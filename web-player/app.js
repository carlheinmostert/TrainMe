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
const $cardViewport = document.getElementById('card-viewport');
const $cardTrack = document.getElementById('card-track');
const $navDots = document.getElementById('nav-dots');
const $btnPrev = document.getElementById('btn-prev');
const $btnNext = document.getElementById('btn-next');

// Progress-pill matrix refs
const $matrix = document.getElementById('progress-matrix');
const $matrixInner = document.getElementById('progress-matrix-inner');
const $matrixChevron = document.getElementById('progress-matrix-chevron');
const $peekPanel = document.getElementById('peek-panel');
const $peekName = document.getElementById('peek-name');
const $peekMeta = document.getElementById('peek-meta');

// ETA refs (assigned after buildProgressMatrix injects them).
// Item 4: three separate numbers — current-slide remaining, total remaining,
// wall-clock finish. Each styled independently so the coral/white/muted
// treatment reads at a glance.
let $etaBlock = null;
let $etaCurrent = null;
let $etaTotal = null;
let $etaFinish = null;

// Wall-clock ticker for the ETA widget. Runs 1/sec so the finish-time label
// keeps drifting forward while the workout is paused (remaining holds steady,
// now() advances → finish = now + remaining also advances). Independent of
// the workoutTimer and prepTimer.
let etaClockTimer = null;

// Workout timer DOM refs (legacy chip is gone per item 7 — see the stub
// <div id="timer-overlay" hidden> kept for backward compatibility).
const $timerOverlay = document.getElementById('timer-overlay');
const $workoutComplete = document.getElementById('workout-complete');
const $workoutTotalTime = document.getElementById('workout-total-time');
const $workoutCloseBtn = document.getElementById('workout-close-btn');
const $startWorkoutBtn = document.getElementById('start-workout-btn');
const $footerLogo = document.getElementById('footer-logo');

// Teaching-peek timer (R-09: auto-shows the peek card for 2s on preview start
// so the user learns the vocabulary once).
let teachingPeekTimer = null;

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

  // Build the progress-pill matrix (replaces legacy single linear bar).
  buildProgressMatrix();

  // Prime the ETA widget and start its wall-clock ticker. The ticker runs
  // for the lifetime of the session so the finish-time drifts forward even
  // during paused states.
  updateEtaDisplay();
  startEtaClock();

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

  const mediaHTML = buildMedia(slide, index);
  const displayName = slide.name || ('Exercise ' + (index + 1));
  const detail = buildActiveSlideDetail(slide);
  // Circuit bar was removed per item 14 — circuit context now lives in the
  // progress-pill matrix (stacked rows under the coral tint band).

  return `
    <div class="exercise-card" data-index="${index}">
      <div class="card-inner">
        <div class="card-media" data-media-index="${index}">
          ${mediaHTML}
          ${buildMediaPauseOverlay()}
          ${buildPrepOverlay()}
        </div>
        <div class="card-body">
          <div class="card-position">Exercise ${Number.parseInt(slide.position, 10) || index + 1}</div>
          <div class="card-exercise-name">${escapeHTML(displayName)}</div>
          ${detail ? `<div class="active-slide-detail">${detail}</div>` : ''}
          ${slide.notes ? `<div class="card-notes">${escapeHTML(slide.notes)}</div>` : ''}
        </div>
      </div>
    </div>
  `;
}

function buildRestCard(slide, index) {
  // Rest card: icon + "Rest" title + "Next up: X" subtitle. The luxurious
  // bottom detail ("30s rest") lives under card-body. Tap to pause/resume
  // is via the same .media-pause-overlay as exercise slides.
  const nextSlide = index < slides.length - 1 ? slides[index + 1] : null;
  const nextUpName = nextSlide ? (nextSlide.name || 'Next exercise') : null;
  const detail = buildActiveSlideDetail(slide);

  return `
    <div class="exercise-card" data-index="${index}">
      <div class="card-inner rest-card">
        <div class="card-media rest-media" data-media-index="${index}">
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
          ${buildMediaPauseOverlay()}
          ${buildPrepOverlay()}
        </div>
        ${detail ? `<div class="card-body"><div class="active-slide-detail">${detail}</div></div>` : ''}
      </div>
    </div>
  `;
}

/**
 * Item 8: centered dark-circle overlay with coral play icon. Shown only when
 * the workout is paused on the active slide. Touch-transparent — the parent
 * .card-media captures the tap and dispatches via handleMediaTap(). The
 * overlay is injected into every card but only toggled visible on the
 * currently active, paused slide.
 */
function buildMediaPauseOverlay() {
  return `
    <div class="media-pause-overlay">
      <div class="pause-disc">
        <svg class="pause-icon-play" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
          <polygon points="6 3 20 12 6 21 6 3"/>
        </svg>
      </div>
    </div>
  `;
}

/**
 * Item 15: prep countdown overlay — big coral number fades over the last
 * 200ms of each second. Lives inside card-media but above it. JS toggles
 * visibility + drives the digit text + fade timing.
 */
function buildPrepOverlay() {
  return `
    <div class="prep-overlay" hidden>
      <div class="prep-overlay-number">15</div>
    </div>
  `;
}

/**
 * Item 5 — "luxurious" bottom detail line.
 *   Standalone exercise: `3 sets · 10 reps · 5s hold`
 *   Circuit exercise:    `10 reps · 5s hold`      (no sets — rounds carried by matrix)
 *   Rest:                `30s rest`
 * Returns a pre-escaped HTML string with <span> separators for the · dots.
 */
