import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/exercise_capture.dart';
import '../models/session.dart';
import '../services/conversion_service.dart';
import '../theme.dart';

/// Visual-only session card — the rendering pulled out of the retired
/// flat-list Home screen so it can be reused by
/// [`ClientSessionsScreen`] under the Clients-as-Home spine IA (R-11).
///
/// Behaviour stays identical to the legacy Home card:
/// - Tap opens the session.
/// - Horizontal swipe (left) fires a soft-delete with an Undo SnackBar.
///   Per R-01 the delete runs immediately; the parent supplies the
///   [onDelete] handler that owns the SnackBar dance.
/// - Right-side action row: Publish / Share / chevron. (Copy-link icon
///   retired in Wave 3 — Share covers the same intent without the
///   silent-clipboard ambiguity.)
/// - Failed-conversion retry pill under the subtitle.
///
/// All network / storage side-effects are pushed up to the parent via
/// the `on*` callbacks so this widget stays pure-render and reusable
/// from any screen that lists sessions.
class SessionCard extends StatelessWidget {
  final Session session;
  final bool isPublishing;
  final String? publishError;

  final VoidCallback onOpen;
  final VoidCallback onDelete;
  final VoidCallback onPublish;
  final VoidCallback? onShare;
  final VoidCallback onShowPublishError;

  const SessionCard({
    super.key,
    required this.session,
    required this.isPublishing,
    required this.publishError,
    required this.onOpen,
    required this.onDelete,
    required this.onPublish,
    required this.onShowPublishError,
    this.onShare,
  });

