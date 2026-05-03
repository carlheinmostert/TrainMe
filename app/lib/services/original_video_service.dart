import 'dart:async';
import 'dart:developer' as dev;
import 'dart:io';
import 'dart:ui' show Rect;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:share_plus/share_plus.dart';

import '../models/exercise_capture.dart';
import 'api_client.dart';

/// Outcome of [OriginalVideoService.resolveSource] — a local file path
/// we can hand directly to the saver, a remote-download path (signed URL
/// for the private `raw-archive` bucket), or null when no source is
/// available.
class ResolvedOriginalSource {
  final File? localFile;
  final String? remoteUrl;

  const ResolvedOriginalSource._({this.localFile, this.remoteUrl});

  /// Source is the local 720p H.264 raw archive — fast path, no network.
  factory ResolvedOriginalSource.local(File file) =>
      ResolvedOriginalSource._(localFile: file);

  /// Source is a signed URL pointing at the private `raw-archive`
  /// bucket. Caller downloads it to a temp file before handing to the
  /// saver / share sheet.
  factory ResolvedOriginalSource.remote(String url) =>
      ResolvedOriginalSource._(remoteUrl: url);

  bool get isEmpty => localFile == null && remoteUrl == null;
}

/// Outcome of a save-to-photos attempt.
enum SaveToPhotosResult {
  /// Video saved to the Camera Roll.
  saved,

  /// iOS returned permission denied / limited without add permission.
  /// UI should surface the "open Settings" hint.
  permissionDenied,

  /// Source file unavailable (local archive missing AND signed-URL
  /// fallback failed). UI shows "Original video no longer available —
  /// recapture to re-archive."
  sourceMissing,

  /// Unexpected failure. UI shows a generic retry message.
  failed,
}

/// Glue between the Studio exercise card's long-press "Download
/// original" action and the three sinks the action sheet exposes: save
/// to Camera Roll, share via the native share sheet, cancel. Abstracts:
///
///   1. **Source resolution** — prefer the local raw archive
///      (`{Documents}/archive/{exerciseId}.mp4`), fall through to a
///      fresh signed URL from the private `raw-archive` bucket, fall
///      through to null when neither is available.
///   2. **Network download** — pulls a signed URL to a temp file via
///      `dart:io` HttpClient so the downstream saver / sharer can stay
///      file-based.
///   3. **Photos permission + write** — wraps `photo_manager`'s
///      `requestPermissionExtend` + `editor.saveVideo` so the card
///      doesn't have to know about PHPhotoLibrary.
///
/// Stateless (callers own the bottom-sheet lifecycle); the service is
/// a plain function collection hung off a singleton for test-stubbing
/// symmetry with [ApiClient].
class OriginalVideoService {
  OriginalVideoService._();

  static final OriginalVideoService instance = OriginalVideoService._();

  /// Decide which source to use for [exercise], given the plan's
  /// practice / plan ids so a remote-fallback signed URL can be built.
  ///
  /// The local archive is preferred — zero network, zero latency, and
  /// no consent gate (this is the practitioner's own capture). If it's
  /// missing / past its 90-day purge, signs a fresh URL from the
  /// private `raw-archive` bucket. Returns an empty [ResolvedOriginalSource]
  /// if neither is available (legacy captures pre-archive pipeline, or
  /// the vault signing helper returned NULL).
  ///
  /// [practiceId] and [planId] may be null for legacy local-only
  /// sessions that never associated with a practice — in that case the
  /// signed-URL fallback is skipped and the caller falls through to
  /// source-missing if the local archive isn't there either.
  ///
  /// Media-type-aware: video exercises probe `absoluteArchiveFilePath`
  /// and sign `.mp4` paths; photo exercises probe `absoluteRawFilePath`
  /// (the raw colour JPG IS the local "archive" for photos — there's no
  /// separate raw-vs-archive split like there is for videos) and sign
  /// `.jpg` paths against the same `raw-archive` bucket.
  Future<ResolvedOriginalSource> resolveSource({
    required ExerciseCapture exercise,
    String? practiceId,
    String? planId,
  }) async {
    final isPhoto = exercise.mediaType == MediaType.photo;

    // 1. Local probe — fastest path.
    //    Videos: `{Documents}/archive/{exerciseId}.mp4` (90-day archive).
    //    Photos: the raw colour JPG itself, since photos don't have a
    //    separate compressed archive — the on-disk raw IS the source for
    //    both Original + B&W treatments (B&W applies a CSS / ColorFiltered
    //    grayscale on top of the same file).
    if (isPhoto) {
      final rawPath = exercise.absoluteRawFilePath;
      if (rawPath.isNotEmpty && !rawPath.startsWith('http')) {
        final lower = rawPath.toLowerCase();
        final isImage = lower.endsWith('.jpg') ||
            lower.endsWith('.jpeg') ||
            lower.endsWith('.png') ||
            lower.endsWith('.heic');
        if (isImage) {
          final file = File(rawPath);
          if (await file.exists()) {
            return ResolvedOriginalSource.local(file);
          }
        }
      }
    } else {
      final localPath = exercise.absoluteArchiveFilePath;
      if (localPath != null) {
        final file = File(localPath);
        if (await file.exists()) {
          return ResolvedOriginalSource.local(file);
        }
      }
    }

    // 2. Signed URL fallback. Requires practice + plan context.
    if (practiceId != null && planId != null) {
      try {
        final url = await ApiClient.instance.signRawArchiveUrl(
          practiceId: practiceId,
          planId: planId,
          exerciseId: exercise.id,
          extension: isPhoto ? 'jpg' : 'mp4',
        );
        if (url != null && url.isNotEmpty) {
          return ResolvedOriginalSource.remote(url);
        }
      } catch (e) {
        dev.log(
          'OriginalVideoService.resolveSource signed-URL failed: $e',
          name: 'OriginalVideoService',
        );
      }
    }

    // 3. Nothing to serve.
    return const ResolvedOriginalSource._();
  }

