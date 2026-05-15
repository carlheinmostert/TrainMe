import 'dart:async';
import 'dart:developer' as dev;
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;
import '../config.dart';
import '../models/client.dart';
import '../models/publish_progress.dart';
import '../models/session.dart';
import '../models/exercise_capture.dart';
import '../models/treatment.dart';
import 'api_client.dart';
import 'auth_service.dart';
import 'local_storage_service.dart';
import 'loud_swallow.dart';
import 'sync_service.dart';

/// Callback invoked by [UploadService.uploadPlan] on every phase boundary
/// and on every per-file tick within [PublishPhase.uploadingTreatments].
///
/// The snapshot is always self-contained — consumers do not need to track
/// previous events to render the current sheet state. See [PublishProgress]
/// for the contract.
///
/// Kept as a callback rather than a stream so existing call sites
/// (StudioModeScreen + tests) stay synchronous-await on the
/// `Future<PublishResult>` return. The sheet UI wraps the callback to fan
/// events out to a `ValueNotifier<PublishProgress>`.
typedef PublishProgressSink = void Function(PublishProgress progress);

// TODO: move to background URLSession for true non-blocking publish.
// Today the upload runs on the Dart isolate tied to the app lifecycle; the
// CLAUDE.md "non-blocking publish" claim is aspirational. A future pass should
// hand media uploads to a native background URLSession / WorkManager so the
// bio can background/kill the app mid-publish without losing progress.

/// Raised by [UploadService.uploadPlan] when the plan has one or more
/// exercises whose sticky `preferred_treatment` is denied by the linked
/// client's `video_consent`. Carries the list of violations so the
/// publish-button handler can show a bottom-sheet with "Grant consent &
/// publish" / "Back to Studio" CTAs without a second round-trip.
///
/// The mobile pre-flight throws this BEFORE anything touches Supabase
/// state (no ledger write, no version bump). The matching server-side
/// backstop (`consume_credit` raising SQLSTATE P0003) is what catches a
/// client that skipped the pre-flight — both paths yield the same user
/// experience.
///
/// See Wave 16 / Milestone V
/// (`supabase/schema_milestone_v_publish_consent_validation.sql`).
class UnconsentedTreatmentsException implements Exception {
  /// The offending exercises, one per violation, in `exercises.position`
  /// order (rest-omitted). Non-empty by construction.
  final List<UnconsentedTreatment> violations;

  /// The client's display name at the moment the check ran. Used to
  /// render "Garry hasn't consented to..." without the UI needing to
  /// re-load the client.
  final String clientName;

  const UnconsentedTreatmentsException({
    required this.violations,
    required this.clientName,
  });

  @override
  String toString() =>
      'UnconsentedTreatmentsException(${violations.length} violation(s) '
      'for $clientName)';
}

/// Carries a pre-formatted user-visible publish error message without the
/// `Bad state:` / `Exception:` prefixes that `StateError` / `Exception`
/// produce via `.toString()`. Used as the `error` payload on
/// [PublishResult.networkFailed] when the underlying failure has a
/// cleaner caller-authored message (e.g. client-linkage collisions).
/// Falling back to [StateError] for raw exceptions still works —
/// [PublishResult.toErrorString] handles both.
class PublishFailureMessage implements Exception {
  final String message;
  const PublishFailureMessage(this.message);
  @override
  String toString() => message;
}

/// Thrown by [UploadService.uploadPlan] when atomic raw-archive uploads
/// fail (PR-C of the 2026-05-15 publish-flow refactor).
///
/// Today every raw-archive variant upload is required: any per-file
/// failure in the upload pass terminates the publish with this exception,
/// the credit refund fires in the same catch block, and the new
/// [PublishProgressSheet] renders the failure state with a
/// "Show which files →" tap-through to [UploadDiagnosticSheet].
///
/// The failure list carries enough detail (kind, exercise index/name,
/// storage path, local path, exists-on-disk) to drive that sheet without
/// a second round-trip. Mirrors the existing [UploadFailureRecord]
/// shape used by the diagnostic surface in PR #345.
///
/// Subsequent steps (plan version bump, exercise upsert, audit row) do
/// NOT run when this fires — the publish is terminal at the upload phase
/// and the credit is refunded so the practice can retry without paying
/// twice. Spec: docs/design/mockups/publish-flow-refactor.html.
class PublishFailedException implements Exception {
  /// The phase that failed. Always [PublishPhase.uploadingTreatments] in
  /// the current implementation, but carried explicitly so future
  /// failures elsewhere (e.g. media bucket push) can reuse this type.
  final PublishPhase phase;

  /// Per-file failure records for the upload pass. Non-empty when
  /// [phase] is [PublishPhase.uploadingTreatments]. Surfaced to the
  /// `Show which files →` link on the failure sheet — opens the existing
  /// [UploadDiagnosticSheet] with the same records.
  final List<UploadFailureRecord> failures;

  /// Files successfully uploaded before the failure. Drives the
  /// "Uploading treatments" row's "N of M files" subtitle in the
  /// failure state — keeps the partial progress visible so the
  /// practitioner sees how far the publish got.
  final int filesUploaded;

  /// Total files the upload pass would have transferred. Same as the
  /// final tick before the failure fired.
  final int filesTotal;

  /// Short user-visible summary suitable for snackbar / banner display.
  /// Defaults to the standard upload-failure copy; callers can override
  /// for specialised wording.
  final String userMessage;

  PublishFailedException({
    required this.phase,
    required this.failures,
    required this.filesUploaded,
    required this.filesTotal,
    String? userMessage,
  }) : userMessage = userMessage ??
            'Some files could not upload — your credit was refunded. '
                'Tap retry to publish again.';

  @override
  String toString() => userMessage;
}

// `UploadFailureRecord` moved to `models/publish_progress.dart` (PR-C
// reactive-failures fix) so [PublishProgress.failure] can carry the
// failure list on the stream event without a circular import — the
// service already imports the model.

/// Structured payload for [PublishResult.networkFailed]: short practitioner copy
/// ([userMessage]) plus optional diagnostics for clipboard / `last_publish_error`.
class PublishFailurePayload implements Exception {
  PublishFailurePayload({
    required this.userMessage,
    this.detail,
    this.refundLikelyAttempted = false,
    this.refundOutcomeUnknown = false,
    this.remoteVersionMayHaveAdvanced = false,
    this.remoteVersionCandidate,
    this.leafExceptionType,
    this.innerMessage,
  });

  /// Snackbar / inline banner — no `Bad state:` / stack dumps.
  final String userMessage;

  /// Technical hint (PostgREST body, socket errno, truncated inner text).
  final String? detail;

  /// True when [UploadService.uploadPlan] attempted `refund_credit` after a debit.
  final bool refundLikelyAttempted;

  /// True when a debit happened but refund confirmation is unknown because the
  /// refund path is intentionally best-effort/swallowing.
  final bool refundOutcomeUnknown;

  /// True when Step 4 probably completed before the failure, so cloud
  /// `plans.version` may have advanced despite a failed publish.
  final bool remoteVersionMayHaveAdvanced;

  /// Candidate cloud version written in Step 4 (when known).
  final int? remoteVersionCandidate;

  final String? leafExceptionType;

  /// Inner failure text (may duplicate [detail] for some paths).
  final String? innerMessage;

  @override
  String toString() => userMessage;

  /// Full text for tap-to-copy in Studio (includes diagnostics).
  String toClipboardText() {
    final buf = StringBuffer(userMessage);
    if (refundLikelyAttempted && refundOutcomeUnknown) {
      buf.writeln();
      buf.write(
        'Credits were charged; refund was attempted but not confirmed — check balance and reconcile if needed.',
      );
    }
    if (remoteVersionMayHaveAdvanced && remoteVersionCandidate != null) {
      buf.writeln();
      buf.write(
        'Cloud plan version may already be v$remoteVersionCandidate despite this failure.',
      );
    }
    buf.writeln();
    buf.writeln('---');
    if (leafExceptionType != null) {
      buf.writeln('type: $leafExceptionType');
    }
    if (innerMessage != null && innerMessage!.trim().isNotEmpty) {
      buf.writeln('raw: ${innerMessage!.trim()}');
    }
    if (detail != null && detail!.trim().isNotEmpty) {
      buf.writeln(detail!.trim());
    }
    return buf.toString().trimRight();
  }

  factory PublishFailurePayload.fromPublishCatch({
    required Object caught,
    required String practiceId,
    required String trainerId,
    required bool refundLikelyAttempted,
    required bool refundOutcomeUnknown,
    required bool remoteVersionMayHaveAdvanced,
    int? remoteVersionCandidate,
  }) {
    final prefix = 'practice=$practiceId trainer=$trainerId :: ';
    String innerMsg;
    if (caught is StateError && caught.message.startsWith(prefix)) {
      innerMsg = caught.message.substring(prefix.length);
    } else {
      innerMsg = caught.toString();
    }

    String userMessage;
    String? detail;

    if (caught is PublishFailureMessage) {
      userMessage = caught.message;
      detail = null;
    } else if (caught is PostgrestException) {
      userMessage = _userMessageForPostgrest(caught);
      final detailsStr = caught.details?.toString().trim();
      detail =
          'PostgREST ${caught.code}${detailsStr != null && detailsStr.isNotEmpty ? ' ($detailsStr)' : ''}: ${caught.message}';
      if (caught.hint != null && caught.hint!.trim().isNotEmpty) {
        detail = '$detail\nhint: ${caught.hint}';
      }
    } else if (caught is SocketException) {
      userMessage =
          'Could not reach the server. Check your connection and retry.';
      detail = caught.message;
    } else {
      final lower = innerMsg.toLowerCase();
      if (lower.contains('socketexception') ||
          lower.contains('failed host lookup') ||
          lower.contains('network is unreachable') ||
          lower.contains('connection refused') ||
          lower.contains('connection reset')) {
        userMessage =
            'Could not reach the server. Check your connection and retry.';
        detail = innerMsg;
      } else {
        userMessage =
            'Publish did not finish. Check your connection and retry. '
            'If this keeps happening, copy the error for support.';
        detail =
            innerMsg.length > 420 ? '${innerMsg.substring(0, 420)}…' : innerMsg;
      }
    }

    final clippedInner =
        innerMsg.length > 600 ? '${innerMsg.substring(0, 600)}…' : innerMsg;

    return PublishFailurePayload(
      userMessage: userMessage,
      detail: detail,
      refundLikelyAttempted: refundLikelyAttempted,
      refundOutcomeUnknown: refundOutcomeUnknown,
      remoteVersionMayHaveAdvanced: remoteVersionMayHaveAdvanced,
      remoteVersionCandidate: remoteVersionCandidate,
      leafExceptionType: caught.runtimeType.toString(),
      innerMessage: clippedInner,
    );
  }
}

