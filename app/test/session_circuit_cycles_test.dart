// Issue #578 — `Session.setCircuitCycles` validation.
//
// Previously the setter silently clamped invalid cycle counts
// (`cycles.clamp(1, 5)`), so a UI bug or a corrupted restored op payload
// passing `0` or a negative value produced a silently-broken session:
// the inter-round rest term in `estimatedTotalDurationSeconds`
// (`(cycles - 1) * restBetweenCircuitRounds`) relies on `cycles >= 1`,
// and a sub-1 value undercharges credits. Option A (approved) makes the
// setter THROW on `cycles < 1` so the bad value surfaces to the caller
// instead of being swallowed.
//
// The setter has no upper bound: the only call site
// (`StudioModeScreen._setCircuitCycles`, fed by `showCircuitControlSheet`
// with `maxCycles: 10`) legitimately produces values up to 10, and the
// duration math is correct for any `cycles >= 1`. The stale "1-5" range
// in the old clamp was never the real product bound.

import 'package:flutter_test/flutter_test.dart';

import 'package:raidme/models/session.dart';

void main() {
  Session baseSession() => Session(
        id: 'session-578',
        clientName: 'Test Client',
        createdAt: DateTime(2026, 5, 29),
      );

  const circuitId = 'circuit-a';

  group('Session.setCircuitCycles validation (issue #578)', () {
    test('throws ArgumentError on 0 cycles', () {
      expect(
        () => baseSession().setCircuitCycles(circuitId, 0),
        throwsArgumentError,
      );
    });

    test('throws ArgumentError on negative cycles', () {
      expect(
        () => baseSession().setCircuitCycles(circuitId, -1),
        throwsArgumentError,
      );
    });

    test('stores and returns a valid cycle count', () {
      final updated = baseSession().setCircuitCycles(circuitId, 3);
      expect(updated.getCircuitCycles(circuitId), 3);
    });

    test('accepts the lower-bound value of 1', () {
      final updated = baseSession().setCircuitCycles(circuitId, 1);
      expect(updated.getCircuitCycles(circuitId), 1);
    });

    test('accepts values above the old clamp ceiling (no upper bound)', () {
      // The UI sheet allows up to 10; the old clamp(1, 5) silently capped
      // these. Verify the value is now preserved verbatim.
      final updated = baseSession().setCircuitCycles(circuitId, 8);
      expect(updated.getCircuitCycles(circuitId), 8);
    });

    test('does not mutate the source session (returns a copy)', () {
      final original = baseSession();
      original.setCircuitCycles(circuitId, 4);
      // Unset circuit falls back to the default of 3.
      expect(original.getCircuitCycles(circuitId), 3);
    });
  });
}
