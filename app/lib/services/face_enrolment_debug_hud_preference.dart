import 'package:shared_preferences/shared_preferences.dart';

/// Per-device toggle controlling whether the face-enrolment debug HUD
/// renders on the enrolment camera viewfinder.
///
/// The HUD (added 2026-05-26) surfaces live pose telemetry directly on
/// screen — pose-event count, nil-axis count, last observed yaw +
/// pitch, current bucket target, and the Manhattan-sum delta — because
/// iOS profile-build NSLog/debugPrint output is filtered by the
/// unified-logging system and the Phase 1 POC `[FaceEnrolment-vision]`
/// lines never reach Console.app or idevicesyslog. Without on-screen
/// visibility we can't tell from the device whether the Vision pose
/// stream is alive, returning nil per frame, or returning values that
/// just don't match the expected targets.
///
/// **Default OFF.** Mirrors the [SafeModeDebugHudPreference] pattern —
/// the HUD is a diagnostic artefact, not a practitioner-facing feature.
/// The hidden Settings → Diagnostics toggle (revealed by the 7-tap
/// easter egg on the Version row) lets Carl (or anyone triaging a
/// face-enrolment regression) flip it on without rebuilding the app.
///
/// Stored in [SharedPreferences] under [_kKey]. Reads tolerate a
/// missing key (first launch on an existing install) by returning the
/// default.
class FaceEnrolmentDebugHudPreference {
  FaceEnrolmentDebugHudPreference._();

  static const String _kKey = 'face_enrolment_debug_hud_enabled';

  /// Default state for fresh installs. Ships OFF.
  static const bool defaultValue = false;

  static Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kKey) ?? defaultValue;
  }

  static Future<void> setEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kKey, value);
  }
}
