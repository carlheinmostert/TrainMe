import 'package:flutter/material.dart';

import '../theme.dart';

/// Wave Lobby (PR 2/4) — practitioner-facing 1:1 crop authoring overlay.
///
/// Drops on top of a video / photo frame in the editor sheet's Preview
/// (Hero) tab while the practitioner picks the Hero moment. The
/// practitioner drags a 1:1 viewport along the source's *free axis* to
/// pick which slice of the frame the lobby tile (PR 4) and every
/// thumbnail consumer (PR 3) renders.
///
/// Geometry:
///   * Free axis = X for landscape sources (`aspectRatio >= 1`).
///   * Free axis = Y for portrait sources (`aspectRatio < 1`).
///   * On a square source the viewport equals the canvas — drag is a no-op.
///
/// The widget paints itself at the canvas size of the displayed media
/// (caller is responsible for matching that — usually by sizing the
/// overlay to the same `AspectRatio` as the underlying media). The 1:1
/// box is computed from those bounds; outside the box renders a 60% sage
/// dim so the practitioner sees the "out" zone explicitly.
///
/// Pan along the constrained axis is silently rejected (the drag tracker
/// only honours deltas on the free axis). Double-tap inside the viewport
/// resets to centre. Linear normalised value `[0.0, 1.0]` along the free
/// axis — no snapping.
///
/// State ownership: the widget is *stateless w.r.t. the persisted value*.
/// The host owns `cropOffset` and feeds new values via [onChanged] (live
/// during drag) + [onChangeEnd] (commit the SQLite write).
class HeroCropViewport extends StatefulWidget {
  /// Effective playback aspect ratio of the underlying media (already
  /// includes any `rotationQuarters` swap). Drives free-axis selection
  /// and viewport sizing. `null` → behaves as if 1.0 (square — drag is
  /// disabled).
  final double? aspectRatio;

  /// Current normalised crop offset in `[0.0, 1.0]` along the free axis.
  /// Null defaults to 0.5 (centred) — matches the consumer fall-through
  /// rule in PR 1's contract.
  final double? cropOffset;

  /// Continuous callback during pan. Fires on every gesture tick with
  /// the live normalised offset. Host should optimistically update its
  /// in-memory exercise + bubble via `onExerciseUpdate` so the editor
  /// sheet header thumbnail rebuilds with the new crop in lock-step.
  final ValueChanged<double> onChanged;

  /// Drag-release commit. Host should debounce the SQLite write here
  /// (mirrors `_persistHero` in studio_mode_screen.dart).
  final ValueChanged<double> onChangeEnd;

  /// Double-tap reset. Host clears the value back to 0.5 (or null —
  /// caller's choice). Optional — when null, double-tap is a no-op.
  final VoidCallback? onReset;

  /// When false, the overlay paints itself but ignores all gestures.
  /// Used while video controllers are still initialising so the
  /// practitioner doesn't drag on a blank canvas.
  final bool enabled;

  const HeroCropViewport({
    super.key,
    required this.aspectRatio,
    required this.cropOffset,
    required this.onChanged,
    required this.onChangeEnd,
    this.onReset,
    this.enabled = true,
  });

  @override
  State<HeroCropViewport> createState() => _HeroCropViewportState();
}

class _HeroCropViewportState extends State<HeroCropViewport> {
  // Live drag offset so the overlay re-paints in lock-step with the
  // pan. Cleared on drag-end so the next paint reads from
  // `widget.cropOffset` (which the host has by then updated to the
  // committed value).
  double? _dragOffset;

  // Cached canvas size from the most recent layout pass. Pan deltas
  // are converted to normalised offsets against this so a fast drag
  // doesn't accumulate float error.
  Size _canvasSize = Size.zero;

  /// Effective aspect ratio with a guard against null / zero.
  double get _aspect {
    final raw = widget.aspectRatio;
    if (raw == null || raw <= 0) return 1.0;
    return raw;
  }

