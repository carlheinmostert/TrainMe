import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme.dart';
import '../theme/motion.dart';

/// Inline Action Tray — the expanding between-card menu that replaces the
/// legacy link / insert-rest buttons. Activated by tapping a gutter
/// insertion dot; dismissed by tapping outside or the × chip.
///
/// Per-spec order and behaviour: Rest / Link / Exercise / close.
class InlineActionTray extends StatelessWidget {
  /// Whether the tray is in its visible (active) state. Callers drive this
  /// via a parent-managed "active dot" index.
  final bool visible;

  /// Whether `Rest here` is offered. Spec: hidden if adjacent to an
  /// existing rest bar (no double-rests).
  final bool showRestAction;

  /// Whether `Link into circuit` is offered. Spec: hidden when at top/bottom
  /// of list, or when both cards are already in the same circuit, or when
  /// inside an existing circuit.
  final bool showLinkAction;

  /// Whether `Break here` is offered. Mutually exclusive with Link — shown
  /// only when the two adjacent cards are already in the same circuit and
  /// the user wants to split the circuit at this point.
  final bool showBreakAction;

  /// Whether `+ Exercise here` is offered. Usually always true except in
  /// the locked-edit state.
  final bool showInsertAction;

  /// Whether any action in the tray costs a credit right now (post-lock).
  /// When true, primary fill flips to neutral + the tap fires
  /// [onLockedAction] instead of the normal callback.
  final bool locked;

  final VoidCallback? onRestHere;
  final VoidCallback? onLinkCircuit;
  final VoidCallback? onBreakLink;
  final VoidCallback? onInsertExercise;
  final VoidCallback onClose;
  final VoidCallback? onLockedAction;

  const InlineActionTray({
    super.key,
    required this.visible,
    required this.onClose,
    this.showRestAction = true,
    this.showLinkAction = true,
    this.showBreakAction = false,
    this.showInsertAction = true,
    this.locked = false,
    this.onRestHere,
    this.onLinkCircuit,
    this.onBreakLink,
    this.onInsertExercise,
    this.onLockedAction,
  });

  void _fire(VoidCallback? cb) {
    HapticFeedback.mediumImpact();
    if (locked) {
      onLockedAction?.call();
      return;
    }
    cb?.call();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: AppMotion.normal,
      curve: AppMotion.emphasized,
      alignment: Alignment.topCenter,
      child: AnimatedOpacity(
        duration: AppMotion.fast,
        curve: AppMotion.standard,
        opacity: visible ? 1 : 0,
        child: visible
            ? Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceBase,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: locked
                          ? AppColors.surfaceBorder
                          : AppColors.primary,
                      width: 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      if (showRestAction)
                        _TrayAction(
                          label: 'Rest',
                          icon: Icons.self_improvement,
                          primary: true,
                          locked: locked,
                          onTap: () => _fire(onRestHere),
                        ),
                      if (showRestAction && (showLinkAction || showBreakAction))
                        const SizedBox(width: 8),
                      if (showLinkAction)
                        _TrayAction(
                          label: 'Link',
                          icon: Icons.link,
                          primary: false,
                          locked: locked,
                          onTap: () => _fire(onLinkCircuit),
                        ),
                      if (showBreakAction)
                        _TrayAction(
                          label: 'Break',
                          icon: Icons.link_off,
                          primary: false,
                          locked: locked,
                          onTap: () => _fire(onBreakLink),
                        ),
                      if ((showRestAction || showLinkAction || showBreakAction) &&
                          showInsertAction)
                        const SizedBox(width: 8),
                      if (showInsertAction)
                        _TrayAction(
                          label: 'Exercise',
                          icon: Icons.add,
                          primary: false,
                          locked: locked,
                          onTap: () => _fire(onInsertExercise),
                        ),
                      // No × close — the insertion triangle itself flips
                      // to point LEFT when the tray is open, signalling
                      // "tap again to close". Reclaims ~40px of width so
                      // Rest / Link / Exercise all fit without spilling.
                    ],
                  ),
                ),
              )
            : const SizedBox.shrink(),
      ),
    );
  }
}

class _TrayAction extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool primary;
  final bool locked;
  final VoidCallback onTap;

  const _TrayAction({
    required this.label,
    required this.icon,
    required this.primary,
    required this.locked,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bool brandFill = primary && !locked;
    final Color fill = brandFill
        ? AppColors.primary
        : AppColors.surfaceRaised;
    final Color textColor = brandFill
        ? Colors.white
        : (locked
            ? AppColors.textSecondaryOnDark.withValues(alpha: 0.5)
            : AppColors.textOnDark);
    final Color borderColor = brandFill
        ? AppColors.primary
        : AppColors.surfaceBorder;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(9999),
          border: Border.all(color: borderColor, width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: textColor),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
                color: textColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
