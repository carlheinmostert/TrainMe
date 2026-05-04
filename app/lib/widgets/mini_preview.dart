import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../models/exercise_capture.dart';
import '../models/treatment.dart';
import '../theme.dart';
import 'hero_star_badge.dart';

/// Greyscale matrix used by [ColorFiltered] for the B&W treatment.
/// Mirrors the web player's `filter: grayscale(1)` look.
const ColorFilter _kGrayscaleFilter = ColorFilter.matrix(<double>[
  0.299, 0.587, 0.114, 0, 0,
  0.299, 0.587, 0.114, 0, 0,
  0.299, 0.587, 0.114, 0, 0,
  0,     0,     0,     1, 0,
]);

/// Live mini preview for an [ExerciseCapture].
///
/// Three branches:
///   * **Rest** (`exercise.isRest`) — sage gradient + bedtime glyph. Inert.
///   * **Photo** (`mediaType == photo`) — `Image.file` on the existing
///     thumbnail/raw/converted fallback chain, no animation.
///   * **Video** — `VideoPlayerController.file` against
///     [ExerciseCapture.absoluteConvertedFilePath] (the line-drawing
///     treatment, ALWAYS — regardless of consent or treatment switch).
///     Muted, autoplay, loops inside the trim window
///     (`startOffsetMs..endOffsetMs`).
///
/// Reactive contract:
///   * Parent rebuild with a NEW `convertedFilePath` → dispose old
///     controller, instantiate new.
///   * Parent rebuild with the SAME `convertedFilePath` but new trim
///     offsets → just update bounds and seek to `start` if outside.
///   * Switching exercise type (e.g. video → photo) → tear down + rebuild
///     branch on the next [didUpdateWidget].
///
/// The MEDIA itself is not a hit target — wrapped in [IgnorePointer] so
/// taps fall through to the host (e.g. the Studio card's outer InkWell or
/// the editor sheet's chevron overlay). The optional [overlay] widget is
/// painted ABOVE the media in a [Stack]; the caller manages its hit
/// behaviour.
class MiniPreview extends StatefulWidget {
  final ExerciseCapture exercise;
  final double width;

  /// Fixed height in logical pixels. When null, the preview takes the
  /// height dictated by its parent (e.g. via `IntrinsicHeight + Row(
  /// crossAxisAlignment: stretch)` so it lines up with a sibling
  /// column's natural content height).
  final double? height;
  final BorderRadius? borderRadius;

  /// Optional positioned overlay (e.g. chevron pair) painted above the
  /// media. Manages its own hit-testing; the underlying media never
  /// captures pointer events.
  final Widget? overlay;

  /// When true, the controller pauses/plays in lockstep with
  /// [studioPauseAll]. Studio list cards opt in so all background
  /// videos halt while the editor sheet is open (less distraction
  /// while editing); the editor sheet's own chrome MiniPreview
  /// leaves this false so it keeps playing in focus.
  final bool respectGlobalPause;

  /// Global pause flag for Studio-list MiniPreviews. Flipped to true
  /// inside [showExerciseEditorSheet] for the duration of the sheet.
  /// MiniPreview instances with [respectGlobalPause] true subscribe
  /// and pause / resume their controller accordingly.
  static final ValueNotifier<bool> studioPauseAll =
      ValueNotifier<bool>(false);

  /// Wave Hero — when true, the mini renders the static Hero-frame JPG
  /// (auto-picked motion-peak by default, or the practitioner's pick
  /// from the trim panel) instead of spinning up a video controller.
  /// Used by Studio exercise cards + the editor sheet's header
  /// thumbnail — surfaces where the Hero shot is the source of truth.
  /// The Preview tab inside the editor sheet uses [MediaViewerBody]
  /// (not this widget), so motion still shows where it should.
  ///
  /// No-op for photos and rest periods — those branches already render
  /// static content.
  final bool staticHero;

