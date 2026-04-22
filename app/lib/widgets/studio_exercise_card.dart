import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:video_thumbnail/video_thumbnail.dart' as vt;

import '../config.dart';
import '../models/exercise_capture.dart';
import '../models/treatment.dart';
import '../theme.dart';
import '../theme/motion.dart';
import 'inline_editable_text.dart';
import 'preset_chip_row.dart';
import 'thumbnail_peek.dart';
import 'treatment_segmented_control.dart';

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

  /// Prep-countdown runway in seconds (Wave 3 / Milestone P). The mobile
  /// preview + web player both default to this when `exercise.prepSeconds`
  /// is null. Practitioners can override per exercise via the "Prep
  /// seconds" inline field on the Studio card. Keep in lockstep with
  /// `_kPrepSeconds` in plan_preview_screen.dart and `PREP_SECONDS` in
  /// web-player/app.js.
  static const int prepSeconds = 5;
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
  if (exercise.customDurationSeconds != null) return true;
  if (exercise.prepSeconds != null) return true;
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
    this.stickyCustomDurationPerRep,
  });

  @override
  State<StudioExerciseCard> createState() => _StudioExerciseCardState();
}

/// Which of the four accordion-grouped sections is currently expanded.
/// At most one at a time — opening another closes the first. All four
/// can end up closed if the practitioner taps the open one. Wave 18.2
/// folded PLAYBACK into the same accordion (previously an independent
/// toggle that defaulted open); all four groups now start collapsed on
/// every card open so the card reads lean + quiet.
enum _AccordionGroup { playback, dose, pacing, notes }

class _StudioExerciseCardState extends State<StudioExerciseCard> {
  late int _reps;
  late int _sets;
  late int _hold;
  late TextEditingController _notesController;

