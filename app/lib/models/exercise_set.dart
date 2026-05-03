import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

/// Sentinel used by [ExerciseSet.copyWith] to distinguish "leave the
/// current value alone" from "explicitly set to null". The `weightKg`
/// field is `double?`, so a plain `double?` parameter cannot tell those
/// two intents apart on its own.
class _Sentinel {
  const _Sentinel();
}

const Object _kSentinel = _Sentinel();

/// When inside a set the isometric hold contributes to the per-set
/// duration. Three modes — see the brief at
/// `feat/hold-position-3-mode`:
///
///   * [perRep]        — `reps × hold`. Legacy contract; preserved on
///                       existing rows via the v36 migration backfill so
///                       displayed durations don't shift on already-
///                       published plans.
///   * [endOfSet]      — `1 × hold`. Default for new sets — one
///                       isometric pause at the end of the set.
///   * [endOfExercise] — `hold` only when this set is the LAST set in
///                       the exercise; `0` on every prior set. Lets the
///                       practitioner schedule a single hold at the very
///                       end of the exercise (e.g. "30s plank at the end
///                       of 3 sets of push-ups").
enum HoldPosition {
  perRep('per_rep'),
  endOfSet('end_of_set'),
  endOfExercise('end_of_exercise');

  /// Wire string. Round-trips through SQLite + Supabase + the
  /// `get_plan_full` RPC. The `CHECK` constraint in
  /// `supabase/schema_wave43_hold_position.sql` accepts exactly these
  /// three values.
  final String wireValue;

  const HoldPosition(this.wireValue);

  /// Parse a wire string back to the enum. Defaults to [endOfSet] (the
  /// new-row default) on null / unknown values — defence-in-depth so a
  /// stale RPC payload can't blow up deserialisation.
  static HoldPosition fromWire(String? value) {
    if (value == null) return HoldPosition.endOfSet;
    for (final p in HoldPosition.values) {
      if (p.wireValue == value) return p;
    }
    return HoldPosition.endOfSet;
  }
}

/// One playable set inside an [ExerciseCapture].
///
/// Wave: per-set PLAN relational model. Each row carries reps, hold,
/// optional weight, and the breather AFTER that set. The set's
/// [position] is 1-based and unique within its parent exercise.
///
/// `weightKg` is nullable — null means bodyweight (no equipment / load
/// recorded). Numeric range mirrors the Postgres `numeric(5,1)` column
/// (a positive value, fractional kg).
///
/// Persisted in:
///   - SQLite table `exercise_sets` (schema v33, owned by
///     `LocalStorageService`).
///   - Supabase `public.exercise_sets` (server side, see
///     `supabase/schema_wave_per_set_dose.sql`).
///
/// Wire shape (snake_case) is the same on both sides:
///   `{position, reps, hold_seconds, weight_kg, breather_seconds_after}`
/// SQLite rows additionally carry `id` and `exercise_id` foreign keys.
@immutable
class ExerciseSet {
  /// Client-generated uuid (v4). Stable across local edits and survives
  /// the publish round-trip — the cloud table's PK matches the local row
  /// so optimistic UI mirrors the eventual server state without any
  /// re-addressing.
  final String id;

  /// 1-based ordinal inside the parent exercise. UNIQUE per exercise on
  /// both SQLite and Postgres.
  final int position;

  /// Number of reps in this set. Must be > 0 (server CHECK constraint).
  final int reps;

  /// Isometric hold seconds. 0 for non-isometric sets.
  final int holdSeconds;

  /// How [holdSeconds] contributes to the per-set duration. See
  /// [HoldPosition] for the three modes. New sets default to
  /// [HoldPosition.endOfSet]. Existing rows whose `holdSeconds > 0`
  /// were backfilled to [HoldPosition.perRep] by the v36 migration so
  /// already-published plan durations stay byte-stable.
  final HoldPosition holdPosition;

  /// Loaded weight in kg. `null` = bodyweight.
  final double? weightKg;

  /// Rest seconds after this set finishes (the "breather"). The web
  /// player + mobile preview honour this between set N and set N+1.
  /// On the LAST set of an exercise this is the breather between the
  /// final set and the next exercise (typically the auto-rest the
  /// player inserts; the value is still authored per-set so a single
  /// surface owns it).
  final int breatherSecondsAfter;

  const ExerciseSet({
    required this.id,
    required this.position,
    required this.reps,
    this.holdSeconds = 0,
    this.holdPosition = HoldPosition.endOfSet,
    this.weightKg,
    this.breatherSecondsAfter = 60,
  });

