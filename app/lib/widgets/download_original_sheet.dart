import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/exercise_capture.dart';
import '../services/original_video_service.dart';
import '../theme.dart';

/// The choice a practitioner made from the bottom sheet. Exposed so
/// unit tests / callers can observe dismiss vs. commit. [cancelled] is
/// the implicit value when the sheet is dismissed without a tap — the
/// caller can treat null from [showDownloadOriginalSheet] the same way.
enum DownloadOriginalChoice { saveToCameraRoll, share, cancelled }

/// Bottom action sheet anchored to the Studio exercise card's long-press
/// "Download original" option. Three rows:
///
///   1. **Save to Camera Roll** — grants Photos.addOnly permission first
///      time, writes the raw mp4 to PHPhotoLibrary.
///   2. **Share** — native iOS share sheet with the mp4 as an XFile.
///   3. **Cancel** — dismiss.
///
/// Source resolution + download + save / share are orchestrated by
/// [OriginalVideoService]; this widget stays presentational.
///
/// R-01 applies — no "Are you sure?" confirmation. Save fires
/// immediately; removing the video from Photos is a one-tap user
/// action anyway.
class DownloadOriginalSheet extends StatelessWidget {
  final ExerciseCapture exercise;
  final String? practiceId;
  final String? planId;

  const DownloadOriginalSheet({
    super.key,
    required this.exercise,
    required this.practiceId,
    required this.planId,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.surfaceBase,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          border: Border(
            top: BorderSide(color: AppColors.surfaceBorder),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(0, 12, 0, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Grabber.
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: AppColors.surfaceBorder,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Text(
                'Original video',
                style: TextStyle(
                  fontFamily: 'Montserrat',
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                  color: AppColors.textOnDark,
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 14),
              child: Text(
                'The colour capture, straight from the camera.',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 13,
                  color: AppColors.textSecondaryOnDark,
                ),
              ),
            ),
            _SheetRow(
              icon: Icons.file_download_outlined,
              label: 'Save to Camera Roll',
              onTap: () {
                HapticFeedback.selectionClick();
                Navigator.of(context).pop(
                  DownloadOriginalChoice.saveToCameraRoll,
                );
              },
            ),
            const _RowDivider(),
            _SheetRow(
              icon: Icons.ios_share_rounded,
              label: 'Share',
              onTap: () {
                HapticFeedback.selectionClick();
                Navigator.of(context).pop(DownloadOriginalChoice.share);
              },
            ),
            const _RowDivider(),
            _SheetRow(
              icon: Icons.close_rounded,
              label: 'Cancel',
              muted: true,
              onTap: () {
                Navigator.of(context).pop(DownloadOriginalChoice.cancelled);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _SheetRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool muted;

  const _SheetRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.muted = false,
  });

  @override
  Widget build(BuildContext context) {
    final textColor = muted
        ? AppColors.textSecondaryOnDark
        : AppColors.textOnDark;
    final iconColor = muted ? AppColors.textSecondaryOnDark : AppColors.primary;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 22, color: iconColor),
            const SizedBox(width: 14),
            Text(
              label,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: textColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RowDivider extends StatelessWidget {
  const _RowDivider();

  @override
  Widget build(BuildContext context) {
    return const Divider(
      height: 1,
      thickness: 1,
      color: AppColors.surfaceBorder,
      indent: 20,
      endIndent: 20,
    );
  }
}

/// Convenience launcher: show the download-original sheet, execute the
/// practitioner's choice via [OriginalVideoService], and surface a
/// SnackBar on the caller's [ScaffoldMessenger]. Returns once the
/// whole flow has settled so callers can await.
///
/// Uses the caller-provided [sharePositionOrigin] for the iPad-popover
/// CGRect on share (simulator + iPad both crash without it). Callers
/// typically pass the bounding rect of the triggering widget.
///
/// Swallows internal errors and turns them into specific SnackBars —
/// this function NEVER throws, so the long-press card code doesn't
/// have to wrap in try/catch.
Future<void> showDownloadOriginalSheet(
  BuildContext context, {
  required ExerciseCapture exercise,
  required String? practiceId,
  required String? planId,
  Rect? sharePositionOrigin,
}) async {
  // Only meaningful for video captures.
  if (exercise.mediaType != MediaType.video) return;

  final choice = await showModalBottomSheet<DownloadOriginalChoice>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => DownloadOriginalSheet(
      exercise: exercise,
      practiceId: practiceId,
      planId: planId,
    ),
  );

  if (!context.mounted) return;
  if (choice == null || choice == DownloadOriginalChoice.cancelled) return;

  final messenger = ScaffoldMessenger.of(context);

  // Resolve source ONCE — both Save and Share share the same resolver
  // to keep behavior predictable and avoid a double signing hop.
  final svc = OriginalVideoService.instance;
  final source = await svc.resolveSource(
    exercise: exercise,
    practiceId: practiceId,
    planId: planId,
  );

  if (source.isEmpty) {
    _showSnack(
      messenger,
      'Original video no longer available — recapture to re-archive.',
    );
    return;
  }

  // Materialise to a concrete File — download the signed URL if we
  // only have a remote source. Any download error bubbles up here and
  // we show a generic failure snack.
  File file;
  try {
    if (source.localFile != null) {
      file = source.localFile!;
    } else {
      file = await svc.downloadToTemp(
        url: source.remoteUrl!,
        exerciseId: exercise.id,
      );
    }
  } catch (e) {
    _showSnack(
      messenger,
      "Couldn't fetch the original video. Check your signal and try again.",
    );
    return;
  }

  switch (choice) {
    case DownloadOriginalChoice.saveToCameraRoll:
      final result = await svc.saveToPhotos(file);
      switch (result) {
        case SaveToPhotosResult.saved:
          _showSnack(messenger, 'Saved to Camera Roll');
          break;
        case SaveToPhotosResult.permissionDenied:
          _showSnack(
            messenger,
            "Photos access was declined. Enable it in Settings → homefit.studio to save videos.",
          );
          break;
        case SaveToPhotosResult.sourceMissing:
          _showSnack(
            messenger,
            'Original video no longer available — recapture to re-archive.',
          );
          break;
        case SaveToPhotosResult.failed:
          _showSnack(
            messenger,
            "Couldn't save to Camera Roll. Try again.",
          );
          break;
      }
      break;
    case DownloadOriginalChoice.share:
      try {
        await svc.share(file: file, sharePositionOrigin: sharePositionOrigin);
      } catch (_) {
        _showSnack(messenger, "Couldn't open the share sheet. Try again.");
      }
      break;
    case DownloadOriginalChoice.cancelled:
      break;
  }
}

void _showSnack(ScaffoldMessengerState messenger, String text) {
  messenger.clearSnackBars();
  messenger.showSnackBar(
    SnackBar(
      content: Text(
        text,
        style: const TextStyle(
          fontFamily: 'Inter',
          fontSize: 14,
          color: AppColors.textOnDark,
        ),
      ),
      backgroundColor: AppColors.surfaceRaised,
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.surfaceBorder),
      ),
    ),
  );
}
