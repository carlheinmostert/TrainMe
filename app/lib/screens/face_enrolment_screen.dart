import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/client.dart';
import '../services/face_enrolment_service.dart';
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
///
/// Entry points (Wave-D):
///   - Empty avatar slot tap on client detail → push this screen directly.
///   - Existing avatar tap → bottom sheet → "Replace avatar and re-enrol"
///     → push this screen.
///
/// POPIA: the parent screen MUST gate on
/// [PracticeClient.safeModeFaceRecognitionAllowed]. This screen does not
/// re-check — gating is the caller's responsibility so the toast copy
/// matches the surrounding UX surface.
class FaceEnrolmentScreen extends StatefulWidget {
  final PracticeClient client;

  const FaceEnrolmentScreen({
    super.key,
    required this.client,
  });

  @override
  State<FaceEnrolmentScreen> createState() => _FaceEnrolmentScreenState();

  /// Convenience push. Returns `true` if enrolment succeeded, `false`
  /// on cancel / failure. Callers use the result to optionally pop a
  /// confirm chip; both outcomes are non-destructive.
  static Future<bool> push(
    BuildContext context, {
    required PracticeClient client,
  }) async {
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        fullscreenDialog: true,
        builder: (_) => FaceEnrolmentScreen(client: client),
      ),
    );
    return ok ?? false;
  }
}

class _FaceEnrolmentScreenState extends State<FaceEnrolmentScreen>
    with WidgetsBindingObserver {
  /// Front-camera controller — selfie convention. Re-built across
  /// app-lifecycle resume.
  CameraController? _cameraController;

  /// Picked camera description. Cached so re-attach after backgrounding
  /// uses the same lens.
  CameraDescription? _camera;

  /// True once the camera is initialised + previewing. Drives the
  /// loading spinner overlay.
  bool _cameraReady = false;

  /// True if the camera failed to start. Surfaces an inline error
  /// state instead of the viewfinder.
  bool _cameraFailed = false;
  String? _cameraErrorMessage;

  /// Lifecycle controller for the service. Reused across retries.
  late final FaceEnrolmentService _service;

  StreamSubscription<FaceEnrolmentError>? _errorSub;

  /// Inline coral-bordered toast text. Surfaced at the top of the
  /// viewfinder for 4s before auto-popping (per spec). Null = no
  /// toast.
  String? _toast;
  Timer? _toastTimer;

  /// Wall-clock instant the latest take-picture call was kicked off,
  /// used to drop overlapping calls if the prior is still finishing
  /// (camera plugin doesn't queue takePicture).
  bool _takePictureInFlight = false;

  /// Temp dir for the frame producer's outputs. Cleared on every
  /// `_resetForRetry` and when the screen pops.
  Directory? _producerTempDir;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _service = FaceEnrolmentService();
    _service.addListener(_onServiceChanged);
    _errorSub = _service.errorStream.listen(_onServiceError);
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _toastTimer?.cancel();
    _errorSub?.cancel();
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

  // ── Camera lifecycle ────────────────────────────────────────────────────

  Future<void> _initCamera() async {
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
      final front = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
      _camera = front;

      final controller = CameraController(
        front,
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

      // Tiny delay so the preview has a frame on screen before the
      // ring starts spinning — gives the user a half-beat to read the
      // first instruction.
      await Future<void>.delayed(const Duration(milliseconds: 350));
      if (!mounted) return;
      if (_service.state == FaceEnrolmentState.idle) {
        unawaited(_service.startSweep());
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
    if (state == FaceEnrolmentState.failed) {
      // Toast lifecycle handled in _onServiceError; here we just
      // schedule the auto-pop.
      _scheduleAutoPopAfterToast();
    }
    setState(() {});
  }

  void _onServiceError(FaceEnrolmentError err) {
    if (!mounted) return;
    setState(() {
      _toast = err.message;
    });
    _toastTimer?.cancel();
    _toastTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      setState(() => _toast = null);
    });
  }

  void _scheduleAutoPopAfterToast() {
    // Toast shows for 4s then we pop with failure. Reuses the same
    // timer the toast itself runs on so we don't double-fire.
    _toastTimer?.cancel();
    _toastTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      _popWithResult(false);
    });
  }

  void _popWithResult(bool success) {
    if (!mounted) return;
    Navigator.of(context).maybePop<bool>(success);
  }

  void _onCancelTap() {
    HapticFeedback.selectionClick();
    _service.cancel();
    // _onServiceChanged handles the pop once state transitions.
  }

  Future<void> _onCommitTap() async {
    if (_service.state != FaceEnrolmentState.confirming) return;
    HapticFeedback.mediumImpact();
    await _service.commit(clientId: widget.client.id);
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
    final state = _service.state;
    if (state == FaceEnrolmentState.confirming) {
      return _ConfirmView(
        slots: _service.pendingSlots ?? const [],
        capturedFrames: _service.capturedFramePaths,
        onCancel: _onCancelTap,
        onCommit: _onCommitTap,
      );
    }
    return _SweepView(
      cameraController: _cameraController,
      cameraReady: _cameraReady,
      progress: _service.progress,
      instructionText: _service.instructionText,
      state: state,
      onCancel: _onCancelTap,
      toast: _toast,
    );
  }
}

