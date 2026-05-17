import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/session.dart';
import '../theme.dart';

/// PR-C visual tone for the optional "Publishing N of M files" chip in
/// the workflow toolbar. Drives both the chip background colour and
/// the leading glyph.
enum PublishingChipTone {
  /// Mid-publish — coral background, small spinner glyph.
  inFlight,

  /// Terminal success — sage background, checkmark.
  success,

  /// Terminal failure — danger-coral, warning glyph + "Tap to retry".
  failure,
}

/// Wave 5 (CAPS) bottom-anchored Studio chrome.
///
/// The bottom is a single fully-rounded workflow pill with five
/// labelled cells:
///
///   [ Capture  Adjust  Preview  Publish  Share ]   →  CAPS
///
/// Each cell shows a glyph directly on the pill surface with a
/// short uppercase label below; cell padding handles inter-cell
/// spacing. When the plan is past its 14-day grace, the Publish
/// slot becomes a coral lock that opens the unlock sheet.
///
/// Wave 44 stripped the surrounding back/gear/stats chrome (it lives
/// in the Studio AppBar + the Statistics tab on the plan-settings
/// sheet). Wave 5 reshaped the pill itself: rename Camera → Capture
/// + Refine → Adjust, fully-rounded geometry, per-cell labels,
/// three-dot network share glyph. The 2026-05-16 cleanup wave then
/// dropped the inter-cell coral arrows (the cells are launchers,
/// not stages — directionality was layering "flow" on top of the
/// existing readiness opacity) and stripped the dark round chip
/// behind each glyph (icon sits directly on the pill surface).
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

  /// PR-C — when the practitioner dismisses the new
  /// [PublishProgressSheet] mid-publish (swipe down), a coral chip
  /// floats above the workflow pill carrying "Publishing N of M
  /// files" / "Plan published" / "Tap to retry" depending on state.
  /// Null hides the chip entirely. Tapping fires
  /// [onPublishingChipTap], which the host wires to re-open the
  /// sheet (mid-flight) or re-fire the publish (on failure).
  final String? publishingChipLabel;

  /// Visual tone of the chip — coral for in-flight (with progress
  /// fraction), sage for success, danger-coral for failure.
  final PublishingChipTone publishingChipTone;

  /// Optional 0..1 progress fraction shown as a thin track inside the
  /// chip during the uploading-treatments phase. Null draws no track.
  final double? publishingChipProgress;

  /// Tapped to re-open the sheet (mid-flight) or trigger the retry
  /// flow (failure state). No-op when null.
  final VoidCallback? onPublishingChipTap;

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
    this.publishingChipLabel,
    this.publishingChipTone = PublishingChipTone.inFlight,
    this.publishingChipProgress,
    this.onPublishingChipTap,
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

    // CAPS workflow chain: Capture · Adjust · Preview · Publish · Share
    // inside a fully-rounded pill. Cells are launchers (each opens a
    // different screen / sheet) rather than stages — there's never a
    // "selected" step, so the prior coral arrows between cells were
    // layering a misleading direction cue on top of the readiness
    // opacity already encoded per cell. Cell padding now handles
    // the inter-cell breathing room.
    final workflowChildren = <Widget>[
      _CapsCell(
        icon: Icons.photo_camera_outlined,
        label: 'CAPTURE',
        active: true,
        onTap: onCaptureTap,
        tooltip: 'Capture (camera)',
      ),
      _CapsCell(
        // 2026-05-16 — Adjust glyph is now Flutter's `Icons.tune`
        // rotated -90° so the three sliders sit vertical with
        // horizontal handles (matches the Feather "sliders" icon).
        // Communicates per-exercise tuning more directly than the
        // previous list-rows glyph.
        icon: Icons.tune,
        rotateGlyphQuarterTurns: -1,
        label: 'ADJUST',
        active: adjustActive,
        onTap: onAdjust,
        tooltip: 'Adjust top card',
      ),
      _CapsCell(
        icon: Icons.slideshow_outlined,
        label: 'PREVIEW',
        active: previewActive,
        onTap: previewActive ? onPreview : null,
        tooltip: 'Preview plan',
      ),
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (publishingChipLabel != null) ...[
            _PublishingChip(
              label: publishingChipLabel!,
              tone: publishingChipTone,
              progress: publishingChipProgress,
              onTap: onPublishingChipTap,
            ),
            const SizedBox(height: 8),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [workflowPill],
          ),
        ],
      ),
    );
  }
}

