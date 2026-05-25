// Phase 1 — Safe Mode v2 enrolment polish (2026-05-25).
// Spec: docs/specs/2026-05-25-safe-mode-v2-enrolment-polish.md (section 3
// Consent matrix, section 4f Consent-aware UI behaviour).
//
// Pins the four-cell consent matrix resolution that drives the editor's
// mode branching. The resolver is a pure function so we don't need to
// spin up the camera plugin or the native channel to exercise it.
//
// Phase 2 (pose gating, quality scoring, manual avatar selection grid)
// gets its own tests in this same file once the mockups are signed off
// and the sweep loop is replaced.

import 'package:flutter_test/flutter_test.dart';

import 'package:raidme/services/face_enrolment_service.dart';

void main() {
  group('resolveFaceEnrolmentMode (consent matrix)', () {
    test('both consents ON → full mode', () {
      expect(
        resolveFaceEnrolmentMode(
          faceRecognitionAllowed: true,
          avatarAllowed: true,
        ),
        FaceEnrolmentMode.full,
      );
    });

    test('face-rec ON, avatar OFF → embeddingOnly mode', () {
      expect(
        resolveFaceEnrolmentMode(
          faceRecognitionAllowed: true,
          avatarAllowed: false,
        ),
        FaceEnrolmentMode.embeddingOnly,
      );
    });

    test('face-rec OFF, avatar ON → avatarOnly mode', () {
      expect(
        resolveFaceEnrolmentMode(
          faceRecognitionAllowed: false,
          avatarAllowed: true,
        ),
        FaceEnrolmentMode.avatarOnly,
      );
    });

    test('both consents OFF → disabled mode', () {
      expect(
        resolveFaceEnrolmentMode(
          faceRecognitionAllowed: false,
          avatarAllowed: false,
        ),
        FaceEnrolmentMode.disabled,
      );
    });
  });

  group('FaceEnrolmentService construction', () {
    test('defaults to full mode when no mode argument is passed', () {
      // Back-compat with Wave-D callers that haven't been updated to
      // pass the resolved mode yet. Once all callers explicitly pass
      // the mode (Phase 2), this default can be removed.
      final svc = FaceEnrolmentService();
      expect(svc.mode, FaceEnrolmentMode.full);
      svc.dispose();
    });

    test('round-trips embeddingOnly mode through the constructor', () {
      final svc = FaceEnrolmentService(mode: FaceEnrolmentMode.embeddingOnly);
      expect(svc.mode, FaceEnrolmentMode.embeddingOnly);
      svc.dispose();
    });

    test('round-trips avatarOnly mode through the constructor', () {
      final svc = FaceEnrolmentService(mode: FaceEnrolmentMode.avatarOnly);
      expect(svc.mode, FaceEnrolmentMode.avatarOnly);
      svc.dispose();
    });
  });
}
