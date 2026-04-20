import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../models/cached_client.dart';
import '../models/cached_practice.dart';
import '../models/pending_op.dart';
import 'api_client.dart';
import 'local_storage_service.dart';

/// Orchestrator for the offline-first sync loop.
///
/// ## Philosophy
///
/// Reads come from SQLite. Writes land in SQLite first, then are
/// queued in `pending_ops` for eventual push to the cloud. The cloud
/// is treated as a replica of the device's view — not the source of
/// truth for the user's most recent intent — so the UI never waits on
/// the network for obvious visual confirmation of a user action.
///
/// Publish stays online-only (see upload_service.dart); the stakes of
/// misbilling across practice switches justify the loss of offline
/// capability for that one flow.
///
/// ## Conflict resolution
///
/// **Last-write-wins, silently.** Two scenarios can produce conflicts:
///
///   1. **Name conflict on offline-create** — Two devices (or the same
///      device across multiple offline mints) both create a client
///      with the same name in the same practice. The cloud returns the
///      id of whichever row won the race; the losing device detects
///      `returnedId != sentId`, rewires local `cached_clients.id` and
///      every `sessions.client_id` reference to the winning id, and
///      deletes its local-id row. The UI does NOT prompt the user —
///      the loser's sessions land correctly under the winning row as
///      if this had always been one client.
///
///   2. **Out-of-order rename** — Device A renames to X, Device B to
///      Y offline, both sync. Whichever op's RPC lands last at the
///      cloud wins. The pulls on the losing device will bring the
///      latest name on the next sync cycle.
///
/// A [debugPrint] diagnostic trail records every rewire / retry so
/// post-incident forensics are possible. No user-facing conflict sheet
/// for MVP — adds friction for the 99% case, diagnostic trail covers
/// the 1%.
///
/// ## When does `pullAll` run?
///
/// - On first construction + `bind(practiceId)` call (boot).
/// - When [currentPracticeId] changes (practice switch).
/// - Immediately after a successful [flush] (server state may have
///   moved; refresh the cache).
/// - When connectivity flips offline → online.
///
/// [flush] runs:
/// - After every [enqueue] (best-effort immediate push).
/// - On the same offline→online transitions.
///
/// ## Dependencies
///
/// - [LocalStorageService] for SQLite CRUD.
/// - [ApiClient] for the cloud RPCs.
/// - `connectivity_plus` for online/offline transitions. If the plugin
///   is unavailable (fresh install, simulator quirk), the stream emits
///   an error and we treat the device as online-optimistic — the first
///   RPC call decides.
class SyncService {
  SyncService({required LocalStorageService storage}) : _storage = storage;

  static SyncService? _instance;

  /// Returns the process-wide singleton. Must be created and bound
  /// once at app startup (see main.dart bootstrap path).
  static SyncService get instance {
    final s = _instance;
    if (s == null) {
      throw StateError(
        'SyncService.configure(storage) must be called before use',
      );
    }
    return s;
  }

  /// One-time configure. Idempotent — repeated calls are no-ops so
  /// hot-reload in dev doesn't double-subscribe the connectivity
  /// listener.
  static void configure(LocalStorageService storage) {
    if (_instance != null) return;
    _instance = SyncService(storage: storage);
  }

  final LocalStorageService _storage;
  final Uuid _uuid = const Uuid();

  /// Direct read access to the local cache layer. Exposed so UI widgets
  /// deep in the tree (PracticeChip, PracticeSwitcherSheet) don't need
  /// to thread a [LocalStorageService] through widget constructors.
  /// Prefer the higher-level pull*/queue* methods for anything
  /// mutating; this is read-only convenience.
  LocalStorageService get storage => _storage;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  /// True while a flush() is running. Guards against re-entrant drain
  /// kicked off by multiple enqueue() calls in quick succession.
  bool _flushing = false;

  /// Running count of unsynced pending ops + offline hint. Bind in the
  /// UI via [ValueListenableBuilder] to render the "N pending" chip.
  final ValueNotifier<int> pendingOpCount = ValueNotifier<int>(0);

  /// True when connectivity_plus reports we have no network. Treated
  /// optimistically — when the plugin errors we assume online.
  final ValueNotifier<bool> offline = ValueNotifier<bool>(false);

