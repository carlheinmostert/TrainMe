// homefit.studio — Exercise Hero Resolver (Flutter Dart surface)
// ==============================================================
//
// Single stateless function that decides how to render an
// exercise's hero/poster on any of the four mobile surfaces (Studio
// card, ClientSessions filmstrip, MediaViewerBody Preview tab,
// camera peek). Pure: no IO except `File.existsSync()` for the
// fallback chains. Mirrors the web JS contract in
// `web-player/exercise_hero.js` (Bundle 1) so a future engineer
// reading both files sees the same shape — see audit
// `docs/audits/photo-video-treatment-audit-2026-05-13.md` for the
// full divergence map.
//
// Why this exists: pre-resolver each surface independently
// re-derived treatment + body-focus + photo-vs-video file
// selection without sharing any contract. F17 (filmstrip picker
// rule) is unrelated; the resolver formalises the rest.
//
// Surfaces:
//   - HeroSurface.studioCard   — Studio exercise card thumbnails
//                                (Mini Preview static-hero path).
//                                Caller renders an Image.file with
//                                fallback chain.
//   - HeroSurface.filmstrip    — ClientSessionsScreen session-card
//                                background tiles. Static posters
//                                with `_kFilmstripGrayscale` filter
//                                for videos. Photos stay line-only
//                                per the documented mixed-treatment
//                                aesthetic.
//   - HeroSurface.mediaViewer  — Editor sheet Preview tab. Caller
//                                spins up a VideoPlayerController
//                                against [ExerciseHero.videoFile]
//                                for video exercises; renders the
//                                [posterFile] + [filter] for photos.
//   - HeroSurface.peek         — Camera-mode peek + last-captured
//                                thumbnail. Static raster only.
//
// Photo vs video branching (current files only — Bundle 2b will
// add `_thumb.jpg` / `_thumb_color.jpg` / `_thumb_line.jpg`
// thumbnail variants for photos in PR 6). The resolver degrades
// gracefully when those files don't exist: it falls through to
// the existing photo path-selection logic (rawFilePath for
// grayscale/original, convertedFilePath for line).

import 'dart:io';

import 'package:flutter/widgets.dart' show ColorFilter;

import '../models/exercise_capture.dart';
import '../models/treatment.dart';

/// Greyscale matrix used by [ColorFiltered] for the B&W treatment.
///
/// Mirrors the web player's CSS `filter: grayscale(1) contrast(1.05)`
/// look. Single canonical instance — replaces the prior duplicates
/// scattered across `mini_preview.dart` (`_kGrayscaleFilter`),
/// `capture_thumbnail.dart` (`_kGrayscaleFilter`), and
/// `session_card.dart` (`_kFilmstripGrayscale`). Two distinct
/// matrices used to live in the codebase — the Rec. 709 luminance
/// weights (0.2126/0.7152/0.0722) for the filmstrip + capture
/// thumbnail surfaces, and a flatter (0.299/0.587/0.114, NTSC
/// weights) variant for `mini_preview.dart`. We unify on Rec. 709
/// since that's what the web player approximates via CSS `filter:
/// grayscale(1)` and what 3/4 prior callers already used; the NTSC
/// variant was the outlier.
const ColorFilter kHeroGrayscaleFilter = ColorFilter.matrix(<double>[
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0, 0, 0, 1, 0, //
]);

/// Which mobile surface is asking for an [ExerciseHero]. Drives
/// the resolver's branching between "I want a playable video"
/// (mediaViewer only) and "I want a static poster" (everywhere
/// else).
enum HeroSurface {
  /// Studio exercise card — static thumbnail picker. Reads
  /// `{id}_thumb_line.jpg` / `{id}_thumb_color.jpg` / `{id}_thumb.jpg`
  /// for videos; line-drawing JPG / raw JPG for photos.
  studioCard,

  /// ClientSessionsScreen session-card filmstrip cell. Same
  /// posterFile semantics as [studioCard], but the filmstrip
  /// applies [kHeroGrayscaleFilter] to videos regardless of
  /// `preferredTreatment` (documented mixed-treatment aesthetic:
  /// B&W videos + line photos).
  filmstrip,

  /// Editor sheet Preview tab. The only surface that returns a
  /// playable [ExerciseHero.videoFile] for videos. Photos still
  /// render a still poster.
  mediaViewer,

