import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/session.dart';
import '../theme.dart';

/// Wave 5 (CAPS) bottom-anchored Studio chrome.
///
/// The bottom is a single fully-rounded workflow pill with five
/// labelled cells:
///
///   [ Capture | Adjust | Preview | Publish | Share ]   →  CAPS
///
/// Each cell is a small dark circle holding a glyph + a 10pt
/// uppercase label below. Slim coral arrows sit between cells on the
/// glyph row (above the label baseline). When the plan is past its
/// 14-day grace, the Publish slot becomes a coral lock that opens the
/// unlock sheet.
///
/// Wave 44 stripped the surrounding back/gear/stats chrome (it lives
/// in the Studio AppBar + the Statistics tab on the plan-settings
/// sheet). Wave 5 reshapes the pill itself: rename Camera → Capture
/// + Refine → Adjust, fully-rounded geometry, per-cell labels, slim
/// coral arrows, three-dot network share glyph.
class StudioBottomBar extends StatelessWidget {
  final Session session;
  final bool isPublishing;
  final bool canPublish;
  final bool isPlanLocked;
  final String? publishError;

  /// Wave 40 (M1) — first toolbar slot is now Capture (was Camera /
  /// before that, Library). Tapping fires the same callback as the
  /// shell's swipe-left-to-Capture pull tab. Library import has moved
  /// inside the camera viewfinder (M2).
  final VoidCallback onCaptureTap;
  /// Adjust — opens the per-exercise editor sheet for the topmost card
  /// (most recent capture, skipping rest periods). Nullable so the host
  /// can disable it when there are no exercises captured yet.
  final VoidCallback? onAdjust;
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
    required this.onCaptureTap,
    this.onAdjust,
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
    final adjustActive = onAdjust != null;
    final previewActive = hasExercises;
    final hasPublishError = publishError != null && !isPublishing;
    final publishActive = canPublish || hasPublishError;
    final shareActive = session.isPublished;

    // CAPS workflow chain: Capture → Adjust → Preview → Publish → Share
    // inside a fully-rounded pill. Triangle dim rule preserved: an
    // arrow FEEDING INTO a dim cell is also dim, creating a visual
    // workflow gate.
    final workflowChildren = <Widget>[
      _CapsCell(
        icon: Icons.photo_camera_outlined,
        label: 'CAPTURE',
        active: true,
        onTap: onCaptureTap,
        tooltip: 'Capture (camera)',
      ),
      _Arrow(dim: !adjustActive),
      _CapsCell(
        icon: Icons.view_list_rounded,
        label: 'ADJUST',
        active: adjustActive,
        onTap: onAdjust,
        tooltip: 'Adjust top card',
      ),
      _Arrow(dim: !previewActive),
      _CapsCell(
        icon: Icons.slideshow_outlined,
        label: 'PREVIEW',
        active: previewActive,
        onTap: previewActive ? onPreview : null,
        tooltip: 'Preview plan',
      ),
      _Arrow(dim: !(isPlanLocked || publishActive)),
      // Wave 39.1 — when locked, the Publish slot is taken by a compact
      // Unlock cell (coral lock). Tapping opens the unlock bottom sheet.
      if (isPlanLocked)
        _CapsCell(
          icon: Icons.lock_outline_rounded,
          label: 'UNLOCK',
          active: true,
          onTap: onUnlockTap,
          tooltip: 'Unlock (1 credit)',
          accent: true,
        )
      else
        _PublishCapsCell(
          session: session,
          isPublishing: isPublishing,
          canPublish: canPublish,
          hasError: hasPublishError,
          onTap: publishActive
              ? (hasPublishError ? onShowPublishError : onPublish)
              : null,
          onLockedTap: onPublishLockedTap,
        ),
      _Arrow(dim: !shareActive),
      _CapsCell(
        // Material's `Icons.share` is the three-dot network glyph
        // (top-right + middle-left + bottom-right circles connected by
        // diagonal lines), matching the `ShareIcon` SVG on the help
        // page. Replaces the prior `Icons.ios_share` arrow-out-of-box.
        icon: Icons.share,
        label: 'SHARE',
        active: shareActive,
        onTap: shareActive ? onShare : null,
        tooltip: 'Share link',
      ),
    ];

