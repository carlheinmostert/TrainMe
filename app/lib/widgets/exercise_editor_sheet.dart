import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/exercise_capture.dart';
import '../models/exercise_set.dart';
import '../models/session.dart';
import '../theme.dart';
import 'dose_table.dart';
import 'inline_editable_text.dart';
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
/// On every meaningful edit the sheet fires [onExerciseChanged] with the
/// (index, fresh ExerciseCapture) so the Studio screen can persist +
/// re-render without waiting for the sheet to dismiss.
///
/// The sheet hosts prev/next chevrons and a dot row so the practitioner
/// can step through the parent session's exercises without closing and
/// reopening the sheet. The active index lives in sheet state and may
/// diverge from [initialExerciseIndex] over the lifetime of the sheet.
Future<void> showExerciseEditorSheet({
  required BuildContext context,
  required Session session,
  required int initialExerciseIndex,
  required void Function(int index, ExerciseCapture updated) onExerciseChanged,
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
      session: session,
      initialExerciseIndex: initialExerciseIndex,
      onExerciseChanged: onExerciseChanged,
      onSessionUpdate: onSessionUpdate,
      initialTab: initialTab,
    ),
  );
}

/// The sheet body. Exposed publicly so tests / future callers can mount
/// it inside a custom host without going through [showExerciseEditorSheet].
class ExerciseEditorSheet extends StatefulWidget {
  /// Parent session. The sheet reads `session.exercises` to drive prev/
  /// next chevrons + the dot row, and keeps a local mirror of the active
  /// exercise so it can fire [onExerciseChanged] with the freshly-mutated
  /// copy on every edit.
  final Session session;

  /// Index into `session.exercises` to land on when the sheet opens.
  final int initialExerciseIndex;

  /// Called whenever the practitioner mutates an exercise (sets, notes,
  /// prep seconds, video reps per loop). The Studio screen wires this
  /// directly to its `_updateExercise(int, ExerciseCapture)` so SQLite +
  /// in-memory + UI stay in step. The reported index is the index of the
  /// EXERCISE CURRENTLY EDITED inside the sheet — which may differ from
  /// [initialExerciseIndex] once the practitioner has navigated.
  final void Function(int index, ExerciseCapture updated) onExerciseChanged;

  /// Optional session-update callback — wired to the Preview tab's
  /// `MediaViewerBody.onSessionUpdate` so crossfade-tuner edits inside
  /// the embed propagate back to the Studio screen.
  final ValueChanged<Session>? onSessionUpdate;

  /// Tab to land on when the sheet opens. Defaults to Dose.
  final ExerciseEditorTab initialTab;

  const ExerciseEditorSheet({
    super.key,
    required this.session,
    required this.initialExerciseIndex,
    required this.onExerciseChanged,
    this.onSessionUpdate,
    this.initialTab = ExerciseEditorTab.dose,
  });

  @override
  State<ExerciseEditorSheet> createState() => _ExerciseEditorSheetState();
}

class _ExerciseEditorSheetState extends State<ExerciseEditorSheet> {
  // Round 3 — Carl's spec evolved twice. Round 2 had drag-down past 0.55
  // dismiss; retest reported releasing below 0.55 dismissed instead of
  // snapping. Round 3: 0.55 is the FLOOR — releases below stay at 0.55.
  // Dismiss is via fast downward velocity (>800), tap-outside (modal
  // barrier), or explicit close.
  //
  // Tab-aware default detent: Preview tab promotes to 0.95 (full canvas
  // for the embedded media viewer); all other tabs settle at 0.55 (form
  // controls don't need the full screen — leaves the parent visible).
  // The tab swipe / tab-strip tap calls `_animateSheetForTab` to honour
  // this. Initial detent is computed in `build()` via `_detentForTab`.
  static const double _kMinDetent = 0.55;
  static const double _kMaxDetent = 0.95;
  static const double _kPreviewDetent = 0.95;

  /// Velocity threshold (logical pt/sec) for fling-down dismissal. Slow
  /// drags below the floor snap back to 0.55 instead of dismissing.
  static const double _kFlingDismissVelocity = 800;

  late final DraggableScrollableController _sheetController;
  late final PageController _pageController;
  late int _exerciseIndex;
  late ExerciseCapture _exercise;
  int _activeTabIndex = 0;
  // Set in _switchTab while animateToPage is in flight. _onPageChanged
  // ignores intermediate page-crosses while non-null so the sheet doesn't
  // briefly snap to a transitional tab's detent (e.g. Notes → Settings
  // crosses Preview, which would otherwise jump the sheet to 0.95).
  int? _pendingFinalTab;
  String? _activeSettingsKey;
  final FocusNode _notesFocusNode = FocusNode();
  late TextEditingController _notesController;

