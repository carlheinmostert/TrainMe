// Per-set PLAN wave — capture-save defaults rewritten for the per-set
// relational model. Legacy uniform `(reps, sets, holdSeconds,
// interSetRestSeconds)` columns were dropped server-side; the model now
// carries `sets: List<ExerciseSet>` + `restHoldSeconds` (rest-only).
//
// At the save boundary, [withPersistenceDefaults] seeds a single canonical
// `ExerciseSet(reps: 10, holdSeconds: 0, weightKg: null,
// breatherSecondsAfter: 30)` for video / photo captures with an empty
// sets list, so downstream consumers always have at least one playable
// row. Rest periods are returned unchanged (their duration lives on
// `restHoldSeconds`). Video captures additionally get
// `videoRepsPerLoop: 3`; photos do not.
//
// These tests pin the behaviour at two levels:
//   1. [ExerciseCapture.withPersistenceDefaults] — the pure helper.
//   2. [LocalStorageService.saveExercise] — brand-new inserts get the
//      defaults via the helper, pre-existing rows are not retroactively
//      backfilled.

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:raidme/models/exercise_capture.dart';
import 'package:raidme/models/exercise_set.dart';
import 'package:raidme/models/session.dart';
import 'package:raidme/services/local_storage_service.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  group('ExerciseCapture.withPersistenceDefaults', () {
    ExerciseCapture seed({
      List<ExerciseSet> sets = const <ExerciseSet>[],
      int? restHoldSeconds,
      MediaType mediaType = MediaType.video,
    }) {
      return ExerciseCapture(
        id: 'ex-seed',
        position: 0,
        rawFilePath: 'raw/dummy.mp4',
        mediaType: mediaType,
        createdAt: DateTime.now(),
        sets: sets,
        restHoldSeconds: restHoldSeconds,
      );
    }

    test('fresh video capture seeds a single default set', () {
      final out = seed().withPersistenceDefaults();
      expect(out.sets, hasLength(1));
      final s = out.sets.single;
      expect(s.position, 1);
      expect(s.reps, 10);
      expect(s.holdSeconds, 0);
      expect(s.weightKg, isNull);
      expect(s.breatherSecondsAfter, 30);
    });

    test('photo capture gets the same seeded set as video', () {
      final out = seed(mediaType: MediaType.photo).withPersistenceDefaults();
      expect(out.sets, hasLength(1));
      expect(out.sets.single.reps, 10);
      expect(out.sets.single.holdSeconds, 0);
    });

    test('explicit sets list survives backfill', () {
      final preset = <ExerciseSet>[
        ExerciseSet.create(position: 1, reps: 12),
        ExerciseSet.create(position: 2, reps: 10),
      ];
      final out = seed(sets: preset).withPersistenceDefaults();
      expect(out.sets, hasLength(2));
      expect(out.sets[0].reps, 12);
      expect(out.sets[1].reps, 10);
    });

    test('rest period is returned unchanged', () {
      final rest = ExerciseCapture(
        id: 'ex-rest',
        position: 1,
        rawFilePath: '',
        mediaType: MediaType.rest,
        restHoldSeconds: 60,
        createdAt: DateTime.now(),
      );
      final out = rest.withPersistenceDefaults();
      expect(out.sets, isEmpty);
      expect(out.restHoldSeconds, 60);
    });

    test('returns the same instance when no changes are needed', () {
      // Already-seeded video capture with videoRepsPerLoop=3 — helper
      // should return the exact same instance.
      final ex = seed(sets: <ExerciseSet>[
        ExerciseSet.create(
          position: 1,
          reps: 10,
          holdSeconds: 0,
          weightKg: null,
          breatherSecondsAfter: 30,
        ),
      ]).copyWith(videoRepsPerLoop: 3);
      final out = ex.withPersistenceDefaults();
      expect(identical(ex, out), isTrue);
    });

    test('fresh video capture seeds videoRepsPerLoop=3', () {
      final out = seed().withPersistenceDefaults();
      expect(out.videoRepsPerLoop, 3);
    });

    test('photo capture does NOT seed videoRepsPerLoop', () {
      final out = seed(mediaType: MediaType.photo).withPersistenceDefaults();
      expect(out.videoRepsPerLoop, isNull);
    });

    test('explicit videoRepsPerLoop survives backfill', () {
      final ex = seed().copyWith(videoRepsPerLoop: 5);
      final out = ex.withPersistenceDefaults();
      expect(out.videoRepsPerLoop, 5);
    });
  });

  group('LocalStorageService.saveExercise — per-set defaults', () {
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

    Future<ExerciseCapture> reloadExercise(String id) async {
      final rows = await storage.db.query(
        'exercises',
        where: 'id = ?',
        whereArgs: [id],
      );
      final setRows = await storage.db.query(
        'exercise_sets',
        where: 'exercise_id = ?',
        whereArgs: [id],
        orderBy: 'position ASC',
      );
      final sets =
          setRows.map((r) => ExerciseSet.fromMap(r)).toList(growable: false);
      return ExerciseCapture.fromMap(rows.single, sets: sets);
    }

    test('fresh video capture saves with one default set', () async {
      final capture = ExerciseCapture(
        id: 'ex-fresh',
        position: 0,
        rawFilePath: 'raw/x.mp4',
        mediaType: MediaType.video,
        createdAt: DateTime.now(),
        sessionId: 'session-opt1',
      );
      await storage.saveExercise(capture);

      final persisted = await reloadExercise('ex-fresh');
      expect(persisted.sets, hasLength(1));
      expect(persisted.sets.single.reps, 10);
      expect(persisted.sets.single.breatherSecondsAfter, 30);
      expect(persisted.videoRepsPerLoop, 3);
    });

    test('rest row persists with no seeded set and restHoldSeconds preserved',
        () async {
      final rest = ExerciseCapture(
        id: 'ex-rest',
        position: 0,
        rawFilePath: '',
        mediaType: MediaType.rest,
        restHoldSeconds: 30,
        createdAt: DateTime.now(),
        sessionId: 'session-opt1',
      );
      await storage.saveExercise(rest);

      final persisted = await reloadExercise('ex-rest');
      expect(persisted.sets, isEmpty);
      expect(persisted.restHoldSeconds, 30);
    });

    test('explicit sets list is never overwritten', () async {
      final curated = ExerciseCapture(
        id: 'ex-curated',
        position: 0,
        rawFilePath: 'raw/x.mp4',
        mediaType: MediaType.video,
        createdAt: DateTime.now(),
        sessionId: 'session-opt1',
        sets: <ExerciseSet>[
          ExerciseSet.create(position: 1, reps: 6),
          ExerciseSet.create(position: 2, reps: 6),
          ExerciseSet.create(position: 3, reps: 6),
          ExerciseSet.create(position: 4, reps: 6),
          ExerciseSet.create(position: 5, reps: 6),
        ],
      );
      await storage.saveExercise(curated);

      final persisted = await reloadExercise('ex-curated');
      expect(persisted.sets, hasLength(5));
      expect(persisted.sets.every((s) => s.reps == 6), isTrue);
    });

    test('no retroactive backfill — existing row with empty sets stays empty',
        () async {
      // Simulate a pre-per-set row already in the DB by inserting with
      // an explicitly empty sets list and then bypassing saveExercise's
      // first-write defaulting on subsequent saves.
      final legacyRow = ExerciseCapture(
        id: 'ex-legacy',
        position: 0,
        rawFilePath: 'raw/x.mp4',
        mediaType: MediaType.video,
        createdAt: DateTime.now(),
        sessionId: 'session-opt1',
      );
      await storage.db.insert('exercises', legacyRow.toMap());
      // Note: deliberately did NOT insert any rows into exercise_sets, so
      // the existing row's sets list is empty. saveExercise should not
      // re-run withPersistenceDefaults on an existing row.

      // Now a conversion-status update comes through — this is a
      // re-save of an existing row. Defaults must NOT be backfilled.
      final churn = legacyRow.copyWith(
        conversionStatus: ConversionStatus.done,
        convertedFilePath: 'converted/x.mp4',
      );
      await storage.saveExercise(churn);

      final persisted = await reloadExercise('ex-legacy');
      expect(
        persisted.sets,
        isEmpty,
        reason: 'Existing empty sets list must stay empty across re-saves',
      );
      expect(persisted.conversionStatus, ConversionStatus.done);
    });
  });
}
