import 'package:uuid/uuid.dart';
import '../config.dart';
import '../services/path_resolver.dart';
import 'treatment.dart';

/// The type of media captured for an exercise.
///
/// [rest] represents a rest period — no media, no conversion needed.
enum MediaType { photo, video, rest }

/// Tracks the line drawing conversion state of a capture.
enum ConversionStatus { pending, converting, done, failed }

/// A single captured exercise — one photo or video from the session.
///
/// Immutable value object. Create a new instance via [copyWith] when updating
/// fields like [conversionStatus] or [convertedFilePath].
class ExerciseCapture {
  final String id;
  final int position;
  final String rawFilePath;
  final String? convertedFilePath;
  final String? thumbnailPath;
  final MediaType mediaType;
  final ConversionStatus conversionStatus;
  final int? reps;
  final int? sets;
  final int? holdSeconds;
  final String? notes;
  final String? name;
  final DateTime createdAt;

  /// The session this capture belongs to. Set when persisting.
  final String? sessionId;

  /// If set, this exercise belongs to a circuit group. All exercises with the
  /// same circuitId are in the same circuit and repeat together as a cycle.
  final String? circuitId;

  /// Whether audio should be included when sending this exercise to the client.
  /// Audio is always captured and preserved in the converted video; this flag
  /// only controls whether it is included at send time. Default is false (muted)
  /// for safety — trainers must explicitly opt in per exercise.
  final bool includeAudio;

  /// Manual duration override in seconds. When set, [effectiveDurationSeconds]
  /// returns this value instead of the calculated [estimatedDurationSeconds].
  /// Nullable — null means "use the auto-calculated value".
  final int? customDurationSeconds;

  /// Per-exercise prep-countdown override in seconds.
  ///
  /// When set, the plan-preview + web player use this value for the
  /// pre-exercise prep phase. When null, the global default (5s) applies.
  /// Legacy rows pre-migration are null; the new 5s default supersedes the
  /// previous hard-coded 15s baseline. Rest periods ignore this field.
  final int? prepSeconds;

  /// Per-exercise inter-set rest ("Post Rep Breather") in seconds
  /// (Milestone Q). Semantics:
  ///
  ///   * null → no breather (legacy rows, pre-migration).
  ///   * 0    → practitioner explicitly disabled the breather.
  ///   * > 0  → breather seconds played between sets on the client
  ///            web player.
  ///
  /// Fresh captures seed to 15 via [withPersistenceDefaults]; existing
  /// rows stay null (no backfill). Feeds the duration math used by the
  /// progress-pill matrix + the workout-timeline ETA:
  ///
  ///   exercise_total = sets × per_set
  ///                  + max(0, sets - 1) × (interSetRestSeconds ?? 0)
  ///
  /// Rest periods + isometric-only exercises skip the default seed —
  /// the former have no sets, the latter run the hold as the primary
  /// dose. The player hides the segmented progress bar when sets <= 1
  /// (breather has no meaning with a single set).
  final int? interSetRestSeconds;

  /// Duration of the raw video file in milliseconds. Populated by the
  /// conversion service after a successful video conversion using the native
  /// AVURLAsset probe. For video exercises, this is used as "one rep" in the
  /// auto-calculated duration estimate (the video IS the demonstration of one
  /// iteration). Null for photos, rest periods, and legacy rows pre-migration.
  final int? videoDurationMs;

  /// Relative path (via [PathResolver]) to the compressed 720p H.264 archive
  /// copy of the raw video. Populated fire-and-forget after a successful video
  /// conversion so we can re-run better line-drawing filters later against a
  /// compact copy of the original footage. Null for photos, rest periods, and
  /// exercises where the archive step hasn't run yet (or failed non-fatally).
  final String? archiveFilePath;

  /// When the [archiveFilePath] was written. Used by the 90-day retention
  /// purge on app startup. Null when [archiveFilePath] is null.
  final DateTime? archivedAt;

  /// When the raw archive was successfully uploaded to the private
  /// `raw-archive` Supabase bucket at `{practice_id}/{plan_id}/{exercise_id}.mp4`.
  /// Set on a best-effort basis during publish — raw-archive upload failures
  /// never fail the publish. Null means "not yet uploaded" (or upload failed
  /// on the last attempt); the next publish retries the upload.
  final DateTime? rawArchiveUploadedAt;

