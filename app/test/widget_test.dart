// Smoke test — keeps the test binary link-checking the widget layer.
import 'package:flutter_test/flutter_test.dart';
import 'package:raidme/models/exercise_capture.dart';
import 'package:raidme/models/session.dart';

void main() {
  group('Session.displayTitle', () {
    test('returns title when set', () {
      final s = Session(
        id: 's1',
        clientName: 'Alice',
        title: 'Leg Day',
        createdAt: DateTime(2026, 1, 15, 9, 30),
      );
      expect(s.displayTitle, 'Leg Day');
    });

    test('falls back to clientName when title is null', () {
      final s = Session(
        id: 's2',
        clientName: 'Bob',
        createdAt: DateTime(2026, 1, 15, 9, 30),
      );
      expect(s.displayTitle, 'Bob');
    });
  });

  group('Session.hasUnpublishedContentChanges', () {
    test('false when sentAt is null (never published)', () {
      final s = Session(
        id: 's3',
        clientName: 'C',
        createdAt: DateTime(2026, 1, 1),
      );
      expect(s.hasUnpublishedContentChanges, isFalse);
    });

    test('true when lastContentEditAt > sentAt', () {
      final base = DateTime(2026, 1, 1);
      final s = Session(
        id: 's4',
        clientName: 'D',
        createdAt: base,
        sentAt: base.add(const Duration(hours: 1)),
        lastContentEditAt: base.add(const Duration(hours: 2)),
      );
      expect(s.hasUnpublishedContentChanges, isTrue);
    });

    test('false when lastContentEditAt <= sentAt', () {
      final base = DateTime(2026, 1, 1);
      final s = Session(
        id: 's5',
        clientName: 'E',
        createdAt: base,
        sentAt: base.add(const Duration(hours: 2)),
        lastContentEditAt: base.add(const Duration(hours: 1)),
      );
      expect(s.hasUnpublishedContentChanges, isFalse);
    });
  });

  group('ExerciseCapture.isRest', () {
    test('true for MediaType.rest', () {
      final e = ExerciseCapture(
        id: 'r1',
        position: 0,
        rawFilePath: '',
        mediaType: MediaType.rest,
        createdAt: DateTime.now(),
        restHoldSeconds: 30,
      );
      expect(e.isRest, isTrue);
    });

    test('false for MediaType.video', () {
      final e = ExerciseCapture(
        id: 'v1',
        position: 0,
        rawFilePath: 'raw/x.mp4',
        mediaType: MediaType.video,
        createdAt: DateTime.now(),
      );
      expect(e.isRest, isFalse);
    });
  });
}
