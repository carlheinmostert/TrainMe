import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config.dart';
import '../models/exercise_capture.dart';
import '../models/exercise_set.dart';
import '../services/api_client.dart';
import '../theme.dart';
import 'exercise_editor_sheet.dart';

/// Matches [UploadService] file pre-flight: converted path first, then raw.
bool exerciseHasMissingMedia(ExerciseCapture exercise) {
  if (exercise.isRest) return false;
  final path =
      exercise.absoluteConvertedFilePath ?? exercise.absoluteRawFilePath;
  return path.isEmpty || !File(path).existsSync();
}

/// Removes [index] and reindexes `position` for UI + SQLite consistency.
List<ExerciseCapture> reindexAfterRemove(
  List<ExerciseCapture> exercises,
  int index,
) {
  final next = List<ExerciseCapture>.from(exercises);
  next.removeAt(index);
  for (var i = 0; i < next.length; i++) {
    next[i] = next[i].copyWith(position: i);
  }
  return next;
}

/// Studio defaults — the global seed values for non-set persistence
/// fields. Per-set values (reps, hold, weight, breather) live on
/// [ExerciseSet]; this surface only carries the metadata that's still
/// per-exercise (rest duration, prep seconds, video reps per loop).
class StudioDefaults {
  StudioDefaults._();

  /// Default rest duration in seconds for auto-inserted rest periods.
  static const int restSeconds = AppConfig.defaultRestDuration;

  /// Wave 24 — number of repetitions captured in the source video.
  static const int videoRepsPerLoop = 3;

  /// Prep-countdown runway in seconds (Wave 3 / Milestone P).
  static const int prepSeconds = 5;
}

/// Returns true when [exercise] has any setting that deviates from the
/// global seed. Wires the small coral indicator dot on the gear icon.
bool exerciseIsCustomised(ExerciseCapture exercise) {
  if (exercise.isRest) {
    return (exercise.restHoldSeconds ?? StudioDefaults.restSeconds) !=
        StudioDefaults.restSeconds;
  }
  if ((exercise.notes ?? '').trim().isNotEmpty) return true;
  if (exercise.includeAudio) return true;
  if (exercise.prepSeconds != null &&
      exercise.prepSeconds != StudioDefaults.prepSeconds) {
    return true;
  }
  if (exercise.mediaType == MediaType.video &&
      exercise.videoRepsPerLoop != null &&
      exercise.videoRepsPerLoop != StudioDefaults.videoRepsPerLoop) {
    return true;
  }
  return false;
}

/// Compact Studio Exercise Card — one row per non-rest exercise.
///
/// Layout (mockup `docs/design/mockups/exercise-card-v2.html` states 1-5):
///
///   [thumb 72×72] [title]                         [gear]
///                 [Dose · summary] [Notes · …]
///
/// Tapping the thumbnail opens the editor sheet on the Preview tab.
/// Tapping the Dose button opens it on the Dose tab. Tapping the Notes
/// button opens it on the Notes tab. Tapping the gear opens it on the
/// Settings tab.
///
/// The parent contract is unchanged from the previous stub:
///   * [onTap] fires on the title-area tap (the Studio screen treats it
///     as the focus / collapse signal — though the card no longer has
///     an inline expanded body, the callback stays wired so the parent
///     can keep its `_expandedIndex`/`_focusedExerciseId` state coherent).
///   * [onUpdate] fires on every meaningful edit inside the editor sheet.
///   * [onThumbnailTap] fires on the thumbnail tap. The Studio screen
///     historically pushed `MediaViewerBody` here; in the new flow we
///     ALSO open the editor sheet on the Preview tab so embedded preview
///     stays consistent. The legacy callback is still surfaced so
///     callers can opt-in to a full-screen route via long-press if
///     desired (not currently wired).
///   * [onReplaceMedia] fires on a long-press of the thumbnail (replace
///     media via image-picker — same pattern as before).
///   * [onDelete], [onDownloadOriginal] retained for parent compatibility
///     even though the swipe-delete primary path is on the parent
///     `Dismissible` (deletion is owned by the parent, not the card).
class StudioExerciseCard extends StatelessWidget {
  final ExerciseCapture exercise;

  /// Parent's expansion flag — kept for backwards compatibility with
  /// callers that wired it to drive a focus-ring effect. The new card
  /// has no inline expanded body, so this flag now only feeds the focus
  /// border.
  final bool isExpanded;
  final bool isFocused;
  final bool isInCircuit;
  final VoidCallback onTap;
  final ValueChanged<ExerciseCapture> onUpdate;
  final VoidCallback onThumbnailTap;
  final VoidCallback onReplaceMedia;
  final VoidCallback onDelete;
  final VoidCallback? onDownloadOriginal;

