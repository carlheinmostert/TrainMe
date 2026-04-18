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

/// Outcome of a publish attempt. Exhaustive via the four factories:
/// [PublishResult.success], [PublishResult.preflightFailed],
/// [PublishResult.networkFailed], [PublishResult.insufficientCredits].
class PublishResult {
  /// When [success] is true, [url] and [version] are set. Otherwise they are
  /// null and one of [missingFiles] / [error] / (balance+required) is set.
  final bool success;
  final String? url;
  final int? version;

  /// Credits charged for this publish (computed via [creditCostFor]). Set
  /// only on success; null otherwise. Milestone D: reflects the DB truth —
  /// the `consume_credit` RPC actually decrements the ledger. Future UI can
  /// show "Used N credits".
  final int? creditsCharged;

  /// Exercises whose local media file was missing at pre-flight. Non-null
  /// only for [PublishResult.preflightFailed].
  final List<String>? missingFiles;

  /// Underlying exception if the publish failed after pre-flight.
  final Object? error;

  /// Current credit balance for the practice at the moment the publish was
  /// rejected. Non-null only for [PublishResult.insufficientCredits].
  final int? balance;

  /// Credits the publish would have cost. Non-null only for
  /// [PublishResult.insufficientCredits].
  final int? required;

  /// Practice id that the insufficient-credits rejection applies to. Non-null
  /// only for [PublishResult.insufficientCredits]. Handy for the D2 UI so the
  /// "buy credits" CTA can deep-link straight to the right practice page.
  final String? practiceId;

