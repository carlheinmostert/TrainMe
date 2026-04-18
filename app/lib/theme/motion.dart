import 'package:flutter/animation.dart';

// ---------------------------------------------------------------------------
// HomeFit Studio — Motion tokens (D-04)
// ---------------------------------------------------------------------------
//
// Canonical animation durations and easings. Mirrors web-player/styles.css
// `--dur-*` / `--ease-*` and web-portal tailwind `transitionDuration` /
// `transitionTimingFunction`. Keep in lockstep.
//
// Usage:
//   AnimatedContainer(duration: AppMotion.normal, curve: AppMotion.standard)
//
class AppMotion {
  AppMotion._();

  // ── Durations ──
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration normal = Duration(milliseconds: 250);
  static const Duration slow = Duration(milliseconds: 400);

  // ── Easings ──
  /// Default. Material-ish ease-out.
  static const Curve standard = Cubic(0.2, 0, 0, 1);

  /// Entrances, modals, primary feedback.
  static const Curve emphasized = Cubic(0.16, 1, 0.3, 1);

  /// Progress bars, timer fills.
  static const Curve linear = Curves.linear;

  // ── Pulse Mark rhythm ──
  /// 1.4s = ~43bpm resting heartbeat. Slow, calm.
  static const Duration pulseCycle = Duration(milliseconds: 1400);
}
