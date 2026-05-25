import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../models/exercise_capture.dart';
import '../services/clipboard_service.dart';
import '../services/path_resolver.dart';
import '../theme.dart';

/// Outcome of the paste bottom sheet. Returned through
/// `Navigator.pop(context, PasteSheetResult.confirmed(ids))` so the
/// caller can branch on the user's intent without re-reading the
/// clipboard.
class PasteSheetResult {
  /// Item ids the practitioner has selected for paste, in the FIFO
  /// order they were copied (oldest-first). Empty when the sheet was
  /// dismissed without pressing the CTA. Non-null and non-empty when
  /// the practitioner explicitly committed.
  final List<String> selectedItemIds;

  /// True when the practitioner is asking Studio to run the integrated
  /// unlock-then-paste flow (E2) because the current session is past
  /// the 14-day structural-edit grace. The Studio screen handles the
  /// branch — the sheet just signals the intent.
  final bool wantsUnlock;

  const PasteSheetResult._({
    required this.selectedItemIds,
    required this.wantsUnlock,
  });

  /// Practitioner backed out without confirming.
  static const PasteSheetResult cancelled = PasteSheetResult._(
    selectedItemIds: <String>[],
    wantsUnlock: false,
  );

  /// Practitioner confirmed and the session is not locked — Studio
  /// should run the paste path immediately.
  factory PasteSheetResult.confirmed(List<String> ids) => PasteSheetResult._(
        selectedItemIds: ids,
        wantsUnlock: false,
      );

  /// Practitioner confirmed against a locked session — Studio should
  /// first surface the existing 1-credit unlock sheet, and on success
  /// proceed with the paste using these ids.
  factory PasteSheetResult.confirmedAfterUnlock(List<String> ids) =>
      PasteSheetResult._(
        selectedItemIds: ids,
        wantsUnlock: true,
      );

  bool get isCancelled => selectedItemIds.isEmpty && !wantsUnlock;
}

/// Show the Exercise Clipboard paste bottom sheet
/// (`docs/specs/2026-05-25-exercise-clipboard.md`, D7).
///
/// Renders one row per [ClipboardItem], all selected by default. Tap a
/// row to toggle. The primary CTA reads `Paste N items` and updates
/// live; when [isTargetLocked] is true the CTA flips to
/// `🔒 Unlock to paste · 1 credit` per E2 and the sheet returns a
/// [PasteSheetResult.confirmedAfterUnlock] so Studio can interleave the
/// existing 1-credit unlock flow.
///
/// Reactive pruning: the sheet subscribes to [ClipboardService] and
/// drops rows mid-display when E1's deletion stream notifies. If
/// pruning empties the list, the sheet auto-dismisses with
/// [PasteSheetResult.cancelled].
Future<PasteSheetResult> showPasteBottomSheet(
  BuildContext context, {
  required bool isTargetLocked,
}) async {
  final result = await showModalBottomSheet<PasteSheetResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.45),
    builder: (sheetCtx) => _PasteSheet(
      isTargetLocked: isTargetLocked,
    ),
  );
  return result ?? PasteSheetResult.cancelled;
}

class _PasteSheet extends StatefulWidget {
  final bool isTargetLocked;

  const _PasteSheet({required this.isTargetLocked});

  @override
  State<_PasteSheet> createState() => _PasteSheetState();
}

class _PasteSheetState extends State<_PasteSheet> {
  /// Set of clipboard-item ids currently selected. Mutates on row tap.
  /// Initialised to "all" in [initState] (D7 — default-all-selected).
  late Set<String> _selectedIds;

  @override
  void initState() {
    super.initState();
    final items = ClipboardService.instance.items;
    _selectedIds = items.map((i) => i.id).toSet();
    ClipboardService.instance.addListener(_onClipboardChange);
  }

  @override
  void dispose() {
    ClipboardService.instance.removeListener(_onClipboardChange);
    super.dispose();
  }

