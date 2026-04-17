import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart' hide Session;
import '../config.dart';
import '../models/session.dart';
import '../models/exercise_capture.dart';
import 'local_storage_service.dart';

// TODO: move to background URLSession for true non-blocking publish.
// Today the upload runs on the Dart isolate tied to the app lifecycle; the
// CLAUDE.md "non-blocking publish" claim is aspirational. A future pass should
// hand media uploads to a native background URLSession / WorkManager so the
// bio can background/kill the app mid-publish without losing progress.

/// Outcome of a publish attempt. Exhaustive via the three factories:
/// [PublishResult.success], [PublishResult.preflightFailed],
/// [PublishResult.networkFailed].
class PublishResult {
  /// When [success] is true, [url] and [version] are set. Otherwise they are
  /// null and one of [missingFiles] / [error] is populated.
  final bool success;
  final String? url;
  final int? version;

  /// Credits charged for this publish (computed via [creditCostFor]). Set
  /// only on success; null otherwise. Milestone A: audit-only — the ledger
  /// is not decremented yet. Future UI can show "Used N credits".
  final int? creditsCharged;

  /// Exercises whose local media file was missing at pre-flight. Non-null
  /// only for [PublishResult.preflightFailed].
  final List<String>? missingFiles;

  /// Underlying exception if the publish failed after pre-flight.
  final Object? error;

  const PublishResult._({
    required this.success,
    this.url,
    this.version,
    this.creditsCharged,
    this.missingFiles,
    this.error,
  });

  /// Successful publish.
  factory PublishResult.success({
    required String url,
    required int version,
    required int creditsCharged,
  }) =>
      PublishResult._(
        success: true,
        url: url,
        version: version,
        creditsCharged: creditsCharged,
      );

  /// Pre-flight validation failure. Nothing was uploaded; no plan state
  /// changed on Supabase.
  factory PublishResult.preflightFailed({required List<String> missing}) =>
      PublishResult._(success: false, missingFiles: List.unmodifiable(missing));

  /// Network/remote failure after pre-flight passed. Media may have been
  /// uploaded but the plan version was NOT bumped.
  factory PublishResult.networkFailed({required Object error}) =>
      PublishResult._(success: false, error: error);

  /// Convenience: was this a pre-flight failure?
  bool get isPreflightFailure => !success && missingFiles != null;

  /// Convenience: was this a network/remote failure?
  bool get isNetworkFailure => !success && error != null;

  /// Human-readable error summary, suitable for snackbar display and storage
  /// in the `last_publish_error` column. Truncated to 500 chars.
  String toErrorString() {
    String s;
    if (isPreflightFailure) {
      final names = missingFiles!.join(', ');
      s = 'Missing local file(s) for exercise(s): $names';
    } else if (isNetworkFailure) {
      s = error.toString();
    } else {
      s = 'Unknown publish error';
    }
    return s.length > 500 ? s.substring(0, 500) : s;
  }
}

/// Handles uploading a completed plan to Supabase and generating a
/// shareable link.
///
/// Architecture: Layer 3 of the three decoupled async layers.
/// Nothing touches the network until the bio taps Send. Only converted
/// (line drawing) files are uploaded — raw footage stays on device.
class UploadService {
  final LocalStorageService _storage;
  final _supabase = Supabase.instance.client;

  /// Storage bucket name for exercise media assets.
  static const _bucket = 'media';

  UploadService({required LocalStorageService storage}) : _storage = storage;

