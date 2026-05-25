import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../services/portal_links.dart';
import '../services/safe_mode_subscription_service.dart';
import '../theme.dart';

/// Bottom-sheet paywall shown when the practitioner tries to capture
/// inside an enforcing Safe Mode geofence without an active subscription
/// or trial. Reader-App compliant — no in-app prices and no in-app
/// Subscribe button on the post-trial path.
///
/// Two states:
///   * First-time:        "Start free trial" CTA — calls
///                        `start_safe_mode_trial(auth.uid())`. On
///                        success the bottom sheet dismisses with
///                        result `true` so the caller can retry the
///                        capture entry path.
///   * Trial used already: copy switches to "Subscribe at
///                        manage.homefit.studio" with a deep-link
///                        button that opens the portal's
///                        `/safe-mode` page. Returns `false`.
///
/// Mounted via [showSafeModePaywallSheet] which returns a Future<bool>
/// telling the caller whether the gate was cleared (true = trial was
/// just started; false = user cancelled or was sent to the portal).
///
/// R-01 (no modal confirmations) is honoured — this sheet is a bottom
/// sheet that the user can swipe away at any time; the "Not now"
/// button is a soft dismiss, not a confirmation step.
class SafeModePaywallSheet extends StatefulWidget {
  const SafeModePaywallSheet({
    super.key,
    required this.premisesName,
    this.trialAlreadyUsed = false,
  });

  /// Human-readable premises name to show in the copy (e.g. "Powerhouse
  /// Gym"). Falls back to "this venue" when blank.
  final String premisesName;

  /// When true, the sheet skips the "Start free trial" path and goes
  /// straight to "Subscribe at manage.homefit.studio". Callers that
  /// know the user has already had their lifetime trial can pass
  /// `true` to avoid the wasted RPC round-trip.
  final bool trialAlreadyUsed;

  @override
  State<SafeModePaywallSheet> createState() => _SafeModePaywallSheetState();
}

class _SafeModePaywallSheetState extends State<SafeModePaywallSheet> {
  bool _starting = false;
  bool _showSubscribePath = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _showSubscribePath = widget.trialAlreadyUsed;
  }

  String get _displayName {
    final trimmed = widget.premisesName.trim();
    if (trimmed.isEmpty) return 'this venue';
    return trimmed;
  }

  Future<void> _onStartTrial() async {
    if (_starting) return;
    final uid = AuthService.instance.currentUserId;
    if (uid == null) {
      setState(() {
        _errorMessage = 'Sign in to start your trial.';
      });
      return;
    }

    setState(() {
      _starting = true;
      _errorMessage = null;
    });

    HapticFeedback.selectionClick();

    try {
      final started = await ApiClient.instance.startSafeModeTrial(userId: uid);
      if (!mounted) return;
      if (started) {
        // Refresh the cached sub status so the next gate check returns
        // true immediately without another network round-trip.
        await SafeModeSubscriptionService.instance.refresh();
        if (!mounted) return;
        Navigator.of(context).pop(true);
        return;
      }
      // Trial was already used — swap to the subscription path.
      setState(() {
        _showSubscribePath = true;
        _starting = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _starting = false;
        _errorMessage = "Couldn't start the trial. Try again shortly.";
      });
    }
  }

  Future<void> _onOpenPortal() async {
    HapticFeedback.selectionClick();
    final uri = portalLink('/safe-mode/subscribe');
    bool launched = false;
    try {
      launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      launched = false;
    }
    if (!mounted) return;
    if (launched) {
      Navigator.of(context).pop(false);
    } else {
      setState(() {
        _errorMessage = "Couldn't open Safari. Try again shortly.";
      });
    }
  }

  void _onNotNow() {
    HapticFeedback.selectionClick();
    Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final bottomInset =
        mediaQuery.viewInsets.bottom + mediaQuery.padding.bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 20 + bottomInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Drag handle for affordance.
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.textOnDark.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Safe Mode subscription required to capture here',
            style: TextStyle(
              fontFamily: 'Montserrat',
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AppColors.textOnDark,
              height: 1.25,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            "You're at $_displayName. Captures inside protected spaces use "
            'Safe Mode (which blurs anyone else around you).',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: AppColors.textOnDark.withValues(alpha: 0.82),
              height: 1.5,
            ),
          ),
          const SizedBox(height: 12),
          _showSubscribePath ? _subscribeCopy() : _trialCopy(),
          if (_errorMessage != null) ...[
            const SizedBox(height: 10),
            Text(
              _errorMessage!,
              style: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.primary,
                height: 1.4,
              ),
            ),
          ],
          const SizedBox(height: 24),
          _showSubscribePath ? _subscribeActions() : _trialActions(),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  Widget _trialCopy() {
    return Text(
      'Try Safe Mode free for 3 days — then 4 credits / month to keep going.',
      style: TextStyle(
        fontFamily: 'Inter',
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: AppColors.textOnDark.withValues(alpha: 0.92),
        height: 1.45,
      ),
    );
  }

  Widget _subscribeCopy() {
    return Text(
      'Your free trial is used. Subscribe at manage.homefit.studio to keep '
      'capturing here.',
      style: TextStyle(
        fontFamily: 'Inter',
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: AppColors.textOnDark.withValues(alpha: 0.92),
        height: 1.45,
      ),
    );
  }

  Widget _trialActions() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton(
          onPressed: _starting ? null : _onStartTrial,
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.primary,
            foregroundColor: AppColors.surfaceBg,
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            textStyle: const TextStyle(
              fontFamily: 'Montserrat',
              fontSize: 15,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
            ),
          ),
          child: _starting
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.surfaceBg,
                  ),
                )
              : const Text('Start free trial'),
        ),
        const SizedBox(height: 10),
        TextButton(
          onPressed: _starting ? null : _onNotNow,
          style: TextButton.styleFrom(
            foregroundColor: AppColors.textOnDark,
            padding: const EdgeInsets.symmetric(vertical: 12),
            textStyle: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          child: const Text('Not now'),
        ),
      ],
    );
  }

  Widget _subscribeActions() {
    // Reader-App compliance (feedback_ios_reader_app) — the in-app
    // button does NOT say "Subscribe" or surface a price. It just
    // deep-links into the portal where the actual subscription flow
    // happens. The portal page is the surface that talks to the user
    // about credits / price / consent.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton(
          onPressed: _onOpenPortal,
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.primary,
            foregroundColor: AppColors.surfaceBg,
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            textStyle: const TextStyle(
              fontFamily: 'Montserrat',
              fontSize: 15,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
            ),
          ),
          child: const Text('Open manage.homefit.studio'),
        ),
        const SizedBox(height: 10),
        TextButton(
          onPressed: _onNotNow,
          style: TextButton.styleFrom(
            foregroundColor: AppColors.textOnDark,
            padding: const EdgeInsets.symmetric(vertical: 12),
            textStyle: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          child: const Text('Not now'),
        ),
      ],
    );
  }
}

/// Show the paywall as a Material bottom sheet. Returns true iff the
/// trial was successfully started in-sheet (the caller should retry
/// capture entry). False on dismiss or portal hand-off.
Future<bool> showSafeModePaywallSheet({
  required BuildContext context,
  required String premisesName,
  bool trialAlreadyUsed = false,
}) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surfaceRaised,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetContext) {
      return SafeModePaywallSheet(
        premisesName: premisesName,
        trialAlreadyUsed: trialAlreadyUsed,
      );
    },
  );
  return result ?? false;
}
