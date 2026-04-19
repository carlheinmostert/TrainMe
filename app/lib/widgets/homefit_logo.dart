import 'package:flutter/material.dart';
import '../theme.dart';

/// homefit.studio logo — the "Full Session" mark.
///
/// Renders a valid training-plan snippet using the exact visual vocabulary
/// of the progress-pill matrix: a 2-exercise circuit × 2 rounds, followed
/// by a standalone exercise, followed by a rest period.
///
/// The logo IS the product. Reading left→right the shape is the literal
/// output the matrix would draw for that plan — coral pills for exercises,
/// a coral-tinted band behind the circuit columns, entry + exit rail
/// stubs, and a sage rest pill closing the sequence.
///
/// No invented shapes. No icons, letters, or decorative curves. See
/// docs/design/mockups/logo-explorations.html for the exploration set
/// this was chosen from.
///
/// Scales proportionally to whatever [size] the parent provides.
class HomefitLogo extends StatelessWidget {
  /// Logical pixel size. The logo fits within a square of this width and
  /// scales its pill/rail geometry proportionally. Sensible values: 18
  /// (favicon/footer), 32 (inline badge), 64 (sign-in header), 128+.
  final double size;

  const HomefitLogo({super.key, this.size = 32});

  @override
  Widget build(BuildContext context) {
    // Aspect ratio derived from the logo's natural proportions: 4 columns
    // wide × 2 rows tall (circuit is 2 rows). Render inside a fixed
    // width:height box so callers can drop it into Rows without extra
    // sizing.
    final width = size;
    final height = size * (10.0 / 22.0); // matches painter's viewBox
    return SizedBox(
      width: width,
      height: height,
      child: CustomPaint(painter: _HomefitLogoPainter()),
    );
  }
}

/// Renders the Full Session plan:
///   [circuit cols=2 rows=2] · [standalone] · [rest]
///
/// All geometry is proportional to the canvas size. The "unit" is derived
/// from the canvas width so the logo scales cleanly from favicon to
/// billboard.
class _HomefitLogoPainter extends CustomPainter {
  _HomefitLogoPainter();

  // Colour tokens — locked to brand.
  static const _coral = AppColors.primary;
  static final _coralBand = AppColors.primary.withValues(alpha: 0.15);
  static const _sage = AppColors.rest;

  @override
  void paint(Canvas canvas, Size size) {
    // Layout unit — all geometry scales from this. Each pill is
    // roughly one unit tall.
    //
    // Natural viewBox: 4 columns × stride (1.25) + 2 stubs (0.5 each) ≈ 6
    // wide. 2 rows × rowStride (1.25) + 0.3 band inset × 2 = 3.1 tall.
    //
    // We compute unit from height to keep pills square-ish. Width
    // content then has to fit in size.width; if not, scale down.
    const pillAspectH = 1.0;   // height units
    const pillAspectW = 1.1;   // slightly wider than tall
    const gap = 0.25;          // inter-pill gap in units
    const bandInset = 0.18;    // band overflow around circuit columns
    const railStub = 0.35;     // entry/exit stub length
    const railWidth = 0.09;    // rail stroke thickness in units
    const cornerRadius = 0.22; // pill corner radius in units

    // Layout: 4 columns, circuit has 2 rows, others have 1 row.
    // Column layout:
    //   col 0: circuit (2 rows)
    //   col 1: circuit (2 rows)
    //   col 2: standalone
    //   col 3: rest
    const cols = 4;
    const maxRows = 2;

    final stride = pillAspectW + gap;
    final rowStride = pillAspectH + gap;

    // Content bounds in units (includes band inset + rail stubs).
    final contentW = cols * stride - gap + bandInset * 2 + railStub * 2;
    final contentH = maxRows * rowStride - gap + bandInset * 2;

    // Fit to canvas — preserve aspect ratio.
    final unitX = size.width / contentW;
    final unitY = size.height / contentH;
    final unit = unitX < unitY ? unitX : unitY;

    // Offsets so the drawn content is centred inside the canvas.
    final dx = (size.width - contentW * unit) / 2 + railStub * unit;
    final dy = (size.height - contentH * unit) / 2 + bandInset * unit;

    // Helpers
    double x(double u) => dx + u * unit;
    double y(double u) => dy + u * unit;

    final pillW = pillAspectW * unit;
    final pillH = pillAspectH * unit;
    final radius = Radius.circular(cornerRadius * unit);

    // Draw circuit band — spans cols 0..1.
    final bandPaint = Paint()..color = _coralBand;
    final bandLeft = x(-bandInset);
    final bandTop = y(-bandInset);
    final bandRight = x(2 * stride - gap + bandInset);
    final bandBottom = y(maxRows * rowStride - gap + bandInset);
    final bandRect = RRect.fromLTRBR(
      bandLeft,
      bandTop,
      bandRight,
      bandBottom,
      Radius.circular(cornerRadius * unit * 1.2),
    );
    canvas.drawRRect(bandRect, bandPaint);

    // Draw rail stubs.
    //
    // The circuit is flanked by standalones-or-rests on its right side
    // (col 2 is a standalone). We only draw a stub on the side that
    // hands off to an adjacent column. Left side is the start of the
    // logo, so we also draw a leading stub for visual balance — it
    // "enters" the plan like a natural ancestor exists off-frame.
    final railPaint = Paint()
      ..color = _coral.withValues(alpha: 0.85)
      ..style = PaintingStyle.fill;

    // Entry stub — horizontal, at top-row mid-y, from left of band to
    // canvas left edge.
    final firstRowMidY = y(pillH / unit / 2);
    canvas.drawRect(
      Rect.fromLTRB(
        x(-bandInset) - railStub * unit,
        firstRowMidY - railWidth * unit / 2,
        bandLeft,
        firstRowMidY + railWidth * unit / 2,
      ),
      railPaint,
    );

    // Exit stub — horizontal, at bottom-row mid-y. Short terminus
    // right after the band; does NOT extend toward the standalone
    // column (which is anchored at row 0, so there's nothing to
    // connect to at this y-coordinate). Matches how the real matrix
    // renders a circuit-terminating stub.
    final lastRowMidY = y(rowStride + pillH / unit / 2);
    canvas.drawRect(
      Rect.fromLTRB(
        bandRight,
        lastRowMidY - railWidth * unit / 2,
        bandRight + railStub * unit,
        lastRowMidY + railWidth * unit / 2,
      ),
      railPaint,
    );

    // Draw pills.
    final coralFill = Paint()..color = _coral;
    final sageFill = Paint()..color = _sage;

    void drawPill(double col, double row, {required bool isRest}) {
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x(col * stride), y(row * rowStride), pillW, pillH),
        radius,
      );
      canvas.drawRRect(rect, isRest ? sageFill : coralFill);
    }

    // Circuit: 2 cols × 2 rows.
    for (var c = 0; c < 2; c++) {
      for (var r = 0; r < 2; r++) {
        drawPill(c.toDouble(), r.toDouble(), isRest: false);
      }
    }
    // Standalone at col 2, row 0. The real progress-pill matrix always
    // anchors non-circuit columns to the TOP row — a 1-row column sits
    // at row 0 while an N-row circuit column fills rows 0..N-1. The
    // circuit's exit stub (at bottom-row mid-y) is a stub INTO empty
    // space below the standalone, not a connector to it — matching
    // what the real matrix draws.
    drawPill(2, 0, isRest: false);
    // Rest also at row 0 of col 3.
    drawPill(3, 0, isRest: true);

  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
