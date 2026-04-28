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

  /// Light impact — subtle tap.
  static Future<String> light() async {
    try {
      final r = await _channel.invokeMethod<String>('lightImpact');
      return r ?? 'no-result';
    } catch (e) {
      HapticFeedback.lightImpact();
      return 'fallback: $e';
    }
  }

  /// Medium impact — standard tap.
  static Future<String> medium() async {
    try {
      final r = await _channel.invokeMethod<String>('mediumImpact');
      return r ?? 'no-result';
    } catch (e) {
      HapticFeedback.mediumImpact();
      return 'fallback: $e';
    }
  }

  /// Heavy impact — strong thud.
  static Future<String> heavy() async {
    try {
      final r = await _channel.invokeMethod<String>('heavyImpact');
      return r ?? 'no-result';
    } catch (e) {
      HapticFeedback.heavyImpact();
      return 'fallback: $e';
    }
  }

  /// Selection click — crisp micro-tap.
  static Future<String> selection() async {
    try {
      final r = await _channel.invokeMethod<String>('selectionClick');
      return r ?? 'no-result';
    } catch (e) {
      HapticFeedback.selectionClick();
      return 'fallback: $e';
    }
  }

  /// Full diagnostic — returns a multi-line report from the native side
  /// including engine state + a test fire.
  static Future<String> diagnose() async {
    try {
      final r = await _channel.invokeMethod<String>('diagnose');
      return r ?? 'no-result';
    } catch (e) {
      return 'channel error: $e';
    }
  }
}
