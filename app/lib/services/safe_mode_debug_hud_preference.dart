import 'package:shared_preferences/shared_preferences.dart';

/// Per-device toggle controlling whether the Safe Mode debug HUD
/// renders on the camera viewfinder.
///
/// The HUD is a diagnostic overlay added 2026-05-22 to chase a
/// "Banner B not rendering on iPhone despite being inside the polygon"
/// bug. It surfaces the exact `SafeModeService` state + GPS sample +
/// match data in the top-right of the viewfinder so the practitioner
/// (or Carl) can read it without attaching a debugger.
///
/// **Default OFF.** Stack item M3 (2026-05-25) — the overlay should
/// not surface to practitioners by default; it is a debug artefact
/// from earlier diagnostic work. The hidden Settings → Debug toggle
/// lets Carl (or anyone helping with a Safe Mode regression) flip it
/// on without rebuilding the app.
///
/// Stored in [SharedPreferences] under [_kKey]. Reads tolerate a
/// missing key (first launch on an existing install) by returning the
/// default.
class SafeModeDebugHudPreference {
  SafeModeDebugHudPreference._();

  static const String _kKey = 'safe_mode_debug_hud_enabled';

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
