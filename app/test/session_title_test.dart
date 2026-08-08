// Unit tests for session_title.dart formatting helpers.
//
// formatSessionTimestamp — produces "{D Mon YYYY HH:MM}" strings (day is
//   not zero-padded; hour and minute are zero-padded).
// formatSessionTitle — thin deprecated wrapper; must produce identical output
//   to formatSessionTimestamp regardless of the (now-ignored) clientName arg.

import 'package:flutter_test/flutter_test.dart';

// ignore: deprecated_member_use
import 'package:raidme/utils/session_title.dart';

void main() {
  group('formatSessionTimestamp', () {
    test('formats a typical timestamp correctly', () {
      final dt = DateTime(2026, 4, 19, 17, 9);
      expect(formatSessionTimestamp(dt), '19 Apr 2026 17:09');
    });

    test('single-digit day is not zero-padded', () {
      final dt = DateTime(2026, 1, 5, 0, 0);
      expect(formatSessionTimestamp(dt), '5 Jan 2026 00:00');
    });

    test('double-digit day', () {
      final dt = DateTime(2026, 12, 31, 23, 59);
      expect(formatSessionTimestamp(dt), '31 Dec 2026 23:59');
    });

    test('midnight formats as 00:00', () {
      final dt = DateTime(2026, 6, 15, 0, 0);
      expect(formatSessionTimestamp(dt), endsWith('00:00'));
    });

    test('hour and minute are zero-padded', () {
      final dt = DateTime(2026, 3, 1, 9, 7);
      expect(formatSessionTimestamp(dt), '1 Mar 2026 09:07');
    });

    test('all twelve months map to the correct abbreviation', () {
      final expected = [
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
      ];
      for (var i = 0; i < 12; i++) {
        final dt = DateTime(2026, i + 1, 1, 0, 0);
        final result = formatSessionTimestamp(dt);
        expect(
          result,
          contains(expected[i]),
          reason: 'month ${i + 1} should abbreviate to ${expected[i]}',
        );
      }
    });
  });

  group('formatSessionTitle (deprecated)', () {
    test('produces the same result as formatSessionTimestamp', () {
      final dt = DateTime(2026, 4, 19, 17, 9);
      // ignore: deprecated_member_use
      expect(formatSessionTitle('Alice', dt), formatSessionTimestamp(dt));
    });

    test('clientName argument is ignored — empty string yields same result', () {
      final dt = DateTime(2026, 8, 8, 12, 0);
      // ignore: deprecated_member_use
      expect(formatSessionTitle('', dt), formatSessionTimestamp(dt));
    });
  });
}
