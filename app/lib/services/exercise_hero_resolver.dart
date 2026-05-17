// homefit.studio — Exercise Hero Resolver (Flutter Dart surface)
// ==============================================================
//
// Single stateless function that decides how to render an
// exercise's hero/poster on any of the four mobile surfaces (Studio
// card, ClientSessions filmstrip, MediaViewerBody Preview tab,
// camera peek). Pure: no IO except `File.existsSync()` for the
// availability check. Mirrors the web JS contract in
// `web-player/exercise_hero.js` so a future engineer reading both
// files sees the same shape.
//
// Load-bearing principle (2026-05-14 refactor):
//   1. Hero pictures everywhere reflect the per-exercise
//      `preferredTreatment` set by the practitioner. The resolver
//      derives treatment INTERNALLY from `exercise.preferredTreatment`
//      + body-focus from `exercise.bodyFocus`. Callers do NOT pass
//      treatment or bodyFocus arguments.
//   2. No silent fallbacks across treatments. If the requested
//      treatment's variant isn't on disk, the resolver returns
//      [ExerciseHero.unavailable] — the caller renders the
//      "treatment not available" placeholder. Showing a DIFFERENT
//      treatment's content silently is worse than showing nothing.
//
// Legitimate exceptions to "no fallback":
//   - Transient "regenerating" state while a thumbnail variant is
//     being extracted (caller's responsibility — the resolver only
//     ever says "not available right now").
//   - On HeroSurface.mediaViewer for VIDEOS we still ship the
//     `posterFile` as a pre-init poster while VideoPlayerController
//     spins up. That's the same treatment's poster, not a different
//     treatment.

import 'dart:io';

import 'package:flutter/widgets.dart' show ColorFilter;

import '../models/exercise_capture.dart';
import '../models/treatment.dart';
import 'thumb_paths.dart';

/// Greyscale matrix used by [ColorFiltered] for the B&W treatment on
/// surfaces whose source file is colour (photo raw JPG, raw archive
/// video). Mirrors the web player's CSS `filter: grayscale(1)
/// contrast(1.05)` look.
const ColorFilter kHeroGrayscaleFilter = ColorFilter.matrix(<double>[
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0, 0, 0, 1, 0, //
]);

/// Which mobile surface is asking for an [ExerciseHero]. Drives the
/// resolver's branching between "I want a playable video"
/// (mediaViewer only) and "I want a static poster" (everywhere
/// else).
enum HeroSurface {
  /// Studio exercise card — static thumbnail picker. Reads
  /// `{id}_thumb_line.jpg` / `{id}_thumb_color.jpg` / `{id}_thumb.jpg`
  /// for videos; line-drawing JPG / raw JPG for photos.
  studioCard,

  /// ClientSessionsScreen session-card filmstrip cell. Same
  /// posterFile semantics as [studioCard] — filmstrip now respects
  /// each exercise's `preferredTreatment` per the 2026-05-14
  /// "no surface-specific overrides" principle. (Pre-refactor the
  /// filmstrip force-grayscaled every video.)
  filmstrip,

  /// Editor sheet Preview tab. The only surface that returns a
  /// playable [ExerciseHero.videoFile] for videos. Photos still
  /// render a still poster.
  mediaViewer,

  /// Camera mode peek + recent-capture thumbnail. Static raster
  /// only; same poster picker as [studioCard].
  peek,
}

/// Capabilities surfaced on [ExerciseHero.caps]. Tells callers what
/// the surface should expose to the practitioner — eg. whether the
/// body-focus pill should be enabled.
class ExerciseHeroCaps {
  /// Whether the body-focus toggle is meaningful for this exercise.
  /// True only for videos. Photos have no segmented variant pipeline
  /// today, so the toggle is a no-op — callers should disable the
  /// pill with the existing tooltip when this is false.
  final bool hasBodyFocus;

  /// The treatments the exercise can actually play on this device.
  /// Always contains [Treatment.line] as the baseline. Adds
  /// [Treatment.grayscale] / [Treatment.original] when the
  /// underlying raw archive (video) or raw JPG (photo) exists on
  /// disk.
  final List<Treatment> availableTreatments;

  /// When the practitioner's chosen treatment isn't available
  /// locally, this is set to [Treatment.line] (the canonical
  /// fallback target). The resolver itself does NOT silently render
  /// Line — it returns [ExerciseHero.unavailable] so the caller
  /// shows a placeholder. The segmented control entry for the
  /// locked treatment should also be disabled.
  final Treatment? treatmentLockedTo;

