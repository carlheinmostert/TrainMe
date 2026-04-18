/**
 * TrainMe Web Player
 * Static exercise plan viewer — clients open shared links from WhatsApp
 * to view their personalised training programmes.
 *
 * Data access: all Supabase I/O routes through `window.HomefitApi` (see
 * api.js). Direct `fetch('.../rest/v1/...')` calls are forbidden here;
 * the one that used to live in `fetchPlan()` is the reason api.js exists.
 * See docs/DATA_ACCESS_LAYER.md.
 */

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
let $etaBlock = null;
let $etaRemaining = null;
let $etaFinish = null;

// Wall-clock ticker for the ETA widget. Runs 1/sec so the finish-time label
// keeps drifting forward while the workout is paused (remaining holds steady,
// now() advances → finish = now + remaining also advances). Independent of
// the workoutTimer and prepTimer.
let etaClockTimer = null;

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
  // Milestone C (RLS lockdown): plans + exercises are scoped by practice
  // membership, so anon PostgREST SELECT returns nothing. We read via
  // the `get_plan_full(p_plan_id)` SECURITY DEFINER RPC — exposed as the
  // only allowed anon operation on `window.HomefitApi`.
  //
  // The RPC also atomically stamps `first_opened_at` on the first fetch
  // (feeds the publish-lock rule: once a client opens a plan, structural
  // edits lock on the practitioner's side).
  const payload = await window.HomefitApi.getPlanFull(planId);

  // Reshape: RPC returns { plan: {...}, exercises: [...] }. The renderer
  // expects the plan object with exercises nested as a property, which is
  // the shape the old PostgREST query produced.
  const plan = { ...payload.plan, exercises: payload.exercises || [] };
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

const MATRIX_SPECS = {
  spacious: { width: 72, height: 40, gap: 8 },
  medium:   { width: 48, height: 32, gap: 8 },
  dense:    { width: 24, height: 12, gap: 8 },
};

const LONG_PRESS_MS = 380;
const MATRIX_AUTO_SNAP_MS = 4000;

/**
 * Choose a size tier based on total columns + viewport width. Spacious when
 * the matrix comfortably fits within ~1.5 × viewport, medium when it fits in
 * ~1.8 × viewport, else dense. The goal is "most pills visible most of the time".
 */
