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
///   └───── unified presets ─────┘   └ inline add ┘
///
/// **Wave 18.1** — the chips render a single unified list. Canonical
/// seeds and custom additions look identical; long-press on any chip
/// removes it with an Undo SnackBar. The `[Custom]` tail only opens an
/// inline numeric input — long-press on it is a no-op. No corner dot
/// distinguishes a "yours" chip from a seed chip; the practitioner
/// curates the list over time until it reflects their muscle memory.
///
/// Chips rendered by this widget:
///   * Unselected → surfaceRaised fill, textOnDark label.
///   * Selected   → [accentColor] fill, white label.
///   * `[+]` tail → dashed [accentColor] pill (32pt tall, 16pt border
///                  radius, 1.5pt border) with a centred
///                  [Icons.add_rounded] glyph. Tapping toggles INLINE
///                  input mode; no bottom sheet, no modal (R-01, load-
///                  bearing — don't regress to a popup here). Long-press
///                  is a no-op. Wave 18.4 replaced the old "Custom" text
///                  pill with this icon. Wave 18.5 reshaped the outline
///                  from a circle (shortestSide/2 radius) to a proper
///                  16pt-radius pill so the `[+]` reads as the SAME
///                  visual family as the text chips (also 32pt tall,
///                  16pt radius), just slightly narrower and dashed
///                  instead of filled. Internal horizontal padding
///                  dropped 8pt → 6pt to keep the pill compact.
///
/// Storage lives in [PractitionerCustomPresets] as a unified list (MRU
/// cap 8 per controlKey). The first read for a control seeds the
/// canonical defaults; subsequent reads respect any deliberate
/// removals. See `getMerged` for the migration path.
///
/// Haptics:
///   - Tap any chip / `[+]`: selectionClick.
///   - Commit NEW value via Done: mediumImpact.
///   - Commit value that matches an existing chip: selectionClick.
///   - Long-press chip: selectionClick (then undo SnackBar).
///   - Long-press `[+]`: no haptic (no-op).
class PresetChipRow extends StatefulWidget {
  /// Opaque key identifying which preset array in
  /// [PractitionerCustomPresets] to read from. e.g. "reps", "sets",
  /// "hold", "rest".
  final String controlKey;

  /// Canonical seed values for this controlKey. Merged with any stored
  /// customs on FIRST read (post-Wave-18.1 migration) and then persisted
  /// as a single unified list. Subsequent reads just return the stored
  /// list — the seeds here are only used as bootstrap material.
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

  /// Label prefix for the undo SnackBar when a chip is removed.
  /// Defaults to the controlKey capitalised.
  final String? undoLabel;

  /// Whether the chip row can scroll horizontally. Defaults to true.
  /// Callers that host the chip row in a horizontally-constrained space
  /// (e.g. the rest bar, which takes a horizontal swipe for
  /// swipe-to-delete) pass `false` so the ListView doesn't eat the
  /// gesture.
  final bool scrollable;

  const PresetChipRow({
    super.key,
    required this.controlKey,
    required this.canonicalPresets,
    required this.currentValue,
    required this.onChanged,
    required this.accentColor,
    this.displayFormat,
    this.undoLabel,
    this.scrollable = true,
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

  /// Full ordered preset list for this control. Drives both the
  /// initial migration-on-first-read AND the visible chips each build.
  List<num> _presets() {
    return PractitionerCustomPresets.getMerged(
      widget.controlKey,
      widget.canonicalPresets,
    );
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

    final existing = _presets().toSet();
    final alreadyExists = existing.contains(parsed);
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
      // Round 2 — when the chip row lives inside a bottom sheet
      // (ExerciseEditorSheet's Plan tab), the iOS keyboard slides up
      // OVER the inline input. Walk up to the nearest Scrollable and
      // scroll the input row into view so it sits above the keyboard.
      // No-op outside scrollable contexts (the original GestureDetector
      // for the [+] tail simply gets focus and that's fine).
      Scrollable.ensureVisible(
        context,
        alignment: 0.5,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      );
    });
  }

