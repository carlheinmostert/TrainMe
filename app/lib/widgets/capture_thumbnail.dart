import 'dart:io';
import 'package:flutter/material.dart';
import '../models/exercise_capture.dart';
import '../models/treatment.dart';
import '../theme.dart';

/// Grayscale color matrix — zeroes the saturation while preserving
/// luminance. Matches the web player's `filter: grayscale(1)
/// contrast(1.05)` as closely as Flutter's `ColorFilter.matrix` allows.
const ColorFilter _kGrayscaleFilter = ColorFilter.matrix(<double>[
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0, 0, 0, 1, 0, //
]);

/// Reusable thumbnail widget for a captured exercise.
///
/// Displays the image (raw if still converting, converted if done)
/// with overlays indicating conversion status and media type.
/// Used in both the session strip (capture screen) and the plan editor.
///
/// Wave 40.6 — treatment-aware thumbnails. When [treatment] is non-null,
/// the thumbnail reflects the practitioner's preferred treatment:
///   - `Treatment.line`      → converted (line-drawing) file (existing)
///   - `Treatment.grayscale` → raw file with a grayscale color filter
///   - `Treatment.original`  → raw file with no filter
/// When [treatment] is null, behaviour matches legacy: converted if done,
/// raw otherwise (i.e. the existing B&W-thumbnail path).
class CaptureThumbnail extends StatelessWidget {
  final ExerciseCapture exercise;
  final double size;

  /// When false, the conversion status overlay (spinner / checkmark /
  /// warning) is suppressed. Used in the capture-mode peek box — Carl
  /// found the perpetual spinner anxiety-inducing mid-session, so there
  /// the thumbnail swaps silently from raw → converted instead.
  final bool showConversionOverlay;

  /// When false, the chrome that's only useful in the small list cell
  /// (the centred play-circle glyph on video thumbnails + the
  /// bottom-left media-type badge) is suppressed. Used by the
  /// long-press peek preview at 240×240 — that surface sits behind a
  /// live `VideoPlayer` once the controller initialises, so the
  /// chrome would briefly flash through the menu open transition and
  /// then vanish ("something popping in background", Wave 19.4 item
  /// 24). Defaults to true so list cells keep their full glyphery.
  final bool showChrome;

  /// Wave 40.6 — when non-null, the thumbnail switches to the
  /// treatment-appropriate source file + color filter. When null,
  /// legacy behaviour applies (converted → raw fallback).
  final Treatment? treatment;

  const CaptureThumbnail({
    super.key,
    required this.exercise,
    this.size = 64,
    this.showConversionOverlay = true,
    this.showChrome = true,
    this.treatment,
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
            if (showChrome) _buildMediaTypeBadge(),
          ],
        ),
      ),
    );
  }

  /// Resolves the file path and optional color filter for the active
  /// treatment. Returns `(File, ColorFilter?)`.
  (File, ColorFilter?) _resolveSource() {
    final effectiveTreatment = treatment ?? Treatment.line;

    // Rest periods: no treatment logic.
    if (exercise.isRest) {
      return (File(exercise.displayFilePath), null);
    }

    switch (effectiveTreatment) {
      case Treatment.line:
        // Line drawing: use the converted file (existing behaviour).
        return (File(exercise.displayFilePath), null);

      case Treatment.grayscale:
        // B&W: use the raw file with a grayscale filter.
        // For videos, prefer the thumbnail of the raw file (there's no
        // separate raw thumbnail — use the archive or raw path).
        final rawPath = exercise.absoluteRawFilePath;
        return (File(rawPath), _kGrayscaleFilter);

      case Treatment.original:
        // Original: use the raw file with no filter.
        final rawPath = exercise.absoluteRawFilePath;
        return (File(rawPath), null);
    }
  }

  /// The thumbnail image. Treatment-aware per Wave 40.6.
  Widget _buildImage(int cacheWidth) {
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

    final (sourceFile, colorFilter) = _resolveSource();

    // For videos, show the extracted thumbnail if available,
    // otherwise fall back to a dark placeholder with a play icon.
    if (exercise.mediaType == MediaType.video) {
      // For non-line treatments, show the raw file directly (it's a
      // video so we can't show a frame — use the thumbnail path but
      // with the treatment filter applied). The thumbnail is always
      // from the converted pipeline, so for B&W/Original we ideally
      // want a raw thumbnail. Since a separate raw thumbnail doesn't
      // exist, we show the existing thumbnail with the appropriate
      // filter: line thumbnail with grayscale filter approximates B&W,
      // and for Original we show the existing thumbnail unfiltered
      // (close enough — the line-drawing thumbnail is the fallback
      // when no raw thumbnail exists).
      if (exercise.absoluteThumbnailPath != null) {
        // Pick the treatment-specific thumbnail for videos.
        // Variants generated at conversion time (Wave 40.6):
        //   line:      {id}_thumb_line.jpg  (frame from converted video)
        //   grayscale: {id}_thumb.jpg       (existing B&W from raw)
        //   original:  {id}_thumb_color.jpg (color frame from raw)
        // Falls back to the existing B&W thumbnail if variants don't exist.
        final basePath = exercise.absoluteThumbnailPath!;
        final effectiveTreatment = treatment ?? Treatment.line;
        String thumbPath;
        switch (effectiveTreatment) {
          case Treatment.line:
            thumbPath = basePath.replaceFirst('_thumb.jpg', '_thumb_line.jpg');
          case Treatment.grayscale:
            thumbPath = basePath; // the default thumbnail IS B&W
          case Treatment.original:
            thumbPath = basePath.replaceFirst('_thumb.jpg', '_thumb_color.jpg');
        }
        // Fall back to the existing thumbnail if the variant doesn't exist.
        final thumbFile = File(thumbPath);
        final fallbackFile = File(basePath);
        final useFile = thumbFile.existsSync() ? thumbFile : fallbackFile;
        Widget thumb = Image.file(
          useFile,
          fit: BoxFit.cover,
          cacheWidth: cacheWidth,
          errorBuilder: (context, error, stackTrace) => Container(
            color: AppColors.surfaceRaised,
            child: const Center(
              child: Icon(Icons.play_circle_outline,
                  color: Colors.white54, size: 28),
            ),
          ),
        );
        return Stack(
          fit: StackFit.expand,
          children: [
            thumb,
            if (showChrome)
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

    // Photo exercises. For B&W/Original, use the raw file; for Line,
    // use the converted (line-drawing) file.
    Widget image = Image.file(
      sourceFile,
      fit: BoxFit.cover,
      cacheWidth: cacheWidth,
      errorBuilder: (context, error, stackTrace) => Container(
        color: AppColors.surfaceRaised,
        child: const Center(
          child: Icon(Icons.broken_image_outlined, color: AppColors.grey500, size: 24),
        ),
      ),
    );
    if (colorFilter != null) {
      image = ColorFiltered(colorFilter: colorFilter, child: image);
    }
    return image;
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
