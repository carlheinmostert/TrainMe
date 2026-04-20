import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../services/sync_service.dart';
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
  /// Portal URL for the "Top up credits" action. Opens in Safari via
  /// url_launcher in external mode so the practitioner lands in a real
  /// browser session (cookies + Supabase auth intact) and — critically —
  /// Apple Review doesn't see us hosting the credit purchase flow in an
  /// in-app WebView.
  static const _creditsTopUpUrl = 'https://manage.homefit.studio/credits';

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
                      // Current practice name. Even when a practitioner is
                      // only in one practice, surfacing the name at a glance
                      // catches the "wait, which account am I in?" failure
                      // mode. Cross-surface, too: if mobile shows
                      // @icloud/"carlhein Practice" while the portal shows
                      // @me.com/"carlhein Practice" there's nothing in the UI
                      // to distinguish. Will need a switcher (D2 backlog)
                      // once practitioners span multiple practices.
                      ValueListenableBuilder<String?>(
                        valueListenable:
                            AuthService.instance.currentPracticeId,
                        builder: (context, practiceId, _) =>
                            _PracticeRow(practiceId: practiceId),
                      ),
                      _Divider(),
                      // Regular credit balance (purchases + signup bonus −
                      // consumed). Distinct from the "Network rebate" stat
                      // in the Network section below, which shows referral
                      // rebate credits — same RPC contract as the portal's
                      // CreditBalance widget for R-11 parity.
                      ValueListenableBuilder<String?>(
                        valueListenable:
                            AuthService.instance.currentPracticeId,
                        builder: (context, practiceId, _) =>
                            _CreditBalanceRow(practiceId: practiceId),
                      ),
                      _Divider(),
                      // Top-up affordance. Carl's Q1 polish: the balance
                      // row is read-only, so there's no obvious path from
                      // "I'm low on credits" to "buy more". Opens the
                      // portal's /credits page in Safari (NOT an in-app
                      // WebView — Apple review history on payment
                      // WebViews is sticky). Intentionally avoids any
                      // IAP-adjacent verbiage ("top up", not "buy",
                      // "purchase", "subscription") so there's no
                      // misread of in-app purchase intent.
                      _ActionRow(
                        icon: Icons.credit_card_rounded,
                        label: 'Top up credits',
                        subtitle: 'Opens homefit.studio in Safari.',
                        onTap: _signOutPending ? null : _openCreditsTopUp,
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
                  _SectionHeader(label: 'Network'),
                  ValueListenableBuilder<String?>(
                    valueListenable:
                        AuthService.instance.currentPracticeId,
                    builder: (context, practiceId, _) =>
                        _NetworkSection(practiceId: practiceId),
                  ),
                  // Join-a-practice card — mobile R-11 twin of the portal's
                  // /join/{code} landing page. Scope for Wave 5: CLAIM only.
                  // Minting + member management live on the portal.
                  const SizedBox(height: 24),
                  _SectionHeader(label: 'Practices'),
                  const _JoinPracticeCard(),
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
                  // Faint build-SHA marker. Relocated from the Home
                  // footer (Wave 3 #16) — Home is now a brand-forward
                  // surface and doesn't carry the "powered by" footer
                  // anymore. The marker lives here so we can still
                  // confirm at a glance which commit is on device
                  // after a rebuild. Same treatment as the old
                  // PoweredByFooter SHA region: 35% opacity,
                  // JetBrainsMono, ~10px, centred.
                  const SizedBox(height: 24),
                  Center(
                    child: Opacity(
                      opacity: 0.35,
                      child: Text(
                        AppConfig.buildSha,
                        style: const TextStyle(
                          fontFamily: 'JetBrainsMono',
                          fontFamilyFallback: ['Menlo', 'Courier'],
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textSecondaryOnDark,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
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

  /// Opens the portal's /credits page in Safari. External-browser mode
  /// (NOT in-app WebView) so the practitioner arrives at a real browser
  /// session with their Supabase auth cookies intact and — equally
  /// important — Apple Review never sees us hosting a payment WebView.
  /// Silent failure-to-launch surfaces a floating SnackBar with the
  /// same copy the Network section's portal hand-off uses, for
  /// consistency.
  Future<void> _openCreditsTopUp() async {
    HapticFeedback.selectionClick();
    final uri = Uri.parse(_creditsTopUpUrl);
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
          SnackBar(
            content: const Text(
              "Couldn't open the portal. Try again shortly.",
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 14,
                color: AppColors.textOnDark,
              ),
            ),
            backgroundColor: AppColors.surfaceRaised,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 3),
          ),
        );
    }
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

/// Live-fetched credit balance. Mirrors the portal's CreditBalance
/// widget shape: "Credit balance" label + "{N} credits" value. Renders
/// a muted "—" while loading or when the practice id is null. Matches
/// the R-11 portal twin copy exactly so a practitioner bouncing between
/// surfaces sees the same numbers with the same labels.
class _CreditBalanceRow extends StatefulWidget {
  final String? practiceId;
  const _CreditBalanceRow({required this.practiceId});

  @override
  State<_CreditBalanceRow> createState() => _CreditBalanceRowState();
}

class _CreditBalanceRowState extends State<_CreditBalanceRow> {
  int? _balance;
  bool _loading = false;

  /// Epoch-ms stamp on the cached balance, if any. Drives the "Last
  /// synced X ago" hint that surfaces when the cache is more than 5
  /// minutes old.
  int? _cachedSyncedAt;

  String? _loadedForPracticeId;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didUpdateWidget(covariant _CreditBalanceRow old) {
    super.didUpdateWidget(old);
    if (widget.practiceId != old.practiceId) {
      _refresh();
    }
  }

  Future<void> _refresh() async {
    final practiceId = widget.practiceId;
    if (practiceId == null) {
      setState(() {
        _balance = null;
        _loading = false;
        _cachedSyncedAt = null;
        _loadedForPracticeId = null;
      });
      return;
    }

    // Seed from the local cache so the row renders an actual number
    // even offline / before the live fetch resolves.
    try {
      final cached =
          await SyncService.instance.storage.getCachedCreditBalance(practiceId);
      if (!mounted) return;
      if (cached != null) {
        setState(() {
          _balance = cached.balance;
          _cachedSyncedAt = cached.syncedAt;
          _loading = false;
          _loadedForPracticeId = practiceId;
        });
      } else {
        setState(() {
          _loading = true;
          _loadedForPracticeId = practiceId;
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = true;
        _loadedForPracticeId = practiceId;
      });
    }

    // Live fetch. On success, cache + display both update. On failure
    // the cached value (if any) stays on screen.
    try {
      final result = await ApiClient.instance.practiceCreditBalance(
        practiceId: practiceId,
      );
      if (!mounted || _loadedForPracticeId != practiceId) return;
      if (result != null) {
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        await SyncService.instance.storage.upsertCachedCreditBalance(
          practiceId: practiceId,
          balance: result,
          nowMs: nowMs,
        );
        if (!mounted || _loadedForPracticeId != practiceId) return;
        setState(() {
          _balance = result;
          _cachedSyncedAt = nowMs;
          _loading = false;
        });
      } else {
        setState(() {
          _loading = false;
        });
      }
    } catch (_) {
      if (!mounted || _loadedForPracticeId != practiceId) return;
      setState(() {
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    String valueText;
    if (_loading && _balance == null) {
      valueText = '—';
    } else if (_balance == null) {
      valueText = "Couldn't load — tap to retry";
    } else {
      valueText = _balance == 1 ? '1 credit' : '$_balance credits';
    }

    final retryable = !_loading && _balance == null && widget.practiceId != null;

    // Staleness hint: show "Last synced X ago" if we're rendering a
    // cached value and it's older than 5 minutes.
    String? staleHint;
    if (_balance != null && _cachedSyncedAt != null) {
      final diffMs =
          DateTime.now().millisecondsSinceEpoch - _cachedSyncedAt!;
      if (diffMs > const Duration(minutes: 5).inMilliseconds) {
        staleHint = 'Last synced ${_relativeAge(_cachedSyncedAt!)}';
      }
    }

    final row = staleHint == null
        ? _ReadOnlyRow(label: 'Credit balance', value: valueText)
        : _ReadOnlyRowWithHint(
            label: 'Credit balance',
            value: valueText,
            hint: staleHint,
          );
    if (!retryable) return row;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _refresh,
      child: row,
    );
  }

  static String _relativeAge(int epochMs) {
    final diff = DateTime.now()
        .difference(DateTime.fromMillisecondsSinceEpoch(epochMs));
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}

/// Variant of [_ReadOnlyRow] that shows a muted hint line beneath the
/// value (e.g. "Last synced 2h ago" for a stale cache).
class _ReadOnlyRowWithHint extends StatelessWidget {
  final String label;
  final String value;
  final String hint;

  const _ReadOnlyRowWithHint({
    required this.label,
    required this.value,
    required this.hint,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
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
          const SizedBox(height: 3),
          Text(
            hint,
            style: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 11,
              color: AppColors.textSecondaryOnDark,
            ),
          ),
        ],
      ),
    );
  }
}

/// Live-fetched current-practice label. Reads from `listMyPractices`
/// and picks the membership whose id matches the cached current
/// practice. Falls back to the first membership if the cache is empty
/// (bootstrap path — AuthService runs `bootstrap_practice_for_user` on
/// first sign-in which returns exactly one id). Tap-to-retry on error.
///
/// For now every practitioner is in at most one practice, but the
/// widget is stateful so a future practice-switcher (D2) can swap in
/// without restructuring the Settings screen.
class _PracticeRow extends StatefulWidget {
  final String? practiceId;
  const _PracticeRow({required this.practiceId});

  @override
  State<_PracticeRow> createState() => _PracticeRowState();
}

class _PracticeRowState extends State<_PracticeRow> {
  String? _name;
  bool _loading = false;
  bool _errored = false;
  String? _loadedForPracticeId;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didUpdateWidget(covariant _PracticeRow old) {
    super.didUpdateWidget(old);
    if (widget.practiceId != old.practiceId) {
      _refresh();
    }
  }

  Future<void> _refresh() async {
    final practiceId = widget.practiceId;
    setState(() {
      _loading = true;
      _errored = false;
      _loadedForPracticeId = practiceId;
    });

    // Seed from cache.
    try {
      final cached = await SyncService.instance.storage.getCachedPractices();
      if (!mounted || _loadedForPracticeId != practiceId) return;
      if (cached.isNotEmpty) {
        final match = cached.firstWhere(
          (m) => m.id == practiceId,
          orElse: () => cached.first,
        );
        setState(() {
          _name = match.name.isNotEmpty ? match.name : null;
          _loading = false;
          _errored = false;
        });
      }
    } catch (_) {
      // Cache miss — fall through to network.
    }

    try {
      final memberships = await ApiClient.instance.listMyPractices();
      if (!mounted || _loadedForPracticeId != practiceId) return;
      if (memberships.isEmpty) {
        // No network, no cache. Keep loading indicator if we never
        // got cache; otherwise leave cached value on screen.
        setState(() {
          _loading = false;
          _errored = _name == null;
        });
        return;
      }
      final match = memberships.firstWhere(
        (m) => m.id == practiceId,
        orElse: () => memberships.isNotEmpty
            ? memberships.first
            : const PracticeMembership(
                id: '',
                name: '',
                role: PracticeRole.practitioner,
              ),
      );
      setState(() {
        _name = match.name.isNotEmpty ? match.name : _name;
        _loading = false;
        _errored = false;
      });
    } catch (_) {
      if (!mounted || _loadedForPracticeId != practiceId) return;
      setState(() {
        _loading = false;
        // Only flag error if we have no cached value to fall back on.
        _errored = _name == null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    String valueText;
    if (_loading || widget.practiceId == null) {
      valueText = '—';
    } else if (_errored) {
      valueText = 'Couldn\'t load — tap to retry';
    } else {
      valueText = _name ?? '—';
    }
    final retryable = _errored && widget.practiceId != null;
    final row = _ReadOnlyRow(label: 'Practice', value: valueText);
    if (!retryable) return row;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _refresh,
      child: row,
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

// ---------------------------------------------------------------------------
// Network section — mobile twin of the portal's "Your network" +
// "Network earnings" cards (see `web-portal/.../dashboard/...`).
//
// Phone-side role (R-11): practitioners share their invite code in the
// moment, from the clinic. Full network management (referee list,
// anonymisation, rebate ledger detail) stays on desktop. This component
// intentionally mirrors only: invite code + share CTA + compact stats
// row + a link back to the portal.
//
// Voice constraint (per docs/design/project/voice.md):
//   - peer-to-peer ONLY. Never "earn rewards / commission / cash / payout
//     / downline". Positioning: "grow your practitioner network → earn
//     free credits on their spend". Bought credits + free credits are
//     the SAME unit — one currency called "credits", so practitioners
//     connect what they buy with what they get for free.
//   - Stats are credits-as-publishes, not ZAR. Qualifying spend shown in
//     ZAR because that's what the network actually transacted, and
//     surfacing it is load-bearing context for "my network is real".
// ---------------------------------------------------------------------------

/// Referral share + stats card. Self-loading — owns its own async state
/// via two futures (code + stats) so the rest of Settings keeps
/// rendering even while the network call is in flight.
class _NetworkSection extends StatefulWidget {
  final String? practiceId;
  const _NetworkSection({required this.practiceId});

  @override
  State<_NetworkSection> createState() => _NetworkSectionState();
}

class _NetworkSectionState extends State<_NetworkSection> {
  /// Pre-composed peer-to-peer share text. Uses "I use X — you might
  /// find it useful too" framing so the recipient reads it as a
  /// colleague recommendation, not a sales pitch. Interpolates the
  /// practice's short code at the end of the manage-portal /r/ path.
  static const _shareTemplate =
      "I use homefit.studio to share exercise plans with my clients — "
      "you might find it useful too: https://manage.homefit.studio/r/{code}";

  /// Portal URL for the "View full network on the portal" link. Opens
  /// in Safari via url_launcher in external mode so the practitioner
  /// lands in a real browser session (cookies + Supabase auth intact).
  /// Points at /dashboard — that's where the Network share + Network
  /// earnings cards live (PR #6). /account only has password + sign
  /// out + about.
  static const _portalNetworkUrl = 'https://manage.homefit.studio/dashboard';

  Future<String>? _codeFuture;
  Future<ReferralStats>? _statsFuture;

  /// Count of retry attempts for the code fetch. After two failures the
  /// widget surfaces a tappable "Couldn't load — tap to retry" row
  /// instead of looping forever.
  int _codeRetryCount = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didUpdateWidget(covariant _NetworkSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.practiceId != widget.practiceId) {
      _codeRetryCount = 0;
      _refresh();
    }
  }

  void _refresh() {
    final practiceId = widget.practiceId;
    if (practiceId == null) {
      setState(() {
        _codeFuture = null;
        _statsFuture = null;
      });
      return;
    }
    setState(() {
      _codeFuture = ApiClient.instance.ensureReferralCode(practiceId);
      _statsFuture = ApiClient.instance.getReferralStats(practiceId);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.practiceId == null) {
      return _SettingsGroup(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
            child: Text(
              'No practice yet — create one to start your network.',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 13,
                color: AppColors.textSecondaryOnDark,
              ),
            ),
          ),
        ],
      );
    }

    return _SettingsGroup(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Your practitioner network',
                style: TextStyle(
                  fontFamily: 'Montserrat',
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                  color: AppColors.textOnDark,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Invite a colleague — they land with 8 free credits '
                'instead of 3. You earn 5% in free credits for every plan '
                'they ever publish, forever.',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 13,
                  height: 1.45,
                  color: AppColors.textSecondaryOnDark,
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: _CodeAndShare(
            codeFuture: _codeFuture,
            retryCount: _codeRetryCount,
            onRetry: () {
              _codeRetryCount += 1;
              _refresh();
            },
            onShare: _share,
            onCopy: _copyCode,
          ),
        ),
        const _Divider(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: _StatsRow(statsFuture: _statsFuture),
        ),
        const _Divider(),
        InkWell(
          onTap: _openPortal,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text(
                  'View full network on the portal',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.primary,
                  ),
                ),
                const SizedBox(width: 4),
                const Icon(
                  Icons.arrow_forward_rounded,
                  size: 16,
                  color: AppColors.primary,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  Future<String?> _resolveCodeOrNull() async {
    final f = _codeFuture;
    if (f == null) return null;
    try {
      return await f;
    } catch (_) {
      return null;
    }
  }

  Future<void> _copyCode() async {
    final code = await _resolveCodeOrNull();
    if (code == null) return;
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

  /// Opens the iOS share sheet with the pre-composed invite text.
  /// `sharePositionOrigin` is supplied because the share sheet silently
  /// fails on iPad/simulator without it (see CLAUDE.md infrastructure
  /// rules).
  Future<void> _share() async {
    final code = await _resolveCodeOrNull();
    if (code == null || !mounted) return;
    HapticFeedback.selectionClick();
    final text = _shareTemplate.replaceAll('{code}', code);
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null
        ? Rect.zero
        : box.localToGlobal(Offset.zero) & box.size;
    await Share.share(
      text,
      subject: 'homefit.studio — try this with your clients',
      sharePositionOrigin: origin,
    );
  }

  Future<void> _openPortal() async {
    HapticFeedback.selectionClick();
    final uri = Uri.parse(_portalNetworkUrl);
    final launched = await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    );
    if (!launched && mounted) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: const Text(
              "Couldn't open the portal. Try again shortly.",
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 14,
                color: AppColors.textOnDark,
              ),
            ),
            backgroundColor: AppColors.surfaceRaised,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 3),
          ),
        );
    }
  }
}

/// Coral-tinted pill displaying the invite code with a share CTA below.
/// Single tap on the pill copies the code. "Share invite link" opens
/// the iOS share sheet.
class _CodeAndShare extends StatelessWidget {
  final Future<String>? codeFuture;
  final int retryCount;
  final VoidCallback onRetry;
  final VoidCallback onShare;
  final VoidCallback onCopy;

  const _CodeAndShare({
    required this.codeFuture,
    required this.retryCount,
    required this.onRetry,
    required this.onShare,
    required this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: codeFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _CodePill(
                code: '      ',
                onTap: null,
                dim: true,
              ),
              const SizedBox(height: 12),
              _ShareButton(onPressed: null),
            ],
          );
        }
        if (snapshot.hasError) {
          // Two-strike rule: auto-retry once silently on first error by
          // returning a tappable row that wraps the retry callback.
          if (retryCount >= 2) {
            return InkWell(
              onTap: onRetry,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(
                  children: const [
                    Icon(
                      Icons.refresh_rounded,
                      size: 18,
                      color: AppColors.primary,
                    ),
                    SizedBox(width: 8),
                    Text(
                      "Couldn't load — tap to retry",
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.primary,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }
          // Silent first retry on build — trigger once via microtask.
          Future.microtask(onRetry);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _CodePill(code: '      ', onTap: null, dim: true),
              const SizedBox(height: 12),
              _ShareButton(onPressed: null),
            ],
          );
        }
        final code = snapshot.data ?? '';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _CodePill(
              code: code,
              onTap: code.isEmpty ? null : onCopy,
            ),
            const SizedBox(height: 12),
            _ShareButton(onPressed: code.isEmpty ? null : onShare),
          ],
        );
      },
    );
  }
}

