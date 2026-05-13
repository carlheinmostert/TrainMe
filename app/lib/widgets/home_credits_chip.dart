import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

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
/// This widget never opens a payment page, never carries a price, never
/// nudges the user toward an external purchase flow. The Reader-App
/// pattern (Spotify, Netflix, Kindle) permits showing account state
/// inside the iOS app and permits *informational* links explaining how
/// the account model works — what it disallows is in-app affordances
/// that funnel users into an external buy flow. Concretely:
///
///   - When `balance > 0` we show the count as a static, non-tappable
///     pill (no `onTap`).
///   - When `balance == 0` we surface a **filled coral pill** containing
///     a bold white `0` and a small `?` glyph. Tapping the `?` opens an
///     **informational** help article at `{portalOrigin}/help/credits`
///     in Safari View Controller. The article explains what credits are
///     and what happens when you run out — it has no "Buy" CTA, shows
///     no prices, and never funnels into a purchase flow. Reviewers
///     consistently accept informational explainer pages; what they
///     reject is anything that reads as a buy nudge.
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
/// the two read as peers in the identity row. The zero-balance state
/// breaks visual convention with a **filled** coral pill so it pulls
/// the eye — credits at zero is the only state the practitioner needs
/// to act on.
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
            // Zero-balance state: switch to a filled coral pill with a
            // bold "0" and a help glyph. The glyph opens an
            // informational explainer page (Reader-App compliant — no
            // prices, no buy CTA).
            if (balance == 0) {
              return const _OutOfCreditsPill();
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

/// Out-of-credits state: a **filled coral pill** containing a bold
/// white `0` and a small `?` glyph. Visually distinct from the
/// non-zero pill so it pulls the eye — running out of credits is the
/// one state the practitioner needs to act on.
///
/// The `?` is the affordance — tapping anywhere on the pill opens the
/// help article at `{portalOrigin}/help/credits` in Safari View
/// Controller (in-app browser). The article is **informational only**:
/// it explains what credits are and what happens when you run out, and
/// has zero purchase CTAs / prices (Apple Guideline 3.1.1 — see
/// `feedback_ios_reader_app.md`).
///
/// Polish: one-shot fade-in on first render. No looping animation; a
/// pulsing pill would feel like an aggressive nag.
class _OutOfCreditsPill extends StatefulWidget {
  const _OutOfCreditsPill();

  @override
  State<_OutOfCreditsPill> createState() => _OutOfCreditsPillState();
}

class _OutOfCreditsPillState extends State<_OutOfCreditsPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fadeCtrl;
  late final Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    _fade = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut);
    // Fire-and-forget; one-shot.
    _fadeCtrl.forward();
  }

  @override
  void dispose() {
    _fadeCtrl.dispose();
    super.dispose();
  }

  Future<void> _openHelp() async {
    final uri = Uri.parse('${AppConfig.portalOrigin}/help/credits');
    bool launched = false;
    try {
      launched = await launchUrl(
        uri,
        mode: LaunchMode.inAppBrowserView,
      );
    } catch (_) {
      launched = false;
    }
    if (!launched) {
      try {
        launched = await launchUrl(
          uri,
          mode: LaunchMode.externalApplication,
        );
      } catch (_) {
        launched = false;
      }
    }
    if (!launched && mounted) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text(
              "Couldn't open the help page. Try again shortly.",
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 14,
                color: AppColors.textOnDark,
              ),
            ),
            duration: Duration(seconds: 3),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: Semantics(
        button: true,
        label: 'Out of credits. Tap to learn more.',
        child: Material(
          color: Colors.transparent,
          // Slightly larger radius than the normal chip (which uses
          // 999/pill) — same circular shape, but the filled state +
          // bolder content makes it read as visually distinct without
          // changing geometry.
          borderRadius: BorderRadius.circular(999),
          child: InkWell(
            onTap: _openHelp,
            borderRadius: BorderRadius.circular(999),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 6,
              ),
              decoration: BoxDecoration(
                color: AppColors.primary,
                borderRadius: BorderRadius.circular(999),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x33000000),
                    blurRadius: 4,
                    offset: Offset(0, 1),
                  ),
                ],
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '0',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      height: 1.0,
                    ),
                  ),
                  SizedBox(width: 6),
                  Icon(
                    Icons.help_outline_rounded,
                    size: 16,
                    color: Colors.white,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
