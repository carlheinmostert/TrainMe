import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import '../config.dart';
import '../models/session.dart';
import '../models/exercise_capture.dart';
import '../models/treatment.dart';
import 'api_client.dart';
import 'auth_service.dart';
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
/// Nothing touches the network until the bio taps Send. Publish uploads
/// converted (line-drawing) media to the public [_bucket] AND, on a
/// best-effort basis, the compressed 720p H.264 raw archive to the private
/// [ApiClient.rawArchiveBucket] so future treatment switches (B&W / original colour)
/// can stream from cloud instead of requiring the original device.
class UploadService {
  final LocalStorageService _storage;

  /// Every Supabase call in this service routes through the shared
  /// [ApiClient]. See `docs/DATA_ACCESS_LAYER.md` — direct
  /// `Supabase.instance.client.*` calls are no longer permitted from
  /// this file.
  ApiClient get _api => ApiClient.instance;

  // The private `raw-archive` bucket is the canonical home for the 720p
  // raw copies; upload goes via [ApiClient.uploadRawArchive], which
  // defines [ApiClient.rawArchiveBucket]. Keeping the name only in the
  // data-access layer preserves the single-source-of-truth rule.

  UploadService({required LocalStorageService storage}) : _storage = storage;

  /// Read the current credit balance for [practiceId] via the
  /// `practice_credit_balance` Postgres function. Returns null on any error
  /// (network hiccup, RLS rejection, function missing) so the caller can
  /// decide whether to soft-fail or abort. We prefer null to zero here so a
  /// transient error doesn't get mistaken for "you're out of credits".
  Future<int?> _getPracticeBalance(String practiceId) =>
      _api.practiceCreditBalance(practiceId: practiceId);

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
    final trainerId = _api.currentUserId;
    if (trainerId == null) {
      throw StateError('Not signed in');
    }

    // Practice id resolution.
    //
    // ALWAYS use the bootstrap-cached `AuthService.currentPracticeId`
    // — it was returned by the `bootstrap_practice_for_user` SECURITY
    // DEFINER RPC after confirming THIS signed-in user's membership.
    // The session's stored practiceId can be stale: the session may
    // have been created on this device while signed in as a different
    // account (the multi-account scenario), or before the practice_id
    // wiring landed at all.
    //
    // Defence-in-depth: if the cache is empty (cold-start race where
    // bootstrap hasn't completed yet, OR a transient RPC failure), we
    // call the bootstrap RPC directly here so the publish always has
    // a freshly verified practice. Only if THAT fails do we fall back
    // to the stored value or bail.
    var cachedPracticeId = AuthService.instance.currentPracticeId.value;
    if (cachedPracticeId == null) {
      await AuthService.instance.ensurePracticeMembership();
      cachedPracticeId = AuthService.instance.currentPracticeId.value;
    }
    final sessionPracticeId = session.practiceId;
    final String practiceId;
    if (cachedPracticeId != null) {
      practiceId = cachedPracticeId;
      if (sessionPracticeId != cachedPracticeId) {
        final backfilled = session.copyWith(practiceId: cachedPracticeId);
        try {
          await _storage.saveSession(backfilled);
        } catch (e) {
          debugPrint(
            'uploadPlan: failed to backfill practiceId locally: $e',
          );
        }
      }
    } else if (sessionPracticeId != null) {
      practiceId = sessionPracticeId;
    } else {
      const msg =
          'Cannot publish: no practice found. Tap Retry on the setup banner.';
      await _recordFailure(session, msg);
      throw StateError(msg);
    }
    debugPrint(
      'uploadPlan: trainer=$trainerId practice=$practiceId '
      'session.practiceId=$sessionPracticeId cached=$cachedPracticeId',
    );
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

    // Tracks storage paths we've successfully uploaded so the catch block
    // can clean them up on a partial-publish failure. Otherwise the retry
    // path stacks orphaned objects in the `media` bucket every time.
    final uploadedPaths = <String>[];

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

      // Step 3a: resolve (or create) the clients row for this plan's
      // clientName. Without this, plans.client_id stays null, which
      // blocks get_plan_full from issuing the grayscale / original
      // signed URLs (the RPC needs a client to check video_consent
      // against). Best-effort: if the upsert fails we continue with a
      // null client_id — the plan still publishes, but cloud B&W /
      // Original won't work until a subsequent publish links it.
      final clientId = await _api.upsertClient(
        practiceId: practiceId,
        name: session.clientName,
      );

