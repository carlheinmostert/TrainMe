import 'dart:io';
import 'package:flutter/material.dart';
import '../models/exercise_capture.dart';

/// Reusable thumbnail widget for a captured exercise.
///
/// Displays the image (raw if still converting, converted if done)
/// with overlays indicating conversion status and media type.
/// Used in both the session strip (capture screen) and the plan editor.
class CaptureThumbnail extends StatelessWidget {
  final ExerciseCapture exercise;
  final double size;

  const CaptureThumbnail({
    super.key,
    required this.exercise,
    this.size = 64,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          fit: StackFit.expand,
          children: [
            _buildImage(),
            _buildConversionOverlay(),
            _buildMediaTypeBadge(),
          ],
        ),
      ),
    );
  }

  /// The thumbnail image. Shows converted version if available, raw otherwise.
  Widget _buildImage() {
    final path = exercise.displayFilePath;
    final file = File(path);

    // For videos, show the extracted thumbnail if available,
    // otherwise fall back to a dark placeholder with a play icon.
    if (exercise.mediaType == MediaType.video) {
      if (exercise.thumbnailPath != null) {
        final thumbFile = File(exercise.thumbnailPath!);
        return Stack(
          fit: StackFit.expand,
          children: [
            Image.file(
              thumbFile,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Container(
                color: Colors.grey.shade800,
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
        color: Colors.grey.shade800,
        child: const Center(
          child: Icon(Icons.play_circle_outline, color: Colors.white54, size: 28),
        ),
      );
    }

    return Image.file(
      file,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => Container(
        color: Colors.grey.shade300,
        child: const Center(
          child: Icon(Icons.broken_image_outlined, color: Colors.grey, size: 24),
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
  /// Camera icon for photo, video icon for video.
  Widget _buildMediaTypeBadge() {
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
