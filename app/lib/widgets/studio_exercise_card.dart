import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config.dart';
import '../models/exercise_capture.dart';
import '../models/exercise_set.dart';
import '../models/session.dart';
import '../models/treatment.dart';
import '../services/api_client.dart';
import '../services/media_prefetch_service.dart';
import '../theme.dart';
import 'exercise_editor_sheet.dart';
import 'mini_preview.dart';

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

/// Studio Exercise Card — image-left / text-right layout (audit Changes 4 + 5).
///
/// Layout (2026-05-14 — square Hero left, text right):
///
///   ┌─────────────┬──────────────────────┐
///   │             │ Exercise Title       │
///   │ [Hero 1:1] │ 🏋  3 sets · 10 reps │
///   │       [📷] │ 📝  Notes preview…   │
///   │             │ [chips: 🎵 🎨 🫥]    │
///   └─────────────┴──────────────────────┘
///
/// The Hero area is a square (cardHeight × cardHeight) on the left
/// rendering the practitioner's per-exercise treatment / hero-frame
/// pick. The right column is the editable plan summary + notes preview
/// + optional state chips. Visually matches the lobby's image-left /
/// text-right row pattern.
///
/// A small media-type indicator (video / photo) sits in the top-right
/// corner of the Hero area as a passive cue. Rest periods don't render
/// the icon.
///
/// Tap zones:
///   * Whole card (default)        → editor sheet on Plan tab.
///   * Long-press anywhere         → replace media (image-picker).
///
/// The parent contract is unchanged:
///   * [onTap] fires on the whole-card tap (Studio screen treats it as
///     the focus / collapse signal).
///   * [onUpdate] fires on every meaningful edit inside the editor sheet.
///   * [onThumbnailTap] retained for backwards-compat — no longer wired.
///   * [onReplaceMedia] fires on a long-press (image-picker swap).
///   * [onDelete], [onDownloadOriginal] retained for parent compatibility.
class StudioExerciseCard extends StatelessWidget {
  final ExerciseCapture exercise;

  /// Parent session — passed through to the editor sheet so the
  /// chevrons + dot row can step through siblings.
  final Session session;

  /// This card's index inside `session.exercises`. The editor sheet uses
  /// it as the initial active index; the practitioner may navigate away
  /// from it inside the sheet, in which case `onUpdate` arrives keyed to
  /// the SHEET's current index (not necessarily this card's).
  final int index;

  /// Parent's expansion flag — kept for backwards compatibility with
  /// callers that wired it to drive a focus-ring effect. The new card
  /// has no inline expanded body, so this flag now only feeds the focus
  /// border.
  final bool isExpanded;
  final bool isFocused;
  final bool isInCircuit;
  final VoidCallback onTap;

  /// Called when the editor sheet emits an update. The reported index
  /// is the editor sheet's CURRENT index (which may differ from
  /// [index] once the practitioner has paged through siblings via
  /// chevrons / dot row).
  final void Function(int index, ExerciseCapture updated) onUpdate;

  /// Retained for backwards compatibility. The flood-fill layout no
  /// longer wires this — the whole card opens the editor on Plan.
  final VoidCallback onThumbnailTap;
  final VoidCallback onReplaceMedia;
  final VoidCallback onDelete;
  final VoidCallback? onDownloadOriginal;

  final ExerciseAnalyticsStats? analyticsStats;

  /// Card height — Carl's spec is 152pt. The Hero area is square
  /// (cardHeight × cardHeight) and the text column fills the
  /// remaining width.
  static const double cardHeight = 152;

