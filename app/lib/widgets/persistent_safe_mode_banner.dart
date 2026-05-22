import 'package:flutter/material.dart';

import '../services/safe_mode_service.dart';
import 'safe_mode_icon.dart';

/// Top-of-app persistent Safe Mode banner.
///
/// Sits ABOVE every route (mounted via [MaterialApp.builder]) and only
/// renders when [SafeModeService.instance.isActive] — auto OR manual.
/// Returns [SizedBox.shrink] otherwise so the app's normal chrome
/// occupies the full safe area.
///
/// Why top-of-app instead of per-screen: Safe Mode is a privacy
/// promise to the client ("bystanders obscured"). It can't be a screen
/// cue that practitioners might miss — it has to be visible across
/// every route as long as Safe Mode is engaged.
///
/// Visual contract (Banner B from `docs/design/mockups/safe-mode-banner.html`):
///   * Coral `#FF6B35` fill, ~44pt tall, rounded corners.
///   * 36px [SafeModeIcon] (dark shield, coral cutouts inverted to
///     dark knockout) on the left.
///   * Two-line label: bold "SAFE MODE ACTIVE" + sub-line with the
///     premises name (auto) or "Manual" (manual override).
///   * Breathing pulse animation — coral brightness gently oscillates
///     between 100% and ~92% over a 2.5s cycle. NOT flashing; subtle.
///   * Tappable — calls [onTap] (typically navigates to the Studio
///     settings sheet Safe Mode row so the practitioner can review +
///     toggle off if manual).
///
/// Mounted in [TrainMeApp.builder] inside a `SafeArea(top: true,
/// bottom: false)` so the banner sits below the iOS status bar but
/// the rest of the app's bottom inset behaviour stays untouched.
class PersistentSafeModeBanner extends StatefulWidget {
  const PersistentSafeModeBanner({
    super.key,
    this.onTap,
  });

  /// Invoked when the banner is tapped. Typically opens the Studio
  /// settings sheet (Safe Mode row), letting the practitioner review
  /// or disengage manual mode. May be null — banner is non-interactive
  /// in that case.
  final VoidCallback? onTap;

  @override
  State<PersistentSafeModeBanner> createState() =>
      _PersistentSafeModeBannerState();
}

class _PersistentSafeModeBannerState extends State<PersistentSafeModeBanner>
    with SingleTickerProviderStateMixin {
  // Subtle breathing pulse: 2.5s cycle, brightness drifts 100% → ~92%
  // → 100%. Tween value goes 0.0 → 1.0; we map to an opacity overlay
  // (or fill colour darken) to avoid a visible "flash" effect.
  late final AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2500),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: SafeModeService.instance,
      builder: (context, _) {
        final svc = SafeModeService.instance;
        if (!svc.isActive) return const SizedBox.shrink();

        // Sub-line copy mirrors `_SafeModeBanner` from the previous
        // in-camera implementation. Drop the leading prefix when the
        // name is empty or the "this venue" fallback.
        final trimmed = svc.premisesName.trim();
        final hasName = trimmed.isNotEmpty
            && trimmed.toLowerCase() != 'this venue';
        final String subLine;
        if (svc.isManual) {
          subLine = 'Manual · bystanders obscured';
        } else if (hasName) {
          subLine = '$trimmed · bystanders obscured';
        } else {
          subLine = 'bystanders obscured';
        }

        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
          child: AnimatedBuilder(
            animation: _pulseController,
            builder: (context, _) {
              // Tween 0.0 → 1.0 (controller auto-reverses every cycle).
              // Map to a subtle coral → coral-dark lerp; brightness
              // ends ~92% at t=1. Not flashing; gentle breathing.
              final t = _pulseController.value;
              final coral = Color.lerp(
                const Color(0xFFFF6B35),
                const Color(0xFFE85A24),
                t,
              )!;

              return Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: widget.onTap,
                  borderRadius: BorderRadius.circular(14),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: coral,
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFFFF6B35).withValues(
                            alpha: 0.40,
                          ),
                          offset: const Offset(0, 6),
                          blurRadius: 18,
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        const SafeModeIcon(
                          size: 36,
                          knockoutColor: Color(0xFF0F1117),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'SAFE MODE ACTIVE',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontFamily: 'Montserrat',
                                  color: Color(0xFF0F1117),
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.4,
                                  height: 1.2,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Opacity(
                                opacity: 0.78,
                                child: Text(
                                  subLine,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontFamily: 'Inter',
                                    color: Color(0xFF0F1117),
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    height: 1.2,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}
