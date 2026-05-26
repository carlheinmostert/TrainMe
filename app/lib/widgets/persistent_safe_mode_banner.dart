import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/safe_mode_service.dart';
import '../services/safe_mode_subscription_service.dart';
import '../services/portal_links.dart';
import 'safe_mode_icon.dart';

/// Top-of-app persistent Safe Mode banner — single source of truth for
/// the in-zone communication of Safe Mode.
///
/// Renders ABOVE every route (mounted via [MaterialApp.builder]) and
/// only when [SafeModeService.instance.isActive] — auto OR manual.
/// Returns [SizedBox.shrink] otherwise so the app's normal chrome
/// occupies the full safe area.
///
/// Why top-of-app instead of per-screen: Safe Mode is a privacy
/// promise to the client ("bystanders obscured"). It must remain
/// visible across every route as long as Safe Mode is engaged.
///
/// Visual contract (M21 — 2026-05-26 mobile stack round 3) — replaces
/// both the legacy coral banner AND the compact
/// `SafeModeSubscribeChip`:
///
///   * **Always sage-green** when inside an enforcing premises. The
///     fill (`#3DDC97`), 1px border (`#22C57E`) and soft glow
///     (`rgba(61, 220, 151, 0.55)`) read as the brand's "safe" cue.
///     The colour does NOT change with subscription state — Safe Mode
///     activation is itself the promise; green is for that promise.
///   * Full-width pill, ~14 px radius, ~10 px vertical padding,
///     mounted directly under the iOS status bar.
///   * **Layout:** `[shield badge] [premises name + sub-copy] [right-edge affordance]`.
///   * **Headline:** premises name (e.g. `Manderson Gym`). No
///     truncation — `softWrap: true` allows the second line to flow
///     if needed.
///   * **Not-subscribed state:** sub-copy `Safe Mode required here —
///     tap to subscribe`. Right-edge chevron `›`. Whole banner is
///     tappable → opens the portal `/safe-mode/subscribe` page in an
///     external Safari View Controller (Reader-App compliant, and
///     bypasses the Navigator-above-banner trap that broke the
///     in-app sheet path — see M27 in the 2026-05-26 stack).
///   * **Subscribed-active state:** sub-copy `Safe Mode active —
///     bystanders blurred`. Right-edge dark-circle-with-sage-check
///     badge. Tappable → opens the portal `/safe-mode` manage page
///     in external Safari so the practitioner can cancel / change plan.
///   * **Manual mode** (rare — practitioner opt-in outside any
///     geofence): same green treatment with `Manual · bystanders
///     obscured` copy; tap goes to the manage sheet so they can
///     toggle back to auto.
///
/// Deactivation hysteresis UX:
///   When [SafeModeService.isTrailing] flips to true, the banner
///   stays put with the green treatment. Only the sub-line copy
///   changes to "Leaving {premises} · {N}s" with a per-second
///   countdown. When the threshold hits and the service drops back
///   to `notInZone`, the banner fades from full opacity to 0 over
///   500ms.
///
/// Mounted in [TrainMeApp.builder] inside a `SafeArea(top: true,
/// bottom: false)` so the banner sits below the iOS status bar but
/// the rest of the app's bottom inset behaviour stays untouched.
class PersistentSafeModeBanner extends StatefulWidget {
  const PersistentSafeModeBanner({super.key, this.onTap});

  /// Optional legacy tap callback. Retained for backwards
  /// compatibility with [TrainMeApp.builder]; the banner now handles
  /// taps internally (subscribe paywall OR manage sheet depending on
  /// state). Callers can leave this null.
  final VoidCallback? onTap;

  @override
  State<PersistentSafeModeBanner> createState() =>
      _PersistentSafeModeBannerState();
}

