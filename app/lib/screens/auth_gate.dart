import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supa show Session;

import '../services/auth_service.dart';
import '../services/local_storage_service.dart';
import '../theme.dart';
import '../widgets/orientation_lock_guard.dart';
import 'home_screen.dart';
import 'sign_in_screen.dart';

/// Root router: listens to Supabase auth state and swaps between
/// [SignInScreen] and [HomeScreen] without any manual navigation.
///
/// - No session yet → SignInScreen.
/// - Session present → HomeScreen (with membership bootstrap running
///   in the background — see [AuthService.ensurePracticeMembership]).
/// - Brief "initialising" state before the first [onAuthStateChange]
///   event arrives → dark loader so the handoff from splash is quiet.
///
/// Session persistence is handled by the Supabase Flutter SDK's default
/// secure storage (Keychain on iOS). Once the user has signed in online
/// at least once, subsequent launches restore the session without a
/// network round-trip — this is what makes the offline-first capture
/// flow viable.
class AuthGate extends StatefulWidget {
  final LocalStorageService storage;

  const AuthGate({super.key, required this.storage});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  StreamSubscription<supa.Session?>? _sub;
  supa.Session? _session;
  bool _initialized = false;

  /// Tracks the last user id we called ensurePracticeMembership for, so we
  /// don't re-run it on every token refresh — `onAuthStateChange` fires for
  /// TOKEN_REFRESHED too, not just sign-in.
  String? _lastBootstrappedUserId;

  @override
  void initState() {
    super.initState();

    // Seed with whatever session already exists (restored from secure
    // storage on cold start). This avoids a one-frame SignInScreen flash
    // when the user is already signed in.
    _session = AuthService.instance.currentSession;
    _initialized = true;

    // Fire membership bootstrap if we booted with an existing session.
    if (_session != null) {
      _bootstrapMembership(_session!.user.id);
    }

    _sub = AuthService.instance.authStateChanges.listen((session) {
      if (!mounted) return;
      setState(() {
        _session = session;
        _initialized = true;
      });
      if (session != null) {
        _bootstrapMembership(session.user.id);
      } else {
        _lastBootstrappedUserId = null;
      }
    });
  }

  void _bootstrapMembership(String userId) {
    if (_lastBootstrappedUserId == userId) return;
    _lastBootstrappedUserId = userId;
    // Fire-and-forget: ensurePracticeMembership swallows its own errors
    // via debugPrint, so we don't need to await or guard here. The home
    // screen renders immediately; membership lands in the background.
    unawaited(AuthService.instance.ensurePracticeMembership());
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return OrientationLockGuard(
      child: Builder(
        builder: (_) {
          if (!_initialized) {
            return const _AuthLoader();
          }
          if (_session == null) {
            return const SignInScreen();
          }
          return HomeScreen(storage: widget.storage);
        },
      ),
    );
  }
}

/// Minimal dark loader shown for the sliver of time between app start and
/// the first auth state resolution.
class _AuthLoader extends StatelessWidget {
  const _AuthLoader();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: AppColors.surfaceBg,
      body: Center(
        child: SizedBox(
          width: 32,
          height: 32,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            valueColor: AlwaysStoppedAnimation(AppColors.primary),
          ),
        ),
      ),
    );
  }
}
