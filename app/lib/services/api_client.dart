import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
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
  ApiClient._() {
    // Wire an auth-state listener so `sessionExpired` clears the moment
    // the user signs back in. Supabase emits `signedIn` when a fresh
    // session lands (via magic link / password / OAuth). Keeps the UI
    // banner tightly coupled to reality without the rest of the app
    // having to remember to clear the flag. Attach errors are
    // swallowed — the banner is a recovery hint, not load-bearing.
    try {
      _authSub = Supabase.instance.client.auth.onAuthStateChange.listen((
        state,
      ) {
        if (state.event == AuthChangeEvent.signedIn ||
            state.event == AuthChangeEvent.tokenRefreshed) {
          sessionExpired.value = false;
        } else if (state.event == AuthChangeEvent.signedOut) {
          // On signedOut we do NOT clear sessionExpired — if this
          // sign-out was triggered by `_detectRevokedSession`, the
          // caller set sessionExpired BEFORE the sign-out fired, and
          // we want the banner to stick until a successful sign-in.
          // Explicit user-initiated sign-outs clear the flag in
          // AuthService.signOut().
        }
      }, onError: (_) {});
    } catch (e) {
      // Plugin not initialised yet — unlikely because ApiClient is only
      // accessed after Supabase.initialize in main.dart. Non-fatal.
      debugPrint('ApiClient: auth listener attach failed: $e');
    }
  }

  // The singleton lives the app lifetime, so we never cancel this
  // subscription — it's kept in a field solely so the closure it binds
  // isn't GC'd. The `ignore: unused_field` silences the analyzer.
  // ignore: unused_field
  StreamSubscription<AuthState>? _authSub;

  /// Singleton. The Supabase client itself is a singleton, so wrapping it
  /// as a singleton here is lossless and lets call sites stay short.
  static final ApiClient instance = ApiClient._();

  /// Classify an arbitrary exception as "the server-side session has
  /// been revoked" vs. anything else. Matches every shape Supabase uses:
  ///
  /// * `AuthApiException(code: 'session_not_found', ...)` — the typed
  ///   wrapper from supabase-flutter when the REST boundary returns
  ///   `{ code: 'session_not_found' }` on a 403.
  /// * `AuthException` (generic) whose `message` contains
  ///   `session_not_found` — the older shape that still surfaces from
  ///   some call sites.
  /// * PostgREST responses that forward the auth gate's 403 payload
  ///   with `session_not_found` in the body.
  ///
  /// If the error matches, flips [sessionExpired] to true so the UI
  /// can render a banner. Does NOT call `signOut()` — the brief's
  /// "don't force-navigate on revoke" rule requires keeping the user
  /// on their current screen with the banner visible. Reads still come
  /// from cache; writes still queue into `pending_ops`. The actual
  /// sign-out happens when the practitioner taps the banner's
  /// "Sign in" CTA, which routes through
  /// [AuthService.signOut] → [AuthGate] → [SignInScreen].
  ///
  /// Does NOT swallow the exception — callers that were expecting an
  /// RPC result still see a failure; the retry backoff in
  /// [SyncService.flush] keeps the 403 rate to at most once per op per
  /// 5 seconds, so piling 403s against the revoked session is bounded.
  ///
  /// Idempotent: repeated calls with the same error only flip the flag
  /// once (`sessionExpired.value` guards re-entry).
  Future<void> _detectRevokedSession(Object error) async {
    // Cheap + order-sensitive checks. AuthException (and its subclasses
    // AuthApiException / AuthSessionMissingException) carries a `code`
    // field populated with `session_not_found` when the REST boundary
    // returns that payload. PostgREST errors that forward the auth
    // gate's 403 body surface the same string in `toString()`, so we
    // also check the stringified form as a fallback.
    final msg = error.toString();
    final looksLikeRevoked =
        msg.contains('session_not_found') ||
        (error is AuthException &&
            (error.code == 'session_not_found' ||
                error.message.contains('session_not_found')));
    if (!looksLikeRevoked) return;
    if (sessionExpired.value) return; // already handling it
    sessionExpired.value = true;
    // Log line deliberately matches the brief's phrasing so grepping
    // `dev.log` archives turns up matches even though the
    // sign-out itself is deferred to the user's banner tap.
    dev.log('session revoked — forcing sign-out', name: 'ApiClient');
  }

  /// Thin wrapper around a single async op that routes known
  /// "session revoked" failures through [_detectRevokedSession] before
  /// rethrowing. Every RPC method in this file that touches the
  /// authenticated Supabase boundary should run through this funnel so
  /// a server-side session deletion can't silently 403 every subsequent
  /// request.
  ///
  /// Doesn't swallow errors — on a non-revoke exception the original
  /// stack trace bubbles up to the caller unchanged.
  Future<T> _guardAuth<T>(Future<T> Function() op) async {
    try {
      return await op();
    } catch (e) {
      await _detectRevokedSession(e);
      rethrow;
    }
  }

  /// Public variant of [_guardAuth] for sibling API seams that still
  /// live outside this file (e.g. [ClientDefaultsApi]) but want the
  /// session-revoke detector to fire on their RPCs too. Prefer inlining
  /// the RPC into this class when possible; this is the compatibility
  /// seam until those seams fold in.
  Future<T> guardAuth<T>(Future<T> Function() op) => _guardAuth(op);

  /// Fires true when an RPC detects the server-side session has been
  /// revoked (`session_not_found` / 403) and we've forced a local
  /// sign-out to recover. Cleared when the user signs back in via the
  /// [onAuthStateChange] `signedIn` event (see [AuthService] for the
  /// wiring — this notifier is exposed so UI can render a banner).
  ///
  /// Rationale: before Wave 15, a revoked session (password rotated
  /// elsewhere, admin intervention, `auth.sessions` row deleted) left
  /// the app returning HTTP 403 `session_not_found` on every RPC with
  /// no recovery path. The practitioner had to discover the problem
  /// via Diagnostics, manually sign out + sign in. This blocked Carl's
  /// pending-ops flush for hours on 2026-04-21.
  ///
  /// Surfaced in Home + Studio as a coral banner with a sign-in CTA.
  /// Non-blocking (reads come from cache; writes queue locally).
  final ValueNotifier<bool> sessionExpired = ValueNotifier<bool>(false);

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
    // Sign-in is the recovery path itself — don't route through
    // [_guardAuth], which would mis-flag a plain invalid-password
    // error as a session-revoke event.
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
  /// membership + 3-credit organic signup bonus (Milestone M). Idempotent;
  /// safe to call on every `onAuthStateChange` event.
  ///
  /// Returns the practice id (uuid as string). Raises `AuthException`
  /// from the underlying client on DB errors — callers own the try/catch.
  Future<String?> bootstrapPracticeForUser() async {
    final result = await _guardAuth(
      () => raw.rpc('bootstrap_practice_for_user'),
    );
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
      // Wrap in a cast<dynamic>() so _guardAuth's T-inference doesn't
      // narrow to a concrete List type — the subsequent `is! List`
      // defence-in-depth was there to protect against Supabase drivers
      // that could return a non-list on unexpected shapes.
      final dynamic response = await _guardAuth(
        () => raw
            .from('practice_members')
            .select(
              'role, practice_id, '
              'practices:practice_id ( id, name, brand_color, public_logo_url )',
            )
            .eq('trainer_id', userId)
            .order('joined_at', ascending: true),
      );
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
            final role = r['role'] is String
                ? r['role'] as String
                : 'practitioner';
            // Public Profile v2 — both fields are nullable on the
            // practices table; defensive `is String` checks so the
            // map() can never explode on a malformed payload.
            final brandColorRaw = practice['brand_color'];
            final logoRaw = practice['public_logo_url'];
            return PracticeMembership(
              id: id,
              name: name,
              role: role == 'owner'
                  ? PracticeRole.owner
                  : PracticeRole.practitioner,
              brandColor: brandColorRaw is String ? brandColorRaw : null,
              publicLogoUrl: logoRaw is String ? logoRaw : null,
            );
          })
          .whereType<PracticeMembership>()
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  /// Whether the signed-in user has the Safe Mode grandfather flag set on
  /// ANY of their `practice_members` rows.
  ///
  /// Self-trainer wave (PR #1 schema) added `practice_members.
  /// safe_mode_grandfathered` — set true by the one-time migration backfill
  /// for any practitioner who has ever captured a `safe_mode_active=true`
  /// exercise. The flag short-circuits the Safe Mode subscription gate to
  /// "always-on" for early adopters.
  ///
  /// Read directly from `practice_members` (same precedent as
  /// [listMyPractices] — RLS scopes the SELECT to `trainer_id = auth.uid()`
  /// rows). Returns `false` on any error so callers render the universal
  /// banner copy rather than the grandfathered-extension line — false is
  /// the safe default (it just means we don't show the bonus line).
  ///
  /// Used by [SelfTrainerIntroBanner] to decide whether to append the
  /// "we've extended your Safe Mode access for free" line.
  Future<bool> isCurrentUserSafeModeGrandfathered() async {
    try {
      final userId = raw.auth.currentUser?.id;
      if (userId == null) return false;
      final dynamic response = await _guardAuth(
        () => raw
            .from('practice_members')
            .select('safe_mode_grandfathered')
            .eq('trainer_id', userId)
            .eq('safe_mode_grandfathered', true)
            .limit(1),
      );
      if (response is! List) return false;
      return response.isNotEmpty;
    } catch (_) {
      // Column may not yet exist on per-PR Branching DBs that haven't
      // applied PR #1's migration, or the network may be flaky. Either
      // way, default to false (= show the universal copy only).
      return false;
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
      final result = await _guardAuth(
        () => raw.rpc(
          'practice_credit_balance',
          params: {'p_practice_id': practiceId},
        ),
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
      // Wrap in dynamic so the `is! List` defence below survives T-
      // inference narrowing. See [listMyPractices] for the same pattern.
      final dynamic result = await _guardAuth(
        () => raw
            .from('plans')
            .select('id, client_id')
            .eq('practice_id', practiceId)
            .not('client_id', 'is', null),
      );
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

  /// `list_practice_plans(p_practice_id)` — full cloud→mobile session
  /// pull surface. Returns every non-deleted plan in the practice with
  /// embedded exercises + per-set rows, scoped by membership.
  ///
  /// One round-trip; no anon access. The mobile [SyncService] hydrates
  /// SQLite (sessions / exercises / exercise_sets) for any plan id it
  /// doesn't yet have locally; existing local rows are NOT clobbered
  /// (local-wins on collisions, per the offline-first contract).
  ///
  /// Returns `[]` on any error so callers render the shell without
  /// crashing — the missing pull is purely additive (zero sessions
  /// locally just means the previous behaviour persists). Throws are
  /// swallowed; tests should assert on the post-pull SQLite state.
  ///
  /// Result rows have the wire shape emitted by the SECURITY DEFINER fn
  /// (see `supabase/schema_pull_practice_plans.sql`):
  ///
  ///   {
  ///     id, practice_id, client_id, client_name, title, version,
  ///     created_at, sent_at, first_opened_at, last_opened_at,
  ///     last_published_at, last_trainer_id, deleted_at,
  ///     circuit_cycles, preferred_rest_interval_seconds,
  ///     crossfade_lead_ms, crossfade_fade_ms,
  ///     unlock_credit_prepaid_at,
  ///     exercises: [{ id, position, name, media_url, line_drawing_url,
  ///                   thumbnail_url, media_type, notes, circuit_id,
  ///                   include_audio, created_at, preferred_treatment,
  ///                   prep_seconds, start_offset_ms, end_offset_ms,
  ///                   video_reps_per_loop, aspect_ratio,
  ///                   rotation_quarters, body_focus, rest_seconds,
  ///                   sets: [{ position, reps, hold_seconds,
  ///                            weight_kg, breather_seconds_after }] }]
  ///   }
  ///
  /// `line_drawing_url` is the public `media` bucket URL for the line-
  /// drawing treatment (always public read; same URL the web player uses
  /// as the default treatment). NULL for rest rows and never-published
  /// rows. The mobile [MediaPrefetchService] reads this field on Studio
  /// session-open and downloads each video / photo so cloud-pulled cards
  /// play from local files.
  Future<List<Map<String, dynamic>>> listPracticePlans(
    String practiceId,
  ) async {
    try {
      final result = await _guardAuth(
        () => raw.rpc(
          'list_practice_plans',
          params: {'p_practice_id': practiceId},
        ),
      );
      // RPC returns jsonb { plans: [...] }. Tolerate the rare case where
      // the wrapper isn't present (older fn variant) by also accepting a
      // bare list.
      List<dynamic>? plans;
      if (result is Map && result['plans'] is List) {
        plans = result['plans'] as List<dynamic>;
      } else if (result is List) {
        plans = result;
      }
      if (plans == null) return const [];
      return plans
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList(growable: false);
    } catch (e) {
      debugPrint('ApiClient.listPracticePlans failed: $e');
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
  ///
  /// Milestone V (2026-04-21, Wave 16): the RPC now raises SQLSTATE
  /// `P0003` if any exercise on the plan has a `preferred_treatment` the
  /// linked client hasn't consented to. The `_guardAuth` passthrough
  /// preserves the `PostgrestException` with `code == 'P0003'`, which
  /// `UploadService` translates into `UnconsentedTreatmentsException` so
  /// the UI can show the unblock sheet. This is the authoritative
  /// backstop — a mobile client that skips the `validatePlanTreatmentConsent`
  /// pre-flight still can't burn credits on a mismatched plan.
  Future<Map<String, dynamic>> consumeCredit({
    required String practiceId,
    required String planId,
    required int credits,
  }) async {
    final result = await _guardAuth(
      () => raw.rpc(
        'consume_credit',
        params: {
          'p_practice_id': practiceId,
          'p_plan_id': planId,
          'p_credits': credits,
        },
      ),
    );
    return result is Map
        ? Map<String, dynamic>.from(result)
        : const <String, dynamic>{};
  }

  /// `preview_publish_cost(p_session_id)` — self-trainer wave PR #6
  /// (2026-05-25). Side-effect-free RPC the Studio workflow pill uses to
  /// surface the credit-cost label ("Publish · Free / 1 credit / 2
  /// credits") without actually consuming anything. The same conditional
  /// logic is applied authoritatively inside `consume_credit` at publish
  /// time — this preview is purely a UI helper.
  ///
  /// Returns 0 / 1 / 2:
  ///   * 0 when the plan's linked client is the practitioner themselves
  ///     (Self-client per PR #1) AND every cloud `exercises` row has
  ///     `self_verified = true`.
  ///   * 2 when the server-side per-set duration estimate exceeds 75
  ///     minutes (4500s).
  ///   * 1 otherwise (including a first-publish plan where the cloud
  ///     has no exercises rows yet — the mobile client's own
  ///     `creditCostForDuration` is still the wire-side source of truth).
  ///
  /// Raises on auth / membership / network failures — no exception
  /// swallowing (per `feedback_no_exception_control_flow`).
  Future<int> previewPublishCost(String sessionId) async {
    final result = await _guardAuth(
      () => raw.rpc(
        'preview_publish_cost',
        params: {'p_session_id': sessionId},
      ),
    );
    if (result is int) return result;
    if (result is num) return result.toInt();
    if (result is String) {
      final parsed = int.tryParse(result);
      if (parsed != null) return parsed;
    }
    throw StateError(
      'preview_publish_cost returned non-integer payload: $result',
    );
  }

  /// `validate_plan_treatment_consent(p_plan_id)` — returns the list of
  /// exercises whose `preferred_treatment` is denied by the linked
  /// client's `video_consent`. Empty list = safe to publish.
  ///
  /// Called from `UploadService.uploadPlan` as a pre-flight check before
  /// the (authoritative) `consumeCredit` guard. Running both means the
  /// UI can show the unblock sheet WITHOUT the server ever having to
  /// raise P0003 — the server-side guard is a backstop, not the primary
  /// UX surface.
  ///
  /// Legacy plans (client_id IS NULL) return an empty list by design;
  /// there's no client to validate against. Milestone V migration
  /// (`supabase/schema_milestone_v_publish_consent_validation.sql`).
  Future<List<UnconsentedTreatment>> validatePlanTreatmentConsent({
    required String planId,
  }) async {
    final result = await _guardAuth(
      () => raw.rpc(
        'validate_plan_treatment_consent',
        params: {'p_plan_id': planId},
      ),
    );
    if (result is! List) return const [];
    final out = <UnconsentedTreatment>[];
    for (final row in result) {
      if (row is! Map) continue;
      final exerciseId = row['exercise_id'];
      final treatment = row['preferred_treatment'];
      final consentKey = row['consent_key'];
      if (exerciseId is String && treatment is String && consentKey is String) {
        out.add(
          UnconsentedTreatment(
            exerciseId: exerciseId,
            preferredTreatment: treatment,
            consentKey: consentKey,
          ),
        );
      }
    }
    return out;
  }

  /// `unlock_plan_for_edit(p_plan_id)` — pre-pay one credit to re-open
  /// structural editing on a post-lock plan. Server-side stamps
  /// `plans.unlock_credit_prepaid_at`; the next successful publish reads
  /// + clears that flag inside `consume_credit` so the republish is
  /// free.
  ///
  /// Returns the RPC's jsonb response as a `Map<String, dynamic>`:
  ///
  ///   * on success: `{ok: true, balance: int, prepaid_at: <ISO ts>}`
  ///   * on insufficient funds: `{ok: false, reason:
  ///     'insufficient_credits', balance: int}`
  ///
  /// Idempotent: a second call on a plan whose flag is still set returns
  /// `{ok: true, balance: <unchanged>, prepaid_at: <existing>}` without
  /// charging again.
  Future<Map<String, dynamic>> unlockPlanForEdit({
    required String planId,
  }) async {
    final result = await _guardAuth(
      () => raw.rpc('unlock_plan_for_edit', params: {'p_plan_id': planId}),
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
      final result = await _guardAuth(
        () => raw.rpc('refund_credit', params: {'p_plan_id': planId}),
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
    await _guardAuth(() => raw.from('plans').upsert(row));
  }

  /// Every client name in the practice, INCLUDING soft-deleted rows.
  /// Milestone W — exposes recycle-bin names to the default-name picker
  /// so it doesn't mint "New client N" only for publish to fail against
  /// the unique index with 23505 "a deleted client already uses that
  /// name".
  ///
  /// Returns an empty set on any error (offline, RPC permission, etc.).
  /// The caller's fallback is the local-cache scan, which is still
  /// correct for the single-device lifetime — the cloud check is a
  /// multi-device / cross-session safety net.
  Future<Set<String>> listAllClientNamesIncludingDeleted(
    String practiceId,
  ) async {
    try {
      final dynamic result = await _guardAuth(
        () => raw.rpc(
          'list_all_client_names',
          params: {'p_practice_id': practiceId},
        ),
      );
      if (result is! List) return const <String>{};
      return result
          .whereType<Map>()
          .map((row) => row['name'])
          .whereType<String>()
          .toSet();
    } catch (e) {
      debugPrint('ApiClient.listAllClientNamesIncludingDeleted failed: $e');
      return const <String>{};
    }
  }

  /// Lightweight fetch of a plan's publish state (version + sent_at).
  /// Used by the session-open reconciliation path — if the publish flow
  /// crashed after `consume_credit` but before `saveSession(updated)`
  /// landed locally, the cloud row has version>0 / sent_at set but the
  /// local row is still at version=0 / planUrl=null. Opening the session
  /// then shows no share button. This fetch lets the Studio screen
  /// detect that divergence and backfill.
  ///
  /// Returns null on any error (network, row not found, etc.). Callers
  /// treat null as "don't reconcile" — the session stays at its local
  /// state, which is the safe default.
  Future<Map<String, dynamic>?> getPlanPublishState(String planId) async {
    try {
      final dynamic result = await _guardAuth(
        () => raw
            .from('plans')
            .select(
              // Wave 33: pull `last_opened_at` alongside `first_opened_at`
              // so SessionShell can reconcile both into the local SQLite
              // mirror — the Studio analytics row needs both timestamps.
              'version, sent_at, first_opened_at, last_opened_at, unlock_credit_prepaid_at',
            )
            .eq('id', planId)
            .maybeSingle(),
      );
      if (result is Map) {
        return Map<String, dynamic>.from(result);
      }
      return null;
    } catch (e) {
      debugPrint('ApiClient.getPlanPublishState failed for $planId: $e');
      return null;
    }
  }

  /// Atomic replace-all-exercises for a plan (Wave 18.1).
  ///
  /// Wraps DELETE + INSERT inside a single SECURITY DEFINER transaction
  /// server-side. This is the ONLY supported write path for exercise
  /// rows.
  ///
  /// **Per-set PLAN wave** — payload shape is now: each row in [rows]
  /// mirrors the `exercises` columns (id, plan_id, position, name,
  /// media_url, thumbnail_url, media_type, notes, circuit_id,
  /// include_audio, preferred_treatment, prep_seconds, start_offset_ms,
  /// end_offset_ms, video_reps_per_loop, aspect_ratio,
  /// rotation_quarters, body_focus, focus_frame_offset_ms,
  /// hero_crop_offset) PLUS a
  /// nested `sets` array
  /// `[{position, reps, hold_seconds, weight_kg, breather_seconds_after}, ...]`
  /// for video / photo exercises. Rest exercises omit `sets` (or pass
  /// an empty array). Unknown keys are ignored by the RPC.
  ///
  /// Pass an empty [rows] list to clear every exercise for the plan.
  ///
  /// Returns a [ReplacePlanExercisesResult] with the cloud's plan
  /// version + a list of exercise IDs whose `sets` array was missing or
  /// empty (the RPC inserted a synthetic single-set fallback for those
  /// — see `schema_wave_per_set_dose.sql`). Callers should surface the
  /// fallback IDs to the practitioner so they know a default was
  /// applied.
  Future<ReplacePlanExercisesResult> replacePlanExercises({
    required String planId,
    required List<Map<String, dynamic>> rows,
  }) async {
    final raw0 = await _guardAuth(
      () => raw.rpc(
        'replace_plan_exercises',
        params: {'p_plan_id': planId, 'p_rows': rows},
      ),
    );
    if (raw0 is Map) {
      final m = Map<String, dynamic>.from(raw0);
      final version = _asNullableInt(m['plan_version']);
      final ids = <String>[];
      final fallback = m['fallback_set_exercise_ids'];
      if (fallback is List) {
        for (final item in fallback) {
          if (item is String && item.isNotEmpty) ids.add(item);
        }
      }
      return ReplacePlanExercisesResult(
        planVersion: version,
        fallbackSetExerciseIds: List.unmodifiable(ids),
      );
    }
    // Older or unexpected shapes — surface a permissive empty result so
    // callers don't crash.
    return const ReplacePlanExercisesResult(
      planVersion: null,
      fallbackSetExerciseIds: <String>[],
    );
  }

  /// Append a plan_issuances audit row. Best-effort from the caller's
  /// perspective — this method raises on failure but upload_service
  /// swallows it (see the comment there; the ledger is already the
  /// source of truth for billing).
  Future<void> insertPlanIssuance(Map<String, dynamic> row) async {
    await _guardAuth(() => raw.from('plan_issuances').insert(row));
  }

  // ==========================================================================
  // Storage — media bucket
  // ==========================================================================

  /// Upload a file to the media bucket at [path]. Uses upsert semantics so
  /// re-publishes overwrite the existing object at the same path.
  Future<void> uploadMedia({required String path, required File file}) async {
    await _guardAuth(
      () => raw.storage
          .from(mediaBucket)
          .upload(path, file, fileOptions: const FileOptions(upsert: true)),
    );
  }

  /// List files in the media bucket under [prefix]. Used by the publish
  /// skip-if-unchanged optimisation to avoid re-uploading identical files.
  Future<List<FileObject>> listMedia({required String prefix}) async {
    return await _guardAuth(
      () => raw.storage.from(mediaBucket).list(path: prefix),
    );
  }

  /// List files in the raw-archive bucket under [prefix].
  Future<List<FileObject>> listRawArchive({required String prefix}) async {
    return await _guardAuth(
      () => raw.storage.from(rawArchiveBucket).list(path: prefix),
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
    await _guardAuth(() => raw.storage.from(mediaBucket).remove(paths));
  }

  // ==========================================================================
  // Plan reads — three-treatment (Milestone G)
  // ==========================================================================

  /// Fetch the server-side view of a plan via the `get_plan_full` RPC.
  /// Returns the raw JSON map (or null on any error). The response shape
  /// carries the three-treatment URLs per exercise, plus the plan-level
  /// artifacts list added in PR #7 (self-trainer wave):
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
  ///   ],
  ///   "artifacts": [
  ///     {
  ///       "kind":         "plan_url",
  ///       "status":       "ready",
  ///       "output_url":   null,         // computed client-side for plan_url
  ///       "generated_at": "2026-05-25T...",
  ///       "metadata":     { }
  ///     }
  ///   ]
  /// }
  /// ```
  ///
  /// The `artifacts` array is always present from the RPC; older plans get
  /// a single backfilled `plan_url` entry, new plans get one written
  /// inside the `consume_credit` transaction on publish. Future kinds
  /// (`reel`, `pdf`) will surface here without an RPC change — see
  /// `docs/adr/0022-plan-artifacts-abstraction-before-reel.md`. v1 has
  /// no Dart-side consumers; this docstring is the forward contract.
  Future<Map<String, dynamic>?> getPlanFull(String planId) async {
    try {
      final result = await _guardAuth(
        () => raw.rpc('get_plan_full', params: {'p_plan_id': planId}),
      );
      if (result is Map) return Map<String, dynamic>.from(result);
      return null;
    } catch (e) {
      debugPrint('ApiClient.getPlanFull failed for $planId: $e');
      return null;
    }
  }

  /// Pull the typed [PlanArtifact] list out of a [getPlanFull] response.
  /// Returns an empty list on any shape mismatch or when the field is
  /// absent (legacy / pre-PR-#7 RPC, or a brand-new plan that has never
  /// been published). Callers should treat an empty list as "no artifacts
  /// known"; the canonical Plan URL is still inferrable from `plan.id`.
  List<PlanArtifact> artifactsFromPlanResponse(Map<String, dynamic>? response) {
    if (response == null) return const [];
    final raw = response['artifacts'];
    if (raw is! List) return const [];
    final out = <PlanArtifact>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final kind = entry['kind'];
      final status = entry['status'];
      if (kind is! String || status is! String) continue;
      out.add(
        PlanArtifact(
          kind: kind,
          status: status,
          outputUrl: _stringOrNull(entry['output_url']),
          generatedAt: _stringOrNull(entry['generated_at']),
          metadata: entry['metadata'] is Map
              ? Map<String, dynamic>.from(entry['metadata'] as Map)
              : const {},
        ),
      );
    }
    return out;
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
        // Per-set PLAN rest-fix — schema_wave_per_set_dose_rest_fix.sql
        // adds rest_seconds to the get_plan_full per-exercise object.
        // Null for video/photo; positive integer for media_type='rest'.
        // Surfaced on the transit object so future cloud→local sync /
        // ExerciseCapture hydration can read it without a second RPC.
        restHoldSeconds: (row['rest_seconds'] as num?)?.toInt(),
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
  ///
  /// Errors propagate — matches [upsertClientWithId]. The publish path
  /// MUST fail hard when this throws, otherwise `plans.client_id` gets
  /// written as NULL and `get_plan_full` falls back to default consent
  /// (line-drawing only). Notable error signals callers should handle:
  ///
  /// * [PostgrestException] `23505` with "already uses that name" —
  ///   a soft-deleted client in this practice owns [name]. The
  ///   practitioner must restore it from the recycle bin or rename
  ///   before republishing; no automatic resolution.
  /// * [PostgrestException] `42501` — caller isn't a member of
  ///   [practiceId].
  /// * Any other exception — network / auth / transient DB error.
  ///
  /// Returns null only when the RPC succeeds but yields no id (defensive;
  /// the SQL contract guarantees a uuid on success).
  Future<String?> upsertClient({
    required String practiceId,
    required String name,
  }) async {
    final result = await _guardAuth(
      () => raw.rpc(
        'upsert_client',
        params: {'p_practice_id': practiceId, 'p_name': name},
      ),
    );
    if (result is String && result.isNotEmpty) return result;
    return null;
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
    final result = await _guardAuth(
      () => raw.rpc(
        'upsert_client_with_id',
        params: {'p_id': clientId, 'p_practice_id': practiceId, 'p_name': name},
      ),
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
      await _guardAuth(
        () => raw.rpc(
          'rename_client',
          params: {'p_client_id': clientId, 'p_new_name': newName},
        ),
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

  /// `rename_session(p_plan_id, p_new_title)` — Wave 38. Companion to
  /// [renameClient] but for sessions (cloud table: `plans`). Practitioner-
  /// driven inline rename on the SessionCard syncs through here. Membership-
  /// checked SECURITY DEFINER, so the same `42501` / `P0002` shapes apply.
  ///
  /// Errors surface as [PostgrestException] for the caller (SyncService) to
  /// classify. There's no UNIQUE on `plans.title` (duplicate titles are fine
  /// across sessions in a practice), so no `23505` branch.
  Future<void> renameSession({
    required String planId,
    required String newTitle,
  }) async {
    await _guardAuth(
      () => raw.rpc(
        'rename_session',
        params: {'p_plan_id': planId, 'p_new_title': newTitle},
      ),
    );
  }

  /// `delete_client(p_client_id)` — soft-deletes the client and cascades
  /// a tombstone onto every plan owned by the client (same `deleted_at`
  /// timestamp so [restoreClient] can reverse it selectively).
  ///
  /// Idempotent — calling on an already-deleted client is a no-op and
  /// returns the existing tombstoned row. SECURITY DEFINER, practice-
  /// membership gated inside the RPC.
  ///
  /// Raises `PostgrestException` on membership / auth failures; caller
  /// (SyncService) lets those bubble so [markPendingOpFailed] records
  /// the error for diagnostics.
  Future<void> deleteClient({required String clientId}) async {
    await _guardAuth(
      () => raw.rpc('delete_client', params: {'p_client_id': clientId}),
    );
  }

  /// `restore_client(p_client_id)` — reverses [deleteClient]. Restores the
  /// client row AND any plan whose `deleted_at` matches the client's
  /// `deleted_at` exactly. Plans soft-deleted at another timestamp
  /// (manual delete before the cascade) stay deleted.
  ///
  /// Idempotent — no-op on a live client.
  Future<void> restoreClient({required String clientId}) async {
    await _guardAuth(
      () => raw.rpc('restore_client', params: {'p_client_id': clientId}),
    );
  }

  /// List the clients belonging to a practice. Used by the Your-clients
  /// screen. Returns an empty list on any error so the UI can render an
  /// empty state rather than crash.
  ///
  /// ⚠️  Historically this swallowed every exception and returned `[]`,
  /// which made it impossible for callers to tell "this practice has no
  /// clients" from "the RPC blew up and we silently pretended nothing
  /// was wrong" — Carl's data looked like it had been wiped. New callers
  /// that need to distinguish those two states should use
  /// [listPracticeClientsOrThrow] instead; this wrapper exists for the
  /// legacy callers (consent sheets / media-viewer fallback) that
  /// genuinely just want a best-effort list.
  Future<List<PracticeClient>> listPracticeClients(String practiceId) async {
    try {
      return await listPracticeClientsOrThrow(practiceId);
    } catch (e) {
      debugPrint('ApiClient.listPracticeClients failed: $e');
      return const [];
    }
  }

  /// Throwing variant of [listPracticeClients]. Use this from the sync
  /// layer where "RPC exploded" needs to be distinguished from "practice
  /// is empty". The UI can then surface a banner instead of silently
  /// rendering an empty list.
  Future<List<PracticeClient>> listPracticeClientsOrThrow(
    String practiceId,
  ) async {
    final result = await _guardAuth(
      () => raw.rpc(
        'list_practice_clients',
        params: {'p_practice_id': practiceId},
      ),
    );
    if (result is! List) return const [];
    return result
        .whereType<Map>()
        .map((m) => PracticeClient.fromJson(Map<String, dynamic>.from(m)))
        .toList(growable: false);
  }

  /// Write the client's video-viewing preferences.
  ///
  /// `lineAllowed` is always true (line drawing de-identifies the client
  /// and is the platform baseline). Passed for explicitness; backend
  /// validates + preserves it. Returns true on success.
  ///
  /// Wave 30 — [avatarAllowed] gates the body-focus avatar capture surface
  /// on the client detail view. Optional + defaults to false so existing
  /// callers don't need to pass it; the four-arg server-side fn merges
  /// the missing key as false anyway. Pass an explicit value once the
  /// caller's UI surface knows about avatar consent.
  ///
  /// Failures are swallowed silently per R-voice fallback — the caller
  /// shows a neutral error if needed.
  /// Wave 17 — [analyticsAllowed] gates anonymous usage analytics for
  /// this client's plans. Default ON per design doc. When null, the
  /// server-side shim preserves the existing value.
  Future<bool> setClientVideoConsent({
    required String clientId,
    required bool lineAllowed,
    required bool grayscaleAllowed,
    required bool colourAllowed,
    bool? avatarAllowed,
    bool? analyticsAllowed,
  }) async {
    try {
      // Pass the avatar flag through when the caller specified it; the
      // server-side 5-arg fn handles all four. When null, route to the
      // 3-arg shim which preserves the existing avatar value server-side
      // — a stale caller can't accidentally clobber a flag it doesn't
      // know about.
      //
      // NOTE (Safe Mode v2, 2026-05-23): the `safe_mode_face_recognition`
      // consent flag is NOT routed through here. It flows via its own
      // dedicated [setClientSafeModeConsent] RPC so the server can
      // additionally zero `clients.face_embedding` on a toggle-off in
      // the same transaction. Don't bundle it into this 5-arg wrapper.
      final params = <String, dynamic>{
        'p_client_id': clientId,
        'p_line_drawing': lineAllowed,
        'p_grayscale': grayscaleAllowed,
        'p_original': colourAllowed,
      };
      if (avatarAllowed != null) {
        params['p_avatar'] = avatarAllowed;
      }
      if (analyticsAllowed != null) {
        params['p_analytics_allowed'] = analyticsAllowed;
      }
      await _guardAuth(
        () => raw.rpc('set_client_video_consent', params: params),
      );
      return true;
    } catch (e) {
      debugPrint('ApiClient.setClientVideoConsent failed: $e');
      return false;
    }
  }

  /// Safe Mode v2 (2026-05-23) — `set_client_safe_mode_consent(p_client_id,
  /// p_consent)`. Flips the `safe_mode_face_recognition` key in the client's
  /// `video_consent` jsonb. When [allowed] is false, the server also zeros
  /// out `clients.face_embedding` + `face_embedding_model_version` so a
  /// fresh consent grant restarts the biometric capture flow.
  ///
  /// Returns true on success, false on any error (network, RLS, RPC
  /// signature mismatch — common while the sibling schema PR is in
  /// flight). Caller is expected to roll back optimistic UI on false.
  Future<bool> setClientSafeModeConsent({
    required String clientId,
    required bool allowed,
  }) async {
    try {
      await _guardAuth(
        () => raw.rpc(
          'set_client_safe_mode_consent',
          params: <String, dynamic>{
            'p_client_id': clientId,
            'p_consent': allowed,
          },
        ),
      );
      return true;
    } catch (e) {
      debugPrint('ApiClient.setClientSafeModeConsent failed: $e');
      return false;
    }
  }

  /// Safe Mode v2 (2026-05-23) — `set_client_face_embedding(p_client_id,
  /// p_embedding, p_model_version)`. Persists the MobileFaceNet embedding
  /// (raw bytes, 512-D float32 little-endian = 2048 bytes) into
  /// `clients.face_embedding` (bytea) and stamps
  /// `clients.face_embedding_model_version`.
  ///
  /// The embedding is derived ON-DEVICE from the client's avatar JPG —
  /// the raw image never leaves the practitioner's iPhone in a form that
  /// can be reverse-engineered into an identifying photo.
  ///
  /// Returns true on success, false on any error. Caller (the
  /// `FaceEmbeddingService`) flips its state to error so the UI can
  /// surface a retry CTA.
  Future<bool> setClientFaceEmbedding({
    required String clientId,
    required Uint8List embedding,
    required int modelVersion,
  }) async {
    try {
      // PostgREST expects bytea params as a `\x`-prefixed hex string.
      // Passing the raw Uint8List was being JSON-serialised as a list
      // of integers (e.g. `[255, 128, 64, ...]`) which PostgreSQL cast
      // to bytea using the literal characters of THAT encoding — the
      // server-side `length(p_embedding) = 2048` check tripped with
      // "got 7253 bytes" (diagnosed via postgres logs 2026-05-23).
      // Hex string with the `\x` prefix is the canonical bytea input
      // format and lands as exactly 2048 bytes for a 2048-byte vector.
      final hex = StringBuffer(r'\x');
      for (final b in embedding) {
        hex.write(b.toRadixString(16).padLeft(2, '0'));
      }
      await _guardAuth(
        () => raw.rpc(
          'set_client_face_embedding',
          params: <String, dynamic>{
            'p_client_id': clientId,
            'p_embedding': hex.toString(),
            'p_model_version': modelVersion,
          },
        ),
      );
      return true;
    } catch (e) {
      debugPrint('ApiClient.setClientFaceEmbedding failed: $e');
      return false;
    }
  }

  /// Safe Mode v2 multi-reference enrolment (2026-05-24, Wave-A) —
  /// `set_client_face_embeddings(p_client_id, p_embeddings, p_model_version,
  /// p_frontal_pick_slot, p_poses_yaw, p_poses_pitch)`. Transactionally
  /// replaces every existing slot for the client with the new 1-8 slot
  /// set. The frontal-pick slot is mirrored into the legacy single-
  /// embedding columns during the backward-compat window.
  ///
  /// Embeddings must each be exactly 2048 bytes (512 FP32 LE floats).
  /// [embeddings], [posesYaw], [posesPitch] must all share the same
  /// length. [frontalPickSlotIndex] is a 0-based index into [embeddings].
  ///
  /// Returns true on success, false on any error. Caller (the
  /// FaceEnrolmentService) flips its state to error so the UI can
  /// surface a retry CTA.
  ///
  /// Spec: docs/specs/2026-05-24-safe-mode-v2-multi-reference-enrolment.md.
  Future<bool> setClientFaceEmbeddings({
    required String clientId,
    required List<Uint8List> embeddings,
    required int modelVersion,
    required int frontalPickSlotIndex,
    required List<double> posesYaw,
    required List<double> posesPitch,
  }) async {
    try {
      // PostgREST expects bytea params as `\x`-prefixed hex strings (see
      // setClientFaceEmbedding above for the diagnostic story). For the
      // array variant, the JSON payload is a list of those same hex
      // strings — PostgREST coerces each element to bytea on the way in.
      final hexList = <String>[];
      for (final e in embeddings) {
        final sb = StringBuffer(r'\x');
        for (final b in e) {
          sb.write(b.toRadixString(16).padLeft(2, '0'));
        }
        hexList.add(sb.toString());
      }
      await _guardAuth(
        () => raw.rpc(
          'set_client_face_embeddings',
          params: <String, dynamic>{
            'p_client_id': clientId,
            'p_embeddings': hexList,
            'p_model_version': modelVersion,
            'p_frontal_pick_slot': frontalPickSlotIndex,
            'p_poses_yaw': posesYaw,
            'p_poses_pitch': posesPitch,
          },
        ),
      );
      return true;
    } catch (e) {
      debugPrint('ApiClient.setClientFaceEmbeddings failed: $e');
      return false;
    }
  }

  /// Safe Mode v2 multi-reference enrolment (2026-05-24, Wave-A) —
  /// `get_client_face_embeddings(p_client_id)`. Returns the full slot
  /// set for the client, ordered ascending by slot_index. Empty list
  /// means unenrolled OR consent withdrawn OR (legitimately) the
  /// caller hasn't synced yet.
  ///
  /// On any error (network, RLS) returns an empty list — caller can't
  /// distinguish "no rows" from "lookup failed" by return value alone;
  /// log lines in console identify the latter.
  Future<List<ClientFaceEmbeddingSlot>> getClientFaceEmbeddings({
    required String clientId,
  }) async {
    try {
      final dynamic result = await _guardAuth(
        () => raw.rpc(
          'get_client_face_embeddings',
          params: <String, dynamic>{'p_client_id': clientId},
        ),
      );
      if (result is! List) return const [];
      return result
          .whereType<Map>()
          .map((row) {
            final map = Map<String, dynamic>.from(row);
            return ClientFaceEmbeddingSlot(
              slotIndex: (map['slot_index'] as num).toInt(),
              embedding: _decodeBytea(map['embedding']),
              modelVersion: (map['model_version'] as num).toInt(),
              isFrontalPick: map['is_frontal_pick'] == true,
            );
          })
          .toList(growable: false);
    } catch (e) {
      debugPrint('ApiClient.getClientFaceEmbeddings failed: $e');
      return const [];
    }
  }

  /// Decode a PostgREST bytea wire value into raw bytes. PostgREST
  /// returns bytea either as a `\x`-prefixed hex string (default) or
  /// base64 (when `Accept` headers ask for it). We handle both shapes
  /// + log a hard error on anything else — the caller's empty-slot
  /// branch then runs.
  static Uint8List _decodeBytea(dynamic value) {
    if (value is String) {
      if (value.startsWith(r'\x')) {
        final hex = value.substring(2);
        final out = Uint8List(hex.length ~/ 2);
        for (int i = 0; i < out.length; i++) {
          out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
        }
        return out;
      }
      // Fallback: assume base64. Caller surfaces empty-list semantics if
      // this throws.
      return base64Decode(value);
    }
    if (value is List) {
      return Uint8List.fromList(value.cast<int>());
    }
    debugPrint(
      'ApiClient._decodeBytea: unexpected bytea wire shape ${value.runtimeType}',
    );
    return Uint8List(0);
  }

  /// Self-trainer wave PR #3 (2026-05-25) —
  /// `register_self_face(p_embedding vector(512), p_consented_at timestamptz)`
  /// SECURITY DEFINER RPC. Writes the practitioner's self-verification
  /// embedding + timestamps and lazily creates the Self-client row in
  /// the user's personal practice.
  ///
  /// Returns the Self-client uuid on success. Throws on any RPC error
  /// (the caller is the Settings → Public profile flow which surfaces
  /// the error verbatim per `feedback_no_silent_fallbacks`).
  ///
  /// Idempotent — re-calling overwrites the embedding + consent
  /// timestamp and reuses the existing Self-client row (enforced by
  /// the partial unique index on `clients (practice_id, user_id) WHERE
  /// user_id IS NOT NULL AND deleted_at IS NULL`).
  ///
  /// The embedding dim is 512 (MobileFaceNet on-device model output) —
  /// the spec text in `docs/SELF_TRAINER_WAVE.md` calls for 192 but the
  /// bundled mlmodel emits 512; the schema migration amends the column
  /// to vector(512). See
  /// `supabase/migrations/20260525114912_register_self_face_rpc.sql`.
  ///
  /// PostgREST serialises `List<double>` as a JSON number array, which
  /// pgvector accepts as a vector literal — no special encoding needed
  /// (unlike the bytea path in [setClientFaceEmbedding] which requires
  /// the `\x`-prefixed hex string trick).
  Future<String> registerSelfFace({
    required List<double> embedding,
    required DateTime consentedAt,
  }) async {
    Future<dynamic> callRpc() => _guardAuth(
      () => raw.rpc(
        'register_self_face',
        params: <String, dynamic>{
          'p_embedding': embedding,
          // Postgres wants ISO-8601; UTC normalisation matches the
          // wave 39.4 Dart-wire-timestamp convention (all timestamps
          // bound for Postgres are UTC).
          'p_consented_at': consentedAt.toUtc().toIso8601String(),
        },
      ),
    );

    dynamic result;
    try {
      result = await callRpc();
    } on PostgrestException catch (e) {
      // R2-M3 — single-shot retry on 23505 (unique-violation). Per the
      // RPC's own comment (migration 20260525114912 lines 192-196), a
      // concurrent SELECT-then-INSERT race can collide on
      // `clients_one_self_per_user_per_practice`. On retry the SELECT
      // branch finds the row the winner inserted and the RPC succeeds
      // idempotently.
      //
      // Not exception-as-control-flow per `feedback_no_exception_control_flow`
      // — this is a documented transient DB error, not a
      // status-code-as-signal path. The RPC contract itself sanctions
      // the retry.
      if (e.code == '23505') {
        debugPrint(
          'ApiClient.registerSelfFace: 23505 on first call — retrying '
          '(documented transient race per RPC comment)',
        );
        result = await callRpc();
      } else {
        rethrow;
      }
    }

    if (result is String && result.isNotEmpty) {
      return result;
    }
    throw StateError(
      'register_self_face returned unexpected shape: ${result.runtimeType} '
      '($result)',
    );
  }

  /// Self-trainer wave PR #4 (2026-05-25) —
  /// `revoke_self_face()` SECURITY DEFINER RPC. POPIA Q14.3 decoupled
  /// deletion of the self-verification embedding.
  ///
  /// Clears `practitioners.face_embedding` + `face_embedding_consented_at`
  /// + `face_embedding_computed_at` back to NULL, and soft-deletes the
  /// Self-client row (`clients.user_id = auth.uid()`). Selfie + name on
  /// the practitioners row remain so the Safe Mode transparency surface
  /// keeps working — only the self-verification purpose is revoked.
  ///
  /// Idempotent — re-calling on an already-revoked practitioner is a
  /// no-op. Returns a [RevokeSelfFaceResult] indicating what changed so
  /// the caller can tailor the SnackBar copy and decide whether to
  /// expose an Undo affordance.
  ///
  /// Throws on any RPC error. The caller (Settings → Public profile
  /// flow) surfaces the error verbatim per `feedback_no_silent_fallbacks`.
  ///
  /// Migration: `supabase/migrations/20260525144005_revoke_self_face_rpc.sql`.
  Future<RevokeSelfFaceResult> revokeSelfFace() async {
    final dynamic result = await _guardAuth(() => raw.rpc('revoke_self_face'));

    // The RPC returns SETOF (embedding_cleared boolean, self_client_deleted uuid)
    // — PostgREST serialises that as a List<Map> with a single row.
    if (result is List && result.isNotEmpty) {
      final first = result.first;
      if (first is Map) {
        final cleared = first['embedding_cleared'];
        final clientId = first['self_client_deleted'];
        return RevokeSelfFaceResult(
          embeddingCleared: cleared is bool ? cleared : false,
          selfClientDeleted: clientId is String ? clientId : null,
        );
      }
    }
    if (result is Map) {
      // Fallback for the single-row Map shape some Supabase clients
      // synthesise when the RETURNS TABLE has a single row.
      final cleared = result['embedding_cleared'];
      final clientId = result['self_client_deleted'];
      return RevokeSelfFaceResult(
        embeddingCleared: cleared is bool ? cleared : false,
        selfClientDeleted: clientId is String ? clientId : null,
      );
    }
    // Empty result list = no row revoked (defensive; the RPC always
    // RETURNs NEXT). Treat as "nothing changed".
    return const RevokeSelfFaceResult(
      embeddingCleared: false,
      selfClientDeleted: null,
    );
  }

  /// Self-trainer wave PR #5 (2026-05-25) —
  /// `get_my_self_face_embedding()` SECURITY DEFINER RPC. Returns the
  /// caller's own `practitioners.face_embedding` as a `List<double>`
  /// (512 floats), or `null` when no self-face has been registered
  /// (i.e. the user has not run the consent flow yet).
  ///
  /// Used by the capture-time self-verification step in
  /// `app/lib/services/conversion_service.dart` to compare against the
  /// freshly-converted exercise media. The RPC keeps the
  /// `practitioners.face_embedding` pgvector column out of the
  /// enumerated table-SELECT surface (per `feedback_no_direct_db_access`).
  ///
  /// Returns a tri-state [SelfFaceEmbeddingResult]:
  ///   * `registered(embedding)` — user has consented; embedding loaded.
  ///   * `notRegistered()` — RPC succeeded but returned no row / empty
  ///     embedding (user has not run the consent flow yet). Safe to
  ///     cache this state across captures.
  ///   * `unknown(error)` — RPC threw OR returned an unparseable shape.
  ///     Per `feedback_no_silent_fallbacks` the caller MUST NOT cache
  ///     this state — the next capture should retry rather than baking
  ///     in a transient network flake as "the user is opted out".
  Future<SelfFaceEmbeddingResult> getMySelfFaceEmbedding() async {
    try {
      final dynamic result = await _guardAuth(
        () => raw.rpc('get_my_self_face_embedding'),
      );
      if (result == null) {
        return const SelfFaceEmbeddingResult.notRegistered();
      }
      if (result is List) {
        final out = <double>[];
        for (final v in result) {
          if (v is double) {
            out.add(v);
          } else if (v is num) {
            out.add(v.toDouble());
          } else {
            final err = StateError(
              'ApiClient.getMySelfFaceEmbedding: unexpected element '
              'type ${v.runtimeType}',
            );
            debugPrint('$err');
            return SelfFaceEmbeddingResult.unknown(err);
          }
        }
        if (out.isEmpty) {
          return const SelfFaceEmbeddingResult.notRegistered();
        }
        return SelfFaceEmbeddingResult.registered(out);
      }
      final shapeErr = StateError(
        'ApiClient.getMySelfFaceEmbedding: unexpected result shape '
        '${result.runtimeType}',
      );
      debugPrint('$shapeErr');
      return SelfFaceEmbeddingResult.unknown(shapeErr);
    } catch (e) {
      debugPrint('ApiClient.getMySelfFaceEmbedding failed: $e');
      return SelfFaceEmbeddingResult.unknown(e);
    }
  }

  /// `set_client_avatar(p_client_id, p_avatar_path)` — Wave 30. Commits
  /// the cloud-side pointer to the body-focus avatar PNG. Caller is
  /// expected to have already uploaded the file to the `raw-archive`
  /// bucket at [avatarPath] (shape `{practiceId}/{clientId}/avatar.png`)
  /// before calling. Pass null to clear the avatar.
  ///
  /// Returns the updated row (id, practice_id, name, avatar_path,
  /// video_consent) on success, or null on any error. Errors are caught
  /// + debug-logged so the offline-first queue can keep flushing.
  Future<Map<String, dynamic>?> setClientAvatar({
    required String clientId,
    required String? avatarPath,
  }) async {
    try {
      final dynamic result = await _guardAuth(
        () => raw.rpc(
          'set_client_avatar',
          params: {'p_client_id': clientId, 'p_avatar_path': avatarPath},
        ),
      );
      if (result is List && result.isNotEmpty) {
        final first = result.first;
        if (first is Map) {
          return Map<String, dynamic>.from(first);
        }
      }
      if (result is Map) {
        return Map<String, dynamic>.from(result);
      }
      return null;
    } catch (e) {
      debugPrint('ApiClient.setClientAvatar failed: $e');
      return null;
    }
  }

  /// Sign a time-limited URL for an avatar PNG inside the private
  /// `raw-archive` bucket. Wave 30 — the avatar slot on the client
  /// detail view binds against this URL (cached per render). Returns
  /// null when the vault secrets aren't populated or the RPC errors,
  /// at which point the caller falls back to the initials monogram.
  ///
  /// `expiresIn` defaults to 1h; the avatar UI re-signs lazily, so a
  /// longer-than-strictly-needed window keeps the visible image alive
  /// across rapid rebuilds without piling RPCs.
  Future<String?> signClientAvatarUrl({
    required String avatarPath,
    int expiresIn = 3600,
  }) async {
    if (avatarPath.isEmpty) return null;
    try {
      final result = await _guardAuth(
        () => raw.rpc(
          'sign_storage_url',
          // SQL signature is sign_storage_url(p_bucket text, p_path text,
          // p_expires_in integer) — PostgREST matches RPC params by name
          // against the SQL identifier, so a missing `p_` prefix surfaces
          // as "function not found" and the catch silently returns null.
          // Diagnosed 2026-05-23 during the Safe Mode v2 avatar-resolve
          // hang: the camera reported "No avatar set yet" because this
          // call 404'd on every retry.
          params: {
            'p_bucket': rawArchiveBucket,
            'p_path': avatarPath,
            'p_expires_in': expiresIn,
          },
        ),
      );
      if (result is String && result.isNotEmpty) return result;
      return null;
    } catch (e) {
      debugPrint('ApiClient.signClientAvatarUrl failed: $e');
      return null;
    }
  }

  // ==========================================================================
  // Storage — raw-archive bucket (private)
  // ==========================================================================

  /// Upload a file to the private `raw-archive` bucket at [path]. Path
  /// shape is `{practice_id}/{plan_id}/{exercise_id}.mp4`.
  ///
  /// The bucket is PRIVATE — the web player never reads this directly;
  /// it gets time-limited signed URLs via the `get_plan_full` RPC when
  /// client consent grants grayscale or original treatments.
  ///
  /// **upsert is TRUE — idempotent re-upload.** Same content to same
  /// path is a harmless overwrite. Avoids 409 Duplicate exceptions that
  /// would otherwise break re-publish: the bucket has no SELECT policy
  /// for `authenticated` (by design — privacy model), so the caller's
  /// existence-check (`listRawArchive`) returns empty silently and
  /// every variant attempts to re-upload. With `upsert: false` those
  /// re-uploads 409, get caught as "failure", and the whole publish
  /// reports "0 of N files". With `upsert: true` Supabase Storage uses
  /// PUT semantics (no SELECT required — only INSERT/UPDATE on
  /// storage.objects, which the policy grants), and the upload
  /// succeeds whether the file exists or not. No exception ever fires
  /// for the duplicate-path case — per the no-exception-control-flow
  /// rule, we don't use thrown 409s as a signal for "already uploaded".
  ///
  /// The fast-path skip in `_uploadRawArchives`
  /// (`exercise.rawArchiveUploadedAt != null`) means in 99% of
  /// re-publish cases we never reach this call at all; `upsert: true`
  /// just handles the 1% edge case where stamping was missed.
  ///
  /// **contentType is set explicitly** to avoid the SDK's mime-sniff
  /// path, which reads the entire file into memory via
  /// `readAsBytesSync()` — a multi-minute 720p H.264 archive would OOM
  /// on iOS.
  ///
  /// Best-effort from the caller's perspective: if the bucket doesn't
  /// exist (pre-migration) or the RLS check fails, this throws and the
  /// caller is expected to log + swallow (see
  /// `UploadService._uploadRawArchives`).
  ///
  /// [contentType] defaults to `video/mp4` (the original 720p H.264
  /// archive). Wave 22 adds the photo path which uploads `image/jpeg`
  /// at `{practice_id}/{plan_id}/{exercise_id}.jpg` — same bucket,
  /// same RLS, only the mime + extension differ.
  Future<void> uploadRawArchive({
    required String path,
    required File file,
    String contentType = 'video/mp4',
  }) async {
    await _guardAuth(
      () => raw.storage
          .from(rawArchiveBucket)
          .upload(
            path,
            file,
            // Idempotent re-upload — same content to same path is a
            // harmless overwrite. Avoids 409 Duplicate exceptions that
            // would otherwise break re-publish.
            fileOptions: FileOptions(upsert: true, contentType: contentType),
          ),
    );
  }

  /// Sign a time-limited URL for an object in the private `raw-archive`
  /// bucket. Returns null when the vault secrets aren't populated (the
  /// `sign_storage_url` helper returns NULL in that case — see
  /// `schema_milestone_g_three_treatment.sql`) or when the RPC errors.
  ///
  /// Path shape: `{practice_id}/{plan_id}/{exercise_id}.{extension}`.
  /// Default `mp4` for the video flow; pass `jpg` for photo three-treatment
  /// pulls (raw colour JPG, same source serves both Original + B&W). Used by
  /// the download-original action sheet (Wave 19.5) and the locked-segment
  /// silent prefetch as a fallback when the local archive / raw photo isn't
  /// on disk. Unlike the `get_plan_full` embedded signed URLs, this path is
  /// for practitioner-side playback of THEIR OWN capture — no client-consent
  /// gate applies.
  ///
  /// `expiresIn` is seconds; defaults to 30 min (matches the
  /// `get_plan_full` helper's default). The signed URL is single-use from
  /// the caller's perspective: it's consumed immediately to download the
  /// file to a temp / archive path, so caching the URL serves no purpose.
  Future<String?> signRawArchiveUrl({
    required String practiceId,
    required String planId,
    required String exerciseId,
    int expiresIn = 1800,
    String extension = 'mp4',
  }) async {
    try {
      // Routes through the membership-checked SECURITY DEFINER wrapper.
      // The underlying public.sign_storage_url is granted to service_role
      // only; sign_practice_raw_archive_url runs as postgres and gates on
      // user_practice_ids() / user_is_practice_owner().
      final result = await _guardAuth(
        () => raw.rpc(
          'sign_practice_raw_archive_url',
          params: {
            'p_practice_id': practiceId,
            'p_plan_id': planId,
            'p_exercise_id': exerciseId,
            'p_expires_in': expiresIn,
            'p_extension': extension,
          },
        ),
      );
      if (result is String && result.isNotEmpty) return result;
      return null;
    } catch (e) {
      debugPrint('ApiClient.signRawArchiveUrl failed: $e');
      return null;
    }
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
    final result = await _guardAuth(
      () => raw.rpc(
        'generate_referral_code',
        params: {'p_practice_id': practiceId},
      ),
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
    final result = await _guardAuth(
      () => raw.rpc(
        'referral_dashboard_stats',
        params: {'p_practice_id': practiceId},
      ),
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

  // ==========================================================================
  // Plan analytics — Wave 17
  // ==========================================================================

  /// `get_plan_analytics_summary(p_plan_id)` — per-plan rollup for the
  /// Studio stats widget. Returns opens, completions, last_opened_at, and
  /// per-exercise stats (viewed / completed / skipped).
  ///
  /// Cloud-only — no offline cache. Fetch on demand when the screen
  /// renders. Returns null on any error so callers render a placeholder.
  Future<PlanAnalyticsSummary?> getPlanAnalyticsSummary(String planId) async {
    try {
      final result = await _guardAuth(
        () => raw.rpc(
          'get_plan_analytics_summary',
          params: {'p_plan_id': planId},
        ),
      );
      Map<String, dynamic>? row;
      if (result is Map<String, dynamic>) {
        row = result;
      } else if (result is List && result.isNotEmpty) {
        final first = result.first;
        if (first is Map<String, dynamic>) row = first;
      }
      if (row == null) return null;
      return PlanAnalyticsSummary.fromJson(row);
    } catch (e) {
      debugPrint('ApiClient.getPlanAnalyticsSummary failed for $planId: $e');
      return null;
    }
  }

  /// `get_client_analytics_summary(p_client_id)` — client-level aggregates
  /// across all plans belonging to this client. Cloud-only; returns null
  /// on any error.
  Future<ClientAnalyticsSummary?> getClientAnalyticsSummary(
    String clientId,
  ) async {
    try {
      final result = await _guardAuth(
        () => raw.rpc(
          'get_client_analytics_summary',
          params: {'p_client_id': clientId},
        ),
      );
      Map<String, dynamic>? row;
      if (result is Map<String, dynamic>) {
        row = result;
      } else if (result is List && result.isNotEmpty) {
        final first = result.first;
        if (first is Map<String, dynamic>) row = first;
      }
      if (row == null) return null;
      return ClientAnalyticsSummary.fromJson(row);
    } catch (e) {
      debugPrint(
        'ApiClient.getClientAnalyticsSummary failed for $clientId: $e',
      );
      return null;
    }
  }

  // ==========================================================================
  // Share-kit analytics — Wave 10 / 11
  // ==========================================================================

  /// Fire-and-forget analytics for every share-kit action (copy, open-intent,
  /// PNG download, clipboard image). Wraps `log_share_event` SECURITY DEFINER
  /// RPC; clients don't write `share_events` directly.
  ///
  /// [channel] is one of: `whatsapp_one_to_one`, `whatsapp_broadcast`,
  /// `email`, `png_download`, `png_clipboard`, `tagline_copy`, `code_copy`,
  /// `link_copy`. [eventKind] is one of: `copy`, `open_intent`, `download`,
  /// `clipboard_image`.
  ///
  /// Callers should wrap in `unawaited(...)` — this method MUST NOT block
  /// the UI. Errors are swallowed locally (with `debugPrint`) because
  /// analytics are low-stakes: the share still happened even if the log
  /// row didn't land. A follow-up can route this through `loudSwallow`
  /// so failures land in the server-side `error_logs` table; kept on
  /// `debugPrint` today to preserve the fire-and-forget contract
  /// exactly.
  Future<void> logShareEvent({
    required String practiceId,
    required String channel,
    required String eventKind,
    Map<String, dynamic>? meta,
  }) async {
    try {
      await _guardAuth(
        () => raw.rpc(
          'log_share_event',
          params: {
            'p_practice_id': practiceId,
            'p_channel': channel,
            'p_event_kind': eventKind,
            ...meta == null ? const {} : {'p_meta': meta},
          },
        ),
      );
    } catch (e) {
      debugPrint('ApiClient.logShareEvent($channel/$eventKind) failed: $e');
    }
  }

  // ==========================================================================
  // Safe Mode — premises lookup
  // ==========================================================================

  /// `find_premises_at(p_lat, p_lng)` — anon-callable RPC that returns
  /// the most-restrictive Safe-Mode-enforcing premises containing the
  /// supplied point. Returns `null` when no enforced polygon contains
  /// the point — in which case Safe Mode stays off for the session.
  ///
  /// "Most restrictive wins" semantics (smallest polygon area first) are
  /// implemented server-side; the client just consumes the single row.
  ///
  /// Anyone-inside-the-polygon binding: the RPC does NOT check practice
  /// membership. A practitioner from Practice A inside Practice B's
  /// polygon gets Practice B's Safe Mode applied to their captures.
  Future<SafeModeMatch?> findPremisesAt({
    required double latitude,
    required double longitude,
  }) async {
    try {
      // anon-callable, but _guardAuth is still safe — it just no-ops
      // when there's no session, since this RPC doesn't read auth.uid().
      final dynamic result = await _guardAuth(
        () => raw.rpc(
          'find_premises_at',
          params: {'p_lat': latitude, 'p_lng': longitude},
        ),
      );
      if (result is! List || result.isEmpty) return null;
      final row = result.first;
      if (row is! Map) return null;
      final id = row['premises_id'];
      final name = row['premises_name'];
      final enforced = row['safe_mode_enforced'];
      if (id is! String) return null;
      // S-H1 fix (synthesis 2026-05-21): the anon RPC no longer returns
      // practice_id (anti-enumeration). Mobile doesn't use it — Safe
      // Mode only needs the premises id + name + enforcement boolean.
      // If a caller needs the practice context, look it up via
      // cached_practices keyed by the active session.
      return SafeModeMatch(
        premisesId: id,
        premisesName: name is String ? name : '',
        safeModeEnforced: enforced is bool ? enforced : false,
      );
    } catch (e) {
      debugPrint('ApiClient.findPremisesAt failed: $e');
      return null;
    }
  }

  /// `report_premises(p_premises_id, p_reason, p_reporter_fingerprint)` —
  /// anon-callable RPC. Surfaces a report to the homefit team (Carl
  /// triages manually for MVP). Returns the new report row id on
  /// success, null on failure.
  ///
  /// `reporterFingerprint` should be a stable device-scoped string so the
  /// server-side per-hour rate-limit (S-H2) caps duplicate reports per
  /// (premises, device). Callers typically pass a SharedPreferences
  /// `device_id`; empty string means "anonymous" and shares a single
  /// rate-limit bucket.
  Future<String?> reportPremises({
    required String premisesId,
    required String reason,
    String reporterFingerprint = '',
  }) async {
    try {
      final dynamic result = await _guardAuth(
        () => raw.rpc(
          'report_premises',
          params: {
            'p_premises_id': premisesId,
            'p_reason': reason,
            'p_reporter_fingerprint': reporterFingerprint,
          },
        ),
      );
      return result is String ? result : null;
    } catch (e) {
      debugPrint('ApiClient.reportPremises failed: $e');
      return null;
    }
  }

  // ==========================================================================
  // Safe Mode subscription gate (Self-trainer wave PR #8, 2026-05-25)
  // ADR-0021; docs/SELF_TRAINER_WAVE.md § Safe Mode subscription model.
  // ==========================================================================

  /// `is_in_active_safe_mode_sub(p_user_id)` — STABLE SECURITY DEFINER
  /// predicate. Returns true if any of:
  ///   * the user is grandfathered (any practice membership with
  ///     `safe_mode_grandfathered = true`),
  ///   * a `safe_mode_month` ledger row exists within the last 30 days,
  ///   * a `safe_mode_month_trial` ledger row exists within the last 3 days.
  ///
  /// Failure modes return `false` rather than throwing — the capture-entry
  /// gate is read on every camera open and a network blip must not block
  /// access for a paying user. False is the "fail-closed" answer: if the
  /// network is down the user is shown the paywall instead of the
  /// viewfinder; UI re-queries on reconnect.
  ///
  /// The result is cached locally — see [SafeModeSubscriptionStatus] in
  /// `app/lib/services/safe_mode_subscription_service.dart` which
  /// memoises this answer for an hour and re-pulls on app launch +
  /// hourly while foreground.
  Future<bool> isInActiveSafeModeSub({required String userId}) async {
    try {
      final dynamic result = await _guardAuth(
        () => raw.rpc(
          'is_in_active_safe_mode_sub',
          params: {'p_user_id': userId},
        ),
      );
      return result is bool ? result : false;
    } catch (e) {
      debugPrint('ApiClient.isInActiveSafeModeSub failed: $e');
      return false;
    }
  }

  /// `start_safe_mode_trial(p_user_id)` — idempotent. Returns true on
  /// the first call (trial row inserted), false on any subsequent call
  /// (user has already used their lifetime trial).
  ///
  /// Throws on auth / membership errors so the caller can surface a
  /// useful message. Callers should pass the current `auth.uid()` user
  /// id — the RPC rejects mismatches.
  Future<bool> startSafeModeTrial({required String userId}) async {
    final dynamic result = await _guardAuth(
      () => raw.rpc('start_safe_mode_trial', params: {'p_user_id': userId}),
    );
    return result is bool ? result : false;
  }

  // ==========================================================================
  // Safe Mode Transparency — Phase A (2026-05-22)
  // ==========================================================================

  /// `set_practitioner_profile(p_first_name, p_last_name, p_avatar_url)` —
  /// upserts the caller's identity row + appends one audit-log entry per
  /// changed field. Empty strings normalise to NULL server-side.
  ///
  /// Throws on validation failure (length > 60, malformed avatar URL,
  /// missing auth). The caller is expected to surface a friendly message.
  Future<void> setPractitionerProfile({
    required String firstName,
    required String lastName,
    required String avatarUrl,
  }) async {
    await _guardAuth(
      () => raw.rpc(
        'set_practitioner_profile',
        params: {
          'p_first_name': firstName,
          'p_last_name': lastName,
          'p_avatar_url': avatarUrl,
        },
      ),
    );
  }

  /// `can_use_safe_mode(p_trainer_id, p_practice_id)` — returns the
  /// six-point gate result. `ok = true` means Safe Mode can engage.
  /// `missing` lists the stable identifiers the client maps to UI copy:
  ///
  ///   Practitioner-controlled:
  ///     'first_name', 'last_name', 'avatar_url'
  ///   Practice-controlled:
  ///     'public_slug', 'public_blurb', 'public_profile_listed'
  ///
  /// Returns null on any network/RPC failure — the caller should treat
  /// null as "unknown, allow the optimistic path" rather than "blocked",
  /// because we don't want a flaky network to suppress Safe Mode for a
  /// fully-compliant practitioner.
  Future<SafeModeGateResult?> canUseSafeMode({
    required String trainerId,
    required String practiceId,
  }) async {
    try {
      final dynamic result = await _guardAuth(
        () => raw.rpc(
          'can_use_safe_mode',
          params: {'p_trainer_id': trainerId, 'p_practice_id': practiceId},
        ),
      );
      if (result is! List || result.isEmpty) return null;
      final row = result.first;
      if (row is! Map) return null;
      final ok = row['ok'];
      final missing = row['missing'];
      return SafeModeGateResult(
        ok: ok is bool ? ok : false,
        missing: missing is List
            ? missing.whereType<String>().toList(growable: false)
            : const <String>[],
      );
    } catch (e) {
      debugPrint('ApiClient.canUseSafeMode failed: $e');
      return null;
    }
  }

  /// Fetch the caller's own practitioner row (or null if not yet
  /// created). Reads via the table directly because RLS already scopes
  /// to self + shared-practice; no RPC needed for a single-row read.
  Future<PractitionerProfile?> getMyPractitionerProfile() async {
    final user = raw.auth.currentUser;
    if (user == null) return null;
    try {
      final dynamic result = await _guardAuth(
        () => raw
            .from('practitioners')
            .select(
              'user_id, first_name, last_name, avatar_url, '
              'face_embedding_consented_at',
            )
            .eq('user_id', user.id)
            .maybeSingle(),
      );
      if (result is! Map) return null;
      final consentedAtRaw = result['face_embedding_consented_at'];
      DateTime? consentedAt;
      if (consentedAtRaw is String && consentedAtRaw.isNotEmpty) {
        try {
          consentedAt = DateTime.parse(consentedAtRaw).toLocal();
        } catch (_) {
          consentedAt = null;
        }
      }
      return PractitionerProfile(
        userId: (result['user_id'] as String?) ?? user.id,
        firstName: result['first_name'] as String?,
        lastName: result['last_name'] as String?,
        avatarUrl: result['avatar_url'] as String?,
        faceEmbeddingConsentedAt: consentedAt,
      );
    } catch (e) {
      debugPrint('ApiClient.getMyPractitionerProfile failed: $e');
      return null;
    }
  }

  // ==========================================================================
  // Safe Mode Transparency — Phase B (2026-05-22)
  // ==========================================================================

  /// `start_capture_session(p_practice_id, p_premises_id, p_lat, p_lng, p_manual)`.
  /// Returns the new session id, or null on failure.
  Future<String?> startCaptureSession({
    required String practiceId,
    String? premisesId,
    double? latitude,
    double? longitude,
    bool manual = false,
  }) async {
    try {
      final dynamic result = await _guardAuth(
        () => raw.rpc(
          'start_capture_session',
          params: {
            'p_practice_id': practiceId,
            'p_premises_id': premisesId,
            'p_lat': latitude,
            'p_lng': longitude,
            'p_manual': manual,
          },
        ),
      );
      return result is String ? result : null;
    } catch (e) {
      debugPrint('ApiClient.startCaptureSession failed: $e');
      return null;
    }
  }

  /// `heartbeat_capture_session(p_session_id, p_lat, p_lng)`.
  /// Fire-and-forget — caller should not block on the response. Errors
  /// are swallowed; a missed heartbeat is recovered by the next tick.
  Future<void> heartbeatCaptureSession({
    required String sessionId,
    double? latitude,
    double? longitude,
  }) async {
    try {
      await _guardAuth(
        () => raw.rpc(
          'heartbeat_capture_session',
          params: {
            'p_session_id': sessionId,
            'p_lat': latitude,
            'p_lng': longitude,
          },
        ),
      );
    } catch (e) {
      debugPrint('ApiClient.heartbeatCaptureSession failed: $e');
    }
  }

  /// `end_capture_session(p_session_id)`. Idempotent. Stamps ended_at.
  Future<void> endCaptureSession({required String sessionId}) async {
    try {
      await _guardAuth(
        () =>
            raw.rpc('end_capture_session', params: {'p_session_id': sessionId}),
      );
    } catch (e) {
      debugPrint('ApiClient.endCaptureSession failed: $e');
    }
  }

  // ==========================================================================
  // Capture audit events (2026-05-23, item 27 / PR B)
  // ==========================================================================

  /// `record_capture_event(p_practice_id, p_premises_id, p_kind,
  /// p_started_at, p_ended_at, p_metadata)` — append-only audit row per
  /// photo + per video (insert-on-stop) captured by the practitioner.
  ///
  /// Powers the 24h roster on the live view (`/v/{practice}/{premises}/now`)
  /// and the bystander-transparency timeline. The RPC is SECURITY DEFINER,
  /// validates that the caller is a member of [practiceId] via
  /// `user_practice_ids()`, and is idempotent on
  /// `(trainer_id, kind, started_at)` — duplicates UPDATE `ended_at` +
  /// `metadata` rather than failing, so a retry from `pending_ops` after
  /// the row already landed is a safe no-op.
  ///
  /// Contract (mirrors the SQL fn):
  ///   * [kind] must be `'photo'` or `'video'`.
  ///   * `kind == 'video'` requires non-null [endedAt].
  ///   * `kind == 'photo'` must have null [endedAt].
  /// Both invariants are also enforced client-side (`ArgumentError`) so
  /// the bad call fails fast before hitting the wire.
  ///
  /// [premisesId] is nullable by design — captures outside any enforcing
  /// polygon still log an audit row (with a NULL `premises_id`), which is
  /// useful for the owner-facing portal drilldown even though the live
  /// view roster filters by premises.
  ///
  /// Returns the new (or pre-existing, on idempotent replay) audit row id.
  /// Errors propagate so the [SyncService] flush loop can classify them
  /// (transient = retry, permanent = drop after [_maxAttempts]).
  Future<String?> recordCaptureEvent({
    required String practiceId,
    String? premisesId,
    required String kind,
    required DateTime startedAt,
    DateTime? endedAt,
    Map<String, dynamic>? metadata,
  }) async {
    if (kind != 'photo' && kind != 'video') {
      throw ArgumentError.value(kind, 'kind', 'must be "photo" or "video"');
    }
    if (kind == 'video' && endedAt == null) {
      throw ArgumentError.value(
        endedAt,
        'endedAt',
        'kind=video requires endedAt',
      );
    }
    if (kind == 'photo' && endedAt != null) {
      throw ArgumentError.value(
        endedAt,
        'endedAt',
        'kind=photo must not have endedAt',
      );
    }
    // Postgres wants ISO-8601 UTC. .toUtc() is a no-op on already-UTC
    // DateTimes; .toIso8601String() emits the trailing 'Z' on a UTC value
    // so Postgres parses it as timestamptz correctly. Mirrors the wire-
    // safety pattern from upload_service.dart (Wave 39.4).
    final params = <String, dynamic>{
      'p_practice_id': practiceId,
      'p_premises_id': premisesId,
      'p_kind': kind,
      'p_started_at': startedAt.toUtc().toIso8601String(),
      'p_ended_at': endedAt?.toUtc().toIso8601String(),
      'p_metadata': metadata ?? const <String, dynamic>{},
    };
    final result = await _guardAuth(
      () => raw.rpc('record_capture_event', params: params),
    );
    if (result is String && result.isNotEmpty) return result;
    return null;
  }

  /// `record_safe_mode_capture_event(p_premises_id, p_metadata)` —
  /// telemetry row written every time the 2026-05-25 accept-zero-
  /// detection branch fires (Vision found no humans in any frame,
  /// safe variant skipped, raw capture used as canonical source).
  ///
  /// SECURITY DEFINER, scoped to `user_practice_ids()` via the
  /// premises resolution (or — when [premisesId] is null because the
  /// accepted-empty fired outside any polygon — via the caller's
  /// first practice membership).
  ///
  /// [metadata] should carry the scene fingerprint computed by the
  /// conversion service (mean RGB, grayscale entropy, complexity
  /// score) plus the exercise id + media type. The portal audit feed
  /// + live-page drawer key off these fields for the drill-in modal.
  ///
  /// Contract: fire-and-forget by the conversion service. Wrapped in
  /// `unawaited(...)` at the caller — failure must NOT block the
  /// capture flow (spec section 7, acceptance criterion 9). This
  /// method's caller catches and swallows any throw to keep the
  /// invariant intact.
  ///
  /// Returns the new audit row id on success, null on failure.
  Future<String?> recordSafeModeCaptureEvent({
    String? premisesId,
    Map<String, dynamic>? metadata,
  }) async {
    final params = <String, dynamic>{
      'p_premises_id': premisesId,
      'p_metadata': metadata ?? const <String, dynamic>{},
    };
    final result = await _guardAuth(
      () => raw.rpc('record_safe_mode_capture_event', params: params),
    );
    if (result is String && result.isNotEmpty) return result;
    return null;
  }

  /// Upload an avatar JPEG to the public `media` bucket at
  /// `avatars/{trainer_id}.jpg`. Returns the public URL on success,
  /// null on failure. Uses upsert so re-uploads overwrite.
  Future<String?> uploadAvatar({
    required String trainerId,
    required File file,
  }) async {
    try {
      final path = 'avatars/$trainerId.jpg';
      await _guardAuth(
        () => raw.storage
            .from('media')
            .upload(
              path,
              file,
              fileOptions: const FileOptions(
                upsert: true,
                contentType: 'image/jpeg',
                cacheControl: '3600',
              ),
            ),
      );
      // Bust the public URL cache so a re-upload shows the new image
      // immediately. The query string is ignored by Supabase Storage
      // but trips browser + CDN caches.
      final base = raw.storage.from('media').getPublicUrl(path);
      return '$base?v=${DateTime.now().millisecondsSinceEpoch}';
    } catch (e) {
      debugPrint('ApiClient.uploadAvatar failed: $e');
      return null;
    }
  }
}

/// Result of the six-point [ApiClient.canUseSafeMode] gate.
///
/// `ok` is true iff every check passed. `missing` carries the stable
/// identifier strings the UI maps to copy:
///
///   Practitioner-controlled:
///     'first_name', 'last_name', 'avatar_url'
///   Practice-controlled:
///     'public_slug', 'public_blurb', 'public_profile_listed'
@immutable
class SafeModeGateResult {
  final bool ok;
  final List<String> missing;

  const SafeModeGateResult({required this.ok, required this.missing});

  /// True iff at least one of the missing items is practitioner-controlled
  /// (the user can fix it in Settings). Drives the "Open Settings" vs
  /// "Open Portal" branch on the gate screen.
  bool get hasPractitionerGap =>
      missing.contains('first_name') ||
      missing.contains('last_name') ||
      missing.contains('avatar_url');

  /// True iff at least one of the missing items is practice-controlled.
  bool get hasPracticeGap =>
      missing.contains('public_slug') ||
      missing.contains('public_blurb') ||
      missing.contains('public_profile_listed');
}

/// The caller's own practitioner identity row, populated by Settings.
/// Null fields = not yet set. Mirrors the columns on the
/// `public.practitioners` table.
@immutable
class PractitionerProfile {
  final String userId;
  final String? firstName;
  final String? lastName;
  final String? avatarUrl;

  /// When the practitioner consented to having their selfie used for
  /// self-verification (POPIA Q14.1). NULL until the user taps Yes on
  /// the [SelfFaceConsentSheet]. Drives the Settings → Public profile
  /// "Face verification: ON / OFF" row + the lazy-backfill skip
  /// condition. Populated by the `register_self_face` RPC, cleared by
  /// the `revoke_self_face` RPC.
  final DateTime? faceEmbeddingConsentedAt;

  const PractitionerProfile({
    required this.userId,
    this.firstName,
    this.lastName,
    this.avatarUrl,
    this.faceEmbeddingConsentedAt,
  });

  /// True iff first + last + avatar are all set. Used to skip the
  /// first-time disclosure card on the second save.
  bool get isComplete =>
      (firstName?.trim().isNotEmpty ?? false) &&
      (lastName?.trim().isNotEmpty ?? false) &&
      (avatarUrl?.trim().isNotEmpty ?? false);

  /// True iff the practitioner has opted into self-verification —
  /// drives the Settings → Public profile "Face verification: ON" copy.
  bool get hasFaceVerification => faceEmbeddingConsentedAt != null;
}

/// Outcome of [ApiClient.revokeSelfFace]. Carries enough state for the
/// Settings → Public profile flow to render an accurate SnackBar
/// ("Face verification removed" vs "Already off") and to decide whether
/// to offer Undo (only when something was actually revoked).
@immutable
class RevokeSelfFaceResult {
  /// True iff the practitioner row had a non-NULL `face_embedding`
  /// before this call cleared it.
  final bool embeddingCleared;

  /// The id of the soft-deleted Self-client row, or NULL if no
  /// self-client existed (revocation without prior registration).
  final String? selfClientDeleted;

  const RevokeSelfFaceResult({
    required this.embeddingCleared,
    required this.selfClientDeleted,
  });

  /// True iff anything was actually revoked. The Settings flow uses
  /// this to decide whether to surface an Undo SnackBar (R-01).
  bool get changedAnything => embeddingCleared || selfClientDeleted != null;
}

/// Outcome of [ApiClient.getMySelfFaceEmbedding]. Tri-state so the
/// caller can distinguish "user hasn't consented" from "network flake"
/// (per `feedback_no_silent_fallbacks` — they must NOT collapse to the
/// same `null` value or transient errors get silently treated as
/// permanent opt-out).
@immutable
class SelfFaceEmbeddingResult {
  /// 0 = registered (embedding populated), 1 = notRegistered, 2 = unknown.
  final int _kind;

  /// Non-null iff registered. The 512-float MobileFaceNet embedding.
  final List<double>? _embedding;

  /// Non-null iff unknown. The underlying error / exception that drove
  /// the unknown state — surfaced via debug log so transient flakes are
  /// inspectable.
  final Object? _error;

  const SelfFaceEmbeddingResult._({
    required int kind,
    List<double>? embedding,
    Object? error,
  }) : _kind = kind,
       _embedding = embedding,
       _error = error;

  const SelfFaceEmbeddingResult.registered(List<double> embedding)
    : this._(kind: 0, embedding: embedding);

  const SelfFaceEmbeddingResult.notRegistered() : this._(kind: 1);

  const SelfFaceEmbeddingResult.unknown(Object error)
    : this._(kind: 2, error: error);

  bool get isRegistered => _kind == 0;
  bool get isNotRegistered => _kind == 1;
  bool get isUnknown => _kind == 2;

  /// Returns the embedding when registered, else null. Callers MUST
  /// branch on [isRegistered] / [isNotRegistered] / [isUnknown] rather
  /// than null-checking this directly — null is not informative here.
  List<double>? get embedding => _embedding;

  /// The error driving the unknown state, when applicable.
  Object? get error => _error;
}

/// Outcome of a [ApiClient.findPremisesAt] call. Returned when the
/// geolocation point sits inside at least one Safe-Mode-enforcing
/// polygon — null otherwise.
@immutable
class SafeModeMatch {
  final String premisesId;
  final String premisesName;
  final bool safeModeEnforced;

  const SafeModeMatch({
    required this.premisesId,
    required this.premisesName,
    required this.safeModeEnforced,
  });
}

/// One slot in a multi-reference face enrolment (Safe Mode v2 Wave-A,
/// 2026-05-24). Mirrors a single row from the cloud
/// `client_face_embeddings` table. Returned by
/// [ApiClient.getClientFaceEmbeddings] and consumed by the upcoming
/// FaceEnrolmentService (Wave-D) + native compositor (Wave-BC).
///
/// Spec: docs/specs/2026-05-24-safe-mode-v2-multi-reference-enrolment.md.
@immutable
class ClientFaceEmbeddingSlot {
  /// 0-based slot ordinal. Matches the cloud row's `slot_index` smallint.
  final int slotIndex;

  /// 2048-byte MobileFaceNet embedding (512 FP32 LE floats, L2-normalised).
  final Uint8List embedding;

  /// Generator version. 1 = MobileFaceNet v1 (current). Older versions
  /// stay valid during the backward-compat window; a future bump
  /// triggers re-enrolment nudges in the UI.
  final int modelVersion;

  /// True on exactly one slot per client — the most-frontal frame, used
  /// as the avatar JPG source.
  final bool isFrontalPick;

  const ClientFaceEmbeddingSlot({
    required this.slotIndex,
    required this.embedding,
    required this.modelVersion,
    required this.isFrontalPick,
  });
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
/// One entry from the `artifacts` array surfaced by the `get_plan_full`
/// RPC (PR #7 of the self-trainer wave). Each plan has one row per
/// artifact kind; v1 ships `kind='plan_url'` only. Future kinds (`reel`,
/// `pdf`) land here without an RPC change — see
/// `docs/adr/0022-plan-artifacts-abstraction-before-reel.md`.
///
/// For `kind='plan_url'`, [outputUrl] is intentionally null — the URL is
/// computed client-side as `https://session.homefit.studio/p/{plan_id}`.
/// Future materialised renders (Reel MP4 in a signed-URL bucket) populate
/// [outputUrl] with the signed URL.
@immutable
class PlanArtifact {
  final String kind;
  final String status;
  final String? outputUrl;
  final String? generatedAt;
  final Map<String, dynamic> metadata;

  const PlanArtifact({
    required this.kind,
    required this.status,
    this.outputUrl,
    this.generatedAt,
    this.metadata = const {},
  });
}

@immutable
class ExerciseTreatmentUrls {
  final String? lineDrawingUrl;
  final String? grayscaleUrl;
  final String? originalUrl;

  /// Rest-period duration (seconds). Null for video/photo rows; positive
  /// integer for media_type='rest'. Round-trips through the
  /// `exercises.rest_seconds` column added in
  /// schema_wave_per_set_dose_rest_fix.sql; matches mobile-side
  /// [ExerciseCapture.restHoldSeconds] (SQLite v33).
  final int? restHoldSeconds;

  const ExerciseTreatmentUrls({
    this.lineDrawingUrl,
    this.grayscaleUrl,
    this.originalUrl,
    this.restHoldSeconds,
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
///
/// Public Profile v2 (2026-05-21) — also carries the practice-level
/// branding columns (`brand_color`, `public_logo_url`) so the embedded
/// Preview can cascade them into the WebView without a second cloud
/// round-trip. Both nullable; null means "fall back to homefit defaults".
@immutable
class PracticeMembership {
  final String id;
  final String name;
  final PracticeRole role;
  final String? brandColor;
  final String? publicLogoUrl;

  const PracticeMembership({
    required this.id,
    required this.name,
    required this.role,
    this.brandColor,
    this.publicLogoUrl,
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

/// One row returned by
/// [ApiClient.validatePlanTreatmentConsent]: a single exercise whose
/// sticky `preferred_treatment` is denied by the linked client's
/// `video_consent` jsonb.
///
/// * [exerciseId] — the offending exercise row. Matches
///   `exercises.id`.
/// * [preferredTreatment] — the raw wire value ('grayscale' or
///   'original'; 'line' is never surfaced since line-drawing consent
///   is always true).
/// * [consentKey] — the matching `video_consent` jsonb key
///   ('grayscale' / 'original'). Provided by the RPC so the UI can
///   render a friendly group label without re-mapping.
///
/// Used only by Wave 16's pre-flight consent validation; never hits
/// the cache or the SQLite layer.
@immutable
class UnconsentedTreatment {
  final String exerciseId;
  final String preferredTreatment;
  final String consentKey;

  const UnconsentedTreatment({
    required this.exerciseId,
    required this.preferredTreatment,
    required this.consentKey,
  });
}

/// Per-exercise analytics stats returned inside [PlanAnalyticsSummary].
@immutable
class ExerciseAnalyticsStats {
  final String exerciseId;
  final int viewed;
  final int completed;
  final int skipped;

  const ExerciseAnalyticsStats({
    required this.exerciseId,
    required this.viewed,
    required this.completed,
    required this.skipped,
  });

  factory ExerciseAnalyticsStats.fromJson(Map<String, dynamic> json) {
    return ExerciseAnalyticsStats(
      exerciseId: json['exercise_id'] as String? ?? '',
      viewed: _asInt(json['viewed']),
      completed: _asInt(json['completed']),
      skipped: _asInt(json['skipped']),
    );
  }
}

/// Plan-level analytics summary returned by `get_plan_analytics_summary`.
@immutable
class PlanAnalyticsSummary {
  final int opens;
  final int completions;
  final DateTime? lastOpenedAt;
  final Map<String, ExerciseAnalyticsStats> exerciseStats;

  const PlanAnalyticsSummary({
    required this.opens,
    required this.completions,
    this.lastOpenedAt,
    required this.exerciseStats,
  });

  factory PlanAnalyticsSummary.fromJson(Map<String, dynamic> json) {
    final statsRaw = json['exercise_stats'];
    final statsMap = <String, ExerciseAnalyticsStats>{};
    if (statsRaw is List) {
      for (final item in statsRaw) {
        if (item is Map<String, dynamic>) {
          final stat = ExerciseAnalyticsStats.fromJson(item);
          if (stat.exerciseId.isNotEmpty) {
            statsMap[stat.exerciseId] = stat;
          }
        }
      }
    }
    return PlanAnalyticsSummary(
      opens: _asInt(json['opens']),
      completions: _asInt(json['completions']),
      lastOpenedAt: json['last_opened_at'] != null
          ? DateTime.tryParse(json['last_opened_at'].toString())
          : null,
      exerciseStats: statsMap,
    );
  }
}

/// Client-level analytics summary returned by
/// `get_client_analytics_summary`.
@immutable
class ClientAnalyticsSummary {
  final int totalOpens;
  final int totalCompletions;
  final int totalPlans;

  const ClientAnalyticsSummary({
    required this.totalOpens,
    required this.totalCompletions,
    required this.totalPlans,
  });

  factory ClientAnalyticsSummary.fromJson(Map<String, dynamic> json) {
    return ClientAnalyticsSummary(
      totalOpens: _asInt(json['total_opens']),
      totalCompletions: _asInt(json['total_completions']),
      totalPlans: _asInt(json['total_plans']),
    );
  }
}

int _asInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

int? _asNullableInt(dynamic v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

/// Outcome of a [ApiClient.replacePlanExercises] call (per-set PLAN
/// wave). The RPC now returns jsonb with two fields:
///
///   * `plan_version` — the plan's current version on Postgres after
///     the write. Useful for diagnostics; the publish flow already
///     tracks its own `newVersion` locally.
///   * `fallback_set_exercise_ids` — list of exercise UUIDs whose
///     incoming `sets` array was missing / empty. The RPC inserts a
///     synthetic single-set fallback (`reps=1, hold=0, weight=NULL,
///     breather=60`) for those rows so the plan stays playable. Surface
///     these to the practitioner so they know a default was applied —
///     this should never fire from the new client (which always
///     populates `sets`); it's a defence-in-depth signal that a stale
///     TestFlight build or a buggy caller skipped the per-set payload.
@immutable
class ReplacePlanExercisesResult {
  final int? planVersion;
  final List<String> fallbackSetExerciseIds;

  const ReplacePlanExercisesResult({
    required this.planVersion,
    required this.fallbackSetExerciseIds,
  });
}

// Wave 14: `ClaimInviteResult` / `ClaimInviteError` / `ClaimInviteErrorKind`
// retired alongside the Wave 5 invite-code flow. Mobile has zero invitee-
// side UI in Wave 14 — new practices appear in the practice-switcher on
// first launch after the auth.users INSERT trigger drains any pending
// entries staged by the owner on the portal's /members page.
