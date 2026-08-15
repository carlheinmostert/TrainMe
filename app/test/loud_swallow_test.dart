import 'package:flutter_test/flutter_test.dart';
import 'package:raidme/services/loud_swallow.dart';

void main() {
  group('loudSwallow', () {
    test('rethrows when swallow: false', () async {
      await expectLater(
        loudSwallow<void>(
          () async => throw StateError('expected'),
          kind: 'test_kind',
          source: 'loud_swallow_test',
          swallow: false,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('returns null and does not rethrow when swallow: true', () async {
      final result = await loudSwallow<String>(
        () async => throw StateError('expected'),
        kind: 'test_kind',
        source: 'loud_swallow_test',
        swallow: true,
      );
      expect(result, isNull);
    });

    test('returns the body result on success', () async {
      final result = await loudSwallow<String>(
        () async => 'hello',
        kind: 'test_kind',
        source: 'loud_swallow_test',
      );
      expect(result, 'hello');
    });

    test('rethrows the exact exception type', () async {
      await expectLater(
        loudSwallow<void>(
          () async => throw ArgumentError('bad arg'),
          kind: 'test_kind',
          source: 'loud_swallow_test',
          swallow: false,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('loudSwallowSync', () {
    test('rethrows when swallow: false', () {
      expect(
        () => loudSwallowSync(
          () => throw StateError('expected'),
          kind: 'test_kind',
          source: 'loud_swallow_test',
          swallow: false,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('does not rethrow when swallow: true', () {
      expect(
        () => loudSwallowSync(
          () => throw StateError('expected'),
          kind: 'test_kind',
          source: 'loud_swallow_test',
          swallow: true,
        ),
        returnsNormally,
      );
    });

    test('runs body normally on success', () {
      var ran = false;
      loudSwallowSync(
        () => ran = true,
        kind: 'test_kind',
        source: 'loud_swallow_test',
      );
      expect(ran, isTrue);
    });
  });
}