  const StudioExerciseCard({
    super.key,
    required this.exercise,
    required this.session,
    required this.index,
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
        onTap: () {
          onTap();
          _openSheet(context, ExerciseEditorTab.plan);
        },
        onLongPress: onReplaceMedia,
        borderRadius: BorderRadius.circular(16),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          height: cardHeight,
          decoration: BoxDecoration(
            color: AppColors.surfaceBase,
            borderRadius: BorderRadius.circular(16),
            // Focused state = outer coral ring (boxShadow). 2px spread.
            boxShadow: showFocusedBorder
                ? const [
                    BoxShadow(
                      color: AppColors.primary,
                      blurRadius: 0,
                      spreadRadius: 2,
                    ),
                  ]
                : null,
          ),
          clipBehavior: Clip.antiAlias,
          // Image-left / text-right layout. Square Hero area
          // (cardHeight × cardHeight) on the left; the rest of the
          // row is the editable plan summary + chips + notes preview.
          // Mirrors the lobby's image-left card pattern.
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // -----------------------------------------------------
              // LEFT — 1:1 square Hero area
              // -----------------------------------------------------
              SizedBox(
                width: cardHeight,
                height: cardHeight,
                child: MiniPreview(
                  exercise: exercise,
                  width: double.infinity,
                  borderRadius: BorderRadius.zero,
                  staticHero: true,
                ),
              ),
              // -----------------------------------------------------
              // RIGHT — text column with corner media-type badge
              // -----------------------------------------------------
              Expanded(
                child: Stack(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                      child: _CardTextColumn(
                        exercise: exercise,
                        title: _resolvedTitle(),
                      ),
                    ),
                    // Media-type indicator (was Change 5, moved
                    // 2026-05-14 — Carl's QA: badge now floats in
                    // the top-left corner of the text column rather
                    // than overlaying the Hero image). Passive,
                    // non-interactive. Suppressed for rest periods.
                    if (!exercise.isRest)
                      Positioned(
                        top: 6,
                        left: 6,
                        child: IgnorePointer(
                          child: _MediaTypeBadge(
                            mediaType: exercise.mediaType,
                          ),
                        ),
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
      session: session,
      initialExerciseIndex: index,
      onExerciseChanged: onUpdate,
      initialTab: initialTab,
    );
  }
}

// =============================================================================
// Helpers
// =============================================================================

/// Right-column text content for the image-left card layout.
///
/// Densities top-to-bottom:
///   * Title (Montserrat 17pt / w700)
///   * Plan summary row (mono — sets × reps × hold + per-set breakdown)
///   * Rest period chip — only for rest exercises (sage tint)
///   * Notes preview — first line, dimmed
///   * State chips strip — audio, treatment, body-focus when set
///
/// Anything that doesn't fit collapses to icon-only via [_IconChip].
class _CardTextColumn extends StatelessWidget {
  final ExerciseCapture exercise;
  final String title;

  const _CardTextColumn({
    required this.exercise,
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    final isRest = exercise.isRest;
    final notes = (exercise.notes ?? '').trim();
    final summary = _planSummary(exercise);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (exerciseHasMissingMedia(exercise)) ...[
          _MediaStatusBanner(exerciseId: exercise.id),
          const SizedBox(height: 6),
        ],
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontFamily: 'Montserrat',
            fontWeight: FontWeight.w700,
            fontSize: 17,
            letterSpacing: -0.2,
            color: AppColors.textOnDark,
          ),
        ),
        const SizedBox(height: 4),
        _SummaryRow(
          icon: Icons.fitness_center,
          text: summary,
          monospace: true,
        ),
        if (!isRest && notes.isNotEmpty) ...[
          const SizedBox(height: 2),
          _SummaryRow(
            icon: Icons.notes_outlined,
            text: notes.split('\n').first,
            monospace: false,
          ),
        ],
        if (!isRest) ...[
          const SizedBox(height: 6),
          _StateChipStrip(exercise: exercise),
        ],
      ],
    );
  }
}

/// Compact icon strip for per-exercise state cues (audio, treatment,
/// body focus). Only the active states render — an exercise with no
/// non-default state renders an empty SizedBox.shrink. Layout is a
/// `Wrap` so chips fold to a second line on cramped widths; in
/// practice the card height keeps them on one row.
class _StateChipStrip extends StatelessWidget {
  final ExerciseCapture exercise;

