import 'dart:convert';
import 'package:uuid/uuid.dart';
import '../config.dart';
import '../services/auth_service.dart';
import '../utils/duration_format.dart';
import 'exercise_capture.dart';

/// A capture session — one bio + one client sitting.
///
/// Contains an ordered list of exercise captures. The session is "active"
/// until explicitly archived. Publishing sets [planUrl] and increments
/// [version]. The session stays editable after publishing — the trainer can
/// update exercises and re-publish.
class Session {
  final String id;
  final String clientName;
  final String? title;
  final List<ExerciseCapture> exercises;
  final DateTime createdAt;
  final DateTime? sentAt;
  final String? planUrl;

  /// Plan version. 0 = never published. First publish sets it to 1, each
  /// subsequent publish increments it.
  final int version;

  /// Timestamp of the most recent publish. Used together with exercise
  /// modification times to detect unpublished changes.
  final DateTime? lastPublishedAt;

  /// Last error message from a failed publish attempt (null when the most
  /// recent attempt succeeded, or no publish has been attempted yet).
  /// Column: `last_publish_error`. Set by upload_service.
  final String? lastPublishError;

  /// How many publish attempts have been made for this session across all
  /// versions. Incremented by upload_service on each attempt regardless of
  /// outcome. Column: `publish_attempt_count`.
  final int publishAttemptCount;

  /// Maps circuitId to number of cycles for that circuit. Persisted as JSON.
  final Map<String, int> circuitCycles;

  /// Trainer-preferred rest interval in seconds. When null, falls back to
  /// [AppConfig.restInsertIntervalMinutes] * 60. Updated when the bio drags
  /// a rest period to a new position — the cumulative exercise time before
  /// that rest becomes the new preferred interval.
  final int? preferredRestIntervalSeconds;

  /// Practice tenant that owns this plan. Added in Milestone A (multi-tenant
  /// billing foundation). Not persisted locally yet — the trainer app uses
  /// [AppConfig.sentinelPracticeId] when publishing. Exposed here so
  /// round-trips through Supabase preserve the value.
  final String? practiceId;

  /// Timestamp of the first time the client web player fetched this plan (set
  /// by the `get_plan_full` RPC atomically on first read). Used by the future
  /// publish-lock rule: once a client has opened the plan, add/reorder/swap
  /// is locked; delete stays free. Milestone A records the column; the lock
  /// UI lands in a later milestone.
  final DateTime? firstOpenedAt;

  /// Supabase `auth.users.id` of the practitioner who created this session on
  /// this device. Persisted locally in SQLite as `created_by_user_id` (schema
  /// v14). Scopes the Home screen list so sessions created under account A
  /// don't leak into account B's view when they sign in on the same device.
  ///
  /// Nullable on purpose:
  ///   - rows that existed before v14 land as NULL and get claimed by the
  ///     first signed-in user to open the Home screen (see
  ///     `LocalStorageService.claimOrphanSessions`).
  ///   - a session drafted while signed out (cold-start edge case) stays
  ///     NULL until the next Home load claims it.
  final String? createdByUserId;

  const Session({
    required this.id,
    required this.clientName,
    this.title,
    this.exercises = const [],
    required this.createdAt,
    this.sentAt,
    this.planUrl,
    this.version = 0,
    this.lastPublishedAt,
    this.lastPublishError,
    this.publishAttemptCount = 0,
    this.circuitCycles = const {},
    this.preferredRestIntervalSeconds,
    this.practiceId,
    this.firstOpenedAt,
    this.createdByUserId,
  });

