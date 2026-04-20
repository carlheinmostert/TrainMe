import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/client.dart';

/// The ONE file that enumerates every Supabase operation the Flutter surface
/// is allowed to perform. Other services (`auth_service.dart`,
/// `upload_service.dart`) MUST go through this class — direct
/// `Supabase.instance.client.rpc(...)`, `.from(...)`, or `.storage` calls
/// elsewhere in `app/lib/` are a layering violation (see
/// `docs/DATA_ACCESS_LAYER.md`).
///
/// The goal is not abstraction for its own sake. It's:
///   1. A single inventory of operations the app can perform, so additions
///      / renames / removals are trivially reviewable in one diff.
///   2. A single place to match against RPC parameter names (the root cause
///      of the `plan_id` → `p_plan_id` silent break on 2026-04-18).
///   3. A single seam to stub in tests when they land.
///
/// ## Conventions
///
/// * Every RPC method is named identically to its SQL fn (camelCased). The
///   parameter list mirrors the SQL signature's `p_*` names minus the prefix.
/// * Every method returns a strongly-typed Dart value (bool / int / Map),
///   not the raw `dynamic` from `supabase.rpc`. Call sites are free from
///   type guards.
/// * Free-form `auth`, `auth.onAuthStateChange`, `.auth.currentSession`,
///   `.auth.currentUser` pass-throughs stay here too — they're the
///   Supabase-native observation surface and have no RPC equivalent.
/// * Storage operations are exposed via [uploadMedia] / [removeMedia] /
///   [publicMediaUrl]. The `media` bucket is the only bucket the app
///   touches; if that changes, broaden here first.
///
/// ## NOT in this file
///
/// * The local SQLite layer (`local_storage_service.dart`) — that's the
///   offline-first store, orthogonal to the network path.
/// * Edge Functions (`payfast-webhook`) — they run server-side, not from
///   the mobile app.
/// * Any business logic. This class is a thin, typed IO boundary. Logic
///   like "consume credit then upsert the version" belongs in
///   `upload_service.dart`; we just expose the primitives it composes.
class ApiClient {
  ApiClient._();

  /// Singleton. The Supabase client itself is a singleton, so wrapping it
  /// as a singleton here is lossless and lets call sites stay short.
  static final ApiClient instance = ApiClient._();

  /// Canonical storage bucket for exercise media. Every storage call in the
  /// app routes through this bucket; if the name ever changes, change it
  /// here.
  static const String mediaBucket = 'media';

  /// Private storage bucket for the raw 720p H.264 archive. Uploads are
  /// scoped by practice membership via `can_write_to_raw_archive(path)`;
  /// reads are service-role only (web player gets signed URLs embedded in
  /// `get_plan_full` when client consent grants grayscale/original).
  /// Created by the three-treatment backend migration.
  static const String rawArchiveBucket = 'raw-archive';

  /// Raw Supabase client. Only exposed for two carve-outs that currently
  /// have no clean replacement:
  ///
  ///   * Native OAuth flows (Google / Apple) that call
  ///     [GoTrueClient.signInWithIdToken] with provider-specific tokens.
  ///     Wrapping would add no value.
  ///   * `onAuthStateChange` stream subscription used by the AuthGate.
  ///
  /// New call sites should prefer the typed methods below.
  SupabaseClient get raw => Supabase.instance.client;

  /// Convenience: the signed-in user's uuid, or null.
  String? get currentUserId => raw.auth.currentUser?.id;

  /// Convenience: the signed-in user's email, or null.
  String? get currentUserEmail => raw.auth.currentUser?.email;

  /// Current Supabase session snapshot (null = signed out).
  Session? get currentSession => raw.auth.currentSession;

  /// Auth state stream. Emits the session on every state change.
  Stream<Session?> get authStateChanges =>
      raw.auth.onAuthStateChange.map((e) => e.session);

  // ==========================================================================
  // Auth — email + password + magic link
  // ==========================================================================

  /// Send a one-time magic link for passwordless sign-in.
  ///
  /// Wraps `supabase.auth.signInWithOtp`. Caller supplies the deep-link
  /// redirect URL — we don't pull it from config because AppConfig is a
  /// UI-layer concern and this class stays reusable from test harnesses.
  Future<void> sendMagicLink({
    required String email,
    required String emailRedirectTo,
    bool shouldCreateUser = true,
  }) async {
    await raw.auth.signInWithOtp(
      email: email,
      emailRedirectTo: emailRedirectTo,
      shouldCreateUser: shouldCreateUser,
    );
  }

