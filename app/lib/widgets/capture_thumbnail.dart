import 'dart:io';
import 'package:flutter/material.dart';
import '../models/exercise_capture.dart';
import '../theme.dart';

/// Reusable thumbnail widget for a captured exercise.
///
/// Displays the image (raw if still converting, converted if done)
/// with overlays indicating conversion status and media type.
/// Used in both the session strip (capture screen) and the plan editor.
class CaptureThumbnail extends StatelessWidget {
  final ExerciseCapture exercise;
  final double size;

  /// When false, the conversion status overlay (spinner / checkmark /
  /// warning) is suppressed. Used in the capture-mode peek box — Carl
  /// found the perpetual spinner anxiety-inducing mid-session, so there
  /// the thumbnail swaps silently from raw → converted instead.
  final bool showConversionOverlay;

  const CaptureThumbnail({
    super.key,
    required this.exercise,
    this.size = 64,
    this.showConversionOverlay = true,
  });

  @override
  Widget build(BuildContext context) {
    // Decode images at the pixel size of the thumbnail so we don't burn
    // memory decoding full-res 12MP images into tiny 64px list cells.
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final cacheWidth = (size * dpr).round().clamp(1, 4096);

    return SizedBox(
      width: size,
      height: size,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          fit: StackFit.expand,
          children: [
            _buildImage(cacheWidth),
            if (showConversionOverlay) _buildConversionOverlay(),
            _buildMediaTypeBadge(),
          ],
        ),
      ),
    );
  }

  /// The thumbnail image. Shows converted version if available, raw otherwise.
  Widget _buildImage(int cacheWidth) {
    final path = exercise.displayFilePath;
    final file = File(path);

    // Rest periods: show a calming icon in a dark surface.
    if (exercise.isRest) {
      return Container(
        color: AppColors.surfaceRaised,
        child: Center(
          child: Icon(
            Icons.self_improvement,
            size: size * 0.5,
            color: AppColors.rest,
          ),
        ),
      );
    }

    // For videos, show the extracted thumbnail if available,
    // otherwise fall back to a dark placeholder with a play icon.
    if (exercise.mediaType == MediaType.video) {
      if (exercise.absoluteThumbnailPath != null) {
        final thumbFile = File(exercise.absoluteThumbnailPath!);
        return Stack(
          fit: StackFit.expand,
          children: [
            Image.file(
              thumbFile,
              fit: BoxFit.cover,
              cacheWidth: cacheWidth,
              errorBuilder: (_, _, _) => Container(
                color: AppColors.surfaceRaised,
                child: const Center(
                  child: Icon(Icons.play_circle_outline,
                      color: Colors.white54, size: 28),
                ),
              ),
            ),
            Center(
              child: Icon(Icons.play_circle_outline,
                  color: Colors.white70, size: size * 0.4),
            ),
          ],
        );
      }
      return Container(
        color: AppColors.surfaceRaised,
        child: const Center(
          child: Icon(Icons.play_circle_outline, color: Colors.white54, size: 28),
        ),
      );
    }

    return Image.file(
      file,
      fit: BoxFit.cover,
      cacheWidth: cacheWidth,
      errorBuilder: (_, _, _) => Container(
        color: AppColors.surfaceRaised,
        child: const Center(
          child: Icon(Icons.broken_image_outlined, color: AppColors.grey500, size: 24),
        ),
      ),
    );
  }

  /// Conversion status overlay:
  /// - Pending/converting: subtle circular progress indicator
  /// - Done: small checkmark badge
  /// - Failed: warning icon
  Widget _buildConversionOverlay() {
    switch (exercise.conversionStatus) {
      case ConversionStatus.pending:
      case ConversionStatus.converting:
        return Container(
          color: Colors.black26,
          child: Center(
            child: SizedBox(
              width: size * 0.35,
              height: size * 0.35,
              child: const CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white70,
              ),
            ),
          ),
        );

      case ConversionStatus.done:
        return Positioned(
          top: 2,
          right: 2,
          child: Container(
            padding: const EdgeInsets.all(2),
            decoration: const BoxDecoration(
              color: Colors.green,
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.check, size: size * 0.18, color: Colors.white),
          ),
        );

      case ConversionStatus.failed:
        return Positioned(
          top: 2,
          right: 2,
          child: Container(
            padding: const EdgeInsets.all(2),
            decoration: const BoxDecoration(
              color: Colors.red,
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.warning_amber, size: size * 0.18, color: Colors.white),
          ),
        );
    }
  }

  /// Small media type badge in the bottom-left corner.
  /// Camera icon for photo, video icon for video, pause for rest.
  Widget _buildMediaTypeBadge() {
    // Rest periods don't need a media type badge.
    if (exercise.isRest) return const SizedBox.shrink();

    return Positioned(
      bottom: 2,
      left: 2,
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Icon(
          exercise.mediaType == MediaType.photo
              ? Icons.photo_camera
              : Icons.videocam,
          size: size * 0.18,
          color: Colors.white,
        ),
      ),
    );
  }
}
