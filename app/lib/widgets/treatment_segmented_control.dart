import 'package:flutter/material.dart';

import '../models/treatment.dart';
import '../theme.dart';

/// Three-segment control sitting under the top bar — coral-accented
/// selected segment, muted unselected. Disabled segments carry a small
/// lock glyph and tap into a tooltip; the [onLockTap] callback then
/// routes the practitioner to the right place to unlock it (R-09: the
/// lock tells you why, the tap takes you to the fix).
///
/// Copy omits "consent" / "legal" / "POPIA" deliberately —
/// see docs/design/project/voice.md.
///
/// Orientation:
///   • [Axis.horizontal] (default) — the classic pill with three segments
///     laid out left-to-right. Used in the plan preview where the
///     practitioner's gestures are tap-only.
///   • [Axis.vertical] — three segments stacked top-to-bottom into a
///     narrow vertical pill. Used in the Studio `_MediaViewer` where a
///     horizontal swipe paginates between exercises and a vertical swipe
///     cycles treatments — the control's orientation mirrors the gesture
///     axis it represents.
///
/// Used by:
///   • [PlanPreviewScreen] — top of the practitioner preview, lock tap
///     opens the client-consent bottom sheet.
///   • Studio fullscreen `_MediaViewer` — left edge of the demo surface,
///     lock tap toggles consent inline (no sheet).
class TreatmentSegmentedControl extends StatelessWidget {
  final Treatment active;
  final bool grayscaleAvailable;
  final bool originalAvailable;
  final ValueChanged<Treatment> onChanged;
  final VoidCallback onLockTap;

  /// Per-treatment override for the locked-state tooltip copy. Falls back
  /// to the default messages used by the plan preview if a key is absent.
  final Map<Treatment, String>? lockedMessages;

  /// Layout axis. Horizontal is the historic default; vertical is used by
  /// the Studio `_MediaViewer` to match its vertical-swipe gesture.
  final Axis orientation;

  const TreatmentSegmentedControl({
    super.key,
    required this.active,
    required this.grayscaleAvailable,
    required this.originalAvailable,
    required this.onChanged,
    required this.onLockTap,
    this.lockedMessages,
    this.orientation = Axis.horizontal,
  });

  bool _available(Treatment t) {
    switch (t) {
      case Treatment.line:
        return true;
      case Treatment.grayscale:
        return grayscaleAvailable;
      case Treatment.original:
        return originalAvailable;
    }
  }

  String _lockedMessage(Treatment t) {
    final override = lockedMessages?[t];
    if (override != null) return override;
    switch (t) {
      case Treatment.grayscale:
        return "Client hasn't said yes to grayscale yet — tap to manage.";
      case Treatment.original:
        return "Client hasn't said yes to colour yet — tap to manage.";
      case Treatment.line:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    if (orientation == Axis.vertical) {
      return _buildVertical(context);
    }
    return _buildHorizontal(context);
  }

  // ---------------------------------------------------------------------------
  // Horizontal (default) — the original layout. Zero visual regression for
  // existing call sites (plan preview, any future horizontal use).
  // ---------------------------------------------------------------------------
  Widget _buildHorizontal(BuildContext context) {
    return Container(
      height: 34,
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(9999),
        border: Border.all(color: AppColors.surfaceBorder),
      ),
      child: Row(
        children: [
          _segment(context, Treatment.line, Axis.horizontal),
          _segment(context, Treatment.grayscale, Axis.horizontal),
          _segment(context, Treatment.original, Axis.horizontal),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Vertical — narrow pill, three stacked segments. Outer container is pill-
  // rounded top + bottom; inner segments share flat adjoining edges (same
  // convention as horizontal, just 90° rotated). Intrinsic width keeps the
  // pill as narrow as the longest label ("Original") permits, so it stays
  // out of the way of the media behind it.
  // ---------------------------------------------------------------------------
  Widget _buildVertical(BuildContext context) {
    return IntrinsicWidth(
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surfaceRaised,
          borderRadius: BorderRadius.circular(9999),
          border: Border.all(color: AppColors.surfaceBorder),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _segment(context, Treatment.line, Axis.vertical),
            _segment(context, Treatment.grayscale, Axis.vertical),
            _segment(context, Treatment.original, Axis.vertical),
          ],
        ),
      ),
    );
  }

  /// A single tappable segment. The [axis] parameter decides whether the
  /// segment expands horizontally (Row with Expanded) or stacks as a fixed-
  /// height row inside the vertical Column. Styling (coral-active,
  /// lock glyph, label) is identical either way — only the enclosing layout
  /// differs.
  Widget _segment(BuildContext context, Treatment t, Axis axis) {
    final selected = active == t;
    final available = _available(t);
    final pill = Tooltip(
      message: available ? '' : _lockedMessage(t),
      triggerMode: TooltipTriggerMode.tap,
      child: GestureDetector(
        onTap: () {
          if (available) {
            onChanged(t);
          } else {
            onLockTap();
          }
        },
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          margin: const EdgeInsets.all(3),
          padding: axis == Axis.vertical
              ? const EdgeInsets.symmetric(horizontal: 10, vertical: 8)
              : EdgeInsets.zero,
          decoration: BoxDecoration(
            color: selected ? AppColors.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(9999),
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (!available)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Icon(
                    Icons.lock_outline,
                    size: 12,
                    color:
                        AppColors.textSecondaryOnDark.withValues(alpha: 0.7),
                  ),
                ),
              Text(
                t.shortLabel,
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.2,
                  color: selected
                      ? Colors.white
                      : (available
                          ? AppColors.textOnDark
                          : AppColors.textSecondaryOnDark
                              .withValues(alpha: 0.6)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (axis == Axis.horizontal) {
      return Expanded(child: pill);
    }
    return pill;
  }
}

/// Saturation-zero colour matrix used to render the grayscale treatment
/// from the original colour file. Luminance weights follow the ITU-R
/// BT.709 recipe.
///
/// Lives next to the segmented control because every caller that uses
/// the control also needs this filter to render the grayscale frame
/// without re-encoding the source.
const ColorFilter grayscaleColorFilter = ColorFilter.matrix(<double>[
  0.2126, 0.7152, 0.0722, 0, 0,
  0.2126, 0.7152, 0.0722, 0, 0,
  0.2126, 0.7152, 0.0722, 0, 0,
  0,      0,      0,      1, 0,
]);
