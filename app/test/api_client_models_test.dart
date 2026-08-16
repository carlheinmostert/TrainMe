// Tests for the pure-Dart model classes that live in api_client.dart.
//
// These classes contain the RPC-response parsing logic and numeric type
// coercions that need to be correct for billing (ReferralStats) and
// analytics (PlanAnalyticsSummary, ClientAnalyticsSummary). None of the
// tests here require Supabase or any platform channel — they're fully
// exercisable on the host via `flutter test`.

import 'package:flutter_test/flutter_test.dart';

import 'package:raidme/services/api_client.dart';
import 'package:raidme/services/sync_service.dart';

void main() {
  // ---------------------------------------------------------------------------
  // ReferralStats.fromJson
  // ---------------------------------------------------------------------------
  group('ReferralStats.fromJson', () {
    test('parses integer fields correctly', () {
      final s = ReferralStats.fromJson({
        'rebate_balance_credits': 3,
        'lifetime_rebate_credits': 10,
        'referee_count': 5,
        'qualifying_spend_total_zar': 250,
      });
      expect(s.rebateBalanceCredits, 3);
      expect(s.lifetimeRebateCredits, 10);
      expect(s.refereeCount, 5);
      expect(s.qualifyingSpendTotalZar, 250);
    });

    test('coerces String values to num/int', () {
      final s = ReferralStats.fromJson({
        'rebate_balance_credits': '1.5',
        'lifetime_rebate_credits': '7',
        'referee_count': '3',
        'qualifying_spend_total_zar': '99.99',
      });
      expect(s.rebateBalanceCredits, 1.5);
      expect(s.lifetimeRebateCredits, 7);
      expect(s.refereeCount, 3);
      expect(s.qualifyingSpendTotalZar, 99.99);
    });

    test('treats null fields as zero (safe default)', () {
      final s = ReferralStats.fromJson({});
      expect(s.rebateBalanceCredits, 0);
      expect(s.lifetimeRebateCredits, 0);
      expect(s.refereeCount, 0);
      expect(s.qualifyingSpendTotalZar, 0);
    });

    test('empty factory returns all-zero', () {
      const s = ReferralStats.empty;
      expect(s.rebateBalanceCredits, 0);
      expect(s.refereeCount, 0);
    });

    test('coerces double for num fields', () {
      final s = ReferralStats.fromJson({
        'rebate_balance_credits': 2.5,
        'lifetime_rebate_credits': 0.0,
        'referee_count': 1,
        'qualifying_spend_total_zar': 125.50,
      });
      expect(s.rebateBalanceCredits, 2.5);
      expect(s.qualifyingSpendTotalZar, 125.50);
    });
  });

  // ---------------------------------------------------------------------------
  // ExerciseAnalyticsStats.fromJson
  // ---------------------------------------------------------------------------
  group('ExerciseAnalyticsStats.fromJson', () {
    test('parses all fields', () {
      final s = ExerciseAnalyticsStats.fromJson({
        'exercise_id': 'abc-123',
        'viewed': 10,
        'completed': 8,
        'skipped': 2,
      });
      expect(s.exerciseId, 'abc-123');
      expect(s.viewed, 10);
      expect(s.completed, 8);
      expect(s.skipped, 2);
    });

    test('defaults to zero for missing counts', () {
      final s = ExerciseAnalyticsStats.fromJson({'exercise_id': 'x'});
      expect(s.viewed, 0);
      expect(s.completed, 0);
      expect(s.skipped, 0);
    });

    test('defaults exerciseId to empty string when missing', () {
      final s = ExerciseAnalyticsStats.fromJson({});
      expect(s.exerciseId, '');
    });

    test('coerces String counts to int', () {
      final s = ExerciseAnalyticsStats.fromJson({
        'exercise_id': 'y',
        'viewed': '5',
        'completed': '3',
        'skipped': '2',
      });
      expect(s.viewed, 5);
      expect(s.completed, 3);
      expect(s.skipped, 2);
    });
  });

  // ---------------------------------------------------------------------------
  // PlanAnalyticsSummary.fromJson
  // ---------------------------------------------------------------------------
  group('PlanAnalyticsSummary.fromJson', () {
    test('parses scalar fields and a non-empty exercise_stats list', () {
      final s = PlanAnalyticsSummary.fromJson({
        'opens': 20,
        'completions': 12,
        'last_opened_at': '2026-05-01T10:00:00.000Z',
        'exercise_stats': [
          {
            'exercise_id': 'ex-1',
            'viewed': 15,
            'completed': 10,
            'skipped': 5,
          },
          {
            'exercise_id': 'ex-2',
            'viewed': 8,
            'completed': 6,
            'skipped': 2,
          },
        ],
      });
      expect(s.opens, 20);
      expect(s.completions, 12);
      expect(s.lastOpenedAt, isNotNull);
      expect(s.exerciseStats, hasLength(2));
      expect(s.exerciseStats['ex-1']?.viewed, 15);
      expect(s.exerciseStats['ex-2']?.completed, 6);
    });

    test('handles missing / null exercise_stats gracefully', () {
      final s = PlanAnalyticsSummary.fromJson({'opens': 3, 'completions': 1});
      expect(s.exerciseStats, isEmpty);
      expect(s.lastOpenedAt, isNull);
    });

    test('ignores exercise_stats entries with empty exerciseId', () {
      final s = PlanAnalyticsSummary.fromJson({
        'opens': 1,
        'completions': 0,
        'exercise_stats': [
          {'viewed': 5, 'completed': 3, 'skipped': 2},
        ],
      });
      // entry has no exercise_id → filtered out
      expect(s.exerciseStats, isEmpty);
    });

    test('parses last_opened_at as UTC DateTime', () {
      final s = PlanAnalyticsSummary.fromJson({
        'opens': 0,
        'completions': 0,
        'last_opened_at': '2026-04-29T08:30:00.000Z',
      });
      expect(s.lastOpenedAt?.isUtc, isTrue);
      expect(s.lastOpenedAt?.year, 2026);
      expect(s.lastOpenedAt?.month, 4);
      expect(s.lastOpenedAt?.day, 29);
    });

    test('invalid last_opened_at string yields null', () {
      final s = PlanAnalyticsSummary.fromJson({
        'opens': 0,
        'completions': 0,
        'last_opened_at': 'not-a-date',
      });
      expect(s.lastOpenedAt, isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // ClientAnalyticsSummary.fromJson
  // ---------------------------------------------------------------------------
  group('ClientAnalyticsSummary.fromJson', () {
    test('parses integer fields', () {
      final s = ClientAnalyticsSummary.fromJson({
        'total_opens': 50,
        'total_completions': 40,
        'total_plans': 10,
      });
      expect(s.totalOpens, 50);
      expect(s.totalCompletions, 40);
      expect(s.totalPlans, 10);
    });

    test('defaults all to zero on empty map', () {
      final s = ClientAnalyticsSummary.fromJson({});
      expect(s.totalOpens, 0);
      expect(s.totalCompletions, 0);
      expect(s.totalPlans, 0);
    });

    test('coerces String fields', () {
      final s = ClientAnalyticsSummary.fromJson({
        'total_opens': '100',
        'total_completions': '80',
        'total_plans': '20',
      });
      expect(s.totalOpens, 100);
      expect(s.totalPlans, 20);
    });
  });

  // ---------------------------------------------------------------------------
  // ExerciseTreatmentUrls
  // ---------------------------------------------------------------------------
  group('ExerciseTreatmentUrls', () {
    test('all fields nullable and independent', () {
      const t = ExerciseTreatmentUrls(
        lineDrawingUrl: 'https://cdn.example.com/line.mp4',
        grayscaleUrl: null,
        originalUrl: null,
        restHoldSeconds: null,
      );
      expect(t.lineDrawingUrl, isNotNull);
      expect(t.grayscaleUrl, isNull);
      expect(t.originalUrl, isNull);
      expect(t.restHoldSeconds, isNull);
    });

    test('restHoldSeconds surfaces for rest rows', () {
      const t = ExerciseTreatmentUrls(restHoldSeconds: 60);
      expect(t.restHoldSeconds, 60);
    });
  });

  // ---------------------------------------------------------------------------
  // RenameClientError
  // ---------------------------------------------------------------------------
  group('RenameClientError.toString', () {
    test('includes kind name', () {
      const e = RenameClientError(RenameClientErrorKind.duplicate);
      expect(e.toString(), contains('duplicate'));
    });

    test('is an Exception', () {
      expect(
        const RenameClientError(RenameClientErrorKind.notFound),
        isA<Exception>(),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // SyncPullOutcome
  // ---------------------------------------------------------------------------
  group('SyncPullOutcome', () {
    test('both flags independently settable', () {
      const o = SyncPullOutcome(anySucceeded: true, hadError: false);
      expect(o.anySucceeded, isTrue);
      expect(o.hadError, isFalse);
    });

    test('partial success: some branches ok, one error', () {
      const o = SyncPullOutcome(anySucceeded: true, hadError: true);
      expect(o.anySucceeded, isTrue);
      expect(o.hadError, isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // ReplacePlanExercisesResult
  // ---------------------------------------------------------------------------
  group('ReplacePlanExercisesResult', () {
    test('holds planVersion and fallback list', () {
      const r = ReplacePlanExercisesResult(
        planVersion: 7,
        fallbackSetExerciseIds: ['ex-a', 'ex-b'],
      );
      expect(r.planVersion, 7);
      expect(r.fallbackSetExerciseIds, hasLength(2));
    });

    test('planVersion can be null (older RPC variant)', () {
      const r = ReplacePlanExercisesResult(
        planVersion: null,
        fallbackSetExerciseIds: [],
      );
      expect(r.planVersion, isNull);
      expect(r.fallbackSetExerciseIds, isEmpty);
    });
  });
}
