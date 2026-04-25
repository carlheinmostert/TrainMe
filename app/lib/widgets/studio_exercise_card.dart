import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config.dart';
import '../models/exercise_capture.dart';
import '../models/treatment.dart';
import '../theme.dart';
import '../theme/motion.dart';
import 'inline_editable_text.dart';
import 'preset_chip_row.dart';
import 'thumbnail_peek.dart';

/// Seed defaults a new exercise card lands with. MVP uses the R-04
/// global defaults (reps 10, sets 3, hold 0s, rest 30s, notes empty,
/// audio off, custom-duration absent). Client-history and
/// practitioner-last-used seeds are deferred.
class StudioDefaults {
  StudioDefaults._();
  static const int reps = 10;
  static const int sets = 3;
  static const int holdSeconds = 0;
  static const int restSeconds = AppConfig.defaultRestDuration;

  /// Wave 24 — number of repetitions captured in the source video. Mirror
  /// of `ExerciseCapture.withPersistenceDefaults()` which seeds 3 on every
  /// fresh video / isometric capture. The PACING accordion's REPS IN VIDEO
  /// row falls back to this when `exercise.videoRepsPerLoop` is null
  /// (legacy / pre-Wave-24 row).
  static const int videoRepsPerLoop = 3;

  /// Prep-countdown runway in seconds (Wave 3 / Milestone P). The mobile
  /// preview + web player both default to this when `exercise.prepSeconds`
  /// is null. Practitioners can override per exercise via the "Prep
  /// seconds" inline field on the Studio card. Keep in lockstep with
  /// `_kPrepSeconds` in plan_preview_screen.dart and `PREP_SECONDS` in
  /// web-player/app.js.
  static const int prepSeconds = 5;

  /// Post Rep Breather — inter-set rest in seconds (Milestone Q). This is
  /// the seed the Studio UI shows when `exercise.interSetRestSeconds` is
  /// null AND no sticky per-client default exists. Fresh captures are
  /// persisted with 15s at write-boundary via
  /// `ExerciseCapture.withPersistenceDefaults()`; legacy rows stay NULL
  /// (no breather) until the practitioner explicitly sets one.
  static const int interSetRestSeconds = 15;
}

/// Returns true when [exercise] has any setting that deviates from the
/// global seed — i.e. the practitioner has curated it. Drives the 4px
/// coral "customised" dot on the card border (R-05).
bool exerciseIsCustomised(ExerciseCapture exercise) {
  if (exercise.isRest) {
    return (exercise.holdSeconds ?? StudioDefaults.restSeconds) !=
        StudioDefaults.restSeconds;
  }
  if ((exercise.reps ?? StudioDefaults.reps) != StudioDefaults.reps) return true;
  if ((exercise.sets ?? StudioDefaults.sets) != StudioDefaults.sets) return true;
  if ((exercise.holdSeconds ?? StudioDefaults.holdSeconds) !=
      StudioDefaults.holdSeconds) {
    return true;
  }
  if ((exercise.notes ?? '').isNotEmpty) return true;
  if (exercise.includeAudio) return true;
  // Wave 24 — UI no longer exposes customDurationSeconds, but a legacy
  // row carrying a manual override should still light the customised
  // dot so the practitioner sees it differs from the surrounding
  // defaults. Removing the row from the editor doesn't erase the data.
  if (exercise.customDurationSeconds != null) return true;
  if (exercise.prepSeconds != null) return true;
  // Milestone Q — inter-set rest counts as customised when the stored
  // value differs from the persistence default (15s). Null stays
  // non-customised (legacy rows / pre-migration captures).
  if (exercise.interSetRestSeconds != null &&
      exercise.interSetRestSeconds != StudioDefaults.interSetRestSeconds) {
    return true;
  }
  // Wave 24 — same convention as inter-set rest. Null = legacy /
  // photo / rest (not customised); a value matching the default 3
  // = freshly seeded (not customised); any other value = practitioner
  // has set a non-default rep count.
  if (exercise.videoRepsPerLoop != null &&
      exercise.videoRepsPerLoop != StudioDefaults.videoRepsPerLoop) {
    return true;
  }
  return false;
}

/// Studio Exercise Card — redesign per `docs/design/project/components.md`
/// §Exercise Card. Flat; border hairlines; 56×56 thumbnail as its own
/// gesture zone; no chevron; whole row is the tap target; header purity
/// (R-02).
class StudioExerciseCard extends StatefulWidget {
  final ExerciseCapture exercise;
  final bool isExpanded;
  final bool isInCircuit;

  /// Tap anywhere on the card row (except the thumbnail) → toggle expand.
  final VoidCallback onTap;

  /// Fired when the card persistable fields change (reps, sets, hold, notes,
  /// audio, custom-duration).
  final ValueChanged<ExerciseCapture> onUpdate;

  /// Thumbnail tap → full-screen viewer.
  final VoidCallback onThumbnailTap;

  /// Thumbnail long-press → Thumbnail Peek → "Replace media" action.
  final VoidCallback onReplaceMedia;

  /// Thumbnail long-press → "Delete exercise" action. Immediate;
  /// caller surfaces the undo snackbar.
  final VoidCallback onDelete;

  /// Thumbnail long-press → "Download original" action (video captures
  /// only). Caller is expected to call `showDownloadOriginalSheet(...)`
  /// with the plan's practice + plan ids. Null (default) disables the
  /// row so the peek menu keeps its legacy three-action shape.
  final VoidCallback? onDownloadOriginal;

  /// Optional sticky per-rep seed for DURATION PER REP's Manual seed
  /// path (Wave 18.7). Parent looks up the client's
  /// `custom_duration_per_rep` default and passes it through; null
  /// means "no sticky default, fall back to 5s".
  final int? stickyCustomDurationPerRep;

  const StudioExerciseCard({
    super.key,
    required this.exercise,
    required this.isExpanded,
    this.isInCircuit = false,
    required this.onTap,
    required this.onUpdate,
    required this.onThumbnailTap,
    required this.onReplaceMedia,
    required this.onDelete,
    this.onDownloadOriginal,
    this.stickyCustomDurationPerRep,
  });

  @override
  State<StudioExerciseCard> createState() => _StudioExerciseCardState();
}

/// Which of the three accordion-grouped sections is currently expanded.
/// At most one at a time — opening another closes the first. All three
/// can end up closed if the practitioner taps the open one. Wave 29
/// retired PLAYBACK from the accordion: treatment + audio are wholly
/// owned by `_MediaViewer` now, and the card surfaces them via a live
/// caption directly below the thumbnail (which doubles as the
/// invitation to open the viewer). Two surfaces for one setting was
/// pure duplication.
enum _AccordionGroup { dose, pacing, notes }

class _StudioExerciseCardState extends State<StudioExerciseCard> {
  late int _reps;
  late int _sets;
  late int _hold;
  late TextEditingController _notesController;

  /// Single-open accordion for DOSE / PACING / NOTES. Null = all three
  /// closed (the default on every card open, per Wave 18.2). Opening
  /// one group closes the previously-open group; tapping the open
  /// group closes it (null again). PLAYBACK retired in Wave 29.
  _AccordionGroup? _openGroup;

  @override
  void initState() {
    super.initState();
    _syncFromModel(widget.exercise);
    _notesController =
        TextEditingController(text: widget.exercise.notes ?? '');
  }

