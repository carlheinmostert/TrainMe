import 'package:flutter/material.dart';

/// Safe Mode combined icon — shield with two figures (subject solid +
/// bystander 45% opacity knockout). Drawn via [CustomPainter] so it
/// scales crisply at any size with zero asset dependencies.
///
/// Reused at:
///   * 14px — banner sub-line glyph (compact)
///   * 22px — banner main glyph + Studio settings toggle row
///   * 24px — chip / inline label
///   * 64px — permission-gate hero + settings/about
///
/// Geometry is locked to a 24-unit viewBox; [size] scales uniformly.
/// The shield is filled with [fillColor] (default brand coral). The
/// two figures are "cut out" of the shield in [knockoutColor]
/// (default dark surface, matching the practitioner-app background).
///
/// Visual contract: design mockup at
/// `docs/design/mockups/safe-mode-banner.html` (Banner B).
class SafeModeIcon extends StatelessWidget {
  const SafeModeIcon({
    super.key,
    this.size = 24,
    this.fillColor = const Color(0xFFFF6B35),
    this.knockoutColor = const Color(0xFF0F1117),
    this.bystanderOpacity = 0.45,
  });

  /// Edge length in logical pixels. The icon is square.
  final double size;

  /// Fill for the shield outline.
  final Color fillColor;

  /// Colour used to "cut out" the subject + bystander silhouettes.
  /// Should match the surface the icon is rendered on so the cut-outs
  /// read as negative space.
  final Color knockoutColor;

  /// Opacity for the bystander (right-hand) figure. Defaults to 0.45 —
  /// reads as "obscured" against the subject's solid 1.0 knockout.
  final double bystanderOpacity;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        size: Size.square(size),
        painter: _SafeModeIconPainter(
          fillColor: fillColor,
          knockoutColor: knockoutColor,
          bystanderOpacity: bystanderOpacity,
        ),
      ),
    );
  }
}

class _SafeModeIconPainter extends CustomPainter {
  _SafeModeIconPainter({
    required this.fillColor,
    required this.knockoutColor,
    required this.bystanderOpacity,
  });

  final Color fillColor;
  final Color knockoutColor;
  final double bystanderOpacity;

  @override
  void paint(Canvas canvas, Size size) {
    // 24-unit viewBox.
    final scale = size.width / 24.0;
    canvas.save();
    canvas.scale(scale, scale);

    // Shield outline (filled coral). Roughly:
    //   M12 1.5 → L3 5 → V11 → curve to peak at 12 22 → L21 11 → V5 → close.
    final shield = Path()
      ..moveTo(12, 1.5)
      ..lineTo(3, 5)
      ..lineTo(3, 11)
      // Lower-left curve into the chin.
      ..cubicTo(3, 16.2, 6.5, 20.4, 12, 22)
      // Lower-right curve back up.
      ..cubicTo(17.5, 20.4, 21, 16.2, 21, 11)
      ..lineTo(21, 5)
      ..close();

    final shieldPaint = Paint()
      ..color = fillColor
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    canvas.drawPath(shield, shieldPaint);

    // Bystander (right) — drawn FIRST so the subject overlaps cleanly
    // on top if their bodies ever touch. Translucent knockout.
    final bystanderPaint = Paint()
      ..color = knockoutColor.withValues(alpha: bystanderOpacity)
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    _drawFigure(
      canvas,
      headCenter: const Offset(15.0, 9.7),
      headRadius: 1.45,
      bodyTop: 11.2,
      bodyHalfWidthTop: 0.8,
      bodyHalfWidthBottom: 2.2,
      bodyBottom: 15.6,
      paint: bystanderPaint,
    );

    // Subject (left, solid knockout).
    final subjectPaint = Paint()
      ..color = knockoutColor
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    _drawFigure(
      canvas,
      headCenter: const Offset(9.5, 9.5),
      headRadius: 1.7,
      bodyTop: 11.1,
      bodyHalfWidthTop: 0.9,
      bodyHalfWidthBottom: 2.5,
      bodyBottom: 16.0,
      paint: subjectPaint,
    );

    canvas.restore();
  }

  /// Draws a stylised head + torso "person glyph" using a circle for
  /// the head and a soft trapezoid for the body. Coordinates are in
  /// 24-unit viewBox space.
  void _drawFigure(
    Canvas canvas, {
    required Offset headCenter,
    required double headRadius,
    required double bodyTop,
    required double bodyHalfWidthTop,
    required double bodyHalfWidthBottom,
    required double bodyBottom,
    required Paint paint,
  }) {
    // Head.
    canvas.drawCircle(headCenter, headRadius, paint);

    // Body — soft trapezoid with curved shoulders that hugs the head.
    final body = Path()
      ..moveTo(headCenter.dx - bodyHalfWidthTop, bodyTop)
      // Shoulders curve outward.
      ..cubicTo(
        headCenter.dx - bodyHalfWidthBottom * 0.85,
        bodyTop + (bodyBottom - bodyTop) * 0.45,
        headCenter.dx - bodyHalfWidthBottom,
        bodyTop + (bodyBottom - bodyTop) * 0.75,
        headCenter.dx - bodyHalfWidthBottom,
        bodyBottom,
      )
      // Base.
      ..lineTo(headCenter.dx + bodyHalfWidthBottom, bodyBottom)
      // Right shoulder back up.
      ..cubicTo(
        headCenter.dx + bodyHalfWidthBottom,
        bodyTop + (bodyBottom - bodyTop) * 0.75,
        headCenter.dx + bodyHalfWidthBottom * 0.85,
        bodyTop + (bodyBottom - bodyTop) * 0.45,
        headCenter.dx + bodyHalfWidthTop,
        bodyTop,
      )
      ..close();
    canvas.drawPath(body, paint);
  }

  @override
  bool shouldRepaint(_SafeModeIconPainter old) =>
      old.fillColor != fillColor ||
      old.knockoutColor != knockoutColor ||
      old.bystanderOpacity != bystanderOpacity;
}
