import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../models/exercise_capture.dart';
import '../models/exercise_set.dart';
import '../models/session.dart';
import '../services/conversion_service.dart';
import '../theme.dart';
import 'dose_table.dart';
import 'inline_editable_text.dart';
import 'media_viewer_body.dart';
import 'preset_chip_row.dart';

/// Which tab the editor sheet should land on when first opened.
enum ExerciseEditorTab { dose, notes, preview, hero, settings }

/// The tabbed bottom-sheet editor for an exercise.
///
/// Mounts via [showExerciseEditorSheet]. Hosts five tabs:
///   * **Dose** — `DoseTable` editing per-set rows.
///   * **Notes** — multiline `TextField` for practitioner-only notes.
///   * **Preview** — embeds `MediaViewerBody` so the practitioner can
///     verify what the client will see, scoped to the active exercise.
///   * **Hero** — scrub the raw video to pick the representative still
///     image (the Hero frame). Drives every practitioner-facing
///     thumbnail surface AND the web player's prep-phase overlay.
///     Disabled for photos (the photo IS the Hero) and rest periods.
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
  // Wave Hero — the Hero tab embeds a video preview + scrubber, so it
  // promotes to the larger detent for canvas (matching Preview).
  static const double _kHeroDetent = 0.95;

  /// Velocity threshold (logical pt/sec) for fling-down dismissal. Slow
  /// drags below the floor snap back to 0.55 instead of dismissing.
  static const double _kFlingDismissVelocity = 800;

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

  /// Returns the canonical detent for the given tab index — Preview +
  /// Hero go large (0.95) so the embedded video has canvas; every other
  /// tab snaps to 0.55 so the underlying screen stays partially visible.
  double _detentForTab(int tabIndex) {
    if (tabIndex == _tabIndexFor(ExerciseEditorTab.preview)) {
      return _kPreviewDetent;
    }
    if (tabIndex == _tabIndexFor(ExerciseEditorTab.hero)) {
      return _kHeroDetent;
    }
    return _kMinDetent;
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
      case ExerciseEditorTab.hero:
        return 3;
      case ExerciseEditorTab.settings:
        return 4;
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
    _snapSheetForTab(next);
  }

  void _onPageChanged(int next) {
    if (next == _activeTabIndex) return;
    setState(() => _activeTabIndex = next);

    // Round 8 — Round 7's addPostFrameCallback (~16ms defer) wasn't long
    // enough; the user's finger remained on the touchscreen past that
    // frame, and the residual vertical motion under the freshly-shrunk
    // sheet was read as a drag past the dismiss floor. Listen to the
    // PageController's scroll-settling notifier instead — guarantees
    // the gesture and the page animation are BOTH done before snap fires.
    final position = _pageController.position;
    if (!position.isScrollingNotifier.value) {
      _snapSheetForTab(next);
      return;
    }
    void onSettle() {
      if (position.isScrollingNotifier.value) return;
      position.isScrollingNotifier.removeListener(onSettle);
      if (mounted) _snapSheetForTab(next);
    }
    position.isScrollingNotifier.addListener(onSettle);
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
      initialChildSize: _detentForTab(_activeTabIndex),
      minChildSize: _kMinDetent,
      maxChildSize: _kMaxDetent,
      snap: true,
      // Round 3 — two snap stops: 0.55 (floor) and 0.95 (full).
      // _onChromeDragEnd dismisses ONLY on a fast downward fling
      // (>800 logical pt/s). Slow drags below 0.55 snap back to the
      // floor — Carl's Round 2 retest reported the previous behaviour
      // (drag below 0.55 dismisses) was unintentional.
      snapSizes: const [_kMinDetent, _kMaxDetent],
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
                        _buildHeroTab(),
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

  void _onChromeDragEnd(DragEndDetails d) {
    if (!_sheetController.isAttached) return;
    final size = _sheetController.size;
    final velocity = d.primaryVelocity ?? 0;
    // Round 3 — only a FAST downward fling dismisses. Slow drag below the
    // floor snaps back to 0.55 instead. Tap-outside (modal barrier) is
    // the canonical "I'm done" gesture; drag is for resizing.
    if (velocity > _kFlingDismissVelocity) {
      Navigator.of(context).maybePop();
      return;
    }
    final double target;
    if (velocity < -_kFlingDismissVelocity) {
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 18, 8),
      // Round 3 — thumbnail (P6) + inline-editable title (P5) sit
      // side-by-side. Card surface no longer renders any edit affordance;
      // every edit happens inside the popup, including the rename.
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
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
    const tabs = ['Dose', 'Notes', 'Preview', 'Hero', 'Settings'];
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
      // Round 3 — embedded mode hides the X button (the sheet's drag-down
      // + tap-outside dismiss) and shifts the vertical treatment pill up
      // so it doesn't collide with the bottom-left Body Focus + Rotate
      // pills on the shorter sheet canvas.
      embeddedInSheet: true,
    );
  }

  Widget _buildHeroTab() {
    if (_exercise.isRest) {
      return const _HeroTabPlaceholder(
        message: 'Rest periods have no Hero frame.',
      );
    }
    if (_exercise.mediaType == MediaType.photo) {
      return const _HeroTabPlaceholder(
        message:
            'Photos are already the Hero frame — no scrubbing needed.',
      );
    }
    return _HeroTab(
      exercise: _exercise,
      onChanged: _emit,
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
              label: 'Reps in Video',
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

// ============================================================================
// Hero tab — scrub the raw video to pick the representative still frame.
// ============================================================================

/// Placeholder body for non-video exercises. The Hero tab is video-only
/// because photos already are the Hero frame and rest periods carry no
/// media.
class _HeroTabPlaceholder extends StatelessWidget {
  final String message;
  const _HeroTabPlaceholder({required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily: 'Inter',
            fontSize: 13,
            color: AppColors.textSecondaryOnDark,
          ),
        ),
      ),
    );
  }
}

