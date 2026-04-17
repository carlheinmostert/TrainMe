import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../theme.dart';

/// Full-screen sign-in landing. Rendered by the AuthGate when the user has
/// no Supabase session. Once sign-in completes (via OAuth deep-link) the
/// AuthGate swaps this out for the HomeScreen automatically.
///
/// POV auth strategy: social-only. Google is live; Apple is scaffolded but
/// disabled with a "coming soon" badge until Carl finishes the Apple
/// Developer enrolment (Services ID + capability in the Supabase dashboard).
/// Flip [_appleEnabled] to true once that's ready.
class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  /// Toggle this to `true` once Apple Developer enrolment is approved and
  /// Sign in with Apple is wired up in the Supabase dashboard. The button
  /// stays visible either way — we want users to see it's coming — but is
  /// functionally disabled while false.
  static const bool _appleEnabled = false;

  bool _signingIn = false;

  Future<void> _signInWithGoogle() async {
    if (_signingIn) return;
    setState(() => _signingIn = true);
    try {
      await AuthService.instance.signInWithGoogle();
      // The OAuth flow handoff is asynchronous: we return here before the
      // user has actually completed sign-in in the browser. The auth state
      // listener on AuthGate handles the post-callback navigation.
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Sign-in failed: $e')),
      );
      setState(() => _signingIn = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.darkBg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            children: [
              const Spacer(flex: 2),

              // Pulse Mark logo
              SizedBox(
                width: 96,
                height: 64,
                child: CustomPaint(
                  painter: _PulseMarkPainter(color: AppColors.primary),
                ),
              ),
              const SizedBox(height: 24),

              // Wordmark
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

              // Subtitle
              const Text(
                'Sign in to get started',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 15,
                  fontWeight: FontWeight.w400,
                  color: AppColors.textSecondaryOnDark,
                ),
              ),

              const Spacer(flex: 3),

              // Primary: Continue with Google
              _SignInButton(
                label: 'Continue with Google',
                icon: _googleIcon(),
                onTap: _signingIn ? null : _signInWithGoogle,
                loading: _signingIn,
                primary: true,
              ),
              const SizedBox(height: 12),

              // Secondary: Continue with Apple (disabled)
              _SignInButton(
                label: 'Continue with Apple',
                icon: const Icon(
                  Icons.apple,
                  color: AppColors.textSecondaryOnDark,
                  size: 22,
                ),
                onTap: _appleEnabled ? () {} : null,
                primary: false,
                comingSoon: !_appleEnabled,
              ),

              const Spacer(flex: 2),

              // Subtle footer — tiny reassurance, no clutter.
              const Padding(
                padding: EdgeInsets.only(bottom: 16),
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

/// Internal stacked-button used twice on the sign-in screen. Primary (coral)
/// and secondary (outlined) variants. `comingSoon` stamps a small pill badge.
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
        : AppColors.darkSurfaceVariant;
    final fg = primary
        ? Colors.white
        : (enabled ? AppColors.textOnDark : AppColors.textSecondaryOnDark);
    final border = primary
        ? null
        : Border.all(color: AppColors.darkBorder);

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
                      color: AppColors.darkBorder,
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
