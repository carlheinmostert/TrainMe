import 'package:flutter/material.dart';
import '../theme.dart';

/// A 44x44 reorder drag handle icon. Wraps [ReorderableDragStartListener]
/// at a thumb-friendly tap-target size used by every reorderable list row
/// in the app (exercise cards and rest bars).
class DragHandle extends StatelessWidget {
  final int index;

  const DragHandle({super.key, required this.index});

  @override
  Widget build(BuildContext context) {
    return ReorderableDragStartListener(
      index: index,
      child: const SizedBox(
        width: 44,
        height: 44,
        child: Center(
          child: Icon(
            Icons.drag_handle,
            color: AppColors.grey500,
            size: 24,
          ),
        ),
      ),
    );
  }
}
