import Flutter
import UIKit
import ARKit
import SceneKit
import Vision
import AVFoundation
import simd
import os.log

// MARK: - ARKit + TrueDepth face enrolment (M40, 2026-05-26)
//
// PRIMARY pose source for face enrolment on TrueDepth-capable devices
// (iPhone X and newer). Replaces the Vision-on-CMSampleBuffer fallback
// (`FaceEnrolmentCameraChannel.swift`) which sources yaw from
// `VNDetectFaceLandmarksRequest` and was empirically QUANTIZED TO 45°
// STEPS on iPhone 17 Pro / iOS 18+. Pitch is also unreliable: every
// streamed-buffer Vision request returns nil pitch.
//
// Apple's documented continuous-pose path is ARKit + TrueDepth, which
// gives full 6-DoF head pose via `ARFaceAnchor.transform` (a 4×4
// rigid-body model-to-world matrix) at the camera frame rate. This
// channel ONLY registers itself when `ARFaceTrackingConfiguration.isSupported`
// returns true; the fallback Vision channel registers unconditionally
// so we never end up with no face-pose source.
//
// Channel surface (IDENTICAL to FaceEnrolmentCameraChannel):
//
//   * MethodChannel `homefit/face-enrolment-camera`
//       - `start(position: "front")` → boots the ARSession, returns
//         device info. Rejects `"back"` — ARFaceTrackingConfiguration
//         is a front-camera-only configuration. Idempotent if the
//         session is already running on the same direction.
//       - `stop()` → tears down the session. Idempotent.
//       - `captureFrameAndEmbed(outPath: String)` → pulls the most-recent
//         `ARFrame.capturedImage`, writes it as JPG, runs MobileFaceNet
//         on the crop derived from `VNDetectFaceRectanglesRequest` (one-
//         shot face detection — Vision face DETECTION works fine, it's
//         continuous pose that's broken on iOS 18+), returns the
//         2048-byte embedding + face bounds + saved frame path.
//
//   * EventChannel `homefit/face-enrolment-pose-stream` — emits the
//     latest face's `yawDeg + pitchDeg + rollDeg + faceID + bounds +
//     timestampMs` at ARKit's frame rate (~60 Hz). Same payload shape
//     as the Vision channel, so the Dart `FaceEnrolmentCameraChannel`
//     wrapper is agnostic to which native channel produced the event.
//
// Pose perspective contract (matches the Vision channel after its
// front-camera mirror inversion):
//
//   - Positive yaw  = user turned their head to THEIR right
//                     (rotation around the up axis)
//   - Positive pitch = user lifted their chin (rotation around the
//                     side axis — looking up)
//   - Positive roll = user tilted toward THEIR right shoulder
//                     (rotation around the forward axis)
//
// ARKit's `ARFaceAnchor.transform` is in the ARKit world coordinate
// system, NOT the sensor coordinate system. ARKit uses a right-handed
// coordinate system with +X right, +Y up, +Z toward the viewer (out of
// the screen). For face-tracking with the front camera, the world
// coordinate system is anchored to the device pose at session start —
// the face anchor's transform rotates relative to that.
//
// The face anchor's local axes (as documented by Apple in the ARKit
// "Tracking and Visualizing Faces" guide):
//   - +X points to the face's right (subject's left from camera POV)
//   - +Y points up (out the top of the head)
//   - +Z points OUT OF the face (toward the camera)
//
// So a "neutral straight-on" face has its +Z axis pointing at the
// camera. We extract the YXZ Euler angles from the rotation part of
// the transform — yaw around the face's Y, pitch around the face's X,
// roll around the face's Z. The ARKit→user-perspective sign mapping
// is determined empirically (different ARKit versions and front-camera
// vs world-camera modes have flipped these conventions in the past);
// the on-screen debug HUD in `FaceEnrolmentScreen` is the source of
// truth for verifying signs on first device run.
//
// Empirical sign convention used here (verify on real device):
//   - Face anchor pitch (rotation about X axis) positive when the
//     user's chin TILTS DOWN, so we NEGATE for user-perspective.
//   - Face anchor yaw (rotation about Y axis) positive when the user
//     turns to THEIR LEFT (the face's Y is "up" from the face's POV,
//     and a rotation around Y by +π/2 brings the face's +X to the
//     world's -Z, i.e. away from the camera and to the right from
//     camera POV). Negate for user-perspective.
//   - Face anchor roll (rotation about Z axis) positive when the user
//     tilts toward their LEFT shoulder. Negate for user-perspective.
//
// All three negations are bundled into `userYaw / userPitch / userRoll`
// extraction below. If device QA surfaces wrong-direction prompt walks,
// flip the negation here AND update the comment block to reflect
// reality — don't paper over the sign mismatch elsewhere.
//
// Threading:
//   - ARSessionDelegate fires on the main queue by default. We do NOT
//     change that — ARKit is highly opinionated about main-queue
//     delivery for ARFrame events. Pose payload assembly is cheap; we
//     emit immediately.
//   - The embedding extraction in `captureFrameAndEmbed` is offloaded
//     to `outputQueue` (a dedicated background queue) so the ~100ms
//     MobileFaceNet pass doesn't stall ARKit's frame delivery.
//
// Preview surface: `FaceEnrolmentARKitPreviewUIView` hosts an `ARSCNView`
// configured for camera passthrough only (no SceneKit 3D rendering).
// Registered as the SAME PlatformView view-id as the Vision channel
// (`homefit/face_enrolment_camera_preview`) so the Dart UI doesn't know
// which preview implementation is mounted. The capability-gated
// registration in AppDelegate picks one or the other.
//
// Diagnostics: `os_log` against subsystem `studio.homefit.app` and
// category `face.enrolment.arkit`. NSLog tag `[FaceEnrolment-arkit]`
// matches the Vision channel's `[FaceEnrolment-vision]` tag for
// side-by-side comparison in Console.app.