  /// True when the source is square — drag becomes a no-op since the
  /// 1:1 viewport already equals the canvas.
  bool get _isSquare => (_aspect - 1.0).abs() < 0.001;

  /// True when the source is landscape — free axis is X.
  bool get _isLandscape => _aspect > 1.0;

  /// Effective offset for paint — prefers the live drag value when
  /// present, falls back to the host's committed value, falls back to
  /// 0.5 (centred). Clamped defensively.
  double get _effectiveOffset {
    final v = _dragOffset ?? widget.cropOffset ?? 0.5;
    if (v < 0.0) return 0.0;
    if (v > 1.0) return 1.0;
    return v;
  }

  /// Compute the displayed media's bounding rect inside [canvas].
  /// The media is centred + letterboxed (matches the parent
  /// `AspectRatio` widget's layout — caller MUST ensure the overlay is
  /// inside the same AspectRatio so the rects coincide).
  ///
  /// We still recompute it here defensively so a layout misalignment
  /// surfaces visually rather than as a silent crop offset drift.
  Rect _mediaRect(Size canvas) {
    if (canvas.width <= 0 || canvas.height <= 0) return Rect.zero;
    final canvasAspect = canvas.width / canvas.height;
    if (canvasAspect > _aspect) {
      // Canvas is wider than the media → pillarbox (vertical bars).
      final mediaW = canvas.height * _aspect;
      final dx = (canvas.width - mediaW) / 2.0;
      return Rect.fromLTWH(dx, 0, mediaW, canvas.height);
    }
    // Canvas is taller than the media → letterbox (horizontal bars).
    final mediaH = canvas.width / _aspect;
    final dy = (canvas.height - mediaH) / 2.0;
    return Rect.fromLTWH(0, dy, canvas.width, mediaH);
  }

  /// Compute the 1:1 viewport rect at the current crop offset within
  /// [media]. Free axis follows orientation; constrained axis is
  /// centred.
  Rect _viewportRect(Rect media) {
    if (media.isEmpty) return Rect.zero;
    if (_isLandscape || _isSquare) {
      // H × H box, drag along X.
      final size = media.height;
      final travel = (media.width - size).clamp(0.0, double.infinity);
      final dx = media.left + travel * _effectiveOffset;
      return Rect.fromLTWH(dx, media.top, size, size);
    }
    // Portrait: W × W box, drag along Y.
    final size = media.width;
    final travel = (media.height - size).clamp(0.0, double.infinity);
    final dy = media.top + travel * _effectiveOffset;
    return Rect.fromLTWH(media.left, dy, size, size);
  }

  void _onDragStart(DragStartDetails _) {
    if (!widget.enabled || _isSquare) return;
    _dragOffset = widget.cropOffset ?? 0.5;
  }

  void _onDragUpdate(DragUpdateDetails details, {required bool horizontal}) {
    if (!widget.enabled || _isSquare) return;
    final media = _mediaRect(_canvasSize);
    if (media.isEmpty) return;
    final double travel;
    final double delta;
    if (horizontal) {
      travel = (media.width - media.height).clamp(0.0, double.infinity);
      delta = details.delta.dx;
    } else {
      travel = (media.height - media.width).clamp(0.0, double.infinity);
      delta = details.delta.dy;
    }
    if (travel <= 0) return;
    final next = ((_dragOffset ?? 0.5) + delta / travel).clamp(0.0, 1.0);
    if (next == _dragOffset) return;
    setState(() => _dragOffset = next);
    widget.onChanged(next);
  }

  void _onDragEnd(DragEndDetails _) {
    if (!widget.enabled || _isSquare) return;
    final last = _dragOffset;
    setState(() => _dragOffset = null);
    if (last != null) widget.onChangeEnd(last);
  }

