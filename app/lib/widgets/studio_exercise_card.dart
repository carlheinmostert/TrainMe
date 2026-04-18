import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../config.dart';
import '../models/exercise_capture.dart';
import '../theme.dart';
import '../theme/motion.dart';
import 'inline_editable_text.dart';
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
    widget.onUpdate(widget.exercise.copyWith(
      reps: _repsValue.round(),
      sets: _setsValue.round(),
      holdSeconds: _holdValue.round(),
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
            border: Border.all(
              color: AppColors.surfaceBorder,
              width: 1,
            ),
          ),
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
        if (isVideo &&
            (widget.exercise.videoDurationMs ?? 0) > 0)
          _ToggleRow(
            label: 'Use video length as 1 rep',
            helper: widget.exercise.customDurationSeconds != null
                ? 'Custom: ${_formatSecs(widget.exercise.effectiveDurationSeconds)}'
                : null,
            value: widget.exercise.customDurationSeconds != null,
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
        if (isVideo)
          _ToggleRow(
            label: 'Include audio on share',
            value: widget.exercise.includeAudio,
            onChanged: (on) {
              widget.onUpdate(
                  widget.exercise.copyWith(includeAudio: on));
            },
          ),
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
  final String? helper;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _ToggleRow({
    required this.label,
    this.helper,
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: AppColors.textOnDark,
                  ),
                ),
                if (helper != null)
                  Text(
                    helper!,
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 12,
                      color: AppColors.textSecondaryOnDark,
                    ),
                  ),
              ],
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
