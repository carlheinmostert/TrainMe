import 'dart:convert';

import 'package:flutter/foundation.dart';

/// The set of offline-queueable client operations. Each variant
/// carries the payload the cloud RPC needs; the SyncService
/// interprets [op_type] + [payload] to dispatch the right RPC.
///
/// More ops can be added post-MVP without changing schema — the
/// `pending_ops` table stores `op_type` + a JSON payload.
enum PendingOpType {
  /// Create-or-conflict-resolve a client. Dispatches the new
  /// `upsert_client_with_id` RPC so the client-generated uuid
  /// survives the round-trip (or gets rewired on name conflict).
  upsertClient,

  /// Rename an existing client. Dispatches `rename_client` RPC.
  renameClient,

  /// Write the client's video-viewing consent. Dispatches
  /// `set_client_video_consent` RPC.
  setConsent,

  /// Soft-delete a client (cascade to plans server-side). Dispatches
  /// `delete_client` RPC. Idempotent — replay is a no-op on an
  /// already-deleted row.
  deleteClient,

  /// Restore a previously soft-deleted client + cascaded plans.
  /// Dispatches `restore_client` RPC. Idempotent — replay on a live
  /// client is a no-op.
  restoreClient,

  /// Write a single sticky per-client exercise default (Milestone R /
  /// Wave 8). Dispatches `set_client_exercise_default` RPC. Idempotent
  /// — whole-value overwrite.
  setExerciseDefault,

  /// Write the cloud-side avatar pointer (Wave 30). Dispatches
  /// `set_client_avatar` RPC. Idempotent — whole-value overwrite, and
  /// the PNG bytes themselves are uploaded directly via
  /// [ApiClient.uploadRawArchive] outside the queue (best-effort + auto-
  /// retry through Storage's own idempotent upsert path).
  setAvatar,

  /// Rename an existing session / plan (Wave 38). Dispatches
  /// `rename_session` RPC. Idempotent — last write wins.
  renameSession,
}

String _opTypeToWire(PendingOpType t) {
  switch (t) {
    case PendingOpType.upsertClient:
      return 'upsert_client';
    case PendingOpType.renameClient:
      return 'rename_client';
    case PendingOpType.setConsent:
      return 'set_consent';
    case PendingOpType.deleteClient:
      return 'delete_client';
    case PendingOpType.restoreClient:
      return 'restore_client';
    case PendingOpType.setExerciseDefault:
      return 'set_exercise_default';
    case PendingOpType.setAvatar:
      return 'set_avatar';
    case PendingOpType.renameSession:
      return 'rename_session';
  }
}

PendingOpType? _opTypeFromWire(String s) {
  switch (s) {
    case 'upsert_client':
      return PendingOpType.upsertClient;
    case 'rename_client':
      return PendingOpType.renameClient;
    case 'set_consent':
      return PendingOpType.setConsent;
    case 'delete_client':
      return PendingOpType.deleteClient;
    case 'restore_client':
      return PendingOpType.restoreClient;
    case 'set_exercise_default':
      return PendingOpType.setExerciseDefault;
    case 'set_avatar':
      return PendingOpType.setAvatar;
    case 'rename_session':
      return PendingOpType.renameSession;
    default:
      return null;
  }
}

/// A queued mutation that needs to be pushed to the cloud.
///
/// Persisted in SQLite `pending_ops` (FIFO drain ordered by
/// `created_at`). Replays safely — every op is designed to be
/// idempotent (upsert-with-id is idempotent by construction;
/// rename is idempotent because the final name wins; consent is
/// a whole-state overwrite).
@immutable
class PendingOp {
  final String id;
  final PendingOpType type;
  final Map<String, dynamic> payload;
  final int createdAt;
  final int attempts;
  final int? lastAttemptAt;
  final String? lastError;

  const PendingOp({
    required this.id,
    required this.type,
    required this.payload,
    required this.createdAt,
    this.attempts = 0,
    this.lastAttemptAt,
    this.lastError,
  });

