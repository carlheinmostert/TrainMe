import 'package:flutter/foundation.dart';

import '../services/api_client.dart' show PracticeMembership, PracticeRole;

/// Offline-first cache row for a practice-membership. Mirrors the shape
/// returned by `ApiClient.listMyPractices()` — practice id + name + the
/// caller's role in it — so the top-bar practice chip + switcher sheet
/// can render without waiting on the network.
///
/// Persisted in SQLite table `cached_practices` (schema v17). One row
/// per membership the user holds. On pull, rows the cloud no longer
/// returns (i.e. the user left / was removed from a practice) are
/// deleted so stale entries don't accumulate.
@immutable
class CachedPractice {
  final String id;
  final String name;
  final PracticeRole role;

  /// Epoch-ms of when the practitioner joined this practice. Mirrors
  /// `practice_members.joined_at` (ordering key for the switcher).
  final int joinedAt;

  /// Epoch-ms of the last successful cloud pull. Always non-null in
  /// practice — the only way a row gets into `cached_practices` is via
  /// a cloud pull.
  final int syncedAt;

  const CachedPractice({
    required this.id,
    required this.name,
    required this.role,
    required this.joinedAt,
    required this.syncedAt,
  });

  /// Hydrate from a SQLite row.
  factory CachedPractice.fromMap(Map<String, dynamic> row) {
    return CachedPractice(
      id: row['id'] as String,
      name: row['name'] as String,
      role: (row['role'] as String) == 'owner'
          ? PracticeRole.owner
          : PracticeRole.practitioner,
      joinedAt: row['joined_at'] as int,
      syncedAt: row['synced_at'] as int,
    );
  }

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'id': id,
      'name': name,
      'role': role == PracticeRole.owner ? 'owner' : 'practitioner',
      'joined_at': joinedAt,
      'synced_at': syncedAt,
    };
  }

  /// Project to the public-facing [PracticeMembership] shape returned
  /// by [ApiClient.listMyPractices]. Kept structurally identical so
  /// callers don't branch on cache vs. live.
  PracticeMembership toMembership() {
    return PracticeMembership(id: id, name: name, role: role);
  }
}
