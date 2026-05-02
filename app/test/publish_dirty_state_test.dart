// Wave 18 — publish dirty-state regression (per-set PLAN rewrite).
//
// The bug: any write path that called `LocalStorageService.saveExercise`
// WITHOUT going through `StudioModeScreen._touchAndPush` left the parent
// session's `last_content_edit_at` column unstamped. Capturing an
// exercise from Camera mode, persisting a muted/treatment change from
// the MediaViewer, or any other "exercise-only" write would then NOT
// flip `Session.hasUnpublishedContentChanges` to true, so the SessionCard
// / Studio toolbar publish indicator stayed sage "Published" even though
// the plan on-device had drifted from the published copy.
//
// Option C fix (see CLAUDE.md Wave 18): stamp the session timestamp
// inside `saveExercise` itself, gated on a delta check across the
// persisted user-content fields so conversion-pipeline churn
// (status / path updates) stays a silent operation.
//
// Per-set PLAN wave: legacy `reps`/`sets`/`holdSeconds` fields are gone.
// User-edit signal now travels through the [ExerciseCapture.sets] list
// (per-set reps / hold / weight / breather). The `_isUserContentDelta`
// check inside saveExercise compares sets element-wise.
//
// These tests pin the behaviour:
//   1. Capturing a new exercise on a published session → dirty.
//   2. Conversion-status-only updates → NOT dirty; a per-set reps bump → dirty.

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:raidme/models/exercise_capture.dart';
import 'package:raidme/models/exercise_set.dart';
import 'package:raidme/models/session.dart';
import 'package:raidme/services/local_storage_service.dart';

void main() {
  // Spin up the ffi variant once for the whole group. This lets us
  // `openDatabase(':memory:')` without touching `path_provider`, which
  // isn't wired up under `flutter test`.
  setUpAll(() {
    sqfliteFfiInit();
  });

  group('saveExercise dirty-state stamp', () {
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

    test('new exercise on a published session → dirty', () async {
      // Seed a published session — version>0, planUrl set, sentAt five
      // minutes ago, last_content_edit_at left null (legacy-clean).
      final sentAt =
          DateTime.now().subtract(const Duration(minutes: 5));
      final session = Session(
        id: 'session-published-1',
        clientName: 'Test Client',
        createdAt: sentAt.subtract(const Duration(hours: 1)),
        sentAt: sentAt,
        planUrl: 'https://session.homefit.studio/p/fake-uuid',
        version: 1,
      );
      await storage.saveSession(session);

      // Sanity: no exercises yet, timestamp still null → clean.
      final before = await storage.getSession(session.id);
      expect(before, isNotNull);
      expect(before!.lastContentEditAt, isNull);
      expect(before.hasUnpublishedContentChanges, isFalse);

      // Simulate Camera-mode capture: saveExercise without stamping
      // the session via _touchAndPush. Before Wave 18 this left the
      // session-card indicator stuck on sage.
      final exercise = ExerciseCapture(
        id: 'ex-new-1',
        position: 0,
        rawFilePath: 'raw/dummy.mp4',
        mediaType: MediaType.video,
        createdAt: DateTime.now(),
        sessionId: session.id,
      );
      await storage.saveExercise(exercise);

      final after = await storage.getSession(session.id);
      expect(after, isNotNull);
      expect(
        after!.lastContentEditAt,
        isNotNull,
        reason:
            'saveExercise must stamp the parent session on NEW exercises',
      );
      expect(
        after.hasUnpublishedContentChanges,
        isTrue,
        reason:
            'A fresh Camera capture on a published session must dirty it',
      );
    });

    test(
      'conversion-status-only update → NOT dirty; per-set reps bump → dirty',
      () async {
        final sentAt =
            DateTime.now().subtract(const Duration(minutes: 5));
        final session = Session(
          id: 'session-published-2',
          clientName: 'Test Client',
          createdAt: sentAt.subtract(const Duration(hours: 1)),
          sentAt: sentAt,
          planUrl: 'https://session.homefit.studio/p/fake-uuid',
          version: 1,
        );
        await storage.saveSession(session);

        // Save an exercise first — this is the initial insert, which
        // DOES flip the stamp. Clear the stamp back to null so the
        // second-stage test mirrors a post-publish stable state.
        final firstSet = ExerciseSet.create(
          position: 1,
          reps: 10,
          holdSeconds: 0,
          weightKg: null,
          breatherSecondsAfter: 30,
        );
        final ex = ExerciseCapture(
          id: 'ex-pub-1',
          position: 0,
          rawFilePath: 'raw/dummy.mp4',
          mediaType: MediaType.video,
          createdAt: DateTime.now(),
          sessionId: session.id,
          conversionStatus: ConversionStatus.pending,
          sets: <ExerciseSet>[firstSet],
          // Pre-stamp videoRepsPerLoop so withPersistenceDefaults is a
          // no-op on the initial save and subsequent copyWith calls
          // preserve the value (otherwise the implicit defaulting on
          // the first save would diverge from this in-memory `ex` and
          // the conversion-status copyWith below would look like a
          // user-content delta against the persisted row).
          videoRepsPerLoop: 3,
        );
        await storage.saveExercise(ex);

        // Simulate "publish just happened" — clear the stamp back to
        // null so we can observe conversion-progress writes in
        // isolation.
        await storage.db.update(
          'sessions',
          {'last_content_edit_at': null},
          where: 'id = ?',
          whereArgs: [session.id],
        );

        final stable = await storage.getSession(session.id);
        expect(stable!.lastContentEditAt, isNull);
        expect(stable.hasUnpublishedContentChanges, isFalse);

        // Conversion-status change: the same row, only
        // `conversion_status` + `converted_file_path` flip. This is
        // the kind of write the ConversionService fires dozens of
        // times per capture — MUST stay a no-op for dirty-state.
        final converting = ex.copyWith(
          conversionStatus: ConversionStatus.converting,
        );
        await storage.saveExercise(converting);

        final afterConverting = await storage.getSession(session.id);
        expect(
          afterConverting!.lastContentEditAt,
          isNull,
          reason:
              'conversion_status churn must NOT stamp the session',
        );

        final done = ex.copyWith(
          conversionStatus: ConversionStatus.done,
          convertedFilePath: 'converted/dummy.mp4',
          thumbnailPath: 'thumbnails/dummy.jpg',
        );
        await storage.saveExercise(done);

        final afterDone = await storage.getSession(session.id);
        expect(
          afterDone!.lastContentEditAt,
          isNull,
          reason:
              'converted_file_path / thumbnail_path updates must NOT stamp the session',
        );
        expect(afterDone.hasUnpublishedContentChanges, isFalse);

        // Now a REAL user edit (per-set reps bump on the only set) —
        // that SHOULD dirty.
        final edited = done.copyWith(
          sets: <ExerciseSet>[firstSet.copyWith(reps: 12)],
        );
        await storage.saveExercise(edited);

        final afterEdit = await storage.getSession(session.id);
        expect(
          afterEdit!.lastContentEditAt,
          isNotNull,
          reason: 'A per-set reps change is a user content edit → must stamp',
        );
        expect(afterEdit.hasUnpublishedContentChanges, isTrue);
      },
    );
  });
}