/// PR-C — workflow-toolbar chip rendered above the CAPS pill when the
/// publish sheet is dismissed mid-flight. Three tones; tone drives both
/// the background colour and the leading glyph.
class _PublishingChip extends StatelessWidget {
  final String label;
  final PublishingChipTone tone;
  final double? progress;
  final VoidCallback? onTap;

  const _PublishingChip({
    required this.label,
    required this.tone,
    required this.progress,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final Color bg;
    final Color fg;
    final IconData glyph;
    switch (tone) {
      case PublishingChipTone.inFlight:
        bg = AppColors.primary.withValues(alpha: 0.16);
        fg = AppColors.primary;
        glyph = Icons.cloud_upload_outlined;
        break;
      case PublishingChipTone.success:
        bg = AppColors.rest.withValues(alpha: 0.16);
        fg = AppColors.rest;
        glyph = Icons.check_circle_rounded;
        break;
      case PublishingChipTone.failure:
        bg = AppColors.primary.withValues(alpha: 0.22);
        fg = AppColors.primary;
        glyph = Icons.error_outline_rounded;
        break;
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap == null
          ? null
          : () {
              HapticFeedback.selectionClick();
              onTap!();
            },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: fg.withValues(alpha: 0.4), width: 1),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(glyph, size: 16, color: fg),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: fg,
                  ),
                ),
              ],
            ),
            if (progress != null) ...[
              const SizedBox(height: 6),
              SizedBox(
                width: 160,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: progress!.clamp(0.0, 1.0),
                    minHeight: 3,
                    backgroundColor: fg.withValues(alpha: 0.2),
                    valueColor: AlwaysStoppedAnimation<Color>(fg),
                  ),
                ),
              ),
            ],
          ],
        ),
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

/// One CAPS cell: a glyph sitting directly on the pill surface with a
/// short uppercase label below. The label dims with the glyph so the
/// active vs disabled state reads on either layer. Mirrors the
/// `ToolbarStrip` component on the public help page (web-portal).
///
/// 2026-05-16 — the dark round chip behind the glyph was removed;
/// the icon now floats on the pill surface inside a 30×30 box at
/// size 28 (per the toolbar cleanup mockup).
class _CapsCell extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback? onTap;
  final String tooltip;
  /// Coral tint for the locked-state Unlock cell so it reads as a
  /// payment gate rather than a generic toolbar action.
  final bool accent;
  /// Optional quarter-turn rotation applied to the glyph only (label
  /// and tap target are unaffected). Used by the Adjust cell to turn
  /// `Icons.tune` into a vertical-sliders glyph.
  final int rotateGlyphQuarterTurns;

  const _CapsCell({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
    required this.tooltip,
    this.accent = false,
    this.rotateGlyphQuarterTurns = 0,
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

    Widget glyph = Icon(icon, color: glyphColor, size: 28);
    if (rotateGlyphQuarterTurns != 0) {
      glyph = RotatedBox(
        quarterTurns: rotateGlyphQuarterTurns,
        child: glyph,
      );
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
                  SizedBox(
                    width: 30,
                    height: 30,
                    child: Center(child: glyph),
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
        width: 22,
        height: 22,
        child: CircularProgressIndicator(
          strokeWidth: 2.4,
          color: AppColors.primary,
        ),
      );
    } else if (hasError) {
      glyph = Icon(Icons.error_outline, color: glyphColor, size: 28);
    } else {
      // Wave 41 — checkmark state retired. The publish cell always
      // shows cloud_upload_outlined; success is a SnackBar toast.
      // 2026-05-16 — bumped to size 28 to match the other CAPS
      // cells now that the dark round chip is gone.
      glyph = Icon(Icons.cloud_upload_outlined, color: glyphColor, size: 28);
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
                  // 2026-05-16 — dark round chip removed; glyph floats
                  // directly on the pill surface in a 30×30 box,
                  // matching `_CapsCell`.
                  SizedBox(
                    width: 30,
                    height: 30,
                    child: Center(child: glyph),
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

