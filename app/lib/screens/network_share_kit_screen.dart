import 'dart:async';
import 'dart:io' show File;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../services/share_kit_templates.dart';
import '../theme.dart';
import '../widgets/homefit_logo.dart';

/// Wave 11 mobile R-11 twin of the portal's `/network` share-kit.
///
/// Surfaces the three share templates (WhatsApp 1:1, WhatsApp broadcast,
/// email) + a rasterised PNG share card the practitioner can drop into
/// WhatsApp status / Instagram story / an email signature.
///
/// **Copy source of truth:** `app/lib/services/share_kit_templates.dart`
/// which mirrors `web-portal/src/lib/share-kit/templates.ts`. Don't inline
/// different copy here — edit the shared templates module instead.
///
/// **PNG render decision:** client-side (Flutter `RepaintBoundary.toImage`
/// at `pixelRatio: 3` on a 360×450 logical widget → 1080×1350 px). Wave 10
/// chose client render over server render because it keeps the mobile
/// path offline-capable.
///
/// **Analytics:** every share action fires `ApiClient.logShareEvent`
/// fire-and-forget. Channel + eventKind strings mirror the portal 1:1 so
/// the event log reads the same from both surfaces.
class NetworkShareKitScreen extends StatefulWidget {
  const NetworkShareKitScreen({super.key});

  @override
  State<NetworkShareKitScreen> createState() => _NetworkShareKitScreenState();
}

class _NetworkShareKitScreenState extends State<NetworkShareKitScreen> {
  // ---------------------------------------------------------------------------
  // Data — load once from ApiClient. Referral code + practice metadata
  // feed all three templates + the PNG card.
  // ---------------------------------------------------------------------------

  Future<_ShareKitContext>? _ctxFuture;

  /// Colleague-name input for the WhatsApp 1:1 template. When non-blank,
  /// `{Colleague}` substitutes inline; when blank, the literal placeholder
  /// is preserved so the practitioner can edit post-paste.
  final TextEditingController _colleagueController = TextEditingController();

