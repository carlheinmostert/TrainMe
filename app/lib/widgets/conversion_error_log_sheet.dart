import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../theme.dart';
import 'undo_snackbar.dart';

/// Diagnostic bottom sheet that surfaces the last 5 entries in
/// `{Documents}/conversion_error.log`.
///
/// Conversion failures are caught + appended to that file by
/// [ConversionService] (see `conversion_service.dart` ~L362). On a
/// real device we don't have UIFileSharingEnabled, so this sheet is
/// the only way to see the actual failure reason without rebuilding.
///
/// Long-press on the "N failed" pill on a SessionCard opens this sheet.
/// Intentionally a debug surface — minimal styling, monospace error
/// text + Copy / Delete affordances.
class ConversionErrorLogSheet extends StatefulWidget {
  const ConversionErrorLogSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surfaceRaised,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      showDragHandle: true,
      builder: (_) => const ConversionErrorLogSheet(),
    );
  }

  @override
  State<ConversionErrorLogSheet> createState() =>
      _ConversionErrorLogSheetState();
}

class _ConversionErrorLogSheetState extends State<ConversionErrorLogSheet> {
  /// Most-recent-first list of parsed log entries (max 5).
  List<_LogEntry>? _entries;
  String? _rawTail;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File(p.join(dir.path, 'conversion_error.log'));
      if (!await file.exists()) {
        if (!mounted) return;
        setState(() {
          _entries = const [];
          _rawTail = null;
          _loading = false;
        });
        return;
      }
      final raw = await file.readAsString();
      final entries = _parseEntries(raw, max: 5);
      // Re-stringify only the displayed entries so "Copy all" matches
      // what the user is looking at, not the full log file.
      final tail = entries.map((e) => e.raw.trim()).join('\n\n');
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _rawTail = tail.isEmpty ? null : tail;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _entries = const [];
        _rawTail = 'Failed to read log: $e';
        _loading = false;
      });
    }
  }

  /// Parse the conversion-error log from the END, returning at most
  /// [max] entries with the most recent first. Each entry is a chunk
  /// separated by a blank line, formatted by `conversion_service.dart`
  /// at L364–369:
  ///
  /// ```
  /// {DateTime}
  /// Exercise: {id}
  /// Raw file: {path}
  /// Error: {e}
  ///
  /// Stack:
  /// {stack}
  /// ```
  ///
  /// Note that the entry's own body contains a blank line between the
  /// Error: line and the Stack: header — so naively splitting on `\n\n`
  /// would split each entry in half. We split on `\n\n\n` (the trailing
  /// `\n\n` plus the next entry's leading newline) which the writer
  /// produces because it always closes its writeAsString with `\n\n`.
  static List<_LogEntry> _parseEntries(String raw, {required int max}) {
    final trimmed = raw.trimRight();
    if (trimmed.isEmpty) return const [];
    // Split on blank-line-between-entries. The writer ends each entry
    // with `\n\n`, then the NEXT entry starts at column 0, giving
    // `...\n\n{DateTime}` between adjacent entries. Use a regex that
    // matches a blank line immediately followed by an ISO-ish timestamp
    // start so we don't split on the entry-internal blank line above
    // "Stack:".
    final splitter = RegExp(r'\n\n(?=\d{4}-\d{2}-\d{2})');
    final parts = trimmed.split(splitter);
    final out = <_LogEntry>[];
    // Walk from the end so we get most-recent-first.
    for (var i = parts.length - 1; i >= 0 && out.length < max; i--) {
      final entry = _LogEntry.parse(parts[i]);
      if (entry != null) out.add(entry);
    }
    return out;
  }

  Future<void> _copyAll() async {
    final tail = _rawTail;
    if (tail == null || tail.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: tail));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text(
            'Copied last 5 conversion errors to clipboard',
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

  Future<void> _deleteLog() async {
    String? backup;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File(p.join(dir.path, 'conversion_error.log'));
      if (await file.exists()) {
        backup = await file.readAsString();
        await file.writeAsString('');
      }
    } catch (_) {
      // If we couldn't even read or clear, swallow — the empty-state
      // render below will tell the user the log's gone.
    }
    if (!mounted) return;
    setState(() {
      _entries = const [];
      _rawTail = null;
    });
    final restoreText = backup;
    showUndoSnackBar(
      context,
      label: 'Error log cleared',
      onUndo: () async {
        if (restoreText == null || restoreText.isEmpty) return;
        try {
          final dir = await getApplicationDocumentsDirectory();
          final file = File(p.join(dir.path, 'conversion_error.log'));
          await file.writeAsString(restoreText);
        } catch (_) {
          // Best-effort restore — if it fails the user can still see
          // future failures appended.
        }
        if (!mounted) return;
        await _load();
      },
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
              padding: EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Text(
                'Conversion errors (last 5)',
                style: TextStyle(
                  fontFamily: 'Montserrat',
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textOnDark,
                ),
              ),
            ),
            Flexible(
              child: _buildBody(),
            ),
            _buildActions(),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.primary,
            ),
          ),
        ),
      );
    }
    final entries = _entries ?? const [];
    if (entries.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'No conversion errors logged yet',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppColors.textOnDark,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Errors only land here after a real conversion failure '
              '— if a clip just looks "stuck", retry the failed pill '
              'first to surface a fresh error.',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 13,
                height: 1.4,
                color: AppColors.textSecondaryOnDark,
              ),
            ),
          ],
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      shrinkWrap: true,
      itemCount: entries.length,
      separatorBuilder: (context, index) => const SizedBox(height: 12),
      itemBuilder: (_, i) => _EntryCard(entry: entries[i]),
    );
  }

  Widget _buildActions() {
    final hasContent = (_entries ?? const []).isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: hasContent ? _copyAll : null,
              icon: const Icon(Icons.copy_all_rounded, size: 18),
              label: const Text('Copy all'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.primary,
                side: BorderSide(
                  color: hasContent
                      ? AppColors.primary.withValues(alpha: 0.6)
                      : AppColors.surfaceBorder,
                ),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: hasContent ? _deleteLog : null,
              icon: const Icon(Icons.delete_outline_rounded, size: 18),
              label: const Text('Delete log'),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFFEF4444),
                side: BorderSide(
                  color: hasContent
                      ? const Color(0xFFEF4444).withValues(alpha: 0.6)
                      : AppColors.surfaceBorder,
                ),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LogEntry {
  final DateTime? timestamp;
  final String? exerciseId;
  final String? rawFilePath;
  final String error;
  final String stack;
  final String raw;

  const _LogEntry({
    required this.timestamp,
    required this.exerciseId,
    required this.rawFilePath,
    required this.error,
    required this.stack,
    required this.raw,
  });

  /// Parse one entry chunk. Tolerant of malformed entries — anything
  /// that can't be parsed cleanly returns null and gets skipped.
  static _LogEntry? parse(String chunk) {
    final lines = chunk.split('\n');
    if (lines.isEmpty) return null;
    DateTime? ts;
    String? exerciseId;
    String? rawFilePath;
    final errorLines = <String>[];
    final stackLines = <String>[];
    var section = _Section.preamble;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (i == 0) {
        ts = DateTime.tryParse(line.trim());
        continue;
      }
      if (line.startsWith('Exercise: ')) {
        exerciseId = line.substring('Exercise: '.length).trim();
        continue;
      }
      if (line.startsWith('Raw file: ')) {
        rawFilePath = line.substring('Raw file: '.length).trim();
        continue;
      }
      if (line.startsWith('Error: ')) {
        section = _Section.error;
        errorLines.add(line.substring('Error: '.length));
        continue;
      }
      if (line.trim() == 'Stack:') {
        section = _Section.stack;
        continue;
      }
      switch (section) {
        case _Section.error:
          errorLines.add(line);
          break;
        case _Section.stack:
          stackLines.add(line);
          break;
        case _Section.preamble:
          break;
      }
    }
    return _LogEntry(
      timestamp: ts,
      exerciseId: exerciseId,
      rawFilePath: rawFilePath,
      error: errorLines.join('\n').trim(),
      stack: stackLines.join('\n').trim(),
      raw: chunk,
    );
  }
}

