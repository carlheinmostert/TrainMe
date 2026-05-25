import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/painting.dart' show decodeImageFromList;
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart' as vt;
import '../config.dart';
import '../models/exercise_capture.dart';
import 'api_client.dart';
import 'face_embedding_service.dart';
import 'local_storage_service.dart';
import 'loud_swallow.dart';
import 'path_resolver.dart';
import 'safe_mode.dart';
import 'safe_mode_service.dart';

/// Maximum tolerated Vision miss-rate (0.0–1.0) for a Safe Mode
/// capture before [ConversionService] rejects it with
/// [SafeModeRejection] (Safe Mode completion wave, 2026-05-21).
///
/// Below the threshold the capture is kept; gap frames in the safe
/// variant are soft-skipped (the underlying converter pumps through
/// without Safe Mode compositing on misses). Above the threshold the
/// converter discards both the safe variant and the line drawing —
/// the user-facing surface treats this as a failed capture and
/// removes the row.
const double kSafeModeMaxMissRate = 0.05;

/// Captures where Vision detected ZERO humans in every frame are
/// accepted as no-PII (empty room, equipment, outdoor landscape) — the
/// 2026-05-25 "accept zero-detection" relaxation. The 100% miss case
/// is structurally distinct from a 50% middle-band miss: an empty
/// frame contains nothing identifiable by definition, while a partial
/// miss means Vision was struggling on a frame that probably did
/// contain a human.
///
/// The `>=` comparison (vs `== 1.0`) tolerates floating-point jitter
/// in the native miss-rate calculation. The native pipeline computes
/// missed-frame-count ÷ total-frame-count; with hundreds of frames
/// the result can land at 0.99999... due to division rounding even
/// when every single frame missed.
///
/// Acceptance shape: when this branch fires, the safe variant file
/// (a coral-painted copy of an empty frame — trivial overhead) is
/// deleted and the canonical-source path falls through to the raw
/// capture, just as it would for a Safe-Mode-off capture. One
/// telemetry row writes to `capture_audit_events` via
/// `record_safe_mode_capture_event` so practice owners can audit the
/// accept-empty rate in production.
const double kSafeModeFullEmptyThreshold = 0.999;

/// Solo-face cosine-similarity floor passed to `applySafeModeV2ToPhoto`.
///
/// Semantic shift (2026-05-24 hybrid pick-highest workshop): this value
/// is NO LONGER an absolute decision boundary. It is only consulted in
/// the solo-face branch — i.e. when exactly one face is detected in the
/// frame, we accept it as the subject UNLESS its cosSim falls below
/// this floor. The floor catches the bystander-alone-no-client edge
/// case (random face in frame, no client present) without rejecting
/// legitimate solo selfies at sideways angles (Carl's IMG_1375 was
/// solo, sideways, cosSim ~0.35 — under the old absolute-0.5 gate it
/// dropped into no-subject mode and got 17.7% blurred; under the new
/// rule it's identified via the solo branch and stays sharp).
///
/// For frames with 2+ faces, the pipeline uses a relative pick — the
/// face with the highest cosSim wins, no absolute gate. The floor
/// does not apply in the multi-face branch.
///
/// 0.10 is well below any legitimate same-person cosSim (Carl's worst
/// was 0.25) but above the typical random-face cosSim cluster
/// (0.15-0.40 for unrelated faces against the enrolled embedding).
const double kSafeModeV2SoloFloor = 0.10;

/// Multi-reference cosSim floor for Safe Mode v2 enrolment built via
/// the rotating-head Face-ID-style sweep (see
/// `docs/specs/2026-05-24-safe-mode-v2-multi-reference-enrolment.md`).
///
/// Semantically distinct from [kSafeModeV2SoloFloor] — that constant is
/// the solo-face floor (consulted only when exactly one face is
/// detected in a frame). This constant is the post-multi-reference
/// solo-floor: once a client has been enrolled across multiple pose
/// references, the per-face cosSim is the MAX across all stored
/// references, which lifts the worst-case subject-self score from
/// ~0.25 (single frontal reference) to ~0.70 (well-enrolled set).
/// 0.55 sits comfortably between the worst-enrolled subject self-score
/// and the highest observed bystander score (0.36).
///
/// PLUMBING NOTE (Wave-BC 2026-05-24): this constant is declared but
/// NOT yet consumed by [_resolveSafeModeV2Threshold]. The native
/// `applySafeModeV2ToPhoto` solo-floor branch uses whatever threshold
/// the caller supplies, and during the back-compat window the cached
/// embedding is still the legacy single-reference vector. Wave-D
/// (enrolment screen + flow) switches the resolver to consult this
/// constant whenever the bound client's enrolment slot count is >= 2
/// (i.e. the client was re-enrolled via the new sweep flow). Until
/// then this constant is referenced only by future code; no behaviour
/// change in this PR.
const double kSafeModeV2MultiRefThreshold = 0.55;

/// SharedPreferences key for the debug-tuning sheet's persisted
/// solo-floor override (2026-05-23 debug-tuning wave; semantics
/// updated 2026-05-24 to solo-floor). When set, both
/// [ConversionService._convert]'s photo Safe Mode pass and
/// [ConversionService.reprocessSafeMode] read this in preference to
/// [kSafeModeV2SoloFloor] (an explicit `thresholdOverride` argument
/// still wins over both). Cleared by the sheet's Reset button. Debug
/// + staging only — release builds never write it because the sheet
/// is gated by `debugTuningGateActive()`.
///
/// The pref key string is preserved across the rename for back-compat
/// with already-persisted values on existing staging devices.
const String kSafeModeV2ThresholdOverridePrefKey =
    'safe_mode_v2_threshold_override';

/// Resolve the solo-floor to pass into `applySafeModeV2ToPhoto`:
///   1. explicit caller [override] (the tuning sheet's live slider)
///   2. SharedPreferences-persisted override (the sheet's "Save as
///      new default" — auto-applied to future captures)
///   3. compile-time [kSafeModeV2SoloFloor] default
Future<double> _resolveSafeModeV2Threshold(double? override) async {
  if (override != null) return override;
  try {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getDouble(kSafeModeV2ThresholdOverridePrefKey);
    if (stored != null) return stored;
  } catch (_) {
    // Fall through to the compile-time default.
  }
  return kSafeModeV2SoloFloor;
}

/// Resolve the subject face embedding(s) for [clientId] (Safe Mode v2
/// Wave-D, 2026-05-24).
///
/// Preference order:
///   1. Multi-reference cache via [LocalStorageService.getCachedClientFaceEmbeddings].
///      Returns 3-8 vectors when the client has been enrolled via the
///      Face-ID-style sweep flow.
///   2. Legacy single-embedding cache via [FaceEmbeddingService.getEmbedding].
///      Covers clients enrolled before the multi-reference wave landed —
///      they have one row at slot_index=0 mirrored into the legacy
///      `clients.face_embedding` column during back-compat.
///
/// Empty list = unenrolled / consent withdrawn / cold-start cache miss.
/// Caller decides whether that's fatal (Safe Mode active → reject) or
/// fine (Safe Mode off → no embedding needed).
///
/// [storage] is the conversion service's [LocalStorageService] handle —
/// passed in rather than a singleton lookup so test fixtures can swap
/// in an in-memory DB without monkey-patching globals.
Future<List<Uint8List>> _resolveSubjectEmbeddings(
  LocalStorageService storage,
  String? clientId,
) async {
  if (clientId == null || clientId.isEmpty) return const [];
  // Step 1 — multi-reference slot bundle (preferred).
  try {
    final slots =
        await storage.getCachedClientFaceEmbeddings(clientId: clientId);
    if (slots.isNotEmpty) {
      final filtered = slots
          .where((s) => s.embedding.isNotEmpty)
          .map((s) => s.embedding)
          .toList(growable: false);
      if (filtered.isNotEmpty) return filtered;
    }
  } catch (e) {
    debugPrint(
      '_resolveSubjectEmbeddings: multi-ref read failed — '
      'falling back to legacy single embedding ($e)',
    );
  }
  // Step 2 — legacy single-embedding cache.
  final legacy = FaceEmbeddingService.instance.getEmbedding(clientId);
  if (legacy != null && legacy.isNotEmpty) {
    return <Uint8List>[legacy];
  }
  return const [];
}

/// Reason discriminator for [SafeModeRejection]. The capture screen
/// branches its toast copy on this so the user knows whether a
/// steadier shot will help or whether the embedding needs to be
/// re-prepared.
enum SafeModeRejectionReason {
  /// Vision miss-rate exceeded [kSafeModeMaxMissRate] — the native
  /// pass couldn't track the subject through enough frames. A
  /// steadier shot or better lighting usually resolves.
  missRateExceeded,

  /// Safe Mode v2 needs the bound client's cached face embedding to
  /// identify the subject vs bystanders. If conversion runs and the
  /// cache is empty (app killed between capture and conversion,
  /// embedding evicted, etc) there's no safe variant we can produce —
  /// uploading the un-blurred raw archive would breach the privacy
  /// contract, so we reject the capture instead.
  missingFaceEmbedding,
}

/// Thrown by [ConversionService] when a Safe Mode capture cannot be
/// completed safely. The capture screen listens via
/// [ConversionService.onSafeModeRejection] and removes the exercise
/// row + shows an inline coral-bordered toast.
///
/// Not a control-flow shortcut — this is a real bubble for an error
/// condition the user must be told about. Per
/// `feedback_no_exception_control_flow`, the upstream catch must
/// surface the rejection to the user, NOT swallow it as "success".
///
/// Per `feedback_no_silent_fallbacks`, the missing-embedding branch
/// MUST NOT fall through to a "publish without blurring" mode — the
/// practitioner expects bystanders to be coral'd and silently
/// degrading erodes that trust.
class SafeModeRejection implements Exception {
  final String exerciseId;
  final double missRate;
  final SafeModeRejectionReason reason;
  const SafeModeRejection(
    this.exerciseId,
    this.missRate, {
    this.reason = SafeModeRejectionReason.missRateExceeded,
  });
  @override
  String toString() =>
      'SafeModeRejection($exerciseId, reason=$reason, missRate='
      '${(missRate * 100).toStringAsFixed(1)}%)';
}

/// Payload emitted on [ConversionService.onExerciseRemoved] after the
/// service deletes an exercise row from SQLite (today: only the Safe
/// Mode rejection cleanup path). Carries the exercise id (the
/// authoritative pivot for list-screen removal) plus the last-known
/// [ExerciseCapture] so listeners can scrub sibling state (session
/// position, focus offsets) without an additional SQLite read.
///
/// The exercise row IS already gone by the time this fires — the
/// payload is a snapshot, not a live reference.
class ExerciseRemoval {
  final String exerciseId;
  final ExerciseCapture? exercise;
  final String reason;
  const ExerciseRemoval({
    required this.exerciseId,
    required this.reason,
    this.exercise,
  });
  @override
  String toString() => 'ExerciseRemoval($exerciseId, reason=$reason)';
}

/// Background line drawing conversion service.
///
/// Architecture: Layer 2 of the three decoupled async layers.
/// Capture writes a raw file to disk and queues it here. This service
/// processes items sequentially in the background, never blocking the UI.
/// The converted file writes to disk alongside the raw original.
///
/// Listeners (e.g. the session strip UI) are notified via [onConversionUpdate]
/// whenever an exercise's status changes, so thumbnails can crossfade from
/// raw to line-drawing.
///
/// On app restart, call [restoreQueue] to re-queue any captures that were
/// mid-conversion or still pending when the app was killed.
class ConversionService extends ChangeNotifier {
  final LocalStorageService _storage;

  // ---------------------------------------------------------------------------
  // Singleton — lives for the entire app lifetime. Never disposed.
  // ---------------------------------------------------------------------------

  static ConversionService? _instance;

  /// Access the singleton instance. Must call [initialize] first.
  static ConversionService get instance {
    assert(_instance != null,
        'ConversionService.initialize() must be called before accessing instance');
    return _instance!;
  }

  /// Create and store the singleton. Call once from main().
  static ConversionService initialize(LocalStorageService storage) {
    _instance = ConversionService._(storage: storage);
    return _instance!;
  }

  /// Test-only factory — builds a [ConversionService] without touching
  /// the singleton field. Used by `app/test/services/` regression tests
  /// to drive the stream + cleanup contract against an in-memory
  /// [LocalStorageService] without colliding with whatever real
  /// instance an integration test may have spun up. Production code
  /// must continue to call [initialize] / [instance].
  @visibleForTesting
  factory ConversionService.forTest(LocalStorageService storage) {
    return ConversionService._(storage: storage);
  }

  /// Native iOS platform channel for video conversion.
  /// Uses AVAssetReader/Writer for H.264/265 I/O and Accelerate for
  /// pixel processing -- bypasses OpenCV's codec limitations on iOS.
  static const _videoChannel = MethodChannel('com.raidme.video_converter');

  /// Simple native frame extraction channel (AVAssetImageGenerator).
  static const _thumbChannel = MethodChannel('com.raidme.native_thumb');

  /// The processing queue. Items are processed FIFO.
  final List<ExerciseCapture> _queue = [];

  /// Whether the processor loop is currently running.
  bool _processing = false;

  /// Stream controller for individual conversion updates.
  final _updateController = StreamController<ExerciseCapture>.broadcast();

  /// Fires each time an exercise's conversion status changes.
  Stream<ExerciseCapture> get onConversionUpdate => _updateController.stream;

  /// Self-trainer wave PR #5 (2026-05-25) — in-memory cache of the
  /// caller's own face embedding (from `practitioners.face_embedding`).
  ///
  /// `null` after fetch = the user has not registered a self-face (no
  /// reference to compare against → skip verification, leave
  /// `self_verified` at NULL). A non-null populated list is reused
  /// across captures within a session to avoid re-fetching the RPC for
  /// every exercise.
  ///
  /// Reset by [resetSelfFaceEmbeddingCache] so the next capture
  /// re-fetches — called by the Settings → Public profile flow when
  /// the user (re-)registers their face.
  List<double>? _cachedSelfFaceEmbedding;
  bool _selfFaceEmbeddingFetched = false;

  /// Stream controller for Safe Mode rejections (Safe Mode completion
  /// wave, 2026-05-21). Captures whose Vision miss-rate exceeded
  /// [kSafeModeMaxMissRate] emit here AFTER the row has been deleted
  /// from SQLite. Listeners (the capture screen) show a coral toast.
  /// Separate stream so a `Stream<ExerciseCapture>` typing doesn't
  /// need to carry exception sentinels.
  final _rejectionController =
      StreamController<SafeModeRejection>.broadcast();

  /// Fires when a Safe Mode capture was rejected (>5% Vision miss-rate)
  /// and the exercise row was removed. Listeners show the inline
  /// rejection toast on the capture screen.
  Stream<SafeModeRejection> get onSafeModeRejection =>
      _rejectionController.stream;

  /// Stream controller for exercise removals (2026-05-25 — accept zero-
  /// detection wave). Carries the exercise id (and the row contents at
  /// the moment of removal) so list-rendering screens can drop the card
  /// from their in-memory snapshot in the same paint as the SQLite
  /// delete. Without this, [onSafeModeRejection] fires the toast on the
  /// capture screen but Studio / ClientSessions keep showing a stuck
  /// converting-spinner card until the next parent refresh — the
  /// "orphan after rejection" symptom Carl reported.
  ///
  /// Production listeners (Studio, ClientSessions) treat the event as
  /// "remove this exercise from your in-memory list". The id is the
  /// authoritative pivot; the payload carries the last-known
  /// [ExerciseCapture] in case a listener needs metadata (session id,
  /// position) to clean up sibling state.
  final _removalController =
      StreamController<ExerciseRemoval>.broadcast();

  /// Fires when an exercise row was removed from SQLite as part of the
  /// Safe Mode rejection cleanup. Studio + ClientSessions listen here
  /// to drop the card from their in-memory list synchronously.
  Stream<ExerciseRemoval> get onExerciseRemoved => _removalController.stream;

  ConversionService._({required LocalStorageService storage})
      : _storage = storage {
    // Listen for progress updates from the native video converter.
    _videoChannel.setMethodCallHandler(_handleNativeCallback);
  }

  /// Handle callbacks from the native platform channel (e.g. progress).
  Future<dynamic> _handleNativeCallback(MethodCall call) async {
    if (call.method == 'onProgress') {
      final args = call.arguments as Map?;
      if (args != null) {
        debugPrint(
            'Native video conversion progress: '
            '${args["framesProcessed"]}/${args["totalFrames"]} frames');
      }
    }
  }

  /// Queue a capture for line drawing conversion.
  /// Rest periods are skipped — they have no media to convert.
  void queueConversion(ExerciseCapture exercise) {
    if (exercise.isRest) return;
    _queue.add(exercise);
    _processQueue();
  }

  /// Re-queue a previously-failed (or stuck) capture by resetting its
  /// status to `pending` and pushing it back on the FIFO queue.
  ///
  /// Used by the Home screen's "N failed" pill so the practitioner can
  /// retry a botched conversion without leaving the session list. Rest
  /// periods are still skipped.
  Future<void> retry(ExerciseCapture exercise) async {
    if (exercise.isRest) return;
    final reset = exercise.copyWith(
      conversionStatus: ConversionStatus.pending,
    );
    await _storage.saveExercise(reset);
    if (!_updateController.isClosed) {
      _updateController.add(reset);
    }
    notifyListeners();
    _queue.add(reset);
    _processQueue();
  }

