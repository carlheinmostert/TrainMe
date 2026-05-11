/// Raidme app configuration
///
/// These values are safe for client-side use.
/// The publishable key is designed to be public — Row Level Security
/// controls what it can access.
class AppConfig {
  // ---------------------------------------------------------------------------
  // Environment flag — three-way switch (see docs/CI.md §5).
  // ---------------------------------------------------------------------------
  // Resolves to one of:
  //   'prod'    — production Supabase project (yrwcofhovrcydootivjx).
  //               Used by TestFlight + App Store builds (bump-version.sh
  //               passes --dart-define=ENV=prod explicitly).
  //   'staging' — persistent Supabase branch DB (vadjvkmldtoeyspyoqbx).
  //               Used by manual "test against staging" builds.
  //   'branch'  — dynamic, current-git-branch-matched Supabase preview
  //               branch DB. The install scripts resolve the URL + anon
  //               key via the Supabase Management API and pass them in
  //               via --dart-define=SUPABASE_URL + SUPABASE_ANON_KEY.
  //
  // Default 'prod' is intentional: a manual `flutter build` without any
  // env flags should point at prod (matches pre-2026-05-11 behaviour).
  // install-sim.sh / install-device.sh override to ENV=branch and
  // bump-version.sh overrides to ENV=prod with the hardcoded URL/key
  // (defence in depth — the default already matches, but explicit is
  // load-bearing for TestFlight).
  static const String env = String.fromEnvironment(
    'ENV',
    defaultValue: 'prod',
  );

  // Compile-time prod constants — the source of truth for prod
  // credentials lives here. Defence-in-depth: the install scripts ALSO
  // hardcode these for the ENV=prod path, but if anything bypasses the
  // script (e.g. `flutter build` in an IDE) AppConfig.env defaults to
  // 'prod' and these values are used.
  static const String _prodSupabaseUrl =
      'https://yrwcofhovrcydootivjx.supabase.co';
  static const String _prodSupabaseAnonKey =
      'sb_publishable_cwhfavfji552BN8X0uPIpA_pwWQ-gw3';

  // Compile-time staging constants — kept as fallback defaults for
  // ENV=staging when the install script doesn't pass them explicitly.
  // The install script always passes them so these are belt-and-braces.
  static const String _stagingSupabaseUrl =
      'https://vadjvkmldtoeyspyoqbx.supabase.co';
  static const String _stagingSupabaseAnonKey =
      'sb_publishable_INTgC6wuK4nyjXlfQE4wpA_5AgBjeOy';

  /// Supabase project URL. Resolution order:
  ///   1. `--dart-define=SUPABASE_URL=...` (install scripts inject this
  ///      for ENV=branch and ENV=staging)
  ///   2. Static default based on [env]: prod URL when env=='prod',
  ///      staging URL otherwise.
  static String get supabaseUrl {
    if (_supabaseUrlFromEnv.isNotEmpty) {
      return _supabaseUrlFromEnv;
    }
    return env == 'prod' ? _prodSupabaseUrl : _stagingSupabaseUrl;
  }

  /// Supabase publishable (anon) key. Same resolution as [supabaseUrl].
  static String get supabaseAnonKey {
    if (_supabaseAnonKeyFromEnv.isNotEmpty) {
      return _supabaseAnonKeyFromEnv;
    }
    return env == 'prod' ? _prodSupabaseAnonKey : _stagingSupabaseAnonKey;
  }

  // Internal: the raw --dart-define values. Empty string means "not
  // passed at build time". Kept private so callers always go through the
  // getters which do the prod/staging fallback.
  static const String _supabaseUrlFromEnv = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: '',
  );
  static const String _supabaseAnonKeyFromEnv = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: '',
  );

  /// Short git SHA baked at build time via
  /// `flutter build ios ... --dart-define=GIT_SHA=$(git rev-parse --short HEAD)`.
  /// Surfaced in the bottom-right of the Pulse Mark footer so we can confirm
  /// at a glance which commit is running on device after a rebuild.
  /// Defaults to `dev` when not passed.
  static const String buildSha =
      String.fromEnvironment('GIT_SHA', defaultValue: 'dev');

  /// Kill-switch for the native audio-muxing path inside the line-drawing
  /// converter. Defaults to `true` — the post-PR-#39 behaviour that includes
  /// the audio track in every converted clip.
  ///
  /// Flip to `false` at build time to fall back to the pre-PR-#39 behaviour
  /// (video-only output, no audio track in the line-drawing file). Use this
  /// when a regression in the audio mux is blocking device QA and you need to
  /// keep capturing + converting while the root cause is investigated.
  ///
  /// Invocation (from the repo root):
  ///
  /// ```sh
  /// cd app && flutter build ios --debug --simulator \
  ///   --dart-define=GIT_SHA=$(git -C /Users/chm/dev/TrainMe rev-parse --short HEAD) \
  ///   --dart-define=HOMEFIT_AUDIO_MUX_ENABLED=false
  /// ```
  ///
  /// For a physical-device release build, add the same flag to `install-device.sh`.
  ///
  /// The Dart side simply passes this value as `includeAudio` over the
  /// platform channel when false, reusing the existing Swift branch that
  /// cleanly skips the audio reader/writer setup (see the
  /// `if includeAudio, let audioTrack = ...` guard in
  /// `VideoConverterChannel.swift`'s `convertVideo`).
  static const bool audioMuxEnabled = bool.fromEnvironment(
    'HOMEFIT_AUDIO_MUX_ENABLED',
    defaultValue: true,
  );

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
      'studio.homefit.app://login-callback';

  /// Signup-bonus credits granted to a brand-new practice by the
  /// `bootstrap_practice_for_user` RPC when the user signs up organically
  /// (no referral code claimed). Lets them try a couple of publishes
  /// before hitting the paywall. Referral-code claimants get +5 more on
  /// top via `claim_referral_code` → 8 total.
  static const int organicSignupBonusCredits = 3;

  /// The bonus a referee gets on top of the organic signup bonus when
  /// they claim a referral code via `/r/{code}`. Matches the +5 inserted
  /// by `claim_referral_code` (see schema_milestone_m_credit_model.sql).
  static const int referralSignupBonusCredits = 5;

  /// Duration threshold for the 2-credit tier, in seconds.
  /// Plans whose estimated total duration exceeds this are charged 2 credits;
  /// all others are 1 credit. 75 minutes = 4500 seconds.
  static const int creditDurationThresholdSeconds = 75 * 60; // 4500s
}

/// Credit cost for a plan based on estimated total duration of non-rest
/// exercises.
///
/// Model (duration-based):
///   - 1 credit for any plan where estimated duration ≤ 75 minutes
///   - 2 credits for any plan where estimated duration > 75 minutes
///
/// The 75-minute threshold is purely anti-abuse; the vast majority of
/// real-world plans fall well under it.
///
/// [nonRestExerciseDurationSeconds] is the sum of
/// `ExerciseCapture.estimatedDurationSeconds` for every non-rest exercise
/// in the session. The caller computes this — see `upload_service.dart`.
///
/// An empty plan (duration == 0) is billed at 1 credit so the audit row
/// is never zero.
int creditCostForDuration(int nonRestExerciseDurationSeconds) {
  if (nonRestExerciseDurationSeconds > AppConfig.creditDurationThresholdSeconds) {
    return 2;
  }
  return 1;
}
