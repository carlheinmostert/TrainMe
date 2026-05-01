import 'dart:async';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../config.dart';
import '../models/exercise_capture.dart';
import '../models/session.dart';
import '../services/conversion_service.dart';
import '../services/homefit_haptics.dart';
import '../services/local_storage_service.dart';
import '../services/path_resolver.dart';
import '../services/sticky_defaults.dart';
import '../services/sync_service.dart';
import '../theme.dart';
import '../widgets/capture_thumbnail.dart';
import '../widgets/orientation_lock_guard.dart';
import '../widgets/shell_pull_tab.dart';

/// In-session camera mode.
///
/// Full-screen camera preview with a single shutter (tap = photo,
/// long-press = video), top-corner controls (flip, flash, exit), a
/// subtle edge pull-tab hinting at Studio mode on the left, and a
/// peek-only capture box mid-left showing the last capture's thumbnail
/// and total count.
///
/// Video recording gets a scale-pulsing red dot (1s cycle, same clock
/// as the haptic tick), a large 30-second countdown, and per-second
/// `mediumImpact` haptic ticks so the bio knows the recording is live
/// without staring at the screen. The visual pulse is a backup for the
/// haptic — iOS can suppress softer haptics while the mic is active.
///
/// Failures are silent — the count doesn't increment — because the bio
/// shouldn't have their attention pulled away from the client by modal
/// error dialogs mid-session.
class CaptureModeScreen extends StatefulWidget {
  final Session session;
  final LocalStorageService storage;

  /// Called after a successful capture lands on disk. Parent refreshes
  /// the session from storage so Studio mode sees the new exercise.
  final Future<void> Function() onCapturesChanged;

  /// Invoked when the user taps the left-edge pull-tab to return to
  /// Studio.
  final VoidCallback onExitToStudio;

  const CaptureModeScreen({
    super.key,
    required this.session,
    required this.storage,
    required this.onCapturesChanged,
    required this.onExitToStudio,
  });

  @override
  State<CaptureModeScreen> createState() => _CaptureModeScreenState();
}

/// The default orientation set for the camera surface — portrait plus
/// both landscapes. Recording lock clamps this to a single orientation
/// (or both landscapes only) for the duration of a clip.
const Set<DeviceOrientation> _kCameraDefaultOrientations = {
  DeviceOrientation.portraitUp,
  DeviceOrientation.landscapeLeft,
  DeviceOrientation.landscapeRight,
};

