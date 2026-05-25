import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../config.dart';
import 'api_client.dart';
import 'face_embedding_service.dart';
import 'safe_mode.dart' show kSafeModeAlgorithmVersion;
import 'sync_service.dart';

/// Diagnostics gate for face-enrolment debug prints (2026-05-24).
/// Enabled in debug + staging profile so Carl can follow the sweep
/// state machine in Console.app; stays off in prod release.
bool get _kDiagLogs => kDebugMode || AppConfig.env == 'staging';

/// Safe Mode v2 multi-reference face enrolment (2026-05-24, Wave-D).
///
/// State machine controller for the Face-ID-style rotating-head sweep.
/// Owns the camera frame buffer + sweep timing + cancel handling + the
/// native embedding pass + the persist step. UI ([FaceEnrolmentScreen])
/// subscribes to [notifyListeners] for state changes and [errorStream]
/// for inline toast surfacing.
///
/// Lifecycle:
///   1. UI mounts the screen and calls [startSweep] once the camera
///      preview is ready. Service writes its first frame to a temp dir
///      and starts ticking through the yaw + pitch phases.
///   2. Yaw phase (~6s @ 4Hz capture cadence) → pitch phase (~4s) →
///      embedding phase (native MobileFaceNet pass on the captured
///      bundle).
///   3. Native returns 3-8 slots ordered by pose. Service transitions
///      to [FaceEnrolmentState.confirming] with the slot bundle on
///      [pendingSlots].
///   4. UI shows confirm view; on Done it calls [commit] which writes
///      to local SQLite then Supabase, copies the frontal-pick frame
///      into the avatars/ directory + queues the cloud avatar upload,
///      then transitions to [FaceEnrolmentState.done].
///   5. UI listens for [done] and pops back to client detail.
///
/// Hard-fails (per `feedback_no_silent_fallbacks`):
///   - Camera isn't ready when [startSweep] runs → caller surfaces an
///     inline toast and pops back.
///   - Frame capture throws → captures continue; if all yaw frames
///     fail we still attempt embedding with whatever we got. Native
///     handles "not enough valid faces" via [FaceEnrolmentError.notEnoughAngles].
///   - Native call returns [FaceEnrolmentError] → state goes to
///     [FaceEnrolmentState.failed] with the message, UI shows toast,
///     auto-pops after 4 seconds.
///   - Cloud RPC fails → local SQLite write still succeeded (offline-
///     first); user lands back on client detail with the new avatar,
///     and pending_ops will flush the cloud write on next online drain.
///
/// Cancel semantics:
///   - During sweep: stop the periodic capture timer, clean the temp
///     directory, transition to [FaceEnrolmentState.cancelled]. UI pops.
///   - During embedding: the native call cannot be killed mid-flight
///     (MobileFaceNet doesn't support interrupt). We let it complete,
///     throw the result away, and transition to cancelled.
///   - During persisting: same as embedding — we let the local write
///     complete (cheap) and discard. Cloud may still receive the
///     write if it was already in flight; acceptable trade-off.
class FaceEnrolmentService extends ChangeNotifier {
  FaceEnrolmentService();

  /// Same native channel as the conversion service. The
  /// `generateFaceEmbeddingsFromFrames` method was added by Wave-BC
  /// (PR #478) and is live on staging.
  @visibleForTesting
  static const MethodChannel videoChannel =
      MethodChannel('com.raidme.video_converter');

  // ── Sweep timing constants ──────────────────────────────────────────────
  //
  // Tuned for a ~10-15s total user-perceived run on real hardware. The
  // 4Hz capture cadence (250ms interval) keeps the frame buffer at ~40
  // captures across the full sweep, which gives the native side enough
  // pose-bucket coverage to pick a 5-8 slot set without choking on
  // the MobileFaceNet pass (~150-300ms per chip on A17).
  //
  // Tunable from device QA — if the practitioner can't keep up with
  // the yaw phase, bump _kYawDuration up and the tick cadence will
  // dilate proportionally.

