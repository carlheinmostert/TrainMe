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
        painter: GutterCardPainter(
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
                : GutterNumberGlyph(
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

/// Position-number glyph. Rendered inside the gutter. Public for use
/// by the Stack-based row layout, where the glyph sits inside its own
/// `Positioned` child rather than the [GutterCardCell] wrapper.
class GutterNumberGlyph extends StatelessWidget {
  final int? value;
  final bool onBrand;
  final bool dimmed;
  const GutterNumberGlyph({super.key, this.value, this.onBrand = false, this.dimmed = false});

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
        // Stay on one line regardless of the parent's horizontal
        // constraint — at double-digit values (10+) Flutter's default
        // layout would wrap the "10" vertically inside the narrow
        // gutter column. TextOverflow.visible lets the glyph extend
        // into the 2px breathing pad if it must, rather than wrap.
        softWrap: false,
        maxLines: 1,
        overflow: TextOverflow.visible,
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

/// Painter for the card-sized gutter slice — draws the circuit rail
/// segment for a card. Public so the Stack-based row layout in
/// `studio_mode_screen.dart` can paint the rail directly into a
/// `Positioned.fill` child instead of going through [GutterCardCell]
/// (which bakes in its own height and loses the "inherit card height"
/// property we need to avoid the sliver blow-out).
class GutterCardPainter extends CustomPainter {
  final bool isInCircuit;
  final bool isFirstInCircuit;
  final bool isLastInCircuit;

  GutterCardPainter({
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

    if (isLastInCircuit) {
      // LAST card — rail terminates at the card's vertical midpoint
      // with a horizontal stub going right, mirroring the header's
      // entry stub on the first card. The stub "closes" the circuit
      // the same way the header "opens" it: rail-in at mid-header,
      // rail-out at mid-last-card.
      final centerY = size.height / 2;
      canvas.drawRect(
        Rect.fromLTRB(
          centerX - railWidth / 2,
          0,
          centerX + railWidth / 2,
          centerY,
        ),
        paint,
      );
      canvas.drawRect(
        Rect.fromLTRB(
          centerX,
          centerY - railWidth / 2,
          size.width,
          centerY + railWidth / 2,
        ),
        paint,
      );
      return;
    }

    // First or middle card — rail flows top-to-bottom, connecting
    // continuously to the header stub above (first card) or the
    // previous card's rail (middle cards). No rounded caps.
    canvas.drawRect(
      Rect.fromLTRB(
        centerX - railWidth / 2,
        0,
        centerX + railWidth / 2,
        size.height,
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant GutterCardPainter old) =>
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
        // Fire a selection-click on TOUCH-DOWN in addition to the usual
        // on-tap haptic. Carl's device-QA note (Q1 polish): the insertion
        // dots are the primary "insert here" affordance on the gutter
        // rail, and firing haptic only on lift-off made them feel
        // unresponsive — the user wants instant tactile confirmation
        // that they've actually hit the 6/10px target. Lift-off haptic
        // is preserved so the interaction still has a "commit" beat
        // when the tap completes (vs tap-cancel on drift-off).
        onTapDown: onTap == null ? null : (_) => HapticFeedback.selectionClick(),
        onTap: () {
          if (onTap == null) return;
          HapticFeedback.selectionClick();
          onTap!();
        },
        child: SizedBox(
          height: 20,
          width: kGutterHitWidth,
          child: CustomPaint(
            painter: GutterGapPainter(
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

/// Painter for the gap between two cards — the insertion dot (idle /
/// focused / active) or the continuous circuit rail. Public for the
/// same reason as [GutterCardPainter]: the Stack-based row in
/// `studio_mode_screen.dart` needs to paint the gap rail/dot into a
/// `Positioned.fill` whose height is determined by the gap's card
/// column (tray / placeholder).
class GutterGapPainter extends CustomPainter {
  final GutterDotState state;
  final bool continuousRail;
  final bool dimmed;

  /// Pulse phase in [0, 1]. When the dot is idle and not dimmed, a soft
  /// coral halo is drawn behind the dot with opacity proportional to
  /// this phase — a gentle breathing animation advertising the dot as
  /// tappable. Pass 0 to disable. See Design Rule R-09.
  final double pulsePhase;

  GutterGapPainter({
    required this.state,
    required this.continuousRail,
    required this.dimmed,
    this.pulsePhase = 0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Rail stays at the gutter's TRUE centre (18), independent of the
    // canvas width — when the call-site widens the Positioned past the
    // gutter so the insertion triangle gets its own channel, the rail
    // must not drift with it. It has to line up with the card rails
    // above and below (which are painted at kGutterVisibleWidth/2).
    const double centerX = kGutterVisibleWidth / 2; // 18
    final centerY = size.height / 2;
    // Triangle lives in its own right channel — 16px to the right of
    // the rail. Sits in the natural gap where the cards' rounded
    // corners curve inward, so no visual collision with card bodies
    // even though it's past the gutter's nominal right edge.
    const double triCenterX = kGutterVisibleWidth - 2; // 34

    // 1) Rail through: draw the circuit rail in the CENTRE channel when
    //    this gap bridges two cards of the same circuit. Does NOT return
    //    early anymore — the insertion triangle still paints in the
    //    right channel on top of this, advertising insertion even inside
    //    a circuit.
    if (continuousRail) {
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
    }

    // 2) Insertion marker: right-pointing triangle in the RIGHT channel.
    //    Shape suggests "insert between the exercise north and the one
    //    south" — the arrow points toward the action surface (the tray
    //    that slides in when tapped). Sits in its own channel so it's
    //    visible regardless of whether the circuit rail is present.

    if (state == GutterDotState.active) {
      // Active — solid coral halo + solid coral triangle pointing LEFT.
      // The flip from right (insert) → left (close) signals "tap me
      // again to dismiss the tray". Replaces a separate × close
      // button; keeps the whole open/close interaction on one affordance.
      final halo = Paint()
        ..color = AppColors.brandTintBg
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(triCenterX, centerY), 9, halo);
      final triPaint = Paint()
        ..color = AppColors.primary
        ..style = PaintingStyle.fill;
      _drawTriangle(
        canvas,
        triCenterX,
        centerY,
        4.5,
        6,
        triPaint,
        pointingLeft: true,
      );
      return;
    }

    // Idle / focused — breathing coral halo BEHIND the triangle when
    // idle + not dimmed. See Design Rule R-09: affordances default to
    // their most obvious form; the pulse signals "tap here, insert".
    // The halo breathes from a 0.15 floor to a 0.45 peak so it's
    // visibly pulsing rather than barely shimmering.
    if (state == GutterDotState.idle && !dimmed) {
      final haloAlpha = 0.15 + (0.30 * pulsePhase);
      final haloPaint = Paint()
        ..color = AppColors.primary.withValues(alpha: haloAlpha)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(triCenterX, centerY), 10, haloPaint);
    }

    // Idle / focused triangle — coral at an opacity that reads as
    // "present but calm". Focused bumps opacity so a mid-press hover
    // still has a visible response. Points RIGHT — "insert" direction.
    final triOpacity = dimmed
        ? 0.2
        : state == GutterDotState.focused
            ? 0.85
            : 0.55;
    final triPaint = Paint()
      ..color = AppColors.primary.withValues(alpha: triOpacity)
      ..style = PaintingStyle.fill;
    _drawTriangle(canvas, triCenterX, centerY, 4, 5.5, triPaint);
  }

  /// Draws an isoceles triangle centred at ([cx], [cy]).
  ///
  /// [halfWidth] is the horizontal extent from centre to the base edge,
  /// [halfHeight] the vertical extent from centre to top/bottom vertex.
  /// Default [pointingLeft] = false draws the apex on the RIGHT (insert
  /// direction); passing true flips it so the apex points LEFT (close
  /// direction).
  void _drawTriangle(
    Canvas canvas,
    double cx,
    double cy,
    double halfWidth,
    double halfHeight,
    Paint paint, {
    bool pointingLeft = false,
  }) {
    final path = Path();
    if (pointingLeft) {
      path
        ..moveTo(cx + halfWidth, cy - halfHeight) // top-right
        ..lineTo(cx + halfWidth, cy + halfHeight) // bottom-right
        ..lineTo(cx - halfWidth, cy); // apex left
    } else {
      path
        ..moveTo(cx - halfWidth, cy - halfHeight) // top-left
        ..lineTo(cx - halfWidth, cy + halfHeight) // bottom-left
        ..lineTo(cx + halfWidth, cy); // apex right
    }
    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant GutterGapPainter old) =>
      old.state != state ||
      old.continuousRail != continuousRail ||
      old.dimmed != dimmed ||
      old.pulsePhase != pulsePhase;
}

/// Gutter slot for the circuit header bar.
///
/// Draws:
///   - No rail in the top half — the circuit conceptually begins at the
///     header's midpoint, not at the top of the header row.
///   - A short horizontal stub at y = height/2, running from the rail
///     centre to the right edge of the gutter strip. This visually "ties"
///     the rail into the circuit name bar to its right.
///   - A vertical rail from y = height/2 to the bottom, continuous with
///     the first circuit card's rail below.
///
/// The whole cell is [kGutterVisibleWidth] wide and [height] tall. Use
/// 32 to match the circuit header bar's explicit SizedBox height.
class GutterCircuitHeaderCell extends StatelessWidget {
  final double height;
  const GutterCircuitHeaderCell({super.key, this.height = 32});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: kGutterVisibleWidth,
      height: height,
      child: CustomPaint(painter: GutterCircuitHeaderPainter()),
    );
  }
}

/// Painter for [GutterCircuitHeaderCell]. Extracted so the Stack-based
/// row layout can also paint this directly if needed.
class GutterCircuitHeaderPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppColors.primary.withValues(alpha: 0.85)
      ..style = PaintingStyle.fill;
    final centerX = size.width / 2;
    final centerY = size.height / 2;
    const railWidth = 3.0;

    // Vertical rail — centre-out, from the midpoint down to the bottom.
    canvas.drawRect(
      Rect.fromLTRB(
        centerX - railWidth / 2,
        centerY,
        centerX + railWidth / 2,
        size.height,
      ),
      paint,
    );

    // Horizontal stub — from the rail's centre line rightward to the
    // right edge of the gutter strip. Meets the circuit name bar's
    // left edge at y = centerY.
    canvas.drawRect(
      Rect.fromLTRB(
        centerX,
        centerY - railWidth / 2,
        size.width,
        centerY + railWidth / 2,
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant GutterCircuitHeaderPainter old) => false;
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
        painter: GutterCardPainter(
          isInCircuit: railThrough,
          isFirstInCircuit: false,
          isLastInCircuit: false,
        ),
      ),
    );
  }
}
