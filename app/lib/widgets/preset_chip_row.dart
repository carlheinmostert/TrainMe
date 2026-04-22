import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/practitioner_custom_presets.dart';
import '../theme.dart';
import 'undo_snackbar.dart';

/// A horizontal row of preset-value chips with a `[Custom]` tail.
/// Replaces the two hand-rolled sliders (`_VerticalSlider` on exercise
/// cards + the sage slider on the Rest bar) with a uniform pattern:
///
///   [5] [8] [10] [12] [15]  [Custom]
///   └ canonical presets ┘   └ inline add ┘
///
/// Chips rendered by this widget:
///   * Unselected canonical → surfaceRaised fill, light label.
///   * Unselected custom    → surfaceRaised fill + 3pt coral dot top-right
///                            (tells the practitioner "this is yours,
///                            long-press to remove").
///   * Selected             → [accentColor] fill, white label, either kind.
///   * `[Custom]` tail      → dashed [accentColor] border (1.5pt),
///                            [accentColor] label. Tapping toggles
///                            INLINE input mode; no bottom sheet, no
///                            modal (R-01, load-bearing — don't
///                            regress to a popup here).
///
/// MRU custom-value memory lives practitioner-wide in
/// [PractitionerCustomPresets]; chips merge canonical + MRU before
/// sorting numerically so [5, 7, 8, 10, 12, 13, 15] reads in order.
///
/// Haptics:
///   - Tap canonical / custom / `[Custom]`: selectionClick.
///   - Commit NEW custom value via Done: mediumImpact.
///   - Commit value that matches an existing chip: selectionClick.
///   - Long-press custom chip: selectionClick (then undo SnackBar).
class PresetChipRow extends StatefulWidget {
  /// Opaque key identifying which preset array in
  /// [PractitionerCustomPresets] to read from. e.g. "reps", "sets",
  /// "hold", "rest". Unknown keys surface an empty custom array.
  final String controlKey;

  /// Canonical chips, fixed per controlKey. Rendered in order first,
  /// then merged with the practitioner's MRU values and re-sorted.
  final List<num> canonicalPresets;

  /// Currently-selected value. Drives the fill colour on the matching
  /// chip. When no chip matches exactly, none render as selected.
  final num currentValue;

  /// Fired whenever the practitioner commits a new value. The caller
  /// writes through to the model (`ExerciseCapture.copyWith(reps: v)`
  /// or the rest-bar's `holdSeconds` field).
  final ValueChanged<num> onChanged;

  /// Optional formatter for display. Defaults to `v.toString()`.
  /// Hold uses `(v) => v == 0 ? 'Off' : '${v}s'`; rest uses
  /// `(v) => v < 60 ? '${v}s' : '${v~/60}m${v%60>0?'${v%60}s':''}'`.
  final String Function(num)? displayFormat;

  /// Accent colour. Coral for Reps / Sets / Hold; sage for Rest.
  final Color accentColor;

  /// Label prefix for the undo SnackBar when a custom chip is removed.
  /// Defaults to the controlKey capitalised.
  final String? undoLabel;

  const PresetChipRow({
    super.key,
    required this.controlKey,
    required this.canonicalPresets,
    required this.currentValue,
    required this.onChanged,
    required this.accentColor,
    this.displayFormat,
    this.undoLabel,
  });

  @override
  State<PresetChipRow> createState() => _PresetChipRowState();
}

