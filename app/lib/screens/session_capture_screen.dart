import 'dart:async';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../models/exercise_capture.dart';
import '../models/session.dart';
import '../services/local_storage_service.dart';
import '../services/conversion_service.dart';
import '../widgets/capture_thumbnail.dart';
import 'plan_editor_screen.dart';

/// The camera capture screen — the core of the app.
///
/// Full-screen camera preview with a capture button, session strip at top,
/// and navigation to the plan editor. This is where the bio spends most
/// of her time during a client session.
///
/// Architecture: Layer 1 (Capture) of the three decoupled async layers.
/// Tap shutter -> raw file writes to disk -> thumbnail in UI -> camera ready.
/// Target: <200ms from tap to "ready for next capture."
class SessionCaptureScreen extends StatefulWidget {
  final Session session;
  final LocalStorageService storage;

  const SessionCaptureScreen({
    super.key,
    required this.session,
    required this.storage,
  });

  @override
  State<SessionCaptureScreen> createState() => _SessionCaptureScreenState();
}

class _SessionCaptureScreenState extends State<SessionCaptureScreen>
    with WidgetsBindingObserver {
  CameraController? _cameraController;
  late Session _session;
  late ConversionService _conversionService;
  StreamSubscription<ExerciseCapture>? _conversionSub;

  bool _isCameraInitialized = false;
  bool _isRecording = false;
  Timer? _recordingTimer;
  double _recordingProgress = 0.0; // 0.0 to 1.0
  int _recordingSeconds = 0;

  /// Maximum video recording duration in seconds.
  static const _maxRecordingSeconds = 30;

  /// Duration at which the progress ring turns amber.
  static const _amberThresholdSeconds = 15;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _session = widget.session;
    _conversionService = ConversionService(storage: widget.storage);
    _listenToConversions();
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _recordingTimer?.cancel();
    _conversionSub?.cancel();
    _conversionService.dispose();
    _cameraController?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Handle camera lifecycle — release when backgrounded, reinit when resumed
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }
    if (state == AppLifecycleState.inactive) {
      _cameraController?.dispose();
      _isCameraInitialized = false;
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  /// Listen for conversion updates and refresh the exercise list.
  void _listenToConversions() {
    _conversionSub = _conversionService.onConversionUpdate.listen((updated) {
      setState(() {
        final exercises = List<ExerciseCapture>.from(_session.exercises);
        final idx = exercises.indexWhere((e) => e.id == updated.id);
        if (idx >= 0) {
          exercises[idx] = updated;
          _session = _session.copyWith(exercises: exercises);
        }
      });
    });
  }

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      debugPrint('No cameras available');
      return;
    }

    // Prefer the rear camera
    final camera = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );

    _cameraController = CameraController(
      camera,
      ResolutionPreset.high,
      enableAudio: false, // Exercise demos don't need audio
    );

    try {
      await _cameraController!.initialize();
      if (mounted) {
        setState(() => _isCameraInitialized = true);
      }
    } catch (e) {
      debugPrint('Camera init failed: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Capture actions
  // ---------------------------------------------------------------------------

  /// Take a photo. This is the Layer 1 fast path:
  /// tap -> save to disk -> add thumbnail -> camera ready.
  Future<void> _capturePhoto() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }
    if (_isRecording) return; // Don't take photos while recording video

    try {
      final xFile = await _cameraController!.takePicture();

      // Move to app documents directory with a stable name
      final dir = await getApplicationDocumentsDirectory();
      final rawDir = Directory(p.join(dir.path, 'raw'));
      await rawDir.create(recursive: true);

      final position = _session.exercises.length;
      final exercise = ExerciseCapture.create(
        position: position,
        rawFilePath: xFile.path,
        mediaType: MediaType.photo,
        sessionId: _session.id,
      );

      // Persist immediately — crash safety
      await widget.storage.saveExercise(exercise);

      // Update local state
      setState(() {
        _session = _session.copyWith(
          exercises: [..._session.exercises, exercise],
        );
      });

      // Queue for background conversion (Layer 2)
      _conversionService.queueConversion(exercise);
    } catch (e) {
      debugPrint('Photo capture failed: $e');
    }
  }

  /// Start recording a video.
  Future<void> _startVideoRecording() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }
    if (_isRecording) return;

    try {
      await _cameraController!.startVideoRecording();
      setState(() {
        _isRecording = true;
        _recordingSeconds = 0;
        _recordingProgress = 0.0;
      });

      // Update progress ring every second
      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        _recordingSeconds++;
        setState(() {
          _recordingProgress = _recordingSeconds / _maxRecordingSeconds;
        });

        // Auto-stop at max duration
        if (_recordingSeconds >= _maxRecordingSeconds) {
          _stopVideoRecording();
        }
      });
    } catch (e) {
      debugPrint('Video recording start failed: $e');
    }
  }

  /// Stop recording and save the video.
  Future<void> _stopVideoRecording() async {
    if (!_isRecording) return;
    _recordingTimer?.cancel();

    try {
      final xFile = await _cameraController!.stopVideoRecording();

      setState(() {
        _isRecording = false;
        _recordingProgress = 0.0;
        _recordingSeconds = 0;
      });

      final position = _session.exercises.length;
      final exercise = ExerciseCapture.create(
        position: position,
        rawFilePath: xFile.path,
        mediaType: MediaType.video,
        sessionId: _session.id,
      );

      // Persist immediately
      await widget.storage.saveExercise(exercise);

      setState(() {
        _session = _session.copyWith(
          exercises: [..._session.exercises, exercise],
        );
      });

      // Queue for background conversion
      _conversionService.queueConversion(exercise);
    } catch (e) {
      debugPrint('Video recording stop failed: $e');
      setState(() {
        _isRecording = false;
        _recordingProgress = 0.0;
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Navigation
  // ---------------------------------------------------------------------------

  /// Proceed to the plan editor.
  void _goToEditor() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => PlanEditorScreen(
          session: _session,
          storage: widget.storage,
        ),
      ),
    );
  }

  /// Confirm discard before going back.
  Future<bool> _confirmDiscard() async {
    if (_session.exercises.isEmpty) return true;

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard session?'),
        content: Text(
          'You have ${_session.exercises.length} capture(s). '
          'Going back will keep them saved — you can resume from the home screen.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Stay'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Go back'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  /// Show a full-screen preview of a capture.
  void _previewCapture(ExerciseCapture exercise) {
    showDialog(
      context: context,
      builder: (context) => Dialog.fullscreen(
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Image preview
            Image.file(
              File(exercise.displayFilePath),
              fit: BoxFit.contain,
            ),
            // Close button
            Positioned(
              top: MediaQuery.of(context).padding.top + 8,
              right: 8,
              child: IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close, color: Colors.white, size: 28),
                style: IconButton.styleFrom(
                  backgroundColor: Colors.black54,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmDiscard()) {
          if (mounted) Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Column(
            children: [
              _buildTopBar(),
              _buildSessionStrip(),
              Expanded(child: _buildCameraPreview()),
              _buildCaptureControls(),
            ],
          ),
        ),
      ),
    );
  }

  /// Top bar: back button, client name, "Done" button.
  Widget _buildTopBar() {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          IconButton(
            onPressed: () async {
              if (await _confirmDiscard()) {
                if (mounted) Navigator.of(context).pop();
              }
            },
            icon: const Icon(Icons.arrow_back, color: Colors.white),
          ),
          Expanded(
            child: Text(
              _session.clientName,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          TextButton(
            onPressed: _session.exercises.isEmpty ? null : _goToEditor,
            child: Text(
              'Done',
              style: TextStyle(
                color: _session.exercises.isEmpty
                    ? Colors.white38
                    : Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Session strip: horizontal scrollable row of capture thumbnails.
  Widget _buildSessionStrip() {
    if (_session.exercises.isEmpty) {
      return const SizedBox(height: 80);
    }

    return Container(
      height: 80,
      color: Colors.black,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        itemCount: _session.exercises.length,
        itemBuilder: (context, index) {
          final exercise = _session.exercises[index];
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: GestureDetector(
              onTap: () => _previewCapture(exercise),
              child: CaptureThumbnail(
                exercise: exercise,
                size: 64,
              ),
            ),
          );
        },
      ),
    );
  }

  /// Camera preview filling the middle of the screen.
  Widget _buildCameraPreview() {
    if (!_isCameraInitialized || _cameraController == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Colors.white38),
            SizedBox(height: 16),
            Text(
              'Starting camera...',
              style: TextStyle(color: Colors.white38),
            ),
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

  /// Capture controls at the bottom: photo button (tap) / video (long press).
  Widget _buildCaptureControls() {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Capture count
          SizedBox(
            width: 80,
            child: Text(
              '${_session.exercises.length}',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 16,
              ),
            ),
          ),

          // Main capture button
          GestureDetector(
            onTap: _capturePhoto,
            onLongPressStart: (_) => _startVideoRecording(),
            onLongPressEnd: (_) => _stopVideoRecording(),
            child: _buildCaptureButton(),
          ),

          // Spacer to balance the layout
          const SizedBox(width: 80),
        ],
      ),
    );
  }

  /// The round capture button with optional video progress ring.
  Widget _buildCaptureButton() {
    final ringColor = _recordingSeconds >= _amberThresholdSeconds
        ? Colors.amber
        : Colors.red;

    return SizedBox(
      width: 80,
      height: 80,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Progress ring (visible when recording)
          if (_isRecording)
            SizedBox(
              width: 80,
              height: 80,
              child: CircularProgressIndicator(
                value: _recordingProgress,
                strokeWidth: 4,
                color: ringColor,
                backgroundColor: Colors.white24,
              ),
            ),

          // Outer ring
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 3),
            ),
          ),

          // Inner circle — changes shape when recording
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: _isRecording ? 28 : 60,
            height: _isRecording ? 28 : 60,
            decoration: BoxDecoration(
              color: _isRecording ? Colors.red : Colors.white,
              borderRadius: BorderRadius.circular(_isRecording ? 6 : 30),
            ),
          ),
        ],
      ),
    );
  }
}
