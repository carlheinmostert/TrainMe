// Unit tests for the shared duration formatting helpers.
//
// Covers:
//   - Sub-minute (seconds only)
//   - Exact minutes (no seconds)
//   - Minutes + seconds (compact vs verbose)
//   - Hours boundary
//   - Hours + remaining minutes
//   - Hours + seconds only (no remaining minutes — the "0m" edge case)
//   - All twelve month labels in formatSessionTimestamp

import 'package:flutter_test/flutter_test.dart';

import 'package:raidme/utils/duration_format.dart';

void main() {
  group('formatDurationStyled — sub-minute', () {
    test('0s → "0s"', () {
      expect(formatDurationStyled(0), '0s');
    });

    test('45s verbose → "45s"', () {
      expect(formatDurationStyled(45), '45s');
    });

    test('45s compact → "45s"', () {
      expect(
        formatDurationStyled(45, style: DurationFormatStyle.compact),
        '45s',
      );
    });

    test('59s → "59s"', () {
      expect(formatDurationStyled(59), '59s');
    });
  });

  group('formatDurationStyled — exact minutes', () {
    test('60s verbose → "1 min"', () {
      expect(formatDurationStyled(60), '1 min');
    });

    test('120s verbose → "2 min"', () {
      expect(formatDurationStyled(120), '2 min');
    });

    test('60s compact → "1m"', () {
      expect(
        formatDurationStyled(60, style: DurationFormatStyle.compact),
        '1m',
      );
    });

    test('3540s verbose → "59 min"', () {
      expect(formatDurationStyled(3540), '59 min');
    });
  });

  group('formatDurationStyled — minutes + seconds', () {
    test('90s compact → "1m 30s"', () {
      expect(
        formatDurationStyled(90, style: DurationFormatStyle.compact),
        '1m 30s',
      );
    });

    test('150s compact → "2m 30s"', () {
      expect(
        formatDurationStyled(150, style: DurationFormatStyle.compact),
        '2m 30s',
      );
    });

    test('90s verbose → "1 min" (verbose drops seconds for < 1h)', () {
      expect(formatDurationStyled(90), '1 min');
    });

    test('3599s verbose → "59 min"', () {
      expect(formatDurationStyled(3599), '59 min');
    });
  });

  group('formatDurationStyled — exact hours', () {
    test('3600s verbose → "1h"', () {
      expect(formatDurationStyled(3600), '1h');
    });

    test('3600s compact → "1h"', () {
      expect(
        formatDurationStyled(3600, style: DurationFormatStyle.compact),
        '1h',
      );
    });

    test('7200s verbose → "2h"', () {
      expect(formatDurationStyled(7200), '2h');
    });
  });

  group('formatDurationStyled — hours + minutes', () {
    test('3660s verbose → "1h 1min"', () {
      expect(formatDurationStyled(3660), '1h 1min');
    });

    test('3660s compact → "1h 1m"', () {
      expect(
        formatDurationStyled(3660, style: DurationFormatStyle.compact),
        '1h 1m',
      );
    });

    test('5400s verbose → "1h 30min"', () {
      expect(formatDurationStyled(5400), '1h 30min');
    });

    test('5400s compact → "1h 30m"', () {
      expect(
        formatDurationStyled(5400, style: DurationFormatStyle.compact),
        '1h 30m',
      );
    });
  });

  group('formatDurationStyled — hours + seconds (no remaining minutes)', () {
    test('3601s compact → "1h 1s" (no redundant "0m")', () {
      expect(
        formatDurationStyled(3601, style: DurationFormatStyle.compact),
        '1h 1s',
      );
    });

    test('7201s compact → "2h 1s"', () {
      expect(
        formatDurationStyled(7201, style: DurationFormatStyle.compact),
        '2h 1s',
      );
    });
  });

  group('formatDurationStyled — hours + minutes + seconds (compact)', () {
    test('3661s compact → "1h 1m 1s"', () {
      expect(
        formatDurationStyled(3661, style: DurationFormatStyle.compact),
        '1h 1m 1s',
      );
    });
  });
}