  /// Sign in with id_token from a native provider (Google / Apple).
  ///
  /// Direct pass-through to `supabase.auth.signInWithIdToken`. Kept here
  /// so the auth flow lives in this inventory even when we reactivate the
  /// Google path (currently parked — see `docs/BACKLOG_GOOGLE_SIGNIN.md`).
  Future<AuthResponse> signInWithIdToken({
    required OAuthProvider provider,
    required String idToken,
    String? accessToken,
  }) async {
    return raw.auth.signInWithIdToken(
      provider: provider,
      idToken: idToken,
      accessToken: accessToken,
    );
  }

  /// Email + password sign-in. Wraps `supabase.auth.signInWithPassword`.
  /// Raises `AuthException` on invalid credentials; caller owns the
  /// fallthrough to magic-link.
  Future<AuthResponse> signInWithPassword({
    required String email,
    required String password,
  }) async {
    return raw.auth.signInWithPassword(email: email, password: password);
  }

  /// End the current session.
  Future<void> signOut() async {
    await raw.auth.signOut();
  }

  // ==========================================================================
  // RPCs — Milestone A/C/E
  // ==========================================================================

  /// `bootstrap_practice_for_user()` — SECURITY DEFINER RPC that either
  /// (a) returns the caller's existing practice, (b) claims the Carl-
  /// sentinel practice, or (c) creates a fresh personal practice + owner
  /// membership + 5-credit welcome bonus. Idempotent; safe to call on
  /// every `onAuthStateChange` event.
  ///
  /// Returns the practice id (uuid as string). Raises `AuthException`
  /// from the underlying client on DB errors — callers own the try/catch.
  Future<String?> bootstrapPracticeForUser() async {
    final result = await raw.rpc('bootstrap_practice_for_user');
    if (result == null) return null;
    return result is String ? result : result.toString();
  }

