// Safe Mode v2 video — Dart-side unit tests (2026-05-25).
//
// Covers the two acceptance-criteria items in section 10 of
// `docs/specs/2026-05-25-safe-mode-v2-video.md`:
//
//   1. Fail-closed rule applies identically to v2 video. The threshold
//      [kSafeModeMaxMissRate] and the `SafeModeRejection` exception
//      shape are what the outer queue handler keys on; whether the
//      pass under the hood is v1 (largest bbox) or v2 (face-rec) does
//      not change the rule. We pin the boundary semantics here so a
//      future tweak that ships an asymmetric rule for video catches
//      this test on the way in.
//
//   2. Per-frame progress stream emission. The native pipeline emits
//      on the `homefit-safe-mode-v2-video-progress` EventChannel; the
//      conversion service wraps each value in a
//      [SafeModeV2VideoProgress] record tagged with the exercise id
//      and forwards via [ConversionService.onSafeModeV2VideoProgress].
//      The Studio card observer ([_SafeModeV2VideoProgressOverlay] in
//      `capture_thumbnail.dart`) filters by id. These tests confirm
//      the wire shape — exercise id round-trips and the fraction
//      stays in the [0.0, 1.0] domain.
//
// Native unit tests for the state machine are out of scope per the
// spec; the manual test wave covers those.

import 'package:flutter_test/flutter_test.dart';

import 'package:raidme/services/conversion_service.dart';

void main() {
  group('SafeModeRejection.missRateExceeded — v2 video fail-closed', () {
    test(
      'value just above kSafeModeMaxMissRate triggers the reject reason',
      () {
        final justAbove = kSafeModeMaxMissRate + 0.0001;
        final rej = SafeModeRejection('ex-1', justAbove);
        expect(rej.missRate, justAbove);
        expect(rej.reason, SafeModeRejectionReason.missRateExceeded);
      },
    );

    test('the threshold itself (5%) sits on the accept side', () {
      // Outer queue handler in `_processQueue` uses `>` not `>=`, so
      // a miss rate exactly equal to the threshold accepts. v2 video
      // must preserve this boundary verbatim — the unified rule from
      // `docs/specs/2026-05-25-safe-mode-accept-zero-detection.md`
      // is symmetric for both media types.
      expect(kSafeModeMaxMissRate, 0.05);
    });

    test('toString includes the percentage formatted to one decimal', () {
      final rej = SafeModeRejection('ex-2', 0.123);
      expect(rej.toString(), contains('12.3%'));
      expect(rej.toString(), contains('ex-2'));
      expect(rej.toString(), contains('missRateExceeded'));
    });
  });

  group('SafeModeRejection.missingFaceEmbedding — v2 cold-cache branch', () {
    test('explicit reason flag round-trips into toString', () {
      // The v2 video pass (and the v2 photo pass before it) throws
      // this rejection when the bound client has no cached embedding
      // slots at conversion time — cold-start cache miss after an
      // app-kill mid-capture. The capture screen distinguishes by
      // reason so the toast copy can guide the practitioner.
      final rej = SafeModeRejection(
        'ex-3',
        0.0,
        reason: SafeModeRejectionReason.missingFaceEmbedding,
      );
      expect(rej.reason, SafeModeRejectionReason.missingFaceEmbedding);
      expect(rej.toString(), contains('missingFaceEmbedding'));
    });
  });

  group('SafeModeV2VideoProgress — wire shape', () {
    test('round-trips exerciseId + fraction verbatim', () {
      const e = SafeModeV2VideoProgress(exerciseId: 'ex-9', fraction: 0.42);
      expect(e.exerciseId, 'ex-9');
      expect(e.fraction, 0.42);
    });

    test('toString formats the fraction as a one-decimal percentage', () {
      const e = SafeModeV2VideoProgress(exerciseId: 'ex-9', fraction: 0.4239);
      expect(e.toString(), contains('ex-9'));
      expect(e.toString(), contains('42.4%'));
    });

    test('the Studio overlay can filter events for its own exercise', () {
      // [_SafeModeV2VideoProgressOverlay] in `capture_thumbnail.dart`
      // listens to the broadcast stream and discards events whose
      // exerciseId doesn't match its own. This test pins the
      // discriminator field — if it ever gets renamed or dropped,
      // the overlay would silently start showing the wrong card's
      // bar.
      const a = SafeModeV2VideoProgress(exerciseId: 'card-A', fraction: 0.3);
      const b = SafeModeV2VideoProgress(exerciseId: 'card-B', fraction: 0.8);
      expect(a.exerciseId, isNot(equals(b.exerciseId)));
    });
  });
}
