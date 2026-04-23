// 2026-04-23 — Option 1 capture-save defaults (reps=10 / sets=3).
//
// When a practitioner captures an exercise and never explicitly touches
// reps / sets, those columns used to persist as NULL. Downstream
// consumers (web player, plan preview) then had to guess at defaults
// which produced inconsistent grammar — one card showed "5 reps", the
// next showed nothing. The fix: at the save boundary, backfill sets=3
// and reps=10 so the persisted row is always truthful.
//
// Exceptions:
//   * Rest periods (`mediaType == rest`) skip both defaults.
//   * Isometric exercises (`holdSeconds` set AND `reps` null) skip only
//     the reps default — hold is the primary duration.
//
// These tests pin the behaviour at two levels:
//   1. [ExerciseCapture.withPersistenceDefaults] — the pure helper.
//   2. [LocalStorageService.saveExercise] — brand-new inserts get the
//      defaults, pre-existing nulls stay null.

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:raidme/models/exercise_capture.dart';
import 'package:raidme/models/session.dart';
import 'package:raidme/services/local_storage_service.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  group('ExerciseCapture.withPersistenceDefaults', () {
    ExerciseCapture seed({
      int? reps,
      int? sets,
      int? holdSeconds,
      MediaType mediaType = MediaType.video,
    }) {
      return ExerciseCapture(
        id: 'ex-seed',
        position: 0,
        rawFilePath: 'raw/dummy.mp4',
        mediaType: mediaType,
        createdAt: DateTime.now(),
        reps: reps,
        sets: sets,
        holdSeconds: holdSeconds,
      );
    }

    test('fresh capture with all nulls gets reps=10 and sets=3', () {
      final out = seed().withPersistenceDefaults();
      expect(out.reps, 10);
      expect(out.sets, 3);
      expect(out.holdSeconds, isNull);
    });

    test('photo capture gets the same defaults as video', () {
      final out = seed(mediaType: MediaType.photo).withPersistenceDefaults();
      expect(out.reps, 10);
      expect(out.sets, 3);
    });

    test('explicit reps survives backfill', () {
      final out = seed(reps: 12).withPersistenceDefaults();
      expect(out.reps, 12);
      expect(out.sets, 3);
    });

    test('explicit sets survives backfill', () {
      final out = seed(sets: 4).withPersistenceDefaults();
      expect(out.reps, 10);
      expect(out.sets, 4);
    });

    test('isometric (hold set, reps null) keeps reps null but sets=3', () {
      final out = seed(holdSeconds: 30).withPersistenceDefaults();
      expect(
        out.reps,
        isNull,
        reason: 'Isometric exercises must not get a reps default',
      );
      expect(out.sets, 3);
      expect(out.holdSeconds, 30);
    });

    test('isometric (hold set, reps explicit) keeps both', () {
      final out = seed(holdSeconds: 30, reps: 5).withPersistenceDefaults();
      expect(out.reps, 5);
      expect(out.sets, 3);
      expect(out.holdSeconds, 30);
    });

    test('rest period is returned unchanged', () {
      final rest = ExerciseCapture(
        id: 'ex-rest',
        position: 1,
        rawFilePath: '',
        mediaType: MediaType.rest,
        holdSeconds: 60,
        createdAt: DateTime.now(),
      );
      final out = rest.withPersistenceDefaults();
      expect(out.reps, isNull);
      expect(out.sets, isNull);
      expect(out.holdSeconds, 60);
    });

    test('returns the same instance when no changes are needed', () {
      final ex = seed(reps: 10, sets: 3);
      final out = ex.withPersistenceDefaults();
      expect(identical(ex, out), isTrue);
    });
  });

  group('LocalStorageService.saveExercise — Option 1 defaults', () {
    late LocalStorageService storage;

    setUp(() async {
      storage = await LocalStorageService.openForTest(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      await storage.saveSession(
        Session(
          id: 'session-opt1',
          clientName: 'Test Client',
          createdAt: DateTime.now(),
        ),
      );
    });

    tearDown(() async {
      await storage.close();
    });

    test('fresh capture saves with reps=10 / sets=3', () async {
      final capture = ExerciseCapture(
        id: 'ex-fresh',
        position: 0,
        rawFilePath: 'raw/x.mp4',
        mediaType: MediaType.video,
        createdAt: DateTime.now(),
        sessionId: 'session-opt1',
      );
      await storage.saveExercise(capture);

      final rows = await storage.db.query(
        'exercises',
        where: 'id = ?',
        whereArgs: ['ex-fresh'],
      );
      final persisted = ExerciseCapture.fromMap(rows.single);
      expect(persisted.reps, 10);
      expect(persisted.sets, 3);
    });

    test('isometric capture keeps reps null but sets=3', () async {
      final iso = ExerciseCapture(
        id: 'ex-iso',
        position: 0,
        rawFilePath: 'raw/x.mp4',
        mediaType: MediaType.video,
        createdAt: DateTime.now(),
        sessionId: 'session-opt1',
        holdSeconds: 45,
      );
      await storage.saveExercise(iso);

      final rows = await storage.db.query(
        'exercises',
        where: 'id = ?',
        whereArgs: ['ex-iso'],
      );
      final persisted = ExerciseCapture.fromMap(rows.single);
      expect(persisted.reps, isNull);
      expect(persisted.sets, 3);
      expect(persisted.holdSeconds, 45);
    });

    test('rest row persists with no reps / sets backfill', () async {
      final rest = ExerciseCapture(
        id: 'ex-rest',
        position: 0,
        rawFilePath: '',
        mediaType: MediaType.rest,
        holdSeconds: 30,
        createdAt: DateTime.now(),
        sessionId: 'session-opt1',
      );
      await storage.saveExercise(rest);

      final rows = await storage.db.query(
        'exercises',
        where: 'id = ?',
        whereArgs: ['ex-rest'],
      );
      final persisted = ExerciseCapture.fromMap(rows.single);
      expect(persisted.reps, isNull);
      expect(persisted.sets, isNull);
      expect(persisted.holdSeconds, 30);
    });

    test('explicit values are never overwritten', () async {
      final curated = ExerciseCapture(
        id: 'ex-curated',
        position: 0,
        rawFilePath: 'raw/x.mp4',
        mediaType: MediaType.video,
        createdAt: DateTime.now(),
        sessionId: 'session-opt1',
        reps: 6,
        sets: 5,
      );
      await storage.saveExercise(curated);

      final rows = await storage.db.query(
        'exercises',
        where: 'id = ?',
        whereArgs: ['ex-curated'],
      );
      final persisted = ExerciseCapture.fromMap(rows.single);
      expect(persisted.reps, 6);
      expect(persisted.sets, 5);
    });

    test('no retroactive backfill — later save with null reps stays null',
        () async {
      // Simulate a pre-Option-1 row already in the DB: bypass the
      // saveExercise default by poking the row in directly.
      final legacyRow = ExerciseCapture(
        id: 'ex-legacy',
        position: 0,
        rawFilePath: 'raw/x.mp4',
        mediaType: MediaType.video,
        createdAt: DateTime.now(),
        sessionId: 'session-opt1',
      );
      await storage.db.insert('exercises', legacyRow.toMap());

      // Now a conversion-status update comes through — this is a
      // re-save of an existing row. Option 1 must NOT backfill.
      final churn = legacyRow.copyWith(
        conversionStatus: ConversionStatus.done,
        convertedFilePath: 'converted/x.mp4',
      );
      await storage.saveExercise(churn);

      final rows = await storage.db.query(
        'exercises',
        where: 'id = ?',
        whereArgs: ['ex-legacy'],
      );
      final persisted = ExerciseCapture.fromMap(rows.single);
      expect(
        persisted.reps,
        isNull,
        reason: 'Existing null reps must stay null across re-saves',
      );
      expect(persisted.sets, isNull);
      expect(persisted.conversionStatus, ConversionStatus.done);
    });
  });
}
