import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// Top-level scopes on Home. Clients is the only real surface today;
/// Classes is the permanent teaser that becomes the multi-client
/// content store once that feature ships. Adding a third scope later
/// is intentionally cheap — extend the enum and add a segment.
enum HomeScope { clients, classes }

/// Segmented control pinned just below the identity row on
/// [HomeScreen]. The control itself IS the information architecture —
/// both segments are always present so Home's shape never changes
/// between today and the day Classes goes live. Today, tapping Classes
/// lands on the coming-soon teaser; the `Soon` pill on the label tells
/// the practitioner it's not buyable yet. When Classes ships, only the
/// body the segment routes to changes — this widget keeps rendering
/// the same two pills.
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
      child: Container(
        height: 40,
        decoration: BoxDecoration(
          color: AppColors.surfaceBase,
          borderRadius: BorderRadius.circular(100),
          border: Border.all(color: AppColors.surfaceBorder, width: 1),
        ),
        padding: const EdgeInsets.all(3),
        child: Row(
          children: [
            Expanded(
              child: _Segment(
                label: 'Clients',
                active: selected == HomeScope.clients,
                onTap: () => _select(HomeScope.clients),
              ),
            ),
            Expanded(
              child: _Segment(
                label: 'Classes',
                soon: true,
                active: selected == HomeScope.classes,
                onTap: () => _select(HomeScope.classes),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _select(HomeScope next) {
    if (next == selected) return;
    HapticFeedback.selectionClick();
    onChanged(next);
  }
}

class _Segment extends StatelessWidget {
  final String label;
  final bool active;
  final bool soon;
  final VoidCallback onTap;

  const _Segment({
    required this.label,
    required this.active,
    required this.onTap,
    this.soon = false,
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
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: fg,
                  letterSpacing: 0.2,
                ),
              ),
              if (soon) ...[
                const SizedBox(width: 8),
                _SoonPill(active: active),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SoonPill extends StatelessWidget {
  final bool active;
  const _SoonPill({required this.active});

  @override
  Widget build(BuildContext context) {
    // On the active (coral-filled) segment the pill flips to a soft
    // white tint so it still reads as a label rather than a hot accent
    // on a hot background. Inactive, it picks up a faint coral tint —
    // just enough to whisper "this is the new thing".
    final bg = active
        ? Colors.white.withValues(alpha: 0.22)
        : AppColors.brandTintBg;
    final fg = active ? Colors.white : AppColors.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(100),
      ),
      child: Text(
        'Soon',
        style: TextStyle(
          fontFamily: 'Inter',
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: fg,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}
