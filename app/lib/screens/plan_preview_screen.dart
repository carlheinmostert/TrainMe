import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../models/exercise_capture.dart';
import '../models/session.dart';

/// Returns true when a video exercise's converted output is a still image
/// (i.e. the fallback frame-extraction path produced a .jpg/.png instead
/// of a video file).
bool _isStillImageConversion(ExerciseCapture exercise) {
  final converted = exercise.convertedFilePath;
  if (converted == null) return false;
  final ext = converted.toLowerCase();
  return ext.endsWith('.jpg') || ext.endsWith('.jpeg') || ext.endsWith('.png');
}

/// Full-screen plan preview — simulates the client experience.
///
/// Shows exercises as a swipeable card deck with large media display,
/// exercise metadata badges, and dot indicators. This is what the client
/// sees when they open a plan link via WhatsApp.
class PlanPreviewScreen extends StatefulWidget {
  final Session session;

  const PlanPreviewScreen({
    super.key,
    required this.session,
  });

  @override
  State<PlanPreviewScreen> createState() => _PlanPreviewScreenState();
}

class _PlanPreviewScreenState extends State<PlanPreviewScreen> {
  late final PageController _pageController;
  int _currentPage = 0;

  /// Video controllers keyed by exercise index.
  /// Only the active page has a live controller.
  final Map<int, VideoPlayerController> _videoControllers = {};

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    // Prepare the first page's video if it is one
    _prepareVideo(0);
  }

  @override
  void dispose() {
    _pageController.dispose();
    for (final controller in _videoControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Video lifecycle
  // ---------------------------------------------------------------------------

  /// Create and initialise a video controller for the given page index.
  /// No-op if the exercise at that index is not a video, or if the video
  /// was converted to a still line drawing image (fallback path on iOS).
  void _prepareVideo(int index) {
    if (index < 0 || index >= widget.session.exercises.length) return;
    final exercise = widget.session.exercises[index];
    if (exercise.mediaType != MediaType.video) return;
    if (_isStillImageConversion(exercise)) return;
    if (_videoControllers.containsKey(index)) return;

    final controller = VideoPlayerController.file(
      File(exercise.displayFilePath),
    );
    _videoControllers[index] = controller;

    // Set volume based on the exercise's includeAudio flag.
    // Audio is always present in the file; this controls playback volume.
    final volume = exercise.includeAudio ? 1.0 : 0.0;

    controller
      ..setLooping(true)
      ..setVolume(volume)
      ..initialize().then((_) {
        if (mounted && _currentPage == index) {
          setState(() {});
          controller.play();
        }
      }).catchError((e) {
        debugPrint('Video init failed for index $index: $e');
      });
  }

  /// Dispose a video controller for a page that is no longer visible.
  void _disposeVideo(int index) {
    final controller = _videoControllers.remove(index);
    controller?.dispose();
  }

  /// Called when the active page changes.
  void _onPageChanged(int index) {
    // Pause the outgoing page's video
    _videoControllers[_currentPage]?.pause();

    setState(() => _currentPage = index);

    // Prepare and auto-play the incoming page's video
    _prepareVideo(index);
    final controller = _videoControllers[index];
    if (controller != null && controller.value.isInitialized) {
      controller.play();
    }

    // Dispose video controllers that are more than 1 page away
    final toDispose = _videoControllers.keys
        .where((k) => (k - index).abs() > 1)
        .toList();
    for (final k in toDispose) {
      _disposeVideo(k);
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final exercises = widget.session.exercises;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            // Top bar
            _buildTopBar(exercises.length),

            // Page view — exercise cards
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                itemCount: exercises.length,
                onPageChanged: _onPageChanged,
                itemBuilder: (context, index) {
                  return _ExercisePage(
                    exercise: exercises[index],
                    index: index,
                    session: widget.session,
                    videoController: _videoControllers[index],
                  );
                },
              ),
            ),

            // Dot indicator
            if (exercises.length > 1) _buildDotIndicator(exercises.length),

            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  /// Top bar: client name (left), "X of Y" (right), close button.
  Widget _buildTopBar(int total) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          // Close button
          IconButton(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close, color: Colors.white, size: 26),
            style: IconButton.styleFrom(backgroundColor: Colors.white12),
          ),
          const SizedBox(width: 8),

          // Client name
          Expanded(
            child: Text(
              widget.session.clientName,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),

          // Page counter
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white12,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              '${_currentPage + 1} of $total',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Dot indicator showing current position in the exercise list.
  Widget _buildDotIndicator(int total) {
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(total, (index) {
          final isActive = index == _currentPage;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            margin: const EdgeInsets.symmetric(horizontal: 4),
            width: isActive ? 24 : 8,
            height: 8,
            decoration: BoxDecoration(
              color: isActive ? Colors.white : Colors.white30,
              borderRadius: BorderRadius.circular(4),
            ),
          );
        }),
      ),
    );
  }
}

// =============================================================================
// Single exercise page — media display + metadata overlay
// =============================================================================

class _ExercisePage extends StatefulWidget {
  final ExerciseCapture exercise;
  final int index;
  final Session session;
  final VideoPlayerController? videoController;

  const _ExercisePage({
    required this.exercise,
    required this.index,
    required this.session,
    this.videoController,
  });