  const PublishResult._({
    required this.success,
    this.url,
    this.version,
    this.creditsCharged,
    this.missingFiles,
    this.error,
    this.balance,
    this.required,
    this.practiceId,
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

  /// Practice does not have enough credits to publish this plan. No network
  /// I/O past the balance check; no plan state changed on Supabase.
  factory PublishResult.insufficientCredits({
    required int balance,
    required int required,
    required String practiceId,
  }) =>
      PublishResult._(
        success: false,
        balance: balance,
        required: required,
        practiceId: practiceId,
      );

  /// Convenience: was this a pre-flight failure?
  bool get isPreflightFailure => !success && missingFiles != null;

  /// Convenience: was this a network/remote failure?
  bool get isNetworkFailure => !success && error != null;

  /// Convenience: was this an insufficient-credits rejection?
  bool get isInsufficientCredits => !success && required != null;

  /// Human-readable error summary, suitable for snackbar display and storage
  /// in the `last_publish_error` column. Truncated to 500 chars.
  String toErrorString() {
    String s;
    if (isPreflightFailure) {
      final names = missingFiles!.join(', ');
      s = 'Missing local file(s) for exercise(s): $names';
    } else if (isInsufficientCredits) {
      s = 'Practice has $balance credits, need $required. '
          'Buy more via manage.homefit.studio.';
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

  /// Read the current credit balance for [practiceId] via the
  /// `practice_credit_balance` Postgres function. Returns null on any error
  /// (network hiccup, RLS rejection, function missing) so the caller can
  /// decide whether to soft-fail or abort. We prefer null to zero here so a
  /// transient error doesn't get mistaken for "you're out of credits".
  Future<int?> _getPracticeBalance(String practiceId) async {
    try {
      final result = await _supabase.rpc(
        'practice_credit_balance',
        params: {'p_practice_id': practiceId},
      );
      if (result is int) return result;
      if (result is num) return result.toInt();
      if (result is String) return int.tryParse(result);
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Upload all converted assets for a session, create/update the plan
  /// record in the backend, and return the result.
  ///
  /// Publish ordering (not a true transaction, but close):
  ///
  ///   1. Pre-flight — verify every non-rest exercise has an existing local
  ///      file. If anything is missing, return [PublishResult.preflightFailed]
  ///      without touching Supabase.
  ///   2. Credit balance pre-check — read the practice balance and abort with
  ///      [PublishResult.insufficientCredits] before any network I/O heavier
  ///      than a single RPC. This is best-effort; step 3b is the race-safe
  ///      source of truth.
  ///   3a. Ensure the plan row exists (no version bump yet) so the FK from
  ///      `credit_ledger.plan_id` to `plans.id` is satisfied on first-ever
  ///      publish. Re-publishes hit this as an idempotent upsert that does
  ///      NOT touch the version — that stays pinned to `session.version`.
  ///   3b. Atomically consume credits via `consume_credit` RPC. If this
  ///      returns `{ok: false}` the publish aborts — the fn is race-safe
  ///      and its answer is the truth even if the pre-check said otherwise.
  ///      Runs BEFORE the version bump so a failure in any later step
  ///      triggers the existing refund path and leaves the ledger balanced.
  ///      A non-insufficient_credits failure (network, auth, etc.) raises
  ///      with `creditConsumed=false`, so a retry sees the same un-bumped
  ///      version and computes an identical `newVersion` — no double-bump.
  ///   4. Upsert the plan row with the bumped version. Required BEFORE the
  ///      media upload so the storage RLS policy (which joins against
  ///      `plans` via the first folder segment of the object name) passes.
  ///   5. Upload media + thumbnails to the `media` bucket. The plan row now
  ///      exists, so the RLS check in the `Media upload` policy succeeds.
  ///      On failure, orphaned uploaded paths are cleaned up inside the
  ///      catch block so retries don't stack bucket garbage.
  ///   6. Upsert new exercise rows. FK to plans is already satisfied.
  ///   7. Delete stale exercise rows that are no longer in the plan.
  ///   8. Write the `plan_issuances` audit row (best-effort; swallowed).
  ///
  /// If any step AFTER `consume_credit` (3b) succeeds fails (plan upsert,
  /// media upload, exercise upsert, delete-orphans), the catch block
  /// inserts a compensating refund row into `credit_ledger` via the
  /// `refund_credit` RPC so the ledger stays balanced.
  ///
  /// Precondition: all exercises should have [ConversionStatus.done]. The
  /// caller should check [Session.allConversionsComplete] first.
  Future<PublishResult> uploadPlan(Session session) async {
    // Milestone B: the AuthGate guarantees a signed-in user at this point,
    // so any null here is a bug we want surfaced loudly (not papered over
    // with a sentinel uuid that would silently pollute audit rows).
    final currentUser = _supabase.auth.currentUser;
    if (currentUser == null) {
      throw StateError('Not signed in');
    }
    final trainerId = currentUser.id;

    // Never fall back to the Carl-sentinel practice here — a malformed local
    // session with practiceId == null must NOT silently charge Carl's tenant.
    // RLS catches it at the DB, but the client has no business picking a
    // tenant on the user's behalf. Surface the bug loudly so the publish
    // banner shows it and the bootstrap retry flow can fix it.
    final sessionPracticeId = session.practiceId;
    if (sessionPracticeId == null) {
      const msg = 'Cannot publish: session has no practiceId';
      await _recordFailure(session, msg);
      throw StateError(msg);
    }
    final practiceId = sessionPracticeId;
    final nonRestCount = session.exercises.where((e) => !e.isRest).length;
    final creditsToCharge = creditCostFor(nonRestCount);

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

    // ------------------------------------------------------------------
    // Step 2: Credit balance pre-check. Best-effort early-exit — the
    // atomic `consume_credit` RPC in Step 3 is the race-safe source of
    // truth. Null balance (RPC error) falls through; we'd rather let the
    // RPC reject than punish the bio for a transient read error.
    // ------------------------------------------------------------------
    final balance = await _getPracticeBalance(practiceId);
    if (balance != null && balance < creditsToCharge) {
      await _recordFailure(
        session,
        'Insufficient credits: have $balance, need $creditsToCharge',
      );
      return PublishResult.insufficientCredits(
        balance: balance,
        required: creditsToCharge,
        practiceId: practiceId,
      );
    }

    final newVersion = session.version + 1;

    // Tracks whether we've consumed credits so catch blocks can refund.
    bool creditConsumed = false;

    try {
      // ----------------------------------------------------------------
      // Step 3: Consume credits atomically BEFORE any plan mutation.
      //
      // Ordering rationale (aligned with the method docstring, 2026-04-18):
      // the prior ordering upserted `plans` (bumping `version`) first and
      // only called `consume_credit` afterward. If the RPC failed for any
      // reason other than `insufficient_credits` (network blip, RLS edge
      // case, transient DB error) the version was bumped server-side even
      // though no credits were taken. `creditConsumed` stayed false so the
      // refund compensator was (correctly) skipped, but a retry would then
      // re-upsert with `newVersion = session.version + 1` AGAIN, double-
      // bumping the version relative to what the user sees locally.
      //
      // New order: consume first. If the RPC raises, no plan state has
      // changed on Supabase and a retry computes the same `newVersion`
      // again — idempotent from the client's perspective.
      //
      // FK caveat: `credit_ledger.plan_id` has a FK to `plans.id`
      // (ON DELETE SET NULL, but the INSERT still requires the referenced
      // row to exist). On a re-publish the plan row already exists, so
      // the FK is satisfied. On a brand-new plan the FK would fail — so
      // we pre-insert a minimal plan row first with the CURRENT version
      // (not the bumped one). That row carries the practice_id the RLS
      // policies need, satisfies the FK, and does NOT claim a version
      // bump the client hasn't earned yet. The version bump happens in
      // Step 4 after consume_credit succeeds.
      // ----------------------------------------------------------------

      // Step 3a: ensure a plan row exists so consume_credit's FK is
      // satisfied on first-ever publish. On re-publish this is a no-op
      // `ON CONFLICT DO NOTHING` (implemented as an upsert that omits
      // every mutable column — PostgREST writes back the same values on
      // conflict). The version stays at `session.version` here.
      await _supabase.from('plans').upsert({
        'id': session.id,
        'client_name': session.clientName,
        'title': session.displayTitle,
        // Supabase PostgREST accepts jsonb as a Dart Map — do NOT json.encode.
        'circuit_cycles': session.circuitCycles,
        'preferred_rest_interval_seconds': session.preferredRestIntervalSeconds,
        'exercise_count': nonRestCount,
        // IMPORTANT: do NOT bump version here — only after consume_credit.
        'version': session.version,
        'created_at': session.createdAt.toIso8601String(),
        'practice_id': practiceId,
      });

      // Step 3b: atomic credit consumption. Source of truth for whether
      // the publish can proceed. If this returns `{ok: false}` the plan
      // row we just ensured above stays as-is (no version bump, no
      // `sent_at` update) — the plan is still at its previous published
      // state. If the RPC raises, same deal.
      final consumeResult = await _supabase.rpc(
        'consume_credit',
        params: {
          'p_practice_id': practiceId,
          'p_plan_id': session.id,
          'p_credits': creditsToCharge,
        },
      );

      final consumeMap = consumeResult is Map
          ? Map<String, dynamic>.from(consumeResult)
          : const <String, dynamic>{};
      final ok = consumeMap['ok'] == true;
      if (!ok) {
        final reportedBalance = consumeMap['balance'];
        final int resolvedBalance = reportedBalance is int
            ? reportedBalance
            : (reportedBalance is num
                ? reportedBalance.toInt()
                : (balance ?? 0));
        await _recordFailure(
          session,
          'consume_credit refused: have $resolvedBalance, need $creditsToCharge',
        );
        return PublishResult.insufficientCredits(
          balance: resolvedBalance,
          required: creditsToCharge,
          practiceId: practiceId,
        );
      }
      creditConsumed = true;

      // ----------------------------------------------------------------
      // Step 4: Now that credits are consumed, bump the plan version and
      // stamp sent_at. This is the only place `newVersion` is written;
      // any later failure (media upload, exercise upsert) triggers the
      // refund compensator below.
      // ----------------------------------------------------------------
      await _supabase.from('plans').upsert({
        'id': session.id,
        'client_name': session.clientName,
        'title': session.displayTitle,
        'circuit_cycles': session.circuitCycles,
        'preferred_rest_interval_seconds': session.preferredRestIntervalSeconds,
        'exercise_count': nonRestCount,
        'version': newVersion,
        'created_at': session.createdAt.toIso8601String(),
        'sent_at': DateTime.now().toIso8601String(),
        'practice_id': practiceId,
      });

      // ----------------------------------------------------------------
      // Step 5: Upload media files. The plan row now exists, so the
      // `Media upload` RLS policy on the `media` bucket passes.
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
      // Step 6: Upsert exercise rows (batched). FK to plans is satisfied
      // from Step 4.
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
      // Step 7: Delete OLD exercise rows for this plan that are not in
      // the new id set. Rest-only sessions (empty exerciseRows) clear
      // everything.
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
      // Step 8: append an audit row to `plan_issuances`. Records who
      // published which plan-version at what size for what credit cost.
      // The ledger is already authoritative via consume_credit; this row
      // exists for billing history / support queries. If the insert fails
      // (e.g. schema migration not applied yet) we swallow — the ledger
      // is consistent and the bio must not be blocked by an audit hiccup.
      // ----------------------------------------------------------------
      try {
        await _supabase.from('plan_issuances').insert({
          'plan_id': session.id,
          'practice_id': practiceId,
          'trainer_id': trainerId,
          'version': newVersion,
          'exercise_count': nonRestCount,
          'credits_charged': creditsToCharge,
          'issued_at': DateTime.now().toIso8601String(),
        });
      } catch (_) {
        // Audit write is best-effort. Do not fail the publish.
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
        creditsCharged: creditsToCharge,
      );
    } catch (e) {
      // Media may be orphaned in storage, exercises may be half-written.
      // If we already consumed credits, compensate with a refund row so
      // the ledger stays balanced — otherwise the bio is charged for a
      // plan that never published.
      if (creditConsumed) {
        await _refundCredits(
          practiceId: practiceId,
          planId: session.id,
          credits: creditsToCharge,
        );
      }
      await _recordFailure(session, e.toString());
      return PublishResult.networkFailed(error: e);
    }
  }

  /// Issue a compensating refund when a publish fails AFTER consume_credit
  /// has already deducted credits. Delegates to the `refund_credit`
  /// SECURITY DEFINER RPC, which:
  ///   * validates a matching consumption row exists for this plan,
  ///   * enforces the caller's practice membership inside the function,
  ///   * is idempotent (a second call for the same plan is a no-op).
  ///
  /// Network failure of the RPC has the same failure mode as the previous
  /// direct-INSERT path: the publish has already failed and we do not want
  /// a refund error to mask the original cause. The ledger may be
  /// temporarily off by one publish's worth of credits; support can
  /// reconcile via the `plan_issuances` audit rows.
  Future<void> _refundCredits({
    required String practiceId,
    required String planId,
    required int credits,
  }) async {
    try {
      await _supabase.rpc(
        'refund_credit',
        params: {'p_plan_id': planId},
      );
    } catch (_) {
      // Best-effort — see docstring above.
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
