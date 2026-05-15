/// Publish-progress model for PR-C of the 2026-05-15 publish-flow refactor.
///
/// Drives the new bottom-sheet UI defined in
/// `docs/design/mockups/publish-progress-sheet.html`. The `uploadPlan` service
/// emits one [PublishProgress] event on every phase boundary and on every
/// per-file tick within phase 3 ("Uploading treatments"). The sheet subscribes
/// to the stream and re-renders against the latest snapshot.
///
/// Phases (in order):
///
/// 1. [PublishPhase.preparing]          — preflight + consent gates + balance check.
/// 2. [PublishPhase.reservingCredit]    — `upsert_client` + plan ensure + `consume_credit`.
/// 3. [PublishPhase.uploadingTreatments] — `media` bucket main+thumb push + raw-archive
///                                          variant push. Carries `filesUploaded` /
///                                          `filesTotal` so the sheet can render the
///                                          "N of M files" subtitle + progress bar.
/// 4. [PublishPhase.savingPlan]         — version bump + exercise upsert.
/// 5. [PublishPhase.finalising]         — audit row + local session save.
///
/// Each phase carries a [PublishPhaseStatus]. The active phase pulses; done
/// phases render a green check; failed phases render a coral "!" and halt the
/// subsequent rows. Once any phase fails, [failedPhase] is set and the rest
/// stay [PublishPhaseStatus.pending].
library;

/// Ordered enum of publish phases. Index = row position in the sheet (0-4).
enum PublishPhase {
  preparing,
  reservingCredit,
  uploadingTreatments,
  savingPlan,
  finalising,
}

/// One per-file failure record captured during the best-effort raw-archive
/// upload pass in [UploadService._uploadRawArchives]. PR #335 added
/// `debugPrint` lines on each `loudSwallow` miss; the in-app diagnostic
/// sheet (`widgets/upload_diagnostic_sheet.dart`) needs the same data on
/// the UI side without parsing log output, so we now collect a list of
/// these alongside the `hadFailures` bool and surface it through
/// [PublishResult.optionalArtifactFailures] and (PR-C reactive fix) the
/// [PublishProgress.failure] event's [PublishProgress.failures] field.
///
/// Lives in the model layer (was in `upload_service.dart` originally) so
/// [PublishProgress] can carry it without a circular import — the service
/// already imports the model.
///
/// Fields mirror the `meta` map passed to `loudSwallow` so a paste of the
/// "Copy all" output reads the same as a server-side `error_logs` row.
class UploadFailureRecord {
  /// loudSwallow `kind` — e.g. `raw_archive_color_thumb_failed`,
  /// `raw_archive_segmented_upload_failed`. Same value the support
  /// console search would key off.
  final String kind;

  /// `{practice_id}/{plan_id}/{exercise_id}<suffix>` — the bucket path
  /// the upload was targeting at the time of failure.
  final String storagePath;

  /// Absolute on-device path of the source file we were trying to push.
  /// Captured so Carl can spot truncated or zero-byte source files even
  /// when the storage path looks reasonable.
  final String localPath;

  /// `File(localPath).existsSync()` AT the failure point — answers the
  /// "did the source disappear?" question that's otherwise invisible
  /// from a debug log alone.
  final bool fileExists;

  /// 0-based slot of this exercise within `session.exercises` (the same
  /// order the practitioner sees in Studio). Null when we can't compute
  /// it (defensive — should always be set).
  final int? exerciseIndex;

  /// Display name of the exercise at upload time, if any. Falls back to
  /// the trimmed exercise id when the practitioner hasn't named it yet.
  final String? exerciseName;

  /// Exercise UUID — pulled into its own field so the diagnostic row
  /// can render a short id when [exerciseName] is null.
  final String exerciseId;

  const UploadFailureRecord({
    required this.kind,
    required this.storagePath,
    required this.localPath,
    required this.fileExists,
    required this.exerciseId,
    this.exerciseIndex,
    this.exerciseName,
  });

