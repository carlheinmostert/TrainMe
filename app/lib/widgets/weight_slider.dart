import 'package:flutter/material.dart';

import '../theme.dart';
import 'branded_slider_theme.dart';

/// Stepped weight slider for the per-set DOSE table editor.
///
/// Renders an N/A toggle on the left and a Material `Slider` on the
/// right. Range is 0–200 kg in 2.5 kg increments (`divisions: 80`); the
/// slider reports its current value via [onChanged] only when the
/// active state is non-null. Toggling the N/A pill flips the value to
/// `null` (bodyweight); a fresh tap from N/A → kg restores a sensible
/// default (10 kg or the last-known value if the parent passes one in).
///
/// Mirrors `docs/design/mockups/exercise-card-dose-table.html` state 8
/// (the weight editor with stepped ticks + bubble + N/A toggle).
class WeightSlider extends StatefulWidget {
  /// Current weight in kg, or `null` for bodyweight.
  final double? valueKg;

  /// Fired when the practitioner adjusts the slider OR toggles N/A. The
  /// parent should treat null as "bodyweight" — the same semantics the
  /// `ExerciseSet.weightKg` field carries.
  final ValueChanged<double?> onChanged;

  /// Default kg value used when toggling out of N/A. Falls back to 10 kg
  /// if the caller doesn't pass anything.
  final double restoreDefaultKg;

  const WeightSlider({
    super.key,
    required this.valueKg,
    required this.onChanged,
    this.restoreDefaultKg = 10.0,
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
    final isNa = widget.valueKg == null;
    final activeKg = widget.valueKg ?? widget.restoreDefaultKg;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Leading N/A toggle.
            _NaToggleButton(
              isActive: isNa,
              onTap: _toggleNa,
            ),
            const SizedBox(width: 12),
            // Trailing live readout — mirrors the mockup's bubble,
            // simplified for inline use.
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: isNa
                        ? Colors.transparent
                        : AppColors.brandTintBg,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isNa
                          ? AppColors.surfaceBorder
                          : AppColors.brandTintBorder,
                      width: 1,
                    ),
                  ),
                  child: Text(
                    isNa ? 'Bodyweight' : _formatKg(activeKg),
                    style: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: isNa
                          ? AppColors.textSecondaryOnDark
                          : AppColors.primary,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // Slider — disabled when N/A is active (Material `Slider` greys
        // itself out automatically when [onChanged] is null).
        //
        // Round 2 — wrap in a GestureDetector that claims horizontal pan
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
              label: _formatKg(activeKg),
              onChanged: isNa
                  ? null
                  : (v) => widget.onChanged(_snapToStep(v)),
            ),
          ),
        ),
        // Tick axis — mono numerals at 0 / 50 / 100 / 150 / 200.
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _AxisTick('0'),
              _AxisTick('50'),
              _AxisTick('100'),
              _AxisTick('150'),
              _AxisTick('200'),
            ],
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'drag · 2.5 kg steps · range 0–200 kg',
          style: TextStyle(
            fontFamily: 'JetBrainsMono',
            fontSize: 10,
            color: AppColors.textSecondaryOnDark,
            letterSpacing: 0.3,
          ),
        ),
      ],
    );
  }

  void _toggleNa() {
    if (widget.valueKg == null) {
      // Restore to the configured default.
      widget.onChanged(_snapToStep(widget.restoreDefaultKg));
    } else {
      widget.onChanged(null);
    }
  }

  /// Snap to the nearest 2.5 kg step within [_kMin, _kMax].
  double _snapToStep(double kg) {
    final clamped = kg.clamp(_kMin, _kMax);
    final stepped = (clamped / 2.5).round() * 2.5;
    return stepped;
  }

  String _formatKg(double kg) {
    if (kg == kg.roundToDouble()) {
      return '${kg.toStringAsFixed(0)} kg';
    }
    return '${kg.toStringAsFixed(1)} kg';
  }
}

class _NaToggleButton extends StatelessWidget {
  final bool isActive;
  final VoidCallback onTap;

  const _NaToggleButton({required this.isActive, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: isActive
                ? Colors.black.withValues(alpha: 0.20)
                : AppColors.surfaceBase,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: AppColors.surfaceBorder,
              width: 1,
            ),
          ),
          child: Text(
            isActive ? '— N/A' : 'N/A',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: isActive
                  ? AppColors.textSecondaryOnDark
                  : AppColors.textOnDark,
              letterSpacing: 0.4,
            ),
          ),
        ),
      ),
    );
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