  /// Relative path (via [PathResolver]) to the dual-output segmented-color
  /// variant of the raw capture — same Vision body mask as the line drawing
  /// is reused to pop the body through pristine while dimming the background.
  ///
  /// Videos: `.segmented.mp4` produced by the AVFoundation third-output
  /// pass during conversion; uploaded to the private `raw-archive` bucket
  /// at `{practice_id}/{plan_id}/{exercise_id}.segmented.mp4`. Consumed by
  /// the web player's Color + B&W treatments to deliver the body-pop
  /// effect.
  ///
  /// Photos (Wave 36): `.segmented.jpg` produced on-device by the same
  /// `ClientAvatarProcessor` pipeline (Vision person-segmentation +
  /// vImage Gaussian blur composite) the avatar surface uses. Uploaded
  /// to `raw-archive` at `{practice_id}/{plan_id}/{exercise_id}.segmented.jpg`.
  /// Same treatment URLs (`grayscale_segmented_url` / `original_segmented_url`)
  /// flow through `get_plan_full` for both photos and videos.
  ///
  /// Null for rest periods and legacy rows pre-migration (v22 for videos,
  /// W36 for photos). Best-effort — missing segmented files fall through
  /// to the untouched original on both mobile + web.
  final String? segmentedRawFilePath;

  /// Relative path (via [PathResolver]) to the Vision person-segmentation
  /// mask sidecar — a grayscale H.264 mp4 where each pixel's luminance
  /// carries the per-frame segmentation weight that drove both the line
  /// drawing + segmented-colour composites. Insurance for future playback-
  /// time compositing: storing it today means already-published plans will
  /// have the data available when tunable backgroundDim / other effects
  /// land, without needing to re-capture.
  ///
  /// Uploaded best-effort to the private `raw-archive` Supabase bucket at
  /// `{practice_id}/{plan_id}/{exercise_id}.mask.mp4`. Null for photos,
  /// rest periods, and legacy rows pre-migration (v23), or when the mask
  /// writer failed non-fatally (line-drawing + segmented still succeed).
  /// No consumer today — `get_plan_full` emits a `mask_url` that the web
  /// player passes through unused.
  final String? maskFilePath;

  /// Remote line drawing URL (returned by `get_plan_full`). Runtime-only;
  /// not persisted to SQLite. Used by the practitioner's preview screen to
  /// display the published treatment without re-reading the local
  /// converted file. Null when the plan was never published (preview uses
  /// the local file instead).
  final String? lineDrawingUrl;

  /// Remote URL for the grayscale (saturation-zero) treatment. Actually
  /// points to the original colour file — grayscale is applied at playback
  /// via a ColorFilter matrix. Null when the client hasn't said yes to
  /// grayscale viewing, which disables the B&W segment in the preview.
  final String? grayscaleUrl;

  /// Remote URL for the unmodified colour treatment. Null when the client
  /// hasn't said yes to colour viewing, which disables the Original
  /// segment in the preview.
  final String? originalUrl;

  /// The practitioner's sticky treatment preference for this specific
  /// exercise.
  ///
  /// Semantics:
  ///   * `null` → no explicit choice, render as [Treatment.line] (the
  ///     de-identifying default). This is the value for every exercise
  ///     at capture time and after a fresh install.
  ///   * non-null → the practitioner cycled the treatment on this
  ///     exercise (via the Studio `_MediaViewer` vertical swipe, a
  ///     plan-preview segment tap, or a Studio-card tile tap) and wants
  ///     that choice to stick. Next time the plan opens, the preview /
  ///     viewer starts on this treatment.
  ///
  /// Per-exercise: moving to the NEXT exercise in the deck doesn't
  /// carry this forward — each exercise renders in ITS OWN saved
  /// preference. An exercise with `null` continues to show Line even
  /// if the practitioner just flipped the previous exercise to B&W.
  ///
  /// Persistence: local SQLite `exercises.preferred_treatment` +
  /// Supabase `exercises.preferred_treatment` (both nullable TEXT).
  /// Round-trips unchanged through publish + sync via the wire
  /// encoding on [TreatmentX.wireValue] / [treatmentFromWire].
  final Treatment? preferredTreatment;