  @override
  void didUpdateWidget(covariant StudioExerciseCard old) {
    super.didUpdateWidget(old);
    if (old.exercise.id != widget.exercise.id) {
      _syncFromModel(widget.exercise);
      _notesController.text = widget.exercise.notes ?? '';
      _openGroup = null;
    } else {
      // Same exercise, same open state — but the parent may have
      // written through a change (treatment pref, includeAudio, etc).
      // Re-seed the local numeric mirrors so the chip rows render the
      // latest value instead of a stale tap.
      _syncFromModel(widget.exercise);
      final nextNotes = widget.exercise.notes ?? '';
      if (_notesController.text != nextNotes) {
        _notesController.text = nextNotes;
      }
    }
    if (old.isExpanded && !widget.isExpanded) {
      // Card just closed — drop accordion state so a re-open lands on
      // the spec default (all four groups closed, per Wave 18.2).
      _openGroup = null;
    }
  }

  void _toggleAccordion(_AccordionGroup group) {
    HapticFeedback.selectionClick();
    setState(() {
      _openGroup = (_openGroup == group) ? null : group;
    });
  }

  void _syncFromModel(ExerciseCapture ex) {
    _reps = ex.reps ?? StudioDefaults.reps;
    _sets = ex.sets ?? StudioDefaults.sets;
    _hold = ex.holdSeconds ?? StudioDefaults.holdSeconds;
  }

  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  void _pushReps(num value) {
    final newReps = value.round();
    final currentCustom = widget.exercise.customDurationSeconds;
    int? nextCustom = currentCustom;
    if (currentCustom != null) {
      final oldReps = widget.exercise.reps ?? StudioDefaults.reps;
      if (oldReps > 0) {
        final perRep = (currentCustom / oldReps).round();
        nextCustom = perRep * newReps;
      }
    }
    setState(() => _reps = newReps);
    widget.onUpdate(widget.exercise.copyWith(
      reps: newReps,
      customDurationSeconds: nextCustom,
    ));
  }

  void _pushSets(num value) {
    final n = value.round();
    setState(() => _sets = n);
    widget.onUpdate(widget.exercise.copyWith(sets: n));
  }

  void _pushHold(num value) {
    final n = value.round();
    setState(() => _hold = n);
    widget.onUpdate(widget.exercise.copyWith(holdSeconds: n));
  }

  void _pushNotes() {
    widget.onUpdate(widget.exercise.copyWith(
      notes:
          _notesController.text.isEmpty ? null : _notesController.text,
    ));
  }

  String get _displayName =>
      widget.exercise.name ??
      'Exercise ${widget.exercise.position + 1}';

  String _buildSummary() {
    // Always show values — defaults read as starting points, not empty
    // states (R-04). Reps × sets · rest Ns pattern; skip sets inside
    // circuits (cycles replace them).
    final parts = <String>[];
    if (widget.isInCircuit) {
      parts.add('$_reps reps');
    } else {
      parts.add('$_sets × $_reps');
    }
    if (_hold > 0) parts.add('${_hold}s hold');
    final dur = widget.exercise.effectiveDurationSeconds;
    // Wave 18.5 — "Custom" copy retired. A set customDurationSeconds
    // now uniquely means the practitioner chose Manual in PACING; we
    // tag it "manual" so the card summary stays distinguishable from
    // the auto-calculated "~Xs" estimate.
    final isManual = widget.exercise.customDurationSeconds != null;
    parts.add(isManual
        ? '${_formatSecs(dur)} manual'
        : '~${_formatSecs(dur)}');
    return parts.join(' · ');
  }

  static String _formatSecs(int seconds) {
    if (seconds < 60) return '${seconds}s';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    if (s == 0) return '${m}m';
    return '${m}m${s}s';
  }

