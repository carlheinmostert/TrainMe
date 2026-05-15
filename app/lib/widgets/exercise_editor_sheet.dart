import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/exercise_capture.dart';
import '../models/session.dart';
import '../theme.dart';
import 'plan_table.dart';
import 'inline_editable_text.dart';
import 'media_viewer_body.dart';
import 'mini_preview.dart';
import 'preset_chip_row.dart';

/// Which tab the editor sheet should land on when first opened.
///
/// Order matches the visible tab strip left-to-right
/// (`Demo · Plan · Notes · Settings`) so the enum's declaration index
/// can be reused directly as the tab strip / PageView index for a
/// non-rest exercise. Rest exercises render only the single "Rest"
/// cell — initial tab is clamped to 0 for them.
///
/// 2026-05-15 — `preview` renamed to `demo` (per ADR-0019). "Preview"
/// implied passive viewing and collided with the CAPS workflow chain's
/// "Preview" step (a separate surface). The tab is the active edit
/// surface for the captured asset (trim, hero pick, treatment, body
/// focus, audio). "Demo" echoes the product narrative ("line-drawing
/// demonstrations") and is unambiguous.
enum ExerciseEditorTab { demo, plan, notes, settings }

/// The tabbed bottom-sheet editor for an exercise.
///
/// Mounts via [showExerciseEditorSheet]. Hosts four tabs:
///   * **Demo** — embeds `MediaViewerBody` so the practitioner can
///     verify what the client will see, scoped to the active exercise.
///     The trim panel here also hosts the Hero-frame pick (a third
///     handle on the shared timeline). Decommissioned the standalone
///     Hero tab 2026-05-03 in favour of that consolidation. Renamed
///     from "Preview" 2026-05-15 (ADR-0019). Default opening tab.
///   * **Plan** — `PlanTable` editing per-set rows.
///   * **Notes** — multiline `TextField` for practitioner-only notes.
///   * **Settings** — preset chip rows for `prepSeconds` +
///     `videoRepsPerLoop` (rarely-changed metadata).
///
/// Detent (2026-05-15 — ADR-0019 inversion extension): the sheet always
/// opens AND stays at the 0.95 maximum detent. The 0.75 floor remains
/// reachable via manual drag-down on the chrome (top drag pill OR
/// bottom rail). The earlier per-tab auto-snap rule (Preview at 0.95,
/// other tabs at 0.75) was retired because the continuous PageView
/// (see below) would oscillate the sheet height at every tab boundary
/// — jarring. Bottom-aligned tab content (Plan / Notes / Settings)
/// keeps the most-tapped controls within thumb reach even at 0.95.
///
/// PageView (2026-05-15): a single continuous virtual PageView spans
/// every `(exerciseIndex, tabIndex)` cell in the session, with WRAP
/// at session boundaries. Tab swipe at the last tab of one exercise
/// flows smoothly into the first tab of the next; swiping past the
/// last cell wraps to the first. Chevron taps on the bottom rail and
/// chrome-horizontal-swipes keep their bounded "jump to next exercise"
/// semantics. Implemented via `PageView.builder` with a large
/// `itemCount = totalCells * 10000` and start near the midpoint, so
/// modulo `totalCells` of the page index maps to the cell offset.
///
/// On every meaningful edit the sheet fires [onExerciseChanged] with
/// the (index, fresh ExerciseCapture) so the Studio screen can persist
/// + re-render without waiting for the sheet to dismiss.
///
/// The sheet hosts prev/next chevrons so the practitioner can step
/// through the parent session's exercises without closing and reopening
/// the sheet. The active index lives in sheet state and may diverge
/// from [initialExerciseIndex] over the lifetime of the sheet.
Future<void> showExerciseEditorSheet({
  required BuildContext context,
  required Session session,
  required int initialExerciseIndex,
  required void Function(int index, ExerciseCapture updated) onExerciseChanged,
  ValueChanged<Session>? onSessionUpdate,
  ExerciseEditorTab initialTab = ExerciseEditorTab.demo,
}) async {
  HapticFeedback.selectionClick();
  // Pause every Studio-list MiniPreview for the duration of the sheet
  // so background motion doesn't distract while editing. The sheet's
  // own chrome MiniPreview leaves respectGlobalPause: false, so the
  // focused exercise's preview keeps playing inside the sheet.
  MiniPreview.studioPauseAll.value = true;
  try {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      // Default barrier disabled — we render our own frosted-scrim layer
      // (BackdropFilter blur + heavier dim) inside the builder so the
      // underlying Studio screen visibly recedes instead of just dims.
      // Same pattern Apple uses for Control Center / share sheets.
      barrierColor: Colors.transparent,
      useSafeArea: true,
      // The inner DraggableScrollableSheet owns drag behaviour. Letting
      // showModalBottomSheet's own enableDrag also fight for vertical
      // drags eats inner widgets (weight slider, trim handles) and the
      // sheet refuses to expand via the drag handle.
      enableDrag: false,
      builder: (sheetCtx) => Stack(
        children: [
          // Frosted-scrim backdrop. GestureDetector wraps the BackdropFilter
          // (not the other way round) so the tap-to-dismiss hit target
          // matches the default modal-barrier behaviour the transparent
          // barrier gave up.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.of(sheetCtx).pop(),
              child: RepaintBoundary(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.65),
                  ),
                ),
              ),
            ),
          ),
          ExerciseEditorSheet(
            session: session,
            initialExerciseIndex: initialExerciseIndex,
            onExerciseChanged: onExerciseChanged,
            onSessionUpdate: onSessionUpdate,
            initialTab: initialTab,
          ),
        ],
      ),
    );
  } finally {
    MiniPreview.studioPauseAll.value = false;
  }
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

  /// Tab to land on when the sheet opens. Defaults to Demo.
  final ExerciseEditorTab initialTab;

  const ExerciseEditorSheet({
    super.key,
    required this.session,
    required this.initialExerciseIndex,
    required this.onExerciseChanged,
    this.onSessionUpdate,
    this.initialTab = ExerciseEditorTab.demo,
  });

  @override
  State<ExerciseEditorSheet> createState() => _ExerciseEditorSheetState();
}

