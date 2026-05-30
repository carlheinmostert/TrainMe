// Coverage for SyncService's offline-queue drain: retry / failure /
// dead-letter / conflict-rewire / no-double-dispatch paths (issue #573).
//
// The SyncService is the backbone of the offline-first architecture — it
// drains `pending_ops`, retries transient RPC failures, drops semantically-
// moot ops, and reconciles a server-side id rewire into the local cache.
// Before this suite none of those paths had a single test; a regression in
// the `_flushing` re-entrancy guard or the 30-attempt safety cap would only
// have surfaced on a practitioner's device.
//
// Harness (no new pubspec deps — see issue #573 brief):
//   * In-memory SQLite via `sqflite_common_ffi` +
//     `LocalStorageService.openForTest` (the #571 seam).
//   * A hand-rolled `_MockApiClient implements ApiClient` driven through
//     `noSuchMethod`. ApiClient's only constructor is private, so it can't
//     be `extends`ed from a test library — `implements` + `noSuchMethod`
//     is the dependency-free way to stand one up. Only the three RPCs the
//     drain dispatches in these tests (upsertClientWithId / renameClient /
//     deleteClient) are overridden; everything else throws via the
//     fallthrough so an unexpected call is loud rather than silent.
//   * `SyncService.withDependencies` (the #571 seam) injects both.
//
// Retry-spacing note: `flush()` skips any op whose `last_attempt_at` is
// inside the 5s `_retryCooldown`. To exercise multi-attempt retries inside
// a fast unit test we back-date `last_attempt_at` between flushes via
// [_ageLastAttempt] — this faithfully drives the same drain path a real
// reconnect / auth-refresh / force-sync would, minus the wall-clock wait.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:raidme/models/cached_client.dart';
import 'package:raidme/models/pending_op.dart';
import 'package:raidme/models/session.dart' as model;
import 'package:raidme/services/api_client.dart';
import 'package:raidme/services/local_storage_service.dart';
import 'package:raidme/services/sync_service.dart';

/// Hand-rolled fake. Implements [ApiClient] via [noSuchMethod] so the test
/// library doesn't need ApiClient's private constructor. Each overridden
/// RPC counts its calls and can be told to throw a configured error for the
/// first N invocations, then return a configured success value.
class _MockApiClient implements ApiClient {
  // --- upsert_client_with_id ---
  int upsertClientCallCount = 0;

  /// When set, the value `upsertClientWithId` returns. `null` exercises the
  /// happy path where the server echoes the SAME id back (set this to the
  /// requested clientId in those tests). A DIFFERENT non-null id triggers
  /// the name-conflict rewire branch.
  String? upsertReturns;

  @override
  Future<String?> upsertClientWithId({
    required String clientId,
    required String practiceId,
    required String name,
  }) async {
    upsertClientCallCount += 1;
    // Default happy path: echo the same id (no rewire).
    return upsertReturns ?? clientId;
  }

  // --- rename_client ---
  int renameClientCallCount = 0;

  /// Number of leading invocations that should throw [renameError] before
  /// the call starts succeeding. Use a huge value for a "permanent error".
  int renameFailTimes = 0;

  /// Error thrown while [renameClientCallCount] <= [renameFailTimes].
  Object renameError = Exception('transient network flake');

  /// Optional completer the call awaits BEFORE doing anything else. Lets a
  /// test hold an in-flight RPC open to probe the re-entrancy guard.
  Completer<void>? renameGate;

  @override
  Future<void> renameClient({
    required String clientId,
    required String newName,
  }) async {
    renameClientCallCount += 1;
    final gate = renameGate;
    if (gate != null) {
      await gate.future;
    }
    if (renameClientCallCount <= renameFailTimes) {
      throw renameError;
    }
    // success — return normally
  }

  // --- delete_client ---
  int deleteClientCallCount = 0;

  @override
  Future<void> deleteClient({required String clientId}) async {
    deleteClientCallCount += 1;
  }

  /// Any ApiClient member the drain didn't expect to touch lands here and
  /// throws, so a test that accidentally exercises an un-stubbed RPC fails
  /// loudly instead of silently returning a Future of null.
  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnimplementedError(
      'Unexpected ApiClient call in test: ${invocation.memberName}',
    );
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  late LocalStorageService storage;
  late _MockApiClient api;
  late SyncService sync;

