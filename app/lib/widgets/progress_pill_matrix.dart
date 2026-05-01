import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/exercise_capture.dart';
import '../models/session.dart';
import '../theme.dart';

// ---------------------------------------------------------------------------
// Progress-pill matrix — novel workout progress visualisation.
//
// Replaces the single linear progress bar at the top of the preview screen
// with a horizontally-scrolling grid of exercise pills. Each circuit round
// stacks vertically under the circuit's columns. The active pill is always
// centred in the viewport, pulses coral on its border, and fills left-to-right
// with the live timer.
//
// Design canonical source: docs/design/mockups/progress-pills.html.
// ---------------------------------------------------------------------------

/// Callback fired when the user releases a long-press on a new pill.
/// Consumers should call PageController.jumpToPage (or equivalent) to make
/// [slideIndex] the active slide and reset its timer.
typedef OnJumpToSlide = void Function(int slideIndex);

/// Size tiers — swapped by density so long plans still fit the viewport.
enum _PillSize { spacious, medium, dense }

class _PillSpec {
  final double width;
  final double height;
  final double fontSize;

  /// When true, pills show REDUCED shorthand: `sets|reps` for standalone,
  /// `reps` only for circuit members. Used at the dense tier where the
  /// full grammar (`sets|reps|hold`) won't fit. Full grammar available
  /// via the long-press peek regardless of tier.
  final bool compactLabel;

  const _PillSpec({
    required this.width,
    required this.height,
    required this.fontSize,
    required this.compactLabel,
  });
}

_PillSpec _specFor(_PillSize size) {
  // Pills are intentionally narrow — the active-exercise details row
  // at the bottom of the matrix carries the full decoded grammar, so
  // the pills themselves can shrink toward a dense progress strip. The
  // goal is maximum at-a-glance visibility of the whole plan.
  switch (size) {
    case _PillSize.spacious:
      return const _PillSpec(
        width: 28,
        height: 22,
        fontSize: 10,
        compactLabel: false,
      );
    case _PillSize.medium:
      return const _PillSpec(
        width: 22,
        height: 20,
        fontSize: 9,
        compactLabel: true,
      );
    case _PillSize.dense:
      return const _PillSpec(
        width: 16,
        height: 18,
        fontSize: 9,
        compactLabel: true,
      );
  }
}

const double _kPillGap = 8.0;
const double _kCircuitBandInset = 6.0;
const Duration _kScrollDuration = Duration(milliseconds: 300);
const double _kEdgeFadeWidth = 40.0;
const Cubic _kEmphasized = Cubic(0.16, 1, 0.3, 1);
const Duration _kPulseDuration = Duration(milliseconds: 1400);

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

/// A single column in the matrix.
///
/// Standalone exercises produce a column with exactly one cell.
/// Circuit groups produce a column with one cell per cycle (row N = cycle N).
class _Column {
  /// Slide indices for each row. First entry is row 1 (cycle 1).
  final List<int> slideIndices;

  /// True when this column participates in a circuit band.
  final bool isCircuit;

  const _Column({required this.slideIndices, required this.isCircuit});
}

/// Groups a contiguous run of circuit columns — for painting the coral tint
/// band that spans them.
class _CircuitBand {
  final int startColumn; // inclusive
  final int endColumn; // exclusive
  final int rowCount; // number of cycles (rows)
  const _CircuitBand({
    required this.startColumn,
    required this.endColumn,
    required this.rowCount,
  });
}

/// A row-aware description of a single slide — populated from the unrolled
/// slide list + Session metadata.
class ProgressPillSlide {
  /// Index into the unrolled slide list (what [PageController.jumpToPage]
  /// wants).
  final int slideIndex;

  /// The exercise captured at this slide.
  final ExerciseCapture exercise;

  /// Circuit id (null if standalone).
  final String? circuitId;

  /// 1-based cycle number. Null if standalone.
  final int? cycle;

  /// 1-based position within the circuit. Null if standalone.
  final int? positionInCircuit;

  /// Total number of cycles in this circuit. Null if standalone.
  final int? totalCycles;

  /// Number to render on the pill itself. For standalone non-rest
  /// exercises this is a running count (1, 2, 3 across the whole plan,
  /// skipping rests). For circuit members it is the exercise's position
  /// WITHIN the circuit group (ignoring any rests inside the circuit);
  /// so every cycle of a 2-exercise circuit reads as "1, 2". Null for
  /// rest slides — those render "Rest" instead.
  final int? displayNumber;

  const ProgressPillSlide({
    required this.slideIndex,
    required this.exercise,
    this.circuitId,
    this.cycle,
    this.positionInCircuit,
    this.totalCycles,
    this.displayNumber,
  });

  bool get isRest => exercise.isRest;
  bool get isCircuit => circuitId != null;
}

/// Build the flat slide list in the same order [PlanPreviewScreen] uses.
/// Circuits are unrolled cycle-by-cycle.
List<ProgressPillSlide> buildProgressPillSlides(Session session) {
  final exercises = session.exercises;
  final out = <ProgressPillSlide>[];
  var i = 0;
  var slideIdx = 0;
  // Running count of non-rest exercises across the whole plan. Rests don't
  // increment so standalone pills read as "1, 2, 3…" continuously.
  var planExerciseNumber = 0;
  while (i < exercises.length) {
    final ex = exercises[i];
    if (ex.circuitId == null) {
      int? number;
      if (!ex.isRest) {
        planExerciseNumber++;
        number = planExerciseNumber;
      }
      out.add(ProgressPillSlide(
        slideIndex: slideIdx++,
        exercise: ex,
        displayNumber: number,
      ));
      i++;
    } else {
      final circuitId = ex.circuitId!;
      final groupStart = i;
      while (i < exercises.length && exercises[i].circuitId == circuitId) {
        i++;
      }
      final groupEnd = i;
      final groupSize = groupEnd - groupStart;
      final total = session.getCircuitCycles(circuitId);
      for (var cycle = 1; cycle <= total; cycle++) {
        // Per-cycle counter so each round's exercises read "1, 2, 3…"
        // rather than continuing the plan-wide sequential numbering.
        var cycleExerciseNumber = 0;
        for (var pos = 0; pos < groupSize; pos++) {
          final e = exercises[groupStart + pos];
          int? number;
          if (!e.isRest) {
            cycleExerciseNumber++;
            number = cycleExerciseNumber;
          }
          out.add(ProgressPillSlide(
            slideIndex: slideIdx++,
            exercise: e,
            circuitId: circuitId,
            cycle: cycle,
            positionInCircuit: pos + 1,
            totalCycles: total,
            displayNumber: number,
          ));
        }
      }
    }
  }
  return out;
}

