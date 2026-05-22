// Unit tests for pure utility functions that have no Flutter/platform deps:
//   - duration_format.dart (formatDurationStyled)
//   - session_title.dart (formatSessionTimestamp, formatSessionTitle)
//
// Run on any host machine with `flutter test` (no simulator or path_provider
// needed — pure Dart logic only).

import 'package:flutter_test/flutter_test.dart';
import 'package:raidme/utils/duration_format.dart';
import 'package:raidme/utils/session_title.dart';

void main() {
  // ---------------------------------------------------------------------------
  // formatDurationStyled — verbose style (default)
  // ---------------------------------------------------------------------------

  group('formatDurationStyled — verbose', () {
    test('0 seconds', () {
      expect(formatDurationStyled(0), '0s');
    });

    test('45 seconds', () {
      expect(formatDurationStyled(45), '45s');
    });

    test('59 seconds', () {
      expect(formatDurationStyled(59), '59s');
    });

    test('1 minute exactly', () {
      expect(formatDurationStyled(60), '1 min');
    });

    test('2 minutes exactly', () {
      expect(formatDurationStyled(120), '2 min');
    });

    test('12 minutes with seconds (truncates to minutes)', () {
      expect(formatDurationStyled(750), '12 min');
    });

    test('59 minutes exactly', () {
      expect(formatDurationStyled(59 * 60), '59 min');
    });

    test('1 hour exactly', () {
      expect(formatDurationStyled(3600), '1h');
    });

    test('1 hour 30 minutes', () {
      expect(formatDurationStyled(5400), '1h 30min');
    });

    test('2 hours exactly', () {
      expect(formatDurationStyled(7200), '2h');
    });

    test('75 minutes (the credit billing threshold)', () {
      expect(formatDurationStyled(75 * 60), '1h 15min');
    });
  });

  // ---------------------------------------------------------------------------
  // formatDurationStyled — compact style
  // ---------------------------------------------------------------------------

  group('formatDurationStyled — compact', () {
    const compact = DurationFormatStyle.compact;

    test('0 seconds', () {
      expect(formatDurationStyled(0, style: compact), '0s');
    });

    test('45 seconds', () {
      expect(formatDurationStyled(45, style: compact), '45s');
    });

    test('1 minute exactly', () {
      expect(formatDurationStyled(60, style: compact), '1m');
    });

    test('2 minutes 30 seconds', () {
      expect(formatDurationStyled(150, style: compact), '2m 30s');
    });

    test('45 minutes exactly', () {
      expect(formatDurationStyled(45 * 60, style: compact), '45m');
    });

    test('45 minutes 30 seconds', () {
      expect(formatDurationStyled(45 * 60 + 30, style: compact), '45m 30s');
    });

    test('1 hour exactly', () {
      expect(formatDurationStyled(3600, style: compact), '1h');
    });

    test('1 hour 30 minutes exactly', () {
      expect(formatDurationStyled(5400, style: compact), '1h 30m');
    });

    test('1 hour 30 minutes 15 seconds', () {
      expect(formatDurationStyled(5415, style: compact), '1h 30m 15s');
    });

    test('2 hours exactly', () {
      expect(formatDurationStyled(7200, style: compact), '2h');
    });
  });

  // ---------------------------------------------------------------------------
  // formatSessionTimestamp
  // ---------------------------------------------------------------------------

  group('formatSessionTimestamp', () {
    test('formats a known date correctly', () {
      final dt = DateTime(2026, 4, 19, 17, 9);
      expect(formatSessionTimestamp(dt), '19 Apr 2026 17:09');
    });

    test('pads single-digit hour with leading zero', () {
      final dt = DateTime(2026, 1, 5, 8, 3);
      expect(formatSessionTimestamp(dt), '5 Jan 2026 08:03');
    });

    test('does not pad single-digit day', () {
      final dt = DateTime(2026, 5, 1, 10, 0);
      expect(formatSessionTimestamp(dt), '1 May 2026 10:00');
    });

    test('formats midnight correctly', () {
      final dt = DateTime(2026, 12, 31, 0, 0);
      expect(formatSessionTimestamp(dt), '31 Dec 2026 00:00');
    });

    test('formats all months correctly', () {
      const expectedMonths = [
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
      ];
      for (int m = 1; m <= 12; m++) {
        final dt = DateTime(2026, m, 15, 12, 0);
        expect(
          formatSessionTimestamp(dt),
          contains(expectedMonths[m - 1]),
          reason: 'Month $m should map to ${expectedMonths[m - 1]}',
        );
      }
    });
  });

  // ---------------------------------------------------------------------------
  // formatSessionTitle — API compatibility wrapper
  // ---------------------------------------------------------------------------

  group('formatSessionTitle', () {
    test('returns the same result as formatSessionTimestamp', () {
      final dt = DateTime(2026, 4, 19, 17, 9);
      expect(
        formatSessionTitle('ignored client name', dt),
        formatSessionTimestamp(dt),
      );
    });

    test('clientName parameter is ignored (legacy compat)', () {
      final dt = DateTime(2026, 5, 22, 9, 30);
      expect(
        formatSessionTitle('Alice', dt),
        formatSessionTitle('Bob', dt),
        reason: 'clientName is intentionally unused — both calls must produce identical output',
      );
    });
  });
}