    // Wave 5 — fully-rounded pill, subtle drop-shadow to lift it off
    // the surface. Slightly more vertical padding than the earlier
    // 12px-corner version so the labels (taller cells) don't crowd
    // the rounded edges.
    final workflowPill = Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(999),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: workflowChildren,
      ),
    );

    return Container(
      // Cells are taller than the prior 28pt icons because of the
      // label, so bump the row height a touch. Pill geometry handles
      // its own internal padding; this is just the outer breathing
      // room above the home indicator.
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
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

/// One CAPS cell: a small dark circle holding the glyph, with a 10pt
/// uppercase label below. The label dims with the glyph so the active
/// vs disabled state reads on either layer. Mirrors the
/// `ToolbarStrip` component on the public help page (web-portal).
class _CapsCell extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback? onTap;
  final String tooltip;
  /// Coral tint for the locked-state Unlock cell so it reads as a
  /// payment gate rather than a generic toolbar action.
  final bool accent;

  const _CapsCell({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
    required this.tooltip,
    this.accent = false,
  });

  @override
  Widget build(BuildContext context) {
    final glyphColor = accent
        ? AppColors.primary
        : active
            ? AppColors.textOnDark
            : AppColors.textOnDark.withValues(alpha: 0.45);
    final labelColor = accent
        ? AppColors.primary
        : active
            ? AppColors.textSecondaryOnDark
            : AppColors.textSecondaryOnDark.withValues(alpha: 0.55);

    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 56,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap == null
                ? null
                : () {
                    HapticFeedback.selectionClick();
                    onTap!();
                  },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.30),
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Icon(icon, color: glyphColor, size: 20),
                  ),
                  const SizedBox(height: 4),
                  // Hotfix 2026-05-05 — CAPS labels were pinching their cells
                  // at the prior 10pt size. Dropped 30% to 7pt and wrapped in
                  // a FittedBox so longer labels (e.g. PUBLISH) auto-shrink
                  // further at unusual font scaling without overflow.
                  //
                  // Polish 2026-05-05 — first letter of each label gets a
                  // visibly heavier weight (w900) as a passive nod to the
                  // CAPS mnemonic. Defensive empty-label fallback to keep
                  // substring(1) safe.
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: label.isEmpty
                        ? Text(
                            '',
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 7,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.4,
                              color: labelColor,
                              height: 1.0,
                            ),
                          )
                        : Text.rich(
                            TextSpan(
                              style: TextStyle(
                                fontFamily: 'Inter',
                                fontSize: 7,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.4, // 0.04em at 10pt
                                color: labelColor,
                                height: 1.0,
                              ),
                              children: [
                                TextSpan(
                                  text: label.substring(0, 1),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w900,
                                    fontSize: 9, // ~28% larger than 7pt
                                  ),
                                ),
                                TextSpan(text: label.substring(1)),
                              ],
                            ),
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.clip,
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

/// Publish CAPS cell — mutates per state. Cloud-upload glyph by
/// default; spinner while publishing; red error glyph when the last
/// publish failed. State + tooltip mirror the prior
/// `_PublishToolbarButton`; only the cell shape changed.
class _PublishCapsCell extends StatelessWidget {
  final Session session;
  final bool isPublishing;
  final bool canPublish;
  final bool hasError;
  final VoidCallback? onTap;
  final VoidCallback onLockedTap;

  const _PublishCapsCell({
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
    final cellActive = canPublish || publishedClean || hasError;

    final glyphColor = hasError
        ? AppColors.error
        : cellActive
            ? AppColors.textOnDark
            : AppColors.textOnDark.withValues(alpha: 0.45);
    final labelColor = hasError
        ? AppColors.error
        : cellActive
            ? AppColors.textSecondaryOnDark
            : AppColors.textSecondaryOnDark.withValues(alpha: 0.55);

    Widget glyph;
    if (isPublishing) {
      glyph = const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(
          strokeWidth: 2.2,
          color: AppColors.primary,
        ),
      );
    } else if (hasError) {
      glyph = Icon(Icons.error_outline, color: glyphColor, size: 20);
    } else {
      // Wave 41 — checkmark state retired. The publish cell always
      // shows cloud_upload_outlined; success is a SnackBar toast.
      glyph = Icon(Icons.cloud_upload_outlined, color: glyphColor, size: 20);
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
        width: 56,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap == null
                ? null
                : () {
                    HapticFeedback.selectionClick();
                    onTap!();
                  },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.30),
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: glyph,
                  ),
                  const SizedBox(height: 4),
                  // Hotfix 2026-05-05 — see comment in _CapsCell for the
                  // 30% drop + FittedBox rationale.
                  //
                  // Polish 2026-05-05 — leading 'P' of PUBLISH bolded
                  // (w900) to nod to the CAPS mnemonic across all 5 cells.
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text.rich(
                      TextSpan(
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 7,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.4, // 0.04em at 10pt
                          color: labelColor,
                          height: 1.0,
                        ),
                        children: const [
                          TextSpan(
                            text: 'P',
                            style: TextStyle(
                              fontWeight: FontWeight.w900,
                              fontSize: 9, // ~28% larger than 7pt
                            ),
                          ),
                          TextSpan(text: 'UBLISH'),
                        ],
                      ),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.clip,
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

/// Slim coral arrow between CAPS cells. Sits 6×14 inside an 8-wide
/// slot, vertically centered on the GLYPH ROW (not the full column),
/// so labels can sit below without the arrow crashing into them.
/// Mirrors the dim semantics of the prior `_Triangle`: an arrow
/// FEEDING INTO a dim cell is also dim.
class _Arrow extends StatelessWidget {
  final bool dim;

  const _Arrow({required this.dim});

  @override
  Widget build(BuildContext context) {
    // Vertical layout — push the arrow up to sit on the 36pt glyph
    // row's centerline. Cell's vertical layout is: 4pt top pad +
    // 36pt circle + 4pt + label + 4pt bottom pad. The 36pt circle's
    // centerline lives at 4 + 18 = 22pt from the cell's top.
    return SizedBox(
      width: 8,
      height: 36, // matches the glyph circle, ignores the label row
      child: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: CustomPaint(
          painter: _ArrowPainter(dim: dim),
        ),
      ),
    );
  }
}

class _ArrowPainter extends CustomPainter {
  final bool dim;

  _ArrowPainter({required this.dim});

  @override
  void paint(Canvas canvas, Size size) {
    // Slim 6×14 arrow head, vertically centered in the slot.
    final paint = Paint()
      ..color = AppColors.primary
          .withValues(alpha: dim ? 0.30 : 0.85)
      ..style = PaintingStyle.fill;
    final cx = size.width / 2;
    final cy = size.height / 2;
    const halfWidth = 3.0;
    const halfHeight = 7.0;
    final path = Path()
      ..moveTo(cx - halfWidth, cy - halfHeight)
      ..lineTo(cx - halfWidth, cy + halfHeight)
      ..lineTo(cx + halfWidth, cy)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _ArrowPainter old) => old.dim != dim;
}
