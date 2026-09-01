// Tests for PendingOp serialisation safety.
//
// Key regression: `_opTypeFromWire` previously had a `default: return null`
// branch, and `PendingOp.fromMap` silently fell back to
// `PendingOpType.upsertClient` when the wire value was unrecognised. This
// caused silent data corruption: an op written by a newer version (or a
// future enum variant) would be replayed as an `upsertClient` with an
// unrelated payload, potentially creating spurious client records.
//
// Fix: `fromMap` now throws `ArgumentError` on an unknown op_type, and
// `LocalStorageService.getPendingOps` skips + logs unrecognised rows
// rather than crashing the entire queue.

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:raidme/models/pending_op.dart';
import 'package:raidme/services/local_storage_service.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  group('PendingOp.fromMap', () {
    Map<String, dynamic> _baseRow({
      String id = 'op-1',
      String opType = 'upsert_client',
      String payload = '{"client_id":"c1","practice_id":"p1","name":"Alice"}',
      int createdAt = 1_000_000,
    }) {
      return <String, dynamic>{
        'id': id,
        'op_type': opType,
        'payload': payload,
        'created_at': createdAt,
        'attempts': 0,
        'last_attempt_at': null,
        'last_error': null,
      };
    }

    test('deserialises all known op types without error', () {
      const knownTypes = <String>[
        'upsert_client',
        'rename_client',
        'set_consent',
        'delete_client',
        'restore_client',
        'set_exercise_default',
        'set_avatar',
        'rename_session',
      ];
      for (final wireType in knownTypes) {
        expect(
          () => PendingOp.fromMap(_baseRow(opType: wireType, payload: '{}')),
          returnsNormally,
          reason: 'op_type "$wireType" should deserialise without error',
        );
      }
    });

    test('throws ArgumentError for an unknown op_type', () {
      expect(
        () => PendingOp.fromMap(_baseRow(opType: 'future_unknown_op')),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.invalidValue,
            'invalidValue',
            'future_unknown_op',
          ),
        ),
        reason: 'An unrecognised op_type must throw rather than silently '
            'default to upsertClient',
      );
    });

    test('throws ArgumentError for an empty op_type string', () {
      expect(
        () => PendingOp.fromMap(_baseRow(opType: '')),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('round-trips a known op through toMap → fromMap', () {
      final original = PendingOp.renameClient(
        opId: 'op-42',
        clientId: 'c-abc',
        newName: 'Bob',
        nowMs: 12345,
      );
      final row = original.toMap();
      final restored = PendingOp.fromMap(
        // toMap returns Object? values; fromMap expects dynamic values.
        row.map((k, v) => MapEntry(k, v)),
      );
      expect(restored.id, original.id);
      expect(restored.type, original.type);
      expect(restored.payload, original.payload);
      expect(restored.createdAt, original.createdAt);
    });
  });

  group('LocalStorageService.getPendingOps — unknown type resilience', () {
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

    test('skips unrecognised op_type rows, returns only valid ops', () async {
      // Insert a valid op directly into the DB.
      final validOp = PendingOp.upsertClient(
        opId: 'op-valid',
        clientId: 'c-1',
        practiceId: 'p-1',
        name: 'Carol',
        nowMs: 1_000,
      );
      await storage.enqueuePendingOp(validOp);

      // Insert a corrupt row with an unknown op_type (simulates a row
      // written by a future app version that added a new enum variant).
      await storage.db.rawInsert(
        '''INSERT INTO pending_ops
           (id, op_type, payload, created_at, attempts, last_attempt_at, last_error)
           VALUES (?, ?, ?, ?, ?, ?, ?)''',
        ['op-corrupt', 'future_unknown_op', '{}', 2_000, 0, null, null],
      );

      final ops = await storage.getPendingOps();

      expect(
        ops,
        hasLength(1),
        reason: 'The corrupt row must be silently skipped',
      );
      expect(ops.single.id, 'op-valid');
      expect(ops.single.type, PendingOpType.upsertClient);
    });

    test('returns empty list when all rows have unrecognised types', () async {
      await storage.db.rawInsert(
        '''INSERT INTO pending_ops
           (id, op_type, payload, created_at, attempts, last_attempt_at, last_error)
           VALUES (?, ?, ?, ?, ?, ?, ?)''',
        ['op-a', 'ghost_op_type_a', '{}', 1_000, 0, null, null],
      );
      await storage.db.rawInsert(
        '''INSERT INTO pending_ops
           (id, op_type, payload, created_at, attempts, last_attempt_at, last_error)
           VALUES (?, ?, ?, ?, ?, ?, ?)''',
        ['op-b', 'ghost_op_type_b', '{}', 2_000, 0, null, null],
      );

      final ops = await storage.getPendingOps();
      expect(ops, isEmpty);
    });
  });
}
