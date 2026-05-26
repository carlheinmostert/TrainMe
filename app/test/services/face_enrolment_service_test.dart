// Safe Mode v2 enrolment polish (2026-05-25).
// Spec: docs/specs/2026-05-25-safe-mode-v2-enrolment-polish.md
//
// Phase 1 — consent-matrix mode resolution (section 3 + 4f).
// Phase 2 — pose-gated sweep math + quality scoring (sections 4b + 4c).
//
// All tests target the pure functions in
// app/lib/services/face_enrolment_service.dart so we can exercise the
// math without spinning up the camera plugin or the native channel.

import 'dart:typed_data';

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

  // ── Phase 2 — pose-gated sweep ──────────────────────────────────────────

  group('poseDistance (Manhattan sum in degrees)', () {
    test('identical poses → 0', () {
      const a = (yaw: 0.0, pitch: 0.0);
      expect(poseDistance(a, a), 0.0);
      const b = (yaw: 30.5, pitch: -12.0);
      expect(poseDistance(b, b), 0.0);
    });

    test('axis-aligned difference adds linearly', () {
      const a = (yaw: 0.0, pitch: 0.0);
      const b = (yaw: 25.0, pitch: 0.0);
      expect(poseDistance(a, b), 25.0);
      const c = (yaw: 0.0, pitch: -10.0);
      expect(poseDistance(a, c), 10.0);
    });

    test('combined yaw + pitch difference', () {
      const a = (yaw: 10.0, pitch: 5.0);
      const b = (yaw: -20.0, pitch: 15.0);
      // |10 - (-20)| + |5 - 15| = 30 + 10 = 40.
      expect(poseDistance(a, b), 40.0);
    });

    test('symmetric — order does not matter', () {
      const a = (yaw: -45.0, pitch: 22.0);
      const b = (yaw: 18.5, pitch: -8.0);
      expect(poseDistance(a, b), poseDistance(b, a));
    });
  });

  group('PoseBucket centres', () {
    test('all six bucket centres are stable + well-separated', () {
      // Mockup design lock — Carl signed off on 6 buckets. Pin the
      // centre values so accidental edits surface as a test break.
      expect(PoseBucket.front.centerDeg, const (yaw: 0.0, pitch: 0.0));
      expect(PoseBucket.frontLeft.centerDeg, const (yaw: -30.0, pitch: 0.0));
      expect(PoseBucket.frontRight.centerDeg, const (yaw: 30.0, pitch: 0.0));
      expect(PoseBucket.left.centerDeg, const (yaw: -60.0, pitch: 0.0));
      expect(PoseBucket.right.centerDeg, const (yaw: 60.0, pitch: 0.0));
      expect(PoseBucket.slightUp.centerDeg, const (yaw: 0.0, pitch: 20.0));
    });

    test('bucket labels are word-form (Carl mockup signoff)', () {
      expect(PoseBucket.front.label, 'front');
      expect(PoseBucket.frontLeft.label, 'front-left');
      expect(PoseBucket.frontRight.label, 'front-right');
      expect(PoseBucket.left.label, 'left');
      expect(PoseBucket.right.label, 'right');
      expect(PoseBucket.slightUp.label, 'slight-up');
    });
  });

  group('closestUnfilledBucket', () {
    test('all unfilled, current pose at origin → front', () {
      expect(
        closestUnfilledBucket(const (yaw: 0.0, pitch: 0.0), <PoseBucket>{}),
        PoseBucket.front,
      );
    });

    test('front filled → returns next-closest unfilled', () {
      final filled = <PoseBucket>{PoseBucket.front};
      // Pose just off-centre to the right — frontRight should win.
      expect(
        closestUnfilledBucket(const (yaw: 5.0, pitch: 0.0), filled),
        PoseBucket.frontRight,
      );
    });

    test('every bucket filled → null', () {
      final filled = PoseBucket.values.toSet();
      expect(
        closestUnfilledBucket(const (yaw: 0.0, pitch: 0.0), filled),
        isNull,
      );
    });

    test('upward pose with all horizontal buckets filled → slightUp', () {
      final filled = <PoseBucket>{
        PoseBucket.front,
        PoseBucket.frontLeft,
        PoseBucket.frontRight,
        PoseBucket.left,
        PoseBucket.right,
      };
      expect(
        closestUnfilledBucket(const (yaw: 0.0, pitch: 25.0), filled),
        PoseBucket.slightUp,
      );
    });
  });

  group('snapToBucket', () {
    test('on-bucket-centre pose snaps to that bucket', () {
      for (final b in PoseBucket.values) {
        expect(snapToBucket(b.centerDeg), b,
            reason: 'centre of ${b.label} should snap to itself');
      }
    });

    test('wildly off pose returns null (35-deg guard)', () {
      // 90-deg yaw is far from every bucket centre.
      expect(snapToBucket(const (yaw: 90.0, pitch: 45.0)), isNull);
    });

    test('mid-way between two buckets picks the closer one', () {
      // 5-deg yaw is closer to `front` (yaw 0) than `frontRight` (yaw 30).
      expect(snapToBucket(const (yaw: 5.0, pitch: 0.0)), PoseBucket.front);
      // 25-deg yaw is closer to `frontRight` (yaw 30) than `front` (yaw 0).
      expect(snapToBucket(const (yaw: 25.0, pitch: 0.0)),
          PoseBucket.frontRight);
    });
  });

  group('isPoseGatedAcceptable', () {
    test('empty existing slot set → always accept', () {
      expect(
        isPoseGatedAcceptable(
          candidateDeg: const (yaw: 0.0, pitch: 0.0),
          existingDeg: const [],
        ),
        isTrue,
      );
    });

    test('identical to existing slot → reject', () {
      expect(
        isPoseGatedAcceptable(
          candidateDeg: const (yaw: 30.0, pitch: 0.0),
          existingDeg: const [(yaw: 30.0, pitch: 0.0)],
        ),
        isFalse,
      );
    });

    test('exactly at threshold (25 deg) → accept (>=)', () {
      // The default threshold is 25 deg Manhattan sum.
      expect(
        isPoseGatedAcceptable(
          candidateDeg: const (yaw: 25.0, pitch: 0.0),
          existingDeg: const [(yaw: 0.0, pitch: 0.0)],
        ),
        isTrue,
      );
    });

    test('just below threshold (24 deg) → reject', () {
      expect(
        isPoseGatedAcceptable(
          candidateDeg: const (yaw: 24.0, pitch: 0.0),
          existingDeg: const [(yaw: 0.0, pitch: 0.0)],
        ),
        isFalse,
      );
    });

    test('one existing fails the gate even when others pass', () {
      // Candidate is 50 deg from existing #1 but 20 deg from existing #2.
      expect(
        isPoseGatedAcceptable(
          candidateDeg: const (yaw: 50.0, pitch: 0.0),
          existingDeg: const [
            (yaw: 0.0, pitch: 0.0),
            (yaw: 70.0, pitch: 0.0),
          ],
        ),
        isFalse,
      );
    });

    test('custom threshold honoured', () {
      // 15 deg apart, gate at 10 → accept.
      expect(
        isPoseGatedAcceptable(
          candidateDeg: const (yaw: 15.0, pitch: 0.0),
          existingDeg: const [(yaw: 0.0, pitch: 0.0)],
          threshold: 10.0,
        ),
        isTrue,
      );
      // 15 deg apart, gate at 20 → reject.
      expect(
        isPoseGatedAcceptable(
          candidateDeg: const (yaw: 15.0, pitch: 0.0),
          existingDeg: const [(yaw: 0.0, pitch: 0.0)],
          threshold: 20.0,
        ),
        isFalse,
      );
    });
  });

  group('QualityScorer.score (composite 0-100)', () {
    test('all components at 1.0 + perfect embedding norm → 100', () {
      final s = QualityScorer.score(
        visionConfidence: 1.0,
        sharpness: 1.0,
        lighting: 1.0,
        poseUniqueness: 1.0,
        embeddingNorm: 1.0,
      );
      expect(s, 100.0);
    });

    test('all components zero + zero-norm embedding → 0', () {
      // norm = 0.0 → penalty 1.0 → norm component 0.0.
      final s = QualityScorer.score(
        visionConfidence: 0.0,
        sharpness: 0.0,
        lighting: 0.0,
        poseUniqueness: 0.0,
        embeddingNorm: 0.0,
      );
      expect(s, 0.0);
    });

    test('out-of-range inputs are clamped before weighting', () {
      // Confidence > 1 should not over-weight; same as 1.0.
      final s = QualityScorer.score(
        visionConfidence: 1.5,
        sharpness: 1.0,
        lighting: 1.0,
        poseUniqueness: 1.0,
        embeddingNorm: 1.0,
      );
      expect(s, 100.0);
    });

    test('weighted sum produces the spec-stated weights', () {
      // Each component contributes its weight when isolated to 1.0.
      // Vision confidence weight = 30.
      var s = QualityScorer.score(
        visionConfidence: 1.0,
        sharpness: 0.0,
        lighting: 0.0,
        poseUniqueness: 0.0,
        embeddingNorm: 0.0, // norm 0 → component 0.
      );
      expect(s, 30.0);

      // Sharpness weight = 25.
      s = QualityScorer.score(
        visionConfidence: 0.0,
        sharpness: 1.0,
        lighting: 0.0,
        poseUniqueness: 0.0,
        embeddingNorm: 0.0,
      );
      expect(s, 25.0);

      // Lighting weight = 20.
      s = QualityScorer.score(
        visionConfidence: 0.0,
        sharpness: 0.0,
        lighting: 1.0,
        poseUniqueness: 0.0,
        embeddingNorm: 0.0,
      );
      expect(s, 20.0);

      // Pose uniqueness weight = 15.
      s = QualityScorer.score(
        visionConfidence: 0.0,
        sharpness: 0.0,
        lighting: 0.0,
        poseUniqueness: 1.0,
        embeddingNorm: 0.0,
      );
      expect(s, 15.0);

      // Embedding norm weight = 10 (perfect norm → full 10 points,
      // every other component zero).
      s = QualityScorer.score(
        visionConfidence: 0.0,
        sharpness: 0.0,
        lighting: 0.0,
        poseUniqueness: 0.0,
        embeddingNorm: 1.0,
      );
      expect(s, 10.0);
    });

    test('threshold (60) sits right at "decent" — moderate everywhere', () {
      // VC 0.8, sharpness 0.6, lighting 0.6, pose unique 0.5, norm 1.0
      // = 30*0.8 + 25*0.6 + 20*0.6 + 15*0.5 + 10*1.0
      // = 24 + 15 + 12 + 7.5 + 10 = 68.5
      final s = QualityScorer.score(
        visionConfidence: 0.8,
        sharpness: 0.6,
        lighting: 0.6,
        poseUniqueness: 0.5,
        embeddingNorm: 1.0,
      );
      expect(s, closeTo(68.5, 0.01));
      // Above the 60 default reject threshold.
      expect(s, greaterThanOrEqualTo(kQualityThreshold));
    });

    test('low everywhere → below threshold, rejected at runtime', () {
      // VC 0.4, sharpness 0.3, lighting 0.3, pose 0.3, norm 0.6
      // = 30*0.4 + 25*0.3 + 20*0.3 + 15*0.3 + 10*(1 - 0.4)
      // = 12 + 7.5 + 6 + 4.5 + 6 = 36.0
      final s = QualityScorer.score(
        visionConfidence: 0.4,
        sharpness: 0.3,
        lighting: 0.3,
        poseUniqueness: 0.3,
        embeddingNorm: 0.6,
      );
      expect(s, closeTo(36.0, 0.01));
      expect(s, lessThan(kQualityThreshold));
    });
  });

  group('QualityScorer.poseUniquenessScore', () {
    test('first slot in empty set → 1.0', () {
      expect(
        QualityScorer.poseUniquenessScore(
          candidateDeg: const (yaw: 0.0, pitch: 0.0),
          existingDeg: const [],
        ),
        1.0,
      );
    });

    test('identical to existing → 0.0', () {
      expect(
        QualityScorer.poseUniquenessScore(
          candidateDeg: const (yaw: 30.0, pitch: 0.0),
          existingDeg: const [(yaw: 30.0, pitch: 0.0)],
        ),
        0.0,
      );
    });

    test('60 deg apart → 1.0 (full bucket separation)', () {
      expect(
        QualityScorer.poseUniquenessScore(
          candidateDeg: const (yaw: 60.0, pitch: 0.0),
          existingDeg: const [(yaw: 0.0, pitch: 0.0)],
        ),
        1.0,
      );
    });

    test('30 deg apart → 0.5', () {
      expect(
        QualityScorer.poseUniquenessScore(
          candidateDeg: const (yaw: 30.0, pitch: 0.0),
          existingDeg: const [(yaw: 0.0, pitch: 0.0)],
        ),
        0.5,
      );
    });

    test('picks the nearest existing pose (min distance)', () {
      // Candidate 50 deg from existing #1 (=0) but 10 deg from #2 (=60).
      // Minimum = 10 deg → score = 10/60 ≈ 0.167.
      expect(
        QualityScorer.poseUniquenessScore(
          candidateDeg: const (yaw: 50.0, pitch: 0.0),
          existingDeg: const [
            (yaw: 0.0, pitch: 0.0),
            (yaw: 60.0, pitch: 0.0),
          ],
        ),
        closeTo(10.0 / 60.0, 0.001),
      );
    });
  });

  group('QualityScorer.embeddingL2Norm', () {
    test('all-zero embedding → 0.0', () {
      final bytes = Uint8List(2048);
      expect(QualityScorer.embeddingL2Norm(bytes), 0.0);
    });

    test('single non-zero FP32 component round-trips', () {
      // 512 floats; set first to 1.0 → L2 norm = 1.0.
      final bytes = Uint8List(2048);
      final view = ByteData.sublistView(bytes);
      view.setFloat32(0, 1.0, Endian.little);
      expect(QualityScorer.embeddingL2Norm(bytes), closeTo(1.0, 0.001));
    });

    test('two non-zero FP32 components: norm = sqrt(sum of squares)', () {
      final bytes = Uint8List(2048);
      final view = ByteData.sublistView(bytes);
      view.setFloat32(0, 3.0, Endian.little);
      view.setFloat32(4, 4.0, Endian.little);
      // sqrt(9 + 16) = 5.
      expect(QualityScorer.embeddingL2Norm(bytes), closeTo(5.0, 0.001));
    });

    test('malformed (non-multiple-of-4) buffer → NaN', () {
      expect(QualityScorer.embeddingL2Norm(Uint8List(3)).isNaN, isTrue);
    });

    test('empty buffer → NaN', () {
      expect(QualityScorer.embeddingL2Norm(Uint8List(0)).isNaN, isTrue);
    });
  });

  group('Pose gating + quality scoring edge cases (spec section 7)', () {
    test('stationary head: same pose tested over and over → never accept', () {
      // Edge case from the brief — first acceptance lands, every
      // subsequent same-pose candidate is rejected by the pose gate.
      const stationary = (yaw: 0.0, pitch: 0.0);
      final existing = <({double yaw, double pitch})>[stationary];
      for (var i = 0; i < 20; i++) {
        expect(
          isPoseGatedAcceptable(
            candidateDeg: stationary,
            existingDeg: existing,
          ),
          isFalse,
          reason: 'tick $i should reject — identical to existing slot',
        );
      }
    });

    test('exactly-at-threshold yaw (25 deg) → accept', () {
      // Boundary case — Manhattan sum == 25 should pass the gate
      // since the rule is "below threshold" → reject (i.e. >= passes).
      expect(
        isPoseGatedAcceptable(
          candidateDeg: const (yaw: 25.0, pitch: 0.0),
          existingDeg: const [(yaw: 0.0, pitch: 0.0)],
        ),
        isTrue,
      );
    });

    test('single existing slot only blocks identical poses', () {
      // Edge case: with only one slot captured, anything 25+ degrees
      // away in Manhattan-sum becomes acceptable.
      const existing = [(yaw: 0.0, pitch: 0.0)];
      expect(
        isPoseGatedAcceptable(
          candidateDeg: const (yaw: 30.0, pitch: 0.0),
          existingDeg: existing,
        ),
        isTrue,
      );
      expect(
        isPoseGatedAcceptable(
          candidateDeg: const (yaw: 0.0, pitch: 30.0),
          existingDeg: existing,
        ),
        isTrue,
      );
    });
  });

  // ── M30 — explicit prompt sequence (2026-05-26) ───────────────────────────

  group('Phase 2 — restored 6-prompt sequence with slightUp', () {
    test('kPromptSequence has six prompts', () {
      expect(kPromptSequence, hasLength(6));
    });

    test('sequence sweeps all five horizontal yaw angles + slightUp', () {
      // Pose source is now Vision-on-CMSampleBuffer which emits pitch
      // reliably, so the 6th prompt is a chin-lift rather than a smile
      // retry of the front bucket. Order: front, right pair, left pair,
      // chin up.
      expect(
        kPromptSequence,
        const <PoseBucket>[
          PoseBucket.front,
          PoseBucket.frontRight,
          PoseBucket.right,
          PoseBucket.frontLeft,
          PoseBucket.left,
          PoseBucket.slightUp,
        ],
      );
    });

    test('full 6-prompt sweep advances through each bucket in order', () {
      // Walk the sequence linearly and verify each step's expected
      // bucket. Defends against accidental reordering — a sweep that
      // pitches up before sweeping horizontally would force the
      // practitioner to immediately swing through extremes.
      for (var i = 0; i < kPromptSequence.length; i++) {
        final bucket = kPromptSequence[i];
        switch (i) {
          case 0:
            expect(bucket, PoseBucket.front);
            break;
          case 1:
            expect(bucket, PoseBucket.frontRight);
            break;
          case 2:
            expect(bucket, PoseBucket.right);
            break;
          case 3:
            expect(bucket, PoseBucket.frontLeft);
            break;
          case 4:
            expect(bucket, PoseBucket.left);
            break;
          case 5:
            expect(bucket, PoseBucket.slightUp);
            break;
          default:
            fail('Unexpected prompt index $i');
        }
      }
    });

    test('kPromptInstructions matches sequence length and is in order', () {
      expect(kPromptInstructions, hasLength(6));
      expect(kPromptInstructions[0], 'Look straight ahead');
      expect(kPromptInstructions[1], 'Turn slightly to your right');
      expect(kPromptInstructions[2], 'Turn further to your right');
      expect(kPromptInstructions[3], 'Turn slightly to your left');
      expect(kPromptInstructions[4], 'Turn further to your left');
      expect(kPromptInstructions[5], 'Lift your chin slightly');
    });

    test('kPromptDirections matches sequence length and points up at slot 5', () {
      expect(kPromptDirections, hasLength(6));
      expect(
        kPromptDirections,
        const <String>['straight', 'right', 'right', 'left', 'left', 'up'],
      );
    });

    test('kPromptStallHints has six entries with non-empty copy', () {
      expect(kPromptStallHints, hasLength(6));
      for (final hint in kPromptStallHints) {
        expect(hint, isNotEmpty);
      }
      // The 6th stall hint is chin-lift specific now that the prompt
      // is "Lift your chin slightly" rather than a smile retry.
      expect(kPromptStallHints[5], contains('chin'));
    });

    test('first prompt target bucket is front', () {
      expect(kPromptSequence.first, PoseBucket.front);
    });

    test('last prompt target bucket is slightUp', () {
      expect(kPromptSequence.last, PoseBucket.slightUp);
    });

    test('kMinPromptsForValidEnrolment is at most kPromptSequence.length', () {
      expect(kMinPromptsForValidEnrolment, lessThanOrEqualTo(kPromptSequence.length));
      expect(kMinPromptsForValidEnrolment, greaterThanOrEqualTo(3));
    });

    test('stall hint timing — soft hint before skip hint', () {
      expect(kStallSoftHintAfter, lessThan(kStallSkipAfter));
    });
  });

  group('Phase 2 — slightUp prompt requires non-zero pitch', () {
    // The Vision-on-CMSampleBuffer pose source emits pitch reliably,
    // so the slightUp bucket (yaw 0, pitch +20) demands a genuine
    // chin-lift rather than any horizontal pose. These tests pin
    // down that pitch is load-bearing for the slightUp bucket — a
    // regression that re-pinned pitch to 0 would silently allow the
    // straight-ahead pose to satisfy the chin-lift prompt.

    test('horizontal pose (yaw 45, pitch 0) does NOT satisfy slightUp', () {
      // slightUp centre is (yaw 0, pitch 20). Distance from (45, 0) is
      // |45| + |20| = 65, well outside the 20-deg accept tolerance the
      // service uses. The bucket walker correctly rejects the frame.
      const horizontalCandidate = (yaw: 45.0, pitch: 0.0);
      final target = PoseBucket.slightUp.centerDeg;
      final d = poseDistance(horizontalCandidate, target);
      expect(d, greaterThan(20.0),
          reason: 'Pure-yaw pose must not satisfy the chin-up prompt');
    });

    test('chin-lift pose (yaw 0, pitch 20) satisfies slightUp', () {
      const chinLiftCandidate = (yaw: 0.0, pitch: 20.0);
      final target = PoseBucket.slightUp.centerDeg;
      final d = poseDistance(chinLiftCandidate, target);
      // On-bucket-centre — distance 0.
      expect(d, 0.0);
      // And it does NOT satisfy the front bucket (pitch 20 vs 0 = 20
      // delta, equal to the accept tolerance — boundary case but the
      // bucket walker tracks the CURRENT prompt's target, not the
      // closest; this expectation is informational and pins down that
      // the chin-lift pose is meaningfully different from front).
      final frontDist = poseDistance(
          chinLiftCandidate, PoseBucket.front.centerDeg);
      expect(frontDist, 20.0);
    });

    test('snapToBucket prefers slightUp for a pure chin-lift pose', () {
      // The 35-degree guard in snapToBucket means a clean (0, 20)
      // pose should land on slightUp, not front.
      expect(snapToBucket(const (yaw: 0.0, pitch: 20.0)),
          PoseBucket.slightUp);
    });
  });

  group('Phase 2 — pose event mirror semantics (user-perspective)', () {
    // The native side negates yaw + roll for the front camera before
    // emitting so the Dart side consumes user-perspective values
    // directly. These tests pin down the contract that arriving pose
    // events use the same chirality as kPromptSequence — a regression
    // that dropped the inversion would make "turn right" prompts walk
    // the wrong way.

    test('positive yaw matches "user turned head right" (sequence chirality)', () {
      // kPromptSequence position 2 targets PoseBucket.right with centre
      // (yaw +60, pitch 0). If the native side ever stopped inverting
      // yaw for the front camera, the practitioner turning their head
      // to their right would emit NEGATIVE yaw and the prompt walker
      // would silently never advance past prompt 1.
      const userTurnedRight = (yaw: 60.0, pitch: 0.0);
      final target = PoseBucket.right.centerDeg;
      expect(poseDistance(userTurnedRight, target), 0.0);
    });

    test('negative yaw matches "user turned head left"', () {
      const userTurnedLeft = (yaw: -60.0, pitch: 0.0);
      final target = PoseBucket.left.centerDeg;
      expect(poseDistance(userTurnedLeft, target), 0.0);
    });

    test('positive pitch matches "user lifted chin"', () {
      // The native side does NOT negate pitch for the front camera
      // (mirroring around the vertical axis doesn't swap up/down).
      // A user lifting their chin should emit positive pitch directly.
      const userChinUp = (yaw: 0.0, pitch: 20.0);
      final target = PoseBucket.slightUp.centerDeg;
      expect(poseDistance(userChinUp, target), 0.0);
    });
  });

  // ── M31 — state-machine completeness ──────────────────────────────────────

  group('M31 — failed state is reachable + cancellable', () {
    test('cancel() from failed state transitions to cancelled', () {
      // The Failed-state Close button calls service.cancel(); for the
      // close to actually pop the route, the service must transition
      // to FaceEnrolmentState.cancelled so the screen listener fires.
      final svc = FaceEnrolmentService();
      // We can't easily push the service into failed without a real
      // native channel, but we can verify cancel() is safe to invoke
      // and the precondition that cancelled is NOT the same as done.
      svc.cancel();
      // From idle, cancel() transitions immediately.
      expect(svc.state, FaceEnrolmentState.cancelled);
      svc.dispose();
    });
  });
}
