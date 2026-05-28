// Tests for Session.estimatedTotalDurationSeconds.
//
// This getter drives both credit pricing (1 credit ≤75min, 2 credits >75min)
// and the ETA widget. It contains non-trivial branching logic for:
//   - standalone exercises (delegates to ExerciseCapture.estimatedDurationSeconds)
//   - circuit groups (one-pass × cycles + inter-round rest)
//   - mixed standalone + circuit layouts
//   - empty sets lists (fallback estimate)
//   - rest period exercises
//
// These are pure unit tests with no database or Flutter dependency —
// run with `flutter test test/session_duration_test.dart`.

import 'package:flutter_test/flutter_test.dart';
import 'package:raidme/config.dart';
import 'package:raidme/models/exercise_capture.dart';
import 'package:raidme/models/exercise_set.dart';
import 'package:raidme/models/session.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

ExerciseCapture _videoExercise({
  required String id,
  required int position,
  List<ExerciseSet>? sets,
  int? videoDurationMs,
  int? videoRepsPerLoop,
  String? circuitId,
}) {
  final defaultSet = ExerciseSet.create(
    position: 1,
    reps: 10,
    holdSeconds: 0,
    weightKg: null,
    breatherSecondsAfter: 30,
  );
  return ExerciseCapture(
    id: id,
    position: position,
    rawFilePath: 'raw/$id.mp4',
    mediaType: MediaType.video,
    conversionStatus: ConversionStatus.done,
    sets: sets ?? [defaultSet],
    videoDurationMs: videoDurationMs,
    videoRepsPerLoop: videoRepsPerLoop ?? 3,
    circuitId: circuitId,
    createdAt: DateTime(2026, 1, 1),
  );
}

ExerciseCapture _restExercise({
  required String id,
  required int position,
  int durationSeconds = 30,
}) {
  return ExerciseCapture(
    id: id,
    position: position,
    rawFilePath: '',
    mediaType: MediaType.rest,
    conversionStatus: ConversionStatus.done,
    restHoldSeconds: durationSeconds,
    createdAt: DateTime(2026, 1, 1),
  );
}

