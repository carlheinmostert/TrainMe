import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/client.dart';
import '../models/session.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../services/local_storage_service.dart';
import '../theme.dart';
import '../widgets/bootstrap_error_banner.dart';
import '../widgets/new_client_sheet.dart';
import '../widgets/powered_by_footer.dart';
import '../widgets/practice_chip.dart';
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
        clients =
            await ApiClient.instance.listPracticeClients(practiceId);
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

  Future<void> _openSettings() async {
    HapticFeedback.selectionClick();
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
  }

  Future<void> _addClient() async {
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

    final result = await showNewClientSheet(context, practiceId: practiceId);
    if (result == null) return;

    // Optimistic local entry so the drilldown lands on a populated
    // screen even if the refresh round-trip is slow.
    final freshClient = PracticeClient(
      id: result.id,
      practiceId: practiceId,
      name: result.name,
    );
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
        ),
      ),
    );
    if (mounted) _load();
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surfaceBg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 8, 0),
              child: Row(
                children: [
                  const PracticeChip(),
                  const Spacer(),
                  IconButton(
                    onPressed: _openSettings,
                    icon: const Icon(
                      Icons.settings_outlined,
                      color: AppColors.textOnDark,
                      size: 26,
                    ),
                    tooltip: 'Settings',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
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
            const PoweredByFooter(),
          ],
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
          return _ClientCard(
            client: client,
            stats: stats,
            onTap: () => _openClient(client),
          );
        },
      ),
    );
  }

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
                const Icon(
                  Icons.people_alt_outlined,
                  size: 64,
                  color: AppColors.grey600,
                ),
                const SizedBox(height: 18),
                const Text(
                  'No clients yet',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'Montserrat',
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textOnDark,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Add your first client to start capturing plans.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 14,
                    color: AppColors.textSecondaryOnDark,
                    height: 1.4,
                  ),
                ),
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
                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ),
    );
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
                    Row(
                      children: [
                        _ConsentSummaryChip(client: client),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _subtitle(stats),
                            style: const TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 12,
                              color: AppColors.textSecondaryOnDark,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
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

/// Coral-tinted chip summarising the client's consent state.
/// `Line only` / `+ B&W` / `+ Original` / `+ B&W + Original`.
class _ConsentSummaryChip extends StatelessWidget {
  final PracticeClient client;

  const _ConsentSummaryChip({required this.client});

  @override
  Widget build(BuildContext context) {
    final label = _label();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: AppColors.primary.withValues(alpha: 0.25),
        ),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontFamily: 'Inter',
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: AppColors.textOnDark,
        ),
      ),
    );
  }

  String _label() {
    if (client.grayscaleAllowed && client.colourAllowed) {
      return 'Line + B&W + Original';
    }
    if (client.grayscaleAllowed) return 'Line + B&W';
    if (client.colourAllowed) return 'Line + Original';
    return 'Line only';
  }
}

/// Per-client session-count + most-recent timestamp.
@immutable
class _ClientSessionStats {
  final int count;
  final DateTime? lastSessionAt;

  const _ClientSessionStats({required this.count, this.lastSessionAt});
}
