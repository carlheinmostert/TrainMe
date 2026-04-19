import 'dart:async';
import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../models/exercise_capture.dart';
import '../models/session.dart';
import '../theme.dart';
import '../widgets/progress_pill_matrix.dart';

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

/// Prep phase duration (seconds) before each exercise in workout mode.
const int _kPrepSeconds = 15;

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

  /// Slide index to land on when opening the preview. Defaults to 0.
  ///
  /// For circuit members, pass the data index (position in
  /// [Session.exercises]) and use [slideIndexForExerciseIndex] to translate
  /// it into the unrolled slide index (first round's slide).
  final int initialSlideIndex;

  const PlanPreviewScreen({
    super.key,
    required this.session,
    this.initialSlideIndex = 0,
  });

  /// Returns the unrolled slide index that corresponds to the first
  /// occurrence of the exercise at [exerciseIndex] in [session.exercises].
  ///
  /// For circuit members this lands on the first round's slide. Returns 0
  /// if no match is found (defensive — callers already passed a valid
  /// data index).
  static int slideIndexForExerciseIndex(Session session, int exerciseIndex) {
    final slides = _buildUnrolledSlides(session);
    for (var i = 0; i < slides.length; i++) {
      if (slides[i].originalIndex == exerciseIndex) return i;
    }
    return 0;
  }

  @override
  State<PlanPreviewScreen> createState() => _PlanPreviewScreenState();
}

class _PlanPreviewScreenState extends State<PlanPreviewScreen> {
  late final PageController _pageController;
  late final List<PreviewSlide> _slides;

  /// Matrix-ready slide list — same ordering as [_slides], carrying the
  /// circuit metadata the [ProgressPillMatrix] needs.
  late final List<ProgressPillSlide> _pillSlides;
  int _currentPage = 0;

  /// Video controllers keyed by *slide* index (not exercise index).
  /// Each slide gets its own controller even when the same exercise file
  /// appears in multiple slides — this avoids lifecycle conflicts.
  final Map<int, VideoPlayerController> _videoControllers = {};

  // ---------------------------------------------------------------------------
  // Workout timer state
  // ---------------------------------------------------------------------------

  /// Whether the user has entered workout mode (timer-driven progression).
  bool _isWorkoutMode = false;

  /// Whether the exercise countdown timer is actively ticking.
  bool _isTimerRunning = false;

  /// Whether the current slide is in the 15s prep phase.
  /// Prep is a silent countdown where the video auto-loops as a preview
  /// of the motion the client is about to perform.
  bool _isPrepPhase = false;

  /// Seconds remaining on the prep-phase countdown.
  int _prepRemainingSeconds = 0;

  /// Seconds remaining on the current slide's exercise countdown.
  int _remainingSeconds = 0;

  /// Total seconds for the current slide (used for progress ring calculation).
  int _totalSeconds = 0;

  /// Whether the workout has been completed (all slides finished).
  bool _workoutComplete = false;

  /// Wall-clock time when workout mode was entered.
  DateTime? _workoutStartTime;

  /// The periodic timer that drives the per-second countdown (exercise or prep).
  Timer? _workoutTimer;

  @override
  void initState() {
    super.initState();
    _slides = _buildUnrolledSlides(widget.session);
    _pillSlides = buildProgressPillSlides(widget.session);
    // Clamp the requested initial index to the valid range. Callers may
    // pass an index computed from a stale exercise list; better to land on
    // slide 0 than crash.
    final initial = _slides.isEmpty
        ? 0
        : widget.initialSlideIndex.clamp(0, _slides.length - 1);
    _currentPage = initial;
    _pageController = PageController(initialPage: initial);
    // Prepare the initial page's video if it is one
    _prepareVideo(initial);
  }

