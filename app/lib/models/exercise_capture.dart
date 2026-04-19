import 'package:uuid/uuid.dart';
import '../config.dart';
import '../services/path_resolver.dart';

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
    this.videoDurationMs,
    this.archiveFilePath,
    this.archivedAt,
    this.lineDrawingUrl,
    this.grayscaleUrl,
    this.originalUrl,
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
      videoDurationMs: map['video_duration_ms'] as int?,
      archiveFilePath: map['archive_file_path'] as String?,
      archivedAt: map['archived_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['archived_at'] as int)
          : null,
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
      'video_duration_ms': videoDurationMs,
      'archive_file_path': archiveFilePath,
      'archived_at': archivedAt?.millisecondsSinceEpoch,
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
    int? videoDurationMs,
    bool clearVideoDurationMs = false,
    String? archiveFilePath,
    bool clearArchiveFilePath = false,
    DateTime? archivedAt,
    bool clearArchivedAt = false,
    String? lineDrawingUrl,
    bool clearLineDrawingUrl = false,
    String? grayscaleUrl,
    bool clearGrayscaleUrl = false,
    String? originalUrl,
    bool clearOriginalUrl = false,
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
      videoDurationMs: clearVideoDurationMs
          ? null
          : (videoDurationMs ?? this.videoDurationMs),
      archiveFilePath: clearArchiveFilePath
          ? null
          : (archiveFilePath ?? this.archiveFilePath),
      archivedAt: clearArchivedAt ? null : (archivedAt ?? this.archivedAt),
      lineDrawingUrl:
          clearLineDrawingUrl ? null : (lineDrawingUrl ?? this.lineDrawingUrl),
      grayscaleUrl:
          clearGrayscaleUrl ? null : (grayscaleUrl ?? this.grayscaleUrl),
      originalUrl: clearOriginalUrl ? null : (originalUrl ?? this.originalUrl),
    );
  }

  /// Estimated duration in seconds for this exercise (all sets).
  /// Rest periods simply return their holdSeconds.
  ///
  /// For video exercises, "one rep" is the actual video duration (the video
  /// IS the demonstration of one iteration). For photos, it falls back to
  /// the config-level [AppConfig.secondsPerRep] constant.
  int get estimatedDurationSeconds {
    if (isRest) return holdSeconds ?? AppConfig.defaultRestDuration;
    final perRep = (mediaType == MediaType.video &&
            videoDurationMs != null &&
            videoDurationMs! > 0)
        ? (videoDurationMs! / 1000).round()
        : AppConfig.secondsPerRep;
    final repsTime = (reps ?? 10) * perRep;
    final holdTime = holdSeconds ?? 0;
    final perSetTime = repsTime + holdTime;
    final totalSets = sets ?? 3;
    final restTime = (totalSets > 1) ? (totalSets - 1) * AppConfig.restBetweenSets : 0;
    return (perSetTime * totalSets) + restTime;
  }

  /// The duration to use everywhere — custom override if set, otherwise
  /// the auto-calculated estimate.
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
}
