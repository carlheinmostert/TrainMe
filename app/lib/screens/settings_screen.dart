import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config.dart';
import '../services/auth_service.dart';
import '../theme.dart';
import '../widgets/powered_by_footer.dart';
import '../widgets/set_password_sheet.dart';
import '../widgets/undo_snackbar.dart';

/// Persistent home for account-level actions the practitioner needs
/// access to at any time — primarily "set or change password" so a
/// magic-link-only user can adopt a password without depending on the
/// one-time home-screen banner.
///
/// Design intent (per docs/design/project/components.md + R-01..R-09):
///   - Dark surface, coral accent only (no competing colours).
///   - Plain tappable rows — no nested menus (R-09: defaults must be
///     obvious). Tap the row → fires the primary action immediately.
///   - Sign-out is destructive but fires IMMEDIATELY with a 3-second
///     undo SnackBar (R-01: no modal confirmations). Cancelling the
///     pending sign-out before the timer elapses aborts cleanly.
///   - R-02 (header purity): the app-bar is title + back button only.
///     Action rows live in the body.
///
/// This screen is deliberately minimal. Scope creep (notifications,
/// theme, locale, etc.) belongs in follow-up work.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  /// Number of times the version row has been tapped in the current
  /// screen lifetime. Seven taps flips [_diagnosticsVisible] on — same
  /// spirit as the Android "Developer options" easter egg. Reset on
  /// every fresh screen open so the debug panel stays out of the way
  /// during normal use.
  int _versionTapCount = 0;
  bool _diagnosticsVisible = false;

  /// Active sign-out countdown state. While non-null the row shows a
  /// "Signing out… Undo" affordance via the SnackBar; cancelling flips
  /// this back to null without calling `signOut()`.
  bool _signOutPending = false;

  @override
  Widget build(BuildContext context) {
    final user = AuthService.instance.currentSession?.user;
    final email = user?.email ?? '—';

    return Scaffold(
      backgroundColor: AppColors.surfaceBg,
      appBar: AppBar(
        backgroundColor: AppColors.surfaceBg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text(
          'Settings',
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
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  _SectionHeader(label: 'Account'),
                  _SettingsGroup(
                    children: [
                      _ReadOnlyRow(
                        label: 'Signed in as',
                        value: email,
                      ),
                      _Divider(),
                      _ActionRow(
                        icon: Icons.lock_outline_rounded,
                        label: 'Set or change password',
                        subtitle:
                            'Skip the magic-link email on future sign-ins.',
                        onTap: _signOutPending ? null : _openPasswordSheet,
                      ),
                      _Divider(),
                      _ActionRow(
                        icon: Icons.logout_rounded,
                        label: 'Sign out',
                        destructive: true,
                        onTap: _signOutPending ? null : _signOutWithUndo,
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  _SectionHeader(label: 'About'),
                  _SettingsGroup(
                    children: [
                      _VersionRow(
                        version: '0.1.0',
                        shortSha: AppConfig.buildSha,
                        onTap: _handleVersionTap,
                      ),
                      if (_diagnosticsVisible) ...[
                        _Divider(),
                        _DiagnosticsPanel(
                          userId: user?.id,
                          practiceId:
                              AuthService.instance.currentPracticeId.value,
                          buildSha: AppConfig.buildSha,
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const PoweredByFooter(),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  Future<void> _openPasswordSheet() async {
    HapticFeedback.selectionClick();
    final saved = await SetPasswordSheet.show(context);
    if (!mounted || !saved) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: const Text(
            'Password saved',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 14,
              color: AppColors.textOnDark,
            ),
          ),
          backgroundColor: AppColors.surfaceRaised,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: AppColors.surfaceBorder),
          ),
        ),
      );
  }

  /// R-01: fire the destructive action immediately, surface an Undo
  /// SnackBar. In this case "immediately" means: arm a 3-second timer;
  /// if the user taps Undo before it fires, abort. If the timer elapses
  /// unchallenged, call [AuthService.signOut]. AuthGate watches the
  /// session stream and swaps to SignInScreen automatically — no manual
  /// Navigator push needed here.
  ///
  /// Using the existing brand snackbar widget so voice and chrome match
  /// the rest of the app's destructive-action treatments.
  Future<void> _signOutWithUndo() async {
    if (_signOutPending) return;
    HapticFeedback.selectionClick();
    setState(() => _signOutPending = true);

    bool cancelled = false;
    showUndoSnackBar(
      context,
      label: 'Signing out…',
      duration: const Duration(seconds: 3),
      onUndo: () {
        cancelled = true;
        if (mounted) setState(() => _signOutPending = false);
      },
    );

    await Future<void>.delayed(const Duration(seconds: 3));
    if (cancelled) return;
    if (!mounted) {
      // Screen disposed mid-wait — still honour the intent.
      await AuthService.instance.signOut();
      return;
    }

    try {
      await AuthService.instance.signOut();
      // AuthGate swaps the tree to SignInScreen on the next auth-state
      // event. No Navigator.pop needed — the screen gets unmounted.
    } catch (e) {
      if (!mounted) return;
      setState(() => _signOutPending = false);
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(
              'Sign out failed: $e',
              style: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 14,
                color: Colors.white,
              ),
            ),
            backgroundColor: AppColors.error,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 4),
          ),
        );
    }
  }

  void _handleVersionTap() {
    HapticFeedback.selectionClick();
    setState(() {
      _versionTapCount += 1;
      if (_versionTapCount >= 7 && !_diagnosticsVisible) {
        _diagnosticsVisible = true;
      }
    });
  }
}

// ---------------------------------------------------------------------------
// Private helpers — local to this screen so the Settings layout stays
// self-contained and the file remains scannable end-to-end.
// ---------------------------------------------------------------------------

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
      child: Text(
        label.toUpperCase(),
        style: const TextStyle(
          fontFamily: 'Inter',
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.0,
          color: AppColors.textSecondaryOnDark,
        ),
      ),
    );
  }
}

