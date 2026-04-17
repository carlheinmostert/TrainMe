import 'dart:async';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../config.dart';
import '../models/exercise_capture.dart';
import '../models/session.dart';
import '../services/conversion_service.dart';
import '../services/local_storage_service.dart';
import '../services/path_resolver.dart';
import '../theme.dart';
import '../widgets/capture_thumbnail.dart';
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

class _CaptureModeScreenState extends State<CaptureModeScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  // --- Camera state ---
  CameraController? _cameraController;
  List<CameraDescription> _cameras = const [];
  int _activeCameraIndex = 0;
  bool _isCameraInitialized = false;
  FlashMode _flashMode = FlashMode.off;

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

  bool _wasRecordingOnBackground = false;
  Timer? _recordingTickTimer;
  int _recordingSeconds = 0;

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
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      if (_recordingTickTimer != null) {
        debugPrint('recording tick timer cancelled (lifecycle paused)');
      }
      _recordingTickTimer?.cancel();
      _recordingTickTimer = null;
      if (_isRecording) {
        _wasRecordingOnBackground = true;
      }
      setState(() {
        _isRecording = false;
        _longPressActive = false;
        _pendingStopAfterStart = false;
        _stopInFlight = false;
        _recordingSeconds = 0;
        _isCameraInitialized = false;
      });
      _cameraController?.dispose();
      _cameraController = null;
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
      if (_wasRecordingOnBackground && mounted) {
        _wasRecordingOnBackground = false;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Recording interrupted')),
        );
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Camera lifecycle
  // ---------------------------------------------------------------------------

  Future<void> _initCamera() async {
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
  /// controller reports. `1x` is always present (main wide). The rest
  /// are included only if they fall within [min, max].
  List<double> _buildLensListForRange(double minZoom, double maxZoom) {
    const candidates = [0.5, 1.0, 2.0, 3.0];
    final lenses = <double>[];
    for (final c in candidates) {
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
  /// and update state. Setting a value that corresponds to a different
  /// physical lens triggers iOS's virtual multi-camera device to switch
  /// under the hood, so this is both "physical lens switch" and "digital
  /// zoom" — same API, handled by the OS.
  Future<void> _applyZoom(double requested) async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;
    final clamped = requested.clamp(_minZoom, _maxZoom).toDouble();
    try {
      await controller.setZoomLevel(clamped);
      if (!mounted) return;
      setState(() => _currentZoom = clamped);
    } catch (e) {
      debugPrint('setZoomLevel($clamped) failed: $e');
    }
  }

  void _onPinchStart(ScaleStartDetails _) {
    _pinchBaseZoom = _currentZoom;
  }

  void _onPinchUpdate(ScaleUpdateDetails details) {
    // Scale relative to the zoom we had when the pinch began.
    final target = _pinchBaseZoom * details.scale;
    _applyZoom(target);
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
      HapticFeedback.mediumImpact();
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
  void _onShutterPressDown() {
    if (_isRecording) return;
    _longPressActive = true;
    _pendingStopAfterStart = false;
  }

  /// Called on both `onLongPressEnd` (normal release) and the raw
  /// pointer-up / cancel safety net. Idempotent — the first call does
  /// the stop, subsequent calls for the same release are no-ops.
  void _onShutterReleased() {
    if (!_longPressActive && !_isRecording) return;
    _longPressActive = false;
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

  Future<void> _startVideoRecording() async {
    if (_cameraController == null ||
        !_cameraController!.value.isInitialized ||
        _isRecording) {
      return;
    }

    // Fire the haptic BEFORE the await so the bio feels the press
    // immediately, even if the controller takes a moment to actually
    // start writing. Use heavy impact — Carl reported feeling nothing
    // with medium on his device.
    HapticFeedback.heavyImpact();

    try {
      await _cameraController!.startVideoRecording();
      if (!mounted) return;
      setState(() {
        _isRecording = true;
        _recordingSeconds = 0;
      });

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
      // Upgraded to `mediumImpact` — on-device testing showed `lightImpact`
      // was not perceptible during active video recording (iOS may suppress
      // softer haptics while the mic is hot to avoid audio contamination).
      // Debug prints confirm via console that the timer actually fires and
      // hasn't been cancelled early.
      _recordingTickTimer =
          Timer.periodic(const Duration(seconds: 1), (timer) {
        debugPrint(
            'haptic tick t=${DateTime.now().toIso8601String()}');
        if (!mounted) {
          timer.cancel();
          return;
        }
        setState(() => _recordingSeconds++);
        HapticFeedback.mediumImpact();
        if (_recordingSeconds >= AppConfig.maxVideoSeconds) {
          _stopVideoRecording(autoStopped: true);
        }
      });
      debugPrint('recording tick timer started');
    } catch (e) {
      debugPrint('Video recording start failed: $e');
      _pendingStopAfterStart = false;
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
          _recordingSeconds = 0;
        });
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
          _recordingSeconds = 0;
        });
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
        _recordingSeconds = 0;
      });

      // Haptic confirmation:
      // - user-initiated stop: single light tap
      // - auto-stopped at max: double light tap so the bio knows the app
      //   stopped them, they didn't accidentally release.
      if (autoStopped) {
        HapticFeedback.lightImpact();
        await Future.delayed(const Duration(milliseconds: 100));
        HapticFeedback.lightImpact();
      } else {
        HapticFeedback.lightImpact();
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
          _recordingSeconds = 0;
        });
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

      final exercise = ExerciseCapture.create(
        position: widget.session.exercises.length + _newCapturesSoFar(),
        rawFilePath: PathResolver.toRelative(destPath),
        mediaType: type,
        sessionId: widget.session.id,
      );

      await widget.storage.saveExercise(exercise);
      ConversionService.instance.queueConversion(exercise);
      return exercise;
    } catch (e) {
      debugPrint('persistCapture failed: $e');
      return null;
    }
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
    return Container(
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

          // Left-edge pull-tab back to Studio — shared chunky pill.
          Positioned.fill(
            child: ShellPullTab(
              side: ShellPullTabSide.left,
              onActivate: widget.onExitToStudio,
            ),
          ),

          // Shutter + lens-switch row — bottom centre. The lens row sits
          // ABOVE the shutter (inside the same SafeArea) so the two
          // bottom controls stay grouped.
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildLensRow(),
                  _buildShutter(),
                ],
              ),
            ),
          ),
        ],
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
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onScaleStart: _onPinchStart,
      onScaleUpdate: _onPinchUpdate,
      child: ClipRect(
        child: FittedBox(
          fit: BoxFit.contain,
          child: SizedBox(
            width: _cameraController!.value.previewSize?.height ?? 0,
            height: _cameraController!.value.previewSize?.width ?? 0,
            child: CameraPreview(_cameraController!),
          ),
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

  /// Small horizontal row of lens-switch pills, positioned ABOVE the
  /// shutter (not overlapping it). Only rear-lens selection — the flip
  /// (front/back) button stays in the top bar.
  ///
  /// Hidden when the back camera has no optical variety (just a single
  /// wide lens) or while recording (mid-clip lens switch causes visible
  /// jumps in the output).
  Widget _buildLensRow() {
    final isBack = _cameras.isNotEmpty &&
        _activeCameraIndex < _cameras.length &&
        _cameras[_activeCameraIndex].lensDirection ==
            CameraLensDirection.back;
    if (!isBack || _availableLenses.length <= 1 || _isRecording) {
      return const SizedBox(height: 8);
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12, top: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (final lens in _availableLenses)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: _buildLensPill(lens),
            ),
        ],
      ),
    );
  }

  Widget _buildLensPill(double lens) {
    // "Active" when current zoom is within ~15% of this lens value.
    // Keeps the highlight sensible as the user pinches smoothly across
    // the range — we don't want every pixel of pinch clearing the
    // highlight.
    final active = (_currentZoom - lens).abs() <= lens * 0.15;
    final bg = active ? AppColors.primary : Colors.black45;
    final fg = active ? Colors.white : Colors.white70;
    final label = lens == lens.roundToDouble()
        ? '${lens.toInt()}x'
        : '${lens.toStringAsFixed(1).replaceAll(RegExp(r'\.?0+$'), '')}x';

    return Material(
      color: bg,
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: () => _applyZoom(lens),
        child: Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
    );
  }

  Widget _buildShutter() {
    // Layered gesture handling — this is the fix for Carl's
    // release-gesture bug:
    //
    //  * `Listener` catches raw pointer up / cancel events. If the
    //    GestureDetector's long-press recognizer cedes to another
    //    recognizer in the arena (e.g. an accidental scale gesture
    //    from finger jitter) the pointer events still fire — so we'll
    //    still stop the recording on finger-up.
    //  * `GestureDetector` handles the semantic tap / long-press on
    //    top of that.
    //
    // `HitTestBehavior.opaque` on both ensures the full 84x84 bounding
    // box receives pointer events — the previous `deferToChild`
    // (default) meant transparent corners around the circular button
    // dropped touches, which is the most likely cause of releases
    // being missed on-device.
    return Padding(
      padding: const EdgeInsets.only(bottom: 24, top: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Listener(
            behavior: HitTestBehavior.opaque,
            onPointerUp: (_) => _onShutterReleased(),
            onPointerCancel: (_) => _onShutterReleased(),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _isRecording ? null : _capturePhoto,
              onLongPressDown: (_) => _onShutterPressDown(),
              onLongPressStart: (_) => _startVideoRecording(),
              onLongPressEnd: (_) => _onShutterReleased(),
              onLongPressCancel: _onShutterReleased,
              child: _buildShutterButton(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildShutterButton() {
    const size = 84.0;
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
            width: _isRecording ? 30 : 64,
            height: _isRecording ? 30 : 64,
            decoration: BoxDecoration(
              color: _isRecording ? AppColors.primary : Colors.white,
              borderRadius:
                  BorderRadius.circular(_isRecording ? 6 : 32),
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
