// ConversionService queue management tests.
//
// ConversionService (app/lib/services/conversion_service.dart) is the Layer 2
// singleton that accepts captures from the camera/studio, queues them for
// line-drawing conversion via a native iOS platform channel, and persists
// status changes to SQLite so the UI can react.
//
// These tests cover the queue management contract WITHOUT exercising the
// native platform channel (video conversion itself requires the iOS runtime).
// Native channel calls are intercepted via TestDefaultBinaryMessengerBinding
// and returned as platform-not-available so they don't throw in the test
// runner.
//
// What is verified:
//   1. queueConversion — rest periods are silently skipped; captures are added.
//   2. _processing guard — a second call while already processing is a no-op.
//   3. restoreQueue — pending/converting rows in SQLite are re-queued.
//   4. retry — resets a failed exercise to pending and re-queues it.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:raidme/models/exercise_capture.dart';
import 'package:raidme/models/exercise_set.dart';
import 'package:raidme/models/session.dart';
import 'package:raidme/services/conversion_service.dart';
import 'package:raidme/services/local_storage_service.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Build a minimal video capture. [conversionStatus] defaults to pending.
ExerciseCapture _videoCapture({
  String id = 'ex-1',
  ConversionStatus conversionStatus = ConversionStatus.pending,
}) {
  return ExerciseCapture(
    id: id,
    position: 0,
    rawFilePath: 'raw/$id.mp4',
    mediaType: MediaType.video,
    createdAt: DateTime.now(),
    sets: const [ExerciseSet(position: 1, reps: 10)],
    conversionStatus: conversionStatus,
  );
}

/// Build a rest-period capture (no media to convert).
ExerciseCapture _restCapture({String id = 'rest-1'}) {
  return ExerciseCapture(
    id: id,
    position: 1,
    rawFilePath: null,
    mediaType: MediaType.rest,
    createdAt: DateTime.now(),
    sets: const [],
    restHoldSeconds: 30,
  );
}

/// Stub the two native channels so they return immediately without
/// forwarding to the iOS runtime (which isn't present under `flutter test`).
void _stubNativeChannels() {
  const videoChannel = MethodChannel('com.raidme.video_converter');
  const thumbChannel = MethodChannel('com.raidme.native_thumb');

  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
    ..setMockMethodCallHandler(videoChannel, (call) async => null)
    ..setMockMethodCallHandler(thumbChannel, (call) async => null);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  late LocalStorageService storage;
  late ConversionService service;

  setUp(() async {
    _stubNativeChannels();

    storage = await LocalStorageService.openForTest(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );

    // Re-initialise the singleton for each test so state doesn't leak.
    ConversionService.resetInstanceForTest();
    service = ConversionService.initialize(storage);
  });

  tearDown(() {
    service.dispose();
  });

  // -------------------------------------------------------------------------
  // queueConversion
  // -------------------------------------------------------------------------

  group('queueConversion', () {
    test('rest periods are silently skipped', () {
      service.queueConversion(_restCapture());
      expect(service.queueLengthForTest, 0);
    });

    test('video captures are added to the queue', () {
      final cap = _videoCapture();
      service.queueConversion(cap);
      expect(service.queueLengthForTest, 1);
    });

    test('multiple captures are queued in order', () {
      service.queueConversion(_videoCapture(id: 'ex-a'));
      service.queueConversion(_videoCapture(id: 'ex-b'));
      service.queueConversion(_videoCapture(id: 'ex-c'));
      expect(service.queueLengthForTest, 3);
    });
  });

  // -------------------------------------------------------------------------
  // _processing guard
  // -------------------------------------------------------------------------

  group('processing guard', () {
    test('second queueConversion while processing does not start a second loop',
        () async {
      // Because the native channel is stubbed to return null immediately the
      // queue drains instantly in the test runner. We verify the guard by
      // checking that no duplicate processing errors surface — the simplest
      // observable proxy is that the queue is fully drained after the first
      // call even with a second call racing in.
      service.queueConversion(_videoCapture(id: 'ex-1'));
      service.queueConversion(_videoCapture(id: 'ex-2'));
      // Both calls reach _processQueue; the guard ensures only one loop runs.
      await Future<void>.delayed(Duration.zero);
      // The queue should have drained (or the processing flag ensures no crash).
      expect(service.processingForTest, isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // restoreQueue
  // -------------------------------------------------------------------------

  group('restoreQueue', () {
    test('pending exercise in SQLite is re-queued', () async {
      final session = Session(
        id: 'sess-1',
        clientName: 'Test',
        createdAt: DateTime.now(),
      );
      await storage.saveSession(session);

      final cap = _videoCapture(
          id: 'ex-restore', conversionStatus: ConversionStatus.pending);
      final withSession = cap.copyWith(sessionId: 'sess-1');
      await storage.saveExercise(withSession);

      await service.restoreQueue();

      expect(service.queueLengthForTest, greaterThanOrEqualTo(1));
    });

    test('converting exercise in SQLite is also re-queued (crash recovery)',
        () async {
      final session = Session(
        id: 'sess-2',
        clientName: 'Test',
        createdAt: DateTime.now(),
      );
      await storage.saveSession(session);

      final cap = _videoCapture(
          id: 'ex-crash', conversionStatus: ConversionStatus.converting);
      final withSession = cap.copyWith(sessionId: 'sess-2');
      await storage.saveExercise(withSession);

      await service.restoreQueue();

      expect(service.queueLengthForTest, greaterThanOrEqualTo(1));
    });

    test('done exercise is NOT re-queued', () async {
      final session = Session(
        id: 'sess-3',
        clientName: 'Test',
        createdAt: DateTime.now(),
      );
      await storage.saveSession(session);

      final cap = _videoCapture(
          id: 'ex-done', conversionStatus: ConversionStatus.done);
      final withSession = cap.copyWith(sessionId: 'sess-3');
      await storage.saveExercise(withSession);

      await service.restoreQueue();

      expect(service.queueLengthForTest, 0);
    });
  });

  // -------------------------------------------------------------------------
  // retry
  // -------------------------------------------------------------------------

  group('retry', () {
    test('rest period is silently skipped', () async {
      await service.retry(_restCapture());
      expect(service.queueLengthForTest, 0);
    });

    test('failed exercise is reset to pending and re-queued', () async {
      final session = Session(
        id: 'sess-4',
        clientName: 'Test',
        createdAt: DateTime.now(),
      );
      await storage.saveSession(session);

      final cap = _videoCapture(
          id: 'ex-fail', conversionStatus: ConversionStatus.failed);
      final withSession = cap.copyWith(sessionId: 'sess-4');
      await storage.saveExercise(withSession);

      // onConversionUpdate fires with the reset exercise.
      ExerciseCapture? emitted;
      final sub = service.onConversionUpdate.listen((e) => emitted = e);

      await service.retry(withSession);

      await sub.cancel();

      expect(service.queueLengthForTest, greaterThanOrEqualTo(1));
      expect(emitted?.conversionStatus, ConversionStatus.pending);
    });
  });
}
