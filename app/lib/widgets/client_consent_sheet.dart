import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/client.dart';
import '../services/sync_service.dart';
import '../theme.dart';

/// Bottom sheet where the practitioner captures the client's viewing
/// preferences (line drawing / grayscale / original colour).
///
/// Voice: peer-to-peer. No "consent" / "legal" / "POPIA" / "withdraw"
/// language — see docs/design/project/voice.md. The client's choice is
/// framed as "what can {Name} see as" rather than "has {Name} consented".
///
/// Line drawing is the platform baseline and always on; the row renders
/// disabled so the practitioner knows there's nothing to decide there.
///
/// Opens via [showClientConsentSheet].
class ClientConsentSheet extends StatefulWidget {
  final PracticeClient client;

  /// Fires after a successful save with the updated client. Used by the
  /// Your-clients screen to refresh its list without a round-trip.
  final ValueChanged<PracticeClient>? onSaved;

  const ClientConsentSheet({
    super.key,
    required this.client,
    this.onSaved,
  });

  @override
  State<ClientConsentSheet> createState() => _ClientConsentSheetState();
}

class _ClientConsentSheetState extends State<ClientConsentSheet> {
  late bool _grayscaleAllowed;
  late bool _colourAllowed;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _grayscaleAllowed = widget.client.grayscaleAllowed;
    _colourAllowed = widget.client.colourAllowed;
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    HapticFeedback.selectionClick();

    // Offline-first: write to the local cache + enqueue. Returns
    // immediately even if the device has no network.
    try {
      final cached = await SyncService.instance.queueSetConsent(
        clientId: widget.client.id,
        grayscaleAllowed: _grayscaleAllowed,
        colourAllowed: _colourAllowed,
      );
      if (!mounted) return;
      if (cached == null) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Couldn't save right now — try again."),
          ),
        );
        return;
      }
      setState(() => _saving = false);
      final updated = widget.client.copyWith(
        grayscaleAllowed: _grayscaleAllowed,
        colourAllowed: _colourAllowed,
      );
      widget.onSaved?.call(updated);
      Navigator.of(context).pop(updated);
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Couldn't save right now — try again."),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.client.name.isEmpty ? 'your client' : widget.client.name;
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
              Text(
                'What can $name see as?',
                style: const TextStyle(
                  fontFamily: 'Montserrat',
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textOnDark,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Line drawing always works. Grayscale and colour are your '
                "client's call — ask once, toggle on.",
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 14,
                  color: AppColors.textSecondaryOnDark,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 20),
              _row(
                icon: Icons.brush_outlined,
                title: 'Line drawing',
                subtitle: 'Always available — de-identifies the client',
                value: true,
                onChanged: null,
              ),
              const Divider(height: 1, color: AppColors.surfaceBorder),
              _row(
                icon: Icons.filter_b_and_w_rounded,
                title: 'Black & white',
                subtitle: 'Real footage in grayscale',
                value: _grayscaleAllowed,
                onChanged: (v) => setState(() => _grayscaleAllowed = v),
              ),
              const Divider(height: 1, color: AppColors.surfaceBorder),
              _row(
                icon: Icons.videocam_outlined,
                title: 'Original colour',
                subtitle: 'Unmodified video',
                value: _colourAllowed,
                onChanged: (v) => setState(() => _colourAllowed = v),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _saving ? null : _save,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
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

  Widget _row({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    final disabled = onChanged == null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            icon,
            size: 24,
            color: disabled
                ? AppColors.textSecondaryOnDark
                : AppColors.primary,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: disabled
                        ? AppColors.textSecondaryOnDark
                        : AppColors.textOnDark,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 12,
                    color: AppColors.textSecondaryOnDark,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: Colors.white,
            activeTrackColor: AppColors.primary,
            inactiveThumbColor: AppColors.textSecondaryOnDark,
            inactiveTrackColor: AppColors.surfaceBorder,
          ),
        ],
      ),
    );
  }
}

/// Show the client-consent bottom sheet. Resolves to the updated
/// [PracticeClient] when the practitioner saves, or null when they
/// dismiss it.
Future<PracticeClient?> showClientConsentSheet(
  BuildContext context, {
  required PracticeClient client,
  ValueChanged<PracticeClient>? onSaved,
}) {
  return showModalBottomSheet<PracticeClient>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surfaceBase,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => ClientConsentSheet(
      client: client,
      onSaved: onSaved,
    ),
  );
}
