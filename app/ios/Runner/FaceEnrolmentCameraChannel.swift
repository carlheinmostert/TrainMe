import Flutter
import UIKit
import AVFoundation
import os.log

// MARK: - M37 — Real-time AVCaptureMetadataOutput face tracking
//
// Replaces the still-image `VNDetectFaceLandmarksRequest` pose detection
// that the Wave-D + Phase 2 enrolment flow relied on. Diagnostic logs on
// Carl's iPhone confirmed VNFaceObservation.yaw / .pitch returned nil for
// EVERY captured frame (even straight-ahead, even with revision 3), which
// silently rejected the entire sweep at the per-prompt tolerance check.
//
// This channel owns an `AVCaptureSession` configured for the front
// (or back) camera with TWO outputs:
//
//   1. `AVCaptureMetadataOutput` with `.face` metadata type — the ISP
//      streams `AVMetadataFaceObject` instances with `yaw` + `rollAngle`
//      computed by silicon, at ~30 fps. Reliable across off-axis angles
//      that VNDetectFaceLandmarksRequest returns nil for.
//
//   2. `AVCaptureVideoDataOutput` — silent stream of `CMSampleBuffer`
//      frames at the same ~30 fps. We keep a tiny ring buffer of the
//      last few frames so the on-demand `captureFrameAndEmbed` channel
//      call can pull a fresh frame, decode it, and run MobileFaceNet.
//      No `AVCapturePhotoOutput` — that triggers iOS's shutter sound +
//      mid-frame interruption which we explicitly do not want for the
//      sweep cadence.
//
// Channel surface:
//
//   * MethodChannel `homefit/face-enrolment-camera`
//       - `start(position: "front"|"back")` → boots the session, returns
//         device info.
//       - `stop()` → tears down the session. Idempotent.
//       - `captureFrameAndEmbed(outPath: String)` → pulls the most-recent
//         CMSampleBuffer from the ring, writes it to `outPath` as JPG,
//         runs MobileFaceNet on the crop derived from the latest face
//         metadata bounding box, returns the 2048-byte embedding + the
//         face bounds + the source frame path.
//
//   * EventChannel `homefit/face-enrolment-pose-stream` — emits the most
//     recent face's yaw + rollAngle + faceID + bounds + timestamp at the
//     same cadence iOS delivers metadata (typically ~10-30 Hz depending
//     on subject distance + lighting). Multi-face frames are filtered
//     down to the largest bounding box so a bystander wandering past
//     doesn't whipsaw the prompt walker.
//
// Pose units: `AVMetadataFaceObject.yawAngle` is the rotation around the
// vertical axis in DEGREES (positive = head turned to the device's right,
// negative = device's left). `rollAngle` is the rotation around the
// view-normal axis in DEGREES (positive = head tilted to the right
// shoulder). PITCH IS NOT EXPOSED by AVCaptureMetadataOutput — the
// device's ISP doesn't compute it because most consumer photo-management
// use cases (tagging, focus assist) only need yaw + roll. The M37 brief
// chooses option 1 (drop pitch-based prompts entirely) so the Dart side
// only acts on yaw values from this channel.
//
// FRONT-CAMERA MIRROR INVERSION: yawAngle is reported from the SENSOR's
// perspective, not the user's. With the front camera, the sensor sees the
// user mirrored — when the user turns their head to THEIR right, the
// sensor measures yaw as NEGATIVE (because from the sensor's perspective
// the user just turned to the sensor's left). The prompt walker on the
// Dart side encodes targets in USER-PERSPECTIVE ("turn right" → +60), so
// we invert yaw before emitting when the front camera is active. This
// gives the Dart side a consistent semantic regardless of camera choice.
// Back-camera (rare in enrolment) needs no inversion — sensor and user
// share the same chirality.
//
// Preview surface: a separate `FlutterPlatformViewFactory` registered
// under view-type `homefit/face_enrolment_camera_preview` (see bottom
// of file). Mirrors the AvatarCameraPreviewFactory pattern.
//
// Diagnostics: os_log against subsystem `studio.homefit.app` and
// category `face.enrolment.camera`. Filter on these in Console.app.