  /// Global key on the PNG card's `RepaintBoundary` so we can snapshot
  /// the rendered layer at `pixelRatio: 3` and write it out as a PNG file.
  final GlobalKey _pngBoundaryKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _ctxFuture = _loadContext();
    _colleagueController.addListener(() {
      // Rebuild the preview bubble whenever the name changes so the slot
      // substitution renders live. Cheap — the rest of the screen is
      // FutureBuilder-cached.
      setState(() {});
    });
  }

  @override
  void dispose() {
    _colleagueController.dispose();
    super.dispose();
  }

  Future<_ShareKitContext> _loadContext() async {
    final practiceId = AuthService.instance.currentPracticeId.value;
    if (practiceId == null) {
      throw StateError('No practice selected — share kit requires a practice.');
    }
    final api = ApiClient.instance;

    // Fetch referral code (mints if missing) + practice list so we can pull
    // the display name for the current practice. Parallelise — independent.
    final results = await Future.wait<Object>([
      api.ensureReferralCode(practiceId),
      api.listMyPractices(),
    ]);

    final code = results[0] as String;
    final memberships = results[1] as List<PracticeMembership>;
    final membership = memberships.firstWhere(
      (m) => m.id == practiceId,
      orElse: () => memberships.isNotEmpty
          ? memberships.first
          : const PracticeMembership(
              id: '',
              name: '',
              role: PracticeRole.practitioner,
            ),
    );

    // Practitioner identity — mirror the portal's fallback rules in
    // `web-portal/src/app/network/page.tsx`:
    //   1. `user_metadata.full_name` (Google OAuth-sourced)
    //   2. `user_metadata.name` (manual-set)
    //   3. title-cased email local-part (carlhein → Carlhein)
    //   4. "A friend" so the signature never reads blank
    final user = api.raw.auth.currentUser;
    final metadata = user?.userMetadata ?? const {};
    final metaFullName = _trimOrNull(metadata['full_name']) ??
        _trimOrNull(metadata['name']);
    final emailLocalPart =
        (api.currentUserEmail ?? '').split('@').first;
    final fullName = metaFullName ??
        (emailLocalPart.isNotEmpty ? _titleCase(emailLocalPart) : 'A friend');
    final firstName = fullName.split(RegExp(r'\s+')).first;

    final practiceName =
        membership.name.isNotEmpty ? membership.name : 'Your practice';

    return _ShareKitContext(
      practiceId: practiceId,
      code: code,
      practiceName: practiceName,
      slots: ShareKitSlots(
        firstName: firstName,
        fullName: fullName,
        practiceName: practiceName,
        referralLink: 'https://manage.homefit.studio/r/$code',
      ),
    );
  }

  /// Returns the trimmed string value if [v] is a non-empty `String`,
  /// otherwise null. Used to unwrap `user_metadata` entries that may be
  /// `null` / int / other types.
  String? _trimOrNull(dynamic v) {
    if (v is String) {
      final t = v.trim();
      if (t.isNotEmpty) return t;
    }
    return null;
  }

  /// Tiny title-case helper so a bare email prefix reads "Carlhein" rather
  /// than "carlhein" in the email signature. Mirrors `titleCase()` in
  /// `web-portal/src/app/network/page.tsx`.
  String _titleCase(String s) {
    if (s.isEmpty) return '';
    return s
        .split(RegExp(r'[.\-_]+'))
        .where((p) => p.isNotEmpty)
        .map((p) => p[0].toUpperCase() + p.substring(1))
        .join(' ');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surfaceBg,
      appBar: AppBar(
        backgroundColor: AppColors.surfaceBg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text(
          'Share homefit.studio',
          style: TextStyle(
            fontFamily: 'Montserrat',
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: AppColors.textOnDark,
          ),
        ),
        iconTheme: const IconThemeData(color: AppColors.textOnDark),
      ),
      body: SafeArea(
        top: false,
        child: FutureBuilder<_ShareKitContext>(
          future: _ctxFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(
                child: CircularProgressIndicator(
                  color: AppColors.primary,
                  strokeWidth: 2,
                ),
              );
            }
            if (snapshot.hasError || snapshot.data == null) {
              return _ErrorState(
                error: snapshot.error,
                onRetry: () => setState(() {
                  _ctxFuture = _loadContext();
                }),
              );
            }
            final ctx = snapshot.data!;
            return _Body(
              ctx: ctx,
              colleagueController: _colleagueController,
              pngBoundaryKey: _pngBoundaryKey,
              onAction: _handleAction,
            );
          },
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Dispatcher — every card-level action flows through here so analytics
  // are wired in one place.
  // ---------------------------------------------------------------------------

  Future<void> _handleAction(_ShareAction action, _ShareKitContext ctx) async {
    switch (action) {
      case _ShareAction.whatsappOneToOneCopy:
        await _copyToClipboard(
          buildWhatsAppOneToOne(
            ctx.slots,
            colleagueName: _colleagueController.text,
          ),
          toast: 'Copied message',
        );
        _logShareEvent(
          ctx,
          channel: 'whatsapp_one_to_one',
          eventKind: 'copy',
          meta: {
            'colleague_name_substituted':
                _colleagueController.text.trim().isNotEmpty,
          },
        );
        break;

      case _ShareAction.whatsappOneToOneOpen:
        await _launchUri(
          buildWhatsAppOneToOneUri(
            ctx.slots,
            colleagueName: _colleagueController.text,
          ),
        );
        _logShareEvent(
          ctx,
          channel: 'whatsapp_one_to_one',
          eventKind: 'open_intent',
          meta: {
            'colleague_name_substituted':
                _colleagueController.text.trim().isNotEmpty,
          },
        );
        break;

      case _ShareAction.whatsappBroadcastCopy:
        await _copyToClipboard(
          buildWhatsAppBroadcast(ctx.slots),
          toast: 'Copied message',
        );
        _logShareEvent(
          ctx,
          channel: 'whatsapp_broadcast',
          eventKind: 'copy',
        );
        break;

      case _ShareAction.whatsappBroadcastOpen:
        await _launchUri(buildWhatsAppBroadcastUri(ctx.slots));
        _logShareEvent(
          ctx,
          channel: 'whatsapp_broadcast',
          eventKind: 'open_intent',
        );
        break;

      case _ShareAction.emailCopy:
        await _copyToClipboard(
          buildEmailFullCopy(ctx.slots),
          toast: 'Copied full email',
        );
        _logShareEvent(ctx, channel: 'email', eventKind: 'copy');
        break;

      case _ShareAction.emailOpen:
        await _launchUri(buildEmailMailtoUri(ctx.slots));
        _logShareEvent(ctx, channel: 'email', eventKind: 'open_intent');
        break;

      case _ShareAction.pngShare:
        await _sharePngCard(ctx);
        // Portal semantics: record the intent even if the user cancels the
        // share sheet — we don't know from the sheet return whether they
        // shared or dismissed, so we treat an intent-fired event as a
        // "download" in the analytics.
        _logShareEvent(
          ctx,
          channel: 'png_download',
          eventKind: 'download',
        );
        break;

      case _ShareAction.taglineCopy:
        final tagline =
            'Plans your client will love and follow. Ready before they leave. — ${ctx.slots.referralLink}';
        await _copyToClipboard(tagline, toast: 'Copied tagline');
        _logShareEvent(ctx, channel: 'tagline_copy', eventKind: 'copy');
        break;
    }
  }

  // ---------------------------------------------------------------------------
  // Primitives — clipboard, url_launcher, PNG rasterise + share.
  // ---------------------------------------------------------------------------

  Future<void> _copyToClipboard(String text, {required String toast}) async {
    HapticFeedback.selectionClick();
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    _showToast(toast);
  }

  Future<void> _launchUri(Uri uri) async {
    HapticFeedback.selectionClick();
    bool launched = false;
    try {
      if (await canLaunchUrl(uri)) {
        launched = await launchUrl(
          uri,
          mode: LaunchMode.externalApplication,
        );
      }
    } catch (_) {
      launched = false;
    }
    if (!launched && mounted) {
      _showToast('No app available to open this link.');
    }
  }

  /// Raster the PNG card widget at `pixelRatio: 3` (logical 360×450 →
  /// 1080×1350 px), write the bytes to a temp file, then hand it to the
  /// iOS share sheet. The sheet's default behaviour includes "Save Image",
  /// so we don't need a separate save-to-photos button.
  Future<void> _sharePngCard(_ShareKitContext ctx) async {
    final boundary = _pngBoundaryKey.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary) return;
    try {
      final image = await boundary.toImage(pixelRatio: 3.0);
      final byteData =
          await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) {
        _showToast("Couldn't render the image. Try again.");
        return;
      }
      final bytes = byteData.buffer.asUint8List();
      final file = await _writeTempPng(bytes, ctx.code);
      if (!mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      final origin = box == null
          ? Rect.zero
          : box.localToGlobal(Offset.zero) & box.size;
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'image/png')],
        subject: 'homefit.studio — ${ctx.practiceName}',
        sharePositionOrigin: origin,
      );
    } catch (e) {
      debugPrint('NetworkShareKitScreen._sharePngCard: $e');
      if (mounted) _showToast("Couldn't share the image. Try again.");
    }
  }

  Future<File> _writeTempPng(Uint8List bytes, String code) async {
    final dir = await getTemporaryDirectory();
    // Include the code so subsequent shares don't overwrite the same file
    // mid-upload by another app.
    final file = File(
      '${dir.path}/homefit-share-${code.toLowerCase()}.png',
    );
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  void _logShareEvent(
    _ShareKitContext ctx, {
    required String channel,
    required String eventKind,
    Map<String, dynamic>? meta,
  }) {
    unawaited(
      ApiClient.instance.logShareEvent(
        practiceId: ctx.practiceId,
        channel: channel,
        eventKind: eventKind,
        meta: meta,
      ),
    );
  }

  void _showToast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            message,
            style: const TextStyle(
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
}

// ---------------------------------------------------------------------------
// Body — scrollable column of cards. Broken out so the parent [State]
// object stays focused on data + dispatch.
// ---------------------------------------------------------------------------

class _Body extends StatelessWidget {
  final _ShareKitContext ctx;
  final TextEditingController colleagueController;
  final GlobalKey pngBoundaryKey;
  final Future<void> Function(_ShareAction, _ShareKitContext) onAction;

  const _Body({
    required this.ctx,
    required this.colleagueController,
    required this.pngBoundaryKey,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        // Code badge row — shown once up top so the practitioner sees
        // what's being shared (the referral code + URL).
        _CodeBadge(code: ctx.code, referralLink: ctx.slots.referralLink),
        const SizedBox(height: 20),

        // 1. WhatsApp one-to-one
        _FormatCard(
          title: 'WhatsApp · one-to-one',
          subtitle: 'Short personal message',
          icon: Icons.chat_bubble_rounded,
          preview: _WhatsAppOneToOnePreview(
            slots: ctx.slots,
            colleagueName: colleagueController.text,
          ),
          inputBelow: _ColleagueInput(controller: colleagueController),
          primaryLabel: 'Copy message',
          primaryIcon: Icons.content_copy_rounded,
          secondaryLabel: 'Open in WhatsApp',
          secondaryIcon: Icons.open_in_new_rounded,
          onPrimary: () => onAction(_ShareAction.whatsappOneToOneCopy, ctx),
          onSecondary: () => onAction(_ShareAction.whatsappOneToOneOpen, ctx),
        ),
        const SizedBox(height: 16),

        // 2. WhatsApp broadcast
        _FormatCard(
          title: 'WhatsApp · status / broadcast',
          subtitle: 'Punchier, no name slot',
          icon: Icons.campaign_rounded,
          preview: _BroadcastPreview(slots: ctx.slots),
          primaryLabel: 'Copy message',
          primaryIcon: Icons.content_copy_rounded,
          secondaryLabel: 'Open in WhatsApp',
          secondaryIcon: Icons.open_in_new_rounded,
          onPrimary: () => onAction(_ShareAction.whatsappBroadcastCopy, ctx),
          onSecondary: () => onAction(_ShareAction.whatsappBroadcastOpen, ctx),
        ),
        const SizedBox(height: 16),

        // 3. Email
        _FormatCard(
          title: 'Email · professional introduction',
          subtitle: 'Subject + body + signature auto-filled',
          icon: Icons.mail_outline_rounded,
          preview: _EmailPreview(slots: ctx.slots),
          primaryLabel: 'Copy full email',
          primaryIcon: Icons.content_copy_rounded,
          secondaryLabel: 'Open in mail client',
          secondaryIcon: Icons.open_in_new_rounded,
          onPrimary: () => onAction(_ShareAction.emailCopy, ctx),
          onSecondary: () => onAction(_ShareAction.emailOpen, ctx),
        ),
        const SizedBox(height: 24),

        // 4. PNG card — RepaintBoundary-wrapped visual render of the
        // share card, 360×450 logical (1080×1350 rasterised at 3x).
        _PngSection(
          ctx: ctx,
          boundaryKey: pngBoundaryKey,
          onShare: () => onAction(_ShareAction.pngShare, ctx),
        ),
        const SizedBox(height: 24),

        // 5. Tagline-helper row — for places a PNG won't fit.
        _TaglineHelper(
          slots: ctx.slots,
          onCopy: () => onAction(_ShareAction.taglineCopy, ctx),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Code badge — referral code + URL. Compact chip row.
// ---------------------------------------------------------------------------

class _CodeBadge extends StatelessWidget {
  final String code;
  final String referralLink;

  const _CodeBadge({required this.code, required this.referralLink});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: AppColors.surfaceBase,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: AppColors.surfaceBorder, width: 1),
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
                const SizedBox(height: 6),
                Text(
                  code,
                  style: const TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontFamilyFallback: ['Menlo', 'Courier'],
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 2,
                    color: AppColors.primary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  referralLink.replaceFirst('https://', ''),
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
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared format-card shell. Three WhatsApp/email cards all use this shape.
// ---------------------------------------------------------------------------

class _FormatCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final Widget preview;
  final Widget? inputBelow;
  final String primaryLabel;
  final IconData primaryIcon;
  final String secondaryLabel;
  final IconData secondaryIcon;
  final VoidCallback onPrimary;
  final VoidCallback onSecondary;

  const _FormatCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.preview,
    this.inputBelow,
    required this.primaryLabel,
    required this.primaryIcon,
    required this.secondaryLabel,
    required this.secondaryIcon,
    required this.onPrimary,
    required this.onSecondary,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceBase,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(color: AppColors.surfaceBorder, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: AppColors.brandTintBg,
                  borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                ),
                alignment: Alignment.center,
                child: Icon(icon, size: 18, color: AppColors.primary),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontFamily: 'Montserrat',
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                        color: AppColors.textOnDark,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 11,
                        color: AppColors.textSecondaryOnDark,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          preview,
          if (inputBelow != null) ...[
            const SizedBox(height: 12),
            inputBelow!,
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: onPrimary,
                  icon: Icon(primaryIcon, size: 16),
                  label: Text(
                    primaryLabel,
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onSecondary,
                  icon: Icon(secondaryIcon, size: 16),
                  label: Text(
                    secondaryLabel,
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textOnDark,
                    side: const BorderSide(color: AppColors.surfaceBorder),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Preview bubbles — render the actual outgoing message so the practitioner
// sees what the recipient will see. Kept visually distinct from the
// `msg-body` mockup: dark raised surface + coral link tint.
// ---------------------------------------------------------------------------

class _WhatsAppOneToOnePreview extends StatelessWidget {
  final ShareKitSlots slots;
  final String colleagueName;

  const _WhatsAppOneToOnePreview({
    required this.slots,
    required this.colleagueName,
  });

  @override
  Widget build(BuildContext context) {
    // Substitute {Colleague} in the preview so the practitioner sees the
    // final message — mirrors the portal's live preview behaviour. When
    // empty, the slot is highlighted as an orange chip so it's visually
    // clear there's an editable placeholder.
    final trimmedName = colleagueName.trim();
    final hasName = trimmedName.isNotEmpty;
    final body = buildWhatsAppOneToOne(
      slots,
      colleagueName: hasName ? trimmedName : null,
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: AppColors.surfaceBorder, width: 1),
      ),
      child: _RichBodyText(
        body: body,
        referralLink: slots.referralLink,
        slotPlaceholder: hasName ? null : '{Colleague}',
      ),
    );
  }
}

class _BroadcastPreview extends StatelessWidget {
  final ShareKitSlots slots;
  const _BroadcastPreview({required this.slots});

  @override
  Widget build(BuildContext context) {
    final body = buildWhatsAppBroadcast(slots);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: AppColors.surfaceBorder, width: 1),
      ),
      child: _RichBodyText(
        body: body,
        referralLink: slots.referralLink,
      ),
    );
  }
}

class _EmailPreview extends StatelessWidget {
  final ShareKitSlots slots;
  const _EmailPreview({required this.slots});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: AppColors.surfaceBorder, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'SUBJECT',
            style: TextStyle(
              fontFamily: 'JetBrainsMono',
              fontFamilyFallback: ['Menlo', 'Courier'],
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
              color: AppColors.textSecondaryOnDark,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            buildEmailSubject(),
            style: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: AppColors.textOnDark,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'BODY',
            style: TextStyle(
              fontFamily: 'JetBrainsMono',
              fontFamilyFallback: ['Menlo', 'Courier'],
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
              color: AppColors.textSecondaryOnDark,
            ),
          ),
          const SizedBox(height: 4),
          // Keep the first three-ish paragraphs of the body visible; full
          // copy lands in the clipboard/mailto. Showing the whole thing
          // makes the card unwieldy on phone.
          _RichBodyText(
            body: buildEmailBody(slots),
            referralLink: slots.referralLink,
            slotPlaceholder: '{Colleague}',
            maxLines: 14,
          ),
        ],
      ),
    );
  }
}

