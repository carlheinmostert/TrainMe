import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/client.dart';
import '../services/api_client.dart';
import '../services/face_embedding_service.dart';
import '../services/face_enrolment_service.dart';
import '../services/sync_service.dart';
import '../theme.dart';
import '../widgets/orientation_lock_guard.dart';

/// Safe Mode v2 multi-reference face enrolment screen (2026-05-24, Wave-D).
///
/// Front-camera Face-ID-style rotating-head sweep. The screen owns:
///   - The camera plugin lifecycle (init / dispose / app-resume / app-pause).
///   - The frame-producer hook that [FaceEnrolmentService] drains during
///     the sweep — captures a still via `controller.takePicture()` every
///     ~250ms and hands the file path to the service.
///   - The visual UI: viewfinder + coral circle outline + arc progress
///     ring + tick marks + instruction text + cancel chip + confirm
///     thumbnails + done button.
///
/// The service owns:
///   - The state machine + timing.
///   - The native MobileFaceNet pass.
///   - The persist step (local SQLite + cloud RPC + avatar copy).
///
/// Spec: docs/specs/2026-05-24-safe-mode-v2-multi-reference-enrolment.md
/// Polish Phase 1: docs/specs/2026-05-25-safe-mode-v2-enrolment-polish.md
///
/// Entry points (Wave-D):
///   - Empty avatar slot tap on client detail → push this screen directly.
///   - Existing avatar tap → bottom sheet → "Replace avatar and re-enrol"
///     → push this screen.
///
/// POPIA: the parent screen MUST gate on the consent matrix from spec
/// section 3 BEFORE pushing this screen. [FaceEnrolmentMode.disabled]
/// is a programming error here — callers route to the consent sheet
/// SnackBar instead of pushing.
///
/// Phase 1 polish (2026-05-25):
///   - Camera flip toggle (rear vs selfie). Default rear (practitioner
///     enrolling client across desk); selfie when self-enrolling.
///     Sticky per-device via SharedPreferences.
///   - Consent-aware mode resolution. Branches between full /
///     embeddingOnly / avatarOnly. Disabled is the caller's
///     responsibility.
///   - avatarOnly mode: single-shot capture (no sweep, no embedding).
class FaceEnrolmentScreen extends StatefulWidget {
  final PracticeClient client;

  /// Resolved consent mode. The caller (avatar-tap intercept on
  /// client detail OR the capture screen's "Set face" CTA) computes
  /// this from the cached client snapshot and refuses to push when
  /// the resolution is [FaceEnrolmentMode.disabled].
  final FaceEnrolmentMode mode;

  const FaceEnrolmentScreen({
    super.key,
    required this.client,
    required this.mode,
  });

  @override
  State<FaceEnrolmentScreen> createState() => _FaceEnrolmentScreenState();

  /// Convenience push. Returns `true` if enrolment succeeded, `false`
  /// on cancel / failure. Callers use the result to optionally pop a
  /// confirm chip; both outcomes are non-destructive.
  ///
  /// Resolves the [FaceEnrolmentMode] from the supplied client's
  /// consent flags. Callers that have already gated on the consent
  /// matrix (the production entry points) get the correct mode for
  /// free; callers that haven't gated and pass a fully-revoked client
  /// will see this method return false immediately without rendering
  /// anything — they should have shown the SnackBar instead. Phase 1
  /// guidance: ALWAYS gate before pushing.
  static Future<bool> push(
    BuildContext context, {
    required PracticeClient client,
  }) async {
    final mode = resolveFaceEnrolmentMode(
      faceRecognitionAllowed: client.safeModeFaceRecognitionAllowed,
      avatarAllowed: client.avatarAllowed,
    );
    if (mode == FaceEnrolmentMode.disabled) {
      // Defensive — production callers gate above this; bail rather
      // than render an unusable editor.
      return false;
    }
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        fullscreenDialog: true,
        builder: (_) => FaceEnrolmentScreen(client: client, mode: mode),
      ),
    );
    return ok ?? false;
  }
}

/// SharedPreferences key for the sticky camera-direction choice.
/// String value: "rear" or "front". Default rear when absent.
const String _kCameraDirectionPrefKey = 'face_enrolment_camera_direction';