  const ExerciseHeroCaps({
    required this.hasBodyFocus,
    required this.availableTreatments,
    this.treatmentLockedTo,
  });
}

/// Returned from [resolveExerciseHero] — describes how a caller
/// should render the exercise on the requested surface.
///
/// Three distinct "shapes":
///   - Normal hero: [videoFile] (mediaViewer-video) OR [posterFile]
///     (everything else) is non-null. [isUnavailable] is false.
///   - Unavailable: both files are null AND [isUnavailable] is true.
///     The requested treatment's variant isn't on disk. Caller
///     renders the coral-tinted "treatment not available" placeholder
///     (a `_HeroNotAvailable` widget). NEVER substitute a different
///     treatment.
///   - Rest period skeleton: both files are null AND [isUnavailable]
///     is false. Caller renders its own rest placeholder (sage glyph,
///     transparent, etc).
class ExerciseHero {
  /// For [HeroSurface.mediaViewer] + video exercises only: the file
  /// the caller should hand to `VideoPlayerController.file`.
  final File? videoFile;

  /// For static surfaces (everything except videos on
  /// [HeroSurface.mediaViewer]): the file the caller should put on
  /// `Image.file`. Null when the requested treatment's variant
  /// isn't on disk (caller renders the unavailable placeholder).
  final File? posterFile;

  /// Optional `ColorFilter` to wrap the rendered image / video in.
  /// Set to [kHeroGrayscaleFilter] when the effective treatment is
  /// grayscale and the underlying file is a colour source (raw JPG,
  /// archive mp4). Null when the file is already the right treatment
  /// (line-drawing JPG, line-drawing mp4, B&W thumbnail).
  final ColorFilter? filter;

  /// True when the requested treatment's variant isn't available
  /// locally. Caller MUST render the [_HeroNotAvailable] placeholder
  /// (NOT silently substitute a different treatment). Distinct from
  /// `posterFile == null && videoFile == null` for rest periods —
  /// rest periods have [isUnavailable] false.
  final bool isUnavailable;

  /// The treatment the resolver attempted to render (matches
  /// `treatmentFromWire(exercise.preferredTreatment)`). When
  /// [isUnavailable] is true this is the REQUESTED treatment, not
  /// any fallback — callers can label the placeholder with it.
  final Treatment treatment;

  /// Capabilities for this exercise — see [ExerciseHeroCaps].
  final ExerciseHeroCaps caps;

  const ExerciseHero({
    this.videoFile,
    this.posterFile,
    this.filter,
    this.isUnavailable = false,
    required this.treatment,
    required this.caps,
  });

  /// Skeleton variant — used for rest periods. Caller falls back to
  /// the surface's own rest placeholder. Distinct from
  /// [ExerciseHero.unavailable]: rest periods are NOT a missing
  /// variant, they're an intentional non-rendering branch.
  const ExerciseHero.skeleton({required this.caps})
      : videoFile = null,
        posterFile = null,
        filter = null,
        isUnavailable = false,
        treatment = Treatment.line;

  /// Unavailable variant — the requested treatment's file isn't on
  /// disk. Caller renders the coral-tinted placeholder.
  const ExerciseHero.unavailable({
    required this.treatment,
    required this.caps,
  })  : videoFile = null,
        posterFile = null,
        filter = null,
        isUnavailable = true;
}

// ============================================================================
// Treatment from wire — map preferred_treatment field
// ============================================================================

/// Map the exercise model's nullable [Treatment] enum to a
/// non-nullable treatment. Defaults to [Treatment.grayscale] (B&W) per the
/// 2026-05-15 publish-flow refactor (PR-B): the primary practitioner-facing
/// treatment is now B&W, with line demoted to one option among several.
/// New captures land with an explicit `preferred_treatment='grayscale'`
/// via `StickyDefaults.applyGlobalCaptureDefaults`; this read-time default
/// covers legacy NULL rows captured pre-2026-05-12. Mirrors the web JS
/// `treatmentFromWire` helper.
Treatment _treatmentFor(ExerciseCapture exercise) {
  return exercise.preferredTreatment ?? Treatment.grayscale;
}

bool _bodyFocusFor(ExerciseCapture exercise) {
  return exercise.bodyFocus ?? true;
}

// ============================================================================
// Capability computation
// ============================================================================

