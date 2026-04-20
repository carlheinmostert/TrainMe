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
}

String _opTypeToWire(PendingOpType t) {
  switch (t) {
    case PendingOpType.upsertClient:
      return 'upsert_client';
    case PendingOpType.renameClient:
      return 'rename_client';
    case PendingOpType.setConsent:
      return 'set_consent';
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
    required int nowMs,
  }) {
    return PendingOp(
      id: opId,
      type: PendingOpType.setConsent,
      payload: <String, dynamic>{
        'client_id': clientId,
        'grayscale_allowed': grayscaleAllowed,
        'colour_allowed': colourAllowed,
      },
      createdAt: nowMs,
    );
  }
}