  final ExerciseAnalyticsStats? analyticsStats;

  const StudioExerciseCard({
    super.key,
    required this.exercise,
    required this.isExpanded,
    this.isFocused = false,
    this.isInCircuit = false,
    required this.onTap,
    required this.onUpdate,
    required this.onThumbnailTap,
    required this.onReplaceMedia,
    required this.onDelete,
    this.onDownloadOriginal,
    this.analyticsStats,
  });

  @override
  Widget build(BuildContext context) {
    final showFocusedBorder = isFocused || isExpanded;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.surfaceBase,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: showFocusedBorder
                  ? AppColors.primary
                  : AppColors.surfaceBorder,
              width: showFocusedBorder ? 2 : 1,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Thumbnail(
                exercise: exercise,
                onTap: () => _openSheet(context, ExerciseEditorTab.preview),
                onLongPress: onReplaceMedia,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (exerciseHasMissingMedia(exercise)) ...[
                      const _MissingMediaBanner(),
                      const SizedBox(height: 8),
                    ],
                    _TitleRow(
                      title: _resolvedTitle(),
                      isCustomised: exerciseIsCustomised(exercise),
                      onGearTap: () =>
                          _openSheet(context, ExerciseEditorTab.settings),
                    ),
                    const SizedBox(height: 10),
                    _TriggerRow(
                      doseSummary: _doseSummary(exercise),
                      notesSummary: _notesSummary(exercise),
                      onDoseTap: () =>
                          _openSheet(context, ExerciseEditorTab.dose),
                      onNotesTap: () =>
                          _openSheet(context, ExerciseEditorTab.notes),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _resolvedTitle() {
    final n = exercise.name?.trim();
    if (n != null && n.isNotEmpty) return n;
    return 'Exercise ${exercise.position + 1}';
  }

  Future<void> _openSheet(
    BuildContext context,
    ExerciseEditorTab initialTab,
  ) async {
    HapticFeedback.selectionClick();
    await showExerciseEditorSheet(
      context: context,
      exercise: exercise,
      onChanged: onUpdate,
      initialTab: initialTab,
    );
  }
}

// =============================================================================
// Helpers
// =============================================================================

class _Thumbnail extends StatelessWidget {
  final ExerciseCapture exercise;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _Thumbnail({
    required this.exercise,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final String? thumbPath = exercise.absoluteThumbnailPath;
    final hasThumb = thumbPath != null && File(thumbPath).existsSync();
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(
          color: AppColors.surfaceRaised,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.surfaceBorder, width: 1),
          gradient: hasThumb
              ? null
              : const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color(0xFF2A2D3A),
                    Color(0xFF1A1D27),
                  ],
                ),
          image: hasThumb
              ? DecorationImage(
                  image: FileImage(File(thumbPath)),
                  fit: BoxFit.cover,
                )
              : null,
        ),
        child: Stack(
          children: [
            if (exercise.mediaType == MediaType.video)
              const Center(
                child: _PlayGlyph(),
              ),
            if (exercise.mediaType == MediaType.photo && !hasThumb)
              const Center(
                child: Icon(
                  Icons.photo_outlined,
                  size: 24,
                  color: AppColors.textSecondaryOnDark,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PlayGlyph extends StatelessWidget {
  const _PlayGlyph();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.72),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: const Padding(
        padding: EdgeInsets.only(left: 2),
        child: Icon(
          Icons.play_arrow_rounded,
          size: 16,
          color: AppColors.textOnDark,
        ),
      ),
    );
  }
}

class _TitleRow extends StatelessWidget {
  final String title;
  final bool isCustomised;
  final VoidCallback onGearTap;

  const _TitleRow({
    required this.title,
    required this.isCustomised,
    required this.onGearTap,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: 'Montserrat',
              fontSize: 16,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
              color: AppColors.textOnDark,
            ),
          ),
        ),
        const SizedBox(width: 8),
        InkWell(
          onTap: onGearTap,
          borderRadius: BorderRadius.circular(14),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                child: Icon(
                  Icons.settings_rounded,
                  size: 22,
                  color: isCustomised
                      ? AppColors.primary
                      : AppColors.textSecondaryOnDark,
                ),
              ),
              if (isCustomised)
                const Positioned(
                  top: 4,
                  right: 4,
                  child: _CoralDot(),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CoralDot extends StatelessWidget {
  const _CoralDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(
        color: AppColors.primary,
        shape: BoxShape.circle,
        border: Border.all(color: AppColors.surfaceBase, width: 1.5),
      ),
    );
  }
}

class _TriggerRow extends StatelessWidget {
  final String doseSummary;
  final String? notesSummary;
  final VoidCallback onDoseTap;
  final VoidCallback onNotesTap;

  const _TriggerRow({
    required this.doseSummary,
    required this.notesSummary,
    required this.onDoseTap,
    required this.onNotesTap,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _TriggerButton(
            label: 'Dose',
            summary: doseSummary,
            summaryStyle: const TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: AppColors.textSecondaryOnDark,
            ),
            onTap: onDoseTap,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _TriggerButton(
            label: 'Notes',
            summary: notesSummary ?? 'Add notes…',
            summaryStyle: TextStyle(
              fontFamily: 'Inter',
              fontSize: 12,
              fontWeight: FontWeight.w500,
              fontStyle: notesSummary == null
                  ? FontStyle.normal
                  : FontStyle.italic,
              color: notesSummary == null
                  ? AppColors.textSecondaryOnDark
                  : AppColors.textSecondaryOnDark,
            ),
            onTap: onNotesTap,
          ),
        ),
      ],
    );
  }
}

class _TriggerButton extends StatelessWidget {
  final String label;
  final String summary;
  final TextStyle summaryStyle;
  final VoidCallback onTap;

