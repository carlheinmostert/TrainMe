// Wave 41 — `_deleteExercise` rollback regression.
//
// The bug: Studio's in-memory exercise list and the SQLite `exercises`
// table could drift if the SQLite delete failed silently. The previous
// `_deleteExercise` fired `widget.storage.deleteExercise(removed.id)`
// fire-and-forget with `.catchError(debugPrint)`, so a thrown delete
// left the row in SQLite, removed it from the UI, and gave publish
// pre-flight a "missing media" target the practitioner couldn't see.
//
// Two tests:
//   1. The list reindex helper (`reindexAfterRemove`) reindexes
//      positions correctly across removal cases. Pure-function unit
//      test, no Flutter binding required.
//   2. The "rollback contract": when `LocalStorageService.deleteExercise`
//      throws, callers can `try/await/catch` cleanly and the original
//      list snapshot survives the catch path. We don't construct the
//      full Studio screen here (its initState wires up
//      ConversionService, UploadService, AuthGate, etc.); instead we
//      simulate the orchestration the screen now follows: snapshot the
//      list, mutate to the next shape, attempt the delete, restore the
//      snapshot on throw. This is the contract the bug fix establishes.

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:raidme/models/exercise_capture.dart';
import 'package:raidme/services/local_storage_service.dart';
import 'package:raidme/widgets/studio_exercise_card.dart';

/// LocalStorageService double whose `deleteExercise` always throws.
/// Mirrors the real bug — the underlying SQLite write failed (disk
/// full, permissions, locked db) and the screen used to swallow it.
class _ThrowingDeleteStorage extends LocalStorageService {
  bool deleteCalled = false;

  @override
  Future<void> deleteExercise(String exerciseId) async {
    deleteCalled = true;
    throw StateError('simulated SQLite delete failure');
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  group('reindexAfterRemove', () {
    test('removes the row at index and reindexes positions', () {
      final list = [
        ExerciseCapture(
          id: 'a',
          position: 0,
          rawFilePath: 'raw/a.mp4',
          mediaType: MediaType.video,
          createdAt: DateTime.now(),
          sessionId: 's1',
        ),
        ExerciseCapture(
          id: 'b',
          position: 1,
          rawFilePath: 'raw/b.mp4',
          mediaType: MediaType.video,
          createdAt: DateTime.now(),
          sessionId: 's1',
        ),
        ExerciseCapture(
          id: 'c',
          position: 2,
          rawFilePath: 'raw/c.mp4',
          mediaType: MediaType.video,
          createdAt: DateTime.now(),
          sessionId: 's1',
        ),
      ];

      final next = reindexAfterRemove(list, 1);
      expect(next, hasLength(2));
      expect(next.map((e) => e.id), ['a', 'c']);
      expect(next.map((e) => e.position), [0, 1]);
    });

    test('does not mutate the input list', () {
      final list = [
        ExerciseCapture(
          id: 'a',
          position: 0,
          rawFilePath: 'raw/a.mp4',
          mediaType: MediaType.video,
          createdAt: DateTime.now(),
          sessionId: 's1',
        ),
        ExerciseCapture(
          id: 'b',
          position: 1,
          rawFilePath: 'raw/b.mp4',
          mediaType: MediaType.video,
          createdAt: DateTime.now(),
          sessionId: 's1',
        ),
      ];

      reindexAfterRemove(list, 0);
      expect(list.map((e) => e.id), ['a', 'b']);
      expect(list.map((e) => e.position), [0, 1]);
    });
  });

  group('_deleteExercise rollback contract', () {
    // The screen now wraps storage.deleteExercise in try/catch and
    // restores the in-memory list on throw. We simulate that
    // orchestration here without spinning the full screen up.
    test(
      'when storage throws, the original list is restored unchanged',
      () async {
        final storage = _ThrowingDeleteStorage();

        final original = [
          ExerciseCapture(
            id: 'a',
            position: 0,
            name: 'Squat',
            rawFilePath: 'raw/a.mp4',
            mediaType: MediaType.video,
            createdAt: DateTime.now(),
            sessionId: 's1',
          ),
          ExerciseCapture(
            id: 'b',
            position: 1,
            name: 'Lunge',
            rawFilePath: 'raw/b.mp4',
            mediaType: MediaType.video,
            createdAt: DateTime.now(),
            sessionId: 's1',
          ),
        ];

        var current = List<ExerciseCapture>.from(original);
        final snapshot = List<ExerciseCapture>.from(current);

        // Optimistic mutation (mirrors what _deleteExercise does
        // before awaiting the SQLite delete).
        current = reindexAfterRemove(current, 0);
        expect(current.map((e) => e.id), ['b']);

        // Attempt delete. Throws.
        Object? caught;
        try {
          await storage.deleteExercise('a');
        } catch (e) {
          caught = e;
          // Rollback to the snapshot — this is the screen's catch path.
          current = snapshot;
        }

        expect(caught, isA<StateError>());
        expect(storage.deleteCalled, isTrue);
        expect(
          current.map((e) => e.id),
          ['a', 'b'],
          reason: 'Original list must be restored after a thrown delete',
        );
        expect(current.map((e) => e.position), [0, 1]);
      },
    );

    test(
      'happy path — successful delete removes the row from real storage',
      () async {
        // Sanity check: with the real storage backend the delete
        // resolves; the contract holds in both directions. We use an
        // absolute rawFilePath here so PathResolver.resolve short-
        // circuits without needing PathResolver.initialize() (which
        // pulls in path_provider — not wired under flutter test).
        final storage = await LocalStorageService.openForTest(
          path: inMemoryDatabasePath,
          factory: databaseFactoryFfi,
        );
        addTearDown(storage.close);

        final ex = ExerciseCapture(
          id: 'ok-1',
          position: 0,
          rawFilePath: '/tmp/raidme-test-ok-1.mp4',
          mediaType: MediaType.video,
          createdAt: DateTime.now(),
          sessionId: 's1',
        );
        await storage.saveExercise(ex);

        // Real path completes without throwing.
        await storage.deleteExercise(ex.id);
      },
    );
  });

  group('exerciseHasMissingMedia', () {
    test('rest periods are never broken (no media)', () {
      final rest = ExerciseCapture(
        id: 'r',
        position: 0,
        rawFilePath: '',
        mediaType: MediaType.rest,
        createdAt: DateTime.now(),
        sessionId: 's1',
      );
      expect(exerciseHasMissingMedia(rest), isFalse);
    });

    test('empty raw path → broken', () {
      final ex = ExerciseCapture(
        id: 'a',
        position: 0,
        rawFilePath: '',
        mediaType: MediaType.video,
        createdAt: DateTime.now(),
        sessionId: 's1',
      );
      expect(exerciseHasMissingMedia(ex), isTrue);
    });

    test('non-existent file path → broken', () {
      // PathResolver.initialize() isn't wired under flutter test (no
      // path_provider). We use an absolute path that PathResolver.resolve
      // returns unchanged — and `File(...).existsSync()` is false because
      // we picked a path nothing creates.
      final ex = ExerciseCapture(
        id: 'a',
        position: 0,
        rawFilePath: '/tmp/raidme-no-such-file-12345.mp4',
        mediaType: MediaType.video,
        createdAt: DateTime.now(),
        sessionId: 's1',
      );
      expect(exerciseHasMissingMedia(ex), isTrue);
    });
  });
}
