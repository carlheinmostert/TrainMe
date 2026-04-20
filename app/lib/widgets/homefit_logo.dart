import 'package:flutter/material.dart';
import '../theme.dart';

/// homefit.studio logo — canonical v2 system.
///
/// The logo is a slice of a training-session matrix: the progress-pill
/// matrix is already the product's visual language, and the mark is
/// literally that matrix in miniature —
///
///   3 ghost pills (outer → inner, tapering larger + lighter) →
///   2-cycle circuit sitting in a coral-tint band (2 exercises × 2 cycles) →
///   1 sage rest pill →
///   3 ghost pills (mirror on the right)
///
/// Two variants share the same 11-element matrix geometry:
///   * [HomefitLogo]       — matrix only, 48×9.5 viewBox. Use in header
///                           brand-marks (paired with a separate wordmark),
///                           favicons, app icons, tight chrome, footer
///                           marks. Default.
///   * [HomefitLogoLockup] — matrix + wordmark stacked, 48×14 viewBox.
///                           Use on hero surfaces, sign-in, marketing,
///                           share cards.
///
/// Geometry canon lives in `web-portal/src/components/HomefitLogo.tsx`;
/// this widget and the web-player helper `buildHomefitLogoSvg()` in
/// `web-player/app.js` mirror it byte-for-byte. Signed off at
/// `docs/design/mockups/logo-ghost-outer.html`.
///
/// Scales proportionally to whatever [size] the parent provides. The
/// intrinsic aspect ratio is 48:9.5 (matrix only) or 48:14 (lockup).
class HomefitLogo extends StatelessWidget {
  /// Logical pixel width. Sensible values: 18 (favicon/footer), 32
  /// (inline badge), 64 (sign-in header), 128+ (hero).
  final double size;

  const HomefitLogo({super.key, this.size = 32});

  @override
  Widget build(BuildContext context) {
    // Matrix-only aspect: 48 wide × 9.5 tall.
    final width = size;
    final height = size * (9.5 / 48.0);
    return SizedBox(
      width: width,
      height: height,
      child: CustomPaint(painter: _HomefitMatrixPainter()),
    );
  }
}

/// Lockup variant — wordmark stacked above the matrix. Use on hero
/// surfaces where the mark has to stand alone. Matrix geometry is
/// identical to [HomefitLogo], translated +4.5 on Y to make room for
/// the wordmark row.
class HomefitLogoLockup extends StatelessWidget {
  /// Logical pixel width. Sensible values: 96 (hero), 160+ (marketing).
  final double size;

  const HomefitLogoLockup({super.key, this.size = 120});

  @override
  Widget build(BuildContext context) {
    // Lockup aspect: 48 wide × 16 tall (includes 2-unit top padding for
    // wordmark ascender — mirrors SVG viewBox="0 -2 48 16").
    final width = size;
    final height = size * (16.0 / 48.0);
    return SizedBox(
      width: width,
      height: height,
      child: CustomPaint(painter: _HomefitLockupPainter()),
    );
  }
}

// --- Shared geometry helpers ------------------------------------------------

/// 11-element matrix geometry in the source (viewBox-units) space.
/// Y coordinates are relative to the matrix band top (y=1.0 on the
/// 48×9.5 canvas). The lockup painter translates these +4.5 on Y.
///
/// Matches the TSX definition verbatim.
class _Pill {
  final double x;
  final double y;
  final double w;
  final double h;
  final double rx;
  final Color fill;
  const _Pill(this.x, this.y, this.w, this.h, this.rx, this.fill);
}

// Colour tokens — locked to brand.
const _coral = AppColors.primary;
const _sage = AppColors.rest;
// Ghost pill greys — match tokens.json ink-disabled / ink-muted / ink-secondary
// (the canonical #4B5563 / #6B7280 / #9CA3AF ramp from the mockup).
const _ghostOuter = Color(0xFF4B5563);
const _ghostMid = Color(0xFF6B7280);
const _ghostInner = Color(0xFF9CA3AF);

