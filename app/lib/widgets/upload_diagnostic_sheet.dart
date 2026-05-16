import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/publish_progress.dart' show UploadFailureRecord;
import '../theme.dart';

/// Per-file diagnostic body for the publish-failure progress sheet.
///
/// PR #335 (2026-05-14) added `debugPrint` lines on each `loudSwallow`
/// miss so the publisher could read which variant upload failed via
/// the Xcode device console. BUG 13 follow-up (2026-05-15) extended
/// that to an in-app affordance via [UploadDiagnosticSheet] —
/// a standalone modal that opened on top of [PublishProgressSheet]
/// when the practitioner tapped "Show which files →".
///
/// HISTORY — the standalone-modal shape caused a recurring tap-dead
/// bug. PR #357 set `useRootNavigator: true` on the child sheet to
/// layer it over the parent; PR #362 dropped that flag. Neither fix
/// took because the parent and child sheets end up on different
/// navigator stacks (Studio's local navigator vs the root navigator
/// reached through `rootScaffoldMessengerKey.currentContext`).
///
/// CURRENT SHAPE — there is no second modal. [PublishProgressSheet]
/// embeds this body as one of three internal views. The drag-handle
/// + rounded chrome belongs to the parent modal route; this body
/// renders only the content + a back chevron. The dismissal control
/// is the back arrow at the top, not a Close button at the bottom.
class UploadDiagnosticBody extends StatelessWidget {
  final List<UploadFailureRecord> failures;

  /// Tap-handler for the back chevron at top-left. The parent sheet
  /// uses this to switch its internal view back to the progress view.
  final VoidCallback onBack;

  const UploadDiagnosticBody({
    super.key,
    required this.failures,
    required this.onBack,
  });

  Future<void> _copyAll(BuildContext context) async {
    final text = failures.map((f) => f.toClipboardText()).join('\n\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            'Copied ${failures.length} failure record(s) to clipboard',
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

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _BackChevronRow(onBack: onBack),
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 4, 20, 4),
          child: Text(
            'Upload diagnostic — last publish',
            style: TextStyle(
              fontFamily: 'Montserrat',
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AppColors.textOnDark,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Text(
            '${failures.length} optional file${failures.length == 1 ? '' : 's'} '
            'failed to upload. Main plan published OK; '
            'retry publish to backfill.',
            style: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 13,
              height: 1.35,
              color: AppColors.textSecondaryOnDark,
            ),
          ),
        ),
        Flexible(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            shrinkWrap: true,
            itemCount: failures.length,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (_, i) =>
                _FailureCard(record: failures[i]),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: OutlinedButton.icon(
            onPressed: () => _copyAll(context),
            icon: const Icon(Icons.copy_all_rounded, size: 18),
            label: const Text('Copy all'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.primary,
              side: BorderSide(
                color: AppColors.primary.withValues(alpha: 0.6),
              ),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
      ],
    );
  }
}

class _BackChevronRow extends StatelessWidget {
  final VoidCallback onBack;

  const _BackChevronRow({required this.onBack});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
      child: Row(
        children: [
          IconButton(
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back_rounded, size: 24),
            color: AppColors.primary,
            tooltip: 'Back',
            padding: const EdgeInsets.all(8),
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }
}

class _FailureCard extends StatelessWidget {
  final UploadFailureRecord record;

  const _FailureCard({required this.record});

  @override
  Widget build(BuildContext context) {
    final indexLabel = record.exerciseIndex != null
        ? '#${record.exerciseIndex! + 1}'
        : '#?';
    final nameLabel = (record.exerciseName == null ||
            record.exerciseName!.isEmpty)
        ? _truncate(record.exerciseId, 12)
        : record.exerciseName!;
    final existsColor = record.fileExists
        ? const Color(0xFF86EFAC) // sage
        : const Color(0xFFEF4444); // red
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
          // Row 1 — kind chip + exists icon
          Row(
            children: [
              Expanded(
                child: Container(
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
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      record.kind,
                      style: const TextStyle(
                        fontFamily: 'Menlo',
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: AppColors.primary,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Row(
                children: [
                  Icon(
                    record.fileExists
                        ? Icons.check_circle_outline_rounded
                        : Icons.error_outline_rounded,
                    size: 14,
                    color: existsColor,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    record.fileExists ? 'exists' : 'missing',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: existsColor,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Row 2 — exercise label
          Text(
            'Exercise: $indexLabel $nameLabel',
            style: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.textOnDark,
            ),
          ),
          const SizedBox(height: 6),
          // Row 3 — storage path
          SelectableText(
            'Bucket: ${record.storagePath}',
            style: const TextStyle(
              fontFamily: 'Menlo',
              fontSize: 11,
              height: 1.35,
              color: AppColors.textSecondaryOnDark,
            ),
          ),
          const SizedBox(height: 4),
          // Row 4 — local path (relativised to hide sandbox UUID)
          SelectableText(
            'Local: ${_relativisePath(record.localPath)}',
            style: const TextStyle(
              fontFamily: 'Menlo',
              fontSize: 11,
              height: 1.35,
              color: AppColors.textSecondaryOnDark,
            ),
          ),
        ],
      ),
    );
  }

  static String _truncate(String s, int n) =>
      s.length <= n ? s : '${s.substring(0, n)}…';

  /// Show file paths relative to `Documents/` so the sheet doesn't
  /// leak the per-install sandbox UUID. Matches
  /// `ConversionErrorLogSheet`'s helper.
  static String _relativisePath(String path) {
    final docsIdx = path.indexOf('/Documents/');
    if (docsIdx >= 0) return path.substring(docsIdx + 1);
    return path;
  }
}
