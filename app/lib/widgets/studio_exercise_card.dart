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
  late double _repsValue;
  late double _setsValue;
  late double _holdValue;
  late TextEditingController _notesController;
  bool _notesOpen = false;

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
      _notesOpen = false;
    }
  }

  void _syncFromModel(ExerciseCapture ex) {
    _repsValue = (ex.reps ?? StudioDefaults.reps).toDouble();
    _setsValue = (ex.sets ?? StudioDefaults.sets).toDouble();
    _holdValue = (ex.holdSeconds ?? StudioDefaults.holdSeconds).toDouble();
  }

  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  void _pushUpdate() {
    // If a custom duration is set (video-length-as-1-rep), keep the
    // TOTAL in sync when reps changes: totalCustom = perRep × reps.
    // perRep is derived from the PREVIOUS reps so the edit round-trips
    // cleanly.
    final newReps = _repsValue.round();
    final currentCustom = widget.exercise.customDurationSeconds;
    int? nextCustom = currentCustom;
    if (currentCustom != null) {
      final oldReps = widget.exercise.reps ?? StudioDefaults.reps;
      if (oldReps > 0) {
        final perRep = (currentCustom / oldReps).round();
        nextCustom = perRep * newReps;
      }
    }
    widget.onUpdate(widget.exercise.copyWith(
      reps: newReps,
      sets: _setsValue.round(),
      holdSeconds: _holdValue.round(),
      notes:
          _notesController.text.isEmpty ? null : _notesController.text,
      customDurationSeconds: nextCustom,
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
    final sets = _setsValue.round();
    final reps = _repsValue.round();
    if (widget.isInCircuit) {
      parts.add('$reps reps');
    } else {
      parts.add('$sets × $reps');
    }
    final hold = _holdValue.round();
    if (hold > 0) parts.add('${hold}s hold');
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
        // Status icon — subtle, non-interactive, allowed under R-02
        // because it's informational, not a tap target.
        _StatusDot(status: widget.exercise.conversionStatus),
      ],
    );
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
        // 1. Failure banner — unchanged position at the top.
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
        // 2. Treatment tiles — three mini-previews of how this specific
        // exercise will render in each treatment. Tapping sets the sticky
        // `preferredTreatment` via R-01 (immediate save, no confirm).
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
        // 3. Muted toggle — lives in the Treatment section. Storage
        // stays `includeAudio`; the UI inverts at the boundary so
        // "Muted = true" means `includeAudio = false`. Default state
        // is muted (safer for shared plans). Always rendered for video
        // exercises; photos have no audio.
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
        // 4. Hairline divider.
        const SizedBox(height: 12),
        const Divider(height: 1, color: AppColors.surfaceBorder),
        const SizedBox(height: 12),
        // 5. Reps slider.
        _VerticalSlider(
          label: 'Reps',
          value: _repsValue,
          min: 1,
          max: 30,
          divisions: 29,
          display: '${_repsValue.round()}',
          onChanged: (v) {
            setState(() => _repsValue = v);
            _pushUpdate();
          },
        ),
        // 6. Use video length as 1 rep — directly under the Reps slider
        // per design feedback. Only rendered for video exercises with a
        // probed duration.
        if (hasVideoLength)
          _ToggleRow(
            label: 'Use video length as 1 rep',
            value: customOn,
            onChanged: (on) {
              if (on) {
                final perRep =
                    (widget.exercise.videoDurationMs! / 1000).round();
                widget.onUpdate(widget.exercise.copyWith(
                  customDurationSeconds: perRep * _repsValue.round(),
                ));
              } else {
                widget.onUpdate(widget.exercise
                    .copyWith(clearCustomDuration: true));
              }
            },
          ),
        // 7. Inline-editable custom duration — only when the toggle is
        // ON. Stores TOTAL (perRep × reps); editing updates perRep and
        // rewrites the total.
        if (hasVideoLength && customOn)
          _CustomDurationRow(
            perRep: _perRepFromCustom(),
            reps: _repsValue.round(),
            onChanged: (newPerRep) {
              final reps = _repsValue.round();
              widget.onUpdate(widget.exercise.copyWith(
                customDurationSeconds: newPerRep * reps,
              ));
            },
          ),
        // 8. Hairline divider.
        const SizedBox(height: 8),
        const Divider(height: 1, color: AppColors.surfaceBorder),
        const SizedBox(height: 12),
        // 9. Sets slider — skipped inside circuits (cycles replace sets).
        if (!widget.isInCircuit)
          _VerticalSlider(
            label: 'Sets',
            value: _setsValue,
            min: 1,
            max: 10,
            divisions: 9,
            display: '${_setsValue.round()}',
            onChanged: (v) {
              setState(() => _setsValue = v);
              _pushUpdate();
            },
          ),
        // 10. Hold slider.
        _VerticalSlider(
          label: 'Hold',
          value: _holdValue,
          min: 0,
          max: 120,
          divisions: 24,
          display: _holdValue.round() == 0
              ? 'Off'
              : '${_holdValue.round()}s',
          onChanged: (v) {
            setState(() => _holdValue = v);
            _pushUpdate();
          },
        ),
        // 11. Notes — unchanged.
        const SizedBox(height: 8),
        GestureDetector(
          onTap: () => setState(() => _notesOpen = !_notesOpen),
          behavior: HitTestBehavior.opaque,
          child: Row(
            children: [
              Icon(
                _notesOpen ? Icons.expand_more : Icons.chevron_right,
                size: 18,
                color: AppColors.textSecondaryOnDark,
              ),
              const SizedBox(width: 4),
              const Text(
                'Notes',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                  color: AppColors.textSecondaryOnDark,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.exercise.notes?.isNotEmpty == true
                      ? widget.exercise.notes!
                      : 'Tap to add',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 12,
                    color: AppColors.textSecondaryOnDark
                        .withValues(alpha: 0.7),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (_notesOpen)
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
              onChanged: (_) => _pushUpdate(),
            ),
          ),
      ],
    );
  }

  /// Derive perRep seconds from the stored total. Used by the
  /// inline-editable custom-duration row.
  int _perRepFromCustom() {
    final total = widget.exercise.customDurationSeconds ?? 0;
    final reps = _repsValue.round();
    if (reps <= 0) return total;
    return (total / reps).round();
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

class _StatusDot extends StatelessWidget {
  final ConversionStatus status;
  const _StatusDot({required this.status});

  @override
  Widget build(BuildContext context) {
    switch (status) {
      case ConversionStatus.pending:
      case ConversionStatus.converting:
        return const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppColors.textSecondaryOnDark,
          ),
        );
      case ConversionStatus.done:
        return const Icon(
          Icons.check_circle,
          size: 18,
          color: AppColors.success,
        );
      case ConversionStatus.failed:
        return const Icon(
          Icons.error_outline,
          size: 18,
          color: AppColors.error,
        );
    }
  }
}

class _VerticalSlider extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String display;
  final ValueChanged<double> onChanged;

  const _VerticalSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.display,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
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
                display,
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
          SliderTheme(
            data: SliderThemeData(
              trackHeight: 6,
              activeTrackColor: AppColors.primary,
              inactiveTrackColor: AppColors.surfaceBorder,
              thumbColor: AppColors.primary,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
              overlayShape:
                  const RoundSliderOverlayShape(overlayRadius: 18),
              overlayColor: AppColors.brandTintBg,
              trackShape: const RoundedRectSliderTrackShape(),
            ),
            child: Slider(
              value: value,
              min: min,
              max: max,
              divisions: divisions,
              onChanged: onChanged,
            ),
          ),
        ],
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

