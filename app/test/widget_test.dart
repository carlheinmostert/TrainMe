// Smoke tests for pure Dart helpers that have no Flutter-engine dependency.
// Widget-tree tests (which need the engine) live in separate files under
// test/widgets/ and are guarded by the @Tags(['flutter']) annotation.
//
// This file intentionally avoids importing any Flutter widget layer so it
// runs quickly under `flutter test --no-sound-null-safety` and plain
// `dart test` alike.

import 'package:flutter_test/flutter_test.dart';
import 'package:raidme/utils/duration_format.dart';

void main() {
  // Guard: the two styles must never produce identical output for values
  // where their grammar differs (minutes range). This catches a future
  // refactor accidentally unifying the label copy.
  test('verbose and compact produce distinct output for whole minutes', () {
    // 2 minutes: verbose = "2 min", compact = "2m".
    expect(
      formatDurationStyled(120),
      isNot(equals(formatDurationStyled(120, style: DurationFormatStyle.compact))),
    );
  });

  test('both styles agree on sub-minute formatting', () {
    // Under 60s the output is identical ("Ns") regardless of style.
    expect(
      formatDurationStyled(30),
      equals(formatDurationStyled(30, style: DurationFormatStyle.compact)),
    );
  });
}
