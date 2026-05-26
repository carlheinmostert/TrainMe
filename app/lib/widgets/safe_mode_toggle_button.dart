import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/safe_mode_service.dart';
import '../theme.dart';
import 'safe_mode_icon.dart';

/// First-class Safe Mode toggle for the Home screen header.
///
/// Three-state visual + behaviour, all driven from the singleton
/// [SafeModeService]:
///
/// 1. **Off** (`!svc.isActive`): icon rendered in default muted /
///    monochrome white, no border. Tap → [SafeModeService.forceActive]
///    so the practitioner opts into manual Safe Mode (and the
///    persistent banner appears).
///
/// 2. **Manual active** (`svc.isActive && svc.isManual`): icon shown
///    coral-filled with a subtle coral border so the toggle reads as
///    "on, my choice". Tap → [SafeModeService.reset] followed by
///    [SafeModeService.checkLocation] so the auto-evaluation gets a
///    fresh look (it may immediately flip back to Auto if the device
///    is inside a polygon, or land on Off).
///
/// 3. **Auto active and locked** (`svc.isActive && !svc.isManual`):
///    **green-filled circular badge** (`#3DDC97` background, `#22C57E`
///    border, soft sage glow) — matches the [PersistentSafeModeBanner]
///    sage treatment so the chrome reads as ONE state ("you are inside
///    an enforcing premises"). The polygon enforcement means the
///    practitioner cannot override — tapping shows a brief inline
///    snackbar "Enforced by your current premises" instead of mutating
///    state. The privacy promise is held tight.
///
///    The green badge appears IRRESPECTIVE of subscription state (per
///    M21 — 2026-05-26 mobile stack round 3); the colour communicates
///    "safe", which is true regardless of whether the practitioner has
///    paid for a subscription. The subscription state lives in the
///    banner's right-edge affordance, not in the action icon.
///
/// Listens to [SafeModeService.instance] via [ListenableBuilder] so the
/// visual updates in real time as polygon evaluations / manual flips /
/// trailing-window deactivations happen.
///
/// Used by the Home screen header next to the network-share
/// (`group_add_outlined`) icon. Sized to roughly match the adjacent
/// header IconButtons (28-32 logical pixels for the icon, inside a 48pt
/// tap target).
class SafeModeToggleButton extends StatelessWidget {
  /// Edge length of the rendered icon. The button's tap target is
  /// fixed at ~48pt for accessibility — only the visible icon scales.
  final double iconSize;

  const SafeModeToggleButton({super.key, this.iconSize = 28});

  // Sage tokens (must match [PersistentSafeModeBanner]). When either
  // surface tweaks its sage, update both — they're meant to read as
  // one cohesive state.
  static const Color _kSageFill = Color(0xFF3DDC97);
  static const Color _kSageBorder = Color(0xFF22C57E);
  static const Color _kSageGlow = Color(0x8C3DDC97);
  static const Color _kInk = Color(0xFF0F1117);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: SafeModeService.instance,
      builder: (context, _) {
        final svc = SafeModeService.instance;
        final isActive = svc.isActive;
        final isManual = svc.isManual;
        // "Auto + locked" = polygon-enforced (active but not manual).
        // This is the state that gets the green badge treatment.
        final isAutoLocked = isActive && !isManual;

        return Tooltip(
          message: _tooltipFor(svc),
          child: Semantics(
            button: true,
            label: _tooltipFor(svc),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => _onTap(context, isAutoLocked),
                borderRadius: BorderRadius.circular(24),
                child: Container(
                  width: 48,
                  height: 48,
                  alignment: Alignment.center,
                  child: _buildIcon(
                    isActive: isActive,
                    isAutoLocked: isAutoLocked,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildIcon({required bool isActive, required bool isAutoLocked}) {
    // Auto-locked → green-filled circular badge with a dark shield
    // knockout. Mirrors [PersistentSafeModeBanner._buildShieldBadge]
    // so the action icon + the banner read as one cohesive "inside
    // an enforcing premises" state.
    if (isAutoLocked) {
      return Container(
        width: iconSize + 8,
        height: iconSize + 8,
        decoration: BoxDecoration(
          color: _kSageFill,
          shape: BoxShape.circle,
          border: Border.all(color: _kSageBorder, width: 1),
          boxShadow: const [
            BoxShadow(
              color: _kSageGlow,
              offset: Offset(0, 0),
              blurRadius: 10,
            ),
          ],
        ),
        alignment: Alignment.center,
        child: SafeModeIcon(
          size: iconSize - 2,
          fillColor: _kInk,
          // Knockout matches the sage so the two figures punch out
          // of the ink, reading as dark shield with sage cutouts.
          knockoutColor: _kSageFill,
        ),
      );
    }

    // Off-state: shield rendered as a flat white outline-equivalent —
    // we reuse SafeModeIcon but with white as the fill so the silhouette
    // still reads, and a knockout that matches the surface so the
    // figures inside disappear (we just see a white shield outline).
    if (!isActive) {
      return SafeModeIcon(
        size: iconSize,
        fillColor: AppColors.textOnDark.withValues(alpha: 0.62),
        // Knockout matches the surface so the two figures vanish — the
        // OFF state should read as a neutral "Safe Mode is available
        // but currently off". Bystander opacity 1.0 means the right
        // figure is also fully knocked out for consistency.
        knockoutColor: AppColors.surfaceBg,
        bystanderOpacity: 1.0,
      );
    }

    // Manual active: coral-filled shield + figures, coral border pill.
    // We keep coral here (rather than sage) because manual mode is the
    // practitioner OPTING IN outside any geofence — there is no
    // enforcing premises promise to make green. Coral reads as
    // "active, your choice".
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: AppColors.primary.withValues(alpha: 0.55),
          width: 1,
        ),
      ),
      child: SafeModeIcon(size: iconSize),
    );
  }

  String _tooltipFor(SafeModeService svc) {
    if (!svc.isActive) return 'Safe Mode (off) — tap to turn on';
    if (svc.isManual) return 'Safe Mode (manual) — tap to turn off';
    // Auto + locked.
    return 'Safe Mode (auto) — enforced by ${svc.premisesName}';
  }

  void _onTap(BuildContext context, bool isAutoLocked) {
    HapticFeedback.selectionClick();
    final svc = SafeModeService.instance;

    if (isAutoLocked) {
      // Polygon enforcement — surface a brief inline message instead
      // of mutating state. R-01 / privacy contract.
      final messenger = ScaffoldMessenger.maybeOf(context);
      if (messenger != null) {
        messenger.clearSnackBars();
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              'Enforced by ${svc.premisesName}.',
              style: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 14,
                color: AppColors.textOnDark,
              ),
            ),
            backgroundColor: AppColors.surfaceRaised,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: const BorderSide(color: AppColors.surfaceBorder),
            ),
          ),
        );
      }
      return;
    }

    if (svc.isActive) {
      // Manual → off + re-evaluate. Manual mode bypasses hysteresis so
      // reset() drops state immediately; checkLocation() then asks the
      // polygon whether it should re-engage as Auto.
      svc.reset();
      // Fire-and-forget; state listeners pick up the change.
      svc.checkLocation();
      return;
    }

    // Off → manual on.
    svc.forceActive();
  }
}
