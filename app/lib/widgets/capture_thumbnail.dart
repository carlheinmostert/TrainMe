import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import '../models/exercise_capture.dart';
import '../models/treatment.dart';
import '../services/conversion_service.dart';
import '../services/exercise_hero_resolver.dart';
import '../theme.dart';
import '../utils/hero_crop_alignment.dart';
import 'hero_star_badge.dart';

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

    // Hero-frame indicator: coral star top-left for video exercises only.
    // Tracks [showChrome] so the long-press 240px peek (which strips
    // chrome to avoid mid-animation "popping") also drops the badge.
    final showHeroBadge =
        showChrome && !exercise.isRest && exercise.mediaType == MediaType.video;
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
            if (showHeroBadge) const HeroStarBadge(),
          ],
        ),
      ),
    );
  }

  /// Resolves the file path and optional color filter for the active
  /// treatment via [resolveExerciseHero]. Returns `(File, ColorFilter?)`.
  ///
  /// Photo paths converge with [_PhotoFrame] in mini_preview.dart;
  /// video paths use the resolver's per-treatment thumbnail variant
  /// selection. Rest periods bypass treatment logic entirely.
  (File, ColorFilter?) _resolveSource() {
    // Rest periods: no treatment logic.
    if (exercise.isRest) {
      return (File(exercise.displayFilePath), null);
    }

    final hero = resolveExerciseHero(
      exercise: exercise,
      surface: HeroSurface.peek,
    );
    final file = hero.posterFile ?? File(exercise.displayFilePath);
    return (file, hero.filter);
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

    // For videos, show the extracted thumbnail variant if available,
    // otherwise fall back to a dark placeholder with a play icon. The
    // per-treatment variant selection ({id}_thumb_line.jpg /
    // {id}_thumb_color.jpg / {id}_thumb.jpg) is centralised in the
    // resolver — see _pickVideoPosterFile.
    if (exercise.mediaType == MediaType.video) {
      if (exercise.absoluteThumbnailPath != null && sourceFile.existsSync()) {
        // Wave Lobby — practitioner-authored 1:1 crop window.
        // Defaults to centred (Alignment.center) for legacy /
        // un-authored exercises; otherwise slides along the source's
        // free axis per orientation.
        final align = heroCropAlignment(exercise);
        Widget thumb = Image.file(
          sourceFile,
          fit: BoxFit.cover,
          alignment: align,
          cacheWidth: cacheWidth,
          errorBuilder: (context, error, stackTrace) => Container(
            color: AppColors.surfaceRaised,
            child: const Center(
              child: Icon(
                Icons.play_circle_outline,
                color: Colors.white54,
                size: 28,
              ),
            ),
          ),
        );
        if (colorFilter != null) {
          thumb = ColorFiltered(colorFilter: colorFilter, child: thumb);
        }
        return Stack(
          fit: StackFit.expand,
          children: [
            thumb,
            if (showChrome)
              Center(
                child: Icon(
                  Icons.play_circle_outline,
                  color: Colors.white70,
                  size: size * 0.4,
                ),
              ),
          ],
        );
      }
      return Container(
        color: AppColors.surfaceRaised,
        child: const Center(
          child: Icon(
            Icons.play_circle_outline,
            color: Colors.white54,
            size: 28,
          ),
        ),
      );
    }

    // Photo exercises. The resolver gives us the right file + filter.
    // Wave Lobby — apply the practitioner-authored 1:1 crop window.
    final align = heroCropAlignment(exercise);
    Widget image = Image.file(
      sourceFile,
      fit: BoxFit.cover,
      alignment: align,
      cacheWidth: cacheWidth,
      errorBuilder: (context, error, stackTrace) => Container(
        color: AppColors.surfaceRaised,
        child: const Center(
          child: Icon(
            Icons.broken_image_outlined,
            color: AppColors.grey500,
            size: 24,
          ),
        ),
      ),
    );
    if (colorFilter != null) {
      image = ColorFiltered(colorFilter: colorFilter, child: image);
    }
    return image;
  }

  /// Conversion status overlay:
  /// - Pending/converting (Safe Mode v2 video): determinate coral
  ///   progress bar at the bottom edge of the thumbnail, driven by
  ///   [ConversionService.onSafeModeV2VideoProgress] for the
  ///   matching exercise id. Per the Safe Mode v2 video spec
  ///   (`docs/specs/2026-05-25-safe-mode-v2-video.md` section 6f),
  ///   the worst-case wait under the 2x real-time ceiling is ~60s
  ///   for a 30s capture — long enough that an indeterminate
  ///   spinner would feel broken. Coral matches the brand accent
  ///   (`AppColors.primary` / `#FF6B35`).
  /// - Pending/converting (everything else): legacy translucent
  ///   indeterminate spinner.
  /// - Done: small checkmark badge.
  /// - Failed: warning icon.
  Widget _buildConversionOverlay() {
    switch (exercise.conversionStatus) {
      case ConversionStatus.pending:
      case ConversionStatus.converting:
        // Safe Mode v2 video conversion: render a determinate coral
        // progress bar bound to the per-exercise stream. Everything
        // else keeps the legacy indeterminate spinner.
        final isSafeVideo =
            exercise.mediaType == MediaType.video && exercise.safeModeActive;
        if (isSafeVideo) {
          return _SafeModeV2VideoProgressOverlay(
            exerciseId: exercise.id,
            barHeight: (size * 0.06).clamp(3.0, 6.0),
          );
        }
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
            child: Icon(
              Icons.warning_amber,
              size: size * 0.18,
              color: Colors.white,
            ),
          ),
        );
    }
  }

  // Note: the Hero-frame star badge is rendered as a separate
  // [HeroStarBadge] widget (see hero_star_badge.dart); it's a sibling
  // Positioned in the Stack (not built here) so it can be conditionally
  // added/skipped at the build-tree level.

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