  /// Call from app startup after LocalStorageService.init(). Wires the
  /// connectivity listener and seeds the pending-count notifier from
  /// persisted state.
  Future<void> start() async {
    await _refreshPendingCount();
    try {
      _connectivitySub = Connectivity().onConnectivityChanged.listen(
        _onConnectivityChanged,
        onError: (_) {
          // Plugin errored — assume online-optimistic. Next enqueue
          // will retry the plugin by reading its current value.
          offline.value = false;
        },
      );
      // Prime the initial state too, because `onConnectivityChanged`
      // only fires on transitions.
      final initial = await Connectivity().checkConnectivity();
      offline.value = _isOffline(initial);
    } catch (e) {
      debugPrint('SyncService.start: connectivity plugin unavailable: $e');
      offline.value = false;
    }
  }

  void dispose() {
    _connectivitySub?.cancel();
    _connectivitySub = null;
  }

  static bool _isOffline(List<ConnectivityResult> results) {
    if (results.isEmpty) return true;
    // connectivity_plus returns [ConnectivityResult.none] when offline.
    return results.every((r) => r == ConnectivityResult.none);
  }

  Future<void> _onConnectivityChanged(List<ConnectivityResult> results) async {
    final wasOffline = offline.value;
    final isOfflineNow = _isOffline(results);
    offline.value = isOfflineNow;
    if (wasOffline && !isOfflineNow) {
      // Offline → online. Fire a flush + pullAll for the currently
      // bound practice. Kick off in parallel; errors are swallowed
      // inside each call.
      debugPrint('SyncService: online — draining pending ops');
      await flush();
      final practiceId = _lastPracticeId;
      if (practiceId != null) {
        await pullAll(practiceId);
      }
    }
  }

  /// Last practice id we were asked to pull. Re-used by the
  /// connectivity listener so the app re-refreshes the same practice
  /// on reconnect without the caller having to wire it in.
  String? _lastPracticeId;

  /// Full refresh for a practice. Fires every pull in parallel;
  /// individual failures are logged + swallowed — a partial sync is
  /// still useful.
  ///
  /// Returns when all branches complete (success OR swallowed error).
  /// See [SyncPullOutcome] for the two signals the UI cares about:
  ///
  /// * [SyncPullOutcome.anySucceeded] — at least one branch landed; UIs
  ///   can use it to refresh the "updated X min ago" hint.
  /// * [SyncPullOutcome.hadError] — at least one branch threw an RPC
  ///   error (i.e. the device is online but the cloud rejected us).
  ///   Drives the "Couldn't refresh. Tap to retry." banner on Home so
  ///   a silent RPC failure never masquerades as "you have no clients".
  Future<SyncPullOutcome> pullAll(String practiceId) async {
    _lastPracticeId = practiceId;
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    // Fire all four in parallel. Each catches its own errors so a
    // single failure doesn't poison the others.
    final results = await Future.wait<_BranchOutcome>([
      _pullPractices(),
      _pullClients(practiceId, nowMs),
      _pullCreditBalance(practiceId, nowMs),
      _backfillSessionClientIds(practiceId),
    ]);
    return SyncPullOutcome(
      anySucceeded: results.any((r) => r == _BranchOutcome.ok),
      hadError: results.any((r) => r == _BranchOutcome.error),
    );
  }

  Future<_BranchOutcome> _pullPractices() async {
    try {
      final memberships = await ApiClient.instance.listMyPractices();
      // listMyPractices doesn't carry joined_at — we re-fetch via the
      // raw practice_members query below so the cache can order by
      // joined_at. Kept in one place to avoid broadening ApiClient.
      // Tolerate either shape: if the richer query fails, fall back
      // to "use nowMs as joined_at stand-in, same for all rows".
      final userId = ApiClient.instance.currentUserId;
      Map<String, int> joinedAtByPracticeId = <String, int>{};
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (userId != null) {
        try {
          final rows = await ApiClient.instance.raw
              .from('practice_members')
              .select('practice_id, joined_at')
              .eq('trainer_id', userId);
          for (final r in rows) {
            final pid = r['practice_id'];
            final ja = r['joined_at'];
            if (pid is String) {
              if (ja is String) {
                final parsed = DateTime.tryParse(ja);
                if (parsed != null) {
                  joinedAtByPracticeId[pid] = parsed.millisecondsSinceEpoch;
                }
              } else if (ja is int) {
                joinedAtByPracticeId[pid] = ja;
              }
            }
          }
        } catch (e) {
          debugPrint('SyncService._pullPractices: joined_at fetch failed: $e');
        }
      }

      final cached = memberships
          .map((m) => CachedPractice(
                id: m.id,
                name: m.name,
                role: m.role,
                joinedAt: joinedAtByPracticeId[m.id] ?? nowMs,
                syncedAt: nowMs,
              ))
          .toList(growable: false);
      await _storage.replaceCachedPractices(cached);
      return _BranchOutcome.ok;
    } catch (e) {
      debugPrint('SyncService._pullPractices: $e');
      return _BranchOutcome.error;
    }
  }

