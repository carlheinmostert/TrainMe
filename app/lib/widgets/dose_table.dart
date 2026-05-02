import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/exercise_set.dart';
import '../theme.dart';
import 'inline_editable_text.dart';
import 'preset_chip_row.dart';
import 'undo_snackbar.dart';
import 'weight_slider.dart';

/// The cell currently being edited (none = collapsed table).
enum _DoseEditorTarget { reps, hold, weight, breather }

/// DOSE table — per-set editor for the Wave: per-set DOSE relational
/// model. Renders [ExerciseSet] rows with `Set / Reps / Hold / Weight /
/// Breather` columns; each cell drops an inline editor below its row
/// when tapped. Mirrors `docs/design/mockups/exercise-card-dose-table.html`.
///
/// Drag-to-reorder uses [ReorderableListView]; the row body lays out
/// like a table via fixed column flex. Swipe-delete uses [Dismissible]
/// with an immediate fire + undo SnackBar (R-01 — no confirmation).
///
/// Layout note: this widget assumes it sits inside a vertically
/// scrollable parent (the editor sheet body). The reorderable list is
/// non-shrink-wrapped — wrap me in a bounded-height container if you
/// hit "unbounded constraints". The host `ExerciseEditorSheet` provides
/// that container via the sheet body's `SingleChildScrollView`.
class DoseTable extends StatefulWidget {
  /// Current set list. The widget renders rows in list order; [position]
  /// values are recomputed on every save (1-based).
  final List<ExerciseSet> sets;

  /// Fired whenever the practitioner adds / edits / reorders / deletes a
  /// row. The list passed in already has its `position` fields renumbered.
  final ValueChanged<List<ExerciseSet>> onSetsChanged;

  /// When non-null, render the circuit-context banner + reconciliation
  /// ghost rows. `cycles > sets.length` → tail "ghost-repeat" row of
  /// the last real set; `cycles < sets.length` → trailing rows render
  /// as "won't play" ghost-skip.
  final int? circuitCycles;

  const DoseTable({
    super.key,
    required this.sets,
    required this.onSetsChanged,
    this.circuitCycles,
  });

  @override
  State<DoseTable> createState() => _DoseTableState();
}

class _DoseTableState extends State<DoseTable> {
  /// Index of the row currently expanded for editing, or null.
  int? _activeRowIndex;
  _DoseEditorTarget? _activeTarget;

