// Credit pricing rule: plans estimated at ≤ 75 minutes cost 1 credit;
// plans over 75 minutes cost 2 credits. The threshold is anti-abuse only —
// virtually all real-world plans cost 1 credit.
//
// `creditCostForDuration` is a pure function in `app/lib/config.dart` that
// takes the sum of `ExerciseCapture.estimatedDurationSeconds` for every
// NON-REST exercise in the session (rest periods are excluded from billing).
//
// These tests pin the boundary behaviour so a future change to the threshold
// constant (AppConfig.creditDurationThresholdSeconds) or the function body
// can't silently break billing without a test failure.

import 'package:flutter_test/flutter_test.dart';
import 'package:raidme/config.dart';

void main() {
  const thresholdSeconds = AppConfig.creditDurationThresholdSeconds; // 4500s = 75 min

  group('creditCostForDuration', () {
    test('zero duration (empty plan) → 1 credit', () {
      expect(creditCostForDuration(0), 1);
    });

    test('1 second → 1 credit', () {
      expect(creditCostForDuration(1), 1);
    });

    test('exactly at threshold → 1 credit (threshold is exclusive: > not >=)', () {
      expect(creditCostForDuration(thresholdSeconds), 1);
    });

    test('one second below threshold → 1 credit', () {
      expect(creditCostForDuration(thresholdSeconds - 1), 1);
    });

    test('one second above threshold → 2 credits', () {
      expect(creditCostForDuration(thresholdSeconds + 1), 2);
    });

    test('very long plan (3 hours) → 2 credits', () {
      expect(creditCostForDuration(3 * 60 * 60), 2);
    });
  });
}
