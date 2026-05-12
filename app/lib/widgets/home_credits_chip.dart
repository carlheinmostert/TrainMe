import 'package:flutter/material.dart';

import '../config.dart';
import '../services/auth_service.dart';
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
/// **Apple Reader-App compliance (App Store Review Guideline 3.1.1).**
/// This widget is **informational only** — it never opens a payment page,
/// never opens the practice manager, never carries a tappable link. The
/// Reader-App pattern (Spotify, Netflix, Kindle) permits showing account
/// state inside the iOS app but disallows any in-app affordance that
/// nudges the user toward an external purchase flow. Concretely:
///
///   - When `balance > 0` we show the count as a static pill (no `onTap`).
///   - When `balance == 0` we expand to a plain-text sentence reading
///     "You're out of credits. Top up at manage.homefit.studio when
///     you're at your computer." — the URL renders as plain text, NOT a
///     hyperlink, NOT a button. Reviewers consistently accept this
///     phrasing because it's read-aloud copy and not a tappable
///     redirect to a payment page.
///
/// Behaviour:
///   - Reads the active practice id from [AuthService.currentPracticeId].
///   - Reads balance from [SyncService.creditBalances] — that notifier
///     is seeded from `cached_credit_balance` at boot, refreshed by
///     [SyncService.pullAll], and updated locally by
///     [SyncService.refreshCreditBalance] after a publish so the number
///     ticks down without a manual refresh.
///
/// Visual: small dark coral pill (`brandTintBg` border, coral icon +
/// number, ink-dark text) — matches the [PracticeChip]'s aesthetic so
/// the two read as peers in the identity row. Zero-balance state breaks
/// out of the pill into a wider plain-text line so it can carry the
/// full sentence without truncating.
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
            // Zero-balance state: replace the count pill with a
            // plain-text sentence. Per the Reader-App rule the URL is
            // NOT a hyperlink — it reads as flat copy so the
            // practitioner's expected workflow is "switch to the
            // laptop and visit the URL there", not "tap here".
            if (balance == 0) {
              return const _OutOfCreditsLine();
            }
            return _CreditsChipVisual(balance: balance);
          },
        );
      },
    );
  }
}

class _CreditsChipVisual extends StatelessWidget {
  final int? balance;

  const _CreditsChipVisual({required this.balance});

  @override
  Widget build(BuildContext context) {
    // Loading state: render the pill so the row's right edge doesn't
    // jump once the cache lands. A single muted "—" is the lightest
    // hint that the slot is reserved.
    final label = balance == null ? '—' : '$balance';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: AppColors.brandTintBg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: AppColors.brandTintBorder,
          width: 1,
        ),
        // Faint elevation cue keeps the pill readable on dark; this is
        // not an interactive surface anymore (Reader-App compliance —
        // no tap target) but the shadow still anchors it visually.
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
    );
  }
}

/// Plain-text zero-balance line. Reader-App rule: when the practitioner
/// has no credits, we MAY tell them where to top up — but only as
/// non-interactive copy. The URL is a string of characters, not a
/// hyperlink, not an `InkWell`, not wrapped in `launchUrl`. If the
/// reviewer or a curious tester taps it nothing happens — exactly the
/// behaviour the guideline expects.
///
/// Layout note: the call site wraps this inside a `Row` and we can't
/// rely on `Flexible` here because [HomeCreditsChip] is several
/// `ValueListenableBuilder`s deep — `ParentDataWidget` only applies
/// when it's a direct child of the `Flex`. Instead we cap the width
/// with a `ConstrainedBox` so the sentence wraps to two lines on
/// narrow phones without overflowing the row.
class _OutOfCreditsLine extends StatelessWidget {
  const _OutOfCreditsLine();

  @override
  Widget build(BuildContext context) {
    // A12 (HARDCODED-AUDIT-2026-05-12) — derive the displayed portal host
    // from AppConfig.portalOrigin so a staging build's copy reads
    // "staging.manage.homefit.studio". The string is non-interactive
    // (Reader-App compliance — no tap target, no "Buy", no prices); we
    // just keep the host accurate to the build env.
    final displayHost =
        AppConfig.portalOrigin.replaceFirst(RegExp(r'^https?://'), '');
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 220),
      child: Text(
        "You're out of credits. Top up at $displayHost "
        "when you're at your computer.",
        textAlign: TextAlign.right,
        style: const TextStyle(
          fontFamily: 'Inter',
          fontSize: 12,
          height: 1.35,
          fontWeight: FontWeight.w500,
          color: AppColors.textSecondaryOnDark,
        ),
      ),
    );
  }
}