class _CaptureModeScreenState extends State<CaptureModeScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  // Wave 40 (M3) — the auto-fading "Hold for video" hint (Wave 8) has
  // been retired in favour of a PERMANENT caption beneath the shutter
  // with three states: idle / pressed-recording / locked. The
  // process-wide static flag and 3s auto-dismiss timer are gone with
  // it.

  // --- Camera state ---
  CameraController? _cameraController;
  List<CameraDescription> _cameras = const [];
  int _activeCameraIndex = 0;
  bool _isCameraInitialized = false;
  FlashMode _flashMode = FlashMode.off;

  // Wave 40.5 (M4) — ultrawide camera support. The `camera` plugin's
  // `setZoomLevel(0.5)` clamps to `getMinZoomLevel()` (>=1.0) on the
  // main wide camera. To reach 0.5x we swap CameraDescription to the
  // ultrawide lens. These are populated in `_initCamera`.
  CameraDescription? _backWideCamera;
  CameraDescription? _backUltrawideCamera;
  bool _isOnUltrawide = false;

  // --- Zoom state ---
  /// Physical zoom bounds of the active controller (in logical "x" terms:
  /// 0.5x, 1x, 2x, etc.). Populated after initialization.
  double _minZoom = 1.0;
  double _maxZoom = 1.0;

  /// Current logical zoom factor (1.0 = main wide lens).
  double _currentZoom = 1.0;

  /// Baseline zoom at the start of a pinch gesture — used so we scale
  /// from the existing zoom, not always from 1.0.
  double _pinchBaseZoom = 1.0;

  /// Pre-computed list of lens-switch buttons the device supports. Built
  /// once after the controller initializes (or after flip) so the build
  /// method stays cheap. `1x` is always present; `0.5x / 2x / 3x` only
  /// appear if the zoom range covers them.
  List<double> _availableLenses = const [1.0];

  // --- Recording state ---
  bool _isRecording = false;

  /// Wave 40 (M4) — true once the user has slid their finger up onto
  /// the lock target and snapped recording into hands-free mode. While
  /// locked: releasing the shutter does NOT stop recording. Stop is
  /// triggered by tapping the morphed (white-square) shutter inner.
  bool _isLocked = false;

  /// Wave 40 (M4) — true while the finger is hovering over the lock
  /// target rect. Derived from upward-drag distance inside the
  /// shutter zone (Listener `onPointerMove`); used for the lock
  /// target's highlight tint + snap-on-release.
  bool _hoveringLockTarget = false;

  /// True between `onLongPressDown` firing and the long-press gesture
  /// ending (end OR cancel OR pointer-up). Acts as a belt-and-braces
  /// flag for the release-gesture fix: if the user lifts their finger
  /// before `_startVideoRecording`'s async init finishes, we still
  /// honour the release and stop as soon as recording has actually
  /// started on the controller.
  bool _longPressActive = false;

  /// Set when the pointer goes up mid-start so the newly-started
  /// recording immediately stops once the controller confirms the start.
  bool _pendingStopAfterStart = false;

  /// Guards against double-stop when both `onLongPressEnd` and the raw
  /// `onPointerUp` Listener fire for the same release.
  bool _stopInFlight = false;

  /// Wave 40 (M2) — multi-select photo picker for the bottom-left
  /// library import button inside the camera viewfinder. Each picked
  /// photo flows through the SAME pipeline as a captured photo
  /// (peek-box animation + conversion queue entry + StudioCard
  /// append). No batched silent ingest.
  final ImagePicker _picker = ImagePicker();

  bool _wasRecordingOnBackground = false;
  Timer? _recordingTickTimer;
  int _recordingSeconds = 0;

  /// Orientation lock for the camera surface. Defaults to portrait +
  /// both landscapes. The moment a recording starts, this clamps to the
  /// orientation recording started in so AVFoundation's embedded
  /// transform metadata stays single-valued (mid-clip rotation otherwise
  /// produces a half-portrait, half-landscape clip with one transform).
  Set<DeviceOrientation> _allowedOrientations = _kCameraDefaultOrientations;

  // --- Peek box state ---
  /// Latest capture shown in the peek box. Updated whenever a capture
  /// lands successfully.
  ExerciseCapture? _lastCapture;

  /// Local capture count (mirrors successfully saved exercises in this
  /// session). Kept in local state so we can increment optimistically
  /// without waiting for the parent refresh round-trip.
  late int _captureCount;

  /// Controller for the "capture flies into the box" animation.
  late final AnimationController _flyController;

  /// Wave 40 (M4) — fade controller for the lock-target + drag-track
  /// overlays. Driven from 0 → 1 over ~200ms once recording starts;
  /// reverses on stop / cancel.
  late final AnimationController _lockTargetController;


  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _captureCount = widget.session.exercises.length;
    // Seed _lastCapture with the most recent existing capture so the
    // peek box isn't empty on first open of an in-progress session.
    if (widget.session.exercises.isNotEmpty) {
      _lastCapture = widget.session.exercises.last;
    }
    _flyController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    _lockTargetController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _initCamera();
  }

  @override
  void didUpdateWidget(covariant CaptureModeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Keep local count in sync with parent session if it refreshes.
    final parentCount = widget.session.exercises.length;
    if (parentCount > _captureCount) {
      _captureCount = parentCount;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_recordingTickTimer != null) {
      debugPrint('recording tick timer cancelled (dispose)');
    }
    _recordingTickTimer?.cancel();
    _recordingTickTimer = null;
    _cameraController?.dispose();
    _flyController.dispose();
    _lockTargetController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _cameraController;
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      // Nothing to do if there's no controller to tear down.
      if (controller == null) return;

      // Cancel the per-second tick before any async work so we don't
      // emit a stray haptic/state change after the app is hidden.
      if (_recordingTickTimer != null) {
        debugPrint('recording tick timer cancelled (lifecycle paused)');
      }
      _recordingTickTimer?.cancel();
      _recordingTickTimer = null;

      // Salvage: if the controller is mid-recording when the system
      // snatches the camera away (phone call, Control Centre swipe),
      // stop cleanly first. stopVideoRecording() writes the MOOV atom
      // so the clip is playable; skipping it would truncate the file
      // to an un-demuxable stream. Run the stop + dispose on a
      // fire-and-forget future so we don't block the lifecycle
      // callback, but still guard the controller from double-dispose
      // via the local `controller` ref.
      final wasRecording =
          _isRecording || controller.value.isRecordingVideo;
      if (wasRecording) {
        _wasRecordingOnBackground = true;
      }

      setState(() {
        _isRecording = false;
        _isLocked = false;
        _hoveringLockTarget = false;
        _longPressActive = false;
        _pendingStopAfterStart = false;
        _stopInFlight = false;
        _recordingSeconds = 0;
        _isCameraInitialized = false;
        _cameraController = null;
        _allowedOrientations = _kCameraDefaultOrientations;
      });
      _lockTargetController.reverse();

      unawaited(_teardownController(controller, salvageRecording: wasRecording));
    } else if (state == AppLifecycleState.resumed) {
      // Re-initialise if the controller was torn down (or never came up
      // cleanly). _initCamera() has its own guard against double-init.
      if (_cameraController == null ||
          !(_cameraController?.value.isInitialized ?? false)) {
        _initCamera();
      }
      if (_wasRecordingOnBackground && mounted) {
        _wasRecordingOnBackground = false;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Recording interrupted')),
        );
      }
    }
  }

  /// Tear down a camera controller that was active when the app went to
  /// background. If [salvageRecording] is true, attempts to stop the
  /// in-flight video recording first so the partial clip is playable
  /// (MOOV atom written by AVFoundation) and can still be persisted as
  /// an exercise.
  ///
  /// All failures are swallowed — the priority is disposing the
  /// controller cleanly so iOS releases the camera. A lost recording is
  /// a worse outcome than a silent save failure (we'll still dispose
  /// cleanly), so we try to salvage but never let an exception block
  /// the dispose path.
  Future<void> _teardownController(
    CameraController controller, {
    required bool salvageRecording,
  }) async {
    if (salvageRecording) {
      try {
        if (controller.value.isRecordingVideo) {
          final xFile = await controller.stopVideoRecording();
          // Persist the salvaged clip as a capture — same path the
          // normal stop-recording flow uses. Non-blocking w.r.t. the
          // dispose below.
          try {
            final exercise =
                await _persistCapture(xFile.path, MediaType.video);
            if (exercise != null && mounted) {
              _onCaptureLanded(exercise);
            }
          } catch (e) {
            debugPrint('Lifecycle-salvaged clip persist failed: $e');
          }
        }
      } catch (e) {
        // iOS sometimes raises "Recording is not in progress" if the
        // system already stopped us before this fires. Log and move
        // on — the file may or may not exist on disk; dispose is what
        // matters next.
        debugPrint('Lifecycle stopVideoRecording failed: $e');
      }
    }
    try {
      await controller.dispose();
    } catch (e) {
      debugPrint('Lifecycle controller.dispose failed: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Camera lifecycle
  // ---------------------------------------------------------------------------

  Future<void> _initCamera() async {
    // Double-init guard — defends against lifecycle resume firing while a
    // previous _initCamera() is still in flight, or a stale re-entry from
    // didChangeAppLifecycleState. If a controller is already initialised
    // we've nothing to do.
    if (_cameraController != null &&
        _cameraController!.value.isInitialized) {
      return;
    }
    try {
      _cameras = await availableCameras();
    } catch (e) {
      debugPrint('availableCameras failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Camera unavailable — check permissions')),
        );
        widget.onExitToStudio();
      }
      return;
    }
    if (_cameras.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No camera available on this device')),
        );
        widget.onExitToStudio();
      }
      return;
    }

    // Prefer back camera on fresh init.
    _activeCameraIndex = _cameras.indexWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
    );
    if (_activeCameraIndex < 0) _activeCameraIndex = 0;

    // Wave 40.5 (M4) — identify back-wide vs back-ultrawide for 0.5x
    // lens switching. On iPhones with dual/triple rear cameras,
    // `availableCameras()` returns separate CameraDescription entries
    // for each physical lens. The ultrawide typically has the lowest
    // sensorOrientation or is listed after the main wide. We identify
    // it by checking for "ultra" in the name (iOS reports
    // "Back Ultra Wide Camera") or by picking the second back camera.
    final backCameras = _cameras
        .where((c) => c.lensDirection == CameraLensDirection.back)
        .toList();
    _backWideCamera = null;
    _backUltrawideCamera = null;
    _isOnUltrawide = false;
    if (backCameras.length >= 2) {
      // iOS names: "Back Camera", "Back Ultra Wide Camera",
      // "Back Telephoto Camera". Match on "ultra" (case-insensitive).
      for (final cam in backCameras) {
        final name = cam.name.toLowerCase();
        if (name.contains('ultra')) {
          _backUltrawideCamera = cam;
        } else {
          _backWideCamera ??= cam;
        }
      }
      // Fallback: if no "ultra" name found, treat the second back camera
      // as ultrawide (some older iOS versions don't label them).
      if (_backUltrawideCamera == null && backCameras.length >= 2) {
        _backWideCamera = backCameras[0];
        _backUltrawideCamera = backCameras[1];
      }
    }

    await _attachController(_cameras[_activeCameraIndex]);
  }

  Future<void> _attachController(CameraDescription camera) async {
    final controller = CameraController(
      camera,
      ResolutionPreset.high,
      enableAudio: true,
    );
    try {
      await controller.initialize();
      try {
        await controller.setFlashMode(_flashMode);
      } catch (_) {
        // Some simulators don't support flash; ignore silently.
      }

      // Query zoom range once, up front, so _buildLensRow / pinch can
      // operate without async calls in the build path.
      double minZoom = 1.0;
      double maxZoom = 1.0;
      try {
        minZoom = await controller.getMinZoomLevel();
        maxZoom = await controller.getMaxZoomLevel();
      } catch (_) {
        // Some simulators throw — fall back to no-zoom.
      }

      // Reset to 1x on (re)attach. On iOS the multi-camera virtual
      // device will auto-pick the matching physical lens under the hood
      // when the user later changes zoom via pinch or lens pills.
      try {
        await controller
            .setZoomLevel(1.0.clamp(minZoom, maxZoom).toDouble());
      } catch (_) {
        // Ignore — zoom not supported on this device.
      }

      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _cameraController = controller;
        _isCameraInitialized = true;
        _minZoom = minZoom;
        _maxZoom = maxZoom;
        _currentZoom = 1.0.clamp(minZoom, maxZoom).toDouble();
        _availableLenses = _buildLensListForRange(minZoom, maxZoom);
      });
    } catch (e) {
      debugPrint('Camera init failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Camera failed: $e')),
        );
        widget.onExitToStudio();
      }
    }
  }

  /// Build the lens-switch button list from the zoom range the active
  /// controller reports.
  ///
  /// Wave 40.5 (M4) — `0.5×` is shown when an ultrawide camera is
  /// detected (via CameraDescription swap) OR when the zoom range
  /// covers it natively. On devices without ultrawide, the pill is
  /// hidden to avoid a no-op button. `2×` and `3×` stay gated on the
  /// reported max so we don't show pills that exceed digital-zoom
  /// range on smaller sensors.
  List<double> _buildLensListForRange(double minZoom, double maxZoom) {
    const candidates = [0.5, 1.0, 2.0, 3.0];
    final lenses = <double>[];
    for (final c in candidates) {
      if (c == 0.5) {
        // Show 0.5x only if we have an ultrawide camera to switch to,
        // or the zoom range natively supports it.
        if (_backUltrawideCamera != null || minZoom <= 0.5) {
          lenses.add(c);
        }
        continue;
      }
      if (c == 1.0) {
        lenses.add(c);
        continue;
      }
      if (c >= minZoom && c <= maxZoom) {
        lenses.add(c);
      }
    }
    return lenses;
  }

  Future<void> _flipCamera() async {
    if (_cameras.length < 2 || _isRecording) return;
    final next = (_activeCameraIndex + 1) % _cameras.length;
    final current = _cameraController;
    setState(() {
      _isCameraInitialized = false;
      _cameraController = null;
    });
    await current?.dispose();
    _activeCameraIndex = next;
    await _attachController(_cameras[next]);
  }

  Future<void> _cycleFlash() async {
    if (_cameraController == null) return;
    // Cycle: off → auto → always → torch → off
    const order = [
      FlashMode.off,
      FlashMode.auto,
      FlashMode.always,
      FlashMode.torch,
    ];
    final idx = order.indexOf(_flashMode);
    final next = order[(idx + 1) % order.length];
    try {
      await _cameraController!.setFlashMode(next);
      setState(() => _flashMode = next);
    } catch (e) {
      debugPrint('setFlashMode failed: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Zoom / lens switching
  // ---------------------------------------------------------------------------

  /// Apply a logical zoom factor (clamped to the device's zoom range)
  /// and update state.
  ///
  /// Wave 40.5 (M4) — 0.5x requires swapping CameraDescription to the
  /// ultrawide lens because `setZoomLevel(0.5)` clamps to 1.0 on the
  /// main wide camera. When switching back from ultrawide to wide (any
  /// value >= 1.0), we swap the controller back and then set zoom.
  Future<void> _applyZoom(double requested) async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;

    // 0.5x requested + ultrawide available + not already on ultrawide
    if (requested <= 0.5 && _backUltrawideCamera != null && !_isOnUltrawide) {
      await _switchToCamera(_backUltrawideCamera!, isUltrawide: true);
      return;
    }

    // >= 1.0 requested but we're on ultrawide — swap back to wide
    if (requested >= 1.0 && _isOnUltrawide && _backWideCamera != null) {
      await _switchToCamera(_backWideCamera!, isUltrawide: false);
      // After switching back to wide, apply the requested zoom
      final ctrl = _cameraController;
      if (ctrl != null && ctrl.value.isInitialized && mounted) {
        final clamped = requested.clamp(_minZoom, _maxZoom).toDouble();
        try {
          await ctrl.setZoomLevel(clamped);
          if (mounted) setState(() => _currentZoom = clamped);
        } catch (e) {
          debugPrint('setZoomLevel($clamped) after switch failed: $e');
        }
      }
      return;
    }

    final clamped = requested.clamp(_minZoom, _maxZoom).toDouble();
    try {
      await controller.setZoomLevel(clamped);
      if (!mounted) return;
      setState(() => _currentZoom = clamped);
    } catch (e) {
      debugPrint('setZoomLevel($clamped) failed: $e');
    }
  }

  /// Wave 40.5 (M4) — swap the active camera controller to a different
  /// CameraDescription. Used for ultrawide <-> wide lens switching.
  Future<void> _switchToCamera(
    CameraDescription camera, {
    required bool isUltrawide,
  }) async {
    if (_isRecording) return; // never switch mid-recording
    final current = _cameraController;
    setState(() {
      _isCameraInitialized = false;
      _cameraController = null;
    });
    await current?.dispose();

    // Update the active camera index to match
    final idx = _cameras.indexOf(camera);
    if (idx >= 0) _activeCameraIndex = idx;

    _isOnUltrawide = isUltrawide;
    await _attachController(camera);
    // On ultrawide, set zoom to 1.0 (which is the ultrawide's native FOV,
    // equivalent to 0.5x on the main wide lens).
    if (isUltrawide && mounted) {
      setState(() => _currentZoom = 0.5);
    }
  }

  /// Wave 40.4 (M5.2) — pinch debounce / coalesce. Pinch updates fire
  /// at ~60 Hz; without coalescing we'd queue dozens of `setZoomLevel`
  /// futures, swamping the camera plugin and visibly stalling the
  /// preview. We track an in-flight call and the most recent target;
  /// if a call is in flight we just record the new target and let the
  /// completer kick off a follow-up that targets the LATEST value.
  bool _zoomInFlight = false;
  double? _pendingZoomTarget;

  Future<void> _applyZoomCoalesced(double requested) async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;
    final clamped = requested.clamp(_minZoom, _maxZoom).toDouble();
    if (_zoomInFlight) {
      _pendingZoomTarget = clamped;
      return;
    }
    _zoomInFlight = true;
    try {
      await controller.setZoomLevel(clamped);
      if (!mounted) return;
      setState(() => _currentZoom = clamped);
    } catch (e) {
      debugPrint('setZoomLevel($clamped) failed: $e');
    } finally {
      _zoomInFlight = false;
      // Drain the most recent pending target, if any.
      if (_pendingZoomTarget != null && mounted) {
        final next = _pendingZoomTarget!;
        _pendingZoomTarget = null;
        unawaited(_applyZoomCoalesced(next));
      }
    }
  }

  void _onPinchStart(ScaleStartDetails _) {
    _pinchBaseZoom = _currentZoom;
  }

  void _onPinchUpdate(ScaleUpdateDetails details) {
    // Scale relative to the zoom we had when the pinch began.
    // Only react to genuine scale changes (two-finger pinches) — a
    // single-finger drag reports `scale == 1.0` constantly and
    // `pointerCount == 1`. Without this guard we'd reset zoom to the
    // base on every drag-related ScaleUpdate.
    if (details.pointerCount < 2) return;
    final target = _pinchBaseZoom * details.scale;
    // Wave 40.5 (M4) — detect pinch crossing the 0.5/1.0 boundary
    // for ultrawide <-> wide camera swap.
    if (_isOnUltrawide && target >= 1.0 && _backWideCamera != null) {
      _applyZoom(target); // will swap back to wide
      return;
    }
    if (!_isOnUltrawide && target < 0.7 && _backUltrawideCamera != null) {
      _applyZoom(0.5); // will swap to ultrawide
      return;
    }
    _applyZoomCoalesced(target);
  }

  // ---------------------------------------------------------------------------
  // Capture
  // ---------------------------------------------------------------------------

  Future<void> _capturePhoto() async {
    if (_cameraController == null ||
        !_cameraController!.value.isInitialized ||
        _isRecording) {
      return;
    }

    try {
      HomefitHaptics.medium();
      final xFile = await _cameraController!.takePicture();
      final exercise = await _persistCapture(xFile.path, MediaType.photo);
      if (exercise != null) {
        _onCaptureLanded(exercise);
      }
    } catch (e) {
      // Silent failure — the count not incrementing is the signal.
      debugPrint('Photo capture failed: $e');
    }
  }

  /// Called when the user's finger touches down on the shutter for a
  /// potential long-press.
  ///
  /// Wave 40.4 (M4) — fire a `selectionClick` haptic immediately on
  /// touch-down so the practitioner gets instant tactile confirmation
  /// the shutter received the press. Carl's QA: "I have no haptic
  /// firing even when I press and hold the camera button." iOS won't
  /// recognise the long-press for ~500ms, so without an
  /// on-touch-down haptic the shutter feels dead until video starts.
  void _onShutterPressDown() {
    if (_isRecording) return;
    _longPressActive = true;
    _pendingStopAfterStart = false;
    _hoveringLockTarget = false;
    HomefitHaptics.selection();
  }

  /// Called on both `onLongPressEnd` (normal release) and the raw
  /// pointer-up / cancel safety net. Idempotent — the first call does
  /// the stop, subsequent calls for the same release are no-ops.
  ///
  /// Wave 40 (M4) — if the finger is hovering over the lock target at
  /// the moment of release, snap into hands-free locked recording
  /// instead of stopping. While locked: subsequent releases do
  /// nothing; only a tap on the morphed (white-square) shutter inner
  /// triggers stop. Below the lock target (i.e. user dragged up,
  /// changed mind, dragged back down), release stops as normal.
  void _onShutterReleased() {
    // If we're already locked into hands-free recording, ignore any
    // stray release events (the finger has been off the shutter for a
    // while; we keep recording until the practitioner explicitly taps
    // stop).
    if (_isLocked) {
      _longPressActive = false;
      return;
    }

    if (!_longPressActive && !_isRecording) return;
    _longPressActive = false;

    // Wave 40 (M4) — if the finger released over the lock target,
    // snap to locked hands-free recording. Recording continues, the
    // shutter inner morphs to a white square, and the lock target
    // turns coral. Subsequent stop is via tap on the morphed shutter.
    if (_isRecording && _hoveringLockTarget && !_stopInFlight) {
      _snapToLockedRecording();
      _hoveringLockTarget = false;
      return;
    }

    if (_isRecording && !_stopInFlight) {
      _stopInFlight = true;
      _stopVideoRecording();
    } else if (!_isRecording) {
      // The user released before the async start completed — flag it
      // so the start handler can immediately stop as soon as the
      // controller confirms it started.
      _pendingStopAfterStart = true;
    }
  }

  /// Wave 40 (M4) — snap the active recording into hands-free locked
  /// mode. Haptic confirmation; setState flips the visuals (lock
  /// target turns coral, shutter inner morphs to white square,
  /// hint copy swaps).
  void _snapToLockedRecording() {
    HomefitHaptics.heavy(); // best-effort; suppressed during mic use
    setState(() => _isLocked = true);
  }

  /// Wave 40 (M4) — translates a pointer-move event inside the
  /// shutter zone into upward drag-distance and updates
  /// [_hoveringLockTarget]. Only fires while the long-press is
  /// active and recording is in flight.
  ///
  /// Wave 40.4 (M3) — geometry pushed further out:
  ///   * Lock-target centre sits 192pt above the screen bottom
  ///     (was 160pt). Shutter centre sits at ~68pt → centre-to-centre
  ///     gap is ~124pt. With the 28pt shutter-bottom inset + 84pt
  ///     shutter the upper edge is at 112pt; lock-target lower edge
  ///     is at 192-28=164pt — a comfortable 52pt of empty corridor.
  ///   * Threshold pushed to ~95pt upward travel (was 60pt) — roughly
  ///     70% of the way to the target's centre, far enough to demand
  ///     a deliberate reach. No accidental triggers from pointer
  ///     jitter at the start of a long-press.
  ///   * Light-impact haptics fire on enter AND exit of the armed
  ///     zone so the practitioner feels the threshold both ways
  ///     ("I'm here, I can release" / "I left, I'd better drag back
  ///     up before letting go").
  void _onShutterPointerMove(PointerMoveEvent event) {
    if (!_longPressActive || _isLocked) return;
    // localPosition is relative to the Listener (the 84x84 shutter
    // zone). dy=42 is the centre; dragging up makes dy < 0 relative
    // to the centre. Distance dragged upward from the shutter centre
    // (positive when the finger is ABOVE centre).
    final dy = event.localPosition.dy;
    final upward = 42.0 - dy;
    final next = upward >= 95;
    if (next != _hoveringLockTarget) {
      // Tactile threshold cue — fires on both enter and exit so the
      // armed-zone boundary is unmistakable.
      HomefitHaptics.light();
      setState(() => _hoveringLockTarget = next);
    }
  }

  Future<void> _startVideoRecording() async {
    if (_cameraController == null ||
        !_cameraController!.value.isInitialized ||
        _isRecording) {
      return;
    }

    // Best-effort haptic — iOS suppresses vibration while AVCaptureSession
    // holds the mic (hardware-level, no workaround). Fires on the first
    // interaction before the mic is fully claimed; silent after that.
    // Visual feedback (pulsing red dot, lock-target animation) is the
    // primary recording cue. See CLAUDE.md iOS limitation note.
    HomefitHaptics.heavy();

    // Snapshot orientation at the first frame and lock the surface to
    // it. AVFoundation embeds `videoOrientation` once at recording
    // start; allowing the device to rotate mid-clip produces a clip
    // with a single transform that no longer matches the latter half
    // of the frames. Locking is the standard pattern.
    final isPortrait = MediaQuery.orientationOf(context) == Orientation.portrait;
    final lockedSet = isPortrait
        ? const {DeviceOrientation.portraitUp}
        : const {
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          };

    try {
      await _cameraController!.startVideoRecording();
      if (!mounted) return;
      setState(() {
        _isRecording = true;
        _recordingSeconds = 0;
        _allowedOrientations = lockedSet;
      });
      // Wave 40 (M4) — fade in the lock target + drag track.
      _lockTargetController.forward(from: 0);

      // If the user already released during the async start, honour
      // that release now. The tick timer has NOT been started yet, so
      // there's nothing to cancel before the stop haptic fires.
      if (_pendingStopAfterStart) {
        _pendingStopAfterStart = false;
        await _stopVideoRecording();
        return;
      }

      // Per-second haptic tick. Fires IMMEDIATELY once we've confirmed
      // (a) the controller started recording, (b) `_isRecording = true`,
      // and (c) the release didn't already land during the async start.
      //
      // Wave 40.4 (M4) — upgraded from `mediumImpact` to `heavyImpact`.
      // Carl's device QA on Wave 40 reported NO per-second haptic was
      // perceptible during recording. iOS suppresses softer haptics
      // while the mic is hot (audio contamination guard); even
      // mediumImpact apparently falls below the threshold on some
      // hardware/build combos. Heavy is the next step up — coarser but
      // unmistakably felt. Debug prints confirm via console that the
      // timer actually fires and hasn't been cancelled early.
      _recordingTickTimer =
          Timer.periodic(const Duration(seconds: 1), (timer) {
        debugPrint(
            'haptic tick t=${DateTime.now().toIso8601String()}');
        if (!mounted) {
          timer.cancel();
          return;
        }
        setState(() => _recordingSeconds++);
        HomefitHaptics.heavy();
        if (_recordingSeconds >= AppConfig.maxVideoSeconds) {
          _stopVideoRecording(autoStopped: true);
        }
      });
      debugPrint('recording tick timer started');
    } catch (e) {
      debugPrint('Video recording start failed: $e');
      _pendingStopAfterStart = false;
      if (mounted) {
        setState(() {
          _allowedOrientations = _kCameraDefaultOrientations;
        });
      }
    }
  }

  Future<void> _stopVideoRecording({bool autoStopped = false}) async {
    // Belt-and-braces: _onShutterReleased also guards, but the
    // auto-stop timer path doesn't go through there.
    _stopInFlight = true;
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) {
      _stopInFlight = false;
      if (mounted) {
        setState(() {
          _isRecording = false;
          _isLocked = false;
          _hoveringLockTarget = false;
          _recordingSeconds = 0;
          _allowedOrientations = _kCameraDefaultOrientations;
        });
        _lockTargetController.reverse();
      }
      return;
    }

    // Defer to the underlying controller's own recording state, not
    // just our `_isRecording` flag. This closes a race where
    // `onLongPressEnd` can fire after the controller has started
    // writing but before our setState has landed.
    final controllerRecording = controller.value.isRecordingVideo;
    if (!_isRecording && !controllerRecording) {
      _stopInFlight = false;
      if (mounted) {
        setState(() {
          _isRecording = false;
          _isLocked = false;
          _hoveringLockTarget = false;
          _recordingSeconds = 0;
          _allowedOrientations = _kCameraDefaultOrientations;
        });
        _lockTargetController.reverse();
      }
      return;
    }

    // Cancel the tick timer BEFORE any further haptics so the
    // per-second tick can't overlap with the forthcoming stop haptic.
    if (_recordingTickTimer != null) {
      debugPrint('recording tick timer cancelled (stop)');
    }
    _recordingTickTimer?.cancel();
    _recordingTickTimer = null;

    try {
      final xFile = await controller.stopVideoRecording();
      _stopInFlight = false;
      if (!mounted) return;
      setState(() {
        _isRecording = false;
        _isLocked = false;
        _hoveringLockTarget = false;
        _recordingSeconds = 0;
        _allowedOrientations = _kCameraDefaultOrientations;
      });
      _lockTargetController.reverse();

      // Haptic confirmation:
      // - user-initiated stop: single light tap
      // - auto-stopped at max: double heavy tap ~120ms apart so the bio
      //   unmistakably knows the app stopped them.
      if (autoStopped) {
        HomefitHaptics.heavy();
        await Future.delayed(const Duration(milliseconds: 120));
        HomefitHaptics.heavy();
      } else {
        HomefitHaptics.light();
      }

      final exercise = await _persistCapture(xFile.path, MediaType.video);
      if (exercise != null) {
        _onCaptureLanded(exercise);
      }
    } catch (e) {
      debugPrint('Video recording stop failed: $e');
      _stopInFlight = false;
      if (mounted) {
        setState(() {
          _isRecording = false;
          _isLocked = false;
          _hoveringLockTarget = false;
          _recordingSeconds = 0;
          _allowedOrientations = _kCameraDefaultOrientations;
        });
        _lockTargetController.reverse();
      }
      // Silent: the count simply doesn't go up.
    }
  }

  /// Copy [sourcePath] into the app's raw directory, build an
  /// [ExerciseCapture], save it, and queue it for line-drawing conversion.
  /// Returns the exercise on success, null on failure.
  Future<ExerciseCapture?> _persistCapture(
    String sourcePath,
    MediaType type,
  ) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final rawDir = Directory(p.join(dir.path, 'raw'));
      await rawDir.create(recursive: true);

      final ext = p.extension(sourcePath);
      final destPath = p.join(
        rawDir.path,
        '${DateTime.now().millisecondsSinceEpoch}$ext',
      );
      await File(sourcePath).copy(destPath);

      var exercise = ExerciseCapture.create(
        position: widget.session.exercises.length + _newCapturesSoFar(),
        rawFilePath: PathResolver.toRelative(destPath),
        mediaType: type,
        sessionId: widget.session.id,
      );

      // Sticky per-client defaults (Milestone R / Wave 8). Forward-only
      // pre-fill — pull the client's most-recent-edit map from the
      // offline cache and seed the seven sticky fields. Cache miss (no
      // client_id, or client not yet synced) simply leaves the capture
      // with the default nulls so StudioDefaults apply.
      //
      // Wave 39 — merge the SQLite-cached snapshot with [StickyDefaults]'
      // in-memory overlay so a rapid edit-then-capture sequence sees the
      // override even if the SQLite write hasn't flushed yet. The overlay
      // wins per-field; SQLite stays the canonical store.
      final clientId = widget.session.clientId;
      if (clientId != null && clientId.isNotEmpty) {
        final cached =
            await SyncService.instance.storage.getCachedClientById(clientId);
        StickyDefaults.primeFromSnapshot(
          clientId,
          cached?.clientExerciseDefaults ?? const <String, dynamic>{},
        );
        final effective = StickyDefaults.effectiveDefaults(
          clientId: clientId,
          cachedDefaults:
              cached?.clientExerciseDefaults ?? const <String, dynamic>{},
        );
        if (effective.isNotEmpty) {
          exercise = StickyDefaults.prefillCapture(exercise, effective);
        }
      }

      await widget.storage.saveExercise(exercise);
      ConversionService.instance.queueConversion(exercise);
      return exercise;
    } catch (e) {
      debugPrint('persistCapture failed: $e');
      return null;
    }
  }

  /// Wave 40 (M2) — open the iOS multi-select photo picker. For each
  /// picked photo we fire the SAME pipeline as a captured photo:
  /// `_persistCapture` writes the file into `raw/`, builds an
  /// `ExerciseCapture`, queues it for line-drawing conversion, then
  /// `_onCaptureLanded` plays the peek-box animation and bumps the
  /// counter. The `await` between each picked file gives the peek-box
  /// animation a moment to play one-per-import — this is intentional
  /// per the brief: "no batched silent ingest".
  ///
  /// Failures are silent — the count simply doesn't increment for the
  /// failed file. Cancel (no selection) is a no-op.
  Future<void> _importFromLibrary() async {
    if (_isRecording) return;
    HomefitHaptics.selection();
    try {
      final picked = await _picker.pickMultipleMedia();
      if (picked.isEmpty) return;
      for (final xfile in picked) {
        final type = _detectMediaType(xfile.path);
        final exercise = await _persistCapture(xfile.path, type);
        if (exercise != null && mounted) {
          _onCaptureLanded(exercise);
          // A short stagger so the peek-box animation visibly fires
          // for each picked file. The fly animation is 420ms; we
          // wait ~280ms so the next photo's animation overlaps the
          // tail of the previous one without the user perceiving it
          // as a single batch swoosh.
          await Future.delayed(const Duration(milliseconds: 280));
        }
      }
    } catch (e) {
      debugPrint('Library import failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Import failed: $e')),
        );
      }
    }
  }

  /// Detect media type from file extension. Mirrors the helper in
  /// `studio_mode_screen.dart` so library imports flow through the
  /// same pipeline either way.
  MediaType _detectMediaType(String path) {
    final ext = p.extension(path).toLowerCase();
    const videoExts = {'.mov', '.mp4', '.m4v', '.qt', '.avi'};
    return videoExts.contains(ext) ? MediaType.video : MediaType.photo;
  }

  /// How many captures we've added locally beyond widget.session.exercises —
  /// used so the position for a freshly-captured-but-not-yet-refreshed
  /// exercise is unique.
  int _newCapturesSoFar() {
    final parentCount = widget.session.exercises.length;
    final delta = _captureCount - parentCount;
    return delta < 0 ? 0 : delta;
  }

  void _onCaptureLanded(ExerciseCapture exercise) {
    setState(() {
      _lastCapture = exercise;
      _captureCount++;
    });
    _flyController.forward(from: 0);
    // Ask parent to refresh the session from storage so Studio sees the
    // new exercise too. Non-blocking.
    unawaited(widget.onCapturesChanged());
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  IconData _flashIcon() {
    switch (_flashMode) {
      case FlashMode.off:
        return Icons.flash_off;
      case FlashMode.auto:
        return Icons.flash_auto;
      case FlashMode.always:
        return Icons.flash_on;
      case FlashMode.torch:
        return Icons.highlight;
    }
  }

  @override
  Widget build(BuildContext context) {
    return OrientationLockGuard(
      allowed: _allowedOrientations,
      child: Container(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _buildCameraPreview(),

          // Top bar overlay — session name + corner controls
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: _buildTopBar(),
            ),
          ),

          // Recording overlay (pulsing dot + countdown) — top of viewfinder
          if (_isRecording)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: _buildRecordingOverlay(),
              ),
            ),

          // Peek capture box — left edge, mid-height
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child: Center(child: _buildPeekBox()),
          ),

          // Wave 40 (M5) — vertical lens stack on the right edge.
          // 44x44pt pills, 8pt gap, vertically centred. Hidden during
          // recording (mid-clip lens switch causes visible jumps in
          // the output) and on devices with no optical variety.
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            child: Center(child: _buildLensColumn()),
          ),

          // Left-edge pull-tab back to Studio — shared chunky pill.
          Positioned.fill(
            child: ShellPullTab(
              side: ShellPullTabSide.left,
              onActivate: widget.onExitToStudio,
            ),
          ),

          // Wave 40 (M2) — bottom-left library import button. 44x44pt
          // round, translucent black, photo-stack glyph. Sits well
          // below the peek box (which is mid-left).
          Positioned(
            left: 16,
            bottom: 36,
            child: SafeArea(
              top: false,
              child: _buildLibraryImportButton(),
            ),
          ),

          // Wave 40 (M4) — lock-target overlay + drag track. Both fade
          // in 200ms after recording starts. Lock target sits 80pt
          // above the shutter centre; drag track is the corridor
          // between them. Hit-testing is disabled on these so the
          // shutter's gesture detector receives the move events for
          // the upward drag detection.
          if (_isRecording || _lockTargetController.value > 0)
            Positioned.fill(
              child: IgnorePointer(
                child: _buildLockTargetOverlay(),
              ),
            ),

          // Shutter — bottom centre. Lens row is now on the right
          // edge so the shutter has a clean vertical corridor for the
          // slide-up-to-lock gesture (M4).
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              top: false,
              child: _buildShutter(),
            ),
          ),

          // Screen-edge coral glow while finger is in the armed zone.
          // Tells the practitioner "you're in the target — release to lock."
          // Disappears the instant the finger leaves the zone.
          if (_hoveringLockTarget)
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedOpacity(
                  opacity: 1.0,
                  duration: const Duration(milliseconds: 150),
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: const Color(0xFFFF6B35).withValues(alpha: 0.8),
                        width: 4,
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      ),
    );
  }

  Widget _buildCameraPreview() {
    if (!_isCameraInitialized || _cameraController == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Colors.white38),
            SizedBox(height: 16),
            Text('Starting camera...',
                style: TextStyle(color: Colors.white38)),
          ],
        ),
      );
    }

    // Pinch-to-zoom lives on the preview itself so the whole viewfinder
    // is a zoom surface — but we keep shutter / peek / top controls
    // outside this GestureDetector so they retain their own hit-testing.
    //
    // BoxFit.contain with black letterboxing shows the full sensor
    // frame. Carl's "zoomed in" report was the previous BoxFit.cover
    // cropping the long edge of the frame.
    //
    // The `camera` plugin reports `previewSize` in the sensor's native
    // landscape coordinates (e.g. 1920x1080). In portrait we have to
    // swap width/height so the FittedBox lays the frame out as a
    // portrait box; in landscape we pass the dimensions through
    // unswapped. The previous always-swap math inverted the moment the
    // device rotated — that was Carl's "weirdly warps into portrait."
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onScaleStart: _onPinchStart,
      onScaleUpdate: _onPinchUpdate,
      child: ClipRect(
        child: OrientationBuilder(
          builder: (context, orientation) {
            final size = _cameraController!.value.previewSize;
            final sensorW = size?.width ?? 0;
            final sensorH = size?.height ?? 0;
            final isPortrait = orientation == Orientation.portrait;
            return FittedBox(
              fit: BoxFit.contain,
              child: SizedBox(
                width: isPortrait ? sensorH : sensorW,
                height: isPortrait ? sensorW : sensorH,
                child: CameraPreview(_cameraController!),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Exit button — slides back to Studio
          _roundIconButton(
            icon: Icons.close,
            onTap: widget.onExitToStudio,
            tooltip: 'Exit to Studio',
          ),

          // Session name — muted, non-tappable, display only
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                widget.session.clientName,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.2,
                  shadows: [
                    Shadow(
                      color: Colors.black54,
                      blurRadius: 4,
                      offset: Offset(0, 1),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Flash toggle
          _roundIconButton(
            icon: _flashIcon(),
            onTap: _cycleFlash,
            tooltip: 'Flash',
          ),
          const SizedBox(width: 4),
          // Flip camera
          _roundIconButton(
            icon: Icons.cameraswitch_outlined,
            onTap: _flipCamera,
            tooltip: 'Flip camera',
          ),
        ],
      ),
    );
  }

  Widget _roundIconButton({
    required IconData icon,
    required VoidCallback onTap,
    String? tooltip,
  }) {
    final button = Material(
      color: Colors.black45,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(icon, size: 20, color: Colors.white),
        ),
      ),
    );
    return tooltip == null
        ? button
        : Tooltip(message: tooltip, child: button);
  }

  Widget _buildRecordingOverlay() {
    final remaining =
        (AppConfig.maxVideoSeconds - _recordingSeconds).clamp(0, 999);
    return Padding(
      padding: const EdgeInsets.only(top: 44, left: 16, right: 16),
      child: Row(
        children: [
          const _PulsingDot(),
          const Spacer(),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              _formatMmSs(remaining),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.w700,
                fontFeatures: [FontFeature.tabularFigures()],
                letterSpacing: 0.5,
              ),
            ),
          ),
          const Spacer(),
          const SizedBox(width: 24), // balance against the dot
        ],
      ),
    );
  }

  String _formatMmSs(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Widget _buildPeekBox() {
    const boxSize = 72.0;
    final hasCapture = _lastCapture != null;

    // Slide-in/scale animation for a fresh capture.
    return AnimatedBuilder(
      animation: _flyController,
      builder: (context, child) {
        final t = _flyController.value;
        // Ease-out scale: start at 1.3 and settle to 1.0
        final scale = t == 0 ? 1.0 : 1.0 + (1.0 - Curves.easeOut.transform(t)) * 0.3;
        return Transform.translate(
          // Start slightly right (toward shutter) and settle into box.
          offset: Offset(t == 0 ? 0 : (1 - Curves.easeOut.transform(t)) * 40, 0),
          child: Opacity(
            opacity: hasCapture ? 1.0 : 0.45,
            child: Transform.scale(scale: scale, child: child),
          ),
        );
      },
      child: Padding(
        padding: const EdgeInsets.only(left: 12),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: boxSize,
              height: boxSize,
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: AppColors.primary,
                  width: 2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.4),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: hasCapture
                  // `showConversionOverlay: false` — the perpetual
                  // spinner was anxiety-inducing mid-session. The
                  // thumbnail already shows the raw frame while
                  // conversion runs and silently swaps to the line-
                  // drawing version once ready (via displayFilePath).
                  // No spinner, no animation on the swap.
                  ? Padding(
                      padding: const EdgeInsets.all(2),
                      child: CaptureThumbnail(
                        exercise: _lastCapture!,
                        size: boxSize - 4,
                        showConversionOverlay: false,
                      ),
                    )
                  : const Center(
                      child: Icon(
                        Icons.photo_camera_outlined,
                        color: Colors.white30,
                        size: 28,
                      ),
                    ),
            ),
            if (_captureCount > 0)
              Positioned(
                top: -6,
                right: -6,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.black, width: 1),
                  ),
                  constraints: const BoxConstraints(minWidth: 20),
                  child: Text(
                    '$_captureCount',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Wave 40 (M5) — vertical column of lens-switch pills on the right
  /// edge of the viewfinder. 44x44pt pills, 8pt gap, vertically
  /// centred. Active pill inverts (white background, black text) for
  /// the iPhone Camera-app feel; inactive pills are translucent
  /// black with a hairline border.
  ///
  /// Hidden when the back camera has no optical variety (just a single
  /// wide lens) or while recording (mid-clip lens switch causes
  /// visible jumps in the output).
  Widget _buildLensColumn() {
    final isBack = _cameras.isNotEmpty &&
        _activeCameraIndex < _cameras.length &&
        _cameras[_activeCameraIndex].lensDirection ==
            CameraLensDirection.back;
    if (!isBack || _availableLenses.length <= 1 || _isRecording) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < _availableLenses.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            _buildLensPill(_availableLenses[i]),
          ],
        ],
      ),
    );
  }

  Widget _buildLensPill(double lens) {
    // "Active" when current zoom is within ~15% of this lens value.
    // For the 0.5x pill, also check if we're on the ultrawide camera.
    final active = lens == 0.5
        ? _isOnUltrawide
        : (!_isOnUltrawide && (_currentZoom - lens).abs() <= lens * 0.15);
    // Wave 40 (M5) — active inverts to white-on-black instead of the
    // coral-on-white the row used. Mirrors iPhone Camera's active-lens
    // pill so the affordance reads as "current selection" without
    // borrowing the workflow accent.
    final bg = active
        ? Colors.white.withValues(alpha: 0.85)
        : Colors.black.withValues(alpha: 0.55);
    final fg = active ? Colors.black : Colors.white;
    final label = lens == lens.roundToDouble()
        ? '${lens.toInt()}×'
        : lens.toStringAsFixed(1).replaceAll(RegExp(r'\.?0+$'), '');
    return Material(
      color: bg,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => _applyZoom(lens),
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: active
                  ? Colors.transparent
                  : Colors.white.withValues(alpha: 0.12),
              width: 1,
            ),
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                color: fg,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Wave 40 (M2) — bottom-left library import button. 44x44pt round,
  /// translucent black, white photo-stack glyph. Tap opens the iOS
  /// multi-select photo picker; each picked file flows through the
  /// SAME `_persistCapture` path as a captured photo.
  Widget _buildLibraryImportButton() {
    return Material(
      color: Colors.black.withValues(alpha: 0.5),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: _isRecording ? null : _importFromLibrary,
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.12),
              width: 1,
            ),
          ),
          child: const Icon(
            Icons.photo_library_outlined,
            color: Colors.white,
            size: 22,
          ),
        ),
      ),
    );
  }

  /// Wave 40 (M4) — lock-target overlay shown while recording. Fades
  /// in 200ms when recording starts, and turns coral when the user
  /// has snapped into locked hands-free mode.
  ///
  /// Wave 40.4 (M3) polish:
  ///   * Lock target pushed from 132pt to 164pt above the safe-area
  ///     bottom (centre at 192pt) so the practitioner has to
  ///     deliberately reach for it. Drag-track stretches accordingly.
  ///   * Armed-state visuals upgraded:
  ///       - scale 1.0 → 1.15 over 120ms via AnimatedScale
  ///       - background tint deepened from 55% → 75% coral alpha
  ///       - "Release to lock" caption fades in below the chip at
  ///         55% white opacity, 10.5pt Inter (matches the M3 hint
  ///         caption register).
  ///
  /// Hit-testing on this overlay is disabled by the parent
  /// `IgnorePointer` so pointer events go through to the shutter
  /// gesture detector for the upward-drag detection.
  Widget _buildLockTargetOverlay() {
    return AnimatedBuilder(
      animation: _lockTargetController,
      builder: (context, _) {
        final t = _lockTargetController.value;
        if (t == 0) return const SizedBox.shrink();
        // Lock target sits centred horizontally, 164pt above the
        // bottom of the safe area (centre at 192pt; chip is 56pt
        // tall). Drag track lives in the gap between shutter
        // (28pt + 84pt = 112pt above bottom) and the lock-target
        // bottom (164pt) — a 52pt gap, so the track is 56pt to
        // overlap both edges.
        final hovering = _hoveringLockTarget;
        final lockBg = _isLocked
            ? AppColors.primary
            : (hovering
                ? AppColors.primary.withValues(alpha: 0.75)
                : Colors.black.withValues(alpha: 0.55));
        final lockBorder = _isLocked || hovering
            ? AppColors.primary
            : Colors.white.withValues(alpha: 0.18);
        final showReleaseHint = hovering && !_isLocked;
        return SafeArea(
          top: false,
          child: Stack(
            alignment: Alignment.bottomCenter,
            children: [
              // Drag track between shutter and lock target.
              Positioned(
                bottom: 112,
                child: Opacity(
                  opacity: t,
                  child: Container(
                    width: 4,
                    height: 56,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(2),
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [
                          Colors.white.withValues(alpha: 0.4),
                          Colors.white.withValues(alpha: 0.1),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              // "Release to lock" caption — appears just under the
              // lock chip while armed (and not yet snapped). Stays
              // beneath the chip's bottom edge (~164pt) at 144pt
              // bottom so it doesn't crowd the chip.
              Positioned(
                bottom: 144,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 120),
                  opacity: showReleaseHint ? t : 0.0,
                  child: Text(
                    'Release to lock',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 10.5,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.2,
                      color: Colors.white.withValues(alpha: 0.55),
                      shadows: const [
                        Shadow(
                          color: Colors.black54,
                          blurRadius: 4,
                          offset: Offset(0, 1),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // Lock target round chip.
              Positioned(
                bottom: 164,
                child: Opacity(
                  opacity: t,
                  child: AnimatedScale(
                    duration: const Duration(milliseconds: 120),
                    curve: Curves.easeOutCubic,
                    scale: hovering && !_isLocked ? 1.15 : 1.0,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: lockBg,
                        border: Border.all(color: lockBorder, width: 1),
                      ),
                      child: const Icon(
                        Icons.lock_outline_rounded,
                        color: Colors.white,
                        size: 22,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildShutter() {
    // Layered gesture handling — Wave 8 background:
    //
    //  * `Listener` catches raw pointer up / cancel events. If the
    //    GestureDetector's long-press recognizer cedes to another
    //    recognizer in the arena (e.g. an accidental scale gesture
    //    from finger jitter) the pointer events still fire — so we'll
    //    still stop the recording on finger-up.
    //  * `GestureDetector` handles the semantic tap / long-press on
    //    top of that.
    //
    // `HitTestBehavior.opaque` on both ensures the full bounding box
    // receives pointer events — the previous `deferToChild` (default)
    // meant transparent corners around the circular button dropped
    // touches.
    //
    // Wave 40 (M4) layered on top: the Listener also tracks
    // `onPointerMove` so we can compute upward drag-delta and detect
    // the "finger over lock target" condition for the slide-up-to-
    // lock gesture. While `_isLocked`, the shutter is in stop mode —
    // a single tap on the morphed (white-square) inner triggers
    // `_stopVideoRecording()`.
    final hint = _isLocked
        ? 'Tap ⬛ to stop'
        : (_isRecording
            ? 'Slide finger ↑ onto \u{1F512} to lock'
            : 'Tap for photo · Hold for video · Slide ↑ to lock');
    return Padding(
      padding: const EdgeInsets.only(bottom: 24, top: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Listener(
                behavior: HitTestBehavior.opaque,
                onPointerMove: _onShutterPointerMove,
                onPointerUp: (_) => _onShutterReleased(),
                onPointerCancel: (_) => _onShutterReleased(),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  // Wave 40 (M4) — when locked, a tap on the shutter
                  // stops recording. Otherwise the tap captures a
                  // photo (only if not already recording).
                  onTap: _isLocked
                      ? () => _stopVideoRecording()
                      : (_isRecording ? null : _capturePhoto),
                  onLongPressDown:
                      _isLocked ? null : (_) => _onShutterPressDown(),
                  onLongPressStart:
                      _isLocked ? null : (_) => _startVideoRecording(),
                  onLongPressEnd:
                      _isLocked ? null : (_) => _onShutterReleased(),
                  onLongPressCancel: _isLocked ? null : _onShutterReleased,
                  child: _buildShutterButton(),
                ),
              ),
            ],
          ),
          // Wave 40 (M3) — permanent hint caption beneath the
          // shutter. Three states (idle / pressed-recording /
          // locked). 55% opacity, 10.5pt Inter. Replaces the old
          // auto-fading "Hold for video" two-liner.
          const SizedBox(height: 8),
          Text(
            hint,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 10.5,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.2,
              color: Colors.white.withValues(alpha: 0.55),
              shadows: const [
                Shadow(
                  color: Colors.black54,
                  blurRadius: 4,
                  offset: Offset(0, 1),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildShutterButton() {
    const size = 84.0;
    // Wave 40 (M4) — when locked, the inner morphs from the
    // recording-red rounded-square into a small WHITE square so the
    // affordance flips from "I'm recording, hold me" to "tap to stop".
    final innerColor = _isLocked
        ? Colors.white
        : (_isRecording ? AppColors.primary : Colors.white);
    final innerSize = _isLocked
        ? 28.0
        : (_isRecording ? 30.0 : 64.0);
    final innerRadius = _isLocked
        ? 4.0
        : (_isRecording ? 6.0 : 32.0);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Outer ring — shifts to a progress-style fill when recording
          if (_isRecording)
            SizedBox(
              width: size,
              height: size,
              child: CircularProgressIndicator(
                value: (_recordingSeconds / AppConfig.maxVideoSeconds)
                    .clamp(0.0, 1.0),
                strokeWidth: 5,
                color: AppColors.primary,
                backgroundColor: Colors.white24,
              ),
            ),
          Container(
            width: size - 8,
            height: size - 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 3),
            ),
          ),
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: innerSize,
            height: innerSize,
            decoration: BoxDecoration(
              color: innerColor,
              borderRadius: BorderRadius.circular(innerRadius),
            ),
          ),
        ],
      ),
    );
  }
}

/// Pulsing red dot shown in the top-left of the viewfinder during
/// recording.
///
/// The scale pulse is deliberately locked to a 1-second cycle so it
/// matches the per-second haptic tick — giving the bio a peripheral-
/// vision confirm that recording is alive even when haptics are
/// suppressed by the OS (e.g. iOS mutes softer haptics while the mic
/// is hot). Size stays the same on average; we just breathe the scale
/// between 1.0 and 1.2.
class _PulsingDot extends StatefulWidget {
  const _PulsingDot();

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat(reverse: true);
    _scale = Tween<double>(begin: 1.0, end: 1.2).animate(
      CurvedAnimation(parent: _c, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Keep the colour/glow pulse we had before (bios already learned
    // it as "recording is live"); overlay the scale pulse on top via
    // ScaleTransition for the peripheral-vision signal.
    return ScaleTransition(
      scale: _scale,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final t = _c.value;
          return Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: Color.lerp(
                const Color(0xFFEF4444),
                const Color(0xFFFCA5A5),
                t,
              ),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color:
                      const Color(0xFFEF4444).withValues(alpha: 0.4 + 0.3 * t),
                  blurRadius: 6 + 4 * t,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
