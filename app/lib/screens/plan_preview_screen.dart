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

/// One slide in the unrolled preview sequence.
///
/// Standalone exercises have null circuit fields. Circuit exercises carry
/// round/position metadata so the UI can display "Round 2 of 3 - Exercise 1 of 2".
class PreviewSlide {
  final ExerciseCapture exercise;

  /// Index into the original [Session.exercises] list.
  final int originalIndex;

  /// Which round this slide belongs to (1-based), or null if standalone.
  final int? circuitRound;

  /// Total rounds for this circuit, or null if standalone.
  final int? circuitTotalRounds;

  /// Position within the circuit (1-based), or null if standalone.
  final int? positionInCircuit;

  /// Number of exercises in this circuit, or null if standalone.
  final int? circuitSize;

  const PreviewSlide({
    required this.exercise,
    required this.originalIndex,
    this.circuitRound,
    this.circuitTotalRounds,
    this.positionInCircuit,
    this.circuitSize,
  });

  bool get isCircuit => circuitRound != null;
}

/// Build the unrolled slide list from a session.
///
/// Walks through [session.exercises] in order, grouping consecutive exercises
/// that share a [circuitId]. Each circuit group is repeated N times (where N
/// comes from [Session.getCircuitCycles]). Standalone exercises appear once.
List<PreviewSlide> _buildUnrolledSlides(Session session) {
  final exercises = session.exercises;
  final slides = <PreviewSlide>[];

  var i = 0;
  while (i < exercises.length) {
    final exercise = exercises[i];

    if (exercise.circuitId == null) {
      // Standalone exercise — add once.
      slides.add(PreviewSlide(
        exercise: exercise,
        originalIndex: i,
      ));
      i++;
    } else {
      // Collect consecutive exercises with the same circuitId.
      final circuitId = exercise.circuitId!;
      final groupStartIndex = i;
      while (i < exercises.length && exercises[i].circuitId == circuitId) {
        i++;
      }
      final groupEndIndex = i; // exclusive
      final circuitSize = groupEndIndex - groupStartIndex;
      final totalRounds = session.getCircuitCycles(circuitId);

      // Repeat the group for each round.
      for (var round = 1; round <= totalRounds; round++) {
        for (var pos = 0; pos < circuitSize; pos++) {
          final originalIdx = groupStartIndex + pos;
          slides.add(PreviewSlide(
            exercise: exercises[originalIdx],
            originalIndex: originalIdx,
            circuitRound: round,
            circuitTotalRounds: totalRounds,
            positionInCircuit: pos + 1,
            circuitSize: circuitSize,
          ));
        }
      }
    }
  }

  return slides;
}

