import 'package:flutter/foundation.dart';

import '../models/cached_client.dart';
import '../models/exercise_capture.dart';
import '../models/treatment.dart';
import 'client_defaults_api.dart';
import 'sync_service.dart';

/// Sticky per-client exercise defaults (Milestone R / Wave 8).
///
/// Two responsibilities:
///
///   1. **Pre-fill** — given a freshly-minted [ExerciseCapture] and a
///      [CachedClient], return a copy with the seven sticky fields
///      populated from the client's [CachedClient.clientExerciseDefaults].
///      Fields already non-null on the exercise are left alone (the
///      capture path seeds empty fields; pre-fill only).
///
///   2. **Write-back** — given a client id, a field key, and a value,
///      queue a local-first write of the new default through
///      [SyncService]. Called on every practitioner override in Studio
///      so the next new capture inherits the latest choice.
///
/// **Forward-only.** This module never reaches back into prior
/// captures. Editing reps on exercise N doesn't retroactively touch
/// exercise N-1; it only biases the NEXT new exercise.
///
/// **Invisible UX.** There is no UI surface — the practitioner sees
/// pre-filled fields and overrides write-back silently. Any debug
/// instrumentation stays behind [debugPrint].
///
/// **Wave 39 — in-memory overlay.** Wave 8 device-QA flagged that the
/// next exercise sometimes didn't inherit the practitioner's override
/// (specifically reps). The original implementation wrote to SQLite via
/// [SyncService.queueSetExerciseDefault] (an async pending-op queue
/// hop) and the next capture's prefill read from SQLite. If the
/// practitioner edited reps and immediately captured another exercise,
/// the SQLite write could lose the race. The fix is a static
/// `_memoryOverlay` per-client map that we update SYNCHRONOUSLY on
/// every override and consult FIRST during prefill — SQLite stays the
/// canonical store but the in-memory layer guarantees forward-only
/// propagation even mid-flight. Both layers stay consistent because
/// every `recordOverride` writes to both.
class StickyDefaults {
  StickyDefaults._();

  /// Wire field names (exposed for call sites that don't also want to
  /// import [ClientDefaultsApi]).
  static const String fReps = ClientDefaultsApi.fReps;
  static const String fSets = ClientDefaultsApi.fSets;
  static const String fHoldSeconds = ClientDefaultsApi.fHoldSeconds;
  static const String fIncludeAudio = ClientDefaultsApi.fIncludeAudio;
  static const String fPreferredTreatment =
      ClientDefaultsApi.fPreferredTreatment;
  static const String fPrepSeconds = ClientDefaultsApi.fPrepSeconds;
  static const String fCustomDurationSeconds =
      ClientDefaultsApi.fCustomDurationSeconds;

  /// Wave 39 — in-memory write-through overlay keyed by client id. Every
  /// [recordOverride] writes here SYNCHRONOUSLY (before the async pending-
  /// op queue starts spinning) so the next capture's [prefillCapture] sees
  /// the latest value even if SQLite hasn't flushed yet. Process-local —
  /// cleared on app restart, at which point SQLite (the canonical store)
  /// rehydrates the cache.
  static final Map<String, Map<String, Object?>> _memoryOverlay =
      <String, Map<String, Object?>>{};