  setUp(() async {
    storage = await LocalStorageService.openForTest(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    api = _MockApiClient();
    sync = SyncService.withDependencies(api: api, storage: storage);
  });

  tearDown(() async {
    sync.dispose();
    await storage.close();
  });

  // Back-date an op's last_attempt_at far enough in the past that the next
  // flush() is past the 5s _retryCooldown and will actually re-attempt it.
  Future<void> ageLastAttempt(String opId) async {
    await storage.db.rawUpdate(
      'UPDATE pending_ops SET last_attempt_at = ? WHERE id = ?',
      [0, opId],
    );
  }

  // Seed a clean cached_clients row so rename/consent ops have a row to
  // mark clean after a successful flush.
  Future<void> seedClient({
    required String id,
    required String practiceId,
    required String name,
  }) async {
    await storage.upsertCachedClient(
      CachedClient(
        id: id,
        practiceId: practiceId,
        name: name,
        syncedAt: DateTime.now().millisecondsSinceEpoch,
        dirty: true,
      ),
    );
  }

  group('SyncService.flush — transient retry then success', () {
    test('renameClient fails twice, succeeds on the 3rd, clears the queue',
        () async {
      const clientId = 'client-1';
      await seedClient(id: clientId, practiceId: 'p1', name: 'Mel');

      final op = PendingOp.renameClient(
        opId: 'op-rename-1',
        clientId: clientId,
        newName: 'Melissa',
        nowMs: DateTime.now().millisecondsSinceEpoch,
      );
      await storage.enqueuePendingOp(op);

      api.renameFailTimes = 2; // throw on attempts 1 and 2

      // Attempt 1 — fails, op stays queued with attempts=1.
      var flushed = await sync.flush();
      expect(flushed, 0);
      expect(api.renameClientCallCount, 1);
      expect(await storage.countPendingOps(), 1);
      var row = (await storage.getPendingOps()).single;
      expect(row.attempts, 1);
      expect(row.lastError, isNotNull);

      // Attempt 2 — still fails. Age the op so the cooldown gate lets it
      // through.
      await ageLastAttempt(op.id);
      flushed = await sync.flush();
      expect(flushed, 0);
      expect(api.renameClientCallCount, 2);
      expect(await storage.countPendingOps(), 1);

      // Attempt 3 — succeeds. Op deleted, queue empty, cached row clean.
      await ageLastAttempt(op.id);
      flushed = await sync.flush();
      expect(flushed, 1);
      expect(api.renameClientCallCount, 3);
      expect(await storage.countPendingOps(), 0);

      final cached = await storage.getCachedClientById(clientId);
      expect(cached, isNotNull);
      expect(cached!.dirty, isFalse,
          reason: 'a successful flush marks the cached row clean');
    });

    test('cooldown gate skips an op re-attempted within 5s', () async {
      await seedClient(id: 'client-cd', practiceId: 'p1', name: 'A');
      final op = PendingOp.renameClient(
        opId: 'op-cooldown',
        clientId: 'client-cd',
        newName: 'B',
        nowMs: DateTime.now().millisecondsSinceEpoch,
      );
      await storage.enqueuePendingOp(op);
      api.renameFailTimes = 99; // always fails

      // First flush attempts + fails (stamps last_attempt_at ~ now).
      await sync.flush();
      expect(api.renameClientCallCount, 1);

      // Immediate second flush — within the cooldown window, so the op is
      // skipped, NOT re-dispatched.
      await sync.flush();
      expect(api.renameClientCallCount, 1,
          reason: 'op re-attempted inside the 5s cooldown must be skipped');
      expect(await storage.countPendingOps(), 1);
    });
  });

  group('SyncService.flush — permanent failure / dead-letter', () {
    test('drops the op after the 30-attempt safety cap', () async {
      await seedClient(id: 'client-perm', practiceId: 'p1', name: 'Stuck');
      final op = PendingOp.renameClient(
        opId: 'op-permanent',
        clientId: 'client-perm',
        newName: 'Stuck Renamed',
        nowMs: DateTime.now().millisecondsSinceEpoch,
      );
      await storage.enqueuePendingOp(op);

      // A generic (non-stale) error — retried, never dropped early.
      api.renameFailTimes = 1000;
      api.renameError = Exception('opaque 500 from the edge');

      // Drive the drain until the 30-attempt cap drops the op. Each flush
      // attempts once; age the op between flushes to clear the cooldown.
      // The cap drops when op.attempts >= 30, i.e. after the 31st dispatch
      // observes attempts already at 30.
      var dropped = false;
      for (var i = 0; i < 40 && !dropped; i++) {
        await sync.flush();
        if (await storage.countPendingOps() == 0) {
          dropped = true;
          break;
        }
        await ageLastAttempt(op.id);
      }

      expect(dropped, isTrue,
          reason: 'op exceeding the 30-attempt cap must be dead-lettered');
      expect(await storage.countPendingOps(), 0);
      // Dispatched at least the cap-many times before being dropped.
      expect(api.renameClientCallCount, greaterThanOrEqualTo(30));
    });

    test('stale op against a missing client is dropped on the first attempt',
        () async {
      await seedClient(id: 'client-gone', practiceId: 'p1', name: 'Ghost');
      final op = PendingOp.renameClient(
        opId: 'op-stale',
        clientId: 'client-gone',
        newName: 'Ghost Renamed',
        nowMs: DateTime.now().millisecondsSinceEpoch,
      );
      await storage.enqueuePendingOp(op);

      // RenameClientError(notFound) is the "client missing on server" signal
      // the drain classifies as moot — dropped immediately, NOT retried.
      api.renameFailTimes = 1000;
      api.renameError = const RenameClientError(RenameClientErrorKind.notFound);

      final flushed = await sync.flush();
      expect(flushed, 1, reason: 'a dropped stale op counts as flushed');
      expect(api.renameClientCallCount, 1,
          reason: 'stale op is dropped on the first attempt, never retried');
      expect(await storage.countPendingOps(), 0);
    });

    test('PostgREST 22023 "not found" is treated as a stale drop', () async {
      await seedClient(id: 'client-22023', practiceId: 'p1', name: 'X');
      final op = PendingOp.renameClient(
        opId: 'op-22023',
        clientId: 'client-22023',
        newName: 'Y',
        nowMs: DateTime.now().millisecondsSinceEpoch,
      );
      await storage.enqueuePendingOp(op);

      api.renameFailTimes = 1000;
      api.renameError = const PostgrestException(
        message: 'client not found',
        code: '22023',
      );

      final flushed = await sync.flush();
      expect(flushed, 1);
      expect(api.renameClientCallCount, 1);
      expect(await storage.countPendingOps(), 0);
    });
  });

  group('SyncService.flush — server-side id rewire', () {
    test('upsertClient returning a different id rewires cached row + sessions',
        () async {
      const localId = 'local-uuid';
      const serverId = 'server-winning-uuid';
      const practiceId = 'p1';

      // Local-minted client row (offline create) + a session referencing it.
      await seedClient(id: localId, practiceId: practiceId, name: 'Dup Name');
      await storage.saveSession(
        model.Session(
          id: 'plan-1',
          clientName: 'Dup Name',
          clientId: localId,
          practiceId: practiceId,
          createdAt: DateTime.now(),
        ),
      );

      final op = PendingOp.upsertClient(
        opId: 'op-upsert',
        clientId: localId,
        practiceId: practiceId,
        name: 'Dup Name',
        nowMs: DateTime.now().millisecondsSinceEpoch,
      );
      await storage.enqueuePendingOp(op);

      // Server says: this name already belongs to serverId — rewire to it.
      api.upsertReturns = serverId;

      final flushed = await sync.flush();
      expect(flushed, 1);
      expect(api.upsertClientCallCount, 1);
      expect(await storage.countPendingOps(), 0);

      // The loser's local-id row is gone; the winning id now owns the row.
      expect(await storage.getCachedClientById(localId), isNull);
      final winner = await storage.getCachedClientById(serverId);
      expect(winner, isNotNull);
      expect(winner!.dirty, isFalse);

      // The session's client_id reference moved to the winning id.
      final planRows = await storage.db.query(
        'sessions',
        columns: ['client_id'],
        where: 'id = ?',
        whereArgs: ['plan-1'],
      );
      expect(planRows.single['client_id'], serverId);
    });

    test('upsertClient echoing the same id marks the row clean (no rewire)',
        () async {
      const clientId = 'same-id';
      await seedClient(id: clientId, practiceId: 'p1', name: 'Solo');
      final op = PendingOp.upsertClient(
        opId: 'op-upsert-same',
        clientId: clientId,
        practiceId: 'p1',
        name: 'Solo',
        nowMs: DateTime.now().millisecondsSinceEpoch,
      );
      await storage.enqueuePendingOp(op);

      api.upsertReturns = clientId; // server echoes our id back

      final flushed = await sync.flush();
      expect(flushed, 1);
      expect(await storage.countPendingOps(), 0);

      final cached = await storage.getCachedClientById(clientId);
      expect(cached, isNotNull);
      expect(cached!.dirty, isFalse);
    });
  });

  group('SyncService.flush — no double-dispatch while in flight', () {
    test('a re-entrant flush() during an in-flight op dispatches it once',
        () async {
      await seedClient(id: 'client-reentrant', practiceId: 'p1', name: 'One');
      final op = PendingOp.renameClient(
        opId: 'op-reentrant',
        clientId: 'client-reentrant',
        newName: 'Two',
        nowMs: DateTime.now().millisecondsSinceEpoch,
      );
      await storage.enqueuePendingOp(op);

      // Hold the RPC open so the first flush() is parked mid-await.
      final gate = Completer<void>();
      api.renameGate = gate;
      api.renameFailTimes = 0; // will succeed once released

      final firstFlush = sync.flush();
      // Let the event loop reach the awaited gate inside renameClient.
      await Future<void>.delayed(Duration.zero);
      expect(api.renameClientCallCount, 1,
          reason: 'first flush dispatched the op and is now parked');

      // Re-entrant flush while the first is still in flight. The _flushing
      // guard must make this an immediate no-op (returns 0, no 2nd dispatch).
      final secondFlushed = await sync.flush();
      expect(secondFlushed, 0,
          reason: 'flush() while one is in flight is a guarded no-op');
      expect(api.renameClientCallCount, 1,
          reason: 'the op must not be dispatched twice');

      // Release the in-flight RPC; the first flush completes cleanly.
      gate.complete();
      final firstFlushed = await firstFlush;
      expect(firstFlushed, 1);
      expect(api.renameClientCallCount, 1);
      expect(await storage.countPendingOps(), 0);
    });
  });
}
