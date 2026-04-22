import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/exercise_capture.dart';
import '../models/session.dart';
import '../services/conversion_service.dart';
import '../theme.dart';

/// Visual-only session card — one row in a client's session list.
///
/// Tap opens the session (navigates into the Studio shell). Swipe-left
/// soft-deletes via the parent's [onDelete]. The card row is purely
/// navigational: Publish + Share used to live here as trailing icons
/// but moved into the new Studio toolbar in Wave 18 so every publish
/// path roots from a single surface. Once the practitioner is inside
/// the Studio, they have full publish + share control there.
///
/// Failed-conversion retry pill stays — it's a per-exercise concern,
/// not a publish concern, and the parent list is the natural surface.
class SessionCard extends StatelessWidget {
  final Session session;

  /// Kept for legacy wiring + future reinstatement (a ClientSessionsScreen
  /// refresh may still care whether a parallel publish is running on
  /// this session — e.g. to grey out the row). Not currently rendered
  /// as a spinner on the card itself.
  final bool isPublishing;

  final VoidCallback onOpen;
  final VoidCallback onDelete;

  const SessionCard({
    super.key,
    required this.session,
    required this.isPublishing,
    required this.onOpen,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final exerciseCount = session.exercises.length;
    final pending = session.pendingConversions;

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
                // Wave 18 — Publish + Share icons moved to the Studio
                // toolbar. The card now ends with the chevron only so
                // the row reads as a pure navigation affordance.
                const Icon(
                  Icons.chevron_right,
                  color: AppColors.grey500,
                  size: 22,
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