  /// Wave Lobby PR 2 — when set, the static-Hero branch maps this
  /// normalised offset (`[0.0, 1.0]` along the source's free axis) onto
  /// an [Alignment] so the editor sheet's header thumbnail re-renders
  /// in lock-step with the practitioner's drag on [HeroCropViewport].
  ///
  /// Other consumer surfaces (Studio cards, ClientSessions cards, etc.)
  /// pass null — those land in PR 3 and at that point will read the
  /// offset off the exercise model directly. Default null preserves
  /// today's `BoxFit.cover` centred render exactly.
  final double? cropOffset;

  const MiniPreview({
    super.key,
    required this.exercise,
    required this.width,
    this.height,
    this.borderRadius,
    this.overlay,
    this.respectGlobalPause = false,
    this.staticHero = false,
    this.cropOffset,
  });

  @override
  State<MiniPreview> createState() => _MiniPreviewState();
}

class _MiniPreviewState extends State<MiniPreview> {
  VideoPlayerController? _controller;
  VoidCallback? _listener;
  bool _initialized = false;
  int _startMs = 0;
  int _endMs = 0;

  @override
  void initState() {
    super.initState();
    if (widget.respectGlobalPause) {
      MiniPreview.studioPauseAll.addListener(_onGlobalPauseChanged);
    }
    // Static-Hero surfaces never instantiate a VideoPlayerController —
    // they render the {id}_thumb*.jpg straight via Image.file.
    if (!widget.staticHero) {
      _initForExercise(widget.exercise);
    }
  }

  void _onGlobalPauseChanged() {
    final controller = _controller;
    if (controller == null || !_initialized) return;
    if (MiniPreview.studioPauseAll.value) {
      controller.pause();
    } else {
      controller.play();
    }
  }

  @override
  void didUpdateWidget(covariant MiniPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldEx = oldWidget.exercise;
    final newEx = widget.exercise;

    // staticHero toggle — drop any controller we hold and short-circuit.
    // The Image.file path doesn't need lifecycle management. Re-engage
    // the controller path if the flag flips back to false.
    if (oldWidget.staticHero != widget.staticHero) {
      _disposeController();
      if (!widget.staticHero) {
        _initForExercise(newEx);
      }
      return;
    }

    if (widget.staticHero) {
      // Pure Image.file render — no controller to maintain. Flutter's
      // image cache keys on the path; bumping focus_frame_offset_ms
      // overwrites the JPG in place, so the next paint after
      // regenerateHeroThumbnails picks up the new bytes via
      // [_HeroFrameImage]'s ValueKey.
      return;
    }

    final oldPath = _videoPathFor(oldEx);
    final newPath = _videoPathFor(newEx);
    final typeChanged = oldEx.mediaType != newEx.mediaType ||
        oldEx.isRest != newEx.isRest;

    if (typeChanged || oldPath != newPath) {
      // Tear down the existing controller (if any) and rebuild the
      // appropriate branch. Covers video→photo, video→rest, and
      // converted-path swaps after a re-conversion.
      _disposeController();
      _initForExercise(newEx);
      return;
    }

    // Same media reference — update trim bounds in place. If the playhead
    // is outside the new window, seek back to the start.
    if (_controller != null && _initialized) {
      _updateTrimBounds(newEx);
    }
  }

  @override
  void dispose() {
    if (widget.respectGlobalPause) {
      MiniPreview.studioPauseAll.removeListener(_onGlobalPauseChanged);
    }
    _disposeController();
    super.dispose();
  }

  /// Treatment the mini should reflect — mirrors the Preview tab's
  /// current selection via `preferredTreatment`. Falls back to line.
  Treatment _treatmentFor(ExerciseCapture ex) =>
      ex.preferredTreatment ?? Treatment.line;

  /// True when the exercise wants the segmented body-pop variant for
  /// non-line treatments. Mirrors the Preview tab's _enhancedBackground
  /// getter (`bodyFocus ?? true` — default ON, opt-out per exercise).
  bool _bodyFocusFor(ExerciseCapture ex) => ex.bodyFocus ?? true;