  @override
  Widget build(BuildContext context) {
    final customised = exerciseIsCustomised(widget.exercise);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          widget.onTap();
        },
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: AppMotion.fast,
          curve: AppMotion.standard,
          decoration: BoxDecoration(
            color: AppColors.surfaceBase,
            borderRadius: BorderRadius.circular(12),
            // Expanded card carries a coral perimeter — a quiet signal
            // that this is the card currently being edited (item 32).
            // AnimatedContainer tweens width + color in AppMotion.fast.
            border: Border.all(
              color: widget.isExpanded
                  ? AppColors.primary
                  : AppColors.surfaceBorder,
              width: widget.isExpanded ? 2 : 1,
            ),
          ),
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  // mainAxisSize.min so the card hugs its content. Without
                  // this, the card lives inside an Expanded inside a
                  // sliver itemBuilder with unbounded main-axis height;
                  // Column.max then expands to viewport height, which
                  // cascades into the list blow-out symptom.
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildHeader(),
                    if (widget.isExpanded) ...[
                      const SizedBox(height: 12),
                      const Divider(
                        height: 1,
                        color: AppColors.surfaceBorder,
                      ),
                      const SizedBox(height: 16),
                      _buildExpandedPanel(),
                    ],
                  ],
                ),
              ),
              if (customised)
                const Positioned(
                  right: 8,
                  bottom: 8,
                  child: _CustomisedDot(),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Thumbnail owns its own gesture zone — tap opens viewer,
            // long press opens peek. Must sit OUTSIDE the card-wide
            // InkWell tap. Wave 29 — wrapped in a Stack so a small
            // coral "tune" glyph overlays the top-right corner, signalling
            // the thumbnail is the entry point to playback settings now
            // that the PLAYBACK accordion has been retired.
            Stack(
              clipBehavior: Clip.none,
              children: [
                ThumbnailPeek(
                  exercise: widget.exercise,
                  onTap: widget.onThumbnailTap,
                  onOpenFullScreen: widget.onThumbnailTap,
                  onReplaceMedia: widget.onReplaceMedia,
                  onDelete: widget.onDelete,
                  onDownloadOriginal: widget.onDownloadOriginal,
                ),
                // Edit-affordance glyph — purely visual. The thumbnail
                // itself is the tap target; the glyph is a hint, not a
                // separate gesture. 28×28 dark pill keeps the icon
                // legible against any thumbnail content.
                Positioned(
                  top: -4,
                  right: -4,
                  child: IgnorePointer(
                    child: Tooltip(
                      message: 'Adjust playback',
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: AppColors.surfaceBorder,
                            width: 1,
                          ),
                        ),
                        alignment: Alignment.center,
                        child: const Icon(
                          Icons.tune_rounded,
                          size: 14,
                          color: AppColors.primary,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  InlineEditableText(
                    initialValue: _displayName,
                    textStyle: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textOnDark,
                    ),
                    onCommit: (newName) {
                      final isDefault = newName ==
                          'Exercise ${widget.exercise.position + 1}';
                      widget.onUpdate(widget.exercise.copyWith(
                        name: isDefault ? null : newName,
                        clearName: isDefault,
                      ));
                    },
                  ),
                  const SizedBox(height: 4),
                  Text(
                    // Wave 18.2 — mixed-case kept. Reps / sets / hold
                    // read naturally ("3 reps · 1 set · 5s hold") next
                    // to the InlineEditableText name above, which is
                    // also mixed case. The ALL CAPS variant from
                    // pre-18.1 read like a label strip rather than a
                    // live stat readout.
                    _buildSummary(),
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.3,
                      color: AppColors.textSecondaryOnDark,
                    ),
                  ),
                ],
              ),
            ),
            // Wave 18 — the trailing `_StatusDot` was removed. The
            // ThumbnailPeek widget's capture_thumbnail overlays already
            // signal every conversion state (green check on done, red
            // warning on failed, centre spinner while converting), so
            // the status dot was redundant and contributed to header-
            // row visual noise. Zero information loss.
          ],
        ),
        // Wave 29 — playback caption. Replaces the retired PLAYBACK
        // accordion summary; rebuilds via setState whenever the model
        // changes (parent owns onUpdate). Tap routes to `_MediaViewer`
        // via the same callback the thumbnail already uses, so the
        // caption is a second tap-affordance for the same destination.
        // Sits below the title row (full card width) so multiple
        // tokens read as a compact line without wrapping under the
        // 56pt thumbnail column.
        Padding(
          padding: const EdgeInsets.only(top: 6, left: 68),
          child: GestureDetector(
            onTap: () {
              HapticFeedback.selectionClick();
              widget.onThumbnailTap();
            },
            behavior: HitTestBehavior.opaque,
            child: Text(
              _playbackCaption(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: AppColors.textSecondaryOnDark,
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------------
  // Non-default markers — drive the coral dot + bolded label on each
  // accordion group header. Wave 18.1 retires the auto-expand-on-non-
  // defaults rule; the marker alone signals "there's something
  // practitioner-curated in this group".
  // ------------------------------------------------------------------

  // Wave 29 — `_playbackHasNonDefaults` retired alongside the PLAYBACK
  // accordion section. Treatment + audio state now surfaces in the
  // live caption row below the thumbnail (see `_playbackCaption`),
  // and the viewer is the single source of truth for editing them.

  /// DOSE is "non-default" when reps/sets/hold differ from the app-wide
  /// seed values. Sets are ignored inside circuits (the dose summary
  /// skips them).
  bool get _doseHasNonDefaults {
    final ex = widget.exercise;
    if ((ex.reps ?? StudioDefaults.reps) != StudioDefaults.reps) return true;
    if (!widget.isInCircuit &&
        (ex.sets ?? StudioDefaults.sets) != StudioDefaults.sets) {
      return true;
    }
    if ((ex.holdSeconds ?? StudioDefaults.holdSeconds) !=
        StudioDefaults.holdSeconds) {
      return true;
    }
    return false;
  }

  /// PACING is "non-default" when prep override, REPS IN VIDEO override,
  /// inter-set rest override is set, or a legacy customDurationSeconds
  /// remains on a pre-Wave-24 row.
  bool get _pacingHasNonDefaults {
    final ex = widget.exercise;
    if (ex.prepSeconds != null) return true;
    // Wave 24 — UI no longer exposes the manual per-rep field, but a
    // legacy override on a pre-migration row should still light the
    // coral dot. The data lives on; the editor is gone.
    if (ex.customDurationSeconds != null) return true;
    // Milestone Q — inter-set rest counts as "non-default" only when it
    // differs from the persistence default (15s). A freshly-seeded 15s
    // row should NOT light the coral dot; only a deliberate deviation
    // (0 = disabled, any other positive integer) does.
    if (ex.interSetRestSeconds != null &&
        ex.interSetRestSeconds != StudioDefaults.interSetRestSeconds) {
      return true;
    }
    // Wave 24 — same convention as inter-set rest. Null = legacy /
    // photo / rest; default 3 = freshly seeded; any other value =
    // practitioner override worth flagging.
    if (ex.videoRepsPerLoop != null &&
        ex.videoRepsPerLoop != StudioDefaults.videoRepsPerLoop) {
      return true;
    }
    return false;
  }

  /// NOTES is "non-default" when the notes field has any content.
  bool get _notesHasNonDefaults => (widget.exercise.notes ?? '').isNotEmpty;

  // ------------------------------------------------------------------
  // Collapsed-row summaries — shown next to each group header when the
  // group is collapsed. Spec requires a summary for ALL four groups
  // (Wave 18.1).
  // ------------------------------------------------------------------

  /// Wave 29 — live caption rendered below the thumbnail. Replaces the
  /// retired PLAYBACK accordion summary and now also surfaces trim +
  /// rotation overrides at a glance. The caption rebuilds whenever the
  /// model changes (the card is a StatefulWidget driven by parent
  /// onUpdate). Bullet-separated tokens; treatment is always present;
  /// the rest only appear when set.
  String _playbackCaption() {
    final ex = widget.exercise;
    final parts = <String>[];

    // Treatment label — always rendered.
    final treatment = ex.preferredTreatment ?? Treatment.line;
    parts.add(treatment.shortLabel);

    // Audio state — videos only.
    if (ex.mediaType == MediaType.video) {
      parts.add(ex.includeAudio ? 'Audio on' : 'Muted');
    }

    // Trim window — only when both ends are set. Format as
    // m:ss-m:ss to read at a glance.
    if (ex.startOffsetMs != null && ex.endOffsetMs != null) {
      parts.add(
        'Trimmed ${_formatMmSs(ex.startOffsetMs!)}-'
        '${_formatMmSs(ex.endOffsetMs!)}',
      );
    }

    // Rotation override — null and 0 both mean "no rotation".
    final quarters = ex.rotationQuarters;
    if (quarters != null && quarters % 4 != 0) {
      parts.add('Rotated ${(quarters % 4) * 90}°');
    }

    return parts.join(' · ');
  }

  /// `123_456` ms → `2:03`. Used by the caption's trim segment.
  static String _formatMmSs(int ms) {
    final totalSec = (ms / 1000).round();
    final m = totalSec ~/ 60;
    final s = totalSec % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  /// DOSE collapsed summary — e.g. `10 reps · 3 sets · 5s hold`.
  /// In circuits, sets are hidden (the circuit cycles replace them).
  /// Hold of 0 renders as `Hold off`.
  String _doseSummary() {
    final parts = <String>['$_reps reps'];
    if (!widget.isInCircuit) {
      parts.add('$_sets sets');
    }
    parts.add(_hold == 0 ? 'Hold off' : '${_hold}s hold');
    return parts.join(' · ');
  }

  /// PACING collapsed summary — `defaults` or comma-separated list.
  ///
  /// Wave 24 — the manual per-rep editor is gone from the UI; the
  /// summary still surfaces a legacy `customDurationSeconds` override
  /// on pre-Wave-24 rows so the practitioner sees that the row is
  /// still being driven by the old manual value (visible signal that
  /// re-publishing will continue to honour it). REPS IN VIDEO joins
  /// the summary when it deviates from the seed of 3.
  String _pacingSummary() {
    final parts = <String>[];
    final ex = widget.exercise;
    if (ex.prepSeconds != null) parts.add('${ex.prepSeconds}s prep');
    // Wave 24 — REPS IN VIDEO surfaces in the collapsed summary only
    // when it deviates from the persistence default of 3 (matches
    // `_pacingHasNonDefaults`). A freshly-seeded 3 stays invisible.
    final videoReps = ex.videoRepsPerLoop;
    if (videoReps != null && videoReps != StudioDefaults.videoRepsPerLoop) {
      parts.add('$videoReps reps/video');
    }
    // Legacy manual per-rep override (pre-Wave-24 rows). Kept for
    // visibility — fresh captures never write this field, but the
    // summary should still show it on rows that carry one.
    if (ex.customDurationSeconds != null) {
      final perRep = _perRepFromCustom();
      parts.add('${perRep}s per rep');
    }
    // Milestone Q — surface the breather in the collapsed summary so a
    // practitioner can see it without expanding the accordion. Only
    // non-default values show up (matches `_pacingHasNonDefaults`); a
    // 15s freshly-seeded value stays invisible in the summary.
    final breather = ex.interSetRestSeconds;
    if (breather != null && breather != StudioDefaults.interSetRestSeconds) {
      if (breather == 0) {
        parts.add('no breather');
      } else {
        parts.add('${breather}s breather');
      }
    }
    if (parts.isEmpty) return 'defaults';
    return parts.join(', ');
  }

  /// NOTES collapsed summary — `empty` or the first 28 chars quoted.
  ///
  /// Wave 18.8 — collapse all whitespace (newlines, tabs, runs of
  /// spaces) to single spaces BEFORE truncating. Otherwise multi-
  /// paragraph notes would spill the collapsed summary across multiple
  /// visual lines. The NOTES `_GroupHeader` also passes
  /// `singleLineSummary: true` so the RichText forces a single line
  /// even in the collapsed state.
  String _notesSummary() {
    final raw = widget.exercise.notes ?? '';
    if (raw.isEmpty) return 'empty';
    final cleaned = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.isEmpty) return 'empty';
    final clipped =
        cleaned.length > 28 ? '${cleaned.substring(0, 28)}…' : cleaned;
    return '"$clipped"';
  }

  Widget _buildExpandedPanel() {
    // Wave 24 — `hasVideoLength` was used by the retired
    // `_DurationPerRepRow`. The new `_VideoRepsPerLoopRow` doesn't
    // need a probed video duration to render (it's a count, not a
    // time), so the variable is gone with the row.
    //
    // Wave 29 — `isVideo` + `hasArchive` previously gated the PLAYBACK
    // body. Both are gone with the section; treatment + audio now
    // live solely in `_MediaViewer`.
    //
    // `playbackOpen` retired with the PLAYBACK section.
    final doseOpen = _openGroup == _AccordionGroup.dose;
    final pacingOpen = _openGroup == _AccordionGroup.pacing;
    final notesOpen = _openGroup == _AccordionGroup.notes;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Failure banner — stays at the top of the expanded panel. It's
        // an alert, not a grouped control, so it lives OUTSIDE the
        // DOSE / PACING / NOTES sections.
        if (widget.exercise.conversionStatus == ConversionStatus.failed)
          Container(
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF3B1111),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: AppColors.error.withValues(alpha: 0.4),
              ),
            ),
            child: const Row(
              children: [
                Icon(Icons.error_outline,
                    color: Color(0xFFFCA5A5), size: 20),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Line drawing conversion failed. The original is preserved.',
                    style: TextStyle(
                      color: Color(0xFFFCA5A5),
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
          ),

        // -----------------------------------------------------------
        // DOSE — accordion member, default closed. Reps + Sets (skip
        // in circuit) + Hold. First section after the Wave 29 PLAYBACK
        // retirement; carries the `isFirst: true` flag PLAYBACK used
        // to own so the header doesn't double-pad with the card's own
        // top inset.
        // -----------------------------------------------------------
        _GroupHeader(
          label: 'Dose',
          expanded: doseOpen,
          hasNonDefaults: _doseHasNonDefaults,
          // Wave 18.3 — summary persists in BOTH states.
          summary: _doseSummary(),
          isFirst: true,
          onTap: () => _toggleAccordion(_AccordionGroup.dose),
        ),
        if (doseOpen)
          _ExpandedBody(
            children: [
              _ControlRow(
                label: 'Reps',
                value: _reps,
                displayFormat: (v) => '$v',
                child: PresetChipRow(
                  controlKey: 'reps',
                  canonicalPresets: const <num>[5, 8, 10, 12, 15],
                  currentValue: _reps,
                  onChanged: _pushReps,
                  accentColor: AppColors.primary,
                  undoLabel: 'reps',
                ),
              ),
              if (!widget.isInCircuit) ...[
                const SizedBox(height: 8),
                _ControlRow(
                  label: 'Sets',
                  value: _sets,
                  displayFormat: (v) => '$v',
                  child: PresetChipRow(
                    controlKey: 'sets',
                    canonicalPresets: const <num>[1, 2, 3, 4, 5],
                    currentValue: _sets,
                    onChanged: _pushSets,
                    accentColor: AppColors.primary,
                    undoLabel: 'sets',
                  ),
                ),
              ],
              const SizedBox(height: 8),
              _ControlRow(
                label: 'Hold',
                value: _hold,
                displayFormat: (v) => v == 0 ? 'Off' : '${v}s',
                child: PresetChipRow(
                  controlKey: 'hold',
                  canonicalPresets: const <num>[0, 5, 10, 30, 60],
                  currentValue: _hold,
                  onChanged: _pushHold,
                  accentColor: AppColors.primary,
                  displayFormat: (v) => v == 0 ? 'Off' : '${v}s',
                  undoLabel: 'hold',
                ),
              ),
            ],
          ),

        // -----------------------------------------------------------
        // PACING — accordion member, default closed.
        // -----------------------------------------------------------
        // Wave 18.6 — inter-group SizedBox(height: 16) removed.
        _GroupHeader(
          label: 'Pacing',
          expanded: pacingOpen,
          hasNonDefaults: _pacingHasNonDefaults,
          // Wave 18.3 — summary persists in BOTH states.
          summary: _pacingSummary(),
          onTap: () => _toggleAccordion(_AccordionGroup.pacing),
        ),
        if (pacingOpen)
          _ExpandedBody(
            children: [
              // Wave 24 — REPS IN VIDEO sits at the TOP of the PACING
              // accordion so the practitioner reads it as foundational:
              // "this video contains N reps; the rest of the math
              // derives from that". Hidden for photos and rest rows
              // (no video to count). Default 3 (seeded by
              // ExerciseCapture.withPersistenceDefaults() on fresh
              // captures); legacy NULL rows fall back to the same
              // default in the editor but still play as 1 rep / loop on
              // both surfaces (preserving pre-Wave-24 timing).
              if (widget.exercise.mediaType == MediaType.video)
                _VideoRepsPerLoopRow(
                  currentValue: widget.exercise.videoRepsPerLoop,
                  globalDefault: StudioDefaults.videoRepsPerLoop,
                  onCommit: (override) {
                    if (override == null) {
                      widget.onUpdate(
                        widget.exercise.copyWith(clearVideoRepsPerLoop: true),
                      );
                    } else {
                      widget.onUpdate(
                        widget.exercise.copyWith(videoRepsPerLoop: override),
                      );
                    }
                  },
                ),
              _PrepSecondsRow(
                currentValue: widget.exercise.prepSeconds,
                globalDefault: StudioDefaults.prepSeconds,
                onCommit: (override) {
                  if (override == null) {
                    widget.onUpdate(
                      widget.exercise.copyWith(clearPrepSeconds: true),
                    );
                  } else {
                    widget.onUpdate(
                      widget.exercise.copyWith(prepSeconds: override),
                    );
                  }
                },
              ),
              // Milestone Q — Post Rep Breather. Shown for all non-rest
              // exercises regardless of sets count (practitioners should
              // be able to configure ahead of time even when sets == 1,
              // per brief). Same inline editor pattern as PREP.
              _InterSetRestRow(
                currentValue: widget.exercise.interSetRestSeconds,
                globalDefault: StudioDefaults.interSetRestSeconds,
                onCommit: (override) {
                  if (override == null) {
                    widget.onUpdate(
                      widget.exercise
                          .copyWith(clearInterSetRestSeconds: true),
                    );
                  } else {
                    widget.onUpdate(
                      widget.exercise
                          .copyWith(interSetRestSeconds: override),
                    );
                  }
                },
              ),
              // Wave 24 — DURATION PER REP retired from the UI. The
              // persisted column lives on for backwards-compatible
              // reads of pre-Wave-24 rows; per-rep / per-set time on
              // both mobile preview and the web player now derives
              // from `videoDurationMs / videoRepsPerLoop`. See
              // ExerciseCapture.estimatedDurationSeconds + the matching
              // calculatePerSetSeconds() in web-player/app.js.
            ],
          ),

        // -----------------------------------------------------------
        // NOTES — accordion member, default closed.
        // -----------------------------------------------------------
        // Wave 18.6 — inter-group SizedBox(height: 16) removed.
        _GroupHeader(
          label: 'Notes',
          expanded: notesOpen,
          hasNonDefaults: _notesHasNonDefaults,
          // Wave 18.3 — summary persists in BOTH states.
          summary: _notesSummary(),
          // Wave 18.8 — NOTES summary forces single-line collapse so
          // multi-paragraph notes don't spill the row onto 2-3 visual
          // lines. PACING keeps its up-to-3-line wrap.
          singleLineSummary: true,
          onTap: () => _toggleAccordion(_AccordionGroup.notes),
        ),
        if (notesOpen)
          _ExpandedBody(
            children: [
              TextField(
                controller: _notesController,
                maxLines: 3,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  hintText: 'e.g. Keep back straight, slow on the way down',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (_) => _pushNotes(),
              ),
            ],
          ),
        const SizedBox(height: 8),
      ],
    );
  }

  /// Derive perRep seconds from the stored total. Used by the
  /// inline-editable custom-duration row.
  int _perRepFromCustom() {
    final total = widget.exercise.customDurationSeconds ?? 0;
    if (_reps <= 0) return total;
    return (total / _reps).round();
  }
}

/// Group-header label for the Studio card's expanded panel. Renders a
/// leading chevron + 11pt uppercase label + same-row summary + an
/// optional trailing coral dot. Tapping fires [onTap].
///
/// Wave 18.3 changes:
///   * Coral dot relocated from LEFT of chevron → RIGHT-aligned
///     trailing position (5pt dot, 12pt from the card edge). Chevron
///     is now always flush-left, so chevrons line up vertically across
///     all four groups regardless of whether the group has non-defaults.
///   * Summary persists when the group is expanded (previously dropped
///     to null on expand, which made the header feel like it was
///     shedding content). Expanded state caps summary to a single line
///     with ellipsis; collapsed keeps the up-to-3-line wrap.
///   * Label stays left-anchored in both states. The previous
///     AnimatedSwitcher (with `— summary`) was also causing a layout
///     jitter when `ValueKey` swapped — dropped in favour of a plain
///     [RichText] whose `maxLines` flips between states.
///   * `hasNonDefaults` no longer changes the label's font weight —
///     the dot alone signals "this group has content" (w700 in all
///     cases). The dot slot exists only when `hasNonDefaults` is true;
///     absence doesn't leave ghost space on the right because the row
///     simply ends at the label-gap + 12pt right-edge padding.
///
/// Carried forward from Wave 18.2:
///   * Chevron rotation animates (180ms ease) between open/closed.
///   * `crossAxisAlignment: CrossAxisAlignment.start` keeps the
///     chevron + dot top-aligned when the label/summary wraps to 2 or
///     3 lines in collapsed state.
class _GroupHeader extends StatelessWidget {
  final String label;
  final bool expanded;

  /// Non-default marker — drives the trailing coral dot. Label weight
  /// no longer changes (Wave 18.3 — dot is the sole "non-default"
  /// signal; label stays at w700).
  final bool hasNonDefaults;

  /// Trailing summary text. Non-null in both collapsed AND expanded
  /// states (Wave 18.3 — summary persists on expand). Rendered on the
  /// same row as the label, joined by a ` · ` separator. Collapsed
  /// wraps up to 3 lines; expanded clamps to 1 line + ellipsis.
  final String? summary;

  /// Tap toggles the group's open/closed state. Every group header
  /// is interactive — PLAYBACK / DOSE / PACING / NOTES all share the
  /// single-open accordion post-Wave-18.2.
  final VoidCallback onTap;

  /// Force the summary onto one visual line with ellipsis, even when
  /// collapsed. NOTES passes `true` so multi-paragraph notes don't
  /// spill the collapsed row across 2-3 lines (Wave 18.8). PLAYBACK /
  /// DOSE / PACING pass `false` and keep the up-to-3-line wrap when
  /// collapsed. Expanded state is always single-line regardless.
  final bool singleLineSummary;

  /// True for the first section header inside the card (PLAYBACK). The
  /// card's own top padding already supplies space above this header,
  /// so the Wave 18.10 asymmetric `top: 12` is suppressed here to avoid
  /// double-padding. All other headers pass `false` (default).
  final bool isFirst;

  const _GroupHeader({
    required this.label,
    required this.expanded,
    required this.hasNonDefaults,
    required this.summary,
    required this.onTap,
    this.singleLineSummary = false,
    this.isFirst = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: ConstrainedBox(
        // Retain a 40pt minimum row height for the 1-line case so the
        // hit target doesn't shrink. Multi-line summaries push the row
        // taller via the inner column (collapsed state only).
        constraints: const BoxConstraints(minHeight: 40),
        child: Padding(
          // Wave 18.10 — asymmetric padding: top: 12 before every
          // section header (except the first, which sits right under
          // the card's own top padding), bottom: 2 below. Section
          // breaks now feel like real section breaks instead of
          // continuations of the previous body.
          // Wave 18.11 — bottom bumped 2 → 6 so the new elevated
          // sub-card has visible breathing room from its section
          // header. Header no longer lives in visual contact with the
          // sub-card's top edge.
          padding: EdgeInsets.only(
            top: isFirst ? 2 : 12,
            bottom: 6,
          ),
          child: Row(
            // Top-aligned so chevron + dot stay at the visual top when
            // the label/summary wraps to 2 or 3 lines.
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 1. Chevron — always flush-left, rotates on open/close.
              // Wave 18.10 — padding retuned to visually centre against
              // the Montserrat 18pt label line box.
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: AnimatedRotation(
                  turns: expanded ? 0 : -0.25,
                  duration: const Duration(milliseconds: 180),
                  curve: AppMotion.standard,
                  child: const Icon(
                    Icons.expand_more,
                    size: 18,
                    color: AppColors.primary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // 2. Label + summary — persists in BOTH states. Collapsed
              //    allows up to 3 lines; expanded clamps to 1 line with
              //    ellipsis. Label stays left-anchored in either case.
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: RichText(
                    maxLines: expanded
                        ? 1
                        : (singleLineSummary ? 1 : 3),
                    softWrap: !expanded && !singleLineSummary,
                    overflow: TextOverflow.ellipsis,
                    // Wave 18.9 — header bumped 16pt → 18pt AND swapped
                    // Inter → Montserrat. Brand spec reserves
                    // Montserrat for headings; using Inter for the
                    // section header was a body-tier choice that held
                    // back the coral-on-dark hierarchy. Montserrat's
                    // display-ready letterforms give the coral label
                    // real presence. Pairs with a matching 13pt → 12pt
                    // shrink on the inner tier (labels + values) in
                    // `_ControlRow` / `_PrepSecondsRow` /
                    // `_DurationPerRepRow`. Inner tier now 6pt below
                    // the header vs Wave 18.8's 3pt — hierarchy finally
                    // reads at a glance.
                    text: TextSpan(
                      style: const TextStyle(
                        fontFamily: 'Montserrat',
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                        color: AppColors.primary,
                        height: 1.25,
                      ),
                      children: <InlineSpan>[
                        TextSpan(text: label.toUpperCase()),
                        if (summary != null && summary!.isNotEmpty)
                          TextSpan(
                            text: ' · $summary',
                            style: const TextStyle(
                              fontFamily: 'Montserrat',
                              fontSize: 18,
                              fontWeight: FontWeight.w500,
                              letterSpacing: 0,
                              color: AppColors.textSecondaryOnDark,
                              height: 1.25,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              // 3. Coral dot (only when non-default) — Wave 18.3 moved
              //    it from the leading position to a trailing slot.
              //    Slot exists only when hasNonDefaults = true; absence
              //    doesn't leave ghost space because the row still has
              //    its 12pt right-edge padding below.
              if (hasNonDefaults) ...[
                const SizedBox(width: 8),
                Padding(
                  // Align to the first-line label baseline. Wave 18.10
                  // bumped 11 → 13 so the dot tracks the chevron's new
                  // visually-centered position on the Montserrat 18pt
                  // line box.
                  padding: const EdgeInsets.only(top: 13),
                  child: Container(
                    width: 5,
                    height: 5,
                    decoration: const BoxDecoration(
                      color: AppColors.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ],
              // 4. 12pt right-edge padding so the dot (or the end of
              //    the label+summary) never touches the card border.
              const SizedBox(width: 12),
            ],
          ),
        ),
      ),
    );
  }
}

/// Wave 18.11 — elevated sub-card for an open accordion section. Wraps
/// each body (PLAYBACK / DOSE / PACING / NOTES) so it reads as a nested
/// card belonging to its parent. Fill is [AppColors.surfaceRaised] on
/// top of the outer card's [AppColors.surfaceBase]; one elevation tier
/// brighter. Radius follows the card's 12 → 8 nesting pattern. Border
/// is a neutral 1pt stroke at 6% white alpha — zero coral on the body
/// itself (the existing coral chevron rotation + persistent summary
/// already signal "this section is live").
class _ExpandedBody extends StatelessWidget {
  final List<Widget> children;
  const _ExpandedBody({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        // Wave 18.11 — mirror the outer card at one elevation tier up.
        // Outer card is surfaceBase @ radius 12; sub-card is surfaceRaised
        // @ radius 8. Same grammar, one step brighter — reads as "this
        // drawer belongs to the parent card" without adding coral.
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.06),
          width: 1,
        ),
      ),
      // Wave 18.11 — symmetric horizontal padding (was LTRB 12/8/4/8);
      // right-aligned values inside (REPS / SETS / HOLD / PREP /
      // DURATION PER REP / Muted toggle) now have breathing room from
      // the sub-card's right edge. Vertical 10pt top + 10pt bottom.
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

/// One DOSE control row — "REPS" label + current-value number +
/// horizontally-scrolling chip row. Keeps the Studio card's grammar
/// consistent across Reps / Sets / Hold.
class _ControlRow extends StatelessWidget {
  final String label;
  final num value;
  final String Function(num) displayFormat;
  final Widget child;

  const _ControlRow({
    required this.label,
    required this.value,
    required this.displayFormat,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                label.toUpperCase(),
                style: const TextStyle(
                  fontFamily: 'Inter',
                  // Wave 18.9 — 13pt → 12pt to widen the gap vs the
                  // 18pt section header.
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                  color: AppColors.textSecondaryOnDark,
                ),
              ),
              Text(
                displayFormat(value),
                style: const TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontFamilyFallback: ['Menlo', 'Courier'],
                  // Wave 18.9 — 13pt → 12pt to widen the gap vs the
                  // 18pt section header.
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textOnDark,
                ),
              ),
            ],
          ),
        ),
        child,
      ],
    );
  }
}

// Wave 24 — `_DurationPerRepRow` + `_SourceTogglePair` were retired
// from the UI on this commit. The persisted column lives on for
// backwards-compatible reads of pre-Wave-24 plans (so an older row
// with a manual override still plays at the override duration), but
// the editor and the From-video / Manual toggle pair are gone. Per-rep
// time is now derived from `videoDurationMs / videoRepsPerLoop` —
// see `_VideoRepsPerLoopRow` below + the matching
// `calculatePerSetSeconds` in `web-player/app.js`.

/// "REPS IN VIDEO" inline-editable integer field for the Studio
/// exercise card's PACING accordion (Wave 24). Asks the practitioner
/// how many repetitions are in the source video; per-rep time on both
/// surfaces derives as
///
///   per_rep = (videoDurationMs / 1000) / videoRepsPerLoop
///   per_set = (reps ?? 10) × per_rep
///
/// Three-state semantics (mirrors the Supabase column):
///   * NULL → legacy / pre-Wave-24 row. Treated as 1 rep per loop on
///     both mobile preview and the web player so older plans keep
///     playing exactly as they did before.
///   * 3 → freshly-seeded default value (via
///     [ExerciseCapture.withPersistenceDefaults]). Stored, not bold.
///   * Any other positive integer → practitioner-set rep count. Bold.
///
/// Commit rules:
///   * Empty / negative / zero / non-numeric → restore previous, no
///     write (a video must contain at least 1 rep).
///   * Value == default (3) → clear the override so the dot doesn't
///     light for a coincidence match (the persistence default already
///     stamped 3, so storing 3-again is a no-op).
///   * Other positive integer → persist as the override.
class _VideoRepsPerLoopRow extends StatefulWidget {
  final int? currentValue;
  final int globalDefault;
  final ValueChanged<int?> onCommit;

  const _VideoRepsPerLoopRow({
    required this.currentValue,
    required this.globalDefault,
    required this.onCommit,
  });

  @override
  State<_VideoRepsPerLoopRow> createState() => _VideoRepsPerLoopRowState();
}

class _VideoRepsPerLoopRowState extends State<_VideoRepsPerLoopRow> {
  late final TextEditingController _controller;
  final FocusNode _focusNode = FocusNode();
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: widget.currentValue?.toString() ?? '',
    );
    _focusNode.addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(covariant _VideoRepsPerLoopRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_editing && oldWidget.currentValue != widget.currentValue) {
      _controller.text = widget.currentValue?.toString() ?? '';
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.removeListener(_onFocusChange);
    _focusNode.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (!_focusNode.hasFocus && _editing) {
      _commit();
    }
  }

  void _startEditing() {
    HapticFeedback.selectionClick();
    _controller.text =
        (widget.currentValue ?? widget.globalDefault).toString();
    setState(() => _editing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
      _controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _controller.text.length,
      );
    });
  }

  void _commit() {
    final text = _controller.text.trim();
    int? next;
    if (text.isEmpty) {
      // Empty → restore previous; null on this column means "legacy
      // 1-rep loop" which is rarely what the practitioner intends.
      next = widget.currentValue;
    } else {
      final parsed = int.tryParse(text);
      if (parsed == null || parsed <= 0) {
        next = widget.currentValue;
      } else if (parsed == widget.globalDefault) {
        next = null;
      } else {
        next = parsed;
      }
    }
    if (next != widget.currentValue) {
      widget.onCommit(next);
    }
    setState(() => _editing = false);
  }

  void _cancel() {
    HapticFeedback.selectionClick();
    setState(() => _editing = false);
  }

  @override
  Widget build(BuildContext context) {
    final hasOverride = widget.currentValue != null;
    final displayValue = hasOverride
        ? widget.currentValue!
        : widget.globalDefault;
    final isCustomised =
        hasOverride && widget.currentValue != widget.globalDefault;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Text(
                'REPS IN VIDEO',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                  color: AppColors.textSecondaryOnDark,
                ),
              ),
              if (!_editing) ...[
                const Spacer(),
                GestureDetector(
                  onTap: _startEditing,
                  behavior: HitTestBehavior.opaque,
                  child: CustomPaint(
                    painter:
                        _DashedUnderlinePainter(color: AppColors.grey500),
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(
                        '$displayValue',
                        style: TextStyle(
                          fontFamily: 'JetBrainsMono',
                          fontFamilyFallback: const ['Menlo', 'Courier'],
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: isCustomised
                              ? AppColors.textOnDark
                              : AppColors.textSecondaryOnDark
                                  .withValues(alpha: 0.7),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (_editing) ...[
            const SizedBox(height: 6),
            InlineNumericEditor(
              controller: _controller,
              focusNode: _focusNode,
              accentColor: AppColors.primary,
              onCancel: _cancel,
              onCommit: _commit,
            ),
          ],
        ],
      ),
    );
  }
}

class _CustomisedDot extends StatelessWidget {
  const _CustomisedDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 4,
      height: 4,
      decoration: const BoxDecoration(
        color: AppColors.primary,
        shape: BoxShape.circle,
      ),
    );
  }
}

