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

  /// `{line_drawing: bool, grayscale: bool, original: bool, avatar: bool,
  /// analytics_allowed: bool}` as the cloud stores it. `line_drawing` is
  /// always true (platform baseline). `avatar` (Wave 30) gates the body-
  /// focus avatar capture surface on the client detail view; default false.
  /// `analytics_allowed` (Wave 17) gates anonymous usage analytics;
  /// default true.
  final bool grayscaleAllowed;
  final bool colourAllowed;
  final bool avatarAllowed;
  final bool analyticsAllowed;

  /// Wave 30 — relative path inside the `raw-archive` bucket of the
  /// body-focus blurred avatar PNG. Shape `{practiceId}/{clientId}/avatar.png`.
  /// Null = no avatar yet (UI falls back to initials monogram).
  final String? avatarPath;

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

  /// Wave 29 — epoch-ms of the most recent `set_client_video_consent`
  /// call that explicitly confirmed this client's video consent.
  /// Publish flow gates on non-NULL: NULL clients always trip the
  /// confirmation sheet before the publish proceeds.
  final int? consentConfirmedAt;

  /// 2026-05-13 — epoch-ms of the first-ever `set_client_video_consent`
  /// call for this client. NULL means the practitioner has never
  /// explicitly toggled consent for this client; the
  /// `ClientSessionsScreen` auto-opens the consent sheet on entry when
  /// this column is NULL. Stamped server-side by the RPC AND locally by
  /// `SyncService.queueSetConsent` so the auto-open suppresses the
  /// instant the practitioner saves, without waiting for a sync round-
  /// trip. See migration `20260513065845_consent_explicitly_set_at.sql`.
  final int? consentExplicitlySetAt;

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
    this.avatarAllowed = false,
    this.analyticsAllowed = true,
    this.avatarPath,
    this.clientExerciseDefaults = const <String, dynamic>{},
    this.consentConfirmedAt,
    this.consentExplicitlySetAt,
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
    final confirmed = json['consent_confirmed_at'];
    int? confirmedMs;
    if (confirmed is String) {
      confirmedMs = DateTime.tryParse(confirmed)?.millisecondsSinceEpoch;
    } else if (confirmed is int) {
      confirmedMs = confirmed;
    }
    final explicit = json['consent_explicitly_set_at'];
    int? explicitMs;
    if (explicit is String) {
      explicitMs = DateTime.tryParse(explicit)?.millisecondsSinceEpoch;
    } else if (explicit is int) {
      explicitMs = explicit;
    }
    final pathRaw = json['avatar_path'];
    return CachedClient(
      id: json['id'] as String,
      practiceId: (json['practice_id'] ?? '') as String,
      name: (json['name'] ?? '') as String,
      grayscaleAllowed: consentMap['grayscale'] == true,
      colourAllowed: consentMap['original'] == true || consentMap['colour'] == true,
      avatarAllowed: consentMap['avatar'] == true,
      analyticsAllowed: consentMap['analytics_allowed'] != false,
      avatarPath:
          pathRaw is String && pathRaw.isNotEmpty ? pathRaw : null,
      clientExerciseDefaults: defaultsMap,
      consentConfirmedAt: confirmedMs,
      consentExplicitlySetAt: explicitMs,
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
    var avatar = false;
    var analytics = true;
    if (consentStr != null && consentStr.isNotEmpty) {
      try {
        final decoded = jsonDecode(consentStr);
        if (decoded is Map) {
          grayscale = decoded['grayscale'] == true;
          colour = decoded['original'] == true || decoded['colour'] == true;
          avatar = decoded['avatar'] == true;
          analytics = decoded['analytics_allowed'] != false;
        }
      } catch (_) {
        // Malformed JSON in cache — treat as default (all off).
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

    final pathRaw = row['avatar_path'];
    return CachedClient(
      id: row['id'] as String,
      practiceId: row['practice_id'] as String,
      name: row['name'] as String,
      grayscaleAllowed: grayscale,
      colourAllowed: colour,
      avatarAllowed: avatar,
      analyticsAllowed: analytics,
      avatarPath:
          pathRaw is String && pathRaw.isNotEmpty ? pathRaw : null,
      clientExerciseDefaults: defaults,
      consentConfirmedAt: row['consent_confirmed_at'] as int?,
      consentExplicitlySetAt: row['consent_explicitly_set_at'] as int?,
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
      'video_consent': jsonEncode(<String, dynamic>{
        'line_drawing': true,
        'grayscale': grayscaleAllowed,
        'original': colourAllowed,
        'avatar': avatarAllowed,
        'analytics_allowed': analyticsAllowed,
      }),
      'avatar_path': avatarPath,
      'client_exercise_defaults': jsonEncode(clientExerciseDefaults),
      'consent_confirmed_at': consentConfirmedAt,
      'consent_explicitly_set_at': consentExplicitlySetAt,
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
      avatarAllowed: avatarAllowed,
      analyticsAllowed: analyticsAllowed,
      avatarPath: avatarPath,
      consentExplicitlySetAt: consentExplicitlySetAt,
    );
  }

  CachedClient copyWith({
    String? id,
    String? practiceId,
    String? name,
    bool? grayscaleAllowed,
    bool? colourAllowed,
    bool? avatarAllowed,
    bool? analyticsAllowed,
    String? avatarPath,
    bool clearAvatarPath = false,
    Map<String, dynamic>? clientExerciseDefaults,
    int? consentConfirmedAt,
    int? consentExplicitlySetAt,
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
      avatarAllowed: avatarAllowed ?? this.avatarAllowed,
      analyticsAllowed: analyticsAllowed ?? this.analyticsAllowed,
      avatarPath: clearAvatarPath ? null : (avatarPath ?? this.avatarPath),
      clientExerciseDefaults:
          clientExerciseDefaults ?? this.clientExerciseDefaults,
      consentConfirmedAt: consentConfirmedAt ?? this.consentConfirmedAt,
      consentExplicitlySetAt:
          consentExplicitlySetAt ?? this.consentExplicitlySetAt,
      syncedAt: syncedAt ?? this.syncedAt,
      dirty: dirty ?? this.dirty,
      deleted: deleted ?? this.deleted,
    );
  }
}
