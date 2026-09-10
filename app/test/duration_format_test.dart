import 'package:flutter_test/flutter_test.dart';
import 'package:raidme/utils/duration_format.dart';

void main() {
  group('formatDurationStyled — compact', () {
    test('sub-minute returns seconds', () {
      expect(formatDurationStyled(0, style: DurationFormatStyle.compact), '0s');
      expect(formatDurationStyled(1, style: DurationFormatStyle.compact), '1s');
      expect(formatDurationStyled(59, style: DurationFormatStyle.compact), '59s');
    });

    test('exact minutes, no seconds', () {
      expect(formatDurationStyled(60, style: DurationFormatStyle.compact), '1m');
      expect(formatDurationStyled(120, style: DurationFormatStyle.compact), '2m');
      expect(formatDurationStyled(3540, style: DurationFormatStyle.compact), '59m');
    });

    test('minutes with seconds', () {
      expect(formatDurationStyled(61, style: DurationFormatStyle.compact), '1m 1s');
      expect(formatDurationStyled(150, style: DurationFormatStyle.compact), '2m 30s');
      expect(formatDurationStyled(3599, style: DurationFormatStyle.compact), '59m 59s');
    });

    test('exact hours, no minutes, no seconds', () {
      expect(formatDurationStyled(3600, style: DurationFormatStyle.compact), '1h');
      expect(formatDurationStyled(7200, style: DurationFormatStyle.compact), '2h');
    });

    test('hours with minutes only', () {
      expect(formatDurationStyled(3660, style: DurationFormatStyle.compact), '1h 1m');
      expect(formatDurationStyled(5400, style: DurationFormatStyle.compact), '1h 30m');
    });

    test('hours with minutes and seconds', () {
      expect(formatDurationStyled(3661, style: DurationFormatStyle.compact), '1h 1m 1s');
      expect(formatDurationStyled(5445, style: DurationFormatStyle.compact), '1h 30m 45s');
    });

    test('hours with zero minutes and seconds', () {
      expect(formatDurationStyled(3601, style: DurationFormatStyle.compact), '1h 0m 1s');
    });
  });

  group('formatDurationStyled — verbose (default)', () {
    test('sub-minute returns seconds', () {
      expect(formatDurationStyled(0), '0s');
      expect(formatDurationStyled(1), '1s');
      expect(formatDurationStyled(59), '59s');
    });

    test('minutes only (no seconds shown)', () {
      expect(formatDurationStyled(60), '1 min');
      expect(formatDurationStyled(90), '1 min');
      expect(formatDurationStyled(120), '2 min');
      expect(formatDurationStyled(3540), '59 min');
    });

    test('exact hours, no remaining minutes', () {
      expect(formatDurationStyled(3600), '1h');
      expect(formatDurationStyled(7200), '2h');
    });

    test('hours with remaining minutes', () {
      expect(formatDurationStyled(3660), '1h 1min');
      expect(formatDurationStyled(5400), '1h 30min');
    });
  });
}