  /// Plain-text representation for the "Copy all" affordance. One block
  /// per record, separated by a blank line in the caller. Mirrors the
  /// shape the existing `loudSwallow` debugPrint produces so a paste of
  /// the clipboard is grep-compatible with terminal logs.
  String toClipboardText() {
    final indexPart = exerciseIndex != null ? '#${exerciseIndex! + 1}' : '#?';
    final namePart = (exerciseName == null || exerciseName!.isEmpty)
        ? exerciseId
        : exerciseName!;
    return 'kind=$kind\n'
        'exercise=$indexPart $namePart ($exerciseId)\n'
        'storage_path=$storagePath\n'
        'local_path=$localPath\n'
        'file_exists=$fileExists';
  }
}

/// Per-phase status driving the row's visual treatment in the sheet.
enum PublishPhaseStatus {
  /// Not yet started — grey circle.
  pending,

  /// Currently running — coral pulse.
  active,

  /// Completed — green check.
  done,

  /// Failed — coral "!". Subsequent rows stay pending.
  failed,
}

/// Human-readable row labels for the sheet. Locked by the spec.
extension PublishPhaseLabels on PublishPhase {
  String get title {
    switch (this) {
      case PublishPhase.preparing:
        return 'Preparing';
      case PublishPhase.reservingCredit:
        return 'Reserving credit';
      case PublishPhase.uploadingTreatments:
        return 'Uploading treatments';
      case PublishPhase.savingPlan:
        return 'Saving plan';
      case PublishPhase.finalising:
        return 'Finalising';
    }
  }
}

/// Snapshot emitted on every phase / per-file boundary. Immutable; the sheet
/// rebuilds against the latest event in the stream.
///
/// The full status map is recomputed each emit so the consumer never has to
/// hold previous events — `events.last` is always sufficient to render.
class PublishProgress {
  /// Status of every phase. Always has all 5 keys (one per [PublishPhase]).
  /// On the happy path this transitions: pending → active → done.
  final Map<PublishPhase, PublishPhaseStatus> statuses;

  /// The phase currently running, or null after all five complete /
  /// after a failure where every later phase was skipped.
  final PublishPhase? currentPhase;

  /// The phase that failed, or null on the happy path. When non-null the
  /// publish is terminal — the sheet renders the retry CTA.
  final PublishPhase? failedPhase;

  /// Files uploaded so far in [PublishPhase.uploadingTreatments]. Only
  /// non-zero while that phase is active or has completed. Zero outside
  /// the upload window.
  final int filesUploaded;

  /// Total files expected to upload in [PublishPhase.uploadingTreatments].
  /// Zero outside the upload window (or for fast-path metadata-only
  /// republishes where nothing is uploaded).
  final int filesTotal;

  /// True only on the terminal success event (all five rows done).
  final bool allDone;

  /// Per-file failure records carried by the terminal failure event so
  /// the sheet's "Show which files →" tap-target appears on the same
  /// stream rebuild that flips [failed] to true.
  ///
  /// Empty on every non-terminal event and on success. Populated only on
  /// the failure event emitted by [UploadService.uploadPlan]'s
  /// [PublishFailedException] catch.
  ///
  /// PR-C reactive-failures fix (2026-05-15) — previously the sheet
  /// captured a `List<UploadFailureRecord>` prop at construction time
  /// (empty initially), and the out-of-band `setState` in studio_mode
  /// after `uploadPlan()` returned never propagated to the
  /// already-constructed sheet widget. Reading from the stream snapshot
  /// guarantees the tap-target appears the moment the failure event
  /// lands.
  final List<UploadFailureRecord> failures;

  const PublishProgress({
    required this.statuses,
    required this.currentPhase,
    required this.failedPhase,
    required this.filesUploaded,
    required this.filesTotal,
    required this.allDone,
    this.failures = const [],
  });

  /// Convenience: the upload-phase subtitle "N of M files". Empty when
  /// not in the upload phase or when no files are queued.
  String get filesSubtitle {
    if (filesTotal == 0) return '';
    return '$filesUploaded of $filesTotal files';
  }

