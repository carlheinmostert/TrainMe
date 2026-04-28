import Flutter
import UIKit
import CoreHaptics

/// Native haptic feedback channel that bypasses Flutter's `HapticFeedback`
/// services. iOS suppresses Flutter-level haptics while `AVCaptureSession`
/// holds the audio engine (mic is hot during video recording).
///
/// Wave 40.6 — rewritten to use `CHHapticEngine` instead of
/// `UIImpactFeedbackGenerator`. Carl's device QA on Wave 40.5 showed that
/// `UIImpactFeedbackGenerator` fires the FIRST time only — subsequent
/// calls in the same session are silently swallowed. The root cause is
/// that iOS invalidates the generator's `prepare()` state after a short
/// delay (~1-2s), and during active `AVCaptureSession` recording the audio
/// session reconfiguration further suppresses the Taptic Engine path that
/// `UIImpactFeedbackGenerator` uses.
///
/// `CHHapticEngine` with `playsHapticsOnly = true` is immune to audio
/// session interference. It talks directly to the Taptic Engine and
/// continues to fire during video recording (mic hot), between recordings,
/// and across repeated calls without any prepare/invalidation dance.
///
/// Channel name: `homefit/haptics`
/// Methods:
///   - `lightImpact`      → transient haptic, intensity 0.4, sharpness 0.5
///   - `mediumImpact`     → transient haptic, intensity 0.65, sharpness 0.6
///   - `heavyImpact`      → transient haptic, intensity 1.0, sharpness 0.8
///   - `selectionClick`   → transient haptic, intensity 0.3, sharpness 0.9
class HomefitHapticsChannel {
    private let channel: FlutterMethodChannel
    private var engine: CHHapticEngine?

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(
            name: "homefit/haptics",
            binaryMessenger: messenger
        )

        startEngine()

        channel.setMethodCallHandler { [weak self] (call, result) in
            guard let self = self else {
                result(FlutterMethodNotImplemented)
                return
            }

            switch call.method {
            case "lightImpact":
                self.playTransient(intensity: 0.4, sharpness: 0.5)
                result(nil)

            case "mediumImpact":
                self.playTransient(intensity: 0.65, sharpness: 0.6)
                result(nil)

            case "heavyImpact":
                self.playTransient(intensity: 1.0, sharpness: 0.8)
                result(nil)

            case "selectionClick":
                self.playTransient(intensity: 0.3, sharpness: 0.9)
                result(nil)

            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    /// Create and start the CHHapticEngine. Called once at init and
    /// again if the engine stops (e.g. app backgrounding).
    private func startEngine() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            return
        }

        do {
            let eng = try CHHapticEngine()
            eng.playsHapticsOnly = true

            // Auto-restart if the engine stops (backgrounding, etc.)
            eng.stoppedHandler = { [weak self] reason in
                // Re-start on next play attempt.
                self?.engine = nil
            }
            eng.resetHandler = { [weak self] in
                do {
                    try self?.engine?.start()
                } catch {
                    self?.engine = nil
                }
            }

            try eng.start()
            self.engine = eng
        } catch {
            self.engine = nil
        }
    }

    /// Fire a single transient haptic event.
    private func playTransient(intensity: Float, sharpness: Float) {
        // Lazy re-start if the engine was torn down.
        if engine == nil {
            startEngine()
        }
        guard let engine = engine else { return }

        do {
            let event = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
                ],
                relativeTime: 0
            )
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            // Non-fatal — haptic just doesn't fire this time.
        }
    }
}
