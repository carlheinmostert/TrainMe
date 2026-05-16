import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/publish_progress.dart' show UploadFailureRecord;
import '../theme.dart';

/// Diagnostic bottom sheet that surfaces the per-file failure list from
/// the last publish's best-effort raw-archive upload pass.
///
/// PR #335 (2026-05-14) added `debugPrint` lines on each `loudSwallow`
/// miss so the publisher could read which variant upload failed via
/// the Xcode device console. BUG 13 follow-up (2026-05-15) extends
/// that to an in-app affordance — when the
/// "Published. Some optional treatment files are still processing…"
/// toast fires on Carl's staging build, a `Details` action opens this
/// sheet so he can paste the diagnostic back without needing a Mac.
///
/// Surface contract:
///   * One row per failed file (mirrors the `meta` map passed to
///     `loudSwallow`).
///   * "Copy all" copies a plain-text block per record (see
///     [UploadFailureRecord.toClipboardText]) so the paste reads the
///     same shape as a server-side `error_logs` row.
///   * Read-only — no retry button. Intentional. The next publish
///     re-runs the same best-effort pass and re-collects failures;
///     surfacing a retry button here would conflate the diagnostic
///     surface with the publish flow.
class UploadDiagnosticSheet extends StatelessWidget {
  final List<UploadFailureRecord> failures;

  const UploadDiagnosticSheet({super.key, required this.failures});

  /// Open the sheet over the current navigator. No-op when the list is
  /// empty — the toast wouldn't have offered a Details action in that
  /// case anyway, but defending against an accidental open is cheap.
  ///
  /// NAV-SCOPE RULE — do NOT add `useRootNavigator: true` here. The
  /// parent [PublishProgressSheet.show] pushes onto the local navigator
  /// (no `useRootNavigator` flag, see `publish_progress_sheet.dart`
  /// around line 100). When this sheet's `show()` used
  /// `useRootNavigator: true` (added in PR #357 with the intent of
  /// layering over the open progress sheet), the modal pushed onto an
  /// unreachable navigator — taps fired the haptic + callback but no
  /// modal appeared (PR #362 follow-up, 2026-05-16). Modal stacking on
  /// the same navigator handles z-order automatically; the parent and
  /// child must always agree on nav scope.
  static Future<void> show(
    BuildContext context,
    List<UploadFailureRecord> failures,
  ) {
    if (failures.isEmpty) return Future<void>.value();
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surfaceRaised,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      showDragHandle: true,
      builder: (_) => UploadDiagnosticSheet(failures: failures),
    );
  }

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
              child: Row(
                children: [
                  Expanded(
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
