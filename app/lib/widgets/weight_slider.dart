import 'package:flutter/material.dart';

import '../theme.dart';
import 'branded_slider_theme.dart';

/// Stepped weight slider for the per-set DOSE table editor.
///
/// Round 3 — chrome retired per Carl: no leading N/A toggle, no readout
/// bubble, no trailing subtitle. The slider's leftmost stop (0 kg) is the
/// bodyweight (N/A) state — drag to 0 to clear, drag right to dial in a
/// load. The Material `Slider`'s built-in label-on-thumb shows the live
/// value during drag.
///
/// Range is 0–200 kg in 2.5 kg increments (`divisions: 80`); the slider
/// reports `null` to the parent on the leftmost stop and the snapped kg
/// value otherwise.
class WeightSlider extends StatefulWidget {
  /// Current weight in kg, or `null` for bodyweight.
  final double? valueKg;

  /// Fired when the practitioner adjusts the slider. The parent should
  /// treat null as "bodyweight" — the same semantics the
  /// `ExerciseSet.weightKg` field carries. The leftmost slider stop
  /// (0 kg) is reported as null.
  final ValueChanged<double?> onChanged;

  /// Default kg value used as the slider's display when the persisted
  /// value is null. Falls back to 0 (bodyweight) if the caller doesn't
  /// pass anything. Mostly historical — Round 3 thumb starts at 0 by
  /// default since 0 = N/A.
  final double restoreDefaultKg;

  /// Fired when the practitioner commits a value — drag-end OR
  /// tap-to-position. Used by the parent (DoseTable) to dismiss the
  /// inline editor block on commit, bringing the weight cell into
  /// parity with reps / hold / breather (which auto-close on chip tap).
  final VoidCallback? onCommit;

  const WeightSlider({
    super.key,
    required this.valueKg,
    required this.onChanged,
    this.restoreDefaultKg = 0.0,
    this.onCommit,
  });

  @override
  State<WeightSlider> createState() => _WeightSliderState();
}

class _WeightSliderState extends State<WeightSlider> {
  static const double _kMin = 0.0;
  static const double _kMax = 200.0;

  /// Slider divisions — 200 / 2.5 = 80 stops. Keeps the snap behaviour
  /// matching the design spec without hand-rolling tick rendering.
  static const int _kDivisions = 80;

  @override
  Widget build(BuildContext context) {
    // Round 3 — null (bodyweight) renders as 0 on the slider; drag back
    // to 0 emits null to the parent.
    final activeKg = widget.valueKg ?? 0.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Slider — Round 3 carries N/A semantics in its leftmost stop.
        // Wrap in a GestureDetector that claims horizontal pan
        // explicitly. Inside the editor sheet, the host SingleChildScroll-
        // View / DraggableScrollableSheet was capturing pan gestures
        // before Slider's own HorizontalDragGestureRecognizer could win
        // the arena, dragging the SHEET vertically instead of moving the
        // slider thumb. Registering empty horizontal handlers + opaque
        // hit-test keeps the slider as the gesture target.
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (_) {},
          onHorizontalDragUpdate: (_) {},
          onHorizontalDragEnd: (_) {},
          child: SliderTheme(
            data: brandedSliderTheme(
              accent: AppColors.primary,
              trackHeight: 4,
              thumbHeight: 22,
              thumbWidth: 22,
              thumbRadius: 11,
            ),
            child: Slider(
              value: activeKg.clamp(_kMin, _kMax),
              min: _kMin,
              max: _kMax,
              divisions: _kDivisions,
              label: _labelFor(activeKg),
              onChanged: (v) {
                final snapped = _snapToStep(v);
                // Leftmost stop = bodyweight (null) by Round 3 spec.
                widget.onChanged(snapped == 0 ? null : snapped);
              },
              // Slider's onChangeEnd fires on drag release AND
              // tap-to-position. One hook covers both commit paths,
              // bringing weight into parity with the chip-row pills
              // (reps / hold / breather) that auto-close on tap.
              onChangeEnd: (_) => widget.onCommit?.call(),
            ),
          ),
        ),
        // Tick axis — mono numerals at 0 / 50 / 100 / 150 / 200. The
        // leftmost '0' tick now reads as the N/A stop semantically.
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _AxisTick('N/A'),
              _AxisTick('50'),
              _AxisTick('100'),
              _AxisTick('150'),
              _AxisTick('200'),
            ],
          ),
        ),
      ],
    );
  }

  /// Snap to the nearest 2.5 kg step within [_kMin, _kMax].
  double _snapToStep(double kg) {
    final clamped = kg.clamp(_kMin, _kMax);
    final stepped = (clamped / 2.5).round() * 2.5;
    return stepped;
  }

  /// Format the slider's bubble label. 0 → 'N/A', whole kg → '15 kg',
  /// half-step → '17.5 kg'.
  String _labelFor(double kg) {
    if (kg == 0) return 'N/A';
    if (kg == kg.roundToDouble()) {
      return '${kg.toStringAsFixed(0)} kg';
    }
    return '${kg.toStringAsFixed(1)} kg';
  }
}

class _AxisTick extends StatelessWidget {
  final String label;
  const _AxisTick(this.label);

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: const TextStyle(
        fontFamily: 'JetBrainsMono',
        fontSize: 10,
        color: AppColors.textSecondaryOnDark,
        letterSpacing: 0.3,
      ),
    );
  }
}