  /// On app restart, reload any unfinished conversions and re-queue them.
  ///
  /// Crash-recovery guard (2026-05-22): a row in `converting` state at app
  /// launch means the previous process died mid-conversion. Re-running it
  /// on the same code path will almost certainly crash again (the original
  /// trigger for this guard was the Safe Mode `CIFilter` force-unwrap that
  /// boot-looped the app in PR #423). Before re-enqueuing we demote every
  /// `converting` row to `failed` so the user sees the "N failed" pill and
  /// can manually retry from a known-good state. Only rows still in
  /// `pending` are re-enqueued for automatic processing.
  ///
  /// The error is appended to the existing `{Documents}/conversion_error.log`
  /// sink (long-press-on-failed-pill surfaces it via PR #213) — we don't
  /// have a per-row error column in SQLite so the log file is the
  /// canonical diagnostic trail.
  Future<void> restoreQueue() async {
    final unconverted = await _storage.getUnconvertedExercises();
    final recoveredFromCrash = <ExerciseCapture>[];
    final pendingOnly = <ExerciseCapture>[];
    for (final exercise in unconverted) {
      if (exercise.conversionStatus == ConversionStatus.converting) {
        recoveredFromCrash.add(exercise);
      } else {
        pendingOnly.add(exercise);
      }
    }

    for (final stuck in recoveredFromCrash) {
      final demoted = stuck.copyWith(
        conversionStatus: ConversionStatus.failed,
      );
      try {
        await _storage.saveExercise(demoted);
      } catch (e) {
        debugPrint('restoreQueue: saveExercise(failed) for ${stuck.id} '
            'failed: $e');
      }
      if (!_updateController.isClosed) {
        _updateController.add(demoted);
      }
      // Append a single-line entry to the conversion error log so the
      // long-press-on-failed-pill log reader surfaces the recovery to
      // the practitioner.
      try {
        final logDir = await getApplicationDocumentsDirectory();
        final logFile = File(p.join(logDir.path, 'conversion_error.log'));
        final ts = DateTime.now().toIso8601String();
        await logFile.writeAsString(
          '$ts [RECOVERY ${stuck.id}] Aborted by prior crash on init\n',
          mode: FileMode.append,
        );
      } catch (_) {
        // Best-effort; the demote already happened.
      }
    }
    if (recoveredFromCrash.isNotEmpty) {
      notifyListeners();
    }

    for (final exercise in pendingOnly) {
      _queue.add(exercise);
    }
    if (_queue.isNotEmpty) {
      _processQueue();
    }
  }

  /// The processing loop. Runs until the queue is drained.
  ///
  /// Wrapped in a top-level try/finally so `_processing` always resets to
  /// false on exit, even if an unexpected exception escapes the per-item
  /// catch (e.g. a SQLite write lock error hitting `saveExercise` before
  /// the inner try begins). Without this guard the singleton could get
  /// stuck `_processing=true` forever, and every future `queueConversion`
  /// call would early-return at line 129 — leaving the last item in a
  /// capture burst wedged until the app restarts.
  Future<void> _processQueue() async {
    if (_processing) return;
    _processing = true;

    try {
    while (_queue.isNotEmpty) {
      final queued = _queue.removeAt(0);

      // Re-read the row from SQLite before stamping `converting`. The queue
      // holds the in-memory ExerciseCapture as it was at queueConversion()
      // time — for fresh captures that's the pre-default object (reps/sets
      // still null). The first saveExercise() in capture / studio flows
      // routes that object through ExerciseCapture.withPersistenceDefaults()
      // and writes sets=3 / reps=10 / interSetRestSeconds=15 to the row.
      // If we copyWith() off the in-memory object here we'd clobber those
      // defaulted columns back to null on every conversion, and the
      // publish path (which reads from SQLite) would ship the nulls to
      // Supabase. Reading fresh inherits the defaulted columns.
      //
      // Round 2 — use [getExerciseById] so child sets come along for the
      // ride. The previous bare fromMap re-read returned an exercise
      // with `sets: const []`, then saveExercise(converting) called
      // `_replaceExerciseSetsTxn(toPersist.id, toPersist.sets)` which
      // DELETED the seeded set written by withPersistenceDefaults a few
      // ms earlier. Card showed "No sets yet" forever after.
      final freshAtStart = await _storage.getExerciseById(queued.id);
      final exercise = freshAtStart ?? queued;

      final converting = exercise.copyWith(
        conversionStatus: ConversionStatus.converting,
      );
      await _storage.saveExercise(converting);
      if (!_updateController.isClosed) {
        _updateController.add(converting);
      }
      notifyListeners();

      try {
        final result = await _convert(converting);

        // Safe Mode fail-closed (Safe Mode completion wave,
        // 2026-05-21; relaxed 2026-05-25 to accept zero-detection
        // captures). The unified rule:
        //
        //   0% .. 5%   miss → accept with safe variant
        //   5% .. 100% miss → reject (partial Vision miss = struggling)
        //   100%       miss → accept as no-PII (empty room, equipment)
        //
        // The same conditional applies to both photos and videos —
        // photos can only land at the endpoints by arithmetic
        // (single-frame miss is binary 0.0 or 1.0), so the middle-
        // band rejection clause is vacuous for photos but the branch
        // reads identically.
        //
        // [SafeModeRejection] remains a genuine bubble (not exception-
        // driven control flow per `feedback_no_exception_control_flow`);
        // the catch block toasts the practitioner and removes the row.
        if (result.safePath != null) {
          final isFullyEmpty =
              result.safeMissRate >= kSafeModeFullEmptyThreshold;
          final isPartialMiss =
              result.safeMissRate > kSafeModeMaxMissRate && !isFullyEmpty;

          if (isPartialMiss) {
            // Existing rejection path — Vision struggled to track the
            // subject through some frames. Best-effort delete of the
            // partial output files before throwing.
            await _deleteSafely(result.safePath);
            await _deleteSafely(result.convertedPath);
            await _deleteSafely(result.segmentedPath);
            await _deleteSafely(result.maskPath);
            throw SafeModeRejection(exercise.id, result.safeMissRate);
          }

          if (isFullyEmpty) {
            // 2026-05-25 — accept zero-detection capture. The safe
            // variant is a coral-painted copy of an empty frame
            // (nothing to obscure); delete it and let the canonical-
            // source resolver fall through to the raw capture, just
            // as it would for a Safe-Mode-off capture. The line
            // drawing + segmented + mask outputs stay (they were
            // computed off the raw / safe pixels regardless).
            //
            // Telemetry is fire-and-forget — a network or RPC failure
            // must NEVER block the capture flow (acceptance criterion
            // 9 in the spec). Wrapped in `unawaited` + try/catch
            // inside the helper so nothing bubbles back here.
            await _deleteSafely(result.safePath);
            unawaited(_recordSafeModeAcceptedEmpty(
              exercise: exercise,
              missRate: result.safeMissRate,
            ));
            // Mutate the local result so the downstream code path
            // sees no safe variant. The pre-2026-05-25 code keyed off
            // `result.safePath != null` to stamp `safeRawFilePath` on
            // the saved exercise; falling through with safePath ==
            // null routes the publish flow back to the normal raw-
            // archive upload (no swap).
            result.clearSafeVariant();
          }
        }

        // Re-read from the database to pick up intermediate updates
        // (e.g. thumbnailPath set during video thumbnail extraction inside
        // _convert). Without this, the copyWith below would use
        // `converting` which still has thumbnailPath: null, overwriting
        // the thumbnail that was saved to the DB mid-conversion.
        // Round 2 — use [getExerciseById] so seeded child sets survive.
        // See the freshAtStart comment above for the full root-cause.
        final base = (await _storage.getExerciseById(exercise.id)) ?? converting;

        var done = base.copyWith(
          convertedFilePath: PathResolver.toRelative(result.convertedPath),
          conversionStatus: ConversionStatus.done,
          segmentedRawFilePath: result.segmentedPath != null
              ? PathResolver.toRelative(result.segmentedPath!)
              : null,
          maskFilePath: result.maskPath != null
              ? PathResolver.toRelative(result.maskPath!)
              : null,
          // Safe Mode: stamp the safe variant path so UploadService
          // can swap it for the raw file in the cloud raw-archive
          // bucket. Local-only column — not mirrored to Supabase.
          safeRawFilePath: result.safePath != null
              ? PathResolver.toRelative(result.safePath!)
              : null,
        );

        // Regenerate the stored thumbnail now that conversion is done.
        //
        // Design (2026-04-20): practitioner-facing lists (Home clients,
        // ClientSessions, Studio exercise cards, Thumbnail Peek, Camera
        // peek box) all read this single thumbnail asset. Line-drawing
        // thumbnails weren't functional at small sizes even after PR #22's
        // motion-peak + person-crop rescue, so we:
        //
        //   1. Extract from the RAW capture (not the line-drawing video).
        //      The client's face/body appears in B&W inside the trainer
        //      app only. The web player (client-facing) keeps the line
        //      drawing via `line_drawing_url` — unchanged.
        //   2. Ask the native side to recolour to luminance via
        //      grayscale:true. Keeps the motion-peak + person-crop
        //      heuristics from PR #22 intact.
        //   3. Fall back to the 720p H.264 archive if the raw is missing
        //      (long-lived installs where cleanup has run), and finally
        //      to the converted line-drawing as a last resort — rather
        //      than leaving the UI with a stale frame.
        if (exercise.mediaType == MediaType.video) {
          // Per-variant try/catch so a failure on the color OR line
          // extract no longer poisons the other variants (per the
          // 2026-05-13 audit's no-silent-fallback principle — each
          // variant is independently observable). Pre-2026-05-14
          // behaviour wrapped all three calls in ONE catch, leaving
          // `_thumb.jpg` on disk but discarding color + line if
          // extract #2 threw mid-pass.
          final dir = await getApplicationDocumentsDirectory();
          final thumbDir = p.join(dir.path, 'thumbnails');
          final thumbPath = p.join(thumbDir, '${exercise.id}_thumb.jpg');
          final sourcePath = await _pickThumbnailSource(done);
          if (sourcePath != null) {
            // Wave Hero — preserve a previously-picked Hero offset
            // (e.g. when the practitioner re-runs conversion after
            // editing the Hero) by feeding it back into the B&W run.
            // Otherwise we let native motion-peak pick the time and
            // round-trip the picked timeMs back into the model so the
            // editor's Hero scrubber opens on the current frame.
            final priorOffset = done.focusFrameOffsetMs;
            final useAutoPick = priorOffset == null;

            // B&W thumbnail (load-bearing — gates the Hero offset
            // resolution used by the color + line calls below). On
            // failure we keep the pre-conversion thumbnail and skip
            // the dependent variants; user-facing surfaces fall back
            // to the explicit placeholder (parallel agent's resolver).
            int pickedMs = priorOffset ?? 0;
            bool bwOk = false;
            try {
              final bwResp = await _thumbChannel
                  .invokeMethod<Map<dynamic, dynamic>>('extractFrame', {
                'inputPath': sourcePath,
                'outputPath': thumbPath,
                'timeMs': priorOffset ?? 0,
                'autoPick': useAutoPick,
                'grayscale': true,
              }).timeout(const Duration(seconds: 30));
              pickedMs = (bwResp?['timeMs'] as int?) ?? priorOffset ?? 0;
              // Wave Lobby — adopt the native segmentation centroid
              // as the default hero crop offset. Lands on every fresh
              // capture so the lobby + every thumbnail frames the
              // practitioner instead of whatever the centre vertical
              // band happens to be (a TV in Carl's QA case). Null
              // when segmentation bailed / source was square — leave
              // the existing value alone so a prior manual drag
              // isn't wiped by a no-op.
              final autoOffset =
                  (bwResp?['autoHeroCropOffset'] as num?)?.toDouble();
              done = done.copyWith(
                thumbnailPath: PathResolver.toRelative(thumbPath),
                focusFrameOffsetMs: pickedMs,
                heroCropOffset: autoOffset ?? done.heroCropOffset,
              );
              bwOk = true;
            } catch (e, st) {
              await _logVariantFailure(
                exerciseId: exercise.id,
                variant: 'bw',
                error: e,
                stack: st,
              );
            }

            // Color thumbnail (used for original treatment).
            // autoPick: false, grayscale: false — plain color frame, no
            // body-focus segmentation. Sampled at the SAME Hero offset
            // as the B&W run so all treatments are visually consistent.
            // Independent failure: a B&W success doesn't gate this, and
            // a color failure doesn't gate the line run.
            try {
              final colorPath = p.join(thumbDir, '${exercise.id}_thumb_color.jpg');
              await _thumbChannel
                  .invokeMethod<Map<dynamic, dynamic>>('extractFrame', {
                'inputPath': sourcePath,
                'outputPath': colorPath,
                'timeMs': pickedMs,
                'autoPick': false,
                'grayscale': false,
              }).timeout(const Duration(seconds: 30));
            } catch (e, st) {
              await _logVariantFailure(
                exerciseId: exercise.id,
                variant: 'color',
                error: e,
                stack: st,
              );
            }

            // Line-drawing thumbnail (used for line treatment). Sampled
            // from the converted line video at the same Hero offset
            // (raw + line are produced in lock-step so the timeline
            // matches).
            if (done.convertedFilePath != null) {
              try {
                final convertedPath = PathResolver.resolve(done.convertedFilePath!);
                final linePath = p.join(thumbDir, '${exercise.id}_thumb_line.jpg');
                await _thumbChannel
                    .invokeMethod<Map<dynamic, dynamic>>('extractFrame', {
                  'inputPath': convertedPath,
                  'outputPath': linePath,
                  'timeMs': pickedMs,
                  'autoPick': false,
                  'grayscale': false,
                }).timeout(const Duration(seconds: 30));
              } catch (e, st) {
                await _logVariantFailure(
                  exerciseId: exercise.id,
                  variant: 'line',
                  error: e,
                  stack: st,
                );
              }
            }
            // Silence the analyzer about unused `bwOk` — it's a future
            // read-site (we may surface a UI banner on Hero-frame loss).
            // Keeping the local so the diff stays minimal if/when that
            // ships.
            if (!bwOk) {
              debugPrint(
                'Post-conversion B&W thumbnail unavailable for ${exercise.id}; '
                'practitioner surfaces will show the placeholder until backfill.',
              );
            }
          }

          // Probe the raw video duration via AVURLAsset so the "one rep" in
          // the duration estimate reflects the actual clip length instead of
          // the hardcoded AppConfig.secondsPerRep constant. Non-fatal — if the
          // probe fails we leave videoDurationMs null and fall back.
          try {
            final rawPath = PathResolver.resolve(exercise.rawFilePath);
            final ms = await _videoChannel.invokeMethod<int>(
              'getVideoDuration',
              {'inputPath': rawPath},
            ).timeout(
              const Duration(seconds: 10),
              onTimeout: () {
                throw TimeoutException(
                  'Native getVideoDuration exceeded 10s '
                  '(exercise=${exercise.id})',
                );
              },
            );
            if (ms != null && ms > 0) {
              done = done.copyWith(videoDurationMs: ms);
            }
          } catch (e) {
            debugPrint('Video duration probe failed for ${exercise.id}: $e');
            // Non-fatal — leave videoDurationMs unset, estimator falls back
            // to AppConfig.secondsPerRep.
          }

          // Wave 28 — probe natural aspect ratio so the landscape player
          // can size pills + the rotated treatment correctly without
          // re-decoding. Stamped at rotation_quarters=0 (no rotation
          // applied yet); the Studio rotate-90 button will rewrite both
          // fields together. Non-fatal — null leaves consumers to derive
          // at first paint.
          final aspect = await _probeVideoAspectRatio(done.absoluteRawFilePath);
          if (aspect != null && aspect > 0) {
            done = done.copyWith(
              aspectRatio: aspect,
              rotationQuarters: done.rotationQuarters ?? 0,
            );
          }
        } else if (exercise.mediaType == MediaType.photo) {
          // Wave 28 — same probe, photo flavour. Decoded via Flutter
          // painting so we don't re-imread the source through OpenCV
          // just for the dimensions.
          final aspect = await _probePhotoAspectRatio(done.absoluteRawFilePath);
          if (aspect != null && aspect > 0) {
            done = done.copyWith(
              aspectRatio: aspect,
              rotationQuarters: done.rotationQuarters ?? 0,
            );
          }

          // Bundle 2b — three-treatment thumbnail variant pipeline for
          // photos, symmetric to the video extractFrame trio above. Until
          // this pass we stamped `thumbnailPath = rawFilePath`, which
          // worked for the small-thumb surface but broke the lobby's
          // `pickTreatmentPoster` (it `.replaceFirst('_thumb.jpg',
          // '_thumb_line.jpg')` on the path — for photos the filename
          // ended in `.heic` / `.jpg`, never `_thumb.jpg`, so the
          // replace was a no-op and every "treatment" pulled the raw
          // colour photo).
          //
          // The three files mirror the video naming convention so the
          // bridge's `_resolveMediaPath` switch (`hero` / `hero_line` /
          // `hero_color`) works without media-type branching, and the
          // cloud upload + `get_plan_full` RPC route them through the
          // same path-pattern infrastructure videos already use.
          //
          //   `{id}_thumb.jpg`        — B&W (greyscale) variant, default
          //                              practitioner-facing surface
          //                              (Studio cards, peek, filmstrip).
          //   `{id}_thumb_color.jpg`  — raw colour, used by Original
          //                              treatment + B&W via CSS filter.
          //   `{id}_thumb_line.jpg`   — line-drawing JPG, used by Line
          //                              treatment.
          //
          // OpenCV (already imported for line conversion) handles HEIC
          // decoding on iOS and emits a JPEG output. The whole pass runs
          // off the UI thread inside `_extractPhotoThumbnailVariants`
          // via `compute()`. Failure here is non-fatal — the line
          // drawing (gating publish) has already shipped, and the
          // fallback below keeps the legacy thumbnailPath-as-raw
          // behaviour so existing surfaces don't regress.
          try {
            final dir = await getApplicationDocumentsDirectory();
            final thumbDir = p.join(dir.path, 'thumbnails');
            await Directory(thumbDir).create(recursive: true);
            final bwPath =
                p.join(thumbDir, '${exercise.id}_thumb.jpg');
            final colorPath =
                p.join(thumbDir, '${exercise.id}_thumb_color.jpg');
            final linePath =
                p.join(thumbDir, '${exercise.id}_thumb_line.jpg');
            // Photo `_thumb_bw.jpg` — bytes-baked greyscale-plus-contrast
            // sibling for the lobby's B&W treatment. See the isolate
            // comment + `web-player/exercise_hero.js` for why this is
            // SIBLING rather than overwriting `_thumb.jpg`: the
            // canonical `_thumb.jpg` keeps its current bytes (so legacy
            // practitioner surfaces don't change), and `_thumb_bw.jpg`
            // is the explicit, presentation-only B&W bitmap consumed
            // by surfaces that can't apply CSS filters (PDF export,
            // html2canvas snapshot).
            final thumbBwPath =
                p.join(thumbDir, '${exercise.id}_thumb_bw.jpg');

            // Safe Mode downstream-variants fix (2026-05-22) — source the
            // thumbnail variants from the safe-painted JPG when one was
            // produced. Without this, `_thumb_bw.jpg` and
            // `_thumb_color.jpg` are baked from the un-safe raw and the
            // web player's lobby Hero surfaces a fully visible
            // bystander even though the canonical raw archive was
            // swapped. `done.safeRawFilePath` was stamped above in the
            // success branch.
            final rawAbs = done.absoluteSafeRawFilePath ??
                exercise.absoluteRawFilePath;
            final convertedAbs = done.absoluteConvertedFilePath;

            await compute(_extractPhotoThumbnailVariants, _PhotoThumbArgs(
              rawPath: rawAbs,
              convertedPath: convertedAbs,
              bwOutPath: bwPath,
              colorOutPath: colorPath,
              lineOutPath: linePath,
              thumbBwOutPath: thumbBwPath,
            ));

            if (await File(bwPath).exists()) {
              done = done.copyWith(
                thumbnailPath: PathResolver.toRelative(bwPath),
              );
            }
          } catch (e) {
            debugPrint(
              'Photo thumbnail variant extraction failed for '
              '${exercise.id}: $e — falling back to legacy '
              'thumbnailPath = rawFilePath',
            );
            // Fallback to legacy behaviour so existing UI surfaces don't
            // regress when the variant pipeline fails (e.g. malformed
            // HEIC). The treatment variants will be missing, but Studio
            // / ClientSessions / peek render the raw colour photo as
            // before.
            if (done.thumbnailPath == null &&
                exercise.rawFilePath.isNotEmpty) {
              done = done.copyWith(thumbnailPath: exercise.rawFilePath);
            }
          }
        }

        await _storage.saveExercise(done);
        if (!_updateController.isClosed) {
          _updateController.add(done);
        }
        notifyListeners();

        // Fire-and-forget raw archive — compresses the raw video to a 720p
        // H.264 copy in {Documents}/archive/ so we can re-run better
        // line-drawing filters against the original footage later. A failure
        // here must not disturb the main conversion flow.
        unawaited(_archiveRawVideo(done));

        // Self-trainer wave PR #5 (2026-05-25) — fire-and-forget
        // capture-time self-verification. Reads the practitioner's
        // registered face embedding (NULL when they haven't opted in →
        // leaves `self_verified` at NULL) and compares against the
        // converted media. Result is stamped onto the local SQLite
        // `exercises.self_verified` column; the next publish round-trips
        // it through `replace_plan_exercises`. Verification failure
        // NEVER blocks capture or conversion — the flag is purely
        // informational and feeds the publish-cost preview in PR #6.
        unawaited(_runSelfVerification(done));
      } on SafeModeRejection catch (rejection) {
        await handleSafeModeRejection(rejection);
      } catch (e, stack) {
        // Write error to a log file for debugging (readable from simulator filesystem)
        try {
          final logDir = await getApplicationDocumentsDirectory();
          final logFile = File(p.join(logDir.path, 'conversion_error.log'));
          await logFile.writeAsString(
            '${DateTime.now()}\nExercise: ${exercise.id}\n'
            'Raw file: ${exercise.rawFilePath}\n'
            'Error: $e\n\nStack:\n$stack\n\n',
            mode: FileMode.append,
          );
        } catch (_) {
          // Log-of-log swallow. Sanctioned site: writing the
          // conversion-error fallback log already failed, so we can't
          // route through `loudSwallow` (which would recurse into this
          // same log path on its own failure). Legacy breadcrumb only;
          // primary observability signal travels via the parent catch's
          // structured handler.
        }

        // Re-read from the database to preserve thumbnailPath. Round 2 —
        // getExerciseById hydrates child sets so the failure-path save
        // doesn't wipe the seeded first set.
        final base = (await _storage.getExerciseById(exercise.id)) ?? converting;

        final failed = base.copyWith(
          conversionStatus: ConversionStatus.failed,
        );
        await _storage.saveExercise(failed);
        if (!_updateController.isClosed) {
          _updateController.add(failed);
        }
        notifyListeners();
        debugPrint('Conversion failed for ${exercise.id}: $e');
      }
    }
    } catch (e, stack) {
      // Last-resort catch — covers any exception that escapes the inner
      // try (e.g. `saveExercise(converting)` hitting a SQLite lock). Logs
      // and moves on; the finally still resets `_processing`.
      debugPrint('_processQueue aborted unexpectedly: $e\n$stack');
    } finally {
      _processing = false;
    }
  }