  /// Yaw phase duration (L → R head rotation).
  static const Duration _kYawDuration = Duration(milliseconds: 6000);

  /// Pitch phase duration (up → down head rotation).
  static const Duration _kPitchDuration = Duration(milliseconds: 4000);

  /// Frame capture interval during the sweep. Lower = more frames =
  /// better pose coverage at the cost of disk + memory.
  static const Duration _kCaptureInterval = Duration(milliseconds: 250);

  /// Target slot count passed to native. Native clamps to [3, 8].
  static const int _kExpectedSlotCount = 6;

  /// Hard minimum slot count to persist. Below this we surface
  /// [FaceEnrolmentError.notEnoughAngles] so the practitioner re-runs
  /// the sweep rather than landing with a useless single-slot enrolment.
  static const int _kHardMinSlotCount = 3;

  /// Number of decorative tick marks on the arc ring. Drives the UI
  /// painter; not load-bearing for the algorithm. 6 ticks = one per
  /// (yaw + pitch) / 6 = ~1.67s.
  static const int kRingTickCount = 6;

  // ── Reactive state ──────────────────────────────────────────────────────

  FaceEnrolmentState _state = FaceEnrolmentState.idle;
  FaceEnrolmentState get state => _state;

  /// 0.0 → 1.0 normalised sweep progress. Drives the arc ring fill.
  /// Reaches 1.0 at the end of the pitch phase.
  double _progress = 0.0;
  double get progress => _progress;

  /// Instruction copy bound to the screen's primary label. Null while
  /// idle / done / cancelled.
  String? _instructionText;
  String? get instructionText => _instructionText;

  /// Captured frame paths during the sweep. Drained when persist
  /// succeeds or on cancel. Public for diagnostics + testing — UI
  /// does not consume this directly.
  final List<String> _capturedFramePaths = <String>[];
  List<String> get capturedFramePaths =>
      List<String>.unmodifiable(_capturedFramePaths);

  /// Picked slots returned from the native embedding pass. Bound to
  /// the confirm view's horizontal thumbnail strip.
  List<FaceEnrolmentSlot>? _pendingSlots;
  List<FaceEnrolmentSlot>? get pendingSlots => _pendingSlots;

  /// Last error if [state] == failed. Null otherwise.
  FaceEnrolmentError? _error;
  FaceEnrolmentError? get error => _error;

  /// Where captured frames live for the current run. Cleaned up on
  /// terminal transitions (done / cancelled / failed).
  Directory? _frameDir;

  /// Periodic timer driving frame capture during the sweep.
  Timer? _captureTimer;


  /// Single broadcast stream for error events. UI subscribes from
  /// `initState` and shows inline coral toasts. Errors also set
  /// [_state] to failed and [_error] for late subscribers.
  final StreamController<FaceEnrolmentError> _errorController =
      StreamController<FaceEnrolmentError>.broadcast();
  Stream<FaceEnrolmentError> get errorStream => _errorController.stream;

  /// Cancellation flag — set by [cancel], read by the sweep + commit
  /// loops to short-circuit cleanly.
  bool _cancelled = false;

  /// Frame producer hook. The screen wires this to its
  /// `_cameraController.takePicture()` flow. We don't own the camera
  /// here — the screen does — because the service shouldn't pin a
  /// camera plugin reference (testing pain + keeps the service free
  /// of UI deps). The hook returns a path to a JPG that the service
  /// then logs in the buffer.
  ///
  /// Set via [setFrameProducer] before [startSweep].
  Future<String?> Function()? _frameProducer;

  /// Bind the frame-producer hook. The screen calls this once after
  /// the camera is initialised, before [startSweep].
  void setFrameProducer(Future<String?> Function() producer) {
    _frameProducer = producer;
  }

  // ── Public API ──────────────────────────────────────────────────────────

