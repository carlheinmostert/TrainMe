import 'package:shared_preferences/shared_preferences.dart';

/// Per-device toggle controlling whether Safe Mode v2 photo + video
/// captures append per-face cosine-similarity scores into
/// `{Documents}/conversion_error.log`.
///
/// Why this exists (2026-05-26, Wave M41 self-recognition diagnostic):
/// the native Safe Mode matcher already logs per-face cosSim via
/// `os_log` to Console.app, but Console requires a Mac + cable + USB
/// trust. The conversion-error log is reachable in-app via the
/// long-press on the Studio "N failed" pill (and from the
/// Diagnostics screen action). Mirroring the per-face cosSim values
/// into that log gives Carl (and any practitioner triaging a
/// self-recognition issue) an in-app surface to confirm whether the
/// matcher saw the subject's face at the expected similarity OR
/// whether the embedding pipeline is misaligned (cosSim ≈ random).
///
/// **Default OFF.** Production captures should not spend disk on
/// diagnostic logs. The toggle is intended to be flipped on
/// temporarily while reproducing a recognition issue and turned
/// back off after the captures land.
///
/// Stored in [SharedPreferences] under [_kKey]. Reads tolerate a
/// missing key (first launch / pre-wave install) by returning the
/// default.
class SafeModeMatchLogPreference {
  SafeModeMatchLogPreference._();

  static const String _kKey = 'safe_mode_match_log_enabled';

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
