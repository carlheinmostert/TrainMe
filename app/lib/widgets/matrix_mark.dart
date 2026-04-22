import 'package:flutter/material.dart';
import '../theme.dart';
import '../theme/motion.dart';

/// Matrix mark — loading spinner variant of the canonical v2 logo.
///
/// Two widgets share the same 12-element geometry (same 11 pills + 1 coral
/// tint band) as `HomefitLogo`:
///
///   * [MatrixMark]        — static. Renders the canonical v2 matrix at a
///                           given height, no animation. The matrix mark
///                           **never animates outside loading contexts**
///                           (see Design Rule: Loading State spec in
///                           `docs/design/project/components.md`).
///   * [MatrixMarkLoading] — animated spinner. Outer ghost greys on each
///                           side breathe inward via an opacity fade,
///                           staggered at 0 / 0.1s / 0.2s. The four coral
///                           middle pills + tint band hold steady. The
///                           single sage rest pill pulses opacity +
///                           `scaleY(1→1.1→1)` on the same cycle. Period:
///                           [AppMotion.loopCycle] (1.4s = 43bpm).
///
/// When `MediaQuery.of(context).disableAnimations == true`,
/// [MatrixMarkLoading] renders a static [MatrixMark] — no breathing, no
/// sage pulse.
///
/// Geometry canon: `docs/design/project/logos/mark.svg` (static reference)
/// and `docs/design/project/logos/mark-session.svg` (baked SMIL reference).
/// Animated motion lab: `docs/design/mockups/matrix-session-motion.html`.
///
/// Port-sibling of `web-player/styles.css` .mark--loading keyframes +
/// `web-portal/src/components/MatrixMarkLoading.tsx`.

// ─── Shared geometry ───────────────────────────────────────────────────────
// The 11-pill matrix in the canonical 48×9.5 viewBox coordinate space.
// Mirrors _matrixPills in homefit_logo.dart byte-for-byte.

class _Pill {
  final double x;
  final double y;
  final double w;
  final double h;
  final double rx;
  final Color fill;
  final String role;
  const _Pill(this.x, this.y, this.w, this.h, this.rx, this.fill, this.role);
}

const _coral = AppColors.primary;
const _sage = AppColors.rest;
// Ghost pill greys — canonical #4B5563 / #6B7280 / #9CA3AF ramp.
const _ghostOuter = Color(0xFF4B5563);
const _ghostMid = Color(0xFF6B7280);
const _ghostInner = Color(0xFF9CA3AF);

const List<_Pill> _pills = <_Pill>[
  // Left ghost pills — outer → inner (will breathe, in order: 1 → 2 → 3).
  _Pill(0, 2.75, 2.5, 1.5, 0.5, _ghostOuter, 'grey-L-1'),
  _Pill(4, 2.45, 3.5, 2.1, 0.7, _ghostMid, 'grey-L-2'),
  _Pill(9, 2.15, 4.5, 2.7, 0.9, _ghostInner, 'grey-L-3'),
  // Coral 4-cell — static.
  _Pill(15, 2, 5, 3, 1, _coral, 'coral-0'),
  _Pill(15, 6.5, 5, 3, 1, _coral, 'coral-1'),
  _Pill(21.5, 2, 5, 3, 1, _coral, 'coral-2'),
  _Pill(21.5, 6.5, 5, 3, 1, _coral, 'coral-3'),
  // Sage rest pill — pulses opacity + scaleY.
  _Pill(28, 2, 5, 3, 1, _sage, 'rest'),
  // Right ghost pills — inner → outer (will breathe, mirrored: 3 → 2 → 1).
  _Pill(34.5, 2.15, 4.5, 2.7, 0.9, _ghostInner, 'grey-R-3'),
  _Pill(40.5, 2.45, 3.5, 2.1, 0.7, _ghostMid, 'grey-R-2'),
  _Pill(45.5, 2.75, 2.5, 1.5, 0.5, _ghostOuter, 'grey-R-1'),
];

// Coral-tint band (static — behind the coral 4-cell).
const _bandX = 14.5;
const _bandY = 1.0;
const _bandW = 12.5;
const _bandH = 8.5;
const _bandRx = 1.2;

// Stagger begins (fractions of the 1.4s cycle): grey-1 = 0, grey-2 = 0.1s,
// grey-3 = 0.2s. Values correspond to the .mark-breathe-1/2/3 keyframes in
// system.css.
const _staggerSeconds = <String, double>{
  'grey-L-1': 0.0,
  'grey-R-1': 0.0,
  'grey-L-2': 0.1,
  'grey-R-2': 0.1,
  'grey-L-3': 0.2,
  'grey-R-3': 0.2,
};

// Min-opacity trough per breathe keyframe (matches system.css values).
const _breatheMinOpacity = <String, double>{
  'grey-L-1': 0.40,
  'grey-R-1': 0.40,
  'grey-L-2': 0.55,
  'grey-R-2': 0.55,
  'grey-L-3': 0.70,
  'grey-R-3': 0.70,
};

/// Static matrix mark. Defaults to the intrinsic 192×38 rendering but
/// honours any explicit [height] via proportional scaling (aspect 48:9.5).
class MatrixMark extends StatelessWidget {
  /// Logical-pixel height. The width is derived from the 48:9.5 aspect
  /// ratio. Sensible values: 38 (intrinsic, matches SVG width="192"
  /// height="38"), 48 (loading-surface default), 96 (hero loading).
  final double height;

