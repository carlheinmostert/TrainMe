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

  // ── Shared loading rhythm ──
  /// Matrix-mark spinner + skeleton sweep. 1.4s = ~43bpm — slow, calm.
  /// Mirrors `motion.loop` in tokens.json.
  static const Duration loopCycle = Duration(milliseconds: 1400);

  /// Easing companion for [loopCycle]: cubic-bezier(0.4, 0, 0.6, 1).
  static const Curve loopEasing = Curves.easeInOut;

  @Deprecated('Use AppMotion.loopCycle — renamed in 1.2.0 when Pulse Mark retired.')
  static const Duration pulseCycle = loopCycle;
}