  Future<_BranchOutcome> _pullClients(String practiceId, int nowMs) async {
    try {
      // Use the throwing variant so an RPC failure bubbles up here
      // instead of silently returning `[]` and making it look like the
      // practice has no clients. The Home screen reads [hadError] from
      // the outcome and shows a "Couldn't refresh" banner.
      final clients = await ApiClient.instance
          .listPracticeClientsOrThrow(practiceId);
      final cached = clients
          .map((c) => CachedClient(
                id: c.id,
                practiceId: c.practiceId.isNotEmpty ? c.practiceId : practiceId,
                name: c.name,
                grayscaleAllowed: c.grayscaleAllowed,
                colourAllowed: c.colourAllowed,
                syncedAt: nowMs,
                dirty: false,
              ))
          .toList(growable: false);
      await _storage.replaceCachedClientsForPractice(
        practiceId: practiceId,
        clients: cached,
      );
      return _BranchOutcome.ok;
    } catch (e) {
      debugPrint('SyncService._pullClients: $e');
      return _BranchOutcome.error;
    }
  }

  Future<_BranchOutcome> _pullCreditBalance(
    String practiceId,
    int nowMs,
  ) async {
    try {
      final balance = await ApiClient.instance
          .practiceCreditBalance(practiceId: practiceId);
      if (balance == null) {
        // A null balance isn't an error per se (RPC responded but had
        // nothing to say) — treat as "no-op" so we don't flash the
        // error banner on a perfectly healthy empty response.
        return _BranchOutcome.noop;
      }
      await _storage.upsertCachedCreditBalance(
        practiceId: practiceId,
        balance: balance,
        nowMs: nowMs,
      );
      return _BranchOutcome.ok;
    } catch (e) {
      debugPrint('SyncService._pullCreditBalance: $e');
      return _BranchOutcome.error;
    }
  }

  Future<_BranchOutcome> _backfillSessionClientIds(String practiceId) async {
    try {
      final links = await ApiClient.instance.listPlanClientLinks(practiceId);
      if (links.isEmpty) return _BranchOutcome.ok;
      await _storage.backfillSessionClientIds(
        links
            .map((l) => (planId: l.planId, clientId: l.clientId))
            .toList(growable: false),
      );
      return _BranchOutcome.ok;
    } catch (e) {
      debugPrint('SyncService._backfillSessionClientIds: $e');
      return _BranchOutcome.error;
    }
  }

  // ---------------------------------------------------------------------------
  // Enqueue + local write helpers. These are the PUBLIC write API for
  // the UI layer — NewClientSheet / ClientSessionsScreen /
  // ClientConsentSheet all go through one of these.
  // ---------------------------------------------------------------------------

