// TODO(wave4-phase2+): Retire this screen once Wave 4 Phase 2+ has
// shipped to Carl's iPhone and parity with `UnifiedPreviewScreen` holds
// for one week of device QA. Until then this remains reachable via a
// long-press on the Studio slideshow icon as an escape hatch — the
// regular tap opens the unified preview (web-player bundle inside a
// WebView, served by the native `homefit-local://` URL scheme handler).
// Tracking note: file shares `plan_preview_screen.dart` filename with
// portal UI — when deleting, also drop the import from
// `studio_mode_screen.dart` and scrub the long-press branch.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../models/client.dart';
import '../models/exercise_capture.dart';
import '../models/session.dart';
import '../models/treatment.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../services/sync_service.dart';
import '../theme.dart';
import '../widgets/client_consent_sheet.dart';
import '../widgets/progress_pill_matrix.dart';
import '../widgets/treatment_segmented_control.dart';

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
/// Global default prep-countdown duration (in seconds).
///
/// Previously 15s; shrunk to 5s in Wave 3 after device QA feedback
/// ("15 feels like forever for a focused circuit"). Per-exercise overrides
/// live on [ExerciseCapture.prepSeconds] and are honoured via
/// [_prepSecondsFor] below.
const int _kPrepSeconds = 5;

/// Resolve the effective prep-countdown seconds for a given exercise —
/// the practitioner's override if set, otherwise the global default.
int _prepSecondsFor(ExerciseCapture exercise) =>
    exercise.prepSeconds ?? _kPrepSeconds;

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

