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
  });

  @override
  State<StudioExerciseCard> createState() => _StudioExerciseCardState();
}

class _StudioExerciseCardState extends State<StudioExerciseCard> {
  late int _reps;
  late int _sets;
  late int _hold;
  late TextEditingController _notesController;

  /// Per-group manual expand/collapse overrides. A null value means
  /// "follow the auto-collapse rule": expand Playback + Dose always,
  /// expand Pacing / Notes only when they hold non-default data.
  /// Overrides reset whenever the card closes + reopens (no
  /// SharedPreferences — the auto-rule is the source of truth).
  bool? _pacingOverride;
  bool? _notesOverride;

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
      _pacingOverride = null;
      _notesOverride = null;
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
      // Card just closed — drop manual overrides so a re-open lands
      // on the auto-collapse rule (spec: "state persists only while
      // the card stays mounted — resets on next open").
      _pacingOverride = null;
      _notesOverride = null;
    }
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
    final isCustom = widget.exercise.customDurationSeconds != null;
    parts.add(isCustom
        ? '${_formatSecs(dur)} custom'
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
                _buildSummary().toUpperCase(),
                style: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
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

  /// Pacing group auto-collapses to its header when every field is at
  /// the app-wide default. Non-default = prep override set OR
  /// customDurationSeconds set OR the video-as-1-rep toggle implicitly
  /// on (tracked via customDurationSeconds). Used to seed the default
  /// expand/collapse state; practitioners can override via the header.
  bool get _pacingHasNonDefaults {
    final ex = widget.exercise;
    if (ex.prepSeconds != null) return true;
    if (ex.customDurationSeconds != null) return true;
    return false;
  }

  bool get _notesHasContent => (widget.exercise.notes ?? '').isNotEmpty;

  bool get _pacingExpanded => _pacingOverride ?? _pacingHasNonDefaults;
  bool get _notesExpanded => _notesOverride ?? _notesHasContent;

  String _pacingSummary() {
    final parts = <String>[];
    final ex = widget.exercise;
    if (ex.prepSeconds != null) parts.add('${ex.prepSeconds}s prep');
    if (ex.customDurationSeconds != null) {
      parts.add('video-length on');
    }
    if (parts.isEmpty) return 'defaults';
    return parts.join(', ');
  }

  String _notesSummary() {
    final raw = widget.exercise.notes ?? '';
    if (raw.isEmpty) return 'empty';
    final clipped = raw.length > 28 ? '${raw.substring(0, 28)}…' : raw;
    return '"$clipped"';
  }

  Widget _buildExpandedPanel() {
    final isVideo = widget.exercise.mediaType == MediaType.video;
    final hasArchive = widget.exercise.archiveFilePath != null &&
        widget.exercise.archiveFilePath!.isNotEmpty;
    final hasVideoLength =
        isVideo && (widget.exercise.videoDurationMs ?? 0) > 0;
    final customOn = widget.exercise.customDurationSeconds != null;
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
        // PLAYBACK — always expanded.
        // -----------------------------------------------------------
        _GroupHeader(
          label: 'Playback',
          expanded: true,
          // Playback is always-on (no auto-collapse); tap is a no-op so
          // we don't mislead the practitioner into thinking it toggles.
          onTap: null,
          summary: null,
        ),
        const SizedBox(height: 8),
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

        // -----------------------------------------------------------
        // DOSE — always expanded. Reps + Sets (skip in circuit) + Hold.
        // -----------------------------------------------------------
        const SizedBox(height: 16),
        _GroupHeader(
          label: 'Dose',
          expanded: true,
          onTap: null,
          summary: null,
        ),
        const SizedBox(height: 8),
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

        // -----------------------------------------------------------
        // PACING — auto-collapsed when every field is default.
        // -----------------------------------------------------------
        const SizedBox(height: 16),
        _GroupHeader(
          label: 'Pacing',
          expanded: _pacingExpanded,
          summary: _pacingExpanded ? null : _pacingSummary(),
          onTap: () {
            HapticFeedback.selectionClick();
            setState(() => _pacingOverride = !_pacingExpanded);
          },
        ),
        if (_pacingExpanded) ...[
          const SizedBox(height: 8),
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
          if (hasVideoLength)
            _ToggleRow(
              label: 'Use video length as 1 rep',
              value: customOn,
              onChanged: (on) {
                if (on) {
                  final perRep =
                      (widget.exercise.videoDurationMs! / 1000).round();
                  widget.onUpdate(widget.exercise.copyWith(
                    customDurationSeconds: perRep * _reps,
                  ));
                } else {
                  widget.onUpdate(widget.exercise
                      .copyWith(clearCustomDuration: true));
                }
              },
            ),
          if (hasVideoLength && customOn)
            _CustomDurationRow(
              perRep: _perRepFromCustom(),
              reps: _reps,
              onChanged: (newPerRep) {
                widget.onUpdate(widget.exercise.copyWith(
                  customDurationSeconds: newPerRep * _reps,
                ));
              },
            ),
        ],

        // -----------------------------------------------------------
        // NOTES — auto-collapsed when empty.
        // -----------------------------------------------------------
        const SizedBox(height: 16),
        _GroupHeader(
          label: 'Notes',
          expanded: _notesExpanded,
          summary: _notesExpanded ? null : _notesSummary(),
          onTap: () {
            HapticFeedback.selectionClick();
            setState(() => _notesOverride = !_notesExpanded);
          },
        ),
        if (_notesExpanded)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: TextField(
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

/// Group-header label for the Studio card's expanded panel. Renders an
/// 11pt uppercase coral label + optional em-dash summary + chevron
/// glyph. Tapping toggles the override; the label row is a 48pt tall
/// hit target spanning the full card width.
class _GroupHeader extends StatelessWidget {
  final String label;
  final bool expanded;

  /// Trailing em-dash summary for collapsed state. Null = no summary
  /// (the group is forced-open, e.g. Playback / Dose).
  final String? summary;

  /// Tap toggles the override. Null = non-interactive (Playback / Dose
  /// render the label + divider only).
  final VoidCallback? onTap;

  const _GroupHeader({
    required this.label,
    required this.expanded,
    required this.summary,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final child = Row(
      children: [
        if (onTap != null)
          AnimatedRotation(
            turns: expanded ? 0 : -0.25,
            duration: AppMotion.fast,
            curve: AppMotion.standard,
            child: const Icon(
              Icons.expand_more,
              size: 18,
              color: AppColors.primary,
            ),
          ),
        if (onTap != null) const SizedBox(width: 4),
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            fontFamily: 'Inter',
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
            color: AppColors.primary,
          ),
        ),
        if (summary != null) ...[
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              '— $summary',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 11,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.2,
                color: AppColors.textSecondaryOnDark,
              ),
            ),
          ),
        ],
      ],
    );
    if (onTap == null) {
      return SizedBox(height: 32, child: Align(alignment: Alignment.centerLeft, child: child));
    }
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        height: 40,
        child: Align(
          alignment: Alignment.centerLeft,
          child: child,
        ),
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
                  fontSize: 11,
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
                  fontSize: 14,
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

/// Inline-editable "Custom duration [Ns] per rep" row. Tap the pill to
/// edit the integer seconds; commits on submit or when focus is lost.
/// Stores per-rep; parent multiplies by reps before persisting.
class _CustomDurationRow extends StatefulWidget {
  final int perRep;
  final int reps;
  final ValueChanged<int> onChanged;

  const _CustomDurationRow({
    required this.perRep,
    required this.reps,
    required this.onChanged,
  });

  @override
  State<_CustomDurationRow> createState() => _CustomDurationRowState();
}

class _CustomDurationRowState extends State<_CustomDurationRow> {
  late final TextEditingController _controller;
  final FocusNode _focusNode = FocusNode();
  bool _isEditing = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: '${widget.perRep}');
    _focusNode.addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(covariant _CustomDurationRow old) {
    super.didUpdateWidget(old);
    if (!_isEditing && old.perRep != widget.perRep) {
      _controller.text = '${widget.perRep}';
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
    if (!_focusNode.hasFocus && _isEditing) {
      _commit();
    }
  }

  void _startEditing() {
    _controller.text = '${widget.perRep}';
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
    if (parsed != null && parsed > 0 && parsed != widget.perRep) {
      widget.onChanged(parsed);
    } else {
      _controller.text = '${widget.perRep}';
    }
    setState(() => _isEditing = false);
  }

  @override
  Widget build(BuildContext context) {
    const labelStyle = TextStyle(
      fontFamily: 'Inter',
      fontSize: 13,
      fontWeight: FontWeight.w500,
      color: AppColors.textOnDark,
    );
    const helperStyle = TextStyle(
      fontFamily: 'Inter',
      fontSize: 12,
      color: AppColors.textSecondaryOnDark,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          const Text('Custom duration', style: labelStyle),
          const SizedBox(width: 10),
          // Editable pill — integer seconds, tap to edit.
          _isEditing
              ? SizedBox(
                  width: 56,
                  child: TextField(
                    controller: _controller,
                    focusNode: _focusNode,
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
                      fillColor: AppColors.brandTintBg,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(
                            color: AppColors.primary, width: 1),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(
                            color: AppColors.primary, width: 2),
                      ),
                    ),
                    onSubmitted: (_) => _commit(),
                  ),
                )
              : GestureDetector(
                  onTap: _startEditing,
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.brandTintBg,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: AppColors.primary.withValues(alpha: 0.45),
                        width: 1,
                      ),
                    ),
                    child: Text(
                      '${widget.perRep}s',
                      style: const TextStyle(
                        fontFamily: 'JetBrainsMono',
                        fontFamilyFallback: ['Menlo', 'Courier'],
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: AppColors.primary,
                      ),
                    ),
                  ),
                ),
          const SizedBox(width: 8),
          const Text('per rep', style: helperStyle),
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
    _controller.text = widget.currentValue?.toString() ?? '';
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
      } else {
        next = parsed;
      }
    }
    if (next != widget.currentValue) {
      widget.onCommit(next);
    }
    setState(() => _editing = false);
  }

  @override
  Widget build(BuildContext context) {
    final hasOverride = widget.currentValue != null;
    final displayText = hasOverride
        ? '${widget.currentValue}s'
        : '${widget.globalDefault}s · default';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          const Text(
            'PREP',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
              color: AppColors.textSecondaryOnDark,
            ),
          ),
          const Spacer(),
          if (_editing) ...[
            SizedBox(
              width: 60,
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.right,
                style: const TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontFamilyFallback: ['Menlo', 'Courier'],
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textOnDark,
                ),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                  suffixText: 's',
                  suffixStyle: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 13,
                    color: AppColors.textSecondaryOnDark,
                  ),
                ),
                onSubmitted: (_) => _commit(),
              ),
            ),
            // iOS number pad has no return key, so the TextField's
            // onSubmitted never fires. Without an explicit Done button
            // there's no way to commit an edit (Wave 3 item #8 fail —
            // Carl: "no way of entering a new value"). Tapping Done
            // also blurs the field, which fires _onFocusChange → commit.
            const SizedBox(width: 8),
            GestureDetector(
              onTap: _commit,
              behavior: HitTestBehavior.opaque,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text(
                  'Done',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ] else
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
                      fontSize: 14,
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

