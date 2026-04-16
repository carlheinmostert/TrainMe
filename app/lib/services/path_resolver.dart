import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Converts between relative (stored) and absolute (runtime) file paths.
///
/// Stored paths in the database are relative to the app's Documents directory
/// (e.g. `raw/video.mp4`). At runtime, [resolve] prepends the current
/// Documents directory to get a usable absolute path.
///
/// This survives app reinstalls — the container ID changes but the relative
/// path remains valid once files are re-created or migrated.
class PathResolver {
  static String? _docsDir;

  /// Must be called once at app startup (after WidgetsFlutterBinding).
  static Future<void> initialize() async {
    final dir = await getApplicationDocumentsDirectory();
    _docsDir = dir.path;
  }

  /// The current Documents directory path.
  static String get docsDir {
    assert(_docsDir != null, 'PathResolver.initialize() must be called first');
    return _docsDir!;
  }

  /// Convert a relative path to absolute. If the path is already absolute
  /// (legacy data), returns it as-is for backwards compatibility.
  static String resolve(String path) {
    if (path.isEmpty) return path;
    if (p.isAbsolute(path)) return path; // legacy absolute path
    return p.join(_docsDir!, path);
  }

  /// Convert an absolute path to relative (for database storage).
  /// If the path is not under the Documents directory, returns it as-is.
  static String toRelative(String absolutePath) {
    if (absolutePath.isEmpty) return absolutePath;
    if (_docsDir != null && absolutePath.startsWith(_docsDir!)) {
      return p.relative(absolutePath, from: _docsDir!);
    }
    return absolutePath; // can't relativize — store as-is
  }
}
