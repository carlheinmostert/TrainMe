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

/// In-session camera mode.
///
/// Full-screen camera preview with a single shutter (tap = photo,
/// long-press = video), top-corner controls (flip, flash, exit), a
/// subtle edge pull-tab hinting at Studio mode on the left, and a
/// peek-only capture box mid-left showing the last capture's thumbnail
/// and total count.
///
/// Video recording gets a pulsing red dot, a large 30-second countdown,
/// and per-second haptic ticks so the bio knows the recording is live
/// without staring at the screen.
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

  // --- Recording state ---
  bool _isRecording = false;
  bool _wasRecordingOnBackground = false;
  Timer? _recordingTimer;
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
    _recordingTimer?.cancel();
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
      _recordingTimer?.cancel();
      _recordingTimer = null;
      if (_isRecording) {
        _wasRecordingOnBackground = true;
      }
      setState(() {
        _isRecording = false;
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
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _cameraController = controller;
        _isCameraInitialized = true;
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

  Future<void> _startVideoRecording() async {
    if (_cameraController == null ||
        !_cameraController!.value.isInitialized ||
        _isRecording) {
      return;
    }

    try {
      await _cameraController!.startVideoRecording();
      HapticFeedback.mediumImpact();
      setState(() {
        _isRecording = true;
        _recordingSeconds = 0;
      });

      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted) {
          timer.cancel();
          return;
        }
        setState(() => _recordingSeconds++);
        // Per-second subtle tick while recording.
        HapticFeedback.selectionClick();
        if (_recordingSeconds >= AppConfig.maxVideoSeconds) {
          _stopVideoRecording(autoStopped: true);
        }
      });
    } catch (e) {
      debugPrint('Video recording start failed: $e');
    }
  }

  Future<void> _stopVideoRecording({bool autoStopped = false}) async {
    if (_cameraController == null ||
        !_cameraController!.value.isInitialized ||
        !_isRecording) {
      setState(() {
        _isRecording = false;
        _recordingSeconds = 0;
      });
      return;
    }
    _recordingTimer?.cancel();

    try {
      final xFile = await _cameraController!.stopVideoRecording();
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
      setState(() {
        _isRecording = false;
        _recordingSeconds = 0;
      });
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

          // Left-edge pull-tab back to Studio
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child: Center(child: _buildPullTab()),
          ),

          // Shutter — bottom centre
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              top: false,
              child: _buildShutter(),
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

    return ClipRect(
      child: OverflowBox(
        alignment: Alignment.center,
        child: FittedBox(
          fit: BoxFit.cover,
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
                  ? Padding(
                      padding: const EdgeInsets.all(2),
                      child: CaptureThumbnail(
                        exercise: _lastCapture!,
                        size: boxSize - 4,
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

  /// Subtle left-edge pull-tab that hints Studio is one swipe right.
  ///
  /// Sits just above the peek box at mid-screen, far enough below to
  /// not overlap. Tappable for discoverability.
  Widget _buildPullTab() {
    return IgnorePointer(
      // Only the visual pill is shown here; GestureDetector on the
      // actual pill handles the tap. Keep the parent non-intercepting
      // so camera preview taps pass through outside the pill.
      ignoring: false,
      child: Align(
        alignment: const Alignment(-1.0, -0.55),
        child: GestureDetector(
          onTap: widget.onExitToStudio,
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: 6,
            height: 64,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.65),
              borderRadius: const BorderRadius.only(
                topRight: Radius.circular(6),
                bottomRight: Radius.circular(6),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 4,
                  offset: const Offset(1, 0),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildShutter() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24, top: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          GestureDetector(
            onTap: _isRecording ? null : _capturePhoto,
            onLongPressStart: (_) => _startVideoRecording(),
            onLongPressEnd: (_) => _stopVideoRecording(),
            child: _buildShutterButton(),
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
class _PulsingDot extends StatefulWidget {
  const _PulsingDot();

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
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
                color: const Color(0xFFEF4444).withValues(alpha: 0.4 + 0.3 * t),
                blurRadius: 6 + 4 * t,
              ),
            ],
          ),
        );
      },
    );
  }
}
