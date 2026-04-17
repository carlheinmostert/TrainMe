/**
 * TrainMe Web Player
 * Static exercise plan viewer — clients open shared links from WhatsApp
 * to view their personalised training programmes.
 */

// ============================================================
// Configuration
// ============================================================

const SUPABASE_URL = 'https://yrwcofhovrcydootivjx.supabase.co';
const SUPABASE_ANON_KEY = 'sb_publishable_cwhfavfji552BN8X0uPIpA_pwWQ-gw3';

// ============================================================
// State
// ============================================================

let plan = null;
let slides = [];
let currentIndex = 0;
let swipeState = { active: false, startX: 0, startY: 0, currentX: 0, startTime: 0, didSwipe: false };

// Workout timer state
let isWorkoutMode = false;
let isTimerRunning = false;
let remainingSeconds = 0;
let totalSeconds = 0;
let workoutTimer = null;
let workoutStartTime = null;

// Prep-countdown state (15s runway before each non-rest exercise)
const PREP_SECONDS = 15;
let isPrepPhase = false;
let prepRemainingSeconds = 0;
let prepTimer = null;

// Timing constants (from config.dart)
const SECONDS_PER_REP = 3;
const REST_BETWEEN_SETS = 30;

// ============================================================
// DOM references
// ============================================================

const $loading = document.getElementById('loading');
const $error = document.getElementById('error');
const $app = document.getElementById('app');
const $clientName = document.getElementById('client-name');
const $planTitle = document.getElementById('plan-title');
const $progress = document.getElementById('progress');
const $progressFill = document.getElementById('progress-fill');
const $cardViewport = document.getElementById('card-viewport');
const $cardTrack = document.getElementById('card-track');
const $navDots = document.getElementById('nav-dots');
const $btnPrev = document.getElementById('btn-prev');
const $btnNext = document.getElementById('btn-next');

// Workout timer DOM refs
const $timerOverlay = document.getElementById('timer-overlay');
const $timerRingProgress = document.getElementById('timer-ring-progress');
const $timerText = document.getElementById('timer-text');
const $timerModeIconPlay = document.getElementById('timer-mode-icon-play');
const $timerModeIconPause = document.getElementById('timer-mode-icon-pause');
const $workoutComplete = document.getElementById('workout-complete');
const $workoutTotalTime = document.getElementById('workout-total-time');
const $workoutCloseBtn = document.getElementById('workout-close-btn');
const $startWorkoutBtn = document.getElementById('start-workout-btn');

// ============================================================
// Data fetching
// ============================================================

function getPlanIdFromURL() {
  const path = window.location.pathname;
  const match = path.match(/^\/p\/([a-zA-Z0-9_-]+)/);
  return match ? match[1] : null;
}

async function fetchPlan(planId) {
  // POV phase: tables are open via permissive RLS, so we read directly.
  // A future hardening pass should switch to the `get_plan_full` SECURITY
  // DEFINER RPC (see supabase/schema_hardening.sql) to prevent enumeration.
  //
  // Milestone A note (see supabase/schema_milestone_a.sql): the get_plan_full
  // RPC stamps `first_opened_at` atomically on the first fetch. That column
  // feeds the future publish-lock rule (once a client opens a plan, the bio
  // can no longer add/reorder/swap exercises — delete stays free). When this
  // client swaps to the RPC, first_opened_at will get set automatically with
  // no client-side code change required here.
  const response = await fetch(
    `${SUPABASE_URL}/rest/v1/plans?id=eq.${planId}&select=*,exercises(*)`,
    {
      headers: {
        'apikey': SUPABASE_ANON_KEY,
        'Authorization': `Bearer ${SUPABASE_ANON_KEY}`,
      }
    }
  );
  if (!response.ok) throw new Error('Plan not found');
  const data = await response.json();
  if (!data.length) throw new Error('Plan not found');
  const plan = data[0];
  plan.exercises.sort((a, b) => a.position - b.position);
  return plan;
}

// ============================================================
// Circuit Unrolling
// ============================================================

