import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/api_client.dart';
import '../services/conversion_service.dart';
import '../services/face_embedding_service.dart';
import '../theme.dart';

/// Self-trainer wave PR #4 (2026-05-25) — POPIA consent bottom sheet.
///
/// Bottom sheet (NOT a modal — per R-01). Surfaces the consent prompt
/// for using the practitioner's Public profile selfie as the
/// self-verification reference image. On Yes:
///
///   1. Compute MobileFaceNet embedding from `selfiePath` via
///      [FaceEmbeddingService.computeForImage].
///   2. Call [ApiClient.registerSelfFace] with the embedding +
///      `DateTime.now().toUtc()` consent stamp.
///   3. Returns the Self-client uuid on success ([Outcome.registered]).
///
/// On Not now:
///   - Dismisses the sheet without computing or registering anything
///     ([Outcome.dismissed]).
///
/// On failure (no face found, native pipeline error, RPC error):
///   - Inline error text inside the sheet. Sheet stays open so the
///     practitioner can retry. Errors are surfaced verbatim per
///     `feedback_no_silent_fallbacks`.
///
/// Copy is **[carl-review:]** — the brief calls out POPIA wording as
/// load-bearing and Carl must bless before merge. The strings in this
/// file are the starting draft from `docs/sub-agent-briefs/04-self-trainer-consent.md`.
class SelfFaceConsentSheet extends StatefulWidget {
  /// Absolute path to the practitioner's existing selfie. The lazy
  /// backfill resolves this from the cached avatar; the inline-FAB
  /// trigger resolves it from the freshly-saved Public profile image.
  final String selfiePath;

  const SelfFaceConsentSheet({super.key, required this.selfiePath});

  /// Convenience launcher. Returns the [SelfFaceConsentOutcome] of the
  /// sheet — never null (a swipe-to-dismiss resolves to
  /// [SelfFaceConsentOutcome.dismissed]).
  static Future<SelfFaceConsentOutcome> show(
    BuildContext context, {
    required String selfiePath,
  }) async {
    final result = await showModalBottomSheet<SelfFaceConsentOutcome>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surfaceBase,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SelfFaceConsentSheet(selfiePath: selfiePath),
    );
    return result ?? const SelfFaceConsentOutcome.dismissed();
  }

  @override
  State<SelfFaceConsentSheet> createState() => _SelfFaceConsentSheetState();
}

class _SelfFaceConsentSheetState extends State<SelfFaceConsentSheet> {
  bool _busy = false;
  String? _error;

  Future<void> _onYes() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      // Defensive: bail early if the file vanished between the lazy
      // backfill scan and the user tapping Yes. The native channel
      // would throw a less-readable PlatformException downstream.
      if (!await File(widget.selfiePath).exists()) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _error =
              "We couldn't find your selfie file. "
              'Take a new one in Public profile, then try again.';
        });
        return;
      }

      final embedding = await FaceEmbeddingService.instance.computeForImage(
        widget.selfiePath,
      );

      if (embedding == null) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _error =
              "We couldn't find a clear face in your selfie. "
              'Try taking a new one in Public profile.';
        });
        return;
      }

      final selfClientId = await ApiClient.instance.registerSelfFace(
        embedding: embedding,
        consentedAt: DateTime.now().toUtc(),
      );

      // Reset the ConversionService's in-memory self-face embedding
      // cache so the next capture re-fetches via the RPC. Without this,
      // captures within the same app session compare against the stale
      // pre-registration cache (null → self_verified stays NULL).
      ConversionService.instance.resetSelfFaceEmbeddingCache();

      if (!mounted) return;
      Navigator.of(
        context,
      ).pop(SelfFaceConsentOutcome.registered(selfClientId: selfClientId));
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Face recognition failed: ${e.message ?? e.code}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = "Couldn't save: $e";
      });
    }
  }

  void _onNotNow() {
    if (_busy) return;
    Navigator.of(context).pop(const SelfFaceConsentOutcome.dismissed());
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Grabber to signal "this is a bottom sheet, not a modal".
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.surfaceBorder,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              // [carl-review:] — POPIA-sensitive copy. Starting draft from
              // docs/sub-agent-briefs/04-self-trainer-consent.md.
              const Text(
                'Use your photo for self-verification too?',
                style: TextStyle(
                  fontFamily: 'Montserrat',
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textOnDark,
                ),
              ),
              const SizedBox(height: 12),
              // [carl-review:] — POPIA wording. The "stays on this device
              // and in your homefit.studio account" sentence is the spot
              // a lawyer is most likely to red-pen (we ship the
              // embedding to Supabase, hosted on AWS — see Q14.2 in
              // SELF_TRAINER_WAVE.md).
              const Text(
                'This lets us recognise you in your own captures so '
                "they're free to publish. Your face data stays on this "
                'device and in your homefit.studio account; you can '
                'delete it anytime in Settings.',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 14,
                  height: 1.5,
                  color: AppColors.textSecondaryOnDark,
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.errorLight,
                    borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                    border: Border.all(color: AppColors.error),
                  ),
                  child: Text(
                    _error!,
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 13,
                      color: AppColors.error,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: _busy ? null : _onNotNow,
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(
                            AppTheme.radiusMd,
                          ),
                          side: const BorderSide(
                            color: AppColors.surfaceBorder,
                          ),
                        ),
                      ),
                      child: const Text(
                        // [carl-review:] — verbatim from brief.
                        'Not now',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textOnDark,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _busy ? null : _onYes,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: AppColors.surfaceRaised,
                        disabledForegroundColor: AppColors.textSecondaryOnDark,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(
                            AppTheme.radiusMd,
                          ),
                        ),
                      ),
                      child: _busy
                          ? const SizedBox(
                              height: 18,
                              width: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text(
                              // [carl-review:] — verbatim from brief.
                              'Yes, use it',
                              style: TextStyle(
                                fontFamily: 'Inter',
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Outcome of [SelfFaceConsentSheet.show]. Mutually exclusive — the
/// caller branches on the kind to decide next-step (proceed to FAB
/// session creation, dismiss without action, etc.).
@immutable
class SelfFaceConsentOutcome {
  /// `registered` = embedding computed + RPC succeeded.
  /// `dismissed`  = user tapped "Not now" or swiped to dismiss.
  final SelfFaceConsentOutcomeKind kind;

  /// Populated iff [kind] is [SelfFaceConsentOutcomeKind.registered]:
  /// the Self-client uuid returned by `register_self_face`.
  final String? selfClientId;

  const SelfFaceConsentOutcome.dismissed()
    : kind = SelfFaceConsentOutcomeKind.dismissed,
      selfClientId = null;

  const SelfFaceConsentOutcome.registered({required String this.selfClientId})
    : kind = SelfFaceConsentOutcomeKind.registered;

  bool get isRegistered => kind == SelfFaceConsentOutcomeKind.registered;
  bool get isDismissed => kind == SelfFaceConsentOutcomeKind.dismissed;
}

enum SelfFaceConsentOutcomeKind { registered, dismissed }