  /// Upload all converted assets for a session, create/update the plan
  /// record in the backend, and return the result.
  ///
  /// Publish ordering (not a true transaction, but close):
  ///   1. Pre-flight — verify every non-rest exercise has an existing local
  ///      file. If anything is missing, return [PublishResult.preflightFailed]
  ///      without touching Supabase.
  ///   2. Upload media + thumbnails to the `media` bucket.
  ///   3. Insert the NEW exercise rows (single batched insert).
  ///   4. Delete OLD exercise rows for this plan where id is NOT in the new
  ///      id set — removes leftovers from previous publishes.
  ///   5. Upsert the plan row with the bumped version LAST. Until this step,
  ///      web-player clients still see the previous version's exercise set.
  ///
  /// If any step after pre-flight fails, the plan row's version is NOT
  /// bumped and a [PublishResult.networkFailed] is returned.
  ///
  /// Precondition: all exercises should have [ConversionStatus.done]. The
  /// caller should check [Session.allConversionsComplete] first.
  Future<PublishResult> uploadPlan(Session session) async {
    // ------------------------------------------------------------------
    // Step 1: Pre-flight validation (no network I/O)
    // ------------------------------------------------------------------
    final missing = <String>[];
    for (final exercise in session.exercises) {
      if (exercise.isRest) continue;
      final path = exercise.absoluteConvertedFilePath ?? exercise.absoluteRawFilePath;
      if (path.isEmpty || !File(path).existsSync()) {
        missing.add(exercise.name ?? exercise.id);
      }
    }
    if (missing.isNotEmpty) {
      await _recordFailure(
        session,
        'Missing local file(s) for exercise(s): ${missing.join(', ')}',
      );
      return PublishResult.preflightFailed(missing: missing);
    }

    try {
      // ----------------------------------------------------------------
      // Step 2: Upload media files
      // ----------------------------------------------------------------
      final mediaUrls = <String, String>{}; // exerciseId -> media URL
      final thumbUrls = <String, String?>{}; // exerciseId -> thumbnail URL

      for (final exercise in session.exercises) {
        if (exercise.isRest) continue;

        final filePath =
            exercise.absoluteConvertedFilePath ?? exercise.absoluteRawFilePath;
        final file = File(filePath);
        final ext = p.extension(filePath);
        final storagePath = '${session.id}/${exercise.id}$ext';
        await _supabase.storage
            .from(_bucket)
            .upload(storagePath, file, fileOptions: const FileOptions(upsert: true));
        mediaUrls[exercise.id] =
            _supabase.storage.from(_bucket).getPublicUrl(storagePath);

        final thumbPath = exercise.absoluteThumbnailPath;
        if (thumbPath != null) {
          final thumbFile = File(thumbPath);
          if (await thumbFile.exists()) {
            final thumbStoragePath = '${session.id}/${exercise.id}_thumb.jpg';
            await _supabase.storage.from(_bucket).upload(
                  thumbStoragePath,
                  thumbFile,
                  fileOptions: const FileOptions(upsert: true),
                );
            thumbUrls[exercise.id] =
                _supabase.storage.from(_bucket).getPublicUrl(thumbStoragePath);
          }
        }
      }

      // ----------------------------------------------------------------
      // Step 3: Upsert plan row FIRST so the exercises.plan_id foreign key
      // is satisfied. The original design did plan-upsert-last as a "pointer
      // flip" but the FK constraint forbids it on first publish. Web-player
      // reads are atomic via the get_plan_full RPC, so the brief window
      // where the plan version is new but exercises are still old is fine.
      // ----------------------------------------------------------------
      final newVersion = session.version + 1;
      final nonRestCount = session.exercises.where((e) => !e.isRest).length;
      // Milestone A: every publish stamps the sentinel practice id. When auth
      // lands (Milestone B) this resolves to the trainer's active practice.
      final practiceId =
          session.practiceId ?? AppConfig.sentinelPracticeId;
      await _supabase.from('plans').upsert({
        'id': session.id,
        'client_name': session.clientName,
        'title': session.displayTitle,
        // Supabase PostgREST accepts jsonb as a Dart Map — do NOT json.encode.
        'circuit_cycles': session.circuitCycles,
        'preferred_rest_interval_seconds': session.preferredRestIntervalSeconds,
        'exercise_count': nonRestCount,
        'version': newVersion,
        'created_at': session.createdAt.toIso8601String(),
        'sent_at': DateTime.now().toIso8601String(),
        'practice_id': practiceId,
      });

      // ----------------------------------------------------------------
      // Step 4: Insert new exercise rows (batched). FK is now satisfied.
      // ----------------------------------------------------------------
      final exerciseRows = session.exercises
          .map((e) => {
                'id': e.id,
                'plan_id': session.id,
                'position': e.position,
                'name': e.name,
                'media_url': mediaUrls[e.id],
                'thumbnail_url': thumbUrls[e.id],
                'media_type': e.mediaType.name,
                'reps': e.reps,
                'sets': e.sets,
                'hold_seconds': e.holdSeconds,
                'notes': e.notes,
                'circuit_id': e.circuitId,
                'include_audio': e.includeAudio,
                'custom_duration_seconds': e.customDurationSeconds,
              })
          .toList();

      if (exerciseRows.isNotEmpty) {
        // Upsert so a re-publish of an unchanged exercise set doesn't PK-collide.
        await _supabase.from('exercises').upsert(exerciseRows);
      }

      // ----------------------------------------------------------------
      // Step 5: Delete OLD exercise rows for this plan that are not in the
      // new id set. Rest-only sessions (empty exerciseRows) clear everything.
      // ----------------------------------------------------------------
      final newIds = exerciseRows.map((r) => r['id'] as String).toList();
      var deleteQuery =
          _supabase.from('exercises').delete().eq('plan_id', session.id);
      if (newIds.isNotEmpty) {
        // Postgrest .not('id', 'in', [...]) serializes to not.in.(id1,id2,...)
        deleteQuery = deleteQuery.not('id', 'in', newIds);
      }
      await deleteQuery;

      // ----------------------------------------------------------------
      // Step 6 (Milestone A): append an audit row to `plan_issuances`.
      // Records who published which plan-version at what size for what
      // credit cost. NO ledger deduction yet — that lands in Milestone D
      // together with the PayFast webhook. If this insert fails (e.g.
      // schema_milestone_a.sql hasn't been run yet) we swallow the error:
      // the publish itself already succeeded and the bio must not be
      // blocked by an audit-table hiccup. Once the migration is applied
      // everywhere this try/catch can be removed.
      // ----------------------------------------------------------------
      final creditsCharged = creditCostFor(nonRestCount);
      try {
        await _supabase.from('plan_issuances').insert({
          'plan_id': session.id,
          'practice_id': practiceId,
          'trainer_id': AppConfig.sentinelTrainerId,
          'version': newVersion,
          'exercise_count': nonRestCount,
          'credits_charged': creditsCharged,
          'issued_at': DateTime.now().toIso8601String(),
        });
      } catch (_) {
        // Audit write is best-effort for Milestone A. Do not fail the publish.
      }

      // ----------------------------------------------------------------
      // Success — persist new local state.
      // ----------------------------------------------------------------
      final planUrl = '${AppConfig.webPlayerBaseUrl}/p/${session.id}';
      final now = DateTime.now();
      final updated = session.copyWith(
        sentAt: now,
        planUrl: planUrl,
        version: newVersion,
        lastPublishedAt: now,
      );
      await _storage.saveSession(updated);
      await _recordSuccess(session.id);

      return PublishResult.success(
        url: planUrl,
        version: newVersion,
        creditsCharged: creditsCharged,
      );
    } catch (e) {
      // Media may be orphaned in storage, exercises may be half-written.
      // Plan row version was NOT bumped, so readers still see the previous
      // exercise set for this plan_id.
      await _recordFailure(session, e.toString());
      return PublishResult.networkFailed(error: e);
    }
  }