  /// Begin the sweep. Transitions idle → sweepingYaw → sweepingPitch
  /// → embedding → confirming. Caller invokes once the camera preview
  /// is up and the screen is ready to render the ring.
  ///
  /// Pre-condition: [setFrameProducer] has been called. If the
  /// producer is null we fail fast with a [FaceEnrolmentError.camera]
  /// since there's no way to recover without the hook wired.
  Future<void> startSweep() async {
    if (_state != FaceEnrolmentState.idle) {
      if (_kDiagLogs) {
        debugPrint(
          '[FaceEnrolment] startSweep ignored — current state=$_state',
        );
      }
      return;
    }
    if (_frameProducer == null) {
      _emitError(const FaceEnrolmentError(
        type: FaceEnrolmentErrorType.camera,
        message: "Camera not ready — try again.",
      ));
      return;
    }
    _cancelled = false;
    _capturedFramePaths.clear();

    // Allocate a per-run temp directory so cancellation can wipe it
    // without disturbing other concurrent flows.
    try {
      final tempDir = await getTemporaryDirectory();
      final runId = DateTime.now().millisecondsSinceEpoch.toString();
      _frameDir = Directory(p.join(tempDir.path, 'face_enrol_$runId'));
      await _frameDir!.create(recursive: true);
    } catch (e) {
      if (_kDiagLogs) {
        debugPrint('[FaceEnrolment] frame dir create failed: $e');
      }
      _emitError(FaceEnrolmentError(
        type: FaceEnrolmentErrorType.io,
        message: "Couldn't prepare capture buffer: $e",
      ));
      return;
    }

    _setState(FaceEnrolmentState.sweepingYaw);
    _instructionText = "Slowly turn your head from left to right";
    notifyListeners();

    await _runPhase(_kYawDuration, baseProgress: 0.0, span: 0.6);
    if (_cancelled) {
      await _teardownFrames();
      _setState(FaceEnrolmentState.cancelled);
      return;
    }

    _setState(FaceEnrolmentState.sweepingPitch);
    _instructionText = "Now look up, then down";
    notifyListeners();

    await _runPhase(_kPitchDuration, baseProgress: 0.6, span: 0.4);
    if (_cancelled) {
      await _teardownFrames();
      _setState(FaceEnrolmentState.cancelled);
      return;
    }

    // Sweep complete — hand off to native for the embedding pass.
    _progress = 1.0;
    _setState(FaceEnrolmentState.embedding);
    _instructionText = "Almost there";
    notifyListeners();

    await _runEmbedding();
  }

  /// Cancel the run cleanly. Safe at any state. The service
  /// transitions to [FaceEnrolmentState.cancelled] and the UI pops.
  ///
  /// During [FaceEnrolmentState.embedding] / [FaceEnrolmentState.persisting]
  /// the in-flight native / cloud call is allowed to finish but its
  /// result is discarded.
  void cancel() {
    if (_state == FaceEnrolmentState.done ||
        _state == FaceEnrolmentState.cancelled ||
        _state == FaceEnrolmentState.failed) {
      return;
    }
    _cancelled = true;
    _captureTimer?.cancel();
    _captureTimer = null;
    if (_kDiagLogs) {
      debugPrint('[FaceEnrolment] cancel requested at state=$_state');
    }
    // If we were sweeping the _runPhase loop sees _cancelled on the
    // next tick and transitions. If we were embedding/persisting the
    // in-flight Future drains then checks the flag before setting
    // the success state.
    if (_state == FaceEnrolmentState.sweepingYaw ||
        _state == FaceEnrolmentState.sweepingPitch) {
      // Short-circuit immediately — _runPhase will exit on next tick.
      // For the case of a totally idle service we still flip to
      // cancelled so the UI route can pop deterministically.
    } else if (_state == FaceEnrolmentState.idle ||
        _state == FaceEnrolmentState.confirming) {
      // Confirming state has no in-flight work — flip immediately.
      _teardownFrames();
      _setState(FaceEnrolmentState.cancelled);
    }
  }