  void _onClipboardChange() {
    if (!mounted) return;
    // Prune selection set when items disappear (reactive pruning per
    // E1). New items aren't auto-selected mid-sheet — re-opening picks
    // them up via the default-all-selected initState seed.
    final liveIds =
        ClipboardService.instance.items.map((i) => i.id).toSet();
    final next = _selectedIds.intersection(liveIds);
    if (ClipboardService.instance.items.isEmpty) {
      // E1 sheet edge — clipboard emptied while open. Pop with
      // cancelled outcome so Studio doesn't try to paste nothing.
      Navigator.of(context).pop(PasteSheetResult.cancelled);
      return;
    }
    setState(() {
      _selectedIds = next;
    });
  }

  void _toggle(String itemId) {
    setState(() {
      if (_selectedIds.contains(itemId)) {
        _selectedIds.remove(itemId);
      } else {
        _selectedIds.add(itemId);
      }
    });
  }

  void _clearAll() {
    ClipboardService.instance.clearAll();
    // Service listener will dispatch the empty-clipboard pop.
  }

  void _commit() {
    final orderedIds = ClipboardService.instance.items
        .where((i) => _selectedIds.contains(i.id))
        .map((i) => i.id)
        .toList(growable: false);
    if (orderedIds.isEmpty) return;
    Navigator.of(context).pop(
      widget.isTargetLocked
          ? PasteSheetResult.confirmedAfterUnlock(orderedIds)
          : PasteSheetResult.confirmed(orderedIds),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = ClipboardService.instance.items;
    final maxHeight = MediaQuery.of(context).size.height * 0.70;
    final viewInsetBottom = MediaQuery.of(context).viewInsets.bottom;
    final viewPaddingBottom = MediaQuery.of(context).viewPadding.bottom;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.surfaceBase,
          border: Border(
            top: BorderSide(color: AppColors.surfaceBorder, width: 1),
          ),
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        padding: EdgeInsets.only(bottom: viewInsetBottom + viewPaddingBottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                itemCount: items.length,
                separatorBuilder: (_, _) => const SizedBox(height: 6),
                itemBuilder: (_, i) => _PasteRow(
                  item: items[i],
                  selected: _selectedIds.contains(items[i].id),
                  onTap: () => _toggle(items[i].id),
                ),
              ),
            ),
            _buildCtaRow(items),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              'Paste from clipboard',
              style: TextStyle(
                fontFamily: 'Montserrat',
                fontWeight: FontWeight.w700,
                fontSize: 15,
                color: AppColors.textOnDark,
                letterSpacing: -0.2,
              ),
            ),
          ),
          TextButton.icon(
            onPressed: _clearAll,
            icon: const Icon(
              Icons.close,
              size: 14,
              color: AppColors.textSecondaryOnDark,
            ),
            label: const Text(
              'Clear all',
              style: TextStyle(
                fontFamily: 'Inter',
                fontWeight: FontWeight.w600,
                fontSize: 12,
                color: AppColors.textSecondaryOnDark,
              ),
            ),
            style: TextButton.styleFrom(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              minimumSize: const Size(0, 28),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCtaRow(List<ClipboardItem> items) {
    final selectedCount = _selectedIds.length;
    final canCommit = selectedCount > 0;
    return Container(
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: AppColors.surfaceBorder, width: 1),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: SizedBox(
        width: double.infinity,
        child: widget.isTargetLocked
            ? _LockedCta(
                onPressed: canCommit ? _commit : null,
                count: selectedCount,
              )
            : _NormalCta(
                onPressed: canCommit ? _commit : null,
                count: selectedCount,
              ),
      ),
    );
  }
}

class _NormalCta extends StatelessWidget {
  final VoidCallback? onPressed;
  final int count;