@available(iOS 13.0, *)
final class FaceEnrolmentARKitChannel: NSObject {
    /// Singleton the preview-view factory pulls from. Set when the
    /// session starts; cleared when it stops. Mirrors the Vision
    /// channel's `currentSession` static so the preview-view factory
    /// pattern is identical.
    static var currentARSession: ARSession?

    private static let log = OSLog(
        subsystem: "studio.homefit.app",
        category: "face.enrolment.arkit"
    )

    /// Posted on the main queue after `startSession` succeeds. The
    /// ARSCNView-backed preview view observes this so it re-attaches
    /// to a freshly built session (matches the Vision channel pattern).
    static let sessionDidStartNotification =
        Notification.Name("homefit.face_enrolment_arkit.sessionDidStart")

    /// Background queue for the MobileFaceNet embed pass in
    /// `captureFrameAndEmbed`. ARSessionDelegate stays on the main
    /// queue per Apple's contract; we hop here for the heavy work.
    private let outputQueue = DispatchQueue(
        label: "homefit.face_enrolment_arkit.output",
        qos: .userInitiated
    )

    private var arSession: ARSession?
    private var configuration: ARFaceTrackingConfiguration?

    private let channel: FlutterMethodChannel
    private let poseEventChannel: FlutterEventChannel
    private let poseStreamHandler = ARKitPoseStreamHandler()

    /// Front camera only — ARFaceTrackingConfiguration won't engage on
    /// the rear camera. Kept as a field so the `payloadForRunningSession`
    /// reply matches the Vision channel's structure.
    private let currentPosition: AVCaptureDevice.Position = .front

    /// Most-recent `ARFrame.capturedImage` — used by
    /// `captureFrameAndEmbed` to pull a fresh pixel buffer. Guarded by
    /// `latestFrameLock`.
    private var latestFramePixelBuffer: CVPixelBuffer?
    private var latestFrameLock = NSLock()

    /// Most-recent face anchor — kept so the face-bounds derived from
    /// the anchor's projection are available when `captureFrameAndEmbed`
    /// runs (without having to wait for the next frame). Guarded by
    /// `latestAnchorLock`.
    private var latestFaceAnchor: ARFaceAnchor?
    private var latestAnchorLock = NSLock()