  /// Returns the video path the mini should play, or null when the
  /// exercise isn't a playable video (rest / photo / missing file).
  /// Mirrors `_sourcePathForTreatment` in studio_mode_screen.dart:
  ///   * line                          → converted line-drawing
  ///   * grayscale/original + bodyFocus → segmentedRawFilePath
  ///   * grayscale/original + !bodyFocus → archive (raw 720p) → raw
  /// Each step falls through to the next-best on-disk file.
  String? _videoPathFor(ExerciseCapture ex) {
    if (ex.isRest) return null;
    if (ex.mediaType != MediaType.video) return null;
    final treatment = _treatmentFor(ex);
    if (treatment == Treatment.line) {
      final path = ex.absoluteConvertedFilePath;
      if (path != null && path.isNotEmpty && File(path).existsSync()) {
        return path;
      }
      return null;
    }
    // grayscale / original — try segmented body-pop first if Body Focus
    // is ON, then archive (raw 720p), then raw, then line-drawing.
    if (_bodyFocusFor(ex)) {
      final seg = ex.absoluteSegmentedRawFilePath;
      if (seg != null && seg.isNotEmpty && File(seg).existsSync()) {
        return seg;
      }
    }
    final archive = ex.absoluteArchiveFilePath;
    if (archive != null && archive.isNotEmpty && File(archive).existsSync()) {
      return archive;
    }
    final raw = ex.absoluteRawFilePath;
    if (raw.isNotEmpty && File(raw).existsSync()) return raw;
    final fallback = ex.absoluteConvertedFilePath;
    if (fallback != null &&
        fallback.isNotEmpty &&
        File(fallback).existsSync()) {
      return fallback;
    }
    return null;
  }

  void _initForExercise(ExerciseCapture ex) {
    final path = _videoPathFor(ex);
    if (path == null) {
      _initialized = false;
      return;
    }
    final controller = VideoPlayerController.file(File(path));
    _controller = controller;
    controller.initialize().then((_) {
      if (!mounted || !identical(controller, _controller)) {
        controller.dispose();
        return;
      }
      _updateTrimBounds(widget.exercise);
      controller.setVolume(0);
      // Native looping is OFF — we manage looping manually to honour the
      // trim window on every pass. setLooping(true) would loop the FULL
      // clip and ignore endOffsetMs.
      controller.setLooping(false);
      controller.seekTo(Duration(milliseconds: _startMs));
      void listener() => _onVideoTick(controller);
      controller.addListener(listener);
      _listener = listener;
      // If the global pause flag is set when this preview mounts (e.g.
      // a card scrolls in while the editor sheet is open), don't
      // autoplay — wait for the flag to flip via the listener.
      final globalPaused =
          widget.respectGlobalPause && MiniPreview.studioPauseAll.value;
      if (!globalPaused) controller.play();
      if (mounted) setState(() => _initialized = true);
    }).catchError((_) {
      // Swallow init failures — the placeholder branch will render via
      // `_initialized == false`.
    });
  }

  void _updateTrimBounds(ExerciseCapture ex) {
    final controller = _controller;
    if (controller == null) return;
    final durMs = controller.value.duration.inMilliseconds;
    final start = ex.startOffsetMs ?? 0;
    final end = ex.endOffsetMs ?? durMs;
    final clampedStart = start.clamp(0, durMs == 0 ? start : durMs);
    final clampedEnd = end.clamp(clampedStart, durMs == 0 ? end : durMs);
    _startMs = clampedStart;
    _endMs = clampedEnd;
    final posMs = controller.value.position.inMilliseconds;
    if (posMs < _startMs || posMs > _endMs) {
      controller.seekTo(Duration(milliseconds: _startMs));
    }
  }