/// Renders a body of text, highlighting the referral link in coral and —
/// if present — the `{slotPlaceholder}` as an orange-tint chip.
///
/// Not a general-purpose rich-text widget: the split rules are specific to
/// the share-kit copy shape (one link, at-most-one `{slot}` token).
class _RichBodyText extends StatelessWidget {
  final String body;
  final String referralLink;
  final String? slotPlaceholder;
  final int? maxLines;

  const _RichBodyText({
    required this.body,
    required this.referralLink,
    this.slotPlaceholder,
    this.maxLines,
  });

  @override
  Widget build(BuildContext context) {
    const baseStyle = TextStyle(
      fontFamily: 'Inter',
      fontSize: 13,
      height: 1.5,
      color: AppColors.textOnDark,
    );
    final linkStyle = baseStyle.copyWith(
      color: AppColors.primary,
      fontFamily: 'JetBrainsMono',
      fontFamilyFallback: const ['Menlo', 'Courier'],
      fontSize: 12,
    );
    final slotStyle = baseStyle.copyWith(
      color: AppColors.primaryLight,
      fontFamily: 'JetBrainsMono',
      fontFamilyFallback: const ['Menlo', 'Courier'],
      fontSize: 12,
      backgroundColor: AppColors.brandTintBg,
    );

    final spans = <InlineSpan>[];
    var remaining = body;

    while (remaining.isNotEmpty) {
      // Which marker comes next — referralLink or the slot placeholder?
      final linkIdx = remaining.indexOf(referralLink);
      final slotIdx = slotPlaceholder == null
          ? -1
          : remaining.indexOf(slotPlaceholder!);

      final hasLink = linkIdx >= 0;
      final hasSlot = slotIdx >= 0;
      if (!hasLink && !hasSlot) {
        spans.add(TextSpan(text: remaining, style: baseStyle));
        break;
      }

      int pickIdx;
      String pickToken;
      TextStyle pickStyle;
      if (hasLink && (!hasSlot || linkIdx < slotIdx)) {
        pickIdx = linkIdx;
        pickToken = referralLink;
        pickStyle = linkStyle;
      } else {
        pickIdx = slotIdx;
        pickToken = slotPlaceholder!;
        pickStyle = slotStyle;
      }

      if (pickIdx > 0) {
        spans.add(
            TextSpan(text: remaining.substring(0, pickIdx), style: baseStyle));
      }
      spans.add(TextSpan(text: pickToken, style: pickStyle));
      remaining = remaining.substring(pickIdx + pickToken.length);
    }

    return Text.rich(
      TextSpan(children: spans),
      maxLines: maxLines,
      overflow: maxLines == null ? TextOverflow.clip : TextOverflow.ellipsis,
    );
  }
}

