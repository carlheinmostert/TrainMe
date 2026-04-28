import 'package:flutter/services.dart';

/// Native haptic feedback that works even while AVCaptureSession is active.
///
/// iOS suppresses Flutter's `HapticFeedback.*` calls while the mic is hot
/// (audio-contamination guard). This wrapper calls `UIImpactFeedbackGenerator`
/// / `UISelectionFeedbackGenerator` directly via a platform channel, which
/// bypasses the suppression.
///
/// Falls back silently on platforms without the native channel (e.g. Android
/// in the future) — the `invokeMethod` call simply throws a
/// `MissingPluginException` which is caught and swallowed.
class HomefitHaptics {
  static const _channel = MethodChannel('homefit/haptics');

  /// Light impact — subtle tap. Used for threshold cues (lock-zone
  /// enter/exit) and stop-recording confirmation.
  static Future<void> light() async {
    try {
      await _channel.invokeMethod('lightImpact');
    } catch (_) {
      // Fallback for platforms without the native channel.
      HapticFeedback.lightImpact();
    }
  }

  /// Medium impact — standard tap. Used for per-second recording ticks.
  static Future<void> medium() async {
    try {
      await _channel.invokeMethod('mediumImpact');
    } catch (_) {
      HapticFeedback.mediumImpact();
    }
  }

  /// Heavy impact — strong thud. Used for recording-start and lock-engage.
  static Future<void> heavy() async {
    try {
      await _channel.invokeMethod('heavyImpact');
    } catch (_) {
      HapticFeedback.heavyImpact();
    }
  }

  /// Selection click — crisp micro-tap. Used for shutter touch-down and
  /// toolbar button taps.
  static Future<void> selection() async {
    try {
      await _channel.invokeMethod('selectionClick');
    } catch (_) {
      HapticFeedback.selectionClick();
    }
  }
}
