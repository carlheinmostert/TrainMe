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
let swipeState = { active: false, startX: 0, currentX: 0, startTime: 0 };

// Workout timer state
let isWorkoutMode = false;
let isTimerRunning = false;
let showPlayGate = false;
let remainingSeconds = 0;
let totalSeconds = 0;
let workoutTimer = null;
let workoutStartTime = null;

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
const $playGate = document.getElementById('play-gate');
const $playGateBtn = document.getElementById('play-gate-btn');
const $restCountdown = document.getElementById('rest-countdown');
const $restCountdownTime = document.getElementById('rest-countdown-time');
const $restCountdownNext = document.getElementById('rest-countdown-next');
const $workoutComplete = document.getElementById('workout-complete');
const $workoutTotalTime = document.getElementById('workout-total-time');
const $workoutCloseBtn = document.getElementById('workout-close-btn');
const $startWorkoutBtn = document.getElementById('start-workout-btn');
const $pauseBtn = document.getElementById('pause-btn');
const $pauseIcon = document.getElementById('pause-icon');
const $resumeIcon = document.getElementById('resume-icon');

// ============================================================
// Data fetching
// ============================================================

function getPlanIdFromURL() {
  const path = window.location.pathname;
  const match = path.match(/^\/p\/([a-zA-Z0-9_-]+)/);
  return match ? match[1] : null;
}

