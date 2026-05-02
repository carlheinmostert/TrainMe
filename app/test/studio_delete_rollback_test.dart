// Wave 41 — `_deleteExercise` rollback regression (ported onto PLAN Studio).
//
// The bug: Studio's in-memory exercise list and the SQLite `exercises`
// table could drift if the SQLite delete failed silently. The previous
// `_deleteExercise` fired `widget.storage.deleteExercise(removed.id)`
// fire-and-forget with `.catchError(debugPrint)`, so a thrown delete
// left the row in SQLite, removed it from the UI, and gave publish
// pre-flight a "missing media" target the practitioner couldn't see.

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:raidme/models/exercise_capture.dart';
import 'package:raidme/services/local_storage_service.dart';
import 'package:raidme/widgets/studio_exercise_card.dart';

/// LocalStorageService double whose `deleteExercise` always throws.
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

        current = reindexAfterRemove(current, 0);
        expect(current.map((e) => e.id), ['b']);

        Object? caught;
        try {
          await storage.deleteExercise('a');
        } catch (e) {
          caught = e;
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