  /// Mint a fresh set with a generated uuid.
  factory ExerciseSet.create({
    required int position,
    int reps = 10,
    int holdSeconds = 0,
    HoldPosition holdPosition = HoldPosition.endOfSet,
    double? weightKg,
    int breatherSecondsAfter = 30,
  }) {
    return ExerciseSet(
      id: const Uuid().v4(),
      position: position,
      reps: reps,
      holdSeconds: holdSeconds,
      holdPosition: holdPosition,
      weightKg: weightKg,
      breatherSecondsAfter: breatherSecondsAfter,
    );
  }

  /// Deserialize from a SQLite row. Snake-case keys.
  factory ExerciseSet.fromMap(Map<String, dynamic> map) {
    return ExerciseSet(
      id: map['id'] as String,
      position: (map['position'] as num).toInt(),
      reps: (map['reps'] as num).toInt(),
      holdSeconds: (map['hold_seconds'] as num?)?.toInt() ?? 0,
      holdPosition: HoldPosition.fromWire(map['hold_position'] as String?),
      weightKg: (map['weight_kg'] as num?)?.toDouble(),
      breatherSecondsAfter:
          (map['breather_seconds_after'] as num?)?.toInt() ?? 60,
    );
  }

  /// Serialize to a SQLite-friendly map. Includes [id] but NOT
  /// `exercise_id` — the caller (LocalStorageService) attaches that.
  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'id': id,
      'position': position,
      'reps': reps,
      'hold_seconds': holdSeconds,
      'hold_position': holdPosition.wireValue,
      'weight_kg': weightKg,
      'breather_seconds_after': breatherSecondsAfter,
    };
  }

  /// Wire shape for the publish RPC payload. Identical to [toMap] minus
  /// [id]; the server generates its own uuid + foreign key.
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'position': position,
      'reps': reps,
      'hold_seconds': holdSeconds,
      'hold_position': holdPosition.wireValue,
      'weight_kg': weightKg,
      'breather_seconds_after': breatherSecondsAfter,
    };
  }

  /// Hydrate from a [get_plan_full] RPC response element. The cloud
  /// doesn't return the row's [id] inside the per-exercise `sets` array
  /// (the cloud uuid is server-side only); we mint a fresh client uuid
  /// so the local mirror stays addressable. This means a published →
  /// pulled set will have a different [id] than the same set written
  /// from the trainer device, but the value identity (position, reps,
  /// etc.) is what matters for diffs.
  factory ExerciseSet.fromRpcJson(Map<String, dynamic> json) {
    return ExerciseSet(
      id: const Uuid().v4(),
      position: (json['position'] as num).toInt(),
      reps: (json['reps'] as num).toInt(),
      holdSeconds: (json['hold_seconds'] as num?)?.toInt() ?? 0,
      holdPosition: HoldPosition.fromWire(json['hold_position'] as String?),
      weightKg: (json['weight_kg'] as num?)?.toDouble(),
      breatherSecondsAfter:
          (json['breather_seconds_after'] as num?)?.toInt() ?? 60,
    );
  }

  /// Copy with selective overrides. The [weightKg] parameter uses a
  /// sentinel so callers can distinguish "leave alone" (omit) from
  /// "explicitly set to null" (pass `weightKg: null`).
  ExerciseSet copyWith({
    String? id,
    int? position,
    int? reps,
    int? holdSeconds,
    HoldPosition? holdPosition,
    Object? weightKg = _kSentinel,
    int? breatherSecondsAfter,
  }) {
    return ExerciseSet(
      id: id ?? this.id,
      position: position ?? this.position,
      reps: reps ?? this.reps,
      holdSeconds: holdSeconds ?? this.holdSeconds,
      holdPosition: holdPosition ?? this.holdPosition,
      weightKg: identical(weightKg, _kSentinel)
          ? this.weightKg
          : (weightKg as double?),
      breatherSecondsAfter: breatherSecondsAfter ?? this.breatherSecondsAfter,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ExerciseSet &&
        other.id == id &&
        other.position == position &&
        other.reps == reps &&
        other.holdSeconds == holdSeconds &&
        other.holdPosition == holdPosition &&
        other.weightKg == weightKg &&
        other.breatherSecondsAfter == breatherSecondsAfter;
  }

  @override
  int get hashCode => Object.hash(
        id,
        position,
        reps,
        holdSeconds,
        holdPosition,
        weightKg,
        breatherSecondsAfter,
      );

  @override
  String toString() =>
      'ExerciseSet(pos=$position reps=$reps hold=${holdSeconds}s '
      '@${holdPosition.wireValue} weight=${weightKg ?? "BW"} '
      'breather=${breatherSecondsAfter}s)';
}
