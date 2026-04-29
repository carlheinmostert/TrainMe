import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/client.dart';
import '../services/sync_service.dart';
import '../theme.dart';

/// Bottom sheet where the practitioner captures the client's viewing
/// preferences (line drawing / grayscale / original colour) and the
/// Wave 30 avatar-storage opt-in.
///
/// Voice: peer-to-peer. No "consent" / "legal" / "POPIA" / "withdraw"
/// language — see docs/design/project/voice.md. The client's choice is
/// framed as "what can {Name} see as" rather than "has {Name} consented".
///
/// Line drawing is the platform baseline and always on; the row renders
/// disabled so the practitioner knows there's nothing to decide there.
///
/// Layout: grouped sections (Wave 3). "Video treatment" holds the three
/// playback toggles; "Profile" (Wave 30) holds the avatar toggle so it
/// reads as a different category — it controls capture/storage, not
/// playback. [highlightAvatar] lights the avatar row with a coral border
/// + brief animation when the sheet opens via the avatar slot tap, so
/// the practitioner immediately sees what they need to flip.
///
/// Opens via [showClientConsentSheet].
class ClientConsentSheet extends StatefulWidget {
  final PracticeClient client;

  /// When true, the avatar row gets a coral pulse on first frame so the
  /// practitioner sees what they need to enable. Used when the sheet was
  /// triggered by tapping a locked avatar slot.
  final bool highlightAvatar;

  /// Fires after a successful save with the updated client. Used by the
  /// Your-clients screen to refresh its list without a round-trip.
  final ValueChanged<PracticeClient>? onSaved;

  const ClientConsentSheet({
    super.key,
    required this.client,
    this.highlightAvatar = false,
    this.onSaved,
  });

  @override
  State<ClientConsentSheet> createState() => _ClientConsentSheetState();
}

class _ClientConsentSheetState extends State<ClientConsentSheet> {
  late bool _grayscaleAllowed;
  late bool _colourAllowed;
  late bool _avatarAllowed;
  late bool _analyticsAllowed;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _grayscaleAllowed = widget.client.grayscaleAllowed;
    _colourAllowed = widget.client.colourAllowed;
    _avatarAllowed = widget.client.avatarAllowed;
    _analyticsAllowed = widget.client.analyticsAllowed;
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
        avatarAllowed: _avatarAllowed,
        analyticsAllowed: _analyticsAllowed,
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
        avatarAllowed: _avatarAllowed,
        analyticsAllowed: _analyticsAllowed,
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
    // Cap the sheet at 90% of screen height so it grows with content but
    // never fills the entire screen — leaves the tap-to-dismiss target
    // along the top edge intact when content is short.
    final maxHeight = MediaQuery.of(context).size.height * 0.9;
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            // Pinned drag handle (top) + scrollable consent sections
            // (middle) + pinned Save button (bottom). Without this the
            // Save button gets pushed off-screen on smaller iPhones once
            // the analytics section (Wave 17) was added.
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
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
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
                        _sectionHeader('Video treatment'),
                        const SizedBox(height: 4),
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
                        const SizedBox(height: 20),
                        _sectionHeader('Profile'),
                        const SizedBox(height: 4),
                        _row(
                          icon: Icons.account_circle_outlined,
                          title: 'Avatar still',
                          subtitle:
                              'Single capture with the background blurred — replaces '
                              'the initials circle on this client.',
                          value: _avatarAllowed,
                          onChanged: (v) => setState(() => _avatarAllowed = v),
                          highlight: widget.highlightAvatar,
                        ),
                        const SizedBox(height: 20),
                        _sectionHeader('Analytics'),
                        const SizedBox(height: 4),
                        _row(
                          icon: Icons.bar_chart_rounded,
                          title: 'Anonymous usage analytics',
                          subtitle:
                              'Track which exercises are completed or skipped '
                              '— helps you refine plans.',
                          value: _analyticsAllowed,
                          onChanged: (v) => setState(() => _analyticsAllowed = v),
                        ),
                        // Future consent groups slot in above this line —
                        // e.g. outcome-tracking, data sharing, reminder
                        // messaging. Each new group: _sectionHeader('<title>')
                        // + its rows, preceded by a SizedBox(height: 20)
                        // spacer. The scrollable middle absorbs additional
                        // content; the Save button stays pinned below.
                      ],
                    ),
                  ),
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
      ),
    );
  }

  /// Small section header for the sheet's grouped layout. Use for every
  /// consent category — "Video treatment" today, outcome-tracking /
  /// reminders tomorrow. Typography matches the app's other group
  /// labels (uppercase Inter 11, coral-tinged text-secondary).
  Widget _sectionHeader(String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Text(
        label.toUpperCase(),
        style: const TextStyle(
          fontFamily: 'Inter',
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
          color: AppColors.textSecondaryOnDark,
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
    bool highlight = false,
  }) {
    final disabled = onChanged == null;
    final padded = Padding(
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
    if (!highlight) return padded;
    // Coral-tinted card to draw the eye when the sheet was opened from
    // a locked avatar slot. No animation — the practitioner just clicked
    // the slot, the row appearing already-emphasised is enough.
    return Container(
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(
          color: AppColors.primary.withValues(alpha: 0.45),
          width: 1.2,
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: padded,
    );
  }
}

/// Show the client-consent bottom sheet. Resolves to the updated
/// [PracticeClient] when the practitioner saves, or null when they
/// dismiss it.
///
/// [highlightAvatar] (Wave 30) — pass true when the sheet is being
/// opened because the practitioner tapped a locked avatar slot, so the
/// avatar row in the Profile group renders with a coral border to point
/// at the toggle they need.
Future<PracticeClient?> showClientConsentSheet(
  BuildContext context, {
  required PracticeClient client,
  bool highlightAvatar = false,
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
      highlightAvatar: highlightAvatar,
      onSaved: onSaved,
    ),
  );
}