  /// Download [url] to a temp file under [getTemporaryDirectory]. Used
  /// when the source is a signed URL (legacy captures, cleared local
  /// archive). Returns the resulting [File] on success; throws on
  /// network / IO errors (caller wraps).
  ///
  /// The temp file name is stable per-exercise so repeated taps within
  /// a session don't pile up orphan temp files — iOS cleans the temp
  /// dir on its own schedule anyway.
  Future<File> downloadToTemp({
    required String url,
    required String exerciseId,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final target = File(p.join(tempDir.path, 'original_$exerciseId.mp4'));
    final httpClient = HttpClient();
    try {
      final request = await httpClient.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode >= 400) {
        throw HttpException(
          'HTTP ${response.statusCode} downloading original video',
          uri: Uri.parse(url),
        );
      }
      final sink = target.openWrite();
      await response.pipe(sink);
      return target;
    } finally {
      httpClient.close(force: false);
    }
  }

  /// Save [file] to the user's iOS Camera Roll via PHPhotoLibrary.
  ///
  /// Handles the first-time `addOnly` permission prompt via
  /// [PhotoManager.requestPermissionExtend]. On denial returns
  /// [SaveToPhotosResult.permissionDenied] so the caller can guide the
  /// user to Settings; on other failures returns [SaveToPhotosResult.failed].
  ///
  /// Routes to `saveVideo` for `.mp4` / `.mov` files and
  /// `saveImageWithPath` for image extensions (`.jpg`, `.jpeg`, `.png`,
  /// `.heic`). Files with an unrecognised extension fall through to
  /// `saveVideo` for backwards compatibility (the original call sites
  /// only ever passed `.mp4`).
  Future<SaveToPhotosResult> saveToPhotos(File file) async {
    try {
      final state = await PhotoManager.requestPermissionExtend(
        requestOption: const PermissionRequestOption(
          iosAccessLevel: IosAccessLevel.addOnly,
        ),
      );
      // IosAccessLevel.addOnly satisfies either authorized or limited.
      // On denied / restricted / notDetermined-that-resolved-to-deny
      // the practitioner has explicitly said no; surface the Settings
      // hint.
      if (!state.hasAccess) {
        return SaveToPhotosResult.permissionDenied;
      }

      final ext = p.extension(file.path).toLowerCase();
      final isImage = ext == '.jpg' ||
          ext == '.jpeg' ||
          ext == '.png' ||
          ext == '.heic';
      if (isImage) {
        await PhotoManager.editor.saveImageWithPath(
          file.path,
          title: p.basename(file.path),
        );
      } else {
        await PhotoManager.editor.saveVideo(
          file,
          title: p.basename(file.path),
        );
      }
      return SaveToPhotosResult.saved;
    } catch (e) {
      dev.log(
        'OriginalVideoService.saveToPhotos error: $e',
        name: 'OriginalVideoService',
      );
      return SaveToPhotosResult.failed;
    }
  }

  /// Open the native iOS share sheet with [file] as an mp4 [XFile].
  ///
  /// [sharePositionOrigin] is the required CGRect for iPad popover
  /// presentation (simulator + iPad both crash without it per the
  /// Share.share() simulator note in CLAUDE.md). Callers pass the
  /// origin of the triggering widget.
  Future<void> share({
    required File file,
    Rect? sharePositionOrigin,
  }) async {
    await Share.shareXFiles(
      [XFile(file.path, mimeType: 'video/mp4')],
      sharePositionOrigin: sharePositionOrigin,
    );
  }
}