/// Collapse the slide list into columns. Standalone slides become 1-row
/// columns. Each exercise in a circuit becomes its own column, with one row
/// per cycle (cycle 1 on top).
List<_Column> _buildColumns(List<ProgressPillSlide> slides) {
  final columns = <_Column>[];
  var i = 0;
  while (i < slides.length) {
    final s = slides[i];
    if (!s.isCircuit) {
      columns.add(_Column(slideIndices: [i], isCircuit: false));
      i++;
    } else {
      // A circuit of N exercises × M cycles contributes N columns.
      final circuitId = s.circuitId!;
      final groupStart = i;
      // First collect just cycle 1 to discover the column count.
      final firstCycleSlides = <int>[];
      while (i < slides.length &&
          slides[i].circuitId == circuitId &&
          slides[i].cycle == 1) {
        firstCycleSlides.add(i);
        i++;
      }
      final groupSize = firstCycleSlides.length;
      final totalCycles = slides[groupStart].totalCycles ?? 1;
      // Columns: one per position within the circuit. Rows: cycle 1..totalCycles.
      for (var pos = 0; pos < groupSize; pos++) {
        final rowsForColumn = <int>[];
        for (var cycle = 1; cycle <= totalCycles; cycle++) {
          // The slide index for (pos, cycle) is groupStart + (cycle-1)*groupSize + pos.
          rowsForColumn.add(groupStart + (cycle - 1) * groupSize + pos);
        }
        columns.add(_Column(slideIndices: rowsForColumn, isCircuit: true));
      }
      // Skip past the rest of the circuit in the slides list.
      i = groupStart + groupSize * totalCycles;
    }
  }
  return columns;
}

/// Build a list of circuit bands — contiguous circuit columns that share a
/// circuit id. Used for painting the coral tint.
List<_CircuitBand> _buildBands(
    List<_Column> columns, List<ProgressPillSlide> slides) {
  final bands = <_CircuitBand>[];
  var i = 0;
  while (i < columns.length) {
    final col = columns[i];
    if (!col.isCircuit) {
      i++;
      continue;
    }
    // Group consecutive circuit columns that share the same underlying
    // circuit id.
    final firstSlide = slides[col.slideIndices.first];
    final circuitId = firstSlide.circuitId;
    final start = i;
    while (i < columns.length &&
        columns[i].isCircuit &&
        slides[columns[i].slideIndices.first].circuitId == circuitId) {
      i++;
    }
    final rows = columns[start].slideIndices.length;
    bands.add(_CircuitBand(startColumn: start, endColumn: i, rowCount: rows));
  }
  return bands;
}

// ---------------------------------------------------------------------------
// Widget
// ---------------------------------------------------------------------------

class ProgressPillMatrix extends StatefulWidget {
  /// Unrolled slide list — same shape [PlanPreviewScreen] uses. Use
  /// [buildProgressPillSlides] to produce this.
  final List<ProgressPillSlide> slides;

  /// Index of the active slide (0-based), or -1 when no slide is active yet.
  final int activeSlideIndex;

  /// Timer progress 0..1 for the active pill's fill bar.
  final double timerProgress;

  /// When true, the fill-bar animation is frozen (e.g. during a long-press).
  final bool paused;

  /// Seconds of workout time remaining. Parent is authoritative: when the
  /// exercise timer is running this should tick down each second; when paused
  /// it should hold steady. The ETA widget uses this + live DateTime.now() to
  /// render "X left" (from this value) and "~finish-time" (= now + this), so
  /// the finish time naturally drifts forward while paused and stays fixed
  /// while running. Pass a negative value (e.g. -1) to render the completed
  /// "Done" state.
  final int remainingSeconds;

  /// True once the workout has finished. Shows the "Done" end state.
  final bool workoutComplete;

  /// Seconds remaining for the CURRENT slide (or prep countdown during
  /// the prep phase). Shown as a bold coral leading token in the top
  /// row: `1:36 · 7:42 left · ~7:42 PM`. Pass a negative value to omit
  /// the current-slide token entirely.
  final int currentSlideRemainingSeconds;

  /// True while the active slide is in the 15-second prep phase. When set,
  /// the active pill's pulse-glow border + the ETA "remaining" readout both
  /// opacity-flash (600ms ease-in-out, 1.0 → 0.4 → 1.0) in sync with the
  /// top-bar counter chip. Exits cleanly when the exercise timer takes over.
  final bool isPrepPhase;

  /// Called when the user releases a long-press on a different pill. Consumers
  /// should [PageController.jumpToPage] and reset the timer.
  final OnJumpToSlide? onJumpTo;

  const ProgressPillMatrix({
    super.key,
    required this.slides,
    required this.activeSlideIndex,
    this.timerProgress = 0.0,
    this.paused = false,
    this.remainingSeconds = 0,
    this.currentSlideRemainingSeconds = -1,
    this.workoutComplete = false,
    this.isPrepPhase = false,
    this.onJumpTo,
  });

  @override
  State<ProgressPillMatrix> createState() => _ProgressPillMatrixState();
}

