import 'package:shared_preferences/shared_preferences.dart';

/// Per-device toggle controlling whether each capture (photo + video) is
/// also written to the iOS Camera Roll alongside the app's own raw
/// archive.
///
/// **Default ON.** New installs auto-save on first capture, which is the
/// behaviour Carl asked for ("introduce a default behaviour which always
/// saves the original video or photo to the device camera roll"). The
/// practitioner can opt out via Settings → Session capture.
///
/// Stored in [SharedPreferences] under [_kKey]. Reads tolerate a missing
/// key (first launch on an existing install) by returning the default.
class CaptureAutoSavePreference {
  CaptureAutoSavePreference._();

  static const String _kKey = 'capture_auto_save_originals_to_photos';

  /// Default state for fresh installs. Ships ON.
  static const bool defaultValue = true;

  static Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kKey) ?? defaultValue;
  }

  static Future<void> setEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kKey, value);
  }
}