  /// Camera mode peek + recent-capture thumbnail. Static raster
  /// only; falls back through the same chain as [studioCard].
  peek,
}

/// Capabilities surfaced on [ExerciseHero.caps]. Tells callers what
/// the surface should expose to the practitioner — eg. whether the
/// body-focus pill should be enabled.
class ExerciseHeroCaps {
  /// Whether the body-focus toggle is meaningful for this exercise.
  /// True only for videos. Photos have no segmented variant pipeline
  /// today (see audit F21) so the toggle is a no-op — callers should
  /// disable the pill with the existing tooltip when this is false.
  final bool hasBodyFocus;

  /// The treatments the exercise can actually play on this device,
  /// in canonical order. Always contains [Treatment.line] as the
  /// baseline (line drawings are always available). Adds
  /// [Treatment.grayscale] / [Treatment.original] when the
  /// underlying raw archive (video) or raw JPG (photo) exists on
  /// disk.
  final List<Treatment> availableTreatments;

  /// When the requested treatment isn't available locally, this is
  /// set to [Treatment.line] (the always-available fallback).
  /// Callers can short-circuit to Line rendering and disable the
  /// segmented control entry for the locked treatment. Null when
  /// the requested treatment IS available.
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
/// Shape mirrors the web JS [resolveExerciseHero] return value
/// from `web-player/exercise_hero.js` so a future engineer reading
/// both files sees the same contract. Field names diverge where
/// the platform demands (Dart [File] vs JS URL string; Flutter
/// [ColorFilter] vs CSS filter string) but the semantics line up.
class ExerciseHero {
  /// For [HeroSurface.mediaViewer] + video exercises only: the file
  /// the caller should hand to `VideoPlayerController.file`. Null
  /// when the exercise is a photo, a rest period, or the requested
  /// playback source isn't on disk.
  final File? videoFile;

  /// For static surfaces (everything except videos on
  /// [HeroSurface.mediaViewer]): the file the caller should put on
  /// `Image.file`. Null when no candidate file exists (caller
  /// renders the fallback widget).
  final File? posterFile;

  /// Optional `ColorFilter` to wrap the rendered image / video in.
  /// Set to [kHeroGrayscaleFilter] when the effective treatment is
  /// grayscale and the underlying file is a colour source (raw
  /// JPG, archive mp4). Null when the file is already the right
  /// treatment (line-drawing JPG, line-drawing mp4, B&W thumbnail).
  final ColorFilter? filter;

  /// Capabilities for this exercise — see [ExerciseHeroCaps].
  final ExerciseHeroCaps caps;

  const ExerciseHero({
    this.videoFile,
    this.posterFile,
    this.filter,
    required this.caps,
  });

  /// Skeleton variant — used for rest periods and any exercise the
  /// resolver can't render on the requested surface (eg. missing
  /// raw on a fresh re-install). Caller falls back to the surface's
  /// default placeholder.
  const ExerciseHero.skeleton({required this.caps})
      : videoFile = null,
        posterFile = null,
        filter = null;
}

// ============================================================================
// Capability computation
// ============================================================================

/// Compute [ExerciseHeroCaps] for an exercise given the requested
/// treatment. Mirrors the JS resolver's `computeCaps` — same
/// semantics for `hasBodyFocus`, `availableTreatments`,
/// `treatmentLockedTo`.
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
  // drawing, and line is the default fallback.
  final available = <Treatment>[Treatment.line];