    /// Synthetic face ID counter — bumped per emitted pose event so
    /// the Dart side sees a monotonic counter. ARFaceAnchor has its
    /// own `identifier` UUID; we expose the synthetic counter for
    /// payload parity with the Vision channel.
    private var syntheticFaceIDCounter: Int = 0

    /// Pose-event diagnostic counter. Logged every 30 emissions so the
    /// device console shows whether the stream is alive without
    /// flooding the log.
    private var poseEmitCount: UInt64 = 0

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
        os_log(
            "FaceEnrolmentARKitChannel initialised (ARKit primary path)",
            log: Self.log, type: .info
        )
    }

    // MARK: - Method dispatch

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "start":
            let posArg = (call.arguments as? [String: Any])?["position"] as? String
            if posArg == "back" {
                // ARFaceTrackingConfiguration is FRONT camera only. Reject
                // the request loudly rather than transparently falling back
                // to AVCaptureDevice on the back camera — silent fallbacks
                // are banned (feedback_no_silent_fallbacks). Calling code
                // doesn't actually request `back` for enrolment; if some
                // future caller did, the loud rejection surfaces the
                // architectural mismatch.
                result(FlutterError(
                    code: "UNSUPPORTED_POSITION",
                    message: "ARKit face enrolment requires the front camera",
                    details: nil
                ))
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.startSession(result: result)
            }

        case "stop":
            DispatchQueue.main.async { [weak self] in
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

    private func startSession(result: @escaping FlutterResult) {
        // ARFaceTrackingConfiguration.isSupported MUST be true — the
        // capability check in AppDelegate gates registration of this
        // channel on this fact, but we double-check defensively here
        // in case a future code path lands us here without the gate.
        guard ARFaceTrackingConfiguration.isSupported else {
            os_log(
                "startSession: ARFaceTrackingConfiguration not supported on this device",
                log: Self.log, type: .error
            )
            result(FlutterError(
                code: "AR_FACE_TRACKING_UNSUPPORTED",
                message: "ARFaceTrackingConfiguration is unsupported (no TrueDepth)",
                details: nil
            ))
            return
        }

        if let existing = arSession, configuration != nil {
            os_log(
                "startSession: ARSession already running, returning info",
                log: Self.log, type: .info
            )
            _ = existing // silence warning; payload below pulls metadata from config
            result(payloadForRunningSession())
            return
        }

        let config = ARFaceTrackingConfiguration()
        config.isLightEstimationEnabled = false
        // Single-face tracking — Safe Mode v2 enrolment is the trainer
        // capturing themselves OR their client, never both. Multi-face
        // mode would force us to disambiguate which face is the subject.
        config.maximumNumberOfTrackedFaces = 1

        let session = ARSession()
        session.delegate = self
        session.delegateQueue = nil  // main queue (ARKit's default)
        session.run(config, options: [.resetTracking, .removeExistingAnchors])

        self.arSession = session
        self.configuration = config
        Self.currentARSession = session

        os_log(
            "startSession: ARSession started (front camera, TrueDepth)",
            log: Self.log, type: .info
        )

        NotificationCenter.default.post(
            name: FaceEnrolmentARKitChannel.sessionDidStartNotification,
            object: nil
        )
        result([
            "started": true,
            "deviceName": "ARKit Face Tracking (front + TrueDepth)",
            "deviceUniqueID": "arkit-face-tracking",
            "position": "front",
            "engine": "arkit",
        ])
    }

    private func payloadForRunningSession() -> [String: Any] {
        return [
            "started": true,
            "deviceName": "ARKit Face Tracking (front + TrueDepth)",
            "deviceUniqueID": "arkit-face-tracking",
            "position": currentPosition == .front ? "front" : "back",
            "engine": "arkit",
        ]
    }

    private func stopSession(result: @escaping FlutterResult) {
        if let session = arSession {
            session.pause()
            os_log("stopSession: ARSession paused", log: Self.log, type: .info)
        } else {
            os_log("stopSession: noop (no active ARSession)", log: Self.log, type: .info)
        }
        arSession = nil
        configuration = nil
        Self.currentARSession = nil
        clearLatestFrame()
        clearLatestAnchor()
        result(["stopped": true])
    }

    // MARK: - Latest-frame + latest-anchor caches

    private func setLatestFrame(_ pixelBuffer: CVPixelBuffer) {
        latestFrameLock.lock()
        defer { latestFrameLock.unlock() }
        latestFramePixelBuffer = pixelBuffer
    }

    private func latestFrame() -> CVPixelBuffer? {
        latestFrameLock.lock()
        defer { latestFrameLock.unlock() }
        return latestFramePixelBuffer
    }

    private func clearLatestFrame() {
        latestFrameLock.lock()
        defer { latestFrameLock.unlock() }
        latestFramePixelBuffer = nil
    }

    private func setLatestAnchor(_ anchor: ARFaceAnchor) {
        latestAnchorLock.lock()
        defer { latestAnchorLock.unlock() }
        latestFaceAnchor = anchor
    }

    private func latestAnchor() -> ARFaceAnchor? {
        latestAnchorLock.lock()
        defer { latestAnchorLock.unlock() }
        return latestFaceAnchor
    }

    private func clearLatestAnchor() {
        latestAnchorLock.lock()
        defer { latestAnchorLock.unlock() }
        latestFaceAnchor = nil
    }

    // MARK: - captureFrameAndEmbed
    //
    // Mirror of `FaceEnrolmentCameraChannel.captureFrameAndEmbed`. Pulls
    // the most-recent `ARFrame.capturedImage` (the camera passthrough
    // texture ARKit decodes for us), writes it as JPG, runs MobileFaceNet
    // on the face crop, returns the embedding + frame path + face bounds.
    //
    // For face bounds, we run a one-shot `VNDetectFaceRectanglesRequest`
    // (Vision face DETECTION is fine; it's continuous pose that's
    // quantized). Computing the bounds from `ARFaceAnchor`'s 3D vertices
    // projected through the camera intrinsics would technically work,
    // but adds complexity for an output that's only used to pad-crop
    // around the face for MobileFaceNet input.

    private func captureFrameAndEmbed(outPath: String, result: @escaping FlutterResult) {
        guard let pixelBuffer = latestFrame() else {
            DispatchQueue.main.async {
                result(FlutterError(
                    code: "NO_FRAME",
                    message: "No ARFrame captured yet — session may not be running",
                    details: nil
                ))
            }
            return
        }

        // ARFrame.capturedImage comes in 420f (YpCbCr biplanar) format on
        // most devices. We need to render it as RGB so MobileFaceNet's
        // RGB-normalised preprocessing matches. CIImage handles the
        // colour conversion via the CGImage round-trip.
        //
        // The capturedImage's natural orientation is "landscape right"
        // (camera home-button-on-the-right) regardless of device
        // rotation. For the front-camera enrolment we want it rotated
        // to portrait + mirrored so the saved JPG matches what the
        // practitioner sees on screen.
        let ciImageRaw = CIImage(cvPixelBuffer: pixelBuffer)
        // ARKit front-camera capturedImage is in the sensor's native
        // landscape orientation. To get an upright portrait image with
        // the user's left on the left of the frame (the mirror-like
        // selfie convention the Vision channel also adopts), apply the
        // right orientation transform. .leftMirrored is what the Vision
        // channel uses for the equivalent rotation.
        let ciImage = ciImageRaw.oriented(.leftMirrored)

        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = ctx.createCGImage(ciImage, from: ciImage.extent) else {
            DispatchQueue.main.async {
                result(FlutterError(
                    code: "CGIMAGE_CREATE_FAILED",
                    message: "CIContext returned nil CGImage from ARFrame",
                    details: nil
                ))
            }
            return
        }

        // Save the full-frame JPG before face detection so we always
        // have a frame on disk even if Vision detection fails.
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

        // Run one-shot face DETECTION (not landmarks) to find the bbox
        // for MobileFaceNet cropping. Vision face detection works fine
        // on iOS 18+; it's the landmarks/pose path that's broken.
        let faceBoundsNormalized: CGRect
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            DispatchQueue.main.async {
                result(FlutterError(
                    code: "FACE_DETECT_FAILED",
                    message: "VNDetectFaceRectanglesRequest threw: \(error.localizedDescription)",
                    details: nil
                ))
            }
            return
        }

        let observations = (request.results ?? []) as [VNFaceObservation]
        guard let primary = observations.max(by: { lhs, rhs in
            (lhs.boundingBox.width * lhs.boundingBox.height) <
                (rhs.boundingBox.width * rhs.boundingBox.height)
        }) else {
            DispatchQueue.main.async {
                result(FlutterError(
                    code: "NO_FACE",
                    message: "No face detected by Vision in the captured ARFrame",
                    details: nil
                ))
            }
            return
        }

        // VNFaceObservation.boundingBox is lower-left-origin normalised.
        // Convert to top-left-origin for the crop math + the Dart
        // payload (which uses top-left-origin, matching the Vision
        // channel's `faceBoundsX/Y/Width/Height` convention).
        let topLeftY = 1.0 - primary.boundingBox.origin.y - primary.boundingBox.height
        faceBoundsNormalized = CGRect(
            x: primary.boundingBox.origin.x,
            y: topLeftY,
            width: primary.boundingBox.width,
            height: primary.boundingBox.height
        )

        // Crop the face for MobileFaceNet with the same 20% pad as the
        // Vision channel — keeps the embedding distribution comparable
        // between the two pipelines.
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

        // Run MobileFaceNet — same singleton the Vision channel uses,
        // so the embedding distribution is identical regardless of
        // pose-source pipeline. Errors get the same code mapping so
        // the Dart side's switch statements don't need ARKit-specific
        // branches.
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

    // MARK: - Pose extraction

    /// Convert an `ARFaceAnchor` transform into user-perspective yaw +
    /// pitch + roll DEGREES. See the top-of-file comment block for the
    /// sign convention rationale.
    private func userPoseDegrees(
        from anchor: ARFaceAnchor
    ) -> (yawDeg: Double, pitchDeg: Double, rollDeg: Double) {
        let m = anchor.transform
        // Extract YXZ Euler angles from the rotation part of the 4x4
        // transform. matrix_float4x4 is column-major; m.columns.0..2 are
        // the basis vectors of the face's local frame expressed in
        // world space.
        //
        // Using the YXZ convention (yaw first around Y, then pitch
        // around the new X, then roll around the new Z), the rotation
        // matrix elements relate to the angles as follows (column-major,
        // so m.columns.j.k = R[k][j] in standard row-major notation):
        //
        //   pitch = asin( -m[2][1] )                  // = asin(-R[1][2])
        //   yaw   = atan2( m[2][0], m[2][2] )         // = atan2(R[0][2], R[2][2])
        //   roll  = atan2( m[0][1], m[1][1] )         // = atan2(R[1][0], R[1][1])
        //
        // Reference: standard YXZ Euler extraction (Wikipedia "Rotation
        // matrix" → "Conversions").
        let r00 = m.columns.0.x
        let r10 = m.columns.0.y
        let r01 = m.columns.1.x
        let r11 = m.columns.1.y
        let r02 = m.columns.2.x
        let r12 = m.columns.2.y
        let r22 = m.columns.2.z

        // Clamp before asin to guard against numerical drift outside [-1, 1].
        let sinPitch = -r12
        let clampedSinPitch = max(-1.0, min(1.0, sinPitch))
        let pitchRad = asin(clampedSinPitch)
        // Gimbal-lock check: when |sinPitch| ≈ 1 (looking straight up
        // or straight down) yaw + roll become coupled. We fall back to
        // atan2(r01, r00) for yaw and 0 for roll in that case — Safe
        // Mode enrolment doesn't hit this regime (max pitch prompt is
        // +20°), but the defensive branch keeps the math sane if a user
        // tilts their head wildly.
        let yawRad: Float
        let rollRad: Float
        if abs(clampedSinPitch) > 0.9999 {
            yawRad = atan2(-r01, r00)
            rollRad = 0.0
        } else {
            yawRad = atan2(r02, r22)
            rollRad = atan2(r10, r11)
        }

        // Convert to degrees and apply the user-perspective negation
        // for all three axes per the top-of-file sign convention.
        let rawYawDeg = Double(yawRad) * 180.0 / .pi
        let rawPitchDeg = Double(pitchRad) * 180.0 / .pi
        let rawRollDeg = Double(rollRad) * 180.0 / .pi
        let yawDegUser = -rawYawDeg
        let pitchDegUser = -rawPitchDeg
        let rollDegUser = -rawRollDeg
        return (yawDeg: yawDegUser, pitchDeg: pitchDegUser, rollDeg: rollDegUser)
    }
}