class _FaceEnrolmentScreenState extends State<FaceEnrolmentScreen>
    with WidgetsBindingObserver {
  /// Active camera controller — front or rear depending on
  /// [_useFrontCamera]. Re-built across app-lifecycle resume AND
  /// across camera-flip taps.
  CameraController? _cameraController;


  /// True once the camera is initialised + previewing. Drives the
  /// loading spinner overlay.
  bool _cameraReady = false;

  /// True if the camera failed to start. Surfaces an inline error
  /// state instead of the viewfinder.
  bool _cameraFailed = false;
  String? _cameraErrorMessage;

  /// Lifecycle controller for the service. Reused across retries.
  /// Constructed from [widget.mode] so the service knows whether to
  /// run sweep + embedding vs the simple-shot avatarOnly path.
  ///
  /// Re-assignable (not `final`) because Phase 2's Retake path on the
  /// post-sweep grid disposes the current service + constructs a
  /// fresh one to restart the pose-gated sweep from a clean state
  /// machine.
  late FaceEnrolmentService _service;

  StreamSubscription<FaceEnrolmentError>? _errorSub;
  StreamSubscription<FaceEnrolmentRejection>? _rejectionSub;

  /// Inline coral-bordered toast text. Surfaced at the top of the
  /// viewfinder for 4s before auto-popping (per spec). Null = no
  /// toast.
  String? _toast;
  Timer? _toastTimer;

  /// M30 — rejection events are retired in favour of per-prompt stall
  /// hints. The timer field stays as a defensive cancel target should
  /// the listener ever be re-enabled. Kept as `Timer?` so the dispose
  /// path keeps compiling.
  Timer? _rejectionTimer;

  /// Phase 2 — practitioner's manually-chosen avatar slot index in the
  /// post-sweep grid. Null = use the auto frontal-pick. Bound to the
  /// coral-bordered selected cell in the grid view.
  int? _chosenAvatarSlotIndex;

  /// Wall-clock instant the latest take-picture call was kicked off,
  /// used to drop overlapping calls if the prior is still finishing
  /// (camera plugin doesn't queue takePicture).
  bool _takePictureInFlight = false;

  /// Temp dir for the frame producer's outputs. Cleared on every
  /// `_resetForRetry` and when the screen pops.
  Directory? _producerTempDir;

  /// True when the front-facing (selfie) camera is active. Persisted
  /// per-device via SharedPreferences under [_kCameraDirectionPrefKey].
  /// Default = false (rear) for practitioner-enrolling-client which
  /// is the 99% real-world case. Flipped to true when (a) the user
  /// taps the flip toggle, OR (b) the heuristic in [_resolveDefaultDirection]
  /// detects self-enrolment on first open (rare, Carl-sentinel-claim).
  bool _useFrontCamera = false;

  /// True while the camera flip toggle is busy tearing down + re-
  /// initialising. Suppresses repeated taps that would race the
  /// camera plugin's lifecycle.
  bool _cameraFlipping = false;

  /// True while a single-shot capture (avatarOnly mode) is in flight.
  /// Locks the shutter to prevent double-fire.
  bool _simpleShotInFlight = false;

  /// True when the avatarOnly mode has just completed and is in its
  /// "saving" overlay state, blocking interaction until the screen
  /// pops with success.
  bool _simpleShotPersisting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _service = FaceEnrolmentService(mode: widget.mode);
    _service.addListener(_onServiceChanged);
    _errorSub = _service.errorStream.listen(_onServiceError);
    _rejectionSub = _service.rejectionStream.listen(_onServiceRejection);
    // Load the sticky camera direction, then init the camera.
    unawaited(_resolveDefaultDirection().then((_) {
      if (!mounted) return;
      _initCamera();
    }));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _toastTimer?.cancel();
    _rejectionTimer?.cancel();
    _errorSub?.cancel();
    _rejectionSub?.cancel();
    _service.removeListener(_onServiceChanged);
    _service.dispose();
    final c = _cameraController;
    _cameraController = null;
    if (c != null) {
      // Fire-and-forget; the camera plugin's dispose is idempotent.
      unawaited(c.dispose());
    }
    final dir = _producerTempDir;
    _producerTempDir = null;
    if (dir != null) {
      // Best-effort cleanup; we don't await.
      try {
        if (dir.existsSync()) {
          dir.deleteSync(recursive: true);
        }
      } catch (_) {}
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      // Drop the camera to release HW so iOS doesn't kill us. We do NOT
      // try to resume mid-sweep — the timing would be broken anyway —
      // so we treat backgrounding mid-flow as a cancel.
      if (_service.state == FaceEnrolmentState.sweepingYaw ||
          _service.state == FaceEnrolmentState.sweepingPitch ||
          _service.state == FaceEnrolmentState.embedding) {
        _service.cancel();
      }
      final c = _cameraController;
      _cameraController = null;
      if (c != null) {
        unawaited(c.dispose());
      }
      if (mounted) {
        setState(() {
          _cameraReady = false;
        });
      }
    } else if (state == AppLifecycleState.resumed) {
      if (!_cameraReady && !_cameraFailed) {
        _initCamera();
      }
    }
  }

  // ── Camera direction resolution ─────────────────────────────────────────

  /// Pick the default camera direction the first time the screen
  /// opens AFTER any prior session. Reads the sticky pref if present;
  /// otherwise falls back to a heuristic:
  ///
  ///   - Self-enrolment (Carl-sentinel-claim case) → selfie. Detected
  ///     by comparing the client name to the local part of the
  ///     practitioner's email (case-insensitive trimmed). This is a
  ///     soft heuristic — the user can always flip via the toggle.
  ///   - Anyone else (the 99% case: practitioner enrolling client
  ///     across a desk) → rear.
  Future<void> _resolveDefaultDirection() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(_kCameraDirectionPrefKey);
      if (stored == 'front') {
        _useFrontCamera = true;
        return;
      }
      if (stored == 'rear') {
        _useFrontCamera = false;
        return;
      }
      // No sticky pref yet — pick by heuristic.
      _useFrontCamera = _detectSelfEnrolment();
    } catch (_) {
      // SharedPreferences unavailable — fall through to heuristic.
      _useFrontCamera = _detectSelfEnrolment();
    }
  }

  /// True when the client being enrolled appears to be the
  /// practitioner themselves. Heuristic: client name matches the
  /// email-local-part (case-insensitive, both trimmed). False when
  /// either name is empty or no email is available.
  bool _detectSelfEnrolment() {
    final email = ApiClient.instance.currentUserEmail;
    if (email == null || email.isEmpty) return false;
    final at = email.indexOf('@');
    if (at <= 0) return false;
    final localPart = email.substring(0, at).trim().toLowerCase();
    final clientName = widget.client.name.trim().toLowerCase();
    if (localPart.isEmpty || clientName.isEmpty) return false;
    return localPart == clientName;
  }

  /// Persist the chosen direction so the next open uses it.
  Future<void> _persistCameraDirection() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kCameraDirectionPrefKey,
        _useFrontCamera ? 'front' : 'rear',
      );
    } catch (_) {
      // Best-effort; the toggle still works in-session if the pref
      // write fails.
    }
  }

  Future<void> _onCameraFlipTap() async {
    if (_cameraFlipping) return;
    // Block flip during active sweep / embedding / persisting — the
    // resulting frames would mix selfie + rear orientations which
    // would corrupt the pose-uniqueness pick on the native side.
    if (_service.state == FaceEnrolmentState.sweepingYaw ||
        _service.state == FaceEnrolmentState.sweepingPitch ||
        _service.state == FaceEnrolmentState.embedding ||
        _service.state == FaceEnrolmentState.persisting) {
      return;
    }
    HapticFeedback.selectionClick();
    setState(() {
      _cameraFlipping = true;
      _useFrontCamera = !_useFrontCamera;
      _cameraReady = false;
    });
    unawaited(_persistCameraDirection());
    // Tear down the current controller, then init the new one. The
    // service's frame producer hook stays bound (it dereferences the
    // current controller on every tick).
    final old = _cameraController;
    _cameraController = null;
    if (old != null) {
      try {
        await old.dispose();
      } catch (_) {}
    }
    await _initCamera(skipAutoStart: true);
    if (!mounted) return;
    setState(() {
      _cameraFlipping = false;
    });
  }

  // ── Camera lifecycle ────────────────────────────────────────────────────

  /// Initialise the camera in the direction dictated by
  /// [_useFrontCamera]. When [skipAutoStart] is true, the
  /// post-initialisation `_service.startSweep()` kick-off is
  /// suppressed — used by the flip path which never wants to
  /// auto-restart a fresh sweep mid-flow.
  Future<void> _initCamera({bool skipAutoStart = false}) async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (!mounted) return;
        setState(() {
          _cameraFailed = true;
          _cameraErrorMessage = "No camera available on this device.";
        });
        return;
      }
      final preferred = _useFrontCamera
          ? CameraLensDirection.front
          : CameraLensDirection.back;
      final picked = cameras.firstWhere(
        (c) => c.lensDirection == preferred,
        // Graceful degrade if the device lacks the preferred direction
        // (e.g. iPad with only one camera in the simulator).
        orElse: () => cameras.first,
      );

      final controller = CameraController(
        picked,
        ResolutionPreset.medium,
        enableAudio: false, // No mic — keeps haptics live + cuts permission noise.
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      _cameraController = controller;

      // Wire the producer hook AFTER the camera is ready. The producer
      // runs in the service's periodic-timer tick; we keep the take-
      // picture call gated by `_takePictureInFlight` so a slow frame
      // doesn't cascade into a backlog.
      _service.setFrameProducer(_captureFrame);

      setState(() {
        _cameraReady = true;
        _cameraFailed = false;
        _cameraErrorMessage = null;
      });

      // avatarOnly mode never auto-starts a sweep — the user controls
      // capture via the shutter button. full / embeddingOnly auto-
      // start the sweep once the preview has a half-beat to settle.
      if (skipAutoStart) return;
      if (widget.mode == FaceEnrolmentMode.avatarOnly) return;

      // Tiny delay so the preview has a frame on screen before the
      // ring starts spinning — gives the user a half-beat to read the
      // first instruction. Per Carl's mockup signoff, the sweep auto-
      // begins as soon as Vision sees a face (no Start button) — the
      // service's pose-gated tick handles the "no face yet" case
      // silently by skipping frames that don't return embeddings.
      await Future<void>.delayed(const Duration(milliseconds: 350));
      if (!mounted) return;
      if (_service.state == FaceEnrolmentState.idle) {
        unawaited(_service.startPoseGatedSweep());
      }
    } on CameraException catch (e) {
      if (!mounted) return;
      setState(() {
        _cameraFailed = true;
        _cameraErrorMessage = e.description ??
            "Camera failed to start (${e.code}). Check permissions.";
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _cameraFailed = true;
        _cameraErrorMessage = "Camera failed to start: $e";
      });
    }
  }

  /// Frame producer hook bound into [FaceEnrolmentService] via
  /// [FaceEnrolmentService.setFrameProducer]. Captures a single still
  /// and returns its path; returns null on failure (next tick retries).
  ///
  /// Drops overlapping calls — if the previous take-picture hasn't
  /// finished when the next tick fires, we skip. Avoids the camera
  /// plugin's "image_capture_already_in_progress" exception that
  /// otherwise cascades.
  Future<String?> _captureFrame() async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return null;
    if (_takePictureInFlight) return null;
    _takePictureInFlight = true;
    try {
      _producerTempDir ??= await () async {
        final tmp = await getTemporaryDirectory();
        final dir = Directory(p.join(
          tmp.path,
          'face_enrol_producer_${DateTime.now().millisecondsSinceEpoch}',
        ));
        await dir.create(recursive: true);
        return dir;
      }();
      final xFile = await controller.takePicture();
      // Move the file from the camera plugin's default location into
      // our scoped dir so cleanup is straightforward.
      final destPath = p.join(
        _producerTempDir!.path,
        'f_${DateTime.now().microsecondsSinceEpoch}.jpg',
      );
      try {
        await File(xFile.path).rename(destPath);
      } catch (_) {
        await File(xFile.path).copy(destPath);
        try {
          await File(xFile.path).delete();
        } catch (_) {}
      }
      return destPath;
    } catch (_) {
      return null;
    } finally {
      _takePictureInFlight = false;
    }
  }

  // ── avatarOnly simple-shot capture ──────────────────────────────────────

  /// Single-tap shutter for [FaceEnrolmentMode.avatarOnly]. Captures
  /// one frame and persists it as the avatar JPG via SyncService.
  /// No sweep, no embedding generation — face-rec consent is OFF in
  /// this mode so we have no business computing a biometric template.
  ///
  /// Path mirrors the avatar-only branch of
  /// [FaceEnrolmentService.commit]: copy the frame into
  /// `{docs}/avatars/{clientId}.png` + best-effort cloud upload via
  /// `ApiClient.uploadRawArchive` + `SyncService.queueSetAvatar`.
  Future<void> _onSimpleShotTap() async {
    if (_simpleShotInFlight || _simpleShotPersisting) return;
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;
    HapticFeedback.mediumImpact();
    setState(() {
      _simpleShotInFlight = true;
    });
    try {
      final xFile = await controller.takePicture();
      if (!mounted) return;
      setState(() {
        _simpleShotInFlight = false;
        _simpleShotPersisting = true;
      });

      // Persist locally first so the avatar exists even if the cloud
      // upload fails — matches the offline-first contract for the
      // multi-ref path in [FaceEnrolmentService.commit].
      final docsDir = await getApplicationDocumentsDirectory();
      final avatarsDir = Directory(p.join(docsDir.path, 'avatars'));
      if (!avatarsDir.existsSync()) {
        avatarsDir.createSync(recursive: true);
      }
      final clientId = widget.client.id;
      final localAbs = p.join(avatarsDir.path, '$clientId.png');
      try {
        if (File(localAbs).existsSync()) {
          File(localAbs).deleteSync();
        }
      } catch (_) {}
      await File(xFile.path).copy(localAbs);
      // Best-effort temp-file cleanup.
      try {
        await File(xFile.path).delete();
      } catch (_) {}

      // Queue cloud avatar upload via SyncService — same path shape
      // as the multi-ref branch so the raw-archive bucket gets
      // `<practiceId>/<clientId>/avatar.png`.
      try {
        final cached = await SyncService.instance.storage
            .getCachedClientById(clientId);
        if (cached != null) {
          final cloudPath = '${cached.practiceId}/$clientId/avatar.png';
          try {
            await ApiClient.instance.uploadRawArchive(
              path: cloudPath,
              file: File(localAbs),
              contentType: 'image/png',
            );
          } catch (_) {
            // Best-effort — local stands.
          }
          await SyncService.instance.queueSetAvatar(
            clientId: clientId,
            avatarPath: cloudPath,
          );
        }
      } catch (_) {
        // Best-effort.
      }

      // Clear any stale embedding cache for this client — face-rec
      // consent is OFF in avatarOnly so the FaceEmbeddingService
      // shouldn't be holding a template at all.
      try {
        FaceEmbeddingService.instance.resetFor(clientId);
      } catch (_) {}

      if (!mounted) return;
      _popWithResult(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _simpleShotInFlight = false;
        _simpleShotPersisting = false;
      });
      _showInlineToast("Couldn't capture — try again ($e)");
    }
  }

  void _showInlineToast(String message) {
    setState(() {
      _toast = message;
    });
    _toastTimer?.cancel();
    _toastTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      setState(() => _toast = null);
    });
  }

  // ── Service ↔ UI ────────────────────────────────────────────────────────

  void _onServiceChanged() {
    if (!mounted) return;
    final state = _service.state;
    if (state == FaceEnrolmentState.done) {
      // Pop with success; client detail will reload.
      _popWithResult(true);
      return;
    }
    if (state == FaceEnrolmentState.cancelled) {
      _popWithResult(false);
      return;
    }
    // M31 — Failed no longer auto-pops. The new _FailedView renders
    // explicit Try Again + Close CTAs; the user controls the
    // transition.
    setState(() {});
  }

  void _onServiceError(FaceEnrolmentError err) {
    if (!mounted) return;
    // M31 — error doesn't drive an inline coral toast on failure any
    // more; the dedicated _FailedView in build() renders the err
    // message. Keep the toast path live for transient camera errors
    // that don't move state to failed (e.g. camera init issues).
    if (_service.state == FaceEnrolmentState.failed) return;
    setState(() {
      _toast = err.message;
    });
    _toastTimer?.cancel();
    _toastTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      setState(() => _toast = null);
    });
  }

  void _onServiceRejection(FaceEnrolmentRejection rej) {
    // M30 — the rose rejection toast is retired in favour of the
    // per-prompt soft hints surfaced via FaceEnrolmentService.showStallHint.
    // Listener stays bound for API compatibility but the UI no longer
    // renders the score-bearing toast.
    if (!mounted) return;
  }

  void _popWithResult(bool success) {
    if (!mounted) return;
    Navigator.of(context).maybePop<bool>(success);
  }

  /// Close-button handler — works in EVERY state (M31 fix). Cancels
  /// any in-flight service work then pops the route. For the Failed
  /// state we bypass the cancel machinery since the service might
  /// be in a transient state that the cancel guards refuse to flip;
  /// we pop directly.
  void _onCancelTap() {
    HapticFeedback.selectionClick();
    final state = _service.state;
    // For terminal-but-non-popped states (failed) pop directly.
    if (state == FaceEnrolmentState.failed) {
      _popWithResult(false);
      return;
    }
    // For idle / avatarOnly there's no service-driven pop coming —
    // pop ourselves.
    if (widget.mode == FaceEnrolmentMode.avatarOnly ||
        state == FaceEnrolmentState.idle) {
      _service.cancel();
      _popWithResult(false);
      return;
    }
    // Sweeping / embedding / persisting / confirming — cancel and let
    // _onServiceChanged pop when the state transitions to cancelled.
    _service.cancel();
    // Belt + braces: if the service somehow doesn't transition within
    // a beat (e.g. it was already mid-await on a native call), pop
    // anyway. Saves users from the "X button does nothing" trap.
    Future<void>.delayed(const Duration(milliseconds: 800), () {
      if (!mounted) return;
      if (_service.state != FaceEnrolmentState.done &&
          _service.state != FaceEnrolmentState.persisting) {
        _popWithResult(false);
      }
    });
  }

  /// M31 — Try Again handler from the Failed view. Asks the service
  /// to clear its error state and restart the pose-gated sweep.
  Future<void> _onTryAgainTap() async {
    HapticFeedback.mediumImpact();
    await _service.restartFromFailed();
  }

  /// M30 — Skip-this-pose handler. Bound to the bottom-of-screen
  /// "Skip this pose" CTA which surfaces after 15s on the same prompt.
  void _onSkipPromptTap() {
    HapticFeedback.selectionClick();
    _service.requestSkipCurrentPrompt();
  }

  Future<void> _onCommitTap() async {
    if (_service.state != FaceEnrolmentState.confirming) return;
    HapticFeedback.mediumImpact();
    await _service.commit(
      clientId: widget.client.id,
      manuallyChosenAvatarSlotIndex: _chosenAvatarSlotIndex,
    );
  }

  /// Retake — discard the accumulated slots and restart the pose-gated
  /// sweep cleanly. No "Are you sure?" modal (R-01). The current
  /// service instance is torn down and replaced with a fresh one so
  /// the state machine starts back at idle.
  Future<void> _onRetakeTap() async {
    HapticFeedback.selectionClick();
    if (!mounted) return;
    setState(() {
      _chosenAvatarSlotIndex = null;
    });
    _service.removeListener(_onServiceChanged);
    _errorSub?.cancel();
    _rejectionSub?.cancel();
    _service.dispose();
    _service = FaceEnrolmentService(mode: widget.mode);
    _service.setFrameProducer(_captureFrame);
    _service.addListener(_onServiceChanged);
    _errorSub = _service.errorStream.listen(_onServiceError);
    _rejectionSub = _service.rejectionStream.listen(_onServiceRejection);
    if (mounted) {
      setState(() {});
    }
    unawaited(_service.startPoseGatedSweep());
  }

  // ── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return OrientationLockGuard(
      allowed: const {DeviceOrientation.portraitUp},
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: _cameraFailed
              ? _buildCameraError()
              : _buildBody(),
        ),
      ),
    );
  }

  Widget _buildCameraError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.videocam_off_outlined,
                color: Colors.white70, size: 48),
            const SizedBox(height: 12),
            const Text(
              'Camera unavailable',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _cameraErrorMessage ??
                  "Check Settings → Privacy → Camera and try again.",
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 13,
                color: Colors.white70,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => _popWithResult(false),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
              ),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (widget.mode == FaceEnrolmentMode.avatarOnly) {
      return _SimpleShotView(
        cameraController: _cameraController,
        cameraReady: _cameraReady,
        clientName: widget.client.name,
        useFrontCamera: _useFrontCamera,
        shotInFlight: _simpleShotInFlight,
        persisting: _simpleShotPersisting,
        onCancel: _onCancelTap,
        onShutter: _onSimpleShotTap,
        onCameraFlip: _onCameraFlipTap,
        toast: _toast,
      );
    }

    final state = _service.state;
    // M31 — render Failed state EXPLICITLY with Try Again + Close
    // CTAs. Previously this fell through to the sweep view which
    // showed the initial prompt overlaid on the error toast.
    if (state == FaceEnrolmentState.failed) {
      return _FailedView(
        message: _service.error?.message ??
            "Couldn't capture enough variety. Try again with better lighting.",
        capturedCount: _service.pendingSlots?.length ?? 0,
        onTryAgain: _onTryAgainTap,
        onClose: _onCancelTap,
      );
    }
    if (state == FaceEnrolmentState.confirming) {
      // embeddingOnly skips the grid entirely — commit immediately.
      // Schedule for after the build so we don't notify mid-build.
      if (widget.mode == FaceEnrolmentMode.embeddingOnly) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (_service.state == FaceEnrolmentState.confirming) {
            unawaited(_onCommitTap());
          }
        });
        return _PersistingOverlayView(
          cameraController: _cameraController,
          cameraReady: _cameraReady,
          useFrontCamera: _useFrontCamera,
          onCancel: _onCancelTap,
          onCameraFlip: _onCameraFlipTap,
        );
      }
      return _AvatarSelectionGridView(
        slots: _service.pendingSlots ?? const [],
        chosenSlotIndex: _chosenAvatarSlotIndex,
        onSelect: (i) => setState(() => _chosenAvatarSlotIndex = i),
        onCancel: _onCancelTap,
        onRetake: _onRetakeTap,
        onConfirm: _onCommitTap,
      );
    }
    // Persisting overlay (with viewfinder behind for continuity).
    if (state == FaceEnrolmentState.persisting) {
      return _PersistingOverlayView(
        cameraController: _cameraController,
        cameraReady: _cameraReady,
        useFrontCamera: _useFrontCamera,
        onCancel: () {},
        onCameraFlip: () {},
      );
    }
    // Default: prompt-driven sweep (idle / sweepingYaw / sweepingPitch /
    // embedding render the same prompt-walk UI; service drives which
    // prompt + stall flags are surfaced).
    return _PoseGatedSweepView(
      cameraController: _cameraController,
      cameraReady: _cameraReady,
      filledBuckets: _service.filledBuckets,
      currentTargetBucket: _service.currentTargetBucket,
      currentPromptIndex: _service.currentPromptIndex,
      showStallHint: _service.showStallHint,
      showSkipPrompt: _service.showSkipPrompt,
      hintText: _service.instructionText ?? 'Look at the camera to begin',
      useFrontCamera: _useFrontCamera,
      onCancel: _onCancelTap,
      onCameraFlip: _onCameraFlipTap,
      onSkipPrompt: _onSkipPromptTap,
      toast: _toast,
    );
  }
}

