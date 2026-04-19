import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide Session;
import 'package:supabase_flutter/supabase_flutter.dart' as supa show Session;

import '../config.dart';
import 'api_client.dart';

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

  /// Data-access seam. Every Supabase call in this service routes through
  /// [ApiClient] so the allowed surface is enumerated in one place
  /// (see `docs/DATA_ACCESS_LAYER.md`). The native OAuth flows
  /// (Google / Apple) hand their provider-specific id_tokens to
  /// [ApiClient.signInWithIdToken]; there is no longer a need for a
  /// `SupabaseClient` reference in this file.
  ApiClient get _api => ApiClient.instance;

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
  supa.Session? get currentSession => _api.currentSession;

  /// Convenience — the authenticated user's uuid, or null.
  String? get currentUserId => _api.currentUserId;

  /// Broadcasts every auth-state change. The AuthGate listens here.
  /// Emits the full [supa.Session] (nullable) so subscribers can tell
  /// signed-in from signed-out without an extra lookup.
  Stream<supa.Session?> get authStateChanges => _api.authStateChanges;

  /// Set (or change) the password on the currently authenticated user.
  ///
  /// Requires an active session — call this only from a post-sign-in
  /// context (e.g. the Settings screen, or the one-time "Set a password?"
  /// prompt on Home). The next time the user signs in, a password-based
  /// sign-in flow with this password will succeed.
  ///
  /// Supabase doesn't expose whether a user has a password set (security),
  /// so we don't persist a server-side flag here — the Settings UI just
  /// offers "Set or change password" without attempting to detect state.
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
    await _api.sendMagicLink(
      email: normalized,
      emailRedirectTo: AppConfig.oauthRedirectUrl,
      shouldCreateUser: true,
    );
  }

  /// Start Google sign-in using the native iOS SDK (google_sign_in v6).
  ///
  /// **Parked behind a `Coming soon` badge on the sign-in screen** as of
  /// 2026-04-17 — the iOS GoogleSignIn 8.x SDK injects a nonce claim that
  /// Supabase's `signInWithIdToken` rejects (see
  /// `docs/BACKLOG_GOOGLE_SIGNIN.md` for the full post-mortem). This method
  /// is kept wired up so re-enablement is a one-line UI flip
  /// (`_googleEnabled = true` in `sign_in_screen.dart`) once upstream
  /// fixes land.
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

    await _api.signInWithIdToken(
      provider: OAuthProvider.google,
      idToken: idToken,
      accessToken: accessToken,
    );
  }

  /// Start Apple sign-in using the native iOS SDK. Wired but INTENTIONALLY
  /// NOT CALLED from the UI until Carl's Apple Developer enrolment is
  /// approved and the Sign in with Apple capability is configured in the
  /// Supabase dashboard. The SignInScreen's Apple button is disabled with
  /// a "coming soon" badge; once Apple is ready, flip `_appleEnabled` in
  /// `sign_in_screen.dart` to true and this method becomes live.
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
    await _api.signInWithIdToken(
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
    await _api.signOut();
    currentPracticeId.value = null;
    bootstrapError.value = null;
  }

  /// Notifier for the last bootstrap-membership error, or null on success.
  /// The HomeScreen binds a banner to this so the user can retry a failed
  /// bootstrap instead of silently landing in a broken state (previously
  /// the failure was swallowed with a debugPrint, which meant an
  /// offline/RLS/network hiccup could leave a user with no practice
  /// membership and no way to publish, with nothing on screen explaining
  /// why).
  final ValueNotifier<String?> bootstrapError = ValueNotifier<String?>(null);

  /// The signed-in user's primary practice id, as returned by the most
  /// recent successful [ensurePracticeMembership] call.
  ///
  /// Populated by the `bootstrap_practice_for_user` SECURITY DEFINER RPC,
  /// so this is always the server's view of the user's own practice (not
  /// a client-picked tenant). Safe to use as a fallback when a locally
  /// created Session has no practiceId of its own — e.g. sessions created
  /// before the practice_id wiring landed, or future flows where the
  /// session is drafted offline.
  final ValueNotifier<String?> currentPracticeId =
      ValueNotifier<String?>(null);

  /// Ensure the signed-in user is a member of at least one practice.
  ///
  /// Idempotent. Safe to call on every `onAuthStateChange` event where a
  /// user is present. Delegates to the `bootstrap_practice_for_user`
  /// SECURITY DEFINER RPC, which folds the former three-step client flow
  /// (check membership → claim sentinel → create fresh practice) into a
  /// single atomic server-side call.
  ///
  /// On success [bootstrapError] is cleared. On failure the exception
  /// string is surfaced via [bootstrapError] so the HomeScreen banner can
  /// offer a Retry affordance. We still debugPrint the failure; the
  /// ValueNotifier is additive, not a replacement.
  Future<void> ensurePracticeMembership() async {
    final userId = _api.currentUserId;
    if (userId == null) return;

    try {
      final practiceId = await _api.bootstrapPracticeForUser();
      currentPracticeId.value = practiceId;
      bootstrapError.value = null;
      debugPrint(
        'AuthService: bootstrap returned practice $practiceId for $userId',
      );
    } catch (e, stack) {
      // Best-effort — never block the UI on a membership bootstrap failure,
      // but now the UI has a signal via [bootstrapError] and can offer a
      // manual Retry. See home_screen._BootstrapErrorBanner.
      bootstrapError.value = e.toString();
      debugPrint('AuthService.ensurePracticeMembership failed: $e');
      debugPrint('$stack');
    }
  }
}
