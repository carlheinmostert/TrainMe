import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/api_client.dart';
import '../services/upload_service.dart';
import '../theme.dart';

/// Which CTA the practitioner tapped in the unconsented-treatments
/// bottom-sheet. Returned from [showUnconsentedTreatmentsSheet].
///
///   * [grantAndPublish] — flip the missing consent flags on the
///     client + retry the publish.
///   * [backToStudio] — dismiss the sheet; practitioner will edit per-
///     exercise preferences manually.
///   * [dismissed] — sheet was swiped down / barrier-tapped without a
///     CTA selection. Same terminal state as [backToStudio] but gives
///     the caller a distinct signal if it needs one (telemetry).
enum UnconsentedTreatmentsAction { grantAndPublish, backToStudio, dismissed }

/// Bottom-sheet shown when [UploadService.uploadPlan] rejects a publish
/// because the linked client hasn't consented to every treatment the
/// practitioner requested per-exercise.
///
/// Voice: peer-to-peer, no "consent/legal/POPIA" language. Matches the
/// existing [client_consent_sheet.dart] conventions:
///   - Coral CTAs, dark surface.
///   - "hasn't consented" in the copy is OK here — the practitioner is
///     the audience, and the alternative phrasing loses the intent.
///
/// R-01 compliance: this is NOT a confirmation modal. It's a
/// block-with-options sheet — there's a destructive action in Studio
/// that *could* be edited to match consent, or a single-tap rescue
/// that flips the flags on the client (already a destructive-like
/// action the client could do from their own UI later).
///
/// Used by [ClientSessionsScreen._publishSession].
class UnconsentedTreatmentsSheet extends StatefulWidget {
  /// The exception carrying the violations + client name.
  final UnconsentedTreatmentsException exception;

  /// The client id to patch via `set_client_video_consent` when the
  /// practitioner taps "Grant consent & publish". Kept separate from
  /// [exception] because the exception itself is safe to pass through
  /// multiple layers without leaking the id.
  final String clientId;

  /// Whether grayscale is currently allowed on the client. Used to
  /// compute the target consent payload when granting — we flip
  /// whatever is currently false to true, without touching the other
  /// treatments.
  final bool currentGrayscaleAllowed;

  /// Whether original-colour is currently allowed on the client.
  final bool currentColourAllowed;

  /// API client. Injected so tests can stub it out; defaults to the
  /// singleton in production.
  final ApiClient api;

  UnconsentedTreatmentsSheet({
    super.key,
    required this.exception,
    required this.clientId,
    required this.currentGrayscaleAllowed,
    required this.currentColourAllowed,
    ApiClient? api,
  }) : api = api ?? ApiClient.instance;

  @override
  State<UnconsentedTreatmentsSheet> createState() =>
      _UnconsentedTreatmentsSheetState();
}

