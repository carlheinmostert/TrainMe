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

  /// Timestamp of the most recent content edit (reps / sets / hold /
  /// notes / name / custom duration / treatment / prep / muted / add /
  /// delete / reorder / circuit change / session title).
  ///
  /// Pure-UI state (scroll position, expand/collapse) does NOT stamp this
  /// — only mutations that would change what the client sees. Compared
  /// against [sentAt] by the session-card indicator:
  ///   - `isPublished && lastContentEditAt ≤ sentAt` → clean (sage ✓).
  ///   - `isPublished && lastContentEditAt > sentAt`  → dirty (coral
  ///     cloud-sync icon, tap re-publishes).
  /// Legacy rows with a null timestamp are treated as clean (pre-feature
  /// edits we have no record of).
  final DateTime? lastContentEditAt;

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

  /// Maps circuitId to a practitioner-supplied display label. Missing key
  /// (or empty value) means "use the auto-assigned letter" — surfaces show
  /// "Circuit A" / "Circuit B" / … from [_circuitLetter] in that case.
  /// Persisted as JSON locally; round-trips through `plans.circuit_names`
  /// jsonb on the cloud.
  final Map<String, String> circuitNames;

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
  /// by the `get_plan_full` RPC atomically on first read; also stamped via
  /// the Wave 33 `record_plan_opened` RPC). Used by the publish-lock rule:
  /// once a client has opened the plan, add/reorder/swap is locked after the
  /// 14-day grace; delete stays free. Milestone A records the column; the
  /// 14-day lock UI lives in StudioModeScreen.
  final DateTime? firstOpenedAt;

  /// Timestamp of the most recent client open (Wave 33). Stamped by the
  /// `record_plan_opened` SECURITY DEFINER RPC on every web-player session
  /// start. Drives the studio analytics row "First opened {date} · Last
  /// opened {date}" without altering the lock policy (which keys off
  /// firstOpenedAt + 14d). NULL when the plan has never been opened.
  final DateTime? lastOpenedAt;

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

  /// Supabase `clients.id` this session belongs to. Null for legacy sessions
  /// created before the Clients-as-Home-spine shift (those are resolved by
  /// the ClientSessionsScreen via `clientName == client.name` fallback).
  ///
  /// Populated at session-creation time by `ClientSessionsScreen._startNewSession`
  /// (from the `clients` row the practitioner drilled into) and round-trips
  /// through SQLite schema v16 (`client_id TEXT`).
  final String? clientId;

  /// Wave 27 — per-plan dual-video crossfade preroll, in milliseconds.
  /// NULL means "use the surface default" (250 on web + mobile). The
  /// _MediaViewer tuner writes through here; on publish the value
  /// flows to the cloud via `plans.crossfade_lead_ms`, then back to
  /// the web player through `to_jsonb(plan_row)` in `get_plan_full`.
  final int? crossfadeLeadMs;

  /// Wave 27 — per-plan dual-video crossfade duration, in milliseconds.
  /// NULL means "use the surface default" (200 on web + mobile).
  /// Same round-trip path as [crossfadeLeadMs].
  final int? crossfadeFadeMs;

  /// Wave 29 — set when the practitioner pre-pays a credit via
  /// `unlock_plan_for_edit` to re-open structural editing on a plan that
  /// crossed the post-publish lock window. The next successful publish
  /// reads + clears this server-side inside `consume_credit` (no double
  /// charge); locally the field clears on the next session reload from
  /// SQLite (which mirrors the cloud row).
  final DateTime? unlockCreditPrepaidAt;

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
    this.lastContentEditAt,
    this.lastPublishError,
    this.publishAttemptCount = 0,
    this.circuitCycles = const {},
    this.circuitNames = const {},
    this.preferredRestIntervalSeconds,
    this.practiceId,
    this.firstOpenedAt,
    this.lastOpenedAt,
    this.createdByUserId,
    this.clientId,
    this.crossfadeLeadMs,
    this.crossfadeFadeMs,
    this.unlockCreditPrepaidAt,
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
    String? clientId,
  }) {
    return Session(
      id: const Uuid().v4(),
      clientName: clientName,
      title: title,
      createdAt: DateTime.now(),
      circuitCycles: {},
      createdByUserId: AuthService.instance.currentUserId,
      clientId: clientId,
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
    Map<String, String> names = {};
    final namesJson = map['circuit_names'] as String?;
    if (namesJson != null && namesJson.isNotEmpty) {
      try {
        final decoded = json.decode(namesJson);
        if (decoded is Map) {
          names = decoded.map(
            (k, v) => MapEntry(k.toString(), v?.toString() ?? ''),
          );
        }
      } catch (_) {
        names = {};
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
      lastContentEditAt: map['last_content_edit_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(
              map['last_content_edit_at'] as int)
          : null,
      lastPublishError: map['last_publish_error'] as String?,
      publishAttemptCount: (map['publish_attempt_count'] as int?) ?? 0,
      circuitCycles: cycles,
      circuitNames: names,
      preferredRestIntervalSeconds: map['preferred_rest_interval'] as int?,
      // `practice_id` and `first_opened_at` only exist on remote Supabase rows
      // today — no local SQLite mirror yet. If present (remote hydration path),
      // we round-trip them; otherwise they stay null.
      practiceId: map['practice_id'] as String?,
      firstOpenedAt: _parseTimestamp(map['first_opened_at']),
      lastOpenedAt: _parseTimestamp(map['last_opened_at']),
      createdByUserId: map['created_by_user_id'] as String?,
      clientId: map['client_id'] as String?,
      crossfadeLeadMs: map['crossfade_lead_ms'] as int?,
      crossfadeFadeMs: map['crossfade_fade_ms'] as int?,
      unlockCreditPrepaidAt: _parseTimestamp(map['unlock_credit_prepaid_at']),
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
  /// `practiceId` is omitted (claim-time + membership-derived; not local).
  /// `firstOpenedAt` IS persisted (Wave 29 follow-up): SessionShell
  /// reconciles cloud → local on open so the structural-edit lock UI
  /// can read it offline.
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
      'last_content_edit_at': lastContentEditAt?.millisecondsSinceEpoch,
      'last_publish_error': lastPublishError,
      'publish_attempt_count': publishAttemptCount,
      'circuit_cycles': circuitCycles.isEmpty
          ? null
          : json.encode(circuitCycles),
      'circuit_names':
          circuitNames.isEmpty ? null : json.encode(circuitNames),
      'preferred_rest_interval': preferredRestIntervalSeconds,
      'created_by_user_id': createdByUserId,
      'client_id': clientId,
      'crossfade_lead_ms': crossfadeLeadMs,
      'crossfade_fade_ms': crossfadeFadeMs,
      'unlock_credit_prepaid_at':
          unlockCreditPrepaidAt?.millisecondsSinceEpoch,
      'first_opened_at': firstOpenedAt?.millisecondsSinceEpoch,
      'last_opened_at': lastOpenedAt?.millisecondsSinceEpoch,
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
    DateTime? lastContentEditAt,
    String? lastPublishError,
    bool clearLastPublishError = false,
    int? publishAttemptCount,
    Map<String, int>? circuitCycles,
    Map<String, String>? circuitNames,
    int? preferredRestIntervalSeconds,
    bool clearPreferredRestInterval = false,
    String? practiceId,
    DateTime? firstOpenedAt,
    bool clearFirstOpenedAt = false,
    DateTime? lastOpenedAt,
    bool clearLastOpenedAt = false,
    String? createdByUserId,
    String? clientId,
    int? crossfadeLeadMs,
    int? crossfadeFadeMs,
    bool clearCrossfadeLeadMs = false,
    bool clearCrossfadeFadeMs = false,
    DateTime? unlockCreditPrepaidAt,
    bool clearUnlockCreditPrepaidAt = false,
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
      lastContentEditAt: lastContentEditAt ?? this.lastContentEditAt,
      lastPublishError: clearLastPublishError
          ? null
          : (lastPublishError ?? this.lastPublishError),
      publishAttemptCount: publishAttemptCount ?? this.publishAttemptCount,
      circuitCycles: circuitCycles ?? this.circuitCycles,
      circuitNames: circuitNames ?? this.circuitNames,
      preferredRestIntervalSeconds: clearPreferredRestInterval
          ? null
          : (preferredRestIntervalSeconds ?? this.preferredRestIntervalSeconds),
      practiceId: practiceId ?? this.practiceId,
      firstOpenedAt: clearFirstOpenedAt
          ? null
          : (firstOpenedAt ?? this.firstOpenedAt),
      lastOpenedAt: clearLastOpenedAt
          ? null
          : (lastOpenedAt ?? this.lastOpenedAt),
      createdByUserId: createdByUserId ?? this.createdByUserId,
      clientId: clientId ?? this.clientId,
      crossfadeLeadMs: clearCrossfadeLeadMs
          ? null
          : (crossfadeLeadMs ?? this.crossfadeLeadMs),
      crossfadeFadeMs: clearCrossfadeFadeMs
          ? null
          : (crossfadeFadeMs ?? this.crossfadeFadeMs),
      unlockCreditPrepaidAt: clearUnlockCreditPrepaidAt
          ? null
          : (unlockCreditPrepaidAt ?? this.unlockCreditPrepaidAt),
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

  /// Custom display name for a circuit. Returns the practitioner-set name
  /// when present and non-empty; otherwise null (caller falls back to the
  /// auto-assigned letter).
  String? getCircuitName(String circuitId) {
    final raw = circuitNames[circuitId];
    if (raw == null) return null;
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// Return a new Session with the custom name set or cleared for a
  /// circuit. Empty / whitespace-only [name] removes the entry so the
  /// surface falls back to the auto label.
  Session setCircuitName(String circuitId, String name) {
    final updated = Map<String, String>.from(circuitNames);
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      updated.remove(circuitId);
    } else {
      updated[circuitId] = trimmed;
    }
    return copyWith(circuitNames: updated);
  }

  /// Whether this session has been sent to the client.
  bool get isSent => sentAt != null;

  /// Whether this plan has been published at least once.
  bool get isPublished => version > 0 && planUrl != null;

  /// True when [isPublished] AND the most recent content edit is newer
  /// than the last publish stamp ([sentAt]).
  ///
  /// Legacy rows with null [lastContentEditAt] are treated as clean — we
  /// have no record of pre-feature edits, so defaulting to "dirty" would
  /// make every historic session re-prompt the trainer on upgrade, which
  /// is noisier than the eventual value of the indicator warrants.
  ///
  /// Pre-publish drafts return false — the card already renders the
  /// coral "cloud_upload" glyph based on [isPublished] alone, so
  /// dirty-vs-clean is only a distinction once a plan has been sent at
  /// least once.
  bool get hasUnpublishedContentChanges {
    if (!isPublished) return false;
    final edited = lastContentEditAt;
    if (edited == null) return false;
    final sent = sentAt;
    if (sent == null) return true;
    return edited.isAfter(sent);
  }

  /// Whether all captures in this session have finished converting.
  bool get allConversionsComplete =>
      exercises.every((e) => e.isConverted);

  /// Number of exercises still awaiting conversion (pending or in-flight).
  /// Failed rows are NOT counted here — they get their own coral "N failed"
  /// retry pill on the session card.
  int get pendingConversions => exercises
      .where((e) =>
          e.conversionStatus == ConversionStatus.pending ||
          e.conversionStatus == ConversionStatus.converting)
      .length;

  /// Total estimated duration in seconds for the entire session.
  /// Accounts for circuit cycles: groups consecutive exercises by circuitId,
  /// sums one round of each circuit, multiplies by cycles, and adds
  /// inter-round rest.
  ///
  /// Per-set PLAN wave: standalone exercises route through
  /// [ExerciseCapture.estimatedDurationSeconds] (which sums per-set
  /// internally). Inside a circuit, "one pass" uses the FIRST set only
  /// (cycles replace sets — running 3 cycles of a 1-set exercise feels
  /// like 3 sets). The breather after that single set is the
  /// inter-rep window inside the circuit pass; subsequent rounds use
  /// [AppConfig.restBetweenCircuitRounds].
  int get estimatedTotalDurationSeconds {
    int total = 0;
    final int len = exercises.length;
    int i = 0;

    while (i < len) {
      final exercise = exercises[i];

      if (exercise.circuitId == null) {
        // Standalone exercise — defer to per-set summing inside
        // ExerciseCapture.
        total += exercise.effectiveDurationSeconds;
        i++;
      } else {
        // Circuit group — collect consecutive exercises with the same circuitId.
        final circuitId = exercise.circuitId!;
        int oneRoundSeconds = 0;

        while (i < len && exercises[i].circuitId == circuitId) {
          final ex = exercises[i];
          if (ex.isRest) {
            oneRoundSeconds +=
                ex.restHoldSeconds ?? AppConfig.defaultRestDuration;
          } else if (ex.sets.isNotEmpty) {
            // Per-set PLAN: inside a circuit pass we count the FIRST
            // set only (cycles replace per-exercise set count). Breather
            // after that set is the within-pass rest.
            final first = ex.sets.first;
            final perRep = (ex.mediaType == MediaType.video &&
                    ex.videoDurationMs != null &&
                    ex.videoDurationMs! > 0)
                ? ((ex.videoDurationMs! / 1000) / (ex.videoRepsPerLoop ?? 1))
                    .round()
                : AppConfig.secondsPerRep;
            oneRoundSeconds += first.reps * perRep +
                first.holdSeconds +
                first.breatherSecondsAfter;
          } else {
            // Empty sets list (capture without persistence defaults
            // applied yet) — fall back to a baseline 10-rep estimate
            // so the circuit still has a non-zero duration. Matches
            // the legacy default of `reps ?? 10`.
            oneRoundSeconds += 10 * AppConfig.secondsPerRep;
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
