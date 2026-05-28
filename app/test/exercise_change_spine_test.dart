// Unpublished-changes coral spine (2026-05-28).
//
// Pins the per-exercise dirty-detection rule + the local persistence of
// the `last_edited_at` column. The spine is a LOCAL-ONLY authoring aid:
//   * Per-card spine via [Session.exerciseHasUnpublishedChanges] — lit when
//     the exercise's own `lastEditedAt` is newer than the session's publish
//     stamp (`sentAt`).
//   * Never-published sessions show no per-card markers.
//   * Legacy / freshly-pulled rows with a null `lastEditedAt` show no
//     marker (we have no record of pre-feature edits).
//   * `markContentEdited()` stamps the edit time so a card lights against
//     the in-memory model the instant an edit lands.
//   * `last_edited_at` round-trips through SQLite save / load.

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:raidme/models/exercise_capture.dart';
import 'package:raidme/models/session.dart';
import 'package:raidme/services/local_storage_service.dart';

ExerciseCapture _ex({
  required String id,
  required String sessionId,
  DateTime? lastEditedAt,
}) {
  return ExerciseCapture(
    id: id,
    position: 0,
    rawFilePath: 'raw/$id.mp4',
    mediaType: MediaType.video,
    createdAt: DateTime.now(),
    sessionId: sessionId,
    lastEditedAt: lastEditedAt,
  );
}

Session _publishedSession({
  required String id,
  required DateTime sentAt,
  List<ExerciseCapture> exercises = const <ExerciseCapture>[],
}) {
  return Session(
    id: id,
    clientName: 'Test Client',
    createdAt: sentAt.subtract(const Duration(hours: 1)),
    sentAt: sentAt,
    planUrl: 'https://session.homefit.studio/p/fake-uuid',
    version: 1,
    exercises: exercises,
  );
}

void main() {
  group('Session.exerciseHasUnpublishedChanges', () {
    final sentAt = DateTime(2026, 5, 28, 10, 0, 0);

    test('edit newer than the publish stamp lights the exercise', () {
      final edited = _ex(
        id: 'ex-1',
        sessionId: 's-1',
        lastEditedAt: sentAt.add(const Duration(minutes: 5)),
      );
      final session = _publishedSession(id: 's-1', sentAt: sentAt);
      expect(session.exerciseHasUnpublishedChanges(edited), isTrue);
    });

    test('edit older than the publish stamp does NOT light', () {
      final stale = _ex(
        id: 'ex-1',
        sessionId: 's-1',
        lastEditedAt: sentAt.subtract(const Duration(minutes: 5)),
      );
      final session = _publishedSession(id: 's-1', sentAt: sentAt);
      expect(session.exerciseHasUnpublishedChanges(stale), isFalse);
    });

    test('null lastEditedAt (legacy / fresh-pull) does NOT light', () {
      final legacy = _ex(id: 'ex-1', sessionId: 's-1', lastEditedAt: null);
      final session = _publishedSession(id: 's-1', sentAt: sentAt);
      expect(session.exerciseHasUnpublishedChanges(legacy), isFalse);
    });

    test('never-published session shows no per-card marker even if edited',
        () {
      final edited = _ex(
        id: 'ex-1',
        sessionId: 's-draft',
        lastEditedAt: DateTime.now(),
      );
      final draft = Session(
        id: 's-draft',
        clientName: 'Test Client',
        createdAt: DateTime.now().subtract(const Duration(hours: 1)),
        // No sentAt, version 0, no planUrl → not published.
      );
      expect(draft.isPublished, isFalse);
      expect(draft.exerciseHasUnpublishedChanges(edited), isFalse);
    });

    test('published-but-never-sent session lights any edited exercise', () {
      // Defensive branch: isPublished true (version>0 + planUrl) but
      // sentAt null. Any edit stamp counts as unpublished.
      final edited = _ex(
        id: 'ex-1',
        sessionId: 's-2',
        lastEditedAt: DateTime.now(),
      );
      final session = Session(
        id: 's-2',
        clientName: 'Test Client',
        createdAt: DateTime.now().subtract(const Duration(hours: 1)),
        planUrl: 'https://session.homefit.studio/p/fake-uuid',
        version: 1,
        // sentAt deliberately null.
      );
      expect(session.isPublished, isTrue);
      expect(session.exerciseHasUnpublishedChanges(edited), isTrue);
    });
  });

  group('ExerciseCapture.markContentEdited', () {
    test('stamps lastEditedAt to now and leaves other fields untouched', () {
      final before = _ex(id: 'ex-1', sessionId: 's-1', lastEditedAt: null);
      final after = before.markContentEdited();
      expect(after.lastEditedAt, isNotNull);
      // Identity-preserving except the stamp.
      expect(after.id, before.id);
      expect(after.position, before.position);
      expect(after.rawFilePath, before.rawFilePath);
      expect(after.mediaType, before.mediaType);
    });

    test('copyWith(clearLastEditedAt: true) nulls the stamp', () {
      final stamped = _ex(
        id: 'ex-1',
        sessionId: 's-1',
        lastEditedAt: DateTime.now(),
      );
      expect(stamped.lastEditedAt, isNotNull);
      final cleared = stamped.copyWith(clearLastEditedAt: true);
      expect(cleared.lastEditedAt, isNull);
    });
  });

  group('last_edited_at persistence (SQLite round-trip)', () {
    setUpAll(() {
      sqfliteFfiInit();
    });

    late LocalStorageService storage;

    setUp(() async {
      storage = await LocalStorageService.openForTest(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
    });

    tearDown(() async {
      await storage.close();
    });

    test('lastEditedAt round-trips through save / load', () async {
      final stamp = DateTime(2026, 5, 28, 12, 34, 56);
      final session = _publishedSession(
        id: 's-rt',
        sentAt: DateTime(2026, 5, 28, 9, 0, 0),
      );
      await storage.saveSession(session);

      final ex = _ex(id: 'ex-rt', sessionId: 's-rt', lastEditedAt: stamp);
      await storage.saveExercise(ex);

      final loaded = await storage.getSession('s-rt');
      expect(loaded, isNotNull);
      final reloaded =
          loaded!.exercises.firstWhere((e) => e.id == 'ex-rt');
      expect(
        reloaded.lastEditedAt,
        equals(stamp),
        reason: 'last_edited_at must survive the SQLite round-trip',
      );
      // And the per-exercise spine lights against the loaded model
      // (stamp is after the publish stamp).
      expect(loaded.exerciseHasUnpublishedChanges(reloaded), isTrue);
    });

    test('null lastEditedAt round-trips as null', () async {
      final session = _publishedSession(
        id: 's-null',
        sentAt: DateTime(2026, 5, 28, 9, 0, 0),
      );
      await storage.saveSession(session);

      final ex = _ex(id: 'ex-null', sessionId: 's-null', lastEditedAt: null);
      await storage.saveExercise(ex);

      final loaded = await storage.getSession('s-null');
      final reloaded =
          loaded!.exercises.firstWhere((e) => e.id == 'ex-null');
      expect(reloaded.lastEditedAt, isNull);
      expect(loaded.exerciseHasUnpublishedChanges(reloaded), isFalse);
    });
  });
}