  /// Wave Hero — re-extract the three treatment thumbnails (B&W, colour,
  /// line) for [exercise] at [offsetMs] into the source raw video,
  /// persist the new offset to `focus_frame_offset_ms`, save the
  /// resulting [ExerciseCapture] to SQLite, and emit it on
  /// [onConversionUpdate] so listeners (Studio screen, list cards) pick
  /// up the fresh thumbnails immediately.
  ///
  /// Used by the editor-sheet "Hero" tab when the practitioner picks a
  /// different frame. No-ops for non-video exercises (photos already
  /// are the Hero frame; rest periods have no media).
  ///
  /// Best-effort — a native extraction failure is logged but the
  /// in-memory [ExerciseCapture] still gets the new
  /// `focus_frame_offset_ms` so the editor's slider remembers the
  /// pick. The thumbnail file on disk is overwritten in place when the
  /// extraction succeeds, so existing UI surfaces (Studio card, Home,
  /// ClientSessions, Camera peek) auto-refresh on the next paint.
  Future<ExerciseCapture> regenerateHeroThumbnails(
    ExerciseCapture exercise,
    int offsetMs,
  ) async {
    if (exercise.mediaType != MediaType.video) {
      // Photos / rest never carry a Hero offset. Return verbatim.
      return exercise;
    }
    final clampedMs = offsetMs < 0 ? 0 : offsetMs;
    var next = exercise.copyWith(focusFrameOffsetMs: clampedMs);

    // Per-variant try/catch (mirrors the post-conversion block — see
    // the 2026-05-13 audit's no-silent-fallback principle). A failure
    // on color OR line no longer voids the B&W refresh; each variant
    // is observable + diagnosable via the conversion-error log.
    final dir = await getApplicationDocumentsDirectory();
    final thumbDir = p.join(dir.path, 'thumbnails');
    try {
      await Directory(thumbDir).create(recursive: true);
    } catch (e, st) {
      // Directory creation failure is the only catastrophic case here —
      // every variant write below would fail otherwise. Log under the
      // bw kind (most prominent surface) and bail out to the persist
      // below so the offset is still remembered.
      await _logVariantFailure(
        exerciseId: exercise.id,
        variant: 'bw',
        error: e,
        stack: st,
        contextKind: 'regen_dir_create',
      );
      await _storage.saveExercise(next);
      if (!_updateController.isClosed) {
        _updateController.add(next);
      }
      notifyListeners();
      return next;
    }
    final thumbPath = p.join(thumbDir, '${exercise.id}_thumb.jpg');
    final sourcePath = await _pickThumbnailSource(exercise);
    if (sourcePath == null) {
      debugPrint(
        'regenerateHeroThumbnails: no raw/archive source for ${exercise.id}',
      );
      await _logVariantFailure(
        exerciseId: exercise.id,
        variant: 'bw',
        error: StateError('No raw/archive source available'),
        contextKind: 'regen_no_source',
      );
    } else {
      // B&W (grayscale + body-focus crop) — the canonical practitioner-
      // facing thumbnail. autoPick:false so the caller-supplied
      // [offsetMs] is honoured verbatim.
      //
      // Wave Lobby — even though autoPick is false, the native side
      // still runs segmentation (the B&W treatment uses the body-
      // focus pass), so the soft-mask centroid is still available.
      // We adopt it as the new hero crop offset — a re-scrub
      // intentionally replaces a prior manual drag because the user
      // just picked a new frame and the auto-pick is the right
      // default for that frame. They can re-drag if they disagree.
      // Per Phase B in the brief.
      try {
        final bwResp = await _thumbChannel
            .invokeMethod<Map<dynamic, dynamic>>('extractFrame', {
          'inputPath': sourcePath,
          'outputPath': thumbPath,
          'timeMs': clampedMs,
          'autoPick': false,
          'grayscale': true,
        }).timeout(const Duration(seconds: 30));
        final autoOffset =
            (bwResp?['autoHeroCropOffset'] as num?)?.toDouble();
        next = next.copyWith(
          thumbnailPath: PathResolver.toRelative(thumbPath),
          heroCropOffset: autoOffset ?? next.heroCropOffset,
        );
      } catch (e, st) {
        await _logVariantFailure(
          exerciseId: exercise.id,
          variant: 'bw',
          error: e,
          stack: st,
          contextKind: 'regen',
        );
      }

      // Colour (no body-focus, no grayscale) — used by the Original
      // treatment surface. Independent failure: a B&W failure above
      // doesn't stop this; a failure here doesn't gate the line run.
      try {
        final colorPath = p.join(thumbDir, '${exercise.id}_thumb_color.jpg');
        await _thumbChannel
            .invokeMethod<Map<dynamic, dynamic>>('extractFrame', {
          'inputPath': sourcePath,
          'outputPath': colorPath,
          'timeMs': clampedMs,
          'autoPick': false,
          'grayscale': false,
        }).timeout(const Duration(seconds: 30));
      } catch (e, st) {
        await _logVariantFailure(
          exerciseId: exercise.id,
          variant: 'color',
          error: e,
          stack: st,
          contextKind: 'regen',
        );
      }

      // Line-drawing — sampled from the converted line video at the
      // same offset (the converted video shares the raw timeline).
      if (exercise.convertedFilePath != null) {
        try {
          final convertedPath = PathResolver.resolve(exercise.convertedFilePath!);
          final linePath = p.join(thumbDir, '${exercise.id}_thumb_line.jpg');
          await _thumbChannel
              .invokeMethod<Map<dynamic, dynamic>>('extractFrame', {
            'inputPath': convertedPath,
            'outputPath': linePath,
            'timeMs': clampedMs,
            'autoPick': false,
            'grayscale': false,
          }).timeout(const Duration(seconds: 30));
        } catch (e, st) {
          await _logVariantFailure(
            exerciseId: exercise.id,
            variant: 'line',
            error: e,
            stack: st,
            contextKind: 'regen',
          );
        }
      }
    }

    // Flag the exercise's thumbs as dirty so the next publish re-uploads
    // every variant — overriding the fast-path skip that keys on
    // `rawArchiveUploadedAt` alone. Set even when one or more variants
    // failed above: any new local variant means cloud is stale. The
    // post-conversion path (first capture → convert) never sets this
    // because `rawArchiveUploadedAt` is still null there, so the normal
    // upload loop already runs and writes every variant.
    //
    // See `exercise_capture.dart` thumbnailsDirty doc-comment + the
    // 2026-05-16 fix commit for the publish-side honouring.
    next = next.copyWith(thumbnailsDirty: true);

    await _storage.saveExercise(next);
    if (!_updateController.isClosed) {
      _updateController.add(next);
    }
    notifyListeners();
    return next;
  }

  /// Probe the rotation-corrected aspect ratio (width / height) of the
  /// video at [absolutePath] via the native channel. Used by the Hero
  /// tab to letterbox iPhone-portrait raw archives correctly:
  /// `VideoPlayerController.value.aspectRatio` reports the unrotated
  /// 16:9 because the rotation lives in metadata, not pixels — but
  /// AVPlayerLayer auto-rotates the visual, so the displayed video
  /// gets stretched into the wrong-shaped letterbox.
  ///
  /// Returns null on missing file, missing video track, or any native
  /// failure. Caller falls back to the unrotated `c.value.aspectRatio`.
  Future<double?> getRotatedAspect(String absolutePath) async {
    if (absolutePath.isEmpty) return null;
    try {
      final aspect = await _videoChannel.invokeMethod<double>(
        'getVideoRotatedAspect',
        {'inputPath': absolutePath},
      ).timeout(const Duration(seconds: 5));
      if (aspect != null && aspect > 0) return aspect;
      return null;
    } catch (e) {
      debugPrint('getRotatedAspect failed for $absolutePath: $e');
      return null;
    }
  }