  /// Single-open accordion for PLAYBACK / DOSE / PACING / NOTES.
  /// Null = all four closed (the default on every card open, per
  /// Wave 18.2). Opening one group closes the previously-open group;
  /// tapping the open group closes it (null again).
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
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Thumbnail owns its own gesture zone — tap opens viewer, long
        // press opens peek. Must sit OUTSIDE the card-wide InkWell tap.
        ThumbnailPeek(
          exercise: widget.exercise,
          onTap: widget.onThumbnailTap,
          onOpenFullScreen: widget.onThumbnailTap,
          onReplaceMedia: widget.onReplaceMedia,
          onDelete: widget.onDelete,
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
                // Wave 18.2 — mixed-case kept. Reps / sets / hold read
                // naturally ("3 reps · 1 set · 5s hold") next to the
                // InlineEditableText name above, which is also mixed
                // case. The ALL CAPS variant from pre-18.1 read like a
                // label strip rather than a live stat readout.
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
        // warning on failed, centre spinner while converting), so the
        // status dot was redundant and contributed to header-row
        // visual noise. Zero information loss.
      ],
    );
  }

  // ------------------------------------------------------------------
  // Non-default markers — drive the coral dot + bolded label on each
  // accordion group header. Wave 18.1 retires the auto-expand-on-non-
  // defaults rule; the marker alone signals "there's something
  // practitioner-curated in this group".
  // ------------------------------------------------------------------

  /// PLAYBACK is "non-default" when the practitioner has changed the
  /// treatment away from Line OR muted the audio on a video.
  bool get _playbackHasNonDefaults {
    final ex = widget.exercise;
    if (ex.preferredTreatment != null &&
        ex.preferredTreatment != Treatment.line) {
      return true;
    }
    if (ex.mediaType == MediaType.video && !ex.includeAudio) {
      return true;
    }
    return false;
  }

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

  /// PACING is "non-default" when prep override OR custom-duration is
  /// set.
  bool get _pacingHasNonDefaults {
    final ex = widget.exercise;
    if (ex.prepSeconds != null) return true;
    if (ex.customDurationSeconds != null) return true;
    return false;
  }

  /// NOTES is "non-default" when the notes field has any content.
  bool get _notesHasNonDefaults => (widget.exercise.notes ?? '').isNotEmpty;

  // ------------------------------------------------------------------
  // Collapsed-row summaries — shown next to each group header when the
  // group is collapsed. Spec requires a summary for ALL four groups
  // (Wave 18.1).
  // ------------------------------------------------------------------

  /// PLAYBACK collapsed summary — e.g. `Line · Audio on` / `B&W · Muted`.
  /// Omits the audio segment for non-video exercises (there's no audio
  /// to mute on a photo).
  String _playbackSummary() {
    final ex = widget.exercise;
    final treatment = ex.preferredTreatment ?? Treatment.line;
    final treatmentLabel = treatment.shortLabel;
    if (ex.mediaType != MediaType.video) return treatmentLabel;
    final audioLabel = ex.includeAudio ? 'Audio on' : 'Muted';
    return '$treatmentLabel · $audioLabel';
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
  /// Wave 18.5 — renamed "custom" copy away from the misleading label
  /// since a value derived from video length is no longer stored as
  /// `customDurationSeconds`. A populated `customDurationSeconds` now
  /// uniquely means "practitioner set a manual per-rep value".
  String _pacingSummary() {
    final parts = <String>[];
    final ex = widget.exercise;
    if (ex.prepSeconds != null) parts.add('${ex.prepSeconds}s prep');
    if (ex.customDurationSeconds != null) {
      final perRep = _perRepFromCustom();
      parts.add('${perRep}s per rep');
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
    final isVideo = widget.exercise.mediaType == MediaType.video;
    final hasArchive = widget.exercise.archiveFilePath != null &&
        widget.exercise.archiveFilePath!.isNotEmpty;
    final hasVideoLength =
        isVideo && (widget.exercise.videoDurationMs ?? 0) > 0;

    final playbackOpen = _openGroup == _AccordionGroup.playback;
    final doseOpen = _openGroup == _AccordionGroup.dose;
    final pacingOpen = _openGroup == _AccordionGroup.pacing;
    final notesOpen = _openGroup == _AccordionGroup.notes;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Failure banner — stays at the top of the expanded panel. It's
        // an alert, not a grouped control, so it lives OUTSIDE the
        // PLAYBACK / DOSE / PACING / NOTES sections.
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
        // PLAYBACK — accordion member, default closed (Wave 18.2).
        // Previously an independent toggle that defaulted open; now
        // participates in the single-open accordion with DOSE / PACING
        // / NOTES. All four start collapsed; opening one closes any
        // other currently-open group.
        // -----------------------------------------------------------
        _GroupHeader(
          label: 'Playback',
          expanded: playbackOpen,
          hasNonDefaults: _playbackHasNonDefaults,
          // Wave 18.3 — summary persists in BOTH states. Expanded
          // collapses to single-line ellipsis inside _GroupHeader.
          summary: _playbackSummary(),
          // Wave 18.10 — PLAYBACK is the first section header; suppress
          // the top: 12 asymmetric padding so it doesn't double-pad
          // with the card's own top inset.
          isFirst: true,
          onTap: () => _toggleAccordion(_AccordionGroup.playback),
        ),
        if (playbackOpen)
          _ExpandedBody(
            children: [
              TreatmentTilesRow(
                exercise: widget.exercise,
                hasArchive: hasArchive,
                onChanged: (t) {
                  HapticFeedback.selectionClick();
                  widget.onUpdate(
                    widget.exercise.copyWith(preferredTreatment: t),
                  );
                },
              ),
              if (isVideo) ...[
                const SizedBox(height: 4),
                _ToggleRow(
                  label: 'Muted',
                  value: !widget.exercise.includeAudio,
                  onChanged: (muted) {
                    widget.onUpdate(
                      widget.exercise.copyWith(includeAudio: !muted),
                    );
                  },
                ),
              ],
            ],
          ),

        // -----------------------------------------------------------
        // DOSE — accordion member, default closed. Reps + Sets (skip
        // in circuit) + Hold.
        // -----------------------------------------------------------
        // Wave 18.6 — inter-group SizedBox(height: 16) removed. Groups
        // flow directly against each other; the tighter 2pt vertical
        // padding inside _GroupHeader provides the visual breathing
        // room. No divider lines between groups.
        _GroupHeader(
          label: 'Dose',
          expanded: doseOpen,
          hasNonDefaults: _doseHasNonDefaults,
          // Wave 18.3 — summary persists in BOTH states.
          summary: _doseSummary(),
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
              // Wave 18.7 — DURATION PER REP redesigned to mirror PREP:
              // label + dashed-underline value on one row, From video /
              // Manual toggle pair on the next row (video only). Editing
              // the value auto-flips source to Manual. Photos + video-
              // without-probe hide the toggle entirely.
              //
              // Storage semantics unchanged from Wave 18.5: customDuration
              // Seconds stores TOTAL (per-rep × reps); null means "From
              // video" (video) or unseeded (photo, which self-seeds on
              // first render).
              _DurationPerRepRow(
                hasVideoLength: hasVideoLength,
                videoLengthSeconds: hasVideoLength
                    ? (widget.exercise.videoDurationMs! / 1000).round()
                    : 0,
                customDurationSeconds: widget.exercise.customDurationSeconds,
                reps: _reps,
                stickyPerRepSeed: widget.stickyCustomDurationPerRep,
                onSelectFromVideo: () {
                  widget.onUpdate(
                    widget.exercise.copyWith(clearCustomDuration: true),
                  );
                },
                onSelectManual: () {
                  // Seed at sticky-per-rep × reps (fallback 5s × reps)
                  // unless a stored customDurationSeconds is already
                  // present (treat that as the prior Manual value even if
                  // we just flipped between segments). Writing the total
                  // immediately ensures the displayed per-rep matches
                  // runtime duration math — no stale ghost values.
                  final existing = widget.exercise.customDurationSeconds;
                  final seedPerRep =
                      widget.stickyCustomDurationPerRep ?? 5;
                  final nextTotal = existing ?? (seedPerRep * _reps);
                  widget.onUpdate(widget.exercise.copyWith(
                    customDurationSeconds: nextTotal,
                  ));
                },
                onCommitManualPerRep: (newPerRep) {
                  widget.onUpdate(widget.exercise.copyWith(
                    customDurationSeconds: newPerRep * _reps,
                  ));
                },
              ),
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
          padding: EdgeInsets.only(
            top: isFirst ? 2 : 12,
            bottom: 2,
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

/// Wave 18.10 — recessed container for an open accordion section. Signals
/// "this is the live drawer" via a darker fill + a 2pt coral hairline on
/// the left edge. One per expanded group (PLAYBACK / DOSE / PACING / NOTES).
///
/// Recessed fill uses [AppColors.surfaceBg] (app root bg, elevation 0) —
/// visibly darker than the card's [AppColors.surfaceBase] (elevation 1).
/// Internal padding `EdgeInsets.fromLTRB(12, 8, 4, 8)`: extra left gives the
/// coral stroke breathing room from the content; tight right because the
/// outer card padding already handles the right edge. No border radius —
/// the card's own rounding + overflow clipping handles corners.
class _ExpandedBody extends StatelessWidget {
  final List<Widget> children;
  const _ExpandedBody({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceBg,
        border: Border(
          left: BorderSide(
            color: AppColors.primary.withValues(alpha: 0.45),
            width: 2,
          ),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
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

/// "DURATION PER REP" row inside PACING. Wave 18.7 redesign — mirrors
/// the PREP layout so both pacing controls read identically:
///
///   DURATION PER REP
///   3s                                       [value with dashed underline]
///   [ From video ]  [ Manual ]               [source toggle — video only]
///
/// Behaviour:
///   * The value (e.g. `3s`) is the primary control. Tap → inline
///     `< Cancel   [_7_]   Done >` editor (via [InlineNumericEditor]).
///     Committing writes per-rep × reps into `customDurationSeconds`
///     AND auto-flips the source toggle to `Manual`.
///   * On video-with-probed-duration, a source-toggle pair sits below
///     the value. `From video` clears `customDurationSeconds` and the
///     displayed value reflects `videoLengthSeconds`. `Manual` seeds
///     `customDurationSeconds` (5 × reps, or `custom_duration_per_rep`
///     sticky default × reps) and makes the value editable.
///   * Photos + videos without probed duration hide the toggle
///     entirely — there's only one source, so a mode indicator would
///     be meaningless. Just the label + editable value.
///
/// Storage semantics are unchanged from Wave 18.5 — `customDurationSeconds`
/// stores the TOTAL (per-rep × reps). This widget reads it divided by
/// reps for display and writes back per-rep × reps on commit.
///
/// Sticky seed — when Manual is first seeded on a fresh exercise
/// (customDurationSeconds == null, user taps Manual OR user taps the
/// value on a photo), this widget asks the parent for the client's
/// sticky `custom_duration_per_rep` default (if any), falling back to
/// 5s. The value is written through `onCommitManualPerRep` so the
/// displayed value matches runtime duration math immediately.
class _DurationPerRepRow extends StatefulWidget {
  /// True when the exercise is a video with a probed videoDurationMs.
  /// Drives whether the source-toggle pair renders at all.
  final bool hasVideoLength;

  /// Video length in whole seconds (0 when hasVideoLength is false).
  /// Used as the displayed per-rep value when From video is active.
  final int videoLengthSeconds;

  /// Stored total — null means From video (for video) or unseeded
  /// (for photo, at which point initState seeds it).
  final int? customDurationSeconds;

  /// Current reps count. Used to convert per-rep ↔ total.
  final int reps;

  /// Tap `From video` → parent clears customDurationSeconds.
  final VoidCallback onSelectFromVideo;

  /// Tap `Manual` on a null customDurationSeconds → parent seeds with
  /// seedPerRep × reps (parent resolves sticky default or 5s and calls
  /// [onCommitManualPerRep]).
  final VoidCallback onSelectManual;

  /// Commit a new per-rep value. Parent writes `newPerRep × reps` into
  /// customDurationSeconds and (optionally) updates the sticky
  /// `custom_duration_per_rep` default.
  final ValueChanged<int> onCommitManualPerRep;

  /// Optional sticky per-rep seed — the parent looks up the client's
  /// `custom_duration_per_rep` default and passes it through. Null
  /// means "no sticky default; fall back to 5s".
  final int? stickyPerRepSeed;

  const _DurationPerRepRow({
    required this.hasVideoLength,
    required this.videoLengthSeconds,
    required this.customDurationSeconds,
    required this.reps,
    required this.onSelectFromVideo,
    required this.onSelectManual,
    required this.onCommitManualPerRep,
    this.stickyPerRepSeed,
  });

  @override
  State<_DurationPerRepRow> createState() => _DurationPerRepRowState();
}

class _DurationPerRepRowState extends State<_DurationPerRepRow> {
  late final TextEditingController _controller;
  final FocusNode _focusNode = FocusNode();
  bool _isEditing = false;

  /// True when Manual mode is active. Equivalent to
  /// `customDurationSeconds != null` on video; always true on photo /
  /// no-probe (since there's only one source).
  bool get _isManual =>
      !widget.hasVideoLength || widget.customDurationSeconds != null;

  /// Per-rep seconds driving the displayed value.
  ///
  /// On Manual: `customDurationSeconds / reps`, or the fallback seed
  /// if customDurationSeconds is null (photo pre-seed race).
  /// On From video: `videoLengthSeconds`.
  int get _displayedPerRep {
    if (widget.hasVideoLength && widget.customDurationSeconds == null) {
      // From video mode — value mirrors the probed length.
      return widget.videoLengthSeconds.clamp(1, 999);
    }
    final total = widget.customDurationSeconds;
    if (total == null) {
      return (widget.stickyPerRepSeed ?? 5).clamp(1, 999);
    }
    if (widget.reps <= 0) return total;
    return (total / widget.reps).round().clamp(1, 999);
  }

  int get _seedPerRep => (widget.stickyPerRepSeed ?? 5).clamp(1, 999);

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: '$_displayedPerRep');
    _focusNode.addListener(_onFocusChange);
    // Photo + video-without-probe: no toggle, only one source.
    // Seed customDurationSeconds on first render so the displayed value
    // matches what the runtime uses. On video-WITH-probe, "From video"
    // is a legitimate null state — we only seed when the practitioner
    // taps Manual OR taps the value to edit.
    if (!widget.hasVideoLength && widget.customDurationSeconds == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        widget.onCommitManualPerRep(_seedPerRep);
      });
    }
  }

  @override
  void didUpdateWidget(covariant _DurationPerRepRow old) {
    super.didUpdateWidget(old);
    // Refresh the text field if the external state shifted (parent
    // wrote through, or user flipped the toggle). Don't stomp on an
    // active edit.
    if (!_isEditing &&
        (old.customDurationSeconds != widget.customDurationSeconds ||
            old.videoLengthSeconds != widget.videoLengthSeconds ||
            old.reps != widget.reps)) {
      _controller.text = '$_displayedPerRep';
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    // Wave 18.7 — focus-blur no longer auto-commits. The iOS number pad
    // doesn't cleanly surrender focus on tap-outside, and blur-commit
    // would clobber an intentional Cancel. Cancel + Done are the only
    // close paths.
  }

  void _startEditing() {
    HapticFeedback.selectionClick();
    _controller.text = '$_displayedPerRep';
    setState(() => _isEditing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
      _controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _controller.text.length,
      );
    });
  }

  void _commit() {
    final raw = _controller.text.trim();
    final parsed = int.tryParse(raw);
    if (parsed != null && parsed > 0) {
      // Commit the new per-rep value. If we were in From video mode,
      // this auto-flips the toggle to Manual because the parent now
      // sees a non-null customDurationSeconds. Spec: editing the value
      // implies Manual.
      widget.onCommitManualPerRep(parsed);
    } else {
      // Invalid / empty — restore display, no write.
      _controller.text = '$_displayedPerRep';
    }
    setState(() => _isEditing = false);
  }

  void _cancel() {
    HapticFeedback.selectionClick();
    _controller.text = '$_displayedPerRep';
    setState(() => _isEditing = false);
  }

  @override
  Widget build(BuildContext context) {
    // Mirror PREP layout:
    //   DURATION PER REP                       (inner label, left)
    //   3s                                     (value, dashed underline)
    //   [ From video ]  [ Manual ]             (source toggle, video only)
    //
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
          // Inline row: label + right-aligned value (when not editing)
          // OR just the label (when editing — the editor stretches
          // full-width below).
          Row(
            children: [
              const Text(
                'DURATION PER REP',
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
              if (!_isEditing) ...[
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
                        '${_displayedPerRep}s',
                        style: const TextStyle(
                          fontFamily: 'JetBrainsMono',
                          fontFamilyFallback: ['Menlo', 'Courier'],
                          // Wave 18.9 — 13pt → 12pt to widen the gap
                          // vs the 18pt section header.
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textOnDark,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (_isEditing) ...[
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
          // Toggle pair only when we have a probed video length —
          // otherwise the single source makes the toggle meaningless.
          if (widget.hasVideoLength) ...[
            const SizedBox(height: 6),
            _SourceTogglePair(
              isFromVideo: !_isManual,
              onSelectFromVideo: () {
                if (!_isManual) return; // already selected
                HapticFeedback.selectionClick();
                widget.onSelectFromVideo();
              },
              onSelectManual: () {
                if (_isManual) return; // already selected
                HapticFeedback.selectionClick();
                widget.onSelectManual();
              },
            ),
          ],
        ],
      ),
    );
  }
}

/// Two-segment source toggle — From video | Manual. Matches the visual
/// family of the treatment segmented control (coral fill for selected,
/// surfaceRaised for unselected). Used by [_DurationPerRepRow] only
/// when the exercise has a probed video length.
///
/// Wave 18.7 — moved out of the inline segmented control and into a
/// standalone row beneath the value. The value is now the primary
/// control; the toggle is a secondary affordance for switching source.
class _SourceTogglePair extends StatelessWidget {
  final bool isFromVideo;
  final VoidCallback onSelectFromVideo;
  final VoidCallback onSelectManual;

  const _SourceTogglePair({
    required this.isFromVideo,
    required this.onSelectFromVideo,
    required this.onSelectManual,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _segment(
          label: 'From video',
          selected: isFromVideo,
          onTap: onSelectFromVideo,
        ),
        const SizedBox(width: 6),
        _segment(
          label: 'Manual',
          selected: !isFromVideo,
          onTap: onSelectManual,
        ),
      ],
    );
  }

  Widget _segment({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: IntrinsicWidth(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          height: 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? AppColors.primary : AppColors.surfaceRaised,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected
                  ? AppColors.primary
                  : AppColors.surfaceBorder,
              width: 1,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 12,
              fontWeight: FontWeight.w600,
              height: 1.0,
              color: selected ? Colors.white : AppColors.textOnDark,
            ),
          ),
        ),
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

class _ToggleRow extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _ToggleRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: AppColors.textOnDark,
              ),
            ),
          ),
          Switch.adaptive(
            value: value,
            onChanged: onChanged,
            activeThumbColor: AppColors.primary,
          ),
        ],
      ),
    );
  }
}

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
                fillColor: AppColors.surfaceRaised,
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

