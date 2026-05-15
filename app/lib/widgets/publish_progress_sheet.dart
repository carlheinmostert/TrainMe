import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/publish_progress.dart';
import '../theme.dart';
import 'upload_diagnostic_sheet.dart';

/// Bottom-sheet UI for the new atomic-publish flow (PR-C of the
/// 2026-05-15 publish-flow refactor).
///
/// Five phase rows — Preparing / Reserving credit / Uploading treatments /
/// Saving plan / Finalising. Each row carries a status glyph:
///
///   * pending  — grey 18px circle outline
///   * active   — coral filled circle with pulse animation
///   * done     — sage check inside a sage-tinted circle
///   * failed   — coral exclamation inside a coral-tinted circle
///
/// Phase 3 ("Uploading treatments") also renders the per-file subtitle
/// ("N of M files") + a 4px coral progress bar fed by
/// [PublishProgress.filesFraction].
///
/// Subscribes to a `ValueListenable<PublishProgress>` so the host
/// (studio_mode_screen) can push events from the publish stream without
/// the sheet rebuilding the whole subtree on each tick.
///
/// Dismiss semantics — the sheet is `isDismissible: true, enableDrag:
/// true`. Swipe-down closes the sheet WITHOUT cancelling the publish.
/// The host catches the dismissal, flips on a "publishing chip" in the
/// workflow toolbar, and the publish continues in the background. Spec:
/// docs/design/mockups/publish-progress-sheet.html.
class PublishProgressSheet extends StatefulWidget {
  /// The progress notifier driven by the publish flow. The sheet
  /// rebuilds on every tick.
  final ValueListenable<PublishProgress> progress;

  /// Called when the practitioner taps the "Retry publish" button in
  /// the failure state. Host re-fires the publish flow.
  final VoidCallback onRetry;

  /// Called when the sheet auto-dismisses on success (after the 1s
  /// "All set" beat). Host fires the "Plan published" toast + lights
  /// up the Share affordance.
  final VoidCallback onSuccessDismiss;

  /// Called when the practitioner taps "Show which files →" on the
  /// failure state. Host hands the failure list to
  /// [UploadDiagnosticSheet.show].
  final ValueChanged<List<UploadFailureRecord>>? onShowFailureDetails;

  /// Fallback failure list for the re-open-after-dismiss path. The
  /// PR-C reactive-failures fix routes failures through the
  /// [PublishProgress.failure] stream event so the sheet reads
  /// `widget.progress.value.failures` directly. This prop is only
  /// consulted when the stream snapshot's `failures` is empty (e.g.
  /// the host re-opens the sheet after a swipe-dismiss and the
  /// notifier still carries an older event).
  final List<UploadFailureRecord> failures;

  const PublishProgressSheet({
    super.key,
    required this.progress,
    required this.onRetry,
    required this.onSuccessDismiss,
    this.onShowFailureDetails,
    this.failures = const [],
  });

  /// Open the sheet over the given navigator. Returns the future the
  /// `showModalBottomSheet` returns; the host typically ignores the
  /// resolution (the sheet's lifecycle is driven by progress events,
  /// not the pop value).
  static Future<void> show(
    BuildContext context, {
    required ValueListenable<PublishProgress> progress,
    required VoidCallback onRetry,
    required VoidCallback onSuccessDismiss,
    required VoidCallback onDismissed,
    ValueChanged<List<UploadFailureRecord>>? onShowFailureDetails,
    List<UploadFailureRecord> failures = const [],
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      // Non-blocking: swipe-down to dismiss; the publish keeps running
      // in the background. The host pops a chip into the toolbar.
      isDismissible: true,
      enableDrag: true,
      isScrollControlled: true,
      backgroundColor: AppColors.surfaceRaised,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      showDragHandle: true,
      builder: (_) => PublishProgressSheet(
        progress: progress,
        onRetry: onRetry,
        onSuccessDismiss: onSuccessDismiss,
        onShowFailureDetails: onShowFailureDetails,
        failures: failures,
      ),
    );
    onDismissed();
  }

  @override
  State<PublishProgressSheet> createState() => _PublishProgressSheetState();
}