  const MatrixMark({super.key, this.height = 38});

  @override
  Widget build(BuildContext context) {
    final width = height * (48.0 / 9.5);
    return SizedBox(
      width: width,
      height: height,
      child: CustomPaint(painter: const _MatrixMarkPainter()),
    );
  }
}

/// Animated matrix-mark loading spinner. Outer greys breathe, coral 4-cell
/// stays static, sage rest pill pulses opacity + scaleY on
/// [AppMotion.loopCycle].
class MatrixMarkLoading extends StatefulWidget {
  /// Logical-pixel height (width derived from 48:9.5 aspect). Default 48.
  final double height;

  const MatrixMarkLoading({super.key, this.height = 48});

  @override
  State<MatrixMarkLoading> createState() => _MatrixMarkLoadingState();
}

class _MatrixMarkLoadingState extends State<MatrixMarkLoading>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: AppMotion.loopCycle,
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Respect OS "Reduce Motion" preference — fall back to static.
    if (MediaQuery.of(context).disableAnimations) {
      return MatrixMark(height: widget.height);
    }

    final width = widget.height * (48.0 / 9.5);
    return SizedBox(
      width: width,
      height: widget.height,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => CustomPaint(
          painter: _MatrixMarkLoadingPainter(phase: _controller.value),
        ),
      ),
    );
  }
}

// ─── Painters ──────────────────────────────────────────────────────────────

void _paintBand(Canvas canvas, double sx, double sy) {
  final bandPaint = Paint()..color = _coral.withValues(alpha: 0.15);
  canvas.drawRRect(
    RRect.fromRectAndRadius(
      Rect.fromLTWH(_bandX * sx, _bandY * sy, _bandW * sx, _bandH * sy),
      Radius.circular(_bandRx * ((sx + sy) / 2)),
    ),
    bandPaint,
  );
}

void _paintPill(
  Canvas canvas,
  _Pill p,
  double sx,
  double sy, {
  double opacity = 1.0,
  double scaleY = 1.0,
}) {
  final paint = Paint()..color = p.fill.withValues(alpha: opacity);
  final baseRect = Rect.fromLTWH(p.x * sx, p.y * sy, p.w * sx, p.h * sy);

  // Apply scaleY around the pill's vertical centre (transform-origin: center).
  final Rect drawRect;
  if (scaleY == 1.0) {
    drawRect = baseRect;
  } else {
    final cy = baseRect.top + baseRect.height / 2;
    final newH = baseRect.height * scaleY;
    drawRect = Rect.fromLTWH(baseRect.left, cy - newH / 2, baseRect.width, newH);
  }

  canvas.drawRRect(
    RRect.fromRectAndRadius(drawRect, Radius.circular(p.rx * ((sx + sy) / 2))),
    paint,
  );
}

class _MatrixMarkPainter extends CustomPainter {
  const _MatrixMarkPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / 48.0;
    final sy = size.height / 9.5;
    _paintBand(canvas, sx, sy);
    for (final p in _pills) {
      _paintPill(canvas, p, sx, sy);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _MatrixMarkLoadingPainter extends CustomPainter {
  /// Controller phase in [0, 1] (normalised through [AppMotion.loopCycle]).
  final double phase;

  const _MatrixMarkLoadingPainter({required this.phase});

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / 48.0;
    final sy = size.height / 9.5;

    _paintBand(canvas, sx, sy);

    // Cycle time in seconds.
    final cycleSec = AppMotion.loopCycle.inMilliseconds / 1000.0;
    final tSec = phase * cycleSec;

    for (final p in _pills) {
      if (_staggerSeconds.containsKey(p.role)) {
        // Ghost grey — opacity breathe with stagger. Matches
        // @keyframes mark-breathe-{1,2,3} in system.css: 0%/100% = 1.0,
        // 50% = minOpacity (ease in + ease out via Curves.easeInOut).
        final begin = _staggerSeconds[p.role]!;
        final minOp = _breatheMinOpacity[p.role]!;
        // Phase-within-cycle from this pill's begin offset.
        final rawPhase = ((tSec - begin) % cycleSec) / cycleSec;
        // Triangle wave 0→1→0 to drive a smooth fade and recovery.
        final tri = rawPhase < 0.5 ? rawPhase * 2 : (1 - rawPhase) * 2;
        final eased = Curves.easeInOut.transform(tri);
        final opacity = 1.0 - eased * (1.0 - minOp);
        _paintPill(canvas, p, sx, sy, opacity: opacity);
      } else if (p.role == 'rest') {
        // Sage rest — opacity 1→0.6→1 + scaleY 1→1.1→1 on the same cycle.
        // Matches @keyframes mark-pulse-sage in system.css.
        final tri = phase < 0.5 ? phase * 2 : (1 - phase) * 2;
        final eased = Curves.easeInOut.transform(tri);
        final opacity = 1.0 - eased * (1.0 - 0.6);
        final scaleY = 1.0 + eased * (1.1 - 1.0);
        _paintPill(canvas, p, sx, sy, opacity: opacity, scaleY: scaleY);
      } else {
        // Coral 4-cell — intentionally static.
        _paintPill(canvas, p, sx, sy);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _MatrixMarkLoadingPainter oldDelegate) =>
      oldDelegate.phase != phase;
}
