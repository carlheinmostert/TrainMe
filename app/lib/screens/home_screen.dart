import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/client.dart';
import '../models/session.dart';
import '../services/auth_service.dart';
import '../services/local_storage_service.dart';
import '../services/sync_service.dart';
import '../theme.dart';
import '../widgets/bootstrap_error_banner.dart';
import '../widgets/home_credits_chip.dart';
import '../widgets/homefit_logo.dart';
import '../widgets/network_share_sheet.dart';
import '../widgets/offline_sync_chip.dart';
import '../widgets/orientation_lock_guard.dart';
import '../widgets/practice_chip.dart';
import '../widgets/session_expired_banner.dart';
import '../widgets/undo_snackbar.dart';
import 'client_sessions_screen.dart';
import 'settings_screen.dart';

/// Landing screen — now the clients list.
///
/// Replaces the flat session list that used to live here. Each row drills
/// into a [`ClientSessionsScreen`] scoped to that one client. The primary
/// CTA becomes "New Client" (pinned above the footer). Sessions are
/// minted from within the per-client screen, so every session is
/// client-anchored by construction — no more orphan date-stamped sessions.
///
/// Design rules honoured:
///  - R-02 header purity: PracticeChip (identity anchor) top-left,
///    Settings gear top-right. Nothing else competes for header real
///    estate; "New Client" is a pinned CTA, not a header button.
///  - R-06 voice: "practitioner" / "client" only. No
///    "consent"/"POPIA"/"withdraw" in user-visible strings — peer-to-peer.
///  - R-09 obvious defaults: CTA always visible; empty state is a single
///    coral "Add your first client" button with no secondary path.
///  - R-11: this is the mobile twin of the portal's `/clients` page.
class HomeScreen extends StatefulWidget {
  final LocalStorageService storage;

  const HomeScreen({super.key, required this.storage});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  /// Clients under the active practice.
  List<PracticeClient> _clients = const [];

  /// Local session count + most-recent timestamp per client. Computed
  /// client-side by joining `clientId == client.id || clientName ==
  /// client.name` against the SQLite sessions list. Fine at MVP scale
  /// (max dozens of sessions per practitioner).
  Map<String, _ClientSessionStats> _stats = const {};

  bool _loading = true;

  /// Truncated error string on SQL / network failure. Non-null means
  /// the build() swaps the list for an error card with a retry button.
  String? _loadError;

  /// True when the local cache is empty AND the device is offline AND
  /// a cloud pull has been attempted at least once this session.
  /// Triggers the specific "you're offline; reconnect to see clients"
  /// empty state instead of the generic "No clients yet" card.
  bool _cacheEmptyAndOffline = false;

  /// True when the most recent background sync hit an RPC-level error
  /// while the device was ONLINE. Drives the inline "Couldn't refresh.
  /// Tap to retry." banner above the clients list. Deliberately
  /// distinct from [_cacheEmptyAndOffline] — offline is expected and
  /// silent, online-RPC-failure is surprising and must be surfaced
  /// (otherwise the cache looks empty and Carl thinks his data was
  /// wiped).
  bool _syncFailed = false;

  /// Running count of consecutive retries against a failed sync. Resets
  /// on success. Shown in parentheses on the banner after the first
  /// failed retry so it's obvious the retries are landing (or not).
  int _syncRetryCount = 0;

  /// True while a retry from the banner is in flight — disables the
  /// banner's tap gesture so double-taps don't queue two overlapping
  /// pullAll calls.
  bool _retrying = false;

  /// Epoch-ms timestamp of the most recent successful background
  /// pullAll. Drives the "Updated X min ago" hint.
  int? _lastSyncedMs;

  String? _lastPracticeId;

  @override
  void initState() {
    super.initState();
    _lastPracticeId = AuthService.instance.currentPracticeId.value;
    AuthService.instance.currentPracticeId.addListener(_onPracticeChanged);
    _load();
  }

  @override
  void dispose() {
    AuthService.instance.currentPracticeId.removeListener(_onPracticeChanged);
    super.dispose();
  }

  void _onPracticeChanged() {
    final next = AuthService.instance.currentPracticeId.value;
    if (next == _lastPracticeId) return;
    _lastPracticeId = next;
    _load();
  }