/// Live video preview + horizontal scrubber for picking the Hero frame.
///
/// The scrubber is clamped to the soft-trim window
/// `[startOffsetMs, endOffsetMs]` (Wave 20) so the Hero is always a frame
/// the client will actually see. As the practitioner drags the slider,
/// the video seeks to that time so the preview reflects the picked
/// frame. The "Set as Hero" button commits the change: the offset is
/// persisted to `focus_frame_offset_ms` AND all three treatment
/// thumbnails (B&W, colour, line) are re-extracted at that offset, so
/// every list-card surface refreshes on the next paint.
class _HeroTab extends StatefulWidget {
  final ExerciseCapture exercise;
  final ValueChanged<ExerciseCapture> onChanged;

  const _HeroTab({
    required this.exercise,
    required this.onChanged,
  });

  @override
  State<_HeroTab> createState() => _HeroTabState();
}

class _HeroTabState extends State<_HeroTab> {
  VideoPlayerController? _controller;
  bool _initialised = false;
  String? _initError;

  /// Current scrubber position in ms. Mirrors slider state. Initialised
  /// to the saved offset (or 0 if none) once the controller is ready.
  int _scrubMs = 0;

  /// True while a regen-on-save is in flight. Disables the button and
  /// shows a spinner so the practitioner can't double-fire.
  bool _saving = false;

  /// True when the on-disk offset matches [_scrubMs] — i.e. nothing
  /// to save. Initialised true (no pending change) and flipped on every
  /// drag delta.
  bool _committed = true;

  @override
  void initState() {
    super.initState();
    _initController();
  }