function chooseMatrixSizeTier(columnCount, viewportWidth) {
  const fits = (spec) => columnCount * (spec.width + spec.gap);
  if (fits(MATRIX_SPECS.spacious) <= viewportWidth * 1.5) return 'spacious';
  if (fits(MATRIX_SPECS.medium)   <= viewportWidth * 1.8) return 'medium';
  return 'dense';
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

/** SVG body glyph (stick figure) or rest glyph (tick in circle). */
function glyphSVG(isRest) {
  if (isRest) {
    return '<svg class="glyph-body" viewBox="0 0 14 14" width="14" height="14">'
         + '<circle cx="7" cy="7" r="4"/>'
         + '<path d="M4.5 7l2 1.5L9.5 5.5"/></svg>';
  }
  return '<svg class="glyph-body" viewBox="0 0 14 14" width="14" height="14">'
       + '<circle class="glyph-head" cx="7" cy="3.5" r="1.6"/>'
       + '<path d="M7 5.2v5M4 7.2l6 0M5 10.2l-1 2.2M9 10.2l1 2.2"/></svg>';
}

function shortLabelFor(slide, index) {
  if (slide.media_type === 'rest') return 'REST';
  const name = slide.name || '';
  if (!name) return String(index + 1);
  const first = name.split(/\s+/)[0] || '';
  const up = first.toUpperCase();
  return up.length > 6 ? up.substring(0, 6) : up;
}

/** Build the DOM for the matrix (columns + pills). One-time per render. */
function buildProgressMatrix() {
  if (!$matrixInner) return;

  const columns = buildMatrixColumns();
  const viewportWidth = window.innerWidth || 375;
  matrixSizeTier = chooseMatrixSizeTier(columns.length, viewportWidth);
  // The circuit tint band is drawn via the .matrix-col.is-circuit class rather
  // than a separately positioned overlay — adjacent circuit columns merge
  // seamlessly via the negative-margin rule in styles.css.

  $matrixInner.className = 'progress-matrix-inner';
  const columnsHTML = columns.map((col, colIdx) => {
    const rowsHTML = col.slideIndices.map((slideIdx) => {
      const slide = slides[slideIdx];
      const isRest = slide.media_type === 'rest';
      const sizeClass = 'size-' + matrixSizeTier;
      const restClass = isRest ? ' is-rest' : '';
      const label = shortLabelFor(slide, slideIdx);
      const glyph = glyphSVG(isRest);
      const content = matrixSizeTier === 'dense'
        ? ''
        : `<span class="pill-content">
             <span class="pill-icon">${glyph}</span>
             ${matrixSizeTier === 'spacious' ? `<span>${escapeHTML(label)}</span>` : ''}
           </span>`;
      return `<div class="pill ${sizeClass}${restClass}" data-slide="${slideIdx}">
                <span class="pill-fill"></span>
                ${content}
              </div>`;
    }).join('');

    const circuitClass = col.isCircuit ? ' is-circuit' : '';
    return `<div class="matrix-col${circuitClass}" data-col="${colIdx}">${rowsHTML}</div>`;
  }).join('');

  // ETA widget — last grid column in the matrix. Scrolls with the matrix by
  // virtue of being a child of .progress-matrix-inner; its content is driven
  // separately by the updateEtaDisplay() tick so the wall-clock drifts while
  // paused (see pattern note at calculateRemainingWorkoutSeconds()).
  const etaHTML = `
    <div class="matrix-eta" id="matrix-eta" aria-live="polite">
      <div class="matrix-eta-remaining">
        <span class="matrix-eta-remaining-value" id="matrix-eta-remaining">0:00</span><span class="matrix-eta-remaining-suffix"> left</span>
      </div>
      <div class="matrix-eta-finish" id="matrix-eta-finish">~--:--</div>
    </div>`;

  $matrixInner.innerHTML = columnsHTML + etaHTML;

  // Cache ETA DOM refs after the innerHTML swap.
  $etaBlock = $matrixInner.querySelector('#matrix-eta');
  $etaRemaining = $matrixInner.querySelector('#matrix-eta-remaining');
  $etaFinish = $matrixInner.querySelector('#matrix-eta-finish');

  // Force layout to run so offsetLeft queries are accurate before first updateUI.
  // No-op if we can't read (jsdom etc.); cheap otherwise.
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

function openPeek(slideIdx) {
  const slide = slides[slideIdx];
  if (!slide) return;
  const name = slide.media_type === 'rest'
    ? 'Rest'
    : (slide.name || `Exercise ${slideIdx + 1}`);
  const metaParts = [];
  if (slide.sets && slide.reps) metaParts.push(`${slide.sets} × ${slide.reps}`);
  else if (slide.reps) metaParts.push(`${slide.reps} reps`);
  if (slide.hold_seconds) metaParts.push(`hold ${slide.hold_seconds}s`);
  $peekName.textContent = name;
  $peekMeta.textContent = metaParts.join(' · ');

  // Make visible first so we can measure, then position above the pill.
  $peekPanel.hidden = false;
  positionPeek(slideIdx);
}

function positionPeek(slideIdx) {
  if ($peekPanel.hidden) return;
  const pill = $matrixInner.querySelector(`.pill[data-slide="${slideIdx}"]`);
  if (!pill) return;
  const rect = pill.getBoundingClientRect();
  const panelWidth = $peekPanel.offsetWidth || 200;
  const panelHeight = $peekPanel.offsetHeight || 140;
  // Centre horizontally over the pill; clamp to viewport edges (8px margin).
  let left = rect.left + rect.width / 2 - panelWidth / 2;
  left = Math.max(8, Math.min(window.innerWidth - panelWidth - 8, left));
  const top = rect.top - panelHeight - 16;
  $peekPanel.style.left = `${left}px`;
  $peekPanel.style.top = `${Math.max(8, top)}px`;
}

function closePeek() {
  $peekPanel.hidden = true;
}

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
    hideTimerDisplay();
  }
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
 * Workout seconds left from "right now" — the active slide's remaining
 * portion plus the full duration of every slide after it.
 *
 * Pre-workout: shows total plan duration (stale finish-time-if-started-now).
 * Prep phase: add the prep runway + full active-slide duration.
 * Running / paused: use `remainingSeconds` (the 1s tick loop is authoritative).
 */
function calculateRemainingWorkoutSeconds() {
  if (!slides.length) return 0;
  if (!isWorkoutMode) {
    // Not started yet — total plan time from the current slide forward.
    return sumUpcomingDurations(currentIndex);
  }
  let active = 0;
  if (isPrepPhase) {
    active = prepRemainingSeconds + calculateDuration(slides[currentIndex]);
  } else {
    active = Math.max(0, remainingSeconds);
  }
  return active + sumUpcomingDurations(currentIndex + 1);
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

  const secs = calculateRemainingWorkoutSeconds();
  const finishAt = new Date(Date.now() + secs * 1000);

  if ($etaRemaining) $etaRemaining.textContent = formatTime(Math.max(0, secs));
  if ($etaFinish) $etaFinish.textContent = `~${formatFinishTime(finishAt)}`;
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
  updateTimerDisplay();
  // Prep seconds are part of "remaining" — tick the ETA too.
  updateEtaDisplay();
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
  updateEtaDisplay();

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
    updateProgressMatrix();
    clearInterval(workoutTimer);
    workoutTimer = null;
    isTimerRunning = false;

    // Auto-advance
    onTimerComplete();
    return;
  }

  updateTimerDisplay();
  // Matrix active-pill fill needs a per-second nudge too.
  updateProgressMatrix();
  updateEtaDisplay();
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
  updateTimerDisplay();
  updateEtaDisplay();
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

  clearWorkoutTimer();
  clearPrepTimer();

  workoutStartTime = null;

  $workoutComplete.hidden = true;
  hideTimerDisplay();

  // Show the start workout button again
  $startWorkoutBtn.hidden = false;

  // Reset matrix state — active/completed classes drop back to idle.
  updateProgressMatrix();

  // Rebuild the matrix (which re-injects the ETA HTML replacing the "Done"
  // innerHTML, if it was set) and reset the end-state flag so the readout
  // shows the pre-workout stale total again.
  workoutCompleteFlag = false;
  buildProgressMatrix();
  updateProgressMatrix();
  updateEtaDisplay();
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

  } catch (err) {
    console.error('Failed to load plan:', err);
    $loading.hidden = true;
    $error.hidden = false;
  }
}

// Start the app
init();