  @override
  Widget build(BuildContext context) {
    final exerciseCount = session.exercises.length;
    final pending = session.pendingConversions;

    // Determine publish/share button states (rules lifted verbatim from
    // the retired Home implementation — changing them would regress the
    // existing publish flow).
    final hasConversionsRunning = session.exercises.any((e) =>
        !e.isRest &&
        (e.conversionStatus == ConversionStatus.pending ||
            e.conversionStatus == ConversionStatus.converting));
    final hasExercises =
        session.exercises.where((e) => !e.isRest).isNotEmpty;
    final canPublish = hasExercises && !hasConversionsRunning && !isPublishing;
    final isPublishedClean =
        session.isPublished && !_hasUnpublishedChanges(session);
    final hasPublishError = publishError != null && !isPublishing;

    final failedConversions = session.exercises
        .where((e) => e.conversionStatus == ConversionStatus.failed)
        .toList(growable: false);
    final hasFailedConversions = failedConversions.isNotEmpty;

    return Dismissible(
      key: ValueKey(session.id),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) async => true,
      onDismissed: (_) => onDelete(),
      background: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(
          color: AppColors.error,
          borderRadius: BorderRadius.circular(12),
        ),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        child: const Icon(Icons.delete_outline, color: Colors.white, size: 28),
      ),
      child: Card(
        elevation: 0,
        color: AppColors.surfaceBase,
        margin: const EdgeInsets.symmetric(vertical: 4),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: AppColors.surfaceBorder, width: 1),
        ),
        child: InkWell(
          onTap: onOpen,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                // Leading camera badge — coral on dark surface, establishes
                // sessions as capture artefacts at a glance.
                _LeadingIconBadge(icon: Icons.camera_alt_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _cardTitle(session),
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          color: AppColors.textOnDark,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text:
                                  '$exerciseCount exercise${exerciseCount == 1 ? '' : 's'}'
                                  '${pending > 0 ? ' ($pending converting...)' : ''}',
                            ),
                            TextSpan(
                              text: ' \u00b7 ${_publishLabel(session)}',
                              style: TextStyle(
                                color: session.version > 0
                                    ? AppColors.circuit
                                    : AppColors.grey500,
                              ),
                            ),
                          ],
                        ),
                        style: const TextStyle(
                          color: AppColors.textSecondaryOnDark,
                          fontSize: 13,
                        ),
                      ),
                      if (hasFailedConversions) ...[
                        const SizedBox(height: 6),
                        _FailedConversionsPill(
                          failed: failedConversions,
                        ),
                      ],
                    ],
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isPublishing)
                      const SizedBox(
                        width: 34,
                        height: 34,
                        child: Padding(
                          padding: EdgeInsets.all(7),
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColors.grey500,
                          ),
                        ),
                      )
                    else
                      SizedBox(
                        width: 34,
                        height: 34,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            IconButton(
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              iconSize: 20,
                              onPressed: canPublish
                                  ? onPublish
                                  : (hasPublishError
                                      ? onShowPublishError
                                      : null),
                              icon: Icon(
                                hasPublishError
                                    ? Icons.cloud_off_outlined
                                    : isPublishedClean
                                        ? Icons.check_circle
                                        : Icons.cloud_upload_outlined,
                                color: hasPublishError
                                    ? AppColors.error
                                    : isPublishedClean
                                        ? AppColors.circuit
                                        : canPublish
                                            ? AppColors.textOnDark
                                            : AppColors.grey600,
                                size: 20,
                              ),
                              tooltip: hasPublishError
                                  ? 'Publish failed — tap for details'
                                  : isPublishedClean
                                      ? 'Published'
                                      : 'Publish',
                            ),
                            if (hasPublishError)
                              Positioned(
                                top: 2,
                                right: 2,
                                child: Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: AppColors.error,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: AppColors.surfaceBase,
                                      width: 1,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    SizedBox(
                      width: 34,
                      height: 34,
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        iconSize: 20,
                        onPressed: session.isPublished ? onShare : null,
                        icon: Icon(
                          Icons.ios_share,
                          color: session.isPublished
                              ? AppColors.textOnDark
                              : AppColors.grey600,
                          size: 20,
                        ),
                        tooltip: 'Share',
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Icon(
                      Icons.chevron_right,
                      color: AppColors.grey500,
                      size: 22,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Display title for the card row.
  ///
  /// Prefers [Session.title] when set (new flow: "Jan Smith · 19 Apr 2026
  /// 17:09"). Falls back to [Session.clientName] so legacy sessions still
  /// read as the date-stamp they were minted with.
  static String _cardTitle(Session session) {
    final t = session.title;
    if (t != null && t.trim().isNotEmpty) return t;
    return session.clientName;
  }

  /// Short publish-status label for the session card.
  static String _publishLabel(Session session) {
    if (session.version == 0) return 'Draft';
    final v = 'Published v${session.version}';
    final dt = session.lastPublishedAt;
    if (dt == null) return v;
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final date = '${dt.day} ${months[dt.month - 1]}';
    return '$v \u00b7 $date';
  }

  /// Heuristic "does this session have unpublished changes?". Mirrors the
  /// retired Home impl — once published and not actively edited, it's
  /// considered clean. Any re-publish is explicit.
  bool _hasUnpublishedChanges(Session session) {
    if (!session.isPublished) return true;
    return false;
  }
}

/// Coral-tinted retry pill. Extracted unchanged from the retired Home
/// screen impl so the visual language of "N failed" stays consistent.
class _FailedConversionsPill extends StatelessWidget {
  final List<ExerciseCapture> failed;

  const _FailedConversionsPill({required this.failed});

  @override
  Widget build(BuildContext context) {
    final count = failed.length;
    return Align(
      alignment: Alignment.centerLeft,
      child: Material(
        color: AppColors.primary.withValues(alpha: 0.14),
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: () => _retry(context, failed),
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.refresh_rounded,
                  size: 14,
                  color: AppColors.primary,
                ),
                const SizedBox(width: 4),
                Text(
                  '$count failed',
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 12,
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

  Future<void> _retry(
    BuildContext context,
    List<ExerciseCapture> failed,
  ) async {
    HapticFeedback.selectionClick();
    for (final ex in failed) {
      unawaited(ConversionService.instance.retry(ex));
    }
    if (!context.mounted) return;
    final count = failed.length;
    final plural = count == 1 ? 'exercise' : 'exercises';
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            'Retrying $count $plural',
            style: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 14,
              color: AppColors.textOnDark,
            ),
          ),
          backgroundColor: AppColors.surfaceRaised,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: AppColors.surfaceBorder),
          ),
        ),
      );
  }
}

/// Small coral-tinted icon badge sat at the leading edge of session
/// (and client) cards. Colour token + treatment is centralised here
/// so both surfaces stay in lock-step visually.
///
/// Coral at 12% alpha background on the dark surface + a coral-filled
/// glyph. Size + radius match the app's chip vocabulary (40×40, radius 10).
class _LeadingIconBadge extends StatelessWidget {
  final IconData icon;
  const _LeadingIconBadge({required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      alignment: Alignment.center,
      child: Icon(icon, color: AppColors.primary, size: 22),
    );
  }
}