  // ---------------------------------------------------------------------------
  // Data
  // ---------------------------------------------------------------------------

  /// Cache-first load. Reads clients + sessions from local SQLite,
  /// renders immediately, then kicks off a background [SyncService.pullAll]
  /// to refresh the cache (non-blocking). The user sees something
  /// instantly even offline.
  Future<void> _load() async {
    if (_loadError != null || !_loading) {
      setState(() {
        _loadError = null;
        _loading = true;
      });
    }

    try {
      final practiceId = AuthService.instance.currentPracticeId.value;
      final userId = AuthService.instance.currentUserId;

      List<PracticeClient> clients = const [];
      if (practiceId != null && practiceId.isNotEmpty) {
        // Read clients from the local cache. This is the offline-first
        // path — the list renders instantly regardless of connectivity.
        final cached = await widget.storage
            .getCachedClientsForPractice(practiceId);
        clients = cached.map((c) => c.toPracticeClient()).toList(growable: false);
      }

      // Claim any orphan sessions for the current user before counting.
      // Idempotent; ensures counts are stable across sign-ins on the
      // same device.
      if (userId != null) {
        await widget.storage.claimOrphanSessions(userId);
      }
      final sessions = await widget.storage.getSessionsForUser(userId);
      final stats = _computeStats(clients, sessions);

      if (!mounted) return;
      setState(() {
        _clients = clients;
        _stats = stats;
        _loading = false;
        _loadError = null;
      });

      // Non-blocking background sync. When it completes we re-read
      // the cache and update the list — the user sees fresh data roll
      // in without having to wait on the initial render. Offline-safe:
      // pullAll swallows all failures.
      if (practiceId != null && practiceId.isNotEmpty) {
        unawaited(_backgroundSync(practiceId));
      }
    } catch (e) {
      final text = e.toString();
      final truncated = text.substring(0, min(200, text.length));
      if (!mounted) return;
      setState(() {
        _clients = const [];
        _stats = const {};
        _loading = false;
        _loadError = truncated;
      });
    }
  }

  /// Run a cloud pull, then re-hydrate the local list from the fresh
  /// cache. Swallows errors — the UI keeps showing whatever we already
  /// had. Sets [_cacheEmptyAndOffline] if the pull finishes and we
  /// still have no clients AND we're offline, so the empty state can
  /// say so plainly. Sets [_syncFailed] if the pull hit an RPC error
  /// while we had connectivity — that's the case where Carl's cache
  /// WOULD have looked empty in the old code path, so we now surface
  /// a banner + retry affordance.
  Future<void> _backgroundSync(String practiceId) async {
    final outcome = await SyncService.instance.pullAll(practiceId);
    if (!mounted) return;
    final cached = await widget.storage.getCachedClientsForPractice(practiceId);
    final clients = cached.map((c) => c.toPracticeClient()).toList(growable: false);
    final userId = AuthService.instance.currentUserId;
    final sessions = await widget.storage.getSessionsForUser(userId);
    final stats = _computeStats(clients, sessions);
    if (!mounted) return;
    final offlineNow = SyncService.instance.offline.value;
    final syncFailed = outcome.hadError && !offlineNow;
    setState(() {
      _clients = clients;
      _stats = stats;
      if (outcome.anySucceeded) {
        _lastSyncedMs = DateTime.now().millisecondsSinceEpoch;
      }
      _cacheEmptyAndOffline = clients.isEmpty && offlineNow;
      _syncFailed = syncFailed;
      if (!syncFailed) {
        // A clean sync (even if offline) resets the retry counter so
        // the next failure starts from "(Tap to retry.)" not
        // "(5 tries.)".
        _syncRetryCount = 0;
      }
    });
  }

  /// Retry handler for the "Couldn't refresh" banner. Fires another
  /// [SyncService.pullAll] for the current practice and updates the
  /// banner state based on whether the retry landed.
  Future<void> _retrySync() async {
    if (_retrying) return;
    final practiceId = AuthService.instance.currentPracticeId.value;
    if (practiceId == null || practiceId.isEmpty) return;
    HapticFeedback.selectionClick();
    setState(() {
      _retrying = true;
      _syncRetryCount += 1;
    });
    try {
      await _backgroundSync(practiceId);
    } finally {
      if (mounted) {
        setState(() {
          _retrying = false;
        });
      }
    }
  }

