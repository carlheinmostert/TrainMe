// Tests for PendingOp serialisation / deserialisation.
//
// Covers:
//   1. Round-trip: every PendingOpType serialises to the correct wire string
//      and deserialises back to the original enum value.
//   2. Payload JSON round-trip.
//   3. Unknown op_type in fromMap — must NOT default silently; the
//      lastError field must be stamped so the drain layer can surface it.
//   4. Malformed payload JSON falls back to empty map without throwing.
//   5. Factory helpers produce the correct type + payload shape.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:raidme/models/pending_op.dart';

void main() {
  group('PendingOpType wire encoding round-trip', () {
    final knownTypes = {
      PendingOpType.upsertClient: 'upsert_client',
      PendingOpType.renameClient: 'rename_client',
      PendingOpType.setConsent: 'set_consent',
      PendingOpType.deleteClient: 'delete_client',
      PendingOpType.restoreClient: 'restore_client',
      PendingOpType.setExerciseDefault: 'set_exercise_default',
      PendingOpType.setAvatar: 'set_avatar',
      PendingOpType.renameSession: 'rename_session',
    };

    for (final entry in knownTypes.entries) {
      test('${entry.key} serialises to "${entry.value}" and round-trips', () {
        final op = PendingOp(
          id: 'op-${entry.key.name}',
          type: entry.key,
          payload: const {'test': true},
          createdAt: 1000,
        );
        final map = op.toMap();
        expect(map['op_type'], entry.value);

        final restored = PendingOp.fromMap({
          ...map,
          'payload': map['payload'],
        });
        expect(restored.type, entry.key);
      });
    }
  });

  group('PendingOp.fromMap', () {
    Map<String, dynamic> _baseRow({
      String opType = 'upsert_client',
      String payload = '{"client_id":"abc"}',
    }) {
      return {
        'id': 'op-1',
        'op_type': opType,
        'payload': payload,
        'created_at': 1_000_000,
        'attempts': 2,
        'last_attempt_at': 999_000,
        'last_error': null,
      };
    }

    test('deserialises a well-formed row', () {
      final op = PendingOp.fromMap(_baseRow());
      expect(op.id, 'op-1');
      expect(op.type, PendingOpType.upsertClient);
      expect(op.payload['client_id'], 'abc');
      expect(op.attempts, 2);
      expect(op.lastAttemptAt, 999_000);
      expect(op.lastError, isNull);
    });

    test('malformed payload JSON falls back to empty map', () {
      final op = PendingOp.fromMap(_baseRow(payload: 'NOT_JSON'));
      expect(op.payload, isEmpty);
    });

    test('missing payload defaults to empty map', () {
      final row = _baseRow()..remove('payload');
      row['payload'] = null;
      final op = PendingOp.fromMap(row);
      expect(op.payload, isEmpty);
    });

    test('unknown op_type stamps lastError instead of silent misroute', () {
      final op = PendingOp.fromMap(_baseRow(opType: 'future_unknown_op'));
      // Must not silently default to upsertClient without a trace.
      // The lastError field must carry the unknown-type marker so the
      // sync drain can skip or surface this op.
      expect(
        op.lastError,
        contains('future_unknown_op'),
        reason: 'lastError must identify the unknown op type',
      );
    });

    test('missing attempts defaults to 0', () {
      final row = _baseRow();
      row.remove('attempts');
      final op = PendingOp.fromMap(row);
      expect(op.attempts, 0);
    });

    test('payload round-trips nested JSON correctly', () {
      final payload = {'client_id': 'abc', 'extra': 123, 'nested': null};
      final row = _baseRow(payload: jsonEncode(payload));
      final op = PendingOp.fromMap(row);
      expect(op.payload['client_id'], 'abc');
      expect(op.payload['extra'], 123);
      expect(op.payload.containsKey('nested'), isTrue);
    });
  });

  group('PendingOp.toMap', () {
    test('toMap produces a valid re-hydrate-able map', () {
      final original = PendingOp(
        id: 'op-2',
        type: PendingOpType.setConsent,
        payload: {'client_id': 'xyz', 'grayscale_allowed': true},
        createdAt: 2_000_000,
        attempts: 1,
        lastAttemptAt: 1_999_000,
        lastError: 'timeout',
      );
      final map = original.toMap();
      final restored = PendingOp.fromMap(map);

      expect(restored.id, original.id);
      expect(restored.type, original.type);
      expect(restored.payload['client_id'], 'xyz');
      expect(restored.payload['grayscale_allowed'], true);
      expect(restored.attempts, 1);
      expect(restored.lastAttemptAt, 1_999_000);
      expect(restored.lastError, 'timeout');
    });
  });

  group('PendingOp factory helpers', () {
    const nowMs = 5_000_000;

    test('PendingOp.upsertClient produces correct type and payload', () {
      final op = PendingOp.upsertClient(
        opId: 'op-u',
        clientId: 'c1',
        practiceId: 'p1',
        name: 'Alice',
        nowMs: nowMs,
      );
      expect(op.type, PendingOpType.upsertClient);
      expect(op.payload['client_id'], 'c1');
      expect(op.payload['practice_id'], 'p1');
      expect(op.payload['name'], 'Alice');
    });

    test('PendingOp.setConsent with all fields', () {
      final op = PendingOp.setConsent(
        opId: 'op-s',
        clientId: 'c2',
        grayscaleAllowed: true,
        colourAllowed: false,
        avatarAllowed: true,
        analyticsAllowed: false,
        nowMs: nowMs,
      );
      expect(op.type, PendingOpType.setConsent);
      expect(op.payload['grayscale_allowed'], true);
      expect(op.payload['colour_allowed'], false);
      expect(op.payload['avatar_allowed'], true);
      expect(op.payload['analytics_allowed'], false);
    });

    test('PendingOp.setConsent without optional fields omits their keys', () {
      final op = PendingOp.setConsent(
        opId: 'op-s2',
        clientId: 'c3',
        grayscaleAllowed: true,
        colourAllowed: true,
        nowMs: nowMs,
      );
      expect(op.payload.containsKey('avatar_allowed'), isFalse);
      expect(op.payload.containsKey('analytics_allowed'), isFalse);
    });

    test('PendingOp.deleteClient produces correct type', () {
      final op = PendingOp.deleteClient(
        opId: 'op-d',
        clientId: 'c4',
        nowMs: nowMs,
      );
      expect(op.type, PendingOpType.deleteClient);
      expect(op.payload['client_id'], 'c4');
    });

    test('PendingOp.renameSession produces correct type', () {
      final op = PendingOp.renameSession(
        opId: 'op-r',
        planId: 'plan-1',
        newTitle: 'Updated Title',
        nowMs: nowMs,
      );
      expect(op.type, PendingOpType.renameSession);
      expect(op.payload['plan_id'], 'plan-1');
      expect(op.payload['new_title'], 'Updated Title');
    });

    test('PendingOp.setAvatar with null avatarPath serialises null key', () {
      final op = PendingOp.setAvatar(
        opId: 'op-av',
        clientId: 'c5',
        avatarPath: null,
        nowMs: nowMs,
      );
      expect(op.type, PendingOpType.setAvatar);
      expect(op.payload.containsKey('avatar_path'), isTrue);
      expect(op.payload['avatar_path'], isNull);
    });
  });

  group('PendingOp.copyWith', () {
    test('copies with updated attempts', () {
      final op = PendingOp(
        id: 'op-c',
        type: PendingOpType.renameClient,
        payload: const {},
        createdAt: 1000,
        attempts: 0,
      );
      final updated = op.copyWith(attempts: 3, lastError: 'rpc_timeout');
      expect(updated.attempts, 3);
      expect(updated.lastError, 'rpc_timeout');
      expect(updated.id, op.id);
      expect(updated.type, op.type);
      expect(updated.createdAt, op.createdAt);
    });
  });
}