  // ---------------------------------------------------------------------
  // Adapter: write publish error / attempt count directly to the sessions
  // table. These columns are added by schema migration v11; if the migration
  // hasn't run yet the UPDATE silently no-ops (the column-missing error is
  // swallowed). Once schema v11 ships, Session.toMap() should also learn these
  // fields and this adapter can be retired.
  // ---------------------------------------------------------------------

  /// On failure: bump `publish_attempt_count`, set `last_publish_error`.
  Future<void> _recordFailure(Session session, String error) async {
    final truncated = error.length > 500 ? error.substring(0, 500) : error;
    try {
      await _storage.db.rawUpdate(
        'UPDATE sessions '
        'SET last_publish_error = ?, '
        '    publish_attempt_count = COALESCE(publish_attempt_count, 0) + 1 '
        'WHERE id = ?',
        [truncated, session.id],
      );
    } catch (_) {
      // Schema v11 not applied yet — skip. Not fatal; publish flow
      // has already returned its PublishResult.
    }
  }

  /// On success: clear `last_publish_error`. Keep `publish_attempt_count`
  /// so the UI can show "took N tries" history if we ever want it.
  Future<void> _recordSuccess(String sessionId) async {
    try {
      await _storage.db.rawUpdate(
        'UPDATE sessions SET last_publish_error = NULL WHERE id = ?',
        [sessionId],
      );
    } catch (_) {
      // Schema v11 not applied yet — skip.
    }
  }

  /// Read the last publish error for a session, if any. Returns null when
  /// the column doesn't exist yet (schema v11 not applied) or no error is
  /// stored.
  Future<String?> getLastPublishError(String sessionId) async {
    try {
      final rows = await _storage.db.query(
        'sessions',
        columns: ['last_publish_error'],
        where: 'id = ?',
        whereArgs: [sessionId],
      );
      if (rows.isEmpty) return null;
      final v = rows.first['last_publish_error'];
      return v is String && v.isNotEmpty ? v : null;
    } catch (_) {
      return null;
    }
  }
}

/// Legacy name kept so existing callers/imports don't break while the
/// migration lands. Prefer [PublishResult.success].
@Deprecated('Use PublishResult.success')
class UploadResult {
  final String url;
  final int version;
  const UploadResult({required this.url, required this.version});
}
