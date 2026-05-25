// Exercise clone unit tests (S-7 — review finding 2026-05-25).
//
// Pins the `cloneExerciseInto` contract from
// `app/lib/services/exercise_clone.dart` — the deep-copy machinery that
// powers Studio's swipe-to-duplicate AND the Exercise Clipboard's paste
// path (decision D8 in the spec). Asserts the carry / reset / strip
// matrix the docstring promises.
//
// Strategy (option (c) from the brief): real file IO against
// `Directory.systemTemp.createTemp()`. Initialises `PathResolver` via a
// mock path_provider method channel so `cloneExerciseInto` can resolve
// relative paths the same way it does in production. Files are tiny
// dummy blobs; the copies are fast.
//
// NOTE: This test deliberately makes NO assertion about `selfVerified` —
// that field is not on this branch (it arrives via Carl's later rebase
// of the self-trainer wave). The B-1 fix will add a `selfVerified`
// assertion at rebase time.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:raidme/models/exercise_capture.dart';
import 'package:raidme/models/exercise_set.dart';
import 'package:raidme/models/session.dart';
import 'package:raidme/models/treatment.dart';
import 'package:raidme/services/exercise_clone.dart';
import 'package:raidme/services/path_resolver.dart';

/// The platform channel the `path_provider` Flutter plugin invokes
/// natively. Mocking it returns deterministic paths so PathResolver can
/// `initialize()` under `flutter test`.
const _pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

late Directory _tempDocsDir;

/// Wire up `path_provider` so `PathResolver.initialize()` resolves to
/// our temp dir.
void _installPathProviderMock(Directory dir) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_pathProviderChannel, (call) async {
    // Every directory query the plugin exposes returns the same temp
    // dir — sufficient for these tests, which only touch
    // `getApplicationDocumentsDirectory`.
    return dir.path;
  });
}

void _uninstallPathProviderMock() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_pathProviderChannel, null);
}

/// Write a tiny placeholder so `_copyExerciseFile` finds the source on
/// disk. Returns the relative path stored on the source row.
Future<String> _seedFile(String relativePath, {String body = 'dummy'}) async {
  final abs = p.join(_tempDocsDir.path, relativePath);
  final f = File(abs);
  await f.parent.create(recursive: true);
  await f.writeAsString(body);
  return relativePath;
}

Session _targetSession({
  String id = 'target-session',
  List<ExerciseCapture> exercises = const <ExerciseCapture>[],
}) {
  return Session(
    id: id,
    clientName: 'Target Client',
    createdAt: DateTime.now(),
    exercises: exercises,
  );
}

/// Build a source exercise with EVERY carry / reset / strip field set
/// to a recognisable value so the clone-side assertions can spot any
/// drift.
Future<ExerciseCapture> _seedSourceExercise({
  String id = 'src-1',
  String sessionId = 'src-session',
}) async {
  final rawRel = await _seedFile('raw/$id.mp4');
  final convertedRel = await _seedFile('converted/$id.mp4');
  final thumbRel = await _seedFile('thumbs/$id.jpg');
  final archiveRel = await _seedFile('archive/$id.mp4');
  final segRel = await _seedFile('segmented/$id.segmented.mp4');
  final maskRel = await _seedFile('mask/$id.mask.mp4');
  final safeRel = await _seedFile('safe/${id}_safe.mp4');
  // Per-treatment thumbnail variants live under {docs}/thumbnails/.
  await _seedFile('thumbnails/${id}_thumb_color.jpg');
  await _seedFile('thumbnails/${id}_thumb_line.jpg');
  await _seedFile('thumbnails/${id}_thumb_bw.jpg');

  return ExerciseCapture(
    id: id,
    position: 7, // deliberately not 0 — clone should override with target end
    rawFilePath: rawRel,
    convertedFilePath: convertedRel,
    thumbnailPath: thumbRel,
    mediaType: MediaType.video,
    conversionStatus: ConversionStatus.done,
    sets: <ExerciseSet>[
      ExerciseSet.create(
        position: 1,
        reps: 12,
        holdSeconds: 4,
        breatherSecondsAfter: 45,
      ),
      ExerciseSet.create(
        position: 2,
        reps: 10,
        holdSeconds: 2,
        breatherSecondsAfter: 30,
      ),
    ],
    notes: 'Watch the elbow lock-out.',
    name: 'Overhead Press',
    createdAt: DateTime(2024, 1, 1, 9), // old; clone should reset to "now"
    sessionId: sessionId,
    circuitId: 'circuit-source-only', // must be stripped on clone
    includeAudio: true,
    prepSeconds: 8,
    videoDurationMs: 6500,
    archiveFilePath: archiveRel,
    archivedAt: DateTime(2024, 2, 2, 10),
    rawArchiveUploadedAt: DateTime(2024, 3, 3, 11), // must be reset
    segmentedRawFilePath: segRel,
    maskFilePath: maskRel,
    preferredTreatment: Treatment.grayscale,
    startOffsetMs: 250,
    endOffsetMs: 6000,
    videoRepsPerLoop: 4,
    aspectRatio: 16 / 9,
    rotationQuarters: 1,
    bodyFocus: true,
    focusFrameOffsetMs: 2200,
    heroCropOffset: 0.7,
    thumbnailsDirty: true, // clone should reset to false
    safeModeActive: true, // carry
    capturedInPremisesId: 'premises-abc', // carry
    safeRawFilePath: safeRel,
    safeModeAlgorithmVersion: 2, // carry
    selfVerified: true, // carry — D8: true statement about the footage
  );
}