  /// Bucket local sessions by client. Matches first by [Session.clientId]
  /// (new-flow), falling back to [Session.clientName] == [PracticeClient.name]
  /// so legacy sessions still roll up correctly without a SQLite backfill.
  Map<String, _ClientSessionStats> _computeStats(
    List<PracticeClient> clients,
    List<Session> sessions,
  ) {
    // Pre-index clients by id + lowercased name for fast lookup.
    final byId = <String, PracticeClient>{for (final c in clients) c.id: c};
    final byLowerName = <String, PracticeClient>{
      for (final c in clients) c.name.toLowerCase(): c,
    };

    final out = <String, _ClientSessionStats>{
      for (final c in clients) c.id: const _ClientSessionStats(count: 0),
    };

    for (final session in sessions) {
      PracticeClient? match;
      final cid = session.clientId;
      if (cid != null && byId.containsKey(cid)) {
        match = byId[cid];
      } else {
        match = byLowerName[session.clientName.toLowerCase()];
      }
      if (match == null) continue;
      final existing = out[match.id] ?? const _ClientSessionStats(count: 0);
      final newLast = existing.lastSessionAt == null ||
              session.createdAt.isAfter(existing.lastSessionAt!)
          ? session.createdAt
          : existing.lastSessionAt;
      out[match.id] = _ClientSessionStats(
        count: existing.count + 1,
        lastSessionAt: newLast,
      );
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  /// Four hex chars (16^4 = 65_536 namespace) for the default client
  /// name. Picked lazily once per `_addClient` call so every mint gets
  /// a fresh suffix. Collision rate is ~1/65_536 per-practice — well
  /// below the rate at which the practitioner would rename anyway, and
  /// the publish path surfaces the 23505 fallback if it ever happens.
  String _randomClientSuffix() {
    final rnd = Random.secure();
    final buffer = StringBuffer();
    for (var i = 0; i < 4; i++) {
      buffer.write(rnd.nextInt(16).toRadixString(16));
    }
    return buffer.toString();
  }

  Future<void> _openSettings() async {
    HapticFeedback.selectionClick();
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
  }

  /// Wave 30 — open the network share-kit bottom sheet. Code + QR +
  /// system share button + a hand-off to the portal's stats view. The
  /// sheet captures the active practice id at mount time, so we don't
  /// need to thread anything through here.
  Future<void> _openNetworkShare() async {
    await NetworkShareSheet.show(context);
  }

  Future<void> _addClient() async {
    // No modal popup — the "I don't want popups" rule applies here too.
    // Auto-name the new client with the first unused "New client {N}"
    // index, create it via SyncService (offline-first), and drop the
    // practitioner straight into the per-client screen where the
    // inline editable name affordance handles the rename.
    HapticFeedback.selectionClick();
    final practiceId = AuthService.instance.currentPracticeId.value;
    if (practiceId == null || practiceId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Pick a practice first'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    // Default name uses a 4-char random suffix so it can never collide
    // with an existing (or soft-deleted) client in this practice. The
    // prior sequential "New client N" picker scanned only the local
    // cache for collisions, but `list_practice_clients` filters out
    // `deleted_at IS NOT NULL` — recycle-bin names from other devices
    // never landed in the cache, which meant publish could still
    // explode with 23505 "a deleted client already uses that name".
    //
    // The practitioner is dropped straight into ClientSessionsScreen
    // after creation where the inline-edit affordance lets them rename
    // to something human. 65k namespace × per-practice scope makes
    // same-suffix collisions vanishingly rare; if one ever does happen,
    // the publish path now catches 23505 and surfaces the rename/
    // restore message.
    final defaultName = 'New client ${_randomClientSuffix()}';

    PracticeClient freshClient;
    try {
      final cached = await SyncService.instance.queueCreateClient(
        practiceId: practiceId,
        name: defaultName,
      );
      freshClient = PracticeClient(
        id: cached.id,
        practiceId: practiceId,
        name: cached.name,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Couldn't create client: $e"),
          duration: const Duration(seconds: 3),
        ),
      );
      return;
    }

    if (!mounted) return;
    setState(() {
      _clients = [..._clients, freshClient];
      _stats = {
        ..._stats,
        freshClient.id: const _ClientSessionStats(count: 0),
      };
    });

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ClientSessionsScreen(
          client: freshClient,
          storage: widget.storage,
        ),
      ),
    );
    if (mounted) _load();
  }