class _PlanPreviewScreenState extends State<PlanPreviewScreen>
    with SingleTickerProviderStateMixin {
  late final PageController _pageController;
  late final List<PreviewSlide> _slides;

  /// 600ms ease-in-out opacity cycle used by the top-bar counter chip during
  /// the prep phase. Same cadence as the web player (`prepFlash` keyframe)
  /// and the `_EtaDisplay` / `_Pill` flash animations — so if the user looks
  /// at both surfaces at once they perceive sync.
  late final AnimationController _prepFlashController;

  /// Matrix-ready slide list — same ordering as [_slides], carrying the
  /// circuit metadata the [ProgressPillMatrix] needs.
  late final List<ProgressPillSlide> _pillSlides;
  int _currentPage = 0;

  /// Video controllers keyed by *slide* index (not exercise index).
  /// Each slide gets its own controller even when the same exercise file
  /// appears in multiple slides — this avoids lifecycle conflicts.
  final Map<int, VideoPlayerController> _videoControllers = {};

  // ---------------------------------------------------------------------------
  // Three-treatment model (line / grayscale / original)
  //
  // The practitioner swipes between treatments via a segmented control
  // below the top bar. Default is [Treatment.line] — the de-identifying
  // baseline that never requires the client's sign-off. Grayscale and
  // original-colour depend on the client having opted in: when the
  // corresponding remote URL is null the segment is disabled.
  //
  // Segment state is per-session (not persisted) — every time the
  // preview opens it starts on Line.
  // ---------------------------------------------------------------------------

  Treatment _treatment = Treatment.line;

  /// Remote treatment URLs keyed by exercise id. Populated from
  /// `get_plan_full` after the screen mounts. Null URLs = segment
  /// disabled for that exercise. An empty map (not fetched yet, or RPC
  /// failed) collapses the segmented control — we don't want to surface
  /// a broken control in the fallback case.
  Map<String, ExerciseTreatmentUrls> _treatmentUrls = const {};
  bool _treatmentUrlsLoaded = false;

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

  /// Runtime mute state for the plan-preview video player. Decoupled from
  /// [ExerciseCapture.includeAudio], which is a publish-time preference
  /// ("ship audio to the client or not"). This flag is a playback-only
  /// override that applies across slides for the current preview session.
  ///
  /// Toggled via the speaker button in the top-right of every exercise
  /// page. Tapping it NEVER pauses the video (Wave 3 fix — see test plan
  /// items 3 / 4 / 5); it only flips volume between 0.0 and the
  /// exercise's native volume.
  bool _isMuted = false;

  @override
  void initState() {
    super.initState();
    _prepFlashController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat(reverse: true);
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
    // Seed from the initial slide's stored preference so the preview
    // lands on the treatment the practitioner last chose for this
    // exercise. Falls back to Line (the default) when preferredTreatment
    // is null.
    if (_slides.isNotEmpty) {
      _treatment = _slides[initial].exercise.preferredTreatment ??
          Treatment.line;
    }
    // Prepare the initial page's video if it is one
    _prepareVideo(initial);
    // Fetch remote treatment URLs for this plan — best-effort.
    // The preview stays fully functional (line-only local playback) if
    // the RPC is missing or the plan was never published.
    _fetchTreatmentUrls();
  }

  /// Pull the three per-exercise treatment URLs from `get_plan_full`.
  /// Silent fallback on any error: the segmented control collapses, the
  /// preview keeps playing the local converted file as before.
  Future<void> _fetchTreatmentUrls() async {
    final response =
        await ApiClient.instance.getPlanFull(widget.session.id);
    if (!mounted) return;
    final urls =
        ApiClient.instance.treatmentUrlsFromPlanResponse(response);
    setState(() {
      _treatmentUrls = urls;
      _treatmentUrlsLoaded = true;
    });
  }

  /// Remote URLs for the currently-active slide's exercise, or null if
  /// we haven't heard back from the server (or this plan was never
  /// published).
  ExerciseTreatmentUrls? _currentSlideUrls() {
    if (_slides.isEmpty) return null;
    final page = _currentPage.clamp(0, _slides.length - 1);
    final exercise = _slides[page].exercise;
    return _treatmentUrls[exercise.id];
  }

  /// True when a local source for [t] exists on the active slide. Line
  /// always has a converted file; B&W + Original need the 720p H.264
  /// archive (kept for 90d post-capture). Remote URLs are irrelevant
  /// here — the mobile preview is a local, offline-first surface.
  bool _isTreatmentAvailable(Treatment t) {
    if (t == Treatment.line) return true;
    if (_slides.isEmpty) return false;
    final exercise =
        _slides[_currentPage.clamp(0, _slides.length - 1)].exercise;
    final localPath = exercise.absoluteArchiveFilePath;
    return localPath != null && File(localPath).existsSync();
  }

  /// Practitioner tapped a segment. If the target treatment is available
  /// switch to it and reset media state for the active slide so the
  /// source swaps cleanly. Persists the choice on the current slide's
  /// exercise so next open defaults to this treatment.
  void _onTreatmentChanged(Treatment t) {
    if (_treatment == t) return;
    if (!_isTreatmentAvailable(t)) {
      _openConsentSheetForCurrent();
      return;
    }
    setState(() => _treatment = t);
    _persistPreferredTreatmentForCurrent(t);
    // Every existing controller points at the *previous* treatment's
    // source. Dispose them all so the lazy _prepareVideo pass rebuilds
    // with the new URL. For grayscale↔original the underlying network
    // URL is identical (the backend serves the original under both
    // keys); disposing the controller is still the cleanest way to
    // re-enter a consistent state because the ColorFilter wrapping is
    // widget-level, not controller-level.
    final allIndices = _videoControllers.keys.toList();
    for (final i in allIndices) {
      _disposeVideo(i);
    }
    // Re-prepare the active slide immediately; neighbours are prepared
    // lazily via _onPageChanged.
    _prepareVideo(_currentPage);
  }

  /// Persist [t] as the current slide's exercise `preferredTreatment`.
  ///
  /// Writes to local SQLite via the shared
  /// [SyncService.instance.storage] handle and mutates the in-memory
  /// [PreviewSlide.exercise] so a page-back-and-forth reads the new
  /// value without a disk round-trip.
  ///
  /// Fire-and-forget: the user has already seen the optimistic state
  /// change on the segmented control, so a DB hiccup doesn't need a UI
  /// surface. Logged via [debugPrint] for diagnostics.
  ///
  /// Idempotent per R-09: flipping back to Line re-writes Line as the
  /// explicit choice — an explicit user decision, not a silent reset
  /// to the implicit default.
  void _persistPreferredTreatmentForCurrent(Treatment t) {
    if (_slides.isEmpty) return;
    final page = _currentPage.clamp(0, _slides.length - 1);
    final slide = _slides[page];
    final original = slide.exercise;
    final updated = original.copyWith(preferredTreatment: t);

    // Rebuild the slide list with this one entry swapped out. A fresh
    // list (same length + ordering) keeps every other slide's
    // PreviewSlide metadata intact without any deep copy.
    _slides[page] = PreviewSlide(
      exercise: updated,
      originalIndex: slide.originalIndex,
      circuitRound: slide.circuitRound,
      circuitTotalRounds: slide.circuitTotalRounds,
      positionInCircuit: slide.positionInCircuit,
      circuitSize: slide.circuitSize,
    );

    unawaited(
      SyncService.instance.storage.saveExercise(updated).catchError((e, _) {
        debugPrint(
          'PlanPreview: saveExercise(preferred_treatment) failed: $e',
        );
      }),
    );
  }

  /// Open the client-consent bottom sheet so the practitioner can
  /// toggle the client's viewing preferences. Invoked from the lock
  /// tooltip on a disabled segment (R-09 affordance: the lock tells
  /// you why, the tap takes you to the fix).
  ///
  /// Resolves the target client by [Session.clientId] when set, else
  /// by [Session.clientName] within the current practice. Falls back
  /// to a gentle SnackBar when no client row is found (e.g. a legacy
  /// plan whose first publish predates the clients table).
  Future<void> _openConsentSheetForCurrent() async {
    final practiceId = AuthService.instance.currentPracticeId.value;
    if (practiceId == null || practiceId.isEmpty) return;

    final clients =
        await ApiClient.instance.listPracticeClients(practiceId);
    if (!mounted) return;

    PracticeClient? match;
    final cid = widget.session.clientId;
    if (cid != null) {
      for (final c in clients) {
        if (c.id == cid) {
          match = c;
          break;
        }
      }
    }
    if (match == null) {
      final lower = widget.session.clientName.toLowerCase();
      for (final c in clients) {
        if (c.name.toLowerCase() == lower) {
          match = c;
          break;
        }
      }
    }

    if (match == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Publish first to set viewing preferences.'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    await showClientConsentSheet(context, client: match);
    // When the practitioner returns, re-fetch so a just-flipped toggle
    // re-enables the segment live.
    if (mounted) {
      _fetchTreatmentUrls();
    }
  }

  @override
  void dispose() {
    _prepFlashController.dispose();
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
  ///
  /// Source selection follows the active [Treatment]:
  ///  - [Treatment.line] — remote `line_drawing_url` if present,
  ///    otherwise the local converted file (legacy path, works offline
  ///    and for plans that were never published).
  ///  - [Treatment.grayscale] — remote original video (grayscale is
  ///    applied at playback via a saturation-zero ColorFilter; the
  ///    backend returns the colour file under `grayscale_url`).
  ///  - [Treatment.original] — remote `original_url`.
  Future<void> _prepareVideo(int index) async {
    if (index < 0 || index >= _slides.length) return;
    final exercise = _slides[index].exercise;
    if (exercise.isRest) return;
    if (exercise.mediaType != MediaType.video) return;
    if (_isStillImageConversion(exercise)) return;
    if (_videoControllers.containsKey(index)) return;

    final controller = _controllerForTreatment(exercise);
    if (controller == null) {
      // No local source — legacy capture whose 90-day archive was
      // pruned, or a fresh-install scenario where the file never
      // existed on this device. Fall back to Line (the converted file
      // persists regardless) with a SnackBar explaining.
      if (_treatment != Treatment.line) {
        _fallbackToLine(index, showSnack: true);
      }
      return;
    }

    _videoControllers[index] = controller;

    // Set volume based on the exercise's includeAudio flag AND the
    // runtime mute toggle. Audio is always present in the file:
    //   * includeAudio=false → publish-time decision to not ship audio
    //     to the client. Video plays silently in the preview too.
    //   * _isMuted=true → runtime tap on the speaker button in the
    //     top-right. Decoupled from play/pause (Wave 3 fix).
    final volume = (exercise.includeAudio && !_isMuted) ? 1.0 : 0.0;

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
        // Safety net — the HEAD probe above handles the common 404
        // case BEFORE the controller is built, but a real init error
        // (DRM, codec, etc.) can still land here.
        debugPrint('Video init failed for slide $index ($_treatment): $e');
        if (!mounted) return;
        if (_videoControllers[index] == controller) {
          _videoControllers.remove(index);
          controller.dispose();
        }
        if (_treatment != Treatment.line) {
          _fallbackToLine(index, showSnack: true);
        }
      });
  }

  /// Fall back to Line treatment when a B&W / Original source is
  /// unavailable. Used when the local archive file is missing (pruned
  /// past 90d, or never existed on this device) and from the init-error
  /// safety net in [_prepareVideo].
  ///
  /// [showSnack] surfaces a brief "not available yet" toast when the
  /// local archive is genuinely missing; caller sets it to false when
  /// silent recovery is preferred.
  void _fallbackToLine(int index, {required bool showSnack}) {
    setState(() => _treatment = Treatment.line);
    _prepareVideo(index);
    if (showSnack) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'This treatment isn\'t available yet — showing line drawing.',
          ),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  /// Dispose a video controller for a slide that is no longer visible.
  void _disposeVideo(int index) {
    final controller = _videoControllers.remove(index);
    controller?.dispose();
  }

  /// Build the right [VideoPlayerController] for the active [_treatment].
  ///
  /// **Local-only.** The mobile preview is the practitioner's offline-
  /// first surface — everything must play from files on the phone, both
  /// pre- and post-publish. Remote signed URLs are for the web player
  /// (client-facing), never for this screen. Earlier "prefer remote"
  /// code was incorrect: it introduced latency, bandwidth waste, and
  /// fragility (the raw-archive 404 / AVPlayer-hang cascade that bit
  /// us through PRs #50, #51, #52 before inversion).
  ///
  /// Source resolution:
  ///   - Line      → `displayFilePath` (converted line-drawing file).
  ///   - Grayscale → `absoluteArchiveFilePath` (720p H.264 archive);
  ///                 desaturated at render time via ColorFilter matrix.
  ///   - Original  → `absoluteArchiveFilePath` (same archive).
  ///
  /// Returns null only when the local file is genuinely missing (legacy
  /// capture whose 90-day archive was pruned). Callers treat that as
  /// "fall back to Line with a SnackBar".
  VideoPlayerController? _controllerForTreatment(ExerciseCapture exercise) {
    switch (_treatment) {
      case Treatment.line:
        return VideoPlayerController.file(File(exercise.displayFilePath));
      case Treatment.grayscale:
      case Treatment.original:
        final localPath = exercise.absoluteArchiveFilePath;
        if (localPath == null || !File(localPath).existsSync()) return null;
        return VideoPlayerController.file(File(localPath));
    }
  }

  /// Called when the active page changes.
  void _onPageChanged(int index) {
    // Pause the outgoing page's video
    _videoControllers[_currentPage]?.pause();

    // Each slide reads its OWN exercise's preferredTreatment — moving
    // to a neighbour does NOT carry the prior treatment forward. If the
    // new slide's exercise has no stored preference (null), fall back
    // to Line (the safe default).
    final previousTreatment = _treatment;
    Treatment nextTreatment = _treatment;
    if (index >= 0 && index < _slides.length) {
      nextTreatment =
          _slides[index].exercise.preferredTreatment ?? Treatment.line;
    }

    setState(() {
      _currentPage = index;
      _treatment = nextTreatment;
    });

    // If the treatment changed due to per-exercise preference, dispose
    // existing controllers so _prepareVideo rebuilds with the new URL.
    if (nextTreatment != previousTreatment) {
      final allIndices = _videoControllers.keys.toList();
      for (final i in allIndices) {
        _disposeVideo(i);
      }
    }

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

  /// Begin the prep countdown for the current exercise slide. Default
  /// runway is 5s ([_kPrepSeconds]); each exercise can override via
  /// [ExerciseCapture.prepSeconds]. Ticks down once per second; on
  /// reaching 0, transitions into the running exercise timer. The video
  /// loops throughout as a motion reminder.
  void _startPrepPhase() {
    _workoutTimer?.cancel();
    final exercise = _slides[_currentPage].exercise;
    setState(() {
      _isPrepPhase = true;
      _prepRemainingSeconds = _prepSecondsFor(exercise);
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

  /// Toggle the runtime mute state and push the new volume to every
  /// already-initialised video controller. Decoupled from play/pause —
  /// tapping the speaker never affects playback state (Wave 3 test
  /// items 3 / 4 / 5). The new volume is 1.0 when both the exercise's
  /// `includeAudio` flag is on AND we're not muted; otherwise 0.0.
  void _toggleMute() {
    setState(() => _isMuted = !_isMuted);
    // Push the new volume to every in-memory controller. A controller
    // with includeAudio=false stays at 0.0 regardless (publish-time
    // opt-out); the runtime toggle only gates when includeAudio=true.
    for (final entry in _videoControllers.entries) {
      final controller = entry.value;
      if (!controller.value.isInitialized) continue;
      final exercise = _slides[entry.key].exercise;
      final volume = (exercise.includeAudio && !_isMuted) ? 1.0 : 0.0;
      controller.setVolume(volume);
    }
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

            // Treatment segmented control (line / B&W / original).
            // Hidden until the remote URLs have been fetched — we don't
            // want to flash a broken control while the RPC is still in
            // flight.
            if (_treatmentUrlsLoaded && _currentSlideUrls() != null) ...[
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TreatmentSegmentedControl(
                  active: _treatment,
                  grayscaleAvailable: _isTreatmentAvailable(Treatment.grayscale),
                  originalAvailable: _isTreatmentAvailable(Treatment.original),
                  onChanged: _onTreatmentChanged,
                  onLockTap: _openConsentSheetForCurrent,
                ),
              ),
            ],

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
                  isPrepPhase: _isPrepPhase,
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
                      // Prep overlay + flashing only apply to the active
                      // slide during prep phase on a non-rest exercise.
                      final isActivePrep = _isWorkoutMode &&
                          !_workoutComplete &&
                          _isPrepPhase &&
                          index == _currentPage &&
                          !slide.exercise.isRest;
                      return _ExercisePage(
                        slide: slide,
                        session: widget.session,
                        videoController: _videoControllers[index],
                        treatment: _treatment,
                        onTap: isActiveInWorkout ? _onTimerChipTap : null,
                        pausedOverlay: isActiveInWorkout &&
                            !_isTimerRunning &&
                            !_isPrepPhase,
                        isPrepPhase: isActivePrep,
                        prepSecondsRemaining: _prepRemainingSeconds,
                        prepTotalSeconds: _prepSecondsFor(slide.exercise),
                        isMuted: _isMuted,
                        onToggleMute: _toggleMute,
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

  /// Small inline timer ring rendered inside the metadata panel of the
  /// current slide. Replaces the old centred full-screen overlay so the
  /// timer sits next to the exercise name/badges instead of covering the
  /// media.
  ///
  /// Acts as a three-mode tappable control:
  ///  - Prep mode: ring counts 15→0, integer seconds, play icon.
  ///    Tap = skip prep.
  ///  - Running mode: ring counts down, M:SS, pause icon.
  ///    Tap = pause.
  ///  - Paused mode: ring frozen, M:SS, play icon.
  ///    Tap = resume.
  Widget _buildInlineTimerRing() {
    // Pick the values to render based on the current mode.
    final double progress;
    final Color color;
    final String label;
    final IconData actionIcon;

    if (_isPrepPhase) {
      // Prep: ring fills as the 15s count down toward 0.
      progress = _kPrepSeconds > 0
          ? (_kPrepSeconds - _prepRemainingSeconds) / _kPrepSeconds
          : 0.0;
      // Use the brand accent for prep so it reads as "get ready" rather
      // than the green→red of an in-progress exercise timer.
      color = AppColors.primary;
      label = '$_prepRemainingSeconds';
      actionIcon = Icons.play_arrow_rounded;
    } else {
      progress = _totalSeconds > 0
          ? (_totalSeconds - _remainingSeconds) / _totalSeconds
          : 0.0;
      if (_remainingSeconds > _totalSeconds * 0.25) {
        color = Colors.green;
      } else if (_remainingSeconds > _totalSeconds * 0.10) {
        color = Colors.amber;
      } else {
        color = Colors.red;
      }
      label = _formatTimer(_remainingSeconds);
      actionIcon = _isTimerRunning
          ? Icons.pause_rounded
          : Icons.play_arrow_rounded;
    }

    const size = 64.0;
    return GestureDetector(
      onTap: _onTimerChipTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            CustomPaint(
              size: const Size(size, size),
              painter: _TimerRingPainter(
                progress: progress,
                color: color,
                trackColor: Colors.white.withValues(alpha: 0.15),
                strokeWidth: 4,
              ),
            ),
            // Time label + small action icon stacked vertically inside ring.
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.5,
                    height: 1.0,
                  ),
                ),
                const SizedBox(height: 2),
                Icon(
                  actionIcon,
                  size: 11,
                  color: Colors.white70,
                ),
              ],
            ),
          ],
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
          //
          // NOTE: The shared `_PrepFlashWrapper` + `_prepFlashController`
          // from 059b828 live on, used instead by the matrix's ETA
          // bold-coral token and each active pill during prep phase.

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

  /// Which treatment the practitioner has selected via the segmented
  /// control. For [Treatment.grayscale] the video is wrapped in a
  /// saturation-zero ColorFilter at render time — the underlying source
  /// file is the original colour video.
  final Treatment treatment;

  /// Optional small timer ring shown in the bottom metadata panel during
  /// workout mode. DEPRECATED — superseded by tap-to-pause on the
  /// video/rest card body and the current-slide countdown in the pill
  /// matrix's top row. Kept on the widget's API to avoid churn during
  /// the transition but no longer rendered.
  final Widget? timerChip;

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

  /// True when this slide is currently in the 15-second prep phase.
  /// Drives the big centred countdown overlay on top of the media.
  final bool isPrepPhase;

  /// Seconds remaining on the prep countdown (15 → 1). Only meaningful when
  /// [isPrepPhase] is true.
  final int prepSecondsRemaining;

  /// Total prep duration — the effective value for THIS slide (per-
  /// exercise override if set, else [_kPrepSeconds]). Used to drive the
  /// fade-out-in-last-200ms easing on the overlay so the number doesn't pop
  /// when prep ends.
  final int prepTotalSeconds;

  /// Runtime mute state owned by the parent. Drives the speaker icon
  /// glyph (speaker / speaker-off) in the top-right of the media. Tap
  /// the icon to invoke [onToggleMute]; pause / resume are unaffected.
  final bool isMuted;

  /// Tap handler for the speaker-icon mute toggle. Fires whenever the
  /// user taps the top-right volume affordance. DOES NOT pause /
  /// resume playback (Wave 3 fix — decouple mute from play/pause).
  final VoidCallback? onToggleMute;

  const _ExercisePage({
    required this.slide,
    required this.session,
    this.videoController,
    this.treatment = Treatment.line,
    this.timerChip,
    this.onTap,
    this.pausedOverlay = false,
    this.isPrepPhase = false,
    this.prepSecondsRemaining = 0,
    this.prepTotalSeconds = 5,
    this.isMuted = false,
    this.onToggleMute,
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
                  // area stays tappable. Mutually exclusive with the
                  // prep-countdown overlay below (pausedOverlay is
                  // gated on !_isPrepPhase).
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
                  // Big prep-countdown overlay — sits above the media, below
                  // the metadata panel. Only present during the 15s prep of
                  // a non-rest exercise. Fades out in the last 200ms of prep
                  // so it doesn't pop when the exercise timer takes over.
                  if (widget.isPrepPhase)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: _PrepCountdownOverlay(
                          secondsRemaining: widget.prepSecondsRemaining,
                          totalSeconds: widget.prepTotalSeconds,
                        ),
                      ),
                    ),
                  // Circuit info + metadata overlay at bottom
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // _buildCircuitBar() removed — the progress-pill
                        // matrix above already communicates circuit
                        // membership + round-of-N, so the orange strip
                        // over the video was redundant signalling.
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

    // Wrap the VideoPlayer in a saturation-zero ColorFilter matrix when
    // the active treatment is grayscale. This is the cheap option that
    // avoids a platform channel — the underlying source is the original
    // colour file (the backend returns it under `grayscale_url`), and
    // Flutter desaturates it on the way to the framebuffer. See the
    // task brief: ColorFiltered vs CIFilter trade-off, we picked (b).
    Widget videoView = AspectRatio(
      aspectRatio: controller.value.aspectRatio,
      child: VideoPlayer(controller),
    );
    if (widget.treatment == Treatment.grayscale) {
      videoView = ColorFiltered(
        colorFilter: grayscaleColorFilter,
        child: videoView,
      );
    }

    return GestureDetector(
      onTap: _togglePlayPause,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Center(child: videoView),
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
          // Mute toggle — tappable speaker icon in the top-right. Only
          // surfaces when the exercise ships with audio (publish-time
          // `includeAudio`). Tapping toggles runtime mute without
          // pausing playback (Wave 3 fix — test items 3 / 4 / 5).
          // Glyph morphs: speaker when audible, speaker-off when muted.
          if (_exercise.includeAudio)
            Positioned(
              top: 12,
              right: 12,
              child: Material(
                color: Colors.transparent,
                shape: const CircleBorder(),
                clipBehavior: Clip.hardEdge,
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: widget.onToggleMute,
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: const BoxDecoration(
                      color: Colors.black45,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      widget.isMuted
                          ? Icons.volume_off_rounded
                          : Icons.volume_up_rounded,
                      size: 20,
                      color: Colors.white,
                      semanticLabel:
                          widget.isMuted ? 'Unmute audio' : 'Mute audio',
                    ),
                  ),
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
        color: AppColors.primary.withValues(alpha: 0.75),
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
  /// For rest slides the panel is slimmed down to just the timer chip so the
  /// rest-card content (icon, "Rest" label, "Next up") stays clean — the
  /// chip still sits in the same bottom-right slot as on exercise slides.
  Widget _buildMetadataOverlay() {
    if (_exercise.isRest) {
      if (widget.timerChip == null) return const SizedBox.shrink();
      return Container(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
        alignment: Alignment.centerRight,
        child: widget.timerChip!,
      );
    }
    final exercise = _exercise;

    // Exercise name + reps/sets/hold badges removed from the overlay:
    // the progress-pill matrix above now carries the active exercise
    // name (top row, left), and the pill itself encodes the shorthand
    // sets|reps|hold. Notes stay — they're the only instructional copy
    // the client sees, and can't be collapsed into a pill.
    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (exercise.notes != null && exercise.notes!.isNotEmpty)
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
    );

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
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(child: info),
          if (widget.timerChip != null) ...[
            const SizedBox(width: 16),
            widget.timerChip!,
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
// Prep flash wrapper — shared 600ms ease-in-out opacity cycle
// =============================================================================

/// Wraps a child in a synchronised opacity-flash animation while [flashing]
/// is true. When false, the child is rendered at full opacity without any
/// AnimatedBuilder rebuild churn.
///
/// Cadence: 600ms per half-cycle, ease-in-out, opacity 1.0 → 0.4 → 1.0.
/// Use the SAME [AnimationController] across every call site that needs to
/// stay in sync (top-bar counter chip + matrix ETA + active pill) so they
/// flash together.
class _PrepFlashWrapper extends StatelessWidget {
  final AnimationController controller;
  final bool flashing;
  final Widget child;

  const _PrepFlashWrapper({
    required this.controller,
    required this.flashing,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (!flashing) return child;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, inner) {
        // Controller is repeating with reverse=true, so .value already cycles
        // 0 → 1 → 0. We only need ease-in-out on top of that.
        final eased = Curves.easeInOut.transform(controller.value);
        final opacity = 1.0 - (eased * 0.6); // 1.0 → 0.4 → 1.0
        return Opacity(opacity: opacity, child: inner);
      },
      child: child,
    );
  }
}

// =============================================================================
// Prep countdown overlay — huge centred coral digit on top of the media
// =============================================================================

/// Big centred countdown number rendered over the media during the 15-second
/// prep phase. The demonstration video keeps playing underneath — this widget
/// is purely decorative (wrapped in IgnorePointer by the caller).
///
/// Fades from 0.85 opacity → 0 during the final 200ms of prep so it doesn't
/// pop when the exercise timer takes over. The digit itself scales
/// responsively based on the available height.
class _PrepCountdownOverlay extends StatelessWidget {
  final int secondsRemaining;
  final int totalSeconds;

  const _PrepCountdownOverlay({
    required this.secondsRemaining,
    required this.totalSeconds,
  });

  @override
  Widget build(BuildContext context) {
    // Opacity ramp: full 0.85 for most of prep, fading to 0 in the last 200ms.
    // The 1-second tick cadence means we can't do a true 200ms fade inside
    // the 1s window — instead, the last integer second (1 → 0) renders at a
    // reduced opacity to signal "about to disappear".
    final double targetOpacity = secondsRemaining <= 0
        ? 0.0
        : (secondsRemaining == 1 ? 0.45 : 0.85);

    return LayoutBuilder(
      builder: (context, constraints) {
        // Scale the digit to fit the available media area. Cap at 180 so we
        // don't blow past the metadata panel on tablets.
        final double size = (constraints.maxHeight * 0.45).clamp(96.0, 180.0);
        return Center(
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            opacity: targetOpacity,
            child: Text(
              '$secondsRemaining',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Montserrat',
                fontWeight: FontWeight.w800,
                fontSize: size,
                height: 1.0,
                letterSpacing: -4.0,
                color: AppColors.primary,
                shadows: const [
                  Shadow(
                    color: Colors.black54,
                    blurRadius: 24,
                    offset: Offset(0, 4),
                  ),
                ],
              ),
            ),
          ),
        );
      },
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

// =============================================================================
// Treatment segmented control extracted to widgets/treatment_segmented_control.dart
// so the studio fullscreen MediaViewer can reuse it. The grayscale ColorFilter
// (`grayscaleColorFilter`) lives there too.
// =============================================================================
