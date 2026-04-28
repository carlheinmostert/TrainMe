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
  final VoidCallback onImport;
  final VoidCallback onPreview;
  final VoidCallback onPublish;
  final VoidCallback onShare;
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
    required this.onImport,
    required this.onPreview,
    required this.onPublish,
    required this.onShare,
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
    final shareActive = session.isPublished;

    // Wave 38.1 hotfix — restore the original 4-action workflow chain
    // (Import ▸ Preview ▸ Publish ▸ Share) with state-aware coral
    // triangles between each action. Center-aligned. Back stays left.
    // When the plan is locked, the Publish slot is replaced by the
    // Unlock pill which floats right-aligned (Carl's mockup spec —
    // Unlock is the ONLY thing on the right; everything else centers).
    //
    // Triangle dim rule: a triangle FEEDING INTO a dim icon is also
    // dim, creating a "chain" read of the workflow gate. Mirrors the
    // pre-W38 `StudioToolbar` semantics.
    final centerGroup = <Widget>[
      _ToolbarIconButton(
        icon: Icons.photo_library_outlined,
        active: true,
        onTap: onImport,
        tooltip: 'Import from library',
      ),
      _Triangle(dim: !previewActive),
      _ToolbarIconButton(
        icon: Icons.slideshow_outlined,
        active: previewActive,
        onTap: previewActive ? onPreview : null,
        tooltip: 'Preview plan',
      ),
      _Triangle(dim: !(isPlanLocked || publishActive)),
      // Wave 39.1 hotfix — when locked, the Publish slot is taken by a
      // compact Unlock icon (lock_outline_rounded, coral). Tapping opens
      // the unlock bottom sheet. This replaces the prior right-anchored
      // "Unlock (1 credit)" pill that was overflowing the toolbar.
      if (isPlanLocked)
        _ToolbarIconButton(
          icon: Icons.lock_outline_rounded,
          active: true,
          onTap: onUnlockTap,
          tooltip: 'Unlock (1 credit)',
          accent: true,
        )
      else
        _PublishToolbarButton(
          session: session,
          isPublishing: isPublishing,
          canPublish: canPublish,
          hasError: hasPublishError,
          onTap: publishActive
              ? (hasPublishError ? onShowPublishError : onPublish)
              : null,
          onLockedTap: onPublishLockedTap,
        ),
      _Triangle(dim: !shareActive),
      _ToolbarIconButton(
        icon: Icons.ios_share,
        active: shareActive,
        onTap: shareActive ? onShare : null,
        tooltip: 'Share link',
      ),
    ];

    // Wave 38.1.1 polish — center the workflow group on the SCREEN
    // midpoint (not biased by Back's 44pt on the left). Stack lets the
    // central Row truly center while Back anchors left and the Unlock
    // pill anchors right (when present), independent of the centre's
    // intrinsic width.
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Stack(
        children: [
          // Truly-centred workflow group.
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: centerGroup,
            ),
          ),
          // Back button — left anchor.
          Align(
            alignment: Alignment.centerLeft,
            child: _ToolbarIconButton(
              icon: Icons.arrow_back_rounded,
              active: true,
              onTap: onBack,
              tooltip: 'Back to sessions',
            ),
          ),
          // Wave 39.1 — Unlock pill retired. Unlock now lives IN the
          // workflow chain (replacing Publish when locked) so the
          // toolbar fits naturally and stays centred.
        ],
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
  /// Wave 39.1 — coral tint for the locked-state Unlock icon (lock_outline)
  /// so it reads as a payment gate rather than a generic toolbar action.
  final bool accent;

  const _ToolbarIconButton({
    required this.icon,
    required this.active,
    required this.onTap,
    required this.tooltip,
    this.accent = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = accent
        ? AppColors.primary
        : active
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
    // Wave 38.1.1 polish — round filled background retired per Carl's
    // QA note ("unnecessary"). Publish now reads as a flat glyph that
    // matches the rest of the toolbar; state is communicated through
    // the glyph + tint alone.
    final publishedDirty =
        session.isPublished && session.hasUnpublishedContentChanges;
    final publishedClean = session.isPublished && !publishedDirty;

    Widget glyph;
    if (isPublishing) {
      glyph = const SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: AppColors.primary,
        ),
      );
    } else if (hasError) {
      glyph = const Icon(Icons.error_outline, color: AppColors.error, size: 24);
    } else if (publishedClean) {
      glyph = const Icon(Icons.check_rounded, color: AppColors.circuit, size: 24);
    } else {
      final color = canPublish
          ? AppColors.primary
          : AppColors.primary.withValues(alpha: 0.45);
      glyph = Icon(Icons.cloud_upload_outlined, color: color, size: 24);
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
        child: InkResponse(
          radius: 22,
          onTap: onTap == null
              ? null
              : () {
                  HapticFeedback.selectionClick();
                  onTap!();
                },
          child: Center(child: glyph),
        ),
      ),
    );
  }
}

/// Small right-pointing coral triangle that sits between toolbar
/// icons. The chain reads "Import ▸ Preview ▸ Publish ▸ Share". A
/// triangle FEEDING INTO a dim icon also dims, so the visual workflow
/// gate is obvious — e.g. Publish→Share triangle dim while the session
/// is unpublished. Ported from the retired pre-W38 `StudioToolbar` so
/// the bottom bar carries the same workflow-cue grammar.
class _Triangle extends StatelessWidget {
  final bool dim;

  const _Triangle({required this.dim});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 14,
      height: 44,
      child: CustomPaint(
        painter: _TrianglePainter(dim: dim),
      ),
    );
  }
}

class _TrianglePainter extends CustomPainter {
  final bool dim;

  _TrianglePainter({required this.dim});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppColors.primary
          .withValues(alpha: dim ? 0.3 : 0.9)
      ..style = PaintingStyle.fill;
    final cx = size.width / 2;
    final cy = size.height / 2;
    const halfWidth = 2.5;
    const halfHeight = 3.0;
    final path = Path()
      ..moveTo(cx - halfWidth, cy - halfHeight)
      ..lineTo(cx - halfWidth, cy + halfHeight)
      ..lineTo(cx + halfWidth, cy)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _TrianglePainter old) => old.dim != dim;
}

// Wave 39.1 — `_UnlockPill` retired. The right-anchored stadium pill
// with "Unlock (1 credit)" text overflowed the toolbar; the unlock
// affordance is now an in-chain coral lock_outline icon that takes the
// Publish slot when locked. Tooltip carries the "(1 credit)" hint.

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
