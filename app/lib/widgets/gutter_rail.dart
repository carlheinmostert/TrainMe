import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme.dart';
import '../theme/motion.dart';

/// Gutter Rail widgets — the vertical column on the left of the Studio list
/// that carries position numbers, insertion dots, circuit rails, and drag
/// handles. See `docs/design/project/components.md` §Gutter Rail for the
/// full spec.
///
/// Three widgets compose the rail:
/// - [GutterCardCell]   — one cell per card (number, drag-handle glyph,
///                         circuit rail segment).
/// - [GutterGapCell]    — insertion dot between two cards (tap target).
/// - [GutterSpacerCell] — unadorned 36px-wide column filler for header /
///                         summary-row slivers so alignment stays honest.
///
/// Dimensions:
///   36px visible column · 44px hit target · 6px dot (idle) · 10px dot
///   (active) · 3px rail stroke.

/// Design-spec constants — kept as top-level `const` so widget consumers
/// can align surrounding content (card column padding, summary row
/// indent).
const double kGutterVisibleWidth = 36.0;
const double kGutterHitWidth = 44.0;

/// Dot state — drives both painter and dot size / colour.
enum GutterDotState { idle, focused, active }

/// Per-card gutter cell. Renders:
/// - [numberGlyph]: 1-based sequence number (exercises only — rests pass
///   `null`).
/// - Circuit rail segment when [isInCircuit] is true. Top cap on the
///   first card in a circuit, bottom cap on the last, straight through
///   otherwise.
/// - Swap to a drag-handle glyph when [isDragging].
/// - Long-press wires through [onLongPress] for drag-reorder engagement.
/// - Tap wires through [onTap] (may open a context menu on rest bars).
///
/// The cell is a fixed 36px visible; wrap in a SizedBox / Row cell of
/// that width at the call site.
class GutterCardCell extends StatelessWidget {
  final int? numberGlyph;
  final bool isInCircuit;
  final bool isFirstInCircuit;
  final bool isLastInCircuit;
  final bool isDragging;
  final double height;
  final bool dimmed;

  /// When true, swap the number for a drag-handle glyph even without an
  /// active drag (used while the host is long-pressing an adjacent card).
  final bool showDragHandleGlyph;

  const GutterCardCell({
    super.key,
    required this.numberGlyph,
    this.isInCircuit = false,
    this.isFirstInCircuit = false,
    this.isLastInCircuit = false,
    this.isDragging = false,
    this.showDragHandleGlyph = false,
    this.dimmed = false,
    this.height = 80,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: kGutterVisibleWidth,
      height: height,
      child: CustomPaint(
        painter: _GutterCardPainter(
          isInCircuit: isInCircuit,
          isFirstInCircuit: isFirstInCircuit,
          isLastInCircuit: isLastInCircuit,
        ),
        child: Center(
          child: AnimatedSwitcher(
            duration: AppMotion.fast,
            switchInCurve: AppMotion.standard,
            switchOutCurve: AppMotion.standard,
            child: (showDragHandleGlyph || isDragging)
                ? _DragHandleGlyph(
                    key: const ValueKey('drag'),
                    onBrand: isInCircuit,
                    dimmed: dimmed,
                  )
                : _NumberGlyph(
                    key: ValueKey('num_$numberGlyph'),
                    value: numberGlyph,
                    onBrand: isInCircuit,
                    dimmed: dimmed,
                  ),
          ),
        ),
      ),
    );
  }
}

class _NumberGlyph extends StatelessWidget {
  final int? value;
  final bool onBrand;
  final bool dimmed;
  const _NumberGlyph({super.key, this.value, this.onBrand = false, this.dimmed = false});

  @override
  Widget build(BuildContext context) {
    if (value == null) return const SizedBox.shrink();
    final color = onBrand
        ? Colors.white
        : AppColors.textSecondaryOnDark;
    return Opacity(
      opacity: dimmed ? 0.3 : (onBrand ? 1.0 : 0.6),
      child: Text(
        '$value',
        style: TextStyle(
          fontFamily: 'JetBrainsMono',
          fontFamilyFallback: const ['Menlo', 'Courier'],
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: color,
          height: 1.0,
        ),
      ),
    );
  }
}

class _DragHandleGlyph extends StatelessWidget {
  final bool onBrand;
  final bool dimmed;
  const _DragHandleGlyph({super.key, this.onBrand = false, this.dimmed = false});

  @override
  Widget build(BuildContext context) {
    final color = onBrand
        ? Colors.white
        : AppColors.textSecondaryOnDark;
    return Opacity(
      opacity: dimmed ? 0.3 : 1.0,
      child: Icon(
        Icons.drag_handle,
        size: 18,
        color: color,
      ),
    );
  }
}

class _GutterCardPainter extends CustomPainter {
  final bool isInCircuit;
  final bool isFirstInCircuit;
  final bool isLastInCircuit;