class _ProgressPillMatrixState extends State<ProgressPillMatrix>
    with TickerProviderStateMixin {
  late AnimationController _pulseController;

  /// Fast 600ms ease-in-out opacity cycle used during the prep phase only.
  /// Drives both the ETA "remaining" readout flash and the active pill's
  /// border/fill flash so they stay perfectly in sync.
  late AnimationController _prepFlashController;

  /// Manual scrub offset in pixels. When non-zero, the user is dragging the
  /// matrix off-centre; the coral chevron appears and we snap back after 4s.
  double _manualOffset = 0.0;
  Timer? _snapBackTimer;

  /// Pill index currently under the finger during a long-press scrub.
  /// -1 = no active long-press.
  int _scrubbedSlideIndex = -1;
  bool _longPressActive = false;

  OverlayEntry? _peekOverlay;
  final LayerLink _matrixLink = LayerLink();

  /// Timer that auto-dismisses the teaching peek (R-09 onboarding). Cancelled
  /// if the user starts long-press scrubbing mid-dismiss.
  Timer? _teachingPeekTimer;

  late List<_Column> _columns;
  late List<_CircuitBand> _bands;

  /// Maps slideIndex → (column, row).
  late Map<int, _SlideCoord> _coords;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: _kPulseDuration,
    )..repeat();
    _prepFlashController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat(reverse: true);
    _rebuildLayout();
    // Teaching peek — auto-show the decoded meta for the active slide
    // for 2 seconds on every preview session start. Teaches the pipe
    // shorthand via demonstration instead of relying on the user to
    // long-press. See Design Rule R-09 in components.md.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final idx = widget.activeSlideIndex;
      if (idx < 0 || idx >= widget.slides.length) return;
      _showPeek(idx);
      _teachingPeekTimer = Timer(const Duration(seconds: 2), () {
        if (!mounted) return;
        // Don't dismiss if the user has since started scrubbing — their
        // own peek takes over.
        if (_longPressActive) return;
        _removePeek();
      });
    });
  }

  @override
  void didUpdateWidget(covariant ProgressPillMatrix oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.slides != widget.slides ||
        oldWidget.slides.length != widget.slides.length) {
      _rebuildLayout();
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _prepFlashController.dispose();
    _snapBackTimer?.cancel();
    _teachingPeekTimer?.cancel();
    _removePeek();
    super.dispose();
  }

  String _activeSlideName() {
    final idx = widget.activeSlideIndex;
    if (idx < 0 || idx >= widget.slides.length) return '';
    final s = widget.slides[idx];
    if (s.isRest) return 'Rest';
    return s.exercise.name ?? 'Exercise ${idx + 1}';
  }

  /// Decoded grammar for the ACTIVE slide — e.g.
  /// "3 sets · 10 reps · 5s hold" or "10 reps · 5s hold" inside a
  /// circuit. Shown permanently in the matrix's bottom row so the
  /// user always sees the full sets/reps/hold for whatever they're
  /// currently on, without needing to long-press the pill.
  ///
  /// Exercises with null reps/sets get defaults (10 reps, 3 sets) to
  /// match the preview card's legacy badge fallback. The matrix never
  /// shows bare duration — there's always a reps/sets read.
  String _activeSlideDetail() {
    final idx = widget.activeSlideIndex;
    if (idx < 0 || idx >= widget.slides.length) return '';
    final slide = widget.slides[idx];
    if (slide.isRest) {
      final dur = slide.exercise.restHoldSeconds ?? 30;
      return '${dur}s rest';
    }
    final e = slide.exercise;
    final firstSet = e.sets.isNotEmpty ? e.sets.first : null;
    final r = firstSet?.reps ?? 10;
    final s = e.sets.isEmpty ? 1 : e.sets.length;
    final hold = firstSet?.holdSeconds ?? 0;
    final isCircuit = slide.circuitId != null;
    final parts = <String>[];
    if (!isCircuit) parts.add('$s sets');
    parts.add('$r reps');
    if (hold > 0) parts.add('${hold}s hold');
    // No cycle suffix — the matrix's active-row position already
    // communicates which cycle the user is in.
    return parts.join(' · ');
  }

  void _rebuildLayout() {
    _columns = _buildColumns(widget.slides);
    _bands = _buildBands(_columns, widget.slides);
    _coords = <int, _SlideCoord>{};
    for (var c = 0; c < _columns.length; c++) {
      final col = _columns[c];
      for (var r = 0; r < col.slideIndices.length; r++) {
        _coords[col.slideIndices[r]] = _SlideCoord(column: c, row: r);
      }
    }
  }

  // -------------------------------------------------------------------------
  // Size-tier heuristic
  // -------------------------------------------------------------------------

  _PillSize _sizeFor(double viewportWidth) {
    final cols = _columns.length;
    if (cols == 0) return _PillSize.spacious;
    final spaciousW = _specFor(_PillSize.spacious).width + _kPillGap;
    final mediumW = _specFor(_PillSize.medium).width + _kPillGap;
    // Pick the LARGEST tier where the full track fits in the viewport
    // without scrolling. The pill matrix should prefer "show everything
    // at once" to "scroll to the active pill" — scroll is a fallback
    // only when even the dense tier can't fit the whole plan.
    final spaciousTrack = cols * spaciousW - _kPillGap;
    final mediumTrack = cols * mediumW - _kPillGap;
    if (spaciousTrack <= viewportWidth) return _PillSize.spacious;
    if (mediumTrack <= viewportWidth) return _PillSize.medium;
    return _PillSize.dense;
  }

  // -------------------------------------------------------------------------
  // Scroll offset
  // -------------------------------------------------------------------------

  /// Compute the x-offset (pixels) that the inner track should translate by
  /// so the viewport shows as much of the plan as possible while keeping
  /// the active pill visible — ideally centred, but clamped so no empty
  /// gutter appears on either side.
  double _computeCenteringOffset(
      double viewportWidth, _PillSpec spec, int activeColumn) {
    final stride = spec.width + _kPillGap;
    // Track width = N columns of stride with the last trailing _kPillGap
    // trimmed off the end.
    final trackWidth = _columns.length * stride - _kPillGap;

    // If the whole track fits in the viewport, show it anchored LEFT.
    if (trackWidth <= viewportWidth) return 0;

    final activeCentre = activeColumn * stride + spec.width / 2;
    final centered = (viewportWidth / 2) - activeCentre;

    // Clamp so the track always fills the viewport edge-to-edge: no
    // empty space on the right when active is near the end of the
    // plan, and no empty space on the left when active is near the
    // start.
    final minOffset = viewportWidth - trackWidth; // most negative
    const maxOffset = 0.0;
    return centered.clamp(minOffset, maxOffset);
  }

  // -------------------------------------------------------------------------
  // Long-press scrubbing
  // -------------------------------------------------------------------------

  int? _hitTest({
    required Offset localPosition,
    required double trackOffsetX,
    required _PillSpec spec,
    required double totalHeight,
  }) {
    final stride = spec.width + _kPillGap;
    final rowStride = spec.height + _kPillGap;
    // localPosition is already in TRACK-LOCAL coordinates because the
    // GestureDetector is the direct child of the AnimatedPositioned
    // that owns trackOffsetX. Subtracting trackOffsetX again was an
    // indexing bug that caused taps to miss or land on the wrong pill
    // whenever the active-centering offset was non-zero.
    final x = localPosition.dx;
    // Pills are laid out at top = rowIndex * rowStride + _kCircuitBandInset.
    // Shift y so row 0 starts at yAdj = 0.
    final yAdj = localPosition.dy - _kCircuitBandInset;
    if (x < 0 || yAdj < -_kCircuitBandInset) return null;
    final col = (x / stride).floor();
    if (col < 0 || col >= _columns.length) return null;
    final clampedY = yAdj < 0 ? 0.0 : yAdj;
    final rowIndex = (clampedY / rowStride).floor();
    final column = _columns[col];
    if (rowIndex < 0 || rowIndex >= column.slideIndices.length) return null;
    // trackOffsetX/totalHeight are intentionally accepted for API symmetry.
    return column.slideIndices[rowIndex];
  }

  /// Tap-to-jump. A quick tap on a pill navigates immediately to the
  /// corresponding slide — long-press is reserved for the peek-preview
  /// scrub flow.
  void _onTapUp(TapUpDetails details, double trackOffsetX, _PillSpec spec,
      double totalHeight) {
    final hit = _hitTest(
      localPosition: details.localPosition,
      trackOffsetX: trackOffsetX,
      spec: spec,
      totalHeight: totalHeight,
    );
    if (hit == null || hit == widget.activeSlideIndex) return;
    HapticFeedback.selectionClick();
    widget.onJumpTo?.call(hit);
  }

  void _onLongPressStart(LongPressStartDetails details, double trackOffsetX,
      _PillSpec spec, double totalHeight) {
    final hit = _hitTest(
      localPosition: details.localPosition,
      trackOffsetX: trackOffsetX,
      spec: spec,
      totalHeight: totalHeight,
    );
    if (hit == null) return;
    setState(() {
      _longPressActive = true;
      _scrubbedSlideIndex = hit;
    });
    HapticFeedback.selectionClick();
    _showPeek(hit);
  }

  void _onLongPressMoveUpdate(LongPressMoveUpdateDetails details,
      double trackOffsetX, _PillSpec spec, double totalHeight) {
    if (!_longPressActive) return;
    final hit = _hitTest(
      localPosition: details.localPosition,
      trackOffsetX: trackOffsetX,
      spec: spec,
      totalHeight: totalHeight,
    );
    if (hit == null || hit == _scrubbedSlideIndex) return;
    setState(() => _scrubbedSlideIndex = hit);
    HapticFeedback.selectionClick();
    _showPeek(hit);
  }

  void _onLongPressEnd(LongPressEndDetails _) {
    if (!_longPressActive) return;
    final target = _scrubbedSlideIndex;
    final current = widget.activeSlideIndex;
    setState(() {
      _longPressActive = false;
      _scrubbedSlideIndex = -1;
    });
    _removePeek();
    if (target != current && target >= 0 && widget.onJumpTo != null) {
      widget.onJumpTo!(target);
    }
  }

  // -------------------------------------------------------------------------
  // Manual swipe (scrub-ahead)
  // -------------------------------------------------------------------------

  void _onHorizontalDragUpdate(DragUpdateDetails d) {
    if (_longPressActive) return;
    _snapBackTimer?.cancel();
    setState(() => _manualOffset += d.delta.dx);
  }

  void _onHorizontalDragEnd(DragEndDetails _) {
    if (_longPressActive) return;
    _snapBackTimer?.cancel();
    _snapBackTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      setState(() => _manualOffset = 0.0);
    });
  }

  // -------------------------------------------------------------------------
  // Peek panel (long-press overlay)
  // -------------------------------------------------------------------------

  void _showPeek(int slideIndex) {
    _removePeek();
    final slide = widget.slides[slideIndex];
    _peekOverlay = OverlayEntry(
      builder: (_) => _PeekOverlay(slide: slide),
    );
    final overlayState = Overlay.maybeOf(context, rootOverlay: true);
    if (overlayState != null) overlayState.insert(_peekOverlay!);
  }

  void _removePeek() {
    _peekOverlay?.remove();
    _peekOverlay = null;
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportWidth = constraints.maxWidth;
        if (widget.slides.isEmpty) {
          return const SizedBox(height: 56);
        }
        final size = _sizeFor(viewportWidth);
        final spec = _specFor(size);

        // Matrix vertical extent: max rows across all columns.
        final maxRows = _columns.fold<int>(
            1, (acc, col) => col.slideIndices.length > acc ? col.slideIndices.length : acc);
        final matrixHeight = maxRows * spec.height +
            (maxRows - 1) * _kPillGap +
            // padding for the band inset so circuits don't clip.
            _kCircuitBandInset * 2;

        // Active column (if any).
        final activeIdx = widget.activeSlideIndex;
        final activeCoord =
            (activeIdx >= 0 && activeIdx < widget.slides.length)
                ? _coords[activeIdx]
                : null;

        // Does the whole track fit within the viewport? If so we lock
        // the track at offset 0, ignore any manual-scrub residue, and
        // disable horizontal drag entirely (further down in the tree).
        // Otherwise we compute the clamped centering offset + honour
        // the manual-scrub delta as before.
        final stride = spec.width + _kPillGap;
        final trackWidth = _columns.length * stride - _kPillGap;
        final trackFits = trackWidth <= viewportWidth;

        final centeringOffset = (activeCoord == null || trackFits)
            ? 0.0
            : _computeCenteringOffset(
                viewportWidth, spec, activeCoord.column);

        final trackOffsetX =
            trackFits ? 0.0 : centeringOffset + _manualOffset;
        final showChevron =
            !trackFits && _manualOffset.abs() > 16 && activeCoord != null;

        return CompositedTransformTarget(
          link: _matrixLink,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Top row: active exercise name (left) + ETA (right).
              // Sits above the scrolling matrix so both stay visible no
              // matter how long the plan is. The name reflects the
              // CURRENT (active) slide, not the scrub target — the peek
              // shows the scrub target when the user long-presses.
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Text(
                        _activeSlideName(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'Montserrat',
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.2,
                          color: AppColors.textOnDark,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    _EtaDisplay(
                      remainingSeconds: widget.remainingSeconds,
                      currentSlideRemainingSeconds:
                          widget.currentSlideRemainingSeconds,
                      workoutComplete: widget.workoutComplete,
                      flashing: widget.isPrepPhase,
                      flashController: _prepFlashController,
                    ),
                  ],
                ),
              ),
              SizedBox(
            height: matrixHeight + 4,
            child: ClipRect(
              child: Stack(
                clipBehavior: Clip.hardEdge,
                children: [
                  // Animated track — circuit bands + pills.
                  AnimatedPositioned(
                    duration: _kScrollDuration,
                    curve: _kEmphasized,
                    left: trackOffsetX,
                    top: 2,
                    height: matrixHeight,
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTapUp: (d) =>
                          _onTapUp(d, trackOffsetX, spec, matrixHeight),
                      // Horizontal drag is disabled when the whole
                      // track fits in the viewport — there's nothing
                      // to scroll. Prevents accidental scrubbing that
                      // would desync the track from its locked 0 offset.
                      onHorizontalDragUpdate:
                          trackFits ? null : _onHorizontalDragUpdate,
                      onHorizontalDragEnd:
                          trackFits ? null : _onHorizontalDragEnd,
                      onLongPressStart: (d) => _onLongPressStart(
                          d, trackOffsetX, spec, matrixHeight),
                      onLongPressMoveUpdate: (d) => _onLongPressMoveUpdate(
                          d, trackOffsetX, spec, matrixHeight),
                      onLongPressEnd: _onLongPressEnd,
                      onLongPressCancel: () {
                        if (_longPressActive) {
                          setState(() {
                            _longPressActive = false;
                            _scrubbedSlideIndex = -1;
                          });
                          _removePeek();
                        }
                      },
                      child: _MatrixTrack(
                        columns: _columns,
                        bands: _bands,
                        slides: widget.slides,
                        spec: spec,
                        activeSlideIndex: activeIdx,
                        scrubSlideIndex: _scrubbedSlideIndex,
                        timerProgress: widget.timerProgress,
                        paused: widget.paused || _longPressActive,
                        pulseController: _pulseController,
                        prepFlashController: _prepFlashController,
                        isPrepPhase: widget.isPrepPhase,
                        remainingSeconds: widget.remainingSeconds,
                        workoutComplete: widget.workoutComplete,
                      ),
                    ),
                  ),

                  // Left-edge fade to surface.bg (40px).
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    width: _kEdgeFadeWidth,
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                            colors: [
                              AppColors.surfaceBg,
                              AppColors.surfaceBg.withValues(alpha: 0),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),

                  // Manual-scrub chevron — points back to active.
                  if (showChevron)
                    Positioned(
                      left: 8,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: _ScrubChevron(pulse: _pulseController),
                      ),
                    ),
                ],
              ),
            ),
          ),
              // Bottom row: decoded grammar for the ACTIVE slide. The
              // pills themselves carry no labels, so this row is the
              // primary "what do I do on this exercise" read. Coral
              // dot separators, 15pt Inter medium — luxurious spacing
              // befitting the information's importance. Cycle info is
              // omitted because the matrix row position already tells
              // you which cycle you're in.
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _activeSlideDetail(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: AppColors.textOnDark,
                      letterSpacing: 0.1,
                      height: 1.2,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SlideCoord {
  final int column;
  final int row;
  const _SlideCoord({required this.column, required this.row});
}

// ---------------------------------------------------------------------------
// Matrix track — renders bands + pills in a Stack
// ---------------------------------------------------------------------------

class _MatrixTrack extends StatelessWidget {
  final List<_Column> columns;
  final List<_CircuitBand> bands;
  final List<ProgressPillSlide> slides;
  final _PillSpec spec;
  final int activeSlideIndex;
  final int scrubSlideIndex;
  final double timerProgress;
  final bool paused;
  final AnimationController pulseController;
  final AnimationController prepFlashController;
  final bool isPrepPhase;
  final int remainingSeconds;
  final bool workoutComplete;

  const _MatrixTrack({
    required this.columns,
    required this.bands,
    required this.slides,
    required this.spec,
    required this.activeSlideIndex,
    required this.scrubSlideIndex,
    required this.timerProgress,
    required this.paused,
    required this.pulseController,
    required this.prepFlashController,
    required this.isPrepPhase,
    required this.remainingSeconds,
    required this.workoutComplete,
  });

  @override
  Widget build(BuildContext context) {
    final stride = spec.width + _kPillGap;
    final rowStride = spec.height + _kPillGap;
    final maxRows = columns.fold<int>(
        1, (acc, col) => col.slideIndices.length > acc ? col.slideIndices.length : acc);
    // Reserve room at the right end for the ETA widget. It scrolls with the
    // matrix so it's OK that it goes off-screen during deep scrub-back. The
    // columns block ends one `_kPillGap` before `columns.length * stride`
    // (the trailing gap after the final column), so we subtract that and
    // then add the ETA gap + slot width.
    // ETA now lives on its OWN row above the matrix (see
    // ProgressPillMatrix.build), not as a trailing slot in the track,
    // so it's always visible regardless of how long the plan is.
    final width = columns.length * stride - _kPillGap;
    final height = maxRows * rowStride - _kPillGap + _kCircuitBandInset * 2;

    final children = <Widget>[];

    // Circuit bands — drawn first so pills render on top.
    for (final band in bands) {
      final left = band.startColumn * stride - _kCircuitBandInset;
      final right = band.endColumn * stride - _kPillGap + _kCircuitBandInset;
      final bandWidth = right - left;
      final bandHeight =
          band.rowCount * rowStride - _kPillGap + _kCircuitBandInset * 2;
      children.add(Positioned(
        left: left,
        top: 0,
        width: bandWidth,
        height: bandHeight,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AppColors.brandTintBg,
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          ),
        ),
      ));
    }

    // Pills.
    for (var c = 0; c < columns.length; c++) {
      final col = columns[c];
      for (var r = 0; r < col.slideIndices.length; r++) {
        final slideIdx = col.slideIndices[r];
        final slide = slides[slideIdx];
        final isActive = slideIdx == activeSlideIndex;
        final isCompleted =
            activeSlideIndex >= 0 && slideIdx < activeSlideIndex;
        final isScrubbed = slideIdx == scrubSlideIndex && scrubSlideIndex >= 0;
        children.add(Positioned(
          left: c * stride,
          top: r * rowStride + _kCircuitBandInset,
          width: spec.width,
          height: spec.height,
          child: _Pill(
            slide: slide,
            spec: spec,
            isActive: isActive,
            isCompleted: isCompleted,
            isScrubbed: isScrubbed,
            paused: paused,
            timerProgress: isActive ? timerProgress : 0.0,
            pulseController: pulseController,
            prepFlashController: prepFlashController,
            isFlashing: isActive && isPrepPhase,
          ),
        ));
      }
    }

    return SizedBox(
      width: width,
      height: height,
      child: Stack(clipBehavior: Clip.none, children: children),
    );
  }
}