// ---------------------------------------------------------------------------
// Colleague-name input for WhatsApp 1:1. Rebuilds live preview via listener
// on the parent's controller.
// ---------------------------------------------------------------------------

class _ColleagueInput extends StatelessWidget {
  final TextEditingController controller;
  const _ColleagueInput({required this.controller});

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      style: const TextStyle(
        fontFamily: 'Inter',
        fontSize: 13,
        color: AppColors.textOnDark,
      ),
      textCapitalization: TextCapitalization.words,
      decoration: InputDecoration(
        isDense: true,
        hintText: 'Colleague\'s first name (optional)',
        hintStyle: const TextStyle(
          fontFamily: 'Inter',
          fontSize: 13,
          color: AppColors.textSecondaryOnDark,
        ),
        filled: true,
        fillColor: AppColors.surfaceRaised,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusSm),
          borderSide: const BorderSide(color: AppColors.surfaceBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusSm),
          borderSide: const BorderSide(color: AppColors.surfaceBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusSm),
          borderSide: const BorderSide(color: AppColors.brandTintBorder),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// PNG share card — the rasterisable widget tree. Wrapped in a
// RepaintBoundary so RenderRepaintBoundary.toImage picks up ONLY the card.
// ---------------------------------------------------------------------------

class _PngSection extends StatelessWidget {
  final _ShareKitContext ctx;
  final GlobalKey boundaryKey;
  final VoidCallback onShare;

