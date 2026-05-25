import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/api_client.dart';
import '../theme.dart';

/// One-time intro banner announcing the Self-trainer wave on Home.
///
/// Shown on the first cold launch after the self-trainer wave lands, until
/// the practitioner taps the dismiss affordance. Backed by a single
/// [SharedPreferences] bool key — per-device, not per-user, matching the
/// pattern used by `_GettingStartedBanner` and the other onboarding
/// affordances in this app.
///
/// The banner has two copy layers:
///   1. A universal headline + body shown to everyone.
///   2. A grandfathered-extension line, shown ONLY when the signed-in
///      user has `practice_members.safe_mode_grandfathered = true` on any
///      of their practices (set by the self-trainer wave's PR #1
///      migration backfill for any practitioner who has ever captured a
///      Safe Mode exercise).
///
/// Copy is `[carl-review:]` bracketed and MUST be wordsmithed by Carl
/// before merge — these are intentionally stiff placeholder strings.
///
/// Design rules honoured:
///  - R-01 no modals: dismiss is a tap, not a confirmation sheet.
///  - R-09 obvious defaults: single primary "Got it" affordance.
///  - R-06 voice: "practitioner" / "Safe Mode" / "My Workouts" — no
///    "user" / "client" misuse in the few user-facing strings.
///
/// Aesthetic: leans on the same coral-tinted accent border the
/// `_GettingStartedBanner` uses so the two onboarding affordances feel
/// related when they happen to co-exist briefly post-update.
class SelfTrainerIntroBanner extends StatefulWidget {
  const SelfTrainerIntroBanner({super.key});

  /// SharedPreferences key. v1 suffix lets us trigger a re-show later by
  /// bumping the suffix if the copy meaningfully changes — mirrors the
  /// `getting_started_banner_seen_v1` convention.
  static const String prefsKey = 'self_trainer_intro_dismissed';

  @override
  State<SelfTrainerIntroBanner> createState() => _SelfTrainerIntroBannerState();
}

class _SelfTrainerIntroBannerState extends State<SelfTrainerIntroBanner> {
  /// Tri-state during the initial async checks:
  ///   - null: still loading the dismiss flag / grandfathered status.
  ///   - false: already dismissed; render nothing.
  ///   - true: render the banner.
  ///
  /// Default false so we don't flash on every launch for users who've
  /// already dismissed — the async load promotes to true only when both
  /// checks pass.
  bool _visible = false;

  /// Whether the grandfathered-extension line should be appended. Resolved
  /// in [initState] alongside the dismiss flag so the banner has its full
  /// content before its first paint (no copy reshuffle after mount).
  bool _grandfathered = false;

  @override
  void initState() {
    super.initState();
    _loadState();
  }

  Future<void> _loadState() async {
    bool dismissed = true;
    bool grandfathered = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      dismissed = prefs.getBool(SelfTrainerIntroBanner.prefsKey) ?? false;
    } catch (_) {
      // SharedPreferences failure is exceptionally rare. Treat as
      // "dismissed" so we don't flash a re-show on every launch.
      dismissed = true;
    }
    if (!dismissed) {
      // Only spend the round-trip when we're actually going to render —
      // grandfathered users are a small minority and the call has a
      // non-zero cost on slow networks.
      grandfathered = await ApiClient.instance
          .isCurrentUserSafeModeGrandfathered();
    }
    if (!mounted) return;
    setState(() {
      _visible = !dismissed;
      _grandfathered = grandfathered;
    });
  }

  Future<void> _markDismissed() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(SelfTrainerIntroBanner.prefsKey, true);
    } catch (_) {
      // Best-effort. The in-memory flip below hides the banner for this
      // session even if the write didn't land; next launch will retry.
    }
  }

  Future<void> _onDismiss() async {
    HapticFeedback.selectionClick();
    await _markDismissed();
    if (!mounted) return;
    setState(() => _visible = false);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      alignment: Alignment.topCenter,
      child: !_visible
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
              child: Container(
                padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.primary, width: 1),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 2),
                      child: Icon(
                        Icons.celebration_outlined,
                        size: 22,
                        color: AppColors.primary,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // [carl-review:] HEADLINE
                          const Text(
                            'My Workouts is live',
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textOnDark,
                            ),
                          ),
                          const SizedBox(height: 4),
                          // [carl-review:] UNIVERSAL BODY
                          const Text(
                            'Capture yourself, get plans '
                            'from your practitioner — all in one place.',
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 13,
                              fontWeight: FontWeight.w400,
                              color: AppColors.textOnDark,
                              height: 1.4,
                            ),
                          ),
                          if (_grandfathered) ...[
                            const SizedBox(height: 6),
                            // [carl-review:] GRANDFATHERED-EXTENSION LINE
                            const Text(
                              'Safe Mode is now a '
                              "subscription. Because you've used it, "
                              "we've extended your access for free — "
                              'no action needed.',
                              style: TextStyle(
                                fontFamily: 'Inter',
                                fontSize: 13,
                                fontWeight: FontWeight.w400,
                                color: AppColors.textSecondaryOnDark,
                                height: 1.4,
                              ),
                            ),
                          ],
                          const SizedBox(height: 8),
                          // Primary affordance — coral text button, no
                          // heavy filled background. R-01: dismiss is a
                          // tap, not a confirmation.
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton(
                              onPressed: _onDismiss,
                              style: TextButton.styleFrom(
                                foregroundColor: AppColors.primary,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 6,
                                ),
                                minimumSize: const Size(0, 32),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                              child: const Text(
                                'Got it',
                                style: TextStyle(
                                  fontFamily: 'Inter',
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Secondary affordance — the × dismiss in case the
                    // practitioner doesn't notice the "Got it" button.
                    // Same handler so both routes mark dismissed.
                    IconButton(
                      onPressed: _onDismiss,
                      icon: const Icon(
                        Icons.close,
                        size: 18,
                        color: AppColors.textSecondaryOnDark,
                      ),
                      tooltip: 'Dismiss',
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(
                        minWidth: 36,
                        minHeight: 36,
                      ),
                      padding: EdgeInsets.zero,
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
