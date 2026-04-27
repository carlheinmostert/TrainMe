import Flutter
import UIKit
import AVFoundation
import os.log

// MARK: - Wave 34 — Native AVFoundation camera glass for avatar capture
//
// REPLACES the Flutter `camera` plugin on `client_avatar_capture_screen.dart`
// (and ONLY that surface — practitioner exercise capture still uses the
// plugin). Wave 33 confirmed via Console.app that the Flutter plugin
// enumerates exactly ONE back camera entry on Carl's Pro iPhone — name
// `"Back Camera"` — which IS the iOS virtual multi-cam device
// (`.builtInDualWideCamera` / `.builtInTripleCamera`). That virtual device
// auto-switches between UltraWide / Wide / Telephoto based on subject
// distance + lighting; no Dart-side picker (Wave 33's 3-strategy filter)
// can defeat it because the underlying lens choice is hidden behind the
// virtual device.
//
// This channel runs an `AVCaptureSession` against the canonical 1×
// `.builtInWideAngleCamera` directly. No virtual device, no auto-switch,
// no fish-eye. The `videoOrientation` is pinned to `.portrait` on both
// the photo-output connection AND the preview-layer connection so a
// sideways phone still produces an upright capture + an upright preview.
//
// Channel name: `com.raidme.avatar_camera`. Methods:
//   * `avatarCameraStart`   → starts the session, returns device info.
//   * `avatarCameraStop`    → stops + tears down. Idempotent.
//   * `avatarCameraCapture` → captures a still JPEG to `outPath`.
//
// The preview surface is a separate `FlutterPlatformViewFactory` registered
// under view-type `homefit/avatar_camera_preview` (see bottom of file).
// The factory hands out UIView wrappers around `AVCaptureVideoPreviewLayer`
// whose session is the SAME `AVCaptureSession` started by this channel —
// they share state via the `currentSession` static.
//
// Diagnostics use `os_log` against subsystem `com.raidme.raidme` and
// category `avatar.capture` so Carl can filter Console.app on the
// physical device. Dart-side `dart:developer.log()` does NOT surface in
// Console.app for iOS Flutter profile/release builds (Wave 33 learned the
// hard way) — load-bearing diagnostics live here in Swift now.

@available(iOS 11.0, *)
final class AvatarCameraChannel: NSObject {
    /// Singleton that the preview-view factory pulls from. Set when the
    /// session starts; cleared when it stops. Multiple preview views
    /// pointing at the same session is fine — `AVCaptureVideoPreviewLayer`
    /// is just a sink, not an owner.
    static var currentSession: AVCaptureSession?

    /// Subsystem + category for `os_log`. EXACT strings — Carl filters on
    /// these in Console.app.
    private static let log = OSLog(subsystem: "com.raidme.raidme", category: "avatar.capture")

    /// Background queue for AVCaptureSession start/stop. Apple specifically
    /// recommends keeping these off the main queue — `startRunning` blocks
    /// until the camera hardware spins up (~200-500ms on real device).
    private let sessionQueue = DispatchQueue(label: "homefit.avatar_camera.session")

    /// The active session. Kept on `self` so its strong reference outlives
    /// each method call. Mirrored into `Self.currentSession` for the
    /// preview factory to read.
    private var session: AVCaptureSession?
    private var photoOutput: AVCapturePhotoOutput?
    private var captureDelegate: AvatarCapturePhotoDelegate?
    private var deviceInput: AVCaptureDeviceInput?

