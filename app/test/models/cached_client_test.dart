// Regression guard for CachedClient face-embedding decoder byte-length
// invariant (Safe Mode v2, 2026-05-25).
//
// A units bug shipped against the MobileFaceNet wire shape: the decoder
// rejected anything not exactly 512 bytes, but the actual embedding is
// 2048 bytes (512 floats x 4 bytes per float). Symptom: Capture screen
// surfaced the "Safe Mode needs to prepare a face fingerprint from the
// avatar" banner for clients whose cloud row already held a valid
// 2048-byte legacy embedding and / or a full multi-reference enrolment.
// Hydration via fromCloudJson AND fromMap (SQLite row) both silently
// returned null, FaceEmbeddingService never hydrated, the state machine
// resolved to needsEmbedding.
//
// These tests pin:
//   1. fromCloudJson accepts a hex-encoded 2048-byte payload (PostgREST
//      canonical bytea shape) and round-trips it.
//   2. fromCloudJson accepts a typed-list 2048-byte payload.
//   3. fromMap accepts a 2048-byte Uint8List from the SQLite row.
//   4. Decoder REJECTS the previous broken-state shape (512 bytes) so
//      a regression in the other direction is impossible.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:raidme/models/cached_client.dart';
import 'package:raidme/services/safe_mode.dart';

