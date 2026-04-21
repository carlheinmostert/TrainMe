import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
import '../services/auth_service.dart';
import '../services/loud_swallow.dart';
import '../services/sync_service.dart';
import '../theme.dart';

/// Wave 7 / Milestone Q — Diagnostics screen.
///
/// Surfaces a small set of boot-time probes that would have caught the
/// silent failures we've traced through the design review
/// (`docs/design-reviews/silent-failures-2026-04-20.md`). Each probe is
/// idempotent, non-destructive, and renders a single row with a
/// green / amber / red chip.
///
/// ## Probes
///
/// 1. **Signed-URL self-check** — calls the `signed_url_self_check()`
///    Postgres RPC (Milestone Q). Green if `ok == true`. Would have
///    caught the 3-week vault-placeholder outage on first launch.
///
/// 2. **Supabase connectivity** — verifies the anon key is accepted via
///    a cheap `supabase.auth.getUser()` roundtrip (or a timeout).
///
/// 3. **Local SQLite** — runs a bounded SELECT against the cache tables
///    so we catch a corrupted / missing database before the practitioner
///    hits a screen that depends on it.
///
/// 4. **Pending-ops queue depth** — reads the `pending_ops` count from
///    the offline-first sync layer. Green at 0, amber while flushing,
///    red if the backlog keeps growing.
///
/// ## Entry points
///
/// * **Settings → Diagnostics** (manual) — always available.
/// * **Boot auto-open** — on the first launch after a fresh sign-in, a
///   SharedPreferences flag (`homefit.diagnostics.seen`) triggers a
///   full-screen push of this route. The intent is that a practitioner
///   with a misconfigured device sees the amber / red banner *before*
///   starting to capture. Tapping any row acknowledges the flag so we
///   don't nag on every launch.
class DiagnosticsScreen extends StatefulWidget {
  /// Open the diagnostics screen. Call from anywhere in the UI.
  static Future<void> push(BuildContext context) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => const DiagnosticsScreen(),
        fullscreenDialog: false,
      ),
    );
  }

  /// SharedPreferences key for the "first-run diagnostics seen" flag.
  /// After the practitioner visits this screen once (manually or via
  /// auto-open), subsequent cold launches don't auto-push the route.
  ///
  /// To force a re-show (e.g. after a vault-secret rotation went
  /// sideways), clear this key via the hidden debug affordance on the
  /// Settings → Version row (7-tap unlock).
  static const String seenPrefsKey = 'homefit.diagnostics.seen';

  /// Open the diagnostics screen automatically if the caller hasn't
  /// seen it yet this install. Meant to be called from the main shell
  /// after first frame on a fresh sign-in. Silently swallows failures —
  /// the user should never see a crash because of the diagnostics
  /// surface itself.
  static Future<void> maybeAutoOpen(BuildContext context) async {
    await loudSwallow(
      () async {
        final prefs = await SharedPreferences.getInstance();
        final seen = prefs.getBool(seenPrefsKey) ?? false;
        if (seen) return;
        if (!context.mounted) return;
        await push(context);
        // Flag as seen after the user has had a chance to look at the
        // probes, regardless of whether any were red. A red state is
        // already persisted server-side via `log_error`; re-nagging on
        // every launch would be a worse UX.
        await prefs.setBool(seenPrefsKey, true);
      },
      kind: 'diagnostics_auto_open_failed',
      source: 'DiagnosticsScreen.maybeAutoOpen',
      severity: 'warn',
      swallow: true,
    );
  }

  const DiagnosticsScreen({super.key});

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  // Probe results. null = not yet run; _ProbeResult carries state + detail.
  _ProbeResult? _signedUrl;
  _ProbeResult? _supabaseConn;
  _ProbeResult? _sqlite;
  _ProbeResult? _pendingOps;

  bool _running = false;

  @override
  void initState() {
    super.initState();
    // Kick the probes off immediately. Each probe is independently
    // time-bounded so one slow RPC can't block the others.
    _runAll();
  }

  Future<void> _runAll() async {
    if (_running) return;
    setState(() {
      _running = true;
      _signedUrl = _supabaseConn = _sqlite = _pendingOps = null;
    });
    // Fire all probes in parallel — they're independent and the whole
    // screen should land in under 2 seconds on good signal.
    await Future.wait<void>([
      _runSignedUrlProbe(),
      _runSupabaseConnProbe(),
      _runSqliteProbe(),
      _runPendingOpsProbe(),
    ]);
    if (!mounted) return;
    setState(() => _running = false);
  }

  Future<void> _runSignedUrlProbe() async {
    // Calls the SECURITY DEFINER `signed_url_self_check()` RPC from
    // schema_milestone_q_error_logs.sql. Returns 4 columns; we look at
    // `ok` and the two presence booleans to classify.
    _ProbeResult result;
    try {
      final response = await Supabase.instance.client
          .rpc('signed_url_self_check')
          .timeout(const Duration(seconds: 10));
      Map<String, dynamic>? row;
      if (response is List && response.isNotEmpty) {
        final first = response.first;
        if (first is Map) row = Map<String, dynamic>.from(first);
      } else if (response is Map) {
        row = Map<String, dynamic>.from(response);
      }
      if (row == null) {
        result = _ProbeResult.red(
          'RPC returned no rows. signed_url_self_check() should return 1 row.',
        );
      } else {
        final ok = row['ok'] == true;
        final jwt = row['jwt_secret_present'] == true;
        final url = row['supabase_url_present'] == true;
        final sample = row['sample_url']?.toString();
        if (ok && jwt && url) {
          result = _ProbeResult.green(
            'Signing works. Sample: ${sample ?? '(empty)'}',
          );
        } else if (!jwt || !url) {
          result = _ProbeResult.red(
            'Vault secret missing: '
            '${jwt ? '' : 'supabase_jwt_secret '}'
            '${url ? '' : 'supabase_url '}'
            '(B&W / Original treatments will silently degrade to line-drawing).',
          );
        } else {
          result = _ProbeResult.red(
            'sign_storage_url() returned NULL — secrets present but signing errored.',
          );
        }
      }
    } catch (e) {
      result = _ProbeResult.red('RPC call failed: $e');
    }
    if (!mounted) return;
    setState(() => _signedUrl = result);
  }

  Future<void> _runSupabaseConnProbe() async {
    _ProbeResult result;
    try {
      // Cheap auth probe — always safe, doesn't hit the DB. Verifies the
      // anon key is still accepted (a key rotation or a bad wifi captive
      // portal would fail here).
      await Supabase.instance.client.auth
          .getUser()
          .timeout(const Duration(seconds: 10));
      final signedIn = Supabase.instance.client.auth.currentSession != null;
      result = _ProbeResult.green(
        signedIn ? 'Reachable, signed in.' : 'Reachable, not signed in.',
      );
    } catch (e) {
      result = _ProbeResult.red('Supabase unreachable: $e');
    }
    if (!mounted) return;
    setState(() => _supabaseConn = result);
  }

  Future<void> _runSqliteProbe() async {
    _ProbeResult result;
    try {
      // Bounded SELECT that exercises the migration path. If the schema
      // version is wrong or the file is corrupt, this will throw before
      // returning.
      final storage = SyncService.instance.storage;
      final rows = await storage.db.rawQuery(
        'SELECT COUNT(*) AS c FROM sessions LIMIT 1',
      );
      final count = rows.isNotEmpty ? rows.first['c'] : null;
      result = _ProbeResult.green(
        'Local DB ok. sessions.count=${count ?? '?'}.',
      );
    } catch (e) {
      result = _ProbeResult.red('SQLite check failed: $e');
    }
    if (!mounted) return;
    setState(() => _sqlite = result);
  }

  Future<void> _runPendingOpsProbe() async {
    _ProbeResult result;
    try {
      final depth =
          await SyncService.instance.storage.countPendingOps();
      if (depth == 0) {
        result = _ProbeResult.green('No pending operations.');
      } else if (depth < 10) {
        result = _ProbeResult.amber(
          '$depth pending op(s) — should flush on next sync.',
        );
      } else {
        result = _ProbeResult.red(
          '$depth pending ops — queue is not draining; check connectivity.',
        );
      }
    } catch (e) {
      result = _ProbeResult.red('Pending-ops read failed: $e');
    }
    if (!mounted) return;
    setState(() => _pendingOps = result);
  }

  @override
  Widget build(BuildContext context) {
    final signedIn = AuthService.instance.currentSession?.user;

    return Scaffold(
      backgroundColor: AppColors.surfaceBg,
      appBar: AppBar(
        backgroundColor: AppColors.surfaceBg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text(
          'Diagnostics',
          style: TextStyle(
            fontFamily: 'Montserrat',
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: AppColors.textOnDark,
          ),
        ),
        iconTheme: const IconThemeData(color: AppColors.textOnDark),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            color: AppColors.textOnDark,
            tooltip: 'Re-run probes',
            onPressed: _running
                ? null
                : () {
                    HapticFeedback.selectionClick();
                    _runAll();
                  },
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            _IntroCard(signedInEmail: signedIn?.email),
            const SizedBox(height: 16),
            _ProbeGroup(
              title: 'Boot probes',
              children: [
                _ProbeRow(
                  label: 'Signed-URL self-check',
                  subtitle:
                      'vault secrets + sign_storage_url() end-to-end',
                  result: _signedUrl,
                ),
                _Divider(),
                _ProbeRow(
                  label: 'Supabase connectivity',
                  subtitle: 'anon key + auth.getUser()',
                  result: _supabaseConn,
                ),
                _Divider(),
                _ProbeRow(
                  label: 'Local SQLite',
                  subtitle: 'schema migrations + cache tables readable',
                  result: _sqlite,
                ),
                _Divider(),
                _ProbeRow(
                  label: 'Pending ops queue',
                  subtitle: 'offline-first sync backlog depth',
                  result: _pendingOps,
                ),
              ],
            ),
            const SizedBox(height: 24),
            _MetaCard(
              practiceId: AuthService.instance.currentPracticeId.value,
              pendingCount: SyncService.instance.pendingOpCount.value,
              offline: SyncService.instance.offline.value,
              sha: AppConfig.buildSha,
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Result types + visual rendering
// ---------------------------------------------------------------------------

enum _ProbeState { green, amber, red }

class _ProbeResult {
  final _ProbeState state;
  final String detail;
  const _ProbeResult._(this.state, this.detail);
  factory _ProbeResult.green(String detail) =>
      _ProbeResult._(_ProbeState.green, detail);
  factory _ProbeResult.amber(String detail) =>
      _ProbeResult._(_ProbeState.amber, detail);
  factory _ProbeResult.red(String detail) =>
      _ProbeResult._(_ProbeState.red, detail);
}

class _IntroCard extends StatelessWidget {
  final String? signedInEmail;
  const _IntroCard({this.signedInEmail});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceBase,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: AppColors.surfaceBorder, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Live health probes',
            style: TextStyle(
              fontFamily: 'Montserrat',
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: AppColors.textOnDark,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            signedInEmail == null
                ? 'Each row runs on open and again every refresh. '
                    'If anything is red, tap the chip for context.'
                : 'Signed in as $signedInEmail. Each row runs on open '
                    'and again every refresh.',
            style: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 13,
              height: 1.45,
              color: AppColors.textSecondaryOnDark,
            ),
          ),
        ],
      ),
    );
  }
}

