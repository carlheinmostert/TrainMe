import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide Session;
import 'package:supabase_flutter/supabase_flutter.dart' as supa show Session;

import '../config.dart';

/// Thin wrapper around [supabase.auth] that centralises sign-in, sign-out,
/// and the practice-membership bootstrap logic.
///
/// Design goals:
///   - Single source of truth for the provider set.
///   - The AuthGate watches [authStateChanges] so UI updates automatically.
///   - Membership bootstrap ([ensurePracticeMembership]) runs on every
///     signed-in event but is idempotent and best-effort: a failure here
///     must never brick the app. Worst case the bio signs in with no
///     membership and publishing will surface a clear error later.
///
/// ## Why native SDKs, not browser OAuth?
///
/// The prior `supabase.auth.signInWithOAuth(...)` path bounced the user
/// through an in-app or external browser to complete the Google / Apple
/// flow. That produced three distinct failure modes in testing:
///
///   1. `LaunchMode.externalApplication` → Safari shows the iOS 17+
///      "Open in app?" prompt, users decline, the deep-link never fires.
///   2. `LaunchMode.inAppWebView` / `ASWebAuthenticationSession` → Google
///      detects the isolated browser session as "insecure" and serves a
///      blank `accounts.google.com` page on first-time use.
///   3. `LaunchMode.inAppBrowserView` / SFSafariViewController → same
///      blank-page behaviour on real devices (SFSafariViewController
///      inherits cookies from Safari, but still presents as a non-standard
///      browser context to Google's fingerprinter in some cases).
///
/// The native SDKs sidestep the browser entirely. `GoogleSignIn.authenticate`
/// presents iOS's own account-picker sheet (shares the system Google account
/// if one is configured, otherwise a webview embedded in Google's own SDK).
/// `SignInWithApple.getAppleIDCredential` uses Apple's first-party UI.
///
/// Both SDKs return a signed ID token that Supabase verifies server-side
/// against its "Authorized Client IDs" list via [SupabaseAuth.signInWithIdToken].
/// The resulting Supabase session is identical to what the OAuth flow would
/// have produced — `onAuthStateChange` fires, [authStateChanges] emits, and
/// the rest of the app (AuthGate, practice-claim, etc.) is untouched.
///
/// Milestone B POV assumption: the FIRST user to sign in claims the
/// pre-seeded sentinel practice (1000 credits) as its owner. Subsequent
/// sign-ins get a fresh personal practice with a 5-credit welcome bonus.
/// This is a one-shot race — `owner_trainer_id IS NULL` on the sentinel
/// acts as the claim flag and the UPDATE is conditional so only one
/// user can win.
class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  SupabaseClient get _supabase => Supabase.instance.client;

  /// Lazy singleton for the Google Sign-In SDK. v6's API is an instance
  /// pattern — one `GoogleSignIn` instance per app lifetime.
  ///
  /// Both iOS and server (web) client IDs are supplied here, matching
  /// Supabase's canonical native-sign-in example. The `serverClientId`
  /// tells Google to issue an id_token whose `aud` claim is the web
  /// client ID — which flips the iOS SDK into a different auth flow that
  /// does NOT auto-inject a nonce claim, unblocking
  /// `signInWithIdToken` on the Supabase side. Both client IDs must be
  /// present in Supabase's Google provider "Authorized Client IDs" list.
  late final GoogleSignIn _googleSignIn = GoogleSignIn(
    clientId:
        '846780406660-lv8l6a83hlm7npvo5fj16m3n91evceih.apps.googleusercontent.com',
    serverClientId:
        '846780406660-v64pgkj2lv0mf71t269hrdenpr9nsq2c.apps.googleusercontent.com',
  );

  /// Current session snapshot. Null when the user isn't signed in.
  /// Persists across app restarts via Supabase's default secure storage
  /// (Keychain on iOS) — no extra wiring needed.
  supa.Session? get currentSession => _supabase.auth.currentSession;

  /// Convenience — the authenticated user's uuid, or null.
  String? get currentUserId => _supabase.auth.currentUser?.id;

  /// Broadcasts every auth-state change. The AuthGate listens here.
  /// Emits the full [supa.Session] (nullable) so subscribers can tell
  /// signed-in from signed-out without an extra lookup.
  Stream<supa.Session?> get authStateChanges =>
      _supabase.auth.onAuthStateChange.map((event) => event.session);

  /// Sign in with email + password.
  ///
  /// Fast-return path for users who previously set a password via
  /// [setPassword]. Magic-link remains the signup / fallback surface — the
  /// sign-in screen calls [sendMagicLink] whenever the password field is
  /// empty or this method throws.
  ///
  /// Throws [AuthException] / [AuthApiException] on bad credentials,
  /// rate-limit, etc. Callers map to friendly copy.
  ///
  /// Email is normalised to `trim().toLowerCase()` — same as magic-link —
  /// so a password account works whether the user types their email in
  /// caps or not.
  Future<void> signInWithPassword(String email, String password) async {
    final normalized = email.trim().toLowerCase();
    if (normalized.isEmpty || !normalized.contains('@')) {
      throw const AuthException('Enter a valid email address.');
    }
    if (password.isEmpty) {
      throw const AuthException('Enter your password.');
    }
    await _supabase.auth.signInWithPassword(
      email: normalized,
      password: password,
    );
  }

  /// Set (or change) the password on the currently authenticated user.
  ///
  /// Requires an active session — call this only from a post-sign-in
  /// context (e.g. the one-time "Set a password?" prompt on Home). The
  /// next time the user signs in, [signInWithPassword] with this password
  /// will succeed.
  ///
  /// Supabase doesn't expose whether a user has a password set (security),
  /// so we don't persist a server-side flag here — the sign-in-screen just
  /// tries password first and falls back to magic link on failure. The UI
  /// tracks "user has been prompted / dismissed" locally via
  /// shared_preferences.
  Future<void> setPassword(String password) async {
    if (password.isEmpty) {
      throw const AuthException('Enter a password.');
    }
    await _supabase.auth.updateUser(UserAttributes(password: password));
  }

  /// Send a one-time magic link to the given email.
  ///
  /// Supabase emails a URL of the form
  /// `com.raidme.raidme://login-callback?token=XXX&type=magiclink` which,
  /// when tapped on this device, deep-links into the app and completes
  /// the session via the Supabase SDK's built-in URL handler
  /// (`onAuthStateChange` fires → AuthGate routes to Home).
  ///
  /// Signup and signin collapse into one call: if the email doesn't yet
  /// have an account Supabase creates it and sends the link; if it does,
  /// Supabase sends the link for passwordless sign-in.
  ///
  /// Throws [AuthException] on rate-limit or invalid email. Callers
  /// validate format before calling, so a thrown [AuthException] from
  /// here is almost always Supabase-side (rate-limit / SMTP outage).
  ///
  /// Email is normalised to `trim().toLowerCase()` so case-inconsistent
  /// typing doesn't create duplicate auth users downstream.
  Future<void> sendMagicLink(String email) async {
    final normalized = email.trim().toLowerCase();
    if (normalized.isEmpty || !normalized.contains('@')) {
      throw const AuthException('Enter a valid email address.');
    }
    await _supabase.auth.signInWithOtp(
      email: normalized,
      emailRedirectTo: AppConfig.oauthRedirectUrl,
      shouldCreateUser: true,
    );
  }

  /// Start Google sign-in using the native iOS SDK (google_sign_in v6).
  ///
  /// **Parked behind UI-removal; see `docs/BACKLOG_GOOGLE_SIGNIN.md`.**
  /// As of the progressive-auth upgrade (2026-04-17) the sign-in screen
  /// surfaces only email + password + magic-link. The Google button is
  /// gone from the UI entirely — not hidden behind a "coming soon" badge,
  /// fully removed. This method is kept wired up (and callable via
  /// `AuthService.instance.signInWithGoogle()`) so re-enablement is a
  /// button-add-back operation once the upstream SDK nonce-mismatch fix
  /// lands and Carl decides Google is worth the surface.
  ///
  /// Flow:
  ///   1. Present the system Google account picker via [GoogleSignIn.signIn].
  ///      iOS shows Google's native chooser sheet; the user picks an account.
  ///   2. Grab the ID token + access token from the returned account.
  ///   3. Hand both to Supabase via [SupabaseAuth.signInWithIdToken]. Supabase
  ///      verifies the JWT against its configured Google OAuth client IDs
  ///      (both the web and iOS client IDs must be in the provider's
  ///      "Authorized Client IDs" list in the Supabase dashboard).
  ///
  /// v6 does NOT auto-insert a nonce claim into the id_token — so Supabase
  /// won't demand a raw nonce back. v7 does inject one automatically, without
  /// exposing it to Dart, which made signInWithIdToken impossible; we pinned
  /// this dep to 6.x in pubspec.yaml for exactly that reason.
  ///
  /// Cancellation: [GoogleSignIn.signIn] returns `null` when the user
  /// dismisses the sheet. We treat that as a no-op.
  Future<void> signInWithGoogle() async {
    final account = await _googleSignIn.signIn();
    if (account == null) {
      return; // user dismissed the picker
    }
    final auth = await account.authentication;
    final idToken = auth.idToken;
    final accessToken = auth.accessToken;
    if (idToken == null) {
      throw Exception('Google sign-in did not return an idToken');
    }

    await _supabase.auth.signInWithIdToken(
      provider: OAuthProvider.google,
      idToken: idToken,
      accessToken: accessToken,
    );
  }

  /// Start Apple sign-in using the native iOS SDK.
  ///
  /// **Parked behind UI-removal; see `docs/BACKLOG_GOOGLE_SIGNIN.md`.**
  /// Wired but INTENTIONALLY NOT CALLED from the UI until Carl's Apple
  /// Developer enrolment is approved and the Sign in with Apple capability
  /// is configured in the Supabase dashboard. The sign-in screen no longer
  /// surfaces an Apple button at all — re-enablement means re-adding the
  /// button, not flipping a flag.
  ///
  /// Apple's SDK returns an `identityToken` (JWT) that Supabase verifies
  /// against the Services ID configured as the OAuth client on the Apple
  /// side. No access token is surfaced to the client.
  // ignore: unused_element
  Future<void> signInWithApple() async {
    final credential = await SignInWithApple.getAppleIDCredential(
      scopes: [
        AppleIDAuthorizationScopes.email,
        AppleIDAuthorizationScopes.fullName,
      ],
    );
    final idToken = credential.identityToken;
    if (idToken == null) {
      throw Exception('Apple sign-in did not return an identityToken');
    }
    await _supabase.auth.signInWithIdToken(
      provider: OAuthProvider.apple,
      idToken: idToken,
    );
  }

  /// End the current session. Clears the secure-storage token so the
  /// next app launch will land on the SignInScreen. Also signs out of
  /// the native Google SDK so the next sign-in shows the account picker
  /// fresh (without this, the SDK would silently re-sign the same user).
  Future<void> signOut() async {
    try {
      await _googleSignIn.signOut();
    } catch (e) {
      // If the user never signed in with Google this session, signOut
      // can throw. Harmless — ignore.
      debugPrint('AuthService.signOut: GoogleSignIn.signOut swallowed: $e');
    }
    await _supabase.auth.signOut();
  }

  /// Ensure the signed-in user is a member of at least one practice.
  ///
  /// Idempotent. Safe to call on every `onAuthStateChange` event where
  /// a user is present — returns immediately if the user already has a
  /// membership row.
  ///
  /// Flow:
  ///   1. SELECT from `practice_members` — any row for this user? done.
  ///   2. If not, SELECT the sentinel practice. If `owner_trainer_id IS
  ///      NULL`, UPDATE it with this user (conditional UPDATE — losers
  ///      of the race get 0 rows affected and fall through to step 3)
  ///      and INSERT the membership row as 'owner'.
  ///   3. Otherwise, INSERT a fresh practice named after the user's
  ///      email, INSERT the owner membership, and seed a 5-credit
  ///      welcome bonus in `credit_ledger`.
  ///
  /// Every failure is swallowed with a debugPrint — auth state must
  /// never get stuck because a background write hiccuped.
  Future<void> ensurePracticeMembership() async {
    final user = _supabase.auth.currentUser;
    if (user == null) return;

    try {
      // Step 1: already a member of anything?
      final existing = await _supabase
          .from('practice_members')
          .select('practice_id')
          .eq('trainer_id', user.id)
          .limit(1);
      if (existing.isNotEmpty) {
        return; // returning user, nothing to do
      }

      // Step 2: try to claim the sentinel practice atomically.
      // The UPDATE is conditional on owner_trainer_id being NULL, so
      // only the first caller wins. `select()` after the update returns
      // the rows that were actually changed — empty list = someone else
      // got there first.
      final claimed = await _supabase
          .from('practices')
          .update({'owner_trainer_id': user.id})
          .eq('id', AppConfig.sentinelPracticeId)
          .isFilter('owner_trainer_id', null)
          .select('id');

      if (claimed.isNotEmpty) {
        // Won the claim — add membership row as owner.
        await _supabase.from('practice_members').insert({
          'practice_id': AppConfig.sentinelPracticeId,
          'trainer_id': user.id,
          'role': 'owner',
        });
        debugPrint('AuthService: claimed sentinel practice for ${user.id}');
        return;
      }

      // Step 3: sentinel already owned — create a fresh personal practice.
      final email = user.email ?? 'trainer';
      final name = "${email.split('@').first}'s Practice";
      final insertedPractice = await _supabase
          .from('practices')
          .insert({
            'name': name,
            'owner_trainer_id': user.id,
          })
          .select('id')
          .single();
      final newPracticeId = insertedPractice['id'] as String;

      await _supabase.from('practice_members').insert({
        'practice_id': newPracticeId,
        'trainer_id': user.id,
        'role': 'owner',
      });

      // Seed welcome bonus so the new practice can try publishing before
      // buying credits. Ledger is append-only; balance is derived by
      // summing `amount`.
      await _supabase.from('credit_ledger').insert({
        'practice_id': newPracticeId,
        'amount': AppConfig.welcomeBonusCredits,
        'type': 'adjustment',
        'notes': 'Welcome bonus',
      });

      debugPrint(
        'AuthService: created fresh practice $newPracticeId for ${user.id}',
      );
    } catch (e, stack) {
      // Best-effort — never block the UI on a membership bootstrap failure.
      debugPrint('AuthService.ensurePracticeMembership failed: $e');
      debugPrint('$stack');
    }
  }
}
