import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/exercise_capture.dart';
import '../models/exercise_set.dart';
import '../models/session.dart';
import '../theme.dart';
import 'dose_table.dart';
import 'media_viewer_body.dart';
import 'preset_chip_row.dart';

/// Which tab the editor sheet should land on when first opened.
enum ExerciseEditorTab { dose, notes, preview, settings }

/// The tabbed bottom-sheet editor for an exercise.
///
/// Mounts via [showExerciseEditorSheet]. Hosts four tabs:
///   * **Dose** — `DoseTable` editing per-set rows.
///   * **Notes** — multiline `TextField` for practitioner-only notes.
///   * **Preview** — embeds `MediaViewerBody` so the practitioner can
///     verify what the client will see, scoped to the active exercise.
///   * **Settings** — preset chip rows for `prepSeconds` +
///     `videoRepsPerLoop` (rarely-changed metadata).
///
/// The sheet runs at one of two snap detents (medium ~60%, large ~92%);
/// the drag handle and `DraggableScrollableSheet` snap behaviour mirror
/// `circuit_control_sheet.dart`. Tab swipe horizontally is delegated to
/// an internal `PageView`. The Notes tab promotes the sheet to large
/// when the textarea gains focus so the keyboard doesn't eat the field.
///
/// On every meaningful edit the sheet fires [onChanged] with a fresh
/// `ExerciseCapture` so the Studio screen can persist + re-render
/// without waiting for the sheet to dismiss.
Future<void> showExerciseEditorSheet({
  required BuildContext context,
  required ExerciseCapture exercise,
  required ValueChanged<ExerciseCapture> onChanged,
  Session? session,
  ValueChanged<Session>? onSessionUpdate,
  ExerciseEditorTab initialTab = ExerciseEditorTab.dose,
}) async {
  HapticFeedback.selectionClick();
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.45),
    useSafeArea: true,
    // The inner DraggableScrollableSheet owns drag behaviour. Letting
    // showModalBottomSheet's own enableDrag also fight for vertical
    // drags eats inner widgets (weight slider, trim handles) and the
    // sheet refuses to expand via the drag handle.
    enableDrag: false,
    builder: (sheetCtx) => ExerciseEditorSheet(
      exercise: exercise,
      onChanged: onChanged,
      session: session,
      onSessionUpdate: onSessionUpdate,
      initialTab: initialTab,
    ),
  );
}

/// The sheet body. Exposed publicly so tests / future callers can mount
/// it inside a custom host without going through [showExerciseEditorSheet].
class ExerciseEditorSheet extends StatefulWidget {
  /// Exercise being edited. The sheet keeps a local mirror so it can
  /// fire [onChanged] with the freshly-mutated copy on every edit.
  final ExerciseCapture exercise;

  /// Called whenever the practitioner mutates the exercise (sets,
  /// notes, prep seconds, video reps per loop). The Studio screen wires
  /// this to its `_updateExercise` so SQLite + in-memory + UI stay in
  /// step.
  final ValueChanged<ExerciseCapture> onChanged;

  /// Optional parent session — passed through to `MediaViewerBody` for
  /// crossfade timings + circuit-cycle reconciliation in the Dose tab.
  final Session? session;

  /// Optional session-update callback — wired to the Preview tab's
  /// `MediaViewerBody.onSessionUpdate` so crossfade-tuner edits inside
  /// the embed propagate back to the Studio screen.
  final ValueChanged<Session>? onSessionUpdate;

  /// Tab to land on when the sheet opens. Defaults to Dose.
  final ExerciseEditorTab initialTab;

  const ExerciseEditorSheet({
    super.key,
    required this.exercise,
    required this.onChanged,
    this.session,
    this.onSessionUpdate,
    this.initialTab = ExerciseEditorTab.dose,
  });

  @override
  State<ExerciseEditorSheet> createState() => _ExerciseEditorSheetState();
}

class _ExerciseEditorSheetState extends State<ExerciseEditorSheet> {
  static const double _kInitialDetent = 0.55;
  static const double _kMinDetent = 0.30;
  static const double _kMaxDetent = 0.95;

