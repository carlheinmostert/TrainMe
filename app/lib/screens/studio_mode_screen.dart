import 'package:flutter/material.dart';
import '../models/session.dart';
import '../services/local_storage_service.dart';
import '../theme.dart';

/// Post-session editing mode — stub. Real implementation lands in the
/// next commit and is extracted wholesale from [SessionCaptureScreen].
class StudioModeScreen extends StatelessWidget {
  final Session session;
  final LocalStorageService storage;
  final ValueChanged<Session> onSessionChanged;
  final VoidCallback onOpenCapture;

  const StudioModeScreen({
    super.key,
    required this.session,
    required this.storage,
    required this.onSessionChanged,
    required this.onOpenCapture,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.darkBg,
      child: const Center(
        child: Text(
          'Studio mode (WIP)',
          style: TextStyle(color: AppColors.textOnDark),
        ),
      ),
    );
  }
}
