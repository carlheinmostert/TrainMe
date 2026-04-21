import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Thin RPC wrapper for the sticky per-client exercise defaults
/// (Milestone R / Wave 8).
///
/// This is a separate seam from [ApiClient] only because that file is
/// owned by a parallel PR stream at the time Wave 8 was written (see
/// `docs/BACKLOG.md`). Once Wave 5 lands, these methods can be folded
/// into [ApiClient] with no behavioural change — the wire contract
/// stays the same.
///
/// Contract mirrors `supabase/schema_milestone_r_sticky_defaults.sql`:
///
///   set_client_exercise_default(p_client_id, p_field, p_value JSONB) -> void
///
/// Seven permitted field keys (Wire constants below):
///   reps, sets, hold_seconds, include_audio, preferred_treatment,
///   prep_seconds, custom_duration_seconds.
class ClientDefaultsApi {
  ClientDefaultsApi._();

  static final ClientDefaultsApi instance = ClientDefaultsApi._();

  /// Wire field names — canonical source of truth. Both the Flutter
  /// pre-fill logic and the Supabase RPC speak this vocabulary.
  static const String fReps = 'reps';
  static const String fSets = 'sets';
  static const String fHoldSeconds = 'hold_seconds';
  static const String fIncludeAudio = 'include_audio';
  static const String fPreferredTreatment = 'preferred_treatment';
  static const String fPrepSeconds = 'prep_seconds';
  static const String fCustomDurationSeconds = 'custom_duration_seconds';

  /// The full set of fields considered "sticky" for new-capture
  /// pre-fill. Used by the propagation layer to walk every field once.
  static const List<String> allFields = <String>[
    fReps,
    fSets,
    fHoldSeconds,
    fIncludeAudio,
    fPreferredTreatment,
    fPrepSeconds,
    fCustomDurationSeconds,
  ];

  SupabaseClient get _raw => Supabase.instance.client;

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
    await _raw.rpc(
      'set_client_exercise_default',
      params: <String, dynamic>{
        'p_client_id': clientId,
        'p_field': field,
        'p_value': value,
      },
    );
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
  /// `client_exercise_defaults` key (Milestone R / Wave 8).
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
    final result = await _raw.rpc(
      'list_practice_clients',
      params: <String, dynamic>{'p_practice_id': practiceId},
    );
    if (result is! List) return const <Map<String, dynamic>>[];
    return result
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList(growable: false);
  }
}
