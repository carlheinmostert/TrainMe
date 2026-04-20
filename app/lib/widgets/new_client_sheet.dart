import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/sync_service.dart';
import '../theme.dart';

/// Bottom sheet for minting a new client from the Clients-as-Home spine.
///
/// Scope is deliberately minimal: one text field (client name), one
/// Save button. Default consent is line-drawing only — the practitioner
/// configures grayscale / original later via [`ClientConsentSheet`] on
/// the per-client page. This matches Carl's decision #2: "New-Client
/// sheet asks for name only."
///
/// Resolves to the newly created client's id on success, or null if
/// the practitioner dismisses without saving.
///
/// R-01: no confirmation modal — the Save button is the commit.
/// R-06 voice: peer-to-peer; no "consent" language here.
class NewClientSheet extends StatefulWidget {
  /// Practice the client belongs to. Reads from
  /// `AuthService.instance.currentPracticeId` at call-site and is
  /// passed in so this sheet stays pure-widget + easily testable.
  final String practiceId;

  const NewClientSheet({super.key, required this.practiceId});

  @override
  State<NewClientSheet> createState() => _NewClientSheetState();
}

class _NewClientSheetState extends State<NewClientSheet> {
  final TextEditingController _controller = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    HapticFeedback.selectionClick();
    setState(() {
      _saving = true;
      _error = null;
    });

    // Offline-first: write the client to the local cache + enqueue
    // the cloud upsert, then pop immediately. The UI doesn't wait on
    // the network — a slow or absent connection becomes invisible to
    // the practitioner.
    try {
      final cached = await SyncService.instance.queueCreateClient(
        practiceId: widget.practiceId,
        name: name,
      );
      if (!mounted) return;
      Navigator.of(context).pop(
        NewClientResult(id: cached.id, name: cached.name),
      );
    } catch (e) {
      // The cache write itself errored (e.g. UNIQUE(practice_id,name)
      // collision from a previously-created local row). Surface the
      // duplicate inline; for other shapes fall back to generic retry
      // copy.
      if (!mounted) return;
      final msg = e.toString();
      final isDuplicate =
          msg.contains('UNIQUE') || msg.contains('unique') || msg.contains('2067');
      setState(() {
        _saving = false;
        _error = isDuplicate
            ? 'A client with that name already exists.'
            : "Couldn't create — tap to retry";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final trimmed = _controller.text.trim();
    final canSave = !_saving && trimmed.isNotEmpty;

    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Drag handle.
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 18),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceBorder,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const Text(
                'New client',
                style: TextStyle(
                  fontFamily: 'Montserrat',
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textOnDark,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Just the name for now. You can set what they see '
                '(black & white, colour) on their page.',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 13,
                  color: AppColors.textSecondaryOnDark,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _controller,
                autofocus: true,
                enabled: !_saving,
                maxLength: 80,
                textInputAction: TextInputAction.done,
                onChanged: (_) {
                  if (_error != null) {
                    setState(() => _error = null);
                  } else {
                    setState(() {}); // refresh Save enabled state.
                  }
                },
                onSubmitted: (_) {
                  if (canSave) _save();
                },
                style: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 15,
                  color: AppColors.textOnDark,
                ),
                decoration: InputDecoration(
                  labelText: 'Client name',
                  labelStyle: const TextStyle(
                    fontFamily: 'Inter',
                    color: AppColors.textSecondaryOnDark,
                  ),
                  counterText: '',
                  filled: true,
                  fillColor: AppColors.surfaceBg,
                  errorText: _error,
                  errorStyle: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 12,
                    color: AppColors.error,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                    borderSide: const BorderSide(
                      color: AppColors.surfaceBorder,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                    borderSide: const BorderSide(
                      color: AppColors.primary,
                      width: 1.4,
                    ),
                  ),
                  errorBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                    borderSide: const BorderSide(color: AppColors.error),
                  ),
                  focusedErrorBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                    borderSide: const BorderSide(
                      color: AppColors.error,
                      width: 1.4,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: canSave ? _save : null,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: AppColors.surfaceRaised,
                  disabledForegroundColor: AppColors.textSecondaryOnDark,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                  ),
                ),
                child: _saving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor:
                              AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      )
                    : const Text(
                        'Save',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Result of a successful save. Pops [showNewClientSheet] with both the
/// new id (so the caller can push the Client Sessions screen) and the
/// typed name (so the caller doesn't need a round-trip to rehydrate the
/// freshly-created row for display).
@immutable
class NewClientResult {
  final String id;
  final String name;

  const NewClientResult({required this.id, required this.name});
}

/// Show the new-client sheet. Resolves to a [NewClientResult] when the
/// practitioner saves, or null when they dismiss.
Future<NewClientResult?> showNewClientSheet(
  BuildContext context, {
  required String practiceId,
}) {
  return showModalBottomSheet<NewClientResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surfaceBase,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => NewClientSheet(practiceId: practiceId),
  );
}