ExerciseHeroCaps _computeCaps(ExerciseCapture exercise, Treatment treatment) {
  if (exercise.isRest) {
    return const ExerciseHeroCaps(
      hasBodyFocus: false,
      availableTreatments: <Treatment>[],
      treatmentLockedTo: null,
    );
  }

  // Body focus is a video-only effect — photos have no segmented
  // variant pipeline yet.
  final isVideo = exercise.mediaType == MediaType.video;
  final hasBodyFocus = isVideo;

  // Line is always available — every conversion produces a line
  // drawing, and line is the default fallback target.
  final available = <Treatment>[Treatment.line];

  // Grayscale + Original require the raw source. For videos that's
  // the 720p H.264 archive mp4; for photos it's the raw colour JPG.
  final hasRawSource = _hasRawSource(exercise);
  if (hasRawSource) {
    available.add(Treatment.grayscale);
    available.add(Treatment.original);
  }

  Treatment? lockedTo;
  if ((treatment == Treatment.grayscale || treatment == Treatment.original) &&
      !hasRawSource) {
    lockedTo = Treatment.line;
  }

  return ExerciseHeroCaps(
    hasBodyFocus: hasBodyFocus,
    availableTreatments: available,
    treatmentLockedTo: lockedTo,
  );
}

/// True when the exercise has a local raw source that grayscale /
/// original treatments can play. For videos: the 720p H.264 archive
/// mp4. For photos: the raw colour JPG (.jpg / .jpeg / .png / .heic).
bool _hasRawSource(ExerciseCapture e) {
  if (e.mediaType == MediaType.video) {
    final path = e.absoluteArchiveFilePath;
    if (path == null) return false;
    return File(path).existsSync();
  }
  // Photo path — raw colour JPG must be an image extension.
  final raw = e.absoluteRawFilePath;
  if (raw.isEmpty) return false;
  final ext = raw.toLowerCase();
  final rawIsImage = ext.endsWith('.jpg') ||
      ext.endsWith('.jpeg') ||
      ext.endsWith('.png') ||
      ext.endsWith('.heic');
  if (!rawIsImage) return false;
  return File(raw).existsSync();
}

// ============================================================================
// Poster file picker — static thumbnail surfaces
// ============================================================================
//
// Strict per-treatment lookup. NO cross-treatment fallback. Returns
// null when the requested treatment's variant isn't on disk; the
// caller renders the unavailable placeholder.

File? _pickVideoPosterFile(ExerciseCapture exercise, Treatment treatment) {
  final basePath = exercise.absoluteThumbnailPath;
  if (basePath == null) return null;

  String thumbPath;
  switch (treatment) {
    case Treatment.line:
      thumbPath = thumbVariantPath(basePath, 'line');
    case Treatment.grayscale:
      thumbPath = basePath; // canonical thumbnail IS B&W
    case Treatment.original:
      thumbPath = thumbVariantPath(basePath, 'color');
  }
  final variantFile = File(thumbPath);
  if (variantFile.existsSync()) return variantFile;
  // No silent cross-treatment fallback: when the variant isn't on
  // disk, return null. Caller renders the unavailable placeholder.
  return null;
}

File? _pickPhotoPosterFile(ExerciseCapture exercise, Treatment treatment) {
  switch (treatment) {
    case Treatment.line:
      final conv = exercise.absoluteConvertedFilePath;
      if (conv != null && conv.isNotEmpty && File(conv).existsSync()) {
        return File(conv);
      }
      return null;
    case Treatment.grayscale:
    case Treatment.original:
      final raw = exercise.absoluteRawFilePath;
      if (raw.isNotEmpty && File(raw).existsSync()) return File(raw);
      return null;
  }
}

// ============================================================================
// Video playback file picker (mediaViewer surface only)
// ============================================================================
//
// Strict per-treatment lookup. The body-focus segmented-variant
// fallback to untouched raw is NOT a cross-treatment substitution —
// it's the same treatment expressed differently on the same source
// (segmented mp4 = body-pop overlay of the raw mp4). So we allow it.

File? _pickVideoPlaybackFile(
  ExerciseCapture exercise,
  Treatment treatment,
  bool bodyFocus,
) {
  if (exercise.mediaType != MediaType.video) return null;

  if (treatment == Treatment.line) {
    final path = exercise.absoluteConvertedFilePath;
    if (path != null && path.isNotEmpty && File(path).existsSync()) {
      return File(path);
    }
    return null;
  }

  // grayscale / original — try the segmented body-pop variant first
  // when body-focus is ON, then the raw archive. NO fallback to the
  // line drawing — that's a cross-treatment substitution.
  if (bodyFocus) {
    final seg = exercise.absoluteSegmentedRawFilePath;
    if (seg != null && seg.isNotEmpty && File(seg).existsSync()) {
      return File(seg);
    }
  }
  final archive = exercise.absoluteArchiveFilePath;
  if (archive != null && archive.isNotEmpty && File(archive).existsSync()) {
    return File(archive);
  }
  return null;
}