/// The viewfinder + ring during sweep / embedding / persisting / failed
/// states. Pulled out so the confirm view can replace it cleanly via
/// the parent's switch.
class _SweepView extends StatelessWidget {
  final CameraController? cameraController;
  final bool cameraReady;
  final double progress;
  final String? instructionText;
  final FaceEnrolmentState state;
  final VoidCallback onCancel;
  final String? toast;

  const _SweepView({
    required this.cameraController,
    required this.cameraReady,
    required this.progress,
    required this.instructionText,
    required this.state,
    required this.onCancel,
    required this.toast,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // 1. Front-camera preview (or loading spinner). Mirrored via
        //    the camera plugin's natural selfie behaviour.
        if (cameraReady && cameraController != null)
          // Dim to ~70% so the coral overlay reads cleanly per spec.
          Opacity(
            opacity: 0.70,
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

        // 2. Radial vignette — 0% centre → 50% black corners. Focuses
        //    attention on the centre ring.
        if (cameraReady)
          IgnorePointer(
            child: Container(
              decoration: const BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment.center,
                  radius: 1.1,
                  colors: [
                    Color(0x00000000),
                    Color(0x80000000),
                  ],
                  stops: [0.55, 1.0],
                ),
              ),
            ),
          ),

        // 3-5. Coral circle + arc ring + ticks — single CustomPaint
        //      so the whole concentric stack moves together.
        if (cameraReady)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _EnrolmentRingPainter(
                  progress: progress,
                  tickCount: FaceEnrolmentService.kRingTickCount,
                  pulsePhase: state == FaceEnrolmentState.sweepingYaw &&
                          progress < 0.05
                      ? DateTime.now().millisecondsSinceEpoch / 1000.0
                      : null,
                ),
              ),
            ),
          ),

        // 6. Instruction text below the ring.
        if (cameraReady && instructionText != null)
          _InstructionLabel(text: instructionText!),

        // 7. Cancel chip top-left.
        Positioned(
          top: 12,
          left: 12,
          child: _CancelChip(onTap: onCancel),
        ),

        // Persisting overlay — full-screen dim + spinner.
        if (state == FaceEnrolmentState.persisting)
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

        // Inline coral-bordered toast at top — used for failure modes
        // and warnings (e.g. notEnoughAngles). Auto-dismissed by the
        // parent's timer.
        if (toast != null)
          Positioned(
            top: 64,
            left: 16,
            right: 16,
            child: _ErrorToast(message: toast!),
          ),
      ],
    );
  }
}

/// The post-sweep confirm screen. Shows the picked slots in a
/// horizontal thumbnail row + the frontal-pick highlighted + a Done
/// button at the bottom.
class _ConfirmView extends StatelessWidget {
  final List<FaceEnrolmentSlot> slots;
  final List<String> capturedFrames;
  final VoidCallback onCancel;
  final Future<void> Function() onCommit;

