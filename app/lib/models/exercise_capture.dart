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
    );
  }

  /// Estimated duration in seconds for this exercise (all sets).
  /// Rest periods simply return their holdSeconds.
  int get estimatedDurationSeconds {
    if (isRest) return holdSeconds ?? AppConfig.defaultRestDuration;
    final repsTime = (reps ?? 10) * AppConfig.secondsPerRep;
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
}
