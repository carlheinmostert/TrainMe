import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'client.dart';

/// Offline-first cache row for a client. Mirrors the cloud `clients`
/// table plus three sync-metadata columns.
///
/// Persisted in SQLite table `cached_clients` (schema v17, extended to
/// v21 for sticky defaults). Read by Home / ClientSessions /
/// PracticeSwitcher UIs to decouple rendering from the network. Written
/// by [SyncService] on both cloud pulls and local mutations (which queue
/// a [PendingOp] for eventual flush).
///
/// Staleness rule: `synced_at == null` means the row has never been
/// confirmed by the cloud (likely an offline-created row awaiting
/// sync). `dirty == 1` means local changes haven't been flushed yet.
@immutable
class CachedClient {
  /// Client uuid. For offline-created clients this is generated on-device
  /// via `const Uuid().v4()` and later passed to the cloud through
  /// `upsert_client_with_id(p_id, ...)` so the local row survives the
  /// sync without re-addressing.
  final String id;
  final String practiceId;
  final String name;

  /// `{line_drawing: bool, grayscale: bool, original: bool}` as the
  /// cloud stores it. `line_drawing` is always true (platform baseline).
  final bool grayscaleAllowed;
  final bool colourAllowed;

  /// Sticky per-client exercise defaults (Milestone R / Wave 8).
  ///
  /// Free-form JSON map whose keys mirror the wire-side
  /// `set_client_exercise_default` field names:
  ///
  ///   reps                     → int
  ///   sets                     → int
  ///   hold_seconds             → int
  ///   include_audio            → bool
  ///   preferred_treatment      → String ('line'|'grayscale'|'original')
  ///   prep_seconds             → int
  ///   custom_duration_seconds  → int | null
  ///
  /// Absent keys fall through to the global [StudioDefaults]. The
  /// propagation direction is FORWARD-ONLY: new captures for this
  /// client pre-fill from this map, and any override written on the
  /// card replaces the value here so the next new capture inherits
  /// the latest choice.
  final Map<String, dynamic> clientExerciseDefaults;

  /// Epoch-ms of the last successful cloud pull that confirmed this
  /// row. Null for offline-created rows that haven't synced yet.
  final int? syncedAt;

  /// 1 = local changes pending; 0 = in-sync.
  final bool dirty;

  /// 1 = locally tombstoned; waiting for cloud delete to confirm.
  /// Today unused (delete-client isn't wired to the queue yet — Carl
  /// asked for create / rename / consent only) but present so the
  /// column exists once delete lands.
  final bool deleted;

  const CachedClient({
    required this.id,
    required this.practiceId,
    required this.name,
    this.grayscaleAllowed = false,
    this.colourAllowed = false,
    this.clientExerciseDefaults = const <String, dynamic>{},
    this.syncedAt,
    this.dirty = false,
    this.deleted = false,
  });

  /// Hydrate from the cloud's `list_practice_clients` JSON shape. The
  /// resulting row is `synced_at=now()` + `dirty=0`.
  factory CachedClient.fromCloudJson(
    Map<String, dynamic> json, {
    required int nowMs,
  }) {
    final consent = json['video_consent'];
    final consentMap = consent is Map
        ? Map<String, dynamic>.from(consent)
        : const <String, dynamic>{};
    final defaults = json['client_exercise_defaults'];
    final defaultsMap = defaults is Map
        ? Map<String, dynamic>.from(defaults)
        : const <String, dynamic>{};
    return CachedClient(
      id: json['id'] as String,
      practiceId: (json['practice_id'] ?? '') as String,
      name: (json['name'] ?? '') as String,
      grayscaleAllowed: consentMap['grayscale'] == true,
      colourAllowed: consentMap['original'] == true || consentMap['colour'] == true,
      clientExerciseDefaults: defaultsMap,
      syncedAt: nowMs,
      dirty: false,
      deleted: false,
    );
  }

  /// Hydrate from a SQLite row.
  factory CachedClient.fromMap(Map<String, dynamic> row) {
    final consentStr = row['video_consent'] as String?;
    var grayscale = false;
    var colour = false;
    if (consentStr != null && consentStr.isNotEmpty) {
      try {
        final decoded = jsonDecode(consentStr);
        if (decoded is Map) {
          grayscale = decoded['grayscale'] == true;
          colour = decoded['original'] == true || decoded['colour'] == true;
        }
      } catch (_) {
        // Malformed JSON in cache — treat as default (both off).
      }
    }

    final defaultsStr = row['client_exercise_defaults'] as String?;
    var defaults = const <String, dynamic>{};
    if (defaultsStr != null && defaultsStr.isNotEmpty) {
      try {
        final decoded = jsonDecode(defaultsStr);
        if (decoded is Map) {
          defaults = Map<String, dynamic>.from(decoded);
        }
      } catch (_) {
        // Malformed JSON in cache — fall back to empty (every field
        // reads through to StudioDefaults).
      }
    }

    return CachedClient(
      id: row['id'] as String,
      practiceId: row['practice_id'] as String,
      name: row['name'] as String,
      grayscaleAllowed: grayscale,
      colourAllowed: colour,
      clientExerciseDefaults: defaults,
      syncedAt: row['synced_at'] as int?,
      dirty: (row['dirty'] as int? ?? 0) == 1,
      deleted: (row['deleted'] as int? ?? 0) == 1,
    );
  }

  /// Serialise to the SQLite row shape.
  Map<String, Object?> toMap() {
    return <String, Object?>{
      'id': id,
      'practice_id': practiceId,
      'name': name,
      'video_consent': jsonEncode(<String, bool>{
        'line_drawing': true,
        'grayscale': grayscaleAllowed,
        'original': colourAllowed,
      }),
      'client_exercise_defaults': jsonEncode(clientExerciseDefaults),
      'synced_at': syncedAt,
      'dirty': dirty ? 1 : 0,
      'deleted': deleted ? 1 : 0,
    };
  }

  /// Project to the public-facing [PracticeClient] shape used by UI.
  PracticeClient toPracticeClient() {
    return PracticeClient(
      id: id,
      practiceId: practiceId,
      name: name,
      colourAllowed: colourAllowed,
      grayscaleAllowed: grayscaleAllowed,
    );
  }

  CachedClient copyWith({
    String? id,
    String? practiceId,
    String? name,
    bool? grayscaleAllowed,
    bool? colourAllowed,
    Map<String, dynamic>? clientExerciseDefaults,
    int? syncedAt,
    bool? dirty,
    bool? deleted,
  }) {
    return CachedClient(
      id: id ?? this.id,
      practiceId: practiceId ?? this.practiceId,
      name: name ?? this.name,
      grayscaleAllowed: grayscaleAllowed ?? this.grayscaleAllowed,
      colourAllowed: colourAllowed ?? this.colourAllowed,
      clientExerciseDefaults:
          clientExerciseDefaults ?? this.clientExerciseDefaults,
      syncedAt: syncedAt ?? this.syncedAt,
      dirty: dirty ?? this.dirty,
      deleted: deleted ?? this.deleted,
    );
  }
}
