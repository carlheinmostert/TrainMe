import 'dart:async';
import 'dart:developer' as dev;
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/exercise_capture.dart';
import '../models/session.dart';
import 'api_client.dart';
import 'local_storage_service.dart';
import 'path_resolver.dart';

/// Per-exercise prefetch state surfaced to the Studio card UI.
///
/// The card subscribes via [MediaPrefetchService.statusFor] →
/// [ValueNotifier]; the listener flips between [idle] (no prefetch
/// scheduled), [downloading] (HTTP in flight — overlay covers the
/// `Media missing` banner), [done] (file landed and SQLite updated),
/// and [failed] (HTTP / IO error — leaves the missing-media banner
/// visible so the practitioner can long-press to recapture).
enum MediaPrefetchStatus { idle, downloading, done, failed }

/// Singleton that downloads the line-drawing treatment for every
/// cloud-only exercise the practitioner opens in Studio.
///
/// ## Why this exists
///
/// Carl's iPhone sandbox is reset on every TestFlight bundle-ID rebrand,
/// so a fresh install hydrates sessions from the cloud (PR #190's
/// `_pullSessions` branch) but leaves their media files on Supabase
/// storage. Without local files, the `_MissingMediaBanner` red chip
/// fires on every card and the only recovery is a manual re-capture.
///
/// The service watches Studio session-open events and downloads the
/// public `media`-bucket line-drawing URL for each video / photo into
/// the same `{Documents}/converted/{exerciseId}_line{ext}` shape the
/// native conversion pipeline writes to. Once the file lands, the
/// service updates `exercises.converted_file_path` in SQLite, which
/// flips `exerciseHasMissingMedia` false — the banner clears, the
/// `MiniPreview` finds the file on disk, and playback works without
/// the practitioner doing anything.
///
/// ## Constraints
///
/// * **Line-drawing only.** B&W and Original treatments live in the
///   private `raw-archive` bucket and need signed URLs; those stay on
///   the existing `OriginalVideoService` on-treatment-switch download
///   path. The default Studio view uses the line-drawing treatment, so
///   covering only that one bucket is enough to make cards play.
///
/// * **Public bucket, no signing.** The `media` bucket has anon-read
///   on `SELECT *` for sharing plan URLs with clients; the same URL the
///   web player resolves works here. We hand it straight to dart:io
///   HttpClient.
///
/// * **Concurrency cap of 3.** A typical cloud-only session has 6-12
///   exercises; three parallel HTTP requests saturates a 4G connection
///   without head-of-line-blocking the rest of the queue.
///
/// * **Atomic file writes.** Bytes stream into a `.partial` sibling and
///   rename on success. A user leaving Studio mid-download discards
///   the partial via [cancelSession] without polluting the converted
///   directory.
///
/// * **Idempotent.** Re-entering Studio for the same session is a
///   no-op once every file is on disk — [_needsDownload] short-circuits
///   on a present-and-non-zero local file before we touch the network.
///
/// ## What it does NOT do
///
/// * Background prefetch on Home — only fires when Studio opens a
///   session.
/// * "Download all" button — there's no UI surface for it.
/// * Retry on failure — the practitioner long-presses to recapture
///   instead. Status flips to [MediaPrefetchStatus.failed] and stays.
class MediaPrefetchService {
  MediaPrefetchService._();
  static final MediaPrefetchService instance = MediaPrefetchService._();

  /// Concurrency cap for parallel HTTP downloads. Three is enough to
  /// keep a 4G uplink saturated without head-of-line blocking; bumping
  /// higher just risks Supabase storage 429 throttling on bulk pulls.
  static const int _maxParallel = 3;

  /// Per-exercise live status. Cards subscribe via
  /// [ValueListenableBuilder] and surface a `_DownloadingOverlay` when
  /// the value flips to [MediaPrefetchStatus.downloading].
  final Map<String, ValueNotifier<MediaPrefetchStatus>> _status =
      <String, ValueNotifier<MediaPrefetchStatus>>{};

  /// Sessions we've already kicked off prefetch for in this app run.
  /// Re-entering Studio for the same session is a no-op (the per-file
  /// `_needsDownload` short-circuit covers the cold restart case).
  final Set<String> _scheduledSessions = <String>{};

  /// In-flight FIFO queue across all sessions. Each entry holds the
  /// exercise id + URL + completer so multiple sessions can prefetch
  /// concurrently without re-implementing per-session worker pools.
  final List<_PrefetchTask> _queue = <_PrefetchTask>[];
  int _activeCount = 0;

  /// HTTP client reused across downloads. Lazy so test code can swap
  /// it via [debugSetClient].
  HttpClient? _http;

  /// API surface — read so tests can swap. Defaults to the singleton.
  ApiClient _api = ApiClient.instance;

  /// Test-only override for the HTTP client.
  @visibleForTesting
  void debugSetClient(HttpClient client) => _http = client;

  /// Test-only override for the API surface.
  @visibleForTesting
  void debugSetApi(ApiClient api) => _api = api;

