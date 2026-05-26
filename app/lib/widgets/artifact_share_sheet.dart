import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../services/api_client.dart';
import '../theme.dart';

/// Artifact-system Wave 5 — share bottom sheet with two intents (2026-05-26).
///
/// Replaces the single-path Studio toolbar Share button (`_shareFromToolbar`
/// → `Share.share()`). Two CTAs:
///
///   * **Share link** — falls through to the OS share sheet with the plan
///     URL. Anonymous; no contact captured. Dominant path per the share-sheet
///     mockup (`docs/design/mockups/2026-05-26-share-sheet.html` — WhatsApp
///     blast).
///
///   * **Send by email** — opens an inline form (email field + optional
///     message). On Send, invokes the `send-artifact-email` Supabase Edge
///     Function via [ApiClient.sendArtifactEmail], which uses Resend's HTTP
///     API to deliver a branded email containing a link to the workout
///     handout at `https://session.homefit.studio/h/{planId}`.
///
/// The email field pre-fills from a caller-supplied seed (typically
/// `CachedClient.email` — see `SyncService` for the hydration path). The
/// caller passes the [planUrl] for the OS share path AND the [planId] +
/// [clientId] for the managed-email path; both are required since the
/// sheet doesn't have a handle to the plan model itself.
///
/// On send-success the sheet flips to a success state (no modal — R-01)
/// then auto-dismisses after a short delay. On send-failure it surfaces
/// an in-sheet coral chip with the reason + a Retry button.
///
/// Open via [showArtifactShareSheet].
class ArtifactShareSheet extends StatefulWidget {
  /// Plan UUID — used for the managed-email path.
  final String planId;

  /// Client UUID — used for the managed-email path so the edge function
  /// can membership-check the practice and stamp `clients.email` via the
  /// `set_client_email` RPC (skipped if a verified email already exists).
  final String clientId;

  /// Practitioner's share URL — used for the OS share path (WhatsApp,
  /// Messages, etc.). Typically `session.homefit.studio/p/{planId}` (the
  /// workout player), NOT the handout. The brief locks this as the user-
  /// visible URL on the dominant blast path.
  final String planUrl;

  /// Optional plan title for the sheet header. Falls back to "this plan"
  /// when absent.
  final String? planTitle;

  /// Optional version number — surfaces in the small "vN · live" chip on
  /// the sheet header to mirror the share-sheet mockup geometry.
  final int? planVersion;

  /// Pre-fill value for the email field. Typically the practitioner-typed
  /// transient email stored on the cached client row (Wave 5 schema). When
  /// null or empty the field opens blank with placeholder copy.
  final String? prefillEmail;

  const ArtifactShareSheet({
    super.key,
    required this.planId,
    required this.clientId,
    required this.planUrl,
    this.planTitle,
    this.planVersion,
    this.prefillEmail,
  });

  @override
  State<ArtifactShareSheet> createState() => _ArtifactShareSheetState();
}

enum _ShareSheetMode { choices, emailForm }
enum _EmailSendState { idle, sending, success, error }

class _ArtifactShareSheetState extends State<ArtifactShareSheet> {
  _ShareSheetMode _mode = _ShareSheetMode.choices;
  _EmailSendState _emailState = _EmailSendState.idle;
  String? _errorReason;

  late final TextEditingController _emailController;
  late final TextEditingController _messageController;
  final FocusNode _emailFocus = FocusNode();

  Timer? _autoDismiss;

  @override
  void initState() {
    super.initState();
    _emailController = TextEditingController(text: widget.prefillEmail ?? '');
    _messageController = TextEditingController();
  }

  @override
  void dispose() {
    _autoDismiss?.cancel();
    _emailController.dispose();
    _messageController.dispose();
    _emailFocus.dispose();
    super.dispose();
  }