// Wave 29 — `_ToggleRow` retired alongside the PLAYBACK section. The
// only caller was the "Muted" switch in PLAYBACK; audio toggling
// lives entirely inside `_MediaViewer` now (mute pill).

/// "Prep seconds" inline-editable integer field for the Studio exercise
/// card's expanded panel (Wave 3 / Milestone P).
///
/// Renders in two modes:
///   * Display — shows "{N}s" in coral text when an override is set, or
///     "{default}s · default" in a muted tone when null. Tap to edit.
///   * Edit — numeric TextField with "s" suffix. Submit commits a
///     positive integer as the override. Empty / 0 / <=0 / non-numeric
///     clears the override (copyWith(clearPrepSeconds: true)).
///
/// The practitioner can't set a negative prep; the CHECK constraint on
/// Supabase + the edit-time guard below keep garbage out of the column.
class _PrepSecondsRow extends StatefulWidget {
  final int? currentValue;
  final int globalDefault;
  final ValueChanged<int?> onCommit;

  const _PrepSecondsRow({
    required this.currentValue,
    required this.globalDefault,
    required this.onCommit,
  });

  @override
  State<_PrepSecondsRow> createState() => _PrepSecondsRowState();
}

class _PrepSecondsRowState extends State<_PrepSecondsRow> {
  late final TextEditingController _controller;
  final FocusNode _focusNode = FocusNode();
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: widget.currentValue?.toString() ?? '',
    );
    _focusNode.addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(covariant _PrepSecondsRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_editing && oldWidget.currentValue != widget.currentValue) {
      _controller.text = widget.currentValue?.toString() ?? '';
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.removeListener(_onFocusChange);
    _focusNode.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (!_focusNode.hasFocus && _editing) {
      _commit();
    }
  }

  void _startEditing() {
    HapticFeedback.selectionClick();
    // Wave 18.7 — seed the editor with the currently-displayed value
    // (override OR global default). Before, the editor opened empty
    // when no override was set, which read as "please type from
    // scratch". Now the field shows the default as a starting point,
    // matching the dashed-underline value the practitioner just
    // tapped.
    _controller.text =
        (widget.currentValue ?? widget.globalDefault).toString();
    setState(() => _editing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
      _controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _controller.text.length,
      );
    });
  }

  void _commit() {
    final text = _controller.text.trim();
    int? next;
    if (text.isEmpty) {
      next = null; // empty → clear override
    } else {
      final parsed = int.tryParse(text);
      // 0 or negative → clear. Only positive integers are valid overrides;
      // matches the CHECK constraint on Supabase (prep_seconds > 0).
      if (parsed == null || parsed <= 0) {
        next = null;
      } else if (parsed == widget.globalDefault) {
        // Wave 18.7 — committing a value identical to the global
        // default should clear the override, not persist a
        // "coincidence override". Otherwise the non-default marker
        // lights up for a value that matches the default. Keeps the
        // override semantics crisp: override ≠ default by definition.
        next = null;
      } else {
        next = parsed;
      }
    }
    if (next != widget.currentValue) {
      widget.onCommit(next);
    }
    setState(() => _editing = false);
  }

  void _cancel() {
    HapticFeedback.selectionClick();
    setState(() => _editing = false);
  }

  @override
  Widget build(BuildContext context) {
    final hasOverride = widget.currentValue != null;
    // Wave 18.7 — dropped the " · default" suffix. The dashed-underline
    // affordance already signals "tap to edit"; the source label
    // (default vs override) was noise. Both states render the same
    // "{N}s" with dashed underline; the colour shift (muted when at
    // default, white when set) remains as the subtle state indicator.
    final displayValue = hasOverride
        ? widget.currentValue!
        : widget.globalDefault;
    final displayText = '${displayValue}s';

    // Wave 18.9 — editor now stacks full-width below the label when
    // editing, instead of sharing a row. DURATION PER REP's 175pt label
    // left no room for the editor even with `Expanded`. Stacking
    // applies to both PREP and DURATION PER REP for visual consistency.
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Text(
                'PREP',
                style: TextStyle(
                  fontFamily: 'Inter',
                  // Wave 18.9 — 13pt → 12pt to widen the gap vs the
                  // 18pt section header.
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                  color: AppColors.textSecondaryOnDark,
                ),
              ),
              if (!_editing) ...[
                const Spacer(),
                GestureDetector(
                  onTap: _startEditing,
                  behavior: HitTestBehavior.opaque,
                  child: CustomPaint(
                    painter: _DashedUnderlinePainter(color: AppColors.grey500),
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(
                        displayText,
                        style: TextStyle(
                          fontFamily: 'JetBrainsMono',
                          fontFamilyFallback: const ['Menlo', 'Courier'],
                          // Wave 18.9 — 13pt → 12pt to widen the gap
                          // vs the 18pt section header.
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: hasOverride
                              ? AppColors.textOnDark
                              : AppColors.textSecondaryOnDark
                                  .withValues(alpha: 0.7),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (_editing) ...[
            const SizedBox(height: 6),
            // Full-width editor — the enclosing Column stretches it
            // via crossAxisAlignment, so no Expanded wrapper needed.
            InlineNumericEditor(
              controller: _controller,
              focusNode: _focusNode,
              accentColor: AppColors.primary,
              onCancel: _cancel,
              onCommit: _commit,
            ),
          ],
        ],
      ),
    );
  }
}

/// "Post Rep Breather" inline-editable integer field for the Studio
/// exercise card's PACING accordion (Milestone Q). Configures seconds
/// of rest between sets within a single exercise — played back on the
/// web player as a sage countdown chip over the last visible frame
/// (video pauses + resumes without reset).
///
/// Three-state semantics (mirrors the Supabase column):
///   * NULL → no breather (legacy rows / pre-migration captures).
///     Displayed as "{default}s" in muted tone (tap to set).
///   * 0 → practitioner explicitly disabled. Displayed as "Off" in
///     muted tone. A committed value of 0 is persisted (distinct
///     from NULL in intent).
///   * Positive integer → breather seconds. Displayed as "{N}s" in
///     bold white when it differs from the default; muted white when
///     it matches the default (because it's likely a freshly-seeded
///     15s that the practitioner has not touched).
///
/// Commit rules — mirror PREP almost exactly, with one difference:
///   * Empty → clear (copyWith(clearInterSetRestSeconds: true))
///   * Negative / non-numeric → clear
///   * 0 → persist 0 (explicit disable — DO NOT clear, that's the
///     difference vs PREP where 0 meant "clear")
///   * Value == default (15) → clear, since a "coincidence override"
///     shouldn't paint the customised dot.
///   * Positive non-default → persist as the override
class _InterSetRestRow extends StatefulWidget {
  final int? currentValue;
  final int globalDefault;
  final ValueChanged<int?> onCommit;

  const _InterSetRestRow({
    required this.currentValue,
    required this.globalDefault,
    required this.onCommit,
  });

  @override
  State<_InterSetRestRow> createState() => _InterSetRestRowState();
}

class _InterSetRestRowState extends State<_InterSetRestRow> {
  late final TextEditingController _controller;
  final FocusNode _focusNode = FocusNode();
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: widget.currentValue?.toString() ?? '',
    );
    _focusNode.addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(covariant _InterSetRestRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_editing && oldWidget.currentValue != widget.currentValue) {
      _controller.text = widget.currentValue?.toString() ?? '';
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.removeListener(_onFocusChange);
    _focusNode.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (!_focusNode.hasFocus && _editing) {
      _commit();
    }
  }

  void _startEditing() {
    HapticFeedback.selectionClick();
    // Seed the editor with the currently-displayed value (override OR
    // global default). Matches the PREP pattern — tapping the dashed
    // underline shows the number the practitioner just saw rather
    // than an empty field.
    _controller.text =
        (widget.currentValue ?? widget.globalDefault).toString();
    setState(() => _editing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
      _controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _controller.text.length,
      );
    });
  }

  void _commit() {
    final text = _controller.text.trim();
    int? next;
    if (text.isEmpty) {
      next = null;
    } else {
      final parsed = int.tryParse(text);
      if (parsed == null || parsed < 0) {
        // Garbage / negative → clear.
        next = null;
      } else if (parsed == widget.globalDefault) {
        // Value == default → clear the override so we don't paint the
        // customised dot for a coincidence match. On fresh captures
        // the stored value is already 15 via withPersistenceDefaults()
        // so clearing here is a no-op at the persistence layer.
        next = null;
      } else {
        // 0 is a valid explicit-disable value; persist it.
        next = parsed;
      }
    }
    if (next != widget.currentValue) {
      widget.onCommit(next);
    }
    setState(() => _editing = false);
  }

  void _cancel() {
    HapticFeedback.selectionClick();
    setState(() => _editing = false);
  }

  @override
  Widget build(BuildContext context) {
    final hasOverride = widget.currentValue != null;
    final isExplicitDisable = widget.currentValue == 0;
    final displayValue = hasOverride
        ? widget.currentValue!
        : widget.globalDefault;
    // "Off" reads cleaner than "0s" for the deliberate-disable case;
    // matches the DOSE.Hold convention (`Hold off`).
    final displayText = isExplicitDisable ? 'Off' : '${displayValue}s';
    // Bold white only when the override differs from the default.
    // A stored 15 (default) or null renders muted — nothing to shout
    // about visually.
    final isCustomised = hasOverride && widget.currentValue != widget.globalDefault;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Text(
                'POST REP BREATHER',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                  color: AppColors.textSecondaryOnDark,
                ),
              ),
              if (!_editing) ...[
                const Spacer(),
                GestureDetector(
                  onTap: _startEditing,
                  behavior: HitTestBehavior.opaque,
                  child: CustomPaint(
                    painter: _DashedUnderlinePainter(color: AppColors.grey500),
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(
                        displayText,
                        style: TextStyle(
                          fontFamily: 'JetBrainsMono',
                          fontFamilyFallback: const ['Menlo', 'Courier'],
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: isCustomised
                              ? AppColors.textOnDark
                              : AppColors.textSecondaryOnDark
                                  .withValues(alpha: 0.7),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (_editing) ...[
            const SizedBox(height: 6),
            InlineNumericEditor(
              controller: _controller,
              focusNode: _focusNode,
              accentColor: AppColors.primary,
              onCancel: _cancel,
              onCommit: _commit,
            ),
          ],
        ],
      ),
    );
  }
}

