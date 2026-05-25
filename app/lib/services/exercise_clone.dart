import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../models/exercise_capture.dart';
import '../models/exercise_set.dart';
import '../models/session.dart';
import 'path_resolver.dart';

/// Deep-copy an exercise row into a (possibly different) target session.
///
/// Shared machinery used by:
///   1. Studio's in-session **Duplicate** path (swipe right, partial swipe
///      → tap `[Duplicate]`).
///   2. The cross-session **Paste** path coming out of the Exercise
///      Clipboard (`docs/specs/2026-05-25-exercise-clipboard.md`, D2).
///
/// Carries every field that describes *what the footage is*; resets every
/// field that describes *where the row lives*; strips circuit membership
/// (circuits are session-structural). See the spec's "Deep-copy
/// semantics" section for the per-field policy.
///
/// **Files copied** (when the source path exists on disk):
///   * `rawFilePath`, `convertedFilePath`, `thumbnailPath`,
///     `archiveFilePath`, `segmentedRawFilePath`, `maskFilePath`,
///     `safeRawFilePath`
///   * Thumbnail variants `{oldId}_thumb_color.jpg`, `{oldId}_thumb_line.jpg`,
///     `{oldId}_thumb_bw.jpg`
///
/// All copies happen against [PathResolver] absolute paths and store the
/// relative paths on the new row. Missing source files are skipped
/// silently — the resulting row holds null on the missing field and the
/// rest of the pipeline (conversion service, upload service) treats it
/// as a partial-state row.
///
/// **Identity:** new UUID, [createdAt] = now. [sessionId] is the target
/// session's id. [position] defaults to `targetSession.exercises.length`
/// (append). Callers can override via [positionOverride] for splice-
/// insert paths.
///
/// **Reset / re-derive:**
///   * `id` — fresh UUID.
///   * `sessionId` — `targetSession.id`.
///   * `position` — [positionOverride] ?? end of target.
///   * `createdAt` — [DateTime.now].
///   * `thumbnailsDirty` — `false` (variants are copied, not regenerated).
///   * `rawArchiveUploadedAt` — null (cloud upload is per-id, must re-run).
///   * `lineDrawingUrl` / `grayscaleUrl` / `originalUrl` — null (runtime-
///     only fields populated by `get_plan_full` at publish-fetch time).
///
/// **Stripped:**
///   * `circuitId` → null. Circuit membership is session-structural and
///     does not survive cross-session paste. A future "Copy circuit"
///     gesture could revisit this; v1 ships without it.
///
/// Returns the freshly-minted [ExerciseCapture]. The caller is
/// responsible for persisting via `LocalStorageService.saveExercise`
/// and re-stamping sibling positions if [positionOverride] inserted
/// mid-list.
Future<ExerciseCapture> cloneExerciseInto({
  required ExerciseCapture source,
  required Session targetSession,
  int? positionOverride,
}) async {
  final newId = const Uuid().v4();
  final position = positionOverride ?? targetSession.exercises.length;

  // Deep-copy files. Each helper resolves the source's relative path,
  // copies to a new path with the new exercise id, and returns the
  // relative path for storage. Skips gracefully if the source doesn't
  // exist.
  String? newRawFilePath;
  String? newConvertedFilePath;
  String? newThumbnailPath;
  String? newArchiveFilePath;
  String? newSegmentedRawFilePath;
  String? newMaskFilePath;
  String? newSafeRawFilePath;

  try {
    newRawFilePath = await _copyExerciseFile(
      source.rawFilePath,
      source.id,
      newId,
    );
    newConvertedFilePath = await _copyExerciseFile(
      source.convertedFilePath,
      source.id,
      newId,
    );
    newThumbnailPath = await _copyExerciseFile(
      source.thumbnailPath,
      source.id,
      newId,
    );
    // Also copy the per-treatment thumbnail variants if they exist.
    // These live under {docs}/thumbnails/{exerciseId}_thumb_<variant>.jpg.
    await _copyThumbnailVariant(source.id, newId, '_thumb_color.jpg');
    await _copyThumbnailVariant(source.id, newId, '_thumb_line.jpg');
    await _copyThumbnailVariant(source.id, newId, '_thumb_bw.jpg');

    newArchiveFilePath = await _copyExerciseFile(
      source.archiveFilePath,
      source.id,
      newId,
    );
    newSegmentedRawFilePath = await _copyExerciseFile(
      source.segmentedRawFilePath,
      source.id,
      newId,
    );
    newMaskFilePath = await _copyExerciseFile(
      source.maskFilePath,
      source.id,
      newId,
    );
    newSafeRawFilePath = await _copyExerciseFile(
      source.safeRawFilePath,
      source.id,
      newId,
    );
  } catch (e) {
    debugPrint('cloneExerciseInto file copy failed: $e');
    // Continue with whatever we managed to copy. The new row will
    // surface the partial state through the existing conversion-status
    // path; the deep-copy itself is best-effort.
  }

  // Per-set rows: full deep copy with fresh per-set UUIDs so the new
  // row's children don't collide with the source on the UNIQUE
  // (exercise_id, position) index. This matches `_duplicateExercise`'s
  // pre-existing behaviour.
  final clonedSets = source.sets
      .map((s) => s.copyWith(id: const Uuid().v4()))
      .toList(growable: false);

  return ExerciseCapture(
    id: newId,
    position: position,
    // Carry — describes WHAT the footage is.
    rawFilePath: newRawFilePath ?? source.rawFilePath,
    convertedFilePath: newConvertedFilePath,
    thumbnailPath: newThumbnailPath,
    mediaType: source.mediaType,
    conversionStatus: source.conversionStatus,
    sets: clonedSets,
    restHoldSeconds: source.restHoldSeconds,
    notes: source.notes,
    name: source.name,
    // Reset — describes WHERE the row lives.
    createdAt: DateTime.now(),
    sessionId: targetSession.id,
    // Strip — circuit membership is session-structural.
    // (Pass null implicitly by not setting it.)
    includeAudio: source.includeAudio,
    prepSeconds: source.prepSeconds,
    videoDurationMs: source.videoDurationMs,
    archiveFilePath: newArchiveFilePath,
    archivedAt: source.archivedAt,
    // Reset — cloud upload is per-id; must re-run for the new row.
    // rawArchiveUploadedAt: null (implicit).
    segmentedRawFilePath: newSegmentedRawFilePath,
    maskFilePath: newMaskFilePath,
    // Runtime-only URL fields — null on a fresh row; populated by
    // `get_plan_full` after publish.
    // lineDrawingUrl / grayscaleUrl / originalUrl: null (implicit).
    preferredTreatment: source.preferredTreatment,
    startOffsetMs: source.startOffsetMs,
    endOffsetMs: source.endOffsetMs,
    videoRepsPerLoop: source.videoRepsPerLoop,
    aspectRatio: source.aspectRatio,
    rotationQuarters: source.rotationQuarters,
    bodyFocus: source.bodyFocus,
    focusFrameOffsetMs: source.focusFrameOffsetMs,
    heroCropOffset: source.heroCropOffset,
    // Reset — variants are copied verbatim, no regen pending.
    thumbnailsDirty: false,
    // Carry — Safe Mode audit describes the event of capture and must
    // remain truthful wherever the row lands (D8).
    safeModeActive: source.safeModeActive,
    capturedInPremisesId: source.capturedInPremisesId,
    safeRawFilePath: newSafeRawFilePath,
    safeModeAlgorithmVersion: source.safeModeAlgorithmVersion,
  );
}