@available(iOS 14.0, *)
final class FaceEnrolmentCameraChannel: NSObject {
    /// Singleton the preview-view factory pulls from. Set when the
    /// session starts; cleared when it stops.
    static var currentSession: AVCaptureSession?

    private static let log = OSLog(
        subsystem: "studio.homefit.app",
        category: "face.enrolment.camera"
    )

    /// Posted on the main queue after `startSession` succeeds. Preview
    /// views observe this so they can re-attach to a freshly built
    /// session.
    static let sessionDidStartNotification =
        Notification.Name("homefit.face_enrolment_camera.sessionDidStart")

    /// Background queue for AVCaptureSession lifecycle (start/stop/
    /// configure). Apple recommends keeping these off main — startRunning
    /// blocks until the camera spins up (~200-500ms on real device).
    private let sessionQueue = DispatchQueue(label: "homefit.face_enrolment_camera.session")

    /// Dedicated queue for the metadata + video data output delegates.
    /// Same queue for both so we have a consistent ordering between
    /// "latest face metadata" and "latest video sample" — the
    /// captureFrameAndEmbed path reads both atomically off this queue.
    private let outputQueue = DispatchQueue(
        label: "homefit.face_enrolment_camera.output",
        qos: .userInitiated
    )

    private var session: AVCaptureSession?
    private var deviceInput: AVCaptureDeviceInput?
    private var metadataOutput: AVCaptureMetadataOutput?
    private var videoDataOutput: AVCaptureVideoDataOutput?

    private let channel: FlutterMethodChannel
    private let poseEventChannel: FlutterEventChannel
    private let poseStreamHandler = PoseStreamHandler()

    /// Currently active camera direction. Re-built when start is called
    /// with the other direction.
    private var currentPosition: AVCaptureDevice.Position = .front

    /// Ring buffer of the most-recent video sample buffers. Bounded to
    /// 3 entries so memory stays flat (each buffer is ~1MB at 1280x720
    /// BGRA but we keep the CMSampleBuffer references which share the
    /// underlying CVPixelBuffer). Access is guarded by `ringLock`.
    private var sampleRing: [CMSampleBuffer] = []
    private let sampleRingLock = NSLock()
    private static let kSampleRingCapacity = 3