function buildActiveSlideDetail(slide) {
  if (slide.media_type === 'rest') {
    const secs = Number.parseInt(slide.hold_seconds, 10)
      || Number.parseInt(slide.custom_duration_seconds, 10)
      || 30;
    return `${secs}s rest`;
  }

  const parts = [];
  const isCircuit = !!slide.circuitRound;
  const sets = Number.parseInt(slide.sets, 10);
  const reps = Number.parseInt(slide.reps, 10);
  const hold = Number.parseInt(slide.hold_seconds, 10);

  // Standalone — include sets. Circuit — omit (rounds live in the matrix).
  if (!isCircuit && Number.isFinite(sets) && sets > 0) {
    parts.push(`${sets} sets`);
  }
  if (Number.isFinite(reps) && reps > 0) {
    parts.push(`${reps} reps`);
  }
  if (Number.isFinite(hold) && hold > 0) {
    parts.push(`${hold}s hold`);
  }

  if (!parts.length) return '';
  // Use middle-dot · as the separator. Wrap in text since CSS is all styling.
  return parts.map(escapeHTML).join(' <span class="sep">·</span> ');
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
    // No inline play overlay — item 7/8 consolidate pause/resume on a single
    // mode-aware tap target (.card-media → handleMediaTap). The
    // .media-pause-overlay inside the card toggles for the paused state.
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

// ============================================================
// Progress-pill matrix
// Canonical design source: docs/design/mockups/progress-pills.html
// ============================================================

// Size tier — chosen once at build time based on slide count + viewport width.
// 'spacious' = icon + short label, 'medium' = icon only, 'dense' = fill-bar only.
let matrixSizeTier = 'spacious';

// Manual scrub offset in px. When non-zero, the matrix is dragged off-centre;
// chevron appears and we snap back after 4s idle.
let matrixManualOffset = 0;
let matrixSnapBackTimer = null;

// Long-press state for peek-and-slide.
let peekState = {
  active: false,
  startedAt: 0,
  startedIndex: -1,
  currentIndex: -1,
  timer: null,
};

// Item 11: aspectish 28×22 / 22×20 / 16×18. Smaller pills overall so the
// entire plan fits the viewport without scrolling on most hardware.
const MATRIX_SPECS = {
  spacious: { width: 28, height: 22, gap: 8 },
  medium:   { width: 22, height: 20, gap: 8 },
  dense:    { width: 16, height: 18, gap: 8 },
};

const LONG_PRESS_MS = 380;
const MATRIX_AUTO_SNAP_MS = 4000;

/**
 * Item 6: pick the LARGEST tier that fits the viewport without horizontal
 * scroll. Only drop down when a tier genuinely overflows. Leaves ~16px of
 * gutter on each side (+ ETA slot width) so the matrix doesn't press up
 * against the viewport edge. When even 'dense' doesn't fit we stay on
 * 'dense' and accept scroll (rare — only enormous plans).
 */
const MATRIX_SIDE_PADDING = 32;  // 16px each side
const MATRIX_ETA_SLOT = 140;     // matches .matrix-eta min-width + gap

function chooseMatrixSizeTier(columnCount, viewportWidth) {
  const available = viewportWidth - MATRIX_SIDE_PADDING - MATRIX_ETA_SLOT;
  const fits = (spec) => columnCount * (spec.width + spec.gap) <= available;
  if (fits(MATRIX_SPECS.spacious)) return 'spacious';
  if (fits(MATRIX_SPECS.medium))   return 'medium';
  return 'dense';
}

/**
 * Item 12 — number-grammar pills, preserved for future re-enable.
 * Currently pills render empty (item 1), but the grammar helper stays so
 * toggling labels back on is a one-line change.
 *   Standalone: `S|R|H`
 *   Circuit:    `R|H`
 *   Rest:       no label
 */
// eslint-disable-next-line no-unused-vars
function pillGrammarLabel(slide) {
  if (slide.media_type === 'rest') return '';
  const parts = [];
  const isCircuit = !!slide.circuitRound;
  const sets = Number.parseInt(slide.sets, 10);
  const reps = Number.parseInt(slide.reps, 10);
  const hold = Number.parseInt(slide.hold_seconds, 10);
  if (!isCircuit && Number.isFinite(sets)) parts.push(String(sets));
  if (Number.isFinite(reps)) parts.push(String(reps));
  if (Number.isFinite(hold) && hold > 0) parts.push(String(hold));
  return parts.join('|');
}

/**
 * Collapse the unrolled slides into column descriptors. Standalone slides
 * produce a 1-row column; circuit groups produce one column per position,
 * with one row per cycle (cycle 1 on top).
 *
 * Returns { columns: [{ slideIndices: [...], isCircuit, circuitId }], bands }
 * where `bands` describes contiguous runs of same-circuit columns for the
 * coral tint band.
 */
function buildMatrixColumns() {
  const columns = [];
  let i = 0;
  while (i < slides.length) {
    const s = slides[i];
    if (!s.circuitRound) {
      columns.push({ slideIndices: [i], isCircuit: false, circuitId: null });
      i++;
      continue;
    }
    // Circuit: collect cycle-1 entries to discover column count.
    const circuitId = s.circuit_id;
    const groupStart = i;
    const firstCycleEnd = (() => {
      let k = i;
      while (k < slides.length &&
             slides[k].circuit_id === circuitId &&
             slides[k].circuitRound === 1) {
        k++;
      }
      return k;
    })();
    const groupSize = firstCycleEnd - groupStart;
    const total = s.circuitTotalRounds || 1;
    for (let pos = 0; pos < groupSize; pos++) {
      const slideIndices = [];
      for (let cycle = 1; cycle <= total; cycle++) {
        slideIndices.push(groupStart + (cycle - 1) * groupSize + pos);
      }
      columns.push({ slideIndices, isCircuit: true, circuitId });
    }
    i = groupStart + groupSize * total;
  }
  return columns;
}

// Legacy glyph/label helpers removed — pills are empty per item 1. The
// pillGrammarLabel() function (defined above) preserves the number-grammar
// spec (item 12) for a future re-enable.

/** Build the DOM for the matrix (columns + pills). One-time per render. */
function buildProgressMatrix() {
  if (!$matrixInner) return;

  const columns = buildMatrixColumns();
  const viewportWidth = window.innerWidth || 375;
  matrixSizeTier = chooseMatrixSizeTier(columns.length, viewportWidth);

  $matrixInner.className = 'progress-matrix-inner';
  const columnsHTML = columns.map((col, colIdx) => {
    const rowsHTML = col.slideIndices.map((slideIdx) => {
      const slide = slides[slideIdx];
      const isRest = slide.media_type === 'rest';
      const sizeClass = 'size-' + matrixSizeTier;
      const restClass = isRest ? ' is-rest' : '';
      // Item 1: pills are EMPTY — no glyph, no label. Just the hull + fill
      // bar. The macro fill-up effect (item 2) and colour coding carry all
      // the information the user needs at a glance. Grammar helper lives in
      // pillGrammarLabel() for future re-enable.
      return `<div class="pill ${sizeClass}${restClass}" data-slide="${slideIdx}">
                <span class="pill-fill"></span>
              </div>`;
    }).join('');

    const circuitClass = col.isCircuit ? ' is-circuit' : '';
    return `<div class="matrix-col${circuitClass}" data-col="${colIdx}">${rowsHTML}</div>`;
  }).join('');

  // Item 4: 3-number ETA row — `current · total · ~finish`. All three numbers
  // are mono, 13pt. current = active-slide remaining (coral bold), total =
  // whole-plan remaining (white bold), finish = wall-clock finish (muted).
  // Content driven by updateEtaDisplay() on every tick.
  const etaHTML = `
    <div class="matrix-eta" id="matrix-eta" aria-live="polite">
      <span class="matrix-eta-current" id="matrix-eta-current">0:00</span>
      <span class="matrix-eta-sep">·</span>
      <span class="matrix-eta-total" id="matrix-eta-total">0:00</span>
      <span class="matrix-eta-sep">·</span>
      <span class="matrix-eta-finish" id="matrix-eta-finish">~--:--</span>
    </div>`;

  $matrixInner.innerHTML = columnsHTML + etaHTML;

  // Cache ETA DOM refs after the innerHTML swap.
  $etaBlock = $matrixInner.querySelector('#matrix-eta');
  $etaCurrent = $matrixInner.querySelector('#matrix-eta-current');
  $etaTotal = $matrixInner.querySelector('#matrix-eta-total');
  $etaFinish = $matrixInner.querySelector('#matrix-eta-finish');

  // Force layout to run so offsetLeft queries are accurate before first updateUI.
  void $matrixInner.offsetWidth;
}

/** Update visible state — active/completed classes + centring scroll + fill width. */
function updateProgressMatrix() {
  if (!$matrixInner) return;
  const spec = MATRIX_SPECS[matrixSizeTier];
  const pills = $matrixInner.querySelectorAll('.pill');

  const isWorkoutActive = isWorkoutMode && !isPrepPhase;
  const activeIdx = isWorkoutMode ? currentIndex : -1;

  pills.forEach((pill) => {
    const slideIdx = Number(pill.getAttribute('data-slide'));
    const isActive = slideIdx === activeIdx;
    const isCompleted = activeIdx >= 0 && slideIdx < activeIdx;
    pill.classList.toggle('is-active', isActive);
    pill.classList.toggle('is-completed', isCompleted);
    pill.classList.remove('is-scrubbed');

    const fill = pill.querySelector('.pill-fill');
    if (!fill) return;
    if (isCompleted) {
      fill.style.width = '100%';
    } else if (isActive) {
      // Live progress: fraction of the active slide's timer elapsed.
      const frac = isWorkoutActive && totalSeconds > 0
        ? Math.max(0, Math.min(1, (totalSeconds - remainingSeconds) / totalSeconds))
        : 0;
      fill.style.width = `${frac * 100}%`;
    } else {
      fill.style.width = '0%';
    }
  });

  // Centre the active pill.
  const activePill = $matrixInner.querySelector(`.pill[data-slide="${activeIdx}"]`);
  const viewportWidth = $matrix.clientWidth || window.innerWidth || 375;
  let centeringOffset = 0;
  if (activePill) {
    // activePill is inside a .matrix-col which is the direct grid child.
    const col = activePill.parentElement;
    const colLeft = col.offsetLeft;
    // pill.offsetLeft is relative to its column; add both.
    const pillLeft = colLeft + activePill.offsetLeft;
    const pillCentre = pillLeft + activePill.offsetWidth / 2;
    centeringOffset = viewportWidth / 2 - pillCentre;
  }
  const translateX = centeringOffset + matrixManualOffset;
  $matrixInner.style.transform = `translateX(${translateX}px)`;

  // Chevron visible only when the user has dragged the matrix away from centre.
  if (Math.abs(matrixManualOffset) > 16 && activeIdx >= 0) {
    $matrixChevron.hidden = false;
  } else {
    $matrixChevron.hidden = true;
  }
}

// ------------------------------------------------------------
// Matrix gestures — long-press peek, slide to scrub, release to jump
// ------------------------------------------------------------

function matrixPointToPillEl(clientX, clientY) {
  const el = document.elementFromPoint(clientX, clientY);
  if (!el) return null;
  return el.closest ? el.closest('.pill[data-slide]') : null;
}

/**
 * Item 9 — centered peek. Shows name + decoded grammar line. CSS positions
 * the panel at viewport center (translate(-50%, -50%)); no per-pill math.
 * The optional `teaching` flag adds a fade-out animation that retires the
 * peek cleanly after the teaching window.
 */
function openPeek(slideIdx, opts) {
  const teaching = !!(opts && opts.teaching);
  const slide = slides[slideIdx];
  if (!slide) return;
  const name = slide.media_type === 'rest'
    ? 'Rest'
    : (slide.name || `Exercise ${slideIdx + 1}`);

  // Decoded grammar — same detail line the bottom row uses (luxurious item 5),
  // stripped of HTML-escape wrappers. Plus a rest prefix for circuits so the
  // user knows what they're scrubbing to.
  let meta = '';
  if (slide.media_type === 'rest') {
    const secs = Number.parseInt(slide.hold_seconds, 10)
      || Number.parseInt(slide.custom_duration_seconds, 10)
      || 30;
    meta = `${secs}s rest`;
  } else {
    const parts = [];
    const isCircuit = !!slide.circuitRound;
    const sets = Number.parseInt(slide.sets, 10);
    const reps = Number.parseInt(slide.reps, 10);
    const hold = Number.parseInt(slide.hold_seconds, 10);
    if (!isCircuit && Number.isFinite(sets) && sets > 0) parts.push(`${sets} sets`);
    if (Number.isFinite(reps) && reps > 0) parts.push(`${reps} reps`);
    if (Number.isFinite(hold) && hold > 0) parts.push(`${hold}s hold`);
    if (isCircuit && slide.circuitRound && slide.circuitTotalRounds) {
      // Prefix circuit round so the scrub peek tells the user where they are.
      parts.unshift(`Circuit · Round ${slide.circuitRound} of ${slide.circuitTotalRounds}`);
    }
    meta = parts.join(' · ');
  }

  $peekName.textContent = name;
  $peekMeta.textContent = meta;
  $peekPanel.classList.toggle('is-teaching', teaching);
  $peekPanel.hidden = false;
}

function closePeek() {
  $peekPanel.hidden = true;
  $peekPanel.classList.remove('is-teaching');
}

// Kept for backward compatibility with the touch handlers that used to call
// this; with centered positioning there's no per-pill math to do.
// eslint-disable-next-line no-unused-vars
function positionPeek(_slideIdx) { /* no-op */ }

function highlightScrubbedPill(slideIdx) {
  $matrixInner.querySelectorAll('.pill.is-scrubbed').forEach((p) =>
    p.classList.remove('is-scrubbed')
  );
  if (slideIdx >= 0) {
    const pill = $matrixInner.querySelector(`.pill[data-slide="${slideIdx}"]`);
    if (pill) pill.classList.add('is-scrubbed');
  }
}

function beginLongPress(slideIdx) {
  peekState.active = true;
  peekState.startedIndex = slideIdx;
  peekState.currentIndex = slideIdx;
  openPeek(slideIdx);
  highlightScrubbedPill(slideIdx);
  // Haptic hint (ignored on unsupported browsers).
  if (navigator.vibrate) navigator.vibrate(8);
  // Freeze active pill's fill animation while peek is open.
  $matrixInner.querySelectorAll('.pill.is-active').forEach((p) =>
    p.classList.add('is-paused')
  );
}

function endLongPress(commit) {
  if (!peekState.active) return;
  const target = peekState.currentIndex;
  const source = peekState.startedIndex;
  peekState.active = false;
  peekState.startedIndex = -1;
  peekState.currentIndex = -1;
  closePeek();
  highlightScrubbedPill(-1);
  $matrixInner.querySelectorAll('.pill.is-paused').forEach((p) =>
    p.classList.remove('is-paused')
  );
  if (commit && target >= 0 && target !== source && target !== currentIndex) {
    jumpToSlide(target);
  }
}

/** Jump to a specific slide — resets timer when in workout mode. */
function jumpToSlide(slideIdx) {
  if (slideIdx < 0 || slideIdx >= slides.length) return;
  if (isWorkoutMode) {
    clearWorkoutTimer();
    clearPrepTimer();
    isTimerRunning = false;
    isPrepPhase = false;
  }
  closePeek();
  goTo(slideIdx);
}

// ------------------------------------------------------------
// Touch handlers — a single pointer drives both peek + manual scrub. If the
// user's finger lingers (>LONG_PRESS_MS) without significant movement, we
// enter peek mode; otherwise horizontal drags become a manual scrub.
// ------------------------------------------------------------

let matrixTouchStart = { x: 0, y: 0, time: 0, slideIdx: -1, moved: false };

function onMatrixTouchStart(e) {
  const touch = e.touches ? e.touches[0] : e;
  if (!touch) return;
  matrixTouchStart.x = touch.clientX;
  matrixTouchStart.y = touch.clientY;
  matrixTouchStart.time = Date.now();
  matrixTouchStart.moved = false;
  matrixTouchStart._lastX = touch.clientX;
  if (matrixSnapBackTimer) {
    clearTimeout(matrixSnapBackTimer);
    matrixSnapBackTimer = null;
  }
  // Which pill is under the initial touch?
  const pill = matrixPointToPillEl(touch.clientX, touch.clientY);
  matrixTouchStart.slideIdx = pill ? Number(pill.getAttribute('data-slide')) : -1;

  // Schedule long-press.
  if (peekState.timer) clearTimeout(peekState.timer);
  peekState.timer = setTimeout(() => {
    peekState.timer = null;
    if (matrixTouchStart.slideIdx >= 0 && !matrixTouchStart.moved) {
      beginLongPress(matrixTouchStart.slideIdx);
    }
  }, LONG_PRESS_MS);
}

/** Item 6: when the matrix fits the viewport without scroll, drag is disabled. */
function matrixFitsViewport() {
  if (!$matrixInner) return true;
  const columns = buildMatrixColumns();
  const viewportWidth = window.innerWidth || 375;
  const available = viewportWidth - MATRIX_SIDE_PADDING - MATRIX_ETA_SLOT;
  const spec = MATRIX_SPECS[matrixSizeTier] || MATRIX_SPECS.dense;
  return columns.length * (spec.width + spec.gap) <= available;
}

function onMatrixTouchMove(e) {
  const touch = e.touches ? e.touches[0] : e;
  if (!touch) return;
  const dx = touch.clientX - matrixTouchStart.x;
  const dy = touch.clientY - matrixTouchStart.y;

  if (peekState.active) {
    // Slide finger during peek — hover over new pills, haptic tick on change.
    const pill = matrixPointToPillEl(touch.clientX, touch.clientY);
    if (pill) {
      const newIdx = Number(pill.getAttribute('data-slide'));
      if (newIdx !== peekState.currentIndex) {
        peekState.currentIndex = newIdx;
        highlightScrubbedPill(newIdx);
        positionPeek(newIdx);
        if (navigator.vibrate) navigator.vibrate(4);
      }
    }
    // Swallow scroll while peeking.
    if (e.cancelable) e.preventDefault();
    return;
  }

  // Pre-long-press: if finger moves more than 10px horizontally, cancel
  // the long-press timer and switch to manual scrub mode instead.
  if (Math.abs(dx) > 10 || Math.abs(dy) > 10) {
    matrixTouchStart.moved = true;
    if (peekState.timer) {
      clearTimeout(peekState.timer);
      peekState.timer = null;
    }
  }

  if (matrixTouchStart.moved && Math.abs(dx) > Math.abs(dy)) {
    // Item 6: skip the scrub if the entire track already fits.
    if (matrixFitsViewport()) return;
    // Manual scrub — translate by the delta since last move event.
    const lastX = matrixTouchStart._lastX ?? touch.clientX;
    const delta = touch.clientX - lastX;
    matrixTouchStart._lastX = touch.clientX;
    matrixManualOffset += delta;
    $matrixInner.classList.add('is-scrubbing');
    $matrixInner.style.transform = `translateX(${computeCenteringOffset() + matrixManualOffset}px)`;
    $matrixChevron.hidden = Math.abs(matrixManualOffset) < 16;
  }
}

/** Read-only: re-compute centring offset for the current active pill. */
function computeCenteringOffset() {
  const activeIdx = isWorkoutMode ? currentIndex : -1;
  const activePill = $matrixInner.querySelector(`.pill[data-slide="${activeIdx}"]`);
  if (!activePill) return 0;
  const col = activePill.parentElement;
  const pillLeft = col.offsetLeft + activePill.offsetLeft;
  const pillCentre = pillLeft + activePill.offsetWidth / 2;
  const viewportWidth = $matrix.clientWidth || window.innerWidth || 375;
  return viewportWidth / 2 - pillCentre;
}

function onMatrixTouchEnd() {
  if (peekState.timer) {
    clearTimeout(peekState.timer);
    peekState.timer = null;
  }
  matrixTouchStart._lastX = undefined;
  $matrixInner.classList.remove('is-scrubbing');

  if (peekState.active) {
    const sameAsStart = peekState.currentIndex === peekState.startedIndex;
    endLongPress(!sameAsStart);
    return;
  }

  // Manual scrub ended — schedule snap-back after 4s idle.
  if (Math.abs(matrixManualOffset) > 0) {
    if (matrixSnapBackTimer) clearTimeout(matrixSnapBackTimer);
    matrixSnapBackTimer = setTimeout(() => {
      matrixManualOffset = 0;
      updateProgressMatrix();
    }, MATRIX_AUTO_SNAP_MS);
  }
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
  // After a jump, recompute immediately so we don't wait 1s for the ticker.
  updateEtaDisplay();
  // Slide state changed — re-evaluate the pause/prep overlay visibility on
  // the new active slide and hide them on the old one.
  updatePauseOverlay();
  updatePrepOverlay();

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
  }
  // Close any peek / prep overlay so we don't linger into the new slide.
  closePeek();
  goTo(currentIndex + 1);
}