/// The single-shot capture view for [FaceEnrolmentMode.avatarOnly].
/// Viewfinder + big coral shutter button at the bottom; no sweep ring,
/// no instruction copy, no embedding pass. Tapping the shutter
/// captures one frame and persists it as the avatar JPG (Phase 1
/// spec 4f, avatarOnly row of section 3 matrix).
///
/// This branch resurrects the legacy single-photo avatar capture flow
/// as a mode of the new editor — the Wave-D PR retired the standalone
/// `pushClientAvatarCapture` entry point.
class _SimpleShotView extends StatelessWidget {
  final CameraController? cameraController;
  final bool cameraReady;
  final String clientName;
  final bool useFrontCamera;
  final bool shotInFlight;
  final bool persisting;
  final VoidCallback onCancel;
  final VoidCallback onShutter;
  final VoidCallback onCameraFlip;
  final String? toast;

  const _SimpleShotView({
    required this.cameraController,
    required this.cameraReady,
    required this.clientName,
    required this.useFrontCamera,
    required this.shotInFlight,
    required this.persisting,
    required this.onCancel,
    required this.onShutter,
    required this.onCameraFlip,
    required this.toast,
  });

  @override
  Widget build(BuildContext context) {
    final shutterEnabled = cameraReady && !shotInFlight && !persisting;
    return Stack(
      fit: StackFit.expand,
      children: [
        // 1. Camera preview (or loading spinner).
        if (cameraReady && cameraController != null)
          SizedBox.expand(
            child: FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: cameraController!.value.previewSize?.height ??
                    MediaQuery.of(context).size.width,
                height: cameraController!.value.previewSize?.width ??
                    MediaQuery.of(context).size.height,
                child: CameraPreview(cameraController!),
              ),
            ),
          )
        else
          const Center(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: AppColors.primary),
                  SizedBox(height: 16),
                  Text(
                    'Preparing camera',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 14,
                      color: Colors.white70,
                    ),
                  ),
                ],
              ),
            ),
          ),

        // 2. Cancel chip top-left.
        Positioned(
          top: 12,
          left: 12,
          child: _CancelChip(onTap: onCancel),
        ),

        // 3. Camera flip toggle top-right.
        Positioned(
          top: 12,
          right: 12,
          child: _CameraFlipChip(
            useFrontCamera: useFrontCamera,
            onTap: onCameraFlip,
          ),
        ),

        // 4. Title strip — explains what the single tap will do.
        if (cameraReady)
          Positioned(
            top: 72,
            left: 24,
            right: 24,
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              ),
              child: Text(
                clientName.isEmpty
                    ? 'Tap the shutter to capture an avatar'
                    : "Tap the shutter to capture $clientName's avatar",
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                  height: 1.35,
                ),
              ),
            ),
          ),

        // 5. Big coral shutter button at the bottom.
        if (cameraReady)
          Positioned(
            left: 0,
            right: 0,
            bottom: 40,
            child: Center(
              child: _ShutterButton(
                enabled: shutterEnabled,
                inFlight: shotInFlight,
                onTap: onShutter,
              ),
            ),
          ),

        // 6. Persisting overlay — full-screen dim + spinner.
        if (persisting)
          Positioned.fill(
            child: Container(
              color: Colors.black.withValues(alpha: 0.55),
              alignment: Alignment.center,
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: AppColors.primary),
                  SizedBox(height: 16),
                  Text(
                    'Saving',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 14,
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),

        // 7. Toast (capture failed).
        if (toast != null)
          Positioned(
            top: 132,
            left: 16,
            right: 16,
            child: _ErrorToast(message: toast!),
          ),
      ],
    );
  }
}

