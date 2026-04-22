import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;

import '../services/auth_service.dart';
import '../theme.dart';
import '../widgets/homefit_logo.dart';

/// Full-screen sign-in landing. Rendered by the AuthGate when the user has
/// no Supabase session. Once sign-in completes (magic-link deep-link fires,
/// Supabase SDK consumes the token, session lands) the AuthGate swaps this
/// out for the HomeScreen automatically.
///
/// POV auth strategy: email magic-link is the PRIMARY sign-in. Google is
/// temporarily parked behind a "coming soon" badge because the iOS
/// GoogleSignIn 8.x SDK injects a nonce that `signInWithIdToken` rejects
/// (see `docs/BACKLOG_GOOGLE_SIGNIN.md`). The native path stays wired in
/// `AuthService` so re-enablement is a one-line flip of [_googleEnabled]
/// once upstream fixes land. Apple remains scaffolded and disabled until
/// Carl's Apple Developer enrolment is approved.
class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  /// Flip to `true` once Google Sign-In + Supabase `signInWithIdToken` are
  /// happy with each other again (post the SDK nonce-mismatch fix tracked
  /// in `docs/BACKLOG_GOOGLE_SIGNIN.md`).
  static const bool _googleEnabled = false;

  /// Flip to `true` once Apple Developer enrolment is approved and Sign in
  /// with Apple is wired up in the Supabase dashboard.
  static const bool _appleEnabled = false;

  final TextEditingController _emailController = TextEditingController();
  final FocusNode _emailFocus = FocusNode();
  final TextEditingController _passwordController = TextEditingController();
  final FocusNode _passwordFocus = FocusNode();

  /// UI state machine for the magic-link form:
  ///   - [_MagicLinkState.form] — email input visible, awaiting send
  ///   - [_MagicLinkState.sending] — request in flight
  ///   - [_MagicLinkState.sent] — confirmation panel, inbox copy
  _MagicLinkState _state = _MagicLinkState.form;
  String? _sentToEmail;
  String? _errorText;

  /// Prevents double-taps on the Google button while its handler runs
  /// (kept even though the button is currently disabled, so re-enablement
  /// stays a one-line flip).
  bool _googleSigningIn = false;

  @override
  void dispose() {
    _emailController.dispose();
    _emailFocus.dispose();
    _passwordController.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  // ── Progressive auth: password first, magic-link fallback ──────────────

  /// Primary submit handler. Mirrors the portal's SignInGate (R-11):
  ///   - If a password is provided, try signInWithPassword first.
  ///   - On password failure (or empty password), fall through to
  ///     sendMagicLink. User sees the "check your inbox" panel with a
  ///     gentle note that the password didn't match.
  ///   - On success the AuthGate's onAuthStateChange listener routes to
  ///     Home; this widget just waits for the unmount.
  Future<void> _submit() async {
    if (_state == _MagicLinkState.sending) return;
    unawaited(HapticFeedback.selectionClick());

    final email = _emailController.text.trim().toLowerCase();
    final password = _passwordController.text;

    if (email.isEmpty || !email.contains('@')) {
      setState(() {
        _errorText = "We don't recognise that email address.";
      });
      return;
    }

    setState(() {
      _state = _MagicLinkState.sending;
      _errorText = null;
    });

    // Password path.
    if (password.isNotEmpty) {
      try {
        await AuthService.instance.signInWithPassword(
          email: email,
          password: password,
        );
        // Success — AuthGate picks up the onAuthStateChange and routes
        // to Home. No setState here; the widget will unmount.
        if (!mounted) return;
        unawaited(HapticFeedback.mediumImpact());
        return;
      } on AuthException catch (_) {
        // Invalid credentials / user-not-found / etc. — fall through to
        // magic-link with a note so the user knows why the flow switched.
        if (!mounted) return;
      } catch (_) {
        if (!mounted) return;
      }
    }

    // Magic-link path (either no password provided, or password sign-in
    // fell through).
    try {
      await AuthService.instance.sendMagicLink(email);
      if (!mounted) return;
      unawaited(HapticFeedback.mediumImpact());
      setState(() {
        _state = _MagicLinkState.sent;
        _sentToEmail = email;
        _errorText = password.isNotEmpty
            ? "Password didn't match — we sent you a magic link instead."
            : null;
      });
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _state = _MagicLinkState.form;
        _errorText = _friendlyAuthError(e);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _state = _MagicLinkState.form;
        _errorText = "Couldn't sign in. Try again.";
      });
    }
  }

  /// Map Supabase AuthException messages onto short, on-voice copy.
  /// Supabase's own strings are serviceable but technical; this keeps the
  /// surface consistent with voice.md (what happened · what to do).
  String _friendlyAuthError(AuthException e) {
    final msg = e.message.toLowerCase();
    if (msg.contains('rate') || msg.contains('too many')) {
      return 'Too many requests. Wait a moment and try again.';
    }
    if (msg.contains('invalid') && msg.contains('email')) {
      return "We don't recognise that email address.";
    }
    return "Couldn't send link. Try again.";
  }

  void _resetForm() {
    setState(() {
      _state = _MagicLinkState.form;
      _errorText = null;
      _sentToEmail = null;
    });
    // Slight delay so the form is mounted before we steal focus.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _emailFocus.requestFocus();
    });
  }

  // ── Google (parked) ─────────────────────────────────────────────────────

  Future<void> _signInWithGoogle() async {
    if (_googleSigningIn) return;
    setState(() => _googleSigningIn = true);
    try {
      await AuthService.instance.signInWithGoogle();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Sign-in failed: $e')),
      );
      setState(() => _googleSigningIn = false);
    }
  }

  // ── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surfaceBg,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              keyboardDismissBehavior:
                  ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: ConstrainedBox(
                constraints:
                    BoxConstraints(minHeight: constraints.maxHeight),
                child: IntrinsicHeight(
                  child: Column(
                    children: [
                      const SizedBox(height: 48),
                      _Header(),
                      const SizedBox(height: 40),
                      Expanded(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 200),
                          switchInCurve: Curves.easeOut,
                          switchOutCurve: Curves.easeIn,
                          child: _state == _MagicLinkState.sent
                              ? _buildSentPanel()
                              : _buildFormPanel(),
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.only(top: 16, bottom: 16),
                        child: Text(
                          'Secure sign-in via Supabase',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 11,
                            color: AppColors.textSecondaryOnDark,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildFormPanel() {
    final sending = _state == _MagicLinkState.sending;
    return Column(
      key: const ValueKey('form'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Label above input
        const Padding(
          padding: EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            'Your email',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
              color: AppColors.textSecondaryOnDark,
            ),
          ),
        ),
        TextField(
          controller: _emailController,
          focusNode: _emailFocus,
          enabled: !sending,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
          autocorrect: false,
          enableSuggestions: false,
          autofillHints: const [AutofillHints.email],
          style: const TextStyle(
            fontFamily: 'Inter',
            fontSize: 15,
            color: AppColors.textOnDark,
          ),
          cursorColor: AppColors.primary,
          onChanged: (_) {
            if (_errorText != null) {
              setState(() => _errorText = null);
            }
          },
          onSubmitted: (_) => _passwordFocus.requestFocus(),
          decoration: InputDecoration(
            hintText: 'name@example.com',
            hintStyle: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 15,
              color: AppColors.textSecondaryOnDark,
            ),
            filled: true,
            fillColor: AppColors.surfaceBase,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 14,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              borderSide:
                  const BorderSide(color: AppColors.surfaceBorder),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              borderSide: BorderSide(
                color: _errorText != null
                    ? AppColors.error
                    : AppColors.surfaceBorder,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              borderSide: BorderSide(
                color: _errorText != null
                    ? AppColors.error
                    : AppColors.primary,
                width: 2,
              ),
            ),
            errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              borderSide: const BorderSide(color: AppColors.error, width: 2),
            ),
          ),
        ),
        const SizedBox(height: 16),
        // Password field (optional) — if present, tried before magic-link
        // fallback. Mirrors the portal's SignInGate for R-11 parity.
        const Padding(
          padding: EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            'Password (optional)',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
              color: AppColors.textSecondaryOnDark,
            ),
          ),
        ),
        TextField(
          controller: _passwordController,
          focusNode: _passwordFocus,
          enabled: !sending,
          obscureText: true,
          textInputAction: TextInputAction.go,
          autocorrect: false,
          enableSuggestions: false,
          autofillHints: const [AutofillHints.password],
          style: const TextStyle(
            fontFamily: 'Inter',
            fontSize: 15,
            color: AppColors.textOnDark,
          ),
          cursorColor: AppColors.primary,
          onSubmitted: (_) => _submit(),
          decoration: InputDecoration(
            hintText: 'Skip for a magic-link email',
            hintStyle: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 15,
              color: AppColors.textSecondaryOnDark,
            ),
            filled: true,
            fillColor: AppColors.surfaceBase,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 14,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              borderSide: const BorderSide(color: AppColors.surfaceBorder),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              borderSide:
                  const BorderSide(color: AppColors.surfaceBorder),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              borderSide:
                  const BorderSide(color: AppColors.primary, width: 2),
            ),
          ),
        ),
        if (_errorText != null)
          Padding(
            padding: const EdgeInsets.only(top: 8, left: 4),
            child: Text(
              _errorText!,
              style: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 12,
                color: AppColors.error,
              ),
            ),
          ),
        const SizedBox(height: 16),
        _PrimaryButton(
          label: 'Continue',
          onTap: sending ? null : _submit,
          loading: sending,
        ),
      ],
    );
  }

  Widget _buildSentPanel() {
    final email = _sentToEmail ?? '';
    return Column(
      key: const ValueKey('sent'),
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: const BoxDecoration(
            color: AppColors.brandTintBg,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: const Icon(
            Icons.mark_email_read_outlined,
            color: AppColors.primary,
            size: 32,
          ),
        ),
        const SizedBox(height: 20),
        const Text(
          'Check your inbox',
          style: TextStyle(
            fontFamily: 'Montserrat',
            fontSize: 22,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.3,
            color: AppColors.textOnDark,
          ),
        ),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: RichText(
            textAlign: TextAlign.center,
            text: TextSpan(
              style: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 14,
                fontWeight: FontWeight.w400,
                color: AppColors.textSecondaryOnDark,
                height: 1.5,
              ),
              children: [
                const TextSpan(text: 'We sent a sign-in link to '),
                TextSpan(
                  text: email,
                  style: const TextStyle(
                    color: AppColors.textOnDark,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const TextSpan(
                  text: '. Open it on this device to continue.',
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        TextButton(
          onPressed: _resetForm,
          style: TextButton.styleFrom(
            foregroundColor: AppColors.primary,
            padding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 10,
            ),
          ),
          child: const Text(
            'Use a different email',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: AppColors.primary,
            ),
          ),
        ),
      ],
    );
  }

  /// Tiny multi-colour Google "G" — a plain text/icon placeholder so we
  /// don't pull in a new asset package just for the sign-in button.
  Widget _googleIcon() {
    return Container(
      width: 22,
      height: 22,
      decoration: const BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: const Text(
        'G',
        style: TextStyle(
          fontFamily: 'Montserrat',
          fontSize: 14,
          fontWeight: FontWeight.w800,
          color: Color(0xFF4285F4), // Google blue
          height: 1.1,
        ),
      ),
    );
  }
}

/// Local enum for the magic-link form's state machine.
enum _MagicLinkState { form, sending, sent }

/// Top wordmark + subtitle. Pulled into its own widget so the AnimatedSwitcher
/// below doesn't re-animate the header when the form swaps out.
class _Header extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const HomefitLogo(size: 120),
        const SizedBox(height: 24),
        const Text(
          'homefit.studio',
          style: TextStyle(
            fontFamily: 'Montserrat',
            fontSize: 28,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.5,
            color: AppColors.textOnDark,
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'Sign in to get started',
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 15,
            fontWeight: FontWeight.w400,
            color: AppColors.textSecondaryOnDark,
          ),
        ),
      ],
    );
  }
}