    private let channel: FlutterMethodChannel

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(
            name: "com.raidme.avatar_camera",
            binaryMessenger: messenger
        )
        super.init()
        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
        os_log("AvatarCameraChannel initialised — channel=%{public}@",
               log: Self.log, type: .info, "com.raidme.avatar_camera")
    }

    // MARK: - Method dispatch

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "avatarCameraStart":
            sessionQueue.async { [weak self] in
                self?.startSession(result: result)
            }
        case "avatarCameraStop":
            sessionQueue.async { [weak self] in
                self?.stopSession(result: result)
            }
        case "avatarCameraCapture":
            guard let args = call.arguments as? [String: Any],
                  let outPath = args["outPath"] as? String else {
                result(FlutterError(
                    code: "INVALID_ARGS",
                    message: "Missing outPath for avatarCameraCapture",
                    details: nil
                ))
                return
            }
            sessionQueue.async { [weak self] in
                self?.capturePhoto(outPath: outPath, result: result)
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Session lifecycle

    /// Build an `AVCaptureSession` with a single back wide-angle input
    /// and a still-photo output. Pins `.portrait` on the photoOutput's
    /// video connection so EXIF orientation is upright regardless of
    /// device rotation.
    ///
    /// Idempotent: if a session is already running, returns its info
    /// without rebuilding. The Dart side calls `avatarCameraStart` from
    /// `initState` AND `didChangeAppLifecycleState(.resumed)` so this
    /// runs more than once per screen.
    private func startSession(result: @escaping FlutterResult) {
        if let existing = session, existing.isRunning {
            os_log("startSession: already running, returning existing device info",
                   log: Self.log, type: .info)
            DispatchQueue.main.async {
                result(self.payloadForRunningSession())
            }
            return
        }

        // CANONICAL device pick — `.builtInWideAngleCamera` is the load-
        // bearing change vs Wave 33. This bypasses iPhone's virtual
        // multi-cam devices entirely. On a single-lens iPhone this is
        // the only back camera; on multi-lens iPhones it's the standard
        // 26mm-equivalent wide.
        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .back
        ) else {
            os_log("startSession: no .builtInWideAngleCamera available",
                   log: Self.log, type: .error)
            DispatchQueue.main.async {
                result(FlutterError(
                    code: "NO_CAMERA",
                    message: "No back wide-angle camera on this device",
                    details: nil
                ))
            }
            return
        }

        // Diagnostic dump of EVERY back-facing device the system can see,
        // so Carl can compare what AVFoundation reports vs what the
        // Flutter `camera` plugin used to enumerate.
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,
                .builtInUltraWideCamera,
                .builtInTelephotoCamera,
                .builtInDualCamera,
                .builtInDualWideCamera,
                .builtInTripleCamera,
            ],
            mediaType: .video,
            position: .back
        )
        let availableTypes = discovery.devices.map { $0.deviceType.rawValue }
        let availableNames = discovery.devices.map { $0.localizedName }
        os_log("startSession: available back devices types=%{public}@ names=%{public}@",
               log: Self.log, type: .info,
               availableTypes.description, availableNames.description)

        let newSession = AVCaptureSession()
        newSession.beginConfiguration()
        newSession.sessionPreset = .photo

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard newSession.canAddInput(input) else {
                newSession.commitConfiguration()
                throw NSError(
                    domain: "AvatarCamera",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Session refused input"]
                )
            }
            newSession.addInput(input)
            self.deviceInput = input

            let output = AVCapturePhotoOutput()
            guard newSession.canAddOutput(output) else {
                newSession.commitConfiguration()
                throw NSError(
                    domain: "AvatarCamera",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Session refused output"]
                )
            }
            newSession.addOutput(output)
            self.photoOutput = output

            // Pin `.portrait` on the photo output's video connection.
            // Without this, an EXIF-written sideways frame would arrive
            // even though we're locking the Dart-side surface to portrait.
            if let conn = output.connection(with: .video) {
                if conn.isVideoOrientationSupported {
                    conn.videoOrientation = .portrait
                }
            }

            newSession.commitConfiguration()
        } catch {
            os_log("startSession: setup failed err=%{public}@",
                   log: Self.log, type: .error, error.localizedDescription)
            DispatchQueue.main.async {
                result(FlutterError(
                    code: "SESSION_SETUP_FAILED",
                    message: "AVCaptureSession setup failed: \(error.localizedDescription)",
                    details: nil
                ))
            }
            return
        }

        // Start the session. `startRunning` is synchronous and blocks
        // until the camera hardware is hot — that's why we're already
        // on a background queue.
        newSession.startRunning()
        self.session = newSession
        Self.currentSession = newSession

        os_log(
            "startSession: started device=%{public}@ uniqueID=%{public}@ deviceType=%{public}@ minZoom=%{public}f maxZoom=%{public}f",
            log: Self.log, type: .info,
            device.localizedName,
            device.uniqueID,
            device.deviceType.rawValue,
            Double(device.minAvailableVideoZoomFactor),
            Double(device.maxAvailableVideoZoomFactor)
        )

        // Notify any preview views that the session is now live so they
        // can attach. Posted on main because preview layers are a UIKit
        // concern.
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: AvatarCameraChannel.sessionDidStartNotification,
                object: nil
            )
            result([
                "started": true,
                "deviceName": device.localizedName,
                "deviceUniqueID": device.uniqueID,
                "deviceTypeRaw": device.deviceType.rawValue,
                "minZoom": NSNumber(value: Double(device.minAvailableVideoZoomFactor)),
                "maxZoom": NSNumber(value: Double(device.maxAvailableVideoZoomFactor)),
                "availableTypes": availableTypes,
                "availableNames": availableNames,
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
            "deviceTypeRaw": device.deviceType.rawValue,
            "minZoom": NSNumber(value: Double(device.minAvailableVideoZoomFactor)),
            "maxZoom": NSNumber(value: Double(device.maxAvailableVideoZoomFactor)),
        ]
    }

    /// Stop + tear down. Idempotent — safe to invoke when no session is
    /// active.
    private func stopSession(result: @escaping FlutterResult) {
        let s = session
        if let s = s, s.isRunning {
            s.stopRunning()
            os_log("stopSession: stopped", log: Self.log, type: .info)
        } else {
            os_log("stopSession: noop (already stopped)", log: Self.log, type: .info)
        }
        // Drop strong refs so the next start rebuilds cleanly.
        session = nil
        photoOutput = nil
        deviceInput = nil
        captureDelegate = nil
        Self.currentSession = nil
        DispatchQueue.main.async {
            result(["stopped": true])
        }
    }

    // MARK: - Capture

    private func capturePhoto(outPath: String, result: @escaping FlutterResult) {
        guard let output = photoOutput, let _ = session, session?.isRunning == true else {
            os_log("capturePhoto: session not running", log: Self.log, type: .error)
            DispatchQueue.main.async {
                result(FlutterError(
                    code: "SESSION_NOT_RUNNING",
                    message: "AVCaptureSession is not running",
                    details: nil
                ))
            }
            return
        }

        // Belt-and-braces — re-pin portrait on the connection right
        // before capture in case the OS reset orientation when the app
        // backgrounded + foregrounded.
        if let conn = output.connection(with: .video), conn.isVideoOrientationSupported {
            conn.videoOrientation = .portrait
        }

        let settings = AVCapturePhotoSettings(format: [
            AVVideoCodecKey: AVVideoCodecType.jpeg
        ])

        let delegate = AvatarCapturePhotoDelegate(outPath: outPath) { [weak self] success, error in
            self?.captureDelegate = nil
            DispatchQueue.main.async {
                if success {
                    os_log("capturePhoto: wrote %{public}@",
                           log: AvatarCameraChannel.log, type: .info, outPath)
                    result(["success": true, "path": outPath])
                } else {
                    os_log("capturePhoto: failed err=%{public}@",
                           log: AvatarCameraChannel.log, type: .error,
                           error?.localizedDescription ?? "unknown")
                    result(FlutterError(
                        code: "CAPTURE_FAILED",
                        message: error?.localizedDescription ?? "Capture failed",
                        details: nil
                    ))
                }
            }
        }
        // Keep the delegate alive across the async capture callback —
        // `AVCapturePhotoOutput.capturePhoto(with:delegate:)` does NOT
        // retain its delegate.
        captureDelegate = delegate

        os_log("capturePhoto: requesting capture outPath=%{public}@",
               log: Self.log, type: .info, outPath)
        output.capturePhoto(with: settings, delegate: delegate)
    }

    // MARK: - Notifications

    /// Posted on the main queue immediately after `startSession` succeeds.
    /// Preview views observe this so they can re-attach to a freshly
    /// constructed `AVCaptureSession` (e.g. after backgrounding).
    static let sessionDidStartNotification = Notification.Name("homefit.avatar_camera.sessionDidStart")
}

