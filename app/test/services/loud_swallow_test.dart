// loudSwallow / loudSwallowSync public-behaviour unit tests (#577).
//
// `app/lib/services/loud_swallow.dart` is the single sanctioned
// exception-swallow infrastructure for the whole codebase (Wave 7 /
// Milestone Q). It had no tests, so any regression in its return /
// rethrow contract silently broke error visibility app-wide with no
// failing test to catch it.
//
// SCOPE — PUBLIC CONTRACT ONLY. These tests pin the observable
// behaviour at the public boundary (inputs -> return value / rethrow),
// NOT the internal structure. They deliberately do NOT reach into
// `_postErrorLog`, `_appendLocalLog`, `_truncate`, `_stackTop`, or
// `_enrichMeta`. That keeps this file composable with PR #595, which is
// deduping the helper's internals in parallel — refactoring the private
// machinery must not break these tests as long as the contract holds.
//
// The two server/filesystem side-effects (`_postErrorLog`,
// `_appendLocalLog`) are fired with `unawaited(...)` and each catches
// its own errors internally, so they never escape onto the caller's
// timeline. We mock the path_provider method channel so the local-log
// breadcrumb write degrades quietly under `flutter test`, then pump the
// microtask/event queue at the end of each case so any pending
// fire-and-forget future settles without leaking into the next test.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:raidme/services/loud_swallow.dart';

/// A distinguishable exception type so rethrow assertions can prove the
/// ORIGINAL error propagated (not some wrapper the helper synthesised).
class _SentinelException implements Exception {
  const _SentinelException(this.tag);
  final String tag;
  @override
  String toString() => '_SentinelException($tag)';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // path_provider's platform channel. Returning a temp dir lets the
  // fire-and-forget local-log breadcrumb degrade quietly instead of
  // throwing a MissingPluginException into the test's zone.
  const pathProviderChannel =
      MethodChannel('plugins.flutter.io/path_provider');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
      // Any directory query resolves to the system temp dir.
      return Directory.systemTemp.path;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
  });

  // Let any unawaited fire-and-forget side-effect futures settle so they
  // don't bleed into the next test as unhandled async work.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  group('loudSwallow (async)', () {
    test('happy path — forwards the body return value unchanged', () async {
      final result = await loudSwallow<int>(
        () async => 42,
        kind: 'test_ok',
        source: 'test',
      );

      expect(result, 42);
      await settle();
    });

    test('happy path — preserves a complex/structured return value',
        () async {
      final payload = <String, Object?>{'a': 1, 'b': const ['x', 'y']};

      final result = await loudSwallow<Map<String, Object?>>(
        () async => payload,
        kind: 'test_ok_map',
        source: 'test',
      );

      expect(result, same(payload));
      await settle();
    });

    test('error path — rethrows the original exception by default', () async {
      // swallow defaults to false: the caller has to opt IN to swallow.
      expect(
        () => loudSwallow<int>(
          () async => throw const _SentinelException('default-rethrow'),
          kind: 'test_rethrow',
          source: 'test',
        ),
        throwsA(isA<_SentinelException>()),
      );
      await settle();
    });

    test('error path — rethrows the ORIGINAL error object (not a wrapper)',
        () async {
      const original = _SentinelException('identity');
      Object? caught;
      try {
        await loudSwallow<int>(
          () async => throw original,
          kind: 'test_rethrow_identity',
          source: 'test',
        );
        fail('expected loudSwallow to rethrow');
      } catch (e) {
        caught = e;
      }

      expect(caught, same(original));
      await settle();
    });

    test('error path — returns null (does not throw) when swallow: true',
        () async {
      final result = await loudSwallow<int>(
        () async => throw const _SentinelException('swallowed'),
        kind: 'test_swallow',
        source: 'test',
        swallow: true,
      );

      expect(result, isNull);
      await settle();
    });

    test('swallow: true with a non-throwing body still returns the value',
        () async {
      // swallow only changes the error path; the success path is identical.
      final result = await loudSwallow<String>(
        () async => 'fine',
        kind: 'test_swallow_ok',
        source: 'test',
        swallow: true,
      );

      expect(result, 'fine');
      await settle();
    });

    test('caller-supplied severity / meta / message do not change the '
        'success contract', () async {
      final result = await loudSwallow<int>(
        () async => 7,
        kind: 'test_args',
        source: 'test',
        severity: 'error',
        message: 'custom message',
        meta: const {'practice_id': 'p-123', 'exercise_id': 'e-456'},
      );

      expect(result, 7);
      await settle();
    });

    test('caller-supplied severity / meta / message do not change the '
        'swallow-error contract', () async {
      final result = await loudSwallow<int>(
        () async => throw const _SentinelException('with-meta'),
        kind: 'test_args_err',
        source: 'test',
        severity: 'fatal',
        message: 'boom',
        meta: const {'practice_id': 'p-789'},
        swallow: true,
      );

      expect(result, isNull);
      await settle();
    });
  });

  group('loudSwallowSync (sync)', () {
    test('happy path — runs the body without throwing', () {
      var ran = false;
      loudSwallowSync(
        () => ran = true,
        kind: 'test_sync_ok',
        source: 'test',
      );

      expect(ran, isTrue);
    });

    test('error path — rethrows the original exception by default', () {
      expect(
        () => loudSwallowSync(
          () => throw const _SentinelException('sync-default-rethrow'),
          kind: 'test_sync_rethrow',
          source: 'test',
        ),
        throwsA(isA<_SentinelException>()),
      );
    });

    test('error path — rethrows the ORIGINAL error object (not a wrapper)',
        () {
      const original = _SentinelException('sync-identity');
      Object? caught;
      try {
        loudSwallowSync(
          () => throw original,
          kind: 'test_sync_identity',
          source: 'test',
        );
        fail('expected loudSwallowSync to rethrow');
      } catch (e) {
        caught = e;
      }

      expect(caught, same(original));
    });

    test('error path — swallows (does not throw) when swallow: true', () {
      // The whole point of the sync variant: prove it returns normally.
      expect(
        () => loudSwallowSync(
          () => throw const _SentinelException('sync-swallowed'),
          kind: 'test_sync_swallow',
          source: 'test',
          swallow: true,
        ),
        returnsNormally,
      );
    });

    test('caller-supplied severity / meta / message do not change the '
        'swallow-error contract', () {
      expect(
        () => loudSwallowSync(
          () => throw const _SentinelException('sync-with-meta'),
          kind: 'test_sync_args',
          source: 'test',
          severity: 'error',
          message: 'sync boom',
          meta: const {'practice_id': 'p-sync'},
          swallow: true,
        ),
        returnsNormally,
      );
    });
  });
}