// -----------------------------------------------------------------------------
// TreatmentTilesRow — three side-by-side mini-previews of how this exercise
// will render in each treatment (Line / B&W / Original). Tapping a tile sets
// the exercise's sticky `preferredTreatment` on the fly.
// -----------------------------------------------------------------------------

/// A single row of three treatment preview tiles, sized to fit inside the
/// Studio exercise card's expanded panel.
///
/// The tiles share a single tiny-resolution "preview bitmap" source
/// (generated once per exercise, cached in process memory via
/// [_TreatmentPreviewCache]). Each tile renders the SAME bitmap with a
/// per-treatment [ColorFilter] to produce the Line / B&W / Original
/// look at near-zero incremental cost.
///
/// Gating — B&W + Original tiles tap into a lock glyph + disabled
/// visual when:
///   • the exercise's local `archiveFilePath` is missing (pre-archive
///     capture, or 90-day retention already pruned it), OR
///   • the client hasn't opted in to the treatment (consent gating —
///     same invariant as the segmented control in the player).
///
/// The current implementation treats the local-archive check as the
/// sole gate; the consent wiring lands at the caller (the Studio card
/// can check `PracticeClient.grayscaleAllowed` / `.colourAllowed` and
/// pass a `grayscaleAvailable` / `originalAvailable` flag through, a
/// follow-up after the feature-flag plumbing lands).
class TreatmentTilesRow extends StatelessWidget {
  final ExerciseCapture exercise;
  final bool hasArchive;
  final ValueChanged<Treatment> onChanged;