  @override
  State<_ExercisePage> createState() => _ExercisePageState();
}

class _ExercisePageState extends State<_ExercisePage> {
  /// Tracks whether the video is paused by user tap (not by page change).
  bool _showPlayOverlay = false;

  void _togglePlayPause() {
    final controller = widget.videoController;
    if (controller == null || !controller.value.isInitialized) return;

    setState(() {
      if (controller.value.isPlaying) {
        controller.pause();
        _showPlayOverlay = true;
      } else {
        controller.play();
        _showPlayOverlay = false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        children: [
          // Media display
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Container(color: const Color(0xFF111111)),
                  _buildMedia(),
                  // Circuit info + metadata overlay at bottom
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildCircuitBar(),
                        _buildMetadataOverlay(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Builds the media widget — photo or video.
  ///
  /// If a video exercise was converted to a still line drawing image
  /// (fallback when OpenCV can't decode H.264/H.265 on iOS), display
  /// it as a photo rather than trying to play a .jpg as video.
  Widget _buildMedia() {
    if (widget.exercise.mediaType == MediaType.video &&
        !_isStillImageConversion(widget.exercise)) {
      return _buildVideoPlayer();
    }
    return _buildPhotoViewer();
  }

  /// Photo display — full-width Image.file with BoxFit.contain.
  Widget _buildPhotoViewer() {
    return Image.file(
      File(widget.exercise.displayFilePath),
      fit: BoxFit.contain,
      width: double.infinity,
      errorBuilder: (_, _, _) => const Center(
        child: Icon(
          Icons.broken_image_outlined,
          size: 64,
          color: Colors.white24,
        ),
      ),
    );
  }

  /// Video display with play/pause on tap and a play icon when paused.
  Widget _buildVideoPlayer() {
    final controller = widget.videoController;

    if (controller == null || !controller.value.isInitialized) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white24, strokeWidth: 2),
      );
    }

    return GestureDetector(
      onTap: _togglePlayPause,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Center(
            child: AspectRatio(
              aspectRatio: controller.value.aspectRatio,
              child: VideoPlayer(controller),
            ),
          ),
          // Play button overlay when paused
          if (_showPlayOverlay || !controller.value.isPlaying)
            Container(
              width: 72,
              height: 72,
              decoration: const BoxDecoration(
                color: Colors.black45,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.play_arrow_rounded,
                size: 48,
                color: Colors.white,
              ),
            ),
          // Speaker icon overlay when audio is included
          if (widget.exercise.includeAudio)
            Positioned(
              top: 12,
              right: 12,
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: const BoxDecoration(
                  color: Colors.black45,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.volume_up_rounded,
                  size: 20,
                  color: Colors.white,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Circuit info bar — shown only when the exercise belongs to a circuit.
  ///
  /// Displays the circuit position (e.g. "2 of 3") and cycle count.
  /// Uses a teal background to match the session screen's circuit border.
  Widget _buildCircuitBar() {
    final circuitId = widget.exercise.circuitId;
    if (circuitId == null) return const SizedBox.shrink();

    // Find all exercises in this circuit, in list order.
    final circuitExercises = widget.session.exercises
        .where((e) => e.circuitId == circuitId)
        .toList();

    final positionInCircuit =
        circuitExercises.indexWhere((e) => e.id == widget.exercise.id) + 1;
    final totalInCircuit = circuitExercises.length;
    final cycles = widget.session.getCircuitCycles(circuitId);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.teal.withValues(alpha: 0.75),
      ),
      child: Row(
        children: [
          const Icon(Icons.loop, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Text(
            'Circuit',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          _circuitDot(),
          Text(
            '$positionInCircuit of $totalInCircuit',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
          _circuitDot(),
          Text(
            '\u00d7$cycles cycles',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  /// Small separator dot for the circuit bar.
  Widget _circuitDot() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Container(
        width: 4,
        height: 4,
        decoration: const BoxDecoration(
          color: Colors.white70,
          shape: BoxShape.circle,
        ),
      ),
    );
  }

  /// Semi-transparent metadata card at the bottom of the page.
  Widget _buildMetadataOverlay() {
    final exercise = widget.exercise;

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.transparent,
            Colors.black.withValues(alpha: 0.7),
            Colors.black.withValues(alpha: 0.85),
          ],
          stops: const [0.0, 0.3, 1.0],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(20, 32, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Exercise name / number
          Text(
            widget.exercise.name ?? 'Exercise ${widget.index + 1}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 12),

          // Metadata badges row
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _buildBadges(exercise),
          ),

          // Notes
          if (exercise.notes != null && exercise.notes!.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              exercise.notes!,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 15,
                height: 1.4,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }

  /// Build the reps / sets / hold badges.
  List<Widget> _buildBadges(ExerciseCapture exercise) {
    final badges = <Widget>[];

    final reps = exercise.reps ?? 10;
    badges.add(_badge('$reps reps'));

    final sets = exercise.sets ?? 3;
    badges.add(_badge('$sets sets'));

    if (exercise.holdSeconds != null && exercise.holdSeconds! > 0) {
      badges.add(_badge('${exercise.holdSeconds}s hold'));
    }

    return badges;
  }

  /// A single metadata badge — semi-transparent pill with white text.
  Widget _badge(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.2),
          width: 1,
        ),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