  // Grayscale + Original require the raw source. For videos that's
  // the 720p H.264 archive mp4; for photos it's the raw colour JPG.
  // Same binary contract as `_hasArchive` in studio_mode_screen.dart.
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
/// Mirrors the existing `_hasArchive` in
/// `studio_mode_screen.dart:3867` so the resolver's
/// `availableTreatments` matches the gating logic the editor sheet
/// already enforces.
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
// Poster file picker — static thumbnail surfaces (Studio card, filmstrip, peek)
// ============================================================================

/// Resolve the static poster file for a video exercise.
///
/// Reads the per-treatment thumbnail variants written at
/// conversion time:
///   - line      → `{id}_thumb_line.jpg`  (frame from converted video)
///   - grayscale → `{id}_thumb.jpg`       (B&W frame from raw)
///   - original  → `{id}_thumb_color.jpg` (colour frame from raw)
///
/// Falls back to the canonical `_thumb.jpg` when a variant is
/// missing (eg. a legacy exercise without colour/line variants).
/// Mirrors the existing `_HeroFrameImage` logic at
/// `mini_preview.dart:606` so behaviour is preserved.
///
/// Returns null when no thumbnail JPG exists at all — caller
/// surfaces the fallback widget.
File? _pickVideoPosterFile(ExerciseCapture exercise, Treatment treatment) {
  final basePath = exercise.absoluteThumbnailPath;
  if (basePath == null) return null;

  String thumbPath;
  switch (treatment) {
    case Treatment.line:
      thumbPath = basePath.replaceFirst('_thumb.jpg', '_thumb_line.jpg');
    case Treatment.grayscale:
      thumbPath = basePath; // default thumbnail IS B&W
    case Treatment.original:
      thumbPath = basePath.replaceFirst('_thumb.jpg', '_thumb_color.jpg');
  }
  final variantFile = File(thumbPath);
  if (variantFile.existsSync()) return variantFile;

  // Fall back to the canonical thumbnail if the variant is missing.
  final fallbackFile = File(basePath);
  if (fallbackFile.existsSync()) return fallbackFile;
  return null;
}

/// Resolve the static poster file for a photo exercise.
///
/// Bundle 2a behaviour (current files only — Bundle 2b PR 6 will
/// add `_thumb_*` variants for photos):
///   - line      → converted line-drawing JPG
///   - grayscale → raw colour JPG (filter applies B&W)
///   - original  → raw colour JPG
///
/// Falls through thumbnail → raw → converted when the chosen file
/// is missing (mirrors the existing `_PhotoFrame.build` fallback
/// chain at `mini_preview.dart:451`).
File? _pickPhotoPosterFile(ExerciseCapture exercise, Treatment treatment) {
  String? candidate;
  if (treatment == Treatment.line) {
    candidate = exercise.absoluteConvertedFilePath;
  } else {
    final raw = exercise.absoluteRawFilePath;
    candidate = raw.isNotEmpty ? raw : null;
  }
  if (candidate != null && File(candidate).existsSync()) return File(candidate);

  // Fallback chain — thumbnail → raw → converted.
  final thumb = exercise.absoluteThumbnailPath;
  if (thumb != null && File(thumb).existsSync()) return File(thumb);
  final raw = exercise.absoluteRawFilePath;
  if (raw.isNotEmpty && File(raw).existsSync()) return File(raw);
  final conv = exercise.absoluteConvertedFilePath;
  if (conv != null && File(conv).existsSync()) return File(conv);
  return null;
}

// ============================================================================
// Video playback file picker (mediaViewer surface only)
// ============================================================================

/// Resolve the playable video file for [HeroSurface.mediaViewer]
/// + video exercises. Mirrors `_sourcePathForTreatment` at
/// `studio_mode_screen.dart:4028` + `_videoPathFor` at
/// `mini_preview.dart:220` (the latter has a richer fallback chain
/// which we adopt here as the single source of truth).
///
/// Returns null when nothing on disk can play (caller falls back
/// to the static photo path or skeleton).
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
  // when body-focus is ON, then the raw archive, then the raw, then
  // the line drawing.
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
  final raw = exercise.absoluteRawFilePath;
  if (raw.isNotEmpty && File(raw).existsSync()) return File(raw);
  final fallback = exercise.absoluteConvertedFilePath;
  if (fallback != null &&
      fallback.isNotEmpty &&
      File(fallback).existsSync()) {
    return File(fallback);
  }
  return null;
}

// ============================================================================
// Public API
// ============================================================================