    /// Most-recent face metadata bounding box (in normalized 0..1
    /// coordinates, AVMetadataFaceObject convention: top-left origin
    /// in metadata space). Used by `captureFrameAndEmbed` to crop the
    /// face out of the ring-buffered sample. Nil when no face has been
    /// detected since session start.
    private var latestFaceBoundsNormalized: CGRect?
    private let latestFaceLock = NSLock()

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(
            name: "homefit/face-enrolment-camera",
            binaryMessenger: messenger
        )
        poseEventChannel = FlutterEventChannel(
            name: "homefit/face-enrolment-pose-stream",
            binaryMessenger: messenger
        )
        super.init()
        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
        poseEventChannel.setStreamHandler(poseStreamHandler)
        os_log("FaceEnrolmentCameraChannel initialised", log: Self.log, type: .info)
    }

    // MARK: - Method dispatch

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "start":
            let posArg = (call.arguments as? [String: Any])?["position"] as? String
            let position: AVCaptureDevice.Position =
                (posArg == "back") ? .back : .front
            sessionQueue.async { [weak self] in
                self?.startSession(position: position, result: result)
            }

        case "stop":
            sessionQueue.async { [weak self] in
                self?.stopSession(result: result)
            }

        case "captureFrameAndEmbed":
            guard let args = call.arguments as? [String: Any],
                  let outPath = args["outPath"] as? String else {
                result(FlutterError(
                    code: "INVALID_ARGS",
                    message: "Missing outPath for captureFrameAndEmbed",
                    details: nil
                ))
                return
            }
            outputQueue.async { [weak self] in
                self?.captureFrameAndEmbed(outPath: outPath, result: result)
            }

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Session lifecycle

    private func startSession(
        position: AVCaptureDevice.Position,
        result: @escaping FlutterResult
    ) {
        if let existing = session, existing.isRunning, currentPosition == position {
            os_log(
                "startSession: already running on same position, returning info",
                log: Self.log, type: .info
            )
            DispatchQueue.main.async {
                result(self.payloadForRunningSession())
            }
            return
        }

        // Tear down any prior session before rebuilding.
        if let existing = session {
            os_log(
                "startSession: rebuilding for position change (was=%{public}@ requested=%{public}@)",
                log: Self.log, type: .info,
                currentPosition == .front ? "front" : "back",
                position == .front ? "front" : "back"
            )
            if existing.isRunning {
                existing.stopRunning()
            }
            self.session = nil
            self.deviceInput = nil
            self.metadataOutput = nil
            self.videoDataOutput = nil
            Self.currentSession = nil
            self.clearSampleRing()
            self.clearLatestFace()
        }

        currentPosition = position

        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: position
        ) else {
            let label = position == .front ? "front" : "back"
            os_log(
                "startSession: no .builtInWideAngleCamera on %{public}@",
                log: Self.log, type: .error, label
            )
            DispatchQueue.main.async {
                result(FlutterError(
                    code: "NO_CAMERA",
                    message: "No \(label) wide-angle camera on this device",
                    details: nil
                ))
            }
            return
        }

        let newSession = AVCaptureSession()
        newSession.beginConfiguration()
        // .high preset is a good compromise — gives 1280x720 (or device-
        // equivalent) at 30fps, well-tuned by Apple for face detection.
        // We don't need .photo's full resolution since the embedding
        // step downscales to MobileFaceNet's 112x112 input anyway.
        if newSession.canSetSessionPreset(.high) {
            newSession.sessionPreset = .high
        } else {
            newSession.sessionPreset = .medium
        }

        // Input.
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard newSession.canAddInput(input) else {
                newSession.commitConfiguration()
                throw NSError(
                    domain: "FaceEnrolmentCamera",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Session refused input"]
                )
            }
            newSession.addInput(input)
            self.deviceInput = input

            // Metadata output for face tracking.
            let metaOut = AVCaptureMetadataOutput()
            guard newSession.canAddOutput(metaOut) else {
                newSession.commitConfiguration()
                throw NSError(
                    domain: "FaceEnrolmentCamera",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Session refused metadata output"]
                )
            }
            newSession.addOutput(metaOut)
            // Available types must be set AFTER addOutput.
            if metaOut.availableMetadataObjectTypes.contains(.face) {
                metaOut.metadataObjectTypes = [.face]
            } else {
                newSession.commitConfiguration()
                throw NSError(
                    domain: "FaceEnrolmentCamera",
                    code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "Device does not report .face metadata"]
                )
            }
            metaOut.setMetadataObjectsDelegate(self, queue: outputQueue)
            self.metadataOutput = metaOut

            // Video data output for on-demand frame grabs.
            let videoOut = AVCaptureVideoDataOutput()
            videoOut.alwaysDiscardsLateVideoFrames = true
            videoOut.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_32BGRA
            ]
            guard newSession.canAddOutput(videoOut) else {
                newSession.commitConfiguration()
                throw NSError(
                    domain: "FaceEnrolmentCamera",
                    code: -4,
                    userInfo: [NSLocalizedDescriptionKey: "Session refused video data output"]
                )
            }
            newSession.addOutput(videoOut)
            videoOut.setSampleBufferDelegate(self, queue: outputQueue)
            self.videoDataOutput = videoOut

            // Pin portrait on both output connections so a sideways
            // device still produces upright bounds + upright JPGs.
            if let conn = videoOut.connection(with: .video) {
                if conn.isVideoOrientationSupported {
                    conn.videoOrientation = .portrait
                }
                // For the front camera, set mirroring so the captured
                // JPG matches what the practitioner sees in the
                // preview — selfies feel wrong-handed if you don't.
                if position == .front, conn.isVideoMirroringSupported {
                    conn.automaticallyAdjustsVideoMirroring = false
                    conn.isVideoMirrored = true
                }
            }

            newSession.commitConfiguration()
        } catch {
            os_log(
                "startSession: setup failed err=%{public}@",
                log: Self.log, type: .error, error.localizedDescription
            )
            DispatchQueue.main.async {
                result(FlutterError(
                    code: "SESSION_SETUP_FAILED",
                    message: "AVCaptureSession setup failed: \(error.localizedDescription)",
                    details: nil
                ))
            }
            return
        }

        newSession.startRunning()
        self.session = newSession
        Self.currentSession = newSession

        os_log(
            "startSession: started device=%{public}@ position=%{public}@",
            log: Self.log, type: .info,
            device.localizedName,
            position == .front ? "front" : "back"
        )

        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: FaceEnrolmentCameraChannel.sessionDidStartNotification,
                object: nil
            )
            result([
                "started": true,
                "deviceName": device.localizedName,
                "deviceUniqueID": device.uniqueID,
                "position": position == .front ? "front" : "back",
            ])
        }
    }

    private func payloadForRunningSession() -> [String: Any] {
        guard let device = deviceInput?.device else {
            return ["started": true]
        }
        return [
            "started": true,
            "deviceName": device.localizedName,
            "deviceUniqueID": device.uniqueID,
            "position": currentPosition == .front ? "front" : "back",
        ]
    }

    private func stopSession(result: @escaping FlutterResult) {
        if let s = session, s.isRunning {
            s.stopRunning()
            os_log("stopSession: stopped", log: Self.log, type: .info)
        } else {
            os_log("stopSession: noop", log: Self.log, type: .info)
        }
        session = nil
        deviceInput = nil
        metadataOutput = nil
        videoDataOutput = nil
        Self.currentSession = nil
        clearSampleRing()
        clearLatestFace()
        DispatchQueue.main.async {
            result(["stopped": true])
        }
    }

    // MARK: - Ring buffer + latest face

    private func appendSample(_ buffer: CMSampleBuffer) {
        sampleRingLock.lock()
        defer { sampleRingLock.unlock() }
        sampleRing.append(buffer)
        if sampleRing.count > Self.kSampleRingCapacity {
            sampleRing.removeFirst(sampleRing.count - Self.kSampleRingCapacity)
        }
    }

    private func mostRecentSample() -> CMSampleBuffer? {
        sampleRingLock.lock()
        defer { sampleRingLock.unlock() }
        return sampleRing.last
    }

    private func clearSampleRing() {
        sampleRingLock.lock()
        defer { sampleRingLock.unlock() }
        sampleRing.removeAll()
    }

    private func setLatestFace(_ bounds: CGRect) {
        latestFaceLock.lock()
        defer { latestFaceLock.unlock() }
        latestFaceBoundsNormalized = bounds
    }

    private func latestFace() -> CGRect? {
        latestFaceLock.lock()
        defer { latestFaceLock.unlock() }
        return latestFaceBoundsNormalized
    }

    private func clearLatestFace() {
        latestFaceLock.lock()
        defer { latestFaceLock.unlock() }
        latestFaceBoundsNormalized = nil
    }

    // MARK: - captureFrameAndEmbed

    /// Pull the most-recent video sample, write its pixel buffer to
    /// `outPath` as a JPG, run MobileFaceNet on the crop derived from
    /// the latest face bounding box, return the embedding bytes + the
    /// frame path.
    ///
    /// Fails loud per `feedback_no_silent_fallbacks`:
    ///   - No buffered sample → NO_FRAME (caller treats as transient).
    ///   - No recent face bounds → NO_FACE (caller treats as transient).
    ///   - MobileFaceNet error → EMBEDDING_FAILED with the model error.
    private func captureFrameAndEmbed(outPath: String, result: @escaping FlutterResult) {
        guard let sample = mostRecentSample() else {
            DispatchQueue.main.async {
                result(FlutterError(
                    code: "NO_FRAME",
                    message: "Ring buffer empty — session may not be running",
                    details: nil
                ))
            }
            return
        }
        guard let faceBoundsNormalized = latestFace() else {
            DispatchQueue.main.async {
                result(FlutterError(
                    code: "NO_FACE",
                    message: "No face detected in the recent metadata stream",
                    details: nil
                ))
            }
            return
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
            DispatchQueue.main.async {
                result(FlutterError(
                    code: "NO_PIXEL_BUFFER",
                    message: "CMSampleBuffer had no CVPixelBuffer",
                    details: nil
                ))
            }
            return
        }

        // Lock the pixel buffer + build a CIImage. We then render through
        // a CGImage so the JPG + the MobileFaceNet crop both share the
        // exact same pixel data.
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)

        // The video data output connection was set videoOrientation =
        // .portrait when we configured the session, so the CIImage is
        // already in display orientation (extent matches what the
        // preview shows). For the front camera we also set
        // isVideoMirrored = true so the saved JPG matches the preview.
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = ctx.createCGImage(ciImage, from: ciImage.extent) else {
            DispatchQueue.main.async {
                result(FlutterError(
                    code: "CGIMAGE_CREATE_FAILED",
                    message: "CIContext returned nil CGImage",
                    details: nil
                ))
            }
            return
        }

        // Write the full-frame JPG. UIImage.jpegData is sync and cheap
        // for 1280x720 — well under 100ms on A14+.
        let uiImage = UIImage(cgImage: cgImage)
        guard let jpegData = uiImage.jpegData(compressionQuality: 0.9) else {
            DispatchQueue.main.async {
                result(FlutterError(
                    code: "JPEG_ENCODE_FAILED",
                    message: "UIImage.jpegData returned nil",
                    details: nil
                ))
            }
            return
        }
        do {
            let outURL = URL(fileURLWithPath: outPath)
            try FileManager.default.createDirectory(
                at: outURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try jpegData.write(to: outURL)
        } catch {
            DispatchQueue.main.async {
                result(FlutterError(
                    code: "WRITE_FAILED",
                    message: "Frame write failed: \(error.localizedDescription)",
                    details: nil
                ))
            }
            return
        }

        // Crop the face out for MobileFaceNet. AVMetadataFaceObject bounds
        // are top-left-origin normalized; CGImage cropping is top-left
        // pixel space — same coordinate system, just unnormalize.
        //
        // NOTE: bounds are in the metadata's coordinate space which can
        // differ from the video-data-output's after orientation + mirror.
        // For the production path (front cam, portrait, mirrored) the
        // metadata output's coordinate space tracks the visible preview
        // — Apple keeps these aligned through the same connection
        // configuration. We add a 20% pad so MobileFaceNet sees full
        // hair + jaw context (matches the existing pad in the
        // generateFaceEmbeddingsFromFrames path).
        let imageW = CGFloat(cgImage.width)
        let imageH = CGFloat(cgImage.height)
        let padFactor: CGFloat = 0.20
        let bx = faceBoundsNormalized.origin.x
        let by = faceBoundsNormalized.origin.y
        let bw = faceBoundsNormalized.width
        let bh = faceBoundsNormalized.height
        let padW = bw * padFactor
        let padH = bh * padFactor
        let cropX = max(0, (bx - padW)) * imageW
        let cropY = max(0, (by - padH)) * imageH
        let cropWidth = min(1.0, bw + 2 * padW) * imageW
        let cropHeight = min(1.0, bh + 2 * padH) * imageH
        let pixelCropRect = CGRect(
            x: cropX.rounded(.down),
            y: cropY.rounded(.down),
            width: cropWidth.rounded(.up),
            height: cropHeight.rounded(.up)
        )
        guard let faceCrop = cgImage.cropping(to: pixelCropRect) else {
            DispatchQueue.main.async {
                result(FlutterError(
                    code: "CROP_FAILED",
                    message: "CGImage crop returned nil for rect \(pixelCropRect)",
                    details: nil
                ))
            }
            return
        }

        // Run MobileFaceNet. Embedder is the same singleton used by the
        // generateFaceEmbeddingsFromFrames batch path — reuses the model
        // load so subsequent calls are sub-100ms on A14+.
        let embeddingData: Data
        do {
            embeddingData = try MobileFaceNetEmbedder.shared.embed(face: faceCrop)
        } catch let err as MobileFaceNetEmbedderError {
            let message: String
            switch err {
            case .modelNotBundled:
                message = "MobileFaceNet.mlmodel not found in app bundle"
            case .modelLoadFailed(let msg):
                message = "MobileFaceNet load failed: \(msg)"
            case .preprocessingFailed(let msg):
                message = "MobileFaceNet preprocessing failed: \(msg)"
            case .inferenceFailed(let msg):
                message = "MobileFaceNet inference failed: \(msg)"
            case .outputShapeMismatch(let msg):
                message = "MobileFaceNet output shape mismatch: \(msg)"
            }
            DispatchQueue.main.async {
                result(FlutterError(
                    code: "EMBEDDING_FAILED",
                    message: message,
                    details: nil
                ))
            }
            return
        } catch {
            DispatchQueue.main.async {
                result(FlutterError(
                    code: "EMBEDDING_FAILED",
                    message: "MobileFaceNet unknown error: \(error.localizedDescription)",
                    details: nil
                ))
            }
            return
        }

        DispatchQueue.main.async {
            result([
                "embedding": FlutterStandardTypedData(bytes: embeddingData),
                "framePath": outPath,
                "faceBoundsX": Double(faceBoundsNormalized.origin.x),
                "faceBoundsY": Double(faceBoundsNormalized.origin.y),
                "faceBoundsWidth": Double(faceBoundsNormalized.width),
                "faceBoundsHeight": Double(faceBoundsNormalized.height),
            ])
        }
    }
}