void main() {
  // ChangeNotifier / platform channel / temp-dir all need the binding
  // initialised.
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  setUp(() async {
    _tempDocsDir = await Directory.systemTemp.createTemp('raidme-clone-test-');
    _installPathProviderMock(_tempDocsDir);
    await PathResolver.initialize();
  });

  tearDown(() async {
    _uninstallPathProviderMock();
    try {
      await _tempDocsDir.delete(recursive: true);
    } catch (_) {
      // Best-effort cleanup. Some files may be locked on Windows CI;
      // not worth failing the test over.
    }
  });

  group('cloneExerciseInto — Carry matrix (describes WHAT the footage is)',
      () {
    test('carries every field documented in the spec D8 Carry list',
        () async {
      final src = await _seedSourceExercise();
      final target = _targetSession();
      final clone = await cloneExerciseInto(
        source: src,
        targetSession: target,
      );

      // --- D8 Carry list ---
      expect(clone.name, src.name);
      expect(clone.notes, src.notes);
      expect(clone.mediaType, src.mediaType);
      expect(clone.prepSeconds, src.prepSeconds);
      expect(clone.videoDurationMs, src.videoDurationMs);
      expect(clone.videoRepsPerLoop, src.videoRepsPerLoop);
      expect(clone.aspectRatio, src.aspectRatio);
      expect(clone.rotationQuarters, src.rotationQuarters);
      expect(clone.includeAudio, src.includeAudio);

      expect(clone.startOffsetMs, src.startOffsetMs);
      expect(clone.endOffsetMs, src.endOffsetMs);
      expect(clone.preferredTreatment, src.preferredTreatment);

      // Safe Mode audit (D8 explicitly calls these out — describes the
      // event of capture).
      expect(clone.safeModeActive, src.safeModeActive);
      expect(clone.capturedInPremisesId, src.capturedInPremisesId);
      expect(clone.safeModeAlgorithmVersion, src.safeModeAlgorithmVersion);

      // Self-verification (D8): true statement about the footage.
      // Harmless when target client isn't the user; publish-credit logic
      // only checks this when target session's Client is the User.
      expect(clone.selfVerified, src.selfVerified);

      // archivedAt: timestamp of the source's archive — carries
      // because it describes the footage, not the row.
      expect(clone.archivedAt, src.archivedAt);
    });

    test('carries auxiliary footage descriptors not enumerated above',
        () async {
      // Sanity check on the other carry-shaped fields the spec implies
      // (Hero crop / focus frame / body focus). Not in the bulleted
      // list but described in the docstring as "describes what the
      // footage looks like".
      final src = await _seedSourceExercise();
      final target = _targetSession();
      final clone = await cloneExerciseInto(
        source: src,
        targetSession: target,
      );

      expect(clone.bodyFocus, src.bodyFocus);
      expect(clone.focusFrameOffsetMs, src.focusFrameOffsetMs);
      expect(clone.heroCropOffset, src.heroCropOffset);
      expect(clone.conversionStatus, src.conversionStatus);
    });
  });

  group('cloneExerciseInto — Reset matrix (describes WHERE the row lives)',
      () {
    test('id is a fresh UUID, different from the source', () async {
      final src = await _seedSourceExercise();
      final target = _targetSession();
      final clone = await cloneExerciseInto(
        source: src,
        targetSession: target,
      );
      expect(clone.id, isNot(src.id));
      expect(clone.id, isNotEmpty);
    });

    test('sessionId is the target session id, not the source session id',
        () async {
      final src = await _seedSourceExercise(sessionId: 'src-session-X');
      final target = _targetSession(id: 'target-session-Y');
      final clone = await cloneExerciseInto(
        source: src,
        targetSession: target,
      );
      expect(clone.sessionId, target.id);
      expect(clone.sessionId, isNot(src.sessionId));
    });

    test(
      'position defaults to end-of-target (length of target exercises)',
      () async {
        final src = await _seedSourceExercise();
        // Three existing rows in the target → clone should land at 3.
        final filler = await _seedSourceExercise(id: 'filler');
        final target = _targetSession(exercises: <ExerciseCapture>[
          filler,
          filler,
          filler,
        ]);

        final clone = await cloneExerciseInto(
          source: src,
          targetSession: target,
        );

        expect(clone.position, 3);
      },
    );

    test('positionOverride wins when supplied', () async {
      final src = await _seedSourceExercise();
      final target = _targetSession(exercises: <ExerciseCapture>[
        await _seedSourceExercise(id: 'f1'),
        await _seedSourceExercise(id: 'f2'),
      ]);

      final clone = await cloneExerciseInto(
        source: src,
        targetSession: target,
        positionOverride: 0,
      );

      expect(clone.position, 0);
    });

    test('createdAt is recent (set to "now", not carried from source)',
        () async {
      final src = await _seedSourceExercise();
      // Source has createdAt = 2024-01-01; clone should be within the
      // last few seconds.
      final before = DateTime.now();
      final clone = await cloneExerciseInto(
        source: src,
        targetSession: _targetSession(),
      );
      final after = DateTime.now();

      // Be generous on the upper bound (file IO can be slow on CI).
      expect(
        clone.createdAt.isBefore(before.subtract(const Duration(seconds: 1))),
        isFalse,
        reason: 'clone.createdAt must NOT be older than the test start',
      );
      expect(
        clone.createdAt.isAfter(after.add(const Duration(seconds: 1))),
        isFalse,
        reason: 'clone.createdAt must NOT be in the future',
      );
      expect(clone.createdAt, isNot(src.createdAt));
    });

    test('thumbnailsDirty is reset to false (variants were copied, not '
        'regenerated)', () async {
      final src = await _seedSourceExercise(); // thumbnailsDirty: true
      final clone = await cloneExerciseInto(
        source: src,
        targetSession: _targetSession(),
      );
      expect(clone.thumbnailsDirty, isFalse);
    });

    test('rawArchiveUploadedAt is null on the clone — cloud upload is '
        'per-id and must re-run', () async {
      final src = await _seedSourceExercise(); // rawArchiveUploadedAt set
      final clone = await cloneExerciseInto(
        source: src,
        targetSession: _targetSession(),
      );
      expect(clone.rawArchiveUploadedAt, isNull);
    });

    test('runtime URL fields (lineDrawingUrl / grayscaleUrl / originalUrl) '
        'are null on the clone', () async {
      final src = await _seedSourceExercise();
      final clone = await cloneExerciseInto(
        source: src,
        targetSession: _targetSession(),
      );
      expect(clone.lineDrawingUrl, isNull);
      expect(clone.grayscaleUrl, isNull);
      expect(clone.originalUrl, isNull);
    });
  });

  group('cloneExerciseInto — Strip matrix (session-structural)', () {
    test('circuitId is null on the clone regardless of source value',
        () async {
      final src = await _seedSourceExercise(); // circuitId = 'circuit-source-only'
      expect(src.circuitId, isNotNull, reason: 'fixture sanity');

      final clone = await cloneExerciseInto(
        source: src,
        targetSession: _targetSession(),
      );

      expect(clone.circuitId, isNull);
    });
  });

  group('cloneExerciseInto — per-set deep copy', () {
    test('clone sets have fresh UUIDs but preserve value-identity fields',
        () async {
      final src = await _seedSourceExercise();
      final clone = await cloneExerciseInto(
        source: src,
        targetSession: _targetSession(),
      );

      expect(clone.sets, hasLength(src.sets.length));

      for (var i = 0; i < src.sets.length; i++) {
        final from = src.sets[i];
        final to = clone.sets[i];

        // Fresh per-set UUID.
        expect(
          to.id,
          isNot(from.id),
          reason: 'cloned set $i must have a fresh UUID',
        );
        expect(to.id, isNotEmpty);

        // Value identity preserved.
        expect(to.position, from.position);
        expect(to.reps, from.reps);
        expect(to.holdSeconds, from.holdSeconds);
        expect(to.holdPosition, from.holdPosition);
        expect(to.weightKg, from.weightKg);
        expect(to.breatherSecondsAfter, from.breatherSecondsAfter);
      }
    });

    test('cloneSetsWithFreshIds — pure helper round-trip', () {
      // Exposed for tests via @visibleForTesting.
      final original = <ExerciseSet>[
        ExerciseSet.create(position: 1, reps: 8, holdSeconds: 0),
        ExerciseSet.create(position: 2, reps: 8, holdSeconds: 0),
      ];
      final cloned = cloneSetsWithFreshIds(original);

      expect(cloned, hasLength(original.length));
      for (var i = 0; i < original.length; i++) {
        expect(cloned[i].id, isNot(original[i].id));
        expect(cloned[i].position, original[i].position);
        expect(cloned[i].reps, original[i].reps);
      }
    });
  });

  group('cloneExerciseInto — file IO', () {
    test('per-treatment thumbnail variants are copied with new exercise id',
        () async {
      final src = await _seedSourceExercise(id: 'src-thumb-variant-test');
      final clone = await cloneExerciseInto(
        source: src,
        targetSession: _targetSession(),
      );

      // Variants under {docs}/thumbnails/{id}_thumb_*.jpg should exist
      // for the new id.
      final docs = _tempDocsDir.path;
      for (final suffix in ['_thumb_color.jpg', '_thumb_line.jpg', '_thumb_bw.jpg']) {
        final dest = File(p.join(docs, 'thumbnails', '${clone.id}$suffix'));
        expect(
          dest.existsSync(),
          isTrue,
          reason: 'expected thumbnail variant $suffix to be copied to ${dest.path}',
        );
      }
    });

    test('source files are copied (not moved) — source still exists',
        () async {
      final src = await _seedSourceExercise();
      final clone = await cloneExerciseInto(
        source: src,
        targetSession: _targetSession(),
      );

      // Source raw still exists.
      final srcAbs = p.join(_tempDocsDir.path, src.rawFilePath);
      expect(File(srcAbs).existsSync(), isTrue);

      // Clone raw exists at a different path (id swapped).
      final cloneRaw = clone.rawFilePath;
      expect(cloneRaw, isNot(src.rawFilePath));
      final cloneAbs = p.join(_tempDocsDir.path, cloneRaw);
      expect(File(cloneAbs).existsSync(), isTrue);
    });

    test('missing source files do not crash; clone proceeds best-effort',
        () async {
      // Build a source row that references a relative path with no
      // backing file. _copyExerciseFile returns null for non-existent
      // sources; the row should still be minted.
      final src = ExerciseCapture(
        id: 'src-missing-files',
        position: 0,
        rawFilePath: 'raw/does-not-exist.mp4',
        mediaType: MediaType.video,
        createdAt: DateTime.now(),
        sessionId: 'src-session',
      );
      final clone = await cloneExerciseInto(
        source: src,
        targetSession: _targetSession(),
      );

      // Identity reset happened.
      expect(clone.id, isNot(src.id));
      // rawFilePath fell back to the source's path per the
      // implementation (`newRawFilePath ?? source.rawFilePath`).
      expect(clone.rawFilePath, src.rawFilePath);
      expect(clone.convertedFilePath, isNull);
      expect(clone.thumbnailPath, isNull);
      expect(clone.archiveFilePath, isNull);
    });
  });
}