function unrollExercises(plan) {
  const exercises = plan.exercises;
  const cycles = plan.circuit_cycles || {};
  const result = [];
  let i = 0;
  while (i < exercises.length) {
    const ex = exercises[i];
    if (!ex.circuit_id) {
      result.push({ ...ex, circuitRound: null, circuitTotalRounds: null, positionInCircuit: null, circuitSize: null });
      i++;
    } else {
      const circuitId = ex.circuit_id;
      const group = [];
      while (i < exercises.length && exercises[i].circuit_id === circuitId) {
        group.push(exercises[i]);
        i++;
      }
      const totalRounds = Number.parseInt(cycles[circuitId], 10) || 3;
      for (let round = 1; round <= totalRounds; round++) {
        group.forEach((gex, idx) => {
          result.push({
            ...gex,
            circuitRound: round,
            circuitTotalRounds: totalRounds,
            positionInCircuit: idx + 1,
            circuitSize: group.length,
          });
        });
      }
    }
  }
  return result;
}

// ============================================================
// Rendering
// ============================================================

function renderPlan() {
  $clientName.textContent = plan.client_name;
  $planTitle.textContent = plan.title;

  // Build navigation dots (i is always a numeric loop index — safe)
  $navDots.innerHTML = slides
    .map((_, i) => `<div class="nav-dot${i === 0 ? ' is-active' : ''}" data-index="${Number(i)}"></div>`)
    .join('');

  // Build exercise cards
  $cardTrack.innerHTML = slides.map((slide, i) => buildCard(slide, i)).join('');

  // Add swipe hint on first card
  if (slides.length > 1) {
    const hint = document.createElement('div');
    hint.className = 'swipe-hint';
    hint.innerHTML = `
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
        <polyline points="15 18 9 12 15 6"></polyline>
      </svg>
      Swipe to navigate
    `;
    $cardViewport.appendChild(hint);
  }

  updateUI();
}

function buildCard(slide, index) {
  // Rest card
  if (slide.media_type === 'rest') {
    return buildRestCard(slide, index);
  }

  const prescriptionPills = buildPrescription(slide);
  const mediaHTML = buildMedia(slide, index);
  const circuitBar = buildCircuitBar(slide);

  const displayName = slide.name || ('Exercise ' + (index + 1));

  return `
    <div class="exercise-card" data-index="${index}">
      <div class="card-inner">
        ${circuitBar}
        <div class="card-media">
          ${mediaHTML}
        </div>
        <div class="card-body">
          <div class="card-position">Exercise ${Number.parseInt(slide.position, 10) || index + 1}</div>
          <div class="card-exercise-name">${escapeHTML(displayName)}</div>
          ${prescriptionPills ? `<div class="card-prescription">${prescriptionPills}</div>` : ''}
          ${slide.notes ? `<div class="card-notes">${escapeHTML(slide.notes)}</div>` : ''}
        </div>
      </div>
    </div>
  `;
}

function buildRestCard(slide, index) {
  // Rest card: icon + "Rest" title + "Next up: X" subtitle only.
  // The numeric countdown is owned by the bottom-right timer chip in
  // workout mode — no duplication here.
  const nextSlide = index < slides.length - 1 ? slides[index + 1] : null;
  const nextUpName = nextSlide ? (nextSlide.name || 'Next exercise') : null;
  const circuitBar = buildCircuitBar(slide);

  return `
    <div class="exercise-card" data-index="${index}">
      <div class="card-inner rest-card">
        ${circuitBar}
        <div class="rest-display">
          <div class="rest-icon">
            <svg viewBox="0 0 64 64" fill="none" xmlns="http://www.w3.org/2000/svg">
              <circle cx="32" cy="32" r="28" stroke="currentColor" stroke-width="2" opacity="0.3"/>
              <circle cx="32" cy="32" r="20" stroke="currentColor" stroke-width="2" opacity="0.2"/>
              <circle cx="32" cy="32" r="12" stroke="currentColor" stroke-width="2" opacity="0.15"/>
              <path d="M32 20v12l8 8" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"/>
            </svg>
          </div>
          <div class="rest-title">Rest</div>
          ${nextUpName ? `<div class="rest-next-up">Next up: ${escapeHTML(nextUpName)}</div>` : ''}
        </div>
      </div>
    </div>
  `;
}