class _CodePill extends StatelessWidget {
  final String code;
  final VoidCallback? onTap;
  final bool dim;

  const _CodePill({
    required this.code,
    required this.onTap,
    this.dim = false,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: AppColors.brandTintBg,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: AppColors.brandTintBorder, width: 1),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                code,
                style: TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontFamilyFallback: const ['Menlo', 'Courier'],
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 3,
                  color:
                      dim ? AppColors.textSecondaryOnDark : AppColors.primary,
                ),
              ),
              if (onTap != null) ...[
                const SizedBox(width: 10),
                const Icon(
                  Icons.content_copy_rounded,
                  size: 16,
                  color: AppColors.primary,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ShareButton extends StatelessWidget {
  final VoidCallback? onPressed;
  const _ShareButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: onPressed,
        icon: const Icon(Icons.ios_share_rounded, size: 18),
        label: const Text(
          'Share invite link',
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
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          ),
        ),
      ),
    );
  }
}

/// Four-tile compact stats row. Inter font, small-caps labels, large
/// coral numbers — matches the dashboard tile aesthetic used elsewhere.
/// Lifetime column fades to 50% when zero so it reads as "nothing yet"
/// without being a full empty-state.
class _StatsRow extends StatelessWidget {
  final Future<ReferralStats>? statsFuture;
  const _StatsRow({required this.statsFuture});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ReferralStats>(
      future: statsFuture,
      builder: (context, snapshot) {
        final loading = snapshot.connectionState == ConnectionState.waiting;
        final stats = snapshot.data ?? ReferralStats.empty;
        final hasError = snapshot.hasError;

        if (hasError) {
          // Stats error is low-stakes — render zeros rather than loud red.
          // The share flow doesn't depend on these numbers.
        }

        String fmtInt(num v) => v.round().toString();
        String fmtZar(num v) {
          final i = v.round();
          // Simple thousands separator without pulling intl.
          final s = i.toString();
          final buf = StringBuffer();
          for (var k = 0; k < s.length; k++) {
            if (k > 0 && (s.length - k) % 3 == 0) buf.write(',');
            buf.write(s[k]);
          }
          return buf.toString();
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _StatTile(
                value: loading ? '—' : fmtInt(stats.rebateBalanceCredits),
                // "Network rebate" disambiguates from the regular "Credit
                // balance" shown in the Account section above. Same RPC
                // contract as the portal's Network earnings card — this is
                // the 5% lifetime rebate + signup bonus pool, NOT your
                // main publishing credits.
                label: 'Network rebate',
              ),
            ),
            Expanded(
              child: _StatTile(
                value: loading ? '—' : fmtInt(stats.lifetimeRebateCredits),
                label: 'Rebate lifetime',
                dim: !loading && stats.lifetimeRebateCredits == 0,
              ),
            ),
            Expanded(
              child: _StatTile(
                value: loading ? '—' : fmtInt(stats.refereeCount),
                label: 'In network',
              ),
            ),
            Expanded(
              child: _StatTile(
                value: loading ? '—' : 'R${fmtZar(stats.qualifyingSpendTotalZar)}',
                label: 'Network spend',
              ),
            ),
          ],
        );
      },
    );
  }
}

