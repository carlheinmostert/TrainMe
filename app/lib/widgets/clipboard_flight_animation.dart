import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/exercise_capture.dart';
import '../theme.dart';
import 'mini_preview.dart';

/// Direction of a clipboard flight animation.
///
/// * [copy] — hero lifts off the source card, arcs UP to the chip,
///   shrinks to chip-size, lands.
/// * [paste] — hero emerges FROM the chip, arcs DOWN to the destination
///   row, grows from chip-size to card-hero-size, settles.
enum ClipboardFlightDirection { copy, paste }

/// Plays the "exercise hero lifts and arcs to the clipboard chip"
/// animation (Variant 1 from the
/// `docs/design/mockups/2026-05-25-clipboard-copy-animation.html`
/// mockup, item M15 from `docs/test-scripts/2026-05-25-stack.md`).
///
/// Renders the SAME hero render as the source card (via [MiniPreview]
/// with `staticHero: true`) inside a transient [OverlayEntry] that
/// animates between [from] and [to] rects. The arc lift is added by
/// pulling the y-axis upward at the midpoint via a quadratic Bezier
/// control point.
///
/// Routes through [MiniPreview] per
/// `feedback_hero_resolver_single_source.md` — the flying widget is
/// the canonical hero render, NOT a placeholder or particle. This
/// keeps the visual identity of the source card consistent with the
/// flying subject.
///
/// On copy: a small scale-up (~1.05) eases in at the start so the
/// thumbnail "lifts" off the card before flying.
/// On paste: a small scale-up settles at the end so the thumbnail
/// "lands" into the destination row.
///
/// Caller passes [direction] to flip the lift / land phases. The
/// arc geometry stays the same (concave-up midpoint).
///
/// Use [playClipboardHeroFlight] as the entry point. On animation
/// completion the entry removes itself and [onLanded] fires —
/// callers chain chip pulse + count bump + haptic off this callback.
Future<void> playClipboardHeroFlight(
  BuildContext context, {
  required ExerciseCapture exercise,
  required Rect from,
  required Rect to,
  required ClipboardFlightDirection direction,
  VoidCallback? onLanded,
  Duration duration = const Duration(milliseconds: 700),
}) async {
  final overlay = Overlay.of(context, rootOverlay: true);
  late final OverlayEntry entry;
  final completer = Completer<void>();

  entry = OverlayEntry(
    builder: (_) => _ClipboardHeroFlight(
      exercise: exercise,
      from: from,
      to: to,
      direction: direction,
      duration: duration,
      onLanded: () {
        onLanded?.call();
      },
      onDone: () {
        if (entry.mounted) entry.remove();
        if (!completer.isCompleted) completer.complete();
      },
    ),
  );
  overlay.insert(entry);
  return completer.future;
}

/// Internal flying widget — animates a rectangle (size + position) and
/// renders the exercise's canonical hero inside it.
class _ClipboardHeroFlight extends StatefulWidget {
  final ExerciseCapture exercise;
  final Rect from;
  final Rect to;
  final ClipboardFlightDirection direction;
  final Duration duration;
  final VoidCallback onLanded;
  final VoidCallback onDone;

  const _ClipboardHeroFlight({
    required this.exercise,
    required this.from,
    required this.to,
    required this.direction,
    required this.duration,
    required this.onLanded,
    required this.onDone,
  });

  @override
  State<_ClipboardHeroFlight> createState() => _ClipboardHeroFlightState();
}

