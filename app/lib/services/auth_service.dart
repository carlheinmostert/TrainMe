import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide Session;
import 'package:supabase_flutter/supabase_flutter.dart' as supa show Session;

import '../config.dart';

/// Thin wrapper around [supabase.auth] that centralises sign-in, sign-out,
/// and the practice-membership bootstrap logic.
///
/// Design goals:
///   - Single source of truth for the OAuth redirect URL and provider set.
///   - The AuthGate watches [authStateChanges] so UI updates automatically.
///   - Membership bootstrap ([ensurePracticeMembership]) runs on every
///     signed-in event but is idempotent and best-effort: a failure here
///     must never brick the app. Worst case the bio signs in with no
///     membership and publishing will surface a clear error later.
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

  /// Start Google OAuth. The actual sign-in completes asynchronously:
  /// the Supabase SDK opens the system browser, the user authenticates,
  /// Google redirects to the Supabase callback URL, and Supabase then
  /// redirects to [AppConfig.oauthRedirectUrl] which deep-links back
  /// into the app. The SDK's internal `app_links` listener picks that
  /// up and flips [authStateChanges].
  ///
  /// Throws if the browser can't be opened. The AuthGate surface should
  /// catch and show a friendly error.
  Future<void> signInWithGoogle() async {
    await _supabase.auth.signInWithOAuth(
      OAuthProvider.google,
      redirectTo: AppConfig.oauthRedirectUrl,
      // inAppBrowserView → SFSafariViewController on iOS. The
      // Goldilocks launch mode for Google OAuth:
      //   • Shares Safari cookies (active Google session just works)
      //   • Follows custom-scheme redirects back to the app without the
      //     iOS 17+ "Open in app?" prompt that full Safari now shows
      //   • Doesn't trip Google's browser-fingerprint block the way
      //     ASWebAuthenticationSession does (white page on accounts.
      //     google.com on first-time use from a real device)
      //   • Stays in-app, no context switch
      authScreenLaunchMode: LaunchMode.inAppBrowserView,
    );
  }

  /// Start Apple OAuth. Wired but INTENTIONALLY NOT CALLED from the UI
  /// until Carl's Apple Developer enrolment is approved and the Services
  /// ID + Sign in with Apple capability are configured in the Supabase
  /// dashboard. The SignInScreen's Apple button is disabled with a
  /// "coming soon" badge; once Apple is ready, flip `_appleEnabled` in
  /// `sign_in_screen.dart` to true and this method becomes live.
  // ignore: unused_element
  Future<void> signInWithApple() async {
    await _supabase.auth.signInWithOAuth(
      OAuthProvider.apple,
      redirectTo: AppConfig.oauthRedirectUrl,
      // inAppBrowserView → SFSafariViewController on iOS. The
      // Goldilocks launch mode for Google OAuth:
      //   • Shares Safari cookies (active Google session just works)
      //   • Follows custom-scheme redirects back to the app without the
      //     iOS 17+ "Open in app?" prompt that full Safari now shows
      //   • Doesn't trip Google's browser-fingerprint block the way
      //     ASWebAuthenticationSession does (white page on accounts.
      //     google.com on first-time use from a real device)
      //   • Stays in-app, no context switch
      authScreenLaunchMode: LaunchMode.inAppBrowserView,
    );
  }

  /// End the current session. Clears the secure-storage token so the
  /// next app launch will land on the SignInScreen.
  Future<void> signOut() async {
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