String _userMessageForPostgrest(PostgrestException e) {
  final code = e.code ?? '';
  final msgLower = e.message.toLowerCase();
  if (code == '42501' || msgLower.contains('permission denied')) {
    return 'Permission denied — sign out and back in, then retry.';
  }
  if (code == '23505') {
    return 'That name or record already exists on the server. Rename or use the recycle bin, then retry.';
  }
  if (code == '23503') {
    return 'Linked data is out of sync. Retry after refreshing your practice data.';
  }
  if (code == 'PGRST301' ||
      msgLower.contains('jwt expired') ||
      msgLower.contains('invalid jwt')) {
    return 'Session expired — sign out and back in, then retry.';
  }
  return 'Server rejected the publish. Retry shortly or copy the error for support.';
}

/// Outcome of a publish attempt. Exhaustive via the six factories:
/// [PublishResult.success], [PublishResult.preflightFailed],
/// [PublishResult.networkFailed], [PublishResult.insufficientCredits],
/// [PublishResult.unconsentedTreatments],
/// [PublishResult.needsConsentConfirmation].
class PublishResult {
  /// When [success] is true, [url] and [version] are set. Otherwise they are
  /// null and one of [missingFiles] / [error] / (balance+required) is set.
  final bool success;
  final String? url;
  final int? version;

  /// Credits charged for this publish (computed via [creditCostForDuration]). Set
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

  /// Wave 16 / Milestone V — per-exercise treatments that the linked
  /// client's `video_consent` doesn't allow. Non-null only for
  /// [PublishResult.unconsentedTreatments]. The caller shows the
  /// bottom-sheet and then (optionally) retries after flipping consent.
  final UnconsentedTreatmentsException? unconsented;

  /// Wave 29 — client whose `consent_confirmed_at` is null at publish
  /// time. The caller surfaces the consent sheet, and on save retries
  /// the publish. Non-null only for
  /// [PublishResult.needsConsentConfirmation]. Carries enough to render
  /// the sheet without re-fetching.
  final PracticeClient? consentConfirmationClient;

  /// Per-set PLAN wave — exercise IDs whose incoming `sets` array was
  /// missing or empty at publish time. The server-side
  /// `replace_plan_exercises` RPC inserted a synthetic single-set
  /// fallback (`reps=1, hold=0, weight=NULL, breather=60`) for these so
  /// the plan stays playable, and surfaced the IDs here so the UI can
  /// warn the practitioner that a default was applied. Empty list on
  /// the happy path (every video/photo exercise carried its own sets).
  ///
  /// TODO(ui): the snackbar / dialog that surfaces this list lives
  /// outside this service per the data-layer scope. The Studio /
  /// publish-button handler should read [fallbackSetExerciseIds] off
  /// the success result and render a one-liner ("N exercises had
  /// missing sets — a single-set default was applied"). The
  /// upload_service itself does NOT show UI.
  final List<String> fallbackSetExerciseIds;

  /// Optional artifact warning — non-blocking raw-archive sidecar uploads had
  /// one or more failures while main publish still succeeded.
  final bool optionalArtifactsHadFailures;

  /// Per-file failure breakdown captured during the best-effort
  /// raw-archive upload pass. Empty when [optionalArtifactsHadFailures]
  /// is false. Surfaced via the in-app diagnostic sheet so Carl can read
  /// which file(s) failed without Xcode device console access.
  ///
  /// Populated since BUG 13 (2026-05-15) — see PR `fix/publish-toast-diagnostic-sheet`.
  /// Pre-existing callers that only read [optionalArtifactsHadFailures]
  /// keep working unchanged.
  final List<UploadFailureRecord> optionalArtifactFailures;