class _ExerciseEditorSheetState extends State<ExerciseEditorSheet> {
  // 2026-05-15 — per-tab auto-snap retired (ADR-0019 inversion
  // extension). The sheet always opens AND stays at the 0.95 max
  // detent; the 0.75 floor remains reachable via manual drag-down on
  // the chrome (top drag pill OR bottom rail). The earlier rule (Preview
  // at 0.95, other tabs at 0.75) would have oscillated the sheet height
  // at every Demo boundary now that swipe is continuous across tabs +
  // exercises — jarring. Bottom-aligned tab content (Plan / Notes /
  // Settings) keeps the most-tapped controls within thumb reach.
  //
  // Earlier history:
  //   * 2026-05-05 — floor raised 0.55 → 0.75 to stop the eye drifting
  //     to the heavily-dimmed underlying Studio.
  //   * Round 3 (2026-05-03) — the floor is the FLOOR; releases below
  //     stay pinned at the floor. Dismiss is via fast downward fling
  //     (>800), tap-outside (frosted-scrim layer), or explicit close.
  static const double _kMinDetent = 0.75;
  static const double _kMaxDetent = 0.95;

  /// Velocity threshold (logical pt/sec) for fling-down dismissal. Slow
  /// drags below the floor snap back to 0.75 instead of dismissing.
  static const double _kFlingDismissVelocity = 800;

  /// Number of `(exerciseIndex, tabIndex)` cells per non-rest exercise.
  /// Mirrors the four [ExerciseEditorTab] enum values.
  static const int _kNonRestCellsPerExercise = 4;

  /// Virtual cycle multiplier for the continuous wrap PageView. Total
  /// page item count = `cycleLength * _kCycleRepeats`; start near the
  /// midpoint so the practitioner has thousands of cycles of headroom
  /// in either direction. 10000 cycles × ~20 cells/session ≈ 200k
  /// pages — plenty.
  static const int _kCycleRepeats = 10000;

  late final DraggableScrollableController _sheetController;
  late final PageController _pageController;
  late int _exerciseIndex;
  late ExerciseCapture _exercise;
  // Local mirror of `widget.session.exercises`. The widget reference is
  // captured at sheet-open time and never updates, so reading from it
  // when navigating between exercises returns stale snapshots — any
  // edits made earlier in the same sheet session would be silently
  // dropped on navigate-and-return (and a subsequent _emit would write
  // the stale state back to the parent, clobbering SQLite). Every
  // _emit mirrors its update into this list; _navigateExercise reads
  // from it.
  late List<ExerciseCapture> _exercises;
  int _activeTabIndex = 0;
  // When an animateToPage is in flight (chevron-jump or multi-tab tab-
  // strip tap), `_onPageChanged` fires for every intermediate page the
  // animation crosses. Without a sentinel the bottom rail would flicker
  // through each intermediate exercise. While set, intermediate page
  // crosses are ignored; only the final page applies state.
  int? _pendingFinalPage;
  String? _activeSettingsKey;
  final FocusNode _notesFocusNode = FocusNode();
  // One Notes controller per exercise id. PageView.builder eagerly
  // constructs the adjacent pages, so each cell needs its own
  // controller — building a single `_notesController` inside the
  // active page only would either leak (controllers re-created on
  // every setState) or flicker (different widget tree per cell).
  // Lifetime: lazy-created on first render of each Notes cell;
  // disposed all together when the sheet dismisses.
  final Map<String, TextEditingController> _notesControllers = {};

