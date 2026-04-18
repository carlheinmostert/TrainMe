import 'package:flutter/material.dart';
import '../theme.dart';

/// Rectangular / pill-shaped slider thumb used across the app. Gives the
/// sliders a bolder, more tactile feel than the stock round thumb.
class RectangularSliderThumbShape extends SliderComponentShape {
  final double width;
  final double height;
  final double radius;

  const RectangularSliderThumbShape({
    this.width = 8,
    this.height = 24,
    this.radius = 4,
  });

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => Size(width, height);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final canvas = context.canvas;
    final paint = Paint()
      ..color = sliderTheme.thumbColor ?? Colors.black87
      ..style = PaintingStyle.fill;

    final rect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: center, width: width, height: height),
      Radius.circular(radius),
    );
    canvas.drawRRect(rect, paint);
  }
}

/// Returns a [SliderThemeData] configured for the HomeFit brand — thick
/// track, rectangular thumb, subtle overlay halo. The [accent] colour is
/// applied to the active track, thumb, and overlay.
SliderThemeData brandedSliderTheme({
  required Color accent,
  double trackHeight = 8,
  double thumbHeight = 24,
  double thumbWidth = 8,
  double thumbRadius = 4,
  double? overlayRadius,
  Color? inactiveTrackColor,
}) {
  return SliderThemeData(
    trackHeight: trackHeight,
    activeTrackColor: accent,
    inactiveTrackColor: inactiveTrackColor ?? AppColors.surfaceBorder,
    thumbColor: accent,
    thumbShape: RectangularSliderThumbShape(
      width: thumbWidth,
      height: thumbHeight,
      radius: thumbRadius,
    ),
    overlayShape: RoundSliderOverlayShape(
      overlayRadius: overlayRadius ?? (thumbHeight - 4),
    ),
    overlayColor: accent.withValues(alpha: 0.12),
    trackShape: const RoundedRectSliderTrackShape(),
  );
}
