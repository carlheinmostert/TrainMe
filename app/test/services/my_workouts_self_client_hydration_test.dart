import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:raidme/models/cached_client.dart';
import 'package:raidme/models/session.dart';
import 'package:raidme/services/local_storage_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Regression for the "My Workouts renders empty even though the user has
/// self-captured sessions" bug (supersedes the PR #614 reload-token theory).
///
/// Carl's iPhone is an UPDATE install that preserved its local SQLite DB
/// across many app versions. The self-client row (`clients.user_id =
/// auth.uid()`, name "Me") was first cached BEFORE the self-trainer wave
/// added `cached_clients.user_id` (SQLite v48). The v48 migration added
/// the column as NULL without a backfill, and the dirty-row skip in
/// `replaceCachedClientsForPractice` could strand that NULL (H1). A
/// delete→undelete cycle could likewise strand a stale local `deleted=1`
/// flag (H2). Either way `getCachedSelfClient` (filters
/// `user_id = ? AND deleted = 0`) returns null → the My Workouts filter
/// short-circuits to `const []`.
///
/// These tests drive the real `LocalStorageService` against a temp
/// `sqflite_common_ffi` DB. They reproduce the exact stale shapes, then
/// assert that after a normal cloud pull (modelled via
/// `replaceCachedClientsForPractice`, the writer `_pullClients` uses) the
/// self-client resolves and the My Workouts filter returns the 5 sessions.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  final factory = databaseFactoryFfi;

  late Directory tmpDir;
  late String dbPath;
  late LocalStorageService storage;

  const userId = 'afb692ab-557a-4527-b6af-83acccd853ab';
  const practiceId = '23d23dd6-41ee-40ec-b56f-ebdf35d9ddc9';
  const selfClientId = '0ef9b42e-ccc5-4ec1-8ece-fa2b8e64dce3';

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('my_workouts_test_');
    dbPath = p.join(tmpDir.path, 'hydration.db');
    storage = await LocalStorageService.openForTest(
      path: dbPath,
      factory: factory,
    );
  });

  tearDown(() async {
    await storage.close();
    await tmpDir.delete(recursive: true);
  });

  /// The cloud row as `_pullClients` would build it via
  /// `CachedClient.fromCloudJson` — non-NULL `user_id`, live (`deleted=0`),
  /// `dirty=0`.
  CachedClient cloudSelfClient() => CachedClient.fromCloudJson(
        <String, dynamic>{
          'id': selfClientId,
          'practice_id': practiceId,
          'name': 'Me',
          'user_id': userId,
          'video_consent': <String, dynamic>{'line_drawing': true},
        },
        nowMs: DateTime.now().millisecondsSinceEpoch,
      );

  Future<void> seedFiveSelfSessions() async {
    final base = DateTime.now().millisecondsSinceEpoch;
    for (var i = 0; i < 5; i++) {
      await storage.saveSession(
        Session(
          id: 'session-$i',
          clientName: 'Me',
          title: 'Workout $i',
          clientId: selfClientId,
          practiceId: practiceId,
          createdByUserId: userId,
          createdAt: DateTime.fromMillisecondsSinceEpoch(base + i),
        ),
      );
    }
  }

  /// The My Workouts filter, lifted verbatim from
  /// `my_workouts_screen.dart` `_load()`.
  Future<List<Session>> myWorkoutsList() async {
    final CachedClient? self = await storage.getCachedSelfClient(userId);
    await storage.claimOrphanSessions(userId);
    final List<Session> all = await storage.getSessionsForUser(userId);
    if (self == null) {
      return <Session>[];
    }
    final String selfId = self.id;
    return all
        .where((Session s) => s.clientId == selfId)
        .toList(growable: false);
  }

  test(
    'H1: self-client cached with NULL user_id + dirty=1 strands the row '
    '(reproduces empty My Workouts)',
    () async {
      // Pre-v48-shaped row: user_id never backfilled (NULL), and the row is
      // mid-sync (dirty=1) so a normal pull skips it.
      await storage.upsertCachedClient(
        CachedClient(
          id: selfClientId,
          practiceId: practiceId,
          name: 'Me',
          dirty: true,
        ),
      );
      await seedFiveSelfSessions();

      // Before the fix, getCachedSelfClient can't find the row (user_id NULL)
      // so the list is empty.
      final before = await myWorkoutsList();
      expect(before, isEmpty,
          reason: 'stale NULL user_id should hide the self-client');

      // A normal cloud pull lands the authoritative self-client.
      await storage.replaceCachedClientsForPractice(
        practiceId: practiceId,
        clients: [cloudSelfClient()],
      );

      // After the pull the self-client must resolve and the 5 sessions show.
      final self = await storage.getCachedSelfClient(userId);
      expect(self, isNotNull,
          reason: 'pull must repair the stranded self-client row');
      expect(self!.id, selfClientId);
      final after = await myWorkoutsList();
      expect(after.length, 5,
          reason: 'My Workouts must list all 5 self-captures after a pull');
    },
  );

  test(
    'H2: self-client cached with stale local deleted=1 strands the row '
    '(reproduces empty My Workouts)',
    () async {
      // The self-client went through a delete→undelete cycle: the cloud is
      // now live (deleted_at NULL) but the local `deleted` int flag is a
      // stale 1. dirty=1 makes a normal pull skip it.
      await storage.upsertCachedClient(
        CachedClient(
          id: selfClientId,
          practiceId: practiceId,
          name: 'Me',
          userId: userId,
          dirty: true,
          deleted: true,
        ),
      );
      await seedFiveSelfSessions();

      final before = await myWorkoutsList();
      expect(before, isEmpty,
          reason: 'stale deleted=1 should hide the self-client');

      await storage.replaceCachedClientsForPractice(
        practiceId: practiceId,
        clients: [cloudSelfClient()],
      );

      final self = await storage.getCachedSelfClient(userId);
      expect(self, isNotNull,
          reason: 'pull must clear the stale local deleted flag');
      final after = await myWorkoutsList();
      expect(after.length, 5);
    },
  );

  test(
    'healthy case: clean self-client row resolves and lists sessions',
    () async {
      await storage.replaceCachedClientsForPractice(
        practiceId: practiceId,
        clients: [cloudSelfClient()],
      );
      await seedFiveSelfSessions();

      final self = await storage.getCachedSelfClient(userId);
      expect(self, isNotNull);
      final after = await myWorkoutsList();
      expect(after.length, 5);
    },
  );

  test(
    'a genuinely-deleted self-client cloud-side stays hidden (no false heal)',
    () async {
      // Stale healthy local row first.
      await storage.replaceCachedClientsForPractice(
        practiceId: practiceId,
        clients: [cloudSelfClient()],
      );
      await seedFiveSelfSessions();
      expect(await storage.getCachedSelfClient(userId), isNotNull);

      // Cloud now reports the self-client tombstoned (it drops out of
      // list_practice_clients entirely). The pull must remove it locally.
      await storage.replaceCachedClientsForPractice(
        practiceId: practiceId,
        clients: const <CachedClient>[],
      );
      expect(await storage.getCachedSelfClient(userId), isNull,
          reason: 'a self-client removed cloud-side must not linger locally');
    },
  );
}