class _ClipboardHeroFlightState extends State<_ClipboardHeroFlight>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _landedFired = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
    );
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        if (!_landedFired) {
          _landedFired = true;
          widget.onLanded();
        }
        widget.onDone();
      }
    });
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Apex of the arc — pull the midpoint upward so the hero traces a
  /// satisfying parabolic curve. Concave-up regardless of direction
  /// (copy lifts up to the chip, paste rises briefly before settling
  /// into the target).
  double _arcLift() {
    final dy = (widget.from.top - widget.to.top).abs();
    return math.max(dy * 0.20, 60.0);
  }

  /// Bezier interpolation between two values (top-left coords are
  /// interpolated separately, size is linearly interpolated).
  double _bezierY(double y0, double yC, double y2, double t) {
    return math.pow(1 - t, 2).toDouble() * y0 +
        2 * (1 - t) * t * yC +
        t * t * y2;
  }

  @override
  Widget build(BuildContext context) {
    final lift = _arcLift();
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (_, _) {
          final raw = _controller.value;
          final t = Curves.easeInOutCubic.transform(raw);

          // Interpolate the top-left point along an arc (linear X,
          // bezier-lifted Y) and the size linearly. Treat the flying
          // widget as a rectangle whose CENTRE traces the arc — this
          // makes the visual feel anchored to the subject rather than
          // its top-left pixel.
          final fromCenter = widget.from.center;
          final toCenter = widget.to.center;
          final midCenter = Offset(
            (fromCenter.dx + toCenter.dx) / 2,
            (fromCenter.dy + toCenter.dy) / 2 - lift,
          );

          final centerX = (1 - t) * fromCenter.dx + t * toCenter.dx;
          final centerY = _bezierY(
            fromCenter.dy,
            midCenter.dy,
            toCenter.dy,
            t,
          );

          final width = (1 - t) * widget.from.width + t * widget.to.width;
          final height = (1 - t) * widget.from.height + t * widget.to.height;

          // Lift / land pop — 5% scale boost at start (copy) or end
          // (paste) so the subject feels grabbed / placed rather than
          // teleported.
          final popScale = _popScale(raw);

          // Hero opacity fades out near the very end of a copy so it
          // dissolves into the chip pulse, and fades IN at the start
          // of a paste so the chip doesn't visibly eject a full-size
          // hero before it scales down.
          final opacity = _phaseOpacity(t);

          // Soft drop-shadow that strengthens at the start of a copy
          // (lift feeling) and softens to chip-flat at the end. For
          // paste, do the opposite — emerge flat and settle with
          // shadow as the subject reaches the destination.
          final shadowStrength = widget.direction ==
                  ClipboardFlightDirection.copy
              ? (1 - t).clamp(0.0, 1.0)
              : t.clamp(0.0, 1.0);

          return Stack(
            children: [
              Positioned(
                left: centerX - (width * popScale) / 2,
                top: centerY - (height * popScale) / 2,
                width: width * popScale,
                height: height * popScale,
                child: Opacity(
                  opacity: opacity,
                  child: _FlyingHero(
                    exercise: widget.exercise,
                    shadowStrength: shadowStrength,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  double _popScale(double raw) {
    // Copy: 1.0 → 1.05 → 1.0 (lift at start).
    // Paste: 1.0 → 1.05 (settle at end).
    if (widget.direction == ClipboardFlightDirection.copy) {
      if (raw < 0.15) {
        final localT = raw / 0.15;
        return 1.0 + 0.05 * Curves.easeOut.transform(localT);
      } else if (raw < 0.30) {
        final localT = (raw - 0.15) / 0.15;
        return 1.05 - 0.05 * Curves.easeIn.transform(localT);
      }
      return 1.0;
    } else {
      if (raw > 0.80) {
        final localT = (raw - 0.80) / 0.20;
        return 1.0 + 0.05 * Curves.easeOutCubic.transform(localT);
      }
      return 1.0;
    }
  }

  double _phaseOpacity(double t) {
    if (widget.direction == ClipboardFlightDirection.copy) {
      // Hold opacity until very late, then fade into the chip in the
      // last 8% — the chip's own pulse takes over from there.
      if (t < 0.92) return 1.0;
      return (1 - (t - 0.92) / 0.08).clamp(0.0, 1.0);
    } else {
      // Paste: chip ejects a near-invisible hero that fades up in the
      // first 12% so the chip doesn't appear to disgorge a full-size
      // thumbnail.
      if (t < 0.12) return (t / 0.12).clamp(0.0, 1.0);
      return 1.0;
    }
  }
}

/// The visible hero inside the flying overlay. Wraps [MiniPreview] —
/// the canonical hero render used by Studio cards — so the in-flight
/// subject matches the source card pixel-for-pixel.
class _FlyingHero extends StatelessWidget {
  final ExerciseCapture exercise;
  final double shadowStrength;

  const _FlyingHero({
    required this.exercise,
    required this.shadowStrength,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45 * shadowStrength),
            blurRadius: 18 * shadowStrength + 2,
            offset: Offset(0, 6 * shadowStrength + 1),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Container(
          // Coral hairline so the flying hero reads as a "lifted" tile
          // even when over a busy background. Matches the chip's
          // coral identity per the mockup's Variant 1.
          decoration: BoxDecoration(
            border: Border.all(
              color: AppColors.primary.withValues(alpha: 0.35),
              width: 1,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: MiniPreview(
            exercise: exercise,
            width: double.infinity,
            borderRadius: BorderRadius.zero,
            staticHero: true,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Back-compat shim
// ---------------------------------------------------------------------------

/// Deprecated — kept so any out-of-tree caller (none in this repo at
/// time of writing) still compiles. Forwards to the new hero-flight
/// animation but degrades to a small synthetic exercise hero render
/// (line-drawing placeholder) since no exercise is supplied.
///
/// New callers MUST use [playClipboardHeroFlight].
@Deprecated('Use playClipboardHeroFlight with a real exercise + rects.')
Future<void> playClipboardFlight(
  BuildContext context, {
  required Offset from,
  required Offset to,
  VoidCallback? onLanded,
  Duration duration = const Duration(milliseconds: 700),
}) async {
  // Treat the points as tiny rects so the geometry still works. The
  // legacy API does not pass an exercise — render nothing inside the
  // flying widget (transparent box). New callers should switch to
  // [playClipboardHeroFlight].
  final overlay = Overlay.of(context, rootOverlay: true);
  late final OverlayEntry entry;
  final completer = Completer<void>();

  entry = OverlayEntry(
    builder: (_) => _LegacyPointFlight(
      from: Rect.fromCenter(center: from, width: 24, height: 24),
      to: Rect.fromCenter(center: to, width: 24, height: 24),
      duration: duration,
      onLanded: () => onLanded?.call(),
      onDone: () {
        if (entry.mounted) entry.remove();
        if (!completer.isCompleted) completer.complete();
      },
    ),
  );
  overlay.insert(entry);
  return completer.future;
}

class _LegacyPointFlight extends StatefulWidget {
  final Rect from;
  final Rect to;
  final Duration duration;
  final VoidCallback onLanded;
  final VoidCallback onDone;

  const _LegacyPointFlight({
    required this.from,
    required this.to,
    required this.duration,
    required this.onLanded,
    required this.onDone,
  });

  @override
  State<_LegacyPointFlight> createState() => _LegacyPointFlightState();
}

class _LegacyPointFlightState extends State<_LegacyPointFlight>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _landedFired = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration);
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        if (!_landedFired) {
          _landedFired = true;
          widget.onLanded();
        }
        widget.onDone();
      }
    });
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (_, _) {
          final t = Curves.easeInOutCubic.transform(_controller.value);
          final x = (1 - t) * widget.from.center.dx + t * widget.to.center.dx;
          final y = (1 - t) * widget.from.center.dy + t * widget.to.center.dy;
          return Positioned(
            left: x - 12,
            top: y - 12,
            child: Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: AppColors.primary,
                shape: BoxShape.circle,
              ),
            ),
          );
        },
      ),
    );
  }
}