  factory PendingOp.fromMap(Map<String, dynamic> row) {
    final payloadRaw = row['payload'] as String? ?? '{}';
    Map<String, dynamic> payload;
    try {
      final decoded = jsonDecode(payloadRaw);
      payload = decoded is Map<String, dynamic>
          ? decoded
          : (decoded is Map ? Map<String, dynamic>.from(decoded) : <String, dynamic>{});
    } catch (_) {
      payload = <String, dynamic>{};
    }
    final type = _opTypeFromWire(row['op_type'] as String? ?? '');
    return PendingOp(
      id: row['id'] as String,
      type: type ?? PendingOpType.upsertClient,
      payload: payload,
      createdAt: row['created_at'] as int,
      attempts: row['attempts'] as int? ?? 0,
      lastAttemptAt: row['last_attempt_at'] as int?,
      lastError: row['last_error'] as String?,
    );
  }

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'id': id,
      'op_type': _opTypeToWire(type),
      'payload': jsonEncode(payload),
      'created_at': createdAt,
      'attempts': attempts,
      'last_attempt_at': lastAttemptAt,
      'last_error': lastError,
    };
  }

  PendingOp copyWith({
    int? attempts,
    int? lastAttemptAt,
    String? lastError,
  }) {
    return PendingOp(
      id: id,
      type: type,
      payload: payload,
      createdAt: createdAt,
      attempts: attempts ?? this.attempts,
      lastAttemptAt: lastAttemptAt ?? this.lastAttemptAt,
      lastError: lastError ?? this.lastError,
    );
  }

  // ---------------------------------------------------------------------------
  // Factory helpers for each op variant. Keep the payload keys here so
  // SyncService doesn't sprinkle string literals around.
  // ---------------------------------------------------------------------------

  /// Queue an `upsert_client_with_id` op. Caller provides the id
  /// because the mobile side wrote a local `cached_clients` row with
  /// that id first, and the sync loop needs to know what to rewire
  /// if the server returns a DIFFERENT id (name-conflict case).
  factory PendingOp.upsertClient({
    required String opId,
    required String clientId,
    required String practiceId,
    required String name,
    required int nowMs,
  }) {
    return PendingOp(
      id: opId,
      type: PendingOpType.upsertClient,
      payload: <String, dynamic>{
        'client_id': clientId,
        'practice_id': practiceId,
        'name': name,
      },
      createdAt: nowMs,
    );
  }

  factory PendingOp.renameClient({
    required String opId,
    required String clientId,
    required String newName,
    required int nowMs,
  }) {
    return PendingOp(
      id: opId,
      type: PendingOpType.renameClient,
      payload: <String, dynamic>{
        'client_id': clientId,
        'new_name': newName,
      },
      createdAt: nowMs,
    );
  }

  factory PendingOp.setConsent({
    required String opId,
    required String clientId,
    required bool grayscaleAllowed,
    required bool colourAllowed,
    bool? avatarAllowed,
    bool? analyticsAllowed,
    required int nowMs,
  }) {
    return PendingOp(
      id: opId,
      type: PendingOpType.setConsent,
      payload: <String, dynamic>{
        'client_id': clientId,
        'grayscale_allowed': grayscaleAllowed,
        'colour_allowed': colourAllowed,
        // Wave 30 — null means "preserve server-side value" (drain layer
        // routes to the 3-arg shim). Non-null carries the explicit intent
        // and routes to the 4-arg fn.
        if (avatarAllowed != null) 'avatar_allowed': avatarAllowed,
        // Wave 17 — analytics consent. Null = preserve existing value.
        if (analyticsAllowed != null) 'analytics_allowed': analyticsAllowed,
      },
      createdAt: nowMs,
    );
  }

  /// Queue a `set_client_avatar` op (Wave 30). Whole-value overwrite of
  /// the cloud-side pointer column. The PNG bytes go to raw-archive via
  /// the storage uploader before this op enqueues; if the upload itself
  /// failed, the local cache still records the path so a re-publish can
  /// retry.
  factory PendingOp.setAvatar({
    required String opId,
    required String clientId,
    required String? avatarPath,
    required int nowMs,
  }) {
    return PendingOp(
      id: opId,
      type: PendingOpType.setAvatar,
      payload: <String, dynamic>{
        'client_id': clientId,
        // Storing null instead of omitting the key makes the drain
        // unambiguous: "explicit clear" vs. "key missing".
        'avatar_path': avatarPath,
      },
      createdAt: nowMs,
    );
  }

  /// Queue a `delete_client` op. Cascades soft-delete to every plan
  /// owned by the client server-side (mirrored by
  /// [LocalStorageService.softDeleteClient] on the local cache).
  factory PendingOp.deleteClient({
    required String opId,
    required String clientId,
    required int nowMs,
  }) {
    return PendingOp(
      id: opId,
      type: PendingOpType.deleteClient,
      payload: <String, dynamic>{
        'client_id': clientId,
      },
      createdAt: nowMs,
    );
  }

  /// Queue a `restore_client` op. Reverses the cascade for plans whose
  /// `deleted_at` matches the client's `deleted_at` exactly.
  factory PendingOp.restoreClient({
    required String opId,
    required String clientId,
    required int nowMs,
  }) {
    return PendingOp(
      id: opId,
      type: PendingOpType.restoreClient,
      payload: <String, dynamic>{
        'client_id': clientId,
      },
      createdAt: nowMs,
    );
  }

  /// Queue a `rename_session` op (Wave 38). Idempotent — last write wins.
  /// Local cache (the `sessions` SQLite table) is updated synchronously
  /// before this op enqueues; the queued op flushes the new title to the
  /// cloud `plans.title` column on the next reconnect.
  factory PendingOp.renameSession({
    required String opId,
    required String planId,
    required String newTitle,
    required int nowMs,
  }) {
    return PendingOp(
      id: opId,
      type: PendingOpType.renameSession,
      payload: <String, dynamic>{
        'plan_id': planId,
        'new_title': newTitle,
      },
      createdAt: nowMs,
    );
  }

  /// Queue a `set_client_exercise_default` op (Milestone R / Wave 8).
  /// One op per field write — coalescing multiple rapid edits into a
  /// single op is unnecessary since each op is already a whole-value
  /// overwrite (last write wins; replaying in order yields the right
  /// final state).
  ///
  /// [value] must be JSON-encodable (bool, num, String, null). The
  /// drain layer re-hydrates it via jsonDecode and hands it to the
  /// RPC unchanged; the RPC wraps it in a jsonb literal server-side.
  factory PendingOp.setExerciseDefault({
    required String opId,
    required String clientId,
    required String field,
    required Object? value,
    required int nowMs,
  }) {
    return PendingOp(
      id: opId,
      type: PendingOpType.setExerciseDefault,
      payload: <String, dynamic>{
        'client_id': clientId,
        'field': field,
        'value': value,
      },
      createdAt: nowMs,
    );
  }
}