class _PersistentSafeModeBannerState extends State<PersistentSafeModeBanner>
    with WidgetsBindingObserver {
  /// Per-second tick used to refresh the trailing-window countdown.
  /// Only runs while the service reports [SafeModeService.isTrailing]
  /// — the rest of the time the banner is fully static so there's no
  /// repaint pressure. Stopped on dispose + whenever trailing flips
  /// back off.
  Timer? _trailingTick;

  @override
  void initState() {
    super.initState();
    SafeModeService.instance.addListener(_handleServiceChange);
    WidgetsBinding.instance.addObserver(this);
    try {
      SafeModeSubscriptionService.instance.addListener(
        _handleSubscriptionChange,
      );
      // M26 regression guard (2026-05-26 stack round 4) — banner mount
      // should re-evaluate the subscription on every fresh paint so a
      // recently-subscribed practitioner whose cache is stale sees the
      // checkmark variant within ~1s rather than waiting up to an hour
      // for the hourly freshness window. Reuses the same throttled
      // forced-refresh path that `AppLifecycleState.resumed` calls, so
      // rapid re-mounts (hot reload / banner fade in-out) coalesce.
      SafeModeSubscriptionService.instance.refreshThrottled();
    } catch (_) {
      // Service not initialised (unit tests / hot reload edge) —
      // banner just renders the unknown-cache shrink state.
    }
    _syncTrailingTick();
  }

  @override
  void dispose() {
    SafeModeService.instance.removeListener(_handleServiceChange);
    WidgetsBinding.instance.removeObserver(this);
    try {
      SafeModeSubscriptionService.instance.removeListener(
        _handleSubscriptionChange,
      );
    } catch (_) {
      // Service not initialised.
    }
    _trailingTick?.cancel();
    _trailingTick = null;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // M26 regression guard — when the practitioner returns to the
    // foreground after subscribing in the portal, refresh the cached
    // subscription answer so the banner flips to the checkmark variant
    // without waiting for the hourly freshness window. Throttled to
    // 5s in the service so rapid app-switches don't hammer the RPC.
    //
    // The subscription service also installs its OWN lifecycle observer
    // (registered at app launch); the banner installs a second one so
    // the refresh fires whether or not the service singleton was ready
    // when the banner mounted. Throttling makes the duplicate call free.
    if (state == AppLifecycleState.resumed) {
      try {
        SafeModeSubscriptionService.instance.refreshThrottled();
      } catch (_) {
        // Service not initialised — no-op.
      }
    }
  }

  void _handleSubscriptionChange() {
    if (!mounted) return;
    setState(() {});
  }

  /// React to a service state change by starting / stopping the
  /// per-second countdown ticker as appropriate.
  void _handleServiceChange() {
    if (!mounted) return;
    _syncTrailingTick();
  }

  void _syncTrailingTick() {
    final shouldTick = SafeModeService.instance.isTrailing;
    if (shouldTick && _trailingTick == null) {
      _trailingTick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() {});
      });
    } else if (!shouldTick && _trailingTick != null) {
      _trailingTick!.cancel();
      _trailingTick = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: SafeModeService.instance,
      builder: (context, _) {
        final svc = SafeModeService.instance;

        // M21 (2026-05-26 mobile stack round 3) — unified banner.
        // The banner renders whenever Safe Mode is engaged. The prior
        // hide-while-not-subscribed-in-zone branch is gone (the
        // compact chip that replaced it is being retired here); the
        // banner now ALWAYS shows in-zone, with the right-edge
        // affordance + sub-copy reflecting subscription state.
        bool? hasAccess;
        try {
          hasAccess = SafeModeSubscriptionService.instance.hasAccess;
        } catch (_) {
          hasAccess = null;
        }
        final showBanner = svc.isActive;
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 500),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          transitionBuilder: (child, animation) {
            return FadeTransition(
              opacity: animation,
              child: SizeTransition(
                axisAlignment: -1.0,
                sizeFactor: animation,
                child: child,
              ),
            );
          },
          child: showBanner
              ? _buildBanner(context, svc, hasAccess)
              : const SizedBox.shrink(key: ValueKey('safe-mode-banner-empty')),
        );
      },
    );
  }

  /// Sage-green brand fill — the "safe" cue. Same hex across both
  /// subscription states; subscription state only affects the right-
  /// edge affordance + sub-copy.
  static const Color _kSageFill = Color(0xFF3DDC97);
  static const Color _kSageBorder = Color(0xFF22C57E);

  /// Glow alpha ≈ 0.55 → 8 bit value 0x8C; rgba(61, 220, 151, 0.55).
  static const Color _kSageGlow = Color(0x8C3DDC97);

  /// Foreground colour for icon + headline — dark surface tone so
  /// the contrast against the sage fill reads at distance.
  static const Color _kInk = Color(0xFF0F1117);

  Widget _buildBanner(
    BuildContext context,
    SafeModeService svc,
    bool? hasAccess,
  ) {
    final subscribed = hasAccess == true;
    final headline = _buildHeadline(svc);
    final subLine = _buildSubLine(svc, subscribed);

    return Padding(
      key: const ValueKey('safe-mode-banner-active'),
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _onBannerTap(context, subscribed, svc),
          borderRadius: BorderRadius.circular(14),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 10,
            ),
            decoration: BoxDecoration(
              color: _kSageFill,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: _kSageBorder, width: 1),
              boxShadow: const [
                BoxShadow(
                  color: _kSageGlow,
                  offset: Offset(0, 0),
                  blurRadius: 18,
                ),
              ],
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Dark-on-sage shield badge — circle with the shield
                // icon punched in. Read at distance: "safety here".
                _buildShieldBadge(),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        headline,
                        // Headline must not truncate — premises names
                        // can be long ("Manderson Gym & Wellness"
                        // etc.). Allow up to two lines before
                        // ellipsis as a hard floor.
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        softWrap: true,
                        style: const TextStyle(
                          fontFamily: 'Montserrat',
                          color: _kInk,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.2,
                          height: 1.2,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Opacity(
                        opacity: 0.82,
                        child: Text(
                          subLine,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          softWrap: true,
                          style: const TextStyle(
                            fontFamily: 'Inter',
                            color: _kInk,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            height: 1.2,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _buildRightAffordance(subscribed),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Dark-on-sage badge at the left of the banner. A solid dark
  /// circle with the homefit shield icon centred — reads as a unit
  /// rather than a free-floating icon on the sage fill.
  Widget _buildShieldBadge() {
    return Container(
      width: 36,
      height: 36,
      decoration: const BoxDecoration(
        color: _kInk,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: const SafeModeIcon(
        size: 24,
        fillColor: _kSageFill,
        knockoutColor: _kInk,
      ),
    );
  }

  /// Right-edge affordance.
  ///
  ///   * Subscribed → dark circle with sage check inside (positive
  ///     status badge).
  ///   * Not-subscribed → outline-only chevron `›` indicating
  ///     "tap to subscribe".
  Widget _buildRightAffordance(bool subscribed) {
    if (subscribed) {
      return Container(
        width: 28,
        height: 28,
        decoration: const BoxDecoration(
          color: _kInk,
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: const Icon(
          Icons.check,
          size: 18,
          color: _kSageFill,
        ),
      );
    }
    // Not subscribed — chevron read as "more to do here".
    return const Icon(
      Icons.chevron_right,
      color: _kInk,
      size: 28,
    );
  }

  Future<void> _onBannerTap(
    BuildContext context,
    bool subscribed,
    SafeModeService svc,
  ) async {
    HapticFeedback.selectionClick();

    // M27 fix (2026-05-26 stack round 4) — tap opens an external
    // Safari View Controller to the portal subscribe / manage page
    // directly. We deliberately do NOT show an in-app paywall sheet
    // here for two reasons:
    //
    //   1. The banner is mounted ABOVE the Navigator (inside
    //      `MaterialApp.builder`); `showModalBottomSheet` walks the
    //      tree for an ancestor Navigator and finds none, so the sheet
    //      silently fails to open — the previous bug Carl reported as
    //      "tap does nothing".
    //   2. iOS Reader-App compliance (feedback_ios_reader_app) — the
    //      app must not host in-app purchase paths. The portal subscribe
    //      page is the canonical surface for the trial-start /
    //      subscribe flow.
    //
    // The portal honours `?practice=<uuid>` so the practitioner lands
    // in the right tenant; `portalLink` builds the env-aware origin
    // (`staging.manage.homefit.studio` vs `manage.homefit.studio`).
    final uri = subscribed
        ? portalLink('/safe-mode')
        : portalLink('/safe-mode/subscribe');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // Best-effort — if URL launch fails, fall back to the legacy
      // `onTap` callback (the rootScaffoldMessenger snackbar in
      // main.dart) so the practitioner still gets a hint.
    }
    widget.onTap?.call();
    // Refresh the subscription cache after the portal hand-off so the
    // banner picks up the new state the next time the user returns to
    // the app. AppLifecycleState.resumed also triggers a refresh, so
    // this is a belt-and-braces second path.
    try {
      SafeModeSubscriptionService.instance.refreshThrottled();
    } catch (_) {
      // Service not initialised — no-op.
    }
    // Reference svc so the analyzer keeps the parameter (callers may
    // want it for future per-premises deep-links).
    // ignore: unused_local_variable
    final _ = svc;
  }

  /// Headline copy. The premises name takes pride of place; in manual
  /// mode (no premises) we fall back to a generic "Safe Mode" label.
  String _buildHeadline(SafeModeService svc) {
    final trimmed = svc.premisesName.trim();
    final hasName =
        trimmed.isNotEmpty && trimmed.toLowerCase() != 'this venue';
    if (svc.isManual) {
      // Manual mode = practitioner-toggled outside any geofence.
      // No premises name applies; the headline is just "Safe Mode".
      return 'Safe Mode';
    }
    if (hasName) return trimmed;
    return 'Safe Mode';
  }

  /// Sub-line copy. Trailing-window countdown takes precedence over
  /// the resting copy so the practitioner always sees an impending
  /// drop. Subscribed vs not-subscribed sub-copy differs at rest.
  String _buildSubLine(SafeModeService svc, bool subscribed) {
    final trimmed = svc.premisesName.trim();
    final hasName =
        trimmed.isNotEmpty && trimmed.toLowerCase() != 'this venue';

    if (svc.isManual) {
      return 'Manual · bystanders obscured';
    }

    if (svc.isTrailing) {
      final remaining = svc.remainingTrailingSeconds;
      if (hasName) {
        return 'Leaving $trimmed · ${remaining}s';
      }
      return 'Leaving · ${remaining}s';
    }

    if (!subscribed) {
      return 'Safe Mode required here — tap to subscribe';
    }
    return 'Safe Mode active — bystanders blurred';
  }
}