  const _StateChipStrip({required this.exercise});

  @override
  Widget build(BuildContext context) {
    final chips = <Widget>[];
    if (exercise.includeAudio) {
      chips.add(const _IconChip(
        icon: Icons.volume_up_outlined,
        tooltip: 'Audio enabled',
      ));
    }
    final treatment = exercise.preferredTreatment;
    if (treatment != null) {
      chips.add(_IconChip(
        icon: _treatmentIcon(treatment),
        tooltip: _treatmentLabel(treatment),
      ));
    }
    final bodyFocus = exercise.bodyFocus;
    if (bodyFocus != null) {
      chips.add(_IconChip(
        icon: bodyFocus
            ? Icons.center_focus_strong_outlined
            : Icons.center_focus_weak_outlined,
        tooltip: bodyFocus ? 'Body focus on' : 'Body focus off',
      ));
    }
    if (chips.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: chips,
    );
  }

  IconData _treatmentIcon(Treatment t) {
    switch (t) {
      case Treatment.line:
        return Icons.brush_outlined;
      case Treatment.grayscale:
        return Icons.gradient_outlined;
      case Treatment.original:
        return Icons.palette_outlined;
    }
  }

  String _treatmentLabel(Treatment t) {
    switch (t) {
      case Treatment.line:
        return 'Line treatment';
      case Treatment.grayscale:
        return 'B&W treatment';
      case Treatment.original:
        return 'Original treatment';
    }
  }
}

/// Tiny 18×18 icon-only chip. Used by the state-strip when room
/// is tight (per the brief: "compress to icon-only if needed to fit").
class _IconChip extends StatelessWidget {
  final IconData icon;
  final String tooltip;

  const _IconChip({required this.icon, required this.tooltip});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Container(
        padding: const EdgeInsets.all(5),
        decoration: BoxDecoration(
          color: AppColors.surfaceRaised,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          icon,
          size: 18,
          color: AppColors.textSecondaryOnDark,
        ),
      ),
    );
  }
}

/// Passive media-type indicator overlaying the top-right corner of
/// the Hero area (audit Change 5). White-on-dark; subtle drop shadow
/// so the glyph reads against bright video frames. Sized 14pt with
/// a 22×22 padded container so the touch-target-look-alike doesn't
/// distract.
class _MediaTypeBadge extends StatelessWidget {
  final MediaType mediaType;

  const _MediaTypeBadge({required this.mediaType});

  @override
  Widget build(BuildContext context) {
    final icon = mediaType == MediaType.photo
        ? Icons.photo_camera_outlined
        : Icons.videocam_outlined;
    return SizedBox(
      width: 33,
      height: 33,
      child: Icon(
        icon,
        size: 21,
        color: Colors.white,
        shadows: const [
          Shadow(
            color: Color(0x99000000),
            offset: Offset(0, 1),
            blurRadius: 2,
          ),
        ],
      ),
    );
  }
}