  const _PngSection({
    required this.ctx,
    required this.boundaryKey,
    required this.onShare,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: AppColors.brandTintBg,
                borderRadius: BorderRadius.circular(AppTheme.radiusSm),
              ),
              alignment: Alignment.center,
              child: const Icon(
                Icons.image_outlined,
                size: 18,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(width: 10),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Downloadable share card',
                    style: TextStyle(
                      fontFamily: 'Montserrat',
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.2,
                      color: AppColors.textOnDark,
                    ),
                  ),
                  Text(
                    '1080 × 1350 · PNG',
                    style: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontFamilyFallback: ['Menlo', 'Courier'],
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5,
                      color: AppColors.textSecondaryOnDark,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // Card — rendered at logical 360×450 (4:5) so the 3x rasterise lands
        // exactly at 1080×1350. Centered + shrunk on narrow phones so the
        // full aspect fits without cropping.
        Center(
          child: RepaintBoundary(
            key: boundaryKey,
            child: _PngShareCard(ctx: ctx),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: onShare,
            icon: const Icon(Icons.ios_share_rounded, size: 18),
            label: const Text(
              'Share PNG',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            'Opens the iOS share sheet — pick WhatsApp, Instagram, Messages, or Save to Photos.',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 11,
              color: AppColors.textSecondaryOnDark,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}

/// The visual card. Logical dimensions 360×450 (4:5); rasterises at 3x to
/// 1080×1350. Geometry follows the mockup's `.png-card` shape from
/// `docs/design/mockups/network-share-kit.html`:
///   * Top: homefit.studio logo + wordmark.
///   * Middle: practitioner label + name + practice + tagline with coral
///     accent on "love and follow".
///   * Bottom: QR of the referral link + code pair chip.
class _PngShareCard extends StatelessWidget {
  final _ShareKitContext ctx;
  const _PngShareCard({required this.ctx});

  @override
  Widget build(BuildContext context) {
    const cardWidth = 360.0;
    const cardHeight = 450.0;
    return Container(
      width: cardWidth,
      height: cardHeight,
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppTheme.radiusXl),
        // Matches the mockup: coral glow top-left + secondary coral glow
        // bottom-right, over a near-black vertical gradient.
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF151824), Color(0xFF0C0E14)],
        ),
        border: Border.all(color: AppColors.surfaceBorder, width: 1),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Coral radial glow — approximated with a gradient on a
          // Positioned.fill (Flutter has no native radial-gradient-overlay
          // shorthand but this visual reads as a glow).
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppTheme.radiusXl),
                gradient: RadialGradient(
                  center: const Alignment(-0.6, -0.8),
                  radius: 1.0,
                  colors: [
                    const Color(0xFFFF6B35).withValues(alpha: 0.28),
                    const Color(0xFFFF6B35).withValues(alpha: 0.02),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 0.5, 1.0],
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppTheme.radiusXl),
                gradient: RadialGradient(
                  center: const Alignment(0.8, 1.0),
                  radius: 0.6,
                  colors: [
                    const Color(0xFFFF6B35).withValues(alpha: 0.14),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 1.0],
                ),
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Top — logo + wordmark.
              Row(
                children: [
                  const HomefitLogo(size: 100),
                  const SizedBox(width: 8),
                  const Text(
                    'homefit.studio',
                    style: TextStyle(
                      fontFamily: 'Montserrat',
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.2,
                      color: AppColors.textOnDark,
                    ),
                  ),
                ],
              ),
              const Spacer(),
              // Middle — practitioner label + name + practice + tagline.
              const Text(
                'YOUR PRACTITIONER',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.2,
                  color: AppColors.primary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                ctx.slots.fullName,
                style: const TextStyle(
                  fontFamily: 'Montserrat',
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  height: 1.1,
                  letterSpacing: -0.5,
                  color: AppColors.textOnDark,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                ctx.practiceName,
                style: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 12,
                  color: AppColors.textSecondaryOnDark,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 20),
              // Tagline with the coral accent on "love and follow".
              const _TaglineRich(),
              const SizedBox(height: 22),
              // Bottom — QR + URL + code pair chip.
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Container(
                    width: 84,
                    height: 84,
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: QrImageView(
                      data: ctx.slots.referralLink,
                      version: QrVersions.auto,
                      backgroundColor: Colors.white,
                      // Tight ECL — the referral link is short, so an L
                      // level keeps the code scannable at the card's
                      // printed size without wasting quiet-zone pixels.
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
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'SCAN OR VISIT',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 9,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.6,
                            color: AppColors.textSecondaryOnDark,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          ctx.slots.referralLink.replaceFirst('https://', ''),
                          style: const TextStyle(
                            fontFamily: 'JetBrainsMono',
                            fontFamilyFallback: ['Menlo', 'Courier'],
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: AppColors.primary,
                            letterSpacing: 0.2,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFF6B35).withValues(alpha: 0.15),
                            border: Border.all(
                              color: AppColors.brandTintBorder,
                              width: 1,
                            ),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            'CODE · ${ctx.code}',
                            style: const TextStyle(
                              fontFamily: 'JetBrainsMono',
                              fontFamilyFallback: ['Menlo', 'Courier'],
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: AppColors.primaryLight,
                              letterSpacing: 0.6,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Tagline rendered across two lines with the coral accent on "love and
/// follow". Mirror of `.png-card-mid .tagline` from the HTML mockup.
class _TaglineRich extends StatelessWidget {
  const _TaglineRich();

  @override
  Widget build(BuildContext context) {
    const baseStyle = TextStyle(
      fontFamily: 'Montserrat',
      fontSize: 16,
      fontWeight: FontWeight.w700,
      height: 1.3,
      letterSpacing: -0.2,
      color: AppColors.textOnDark,
    );
    final coralStyle = baseStyle.copyWith(color: AppColors.primary);
    return Text.rich(
      TextSpan(
        children: [
          const TextSpan(text: 'Plans your client will '),
          TextSpan(text: 'love and follow', style: coralStyle),
          const TextSpan(text: '.\nReady before they leave.'),
        ],
      ),
      style: baseStyle,
    );
  }
}

// ---------------------------------------------------------------------------
// Tagline helper — raw tagline + referral link + copy button.
// ---------------------------------------------------------------------------

class _TaglineHelper extends StatelessWidget {
  final ShareKitSlots slots;
  final VoidCallback onCopy;
  const _TaglineHelper({required this.slots, required this.onCopy});

  @override
  Widget build(BuildContext context) {
    final tagline =
        'Plans your client will love and follow. Ready before they leave. — ${slots.referralLink}';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: AppColors.surfaceBorder, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'TAGLINE',
            style: TextStyle(
              fontFamily: 'JetBrainsMono',
              fontFamilyFallback: ['Menlo', 'Courier'],
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
              color: AppColors.textSecondaryOnDark,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            tagline,
            style: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 13,
              height: 1.5,
              color: AppColors.textOnDark,
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton.icon(
              onPressed: onCopy,
              icon: const Icon(Icons.content_copy_rounded, size: 14),
              label: const Text(
                'Copy tagline',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.textOnDark,
                side: const BorderSide(color: AppColors.surfaceBorder),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Error state. Dead-simple retry row — network failure here usually means
// the practice can't be resolved or the referral-code RPC failed.
// ---------------------------------------------------------------------------

class _ErrorState extends StatelessWidget {
  final Object? error;
  final VoidCallback onRetry;
  const _ErrorState({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error_outline_rounded,
              size: 36,
              color: AppColors.primary,
            ),
            const SizedBox(height: 12),
            const Text(
              "Couldn't load your share kit.",
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppColors.textOnDark,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              error?.toString() ?? 'Unknown error',
              style: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 12,
                color: AppColors.textSecondaryOnDark,
              ),
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('Try again'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.primary,
                side: const BorderSide(color: AppColors.brandTintBorder),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Data + action enums — kept private to this file.
// ---------------------------------------------------------------------------

/// Loaded context for the share-kit screen. All fields are non-null by the
/// time this object exists — failure paths throw from `_loadContext`.
@immutable
class _ShareKitContext {
  final String practiceId;
  final String code;
  final String practiceName;
  final ShareKitSlots slots;

  const _ShareKitContext({
    required this.practiceId,
    required this.code,
    required this.practiceName,
    required this.slots,
  });
}

/// Every analytics-logged action the screen dispatches. Adding a new share
/// surface means extending this enum + the switch in `_handleAction`; the
/// compiler flags missing cases so analytics stay in sync.
enum _ShareAction {
  whatsappOneToOneCopy,
  whatsappOneToOneOpen,
  whatsappBroadcastCopy,
  whatsappBroadcastOpen,
  emailCopy,
  emailOpen,
  pngShare,
  taglineCopy,
}