/// Canonical 11-element matrix in the 48×9.5 coordinate system.
final List<_Pill> _matrixPills = <_Pill>[
  // Left ghost pills: outer→inner, progressively larger + lighter.
  _Pill(0, 2.75, 2.5, 1.5, 0.5, _ghostOuter),
  _Pill(4, 2.45, 3.5, 2.1, 0.7, _ghostMid),
  _Pill(9, 2.15, 4.5, 2.7, 0.9, _ghostInner),
  // Ex2 / Ex3 — 2×2 grid (2 exercises × 2 cycles), solid coral.
  _Pill(15, 2, 5, 3, 1, _coral),
  _Pill(15, 6.5, 5, 3, 1, _coral),
  _Pill(21.5, 2, 5, 3, 1, _coral),
  _Pill(21.5, 6.5, 5, 3, 1, _coral),
  // Rest — sage.
  _Pill(28, 2, 5, 3, 1, _sage),
  // Right ghost pills: inner→outer, mirror of left.
  _Pill(34.5, 2.15, 4.5, 2.7, 0.9, _ghostInner),
  _Pill(40.5, 2.45, 3.5, 2.1, 0.7, _ghostMid),
  _Pill(45.5, 2.75, 2.5, 1.5, 0.5, _ghostOuter),
];

/// Coral-tint band sitting behind the circuit columns.
const _bandX = 14.5;
const _bandW = 12.5;
const _bandH = 8.5;
const _bandRx = 1.2;
const _bandY = 1.0; // matrix-only; lockup adds +4.5.

void _paintMatrix(Canvas canvas, Size size, {required double yOffset, required double viewBoxH}) {
  // Scale from the 48×viewBoxH source space into the canvas.
  final sx = size.width / 48.0;
  final sy = size.height / viewBoxH;

  // Band first so pills sit on top.
  final bandPaint = Paint()..color = _coral.withValues(alpha: 0.15);
  canvas.drawRRect(
    RRect.fromRectAndRadius(
      Rect.fromLTWH(_bandX * sx, (_bandY + yOffset) * sy, _bandW * sx, _bandH * sy),
      Radius.circular(_bandRx * ((sx + sy) / 2)),
    ),
    bandPaint,
  );

  for (final p in _matrixPills) {
    final paint = Paint()..color = p.fill;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(p.x * sx, (p.y + yOffset) * sy, p.w * sx, p.h * sy),
        Radius.circular(p.rx * ((sx + sy) / 2)),
      ),
      paint,
    );
  }
}

/// Matrix-only painter (viewBox 48×9.5).
class _HomefitMatrixPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    _paintMatrix(canvas, size, yOffset: 0, viewBoxH: 9.5);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Lockup painter (viewBox 48×14): wordmark row + matrix translated +4.5.
class _HomefitLockupPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    // Wordmark sits at y=4.6 in source units, centered in a 48-wide row.
    // Render via TextPainter with Montserrat 600, scaled so the rendered
    // width is ≤ 48 source units (matches the SVG textLength="48"
    // lengthAdjust="spacingAndGlyphs" behaviour).
    const targetWidthUnits = 48.0;
    const wordmarkUnitHeight = 6.5; // source units
    const viewBoxH = 16.0;

    final sx = size.width / 48.0;
    final sy = size.height / viewBoxH;

    final wordmarkPainter = TextPainter(
      text: TextSpan(
        text: 'homefit.studio',
        style: TextStyle(
          fontFamily: 'Montserrat',
          fontWeight: FontWeight.w600,
          fontSize: wordmarkUnitHeight * sy,
          color: const Color(0xFFF0F0F5),
          letterSpacing: -0.1 * ((sx + sy) / 2),
          height: 1.0,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    );
    wordmarkPainter.layout();

    // Scale horizontally if the natural width exceeds the target (mirrors
    // SVG's spacingAndGlyphs compression).
    final targetWidthPx = targetWidthUnits * sx;
    final scaleX = wordmarkPainter.width > targetWidthPx
        ? targetWidthPx / wordmarkPainter.width
        : 1.0;

    canvas.save();
    // Center the wordmark horizontally, anchor baseline at y=6.6 units
    // (4.6 original + 2-unit top padding for ascender safety).
    final wordmarkYPx = 6.6 * sy - wordmarkPainter.computeDistanceToActualBaseline(TextBaseline.alphabetic);
    final wordmarkXPx = (size.width - wordmarkPainter.width * scaleX) / 2;
    canvas.translate(wordmarkXPx, wordmarkYPx);
    canvas.scale(scaleX, 1.0);
    wordmarkPainter.paint(canvas, Offset.zero);
    canvas.restore();

    // Matrix shifted +6.5 units on Y (4.5 original + 2-unit top padding).
    _paintMatrix(canvas, size, yOffset: 6.5, viewBoxH: viewBoxH);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