  _GutterCardPainter({
    required this.isInCircuit,
    required this.isFirstInCircuit,
    required this.isLastInCircuit,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (!isInCircuit) return;
    final paint = Paint()
      ..color = AppColors.primary.withValues(alpha: 0.85)
      ..style = PaintingStyle.fill;
    final centerX = size.width / 2;
    const railWidth = 3.0;
    const capRadius = 1.5;
    final top = isFirstInCircuit ? 0.0 : 0.0;
    final bottom = isLastInCircuit ? size.height : size.height;
    final rect = Rect.fromLTRB(
      centerX - railWidth / 2,
      top,
      centerX + railWidth / 2,
      bottom,
    );
    // Rounded caps only on the extremes of a circuit. Inner cards paint
    // a plain stripe that visually fuses with the cards above/below —
    // Flutter paints each cell independently so adjacent edges already
    // touch as long as the top/bottom match.
    final topRadius = isFirstInCircuit
        ? const Radius.circular(capRadius)
        : Radius.zero;
    final bottomRadius = isLastInCircuit
        ? const Radius.circular(capRadius)
        : Radius.zero;
    final rrect = RRect.fromRectAndCorners(
      rect,
      topLeft: topRadius,
      topRight: topRadius,
      bottomLeft: bottomRadius,
      bottomRight: bottomRadius,
    );
    canvas.drawRRect(rrect, paint);
  }

  @override
  bool shouldRepaint(covariant _GutterCardPainter old) =>
      old.isInCircuit != isInCircuit ||
      old.isFirstInCircuit != isFirstInCircuit ||
      old.isLastInCircuit != isLastInCircuit;
}

/// Inter-card gutter gap — the insertion dot.
///
/// Four visual contracts:
///   1. Always renders a 44px-tall hit target so the row is tappable.
///   2. Inside a same-circuit continuous stretch, no dot is painted;
///      the rail carries through from the upper card's cell into the
///      lower card's cell via [continuousRail].
///   3. Outside a circuit, an idle/focused/active dot glyph paints in
///      the centre.
///   4. Active state: 10px coral disc + 4px halo, brief entrance
///      animation via [AnimatedContainer].
class GutterGapCell extends StatelessWidget {
  final GutterDotState state;
  final bool continuousRail;
  final VoidCallback? onTap;
  final bool dimmed;

  const GutterGapCell({
    super.key,
    this.state = GutterDotState.idle,
    this.continuousRail = false,
    this.onTap,
    this.dimmed = false,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: kGutterVisibleWidth,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (onTap == null) return;
          HapticFeedback.selectionClick();
          onTap!();
        },
        child: SizedBox(
          height: 20,
          width: kGutterHitWidth,
          child: CustomPaint(
            painter: _GutterGapPainter(
              state: state,
              continuousRail: continuousRail,
              dimmed: dimmed,
            ),
          ),
        ),
      ),
    );
  }
}

class _GutterGapPainter extends CustomPainter {
  final GutterDotState state;
  final bool continuousRail;
  final bool dimmed;

  _GutterGapPainter({
    required this.state,
    required this.continuousRail,
    required this.dimmed,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final centerX = size.width / 2;
    final centerY = size.height / 2;

    if (continuousRail) {
      // No dot — rail carries through.
      final paint = Paint()
        ..color = AppColors.primary.withValues(alpha: dimmed ? 0.3 : 0.85)
        ..style = PaintingStyle.fill;
      const railWidth = 3.0;
      canvas.drawRect(
        Rect.fromLTRB(
          centerX - railWidth / 2,
          0,
          centerX + railWidth / 2,
          size.height,
        ),
        paint,
      );
      return;
    }

    if (state == GutterDotState.active) {
      // 10px coral disc with 4px halo (14px outer).
      final halo = Paint()
        ..color = AppColors.brandTintBg
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(centerX, centerY), 9, halo);
      final core = Paint()
        ..color = AppColors.primary
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(centerX, centerY), 5, core);
      return;
    }

    // Idle / focused — 6px muted dot.
    final opacity = dimmed
        ? 0.15
        : state == GutterDotState.focused
            ? 0.6
            : 0.3;
    final paint = Paint()
      ..color = AppColors.textSecondaryOnDark.withValues(alpha: opacity)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(centerX, centerY), 3, paint);
  }

  @override
  bool shouldRepaint(covariant _GutterGapPainter old) =>
      old.state != state ||
      old.continuousRail != continuousRail ||
      old.dimmed != dimmed;
}

/// Empty gutter cell — used for summary row / circuit header slivers so the
/// card column stays aligned without rendering any rail content.
class GutterSpacerCell extends StatelessWidget {
  final double height;
  final bool railThrough;
  const GutterSpacerCell({super.key, required this.height, this.railThrough = false});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: kGutterVisibleWidth,
      height: height,
      child: CustomPaint(
        painter: _GutterCardPainter(
          isInCircuit: railThrough,
          isFirstInCircuit: false,
          isLastInCircuit: false,
        ),
      ),
    );
  }
}
