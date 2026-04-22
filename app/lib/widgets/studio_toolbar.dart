import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/session.dart';
import '../theme.dart';

/// Unified Studio toolbar. Lives directly below the AppBar, above the
/// exercise list. Four actions in a fixed order, separated by coral
/// right-pointing triangles that echo each action's state:
///
///     Import  ▸  Preview  ▸  Publish  ▸  Share
///
/// Variant C1 — state-aware dimming:
///   * Dim icon = 45% opacity, no haptic on tap, still renders tooltip.
///   * The triangle FEEDING INTO a dim icon is also dim. This creates
///     a "chain" read: if Share is dim (session not published),
///     Publish→Share triangle reads dim too.
///   * Import is always active. Preview active when `exercises.isNotEmpty`.
///     Publish active when [canPublish] (has exercises, no conversions
///     running, not mid-publish); error state ALSO counts as active —
///     tap to view the error. Share active when `session.isPublished`.
///
/// Publish icon mutates per state:
///   never published       → cloud_upload_outlined, coral
///   published & clean     → check_circle, sage
///   published & dirty     → cloud_upload_outlined, coral
///   publishing            → 22pt CircularProgressIndicator, coral
///   error                 → error_outline, red (tap = show error)
///
/// A small lock badge overlays the Publish icon bottom-right when
/// [isPublishLocked] is true; tapping a locked Publish fires the
/// caller's [onPublishLockedTap] (the existing showPublishLockToast).
class StudioToolbar extends StatelessWidget {
  final Session session;
  final bool isPublishing;
  final bool canPublish;
  final bool isPublishLocked;
  final String? publishError;

  final VoidCallback onImport;
  final VoidCallback onPreview;
  final VoidCallback onPreviewLongPress;
  final VoidCallback onPublish;
  final VoidCallback onPublishLockedTap;
  final VoidCallback onShowPublishError;
  final VoidCallback? onShare;

  const StudioToolbar({
    super.key,
    required this.session,
    required this.isPublishing,
    required this.canPublish,
    required this.isPublishLocked,
    required this.publishError,
    required this.onImport,
    required this.onPreview,
    required this.onPreviewLongPress,
    required this.onPublish,
    required this.onPublishLockedTap,
    required this.onShowPublishError,
    required this.onShare,
  });

  @override
  Widget build(BuildContext context) {
    final hasExercises = session.exercises.isNotEmpty;
    final previewActive = hasExercises;
    final publishedDirty =
        session.isPublished && session.hasUnpublishedContentChanges;
    final publishedClean = session.isPublished && !publishedDirty;
    final hasPublishError = publishError != null && !isPublishing;
    // "active" for publish — also true when publish errored (tap shows
    // the error sheet).
    final publishActive = canPublish || hasPublishError;
    final shareActive = session.isPublished;

    final children = <Widget>[
      _IconButton(
        icon: Icons.photo_library_outlined,
        iconColor: AppColors.textOnDark,
        active: true,
        onTap: onImport,
        tooltip: 'Import from library',
      ),
      _Triangle(dim: !previewActive),
      _IconButton(
        icon: Icons.slideshow_outlined,
        iconColor: AppColors.textOnDark,
        active: previewActive,
        onTap: previewActive ? onPreview : null,
        onLongPress: previewActive ? onPreviewLongPress : null,
        tooltip: 'Preview plan (long-press: legacy native)',
      ),
      _Triangle(dim: !publishActive),
      _PublishIconButton(
        session: session,
        isPublishing: isPublishing,
        canPublish: canPublish,
        isPublishLocked: isPublishLocked,
        publishError: publishError,
        publishedClean: publishedClean,
        publishedDirty: publishedDirty,
        onPublish: onPublish,
        onPublishLockedTap: onPublishLockedTap,
        onShowPublishError: onShowPublishError,
      ),
      _Triangle(dim: !shareActive),
      _IconButton(
        icon: Icons.ios_share,
        iconColor: AppColors.textOnDark,
        active: shareActive,
        onTap: shareActive ? onShare : null,
        tooltip: 'Share link',
      ),
    ];

    return Container(
      // Wave 18.1 compaction: 52 → 40. The child IconButtons also
      // shrink via visualDensity: compact + padding: zero (see
      // _IconButton / _PublishIconButton below), so icons stay 22pt
      // visible while the overall strip reads tighter.
      height: 40,
      decoration: const BoxDecoration(
        color: AppColors.surfaceBase,
        border: Border(
          bottom: BorderSide(
            color: AppColors.surfaceBorder,
            width: 1,
          ),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: children,
      ),
    );
  }
}

/// Shared glyph + ink surface for the toolbar's active/inactive icons.
/// 48pt tap target, 22pt glyph, ~45% opacity when inactive. Tooltip
/// on long-press (the Flutter IconButton default).
class _IconButton extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final bool active;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final String tooltip;

