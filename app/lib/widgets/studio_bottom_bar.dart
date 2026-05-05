import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/session.dart';
import '../theme.dart';

/// Wave 44 bottom-anchored Studio chrome.
///
/// Stripped down to the workflow pill alone. Wave 38's stacked-row
/// chrome (stats strip + subtitle + back + gear) moved upward into
/// the Studio AppBar and into the new `Statistics` tab on the
/// plan-settings sheet. The bottom bar is now JUST the pill:
///
///   [ Camera | Refine | Preview | Publish | Share ]
///
/// Five icons, coral triangles between them, with the Publish slot
/// replaced by the Unlock pill when the plan is past its 14-day
/// grace. Wave 5 (CAPS rename) will reshape the pill itself; this
/// pass leaves icon names + glyphs untouched.
class StudioBottomBar extends StatelessWidget {
  final Session session;
  final bool isPublishing;
  final bool canPublish;
  final bool isPlanLocked;
  final String? publishError;

  /// Wave 40 (M1) — first toolbar slot is now Camera (replaces the
  /// retired Library slot). Tapping fires the same callback as the
  /// shell's swipe-left-to-Capture pull tab. Library import has moved
  /// inside the camera viewfinder (M2).
  final VoidCallback onCameraTap;
  /// Refine — opens the per-exercise editor sheet for the topmost card
  /// (most recent capture, skipping rest periods). Nullable so the host
  /// can disable it when there are no exercises captured yet.
  final VoidCallback? onRefine;
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
    required this.onCameraTap,
    this.onRefine,
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
        child: _buildToolbar(hasExercises),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Toolbar
  // ---------------------------------------------------------------------------

  Widget _buildToolbar(bool hasExercises) {
    final previewActive = hasExercises;
    final hasPublishError = publishError != null && !isPublishing;
    final publishActive = canPublish || hasPublishError;
    final shareActive = session.isPublished;

    // Workflow chain: Camera → Refine → Preview → Publish → Share inside
    // a raised pill. Wave 44 stripped the surrounding back/gear chrome —
    // back lives in the AppBar, gear lives on the AppBar's right edge.
    final workflowChildren = <Widget>[
      // Wave 40 (M1) — Camera replaces Library as the first slot. Tap
      // = same as swipe-left to Capture mode (no modal).
      _ToolbarIconButton(
        icon: Icons.photo_camera_outlined,
        active: true,
        onTap: onCameraTap,
        tooltip: 'Open camera',
      ),
      _Triangle(dim: onRefine == null),
      // Refine — opens the editor sheet for the topmost card (most
      // recent capture, skipping rest).
      _ToolbarIconButton(
        icon: Icons.view_list_rounded,
        active: onRefine != null,
        onTap: onRefine,
        tooltip: 'Refine top card',
      ),
      _Triangle(dim: !previewActive),
      _ToolbarIconButton(
        icon: Icons.slideshow_outlined,
        active: previewActive,
        onTap: previewActive ? onPreview : null,
        tooltip: 'Preview plan',
      ),
      _Triangle(dim: !(isPlanLocked || publishActive)),
      // Wave 39.1 — when locked, the Publish slot is taken by a compact
      // Unlock icon (lock_outline_rounded, coral). Tapping opens the
      // unlock bottom sheet.
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

    // Wave 44 — the workflow pill is the entire toolbar. Centred so
    // the row reads as a coherent control rather than a left-anchored
    // strip with empty right space.
    final workflowPill = Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: workflowChildren,
      ),
    );

    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [workflowPill],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Stats line resolution — public so the plan-settings sheet's Statistics
// tab can reuse it. Same logic that previously lived inside the bottom
// bar's stats strip; the bar no longer renders these lines but the
// truth needs a single home.
// ---------------------------------------------------------------------------

/// Tone of the lock-state line. Drives the leading dot colour and a
/// subtle text-weight bump on `locked`.
enum StudioLockTone { fresh, warning, urgent, locked, unlocked }

/// One line of the lock-state row: which tone, what label, what dot
/// colour to paint. The dot colour is pre-resolved so callers can
/// drive any tone with a single field rather than re-mapping in two
/// surfaces.
class StudioLockLine {
  final StudioLockTone tone;
  final String label;
  final Color dotColor;
  const StudioLockLine({
    required this.tone,
    required this.label,
    required this.dotColor,
  });
}

/// Combined first/last opened + lock-state lines for a session. Either
/// or both may be null (drafts return both null; published-but-not-
/// opened returns "Not yet opened" + null lock).
class StudioStatsLines {
  final String? opened;
  final StudioLockLine? lock;
  const StudioStatsLines({required this.opened, required this.lock});
}

/// Resolve the analytics + lock state for a session. Wave 38 had this
/// logic inside `StudioBottomBar._resolveStatsLines`; Wave 44 lifts it
/// out as a free function so the new `Statistics` tab in the plan-
/// settings sheet can call into the same single source of truth.
StudioStatsLines resolveStudioStatsLines(Session session) {
  if (!session.isPublished) {
    return const StudioStatsLines(opened: null, lock: null);
  }
  final firstOpened = session.firstOpenedAt;
  if (firstOpened == null) {
    return const StudioStatsLines(opened: 'Not yet opened', lock: null);
  }
  final lastOpened = session.lastOpenedAt ?? firstOpened;
  final sameDay = firstOpened.year == lastOpened.year &&
      firstOpened.month == lastOpened.month &&
      firstOpened.day == lastOpened.day;
  final opened = sameDay
      ? 'First & last opened ${_fmtDay(firstOpened)}'
      : 'First opened ${_fmtDay(firstOpened)}'
          ' · Last opened ${_fmtDay(lastOpened)}';

  if (session.unlockCreditPrepaidAt != null) {
    return StudioStatsLines(
      opened: opened,
      lock: const StudioLockLine(
        tone: StudioLockTone.unlocked,
        label: 'Unlocked · republish free',
        dotColor: AppColors.primaryLight,
      ),
    );
  }

  final elapsed = DateTime.now().difference(firstOpened);
  final remaining = const Duration(days: 14) - elapsed;
  if (remaining <= Duration.zero) {
    return StudioStatsLines(
      opened: opened,
      lock: const StudioLockLine(
        tone: StudioLockTone.locked,
        label: 'Republish costs 1 credit',
        dotColor: AppColors.error,
      ),
    );
  }
  final tone = remaining <= const Duration(hours: 24)
      ? StudioLockTone.urgent
      : remaining <= const Duration(days: 3)
          ? StudioLockTone.warning
          : StudioLockTone.fresh;
  return StudioStatsLines(
    opened: opened,
    lock: StudioLockLine(
      tone: tone,
      label: 'Free Edits · ${_fmtRemaining(remaining)} left',
      dotColor: tone == StudioLockTone.urgent
          ? AppColors.primary
          : tone == StudioLockTone.warning
              ? AppColors.warning
              : AppColors.rest,
    ),
  );
}

String _fmtDay(DateTime dt) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${dt.day} ${months[dt.month - 1]}';
}