function buildCircuitBar(slide) {
  if (!slide.circuitRound) return '';
  const round = Number.parseInt(slide.circuitRound, 10) || 1;
  const totalRounds = Number.parseInt(slide.circuitTotalRounds, 10) || 1;
  const posInCircuit = Number.parseInt(slide.positionInCircuit, 10) || 1;
  const circuitSize = Number.parseInt(slide.circuitSize, 10) || 1;
  return `<div class="circuit-bar">Circuit &middot; Round ${round} of ${totalRounds} &middot; Exercise ${posInCircuit} of ${circuitSize}</div>`;
}

function buildMedia(exercise, index) {
  if (!exercise.media_url) {
    // Placeholder for exercises without media yet
    return `
      <div class="media-placeholder">
        <div class="media-placeholder-icon">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
            ${exercise.media_type === 'video'
              ? '<polygon points="5 3 19 12 5 21 5 3"></polygon>'
              : '<rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="8.5" cy="8.5" r="1.5"/><path d="m21 15-5-5L5 21"/>'
            }
          </svg>
        </div>
        <span class="media-placeholder-text">${exercise.media_type === 'video' ? 'Video' : 'Image'} coming soon</span>
      </div>
    `;
  }

  if (exercise.media_type === 'video') {
    const mutedAttr = exercise.include_audio ? '' : 'muted';
    const posterAttr = exercise.thumbnail_url ? `poster="${escapeHTML(exercise.thumbnail_url)}"` : '';
    return `
      <video
        id="video-${index}"
        src="${escapeHTML(exercise.media_url)}"
        playsinline
        loop
        ${mutedAttr}
        preload="auto"
        ${posterAttr}
      ></video>
      <div class="video-play-overlay is-hidden" data-video-index="${index}">
        <div class="play-button">
          <svg viewBox="0 0 24 24"><polygon points="6 3 20 12 6 21 6 3"></polygon></svg>
        </div>
      </div>
    `;
  }

  // Photo / image
  const posterAttr = exercise.thumbnail_url ? exercise.thumbnail_url : exercise.media_url;
  return `<img src="${escapeHTML(posterAttr)}" alt="${escapeHTML(exercise.name || 'Exercise')}" loading="lazy">`;
}

function buildPrescription(exercise) {
  const pills = [];

  if (exercise.reps != null) {
    const reps = Number.parseInt(exercise.reps, 10);
    if (Number.isFinite(reps)) {
      pills.push(`<span class="rx-pill">${reps} <span class="rx-pill-label">reps</span></span>`);
    }
  }
  if (exercise.sets != null) {
    const sets = Number.parseInt(exercise.sets, 10);
    if (Number.isFinite(sets)) {
      pills.push(`<span class="rx-pill">${sets} <span class="rx-pill-label">sets</span></span>`);
    }
  }
  if (exercise.hold_seconds != null) {
    const hold = Number.parseInt(exercise.hold_seconds, 10);
    if (Number.isFinite(hold)) {
      const label = hold >= 60
        ? `${Math.floor(hold / 60)}m ${hold % 60 ? (hold % 60) + 's' : ''}`
        : `${hold}s`;
      pills.push(`<span class="rx-pill">${label} <span class="rx-pill-label">hold</span></span>`);
    }
  }

  return pills.join('');
}