class _SlotPlaceholder extends StatelessWidget {
  const _SlotPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: AppColors.surfaceBase,
      child: Center(
        child: Icon(
          Icons.face_outlined,
          color: AppColors.textSecondaryOnDark,
          size: 28,
        ),
      ),
    );
  }
}

class _CancelChip extends StatelessWidget {
  final VoidCallback onTap;

  const _CancelChip({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surfaceRaised,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: const SizedBox(
          width: 40,
          height: 40,
          child: Icon(
            Icons.close,
            color: Colors.white,
            size: 22,
          ),
        ),
      ),
    );
  }
}

/// Camera flip toggle — top-right of viewfinder. Coral border on
/// selfie mode (visual cue that the practitioner-facing direction is
/// active), neutral surface on rear. Tap = flip; sticky pref persists.
///
/// Phase 1 spec 4a. The icon changes orientation to mirror the active
/// direction (`cameraswitch_outlined` rotates 180° between modes).
class _CameraFlipChip extends StatelessWidget {
  final bool useFrontCamera;
  final VoidCallback onTap;

  const _CameraFlipChip({
    required this.useFrontCamera,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surfaceRaised,
      shape: CircleBorder(
        side: BorderSide(
          color: useFrontCamera
              ? AppColors.primary.withValues(alpha: 0.85)
              : Colors.transparent,
          width: 1.5,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: const SizedBox(
          width: 40,
          height: 40,
          child: Icon(
            Icons.cameraswitch_outlined,
            color: Colors.white,
            size: 22,
          ),
        ),
      ),
    );
  }
}

/// Big coral shutter for the avatarOnly simple-shot view. Disabled
/// state shows a dim coral with no inner ring; active state shows a
/// crisp coral with the inner white ring; in-flight state collapses
/// the inner ring to a small spinner.
class _ShutterButton extends StatelessWidget {
  final bool enabled;
  final bool inFlight;
  final VoidCallback onTap;

