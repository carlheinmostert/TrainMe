import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../services/sync_service.dart';
import '../theme.dart';

/// Bottom sheet that lists the practices the signed-in practitioner
/// belongs to, shows the current selection, and lets them switch.
///
/// Mobile twin of the web portal's dashboard `PracticeSwitcher.tsx`
/// (R-11). Capability set must match:
///   - See every practice the user is a member of.
///   - See which one is currently active.
///   - Switch to another with a single tap.
///
/// Disambiguation for same-named practices: each row shows
/// "{N} credits · {role}" as a secondary line. Balance comes from the
/// existing `practiceCreditBalance` RPC — two practices named "carlhein
/// Practice" with different credit totals read as distinct to the eye.
///
/// Sign-out lives below the list because (a) it's a destructive
/// account-level action that belongs with identity, and (b) Carl's been
/// bouncing between auth accounts today; a one-tap sign-out here saves a
/// trip through Settings. Fires immediately with a 3-second undo
/// SnackBar per R-01.
class PracticeSwitcherSheet extends StatefulWidget {
  final List<PracticeMembership> memberships;
  final String? currentPracticeId;

  /// Messenger captured from the calling site (the chip's parent
  /// Scaffold). The sheet pops itself before firing the Undo SnackBar,
  /// so the sheet's own context is stale by the time we need a
  /// messenger — the caller threads its own.
  final ScaffoldMessengerState? parentMessenger;

  const PracticeSwitcherSheet({
    super.key,
    required this.memberships,
    required this.currentPracticeId,
    required this.parentMessenger,
  });

  /// Show the sheet. Returns when the user dismisses or switches. All
  /// actions are performed on [AuthService.instance] directly — the
  /// caller doesn't need to read the result.
  static Future<void> show(
    BuildContext context, {
    required List<PracticeMembership> memberships,
    required String? currentPracticeId,
  }) {
    // Capture the parent messenger *before* the sheet opens so sign-out
    // can surface its undo SnackBar after the sheet pops.
    final messenger = ScaffoldMessenger.maybeOf(context);
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surfaceBase,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      // Allow the sheet to grow tall if the practitioner is in lots of
      // practices; draggable handle lets them dismiss naturally.
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => PracticeSwitcherSheet(
        memberships: memberships,
        currentPracticeId: currentPracticeId,
        parentMessenger: messenger,
      ),
    );
  }

  @override
  State<PracticeSwitcherSheet> createState() => _PracticeSwitcherSheetState();
}

class _PracticeSwitcherSheetState extends State<PracticeSwitcherSheet> {
  /// Per-practice credit balance cache, keyed by practice id. Fetched
  /// once on mount; a null value means the RPC errored or hasn't
  /// returned yet (UI renders "— credits" in both cases).
  final Map<String, int?> _balances = <String, int?>{};
  bool _loadingBalances = true;

  /// Set while sign-out is counting down to its 3-second undo window.
  /// Prevents double-fires from a rapid double-tap.
  bool _signOutPending = false;

  @override
  void initState() {
    super.initState();
    _loadBalances();
  }

  Future<void> _loadBalances() async {
    // Cache-first: seed the balance map from cached_credit_balance so
    // the sheet renders real numbers even offline. Then fire live
    // fetches in parallel and let them overwrite each row as they
    // complete.
    final seedEntries = await Future.wait(
      widget.memberships.map((m) async {
        final cached =
            await SyncService.instance.storage.getCachedCreditBalance(m.id);
        return MapEntry(m.id, cached?.balance);
      }),
    );
    if (!mounted) return;
    setState(() {
      _balances
        ..clear()
        ..addEntries(seedEntries);
      _loadingBalances = false;
    });

    // Live refresh. Swallows its own errors; on failure the cached
    // value we already painted stays on screen.
    final liveEntries = await Future.wait(
      widget.memberships.map((m) async {
        final balance = await ApiClient.instance.practiceCreditBalance(
          practiceId: m.id,
        );
        return MapEntry(m.id, balance);
      }),
    );
    if (!mounted) return;
    setState(() {
      for (final e in liveEntries) {
        if (e.value != null) {
          _balances[e.key] = e.value;
        }
      }
    });
  }