  const _NormalCta({required this.onPressed, required this.count});

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        disabledBackgroundColor: AppColors.primary.withValues(alpha: 0.38),
        disabledForegroundColor: Colors.white.withValues(alpha: 0.65),
        padding: const EdgeInsets.symmetric(vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
        elevation: 0,
      ),
      child: Text(
        count == 1 ? 'Paste 1 item' : 'Paste $count items',
        style: const TextStyle(
          fontFamily: 'Montserrat',
          fontWeight: FontWeight.w700,
          fontSize: 14,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

class _LockedCta extends StatelessWidget {
  final VoidCallback? onPressed;
  final int count;

  const _LockedCta({required this.onPressed, required this.count});

  @override
  Widget build(BuildContext context) {
    return ElevatedButton.icon(
      onPressed: onPressed,
      icon: const Icon(Icons.lock_outline, size: 16),
      label: Text(
        count == 1
            ? 'Unlock to paste 1 item · 1 credit'
            : 'Unlock to paste $count items · 1 credit',
        style: const TextStyle(
          fontFamily: 'Montserrat',
          fontWeight: FontWeight.w700,
          fontSize: 13,
          letterSpacing: 0.3,
        ),
      ),
      style: ElevatedButton.styleFrom(
        // Per the mockup's "locked" CTA — surface-raised background +
        // coral foreground + dashed coral border. ElevatedButton doesn't
        // natively render dashed borders so we fall back to a solid 1px
        // coral border at 30% alpha (the mockup token is
        // brand-tint-border).
        backgroundColor: AppColors.surfaceRaised,
        foregroundColor: AppColors.primary,
        disabledBackgroundColor: AppColors.surfaceRaised,
        disabledForegroundColor: AppColors.primary.withValues(alpha: 0.45),
        padding: const EdgeInsets.symmetric(vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: AppColors.primary.withValues(alpha: 0.30),
            width: 1,
          ),
        ),
        elevation: 0,
      ),
    );
  }
}

class _PasteRow extends StatelessWidget {
  final ClipboardItem item;
  final bool selected;
  final VoidCallback onTap;

  const _PasteRow({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final mediaTypeLabel = item.displayMediaType == MediaType.video
        ? 'VIDEO'
        : item.displayMediaType == MediaType.photo
            ? 'PHOTO'
            : 'REST';
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 120),
          opacity: selected ? 1.0 : 0.45,
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.surfaceRaised,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                _CheckGlyph(selected: selected),
                const SizedBox(width: 12),
                _RowThumbnail(item: item),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        item.displayName?.trim().isNotEmpty == true
                            ? item.displayName!
                            : 'Untitled exercise',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'Montserrat',
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                          color: AppColors.textOnDark,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        '$mediaTypeLabel · ${_formatCopiedAt(item.copiedAt)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 11,
                          color: AppColors.textSecondaryOnDark,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CheckGlyph extends StatelessWidget {
  final bool selected;
  const _CheckGlyph({required this.selected});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: selected ? AppColors.primary : Colors.transparent,
        border: Border.all(
          color: selected ? AppColors.primary : AppColors.surfaceBorder,
          width: 1.5,
        ),
        shape: BoxShape.circle,
      ),
      child: selected
          ? const Icon(Icons.check, size: 14, color: Colors.white)
          : const SizedBox.shrink(),
    );
  }
}

class _RowThumbnail extends StatelessWidget {
  final ClipboardItem item;
  const _RowThumbnail({required this.item});

  @override
  Widget build(BuildContext context) {
    final relPath = item.displayThumbPath;
    Widget child;
    if (relPath != null && relPath.isNotEmpty) {
      final file = File(PathResolver.resolve(relPath));
      if (file.existsSync()) {
        child = Image.file(
          file,
          width: 44,
          height: 44,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _placeholder(item),
        );
      } else {
        child = _placeholder(item);
      }
    } else {
      child = _placeholder(item);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(width: 44, height: 44, child: child),
    );
  }

  Widget _placeholder(ClipboardItem item) {
    final icon = item.displayMediaType == MediaType.video
        ? Icons.videocam_outlined
        : item.displayMediaType == MediaType.photo
            ? Icons.image_outlined
            : Icons.bedtime_outlined;
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF2A2D3A), Color(0xFF1F222D)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Icon(
        icon,
        size: 20,
        color: AppColors.textSecondaryOnDark.withValues(alpha: 0.6),
      ),
    );
  }
}

String _formatCopiedAt(DateTime copiedAt) {
  final now = DateTime.now();
  final diff = now.difference(copiedAt);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays < 7) return '${diff.inDays}d ago';
  return '${copiedAt.day} ${_monthAbbr(copiedAt.month)}';
}

String _monthAbbr(int month) {
  const abbrs = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return abbrs[(month - 1).clamp(0, 11)];
}