  /// Soft-trim in-point in milliseconds (Wave 20 / Milestone X).
  ///
  /// When set together with [endOffsetMs], the mobile preview AND the
  /// web player clamp playback to `[startOffsetMs, endOffsetMs]` and
  /// loop within that window. NO re-conversion: the underlying media
  /// file stays full-length; trim is purely a playback metadata pair.
  ///
  /// The same trim applies across all three treatments (Line / B&W /
  /// Original) since they share source timing. Switching treatment via
  /// the vertical pill must NOT reset the trim.
  ///
  /// `null` (or [endOffsetMs] null) means "no trim, play the full
  /// clip" — preserves legacy behaviour for every pre-Wave-20 row.
  /// Application code enforces start < end and a 0.3s minimum window;
  /// the DB only guards against negatives via CHECK.
  ///
  /// Persistence: local SQLite `exercises.start_offset_ms` (schema v25)
  /// + Supabase `exercises.start_offset_ms` (Milestone X).
  final int? startOffsetMs;

  /// Soft-trim out-point in milliseconds (Wave 20 / Milestone X).
  /// See [startOffsetMs] for the full semantics.
  final int? endOffsetMs;

  /// Number of repetitions captured in the source video (Wave 24).
  ///
  /// Semantics:
  ///   * `null` → legacy / pre-migration row. Mobile preview + web
  ///     player both treat as 1 rep per loop (preserves pre-Wave-24
  ///     playback math; older plans never wrote this column).
  ///   * `> 0` → practitioner-set or persistence-default count of reps
  ///     captured in the video. Fresh captures seed to 3 via
  ///     [withPersistenceDefaults].
  ///
  /// Per-rep + per-set time derive from this value:
  ///
  ///   per_rep_seconds = (videoDurationMs / 1000) / videoRepsPerLoop
  ///   per_set_seconds = (reps ?? 10) × per_rep_seconds
  ///
  /// Wave 24 retired the manual [customDurationSeconds] override from
  /// the UI; the DB column stays for backwards-compatible reads of
  /// older plans. Photos + rest periods don't carry this field — they
  /// have no video to count reps in.
  ///
  /// Persistence: local SQLite `exercises.video_reps_per_loop`
  /// (schema v26) + Supabase `exercises.video_reps_per_loop`
  /// (schema_wave24_video_reps_per_loop.sql).
  final int? videoRepsPerLoop;

  /// Effective playback aspect ratio (width / height) after any
  /// practitioner rotation (Wave 28).
  ///
  /// Captured at conversion time from the source media's natural
  /// dimensions. When [rotationQuarters] flips the orientation by 90°,
  /// callers MUST update this to the rotated value in the same write
  /// (single source of truth — consumers never re-derive from natural
  /// dimensions + rotation).
  ///
  /// `null` → consumer derives from media at first paint (legacy /
  /// pre-migration row, or a capture where the probe failed
  /// non-fatally).
  ///
  /// Persistence: local SQLite `exercises.aspect_ratio` (schema v28) +
  /// Supabase `exercises.aspect_ratio` (schema_wave28_landscape_metadata).
  final double? aspectRatio;

  /// Practitioner playback rotation in 90° clockwise quarters
  /// (Wave 28).
  ///
  /// Values: 0 / 1 / 2 / 3. `null` is treated as 0 by both surfaces.
  /// Applied as a CSS transform / Flutter `Transform.rotate` at render
  /// time — NO source re-encoding. The web + native players each apply
  /// the same rotation.
  ///
  /// Persistence: local SQLite `exercises.rotation_quarters` (schema
  /// v28) + Supabase `exercises.rotation_quarters`
  /// (schema_wave28_landscape_metadata).
  final int? rotationQuarters;

  const ExerciseCapture({
    required this.id,
    required this.position,
    required this.rawFilePath,
    this.convertedFilePath,
    this.thumbnailPath,
    required this.mediaType,
    this.conversionStatus = ConversionStatus.pending,
    this.reps,
    this.sets,
    this.holdSeconds,
    this.notes,
    this.name,
    required this.createdAt,
    this.sessionId,
    this.circuitId,
    this.includeAudio = false,
    this.customDurationSeconds,
    this.prepSeconds,
    this.interSetRestSeconds,
    this.videoDurationMs,
    this.archiveFilePath,
    this.archivedAt,
    this.rawArchiveUploadedAt,
    this.segmentedRawFilePath,
    this.maskFilePath,
    this.lineDrawingUrl,
    this.grayscaleUrl,
    this.originalUrl,
    this.preferredTreatment,
    this.startOffsetMs,
    this.endOffsetMs,
    this.videoRepsPerLoop,
    this.aspectRatio,
    this.rotationQuarters,
  });

