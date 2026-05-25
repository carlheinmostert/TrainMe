// Exercise Clipboard unit tests (S-7 — review finding 2026-05-25).
//
// Pins the ClipboardService contract documented in
// `docs/specs/2026-05-25-exercise-clipboard.md` (decisions D7 / D8 / E1)
// and the docstrings on `app/lib/services/clipboard_service.dart`.
//
// The service is a bare `ChangeNotifier` singleton with in-memory state —
// no file I/O, no SQLite, no platform channel. These tests stand it up
// against a fresh instance (singleton instance is fine — we explicitly
// `clearAll()` between tests to keep them hermetic) and exercise the
// public mutation surface.

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:raidme/models/exercise_capture.dart';
import 'package:raidme/models/session.dart';
import 'package:raidme/services/clipboard_service.dart';

ExerciseCapture _exercise({
  required String id,
  String? name,
  String? sessionId,
  MediaType mediaType = MediaType.video,
}) {
  return ExerciseCapture(
    id: id,
    position: 0,
    // Absolute path so PathResolver.resolve isn't reached for this test.
    rawFilePath: '/tmp/raidme-clipboard-$id.mp4',
    mediaType: mediaType,
    createdAt: DateTime.now(),
    sessionId: sessionId,
    name: name ?? 'Exercise $id',
    thumbnailPath: 'thumbnails/$id.jpg',
    heroCropOffset: 0.5,
  );
}

Session _session({String id = 'session-1'}) {
  return Session(
    id: id,
    clientName: 'Test Client',
    createdAt: DateTime.now(),
  );
}