  const _ShutterButton({
    required this.enabled,
    required this.inFlight,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colour = enabled
        ? AppColors.primary
        : AppColors.primary.withValues(alpha: 0.40);
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
        width: 84,
        height: 84,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: colour, width: 4),
        ),
        child: Center(
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: colour,
            ),
            child: inFlight
                ? const Padding(
                    padding: EdgeInsets.all(18),
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      valueColor:
                          AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  )
                : null,
          ),
        ),
      ),
    );
  }
}
class _ErrorToast extends StatelessWidget {
  final String message;

  const _ErrorToast({required this.message});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.surfaceBase,
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          border: Border.all(color: AppColors.primary, width: 1.5),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.error_outline,
              color: AppColors.primary,
              size: 18,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: Colors.white,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Phase 2 widgets ────────────────────────────────────────────────────────

/// Phase 2 — the pose-gated sweep view that replaces the legacy
/// [_SweepView] for [FaceEnrolmentMode.full] and
/// [FaceEnrolmentMode.embeddingOnly]. Renders the mockup-faithful
/// 6-segment guidance ring + dashed face guide + slot counter +
/// quality badge + hint text + reject toast.
///
/// Mockup signoff: docs/design/mockups/safe-mode-v2-enrolment-polish.html
/// states 1 + 2. All five of Carl's approved decisions honoured:
///   - 6 pose buckets (not 8).
///   - Reject toast shows the raw score.
///   - Dashed face guide (not the prior solid breathing circle).
///   - No "Start" button — sweep auto-begins on face detection.
///   - Pose labels stay word-form on the grid (handled in
///     [_AvatarSelectionGridView]).
class _PoseGatedSweepView extends StatelessWidget {
  final CameraController? cameraController;
  final bool cameraReady;
  final Set<PoseBucket> filledBuckets;
  final PoseBucket? currentTargetBucket;
  /// M30 — current prompt index (0..5) into [kPromptSequence]. -1
  /// before the sweep has started; >=6 after the last prompt.
  final int currentPromptIndex;
  final bool showStallHint;
  final bool showSkipPrompt;
  final String hintText;
  final bool useFrontCamera;
  final VoidCallback onCancel;
  final VoidCallback onCameraFlip;
  final VoidCallback onSkipPrompt;
  final String? toast;