function goPrev() {
  if (isWorkoutMode) {
    clearWorkoutTimer();
    clearPrepTimer();
    isTimerRunning = false;
    isPrepPhase = false;
  }
  closePeek();
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
  if (prepFadeTimer) {
    clearTimeout(prepFadeTimer);
    prepFadeTimer = null;
  }
  isPrepPhase = false;
}

function autoPlayCurrentVideo() {
  const currentVideo = document.getElementById(`video-${currentIndex}`);
  if (!currentVideo) return;
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

  // Progress-pill matrix — active pill state + centring scroll
  updateProgressMatrix();

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

function pauseAllVideos() {
  document.querySelectorAll('video').forEach(v => {
    v.pause();
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
    // Spacebar is a keyboard equivalent of tapping the active media area.
    // Same mode-aware dispatch as handleMediaTap without the event target.
    if (isPrepPhase) {
      finishPrepPhase();
    } else if (isTimerRunning) {
      pauseTimer();
    } else if (remainingSeconds > 0) {
      resumeTimer();
    }
    updatePauseOverlay();
  }
}

// ============================================================
// Workout Timer
// ============================================================

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

// ------------------------------------------------------------
// ETA (matrix right-end widget) — "7:42 left" + "~7:42 PM".
// Remaining ticks down when the workout is running, holds steady when paused;
// finish time = now() + remaining, so it drifts forward while paused — by
// design. See the semantic table in the task brief.
// ------------------------------------------------------------

/**
 * Sum of expected-durations for every slide strictly after the active one.
 * Each slide in `slides[]` is already one pass of its exercise (circuits are
 * unrolled upstream in unrollExercises), so we can sum per-slide without
 * re-multiplying by cycles.
 */
function sumUpcomingDurations(startIndex) {
  let sum = 0;
  for (let i = startIndex; i < slides.length; i++) {
    sum += calculateDuration(slides[i]);
  }
  return sum;
}

/**
 * Seconds left on the active slide (exclusive of upcoming slides). During
 * prep: prep runway + full active-slide duration. Running / paused: the
 * authoritative `remainingSeconds` tick counter.
 */
function calculateActiveSlideRemainingSeconds() {
  if (!slides.length) return 0;
  if (!isWorkoutMode) {
    // Pre-workout: current slide's full duration.
    return calculateDuration(slides[currentIndex]);
  }
  if (isPrepPhase) {
    return prepRemainingSeconds + calculateDuration(slides[currentIndex]);
  }
  return Math.max(0, remainingSeconds);
}

/**
 * Workout seconds left from "right now" — the active slide's remaining
 * portion plus the full duration of every slide after it.
 *
 * Pre-workout: shows total plan duration (stale finish-time-if-started-now).
 * Prep phase: add the prep runway + full active-slide duration.
 * Running / paused: use `remainingSeconds` (the 1s tick loop is authoritative).
 */
function calculateRemainingWorkoutSeconds() {
  if (!slides.length) return 0;
  return calculateActiveSlideRemainingSeconds()
    + sumUpcomingDurations(currentIndex + 1);
}

/**
 * Format the finish wall-clock time using the device locale. Mirrors
 * MaterialLocalizations.formatTimeOfDay on the Flutter side — 12h vs 24h is
 * chosen automatically.
 */
function formatFinishTime(date) {
  try {
    return new Intl.DateTimeFormat(undefined, {
      hour: 'numeric',
      minute: '2-digit',
    }).format(date);
  } catch (_err) {
    // Extremely defensive fallback — Intl should always be present.
    const h = date.getHours();
    const m = date.getMinutes().toString().padStart(2, '0');
    return `${h}:${m}`;
  }
}

/**
 * Render the ETA widget. Called on every workout-tick AND on an independent
 * 1s wall-clock tick so the finish time drifts forward while paused.
 * Item 4: three numbers — current, total, finish.
 */
function updateEtaDisplay() {
  if (!$etaBlock) return;
  if (workoutCompleteFlag) {
    // Set the "Done" markup once; subsequent ticks are no-ops until the flag
    // flips (exitWorkout() rebuilds the whole matrix so refs are refreshed).
    if (!$etaBlock.classList.contains('is-done')) {
      $etaBlock.classList.add('is-done');
      $etaBlock.innerHTML = '<div class="matrix-eta-done">Done</div>';
    }
    return;
  }

  const activeSecs = calculateActiveSlideRemainingSeconds();
  const totalSecs = calculateRemainingWorkoutSeconds();
  const finishAt = new Date(Date.now() + totalSecs * 1000);

  if ($etaCurrent) $etaCurrent.textContent = formatTime(Math.max(0, activeSecs));
  if ($etaTotal) $etaTotal.textContent = formatTime(Math.max(0, totalSecs));
  if ($etaFinish) $etaFinish.textContent = `~${formatFinishTime(finishAt)}`;

  // Item 15: prep-phase flash — current-slide token + active pill.
  if ($etaCurrent) {
    $etaCurrent.classList.toggle('is-prep-flashing', isPrepPhase);
  }
  if ($matrixInner) {
    const activePill = $matrixInner.querySelector('.pill.is-active');
    if (activePill) {
      activePill.classList.toggle('is-prep-flashing', isPrepPhase);
    }
  }
}

// Mirrors the Flutter widget.workoutComplete flag for the ETA "Done" state.
let workoutCompleteFlag = false;

function startEtaClock() {
  if (etaClockTimer) return;
  etaClockTimer = setInterval(updateEtaDisplay, 1000);
}

function stopEtaClock() {
  if (etaClockTimer) {
    clearInterval(etaClockTimer);
    etaClockTimer = null;
  }
}

/**
 * Enter workout mode. Calling goTo(0) triggers the prep-or-rest flow for the
 * first slide via enterWorkoutPhaseForCurrent().
 */
function startWorkout() {
  isWorkoutMode = true;
  workoutCompleteFlag = false;
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
  // Matrix needs an active-state redraw now that isWorkoutMode is true.
  updateProgressMatrix();
  updateEtaDisplay();
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
 * Begin the 15-second prep countdown. The big coral prep overlay counts
 * down; tapping the media area skips to the running phase (item 7). The
 * current-slide ETA number + active pill flash during prep (item 15).
 */
function startPrepPhase() {
  clearPrepTimer();
  clearWorkoutTimer();

  isPrepPhase = true;
  isTimerRunning = false;
  prepRemainingSeconds = PREP_SECONDS;

  updatePrepOverlay();
  schedulePrepFade();
  updatePauseOverlay();
  // ETA now reflects prep seconds + new slide's full duration + upcoming.
  updateEtaDisplay();

  prepTimer = setInterval(onPrepTick, 1000);
}

function onPrepTick() {
  if (!isPrepPhase) return;
  prepRemainingSeconds--;

  if (prepRemainingSeconds <= 0) {
    finishPrepPhase();
    return;
  }
  updatePrepOverlay();
  schedulePrepFade();
  // Prep seconds are part of "remaining" — tick the ETA too.
  updateEtaDisplay();
}

function finishPrepPhase() {
  clearPrepTimer();
  // Hide the prep overlay, drop the flash.
  updatePrepOverlay();
  startTimer();
}

/**
 * Start the countdown timer for the current slide
 */
function startTimer() {
  clearWorkoutTimer();
  clearPrepTimer();

  isTimerRunning = true;
  updatePauseOverlay();
  updateEtaDisplay();

  workoutTimer = setInterval(onTimerTick, 1000);
}

/**
 * Legacy stubs — the dedicated timer chip is gone (item 7). Keeping the
 * function names so any late-bound call site from pre-parity code no-ops
 * instead of throwing.
 */
function showTimerDisplay() { /* no-op */ }
function hideTimerDisplay() {
  // Belt-and-braces: hide the legacy element if anyone kept its markup.
  if ($timerOverlay) $timerOverlay.hidden = true;
}

/**
 * Called every second while timer is running
 */
function onTimerTick() {
  if (!isTimerRunning) return;

  remainingSeconds--;

  if (remainingSeconds <= 0) {
    remainingSeconds = 0;
    updateProgressMatrix();
    clearInterval(workoutTimer);
    workoutTimer = null;
    isTimerRunning = false;

    // Auto-advance
    onTimerComplete();
    return;
  }

  // Matrix active-pill fill needs a per-second nudge too.
  updateProgressMatrix();
  updateEtaDisplay();
}

// updateTimerDisplay + setTimerModeIcon removed — the dedicated chip is
// gone (item 7). Prep digits are driven by updatePrepOverlay(); pause state
// is driven by updatePauseOverlay(); countdown numbers read from the ETA row.

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
 * Pause the running timer. Freezes remainingSeconds (so the ETA "total"
 * number stays static while the wall-clock finish time drifts forward),
 * pauses the active video, and reveals the centered pause overlay.
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
  updatePauseOverlay();
  // ETA clock keeps running in the background — remaining stays static,
  // finish-time drifts forward. Nudge once to reflect immediately.
  updateEtaDisplay();
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
  updatePauseOverlay();
  updateEtaDisplay();
}

/**
 * Item 7: single mode-aware tap handler for the media area.
 * Prep → skip prep. Running → pause. Paused → resume.
 *
 * Bail when the user just swiped, so the synthetic click that follows a
 * touchend doesn't pause/resume by accident.
 */
function handleMediaTap(e) {
  if (!isWorkoutMode) return;
  if (swipeState.didSwipe) {
    swipeState.didSwipe = false;
    return;
  }
  // Only fire for taps that land on .card-media (or its children that aren't
  // themselves interactive — we keep things simple by hoisting the listener
  // to .card-media and letting children bubble up).
  const mediaEl = e.target.closest ? e.target.closest('.card-media[data-media-index]') : null;
  if (!mediaEl) return;
  const idx = Number(mediaEl.getAttribute('data-media-index'));
  if (!Number.isFinite(idx) || idx !== currentIndex) return;

  if (isPrepPhase) {
    finishPrepPhase();
    return;
  }
  if (isTimerRunning) {
    pauseTimer();
  } else if (remainingSeconds > 0) {
    resumeTimer();
  }
  updatePauseOverlay();
}

/**
 * Item 8: toggle the centered pause overlay on the active slide. Visible only
 * when the workout is paused AND we're not in the prep phase. Other slides
 * hide their overlay so we don't leave it visible in the wings of the card
 * track.
 */
function updatePauseOverlay() {
  if (!$cardTrack) return;
  const overlays = $cardTrack.querySelectorAll('.media-pause-overlay');
  const showActive = isWorkoutMode && !isPrepPhase && !isTimerRunning
    && remainingSeconds > 0;
  overlays.forEach((overlay) => {
    const card = overlay.closest('.exercise-card');
    const idx = card ? Number(card.getAttribute('data-index')) : -1;
    overlay.classList.toggle('is-visible', showActive && idx === currentIndex);
  });
}

/**
 * Item 15: prep overlay digit. Shown only during the prep phase on the
 * currently active slide. Digit text is driven by prepRemainingSeconds.
 * The .is-fading class is added in the last 200ms of each second so the
 * digit smoothly fades before the next one appears.
 */
function updatePrepOverlay() {
  if (!$cardTrack) return;
  const overlays = $cardTrack.querySelectorAll('.prep-overlay');
  overlays.forEach((overlay) => {
    const card = overlay.closest('.exercise-card');
    const idx = card ? Number(card.getAttribute('data-index')) : -1;
    const visible = isPrepPhase && idx === currentIndex;
    overlay.hidden = !visible;
    if (visible) {
      const numEl = overlay.querySelector('.prep-overlay-number');
      if (numEl) numEl.textContent = String(Math.max(0, prepRemainingSeconds));
    }
  });
}

/**
 * Kick the fade animation at the start of each prep-second. Adds .is-fading
 * ~800ms into the second and removes it when the next second's digit is set.
 */
let prepFadeTimer = null;
function schedulePrepFade() {
  if (prepFadeTimer) clearTimeout(prepFadeTimer);
  const overlay = $cardTrack.querySelector(
    `.exercise-card[data-index="${currentIndex}"] .prep-overlay`);
  if (!overlay) return;
  const numEl = overlay.querySelector('.prep-overlay-number');
  if (!numEl) return;
  numEl.classList.remove('is-fading');
  // Last ~200ms of the 1000ms beat fade the current digit out.
  prepFadeTimer = setTimeout(() => {
    numEl.classList.add('is-fading');
  }, 800);
}

/**
 * Show workout complete screen
 */
function finishWorkout() {
  clearWorkoutTimer();
  clearPrepTimer();
  isTimerRunning = false;
  isPrepPhase = false;

  updatePauseOverlay();
  updatePrepOverlay();

  // Calculate total workout time
  const elapsedMs = Date.now() - workoutStartTime;
  const elapsedSeconds = Math.round(elapsedMs / 1000);
  $workoutTotalTime.textContent = `Total time: ${formatTime(elapsedSeconds)}`;

  $workoutComplete.hidden = false;

  // Flip the ETA to "Done" end-state.
  workoutCompleteFlag = true;
  updateEtaDisplay();
}

/**
 * Close workout mode and return to browse
 */
function exitWorkout() {
  isWorkoutMode = false;
  isTimerRunning = false;
  isPrepPhase = false;

  clearWorkoutTimer();
  clearPrepTimer();

  workoutStartTime = null;

  $workoutComplete.hidden = true;
  updatePauseOverlay();
  updatePrepOverlay();

  // Show the start workout button again
  $startWorkoutBtn.hidden = false;

  // Rebuild the matrix (which re-injects the ETA HTML replacing the "Done"
  // innerHTML, if it was set) and reset the end-state flag so the readout
  // shows the pre-workout stale total again.
  workoutCompleteFlag = false;
  buildProgressMatrix();
  updateProgressMatrix();
  updateEtaDisplay();
}

// ============================================================
// HomefitLogo (item 10)
// ------------------------------------------------------------
// Mini-plan glyph built entirely from pill primitives:
//   col 1..2  — 2-exercise circuit × 2 rounds (coral pills, coral tint band)
//   col 3     — 1 standalone exercise (coral pill, top row only)
//   col 4     — 1 rest (sage pill, top row only)
// Rail entry stub enters at (band left, top-row mid-y). Rail exit stub
// leaves at (band right, bottom-row mid-y). Coral accents, sage for rest.
// Rendered proportionally via inline SVG.
// ============================================================

function buildHomefitLogoSvg() {
  // Mini-pill metrics — 5×3 per cell with 1.5 gaps.
  const cell = 5;
  const rowGap = 1.5;
  const colGap = 1.5;
  const rows = 2;
  const cols = 4;
  const bandCols = 2;         // circuit spans cols 0 and 1
  const railStubLen = 3;
  const padX = 2;
  const padY = 2;

  const bandX = padX + railStubLen - 0.5;
  const bandY = padY - 0.5;
  const bandW = bandCols * cell + (bandCols - 1) * colGap + 1;
  const bandH = rows * 3 + (rows - 1) * rowGap + 1;

  const cellX = (c) => padX + railStubLen + c * (cell + colGap);
  const cellY = (r) => padY + r * (3 + rowGap);

  const width = padX + railStubLen + cols * cell + (cols - 1) * colGap
    + railStubLen + padX;
  const height = padY + rows * 3 + (rows - 1) * rowGap + padY;

  const coral = '#FF6B35';
  const coralTint = 'rgba(255, 107, 53, 0.15)';
  const sage = '#86EFAC';
  const railColor = 'rgba(255, 107, 53, 0.7)';

  let svg = `<svg class="homefit-logo" viewBox="0 0 ${width} ${height}"`
    + ` xmlns="http://www.w3.org/2000/svg" aria-hidden="true">`;

  // Rail entry stub — top row, just before band.
  const topY = cellY(0) + 3 / 2;
  svg += `<path d="M0 ${topY} L${bandX} ${topY}" stroke="${railColor}"`
    + ` stroke-width="0.7" stroke-linecap="round"/>`;

  // Coral tint band behind circuit columns.
  svg += `<rect x="${bandX}" y="${bandY}" width="${bandW}" height="${bandH}"`
    + ` rx="1.5" fill="${coralTint}"/>`;

  // Circuit pills (cols 0,1 × rows 0,1) — coral.
  for (let r = 0; r < rows; r++) {
    for (let c = 0; c < bandCols; c++) {
      svg += `<rect x="${cellX(c)}" y="${cellY(r)}" width="${cell}" height="3"`
        + ` rx="1" fill="${coral}"/>`;
    }
  }

  // Standalone coral pill — col 2, row 0 only.
  svg += `<rect x="${cellX(2)}" y="${cellY(0)}" width="${cell}" height="3"`
    + ` rx="1" fill="${coral}"/>`;

  // Rest sage pill — col 3, row 0 only.
  svg += `<rect x="${cellX(3)}" y="${cellY(0)}" width="${cell}" height="3"`
    + ` rx="1" fill="${sage}"/>`;

  // Rail exit stub — bottom row, just after the last col.
  const botY = cellY(1) + 3 / 2;
  const exitX = cellX(cols - 1) + cell;
  svg += `<path d="M${exitX} ${botY} L${width} ${botY}" stroke="${railColor}"`
    + ` stroke-width="0.7" stroke-linecap="round"/>`;

  svg += `</svg>`;
  return svg;
}

function renderFooterLogo() {
  if (!$footerLogo) return;
  // Prepend the SVG before the wordmark span.
  const existingWordmark = $footerLogo.querySelector('.homefit-logo-wordmark');
  $footerLogo.innerHTML = buildHomefitLogoSvg()
    + (existingWordmark ? existingWordmark.outerHTML
        : '<span class="homefit-logo-wordmark">homefit.studio</span>');
}

// ============================================================
// Teaching peek (item 9 — R-09)
// ------------------------------------------------------------
// On preview start, auto-show the centered peek for the current slide for
// 2 seconds so the user learns the visual grammar once. Stays out of the
// way afterwards — only returns during long-press scrubbing in the matrix.
// ============================================================

function scheduleTeachingPeek() {
  if (teachingPeekTimer) {
    clearTimeout(teachingPeekTimer);
    teachingPeekTimer = null;
  }
  if (!slides.length) return;
  openPeek(currentIndex, { teaching: true });
  teachingPeekTimer = setTimeout(() => {
    closePeek();
    teachingPeekTimer = null;
  }, 2200);
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
    renderFooterLogo();

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
    // Mode-aware pause — tap anywhere on the active slide's media area.
    $cardViewport.addEventListener('click', handleMediaTap);
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
          isPrepPhase = false;
        }
        closePeek();
        goTo(parseInt(dot.dataset.index, 10));
      }
    });

    // Workout timer events
    $startWorkoutBtn.addEventListener('click', startWorkout);
    $workoutCloseBtn.addEventListener('click', exitWorkout);

    // (Item 7) The dedicated timer-chip click binding is retired — tapping
    // the media area via handleMediaTap() is the only pause/resume control.

    // Progress-pill matrix — touch handlers drive both long-press peek
    // (finger held over a pill for >380ms) and manual scrub (horizontal drag).
    if ($matrix) {
      $matrix.addEventListener('touchstart', onMatrixTouchStart, { passive: false });
      $matrix.addEventListener('touchmove', onMatrixTouchMove, { passive: false });
      $matrix.addEventListener('touchend', onMatrixTouchEnd);
      $matrix.addEventListener('touchcancel', onMatrixTouchEnd);
      // Desktop / mouse: tap-to-jump when no touch events fire.
      // Long-press-and-slide on mouse is a follow-up (mobile-first for MVP).
      $matrix.addEventListener('click', (e) => {
        if (peekState.active) return;
        const pill = e.target.closest ? e.target.closest('.pill[data-slide]') : null;
        if (!pill) return;
        const idx = Number(pill.getAttribute('data-slide'));
        if (Number.isFinite(idx) && idx !== currentIndex) jumpToSlide(idx);
      });
      // Re-choose size tier on viewport resize — rebuild is cheap.
      window.addEventListener('resize', () => {
        const prev = matrixSizeTier;
        const cols = buildMatrixColumns();
        const nextTier = chooseMatrixSizeTier(cols.length, window.innerWidth);
        if (nextTier !== prev) {
          buildProgressMatrix();
          updateProgressMatrix();
        } else {
          updateProgressMatrix();
        }
      });
    }

    // Try to autoplay the first slide's video on initial load. The fetchPlan
    // click that opened the URL should have unlocked autoplay on iOS Safari,
    // but we swallow the rejection defensively if the browser blocks it.
    autoPlayCurrentVideo();

    // Show the Start Workout button
    $startWorkoutBtn.hidden = false;

    // R-09 teaching peek — 2s centered peek for the first slide so users
    // learn the name + grammar vocabulary once.
    scheduleTeachingPeek();

  } catch (err) {
    console.error('Failed to load plan:', err);
    $loading.hidden = true;
    $error.hidden = false;
  }
}

// Start the app
init();