  const _IconButton({
    required this.icon,
    required this.iconColor,
    required this.active,
    required this.onTap,
    required this.tooltip,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final color = active ? iconColor : iconColor.withValues(alpha: 0.45);
    // Wave 18.1 compaction — IconButton with visualDensity.compact +
    // zero padding. Previously a raw GestureDetector inside a 48×48
    // SizedBox; the button surface now matches the 40pt toolbar
    // height. The 22pt visible glyph is preserved via iconSize.
    //
    // Long-press (Preview's legacy-native escape hatch) is wired via
    // a wrapping GestureDetector since IconButton has no onLongPress.
    final button = IconButton(
      onPressed: onTap == null
          ? null
          : () {
              HapticFeedback.selectionClick();
              onTap!();
            },
      icon: Icon(icon, color: color, size: 22),
      iconSize: 22,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
      splashRadius: 20,
      tooltip: tooltip,
    );
    if (onLongPress == null) return button;
    return GestureDetector(
      onLongPress: onLongPress,
      behavior: HitTestBehavior.opaque,
      child: button,
    );
  }
}

/// The Publish icon — state-aware glyph + colour + optional lock badge
/// overlay. Kept as its own widget so the toolbar Row stays readable.
class _PublishIconButton extends StatelessWidget {
  final Session session;
  final bool isPublishing;
  final bool canPublish;
  final bool isPublishLocked;
  final String? publishError;
  final bool publishedClean;
  final bool publishedDirty;
  final VoidCallback onPublish;
  final VoidCallback onPublishLockedTap;
  final VoidCallback onShowPublishError;

  const _PublishIconButton({
    required this.session,
    required this.isPublishing,
    required this.canPublish,
    required this.isPublishLocked,
    required this.publishError,
    required this.publishedClean,
    required this.publishedDirty,
    required this.onPublish,
    required this.onPublishLockedTap,
    required this.onShowPublishError,
  });

  @override
  Widget build(BuildContext context) {
    final hasPublishError = publishError != null && !isPublishing;

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
    } else if (hasPublishError) {
      glyph = const Icon(
        Icons.error_outline,
        color: AppColors.error,
        size: 22,
      );
    } else if (publishedClean) {
      glyph = const Icon(
        Icons.check_circle,
        color: AppColors.circuit,
        size: 22,
      );
    } else {
      // never published OR published+dirty → coral upload.
      final color = canPublish ? AppColors.primary : AppColors.grey600;
      glyph = Icon(
        Icons.cloud_upload_outlined,
        color: color,
        size: 22,
      );
    }

    final active = canPublish || hasPublishError;

    String tooltip;
    if (hasPublishError) {
      tooltip = 'Last publish failed: ${publishError!}';
    } else if (publishedClean) {
      tooltip = 'Published v${session.version} — tap to re-share';
    } else if (publishedDirty) {
      tooltip = 'Changes pending — tap to re-publish';
    } else if (session.isPublished) {
      tooltip = 'Publish';
    } else {
      tooltip = 'Publish';
    }

    VoidCallback? handler;
    if (isPublishLocked) {
      handler = onPublishLockedTap;
    } else if (hasPublishError) {
      handler = onShowPublishError;
    } else if (canPublish) {
      handler = onPublish;
    }

    // Wave 18.1 compaction — IconButton with visualDensity.compact +
    // zero padding, minWidth/minHeight 40 to match the new toolbar
    // height. The lock badge overlays via the IconButton's icon slot,
    // which accepts a Stack.
    return IconButton(
      onPressed: handler == null
          ? null
          : () {
              HapticFeedback.selectionClick();
              handler!();
            },
      icon: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          Opacity(opacity: active ? 1.0 : 0.45, child: glyph),
          if (isPublishLocked)
            const Positioned(
              right: -4,
              bottom: -4,
              child: Icon(
                Icons.lock_outline,
                size: 12,
                color: AppColors.textSecondaryOnDark,
              ),
            ),
        ],
      ),
      iconSize: 22,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
      splashRadius: 20,
      tooltip: tooltip,
    );
  }
}

/// Coral right-pointing triangle separator between toolbar icons.
/// 5pt wide × 6pt tall, centred in its 16pt-wide channel. Dim state
/// echoes the adjacent icon's active/inactive read.
class _Triangle extends StatelessWidget {
  final bool dim;

  const _Triangle({required this.dim});

  @override
  Widget build(BuildContext context) {
    // Height bumped down from 48 → 40 to match the Wave 18.1 toolbar
    // compaction. Visible triangle extents are controlled in the
    // painter, so the centred triangle keeps the same visible size.
    return SizedBox(
      width: 16,
      height: 40,
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
    const halfWidth = 2.5; // 5pt tall visual edge
    const halfHeight = 3.0; // 6pt vertical extent from centre
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
