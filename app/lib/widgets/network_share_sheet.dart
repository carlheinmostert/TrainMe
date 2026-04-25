import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../services/portal_links.dart';
import '../theme.dart';

/// Wave 30 — replaces the standalone `NetworkShareKitScreen` as the
/// canonical "share homefit.studio" surface on mobile.
///
/// Spawned from the Home top-left network icon as a draggable bottom
/// sheet. The mobile app keeps the share-kit (code + QR + share button +
/// portal hand-off); full network stats stay in the portal.
///
/// The sheet owns its own `_codeFuture`. Initial render seeds the future
/// from `ApiClient.ensureReferralCode` (which mints lazily server-side and
/// is idempotent). On error the FutureBuilder lands on a tappable retry
/// row instead of a silent infinite spinner — that was the failure mode
/// Carl flagged on the retired standalone screen.
class NetworkShareSheet extends StatefulWidget {
  const NetworkShareSheet({super.key});

  /// Show the sheet. Returns when the user dismisses.
  static Future<void> show(BuildContext context) {
    HapticFeedback.selectionClick();
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surfaceBase,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const NetworkShareSheet(),
    );
  }

  @override
  State<NetworkShareSheet> createState() => _NetworkShareSheetState();
}

class _NetworkShareSheetState extends State<NetworkShareSheet> {
  /// Future for the active practice's referral code. Re-seeded on retry.
  /// Null only when there's no active practice (rare — Home gates entry
  /// to the sheet on a non-null practice id, but defence-in-depth).
  Future<String>? _codeFuture;

  /// Active practice id captured at mount time. The sheet doesn't track
  /// switches — Home's chip enables/disables the sheet trigger based on
  /// practice membership; if the user switches mid-sheet, the next open
  /// re-seeds from the new id.
  String? _practiceId;

  @override
  void initState() {
    super.initState();
    _practiceId = AuthService.instance.currentPracticeId.value;
    _refresh();
  }

  void _refresh() {
    final practiceId = _practiceId;
    if (practiceId == null || practiceId.isEmpty) {
      setState(() => _codeFuture = null);
      return;
    }
    setState(() {
      _codeFuture = ApiClient.instance.ensureReferralCode(practiceId);
    });
  }

  String _referralUrl(String code) =>
      'https://manage.homefit.studio/r/$code';

