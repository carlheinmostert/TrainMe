// Pure-model unit tests — no Flutter framework, no SQLite, no network.
//
// Covers:
//   - PendingOp serialization round-trips for all 8 op types
//   - Session computed properties and copyWith (incl. new clearTitle)
//   - ExerciseCapture.estimatedDurationSeconds for all three HoldPosition modes
//   - ExerciseSet equality, sentinel copyWith, fromMap round-trip
//   - HoldPosition.fromWire edge cases
//   - StickyDefaults.prefillCapture and applyGlobalCaptureDefaults

import 'package:flutter_test/flutter_test.dart';

import 'package:raidme/models/exercise_capture.dart';
import 'package:raidme/models/exercise_set.dart';
import 'package:raidme/models/pending_op.dart';
import 'package:raidme/models/session.dart';
import 'package:raidme/models/treatment.dart';
import 'package:raidme/services/sticky_defaults.dart';

void main() {
  // ---------------------------------------------------------------------------
  // PendingOp — serialization round-trips
  // ---------------------------------------------------------------------------

  group('PendingOp.toMap / fromMap round-trip', () {
    test('upsertClient preserves type and payload', () {
      final op = PendingOp.upsertClient(
        opId: 'op-1',
        clientId: 'client-1',
        practiceId: 'practice-1',
        name: 'Alice',
        nowMs: 1000000,
      );
      final restored = PendingOp.fromMap(op.toMap());

      expect(restored.id, op.id);
      expect(restored.type, PendingOpType.upsertClient);
      expect(restored.payload['client_id'], 'client-1');
      expect(restored.payload['practice_id'], 'practice-1');
      expect(restored.payload['name'], 'Alice');
      expect(restored.createdAt, 1000000);
    });

    test('renameClient round-trips', () {
      final op = PendingOp.renameClient(
        opId: 'op-2',
        clientId: 'client-2',
        newName: 'Bob',
        nowMs: 2000000,
      );
      final restored = PendingOp.fromMap(op.toMap());
      expect(restored.type, PendingOpType.renameClient);
      expect(restored.payload['new_name'], 'Bob');
    });

    test('setConsent round-trips — all four boolean fields', () {
      final op = PendingOp.setConsent(
        opId: 'op-3',
        clientId: 'client-3',
        grayscaleAllowed: true,
        colourAllowed: false,
        avatarAllowed: true,
        analyticsAllowed: false,
        nowMs: 3000000,
      );
      final restored = PendingOp.fromMap(op.toMap());
      expect(restored.type, PendingOpType.setConsent);
      expect(restored.payload['grayscale_allowed'], isTrue);
      expect(restored.payload['colour_allowed'], isFalse);
      expect(restored.payload['avatar_allowed'], isTrue);
      expect(restored.payload['analytics_allowed'], isFalse);
    });

    test('setConsent round-trips — optional fields absent when null', () {
      final op = PendingOp.setConsent(
        opId: 'op-3b',
        clientId: 'client-3b',
        grayscaleAllowed: true,
        colourAllowed: false,
        nowMs: 3500000,
      );
      final restored = PendingOp.fromMap(op.toMap());
      expect(restored.payload.containsKey('avatar_allowed'), isFalse);
      expect(restored.payload.containsKey('analytics_allowed'), isFalse);
    });

    test('deleteClient round-trips', () {
      final op = PendingOp.deleteClient(
        opId: 'op-4',
        clientId: 'client-4',
        nowMs: 4000000,
      );
      final restored = PendingOp.fromMap(op.toMap());
      expect(restored.type, PendingOpType.deleteClient);
      expect(restored.payload['client_id'], 'client-4');
    });

    test('restoreClient round-trips', () {
      final op = PendingOp.restoreClient(
        opId: 'op-5',
        clientId: 'client-5',
        nowMs: 5000000,
      );
      final restored = PendingOp.fromMap(op.toMap());
      expect(restored.type, PendingOpType.restoreClient);
      expect(restored.payload['client_id'], 'client-5');
    });

    test('setExerciseDefault round-trips with int value', () {
      final op = PendingOp.setExerciseDefault(
        opId: 'op-6',
        clientId: 'client-6',
        field: 'first_set_reps',
        value: 12,
        nowMs: 6000000,
      );
      final restored = PendingOp.fromMap(op.toMap());
      expect(restored.type, PendingOpType.setExerciseDefault);
      expect(restored.payload['field'], 'first_set_reps');
      expect(restored.payload['value'], 12);
    });

    test('setExerciseDefault round-trips with null value (explicit clear)', () {
      final op = PendingOp.setExerciseDefault(
        opId: 'op-7',
        clientId: 'client-7',
        field: 'first_set_weight_kg',
        value: null,
        nowMs: 7000000,
      );
      final restored = PendingOp.fromMap(op.toMap());
      expect(restored.payload['value'], isNull);
    });

    test('setAvatar round-trips — path present', () {
      final op = PendingOp.setAvatar(
        opId: 'op-8',
        clientId: 'client-8',
        avatarPath: 'practice/client/avatar.png',
        nowMs: 8000000,
      );
      final restored = PendingOp.fromMap(op.toMap());
      expect(restored.type, PendingOpType.setAvatar);
      expect(restored.payload['avatar_path'], 'practice/client/avatar.png');
    });

    test('setAvatar round-trips — null path (explicit clear)', () {
      final op = PendingOp.setAvatar(
        opId: 'op-9',
        clientId: 'client-9',
        avatarPath: null,
        nowMs: 9000000,
      );
      final restored = PendingOp.fromMap(op.toMap());
      // Key must be present with an explicit null — distinguishes clear from absent.
      expect(restored.payload.containsKey('avatar_path'), isTrue);
      expect(restored.payload['avatar_path'], isNull);
    });

    test('renameSession round-trips', () {
      final op = PendingOp.renameSession(
        opId: 'op-10',
        planId: 'plan-10',
        newTitle: 'My New Title',
        nowMs: 10000000,
      );
      final restored = PendingOp.fromMap(op.toMap());
      expect(restored.type, PendingOpType.renameSession);
      expect(restored.payload['plan_id'], 'plan-10');
      expect(restored.payload['new_title'], 'My New Title');
    });

    test('fromMap — malformed payload JSON yields empty map, no throw', () {
      final row = <String, dynamic>{
        'id': 'op-bad',
        'op_type': 'upsert_client',
        'payload': '{not valid json',
        'created_at': 1000,
        'attempts': 0,
      };
      expect(() => PendingOp.fromMap(row), returnsNormally);
      final op = PendingOp.fromMap(row);
      expect(op.payload, isEmpty);
    });

    test('copyWith preserves all fields and overrides selected ones', () {
      final op = PendingOp.upsertClient(
        opId: 'op-cw',
        clientId: 'c',
        practiceId: 'p',
        name: 'Carl',
        nowMs: 100,
      );
      final updated = op.copyWith(attempts: 3, lastError: 'timeout');
      expect(updated.id, op.id);
      expect(updated.type, op.type);
      expect(updated.attempts, 3);
      expect(updated.lastError, 'timeout');
      expect(updated.payload, op.payload);
      expect(updated.createdAt, op.createdAt);
    });
  });

  // ---------------------------------------------------------------------------
  // Session — computed properties
  // ---------------------------------------------------------------------------

  group('Session.hasUnpublishedContentChanges', () {
    final baseCreatedAt = DateTime(2025, 1, 1);

    test('unpublished session is always false', () {
      final s = Session(
        id: 's1',
        clientName: 'Alice',
        createdAt: baseCreatedAt,
      );
      expect(s.hasUnpublishedContentChanges, isFalse);
    });

    test('published with null lastContentEditAt is clean (legacy rows)', () {
      final s = Session(
        id: 's2',
        clientName: 'Alice',
        createdAt: baseCreatedAt,
        sentAt: DateTime(2025, 6, 1),
        planUrl: 'https://example.com/p/uuid',
        version: 1,
      );
      expect(s.hasUnpublishedContentChanges, isFalse);
    });

    test('published — edit BEFORE sentAt is clean', () {
      final sentAt = DateTime(2025, 6, 1, 12);
      final s = Session(
        id: 's3',
        clientName: 'Alice',
        createdAt: baseCreatedAt,
        sentAt: sentAt,
        planUrl: 'https://example.com/p/uuid',
        version: 1,
        lastContentEditAt: DateTime(2025, 6, 1, 10),
      );
      expect(s.hasUnpublishedContentChanges, isFalse);
    });

    test('published — edit AFTER sentAt is dirty', () {
      final sentAt = DateTime(2025, 6, 1, 12);
      final s = Session(
        id: 's4',
        clientName: 'Alice',
        createdAt: baseCreatedAt,
        sentAt: sentAt,
        planUrl: 'https://example.com/p/uuid',
        version: 1,
        lastContentEditAt: DateTime(2025, 6, 1, 14),
      );
      expect(s.hasUnpublishedContentChanges, isTrue);
    });

    test('published — null sentAt with non-null edit is dirty', () {
      final s = Session(
        id: 's5',
        clientName: 'Alice',
        createdAt: baseCreatedAt,
        planUrl: 'https://example.com/p/uuid',
        version: 1,
        lastContentEditAt: DateTime(2025, 6, 2),
      );
      expect(s.hasUnpublishedContentChanges, isTrue);
    });
  });

  group('Session.displayTitle', () {
    test('returns explicit title when set', () {
      final s = Session(
        id: 's1',
        clientName: 'Alice',
        createdAt: DateTime.now(),
        title: 'Custom Title',
      );
      expect(s.displayTitle, 'Custom Title');
    });

    test('falls back to clientName when title is null', () {
      final s = Session(
        id: 's2',
        clientName: 'Bob',
        createdAt: DateTime.now(),
      );
      expect(s.displayTitle, 'Session for Bob');
    });
  });

  group('Session.copyWith clearTitle', () {
    test('clearTitle: true nulls out an existing title', () {
      final s = Session(
        id: 's1',
        clientName: 'Alice',
        createdAt: DateTime.now(),
        title: 'Original Title',
      );
      final cleared = s.copyWith(clearTitle: true);
      expect(cleared.title, isNull);
      expect(cleared.displayTitle, 'Session for Alice');
    });

    test('clearTitle: false with no title arg preserves existing title', () {
      final s = Session(
        id: 's1',
        clientName: 'Alice',
        createdAt: DateTime.now(),
        title: 'Kept Title',
      );
      final same = s.copyWith();
      expect(same.title, 'Kept Title');
    });

    test('setting title via copyWith works', () {
      final s = Session(
        id: 's1',
        clientName: 'Alice',
        createdAt: DateTime.now(),
      );
      final updated = s.copyWith(title: 'New Title');
      expect(updated.title, 'New Title');
    });
  });

  group('Session circuit helpers', () {
    test('getCircuitCycles returns 3 by default', () {
      final s = Session(
        id: 's1',
        clientName: 'Alice',
        createdAt: DateTime.now(),
      );
      expect(s.getCircuitCycles('unknown'), 3);
    });

    test('setCircuitCycles clamps to 1..5', () {
      final s = Session(
        id: 's1',
        clientName: 'Alice',
        createdAt: DateTime.now(),
      );
      expect(s.setCircuitCycles('c', 0).getCircuitCycles('c'), 1);
      expect(s.setCircuitCycles('c', 6).getCircuitCycles('c'), 5);
      expect(s.setCircuitCycles('c', 3).getCircuitCycles('c'), 3);
    });

    test('getCircuitName returns null for missing/empty entry', () {
      final s = Session(
        id: 's1',
        clientName: 'Alice',
        createdAt: DateTime.now(),
      );
      expect(s.getCircuitName('missing'), isNull);
    });

    test('setCircuitName stores name, removing whitespace-only clears it', () {
      final s = Session(
        id: 's1',
        clientName: 'Alice',
        createdAt: DateTime.now(),
      );
      final named = s.setCircuitName('c1', 'Legs');
      expect(named.getCircuitName('c1'), 'Legs');

      final cleared = named.setCircuitName('c1', '   ');
      expect(cleared.getCircuitName('c1'), isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // ExerciseCapture — estimatedDurationSeconds (HoldPosition modes)
  // ---------------------------------------------------------------------------

  group('ExerciseCapture.estimatedDurationSeconds', () {
    ExerciseCapture makeVideo({
      required List<ExerciseSet> sets,
      int? videoDurationMs,
      int? videoRepsPerLoop,
    }) {
      return ExerciseCapture(
        id: 'ex-dur',
        position: 0,
        rawFilePath: 'raw/x.mp4',
        mediaType: MediaType.video,
        createdAt: DateTime.now(),
        sets: sets,
        videoDurationMs: videoDurationMs,
        videoRepsPerLoop: videoRepsPerLoop,
      );
    }

    test('rest returns restHoldSeconds', () {
      final rest = ExerciseCapture(
        id: 'r1',
        position: 0,
        rawFilePath: '',
        mediaType: MediaType.rest,
        createdAt: DateTime.now(),
        restHoldSeconds: 45,
      );
      expect(rest.estimatedDurationSeconds, 45);
    });

    test('empty sets list returns 0', () {
      expect(makeVideo(sets: []).estimatedDurationSeconds, 0);
    });

    test('HoldPosition.perRep — hold multiplied per rep', () {
      // videoDurationMs=10000, videoRepsPerLoop=5 → perRep = 2s
      // set: reps=5, hold=3s perRep, breather=0
      // total = 5*2 + 5*3 + 0 = 25
      final set = ExerciseSet.create(
        position: 1,
        reps: 5,
        holdSeconds: 3,
        holdPosition: HoldPosition.perRep,
        breatherSecondsAfter: 0,
      );
      final ex = makeVideo(
        sets: [set],
        videoDurationMs: 10000,
        videoRepsPerLoop: 5,
      );
      expect(ex.estimatedDurationSeconds, 25);
    });

    test('HoldPosition.endOfSet — hold applied once regardless of reps', () {
      // perRep = 10000/1000 / 5 = 2s
      // set: reps=5, hold=10s endOfSet, breather=0
      // total = 5*2 + 1*10 + 0 = 20
      final set = ExerciseSet.create(
        position: 1,
        reps: 5,
        holdSeconds: 10,
        holdPosition: HoldPosition.endOfSet,
        breatherSecondsAfter: 0,
      );
      final ex = makeVideo(
        sets: [set],
        videoDurationMs: 10000,
        videoRepsPerLoop: 5,
      );
      expect(ex.estimatedDurationSeconds, 20);
    });

    test('HoldPosition.endOfExercise — hold only on last set', () {
      // perRep = 2s, reps=5, hold=10s endOfExercise, breather=0
      // set1 (not last): 5*2 + 0 + 0 = 10
      // set2 (last):     5*2 + 10 + 0 = 20
      // total = 30
      final set1 = ExerciseSet.create(
        position: 1,
        reps: 5,
        holdSeconds: 10,
        holdPosition: HoldPosition.endOfExercise,
        breatherSecondsAfter: 0,
      );
      final set2 = ExerciseSet.create(
        position: 2,
        reps: 5,
        holdSeconds: 10,
        holdPosition: HoldPosition.endOfExercise,
        breatherSecondsAfter: 0,
      );
      final ex = makeVideo(
        sets: [set1, set2],
        videoDurationMs: 10000,
        videoRepsPerLoop: 5,
      );
      expect(ex.estimatedDurationSeconds, 30);
    });

    test('breather is summed per set', () {
      // perRep = 6000/1000 / 3 = 2s
      // set: reps=3, hold=0, breather=15
      // total = 3*2 + 0 + 15 = 21
      final set = ExerciseSet.create(
        position: 1,
        reps: 3,
        holdSeconds: 0,
        holdPosition: HoldPosition.endOfSet,
        breatherSecondsAfter: 15,
      );
      final ex = makeVideo(
        sets: [set],
        videoDurationMs: 6000,
        videoRepsPerLoop: 3,
      );
      expect(ex.estimatedDurationSeconds, 21);
    });

    test('multiple sets are summed', () {
      // perRep = 2s (10000ms / 5)
      // set1: reps=5, hold=0 endOfSet, breather=10 → 5*2+0+10 = 20
      // set2: reps=5, hold=0 endOfSet, breather=10 → 5*2+0+10 = 20
      // total = 40
      final set1 = ExerciseSet.create(
        position: 1, reps: 5, holdSeconds: 0,
        holdPosition: HoldPosition.endOfSet, breatherSecondsAfter: 10,
      );
      final set2 = ExerciseSet.create(
        position: 2, reps: 5, holdSeconds: 0,
        holdPosition: HoldPosition.endOfSet, breatherSecondsAfter: 10,
      );
      final ex = makeVideo(
        sets: [set1, set2],
        videoDurationMs: 10000,
        videoRepsPerLoop: 5,
      );
      expect(ex.estimatedDurationSeconds, 40);
    });
  });

  // ---------------------------------------------------------------------------
  // ExerciseSet
  // ---------------------------------------------------------------------------

  group('ExerciseSet', () {
    test('equality uses all fields', () {
      final a = ExerciseSet.create(position: 1, reps: 10, holdSeconds: 5);
      final b = a.copyWith(reps: 11);
      expect(a == b, isFalse);
      expect(a == a.copyWith(), isTrue);
    });

    test('copyWith with explicit null weightKg clears it', () {
      final set = ExerciseSet.create(position: 1, reps: 10, weightKg: 20.0);
      final cleared = set.copyWith(weightKg: null);
      expect(cleared.weightKg, isNull);
    });

    test('copyWith without weightKg preserves existing value', () {
      final set = ExerciseSet.create(position: 1, reps: 10, weightKg: 20.0);
      final updated = set.copyWith(reps: 12);
      expect(updated.weightKg, 20.0);
    });

    test('HoldPosition.fromWire — known values', () {
      expect(HoldPosition.fromWire('per_rep'), HoldPosition.perRep);
      expect(HoldPosition.fromWire('end_of_set'), HoldPosition.endOfSet);
      expect(HoldPosition.fromWire('end_of_exercise'), HoldPosition.endOfExercise);
    });

    test('HoldPosition.fromWire — null defaults to endOfSet', () {
      expect(HoldPosition.fromWire(null), HoldPosition.endOfSet);
    });

    test('HoldPosition.fromWire — unknown string defaults to endOfSet', () {
      expect(HoldPosition.fromWire('unknown_value'), HoldPosition.endOfSet);
    });

    test('fromMap / toMap round-trip preserves all fields', () {
      final original = ExerciseSet.create(
        position: 2,
        reps: 8,
        holdSeconds: 5,
        holdPosition: HoldPosition.perRep,
        weightKg: 15.5,
        breatherSecondsAfter: 45,
      );
      final map = <String, dynamic>{
        'id': original.id,
        'position': original.position,
        'reps': original.reps,
        'hold_seconds': original.holdSeconds,
        'hold_position': original.holdPosition.wireValue,
        'weight_kg': original.weightKg,
        'breather_seconds_after': original.breatherSecondsAfter,
      };
      final restored = ExerciseSet.fromMap(map);
      expect(restored.position, original.position);
      expect(restored.reps, original.reps);
      expect(restored.holdSeconds, original.holdSeconds);
      expect(restored.holdPosition, original.holdPosition);
      expect(restored.weightKg, original.weightKg);
      expect(restored.breatherSecondsAfter, original.breatherSecondsAfter);
    });

    test('fromMap — null numeric fields use defaults', () {
      final map = <String, dynamic>{
        'id': 'set-null',
        'position': 1,
        'reps': 10,
        'hold_seconds': null,
        'hold_position': null,
        'weight_kg': null,
        'breather_seconds_after': null,
      };
      final set = ExerciseSet.fromMap(map);
      expect(set.holdSeconds, 0);
      expect(set.holdPosition, HoldPosition.endOfSet);
      expect(set.weightKg, isNull);
      expect(set.breatherSecondsAfter, 60); // fromMap default (stored rows)
    });
  });

  // ---------------------------------------------------------------------------
  // StickyDefaults.prefillCapture
  // ---------------------------------------------------------------------------

  group('StickyDefaults.prefillCapture', () {
    setUp(StickyDefaults.resetOverlay);

    ExerciseCapture seedCapture() {
      return ExerciseCapture(
        id: 'ex-pf',
        position: 0,
        rawFilePath: 'raw/x.mp4',
        mediaType: MediaType.video,
        createdAt: DateTime.now(),
        sets: <ExerciseSet>[
          ExerciseSet.create(
            position: 1,
            reps: 10,
            holdSeconds: 0,
            weightKg: null,
            breatherSecondsAfter: 30,
          ),
        ],
        videoRepsPerLoop: 3,
      );
    }

    test('rest period returned unchanged (identity)', () {
      final rest = ExerciseCapture(
        id: 'ex-rest',
        position: 0,
        rawFilePath: '',
        mediaType: MediaType.rest,
        restHoldSeconds: 60,
        createdAt: DateTime.now(),
      );
      final out = StickyDefaults.prefillCapture(rest, {'include_audio': true});
      expect(identical(out, rest), isTrue);
    });

    test('empty defaults returns exercise unchanged (identity)', () {
      final ex = seedCapture();
      final out = StickyDefaults.prefillCapture(ex, {});
      expect(identical(out, ex), isTrue);
    });

    test('fills first-set reps from sticky default (synthetic seed)', () {
      final out = StickyDefaults.prefillCapture(
        seedCapture(),
        {'first_set_reps': 12},
      );
      expect(out.sets.first.reps, 12);
    });

    test('does not touch first set when it is not a synthetic seed', () {
      // Reps=6 is not the synthetic default (10) — should NOT be overwritten.
      final ex = ExerciseCapture(
        id: 'ex-authored',
        position: 0,
        rawFilePath: 'raw/x.mp4',
        mediaType: MediaType.video,
        createdAt: DateTime.now(),
        sets: <ExerciseSet>[
          ExerciseSet.create(
            position: 1,
            reps: 6,
            holdSeconds: 0,
            weightKg: null,
            breatherSecondsAfter: 30,
          ),
        ],
      );
      final out = StickyDefaults.prefillCapture(ex, {'first_set_reps': 12});
      expect(out.sets.first.reps, 6);
    });

    test('fills prepSeconds when null on exercise', () {
      final ex = seedCapture(); // prepSeconds is null
      final out = StickyDefaults.prefillCapture(ex, {'prep_seconds': 8});
      expect(out.prepSeconds, 8);
    });

    test('does not overwrite prepSeconds when already set on exercise', () {
      final ex = seedCapture().copyWith(prepSeconds: 5);
      final out = StickyDefaults.prefillCapture(ex, {'prep_seconds': 8});
      expect(out.prepSeconds, 5);
    });

    test('fills first-set weightKg from sticky default', () {
      final out = StickyDefaults.prefillCapture(
        seedCapture(),
        {'first_set_weight_kg': 25.0},
      );
      expect(out.sets.first.weightKg, 25.0);
    });

    test('fills first-set breatherSecondsAfter from sticky default', () {
      final out = StickyDefaults.prefillCapture(
        seedCapture(),
        {'first_set_breather_seconds': 45},
      );
      expect(out.sets.first.breatherSecondsAfter, 45);
    });

    test('no-op when no sticky first-set fields present', () {
      final ex = seedCapture();
      final out = StickyDefaults.prefillCapture(
        ex,
        {'prep_seconds': 5}, // only non-first-set field
      );
      expect(out.sets.first.reps, 10); // unchanged
    });
  });

  // ---------------------------------------------------------------------------
  // StickyDefaults.applyGlobalCaptureDefaults
  // ---------------------------------------------------------------------------

  group('StickyDefaults.applyGlobalCaptureDefaults', () {
    test('rest is returned unchanged (identity)', () {
      final rest = ExerciseCapture(
        id: 'r',
        position: 0,
        rawFilePath: '',
        mediaType: MediaType.rest,
        restHoldSeconds: 60,
        createdAt: DateTime.now(),
      );
      expect(identical(StickyDefaults.applyGlobalCaptureDefaults(rest), rest), isTrue);
    });

    test('new video capture gets preferredTreatment = grayscale', () {
      final ex = ExerciseCapture(
        id: 'ex-g',
        position: 0,
        rawFilePath: 'raw/x.mp4',
        mediaType: MediaType.video,
        createdAt: DateTime.now(),
      );
      final out = StickyDefaults.applyGlobalCaptureDefaults(ex);
      expect(out.preferredTreatment, Treatment.grayscale);
    });

    test('new video capture gets bodyFocus = false', () {
      final ex = ExerciseCapture(
        id: 'ex-bf',
        position: 0,
        rawFilePath: 'raw/x.mp4',
        mediaType: MediaType.video,
        createdAt: DateTime.now(),
      );
      final out = StickyDefaults.applyGlobalCaptureDefaults(ex);
      expect(out.bodyFocus, isFalse);
    });

    test('existing preferredTreatment is preserved', () {
      final ex = ExerciseCapture(
        id: 'ex-pt',
        position: 0,
        rawFilePath: 'raw/x.mp4',
        mediaType: MediaType.video,
        createdAt: DateTime.now(),
        preferredTreatment: Treatment.original,
      );
      final out = StickyDefaults.applyGlobalCaptureDefaults(ex);
      expect(out.preferredTreatment, Treatment.original);
    });

    test('existing bodyFocus = true is preserved', () {
      final ex = ExerciseCapture(
        id: 'ex-bft',
        position: 0,
        rawFilePath: 'raw/x.mp4',
        mediaType: MediaType.video,
        createdAt: DateTime.now(),
        bodyFocus: true,
      );
      final out = StickyDefaults.applyGlobalCaptureDefaults(ex);
      expect(out.bodyFocus, isTrue);
    });

    test('returns same instance when both fields already set', () {
      final ex = ExerciseCapture(
        id: 'ex-both',
        position: 0,
        rawFilePath: 'raw/x.mp4',
        mediaType: MediaType.video,
        createdAt: DateTime.now(),
        preferredTreatment: Treatment.line,
        bodyFocus: false,
      );
      final out = StickyDefaults.applyGlobalCaptureDefaults(ex);
      expect(identical(out, ex), isTrue);
    });
  });
}