function escapeHTML(str) {
  if (str === null || str === undefined || str === '') return '';
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;')
    .replace(/\//g, '&#47;');
}

// ============================================================
// Navigation
// ============================================================

function goTo(index) {
  if (index < 0 || index >= slides.length) return;

  // Pause any playing videos on current card
  pauseAllVideos();

  // Cancel any in-flight prep countdown; the new slide gets its own setup.
  clearPrepTimer();

  currentIndex = index;
  updateUI();

  // Auto-play the current slide's video (muted, looped). Safari's autoplay
  // policy may block this if there hasn't been a user gesture yet — swallow
  // the rejection so we don't crash. The first gesture (tap on the URL /
  // Start Workout button) typically unlocks it.
  autoPlayCurrentVideo();

  if (isWorkoutMode) {
    // New slide in workout mode — start prep or auto-start rest
    enterWorkoutPhaseForCurrent();
  }
}

function goNext() {
  if (isWorkoutMode) {
    // Stop current timer when skipping
    clearWorkoutTimer();
    clearPrepTimer();
    isTimerRunning = false;
    isPrepPhase = false;
    hideTimerDisplay();
  }
  goTo(currentIndex + 1);
}

function goPrev() {
  if (isWorkoutMode) {
    clearWorkoutTimer();
    clearPrepTimer();
    isTimerRunning = false;
    isPrepPhase = false;
    hideTimerDisplay();
  }
  goTo(currentIndex - 1);
}

function clearWorkoutTimer() {
  if (workoutTimer) {
    clearInterval(workoutTimer);
    workoutTimer = null;
  }
}

function clearPrepTimer() {
  if (prepTimer) {
    clearInterval(prepTimer);
    prepTimer = null;
  }
  isPrepPhase = false;
}

function autoPlayCurrentVideo() {
  const currentVideo = document.getElementById(`video-${currentIndex}`);
  if (!currentVideo) return;
  const overlay = $cardTrack.querySelector(
    `.video-play-overlay[data-video-index="${currentIndex}"]`
  );
  if (overlay) overlay.classList.add('is-hidden');
  currentVideo.play().catch((err) => {
    console.warn('video autoplay blocked:', err);
  });
}

function updateUI() {
  const total = slides.length;

  // Slide the track
  $cardTrack.style.transform = `translateX(-${currentIndex * 100}%)`;

  // Progress text
  $progress.textContent = `${currentIndex + 1} of ${total}`;

  // Progress bar
  $progressFill.style.width = `${((currentIndex + 1) / total) * 100}%`;

  // Nav buttons
  $btnPrev.disabled = currentIndex === 0;
  $btnNext.disabled = currentIndex === total - 1;

  // Dots
  const dots = $navDots.querySelectorAll('.nav-dot');
  dots.forEach((dot, i) => {
    dot.classList.toggle('is-active', i === currentIndex);
  });
}

// ============================================================
// Video Playback
// ============================================================

function handleVideoTap(e) {
  const overlay = e.target.closest('.video-play-overlay');
  if (!overlay) return;

  const videoIndex = parseInt(overlay.dataset.videoIndex, 10);
  const video = document.getElementById(`video-${videoIndex}`);
  if (!video) return;

  if (video.paused) {
    video.play();
    overlay.classList.add('is-hidden');
  } else {
    video.pause();
    overlay.classList.remove('is-hidden');
  }
}

function pauseAllVideos() {
  document.querySelectorAll('video').forEach(v => {
    v.pause();
  });
  // Per-video play overlay is hidden by default; we only reveal it when the
  // user manually pauses the current slide's video via tap (see handleVideoTap).
  document.querySelectorAll('.video-play-overlay').forEach(o => {
    o.classList.add('is-hidden');
  });
}

// ============================================================
// Touch / Swipe Handling
// ============================================================

function onTouchStart(e) {
  if (e.touches.length > 1) return;

  swipeState.active = true;
  swipeState.startX = e.touches[0].clientX;
  swipeState.startY = e.touches[0].clientY;
  swipeState.currentX = e.touches[0].clientX;
  swipeState.startTime = Date.now();
  swipeState.didSwipe = false;

  $cardTrack.classList.add('is-swiping');
}

function onTouchMove(e) {
  if (!swipeState.active) return;

  swipeState.currentX = e.touches[0].clientX;
  const dx = swipeState.currentX - swipeState.startX;
  const dy = e.touches[0].clientY - swipeState.startY;

  // Track whether this gesture became a swipe. Used by the overlays to
  // suppress the synthetic click (pause/resume) when the user was navigating.
  if (Math.abs(dx) > 10 && Math.abs(dx) > Math.abs(dy)) {
    swipeState.didSwipe = true;
  }

  const viewportWidth = $cardViewport.offsetWidth;

  // Add resistance at edges
  let effectiveDx = dx;
  if ((currentIndex === 0 && dx > 0) || (currentIndex === slides.length - 1 && dx < 0)) {
    effectiveDx = dx * 0.25;
  }

  const offset = -(currentIndex * viewportWidth) + effectiveDx;
  $cardTrack.style.transform = `translateX(${offset}px)`;
}

function onTouchEnd() {
  if (!swipeState.active) return;
  swipeState.active = false;

  $cardTrack.classList.remove('is-swiping');

  const dx = swipeState.currentX - swipeState.startX;
  const dt = Date.now() - swipeState.startTime;
  const viewportWidth = $cardViewport.offsetWidth;
  const velocity = Math.abs(dx) / dt;

  // Threshold: 25% of viewport width or fast swipe
  const threshold = viewportWidth * 0.25;
  const isFastSwipe = velocity > 0.5 && Math.abs(dx) > 30;

  if ((Math.abs(dx) > threshold || isFastSwipe) && dx < 0) {
    goNext();
  } else if ((Math.abs(dx) > threshold || isFastSwipe) && dx > 0) {
    goPrev();
  } else {
    updateUI(); // snap back
  }
}

// ============================================================
// Keyboard Navigation
// ============================================================

function onKeyDown(e) {
  if (e.key === 'ArrowRight' || e.key === 'ArrowDown') {
    e.preventDefault();
    goNext();
  } else if (e.key === 'ArrowLeft' || e.key === 'ArrowUp') {
    e.preventDefault();
    goPrev();
  } else if (e.key === ' ' && isWorkoutMode) {
    e.preventDefault();
    handleTimerOverlayTap();
  }
}

// ============================================================
// Workout Timer
// ============================================================

const TIMER_CIRCUMFERENCE = 2 * Math.PI * 54; // ~339.29

/**
 * Calculate the duration in seconds for an exercise slide.
 * Uses custom_duration_seconds if set, otherwise computes from reps/sets/hold.
 */
function calculateDuration(slide) {
  if (slide.custom_duration_seconds) {
    return slide.custom_duration_seconds;
  }

  if (slide.media_type === 'rest') {
    return slide.hold_seconds || slide.custom_duration_seconds || 30;
  }

  const reps = slide.reps || 10;
  const sets = slide.sets || 3;
  const holdPerSet = slide.hold_seconds || 0;
  const perSet = (reps * SECONDS_PER_REP) + holdPerSet;
  const restTotal = (sets - 1) * REST_BETWEEN_SETS;
  return (perSet * sets) + restTotal;
}

/**
 * Format seconds as m:ss
 */
function formatTime(seconds) {
  const m = Math.floor(seconds / 60);
  const s = seconds % 60;
  return `${m}:${s.toString().padStart(2, '0')}`;
}

/**
 * Enter workout mode. Calling goTo(0) triggers the prep-or-rest flow for the
 * first slide via enterWorkoutPhaseForCurrent().
 */
function startWorkout() {
  isWorkoutMode = true;
  workoutStartTime = Date.now();

  // Hide the start button
  $startWorkoutBtn.hidden = true;

  if (currentIndex === 0) {
    // Already on the first slide — goTo() short-circuits when index is
    // unchanged, so manually kick off the workout phase.
    autoPlayCurrentVideo();
    enterWorkoutPhaseForCurrent();
  } else {
    goTo(0);
  }
}

/**
 * Called whenever workout mode enters a slide. Non-rest slides get a 15s prep
 * countdown first; rest slides auto-start their countdown immediately.
 */
function enterWorkoutPhaseForCurrent() {
  if (!isWorkoutMode) return;

  const slide = slides[currentIndex];
  if (!slide) {
    finishWorkout();
    return;
  }

  totalSeconds = calculateDuration(slide);
  remainingSeconds = totalSeconds;

  if (slide.media_type === 'rest') {
    // Rest — no prep, auto-start countdown. The bottom-right timer chip
    // is the single source of truth for the rest countdown.
    startTimer();
  } else {
    // Exercise — run 15s prep runway, then startTimer()
    startPrepPhase();
  }
}

/**
 * Begin the 15-second prep countdown. The timer chip shows the prep seconds
 * with a play-arrow glyph; tapping the chip skips to the running phase.
 */
function startPrepPhase() {
  clearPrepTimer();
  clearWorkoutTimer();

  isPrepPhase = true;
  isTimerRunning = false;
  prepRemainingSeconds = PREP_SECONDS;

  updateTimerDisplay();
  showTimerDisplay();

  prepTimer = setInterval(onPrepTick, 1000);
}

function onPrepTick() {
  if (!isPrepPhase) return;
  prepRemainingSeconds--;

  if (prepRemainingSeconds <= 0) {
    finishPrepPhase();
    return;
  }
  updateTimerDisplay();
}

function finishPrepPhase() {
  clearPrepTimer();
  startTimer();
}

/**
 * Start the countdown timer for the current slide
 */
function startTimer() {
  clearWorkoutTimer();
  clearPrepTimer();

  isTimerRunning = true;
  updateTimerDisplay();
  showTimerDisplay();

  workoutTimer = setInterval(onTimerTick, 1000);
}

function showTimerDisplay() {
  // Show the timer chip for every slide in workout mode — including rest
  // slides. The chip is the single source of truth for the countdown.
  $timerOverlay.hidden = false;
}

function hideTimerDisplay() {
  $timerOverlay.hidden = true;
}

/**
 * Called every second while timer is running
 */
function onTimerTick() {
  if (!isTimerRunning) return;

  remainingSeconds--;

  if (remainingSeconds <= 0) {
    remainingSeconds = 0;
    updateTimerDisplay();
    clearInterval(workoutTimer);
    workoutTimer = null;
    isTimerRunning = false;

    // Auto-advance
    onTimerComplete();
    return;
  }

  updateTimerDisplay();
}

/**
 * Update the visual timer display (ring + text + mode icon). Handles three
 * modes: prep (counts 15→0, shows integer seconds + play arrow), running
 * (counts down, shows M:SS + pause glyph), paused (frozen, M:SS + play arrow).
 */
function updateTimerDisplay() {
  if (isPrepPhase) {
    // Prep mode: integer seconds, play-arrow icon, ring counts 15→0.
    $timerText.textContent = String(Math.max(0, prepRemainingSeconds));
    const progress = PREP_SECONDS > 0
      ? (1 - (prepRemainingSeconds / PREP_SECONDS))
      : 0;
    const offset = TIMER_CIRCUMFERENCE * (1 - progress);
    $timerRingProgress.setAttribute('stroke-dashoffset', offset.toString());
    $timerRingProgress.setAttribute('stroke', '#FF6B35');
    setTimerModeIcon('play');
    return;
  }

  // Running / paused mode
  $timerText.textContent = formatTime(remainingSeconds);

  const progress = totalSeconds > 0 ? (1 - (remainingSeconds / totalSeconds)) : 0;
  const offset = TIMER_CIRCUMFERENCE * (1 - progress);
  $timerRingProgress.setAttribute('stroke-dashoffset', offset.toString());

  // Red only in final 10% of the exercise for urgency; otherwise coral.
  const pct = totalSeconds > 0 ? (remainingSeconds / totalSeconds) : 1;
  $timerRingProgress.setAttribute('stroke', pct <= 0.10 ? '#EF4444' : '#FF6B35');

  setTimerModeIcon(isTimerRunning ? 'pause' : 'play');
}

function setTimerModeIcon(mode) {
  // mode: 'play' or 'pause'
  $timerModeIconPlay.hidden = mode !== 'play';
  $timerModeIconPause.hidden = mode !== 'pause';
}

/**
 * Timer hit zero -- advance to next slide. goTo() re-enters the workout
 * phase (prep for exercises, auto-start for rest) for the new slide.
 */
function onTimerComplete() {
  hideTimerDisplay();

  const nextIndex = currentIndex + 1;
  if (nextIndex >= slides.length) {
    finishWorkout();
    return;
  }

  goTo(nextIndex);
}

/**
 * Pause the running timer
 */
function pauseTimer() {
  if (!isTimerRunning) return;
  isTimerRunning = false;
  clearWorkoutTimer();
  // Keep the video in sync so it doesn't keep playing while the timer is paused.
  const currentVideo = document.getElementById(`video-${currentIndex}`);
  if (currentVideo && !currentVideo.paused) {
    currentVideo.pause();
  }
  updateTimerDisplay();
}

/**
 * Resume a paused timer
 */
function resumeTimer() {
  if (isTimerRunning) return;
  isTimerRunning = true;
  workoutTimer = setInterval(onTimerTick, 1000);
  // Resume video playback alongside the timer.
  const currentVideo = document.getElementById(`video-${currentIndex}`);
  if (currentVideo && currentVideo.paused) {
    currentVideo.play().catch((err) => {
      console.warn('video resume failed:', err);
    });
  }
  updateTimerDisplay();
}

/**
 * Single tap handler for the timer chip. Dispatches
 * based on current mode: prep → skip, running → pause, paused → resume.
 *
 * When the user just finished swiping horizontally on this overlay, the
 * browser still fires a synthetic click on touchend. Bail out so the swipe
 * doesn't also toggle pause/resume.
 */
function handleTimerOverlayTap() {
  if (!isWorkoutMode) return;
  if (swipeState.didSwipe) {
    swipeState.didSwipe = false;
    return;
  }
  if (isPrepPhase) {
    finishPrepPhase();
    return;
  }
  if (isTimerRunning) {
    pauseTimer();
  } else if (remainingSeconds > 0) {
    resumeTimer();
  }
}

/**
 * Show workout complete screen
 */
function finishWorkout() {
  clearWorkoutTimer();
  clearPrepTimer();
  isTimerRunning = false;

  hideTimerDisplay();

  // Calculate total workout time
  const elapsedMs = Date.now() - workoutStartTime;
  const elapsedSeconds = Math.round(elapsedMs / 1000);
  $workoutTotalTime.textContent = `Total time: ${formatTime(elapsedSeconds)}`;

  $workoutComplete.hidden = false;
}

/**
 * Close workout mode and return to browse
 */
function exitWorkout() {
  isWorkoutMode = false;
  isTimerRunning = false;

  clearWorkoutTimer();
  clearPrepTimer();

  workoutStartTime = null;

  $workoutComplete.hidden = true;
  hideTimerDisplay();

  // Show the start workout button again
  $startWorkoutBtn.hidden = false;
}

// ============================================================
// Service Worker Registration
// ============================================================

async function registerServiceWorker() {
  if ('serviceWorker' in navigator) {
    try {
      await navigator.serviceWorker.register('/sw.js');
    } catch (err) {
      console.warn('Service worker registration failed:', err);
    }
  }
}

// ============================================================
// Initialisation
// ============================================================

async function init() {
  registerServiceWorker();

  const planId = getPlanIdFromURL();

  try {
    plan = await fetchPlan(planId);

    if (!plan || !plan.exercises || plan.exercises.length === 0) {
      throw new Error('Empty plan');
    }

    // Sort exercises by position
    plan.exercises.sort((a, b) => a.position - b.position);

    // Unroll circuits into flat slides array
    slides = unrollExercises(plan);

    // Render
    renderPlan();

    // Show app
    $loading.classList.add('fade-out');
    setTimeout(() => {
      $loading.hidden = true;
      $app.hidden = false;
    }, 250);

    // Bind events
    $btnNext.addEventListener('click', goNext);
    $btnPrev.addEventListener('click', goPrev);
    $cardViewport.addEventListener('touchstart', onTouchStart, { passive: true });
    $cardViewport.addEventListener('touchmove', onTouchMove, { passive: true });
    $cardViewport.addEventListener('touchend', onTouchEnd);
    $cardViewport.addEventListener('click', handleVideoTap);
    document.addEventListener('keydown', onKeyDown);

    // Dot navigation
    $navDots.addEventListener('click', (e) => {
      const dot = e.target.closest('.nav-dot');
      if (dot) {
        if (isWorkoutMode) {
          // Reset timer when jumping via dots
          clearWorkoutTimer();
          clearPrepTimer();
          isTimerRunning = false;
          hideTimerDisplay();
        }
        goTo(parseInt(dot.dataset.index, 10));
      }
    });

    // Workout timer events
    $startWorkoutBtn.addEventListener('click', startWorkout);
    $workoutCloseBtn.addEventListener('click', exitWorkout);

    // Timer chip is the only pause/play control — one tappable element that
    // dispatches based on mode (prep / running / paused). It shows on all
    // slides in workout mode, including rest slides.
    $timerOverlay.addEventListener('click', handleTimerOverlayTap);

    // Try to autoplay the first slide's video on initial load. The fetchPlan
    // click that opened the URL should have unlocked autoplay on iOS Safari,
    // but we swallow the rejection defensively if the browser blocks it.
    autoPlayCurrentVideo();

    // Show the Start Workout button
    $startWorkoutBtn.hidden = false;

  } catch (err) {
    console.error('Failed to load plan:', err);
    $loading.hidden = true;
    $error.hidden = false;
  }
}

// Start the app
init();
