import 'package:flutter/material.dart';
import '../theme.dart';

/// Brand-standard "destructive action fired · Undo" snackbar.
///
/// Enforces R-01 (no modal confirmations for destructive actions): fire
/// immediately, give the practitioner a 5-second window to undo via a
/// SnackBarAction, then auto-dismiss.
///
/// Usage:
/// ```dart
/// showUndoSnackBar(
///   context,
///   label: 'Exercise deleted',
///   onUndo: () => _restoreExercise(removed),
/// );
/// ```
void showUndoSnackBar(
  BuildContext context, {
  required String label,
  required VoidCallback onUndo,
  Duration duration = const Duration(seconds: 5),
}) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.clearSnackBars();
  messenger.showSnackBar(
    SnackBar(
      content: Text(
        label,
        style: const TextStyle(
          fontFamily: 'Inter',
          fontSize: 14,
          color: AppColors.textOnDark,
        ),
      ),
      backgroundColor: AppColors.surfaceRaised,
      behavior: SnackBarBehavior.floating,
      duration: duration,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.surfaceBorder),
      ),
      action: SnackBarAction(
        label: 'Undo',
        textColor: AppColors.primary,
        onPressed: onUndo,
      ),
    ),
  );
}

/// Inline tooltip-toast surfaced when a credit-costing affordance is tapped
/// while the plan is in its post-lock window. Purely informational; no undo.
void showPublishLockToast(BuildContext context) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.clearSnackBars();
  messenger.showSnackBar(
    SnackBar(
      content: const Text(
        'This counts as a new version · 1 credit.',
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
