import 'package:flutter/foundation.dart';

import '../models/cached_client.dart';
import '../models/exercise_capture.dart';
import '../models/exercise_set.dart';
import '../models/treatment.dart';
import 'client_defaults_api.dart';
import 'sync_service.dart';

/// Sticky per-client exercise defaults.
///
/// Two responsibilities:
///
///   1. **Pre-fill** — given a freshly-minted [ExerciseCapture] and a
///      [CachedClient], return a copy with the surviving sticky fields
///      populated from the client's [CachedClient.clientExerciseDefaults].
///      Fields already non-null on the exercise are left alone (the
///      capture path seeds empty fields; pre-fill only).
///
///      For per-set fields (reps / hold / weight / breather) — there
///      isn't a "current value" on the exercise to compare against (the
///      [ExerciseCapture.sets] list is opaque). When pre-filling a
///      brand-new capture whose `sets` was just seeded by
///      [ExerciseCapture.withPersistenceDefaults], the helper rebuilds
///      the synthetic first set with the sticky-stored values when they
///      exist.
///
///   2. **Write-back** — given a client id, a field key, and a value,
///      queue a local-first write of the new default through
///      [SyncService]. Called on every practitioner override on the
///      PLAN editor / pacing controls so the next new capture for this
///      client inherits the latest choice.
///
/// **Forward-only.** Editing exercise N doesn't retroactively touch
/// exercise N-1; it only biases the NEXT new exercise.
///
/// **Per-set PLAN wave note** — the legacy field set (`reps`, `sets`,
/// `hold_seconds`, `inter_set_rest_seconds`, `custom_duration_seconds`)
/// retired alongside the database migration. The replacement keys are
/// scoped to the FIRST set (`first_set_reps`, `first_set_hold_seconds`,
/// `first_set_weight_kg`, `first_set_breather_seconds`) — matching the
/// "common case" the practitioner would have wanted seeded. Subsequent
/// sets within the same exercise are practitioner-authored on the PLAN
/// table; we don't try to forward-propagate full set lists.
///
/// **Wave 39 — in-memory overlay.** A static `_memoryOverlay`
/// per-client map updates SYNCHRONOUSLY on every override and is
/// consulted FIRST during prefill — SQLite stays the canonical store
/// but the in-memory layer guarantees forward-only propagation even
/// mid-flight. Both layers stay consistent because every
/// `recordOverride` writes to both.
class StickyDefaults {
  StickyDefaults._();

  /// Wire field names (exposed for call sites that don't also want to
  /// import [ClientDefaultsApi]).
  static const String fIncludeAudio = ClientDefaultsApi.fIncludeAudio;
  static const String fPreferredTreatment =
      ClientDefaultsApi.fPreferredTreatment;
  static const String fPrepSeconds = ClientDefaultsApi.fPrepSeconds;
  static const String fVideoRepsPerLoop = ClientDefaultsApi.fVideoRepsPerLoop;
  // Wave 42 — per-exercise practitioner body-focus default.
  static const String fBodyFocus = ClientDefaultsApi.fBodyFocus;

  /// Per-set first-set sticky seeds (per-set PLAN wave).
  static const String fFirstSetReps = ClientDefaultsApi.fFirstSetReps;
  static const String fFirstSetHoldSeconds =
      ClientDefaultsApi.fFirstSetHoldSeconds;
  static const String fFirstSetWeightKg = ClientDefaultsApi.fFirstSetWeightKg;
  static const String fFirstSetBreatherSeconds =
      ClientDefaultsApi.fFirstSetBreatherSeconds;

  /// In-memory write-through overlay keyed by client id. Every
  /// [recordOverride] writes here SYNCHRONOUSLY so the next capture's
  /// [prefillCapture] sees the latest value even if SQLite hasn't
  /// flushed yet. Process-local — cleared on app restart, at which
  /// point SQLite (the canonical store) rehydrates the cache.
  static final Map<String, Map<String, Object?>> _memoryOverlay =
      <String, Map<String, Object?>>{};

  /// Prime the in-memory overlay from a freshly-loaded SQLite snapshot.
  /// Existing overlay wins per-key.
  static void primeFromSnapshot(String clientId, Map<String, dynamic> snapshot) {
    if (clientId.isEmpty) return;
    if (snapshot.isEmpty) return;
    final overlay = _memoryOverlay[clientId];
    if (overlay == null) {
      _memoryOverlay[clientId] = Map<String, Object?>.from(snapshot);
      return;
    }
    for (final entry in snapshot.entries) {
      overlay.putIfAbsent(entry.key, () => entry.value);
    }
  }

  /// Resolve the effective defaults map for [clientId]. Merge order:
  ///   - SQLite-cached snapshot (passed by caller as [cachedDefaults])
  ///   - In-memory overlay (this-process write-throughs since launch)
  ///
  /// The overlay always wins per-field — it represents writes that may
  /// not have flushed to SQLite yet. Returns an empty map when both are
  /// empty (no per-client default at all).
  static Map<String, dynamic> effectiveDefaults({
    required String clientId,
    required Map<String, dynamic> cachedDefaults,
  }) {
    final merged = Map<String, dynamic>.from(cachedDefaults);
    final overlay = _memoryOverlay[clientId];
    if (overlay != null) {
      merged.addAll(overlay);
    }
    return merged;
  }

