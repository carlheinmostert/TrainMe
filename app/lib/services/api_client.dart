import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

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
}