/// Copy a single exercise file, replacing [oldId] with [newId] in the
/// filename. Returns the new relative path, or null when the source is
/// null or doesn't exist on disk.
Future<String?> _copyExerciseFile(
  String? relativePath,
  String oldId,
  String newId,
) async {
  if (relativePath == null || relativePath.isEmpty) return null;
  final absSource = PathResolver.resolve(relativePath);
  final sourceFile = File(absSource);
  if (!sourceFile.existsSync()) return null;

  // Replace the old exercise id in the filename with the new one.
  final newRelative = relativePath.replaceAll(oldId, newId);
  final absDest = PathResolver.resolve(newRelative);

  // Ensure the destination directory exists.
  final destDir = Directory(p.dirname(absDest));
  if (!destDir.existsSync()) {
    destDir.createSync(recursive: true);
  }

  await sourceFile.copy(absDest);
  return newRelative;
}

/// Copy a thumbnail variant (e.g. `_thumb_color.jpg`) if it exists.
/// Variants live under `{docs}/thumbnails/{exerciseId}{suffix}` —
/// no relative-path stored on the model; the path is reconstructed by
/// consumers from the exercise id.
Future<void> _copyThumbnailVariant(
  String oldId,
  String newId,
  String suffix,
) async {
  final thumbDir = p.join(PathResolver.docsDir, 'thumbnails');
  final sourceFile = File(p.join(thumbDir, '$oldId$suffix'));
  if (!sourceFile.existsSync()) return;
  // Ensure the thumbnails directory exists — it normally does, but the
  // cross-session paste path could land into a brand-new session where
  // no thumbnail has ever been written.
  final destDir = Directory(thumbDir);
  if (!destDir.existsSync()) {
    destDir.createSync(recursive: true);
  }
  final destPath = p.join(thumbDir, '$newId$suffix');
  await sourceFile.copy(destPath);
}

/// Per-set deep-copy. Exposed as a top-level so unit tests can drive
/// the set-clone contract independently of file IO.
@visibleForTesting
List<ExerciseSet> cloneSetsWithFreshIds(List<ExerciseSet> sets) {
  return sets.map((s) => s.copyWith(id: const Uuid().v4())).toList(
        growable: false,
      );
}
