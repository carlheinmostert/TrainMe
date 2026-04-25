import 'package:flutter/material.dart';
import '../theme.dart';

/// Which edge of the screen the pull-tab sits on.
///
/// [left] lives on the left edge (used in Capture mode — tapping reveals
/// Studio) and shows an edit/studio icon.
/// [right] lives on the right edge (used in Studio mode — tapping reveals
/// Camera) and shows a camera icon.
enum ShellPullTabSide { left, right }

/// Edge pull-tab that hints at the adjacent mode in the Session Shell.
///
/// Renders as a half-pill jutting in from the screen edge:
///   - flat on the screen edge
///   - rounded on the inside edge
///   - coral brand fill with a subtle shadow
///   - white icon signalling the target mode
///
/// Tap and horizontal drag-initiation both invoke [onActivate]. The whole
/// pill is the touch target; the caller is expected to place this inside
/// a Stack so horizontal swipes on the surrounding PageView still take
/// precedence for full-surface drags.
///
/// On first arrival at each mode within a session, the tab animates in
/// from off-screen with a short ease-out translate — drawing the user's
/// eye to the affordance. Subsequent page changes skip the animation so
/// it doesn't become noisy.
class ShellPullTab extends StatefulWidget {
  final ShellPullTabSide side;
  final VoidCallback onActivate;

  /// Vertical alignment on the edge.  -1.0 is top, 0.0 is centre, 1.0 is
  /// bottom. Default 0.333 places the tab one third of the screen height
  /// up from the bottom — consistent across Studio and Capture so the
  /// user's thumb finds it in the same spot regardless of mode.
  final double verticalAlignment;

  const ShellPullTab({
    super.key,
    required this.side,
    required this.onActivate,
    this.verticalAlignment = 0.333,
  });

  @override
  State<ShellPullTab> createState() => _ShellPullTabState();
}

/// Tracks which sides have already played the entrance animation in the
/// current app session. Reset on app restart, not on page change.
final Set<ShellPullTabSide> _playedEntranceFor = {};

class _ShellPullTabState extends State<ShellPullTab>
    with SingleTickerProviderStateMixin {
  static const double _width = 22;
  static const double _height = 72;
  static const double _iconSize = 20;

  late final AnimationController _entrance;
  late final Animation<double> _slide;

  @override
  void initState() {
    super.initState();
    _entrance = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 360),
    );
    _slide = CurvedAnimation(parent: _entrance, curve: Curves.easeOutCubic);

    final alreadyPlayed = _playedEntranceFor.contains(widget.side);
    if (alreadyPlayed) {
      // Already shown this session — skip the animation and sit in place.
      _entrance.value = 1.0;
    } else {
      _playedEntranceFor.add(widget.side);
      // Tiny initial delay so the mode finishes laying in before the tab
      // announces itself.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _entrance.forward();
      });
    }
  }

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isLeft = widget.side == ShellPullTabSide.left;

    final borderRadius = isLeft
        ? const BorderRadius.only(
            topRight: Radius.circular(14),
            bottomRight: Radius.circular(14),
          )
        : const BorderRadius.only(
            topLeft: Radius.circular(14),
            bottomLeft: Radius.circular(14),
          );

    final shadowOffset = isLeft ? const Offset(2, 1) : const Offset(-2, 1);

    // Icon that communicates the *target* mode (what tapping reveals).
    //   left-edge  -> reveals Studio -> edit icon
    //   right-edge -> reveals Camera -> list-alt (session) icon — the
    //   camera glyph read as "capture mode" when sessions are wider
    //   than that.
    final icon = isLeft
        ? Icons.edit_outlined
        : Icons.list_alt_rounded;

    return Align(
      alignment: Alignment(isLeft ? -1.0 : 1.0, widget.verticalAlignment),
      child: AnimatedBuilder(
        animation: _slide,
        builder: (context, child) {
          // Translate from fully off-screen (width + a little shadow room)
          // on the owning edge to resting position.
          final t = 1.0 - _slide.value;
          final dx = (isLeft ? -1 : 1) * (_width + 6) * t;
          return Transform.translate(
            offset: Offset(dx, 0),
            child: Opacity(
              opacity: _slide.value.clamp(0.0, 1.0),
              child: child,
            ),
          );
        },
        child: GestureDetector(
          onTap: widget.onActivate,
          // Horizontal drag on the tab itself also counts as "reveal the
          // other mode" — matches the swipe affordance the tab advertises.
          onHorizontalDragStart: (_) => widget.onActivate(),
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: _width,
            height: _height,
            decoration: BoxDecoration(
              color: AppColors.primary,
              borderRadius: borderRadius,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.35),
                  blurRadius: 6,
                  offset: shadowOffset,
                ),
              ],
            ),
            alignment: Alignment.center,
            child: Icon(
              icon,
              size: _iconSize,
              color: Colors.white.withValues(alpha: 0.95),
            ),
          ),
        ),
      ),
    );
  }
}
