// Tests for the shared duration-formatting helpers in
// `app/lib/utils/duration_format.dart`.
//
// These are pure functions with no Flutter-engine dependency, so they run
// fast under `flutter test` without any special setUp.

import 'package:flutter_test/flutter_test.dart';
import 'package:raidme/utils/duration_format.dart';

void main() {
  group('formatDurationStyled — verbose (default)', () {
    test('under 60s returns Ns', () {
      expect(formatDurationStyled(0), '0s');
      expect(formatDurationStyled(1), '1s');
      expect(formatDurationStyled(45), '45s');
      expect(formatDurationStyled(59), '59s');
    });

    test('exactly 60s returns "1 min"', () {
      expect(formatDurationStyled(60), '1 min');
    });

    test('1–59 min range returns "N min"', () {
      expect(formatDurationStyled(90), '1 min');
      expect(formatDurationStyled(120), '2 min');
      expect(formatDurationStyled(3599), '59 min');
    });

    test('exactly 1h returns "1h"', () {
      expect(formatDurationStyled(3600), '1h');
    });

    test('1h30min returns "1h 30min"', () {
      expect(formatDurationStyled(5400), '1h 30min');
    });

    test('2h returns "2h"', () {
      expect(formatDurationStyled(7200), '2h');
    });

    test('verbose ignores leftover seconds once past 60min', () {
      // 61 minutes 30 seconds → displayed as "61 min" (no seconds column).
      expect(formatDurationStyled(3690), '61 min');
      // 1h 0m 45s → displayed as "1h" (seconds stripped).
      expect(formatDurationStyled(3645), '1h');
    });
  });

  group('formatDurationStyled — compact', () {
    const compact = DurationFormatStyle.compact;

    test('under 60s returns Ns', () {
      expect(formatDurationStyled(0, style: compact), '0s');
      expect(formatDurationStyled(45, style: compact), '45s');
    });

    test('whole minutes return "Nm"', () {
      expect(formatDurationStyled(60, style: compact), '1m');
      expect(formatDurationStyled(120, style: compact), '2m');
      expect(formatDurationStyled(3540, style: compact), '59m');
    });

    test('minutes + seconds return "Nm Ns"', () {
      expect(formatDurationStyled(90, style: compact), '1m 30s');
      expect(formatDurationStyled(135, style: compact), '2m 15s');
    });

    test('exactly 1h returns "1h"', () {
      expect(formatDurationStyled(3600, style: compact), '1h');
    });

    test('1h whole minutes returns "1h Nm"', () {
      expect(formatDurationStyled(5400, style: compact), '1h 30m');
      expect(formatDurationStyled(7200, style: compact), '2h');
    });

    test('1h minutes + seconds returns "1h Nm Ns"', () {
      expect(formatDurationStyled(3661, style: compact), '1h 1m 1s');
      expect(formatDurationStyled(5445, style: compact), '1h 30m 45s');
    });
  });
}