  /// Convenience: the fraction (0.0..1.0) of files uploaded in the
  /// uploading-treatments phase. Returns 0 when [filesTotal] is zero.
  double get filesFraction {
    if (filesTotal == 0) return 0;
    return (filesUploaded / filesTotal).clamp(0.0, 1.0);
  }

  /// Convenience: did publish fail at any phase?
  bool get failed => failedPhase != null;

  /// Status helper.
  PublishPhaseStatus statusOf(PublishPhase phase) =>
      statuses[phase] ?? PublishPhaseStatus.pending;

  /// Build the next snapshot after marking [phase] as active.
  factory PublishProgress.markActive(PublishPhase phase) {
    final statuses = <PublishPhase, PublishPhaseStatus>{};
    for (final p in PublishPhase.values) {
      if (p.index < phase.index) {
        statuses[p] = PublishPhaseStatus.done;
      } else if (p == phase) {
        statuses[p] = PublishPhaseStatus.active;
      } else {
        statuses[p] = PublishPhaseStatus.pending;
      }
    }
    return PublishProgress(
      statuses: statuses,
      currentPhase: phase,
      failedPhase: null,
      filesUploaded: 0,
      filesTotal: 0,
      allDone: false,
    );
  }

  /// Build the per-file tick snapshot for the upload phase. Keeps every
  /// earlier phase done, this phase active, subsequent phases pending.
  factory PublishProgress.uploadTick({
    required int filesUploaded,
    required int filesTotal,
  }) {
    final statuses = <PublishPhase, PublishPhaseStatus>{};
    for (final p in PublishPhase.values) {
      if (p.index < PublishPhase.uploadingTreatments.index) {
        statuses[p] = PublishPhaseStatus.done;
      } else if (p == PublishPhase.uploadingTreatments) {
        statuses[p] = PublishPhaseStatus.active;
      } else {
        statuses[p] = PublishPhaseStatus.pending;
      }
    }
    return PublishProgress(
      statuses: statuses,
      currentPhase: PublishPhase.uploadingTreatments,
      failedPhase: null,
      filesUploaded: filesUploaded,
      filesTotal: filesTotal,
      allDone: false,
    );
  }

  /// Build the terminal success snapshot — every phase done.
  factory PublishProgress.allDone() {
    final statuses = <PublishPhase, PublishPhaseStatus>{};
    for (final p in PublishPhase.values) {
      statuses[p] = PublishPhaseStatus.done;
    }
    return PublishProgress(
      statuses: statuses,
      currentPhase: null,
      failedPhase: null,
      filesUploaded: 0,
      filesTotal: 0,
      allDone: true,
    );
  }

  /// Build the terminal failure snapshot — earlier phases done, the
  /// failing phase coral, later phases stay pending.
  ///
  /// [failures] carries per-file diagnostic records from the atomic
  /// upload path (see [UploadFailureRecord]). On the same stream event
  /// that flips [failed] to true, the progress sheet reads this list to
  /// decide whether to render the "Show which files →" tap-target.
  /// Defaults to empty for non-atomic-upload failure modes where no
  /// per-file detail is available.
  factory PublishProgress.failure({
    required PublishPhase phase,
    int filesUploaded = 0,
    int filesTotal = 0,
    List<UploadFailureRecord> failures = const [],
  }) {
    final statuses = <PublishPhase, PublishPhaseStatus>{};
    for (final p in PublishPhase.values) {
      if (p.index < phase.index) {
        statuses[p] = PublishPhaseStatus.done;
      } else if (p == phase) {
        statuses[p] = PublishPhaseStatus.failed;
      } else {
        statuses[p] = PublishPhaseStatus.pending;
      }
    }
    return PublishProgress(
      statuses: statuses,
      currentPhase: null,
      failedPhase: phase,
      filesUploaded: filesUploaded,
      filesTotal: filesTotal,
      allDone: false,
      failures: List.unmodifiable(failures),
    );
  }
}
