import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide Session;

import '../models/client.dart';

// =============================================================================
// ApiClient — single enumerated Supabase surface for the Flutter app.
//
// Seeded for the three-treatment feature. Agents should add their methods in
// distinct sections of this file to minimise merge collisions. Section map:
//   - Plan reads             (this agent)
//   - Client + consent       (this agent)
//   - Raw archive uploads    (agent B — `uploadRawArchive` etc., BOTTOM)
//
// Keeping this a singleton mirrors the patterns used by the existing
// AuthService / ConversionService.
// =============================================================================

class ApiClient {
  ApiClient._();

  static final ApiClient instance = ApiClient._();

  SupabaseClient get _supabase => Supabase.instance.client;

  // ---------------------------------------------------------------------------
  // Section: Plan reads
  // ---------------------------------------------------------------------------

  /// Fetch the server-side view of a plan via the `get_plan_full` RPC, then
  /// return the raw JSON map for the caller to merge into its local Session.
  ///
  /// The RPC is anonymous-friendly (used by the web player) but works for
  /// the signed-in practitioner too — it is the single entry point for
  /// reading plans post-publish. Returns null on any error (missing plan,
  /// RPC missing, RLS rejection) so callers can fall back to local state.
  ///
  /// Schema of the successful response (three-treatment slice):
  /// ```
  /// {
  ///   "plan": { ... },
  ///   "exercises": [
  ///     {
  ///       "id": "...",
  ///       "line_drawing_url": "https://.../line.mp4",   // always present
  ///       "grayscale_url":    "https://.../orig.mp4" | null,
  ///       "original_url":     "https://.../orig.mp4" | null,
  ///       ...
  ///     }
  ///   ]
  /// }
  /// ```
  Future<Map<String, dynamic>?> getPlanFull(String planId) async {
    try {
      final raw = await _supabase.rpc(
        'get_plan_full',
        params: {'p_plan_id': planId},
      );
      if (raw is Map) {
        return Map<String, dynamic>.from(raw);
      }
      return null;
    } catch (e) {
      debugPrint('ApiClient.getPlanFull failed for $planId: $e');
      return null;
    }
  }

  /// Pull just the `line_drawing_url` / `grayscale_url` / `original_url`
  /// triplet per exercise out of a [getPlanFull] response. Returns an empty
  /// map on any shape mismatch — callers fall back to local file playback.
  Map<String, ExerciseTreatmentUrls> treatmentUrlsFromPlanResponse(
    Map<String, dynamic>? response,
  ) {
    final out = <String, ExerciseTreatmentUrls>{};
    if (response == null) return out;
    final exercises = response['exercises'];
    if (exercises is! List) return out;
    for (final row in exercises) {
      if (row is! Map) continue;
      final id = row['id'];
      if (id is! String) continue;
      out[id] = ExerciseTreatmentUrls(
        lineDrawingUrl: _stringOrNull(row['line_drawing_url']),
        grayscaleUrl: _stringOrNull(row['grayscale_url']),
        originalUrl: _stringOrNull(row['original_url']),
      );
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // Section: Client + consent
  // ---------------------------------------------------------------------------

  /// List the clients belonging to a practice. Used by the Your-clients
  /// screen. Returns an empty list on any error so the UI can render an
  /// empty state rather than crash.
  Future<List<PracticeClient>> listPracticeClients(String practiceId) async {
    try {
      final raw = await _supabase.rpc(
        'list_practice_clients',
        params: {'p_practice_id': practiceId},
      );
      if (raw is! List) return const [];
      return raw
          .whereType<Map>()
          .map((m) => PracticeClient.fromJson(Map<String, dynamic>.from(m)))
          .toList(growable: false);
    } catch (e) {
      debugPrint('ApiClient.listPracticeClients failed: $e');
      return const [];
    }
  }

  /// Write the client's video-viewing preferences. [lineAllowed] is always
  /// true (line drawing is the platform baseline) and is passed for
  /// explicitness; the backend ignores it. Returns true on success.
  ///
  /// Failures are swallowed silently per the task brief (R-voice
  /// consent path fallback). The caller shows a neutral error if it
  /// needs to — we don't want the sheet to spew stack traces at the
  /// practitioner for a transient RPC miss.
  Future<bool> setClientVideoConsent({
    required String clientId,
    required bool lineAllowed,
    required bool grayscaleAllowed,
    required bool colourAllowed,
  }) async {
    try {
      await _supabase.rpc(
        'set_client_video_consent',
        params: {
          'p_client_id': clientId,
          'p_line': lineAllowed,
          'p_grayscale': grayscaleAllowed,
          'p_original': colourAllowed,
        },
      );
      return true;
    } catch (e) {
      debugPrint('ApiClient.setClientVideoConsent failed: $e');
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static String? _stringOrNull(dynamic v) {
    if (v is String && v.isNotEmpty) return v;
    return null;
  }
}

/// The three remote URLs the segmented control in the preview picks
/// between. Any of the three can be null — null means "not published yet"
/// (line) or "client hasn't said yes to this treatment" (grayscale /
/// original).
class ExerciseTreatmentUrls {
  final String? lineDrawingUrl;
  final String? grayscaleUrl;
  final String? originalUrl;

  const ExerciseTreatmentUrls({
    this.lineDrawingUrl,
    this.grayscaleUrl,
    this.originalUrl,
  });
}