  @override
  void dispose() {
    _workoutTimer?.cancel();
    _pageController.dispose();
    for (final controller in _videoControllers.values) {
      controller.dispose();
    }
    super.dispose();
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
        // Guard against controller-disposed-before-init race: a fast swipe
        // can call _disposeVideo(index) before init completes, so the
        // callback may fire on a stale (disposed) controller.
        if (_videoControllers[index] != controller) return;
        if (mounted && _currentPage == index) {
          setState(() {});
          // Auto-play the current slide's video as soon as it's ready —
          // works for browse mode, workout mode, AND the initial first slide.
          // The video is the motion demo; it loops as a continuous reminder.
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
    // prep/timer for the new slide. The _advanceToNext path handles this via
    // a post-frame callback, but manual swipes come through here.
    if (_isWorkoutMode && !_workoutComplete) {
      _setupSlideTimer(index);
    }
  }

  // ---------------------------------------------------------------------------
  // Workout timer
  // ---------------------------------------------------------------------------

  /// Enter workout mode: record the start time and set up the first slide
  /// (which kicks off a 15s prep phase for non-rest exercises).
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
  /// Rest slides auto-start the countdown immediately. Exercise slides enter
  /// a 15s prep phase during which the video auto-loops; the prep timer ticks
  /// down and then the exercise timer starts automatically.
  void _setupSlideTimer(int index) {
    _workoutTimer?.cancel();
    if (index < 0 || index >= _slides.length) return;

    final exercise = _slides[index].exercise;
    final duration = exercise.effectiveDurationSeconds;

    setState(() {
      _totalSeconds = duration;
      _remainingSeconds = duration;
      _isTimerRunning = false;
      _isPrepPhase = false;
      _prepRemainingSeconds = 0;
    });

    if (exercise.isRest) {
      // Rest periods start counting down immediately — no prep phase.
      _startTimer();
    } else {
      // Exercises get a 15s prep phase first. Video keeps looping in
      // the background as a motion preview.
      _startPrepPhase();
    }
  }

  /// Begin the 15-second prep countdown for the current exercise slide.
  /// Ticks down once per second; on reaching 0, transitions into the running
  /// exercise timer. The video loops throughout as a motion reminder.
  void _startPrepPhase() {
    _workoutTimer?.cancel();
    setState(() {
      _isPrepPhase = true;
      _prepRemainingSeconds = _kPrepSeconds;
      _isTimerRunning = false;
    });
    _workoutTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _onPrepTick();
    });
  }

  /// Called once per second during prep phase.
  void _onPrepTick() {
    if (_prepRemainingSeconds <= 1) {
      // Prep is done — cancel the prep ticker and start the exercise timer.
      _workoutTimer?.cancel();
      setState(() {
        _prepRemainingSeconds = 0;
        _isPrepPhase = false;
      });
      _startTimer();
    } else {
      setState(() => _prepRemainingSeconds--);
    }
  }

  /// Skip the prep phase and immediately enter the exercise timer.
  /// Invoked by tapping the prep timer ring.
  void _skipPrep() {
    if (!_isPrepPhase) return;
    _workoutTimer?.cancel();
    setState(() {
      _isPrepPhase = false;
      _prepRemainingSeconds = 0;
    });
    _startTimer();
  }

  /// Begin (or resume) the exercise countdown for the current slide.
  /// Also plays any video on this slide so timer and video stay in sync
  /// (video should already be playing from auto-play, but this is defensive).
  void _startTimer() {
    setState(() {
      _isTimerRunning = true;
    });
    final controller = _videoControllers[_currentPage];
    if (controller != null && controller.value.isInitialized) {
      controller.play();
    }
    _workoutTimer?.cancel();
    _workoutTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _onTimerTick();
    });
  }

  /// Pause the running countdown. Also pauses any playing video on the
  /// current slide so the timer and video stay in sync.
  void _pauseTimer() {
    _workoutTimer?.cancel();
    final controller = _videoControllers[_currentPage];
    if (controller != null && controller.value.isInitialized) {
      controller.pause();
    }
    setState(() => _isTimerRunning = false);
  }

  /// Resume a previously paused countdown. Also resumes video playback.
  void _resumeTimer() {
    if (_remainingSeconds <= 0) return;
    setState(() => _isTimerRunning = true);
    final controller = _videoControllers[_currentPage];
    if (controller != null && controller.value.isInitialized) {
      controller.play();
    }
    _workoutTimer?.cancel();
    _workoutTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _onTimerTick();
    });
  }

  /// Tap handler for the consolidated timer chip. Dispatches to the correct
  /// action based on current mode (prep / running / paused).
  void _onTimerChipTap() {
    if (_isPrepPhase) {
      _skipPrep();
    } else if (_isTimerRunning) {
      _pauseTimer();
    } else {
      _resumeTimer();
    }
  }

  /// Called every second while the exercise timer is running.
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
    // timer (and 15s prep, if non-rest) for the new slide. Use a post-frame
    // callback so the page has settled.
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
      _isPrepPhase = false;
      _prepRemainingSeconds = 0;
      _workoutComplete = true;
    });
  }

  /// Exit workout mode entirely and return to browse mode.
  void _exitWorkoutMode() {
    _workoutTimer?.cancel();
    setState(() {
      _isWorkoutMode = false;
      _isTimerRunning = false;
      _isPrepPhase = false;
      _prepRemainingSeconds = 0;
      _remainingSeconds = 0;
      _totalSeconds = 0;
      _workoutComplete = false;
      _workoutStartTime = null;
    });
  }

  /// Fraction 0..1 the active pill's fill bar should show. During prep we
  /// keep the fill at zero — the pulse glow is enough of a cue that the
  /// exercise is live, and the timer chip shows the 15s countdown.
  double _computeTimerProgress() {
    if (!_isWorkoutMode) return 0.0;
    if (_isPrepPhase) return 0.0;
    if (_totalSeconds <= 0) return 0.0;
    return ((_totalSeconds - _remainingSeconds) / _totalSeconds)
        .clamp(0.0, 1.0);
  }

  /// Seconds of workout time remaining. Drives the ETA widget's "X left" and
  /// "~finish" readouts.
  ///
  /// In workout mode: what's left of the active slide (from _remainingSeconds)
  /// + the estimated duration of every slide after it. The active-slide
  /// portion only decreases while the timer is actually running (the parent
  /// rebuild cadence handles this). Paused → this value stays static, which
  /// is exactly what we want: "remaining holds, finish drifts".
  ///
  /// Before Start Workout: total plan duration (stale finish-time-if-started
  /// -now). After finish: 0 (but workoutComplete flag takes precedence in the
  /// widget itself).
  /// Seconds left on the CURRENT slide (or prep countdown during prep
  /// phase). Feeds the bold coral `1:36` token in the pill matrix's
  /// top row. Returns -1 outside workout mode so the matrix omits the
  /// token entirely.
  int _computeCurrentSlideRemainingSeconds() {
    if (!_isWorkoutMode) return -1;
    if (_workoutComplete) return 0;
    if (_isPrepPhase) return _prepRemainingSeconds;
    return _remainingSeconds;
  }

  int _computeRemainingWorkoutSeconds() {
    if (_slides.isEmpty) return 0;
    if (_workoutComplete) return 0;

    int sum = 0;

    // The portion of the "now playing" slide that still has to run.
    if (_isWorkoutMode && _currentPage >= 0 && _currentPage < _slides.length) {
      if (_isPrepPhase) {
        // Prep hasn't started the exercise countdown yet — the full slide
        // duration is still ahead, plus whatever's left of the 15s prep
        // runway.
        sum += _prepRemainingSeconds +
            _slides[_currentPage].exercise.effectiveDurationSeconds;
      } else {
        // Running or paused — use the authoritative _remainingSeconds the
        // tick loop is driving. When paused this number doesn't change, so
        // the total stays static (which makes the finish time drift via
        // DateTime.now() advancing in the child ticker).
        sum += _remainingSeconds;
      }
    } else {
      // Not yet in workout mode — include the current slide's full duration.
      if (_currentPage >= 0 && _currentPage < _slides.length) {
        sum += _slides[_currentPage].exercise.effectiveDurationSeconds;
      }
    }

    // All slides strictly after the active one — full estimated duration.
    for (var i = _currentPage + 1; i < _slides.length; i++) {
      sum += _slides[i].exercise.effectiveDurationSeconds;
    }
    return sum;
  }

  /// Matrix jump — user released a long-press on a different pill. Jump the
  /// page view to that slide and, when in workout mode, reset its timer.
  void _onMatrixJumpTo(int slideIndex) {
    if (slideIndex < 0 || slideIndex >= _slides.length) return;
    _navigateToPage(slideIndex);
    if (_isWorkoutMode && !_workoutComplete) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _setupSlideTimer(slideIndex);
      });
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
  /// top of the PageView as an overlay and must not block swipe gestures.
  /// Uses RawGestureDetector with only a TapGestureRecognizer so horizontal
  /// drags propagate to the underlying PageView via the gesture arena —
  /// a plain GestureDetector with behavior: opaque would swallow PointerDown
  /// events before the PageView ever sees them.
  Widget _buildNavButton({
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      gestures: <Type, GestureRecognizerFactory>{
        TapGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
          () => TapGestureRecognizer(),
          (TapGestureRecognizer instance) {
            instance.onTap = onTap;
          },
        ),
      },
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

            // Progress-pill matrix — replaces the previous linear bar.
            // Always render when more than 1 slide so the bio can scan the
            // plan structure at a glance. Single-exercise plans skip this.
            if (slideCount > 1) ...[
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: ProgressPillMatrix(
                  slides: _pillSlides,
                  activeSlideIndex: _isWorkoutMode ? _currentPage : -1,
                  timerProgress: _computeTimerProgress(),
                  paused: !_isTimerRunning && !_isPrepPhase,
                  remainingSeconds: _computeRemainingWorkoutSeconds(),
                  currentSlideRemainingSeconds:
                      _computeCurrentSlideRemainingSeconds(),
                  workoutComplete: _workoutComplete,
                  onJumpTo: _onMatrixJumpTo,
                ),
              ),
              const SizedBox(height: 8),
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
                      // Chip removed — tap on the video or rest card
                      // body now triggers the mode-aware handler (skip
                      // prep / pause / resume). The current-slide
                      // countdown is shown in the pill matrix's top row.
                      final isActiveInWorkout = _isWorkoutMode &&
                          !_workoutComplete &&
                          index == _currentPage;
                      return _ExercisePage(
                        slide: slide,
                        session: widget.session,
                        videoController: _videoControllers[index],
                        onTap: isActiveInWorkout ? _onTimerChipTap : null,
                        pausedOverlay: isActiveInWorkout &&
                            !_isTimerRunning &&
                            !_isPrepPhase,
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

                  // Timer ring is rendered inside the per-slide metadata panel
                  // via _ExercisePage.timerChip, not as a fullscreen overlay.
                  // Rest slides use the same chip — the full-screen rest
                  // countdown overlay was removed to eliminate redundancy.

                  // Workout complete overlay
                  if (_workoutComplete) _buildWorkoutCompleteOverlay(),
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
                colors: [AppColors.primary, AppColors.primaryDark],
              ),
              borderRadius: BorderRadius.circular(32),
              boxShadow: [
                BoxShadow(
                  color: AppColors.primary.withValues(alpha: 0.4),
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
                color: AppColors.primary,
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
                      colors: [AppColors.primary, AppColors.primaryDark],
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

          // Page counter removed — the progress-pill matrix above
          // already communicates where the user is in the plan (active
          // pill position + total pill count). The "1 of 15" chip was
          // redundant signalling.

        ],
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

  /// Mode-aware tap handler routed up from the video/rest card's body
  /// (prep → skip prep, running → pause, paused → resume). Provided by
  /// the parent during workout mode. Null outside workout mode —
  /// reverts to the video's own play/pause toggle.
  final VoidCallback? onTap;

  /// Whether the workout is currently paused (or in prep). Drives the
  /// centered play-arrow overlay that appears on top of the media so
  /// the user has a visible "tap to resume" affordance regardless of
  /// whether the media is a video, photo, or rest card.
  final bool pausedOverlay;

  const _ExercisePage({
    required this.slide,
    required this.session,
    this.videoController,
    this.onTap,
    this.pausedOverlay = false,
  });

  @override
  State<_ExercisePage> createState() => _ExercisePageState();
}

class _ExercisePageState extends State<_ExercisePage> {
  /// Tracks whether the video is paused by user tap (not by page change).
  /// Overlay is only visible when the user has explicitly paused the video —
  /// it must not flash while the video is transiently paused by the parent
  /// (e.g. during page change or workout pause).
  bool _showPlayOverlay = false;

  ExerciseCapture get _exercise => widget.slide.exercise;

  void _togglePlayPause() {
    // In workout mode the parent owns pause/resume — routing tap up
    // also pauses/skips the workout TIMER, not just the video. Outside
    // workout mode (idle preview), fall back to local video toggle so
    // practitioners can scrub the clip.
    if (widget.onTap != null) {
      widget.onTap!();
      return;
    }
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
                  // Paused affordance — centered play-arrow over the
                  // media when the workout is paused. Unified across
                  // video / photo / rest so tap-to-pause always has
                  // visible feedback. Touch-transparent so the whole
                  // area stays tappable.
                  if (widget.pausedOverlay)
                    const IgnorePointer(
                      child: Center(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Color(0x66000000),
                            shape: BoxShape.circle,
                          ),
                          child: Padding(
                            padding: EdgeInsets.all(16),
                            child: Icon(
                              Icons.play_arrow_rounded,
                              color: Colors.white,
                              size: 56,
                            ),
                          ),
                        ),
                      ),
                    ),
                  // Circuit info + metadata overlay at bottom
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    // Bottom metadata overlay (gradient wash + exercise
                    // notes). Circuit round-of-N signalling is owned by
                    // the progress-pill matrix above.
                    child: _buildMetadataOverlay(),
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
    final inner = _exercise.isRest
        ? _buildRestDisplay()
        : (_exercise.mediaType == MediaType.video &&
                !_isStillImageConversion(_exercise))
            ? _buildVideoPlayer()
            : _buildPhotoViewer();
    // Whole body is a tap target for the mode-aware pause / skip-prep
    // handler routed from the parent. The video player already wires
    // its own GestureDetector via _togglePlayPause (which now routes
    // up to widget.onTap when provided); rest + photo need this outer
    // wrapper.
    if (widget.onTap == null || !_exercise.isRest && _exercise.mediaType == MediaType.video && !_isStillImageConversion(_exercise)) {
      return inner;
    }
    return GestureDetector(
      onTap: _togglePlayPause,
      behavior: HitTestBehavior.opaque,
      child: inner,
    );
  }

  /// Rest period display — calming gradient with rest icon and "Next up".
  ///
  /// The numeric countdown previously shown here has been removed — the
  /// bottom-right timer chip is the single source of truth for the rest
  /// countdown in workout mode.
  Widget _buildRestDisplay() {
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
              color: Color(0xFFFF8F5E), // primary light
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
            if (nextExerciseName != null) ...[
              const SizedBox(height: 16),
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

  /// Video display with play/pause on tap. Play overlay only appears when the
  /// user has explicitly paused via tap (`_showPlayOverlay`). It never flashes
  /// while the video is auto-playing.
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
          // Play overlay — only shown when the user has explicitly tapped
          // to pause. Never appears during auto-play / transient pauses.
          if (_showPlayOverlay)
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
  /// Semi-transparent metadata card at the bottom of the page.
  ///
  /// Rest slides skip this entirely — their card body already owns the
  /// visual language. Exercise slides get a gradient wash with the
  /// notes line on top (the only instructional copy not encoded by the
  /// progress-pill matrix above).
  Widget _buildMetadataOverlay() {
    if (_exercise.isRest) return const SizedBox.shrink();
    final exercise = _exercise;

    // Exercise name + reps/sets/hold badges removed from the overlay:
    // the progress-pill matrix above now carries the active exercise
    // name (top row, left), and the pill itself encodes the shorthand
    // sets|reps|hold. Notes stay — they're the only instructional copy
    // the client sees, and can't be collapsed into a pill.
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
      child: (exercise.notes != null && exercise.notes!.isNotEmpty)
          ? Text(
              exercise.notes!,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 15,
                height: 1.4,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            )
          : const SizedBox.shrink(),
    );
  }
}

