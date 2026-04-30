import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/exercise_set.dart';
import '../theme.dart';
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
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
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
                textAlign: TextAlign.center, style: headerStyle),
          ),
          Expanded(
            flex: 2,
            child: Text('REPS',
                textAlign: TextAlign.center, style: headerStyle),
          ),
          Expanded(
            flex: 2,
            child: Text('HOLD',
                textAlign: TextAlign.center, style: headerStyle),
          ),
          Expanded(
            flex: 3,
            child: Text('WEIGHT',
                textAlign: TextAlign.center, style: headerStyle),
          ),
          Expanded(
            flex: 3,
            child: Text('BREATHER',
                textAlign: TextAlign.center, style: headerStyle),
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
                    flex: 2,
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
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
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
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: color,
                  fontStyle: isGhost ? FontStyle.italic : FontStyle.normal,
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildEditorEyebrow(target, set.position),
          const SizedBox(height: 8),
          if (target == _DoseEditorTarget.reps)
            _buildChipRow(
              presets: const [5, 8, 10, 12, 15],
              currentValue: set.reps,
              onPick: (v) => _commitReps(index, v),
            ),
          if (target == _DoseEditorTarget.hold)
            _buildChipRow(
              presets: const [0, 5, 10, 30, 60],
              currentValue: set.holdSeconds,
              labelFor: (v) => v == 0 ? 'Off' : '$v',
              onPick: (v) => _commitHold(index, v),
            ),
          if (target == _DoseEditorTarget.weight)
            WeightSlider(
              valueKg: set.weightKg,
              onChanged: (v) => _commitWeight(index, v),
            ),
          if (target == _DoseEditorTarget.breather)
            _buildChipRow(
              presets: const [15, 30, 45, 60, 90, 120],
              currentValue: set.breatherSecondsAfter,
              onPick: (v) => _commitBreather(index, v),
            ),
        ],
      ),
    );
  }

  Widget _buildEditorEyebrow(_DoseEditorTarget target, int position) {
    final label = switch (target) {
      _DoseEditorTarget.reps => 'Reps · set $position',
      _DoseEditorTarget.hold => 'Hold · set $position',
      _DoseEditorTarget.weight => 'Weight · set $position',
      _DoseEditorTarget.breather => 'Breather · after set $position',
    };
    final hint = switch (target) {
      _DoseEditorTarget.reps => 'tap a value, or re-tap to dismiss',
      _DoseEditorTarget.hold => 'duration of the held position',
      _DoseEditorTarget.weight => 'snaps to 2.5 kg steps · 0–200 kg',
      _DoseEditorTarget.breather => 'rest before the next set',
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontFamily: 'Inter',
            fontSize: 10,
            fontWeight: FontWeight.w700,
            color: AppColors.primary,
            letterSpacing: 0.6,
          ),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            hint,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 10,
              fontWeight: FontWeight.w500,
              color: AppColors.textSecondaryOnDark,
              letterSpacing: 0.3,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildChipRow({
    required List<int> presets,
    required int currentValue,
    required ValueChanged<int> onPick,
    String Function(int)? labelFor,
  }) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final v in presets)
          _PresetChip(
            label: labelFor != null ? labelFor(v) : '$v',
            selected: v == currentValue,
            onTap: () {
              HapticFeedback.selectionClick();
              onPick(v);
            },
          ),
        _CustomChip(
          onTap: () => _openCustomInput(currentValue, onPick, labelFor),
        ),
      ],
    );
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

  /// Open a barebones AlertDialog for custom-value entry. Use sparingly —
  /// this is the only popup left in the editor surface (the user's
  /// no-popup rule applies to entity creation, not numeric custom input).
  Future<void> _openCustomInput(
    int currentValue,
    ValueChanged<int> onPick,
    String Function(int)? labelFor,
  ) async {
    final controller =
        TextEditingController(text: currentValue.toString());
    final result = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceRaised,
        title: const Text(
          'Custom value',
          style: TextStyle(
            fontFamily: 'Montserrat',
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: AppColors.textOnDark,
          ),
        ),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          style: const TextStyle(
            fontFamily: 'JetBrainsMono',
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: AppColors.textOnDark,
          ),
          decoration: const InputDecoration(
            isDense: true,
            border: OutlineInputBorder(),
          ),
          onSubmitted: (text) {
            final parsed = int.tryParse(text.trim());
            if (parsed != null && parsed >= 0) {
              Navigator.of(ctx).pop(parsed);
            } else {
              Navigator.of(ctx).pop();
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final parsed = int.tryParse(controller.text.trim());
              if (parsed != null && parsed >= 0) {
                Navigator.of(ctx).pop(parsed);
              } else {
                Navigator.of(ctx).pop();
              }
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result != null) {
      onPick(result);
    }
  }

  String _formatKg(double kg) {
    if (kg == kg.roundToDouble()) {
      return kg.toStringAsFixed(0);
    }
    return kg.toStringAsFixed(1);
  }
}

class _PresetChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _PresetChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        constraints: const BoxConstraints(minWidth: 44),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? AppColors.primary : AppColors.surfaceBase,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.surfaceBorder,
            width: 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color:
                selected ? Colors.white : AppColors.textSecondaryOnDark,
          ),
        ),
      ),
    );
  }
}

class _CustomChip extends StatelessWidget {
  final VoidCallback onTap;
  const _CustomChip({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        constraints: const BoxConstraints(minWidth: 44),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.surfaceBase,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: AppColors.brandTintBorder,
            width: 1,
          ),
        ),
        child: const Text(
          'Custom…',
          style: TextStyle(
            fontFamily: 'JetBrainsMono',
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: AppColors.primary,
            letterSpacing: 0.3,
          ),
        ),
      ),
    );
  }
}
