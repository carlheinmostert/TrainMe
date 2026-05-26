import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/portal_links.dart';
import '../services/safe_mode_service.dart';
import '../services/safe_mode_subscription_service.dart';
import 'safe_mode_icon.dart';

/// Compact right-aligned coral chip surfaced under the Home AppBar when
/// the practitioner is inside an enforcing Safe Mode premises WITHOUT
/// an active Safe Mode subscription.
///
/// Stack item M10 (2026-05-25 mobile stack) — replaces the prior full-
/// width orange banner ("SAFE MODE ACTIVE … subscribe to capture here")
/// which ate ~95 px of vertical real estate on iPhone 16e and
/// truncated both copy lines (`SA…` / `Man…`) because the internal pill
/// consumed too much width. Carl picked Option 2 from
/// `docs/design/mockups/2026-05-25-safe-mode-banner-compaction.html` —
/// a discreet chip aligned RIGHT, ~24 px tall, positioned just below
/// the AppBar (above the My Workouts / Clients / Classes capsule strip).
///
/// Visibility rule (unchanged from the legacy banner):
///   * `SafeModeService.instance.isActive` is true (the practitioner is
///     inside an enforcing polygon — auto-mode; manual mode is
///     intentionally excluded since manual implies the practitioner is
///     OUT of geofence so the "subscribe to capture here" pitch is
///     misleading).
///   * `SafeModeSubscriptionService.instance.hasAccess` is `false`
///     (cache-known, no active subscription). When `null` (cache cold)
///     the chip stays hidden — we don't flash a misleading state.
///
/// The chip disappears the moment EITHER:
///   * the subscription cache flips to `true` (purchase completes), or
///   * `SafeModeService.isActive` flips to false (practitioner leaves
///     the geofence).
///
/// Premises name is intentionally NOT surfaced in the chip — it lives
/// behind the tap (the paywall sheet shows it in the body) per Carl's
/// signoff on the mockup. Keeps the chip narrow enough to never
/// truncate.
///
/// Tap deep-links to the portal `/safe-mode/subscribe` page in external
/// Safari. Reader-App compliant: copy says where to subscribe, no
/// in-app purchase button.
///
/// Mobile-only per `feedback_consumption_vs_config_surfaces.md` — the
/// web portal isn't a Safe Mode capture surface, so no R-10 twin is
/// required.
class SafeModeSubscribeChip extends StatefulWidget {
  const SafeModeSubscribeChip({super.key});

  @override
  State<SafeModeSubscribeChip> createState() => _SafeModeSubscribeChipState();
}

class _SafeModeSubscribeChipState extends State<SafeModeSubscribeChip> {
  @override
  void initState() {
    super.initState();
    SafeModeService.instance.addListener(_onChange);
    try {
      SafeModeSubscriptionService.instance.addListener(_onChange);
      // Kick a cache refresh on mount so the chip resolves to its true
      // state on first paint after a cold launch. No-op when the cache
      // is already fresh.
      SafeModeSubscriptionService.instance.refreshIfStale();
    } catch (_) {
      // Service not initialised (unit tests / hot reload edge) — chip
      // just renders the cold-cache shrink state below.
    }
  }

  @override
  void dispose() {
    SafeModeService.instance.removeListener(_onChange);
    try {
      SafeModeSubscriptionService.instance.removeListener(_onChange);
    } catch (_) {
      // Service not initialised.
    }
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  Future<void> _onTap() async {
    HapticFeedback.selectionClick();
    try {
      await launchUrl(
        portalLink('/safe-mode/subscribe'),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      // Silent — capture-entry gate is the load-bearing path; this is
      // a convenience nudge. The paywall sheet on the camera screen
      // already covers the load-bearing CTA when the practitioner
      // tries to capture without a sub.
    }
  }

  @override
  Widget build(BuildContext context) {
    // Render-gate evaluation: in-zone AND known-not-subscribed.
    final svc = SafeModeService.instance;
    if (!svc.isActive) return const SizedBox.shrink();
    // Auto-mode only — manual mode is the practitioner OPTING IN to Safe
    // Mode outside any geofence; the "subscribe to capture here" pitch
    // doesn't apply.
    if (svc.isManual) return const SizedBox.shrink();

    bool? hasAccess;
    try {
      hasAccess = SafeModeSubscriptionService.instance.hasAccess;
    } catch (_) {
      // Service not initialised — render nothing.
      return const SizedBox.shrink();
    }
    // Null cache → don't paint a misleading state. The cache refresh
    // fired in initState will resolve and trigger another build.
    if (hasAccess == null) return const SizedBox.shrink();
    if (hasAccess) return const SizedBox.shrink();

    return Padding(
      // Right-aligned per the mockup; the right padding mirrors the
      // brand-lockup horizontal padding so the chip sits under the
      // settings gear visually. Vertical padding shrinks the chip's
      // footprint to ~24 px (was ~95 px for the legacy banner).
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _onTap,
              borderRadius: BorderRadius.circular(999),
              child: Container(
                // Asymmetric horizontal padding (10 left for the icon, 12
                // right for the arrow) keeps the chip compact while the
                // larger icon (M16: bumped 14 → 28 px) gets enough breath
                // not to crowd the text. Vertical padding stays at 6 px
                // — the icon is square so it drives total chip height to
                // ~40 px (was ~26 px). Still well under the legacy 95 px
                // banner and reads at typical iPhone viewing distance.
                padding: const EdgeInsets.fromLTRB(10, 6, 12, 6),
                decoration: BoxDecoration(
                  color: const Color(0xFFFF6B35),
                  borderRadius: BorderRadius.circular(999),
                  boxShadow: const [
                    BoxShadow(
                      // ~35% coral glow per the mockup `var(--coral-glow)`.
                      color: Color(0x59FF6B35),
                      offset: Offset(0, 0),
                      blurRadius: 12,
                    ),
                  ],
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SafeModeIcon(
                      // M16 (2026-05-25 mobile stack): bumped from 14 to
                      // 28 px because the 14-px shield was illegible at
                      // typical iPhone viewing distance — the entire
                      // chip's first read was just "coral pill with
                      // text"; the safety affordance only resolved on
                      // close inspection. 28 px is ~2x bigger and
                      // approximately matches the body text x-height
                      // visually weighted, so the icon now carries its
                      // intended "shield + figures" signal.
                      size: 28,
                      // Dark knockout on coral matches the persistent-banner
                      // icon treatment for visual continuity.
                      knockoutColor: Color(0xFF0F1117),
                    ),
                    SizedBox(width: 8),
                    Text(
                      'Subscribe to capture here',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        color: Color(0xFF0F1117),
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        height: 1.1,
                      ),
                    ),
                    SizedBox(width: 4),
                    Text(
                      '→',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        color: Color(0xFF0F1117),
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        height: 1.1,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
