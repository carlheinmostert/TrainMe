import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthApiException, AuthException;

import '../services/auth_service.dart';
import '../theme.dart';

/// Full-screen sign-in landing. Rendered by the AuthGate when the user has
/// no Supabase session. Once sign-in completes (either a password login or
/// the magic-link deep-link fires) the AuthGate swaps this out for the
/// HomeScreen automatically.
///
/// Progressive-auth strategy:
///
///   - Email + password is the fast-return path. If the user already has
///     a password set (via [AuthService.setPassword] on Home), typing both
///     fields and tapping Sign in signs them in immediately.
///   - If they leave the password blank, Sign in falls through to a magic
///     link on the email field (signup-or-signin in one API call).
///   - If they type a password and it's wrong, we show an inline error
///     plus a "Forgot password? Get a magic link." link that triggers the
///     same OTP flow.
///   - Google + Apple are NOT surfaced here. Their `AuthService` paths
///     remain wired for future re-enablement — see
///     `docs/BACKLOG_GOOGLE_SIGNIN.md`.
class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final FocusNode _emailFocus = FocusNode();
  final FocusNode _passwordFocus = FocusNode();

  /// UI state machine:
  ///   - [_SignInState.form]      — inputs visible, primary CTA idle
  ///   - [_SignInState.submitting] — network call in flight
  ///   - [_SignInState.sent]       — magic-link confirmation panel
  _SignInState _state = _SignInState.form;

  /// The email we sent the magic link to (displayed in the confirmation
  /// panel).
  String? _sentToEmail;

  /// Inline error shown beneath the password field. Null when clean.
  String? _errorText;

  /// Whether we should show the "Forgot password? Get a magic link." link.
  /// Surfaced only after the first bad-credentials attempt so first-time
  /// signup users don't see it.
  bool _showForgotLink = false;

  /// Password field visibility toggle.
  bool _passwordObscured = true;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _emailFocus.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  // ── Primary submit ──────────────────────────────────────────────────────

  /// Handle the Sign in CTA.
  ///
  /// Routing:
  ///   - Password empty → send magic link.
  ///   - Password filled → try password first; on failure fall back to
  ///     a clear error + "Forgot password?" link (magic-link is a tap
  ///     away, not an automatic cascade — auto-cascading would mask typos
  ///     and train users to ignore their password).
  Future<void> _onSignInPressed() async {
    if (_state == _SignInState.submitting) return;
    unawaited(HapticFeedback.selectionClick());

    final email = _emailController.text.trim().toLowerCase();
    final password = _passwordController.text;

    if (email.isEmpty || !email.contains('@')) {
      setState(() {
        _errorText = "We don't recognise that email address.";
      });
      return;
    }

    if (password.isEmpty) {
      await _sendMagicLink(email);
      return;
    }

    setState(() {
      _state = _SignInState.submitting;
      _errorText = null;
    });

    try {
      await AuthService.instance.signInWithPassword(email, password);
      // Success — AuthGate swaps us out once the session lands. Keep the
      // button in the submitting state until then so the screen doesn't
      // flash back to idle for a frame.
      if (!mounted) return;
      unawaited(HapticFeedback.mediumImpact());
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _state = _SignInState.form;
        _errorText = _friendlyAuthError(e);
        _showForgotLink = _isBadCredentials(e);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _state = _SignInState.form;
        _errorText = "Couldn't sign you in.";
        _showForgotLink = true;
      });
    }
  }

  /// Send the magic link to the given email and advance to the "sent"
  /// confirmation panel.
  Future<void> _sendMagicLink(String email) async {
    setState(() {
      _state = _SignInState.submitting;
      _errorText = null;
    });
    try {
      await AuthService.instance.sendMagicLink(email);
      if (!mounted) return;
      unawaited(HapticFeedback.mediumImpact());
      setState(() {
        _state = _SignInState.sent;
        _sentToEmail = email;
      });
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _state = _SignInState.form;
        _errorText = _friendlyAuthError(e);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _state = _SignInState.form;
        _errorText = "Couldn't send link. Try again.";
      });
    }
  }

  /// Secondary inline link: "Send me a magic link instead".
  Future<void> _onMagicLinkInsteadPressed() async {
    if (_state == _SignInState.submitting) return;
    final email = _emailController.text.trim().toLowerCase();
    if (email.isEmpty || !email.contains('@')) {
      setState(() {
        _errorText = "We don't recognise that email address.";
      });
      _emailFocus.requestFocus();
      return;
    }
    await _sendMagicLink(email);
  }

  /// Is this AuthException a "wrong password" signal? Used to decide
  /// whether to show the "Forgot password?" link.
  bool _isBadCredentials(AuthException e) {
    if (e is AuthApiException) {
      final code = e.code?.toLowerCase() ?? '';
      if (code.contains('invalid_credentials')) return true;
      if (code.contains('invalid_grant')) return true;
    }
    final msg = e.message.toLowerCase();
    if (msg.contains('invalid login credentials')) return true;
    if (msg.contains('invalid password')) return true;
    return false;
  }

  /// Map Supabase AuthException messages onto short, on-voice copy per
  /// voice.md's error-message formula (what happened · what to do).
  String _friendlyAuthError(AuthException e) {
    if (_isBadCredentials(e)) {
      return "Couldn't sign you in.";
    }
    final msg = e.message.toLowerCase();
    if (msg.contains('rate') || msg.contains('too many')) {
      return 'Too many requests. Wait a moment and try again.';
    }
    if (msg.contains('invalid') && msg.contains('email')) {
      return "We don't recognise that email address.";
    }
    if (msg.contains('email not confirmed')) {
      return 'Check your inbox to confirm this email first.';
    }
    return "Couldn't sign you in.";
  }

  void _resetForm() {
    setState(() {
      _state = _SignInState.form;
      _errorText = null;
      _sentToEmail = null;
      _showForgotLink = false;
      _passwordController.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _emailFocus.requestFocus();
    });
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
                          child: _state == _SignInState.sent
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
    final submitting = _state == _SignInState.submitting;
    return Column(
      key: const ValueKey('form'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Email label + field
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
          enabled: !submitting,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
          autocorrect: false,
          enableSuggestions: false,
          autofillHints: const [AutofillHints.email, AutofillHints.username],
          style: const TextStyle(
            fontFamily: 'Inter',
            fontSize: 15,
            color: AppColors.textOnDark,
          ),
          cursorColor: AppColors.primary,
          onChanged: (_) {
            if (_errorText != null) {
              setState(() {
                _errorText = null;
                _showForgotLink = false;
              });
            }
          },
          onSubmitted: (_) => _passwordFocus.requestFocus(),
          decoration: _fieldDecoration(
            hint: 'name@example.com',
            hasError: false,
          ),
        ),
        const SizedBox(height: 16),
        // Password label + field
        const Padding(
          padding: EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            'Password',
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
          enabled: !submitting,
          obscureText: _passwordObscured,
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
          onChanged: (_) {
            if (_errorText != null) {
              setState(() {
                _errorText = null;
                _showForgotLink = false;
              });
            }
          },
          onSubmitted: (_) => _onSignInPressed(),
          decoration: _fieldDecoration(
            hint: 'Optional — leave blank for a magic link',
            hasError: _errorText != null,
            suffix: IconButton(
              onPressed: submitting
                  ? null
                  : () => setState(
                        () => _passwordObscured = !_passwordObscured,
                      ),
              splashRadius: 20,
              icon: Icon(
                _passwordObscured
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
                size: 20,
                color: AppColors.textSecondaryOnDark,
              ),
              tooltip: _passwordObscured ? 'Show password' : 'Hide password',
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
        if (_showForgotLink) ...[
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: submitting ? null : _onMagicLinkInsteadPressed,
              style: TextButton.styleFrom(
                foregroundColor: AppColors.primary,
                padding: const EdgeInsets.symmetric(
                  horizontal: 4,
                  vertical: 4,
                ),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text(
                'Forgot password? Get a magic link.',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
        const SizedBox(height: 20),
        _PrimaryButton(
          label: 'Sign in',
          onTap: submitting ? null : _onSignInPressed,
          loading: submitting,
        ),
        const SizedBox(height: 12),
        // Secondary inline link — always visible, always a one-tap magic
        // link. Lives below the primary so the fast-return path (password)
        // is the obvious first choice.
        Center(
          child: TextButton(
            onPressed: submitting ? null : _onMagicLinkInsteadPressed,
            style: TextButton.styleFrom(
              foregroundColor: AppColors.textSecondaryOnDark,
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 8,
              ),
            ),
            child: const Text(
              'Send me a magic link instead',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Shared [InputDecoration] factory for both fields. Keeps the look
  /// aligned with the Text Input spec in `docs/design/project/components.md`.
  InputDecoration _fieldDecoration({
    required String hint,
    required bool hasError,
    Widget? suffix,
  }) {
    return InputDecoration(
      hintText: hint,
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
      suffixIcon: suffix,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        borderSide: const BorderSide(color: AppColors.surfaceBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        borderSide: BorderSide(
          color: hasError ? AppColors.error : AppColors.surfaceBorder,
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        borderSide: BorderSide(
          color: hasError ? AppColors.error : AppColors.primary,
          width: 2,
        ),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        borderSide: const BorderSide(color: AppColors.error, width: 2),
      ),
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
}

/// Local enum for the sign-in form's state machine.
enum _SignInState { form, submitting, sent }

/// Top wordmark + subtitle. Pulled into its own widget so the AnimatedSwitcher
/// below doesn't re-animate the header when the form swaps out.
class _Header extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SizedBox(
          width: 96,
          height: 64,
          child: CustomPaint(
            painter: _PulseMarkPainter(color: AppColors.primary),
          ),
        ),
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

/// Coral-filled primary CTA — anchors Sign in as the primary action.
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

/// Pulse Mark — heartbeat line tracing a house roof silhouette.
/// Duplicated from `powered_by_footer.dart` because that file's painter is
/// private. Kept verbatim to stay in visual lock-step.
class _PulseMarkPainter extends CustomPainter {
  final Color color;
  _PulseMarkPainter({this.color = AppColors.primary});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 3.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final path = Path();
    final w = size.width;
    final h = size.height;
    path.moveTo(w * 0.05, h * 0.7);
    path.lineTo(w * 0.25, h * 0.7);
    path.lineTo(w * 0.35, h * 0.2);
    path.lineTo(w * 0.5, h * 0.8);
    path.lineTo(w * 0.65, h * 0.2);
    path.lineTo(w * 0.75, h * 0.7);
    path.lineTo(w * 0.95, h * 0.7);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