  void _onVideoTick(VideoPlayerController controller) {
    if (!mounted) return;
    final value = controller.value;
    if (!value.isInitialized) return;
    final durMs = value.duration.inMilliseconds;
    if (durMs <= 0) return;
    // _endMs may be 0 if duration wasn't ready when _updateTrimBounds
    // first ran — fall back to durMs and update _endMs in place so the
    // next tick has the right window.
    int endMs = (_endMs > 0 && _endMs <= durMs) ? _endMs : durMs;
    if (_endMs == 0 || _endMs > durMs) _endMs = endMs;
    final posMs = value.position.inMilliseconds;
    // 50ms tolerance — listener fires on a coarse cadence and position
    // can land a frame past end-of-clip on iOS.
    if (posMs >= endMs - 50) {
      controller.seekTo(Duration(milliseconds: _startMs));
      // setLooping(false) means iOS pauses at end-of-clip; resume play
      // explicitly after every wraparound.
      if (!value.isPlaying) controller.play();
    }
  }

  void _disposeController() {
    final controller = _controller;
    if (controller == null) return;
    final listener = _listener;
    if (listener != null) {
      controller.removeListener(listener);
    }
    controller.pause().catchError((_) {});
    controller.dispose();
    _controller = null;
    _listener = null;
    _initialized = false;
  }

  // ---------------------------------------------------------------------------
  // Render
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final radius = widget.borderRadius ?? BorderRadius.circular(12);
    final ex = widget.exercise;
    // Hero-frame indicator: coral star top-left for video exercises only.
    // Photos ARE the Hero by definition (badge would be redundant); rest
    // periods have no media. Auto-picked motion-peak counts as the active
    // Hero — don't gate on `focus_frame_offset_ms` being non-null.
    final showHeroBadge =
        !ex.isRest && ex.mediaType == MediaType.video;
    final clip = ClipRRect(
      borderRadius: radius,
      child: Stack(
        fit: StackFit.expand,
        children: [
          IgnorePointer(child: _buildMedia()),
          if (showHeroBadge) const HeroStarBadge(),
          if (widget.overlay != null) widget.overlay!,
        ],
      ),
    );
    // Flood-fill mode — when width is infinite (and height is null), let
    // the parent size both axes (e.g. via StackFit.expand). Avoids the
    // ConstrainedBox(width: infinity) crash that hits when no maxWidth is
    // bounded above.
    final widthIsInfinite = widget.width == double.infinity;
    if (widthIsInfinite && widget.height == null) {
      return SizedBox.expand(child: clip);
    }
    if (widget.height != null) {
      return SizedBox(width: widget.width, height: widget.height, child: clip);
    }
    // Width-only fixed; height filled by parent (Row(stretch) +
    // IntrinsicHeight). ConstrainedBox preserves any maxHeight the
    // parent imposes while pinning width.
    return ConstrainedBox(
      constraints: BoxConstraints.tightFor(width: widget.width),
      child: clip,
    );
  }

  Widget _buildMedia() {
    final ex = widget.exercise;
    if (ex.isRest) return const _RestPlaceholder();
    final treatment = _treatmentFor(ex);
    if (ex.mediaType == MediaType.photo) {
      return _PhotoFrame(exercise: ex, treatment: treatment);
    }
    // Wave Hero — Studio cards + the editor sheet header opt into
    // [staticHero] so the practitioner sees the picked Hero shot, not
    // a playing video. The Preview tab inside the editor sheet still
    // gets motion via [MediaViewerBody] (a different widget).
    if (widget.staticHero) {
      return _HeroFrameImage(
        exercise: ex,
        treatment: treatment,
        cropOffset: widget.cropOffset,
      );
    }
    return _VideoFrame(
      controller: _controller,
      initialized: _initialized,
      fallbackExercise: ex,
      treatment: treatment,
    );
  }
}

// =============================================================================
// Internal: media branches
// =============================================================================

class _RestPlaceholder extends StatelessWidget {
  const _RestPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.rest.withValues(alpha: 0.18),
            AppColors.rest.withValues(alpha: 0.04),
          ],
        ),
      ),
      alignment: Alignment.center,
      child: const Icon(
        Icons.bedtime_outlined,
        size: 32,
        color: AppColors.rest,
      ),
    );
  }
}