/// Coral-filled primary CTA — bigger and bolder than the secondary provider
/// buttons to anchor the magic-link path as the primary action.
class _PrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final bool loading;

  const _PrimaryButton({
    required this.label,
    required this.onTap,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null && !loading;
    final bg = enabled
        ? AppColors.primary
        : AppColors.primary.withValues(alpha: 0.4);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        onTap: enabled ? onTap : null,
        child: Container(
          height: 52,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          ),
          alignment: Alignment.center,
          child: loading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(Colors.white),
                  ),
                )
              : Text(
                  label,
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
        ),
      ),
    );
  }
}

/// "or continue with" divider between the email form and social providers.
class _OrDivider extends StatelessWidget {
  const _OrDivider();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Expanded(
          child: Divider(
            color: AppColors.surfaceBorder,
            thickness: 1,
            height: 1,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            'or continue with',
            style: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 12,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.3,
              color: AppColors.textSecondaryOnDark,
            ),
          ),
        ),
        const Expanded(
          child: Divider(
            color: AppColors.surfaceBorder,
            thickness: 1,
            height: 1,
          ),
        ),
      ],
    );
  }
}

/// Secondary provider button. `comingSoon` stamps a small pill badge.
class _SignInButton extends StatelessWidget {
  final String label;
  final Widget icon;
  final VoidCallback? onTap;
  final bool loading;
  final bool primary;
  final bool comingSoon;

  const _SignInButton({
    required this.label,
    required this.icon,
    required this.onTap,
    this.loading = false,
    this.primary = false,
    this.comingSoon = false,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null && !loading;
    final bg = primary
        ? (enabled ? AppColors.primary : AppColors.primary.withValues(alpha: 0.4))
        : AppColors.surfaceRaised;
    final fg = primary
        ? Colors.white
        : (enabled ? AppColors.textOnDark : AppColors.textSecondaryOnDark);
    final border = primary
        ? null
        : Border.all(color: AppColors.surfaceBorder);

    return Opacity(
      opacity: enabled ? 1.0 : 0.6,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          onTap: onTap,
          child: Container(
            height: 52,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              border: border,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                SizedBox(width: 22, height: 22, child: Center(child: icon)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: fg,
                    ),
                  ),
                ),
                if (loading)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(Colors.white),
                    ),
                  )
                else if (comingSoon)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceBorder,
                      borderRadius: BorderRadius.circular(100),
                    ),
                    child: const Text(
                      'Coming soon',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textSecondaryOnDark,
                        letterSpacing: 0.3,
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
}