void main() {
  group('ClipboardService — initial state', () {
    setUp(() {
      // Belt-and-braces — clear any leakage from prior groups since the
      // service is a singleton. clearAll is a no-op when already empty
      // (no listener notification fires).
      ClipboardService.instance.clearAll();
    });

    test('items is empty', () {
      expect(ClipboardService.instance.items, isEmpty);
    });

    test('count is zero', () {
      expect(ClipboardService.instance.count, 0);
    });

    test('isNotEmpty is false', () {
      expect(ClipboardService.instance.isNotEmpty, isFalse);
    });
  });

  group('ClipboardService.addItem', () {
    final service = ClipboardService.instance;
    final session = _session();

    setUp(() {
      service.clearAll();
    });

    test('populates items + increments count when adding one source', () {
      final ex = _exercise(id: 'ex-1', name: 'Squat');
      final added = service.addItem(ex, session);

      expect(added, isNotNull);
      expect(service.items, hasLength(1));
      expect(service.count, 1);
      expect(service.isNotEmpty, isTrue);
      expect(service.items.single.sourceExerciseId, 'ex-1');
      expect(service.items.single.sourceSessionId, session.id);
      expect(service.items.single.displayName, 'Squat');
      expect(service.items.single.displayMediaType, MediaType.video);
      expect(service.items.single.displayThumbPath, 'thumbnails/ex-1.jpg');
      expect(service.items.single.displayHeroCropOffset, 0.5);
    });

    test('de-dupes by sourceExerciseId — same source twice is a no-op',
        () {
      final ex = _exercise(id: 'ex-dup', name: 'Lunge');
      final first = service.addItem(ex, session);
      final second = service.addItem(ex, session);

      expect(first, isNotNull);
      // Second call returns null per the docstring — no count bump on
      // re-copy.
      expect(second, isNull);
      expect(service.items, hasLength(1));
      expect(service.count, 1);
    });

    test('rest periods are rejected defensively — addItem is a no-op', () {
      final restExercise = _exercise(
        id: 'rest-1',
        name: 'Rest',
        mediaType: MediaType.rest,
      );
      final result = service.addItem(restExercise, session);

      expect(result, isNull);
      expect(service.items, isEmpty);
      expect(service.count, 0);
    });

    test('preserves FIFO order across multiple adds (A, B, C)', () {
      final a = _exercise(id: 'ex-A', name: 'A');
      final b = _exercise(id: 'ex-B', name: 'B');
      final c = _exercise(id: 'ex-C', name: 'C');

      service.addItem(a, session);
      service.addItem(b, session);
      service.addItem(c, session);

      expect(
        service.items.map((i) => i.sourceExerciseId).toList(),
        <String>['ex-A', 'ex-B', 'ex-C'],
      );
    });
  });

  group('ClipboardService.clearAll', () {
    final service = ClipboardService.instance;
    final session = _session();

    setUp(() {
      service.clearAll();
    });

    test('empties the clipboard when items are present', () {
      service.addItem(_exercise(id: 'ex-1'), session);
      service.addItem(_exercise(id: 'ex-2'), session);
      service.addItem(_exercise(id: 'ex-3'), session);
      expect(service.count, 3);

      service.clearAll();
      expect(service.items, isEmpty);
      expect(service.count, 0);
      expect(service.isNotEmpty, isFalse);
    });
  });

  group('ClipboardService.notifySourceDeleted (E1 reactive pruning)', () {
    final service = ClipboardService.instance;
    final session = _session();

    setUp(() {
      service.clearAll();
    });

    test('removes the matching item; siblings stay intact', () {
      service.addItem(_exercise(id: 'ex-A'), session);
      service.addItem(_exercise(id: 'ex-B'), session);
      service.addItem(_exercise(id: 'ex-C'), session);

      service.notifySourceDeleted('ex-B');

      expect(service.count, 2);
      expect(
        service.items.map((i) => i.sourceExerciseId).toList(),
        <String>['ex-A', 'ex-C'],
      );
    });

    test('non-existent id is a silent no-op', () {
      service.addItem(_exercise(id: 'ex-A'), session);
      service.addItem(_exercise(id: 'ex-B'), session);
      final before = service.items.toList();

      // Should NOT throw, should NOT mutate state.
      service.notifySourceDeleted('ex-does-not-exist');

      expect(service.count, 2);
      expect(
        service.items.map((i) => i.sourceExerciseId).toList(),
        before.map((i) => i.sourceExerciseId).toList(),
      );
    });
  });

  group('ClipboardService — ChangeNotifier semantics', () {
    final service = ClipboardService.instance;
    final session = _session();

    setUp(() {
      service.clearAll();
    });

    test(
      'notifies listeners on add / clearAll / notifySourceDeleted (hits); '
      'silent on duplicate add and notifySourceDeleted miss',
      () {
        var notifyCount = 0;
        void listener() => notifyCount++;
        service.addListener(listener);
        addTearDown(() => service.removeListener(listener));

        // 1. First addItem → notification fires.
        service.addItem(_exercise(id: 'ex-1'), session);
        expect(notifyCount, 1, reason: 'addItem (new) should notify');

        // 2. Duplicate addItem → NO notification.
        service.addItem(_exercise(id: 'ex-1'), session);
        expect(
          notifyCount,
          1,
          reason: 'addItem (duplicate) should be silent',
        );

        // 3. notifySourceDeleted on an unknown id → NO notification.
        service.notifySourceDeleted('does-not-exist');
        expect(
          notifyCount,
          1,
          reason: 'notifySourceDeleted (miss) should be silent',
        );

        // 4. notifySourceDeleted on a real hit → notification fires.
        service.notifySourceDeleted('ex-1');
        expect(
          notifyCount,
          2,
          reason: 'notifySourceDeleted (hit) should notify',
        );

        // 5. clearAll on an already-empty clipboard → NO notification
        //    (per the docstring's `if (_items.isEmpty) return`).
        service.clearAll();
        expect(
          notifyCount,
          2,
          reason: 'clearAll on empty clipboard should be silent',
        );

        // 6. clearAll on a populated clipboard → notification fires.
        service.addItem(_exercise(id: 'ex-2'), session);
        expect(notifyCount, 3);
        service.clearAll();
        expect(
          notifyCount,
          4,
          reason: 'clearAll on populated clipboard should notify',
        );
      },
    );
  });

  group('ClipboardService.itemById', () {
    final service = ClipboardService.instance;
    final session = _session();

    setUp(() {
      service.clearAll();
    });

    test('returns the matching ClipboardItem for a known id', () {
      final ex = _exercise(id: 'ex-known');
      final added = service.addItem(ex, session);
      expect(added, isNotNull);

      final found = service.itemById(added!.id);
      expect(found, isNotNull);
      expect(found!.sourceExerciseId, 'ex-known');
    });

    test('returns null for an unknown clipboard id', () {
      expect(service.itemById('not-a-real-id'), isNull);
    });
  });

  group('ClipboardService — items view is unmodifiable', () {
    final service = ClipboardService.instance;
    final session = _session();

    setUp(() {
      service.clearAll();
    });

    test('items getter returns an unmodifiable view', () {
      service.addItem(_exercise(id: 'ex-immutable'), session);
      final view = service.items;
      // Trying to mutate the returned list must throw — that's the
      // entire point of the unmodifiable wrapper (callers can't smuggle
      // items in without going through addItem).
      expect(
        () => view.add(ClipboardItem(
          id: 'sneaky',
          sourceExerciseId: 'sneaky',
          sourceSessionId: 'sneaky',
          copiedAt: DateTime.now(),
          displayMediaType: MediaType.video,
        )),
        throwsA(isA<UnsupportedError>()),
      );
    });
  });

  group('ClipboardService — debug listener compatibility', () {
    // Smoke test that ChangeNotifier integration is healthy across mode
    // boundaries (debug + profile). Mostly future-proofing — guards
    // against an accidental swap to a custom notifier shape.
    test('subclasses Listenable correctly', () {
      expect(ClipboardService.instance, isA<Listenable>());
    });
  });
}