  Future<void> _initController() async {
    final raw = widget.exercise.absoluteRawFilePath;
    if (raw.isEmpty || !File(raw).existsSync()) {
      setState(() {
        _initError = 'Raw video file not found.';
      });
      return;
    }
    final controller = VideoPlayerController.file(File(raw));
    try {
      await controller.initialize();
      // Mute — Hero scrubbing is a visual-only flow.
      await controller.setVolume(0);
      // Seed scrubber from saved offset; clamp to soft-trim window.
      final start = widget.exercise.startOffsetMs ?? 0;
      final end = widget.exercise.endOffsetMs ??
          controller.value.duration.inMilliseconds;
      final saved = widget.exercise.focusFrameOffsetMs ?? start;
      _scrubMs = saved.clamp(start, end).toInt();
      await controller.seekTo(Duration(milliseconds: _scrubMs));
      if (mounted) {
        setState(() {
          _controller = controller;
          _initialised = true;
        });
      }
    } catch (e) {
      debugPrint('_HeroTab controller init failed: $e');
      if (mounted) {
        setState(() {
          _initError = 'Could not load video.';
        });
      }
      await controller.dispose();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  /// Soft-trim window for the slider. Falls back to full duration when
  /// the practitioner hasn't trimmed.
  ({int startMs, int endMs}) _window() {
    final c = _controller;
    final totalMs = c?.value.duration.inMilliseconds ?? 0;
    final start = widget.exercise.startOffsetMs ?? 0;
    final end = widget.exercise.endOffsetMs ?? totalMs;
    final clampedEnd = end > start ? end : (totalMs > start ? totalMs : start + 1);
    return (startMs: start, endMs: clampedEnd);
  }

  void _onSliderChanged(double valueMs) {
    final w = _window();
    final clamped = valueMs.clamp(w.startMs.toDouble(), w.endMs.toDouble());
    final newMs = clamped.toInt();
    setState(() {
      _scrubMs = newMs;
      _committed = newMs == widget.exercise.focusFrameOffsetMs;
    });
    _controller?.seekTo(Duration(milliseconds: newMs));
  }

  Future<void> _commitHero() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final updated = await ConversionService.instance
          .regenerateHeroThumbnails(widget.exercise, _scrubMs);
      widget.onChanged(updated);
      if (mounted) {
        setState(() => _committed = true);
      }
      HapticFeedback.lightImpact();
    } catch (e) {
      debugPrint('_HeroTab commit failed: $e');
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  String _formatMs(int ms) {
    final totalSeconds = ms ~/ 1000;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    final tenths = (ms % 1000) ~/ 100;
    return '$minutes:${seconds.toString().padLeft(2, '0')}.$tenths';
  }

  @override
  Widget build(BuildContext context) {
    if (_initError != null) {
      return _HeroTabPlaceholder(message: _initError!);
    }
    final c = _controller;
    if (!_initialised || c == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.primary,
            ),
          ),
        ),
      );
    }
    final w = _window();
    final saved = widget.exercise.focusFrameOffsetMs;
    final canSave = !_saving && !_committed;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Live preview surface — square-ish letterbox honouring the
          // video's natural aspect.
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Container(
                color: Colors.black,
                child: AspectRatio(
                  aspectRatio: c.value.aspectRatio,
                  child: VideoPlayer(c),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Time row: current scrub position vs. window end.
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _formatMs(_scrubMs),
                style: const TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 13,
                  color: AppColors.textOnDark,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                _formatMs(w.endMs),
                style: const TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 13,
                  color: AppColors.textSecondaryOnDark,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),

          // Scrubber — clamped to [startMs, endMs] of the soft-trim
          // window. Coral active track to match brand accent.
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: AppColors.primary,
              inactiveTrackColor: AppColors.surfaceBorder,
              thumbColor: AppColors.primary,
              overlayColor: AppColors.primary.withValues(alpha: 0.18),
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
            ),
            child: Slider(
              min: w.startMs.toDouble(),
              max: w.endMs.toDouble(),
              value: _scrubMs.toDouble().clamp(
                    w.startMs.toDouble(),
                    w.endMs.toDouble(),
                  ),
              onChanged: _onSliderChanged,
            ),
          ),
          const SizedBox(height: 8),

          // Commit row — coral CTA + a tiny status line so the
          // practitioner knows whether the current Hero matches the
          // saved one.
          Row(
            children: [
              Expanded(
                child: Text(
                  saved == null
                      ? 'No Hero set yet — slide to pick a frame.'
                      : (_committed
                          ? 'Hero set at ${_formatMs(saved)}'
                          : 'Slide to ${_formatMs(_scrubMs)} · unsaved'),
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 11,
                    color: AppColors.textSecondaryOnDark,
                    height: 1.45,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              ElevatedButton(
                onPressed: canSave ? _commitHero : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: AppColors.surfaceRaised,
                  disabledForegroundColor: AppColors.textSecondaryOnDark,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 18, vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  textStyle: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                child: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('Set as Hero'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