  /// Test / diagnostic: clear the in-memory overlay. Production code never
  /// needs to call this.
  @visibleForTesting
  static void resetOverlay() {
    _memoryOverlay.clear();
  }

  /// Pre-fill [exercise] with sticky fields from [defaults].
  ///
  /// Top-level scalar fields (includeAudio, preferredTreatment,
  /// prepSeconds, videoRepsPerLoop) are filled when the exercise's
  /// current value is null / default.
  ///
  /// First-set fields (reps / hold / weight / breather) are applied to
  /// the FIRST element of [ExerciseCapture.sets] when:
  ///   * the exercise has at least one set;
  ///   * the first set looks like the synthetic seed
  ///     ([ExerciseSet] with the canonical defaults from
  ///     [ExerciseCapture.withPersistenceDefaults]); we don't try to
  ///     overwrite a practitioner-authored first set.
  ///
  /// Rest periods are returned unchanged. When [defaults] is empty the
  /// exercise is returned unchanged.
  static ExerciseCapture prefillCapture(
    ExerciseCapture exercise,
    Map<String, dynamic> defaults,
  ) {
    if (exercise.isRest) return exercise;
    if (defaults.isEmpty) return exercise;

    final next = exercise.copyWith(
      includeAudio: _asBool(defaults[fIncludeAudio]) ?? exercise.includeAudio,
      preferredTreatment: exercise.preferredTreatment ??
          _asTreatment(defaults[fPreferredTreatment]),
      prepSeconds: exercise.prepSeconds ?? _asInt(defaults[fPrepSeconds]),
      videoRepsPerLoop: exercise.videoRepsPerLoop ??
          _asInt(defaults[fVideoRepsPerLoop]),
      // Wave 42 — body-focus default. null on the new exercise means
      // "no explicit choice yet"; pull the client's last toggled value
      // from defaults. The web player + mobile preview both interpret
      // null as "render with body-focus ON" so the default-default is
      // unchanged from pre-Wave-42 behaviour.
      bodyFocus: exercise.bodyFocus ?? _asBool(defaults[fBodyFocus]),
    );

    // Apply first-set sticky values when we have a synthetic-looking
    // first set. The seed planted by withPersistenceDefaults is
    // (reps=10, hold=0, weight=null, breather=30). If the exercise's
    // first set still matches that shape exactly, replace it with the
    // sticky version.
    if (next.sets.isEmpty) return next;
    final first = next.sets.first;
    final isSyntheticSeed = first.position == 1 &&
        first.reps == 10 &&
        first.holdSeconds == 0 &&
        first.weightKg == null &&
        first.breatherSecondsAfter == 30;
    if (!isSyntheticSeed) return next;

    final stickyReps = _asInt(defaults[fFirstSetReps]);
    final stickyHold = _asInt(defaults[fFirstSetHoldSeconds]);
    final stickyWeight = _asDouble(defaults[fFirstSetWeightKg]);
    final stickyBreather = _asInt(defaults[fFirstSetBreatherSeconds]);
    if (stickyReps == null &&
        stickyHold == null &&
        stickyWeight == null &&
        stickyBreather == null) {
      return next;
    }
    final replaced = first.copyWith(
      reps: stickyReps ?? first.reps,
      holdSeconds: stickyHold ?? first.holdSeconds,
      weightKg:
          defaults.containsKey(fFirstSetWeightKg) ? stickyWeight : first.weightKg,
      breatherSecondsAfter: stickyBreather ?? first.breatherSecondsAfter,
    );
    final newSets = <ExerciseSet>[
      replaced,
      ...next.sets.skip(1),
    ];
    return next.copyWith(sets: newSets);
  }

  /// Apply the **global** capture-time defaults to fields that are still
  /// null after sticky-defaults pre-fill. This is the "first-ever capture
  /// for this client" / "no sticky default for this field" fallback:
  ///
  ///   * `preferredTreatment` → [Treatment.grayscale] (B&W). Replaces the
  ///     pre-2026-05-12 implicit fallback of [Treatment.line], which lives
  ///     at READ time (`ex.preferredTreatment ?? Treatment.line`). By
  ///     writing the value EXPLICITLY on new captures we shift the
  ///     default-default without disturbing existing NULL rows in the
  ///     database.
  ///   * `bodyFocus` → `false` (off). Same logic — the existing read-time
  ///     fallback (`bodyFocus ?? true`) keeps legacy NULL rows on the old
  ///     body-focus-ON behaviour while new captures land with an explicit
  ///     `false`.
  ///
  /// Sticky-defaults always win: this helper only fills fields that are
  /// STILL null after [prefillCapture]. Existing exercises in the DB are
  /// untouched (this only runs on the freshly-minted capture path).
  ///
  /// Rest periods skip both fields entirely (they have neither concept).
  static ExerciseCapture applyGlobalCaptureDefaults(ExerciseCapture exercise) {
    if (exercise.isRest) return exercise;
    final needsTreatment = exercise.preferredTreatment == null;
    final needsBodyFocus = exercise.bodyFocus == null;
    if (!needsTreatment && !needsBodyFocus) return exercise;
    return exercise.copyWith(
      preferredTreatment:
          needsTreatment ? Treatment.grayscale : exercise.preferredTreatment,
      bodyFocus: needsBodyFocus ? false : exercise.bodyFocus,
    );
  }

