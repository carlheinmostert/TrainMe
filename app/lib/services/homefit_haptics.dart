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

  /// Light impact — subtle tap.
  static Future<String> light() => _invoke('lightImpact', HapticFeedback.lightImpact);

  /// Medium impact — standard tap.
  static Future<String> medium() => _invoke('mediumImpact', HapticFeedback.mediumImpact);

  /// Heavy impact — strong thud.
  static Future<String> heavy() => _invoke('heavyImpact', HapticFeedback.heavyImpact);

  /// Selection click — crisp micro-tap.
  static Future<String> selection() => _invoke('selectionClick', HapticFeedback.selectionClick);

  /// Full diagnostic — returns a multi-line report from the native side
  /// including engine state + a test fire.
  static Future<String> diagnose() => _invoke('diagnose', null);

  // ---------------------------------------------------------------------------

  /// Invokes [method] on the native haptics channel. On failure, calls [fallback]
  /// (if provided) and returns a 'fallback:' string. [fallback] is null only
  /// for the diagnostics call, which has no meaningful Flutter-level fallback.
  static Future<String> _invoke(String method, Future<void> Function()? fallback) async {
    try {
      final r = await _channel.invokeMethod<String>(method);
      return r ?? 'no-result';
    } catch (e) {
      if (fallback != null) await fallback();
      return fallback != null ? 'fallback: $e' : 'channel error: $e';
    }
  }
}