/// Summary row — 14pt icon + 12pt text on the surface base. Mono-
/// spaced when [monospace] is true (plan grammar lines up).
class _SummaryRow extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool monospace;

  const _SummaryRow({
    required this.icon,
    required this.text,
    required this.monospace,
  });

  @override
  Widget build(BuildContext context) {
    final visible = text.isEmpty ? '—' : text;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            icon,
            size: 14,
            color: AppColors.textSecondaryOnDark,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              visible,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: monospace ? 'JetBrainsMono' : 'Inter',
                fontSize: 12,
                fontWeight: monospace ? FontWeight.w700 : FontWeight.w500,
                color: AppColors.textOnDark,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Live banner that flips between "downloading…" (while
/// [MediaPrefetchService] is pulling the line-drawing file from the
/// public media bucket on Studio session-open) and the canonical
/// "Media missing — long-press to recapture" red chip when no
/// download is in flight or the download failed. Showing the banner
/// at all is gated by `exerciseHasMissingMedia` upstream — if the
/// local file is on disk, we never render either state.
class _MediaStatusBanner extends StatelessWidget {
  const _MediaStatusBanner({required this.exerciseId});

  final String exerciseId;

  @override
  Widget build(BuildContext context) {
    final notifier = MediaPrefetchService.instance.statusFor(exerciseId);
    return ValueListenableBuilder<MediaPrefetchStatus>(
      valueListenable: notifier,
      builder: (context, status, _) {
        if (status == MediaPrefetchStatus.downloading) {
          return const _DownloadingChip();
        }
        // idle / failed / done all fall back to the missing chip — done
        // is transient (Studio re-reads SQLite immediately after, which
        // flips `exerciseHasMissingMedia` false and unmounts this widget).
        return const _MissingMediaChip();
      },
    );
  }
}

/// Red chip — original missing-media affordance. Practitioner long-
/// presses the card to re-capture.
class _MissingMediaChip extends StatelessWidget {
  const _MissingMediaChip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.error.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.warning_amber_rounded, size: 14, color: Colors.white),
          SizedBox(width: 6),
          Flexible(
            child: Text(
              'Media missing — long-press to recapture',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Colors.white,
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

/// Coral chip — line-drawing file is being pulled from the public
/// media bucket. Spinner + "downloading" copy. No tap target; the
/// download settles to either `Media missing` (failed) or vanishes
/// (Studio re-reads SQLite once the file lands).
class _DownloadingChip extends StatelessWidget {
  const _DownloadingChip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
            ),
          ),
          SizedBox(width: 8),
          Flexible(
            child: Text(
              'Downloading line drawing…',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Colors.white,
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

/// Build the Plan summary string. Mirrors the web-player canonical
/// decoded grammar (web-player/app.js buildDecodedGrammar) with full
/// words on the practitioner surface:
///   Uniform:   `3 sets · 10 reps · @ 15 kg · 5s hold`
///   Pyramid:   `8/10/12 reps · @ 12.5/15/17.5 kg · 5s hold`
///   Bodyweight: `3 sets · 10 reps · 30s hold`
///   Rest:      `Rest · 30s`
String _planSummary(ExerciseCapture exercise) {
  if (exercise.isRest) {
    final secs = exercise.restHoldSeconds ?? StudioDefaults.restSeconds;
    return 'Rest · ${secs}s';
  }
  final sets = exercise.sets;
  if (sets.isEmpty) return 'No sets yet';

  final repsAll = sets.map((s) => s.reps).toList();
  final holdAll = sets.map((s) => s.holdSeconds).toList();
  final weightAll = sets.map((s) => s.weightKg).toList();

  final repsUniform = repsAll.toSet().length == 1;
  final holdUniform = holdAll.toSet().length == 1;
  final weightUniform = weightAll.toSet().length == 1;
  final allBodyweight = weightAll.every((w) => w == null);

  final parts = <String>[];

  if (repsUniform) {
    parts.add('${sets.length} sets');
    parts.add('${repsAll.first} reps');
  } else {
    parts.add('${repsAll.join('/')} reps');
  }

  if (!allBodyweight) {
    if (weightUniform && weightAll.first != null) {
      parts.add('@ ${_formatKg(weightAll.first!)} kg');
    } else {
      final formatted = weightAll
          .map((w) => w == null ? 'BW' : _formatKg(w))
          .join('/');
      parts.add('@ $formatted kg');
    }
  }

  if (holdAll.any((h) => h > 0)) {
    if (holdUniform) {
      parts.add('${holdAll.first}s hold');
    } else {
      parts.add('${holdAll.join('/')}s hold');
    }
  }

  return parts.join(' · ');
}

String _formatKg(double kg) {
  if (kg == kg.roundToDouble()) {
    return kg.toStringAsFixed(0);
  }
  return kg.toStringAsFixed(1);
}
