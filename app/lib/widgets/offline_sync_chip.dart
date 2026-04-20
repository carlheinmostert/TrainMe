import 'package:flutter/material.dart';

import '../services/sync_service.dart';
import '../theme.dart';

/// Subtle status chip that renders near the practice chip on Home.
///
/// States:
///   - Hidden when online AND no pending ops.
///   - "Offline" (muted icon + label) when connectivity_plus reports
///     no network. Takes precedence over the pending-ops count.
///   - "{N} pending" when the queue has ops awaiting sync.
///
/// Deliberately quiet: ink-muted palette, no red or alarmist colours.
/// The practitioner shouldn't feel "something is broken" — we're just
/// telling them we'll catch up once they reconnect.
class OfflineSyncChip extends StatelessWidget {
  const OfflineSyncChip({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: SyncService.instance.offline,
      builder: (context, offline, _) {
        return ValueListenableBuilder<int>(
          valueListenable: SyncService.instance.pendingOpCount,
          builder: (context, pending, _) {
            if (!offline && pending == 0) {
              return const SizedBox.shrink();
            }
            final label = offline
                ? 'Offline'
                : (pending == 1 ? '1 pending' : '$pending pending');
            final icon = offline ? Icons.cloud_off_outlined : Icons.sync_rounded;
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.surfaceRaised,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: AppColors.surfaceBorder,
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 12, color: AppColors.textSecondaryOnDark),
                  const SizedBox(width: 5),
                  Text(
                    label,
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textSecondaryOnDark,
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