Session _sessionWith(List<ExerciseCapture> exercises,
    {Map<String, int> circuitCycles = const {}}) {
  return Session(
    id: 'session-test',
    clientName: 'Test Client',
    exercises: exercises,
    createdAt: DateTime(2026, 1, 1),
    circuitCycles: circuitCycles,
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('Session.estimatedTotalDurationSeconds', () {
    test('empty exercises list returns 0', () {
      final session = _sessionWith([]);
      expect(session.estimatedTotalDurationSeconds, 0);
    });

    test('single standalone video without videoDurationMs uses secondsPerRep fallback', () {
      final ex = _videoExercise(
        id: 'ex1',
        position: 0,
        sets: [ExerciseSet.create(position: 1, reps: 10, breatherSecondsAfter: 30)],
        videoDurationMs: null,
      );
      final session = _sessionWith([ex]);
      // per-rep = AppConfig.secondsPerRep, total = 10 * perRep + 30
      final expected = 10 * AppConfig.secondsPerRep + 30;
      expect(session.estimatedTotalDurationSeconds, expected);
    });

    test('single standalone video with videoDurationMs calculates per-rep from duration', () {
      // 6000ms video, 3 reps per loop → 2s per rep
      final ex = _videoExercise(
        id: 'ex1',
        position: 0,
        sets: [ExerciseSet.create(position: 1, reps: 6, breatherSecondsAfter: 0)],
        videoDurationMs: 6000,
        videoRepsPerLoop: 3,
      );
      final session = _sessionWith([ex]);
      // perRep = (6000/1000) / 3 = 2s; total = 6 * 2 + 0 = 12
      expect(session.estimatedTotalDurationSeconds, 12);
    });

    test('multiple standalone exercises sum independently', () {
      final ex1 = _videoExercise(
        id: 'ex1',
        position: 0,
        sets: [ExerciseSet.create(position: 1, reps: 5, breatherSecondsAfter: 10)],
        videoDurationMs: 3000,
        videoRepsPerLoop: 3,
      );
      final ex2 = _videoExercise(
        id: 'ex2',
        position: 1,
        sets: [ExerciseSet.create(position: 1, reps: 5, breatherSecondsAfter: 10)],
        videoDurationMs: 3000,
        videoRepsPerLoop: 3,
      );
      final session = _sessionWith([ex1, ex2]);
      // Each: perRep = 1s, total per ex = 5*1 + 10 = 15; combined = 30
      expect(session.estimatedTotalDurationSeconds, 30);
    });

    test('rest period uses restHoldSeconds', () {
      final rest = _restExercise(id: 'r1', position: 0, durationSeconds: 60);
      final session = _sessionWith([rest]);
      expect(session.estimatedTotalDurationSeconds, 60);
    });

    test('rest period uses AppConfig.defaultRestDuration when restHoldSeconds is null', () {
      final rest = ExerciseCapture(
        id: 'r1',
        position: 0,
        rawFilePath: '',
        mediaType: MediaType.rest,
        conversionStatus: ConversionStatus.done,
        restHoldSeconds: null,
        createdAt: DateTime(2026, 1, 1),
      );
      final session = _sessionWith([rest]);
      expect(session.estimatedTotalDurationSeconds, AppConfig.defaultRestDuration);
    });

    test('circuit with 1 cycle equals one-pass duration', () {
      const circuitId = 'circuit-A';
      final ex1 = _videoExercise(
        id: 'ex1',
        position: 0,
        sets: [ExerciseSet.create(position: 1, reps: 5, breatherSecondsAfter: 10)],
        videoDurationMs: 3000,
        videoRepsPerLoop: 3,
        circuitId: circuitId,
      );
      final ex2 = _videoExercise(
        id: 'ex2',
        position: 1,
        sets: [ExerciseSet.create(position: 1, reps: 5, breatherSecondsAfter: 10)],
        videoDurationMs: 3000,
        videoRepsPerLoop: 3,
        circuitId: circuitId,
      );
      final session = _sessionWith([ex1, ex2], circuitCycles: {circuitId: 1});
      // oneRound = 2 * (5*1 + 10) = 30; cycles=1; interRound=0
      expect(session.estimatedTotalDurationSeconds, 30);
    });

    test('circuit with 3 cycles multiplies one-pass and adds inter-round rest', () {
      const circuitId = 'circuit-A';
      final ex1 = _videoExercise(
        id: 'ex1',
        position: 0,
        sets: [ExerciseSet.create(position: 1, reps: 5, breatherSecondsAfter: 10)],
        videoDurationMs: 3000,
        videoRepsPerLoop: 3,
        circuitId: circuitId,
      );
      final session = _sessionWith([ex1], circuitCycles: {circuitId: 3});
      // oneRound = 5*1 + 10 = 15; cycles=3; interRound = 2 * AppConfig.restBetweenCircuitRounds
      final expected = 15 * 3 + 2 * AppConfig.restBetweenCircuitRounds;
      expect(session.estimatedTotalDurationSeconds, expected);
    });

    test('circuit uses default 3 cycles when no circuitCycles entry', () {
      const circuitId = 'circuit-A';
      final ex1 = _videoExercise(
        id: 'ex1',
        position: 0,
        sets: [ExerciseSet.create(position: 1, reps: 5, breatherSecondsAfter: 10)],
        videoDurationMs: 3000,
        videoRepsPerLoop: 3,
        circuitId: circuitId,
      );
      // No circuitCycles entry → default is 3
      final session = _sessionWith([ex1], circuitCycles: {});
      final expected = (5 * 1 + 10) * 3 + 2 * AppConfig.restBetweenCircuitRounds;
      expect(session.estimatedTotalDurationSeconds, expected);
    });

    test('mixed standalone + circuit layout sums both correctly', () {
      const circuitId = 'circuit-B';
      final standalone = _videoExercise(
        id: 'ex-standalone',
        position: 0,
        sets: [ExerciseSet.create(position: 1, reps: 5, breatherSecondsAfter: 0)],
        videoDurationMs: 3000,
        videoRepsPerLoop: 3,
      );
      final circuitEx = _videoExercise(
        id: 'ex-circuit',
        position: 1,
        sets: [ExerciseSet.create(position: 1, reps: 5, breatherSecondsAfter: 0)],
        videoDurationMs: 3000,
        videoRepsPerLoop: 3,
        circuitId: circuitId,
      );
      final session = _sessionWith(
        [standalone, circuitEx],
        circuitCycles: {circuitId: 2},
      );
      // standalone: 5*1 = 5
      // circuit: oneRound=5, cycles=2, interRound = 1 * AppConfig.restBetweenCircuitRounds
      final expectedCircuit = 5 * 2 + 1 * AppConfig.restBetweenCircuitRounds;
      expect(session.estimatedTotalDurationSeconds, 5 + expectedCircuit);
    });

    test('circuit exercise with empty sets falls back to 10-rep baseline', () {
      const circuitId = 'circuit-C';
      final ex = ExerciseCapture(
        id: 'ex-empty',
        position: 0,
        rawFilePath: 'raw/x.mp4',
        mediaType: MediaType.video,
        conversionStatus: ConversionStatus.done,
        sets: const [],
        circuitId: circuitId,
        createdAt: DateTime(2026, 1, 1),
      );
      final session = _sessionWith([ex], circuitCycles: {circuitId: 2});
      // empty sets → fallback = 10 * AppConfig.secondsPerRep per round
      final oneRound = 10 * AppConfig.secondsPerRep;
      final expected = oneRound * 2 + 1 * AppConfig.restBetweenCircuitRounds;
      expect(session.estimatedTotalDurationSeconds, expected);
    });

    test('consecutive exercises in the SAME circuit are grouped', () {
      const circuitId = 'circuit-D';
      final ex1 = _videoExercise(
        id: 'ex1',
        position: 0,
        sets: [ExerciseSet.create(position: 1, reps: 3, breatherSecondsAfter: 0)],
        videoDurationMs: 3000,
        videoRepsPerLoop: 3,
        circuitId: circuitId,
      );
      final ex2 = _videoExercise(
        id: 'ex2',
        position: 1,
        sets: [ExerciseSet.create(position: 1, reps: 3, breatherSecondsAfter: 0)],
        videoDurationMs: 3000,
        videoRepsPerLoop: 3,
        circuitId: circuitId,
      );
      final session = _sessionWith([ex1, ex2], circuitCycles: {circuitId: 2});
      // oneRound = 2 exercises × (3 reps × 1s) = 6
      // total = 6 * 2 + 1 * AppConfig.restBetweenCircuitRounds
      final expected = 6 * 2 + 1 * AppConfig.restBetweenCircuitRounds;
      expect(session.estimatedTotalDurationSeconds, expected);
    });

    test('two separate circuits are accounted for independently', () {
      const circuitA = 'circuit-E1';
      const circuitB = 'circuit-E2';
      final exA = _videoExercise(
        id: 'exA',
        position: 0,
        sets: [ExerciseSet.create(position: 1, reps: 5, breatherSecondsAfter: 0)],
        videoDurationMs: 3000,
        videoRepsPerLoop: 3,
        circuitId: circuitA,
      );
      final exB = _videoExercise(
        id: 'exB',
        position: 1,
        sets: [ExerciseSet.create(position: 1, reps: 5, breatherSecondsAfter: 0)],
        videoDurationMs: 3000,
        videoRepsPerLoop: 3,
        circuitId: circuitB,
      );
      final session = _sessionWith(
        [exA, exB],
        circuitCycles: {circuitA: 2, circuitB: 3},
      );
      // circuitA: 5 * 2 + 1 * rest = 10 + rest
      // circuitB: 5 * 3 + 2 * rest = 15 + 2*rest
      final restA = 1 * AppConfig.restBetweenCircuitRounds;
      final restB = 2 * AppConfig.restBetweenCircuitRounds;
      expect(
        session.estimatedTotalDurationSeconds,
        (10 + restA) + (15 + restB),
      );
    });
  });
}