  Future<void> _removeChip(num value) async {
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

    final presets = _presets();

    // Non-scrolling variant uses a Wrap so long lists flow onto
    // additional rows instead of silently hiding chips past the edge
    // (Wave 18.2 — fixed the cap-8 + [Custom] tail overflowing off
    // narrow phones). Wrap has no scrolling so it doesn't contest the
    // outer Dismissible for horizontal drag, and its vertical extent
    // grows as needed — a 2-line wrap reads as ~2 × row height.
    //
    // Wave 18.3 — the outer SizedBox(width: double.infinity) is
    // load-bearing: without a bounded-width parent, the Wrap receives
    // loose horizontal constraints and each child lays out on its own
    // "run" (i.e. stacks vertically). Even when PresetChipRow lives
    // inside Expanded, that bound only reaches the Padding; forcing
    // width: double.infinity here pins the Wrap's parent axis so chips
    // flow horizontally and wrap onto a new row only when needed.
    if (!widget.scrollable) {
      final wrapChildren = <Widget>[
        for (final value in presets)
          _Chip(
            label: _format(value),
            selected: value == widget.currentValue,
            accentColor: widget.accentColor,
            onTap: () {
              HapticFeedback.selectionClick();
              widget.onChanged(value);
            },
            onLongPress: () => _removeChip(value),
          ),
        _CustomTail(
          accentColor: widget.accentColor,
          onTap: _openCustomInput,
        ),
      ];
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: SizedBox(
          width: double.infinity,
          child: Wrap(
            direction: Axis.horizontal,
            alignment: WrapAlignment.start,
            crossAxisAlignment: WrapCrossAlignment.center,
            // Wave 18.4 — tightened from 6pt to 4pt so a full canonical
            // + [+] + a custom or two fits one line on iPhone.
            // Wave 18.5 — tightened further 4pt → 2pt so three customs
            // + canonical + [+] all fit one line on iPhone 17 Pro.
            spacing: 2,
            runSpacing: 2,
            children: wrapChildren,
          ),
        ),
      );
    }

    // Scrollable variant (PLAN rows): horizontal ListView.
    // Wave 18.4 — padding tightened 6pt → 4pt per chip (same as Wrap).
    // Wave 18.5 — tightened further 4pt → 2pt to mirror the Wrap branch.
    final children = <Widget>[
      for (final value in presets)
        Padding(
          padding: const EdgeInsets.only(right: 2),
          child: _Chip(
            label: _format(value),
            selected: value == widget.currentValue,
            accentColor: widget.accentColor,
            onTap: () {
              HapticFeedback.selectionClick();
              widget.onChanged(value);
            },
            onLongPress: () => _removeChip(value),
          ),
        ),
      // [+] tail — long-press is a no-op (spec: Wave 18.1; glyph: 18.4).
      _CustomTail(
        accentColor: widget.accentColor,
        onTap: _openCustomInput,
      ),
    ];

    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        children: children,
      ),
    );
  }
}