// MARK: - Photo capture delegate

@available(iOS 11.0, *)
private final class AvatarCapturePhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let outPath: String
    private let completion: (Bool, Error?) -> Void

    init(outPath: String, completion: @escaping (Bool, Error?) -> Void) {
        self.outPath = outPath
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if let error = error {
            completion(false, error)
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            completion(false, NSError(
                domain: "AvatarCamera",
                code: -10,
                userInfo: [NSLocalizedDescriptionKey: "No JPEG data"]
            ))
            return
        }
        do {
            let url = URL(fileURLWithPath: outPath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url)
            completion(true, nil)
        } catch {
            completion(false, error)
        }
    }
}

// MARK: - Preview UIView + PlatformView wrapper

/// UIView that hosts an `AVCaptureVideoPreviewLayer` whose session is the
/// active `AvatarCameraChannel.currentSession`. Re-attaches when the
/// session is restarted (e.g. after backgrounding).
@available(iOS 11.0, *)
final class AvatarCameraPreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    private var previewLayer: AVCaptureVideoPreviewLayer {
        return layer as! AVCaptureVideoPreviewLayer
    }

    private var observer: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        previewLayer.videoGravity = .resizeAspect
        attachIfPossible()
        observer = NotificationCenter.default.addObserver(
            forName: AvatarCameraChannel.sessionDidStartNotification,
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

    /// Bind the preview layer to whatever session is current and pin
    /// portrait orientation on its connection. No-op if there's no
    /// session yet.
    private func attachIfPossible() {
        guard let session = AvatarCameraChannel.currentSession else { return }
        previewLayer.session = session
        if let conn = previewLayer.connection, conn.isVideoOrientationSupported {
            conn.videoOrientation = .portrait
        }
    }
}

/// Bridges Flutter's PlatformView to `AvatarCameraPreviewUIView`. View-id
/// is `homefit/avatar_camera_preview`. Registered against the same
/// messenger as the channel, see `AppDelegate.application(_:didFinish…)`.
@available(iOS 11.0, *)
final class AvatarCameraPreviewFactory: NSObject, FlutterPlatformViewFactory {
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
        return AvatarCameraPreviewPlatformView(frame: frame)
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        return FlutterStandardMessageCodec.sharedInstance()
    }
}

@available(iOS 11.0, *)
private final class AvatarCameraPreviewPlatformView: NSObject, FlutterPlatformView {
    private let _view: AvatarCameraPreviewUIView

    init(frame: CGRect) {
        _view = AvatarCameraPreviewUIView(frame: frame)
        super.init()
    }

    func view() -> UIView { _view }
}
