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

/// One playable set inside an [ExerciseCapture].
///
/// Wave: per-set DOSE relational model. Each row carries reps, hold,
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
    this.weightKg,
    this.breatherSecondsAfter = 60,
  });

  /// Mint a fresh set with a generated uuid.
  factory ExerciseSet.create({
    required int position,
    int reps = 10,
    int holdSeconds = 0,
    double? weightKg,
    int breatherSecondsAfter = 30,
  }) {
    return ExerciseSet(
      id: const Uuid().v4(),
      position: position,
      reps: reps,
      holdSeconds: holdSeconds,
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
    Object? weightKg = _kSentinel,
    int? breatherSecondsAfter,
  }) {
    return ExerciseSet(
      id: id ?? this.id,
      position: position ?? this.position,
      reps: reps ?? this.reps,
      holdSeconds: holdSeconds ?? this.holdSeconds,
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
        other.weightKg == weightKg &&
        other.breatherSecondsAfter == breatherSecondsAfter;
  }

  @override
  int get hashCode => Object.hash(
        id,
        position,
        reps,
        holdSeconds,
        weightKg,
        breatherSecondsAfter,
      );

  @override
  String toString() =>
      'ExerciseSet(pos=$position reps=$reps hold=${holdSeconds}s '
      'weight=${weightKg ?? "BW"} breather=${breatherSecondsAfter}s)';
}