/// Determinate coral progress bar for an in-flight Safe Mode v2
/// video conversion (2026-05-25).
///
/// Subscribes to [ConversionService.onSafeModeV2VideoProgress] and
/// filters for the matching [exerciseId]. The bar sits at the bottom
/// edge of the thumbnail under a dim translucent veil so the heroframe
/// underneath stays legible while the safe variant is being composited.
///
/// Coral matches the brand accent
/// (`AppColors.primary` / `#FF6B35`) per the spec's section 6f
/// styling guidance.
///
/// Falls back to a 0% bar before the first progress event arrives so
/// the surface never goes blank for the brief window between the
/// `converting` status flip and the first frame composited.
class _SafeModeV2VideoProgressOverlay extends StatefulWidget {
  /// Id of the exercise whose Safe Mode v2 video pass is in flight.
  /// Used to filter events on
  /// [ConversionService.onSafeModeV2VideoProgress] so a parallel
  /// capture's progress doesn't bleed into this card.
  final String exerciseId;

  /// Pixel height of the coral progress bar at the bottom of the
  /// thumbnail. Sized as a fraction of the overall thumbnail size by
  /// the parent, then clamped to a sensible 3–6 px range so it stays
  /// visible at the smallest peek size and doesn't dominate the
  /// larger Studio card.
  final double barHeight;

  const _SafeModeV2VideoProgressOverlay({
    required this.exerciseId,
    required this.barHeight,
  });

  @override
  State<_SafeModeV2VideoProgressOverlay> createState() =>
      _SafeModeV2VideoProgressOverlayState();
}

class _SafeModeV2VideoProgressOverlayState
    extends State<_SafeModeV2VideoProgressOverlay> {
  StreamSubscription<SafeModeV2VideoProgress>? _sub;
  double _fraction = 0.0;

  @override
  void initState() {
    super.initState();
    _sub = ConversionService.instance.onSafeModeV2VideoProgress.listen((event) {
      if (!mounted) return;
      if (event.exerciseId != widget.exerciseId) return;
      setState(() => _fraction = event.fraction);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Dim veil sits over the thumbnail so the bar reads cleanly
        // against any background. Matches the spinner's translucency
        // so the visual weight of "converting" is unchanged.
        Container(color: Colors.black26),
        Align(
          alignment: Alignment.bottomCenter,
          child: SizedBox(
            height: widget.barHeight,
            child: ClipRRect(
              borderRadius: const BorderRadius.only(
                bottomLeft: Radius.circular(8),
                bottomRight: Radius.circular(8),
              ),
              child: LinearProgressIndicator(
                value: _fraction.clamp(0.0, 1.0),
                backgroundColor: Colors.white24,
                valueColor: const AlwaysStoppedAnimation<Color>(
                  AppColors.primary,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
