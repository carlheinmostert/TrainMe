import 'package:flutter/material.dart';

import '../models/session.dart';
import '../services/auth_service.dart';
import '../services/local_storage_service.dart';
import '../theme.dart';
import '../widgets/self_capture_card.dart';

/// Body widget for the My Workouts scope on Home.
///
/// Renders the practitioner's own self-capture sessions — the rows
/// whose `client_id` matches the cached Self-client (the row in their
/// personal practice where `clients.user_id = auth.uid()`).
///
/// Offline-first by construction. Both reads route through
/// [LocalStorageService] — no direct DB access (per
/// `feedback_no_direct_db_access`) and no exception-driven control flow
/// (per `feedback_no_exception_control_flow`). The pull branch for
/// sessions already exists in [SyncService._pullSessions]; the
/// Self-client row arrives via `_pullClients` which mirrors
/// `list_practice_clients` — both run inside [SyncService.pullAll]
/// which fires from Home on load.
///
/// Empty states (in priority order):
/// 1. No Self-client yet → "Record your first workout" CTA points at
///    the FAB (which itself handles the consent gate).
/// 2. Self-client exists but zero self-captures → same CTA.
/// 3. Has self-captures → reverse-chronological list.
///
/// A secondary muted line surfaces under the CTA in cases 1 and 2:
/// "Got a link from your practitioner? Tap to claim it." The action
/// is deferred (inbound shared plans land in a follow-up PR); the
/// line is plain text without `onTap` per the brief.
///
/// Tap routing for cards is delegated to [onTapSession] — the parent
/// Home screen pushes [SessionShellScreen] in Studio mode (since
/// self-captures are always owned by the practitioner). When the
/// inbound branch eventually ships, the parent will route inbound
/// cards to [PlanPreviewScreen] instead; that branching belongs at
/// the call site, not in this widget.
class MyWorkoutsScreen extends StatefulWidget {
  final LocalStorageService storage;

  /// Tap handler for a self-capture row. Receives the session to
  /// navigate into.
  final ValueChanged<Session> onTapSession;

  /// Sessions render-version. Bumped by the parent whenever it wants
  /// the list to re-read from SQLite (e.g. after returning from the
  /// session shell). Lets the parent re-trigger a load without
  /// passing a GlobalKey + state-of-state.
  final int reloadToken;

  const MyWorkoutsScreen({
    super.key,
    required this.storage,
    required this.onTapSession,
    this.reloadToken = 0,
  });

  @override
  State<MyWorkoutsScreen> createState() => _MyWorkoutsScreenState();
}

class _MyWorkoutsScreenState extends State<MyWorkoutsScreen> {
  /// Self-capture sessions, newest first. Filtered locally from the
  /// full per-user session list to only those whose `clientId`
  /// matches the cached Self-client's id (looked up at load time).
  List<Session> _sessions = const [];

  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant MyWorkoutsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reloadToken != widget.reloadToken) {
      _load();
    }
  }

  Future<void> _load() async {
    final userId = AuthService.instance.currentUserId;
    if (userId == null) {
      if (!mounted) return;
      setState(() {
        _sessions = const [];
        _loading = false;
      });
      return;
    }

    final self = await widget.storage.getCachedSelfClient(userId);
    // Claim any orphan sessions for this user first so the per-user
    // query catches sessions drafted while signed out. Idempotent —
    // safe to fire on every load (same pattern as HomeScreen._load).
    await widget.storage.claimOrphanSessions(userId);
    final all = await widget.storage.getSessionsForUser(userId);

    final List<Session> filtered;
    if (self == null) {
      filtered = const [];
    } else {
      filtered = all.where((s) => s.clientId == self.id).toList(growable: false);
      // getSessionsForUser already orders by `created_at DESC`; keep
      // the order explicit here in case the underlying query ever
      // changes (no .reverse — DESC means newest first).
    }

    if (!mounted) return;
    setState(() {
      _sessions = filtered;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return _buildShimmer();
    }
    if (_sessions.isEmpty) {
      return _buildEmptyState();
    }
    return RefreshIndicator(
      color: AppColors.primary,
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        itemCount: _sessions.length,
        itemBuilder: (context, i) {
          final session = _sessions[i];
          return SelfCaptureCard(
            key: ValueKey('self-capture-${session.id}'),
            session: session,
            onTap: () => widget.onTapSession(session),
          );
        },
      ),
    );
  }

  Widget _buildShimmer() {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      itemCount: 3,
      itemBuilder: (_, _) => Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        height: 86,
        decoration: BoxDecoration(
          color: AppColors.surfaceBase,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.surfaceBorder, width: 1),
        ),
      ),
    );
  }

  /// Full-screen empty state shown when the user has zero
  /// self-captures (either because they've never registered, or
  /// because they registered but haven't captured yet). Both states
  /// share the same CTA — the actual gating happens at the FAB which
  /// surfaces the consent sheet if the embedding consent isn't
  /// stamped yet (per `home_screen.dart`'s `_newSelfSessionStub`).
  Widget _buildEmptyState() {
    return LayoutBuilder(
      builder: (context, c) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: c.maxHeight),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(height: 32),
                Container(
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(24),
                  ),
                  alignment: Alignment.center,
                  child: const Icon(
                    Icons.fitness_center_rounded,
                    size: 48,
                    color: AppColors.primary,
                  ),
                ),
                const SizedBox(height: 24),
                const Text(
                  'Record your first workout',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'Montserrat',
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textOnDark,
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Tap New Session below to capture yourself moving — '
                  'every clip becomes a line drawing you can play back '
                  'anywhere.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 14,
                    color: AppColors.textSecondaryOnDark,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 24),
                // Inbound-from-practitioner ingress is deferred to a
                // follow-up PR (see `docs/SELF_TRAINER_WAVE.md`
                // § "Capture-entry path from My Workouts"). Render
                // the affordance copy without an `onTap` so the
                // surface area is staked out but doesn't promise a
                // working action yet.
                const Text(
                  'Got a link from your practitioner? Tap to claim it.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 12,
                    color: AppColors.grey500,
                  ),
                ),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