  const TreatmentTilesRow({
    super.key,
    required this.exercise,
    required this.hasArchive,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final active = exercise.preferredTreatment ?? Treatment.line;
    // Photos render from the raw file directly — they're already a
    // still image. Videos fall back to the grayscale thumbnail (per
    // PR #33) if a colour first-frame hasn't been generated yet.
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Expanded(
            child: _TreatmentTile(
              treatment: Treatment.line,
              active: active == Treatment.line,
              available: true,
              exercise: exercise,
              onTap: () => onChanged(Treatment.line),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _TreatmentTile(
              treatment: Treatment.grayscale,
              active: active == Treatment.grayscale,
              available: hasArchive,
              exercise: exercise,
              onTap: () => onChanged(Treatment.grayscale),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _TreatmentTile(
              treatment: Treatment.original,
              active: active == Treatment.original,
              available: hasArchive,
              exercise: exercise,
              onTap: () => onChanged(Treatment.original),
            ),
          ),
        ],
      ),
    );
  }
}

/// One preview tile — a 48-px-tall rounded card showing how the
/// exercise renders in [treatment]. Tapping sets the exercise's
/// `preferredTreatment` (R-01: immediate save, no confirm). The active
/// tile carries a coral ring + check badge; locked tiles show a lock
/// glyph and grey out.
class _TreatmentTile extends StatelessWidget {
  final Treatment treatment;
  final bool active;
  final bool available;
  final ExerciseCapture exercise;
  final VoidCallback onTap;