class _PublishProgressSheetState extends State<PublishProgressSheet>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  bool _successDismissed = false;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat();
    widget.progress.addListener(_onProgress);
    _onProgress();
  }

  @override
  void dispose() {
    widget.progress.removeListener(_onProgress);
    _pulseController.dispose();
    super.dispose();
  }

  void _onProgress() {
    final p = widget.progress.value;
    if (p.allDone && !_successDismissed) {
      _successDismissed = true;
      // 1-second "All set" beat then auto-dismiss.
      Future.delayed(const Duration(seconds: 1), () {
        if (!mounted) return;
        Navigator.of(context).maybePop();
        widget.onSuccessDismiss();
      });
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.progress.value;
    final mediaInsets = MediaQuery.of(context).viewInsets;
    return Padding(
      padding: EdgeInsets.only(bottom: mediaInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(p),
            const SizedBox(height: 8),
            // Phase rows
            for (final phase in PublishPhase.values)
              _PhaseRow(
                phase: phase,
                status: p.statusOf(phase),
                pulse: _pulseController,
                subtitle: phase == PublishPhase.uploadingTreatments
                    ? p.filesSubtitle
                    : '',
                progressFraction:
                    phase == PublishPhase.uploadingTreatments &&
                            p.statusOf(phase) == PublishPhaseStatus.active
                        ? p.filesFraction
                        : null,
              ),
            const SizedBox(height: 16),
            _buildFooter(p),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(PublishProgress p) {
    String title;
    String subtitle;
    Color titleColor = AppColors.textOnDark;
    if (p.allDone) {
      title = 'All set';
      subtitle = 'Plan published — Share is ready.';
      titleColor = AppColors.rest;
    } else if (p.failed) {
      title = 'Publish failed';
      subtitle = 'Your credit was refunded. Tap retry to publish again.';
      titleColor = AppColors.primary;
    } else {
      title = 'Publishing plan';
      subtitle = 'You can swipe down — publish keeps running.';
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontFamily: 'Montserrat',
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: titleColor,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 13,
              color: AppColors.textSecondaryOnDark,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFooter(PublishProgress p) {
    if (p.allDone) {
      // 1s beat then auto-dismiss; show a sage banner.
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.rest.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: AppColors.rest.withValues(alpha: 0.5),
            ),
          ),
          child: Row(
            children: [
              Icon(Icons.check_circle_rounded,
                  color: AppColors.rest, size: 20),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Plan published.',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textOnDark,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    if (p.failed) {
      // PR-C reactive-failures fix — prefer the failures carried by
      // the failure event (always populated by upload_service when
      // the failure is an atomic-upload one). Fall back to the prop
      // only on the re-open path where the host may have rebuilt the
      // sheet against a notifier that still holds an older event.
      final failureList =
          p.failures.isNotEmpty ? p.failures : widget.failures;
      final hasFailureDetails =
          failureList.isNotEmpty && widget.onShowFailureDetails != null;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (hasFailureDetails)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    widget.onShowFailureDetails!(failureList);
                  },
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'Show which files',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppColors.primary,
                          decoration: TextDecoration.underline,
                          decorationColor:
                              AppColors.primary.withValues(alpha: 0.6),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(Icons.arrow_forward_rounded,
                          size: 14, color: AppColors.primary),
                    ],
                  ),
                ),
              ),
            ElevatedButton(
              onPressed: () {
                HapticFeedback.mediumImpact();
                Navigator.of(context).maybePop();
                widget.onRetry();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text(
                'Retry publish',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
            ),
          ],
        ),
      );
    }
    // In-flight: short hint that swipe is safe.
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 20),
      child: Text(
        'Swipe down to keep working — we will let you know when it lands.',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontFamily: 'Inter',
          fontSize: 12,
          color: AppColors.textSecondaryOnDark,
          height: 1.45,
        ),
      ),
    );
  }
}

/// One phase row inside the sheet. Renders glyph + title + optional
/// subtitle + optional progress bar.
class _PhaseRow extends StatelessWidget {
  final PublishPhase phase;
  final PublishPhaseStatus status;
  final Animation<double> pulse;
  final String subtitle;
  final double? progressFraction;

  const _PhaseRow({
    required this.phase,
    required this.status,
    required this.pulse,
    required this.subtitle,
    this.progressFraction,
  });

  @override
  Widget build(BuildContext context) {
    final showBar = progressFraction != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _StatusGlyph(status: status, pulse: pulse),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  phase.title,
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: _titleColor(status),
                  ),
                ),
                if (subtitle.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitle,
                      style: const TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 12,
                        color: AppColors.textSecondaryOnDark,
                      ),
                    ),
                  ),
                if (showBar)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: progressFraction!.clamp(0.0, 1.0),
                        minHeight: 4,
                        backgroundColor: AppColors.surfaceBase,
                        valueColor:
                            AlwaysStoppedAnimation<Color>(AppColors.primary),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Color _titleColor(PublishPhaseStatus status) {
    switch (status) {
      case PublishPhaseStatus.pending:
        return AppColors.textSecondaryOnDark;
      case PublishPhaseStatus.active:
      case PublishPhaseStatus.done:
        return AppColors.textOnDark;
      case PublishPhaseStatus.failed:
        return AppColors.primary;
    }
  }
}

class _StatusGlyph extends StatelessWidget {
  final PublishPhaseStatus status;
  final Animation<double> pulse;

  const _StatusGlyph({required this.status, required this.pulse});

  @override
  Widget build(BuildContext context) {
    switch (status) {
      case PublishPhaseStatus.pending:
        return Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: AppColors.surfaceBorder, width: 1.5),
          ),
        );
      case PublishPhaseStatus.active:
        return AnimatedBuilder(
          animation: pulse,
          builder: (_, _) {
            // Pulse alpha between 0.55 and 1.0 so the dot reads as
            // "live" without flickering distracting motion.
            final t = (pulse.value * 2 - 1).abs(); // 0..1..0
            final alpha = 0.55 + 0.45 * (1 - t);
            return Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.primary.withValues(alpha: alpha),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.primary.withValues(alpha: 0.5 * alpha),
                    blurRadius: 10,
                    spreadRadius: 1,
                  ),
                ],
              ),
            );
          },
        );
      case PublishPhaseStatus.done:
        return Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.rest.withValues(alpha: 0.18),
            border: Border.all(color: AppColors.rest, width: 1.5),
          ),
          child: Icon(Icons.check_rounded,
              size: 14, color: AppColors.rest),
        );
      case PublishPhaseStatus.failed:
        return Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.primary.withValues(alpha: 0.18),
            border: Border.all(color: AppColors.primary, width: 1.5),
          ),
          child: Icon(Icons.priority_high_rounded,
              size: 14, color: AppColors.primary),
        );
    }
  }
}