// MARK: - ARSessionDelegate

@available(iOS 13.0, *)
extension FaceEnrolmentARKitChannel: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Cache the latest pixel buffer for the captureFrameAndEmbed
        // path. ARFrame.capturedImage is the camera passthrough texture
        // (YpCbCr 420f); it's safe to retain the CVPixelBuffer ref
        // across queue boundaries.
        setLatestFrame(frame.capturedImage)

        // Find the first ARFaceAnchor — single-face tracking config means
        // there's at most one. Cache it for captureFrameAndEmbed's
        // bounds path.
        guard let faceAnchor = frame.anchors.compactMap({ $0 as? ARFaceAnchor }).first else {
            // No face this frame — emit no pose event (subscribers
            // treat a quiet period as "no face", matching the Vision
            // channel's contract).
            return
        }
        setLatestAnchor(faceAnchor)

        let pose = userPoseDegrees(from: faceAnchor)

        // ARFaceAnchor doesn't directly expose a 2D image-space
        // bounding box — its geometry is 3D vertices in face-local
        // space. We could project + reduce to a bbox, but the Dart
        // side only uses bounds for the `face is in frame` debug
        // overlay; the pose-walker doesn't gate on them. Pass through
        // the unit rect as a conservative "the face is somewhere".
        // If a future caller needs real bounds here, project the
        // anchor's geometry through frame.camera.projectionMatrix.
        let bounds = CGRect(x: 0.25, y: 0.20, width: 0.5, height: 0.6)

        syntheticFaceIDCounter &+= 1
        let faceID = syntheticFaceIDCounter

        let payload: [String: Any] = [
            "faceID": faceID,
            "yawDeg": pose.yawDeg,
            "pitchDeg": pose.pitchDeg,
            "rollDeg": pose.rollDeg,
            "boundsX": Double(bounds.origin.x),
            "boundsY": Double(bounds.origin.y),
            "boundsWidth": Double(bounds.size.width),
            "boundsHeight": Double(bounds.size.height),
            "timestampMs": Int(Date().timeIntervalSince1970 * 1000),
        ]

        // Periodic diagnostic log — every 30 events (~0.5s at 60 Hz)
        // so the device console shows the stream is alive without
        // flooding. The on-screen pose HUD is the source of truth for
        // per-frame numbers.
        poseEmitCount &+= 1
        if poseEmitCount % 30 == 0 {
            NSLog(String(
                format: "[FaceEnrolment-arkit] tick#%llu yaw=%.1f° pitch=%.1f° roll=%.1f°",
                poseEmitCount, pose.yawDeg, pose.pitchDeg, pose.rollDeg
            ))
        }

        // Already on main queue per ARSession delegate contract — send
        // directly.
        poseStreamHandler.send(payload)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        // No silent fallback — surface the failure to the Dart side via
        // the pose stream error channel. The Vision channel does not
        // take over on ARKit failure: per `feedback_no_silent_fallbacks`,
        // load-bearing features must show an explicit error rather than
        // transparently degrading.
        os_log(
            "ARSession failed: %{public}@",
            log: Self.log, type: .error,
            error.localizedDescription
        )
        NSLog("[FaceEnrolment-arkit] session_failed=\(error.localizedDescription)")
        poseStreamHandler.sendError(
            FlutterError(
                code: "AR_SESSION_FAILED",
                message: error.localizedDescription,
                details: nil
            )
        )
    }

    func sessionWasInterrupted(_ session: ARSession) {
        os_log(
            "ARSession was interrupted (e.g. backgrounded, phone call)",
            log: Self.log, type: .info
        )
        NSLog("[FaceEnrolment-arkit] session_interrupted")
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        os_log(
            "ARSession interruption ended — resetting tracking",
            log: Self.log, type: .info
        )
        NSLog("[FaceEnrolment-arkit] session_interruption_ended")
        // Reset tracking so the face anchor is re-acquired cleanly
        // rather than picking up a stale pose from before the
        // interruption.
        if let config = configuration {
            session.run(config, options: [.resetTracking, .removeExistingAnchors])
        }
    }
}

