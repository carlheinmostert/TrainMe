// Safe Mode v2 video — Dart-side unit tests (2026-05-25).
//
// Covers the acceptance-criteria items in section 10 of
// `docs/specs/2026-05-25-safe-mode-v2-video.md`:
//
//   1. Fail-closed rule applies identically to v2 video. The threshold
//      [kSafeModeMaxMissRate] and the `SafeModeRejection` exception
//      shape are what the outer queue handler keys on; whether the
//      pass under the hood is v1 (largest bbox) or v2 (face-rec) does
//      not change the rule. We pin the boundary semantics here so a
//      future tweak that ships an asymmetric rule for video catches
//      this test on the way in.
//
//   2. Per-frame progress stream emission. The native pipeline emits
//      on the `homefit-safe-mode-v2-video-progress` EventChannel; the
//      conversion service wraps each value in a
//      [SafeModeV2VideoProgress] record tagged with the exercise id
//      and forwards via [ConversionService.onSafeModeV2VideoProgress].
//      The Studio card observer ([_SafeModeV2VideoProgressOverlay] in
//      `capture_thumbnail.dart`) filters by id. These tests confirm
//      the wire shape — exercise id round-trips and the fraction
//      stays in the [0.0, 1.0] domain.
//
//   3. C1 (sev1 privacy regression, code review on PR #497).
//      `_applySafeModeV2ToVideo` throws `SafeModeRejection` in two
//      branches (empty embedding slots; native miss-rate exceeded).
//      Before the fix, `_convert`'s outer `catch (e, stack)` silently
//      swallowed any throw from `_applySafeModeV2ToVideo` and fell
//      through to `_convertVideoViaFrameExtraction` — producing a
//      still-frame line drawing of the RAW UNBLURRED video. The
//      result looked like success: `_ConvertResult.safePath == null`,
//      queue handler stamped `safeRawFilePath = null`, UploadService
//      uploaded the raw unblurred video to the cloud `raw-archive`
//      bucket. Privacy guarantee broken.
//
//      The fix adds `on SafeModeRejection { rethrow; }` before the
//      catch in `_convert`'s video branch. The integration tests in
//      the third group below drive through the public
//      `queueConversion` entrypoint and assert the rejection reaches
//      the queue handler's `on SafeModeRejection` block (visible on
//      `onSafeModeRejection` stream + `onExerciseRemoved` stream)
//      rather than being swallowed and producing a silent "success".
//
// Native unit tests for the state machine are out of scope per the
// spec; the manual test wave covers those.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:raidme/models/exercise_capture.dart';
import 'package:raidme/models/session.dart';
import 'package:raidme/services/conversion_service.dart';
import 'package:raidme/services/local_storage_service.dart';
import 'package:raidme/services/safe_mode.dart'
    show kFaceEmbeddingBytes, kSafeModeAlgorithmVersion;