  /// Returns a notifier for [exerciseId] — never null. Card consumers
  /// hold the reference for their lifetime; the value flips between
  /// the four [MediaPrefetchStatus] states as work progresses.
  ValueNotifier<MediaPrefetchStatus> statusFor(String exerciseId) {
    return _status.putIfAbsent(
      exerciseId,
      () => ValueNotifier<MediaPrefetchStatus>(MediaPrefetchStatus.idle),
    );
  }

  /// Inspect the current status without subscribing.
  MediaPrefetchStatus currentStatus(String exerciseId) =>
      _status[exerciseId]?.value ?? MediaPrefetchStatus.idle;

  /// Kick off a best-effort prefetch for every exercise on [session]
  /// that has a cloud line-drawing URL but no valid local file. Returns
  /// a [Future] that resolves when every queued download has finished
  /// (or failed). The Studio screen fires this fire-and-forget on init
  /// and doesn't wait — cards re-render via the per-exercise notifiers.
  ///
  /// [storage] is the shared [LocalStorageService] instance threaded
  /// through the widget tree (`main.dart` → AuthGate → screens). The
  /// service uses it to update `exercises.converted_file_path` when a
  /// download lands.
  ///
  /// [onExerciseDownloaded] fires once per successfully-downloaded
  /// exercise id — Studio re-reads the session from SQLite so the
  /// MiniPreview picks up the freshly-stamped `convertedFilePath` and
  /// the missing-media banner clears. Optional; tests pass null.
  ///
  /// First call per session in this app run is the authoritative one;
  /// subsequent calls are no-ops via [_scheduledSessions]. Cold-restart
  /// idempotence is handled by [_needsDownload] (file present + non-zero
  /// → skip).
  Future<void> prefetchSession(
    Session session, {
    required LocalStorageService storage,
    void Function(String exerciseId)? onExerciseDownloaded,
  }) async {
    if (_scheduledSessions.contains(session.id)) return;
    _scheduledSessions.add(session.id);

    // Filter to exercises that need a download. Rest periods are
    // skipped (no media); exercises whose local converted file already
    // exists are skipped.
    final candidates = session.exercises
        .where((e) => !e.isRest)
        .where(_needsDownload)
        .toList(growable: false);
    if (candidates.isEmpty) {
      dev.log(
        'prefetchSession session=${session.id} — nothing to download',
        name: 'MediaPrefetchService',
      );
      return;
    }

    // Need authoritative URLs. The cloud→local sync stamps
    // ExerciseCapture.lineDrawingUrl at the moment of pull, but local
    // SQLite read paths re-hydrate via fromMap which doesn't carry it
    // — so by the time Studio opens the session, it's null on every
    // exercise. Re-fetching the plan via get_plan_full is one RPC
    // round-trip and gives us the exact triplet the web player uses.
    final planResponse = await _api.getPlanFull(session.id);
    if (planResponse == null) {
      dev.log(
        'prefetchSession session=${session.id} — get_plan_full returned null',
        name: 'MediaPrefetchService',
      );
      // No URLs — every candidate goes to failed so the missing-media
      // banner stays put and the practitioner can long-press recapture.
      for (final ex in candidates) {
        _setStatus(ex.id, MediaPrefetchStatus.failed);
      }
      return;
    }
    final urlsById = _api.treatmentUrlsFromPlanResponse(planResponse);

    final tasks = <_PrefetchTask>[];
    for (final ex in candidates) {
      final urls = urlsById[ex.id];
      final lineUrl = urls?.lineDrawingUrl;
      if (lineUrl == null || lineUrl.isEmpty) {
        // No published line-drawing URL — nothing we can pull. Leave
        // the status idle (banner stays visible).
        continue;
      }
      final ext = _extensionFor(ex.mediaType, lineUrl);
      tasks.add(
        _PrefetchTask(
          sessionId: session.id,
          exerciseId: ex.id,
          url: lineUrl,
          targetRelativePath: p.join('converted', '${ex.id}_line$ext'),
          storage: storage,
          onDownloaded: onExerciseDownloaded,
        ),
      );
    }

    if (tasks.isEmpty) {
      dev.log(
        'prefetchSession session=${session.id} — '
        'all ${candidates.length} candidates lacked line_drawing_url',
        name: 'MediaPrefetchService',
      );
      return;
    }

    dev.log(
      'prefetchSession session=${session.id} — '
      'queued ${tasks.length} downloads (cap=$_maxParallel)',
      name: 'MediaPrefetchService',
    );

    // Mark each task as downloading up-front so the card UI flips to
    // the spinner overlay even before its turn in the FIFO comes up.
    for (final t in tasks) {
      _setStatus(t.exerciseId, MediaPrefetchStatus.downloading);
      _queue.add(t);
    }
    _drain();

    // Wait for every queued task to settle (success or failure) before
    // returning — the Studio screen ignores this future, but tests do.
    await Future.wait(tasks.map((t) => t.completer.future));
  }