  Future<void> _openClient(PracticeClient client) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ClientSessionsScreen(
          client: client,
          storage: widget.storage,
          onDeleted: () => _optimisticallyHide(client.id),
        ),
      ),
    );
    if (mounted) _load();
  }

  /// Remove a client from the local list immediately, without waiting
  /// for a DB round-trip. Used both by the swipe-to-delete Dismissible
  /// and by the detail screen's Delete button (via the [onDeleted]
  /// callback) so the list-ready state stays in sync with whichever
  /// surface fired the delete.
  void _optimisticallyHide(String clientId) {
    if (!mounted) return;
    setState(() {
      _clients = _clients.where((c) => c.id != clientId).toList(growable: false);
      _stats = Map<String, _ClientSessionStats>.from(_stats)..remove(clientId);
    });
  }

  /// Optimistic reinsert after an Undo. Trusts that the client already
  /// existed and isn't mid-drag.
  void _optimisticallyRestore(PracticeClient client) {
    if (!mounted) return;
    setState(() {
      if (_clients.any((c) => c.id == client.id)) return;
      _clients = [..._clients, client];
    });
  }

  /// Swipe-to-delete. Fires immediately (R-01: no modal confirmation)
  /// + surfaces an Undo SnackBar for 7 seconds. Undo reverses the
  /// cascade: the client AND every session that was cascaded land back
  /// where they were.
  Future<void> _deleteClient(PracticeClient client) async {
    HapticFeedback.mediumImpact();
    // Hide from the list straight away so the Dismissible's slide-out
    // looks clean. The Dismissible itself handles the animation frame;
    // state-level removal is what keeps the list stable if Undo isn't
    // pressed.
    _optimisticallyHide(client.id);

    int cascadeTs;
    try {
      cascadeTs = await SyncService.instance.queueDeleteClient(
        clientId: client.id,
      );
    } catch (e) {
      if (!mounted) return;
      _optimisticallyRestore(client);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Couldn't delete ${client.name}: $e"),
          duration: const Duration(seconds: 4),
          backgroundColor: AppColors.error,
        ),
      );
      return;
    }

    if (!mounted) return;
    showUndoSnackBar(
      context,
      label: '${client.name.isEmpty ? 'Client' : client.name} deleted',
      duration: const Duration(seconds: 7),
      onUndo: () async {
        await SyncService.instance.queueRestoreClient(
          clientId: client.id,
          cascadeTimestampMs: cascadeTs,
        );
        if (!mounted) return;
        _optimisticallyRestore(client);
        // Re-pull stats so session counts repopulate.
        _load();
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return OrientationLockGuard(
      child: Scaffold(
      backgroundColor: AppColors.surfaceBg,
      body: SafeArea(
        child: Stack(
          children: [
            Column(
          children: [
            // Brand anchor. Matrix + wordmark lockup sits above the
            // identity controls so Home reads as the brand's front
            // door — the first thing a practitioner sees when opening
            // the app. Identity controls (PracticeChip + offline chip)
            // live underneath so the hierarchy is brand → identity →
            // content. Settings lives top-right of the Scaffold via a
            // Stack overlay so it gets a generous tap target instead of
            // fighting the practice chip for the identity row's space.
            const Padding(
              // Bottom padding 3× bigger per Wave 3 #14 pass-note — gives
              // the brand anchor enough breathing room before the
              // identity-controls row (practice chip + sync).
              padding: EdgeInsets.fromLTRB(24, 16, 24, 24),
              child: Center(
                child: HomefitLogoLockup(size: 180),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 4, 12, 0),
              child: Row(
                children: [
                  PracticeChip(),
                  SizedBox(width: 8),
                  // Offline / pending-ops chip. Hidden when online +
                  // queue empty; subtle ink-muted when there's
                  // something to say.
                  OfflineSyncChip(),
                  // Spacer pushes the credits chip to the right edge
                  // of the row. PracticeChip stays left-anchored;
                  // they read as peers on the identity line.
                  Spacer(),
                  // Wave 29 — credit balance for the active practice.
                  // Tap → opens manage.homefit.studio/credits with
                  // ?practice=<uuid> so the portal lands in context.
                  HomeCreditsChip(),
                ],
              ),
            ),
            // "Updated N min ago" hint, only when we have a successful
            // sync to report AND the body is the clients list (not
            // loading / error / empty).
            if (_lastSyncedMs != null &&
                !_loading &&
                _loadError == null &&
                _clients.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
                child: Row(
                  children: [
                    Text(
                      'Updated ${_relativeAge(_lastSyncedMs!)}',
                      style: const TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 11,
                        color: AppColors.textSecondaryOnDark,
                      ),
                    ),
                  ],
                ),
              ),
            // Inline sync-failure banner. Only shown when we're online
            // AND the most recent pullAll hit an RPC error. The clients
            // list (if any) stays visible behind it, so Carl's mental
            // model is preserved: "I have N clients cached, I see them,
            // the banner tells me we can't reach the cloud right now,
            // nothing is broken." We only suppress it when the list is
            // empty — that case falls through to the bigger "Couldn't
            // load your clients" empty state which carries the same
            // retry affordance.
            if (_syncFailed && !_loading && _clients.isNotEmpty)
              _SyncFailedBanner(
                retryCount: _syncRetryCount,
                retrying: _retrying,
                onTap: _retrying ? null : _retrySync,
              ),
            const SizedBox(height: 8),
            // Wave 15 — a server-revoked session (password rotated,
            // admin intervention, auth.sessions row deleted) used to
            // 403 every subsequent RPC silently. ApiClient now detects
            // `session_not_found`, forces a local sign-out, and flips
            // `sessionExpired` so this banner surfaces. Reads stay on
            // cache; writes queue locally. Tapping sign-in routes
            // through AuthService.signOut → AuthGate.
            SessionExpiredBanner(
              onSignIn: () => AuthService.instance.signOut(),
            ),
            ValueListenableBuilder<String?>(
              valueListenable: AuthService.instance.bootstrapError,
              builder: (context, error, _) {
                if (error == null) return const SizedBox.shrink();
                return BootstrapErrorBanner(
                  onRetry: () =>
                      AuthService.instance.ensurePracticeMembership(),
                );
              },
            ),
            Expanded(
              child: _loading
                  ? _buildShimmer()
                  : (_loadError != null
                      ? _buildLoadErrorCard(_loadError!)
                      : _buildBody()),
            ),
            // Primary CTA. Coral FAB pinned above the footer so the
            // gesture lives in the thumb zone.
            if (!_loading && _loadError == null)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 12),
                child: SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: FilledButton.icon(
                    onPressed: _addClient,
                    icon: const Icon(Icons.person_add_alt_1_rounded, size: 24),
                    label: const Text(
                      'New Client',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
            // Settings overlay — top-right of the Home surface, above the
            // brand lockup. Given the corner to itself so the gesture
            // isn't fighting the PracticeChip + OfflineSyncChip for space
            // in the identity row.
            Positioned(
              top: 4,
              right: 4,
              child: IconButton(
                onPressed: _openSettings,
                icon: const Icon(
                  Icons.settings_outlined,
                  color: AppColors.textOnDark,
                  size: 26,
                ),
                tooltip: 'Settings',
              ),
            ),
            // Wave 30 — Network share entry point. Mirrors the Settings
            // gear's corner placement on the opposite side so the brand
            // lockup stays uncrowded. Tap opens the NetworkShareSheet
            // (referral code + QR + share button + portal hand-off).
            Positioned(
              top: 4,
              left: 4,
              child: IconButton(
                onPressed: _openNetworkShare,
                icon: const Icon(
                  Icons.group_add_outlined,
                  color: AppColors.primary,
                  size: 24,
                ),
                tooltip: 'Share with another practitioner',
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }

  Widget _buildBody() {
    if (_clients.isEmpty) {
      return _buildEmptyState();
    }
    return RefreshIndicator(
      color: AppColors.primary,
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        itemCount: _clients.length,
        itemBuilder: (context, i) {
          final client = _clients[i];
          final stats = _stats[client.id] ??
              const _ClientSessionStats(count: 0);
          return Dismissible(
            // Use the client id — stable across reorders and Undo.
            key: ValueKey('client-${client.id}'),
            direction: DismissDirection.endToStart,
            background: const SizedBox.shrink(),
            secondaryBackground: Container(
              margin: const EdgeInsets.symmetric(vertical: 4),
              padding: const EdgeInsets.symmetric(horizontal: 24),
              alignment: Alignment.centerRight,
              decoration: BoxDecoration(
                color: AppColors.error,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.delete_outline_rounded, color: Colors.white),
                  SizedBox(width: 8),
                  Text(
                    'Delete',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
            onDismissed: (_) => _deleteClient(client),
            child: _ClientCard(
              client: client,
              stats: stats,
              onTap: () => _openClient(client),
            ),
          );
        },
      ),
    );
  }

  Widget _buildEmptyState() {
    // Three flavours of empty:
    //   1. Online, sync worked, truly no clients → coral CTA.
    //   2. Offline with an empty cache → "you're offline", no CTA.
    //   3. Online but sync failed + empty cache → "couldn't load your
    //      clients" with a retry button. This is the pathological case
    //      that silently rendered "No clients yet" in the old code and
    //      made it look like Carl's data was wiped.
    final offlineNoCache = _cacheEmptyAndOffline;
    final syncFailedEmpty = _syncFailed && !offlineNoCache;

    final String title;
    final String body;
    final IconData icon;
    if (syncFailedEmpty) {
      title = "Couldn't load your clients";
      body = 'Check your connection and try again.';
      icon = Icons.cloud_sync_outlined;
    } else if (offlineNoCache) {
      title = "You're offline";
      body = "We'll fill in your clients the moment you reconnect.";
      icon = Icons.cloud_off_outlined;
    } else {
      title = 'No clients yet';
      body = 'Add your first client to start capturing plans.';
      icon = Icons.people_alt_outlined;
    }
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
                Icon(
                  icon,
                  size: 64,
                  color: AppColors.grey600,
                ),
                const SizedBox(height: 18),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: 'Montserrat',
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textOnDark,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  body,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 14,
                    color: AppColors.textSecondaryOnDark,
                    height: 1.4,
                  ),
                ),
                if (syncFailedEmpty) ...[
                  const SizedBox(height: 22),
                  SizedBox(
                    width: 260,
                    child: FilledButton.icon(
                      onPressed: _retrying ? null : _retrySync,
                      icon: _retrying
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  Colors.white,
                                ),
                              ),
                            )
                          : const Icon(Icons.refresh_rounded),
                      label: Text(_retrying ? 'Retrying…' : 'Try again'),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius:
                              BorderRadius.circular(AppTheme.radiusMd),
                        ),
                        textStyle: const TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ] else if (!offlineNoCache) ...[
                  const SizedBox(height: 22),
                  SizedBox(
                    width: 260,
                    child: FilledButton.icon(
                      onPressed: _addClient,
                      icon: const Icon(Icons.person_add_alt_1_rounded),
                      label: const Text('Add your first client'),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius:
                              BorderRadius.circular(AppTheme.radiusMd),
                        ),
                        textStyle: const TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Relative age string used for the "Updated X min ago" hint.
  static String _relativeAge(int epochMs) {
    final diff = DateTime.now()
        .difference(DateTime.fromMillisecondsSinceEpoch(epochMs));
    if (diff.inSeconds < 30) return 'just now';
    if (diff.inMinutes < 1) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  Widget _buildShimmer() {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      itemCount: 3,
      itemBuilder: (_, _) => Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        height: 78,
        decoration: BoxDecoration(
          color: AppColors.surfaceBase,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.surfaceBorder, width: 1),
        ),
      ),
    );
  }

  Widget _buildLoadErrorCard(String error) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 480),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: AppColors.surfaceBase,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.surfaceBorder, width: 1),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.error_outline_rounded,
                    color: AppColors.primary,
                    size: 28,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          "Couldn't load your clients.",
                          style: TextStyle(
                            fontFamily: 'Montserrat',
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textOnDark,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          error,
                          style: const TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 13,
                            color: AppColors.textSecondaryOnDark,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: _load,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius:
                          BorderRadius.circular(AppTheme.radiusMd),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                    textStyle: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  child: const Text('Try again'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Inline "Couldn't refresh. Tap to retry." banner that renders
/// between the practice chip and the clients list when the most recent
/// background sync hit an RPC error while online. Deliberately subtle —
/// dark surface with a thin coral accent on the left, matching the
/// [OfflineSyncChip]'s muted aesthetic so it doesn't feel alarming.
/// The cached clients are still visible underneath, so Carl can keep
/// working while we figure out what the cloud is doing.
class _SyncFailedBanner extends StatelessWidget {
  final int retryCount;
  final bool retrying;
  final VoidCallback? onTap;

  const _SyncFailedBanner({
    required this.retryCount,
    required this.retrying,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // retryCount==0: first failure, no count yet.
    // retryCount==1+: we've already tried N times since the first fail.
    final String message;
    if (retrying) {
      message = 'Retrying…';
    } else if (retryCount <= 1) {
      message = "Couldn't refresh. Tap to retry.";
    } else {
      message = "Couldn't refresh ($retryCount tries). Tap to retry.";
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.surfaceRaised,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: AppColors.primary.withValues(alpha: 0.45),
                width: 1,
              ),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: retrying
                      ? const CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            AppColors.primary,
                          ),
                        )
                      : const Icon(
                          Icons.cloud_sync_outlined,
                          size: 16,
                          color: AppColors.primary,
                        ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    message,
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: AppColors.textOnDark,
                    ),
                  ),
                ),
                if (!retrying)
                  const Icon(
                    Icons.refresh_rounded,
                    size: 18,
                    color: AppColors.textSecondaryOnDark,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Row rendered per client in the Home list.
class _ClientCard extends StatelessWidget {
  final PracticeClient client;
  final _ClientSessionStats stats;
  final VoidCallback onTap;

  const _ClientCard({
    required this.client,
    required this.stats,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: AppColors.surfaceBase,
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.surfaceBorder, width: 1),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              // Leading person badge — coral on dark. Matches the
              // session badge on SessionCard so the two card types read
              // as the same visual family on the Clients-as-Home spine.
              // Wave 34 bumped both in lock-step: 40×40 → 60×60, glyph
              // 22 → 33, radius 10 → 14. The +50% size makes the icon
              // a confident anchor on the row rather than the chip-
              // sized footprint of Wave 30-33.
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                alignment: Alignment.center,
                child: const Icon(
                  Icons.person_outline,
                  color: AppColors.primary,
                  size: 33,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      client.name.isEmpty ? 'Unnamed client' : client.name,
                      style: const TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textOnDark,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    // Consent summary chip removed from the Home list per
                    // Carl (2026-04-20 post-Wave-3): treatment consent
                    // detail isn't relevant at the client-list level;
                    // consent lives on the client detail screen's header
                    // chip + the sheet it opens.
                    Text(
                      _subtitle(stats),
                      style: const TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 12,
                        color: AppColors.textSecondaryOnDark,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(
                Icons.chevron_right,
                color: AppColors.grey500,
                size: 22,
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _subtitle(_ClientSessionStats stats) {
    if (stats.count == 0) return 'No sessions yet';
    final plural = stats.count == 1 ? 'session' : 'sessions';
    final when = _relativeDate(stats.lastSessionAt);
    if (when == null) return '${stats.count} $plural';
    return '${stats.count} $plural \u00b7 $when';
  }

  /// Short relative-date: "just now" / "Nm ago" / "Nh ago" / "N days ago"
  /// / "Mon 12 Apr". Keeps one-glance readability without pulling in an
  /// intl dependency.
  String? _relativeDate(DateTime? dt) {
    if (dt == null) return null;
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inSeconds < 45) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) {
      return '${diff.inDays} day${diff.inDays == 1 ? '' : 's'} ago';
    }
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${dt.day} ${months[dt.month - 1]}';
  }
}

/// Per-client session-count + most-recent timestamp.
@immutable
class _ClientSessionStats {
  final int count;
  final DateTime? lastSessionAt;

  const _ClientSessionStats({required this.count, this.lastSessionAt});
}