  /// Fire-and-forget: write a single override back into the client's
  /// sticky defaults.
  static void recordOverride({
    required String? clientId,
    required String field,
    required Object? value,
  }) {
    if (clientId == null || clientId.isEmpty) return;
    final overlay = _memoryOverlay.putIfAbsent(
      clientId,
      () => <String, Object?>{},
    );
    if (value == null) {
      overlay.remove(field);
    } else {
      overlay[field] = value;
    }
    SyncService.instance
        .queueSetExerciseDefault(
      clientId: clientId,
      field: field,
      value: value,
    )
        .then((_) {
      // Success path is quiet.
    }, onError: (e) {
      debugPrint('StickyDefaults.recordOverride($field) failed: $e');
    });
  }

  /// Compare any two exercise snapshots and queue every sticky-field
  /// delta. Per-set PLAN wave: scalars are compared directly; first-set
  /// fields are derived from `sets.first` when both snapshots have at
  /// least one set.
  static void recordAllDeltas({
    required String? clientId,
    required ExerciseCapture before,
    required ExerciseCapture after,
  }) {
    if (clientId == null || clientId.isEmpty) return;

    if (before.includeAudio != after.includeAudio) {
      recordOverride(
        clientId: clientId,
        field: fIncludeAudio,
        value: after.includeAudio,
      );
    }
    if (before.preferredTreatment != after.preferredTreatment) {
      recordOverride(
        clientId: clientId,
        field: fPreferredTreatment,
        value: after.preferredTreatment?.wireValue,
      );
    }
    if (before.prepSeconds != after.prepSeconds) {
      recordOverride(
        clientId: clientId,
        field: fPrepSeconds,
        value: after.prepSeconds,
      );
    }
    if (before.videoRepsPerLoop != after.videoRepsPerLoop) {
      recordOverride(
        clientId: clientId,
        field: fVideoRepsPerLoop,
        value: after.videoRepsPerLoop,
      );
    }

    final beforeFirst = before.sets.isNotEmpty ? before.sets.first : null;
    final afterFirst = after.sets.isNotEmpty ? after.sets.first : null;
    if (afterFirst != null) {
      if (beforeFirst?.reps != afterFirst.reps) {
        recordOverride(
          clientId: clientId,
          field: fFirstSetReps,
          value: afterFirst.reps,
        );
      }
      if (beforeFirst?.holdSeconds != afterFirst.holdSeconds) {
        recordOverride(
          clientId: clientId,
          field: fFirstSetHoldSeconds,
          value: afterFirst.holdSeconds,
        );
      }
      if (beforeFirst?.weightKg != afterFirst.weightKg) {
        recordOverride(
          clientId: clientId,
          field: fFirstSetWeightKg,
          value: afterFirst.weightKg,
        );
      }
      if (beforeFirst?.breatherSecondsAfter !=
          afterFirst.breatherSecondsAfter) {
        recordOverride(
          clientId: clientId,
          field: fFirstSetBreatherSeconds,
          value: afterFirst.breatherSecondsAfter,
        );
      }
    }
    // Wave 42 — body-focus fan-out. Toggling from the Studio pill
    // updates the client's sticky default so the next new capture
    // inherits the practitioner's latest choice.
    if (before.bodyFocus != after.bodyFocus) {
      recordOverride(
        clientId: clientId,
        field: fBodyFocus,
        value: after.bodyFocus,
      );
    }
  }

  // --- Coercion helpers -----------------------------------------------------
  // JSON round-trips ints through a double when the value crossed a JS
  // runtime (rare on supabase-flutter but safe to handle). Accept any
  // num and floor to int for the integer fields.

  static int? _asInt(Object? raw) {
    if (raw == null) return null;
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw);
    return null;
  }

  static double? _asDouble(Object? raw) {
    if (raw == null) return null;
    if (raw is double) return raw;
    if (raw is num) return raw.toDouble();
    if (raw is String) return double.tryParse(raw);
    return null;
  }

  static bool? _asBool(Object? raw) {
    if (raw == null) return null;
    if (raw is bool) return raw;
    if (raw is num) return raw != 0;
    if (raw is String) {
      if (raw == 'true') return true;
      if (raw == 'false') return false;
    }
    return null;
  }

  static Treatment? _asTreatment(Object? raw) {
    return treatmentFromWire(raw);
  }
}
