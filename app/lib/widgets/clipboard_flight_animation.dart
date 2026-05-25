import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

/// Plays the "exercise flies to the clipboard chip" coral particle
/// animation (`docs/specs/2026-05-25-exercise-clipboard.md`, the
/// Behaviour > Copy > Animation section).
///
/// Renders as a transient `OverlayEntry` so the particle floats above
/// Studio chrome without rebuilding the screen. The arc is a quadratic
/// Bezier from the source point (the practitioner's tapped card or the
/// editor-sheet Copy button) to the chip anchor (top-right of the
/// AppBar). On completion the entry removes itself and an optional
/// [onLanded] callback fires — Studio uses this to trigger the chip's
/// pulse + the count bump.
///
/// Use [playClipboardFlight] as the entry point. Callers compute the
/// source / target points in global coordinates and pass them in; the
/// helper deals with overlay insertion, animation lifecycle, and
/// cleanup.
Future<void> playClipboardFlight(
  BuildContext context, {
  required Offset from,
  required Offset to,
  VoidCallback? onLanded,
  Duration duration = const Duration(milliseconds: 420),
}) async {
  final overlay = Overlay.of(context, rootOverlay: true);
  late final OverlayEntry entry;
  final completer = Completer<void>();

  entry = OverlayEntry(
    builder: (_) => _ClipboardFlight(
      from: from,
      to: to,
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

/// Internal widget — the actual painter + AnimationController.
class _ClipboardFlight extends StatefulWidget {
  final Offset from;
  final Offset to;
  final Duration duration;
  final VoidCallback onLanded;
  final VoidCallback onDone;

  const _ClipboardFlight({
    required this.from,
    required this.to,
    required this.duration,
    required this.onLanded,
    required this.onDone,
  });

  @override
  State<_ClipboardFlight> createState() => _ClipboardFlightState();
}

class _ClipboardFlightState extends State<_ClipboardFlight>
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

  /// Apex of the arc — pull the midpoint upward by 30% of the vertical
  /// distance so the particle traces a satisfying parabolic curve from
  /// any source to the chip in the top-right.
  Offset _controlPoint() {
    final mid = Offset(
      (widget.from.dx + widget.to.dx) / 2,
      (widget.from.dy + widget.to.dy) / 2,
    );
    final dy = widget.from.dy - widget.to.dy;
    final lift = math.max(dy.abs() * 0.35, 80.0);
    return Offset(mid.dx, mid.dy - lift);
  }

  @override
  Widget build(BuildContext context) {
    final control = _controlPoint();
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (_, _) {
          final t = Curves.easeInOutCubic.transform(_controller.value);
          // Quadratic Bezier: P = (1-t)^2 * P0 + 2(1-t)t * P1 + t^2 * P2.
          final pos = Offset(
            math.pow(1 - t, 2).toDouble() * widget.from.dx +
                2 * (1 - t) * t * control.dx +
                t * t * widget.to.dx,
            math.pow(1 - t, 2).toDouble() * widget.from.dy +
                2 * (1 - t) * t * control.dy +
                t * t * widget.to.dy,
          );
          // Particle shrinks as it approaches the chip — feels like a
          // capture rather than a delivery.
          final scale = 1.0 - 0.55 * t;
          final opacity = t < 0.85 ? 1.0 : (1 - (t - 0.85) / 0.15);
          return Stack(
            children: [
              Positioned(
                left: pos.dx - 12 * scale,
                top: pos.dy - 12 * scale,
                child: Opacity(
                  opacity: opacity.clamp(0.0, 1.0),
                  child: Transform.scale(
                    scale: scale,
                    child: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: AppColors.primary,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.primary.withValues(alpha: 0.55),
                            blurRadius: 12,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.content_paste,
                        size: 14,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

