import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../theme.dart';

/// Wave 15 — Session-expired banner.
///
/// Surfaces [AuthService.sessionExpired] as a coral banner with a
/// "Sign in" CTA. Non-blocking per R-01: reads continue from the
/// SQLite cache and writes queue locally via the pending-ops loop;
/// this banner is the visible recovery hint, nothing more.
///
/// Rendered at the top of the main Home + Studio scaffolds (so the
/// practitioner sees it regardless of which mode they're in when the
/// revocation is detected). Returns [SizedBox.shrink] when the flag is
/// false so it stays out of the way on the happy path.
///
/// Tap dispatches to [onSignIn] which the host screen implements —
/// typically signs out via [AuthService.signOut], which lets the
/// AuthGate route the user back to the sign-in screen. Once the user
/// re-authenticates, `onAuthStateChange(signedIn)` fires and
/// [AuthService.sessionExpired] clears → this banner vanishes on the
/// next frame.
class SessionExpiredBanner extends StatelessWidget {
  /// Called when the user taps the CTA. Typical implementation: call
  /// [AuthService.signOut] so the AuthGate swaps to [SignInScreen].
  final VoidCallback onSignIn;

  const SessionExpiredBanner({super.key, required this.onSignIn});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: AuthService.instance.sessionExpired,
      builder: (context, expired, _) {
        if (!expired) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Container(
            decoration: BoxDecoration(
              color: AppColors.surfaceBase,
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              border: Border.all(
                color: AppColors.primary.withValues(alpha: 0.45),
                width: 1.2,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 4,
                  height: 60,
                  decoration: const BoxDecoration(
                    color: AppColors.primary,
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(8),
                      bottomLeft: Radius.circular(8),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                const Icon(
                  Icons.lock_outline_rounded,
                  color: AppColors.primary,
                  size: 22,
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Your session expired',
                          style: TextStyle(
                            fontFamily: 'Montserrat',
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textOnDark,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'Please sign in again to continue syncing.',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 12,
                            color: AppColors.textSecondaryOnDark,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: FilledButton(
                    onPressed: onSignIn,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      shape: RoundedRectangleBorder(
                        borderRadius:
                            BorderRadius.circular(AppTheme.radiusSm),
                      ),
                      textStyle: const TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    child: const Text('Sign in'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
