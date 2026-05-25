import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// Top-level scopes on Home.
///
/// - [clients] and [classes] are sub-scopes of the practitioner's
///   Practice mode. Both inside the left capsule of
///   [HomeScopeSegmented].
/// - [workouts] is a separate identity (consumer, not creator) — its
///   own capsule on the right of the row, with no practice context
///   and no credits.
///
/// Adding a fourth scope later is intentionally cheap — extend this
/// enum and add a segment to one of the capsules (or a third
/// capsule if the new scope is yet another identity).
enum HomeScope { clients, classes, workouts }

/// Two-capsule scope row pinned just below the brand lockup on
/// [HomeScreen]. The control itself IS the information architecture
/// — three top-level surfaces are always visible so Home's shape
/// doesn't change between today and the day Classes / Workouts go
/// live. Today, the Classes and Workouts segments route to locked
/// teaser bodies; the teaser body's headline carries a "Coming soon"
/// pill so labels in the AppBar capsule stay short and never
/// truncate.
///
/// Visual model:
///
///   [ My Workouts ]    [ Clients · Classes ]
///   Workouts capsule       Practice capsule
///      (flex 100)             (flex 165)
///
/// The Workouts and Practice capsules sit side-by-side with a 6px
/// gap. Visually distinct primitives tell the truth that My Workouts
/// (Self-trainer) and Practice (creator) are different identities.
///
/// Spacing/label tightened 2026-05-13 (round 2 QA) — original layout
/// dropped to single-word "Workouts" to avoid truncation. Per
/// `docs/SELF_TRAINER_WAVE.md` § IA changes (2026-05-25), the layout
/// is reversed (My Workouts capsule on the LEFT) and the label is
/// restored to "My Workouts". Order, not width, carries the
/// prominence signal (Q5.2 of the design doc). Width ratios (flex
/// 100:165) are unchanged.
class HomeScopeSegmented extends StatelessWidget {
  final HomeScope selected;
  final ValueChanged<HomeScope> onChanged;

  const HomeScopeSegmented({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: Row(
        children: [
          // My Workouts capsule (Self-trainer scope — separate identity).
          // Sits LEFT per `docs/SELF_TRAINER_WAVE.md` § IA changes; order
          // carries the prominence signal (Q5.2), not width. The
          // underlying `HomeScope.workouts` enum name is unchanged — only
          // the user-facing label flipped back to "My Workouts".
          Expanded(
            flex: 100,
            child: _Capsule(
              children: [
                _Segment(
                  label: 'My Workouts',
                  active: selected == HomeScope.workouts,
                  onTap: () => _select(HomeScope.workouts),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          // Practice capsule (creator scopes)
          Expanded(
            flex: 165,
            child: _Capsule(
              children: [
                _Segment(
                  label: 'Clients',
                  active: selected == HomeScope.clients,
                  onTap: () => _select(HomeScope.clients),
                ),
                _Segment(
                  label: 'Classes',
                  active: selected == HomeScope.classes,
                  onTap: () => _select(HomeScope.classes),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _select(HomeScope next) {
    if (next == selected) return;
    HapticFeedback.selectionClick();
    onChanged(next);
  }
}

class _Capsule extends StatelessWidget {
  final List<Widget> children;

  const _Capsule({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: AppColors.surfaceBase,
        borderRadius: BorderRadius.circular(100),
        border: Border.all(color: AppColors.surfaceBorder, width: 1),
      ),
      padding: const EdgeInsets.all(3),
      child: Row(
        children: [
          for (final child in children) Expanded(child: child),
        ],
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _Segment({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fg = active ? Colors.white : AppColors.textSecondaryOnDark;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(100),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(100),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            color: active ? AppColors.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(100),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: fg,
              letterSpacing: 0.1,
            ),
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
        ),
      ),
    );
  }
}