  Future<void> _copyCode(String code) async {
    HapticFeedback.selectionClick();
    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: const Text(
            'Code copied',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 14,
              color: AppColors.textOnDark,
            ),
          ),
          backgroundColor: AppColors.surfaceRaised,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: AppColors.surfaceBorder),
          ),
        ),
      );
  }

  /// Open the system share sheet with the peer-to-peer template + URL.
  /// `sharePositionOrigin` is needed on iPad / simulator otherwise the
  /// sheet silently fails (R-08 gotcha).
  Future<void> _shareUrl(String code) async {
    HapticFeedback.selectionClick();
    final url = _referralUrl(code);
    final text = 'Try homefit.studio with my invite — $url';
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null
        ? Rect.zero
        : box.localToGlobal(Offset.zero) & box.size;
    try {
      await Share.share(text, sharePositionOrigin: origin);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text("Couldn't open share sheet: $e"),
            duration: const Duration(seconds: 3),
          ),
        );
    }
  }

  Future<void> _openPortalNetwork() async {
    HapticFeedback.selectionClick();
    final uri = portalLink('/network', practiceId: _practiceId);
    bool launched = false;
    try {
      launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      launched = false;
    }
    if (!launched && mounted) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text("Couldn't open the portal. Try again shortly."),
            duration: Duration(seconds: 3),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    // Sheet content lives inside a SafeArea so it respects the home-
    // indicator gutter on iPhones with no physical home button.
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 4),
            const Text(
              'Share with another practitioner',
              style: TextStyle(
                fontFamily: 'Montserrat',
                fontSize: 18,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.2,
                color: AppColors.textOnDark,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'They land with 8 free credits — you earn 5% in free credits '
              'on every plan they ever publish.',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 13,
                height: 1.45,
                color: AppColors.textSecondaryOnDark,
              ),
            ),
            const SizedBox(height: 18),
            _buildCodeAndQr(),
            const SizedBox(height: 16),
            _buildShareButton(),
            const SizedBox(height: 12),
            _buildPortalLink(),
          ],
        ),
      ),
    );
  }

  Widget _buildCodeAndQr() {
    if (_codeFuture == null) {
      // No practice — render a static error row. Should be rare since
      // Home gates the trigger on a live practice id.
      return _ErrorBlock(
        message: 'No practice selected. Pick one from Home and try again.',
        onRetry: null,
      );
    }
    return FutureBuilder<String>(
      future: _codeFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const _LoadingBlock();
        }
        if (snapshot.hasError || snapshot.data == null) {
          return _ErrorBlock(
            message: snapshot.hasError
                ? "Couldn't load your share code. ${snapshot.error}"
                : "Couldn't load your share code.",
            onRetry: _refresh,
          );
        }
        final code = snapshot.data!;
        return _CodeAndQrBlock(
          code: code,
          referralUrl: _referralUrl(code),
          onCopy: () => _copyCode(code),
        );
      },
    );
  }

  Widget _buildShareButton() {
    return FutureBuilder<String>(
      future: _codeFuture,
      builder: (context, snapshot) {
        final code = snapshot.data;
        final ready = !snapshot.hasError && code != null && code.isNotEmpty;
        return SizedBox(
          width: double.infinity,
          height: 52,
          child: FilledButton.icon(
            onPressed: ready ? () => _shareUrl(code) : null,
            icon: const Icon(Icons.ios_share_rounded, size: 18),
            label: const Text(
              'Share via\u2026',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              disabledBackgroundColor: AppColors.surfaceRaised,
              disabledForegroundColor: AppColors.textSecondaryOnDark,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPortalLink() {
    return Center(
      child: TextButton(
        onPressed: _openPortalNetwork,
        style: TextButton.styleFrom(
          foregroundColor: AppColors.primary,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'View network stats',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(width: 4),
            Icon(Icons.arrow_forward_rounded, size: 14),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Internal building blocks. Kept private — none of these need to be
// reused elsewhere.
// ---------------------------------------------------------------------------

/// Code-pill + QR. Code is a tap-target the whole way across; QR sits
/// below at 156×156 logical so it scans cleanly off a phone screen.
class _CodeAndQrBlock extends StatelessWidget {
  final String code;
  final String referralUrl;
  final VoidCallback onCopy;

  const _CodeAndQrBlock({
    required this.code,
    required this.referralUrl,
    required this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Tap-to-copy code pill. Coral monospace text on the brand-tint
        // surface — same visual family as Settings' Network code block.
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onCopy,
            borderRadius: BorderRadius.circular(14),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 14,
              ),
              decoration: BoxDecoration(
                color: AppColors.brandTintBg,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: AppColors.brandTintBorder,
                  width: 1,
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'YOUR SHARE CODE',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.8,
                            color: AppColors.textSecondaryOnDark,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          code,
                          style: const TextStyle(
                            fontFamily: 'JetBrainsMono',
                            fontFamilyFallback: ['Menlo', 'Courier'],
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 2,
                            color: AppColors.primary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          referralUrl.replaceFirst('https://', ''),
                          style: const TextStyle(
                            fontFamily: 'JetBrainsMono',
                            fontFamilyFallback: ['Menlo', 'Courier'],
                            fontSize: 11,
                            color: AppColors.textSecondaryOnDark,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Icon(
                    Icons.content_copy_rounded,
                    size: 18,
                    color: AppColors.primary,
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        // QR — same encoding as the share-kit screen had: full referral
        // URL, error-correction L (link is short; quiet zone matters more
        // than bit redundancy here).
        Center(
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
            ),
            child: QrImageView(
              data: referralUrl,
              version: QrVersions.auto,
              size: 156,
              backgroundColor: Colors.white,
              errorCorrectionLevel: QrErrorCorrectLevel.L,
              padding: EdgeInsets.zero,
              eyeStyle: const QrEyeStyle(
                eyeShape: QrEyeShape.square,
                color: Color(0xFF0C0E14),
              ),
              dataModuleStyle: const QrDataModuleStyle(
                dataModuleShape: QrDataModuleShape.square,
                color: Color(0xFF0C0E14),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _LoadingBlock extends StatelessWidget {
  const _LoadingBlock();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 220,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.surfaceBorder, width: 1),
      ),
      child: const SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(
          color: AppColors.primary,
          strokeWidth: 2,
        ),
      ),
    );
  }
}

/// Inline error state with optional retry. Replaces the silent infinite
/// spinner Carl flagged on the retired standalone screen.
class _ErrorBlock extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;

  const _ErrorBlock({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.surfaceBorder, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.error_outline_rounded,
                size: 20,
                color: AppColors.primary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  message,
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 13,
                    height: 1.4,
                    color: AppColors.textOnDark,
                  ),
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (onRetry != null) ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text(
                  'Try again',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.primary,
                  side: const BorderSide(color: AppColors.brandTintBorder),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