class _StatTile extends StatelessWidget {
  final String value;
  final String label;
  final bool dim;

  const _StatTile({
    required this.value,
    required this.label,
    this.dim = false,
  });

  @override
  Widget build(BuildContext context) {
    final opacity = dim ? 0.5 : 1.0;
    return Opacity(
      opacity: opacity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: const TextStyle(
              fontFamily: 'Montserrat',
              fontSize: 20,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.4,
              color: AppColors.primary,
            ),
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: AppColors.textSecondaryOnDark,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Join a practice — Wave 5 mobile twin (claim-only)
//
// Mobile scope for Wave 5: CLAIM an existing invite code. Minting codes
// and managing members lives exclusively on the portal for now. This
// card is a 7-char text input + "Join" button; on success it switches
// to the newly-joined practice and fires a SnackBar.
// ---------------------------------------------------------------------------

class _JoinPracticeCard extends StatefulWidget {
  const _JoinPracticeCard();

  @override
  State<_JoinPracticeCard> createState() => _JoinPracticeCardState();
}

class _JoinPracticeCardState extends State<_JoinPracticeCard> {
  final _controller = TextEditingController();
  bool _submitting = false;
  String? _inlineError;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Force-upper-case + strip whitespace. Codes are drawn from the
  /// unambiguous-alphabet pattern (A-Z2-9 minus 0/O/I/1/l), so we
  /// transparently canonicalise user input rather than rejecting it.
  String _normalise(String v) =>
      v.replaceAll(RegExp(r'\s+'), '').toUpperCase();

  Future<void> _submit() async {
    final raw = _controller.text;
    final code = _normalise(raw);
    if (code.length != 7) {
      setState(() => _inlineError = 'Codes are 7 characters long.');
      return;
    }

    HapticFeedback.selectionClick();
    setState(() {
      _submitting = true;
      _inlineError = null;
    });

    try {
      final result = await ApiClient.instance.claimPracticeInvite(code);
      if (!mounted) return;

      // Flip the active practice to the newly-joined one so the rest of
      // the app picks up its credit balance / clients / sessions on the
      // next frame.
      await AuthService.instance.selectPractice(result.practiceId);
      // Best-effort cache refresh for the new practice so Home /
      // ClientSessions don't render stale data for a moment.
      try {
        await SyncService.instance.pullAll(result.practiceId);
      } catch (_) {
        // Non-fatal — cache will catch up on next pull.
      }

      if (!mounted) return;
      _controller.clear();
      setState(() => _submitting = false);

      final label = result.practiceName.isNotEmpty
          ? result.practiceName
          : 'that practice';
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(
              'Joined $label',
              style: const TextStyle(
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
    } on ClaimInviteError catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _inlineError = _mapClaimError(e);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _inlineError = 'Something went wrong — try again.';
      });
      debugPrint('claimPracticeInvite unexpected error: $e');
    }
  }

  static String _mapClaimError(ClaimInviteError e) {
    switch (e.kind) {
      case ClaimInviteErrorKind.invalidOrUsed:
        return "That code's invalid or already been used.";
      case ClaimInviteErrorKind.invalid:
        return 'Codes are 7 characters long.';
      case ClaimInviteErrorKind.auth:
        return 'Your session expired — sign in again.';
      case ClaimInviteErrorKind.unknown:
        return 'Something went wrong — try again.';
    }
  }

  @override
  Widget build(BuildContext context) {
    return _SettingsGroup(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              Text(
                'Join a practice',
                style: TextStyle(
                  fontFamily: 'Montserrat',
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                  color: AppColors.textOnDark,
                ),
              ),
              SizedBox(height: 6),
              Text(
                "Enter the 7-character code a colleague shared with you. "
                "You'll be added as a practitioner.",
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 13,
                  height: 1.45,
                  color: AppColors.textSecondaryOnDark,
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _controller,
                enabled: !_submitting,
                autocorrect: false,
                textCapitalization: TextCapitalization.characters,
                // Unambiguous alphabet — same uppercase-letters + digits
                // set the mint function uses. Force uppercase on input
                // so paste from email/WhatsApp still works cleanly.
                inputFormatters: [
                  FilteringTextInputFormatter.allow(
                    RegExp(r'[A-Za-z0-9]'),
                  ),
                  LengthLimitingTextInputFormatter(7),
                  TextInputFormatter.withFunction((oldValue, newValue) {
                    return newValue.copyWith(
                      text: newValue.text.toUpperCase(),
                      selection: newValue.selection,
                    );
                  }),
                ],
                style: const TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontFamilyFallback: ['Menlo', 'Courier'],
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 3,
                  color: AppColors.textOnDark,
                ),
                decoration: InputDecoration(
                  hintText: 'ABC2XYZ',
                  hintStyle: const TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontFamilyFallback: ['Menlo', 'Courier'],
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 3,
                    color: AppColors.grey600,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                  filled: true,
                  fillColor: AppColors.surfaceRaised,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                    borderSide: const BorderSide(
                      color: AppColors.surfaceBorder,
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                    borderSide: const BorderSide(
                      color: AppColors.surfaceBorder,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                    borderSide: const BorderSide(
                      color: AppColors.primary,
                      width: 2,
                    ),
                  ),
                ),
                onSubmitted: (_) => _submit(),
              ),
              if (_inlineError != null) ...[
                const SizedBox(height: 8),
                Text(
                  _inlineError!,
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: AppColors.error,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _submitting ? null : _submit,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: AppColors.surfaceRaised,
                  disabledForegroundColor: AppColors.textSecondaryOnDark,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                  ),
                ),
                child: Text(
                  _submitting ? 'Joining…' : 'Join',
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