class _PhotoFrame extends StatelessWidget {
  final ExerciseCapture exercise;
  final Treatment treatment;

  const _PhotoFrame({required this.exercise, required this.treatment});

  @override
  Widget build(BuildContext context) {
    // Treatment-aware path selection:
    //   * line      → converted (line-drawing JPG)
    //   * grayscale → raw (will receive a greyscale colour filter)
    //   * original  → raw
    // Falls back through thumbnail → raw → converted if the chosen one
    // is missing on disk.
    String? path;
    if (treatment == Treatment.line) {
      path = exercise.absoluteConvertedFilePath;
    } else {
      path = exercise.absoluteRawFilePath.isNotEmpty
          ? exercise.absoluteRawFilePath
          : null;
    }
    if (path == null || !File(path).existsSync()) {
      final thumb = exercise.absoluteThumbnailPath;
      if (thumb != null && File(thumb).existsSync()) path = thumb;
    }
    if (path == null || !File(path).existsSync()) {
      final raw = exercise.absoluteRawFilePath;
      if (raw.isNotEmpty && File(raw).existsSync()) path = raw;
    }
    if (path == null || !File(path).existsSync()) {
      final conv = exercise.absoluteConvertedFilePath;
      if (conv != null && File(conv).existsSync()) path = conv;
    }
    if (path == null || !File(path).existsSync()) {
      return const _PhotoFallback();
    }
    final image = Image.file(
      File(path),
      fit: BoxFit.cover,
      errorBuilder: (_, e, s) => const _PhotoFallback(),
    );
    if (treatment == Treatment.grayscale) {
      return ColorFiltered(colorFilter: _kGrayscaleFilter, child: image);
    }
    return image;
  }
}

class _PhotoFallback extends StatelessWidget {
  const _PhotoFallback();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF2A2D3A),
            Color(0xFF1A1D27),
          ],
        ),
      ),
      alignment: Alignment.center,
      child: const Icon(
        Icons.photo_outlined,
        size: 28,
        color: AppColors.textSecondaryOnDark,
      ),
    );
  }
}

class _VideoFrame extends StatelessWidget {
  final VideoPlayerController? controller;
  final bool initialized;
  final ExerciseCapture fallbackExercise;
  final Treatment treatment;

  const _VideoFrame({
    required this.controller,
    required this.initialized,
    required this.fallbackExercise,
    required this.treatment,
  });

  @override
  Widget build(BuildContext context) {
    if (!initialized || controller == null) {
      // Pre-init / failed-init — fall back to the static thumbnail chain
      // so the surface isn't a black void while the file is opening.
      return _PhotoFrame(exercise: fallbackExercise, treatment: treatment);
    }
    final size = controller!.value.size;
    final video = FittedBox(
      fit: BoxFit.cover,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: size.width == 0 ? 1 : size.width,
        height: size.height == 0 ? 1 : size.height,
        child: VideoPlayer(controller!),
      ),
    );
    if (treatment == Treatment.grayscale) {
      return ColorFiltered(colorFilter: _kGrayscaleFilter, child: video);
    }
    return video;
  }
}

/// Wave Hero — static-frame variant for video exercises. Reads the
/// per-treatment JPG written by [ConversionService.regenerateHeroThumbnails]
/// (and the post-conversion thumbnail extraction):
///
///   * line      → `{id}_thumb_line.jpg`  (frame from converted line video)
///   * grayscale → `{id}_thumb.jpg`       (B&W frame from raw)
///   * original  → `{id}_thumb_color.jpg` (colour frame from raw)
///
/// Falls through to the next-best on-disk JPG when a variant is missing
/// (e.g. a legacy exercise without colour/line variants), and finally
/// to the [_PhotoFrame] (which itself falls through to the dark glyph)
/// when no JPG exists at all.
///
/// Hero regeneration overwrites the JPG IN PLACE — same path, new bytes —
/// which Flutter's default `FileImage` cache can't see. We use
/// [_HeroFileImage] (a `FileImage` subclass that includes the picked
/// offset in its identity) so a fresh pick busts the cache and the
/// Studio card / editor header repaint with the new frame.
class _HeroFrameImage extends StatelessWidget {
  final ExerciseCapture exercise;
  final Treatment treatment;