      // Step 3b: ensure a plan row exists so consume_credit's FK is
      // satisfied on first-ever publish. On re-publish this is a no-op
      // `ON CONFLICT DO NOTHING` (implemented as an upsert that omits
      // every mutable column — PostgREST writes back the same values on
      // conflict). The version stays at `session.version` here.
      await _api.upsertPlan({
        'id': session.id,
        'client_name': session.clientName,
        'client_id': clientId,
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
      final consumeMap = await _api.consumeCredit(
        practiceId: practiceId,
        planId: session.id,
        credits: creditsToCharge,
      );
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
      await _api.upsertPlan({
        'id': session.id,
        'client_name': session.clientName,
        'client_id': clientId,
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
        await _api.uploadMedia(path: storagePath, file: file);
        // Only record the path AFTER the upload succeeds — a throw in the
        // upload call itself leaves the remote in whatever state the
        // supabase SDK leaves it in, and we don't want to DELETE a path we
        // never successfully created.
        uploadedPaths.add(storagePath);
        mediaUrls[exercise.id] = _api.publicMediaUrl(path: storagePath);

        final thumbPath = exercise.absoluteThumbnailPath;
        if (thumbPath != null) {
          final thumbFile = File(thumbPath);
          if (await thumbFile.exists()) {
            final thumbStoragePath = '${session.id}/${exercise.id}_thumb.jpg';
            await _api.uploadMedia(path: thumbStoragePath, file: thumbFile);
            uploadedPaths.add(thumbStoragePath);
            thumbUrls[exercise.id] =
                _api.publicMediaUrl(path: thumbStoragePath);
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
                // Sticky treatment preference (Milestone O). null is
                // "default = line"; non-null is the practitioner's
                // explicit choice persisted from the Studio card tiles
                // / plan preview / _MediaViewer. Round-trips through the
                // exercises.preferred_treatment column; get_plan_full
                // is expected to surface it on subsequent reads.
                'preferred_treatment': e.preferredTreatment?.wireValue,
                // Per-exercise prep-countdown override (Milestone P /
                // Wave 3). null = use global default (5s); positive int
                // = practitioner override set via the Studio card's
                // "Prep seconds" inline field. Surfaces on the web
                // player via get_plan_full (emitted by to_jsonb(e)).
                'prep_seconds': e.prepSeconds,
              })
          .toList();

      // Upsert so a re-publish of an unchanged exercise set doesn't PK-collide.
      await _api.upsertExercises(exerciseRows);

      // ----------------------------------------------------------------
      // Step 7: Delete OLD exercise rows for this plan that are not in
      // the new id set. Rest-only sessions (empty exerciseRows) clear
      // everything.
      // ----------------------------------------------------------------
      final newIds = exerciseRows.map((r) => r['id'] as String).toList();
      await _api.deleteStaleExercises(planId: session.id, keepIds: newIds);

      // ----------------------------------------------------------------
      // Step 7.5: best-effort raw-archive upload.
      //
      // For every exercise with a local `archiveFilePath` that hasn't yet
      // been uploaded, stream the compressed 720p H.264 copy into the
      // private `raw-archive` bucket at:
      //     {practiceId}/{planId}/{exerciseId}.mp4
      //
      // This is intentionally best-effort:
      //   - Each exercise is wrapped in its own try/catch, so one failure
      //     doesn't cascade and take down the rest.
      //   - ALL failures are swallowed — publish continues regardless.
      //   - The bucket may not exist yet (parallel backend work in flight);
      //     a 404 here simply leaves `rawArchiveUploadedAt` null and the
      //     next publish retries. Do NOT surface this to the practitioner.
      //   - Already-uploaded exercises (`rawArchiveUploadedAt != null`) are
      //     skipped to save bandwidth on re-publish.
      //
      // Ordering: runs AFTER plan/exercises/orphan-cleanup succeeded so
      // the main plan is complete even if every raw upload fails. The
      // practitioner never waits on raw archive — they can re-publish to
      // back-fill later.
      // ----------------------------------------------------------------
      await _uploadRawArchives(
        session: session,
        practiceId: practiceId,
      );

      // ----------------------------------------------------------------
      // Step 8: append an audit row to `plan_issuances`. Records who
      // published which plan-version at what size for what credit cost.
      // The ledger is already authoritative via consume_credit; this row
      // exists for billing history / support queries. If the insert fails
      // (e.g. schema migration not applied yet) we swallow — the ledger
      // is consistent and the bio must not be blocked by an audit hiccup.
      // ----------------------------------------------------------------
      try {
        await _api.insertPlanIssuance({
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
      // Clean up any storage objects we uploaded before the failure so a
      // retry doesn't stack more orphans. Wrapped in its own try/catch —
      // a cleanup failure must NOT mask the original error surfaced to
      // the user via [PublishResult.networkFailed].
      if (uploadedPaths.isNotEmpty) {
        try {
          await _api.removeMedia(paths: uploadedPaths);
        } catch (cleanupErr) {
          debugPrint(
            'UploadService: orphan cleanup failed for ${uploadedPaths.length} '
            'path(s) after publish failure — leaving objects in bucket: '
            '$cleanupErr',
          );
        }
      }

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
      // Include practice/trainer context in the failure so a mismatched-
      // tenant error (RLS rejection) surfaces enough detail in the
      // user-facing snackbar to diagnose without device logs. The
      // PublishResult's error is what reaches the SnackBar via
      // `result.toErrorString()` — wrap the raw exception with context.
      final wrappedError = StateError(
        'practice=$practiceId trainer=$trainerId :: ${e.toString()}',
      );
      await _recordFailure(session, wrappedError.message);
      return PublishResult.networkFailed(error: wrappedError);
    }
  }

  /// Upload the compressed 720p H.264 raw-archive copy of every video
  /// exercise in [session] to the private [ApiClient.rawArchiveBucket] under
  /// `{practiceId}/{planId}/{exerciseId}.mp4`.
  ///
  /// Best-effort: every failure mode (missing local file, missing bucket,
  /// RLS rejection, network error) is logged via [debugPrint] and
  /// swallowed. Per-exercise try/catch so one bad file cannot poison the
  /// rest. Successful uploads stamp `rawArchiveUploadedAt = now()` on the
  /// local row; already-uploaded exercises are skipped so re-publishes
  /// don't re-transfer.
  ///
  /// Routing note: this eventually wants to live behind the ApiClient
  /// data-access layer (per docs/DATA_ACCESS_LAYER.md and the mention in
  /// CLAUDE.md). That file does not yet exist on this branch; once it
  /// lands, inline this call site into
  /// `ApiClient.uploadRawArchive({practiceId, planId, exerciseId, localPath})`
  /// which takes the same four inputs.
  Future<void> _uploadRawArchives({
    required Session session,
    required String practiceId,
  }) async {
    for (final exercise in session.exercises) {
      if (exercise.isRest) continue;
      if (exercise.rawArchiveUploadedAt != null) continue;
      final relPath = exercise.archiveFilePath;
      if (relPath == null || relPath.isEmpty) continue;
      final absPath = exercise.absoluteArchiveFilePath;
      if (absPath == null) continue;

      final file = File(absPath);
      if (!file.existsSync()) {
        debugPrint(
          'UploadService: raw-archive file missing for exercise ${exercise.id} '
          'at $absPath — skipping (local archive may have been pruned).',
        );
        continue;
      }

      final storagePath = '$practiceId/${session.id}/${exercise.id}.mp4';
      try {
        await _api.uploadRawArchive(
          path: storagePath,
          file: file,
        );
        // Persist the success locally so a subsequent publish skips this
        // file. Wrapped in its own try/catch — a DB hiccup here must not
        // mask the fact that the upload itself succeeded.
        try {
          final stamped = exercise.copyWith(
            rawArchiveUploadedAt: DateTime.now(),
          );
          await _storage.saveExercise(stamped);
        } catch (dbErr) {
          debugPrint(
            'UploadService: raw-archive upload succeeded for ${exercise.id} '
            'but local stamp failed: $dbErr',
          );
        }
      } catch (e) {
        // Bucket missing (404) / RLS rejection / transient network — all
        // non-fatal. Next publish retries. Keep the log terse so a large
        // plan with a vanished bucket doesn't flood debugPrint.
        debugPrint(
          'UploadService: raw-archive upload failed for ${exercise.id} '
          '→ $storagePath (continuing): $e',
        );
      }
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
    // [ApiClient.refundCredit] already swallows RPC errors — best-effort
    // semantics are preserved; see docstring above for the ledger
    // reconciliation contract.
    await _api.refundCredit(planId: planId);
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