  @override
  void initState() {
    super.initState();
    _exerciseIndex = widget.initialExerciseIndex;
    _exercise = widget.session.exercises[_exerciseIndex];
    _activeTabIndex = _tabIndexFor(widget.initialTab);
    _sheetController = DraggableScrollableController();
    _pageController = PageController(initialPage: _activeTabIndex);
    _notesController = TextEditingController(text: _exercise.notes ?? '');
    _notesFocusNode.addListener(_onNotesFocusChanged);
  }

  /// Returns the canonical detent for the given tab index — Preview goes
  /// large (0.95) so the embedded media viewer has canvas; every other
  /// tab snaps to 0.55 so the underlying screen stays partially visible.
  double _detentForTab(int tabIndex) {
    return tabIndex == _tabIndexFor(ExerciseEditorTab.preview)
        ? _kPreviewDetent
        : _kMinDetent;
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
    // setState rebuilds the Notes tab so the Done button shows/hides as
    // focus changes. Listener fires on BOTH gain and loss of focus.
    if (mounted) setState(() {});
    if (!_sheetController.isAttached) return;
    // Promote on focus gain (so keyboard doesn't squash the textarea),
    // restore to floor detent on focus loss (Notes' canonical detent).
    _sheetController.animateTo(
      _notesFocusNode.hasFocus ? _kMaxDetent : _kMinDetent,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  void _switchTab(int next) {
    if (next == _activeTabIndex) return;
    HapticFeedback.selectionClick();
    _pendingFinalTab = next;
    setState(() => _activeTabIndex = next);
    _pageController
        .animateToPage(
          next,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        )
        .whenComplete(() {
      if (mounted && _pendingFinalTab == next) _pendingFinalTab = null;
    });
    _snapSheetForTab(next);
  }

  void _onPageChanged(int next) {
    // While _switchTab's animateToPage is in flight across non-adjacent
    // pages, ignore intermediate page-crosses so we don't snap to a
    // transitional tab's detent (e.g. Preview's 0.95 mid-flight).
    if (_pendingFinalTab != null && next != _pendingFinalTab) return;
    if (next == _activeTabIndex) return;
    setState(() => _activeTabIndex = next);
    // Snap immediately. The earlier settle-listener defer was a workaround
    // for the shouldCloseOnMinExtent auto-dismiss bug: residual vertical
    // finger motion at floor would trigger the dismiss observer. With
    // shouldCloseOnMinExtent: false we no longer need that defer, and
    // immediate snap is more reliable (Preview → Settings/Notes via swipe
    // sometimes failed to snap when settle fired too early).
    _snapSheetForTab(next);
  }

  /// Round 5 — hard-snap the sheet to the canonical detent for the given
  /// tab. Preview promotes to 0.95 (full canvas for the embedded media
  /// viewer); every other tab settles at 0.55 so the underlying screen
  /// stays partially visible.
  ///
  /// Uses [DraggableScrollableController.jumpTo] (instant) instead of
  /// `animateTo`. Round 4 used a 240ms easeOutCubic animation, but the
  /// PageView's swipe gesture feeds vertical pan deltas into the same
  /// `DraggableScrollableSheet` and cancels the in-flight animation
  /// mid-flight — leaving the sheet parked at intermediate sizes (~65%)
  /// when the user swipes between tabs. Hard snap eliminates the race.
  void _snapSheetForTab(int tabIndex) {
    if (!_sheetController.isAttached) return;
    _sheetController.jumpTo(_detentForTab(tabIndex));
  }

  void _emit(ExerciseCapture next) {
    setState(() => _exercise = next);
    widget.onExerciseChanged(_exerciseIndex, next);
  }

  /// Step the active exercise by ±1 (or jump to a specific index from the
  /// dot row). Out-of-range / no-op calls are silently ignored. Resets the
  /// Notes controller so stale text from the previous exercise can't
  /// linger, and collapses any open Settings row.
  void _navigateExercise(int newIndex) {
    if (newIndex < 0 || newIndex >= widget.session.exercises.length) return;
    if (newIndex == _exerciseIndex) return;
    HapticFeedback.selectionClick();
    setState(() {
      _exerciseIndex = newIndex;
      _exercise = widget.session.exercises[newIndex];
      _notesController.text = _exercise.notes ?? '';
      _activeSettingsKey = null;
    });
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
      initialChildSize: _detentForTab(_activeTabIndex),
      minChildSize: _kMinDetent,
      maxChildSize: _kMaxDetent,
      snap: true,
      // Two snap stops: 0.55 (floor) and 0.95 (full).
      snapSizes: const [_kMinDetent, _kMaxDetent],
      // CRITICAL: defaults to true. When true, _BottomSheetState.extentChanged
      // (Flutter framework) auto-closes the route the moment extent equals
      // minChildSize — which is exactly where our slow drag-down lands and
      // where _snapSheetForTab parks every non-Preview tab. Disabling this
      // hands all dismissal control back to us. Tap-outside (modal barrier)
      // remains the canonical "I'm done" gesture.
      shouldCloseOnMinExtent: false,
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
  ///
  /// Round 3 — wraps the chrome AND the drag-handle pill in their own
  /// GestureDetectors with `behavior: opaque`. The pill itself bumps to
  /// 48pt-tall hit area (visible bar still 4pt) so the drag region is
  /// thumb-friendly even on the Preview tab. Carl's retest reported the
  /// Preview tab "does not allow dragging the card up or down" — the
  /// previous chrome surface was only ~50pt tall after the 6pt SizedBox
  /// gap, easy to miss next to the embedded MediaViewerBody's gestures.
  Widget _buildDragChrome() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: _onChromeDragUpdate,
      onVerticalDragEnd: _onChromeDragEnd,
      // Horizontal swipe on the chrome navigates between exercises.
      // The drag system picks the dominant axis: mostly-vertical = resize,
      // mostly-horizontal = navigate. Threshold 200 pt/s ensures a slow
      // wobble doesn't trigger nav.
      onHorizontalDragEnd: _onChromeHorizontalDragEnd,
      child: SizedBox(
        width: double.infinity,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Drag-handle pill — visible 4pt bar centered in a 22pt-tall
            // hit zone for thumb-friendly grabbing.
            SizedBox(
              height: 22,
              child: Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.surfaceBorder,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
            _buildHeader(),
          ],
        ),
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

  void _onChromeHorizontalDragEnd(DragEndDetails d) {
    final velocity = d.primaryVelocity ?? 0;
    // Standard PageView convention: finger moves left → next, right → prev.
    if (velocity < -200) {
      _navigateExercise(_exerciseIndex + 1);
    } else if (velocity > 200) {
      _navigateExercise(_exerciseIndex - 1);
    }
  }

  void _onChromeDragEnd(DragEndDetails d) {
    if (!_sheetController.isAttached) return;
    final size = _sheetController.size;
    final velocity = d.primaryVelocity ?? 0;
    // No-op when the sheet is already exactly at a detent (no real drag
    // happened). This handles a tab-strip tap that the outer drag
    // recognizer arena-claims as a zero-motion "drag": without this guard
    // _onChromeDragEnd would animateTo the current detent, racing with
    // _switchTab's jumpTo to the NEW tab's detent (e.g. tapping Settings
    // from Preview while at 0.95 — animateTo(0.95) would override
    // jumpTo(0.55) and the sheet would stay parked at Preview's detent).
    const detentTol = 0.005;
    if ((size - _kMinDetent).abs() < detentTol ||
        (size - _kMaxDetent).abs() < detentTol) {
      return;
    }
    // Drag is for resizing ONLY. Dismissal is via tap-outside (modal
    // barrier). Velocity-based dismiss was tried in Round 3 (>800 pt/s)
    // but caused two bugs: (1) a normal drag-down from 0.95 to 0.55
    // released with enough residual velocity to dismiss instead of snap,
    // and (2) a tap on a tab — even with no intentional motion — was
    // sometimes claimed by the outer GestureDetector's vertical-drag
    // recognizer (sub-slop finger jitter under HitTestBehavior.translucent)
    // and ended with velocity > 800, dismissing the sheet on a tab tap.
    final double target;
    if (velocity < -_kFlingDismissVelocity) {
      // Fast UPWARD fling promotes to the max detent. Useful and
      // unambiguous — no wrong-direction tap-jitter risk.
      target = _kMaxDetent;
    } else {
      // Snap to whichever of [min, max] is closer.
      const detents = [_kMinDetent, _kMaxDetent];
      target = detents.reduce(
        (a, b) => (size - a).abs() < (size - b).abs() ? a : b,
      );
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
    final total = widget.session.exercises.length;
    final canPrev = _exerciseIndex > 0;
    final canNext = _exerciseIndex < total - 1;
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 8),
      // Chevrons flank the title block; counter + close × cluster on
      // the right edge. Tapping a chevron steps the active exercise by
      // ±1 — the sheet stays open and the body re-renders against the
      // new exercise.
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          IconButton(
            onPressed: canPrev
                ? () => _navigateExercise(_exerciseIndex - 1)
                : null,
            padding: EdgeInsets.zero,
            constraints: BoxConstraints.tightFor(width: 36, height: 36),
            iconSize: 22,
            icon: Icon(
              Icons.chevron_left,
              size: 22,
              color: canPrev
                  ? AppColors.textOnDark
                  : AppColors.textSecondaryOnDark.withValues(alpha: 0.4),
            ),
          ),
          _HeaderThumbnail(exercise: _exercise),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                InlineEditableText(
                  // KEY ensures the editable text rebuilds when the
                  // resolved title changes (e.g. position drift on a
                  // capture without a name). Without the key the
                  // controller text wouldn't refresh on a fresh exercise.
                  key: ValueKey(
                      'editor-title-${_exercise.id}-${_exercise.position}'),
                  initialValue: title,
                  hintText: 'Name this exercise…',
                  onCommit: (next) =>
                      _emit(_exercise.copyWith(name: next)),
                  textStyle: const TextStyle(
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
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 11,
                    color: AppColors.textSecondaryOnDark,
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: canNext
                ? () => _navigateExercise(_exerciseIndex + 1)
                : null,
            padding: EdgeInsets.zero,
            constraints: BoxConstraints.tightFor(width: 36, height: 36),
            iconSize: 22,
            icon: Icon(
              Icons.chevron_right,
              size: 22,
              color: canNext
                  ? AppColors.textOnDark
                  : AppColors.textSecondaryOnDark.withValues(alpha: 0.4),
            ),
          ),
          const SizedBox(width: 4),
          Text(
            '${_exerciseIndex + 1} of $total',
            style: const TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.textSecondaryOnDark,
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            padding: EdgeInsets.zero,
            constraints: BoxConstraints.tightFor(width: 36, height: 36),
            iconSize: 22,
            icon: const Icon(
              Icons.close,
              size: 22,
              color: AppColors.textOnDark,
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
    // Round 2 — tab strip listens for vertical drag too so the Preview
    // tab (whose body owns gestures inside MediaViewerBody) still has a
    // reliable drag region between the chrome and the page content.
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragUpdate: _onChromeDragUpdate,
      onVerticalDragEnd: _onChromeDragEnd,
      child: Container(
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
  /// of a circuit.
  int? _circuitCycles() {
    final circuitId = _exercise.circuitId;
    if (circuitId == null) return null;
    return widget.session.circuitCycles[circuitId];
  }

  Widget _buildNotesTab(ScrollController scrollController) {
    final keyboardInset = MediaQuery.of(context).viewInsets.bottom;
    return GestureDetector(
      // Tap anywhere outside the textarea dismisses the keyboard. translucent
      // so the TextField still claims its own taps via the gesture arena.
      behavior: HitTestBehavior.translucent,
      onTap: () => _notesFocusNode.unfocus(),
      child: SingleChildScrollView(
        controller: scrollController,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: EdgeInsets.fromLTRB(16, 8, 16, 24 + keyboardInset),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Done button — only takes vertical space when visible, so the
            // textarea sits flush under the tab strip when the keyboard
            // is closed.
            if (_notesFocusNode.hasFocus)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => _notesFocusNode.unfocus(),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    minimumSize: const Size(0, 28),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    foregroundColor: AppColors.primary,
                  ),
                  child: const Text(
                    'Done',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
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
          ],
        ),
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
      // Round 3 — embedded mode hides the X button (the sheet's drag-down
      // + tap-outside dismiss) and shifts the vertical treatment pill up
      // so it doesn't collide with the bottom-left Body Focus + Rotate
      // pills on the shorter sheet canvas.
      embeddedInSheet: true,
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
          _CollapsibleSettingsRow(
            label: 'Prep seconds',
            summary: '${prepSeconds}s',
            isExpanded: _activeSettingsKey == 'prep',
            onTap: () => setState(() {
              _activeSettingsKey =
                  _activeSettingsKey == 'prep' ? null : 'prep';
            }),
            editor: PresetChipRow(
              controlKey: 'prep',
              canonicalPresets: const <num>[10, 15, 20, 30, 45, 60],
              currentValue: prepSeconds,
              accentColor: AppColors.primary,
              displayFormat: (v) => '${v.toInt()}s',
              undoLabel: 'prep',
              scrollable: false,
              onChanged: (v) {
                _emit(_exercise.copyWith(prepSeconds: v.round()));
                setState(() => _activeSettingsKey = null);
              },
            ),
          ),
          if (_exercise.mediaType == MediaType.video) ...[
            const SizedBox(height: 8),
            _CollapsibleSettingsRow(
              label: 'Reps in Video',
              summary: '$videoReps',
              isExpanded: _activeSettingsKey == 'videoRepsPerLoop',
              onTap: () => setState(() {
                _activeSettingsKey =
                    _activeSettingsKey == 'videoRepsPerLoop'
                        ? null
                        : 'videoRepsPerLoop';
              }),
              editor: PresetChipRow(
                controlKey: 'videoRepsPerLoop',
                canonicalPresets: const <num>[1, 2, 3, 4, 5],
                currentValue: videoReps,
                accentColor: AppColors.primary,
                displayFormat: (v) => '${v.toInt()}',
                undoLabel: 'reps per loop',
                scrollable: false,
                onChanged: (v) {
                  _emit(_exercise.copyWith(videoRepsPerLoop: v.round()));
                  setState(() => _activeSettingsKey = null);
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Vertically stacked label-above-control settings section. Matches the
/// pattern used elsewhere in Settings screens — section header on its
/// Round 3 (P6) — small square thumbnail rendered in the editor sheet's
/// header. Mirrors the trainer-facing preview thumbnails used elsewhere
/// (Studio cards, Home, Camera peek box) — same source asset, just a
/// smaller surface (44×44 here) so it pairs neatly with the inline-
/// editable title without dominating the chrome.
class _HeaderThumbnail extends StatelessWidget {
  final ExerciseCapture exercise;

  const _HeaderThumbnail({required this.exercise});

  @override
  Widget build(BuildContext context) {
    final String? thumbPath = exercise.absoluteThumbnailPath;
    final hasThumb = thumbPath != null && File(thumbPath).existsSync();
    final isVideo = exercise.mediaType == MediaType.video;
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.surfaceBorder, width: 1),
        gradient: hasThumb
            ? null
            : const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFF2A2D3A),
                  Color(0xFF1A1D27),
                ],
              ),
        image: hasThumb
            ? DecorationImage(
                image: FileImage(File(thumbPath)),
                fit: BoxFit.cover,
              )
            : null,
      ),
      child: Stack(
        children: [
          if (isVideo)
            const Center(
              child: _HeaderPlayGlyph(),
            ),
          if (exercise.mediaType == MediaType.photo && !hasThumb)
            const Center(
              child: Icon(
                Icons.photo_outlined,
                size: 18,
                color: AppColors.textSecondaryOnDark,
              ),
            ),
          if (exercise.isRest)
            const Center(
              child: Icon(
                Icons.bedtime_outlined,
                size: 18,
                color: AppColors.textSecondaryOnDark,
              ),
            ),
        ],
      ),
    );
  }
}

class _HeaderPlayGlyph extends StatelessWidget {
  const _HeaderPlayGlyph();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.72),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: const Padding(
        padding: EdgeInsets.only(left: 1),
        child: Icon(
          Icons.play_arrow_rounded,
          size: 12,
          color: AppColors.textOnDark,
        ),
      ),
    );
  }
}

/// Collapsible row for the Settings tab — mirrors the Dose-table pattern
/// where the row shows label + current value, and tapping expands an
/// inline editor below. Tapping a value in the editor commits and
/// collapses the row (handled by the caller via [setState]).
class _CollapsibleSettingsRow extends StatelessWidget {
  final String label;
  final String summary;
  final bool isExpanded;
  final VoidCallback onTap;
  final Widget editor;

  const _CollapsibleSettingsRow({
    required this.label,
    required this.summary,
    required this.isExpanded,
    required this.onTap,
    required this.editor,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: isExpanded
                      ? AppColors.primary
                      : AppColors.surfaceBorder,
                  width: isExpanded ? 2 : 1,
                ),
              ),
            ),
            child: Row(
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textOnDark,
                  ),
                ),
                const Spacer(),
                Text(
                  summary,
                  style: TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: isExpanded
                        ? AppColors.primary
                        : AppColors.textSecondaryOnDark,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (isExpanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
            child: editor,
          ),
      ],
    );
  }
}