  /// List the practices the signed-in user is a member of.
  ///
  /// Mirrors the portal's `PortalApi.listMyPractices()`. Ordered by
  /// `joined_at` so [0] is the first practice the user joined (the
  /// Carl-sentinel / bootstrap one).
  ///
  /// Explicitly filters by `trainer_id = auth.uid()` — the
  /// practice_members RLS policy is broader than "your own rows": it
  /// allows SELECT on all members of any practice you belong to (needed
  /// for the members page). Without this filter a user who's in a
  /// shared practice sees their peer's membership rows too, producing
  /// phantom entries in the switcher.
  ///
  /// Returns `[]` on any error so UI can render a shell without crashing.
  Future<List<PracticeMembership>> listMyPractices() async {
    try {
      final userId = raw.auth.currentUser?.id;
      if (userId == null) return const [];
      final response = await raw
          .from('practice_members')
          .select('role, practice_id, practices:practice_id ( id, name )')
          .eq('trainer_id', userId)
          .order('joined_at', ascending: true);
      if (response is! List) return const [];
      return response
          .whereType<Map>()
          .map((r) {
            final practiceRaw = r['practices'];
            final practice = practiceRaw is List
                ? (practiceRaw.isNotEmpty ? practiceRaw.first : null)
                : practiceRaw;
            if (practice is! Map) return null;
            final id = practice['id'];
            final name = practice['name'];
            if (id is! String || name is! String) return null;
            final role = r['role'] is String ? r['role'] as String : 'practitioner';
            return PracticeMembership(
              id: id,
              name: name,
              role: role == 'owner' ? PracticeRole.owner : PracticeRole.practitioner,
            );
          })
          .whereType<PracticeMembership>()
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  /// `practice_credit_balance(p_practice_id)` — SECURITY DEFINER fn that
  /// returns `SUM(delta)` over `credit_ledger` rows for the practice.
  ///
  /// Returns null when the call errors (network hiccup / RLS rejection /
  /// fn missing). The caller decides whether a null falls through to a
  /// retry or to a soft-fail. Never coerces null to zero — a transient
  /// error should NOT be mistaken for "you're out of credits".
  Future<int?> practiceCreditBalance({required String practiceId}) async {
    try {
      final result = await raw.rpc(
        'practice_credit_balance',
        params: {'p_practice_id': practiceId},
      );
      if (result is int) return result;
      if (result is num) return result.toInt();
      if (result is String) return int.tryParse(result);
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Fetch the `plans.client_id` mapping for every plan in this practice
  /// that's been linked to a client. Used by HomeScreen to backfill local
  /// SQLite `sessions.client_id` (which was null for pre-v16 sessions —
  /// the migration didn't backfill). RLS allows authenticated practice
  /// members to SELECT their own practice's plans, so this direct read
  /// is safe.
  ///
  /// Returns `[]` on any error so callers render the shell without
  /// crashing; backfill is purely an optimisation — the name-match
  /// fallback in the filter keeps sessions visible when the sync fails.
  Future<List<PlanClientLink>> listPlanClientLinks(String practiceId) async {
    try {
      final result = await raw
          .from('plans')
          .select('id, client_id')
          .eq('practice_id', practiceId)
          .not('client_id', 'is', null);
      if (result is! List) return const [];
      return result
          .whereType<Map>()
          .map((r) {
            final id = r['id'];
            final clientId = r['client_id'];
            if (id is! String || clientId is! String) return null;
            return PlanClientLink(planId: id, clientId: clientId);
          })
          .whereType<PlanClientLink>()
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  /// `consume_credit(p_practice_id, p_plan_id, p_credits)` — atomic credit
  /// burn. Returns the RPC's jsonb response as a `Map<String, dynamic>`:
  ///
  ///   * on success: `{ok: true, new_balance: N}`
  ///   * on insufficient funds: `{ok: false, reason: 'insufficient_credits',
  ///     balance: N}`
  ///
  /// Raises on membership / auth / network failures; caller handles.
  /// Empty map on a malformed RPC response so callers can rely on
  /// `result['ok'] == true` without null-guarding every field.
  Future<Map<String, dynamic>> consumeCredit({
    required String practiceId,
    required String planId,
    required int credits,
  }) async {
    final result = await raw.rpc(
      'consume_credit',
      params: {
        'p_practice_id': practiceId,
        'p_plan_id': planId,
        'p_credits': credits,
      },
    );
    return result is Map
        ? Map<String, dynamic>.from(result)
        : const <String, dynamic>{};
  }

  /// `refund_credit(p_plan_id)` — idempotent compensating refund. Best-
  /// effort: swallows errors (retry logic would risk stacking refund rows
  /// under partial-success scenarios). Returns `true` when a ledger row
  /// was written, `false` when the call was a no-op (already refunded, no
  /// matching consumption, or any swallowed error).
  Future<bool> refundCredit({required String planId}) async {
    try {
      final result = await raw.rpc(
        'refund_credit',
        params: {'p_plan_id': planId},
      );
      return result == true;
    } catch (_) {
      return false;
    }
  }

  // ==========================================================================
  // Table CRUD — plans, exercises, plan_issuances
  // ==========================================================================
  //
  // These are thin wrappers around `.from(table).upsert/delete/insert`. We
  // accept raw Map<String, dynamic> payloads for now; strongly-typed DTOs
  // live in `app/lib/models/` and are converted at the call site. A future
  // pass can push the typed row shapes into this file if discipline slips.

  /// Upsert a plan row. Used both for the pre-consume FK-satisfying upsert
  /// (without the version bump) and the post-consume version bump. The
  /// caller owns the row shape so this class stays agnostic to schema
  /// migrations.
  Future<void> upsertPlan(Map<String, dynamic> row) async {
    await raw.from('plans').upsert(row);
  }

  /// Upsert a batch of exercise rows.
  Future<void> upsertExercises(List<Map<String, dynamic>> rows) async {
    if (rows.isEmpty) return;
    await raw.from('exercises').upsert(rows);
  }

  /// Delete exercise rows for a plan that are NOT in [keepIds]. If
  /// [keepIds] is empty, deletes every exercise for the plan.
  Future<void> deleteStaleExercises({
    required String planId,
    required List<String> keepIds,
  }) async {
    var q = raw.from('exercises').delete().eq('plan_id', planId);
    if (keepIds.isNotEmpty) {
      q = q.not('id', 'in', keepIds);
    }
    await q;
  }

  /// Append a plan_issuances audit row. Best-effort from the caller's
  /// perspective — this method raises on failure but upload_service
  /// swallows it (see the comment there; the ledger is already the
  /// source of truth for billing).
  Future<void> insertPlanIssuance(Map<String, dynamic> row) async {
    await raw.from('plan_issuances').insert(row);
  }

  // ==========================================================================
  // Storage — media bucket
  // ==========================================================================

  /// Upload a file to the media bucket at [path]. Uses upsert semantics so
  /// re-publishes overwrite the existing object at the same path.
  Future<void> uploadMedia({
    required String path,
    required File file,
  }) async {
    await raw.storage.from(mediaBucket).upload(
          path,
          file,
          fileOptions: const FileOptions(upsert: true),
        );
  }

  /// Return the public URL for an object at [path] in the media bucket.
  /// Non-async — the client computes this locally.
  String publicMediaUrl({required String path}) {
    return raw.storage.from(mediaBucket).getPublicUrl(path);
  }

  /// Remove a batch of objects from the media bucket. Used on publish
  /// failure to clean up orphaned uploads. Raises on failure; caller is
  /// expected to wrap in try/catch and swallow (cleanup must not mask
  /// the original error).
  Future<void> removeMedia({required List<String> paths}) async {
    if (paths.isEmpty) return;
    await raw.storage.from(mediaBucket).remove(paths);
  }

  // ==========================================================================
  // Plan reads — three-treatment (Milestone G)
  // ==========================================================================

  /// Fetch the server-side view of a plan via the `get_plan_full` RPC.
  /// Returns the raw JSON map (or null on any error). The response shape
  /// carries the three-treatment URLs per exercise:
  ///
  /// ```
  /// {
  ///   "plan": { ... },
  ///   "exercises": [
  ///     {
  ///       "id": "...",
  ///       "line_drawing_url": "https://.../line.mp4",   // always
  ///       "grayscale_url":    "https://.../orig.mp4" | null,
  ///       "original_url":     "https://.../orig.mp4" | null,
  ///       ...
  ///     }
  ///   ]
  /// }
  /// ```
  Future<Map<String, dynamic>?> getPlanFull(String planId) async {
    try {
      final result = await raw.rpc(
        'get_plan_full',
        params: {'p_plan_id': planId},
      );
      if (result is Map) return Map<String, dynamic>.from(result);
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

  // ==========================================================================
  // Clients + consent — three-treatment (Milestone G)
  // ==========================================================================

  /// `upsert_client(p_practice_id, p_name)` — idempotent lookup-or-create.
  /// Returns the client id (uuid). Used by the publish path so existing
  /// plans with `clientName` free-text become linked to a `clients` row.
  Future<String?> upsertClient({
    required String practiceId,
    required String name,
  }) async {
    try {
      final result = await raw.rpc(
        'upsert_client',
        params: {'p_practice_id': practiceId, 'p_name': name},
      );
      if (result is String && result.isNotEmpty) return result;
      return null;
    } catch (e) {
      debugPrint('ApiClient.upsertClient failed: $e');
      return null;
    }
  }

  /// `upsert_client_with_id(p_id, p_practice_id, p_name)` — offline-first
  /// variant of [upsertClient]. Caller supplies a client-generated uuid
  /// so the row persisted locally BEFORE contact with the cloud can
  /// survive the sync round-trip without the UI having to re-address
  /// anything.
  ///
  /// Three return shapes (see milestone-K migration):
  ///   1. Fresh insert — returns the caller's [clientId] unchanged.
  ///   2. Idempotent replay (row with this id already exists) — returns
  ///      [clientId] unchanged.
  ///   3. Name conflict — returns the id of the OTHER row in this
  ///      practice that already uses [name]. Caller (SyncService) is
  ///      expected to detect `returnedId != clientId` and rewire local
  ///      references from [clientId] to the returned id.
  ///
  /// Throws on network / membership / auth failures. Caller owns the
  /// try/catch; SyncService treats most errors as retryable but surfaces
  /// unrecoverable SQLSTATEs (42501 / P0002) via `PendingOp.attempts`.
  Future<String?> upsertClientWithId({
    required String clientId,
    required String practiceId,
    required String name,
  }) async {
    final result = await raw.rpc(
      'upsert_client_with_id',
      params: {
        'p_id': clientId,
        'p_practice_id': practiceId,
        'p_name': name,
      },
    );
    if (result is String && result.isNotEmpty) return result;
    return null;
  }

  /// `rename_client(p_client_id, p_new_name)` — mirrors the portal's
  /// `PortalApi.renameClient`. Raises a typed [RenameClientError] so
  /// callers (editable client name header on [ClientSessionsScreen])
  /// can surface specific inline messages:
  ///
  /// * `duplicate` (PostgreSQL 23505) — another client in the practice
  ///   already uses the target name.
  /// * `notFound` (P0002) — client id doesn't exist.
  /// * `notMember` (42501) — caller isn't a member of the client's
  ///   practice.
  /// * `empty` (22023) — blank name. Caller typically validates client-
  ///   side first, but the RPC enforces it server-side too.
  ///
  /// Any other [PostgrestException] surfaces as an [Exception] with the
  /// server message so the caller doesn't lose signal on unanticipated
  /// failures.
  Future<void> renameClient({
    required String clientId,
    required String newName,
  }) async {
    try {
      await raw.rpc(
        'rename_client',
        params: {'p_client_id': clientId, 'p_new_name': newName},
      );
    } on PostgrestException catch (e) {
      switch (e.code) {
        case '23505':
          throw const RenameClientError(RenameClientErrorKind.duplicate);
        case 'P0002':
          throw const RenameClientError(RenameClientErrorKind.notFound);
        case '42501':
          throw const RenameClientError(RenameClientErrorKind.notMember);
        case '22023':
          throw const RenameClientError(RenameClientErrorKind.empty);
        default:
          rethrow;
      }
    }
  }

  /// List the clients belonging to a practice. Used by the Your-clients
  /// screen. Returns an empty list on any error so the UI can render an
  /// empty state rather than crash.
  Future<List<PracticeClient>> listPracticeClients(String practiceId) async {
    try {
      final result = await raw.rpc(
        'list_practice_clients',
        params: {'p_practice_id': practiceId},
      );
      if (result is! List) return const [];
      return result
          .whereType<Map>()
          .map((m) => PracticeClient.fromJson(Map<String, dynamic>.from(m)))
          .toList(growable: false);
    } catch (e) {
      debugPrint('ApiClient.listPracticeClients failed: $e');
      return const [];
    }
  }

  /// Write the client's video-viewing preferences.
  ///
  /// `lineAllowed` is always true (line drawing de-identifies the client
  /// and is the platform baseline). Passed for explicitness; backend
  /// validates + preserves it. Returns true on success.
  ///
  /// Failures are swallowed silently per R-voice fallback — the caller
  /// shows a neutral error if needed.
  Future<bool> setClientVideoConsent({
    required String clientId,
    required bool lineAllowed,
    required bool grayscaleAllowed,
    required bool colourAllowed,
  }) async {
    try {
      await raw.rpc(
        'set_client_video_consent',
        params: {
          'p_client_id': clientId,
          'p_line_drawing': lineAllowed,
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

  // ==========================================================================
  // Storage — raw-archive bucket (private)
  // ==========================================================================

  /// Upload a file to the private `raw-archive` bucket at [path]. Path
  /// shape is `{practice_id}/{plan_id}/{exercise_id}.mp4`. Uses upsert so
  /// a re-publish overwrites the existing object at the same path.
  ///
  /// The bucket is PRIVATE — the web player never reads this directly;
  /// it gets time-limited signed URLs via the `get_plan_full` RPC when
  /// client consent grants grayscale or original treatments.
  ///
  /// Best-effort from the caller's perspective: if the bucket doesn't
  /// exist (pre-migration) or the RLS check fails, this throws and the
  /// caller is expected to swallow (see `UploadService._uploadRawArchives`).
  Future<void> uploadRawArchive({
    required String path,
    required File file,
  }) async {
    await raw.storage.from(rawArchiveBucket).upload(
          path,
          file,
          fileOptions: const FileOptions(upsert: true),
        );
  }

  // ---------------------------------------------------------------------------
  // Referral
  // ---------------------------------------------------------------------------

  /// Fetch (or create) the referral code for [practiceId].
  ///
  /// Wraps the `generate_referral_code` RPC. Idempotent — calling it
  /// repeatedly for the same practice returns the same code, so the
  /// client can call this on every Settings → Network render without
  /// worrying about collisions.
  ///
  /// Throws if the RPC fails or returns a non-string payload; callers
  /// are expected to handle errors and retry (e.g. the
  /// "Couldn't load — tap to retry" row in Settings).
  Future<String> ensureReferralCode(String practiceId) async {
    final result = await raw.rpc(
      'generate_referral_code',
      params: {'p_practice_id': practiceId},
    );
    if (result is String && result.isNotEmpty) return result;
    if (result is List && result.isNotEmpty) {
      final first = result.first;
      if (first is String && first.isNotEmpty) return first;
      if (first is Map && first['generate_referral_code'] is String) {
        return first['generate_referral_code'] as String;
      }
    }
    throw StateError(
      'generate_referral_code returned unexpected payload: $result',
    );
  }

  /// Fetch aggregate referral stats for [practiceId].
  ///
  /// Wraps the `referral_dashboard_stats` RPC which returns a single row
  /// with four numeric columns. PostgREST returns this either as a bare
  /// Map or a List-of-one-Map depending on the RPC return semantics; we
  /// tolerate both shapes.
  Future<ReferralStats> getReferralStats(String practiceId) async {
    final result = await raw.rpc(
      'referral_dashboard_stats',
      params: {'p_practice_id': practiceId},
    );
    Map<String, dynamic>? row;
    if (result is Map<String, dynamic>) {
      row = result;
    } else if (result is List && result.isNotEmpty) {
      final first = result.first;
      if (first is Map<String, dynamic>) row = first;
    }
    if (row == null) {
      throw StateError('referral_dashboard_stats returned no row');
    }
    return ReferralStats.fromJson(row);
  }
}

/// Aggregate stats for a practice's referral network.
///
/// Mirrors the four columns returned by the `referral_dashboard_stats`
/// RPC. Lives alongside [ApiClient] rather than in a generic models
/// folder because it's API-surface-specific — the RPC is the schema.
@immutable
class ReferralStats {
  final num rebateBalanceCredits;
  final num lifetimeRebateCredits;
  final int refereeCount;
  final num qualifyingSpendTotalZar;

  const ReferralStats({
    required this.rebateBalanceCredits,
    required this.lifetimeRebateCredits,
    required this.refereeCount,
    required this.qualifyingSpendTotalZar,
  });

  /// Safe constructor for "no data yet" states so callers can render the
  /// shell without a null-check everywhere. Not used for error states —
  /// error states surface as a thrown exception from [ApiClient].
  static const empty = ReferralStats(
    rebateBalanceCredits: 0,
    lifetimeRebateCredits: 0,
    refereeCount: 0,
    qualifyingSpendTotalZar: 0,
  );

  factory ReferralStats.fromJson(Map<String, dynamic> json) {
    num asNum(dynamic v) {
      if (v is num) return v;
      if (v is String) return num.tryParse(v) ?? 0;
      return 0;
    }

    int asInt(dynamic v) {
      if (v is int) return v;
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v) ?? 0;
      return 0;
    }

    return ReferralStats(
      rebateBalanceCredits: asNum(json['rebate_balance_credits']),
      lifetimeRebateCredits: asNum(json['lifetime_rebate_credits']),
      refereeCount: asInt(json['referee_count']),
      qualifyingSpendTotalZar: asNum(json['qualifying_spend_total_zar']),
    );
  }
}

/// Private helper used by [ApiClient] three-treatment parsing. Kept here
/// (module-scope) so it doesn't collide with any file-private `_stringOrNull`
/// in callers.
String? _stringOrNull(dynamic v) {
  if (v is String && v.isNotEmpty) return v;
  return null;
}

/// The three remote URLs the segmented control picks between. Any of the
/// three can be null:
///   - `lineDrawingUrl` null: not published yet (or plan pre-dates the
///     three-treatment migration). Callers fall back to the local
///     converted file if available.
///   - `grayscaleUrl` null: client hasn't granted grayscale consent.
///   - `originalUrl` null: client hasn't granted original-colour consent.
@immutable
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

/// Categorised failure from [ApiClient.renameClient]. Maps 1:1 to the
/// portal's `RenameClientError` so mobile + portal surface identical
/// messaging to the practitioner (R-11 twin).
enum RenameClientErrorKind { duplicate, notFound, notMember, empty }

/// Thrown by [ApiClient.renameClient] when the RPC raises a known
/// SQLSTATE. Carries the [kind] so the caller can pick the matching
/// inline message without parsing server strings.
@immutable
class RenameClientError implements Exception {
  final RenameClientErrorKind kind;

  const RenameClientError(this.kind);

  @override
  String toString() => 'RenameClientError(${kind.name})';
}

/// Role within a practice. Owners can invite members + buy credits;
/// practitioners consume credits to publish. Mirrors the portal's
/// `PracticeWithRole.role` shape.
enum PracticeRole { owner, practitioner }

/// One membership row: the practice id + its display name + the caller's
/// role in it. Returned by [ApiClient.listMyPractices].
@immutable
class PracticeMembership {
  final String id;
  final String name;
  final PracticeRole role;

  const PracticeMembership({
    required this.id,
    required this.name,
    required this.role,
  });
}

/// One cloud-side (plan_id, client_id) pair. Used to backfill local
/// SQLite `sessions.client_id` for pre-v16 rows whose schema migration
/// added the column but left existing data null.
@immutable
class PlanClientLink {
  final String planId;
  final String clientId;

  const PlanClientLink({required this.planId, required this.clientId});
}