  /// Commit the enrolment — write to local + cloud. Caller is the
  /// confirm view's Done button. [clientId] is the parent client.
  ///
  /// Side effects (in order):
  ///   1. Local SQLite write via [LocalStorageService.setCachedClientFaceEmbeddings]
  ///      (mirrored from [SyncService.storage]).
  ///   2. Cloud RPC via [ApiClient.setClientFaceEmbeddings] —
  ///      best-effort. Failure does NOT block the local-side win;
  ///      SyncService picks it up on next pull.
  ///   3. Copy the frontal-pick frame into the persistent avatars/
  ///      directory at `{docs}/avatars/{clientId}.png` (the canonical
  ///      local path FaceEmbeddingService reads from).
  ///   4. Best-effort cloud avatar upload + `set_client_avatar` RPC
  ///      via SyncService.
  ///   5. Prime [FaceEmbeddingService] so the in-memory legacy single-
  ///      embedding state matches the new frontal-pick (back-compat
  ///      with conversion service callsites that still read the
  ///      singular cache during this release cycle).
  Future<void> commit({required String clientId}) async {
    if (_state != FaceEnrolmentState.confirming) {
      if (_kDiagLogs) {
        debugPrint(
          '[FaceEnrolment] commit ignored — state=$_state (expected confirming)',
        );
      }
      return;
    }
    final slots = _pendingSlots;
    if (slots == null || slots.isEmpty) {
      _emitError(const FaceEnrolmentError(
        type: FaceEnrolmentErrorType.notEnoughAngles,
        message: "Couldn't capture enough angles — try again",
      ));
      return;
    }

    _setState(FaceEnrolmentState.persisting);
    _instructionText = "Saving";
    notifyListeners();

    // Step 1: local SQLite write.
    try {
      await SyncService.instance.storage.setCachedClientFaceEmbeddings(
        clientId: clientId,
        slots: slots
            .map((s) => (
                  slotIndex: s.slotIndex,
                  embedding: s.embedding,
                  modelVersion: kSafeModeAlgorithmVersion,
                  isFrontalPick: s.isFrontalPick,
                  poseYaw: s.poseYaw,
                  posePitch: s.posePitch,
                ))
            .toList(growable: false),
      );
      if (_kDiagLogs) {
        debugPrint(
          '[FaceEnrolment] local write succeeded — '
          'client=$clientId slots=${slots.length}',
        );
      }
    } catch (e) {
      if (_kDiagLogs) {
        debugPrint('[FaceEnrolment] local write FAILED: $e');
      }
      _emitError(FaceEnrolmentError(
        type: FaceEnrolmentErrorType.io,
        message: "Couldn't save locally — try again ($e)",
      ));
      return;
    }

    if (_cancelled) {
      await _teardownFrames();
      _setState(FaceEnrolmentState.cancelled);
      return;
    }

    // Step 2: cloud RPC — best-effort, log failure but don't block.
    try {
      final frontalIdx = slots.indexWhere((s) => s.isFrontalPick);
      final safeFrontalIdx = frontalIdx >= 0 ? frontalIdx : 0;
      final ok = await ApiClient.instance.setClientFaceEmbeddings(
        clientId: clientId,
        embeddings:
            slots.map((s) => s.embedding).toList(growable: false),
        modelVersion: kSafeModeAlgorithmVersion,
        frontalPickSlotIndex: safeFrontalIdx,
        posesYaw: slots
            .map((s) => s.poseYaw ?? 0.0)
            .toList(growable: false),
        posesPitch: slots
            .map((s) => s.posePitch ?? 0.0)
            .toList(growable: false),
      );
      if (!ok && _kDiagLogs) {
        debugPrint(
          '[FaceEnrolment] cloud write returned false — sync will retry',
        );
      }
    } catch (e) {
      if (_kDiagLogs) {
        debugPrint('[FaceEnrolment] cloud write threw: $e — local stands');
      }
    }

    // Step 3 + 4: copy frontal-pick frame to avatars/ and best-effort
    // cloud avatar upload. We use the frontal-pick frame source from
    // the captured frame buffer; the slot tracks its source frame
    // index so we can copy the right file.
    try {
      await _writeFrontalAvatar(clientId: clientId, slots: slots);
    } catch (e) {
      // Avatar write is best-effort — the practitioner will see a
      // missing-avatar slot but enrolment itself succeeded. Log only.
      if (_kDiagLogs) {
        debugPrint('[FaceEnrolment] avatar write failed: $e');
      }
    }

    // Step 5: prime the legacy single-embedding cache so any
    // conversion callsite that still reads
    // FaceEmbeddingService.getEmbedding(clientId) sees the new frontal
    // pick (back-compat during this release cycle).
    try {
      final frontalSlot = slots.firstWhere(
        (s) => s.isFrontalPick,
        orElse: () => slots.first,
      );
      FaceEmbeddingService.instance.hydrateFromBytes(
        clientId,
        frontalSlot.embedding,
      );
    } catch (e) {
      if (_kDiagLogs) {
        debugPrint('[FaceEnrolment] legacy prime failed: $e');
      }
    }

    await _teardownFrames();
    _setState(FaceEnrolmentState.done);
    _instructionText = null;
    notifyListeners();
  }

