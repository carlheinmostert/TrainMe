// SafeModeMatchDiagnostic parser + threshold contract tests (Wave M41).
//
// The native side returns a Map keyed by 'faces' (List of per-face
// dicts) + 'subjectIndex' / 'bestSim' / 'branch' / 'referenceCount'.
// These tests assert the Dart parser is tolerant of the realistic
// channel-edge type sloppiness (num vs double, missing fields,
// odd-typed lists) and produces the right typed result.
//
// We don't drive the actual MethodChannel here — the platform side is
// covered by the native VideoConverterChannel test plan in
// `app/ios/RunnerTests/`. The risk this test guards is purely the
// dart-side parse contract: a change in the native payload shape
// MUST fail one of these assertions before reaching Carl's phone.

import 'package:flutter_test/flutter_test.dart';

import 'package:raidme/services/conversion_service.dart' show kSafeModeV2SoloFloor;
import 'package:raidme/services/safe_mode_match_diagnostic.dart';

void main() {
  group('SafeModeMatchDiagnostic.parseResultForTesting', () {
    test('parses a multi-face recognised result', () {
      final raw = <dynamic, dynamic>{
        'faces': <Map<dynamic, dynamic>>[
          {
            'cosSim': 0.62,
            'boundsX': 0.30,
            'boundsY': 0.40,
            'boundsWidth': 0.20,
            'boundsHeight': 0.25,
            'cropX': 200,
            'cropY': 350,
            'cropWidth': 180,
            'cropHeight': 220,
          },
          {
            'cosSim': 0.10,
            'boundsX': 0.70,
            'boundsY': 0.45,
            'boundsWidth': 0.10,
            'boundsHeight': 0.12,
            'cropX': 700,
            'cropY': 400,
            'cropWidth': 100,
            'cropHeight': 130,
          },
        ],
        'subjectIndex': 0,
        'bestSim': 0.62,
        'branch': 'multi-relative',
        'referenceCount': 6,
      };

      final result = SafeModeMatchDiagnostic.parseResultForTesting(raw);

      expect(result.faces, hasLength(2));
      expect(result.faces[0].cosSim, closeTo(0.62, 1e-9));
      expect(result.faces[1].cosSim, closeTo(0.10, 1e-9));
      expect(result.subjectIndex, 0);
      expect(result.subjectIdentified, isTrue);
      expect(result.bestSim, closeTo(0.62, 1e-9));
      expect(result.branch, 'multi-relative');
      expect(result.referenceCount, 6);
      expect(result.faces[0].normalizedBounds.left, closeTo(0.30, 1e-9));
      expect(result.faces[0].cropPixelRect.left, 200);
    });

    test('parses a solo-floor REJECTED result (subjectIndex null)', () {
      // This is the load-bearing failure shape — Carl's bug. One face,
      // cosSim below the solo-floor, picker returns subjectIndex=null.
      // The Dart layer must distinguish "no subject" from "no faces"
      // so the bottom-sheet interpretation can show the right message.
      final raw = <dynamic, dynamic>{
        'faces': <Map<dynamic, dynamic>>[
          {
            'cosSim': 0.07,
            'boundsX': 0.30,
            'boundsY': 0.40,
            'boundsWidth': 0.30,
            'boundsHeight': 0.35,
            'cropX': 240,
            'cropY': 320,
            'cropWidth': 290,
            'cropHeight': 320,
          },
        ],
        'subjectIndex': null,
        'bestSim': 0.07,
        'branch': 'solo-floor',
        'referenceCount': 6,
      };

      final result = SafeModeMatchDiagnostic.parseResultForTesting(raw);

      expect(result.faces, hasLength(1));
      expect(result.subjectIndex, isNull);
      expect(result.subjectIdentified, isFalse);
      expect(result.branch, 'solo-floor');
      expect(result.bestSim, lessThan(0.10),
          reason: 'cosSim under the solo-floor stays under the floor');
    });

    test('parses a no-faces result', () {
      final raw = <dynamic, dynamic>{
        'faces': <Map<dynamic, dynamic>>[],
        'subjectIndex': null,
        'bestSim': -2.0,
        'branch': 'no-faces',
        'referenceCount': 6,
      };

      final result = SafeModeMatchDiagnostic.parseResultForTesting(raw);

      expect(result.faces, isEmpty);
      expect(result.subjectIndex, isNull);
      expect(result.subjectIdentified, isFalse);
      expect(result.branch, 'no-faces');
      expect(result.bestSim, -2.0);
    });

    test('tolerates int values where doubles are expected', () {
      // FlutterStandardCodec sometimes hands `int` across the channel
      // for whole-number doubles. The parser must coerce via num.toDouble
      // not the unsafe `as double` cast.
      final raw = <dynamic, dynamic>{
        'faces': <Map<dynamic, dynamic>>[
          {
            'cosSim': 0, // int, not double
            'boundsX': 0,
            'boundsY': 0,
            'boundsWidth': 1,
            'boundsHeight': 1,
            'cropX': 0,
            'cropY': 0,
            'cropWidth': 100,
            'cropHeight': 100,
          },
        ],
        'subjectIndex': null,
        'bestSim': 0, // int
        'branch': 'solo-floor',
        'referenceCount': 1,
      };

      final result = SafeModeMatchDiagnostic.parseResultForTesting(raw);

      expect(result.faces.single.cosSim, 0.0);
      expect(result.bestSim, 0.0);
    });

    test('tolerates missing optional fields with safe defaults', () {
      // Defensive — if a future native version omits a field, the parser
      // shouldn't throw; it should fall through to a defaulted result
      // the UI can still render.
      final raw = <dynamic, dynamic>{
        // Only the minimum keys.
        'faces': <dynamic>[],
      };

      final result = SafeModeMatchDiagnostic.parseResultForTesting(raw);

      expect(result.faces, isEmpty);
      expect(result.subjectIndex, isNull);
      expect(result.bestSim, -2.0);
      expect(result.branch, 'unknown');
      expect(result.referenceCount, 0);
    });
  });

  group('kSafeModeMatchDiagnosticDefaultThreshold', () {
    test('stays in lock-step with kSafeModeV2SoloFloor', () {
      // Drift detector. The diagnostic's default threshold mirrors the
      // production solo-floor — we hold it as a local constant rather
      // than an import (to avoid a circular dependency with
      // conversion_service.dart), so a refactor that changes one MUST
      // change the other. This test fails loud if they drift.
      expect(
        kSafeModeMatchDiagnosticDefaultThreshold,
        equals(kSafeModeV2SoloFloor),
        reason:
            'Default diagnostic threshold has drifted from the '
            'production solo-floor — update both in lock-step or the '
            'diagnostic will lie about what the matcher would do.',
      );
    });
  });

  group('SafeModeDiagResult.subjectIdentified', () {
    test('true iff subjectIndex is non-null', () {
      // subjectIdentified is a getter — defend its semantics so future
      // refactors don't accidentally rename to "subjectIndex != -1" or
      // similar (which would silently flip recognition on null).
      const recognised = SafeModeDiagResult(
        faces: [],
        subjectIndex: 0,
        bestSim: 0.7,
        branch: 'multi-relative',
        referenceCount: 6,
      );
      const rejected = SafeModeDiagResult(
        faces: [],
        subjectIndex: null,
        bestSim: 0.07,
        branch: 'solo-floor',
        referenceCount: 6,
      );
      expect(recognised.subjectIdentified, isTrue);
      expect(rejected.subjectIdentified, isFalse);
    });
  });
}