  /// Prime the in-memory overlay from a freshly-loaded SQLite snapshot.
  /// Called by capture / studio screens just before a new-capture prefill
  /// so the overlay map starts coherent with the SQLite row. Skips when
  /// the overlay already has entries — the overlay always wins (it
  /// represents writes that may not have flushed yet).
  static void primeFromSnapshot(String clientId, Map<String, dynamic> snapshot) {
    if (clientId.isEmpty) return;
    if (snapshot.isEmpty) return;
    final overlay = _memoryOverlay[clientId];
    if (overlay == null) {
      _memoryOverlay[clientId] = Map<String, Object?>.from(snapshot);
      return;
    }
    // Existing overlay wins per-key; only add fields not already overlaid.
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

  /// Pre-fill [exercise] with the seven sticky fields from [defaults].
  ///
  /// Fields on [exercise] that are already non-null take precedence
  /// (the caller already had an intent). Rest periods are returned
  /// unchanged — reps / sets / etc. don't apply to rest.
  ///
  /// When [defaults] is empty (fresh client, no prior captures), the
  /// exercise is returned unchanged so the Studio card falls through
  /// to its hard-coded [StudioDefaults] seed values.
  static ExerciseCapture prefillCapture(
    ExerciseCapture exercise,
    Map<String, dynamic> defaults,
  ) {
    if (exercise.isRest) return exercise;
    if (defaults.isEmpty) return exercise;

    return exercise.copyWith(
      reps: exercise.reps ?? _asInt(defaults[fReps]),
      sets: exercise.sets ?? _asInt(defaults[fSets]),
      holdSeconds: exercise.holdSeconds ?? _asInt(defaults[fHoldSeconds]),
      includeAudio: _asBool(defaults[fIncludeAudio]) ?? exercise.includeAudio,
      preferredTreatment: exercise.preferredTreatment ??
          _asTreatment(defaults[fPreferredTreatment]),
      prepSeconds: exercise.prepSeconds ?? _asInt(defaults[fPrepSeconds]),
      customDurationSeconds: exercise.customDurationSeconds ??
          _asInt(defaults[fCustomDurationSeconds]),
    );
  }

  /// Fire-and-forget: write a single override back into the client's
  /// sticky defaults. Silent on success or failure — never blocks UX.
  ///
  /// [clientId] may be null for legacy sessions missing a [Session.clientId];
  /// in that case we simply skip (nothing to update, forward-only from
  /// here).
  ///
  /// Wave 39 — writes to the in-memory [_memoryOverlay] FIRST (synchronous),
  /// then queues the persistent write through [SyncService]. This way a
  /// rapid edit-then-capture sequence sees the latest value via
  /// [effectiveDefaults] even if the SQLite write lost the race.
  static void recordOverride({
    required String? clientId,
    required String field,
    required Object? value,
  }) {
    if (clientId == null || clientId.isEmpty) return;
    // Synchronous in-memory write-through. Always lands before the next
    // prefill, regardless of how the async queue completes.
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

  /// Record the whole `reps / sets / hold / customDuration` quartet in
  /// one go — used by the Studio card's [_pushUpdate] which edits that
  /// block as a group. Each field is independently queued; individual
  /// failures don't cascade.
  static void recordStudioSliderGroup({
    required String? clientId,
    required ExerciseCapture before,
    required ExerciseCapture after,
  }) {
    if (clientId == null || clientId.isEmpty) return;
    if (before.reps != after.reps) {
      recordOverride(
        clientId: clientId,
        field: fReps,
        value: after.reps,
      );
    }
    if (before.sets != after.sets) {
      recordOverride(
        clientId: clientId,
        field: fSets,
        value: after.sets,
      );
    }
    if (before.holdSeconds != after.holdSeconds) {
      recordOverride(
        clientId: clientId,
        field: fHoldSeconds,
        value: after.holdSeconds,
      );
    }
    if (before.customDurationSeconds != after.customDurationSeconds) {
      recordOverride(
        clientId: clientId,
        field: fCustomDurationSeconds,
        value: after.customDurationSeconds,
      );
    }
  }

  /// Compare any two exercise snapshots and queue every sticky-field
  /// delta. Callers that don't know which field changed (e.g. the
  /// Studio card's generic `onUpdate` tap) use this to fan out.
  static void recordAllDeltas({
    required String? clientId,
    required ExerciseCapture before,
    required ExerciseCapture after,
  }) {
    if (clientId == null || clientId.isEmpty) return;
    if (before.reps != after.reps) {
      recordOverride(clientId: clientId, field: fReps, value: after.reps);
    }
    if (before.sets != after.sets) {
      recordOverride(clientId: clientId, field: fSets, value: after.sets);
    }
    if (before.holdSeconds != after.holdSeconds) {
      recordOverride(
        clientId: clientId,
        field: fHoldSeconds,
        value: after.holdSeconds,
      );
    }
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
    if (before.customDurationSeconds != after.customDurationSeconds) {
      recordOverride(
        clientId: clientId,
        field: fCustomDurationSeconds,
        value: after.customDurationSeconds,
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