  const _PoseGatedSweepView({
    required this.cameraController,
    required this.cameraReady,
    required this.filledBuckets,
    required this.currentTargetBucket,
    required this.currentPromptIndex,
    required this.showStallHint,
    required this.showSkipPrompt,
    required this.hintText,
    required this.useFrontCamera,
    required this.onCancel,
    required this.onCameraFlip,
    required this.onSkipPrompt,
    required this.toast,
  });

  @override
  Widget build(BuildContext context) {
    final int promptStep =
        currentPromptIndex < 0 ? 0 : currentPromptIndex.clamp(0, kPromptSequence.length);
    final int totalPrompts = kPromptSequence.length;
    final bool hasActivePrompt =
        currentPromptIndex >= 0 && currentPromptIndex < totalPrompts;
    final String direction = hasActivePrompt
        ? kPromptDirections[currentPromptIndex]
        : 'straight';
    final String stallHint = hasActivePrompt && showStallHint
        ? kPromptStallHints[currentPromptIndex]
        : '';

    return Stack(
      fit: StackFit.expand,
      children: [
        // 1. Camera preview — full-resolution, no dim. The guidance
        //    overlay sits over the top.
        if (cameraReady && cameraController != null)
          SizedBox.expand(
            child: FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: cameraController!.value.previewSize?.height ??
                    MediaQuery.of(context).size.width,
                height: cameraController!.value.previewSize?.width ??
                    MediaQuery.of(context).size.height,
                child: CameraPreview(cameraController!),
              ),
            ),
          )
        else
          const Center(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: AppColors.primary),
                  SizedBox(height: 16),
                  Text(
                    'Preparing camera',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 14,
                      color: Colors.white70,
                    ),
                  ),
                ],
              ),
            ),
          ),

        // 2. Soft radial vignette to give the central area focus.
        if (cameraReady)
          IgnorePointer(
            child: Container(
              decoration: const BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment.center,
                  radius: 1.1,
                  colors: [
                    Color(0x00000000),
                    Color(0x66000000),
                  ],
                  stops: [0.55, 1.0],
                ),
              ),
            ),
          ),

        // 3. The 6-segment guidance ring + dashed face guide. One
        //    painter so the geometry stays pixel-aligned across
        //    rebuilds.
        if (cameraReady)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _GuidanceRingPainter(
                  filledBuckets: filledBuckets,
                  targetBucket: currentTargetBucket,
                ),
              ),
            ),
          ),

        // 4. Cancel chip top-left.
        Positioned(
          top: 12,
          left: 12,
          child: _CancelChip(onTap: onCancel),
        ),

        // 5. Step counter pill top-centre. "Step N of 6".
        Positioned(
          top: 18,
          right: 64,
          child: _StepCounterPill(
            step: promptStep + (hasActivePrompt ? 1 : 0),
            total: totalPrompts,
          ),
        ),

        // 6. Camera flip toggle top-right corner.
        Positioned(
          top: 12,
          right: 12,
          child: _CameraFlipChip(
            useFrontCamera: useFrontCamera,
            onTap: onCameraFlip,
          ),
        ),

        // 7. Direction arrow above the ring centre, animated by prompt.
        if (cameraReady && hasActivePrompt)
          Positioned(
            left: 0,
            right: 0,
            top: MediaQuery.of(context).size.height * 0.10,
            child: Center(
              child: _PromptDirectionArrow(direction: direction),
            ),
          ),

        // 8. Prompt copy + stall hint + progress dots stack below the
        //    ring. Single block so spacing stays consistent across
        //    prompts.
        if (cameraReady)
          Positioned(
            left: 24,
            right: 24,
            bottom: MediaQuery.of(context).size.height * 0.22,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  hintText,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: 'Montserrat',
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    height: 1.3,
                    shadows: [
                      Shadow(blurRadius: 8, color: Color(0xB3000000)),
                    ],
                  ),
                ),
                if (stallHint.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      stallHint,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: AppColors.warning,
                        height: 1.35,
                        shadows: [
                          Shadow(blurRadius: 8, color: Color(0xB3000000)),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                _PromptProgressDots(
                  total: totalPrompts,
                  current: currentPromptIndex,
                ),
              ],
            ),
          ),

        // 9. Skip-this-pose CTA — only after 15s on the same prompt.
        if (cameraReady && showSkipPrompt && hasActivePrompt)
          Positioned(
            left: 0,
            right: 0,
            bottom: 36,
            child: Center(
              child: _SkipPromptChip(onTap: onSkipPrompt),
            ),
          ),

        // 10. Generic error toast top (transient camera errors only).
        if (toast != null)
          Positioned(
            top: 110,
            left: 16,
            right: 16,
            child: _ErrorToast(message: toast!),
          ),
      ],
    );
  }
}

/// M30 — replaces the legacy _SlotCounterPill. Reads "Step 3 of 6".
class _StepCounterPill extends StatelessWidget {
  final int step;
  final int total;

  const _StepCounterPill({required this.step, required this.total});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.surfaceBorder, width: 1),
      ),
      child: Text(
        'Step ${step.clamp(1, total)} of $total',
        style: const TextStyle(
          fontFamily: 'Inter',
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: Colors.white,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

/// M30 — direction arrow that hints which way to move. Six values:
/// straight / right / left / up / down / smile.
class _PromptDirectionArrow extends StatelessWidget {
  final String direction;

  const _PromptDirectionArrow({required this.direction});

  @override
  Widget build(BuildContext context) {
    final IconData icon;
    switch (direction) {
      case 'right':
        icon = Icons.arrow_forward_rounded;
        break;
      case 'left':
        icon = Icons.arrow_back_rounded;
        break;
      case 'up':
        icon = Icons.arrow_upward_rounded;
        break;
      case 'down':
        icon = Icons.arrow_downward_rounded;
        break;
      case 'smile':
        icon = Icons.sentiment_satisfied_rounded;
        break;
      case 'straight':
      default:
        icon = Icons.center_focus_strong_rounded;
        break;
    }
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        shape: BoxShape.circle,
        border: Border.all(
          color: AppColors.primary.withValues(alpha: 0.7),
          width: 2,
        ),
      ),
      alignment: Alignment.center,
      child: Icon(icon, color: AppColors.primary, size: 32),
    );
  }
}

/// M30 — six small dots beneath the prompt copy. Filled = completed,
/// outlined coral = current, faded = upcoming.
class _PromptProgressDots extends StatelessWidget {
  final int total;
  final int current;

  const _PromptProgressDots({required this.total, required this.current});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List<Widget>.generate(total, (i) {
        Color colour;
        double size;
        bool filled;
        if (i < current) {
          colour = AppColors.primary;
          size = 10;
          filled = true;
        } else if (i == current) {
          colour = AppColors.primary;
          size = 12;
          filled = false;
        } else {
          colour = Colors.white.withValues(alpha: 0.35);
          size = 8;
          filled = false;
        }
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: filled ? colour : Colors.transparent,
              border: Border.all(color: colour, width: 1.8),
            ),
          ),
        );
      }),
    );
  }
}

/// M30 — Skip-this-pose CTA. Appears after 15s on the same prompt.
class _SkipPromptChip extends StatelessWidget {
  final VoidCallback onTap;

