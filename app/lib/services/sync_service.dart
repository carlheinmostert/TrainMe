import 'dart:async';
import 'dart:developer' as dev;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../models/cached_client.dart';
import '../models/cached_practice.dart';
import '../models/pending_op.dart';
import 'api_client.dart';
import 'client_defaults_api.dart';
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
  StreamSubscription<AuthState>? _authSub;

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

    // Dump any stuck queue contents so we can diagnose via os_log. This
    // fires on every cold boot, only when the queue is non-empty.
    if (pendingOpCount.value > 0) {
      try {
        final ops = await _storage.getPendingOps();
        dev.log(
          'boot — ${ops.length} pending ops in queue',
          name: 'SyncService',
        );
        for (final op in ops.take(30)) {
          dev.log(
            '  ${op.type.name} id=${op.id} attempts=${op.attempts} '
            'last_error=${op.lastError ?? "(none)"}',
            name: 'SyncService',
          );
        }
      } catch (e) {
        dev.log('boot queue dump failed: $e', name: 'SyncService');
      }
    }

    // Drain-on-boot. Previously the queue only flushed on offline→online
    // transitions, which left cold-start-with-stuck-queue scenarios
    // silently idle. Fire-and-forget; failures land in the per-op catch
    // block and surface via dev.log.
    unawaited(flush());

    // Auth-state listener: fire a flush whenever the user (re-)signs in.
    // Before this, a sign-out + sign-in cycle left the queue stuck with
    // stale-JWT errors until the user happened to enqueue another op.
    // Fix: on signedIn events, drain the queue against the new session.
    //
    // Wave 15 polish — also fire a `pullAll` for the last-known practice
    // on signedIn so the newly-authed session refreshes cache state
    // that may have moved server-side while the token was revoked.
    // pullAll is guarded on _lastPracticeId being non-null (fresh
    // sign-ins haven't bound a practice yet; the bootstrap path does
    // that separately).
    try {
      _authSub = Supabase.instance.client.auth.onAuthStateChange.listen(
        (state) {
          if (state.event == AuthChangeEvent.signedIn ||
              state.event == AuthChangeEvent.tokenRefreshed) {
            dev.log(
              'auth ${state.event.name} — draining pending ops',
              name: 'SyncService',
            );
            unawaited(flush());
            final pid = _lastPracticeId;
            if (state.event == AuthChangeEvent.signedIn && pid != null) {
              dev.log(
                'auth signedIn — refreshing cache for $pid',
                name: 'SyncService',
              );
              unawaited(pullAll(pid));
            }
          }
        },
        onError: (_) {
          // Plugin errored — don't die; connectivity listener is the
          // fallback drain trigger.
        },
      );
    } catch (e) {
      debugPrint('SyncService.start: auth listener attach failed: $e');
    }
  }

  void dispose() {
    _connectivitySub?.cancel();
    _connectivitySub = null;
    _authSub?.cancel();
    _authSub = null;
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
      dev.log('online transition — draining pending ops', name: 'SyncService');
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
      // Go through the raw RPC surface so the new
      // `client_exercise_defaults` jsonb (Milestone R / Wave 8) lands
      // in the cache alongside consent + name. The typed
      // `ApiClient.listPracticeClientsOrThrow` drops the defaults
      // through the `PracticeClient` projection; the raw read
      // preserves them on the wire map.
      final rawRows = await ClientDefaultsApi.instance
          .listPracticeClientsRaw(practiceId);
      final cached = rawRows.map((row) {
        final withPractice = Map<String, dynamic>.from(row);
        // The RPC omits practice_id (it's bound by the input param) —
        // backfill so CachedClient.fromCloudJson can populate it.
        withPractice.putIfAbsent('practice_id', () => practiceId);
        return CachedClient.fromCloudJson(withPractice, nowMs: nowMs);
      }).toList(growable: false);
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
    final current = await _loadCachedClientRaw(clientId);
    if (current == null) return null;
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

  /// Local-first delete. Soft-deletes the cached client row AND
  /// cascades a tombstone onto every local session that belongs to the
  /// client. Returns the cascade timestamp (epoch ms) which the caller
  /// should hold onto — [queueRestoreClient] needs it to reverse the
  /// same cascade on undo.
  ///
  /// The cloud side is handled idempotently by the `delete_client` RPC;
  /// replay-safe, returns the existing tombstoned row if already
  /// deleted.
  Future<int> queueDeleteClient({
    required String clientId,
  }) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final cascadeTs = await _storage.softDeleteClientCascade(
      clientId: clientId,
    );
    final op = PendingOp.deleteClient(
      opId: _uuid.v4(),
      clientId: clientId,
      nowMs: nowMs,
    );
    await _storage.enqueuePendingOp(op);
    await _refreshPendingCount();
    unawaited(flush());
    return cascadeTs;
  }

  /// Reverse a [queueDeleteClient]. Restores the cached client + any
  /// session soft-deleted at [cascadeTimestampMs]. Queues a
  /// `restore_client` op for eventual cloud push.
  Future<void> queueRestoreClient({
    required String clientId,
    required int cascadeTimestampMs,
  }) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    await _storage.restoreClientCascade(
      clientId: clientId,
      cascadeTimestampMs: cascadeTimestampMs,
    );
    final op = PendingOp.restoreClient(
      opId: _uuid.v4(),
      clientId: clientId,
      nowMs: nowMs,
    );
    await _storage.enqueuePendingOp(op);
    await _refreshPendingCount();
    unawaited(flush());
  }

  /// Local-first consent write.
  Future<CachedClient?> queueSetConsent({
    required String clientId,
    required bool grayscaleAllowed,
    required bool colourAllowed,
  }) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final current = await _loadCachedClientRaw(clientId);
    if (current == null) return null;
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

  /// Local-first sticky-default write (Milestone R / Wave 8).
  ///
  /// Called from the Studio card whenever the practitioner overrides
  /// one of the seven sticky fields (reps / sets / hold_seconds /
  /// include_audio / preferred_treatment / prep_seconds /
  /// custom_duration_seconds) on a NEW capture. Writes the new value
  /// into [CachedClient.clientExerciseDefaults] in-memory / on-disk,
  /// queues the RPC, and best-effort flushes.
  ///
  /// [value] must be JSON-encodable (bool, num, String, null). Null
  /// means "clear this field" — the next new capture reverts to the
  /// [StudioDefaults] global fallback.
  ///
  /// Returns the updated cache row so the caller can immediately refresh
  /// its in-memory state. Null when [clientId] doesn't resolve to a
  /// cached row (legacy sessions without client_id — we just skip).
  Future<CachedClient?> queueSetExerciseDefault({
    required String clientId,
    required String field,
    required Object? value,
  }) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final current = await _loadCachedClientRaw(clientId);
    if (current == null) return null;
    final nextDefaults = Map<String, dynamic>.from(
      current.clientExerciseDefaults,
    );
    if (value == null) {
      nextDefaults.remove(field);
    } else {
      nextDefaults[field] = value;
    }
    final updated = current.copyWith(
      clientExerciseDefaults: nextDefaults,
      dirty: true,
    );
    await _storage.upsertCachedClient(updated);
    final op = PendingOp.setExerciseDefault(
      opId: _uuid.v4(),
      clientId: clientId,
      field: field,
      value: value,
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

  /// Minimum time between successive retries of the same op. Prevents a
  /// burst of `enqueue → flush` calls from hammering the server when a
  /// recently-failed op will almost certainly fail again within the
  /// same few seconds (bad token, captive portal, RLS mismatch). The op
  /// is still retried on the next reconnect / auth event / force-sync
  /// after the cool-down. 5s matches the shortest observable recovery
  /// latency on LTE in Carl's QA logs.
  static const Duration _retryCooldown = Duration(seconds: 5);

  /// Hard cap on per-op retry attempts before the op is dropped as a
  /// safety net (prevents an unknown-error class from bloating the queue
  /// forever). ~30 attempts ≈ a full day of reconnect cycles at the
  /// [_retryCooldown] tick rate.
  static const int _maxAttempts = 30;

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
      final nowMsAtStart = DateTime.now().millisecondsSinceEpoch;
      for (final op in ops) {
        // Wave 15 polish — skip ops we retried within the cool-down
        // window. Prevents two rapid enqueues from firing back-to-back
        // flushes against a known-broken session (e.g. session_not_found
        // loop pre-Wave-15). The op stays in the queue and the next
        // natural drain trigger (reconnect, auth refresh, manual force
        // sync, cold boot) will pick it up.
        final lastAttempt = op.lastAttemptAt;
        if (lastAttempt != null &&
            nowMsAtStart - lastAttempt < _retryCooldown.inMilliseconds) {
          continue;
        }
        try {
          final delta = await _applyOp(op);
          if (delta) {
            await _storage.deletePendingOp(op.id);
            flushed += 1;
          }
        } catch (e) {
          final code = _extractErrorCode(e);
          final msg = e.toString();

          // "Client missing on server" class of errors — the intended
          // state (rename / update defaults / consent on client X) is
          // moot because X is gone. Drop the op instead of retrying.
          // Matches the drop-semantics we gave delete_client + restore_client
          // in the schema_fix_delete_restore_idempotent.sql migration.
          if (_isStaleOpAgainstMissingClient(e, op.type)) {
            await _dropOp(op, reason: 'stale — client missing', detail: msg);
            flushed += 1;
            continue;
          }

          // Safety net: after 30 failed attempts, drop the op. Prevents
          // any unknown-error class from bloating the queue forever.
          // 30 attempts ≈ a full day of reconnect cycles.
          if (op.attempts >= _maxAttempts) {
            await _dropOp(
              op,
              reason: 'attempts=${op.attempts} exceeded cap',
              detail: msg,
            );
            flushed += 1;
            continue;
          }

          final nowMs = DateTime.now().millisecondsSinceEpoch;
          await _storage.markPendingOpFailed(
            id: op.id,
            error: msg,
            nowMs: nowMs,
          );
          debugPrint('SyncService.flush: op ${op.type.name} '
              'id=${op.id} failed (code=$code): $msg');
          // Profile builds strip debugPrint from os_log; dev.log goes
          // through the VM service + Dart os_log subsystem so it's
          // visible in idevicesyslog / Console.app.
          dev.log(
            'flush ${op.type.name} id=${op.id} code=$code: $msg',
            name: 'SyncService',
          );
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
  /// (so it can be deleted from the queue); throws if it should be
  /// retried. Previously the [upsertClient] branch could return
  /// `false` on a null RPC response, which branched around the flush
  /// loop's catch block entirely — attempts never incremented, the
  /// stale-op classifier never ran, and no dev.log fired. That's how
  /// client fc2c8be9-... became a permanent ghost in Carl's queue.
  /// All paths now either return true or throw so the flush loop's
  /// error handling is the single funnel.
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
        if (returned == null) {
          // Null-return from upsert_client_with_id is rare — it means the
          // RPC succeeded at the transport layer but the DB refused to
          // return a row. Typical causes: practice_id is not a practice
          // the signed-in user is a member of (the SECURITY DEFINER
          // fn's membership check silently drops the row), or a quiet
          // RLS/permission edge case. Throw so the flush's catch block
          // owns recovery: attempts increments, last_error populates,
          // the 30-attempt safety cap applies — same path every other
          // op takes on failure. Without this, the op sat in
          // pending_ops forever with no diagnostic trail.
          throw const UpsertClientNullResultException();
        }
        if (returned != clientId) {
          // Name-conflict rewire — server returned the id of a DIFFERENT
          // existing client. Move local state over.
          await _rewireClient(fromId: clientId, toId: returned);
        } else {
          // Happy path: mark the row clean.
          await _markCachedClientClean(clientId);
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
        await _markCachedClientClean(clientId);
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
        await _markCachedClientClean(clientId);
        return true;

      case PendingOpType.deleteClient:
        final clientId = op.payload['client_id'] as String?;
        if (clientId == null) return true;
        await ApiClient.instance.deleteClient(clientId: clientId);
        // Mark the cached row clean; it stays with `deleted=1` so reads
        // skip it. A subsequent pull will remove it once the server
        // state settles (list_practice_clients filters deleted rows).
        await _markCachedClientClean(clientId);
        return true;

      case PendingOpType.restoreClient:
        final clientId = op.payload['client_id'] as String?;
        if (clientId == null) return true;
        await ApiClient.instance.restoreClient(clientId: clientId);
        await _markCachedClientClean(clientId);
        return true;

      case PendingOpType.setExerciseDefault:
        final clientId = op.payload['client_id'] as String?;
        final field = op.payload['field'] as String?;
        // `value` is intentionally dynamic — the RPC's p_value JSONB
        // accepts bool / num / String / null transparently (the
        // supabase-flutter client JSON-encodes whatever we pass).
        final value = op.payload['value'];
        if (clientId == null || field == null) return true;
        await ClientDefaultsApi.instance.setClientExerciseDefault(
          clientId: clientId,
          field: field,
          value: value,
        );
        await _markCachedClientClean(clientId);
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

  /// Raw cached-client lookup that does NOT filter soft-deleted rows.
  /// Separate from [LocalStorageService.getCachedClientById] because the
  /// queue* helpers need to operate on any row we have a copy of (a
  /// rename issued just before a delete still queues; the cloud
  /// classifier will drop it if necessary). Returns null on miss.
  Future<CachedClient?> _loadCachedClientRaw(String clientId) async {
    final rows = await _storage.db.query(
      'cached_clients',
      where: 'id = ?',
      whereArgs: [clientId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return CachedClient.fromMap(rows.first);
  }

  /// Mark a cached_clients row as clean + stamped with a fresh
  /// `synced_at`. Called after every successful op in [_applyOp] — this
  /// is the single place the SQL literal lives so a future column change
  /// doesn't need six identical edits.
  Future<void> _markCachedClientClean(String clientId) async {
    await _storage.db.rawUpdate(
      'UPDATE cached_clients SET dirty = 0, synced_at = ? WHERE id = ?',
      [DateTime.now().millisecondsSinceEpoch, clientId],
    );
  }

  /// Permanently drop [op] from the queue and emit a diagnostic log
  /// line. Used by the two drop paths in [flush] — stale-op classifier
  /// match + 30-attempt safety cap — so the delete + `dev.log` pair
  /// stays in lockstep regardless of which path fires.
  ///
  /// [reason] is a short classifier (e.g. `stale — client missing`,
  /// `attempts=30 exceeded cap`); [detail] is the stringified exception
  /// from the most recent attempt.
  Future<void> _dropOp(
    PendingOp op, {
    required String reason,
    required String detail,
  }) async {
    await _storage.deletePendingOp(op.id);
    dev.log(
      'flush ${op.type.name} id=${op.id} dropped ($reason): $detail',
      name: 'SyncService',
    );
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

  /// Returns true when the exception indicates that the server-side
  /// client (or plan) the op acts on no longer exists. The op is
  /// semantically moot — the user's intent to mutate X is already
  /// superseded by X being gone — so we drop it from the queue instead
  /// of retrying forever. See the 2026-04-21 post-mortem: a session
  /// invalidation (`session_not_found`) blocked all flushes for an hour,
  /// during which many ops on soon-to-be-deleted clients piled up;
  /// when the JWT recovered, those ops would never succeed and the
  /// queue would otherwise stay stuck forever.
  bool _isStaleOpAgainstMissingClient(Object e, PendingOpType type) {
    final msg = e.toString().toLowerCase();

    // PostgREST 22023 — covers BOTH 'client X not found' (row gone) and
    // 'client has been deleted' (row tombstoned). Set_client_exercise_default,
    // set_client_video_consent, rename_client all return these shapes when
    // the row is missing or soft-deleted on the server.
    if (e is PostgrestException && e.code == '22023' &&
        (msg.contains('not found') || msg.contains('has been deleted'))) {
      return true;
    }

    // PostgREST 23505 — unique_violation on the (practice_id, name)
    // constraint in `clients`. Observed shape:
    //   "a deleted client already uses that name — restore it instead"
    // The practitioner created a client locally while the server still
    // has a tombstoned client with the same name. There's no correct
    // automatic resolution (the intent is ambiguous — did they want
    // to restore the old one or keep a fresh one?). Drop the op; the
    // user can recreate or restore from the recycle bin on the portal.
    if (type == PendingOpType.upsertClient &&
        e is PostgrestException &&
        e.code == '23505' &&
        msg.contains('already uses that name')) {
      return true;
    }

    // renameClient on ApiClient throws RenameClientError(notFound) when
    // the RPC's RETURN QUERY returns zero rows (client absent / deleted).
    // Match the typed exception directly — cheaper + less fragile than
    // stringifying + lower-casing the error and grepping.
    if (type == PendingOpType.renameClient &&
        e is RenameClientError &&
        e.kind == RenameClientErrorKind.notFound) {
      return true;
    }

    // set_client_video_consent returns `false` when the caller isn't a
    // member of the client's practice OR the client is missing. We wrap
    // that in a thrown exception upstream; the message carries the
    // distinctive string.
    if (type == PendingOpType.setConsent &&
        msg.contains('set_client_video_consent returned false')) {
      return true;
    }

    // delete_client / restore_client are already idempotent on missing
    // rows (schema_fix_delete_restore_idempotent.sql), so any thrown
    // error there is NOT a stale-op condition — let the normal retry
    // path handle it.
    return false;
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

/// Raised by [SyncService._applyOp] when `upsert_client_with_id` returns
/// null. Routes through the normal flush catch block so attempts
/// increments, last_error populates, and the 30-attempt safety cap
/// applies — same as every other op failure. The message is deliberately
/// short + distinctive so `_isStaleOpAgainstMissingClient` or a future
/// heuristic can match on it cheaply.
///
/// Not a PostgrestException — the RPC itself didn't throw; it returned
/// null, which is a semantically distinct failure mode. Wrapping it in a
/// typed exception keeps the flush catch block's error string
/// self-describing.
@immutable
class UpsertClientNullResultException implements Exception {
  const UpsertClientNullResultException();

  @override
  String toString() =>
      'UpsertClientNullResultException: upsert_client_with_id returned null';
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
