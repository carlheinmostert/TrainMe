import 'dart:convert';
import 'package:uuid/uuid.dart';
import '../config.dart';
import 'exercise_capture.dart';

/// A capture session — one bio + one client sitting.
///
/// Contains an ordered list of exercise captures. The session is "active"
/// (unsent) until the bio taps Send, at which point [sentAt] and [planUrl]
/// are populated.
class Session {
  final String id;
  final String clientName;
  final String? title;
  final List<ExerciseCapture> exercises;
  final DateTime createdAt;
  final DateTime? sentAt;
  final String? planUrl;

  /// Maps circuitId to number of cycles for that circuit. Persisted as JSON.
  final Map<String, int> circuitCycles;

  /// Trainer-preferred rest interval in seconds. When null, falls back to
  /// [AppConfig.restInsertIntervalMinutes] * 60. Updated when the bio drags
  /// a rest period to a new position — the cumulative exercise time before
  /// that rest becomes the new preferred interval.
  final int? preferredRestIntervalSeconds;

  const Session({
    required this.id,
    required this.clientName,
    this.title,
    this.exercises = const [],
    required this.createdAt,
    this.sentAt,
    this.planUrl,
    this.circuitCycles = const {},
    this.preferredRestIntervalSeconds,
  });

  /// Create a new session with a generated UUID.
  factory Session.create({
    required String clientName,
    String? title,
  }) {
    return Session(
      id: const Uuid().v4(),
      clientName: clientName,
      title: title,
      createdAt: DateTime.now(),
      circuitCycles: {},
    );
  }

  /// Deserialize from a SQLite row. Exercises are attached separately.
  factory Session.fromMap(Map<String, dynamic> map,
      {List<ExerciseCapture> exercises = const []}) {
    Map<String, int> cycles = {};
    final cyclesJson = map['circuit_cycles'] as String?;
    if (cyclesJson != null && cyclesJson.isNotEmpty) {
      final decoded = json.decode(cyclesJson);
      if (decoded is Map) {
        cycles = decoded.map((k, v) => MapEntry(k as String, v as int));
      }
    }
    return Session(
      id: map['id'] as String,
      clientName: map['client_name'] as String,
      title: map['title'] as String?,
      exercises: exercises,
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
      sentAt: map['sent_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['sent_at'] as int)
          : null,
      planUrl: map['plan_url'] as String?,
      circuitCycles: cycles,
      preferredRestIntervalSeconds: map['preferred_rest_interval'] as int?,
    );
  }

  /// Serialize to a map suitable for SQLite insertion.
  /// Exercises are stored in their own table — not included here.
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'client_name': clientName,
      'title': title,
      'created_at': createdAt.millisecondsSinceEpoch,
      'sent_at': sentAt?.millisecondsSinceEpoch,
      'plan_url': planUrl,
      'circuit_cycles': circuitCycles.isEmpty
          ? null
          : json.encode(circuitCycles),
      'preferred_rest_interval': preferredRestIntervalSeconds,
    };
  }

  /// Create a modified copy.
  Session copyWith({
    String? clientName,
    String? title,
    List<ExerciseCapture>? exercises,
    DateTime? sentAt,
    String? planUrl,
    Map<String, int>? circuitCycles,
    int? preferredRestIntervalSeconds,
    bool clearPreferredRestInterval = false,
  }) {
    return Session(
      id: id,
      clientName: clientName ?? this.clientName,
      title: title ?? this.title,
      exercises: exercises ?? this.exercises,
      createdAt: createdAt,
      sentAt: sentAt ?? this.sentAt,
      planUrl: planUrl ?? this.planUrl,
      circuitCycles: circuitCycles ?? this.circuitCycles,
      preferredRestIntervalSeconds: clearPreferredRestInterval
          ? null
          : (preferredRestIntervalSeconds ?? this.preferredRestIntervalSeconds),
    );
  }

  /// The effective rest interval in seconds — preferred if set, else config default.
  int get effectiveRestIntervalSeconds =>
      preferredRestIntervalSeconds ?? (AppConfig.restInsertIntervalMinutes * 60);

  /// Get the number of cycles for a circuit. Returns 3 (default) if not set.
  int getCircuitCycles(String circuitId) {
    return circuitCycles[circuitId] ?? 3;
  }

  /// Return a new Session with the cycle count updated for a circuit.
  Session setCircuitCycles(String circuitId, int cycles) {
    final updated = Map<String, int>.from(circuitCycles);
    updated[circuitId] = cycles.clamp(1, 5);
    return copyWith(circuitCycles: updated);
  }

  /// Whether this session has been sent to the client.
  bool get isSent => sentAt != null;

  /// Whether all captures in this session have finished converting.
  bool get allConversionsComplete =>
      exercises.every((e) => e.isConverted);

  /// Number of exercises still awaiting conversion.
  int get pendingConversions =>
      exercises.where((e) => !e.isConverted).length;

  /// Total estimated duration in seconds for the entire session.
  /// Accounts for circuit cycles: groups consecutive exercises by circuitId,
  /// sums one round of each circuit, multiplies by cycles, and adds
  /// inter-round rest.
  int get estimatedTotalDurationSeconds {
    int total = 0;
    final int len = exercises.length;
    int i = 0;

    while (i < len) {
      final exercise = exercises[i];

      if (exercise.circuitId == null) {
        // Standalone exercise — use effective duration (custom override or calculated).
        total += exercise.effectiveDurationSeconds;
        i++;
      } else {
        // Circuit group — collect consecutive exercises with the same circuitId.
        final circuitId = exercise.circuitId!;
        int oneRoundSeconds = 0;

        while (i < len && exercises[i].circuitId == circuitId) {
          final ex = exercises[i];
          if (ex.isRest) {
            // Rest periods inside circuits: count their duration once per round.
            oneRoundSeconds += ex.holdSeconds ?? AppConfig.defaultRestDuration;
          } else if (ex.customDurationSeconds != null) {
            // Custom override set — use it directly for the per-round contribution.
            oneRoundSeconds += ex.customDurationSeconds!;
          } else {
            // For circuit exercises, compute per-exercise time for ONE pass
            // (reps + hold only, no sets — cycles replace sets).
            final repsTime = (ex.reps ?? 10) * AppConfig.secondsPerRep;
            final holdTime = ex.holdSeconds ?? 0;
            oneRoundSeconds += repsTime + holdTime;
          }
          i++;
        }

        final cycles = getCircuitCycles(circuitId);
        final interRoundRest = (cycles > 1)
            ? (cycles - 1) * AppConfig.restBetweenCircuitRounds
            : 0;
        total += (oneRoundSeconds * cycles) + interRoundRest;
      }
    }

    return total;
  }

  /// A display-friendly title: explicit title, or "Session for {client}".
  String get displayTitle => title ?? 'Session for $clientName';
}

/// Format a duration in seconds into a human-readable string.
String formatDuration(int totalSeconds) {
  if (totalSeconds < 60) return '${totalSeconds}s';
  final minutes = totalSeconds ~/ 60;
  if (minutes < 60) return '$minutes min';
  final hours = minutes ~/ 60;
  final remainingMinutes = minutes % 60;
  if (remainingMinutes == 0) return '${hours}h';
  return '${hours}h ${remainingMinutes}min';
}