  void _onDoubleTap() {
    if (!widget.enabled || _isSquare) return;
    final reset = widget.onReset;
    if (reset == null) return;
    // Match drag-release path so the host sees a value to commit.
    setState(() => _dragOffset = null);
    reset();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _canvasSize = Size(
          constraints.maxWidth.isFinite ? constraints.maxWidth : 0,
          constraints.maxHeight.isFinite ? constraints.maxHeight : 0,
        );
        final media = _mediaRect(_canvasSize);
        final viewport = _viewportRect(media);
        // Axis-LOCKED recognisers — landscape claims horizontal drag
        // ONLY (vertical drags fall through), portrait claims vertical
        // ONLY. This lets tab swipes on a portrait source still page
        // through the editor sheet's tabs, and stops a stray vertical
        // gesture from being claimed as a "free-axis drag" on a
        // landscape source. Square sources register no drag handlers
        // at all (drag is meaningless when viewport == canvas).
        //
        // `behavior: translucent` so a quick tap (no movement) bubbles
        // through to the underlying `onTap: _togglePlayPause` on the
        // PageView itemBuilder's GestureDetector.
        Widget child = CustomPaint(
          size: _canvasSize,
          painter: _HeroCropPainter(
            media: media,
            viewport: viewport,
            showFrame: !_isSquare,
          ),
        );
        if (_isSquare || !widget.enabled) {
          return IgnorePointer(child: child);
        }
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragStart: _isLandscape ? _onDragStart : null,
          onHorizontalDragUpdate: _isLandscape
              ? (d) => _onDragUpdate(d, horizontal: true)
              : null,
          onHorizontalDragEnd: _isLandscape ? _onDragEnd : null,
          onVerticalDragStart: !_isLandscape ? _onDragStart : null,
          onVerticalDragUpdate: !_isLandscape
              ? (d) => _onDragUpdate(d, horizontal: false)
              : null,
          onVerticalDragEnd: !_isLandscape ? _onDragEnd : null,
          onDoubleTap: _onDoubleTap,
          child: child,
        );
      },
    );
  }
}

/// Paints the 60% sage dim outside the 1:1 viewport box + the coral 2px
/// border around the box itself. Inside the box stays fully transparent
/// so the underlying media reads through.
class _HeroCropPainter extends CustomPainter {
  final Rect media;
  final Rect viewport;
  final bool showFrame;

  _HeroCropPainter({
    required this.media,
    required this.viewport,
    required this.showFrame,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (!showFrame || media.isEmpty || viewport.isEmpty) return;
    // Sage dim — paint the four "out" rectangles around the viewport
    // inside the media bounds. (Outside the media bounds we leave
    // alone; the canvas there is already letterbox-black from the
    // parent Stack.)
    final dimPaint = Paint()
      ..color = AppColors.rest.withValues(alpha: 0.35)
      ..blendMode = BlendMode.srcOver;
    // Left strip
    if (viewport.left > media.left) {
      canvas.drawRect(
        Rect.fromLTWH(
          media.left,
          media.top,
          viewport.left - media.left,
          media.height,
        ),
        dimPaint,
      );
    }
    // Right strip
    if (viewport.right < media.right) {
      canvas.drawRect(
        Rect.fromLTWH(
          viewport.right,
          media.top,
          media.right - viewport.right,
          media.height,
        ),
        dimPaint,
      );
    }
    // Top strip (only spans the viewport's horizontal extent so we
    // don't double-paint the corners).
    if (viewport.top > media.top) {
      canvas.drawRect(
        Rect.fromLTWH(
          viewport.left,
          media.top,
          viewport.width,
          viewport.top - media.top,
        ),
        dimPaint,
      );
    }
    // Bottom strip
    if (viewport.bottom < media.bottom) {
      canvas.drawRect(
        Rect.fromLTWH(
          viewport.left,
          viewport.bottom,
          viewport.width,
          media.bottom - viewport.bottom,
        ),
        dimPaint,
      );
    }

    // Coral 2px border around the viewport.
    final borderPaint = Paint()
      ..color = AppColors.primary
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawRect(viewport, borderPaint);
  }

  @override
  bool shouldRepaint(covariant _HeroCropPainter old) {
    return old.media != media ||
        old.viewport != viewport ||
        old.showFrame != showFrame;
  }
}