/// Dashed underline painter for the "Prep seconds" tappable field.
/// Mirrors [InlineEditableText]'s local painter — duplicated here so the
/// card widget stays self-contained.
class _DashedUnderlinePainter extends CustomPainter {
  final Color color;
  _DashedUnderlinePainter({this.color = Colors.grey});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;

    double startX = 0;
    const dashWidth = 4.0;
    const dashGap = 3.0;

    while (startX < size.width) {
      canvas.drawLine(
        Offset(startX, size.height),
        Offset(startX + dashWidth, size.height),
        paint,
      );
      startX += dashWidth + dashGap;
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Inline numeric editor row with explicit `< Cancel   [_N_]   Done >`
/// buttons. iOS numeric keypad has no return key, so commit / dismiss
/// need explicit affordances. Mirrors the pattern already in use on
/// [PresetChipRow]'s `_CustomInputRow`.
///
/// Wave 18.7 — introduced for PREP + DURATION PER REP inline editors.
/// Both editors previously either swallowed typed values (no way to
/// commit) or relied on focus-blur to commit, which isn't a guaranteed
/// gesture for the user. Cancel is now a first-class restore; Done is
/// the explicit commit path.
///
/// Wave 18.8 — editor now consumes the full horizontal width offered by
/// its parent. The text field uses [Expanded] instead of a fixed
/// [fieldWidth] (retained as an ignored param for compat), so the row
/// fits exactly within the card's content area.
///
/// Wave 18.9 — callers wrap in [Expanded] (or stretch via parent
/// [Column]) to give the editor a bounded width. PREP + DURATION PER
/// REP now use a stretched [Column] instead of an [Expanded]-in-[Row]
/// pattern — the 175pt DURATION PER REP label left no room for the
/// editor on its own row.
class InlineNumericEditor extends StatelessWidget {
  /// TextEditingController owned by the caller. Lets the caller pre-seed
  /// the field with the current value + retain state across rebuilds.
  final TextEditingController controller;

  /// FocusNode owned by the caller — the caller drives requestFocus()
  /// after opening the editor so the number pad pops immediately.
  final FocusNode focusNode;

  /// Accent colour — coral on exercise card, sage on rest bar (future).
  final Color accentColor;

  /// Cancel restores the prior state without committing. Caller flips
  /// editing back to closed.
  final VoidCallback onCancel;

  /// Done commits the typed value. Caller parses the controller, writes
  /// through to the model, and flips editing back to closed.
  final VoidCallback onCommit;

  /// Optional suffix character inside the text field (e.g. 's' for
  /// seconds). Drawn as a non-editable suffix via InputDecoration.
  final String? suffix;

  /// Retained for API compat; ignored as of Wave 18.8 — the field now
  /// uses [Expanded] and fills whatever horizontal space the parent
  /// offers, so fixed widths would just overflow the card on narrow
  /// phones. Remove once no external caller still passes it.
  final double fieldWidth;

  const InlineNumericEditor({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.accentColor,
    required this.onCancel,
    required this.onCommit,
    this.suffix,
    this.fieldWidth = 72,
  });

  @override
  Widget build(BuildContext context) {
    // Wave 18.8 — the editor's Row no longer uses MainAxisSize.min; it
    // fills the parent width so the text field (Expanded) can take all
    // the leftover space between Cancel and Done. Callers wrap this in
    // Expanded when embedding in a flex parent (PREP + DURATION PER
    // REP both do). On a narrow card (iPhone 17 Pro, ~353pt content)
    // the editor fits without overflowing past the right edge.
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          TextButton(
            onPressed: onCancel,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text(
              'Cancel',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondaryOnDark,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
              ],
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'JetBrainsMono',
                fontFamilyFallback: ['Menlo', 'Courier'],
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: AppColors.textOnDark,
              ),
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 6,
                ),
                filled: true,
                // Wave 18.11 — darker fill than the sub-card (surfaceRaised) so the text field reads as a recessed input well.
                fillColor: AppColors.surfaceBase,
                suffixText: suffix,
                suffixStyle: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 13,
                  color: AppColors.textSecondaryOnDark,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: accentColor, width: 1),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: accentColor, width: 2),
                ),
              ),
              onSubmitted: (_) => onCommit(),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: onCommit,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              backgroundColor: accentColor,
            ),
            child: const Text(
              'Done',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