  @override
  Widget build(BuildContext context) {
    final isCircuit = widget.circuitCycles != null;
    final cycles = widget.circuitCycles ?? widget.sets.length;
    final ghostRepeatCount =
        (isCircuit && cycles > widget.sets.length && widget.sets.isNotEmpty)
            ? cycles - widget.sets.length
            : 0;
    final ghostSkipStartIndex =
        (isCircuit && cycles < widget.sets.length) ? cycles : -1;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (isCircuit) _buildCircuitBanner(cycles),
        _buildHeaderRow(),
        // Reorderable rows. We avoid `ReorderableListView.builder` because
        // it forces its own scroll view; instead we hand-roll a Column
        // with a long-press drag pattern via [ReorderableListView] hosted
        // inside a `LimitedBox` parent. To keep a flat structure inside
        // a scroll view, render rows as plain widgets and wire reorder
        // through a simple `ReorderableListView` with `shrinkWrap: true,
        // physics: NeverScrollableScrollPhysics()`.
        ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          onReorder: _handleReorder,
          proxyDecorator: _proxyDecorator,
          children: [
            for (int i = 0; i < widget.sets.length; i++)
              _buildRow(i, widget.sets[i], isGhostSkip: ghostSkipStartIndex >= 0 && i >= ghostSkipStartIndex),
          ],
        ),
        if (ghostRepeatCount > 0)
          _buildGhostRepeatRows(ghostRepeatCount, widget.sets.last, cycles),
        if (ghostSkipStartIndex >= 0)
          Padding(
            padding: const EdgeInsets.only(left: 12, top: 4),
            child: Text(
              'Sets ${ghostSkipStartIndex + 1}+ won’t play (cycles = $cycles)',
              style: const TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: AppColors.primary,
                fontStyle: FontStyle.italic,
                letterSpacing: 0.4,
              ),
            ),
          ),
        const SizedBox(height: 12),
        _buildAddSetCta(),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Header
  // ---------------------------------------------------------------------------

  Widget _buildCircuitBanner(int cycles) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.brandTintBg,
        borderRadius: const BorderRadius.only(
          topRight: Radius.circular(8),
          bottomRight: Radius.circular(8),
        ),
        border: const Border(
          left: BorderSide(color: AppColors.primary, width: 2),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.loop_rounded,
            size: 16,
            color: AppColors.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Each set in this list plays as one round of the circuit, in order. '
              'Cycles set to $cycles. If your cycle count is higher than the number '
              'of sets, the last set repeats. If lower, trailing sets won’t play.',
              style: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 12,
                color: AppColors.textSecondaryOnDark,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeaderRow() {
    const headerStyle = TextStyle(
      fontFamily: 'Inter',
      fontSize: 10,
      fontWeight: FontWeight.w700,
      color: AppColors.textSecondaryOnDark,
      letterSpacing: 0.6,
    );
    // Horizontal padding 4 (not 8) to match the row's
    // EdgeInsets.symmetric(horizontal: 4) below — keeps every header cell
    // aligned with its value cell. With 8/4 they drifted by ~2pt per
    // column and the BREATHER header wrapped on iOS Dynamic Type ≥ 1.1×.
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 8),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: AppColors.surfaceBorder, width: 1),
        ),
      ),
      child: Row(
        children: const [
          SizedBox(
            width: 36,
            child: Text('SET',
                textAlign: TextAlign.center,
                style: headerStyle,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.fade),
          ),
          Expanded(
            flex: 2,
            child: Text('REPS',
                textAlign: TextAlign.center,
                style: headerStyle,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.fade),
          ),
          Expanded(
            flex: 3,
            child: Text('HOLD',
                textAlign: TextAlign.center,
                style: headerStyle,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.fade),
          ),
          Expanded(
            flex: 3,
            child: Text('WEIGHT',
                textAlign: TextAlign.center,
                style: headerStyle,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.fade),
          ),
          Expanded(
            flex: 3,
            child: Text('BREATHER',
                textAlign: TextAlign.center,
                style: headerStyle,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.fade),
          ),
          SizedBox(width: 28),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Row
  // ---------------------------------------------------------------------------

  Widget _buildRow(int index, ExerciseSet set, {required bool isGhostSkip}) {
    final isActiveRow = _activeRowIndex == index;
    return Column(
      key: ValueKey('dose-row-${set.id}'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Dismissible(
          key: ValueKey('dose-dismiss-${set.id}'),
          direction: DismissDirection.endToStart,
          background: Container(
            color: AppColors.error,
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: const Icon(Icons.delete_outline, color: Colors.white),
          ),
          onDismissed: (_) => _deleteRow(index),
          child: Container(
            decoration: BoxDecoration(
              color: isGhostSkip
                  ? Colors.transparent
                  : (isActiveRow
                      ? AppColors.primary.withValues(alpha: 0.04)
                      : Colors.transparent),
              border: Border(
                left: BorderSide(
                  color: isActiveRow
                      ? AppColors.primary
                      : Colors.transparent,
                  width: 2,
                ),
                bottom: BorderSide(
                  color: AppColors.surfaceBorder,
                  width: 1,
                ),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
              child: Row(
                children: [
                  // Position pill — coral mono.
                  SizedBox(
                    width: 36,
                    child: Center(
                      child: _buildPositionPill(set.position, ghost: isGhostSkip),
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: _buildCellTap(
                      label: '${set.reps}',
                      unit: null,
                      isActive: isActiveRow &&
                          _activeTarget == _DoseEditorTarget.reps,
                      isGhost: isGhostSkip,
                      onTap: () =>
                          _toggleEditor(index, _DoseEditorTarget.reps),
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: _buildCellTap(
                      label: set.holdSeconds == 0
                          ? '—'
                          : '${set.holdSeconds}',
                      unit: set.holdSeconds == 0 ? null : 's',
                      isNa: set.holdSeconds == 0,
                      isActive: isActiveRow &&
                          _activeTarget == _DoseEditorTarget.hold,
                      isGhost: isGhostSkip,
                      onTap: () =>
                          _toggleEditor(index, _DoseEditorTarget.hold),
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: _buildCellTap(
                      label: set.weightKg == null
                          ? '—'
                          : _formatKg(set.weightKg!),
                      unit: set.weightKg == null ? null : 'kg',
                      isNa: set.weightKg == null,
                      isActive: isActiveRow &&
                          _activeTarget == _DoseEditorTarget.weight,
                      isGhost: isGhostSkip,
                      onTap: () =>
                          _toggleEditor(index, _DoseEditorTarget.weight),
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: _buildCellTap(
                      label: '${set.breatherSecondsAfter}',
                      unit: 's',
                      isActive: isActiveRow &&
                          _activeTarget == _DoseEditorTarget.breather,
                      isGhost: isGhostSkip,
                      onTap: () =>
                          _toggleEditor(index, _DoseEditorTarget.breather),
                    ),
                  ),
                  // Drag handle — long-press to reorder.
                  SizedBox(
                    width: 28,
                    child: ReorderableDragStartListener(
                      index: index,
                      child: const Icon(
                        Icons.drag_indicator_rounded,
                        size: 18,
                        color: AppColors.textSecondaryOnDark,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (isActiveRow) _buildEditorBlock(index, set),
      ],
    );
  }

  Widget _buildPositionPill(int position, {required bool ghost}) {
    return Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        color: ghost ? Colors.transparent : AppColors.brandTintBg,
        shape: BoxShape.circle,
        border: Border.all(
          color: ghost
              ? AppColors.textSecondaryOnDark.withValues(alpha: 0.6)
              : AppColors.brandTintBorder,
          width: 1,
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        '$position',
        style: TextStyle(
          fontFamily: 'JetBrainsMono',
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: ghost ? AppColors.textSecondaryOnDark : AppColors.primary,
          fontStyle: ghost ? FontStyle.italic : FontStyle.normal,
        ),
      ),
    );
  }

  Widget _buildCellTap({
    required String label,
    required String? unit,
    bool isNa = false,
    bool isActive = false,
    bool isGhost = false,
    required VoidCallback onTap,
  }) {
    final color = isGhost
        ? AppColors.textSecondaryOnDark
        : (isActive
            ? AppColors.primary
            : (isNa
                ? AppColors.textSecondaryOnDark
                : AppColors.textOnDark));
    return InkWell(
      onTap: isGhost ? null : onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        // Margin removed (was horizontal: 4) and padding tightened (was
        // horizontal: 6) to recover ~12pt of cell width — fractional
        // weights "100.5" / "197.5" were ellipsizing inside the WEIGHT
        // cell because margin + padding ate ~20pt before the value's
        // 37pt glyph budget could land. Cells now sit edge-to-edge with
        // a thin inner padding and the active border still stands out.
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        decoration: BoxDecoration(
          color: isActive
              ? AppColors.brandTintBg
              : (isGhost
                  ? Colors.transparent
                  : Colors.white.withValues(alpha: 0.03)),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isActive ? AppColors.brandTintBorder : Colors.transparent,
            width: 1,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Flexible(
              child: isGhost
                  ? Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: 'JetBrainsMono',
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: color,
                        fontStyle: FontStyle.italic,
                      ),
                    )
                  : DashedUnderline(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontFamily: 'JetBrainsMono',
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: color,
                          fontStyle: FontStyle.normal,
                        ),
                      ),
                    ),
            ),
            if (unit != null && !isNa) ...[
              const SizedBox(width: 3),
              Text(
                unit,
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: isActive
                      ? AppColors.primary.withValues(alpha: 0.85)
                      : AppColors.textSecondaryOnDark,
                  letterSpacing: 0.4,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _proxyDecorator(Widget child, int index, Animation<double> animation) {
    return Material(
      color: AppColors.surfaceRaised,
      elevation: 8,
      shadowColor: Colors.black.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(8),
      child: child,
    );
  }

  // ---------------------------------------------------------------------------
  // Editor block (chip rows + weight slider)
  // ---------------------------------------------------------------------------

  Widget _buildEditorBlock(int index, ExerciseSet set) {
    final target = _activeTarget;
    if (target == null) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.04),
        border: const Border(
          left: BorderSide(color: AppColors.primary, width: 2),
          bottom: BorderSide(color: AppColors.surfaceBorder, width: 1),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      // Eyebrow label + hint removed — pills speak for themselves and the
      // user dismisses by tapping a value (the chip-row callbacks now also
      // collapse the editor) or tapping a different cell.
      child: switch (target) {
        _DoseEditorTarget.reps => PresetChipRow(
            controlKey: 'reps',
            canonicalPresets: const <num>[5, 8, 10, 12, 15],
            currentValue: set.reps,
            accentColor: AppColors.primary,
            undoLabel: 'reps',
            scrollable: false,
            onChanged: (v) {
              _commitReps(index, v.round());
              _closeEditor();
            },
          ),
        _DoseEditorTarget.hold => PresetChipRow(
            controlKey: 'hold',
            canonicalPresets: const <num>[0, 5, 10, 30, 60],
            currentValue: set.holdSeconds,
            accentColor: AppColors.primary,
            displayFormat: (v) => v == 0 ? 'Off' : '${v.toInt()}s',
            undoLabel: 'hold',
            scrollable: false,
            onChanged: (v) {
              _commitHold(index, v.round());
              _closeEditor();
            },
          ),
        // Weight is a continuous slider. onCommit fires on drag-end or
        // tap-to-position (Slider.onChangeEnd) so the editor block
        // dismisses on commit, matching the chip-row pills above.
        _DoseEditorTarget.weight => WeightSlider(
            valueKg: set.weightKg,
            onChanged: (v) => _commitWeight(index, v),
            onCommit: _closeEditor,
          ),
        _DoseEditorTarget.breather => PresetChipRow(
            controlKey: 'breather',
            canonicalPresets: const <num>[15, 30, 45, 60, 90, 120],
            currentValue: set.breatherSecondsAfter,
            accentColor: AppColors.rest,
            displayFormat: (v) => '${v.toInt()}s',
            undoLabel: 'breather',
            scrollable: false,
            onChanged: (v) {
              _commitBreather(index, v.round());
              _closeEditor();
            },
          ),
      },
    );
  }

  void _closeEditor() {
    setState(() {
      _activeRowIndex = null;
      _activeTarget = null;
    });
  }

  // ---------------------------------------------------------------------------
  // Add Set CTA
  // ---------------------------------------------------------------------------

  Widget _buildAddSetCta() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: _addSet,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.brandTintBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: AppColors.brandTintBorder,
                width: 1,
                style: BorderStyle.solid,
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 16,
                  height: 16,
                  decoration: const BoxDecoration(
                    color: AppColors.primary,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: const Icon(Icons.add, size: 13, color: Colors.white),
                ),
                const SizedBox(width: 8),
                const Text(
                  'Add Set',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppColors.primary,
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'Copies last set’s values',
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 11,
            fontStyle: FontStyle.italic,
            color: AppColors.textSecondaryOnDark,
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Ghost-repeat (cycles > rows)
  // ---------------------------------------------------------------------------

  Widget _buildGhostRepeatRows(int count, ExerciseSet template, int cycles) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (int i = 0; i < count; i++)
          Container(
            decoration: const BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: AppColors.brandTintBorder,
                  width: 2,
                ),
                bottom: BorderSide(
                  color: AppColors.surfaceBorder,
                  width: 1,
                ),
              ),
            ),
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            child: Opacity(
              opacity: 0.45,
              child: Row(
                children: [
                  SizedBox(
                    width: 36,
                    child: Center(
                      child: _buildPositionPill(
                        template.position,
                        ghost: true,
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: _buildCellTap(
                      label: '${template.reps}',
                      unit: null,
                      isGhost: true,
                      onTap: () {},
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: _buildCellTap(
                      label: template.holdSeconds == 0
                          ? '—'
                          : '${template.holdSeconds}',
                      unit: template.holdSeconds == 0 ? null : 's',
                      isNa: template.holdSeconds == 0,
                      isGhost: true,
                      onTap: () {},
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: _buildCellTap(
                      label: template.weightKg == null
                          ? '—'
                          : _formatKg(template.weightKg!),
                      unit: template.weightKg == null ? null : 'kg',
                      isNa: template.weightKg == null,
                      isGhost: true,
                      onTap: () {},
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: _buildCellTap(
                      label: '${template.breatherSecondsAfter}',
                      unit: 's',
                      isGhost: true,
                      onTap: () {},
                    ),
                  ),
                  const SizedBox(width: 28),
                ],
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(left: 12, top: 4),
          child: Text(
            'Round${count > 1 ? 's' : ''} ${widget.sets.length + 1}'
            '${count > 1 ? '–$cycles' : ''} — repeats Set ${template.position}',
            style: const TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: AppColors.textSecondaryOnDark,
              fontStyle: FontStyle.italic,
              letterSpacing: 0.4,
            ),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Mutations
  // ---------------------------------------------------------------------------

  void _toggleEditor(int index, _DoseEditorTarget target) {
    HapticFeedback.selectionClick();
    setState(() {
      if (_activeRowIndex == index && _activeTarget == target) {
        _activeRowIndex = null;
        _activeTarget = null;
      } else {
        _activeRowIndex = index;
        _activeTarget = target;
      }
    });
  }

  List<ExerciseSet> _renumber(List<ExerciseSet> sets) {
    return [
      for (int i = 0; i < sets.length; i++)
        sets[i].copyWith(position: i + 1),
    ];
  }

  void _emit(List<ExerciseSet> next) {
    widget.onSetsChanged(_renumber(next));
  }

  void _commitReps(int index, int value) {
    final next = [...widget.sets];
    next[index] = next[index].copyWith(reps: value);
    _emit(next);
  }

  void _commitHold(int index, int value) {
    final next = [...widget.sets];
    next[index] = next[index].copyWith(holdSeconds: value);
    _emit(next);
  }

  void _commitWeight(int index, double? value) {
    final next = [...widget.sets];
    next[index] = next[index].copyWith(weightKg: value);
    _emit(next);
  }

  void _commitBreather(int index, int value) {
    final next = [...widget.sets];
    next[index] = next[index].copyWith(breatherSecondsAfter: value);
    _emit(next);
  }

  void _addSet() {
    HapticFeedback.mediumImpact();
    final base = widget.sets.isNotEmpty
        ? widget.sets.last
        : ExerciseSet.create(position: 1);
    final fresh = ExerciseSet.create(
      position: widget.sets.length + 1,
      reps: base.reps,
      holdSeconds: base.holdSeconds,
      weightKg: base.weightKg,
      breatherSecondsAfter: base.breatherSecondsAfter,
    );
    _emit([...widget.sets, fresh]);
  }

  void _deleteRow(int index) {
    final removed = widget.sets[index];
    HapticFeedback.lightImpact();
    final next = [...widget.sets]..removeAt(index);
    setState(() {
      if (_activeRowIndex == index) {
        _activeRowIndex = null;
        _activeTarget = null;
      }
    });
    _emit(next);
    showUndoSnackBar(
      context,
      label: 'Set ${removed.position} deleted',
      onUndo: () {
        final restored = [...widget.sets];
        final reinsertAt = index.clamp(0, restored.length);
        restored.insert(reinsertAt, removed);
        _emit(restored);
      },
    );
  }

  void _handleReorder(int oldIndex, int newIndex) {
    HapticFeedback.lightImpact();
    final next = [...widget.sets];
    int adj = newIndex;
    if (newIndex > oldIndex) adj -= 1;
    final moved = next.removeAt(oldIndex);
    next.insert(adj, moved);
    setState(() {
      _activeRowIndex = null;
      _activeTarget = null;
    });
    _emit(next);
  }

  String _formatKg(double kg) {
    if (kg == kg.roundToDouble()) {
      return kg.toStringAsFixed(0);
    }
    return kg.toStringAsFixed(1);
  }
}

