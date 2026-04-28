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
    private var lastError: String?

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
                let ok = self.playTransient(intensity: 0.4, sharpness: 0.5)
                result(ok ? "ok" : self.lastError ?? "unknown")

            case "mediumImpact":
                let ok = self.playTransient(intensity: 0.65, sharpness: 0.6)
                result(ok ? "ok" : self.lastError ?? "unknown")

            case "heavyImpact":
                let ok = self.playTransient(intensity: 1.0, sharpness: 0.8)
                result(ok ? "ok" : self.lastError ?? "unknown")

            case "selectionClick":
                let ok = self.playTransient(intensity: 0.3, sharpness: 0.9)
                result(ok ? "ok" : self.lastError ?? "unknown")

            case "diagnose":
                result(self.diagnose())

            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    /// Create and start the CHHapticEngine. Called once at init and
    /// again if the engine stops (e.g. app backgrounding).
    private func startEngine() {
        let hw = CHHapticEngine.capabilitiesForHardware()
        guard hw.supportsHaptics else {
            lastError = "hardware does not support haptics"
            NSLog("[HomefitHaptics] supportsHaptics=false — device has no Taptic Engine")
            return
        }

        do {
            let eng = try CHHapticEngine()
            eng.playsHapticsOnly = true

            eng.stoppedHandler = { [weak self] reason in
                NSLog("[HomefitHaptics] engine stopped: reason=%d", reason.rawValue)
                self?.engine = nil
                self?.lastError = "engine stopped (reason \(reason.rawValue))"
            }
            eng.resetHandler = { [weak self] in
                NSLog("[HomefitHaptics] engine reset — restarting")
                do {
                    try self?.engine?.start()
                    NSLog("[HomefitHaptics] engine restarted OK")
                } catch {
                    NSLog("[HomefitHaptics] engine restart failed: %@", error.localizedDescription)
                    self?.engine = nil
                    self?.lastError = "restart failed: \(error.localizedDescription)"
                }
            }

            try eng.start()
            self.engine = eng
            self.lastError = nil
            NSLog("[HomefitHaptics] CHHapticEngine started OK")
        } catch {
            self.engine = nil
            self.lastError = "engine start failed: \(error.localizedDescription)"
            NSLog("[HomefitHaptics] engine start FAILED: %@", error.localizedDescription)
        }
    }

    /// Fire a single transient haptic event. Returns true if the event
    /// was delivered to the engine without error.
    @discardableResult
    private func playTransient(intensity: Float, sharpness: Float) -> Bool {
        if engine == nil {
            NSLog("[HomefitHaptics] engine nil — attempting restart")
            startEngine()
        }
        guard let engine = engine else {
            lastError = lastError ?? "engine is nil after restart attempt"
            NSLog("[HomefitHaptics] playTransient BAIL — engine still nil")
            return false
        }

        do {
            // Always re-start the engine before each play. CHHapticEngine
            // auto-stops after brief inactivity (~1-2s) to conserve power.
            // start() is idempotent — no-op if already running, restarts if
            // dormant. Without this, the second+ haptic in a session reports
            // success but the Taptic Engine hardware doesn't fire.
            try engine.start()

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
            NSLog("[HomefitHaptics] playTransient OK (intensity=%.2f)", intensity)
            lastError = nil
            return true
        } catch {
            lastError = "play failed: \(error.localizedDescription)"
            NSLog("[HomefitHaptics] playTransient FAILED: %@", error.localizedDescription)
            return false
        }
    }

    /// Diagnostic report — called from the Diagnostics screen via
    /// the `diagnose` method channel call.
    private func diagnose() -> String {
        let hw = CHHapticEngine.capabilitiesForHardware()
        var lines: [String] = []
        lines.append("supportsHaptics: \(hw.supportsHaptics)")
        lines.append("engine: \(engine != nil ? "alive" : "nil")")
        lines.append("lastError: \(lastError ?? "none")")

        // Try a test fire.
        let testOk = playTransient(intensity: 1.0, sharpness: 0.8)
        lines.append("testFire(heavy): \(testOk ? "OK" : "FAILED — \(lastError ?? "?")")")

        return lines.joined(separator: "\n")
    }
}
