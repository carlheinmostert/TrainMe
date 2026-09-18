// Tests for the PublishResult sealed class and its companion exception types.
//
// These tests cover the pure-Dart logic in upload_service.dart that has no
// external dependencies (no network, no Supabase, no file-system). They exist
// to pin the contract of the revenue-critical publish path against regressions:
// every publish either succeeds with a charged credit and a URL, or fails with
// a structured result that tells the UI exactly what happened and whether a
// refund was issued.
//
// Run with: flutter test test/publish_result_test.dart

import 'package:flutter_test/flutter_test.dart';

import 'package:raidme/models/client.dart';
import 'package:raidme/models/publish_progress.dart';
import 'package:raidme/services/api_client.dart' show UnconsentedTreatment;
import 'package:raidme/services/upload_service.dart';

void main() {
  // -------------------------------------------------------------------------
  // PublishResult.success
  // -------------------------------------------------------------------------
  group('PublishResult.success', () {
    test('sets success=true, url, version, creditsCharged', () {
      final r = PublishResult.success(
        url: 'https://session.homefit.studio/p/abc',
        version: 3,
        creditsCharged: 1,
      );
      expect(r.success, isTrue);
      expect(r.url, 'https://session.homefit.studio/p/abc');
      expect(r.version, 3);
      expect(r.creditsCharged, 1);
    });

    test('convenience getters are all false on a clean success', () {
      final r = PublishResult.success(
        url: 'https://session.homefit.studio/p/abc',
        version: 1,
        creditsCharged: 1,
      );
      expect(r.isPreflightFailure, isFalse);
      expect(r.isNetworkFailure, isFalse);
      expect(r.isInsufficientCredits, isFalse);
      expect(r.isUnconsentedTreatments, isFalse);
      expect(r.isNeedsConsentConfirmation, isFalse);
    });

    test('optionalArtifactsHadFailures defaults false', () {
      final r = PublishResult.success(
        url: 'https://session.homefit.studio/p/abc',
        version: 1,
        creditsCharged: 1,
      );
      expect(r.optionalArtifactsHadFailures, isFalse);
      expect(r.optionalArtifactFailureReason, isNull);
    });

    test('optionalArtifactsHadFailures=true sets the failure reason', () {
      final failure = UploadFailureRecord(
        kind: 'raw_archive_upload_failed',
        storagePath: 'p1/plan1/ex1.mp4',
        localPath: '/docs/archive/ex1.mp4',
        fileExists: false,
        exerciseId: 'ex1',
      );
      final r = PublishResult.success(
        url: 'https://session.homefit.studio/p/abc',
        version: 2,
        creditsCharged: 1,
        optionalArtifactsHadFailures: true,
        optionalArtifactFailures: [failure],
      );
      expect(r.optionalArtifactsHadFailures, isTrue);
      expect(r.optionalArtifactFailures, hasLength(1));
      expect(r.optionalArtifactFailureReason, isNotNull);
    });

    test('consentPreflightSkipped=true surfaces the skipped reason', () {
      final r = PublishResult.success(
        url: 'https://session.homefit.studio/p/abc',
        version: 1,
        creditsCharged: 1,
        consentPreflightSkipped: true,
      );
      expect(r.consentPreflightSkipped, isTrue);
      expect(r.consentPreflightSkippedReason, isNotNull);
    });

    test('fallbackSetExerciseIds carries through', () {
      final r = PublishResult.success(
        url: 'https://session.homefit.studio/p/abc',
        version: 1,
        creditsCharged: 1,
        fallbackSetExerciseIds: ['ex-001', 'ex-002'],
      );
      expect(r.fallbackSetExerciseIds, containsAllInOrder(['ex-001', 'ex-002']));
    });
  });

  // -------------------------------------------------------------------------
  // PublishResult.preflightFailed
  // -------------------------------------------------------------------------
  group('PublishResult.preflightFailed', () {
    test('sets success=false, isPreflightFailure=true', () {
      final r = PublishResult.preflightFailed(missing: ['ex-1.mp4', 'ex-2.mp4']);
      expect(r.success, isFalse);
      expect(r.isPreflightFailure, isTrue);
      expect(r.missingFiles, containsAllInOrder(['ex-1.mp4', 'ex-2.mp4']));
    });

    test('toErrorString lists missing file names', () {
      final r = PublishResult.preflightFailed(missing: ['videoA.mp4']);
      expect(r.toErrorString(), contains('videoA.mp4'));
    });

    test('other convenience getters are false', () {
      final r = PublishResult.preflightFailed(missing: ['f.mp4']);
      expect(r.isNetworkFailure, isFalse);
      expect(r.isInsufficientCredits, isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // PublishResult.networkFailed
  // -------------------------------------------------------------------------
  group('PublishResult.networkFailed', () {
    test('sets success=false, isNetworkFailure=true', () {
      final r = PublishResult.networkFailed(error: Exception('timeout'));
      expect(r.success, isFalse);
      expect(r.isNetworkFailure, isTrue);
    });

    test('toErrorString includes the exception message', () {
      final r = PublishResult.networkFailed(
        error: const PublishFailureMessage('Storage upload timed out'),
      );
      expect(r.toErrorString(), contains('Storage upload timed out'));
    });

    test('toErrorString falls back gracefully for unknown error types', () {
      final r = PublishResult.networkFailed(error: Exception('unknown'));
      final s = r.toErrorString();
      expect(s, isNotEmpty);
    });

    test('toErrorString is capped at 500 chars', () {
      final longMsg = 'A' * 600;
      final r = PublishResult.networkFailed(
        error: PublishFailureMessage(longMsg),
      );
      expect(r.toErrorString().length, 500);
    });
  });

  // -------------------------------------------------------------------------
  // PublishResult.insufficientCredits
  // -------------------------------------------------------------------------
  group('PublishResult.insufficientCredits', () {
    test('sets success=false, balance, required, practiceId', () {
      final r = PublishResult.insufficientCredits(
        balance: 0,
        required: 1,
        practiceId: 'practice-123',
      );
      expect(r.success, isFalse);
      expect(r.isInsufficientCredits, isTrue);
      expect(r.balance, 0);
      expect(r.required, 1);
      expect(r.practiceId, 'practice-123');
    });

    test('toErrorString mentions balance and required credits', () {
      final r = PublishResult.insufficientCredits(
        balance: 2,
        required: 3,
        practiceId: 'p1',
      );
      final s = r.toErrorString();
      expect(s, contains('2'));
      expect(s, contains('3'));
    });
  });

  // -------------------------------------------------------------------------
  // PublishResult.unconsentedTreatments
  // -------------------------------------------------------------------------
  group('PublishResult.unconsentedTreatments', () {
    test('sets success=false, isUnconsentedTreatments=true', () {
      final e = UnconsentedTreatmentsException(
        violations: [
          const UnconsentedTreatment(
            exerciseId: 'ex-1',
            preferredTreatment: 'original',
            consentKey: 'original',
          ),
        ],
        clientName: 'Garry',
      );
      final r = PublishResult.unconsentedTreatments(e);
      expect(r.success, isFalse);
      expect(r.isUnconsentedTreatments, isTrue);
      expect(r.unconsented, same(e));
    });

    test('toErrorString mentions client name', () {
      final e = UnconsentedTreatmentsException(
        violations: [
          const UnconsentedTreatment(
            exerciseId: 'ex-1',
            preferredTreatment: 'grayscale',
            consentKey: 'grayscale',
          ),
        ],
        clientName: 'Melissa',
      );
      final r = PublishResult.unconsentedTreatments(e);
      expect(r.toErrorString(), contains('Melissa'));
    });
  });

  // -------------------------------------------------------------------------
  // PublishResult.needsConsentConfirmation
  // -------------------------------------------------------------------------
  group('PublishResult.needsConsentConfirmation', () {
    test('sets success=false, isNeedsConsentConfirmation=true', () {
      const client = PracticeClient(
        id: 'client-1',
        practiceId: 'practice-1',
        name: 'Jane',
      );
      final r = PublishResult.needsConsentConfirmation(client);
      expect(r.success, isFalse);
      expect(r.isNeedsConsentConfirmation, isTrue);
      expect(r.consentConfirmationClient?.name, 'Jane');
    });

    test('toErrorString includes the client name', () {
      const client = PracticeClient(
        id: 'client-2',
        practiceId: 'practice-1',
        name: 'Thomas',
      );
      final r = PublishResult.needsConsentConfirmation(client);
      expect(r.toErrorString(), contains('Thomas'));
    });

    test('toErrorString falls back gracefully for empty name', () {
      const client = PracticeClient(
        id: 'client-3',
        practiceId: 'practice-1',
        name: '',
      );
      final r = PublishResult.needsConsentConfirmation(client);
      expect(r.toErrorString(), isNotEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // UnconsentedTreatmentsException
  // -------------------------------------------------------------------------
  group('UnconsentedTreatmentsException', () {
    test('toString reports violation count and client name', () {
      final e = UnconsentedTreatmentsException(
        violations: [
          const UnconsentedTreatment(
            exerciseId: 'ex-1',
            preferredTreatment: 'original',
            consentKey: 'original',
          ),
          const UnconsentedTreatment(
            exerciseId: 'ex-2',
            preferredTreatment: 'grayscale',
            consentKey: 'grayscale',
          ),
        ],
        clientName: 'Alice',
      );
      final s = e.toString();
      expect(s, contains('2'));
      expect(s, contains('Alice'));
    });
  });

  // -------------------------------------------------------------------------
  // PublishFailureMessage
  // -------------------------------------------------------------------------
  group('PublishFailureMessage', () {
    test('toString returns the message exactly', () {
      const m = PublishFailureMessage('Credit deduction failed');
      expect(m.toString(), 'Credit deduction failed');
    });
  });
}