enum _Section { preamble, error, stack }

class _EntryCard extends StatelessWidget {
  final _LogEntry entry;

  const _EntryCard({required this.entry});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
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
              Expanded(
                child: Text(
                  _relativeOrAbsolute(entry.timestamp),
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textOnDark,
                  ),
                ),
              ),
              if (entry.exerciseId != null)
                Text(
                  '${_truncate(entry.exerciseId!, 8)}…',
                  style: const TextStyle(
                    fontFamily: 'Menlo',
                    fontSize: 11,
                    color: AppColors.textSecondaryOnDark,
                  ),
                ),
            ],
          ),
          if (entry.rawFilePath != null) ...[
            const SizedBox(height: 6),
            Text(
              'Raw file: ${_relativisePath(entry.rawFilePath!)}',
              style: const TextStyle(
                fontFamily: 'Menlo',
                fontSize: 11,
                color: AppColors.textSecondaryOnDark,
              ),
            ),
          ],
          const SizedBox(height: 8),
          if (entry.error.isNotEmpty)
            SelectableText(
              'Error: ${entry.error}',
              style: const TextStyle(
                fontFamily: 'Menlo',
                fontSize: 12,
                height: 1.4,
                color: AppColors.primary,
              ),
            ),
          if (entry.stack.isNotEmpty)
            Theme(
              data: Theme.of(context).copyWith(
                dividerColor: Colors.transparent,
              ),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                iconColor: AppColors.textSecondaryOnDark,
                collapsedIconColor: AppColors.textSecondaryOnDark,
                title: const Text(
                  'Stack trace',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textSecondaryOnDark,
                  ),
                ),
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceRaised,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SelectableText(
                      entry.stack,
                      style: const TextStyle(
                        fontFamily: 'Menlo',
                        fontSize: 11,
                        height: 1.35,
                        color: AppColors.textSecondaryOnDark,
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

  static String _truncate(String s, int n) =>
      s.length <= n ? s : s.substring(0, n);

  /// Show file paths relative to `Documents/` so the sheet doesn't
  /// leak the per-install sandbox UUID.
  static String _relativisePath(String path) {
    final docsIdx = path.indexOf('/Documents/');
    if (docsIdx >= 0) return path.substring(docsIdx + 1);
    return path;
  }

  static String _relativeOrAbsolute(DateTime? ts) {
    if (ts == null) return 'Unknown time';
    final delta = DateTime.now().difference(ts);
    if (delta.inSeconds < 60) return '${delta.inSeconds}s ago';
    if (delta.inMinutes < 60) return '${delta.inMinutes} min ago';
    if (delta.inHours < 24) return '${delta.inHours}h ago';
    if (delta.inDays < 7) return '${delta.inDays}d ago';
    // Fallback to absolute (local time).
    final local = ts.toLocal();
    final y = local.year.toString();
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '$y-$m-$d $hh:$mm';
  }
}
