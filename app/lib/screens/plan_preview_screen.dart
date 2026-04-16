import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
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

  // ---------------------------------------------------------------------------
  // Workout timer state
  // ---------------------------------------------------------------------------

  /// Whether the user has entered workout mode (timer-driven progression).
  bool _isWorkoutMode = false;

  /// Whether the countdown timer is actively ticking.
  bool _isTimerRunning = false;

  /// Whether to show the "Tap to start" play gate overlay.
  bool _showPlayGate = false;

  /// Seconds remaining on the current slide's countdown.
  int _remainingSeconds = 0;

  /// Total seconds for the current slide (used for progress ring calculation).
  int _totalSeconds = 0;

  /// Whether the workout has been completed (all slides finished).
  bool _workoutComplete = false;

  /// Wall-clock time when workout mode was entered.
  DateTime? _workoutStartTime;

  /// The periodic timer that drives the per-second countdown.
  Timer? _workoutTimer;

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
    _workoutTimer?.cancel();
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

    // When in workout mode and the user manually swipes (skip), reset the
    // timer for the new slide. The _advanceToNext path handles this via a
    // post-frame callback, but manual swipes come through here.
    if (_isWorkoutMode && !_workoutComplete) {
      _setupSlideTimer(index);
    }
  }

  // ---------------------------------------------------------------------------
  // Workout timer
  // ---------------------------------------------------------------------------

  /// Enter workout mode: record the start time and set up the first slide.
  void _startWorkout() {
    setState(() {
      _isWorkoutMode = true;
      _workoutComplete = false;
      _workoutStartTime = DateTime.now();
    });
    _setupSlideTimer(_currentPage);
  }

  /// Configure the timer for the given slide index.
  ///
  /// Rest slides auto-start immediately. Exercise slides show the play gate
  /// so the client can get ready before the countdown begins.
  void _setupSlideTimer(int index) {
    _workoutTimer?.cancel();
    if (index < 0 || index >= _slides.length) return;

    final exercise = _slides[index].exercise;
    final duration = exercise.effectiveDurationSeconds;

    setState(() {
      _totalSeconds = duration;
      _remainingSeconds = duration;
      _isTimerRunning = false;
      _showPlayGate = false;
    });

    if (exercise.isRest) {
      // Rest periods start counting down immediately — no play gate.
      _startTimer();
    } else {
      // Exercises show the play gate; client taps when ready.
      setState(() => _showPlayGate = true);
    }
  }

  /// Begin (or resume) the countdown for the current slide.
  void _startTimer() {
    setState(() {
      _showPlayGate = false;
      _isTimerRunning = true;
    });
    _workoutTimer?.cancel();
    _workoutTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _onTimerTick();
    });
  }

  /// Pause the running countdown.
  void _pauseTimer() {
    _workoutTimer?.cancel();
    setState(() => _isTimerRunning = false);
  }

  /// Resume a previously paused countdown.
  void _resumeTimer() {
    if (_remainingSeconds <= 0) return;
    setState(() => _isTimerRunning = true);
    _workoutTimer?.cancel();
    _workoutTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _onTimerTick();
    });
  }

  /// Called every second while the timer is running.
  void _onTimerTick() {
    if (_remainingSeconds <= 1) {
      // Timer has finished — advance or complete.
      _workoutTimer?.cancel();
      setState(() {
        _remainingSeconds = 0;
        _isTimerRunning = false;
      });

      if (_currentPage < _slides.length - 1) {
        _advanceToNext();
      } else {
        _finishWorkout();
      }
    } else {
      setState(() => _remainingSeconds--);
    }
  }

  /// Auto-advance to the next slide after the current timer expires.
  void _advanceToNext() {
    final nextPage = _currentPage + 1;
    if (nextPage >= _slides.length) {
      _finishWorkout();
      return;
    }
    _navigateToPage(nextPage);
    // _onPageChanged will fire via PageView, but we also need to set up the
    // timer for the new slide. Use a post-frame callback so the page has
    // settled.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _isWorkoutMode && !_workoutComplete) {
        _setupSlideTimer(nextPage);
      }
    });
  }

  /// Mark the workout as complete and record total elapsed time.
  void _finishWorkout() {
    _workoutTimer?.cancel();
    setState(() {
      _isTimerRunning = false;
      _showPlayGate = false;
      _workoutComplete = true;
    });
  }

  /// Exit workout mode entirely and return to browse mode.
  void _exitWorkoutMode() {
    _workoutTimer?.cancel();
    setState(() {
      _isWorkoutMode = false;
      _isTimerRunning = false;
      _showPlayGate = false;
      _remainingSeconds = 0;
      _totalSeconds = 0;
      _workoutComplete = false;
      _workoutStartTime = null;
    });
  }

  /// Format seconds as "M:SS".
  String _formatTimer(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
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

                  // --- Workout mode overlays ---

                  // Start Workout button — shown on first slide before
                  // workout mode is active.
                  if (!_isWorkoutMode && !_workoutComplete)
                    _buildStartWorkoutOverlay(),

                  // Timer ring — visible while workout mode is active and
                  // the timer is running (not during play gate).
                  if (_isWorkoutMode &&
                      !_workoutComplete &&
                      _isTimerRunning &&
                      !_showPlayGate)
                    _buildTimerOverlay(),

                  // Rest countdown overlay — larger display for rest slides
                  if (_isWorkoutMode &&
                      !_workoutComplete &&
                      _isTimerRunning &&
                      _slides[_currentPage].exercise.isRest)
                    _buildRestCountdownOverlay(),

                  // Play gate — "Tap to start" before each exercise.
                  if (_isWorkoutMode && !_workoutComplete && _showPlayGate)
                    _buildPlayGateOverlay(),

                  // Workout complete overlay
                  if (_workoutComplete) _buildWorkoutCompleteOverlay(),
                ],
              ),
            ),

            // Workout controls bar (pause/resume) — below the page view
            if (_isWorkoutMode && !_workoutComplete && !_showPlayGate)
              _buildWorkoutControls(),

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

  // ---------------------------------------------------------------------------
  // Workout overlay widgets
  // ---------------------------------------------------------------------------

  /// "Start Workout" button — bottom-center overlay before workout mode begins.
  Widget _buildStartWorkoutOverlay() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 32,
      child: Center(
        child: GestureDetector(
          onTap: _startWorkout,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF4DB6AC), Color(0xFF00897B)],
              ),
              borderRadius: BorderRadius.circular(32),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF4DB6AC).withValues(alpha: 0.4),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.play_arrow_rounded, color: Colors.white, size: 28),
                SizedBox(width: 8),
                Text(
                  'Start Workout',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Circular countdown timer with a progress ring.
  ///
  /// The ring fills from 0 to 1 as time elapses. Colour shifts from green
  /// through amber to red based on remaining time thresholds.
  Widget _buildTimerRing() {
    final progress = _totalSeconds > 0
        ? (_totalSeconds - _remainingSeconds) / _totalSeconds
        : 0.0;
    final Color color;
    if (_remainingSeconds > _totalSeconds * 0.25) {
      color = Colors.green;
    } else if (_remainingSeconds > _totalSeconds * 0.10) {
      color = Colors.amber;
    } else {
      color = Colors.red;
    }

    return SizedBox(
      width: 120,
      height: 120,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Custom painted ring for a thicker, rounder arc.
          CustomPaint(
            size: const Size(120, 120),
            painter: _TimerRingPainter(
              progress: progress,
              color: color,
              trackColor: Colors.white.withValues(alpha: 0.15),
              strokeWidth: 6,
            ),
          ),
          Text(
            _formatTimer(_remainingSeconds),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 32,
              fontWeight: FontWeight.bold,
              letterSpacing: -1,
            ),
          ),
        ],
      ),
    );
  }

  /// Timer overlay — centered on the slide with a semi-transparent scrim.
  Widget _buildTimerOverlay() {
    // Don't double-up on rest slides; the rest countdown overlay handles those.
    if (_slides[_currentPage].exercise.isRest) return const SizedBox.shrink();

    return Positioned.fill(
      child: IgnorePointer(
        child: Center(
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.35),
              shape: BoxShape.circle,
            ),
            child: _buildTimerRing(),
          ),
        ),
      ),
    );
  }

  /// Rest countdown — large centred number with "Next up" label.
  Widget _buildRestCountdownOverlay() {
    // Find the name of the next non-rest exercise for the "Next up" label.
    String? nextExerciseName;
    for (var i = _currentPage + 1; i < _slides.length; i++) {
      if (!_slides[i].exercise.isRest) {
        final ex = _slides[i].exercise;
        nextExerciseName = ex.name ?? 'Exercise ${_slides[i].originalIndex + 1}';
        break;
      }
    }

    return Positioned.fill(
      child: IgnorePointer(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildTimerRing(),
              if (nextExerciseName != null) ...[
                const SizedBox(height: 20),
                Text(
                  'Next up: $nextExerciseName',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Play gate — large play button with "Tap to start" text.
  Widget _buildPlayGateOverlay() {
    return Positioned.fill(
      child: GestureDetector(
        onTap: _startTimer,
        behavior: HitTestBehavior.opaque,
        child: Container(
          color: Colors.black.withValues(alpha: 0.5),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(
                    color: const Color(0xFF4DB6AC).withValues(alpha: 0.9),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF4DB6AC).withValues(alpha: 0.4),
                        blurRadius: 24,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.play_arrow_rounded,
                    size: 56,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Tap to start',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 18,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _formatTimer(_totalSeconds),
                  style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 14,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Pause / resume controls below the page view.
  Widget _buildWorkoutControls() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: GestureDetector(
          onTap: _isTimerRunning ? _pauseTimer : _resumeTimer,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _isTimerRunning
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: 24,
                ),
                const SizedBox(width: 8),
                Text(
                  _isTimerRunning ? 'Pause' : 'Resume',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Workout complete screen — total time and close button.
  Widget _buildWorkoutCompleteOverlay() {
    final elapsed = _workoutStartTime != null
        ? DateTime.now().difference(_workoutStartTime!).inSeconds
        : 0;
    final totalFormatted = formatDuration(elapsed);

    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.85),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.check_circle_outline_rounded,
                size: 80,
                color: Color(0xFF4DB6AC),
              ),
              const SizedBox(height: 24),
              const Text(
                'Workout Complete!',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Total time: $totalFormatted',
                style: const TextStyle(
                  color: Colors.white60,
                  fontSize: 18,
                  fontWeight: FontWeight.w400,
                ),
              ),
              const SizedBox(height: 40),
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF4DB6AC), Color(0xFF00897B)],
                    ),
                    borderRadius: BorderRadius.circular(28),
                  ),
                  child: const Text(
                    'Close',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              GestureDetector(
                onTap: _exitWorkoutMode,
                child: const Text(
                  'Back to browse',
                  style: TextStyle(
                    color: Colors.white38,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    decoration: TextDecoration.underline,
                    decorationColor: Colors.white38,
                  ),
                ),
              ),
            ],
          ),
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

// =============================================================================
// Timer ring painter — draws an arc that fills as time elapses
// =============================================================================

class _TimerRingPainter extends CustomPainter {
  final double progress; // 0.0 .. 1.0
  final Color color;
  final Color trackColor;
  final double strokeWidth;

  const _TimerRingPainter({
    required this.progress,
    required this.color,
    required this.trackColor,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (math.min(size.width, size.height) - strokeWidth) / 2;

    // Track (full circle, dim)
    final trackPaint = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, radius, trackPaint);

    // Progress arc — starts at top (−pi/2), sweeps clockwise.
    if (progress > 0) {
      final arcPaint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2,
        2 * math.pi * progress,
        false,
        arcPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _TimerRingPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}