// ---------------------------------------------------------------------------
// ETA display — right-aligned two-line readout at the end of row 1.
//
// Line 1: "7:42 left"   — drops by one each second while the workout is
//                         running; holds steady while paused or before start.
// Line 2: "~7:42 PM"    — finish time = DateTime.now() + remainingSeconds.
//                         Owns its own 1s Timer so the wall-clock keeps moving
//                         while the parent's remainingSeconds is static
//                         (paused state). "now() advances, remaining doesn't,
//                         so the finish time drifts forward" — intentional.
//
// After finish, shows "Done".
// ---------------------------------------------------------------------------

class _EtaDisplay extends StatefulWidget {
  final int remainingSeconds;
  final int currentSlideRemainingSeconds;
  final bool workoutComplete;

  /// When true, the "remaining" readout opacity-flashes (1.0 → 0.4 → 1.0)
  /// in sync with [flashController]. Used during the 15-second prep phase so
  /// the top-bar counter + active pill + this widget all pulse in lockstep.
  final bool flashing;
  final AnimationController flashController;

  const _EtaDisplay({
    required this.remainingSeconds,
    required this.currentSlideRemainingSeconds,
    required this.workoutComplete,
    required this.flashing,
    required this.flashController,
  });

  @override
  State<_EtaDisplay> createState() => _EtaDisplayState();
}

