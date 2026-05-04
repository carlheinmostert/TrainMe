import 'package:flutter/widgets.dart';

import '../models/exercise_capture.dart';

/// Default normalised offset used when [ExerciseCapture.heroCropOffset]
/// is null (legacy / pre-migration row, or a fresh capture the
/// practitioner hasn't authored). Centres the crop on the source's
/// free axis so legacy rows render exactly as they did pre-Wave-Lobby.
const double kHeroCropDefaultOffset = 0.5;

/// Resolve a Flutter [Alignment] for `BoxFit.cover` based on the
/// practitioner-authored Wave-Lobby [ExerciseCapture.heroCropOffset]
/// and the source media's effective orientation (Wave 28
/// `aspectRatio` / `rotationQuarters`).
///
/// The free axis — the one the offset slides along — is determined by
/// the source's effective aspect ratio after any practitioner
/// rotation:
///
///   * Landscape (effective aspect >= 1) — free axis is X. The crop
///     window slides horizontally; the constrained axis (Y) hugs the
///     full short edge.
///   * Portrait (effective aspect < 1) — free axis is Y. The crop
///     window slides vertically; the constrained axis (X) hugs the
///     full short edge.
///   * Unknown aspect (`aspectRatio == null`) — falls through to
///     [Alignment.center]. Unknown orientation can't pick an axis,
///     and centred is the existing pre-Wave-Lobby render.
///
/// Math:
///   * `offset` is normalised in [0.0, 1.0].
///   * Flutter [Alignment] takes free-axis coordinates in [-1.0, 1.0]
///     where -1 = top/left edge, +1 = bottom/right edge.
///   * Mapping: `align_axis = offset * 2 - 1`.
///
/// Usage:
/// ```dart
/// Image.file(
///   file,
///   fit: BoxFit.cover,
///   alignment: heroCropAlignment(exercise),
/// );
/// ```
///
/// Returns [Alignment.center] for rest periods and any source whose
/// orientation can't be determined.
Alignment heroCropAlignment(ExerciseCapture exercise) {
  if (exercise.isRest) return Alignment.center;
  final ar = exercise.aspectRatio;
  if (ar == null) return Alignment.center;
  final offset = exercise.heroCropOffset ?? kHeroCropDefaultOffset;
  // Coerce to the legal range — defensive, in case a rogue write
  // landed an out-of-bounds value before PR 2's editor clamps it.
  final clamped = offset.clamp(0.0, 1.0);
  final axisCoord = clamped * 2.0 - 1.0;
  final isLandscape = ar >= 1.0;
  return isLandscape
      ? Alignment(axisCoord, 0.0) // free axis = X
      : Alignment(0.0, axisCoord); // free axis = Y
}