  Future<void> _onShareLinkTap() async {
    HapticFeedback.selectionClick();
    // Close the sheet first so the OS share sheet positions cleanly over
    // the Studio backdrop and we don't render two surfaces at once.
    final navigator = Navigator.of(context);
    final box = context.findRenderObject() as RenderBox?;
    final origin = box != null
        ? box.localToGlobal(Offset.zero) & box.size
        : const Rect.fromLTWH(0, 0, 100, 100);
    navigator.pop();
    try {
      await Share.share(widget.planUrl, sharePositionOrigin: origin);
    } catch (_) {
      // The share sheet has already closed; we don't have a reliable
      // BuildContext for a SnackBar. The Studio screen's existing
      // `_shareFromToolbar` shell now wraps the call in its own
      // try/catch (preserved by the wiring change), so this is a no-op.
    }
  }

  void _onSendByEmailTap() {
    HapticFeedback.selectionClick();
    setState(() {
      _mode = _ShareSheetMode.emailForm;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _emailFocus.requestFocus();
    });
  }

  Future<void> _onSendTap() async {
    final to = _emailController.text.trim();
    if (!_isEmailValid(to)) {
      setState(() {
        _emailState = _EmailSendState.error;
        _errorReason = 'invalid_email';
      });
      return;
    }
    HapticFeedback.selectionClick();
    setState(() {
      _emailState = _EmailSendState.sending;
      _errorReason = null;
    });

    try {
      final result = await ApiClient.instance.sendArtifactEmail(
        planId: widget.planId,
        clientId: widget.clientId,
        to: to,
        message: _messageController.text,
      );
      if (!mounted) return;
      final ok = result['ok'] == true;
      if (ok) {
        setState(() {
          _emailState = _EmailSendState.success;
        });
        _autoDismiss = Timer(const Duration(milliseconds: 1800), () {
          if (mounted) Navigator.of(context).maybePop();
        });
      } else {
        setState(() {
          _emailState = _EmailSendState.error;
          _errorReason = (result['reason'] as String?) ?? 'send_failed';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _emailState = _EmailSendState.error;
        _errorReason = 'network';
      });
    }
  }

  bool _isEmailValid(String s) {
    if (s.isEmpty || s.length > 254) return false;
    // Mirror the RPC + edge function regex.
    final re = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
    return re.hasMatch(s);
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets;
    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: Container(
          decoration: const BoxDecoration(
            color: AppColors.surfaceBase,
            borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
            border: Border(
              top: BorderSide(color: AppColors.surfaceBorder),
            ),
          ),
          padding: const EdgeInsets.only(top: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Drag handle
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: AppColors.surfaceBorder,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              _buildHeader(),
              const SizedBox(height: 8),
              const Divider(
                height: 1,
                thickness: 1,
                color: AppColors.surfaceBorder,
              ),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 160),
                child: _mode == _ShareSheetMode.choices
                    ? _buildChoicesBody()
                    : _buildEmailFormBody(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final title = (widget.planTitle ?? '').trim();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Share workout',
            style: TextStyle(
              fontFamily: 'Montserrat',
              fontWeight: FontWeight.w700,
              fontSize: 17,
              color: Colors.white,
              letterSpacing: -0.1,
            ),
          ),
          if (title.isNotEmpty || widget.planVersion != null) ...[
            const SizedBox(height: 4),
            Text(
              [
                if (title.isNotEmpty) title,
                if (widget.planVersion != null) 'v${widget.planVersion}',
              ].join(' · '),
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.textSecondaryOnDark,
                letterSpacing: 0.1,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildChoicesBody() {
    return Padding(
      key: const ValueKey('choices'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ChoiceCard(
            icon: Icons.ios_share_outlined,
            title: 'Share link',
            subtitle: 'WhatsApp, Messages, anywhere',
            note: 'Link only — no contact saved.',
            onTap: _onShareLinkTap,
          ),
          const SizedBox(height: 10),
          _ChoiceCard(
            icon: Icons.mail_outline,
            title: 'Send by email',
            subtitle: 'Branded email with a link to your plan',
            note: null,
            onTap: _onSendByEmailTap,
            isPrimary: true,
          ),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
            child: Text(
              "Already claimed? They'll be reached on the account email.",
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 10.5,
                color: AppColors.textSecondaryOnDark.withValues(alpha: 0.8),
                letterSpacing: 0.1,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmailFormBody() {
    final isSending = _emailState == _EmailSendState.sending;
    final isSuccess = _emailState == _EmailSendState.success;
    return Padding(
      key: const ValueKey('email-form'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              IconButton(
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 32,
                  height: 32,
                ),
                onPressed: isSending || isSuccess
                    ? null
                    : () {
                        setState(() {
                          _mode = _ShareSheetMode.choices;
                          _emailState = _EmailSendState.idle;
                          _errorReason = null;
                        });
                      },
                icon: const Icon(
                  Icons.arrow_back_ios_new,
                  color: AppColors.textSecondaryOnDark,
                  size: 16,
                ),
              ),
              const SizedBox(width: 4),
              const Text(
                'Send by email',
                style: TextStyle(
                  fontFamily: 'Montserrat',
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  color: Colors.white,
                  letterSpacing: -0.1,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (isSuccess)
            _SuccessChip(to: _emailController.text.trim())
          else ...[
            _EmailField(
              controller: _emailController,
              focusNode: _emailFocus,
              enabled: !isSending,
            ),
            const SizedBox(height: 12),
            _MessageField(
              controller: _messageController,
              enabled: !isSending,
            ),
            if (_emailState == _EmailSendState.error)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: _ErrorChip(
                  reason: _errorReason ?? 'send_failed',
                  onRetry: _onSendTap,
                ),
              ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: isSending ? null : _onSendTap,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  disabledBackgroundColor:
                      AppColors.primary.withValues(alpha: 0.45),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(13),
                  ),
                  elevation: 0,
                ),
                child: isSending
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          valueColor:
                              AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      )
                    : const Text(
                        'Send · 1 email',
                        style: TextStyle(
                          fontFamily: 'Montserrat',
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                          letterSpacing: 0.3,
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: RichText(
                text: TextSpan(
                  style: TextStyle(
                    fontSize: 10.5,
                    color: AppColors.textSecondaryOnDark.withValues(alpha: 0.8),
                    height: 1.4,
                  ),
                  children: [
                    TextSpan(
                      text: '* ',
                      style: const TextStyle(
                        color: AppColors.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const TextSpan(
                      text:
                          'If your client later claims their plan with a different '
                          'email, the verified one supersedes this one.',
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ChoiceCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String? note;
  final VoidCallback onTap;
  final bool isPrimary;

  const _ChoiceCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.note,
    required this.onTap,
    this.isPrimary = false,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surfaceRaised,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 13),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.surfaceBorder),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: isPrimary
                      ? AppColors.primary
                      : AppColors.brandTintBg,
                  border: Border.all(color: AppColors.brandTintBorder),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(
                  icon,
                  color: isPrimary ? Colors.white : AppColors.primary,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontFamily: 'Montserrat',
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                        color: Colors.white,
                        letterSpacing: -0.1,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: AppColors.textSecondaryOnDark,
                        height: 1.4,
                      ),
                    ),
                    if (note != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        note!,
                        style: TextStyle(
                          fontSize: 10.5,
                          color: AppColors.textSecondaryOnDark
                              .withValues(alpha: 0.7),
                          fontStyle: FontStyle.italic,
                          letterSpacing: 0.1,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 4),
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Icon(
                  Icons.chevron_right,
                  color: AppColors.textSecondaryOnDark,
                  size: 20,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmailField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool enabled;

  const _EmailField({
    required this.controller,
    required this.focusNode,
    required this.enabled,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(left: 2, bottom: 6),
          child: Text(
            'CLIENT EMAIL',
            style: TextStyle(
              fontFamily: 'Montserrat',
              fontWeight: FontWeight.w600,
              fontSize: 10,
              color: AppColors.textSecondaryOnDark,
              letterSpacing: 1,
            ),
          ),
        ),
        TextField(
          controller: controller,
          focusNode: focusNode,
          enabled: enabled,
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
          textInputAction: TextInputAction.next,
          style: const TextStyle(
            fontSize: 14,
            color: Colors.white,
          ),
          decoration: InputDecoration(
            hintText: 'client@email',
            hintStyle: TextStyle(
              color: AppColors.textSecondaryOnDark.withValues(alpha: 0.5),
              fontStyle: FontStyle.italic,
            ),
            filled: true,
            fillColor: AppColors.surfaceBg,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(11),
              borderSide:
                  const BorderSide(color: AppColors.primary, width: 1.5),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(11),
              borderSide:
                  const BorderSide(color: AppColors.primary, width: 1.5),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(11),
              borderSide:
                  const BorderSide(color: AppColors.primary, width: 1.8),
            ),
            disabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(11),
              borderSide: BorderSide(
                color: AppColors.primary.withValues(alpha: 0.4),
                width: 1.5,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _MessageField extends StatelessWidget {
  final TextEditingController controller;
  final bool enabled;

  const _MessageField({
    required this.controller,
    required this.enabled,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(left: 2, bottom: 6),
          child: Text(
            'MESSAGE · OPTIONAL',
            style: TextStyle(
              fontFamily: 'Montserrat',
              fontWeight: FontWeight.w600,
              fontSize: 10,
              color: AppColors.textSecondaryOnDark,
              letterSpacing: 1,
            ),
          ),
        ),
        TextField(
          controller: controller,
          enabled: enabled,
          maxLines: 3,
          maxLength: 280,
          textInputAction: TextInputAction.done,
          style: const TextStyle(
            fontSize: 14,
            color: Colors.white,
          ),
          decoration: InputDecoration(
            hintText: 'A note for your client (optional)…',
            hintStyle: TextStyle(
              color: AppColors.textSecondaryOnDark.withValues(alpha: 0.55),
            ),
            filled: true,
            fillColor: AppColors.surfaceBg,
            counterStyle: const TextStyle(
              color: AppColors.textSecondaryOnDark,
              fontSize: 10,
            ),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(11),
              borderSide: const BorderSide(color: AppColors.surfaceBorder),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(11),
              borderSide: const BorderSide(color: AppColors.surfaceBorder),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(11),
              borderSide:
                  const BorderSide(color: AppColors.primary, width: 1.2),
            ),
          ),
        ),
      ],
    );
  }
}

class _ErrorChip extends StatelessWidget {
  final String reason;
  final VoidCallback onRetry;

  const _ErrorChip({required this.reason, required this.onRetry});

  String _humanize(String r) {
    switch (r) {
      case 'invalid_email':
        return "That doesn't look like an email.";
      case 'forbidden':
        return "You can't share this plan.";
      case 'plan_not_found':
        return "We couldn't find that plan.";
      case 'client_mismatch':
        return 'Plan / client mismatch.';
      case 'unauthenticated':
        return 'Please sign in again.';
      case 'send_failed':
        return "Couldn't send the email. Try again.";
      case 'network':
        return 'Network error. Try again.';
      default:
        return 'Send failed: $r';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: AppColors.brandTintBg,
        border: Border.all(color: AppColors.brandTintBorder),
        borderRadius: BorderRadius.circular(11),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.error_outline,
            color: AppColors.primary,
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _humanize(reason),
              style: const TextStyle(
                fontSize: 12.5,
                color: Colors.white,
              ),
            ),
          ),
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(
              foregroundColor: AppColors.primary,
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text(
              'Retry',
              style: TextStyle(
                fontFamily: 'Montserrat',
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SuccessChip extends StatelessWidget {
  final String to;

  const _SuccessChip({required this.to});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.brandTintBg,
        border: Border.all(color: AppColors.brandTintBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: const BoxDecoration(
              color: AppColors.primary,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.check,
              color: Colors.white,
              size: 18,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Email sent',
                  style: TextStyle(
                    fontFamily: 'Montserrat',
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  to,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondaryOnDark,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Opens the artifact share sheet as a modal bottom sheet. Returns null on
/// dismiss; the caller doesn't need any reply payload — the sheet itself
/// owns the share + send lifecycle.
Future<void> showArtifactShareSheet(
  BuildContext context, {
  required String planId,
  required String clientId,
  required String planUrl,
  String? planTitle,
  int? planVersion,
  String? prefillEmail,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => ArtifactShareSheet(
      planId: planId,
      clientId: clientId,
      planUrl: planUrl,
      planTitle: planTitle,
      planVersion: planVersion,
      prefillEmail: prefillEmail,
    ),
  );
}