class _EtaDisplayState extends State<_EtaDisplay> {
  /// Wall-clock ticker — forces a rebuild every second so the finish time
  /// keeps rolling forward even when the parent hasn't rebuilt (e.g. paused
  /// state where remainingSeconds is static).
  Timer? _clockTimer;

  @override
  void initState() {
    super.initState();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    super.dispose();
  }

  String _formatRemaining(int secs) {
    final s = secs < 0 ? 0 : secs;
    final m = s ~/ 60;
    final r = s % 60;
    return '$m:${r.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    if (widget.workoutComplete) {
      // End state — single centred "Done" label. Keeps the slot occupied so
      // the overall layout doesn't shift on completion.
      return const Align(
        alignment: Alignment.centerRight,
        child: Text(
          'Done',
          textAlign: TextAlign.right,
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: AppColors.textOnDark,
            letterSpacing: -0.2,
          ),
        ),
      );
    }

    final remaining = widget.remainingSeconds < 0 ? 0 : widget.remainingSeconds;
    final finishAt = DateTime.now().add(Duration(seconds: remaining));
    final remainingLabel = _formatRemaining(remaining);
    final finishLabel =
        MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(finishAt),
    );

    // Digits get JetBrainsMono with Menlo/Courier fallback (same pattern as
    // app/lib/widgets/gutter_rail.dart — font isn't bundled, so the fallback
    // is the one that actually renders).
    const monoFamily = 'JetBrainsMono';
    const monoFallback = ['Menlo', 'Courier'];

    final slideRem = widget.currentSlideRemainingSeconds;
    final showSlide = slideRem >= 0;
    final slideLabel = showSlide ? _formatRemaining(slideRem) : '';

    // Bold coral current-slide token. During the 15-second prep phase, this
    // single leftmost token opacity-flashes 1.0 → 0.4 → 1.0 @ 600ms
    // ease-in-out via the shared [flashController], in sync with the active
    // pill + the top-bar counter chip. Per the port spec: flash applies ONLY
    // to this token, not to the "X left" total or the "~finish" wall-clock.
    final slideTokenText = Text(
      slideLabel,
      style: const TextStyle(
        fontFamily: monoFamily,
        fontFamilyFallback: monoFallback,
        fontSize: 13,
        fontWeight: FontWeight.w700,
        color: AppColors.primary,
        letterSpacing: -0.2,
        height: 1.0,
      ),
    );
    final Widget slideTokenAnimated = widget.flashing
        ? AnimatedBuilder(
            animation: widget.flashController,
            builder: (context, child) {
              final eased =
                  Curves.easeInOut.transform(widget.flashController.value);
              final opacity = 1.0 - (eased * 0.6); // 1.0 → 0.4 → 1.0
              return Opacity(opacity: opacity, child: child);
            },
            child: slideTokenText,
          )
        : slideTokenText;

    // Tokens after the leading slide-remaining: " · 7:42 left · ~7:42 PM".
    // Rendered as a single Text.rich so the kerning + vertical alignment
    // match the animated leading token exactly.
    final restOfLine = Text.rich(
      TextSpan(children: [
        TextSpan(
          text: showSlide ? ' · ' : '',
          style: const TextStyle(
            fontFamily: 'Inter',
            fontSize: 11,
            fontWeight: FontWeight.w500,
            color: AppColors.textSecondaryOnDark,
            letterSpacing: 0.1,
            height: 1.0,
          ),
        ),
        TextSpan(
          text: remainingLabel,
          style: const TextStyle(
            fontFamily: monoFamily,
            fontFamilyFallback: monoFallback,
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: AppColors.textOnDark,
            letterSpacing: -0.2,
            height: 1.0,
          ),
        ),
        const TextSpan(
          text: ' · ',
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 11,
            fontWeight: FontWeight.w500,
            color: AppColors.textSecondaryOnDark,
            letterSpacing: 0.1,
            height: 1.0,
          ),
        ),
        TextSpan(
          text: '~$finishLabel',
          style: const TextStyle(
            fontFamily: monoFamily,
            fontFamilyFallback: monoFallback,
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: AppColors.textSecondaryOnDark,
            letterSpacing: -0.2,
            height: 1.0,
          ),
        ),
      ]),
      textAlign: TextAlign.right,
    );

    // One line: "1:36 · 7:42 left · ~7:42 PM". Reading L→R zooms OUT in
    // scope: current exercise → whole workout → wall-clock finish. The
    // current-slide token is bold coral to signal "active now".
    return Align(
      alignment: Alignment.centerRight,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (showSlide) slideTokenAnimated,
          restOfLine,
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Pill — single rounded-rectangle with fill bar + pulse glow
// ---------------------------------------------------------------------------

class _Pill extends StatelessWidget {
  final ProgressPillSlide slide;
  final _PillSpec spec;
  final bool isActive;
  final bool isCompleted;
  final bool isScrubbed;
  final bool paused;
  final double timerProgress;
  final AnimationController pulseController;

  /// 600ms ease-in-out controller shared with the top-bar counter chip and
  /// the ETA readout. Used to drive an opacity flash on the border + fill
  /// when [isFlashing] is true.
  final AnimationController prepFlashController;

  /// True only when this pill is both the active slide AND the workout is in
  /// the 15-second prep phase. Causes the border/fill to opacity-flash in
  /// sync with the top-bar token.
  final bool isFlashing;

  const _Pill({
    required this.slide,
    required this.spec,
    required this.isActive,
    required this.isCompleted,
    required this.isScrubbed,
    required this.paused,
    required this.timerProgress,
    required this.pulseController,
    required this.prepFlashController,
    required this.isFlashing,
  });

  @override
  Widget build(BuildContext context) {
    final isRest = slide.isRest;
    // Choose colours per state.
    //
    // Rest pills preview their sage category EVEN when idle. Otherwise a
    // future rest looks identical to a future exercise and the client
    // has no visual "a break is coming" cue. Subtle sage tint on the
    // backdrop + a sage-tinted border when not active = "you can look
    // forward to this".
    final baseFill = (isRest && !isActive && !isCompleted)
        ? AppColors.rest.withValues(alpha: 0.15)
        : AppColors.surfaceRaised;
    final borderColor = isActive
        ? (isRest ? AppColors.rest : AppColors.primary)
        : (isRest
            ? AppColors.rest.withValues(alpha: 0.55)
            : AppColors.surfaceBorder);
    final borderWidth = isActive ? 2.0 : 1.0;

    // Fill bar colour. Completed pills fill FULLY WITH CORAL (rest
    // pills fill with sage) so the whole matrix gradually "fills up"
    // as the user moves through the plan — a macro progress signal
    // that reads at a glance.
    final fillColor = isCompleted
        ? (isRest ? AppColors.rest : AppColors.primary)
        : isRest
            ? AppColors.rest.withValues(alpha: 0.85)
            : AppColors.primary.withValues(alpha: 0.85);

    final fillWidth = isCompleted
        ? 1.0
        : isActive
            ? timerProgress.clamp(0.0, 1.0)
            : 0.0;

    // No label any more — opacity kept as a constant for the scrubbed-
    // state animation scale to hook into.
    // ignore: unused_local_variable
    final contentOpacity = isCompleted
        ? 0.4
        : isActive
            ? 1.0
            : 0.6;

    // Scrubbed pill gets a brief scale+brighter border.
    final scrubScale = isScrubbed ? 1.06 : 1.0;

    final pillChild = DecoratedBox(
      decoration: BoxDecoration(
        color: baseFill,
        border: Border.all(color: borderColor, width: borderWidth),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppTheme.radiusMd - borderWidth),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Left-to-right fill bar.
            FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: fillWidth,
              child: Container(color: fillColor),
            ),
            // Pills are intentionally empty — colour + position + fill
            // bar carry the visual information. Grammar shows in the
            // matrix's bottom details row and in the long-press peek.
          ],
        ),
      ),
    );

    // Pulse glow — only for active pills. We use box-shadow spread that cycles.
    Widget wrapped = pillChild;
    if (isActive && !paused) {
      wrapped = AnimatedBuilder(
        animation: pulseController,
        builder: (context, child) {
          // Breathing cycle 0→1→0 (sine).
          final t = pulseController.value; // 0..1 linear
          // Same visual timing as the CSS keyframes: box-shadow spread
          // grows from 0 to 8 and opacity fades alpha 0.4 → 0.
          final pulse = t; // 0..1
          final glowOpacity = (1.0 - pulse) * 0.4;
          final spread = pulse * 8.0;
          final glowColor = isRest ? AppColors.rest : AppColors.primary;
          return DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              boxShadow: [
                BoxShadow(
                  color: glowColor.withValues(alpha: glowOpacity),
                  blurRadius: 0,
                  spreadRadius: spread,
                ),
              ],
            ),
            child: child,
          );
        },
        child: wrapped,
      );
    }

    // Prep-phase flash — opacity 1.0 → 0.4 → 1.0 @ 600ms ease-in-out, applied
    // over the entire pill (border + fill + content). Same cadence as the
    // top-bar counter chip and the ETA readout so all three stay visually
    // synchronised. Only the active pill flashes; everything else stays put.
    Widget maybeFlashing = wrapped;
    if (isFlashing) {
      maybeFlashing = AnimatedBuilder(
        animation: prepFlashController,
        builder: (context, child) {
          final eased =
              Curves.easeInOut.transform(prepFlashController.value);
          final opacity = 1.0 - (eased * 0.6); // 1.0 → 0.4 → 1.0
          return Opacity(opacity: opacity, child: child);
        },
        child: wrapped,
      );
    }

    return Semantics(
      label: _semanticsLabelFor(slide),
      button: true,
      child: AnimatedScale(
        scale: scrubScale,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: maybeFlashing,
      ),
    );
  }

  /// VoiceOver / screen-reader label. Spoken in plain English so the
  /// pill is usable even for users who can't see the shorthand.
  static String _semanticsLabelFor(ProgressPillSlide slide) {
    if (slide.isRest) {
      final dur = slide.exercise.restHoldSeconds ?? 30;
      return '$dur second rest';
    }
    final e = slide.exercise;
    final parts = <String>[];
    final name = e.name;
    if (name != null && name.isNotEmpty) parts.add(name);
    if (slide.cycle != null && slide.totalCycles != null) {
      parts.add('cycle ${slide.cycle} of ${slide.totalCycles}');
    }
    final firstSet = e.sets.isNotEmpty ? e.sets.first : null;
    if (firstSet == null) {
      final dur = e.effectiveDurationSeconds;
      if (dur > 0) parts.add('$dur seconds');
    } else {
      if (slide.circuitId == null) {
        parts.add('${e.sets.length} sets');
      }
      parts.add('${firstSet.reps} reps');
      if (firstSet.holdSeconds > 0) {
        parts.add('${firstSet.holdSeconds} second hold');
      }
    }
    return parts.join(', ');
  }
}

