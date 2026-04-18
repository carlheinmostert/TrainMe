/// Raidme app configuration
///
/// These values are safe for client-side use.
/// The publishable key is designed to be public — Row Level Security
/// controls what it can access.
class AppConfig {
  static const String supabaseUrl = 'https://yrwcofhovrcydootivjx.supabase.co';
  static const String supabaseAnonKey = 'sb_publishable_cwhfavfji552BN8X0uPIpA_pwWQ-gw3';

  /// Short git SHA baked at build time via
  /// `flutter build ios ... --dart-define=GIT_SHA=$(git rev-parse --short HEAD)`.
  /// Surfaced in the bottom-right of the Pulse Mark footer so we can confirm
  /// at a glance which commit is running on device after a rebuild.
  /// Defaults to `dev` when not passed.
  static const String buildSha =
      String.fromEnvironment('GIT_SHA', defaultValue: 'dev');

  /// Base URL for shared plan links (web player)
  /// TODO: Update when domain is registered
  static const String webPlayerBaseUrl = 'https://session.homefit.studio';

  /// Video recording constraints
  static const int maxVideoSeconds = 30;
  static const int videoWarningSeconds = 15;

  /// Recycle bin: days before soft-deleted sessions are permanently purged
  static const int recycleBinRetentionDays = 7;

  /// Duration estimation defaults
  static const int secondsPerRep = 3;
  static const int restBetweenSets = 30; // seconds
  static const int restBetweenCircuitRounds = 60; // seconds
  static const int defaultRestDuration = 30; // seconds for auto-inserted rest periods
  static const int restInsertIntervalMinutes = 10; // auto-insert rest every N minutes

  /// Line drawing conversion defaults
  static const int blurKernel = 31;
  static const int thresholdBlock = 9;
  static const int contrastLow = 80;

  // ---------------------------------------------------------------------------
  // Multi-tenant billing foundation (Milestone A)
  // ---------------------------------------------------------------------------
  // Sentinel uuids used while Carl is the sole trainer. Every plan publish
  // stamps `practice_id = sentinelPracticeId` and `trainer_id = sentinelTrainerId`
  // on the `plan_issuances` audit row. Milestone B replaces these with values
  // derived from the authenticated session; Milestone C makes `practice_id`
  // NOT NULL on `plans` once we are confident every code path stamps it.
  //
  // Keep these in lock-step with supabase/schema_milestone_a.sql (sentinel
  // backfill section).
  static const String sentinelPracticeId =
      '00000000-0000-0000-0000-0000000ca71e';
  static const String sentinelTrainerId =
      '00000000-0000-0000-0000-000000000001';

  /// Deep-link callback URL used by Supabase OAuth providers (Google, Apple).
  /// Registered in `app/ios/Runner/Info.plist` under `CFBundleURLTypes` and
  /// configured in the Supabase dashboard as an allowed redirect URL.
  /// Matches the iOS app's bundle identifier so the OS routes the callback
  /// straight back into the app.
  static const String oauthRedirectUrl =
      'com.raidme.raidme://login-callback';

  /// Welcome-bonus credits granted to a brand-new practice (user who signs in
  /// after the sentinel has already been claimed). Lets them publish a couple
  /// of plans before needing to buy credits.
  static const int welcomeBonusCredits = 5;

  /// Credit cost by plan size (non-rest exercise count).
  /// 1-8 exercises  → 1 credit
  /// 9-15 exercises → 2 credits
  /// 16+ exercises  → 3 credits (clamped)
  static const int creditsPerSmallPlan = 1; // 1-8 exercises
  static const int creditsPerMediumPlan = 2; // 9-15 exercises
  static const int creditsPerLargePlan = 3; // 16+ exercises
}

/// Credit cost for a plan given its non-rest exercise count.
///
/// Formula: `ceil(count / 8)` clamped to `[1, 3]`.
///   1-8   → 1 credit
///   9-15  → 2 credits  (9/8 = 1.125 → ceil = 2)
///   16+   → 3 credits  (clamped)
///
/// An empty plan (count == 0) is billed at the minimum of 1 credit so the
/// audit row is never zero — if we ever see `credits_charged = 0` in
/// `plan_issuances` it means the clamp was bypassed, which is a bug.
int creditCostFor(int exerciseCount) {
  if (exerciseCount <= 0) return AppConfig.creditsPerSmallPlan;
  final raw = ((exerciseCount + 7) ~/ 8); // ceil(n/8)
  if (raw <= AppConfig.creditsPerSmallPlan) return AppConfig.creditsPerSmallPlan;
  if (raw >= AppConfig.creditsPerLargePlan) return AppConfig.creditsPerLargePlan;
  return raw;
}
