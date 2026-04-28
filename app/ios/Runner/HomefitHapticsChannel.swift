import Flutter
import UIKit
import CoreHaptics

/// Native haptic feedback via UIImpactFeedbackGenerator.
///
/// **iOS limitation (confirmed 2026-04-28):** iOS suppresses ALL vibration
/// hardware while an AVCaptureSession with audio input is active. This is
/// a hardware-level protection to prevent Taptic Engine vibrations from
/// contaminating microphone audio. No API (UIImpactFeedbackGenerator,
/// CHHapticEngine, AudioServicesPlaySystemSound, AVAudioSession category
/// swap) can bypass it. Haptics only fire BEFORE the camera plugin claims
/// the mic (first interaction in a camera session). After that, visual
/// feedback is the only option — see capture_mode_screen.dart.
///
/// The channel remains useful for non-camera surfaces (Diagnostics,
/// Settings, Studio editor) where haptics fire reliably.
///
/// Channel name: `homefit/haptics`
/// Methods: `lightImpact`, `mediumImpact`, `heavyImpact`, `selectionClick`, `diagnose`
class HomefitHapticsChannel {
    private let channel: FlutterMethodChannel
    private var lastError: String?

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
                result(self.fire(.light, intensity: 0.4) ? "ok" : self.lastError ?? "unknown")
            case "mediumImpact":
                result(self.fire(.medium, intensity: 0.65) ? "ok" : self.lastError ?? "unknown")
            case "heavyImpact":
                result(self.fire(.heavy, intensity: 1.0) ? "ok" : self.lastError ?? "unknown")
            case "selectionClick":
                result(self.fire(.light, intensity: 0.3) ? "ok" : self.lastError ?? "unknown")
            case "diagnose":
                result(self.diagnose())
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    /// Fresh generator per call — no caching, no stale state.
    @discardableResult
    private func fire(_ style: UIImpactFeedbackGenerator.FeedbackStyle, intensity: Float) -> Bool {
        let gen = UIImpactFeedbackGenerator(style: style)
        gen.prepare()
        gen.impactOccurred(intensity: CGFloat(intensity))
        lastError = nil
        return true
    }

    /// Diagnostic report for the Diagnostics screen.
    private func diagnose() -> String {
        let hw = CHHapticEngine.capabilitiesForHardware()
        var lines: [String] = []
        lines.append("supportsHaptics: \(hw.supportsHaptics)")
        lines.append("lastError: \(lastError ?? "none")")
        let ok = fire(.heavy, intensity: 1.0)
        lines.append("testFire(heavy): \(ok ? "OK" : "FAILED")")
        return lines.joined(separator: "\n")
    }
}
