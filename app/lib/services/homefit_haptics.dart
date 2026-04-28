import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Native haptic feedback that works even while AVCaptureSession is active.
///
/// iOS suppresses Flutter's `HapticFeedback.*` calls while the mic is hot
/// (audio-contamination guard). This wrapper calls `CHHapticEngine` directly
/// via a platform channel, which bypasses the suppression entirely.
///
/// Wave 40.6 — added `kDebugMode` debug prints so haptic call sites are
/// visible in the console log during device QA.
///
/// Falls back silently on platforms without the native channel (e.g. Android
/// in the future) — the `invokeMethod` call simply throws a
/// `MissingPluginException` which is caught and swallowed.
class HomefitHaptics {
  static const _channel = MethodChannel('homefit/haptics');

  /// Light impact — subtle tap. Used for threshold cues (lock-zone
  /// enter/exit) and stop-recording confirmation.
  static Future<void> light() async {
    if (kDebugMode) debugPrint('HomefitHaptics: firing lightImpact');
    try {
      await _channel.invokeMethod('lightImpact');
    } catch (_) {
      // Fallback for platforms without the native channel.
      HapticFeedback.lightImpact();
    }
  }

  /// Medium impact — standard tap. Used for per-second recording ticks.
  static Future<void> medium() async {
    if (kDebugMode) debugPrint('HomefitHaptics: firing mediumImpact');
    try {
      await _channel.invokeMethod('mediumImpact');
    } catch (_) {
      HapticFeedback.mediumImpact();
    }
  }

  /// Heavy impact — strong thud. Used for recording-start and lock-engage.
  static Future<void> heavy() async {
    if (kDebugMode) debugPrint('HomefitHaptics: firing heavyImpact');
    try {
      await _channel.invokeMethod('heavyImpact');
    } catch (_) {
      HapticFeedback.heavyImpact();
    }
  }

  /// Selection click — crisp micro-tap. Used for shutter touch-down and
  /// toolbar button taps.
  static Future<void> selection() async {
    if (kDebugMode) debugPrint('HomefitHaptics: firing selectionClick');
    try {
      await _channel.invokeMethod('selectionClick');
    } catch (_) {
      HapticFeedback.selectionClick();
    }
  }
}