String _fmtRemaining(Duration d) {
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
      width: 48,
      height: 48,
      child: IconButton(
        onPressed: onTap == null
            ? null
            : () {
                HapticFeedback.selectionClick();
                onTap!();
              },
        padding: EdgeInsets.zero,
        icon: Icon(icon, color: color, size: 28),
        iconSize: 28,
        splashRadius: 24,
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

    Widget glyph;
    if (isPublishing) {
      glyph = const SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(
          strokeWidth: 2.4,
          color: AppColors.primary,
        ),
      );
    } else if (hasError) {
      glyph = const Icon(Icons.error_outline, color: AppColors.error, size: 28);
    } else {
      // Wave 41 — checkmark state retired. The publish button always
      // shows cloud_upload_outlined; success is communicated via a
      // dismissible SnackBar toast instead.
      final color = canPublish || publishedClean
          ? AppColors.textOnDark
          : AppColors.textOnDark.withValues(alpha: 0.45);
      glyph = Icon(Icons.cloud_upload_outlined, color: color, size: 28);
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
        width: 48,
        height: 48,
        child: InkResponse(
          radius: 24,
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
/// icons. The chain reads "Camera ▸ Refine ▸ Preview ▸ Publish ▸ Share".
/// A triangle FEEDING INTO a dim icon also dims, so the visual workflow
/// gate is obvious.
class _Triangle extends StatelessWidget {
  final bool dim;

  const _Triangle({required this.dim});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 16,
      height: 48,
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
    // Wave 40 (M6) — bumped from 8x12 to 10x14 to match the larger
    // toolbar icons (24 -> 28). Half-extents scale accordingly.
    final paint = Paint()
      ..color = AppColors.primary
          .withValues(alpha: dim ? 0.3 : 0.9)
      ..style = PaintingStyle.fill;
    final cx = size.width / 2;
    final cy = size.height / 2;
    const halfWidth = 5.0;
    const halfHeight = 7.0;
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