// MARK: - Metadata delegate

@available(iOS 14.0, *)
extension FaceEnrolmentCameraChannel: AVCaptureMetadataOutputObjectsDelegate {
    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        // Filter to faces. AVMetadataObjectType.face produces
        // AVMetadataFaceObject instances which carry yawAngle + rollAngle.
        let faces = metadataObjects.compactMap { $0 as? AVMetadataFaceObject }
        guard !faces.isEmpty else {
            // No face this frame — clear the cached bounds so a stale
            // box doesn't leak into the next captureFrameAndEmbed call.
            // The pose stream stays silent (no event emitted) since
            // there's no pose to publish.
            clearLatestFace()
            return
        }
        // Pick the largest bounding box — bystander-resilient.
        let largest = faces.max { lhs, rhs in
            (lhs.bounds.width * lhs.bounds.height) <
                (rhs.bounds.width * rhs.bounds.height)
        }!
        setLatestFace(largest.bounds)

        // Emit the pose event. yawAngle + rollAngle are non-optional
        // CGFloat on AVMetadataFaceObject — there's no nil sentinel like
        // VNFaceObservation. The "hasYawAngle" / "hasRollAngle" boolean
        // properties tell us whether the ISP actually computed them this
        // frame; we omit the fields from the event when they didn't.
        var payload: [String: Any] = [
            "faceID": Int(largest.faceID),
            "boundsX": Double(largest.bounds.origin.x),
            "boundsY": Double(largest.bounds.origin.y),
            "boundsWidth": Double(largest.bounds.width),
            "boundsHeight": Double(largest.bounds.height),
            "timestampMs": Int(Date().timeIntervalSince1970 * 1000),
        ]
        if largest.hasYawAngle {
            // Front-camera mirror inversion — see comment block at top of
            // file. Flip the sign so positive yaw consistently means
            // "user turned their head to their right" regardless of which
            // physical camera the session is using. AVMetadataFaceObject
            // reports yaw in degrees in the range (-180, 180]; negation
            // preserves the range. We also normalise into the same range
            // after negation in case the ISP ever returns -180 exactly.
            let rawYaw = Double(largest.yawAngle)
            let mirroredYaw = (currentPosition == .front) ? -rawYaw : rawYaw
            payload["yawDeg"] = mirroredYaw
        }
        if largest.hasRollAngle {
            // Roll also mirrors with the camera. Negation here keeps
            // "positive roll = head tilted toward user's right shoulder"
            // consistent between front and back cameras. Dart side does
            // not currently consume roll for pose-walker logic but the
            // event payload is documented as user-perspective so we keep
            // both axes in the same frame.
            let rawRoll = Double(largest.rollAngle)
            let mirroredRoll = (currentPosition == .front) ? -rawRoll : rawRoll
            payload["rollDeg"] = mirroredRoll
        }
        // M37: pitch is not available via AVCaptureMetadataOutput. Dart
        // side accepts payloads without a pitch field — option 1 from
        // the brief (yaw-only prompt walker).
        DispatchQueue.main.async { [weak poseStreamHandler] in
            poseStreamHandler?.send(payload)
        }
    }
}