  /// Local-first create of a new client. Writes a dirty
  /// `cached_clients` row and enqueues an `upsert_client_with_id` op.
  /// Triggers a best-effort immediate [flush] so online-path latency
  /// feels unchanged.
  ///
  /// Returns the freshly minted client id. For offline-optimistic UI
  /// use: show a client with this id straight away, SyncService will
  /// rewire if a conflict lands.
  Future<CachedClient> queueCreateClient({
    required String practiceId,
    required String name,
  }) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final clientId = _uuid.v4();
    final cached = CachedClient(
      id: clientId,
      practiceId: practiceId,
      name: name.trim(),
      syncedAt: null,
      dirty: true,
    );
    await _storage.upsertCachedClient(cached);
    final op = PendingOp.upsertClient(
      opId: _uuid.v4(),
      clientId: clientId,
      practiceId: practiceId,
      name: cached.name,
      nowMs: nowMs,
    );
    await _storage.enqueuePendingOp(op);
    await _refreshPendingCount();
    // Best-effort immediate push — if offline, this is a quick no-op.
    unawaited(flush());
    return cached;
  }

  /// Local-first rename. Writes the new name into cached_clients with
  /// dirty=1 and queues a rename_client op.
  Future<CachedClient?> queueRenameClient({
    required String clientId,
    required String newName,
  }) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final trimmed = newName.trim();
    // Load current row so we can keep the consent flags intact.
    final rows = await _storage.db.query(
      'cached_clients',
      where: 'id = ?',
      whereArgs: [clientId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final current = CachedClient.fromMap(rows.first);
    final updated = current.copyWith(name: trimmed, dirty: true);
    await _storage.upsertCachedClient(updated);
    final op = PendingOp.renameClient(
      opId: _uuid.v4(),
      clientId: clientId,
      newName: trimmed,
      nowMs: nowMs,
    );
    await _storage.enqueuePendingOp(op);
    await _refreshPendingCount();
    unawaited(flush());
    return updated;
  }

  /// Local-first consent write.
  Future<CachedClient?> queueSetConsent({
    required String clientId,
    required bool grayscaleAllowed,
    required bool colourAllowed,
  }) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final rows = await _storage.db.query(
      'cached_clients',
      where: 'id = ?',
      whereArgs: [clientId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final current = CachedClient.fromMap(rows.first);
    final updated = current.copyWith(
      grayscaleAllowed: grayscaleAllowed,
      colourAllowed: colourAllowed,
      dirty: true,
    );
    await _storage.upsertCachedClient(updated);
    final op = PendingOp.setConsent(
      opId: _uuid.v4(),
      clientId: clientId,
      grayscaleAllowed: grayscaleAllowed,
      colourAllowed: colourAllowed,
      nowMs: nowMs,
    );
    await _storage.enqueuePendingOp(op);
    await _refreshPendingCount();
    unawaited(flush());
    return updated;
  }

  // ---------------------------------------------------------------------------
  // Drain
  // ---------------------------------------------------------------------------

  /// Try to push every queued op. Each op is independent — a failure
  /// on op N doesn't block op N+1. Idempotent: running twice in a row
  /// with no new ops is a no-op.
  ///
  /// Returns the number of ops successfully flushed this call.
  Future<int> flush() async {
    if (_flushing) return 0;
    _flushing = true;
    var flushed = 0;
    try {
      final ops = await _storage.getPendingOps();
      for (final op in ops) {
        try {
          final delta = await _applyOp(op);
          if (delta) {
            await _storage.deletePendingOp(op.id);
            flushed += 1;
          }
        } catch (e) {
          final code = _extractErrorCode(e);
          final msg = e.toString();
          final nowMs = DateTime.now().millisecondsSinceEpoch;
          await _storage.markPendingOpFailed(
            id: op.id,
            error: msg,
            nowMs: nowMs,
          );
          debugPrint('SyncService.flush: op ${op.type.name} '
              'id=${op.id} failed (code=$code): $msg');
          // Don't break — keep draining subsequent ops. Each is
          // independent and some may succeed.
        }
      }
    } finally {
      _flushing = false;
      await _refreshPendingCount();
    }
    if (flushed > 0) {
      // Server state may have moved — refresh cache for the last
      // known practice. Fire-and-forget.
      final pid = _lastPracticeId;
      if (pid != null) {
        unawaited(pullAll(pid));
      }
    }
    return flushed;
  }

  /// Dispatch one op to the cloud. Returns true if the op landed
  /// (so it can be deleted from the queue); false if it should stay
  /// queued (shouldn't happen today — all paths either return true or
  /// throw).
  Future<bool> _applyOp(PendingOp op) async {
    switch (op.type) {
      case PendingOpType.upsertClient:
        final clientId = op.payload['client_id'] as String?;
        final practiceId = op.payload['practice_id'] as String?;
        final name = op.payload['name'] as String?;
        if (clientId == null || practiceId == null || name == null) {
          return true; // drop malformed op
        }
        final returned = await ApiClient.instance.upsertClientWithId(
          clientId: clientId,
          practiceId: practiceId,
          name: name,
        );
        if (returned == null) return false;
        if (returned != clientId) {
          // Name-conflict rewire — server returned the id of a DIFFERENT
          // existing client. Move local state over.
          await _rewireClient(fromId: clientId, toId: returned);
        } else {
          // Happy path: mark the row clean.
          await _storage.db.rawUpdate(
            'UPDATE cached_clients SET dirty = 0, synced_at = ? WHERE id = ?',
            [DateTime.now().millisecondsSinceEpoch, clientId],
          );
        }
        return true;

      case PendingOpType.renameClient:
        final clientId = op.payload['client_id'] as String?;
        final newName = op.payload['new_name'] as String?;
        if (clientId == null || newName == null) return true;
        await ApiClient.instance.renameClient(
          clientId: clientId,
          newName: newName,
        );
        await _storage.db.rawUpdate(
          'UPDATE cached_clients SET dirty = 0, synced_at = ? WHERE id = ?',
          [DateTime.now().millisecondsSinceEpoch, clientId],
        );
        return true;

      case PendingOpType.setConsent:
        final clientId = op.payload['client_id'] as String?;
        final grayscale = op.payload['grayscale_allowed'] as bool?;
        final colour = op.payload['colour_allowed'] as bool?;
        if (clientId == null || grayscale == null || colour == null) return true;
        final ok = await ApiClient.instance.setClientVideoConsent(
          clientId: clientId,
          lineAllowed: true,
          grayscaleAllowed: grayscale,
          colourAllowed: colour,
        );
        if (!ok) {
          throw Exception('set_client_video_consent returned false');
        }
        await _storage.db.rawUpdate(
          'UPDATE cached_clients SET dirty = 0, synced_at = ? WHERE id = ?',
          [DateTime.now().millisecondsSinceEpoch, clientId],
        );
        return true;
    }
  }

  /// Handle a name-conflict: the cloud returned the id of an existing
  /// client instead of minting a fresh row with our local id. Move
  /// every local reference from the local id to the server id.
  Future<void> _rewireClient({
    required String fromId,
    required String toId,
  }) async {
    debugPrint('SyncService: rewiring client $fromId -> $toId (name conflict)');
    await _storage.db.transaction((txn) async {
      // Move session.client_id references to the winning id.
      await txn.rawUpdate(
        'UPDATE sessions SET client_id = ? WHERE client_id = ?',
        [toId, fromId],
      );
      // If a row with toId already exists in cached_clients (likely —
      // the winning row was cached earlier), just delete the loser. If
      // toId doesn't exist yet, upgrade the loser's row to the winning
      // id.
      final existing = await txn.query(
        'cached_clients',
        where: 'id = ?',
        whereArgs: [toId],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        await txn.delete(
          'cached_clients',
          where: 'id = ?',
          whereArgs: [fromId],
        );
      } else {
        await txn.update(
          'cached_clients',
          <String, Object?>{
            'id': toId,
            'dirty': 0,
            'synced_at': DateTime.now().millisecondsSinceEpoch,
          },
          where: 'id = ?',
          whereArgs: [fromId],
        );
      }
    });
  }

  Future<void> _refreshPendingCount() async {
    final c = await _storage.countPendingOps();
    if (c != pendingOpCount.value) {
      pendingOpCount.value = c;
    }
  }

  /// Extract the PostgREST / Postgres SQLSTATE code from an arbitrary
  /// exception. Returns null when the shape is unrecognised. Today
  /// only used for the debug log — SyncService retries all errors the
  /// same way; distinguishing recoverable from unrecoverable is a
  /// post-MVP sharpening.
  String? _extractErrorCode(Object e) {
    if (e is PostgrestException) return e.code;
    return null;
  }
}

/// Outcome of a single [SyncService.pullAll] branch.
enum _BranchOutcome {
  /// The branch completed and committed new data to the cache.
  ok,

  /// The branch completed but had nothing useful to commit (e.g. the
  /// RPC returned null / empty). Not an error — still a clean round-
  /// trip with the cloud.
  noop,

  /// The branch threw — either the RPC errored server-side or the
  /// network failed mid-request. Either way the cache was NOT updated
  /// and the UI should treat this as "we couldn't talk to the cloud
  /// right now".
  error,
}

/// Result of a [SyncService.pullAll] invocation. Carries two signals:
///
/// * [anySucceeded] — at least one branch landed fresh data.
/// * [hadError] — at least one branch threw. Connectivity is checked
///   separately via [SyncService.offline]; the caller should combine
///   the two to tell "offline, expected" (silent) from "online but RPC
///   failed" (surface to user).
///
/// This replaces the plain `bool` that [pullAll] used to return, which
/// couldn't distinguish "partial success" from "total silent failure".
@immutable
class SyncPullOutcome {
  final bool anySucceeded;
  final bool hadError;

  const SyncPullOutcome({
    required this.anySucceeded,
    required this.hadError,
  });
}
