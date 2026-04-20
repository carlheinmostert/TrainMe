import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../theme.dart';
import 'practice_switcher_sheet.dart';

/// Glanceable "who am I acting as?" pill for the top bar of every
/// practitioner-facing surface (Home and Studio).
///
/// Design intent (Design Rules R-02, R-09, R-11):
///   - R-02: the chip is an identity anchor, not navigation. It tells
///     the practitioner which practice their next publish will bill. It
///     is NOT a mode-switch or a page title; it coexists with the
///     Settings gear on Home and the back arrow / title on Studio.
///   - R-09: obvious affordances. When the practitioner belongs to more
///     than one practice the chip shows a chevron-down so "tap to
///     switch" reads at a glance. When they belong to exactly one
///     practice the chevron is dropped — the chip becomes an honest
///     read-only label rather than a button that promises a switcher
///     that can't exist.
///   - R-11: mobile twin of the portal's `PracticeSwitcher.tsx` on the
///     dashboard. The capability set is identical; only the surface
///     metaphor differs (bottom sheet vs. dropdown).
///
/// State rules:
///   - Loading / no practice yet → renders the muted "—" placeholder so
///     the chrome doesn't jump once the listMyPractices call lands.
///   - [enabled] = false → the chip is rendered at 55% opacity and the
///     tap handler is a no-op. Used by SessionShellScreen / Studio so
///     switching mid-session doesn't become a footgun.
class PracticeChip extends StatelessWidget {
  /// When false, the chip renders in a muted state and the tap handler
  /// is a no-op. Used inside a session where switching practice
  /// mid-edit would cause cross-tenant session state (R-01 spirit:
  /// never silently move the user's data out from under them).
  final bool enabled;

  const PracticeChip({super.key, this.enabled = true});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: AuthService.instance.currentPracticeId,
      builder: (context, practiceId, _) {
        return _PracticeChipForId(
          practiceId: practiceId,
          enabled: enabled,
        );
      },
    );
  }
}

/// Stateful inner widget keyed by the current practice id. Owns the
/// `listMyPractices()` fetch in a `FutureBuilder` so the network round-
/// trip doesn't re-fire on every parent rebuild. Refetches when the
/// current practice id changes (switch or bootstrap).
class _PracticeChipForId extends StatefulWidget {
  final String? practiceId;
  final bool enabled;

  const _PracticeChipForId({
    required this.practiceId,
    required this.enabled,
  });

  @override
  State<_PracticeChipForId> createState() => _PracticeChipForIdState();
}

class _PracticeChipForIdState extends State<_PracticeChipForId> {
  Future<List<PracticeMembership>>? _future;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didUpdateWidget(covariant _PracticeChipForId old) {
    super.didUpdateWidget(old);
    // Refetch when the id flips — the membership list might have
    // shifted too (e.g. the user was just added as owner of a second
    // practice by the portal). Cheap: the typical practitioner has 1-2
    // memberships.
    if (old.practiceId != widget.practiceId) {
      _refresh();
    }
  }

  void _refresh() {
    setState(() {
      _future = ApiClient.instance.listMyPractices();
    });
  }

  Future<void> _onTap() async {
    if (!widget.enabled) return;
    final memberships = await _future;
    if (memberships == null || memberships.length <= 1) return;
    if (!mounted) return;
    HapticFeedback.selectionClick();
    await PracticeSwitcherSheet.show(
      context,
      memberships: memberships,
      currentPracticeId: widget.practiceId,
    );
    // The sheet calls AuthService.selectPractice directly; the
    // ValueListenableBuilder above picks up the change. No-op here.
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<PracticeMembership>>(
      future: _future,
      builder: (context, snapshot) {
        final memberships = snapshot.data ?? const <PracticeMembership>[];
        final loading = snapshot.connectionState == ConnectionState.waiting;

        // Pick the current practice's display name.
        String? name;
        if (memberships.isNotEmpty) {
          final match = memberships.firstWhere(
            (m) => m.id == widget.practiceId,
            orElse: () => memberships.first,
          );
          name = match.name.isNotEmpty ? match.name : null;
        }

        final showChevron =
            widget.enabled && !loading && memberships.length > 1;
        final tapHandler = showChevron ? _onTap : null;
        final label = (loading || name == null) ? '—' : name;

        return _PracticeChipVisual(
          label: label,
          showChevron: showChevron,
          onTap: tapHandler,
          dimmed: !widget.enabled,
        );
      },
    );
  }
}

/// Pure visual — no state, no async. Coral-outlined pill matching the
/// brand-tint chip pattern used elsewhere (Settings referral code
/// pill, preview-screen treatment badges).
class _PracticeChipVisual extends StatelessWidget {
  final String label;
  final bool showChevron;
  final VoidCallback? onTap;
  final bool dimmed;

  const _PracticeChipVisual({
    required this.label,
    required this.showChevron,
    required this.onTap,
    required this.dimmed,
  });

  @override
  Widget build(BuildContext context) {
    // R-09: disabled-looking chip on Studio is deliberate — the
    // practitioner should not feel invited to switch mid-session.
    final opacity = dimmed ? 0.55 : 1.0;
    return Opacity(
      opacity: opacity,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: AppColors.brandTintBg,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: AppColors.brandTintBorder, width: 1),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.home_outlined,
                  size: 14,
                  color: AppColors.primary,
                ),
                const SizedBox(width: 6),
                // Constrain so a long practice name wraps into an
                // ellipsis rather than pushing the Settings gear off
                // the screen.
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 180),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textOnDark,
                    ),
                  ),
                ),
                if (showChevron) ...[
                  const SizedBox(width: 4),
                  const Icon(
                    Icons.expand_more_rounded,
                    size: 16,
                    color: AppColors.primary,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
