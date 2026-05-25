// FaceEmbeddingService dim-mismatch regression test.
//
// Self-trainer wave hotfix B — R5-M1 / M-5.
//
// The bug class: native MobileFaceNet returns a partial / wrong-size
// embedding (or our Dart unpacker reads the wrong number of floats —
// the same family of bug PR #489 fixed at the bytes-vs-floats layer).
// Pre-fix, `computeForImage` happily returned whatever the native side
// handed back — including a 100-element list — which downstream code
// then treated as a valid embedding, producing meaningless cosine
// similarities at verify time.
//
// Post-fix, the Dart wrapper asserts `result.length ==
// kSelfFaceEmbeddingFloats` (512) before returning the embedding to
// callers, and returns null when the dim doesn't match. This test
// drives the public surface via the platform channel mock and asserts
// that contract.
//
// Pairs with the iOS-side dim assertion at
// HomefitFaceEmbeddingChannel.swift `unpackFloats` (R5-L1).

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:raidme/services/face_embedding_service.dart';
import 'package:raidme/services/safe_mode.dart' show kSelfFaceEmbeddingFloats;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel selfFaceChannel = MethodChannel(
    'studio.homefit.face_embedding',
  );

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(selfFaceChannel, null);
  });

  group('FaceEmbeddingService.computeForImage dim contract', () {
    test('rejects a 100-element response and returns null', () async {
      // Mock a clearly-wrong-size return — 100 floats. The native side
      // should never emit this (MobileFaceNet always emits exactly 512)
      // but if it ever does we want loud failure, not a silent garbage
      // embedding leaking into verify.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(selfFaceChannel, (call) async {
        if (call.method == 'computeEmbeddingForImage') {
          return List<double>.filled(100, 0.5);
        }
        return null;
      });

      final result =
          await FaceEmbeddingService.instance.computeForImage('/tmp/x.jpg');
      expect(result, isNull,
          reason: 'A short embedding must be rejected, not returned.');
    });

    test('accepts the canonical 512-float response', () async {
      // Sanity twin — same mock pattern with the correct dim should
      // round-trip cleanly. Guards against an over-zealous future
      // refactor that rejects everything.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(selfFaceChannel, (call) async {
        if (call.method == 'computeEmbeddingForImage') {
          return List<double>.filled(kSelfFaceEmbeddingFloats, 0.5);
        }
        return null;
      });

      final result =
          await FaceEmbeddingService.instance.computeForImage('/tmp/x.jpg');
      expect(result, isNotNull);
      expect(result!.length, kSelfFaceEmbeddingFloats);
    });

    test('returns null on native nil (no face detected)', () async {
      // Canonical no-face response: native returns nil → Dart returns
      // null without throwing.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(selfFaceChannel, (call) async {
        if (call.method == 'computeEmbeddingForImage') {
          return null;
        }
        return null;
      });

      final result =
          await FaceEmbeddingService.instance.computeForImage('/tmp/x.jpg');
      expect(result, isNull);
    });
  });

  group('kSelfFaceEmbeddingFloats constant', () {
    test('equals 512 (MobileFaceNet output)', () {
      expect(kSelfFaceEmbeddingFloats, 512);
    });
  });
}
