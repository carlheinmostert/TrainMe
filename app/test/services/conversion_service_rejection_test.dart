// Safe Mode rejection cleanup contract — regression test for the
// orphan-exercise-after-rejection bug (2026-05-25 wave).
//
// The bug: when a Safe Mode capture tripped the middle-band rejection
// (5% < miss-rate < 100%), the rejection catch block deleted the row
// from SQLite + broadcast on the rejection stream so the capture
// screen could toast. But it never told Studio / ClientSessions to
// drop the card from their in-memory list. Result: a card stuck in
// `converting` state with no underlying SQLite row, lingering until
// app restart.
//
// Root cause (hypothesis 2 from the spec — section 3b): the conversion
// service emitted SafeModeRejection on a dedicated rejection stream
// but NEVER fired anything on `onConversionUpdate` or any other
// signal that list-rendering screens subscribed to. The SQLite row
// vanished, the listener never knew.
//
// Fix shape (2026-05-25): introduce `onExerciseRemoved` stream
// carrying an `ExerciseRemoval` payload. Studio + ClientSessions
// subscribe and drop the card synchronously. The handler is extracted
// to `handleSafeModeRejection` so this regression test can drive it
// without standing up the full conversion queue.
//
// This file's FIRST test (`onExerciseRemoved emits when …`) is the
// iron-law regression guard — it would fail on staging tip today
// because neither the stream nor the public helper existed. After the
// fix it passes.

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:raidme/models/exercise_capture.dart';
import 'package:raidme/services/conversion_service.dart';
import 'package:raidme/services/local_storage_service.dart';

/// Storage double whose `deleteExercise` throws on demand. Lets us
/// verify the post-fix contract: even when the SQLite delete fails,
/// listeners must still receive the removal event so the in-memory
/// card disappears. (Pre-fix the cleanup swallowed the throw and
/// emitted nothing, which is exactly what produced the orphan.)
class _ThrowingDeleteStorage extends LocalStorageService {
  bool deleteCalled = false;
  ExerciseCapture? _row;

  void seed(ExerciseCapture e) {
    _row = e;
  }

  @override
  Future<ExerciseCapture?> getExerciseById(String id) async {
    if (_row != null && _row!.id == id) return _row;
    return null;
  }

  @override
  Future<void> deleteExercise(String id) async {
    deleteCalled = true;
    throw StateError('simulated SQLite delete failure');
  }
}

ExerciseCapture _safeModeExercise(String id) {
  // Absolute paths so PathResolver.resolve doesn't trip on a null
  // docsDir (we don't initialise path_provider in this test). The
  // files don't have to exist — _deleteFileIfExists silently skips
  // missing files.
  return ExerciseCapture(
    id: id,
    position: 0,
    rawFilePath: '/tmp/raidme-test-$id.mp4',
    mediaType: MediaType.video,
    createdAt: DateTime.now(),
    sessionId: 's-rejection',
    safeModeActive: true,
    conversionStatus: ConversionStatus.converting,
  );
}