void main() {
  group('CachedClient.fromCloudJson face-embedding decoder', () {
    final canonicalBytes = Uint8List.fromList(
      List.generate(kFaceEmbeddingBytes, (i) => i % 256),
    );

    Map<String, dynamic> baseJson({Object? faceEmbedding}) {
      return <String, dynamic>{
        'id': 'client-test-1',
        'practice_id': 'practice-test-1',
        'name': 'Test Client',
        'video_consent': <String, dynamic>{
          'line_drawing': true,
          'grayscale': false,
          'original': false,
          'avatar': false,
          'analytics_allowed': true,
          'safe_mode_face_recognition': true,
        },
        'client_exercise_defaults': const <String, dynamic>{},
        'avatar_path': 'practice-test-1/client-test-1/avatar.png',
        'face_embedding': faceEmbedding,
        'face_embedding_model_version': 1,
      };
    }

    test('accepts canonical 2048-byte hex-encoded bytea payload', () {
      // PostgREST emits Postgres bytea as `\xDEADBEEF...`.
      final hex = StringBuffer(r'\x');
      for (final b in canonicalBytes) {
        hex.write(b.toRadixString(16).padLeft(2, '0'));
      }
      final cached = CachedClient.fromCloudJson(
        baseJson(faceEmbedding: hex.toString()),
        nowMs: 1700000000000,
      );

      expect(cached.faceEmbedding, isNotNull);
      expect(cached.faceEmbedding!.length, kFaceEmbeddingBytes);
      expect(cached.faceEmbedding, equals(canonicalBytes));
      expect(cached.faceEmbeddingModelVersion, 1);
    });

    test('accepts canonical 2048-byte base64-encoded bytea payload', () {
      final b64 = base64Encode(canonicalBytes);
      final cached = CachedClient.fromCloudJson(
        baseJson(faceEmbedding: b64),
        nowMs: 1700000000000,
      );

      expect(cached.faceEmbedding, isNotNull);
      expect(cached.faceEmbedding!.length, kFaceEmbeddingBytes);
      expect(cached.faceEmbedding, equals(canonicalBytes));
    });

    test('accepts canonical 2048-byte typed Uint8List payload', () {
      final cached = CachedClient.fromCloudJson(
        baseJson(faceEmbedding: canonicalBytes),
        nowMs: 1700000000000,
      );

      expect(cached.faceEmbedding, isNotNull);
      expect(cached.faceEmbedding!.length, kFaceEmbeddingBytes);
      expect(cached.faceEmbedding, equals(canonicalBytes));
    });

    test('accepts canonical 2048-byte List<int> payload', () {
      final cached = CachedClient.fromCloudJson(
        baseJson(faceEmbedding: canonicalBytes.toList()),
        nowMs: 1700000000000,
      );

      expect(cached.faceEmbedding, isNotNull);
      expect(cached.faceEmbedding!.length, kFaceEmbeddingBytes);
      expect(cached.faceEmbedding, equals(canonicalBytes));
    });

    test('rejects pre-fix broken 512-byte payload (regression guard)', () {
      final broken = Uint8List.fromList(List.generate(512, (i) => i % 256));
      final cached = CachedClient.fromCloudJson(
        baseJson(faceEmbedding: broken),
        nowMs: 1700000000000,
      );

      expect(
        cached.faceEmbedding,
        isNull,
        reason: 'The previous off-by-units bug accepted 512 bytes; '
            'after the fix the canonical shape is 2048 bytes only.',
      );
      expect(cached.faceEmbeddingModelVersion, isNull);
    });

    test('rejects null payload', () {
      final cached = CachedClient.fromCloudJson(
        baseJson(faceEmbedding: null),
        nowMs: 1700000000000,
      );

      expect(cached.faceEmbedding, isNull);
      expect(cached.faceEmbeddingModelVersion, isNull);
    });

    test('rejects empty string payload', () {
      final cached = CachedClient.fromCloudJson(
        baseJson(faceEmbedding: ''),
        nowMs: 1700000000000,
      );

      expect(cached.faceEmbedding, isNull);
    });
  });

  group('CachedClient.fromMap face-embedding decoder', () {
    final canonicalBytes = Uint8List.fromList(
      List.generate(kFaceEmbeddingBytes, (i) => i % 256),
    );

    Map<String, dynamic> baseRow({Object? faceEmbedding}) {
      return <String, dynamic>{
        'id': 'client-test-1',
        'practice_id': 'practice-test-1',
        'name': 'Test Client',
        'video_consent': jsonEncode(<String, dynamic>{
          'line_drawing': true,
          'grayscale': false,
          'original': false,
          'avatar': false,
          'analytics_allowed': true,
          'safe_mode_face_recognition': true,
        }),
        'client_exercise_defaults': '{}',
        'avatar_path': 'practice-test-1/client-test-1/avatar.png',
        'consent_confirmed_at': null,
        'consent_explicitly_set_at': null,
        'face_embedding': faceEmbedding,
        'face_embedding_model_version': 1,
        'synced_at': 1700000000000,
        'dirty': 0,
        'deleted': 0,
      };
    }

    test('accepts canonical 2048-byte Uint8List from SQLite row', () {
      final cached = CachedClient.fromMap(
        baseRow(faceEmbedding: canonicalBytes),
      );

      expect(cached.faceEmbedding, isNotNull);
      expect(cached.faceEmbedding!.length, kFaceEmbeddingBytes);
      expect(cached.faceEmbedding, equals(canonicalBytes));
      expect(cached.faceEmbeddingModelVersion, 1);
    });

    test('accepts canonical 2048-byte List<int> from SQLite row', () {
      final cached = CachedClient.fromMap(
        baseRow(faceEmbedding: canonicalBytes.toList()),
      );

      expect(cached.faceEmbedding, isNotNull);
      expect(cached.faceEmbedding!.length, kFaceEmbeddingBytes);
      expect(cached.faceEmbedding, equals(canonicalBytes));
    });

    test('rejects pre-fix broken 512-byte payload (regression guard)', () {
      final broken = Uint8List.fromList(List.generate(512, (i) => i % 256));
      final cached = CachedClient.fromMap(
        baseRow(faceEmbedding: broken),
      );

      expect(
        cached.faceEmbedding,
        isNull,
        reason: 'The previous off-by-units bug accepted 512 bytes; '
            'after the fix the canonical shape is 2048 bytes only.',
      );
      expect(cached.faceEmbeddingModelVersion, isNull);
    });

    test('rejects null payload', () {
      final cached = CachedClient.fromMap(
        baseRow(faceEmbedding: null),
      );

      expect(cached.faceEmbedding, isNull);
      expect(cached.faceEmbeddingModelVersion, isNull);
    });
  });

  group('kFaceEmbeddingBytes invariant', () {
    test('is 2048 (512 floats x 4 bytes per float)', () {
      // Pin the constant so a future "simplify" doesn't drop it back to
      // the float count. This is the load-bearing units invariant.
      expect(kFaceEmbeddingBytes, 2048);
      expect(kFaceEmbeddingBytes, 512 * 4);
    });
  });
}
