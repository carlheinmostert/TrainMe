import 'package:flutter/material.dart';

import '../services/clipboard_service.dart';
import '../theme.dart';

/// Top-right Studio AppBar chip that surfaces the in-memory exercise
/// clipboard count (`docs/specs/2026-05-25-exercise-clipboard.md`, D5).
///
/// Layout: `[📋 N ×]` — clipboard icon, count badge, divider, clear-all
/// `×`. Visible only when [ClipboardService.count] >= 1; collapses to a
/// zero-size shrink when empty. Single-piece coral capsule; the `×`
/// owns a sub-region whose tap is intercepted before the chip's outer
/// tap handler fires (per the mockup's "clear all" pictograph next to
/// the count).
///
/// The chip mounts inside the Studio AppBar's `actions:` slot. It
/// rebuilds reactively on `ClipboardService.notifyListeners` — no
/// explicit stream subscription needed in callers.
class ClipboardChip extends StatefulWidget {
  /// Fires when the practitioner taps the body of the chip (NOT the
  /// `×`). Studio uses this to surface the paste bottom sheet.
  final VoidCallback onTap;

  /// Fires when the practitioner taps the trailing `×`. Studio uses
  /// this to call `ClipboardService.instance.clearAll()` so the
  /// destructive intent is owned outside the widget (kept testable +
  /// easy to wrap with telemetry / undo later without changing the
  /// chip).
  final VoidCallback onClearAll;

  /// Optional pulse-trigger key. Callers (the Studio swipe handler +
  /// editor-sheet Copy button) bump a counter and pass it as a child
  /// of [ValueKey] so the chip can run a brief scale pulse on landing
  /// per the mockup. Null when no pulse is requested.
  final Object? pulseTrigger;

  const ClipboardChip({
    super.key,
    required this.onTap,
    required this.onClearAll,
    this.pulseTrigger,
  });

  @override
  State<ClipboardChip> createState() => _ClipboardChipState();
}

class _ClipboardChipState extends State<ClipboardChip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final Animation<double> _pulseScale;
  int _lastSeenCount = 0;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );
    _pulseScale = TweenSequence<double>(<TweenSequenceItem<double>>[
      TweenSequenceItem(
        tween: Tween(begin: 1.0, end: 1.18)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 1,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 1.18, end: 1.0)
            .chain(CurveTween(curve: Curves.easeIn)),
        weight: 1,
      ),
    ]).animate(_pulseController);
    _lastSeenCount = ClipboardService.instance.count;
    ClipboardService.instance.addListener(_onServiceChange);
  }

  @override
  void didUpdateWidget(covariant ClipboardChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pulseTrigger != null &&
        widget.pulseTrigger != oldWidget.pulseTrigger) {
      _pulseController.forward(from: 0);
    }
  }

  @override
  void dispose() {
    ClipboardService.instance.removeListener(_onServiceChange);
    _pulseController.dispose();
    super.dispose();
  }

  void _onServiceChange() {
    if (!mounted) return;
    final next = ClipboardService.instance.count;
    // Pulse on every COUNT INCREASE (covers both Studio swipe-copy and
    // editor-sheet copy; the no-op duplicate case stays silent here
    // and the caller bumps `pulseTrigger` if it wants a pulse on a
    // dedupe). Decreases (clear-all, reactive pruning) don't pulse —
    // those land via the `AnimatedSwitcher`'s scale-out instead.
    if (next > _lastSeenCount) {
      _pulseController.forward(from: 0);
    }
    _lastSeenCount = next;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final count = ClipboardService.instance.count;
    // Hidden when empty (D5). AnimatedSwitcher gives a soft scale-fade
    // on the 0 → 1 and 1 → 0 transitions so the AppBar doesn't pop.
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      transitionBuilder: (child, animation) {
        return FadeTransition(
          opacity: animation,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.85, end: 1.0).animate(animation),
            child: child,
          ),
        );
      },
      child: count == 0
          ? const SizedBox.shrink(key: ValueKey('clipboard-chip-empty'))
          : Padding(
              key: const ValueKey('clipboard-chip-populated'),
              padding: const EdgeInsets.only(right: 8),
              child: ScaleTransition(
                scale: _pulseScale,
                child: _buildChip(count),
              ),
            ),
    );
  }

  Widget _buildChip(int count) {
    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.primary,
          borderRadius: BorderRadius.circular(14),
          boxShadow: const [
            BoxShadow(
              color: Color(0x59FF6B35), // 35% coral
              offset: Offset(0, 4),
              blurRadius: 10,
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              onTap: widget.onTap,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(14),
                bottomLeft: Radius.circular(14),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      // `content_paste` is Material's clipboard glyph —
                      // closest semantic to the mockup's 📋. Stays
                      // monochrome white inside the coral capsule.
                      Icons.content_paste,
                      size: 14,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '$count',
                      style: const TextStyle(
                        fontFamily: 'Montserrat',
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                        height: 1.0,
                        color: Colors.white,
                        fontFeatures: [FontFeature.tabularFigures()],
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Divider — 1px white-at-30% line per the mockup.
            Container(
              width: 1,
              height: 16,
              color: Colors.white.withValues(alpha: 0.30),
            ),
            InkWell(
              onTap: widget.onClearAll,
              borderRadius: const BorderRadius.only(
                topRight: Radius.circular(14),
                bottomRight: Radius.circular(14),
              ),
              child: const Padding(
                padding: EdgeInsets.fromLTRB(8, 6, 10, 6),
                child: Icon(
                  Icons.close,
                  size: 13,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
