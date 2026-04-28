import Flutter
import UIKit

/// Native haptic feedback channel that bypasses Flutter's `HapticFeedback`
/// services. iOS suppresses Flutter-level haptics while `AVCaptureSession`
/// holds the audio engine (mic is hot during video recording). Calling
/// `UIImpactFeedbackGenerator` / `UISelectionFeedbackGenerator` directly
/// from native Swift is NOT suppressed — the Taptic Engine fires even
/// while recording.
///
/// Mirrors the platform-channel pattern of `VideoConverterChannel.swift`.
/// Registered in `AppDelegate.swift` alongside the other channels.
///
/// Channel name: `homefit/haptics`
/// Methods:
///   - `lightImpact`      → UIImpactFeedbackGenerator(style: .light)
///   - `mediumImpact`     → UIImpactFeedbackGenerator(style: .medium)
///   - `heavyImpact`      → UIImpactFeedbackGenerator(style: .heavy)
///   - `selectionClick`   → UISelectionFeedbackGenerator
class HomefitHapticsChannel {
    private let channel: FlutterMethodChannel

    // Pre-warmed generators — `prepare()` reduces latency on first fire.
    private lazy var lightGenerator: UIImpactFeedbackGenerator = {
        let g = UIImpactFeedbackGenerator(style: .light)
        g.prepare()
        return g
    }()

    private lazy var mediumGenerator: UIImpactFeedbackGenerator = {
        let g = UIImpactFeedbackGenerator(style: .medium)
        g.prepare()
        return g
    }()

    private lazy var heavyGenerator: UIImpactFeedbackGenerator = {
        let g = UIImpactFeedbackGenerator(style: .heavy)
        g.prepare()
        return g
    }()

    private lazy var selectionGenerator: UISelectionFeedbackGenerator = {
        let g = UISelectionFeedbackGenerator()
        g.prepare()
        return g
    }()

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(
            name: "homefit/haptics",
            binaryMessenger: messenger
        )

        channel.setMethodCallHandler { [weak self] (call, result) in
            guard let self = self else {
                result(FlutterMethodNotImplemented)
                return
            }

            switch call.method {
            case "lightImpact":
                self.lightGenerator.impactOccurred()
                self.lightGenerator.prepare()
                result(nil)

            case "mediumImpact":
                self.mediumGenerator.impactOccurred()
                self.mediumGenerator.prepare()
                result(nil)

            case "heavyImpact":
                self.heavyGenerator.impactOccurred()
                self.heavyGenerator.prepare()
                result(nil)

            case "selectionClick":
                self.selectionGenerator.selectionChanged()
                self.selectionGenerator.prepare()
                result(nil)

            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }
}
