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
///   [ Clients · Classes ]      [ My Workouts ]
///        Practice capsule         Workouts capsule
///         (flex 1.95)                (flex 1)
///
/// The Practice and Workouts capsules sit side-by-side with an 8px
/// gap. Visually distinct primitives tell the truth that Practice
/// (creator) and Workouts (consumer) are different identities — the
/// Practice chip + Credits chip live BELOW this row, anchored to
/// the Practice capsule (see [HomeScreen]).
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
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Row(
        children: [
          // Practice capsule (creator scopes)
          Expanded(
            flex: 195,
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
          const SizedBox(width: 8),
          // Workouts capsule (consumer scope — separate identity)
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