// MARK: - Pose stream handler (ARKit-specific)

@available(iOS 13.0, *)
private final class ARKitPoseStreamHandler: NSObject, FlutterStreamHandler {
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
    /// no listener is bound — events simply drop, matching the Vision
    /// channel's contract.
    func send(_ payload: [String: Any]) {
        sink?(payload)
    }

    /// Surface an ARKit session error to Dart. Per the no-silent-fallback
    /// rule, errors propagate up — the UI is responsible for showing the
    /// "ARKit unavailable, please try again" toast and giving the user
    /// an explicit restart path.
    func sendError(_ error: FlutterError) {
        sink?(error)
    }
}

// MARK: - Preview UIView + PlatformView wrapper
//
// Uses ARSCNView for the camera passthrough preview. SceneKit's 3D
// rendering pipeline is unnecessary for our use (we don't render face
// meshes or AR overlays), but ARSCNView is the cheapest way to get
// the camera feed displayed without owning a Metal pipeline ourselves.
// `automaticallyUpdatesLighting = false` and the empty scene keep CPU
// overhead minimal — the view is essentially a chrome wrapper around
// the AVCaptureVideoPreviewLayer equivalent that ARKit manages
// internally.

@available(iOS 13.0, *)
final class FaceEnrolmentARKitPreviewUIView: UIView {
    private let arSCNView: ARSCNView