  const _TriggerButton({
    required this.label,
    required this.summary,
    required this.summaryStyle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.surfaceRaised,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.surfaceBorder, width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textOnDark,
                  letterSpacing: -0.05,
                ),
              ),
              const SizedBox(width: 6),
              const Text(
                '·',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 13,
                  color: AppColors.textSecondaryOnDark,
                ),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  summary,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: summaryStyle,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Banner when line-drawing or raw file is missing (publish pre-flight matches).
class _MissingMediaBanner extends StatelessWidget {
  const _MissingMediaBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.error.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: AppColors.error.withValues(alpha: 0.45),
          width: 1,
        ),
      ),
      child: const Row(
        children: [
          Icon(
            Icons.warning_amber_rounded,
            size: 14,
            color: AppColors.error,
          ),
          SizedBox(width: 6),
          Expanded(
            child: Text(
              'Media missing — long-press to delete and recapture',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.error,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Summary builders
// =============================================================================

/// Build the Dose summary string. Uniform sets collapse to "N × R"
/// (optionally `@ kg`); pyramid sets fan out via slashes.
String _doseSummary(ExerciseCapture exercise) {
  if (exercise.isRest) {
    final secs = exercise.restHoldSeconds ?? StudioDefaults.restSeconds;
    return 'Rest · ${secs}s';
  }
  final sets = exercise.sets;
  if (sets.isEmpty) return 'No sets yet';

  final repsAll = sets.map((s) => s.reps).toList();
  final holdAll = sets.map((s) => s.holdSeconds).toList();
  final weightAll = sets.map((s) => s.weightKg).toList();
  final breatherAll = sets.map((s) => s.breatherSecondsAfter).toList();

  final repsUniform = repsAll.toSet().length == 1;
  final holdUniform = holdAll.toSet().length == 1;
  final weightUniform = weightAll.toSet().length == 1;
  final breatherUniform = breatherAll.toSet().length == 1;

  final parts = <String>[];

  // Reps + sets clause.
  if (repsUniform) {
    parts.add('${sets.length} × ${repsAll.first}');
  } else {
    parts.add(repsAll.join('/'));
  }

  // Weight clause — only render when at least one set has a weight.
  final allBodyweight = weightAll.every((w) => w == null);
  if (!allBodyweight) {
    if (weightUniform && weightAll.first != null) {
      parts.add('@ ${_formatKg(weightAll.first!)} kg');
    } else {
      final formatted = weightAll
          .map((w) => w == null ? '—' : _formatKg(w))
          .join('/');
      parts.add('@ $formatted kg');
    }
  } else {
    parts.add('bodyweight');
  }

  // Hold clause — surface only when any set has a hold.
  if (holdAll.any((h) => h > 0)) {
    if (holdUniform) {
      parts.add('${holdAll.first} s hold');
    } else {
      parts.add('${holdAll.join('/')} s hold');
    }
  }

  // Breather clause — only when uniform AND non-default-ish, or when
  // varied. Skip if every set has 60 s after to keep summary lean.
  if (!breatherUniform) {
    parts.add('${breatherAll.join('/')} s rest');
  } else if (breatherAll.first != 60) {
    parts.add('${breatherAll.first} s rest');
  }

  return parts.join(' · ');
}

String _formatKg(double kg) {
  if (kg == kg.roundToDouble()) {
    return kg.toStringAsFixed(0);
  }
  return kg.toStringAsFixed(1);
}

/// Returns the truncated notes summary, or null when notes are empty.
String? _notesSummary(ExerciseCapture exercise) {
  final notes = exercise.notes?.trim();
  if (notes == null || notes.isEmpty) return null;
  if (notes.length <= 50) return '"$notes"';
  return '"${notes.substring(0, 50).trimRight()}…"';
}
