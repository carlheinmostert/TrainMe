/// A Practice is the multi-tenant boundary: the billing unit and the group
/// that practitioners belong to. Matches the `practices` table introduced in
/// `supabase/schema_milestone_a.sql`.
///
/// Milestone A landing purpose: have the Dart type on hand so later milestones
/// (B for auth, C for NOT-NULL enforcement, D for credit deduction) can add
/// persistence + wire-in without another model-shape change. No local SQLite
/// mirror yet — today there is only the single sentinel practice.
class Practice {
  /// Supabase-side uuid. For POV this is always [sentinelPracticeId].
  final String id;

  /// Human-readable practice name (e.g. "Carl's Practice").
  final String name;

  /// Trainer uuid of the practice owner. Nullable until Milestone B adds the
  /// trainers table and the FK.
  final String? ownerTrainerId;

  /// Row creation timestamp (server-side `now()` when the row was inserted).
  final DateTime createdAt;

  const Practice({
    required this.id,
    required this.name,
    this.ownerTrainerId,
    required this.createdAt,
  });

  /// Build from a Supabase row (snake_case keys). Tolerates missing keys so
  /// future columns don't break older clients.
  factory Practice.fromMap(Map<String, dynamic> map) {
    final created = map['created_at'];
    DateTime createdAt;
    if (created is String) {
      createdAt = DateTime.tryParse(created) ?? DateTime.now();
    } else if (created is int) {
      createdAt = DateTime.fromMillisecondsSinceEpoch(created);
    } else if (created is DateTime) {
      createdAt = created;
    } else {
      createdAt = DateTime.now();
    }
    return Practice(
      id: map['id'] as String,
      name: map['name'] as String,
      ownerTrainerId: map['owner_trainer_id'] as String?,
      createdAt: createdAt,
    );
  }

  /// Serialize for a Supabase insert/upsert. `created_at` is server-managed so
  /// we omit it.
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'owner_trainer_id': ownerTrainerId,
    };
  }

  Practice copyWith({
    String? name,
    String? ownerTrainerId,
  }) {
    return Practice(
      id: id,
      name: name ?? this.name,
      ownerTrainerId: ownerTrainerId ?? this.ownerTrainerId,
      createdAt: createdAt,
    );
  }
}