/// Resolve the hero/poster shape for a single exercise on a single
/// mobile surface.
///
/// Pure synchronous function — no IO except `File.existsSync()`
/// for fallback chains. Idempotent on its inputs; safe to call on
/// every rebuild.
///
/// Surface semantics:
///   - [HeroSurface.mediaViewer] for video exercises returns
///     [ExerciseHero.videoFile] for `VideoPlayerController.file`.
///     The caller renders a `VideoPlayer` widget and applies
///     [ExerciseHero.filter] if non-null.
///   - All other surfaces (or [HeroSurface.mediaViewer] for photos)
///     return [ExerciseHero.posterFile] for `Image.file`. Caller
///     wraps in [ColorFiltered] when [ExerciseHero.filter] is set.
///
/// Capabilities:
///   - [ExerciseHero.caps.hasBodyFocus] is true ONLY for videos —
///     callers should disable the body-focus pill with the
///     "available for video exercises only" tooltip otherwise.
///   - [ExerciseHero.caps.treatmentLockedTo] is non-null when the
///     requested treatment isn't available locally. The resolver
///     internally falls back to [Treatment.line] in that case;
///     callers can additionally disable the segmented-control
///     entry for the locked treatment.
///
/// Photo body-focus + grayscale behaviour: for photos, grayscale
/// is realised via [kHeroGrayscaleFilter] applied on top of the
/// raw colour JPG (matches the web player's CSS `filter:
/// grayscale(1)`). Photos have no body-focus variant; `bodyFocus`
/// is ignored for photo exercises.
ExerciseHero resolveExerciseHero({
  required ExerciseCapture exercise,
  required Treatment treatment,
  required bool bodyFocus,
  required HeroSurface surface,
}) {
  // Rest periods: no hero. Caller renders the surface's own rest
  // placeholder (sage glyph on MediaViewer, transparent on
  // filmstrip, etc).
  if (exercise.isRest) {
    return const ExerciseHero.skeleton(
      caps: ExerciseHeroCaps(
        hasBodyFocus: false,
        availableTreatments: <Treatment>[],
        treatmentLockedTo: null,
      ),
    );
  }

  final caps = _computeCaps(exercise, treatment);
  // Fall back to Line when the requested treatment isn't available
  // — matches `_effectiveTreatmentFor` in studio_mode_screen.dart.
  final effective =
      caps.treatmentLockedTo == Treatment.line ? Treatment.line : treatment;

  final isPhoto = exercise.mediaType == MediaType.photo;

  // ---------------------------------------------------------------
  // MediaViewer + video — return the playable file
  // ---------------------------------------------------------------
  if (surface == HeroSurface.mediaViewer && !isPhoto) {
    final video = _pickVideoPlaybackFile(exercise, effective, bodyFocus);
    final filter =
        effective == Treatment.grayscale ? kHeroGrayscaleFilter : null;
    if (video == null) {
      // No playable file on disk — fall back to a still poster so
      // the surface isn't a black void (mirrors `_VideoFrame`
      // pre-init fallback at `mini_preview.dart:541`).
      final poster = _pickVideoPosterFile(exercise, effective);
      return ExerciseHero(
        videoFile: null,
        posterFile: poster,
        filter: filter,
        caps: caps,
      );
    }
    return ExerciseHero(
      videoFile: video,
      posterFile: _pickVideoPosterFile(exercise, effective),
      filter: filter,
      caps: caps,
    );
  }

  // ---------------------------------------------------------------
  // Static surfaces (Studio card, filmstrip, peek) — return a poster
  // ---------------------------------------------------------------
  File? poster;
  ColorFilter? filter;

  if (isPhoto) {
    poster = _pickPhotoPosterFile(exercise, effective);
    // Photos realise B&W via CSS filter (web) / ColorFilter (mobile)
    // applied on top of the raw colour JPG. Line photos render the
    // converted file directly (no filter needed). Original = raw,
    // no filter.
    filter = effective == Treatment.grayscale ? kHeroGrayscaleFilter : null;
  } else {
    // Video on a static surface. The thumbnail variants ALREADY
    // encode B&W (the canonical `_thumb.jpg` IS the B&W extract from
    // raw). So we DON'T apply kHeroGrayscaleFilter on top — that
    // would double-grayscale a colour variant or do nothing on a
    // pre-greyed thumb. The filmstrip is the one exception: it
    // forces B&W on every video regardless of `preferredTreatment`
    // (documented mixed-treatment aesthetic in `session_card.dart`).
    poster = _pickVideoPosterFile(exercise, effective);
    if (surface == HeroSurface.filmstrip) {
      filter = kHeroGrayscaleFilter;
    } else {
      filter = null;
    }
  }

  return ExerciseHero(
    videoFile: null,
    posterFile: poster,
    filter: filter,
    caps: caps,
  );
}
