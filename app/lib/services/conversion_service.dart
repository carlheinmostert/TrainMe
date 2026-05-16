import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/painting.dart' show decodeImageFromList;
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart' as vt;
import '../config.dart';
import '../models/exercise_capture.dart';
import 'local_storage_service.dart';
import 'loud_swallow.dart';
import 'path_resolver.dart';

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
  Future<void> restoreQueue() async {
    final unconverted = await _storage.getUnconvertedExercises();
    for (final exercise in unconverted) {
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

            final rawAbs = exercise.absoluteRawFilePath;
            final convertedAbs = done.absoluteConvertedFilePath;

            await compute(_extractPhotoThumbnailVariants, _PhotoThumbArgs(
              rawPath: rawAbs,
              convertedPath: convertedAbs,
              bwOutPath: bwPath,
              colorOutPath: colorPath,
              lineOutPath: linePath,
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
      try {
        final segResult = await _convertVideo(
          exercise.absoluteRawFilePath,
          videoOutputPath,
          segmentedOutputPath: segmentedOutputPath,
          maskOutputPath: maskOutputPath,
          includeAudio: AppConfig.audioMuxEnabled,
        );
        return _ConvertResult(
          convertedPath: videoOutputPath,
          segmentedPath: segResult.segmentedPath,
          maskPath: segResult.maskPath,
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
      final convertedPath =
          p.join(convertedDir, '${exercise.id}_line$ext');
      await _convertPhoto(exercise.absoluteRawFilePath, convertedPath);

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
      String? segmentedPhotoPath;
      try {
        final candidate =
            p.join(convertedDir, '${exercise.id}.segmented.jpg');
        await _convertPhotoBodyFocus(
          exercise.absoluteRawFilePath,
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
        debugPrint(
            'Native video conversion complete: '
            '${result["framesProcessed"]} frames '
            '(audioSamplesWritten=${result["audioSamplesWritten"]}, '
            'audioMuxEnabled=${AppConfig.audioMuxEnabled}, '
            'segFrames=${result["segFramesProcessed"] ?? 0}, '
            'maskFrames=${result["maskFramesProcessed"] ?? 0}) -> $outputPath');
        return _NativeVideoResult(
          segmentedPath: segPath,
          maskPath: maskPath,
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

      final bwMissing = !await File(bwPath).exists();
      final colorMissing = !await File(colorPath).exists();
      final lineMissing = !await File(linePath).exists();

      if (!bwMissing && !colorMissing && !lineMissing) {
        continue;
      }

      if (exercise.mediaType == MediaType.photo) {
        // Photos: variants are produced atomically by the OpenCV
        // isolate in _extractPhotoThumbnailVariants. Re-run the whole
        // pass if ANY of the three is missing — the isolate is
        // idempotent + handles missing converted JPG gracefully.
        await _logBackfillEvent(
          exerciseId: exercise.id,
          event: 'start',
          variant: 'photo_all',
          detail: 'bwMissing=$bwMissing colorMissing=$colorMissing lineMissing=$lineMissing',
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
          ));
          // Re-stamp thumbnailPath if it isn't pointing at the bw
          // variant already (legacy rows may still have
          // thumbnailPath = rawFilePath).
          if (await File(bwPath).exists()) {
            final next = exercise.copyWith(
              thumbnailPath: PathResolver.toRelative(bwPath),
            );
            await _storage.saveExercise(next);
            if (!_updateController.isClosed) {
              _updateController.add(next);
            }
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

  const _ConvertResult({
    required this.convertedPath,
    this.segmentedPath,
    this.maskPath,
  });
}

/// Result of the native-side `convertVideo` platform channel call.
/// Plain value object — carries the two optional sidecar paths the
/// caller needs to thread back onto [ExerciseCapture].
class _NativeVideoResult {
  final String? segmentedPath;
  final String? maskPath;

  const _NativeVideoResult({
    this.segmentedPath,
    this.maskPath,
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
/// `colorOutPath`, `lineOutPath` MUST be resolved upstream (e.g. via
/// `path_provider` + `path.join`) before the [compute] call.
class _PhotoThumbArgs {
  final String rawPath;
  final String? convertedPath;
  final String bwOutPath;
  final String colorOutPath;
  final String lineOutPath;

  const _PhotoThumbArgs({
    required this.rawPath,
    required this.convertedPath,
    required this.bwOutPath,
    required this.colorOutPath,
    required this.lineOutPath,
  });
}

/// Top-level isolate entry that produces the three treatment thumbnail
/// variants for a captured photo, symmetric to the video pipeline's
/// `extractFrame` trio:
///
///   * `{id}_thumb.jpg`        — B&W (greyscale) from the raw photo. The
///                                canonical practitioner-facing thumb.
///   * `{id}_thumb_color.jpg`  — raw colour copy (downscale at parity
///                                with the video pipeline; same source,
///                                JPEG quality 95).
///   * `{id}_thumb_line.jpg`   — line-drawing copy of the converted JPG.
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
