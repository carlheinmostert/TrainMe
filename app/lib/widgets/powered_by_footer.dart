import 'package:flutter/material.dart';
import '../config.dart';
import '../theme.dart';
import 'homefit_logo.dart';

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
                  const HomefitLogo(size: 28),
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