class _PresetChipRowState extends State<PresetChipRow> {
  bool _customInputOpen = false;
  final TextEditingController _customController = TextEditingController();
  final FocusNode _customFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    PractitionerCustomPresets.onChange.addListener(_onStoreChanged);
  }

  @override
  void dispose() {
    PractitionerCustomPresets.onChange.removeListener(_onStoreChanged);
    _customController.dispose();
    _customFocusNode.dispose();
    super.dispose();
  }

  void _onStoreChanged() {
    if (!mounted) return;
    setState(() {});
  }

  String _format(num value) {
    final fn = widget.displayFormat;
    if (fn != null) return fn(value);
    return value.toString();
  }

  Set<num> _canonicalSet() =>
      widget.canonicalPresets.toSet();

  List<num> _mergedPresets() {
    final canonical = widget.canonicalPresets;
    final custom = PractitionerCustomPresets.get(widget.controlKey);
    final merged = <num>{...canonical, ...custom}.toList();
    merged.sort((a, b) => a.compareTo(b));
    return merged;
  }

  Future<void> _commitCustom() async {
    final text = _customController.text.trim();
    final parsed = num.tryParse(text);
    if (parsed == null || parsed < 0) {
      // Invalid — close input without committing. No haptic.
      setState(() {
        _customInputOpen = false;
        _customController.clear();
      });
      return;
    }

    final canonical = _canonicalSet();
    final custom =
        PractitionerCustomPresets.get(widget.controlKey).toSet();
    final alreadyExists = canonical.contains(parsed) ||
        custom.contains(parsed);
    if (alreadyExists) {
      HapticFeedback.selectionClick();
    } else {
      HapticFeedback.mediumImpact();
      await PractitionerCustomPresets.add(widget.controlKey, parsed);
    }

    if (!mounted) return;
    setState(() {
      _customInputOpen = false;
      _customController.clear();
    });
    widget.onChanged(parsed);
  }

  void _cancelCustom() {
    setState(() {
      _customInputOpen = false;
      _customController.clear();
    });
  }

  void _openCustomInput() {
    HapticFeedback.selectionClick();
    setState(() => _customInputOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _customFocusNode.requestFocus();
    });
  }

  Future<void> _removeCustomChip(num value) async {
    HapticFeedback.selectionClick();
    await PractitionerCustomPresets.remove(widget.controlKey, value);
    if (!mounted) return;
    final label = widget.undoLabel ?? widget.controlKey;
    HapticFeedback.lightImpact();
    showUndoSnackBar(
      context,
      label: 'Removed $label ${_format(value)}',
      onUndo: () async {
        HapticFeedback.selectionClick();
        await PractitionerCustomPresets.add(widget.controlKey, value);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_customInputOpen) {
      return _CustomInputRow(
        controller: _customController,
        focusNode: _customFocusNode,
        accentColor: widget.accentColor,
        onCancel: _cancelCustom,
        onCommit: _commitCustom,
      );
    }

    final presets = _mergedPresets();
    final canonicalSet = _canonicalSet();

    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        children: [
          for (final value in presets)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: _Chip(
                label: _format(value),
                selected: value == widget.currentValue,
                isCustom: !canonicalSet.contains(value),
                accentColor: widget.accentColor,
                onTap: () {
                  HapticFeedback.selectionClick();
                  widget.onChanged(value);
                },
                onLongPress: canonicalSet.contains(value)
                    ? null
                    : () => _removeCustomChip(value),
              ),
            ),
          // [Custom] tail.
          _CustomTail(
            accentColor: widget.accentColor,
            onTap: _openCustomInput,
          ),
        ],
      ),
    );
  }
}

/// Chip — either a canonical or MRU custom value. Long-press on custom
/// chips removes them; canonical chips ignore long-press (they're
/// immutable).
class _Chip extends StatelessWidget {
  final String label;
  final bool selected;
  final bool isCustom;
  final Color accentColor;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _Chip({
    required this.label,
    required this.selected,
    required this.isCustom,
    required this.accentColor,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: selected ? accentColor : AppColors.surfaceRaised,
          borderRadius: BorderRadius.circular(16),
        ),
        alignment: Alignment.center,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                label,
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: selected ? Colors.white : AppColors.textOnDark,
                ),
              ),
            ),
            if (isCustom && !selected)
              Positioned(
                top: -3,
                right: -5,
                child: Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: accentColor,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Dashed-border `[Custom]` tail chip. Tapping opens the inline input.
class _CustomTail extends StatelessWidget {
  final Color accentColor;
  final VoidCallback onTap;

  const _CustomTail({
    required this.accentColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: const BoxDecoration(),
        child: CustomPaint(
          painter: _DashedBorderPainter(color: accentColor),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 2,
              vertical: 6,
            ),
            child: Text(
              'Custom',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: accentColor,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Inline custom-value entry row.
///
///    < Cancel   [_7_]   Done >
///
/// Numeric keyboard; Done commits via [onCommit]. Cancel restores the
/// prior chip row unchanged. No bottom sheet or modal — this is the
/// load-bearing no-popup rule from CLAUDE.md.
class _CustomInputRow extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final Color accentColor;
  final VoidCallback onCancel;
  final VoidCallback onCommit;

  const _CustomInputRow({
    required this.controller,
    required this.focusNode,
    required this.accentColor,
    required this.onCancel,
    required this.onCommit,
  });

  @override
  Widget build(BuildContext context) {
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
            child: Text(
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
          SizedBox(
            width: 72,
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

/// Dashed-border painter for the `[Custom]` tail chip. Mirrors the
/// pattern `InlineEditableText` uses for dashed underlines; kept here
/// so the chip is self-contained.
class _DashedBorderPainter extends CustomPainter {
  final Color color;

  _DashedBorderPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, size.width, size.height),
      const Radius.circular(16),
    );

    // Draw dashed outline by stroking a path with a dash pattern.
    // Flutter's Canvas has no dashed-stroke primitive, so we emulate
    // by walking the RRect's metrics and stroking short segments.
    final path = Path()..addRRect(rrect);
    for (final metric in path.computeMetrics()) {
      const dashLen = 5.0;
      const gapLen = 3.0;
      double distance = 0.0;
      while (distance < metric.length) {
        final next = (distance + dashLen).clamp(0.0, metric.length);
        final segment = metric.extractPath(distance, next);
        canvas.drawPath(segment, paint);
        distance = next + gapLen;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter old) =>
      old.color != color;
}