void main() {
  setUpAll(() {
    // Required because ConversionService constructor wires up a
    // MethodChannel handler — that needs a binary messenger which
    // only exists after the binding is initialised.
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
  });

  group('handleSafeModeRejection — orphan-after-rejection guard', () {
    test(
      'onExerciseRemoved emits when a Safe Mode capture is rejected '
      '(staging-tip behaviour: no removal event — orphan card stayed)',
      () async {
        final storage = await LocalStorageService.openForTest(
          path: inMemoryDatabasePath,
          factory: databaseFactoryFfi,
        );
        addTearDown(storage.close);

        // The in-memory FFI DB doesn't enforce FKs by default so we
        // can insert an exercise row directly without seeding a
        // parent session. Keeps the test narrowly scoped to the
        // rejection-cleanup contract.
        final original = _safeModeExercise('orphan-test-1');
        await storage.saveExercise(original);

        // Verify the seed landed.
        final pre = await storage.getExerciseById(original.id);
        expect(pre, isNotNull);

        final svc = ConversionService.forTest(storage);

        final removals = <ExerciseRemoval>[];
        final removalSub = svc.onExerciseRemoved.listen(removals.add);
        addTearDown(removalSub.cancel);
        final rejections = <SafeModeRejection>[];
        final rejectionSub =
            svc.onSafeModeRejection.listen(rejections.add);
        addTearDown(rejectionSub.cancel);

        await svc.handleSafeModeRejection(
          SafeModeRejection(original.id, 0.5),
        );
        // Flush microtasks so the broadcast listener callbacks run
        // before we assert. handleSafeModeRejection awaits the SQLite
        // delete but the StreamController.add hand-off completes on
        // the next microtask hop.
        await Future<void>.delayed(Duration.zero);

        // The pivotal assertion — fixed by the 2026-05-25 wave. On
        // staging tip there was no onExerciseRemoved stream at all;
        // listeners had no signal to drop the card.
        expect(
          removals,
          hasLength(1),
          reason:
              'onExerciseRemoved must emit exactly one event so '
              'Studio + ClientSessions drop the orphan card.',
        );
        expect(removals.single.exerciseId, original.id);
        expect(removals.single.reason, 'safe_mode_rejection');

        // The exercise snapshot rides along so listeners can scrub
        // sibling state (session position, focus offset) without an
        // additional SQLite read.
        expect(removals.single.exercise, isNotNull);
        expect(removals.single.exercise!.id, original.id);

        // Rejection stream still fires (existing capture-screen toast).
        expect(rejections, hasLength(1));
        expect(rejections.single.exerciseId, original.id);

        // SQLite row is gone.
        final after = await storage.getExerciseById(original.id);
        expect(
          after,
          isNull,
          reason: 'rejection cleanup must delete the SQLite row',
        );
      },
    );

    test(
      'removal event still fires when the SQLite delete throws — '
      'in-memory card disappears even if the row leaks',
      () async {
        final storage = _ThrowingDeleteStorage();
        final original = _safeModeExercise('orphan-test-throw');
        storage.seed(original);

        final svc = ConversionService.forTest(storage);

        final removals = <ExerciseRemoval>[];
        final removalSub = svc.onExerciseRemoved.listen(removals.add);
        addTearDown(removalSub.cancel);

        await svc.handleSafeModeRejection(
          SafeModeRejection(original.id, 0.5),
        );
        await Future<void>.delayed(Duration.zero);

        expect(
          storage.deleteCalled,
          isTrue,
          reason: 'rejection cleanup must attempt the SQLite delete',
        );
        expect(
          removals,
          hasLength(1),
          reason:
              'Even when SQLite throws, listeners must get the '
              'removal event — a stuck spinner is worse than an '
              'orphaned DB row (covered by periodic cleanup).',
        );
        expect(removals.single.exerciseId, original.id);
      },
    );
  });

  // R2-L2 — race-protection contract for the self-verification stamp.
  //
  // `_runSelfVerification` re-reads the latest exercise row from SQLite
  // immediately before stamping `self_verified`. The rationale (see
  // ConversionService line ~2369): a parallel update (raw-archive
  // completion, hero thumbnail regen, etc) can race the verification
  // pipeline on the same row. Without the re-read, the stamp would
  // clobber whatever the parallel update wrote.
  //
  // This test simulates the race: seed a row, simulate an intermediate
  // update landing AFTER the verification's snapshot but BEFORE its
  // persist call, then assert that the persisted row carries BOTH the
  // racing update's field AND the verification's stamp.
  group('self-verification stamp re-reads SQLite before persisting', () {
    test(
      'stampSelfVerifiedForTest uses the latest row, not a stale snapshot',
      () async {
        final storage = await LocalStorageService.openForTest(
          path: inMemoryDatabasePath,
          factory: databaseFactoryFfi,
        );
        addTearDown(storage.close);

        // Seed a baseline exercise.
        final initial = _safeModeExercise('self-verify-race-1');
        await storage.saveExercise(initial);

        final svc = ConversionService.forTest(storage);

        // Simulate the intermediate update that the verification
        // pipeline must NOT clobber. Field choice: thumbnailPath, which
        // is touched by the parallel hero-regen path on the same row.
        final racingUpdate = initial.copyWith(
          thumbnailPath: 'racing/thumb.jpg',
        );
        await storage.saveExercise(racingUpdate);

        // Stamp self_verified through the test surface. The helper
        // mirrors the production re-read path: it must source from
        // SQLite, not from the supplied `initial` snapshot.
        final persisted =
            await svc.stampSelfVerifiedForTest(initial, true);

        expect(persisted, isNotNull);
        expect(persisted!.selfVerified, isTrue,
            reason: 'the stamped flag must persist');
        expect(
          persisted.thumbnailPath,
          'racing/thumb.jpg',
          reason:
              'the intermediate write must not be clobbered — the '
              "stamping path re-reads SQLite before applying its diff",
        );

        // Read straight from storage as a double-check that we wrote
        // what we said we wrote.
        final loaded = await storage.getExerciseById(initial.id);
        expect(loaded, isNotNull);
        expect(loaded!.selfVerified, isTrue);
        expect(loaded.thumbnailPath, 'racing/thumb.jpg');
      },
    );
  });
}
