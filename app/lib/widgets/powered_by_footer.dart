import 'package:flutter/material.dart';
import '../config.dart';
import '../theme.dart';

/// "powered by homefit.studio" footer with Pulse Mark logo.
/// Shown at the bottom of primary screens.
///
/// Includes a tiny build-SHA marker in the bottom-right so we can
/// confirm at a glance which commit is running on device. See
/// [AppConfig.buildSha].
class PoweredByFooter extends StatelessWidget {
  const PoweredByFooter({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'powered by',
                style: TextStyle(
                  fontSize: 11,
                  color: AppColors.textSecondaryOnDark,
                  letterSpacing: 0.3,
                ),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 26,
                    height: 18,
                    child: CustomPaint(
                      painter:
                          _PulseMarkPainter(color: AppColors.primary),
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Text(
                    'homefit.studio',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textOnDark,
                      letterSpacing: -0.2,
                    ),
                  ),
                ],
              ),
            ],
          ),
          // Build-SHA marker — subtle, bottom-right. Confirms at a glance
          // which commit is on the device after a rebuild.
          Positioned(
            right: 0,
            bottom: 0,
            child: Opacity(
              opacity: 0.35,
              child: Text(
                AppConfig.buildSha,
                style: const TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontFamilyFallback: ['Menlo', 'Courier'],
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textSecondaryOnDark,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Pulse Mark — heartbeat line tracing a house roof silhouette.
class _PulseMarkPainter extends CustomPainter {
  final Color color;
  _PulseMarkPainter({this.color = AppColors.primary});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final path = Path();
    final w = size.width;
    final h = size.height;
    path.moveTo(w * 0.05, h * 0.7);
    path.lineTo(w * 0.25, h * 0.7);
    path.lineTo(w * 0.35, h * 0.2);
    path.lineTo(w * 0.5, h * 0.8);
    path.lineTo(w * 0.65, h * 0.2);
    path.lineTo(w * 0.75, h * 0.7);
    path.lineTo(w * 0.95, h * 0.7);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