  /// Create a new capture with a generated UUID.
  factory ExerciseCapture.create({
    required int position,
    required String rawFilePath,
    required MediaType mediaType,
    String? sessionId,
  }) {
    return ExerciseCapture(
      id: const Uuid().v4(),
      position: position,
      rawFilePath: rawFilePath,
      mediaType: mediaType,
      createdAt: DateTime.now(),
      sessionId: sessionId,
    );
  }

  /// Create a rest period exercise — no media, no conversion.
  factory ExerciseCapture.createRest({
    required int position,
    String? sessionId,
    int? durationSeconds,
  }) {
    return ExerciseCapture(
      id: const Uuid().v4(),
      position: position,
      rawFilePath: '',
      mediaType: MediaType.rest,
      conversionStatus: ConversionStatus.done,
      holdSeconds: durationSeconds ?? AppConfig.defaultRestDuration,
      name: 'Rest',
      createdAt: DateTime.now(),
      sessionId: sessionId,
    );
  }

  /// Whether this exercise is a rest period.
  bool get isRest => mediaType == MediaType.rest;

  /// Deserialize from a SQLite row.
  factory ExerciseCapture.fromMap(Map<String, dynamic> map) {
    return ExerciseCapture(
      id: map['id'] as String,
      position: map['position'] as int,
      rawFilePath: map['raw_file_path'] as String,
      convertedFilePath: map['converted_file_path'] as String?,
      thumbnailPath: map['thumbnail_path'] as String?,
      mediaType: MediaType.values[map['media_type'] as int],
      conversionStatus:
          ConversionStatus.values[map['conversion_status'] as int],
      reps: map['reps'] as int?,
      sets: map['sets'] as int?,
      holdSeconds: map['hold_seconds'] as int?,
      notes: map['notes'] as String?,
      name: map['name'] as String?,
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
      sessionId: map['session_id'] as String?,
      circuitId: map['circuit_id'] as String?,
      includeAudio: (map['include_audio'] as int?) == 1,
      customDurationSeconds: map['custom_duration'] as int?,
      prepSeconds: map['prep_seconds'] as int?,
      interSetRestSeconds: map['inter_set_rest_seconds'] as int?,
      videoDurationMs: map['video_duration_ms'] as int?,
      archiveFilePath: map['archive_file_path'] as String?,
      archivedAt: map['archived_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['archived_at'] as int)
          : null,
      rawArchiveUploadedAt: map['raw_archive_uploaded_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(
              map['raw_archive_uploaded_at'] as int)
          : null,
      segmentedRawFilePath: map['segmented_raw_file_path'] as String?,
      maskFilePath: map['mask_file_path'] as String?,
      preferredTreatment: treatmentFromWire(map['preferred_treatment']),
      startOffsetMs: map['start_offset_ms'] as int?,
      endOffsetMs: map['end_offset_ms'] as int?,
      videoRepsPerLoop: map['video_reps_per_loop'] as int?,
      aspectRatio: (map['aspect_ratio'] as num?)?.toDouble(),
      rotationQuarters: map['rotation_quarters'] as int?,
    );
  }

  /// Serialize to a map suitable for SQLite insertion.
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'session_id': sessionId,
      'position': position,
      'raw_file_path': rawFilePath,
      'converted_file_path': convertedFilePath,
      'thumbnail_path': thumbnailPath,
      'media_type': mediaType.index,
      'conversion_status': conversionStatus.index,
      'reps': reps,
      'sets': sets,
      'hold_seconds': holdSeconds,
      'notes': notes,
      'name': name,
      'created_at': createdAt.millisecondsSinceEpoch,
      'circuit_id': circuitId,
      'include_audio': includeAudio ? 1 : 0,
      'custom_duration': customDurationSeconds,
      'prep_seconds': prepSeconds,
      'inter_set_rest_seconds': interSetRestSeconds,
      'video_duration_ms': videoDurationMs,
      'archive_file_path': archiveFilePath,
      'archived_at': archivedAt?.millisecondsSinceEpoch,
      'raw_archive_uploaded_at': rawArchiveUploadedAt?.millisecondsSinceEpoch,
      'segmented_raw_file_path': segmentedRawFilePath,
      'mask_file_path': maskFilePath,
      'preferred_treatment': preferredTreatment?.wireValue,
      'start_offset_ms': startOffsetMs,
      'end_offset_ms': endOffsetMs,
      'video_reps_per_loop': videoRepsPerLoop,
      'aspect_ratio': aspectRatio,
      'rotation_quarters': rotationQuarters,
    };
  }

  /// Create a modified copy. Use this instead of mutating fields.
  ///
  /// For [circuitId], pass the special [clearCircuitId] sentinel to explicitly
  /// set it to null (removing the exercise from a circuit). Passing null (the
  /// default) keeps the current value.
  ExerciseCapture copyWith({
    int? position,
    String? rawFilePath,
    String? convertedFilePath,
    String? thumbnailPath,
    MediaType? mediaType,
    ConversionStatus? conversionStatus,
    int? reps,
    int? sets,
    int? holdSeconds,
    String? notes,
    String? name,
    bool clearName = false,
    String? sessionId,
    String? circuitId,
    bool clearCircuitId = false,
    bool? includeAudio,
    int? customDurationSeconds,
    bool clearCustomDuration = false,
    int? prepSeconds,
    bool clearPrepSeconds = false,
    int? interSetRestSeconds,
    bool clearInterSetRestSeconds = false,
    int? videoDurationMs,
    bool clearVideoDurationMs = false,
    String? archiveFilePath,
    bool clearArchiveFilePath = false,
    DateTime? archivedAt,
    bool clearArchivedAt = false,
    DateTime? rawArchiveUploadedAt,
    bool clearRawArchiveUploadedAt = false,
    String? segmentedRawFilePath,
    bool clearSegmentedRawFilePath = false,
    String? maskFilePath,
    bool clearMaskFilePath = false,
    String? lineDrawingUrl,
    bool clearLineDrawingUrl = false,
    String? grayscaleUrl,
    bool clearGrayscaleUrl = false,
    String? originalUrl,
    bool clearOriginalUrl = false,
    Treatment? preferredTreatment,
    bool clearPreferredTreatment = false,
    int? startOffsetMs,
    bool clearStartOffsetMs = false,
    int? endOffsetMs,
    bool clearEndOffsetMs = false,
    int? videoRepsPerLoop,
    bool clearVideoRepsPerLoop = false,
    double? aspectRatio,
    bool clearAspectRatio = false,
    int? rotationQuarters,
    bool clearRotationQuarters = false,
  }) {
    return ExerciseCapture(
      id: id,
      position: position ?? this.position,
      rawFilePath: rawFilePath ?? this.rawFilePath,
      convertedFilePath: convertedFilePath ?? this.convertedFilePath,
      thumbnailPath: thumbnailPath ?? this.thumbnailPath,
      mediaType: mediaType ?? this.mediaType,
      conversionStatus: conversionStatus ?? this.conversionStatus,
      reps: reps ?? this.reps,
      sets: sets ?? this.sets,
      holdSeconds: holdSeconds ?? this.holdSeconds,
      notes: notes ?? this.notes,
      name: clearName ? null : (name ?? this.name),
      createdAt: createdAt,
      sessionId: sessionId ?? this.sessionId,
      circuitId: clearCircuitId ? null : (circuitId ?? this.circuitId),
      includeAudio: includeAudio ?? this.includeAudio,
      customDurationSeconds: clearCustomDuration
          ? null
          : (customDurationSeconds ?? this.customDurationSeconds),
      prepSeconds:
          clearPrepSeconds ? null : (prepSeconds ?? this.prepSeconds),
      interSetRestSeconds: clearInterSetRestSeconds
          ? null
          : (interSetRestSeconds ?? this.interSetRestSeconds),
      videoDurationMs: clearVideoDurationMs
          ? null
          : (videoDurationMs ?? this.videoDurationMs),
      archiveFilePath: clearArchiveFilePath
          ? null
          : (archiveFilePath ?? this.archiveFilePath),
      archivedAt: clearArchivedAt ? null : (archivedAt ?? this.archivedAt),
      rawArchiveUploadedAt: clearRawArchiveUploadedAt
          ? null
          : (rawArchiveUploadedAt ?? this.rawArchiveUploadedAt),
      segmentedRawFilePath: clearSegmentedRawFilePath
          ? null
          : (segmentedRawFilePath ?? this.segmentedRawFilePath),
      maskFilePath: clearMaskFilePath
          ? null
          : (maskFilePath ?? this.maskFilePath),
      lineDrawingUrl:
          clearLineDrawingUrl ? null : (lineDrawingUrl ?? this.lineDrawingUrl),
      grayscaleUrl:
          clearGrayscaleUrl ? null : (grayscaleUrl ?? this.grayscaleUrl),
      originalUrl: clearOriginalUrl ? null : (originalUrl ?? this.originalUrl),
      preferredTreatment: clearPreferredTreatment
          ? null
          : (preferredTreatment ?? this.preferredTreatment),
      startOffsetMs: clearStartOffsetMs
          ? null
          : (startOffsetMs ?? this.startOffsetMs),
      endOffsetMs:
          clearEndOffsetMs ? null : (endOffsetMs ?? this.endOffsetMs),
      videoRepsPerLoop: clearVideoRepsPerLoop
          ? null
          : (videoRepsPerLoop ?? this.videoRepsPerLoop),
      aspectRatio:
          clearAspectRatio ? null : (aspectRatio ?? this.aspectRatio),
      rotationQuarters: clearRotationQuarters
          ? null
          : (rotationQuarters ?? this.rotationQuarters),
    );
  }

  /// Backfill the per-capture persistence defaults (Option 1 from the
  /// 2026-04-22 player-grammar discussion).
  ///
  /// Problem: when a practitioner captures an exercise and never touches
  /// reps / sets, those columns persist as NULL. Downstream consumers
  /// (web player, plan preview) then have to guess defaults at display
  /// time, which produced inconsistent grammar across exercises captured
  /// in the same session — one card showed "5 reps", the next showed
  /// nothing, because the display-time fallback differed per surface.
  ///
  /// Fix: at the persistence boundary, backfill missing reps / sets with
  /// the same canonical defaults the Studio card would have drawn
  /// (3 sets x 10 reps). Truthful data, no display-time imputation.
  ///
  /// Milestone Q extension (2026-04-23): also stamp
  /// `interSetRestSeconds = 15` on fresh captures so the new "Post Rep
  /// Breather" feature has a meaningful default on day one. Same
  /// exceptions apply — rest periods and isometric-only captures skip
  /// the seed. Existing rows with a non-null value are never
  /// overwritten, matching the null-fill discipline below.
  ///
  /// Wave 24 extension (2026-04-24): stamp `videoRepsPerLoop = 3` on
  /// fresh VIDEO captures (and isometric / hold captures, per Carl's
  /// "how many hold cycles is in this video?" framing). Photos + rest
  /// periods skip the seed — they have no video to count reps in.
  /// Existing rows stay null (no backfill); the player's null-fallback
  /// branch treats null as 1 rep / loop and preserves pre-Wave-24
  /// playback math.
  ///
  /// Exceptions:
  ///   * Rest periods (`mediaType == rest`) have no reps / sets
  ///     semantics — returned unchanged.
  ///   * Isometric exercises (`holdSeconds` set AND `reps` still null)
  ///     skip the reps default. Hold is the primary duration; reps
  ///     isn't semantically meaningful. Sets default still applies.
  ///     Inter-set rest is also skipped — an isometric capture typically
  ///     runs as a single hold, not a reps-per-set block.
  ///
  /// Fields already set are never overwritten — the helper only fills
  /// nulls.
  ExerciseCapture withPersistenceDefaults() {
    if (isRest) return this;
    final isIsometric = holdSeconds != null && reps == null;
    final nextReps = reps ?? (isIsometric ? null : 10);
    final nextSets = sets ?? 3;
    final nextInterSetRest = interSetRestSeconds ??
        (isIsometric ? null : 15);
    // Wave 24 — fresh video / hold captures default to 3 reps in the
    // source clip. Photos + legacy non-video rows stay null and the
    // player treats null as 1 rep per loop.
    final nextVideoRepsPerLoop = videoRepsPerLoop ??
        (mediaType == MediaType.video ? 3 : null);
    if (nextReps == reps &&
        nextSets == sets &&
        nextInterSetRest == interSetRestSeconds &&
        nextVideoRepsPerLoop == videoRepsPerLoop) {
      return this;
    }
    return copyWith(
      reps: nextReps,
      sets: nextSets,
      interSetRestSeconds: nextInterSetRest,
      videoRepsPerLoop: nextVideoRepsPerLoop,
    );
  }

  /// Estimated duration in seconds for this exercise (all sets).
  /// Rest periods simply return their holdSeconds.
  ///
  /// Wave 24 derivation (mirror of `web-player/app.js :: calculatePerSetSeconds`):
  ///
  ///   per_rep_seconds = (videoDurationMs / 1000) / (videoRepsPerLoop ?? 1)
  ///   per_set_seconds = (reps ?? 10) × per_rep_seconds + (holdSeconds ?? 0)
  ///
  /// Legacy rows with `videoRepsPerLoop == null` fall back to 1 rep per
  /// loop, preserving pre-Wave-24 playback math. Photos + holds with no
  /// video duration fall back to [AppConfig.secondsPerRep] (the legacy
  /// 3s baseline); Wave 24 didn't change that branch.
  ///
  /// Milestone Q — inter-set rest is per-exercise. The stored
  /// [interSetRestSeconds] replaces the legacy [AppConfig.restBetweenSets]
  /// baseline:
  ///
  ///   exercise_total = sets × per_set
  ///                  + max(0, sets - 1) × (interSetRestSeconds ?? 0)
  ///
  /// Legacy rows (null) therefore compute without any inter-set rest —
  /// a deliberate shift per the brief. Fresh captures seed to 15 via
  /// [withPersistenceDefaults] so the default experience is unchanged
  /// in spirit (just shorter by design).
  int get estimatedDurationSeconds {
    if (isRest) return holdSeconds ?? AppConfig.defaultRestDuration;
    final perRep = (mediaType == MediaType.video &&
            videoDurationMs != null &&
            videoDurationMs! > 0)
        ? ((videoDurationMs! / 1000) / (videoRepsPerLoop ?? 1)).round()
        : AppConfig.secondsPerRep;
    final repsTime = (reps ?? 10) * perRep;
    final holdTime = holdSeconds ?? 0;
    final perSetTime = repsTime + holdTime;
    final totalSets = sets ?? 3;
    final betweenSet = interSetRestSeconds ?? 0;
    final restTime = (totalSets > 1) ? (totalSets - 1) * betweenSet : 0;
    return (perSetTime * totalSets) + restTime;
  }

  /// The duration to use everywhere — Wave 24 routes the new derivation
  /// through [estimatedDurationSeconds] and only falls back to the legacy
  /// [customDurationSeconds] override when the new field is also set on
  /// the same row (legacy rows captured pre-Wave-24, where the manual
  /// per-rep field was the only way to override the timing). Fresh
  /// captures never write `customDurationSeconds`, so the new path is
  /// the default.
  int get effectiveDurationSeconds =>
      customDurationSeconds ?? estimatedDurationSeconds;

  /// Whether the line drawing conversion is complete.
  bool get isConverted => conversionStatus == ConversionStatus.done;

  /// The best available file path — converted if ready, raw otherwise.
  /// Resolved to an absolute path for runtime use.
  String get displayFilePath => PathResolver.resolve(convertedFilePath ?? rawFilePath);

  /// Absolute path to the raw capture file.
  String get absoluteRawFilePath => PathResolver.resolve(rawFilePath);

  /// Absolute path to the converted line drawing, or null.
  String? get absoluteConvertedFilePath =>
      convertedFilePath != null ? PathResolver.resolve(convertedFilePath!) : null;

  /// Absolute path to the thumbnail, or null.
  String? get absoluteThumbnailPath =>
      thumbnailPath != null ? PathResolver.resolve(thumbnailPath!) : null;

  /// Absolute path to the compressed raw archive, or null.
  String? get absoluteArchiveFilePath =>
      archiveFilePath != null ? PathResolver.resolve(archiveFilePath!) : null;

  /// Absolute path to the segmented-color raw variant, or null.
  String? get absoluteSegmentedRawFilePath => segmentedRawFilePath != null
      ? PathResolver.resolve(segmentedRawFilePath!)
      : null;

  /// Absolute path to the Vision person-segmentation mask sidecar mp4,
  /// or null when the mask pass didn't run / failed non-fatally.
  String? get absoluteMaskFilePath =>
      maskFilePath != null ? PathResolver.resolve(maskFilePath!) : null;
}