class _ProbeGroup extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _ProbeGroup({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
          child: Text(
            title.toUpperCase(),
            style: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.0,
              color: AppColors.textSecondaryOnDark,
            ),
          ),
        ),
        Container(
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
        ),
      ],
    );
  }
}

class _ProbeRow extends StatelessWidget {
  final String label;
  final String subtitle;
  final _ProbeResult? result;
  const _ProbeRow({
    required this.label,
    required this.subtitle,
    required this.result,
  });

  Color _chipColor() {
    final r = result;
    if (r == null) return AppColors.surfaceBorder;
    switch (r.state) {
      case _ProbeState.green:
        return AppColors.success;
      case _ProbeState.amber:
        return AppColors.warning;
      case _ProbeState.red:
        return AppColors.error;
    }
  }

  String _chipText() {
    final r = result;
    if (r == null) return '…';
    switch (r.state) {
      case _ProbeState.green:
        return 'PASS';
      case _ProbeState.amber:
        return 'WARN';
      case _ProbeState.red:
        return 'FAIL';
    }
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: result == null
          ? null
          : () {
              HapticFeedback.selectionClick();
              _showDetail(context, label, result!);
            },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textOnDark,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    result?.detail ?? subtitle,
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 12,
                      color: AppColors.textSecondaryOnDark,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: _chipColor().withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: _chipColor(), width: 1),
              ),
              child: Text(
                _chipText(),
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                  color: _chipColor(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showDetail(
    BuildContext context,
    String label,
    _ProbeResult r,
  ) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            '$label: ${r.detail}',
            style: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 13,
              color: AppColors.textOnDark,
            ),
          ),
          backgroundColor: AppColors.surfaceRaised,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 6),
          action: SnackBarAction(
            label: 'Copy',
            textColor: AppColors.primary,
            onPressed: () {
              Clipboard.setData(ClipboardData(text: r.detail));
            },
          ),
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

class _MetaCard extends StatelessWidget {
  final String? practiceId;
  final int pendingCount;
  final bool offline;
  final String sha;
  const _MetaCard({
    required this.practiceId,
    required this.pendingCount,
    required this.offline,
    required this.sha,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceBase,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: AppColors.surfaceBorder, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Context',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.0,
              color: AppColors.textSecondaryOnDark,
            ),
          ),
          const SizedBox(height: 10),
          _MetaRow(label: 'Build SHA', value: sha),
          _MetaRow(
            label: 'Practice',
            value: practiceId ?? '(none)',
          ),
          _MetaRow(
            label: 'Pending ops',
            value: pendingCount.toString(),
          ),
          _MetaRow(
            label: 'Connectivity',
            value: offline ? 'offline' : 'online',
          ),
          _MetaRow(
            label: 'Debug build',
            value: kDebugMode ? 'yes' : 'no',
          ),
        ],
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  final String label;
  final String value;
  const _MetaRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          SizedBox(
            width: 120,
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
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