/// Chip — one value in the practitioner's curated list. Long-press
/// removes any chip (Wave 18.1 — canonical vs custom distinction is
/// gone; the chips look identical and behave identically).
class _Chip extends StatelessWidget {
  final String label;
  final bool selected;
  final Color accentColor;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _Chip({
    required this.label,
    required this.selected,
    required this.accentColor,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    // Wave 18.3.1 — IntrinsicWidth forces the Container to size to its
    // text's natural width. Without it, `Container(alignment: center)`
    // with bounded parent constraints (as inside the non-scrollable
    // Wrap) expands to the full parent width, making each chip a full
    // row and producing the "chips stacked vertically" regression.
    return IntrinsicWidth(
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        behavior: HitTestBehavior.opaque,
        child: Container(
          height: 32,
          // Wave 18.5 — horizontal padding tightened 12pt → 10pt so
          // three customs + canonical + [+] fit one line on iPhone.
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: selected ? accentColor : AppColors.surfaceRaised,
            borderRadius: BorderRadius.circular(16),
          ),
          alignment: Alignment.center,
          // Wave 18.2 — `height: 1.0` strips Inter's natural descender
          // padding so the label sits dead-centre inside the 32pt pill.
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 13,
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

/// Dashed-border `[+]` tail chip. Tapping opens the inline input.
/// Long-press is a no-op per Wave 18.1 — only value chips can be
/// removed, and the tail isn't a value.
///
/// Wave 18.4 — retired the "Custom" text pill for a 32×32 dashed circle
/// with a centred [Icons.add_rounded] glyph. Wave 18.5 reshaped the
/// circle into a proper 32pt-tall, 16pt-radius dashed pill so the tail
/// sits in the same visual family as the text chips (which are also
/// 32pt tall with 16pt radius). Wave 18.6 bumped the horizontal padding
/// 6pt → 12pt so the pill is ~42pt wide instead of ~30pt — unambiguously
/// pill-shaped, visual weight matching the text chips.
///
/// Wave 18.7 — **structural fix**: CustomPaint now wraps the Container
/// instead of sitting inside its padding. Before, the dashed border was
/// drawn on the canvas INSIDE the 12pt padding, so the pill hugged the
/// 18pt icon with ~0 visible padding and the 12pt ended up as invisible
/// margin outside the visible border. Swapping the nesting paints the
/// dashed border on the FULL pill area and leaves the 12pt padding as
/// real space between the border and the icon. The pill finally reads
/// as a padded pill — ~42pt wide with visible room around the centred
/// icon. Intrinsic width preserved via the outer [IntrinsicWidth] so
/// the pill still sizes to icon + padding × 2.
///
/// Wave 18.8 — horizontal padding tightened 12pt → 10pt. Live QA showed
/// the ~42pt-wide pill was fractionally too wide next to the text
/// chips; 10pt × 2 + 18pt icon = ~38pt, a leaner match.
class _CustomTail extends StatelessWidget {
  final Color accentColor;
  final VoidCallback onTap;

  const _CustomTail({
    required this.accentColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return IntrinsicWidth(
      child: GestureDetector(
        onTap: onTap,
        // Long-press on [+] is explicitly a no-op (Wave 18.1). No
        // haptic, no action.
        behavior: HitTestBehavior.opaque,
        // Wave 18.7 — CustomPaint wraps the padded Container so the
        // dashed border paints on the full pill area, and the 12pt
        // horizontal padding lives INSIDE the border. Before the swap
        // the border was painted on the reduced canvas (inside padding)
        // so the pill looked like it had no padding at all.
        child: CustomPaint(
          painter: _DashedBorderPainter(color: accentColor),
          child: Container(
            height: 32,
            // Wave 18.8 — tightened 12pt → 10pt so the pill is ~38pt
            // wide instead of ~42pt, matching the text chips' visual
            // weight more closely.
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.center,
            child: Icon(
              Icons.add_rounded,
              size: 18,
              color: accentColor,
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

/// Dashed-border painter for the `[+]` tail chip. Mirrors the pattern
/// `InlineEditableText` uses for dashed underlines; kept here so the
/// chip is self-contained.
///
/// Wave 18.5 — corner radius fixed at 16pt (matching the text chips'
/// BorderRadius.circular(16)) so the outline traces a proper pill, not
/// a circle. With a 32pt-tall container and a radius-16 RRect, the
/// ends are rounded caps; with any extra horizontal width (from the
/// 6pt padding around the 18pt icon, roughly 30pt wide total), the
/// pill reads as "the same family as a text chip, just narrower".
class _DashedBorderPainter extends CustomPainter {
  final Color color;

  _DashedBorderPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    // Fixed 16pt radius matches the text chip's BorderRadius.circular(16),
    // so the dashed tail reads as the same visual family — a pill, not
    // a circle. Wave 18.6 → 18.8 — with 10pt horizontal padding the
    // container is ~38pt wide at 32pt tall, so the 16pt radius traces
    // a clean pill with visible straight sides between the rounded caps.
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