  const _ConfirmView({
    required this.slots,
    required this.capturedFrames,
    required this.onCancel,
    required this.onCommit,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(color: AppColors.surfaceBg),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            child: Column(
              children: [
                Row(
                  children: [
                    _CancelChip(onTap: onCancel),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        'Confirm enrolment',
                        style: TextStyle(
                          fontFamily: 'Montserrat',
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                const Text(
                  'Captured angles',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 13,
                    color: AppColors.textSecondaryOnDark,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 92,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: slots.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (context, i) => _SlotThumbnail(
                      slot: slots[i],
                      // Map slot index → captured frame approximation
                      // (native picks slots in capture order).
                      capturedPath: _resolveCapturedPath(i),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: AppColors.brandTintBg,
                    borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                    border: Border.all(color: AppColors.brandTintBorder),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.face_retouching_natural,
                        color: AppColors.primary,
                        size: 18,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Most-frontal frame · avatar source',
                              style: TextStyle(
                                fontFamily: 'Inter',
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              "${slots.length} angles will be stored "
                              "so we recognise this client from any side.",
                              style: const TextStyle(
                                fontFamily: 'Inter',
                                fontSize: 12,
                                color: AppColors.textSecondaryOnDark,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => onCommit(),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius:
                            BorderRadius.circular(AppTheme.radiusMd),
                      ),
                    ),
                    child: const Text(
                      'Done',
                      style: TextStyle(
                        fontFamily: 'Inter',
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
    );
  }

  /// Approximate which captured-frame file corresponds to slot [i].
  /// Native picks slots in capture order so proportional mapping is
  /// close enough for a confirm-view thumbnail. Returns null if the
  /// buffer was emptied (cancel/teardown).
  String? _resolveCapturedPath(int slotIndex) {
    if (capturedFrames.isEmpty) return null;
    if (slots.isEmpty) return null;
    final approx = ((slotIndex / slots.length) * capturedFrames.length)
        .floor()
        .clamp(0, capturedFrames.length - 1);
    return capturedFrames[approx];
  }
}

/// One slot in the confirm view's horizontal strip.
class _SlotThumbnail extends StatelessWidget {
  final FaceEnrolmentSlot slot;
  final String? capturedPath;

  const _SlotThumbnail({
    required this.slot,
    required this.capturedPath,
  });

  @override
  Widget build(BuildContext context) {
    final borderColor =
        slot.isFrontalPick ? AppColors.primary : AppColors.surfaceBorder;
    return Container(
      width: 70,
      height: 92,
      decoration: BoxDecoration(
        color: AppColors.surfaceBase,
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        border: Border.all(
          color: borderColor,
          width: slot.isFrontalPick ? 2 : 1,
        ),
      ),
      clipBehavior: Clip.hardEdge,
      child: capturedPath != null
          ? Image.file(
              File(capturedPath!),
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const _SlotPlaceholder(),
            )
          : const _SlotPlaceholder(),
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

class _InstructionLabel extends StatelessWidget {
  final String text;

  const _InstructionLabel({required this.text});

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    // Sit roughly 28% from the bottom — below the ring, above the
    // safe-area inset. Tuned by inspection against the spec's mock
    // visual hierarchy.
    return Positioned(
      left: 24,
      right: 24,
      bottom: size.height * 0.18,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.40),
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        ),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily: 'Montserrat',
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Colors.white,
            height: 1.3,
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

/// Custom painter for the concentric coral circle + arc progress ring
/// + tick marks. All geometry in one painter so the visual stack
/// stays pixel-aligned across rebuilds.
class _EnrolmentRingPainter extends CustomPainter {
  final double progress;
  final int tickCount;

  /// Seconds-since-epoch fractional value when in the early-sweep
  /// breathing-pulse window. Null = no pulse.
  final double? pulsePhase;

  _EnrolmentRingPainter({
    required this.progress,
    required this.tickCount,
    this.pulsePhase,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, size.height / 2);
    // Coral circle diameter ≈ 70% of viewport width (per spec).
    final circleDiameter = size.width * 0.70;
    final circleRadius = circleDiameter / 2;
    // Arc ring sits 12px outside the coral circle (per spec).
    final ringRadius = circleRadius + 12;

    // 1. Coral circle outline. 3px stroke.
    final pulseOpacity = pulsePhase == null
        ? 1.0
        : (0.92 + 0.08 * math.sin(pulsePhase! * 2 * math.pi * 1));
    final circlePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = AppColors.primary.withValues(alpha: pulseOpacity);
    canvas.drawCircle(centre, circleRadius, circlePaint);

    // 2. Arc track (full ring, dim coral).
    final trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..color = AppColors.primary.withValues(alpha: 0.20)
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(centre, ringRadius, trackPaint);

    // 3. Arc fill (progress from 12 o'clock clockwise).
    if (progress > 0) {
      final fillPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..color = AppColors.primary
        ..strokeCap = StrokeCap.round;
      final sweepAngle = 2 * math.pi * progress.clamp(0.0, 1.0);
      // Start at -π/2 (top, 12 o'clock).
      canvas.drawArc(
        Rect.fromCircle(center: centre, radius: ringRadius),
        -math.pi / 2,
        sweepAngle,
        false,
        fillPaint,
      );
    }

    // 4. Tick marks. Each tick: 8px radial line straddling the ring.
    final tickRadiusInner = ringRadius - 8;
    final tickRadiusOuter = ringRadius + 8;
    for (var i = 0; i < tickCount; i++) {
      final angle = -math.pi / 2 + (2 * math.pi * (i / tickCount));
      final p1 = Offset(
        centre.dx + tickRadiusInner * math.cos(angle),
        centre.dy + tickRadiusInner * math.sin(angle),
      );
      final p2 = Offset(
        centre.dx + tickRadiusOuter * math.cos(angle),
        centre.dy + tickRadiusOuter * math.sin(angle),
      );
      // Tick is "lit" if the progress arc has swept past it.
      final tickProgressThreshold = i / tickCount;
      final lit = progress >= tickProgressThreshold;
      final tickPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = lit ? 2 : 1
        ..color = AppColors.primary
            .withValues(alpha: lit ? 1.0 : 0.50);
      canvas.drawLine(p1, p2, tickPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _EnrolmentRingPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.tickCount != tickCount ||
        oldDelegate.pulsePhase != pulsePhase;
  }
}