  TextEditingController _notesControllerFor(ExerciseCapture ex) {
    return _notesControllers.putIfAbsent(
      ex.id,
      () => TextEditingController(text: ex.notes ?? ''),
    );
  }

  @override
  void initState() {
    super.initState();
    _exerciseIndex = widget.initialExerciseIndex;
    _exercises = List<ExerciseCapture>.from(widget.session.exercises);
    _exercise = _exercises[_exerciseIndex];
    // Rest exercises render only one tab ("Rest") — clamp the active
    // index to 0 regardless of the requested initialTab so the
    // PageController doesn't init beyond the only valid cell.
    _activeTabIndex =
        _exercise.isRest ? 0 : _tabIndexFor(widget.initialTab);
    _sheetController = DraggableScrollableController();
    _pageController = PageController(
      initialPage: _pageForCell(_exerciseIndex, _activeTabIndex),
    );
    _notesFocusNode.addListener(_onNotesFocusChanged);
  }

  @override
  void dispose() {
    _notesFocusNode.removeListener(_onNotesFocusChanged);
    _notesFocusNode.dispose();
    for (final controller in _notesControllers.values) {
      controller.dispose();
    }
    _notesControllers.clear();
    _pageController.dispose();
    _sheetController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Virtual page-index <-> (exercise, tab) mapping
  // ---------------------------------------------------------------------------

  /// Tabs per exercise (rest exercises contribute exactly one cell).
  int _cellsFor(ExerciseCapture e) =>
      e.isRest ? 1 : _kNonRestCellsPerExercise;

  /// Sum of cells across the whole session — one full wrap cycle.
  int get _cycleLength {
    int n = 0;
    for (final e in _exercises) {
      n += _cellsFor(e);
    }
    return n;
  }

  /// Total item count for the virtual PageView. Modulo `_cycleLength`
  /// of any page index maps back to a (exercise, tab) cell within a
  /// single session cycle.
  int get _itemCount => _cycleLength * _kCycleRepeats;

  /// Resolve a virtual page index to its (exerciseIndex, tabIndex) cell.
  ({int exIdx, int tabIdx}) _cellAt(int page) {
    final cycle = _cycleLength;
    if (cycle == 0) return (exIdx: 0, tabIdx: 0);
    int rem = page % cycle;
    if (rem < 0) rem += cycle; // Dart's `%` is non-negative; defensive.
    for (int i = 0; i < _exercises.length; i++) {
      final w = _cellsFor(_exercises[i]);
      if (rem < w) return (exIdx: i, tabIdx: rem);
      rem -= w;
    }
    return (exIdx: 0, tabIdx: 0); // Unreachable.
  }

  /// Page index for a cell. Computes the NEAREST page that maps to the
  /// requested cell relative to the current PageController position —
  /// so animateToPage walks at most half a cycle, not across the whole
  /// virtual range. Without the nearest-neighbour math, repeated wrap-
  /// arounds would drift the anchor and chevron jumps would animate
  /// across the entire session.
  int _pageForCell(int exIdx, int tabIdx) {
    final cycle = _cycleLength;
    if (cycle == 0) return 0;
    int offset = 0;
    for (int i = 0; i < exIdx; i++) {
      offset += _cellsFor(_exercises[i]);
    }
    offset += tabIdx;
    // If the controller isn't attached yet (initial build), park near
    // the midpoint so wrap headroom exists in both directions.
    if (!_pageController.hasClients) {
      final anchor = (_kCycleRepeats ~/ 2) * cycle;
      return anchor + offset;
    }
    final currentPage = _pageController.page?.round() ??
        ((_kCycleRepeats ~/ 2) * cycle);
    final currentCycleStart = (currentPage ~/ cycle) * cycle;
    // Three candidate pages around the current cycle: previous cycle,
    // current cycle, next cycle. Pick the one whose absolute distance
    // to `currentPage` is smallest.
    final candidates = <int>[
      currentCycleStart - cycle + offset,
      currentCycleStart + offset,
      currentCycleStart + cycle + offset,
    ];
    int best = candidates.first;
    int bestDist = (candidates.first - currentPage).abs();
    for (int i = 1; i < candidates.length; i++) {
      final d = (candidates[i] - currentPage).abs();
      if (d < bestDist) {
        bestDist = d;
        best = candidates[i];
      }
    }
    return best;
  }

  int _tabIndexFor(ExerciseEditorTab t) {
    switch (t) {
      case ExerciseEditorTab.demo:
        return 0;
      case ExerciseEditorTab.plan:
        return 1;
      case ExerciseEditorTab.notes:
        return 2;
      case ExerciseEditorTab.settings:
        return 3;
    }
  }

  void _onNotesFocusChanged() {
    // setState rebuilds the Notes tab so the Done button shows/hides as
    // focus changes. Listener fires on BOTH gain and loss of focus.
    if (mounted) setState(() {});
    // Sheet stays at 0.95 regardless of Notes focus now (ADR-0019).
    // The keyboard appears over the bottom-aligned textarea; no detent
    // change needed.
  }

  /// Tab-strip tap: animate the PageView to the same exercise's chosen
  /// tab. Within-exercise hop — no exercise change.
  void _switchTab(int nextTab) {
    if (nextTab == _activeTabIndex) return;
    if (_exercise.isRest) return; // Rest has only one tab.
    HapticFeedback.selectionClick();
    final targetPage = _pageForCell(_exerciseIndex, nextTab);
    if (!_pageController.hasClients) return;
    _pendingFinalPage = targetPage;
    _pageController
        .animateToPage(
      targetPage,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    )
        .whenComplete(() {
      if (mounted && _pendingFinalPage == targetPage) {
        _pendingFinalPage = null;
      }
    });
  }

  void _onPageChanged(int page) {
    // Ignore intermediate pages while a programmatic animateToPage is in
    // flight (chevron jump or multi-tab tab-strip tap). Only update state
    // when the page settles at the destination — prevents the bottom rail
    // from flashing through every intermediate exercise / tab.
    if (_pendingFinalPage != null && page != _pendingFinalPage) return;
    final cell = _cellAt(page);
    if (cell.exIdx == _exerciseIndex && cell.tabIdx == _activeTabIndex) {
      return;
    }
    final crossedExercise = cell.exIdx != _exerciseIndex;
    setState(() {
      if (crossedExercise) {
        _exerciseIndex = cell.exIdx;
        _exercise = _exercises[cell.exIdx];
        _activeSettingsKey = null;
      }
      _activeTabIndex = cell.tabIdx;
    });
  }

  void _emit(ExerciseCapture next) {
    // Look the exercise up by id, not by current index. _commitHero
    // (Hero tab) awaits a native thumbnail regen that can outlive a
    // user-initiated navigate-next: when the future finally settles,
    // [_exerciseIndex] has already moved on, and a naive
    // `_exercises[_exerciseIndex] = next` would clobber the new active
    // exercise with the previous one's mutation.
    final idx = _exercises.indexWhere((e) => e.id == next.id);
    if (idx < 0) {
      // Defensive: shouldn't happen for in-flight edits since the
      // exercise is in `_exercises` by construction, but bail rather
      // than corrupt the list.
      return;
    }
    setState(() {
      _exercises[idx] = next;
      if (_exerciseIndex == idx) {
        _exercise = next;
      }
    });
    widget.onExerciseChanged(idx, next);
  }

  /// Step the active exercise by ±1 (or jump to a specific index from
  /// a chevron tap / chrome-horizontal-swipe). Out-of-range / no-op
  /// calls are silently ignored — chevrons disable at boundaries, and
  /// the chrome-horizontal-swipe handler also clamps. The continuous
  /// PageView itself wraps; this 1-jump path stays bounded so the
  /// chevrons keep their familiar "first / last" affordance.
  ///
  /// Animates the PageView to the new exercise's first tab — Demo for
  /// non-rest, Rest for rest. The `_onPageChanged` callback then
  /// updates `_exerciseIndex`, resets the Notes controller, and
  /// collapses any open Settings row.
  void _navigateExercise(int newIndex) {
    if (newIndex < 0 || newIndex >= _exercises.length) return;
    if (newIndex == _exerciseIndex) return;
    HapticFeedback.selectionClick();
    if (!_pageController.hasClients) return;
    final targetPage = _pageForCell(newIndex, 0);
    _pendingFinalPage = targetPage;
    _pageController
        .animateToPage(
      targetPage,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    )
        .whenComplete(() {
      if (mounted && _pendingFinalPage == targetPage) {
        _pendingFinalPage = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      controller: _sheetController,
      // Always open at the max detent. 0.75 floor is a manual-drag-only
      // destination now (ADR-0019).
      initialChildSize: _kMaxDetent,
      minChildSize: _kMinDetent,
      maxChildSize: _kMaxDetent,
      snap: true,
      // Two snap stops: 0.75 (floor) and 0.95 (full).
      snapSizes: const [_kMinDetent, _kMaxDetent],
      // CRITICAL: defaults to true. When true, _BottomSheetState.extentChanged
      // (Flutter framework) auto-closes the route the moment extent equals
      // minChildSize — which is exactly where our slow drag-down lands.
      // Disabling this hands all dismissal control back to us. Tap-outside
      // (frosted-scrim layer) remains the canonical "I'm done" gesture.
      shouldCloseOnMinExtent: false,
      expand: false,
      builder: (ctx, scrollController) {
        // Wrap in our own ScaffoldMessenger so showUndoSnackBar fires from
        // PlanTable / etc. land INSIDE the sheet (above the modal barrier),
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
              // Layout inverted 2026-05-06 for one-handed reach. The
              // thumbnail + title + chevrons used to sit at the top
              // (out of thumb range when the sheet snaps to 0.95);
              // they now live in the bottom rail, with the tab strip
              // tucked directly above as a single thumb-zone dock.
              //
              // 2026-05-15 — content-inversion landed (ADR-0019). The
              // PageView is a single continuous virtual stream of
              // (exercise, tab) cells with wrap. Cell pages bottom-
              // align their content (except Demo, which uses the full
              // upper canvas for the video).
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildDragChrome(),
                  Expanded(
                    child: PageView.builder(
                      controller: _pageController,
                      onPageChanged: _onPageChanged,
                      itemCount: _itemCount,
                      itemBuilder: (ctx, page) {
                        final cell = _cellAt(page);
                        final ex = _exercises[cell.exIdx];
                        return _buildCell(ex, cell.tabIdx, scrollController);
                      },
                    ),
                  ),
                  _buildTabStrip(),
                  _buildBottomRail(),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// Renders the body widget for a single virtual cell. The sheet's
  /// own `ScrollController` (from `DraggableScrollableSheet.builder`)
  /// is wired to the currently-visible page only — that's what makes
  /// the inner scroll-to-resize trick work. Off-screen cells receive
  /// `null` so they create their own internal controller (Flutter
  /// manages its lifecycle); attaching the sheet's controller to
  /// every cell would make multi-cell `attach` throw.
  Widget _buildCell(
    ExerciseCapture ex,
    int tabIdx,
    ScrollController activeScrollController,
  ) {
    final isActive = ex.id == _exercise.id && tabIdx == _activeTabIndex;
    final ScrollController? controller =
        isActive ? activeScrollController : null;
    if (ex.isRest) {
      return _buildRestTab(ex, controller);
    }
    switch (tabIdx) {
      case 0:
        return _buildDemoTab(ex);
      case 1:
        return _buildPlanTab(ex, controller);
      case 2:
        return _buildNotesTab(ex, controller);
      case 3:
        return _buildSettingsTab(ex, controller);
      default:
        return const SizedBox.shrink();
    }
  }

  // ---------------------------------------------------------------------------
  // Header chrome
  // ---------------------------------------------------------------------------

  /// Top-of-sheet drag affordance — drag-handle pill only. The thumbnail
  /// + title + chevron-nav cluster has moved to the bottom rail
  /// ([_buildBottomRail]) for one-handed reach, so the chrome is now a
  /// minimal 22pt hit strip that owns vertical resize / horizontal nav
  /// drags at the very top of the sheet.
  Widget _buildDragChrome() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: _onChromeDragUpdate,
      onVerticalDragEnd: _onChromeDragEnd,
      onHorizontalDragEnd: _onChromeHorizontalDragEnd,
      child: SizedBox(
        width: double.infinity,
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
    // jumpTo(0.75) and the sheet would stay parked at Preview's detent).
    const detentTol = 0.005;
    if ((size - _kMinDetent).abs() < detentTol ||
        (size - _kMaxDetent).abs() < detentTol) {
      return;
    }
    // Drag is for resizing ONLY. Dismissal is via tap-outside (the
    // frosted-scrim layer). Velocity-based dismiss was tried in Round 3
    // (>800 pt/s) but caused two bugs: (1) a normal drag-down from 0.95
    // to floor released with enough residual velocity to dismiss instead of snap,
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

  /// Thumb-zone bottom rail — the canonical exercise-nav surface. The
  /// whole rail is the horizontal-swipe drag region (vertical drag still
  /// resizes the sheet so thumb-down-to-dismiss keeps working anywhere).
  /// Far-left + far-right chevrons sit at the rail edge for unambiguous
  /// prominence; a Hero-frame thumbnail and the editable title ride
  /// between them.
  Widget _buildBottomRail() {
    final title = _exercise.name?.trim().isNotEmpty == true
        ? _exercise.name!
        : 'Exercise ${_exercise.position + 1}';
    final canPrev = _exerciseIndex > 0;
    final canNext = _exerciseIndex < _exercises.length - 1;
    final viewPaddingBottom = MediaQuery.of(context).viewPadding.bottom;
    return GestureDetector(
      // translucent so InlineEditableText taps + chevron InkWells still
      // claim their hits via the gesture arena, while the empty rail
      // surface still feeds horizontal drags into the swipe handler.
      behavior: HitTestBehavior.translucent,
      onVerticalDragUpdate: _onChromeDragUpdate,
      onVerticalDragEnd: _onChromeDragEnd,
      onHorizontalDragEnd: _onChromeHorizontalDragEnd,
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.surfaceRaised,
          border: Border(
            top: BorderSide(color: AppColors.surfaceBorder, width: 1),
          ),
        ),
        padding: EdgeInsets.fromLTRB(4, 8, 4, 8 + viewPaddingBottom),
        child: Row(
          children: [
            _BottomRailChevron(
              icon: Icons.chevron_left,
              enabled: canPrev,
              onTap: () => _navigateExercise(_exerciseIndex - 1),
            ),
            const SizedBox(width: 4),
            // Static Hero-frame thumbnail. MiniPreview's _HeroFrameImage
            // uses an mtime-keyed cache (see hero_file_image.dart) so the
            // glyph repaints the moment ConversionService finishes a
            // hero-frame regen — even though the JPG path doesn't change.
            MiniPreview(
              exercise: _exercise,
              width: 56,
              height: 40,
              borderRadius: BorderRadius.circular(8),
              staticHero: true,
              cropOffset: _exercise.heroCropOffset,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  InlineEditableText(
                    key: ValueKey(
                        'rail-title-${_exercise.id}-${_exercise.position}'),
                    initialValue: title,
                    hintText: 'Name this exercise…',
                    onCommit: (next) =>
                        _emit(_exercise.copyWith(name: next)),
                    textStyle: const TextStyle(
                      fontFamily: 'Montserrat',
                      fontSize: 15,
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
                      fontSize: 10,
                      color: AppColors.textSecondaryOnDark,
                      letterSpacing: 0.3,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            _BottomRailChevron(
              icon: Icons.chevron_right,
              enabled: canNext,
              onTap: () => _navigateExercise(_exerciseIndex + 1),
            ),
          ],
        ),
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
    final tabs = _exercise.isRest
        ? const ['Rest']
        : const ['Demo', 'Plan', 'Notes', 'Settings'];
    // 2026-05-06 — tab strip now sits between page content and the
    // bottom rail. Top hairline separates from page content; the
    // rail's own top border supplies the divider on the other side
    // (avoids the doubled-hairline that comes from stacking two
    // adjacent borders).
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragUpdate: _onChromeDragUpdate,
      onVerticalDragEnd: _onChromeDragEnd,
      child: Container(
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: AppColors.surfaceBorder, width: 1),
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
                  // Tabs sit BELOW the page content now, so the active
                  // indicator hangs off the TOP edge to point up at the
                  // content it controls.
                  decoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(
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

  /// Demo tab — embeds [MediaViewerBody] for the practitioner to verify
  /// what the client will see. Uses the full PageView canvas (no bottom-
  /// alignment) — the video IS the content, and treatment / trim
  /// affordances live inside the embed.
  Widget _buildDemoTab(ExerciseCapture ex) {
    if (ex.isRest) {
      // Rest exercises don't reach this branch (they're 1-cell with
      // their own `_buildRestTab`), but guard defensively.
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Rest periods have no media to demo.',
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
      // Force re-mount on chevron / dot navigation. MediaViewerBody owns
      // its own VideoPlayerController and treatment-state — without a
      // unique key it doesn't pick up the new exercise via didUpdateWidget.
      key: ValueKey('demo-tab-${ex.id}'),
      exercises: [ex],
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

  Widget _buildPlanTab(
    ExerciseCapture ex,
    ScrollController? scrollController,
  ) {
    final cycles = _circuitCyclesFor(ex);
    // Round 2 — bottom padding mirrors MediaQuery.viewInsets.bottom so
    // the iOS keyboard (when the inline custom-value editor opens)
    // doesn't cover the bottom rows of the table OR the inline editor
    // itself. Scrollable.ensureVisible inside PresetChipRow handles
    // the centring; this padding prevents the sheet's bottom from
    // getting clipped.
    final keyboardInset = MediaQuery.of(context).viewInsets.bottom;
    return _BottomAlignedTab(
      scrollController: scrollController,
      padding: EdgeInsets.fromLTRB(16, 16, 16, 24 + keyboardInset),
      child: PlanTable(
        sets: ex.sets,
        onSetsChanged: (sets) => _emit(ex.copyWith(sets: sets)),
        circuitCycles: cycles,
      ),
    );
  }

  /// Resolved circuit cycle count for the given exercise, or null when
  /// it isn't part of a circuit.
  int? _circuitCyclesFor(ExerciseCapture ex) {
    final circuitId = ex.circuitId;
    if (circuitId == null) return null;
    return widget.session.circuitCycles[circuitId];
  }

  Widget _buildNotesTab(
    ExerciseCapture ex,
    ScrollController? scrollController,
  ) {
    final keyboardInset = MediaQuery.of(context).viewInsets.bottom;
    final isActive = ex.id == _exercise.id;
    final controller = _notesControllerFor(ex);
    return GestureDetector(
      // Tap anywhere outside the textarea dismisses the keyboard. translucent
      // so the TextField still claims its own taps via the gesture arena.
      behavior: HitTestBehavior.translucent,
      onTap: () => _notesFocusNode.unfocus(),
      child: _BottomAlignedTab(
        scrollController: scrollController,
        padding: EdgeInsets.fromLTRB(16, 8, 16, 24 + keyboardInset),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Done button — only takes vertical space when visible, so the
            // textarea sits flush under the tab strip when the keyboard
            // is closed. Only the active Notes cell can have focus.
            if (isActive && _notesFocusNode.hasFocus)
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
              controller: controller,
              focusNode: isActive ? _notesFocusNode : null,
              minLines: 8,
              maxLines: null,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              onChanged: (text) => _emit(ex.copyWith(notes: text)),
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

  /// Rest-exercise editor body. Single collapsible row (label "Rest
  /// period" + summary "${seconds}s") that expands a [PresetChipRow]
  /// of canonical durations. Mirrors the rest-bar in Studio so the
  /// affordance is familiar when the practitioner taps a rest from
  /// the editor sheet. Bottom-aligned per ADR-0019.
  Widget _buildRestTab(
    ExerciseCapture ex,
    ScrollController? scrollController,
  ) {
    final restSecs = ex.restHoldSeconds ?? 30;
    final keyboardInset = MediaQuery.of(context).viewInsets.bottom;
    final isActive = ex.id == _exercise.id;
    return _BottomAlignedTab(
      scrollController: scrollController,
      padding: EdgeInsets.fromLTRB(16, 16, 16, 24 + keyboardInset),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _CollapsibleSettingsRow(
            label: 'Rest period',
            summary: _formatRestSummary(restSecs),
            isExpanded: isActive && _activeSettingsKey == 'rest',
            onTap: () => setState(() {
              _activeSettingsKey =
                  _activeSettingsKey == 'rest' ? null : 'rest';
            }),
            editor: PresetChipRow(
              controlKey: 'rest',
              canonicalPresets: const <num>[15, 30, 60, 90],
              currentValue: restSecs,
              accentColor: AppColors.rest,
              displayFormat: (v) => _formatRestSummary(v.round()),
              undoLabel: 'rest',
              scrollable: false,
              onChanged: (v) {
                _emit(ex.copyWith(restHoldSeconds: v.round()));
                setState(() => _activeSettingsKey = null);
              },
            ),
          ),
        ],
      ),
    );
  }

  /// `s < 60 → "${s}s"`, else `"${m}m"` or `"${m}m${s}s"` — mirrors
  /// the rest-bar `_format` helper in `studio_mode_screen.dart`.
  String _formatRestSummary(int seconds) {
    if (seconds < 60) return '${seconds}s';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    if (s == 0) return '${m}m';
    return '${m}m${s}s';
  }


  Widget _buildSettingsTab(
    ExerciseCapture ex,
    ScrollController? scrollController,
  ) {
    final prepSeconds = ex.prepSeconds ?? 5;
    final videoReps = ex.videoRepsPerLoop ?? 3;
    final keyboardInset = MediaQuery.of(context).viewInsets.bottom;
    final isActive = ex.id == _exercise.id;
    return _BottomAlignedTab(
      scrollController: scrollController,
      padding: EdgeInsets.fromLTRB(16, 16, 16, 24 + keyboardInset),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _CollapsibleSettingsRow(
            label: 'Prep seconds',
            summary: '${prepSeconds}s',
            isExpanded: isActive && _activeSettingsKey == 'prep',
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
                _emit(ex.copyWith(prepSeconds: v.round()));
                setState(() => _activeSettingsKey = null);
              },
            ),
          ),
          if (ex.mediaType == MediaType.video) ...[
            const SizedBox(height: 8),
            _CollapsibleSettingsRow(
              label: 'Reps in Video',
              summary: '$videoReps',
              isExpanded:
                  isActive && _activeSettingsKey == 'videoRepsPerLoop',
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
                  _emit(ex.copyWith(videoRepsPerLoop: v.round()));
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

/// Edge-aligned chevron for the bottom rail — 48×48 tap target, 30pt
/// coral glyph for prominence at thumb reach. No drop shadow (the rail's
/// surfaceRaised background gives the glyph a clean substrate, unlike the
/// retired overlay which had to read against a moving video).
///
/// Disabled state (at the first / last exercise) drops opacity and
/// nulls the tap handler so it's an unambiguous no-op.
class _BottomRailChevron extends StatelessWidget {
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  const _BottomRailChevron({
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = enabled
        ? AppColors.primary
        : AppColors.primary.withValues(alpha: 0.30);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(24),
        child: SizedBox(
          width: 48,
          height: 48,
          child: Center(
            child: Icon(icon, size: 30, color: color),
          ),
        ),
      ),
    );
  }
}

/// Bottom-aligned tab body wrapper (ADR-0019 inversion extension —
/// 2026-05-15). Wraps content in a `SingleChildScrollView` whose child
/// is a [Column] with `MainAxisAlignment.end`, sized to at least the
/// viewport height. Result: when the content is shorter than the
/// available canvas, empty space sits at the top and the controls
/// pin to the bottom — within thumb reach above the tab strip. When
/// the content is taller, the scroll handles overflow as normal.
///
/// Demo tab does NOT use this — it owns the full upper canvas for the
/// embedded video.
class _BottomAlignedTab extends StatelessWidget {
  /// `null` for off-screen cells — the inner `SingleChildScrollView`
  /// then creates its own internal controller. Only the currently-
  /// visible cell receives the sheet's own controller so the
  /// scroll-to-resize trick works without `attach`-ing the same
  /// controller to multiple scrollables.
  final ScrollController? scrollController;
  final EdgeInsets padding;
  final Widget child;
  final ScrollViewKeyboardDismissBehavior keyboardDismissBehavior;

  const _BottomAlignedTab({
    required this.scrollController,
    required this.padding,
    required this.child,
    this.keyboardDismissBehavior = ScrollViewKeyboardDismissBehavior.manual,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, constraints) {
        // Available content height = viewport minus our own padding,
        // clamped to non-negative. ConstrainedBox(minHeight:) forces
        // the Column to occupy at least that height so
        // MainAxisAlignment.end can push the child to the bottom.
        final minHeight =
            (constraints.maxHeight - padding.top - padding.bottom)
                .clamp(0.0, double.infinity);
        return SingleChildScrollView(
          controller: scrollController,
          keyboardDismissBehavior: keyboardDismissBehavior,
          padding: padding,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: minHeight),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisAlignment: MainAxisAlignment.end,
              mainAxisSize: MainAxisSize.max,
              children: [child],
            ),
          ),
        );
      },
    );
  }
}

/// Collapsible row for the Settings tab — mirrors the Plan-table pattern
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
                DashedUnderline(
                  child: Text(
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

