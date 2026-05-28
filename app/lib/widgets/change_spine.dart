import 'package:flutter/material.dart';

import '../theme.dart';

/// Coral "unpublished changes" spine — a 4px coral bar down the full-height
/// left edge of a card (unpublished-changes coral spine, 2026-05-28).
///
/// ONE shared widget used at BOTH levels so the treatment cannot drift:
///   * Studio exercise card — when that exercise's own content changed
///     since the last publish.
///   * Session-list card — when ANY of its exercises is dirty.
///
/// Locked visual spec: 4px wide, full height of the parent slot, coral
/// `#FF6B35` ([AppColors.primary]), with only the RIGHT corners rounded
/// (2px). Render it inside a `Positioned(left: 0, top: 0, bottom: 0)` (or
/// as a sized child of a Row) on top of any card imagery / veil so it reads
/// crisp coral.
///
/// Stateless and self-contained — callers gate visibility themselves; this
/// widget only knows how to draw the bar.
class ChangeSpine extends StatelessWidget {
  const ChangeSpine({super.key});

  /// Bar width in logical pixels.
  static const double width = 4;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      decoration: const BoxDecoration(
        color: AppColors.primary, // #FF6B35 — the canonical coral accent
        borderRadius: BorderRadius.only(
          topRight: Radius.circular(2),
          bottomRight: Radius.circular(2),
        ),
      ),
    );
  }
}
