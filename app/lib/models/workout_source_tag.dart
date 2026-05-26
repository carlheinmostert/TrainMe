/// M29 (2026-05-26) — source tag for a workout row.
///
/// Shared vocabulary with the portal — the values match the TypeScript
/// `WorkoutSourceTag` const union in `web-portal/src/lib/supabase/api.ts`.
/// When the inbound-shared-plan ingest wave lands, both surfaces will
/// switch on `sharedByPractitioner` together; today only `self` is
/// reachable.
enum WorkoutSourceTag {
  /// The practitioner is both the operator (captured the workout) and
  /// the subject (the body in the footage). This is the only value
  /// the live system produces today.
  self('self'),

  /// RESERVED — the workout was published by another practitioner and
  /// shared inbound. Wired but not reachable until the shared-plan
  /// ingestion wave ships.
  sharedByPractitioner('shared_by_practitioner');

  const WorkoutSourceTag(this.wireValue);

  /// String form used in DB rows and the portal type system. Stays
  /// stable across releases — Dart-only renames don't affect what the
  /// server emits.
  final String wireValue;

  /// Parse the wire-form back into the enum. Any unrecognised value
  /// (including null) maps to [self] so a future server tag the mobile
  /// app doesn't yet understand renders as the safe default rather than
  /// crashing a list. Parity with the portal's `mapMyWorkoutRow` fallback.
  static WorkoutSourceTag fromWire(String? raw) {
    switch (raw) {
      case 'shared_by_practitioner':
        return WorkoutSourceTag.sharedByPractitioner;
      case 'self':
      default:
        return WorkoutSourceTag.self;
    }
  }
}