  /// Wave Lobby PR 2 — practitioner-authored crop offset for the
  /// editor-sheet header live preview. Null = render at default
  /// `Alignment.center` (the legacy behaviour). When non-null we
  /// project the value onto the source's free axis based on the
  /// exercise's `aspectRatio`.
  final double? cropOffset;

  const _HeroFrameImage({
    required this.exercise,
    required this.treatment,
    this.cropOffset,
  });

  @override
  Widget build(BuildContext context) {
    final basePath = exercise.absoluteThumbnailPath;
    // No thumbnail extracted yet (e.g. mid-conversion on a fresh
    // capture). Show the dark fallback instead of trying to render the
    // raw video as an Image — that just bubbles up an error painter.
    if (basePath == null) {
      return const _PhotoFallback();
    }
    String thumbPath;
    switch (treatment) {
      case Treatment.line:
        thumbPath = basePath.replaceFirst('_thumb.jpg', '_thumb_line.jpg');
      case Treatment.grayscale:
        thumbPath = basePath; // default thumbnail IS B&W
      case Treatment.original:
        thumbPath = basePath.replaceFirst('_thumb.jpg', '_thumb_color.jpg');
    }
    final thumbFile = File(thumbPath);
    final fallbackFile = File(basePath);
    final useFile = thumbFile.existsSync() ? thumbFile : fallbackFile;
    if (!useFile.existsSync()) return const _PhotoFallback();
    final offset = exercise.focusFrameOffsetMs ?? 0;
    return Image(
      image: _HeroFileImage(useFile, offset),
      fit: BoxFit.cover,
      alignment: _alignmentFor(),
      errorBuilder: (_, e, s) => const _PhotoFallback(),
    );
  }

  /// Wave Lobby PR 2 — map the practitioner's normalised offset onto
  /// an [Alignment]. The free axis follows the source's
  /// `aspectRatio`:
  ///
  ///   * Landscape source (`aspect >= 1`) → drag X. Alignment.x maps
  ///     the offset to `[-1, +1]` (0 = -1, 0.5 = 0, 1 = +1).
  ///   * Portrait source (`aspect < 1`) → drag Y, same mapping on the
  ///     vertical axis.
  ///
  /// Null cropOffset OR null aspectRatio → return [Alignment.center]
  /// so legacy rows render unchanged.
  Alignment _alignmentFor() {
    final v = cropOffset;
    if (v == null) return Alignment.center;
    final aspect = exercise.aspectRatio;
    if (aspect == null || aspect <= 0) return Alignment.center;
    final clamped = v.clamp(0.0, 1.0);
    // Map [0..1] → [-1..+1].
    final axis = (clamped * 2.0) - 1.0;
    if (aspect >= 1.0) {
      // Landscape → free axis is X. Vertical stays centred.
      return Alignment(axis, 0.0);
    }
    // Portrait → free axis is Y. Horizontal stays centred.
    return Alignment(0.0, axis);
  }
}

/// `FileImage` whose cache identity includes the practitioner-picked
/// Hero offset. Without this, an in-place rewrite of the same path
/// (which is what [ConversionService.regenerateHeroThumbnails] does)
/// keeps the stale bytes in [PaintingBinding.imageCache]. Bumping the
/// offset → different `==` / `hashCode` → cache miss → fresh decode.
class _HeroFileImage extends FileImage {
  final int offsetMs;
  const _HeroFileImage(super.file, this.offsetMs);

  @override
  bool operator ==(Object other) {
    if (other is! _HeroFileImage) return false;
    return file.path == other.file.path && offsetMs == other.offsetMs;
  }

  @override
  int get hashCode => Object.hash(file.path, offsetMs);
}

