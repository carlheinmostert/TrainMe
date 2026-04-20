import 'package:flutter/material.dart';

import '../services/sync_service.dart';
import '../theme.dart';

/// Subtle status chip(s) that render near the practice chip on Home.
///
/// States:
///   - Hidden when online AND no pending ops.
///   - "Offline" chip when connectivity_plus reports no network.
///   - "{N} pending" chip when the queue has ops awaiting sync — shown
///     at ALL times, online OR offline, so the practitioner has
///     visibility into queued ops even without connectivity.
///   - Offline + N pending → BOTH chips render side-by-side. The
///     "Offline" banner no longer hides the pending count; pending ops
///     are a cached-queue concept and shouldn't be gated by live
///     connectivity.
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
            final pendingLabel =
                pending == 1 ? '1 pending' : '$pending pending';
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (offline)
                  _StatusChip(
                    icon: Icons.cloud_off_outlined,
                    label: 'Offline',
                  ),
                if (offline && pending > 0) const SizedBox(width: 6),
                if (pending > 0)
                  _StatusChip(
                    icon: Icons.sync_rounded,
                    label: pendingLabel,
                  ),
              ],
            );
          },
        );
      },
    );
  }
}

/// Single muted pill — shared shell for the Offline + Pending chips so
/// they stay visually identical when they sit side-by-side.
class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
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
  }
}
