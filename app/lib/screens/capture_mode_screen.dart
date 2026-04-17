import 'package:flutter/material.dart';
import '../models/session.dart';
import '../services/local_storage_service.dart';
import '../theme.dart';

/// In-session camera mode — stub. Real implementation lands in the
/// next commit.
class CaptureModeScreen extends StatelessWidget {
  final Session session;
  final LocalStorageService storage;
  final Future<void> Function() onCapturesChanged;
  final VoidCallback onExitToStudio;

  const CaptureModeScreen({
    super.key,
    required this.session,
    required this.storage,
    required this.onCapturesChanged,
    required this.onExitToStudio,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      child: const Center(
        child: Text(
          'Capture mode (WIP)',
          style: TextStyle(color: AppColors.textOnDark),
        ),
      ),
    );
  }
}
