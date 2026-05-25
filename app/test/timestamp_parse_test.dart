// Tests for the shared parseTimestamp utility (lib/utils/timestamp_parse.dart).
//
// Also covers the ExerciseCapture.fromMap enum-safety guard (_decodeEnum)
// indirectly — an out-of-range media_type or conversion_status index should
// fall back to the enum's first value rather than throwing a RangeError.
//
// These are pure-Dart host tests — no sqflite or Flutter framework needed.

import 'package:flutter_test/flutter_test.dart';

import 'package:raidme/utils/timestamp_parse.dart';
import 'package:raidme/models/exercise_capture.dart';
import 'package:raidme/models/exercise_set.dart';

void main() {
  group('parseTimestamp', () {
    test('returns null for null input', () {
      expect(parseTimestamp(null), isNull);
    });

    test('returns the same DateTime when passed a DateTime', () {
      final dt = DateTime(2026, 5, 25, 12);
      expect(parseTimestamp(dt), equals(dt));
    });

    test('parses int as milliseconds since epoch', () {
      final ms = DateTime(2026, 5, 25).millisecondsSinceEpoch;
      final result = parseTimestamp(ms);
      expect(result, isNotNull);
      expect(result!.millisecondsSinceEpoch, ms);
    });

    test('parses ISO-8601 string', () {
      const iso = '2026-05-25T10:30:00.000Z';
      final result = parseTimestamp(iso);
      expect(result, isNotNull);
      expect(result!.toUtc().year, 2026);
      expect(result.toUtc().month, 5);
      expect(result.toUtc().day, 25);
    });

    test('returns null for malformed ISO string', () {
      expect(parseTimestamp('not-a-date'), isNull);
    });

    test('returns null for unexpected type (double)', () {
      expect(parseTimestamp(3.14), isNull);
    });

    test('returns null for unexpected type (bool)', () {
      expect(parseTimestamp(true), isNull);
    });
  });

  group('ExerciseCapture.fromMap — enum safety (_decodeEnum)', () {
    Map<String, dynamic> baseMap({int mediaType = 0, int conversionStatus = 0}) {
      return <String, dynamic>{
        'id': 'ex-test',
        'position': 0,
        'raw_file_path': 'raw/x.mp4',
        'converted_file_path': null,
        'thumbnail_path': null,
        'media_type': mediaType,
        'conversion_status': conversionStatus,
        'rest_hold_seconds': null,
        'notes': null,
        'name': null,
        'created_at': DateTime(2026, 5, 25).millisecondsSinceEpoch,
        'session_id': 'session-1',
        'circuit_id': null,
        'include_audio': 0,
        'prep_seconds': null,
        'video_duration_ms': null,
        'archive_file_path': null,
        'archived_at': null,
        'raw_archive_uploaded_at': null,
        'segmented_raw_file_path': null,
        'mask_file_path': null,
        'preferred_treatment': null,
        'start_offset_ms': null,
        'end_offset_ms': null,
        'video_reps_per_loop': null,
        'aspect_ratio': null,
        'rotation_quarters': null,
        'body_focus': null,
        'focus_frame_offset_ms': null,
        'hero_crop_offset': null,
        'thumbnails_dirty': 0,
      };
    }

    test('media_type=0 → photo', () {
      final ex = ExerciseCapture.fromMap(baseMap(mediaType: 0));
      expect(ex.mediaType, MediaType.photo);
    });

    test('media_type=1 → video', () {
      final ex = ExerciseCapture.fromMap(baseMap(mediaType: 1));
      expect(ex.mediaType, MediaType.video);
    });

    test('media_type=2 → rest', () {
      final ex = ExerciseCapture.fromMap(baseMap(mediaType: 2));
      expect(ex.mediaType, MediaType.rest);
    });

    test('media_type out-of-range falls back to photo (no RangeError)', () {
      // DB schema drift or corruption — must not throw.
      final ex = ExerciseCapture.fromMap(baseMap(mediaType: 99));
      expect(ex.mediaType, MediaType.photo);
    });

    test('media_type negative falls back to photo (no RangeError)', () {
      final ex = ExerciseCapture.fromMap(baseMap(mediaType: -1));
      expect(ex.mediaType, MediaType.photo);
    });

    test('conversion_status out-of-range falls back to pending (no RangeError)', () {
      final ex = ExerciseCapture.fromMap(baseMap(conversionStatus: 99));
      expect(ex.conversionStatus, ConversionStatus.pending);
    });
  });
}
