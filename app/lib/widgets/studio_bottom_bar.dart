import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/session.dart';
import '../theme.dart';

/// Wave 38 bottom-anchored Studio chrome.
///
/// Replaces the top AppBar entirely. Three vertically-stacked rows
/// inside a single `SafeArea(top: false, bottom: true)`. Reads
/// bottom-up — toolbar is the most reachable layer; the analytics +
/// subtitle context above it disambiguates "what am I editing?"
/// without forcing the practitioner to back out of Studio.
///
///   [Stats strip]   ~40pt — analytics: First/Last opened + lock state
///   [Subtitle row]  28pt — `{date} · {client name}`, single line, ellipsised
///   [Toolbar]       44pt — back / preview / publish (+ unlock pill on lock)
///
/// Per the canonical mockup at
/// `docs/design/mockups/studio-bottom-toolbar.html`. Five Carl-locked
/// design questions are baked in:
///
///   1. Unlock pill REPLACES Publish when locked (right-aligned).
///   2. Padlock chip retired; lock state communicated via the dot in the
///      stats strip + the unlock pill in the toolbar.
///   3. Default-fixed (no auto-hide on scroll).
///   4. Subtitle row ellipsises on overflow.
///   5. Drafts skip the stats strip entirely (~40pt smaller bottom stack).
class StudioBottomBar extends StatelessWidget {
  final Session session;
  final bool isPublishing;
  final bool canPublish;
  final bool isPlanLocked;
  final String? publishError;
  final String clientName;

  final VoidCallback onBack;
  final VoidCallback onPreview;
  final VoidCallback onPublish;
  final VoidCallback onPublishLockedTap;
  final VoidCallback onUnlockTap;
  final VoidCallback onShowPublishError;

  const StudioBottomBar({
    super.key,
    required this.session,
    required this.isPublishing,
    required this.canPublish,
    required this.isPlanLocked,
    required this.publishError,
    required this.clientName,
    required this.onBack,
    required this.onPreview,
    required this.onPublish,
    required this.onPublishLockedTap,
    required this.onUnlockTap,
    required this.onShowPublishError,
  });