  late final DraggableScrollableController _sheetController;
  late final PageController _pageController;
  late ExerciseCapture _exercise;
  int _activeTabIndex = 0;
  final FocusNode _notesFocusNode = FocusNode();
  late TextEditingController _notesController;

  @override
  void initState() {
    super.initState();
    _exercise = widget.exercise;
    _activeTabIndex = _tabIndexFor(widget.initialTab);
    _sheetController = DraggableScrollableController();
    _pageController = PageController(initialPage: _activeTabIndex);
    _notesController = TextEditingController(text: _exercise.notes ?? '');
    _notesFocusNode.addListener(_onNotesFocusChanged);
  }

  @override
  void dispose() {
    _notesFocusNode.removeListener(_onNotesFocusChanged);
    _notesFocusNode.dispose();
    _notesController.dispose();
    _pageController.dispose();
    _sheetController.dispose();
    super.dispose();
  }

  int _tabIndexFor(ExerciseEditorTab t) {
    switch (t) {
      case ExerciseEditorTab.dose:
        return 0;
      case ExerciseEditorTab.notes:
        return 1;
      case ExerciseEditorTab.preview:
        return 2;
      case ExerciseEditorTab.settings:
        return 3;
    }
  }

  void _onNotesFocusChanged() {
    if (!_notesFocusNode.hasFocus) return;
    if (!_sheetController.isAttached) return;
    // Promote to the larger detent so the keyboard doesn't squash the
    // textarea. Animation matches the sheet's natural snap motion.
    _sheetController.animateTo(
      _kMaxDetent,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  void _switchTab(int next) {
    if (next == _activeTabIndex) return;
    HapticFeedback.selectionClick();
    setState(() => _activeTabIndex = next);
    _pageController.animateToPage(
      next,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  void _onPageChanged(int next) {
    if (next == _activeTabIndex) return;
    setState(() => _activeTabIndex = next);
  }

  void _emit(ExerciseCapture next) {
    setState(() => _exercise = next);
    widget.onChanged(next);
  }

  void _onSetsChanged(List<ExerciseSet> sets) {
    _emit(_exercise.copyWith(sets: sets));
  }

  void _onNotesChanged(String text) {
    _emit(_exercise.copyWith(notes: text));
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      controller: _sheetController,
      initialChildSize: _kInitialDetent,
      minChildSize: _kMinDetent,
      maxChildSize: _kMaxDetent,
      snap: true,
      snapSizes: const [_kMinDetent, _kInitialDetent, _kMaxDetent],
      expand: false,
      builder: (ctx, scrollController) {
        // Wrap in our own ScaffoldMessenger so showUndoSnackBar fires from
        // DoseTable / etc. land INSIDE the sheet (above the modal barrier),
        // not behind it on the host scaffold where they're invisible.
        return ScaffoldMessenger(
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: Container(
              decoration: const BoxDecoration(
                color: AppColors.surfaceBase,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(24),
                  topRight: Radius.circular(24),
                ),
                border: Border(
                  top: BorderSide(color: AppColors.surfaceBorder, width: 1),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildDragChrome(),
                  _buildTabStrip(),
                  Expanded(
                    child: PageView(
                      controller: _pageController,
                      onPageChanged: _onPageChanged,
                      children: [
                        _buildDoseTab(scrollController),
                        _buildNotesTab(scrollController),
                        _buildPreviewTab(),
                        _buildSettingsTab(scrollController),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Header chrome
  // ---------------------------------------------------------------------------

  /// Chrome cluster (drag handle + title) that owns the sheet's vertical
  /// drag affordance. With `enableDrag: false` on showModalBottomSheet,
  /// nothing else listens for vertical pulls outside the inner Scrollables
  /// so the handle is the canonical "expand / collapse / dismiss" surface.
  Widget _buildDragChrome() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: _onChromeDragUpdate,
      onVerticalDragEnd: _onChromeDragEnd,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.surfaceBorder,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 6),
          _buildHeader(),
        ],
      ),
    );
  }

  void _onChromeDragUpdate(DragUpdateDetails d) {
    if (!_sheetController.isAttached) return;
    final screenH = MediaQuery.of(context).size.height;
    if (screenH <= 0) return;
    final delta = d.primaryDelta ?? 0;
    final next = (_sheetController.size - delta / screenH)
        .clamp(_kMinDetent, _kMaxDetent);
    _sheetController.jumpTo(next);
  }

  void _onChromeDragEnd(DragEndDetails d) {
    if (!_sheetController.isAttached) return;
    final size = _sheetController.size;
    final velocity = d.primaryVelocity ?? 0;
    // Velocity > 0 means dragging DOWN — snap to the lower detent (or
    // dismiss if already past the floor); velocity < 0 means dragging UP.
    final double target;
    if (velocity > 600) {
      // Hard flick down — dismiss.
      Navigator.of(context).maybePop();
      return;
    } else if (velocity < -600) {
      target = _kMaxDetent;
    } else {
      // Snap to nearest of [min, initial, max].
      const detents = [_kMinDetent, _kInitialDetent, _kMaxDetent];
      target = detents.reduce(
        (a, b) => (size - a).abs() < (size - b).abs() ? a : b,
      );
    }
    if (target <= _kMinDetent + 0.01) {
      Navigator.of(context).maybePop();
      return;
    }
    _sheetController.animateTo(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  Widget _buildHeader() {
    final title = _exercise.name?.trim().isNotEmpty == true
        ? _exercise.name!
        : 'Exercise ${_exercise.position + 1}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: 'Montserrat',
              fontSize: 17,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
              color: AppColors.textOnDark,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            _metaLine(),
            style: const TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 11,
              color: AppColors.textSecondaryOnDark,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }

  String _metaLine() {
    if (_exercise.isRest) {
      final secs = _exercise.restHoldSeconds ?? 60;
      return 'REST · ${secs}s';
    }
    final type = _exercise.mediaType == MediaType.video ? 'VIDEO' : 'PHOTO';
    final dur = _exercise.videoDurationMs != null
        ? '${(_exercise.videoDurationMs! / 1000).round()}s'
        : null;
    final reps = _exercise.videoRepsPerLoop != null
        ? '${_exercise.videoRepsPerLoop} reps captured'
        : null;
    return [type, ?dur, ?reps].join(' · ');
  }

  Widget _buildTabStrip() {
    const tabs = ['Dose', 'Notes', 'Preview', 'Settings'];
    return Container(
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: AppColors.surfaceBorder, width: 1),
        ),
      ),
      child: Row(
        children: [
          for (int i = 0; i < tabs.length; i++)
            Expanded(
              child: InkWell(
                onTap: () => _switchTab(i),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: _activeTabIndex == i
                            ? AppColors.primary
                            : Colors.transparent,
                        width: 2,
                      ),
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    tabs[i],
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: _activeTabIndex == i
                          ? AppColors.textOnDark
                          : AppColors.textSecondaryOnDark,
                      letterSpacing: 0.1,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Tab bodies
  // ---------------------------------------------------------------------------

  Widget _buildDoseTab(ScrollController scrollController) {
    final cycles = _circuitCycles();
    // Round 2 — bottom padding mirrors MediaQuery.viewInsets.bottom so
    // the iOS keyboard (when the inline custom-value editor opens)
    // doesn't cover the bottom rows of the table OR the inline editor
    // itself. Scrollable.ensureVisible inside PresetChipRow handles
    // the centring; this padding prevents the sheet's bottom from
    // getting clipped.
    final keyboardInset = MediaQuery.of(context).viewInsets.bottom;
    return SingleChildScrollView(
      controller: scrollController,
      padding: EdgeInsets.fromLTRB(16, 16, 16, 24 + keyboardInset),
      child: DoseTable(
        sets: _exercise.sets,
        onSetsChanged: _onSetsChanged,
        circuitCycles: cycles,
      ),
    );
  }

  /// Resolved circuit cycle count, or null when the exercise isn't part
  /// of a circuit (or the parent session is missing).
  int? _circuitCycles() {
    final circuitId = _exercise.circuitId;
    if (circuitId == null) return null;
    final session = widget.session;
    if (session == null) return null;
    return session.circuitCycles[circuitId];
  }

  Widget _buildNotesTab(ScrollController scrollController) {
    final keyboardInset = MediaQuery.of(context).viewInsets.bottom;
    return SingleChildScrollView(
      controller: scrollController,
      padding: EdgeInsets.fromLTRB(16, 16, 16, 24 + keyboardInset),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 200),
            child: TextField(
              controller: _notesController,
              focusNode: _notesFocusNode,
              minLines: 8,
              maxLines: null,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              onChanged: _onNotesChanged,
              style: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 14,
                color: AppColors.textOnDark,
                height: 1.55,
              ),
              decoration: InputDecoration(
                hintText:
                    'e.g. Watch for valgus collapse on the left knee. Cue heel pressure on descent.',
                hintStyle: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 14,
                  color: AppColors.textSecondaryOnDark,
                  fontStyle: FontStyle.italic,
                ),
                filled: true,
                fillColor: AppColors.surfaceRaised,
                contentPadding: const EdgeInsets.all(14),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide:
                      const BorderSide(color: AppColors.surfaceBorder),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide:
                      const BorderSide(color: AppColors.surfaceBorder),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide:
                      const BorderSide(color: AppColors.primary, width: 2),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'Notes appear in your session view, not on the client web player.',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 11,
              color: AppColors.textSecondaryOnDark,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewTab() {
    if (_exercise.isRest) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Rest periods have no media to preview.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 13,
              color: AppColors.textSecondaryOnDark,
            ),
          ),
        ),
      );
    }
    return MediaViewerBody(
      exercises: [_exercise],
      initialIndex: 0,
      session: widget.session,
      onExerciseUpdate: (updated) {
        _emit(updated);
      },
      onSessionUpdate: widget.onSessionUpdate,
    );
  }

  Widget _buildSettingsTab(ScrollController scrollController) {
    final prepSeconds = _exercise.prepSeconds ?? 5;
    final videoReps = _exercise.videoRepsPerLoop ?? 3;
    final keyboardInset = MediaQuery.of(context).viewInsets.bottom;
    return SingleChildScrollView(
      controller: scrollController,
      padding: EdgeInsets.fromLTRB(16, 16, 16, 24 + keyboardInset),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _SettingsSection(
            label: 'Prep seconds',
            child: PresetChipRow(
              controlKey: 'prep',
              canonicalPresets: const <num>[10, 15, 20, 30, 45, 60],
              currentValue: prepSeconds,
              accentColor: AppColors.primary,
              displayFormat: (v) => '${v.toInt()}s',
              undoLabel: 'prep',
              scrollable: false,
              onChanged: (v) =>
                  _emit(_exercise.copyWith(prepSeconds: v.round())),
            ),
          ),
          const SizedBox(height: 20),
          if (_exercise.mediaType == MediaType.video)
            _SettingsSection(
              label: 'Video reps per loop',
              child: PresetChipRow(
                controlKey: 'videoRepsPerLoop',
                canonicalPresets: const <num>[1, 2, 3, 4, 5],
                currentValue: videoReps,
                accentColor: AppColors.primary,
                displayFormat: (v) => '${v.toInt()}',
                undoLabel: 'reps per loop',
                scrollable: false,
                onChanged: (v) =>
                    _emit(_exercise.copyWith(videoRepsPerLoop: v.round())),
              ),
            ),
          const SizedBox(height: 16),
          const Text(
            'These rarely change once you’ve recorded the exercise.',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 11,
              color: AppColors.textSecondaryOnDark,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// Vertically stacked label-above-control settings section. Matches the
/// pattern used elsewhere in Settings screens — section header on its
/// own line, control beneath. The previous inline label-and-value-on-
/// the-same-row treatment squeezed the chip row into too little width.
class _SettingsSection extends StatelessWidget {
  final String label;
  final Widget child;

  const _SettingsSection({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            fontFamily: 'Inter',
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: AppColors.textSecondaryOnDark,
            letterSpacing: 1.0,
          ),
        ),
        const SizedBox(height: 8),
        child,
      ],
    );
  }
}