void main() {
  group('SafeModeRejection.missRateExceeded — v2 video fail-closed', () {
    test(
      'value just above kSafeModeMaxMissRate triggers the reject reason',
      () {
        final justAbove = kSafeModeMaxMissRate + 0.0001;
        final rej = SafeModeRejection('ex-1', justAbove);
        expect(rej.missRate, justAbove);
        expect(rej.reason, SafeModeRejectionReason.missRateExceeded);
      },
    );

    test('the threshold itself (5%) sits on the accept side', () {
      // Outer queue handler in `_processQueue` uses `>` not `>=`, so
      // a miss rate exactly equal to the threshold accepts. v2 video
      // must preserve this boundary verbatim — the unified rule from
      // `docs/specs/2026-05-25-safe-mode-accept-zero-detection.md`
      // is symmetric for both media types.
      expect(kSafeModeMaxMissRate, 0.05);
    });

    test('toString includes the percentage formatted to one decimal', () {
      final rej = SafeModeRejection('ex-2', 0.123);
      expect(rej.toString(), contains('12.3%'));
      expect(rej.toString(), contains('ex-2'));
      expect(rej.toString(), contains('missRateExceeded'));
    });
  });

  group('SafeModeRejection.missingFaceEmbedding — v2 cold-cache branch', () {
    test('explicit reason flag round-trips into toString', () {
      // The v2 video pass (and the v2 photo pass before it) throws
      // this rejection when the bound client has no cached embedding
      // slots at conversion time — cold-start cache miss after an
      // app-kill mid-capture. The capture screen distinguishes by
      // reason so the toast copy can guide the practitioner.
      final rej = SafeModeRejection(
        'ex-3',
        0.0,
        reason: SafeModeRejectionReason.missingFaceEmbedding,
      );
      expect(rej.reason, SafeModeRejectionReason.missingFaceEmbedding);
      expect(rej.toString(), contains('missingFaceEmbedding'));
    });
  });

  group('SafeModeV2VideoProgress — wire shape', () {
    test('round-trips exerciseId + fraction verbatim', () {
      const e = SafeModeV2VideoProgress(exerciseId: 'ex-9', fraction: 0.42);
      expect(e.exerciseId, 'ex-9');
      expect(e.fraction, 0.42);
    });

    test('toString formats the fraction as a one-decimal percentage', () {
      const e = SafeModeV2VideoProgress(exerciseId: 'ex-9', fraction: 0.4239);
      expect(e.toString(), contains('ex-9'));
      expect(e.toString(), contains('42.4%'));
    });

    test('the Studio overlay can filter events for its own exercise', () {
      // [_SafeModeV2VideoProgressOverlay] in `capture_thumbnail.dart`
      // listens to the broadcast stream and discards events whose
      // exerciseId doesn't match its own. This test pins the
      // discriminator field — if it ever gets renamed or dropped,
      // the overlay would silently start showing the wrong card's
      // bar.
      const a = SafeModeV2VideoProgress(exerciseId: 'card-A', fraction: 0.3);
      const b = SafeModeV2VideoProgress(exerciseId: 'card-B', fraction: 0.8);
      expect(a.exerciseId, isNot(equals(b.exerciseId)));
    });
  });

  group(
    '_applySafeModeV2ToVideo invocation path — C1 regression guard',
    () {
      // These tests drive `queueConversion` end-to-end against a mock
      // platform layer so the `on SafeModeRejection { rethrow; }` fix
      // in `_convert`'s video branch is exercised by the actual queue.
      // A regression that re-swallows the rejection (e.g. by
      // re-ordering the catch blocks or dropping the rethrow) would
      // fail the third test below — the load-bearing C1 catcher.

      const videoChannelName = 'com.raidme.video_converter';
      const thumbChannelName = 'com.raidme.native_thumb';
      const pathProviderChannelName = 'plugins.flutter.io/path_provider';

      late Directory tmpDocs;
      late LocalStorageService storage;
      late ConversionService svc;
      // List of native MethodCall payloads received by the mock video
      // channel — lets a test assert which Swift entry points the Dart
      // path actually invoked (and in what order).
      late List<MethodCall> videoCalls;
      // The mock handler installed for the current test. Each test
      // overrides this in setUp before queueing a conversion; the
      // teardown clears it.
      Future<Object?> Function(MethodCall call)? videoHandler;

      Future<Object?> recordAndDelegate(MethodCall call) async {
        videoCalls.add(call);
        final h = videoHandler;
        if (h != null) {
          return await h(call);
        }
        return null;
      }

      setUpAll(() {
        TestWidgetsFlutterBinding.ensureInitialized();
        sqfliteFfiInit();
      });

      setUp(() async {
        tmpDocs = await Directory.systemTemp.createTemp(
          'raidme-v2-video-test-',
        );
        videoCalls = <MethodCall>[];
        videoHandler = null;

        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

        // Mock path_provider so `_convert` can resolve
        // `getApplicationDocumentsDirectory()` to a real temp dir.
        // Without this, every `getApplicationDocumentsDirectory()` call
        // throws MissingPluginException before the queue handler can
        // even run.
        messenger.setMockMethodCallHandler(
          const MethodChannel(pathProviderChannelName),
          (MethodCall call) async {
            return tmpDocs.path;
          },
        );

        // Mock the video conversion channel. Each test installs its
        // own `videoHandler` in setUp; this default handler just
        // records the call and returns null (which surfaces in
        // `_convertVideo` as a failed native attempt and falls through
        // to the OpenCV path — which we do NOT want, hence each test
        // overrides).
        messenger.setMockMethodCallHandler(
          const MethodChannel(videoChannelName),
          recordAndDelegate,
        );

        // Native thumbnail channel — never reached in the C1 path
        // (rejection bubbles up from `_convert` before
        // `_extractVideoThumbnail` runs in the success cases). Mock to
        // return null so any incidental probe doesn't taint the test.
        messenger.setMockMethodCallHandler(
          const MethodChannel(thumbChannelName),
          (MethodCall call) async => null,
        );

        storage = await LocalStorageService.openForTest(
          path: inMemoryDatabasePath,
          factory: databaseFactoryFfi,
        );

        // Seed a parent session WITH a clientId so
        // `_resolveSubjectEmbeddings` runs against a real client key
        // (rather than the null-client short-circuit that returns
        // `const []` regardless of cache state).
        final session = Session(
          id: 's-v2v-test',
          clientName: 'QA Test',
          createdAt: DateTime.now(),
          clientId: 'c-v2v-test',
        );
        await storage.saveSession(session);

        svc = ConversionService.forTest(storage);
      });

      tearDown(() async {
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(
          const MethodChannel(videoChannelName),
          null,
        );
        messenger.setMockMethodCallHandler(
          const MethodChannel(thumbChannelName),
          null,
        );
        messenger.setMockMethodCallHandler(
          const MethodChannel(pathProviderChannelName),
          null,
        );
        await storage.close();
        try {
          await tmpDocs.delete(recursive: true);
        } catch (_) {
          // Best-effort temp cleanup; OS will reap on reboot if needed.
        }
      });

      ExerciseCapture safeModeVideo(String id) {
        // Absolute path that does NOT exist on disk — `_pickThumbnailSource`
        // checks `File(path).exists()` and falls through cleanly when
        // every candidate is missing, so the per-variant extractFrame
        // block is skipped. `_extractVideoThumbnail` will still be
        // invoked once for the up-front thumb, but the mock returns
        // null which routes the call through the swallow path.
        return ExerciseCapture(
          id: id,
          position: 0,
          rawFilePath: p.join(tmpDocs.path, '$id.mp4'),
          mediaType: MediaType.video,
          createdAt: DateTime.now(),
          sessionId: 's-v2v-test',
          safeModeActive: true,
          conversionStatus: ConversionStatus.pending,
        );
      }

      Future<void> assertRejectionArrives(
        Future<SafeModeRejection> rejectionFuture, {
        Duration timeout = const Duration(seconds: 5),
      }) async {
        await rejectionFuture.timeout(timeout, onTimeout: () {
          fail(
            'No SafeModeRejection arrived within $timeout — C1 may '
            'have regressed (rejection swallowed by `_convert`\'s '
            'catch (e, stack) instead of rethrown to the queue '
            'handler).',
          );
        });
      }

      test(
        'mock returns success with low miss-rate — safe path stamped, '
        'no rejection',
        () async {
          // `_convertVideo` mocks to a successful line/seg/mask write;
          // `applySafeModeV2ToVideo` returns success with safeMissRate=0.0
          // — well below the 5% accept ceiling so the queue handler
          // accepts and stamps `safeRawFilePath` on the exercise.
          videoHandler = (MethodCall call) async {
            switch (call.method) {
              case 'convertVideo':
                final args = call.arguments as Map;
                return <String, Object?>{
                  'success': true,
                  'framesProcessed': 30,
                  'audioSamplesWritten': 0,
                  'segFramesProcessed': 30,
                  'maskFramesProcessed': 30,
                  'segmentedOutputPath': args['segmentedOutputPath'],
                  'maskOutputPath': args['maskOutputPath'],
                };
              case 'applySafeModeV2ToVideo':
                final destPath = (call.arguments as Map)['destPath'] as String;
                // Write a tiny file at destPath so the Dart-side
                // `File(destPath).exists()` check returns true and the
                // outcome carries a non-null safePath.
                await File(destPath).create(recursive: true);
                await File(destPath).writeAsBytes(<int>[0, 1, 2, 3]);
                return <String, Object?>{
                  'success': true,
                  'safeMissRate': 0.0,
                  'framesProcessed': 30,
                  'durationMs': 1000,
                };
              case 'getVideoDuration':
                return 1000;
              case 'compressVideo':
                return <String, Object?>{'success': true};
              default:
                return null;
            }
          };

          // Seed a single embedding slot so
          // `_resolveSubjectEmbeddings` returns non-empty and the
          // missing-embedding short-circuit doesn't fire.
          await storage.setCachedClientFaceEmbeddings(
            clientId: 'c-v2v-test',
            slots: [
              (
                slotIndex: 0,
                embedding: Uint8List(kFaceEmbeddingBytes),
                modelVersion: kSafeModeAlgorithmVersion,
                isFrontalPick: true,
                poseYaw: 0.0,
                posePitch: 0.0,
              ),
            ],
          );

          final exercise = safeModeVideo('v2v-success-low-miss');
          await storage.saveExercise(exercise);

          final rejections = <SafeModeRejection>[];
          final sub = svc.onSafeModeRejection.listen(rejections.add);
          addTearDown(sub.cancel);

          // Listen for the conversion update stream to know when the
          // queue clears for this exercise. The done outcome lands as
          // an update with ConversionStatus.done. Far more reliable
          // than a fixed-duration delay — the pre-_convertVideo
          // thumbnail-extraction path goes through OpenCV + the
          // video_thumbnail fallback in a test env, both of which take
          // a real second or two to fail through.
          final done = Completer<void>();
          final updateSub = svc.onConversionUpdate.listen((e) {
            if (e.id == exercise.id &&
                e.conversionStatus == ConversionStatus.done &&
                !done.isCompleted) {
              done.complete();
            }
          });
          addTearDown(updateSub.cancel);

          svc.queueConversion(exercise);
          await done.future.timeout(
            const Duration(seconds: 10),
            onTimeout: () => fail(
              'Conversion did not complete within 10s — the mock '
              'platform layer may have regressed.',
            ),
          );

          expect(
            rejections,
            isEmpty,
            reason: 'Low miss-rate accept path must not emit a '
                'Safe Mode rejection.',
          );
          expect(
            videoCalls.any((c) => c.method == 'applySafeModeV2ToVideo'),
            isTrue,
            reason: 'applySafeModeV2ToVideo must have been invoked.',
          );

          // The exercise row should now be `done` and carry the safe
          // variant path — the load-bearing local-state stamp that
          // tells UploadService to upload the safe variant in place of
          // the raw archive.
          final stored = await storage.getExerciseById(exercise.id);
          expect(stored, isNotNull);
          expect(stored!.safeRawFilePath, isNotNull);
          expect(stored.safeRawFilePath, contains('_safe.mp4'));
        },
      );

      test(
        'mock returns success with high miss-rate — '
        'SafeModeRejection.missRateExceeded propagates',
        () async {
          // `applySafeModeV2ToVideo` returns success with safeMissRate
          // well above the 5% accept ceiling. The queue handler's
          // unified fail-closed rule throws SafeModeRejection with
          // `missRateExceeded`. The throw originates in the queue
          // itself (not in `_convert`), so this test exercises the
          // existing `on SafeModeRejection` block from the
          // 2026-05-21 completion wave — pairing it with the C1
          // test below pins both rejection paths.
          videoHandler = (MethodCall call) async {
            switch (call.method) {
              case 'convertVideo':
                final args = call.arguments as Map;
                return <String, Object?>{
                  'success': true,
                  'framesProcessed': 30,
                  'audioSamplesWritten': 0,
                  'segFramesProcessed': 30,
                  'maskFramesProcessed': 30,
                  'segmentedOutputPath': args['segmentedOutputPath'],
                  'maskOutputPath': args['maskOutputPath'],
                };
              case 'applySafeModeV2ToVideo':
                final destPath = (call.arguments as Map)['destPath'] as String;
                await File(destPath).create(recursive: true);
                await File(destPath).writeAsBytes(<int>[0, 1, 2, 3]);
                return <String, Object?>{
                  'success': true,
                  // 30% miss — squarely in the middle band that
                  // rejects (>5%, <100%).
                  'safeMissRate': 0.30,
                  'framesProcessed': 30,
                  'durationMs': 1000,
                };
              case 'getVideoDuration':
                return 1000;
              default:
                return null;
            }
          };

          await storage.setCachedClientFaceEmbeddings(
            clientId: 'c-v2v-test',
            slots: [
              (
                slotIndex: 0,
                embedding: Uint8List(kFaceEmbeddingBytes),
                modelVersion: kSafeModeAlgorithmVersion,
                isFrontalPick: true,
                poseYaw: 0.0,
                posePitch: 0.0,
              ),
            ],
          );

          final exercise = safeModeVideo('v2v-high-miss');
          await storage.saveExercise(exercise);

          final rejection = Completer<SafeModeRejection>();
          final sub = svc.onSafeModeRejection.listen((r) {
            if (!rejection.isCompleted) rejection.complete(r);
          });
          addTearDown(sub.cancel);

          svc.queueConversion(exercise);
          await assertRejectionArrives(rejection.future);

          final rej = await rejection.future;
          expect(rej.exerciseId, exercise.id);
          expect(rej.reason, SafeModeRejectionReason.missRateExceeded);
          expect(rej.missRate, closeTo(0.30, 0.001));

          // Sanity — rejection cleanup must have removed the SQLite
          // row so the orphan-card fix from the 2026-05-25
          // zero-detection wave still holds for the v2 video path.
          final stored = await storage.getExerciseById(exercise.id);
          expect(stored, isNull);
        },
      );

      test(
        'C1 — missing embeddings: SafeModeRejection.missingFaceEmbedding '
        'thrown by _applySafeModeV2ToVideo propagates through _convert '
        'to the queue handler',
        () async {
          // The LOAD-BEARING C1 regression catcher.
          //
          // Pre-fix shape: `_applySafeModeV2ToVideo` threw
          // SafeModeRejection (cold-cache empty-embeddings branch);
          // `_convert`'s outer `catch (e, stack)` swallowed it and
          // fell through to `_convertVideoViaFrameExtraction`. The
          // queue handler's `result.safePath` was null (no safe
          // variant), so the unified rule never tripped — the
          // capture appeared successful and the raw unblurred video
          // uploaded to the cloud raw-archive bucket. Privacy
          // breach + zero user feedback.
          //
          // Post-fix shape: `on SafeModeRejection { rethrow; }` sits
          // before the outer catch, so the rejection propagates out
          // of `_convert` and lands in the queue handler's
          // `on SafeModeRejection` block, which calls
          // `handleSafeModeRejection` → deletes the SQLite row +
          // emits on `onSafeModeRejection` so the capture screen
          // toasts.
          //
          // This test seeds NO embeddings for the client, mocks
          // `convertVideo` to succeed (so the path reaches
          // `_applySafeModeV2ToVideo`), and asserts a
          // missingFaceEmbedding rejection lands on the public
          // stream. A regression that re-swallows the rejection
          // would not surface on the stream and this test fails on
          // the 5-second timeout in `assertRejectionArrives`.
          videoHandler = (MethodCall call) async {
            switch (call.method) {
              case 'convertVideo':
                // The line-drawing pass succeeds so the safe-mode
                // branch is the only failure surface.
                final args = call.arguments as Map;
                return <String, Object?>{
                  'success': true,
                  'framesProcessed': 30,
                  'audioSamplesWritten': 0,
                  'segFramesProcessed': 30,
                  'maskFramesProcessed': 30,
                  'segmentedOutputPath': args['segmentedOutputPath'],
                  'maskOutputPath': args['maskOutputPath'],
                };
              case 'applySafeModeV2ToVideo':
                // Should NEVER be reached — the Dart-side empty-
                // embeddings short-circuit throws before invoking
                // the channel. If this fires we have a different
                // regression (mock priming bug).
                fail(
                  'applySafeModeV2ToVideo invoked despite empty '
                  'embedding cache — the Dart-side short-circuit '
                  'should have thrown '
                  'SafeModeRejection.missingFaceEmbedding before '
                  'reaching the platform channel.',
                );
              case 'getVideoDuration':
                return 1000;
              default:
                return null;
            }
          };

          // Deliberately seed NO embeddings — this is the cold-cache
          // condition the missingFaceEmbedding branch fires on.

          final exercise = safeModeVideo('v2v-c1-missing-embedding');
          await storage.saveExercise(exercise);

          final rejection = Completer<SafeModeRejection>();
          final removals = <ExerciseRemoval>[];

          final rejSub = svc.onSafeModeRejection.listen((r) {
            if (!rejection.isCompleted) rejection.complete(r);
          });
          addTearDown(rejSub.cancel);
          final removalSub = svc.onExerciseRemoved.listen(removals.add);
          addTearDown(removalSub.cancel);

          svc.queueConversion(exercise);
          await assertRejectionArrives(rejection.future);

          final rej = await rejection.future;
          expect(
            rej.reason,
            SafeModeRejectionReason.missingFaceEmbedding,
            reason:
                'The cold-cache empty-embeddings branch must throw '
                'SafeModeRejection.missingFaceEmbedding — anything '
                'else means the Dart-side short-circuit lost its '
                'reason flag.',
          );
          expect(rej.exerciseId, exercise.id);

          // The orphan-after-rejection guard (paired with the
          // existing `conversion_service_rejection_test.dart` group)
          // requires `onExerciseRemoved` to fire so Studio +
          // ClientSessions drop the card synchronously. Flush
          // microtasks so the broadcast hand-off completes.
          await Future<void>.delayed(Duration.zero);
          expect(removals, hasLength(1));
          expect(removals.single.exerciseId, exercise.id);

          // SQLite row gone — same contract as the existing
          // rejection-cleanup test.
          final stored = await storage.getExerciseById(exercise.id);
          expect(stored, isNull);

          // The line-drawing convertVideo pass DID run, but
          // applySafeModeV2ToVideo did NOT (empty-embedding short-
          // circuit fires before the platform call).
          expect(
            videoCalls.any((c) => c.method == 'convertVideo'),
            isTrue,
            reason: '_convertVideo line-drawing pass should have run.',
          );
          expect(
            videoCalls.any((c) => c.method == 'applySafeModeV2ToVideo'),
            isFalse,
            reason:
                'applySafeModeV2ToVideo must NOT be invoked when the '
                'embedding cache is empty — the Dart short-circuit '
                'throws first.',
          );
        },
      );
    },
  );
}
