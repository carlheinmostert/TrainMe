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
  static void recordOverride({
    required String? clientId,
    required String field,
    required Object? value,
  }) {
    if (clientId == null || clientId.isEmpty) return;
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
