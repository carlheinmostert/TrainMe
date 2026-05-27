// Unit tests for duration formatting utilities.
//
// Covers both DurationFormatStyle variants and the session timestamp
// formatter. These are pure functions with no Flutter or SQLite
// dependencies so they run without any test-harness setup.

import 'package:flutter_test/flutter_test.dart';

import 'package:raidme/utils/duration_format.dart';
import 'package:raidme/utils/session_title.dart';

void main() {
  group('formatDurationStyled — verbose style', () {
    test('under 60s returns seconds', () {
      expect(formatDurationStyled(0), '0s');
      expect(formatDurationStyled(1), '1s');
      expect(formatDurationStyled(59), '59s');
    });

    test('exact minutes', () {
      expect(formatDurationStyled(60), '1 min');
      expect(formatDurationStyled(120), '2 min');
      expect(formatDurationStyled(3540), '59 min');
    });

    test('minutes with leftover seconds are shown as just minutes (verbose)',
        () {
      // Verbose style rounds down to minutes — seconds are dropped.
      expect(formatDurationStyled(90), '1 min');
      expect(formatDurationStyled(3599), '59 min');
    });

    test('exact hours', () {
      expect(formatDurationStyled(3600), '1h');
      expect(formatDurationStyled(7200), '2h');
    });

    test('hours with leftover minutes', () {
      expect(formatDurationStyled(3660), '1h 1min');
      expect(formatDurationStyled(5400), '1h 30min');
    });
  });

  group('formatDurationStyled — compact style', () {
    const style = DurationFormatStyle.compact;

    test('under 60s returns seconds', () {
      expect(formatDurationStyled(0, style: style), '0s');
      expect(formatDurationStyled(45, style: style), '45s');
      expect(formatDurationStyled(59, style: style), '59s');
    });

    test('exact minutes', () {
      expect(formatDurationStyled(60, style: style), '1m');
      expect(formatDurationStyled(120, style: style), '2m');
    });

    test('minutes with leftover seconds', () {
      expect(formatDurationStyled(90, style: style), '1m 30s');
      expect(formatDurationStyled(3599, style: style), '59m 59s');
    });

    test('exact hours', () {
      expect(formatDurationStyled(3600, style: style), '1h');
      expect(formatDurationStyled(7200, style: style), '2h');
    });

    test('hours with leftover minutes, no seconds', () {
      expect(formatDurationStyled(5400, style: style), '1h 30m');
    });

    test('hours with minutes and seconds', () {
      expect(formatDurationStyled(3661, style: style), '1h 1m 1s');
      expect(formatDurationStyled(5445, style: style), '1h 30m 45s');
    });
  });

  group('formatSessionTimestamp', () {
    test('formats a known datetime correctly', () {
      // 19 Apr 2026 at 17:09
      final dt = DateTime(2026, 4, 19, 17, 9);
      expect(formatSessionTimestamp(dt), '19 Apr 2026 17:09');
    });

    test('pads single-digit hour and minute', () {
      final dt = DateTime(2026, 1, 5, 8, 3);
      expect(formatSessionTimestamp(dt), '5 Jan 2026 08:03');
    });

    test('midnight renders as 00:00', () {
      final dt = DateTime(2026, 12, 31, 0, 0);
      expect(formatSessionTimestamp(dt), '31 Dec 2026 00:00');
    });

    test('all twelve months map correctly', () {
      const months = [
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
      ];
      for (var i = 0; i < 12; i++) {
        final dt = DateTime(2026, i + 1, 15, 12, 0);
        expect(
          formatSessionTimestamp(dt),
          contains(months[i]),
          reason: 'month index $i should produce ${months[i]}',
        );
      }
    });
  });

  group('formatSessionTitle', () {
    test('delegates to formatSessionTimestamp (no client prefix)', () {
      final dt = DateTime(2026, 5, 27, 9, 30);
      expect(formatSessionTitle(dt), formatSessionTimestamp(dt));
      expect(formatSessionTitle(dt), '27 May 2026 09:30');
    });
  });
}