  /// Convert a single capture. Dispatches to photo or video handler.
  /// For videos, also extracts a thumbnail from the first frame before
  /// starting the full conversion.
  ///
  /// Returns a [_ConvertResult] carrying the converted line-drawing path
  /// and, when the native dual-output pass succeeds, the segmented-color
  /// raw variant. Photos and the OpenCV / frame-extraction fallbacks
  /// populate only [convertedPath]; [segmentedPath] remains null.
  Future<_ConvertResult> _convert(ExerciseCapture exercise) async {
    final dir = await getApplicationDocumentsDirectory();
    final ext = p.extension(exercise.rawFilePath);
    final convertedDir = p.join(dir.path, 'converted');
    await Directory(convertedDir).create(recursive: true);

    if (exercise.mediaType == MediaType.video) {
      // Extract a thumbnail immediately so the UI has something to show.
      try {
        final thumbPath = await _extractVideoThumbnail(
            exercise.absoluteRawFilePath, exercise.id, dir.path);
        if (thumbPath != null) {
          final withThumb = exercise.copyWith(thumbnailPath: PathResolver.toRelative(thumbPath));
          await _storage.saveExercise(withThumb);
          if (!_updateController.isClosed) {
            _updateController.add(withThumb);
          }
          notifyListeners();
        }
      } catch (e) {
        debugPrint('Thumbnail extraction failed for ${exercise.id}: $e');
        // Non-fatal — the UI will fall back to the placeholder.
      }

      // Try full frame-by-frame video conversion via OpenCV first.
      // On iOS, OpenCV's VideoCapture often can't decode H.264/H.265
      // because the codec backend wasn't compiled in. In that case, fall
      // back to extracting a key frame via video_thumbnail and converting
      // that single frame to a line drawing still image.
      //
      // Always mux the audio track into the converted file. The per-exercise
      // `ExerciseCapture.includeAudio` flag is a PLAYBACK concern (the
      // preview screen and web player set volume/muted attr based on it —
      // see `plan_preview_screen.dart:425` and `web-player/app.js:441`).
      // The file itself should always carry the recorded audio so the
      // practitioner can toggle the "Include audio on share" switch in
      // Studio at any time without needing to re-capture.
      //
      // Previous behaviour (PR #29) passed `exercise.includeAudio` through
      // to the converter — but `ExerciseCapture.includeAudio` defaults to
      // `false` (see `exercise_capture.dart:109`), which collapsed PR #29's
      // Swift `sourceFormatHint` fix before it could run. Fresh captures
      // still shipped with silent Line treatment. (2026-04-20).
      //
      // Kill-switch (2026-04-20, PR #40 triage): if the audio-mux path is
      // causing device hangs, flip `AppConfig.audioMuxEnabled` to false at
      // build time via `--dart-define=HOMEFIT_AUDIO_MUX_ENABLED=false`. That
      // makes us pass `includeAudio: false` to the native converter, which
      // falls back to the pre-PR-#39 video-only path (no audio reader /
      // writer / sample drain). The output will be silent on Line treatment
      // but conversion will complete rather than hang. See `config.dart`.
      final videoOutputPath = p.join(convertedDir, '${exercise.id}_line$ext');
      // The segmented-color raw variant lands alongside the line drawing.
      // `.mp4` always — the native AVAssetWriter writes mp4 containers
      // regardless of the raw capture extension, and the upload path on
      // Supabase is also `.segmented.mp4`. Keeping the on-disk suffix
      // aligned makes it easier to grep / reason about.
      final segmentedOutputPath =
          p.join(convertedDir, '${exercise.id}_segmented.mp4');
      // Milestone P2: the Vision mask is emitted as a THIRD output — a
      // grayscale H.264 mp4 that's pixel-perfect aligned with the segmented
      // composite. Upload lands at `{...}.mask.mp4` in raw-archive; today
      // it has no consumer (insurance for future playback-time compositing).
      final maskOutputPath =
          p.join(convertedDir, '${exercise.id}_mask.mp4');
      // Safe Mode (2026-05-21) — when the session is inside an
      // enforcing premises the native pipeline writes a 4th output with
      // coral silhouettes baked over bystanders. Bypassed if Safe Mode
      // is off (most sessions); the file simply isn't produced.
      String? safeOutputPath;
      try {
        if (SafeModeService.instance.isActive) {
          safeOutputPath = p.join(convertedDir, '${exercise.id}_safe.mp4');
        }
      } catch (_) {
        // Service not initialised (e.g. tests). Fall through with no
        // Safe Mode pass — line drawing + segmented still happen.
      }
      try {
        final segResult = await _convertVideo(
          exercise.absoluteRawFilePath,
          videoOutputPath,
          segmentedOutputPath: segmentedOutputPath,
          maskOutputPath: maskOutputPath,
          safeOutputPath: safeOutputPath,
          includeAudio: AppConfig.audioMuxEnabled,
        );
        return _ConvertResult(
          convertedPath: videoOutputPath,
          segmentedPath: segResult.segmentedPath,
          maskPath: segResult.maskPath,
          safePath: segResult.safePath,
          safeMissRate: segResult.safeMissRate,
        );
      } catch (e, stack) {
        debugPrint(
            'Full video conversion failed for ${exercise.id}: $e — '
            'falling back to key-frame extraction');
        try {
          final logDir = await getApplicationDocumentsDirectory();
          final logFile = File(p.join(logDir.path, 'conversion_error.log'));
          await logFile.writeAsString(
            '${DateTime.now()} [_convertVideo failed]\n$e\n$stack\n\n',
            mode: FileMode.append,
          );
        } catch (_) {
          // Log-of-log swallow. Sanctioned site: writing the
          // conversion-error fallback log already failed, so we can't
          // route through `loudSwallow` (which would recurse into this
          // same log path on its own failure). Legacy breadcrumb only;
          // primary observability signal travels via the parent catch's
          // structured handler.
        }
      }

      // Fallback: extract a key frame and convert to a still line drawing.
      final stillOutputPath =
          p.join(convertedDir, '${exercise.id}_line.jpg');
      await _convertVideoViaFrameExtraction(
          exercise.absoluteRawFilePath, stillOutputPath);
      return _ConvertResult(convertedPath: stillOutputPath);
    } else {
      // Safe Mode downstream-variants fix (2026-05-22). The photo branch
      // re-orders the safe pass to run FIRST so every downstream pass
      // (line drawing, body-focus segmented, thumbnail variants) reads
      // from the safe-painted JPG instead of the raw capture. Without
      // this, the player's `_thumb_bw.jpg` / `.segmented.jpg` /
      // `_thumb_color.jpg` files all betray bystander identity even
      // when PR #402's upload swap rewrote the canonical `.jpg`.
      //
      // Carl-signed (2026-05-22): the LOCKED-v6 line-drawing tuning
      // exception is APPROVED for Safe Mode captures — feeding safe
      // pixels into the edge detector is correct because the
      // bystander's flat coral region produces a flat silhouette
      // rather than identifying edges. Without this, even the line
      // drawing leaks bystander identity through silhouette.
      //
      // Gate on the CAPTURE-time stamp (`exercise.safeModeActive`),
      // not the runtime `SafeModeService.instance.isActive` check. The
      // conversion runs asynchronously after capture; if the
      // practitioner leaves the polygon between shutter and conversion
      // the runtime check would be false even though the capture
      // intent was Safe Mode. The stamp is the source of truth.
      String? safePhotoPath;
      double safePhotoMissRate = 0.0;
      if (exercise.safeModeActive) {
        // Safe Mode v2 (2026-05-23) — resolve the bound client's face
        // embedding through the session. Capture-screen gating in
        // `_shouldGateOnSafeModeV2` normally guarantees the embedding
        // is cached by shutter time. The narrow race the capture-time
        // gate cannot cover: app killed between shutter and
        // conversion + cold-start cache miss before the queued
        // conversion resumes. Hard-refuse rather than fall through to
        // an un-blurred upload (`feedback_no_silent_fallbacks`).
        final session = exercise.sessionId == null
            ? null
            : await _storage.getSession(exercise.sessionId!);
        final clientId = session?.clientId;
        // Wave-D (2026-05-24): resolve the subject embedding(s) from
        // the multi-reference cache first; fall back to the legacy
        // single-embedding cache during the back-compat window so
        // clients enrolled before this wave keep working.
        final List<Uint8List> subjectEmbeddings =
            await _resolveSubjectEmbeddings(_storage, clientId);

        if (subjectEmbeddings.isEmpty) {
          try {
            final logDir = await getApplicationDocumentsDirectory();
            final logFile =
                File(p.join(logDir.path, 'conversion_error.log'));
            await logFile.writeAsString(
              '${DateTime.now()} [applySafeModeV2ToPhoto refused: '
              'no embedding for client=${clientId ?? "<none>"}]\n\n',
              mode: FileMode.append,
            );
          } catch (_) {
            // Sanctioned log-of-log swallow.
          }
          throw SafeModeRejection(
            exercise.id,
            0.0,
            reason: SafeModeRejectionReason.missingFaceEmbedding,
          );
        } else {
          try {
            final candidate =
                p.join(convertedDir, '${exercise.id}_safe.jpg');
            final threshold = await _resolveSafeModeV2Threshold(null);
            // Multi-reference (2026-05-24, Wave-D): native takes
            // `subjectEmbeddings: List<Data>`. Pass the full slot set
            // when available (3-8 vectors); during back-compat the
            // legacy single avatar embedding lives at index 0 alone.
            final resp = await _videoChannel
                .invokeMethod<Map<dynamic, dynamic>>(
              'applySafeModeV2ToPhoto',
              <String, dynamic>{
                'srcPath': exercise.absoluteRawFilePath,
                'destPath': candidate,
                'subjectEmbeddings': subjectEmbeddings,
                'threshold': threshold,
              },
            ).timeout(const Duration(seconds: 30));
            if (resp == null) {
              throw StateError('applySafeModeV2ToPhoto returned null');
            }
            final missRate =
                (resp['safeFramesMissedRate'] as num?)?.toDouble() ?? 0.0;
            if (await File(candidate).exists()) {
              safePhotoPath = candidate;
              safePhotoMissRate = missRate;
            }
          } catch (e, stack) {
            debugPrint(
              'Photo Safe Mode v2 pass failed for ${exercise.id}: $e — '
              'falling through with safe=null; downstream passes will '
              'fall back to the raw capture (un-blurred bystanders may '
              'surface — outer queue handler may still throw '
              'SafeModeRejection based on missRate when applicable).',
            );
            try {
              final logDir = await getApplicationDocumentsDirectory();
              final logFile =
                  File(p.join(logDir.path, 'conversion_error.log'));
              await logFile.writeAsString(
                '${DateTime.now()} [applySafeModeV2ToPhoto failed]\n$e\n$stack\n\n',
                mode: FileMode.append,
              );
            } catch (_) {
              // Sanctioned log-of-log swallow.
            }
          }
        }
      }

      // Canonical source — the safe-painted JPG when Safe Mode produced
      // one, otherwise the raw capture. Every downstream pass below
      // reads from this so the bystander coral paint propagates into
      // line drawing, body-focus segmented JPG, and thumbnail variants.
      final canonicalSource =
          safePhotoPath ?? exercise.absoluteRawFilePath;

      final convertedPath =
          p.join(convertedDir, '${exercise.id}_line$ext');
      await _convertPhoto(canonicalSource, convertedPath);

      // Wave 36 — body-focus segmented variant for exercise photos.
      // Mirrors the dual-output story videos have had since Milestone P:
      // a Vision person-segmentation + Gaussian-blur composite that
      // preserves the body and dims the background. Best-effort — a
      // failure here MUST NOT fail the line-drawing conversion (which
      // is what gates publish).
      //
      // Output naming intentionally stays `.segmented.jpg` so
      // `upload_service.dart` can route it to the same `raw-archive`
      // bucket pattern videos use, and the schema's `segmented_url`
      // signing logic in `get_plan_full` only has to learn one extra
      // suffix per media type.
      //
      // 2026-05-22: `canonicalSource` flows in so the body-focus pass
      // sees the safe-painted pixels. Vision person-segmentation may
      // still detect the bystander silhouette as a person (the coral
      // patch has body-shape edges), but the per-pixel composite
      // sources RGB from the input — so any "human" region carries
      // coral pixels rather than the original bystander.
      String? segmentedPhotoPath;
      try {
        final candidate =
            p.join(convertedDir, '${exercise.id}.segmented.jpg');
        await _convertPhotoBodyFocus(
          canonicalSource,
          candidate,
        );
        if (await File(candidate).exists()) {
          segmentedPhotoPath = candidate;
        }
      } catch (e, stack) {
        debugPrint(
          'Photo body-focus segmentation failed for ${exercise.id}: $e — '
          'line drawing already produced; falling through with segmented=null',
        );
        try {
          final logDir = await getApplicationDocumentsDirectory();
          final logFile = File(p.join(logDir.path, 'conversion_error.log'));
          await logFile.writeAsString(
            '${DateTime.now()} [_convertPhotoBodyFocus failed]\n$e\n$stack\n\n',
            mode: FileMode.append,
          );
        } catch (_) {
          // Sanctioned log-of-log swallow — see the video branch's
          // matching site for the rationale.
        }
      }

      return _ConvertResult(
        convertedPath: convertedPath,
        segmentedPath: segmentedPhotoPath,
        safePath: safePhotoPath,
        safeMissRate: safePhotoMissRate,
      );
    }
  }

  /// Native body-focus segmentation pass for an exercise photo.
  ///
  /// Calls the iOS `processPhotoBodyFocus` channel method (Wave 36),
  /// which reuses the same `ClientAvatarProcessor` Vision +
  /// vImage-Gaussian-blur compose pipeline the avatar surface uses,
  /// encoded as JPEG (compressionQuality 0.9).
  ///
  /// 30s timeout matches the line-drawing photo conversion timeout —
  /// a hung Vision call would otherwise wedge the conversion queue
  /// for new captures behind it. On timeout the outer `_convert`
  /// catches and proceeds without a segmented variant.
  Future<void> _convertPhotoBodyFocus(
    String inputPath,
    String outputPath,
  ) async {
    final dynamic resp = await _videoChannel.invokeMethod<Object?>(
      'processPhotoBodyFocus',
      <String, dynamic>{
        'rawPath': inputPath,
        'outPath': outputPath,
      },
    ).timeout(
      const Duration(seconds: 30),
      onTimeout: () => throw TimeoutException(
        'Photo body-focus exceeded 30s — Vision likely hung '
        '(inputPath=$inputPath)',
      ),
    );
    if (resp is! Map || resp['success'] != true) {
      throw StateError('processPhotoBodyFocus returned unexpected: $resp');
    }
  }

  /// Pick the best available source file to extract a practitioner-facing
  /// thumbnail from, falling back in readability-preference order:
  ///
  ///   0. Safe Mode variant (`safeRawFilePath`) — when present, ALWAYS
  ///      preferred. Bystanders show as flat coral so the thumb honours
  ///      the Safe Mode privacy guarantee. Added 2026-05-22 (downstream
  ///      variants fix) so that `_thumb_color.jpg` / `_thumb.jpg` /
  ///      `_thumb_line.jpg` are baked from safe pixels rather than the
  ///      un-safe raw — without this, the web player's lobby Hero
  ///      surfaces a fully visible bystander even though PR #402 swapped
  ///      the canonical raw archive.
  ///   1. Raw capture (`rawFilePath`) — what the camera actually recorded.
  ///      Grayscales cleanly and gives the most legible "this is Client A
  ///      doing a squat" frame.
  ///   2. 720p H.264 archive (`archiveFilePath`) — still a real-person
  ///      frame, just smaller. Safe fallback for long-lived installs where
  ///      the raw got pruned.
  ///   3. Converted line-drawing (`convertedFilePath`) — last resort. Worse
  ///      legibility at small sizes but strictly better than leaving the
  ///      old thumbnail untouched.
  ///
  /// Returns null if none of the candidates exist on disk (shouldn't
  /// happen in practice — caller will skip the thumbnail regen step).
  Future<String?> _pickThumbnailSource(ExerciseCapture exercise) async {
    final candidates = <String?>[
      // Safe Mode wins when the capture was inside an enforcing polygon
      // AND the converter produced a safe variant. Falls through to the
      // un-safe raw only when the safe pass never ran or failed.
      exercise.safeModeActive ? exercise.absoluteSafeRawFilePath : null,
      exercise.rawFilePath.isNotEmpty ? exercise.absoluteRawFilePath : null,
      exercise.absoluteArchiveFilePath,
      exercise.absoluteConvertedFilePath,
    ];
    for (final candidate in candidates) {
      if (candidate == null || candidate.isEmpty) continue;
      if (await File(candidate).exists()) return candidate;
    }
    return null;
  }

  /// Probe a video's natural aspect ratio (width / height) via a
  /// transient `VideoPlayerController` (Wave 28). Returns null on any
  /// failure — caller leaves aspect_ratio unset and consumers derive at
  /// first paint.
  ///
  /// Hard 10s timeout: a botched file or codec stall would otherwise
  /// hold the conversion queue indefinitely. The controller is always
  /// disposed in finally so a partial init doesn't leak the player.
  Future<double?> _probeVideoAspectRatio(String absolutePath) async {
    if (absolutePath.isEmpty) return null;
    final file = File(absolutePath);
    if (!await file.exists()) return null;
    final controller = VideoPlayerController.file(file);
    try {
      await controller.initialize().timeout(const Duration(seconds: 10));
      final size = controller.value.size;
      if (size.width <= 0 || size.height <= 0) return null;
      return size.width / size.height;
    } catch (e) {
      debugPrint('Wave 28 video aspect probe failed for $absolutePath: $e');
      return null;
    } finally {
      try {
        await controller.dispose();
      } catch (_) {
        // Disposal failures are not actionable here — the controller is
        // about to fall out of scope either way.
      }
    }
  }

  /// Probe a photo's natural aspect ratio via Flutter's painting decoder
  /// (Wave 28). Returns null on any failure — caller leaves
  /// aspect_ratio unset.
  Future<double?> _probePhotoAspectRatio(String absolutePath) async {
    if (absolutePath.isEmpty) return null;
    final file = File(absolutePath);
    if (!await file.exists()) return null;
    try {
      final bytes = await file.readAsBytes();
      final image = await decodeImageFromList(bytes);
      try {
        if (image.width <= 0 || image.height <= 0) return null;
        return image.width / image.height;
      } finally {
        image.dispose();
      }
    } catch (e) {
      debugPrint('Wave 28 photo aspect probe failed for $absolutePath: $e');
      return null;
    }
  }

