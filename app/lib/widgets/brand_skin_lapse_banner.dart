import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../theme.dart';

/// Studio-mounted, read-only lapse banner for the brand-skin
/// subscription (Artifact-system Wave 4 / ADR-0029).
///
/// Renders ONLY while the practice's brand-skin subscription is in its
/// 7-day grace window (past day 30, before day 37). Outside that window
/// the widget renders [SizedBox.shrink] and consumes zero vertical
/// space — practitioners with healthy or fully-lapsed subscriptions
/// don't see any chrome.
///
/// Reader-App compliance:
///   - Banner is informational text only. No tap target, no CTA, no
///     "Renew" button, no mention of price or credits. The practitioner
///     visits `manage.homefit.studio/brand-skin` from a web browser to
///     act on it; the banner's sole job is to surface that the cycle is
///     ending so they remember to.
///
/// Failure modes:
///   - Missing practiceId → SizedBox.shrink (the surface that mounted
///     this banner doesn't know which practice to read; fail-quiet).
///   - RPC error / network blip → SizedBox.shrink (the fallback
///     `BrandSkinState.inactive` resolves in_grace=false; a network
///     blip must not paint a misleading "you're about to lapse"
///     warning).
///
/// Lifecycle:
///   - One fetch on mount. No polling, no listener, no per-second tick.
///     Grace state changes slowly (day-level), so a stale read for the
///     life of a Studio session is acceptable. Practitioners returning
///     to Studio on a fresh launch re-fetch automatically.
class BrandSkinLapseBanner extends StatefulWidget {
  const BrandSkinLapseBanner({super.key, this.practiceId});

  /// Practice context for the state lookup. Optional because some
  /// callers may not have resolved a practice yet; null short-circuits
  /// to [SizedBox.shrink].
  final String? practiceId;

  @override
  State<BrandSkinLapseBanner> createState() => _BrandSkinLapseBannerState();
}

class _BrandSkinLapseBannerState extends State<BrandSkinLapseBanner> {
  BrandSkinState _state = BrandSkinState.inactive;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(BrandSkinLapseBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.practiceId != widget.practiceId) {
      _state = BrandSkinState.inactive;
      _loaded = false;
      _load();
    }
  }

  Future<void> _load() async {
    final practiceId =
        widget.practiceId ?? AuthService.instance.currentPracticeId.value;
    if (practiceId == null || practiceId.isEmpty) {
      if (mounted) setState(() => _loaded = true);
      return;
    }
    try {
      final next = await ApiClient.instance.getBrandSkinState(
        practiceId: practiceId,
      );
      if (mounted) {
        setState(() {
          _state = next;
          _loaded = true;
        });
      }
    } catch (_) {
      // Silent fall-through to the inactive snapshot — see widget docstring.
      if (mounted) setState(() => _loaded = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const SizedBox.shrink();
    if (!_state.inGrace) return const SizedBox.shrink();

    final days = _state.daysUntilLapse ?? 0;
    final dayLabel = days == 1 ? 'day' : 'days';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.12),
        border: Border(
          bottom: BorderSide(
            color: AppColors.primary.withValues(alpha: 0.30),
            width: 1,
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.brush_outlined,
            size: 18,
            color: AppColors.primary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.textOnDark,
                  fontFamily: 'Inter',
                  height: 1.35,
                ),
                children: [
                  TextSpan(
                    text: 'Your brand chrome reverts in $days $dayLabel. ',
                    style: TextStyle(
                      color: AppColors.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const TextSpan(
                    text:
                        'Top up at manage.homefit.studio to keep your brand on every handout.',
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