  const _SkipPromptChip({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surfaceRaised,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.skip_next_rounded,
                  color: Colors.white, size: 18),
              SizedBox(width: 6),
              Text(
                'Skip this pose',
                style: TextStyle(
                  fontFamily: 'Montserrat',
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  letterSpacing: -0.1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// M31 — dedicated Failed view replacing the previous toast-overlaid-
/// on-the-sweep-screen rendering. Single render path; Try Again +
/// Close CTAs are always tappable; no overlap with the initial-state
/// prompt.
class _FailedView extends StatelessWidget {
  final String message;
  final int capturedCount;
  final Future<void> Function() onTryAgain;
  final VoidCallback onClose;

  const _FailedView({
    required this.message,
    required this.capturedCount,
    required this.onTryAgain,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surfaceBg,
      child: SafeArea(
        child: Stack(
          children: [
            // Close chip top-left — always tappable (M31).
            Positioned(
              top: 12,
              left: 12,
              child: _CancelChip(onTap: onClose),
            ),
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.error.withValues(alpha: 0.15),
                        border: Border.all(
                          color: AppColors.error.withValues(alpha: 0.55),
                          width: 1.5,
                        ),
                      ),
                      alignment: Alignment.center,
                      child: const Icon(
                        Icons.error_outline,
                        color: AppColors.error,
                        size: 32,
                      ),
                    ),
                    const SizedBox(height: 18),
                    const Text(
                      "Couldn't capture enough variety",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: 'Montserrat',
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        letterSpacing: -0.2,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      message,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 14,
                        color: AppColors.textSecondaryOnDark,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 28),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () => onTryAgain(),
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          foregroundColor: Colors.white,
                          padding:
                              const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius:
                                BorderRadius.circular(AppTheme.radiusMd),
                          ),
                        ),
                        child: const Text(
                          'Try again',
                          style: TextStyle(
                            fontFamily: 'Montserrat',
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: onClose,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          backgroundColor: AppColors.surfaceRaised,
                          side: const BorderSide(
                              color: AppColors.surfaceBorder),
                          padding:
                              const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius:
                                BorderRadius.circular(AppTheme.radiusMd),
                          ),
                        ),
                        child: const Text(
                          'Close',
                          style: TextStyle(
                            fontFamily: 'Montserrat',
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Painter for the 6-segment guidance ring + dashed face guide.
/// Mockup state 1+2 geometry: ring radius scales to viewport width;
/// segment thickness = 10pt; 10-degree gap between segments; labels
/// sit just outside the ring. Lit segments glow with a coral drop
/// shadow.
class _GuidanceRingPainter extends CustomPainter {
  final Set<PoseBucket> filledBuckets;
  final PoseBucket? targetBucket;

  _GuidanceRingPainter({
    required this.filledBuckets,
    required this.targetBucket,
  });

  /// Bucket order around the ring, clockwise from 12 o'clock. Mirrors
  /// the mockup script's labels array. The angular positions are
  /// chosen so that "UP" is at the top and the front-* / left / right
  /// buckets fall into intuitive positions around the head.
  static const List<PoseBucket> _ringOrder = <PoseBucket>[
    PoseBucket.slightUp, // 12 o'clock (UP)
    PoseBucket.frontRight, // 2
    PoseBucket.right, // 4
    PoseBucket.front, // 6 (DOWN slot — represents the neutral / chin-tucked-down centred shot)
    PoseBucket.left, // 8
    PoseBucket.frontLeft, // 10
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, size.height * 0.38);
    final ringRadius = math.min(size.width, size.height) * 0.38;
    final faceGuideRadius = ringRadius - 24;

    // Dashed face guide circle (per Carl's mockup decision — replaces
    // the prior solid breathing circle).
    _drawDashedCircle(
      canvas,
      centre,
      faceGuideRadius,
      strokeColor: AppColors.primary.withValues(alpha: 0.6),
      strokeWidth: 1.5,
      dashLength: 6,
      gapLength: 8,
    );

    // Segments. Bucket angle = 60 deg. 10 deg gap.
    const buckets = kPoseBucketCount;
    const gapDeg = 10.0;
    const bucketDeg = 360.0 / buckets;

    for (var i = 0; i < buckets; i++) {
      final bucket = _ringOrder[i];
      final centerDeg = i * bucketDeg;
      final startDeg = centerDeg - bucketDeg / 2 + gapDeg / 2;
      final endDeg = centerDeg + bucketDeg / 2 - gapDeg / 2;

      final isLit = filledBuckets.contains(bucket);
      final isTarget = targetBucket == bucket && !isLit;
      final colour = isLit
          ? AppColors.primary
          : isTarget
              ? AppColors.primary.withValues(alpha: 0.55)
              : AppColors.primary.withValues(alpha: 0.18);

      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 10
        ..color = colour;
      if (isLit) {
        paint.maskFilter = const MaskFilter.blur(BlurStyle.outer, 4);
      }
      final rect = Rect.fromCircle(center: centre, radius: ringRadius);
      // SVG-style: 0 deg = 12 o'clock, clockwise. Convert to Flutter
      // canvas coords: -pi/2 = 12 o'clock, sweepAngle clockwise.
      final startRad = (startDeg - 90) * math.pi / 180;
      final sweepRad = (endDeg - startDeg) * math.pi / 180;
      canvas.drawArc(rect, startRad, sweepRad, false, paint);
    }
  }

  void _drawDashedCircle(
    Canvas canvas,
    Offset centre,
    double radius, {
    required Color strokeColor,
    required double strokeWidth,
    required double dashLength,
    required double gapLength,
  }) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..color = strokeColor;
    final circumference = 2 * math.pi * radius;
    final cycle = dashLength + gapLength;
    final cycleCount = (circumference / cycle).floor();
    final dashAngle = (dashLength / radius);
    final gapAngle = (gapLength / radius);
    for (var i = 0; i < cycleCount; i++) {
      final startAngle = i * (dashAngle + gapAngle);
      final rect = Rect.fromCircle(center: centre, radius: radius);
      canvas.drawArc(rect, startAngle, dashAngle, false, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _GuidanceRingPainter oldDelegate) {
    return !setEquals(oldDelegate.filledBuckets, filledBuckets) ||
        oldDelegate.targetBucket != targetBucket;
  }
}

/// Persisting-state placeholder used while the embeddingOnly mode is
/// auto-committing post-sweep. Keeps the viewfinder behind so the
/// transition doesn't flash to a bare black.
class _PersistingOverlayView extends StatelessWidget {
  final CameraController? cameraController;
  final bool cameraReady;
  final bool useFrontCamera;
  final VoidCallback onCancel;
  final VoidCallback onCameraFlip;

  const _PersistingOverlayView({
    required this.cameraController,
    required this.cameraReady,
    required this.useFrontCamera,
    required this.onCancel,
    required this.onCameraFlip,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (cameraReady && cameraController != null)
          Opacity(
            opacity: 0.4,
            child: SizedBox.expand(
              child: FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: cameraController!.value.previewSize?.height ??
                      MediaQuery.of(context).size.width,
                  height: cameraController!.value.previewSize?.width ??
                      MediaQuery.of(context).size.height,
                  child: CameraPreview(cameraController!),
                ),
              ),
            ),
          ),
        Container(color: Colors.black.withValues(alpha: 0.45)),
        const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: AppColors.primary),
              SizedBox(height: 16),
              Text(
                'Saving',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Phase 2 — manual avatar selection grid. Shown ONLY in
/// [FaceEnrolmentMode.full] (avatar consent on) after a successful
/// pose-gated sweep.
///
/// Mockup state 3. Renders:
///   - Quality histogram at the top.
///   - 3-column face grid (1 row for 3 slots, 2 for 4-6, 3 for 7-8).
///   - Frontal-pick highlighted by default; tap any cell to override.
///   - Confirm (coral, primary) + Retake (secondary) buttons at the
///     bottom.
class _AvatarSelectionGridView extends StatelessWidget {
  final List<FaceEnrolmentSlot> slots;
  final int? chosenSlotIndex;
  final ValueChanged<int> onSelect;
  final VoidCallback onCancel;
  final VoidCallback onRetake;
  final Future<void> Function() onConfirm;

  const _AvatarSelectionGridView({
    required this.slots,
    required this.chosenSlotIndex,
    required this.onSelect,
    required this.onCancel,
    required this.onRetake,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    // The default-highlighted cell is the chosen one if the user has
    // tapped, else the auto frontal-pick (typically slot 0 for the
    // front-bucket capture). Falls back to slot 0 if no flag is set.
    int defaultIdx = slots.indexWhere((s) => s.isFrontalPick);
    if (defaultIdx < 0) defaultIdx = 0;
    final selectedIdx = chosenSlotIndex ?? defaultIdx;

    // Quality average → maybe surface a low-quality warning banner.
    double avg = 0;
    if (slots.isNotEmpty) {
      double sum = 0;
      int n = 0;
      for (final s in slots) {
        if (s.qualityScore != null) {
          sum += s.qualityScore!;
          n++;
        }
      }
      avg = n > 0 ? (sum / n) : 0;
    }
    final showLowQualityWarning = slots.length >= 3 && avg > 0 && avg < 70;

    return Container(
      color: AppColors.surfaceBg,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header row — cancel chip + title.
              Row(
                children: [
                  _CancelChip(onTap: onCancel),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Pick the avatar',
                      style: TextStyle(
                        fontFamily: 'Montserrat',
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        letterSpacing: -0.3,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.only(left: 52),
                child: Text(
                  'All ${slots.length} angles saved. Tap the photo to use '
                  "as the client's profile image.",
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 13,
                    color: AppColors.textSecondaryOnDark,
                    height: 1.45,
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Quality histogram.
              _QualityHistogram(slots: slots),

              if (showLowQualityWarning) ...[
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: AppColors.warning.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                    border: Border.all(
                      color: AppColors.warning.withValues(alpha: 0.40),
                    ),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.warning_amber_rounded,
                          color: AppColors.warning, size: 18),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Quality is low — try better lighting or get closer.',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: Colors.white,
                            height: 1.35,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 18),
              const Text(
                'CAPTURED ANGLES',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.2,
                  color: AppColors.textSecondaryOnDark,
                ),
              ),
              const SizedBox(height: 10),

              // Grid. Always 3 columns; rows scale with slot count.
              Expanded(
                child: GridView.builder(
                  itemCount: slots.length,
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 3 / 4,
                  ),
                  itemBuilder: (context, i) {
                    return _GridCell(
                      slot: slots[i],
                      selected: i == selectedIdx,
                      onTap: () => onSelect(i),
                    );
                  },
                ),
              ),

              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: onRetake,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        backgroundColor: AppColors.surfaceRaised,
                        side: const BorderSide(
                            color: AppColors.surfaceBorder),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius:
                              BorderRadius.circular(AppTheme.radiusMd),
                        ),
                      ),
                      child: const Text(
                        'Retake',
                        style: TextStyle(
                          fontFamily: 'Montserrat',
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => onConfirm(),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius:
                              BorderRadius.circular(AppTheme.radiusMd),
                        ),
                      ),
                      child: const Text(
                        'Confirm',
                        style: TextStyle(
                          fontFamily: 'Montserrat',
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GridCell extends StatelessWidget {
  final FaceEnrolmentSlot slot;
  final bool selected;
  final VoidCallback onTap;

  const _GridCell({
    required this.slot,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final score = slot.qualityScore?.round();
    final Color scoreColour;
    if (score == null) {
      scoreColour = AppColors.textSecondaryOnDark;
    } else if (score >= 80) {
      scoreColour = AppColors.primary;
    } else if (score >= 60) {
      scoreColour = AppColors.warning;
    } else {
      scoreColour = AppColors.error;
    }

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          color: AppColors.surfaceBase,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.surfaceBorder,
            width: selected ? 2 : 1,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: AppColors.primary.withValues(alpha: 0.18),
                    blurRadius: 0,
                    spreadRadius: 3,
                  ),
                ]
              : null,
        ),
        clipBehavior: Clip.hardEdge,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Source frame thumbnail. Falls back to the placeholder
            // glyph if the file is missing (e.g. sweep was cancelled
            // mid-flow and the producer dir was cleaned).
            if (slot.sourceFramePath != null &&
                File(slot.sourceFramePath!).existsSync())
              Image.file(
                File(slot.sourceFramePath!),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const _SlotPlaceholder(),
              )
            else
              const _SlotPlaceholder(),

            // Score chip top-right.
            if (score != null)
              Positioned(
                top: 5,
                right: 5,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceBg.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '$score',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: scoreColour,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),

            // Frontal star top-left (auto frontal pick only).
            if (slot.isFrontalPick)
              const Positioned(
                top: 5,
                left: 5,
                child: _FrontalStar(),
              ),

            // Pose label bottom.
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
                color: AppColors.surfaceBg.withValues(alpha: 0.75),
                alignment: Alignment.center,
                child: Text(
                  slot.bucket?.label ?? 'unknown',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    color: selected
                        ? AppColors.primaryLight
                        : AppColors.textSecondaryOnDark,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FrontalStar extends StatelessWidget {
  const _FrontalStar();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 16,
      height: 16,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.primary,
      ),
      alignment: Alignment.center,
      child: const Icon(
        Icons.star,
        size: 10,
        color: Colors.white,
      ),
    );
  }
}

class _QualityHistogram extends StatelessWidget {
  final List<FaceEnrolmentSlot> slots;

  const _QualityHistogram({required this.slots});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surfaceBase,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.surfaceBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final s in slots) ...[
            Expanded(child: _HistogramBar(score: s.qualityScore)),
            const SizedBox(width: 4),
          ],
        ]..removeLast(),
      ),
    );
  }
}

class _HistogramBar extends StatelessWidget {
  final double? score;

  const _HistogramBar({required this.score});

  @override
  Widget build(BuildContext context) {
    final s = score ?? 0;
    final Color colour;
    if (s >= 80) {
      colour = AppColors.primary;
    } else if (s >= 60) {
      colour = AppColors.warning;
    } else {
      colour = AppColors.error;
    }
    // Map 50..100 → 4..28 pt of bar height; below 50 = 4pt minimum.
    final h = math.max(4.0, ((s - 50) / 50) * 28).clamp(4.0, 28.0);
    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Container(
          height: h.toDouble(),
          decoration: BoxDecoration(
            color: colour,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(3),
            ),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          '${s.round()}',
          style: const TextStyle(
            fontFamily: 'Inter',
            fontSize: 8,
            fontWeight: FontWeight.w700,
            color: AppColors.textSecondaryOnDark,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}