  const _TreatmentTile({
    required this.treatment,
    required this.active,
    required this.available,
    required this.exercise,
    required this.onTap,
  });

  /// Per-tile [ColorFilter]. Line is an identity filter (the source is
  /// already a grayscale thumbnail — PR #33 — which is close enough to
  /// the line-drawing aesthetic for a 44 px preview). B&W reuses the
  /// saturation-zero matrix shipped with the segmented control for
  /// visual parity. Original has no filter (pass-through).
  ColorFilter? get _filter {
    switch (treatment) {
      case Treatment.line:
        // The stored thumbnail is already grayscale (PR #33). A subtle
        // brighten nudges it towards the pencil-on-paper feel of the
        // full line drawing; not trying to emulate the actual v6
        // aesthetic at 44 px, just hinting at it.
        return const ColorFilter.matrix(<double>[
          1.1, 0, 0, 0, 14,
          0, 1.1, 0, 0, 14,
          0, 0, 1.1, 0, 14,
          0, 0, 0, 1, 0,
        ]);
      case Treatment.grayscale:
        return grayscaleColorFilter;
      case Treatment.original:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final borderColor = active
        ? AppColors.primary
        : AppColors.surfaceBorder;
    final borderWidth = active ? 2.0 : 1.0;

    return GestureDetector(
      onTap: available ? onTap : null,
      behavior: HitTestBehavior.opaque,
      child: Opacity(
        opacity: available ? 1 : 0.5,
        child: Container(
          height: 48,
          decoration: BoxDecoration(
            color: AppColors.surfaceRaised,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: borderColor,
              width: borderWidth,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(7),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Base preview — same source bitmap for every tile, with
                // a per-treatment filter on top. When the exercise is a
                // rest period (shouldn't expand to tiles, but guard
                // anyway) or the media is missing, fall back to a
                // neutral surface.
                _TreatmentPreviewImage(
                  exercise: exercise,
                  filter: _filter,
                ),
                // Bottom label — Line / B&W / Original. White text on a
                // scrim for contrast over any source colour.
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    height: 18,
                    color: Colors.black.withValues(alpha: 0.55),
                    alignment: Alignment.center,
                    child: Text(
                      treatment.shortLabel,
                      style: const TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
                // Active badge — coral check bottom-right.
                if (active)
                  Positioned(
                    top: 4,
                    right: 4,
                    child: Container(
                      width: 14,
                      height: 14,
                      decoration: const BoxDecoration(
                        color: AppColors.primary,
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: const Icon(
                        Icons.check,
                        size: 10,
                        color: Colors.white,
                      ),
                    ),
                  ),
                // Lock glyph for unavailable treatments.
                if (!available)
                  Container(
                    color: Colors.black.withValues(alpha: 0.3),
                    alignment: Alignment.center,
                    child: const Icon(
                      Icons.lock_outline,
                      color: Colors.white70,
                      size: 18,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Renders the preview bitmap for a Studio-card treatment tile, applying
/// [filter] at paint time. Photos use the raw file directly; videos use
/// either the stored thumbnail (fast path, grayscale per PR #33) or a
/// freshly-extracted first frame from the archive file (slow path, one
/// one-time VideoThumbnail call per exercise, cached for the session in
/// [_TreatmentPreviewCache]).
class _TreatmentPreviewImage extends StatelessWidget {
  final ExerciseCapture exercise;
  final ColorFilter? filter;

  const _TreatmentPreviewImage({
    required this.exercise,
    required this.filter,
  });

  @override
  Widget build(BuildContext context) {
    // Rest periods don't appear here — the card never expands for them.
    // Still, guard against an edge case where a rest card somehow
    // becomes expanded; show a neutral surface so nothing crashes.
    if (exercise.isRest) {
      return const ColoredBox(color: AppColors.surfaceBase);
    }

    // Photos: use the raw file directly. Already a still image, no
    // extraction needed. The raw file is the colour original — filters
    // can freely convert it to Line / B&W without a second source.
    if (exercise.mediaType == MediaType.photo) {
      return _filtered(
        Image.file(
          File(exercise.absoluteRawFilePath),
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) =>
              const ColoredBox(color: AppColors.surfaceBase),
        ),
      );
    }

    // Videos: try the stored thumbnail path first. It's cheap and
    // already on disk. Fall back to on-demand extraction from the raw
    // archive (first frame via video_thumbnail — cached in process
    // memory for the session).
    final thumbPath = exercise.absoluteThumbnailPath;
    if (thumbPath != null && File(thumbPath).existsSync()) {
      return _filtered(
        Image.file(
          File(thumbPath),
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) =>
              const ColoredBox(color: AppColors.surfaceBase),
        ),
      );
    }

    // Archive / raw on-demand thumbnail — only fires when the static
    // thumbnail is missing (legacy captures pre-thumbnail). Cached
    // so we don't re-extract on every rebuild.
    final source = exercise.absoluteArchiveFilePath ??
        (exercise.rawFilePath.isNotEmpty
            ? exercise.absoluteRawFilePath
            : null);
    if (source == null) {
      return const ColoredBox(color: AppColors.surfaceBase);
    }
    return FutureBuilder<String?>(
      future: _TreatmentPreviewCache.getOrExtract(
        exerciseId: exercise.id,
        sourcePath: source,
      ),
      builder: (context, snapshot) {
        final path = snapshot.data;
        if (path == null || !File(path).existsSync()) {
          return const ColoredBox(color: AppColors.surfaceBase);
        }
        return _filtered(
          Image.file(
            File(path),
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) =>
                const ColoredBox(color: AppColors.surfaceBase),
          ),
        );
      },
    );
  }

  Widget _filtered(Widget child) {
    if (filter == null) return child;
    return ColorFiltered(colorFilter: filter!, child: child);
  }
}

/// Process-wide cache for Studio-card treatment preview bitmaps. Keyed
/// by exercise id; value is an absolute path to a JPEG on disk written
/// under `{Documents}/treatment_previews/{exerciseId}.jpg` the first
/// time the tile row mounts.
///
/// Only used for videos whose static [ExerciseCapture.thumbnailPath] is
/// absent (legacy rows) — modern captures hit the fast path directly
/// from [ExerciseCapture.thumbnailPath].
class _TreatmentPreviewCache {
  _TreatmentPreviewCache._();

  static final Map<String, Future<String?>> _inFlight = <String, Future<String?>>{};

  static Future<String?> getOrExtract({
    required String exerciseId,
    required String sourcePath,
  }) {
    final existing = _inFlight[exerciseId];
    if (existing != null) return existing;
    final future = _extract(exerciseId: exerciseId, sourcePath: sourcePath);
    _inFlight[exerciseId] = future;
    return future;
  }

  static Future<String?> _extract({
    required String exerciseId,
    required String sourcePath,
  }) async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docs.path, 'treatment_previews'));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final outPath = p.join(dir.path, '$exerciseId.jpg');
      if (File(outPath).existsSync()) {
        return outPath;
      }
      final result = await vt.VideoThumbnail.thumbnailFile(
        video: sourcePath,
        thumbnailPath: outPath,
        imageFormat: vt.ImageFormat.JPEG,
        maxWidth: 192,
        quality: 70,
      );
      return result;
    } catch (e) {
      debugPrint('TreatmentPreviewCache.extract failed for $exerciseId: $e');
      return null;
    }
  }
}