  /// Create a new session with a generated UUID.
  ///
  /// Populates [createdByUserId] from [AuthService.instance.currentUserId] at
  /// construction time so the Home screen can scope the session list to the
  /// authenticated practitioner. When no user is signed in (cold-start before
  /// sign-in), the field stays null and the row gets claimed by the first
  /// user to open the Home screen after signing in — see
  /// `LocalStorageService.claimOrphanSessions`.
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
      createdByUserId: AuthService.instance.currentUserId,
    );
  }

  /// Deserialize from a SQLite row. Exercises are attached separately.
  factory Session.fromMap(Map<String, dynamic> map,
      {List<ExerciseCapture> exercises = const []}) {
    Map<String, int> cycles = {};
    final cyclesJson = map['circuit_cycles'] as String?;
    if (cyclesJson != null && cyclesJson.isNotEmpty) {
      try {
        final decoded = json.decode(cyclesJson);
        if (decoded is Map) {
          cycles = decoded.map((k, v) {
            // Tolerate schema drift: value may be int, String, or null.
            // Fall back to the default of 3 cycles for anything invalid.
            int cycleCount = 3;
            if (v is int) {
              cycleCount = v;
            } else if (v is String) {
              cycleCount = int.tryParse(v) ?? 3;
            } else if (v is num) {
              cycleCount = v.toInt();
            }
            return MapEntry(k.toString(), cycleCount);
          });
        }
      } catch (_) {
        // Malformed JSON — start with an empty cycles map.
        cycles = {};
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
      version: (map['version'] as int?) ?? 0,
      lastPublishedAt: map['last_published_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['last_published_at'] as int)
          : null,
      lastPublishError: map['last_publish_error'] as String?,
      publishAttemptCount: (map['publish_attempt_count'] as int?) ?? 0,
      circuitCycles: cycles,
      preferredRestIntervalSeconds: map['preferred_rest_interval'] as int?,
      // `practice_id` and `first_opened_at` only exist on remote Supabase rows
      // today — no local SQLite mirror yet. If present (remote hydration path),
      // we round-trip them; otherwise they stay null.
      practiceId: map['practice_id'] as String?,
      firstOpenedAt: _parseTimestamp(map['first_opened_at']),
      createdByUserId: map['created_by_user_id'] as String?,
    );
  }

  /// Accept either an ISO-8601 string (remote Supabase JSON) or a
  /// millisecondsSinceEpoch int (future local SQLite mirror) or null.
  static DateTime? _parseTimestamp(Object? value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
    if (value is String) return DateTime.tryParse(value);
    return null;
  }

  /// Serialize to a map suitable for SQLite insertion.
  /// Exercises are stored in their own table — not included here.
  ///
  /// Note: `practiceId` and `firstOpenedAt` are intentionally NOT included
  /// here. They exist only on the remote Supabase `plans` row in Milestone A;
  /// the local SQLite schema gets matching columns when auth / membership
  /// goes dynamic in a later milestone. Adding them here today would error
  /// against the current LocalStorageService schema.
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'client_name': clientName,
      'title': title,
      'created_at': createdAt.millisecondsSinceEpoch,
      'sent_at': sentAt?.millisecondsSinceEpoch,
      'plan_url': planUrl,
      'version': version,
      'last_published_at': lastPublishedAt?.millisecondsSinceEpoch,
      'last_publish_error': lastPublishError,
      'publish_attempt_count': publishAttemptCount,
      'circuit_cycles': circuitCycles.isEmpty
          ? null
          : json.encode(circuitCycles),
      'preferred_rest_interval': preferredRestIntervalSeconds,
      'created_by_user_id': createdByUserId,
    };
  }

  /// Create a modified copy.
  Session copyWith({
    String? clientName,
    String? title,
    List<ExerciseCapture>? exercises,
    DateTime? sentAt,
    String? planUrl,
    int? version,
    DateTime? lastPublishedAt,
    String? lastPublishError,
    bool clearLastPublishError = false,
    int? publishAttemptCount,
    Map<String, int>? circuitCycles,
    int? preferredRestIntervalSeconds,
    bool clearPreferredRestInterval = false,
    String? practiceId,
    DateTime? firstOpenedAt,
    String? createdByUserId,
  }) {
    return Session(
      id: id,
      clientName: clientName ?? this.clientName,
      title: title ?? this.title,
      exercises: exercises ?? this.exercises,
      createdAt: createdAt,
      sentAt: sentAt ?? this.sentAt,
      planUrl: planUrl ?? this.planUrl,
      version: version ?? this.version,
      lastPublishedAt: lastPublishedAt ?? this.lastPublishedAt,
      lastPublishError: clearLastPublishError
          ? null
          : (lastPublishError ?? this.lastPublishError),
      publishAttemptCount: publishAttemptCount ?? this.publishAttemptCount,
      circuitCycles: circuitCycles ?? this.circuitCycles,
      preferredRestIntervalSeconds: clearPreferredRestInterval
          ? null
          : (preferredRestIntervalSeconds ?? this.preferredRestIntervalSeconds),
      practiceId: practiceId ?? this.practiceId,
      firstOpenedAt: firstOpenedAt ?? this.firstOpenedAt,
      createdByUserId: createdByUserId ?? this.createdByUserId,
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

  /// Whether this plan has been published at least once.
  bool get isPublished => version > 0 && planUrl != null;

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
///
/// Thin wrapper that defaults to the verbose style ("Ns" / "N min" /
/// "Nh Nmin"). Call [formatDurationStyled] directly for other styles.
String formatDuration(int totalSeconds) =>
    formatDurationStyled(totalSeconds, style: DurationFormatStyle.verbose);