class _SettingsGroup extends StatelessWidget {
  final List<Widget> children;
  const _SettingsGroup({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceBase,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: AppColors.surfaceBorder, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) {
    return const Divider(
      height: 1,
      thickness: 1,
      color: AppColors.surfaceBorder,
    );
  }
}

class _ReadOnlyRow extends StatelessWidget {
  final String label;
  final String value;
  const _ReadOnlyRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                    color: AppColors.textSecondaryOnDark,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: AppColors.textOnDark,
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

class _ActionRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? subtitle;
  final VoidCallback? onTap;
  final bool destructive;

  const _ActionRow({
    required this.icon,
    required this.label,
    this.subtitle,
    this.onTap,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final labelColor = !enabled
        ? AppColors.grey600
        : destructive
            ? AppColors.error
            : AppColors.textOnDark;
    final iconColor = !enabled
        ? AppColors.grey600
        : destructive
            ? AppColors.error
            : AppColors.primary;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(icon, size: 20, color: iconColor),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: labelColor,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        style: const TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 12,
                          color: AppColors.textSecondaryOnDark,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (enabled && !destructive)
                const Icon(
                  Icons.chevron_right_rounded,
                  color: AppColors.grey500,
                  size: 22,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VersionRow extends StatelessWidget {
  final String version;
  final String shortSha;
  final VoidCallback onTap;

  const _VersionRow({
    required this.version,
    required this.shortSha,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'Version',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textOnDark,
                  ),
                ),
              ),
              Text(
                '$version · $shortSha',
                style: const TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontFamilyFallback: ['Menlo', 'Courier'],
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: AppColors.textSecondaryOnDark,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Diagnostic panel unlocked by tapping the Version row seven times.
/// Surfaces the signed-in user UUID, current practice UUID, and full
/// build SHA. Each row is tappable to copy the value to clipboard —
/// same pattern as the error-SnackBar copy behaviour elsewhere.
class _DiagnosticsPanel extends StatelessWidget {
  final String? userId;
  final String? practiceId;
  final String buildSha;

  const _DiagnosticsPanel({
    required this.userId,
    required this.practiceId,
    required this.buildSha,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Diagnostics',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
              color: AppColors.primary,
            ),
          ),
          const SizedBox(height: 10),
          _DiagRow(label: 'User ID', value: userId ?? '—'),
          const SizedBox(height: 8),
          _DiagRow(label: 'Practice ID', value: practiceId ?? '—'),
          const SizedBox(height: 8),
          _DiagRow(label: 'Build SHA', value: buildSha),
        ],
      ),
    );
  }
}

class _DiagRow extends StatelessWidget {
  final String label;
  final String value;

  const _DiagRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: value == '—'
          ? null
          : () async {
              await Clipboard.setData(ClipboardData(text: value));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context)
                ..clearSnackBars()
                ..showSnackBar(
                  SnackBar(
                    content: Text(
                      '$label copied',
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
            },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 96,
              child: Text(
                label,
                style: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textSecondaryOnDark,
                ),
              ),
            ),
            Expanded(
              child: Text(
                value,
                style: const TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontFamilyFallback: ['Menlo', 'Courier'],
                  fontSize: 12,
                  color: AppColors.textOnDark,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