    private var observer: NSObjectProtocol?

    override init(frame: CGRect) {
        arSCNView = ARSCNView(frame: frame)
        super.init(frame: frame)
        backgroundColor = .black
        arSCNView.frame = bounds
        arSCNView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        arSCNView.backgroundColor = .black
        arSCNView.automaticallyUpdatesLighting = false
        arSCNView.scene = SCNScene()
        // Hide the SceneKit statistics + don't render any 3D overlays —
        // we just want the camera passthrough.
        arSCNView.showsStatistics = false
        addSubview(arSCNView)

        attachIfPossible()
        observer = NotificationCenter.default.addObserver(
            forName: FaceEnrolmentARKitChannel.sessionDidStartNotification,
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
        guard let session = FaceEnrolmentARKitChannel.currentARSession else { return }
        arSCNView.session = session
    }
}

/// PlatformView factory — registered under the SAME view-type as the
/// Vision channel's preview (`homefit/face_enrolment_camera_preview`)
/// when ARKit is the primary path. AppDelegate's capability check
/// guarantees only one factory is registered per launch so there's no
/// view-id collision at runtime.
@available(iOS 13.0, *)
final class FaceEnrolmentARKitPreviewFactory: NSObject, FlutterPlatformViewFactory {
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
        return FaceEnrolmentARKitPreviewPlatformView(frame: frame)
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        return FlutterStandardMessageCodec.sharedInstance()
    }
}

@available(iOS 13.0, *)
private final class FaceEnrolmentARKitPreviewPlatformView: NSObject, FlutterPlatformView {
    private let _view: FaceEnrolmentARKitPreviewUIView

    init(frame: CGRect) {
        _view = FaceEnrolmentARKitPreviewUIView(frame: frame)
        super.init()
    }

    func view() -> UIView { _view }
}