  // ── Internal phases ─────────────────────────────────────────────────────

  /// Run one sweep phase (yaw or pitch). Drives [_progress] from
  /// `baseProgress` → `baseProgress + span` over `duration`, capturing
  /// a frame every [_kCaptureInterval]. Returns when the phase ends or
  /// [_cancelled] is set.
  Future<void> _runPhase(
    Duration duration, {
    required double baseProgress,
    required double span,
  }) async {
    final endAt = DateTime.now().add(duration);
    // Kick off the periodic capture timer.
    _captureTimer?.cancel();
    _captureTimer = Timer.periodic(_kCaptureInterval, (_) async {
      if (_cancelled) return;
      final producer = _frameProducer;
      if (producer == null) return;
      try {
        final path = await producer();
        if (path == null) return;
        if (_cancelled) {
          // Best-effort cleanup if the user cancelled mid-call.
          try {
            await File(path).delete();
          } catch (_) {}
          return;
        }
        _capturedFramePaths.add(path);
      } catch (e) {
        // Per-frame failures are non-fatal; the next tick retries.
        if (_kDiagLogs) {
          debugPrint('[FaceEnrolment] frame capture skipped: $e');
        }
      }
    });

    // Drive progress via short polls so the UI animates smoothly even
    // if individual captures are slow.
    while (!_cancelled && DateTime.now().isBefore(endAt)) {
      final elapsed = duration - endAt.difference(DateTime.now());
      final ratio = elapsed.inMilliseconds / duration.inMilliseconds;
      _progress = (baseProgress + (ratio.clamp(0.0, 1.0) * span))
          .clamp(0.0, 1.0)
          .toDouble();
      notifyListeners();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    _captureTimer?.cancel();
    _captureTimer = null;
    if (!_cancelled) {
      _progress = (baseProgress + span).clamp(0.0, 1.0).toDouble();
      notifyListeners();
    }
  }

  /// Run the native MobileFaceNet pass on the captured frame buffer.
  /// Transitions to confirming on success or failed on error.
  Future<void> _runEmbedding() async {
    if (_capturedFramePaths.isEmpty) {
      _emitError(const FaceEnrolmentError(
        type: FaceEnrolmentErrorType.notEnoughAngles,
        message: "Couldn't capture enough angles — try again",
      ));
      return;
    }

    try {
      final dynamic resp = await videoChannel
          .invokeMethod<Map<dynamic, dynamic>>(
            'generateFaceEmbeddingsFromFrames',
            <String, dynamic>{
              'framePaths': _capturedFramePaths,
              'expectedSlotCount': _kExpectedSlotCount,
            },
          )
          .timeout(const Duration(seconds: 30));

      if (resp == null) {
        _emitError(const FaceEnrolmentError(
          type: FaceEnrolmentErrorType.embeddingFailed,
          message: "Face recognition returned no result — try again.",
        ));
        return;
      }

      final map = Map<String, dynamic>.from(resp as Map);
      final List<dynamic> embsRaw =
          (map['embeddings'] as List<dynamic>?) ?? const [];
      final List<dynamic> yawsRaw =
          (map['posesYaw'] as List<dynamic>?) ?? const [];
      final List<dynamic> pitchesRaw =
          (map['posesPitch'] as List<dynamic>?) ?? const [];
      final int frontalIndex = (map['frontalPickSlot'] as int?) ?? 0;

      final embeddings = <Uint8List>[];
      for (final raw in embsRaw) {
        if (raw is Uint8List) {
          embeddings.add(raw);
        } else if (raw is List<int>) {
          embeddings.add(Uint8List.fromList(raw));
        }
      }

      if (embeddings.length < _kHardMinSlotCount) {
        _emitError(FaceEnrolmentError(
          type: FaceEnrolmentErrorType.notEnoughAngles,
          message: "Couldn't capture enough angles — try again "
              "(got ${embeddings.length} of $_kHardMinSlotCount min)",
        ));
        return;
      }

      // Cancel between native call and slot assembly — discard.
      if (_cancelled) {
        await _teardownFrames();
        _setState(FaceEnrolmentState.cancelled);
        return;
      }

      final slots = <FaceEnrolmentSlot>[];
      for (var i = 0; i < embeddings.length; i++) {
        final yaw = i < yawsRaw.length
            ? (yawsRaw[i] as num).toDouble()
            : null;
        final pitch = i < pitchesRaw.length
            ? (pitchesRaw[i] as num).toDouble()
            : null;
        slots.add(FaceEnrolmentSlot(
          slotIndex: i,
          embedding: embeddings[i],
          isFrontalPick: i == frontalIndex,
          poseYaw: yaw,
          posePitch: pitch,
          // The frontal-pick frame is whichever sweep frame had the
          // closest-to-zero yaw + pitch. Native side already returned
          // the metadata; we don't try to map back to a specific
          // captured file path here. The avatar copy step in commit()
          // re-derives the closest captured frame to "frontal" by
          // index proximity.
        ));
      }

      _pendingSlots = slots;
      _setState(FaceEnrolmentState.confirming);
      _instructionText = null;
      notifyListeners();
    } on PlatformException catch (e) {
      final code = e.code;
      // Native distinguishes "not enough frames" from generic failure
      // so the UI can show the right copy.
      if (code == 'NOT_ENOUGH_FRAMES') {
        _emitError(FaceEnrolmentError(
          type: FaceEnrolmentErrorType.notEnoughAngles,
          message:
              e.message ?? "Couldn't capture enough angles — try again",
        ));
      } else if (code == 'UNSUPPORTED_OS') {
        _emitError(FaceEnrolmentError(
          type: FaceEnrolmentErrorType.embeddingFailed,
          message:
              e.message ?? "Face recognition needs iOS 15 or newer.",
        ));
      } else {
        _emitError(FaceEnrolmentError(
          type: FaceEnrolmentErrorType.embeddingFailed,
          message: e.message ?? "Face recognition failed ($code).",
        ));
      }
    } on MissingPluginException catch (_) {
      _emitError(const FaceEnrolmentError(
        type: FaceEnrolmentErrorType.embeddingFailed,
        message: "Face recognition not available in this build.",
      ));
    } on TimeoutException catch (_) {
      _emitError(const FaceEnrolmentError(
        type: FaceEnrolmentErrorType.embeddingFailed,
        message: "Face recognition timed out — try again.",
      ));
    } catch (e) {
      _emitError(FaceEnrolmentError(
        type: FaceEnrolmentErrorType.embeddingFailed,
        message: "Face recognition failed: $e",
      ));
    }
  }

  /// Copy the frontal-pick frame into the persistent avatars/
  /// directory and queue the cloud-side avatar upload. The frontal-
  /// pick frame is approximated as the captured frame at the same
  /// list-index as the frontal slot, since native picks slots in
  /// frame-order. Best-effort — failure does not block the enrolment.
  Future<void> _writeFrontalAvatar({
    required String clientId,
    required List<FaceEnrolmentSlot> slots,
  }) async {
    final frontalSlotIdx = slots.indexWhere((s) => s.isFrontalPick);
    if (frontalSlotIdx < 0) return;
    if (_capturedFramePaths.isEmpty) return;

    // Best approximation: native returns slots ordered by capture
    // index, so the slot index roughly maps to a captured frame
    // index in the original buffer. We don't have an exact mapping,
    // so we use a proportional pick — the slot at idx `i` out of `N`
    // came from approximately frame `i * (M / N)` where M is the
    // captured buffer size. For the frontal pick (typically near the
    // middle of the yaw phase), this lands close enough that the
    // avatar JPG shows a recognisable headshot.
    //
    // Future improvement (out of scope for Wave-D): native returns the
    // source frame index for each slot in the response payload so we
    // can copy the exact frame.
    final approxCapturedIdx = ((frontalSlotIdx / slots.length) *
            _capturedFramePaths.length)
        .floor()
        .clamp(0, _capturedFramePaths.length - 1);
    final sourcePath = _capturedFramePaths[approxCapturedIdx];

    final docsDir = await getApplicationDocumentsDirectory();
    final avatarsDir = Directory(p.join(docsDir.path, 'avatars'));
    if (!avatarsDir.existsSync()) {
      avatarsDir.createSync(recursive: true);
    }
    final localAbs = p.join(avatarsDir.path, '$clientId.png');
    try {
      if (File(localAbs).existsSync()) {
        File(localAbs).deleteSync();
      }
    } catch (_) {}
    await File(sourcePath).copy(localAbs);

    // Queue cloud avatar upload via SyncService — the cloud path
    // encodes the practice scope so RLS approves the bucket write.
    try {
      final cached =
          await SyncService.instance.storage.getCachedClientById(clientId);
      if (cached == null) return;
      final cloudPath =
          '${cached.practiceId}/$clientId/avatar.png';
      try {
        await ApiClient.instance.uploadRawArchive(
          path: cloudPath,
          file: File(localAbs),
          contentType: 'image/png',
        );
      } catch (e) {
        if (_kDiagLogs) {
          debugPrint('[FaceEnrolment] avatar cloud upload failed: $e');
        }
      }
      await SyncService.instance.queueSetAvatar(
        clientId: clientId,
        avatarPath: cloudPath,
      );
    } catch (e) {
      if (_kDiagLogs) {
        debugPrint('[FaceEnrolment] avatar persist queue failed: $e');
      }
    }
  }

  /// Wipe the per-run frame buffer. Called on every terminal
  /// transition (done / cancelled / failed) so we don't leak temp
  /// files. Sync version is best-effort; async deletes await
  /// completion so the dir is gone before the next enrolment.
  Future<void> _teardownFrames() async {
    final dir = _frameDir;
    _frameDir = null;
    _capturedFramePaths.clear();
    if (dir == null) return;
    try {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (e) {
      if (_kDiagLogs) {
        debugPrint('[FaceEnrolment] frame teardown failed: $e');
      }
    }
  }

  // ── State plumbing ──────────────────────────────────────────────────────

  void _setState(FaceEnrolmentState next) {
    if (_state == next) return;
    _state = next;
    if (_kDiagLogs) {
      debugPrint('[FaceEnrolment] state → $next');
    }
    notifyListeners();
  }

  void _emitError(FaceEnrolmentError err) {
    _error = err;
    _state = FaceEnrolmentState.failed;
    _instructionText = null;
    // Capture timer + temp frames go away before the listener fires
    // so the next start (after a Retry) sees a clean slate.
    _captureTimer?.cancel();
    _captureTimer = null;
    // Don't await teardown — error UI pops 4s later; if we leak a few
    // frames in the meantime that's acceptable.
    unawaited(_teardownFrames());
    if (_kDiagLogs) {
      debugPrint('[FaceEnrolment] error → ${err.type}: ${err.message}');
    }
    if (!_errorController.isClosed) {
      _errorController.add(err);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _captureTimer?.cancel();
    _errorController.close();
    // Don't await — dispose is sync. Best-effort cleanup.
    unawaited(_teardownFrames());
    super.dispose();
  }
}

/// State machine for [FaceEnrolmentService]. UI ([FaceEnrolmentScreen])
/// switches its rendered widget tree on this enum.
enum FaceEnrolmentState {
  /// Service just constructed; camera initialising. UI shows a brief
  /// "Preparing camera" spinner. Auto-trigger [startSweep] once the
  /// camera reports ready.
  idle,

  /// Yaw sweep in progress — instruction "Slowly turn your head from
  /// left to right". Frames captured at ~4Hz.
  sweepingYaw,

  /// Pitch sweep in progress — instruction "Now look up, then down".
  /// Frames captured at ~4Hz.
  sweepingPitch,

  /// Sweep complete; running native MobileFaceNet pass on the
  /// captured buffer. UI shows the ring at 100% + "Almost there"
  /// label.
  embedding,

  /// Native returned a slot bundle; UI shows the confirm view with
  /// the picked thumbnails + Done button.
  confirming,

  /// User tapped Done; local + cloud writes in flight.
  persisting,

  /// Terminal — enrolment succeeded. UI pops back to client detail.
  done,

  /// Terminal — user cancelled. UI pops back without changes.
  cancelled,

  /// Terminal — something went wrong; [FaceEnrolmentService.error]
  /// carries the type + message. UI shows the inline toast for 4s
  /// then pops.
  failed,
}

/// One picked slot from the native enrolment pass. Bound to the
/// confirm view's horizontal thumbnail row.
@immutable
class FaceEnrolmentSlot {
  /// 0-based slot ordinal.
  final int slotIndex;

  /// 2048-byte MobileFaceNet embedding (512 FP32 LE floats).
  final Uint8List embedding;

  /// True for exactly one slot — the most-frontal frame. Used as the
  /// avatar JPG source.
  final bool isFrontalPick;

  /// Estimated yaw angle (radians) of the picked frame. Optional —
  /// older native builds may return 0.0. Stored for analytics only.
  final double? poseYaw;

  /// Estimated pitch angle (radians) of the picked frame.
  final double? posePitch;

  const FaceEnrolmentSlot({
    required this.slotIndex,
    required this.embedding,
    required this.isFrontalPick,
    this.poseYaw,
    this.posePitch,
  });
}

/// Error envelope for inline toast surfacing.
@immutable
class FaceEnrolmentError {
  final FaceEnrolmentErrorType type;
  final String message;

  const FaceEnrolmentError({
    required this.type,
    required this.message,
  });
}

/// Discriminates between "user-facing nudge" errors (notEnoughAngles —
/// asks the user to retry) and "infrastructure" errors (camera, io —
/// surfaces a generic apology).
enum FaceEnrolmentErrorType {
  /// Native returned fewer than the hard minimum slots. UI shows the
  /// retry-with-clearer-pose nudge.
  notEnoughAngles,

  /// Native MobileFaceNet pass failed (model load, timeout, platform
  /// exception). UI shows the message + auto-pops.
  embeddingFailed,

  /// Camera plugin failed to initialise OR the screen forgot to wire
  /// the frame producer.
  camera,

  /// SQLite write or temp dir create failed. Rare; surface verbatim
  /// so we can diagnose from Carl's screenshot.
  io,
}
