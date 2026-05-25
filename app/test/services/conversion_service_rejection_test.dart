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
}
