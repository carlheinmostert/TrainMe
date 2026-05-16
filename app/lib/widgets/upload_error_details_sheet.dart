import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/publish_progress.dart';
import '../theme.dart';

/// Diagnostic bottom sheet for non-atomic-upload publish failures.
///
/// Sibling to [UploadDiagnosticSheet] (which renders a per-file failure
/// list for atomic raw-archive + media-bucket upload failures). This
/// sheet renders the single error payload captured for failure modes
/// where there is no per-file breakdown — network errors, RLS
/// rejections, RPC errors, credit-consume blips, savePlan failures.
///
/// Layout (single screen, no scroll for typical payloads):
///   * Heading      — "Publish failed"
///   * Subhead      — "Failed during {phase.title}."
///   * User message — practitioner-facing copy, body weight.
///   * Diagnostic   — monospace selectable block with exception type +
///                    detail + capture timestamp. SelectableText so the
///                    practitioner can pick specific lines.
///   * Buttons      — "Copy" (writes [PublishErrorDetails.clipboardText]
///                    to clipboard) + "Close".
///
/// Uses `useRootNavigator: true` so the sheet layers cleanly above the
/// already-open progress sheet (same pattern as
/// [UploadDiagnosticSheet] per PR #357).
class UploadErrorDetailsSheet extends StatelessWidget {
  /// Diagnostic payload to render. Carries the phase, exception type,
  /// user message, optional detail string, pre-formatted clipboard
  /// text, and capture timestamp.
  final PublishErrorDetails details;

  const UploadErrorDetailsSheet({super.key, required this.details});

  /// Open the sheet over the current root navigator. No-op when
  /// [details] is null — the failure sheet wouldn't have offered the
  /// "Show error details" tap-target in that case anyway, but
  /// defending is cheap.
  static Future<void> show(
    BuildContext context,
    PublishErrorDetails? details,
  ) {
    if (details == null) return Future<void>.value();
    return showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      backgroundColor: AppColors.surfaceRaised,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      showDragHandle: true,
      builder: (_) => UploadErrorDetailsSheet(details: details),
    );
  }

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: details.clipboardText));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text(
            'Copied error details to clipboard',
            style: TextStyle(
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

  @override
  Widget build(BuildContext context) {
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
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 4),
              child: Text(
                'Publish failed',
                style: TextStyle(
                  fontFamily: 'Montserrat',
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textOnDark,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
              child: Text(
                'Failed during ${details.phase.title}.',
                style: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 13,
                  height: 1.35,
                  color: AppColors.textSecondaryOnDark,
                ),
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _UserMessageBlock(message: details.userMessage),
                    const SizedBox(height: 14),
                    _DiagnosticBlock(details: details),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _copy(context),
                      icon: const Icon(Icons.copy_all_rounded, size: 18),
                      label: const Text('Copy'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.primary,
                        side: BorderSide(
                          color: AppColors.primary.withValues(alpha: 0.6),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded, size: 18),
                      label: const Text('Close'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.textSecondaryOnDark,
                        side: const BorderSide(
                          color: AppColors.surfaceBorder,
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _UserMessageBlock extends StatelessWidget {
  final String message;

  const _UserMessageBlock({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.surfaceBase,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surfaceBorder),
      ),
      child: SelectableText(
        message,
        style: const TextStyle(
          fontFamily: 'Inter',
          fontSize: 14,
          height: 1.4,
          color: AppColors.textOnDark,
        ),
      ),
    );
  }
}

class _DiagnosticBlock extends StatelessWidget {
  final PublishErrorDetails details;

  const _DiagnosticBlock({required this.details});

  @override
  Widget build(BuildContext context) {
    final lines = <String>[
      'type: ${details.exceptionType}',
    ];
    final detail = details.detail;
    if (detail != null && detail.trim().isNotEmpty) {
      lines.add(detail.trim());
    }
    lines.add('captured: ${details.capturedAt.toIso8601String()}');
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.surfaceBase,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surfaceBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: AppColors.primary.withValues(alpha: 0.5),
                    width: 0.6,
                  ),
                ),
                child: const Text(
                  'diagnostic',
                  style: TextStyle(
                    fontFamily: 'Menlo',
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppColors.primary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SelectableText(
            lines.join('\n'),
            style: const TextStyle(
              fontFamily: 'Menlo',
              fontSize: 11,
              height: 1.4,
              color: AppColors.textSecondaryOnDark,
            ),
          ),
        ],
      ),
    );
  }
}
