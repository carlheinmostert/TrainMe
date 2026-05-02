import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'api_client.dart';

/// Thin RPC wrapper for the sticky per-client exercise defaults
/// (Milestone R / Wave 8).
///
/// This is a separate seam from [ApiClient] only because that file is
/// owned by a parallel PR stream. Once that lands, these methods can be
/// folded into [ApiClient] with no behavioural change — the wire
/// contract stays the same.
///
/// RPC calls here route through [ApiClient.guardAuth] so a revoked
/// server-side session fires [ApiClient.sessionExpired] the same way
/// every other RPC does.
///
/// Contract:
///
///   set_client_exercise_default(p_client_id, p_field, p_value JSONB) -> void
///
/// **Per-set PLAN wave** (Wave: per-set PLAN relational model) — the
/// legacy field set (`reps`, `sets`, `hold_seconds`,
/// `inter_set_rest_seconds`, `custom_duration_seconds`) was retired
/// when the database moved to the per-set [exercise_sets] child table.
/// The cloud-side migration scrubbed those keys from
/// `clients.client_exercise_defaults`; the SQLite v33 migration mirrors
/// that scrub for the local cache.
///
/// **Surviving sticky keys:**
///
///   * include_audio                — bool
///   * preferred_treatment          — String ('line'|'grayscale'|'original')
///   * prep_seconds                 — int
///   * video_reps_per_loop          — int (Wave 24)
///
/// **New per-set sticky keys** (the PLAN wave introduced these so the
/// most-recent first-set values still forward-propagate to the next
/// new capture for the same client):
///
///   * first_set_reps               — int
///   * first_set_hold_seconds       — int
///   * first_set_weight_kg          — num | null
///   * first_set_breather_seconds   — int
///
/// The `set_client_exercise_default` RPC writes any key into the
/// `client_exercise_defaults` JSONB column; no schema change required
/// for the new keys.
class ClientDefaultsApi {
  ClientDefaultsApi._();

  static final ClientDefaultsApi instance = ClientDefaultsApi._();

  /// Wire field names — canonical source of truth. Both the Flutter
  /// pre-fill logic and the Supabase RPC speak this vocabulary.
  static const String fIncludeAudio = 'include_audio';
  static const String fPreferredTreatment = 'preferred_treatment';
  static const String fPrepSeconds = 'prep_seconds';
  static const String fVideoRepsPerLoop = 'video_reps_per_loop';

  /// Per-set first-set sticky seeds. The next new capture's first set
  /// inherits these values. Practitioner overrides on the PLAN table
  /// editor write back the new value here. Nullable values
  /// (`first_set_weight_kg`) round-trip through JSON as `null` when the
  /// practitioner explicitly cleared a previously-set weight.
  static const String fFirstSetReps = 'first_set_reps';
  static const String fFirstSetHoldSeconds = 'first_set_hold_seconds';
  static const String fFirstSetWeightKg = 'first_set_weight_kg';
  static const String fFirstSetBreatherSeconds = 'first_set_breather_seconds';

  // Wave 42 — per-exercise practitioner body-focus default.
  static const String fBodyFocus = 'body_focus';

  /// The full set of fields considered "sticky" for new-capture
  /// pre-fill. Used by the propagation layer to walk every field once.
  static const List<String> allFields = <String>[
    fIncludeAudio,
    fPreferredTreatment,
    fPrepSeconds,
    fVideoRepsPerLoop,
    fFirstSetReps,
    fFirstSetHoldSeconds,
    fFirstSetWeightKg,
    fFirstSetBreatherSeconds,
    fBodyFocus,
  ];

  SupabaseClient get _raw => ApiClient.instance.raw;

  /// Writes a single default field for [clientId]. Throws on network /
  /// auth / membership failure — callers either recover via the
  /// pending-op queue (SyncService) or swallow with a debugPrint for a
  /// best-effort optimistic write.
  ///
  /// [value] must be JSON-encodable (bool, num, String, null).
  Future<void> setClientExerciseDefault({
    required String clientId,
    required String field,
    required Object? value,
  }) async {
    await ApiClient.instance.guardAuth(() => _raw.rpc(
          'set_client_exercise_default',
          params: <String, dynamic>{
            'p_client_id': clientId,
            'p_field': field,
            'p_value': value,
          },
        ));
  }

  /// Best-effort variant — swallows errors with a debug log. Used by
  /// the Studio card's override path when we want to fire-and-forget
  /// without blocking UX; SyncService is the fallback path that
  /// guarantees durability.
  Future<bool> trySetClientExerciseDefault({
    required String clientId,
    required String field,
    required Object? value,
  }) async {
    try {
      await setClientExerciseDefault(
        clientId: clientId,
        field: field,
        value: value,
      );
      return true;
    } catch (e) {
      debugPrint('ClientDefaultsApi.setClientExerciseDefault failed: $e');
      return false;
    }
  }

  /// Fetch the raw `list_practice_clients` payload including the new
  /// `client_exercise_defaults` key.
  ///
  /// SyncService uses this to hydrate the SQLite cache with defaults
  /// without having to flow through the typed [PracticeClient] model
  /// (which is owned by a parallel PR stream and intentionally left
  /// untouched here).
  ///
  /// Returns the raw list of maps exactly as the RPC returned them.
  /// Callers use [CachedClient.fromCloudJson] to decode.
  Future<List<Map<String, dynamic>>> listPracticeClientsRaw(
    String practiceId,
  ) async {
    final result = await ApiClient.instance.guardAuth(() => _raw.rpc(
          'list_practice_clients',
          params: <String, dynamic>{'p_practice_id': practiceId},
        ));
    if (result is! List) return const <Map<String, dynamic>>[];
    return result
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList(growable: false);
  }
}