// ============================================================================
// Public API
// ============================================================================

/// Resolve the hero/poster shape for a single exercise on a single
/// mobile surface.
///
/// Treatment and body-focus are derived INTERNALLY from
/// `exercise.preferredTreatment` and `exercise.bodyFocus`. The caller
/// does NOT pass these as arguments. To switch treatments mid-session,
/// mutate the exercise model and re-render.
///
/// Returns:
///   - Normal hero (`ExerciseHero` with files set) when the
///     practitioner's chosen treatment is available locally.
///   - `ExerciseHero.unavailable` when the variant isn't on disk —
///     caller renders the `_HeroNotAvailable` placeholder.
///   - `ExerciseHero.skeleton` for rest periods — caller renders its
///     own rest placeholder.
ExerciseHero resolveExerciseHero({
  required ExerciseCapture exercise,
  required HeroSurface surface,
}) {
  // Rest periods: skeleton.
  if (exercise.isRest) {
    return const ExerciseHero.skeleton(
      caps: ExerciseHeroCaps(
        hasBodyFocus: false,
        availableTreatments: <Treatment>[],
        treatmentLockedTo: null,
      ),
    );
  }

  final treatment = _treatmentFor(exercise);
  final bodyFocus = _bodyFocusFor(exercise);
  final caps = _computeCaps(exercise, treatment);

  // No silent cross-treatment fallback. If the practitioner's chosen
  // treatment isn't available, the resolver reports unavailable and
  // the caller renders the placeholder. EXCEPTION: when treatment is
  // already Line, "unavailable" means the line file is missing too,
  // which we'd still surface via the file-check below.
  if (caps.treatmentLockedTo == Treatment.line && treatment != Treatment.line) {
    return ExerciseHero.unavailable(treatment: treatment, caps: caps);
  }

  final isPhoto = exercise.mediaType == MediaType.photo;

  // ---------------------------------------------------------------
  // MediaViewer + video — return the playable file
  // ---------------------------------------------------------------
  if (surface == HeroSurface.mediaViewer && !isPhoto) {
    final video = _pickVideoPlaybackFile(exercise, treatment, bodyFocus);
    // For grayscale we apply the matrix filter on top of the raw mp4
    // since the raw mp4 is colour. For line + original the bytes are
    // already the target colour space (line drawing OR raw colour).
    final filter =
        treatment == Treatment.grayscale ? kHeroGrayscaleFilter : null;
    if (video == null) {
      // No playable file on disk. Still try to surface a poster so
      // the viewer shows something while the file resolves. If the
      // poster is missing too, this is genuinely unavailable.
      final poster = _pickVideoPosterFile(exercise, treatment);
      if (poster == null) {
        return ExerciseHero.unavailable(treatment: treatment, caps: caps);
      }
      return ExerciseHero(
        videoFile: null,
        posterFile: poster,
        filter: filter,
        treatment: treatment,
        caps: caps,
      );
    }
    return ExerciseHero(
      videoFile: video,
      posterFile: _pickVideoPosterFile(exercise, treatment),
      filter: filter,
      treatment: treatment,
      caps: caps,
    );
  }

  // ---------------------------------------------------------------
  // Static surfaces — return a poster
  // ---------------------------------------------------------------
  File? poster;
  ColorFilter? filter;

  if (isPhoto) {
    poster = _pickPhotoPosterFile(exercise, treatment);
    // Photo grayscale is realised via ColorFilter on the raw JPG.
    // Photo line renders the converted line-drawing JPG directly (no
    // filter). Photo original = raw, no filter.
    filter = treatment == Treatment.grayscale ? kHeroGrayscaleFilter : null;
  } else {
    // Video on a static surface. The per-treatment thumbnail
    // (_thumb.jpg = B&W, _thumb_color.jpg, _thumb_line.jpg) already
    // encodes the right pixels — no ColorFilter on top.
    poster = _pickVideoPosterFile(exercise, treatment);
    filter = null;
  }

  if (poster == null) {
    return ExerciseHero.unavailable(treatment: treatment, caps: caps);
  }

  return ExerciseHero(
    videoFile: null,
    posterFile: poster,
    filter: filter,
    treatment: treatment,
    caps: caps,
  );
}
