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
  final bool showIcon;
  final bool showLabel;
  final double iconSize;
  final double fontSize;
  const _PillSpec({
    required this.width,
    required this.height,
    required this.showIcon,
    required this.showLabel,
    required this.iconSize,
    required this.fontSize,
  });
}

_PillSpec _specFor(_PillSize size) {
  switch (size) {
    case _PillSize.spacious:
      return const _PillSpec(
        width: 72,
        height: 40,
        showIcon: true,
        showLabel: true,
        iconSize: 14,
        fontSize: 10,
      );
    case _PillSize.medium:
      return const _PillSpec(
        width: 48,
        height: 32,
        showIcon: true,
        showLabel: false,
        iconSize: 16,
        fontSize: 0,
      );
    case _PillSize.dense:
      return const _PillSpec(
        width: 24,
        height: 12,
        showIcon: false,
        showLabel: false,
        iconSize: 0,
        fontSize: 0,
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

  const ProgressPillSlide({
    required this.slideIndex,
    required this.exercise,
    this.circuitId,
    this.cycle,
    this.positionInCircuit,
    this.totalCycles,
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
  while (i < exercises.length) {
    final ex = exercises[i];
    if (ex.circuitId == null) {
      out.add(ProgressPillSlide(slideIndex: slideIdx++, exercise: ex));
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
        for (var pos = 0; pos < groupSize; pos++) {
          final e = exercises[groupStart + pos];
          out.add(ProgressPillSlide(
            slideIndex: slideIdx++,
            exercise: e,
            circuitId: circuitId,
            cycle: cycle,
            positionInCircuit: pos + 1,
            totalCycles: total,
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

  /// Called when the user releases a long-press on a different pill. Consumers
  /// should [PageController.jumpToPage] and reset the timer.
  final OnJumpToSlide? onJumpTo;

  const ProgressPillMatrix({
    super.key,
    required this.slides,
    required this.activeSlideIndex,
    this.timerProgress = 0.0,
    this.paused = false,
    this.onJumpTo,
  });

  @override
  State<ProgressPillMatrix> createState() => _ProgressPillMatrixState();
}

class _ProgressPillMatrixState extends State<ProgressPillMatrix>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;

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
    _rebuildLayout();
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
    _snapBackTimer?.cancel();
    _removePeek();
    super.dispose();
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
    // Comfortable fit: half the columns should show at once.
    if (cols * spaciousW <= viewportWidth * 1.5) return _PillSize.spacious;
    if (cols * mediumW <= viewportWidth * 1.8) return _PillSize.medium;
    return _PillSize.dense;
  }

  // -------------------------------------------------------------------------
  // Scroll offset
  // -------------------------------------------------------------------------

  /// Compute the x-offset (pixels) that the inner track should translate by
  /// to centre the active pill in the viewport.
  double _computeCenteringOffset(
      double viewportWidth, _PillSpec spec, int activeColumn) {
    final stride = spec.width + _kPillGap;
    final activeCentre = activeColumn * stride + spec.width / 2;
    return (viewportWidth / 2) - activeCentre;
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
    // Translate the hit point into track-local coordinates.
    final x = localPosition.dx - trackOffsetX;
    final y = localPosition.dy;
    if (x < -_kPillGap) return null;
    final col = (x / stride).floor();
    if (col < 0 || col >= _columns.length) return null;
    // Row 0 is centred when there's a single row; when there are multiple
    // rows, rows stack down. We'll centre the vertical starting row such that
    // a 1-row column aligns with row 0 of multi-row columns.
    final rowIndex = (y / rowStride).floor().clamp(0, 99);
    final column = _columns[col];
    if (rowIndex < 0 || rowIndex >= column.slideIndices.length) return null;
    // Unused vars silenced:
    // ignore: unused_local_variable
    final _ = totalHeight;
    return column.slideIndices[rowIndex];
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
      builder: (_) => _PeekOverlay(
        link: _matrixLink,
        slide: slide,
      ),
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

        final centeringOffset = activeCoord == null
            ? 0.0
            : _computeCenteringOffset(
                viewportWidth, spec, activeCoord.column);

        final trackOffsetX = centeringOffset + _manualOffset;
        final showChevron = _manualOffset.abs() > 16 && activeCoord != null;

        return CompositedTransformTarget(
          link: _matrixLink,
          child: SizedBox(
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
                      onHorizontalDragUpdate: _onHorizontalDragUpdate,
                      onHorizontalDragEnd: _onHorizontalDragEnd,
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
  });

  @override
  Widget build(BuildContext context) {
    final stride = spec.width + _kPillGap;
    final rowStride = spec.height + _kPillGap;
    final maxRows = columns.fold<int>(
        1, (acc, col) => col.slideIndices.length > acc ? col.slideIndices.length : acc);
    final width = columns.length * stride;
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

  const _Pill({
    required this.slide,
    required this.spec,
    required this.isActive,
    required this.isCompleted,
    required this.isScrubbed,
    required this.paused,
    required this.timerProgress,
    required this.pulseController,
  });

  @override
  Widget build(BuildContext context) {
    final isRest = slide.isRest;
    // Choose colours per state.
    final baseFill = AppColors.surfaceRaised;
    final borderColor = isActive
        ? (isRest ? AppColors.rest : AppColors.primary)
        : AppColors.surfaceBorder;
    final borderWidth = isActive ? 2.0 : 1.0;

    // Fill bar colour.
    final fillColor = isCompleted
        ? AppColors.textSecondaryOnDark.withValues(alpha: 0.55)
        : isRest
            ? AppColors.rest.withValues(alpha: 0.85)
            : AppColors.primary.withValues(alpha: 0.85);

    final fillWidth = isCompleted
        ? 1.0
        : isActive
            ? timerProgress.clamp(0.0, 1.0)
            : 0.0;

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
            if (spec.showIcon || spec.showLabel)
              Center(
                child: Opacity(
                  opacity: contentOpacity,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (spec.showIcon)
                        SizedBox(
                          width: spec.iconSize,
                          height: spec.iconSize,
                          child: CustomPaint(
                            painter: _PillIconPainter(
                              isRest: isRest,
                              color: _iconColor(isRest, isCompleted, isActive),
                            ),
                          ),
                        ),
                      if (spec.showIcon && spec.showLabel)
                        const SizedBox(width: 4),
                      if (spec.showLabel)
                        Flexible(
                          child: Text(
                            _labelFor(slide),
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: spec.fontSize,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.5,
                              color:
                                  _iconColor(isRest, isCompleted, isActive),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
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

    return AnimatedScale(
      scale: scrubScale,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      child: wrapped,
    );
  }

  static Color _iconColor(bool isRest, bool isCompleted, bool isActive) {
    if (isCompleted) return AppColors.textSecondaryOnDark.withValues(alpha: 0.6);
    if (isRest) return AppColors.rest;
    if (isActive) return AppColors.textOnDark;
    return AppColors.textSecondaryOnDark;
  }

  static String _labelFor(ProgressPillSlide slide) {
    if (slide.isRest) return 'REST';
    final name = slide.exercise.name;
    if (name == null || name.isEmpty) return '${slide.slideIndex + 1}';
    // Up to 6 uppercase chars.
    final firstWord = name.split(' ').first;
    final short = firstWord.toUpperCase();
    return short.length > 6 ? short.substring(0, 6) : short;
  }
}

/// Simple inline icon painter — stick-figure body glyph or rest tick.
/// Matches the mockup's generic glyph (stick figure) and rest tick-in-circle.
class _PillIconPainter extends CustomPainter {
  final bool isRest;
  final Color color;

  _PillIconPainter({required this.isRest, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // Scale to the 14×14 viewBox used in the mockup.
    final s = size.width / 14.0;
    Offset p(double x, double y) => Offset(x * s, y * s);

    if (isRest) {
      // Tick in circle: circle cx=7 cy=7 r=4; path M4.5 7 l2 1.5 L9.5 5.5
      canvas.drawCircle(p(7, 7), 4 * s, paint);
      final path = Path()
        ..moveTo(p(4.5, 7).dx, p(4.5, 7).dy)
        ..relativeLineTo(2 * s, 1.5 * s)
        ..lineTo(p(9.5, 5.5).dx, p(9.5, 5.5).dy);
      canvas.drawPath(path, paint);
    } else {
      // Stick figure: head at (7, 3.5) r=1.6; body + arms + legs.
      final fillPaint = Paint()..color = color;
      canvas.drawCircle(p(7, 3.5), 1.6 * s, fillPaint);
      final body = Path()
        ..moveTo(p(7, 5.2).dx, p(7, 5.2).dy)
        ..relativeLineTo(0, 5 * s)
        ..moveTo(p(4, 7.2).dx, p(4, 7.2).dy)
        ..relativeLineTo(6 * s, 0)
        ..moveTo(p(5, 10.2).dx, p(5, 10.2).dy)
        ..relativeLineTo(-1 * s, 2.2 * s)
        ..moveTo(p(9, 10.2).dx, p(9, 10.2).dy)
        ..relativeLineTo(1 * s, 2.2 * s);
      canvas.drawPath(body, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _PillIconPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.isRest != isRest;
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
  final LayerLink link;
  final ProgressPillSlide slide;

  const _PeekOverlay({required this.link, required this.slide});

  @override
  Widget build(BuildContext context) {
    final name = slide.isRest
        ? 'Rest'
        : (slide.exercise.name ?? 'Exercise ${slide.slideIndex + 1}');

    final reps = slide.exercise.reps;
    final sets = slide.exercise.sets;
    final hold = slide.exercise.holdSeconds;
    final metaParts = <String>[];
    if (sets != null && reps != null) {
      metaParts.add('$sets × $reps');
    } else if (reps != null) {
      metaParts.add('$reps reps');
    }
    if (hold != null && hold > 0) metaParts.add('hold ${hold}s');
    final meta = metaParts.join(' · ');

    return Positioned(
      left: 0,
      right: 0,
      child: CompositedTransformFollower(
        link: link,
        showWhenUnlinked: false,
        targetAnchor: Alignment.topCenter,
        followerAnchor: Alignment.bottomCenter,
        offset: const Offset(0, -16),
        child: Center(
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: 200,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.surfaceRaised,
                borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                border: Border.all(color: AppColors.surfaceBorder),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Line-drawing placeholder thumbnail — hatched background.
                  Container(
                    height: 88,
                    decoration: BoxDecoration(
                      color: AppColors.surfaceBase,
                      border: Border.all(color: AppColors.surfaceBorder),
                      borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                    ),
                    child: const Center(
                      child: Icon(
                        Icons.accessibility_new_rounded,
                        size: 40,
                        color: Color(0xFF4B5563),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'Montserrat',
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                      letterSpacing: -0.2,
                      color: AppColors.textOnDark,
                    ),
                  ),
                  if (meta.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      meta,
                      style: const TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 11,
                        color: AppColors.textSecondaryOnDark,
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.only(top: 8),
                    decoration: const BoxDecoration(
                      border: Border(
                        top: BorderSide(
                          color: AppColors.brandTintBorder,
                          width: 1,
                          style: BorderStyle.solid,
                        ),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        Icon(Icons.arrow_forward_rounded,
                            size: 12, color: AppColors.primary),
                        SizedBox(width: 6),
                        Text(
                          'release to jump here',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 11,
                            color: AppColors.primary,
                            letterSpacing: 0.2,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