  @override
  Widget build(BuildContext context) {
    final hasExercises = session.exercises.isNotEmpty;
    final stats = _resolveStatsLines();
    final showStats = stats.opened != null || stats.lock != null;

    return SafeArea(
      top: false,
      bottom: true,
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.surfaceBg,
          border: Border(
            top: BorderSide(color: AppColors.surfaceBorder, width: 1),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showStats) _buildStatsStrip(stats),
            _buildSubtitleRow(),
            _buildToolbar(hasExercises),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Stats strip
  // ---------------------------------------------------------------------------

  Widget _buildStatsStrip(_StatsLines stats) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 6, 18, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (stats.opened != null)
            Text(
              stats.opened!,
              style: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 11.5,
                color: AppColors.textSecondaryOnDark,
                height: 1.45,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          if (stats.lock != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: stats.lock!.dotColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      stats.lock!.label,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 11.5,
                        color: stats.lock!.tone == _LockTone.locked
                            ? AppColors.textOnDark
                            : AppColors.textSecondaryOnDark,
                        fontWeight: stats.lock!.tone == _LockTone.locked
                            ? FontWeight.w600
                            : FontWeight.w400,
                        height: 1.45,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Subtitle row
  // ---------------------------------------------------------------------------

  Widget _buildSubtitleRow() {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 8),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: AppColors.surfaceBorder, width: 1),
        ),
      ),
      child: Text(
        _formatSubtitle(),
        style: const TextStyle(
          fontFamily: 'Inter',
          fontSize: 12,
          color: AppColors.textSecondaryOnDark,
          height: 1.3,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  String _formatSubtitle() {
    final created = session.createdAt;
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final date = '${created.day} ${months[created.month - 1]} ${created.year}';
    final name = clientName.trim().isEmpty
        ? session.clientName.trim()
        : clientName;
    if (name.isEmpty) return date;
    return '$date \u00b7 $name';
  }

  // ---------------------------------------------------------------------------
  // Toolbar
  // ---------------------------------------------------------------------------

  Widget _buildToolbar(bool hasExercises) {
    final previewActive = hasExercises;
    final hasPublishError = publishError != null && !isPublishing;
    final publishActive = canPublish || hasPublishError;

    final children = <Widget>[
      _ToolbarIconButton(
        icon: Icons.arrow_back_rounded,
        active: true,
        onTap: onBack,
        tooltip: 'Back to sessions',
      ),
      if (isPlanLocked) ...[
        _ToolbarIconButton(
          icon: Icons.slideshow_outlined,
          active: previewActive,
          onTap: previewActive ? onPreview : null,
          tooltip: 'Preview plan',
        ),
        const Spacer(),
        _UnlockPill(onTap: onUnlockTap),
      ] else ...[
        const Spacer(),
        _ToolbarIconButton(
          icon: Icons.slideshow_outlined,
          active: previewActive,
          onTap: previewActive ? onPreview : null,
          tooltip: 'Preview plan',
        ),
        const SizedBox(width: 8),
        _PublishToolbarButton(
          session: session,
          isPublishing: isPublishing,
          canPublish: canPublish,
          hasError: hasPublishError,
          onTap: publishActive
              ? (hasPublishError ? onShowPublishError : onPublish)
              : null,
          // Wave 32 mid-grace lock state still shows publish; only the
          // post-grace lock surfaces the unlock pill. (See
          // `_isPlanLocked` getter on the screen.)
          onLockedTap: onPublishLockedTap,
        ),
      ],
    ];

    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: children,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Stats line resolution
  // ---------------------------------------------------------------------------

  /// Mirror of `SessionCard._resolveLockState` so the bottom strip and
  /// the SessionCard agree on lock copy + tone. Drafts return `null` for
  /// both lines (the strip vanishes); published-never-opened returns
  /// "Not yet opened" + a null lock row.
  _StatsLines _resolveStatsLines() {
    if (!session.isPublished) {
      return const _StatsLines(opened: null, lock: null);
    }
    final firstOpened = session.firstOpenedAt;
    if (firstOpened == null) {
      return const _StatsLines(
        opened: 'Not yet opened',
        lock: null,
      );
    }
    final lastOpened = session.lastOpenedAt ?? firstOpened;
    final sameDay = firstOpened.year == lastOpened.year &&
        firstOpened.month == lastOpened.month &&
        firstOpened.day == lastOpened.day;
    final opened = sameDay
        ? 'First & last opened ${_fmtDay(firstOpened)}'
        : 'First opened ${_fmtDay(firstOpened)}'
            ' \u00b7 Last opened ${_fmtDay(lastOpened)}';

    if (session.unlockCreditPrepaidAt != null) {
      return _StatsLines(
        opened: opened,
        lock: const _LockLine(
          tone: _LockTone.unlocked,
          label: 'Unlocked \u00b7 republish free',
          dotColor: AppColors.primaryLight,
        ),
      );
    }

    final elapsed = DateTime.now().difference(firstOpened);
    final remaining = const Duration(days: 14) - elapsed;
    if (remaining <= Duration.zero) {
      return _StatsLines(
        opened: opened,
        lock: const _LockLine(
          tone: _LockTone.locked,
          label: 'Republish costs 1 credit',
          dotColor: AppColors.error,
        ),
      );
    }
    final tone = remaining <= const Duration(hours: 24)
        ? _LockTone.urgent
        : remaining <= const Duration(days: 3)
            ? _LockTone.warning
            : _LockTone.fresh;
    return _StatsLines(
      opened: opened,
      lock: _LockLine(
        tone: tone,
        label: 'Free Edits \u00b7 ${_fmtRemaining(remaining)} left',
        dotColor: tone == _LockTone.urgent
            ? AppColors.primary
            : tone == _LockTone.warning
                ? AppColors.warning
                : AppColors.rest,
      ),
    );
  }

  static String _fmtDay(DateTime dt) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${dt.day} ${months[dt.month - 1]}';
  }

  static String _fmtRemaining(Duration d) {
    if (d.inDays >= 1) {
      final days = d.inDays;
      final hours = d.inHours - days * 24;
      return hours == 0 ? '${days}d' : '${days}d ${hours}h';
    }
    if (d.inHours >= 1) {
      final hours = d.inHours;
      final minutes = d.inMinutes - hours * 60;
      return minutes == 0 ? '${hours}h' : '${hours}h ${minutes}m';
    }
    final minutes = d.inMinutes;
    return minutes <= 0 ? '1m' : '${minutes}m';
  }
}

// ---------------------------------------------------------------------------
// Sub-widgets
// ---------------------------------------------------------------------------

class _ToolbarIconButton extends StatelessWidget {
  final IconData icon;
  final bool active;
  final VoidCallback? onTap;
  final String tooltip;

  const _ToolbarIconButton({
    required this.icon,
    required this.active,
    required this.onTap,
    required this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final color = active
        ? AppColors.textOnDark
        : AppColors.textOnDark.withValues(alpha: 0.45);
    return SizedBox(
      width: 44,
      height: 44,
      child: IconButton(
        onPressed: onTap == null
            ? null
            : () {
                HapticFeedback.selectionClick();
                onTap!();
              },
        padding: EdgeInsets.zero,
        icon: Icon(icon, color: color, size: 24),
        iconSize: 24,
        splashRadius: 22,
        tooltip: tooltip,
      ),
    );
  }
}

/// Publish action — coral filled circle on the toolbar's right edge.
/// Mutates per state to mirror `StudioToolbar`'s `_PublishIconButton`:
/// upload glyph (default), check (clean published), spinner (publishing),
/// error (red). Locked-but-mid-grace plans still show publish (Wave 32
/// rule: only post-grace publishes route through the unlock sheet).
class _PublishToolbarButton extends StatelessWidget {
  final Session session;
  final bool isPublishing;
  final bool canPublish;
  final bool hasError;
  final VoidCallback? onTap;
  final VoidCallback onLockedTap;

  const _PublishToolbarButton({
    required this.session,
    required this.isPublishing,
    required this.canPublish,
    required this.hasError,
    required this.onTap,
    required this.onLockedTap,
  });

  @override
  Widget build(BuildContext context) {
    final publishedDirty =
        session.isPublished && session.hasUnpublishedContentChanges;
    final publishedClean = session.isPublished && !publishedDirty;

    Color bg;
    Color iconColor;
    Widget child;

    if (isPublishing) {
      bg = AppColors.primary;
      iconColor = Colors.white;
      child = const SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
        ),
      );
    } else if (hasError) {
      bg = AppColors.error;
      iconColor = Colors.white;
      child = Icon(Icons.error_outline, color: iconColor, size: 24);
    } else if (publishedClean) {
      bg = AppColors.circuit;
      iconColor = Colors.white;
      child = Icon(Icons.check_rounded, color: iconColor, size: 24);
    } else {
      // never published OR dirty re-publish
      bg = canPublish
          ? AppColors.primary
          : AppColors.primary.withValues(alpha: 0.45);
      iconColor = Colors.white;
      child = Icon(Icons.cloud_upload_outlined, color: iconColor, size: 24);
    }

    String tooltip;
    if (hasError) {
      tooltip = 'Last publish failed — tap for details';
    } else if (publishedClean) {
      tooltip = 'Published v${session.version}';
    } else if (publishedDirty) {
      tooltip = 'Re-publish';
    } else {
      tooltip = 'Publish';
    }

    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 44,
        height: 44,
        child: Material(
          color: bg,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap == null
                ? null
                : () {
                    HapticFeedback.selectionClick();
                    onTap!();
                  },
            child: Center(child: child),
          ),
        ),
      ),
    );
  }
}

/// Coral-bordered, coral-tinted "🔒 Unlock (1 credit)" stadium pill.
/// 44pt height, 999px radius. Replaces Publish when the plan is post-
/// 14-day-grace locked.
class _UnlockPill extends StatelessWidget {
  final VoidCallback onTap;

  const _UnlockPill({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.primary.withValues(alpha: 0.12),
      shape: StadiumBorder(
        side: BorderSide(color: AppColors.primary, width: 1.5),
      ),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 0),
          child: SizedBox(
            height: 44,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.lock_outline_rounded,
                  size: 18,
                  color: AppColors.primary,
                ),
                SizedBox(width: 8),
                Text(
                  'Unlock (1 credit)',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.primary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Internal value-types for the stats resolver
// ---------------------------------------------------------------------------

enum _LockTone { fresh, warning, urgent, locked, unlocked }

class _LockLine {
  final _LockTone tone;
  final String label;
  final Color dotColor;
  const _LockLine({
    required this.tone,
    required this.label,
    required this.dotColor,
  });
}

class _StatsLines {
  final String? opened;
  final _LockLine? lock;
  const _StatsLines({required this.opened, required this.lock});
}