  /// Extract a video frame and save it as a JPEG thumbnail.
  /// Returns the thumbnail path, or null if extraction fails.
  ///
  /// Tries three approaches in order:
  /// 1. Native iOS platform channel (AVAssetImageGenerator)
  /// 2. OpenCV VideoCapture (works on Android, may fail on iOS)
  /// 3. video_thumbnail package (cross-platform fallback)
  Future<String?> _extractVideoThumbnail(
      String videoPath, String exerciseId, String baseDir) async {
    final thumbDir = Directory(p.join(baseDir, 'thumbnails'));
    await thumbDir.create(recursive: true);
    final thumbPath = p.join(thumbDir.path, '${exerciseId}_thumb.jpg');

    // Attempt 0: Simple native frame extraction (most reliable on iOS).
    // `grayscale:true` — practitioner-facing lists render the B&W frame so
    // the client is readable at small sizes. The line-drawing treatment
    // is preserved on the client-facing web player only.
    try {
      final result = await _thumbChannel.invokeMethod<Map<dynamic, dynamic>>(
        'extractFrame',
        {
          'inputPath': videoPath,
          'outputPath': thumbPath,
          // `timeMs` ignored when autoPick=true; native picks a motion-peak
          // frame and crops tight around the person.
          'timeMs': 0,
          'autoPick': true,
          'grayscale': true,
        },
      ).timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          throw TimeoutException(
            'Native thumb extractFrame exceeded 30s '
            '(exercise=$exerciseId)',
          );
        },
      );
      if (result != null && await File(thumbPath).exists()) {
        debugPrint('Native thumb channel succeeded: $thumbPath');
        return thumbPath;
      }
    } catch (e, st) {
      // Native thumb channel failure. Control flow: fall through to
      // the full video-converter channel attempt below. Wave 7: route
      // the signal through `loudSwallow` so the server-side error_logs
      // table receives a row + the local diagnostics.log captures it,
      // even in release builds where the debugPrint below is stripped.
      debugPrint('Native thumb channel failed: $e');
      await loudSwallow(
        () async {
          final logDir = await getApplicationDocumentsDirectory();
          final logFile = File(p.join(logDir.path, 'conversion_error.log'));
          await logFile.writeAsString(
            '${DateTime.now()} [native_thumb extractFrame]\n$e\n'
            '  ${st.toString().split('\n').take(3).join('\n  ')}\n\n',
            mode: FileMode.append,
          );
        },
        kind: 'native_thumb_channel_failed',
        source: 'ConversionService._extractVideoThumbnail',
        severity: 'warn',
        message: e.toString(),
        meta: {
          'exercise_id': exerciseId,
          'video_path': videoPath,
        },
        swallow: true,
      );
    }

    // Attempt 1: Full native video converter channel.
    try {
      final result = await _videoChannel.invokeMethod<Map>(
        'extractThumbnail',
        {
          'inputPath': videoPath,
          'outputPath': thumbPath,
          // `timeMs` ignored when autoPick=true; native picks a motion-peak
          // frame and crops tight around the person.
          'timeMs': 0,
          'autoPick': true,
          'grayscale': true,
        },
      ).timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          throw TimeoutException(
            'Native extractThumbnail exceeded 30s '
            '(exercise=$exerciseId)',
          );
        },
      );
      if (result != null && result['success'] == true) {
        debugPrint('Native thumbnail extraction succeeded');
        return thumbPath;
      }
    } on PlatformException catch (e) {
      debugPrint('Native thumbnail extraction failed: ${e.message}');
    } on MissingPluginException {
      debugPrint('Video converter channel not registered');
    }

    // Attempt 2: OpenCV VideoCapture (works on Android, may fail on iOS).
    try {
      final cap = cv.VideoCapture.fromFile(videoPath);
      if (cap.isOpened) {
        try {
          final (success, frame) = cap.read();
          if (success && !frame.isEmpty) {
            cv.imwrite(thumbPath, frame,
                params: cv.VecI32.fromList([cv.IMWRITE_JPEG_QUALITY, 85]));
            frame.dispose();
            return thumbPath;
          }
          frame.dispose();
        } finally {
          cap.release();
        }
      } else {
        cap.release();
      }
    } catch (e) {
      debugPrint('OpenCV VideoCapture unavailable: $e');
    }

    // Attempt 3: video_thumbnail package (uses AVAssetImageGenerator on iOS).
    debugPrint('OpenCV VideoCapture failed for thumbnail -- '
        'falling back to video_thumbnail package');
    for (final videoUri in [videoPath, 'file://$videoPath']) {
      try {
        final Uint8List? bytes = await vt.VideoThumbnail.thumbnailData(
          video: videoUri,
          imageFormat: vt.ImageFormat.JPEG,
          maxWidth: 512,
          quality: 85,
        );
        if (bytes != null && bytes.isNotEmpty) {
          await File(thumbPath).writeAsBytes(bytes);
          return thumbPath;
        }
      } catch (e) {
        debugPrint('video_thumbnail thumbnail failed with "$videoUri": $e');
      }
    }
    return null;
  }

  /// Convert a single photo to a line drawing using OpenCV.
  ///
  /// Runs on a background isolate so the 400-800ms OpenCV work on 12MP
  /// photos doesn't block the UI thread. The isolate entry handles the
  /// full imread → process → imwrite cycle with only primitive types
  /// crossing the isolate boundary (opencv_dart Mat handles wrap FFI
  /// pointers that don't survive isolate hops).
  Future<void> _convertPhoto(String inputPath, String outputPath) async {
    // 30s timeout is insurance against a legitimately hung OpenCV isolate
    // (observed in the wild: the last capture in a rapid burst would sit
    // at "converting" forever). The photo pipeline runs end-to-end in
    // ~400-800ms on a 12MP image, so 30s is well past any legitimate
    // work window. On timeout the outer catch marks the row as
    // `ConversionStatus.failed` so the "N failed" retry pill surfaces.
    await compute<_PhotoConvertArgs, void>(
      _convertPhotoIsolate,
      _PhotoConvertArgs(
        inputPath: inputPath,
        outputPath: outputPath,
        blurKernel: AppConfig.blurKernel,
        thresholdBlock: AppConfig.thresholdBlock,
        contrastLow: AppConfig.contrastLow,
      ),
    ).timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        throw TimeoutException(
          'Photo conversion exceeded 30s — isolate likely hung '
          '(inputPath=$inputPath)',
        );
      },
    );
  }

  /// Convert a video to a line drawing.
  ///
  /// Tries the native iOS platform channel first (AVAssetReader/Writer +
  /// Accelerate). This handles H.264/265 codecs that OpenCV can't decode on
  /// iOS. If the native channel is unavailable (e.g. on Android) or fails,
  /// falls back to OpenCV's VideoCapture/VideoWriter.
  ///
  /// [includeAudio] controls whether the native converter muxes the source
  /// audio track into the output file. Defaults to true — mirrors the
  /// practitioner's per-exercise mute toggle on `ExerciseCapture`.
  ///
  /// [segmentedOutputPath] opts into the dual-output pass: the native side
  /// reuses the Vision person-segmentation mask it already computes for the
  /// line drawing to also write a segmented-color mp4 alongside it (body
  /// untouched, background dimmed). Best-effort — a failure in the
  /// segmented writer never blocks or fails the line-drawing conversion.
  ///
  /// [maskOutputPath] opts into the mask-sidecar pass (Milestone P2): the
  /// SAME Vision mask that drives the line-drawing + segmented composites
  /// is written out as a grayscale H.264 mp4. Insurance for future
  /// playback-time compositing — no consumer today. Best-effort, same as
  /// the segmented writer; a failure never blocks line-drawing output.
  ///
  /// Returns a [_NativeVideoResult] carrying the absolute segmented + mask
  /// paths when the native side reports successful writes, or nulls
  /// otherwise (photo fallback, OpenCV fallback, or any individual sidecar
  /// writer failure).
  Future<_NativeVideoResult> _convertVideo(
    String inputPath,
    String outputPath, {
    String? segmentedOutputPath,
    String? maskOutputPath,
    String? safeOutputPath,
    bool includeAudio = true,
  }) async {
    // --- Attempt 1: Native iOS platform channel ---
    try {
      final args = <String, Object?>{
        'inputPath': inputPath,
        'outputPath': outputPath,
        'blurKernel': AppConfig.blurKernel,
        'thresholdBlock': AppConfig.thresholdBlock,
        'contrastLow': AppConfig.contrastLow,
        'includeAudio': includeAudio,
      };
      if (segmentedOutputPath != null) {
        args['segmentedOutputPath'] = segmentedOutputPath;
      }
      if (maskOutputPath != null) {
        args['maskOutputPath'] = maskOutputPath;
      }
      // Safe Mode (2026-05-21) — when set, the native side runs a 4th
      // output pass that composites a coral silhouette over every
      // segmented person OTHER than the largest one (identified via
      // VNDetectHumanRectanglesRequest). Failures inside that pass are
      // non-fatal — the line drawing + segmented outputs still ship.
      if (safeOutputPath != null) {
        args['safeOutputPath'] = safeOutputPath;
        args['safeModeEnabled'] = true;
      }
      // Hard ceiling — if the native side stalls (AVAssetWriter drain
       // deadlock, disk backpressure, etc.) we'd otherwise wedge the entire
      // ConversionService queue forever. 3 min is ~30x the worst realistic
      // runtime for a 30s capture at 30fps; anything longer is pathological.
      final result = await _videoChannel.invokeMethod<Map>(
        'convertVideo',
        args,
      ).timeout(
        const Duration(minutes: 3),
        onTimeout: () {
          throw TimeoutException(
            'Native convertVideo exceeded 3 min — treating as failed '
            '(inputPath=$inputPath)',
          );
        },
      );
      if (result != null && result['success'] == true) {
        final segPath = result['segmentedOutputPath'] as String?;
        final maskPath = result['maskOutputPath'] as String?;
        final safePath = result['safeOutputPath'] as String?;
        final safeMiss =
            (result['safeFramesMissedRate'] as num?)?.toDouble() ?? 0.0;
        debugPrint(
            'Native video conversion complete: '
            '${result["framesProcessed"]} frames '
            '(audioSamplesWritten=${result["audioSamplesWritten"]}, '
            'audioMuxEnabled=${AppConfig.audioMuxEnabled}, '
            'segFrames=${result["segFramesProcessed"] ?? 0}, '
            'maskFrames=${result["maskFramesProcessed"] ?? 0}, '
            'safeFrames=${result["safeFramesProcessed"] ?? 0}, '
            'safeMissRate=${safeMiss.toStringAsFixed(3)}) -> $outputPath');
        return _NativeVideoResult(
          segmentedPath: segPath,
          maskPath: maskPath,
          safePath: safePath,
          safeMissRate: safeMiss,
        );
      }
    } on PlatformException catch (e) {
      debugPrint(
          'Native video conversion failed: ${e.code} - ${e.message} -- '
          'falling back to OpenCV VideoCapture');
    } on MissingPluginException {
      debugPrint(
          'Native video channel not available (not iOS?) -- '
          'falling back to OpenCV VideoCapture');
    }

    // --- Attempt 2: OpenCV VideoCapture/VideoWriter ---
    await _convertVideoViaOpenCV(inputPath, outputPath);
    return const _NativeVideoResult();
  }

  /// Convert a video frame-by-frame using OpenCV's VideoCapture/VideoWriter.
  ///
  /// Works on platforms where OpenCV has codec support (typically Android).
  /// On iOS, H.264/265 decoding usually fails because the codec backend
  /// wasn't compiled in -- use the native platform channel instead.
  Future<void> _convertVideoViaOpenCV(
      String inputPath, String outputPath) async {
    final cap = cv.VideoCapture.fromFile(inputPath);
    if (!cap.isOpened) {
      debugPrint('VideoCapture failed to open file: $inputPath');
      throw Exception('Could not open video: $inputPath');
    }

    try {
      final fps = cap.get(cv.CAP_PROP_FPS);
      final width = cap.get(cv.CAP_PROP_FRAME_WIDTH).toInt();
      final height = cap.get(cv.CAP_PROP_FRAME_HEIGHT).toInt();
      final totalFrames = cap.get(cv.CAP_PROP_FRAME_COUNT).toInt();

      // Choose codec string based on output extension
      final ext = p.extension(outputPath).toLowerCase();
      String codec;
      if (ext == '.mov') {
        codec = 'avc1';
      } else if (ext == '.avi') {
        codec = 'XVID';
      } else {
        codec = 'mp4v';
      }

      final writer = cv.VideoWriter.fromFile(
        outputPath,
        codec,
        fps,
        (width, height),
      );

      if (!writer.isOpened) {
        // Fallback to mp4v
        writer.open(outputPath, 'mp4v', fps, (width, height));
      }

      try {
        var frameCount = 0;
        while (true) {
          final (success, frame) = cap.read();
          if (!success || frame.isEmpty) {
            frame.dispose();
            break;
          }

          final lineFrame = _frameToLineDrawing(frame);
          writer.write(lineFrame);

          lineFrame.dispose();
          frame.dispose();
          frameCount++;

          if (frameCount % 100 == 0) {
            debugPrint('  Video conversion: frame $frameCount/$totalFrames');
          }
        }

        debugPrint('  Video conversion complete: $frameCount frames');
      } finally {
        writer.release();
      }
    } finally {
      cap.release();
    }
  }

  /// Fallback video conversion: extract a key frame from the middle of the
  /// video using the video_thumbnail package (which uses platform-native APIs
  /// like AVAssetImageGenerator on iOS), then convert that single frame to a
  /// line drawing still image.
  ///
  /// This produces a .jpg output instead of a video. The bio gets a clean
  /// line drawing representation of the exercise. Full video-to-video
  /// conversion can be added later when the codec issue is resolved.
  Future<void> _convertVideoViaFrameExtraction(
      String inputPath, String outputPath) async {
    // Extract a frame from roughly the middle of the video.
    // video_thumbnail's timeMs defaults to 0 (first frame); we request the
    // midpoint for a more representative pose.
    //
    // Note: we don't have the duration without a video player, but
    // video_thumbnail with a non-zero timeMs will clamp to the video's
    // actual length, so requesting a large value just gives us the last
    // frame. We'll try 5 seconds in (a reasonable midpoint for exercises
    // capped at 30 seconds).
    final int targetTimeMs = (AppConfig.maxVideoSeconds * 1000) ~/ 2;

    // Try native channel first (most reliable on iOS).
    final tempDir = await getTemporaryDirectory();
    final tempFramePath = p.join(tempDir.path, 'frame_extract_temp.jpg');

    try {
      final result = await _thumbChannel.invokeMethod<Map<dynamic, dynamic>>(
        'extractFrame',
        {
          'inputPath': inputPath,
          'outputPath': tempFramePath,
          'timeMs': targetTimeMs,
        },
      );
      if (result != null && await File(tempFramePath).exists()) {
        // Native extraction succeeded — process with OpenCV below.
      } else {
        throw Exception('Native frame extraction returned null');
      }
    } catch (nativeErr) {
      debugPrint('Native frame extraction failed: $nativeErr');
      try {
        final logDir = await getApplicationDocumentsDirectory();
        final logFile = File(p.join(logDir.path, 'conversion_error.log'));
        await logFile.writeAsString(
          '${DateTime.now()} [native_thumb frame extract]\n$nativeErr\n\n',
          mode: FileMode.append,
        );
      } catch (_) {
        // Log-of-log swallow. Same rationale as the other log-of-log
        // sites in this file — the fallback log write is optional
        // forensic surface, and a filesystem failure here must not
        // recurse into loudSwallow's own logging path.
      }

      // Fallback to video_thumbnail package.
      Uint8List? bytes;
      for (final videoUri in [inputPath, 'file://$inputPath']) {
        try {
          bytes = await vt.VideoThumbnail.thumbnailData(
            video: videoUri,
            imageFormat: vt.ImageFormat.JPEG,
            maxWidth: 1920,
            quality: 95,
            timeMs: targetTimeMs,
          );
          if (bytes != null && bytes.isNotEmpty) break;
        } catch (e) {
          debugPrint('video_thumbnail failed with uri "$videoUri": $e');
        }
      }

      if (bytes == null || bytes.isEmpty) {
        throw Exception(
            'All frame extraction methods failed for: $inputPath');
      }

      await File(tempFramePath).writeAsBytes(bytes);
    }

    try {
      // Load and convert via the standard line drawing pipeline.
      final img = cv.imread(tempFramePath, flags: cv.IMREAD_COLOR);
      if (img.isEmpty) {
        throw Exception(
            'OpenCV could not read extracted frame: $tempFramePath');
      }

      try {
        final result = _frameToLineDrawing(img);
        cv.imwrite(outputPath, result,
            params: cv.VecI32.fromList([cv.IMWRITE_JPEG_QUALITY, 95]));
        result.dispose();
      } finally {
        img.dispose();
      }

      debugPrint('Video frame extraction fallback complete: $outputPath');
    } finally {
      // Clean up temp file.
      try {
        await File(tempFramePath).delete();
      } catch (_) {
        // Log-of-log swallow. Same rationale as the other log-of-log
        // sites in this file — the fallback log write is optional
        // forensic surface, and a filesystem failure here must not
        // recurse into loudSwallow's own logging path.
      }
    }
  }

  /// Convert a single BGR frame to a line drawing.
  ///
  /// Algorithm (ported from line-drawing-convert.skill):
  ///
  /// 1. Convert to grayscale
  /// 2. Pencil sketch via divide: invert -> blur -> divide original by inverse
  /// 3. Adaptive thresholding for crisp structural lines
  /// 4. Combine: take darkest (most line-like) of both results
  /// 5. Contrast boost: push light grays to white, keep dark lines
  /// 6. Convert back to BGR for output
  cv.Mat _frameToLineDrawing(cv.Mat frame) {
    final blurKernel = AppConfig.blurKernel;
    final thresholdBlock = AppConfig.thresholdBlock;
    final contrastLow = AppConfig.contrastLow;

    // Step 1: Convert to grayscale
    final gray = cv.cvtColor(frame, cv.COLOR_BGR2GRAY);

    // Step 2: Pencil sketch via divide
    // Create a white mat (255) for inversion: inv = 255 - gray
    final white = cv.Mat.ones(gray.rows, gray.cols, cv.MatType.CV_8UC1)
        .multiplyU8(255);
    final inv = cv.subtract(white, gray);

    // Blur the inverted image
    final blur = cv.gaussianBlur(inv, (blurKernel, blurKernel), 0);

    // Divisor: 255 - blur
    final invBlur = cv.subtract(white, blur);

    // Guard against divide-by-zero on saturated (over-exposed) frames.
    // Gym lighting can produce frames where blur is near 255, making
    // invBlur near 0 — which crashes cv.divide. Clamp to minimum 1 by
    // element-wise max against a ones-filled mat of matching shape.
    final onesMat = cv.Mat.ones(invBlur.rows, invBlur.cols, cv.MatType.CV_8UC1);
    final invBlurSafe = cv.max(invBlur, onesMat);

    // Divide: sketch = gray / (255 - blur) * 256
    final sketch = cv.divide(gray, invBlurSafe, scale: 256.0);

    // Step 3: Adaptive threshold for crisp structural lines
    final blurredGray = cv.gaussianBlur(gray, (5, 5), 0);
    final adaptive = cv.adaptiveThreshold(
      blurredGray,
      255,
      cv.ADAPTIVE_THRESH_GAUSSIAN_C,
      cv.THRESH_BINARY,
      thresholdBlock,
      2,
    );

    // Step 4: Combine — take the darkest pixel of both
    final combined = cv.min(sketch, adaptive);

    // Step 5: Contrast boost using convertTo(alpha, beta)
    // Formula: output = clip(input * alpha + beta, 0, 255)
    // We want: output = clip((input - contrastLow) * scale, 0, 255)
    // Which is: alpha = scale, beta = -contrastLow * scale
    final scale = 255.0 / (255 - contrastLow).clamp(1, 255);
    final beta = -contrastLow.toDouble() * scale;
    final boosted = combined.convertTo(cv.MatType.CV_8UC1,
        alpha: scale, beta: beta);

    // Step 6: Convert to BGR for output
    final result = cv.cvtColor(boosted, cv.COLOR_GRAY2BGR);

    // Dispose all intermediate matrices
    gray.dispose();
    white.dispose();
    inv.dispose();
    blur.dispose();
    invBlur.dispose();
    onesMat.dispose();
    invBlurSafe.dispose();
    sketch.dispose();
    blurredGray.dispose();
    adaptive.dispose();
    combined.dispose();
    boosted.dispose();

    return result;
  }

  /// Compress the raw video to a 720p H.264 archive copy and record the
  /// location on the exercise row. Fire-and-forget from [_processQueue] —
  /// any failure is swallowed and logged so it never disturbs the bio's
  /// main flow. No-op for non-video media.
  ///
  /// The raw file in `{Documents}/raw/` is intentionally NOT deleted here —
  /// that's a separate cleanup pass we can add in a follow-up once the
  /// archive pipeline has been exercised in the wild. Safer to over-retain.
  Future<void> _archiveRawVideo(ExerciseCapture done) async {
    // TODO: upload archived raw to private Supabase bucket once auth is in.
    if (done.mediaType != MediaType.video) return;

    try {
      final rawPath = done.absoluteRawFilePath;
      if (rawPath.isEmpty) return;
      if (!await File(rawPath).exists()) {
        debugPrint('Archive skipped — raw file missing for ${done.id}: $rawPath');
        return;
      }

      final docsDir = await getApplicationDocumentsDirectory();
      final archiveDir = p.join(docsDir.path, 'archive');
      await Directory(archiveDir).create(recursive: true);
      final archivePath = p.join(archiveDir, '${done.id}.mp4');

      final result = await _videoChannel.invokeMethod<Map>(
        'compressVideo',
        {
          'inputPath': rawPath,
          'outputPath': archivePath,
        },
      );

      if (result == null || result['success'] != true) {
        debugPrint('Archive compression returned unexpected result for ${done.id}: $result');
        return;
      }

      // TODO: delete the raw file from {Documents}/raw/ once we're confident
      // the archive is sufficient. Leaving the raw in place for now is safer
      // — a failed archive would otherwise lose the only copy of the clip.
      final updated = done.copyWith(
        archiveFilePath: PathResolver.toRelative(archivePath),
        archivedAt: DateTime.now(),
      );
      await _storage.saveExercise(updated);
      if (!_updateController.isClosed) {
        _updateController.add(updated);
      }
      debugPrint(
          'Archived raw video for ${done.id}: $archivePath '
          '(${result["sizeBytes"]} bytes)');
    } catch (e, stack) {
      debugPrint('Raw archive failed for ${done.id}: $e');
      try {
        final logDir = await getApplicationDocumentsDirectory();
        final logFile = File(p.join(logDir.path, 'conversion_error.log'));
        await logFile.writeAsString(
          '${DateTime.now()} [_archiveRawVideo]\n'
          'Exercise: ${done.id}\n'
          'Error: $e\n$stack\n\n',
          mode: FileMode.append,
        );
      } catch (_) {
        // Log-of-log swallow. Same rationale as the other log-of-log
        // sites in this file — the fallback log write is optional
        // forensic surface, and a filesystem failure here must not
        // recurse into loudSwallow's own logging path.
      }
    }
  }

  /// Reset the in-memory cache of the caller's self-face embedding so
  /// the next [_runSelfVerification] re-fetches via the RPC. Call from
  /// the Settings → Public profile flow after the user (re-)registers
  /// their face — otherwise captures within the same app session keep
  /// comparing against the stale pre-registration cache (which is null
  /// → all captures stamp `self_verified = NULL`).
  void resetSelfFaceEmbeddingCache() {
    _cachedSelfFaceEmbedding = null;
    _selfFaceEmbeddingFetched = false;
  }

  /// Self-trainer wave PR #5 (2026-05-25) — capture-time
  /// self-verification.
  ///
  /// Fire-and-forget pipeline:
  ///   1. Skip silently for rest periods (defensive — `_processQueue`
  ///      only invokes this after a successful conversion of a
  ///      photo/video, but a no-op here is cheaper than a stack trace).
  ///   2. Lazy-fetch the practitioner's self-face embedding from the
  ///      `get_my_self_face_embedding()` RPC. Cached for the rest of the
  ///      app session via [_cachedSelfFaceEmbedding].
  ///   3. NULL reference embedding (user hasn't opted in) → leave
  ///      `self_verified` at NULL (skip pipeline). Per the brief: "if
  ///      NULL, skip — leaves self_verified NULL".
  ///   4. Pick the media path: Safe Mode safe variant when the capture
  ///      was Safe-Mode-active (the original is never displayed per
  ///      `feedback_no_original_display_safe_mode`), otherwise the
  ///      converted file, falling back to raw if the converted path is
  ///      somehow missing (shouldn't happen post-conversion).
  ///   5. Invoke [FaceEmbeddingService.verifyAgainstReference] —
  ///      samples 3 evenly-spaced frames for videos, 1 frame for
  ///      photos. The native pipeline returns `{matched, distance}` or
  ///      a `noFace` / `error` outcome.
  ///   6. Stamp the result onto `exercises.self_verified`:
  ///      - `matched` outcome → `true`
  ///      - `noFace` / `error` outcome → `false` (conservative —
  ///        unknown defaults to "not verified" so the publish path
  ///        charges credits by default).
  ///   7. Persist via `_storage.saveExercise` and emit on
  ///      `_updateController` so live UI reflects the new flag.
  ///
  /// All steps are wrapped in a single try/catch — any exception is
  /// logged and swallowed. Self-verification failure NEVER blocks
  /// capture, conversion, or publish; the flag is purely informational.
  Future<void> _runSelfVerification(ExerciseCapture done) async {
    if (done.mediaType == MediaType.rest) return;

    try {
      // Step 2 — lazy fetch the reference embedding.
      if (!_selfFaceEmbeddingFetched) {
        _cachedSelfFaceEmbedding =
            await ApiClient.instance.getMySelfFaceEmbedding();
        _selfFaceEmbeddingFetched = true;
        if (_cachedSelfFaceEmbedding == null) {
          debugPrint(
            '[ConversionService] self-verification: no '
            'practitioners.face_embedding registered — skipping '
            '(self_verified stays NULL)',
          );
        } else {
          debugPrint(
            '[ConversionService] self-verification: fetched reference '
            'embedding (${_cachedSelfFaceEmbedding!.length} floats)',
          );
        }
      }
      final reference = _cachedSelfFaceEmbedding;
      if (reference == null || reference.isEmpty) {
        // Step 3 — NULL reference → skip per brief.
        return;
      }

      // Step 4 — pick the media path. For Safe Mode captures, the safe
      // variant is the only surface the practitioner ever shares OR
      // sees post-conversion (per `feedback_no_original_display_safe_mode`)
      // so it's also the only surface that should drive verification.
      // For non-Safe-Mode captures, fall through to the converted file
      // (line drawing for video / line jpg for photo), then raw as a
      // last-resort.
      String? mediaPath;
      if (done.safeModeActive && done.absoluteSafeRawFilePath != null) {
        mediaPath = done.absoluteSafeRawFilePath;
      } else if (done.convertedFilePath != null) {
        mediaPath = PathResolver.resolve(done.convertedFilePath!);
      } else if (done.rawFilePath.isNotEmpty) {
        mediaPath = done.absoluteRawFilePath;
      }
      if (mediaPath == null ||
          mediaPath.isEmpty ||
          !await File(mediaPath).exists()) {
        debugPrint(
          '[ConversionService] self-verification: no usable media path '
          'for ${done.id} (mediaPath=$mediaPath) — skipping',
        );
        return;
      }

      // Step 5 — invoke the native verify pipeline.
      final outcome =
          await FaceEmbeddingService.instance.verifyAgainstReference(
        mediaPath: mediaPath,
        reference: reference,
      );

      // Step 6 — resolve the tri-state value.
      //
      // `matched` outcome → true. Every other outcome (`noFace`,
      // `error`) → false (conservative, per the brief: "if reference
      // embedding is NULL OR native compare throws OR no face detected
      // → self_verified = false").
      final bool verifiedValue = outcome.verifiedValue;

      // Step 7 — persist + emit. Re-read from storage to avoid
      // clobbering any intermediate update (e.g. raw-archive completion
      // racing this pipeline on the same exercise id).
      final base = (await _storage.getExerciseById(done.id)) ?? done;
      final updated = base.copyWith(selfVerified: verifiedValue);
      await _storage.saveExercise(updated);
      if (!_updateController.isClosed) {
        _updateController.add(updated);
      }
      debugPrint(
        '[ConversionService] self-verification: stamped '
        'self_verified=$verifiedValue for ${done.id} '
        '(noFace=${outcome.isNoFace} error=${outcome.errorMessage})',
      );
    } catch (e, stack) {
      // Sanctioned swallow — verification failure is non-fatal by
      // contract. Log via the conversion-error log so the long-press
      // diagnostic sheet on the "N failed" pill surfaces the cause if
      // a pattern emerges.
      debugPrint(
        '[ConversionService] self-verification threw for ${done.id}: $e',
      );
      try {
        final logDir = await getApplicationDocumentsDirectory();
        final logFile = File(p.join(logDir.path, 'conversion_error.log'));
        await logFile.writeAsString(
          '${DateTime.now()} [_runSelfVerification]\n'
          'Exercise: ${done.id}\n'
          'Error: $e\n$stack\n\n',
          mode: FileMode.append,
        );
      } catch (_) {
        // Log-of-log swallow. Same rationale as elsewhere in this file.
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Variant-level diagnostic log (2026-05-14 hardening)
  //
  // The per-call try/catch refactor in [_processQueue] + [regenerateHeroThumbnails]
  // surfaces individual B&W / color / line failures instead of silently
  // swallowing them via a single outer catch. Each failure lands in
  // `{Documents}/conversion_error.log` with a distinct `[VARIANT bw|color|line]`
  // prefix so the existing failed-pill long-press sheet (PR #213) can
  // distinguish them from full conversion failures.
  //
  // Eager backfill (see [backfillMissingVariants] below) emits matching
  // `[BACKFILL]` entries so practitioners can see what regenerated.
  // ---------------------------------------------------------------------------

  /// Append a single `[VARIANT <kind>]` entry to the conversion-error log
  /// for [exerciseId]. Best-effort — a filesystem failure here MUST NOT
  /// propagate (caller is already on an exception path); we deliberately
  /// don't route through `loudSwallow` because that would recurse if the
  /// failure mode is "documents dir unwritable".
  ///
  /// [contextKind] is an optional discriminator (e.g. `regen`, `backfill`,
  /// Handle a [SafeModeRejection] bubbling up from the conversion
  /// pipeline. Reads the row from SQLite (snapshot for the listener
  /// payload), deletes it, emits on both the rejection stream (so the
  /// capture screen toasts) AND on [onExerciseRemoved] (so Studio /
  /// ClientSessions drop the card from their in-memory list in the
  /// same paint as the SQLite delete).
  ///
  /// Visible for testing — the orphan-after-rejection regression in
  /// `app/test/services/conversion_service_rejection_test.dart` drives
  /// this directly without standing up the full conversion queue. In
  /// production it's only called from the [_processQueue] catch block.
  ///
  /// SQLite delete failures are logged but not re-thrown — both the
  /// toast and the removal event still fire so the listener can at
  /// least drop the in-memory card. Pre-2026-05-25 behaviour swallowed
  /// the delete failure AND never emitted any removal signal, leaving
  /// the orphan card stuck in `converting` state until app restart.
  @visibleForTesting
  Future<void> handleSafeModeRejection(SafeModeRejection rejection) async {
    debugPrint('Safe Mode rejected ${rejection.exerciseId}: $rejection');
    // Snapshot the row BEFORE deleting so the removal payload carries
    // the last-known ExerciseCapture (session id, position, etc — the
    // listener uses these to scrub sibling state). Null is acceptable
    // (the row may already be gone if a parallel cleanup ran first).
    ExerciseCapture? snapshot;
    try {
      snapshot = await _storage.getExerciseById(rejection.exerciseId);
    } catch (e) {
      debugPrint(
          'Safe Mode rejection: snapshot read failed for '
          '${rejection.exerciseId}: $e');
    }
    try {
      await _storage.deleteExercise(rejection.exerciseId);
    } catch (e) {
      debugPrint(
          'Safe Mode rejection: deleteExercise failed for '
          '${rejection.exerciseId}: $e');
    }
    if (!_rejectionController.isClosed) {
      _rejectionController.add(rejection);
    }
    // Emit on the removal stream regardless of whether the SQLite
    // delete itself succeeded. Even if the delete throws, telling
    // Studio "drop this card from memory" is the right user-facing
    // outcome — a stuck spinner is worse than a card that's gone from
    // the UI but lingers in the DB as orphaned bytes (covered by the
    // periodic cleanup sweep).
    if (!_removalController.isClosed) {
      _removalController.add(ExerciseRemoval(
        exerciseId: rejection.exerciseId,
        exercise: snapshot,
        reason: 'safe_mode_rejection',
      ));
    }
    notifyListeners();
  }

  /// Best-effort delete of a file at an absolute path. Swallows
  /// every error — used by the Safe Mode rejection path to tidy
  /// up partial outputs before throwing [SafeModeRejection]. Skips
  /// silently when [path] is null or the file doesn't exist.
  Future<void> _deleteSafely(String? path) async {
    if (path == null || path.isEmpty) return;
    try {
      final f = File(path);
      if (await f.exists()) {
        await f.delete();
      }
    } catch (e) {
      debugPrint('_deleteSafely($path) ignored: $e');
    }
  }

  /// Fire-and-forget telemetry write for the 2026-05-25 accept-zero-
  /// detection branch. Computes a numerics-only scene fingerprint
  /// (channel means, entropy, complexity) off the raw capture's first
  /// frame and posts it through [ApiClient.recordSafeModeCaptureEvent].
  ///
  /// Failure handling: every error is caught and logged via debugPrint
  /// only. The capture flow MUST NOT see a throw from this method
  /// (spec acceptance criterion 9). The caller wraps the invocation in
  /// `unawaited(...)`; this method's own try/catch is the second guard
  /// against bubbling.
  ///
  /// Privacy posture: no image bytes leave the device — only aggregate
  /// numerics. The scene fingerprint distinguishes "empty room" from
  /// "complex scene Vision missed" by exposing outliers in the audit
  /// feed without leaking pixels.
  Future<void> _recordSafeModeAcceptedEmpty({
    required ExerciseCapture exercise,
    required double missRate,
  }) async {
    try {
      final fingerprint =
          await _computeSceneFingerprint(exercise.absoluteRawFilePath);
      final metadata = <String, dynamic>{
        'exercise_id': exercise.id,
        'media_type': exercise.mediaType == MediaType.video ? 'video' : 'photo',
        'miss_rate': missRate,
        'scene_fingerprint': fingerprint,
      };
      await ApiClient.instance.recordSafeModeCaptureEvent(
        premisesId: exercise.capturedInPremisesId,
        metadata: metadata,
      );
    } catch (e) {
      debugPrint(
          'recordSafeModeCaptureEvent fire-and-forget failed for '
          '${exercise.id}: $e');
    }
  }

  /// Compute a numerics-only scene fingerprint off the first frame of
  /// the raw capture at [rawFilePath]. Returns:
  ///
  ///   * `mean_r`, `mean_g`, `mean_b` — int channel means 0..255
  ///   * `grayscale_entropy` — Shannon entropy of the luminance
  ///     histogram, 0..8 (256 bins, max ~8 bits)
  ///   * `complexity_score` — Laplacian-variance proxy, clamped 0..1
  ///     by dividing by a typical empty-scene baseline (~50). Higher
  ///     values mean "more edges / structure"; an empty wall sits near
  ///     0, a busy outdoor scene approaches 1.
  ///
  /// Photos and videos both use the first frame (photo: the image
  /// itself; video: t=0 sample). Video fingerprint extraction relies
  /// on `package:video_thumbnail`, already in pubspec for hero
  /// thumbnails.
  ///
  /// Defensive: never throws. On any decode failure returns
  /// `{"error": "decode_failed"}` so the audit row still writes with
  /// a clear marker. The fingerprint is informational, not load-
  /// bearing — a missing reading degrades to "we accepted this but
  /// can't characterise the scene."
  Future<Map<String, dynamic>> _computeSceneFingerprint(
    String rawFilePath,
  ) async {
    try {
      // Pull a small decoded image (256x256 max) for cheap math.
      // Videos go through video_thumbnail to grab t=0 as JPEG bytes;
      // photos read the file bytes directly.
      Uint8List? bytes;
      final lower = rawFilePath.toLowerCase();
      final isVideo = lower.endsWith('.mp4') ||
          lower.endsWith('.mov') ||
          lower.endsWith('.m4v');
      if (isVideo) {
        bytes = await vt.VideoThumbnail.thumbnailData(
          video: rawFilePath,
          imageFormat: vt.ImageFormat.JPEG,
          maxWidth: 256,
          quality: 60,
          timeMs: 0,
        );
      } else {
        bytes = await File(rawFilePath).readAsBytes();
      }
      if (bytes == null || bytes.isEmpty) {
        return <String, dynamic>{'error': 'empty_frame'};
      }
      // Use opencv_dart (already imported) for decode + math.
      // imdecode handles JPEG/HEIC/PNG transparently.
      final mat = cv.imdecode(bytes, cv.IMREAD_COLOR);
      if (mat.isEmpty) {
        return <String, dynamic>{'error': 'decode_failed'};
      }
      // Resize down to 256x256 for cheap statistics.
      final small = cv.resize(mat, (256, 256));
      mat.dispose();
      // Channel means — OpenCV `mean` returns Scalar(b, g, r, a).
      final m = cv.mean(small);
      final meanB = m.val1.round().clamp(0, 255);
      final meanG = m.val2.round().clamp(0, 255);
      final meanR = m.val3.round().clamp(0, 255);

      // Grayscale conversion for entropy + complexity.
      final gray = cv.cvtColor(small, cv.COLOR_BGR2GRAY);

      // Walk the 256x256 grayscale pixels manually to build a
      // histogram. Avoids the calcHist API surface which wants
      // VecI32 / VecF32 wrappers — direct iteration is cheap on a
      // 65k-pixel small image and keeps the helper resilient to
      // opencv_dart API drift.
      final histogram = List<int>.filled(256, 0);
      final rows = gray.rows;
      final cols = gray.cols;
      var totalPixels = 0;
      for (var y = 0; y < rows; y++) {
        for (var x = 0; x < cols; x++) {
          final v = gray.at<int>(y, x);
          if (v >= 0 && v < 256) {
            histogram[v] += 1;
            totalPixels += 1;
          }
        }
      }
      double entropy = 0;
      if (totalPixels > 0) {
        for (var i = 0; i < 256; i++) {
          if (histogram[i] == 0) continue;
          final p = histogram[i] / totalPixels;
          // log base 2 = ln(p) / ln(2)
          entropy -= p * (math.log(p) / math.ln2);
        }
      }

      // Laplacian variance as a complexity proxy. cv.laplacian + cv.meanStdDev.
      final lap = cv.laplacian(gray, cv.MatType.CV_64F);
      final stats = cv.meanStdDev(lap);
      final stddev = stats.$2.val1;
      final laplacianVar = stddev * stddev;
      // Normalise to 0..1 by dividing by a typical busy-scene baseline
      // (~250 variance for highly textured frames). Empty walls land
      // near 0, complex outdoor scenes approach 1. Divisor chosen
      // pragmatically — open question 12.2 in the spec to refine
      // against real fixtures.
      const baseline = 250.0;
      final complexity = (laplacianVar / baseline).clamp(0.0, 1.0);

      gray.dispose();
      lap.dispose();
      small.dispose();

      return <String, dynamic>{
        'mean_r': meanR,
        'mean_g': meanG,
        'mean_b': meanB,
        'grayscale_entropy': entropy,
        'complexity_score': complexity,
      };
    } catch (e) {
      debugPrint('_computeSceneFingerprint failed for $rawFilePath: $e');
      return <String, dynamic>{'error': 'decode_failed'};
    }
  }

  /// `regen_no_source`) so the same `variant` shows up with different
  /// context labels in the log without needing a separate log-writer per
  /// caller.
  Future<void> _logVariantFailure({
    required String exerciseId,
    required String variant,
    required Object error,
    StackTrace? stack,
    String contextKind = 'post_conversion',
  }) async {
    debugPrint('Variant thumbnail failed [$variant/$contextKind] for $exerciseId: $error');
    try {
      final logDir = await getApplicationDocumentsDirectory();
      final logFile = File(p.join(logDir.path, 'conversion_error.log'));
      // Format mirrors the existing entry shape so the parser in
      // [ConversionErrorLogSheet] keeps working:
      //   {DateTime}
      //   Exercise: {id}
      //   ...
      //   Error: {e}
      //
      //   Stack:
      //   {stack}
      final stackBlock = stack == null
          ? ''
          : '\nStack:\n${stack.toString().split('\n').take(3).join('\n')}\n';
      await logFile.writeAsString(
        '${DateTime.now()} [VARIANT $variant/$contextKind]\n'
        'Exercise: $exerciseId\n'
        'Error: $error\n'
        '$stackBlock\n',
        mode: FileMode.append,
      );
    } catch (_) {
      // Log-of-log swallow. Sanctioned site (same rationale as elsewhere
      // in this file): writing the conversion-error log already failed,
      // so any further redirect would just recurse on the same failure.
    }
  }

  /// Append a `[BACKFILL <event>]` entry to the conversion-error log. Used
  /// by [backfillMissingVariants] to make eager backfill activity visible
  /// alongside variant + conversion failures in the long-press sheet.
  ///
  /// [event] is a short tag: `start`, `success`, `skip`. Failures land via
  /// `_logVariantFailure(... contextKind: 'backfill')` so the existing
  /// `[VARIANT ...]` view captures them too.
  Future<void> _logBackfillEvent({
    required String exerciseId,
    required String event,
    String? variant,
    String? detail,
  }) async {
    debugPrint('Backfill [$event] $variant for $exerciseId${detail == null ? '' : ' — $detail'}');
    try {
      final logDir = await getApplicationDocumentsDirectory();
      final logFile = File(p.join(logDir.path, 'conversion_error.log'));
      final variantPart = variant == null ? '' : ' $variant';
      await logFile.writeAsString(
        '${DateTime.now()} [BACKFILL $event$variantPart]\n'
        'Exercise: $exerciseId\n'
        '${detail == null ? '' : 'Detail: $detail\n'}\n',
        mode: FileMode.append,
      );
    } catch (_) {
      // Sanctioned log-of-log swallow.
    }
  }

  /// Walk every video exercise in [exercises] and re-run extractFrame for
  /// any of the three thumbnail variants (`_thumb.jpg`, `_thumb_color.jpg`,
  /// `_thumb_line.jpg`) that are missing on disk. Each per-variant call is
  /// wrapped in granular try/catch; one variant failing doesn't poison
  /// the others. Successes emit on [onConversionUpdate] so listeners can
  /// rebuild and pick up the freshly-stamped files.
  ///
  /// Photo variants are produced atomically by the OpenCV isolate in
  /// [_extractPhotoThumbnailVariants] — we don't re-run that isolate
  /// piecemeal (it's a single compute() call), but we still emit a
  /// per-photo BACKFILL log entry if the photo's `_thumb.jpg` is missing
  /// so the practitioner sees it.
  ///
  /// Runs sequentially (one exercise at a time) — the native extractFrame
  /// channel isn't reentrant. Designed to run in the background on
  /// session-open without blocking the UI.
  ///
  /// No-op for the queue-processor path (which writes variants
  /// atomically). Designed for the "session opened with stale / missing
  /// variants" case — e.g. fresh reinstall, manual file delete, partial
  /// failure pre-hardening.
  Future<void> backfillMissingVariants(List<ExerciseCapture> exercises) async {
    if (exercises.isEmpty) return;
    final dir = await getApplicationDocumentsDirectory();
    final thumbDir = p.join(dir.path, 'thumbnails');
    try {
      await Directory(thumbDir).create(recursive: true);
    } catch (_) {
      // If we can't even create the directory, every variant write would
      // fail. Bail out silently — _logVariantFailure would just recurse
      // on the same filesystem state.
      return;
    }

    for (final exercise in exercises) {
      if (exercise.isRest) continue;
      // Only act on `done` conversions — pending / converting / failed
      // exercises don't have stable variant files yet (the queue
      // processor produces them atomically). Backfill is for the case
      // where a previous run completed but variants got lost since.
      if (exercise.conversionStatus != ConversionStatus.done) continue;

      final bwPath = p.join(thumbDir, '${exercise.id}_thumb.jpg');
      final colorPath = p.join(thumbDir, '${exercise.id}_thumb_color.jpg');
      final linePath = p.join(thumbDir, '${exercise.id}_thumb_line.jpg');
      final thumbBwPath = p.join(thumbDir, '${exercise.id}_thumb_bw.jpg');

      final bwMissing = !await File(bwPath).exists();
      final colorMissing = !await File(colorPath).exists();
      final lineMissing = !await File(linePath).exists();
      // Photos-only: the bytes-baked B&W sibling. Videos don't produce
      // one — for videos the canonical `_thumb.jpg` already IS baked
      // greyscale bytes (segmentation pipeline), so `thumbnail_url`
      // still serves the B&W treatment cleanly. Only photos need this
      // extra sibling because their `_thumb_color.jpg` is the colour
      // bytes and the lobby otherwise relies on a CSS filter to fake
      // grayscale at render time.
      final isPhoto = exercise.mediaType == MediaType.photo;
      final thumbBwMissing = isPhoto && !await File(thumbBwPath).exists();

      if (!bwMissing && !colorMissing && !lineMissing && !thumbBwMissing) {
        continue;
      }

      if (exercise.mediaType == MediaType.photo) {
        // Photos: variants are produced atomically by the OpenCV
        // isolate in _extractPhotoThumbnailVariants. Re-run the whole
        // pass if ANY of the four is missing — the isolate is
        // idempotent + handles missing converted JPG gracefully.
        await _logBackfillEvent(
          exerciseId: exercise.id,
          event: 'start',
          variant: 'photo_all',
          detail:
              'bwMissing=$bwMissing colorMissing=$colorMissing lineMissing=$lineMissing thumbBwMissing=$thumbBwMissing',
        );
        try {
          final rawAbs = exercise.absoluteRawFilePath;
          if (rawAbs.isEmpty || !await File(rawAbs).exists()) {
            await _logVariantFailure(
              exerciseId: exercise.id,
              variant: 'photo_all',
              error: StateError('Raw file missing on disk'),
              contextKind: 'backfill',
            );
            continue;
          }
          await compute(_extractPhotoThumbnailVariants, _PhotoThumbArgs(
            rawPath: rawAbs,
            convertedPath: exercise.absoluteConvertedFilePath,
            bwOutPath: bwPath,
            colorOutPath: colorPath,
            lineOutPath: linePath,
            thumbBwOutPath: thumbBwPath,
          ));
          // Re-stamp thumbnailPath if it isn't pointing at the bw
          // variant already (legacy rows may still have
          // thumbnailPath = rawFilePath). Also flip thumbnailsDirty
          // so the next publish re-uploads the freshly-baked
          // `_thumb_bw.jpg` alongside the other variants — without
          // this stamp the fast-path skip ALL uploads on a
          // pre-uploaded raw archive and the cloud poster stays
          // stale.
          final next = exercise.copyWith(
            thumbnailPath: await File(bwPath).exists()
                ? PathResolver.toRelative(bwPath)
                : exercise.thumbnailPath,
            thumbnailsDirty: thumbBwMissing ? true : exercise.thumbnailsDirty,
          );
          await _storage.saveExercise(next);
          if (!_updateController.isClosed) {
            _updateController.add(next);
          }
          await _logBackfillEvent(
            exerciseId: exercise.id,
            event: 'success',
            variant: 'photo_all',
          );
        } catch (e, st) {
          await _logVariantFailure(
            exerciseId: exercise.id,
            variant: 'photo_all',
            error: e,
            stack: st,
            contextKind: 'backfill',
          );
        }
        continue;
      }

      // Video branch — per-variant extractFrame call, each independently
      // gated + logged. Mirrors the per-call try/catch in [_processQueue]
      // so a partial failure leaves the successful variants on disk.
      final sourcePath = await _pickThumbnailSource(exercise);
      if (sourcePath == null) {
        await _logVariantFailure(
          exerciseId: exercise.id,
          variant: 'bw',
          error: StateError('No raw/archive source available'),
          contextKind: 'backfill_no_source',
        );
        continue;
      }
      // Use the saved Hero offset if we have one; otherwise let native
      // motion-peak pick (round-tripping the picked offset into the
      // model is handled by the post-conversion path, not here — this
      // is purely a missing-file recovery).
      final offset = exercise.focusFrameOffsetMs ?? 0;
      final useAutoPick = exercise.focusFrameOffsetMs == null;

      ExerciseCapture? updated;

      if (bwMissing) {
        await _logBackfillEvent(
          exerciseId: exercise.id,
          event: 'start',
          variant: 'bw',
        );
        try {
          final bwResp = await _thumbChannel
              .invokeMethod<Map<dynamic, dynamic>>('extractFrame', {
            'inputPath': sourcePath,
            'outputPath': bwPath,
            'timeMs': offset,
            'autoPick': useAutoPick,
            'grayscale': true,
          }).timeout(const Duration(seconds: 30));
          final pickedMs = (bwResp?['timeMs'] as int?) ?? offset;
          updated = (updated ?? exercise).copyWith(
            thumbnailPath: PathResolver.toRelative(bwPath),
            focusFrameOffsetMs: pickedMs,
          );
          await _logBackfillEvent(
            exerciseId: exercise.id,
            event: 'success',
            variant: 'bw',
          );
        } catch (e, st) {
          await _logVariantFailure(
            exerciseId: exercise.id,
            variant: 'bw',
            error: e,
            stack: st,
            contextKind: 'backfill',
          );
        }
      }

      // Hero offset we feed into color + line. Prefer the freshly-picked
      // offset from the BW backfill above (carries the motion-peak pick
      // if autoPick fired). Otherwise the existing model value.
      final hero = updated?.focusFrameOffsetMs ?? offset;

      if (colorMissing) {
        await _logBackfillEvent(
          exerciseId: exercise.id,
          event: 'start',
          variant: 'color',
        );
        try {
          await _thumbChannel
              .invokeMethod<Map<dynamic, dynamic>>('extractFrame', {
            'inputPath': sourcePath,
            'outputPath': colorPath,
            'timeMs': hero,
            'autoPick': false,
            'grayscale': false,
          }).timeout(const Duration(seconds: 30));
          await _logBackfillEvent(
            exerciseId: exercise.id,
            event: 'success',
            variant: 'color',
          );
        } catch (e, st) {
          await _logVariantFailure(
            exerciseId: exercise.id,
            variant: 'color',
            error: e,
            stack: st,
            contextKind: 'backfill',
          );
        }
      }

      if (lineMissing && exercise.convertedFilePath != null) {
        await _logBackfillEvent(
          exerciseId: exercise.id,
          event: 'start',
          variant: 'line',
        );
        try {
          final convertedPath = PathResolver.resolve(exercise.convertedFilePath!);
          await _thumbChannel
              .invokeMethod<Map<dynamic, dynamic>>('extractFrame', {
            'inputPath': convertedPath,
            'outputPath': linePath,
            'timeMs': hero,
            'autoPick': false,
            'grayscale': false,
          }).timeout(const Duration(seconds: 30));
          await _logBackfillEvent(
            exerciseId: exercise.id,
            event: 'success',
            variant: 'line',
          );
        } catch (e, st) {
          await _logVariantFailure(
            exerciseId: exercise.id,
            variant: 'line',
            error: e,
            stack: st,
            contextKind: 'backfill',
          );
        }
      } else if (lineMissing) {
        // No converted file → line variant can't be produced. Log so
        // the practitioner sees why the placeholder will stick around.
        await _logBackfillEvent(
          exerciseId: exercise.id,
          event: 'skip',
          variant: 'line',
          detail: 'No convertedFilePath',
        );
      }

      if (updated != null) {
        await _storage.saveExercise(updated);
        if (!_updateController.isClosed) {
          _updateController.add(updated);
        }
      }
    }
  }

  /// Number of items currently waiting in the queue.
  int get queueLength => _queue.length + (_processing ? 1 : 0);

  /// Whether the service is currently processing conversions.
  bool get isProcessing => _processing;

  /// Safe Mode v2 (2026-05-23) — re-process a single photo exercise's
  /// safe variant against the current algorithm (face-recognition
  /// based) using the latest subject embedding.
  ///
  /// Eligible iff:
  ///   * `media_type == photo` (v2 photos only — video Safe Mode is
  ///     deferred per the spec).
  ///   * Raw original is still available locally OR within the 90-day
  ///     cloud retention window.
  ///   * The current subject embedding exists for the bound client.
  ///
  /// Flow:
  ///   1. Resolve the raw original path (local — cloud fallback is
  ///      future work; today raw photos stay on-device under their
  ///      `archive/` directory).
  ///   2. Invoke the native `applySafeModeV2ToPhoto(srcPath, destPath,
  ///      subjectEmbeddings, threshold)` with the new subject embedding(s).
  ///      Multi-reference (2026-05-24): the embedding list contains 1–8
  ///      vectors; during the back-compat window the single legacy avatar
  ///      embedding is wrapped in a one-element list.
  ///   3. Overwrite the safe-variant JPG at `{exerciseId}_safe.jpg`.
  ///   4. Stamp `safeModeAlgorithmVersion = kSafeModeAlgorithmVersion`
  ///      on the SQLite row + mark thumbnails dirty so the next publish
  ///      re-uploads.
  ///
  /// Returns true on success, false on any failure (file missing,
  /// embedding missing, native call throws). Caller surfaces the
  /// result with a toast.
  ///
  /// [thresholdOverride] — debug-tuning sheet entry point. Now controls
  /// the solo-face floor (see [kSafeModeV2SoloFloor]). When non-null
  /// it takes precedence over both the SharedPreferences-persisted
  /// override and the compile-time default. Production callers leave
  /// it null and the live-resolved floor falls back through the
  /// standard chain.
  Future<bool> reprocessSafeMode(
    String exerciseId, {
    double? thresholdOverride,
  }) async {
    final ex = await _storage.getExerciseById(exerciseId);
    if (ex == null) return false;
    if (ex.mediaType != MediaType.photo) return false;
    if (!ex.safeModeActive) return false;

    // Step 1: resolve raw original. Today raw originals live under
    // {Documents}/raw/ via the captures pipeline; the archive/
    // directory holds the 720p compressed copy for videos. For
    // photos the rawFilePath IS the captured JPG. Cloud retention
    // fallback (signed URL download from raw-archive) is documented
    // future work — at retention, the exercise becomes ineligible.
    final rawAbs = ex.absoluteRawFilePath;
    final rawFile = File(rawAbs);
    if (!await rawFile.exists()) return false;

    // Step 2: resolve the subject embedding(s). Wave-D (2026-05-24)
    // prefers the multi-reference local cache (3-8 vectors) and falls
    // back to the legacy single-embedding cache for clients enrolled
    // before this wave landed. If neither has bytes, bail rather than
    // running with a stale fingerprint.
    final session = ex.sessionId == null
        ? null
        : await _storage.getSession(ex.sessionId!);
    final clientId = session?.clientId;
    if (clientId == null || clientId.isEmpty) return false;
    final List<Uint8List> embeddings =
        await _resolveSubjectEmbeddings(_storage, clientId);
    if (embeddings.isEmpty) return false;

    // Step 3: invoke the native pass.
    final docsDir = await getApplicationDocumentsDirectory();
    final convertedDir = p.join(docsDir.path, 'converted');
    try {
      await Directory(convertedDir).create(recursive: true);
    } catch (_) {}
    final destPath = p.join(convertedDir, '${ex.id}_safe.jpg');

    final threshold = await _resolveSafeModeV2Threshold(thresholdOverride);
    try {
      // Multi-reference (2026-05-24, Wave-D): native takes
      // `subjectEmbeddings: List<Data>`. We pass whatever the slot
      // resolver returned — a fully-enrolled client has 3-8 vectors;
      // a back-compat legacy client has the single avatar vector.
      final dynamic resp = await _videoChannel
          .invokeMethod<Map<dynamic, dynamic>>(
            'applySafeModeV2ToPhoto',
            <String, dynamic>{
              'srcPath': rawAbs,
              'destPath': destPath,
              'subjectEmbeddings': embeddings,
              'threshold': threshold,
            },
          )
          .timeout(const Duration(seconds: 30));
      if (resp == null) return false;
    } catch (e, stack) {
      try {
        final logDir = await getApplicationDocumentsDirectory();
        final logFile = File(p.join(logDir.path, 'conversion_error.log'));
        await logFile.writeAsString(
          '${DateTime.now()} [applySafeModeV2ToPhoto re-process failed]\n$e\n$stack\n\n',
          mode: FileMode.append,
        );
      } catch (_) {
        // Sanctioned log-of-log swallow.
      }
      return false;
    }

    if (!await File(destPath).exists()) return false;

    // Step 4: stamp the new algorithm version + mark thumbs dirty so
    // the next publish re-uploads. The safe-variant relative path
    // doesn't change (same `_safe.jpg` slot), so safeRawFilePath
    // round-trips unchanged.
    final updated = ex.copyWith(
      safeRawFilePath: PathResolver.toRelative(destPath),
      safeModeAlgorithmVersion: kSafeModeAlgorithmVersion,
      thumbnailsDirty: true,
    );
    await _storage.saveExercise(updated);
    if (!_updateController.isClosed) {
      _updateController.add(updated);
    }
    notifyListeners();
    return true;
  }

  // Note: dispose() intentionally not overridden. This service is a singleton
  // that lives for the entire app lifetime. Closing the StreamController would
  // cause "Bad state: Cannot add new events after calling close" if a screen
  // that holds a reference triggers disposal.
}

/// Result of a single [ConversionService._convert] call. Carries the
/// primary line-drawing path plus the optional segmented-color raw
/// variant and mask sidecar (populated only when the native dual-output
/// + mask passes succeeded — each is independently best-effort).
class _ConvertResult {
  final String convertedPath;
  final String? segmentedPath;
  final String? maskPath;
  // Mutable so the accept-zero-detection branch in [_processQueue]
  // can null out the safe variant in place once it's been deleted
  // (the rest of the downstream save block keys off `safePath !=
  // null` to stamp `safeRawFilePath` on the exercise row — falling
  // through with null routes the publish flow back to the normal
  // raw-archive upload, no swap). Without this mutation we'd thread
  // a copy through and the save block would still try to stamp a
  // path to a file that no longer exists.
  String? safePath;
  // Vision miss-rate from the Safe Mode pass when one ran. 0.0 when
  // no Safe Mode pass happened or every frame found a human. Used by
  // the conversion success branch to decide whether to keep the
  // capture (<= kSafeModeMaxMissRate) or throw [SafeModeRejection].
  final double safeMissRate;

  _ConvertResult({
    required this.convertedPath,
    this.segmentedPath,
    this.maskPath,
    this.safePath,
    this.safeMissRate = 0.0,
  });

  /// Null out the safe variant after the accept-zero-detection branch
  /// has deleted the file. See the class-level comment on [safePath]
  /// for the rationale.
  void clearSafeVariant() {
    safePath = null;
  }
}

/// Result of the native-side `convertVideo` platform channel call.
/// Plain value object — carries the optional sidecar paths the caller
/// needs to thread back onto [ExerciseCapture]. The `safePath` is the
/// Safe Mode raw archive (bystander-blurred), present only when the
/// native pipeline was given a `safeOutputPath` AND the compositing
/// pass produced a non-empty file. Failure of the safe pass never
/// blocks the line drawing.
class _NativeVideoResult {
  final String? segmentedPath;
  final String? maskPath;
  final String? safePath;
  // Vision miss-rate the native `SafeModeProcessor` accumulated over
  // the conversion run. 0.0 when no Safe Mode pass ran (no
  // `safeOutputPath` passed in); otherwise [0, 1].
  final double safeMissRate;

  const _NativeVideoResult({
    this.segmentedPath,
    this.maskPath,
    this.safePath,
    this.safeMissRate = 0.0,
  });
}

/// Arguments for the photo-convert isolate entry. Must be a const-constructible
/// value type so it survives isolate boundary serialisation cleanly.
class _PhotoConvertArgs {
  final String inputPath;
  final String outputPath;
  final int blurKernel;
  final int thresholdBlock;
  final int contrastLow;

  const _PhotoConvertArgs({
    required this.inputPath,
    required this.outputPath,
    required this.blurKernel,
    required this.thresholdBlock,
    required this.contrastLow,
  });
}

/// Top-level isolate entry for photo line drawing conversion.
///
/// Must be a top-level function (not a closure or method) so `compute()`
/// can invoke it on a background isolate. All OpenCV Mat allocations stay
/// inside this isolate — only file paths cross the boundary.
void _convertPhotoIsolate(_PhotoConvertArgs args) {
  final img = cv.imread(args.inputPath, flags: cv.IMREAD_COLOR);
  if (img.isEmpty) {
    throw Exception('Could not read image: ${args.inputPath}');
  }

  try {
    final result = _frameToLineDrawingSync(
      img,
      blurKernel: args.blurKernel,
      thresholdBlock: args.thresholdBlock,
      contrastLow: args.contrastLow,
    );

    final ext = p.extension(args.outputPath).toLowerCase();
    if (ext == '.jpg' || ext == '.jpeg') {
      cv.imwrite(args.outputPath, result,
          params: cv.VecI32.fromList([cv.IMWRITE_JPEG_QUALITY, 95]));
    } else if (ext == '.png') {
      cv.imwrite(args.outputPath, result,
          params: cv.VecI32.fromList([cv.IMWRITE_PNG_COMPRESSION, 3]));
    } else {
      cv.imwrite(args.outputPath, result);
    }

    result.dispose();
  } finally {
    img.dispose();
  }
}

/// Standalone (top-level) version of the line drawing algorithm for use
/// inside an isolate. Mirrors [ConversionService._frameToLineDrawing] but
/// does not depend on the service instance or AppConfig singletons.
cv.Mat _frameToLineDrawingSync(
  cv.Mat frame, {
  required int blurKernel,
  required int thresholdBlock,
  required int contrastLow,
}) {
  // Step 1: Convert to grayscale
  final gray = cv.cvtColor(frame, cv.COLOR_BGR2GRAY);

  // Step 2: Pencil sketch via divide
  final white = cv.Mat.ones(gray.rows, gray.cols, cv.MatType.CV_8UC1)
      .multiplyU8(255);
  final inv = cv.subtract(white, gray);
  final blur = cv.gaussianBlur(inv, (blurKernel, blurKernel), 0);
  final invBlur = cv.subtract(white, blur);
  // Clamp against divide-by-zero on saturated frames via element-wise max.
  final onesMat = cv.Mat.ones(invBlur.rows, invBlur.cols, cv.MatType.CV_8UC1);
  final invBlurSafe = cv.max(invBlur, onesMat);
  final sketch = cv.divide(gray, invBlurSafe, scale: 256.0);

  // Step 3: Adaptive threshold
  final blurredGray = cv.gaussianBlur(gray, (5, 5), 0);
  final adaptive = cv.adaptiveThreshold(
    blurredGray,
    255,
    cv.ADAPTIVE_THRESH_GAUSSIAN_C,
    cv.THRESH_BINARY,
    thresholdBlock,
    2,
  );

  // Step 4: Combine
  final combined = cv.min(sketch, adaptive);

  // Step 5: Contrast boost
  final scale = 255.0 / (255 - contrastLow).clamp(1, 255);
  final beta = -contrastLow.toDouble() * scale;
  final boosted = combined.convertTo(cv.MatType.CV_8UC1,
      alpha: scale, beta: beta);

  // Step 6: Convert to BGR for output
  final result = cv.cvtColor(boosted, cv.COLOR_GRAY2BGR);

  gray.dispose();
  white.dispose();
  inv.dispose();
  blur.dispose();
  invBlur.dispose();
  onesMat.dispose();
  invBlurSafe.dispose();
  sketch.dispose();
  blurredGray.dispose();
  adaptive.dispose();
  combined.dispose();
  boosted.dispose();

  return result;
}

// =============================================================================
// Photo three-treatment thumbnail variants (Bundle 2b — audit PR 6)
// =============================================================================

/// Arguments crossing into the photo thumbnail-variant isolate.
///
/// Plain-data only — all file paths are absolute. The isolate has no
/// access to the parent's storage / path-resolver state, so `bwOutPath`,
/// `colorOutPath`, `lineOutPath`, `thumbBwOutPath` MUST be resolved
/// upstream (e.g. via `path_provider` + `path.join`) before the [compute]
/// call.
class _PhotoThumbArgs {
  final String rawPath;
  final String? convertedPath;
  final String bwOutPath;
  final String colorOutPath;
  final String lineOutPath;
  final String thumbBwOutPath;

  const _PhotoThumbArgs({
    required this.rawPath,
    required this.convertedPath,
    required this.bwOutPath,
    required this.colorOutPath,
    required this.lineOutPath,
    required this.thumbBwOutPath,
  });
}

/// Top-level isolate entry that produces the four treatment thumbnail
/// variants for a captured photo, symmetric to the video pipeline's
/// `extractFrame` trio:
///
///   * `{id}_thumb.jpg`        — B&W (greyscale) from the raw photo. The
///                                canonical practitioner-facing thumb.
///   * `{id}_thumb_color.jpg`  — raw colour copy (downscale at parity
///                                with the video pipeline; same source,
///                                JPEG quality 95).
///   * `{id}_thumb_line.jpg`   — line-drawing copy of the converted JPG.
///   * `{id}_thumb_bw.jpg`     — bytes-baked B&W with contrast 1.05
///                                applied, visually matching the CSS
///                                `filter: grayscale(1) contrast(1.05)`
///                                that the lobby previously composited
///                                at render time. Used by surfaces that
///                                cannot apply CSS filters (PDF export,
///                                html2canvas snapshot) — so the same
///                                B&W look survives a snapshot
///                                round-trip without depending on
///                                downstream filter support.
///
/// Photos don't need motion-peak / person-crop (the raw IS the Hero
/// frame; per `mini_preview.dart:351-353`). They DO benefit from a
/// modest downscale so the on-disk variant sizes track the video
/// pipeline rather than serving full-resolution images to small
/// surfaces like the filmstrip / Studio card.
///
/// The downscale target matches the video pipeline's
/// `extractFrame`-extracted JPEG (≈720px on the long edge). The line
/// variant copies the converted JPG verbatim (already at converted
/// resolution; line drawings are visually OK at smaller sizes too, so
/// we apply the same downscale).
///
/// Failure inside this isolate throws back to the caller, which logs
/// and falls back to the legacy `thumbnailPath = rawFilePath` stamp.
void _extractPhotoThumbnailVariants(_PhotoThumbArgs args) {
  // Long-edge target — matches the video pipeline's extractFrame default
  // (the native side resizes to ≤ 720 on the long edge). Keeping parity
  // means the filmstrip / Studio cards consume similarly-sized assets
  // across both media types.
  const int targetLongEdge = 720;

  cv.Mat? rawColor;
  try {
    rawColor = cv.imread(args.rawPath, flags: cv.IMREAD_COLOR);
    if (rawColor.isEmpty) {
      throw Exception('Could not read raw photo: ${args.rawPath}');
    }

    final resizedColor = _resizeForThumbnail(rawColor, targetLongEdge);

    // _thumb_color.jpg — raw colour, JPEG quality 95.
    cv.imwrite(args.colorOutPath, resizedColor,
        params: cv.VecI32.fromList([cv.IMWRITE_JPEG_QUALITY, 95]));

    // _thumb.jpg — B&W greyscale via single-channel cvtColor (NOT
    // CSS-filter-style 0.299/0.587/0.114 luminance weighting via a 3x3
    // matrix — OpenCV's BGR2GRAY uses ITU-R BT.601 weights which is
    // visually equivalent and avoids the extra matrix-multiply pass).
    final gray = cv.cvtColor(resizedColor, cv.COLOR_BGR2GRAY);
    cv.imwrite(args.bwOutPath, gray,
        params: cv.VecI32.fromList([cv.IMWRITE_JPEG_QUALITY, 95]));

    // _thumb_bw.jpg — same greyscale but with contrast 1.05 applied to
    // match the CSS `filter: grayscale(1) contrast(1.05)` baseline the
    // web-player lobby otherwise composites at render time. CSS contrast
    // is defined (per spec) as `new = (old - 0.5) * c + 0.5` on
    // normalised 0..1 channels. In 0..255 byte space that becomes
    // `new = c*old + (1 - c)*127.5`, i.e. `convertScaleAbs(alpha=c,
    // beta=(1-c)*127.5)`. For c = 1.05 → alpha = 1.05, beta = -6.375.
    // Surfaces that can't apply CSS filters (PDF export, html2canvas
    // snapshot) consume this file directly so the B&W treatment looks
    // the same across every render path. Lives as a SIBLING of
    // `_thumb.jpg` — `_thumb.jpg` is preserved as the canonical
    // practitioner-facing thumb so existing surfaces keep their
    // current bytes; `_thumb_bw.jpg` is purely a presentation artifact
    // for the web player + scheme bridge.
    final thumbBw = cv.convertScaleAbs(gray, alpha: 1.05, beta: -6.375);
    cv.imwrite(args.thumbBwOutPath, thumbBw,
        params: cv.VecI32.fromList([cv.IMWRITE_JPEG_QUALITY, 92]));
    thumbBw.dispose();
    gray.dispose();

    resizedColor.dispose();

    // _thumb_line.jpg — copy of the converted line-drawing JPG. The
    // photo branch of [_convert] already produces this JPG at full
    // resolution; we resize it to match the thumbnail-tier sizing for
    // consistency. Skipped silently if the converted JPG is missing
    // (legacy / pre-PR rows might lack it, though current photo flow
    // always emits one).
    final convertedPath = args.convertedPath;
    if (convertedPath != null && File(convertedPath).existsSync()) {
      final lineSource = cv.imread(convertedPath, flags: cv.IMREAD_COLOR);
      if (!lineSource.isEmpty) {
        final resizedLine = _resizeForThumbnail(lineSource, targetLongEdge);
        cv.imwrite(args.lineOutPath, resizedLine,
            params: cv.VecI32.fromList([cv.IMWRITE_JPEG_QUALITY, 95]));
        resizedLine.dispose();
      }
      lineSource.dispose();
    }
  } finally {
    rawColor?.dispose();
  }
}

/// Resize [src] to a thumbnail-tier size while preserving aspect ratio.
///
/// Returns a NEW Mat — caller is responsible for `.dispose()` on the
/// returned value. The input [src] is left untouched (caller still owns
/// it).
///
/// When the source is already at or below [targetLongEdge] on the long
/// edge, returns a clone (so disposal semantics stay consistent — no
/// special-case branch in the caller).
cv.Mat _resizeForThumbnail(cv.Mat src, int targetLongEdge) {
  final w = src.cols;
  final h = src.rows;
  if (w <= 0 || h <= 0) return src.clone();

  final longEdge = w > h ? w : h;
  if (longEdge <= targetLongEdge) {
    return src.clone();
  }
  final scale = targetLongEdge / longEdge;
  final newW = (w * scale).round();
  final newH = (h * scale).round();

  // INTER_AREA = best for shrinking (per OpenCV docs).
  return cv.resize(src, (newW, newH), interpolation: cv.INTER_AREA);
}
