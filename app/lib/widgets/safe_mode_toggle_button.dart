import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/safe_mode_service.dart';
import '../theme.dart';
import 'safe_mode_icon.dart';

/// First-class Safe Mode toggle for the Home screen header.
///
/// **Brand call (M24 — 2026-05-26 mobile stack round 4): Safe Mode is
/// ALWAYS green, full stop.** The action icon always renders as the
/// green-filled circular badge (`#3DDC97` background, `#22C57E` border,
/// soft sage glow) — irrespective of whether Safe Mode is currently
/// off, manually engaged, or auto-engaged inside an enforcing premises.
/// Colour does NOT differentiate state. The token "green = Safe Mode"
/// must read at distance regardless of whether the practitioner is
/// inside a premises right now.
///
/// State differentiation lives in BEHAVIOUR (and, where needed, in
/// non-colour affordances inside the green badge — e.g. an inner dot,
/// shield knockout, etc.), not in colour-shifting away from green.
///
/// Three-state behaviour, all driven from the singleton
/// [SafeModeService]:
///
/// 1. **Off** (`!svc.isActive`): tap → [SafeModeService.forceActive]
///    so the practitioner opts into manual Safe Mode (and the
///    persistent banner appears).
///
/// 2. **Manual active** (`svc.isActive && svc.isManual`): tap →
///    [SafeModeService.reset] followed by [SafeModeService.checkLocation]
///    so the auto-evaluation gets a fresh look (it may immediately flip
///    back to Auto if the device is inside a polygon, or land on Off).
///
/// 3. **Auto active and locked** (`svc.isActive && !svc.isManual`):
///    polygon enforcement means the practitioner cannot override —
///    tapping shows a brief inline snackbar "Enforced by your current
///    premises" instead of mutating state.
///
/// Listens to [SafeModeService.instance] via [ListenableBuilder] so the
/// behaviour updates in real time as polygon evaluations / manual flips
/// / trailing-window deactivations happen.
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
        // Drives BEHAVIOUR (tap → enforcement snackbar) but no longer
        // drives colour — every state is green per M24.
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
                    isManual: isManual,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Always renders the green-filled circular badge — M24 brand call:
  /// Safe Mode is ALWAYS green, full stop. No colour state-shift.
  ///
  /// State differentiation lives in non-colour affordances inside the
  /// badge:
  ///   * Active states (auto-locked OR manual) → solid dark shield
  ///     knockout reads "engaged".
  ///   * Off state → same green badge with an inset ring (`bystanderOpacity`
  ///     dialled down so the badge reads slightly emptier) so the
  ///     practitioner can still distinguish "armed and waiting" from
  ///     "actively obscuring bystanders right now" without colour.
  Widget _buildIcon({required bool isActive, required bool isManual}) {
    // Off-state: still green badge, but the shield interior reads
    // "armed, not currently obscuring". Lower bystanderOpacity so the
    // second figure ghosts in, signalling the state difference without
    // colour-shifting.
    //
    // `isManual` intentionally unused in the icon visuals — colour AND
    // shield treatment stay constant across off / manual / auto. The
    // flag still flows into `_onTap` to drive the enforcement snackbar
    // path.
    // ignore: unused_local_variable
    final manualUnused = isManual;
    final shieldKnockout = isActive
        // Active (auto OR manual) → both figures punch out of the dark
        // shield reading as the canonical engaged shield.
        ? SafeModeIcon(
            size: iconSize - 2,
            fillColor: _kInk,
            knockoutColor: _kSageFill,
          )
        // Off → bystander figure ghosted (0.45) so the badge has a
        // visible "not yet engaged" signal that doesn't depend on
        // colour.
        : SafeModeIcon(
            size: iconSize - 2,
            fillColor: _kInk,
            knockoutColor: _kSageFill,
            bystanderOpacity: 0.45,
          );

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
      child: shieldKnockout,
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