  /// Discard any partial download for [sessionId] and reset its
  /// scheduled flag so a re-open re-tries. Called when the practitioner
  /// navigates away mid-download. Active HTTP requests are left to
  /// finish — `dart:io` HttpClient doesn't expose a clean cancel —
  /// but their bytes go to a `.partial` file that's overwritten next
  /// time. No-op when nothing is queued for the session.
  void cancelSession(String sessionId) {
    _scheduledSessions.remove(sessionId);
    // Drop queued (not-yet-active) tasks for this session. In-flight
    // tasks still finalise; their notifiers flip to done/failed
    // normally and the next prefetchSession call sees the file already
    // on disk via _needsDownload.
    _queue.removeWhere((t) {
      if (t.sessionId != sessionId) return false;
      _setStatus(t.exerciseId, MediaPrefetchStatus.idle);
      t.completer.complete();
      return true;
    });
  }

  // ------------------------------------------------------------------
  // Internals
  // ------------------------------------------------------------------

  bool _needsDownload(ExerciseCapture exercise) {
    final converted = exercise.absoluteConvertedFilePath;
    if (converted != null && converted.isNotEmpty) {
      final f = File(converted);
      if (f.existsSync() && f.lengthSync() > 0) return false;
    }
    final raw = exercise.absoluteRawFilePath;
    if (raw.isNotEmpty && !raw.startsWith('http')) {
      final f = File(raw);
      if (f.existsSync() && f.lengthSync() > 0) return false;
    }
    return true;
  }

  String _extensionFor(MediaType type, String url) {
    if (type == MediaType.photo) return '.jpg';
    if (type == MediaType.video) return '.mp4';
    // Fallback by URL — defensive against future media types.
    final lower = url.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return '.jpg';
    if (lower.endsWith('.png')) return '.png';
    return '.mp4';
  }

  void _setStatus(String exerciseId, MediaPrefetchStatus next) {
    final notifier = _status.putIfAbsent(
      exerciseId,
      () => ValueNotifier<MediaPrefetchStatus>(MediaPrefetchStatus.idle),
    );
    if (notifier.value != next) notifier.value = next;
  }

  void _drain() {
    while (_activeCount < _maxParallel && _queue.isNotEmpty) {
      final task = _queue.removeAt(0);
      _activeCount += 1;
      unawaited(
        _runTask(task).whenComplete(() {
          _activeCount = math.max(0, _activeCount - 1);
          _drain();
        }),
      );
    }
  }

  Future<void> _runTask(_PrefetchTask task) async {
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final absoluteTarget = p.join(docsDir.path, task.targetRelativePath);
      final partialTarget = '$absoluteTarget.partial';
      final dir = Directory(p.dirname(absoluteTarget));
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }

      // Defensive: if a stale .partial is hanging around, remove it so
      // we start clean.
      final partialFile = File(partialTarget);
      if (partialFile.existsSync()) {
        try {
          partialFile.deleteSync();
        } catch (_) {
          /* ignore */
        }
      }

      final client = _http ??= HttpClient();
      final request = await client.getUrl(Uri.parse(task.url));
      final response = await request.close();
      if (response.statusCode >= 400) {
        throw HttpException(
          'HTTP ${response.statusCode} downloading line drawing',
          uri: Uri.parse(task.url),
        );
      }

      final sink = partialFile.openWrite();
      try {
        await response.pipe(sink);
      } finally {
        await sink.flush();
        await sink.close();
      }

      // Atomic rename only if download succeeded. iOS file-system
      // rename inside the same volume is atomic.
      final finalFile = File(absoluteTarget);
      if (finalFile.existsSync()) {
        try {
          finalFile.deleteSync();
        } catch (_) {
          /* ignore */
        }
      }
      await partialFile.rename(absoluteTarget);

      // Persist the local path on the exercise row. Reload + copyWith
      // to preserve every other column (sets / preferred treatment /
      // notes / etc.) — saveExercise replaces the whole row.
      final fresh = await task.storage.getExerciseById(task.exerciseId);
      if (fresh != null) {
        final relative = PathResolver.toRelative(absoluteTarget);
        await task.storage.saveExercise(
          fresh.copyWith(convertedFilePath: relative),
        );
      } else {
        dev.log(
          '_runTask exerciseId=${task.exerciseId} — '
          'no local row to update; bytes still landed on disk',
          name: 'MediaPrefetchService',
        );
      }

      _setStatus(task.exerciseId, MediaPrefetchStatus.done);
      task.onDownloaded?.call(task.exerciseId);
      task.completer.complete();
    } catch (e, st) {
      dev.log(
        '_runTask failed exerciseId=${task.exerciseId}: $e',
        name: 'MediaPrefetchService',
        error: e,
        stackTrace: st,
      );
      _setStatus(task.exerciseId, MediaPrefetchStatus.failed);
      task.completer.complete();
    }
  }
}

class _PrefetchTask {
  _PrefetchTask({
    required this.sessionId,
    required this.exerciseId,
    required this.url,
    required this.targetRelativePath,
    required this.storage,
    this.onDownloaded,
  });

  final String sessionId;
  final String exerciseId;
  final String url;
  final String targetRelativePath;
  final LocalStorageService storage;
  final void Function(String exerciseId)? onDownloaded;
  final Completer<void> completer = Completer<void>();
}