  Future<void> _onSelect(PracticeMembership m) async {
    if (m.id == widget.currentPracticeId) return;
    HapticFeedback.selectionClick();
    await AuthService.instance.selectPractice(m.id);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  /// R-01: sign out fires immediately, undo SnackBar lets the user
  /// abort within 3 seconds. Mirrors the Settings-screen sign-out flow
  /// (same copy, same duration) so the two entry points behave
  /// identically.
  Future<void> _onSignOut() async {
    if (_signOutPending) return;
    setState(() => _signOutPending = true);
    HapticFeedback.selectionClick();

    // Pop the sheet first so the SnackBar isn't occluded by the sheet's
    // scrim. After pop, `this` context is stale — use the captured
    // messenger.
    Navigator.of(context).pop();

    final messenger = widget.parentMessenger;
    if (messenger == null) {
      // Fallback: still honour the sign-out intent, losing only the
      // undo affordance. Better than silently no-op'ing.
      await AuthService.instance.signOut();
      return;
    }

    bool cancelled = false;
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: const Text(
          'Signing out…',
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 14,
            color: AppColors.textOnDark,
          ),
        ),
        action: SnackBarAction(
          label: 'Undo',
          textColor: AppColors.primary,
          onPressed: () {
            cancelled = true;
          },
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

    await Future<void>.delayed(const Duration(seconds: 3));
    if (cancelled) return;
    await AuthService.instance.signOut();
  }

  @override
  Widget build(BuildContext context) {
    final memberships = widget.memberships;

    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Text(
                'Practice',
                style: TextStyle(
                  fontFamily: 'Montserrat',
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textOnDark,
                ),
              ),
            ),
            if (memberships.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 8, 20, 16),
                child: Text(
                  "You're not in any practice yet.",
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 14,
                    color: AppColors.textSecondaryOnDark,
                  ),
                ),
              )
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  itemCount: memberships.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 2),
                  itemBuilder: (context, i) {
                    final m = memberships[i];
                    final balance = _balances[m.id];
                    final isCurrent = m.id == widget.currentPracticeId;
                    return _PracticeRow(
                      name: m.name,
                      role: m.role,
                      balance: balance,
                      loadingBalance: _loadingBalances,
                      isCurrent: isCurrent,
                      onTap: isCurrent ? null : () => _onSelect(m),
                    );
                  },
                ),
              ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Divider(
                height: 1,
                thickness: 1,
                color: AppColors.surfaceBorder,
              ),
            ),
            InkWell(
              onTap: _signOutPending ? null : _onSignOut,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 16,
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.logout_rounded,
                      size: 20,
                      color: AppColors.error,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      'Sign out',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: _signOutPending
                            ? AppColors.grey600
                            : AppColors.error,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }
}

/// Single practice row. Two-line layout: practice name on top, a
/// "{N} credits · {role}" secondary line below. Coral checkmark at
/// trailing edge on the current practice.
class _PracticeRow extends StatelessWidget {
  final String name;
  final PracticeRole role;
  final int? balance;
  final bool loadingBalance;
  final bool isCurrent;
  final VoidCallback? onTap;

  const _PracticeRow({
    required this.name,
    required this.role,
    required this.balance,
    required this.loadingBalance,
    required this.isCurrent,
    required this.onTap,
  });

  String get _balanceLabel {
    if (loadingBalance) return '— credits';
    if (balance == null) return '— credits';
    if (balance == 1) return '1 credit';
    return '$balance credits';
  }

  String get _roleLabel {
    switch (role) {
      case PracticeRole.owner:
        return 'owner';
      case PracticeRole.practitioner:
        return 'practitioner';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name.isNotEmpty ? name : '—',
                      style: const TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textOnDark,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$_balanceLabel · $_roleLabel',
                      style: const TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 13,
                        color: AppColors.textSecondaryOnDark,
                      ),
                    ),
                  ],
                ),
              ),
              if (isCurrent)
                const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: Icon(
                    Icons.check_circle_rounded,
                    color: AppColors.primary,
                    size: 22,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
