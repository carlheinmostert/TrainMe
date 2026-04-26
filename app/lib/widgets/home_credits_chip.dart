import 'dart:developer' as dev;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/auth_service.dart';
import '../services/portal_links.dart';
import '../services/sync_service.dart';
import '../theme.dart';

/// Glanceable credit-balance pill for Home. Sits right-aligned in the
/// same row as [PracticeChip] so the practitioner can see at a glance
/// "this practice has N credits left" without drilling into Settings.
///
/// Wave 29 — replaces the Settings-only Credit Balance row as the first-
/// surface affordance. The Settings row still exists (richer copy +
/// sync-age hint); this chip is the at-a-glance anchor.
///
/// Behaviour:
///   - Reads the active practice id from [AuthService.currentPracticeId].
///   - Reads balance from [SyncService.creditBalances] — that notifier
///     is seeded from `cached_credit_balance` at boot, refreshed by
///     [SyncService.pullAll], and updated locally by
///     [SyncService.refreshCreditBalance] after a publish so the number
///     ticks down without a manual refresh.
///   - Tap → launches `manage.homefit.studio/credits?practice=<uuid>`
///     in the external browser. The portal middleware honours the
///     query param so the practitioner lands in the same practice they
///     were just viewing in the app.
///
/// Visual: small dark coral pill (`brandTintBg` border, coral icon +
/// number, ink-dark text) — matches the [PracticeChip]'s aesthetic so
/// the two read as peers in the identity row.
class HomeCreditsChip extends StatelessWidget {
  const HomeCreditsChip({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: AuthService.instance.currentPracticeId,
      builder: (context, practiceId, _) {
        if (practiceId == null || practiceId.isEmpty) {
          return const SizedBox.shrink();
        }
        return ValueListenableBuilder<Map<String, int?>>(
          valueListenable: SyncService.instance.creditBalances,
          builder: (context, balances, _) {
            final balance = balances[practiceId];
            return _CreditsChipVisual(
              balance: balance,
              onTap: () => _onTap(context, practiceId),
            );
          },
        );
      },
    );
  }

  Future<void> _onTap(BuildContext context, String practiceId) async {
    HapticFeedback.selectionClick();
    final uri = portalLink('/credits', practiceId: practiceId);
    // Diagnostic — Wave 30 #8 chased "lands on home" intermittently;
    // keep this line so a fresh repro can be confirmed against the
    // actual outbound URL the launcher receives.
    dev.log('home_credits_chip launch -> $uri', name: 'homefit.chip');
    bool launched = false;
    try {
      launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      launched = false;
    }
    if (!launched && context.mounted) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text(
              "Couldn't open the portal. Try again shortly.",
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 14,
                color: AppColors.textOnDark,
              ),
            ),
            backgroundColor: AppColors.surfaceRaised,
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 3),
          ),
        );
    }
  }
}

class _CreditsChipVisual extends StatelessWidget {
  final int? balance;
  final VoidCallback onTap;

  const _CreditsChipVisual({required this.balance, required this.onTap});

  @override
  Widget build(BuildContext context) {
    // Loading state: render the pill so the row's right edge doesn't
    // jump once the cache lands. A single muted "—" is the lightest
    // hint that the slot is reserved.
    final label = balance == null ? '—' : '$balance';
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: AppColors.brandTintBg,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: AppColors.brandTintBorder,
              width: 1,
            ),
            // Faint elevation cue so it reads as interactive without
            // shouting — matches the rest of the dark-on-dark chrome.
            boxShadow: const [
              BoxShadow(
                color: Color(0x33000000),
                blurRadius: 4,
                offset: Offset(0, 1),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.toll_rounded,
                size: 14,
                color: AppColors.primary,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textOnDark,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