class _UnconsentedTreatmentsSheetState
    extends State<UnconsentedTreatmentsSheet> {
  bool _granting = false;

  /// Group the violations by consent_key and return the counts. Keeps
  /// the mapping order stable (grayscale first, then original) so the
  /// list renders identically across runs.
  List<MapEntry<String, int>> get _grouped {
    final counts = <String, int>{};
    for (final v in widget.exception.violations) {
      counts.update(v.consentKey, (c) => c + 1, ifAbsent: () => 1);
    }
    // Stable render order: grayscale first, original second, everything
    // else (defensive — only ever 'line_drawing' in future) last.
    const order = ['grayscale', 'original', 'line_drawing'];
    final entries = counts.entries.toList();
    entries.sort((a, b) {
      final ai = order.indexOf(a.key);
      final bi = order.indexOf(b.key);
      if (ai == -1 && bi == -1) return a.key.compareTo(b.key);
      if (ai == -1) return 1;
      if (bi == -1) return -1;
      return ai.compareTo(bi);
    });
    return entries;
  }

  /// Human-readable label for a consent key. Matches the
  /// [ClientConsentSheet] copy ("Black & white" / "Original colour")
  /// so the practitioner sees consistent terminology across both
  /// sheets.
  String _labelFor(String consentKey) {
    switch (consentKey) {
      case 'grayscale':
        return 'Black & white';
      case 'original':
        return 'Original colour';
      case 'line_drawing':
        return 'Line drawing';
      default:
        return consentKey;
    }
  }

  String _pluralise(int n, String singular, String plural) =>
      n == 1 ? singular : plural;

  Future<void> _grantAndPublish() async {
    if (_granting) return;
    setState(() => _granting = true);
    HapticFeedback.selectionClick();

    // Compute the target consent payload. Flip ONLY the keys that the
    // violations list actually references, leaving the others alone.
    // This preserves any treatment the practitioner deliberately
    // turned off for unrelated reasons.
    final wantedKeys = widget.exception.violations
        .map((v) => v.consentKey)
        .toSet();
    final nextGrayscale = widget.currentGrayscaleAllowed ||
        wantedKeys.contains('grayscale');
    final nextColour =
        widget.currentColourAllowed || wantedKeys.contains('original');

    final ok = await widget.api.setClientVideoConsent(
      clientId: widget.clientId,
      lineAllowed: true,
      grayscaleAllowed: nextGrayscale,
      colourAllowed: nextColour,
    );

    if (!mounted) return;
    setState(() => _granting = false);

    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Couldn't update consent — try again."),
        ),
      );
      return;
    }

    Navigator.of(context).pop(UnconsentedTreatmentsAction.grantAndPublish);
  }

  void _backToStudio() {
    HapticFeedback.selectionClick();
    Navigator.of(context).pop(UnconsentedTreatmentsAction.backToStudio);
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.exception.clientName.isEmpty
        ? 'Your client'
        : widget.exception.clientName;
    return SafeArea(
      top: false,
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
            const Text(
              "CLIENT HASN'T CONSENTED TO ALL TREATMENTS",
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              "$name hasn't consented to:",
              style: const TextStyle(
                fontFamily: 'Montserrat',
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppColors.textOnDark,
                letterSpacing: -0.2,
              ),
            ),
            const SizedBox(height: 12),
            ..._grouped.map((entry) {
              final count = entry.value;
              final label = _labelFor(entry.key);
              final exerciseWord = _pluralise(count, 'exercise', 'exercises');
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 2, right: 10),
                      child: Icon(
                        Icons.circle,
                        size: 6,
                        color: AppColors.textSecondaryOnDark,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        '$label ($count $exerciseWord)',
                        style: const TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: AppColors.textOnDark,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }),
            const SizedBox(height: 14),
            const Text(
              'The video will fall back to line-drawing for any '
              'unconsented treatment.',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 13,
                color: AppColors.textSecondaryOnDark,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 22),
            FilledButton(
              onPressed: _granting ? null : _grantAndPublish,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                ),
              ),
              child: _granting
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
                      'Grant consent & publish',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _granting ? null : _backToStudio,
              style: TextButton.styleFrom(
                foregroundColor: AppColors.textOnDark,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                ),
              ),
              child: const Text(
                'Back to Studio',
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
    );
  }
}

/// Show the unconsented-treatments bottom-sheet. Resolves to the
/// [UnconsentedTreatmentsAction] the practitioner selected. A swipe-
/// down or barrier-tap resolves to
/// [UnconsentedTreatmentsAction.dismissed].
Future<UnconsentedTreatmentsAction> showUnconsentedTreatmentsSheet(
  BuildContext context, {
  required UnconsentedTreatmentsException exception,
  required String clientId,
  required bool currentGrayscaleAllowed,
  required bool currentColourAllowed,
  ApiClient? api,
}) async {
  final result = await showModalBottomSheet<UnconsentedTreatmentsAction>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surfaceBase,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => UnconsentedTreatmentsSheet(
      exception: exception,
      clientId: clientId,
      currentGrayscaleAllowed: currentGrayscaleAllowed,
      currentColourAllowed: currentColourAllowed,
      api: api,
    ),
  );
  return result ?? UnconsentedTreatmentsAction.dismissed;
}