  /// Step 0 consent preflight warning — true when
  /// `validate_plan_treatment_consent` failed and publish continued, relying
  /// on server-side `consume_credit` P0003 as the backstop.
  final bool consentPreflightSkipped;

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
    this.unconsented,
    this.consentConfirmationClient,
    this.fallbackSetExerciseIds = const <String>[],
    this.optionalArtifactsHadFailures = false,
    this.optionalArtifactFailures = const <UploadFailureRecord>[],
    this.consentPreflightSkipped = false,
  });

  /// Successful publish.
  factory PublishResult.success({
    required String url,
    required int version,
    required int creditsCharged,
    List<String> fallbackSetExerciseIds = const <String>[],
    bool optionalArtifactsHadFailures = false,
    List<UploadFailureRecord> optionalArtifactFailures =
        const <UploadFailureRecord>[],
    bool consentPreflightSkipped = false,
  }) =>
      PublishResult._(
        success: true,
        url: url,
        version: version,
        creditsCharged: creditsCharged,
        fallbackSetExerciseIds: fallbackSetExerciseIds,
        optionalArtifactsHadFailures: optionalArtifactsHadFailures,
        optionalArtifactFailures:
            List.unmodifiable(optionalArtifactFailures),
        consentPreflightSkipped: consentPreflightSkipped,
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

  /// Wave 16 / Milestone V — publish refused because one or more
  /// exercises have a `preferred_treatment` the client hasn't
  /// consented to. No plan state changed on Supabase; the ledger was
  /// not touched. The caller shows the unblock sheet with "Grant
  /// consent & publish" and "Back to Studio" CTAs.
  factory PublishResult.unconsentedTreatments(
    UnconsentedTreatmentsException e,
  ) =>
      PublishResult._(success: false, unconsented: e);

  /// Wave 29 — publish refused because the linked client's
  /// `consent_confirmed_at` is null. No credit was consumed. The caller
  /// surfaces the consent sheet (which stamps the column server-side)
  /// and re-fires publish.
  factory PublishResult.needsConsentConfirmation(PracticeClient client) =>
      PublishResult._(success: false, consentConfirmationClient: client);

  /// Convenience: was this a pre-flight failure?
  bool get isPreflightFailure => !success && missingFiles != null;

  /// Convenience: was this a network/remote failure?
  bool get isNetworkFailure => !success && error != null;

  /// Convenience: was this an insufficient-credits rejection?
  bool get isInsufficientCredits => !success && required != null;

  /// Convenience: was this an unconsented-treatments rejection?
  bool get isUnconsentedTreatments => !success && unconsented != null;

  /// Convenience: was this a missing-consent-confirmation rejection?
  bool get isNeedsConsentConfirmation =>
      !success && consentConfirmationClient != null;

  /// UI hint shown on success when Step 0 consent preflight could not run.
  String? get consentPreflightSkippedReason {
    if (!success || !consentPreflightSkipped) return null;
    return 'consent validation RPC unavailable';
  }

  /// UI hint shown on success when optional raw-archive artifact uploads failed.
  String? get optionalArtifactFailureReason {
    if (!success || !optionalArtifactsHadFailures) return null;
    return 'raw-archive upload incomplete';
  }

  /// Human-readable error summary, suitable for snackbar display and storage
  /// in the `last_publish_error` column. Truncated to 500 chars.
  String toErrorString() {
    String s;
    if (isPreflightFailure) {
      final names = missingFiles!.join(', ');
      s = 'Missing local file(s) for exercise(s): $names';
    } else if (isInsufficientCredits) {
      // Apple Reader-App compliance (Guideline 3.1.1): error copy may
      // not direct the practitioner to an external purchase flow.
      // Previously read "...Buy more via manage.homefit.studio." which
      // a reviewer could fairly read as steering toward web payment.
      // The shorter line below states the fact and stops there; the
      // zero-balance hint on Home carries the only mention of the
      // top-up URL, as plain text.
      s = 'Practice has $balance credits, need $required.';
    } else if (isUnconsentedTreatments) {
      final u = unconsented!;
      s = '${u.clientName} has not consented to '
          '${u.violations.length} treatment(s).';
    } else if (isNeedsConsentConfirmation) {
      final c = consentConfirmationClient!;
      s = 'Consent for ${c.name.isEmpty ? 'this client' : c.name} '
          'has not been confirmed yet.';
    } else if (isNetworkFailure) {
      final err = error!;
      if (err is PublishFailurePayload) {
        s = err.userMessage;
      } else {
        s = err.toString();
      }
    } else {
      s = 'Unknown publish error';
    }
    return s.length > 500 ? s.substring(0, 500) : s;
  }

  /// Optional rich clipboard text for network failures ([PublishFailurePayload]).
  String? get networkFailureClipboardDetail {
    if (!isNetworkFailure) return null;
    final e = error;
    if (e is PublishFailurePayload) return e.toClipboardText();
    return null;
  }

  /// True when publish failed after debit and refund completion is unknown.
  bool get networkFailureRefundOutcomeUnknown {
    if (!isNetworkFailure) return false;
    final e = error;
    return e is PublishFailurePayload && e.refundOutcomeUnknown;
  }

  /// UI hint for partial-version-drift ambiguity on network failures.
  String? get networkFailureVersionDriftReason {
    if (!isNetworkFailure) return null;
    final e = error;
    if (e is! PublishFailurePayload || !e.remoteVersionMayHaveAdvanced) {
      return null;
    }
    if (e.remoteVersionCandidate != null) {
      return 'cloud may already be on v${e.remoteVersionCandidate}';
    }
    return 'cloud version may already be ahead';
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
  ///
  /// PR-C (2026-05-15) — optional [onProgress] callback fires on every
  /// phase boundary and per-file tick inside the upload phase. Drives
  /// the new [PublishProgressSheet] UI. Existing callers that don't pass
  /// the callback work unchanged.
  Future<PublishResult> uploadPlan(
    Session session, {
    PublishProgressSink? onProgress,
  }) async {
    // Local emit helper so we can drop the callback into every phase
    // boundary without sprinkling null-checks. Safe to invoke regardless
    // of whether the caller attached a sink.
    void emit(PublishProgress p) {
      try {
        onProgress?.call(p);
      } catch (_) {
        // Never let a UI consumer's exception derail the publish path.
      }
    }

    // Phase 1 — Preparing. Pre-flight, consent gates, balance check.
    emit(PublishProgress.markActive(PublishPhase.preparing));
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
        await loudSwallow(
          () => _storage.saveSession(backfilled),
          kind: 'practice_id_backfill_failed',
          source: 'UploadService.uploadPlan',
          severity: 'warn',
          meta: {
            'session_id': session.id,
            'practice_id': cachedPracticeId,
            'was': sessionPracticeId,
          },
          swallow: true,
        );
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
    final nonRestExercises = session.exercises.where((e) => !e.isRest);
    final nonRestCount = nonRestExercises.length;
    final totalDurationSeconds = nonRestExercises.fold<int>(
      0,
      (sum, e) => sum + e.estimatedDurationSeconds,
    );
    final creditsToCharge = creditCostForDuration(totalDurationSeconds);

    // Resolve the LIVE client name. `session.clientName` is a legacy
    // mirror of `clients.name` — it was frozen at session creation and
    // the R-11 rename flow (SyncService.queueRenameClient) only updates
    // `cached_clients`, not existing sessions. Publish-via-stale-name
    // hits 23505 "restore it instead" when the session's old name
    // coincides with a soft-deleted client from before the rename.
    //
    // Fall back to `session.clientName` for legacy sessions where
    // `clientId` is null (pre-R-11 rows) and for the extreme edge where
    // the cache lookup returns null (client row purged while the
    // session still exists).
    String effectiveClientName = session.clientName;
    if (session.clientId != null && session.clientId!.isNotEmpty) {
      final cached = await _storage.getCachedClientById(session.clientId!);
      if (cached != null && cached.name.trim().isNotEmpty) {
        effectiveClientName = cached.name;
      }
    }

    // ------------------------------------------------------------------
    // Step 0a: Consent-confirmation gate (Wave 29).
    //
    // If the linked client has never had `set_client_video_consent`
    // called on them — i.e. `consent_confirmed_at IS NULL` — refuse to
    // publish until the practitioner explicitly confirms what the
    // client may see. No credit consumed, no files uploaded.
    //
    // Source of truth is the local `cached_clients` mirror: writes go
    // through SyncService.queueSetConsent which stamps the column
    // immediately + queues the RPC. The cloud column gets re-stamped on
    // flush. Legacy sessions without a clientId (pre-R-11 rows) skip
    // the gate — there's no client row to read against.
    // ------------------------------------------------------------------
    if (session.clientId != null && session.clientId!.isNotEmpty) {
      final cached = await _storage.getCachedClientById(session.clientId!);
      if (cached != null && cached.consentConfirmedAt == null) {
        return PublishResult.needsConsentConfirmation(
          cached.toPracticeClient(),
        );
      }
    }

    // ------------------------------------------------------------------
    // Step 0: Pre-flight consent validation (Wave 16 / Milestone V)
    //
    // Reject the publish BEFORE any file check or network I/O if any
    // exercise's sticky `preferred_treatment` is denied by the linked
    // client's `video_consent`. Triggered by the 2026-04-21 QA finding
    // where a practitioner set per-exercise preferences to grayscale /
    // original but the client had both switched off; publish succeeded
    // silently, and the web player fell back to line-drawing for those
    // exercises with no signal on either side.
    //
    // The RPC is SECURITY DEFINER + membership-checked internally. On
    // violation we raise [UnconsentedTreatmentsException] which the
    // caller catches + translates into a bottom-sheet with "Grant
    // consent & publish" / "Back to Studio" CTAs. No local state
    // changes; no Supabase writes happen.
    //
    // This is the primary UX surface. The matching server-side guard
    // inside `consume_credit` (raises SQLSTATE P0003) is the
    // authoritative backstop and only fires when a client skipped the
    // pre-flight entirely. That race is explicitly caught below.
    //
    // Best-effort: if the RPC itself fails (network blip, auth edge
    // case) we fall through to the file pre-flight so a transient
    // failure doesn't block publish — the server-side guard still
    // catches any real violation via `consume_credit`'s P0003 path.
    // ------------------------------------------------------------------
    bool consentPreflightSkipped = false;
    try {
      final violations = await _api.validatePlanTreatmentConsent(
        planId: session.id,
      );
      if (violations.isNotEmpty) {
        final exc = UnconsentedTreatmentsException(
          violations: violations,
          clientName: effectiveClientName,
        );
        await _recordFailure(session, exc.toString());
        return PublishResult.unconsentedTreatments(exc);
      }
    } catch (e) {
      // Swallow — the server-side consume_credit guard remains the
      // authoritative source of truth. Log for diagnostics only.
      consentPreflightSkipped = true;
      await _recordFailure(
        session,
        'Consent preflight skipped due to RPC failure; publish continued with consume_credit backstop.',
      );
      debugPrint('UploadService: validate_plan_treatment_consent failed: $e');
    }

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
    // Step-4 marker: once true, cloud `plans.version` may already be ahead of
    // local SQLite when a later step fails and returns networkFailed.
    bool planVersionBumped = false;
    // Refund confirmation marker. Null means "refund path not entered".
    // false means "refund attempted but completion unknown/failed".
    bool? refundApplied;

    // Tracks storage paths we've successfully uploaded so the catch block
    // can clean them up on a partial-publish failure. Otherwise the retry
    // path stacks orphaned objects in the `media` bucket every time.
    final uploadedPaths = <String>[];

    // Phase 2 — Reserving credit. Wraps client upsert + plan ensure +
    // consume_credit. Emitted just before the try block so a hard
    // throw in any of those steps lands the sheet on the reserving-
    // credit row.
    emit(PublishProgress.markActive(PublishPhase.reservingCredit));

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
      // against).
      //
      // Hard failure: if the upsert throws we MUST bail before
      // consume_credit runs. Previously we swallowed the error inside
      // ApiClient.upsertClient and continued with a null client_id —
      // the plan still "published" but the web player couldn't surface
      // B&W / Original treatments even after consent. The most common
      // throw is SQLSTATE 23505 "a deleted client already uses that
      // name — restore it instead", which the practitioner can only
      // fix by restoring from the recycle bin or renaming the client;
      // retrying the publish as-is will loop forever.
      //
      // Ordering: runs BEFORE consume_credit (step 3b) so a throw
      // here means no credits were taken and no refund is needed.
      // Prefer the ID-first RPC when the session already knows its
      // clientId — `upsert_client_with_id` looks up by id and returns
      // early if a live row exists, bypassing the name-collision check
      // entirely. That matters when a soft-deleted client in this
      // practice happens to share a name with the one we're about to
      // publish: `upsert_client` would raise 23505, while
      // `upsert_client_with_id` just resolves by id. Falls back to the
      // name-only RPC for legacy sessions with no clientId.
      final String? clientId;
      try {
        final knownClientId = session.clientId;
        if (knownClientId != null && knownClientId.isNotEmpty) {
          clientId = await _api.upsertClientWithId(
            clientId: knownClientId,
            practiceId: practiceId,
            name: effectiveClientName,
          );
        } else {
          clientId = await _api.upsertClient(
            practiceId: practiceId,
            name: effectiveClientName,
          );
        }
      } catch (e) {
        final String userMessage;
        if (e is PostgrestException &&
            e.code == '23505' &&
            (e.message.toLowerCase().contains('already uses that name') ||
                e.message.toLowerCase().contains('restore it instead'))) {
          userMessage =
              'This client name collides with a deleted client. Open the '
              'recycle bin and restore it, or rename before republishing.';
        } else {
          userMessage =
              'Could not register client with server — check connection '
              'and retry.';
        }
        await _recordFailure(session, userMessage);
        return PublishResult.networkFailed(
          error: PublishFailureMessage(userMessage),
        );
      }

      // Step 3b: ensure a plan row exists so consume_credit's FK is
      // satisfied on first-ever publish. On re-publish this is a no-op
      // `ON CONFLICT DO NOTHING` (implemented as an upsert that omits
      // every mutable column — PostgREST writes back the same values on
      // conflict). The version stays at `session.version` here.
      await _api.upsertPlan({
        'id': session.id,
        'client_name': effectiveClientName,
        'client_id': clientId,
        'title': session.displayTitle,
        // Supabase PostgREST accepts jsonb as a Dart Map — do NOT json.encode.
        'circuit_cycles': session.circuitCycles,
        'circuit_names': session.circuitNames,
        'preferred_rest_interval_seconds': session.preferredRestIntervalSeconds,
        'exercise_count': nonRestCount,
        // IMPORTANT: do NOT bump version here — only after consume_credit.
        'version': session.version,
        // Wave 39.4 — emit UTC. Postgres timestamptz columns interpret
        // any naked-offset ISO string in the connection's TZ; the audit
        // trail and dashboard timestamps both read these as authored,
        // so non-UTC writes drift across viewers. Always toUtc() before
        // toIso8601String().
        'created_at': session.createdAt.toUtc().toIso8601String(),
        'practice_id': practiceId,
        // Wave 27 — NULL means "use the surface default" on the cloud side
        // too; the reset button explicitly writes null so a re-publish
        // restores the default-rendered view.
        'crossfade_lead_ms': session.crossfadeLeadMs,
        'crossfade_fade_ms': session.crossfadeFadeMs,
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
      // Wave 29 — server-side prepaid-unlock fast path. consume_credit
      // returns `prepaid_unlock_at` when a prior `unlock_plan_for_edit`
      // already paid for this republish; the ledger was not debited
      // and the flag was cleared in the same transaction.
      final prepaidUnlockAt = consumeMap['prepaid_unlock_at'];
      if (ok && prepaidUnlockAt != null) {
        dev.log(
          'consume_credit skipped: republish covered by prior unlock at '
          '$prepaidUnlockAt (plan=${session.id}, practice=$practiceId)',
          name: 'UploadService.uploadPlan',
        );
      }
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
        'client_name': effectiveClientName,
        'client_id': clientId,
        'title': session.displayTitle,
        'circuit_cycles': session.circuitCycles,
        'circuit_names': session.circuitNames,
        'preferred_rest_interval_seconds': session.preferredRestIntervalSeconds,
        'exercise_count': nonRestCount,
        'version': newVersion,
        // Wave 39.4 — UTC wire format (see comment in upsertPlan above).
        'created_at': session.createdAt.toUtc().toIso8601String(),
        'sent_at': DateTime.now().toUtc().toIso8601String(),
        'practice_id': practiceId,
        'crossfade_lead_ms': session.crossfadeLeadMs,
        'crossfade_fade_ms': session.crossfadeFadeMs,
      });
      planVersionBumped = true;

      // ----------------------------------------------------------------
      // Step 5: Upload media files.
      //
      // Fast-path: if EVERY non-rest exercise already has
      // `rawArchiveUploadedAt` set, all files were uploaded in a prior
      // publish and nothing was re-captured. Skip ALL upload loops —
      // zero list calls, zero uploads, zero network for files. Just
      // build the URL map from the known path pattern.
      // ----------------------------------------------------------------
      // PR-C — start uploading-treatments phase. Per-file ticks emit
      // via `emit(PublishProgress.uploadTick(...))` after each
      // successful upload. The total is an upper bound (line-drawing
      // bucket + raw-archive variants); the metadata-only fast-path
      // can leave it at zero, in which case the sheet renders the row
      // as "complete in 0s" with no progress bar.
      emit(PublishProgress.markActive(PublishPhase.uploadingTreatments));
      int filesUploaded = 0;
      // Best-effort total estimate — counts files that COULD upload
      // (one per non-rest exercise per variant). The actual run may
      // skip some because they already exist in storage; the sheet's
      // "N of M files" is a worst-case ceiling, the bar still fills
      // as ticks land.
      int filesTotal = 0;

      final mediaUrls = <String, String>{}; // exerciseId -> media URL
      final thumbUrls = <String, String?>{}; // exerciseId -> thumbnail URL

      final nonRestExercises =
          session.exercises.where((e) => !e.isRest).toList();
      final allPreviouslyUploaded = nonRestExercises.isNotEmpty &&
          nonRestExercises.every((e) => e.rawArchiveUploadedAt != null);

      // Count the files this publish might upload (used for the sheet's
      // "N of M files" subtitle). Order:
      //   * media bucket: main mp4/jpg per exercise + _thumb.jpg + _thumb_line.jpg
      //   * raw-archive bucket: raw mp4 / raw jpg + segmented + _thumb_color + mask
      // Fast-path metadata-only republishes only refresh _thumb_line if
      // missing, so we count one possible variant per exercise there.
      if (allPreviouslyUploaded) {
        // Just the line-thumb backfill candidate per exercise.
        filesTotal = nonRestExercises.length;
      } else {
        for (final ex in nonRestExercises) {
          filesTotal += 1; // main media
          if (ex.absoluteThumbnailPath != null) filesTotal += 2; // _thumb + _thumb_line
        }
      }
      // Raw-archive variants — every variant is now required (PR-A).
      // Count what's plausibly on disk; the upload pass below will
      // skip whichever variants are missing.
      for (final ex in nonRestExercises) {
        if (ex.archiveFilePath != null && ex.archiveFilePath!.isNotEmpty) {
          filesTotal += 1;
        }
        if (ex.segmentedRawFilePath != null &&
            ex.segmentedRawFilePath!.isNotEmpty) {
          filesTotal += 1;
        }
        if (ex.mediaType.name == 'photo' && ex.rawFilePath.isNotEmpty) {
          filesTotal += 1;
        }
        if (ex.absoluteThumbnailPath != null) {
          filesTotal += 1; // _thumb_color
        }
        if (ex.maskFilePath != null && ex.maskFilePath!.isNotEmpty) {
          filesTotal += 1;
        }
      }
      emit(PublishProgress.uploadTick(
        filesUploaded: 0,
        filesTotal: filesTotal,
      ));

      if (allPreviouslyUploaded) {
        debugPrint('uploadPlan: metadata-only republish — skipping main file uploads');
        // Variant-thumb backfill (Wave Three-Treatment-Thumbs, 2026-05-05).
        // Plans previously published with builds before PR #263 don't have
        // `_thumb_line.jpg` in storage. Always run an existence-check +
        // upload pass for the variant so older plans get the file
        // populated on the next publish — independent of whether the main
        // mp4 / _thumb.jpg already exist.
        final existingFiles = <String>{};
        try {
          final listing = await _api.listMedia(prefix: session.id);
          for (final item in listing) {
            existingFiles.add('${session.id}/${item.name}');
          }
        } catch (_) {}

        for (final exercise in nonRestExercises) {
          final ext = p.extension(
            exercise.absoluteConvertedFilePath ?? exercise.absoluteRawFilePath,
          );
          final storagePath = '${session.id}/${exercise.id}$ext';
          mediaUrls[exercise.id] = _api.publicMediaUrl(path: storagePath);
          final thumbAbs = exercise.absoluteThumbnailPath;
          if (thumbAbs != null) {
            thumbUrls[exercise.id] = _api.publicMediaUrl(
                path: '${session.id}/${exercise.id}_thumb.jpg');

            // Backfill _thumb_line.jpg if missing in storage. Skip when
            // replaceFirst was a no-op (legacy photo rows whose
            // thumbnailPath was the raw file before Bundle 2b's variant
            // pipeline existed) — otherwise we'd upload the raw photo
            // mis-named as `_thumb_line.jpg`.
            final lineThumbAbs =
                thumbAbs.replaceFirst('_thumb.jpg', '_thumb_line.jpg');
            if (lineThumbAbs != thumbAbs) {
              final lineThumbFile = File(lineThumbAbs);
              if (await lineThumbFile.exists()) {
                final lineStoragePath =
                    '${session.id}/${exercise.id}_thumb_line.jpg';
                if (!existingFiles.contains(lineStoragePath)) {
                  await _api.uploadMedia(
                      path: lineStoragePath, file: lineThumbFile);
                  uploadedPaths.add(lineStoragePath);
                  filesUploaded += 1;
                  emit(PublishProgress.uploadTick(
                    filesUploaded: filesUploaded,
                    filesTotal: filesTotal,
                  ));
                }
              }
            }
          }
        }
      } else {
        // Some exercises are new — list + upload as needed.
        final existingFiles = <String>{};
        try {
          final listing = await _api.listMedia(prefix: session.id);
          for (final item in listing) {
            existingFiles.add('${session.id}/${item.name}');
          }
        } catch (_) {}

        for (final exercise in nonRestExercises) {
          final filePath =
              exercise.absoluteConvertedFilePath ?? exercise.absoluteRawFilePath;
          final file = File(filePath);
          final ext = p.extension(filePath);
          final storagePath = '${session.id}/${exercise.id}$ext';
          if (!existingFiles.contains(storagePath)) {
            await _api.uploadMedia(path: storagePath, file: file);
            uploadedPaths.add(storagePath);
            filesUploaded += 1;
            emit(PublishProgress.uploadTick(
              filesUploaded: filesUploaded,
              filesTotal: filesTotal,
            ));
          }
          mediaUrls[exercise.id] = _api.publicMediaUrl(path: storagePath);

          final thumbPath = exercise.absoluteThumbnailPath;
          if (thumbPath != null) {
            final thumbFile = File(thumbPath);
            if (await thumbFile.exists()) {
              final thumbStoragePath = '${session.id}/${exercise.id}_thumb.jpg';
              if (!existingFiles.contains(thumbStoragePath)) {
                await _api.uploadMedia(
                    path: thumbStoragePath, file: thumbFile);
                uploadedPaths.add(thumbStoragePath);
                filesUploaded += 1;
                emit(PublishProgress.uploadTick(
                  filesUploaded: filesUploaded,
                  filesTotal: filesTotal,
                ));
              }
              thumbUrls[exercise.id] =
                  _api.publicMediaUrl(path: thumbStoragePath);

              // Wave Three-Treatment-Thumbs (2026-05-05) — also upload
              // the LINE-DRAWING JPG (`_thumb_line.jpg`) for the web
              // player's line treatment. Native conversion (video) /
              // OpenCV isolate (photo, Bundle 2b) produces this
              // alongside `_thumb.jpg` — same Hero offset, sourced from
              // the converted line video or line-drawing photo. Public
              // bucket; URL reconstructed by get_plan_full at fetch
              // time.
              //
              // Defensive: skip when the replaceFirst was a no-op
              // (legacy photo rows whose `thumbnailPath` was the raw
              // file before the Bundle 2b photo-variant pipeline). The
              // line variant doesn't exist for those rows on disk.
              final lineThumbPath =
                  thumbPath.replaceFirst('_thumb.jpg', '_thumb_line.jpg');
              if (lineThumbPath != thumbPath) {
                final lineThumbFile = File(lineThumbPath);
                if (await lineThumbFile.exists()) {
                  final lineStoragePath =
                      '${session.id}/${exercise.id}_thumb_line.jpg';
                  if (!existingFiles.contains(lineStoragePath)) {
                    await _api.uploadMedia(
                        path: lineStoragePath, file: lineThumbFile);
                    uploadedPaths.add(lineStoragePath);
                    filesUploaded += 1;
                    emit(PublishProgress.uploadTick(
                      filesUploaded: filesUploaded,
                      filesTotal: filesTotal,
                    ));
                  }
                }
              }
            }
          }
        }
      }

      // ----------------------------------------------------------------
      // Step 7.5 (PR-C order): atomic raw-archive upload.
      //
      // PR-C (2026-05-15) reorders this BEFORE the exercise upsert so a
      // raw-archive failure can throw [PublishFailedException], unwind
      // the credit refund + media-bucket cleanup, and leave the
      // `exercises` table untouched. The pre-PR-C order ran exercise
      // upsert first and treated raw uploads as best-effort; the new
      // [PublishProgressSheet] needs every upload to be required so the
      // failure state is meaningful.
      //
      // Closure shares the same `filesUploaded` / `filesTotal` ints with
      // the media-bucket loop above, so the sheet's "N of M files"
      // counter advances seamlessly across both buckets.
      // ----------------------------------------------------------------
      final optionalArtifactFailureList = await _uploadRawArchives(
        session: session,
        practiceId: practiceId,
        onSuccessfulTick: () {
          filesUploaded += 1;
          emit(PublishProgress.uploadTick(
            filesUploaded: filesUploaded,
            filesTotal: filesTotal,
          ));
        },
      );

      // PR-C: any raw-archive failure is now terminal. Throw and let the
      // outer catch refund the credit + clean up the media bucket. The
      // exception carries the per-file failure list so the sheet's
      // "Show which files →" link can open [UploadDiagnosticSheet]
      // without re-fetching.
      if (optionalArtifactFailureList.isNotEmpty) {
        throw PublishFailedException(
          phase: PublishPhase.uploadingTreatments,
          failures: optionalArtifactFailureList,
          filesUploaded: filesUploaded,
          filesTotal: filesTotal,
        );
      }
      final optionalArtifactsHadFailures =
          optionalArtifactFailureList.isNotEmpty;

      // PR-C — uploads complete; transition to the "Saving plan" row.
      emit(PublishProgress.markActive(PublishPhase.savingPlan));

      // ----------------------------------------------------------------
      // Step 6: Upsert exercise rows (batched). FK to plans is satisfied
      // from Step 4.
      // ----------------------------------------------------------------
      // Per-set PLAN wave — payload now carries a nested `sets` array
      // per video/photo exercise. Rest exercises emit an empty `sets`
      // array (the RPC ignores it for media_type='rest'). Each set
      // serialises as {position, reps, hold_seconds, weight_kg,
      // breather_seconds_after}.
      final exerciseRows = session.exercises
          .map((e) => {
                'id': e.id,
                'plan_id': session.id,
                'position': e.position,
                'name': e.name,
                'media_url': mediaUrls[e.id],
                'thumbnail_url': thumbUrls[e.id],
                'media_type': e.mediaType.name,
                'sets': e.sets.map((s) => s.toJson()).toList(growable: false),
                'notes': e.notes,
                'circuit_id': e.circuitId,
                'include_audio': e.includeAudio,
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
                // Soft-trim window (Wave 20 / Milestone X). Both null
                // = no trim, full clip plays. When set, mobile preview
                // + web player clamp playback to [start, end] and loop
                // within that window; same trim applies across all
                // three treatments. Surfaces on the web player via
                // get_plan_full (emitted by to_jsonb(e)).
                'start_offset_ms': e.startOffsetMs,
                'end_offset_ms': e.endOffsetMs,
                // Wave 24 — number of reps captured in the source
                // video. NULL = legacy / pre-migration row (player
                // treats as 1 rep per loop). Fresh captures seed to 3
                // via withPersistenceDefaults().
                'video_reps_per_loop': e.videoRepsPerLoop,
                // Wave 28 — landscape orientation metadata. aspect_ratio
                // is the effective playback aspect AFTER any practitioner
                // rotation (single source of truth — consumers don't
                // re-derive from natural dimensions + rotation).
                'aspect_ratio': e.aspectRatio,
                'rotation_quarters': e.rotationQuarters,
                // Per-set PLAN rest-fix (schema_wave_per_set_dose_rest_fix.sql).
                // Only meaningful for media_type='rest'; null for video/photo.
                // The Wave-1 migration dropped exercises.hold_seconds (which
                // had been the rest-duration carrier for rest rows); this
                // restores the cloud round-trip via a dedicated rest_seconds
                // column. Mobile-side the value lives on
                // ExerciseCapture.restHoldSeconds (SQLite v33).
                'rest_seconds': e.restHoldSeconds,
                // Wave 42 — per-exercise practitioner body-focus default.
                // null = render with body-focus ON (the pre-Wave-42
                // default; legacy rows stay unchanged on first open).
                // true / false = explicit practitioner choice. Replaces
                // the legacy per-device flag in the mobile preview that
                // never reached publish. Surfaces on the web player via
                // get_plan_full (emitted by to_jsonb(e)); the player
                // layers per-exercise CLIENT overrides on top via
                // localStorage homefit.overrides::{planId}.
                'body_focus': e.bodyFocus,
                // Wave Hero — practitioner-picked Hero frame offset (ms
                // into the raw video). Drives every practitioner-facing
                // thumbnail surface AND the web player's prep-phase
                // overlay + video poster. NULL = legacy / pre-migration
                // row (consumers fall through to motion-peak heuristic).
                // Surfaces on the web player via get_plan_full (emitted
                // by to_jsonb(e)).
                'focus_frame_offset_ms': e.focusFrameOffsetMs,
                // Wave Lobby (PR 1/N) — practitioner-authored 1:1 Hero
                // crop offset, normalized 0.0..1.0 along the source
                // media's free axis (X for landscape, Y for portrait;
                // see Wave 28 aspect_ratio / rotation_quarters). NULL
                // = unset (consumers default to 0.5 / centred). No
                // consumer reads this yet — landed for round-trip
                // parity ahead of the editor + lobby PRs.
                'hero_crop_offset': e.heroCropOffset,
              })
          .toList();

      // Atomic replace-all — DELETE + INSERT in one transaction server-side.
      // Per-set PLAN wave: the RPC also rewrites the per-exercise child
      // rows in `exercise_sets` and returns a list of fallback exercise
      // IDs whose incoming `sets` array was missing/empty. Surface
      // those to the caller via [PublishResult.fallbackSetExerciseIds].
      final replaceResult = await _api.replacePlanExercises(
        planId: session.id,
        rows: exerciseRows,
      );
      // The list is propagated all the way to the success result. We
      // copy into a local so the closure capture below is explicit.
      final fallbackSetIds = replaceResult.fallbackSetExerciseIds;
      if (fallbackSetIds.isNotEmpty) {
        debugPrint(
          'uploadPlan: server applied synthetic single-set fallback for '
          '${fallbackSetIds.length} exercise(s): ${fallbackSetIds.join(", ")}',
        );
      }

      // PR-C — Step 7.5 (raw-archive upload) moved up to run BEFORE the
      // exercise upsert above so failures throw before persisting plan
      // state. See the new atomic-upload block higher in this method.

      // PR-C — exercises persisted; transition to the "Finalising" row.
      emit(PublishProgress.markActive(PublishPhase.finalising));

      // ----------------------------------------------------------------
      // Step 8: append an audit row to `plan_issuances`. Records who
      // published which plan-version at what size for what credit cost.
      // The ledger is already authoritative via consume_credit; this row
      // exists for billing history / support queries. If the insert fails
      // (e.g. schema migration not applied yet) we swallow — the ledger
      // is consistent and the bio must not be blocked by an audit hiccup.
      // ----------------------------------------------------------------
      // Wave 39 — when the prepaid-unlock fast path fired in step 3b,
      // surface the cleared timestamp on the audit row so the portal's
      // /audit page can render the "Prepaid via unlock at {date}" subtitle
      // and reverse-link the matching `credit.consumption` unlock row.
      // NULL on regular publishes.
      final issuanceRow = <String, dynamic>{
        'plan_id': session.id,
        'practice_id': practiceId,
        'trainer_id': trainerId,
        'version': newVersion,
        'exercise_count': nonRestCount,
        'credits_charged': creditsToCharge,
        // Wave 39.4 — UTC wire format. Audit page renders this in the
        // viewer's timezone; non-UTC writes drift by host TZ offset.
        'issued_at': DateTime.now().toUtc().toIso8601String(),
      };
      if (prepaidUnlockAt is String && prepaidUnlockAt.isNotEmpty) {
        issuanceRow['prepaid_unlock_at'] = prepaidUnlockAt;
      }
      await loudSwallow(
        () => _api.insertPlanIssuance(issuanceRow),
        kind: 'plan_issuance_audit_failed',
        source: 'UploadService.uploadPlan',
        severity: 'warn',
        meta: {
          'plan_id': session.id,
          'practice_id': practiceId,
          'version': newVersion,
          'credits_charged': creditsToCharge,
        },
        // Audit write is best-effort; ledger is the source of truth for
        // billing. Do not fail the publish on its behalf.
        swallow: true,
      );

      // ----------------------------------------------------------------
      // Success — persist new local state.
      // ----------------------------------------------------------------
      final planUrl = '${AppConfig.webPlayerBaseUrl}/p/${session.id}';
      final now = DateTime.now();
      // Wave 39.1 — when consume_credit hit the prepaid-unlock fast
      // path, the cloud-side function ALSO cleared first_opened_at +
      // last_opened_at to restart the 14-day grace clock. Mirror that
      // locally so the bottom-bar lock chip flips back to "Not yet
      // opened" immediately, instead of waiting for the next reconcile
      // (and instead of misleadingly showing a residual lock between
      // the publish and the reconcile).
      final unlockPaid = prepaidUnlockAt != null;
      final updated = session.copyWith(
        sentAt: now,
        planUrl: planUrl,
        version: newVersion,
        lastPublishedAt: now,
        // Wave 29 — server-side `consume_credit` cleared the prepaid
        // unlock flag in the same transaction (whether it was the
        // prepaid fast-path OR a normal charge that happened to follow
        // an unlock-then-charge race). Mirror that locally so
        // `_isPlanLocked` flips back to true once the post-open grace
        // window has elapsed.
        clearUnlockCreditPrepaidAt: true,
        clearFirstOpenedAt: unlockPaid,
        clearLastOpenedAt: unlockPaid,
      );
      await _storage.saveSession(updated);
      await _recordSuccess(session.id);

      // Wave 29 — broadcast the post-consume balance so the Home
      // credits chip ticks down without waiting for the next pullAll.
      // Fire-and-forget; failure is invisible to the publish path.
      unawaited(SyncService.instance.refreshCreditBalance(practiceId));

      // PR-C — every row now green; the sheet shows the 1-second
      // "All set" beat then auto-dismisses.
      emit(PublishProgress.allDone());

      return PublishResult.success(
        url: planUrl,
        version: newVersion,
        creditsCharged: creditsToCharge,
        fallbackSetExerciseIds: fallbackSetIds,
        optionalArtifactsHadFailures: optionalArtifactsHadFailures,
        optionalArtifactFailures: optionalArtifactFailureList,
        consentPreflightSkipped: consentPreflightSkipped,
      );
    } catch (e) {
      // Clean up any storage objects we uploaded before the failure so a
      // retry doesn't stack more orphans. Wrapped in its own try/catch —
      // a cleanup failure must NOT mask the original error surfaced to
      // the user via [PublishResult.networkFailed].
      if (uploadedPaths.isNotEmpty) {
        await loudSwallow(
          () => _api.removeMedia(paths: uploadedPaths),
          kind: 'orphan_cleanup_failed',
          source: 'UploadService.uploadPlan',
          severity: 'warn',
          message:
              'orphan cleanup failed for ${uploadedPaths.length} path(s) '
              'after publish failure — leaving objects in bucket',
          meta: {
            'plan_id': session.id,
            'practice_id': practiceId,
            'orphan_count': uploadedPaths.length,
          },
          // Cleanup is best-effort; the publish already failed and we
          // must preserve that original error up the stack.
          swallow: true,
        );
      }

      // If we already consumed credits, compensate with a refund row so
      // the ledger stays balanced — otherwise the bio is charged for a
      // plan that never published.
      //
      // PR-C — atomicity demands the refund actually lands. Retry once
      // on transient error so a single network blip can't strand the
      // practitioner with a debit and no plan. The underlying
      // `refund_credit` RPC is idempotent on `plan_id`, so a double-fire
      // is safe.
      if (creditConsumed) {
        refundApplied = await _refundCredits(
          practiceId: practiceId,
          planId: session.id,
          credits: creditsToCharge,
        );
        if (refundApplied != true) {
          // Single retry — most refund misses are transient socket
          // drops. The RPC's idempotency guard means a second call
          // against an already-refunded plan is a no-op.
          refundApplied = await _refundCredits(
            practiceId: practiceId,
            planId: session.id,
            credits: creditsToCharge,
          );
        }
      }

      // Wave 16 / Milestone V server-side backstop: if the pre-flight
      // was skipped or the consent rows changed between the pre-flight
      // and `consume_credit`, the RPC raises SQLSTATE P0003. Translate
      // that into the same PublishResult the pre-flight produces so
      // the UI has exactly one code path for unblock. Re-query the
      // violations so the sheet can group them; if the re-query fails
      // (it shouldn't — same auth context that just got a server
      // error) we fall through with an empty list + the client name.
      if (e is PostgrestException && e.code == 'P0003') {
        emit(PublishProgress.failure(phase: PublishPhase.reservingCredit));
        List<UnconsentedTreatment> violations = const [];
        try {
          violations = await _api.validatePlanTreatmentConsent(
            planId: session.id,
          );
        } catch (_) {
          // Fall through with empty list — the sheet still renders
          // a sensible "client has not consented to all treatments"
          // message and the Back-to-Studio CTA works.
        }
        final exc = UnconsentedTreatmentsException(
          violations: violations,
          clientName: effectiveClientName,
        );
        await _recordFailure(session, exc.toString());
        return PublishResult.unconsentedTreatments(exc);
      }

      // PR-C — atomic-upload terminal failure. Emit the failure
      // snapshot pointing at the uploading-treatments row and return
      // the per-file failure list via [PublishResult.networkFailed]'s
      // error payload so the sheet's "Show which files →" link can
      // hand the same records to [UploadDiagnosticSheet].
      if (e is PublishFailedException) {
        // PR-C reactive-failures fix — carry the per-file diagnostic
        // list on the same stream event that flips `failed=true`. The
        // progress sheet reads from this snapshot so the "Show which
        // files →" tap-target appears on the same rebuild as the
        // coral failure row. Previously the host's setState pushed
        // failures out-of-band after `uploadPlan` returned, by which
        // point the sheet widget had already captured `failures: []`
        // at construction.
        emit(PublishProgress.failure(
          phase: e.phase,
          filesUploaded: e.filesUploaded,
          filesTotal: e.filesTotal,
          failures: e.failures,
        ));
        await _recordFailure(session, e.userMessage);
        // Wrap as PublishFailurePayload so the existing
        // [PublishResult.networkFailed] path still works for callers
        // that don't know about the atomic-upload exception. The
        // diagnostic list flows through `optionalArtifactFailures`
        // even though the publish is terminal — the sheet's
        // tap-through reads from the result's payload.
        final payload = PublishFailurePayload(
          userMessage: e.userMessage,
          detail: 'Atomic upload failed for ${e.failures.length} file(s).',
          refundLikelyAttempted: creditConsumed,
          refundOutcomeUnknown: creditConsumed && refundApplied != true,
          remoteVersionMayHaveAdvanced: planVersionBumped,
          remoteVersionCandidate: planVersionBumped ? newVersion : null,
          leafExceptionType: 'PublishFailedException',
          innerMessage: e.userMessage,
        );
        return PublishResult._(
          success: false,
          error: payload,
          optionalArtifactsHadFailures: true,
          optionalArtifactFailures: List.unmodifiable(e.failures),
        );
      }

      // PR-C — non-atomic-upload failures still land on the failing
      // phase row in the sheet. Best-effort guess: if uploads had
      // already begun (filesUploaded > 0 OR uploadedPaths non-empty)
      // the failure belongs to the upload phase; otherwise it
      // belongs to the saving-plan phase (replacePlanExercises is
      // the only network call between upload completion and the
      // best-effort audit row).
      final inferredFailedPhase = uploadedPaths.isNotEmpty
          ? PublishPhase.uploadingTreatments
          : (creditConsumed
              ? PublishPhase.savingPlan
              : PublishPhase.reservingCredit);
      emit(PublishProgress.failure(phase: inferredFailedPhase));

      final payload = PublishFailurePayload.fromPublishCatch(
        caught: e,
        practiceId: practiceId,
        trainerId: trainerId,
        refundLikelyAttempted: creditConsumed,
        refundOutcomeUnknown: creditConsumed && refundApplied != true,
        remoteVersionMayHaveAdvanced: planVersionBumped,
        remoteVersionCandidate: planVersionBumped ? newVersion : null,
      );
      await _recordFailure(session, payload.toClipboardText());
      return PublishResult.networkFailed(error: payload);
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
  /// Returns the per-file failure list (empty on the happy path). The
  /// caller derives the legacy `hadFailures` boolean from
  /// `result.isNotEmpty`. PR #335 added debugPrint logging; BUG 13
  /// (2026-05-15) extended that to a structured collection so the
  /// in-app diagnostic sheet can render which file(s) failed without
  /// needing Xcode device console access.
  Future<List<UploadFailureRecord>> _uploadRawArchives({
    required Session session,
    required String practiceId,
    void Function()? onSuccessfulTick,
  }) async {
    // -----------------------------------------------------------------
    // PR-A (2026-05-15) — consent decoupled from upload.
    //
    // Every variant file in this function (main raw mp4, segmented
    // mp4/jpg, photo raw jpg, _thumb_color.jpg, mask mp4) uploads on
    // every publish if it exists on disk, regardless of the client's
    // `video_consent` flags. Existing skip-if-missing + skip-if-already-
    // uploaded short-circuits stay — PR-C will tighten the missing-file
    // case to fail the publish.
    //
    // Consent is now a pure player-side visibility gate: the
    // `get_plan_full` RPC emits NULL signed URLs for treatments the
    // client hasn't consented to, so revoked treatments stay invisible
    // even though the underlying file is in `raw-archive`. The win is
    // that toggling consent ON later doesn't require a republish — the
    // file is already in storage waiting for `get_plan_full` to sign it.
    //
    // Spec: docs/design/mockups/publish-flow-refactor.html
    // -----------------------------------------------------------------
    final failures = <UploadFailureRecord>[];
    // Snapshot the exercise order ONCE so every failure record reports
    // a stable 0-based slot even if `session.exercises` is mutated
    // elsewhere mid-publish (it shouldn't be, but the cost is one map
    // lookup and the upside is debuggable indices).
    final indexByExerciseId = <String, int>{
      for (var i = 0; i < session.exercises.length; i++)
        session.exercises[i].id: i,
    };
    final nameByExerciseId = <String, String?>{
      for (final e in session.exercises) e.id: e.name,
    };
    // Fast-path: if all exercises already uploaded, skip the main mp4 +
    // segmented + mask uploads. We still need to backfill the color-thumb
    // variant (Wave Three-Treatment-Thumbs, 2026-05-05) because plans
    // previously published with builds before PR #263 don't have it in
    // storage. The variant-thumb backfill below runs unconditionally.
    final nonRest = session.exercises.where((e) => !e.isRest).toList();
    final allMainUploaded =
        nonRest.every((e) => e.rawArchiveUploadedAt != null);
    if (allMainUploaded) {
      debugPrint(
        '_uploadRawArchives: main archives previously uploaded — '
        'running variant-thumb backfill only',
      );
    }

    // Some exercises need uploading. List existing files once.
    final existingRaw = <String>{};
    try {
      final listing = await _api.listRawArchive(
        prefix: '$practiceId/${session.id}',
      );
      for (final item in listing) {
        existingRaw.add('$practiceId/${session.id}/${item.name}');
      }
    } catch (_) {}

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

      // Skip if already in storage (existence check from listing above).
      if (existingRaw.contains(storagePath)) {
        debugPrint('_uploadRawArchives: skip $storagePath (exists)');
        // Still stamp locally so future publishes skip the listing check too.
        await loudSwallow(
          () => _storage.saveExercise(
            exercise.copyWith(rawArchiveUploadedAt: DateTime.now()),
          ),
          kind: 'raw_archive_local_stamp',
          source: 'UploadService._uploadRawArchives',
          severity: 'info',
          swallow: true,
        );
        continue;
      }

      final ok = await loudSwallow<bool>(
        () async {
          await _api.uploadRawArchive(path: storagePath, file: file);
          return true;
        },
        kind: 'raw_archive_upload_failed',
        source: 'UploadService._uploadRawArchives',
        severity: 'warn',
        meta: {
          'practice_id': practiceId,
          'plan_id': session.id,
          'exercise_id': exercise.id,
          'storage_path': storagePath,
          'local_path': absPath,
          'file_exists': file.existsSync(),
        },
        swallow: true,
      );
      if (ok != true) {
        debugPrint(
          '_uploadRawArchives FAILED kind=raw_archive_upload_failed '
          'path=$storagePath local=$absPath exists=${file.existsSync()}',
        );
        failures.add(UploadFailureRecord(
          kind: 'raw_archive_upload_failed',
          storagePath: storagePath,
          localPath: absPath,
          fileExists: file.existsSync(),
          exerciseId: exercise.id,
          exerciseIndex: indexByExerciseId[exercise.id],
          exerciseName: nameByExerciseId[exercise.id],
        ));
        // loudSwallow swallowed the throw. Keep the legacy on-device
        // breadcrumb so existing diagnostic tooling still sees it, even
        // though the primary signal now goes via log_error.
        await _logRawArchiveFailure(
          exercise.id,
          storagePath,
          'loudSwallow route — see diagnostics.log',
          StackTrace.current,
        );
        continue;
      }
      onSuccessfulTick?.call();

      // Persist the success locally so a subsequent publish skips this
      // file. A DB hiccup here must not mask the fact that the upload
      // itself succeeded — swallow + log loudly.
      await loudSwallow(
        () => _storage.saveExercise(
          exercise.copyWith(rawArchiveUploadedAt: DateTime.now()),
        ),
        kind: 'raw_archive_local_stamp_failed',
        source: 'UploadService._uploadRawArchives',
        severity: 'warn',
        meta: {
          'exercise_id': exercise.id,
          'storage_path': storagePath,
        },
        swallow: true,
      );
    }

    // --- Segmented-color raw variant (Option 1-augment) ---
    //
    // Independent best-effort pass for the dual-output segmented mp4 the
    // native converter writes alongside the line drawing. Stored at
    // `{practiceId}/{planId}/{exerciseId}.segmented.mp4` in the same
    // private `raw-archive` bucket. The web player's Color + B&W
    // treatments pull this over the untouched original when
    // `get_plan_full` returns a signed URL for it.
    //
    // Why a second loop (not folded into the one above):
    //   * The two files are independently produced and independently
    //     tracked — the segmented file can be missing on legacy rows
    //     while the original is present, or vice versa on a future
    //     re-run of just the segmented pass.
    //   * Re-publish idempotency is the same pattern either way, but
    //     we intentionally do NOT track "segmented uploaded" with a
    //     dedicated column — Supabase storage upserts are safe to
    //     retry, and skipping by filename prefix keeps the schema
    //     smaller. Re-publishes will re-transfer if needed; the file
    //     is small (720p + dim) and this is the exception path, not
    //     the hot path.
    //   * Failure here MUST NOT affect the original upload bookkeeping
    //     above — we've already stamped `rawArchiveUploadedAt` for
    //     the original; the segmented variant is additive.
    for (final exercise in session.exercises) {
      if (exercise.isRest) continue;
      final segRel = exercise.segmentedRawFilePath;
      if (segRel == null || segRel.isEmpty) continue;
      final absSeg = exercise.absoluteSegmentedRawFilePath;
      if (absSeg == null) continue;
      final segFile = File(absSeg);
      if (!segFile.existsSync()) {
        debugPrint(
          'UploadService: segmented raw file missing for exercise ${exercise.id} '
          'at $absSeg — skipping.',
        );
        continue;
      }
      // Wave 36 — `segmented_raw_file_path` now spans BOTH videos
      // (`.segmented.mp4`) AND photos (`.segmented.jpg`). The native
      // pipeline writes whichever extension is appropriate; the upload
      // path mirrors that suffix so `get_plan_full` can sign a URL
      // against the right object. Pick MIME + storage suffix off the
      // local file's actual extension rather than hard-coding `.mp4`.
      final localExt = p.extension(absSeg).toLowerCase();
      final isPhotoSegmented = localExt == '.jpg' || localExt == '.jpeg';
      final segSuffix = isPhotoSegmented ? '.segmented.jpg' : '.segmented.mp4';
      final segMime = isPhotoSegmented ? 'image/jpeg' : 'video/mp4';
      final segStoragePath =
          '$practiceId/${session.id}/${exercise.id}$segSuffix';
      if (existingRaw.contains(segStoragePath)) {
        debugPrint('_uploadRawArchives: skip $segStoragePath (exists)');
        continue;
      }
      final ok = await loudSwallow<bool>(
        () async {
          await _api.uploadRawArchive(
            path: segStoragePath,
            file: segFile,
            contentType: segMime,
          );
          return true;
        },
        kind: 'raw_archive_segmented_upload_failed',
        source: 'UploadService._uploadRawArchives',
        severity: 'warn',
        meta: {
          'practice_id': practiceId,
          'plan_id': session.id,
          'exercise_id': exercise.id,
          'storage_path': segStoragePath,
          'local_path': absSeg,
          'file_exists': segFile.existsSync(),
        },
        swallow: true,
      );
      if (ok != true) {
        debugPrint(
          '_uploadRawArchives FAILED kind=raw_archive_segmented_upload_failed '
          'path=$segStoragePath local=$absSeg exists=${segFile.existsSync()}',
        );
        failures.add(UploadFailureRecord(
          kind: 'raw_archive_segmented_upload_failed',
          storagePath: segStoragePath,
          localPath: absSeg,
          fileExists: segFile.existsSync(),
          exerciseId: exercise.id,
          exerciseIndex: indexByExerciseId[exercise.id],
          exerciseName: nameByExerciseId[exercise.id],
        ));
      } else {
        onSuccessfulTick?.call();
      }
    }

    // --- Photo raw upload (Wave 22) ---
    //
    // Independent best-effort pass for photo exercises. The line-drawing JPG
    // already shipped to the public `media` bucket above (Step 5). Here we
    // ship the COLOR raw photo to the private `raw-archive` bucket at:
    //   `{practiceId}/{planId}/{exerciseId}.jpg`
    //
    // This unlocks the three-treatment story for photos: get_plan_full's
    // signed URL flips on `original_url` (consent-gated AT THE RPC LAYER),
    // the web player shows Colour + B&W as enabled segments and applies
    // the same CSS grayscale filter to the <img> at playback time. Same
    // source object serves both — no second file.
    //
    // PR-A (2026-05-15): consent gate removed from this loop. Every photo
    // raw uploads on every publish regardless of `colourAllowed` — see the
    // policy comment at the top of this function.
    //
    // Pattern mirrors the video raw-upload above (line 891+):
    //   * per-exercise try/catch via loudSwallow — one failure can't poison
    //     the rest;
    //   * skipped silently when the source file is missing on disk;
    //   * legacy photos with no separate raw on device fall through —
    //     the line drawing already shipped, the web player handles
    //     `original_url=null` gracefully.
    //
    // Photos now stamp `rawArchiveUploadedAt` on successful upload — same
    // pattern as videos above. Before 2026-05-15 only videos stamped, so the
    // fast-path skip (`nonRestExercises.every(e => e.rawArchiveUploadedAt
    // != null)`) at the top of this function never fired for photo plans.
    // On re-publish the existence-check loop ran, but `listRawArchive`
    // returns empty (the bucket has no SELECT policy for `authenticated` by
    // design — privacy model), so every photo's variants attempted upload,
    // hit 409 Duplicate, and the publish reported "0 of N files".
    //
    // Now: photo upload success stamps the timestamp + saves the exercise.
    // Next publish's fast-path skip handles the no-change case with zero
    // upload attempts. Belt-and-braces: `uploadRawArchive` now uses
    // `upsert: true`, so even if a row escapes the stamp the re-upload is
    // an idempotent silent overwrite (no exception, no failure record).
    for (final exercise in session.exercises) {
      if (exercise.isRest) continue;
      if (exercise.mediaType.name != 'photo') continue;
      final rawRel = exercise.rawFilePath;
      if (rawRel.isEmpty) continue;
      final absRaw = exercise.absoluteRawFilePath;
      final rawFile = File(absRaw);
      if (!rawFile.existsSync()) {
        debugPrint(
          'UploadService: raw photo missing for exercise ${exercise.id} '
          'at $absRaw — skipping (pre-migration / pruned).',
        );
        continue;
      }
      final ext = p.extension(absRaw).toLowerCase();
      // Default to .jpg when the camera handed us something exotic —
      // the file content is fine, the bucket only cares about the path
      // segment for RLS, and get_plan_full's signed URL hard-codes
      // .jpg as the suffix.
      final normalisedExt =
          (ext == '.jpg' || ext == '.jpeg' || ext == '.png' || ext == '.heic')
              ? '.jpg'
              : '.jpg';
      final mime = (ext == '.png')
          ? 'image/png'
          : (ext == '.heic' ? 'image/heic' : 'image/jpeg');
      final storagePath =
          '$practiceId/${session.id}/${exercise.id}$normalisedExt';
      if (existingRaw.contains(storagePath)) {
        debugPrint('_uploadRawArchives: skip photo $storagePath (exists)');
        // Still stamp locally so future publishes hit the fast-path skip
        // and don't even bother with the listing call. Mirrors the video
        // exists-skip stamping above.
        if (exercise.rawArchiveUploadedAt == null) {
          await loudSwallow(
            () => _storage.saveExercise(
              exercise.copyWith(rawArchiveUploadedAt: DateTime.now()),
            ),
            kind: 'raw_archive_local_stamp',
            source: 'UploadService._uploadRawArchives',
            severity: 'info',
            swallow: true,
          );
        }
        continue;
      }
      final ok = await loudSwallow<bool>(
        () async {
          await _api.uploadRawArchive(
            path: storagePath,
            file: rawFile,
            contentType: mime,
          );
          return true;
        },
        kind: 'raw_archive_photo_upload_failed',
        source: 'UploadService._uploadRawArchives',
        severity: 'warn',
        meta: {
          'practice_id': practiceId,
          'plan_id': session.id,
          'exercise_id': exercise.id,
          'storage_path': storagePath,
          'local_path': absRaw,
          'file_exists': rawFile.existsSync(),
        },
        swallow: true,
      );
      if (ok != true) {
        debugPrint(
          '_uploadRawArchives FAILED kind=raw_archive_photo_upload_failed '
          'path=$storagePath local=$absRaw exists=${rawFile.existsSync()}',
        );
        failures.add(UploadFailureRecord(
          kind: 'raw_archive_photo_upload_failed',
          storagePath: storagePath,
          localPath: absRaw,
          fileExists: rawFile.existsSync(),
          exerciseId: exercise.id,
          exerciseIndex: indexByExerciseId[exercise.id],
          exerciseName: nameByExerciseId[exercise.id],
        ));
      } else {
        onSuccessfulTick?.call();
        // Persist the success locally so the next publish skips this
        // photo via the fast-path. A DB hiccup here must not mask the
        // fact that the upload itself succeeded — swallow + log loudly.
        // Mirrors the video success stamping above.
        await loudSwallow(
          () => _storage.saveExercise(
            exercise.copyWith(rawArchiveUploadedAt: DateTime.now()),
          ),
          kind: 'raw_archive_local_stamp_failed',
          source: 'UploadService._uploadRawArchives',
          severity: 'warn',
          meta: {
            'exercise_id': exercise.id,
            'storage_path': storagePath,
          },
          swallow: true,
        );
      }
    }

    // --- Color Hero JPG upload (Wave Three-Treatment-Thumbs, 2026-05-05) ---
    //
    // For every video exercise, upload `_thumb_color.jpg` (color frame
    // from raw, no body-pop) to the private `raw-archive` bucket at:
    //   `{practiceId}/{planId}/{exerciseId}_thumb_color.jpg`
    //
    // The web player + Workflow Preview pull this for B&W and Original
    // treatments via the get_plan_full RPC's signed URL. CSS
    // grayscale(1) filter renders the B&W variant from the same source.
    //
    // PR-A (2026-05-15): consent gate removed. Every `_thumb_color.jpg`
    // uploads on every publish regardless of `grayscaleAllowed` /
    // `colourAllowed`. Visibility is gated player-side via
    // `get_plan_full`'s NULL signed URLs when consent is missing — see
    // the policy comment at the top of this function.
    for (final exercise in session.exercises) {
      if (exercise.isRest) continue;
      // Bundle 2b — photos now produce a `_thumb_color.jpg` variant
      // alongside videos (the variant pipeline lives in
      // conversion_service.dart's photo branch). Without the matching
      // photo branch every photo plan published since Bundle 2b would
      // re-upload the raw colour image as `_thumb_color.jpg` via the
      // `_thumb_line.jpg` replaceFirst no-op (latent bug pre-2b too).
      // Same storage path — videos + photos converge.
      final mediaName = exercise.mediaType.name;
      if (mediaName != 'video' && mediaName != 'photo') continue;
      final thumbAbs = exercise.absoluteThumbnailPath;
      if (thumbAbs == null) continue;
      // Convention: native (video) / OpenCV-isolate (photo) conversion
      // writes _thumb_color.jpg next to _thumb.jpg in the same
      // {Documents}/thumbnails/ directory. Pre-Bundle-2b photo rows
      // had `thumbnailPath = rawFilePath` (not under thumbnails/),
      // so the replaceFirst was a no-op + the existsSync skipped them.
      // Post-2b rows resolve correctly.
      final colorThumbAbs =
          thumbAbs.replaceFirst('_thumb.jpg', '_thumb_color.jpg');
      if (colorThumbAbs == thumbAbs) {
        // Defensive: legacy photo rows whose thumbnailPath wasn't
        // touched by Bundle 2b (e.g. capture that pre-dated install).
        // Skip — no variant exists on disk.
        continue;
      }
      final colorFile = File(colorThumbAbs);
      if (!colorFile.existsSync()) {
        debugPrint(
          'UploadService: color thumb missing for ${exercise.id} '
          '($mediaName) at $colorThumbAbs — skipping.',
        );
        continue;
      }
      final colorStoragePath =
          '$practiceId/${session.id}/${exercise.id}_thumb_color.jpg';
      if (existingRaw.contains(colorStoragePath)) {
        debugPrint('_uploadRawArchives: skip $colorStoragePath (exists)');
        continue;
      }
      final ok = await loudSwallow<bool>(
        () async {
          await _api.uploadRawArchive(
            path: colorStoragePath,
            file: colorFile,
            contentType: 'image/jpeg',
          );
          return true;
        },
        kind: 'raw_archive_color_thumb_failed',
        source: 'UploadService._uploadRawArchives',
        severity: 'warn',
        meta: {
          'practice_id': practiceId,
          'plan_id': session.id,
          'exercise_id': exercise.id,
          'media_type': mediaName,
          'storage_path': colorStoragePath,
          'local_path': colorThumbAbs,
          'file_exists': colorFile.existsSync(),
        },
        swallow: true,
      );
      if (ok != true) {
        debugPrint(
          '_uploadRawArchives FAILED kind=raw_archive_color_thumb_failed '
          'path=$colorStoragePath local=$colorThumbAbs '
          'exists=${colorFile.existsSync()}',
        );
        failures.add(UploadFailureRecord(
          kind: 'raw_archive_color_thumb_failed',
          storagePath: colorStoragePath,
          localPath: colorThumbAbs,
          fileExists: colorFile.existsSync(),
          exerciseId: exercise.id,
          exerciseIndex: indexByExerciseId[exercise.id],
          exerciseName: nameByExerciseId[exercise.id],
        ));
      } else {
        onSuccessfulTick?.call();
      }
    }

    // --- Person-segmentation mask sidecar (Milestone P2) ---
    //
    // Third independent best-effort pass. Uploads the grayscale mask mp4
    // produced by the native third AVAssetWriter to:
    //   `{practiceId}/{planId}/{exerciseId}.mask.mp4`
    //
    // Same structural contract as the segmented loop above:
    //   * Fully independent from the original + segmented passes — a
    //     failure here MUST NOT disturb either of them (or vice versa).
    //   * Skipped silently when `maskFilePath` is null (legacy rows,
    //     mask writer failed non-fatally, OpenCV fallback that doesn't
    //     produce a mask).
    //   * No dedicated "mask uploaded at" column. Storage upserts are
    //     idempotent; re-publishes re-transfer, matching the segmented
    //     file's pattern.
    //   * Today the mask has NO consumer. Storing it now is insurance
    //     so future playback-time compositing (tunable backgroundDim,
    //     other effects) can work against already-published plans.
    for (final exercise in session.exercises) {
      if (exercise.isRest) continue;
      final maskRel = exercise.maskFilePath;
      if (maskRel == null || maskRel.isEmpty) continue;
      final absMask = exercise.absoluteMaskFilePath;
      if (absMask == null) continue;
      final maskFile = File(absMask);
      if (!maskFile.existsSync()) {
        debugPrint(
          'UploadService: mask sidecar file missing for exercise ${exercise.id} '
          'at $absMask — skipping.',
        );
        continue;
      }
      final maskStoragePath =
          '$practiceId/${session.id}/${exercise.id}.mask.mp4';
      if (existingRaw.contains(maskStoragePath)) {
        debugPrint('_uploadRawArchives: skip $maskStoragePath (exists)');
        continue;
      }
      final ok = await loudSwallow<bool>(
        () async {
          await _api.uploadRawArchive(path: maskStoragePath, file: maskFile);
          return true;
        },
        kind: 'raw_archive_mask_upload_failed',
        source: 'UploadService._uploadRawArchives',
        severity: 'warn',
        meta: {
          'practice_id': practiceId,
          'plan_id': session.id,
          'exercise_id': exercise.id,
          'storage_path': maskStoragePath,
          'local_path': absMask,
          'file_exists': maskFile.existsSync(),
        },
        swallow: true,
      );
      if (ok != true) {
        debugPrint(
          '_uploadRawArchives FAILED kind=raw_archive_mask_upload_failed '
          'path=$maskStoragePath local=$absMask exists=${maskFile.existsSync()}',
        );
        failures.add(UploadFailureRecord(
          kind: 'raw_archive_mask_upload_failed',
          storagePath: maskStoragePath,
          localPath: absMask,
          fileExists: maskFile.existsSync(),
          exerciseId: exercise.id,
          exerciseIndex: indexByExerciseId[exercise.id],
          exerciseName: nameByExerciseId[exercise.id],
        ));
      } else {
        onSuccessfulTick?.call();
      }
    }
    return failures;
  }

  /// Append a raw-archive upload failure to `{Documents}/raw_archive_error.log`.
  /// Swallows its own errors — this is a best-effort breadcrumb, never
  /// block publish on its behalf.
  ///
  /// Kept for continuity after Wave 7 routed the primary signal through
  /// `loudSwallow` (which writes the server-side `error_logs` row + the
  /// new shared `{Documents}/diagnostics.log`). This file-specific log
  /// is legacy forensic surface that the filter workbench / on-device
  /// support affordance already know to look at.
  Future<void> _logRawArchiveFailure(
    String exerciseId,
    String storagePath,
    Object error,
    StackTrace st,
  ) async {
    await loudSwallow(
      () async {
        final dir = await getApplicationDocumentsDirectory();
        final logFile = File(p.join(dir.path, 'raw_archive_error.log'));
        await logFile.writeAsString(
          '${DateTime.now().toIso8601String()}  exercise=$exerciseId  path=$storagePath\n'
          '  $error\n'
          '  ${st.toString().split('\n').take(4).join('\n  ')}\n\n',
          mode: FileMode.append,
          flush: true,
        );
      },
      kind: 'raw_archive_log_write_failed',
      source: 'UploadService._logRawArchiveFailure',
      severity: 'warn',
      swallow: true,
    );
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
  Future<bool> _refundCredits({
    required String practiceId,
    required String planId,
    required int credits,
  }) async {
    // [ApiClient.refundCredit] already swallows RPC errors — best-effort
    // semantics are preserved; see docstring above for the ledger
    // reconciliation contract.
    return _api.refundCredit(planId: planId);
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
    await loudSwallow(
      () => _storage.db.rawUpdate(
        'UPDATE sessions '
        'SET last_publish_error = ?, '
        '    publish_attempt_count = COALESCE(publish_attempt_count, 0) + 1 '
        'WHERE id = ?',
        [truncated, session.id],
      ),
      kind: 'publish_error_record_failed',
      source: 'UploadService._recordFailure',
      severity: 'warn',
      meta: {'session_id': session.id},
      // Schema v11 not applied yet — skip. Not fatal; publish flow
      // has already returned its PublishResult.
      swallow: true,
    );
  }

  /// On success: clear `last_publish_error`. Keep `publish_attempt_count`
  /// so the UI can show "took N tries" history if we ever want it.
  Future<void> _recordSuccess(String sessionId) async {
    await loudSwallow(
      () => _storage.db.rawUpdate(
        'UPDATE sessions SET last_publish_error = NULL WHERE id = ?',
        [sessionId],
      ),
      kind: 'publish_success_record_failed',
      source: 'UploadService._recordSuccess',
      severity: 'warn',
      meta: {'session_id': sessionId},
      // Schema v11 not applied yet — skip.
      swallow: true,
    );
  }

  /// Read the last publish error for a session, if any. Returns null when
  /// the column doesn't exist yet (schema v11 not applied) or no error is
  /// stored.
  Future<String?> getLastPublishError(String sessionId) async {
    final result = await loudSwallow<String?>(
      () async {
        final rows = await _storage.db.query(
          'sessions',
          columns: ['last_publish_error'],
          where: 'id = ?',
          whereArgs: [sessionId],
        );
        if (rows.isEmpty) return null;
        final v = rows.first['last_publish_error'];
        return v is String && v.isNotEmpty ? v : null;
      },
      kind: 'publish_error_read_failed',
      source: 'UploadService.getLastPublishError',
      severity: 'warn',
      meta: {'session_id': sessionId},
      swallow: true,
    );
    return result;
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