// ---------------------------------------------------------------------------
// Scrub chevron — pulsing coral arrow pointing to the active pill after a
// manual scrub.
// ---------------------------------------------------------------------------

class _ScrubChevron extends StatelessWidget {
  final AnimationController pulse;
  const _ScrubChevron({required this.pulse});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: pulse,
      builder: (_, _) {
        final t = pulse.value;
        final spread = t * 6.0;
        final glowOpacity = (1.0 - t) * 0.4;
        return Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.brandTintBg,
            border: Border.all(color: AppColors.brandTintBorder, width: 1),
            boxShadow: [
              BoxShadow(
                color: AppColors.primary.withValues(alpha: glowOpacity),
                blurRadius: 0,
                spreadRadius: spread,
              ),
            ],
          ),
          child: const Icon(
            Icons.chevron_left_rounded,
            color: AppColors.primary,
            size: 16,
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Peek overlay — floats above the pressed pill during a long-press.
// ---------------------------------------------------------------------------

class _PeekOverlay extends StatelessWidget {
  final ProgressPillSlide slide;

  const _PeekOverlay({required this.slide});

  @override
  Widget build(BuildContext context) {
    final nameLine = _nameFor(slide);
    final metaLine = _metaFor(slide);

    // Centered on the whole screen — out of the Dynamic Island / notch's
    // way entirely. During scrub the user's attention is on finding the
    // right exercise, not on the current one, so covering the middle is
    // fine. Also auto-displays for 2s at preview start to TEACH the pipe
    // shorthand users will see on the pills themselves — see the
    // _scheduleTeachingPeek() call in ProgressPillMatrix.initState.
    return IgnorePointer(
      child: SafeArea(
        child: Center(
          child: Material(
            color: Colors.transparent,
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width - 48,
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: 28,
                vertical: 20,
              ),
              decoration: BoxDecoration(
                color: AppColors.surfaceRaised,
                borderRadius: BorderRadius.circular(AppTheme.radiusLg),
                border: Border.all(color: AppColors.primary, width: 2),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    nameLine,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'Montserrat',
                      fontWeight: FontWeight.w700,
                      fontSize: 22,
                      letterSpacing: -0.3,
                      color: AppColors.textOnDark,
                    ),
                  ),
                  if (metaLine.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      metaLine,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'Inter',
                        fontWeight: FontWeight.w500,
                        fontSize: 15,
                        color: AppColors.textSecondaryOnDark,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static String _nameFor(ProgressPillSlide slide) {
    if (slide.isRest) return 'Rest';
    return slide.exercise.name ?? 'Exercise ${slide.slideIndex + 1}';
  }

  /// The DECODED form of the pill grammar — teaches users what the
  /// pipe shorthand on the pill actually means. e.g. `3 sets · 10 reps
  /// · 5s hold` for a `3|10|5` pill.
  static String _metaFor(ProgressPillSlide slide) {
    if (slide.isRest) {
      final dur = slide.exercise.restHoldSeconds ?? 30;
      return '${dur}s';
    }
    final e = slide.exercise;
    final firstSet = e.sets.isNotEmpty ? e.sets.first : null;
    final r = firstSet?.reps ?? 10;
    final s = e.sets.isEmpty ? 1 : e.sets.length;
    final hold = firstSet?.holdSeconds ?? 0;
    final isCircuit = slide.circuitId != null;

    final parts = <String>[];
    if (!isCircuit) parts.add('$s sets');
    parts.add('$r reps');
    if (hold > 0) parts.add('${hold}s hold');

    var line = parts.join(' · ');
    if (isCircuit && slide.cycle != null && slide.totalCycles != null) {
      line += '  ·  cycle ${slide.cycle} of ${slide.totalCycles}';
    }
    return line;
  }
}