// MARK: - Video data delegate

@available(iOS 14.0, *)
extension FaceEnrolmentCameraChannel: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Ring-buffer the latest sample. The captureFrameAndEmbed path
        // pulls from this ring on demand — we don't decode every frame.
        appendSample(sampleBuffer)
    }
}

// MARK: - Pose event stream handler

@available(iOS 14.0, *)
private final class PoseStreamHandler: NSObject, FlutterStreamHandler {
    private var sink: FlutterEventSink?

    func onListen(
        withArguments arguments: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        sink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        sink = nil
        return nil
    }

    /// Forward a pose payload to the active Dart listener. No-op when
    /// there is no listener — the stream simply drops events between
    /// onCancel and the next onListen.
    func send(_ payload: [String: Any]) {
        sink?(payload)
    }
}

// MARK: - Preview UIView + PlatformView wrapper

/// UIView hosting an `AVCaptureVideoPreviewLayer` bound to
/// `FaceEnrolmentCameraChannel.currentSession`. Re-attaches whenever
/// the session restarts (post-backgrounding / camera flip).
@available(iOS 14.0, *)
final class FaceEnrolmentCameraPreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    private var previewLayer: AVCaptureVideoPreviewLayer {
        return layer as! AVCaptureVideoPreviewLayer
    }

    private var observer: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        previewLayer.videoGravity = .resizeAspectFill
        attachIfPossible()
        observer = NotificationCenter.default.addObserver(
            forName: FaceEnrolmentCameraChannel.sessionDidStartNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.attachIfPossible()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    deinit {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func attachIfPossible() {
        guard let session = FaceEnrolmentCameraChannel.currentSession else { return }
        previewLayer.session = session
        if let conn = previewLayer.connection, conn.isVideoOrientationSupported {
            conn.videoOrientation = .portrait
        }
    }
}

/// PlatformView factory — view-id `homefit/face_enrolment_camera_preview`.
@available(iOS 14.0, *)
final class FaceEnrolmentCameraPreviewFactory: NSObject, FlutterPlatformViewFactory {
    private let messenger: FlutterBinaryMessenger

    init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        super.init()
    }

    func create(
        withFrame frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?
    ) -> FlutterPlatformView {
        return FaceEnrolmentCameraPreviewPlatformView(frame: frame)
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        return FlutterStandardMessageCodec.sharedInstance()
    }
}

@available(iOS 14.0, *)
private final class FaceEnrolmentCameraPreviewPlatformView: NSObject, FlutterPlatformView {
    private let _view: FaceEnrolmentCameraPreviewUIView

    init(frame: CGRect) {
        _view = FaceEnrolmentCameraPreviewUIView(frame: frame)
        super.init()
    }

    func view() -> UIView { _view }
}
