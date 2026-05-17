import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../models/exercise_capture.dart';
import '../models/treatment.dart';
import '../services/exercise_hero_resolver.dart';
import '../theme.dart';
import '../utils/hero_crop_alignment.dart';
import 'hero_star_badge.dart';

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
      // image cache keys on the path; ConversionService.regenerateHero
      // Thumbnails overwrites the JPG in place, so [_HeroFileImage]
      // uses file-mtime (not focus_frame_offset_ms) as the cache-bust
      // signal so a regen-completion repaints with the new bytes
      // without flickering during a drag (mtime is stable while the
      // file content is unchanged).
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
  /// current selection via `preferredTreatment`. Falls back to B&W
  /// (grayscale) per the 2026-05-15 publish-flow refactor (PR-B).
  ///
  /// Read internally for state-tracking (e.g. `didUpdateWidget`
  /// path comparison) — the actual file selection routes through
  /// [resolveExerciseHero] so all surfaces converge on the same
  /// contract.
  Treatment _treatmentFor(ExerciseCapture ex) =>
      ex.preferredTreatment ?? Treatment.grayscale;

  /// Returns the video path the mini should play, or null when the
  /// exercise isn't a playable video (rest / photo / missing file).
  /// Delegates to [resolveExerciseHero] (HeroSurface.mediaViewer)
  /// so the playback fallback chain stays in lockstep with the
  /// editor sheet's Preview tab + the bundled web player.
  String? _videoPathFor(ExerciseCapture ex) {
    if (ex.isRest) return null;
    if (ex.mediaType != MediaType.video) return null;
    final hero = resolveExerciseHero(
      exercise: ex,
      surface: HeroSurface.mediaViewer,
    );
    return hero.videoFile?.path;
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
    // Treatment-aware path selection routes through the resolver so
    // the photo fallback chain (treatment file → thumbnail → raw →
    // converted) stays in lockstep with Studio cards + filmstrip +
    // peek.
    final hero = resolveExerciseHero(
      exercise: exercise,
      surface: HeroSurface.studioCard,
    );
    final file = hero.posterFile;
    if (file == null) return const _PhotoFallback();
    // Wave Lobby — practitioner-authored 1:1 crop window.
    final align = heroCropAlignment(exercise);
    final image = Image.file(
      file,
      fit: BoxFit.cover,
      alignment: align,
      errorBuilder: (_, e, s) => const _PhotoFallback(),
    );
    final filter = hero.filter;
    if (filter != null) {
      return ColorFiltered(colorFilter: filter, child: image);
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
    // Wave Lobby — practitioner-authored 1:1 crop window. FittedBox
    // accepts an [alignment] which controls which part of the child
    // is visible after BoxFit.cover scaling.
    final align = heroCropAlignment(fallbackExercise);
    final video = FittedBox(
      fit: BoxFit.cover,
      alignment: align,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: size.width == 0 ? 1 : size.width,
        height: size.height == 0 ? 1 : size.height,
        child: VideoPlayer(controller!),
      ),
    );
    if (treatment == Treatment.grayscale) {
      return ColorFiltered(colorFilter: kHeroGrayscaleFilter, child: video);
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
/// [_HeroFileImage] (a `FileImage` subclass that includes the file's
/// last-modified-time in its identity) so the regen-completion (which
/// advances mtime) busts the cache and the Studio card / bottom rail
/// repaints with the new frame. Keying on mtime rather than the picked
/// offset also keeps the glyph stable mid-drag — `_persistHero`
/// optimistically bumps `focusFrameOffsetMs` every gesture tick, but the
/// JPG bytes don't change until the 250ms-debounced regen lands, so
/// keying on offset would flicker the cache on every tick while still
/// painting the same stale bytes.
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
    // Route the per-treatment thumbnail variant selection through the
    // resolver so the {id}_thumb_line.jpg / _thumb_color.jpg / _thumb.jpg
    // fallback chain is shared with the rest of the static-poster
    // surfaces (Studio card, filmstrip, peek).
    final hero = resolveExerciseHero(
      exercise: exercise,
      surface: HeroSurface.studioCard,
    );
    final useFile = hero.posterFile;
    if (useFile == null) return const _PhotoFallback();
    // Cache-bust on file mtime, not on focus_frame_offset_ms. Regen
    // overwrites the JPG in place, advancing mtime; mid-drag the
    // optimistic offset bumps every gesture tick but the file bytes are
    // unchanged, so mtime is the right signal for "the picture really
    // did change".
    int mtimeMs;
    try {
      mtimeMs = useFile.lastModifiedSync().millisecondsSinceEpoch;
    } catch (_) {
      // Filesystems that race a rewrite vs. a stat can throw — fall
      // back to 0 so we still render the on-disk bytes (cache hit on
      // the prior key is acceptable; next paint with a real mtime busts
      // it cleanly).
      mtimeMs = 0;
    }
    // Wave Lobby — practitioner-authored 1:1 crop window. Defaults to
    // centred for legacy / un-authored exercises so the existing pixel
    // output is preserved.
    final align = heroCropAlignment(exercise);
    return Image(
      image: _HeroFileImage(useFile, mtimeMs),
      fit: BoxFit.cover,
      alignment: align,
      errorBuilder: (_, e, s) => const _PhotoFallback(),
    );
  }

  /// Wave Lobby PR 2 — map the practitioner's normalised offset onto
  /// an [Alignment]. The free axis follows the source's
  /// `aspectRatio`:
}

/// `FileImage` whose cache identity includes the JPG's
/// `lastModified.millisecondsSinceEpoch`. Without this, an in-place
/// rewrite of the same path (which is what
/// [ConversionService.regenerateHeroThumbnails] does) keeps the stale
/// bytes in [PaintingBinding.imageCache]. mtime advances only when the
/// file is actually rewritten, so it sidesteps the mid-drag flicker that
/// keying on `focusFrameOffsetMs` introduces (the offset bumps every
/// gesture tick but the bytes are stale until the debounce lands).
class _HeroFileImage extends FileImage {
  final int mtimeMs;
  const _HeroFileImage(super.file, this.mtimeMs);

  @override
  bool operator ==(Object other) {
    if (other is! _HeroFileImage) return false;
    return file.path == other.file.path && mtimeMs == other.mtimeMs;
  }

  @override
  int get hashCode => Object.hash(file.path, mtimeMs);
}