/// Full-screen plan preview — simulates the client experience.
///
/// Shows exercises as a swipeable card deck with large media display,
/// exercise metadata badges, and dot indicators. This is what the client
/// sees when they open a plan link via WhatsApp.
///
/// Circuits are "unrolled" so the client swipes through the full sequence.
/// A circuit with exercises A, B and 3 cycles becomes A, B, A, B, A, B.
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
  late final List<PreviewSlide> _slides;
  int _currentPage = 0;

  /// Continuous page value (e.g. 2.35) for smooth progress bar animation.
  double _currentPageValue = 0.0;

  /// Video controllers keyed by *slide* index (not exercise index).
  /// Each slide gets its own controller even when the same exercise file
  /// appears in multiple slides — this avoids lifecycle conflicts.
  final Map<int, VideoPlayerController> _videoControllers = {};

  @override
  void initState() {
    super.initState();
    _slides = _buildUnrolledSlides(widget.session);
    _pageController = PageController();
    _pageController.addListener(_onPageScroll);
    // Prepare the first page's video if it is one
    _prepareVideo(0);
  }

  @override
  void dispose() {
    _pageController.removeListener(_onPageScroll);
    _pageController.dispose();
    for (final controller in _videoControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  /// Fires continuously as the user drags between pages — gives us a smooth
  /// fractional page value (e.g. 2.35) rather than integer snaps.
  void _onPageScroll() {
    final page = _pageController.page;
    if (page != null) {
      setState(() => _currentPageValue = page);
    }
  }

  // ---------------------------------------------------------------------------
  // Video lifecycle
  // ---------------------------------------------------------------------------

  /// Create and initialise a video controller for the given slide index.
  /// No-op if the exercise at that slide is not a video, or if the video
  /// was converted to a still line drawing image (fallback path on iOS).
  void _prepareVideo(int index) {
    if (index < 0 || index >= _slides.length) return;
    final exercise = _slides[index].exercise;
    if (exercise.isRest) return;
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
        debugPrint('Video init failed for slide $index: $e');
      });
  }

  /// Dispose a video controller for a slide that is no longer visible.
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
  // Navigation helpers
  // ---------------------------------------------------------------------------

  /// Animate to a specific page with a smooth curve.
  void _navigateToPage(int page) {
    if (page < 0 || page >= _slides.length) return;
    _pageController.animateToPage(
      page,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  /// Circular semi-transparent navigation button with a white arrow icon.
  ///
  /// 56px tap target for gym-friendly finger targeting. The button sits on
  /// top of the PageView as an overlay and does not block swipe gestures
  /// (GestureDetector only captures taps, not horizontal drags).
  Widget _buildNavButton({
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 56,
        height: 56,
        decoration: const BoxDecoration(
          color: Colors.black38,
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: Colors.white, size: 32),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final slideCount = _slides.length;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            // Top bar
            _buildTopBar(slideCount),

            // Progress bar — always visible when more than 1 slide
            if (slideCount > 1) ...[
              const SizedBox(height: 4),
              _buildProgressBar(),
              const SizedBox(height: 4),
            ],

            // Page view — exercise cards + navigation button overlay
            Expanded(
              child: Stack(
                children: [
                  PageView.builder(
                    controller: _pageController,
                    itemCount: slideCount,
                    onPageChanged: _onPageChanged,
                    itemBuilder: (context, index) {
                      final slide = _slides[index];
                      return _ExercisePage(
                        slide: slide,
                        session: widget.session,
                        videoController: _videoControllers[index],
                      );
                    },
                  ),

                  // Back button — hidden on first slide
                  if (_currentPage > 0)
                    Positioned(
                      left: 8,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: _buildNavButton(
                          icon: Icons.chevron_left,
                          onTap: () => _navigateToPage(_currentPage - 1),
                        ),
                      ),
                    ),

                  // Forward button — hidden on last slide
                  if (_currentPage < slideCount - 1)
                    Positioned(
                      right: 8,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: _buildNavButton(
                          icon: Icons.chevron_right,
                          onTap: () => _navigateToPage(_currentPage + 1),
                        ),
                      ),
                    ),
                ],
              ),
            ),

            // Dot indicator — only when slide count is manageable (<=10).
            // With many slides the progress bar above is sufficient.
            if (slideCount > 1 && slideCount <= 10)
              _buildDotIndicator(slideCount),

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

  /// Thin progress bar showing overall workout completion.
  ///
  /// Uses [_currentPageValue] (a continuous double from the PageController
  /// listener) so the fill animates smoothly as the user drags between pages
  /// rather than jumping discretely on page snap.
  Widget _buildProgressBar() {
    final total = _slides.length;
    final fraction = total <= 1 ? 1.0 : (_currentPageValue + 1) / total;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: SizedBox(
        height: 3.5,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: Stack(
            children: [
              // Track
              Container(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // Fill — uses FractionallySizedBox for smooth width
              FractionallySizedBox(
                widthFactor: fraction.clamp(0.0, 1.0),
                child: Container(
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Colors.white, Color(0xFF4DB6AC)], // white → teal
                    ),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Dot indicator showing current position in the unrolled slide list.
  ///
  /// Only called when [total] <= 10 (the caller guards this). For larger
  /// slide counts the progress bar alone is sufficient.
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
  final PreviewSlide slide;
  final Session session;
  final VideoPlayerController? videoController;

  const _ExercisePage({
    required this.slide,
    required this.session,
    this.videoController,
  });

  @override
  State<_ExercisePage> createState() => _ExercisePageState();
}

class _ExercisePageState extends State<_ExercisePage> {
  /// Tracks whether the video is paused by user tap (not by page change).
  bool _showPlayOverlay = false;

  ExerciseCapture get _exercise => widget.slide.exercise;

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

  /// Builds the media widget — photo, video, or rest.
  ///
  /// If a video exercise was converted to a still line drawing image
  /// (fallback when OpenCV can't decode H.264/H.265 on iOS), display
  /// it as a photo rather than trying to play a .jpg as video.
  Widget _buildMedia() {
    if (_exercise.isRest) return _buildRestDisplay();
    if (_exercise.mediaType == MediaType.video &&
        !_isStillImageConversion(_exercise)) {
      return _buildVideoPlayer();
    }
    return _buildPhotoViewer();
  }

  /// Rest period display — calming gradient with large rest icon and duration.
  Widget _buildRestDisplay() {
    final duration = _exercise.holdSeconds ?? 30;

    // Find the next non-rest exercise name for "Next up" label
    String? nextExerciseName;
    final slides = widget.session.exercises;
    final currentOriginalIdx = widget.slide.originalIndex;
    for (var i = currentOriginalIdx + 1; i < slides.length; i++) {
      if (!slides[i].isRest) {
        nextExerciseName = slides[i].name ?? 'Exercise ${i + 1}';
        break;
      }
    }

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0xFF37474F), // blue-grey 800
            Color(0xFF263238), // blue-grey 900
          ],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.self_improvement,
              size: 64,
              color: Color(0xFF80CBC4), // teal 200
            ),
            const SizedBox(height: 16),
            const Text(
              'Rest',
              style: TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '${duration}s',
              style: const TextStyle(
                color: Color(0xFF80CBC4),
                fontSize: 48,
                fontWeight: FontWeight.w300,
                letterSpacing: -1,
              ),
            ),
            if (nextExerciseName != null) ...[
              const SizedBox(height: 24),
              Text(
                'Next up: $nextExerciseName',
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Photo display — full-width Image.file with BoxFit.contain.
  Widget _buildPhotoViewer() {
    return Image.file(
      File(_exercise.displayFilePath),
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
          if (_exercise.includeAudio)
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

  /// Circuit info bar — shown only when this slide is part of a circuit.
  ///
  /// Displays "Circuit - Round X of Y - Exercise M of N" using the
  /// pre-computed metadata from the unrolled [PreviewSlide].
  Widget _buildCircuitBar() {
    final slide = widget.slide;
    if (!slide.isCircuit) return const SizedBox.shrink();

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
            'Round ${slide.circuitRound} of ${slide.circuitTotalRounds}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
          _circuitDot(),
          Text(
            'Exercise ${slide.positionInCircuit} of ${slide.circuitSize}',
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
  /// Hidden for rest periods — the rest display already shows all info.
  Widget _buildMetadataOverlay() {
    if (_exercise.isRest) return const SizedBox.shrink();
    final exercise = _exercise;

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
            exercise.name ?? 'Exercise ${widget.slide.originalIndex + 1}',
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