async function fetchPlan(planId) {
  // Uses the `get_plan_full` RPC so direct SELECT on plans/exercises can be
  // revoked — prevents table enumeration via the anon key.
  const response = await fetch(
    `${SUPABASE_URL}/rest/v1/rpc/get_plan_full`,
    {
      method: 'POST',
      headers: {
        'apikey': SUPABASE_ANON_KEY,
        'Authorization': `Bearer ${SUPABASE_ANON_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ plan_id: planId }),
    }
  );
  if (!response.ok) throw new Error('Plan not found');
  const data = await response.json();
  if (!data || !data.plan) throw new Error('Plan not found');
  const plan = data.plan;
  plan.exercises = Array.isArray(data.exercises) ? data.exercises : [];
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
  const duration = slide.hold_seconds || slide.custom_duration_seconds || 30;
  const nextSlide = index < slides.length - 1 ? slides[index + 1] : null;
  const nextUpName = nextSlide ? (nextSlide.name || 'Next exercise') : null;
  const circuitBar = buildCircuitBar(slide);

  const safeDuration = Number.parseInt(duration, 10) || 30;

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
          <div class="rest-duration">${safeDuration}s</div>
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
      <div class="video-play-overlay" data-video-index="${index}">
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

  currentIndex = index;
  updateUI();

  // If in workout mode and navigating manually (via skip buttons),
  // reset timer state for the new slide
  if (isWorkoutMode && !isTimerRunning && !showPlayGate) {
    // User skipped — show play gate for the new slide
    showPlayGateForCurrent();
  }
}

function goNext() {
  if (isWorkoutMode) {
    // Stop current timer when skipping
    if (workoutTimer) {
      clearInterval(workoutTimer);
      workoutTimer = null;
    }
    isTimerRunning = false;
    hideTimerDisplay();
    hidePlayGate();
    hideRestCountdown();
    showPlayGate = false;
  }
  goTo(currentIndex + 1);
}

function goPrev() {
  if (isWorkoutMode) {
    if (workoutTimer) {
      clearInterval(workoutTimer);
      workoutTimer = null;
    }
    isTimerRunning = false;
    hideTimerDisplay();
    hidePlayGate();
    hideRestCountdown();
    showPlayGate = false;
  }
  goTo(currentIndex - 1);
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
  document.querySelectorAll('.video-play-overlay').forEach(o => {
    o.classList.remove('is-hidden');
  });
}

// ============================================================
// Touch / Swipe Handling
// ============================================================

function onTouchStart(e) {
  if (e.touches.length > 1) return;

  swipeState.active = true;
  swipeState.startX = e.touches[0].clientX;
  swipeState.currentX = e.touches[0].clientX;
  swipeState.startTime = Date.now();

  $cardTrack.classList.add('is-swiping');
}

function onTouchMove(e) {
  if (!swipeState.active) return;

  swipeState.currentX = e.touches[0].clientX;
  const dx = swipeState.currentX - swipeState.startX;
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
    if (showPlayGate) {
      // Spacebar starts the exercise from play gate
      hidePlayGate();
      startTimer();
    } else if (isTimerRunning || remainingSeconds > 0) {
      togglePause();
    }
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
 * Enter workout mode
 */
function startWorkout() {
  isWorkoutMode = true;
  workoutStartTime = Date.now();

  // Hide the start button
  $startWorkoutBtn.hidden = true;

  // Go to the first slide
  goTo(0);

  // Show play gate on first exercise (or auto-start if rest)
  showPlayGateForCurrent();
}

/**
 * Show the play gate overlay, or auto-start for rest slides
 */
function showPlayGateForCurrent() {
  if (!isWorkoutMode) return;

  const slide = slides[currentIndex];
  if (!slide) {
    finishWorkout();
    return;
  }

  // Calculate duration for this slide
  totalSeconds = calculateDuration(slide);
  remainingSeconds = totalSeconds;

  if (slide.media_type === 'rest') {
    // Rest periods auto-start -- show rest countdown overlay
    hidePlayGate();
    showRestCountdown();
    startTimer();
  } else {
    // Exercise slides show play gate
    hideRestCountdown();
    hideTimerDisplay();
    showPlayGateOverlay();
  }
}

function showPlayGateOverlay() {
  showPlayGate = true;
  $playGate.hidden = false;
  $pauseBtn.hidden = true;
}

function hidePlayGate() {
  showPlayGate = false;
  $playGate.hidden = true;
}

function showRestCountdown() {
  const nextSlide = currentIndex < slides.length - 1 ? slides[currentIndex + 1] : null;
  const nextName = nextSlide ? (nextSlide.name || 'Next exercise') : '';

  $restCountdownTime.textContent = remainingSeconds;
  $restCountdownNext.textContent = nextName ? `Next up: ${nextName}` : '';
  $restCountdown.hidden = false;

  // Also show pause button during rest
  $pauseBtn.hidden = false;
  updatePauseButton();
}

function hideRestCountdown() {
  $restCountdown.hidden = true;
}

/**
 * Start the countdown timer for the current slide
 */
function startTimer() {
  if (workoutTimer) clearInterval(workoutTimer);

  isTimerRunning = true;
  updateTimerDisplay();
  showTimerDisplay();
  $pauseBtn.hidden = false;
  updatePauseButton();

  workoutTimer = setInterval(onTimerTick, 1000);
}

function showTimerDisplay() {
  const slide = slides[currentIndex];
  // Only show the SVG ring timer for non-rest slides
  if (slide && slide.media_type !== 'rest') {
    $timerOverlay.hidden = false;
  }
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
 * Update the visual timer display (ring + text)
 */
function updateTimerDisplay() {
  const slide = slides[currentIndex];

  if (slide && slide.media_type === 'rest') {
    // Update rest countdown number
    $restCountdownTime.textContent = remainingSeconds;
    return;
  }

  // Update text
  $timerText.textContent = formatTime(remainingSeconds);

  // Update SVG ring progress
  const progress = totalSeconds > 0 ? (1 - (remainingSeconds / totalSeconds)) : 0;
  const offset = TIMER_CIRCUMFERENCE * (1 - progress);
  $timerRingProgress.setAttribute('stroke-dashoffset', offset.toString());

  // Update color based on remaining percentage — stay on-brand (coral orange),
  // only shift to red in the final seconds for urgency.
  const pct = totalSeconds > 0 ? (remainingSeconds / totalSeconds) : 1;
  let color;
  if (pct <= 0.10) {
    color = '#EF4444'; // red — final urgency
  } else {
    color = '#FF6B35'; // coral orange (brand primary)
  }
  $timerRingProgress.setAttribute('stroke', color);
}

/**
 * Timer hit zero -- advance to next slide
 */
function onTimerComplete() {
  hideTimerDisplay();
  hideRestCountdown();
  $pauseBtn.hidden = true;

  // Move to next slide
  const nextIndex = currentIndex + 1;
  if (nextIndex >= slides.length) {
    finishWorkout();
    return;
  }

  goTo(nextIndex);

  // Show play gate for the new slide (or auto-start rest)
  showPlayGateForCurrent();
}

/**
 * Pause the running timer
 */
function pauseTimer() {
  if (!isTimerRunning) return;
  isTimerRunning = false;
  if (workoutTimer) {
    clearInterval(workoutTimer);
    workoutTimer = null;
  }
  updatePauseButton();
}

/**
 * Resume a paused timer
 */
function resumeTimer() {
  if (isTimerRunning) return;
  isTimerRunning = true;
  workoutTimer = setInterval(onTimerTick, 1000);
  updatePauseButton();
}

/**
 * Toggle pause/resume
 */
function togglePause() {
  if (isTimerRunning) {
    pauseTimer();
  } else {
    resumeTimer();
  }
}

function updatePauseButton() {
  $pauseIcon.hidden = !isTimerRunning;
  $resumeIcon.hidden = isTimerRunning;
}

/**
 * Show workout complete screen
 */
function finishWorkout() {
  // Stop any running timer
  if (workoutTimer) {
    clearInterval(workoutTimer);
    workoutTimer = null;
  }
  isTimerRunning = false;

  hideTimerDisplay();
  hidePlayGate();
  hideRestCountdown();
  $pauseBtn.hidden = true;

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
  showPlayGate = false;

  if (workoutTimer) {
    clearInterval(workoutTimer);
    workoutTimer = null;
  }

  workoutStartTime = null;

  $workoutComplete.hidden = true;
  hideTimerDisplay();
  hidePlayGate();
  hideRestCountdown();
  $pauseBtn.hidden = true;

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
          if (workoutTimer) {
            clearInterval(workoutTimer);
            workoutTimer = null;
          }
          isTimerRunning = false;
          hideTimerDisplay();
          hidePlayGate();
          hideRestCountdown();
          showPlayGate = false;
        }
        goTo(parseInt(dot.dataset.index, 10));
      }
    });

    // Workout timer events
    $startWorkoutBtn.addEventListener('click', startWorkout);
    $playGateBtn.addEventListener('click', () => {
      hidePlayGate();
      startTimer();
    });
    $pauseBtn.addEventListener('click', togglePause);
    $workoutCloseBtn.addEventListener('click', exitWorkout);

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
