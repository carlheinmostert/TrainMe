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
// Build marker (rendered discreetly in the footer for QA)
// ============================================================
//
// MUST mirror the cache name suffix in `web-player/sw.js`. Both rev
// together — bumping one without the other will leave the version
// label stale on a freshly-cached client. Convention: drop the
// `homefit-player-` prefix; keep the `vN-slug` tail.
const PLAYER_VERSION = 'v43-loop-crossfade-rep-tick';

// ============================================================
// Native bridge (Wave 4 Phase 2)
// ============================================================
//
// When the bundle is loaded inside the Flutter-embedded WebView, the Dart
// side injects a `JavaScriptChannel` named `HomefitBridge` that accepts
// JSON-encoded messages. `window.homefitBridge` below is a thin facade
// over that channel — it lets the rest of app.js request native
// capabilities (haptic feedback, iOS audio-session category) without
// caring whether it's running in the trainer app or at
// session.homefit.studio.
//
// The facade is a NO-OP when the channel is absent — the production web
// player path never sees `HomefitBridge`, so every call below silently
// becomes a tree-shaken-in-spirit pass-through. Do NOT rely on a return
// value; these are fire-and-forget signals.
//
// Haptic kinds recognised by the Dart dispatcher:
//   'selection'      — HapticFeedback.selectionClick  (1-per-second prep tick)
//   'mediumImpact'   — HapticFeedback.mediumImpact    (prep→run transition)
//   'heavyImpact'    — HapticFeedback.heavyImpact     (reserved; slide jump)
//
// `setAudioPlayback(active)` flips the iOS AVAudioSession category to
// `.playback` so the Silent-mode switch doesn't mute the preview. The
// trainer hits this switch often mid-session and the existing native
// preview respects it — the WebView needs an explicit override to match.
(function installHomefitBridge() {
  function postBridge(payload) {
    try {
      const ch = window.HomefitBridge;
      if (!ch || typeof ch.postMessage !== 'function') return;
      ch.postMessage(JSON.stringify(payload));
    } catch (err) {
      // Swallow — the bridge is best-effort. Logging here would spam the
      // production web player (no bridge present) and the embedded one
      // (where the channel exists but the OS might reject a call).
    }
  }

  const bridge = {
    requestHaptic: function (kind) {
      if (typeof kind !== 'string' || !kind) return;
      postBridge({ type: 'haptic', kind: kind });
    },
    setAudioPlayback: function (active) {
      postBridge({ type: 'audio', active: !!active });
    },
  };

  window.homefitBridge = bridge;
  window.isHomefitEmbedded = function () {
    try {
      return !!(window.HomefitBridge && typeof window.HomefitBridge.postMessage === 'function');
    } catch (_) {
      return false;
    }
  };

  // Delegated `video.play` listener — the first time any <video> element
  // kicks off playback, flip the audio session to `.playback` so the
  // Silent switch stops muting the preview. `capture: true` lets us
  // observe the event at the document level before the video's own
  // handlers fire. One-shot — after the first success we remove the
  // listener so the bridge isn't spammed on every slide change.
  let audioActivated = false;
  function onFirstVideoPlay(evt) {
    if (audioActivated) return;
    const tgt = evt && evt.target;
    if (!tgt || tgt.tagName !== 'VIDEO') return;
    audioActivated = true;
    bridge.setAudioPlayback(true);
    document.removeEventListener('play', onFirstVideoPlay, true);
  }
  document.addEventListener('play', onFirstVideoPlay, true);
})();

// ============================================================
// State
// ============================================================

let plan = null;
let slides = [];
let currentIndex = 0;
let swipeState = { active: false, startX: 0, startY: 0, currentX: 0, startTime: 0, didSwipe: false };

// Three-treatment playback — PER SLIDE, driven by exercise.preferred_treatment.
//
// The practitioner sets a treatment per exercise in the Studio card;
// that choice travels through `get_plan_full` as `preferred_treatment`
// ('line' | 'grayscale' | 'original' | null). The web player plays
// whatever the practitioner chose — the client doesn't get a picker.
// (Mirrors Flutter mobile preview's behaviour post-2026-04-20: the
// segmented-control UI on the client surface was removed on Carl's
// call — letting the viewer change treatment mid-playback was the
// wrong mental model.)
//
// When a slide's preferred treatment has no URL available (consent
// absent / raw-archive upload missing), silently fall back to 'line'
// so the slide still plays rather than hanging on a blank frame.
const TREATMENTS = ['line', 'bw', 'original'];

/** Map the backend's wire value to the web player's internal key. */
function treatmentFromWire(wire) {
  if (wire === 'grayscale') return 'bw';
  if (wire === 'original') return 'original';
  return 'line';
}

/**
 * The effective treatment for [exercise]. Honours the practitioner's
 * per-exercise `preferred_treatment` when the corresponding URL is
 * available; else falls back to Line (the always-present default).
 *
 * Availability check considers BOTH the segmented dual-output URL
 * (Milestone P, preferred) and the untouched original URL (fallback) —
 * consent-wise they move together, but keeping the check permissive
 * ensures a plan with only one of the two still honours the
 * practitioner's sticky choice.
 */
function slideTreatment(exercise) {
  const hasGray = !!(exercise && (exercise.grayscale_segmented_url || exercise.grayscale_url));
  const hasOrig = !!(exercise && (exercise.original_segmented_url || exercise.original_url));
  // Wave 19.6 — client-controlled override beats the practitioner's pick
  // when the client has explicitly chosen a treatment in the gear popover.
  // 'auto' (default) defers to the per-exercise practitioner preference.
  // For a forced treatment we still defensively fall back to 'line' if the
  // URL isn't available (the segment is disabled in that case, but a stale
  // localStorage value from a different plan could land us here).
  if (clientTreatmentOverride !== 'auto') {
    if (clientTreatmentOverride === 'line') return 'line';
    if (clientTreatmentOverride === 'bw') return hasGray ? 'bw' : 'line';
    if (clientTreatmentOverride === 'original') return hasOrig ? 'original' : 'line';
  }
  const candidate = treatmentFromWire(exercise && exercise.preferred_treatment);
  if (candidate === 'bw' && !hasGray) return 'line';
  if (candidate === 'original' && !hasOrig) return 'line';
  return candidate;
}

// Workout timer state
let isWorkoutMode = false;
let isTimerRunning = false;
let remainingSeconds = 0;
let totalSeconds = 0;
let workoutTimer = null;
let workoutStartTime = null;

// ------------------------------------------------------------------
// Milestone Q — Post Rep Breather state.
//
// Tracks the per-exercise set/rest structure for the active slide so
// the 1-second tick loop can pause the video at set boundaries, count
// down the breather, then resume video playback from the paused frame
// (no currentTime reset = continuous playback). All fields reset on
// every slide transition via `beginSetMachineForCurrent()`.
// ------------------------------------------------------------------
// Current set index (0-based). Incremented when the in-set timer hits
// zero; bumped again at the end of the breather.
let currentSetIndex = 0;
// Total sets for the active slide (cached; same as slides[currentIndex].sets).
let totalSetsForSlide = 1;
// 'set' | 'rest'. 'rest' means we're inside the inter-set breather.
let setPhase = 'set';
// Phase-local remaining seconds — counts down from the per-set duration
// (or breather seconds). When zero, transitions to the next phase.
let setPhaseRemaining = 0;
// Breather seconds for the active slide (cached).
let interSetRestForSlide = 0;

// ------------------------------------------------------------------
// Wave 19.7 — Dual-video crossfade + rep-tick on loop seam.
//
// Short clips loop visibly: iOS Safari has a 30-100ms hiccup at the
// natural-end → seek-to-0 → resume seam. We hide the hiccup by playing
// two stacked `<video>` elements with the same source and crossfading
// between them ~250ms before the active one ends. The crossfade
// plumbing IS the loop detector, so it also drives the per-slide rep
// counter (Set 1 · {currentRepInSet} of {reps}) + a 200ms scale/glow
// pulse on the active set segment.
//
// State shape:
//   loopState[slideIndex] = {
//     activeSlot: 'a' | 'b',
//     prebuffered: boolean,        // inactive video already kicked off
//     scheduled: boolean,          // rAF/timeout in flight; do not double-arm
//     timupHandler, endedHandler,  // bound listeners for cleanup
//     repsInSet: number,           // current rep within the active set
//   }
// Skipped entirely for: photos, rest slides, videos longer than
// LOOP_CROSSFADE_MAX_DURATION (no perceptual seam at low loop frequency).
// ------------------------------------------------------------------
const LOOP_CROSSFADE_LEAD_MS = 250;     // preroll the inactive video this far before duration
const LOOP_CROSSFADE_MIN_DURATION = 1.2; // < this → fall back to native loop (too short for crossfade)
const LOOP_CROSSFADE_MAX_DURATION = 12;  // > this → seam is rare, skip the dual-video machinery
const REP_TICK_PULSE_MS = 200;
const loopState = new Map();

// Prep-countdown state. Default runway is 5s (Wave 3 / Milestone P);
// each exercise can override via `prep_seconds` on the get_plan_full
// payload. Resolve per slide via `prepSecondsFor(slide)` rather than
// reading PREP_SECONDS directly.
const PREP_SECONDS = 5;
let isPrepPhase = false;
let prepRemainingSeconds = 0;
let prepTimer = null;

/**
 * Resolve the effective prep-countdown seconds for a given slide.
 * Honours the per-exercise override when set; otherwise the default.
 * Non-positive overrides fall back to the default — keeps the UI
 * from freezing on a zero runway if bad data ever lands.
 */
function prepSecondsFor(slide) {
  const override = slide && slide.prep_seconds;
  if (typeof override === 'number' && override > 0) return override;
  return PREP_SECONDS;
}

// Runtime mute state for the client-facing player. Decoupled from
// play/pause (Wave 3 fix — test items 3 / 4 / 5). Tapping the speaker
// icon on any video card flips this flag; we push the new value to
// every rendered <video> element without touching its paused/playing
// state. Persists across slide changes within the same session.
let isMuted = false;

// Segmented-background-effect opt-out (Milestone P toggle — 2026-04-23).
//
// When ON (default) the Color + B&W treatments prefer the segmented
// dual-output mp4 that dims the background behind the body. When OFF
// they play the untouched raw-archive original. Line treatment is
// unaffected either way — it's a separate pipeline.
//
// Per-device preference: read from localStorage at boot, written back
// on toggle. No server round-trip. Key is explicit + namespaced so
// future playback prefs (inter-set rest, autoplay-next, ...) can stack
// under `homefit.playback.*`.
const SEGMENTED_EFFECT_STORAGE_KEY = 'homefit.playback.segmentedEffect';
let segmentedEffectEnabled = readSegmentedEffectPreference();

function readSegmentedEffectPreference() {
  try {
    const raw = window.localStorage.getItem(SEGMENTED_EFFECT_STORAGE_KEY);
    if (raw === 'off') return false;
    // Default ON — treat any other value (including nulls, legacy data,
    // or a future 'on') as enabled. The toggle only stores 'on' | 'off'.
    return true;
  } catch (_) {
    // Private-mode Safari / blocked storage — fall back to the default.
    return true;
  }
}

function writeSegmentedEffectPreference(enabled) {
  try {
    window.localStorage.setItem(SEGMENTED_EFFECT_STORAGE_KEY, enabled ? 'on' : 'off');
  } catch (_) {
    // Best-effort; if storage is blocked the in-memory flag still drives
    // this session's playback — we just lose persistence across reloads.
  }
}

// ----------------------------------------------------------------
// Client-controlled "Show me" treatment override (Wave 19.6).
//
// In `auto` mode (default) the player honours the practitioner's
// per-exercise `preferred_treatment` (the legacy slideTreatment()
// behaviour). In `line` / `bw` / `original` mode every video slide is
// forced to that treatment, ignoring per-exercise picks. Photo + rest
// slides are unaffected.
//
// Stored per-plan (different plans may have different consent posture,
// so a global preference would surface "this plan doesn't have B&W"
// confusion when switching between clients on a shared device). The
// resolved planId is appended to the namespace at boot.
//
// Wire-storage values: 'auto' | 'line' | 'bw' | 'original'.
// ----------------------------------------------------------------
const TREATMENT_OVERRIDE_STORAGE_PREFIX = 'homefit.playback.treatment::';
const VALID_OVERRIDES = ['auto', 'line', 'bw', 'original'];

let clientTreatmentOverride = 'auto';

function treatmentOverrideStorageKey(planId) {
  return TREATMENT_OVERRIDE_STORAGE_PREFIX + (planId || 'unknown');
}

function readClientTreatmentOverride(planId) {
  try {
    const raw = window.localStorage.getItem(treatmentOverrideStorageKey(planId));
    if (raw && VALID_OVERRIDES.indexOf(raw) !== -1) return raw;
    return 'auto';
  } catch (_) {
    return 'auto';
  }
}

function writeClientTreatmentOverride(planId, value) {
  try {
    window.localStorage.setItem(treatmentOverrideStorageKey(planId), value);
  } catch (_) {
    // Storage blocked — in-memory flag still drives this session.
  }
}

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
const $btnPrev = document.getElementById('btn-prev');
const $btnNext = document.getElementById('btn-next');

// Top-stack v2 refs — workout timeline strip + active-slide header are
// direct children of #app. Wave 19.2 retired the 3-number matrix ETA
// bar: start/finish wall clocks live in the timeline strip; remaining
// time moved into the active-slide header in parens; per-slide
// estimates live inside each pill.
const $timelineBar = document.getElementById('workout-timeline-bar');
const $timelineStart = document.getElementById('workout-timeline-start');
const $timelineTotal = document.getElementById('workout-timeline-total');
const $timelineEnd = document.getElementById('workout-timeline-end');
const $activeSlideHeader = document.getElementById('active-slide-header');
const $activeSlideTitle = document.getElementById('active-slide-title');

// Progress-pill matrix refs
const $matrix = document.getElementById('progress-matrix');
const $matrixInner = document.getElementById('progress-matrix-inner');
const $matrixChevron = document.getElementById('progress-matrix-chevron');

// Video-as-hero overlay refs
const $btnFullscreen = document.getElementById('btn-fullscreen');
const $restCountdownOverlay = document.getElementById('rest-countdown-overlay');
const $restCountdownNumber = document.getElementById('rest-countdown-number');
const $cardNotes = document.getElementById('card-notes');
const $cardNotesText = document.getElementById('card-notes-text');

// Milestone Q — inter-set rest overlays.
//   * #set-progress-bar sits above the media on every exercise slide
//     that has sets > 1 OR a breather > 0. It's a horizontal strip of
//     segments: coral for set phases, sage for breather phases. The
//     active segment fills smoothly with its phase-local countdown;
//     completed segments are solid, upcoming segments are outlined.
//   * #breather-overlay sits on top of the paused video and shows a
//     big sage countdown number + a restful-person glyph during the
//     inter-set breather. Hidden outside breathers.
const $setProgressBar = document.getElementById('set-progress-bar');
const $breatherOverlay = document.getElementById('breather-overlay');
const $breatherNumber = document.getElementById('breather-number');

// Wall-clock ticker for the ETA widget. Runs 1/sec so the finish-time label
// keeps drifting forward while the workout is paused (remaining holds steady,
// now() advances → finish = now + remaining also advances). Independent of
// the workoutTimer and prepTimer.
let etaClockTimer = null;

// Workout timer DOM refs (legacy chip is gone per item 7 — see the stub
// <div id="timer-overlay" hidden> kept for backward compatibility).
const $timerOverlay = document.getElementById('timer-overlay');
const $workoutComplete = document.getElementById('workout-complete');
const $workoutCompleteIcon = document.getElementById('workout-complete-icon');
const $workoutTotalTime = document.getElementById('workout-total-time');
const $workoutCloseBtn = document.getElementById('workout-close-btn');
const $startWorkoutBtn = document.getElementById('start-workout-btn');
const $footerLogo = document.getElementById('footer-logo');

// Top-stack v1 — ambient fullscreen mode. Tapping the video surface in
// fullscreen briefly reveals chrome (chevrons, mute, notes, fullscreen
// toggle) at 100% alpha for 3s, then they fade back to ~30%.
let chromeRevealTimer = null;
const CHROME_REVEAL_MS = 3000;

// iPhone Safari does not expose Element.requestFullscreen (the WebKit
// variant is iPad/macOS only). When the real API is unavailable we fall
// back to a CSS-only "faux" fullscreen: toggle body.is-fullscreen directly
// + lock document scroll. All downstream layout already keys off the body
// class, so faux mode gets the full ambient layout (the only visible
// difference is that Safari's own URL bar stays on screen).
let fauxFullscreenActive = false;
let fauxFullscreenPrevHtmlOverflow = '';
let fauxFullscreenPrevBodyOverflow = '';

// ============================================================
// Data fetching
// ============================================================

function getPlanIdFromURL() {
  // Wave 4 Phase 1 — unified player prototype. When the bundle is served
  // by the Flutter-embedded local server, the URL shape is
  // `http://127.0.0.1:<port>/?planId=<id>&src=local` (no /p/<id> path
  // prefix because the local server is free of the Vercel rewrite rules).
  // Prefer the query-string resolver from api.js when it signals local.
  try {
    if (window.HomefitApi && window.HomefitApi.isLocalSurface && window.HomefitApi.isLocalSurface()) {
      return window.HomefitApi.getLocalPlanId();
    }
  } catch (_) {
    // Fall through to the path-based resolver.
  }
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
  //
  // Three-treatment (2026-04-19): HomefitApi.getPlanFull now normalises
  // each exercise so `line_drawing_url` / `grayscale_url` / `original_url`
  // are always-present-but-nullable keys. The renderer's segmented
  // control uses the nulls to disable B&W / Original tabs.
  const payload = await window.HomefitApi.getPlanFull(planId);

  // Reshape: RPC returns { plan: {...}, exercises: [...] }. The renderer
  // expects a flat plan object with exercises nested as a property.
  const plan = { ...payload.plan, exercises: payload.exercises || [] };
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

  // Build the progress-pill matrix (replaces legacy single linear bar).
  buildProgressMatrix();

  // Prime the ETA widget and start its wall-clock ticker. The ticker runs
  // for the lifetime of the session so the finish-time drifts forward even
  // during paused states.
  updateTimelineBar();
  startTimelineClock();

  // Build exercise cards. Top-stack v1 — the card body carries only the
  // media (video + overlays). Name, grammar, notes are rendered by the
  // top-stack renderer updateActiveSlideHeader() + updateCardNotes().
  $cardTrack.innerHTML = slides.map((slide, i) => buildCard(slide, i)).join('');

  // Prime the top-stack header + notes overlay for the first slide.
  updateActiveSlideHeader();
  updateCardNotes();

  updateUI();
  // Wave 19.3 fix: the pause overlay is baked with play-icon-default in
  // buildMediaPauseOverlay(), but the initial glyph state should reflect
  // "video is playing" (= PAUSE glyph) on first paint. updateUI() does not
  // touch the overlay so we flip it explicitly here — otherwise the first
  // time the user sees fullscreen they get a dimmed ▶ instead of ||.
  updatePauseOverlay();
}

function buildCard(slide, index) {
  // Rest card
  if (slide.media_type === 'rest') {
    return buildRestCard(slide, index);
  }

  const mediaHTML = buildMedia(slide, index);
  const mediaType = slide.media_type === 'video' ? 'video' : 'photo';

  return `
    <div class="exercise-card" data-index="${index}" data-media-type="${mediaType}">
      <div class="card-inner">
        <div class="card-media" data-media-index="${index}">
          ${mediaHTML}
          ${buildMediaPauseOverlay()}
          ${buildPrepOverlay()}
        </div>
      </div>
    </div>
  `;
}

function buildRestCard(slide, index) {
  // Rest card: icon + "Rest" title + "Next up: X" subtitle. Name + grammar
  // live in the top-stack active-slide-header (not inside the card). Tap
  // to pause/resume is via the same .media-pause-overlay as exercise slides.
  const nextSlide = index < slides.length - 1 ? slides[index + 1] : null;
  const nextUpName = nextSlide ? (nextSlide.name || 'Next exercise') : null;

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
  // Wave 19.3: default the visible glyph to PAUSE because the video begins
  // playing on first paint (preview autoplay). updatePauseOverlay() then
  // swaps to PLAY only during the explicit mid-workout paused state.
  return `
    <div class="media-pause-overlay">
      <div class="pause-disc">
        <svg class="pause-icon pause-icon-play" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true" hidden>
          <polygon points="6 3 20 12 6 21 6 3"/>
        </svg>
        <svg class="pause-icon pause-icon-pause" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
          <rect x="6" y="4" width="4" height="16" rx="1"/>
          <rect x="14" y="4" width="4" height="16" rx="1"/>
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
 * Decoded grammar for the active slide — flat list of prescription tokens
 * that gets appended to the exercise name on the single-line title row.
 *   Standalone exercise: `3 sets · 10 reps · 5s hold`
 *   Circuit exercise:    `10 reps · 5s hold`  (sets suppressed — circuits own the count)
 *   Rest:                `30s rest`
 * Returns a plain string (no HTML) — the caller sets textContent.
 */
function buildDecodedGrammar(slide) {
  if (!slide) return '';
  if (slide.media_type === 'rest') {
    const secs = Number.parseInt(slide.hold_seconds, 10)
      || Number.parseInt(slide.custom_duration_seconds, 10)
      || 30;
    return `${secs}s rest`;
  }

  const parts = [];
  const isCircuit = !!slide.circuitRound;
  const setsRaw = Number.parseInt(slide.sets, 10);
  const repsRaw = Number.parseInt(slide.reps, 10);
  const holdRaw = Number.parseInt(slide.hold_seconds, 10);
  const hasSets = Number.isFinite(setsRaw) && setsRaw > 0;
  const hasReps = Number.isFinite(repsRaw) && repsRaw > 0;
  const hasHold = Number.isFinite(holdRaw) && holdRaw > 0;
  // Wave 19.4: full defaults — every exercise reads as `{sets} sets · {reps}
  // reps [· Ts hold]`. The earlier isometric short-circuit (suppressed reps
  // when only hold was captured) caused three consecutive circuit exercises
  // to show "30s hold", "10 reps", and "5 reps" — visibly inconsistent. Now
  // reps always shows (defaulting to 10 when null); hold appends when set.
  const sets = hasSets ? setsRaw : 3;
  const reps = hasReps ? repsRaw : 10;

  if (!isCircuit) parts.push(`${sets} sets`);
  parts.push(`${reps} reps`);
  if (hasHold) parts.push(`${holdRaw}s hold`);

  return parts.join(' · ');
}

/**
 * Top-stack active-slide header — single-line row "{name} · {grammar}".
 * Renders the currently focused slide (or upcoming during prep). The circuit
 * "Round X of Y" suffix was dropped — the progress-pill matrix already shows
 * circuit position visually, so the extra text was redundant. The row uses
 * CSS white-space:nowrap + text-overflow:ellipsis to truncate if the
 * combined string is wider than the viewport.
 */
function updateActiveSlideHeader() {
  if (!$activeSlideTitle) return;
  const slide = slides[currentIndex];
  if (!slide) {
    $activeSlideTitle.textContent = '';
    $activeSlideTitle.classList.remove('is-rest');
    return;
  }

  const isRest = slide.media_type === 'rest';
  const name = isRest ? 'Rest' : (slide.name || `Exercise ${currentIndex + 1}`);
  const grammar = buildDecodedGrammar(slide);
  // Wave 19.3: trailing "(MM:SS)" removed from the title — the remaining
  // total now lives in the centre of the timeline strip directly above
  // the matrix. Per-pill durations carry the per-slide number.
  $activeSlideTitle.textContent = grammar ? `${name} · ${grammar}` : name;
  $activeSlideTitle.classList.toggle('is-rest', isRest);
}

/**
 * Top-stack notes overlay — shown as plain coral text at the bottom of
 * the video (no box). Populated per active slide; hidden if the slide has
 * no notes. Tap toggles a 3-line clamp → full expansion.
 */
function updateCardNotes() {
  if (!$cardNotes || !$cardNotesText) return;
  const slide = slides[currentIndex];
  // Rest slides have no notes; exercise slides might.
  if (slide && slide.media_type !== 'rest' && slide.notes) {
    $cardNotesText.textContent = slide.notes;
    $cardNotes.hidden = false;
    $cardNotes.classList.remove('is-expanded');
    $cardNotes.setAttribute('aria-expanded', 'false');
  } else {
    $cardNotesText.textContent = '';
    $cardNotes.hidden = true;
    $cardNotes.classList.remove('is-expanded');
    $cardNotes.setAttribute('aria-expanded', 'false');
  }
}

function buildMedia(exercise, index) {
  // Each slide plays whatever treatment the practitioner chose on its
  // own exercise (preferred_treatment from get_plan_full). No global /
  // viewer-driven switching; the mental model is "practitioner prescribes
  // the visual, client just watches". slideTreatment() already falls
  // back to 'line' when the preferred treatment's URL is missing, so
  // resolveTreatmentUrl's null branch is only hit for rest slides
  // (handled below) or exercises with no media at all.
  const slideT = slideTreatment(exercise);
  const resolvedUrl = resolveTreatmentUrl(exercise, slideT);

  if (!resolvedUrl) {
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
    // Muted attribute gating:
    //   * exercise.include_audio === false → always muted (publish-time
    //     opt-out; the client never hears audio for this exercise).
    //   * exercise.include_audio === true + runtime isMuted=true → muted
    //     (Wave 3 decouple — the speaker overlay toggled the runtime flag
    //     without pausing playback).
    //   * exercise.include_audio === true + runtime isMuted=false → audio on.
    const shouldMute = !exercise.include_audio || isMuted;
    const mutedAttr = shouldMute ? 'muted' : '';
    const posterAttr = exercise.thumbnail_url ? `poster="${escapeHTML(exercise.thumbnail_url)}"` : '';
    // Mute affordance — only rendered when the exercise ships with
    // audio (no point showing a mute button on a silent clip). Tap
    // flips isMuted, re-syncs every live <video> element, redraws the
    // icon. Lives in its own overlay layer so it's clickable without
    // competing with the card's tap-to-pause gesture (stopPropagation
    // in toggleMuteButton).
    const muteButton = exercise.include_audio ? `
      <button
        type="button"
        class="mute-toggle"
        data-video-index="${index}"
        aria-label="${isMuted ? 'Unmute audio' : 'Mute audio'}"
        aria-pressed="${isMuted ? 'true' : 'false'}"
      >
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
          ${isMuted
            ? '<polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5"/><line x1="23" y1="9" x2="17" y2="15"/><line x1="17" y1="9" x2="23" y2="15"/>'
            : '<polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5"/><path d="M15.54 8.46a5 5 0 0 1 0 7.07"/><path d="M19.07 4.93a10 10 0 0 1 0 14.14"/>'
          }
        </svg>
      </button>
    ` : '';
    // Dual-video crossfade (Wave 19.7). Two stacked <video> elements
    // share the same source — the "active" one plays normally; ~250ms
    // before it reaches `duration` we preroll the inactive one and swap
    // visible-active via opacity. Eliminates the iOS Safari loop-seam
    // hiccup. The native `loop` attribute stays as a fallback so the
    // slide still cycles even if the prebuffer trigger misses
    // (network-slow, duration < crossfade window). The loop-detector
    // also drives the rep tick; see scheduleNextLoopBoundary() +
    // handleLoopBoundary().
    //
    // `video-${index}` is kept on the primary element for backward
    // compatibility with every getElementById call in app.js — the
    // legacy "active video" lookups still resolve to the right slot.
    // The secondary lives at `video-${index}-b` and is paused by
    // default at frame 0.
    const grayscaleClass = slideT === 'bw' ? 'is-grayscale' : '';
    return `
      <div class="video-loop-pair" data-pair-index="${index}">
        <video
          id="video-${index}"
          class="video-loop-slot ${grayscaleClass}"
          src="${escapeHTML(resolvedUrl)}"
          data-treatment="${slideT}"
          data-active="true"
          data-loop-slot="a"
          playsinline
          loop
          ${mutedAttr}
          preload="auto"
          ${posterAttr}
        ></video>
        <video
          id="video-${index}-b"
          class="video-loop-slot ${grayscaleClass}"
          src="${escapeHTML(resolvedUrl)}"
          data-treatment="${slideT}"
          data-active="false"
          data-loop-slot="b"
          playsinline
          loop
          muted
          preload="auto"
          ${posterAttr}
          aria-hidden="true"
        ></video>
      </div>
      ${muteButton}
    `;
  }

  // Photo / image
  const posterAttr = exercise.thumbnail_url ? exercise.thumbnail_url : resolvedUrl;
  return `<img src="${escapeHTML(posterAttr)}" alt="${escapeHTML(exercise.name || 'Exercise')}" loading="lazy">`;
}

/**
 * Resolve the URL for a given exercise + treatment.
 *
 *   'line'     → line_drawing_url (always present on post-migration plans;
 *                falls back to legacy `media_url` for old plans). Never
 *                gated by the segmented-effect toggle — line drawing is
 *                its own pipeline, not a dual-output variant.
 *   'bw'       → grayscale_segmented_url || grayscale_url, toggle ON
 *                (default). When the per-device toggle is OFF we skip
 *                the segmented variant and play the untouched original
 *                directly — same source, no body-pop effect. CSS
 *                grayscale filter is applied to the <video> either way.
 *   'original' → original_segmented_url || original_url, toggle ON
 *                (default). Toggle OFF → untouched original only.
 *
 * Segmented-first preference: Milestone P (2026-04-23) adds a dual-output
 * mp4 alongside the line drawing that reuses the same Vision person-
 * segmentation mask — body pristine, background dimmed. Using it for the
 * Color + B&W treatments keeps the body-pop effect consistent across
 * all three treatments. Legacy plans + exercises captured before the
 * dual-output pass shipped still render correctly via the untouched
 * original fallback.
 *
 * Returns null when the treatment has no URL (consent-absent). Callers
 * must handle this gracefully (disable segment + fall back to line).
 */
function resolveTreatmentUrl(exercise, treatment) {
  if (!exercise) return null;
  if (treatment === 'bw') {
    if (segmentedEffectEnabled) {
      return exercise.grayscale_segmented_url || exercise.grayscale_url || null;
    }
    // Toggle OFF — skip the segmented variant entirely and play the
    // untouched original. When the raw original is missing we still
    // fall through to the segmented copy so the slide can play at all
    // (rare — would only happen on a mangled upload).
    return exercise.grayscale_url || exercise.grayscale_segmented_url || null;
  }
  if (treatment === 'original') {
    if (segmentedEffectEnabled) {
      return exercise.original_segmented_url || exercise.original_url || null;
    }
    return exercise.original_url || exercise.original_segmented_url || null;
  }
  // 'line' + unknown treatments → line drawing (the always-available default).
  return exercise.line_drawing_url || exercise.media_url || null;
}

// buildPrescription() was retired alongside .rx-pill in the top-stack v1
// refactor — the decoded grammar (e.g. "3 sets · 10 reps · 5s hold") now
// lives as plain text appended to the exercise name in .active-slide-title
// above the video. See buildDecodedGrammar() + updateActiveSlideHeader().

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
 * Pick the LARGEST tier that fits the viewport without horizontal scroll.
 * Top-stack v1: the ETA now lives on its own row above the matrix, so the
 * matrix has the full viewport width to play with (minus the side padding).
 * Only drops down a tier when a tier genuinely overflows. When even 'dense'
 * doesn't fit we stay on 'dense' and accept scroll (rare — only enormous
 * plans).
 */
const MATRIX_SIDE_PADDING = 32;  // 16px each side

function chooseMatrixSizeTier(columnCount, viewportWidth) {
  const available = viewportWidth - MATRIX_SIDE_PADDING;
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
 * Collapse the unrolled slides into a flat block list for the matrix.
 *
 * Wave 19 change (2026-04-22): Circuits now render ROW-FIRST instead of
 * column-first. A circuit becomes ONE .matrix-circuit block whose children
 * are N_rounds × N_exercises pills, laid out row-by-row so round 1's pills
 * (exercise A, B, C) sit on the top row, round 2's on the next row, etc.
 * Each row gets a coral tint band. This matches real execution order:
 * do A, B, C (round 1), then A, B, C (round 2), ...
 *
 * Standalone (non-circuit) slides still render as a .matrix-col with one pill.
 *
 * Returns blocks: [
 *   { kind: 'single', slideIndex },
 *   { kind: 'circuit', circuitId, rounds: [[slideIdx,...], ...], groupSize },
 * ]
 */
function buildMatrixBlocks() {
  const blocks = [];
  let i = 0;
  while (i < slides.length) {
    const s = slides[i];
    if (!s.circuitRound) {
      blocks.push({ kind: 'single', slideIndex: i });
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
    // rounds[roundIdx] = [slideIdx_exerciseA, slideIdx_exerciseB, ...]
    const rounds = [];
    for (let cycle = 1; cycle <= total; cycle++) {
      const row = [];
      for (let pos = 0; pos < groupSize; pos++) {
        row.push(groupStart + (cycle - 1) * groupSize + pos);
      }
      rounds.push(row);
    }
    blocks.push({ kind: 'circuit', circuitId, rounds, groupSize });
    i = groupStart + groupSize * total;
  }
  return blocks;
}

/**
 * Backwards-compat shim for call sites that still ask for "columns".
 * Returns the flattened column count the matrix will paint — a single is
 * 1 column, a circuit contributes groupSize columns (one per exercise slot).
 * Used by chooseMatrixSizeTier() to pick a size tier that fits the viewport.
 */
function countMatrixColumns(blocks) {
  let n = 0;
  for (const b of blocks) {
    if (b.kind === 'single') n += 1;
    else n += b.groupSize;
  }
  return n;
}

// Legacy glyph/label helpers removed — pills are empty per item 1. The
// pillGrammarLabel() function (defined above) preserves the number-grammar
// spec (item 12) for a future re-enable.

/** Build the DOM for the matrix (singles + circuit blocks). One-time per render. */
function buildProgressMatrix() {
  if (!$matrixInner) return;

  const blocks = buildMatrixBlocks();
  const viewportWidth = window.innerWidth || 375;
  matrixSizeTier = chooseMatrixSizeTier(countMatrixColumns(blocks), viewportWidth);

  $matrixInner.className = 'progress-matrix-inner';
  const sizeClass = 'size-' + matrixSizeTier;

  /** Render a single pill's HTML. Wave 19.2: each pill carries its own
   *  estimated duration as "NNs" text clipped against the fill gradient
   *  so the glyph colour inverts (white on empty, black on coral) without
   *  a double-layer DOM. The active pill's text is replaced by the live
   *  countdown in updateProgressMatrix(). */
  const pillHTML = (slideIdx) => {
    const slide = slides[slideIdx];
    const isRest = slide.media_type === 'rest';
    const restClass = isRest ? ' is-rest' : '';
    const dur = calculateDuration(slide);
    return `<div class="pill ${sizeClass}${restClass}" data-slide="${slideIdx}" data-estimate="${dur}" style="--fill-pct: 0%">
              <span class="pill-fill"></span>
              <span class="pill-duration">${dur}s</span>
            </div>`;
  };

  const blocksHTML = blocks.map((block, blockIdx) => {
    if (block.kind === 'single') {
      const dur = calculateDuration(slides[block.slideIndex]) || 1;
      // Wave 19.3: `--pill-weight` powers duration-proportional flex in
      // fullscreen. Non-fullscreen still uses the default `flex: 1 1 0`
      // so short plans render as equal-width pills like before.
      return `<div class="matrix-col" data-col="${blockIdx}" style="--pill-weight: ${dur};">${pillHTML(block.slideIndex)}</div>`;
    }
    // Circuit: row-first grid. Each round is a coral-tinted row of N pills.
    const { rounds, groupSize } = block;
    // First cycle is authoritative for duration weights; subsequent cycles
    // inherit the same shape by construction, so we read row 0.
    const firstRow = rounds[0] || [];
    const rowDurations = firstRow.map((idx) => calculateDuration(slides[idx]) || 1);
    const circuitWeight = rowDurations.reduce((a, b) => a + b, 0) || 1;
    // Wave 19.3: weight pills WITHIN a round by duration too — but only in
    // fullscreen. We stash the duration-weighted template in --row-template-fs
    // so the fullscreen rule can swap it in. Non-fullscreen still renders
    // equal 1fr columns (driven by the default .matrix-circuit-row rule),
    // matching the singles outside the block which stay equal-weight too.
    const rowTemplate = rowDurations.map((d) => `${d}fr`).join(' ');
    const roundsHTML = rounds.map((row, roundIdx) => {
      const rowPills = row.map((slideIdx) => pillHTML(slideIdx)).join('');
      return `<div class="matrix-circuit-row" data-round="${roundIdx + 1}" style="--row-template-fs: ${rowTemplate};">${rowPills}</div>`;
    }).join('');
    return `<div class="matrix-circuit" data-circuit="${block.circuitId}" data-col="${blockIdx}" style="--circuit-cols: ${groupSize}; --circuit-weight: ${circuitWeight};">${roundsHTML}</div>`;
  }).join('');

  $matrixInner.innerHTML = blocksHTML;

  // Force layout to run so offsetLeft queries are accurate before first updateUI.
  void $matrixInner.offsetWidth;
}

/** Update visible state — active/completed classes + pill fill width.
 *  Wave 19.1 fit-to-viewport: matrix always fits, so no centering scroll. */
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
    const durEl = pill.querySelector('.pill-duration');
    // Fill percentage drives BOTH the visual band AND the glyph inversion
    // gradient — we mirror it onto a CSS custom property so the text's
    // background-clip gradient flips colour at the exact same boundary.
    let fillPct = 0;
    let durText = '';
    if (isCompleted) {
      fillPct = 100;
      // Completed pills keep their original estimate; the glyph reads black
      // on the full coral fill.
      const est = Number(pill.getAttribute('data-estimate')) || 0;
      durText = `${est}s`;
    } else if (isActive) {
      const frac = isWorkoutActive && totalSeconds > 0
        ? Math.max(0, Math.min(1, (totalSeconds - remainingSeconds) / totalSeconds))
        : 0;
      fillPct = frac * 100;
      // Active pill counts down in seconds — `NNs` keeps the digit width
      // predictable against the gradient clip.
      const showSecs = isWorkoutActive
        ? Math.max(0, remainingSeconds)
        : (Number(pill.getAttribute('data-estimate')) || 0);
      durText = `${showSecs}s`;
    } else {
      fillPct = 0;
      const est = Number(pill.getAttribute('data-estimate')) || 0;
      durText = `${est}s`;
    }
    if (fill) fill.style.width = `${fillPct}%`;
    pill.style.setProperty('--fill-pct', `${fillPct}%`);
    if (durEl && durEl.textContent !== durText) durEl.textContent = durText;
  });

  // Wave 19.1: matrix always fits the viewport (flex-distribute fit-to-width
  // + fullscreen pill cap removal), so the historical centring-scroll +
  // manual-drag scrub have nothing to do. Reset any lingering transform so
  // a viewport resize doesn't leave the matrix shifted, and keep the chevron
  // hidden unconditionally — there's nothing off-screen to chevron toward.
  $matrixInner.style.transform = '';
  matrixManualOffset = 0;
  $matrixChevron.hidden = true;
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
 * Highlight the pill currently under the user's finger during a scrub.
 * Gives tactile feedback about which slide will be jumped to on release.
 */
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
  highlightScrubbedPill(slideIdx);
  // Haptic hint (ignored on unsupported browsers).
  if (navigator.vibrate) navigator.vibrate(8);
  // Freeze active pill's fill animation while scrubbing.
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

/** Wave 19.1: with flex fit-to-viewport the matrix always fits — drag
 *  scrub has nothing to reveal, so the legacy gate is always true. */
function matrixFitsViewport() {
  return true;
}

function onMatrixTouchMove(e) {
  const touch = e.touches ? e.touches[0] : e;
  if (!touch) return;
  const dx = touch.clientX - matrixTouchStart.x;
  const dy = touch.clientY - matrixTouchStart.y;

  if (peekState.active) {
    // Slide finger during scrub — hover over new pills, haptic tick on change.
    const pill = matrixPointToPillEl(touch.clientX, touch.clientY);
    if (pill) {
      const newIdx = Number(pill.getAttribute('data-slide'));
      if (newIdx !== peekState.currentIndex) {
        peekState.currentIndex = newIdx;
        highlightScrubbedPill(newIdx);
        if (navigator.vibrate) navigator.vibrate(4);
      }
    }
    // Swallow scroll while scrubbing.
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

  // Wave 19.7 — tear down the crossfade machinery on the slide we're
  // leaving so a stale `ended` event can't tick reps on the new slide,
  // and reset rep counters on both old + new slides (mid-loop slide
  // jump should always restart the new slide's count from zero).
  teardownLoopForSlide(currentIndex);
  resetRepCounterForSlide(currentIndex);
  resetRepCounterForSlide(index);

  // Cancel any in-flight prep countdown; the new slide gets its own setup.
  clearPrepTimer();

  currentIndex = index;
  updateUI();
  // After a jump, recompute immediately so we don't wait 1s for the ticker.
  updateTimelineBar();
  // Slide state changed — re-evaluate the pause/prep overlay visibility on
  // the new active slide and hide them on the old one.
  updatePauseOverlay();
  updatePrepOverlay();
  // Wave 19.6 — Enhanced Background switch enabled-state depends on the
  // CURRENT slide's effective treatment when in `auto` mode. Re-evaluate
  // on every slide change so a swipe from a forced-line slide to a colour
  // slide flips the switch back to enabled.
  updateEnhancedBackgroundEnabled();

  // Auto-play the current slide's video (muted, looped). Safari's autoplay
  // policy may block this if there hasn't been a user gesture yet — swallow
  // the rejection so we don't crash. The first gesture (tap on the URL /
  // Start Workout button) typically unlocks it. Prep play-gating in
  // enterWorkoutPhaseForCurrent() pauses it back down during the runway.
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
  goTo(currentIndex + 1);
}

function goPrev() {
  if (isWorkoutMode) {
    clearWorkoutTimer();
    clearPrepTimer();
    isTimerRunning = false;
    isPrepPhase = false;
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
  if (prepFadeTimer) {
    clearTimeout(prepFadeTimer);
    prepFadeTimer = null;
  }
  isPrepPhase = false;
}

function autoPlayCurrentVideo() {
  const currentVideo = getActiveVideoForSlide(currentIndex);
  if (!currentVideo) return;
  currentVideo.play().catch((err) => {
    console.warn('video autoplay blocked:', err);
  });
  // Wave 19.7 — install the crossfade + rep-tick detector for this slide.
  // No-op if it's already armed, a photo/rest slide, or shorter than the
  // crossfade-min threshold (handler falls back to native loop in that
  // case anyway).
  installLoopDetectorForSlide(currentIndex);
}

// ============================================================
// Wave 19.7 — Dual-video crossfade + rep tick
// ============================================================

/**
 * The visually-active <video> for slide `idx`. Pair has slot=a (the
 * legacy `video-${idx}` element) + slot=b (`video-${idx}-b`). Pre-Wave
 * 19.7 every slot=a was THE video; the pair is rendered in a tight DOM
 * wrapper so legacy `getElementById` calls still resolve to the primary
 * element. This helper picks whichever slot is currently visible —
 * which is also whichever one is playing.
 */
function getActiveVideoForSlide(idx) {
  const a = document.getElementById(`video-${idx}`);
  if (!a) return null;
  const b = document.getElementById(`video-${idx}-b`);
  if (!b) return a;
  // data-active='true' on the visible slot. Default state is slot=a
  // active (build-time wiring in buildMedia()).
  if (a.getAttribute('data-active') === 'true') return a;
  if (b.getAttribute('data-active') === 'true') return b;
  return a;
}

function getInactiveVideoForSlide(idx) {
  const active = getActiveVideoForSlide(idx);
  if (!active) return null;
  const a = document.getElementById(`video-${idx}`);
  const b = document.getElementById(`video-${idx}-b`);
  return active === a ? b : a;
}

/**
 * Wire the loop detector + crossfade for a slide. Idempotent — safe to
 * call on every slide change. Skipped for photos, rest slides,
 * placeholder cards (no video element), or videos whose duration is
 * outside the crossfade window (handled inside the listener once
 * `loadedmetadata` fires).
 *
 * The detector listens to `timeupdate` on the active slot. ~250ms
 * before duration we preroll the inactive slot (currentTime=0,
 * play()). On `ended` we swap visible-active via CSS opacity (200ms
 * transition), reset the now-inactive slot, and fire `handleLoopBoundary`
 * which advances the rep counter + pulses the active set segment.
 *
 * `loop` stays on both elements so the visual cycle keeps going if our
 * scheduling misses (network-slow second video, duration shorter than
 * the crossfade window, etc). The `ended` event still fires under
 * native loop on iOS Safari, so the rep tick survives the fallback —
 * only the visual hiccup comes back.
 */
function installLoopDetectorForSlide(idx) {
  const slide = slides[idx];
  if (!slide || slide.media_type !== 'video') return;
  const active = getActiveVideoForSlide(idx);
  if (!active) return;

  // Already armed for this slide? Detector is per-pair, not per-slot —
  // when we swap slots we re-attach the listeners in handleLoopBoundary.
  let state = loopState.get(idx);
  if (state && state.armed) return;

  state = state || { activeSlot: 'a', repsInSet: 0, armed: false };
  state.activeSlot = active.getAttribute('data-loop-slot') || 'a';
  state.armed = true;
  state.prebuffered = false;
  loopState.set(idx, state);

  attachLoopListeners(idx, active);
}

function attachLoopListeners(idx, videoEl) {
  if (!videoEl) return;

  // `lastTime` lets timeupdate detect both:
  //   * the prebuffer trigger (currentTime > duration - LOOP_CROSSFADE_LEAD_MS)
  //   * the loop seam itself (currentTime < lastTime → just wrapped)
  // We can't rely on the `ended` event because the native `loop`
  // attribute suppresses it — the browser silently seeks back to 0
  // and continues. timeupdate fires every ~250ms on iOS Safari, which
  // is dense enough to catch both events reliably.
  let lastTime = 0;

  const onTimeUpdate = () => {
    const dur = videoEl.duration;
    if (!Number.isFinite(dur) || dur <= 0) return;
    const inWindow = dur >= LOOP_CROSSFADE_MIN_DURATION
                  && dur <= LOOP_CROSSFADE_MAX_DURATION;
    const state = loopState.get(idx);
    if (!state) { lastTime = videoEl.currentTime; return; }

    const t = videoEl.currentTime;

    // Loop-wrap detection: `loop` makes the browser seek back to 0
    // without firing `ended`. A drop of more than (duration / 2) is
    // unambiguously a wrap (rules out small skip-back jitter).
    if (lastTime > 0 && t + 0.05 < lastTime && (lastTime - t) > dur / 2) {
      lastTime = t;
      handleLoopBoundary(idx);
      return;
    }

    // Prebuffer trigger.
    if (!state.prebuffered && inWindow && (dur - t) * 1000 <= LOOP_CROSSFADE_LEAD_MS) {
      const inactive = getInactiveVideoForSlide(idx);
      if (inactive) {
        state.prebuffered = true;
        try {
          inactive.currentTime = 0;
        } catch (_) { /* metadata may not be ready */ }
        // Force-mute the prerolled slot so the ~250ms overlap window
        // doesn't play double-audio. Audio handoff happens at the
        // visible swap below (handleLoopBoundary copies oldActive.muted
        // onto the new active).
        inactive.muted = true;
        inactive.play().catch((err) => {
          // Network-slow second video — fall back to native loop for
          // this cycle. The wrap-detect branch above will still fire
          // the rep tick + reset prebuffered for next cycle.
          console.warn('crossfade preroll failed; native loop fallback:', err);
          state.prebuffered = false;
        });
      }
    }

    lastTime = t;
  };

  videoEl.addEventListener('timeupdate', onTimeUpdate);
  // `ended` may still fire if the slide ever loses its `loop` attribute
  // (defensive — keeps the rep tick alive on that path too).
  const onEnded = () => handleLoopBoundary(idx);
  videoEl.addEventListener('ended', onEnded);
  videoEl._homefitLoopHandlers = { onTimeUpdate, onEnded };
}

function detachLoopListeners(videoEl) {
  if (!videoEl || !videoEl._homefitLoopHandlers) return;
  const { onTimeUpdate, onEnded } = videoEl._homefitLoopHandlers;
  videoEl.removeEventListener('timeupdate', onTimeUpdate);
  videoEl.removeEventListener('ended', onEnded);
  videoEl._homefitLoopHandlers = null;
}

/**
 * One loop just ended on slide `idx`. Two jobs:
 *   1. Crossfade — flip data-active so the prebuffered inactive slot
 *      becomes the visible active slot. Reset the now-inactive slot to
 *      currentTime=0 + pause so it's ready for the next cycle.
 *   2. Rep tick — bump repsInSet, redraw the set-progress-bar label,
 *      pulse the active segment. When repsInSet === slide.reps, the
 *      breather/next-set state machine takes over (driven by the 1Hz
 *      tick loop, which is independent — so we just reset repsInSet
 *      to 0 and let the existing setPhase machinery handle the pause).
 */
function handleLoopBoundary(idx) {
  const slide = slides[idx];
  if (!slide) return;
  const state = loopState.get(idx);
  if (!state) return;

  // --- Crossfade -------------------------------------------------
  const oldActive = getActiveVideoForSlide(idx);
  const newActive = getInactiveVideoForSlide(idx);
  if (newActive && oldActive && newActive !== oldActive) {
    const dur = oldActive.duration || 0;
    const inWindow = dur >= LOOP_CROSSFADE_MIN_DURATION
                  && dur <= LOOP_CROSSFADE_MAX_DURATION;
    if (state.prebuffered && inWindow) {
      // Visible swap. CSS handles the 200ms opacity transition.
      newActive.setAttribute('data-active', 'true');
      oldActive.setAttribute('data-active', 'false');
      // Audio handoff: inherit the legacy mute-pref logic. The new
      // active slot adopts the muted state of the old one.
      newActive.muted = oldActive.muted;
      // The native `loop` attribute will have already restarted oldActive;
      // pause + reset it so it sits idle for the next cycle.
      try {
        oldActive.pause();
        oldActive.currentTime = 0;
      } catch (_) { /* swallow */ }
      // Re-arm listeners on the new active slot.
      detachLoopListeners(oldActive);
      attachLoopListeners(idx, newActive);
      state.activeSlot = newActive.getAttribute('data-loop-slot') || state.activeSlot;
    }
  }
  state.prebuffered = false;
  loopState.set(idx, state);

  // --- Rep tick --------------------------------------------------
  // Only count reps for the active slide and only while the workout
  // timer is actually running (a paused workout shouldn't tick reps;
  // the video is paused too so this branch is mostly defensive).
  if (idx !== currentIndex) return;
  if (!isWorkoutMode || !isTimerRunning || isPrepPhase || setPhase !== 'set') return;

  // Wave 19.5 follow-up — do NOT fabricate a rep target on legacy data
  // (slide.reps null/0). Let the counter free-run for the visual label;
  // the 1Hz tick + advanceSetPhase() owns the time-based set→rest
  // transition for those slides. Only reset on real reps targets.
  const targetReps = slide.reps && slide.reps > 0 ? slide.reps : null;
  state.repsInSet = (state.repsInSet || 0) + 1;
  if (targetReps !== null && state.repsInSet >= targetReps) {
    // Set complete from a rep-counting perspective. The set→rest
    // transition itself is owned by the 1Hz tick + advanceSetPhase(),
    // so we don't fire it here — worst case they're a tick apart
    // visually, which is below perceptual budget.
    state.repsInSet = 0;
  }
  loopState.set(idx, state);

  // Repaint the set-progress-bar label + flash the active segment.
  updateSetProgressBar();
  pulseActiveSetSegment();
}

/** Trigger the 200ms scale + glow pulse on the active set segment. */
function pulseActiveSetSegment() {
  if (!$setProgressBar) return;
  const seg = $setProgressBar.querySelector('.set-progress-bar-segment--active');
  if (!seg) return;
  seg.classList.remove('is-rep-pulse');
  // Force a reflow so the animation restarts on consecutive reps.
  // eslint-disable-next-line no-unused-expressions
  void seg.offsetWidth;
  seg.classList.add('is-rep-pulse');
  setTimeout(() => {
    seg.classList.remove('is-rep-pulse');
  }, REP_TICK_PULSE_MS);
}

/** Reset the rep-in-set counter for the active slide (slide jump, set boundary). */
function resetRepCounterForSlide(idx) {
  const state = loopState.get(idx);
  if (!state) return;
  state.repsInSet = 0;
  loopState.set(idx, state);
}

/**
 * Cleanup loop machinery for a slide we're navigating away from. Pause
 * + zero both slots so we free the decoder; detach listeners so a
 * stale `ended` event on a backgrounded slide can't tick reps on the
 * new slide. State entry stays in the map so the rep counter survives
 * a back-swipe — installLoopDetectorForSlide() will re-arm listeners.
 */
function teardownLoopForSlide(idx) {
  const a = document.getElementById(`video-${idx}`);
  const b = document.getElementById(`video-${idx}-b`);
  [a, b].forEach((v) => {
    if (!v) return;
    detachLoopListeners(v);
    try { v.pause(); } catch (_) { /* swallow */ }
  });
  const state = loopState.get(idx);
  if (state) {
    state.armed = false;
    state.prebuffered = false;
    loopState.set(idx, state);
  }
}

function updateUI() {
  const total = slides.length;

  // Slide the track
  $cardTrack.style.transform = `translateX(-${currentIndex * 100}%)`;

  // Progress text
  $progress.textContent = `${currentIndex + 1} of ${total}`;

  // Progress-pill matrix — active pill state + centring scroll
  updateProgressMatrix();

  // Top-stack header + notes — name + grammar + coral notes blob.
  updateActiveSlideHeader();
  updateCardNotes();

  // Rest countdown overlay state — shown only on the active rest slide.
  updateRestCountdownOverlay();

  // Milestone Q — set/breather overlays track the active slide too.
  updateSetProgressBar();
  updateBreatherOverlay();

  // Nav buttons
  $btnPrev.disabled = currentIndex === 0;
  $btnNext.disabled = currentIndex === total - 1;
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
  // Escape closes the settings popover before any slide-nav gesture —
  // the user's mental model is "dismiss the panel I just opened", not
  // "go somewhere else".
  if (e.key === 'Escape' && isSettingsPopoverOpen()) {
    setSettingsPopoverOpen(false);
    return;
  }
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
 * Milestone Q — return the practitioner-configured inter-set rest
 * ("Post Rep Breather") for a slide, clamped to 0 for null values.
 * Legacy rows (null) compute WITHOUT any inter-set rest — this is a
 * deliberate behaviour change on re-publish, acceptable per the brief.
 * The 30s REST_BETWEEN_SETS baseline is retired.
 */
function getInterSetRestSeconds(slide) {
  const v = slide.inter_set_rest_seconds;
  if (v === null || v === undefined) return 0;
  return Math.max(0, Number(v) | 0);
}

/**
 * Milestone Q — per-set duration (reps × per-rep + hold). Exposed as
 * a helper so the set/rest state machine can derive set boundaries
 * consistently with the total duration.
 */
function calculatePerSetSeconds(slide) {
  if (slide.custom_duration_seconds) {
    // Manual total / sets; rounded down to the nearest integer second.
    const sets = slide.sets || 1;
    if (sets <= 1) return slide.custom_duration_seconds;
    return Math.max(1, Math.floor(slide.custom_duration_seconds / sets));
  }
  const reps = slide.reps || 10;
  const holdPerSet = slide.hold_seconds || 0;
  return (reps * SECONDS_PER_REP) + holdPerSet;
}

/**
 * Calculate the duration in seconds for an exercise slide.
 * Uses custom_duration_seconds if set, otherwise computes from reps/sets/hold.
 *
 * Milestone Q math:
 *   exercise_total = sets × per_set
 *                  + max(0, sets - 1) × COALESCE(inter_set_rest_seconds, 0)
 *
 * custom_duration_seconds stores the total across all sets (per-rep ×
 * reps × sets from the Studio UI), so we add the inter-set rest ON TOP
 * of it — the practitioner's "per-rep" choice doesn't include breather
 * time.
 */
function calculateDuration(slide) {
  if (slide.media_type === 'rest') {
    return slide.hold_seconds || slide.custom_duration_seconds || 30;
  }

  const sets = slide.sets || 3;
  const breather = getInterSetRestSeconds(slide);
  const restTotal = (sets > 1) ? (sets - 1) * breather : 0;

  if (slide.custom_duration_seconds) {
    return slide.custom_duration_seconds + restTotal;
  }

  const perSet = calculatePerSetSeconds(slide);
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
 * Render the workout-timeline strip. Called on every workout-tick AND on an
 * independent 1s wall-clock tick so the finish time drifts forward while
 * paused. Wave 19.2: replaces the 3-number ETA row — start wall clock is
 * frozen at Start Workout, finish = now() + remainingWorkoutSeconds.
 */
function updateTimelineBar() {
  if (!$timelineStart || !$timelineEnd) return;
  // Wave 19.3: the centre slot carries the live remaining-total. Pre-start
  // it shows "0:00" so the row's intrinsic width is stable when the workout
  // kicks off; the edges show "--:--" until the start wall-clock is captured.
  if (!isWorkoutMode || !workoutStartTime) {
    $timelineStart.textContent = '--:--';
    $timelineEnd.textContent = '--:--';
    if ($timelineTotal) {
      $timelineTotal.textContent = formatTime(Math.max(0, calculateRemainingWorkoutSeconds()));
    }
    return;
  }
  $timelineStart.textContent = formatFinishTime(new Date(workoutStartTime));
  if (workoutCompleteFlag) {
    // Snapshot the real finish wall-clock at completion (Date.now() then
    // stops drifting against remainingSeconds which is 0).
    $timelineEnd.textContent = formatFinishTime(new Date());
    if ($timelineTotal) $timelineTotal.textContent = '0:00';
    return;
  }
  const totalSecs = calculateRemainingWorkoutSeconds();
  const finishAt = new Date(Date.now() + totalSecs * 1000);
  $timelineEnd.textContent = `~${formatFinishTime(finishAt)}`;
  if ($timelineTotal) $timelineTotal.textContent = formatTime(Math.max(0, totalSecs));

  // Prep-phase flash — active pill + the centred total so the client
  // perceives the "getting ready" cadence even with the title parens gone.
  if ($matrixInner) {
    const activePill = $matrixInner.querySelector('.pill.is-active');
    if (activePill) {
      activePill.classList.toggle('is-prep-flashing', isPrepPhase);
    }
  }
  if ($timelineTotal) {
    $timelineTotal.classList.toggle('is-prep-flashing', isPrepPhase);
  }
}

// Mirrors the Flutter widget.workoutComplete flag for the ETA "Done" state.
let workoutCompleteFlag = false;

function startTimelineClock() {
  if (etaClockTimer) return;
  etaClockTimer = setInterval(updateTimelineBar, 1000);
}

function stopTimelineClock() {
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

  // Top-stack v1 — request browser fullscreen so the video fills the
  // viewport. Must be inside the button's click gesture; the browser
  // rejects the API call otherwise.
  requestFullscreen();

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
  updateTimelineBar();
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

  // Milestone Q — prime the set/rest state machine for this slide. The
  // per-set duration + breather seconds are cached here so the 1-second
  // tick loop can swap phases without re-reading the slide.
  beginSetMachineForCurrent();

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
 * Milestone Q — reset the set/rest state machine to the first set of
 * the active slide. Called whenever a new slide becomes active
 * (enterWorkoutPhaseForCurrent), including when the practitioner swipes
 * mid-breather — the new slide starts fresh on its first set.
 */
function beginSetMachineForCurrent() {
  const slide = slides[currentIndex];
  if (!slide || slide.media_type === 'rest') {
    currentSetIndex = 0;
    totalSetsForSlide = 1;
    setPhase = 'set';
    setPhaseRemaining = 0;
    interSetRestForSlide = 0;
    return;
  }
  currentSetIndex = 0;
  totalSetsForSlide = Math.max(1, slide.sets || 1);
  setPhase = 'set';
  setPhaseRemaining = calculatePerSetSeconds(slide);
  interSetRestForSlide = getInterSetRestSeconds(slide);
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
  // Per-exercise override when present, else the 5s global default.
  const slide = slides[currentIndex];
  prepRemainingSeconds = prepSecondsFor(slide);

  // Prep play-gating — pause + reset the video so nothing is moving
  // behind the coral countdown digits.
  gateVideoForPrep(true);

  updatePrepOverlay();
  schedulePrepFade();
  updatePauseOverlay();
  updateRestCountdownOverlay();
  // ETA now reflects prep seconds + new slide's full duration + upcoming.
  updateTimelineBar();

  prepTimer = setInterval(onPrepTick, 1000);
}

function onPrepTick() {
  if (!isPrepPhase) return;
  prepRemainingSeconds--;

  // Wave 4 Phase 2 — haptic tick every prep second when embedded in the
  // Flutter WebView. No-op on the public web player (bridge absent).
  if (window.homefitBridge) window.homefitBridge.requestHaptic('selection');

  if (prepRemainingSeconds <= 0) {
    finishPrepPhase();
    return;
  }
  updatePrepOverlay();
  schedulePrepFade();
  // Prep seconds are part of "remaining" — tick the timeline + title too.
  updateTimelineBar();
  updateActiveSlideHeader();
}

function finishPrepPhase() {
  clearPrepTimer();
  // Hide the prep overlay, drop the flash.
  updatePrepOverlay();
  // Release the prep play-gate — video resumes on the running phase.
  gateVideoForPrep(false);
  // Wave 4 Phase 2 — medium haptic on the prep→run transition so the
  // trainer feels the handoff without looking at the screen. No-op on
  // the public web player.
  if (window.homefitBridge) window.homefitBridge.requestHaptic('mediumImpact');
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
  updateRestCountdownOverlay();
  updateSetProgressBar();
  updateBreatherOverlay();
  updateTimelineBar();

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
  // Milestone Q — phase-local timer ticks in lockstep with the overall
  // remaining counter. When it hits zero we check whether another set
  // / breather follows on THIS slide before falling through to the next
  // slide.
  if (!isRestSlide()) {
    setPhaseRemaining--;
  }

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

  // Milestone Q — phase boundary inside the active slide (set → rest or
  // rest → set). The overall `remainingSeconds` keeps ticking; only the
  // phase-local counter wraps.
  if (!isRestSlide() && setPhaseRemaining <= 0) {
    advanceSetPhase();
  }

  // Matrix active-pill fill needs a per-second nudge too.
  updateProgressMatrix();
  updateRestCountdownOverlay();
  updateSetProgressBar();
  updateBreatherOverlay();
  updateTimelineBar();
  // (MM:SS) remaining rides in the active-slide title — needs a per-tick
  // refresh same as the timeline and matrix.
  updateActiveSlideHeader();
}

function isRestSlide() {
  const slide = slides[currentIndex];
  return !!(slide && slide.media_type === 'rest');
}

/**
 * Milestone Q — move from set → rest or rest → next set at a phase
 * boundary. This is the one place that pauses/resumes the active video
 * around the breather. Video currentTime is NEVER reset — pause holds
 * the last visible frame, play() resumes from there.
 *
 * Called ONLY from onTimerTick() when setPhaseRemaining hits zero AND
 * remainingSeconds > 0 (meaning more of this slide is still ahead). If
 * it's the last set, this function is never reached because
 * remainingSeconds drops to 0 at the same tick and onTimerComplete()
 * advances to the next slide.
 */
function advanceSetPhase() {
  if (setPhase === 'set') {
    // Set done. Is there a breather OR another set to come?
    const isLastSet = currentSetIndex >= totalSetsForSlide - 1;
    if (isLastSet) {
      // Last set ending coincides with remainingSeconds hitting 0;
      // onTimerTick will take the auto-advance branch. Nothing to do.
      return;
    }
    if (interSetRestForSlide > 0) {
      // Enter breather. Pause the video at its current frame (no reset).
      setPhase = 'rest';
      setPhaseRemaining = interSetRestForSlide;
      pauseActiveVideoForBreather();
    } else {
      // No breather — skip straight to the next set, keep the video
      // playing without interruption.
      currentSetIndex++;
      setPhase = 'set';
      setPhaseRemaining = calculatePerSetSeconds(slides[currentIndex]);
      // Wave 19.7 — fresh set, fresh rep count even when there's no breather.
      resetRepCounterForSlide(currentIndex);
    }
  } else {
    // rest → next set. Bump set index, resume video.
    currentSetIndex++;
    setPhase = 'set';
    setPhaseRemaining = calculatePerSetSeconds(slides[currentIndex]);
    // Wave 19.7 — fresh set, fresh rep count.
    resetRepCounterForSlide(currentIndex);
    resumeActiveVideoAfterBreather();
  }
  updateSetProgressBar();
  updateBreatherOverlay();
}

/**
 * Milestone Q — pause the active video at its current frame for the
 * inter-set breather. NO seek, NO reset — the browser holds the last
 * decoded frame visually, which is exactly what the brief specifies
 * ("continuous playback, no reset"). On resume we call play() without
 * touching currentTime.
 */
function pauseActiveVideoForBreather() {
  const video = getActiveVideoForSlide(currentIndex);
  if (video && !video.paused) {
    try { video.pause(); } catch (_) { /* best-effort */ }
  }
  // Wave 19.7 — entering the breather closes the rep window for this set.
  resetRepCounterForSlide(currentIndex);
}

function resumeActiveVideoAfterBreather() {
  if (!isTimerRunning) return;
  const video = getActiveVideoForSlide(currentIndex);
  if (video && video.paused) {
    video.play().catch((err) => {
      console.warn('video resume after breather failed:', err);
    });
  }
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
  const currentVideo = getActiveVideoForSlide(currentIndex);
  if (currentVideo && !currentVideo.paused) {
    currentVideo.pause();
  }
  updatePauseOverlay();
  updateRestCountdownOverlay();
  updateBreatherOverlay();
  // ETA clock keeps running in the background — remaining stays static,
  // finish-time drifts forward. Nudge once to reflect immediately.
  updateTimelineBar();
  // Transition already visually loud (overlay snaps to full alpha on pause)
  // but keep the flash-class for symmetry with the resume path so rapid
  // pause/resume doesn't leave a stale animation.
  flashPauseOverlay();
}

/**
 * Resume a paused timer
 */
function resumeTimer() {
  if (isTimerRunning) return;
  isTimerRunning = true;
  workoutTimer = setInterval(onTimerTick, 1000);
  // Resume video playback alongside the timer — BUT ONLY if we're in a
  // set phase. During a breather the video is meant to be paused on
  // the last visible frame; resuming the timer just continues counting
  // down the breather.
  const currentVideo = getActiveVideoForSlide(currentIndex);
  if (currentVideo && currentVideo.paused && setPhase !== 'rest') {
    currentVideo.play().catch((err) => {
      console.warn('video resume failed:', err);
    });
  }
  updatePauseOverlay();
  updateRestCountdownOverlay();
  updateBreatherOverlay();
  updateTimelineBar();
  // Flash the pause icon at full alpha for ~900ms so the tap's outcome is
  // legible on top of the running video.
  flashPauseOverlay();
}

/**
 * Item 7: single mode-aware tap handler for the media area.
 * Prep → skip prep. Running → pause. Paused → resume.
 *
 * Bail when the user just swiped, so the synthetic click that follows a
 * touchend doesn't pause/resume by accident.
 */
function handleMediaTap(e) {
  // Mute button intercepts first — it's inside .card-media but must NOT
  // trigger pause/resume. Taking the early return keeps play/pause
  // decoupled from the mute toggle (Wave 3 — test items 3 / 4 / 5).
  const muteBtn = e.target.closest ? e.target.closest('.mute-toggle') : null;
  if (muteBtn) {
    e.stopPropagation();
    toggleMute();
    return;
  }
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
 * Toggle runtime mute across every live <video> element. Decoupled from
 * playback state (Wave 3 fix — test items 3 / 4 / 5): a tap on the
 * speaker icon NEVER pauses. Also redraws the mute-toggle glyph so the
 * icon reflects the current state immediately.
 *
 * Respects the publish-time `include_audio` flag — if the exercise
 * didn't ship with audio, its video stays muted regardless (no button
 * is rendered for that exercise in the first place).
 */
function toggleMute() {
  isMuted = !isMuted;
  const videos = $cardTrack ? $cardTrack.querySelectorAll('video') : [];
  videos.forEach((video) => {
    // include_audio is encoded on the slide, not the <video> element;
    // pull it back through the card wrapper's data-media-index.
    const card = video.closest('.exercise-card');
    const idx = card ? Number(card.getAttribute('data-index')) : NaN;
    const slide = Number.isFinite(idx) ? slides[idx] : null;
    if (!slide || !slide.include_audio) {
      // Publish-time muted — leave it muted regardless.
      video.muted = true;
      return;
    }
    video.muted = isMuted;
  });
  // Redraw every visible mute button (glyph + a11y state).
  const buttons = $cardTrack
    ? $cardTrack.querySelectorAll('.mute-toggle')
    : [];
  buttons.forEach((btn) => {
    btn.setAttribute('aria-pressed', isMuted ? 'true' : 'false');
    btn.setAttribute('aria-label', isMuted ? 'Unmute audio' : 'Mute audio');
    const svg = btn.querySelector('svg');
    if (!svg) return;
    svg.innerHTML = isMuted
      ? '<polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5"/><line x1="23" y1="9" x2="17" y2="15"/><line x1="17" y1="9" x2="23" y2="15"/>'
      : '<polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5"/><path d="M15.54 8.46a5 5 0 0 1 0 7.07"/><path d="M19.07 4.93a10 10 0 0 1 0 14.14"/>';
  });
}

// ============================================================
// Settings popover — per-device playback preferences
// ============================================================
//
// Currently hosts the Milestone P segmented-effect toggle. Shaped to
// grow: the popover is a vertical stack of .settings-row entries, each
// an independent label+switch pair. Add a row by duplicating the
// existing <label> block in index.html + binding a change handler
// here. No global settings-bus needed at this scale.
//
// State lives in module-scope flags (e.g. segmentedEffectEnabled) that
// `resolveTreatmentUrl` + other renderers read directly. No event bus.

const $btnSettings = document.getElementById('btn-settings');
const $settingsPopover = document.getElementById('settings-popover');
const $toggleSegmentedEffect = document.getElementById('toggle-segmented-effect');
const $toggleSegmentedEffectHint = document.getElementById('toggle-segmented-effect-hint');
const $treatmentOverride = document.getElementById('treatment-override');
const $enhancedBackgroundRow = document.getElementById('enhanced-background-row');

// Plan-level consent rollup. `get_plan_full` only emits grayscale_url /
// original_url on exercises the client has consented to that treatment for —
// consent is plan-wide, so a single slide carrying a URL means "this plan
// has consent". Computed once after fetchPlan() lands.
let planHasGrayscaleConsent = false;
let planHasOriginalConsent = false;

function recomputePlanConsent() {
  planHasGrayscaleConsent = false;
  planHasOriginalConsent = false;
  if (!plan || !Array.isArray(plan.exercises)) return;
  for (const ex of plan.exercises) {
    if (ex && (ex.grayscale_url || ex.grayscale_segmented_url)) planHasGrayscaleConsent = true;
    if (ex && (ex.original_url || ex.original_segmented_url)) planHasOriginalConsent = true;
    if (planHasGrayscaleConsent && planHasOriginalConsent) break;
  }
}

/** Sync the hint copy to the current toggle state. */
function updateSegmentedEffectHint() {
  if (!$toggleSegmentedEffectHint) return;
  $toggleSegmentedEffectHint.textContent = segmentedEffectEnabled
    ? 'Body in focus — background dimmed'
    : 'Original untouched';
}

/** Open / close the settings popover. */
function setSettingsPopoverOpen(open) {
  if (!$settingsPopover || !$btnSettings) return;
  if (open) {
    $settingsPopover.hidden = false;
    // Next frame so the transition runs from closed → open.
    requestAnimationFrame(() => {
      $settingsPopover.setAttribute('data-open', 'true');
    });
    $btnSettings.setAttribute('aria-expanded', 'true');
  } else {
    $settingsPopover.setAttribute('data-open', 'false');
    $btnSettings.setAttribute('aria-expanded', 'false');
    // Wait for the fade-out to complete before hiding — matches the
    // 160ms transition in styles.css.
    setTimeout(() => {
      if ($settingsPopover.getAttribute('data-open') !== 'true') {
        $settingsPopover.hidden = true;
      }
    }, 180);
  }
}

function isSettingsPopoverOpen() {
  return !!($settingsPopover && $settingsPopover.getAttribute('data-open') === 'true');
}

/**
 * Apply a change to the segmented-effect toggle: persist the new
 * value, update the hint copy, and re-point every rendered <video>
 * whose treatment URL just changed. Keeps the current slide's
 * playback position and playing state so the swap is invisible if
 * the client is mid-workout.
 */
function applySegmentedEffectChange(nextEnabled) {
  if (nextEnabled === segmentedEffectEnabled) return;
  segmentedEffectEnabled = nextEnabled;
  writeSegmentedEffectPreference(segmentedEffectEnabled);
  updateSegmentedEffectHint();
  rebindVideoSources();
}

/**
 * Walk every rendered <video> in the card track, re-resolve the URL
 * its slide should now use, and swap the `src` in place if it changed.
 * For the currently active slide we preserve `currentTime` and resume
 * playback post-swap so the toggle feels seamless mid-exercise.
 *
 * Non-active slides get a naive src swap (no resume) — they're paused
 * anyway, and the next time they become active `autoPlayCurrentVideo`
 * will kick them off. This keeps memory/CPU pressure down vs. forcing
 * every video to reload + play immediately.
 */
function rebindVideoSources() {
  if (!$cardTrack) return;
  const videos = $cardTrack.querySelectorAll('video[id^="video-"]');
  videos.forEach((videoEl) => {
    const card = videoEl.closest('.exercise-card');
    if (!card) return;
    const idx = Number(card.getAttribute('data-index'));
    if (!Number.isFinite(idx)) return;
    const slide = slides[idx];
    if (!slide) return;
    const slideT = slideTreatment(slide);
    const nextUrl = resolveTreatmentUrl(slide, slideT);
    if (!nextUrl) return;
    // Treatment may have flipped (line ↔ bw ↔ original) under the client
    // override. Keep the data-attribute + grayscale CSS class in sync with
    // the live treatment so a forced-B&W slide actually goes greyscale even
    // when the underlying URL didn't change.
    videoEl.setAttribute('data-treatment', slideT);
    videoEl.classList.toggle('is-grayscale', slideT === 'bw');
    // getAttribute is the raw attribute text; videoEl.src is the
    // resolved absolute URL (prefixed with the origin). Compare via
    // the attribute for a stable check.
    const currentAttr = videoEl.getAttribute('src');
    if (currentAttr === nextUrl) return;

    const isActive = idx === currentIndex;
    const wasPlaying = isActive && !videoEl.paused && !videoEl.ended;
    const resumeAt = isActive ? videoEl.currentTime : 0;

    videoEl.setAttribute('src', nextUrl);
    // `load()` is required after a src swap for the new media to be
    // picked up reliably on all browsers (Safari in particular).
    videoEl.load();

    if (isActive) {
      // Restore playback position once metadata is loaded. `loadedmetadata`
      // fires once per src change — the { once: true } option auto-cleans.
      const restore = () => {
        try {
          // If the new source is shorter than resumeAt (shouldn't happen
          // — segmented + original are the same length — but defensive),
          // clamp to 0 so we don't stall.
          videoEl.currentTime = Math.min(resumeAt, videoEl.duration || resumeAt);
        } catch (_) {
          // Some browsers throw if currentTime is set too early; ignore.
        }
        if (wasPlaying) {
          videoEl.play().catch(() => {
            // Autoplay policy — a user gesture should have unlocked this
            // already (the toggle click counts), but swallow defensively.
          });
        }
      };
      videoEl.addEventListener('loadedmetadata', restore, { once: true });
    }
  });
}

// ----------------------------------------------------------------
// "Show me" segmented control (Wave 19.6)
// ----------------------------------------------------------------

/**
 * Repaint the segmented control — active state, disabled state for
 * unconsented options, ARIA. Always reflects `clientTreatmentOverride`
 * + `planHasGrayscaleConsent` + `planHasOriginalConsent`.
 */
function paintTreatmentOverride() {
  if (!$treatmentOverride) return;
  const segments = $treatmentOverride.querySelectorAll('.treatment-segment');
  segments.forEach((seg) => {
    const t = seg.getAttribute('data-treatment');
    let disabled = false;
    if (t === 'bw' && !planHasGrayscaleConsent) disabled = true;
    if (t === 'original' && !planHasOriginalConsent) disabled = true;
    seg.classList.toggle('is-disabled', disabled);
    seg.setAttribute('aria-disabled', disabled ? 'true' : 'false');
    if (disabled) {
      seg.setAttribute('title', "Your practitioner hasn't enabled this format");
    } else {
      seg.removeAttribute('title');
    }
    const isActive = !disabled && clientTreatmentOverride === t;
    seg.classList.toggle('is-active', isActive);
    seg.setAttribute('aria-checked', isActive ? 'true' : 'false');
    seg.setAttribute('tabindex', isActive ? '0' : '-1');
  });
}

/**
 * Apply a new override value: persist, rebind every video source, and
 * re-evaluate the Enhanced Background switch's enabled state (the new
 * override may flip the current effective treatment to/from line).
 */
function applyClientTreatmentOverride(next) {
  if (!next || VALID_OVERRIDES.indexOf(next) === -1) return;
  if (next === clientTreatmentOverride) return;
  clientTreatmentOverride = next;
  const planId = (plan && plan.id) || getPlanIdFromURL();
  writeClientTreatmentOverride(planId, clientTreatmentOverride);
  paintTreatmentOverride();
  rebindVideoSources();
  updateEnhancedBackgroundEnabled();
}

/**
 * The Enhanced Background switch dims the video background. There's
 * nothing to dim on a line-drawing slide, so the switch is disabled
 * (visible-but-greyed) whenever the *current effective* treatment is
 * 'line'. In `auto` mode the effective treatment is per-slide, so this
 * runs on every slide change. With a forced override the disabled-ness
 * is constant until the override flips.
 */
function updateEnhancedBackgroundEnabled() {
  if (!$enhancedBackgroundRow || !$toggleSegmentedEffect) return;
  const slide = slides[currentIndex];
  // Only video slides have a treatment to consider — for rest / photo
  // slides we leave the switch enabled (its preference still drives
  // future video slides).
  let effective = 'line';
  if (slide && slide.media_type === 'video') {
    effective = slideTreatment(slide);
  } else if (clientTreatmentOverride !== 'auto') {
    effective = clientTreatmentOverride;
  } else {
    // Fall back to scanning the active slide; if it's not a video we
    // assume the switch should remain enabled.
    effective = 'bw';
  }
  const disabled = effective === 'line';
  $enhancedBackgroundRow.classList.toggle('is-disabled', disabled);
  if (disabled) {
    $enhancedBackgroundRow.setAttribute('title', 'Background dimming applies to colour playback only');
  } else {
    $enhancedBackgroundRow.removeAttribute('title');
  }
  // Native `disabled` on the input prevents stray taps even if the
  // pointer-events:none CSS is bypassed (e.g. keyboard tab).
  $toggleSegmentedEffect.disabled = disabled;
}

/**
 * Wave 19.2: pause overlay is now a flash-on-toggle confirmation, not a
 * persistent dim affordance. The previous 0.35-opacity pause icon during
 * running was invisible against most video content.
 *
 * State model:
 *   Running  → overlay invisible; `flashPauseOverlay()` surfaces it briefly
 *              (full alpha → fade) on every play↔pause toggle to confirm
 *              the gesture landed.
 *   Paused   → overlay stays visible at full alpha (the play icon is the
 *              CTA to resume).
 *   Prep / offscreen slide → overlay hidden unconditionally.
 */
function updatePauseOverlay() {
  if (!$cardTrack) return;
  const overlays = $cardTrack.querySelectorAll('.media-pause-overlay');
  const workoutLive = isWorkoutMode && !isPrepPhase && remainingSeconds > 0;
  // Wave 19.3: glyph semantics = "what would tap do / what is playing now".
  // Everywhere the video is effectively playing (pre-workout preview, prep,
  // active timer) we show the PAUSE icon. Only the explicit paused-mid-
  // workout state shows the PLAY icon. Fixes the fullscreen dimmed-button
  // showing a play glyph while the video was clearly playing.
  const showPlayIcon = isWorkoutMode && !isPrepPhase && !isTimerRunning;
  overlays.forEach((overlay) => {
    const card = overlay.closest('.exercise-card');
    const idx = card ? Number(card.getAttribute('data-index')) : -1;
    const isActive = workoutLive && idx === currentIndex;
    // Persistent visibility ONLY when paused on the active slide. Running
    // state leans on flashPauseOverlay() for transient feedback.
    overlay.classList.toggle('is-visible', isActive && !isTimerRunning);
    const playIcon = overlay.querySelector('.pause-icon-play');
    const pauseIcon = overlay.querySelector('.pause-icon-pause');
    if (playIcon) playIcon.hidden = !showPlayIcon;
    if (pauseIcon) pauseIcon.hidden = showPlayIcon;
  });
}

/**
 * Briefly surface the pause overlay at full alpha to confirm a toggle.
 * CSS animation (.media-pause-overlay.is-flashing) holds at 1 alpha then
 * fades — we just toggle the class and clear any in-flight timer so
 * rapid taps don't leak stacked animations.
 */
function flashPauseOverlay() {
  if (!$cardTrack) return;
  const card = $cardTrack.querySelector(`.exercise-card[data-index="${currentIndex}"]`);
  if (!card) return;
  const overlay = card.querySelector('.media-pause-overlay');
  if (!overlay) return;
  const playIcon = overlay.querySelector('.pause-icon-play');
  const pauseIcon = overlay.querySelector('.pause-icon-pause');
  // Match the glyph semantics used by updatePauseOverlay (Wave 19.3):
  // PLAY glyph only during an explicit mid-workout pause; PAUSE glyph any
  // time the video is playing (pre-start preview, prep, or running).
  const showPlayIcon = isWorkoutMode && !isPrepPhase && !isTimerRunning;
  if (playIcon) playIcon.hidden = !showPlayIcon;
  if (pauseIcon) pauseIcon.hidden = showPlayIcon;
  // Restart the animation — remove, force reflow, re-add.
  overlay.classList.remove('is-flashing');
  void overlay.offsetWidth;
  overlay.classList.add('is-flashing');
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
 * Rest countdown overlay — big coral number overlaid on the last visible
 * frame during rest slides. Reuses the prep-overlay visual language but
 * at the viewport level (not inside the card) because the rest card has
 * its own sage-tinted composed display. Only visible when the current
 * slide is rest AND the workout timer is running (hidden during pause /
 * prep / exercise slides).
 */
function updateRestCountdownOverlay() {
  if (!$restCountdownOverlay || !$restCountdownNumber) return;
  const slide = slides[currentIndex];
  const isRestSlide = !!(slide && slide.media_type === 'rest');
  const visible = isWorkoutMode && isRestSlide && !isPrepPhase;
  $restCountdownOverlay.hidden = !visible;
  if (visible) {
    $restCountdownNumber.textContent = String(Math.max(0, remainingSeconds));
  }
}

/**
 * Milestone Q — render the per-exercise segmented progress bar. One
 * segment per set (coral) + one segment per breather (sage) interleaved.
 *
 * Segment visual states:
 *   * complete — solid full fill
 *   * active   — partial fill driven by `setPhaseRemaining` vs the
 *                phase's total duration; only ONE segment is active at
 *                any moment
 *   * upcoming — empty outline
 *
 * Always visible on a fresh exercise slide (i.e. before Start Workout)
 * so the client previews their structure up front. The earlier
 * `isWorkoutMode` gate that suppressed it pre-workout was a regression
 * — Carl signed off on showing the bar from first paint. Sets / breather
 * are read directly from the slide payload (NOT from the cached
 * `totalSetsForSlide` / `interSetRestForSlide` state) because those
 * cached values stay at their module defaults (1 / 0) until the workout
 * actually starts and `beginSetMachineForCurrent()` primes them.
 *
 * Hidden when:
 *   * rest slides (rest slide already gets #rest-countdown-overlay)
 *   * single-set exercises with no breather (nothing meaningful to show)
 */
function updateSetProgressBar() {
  if (!$setProgressBar) return;
  const slide = slides[currentIndex];

  // Read from the slide payload — cached state is unreliable pre-workout.
  const slideSets = slide ? Math.max(1, slide.sets || 1) : 1;
  const slideBreather = slide ? getInterSetRestSeconds(slide) : 0;

  const eligible = !!slide
    && slide.media_type !== 'rest'
    && (slideSets > 1 || slideBreather > 0);
  $setProgressBar.hidden = !eligible;
  if (!eligible) {
    $setProgressBar.innerHTML = '';
    return;
  }

  const perSet = calculatePerSetSeconds(slide);
  const reps = slide.reps || 0;
  const segments = [];
  for (let i = 0; i < slideSets; i++) {
    segments.push({ kind: 'set', index: i, total: perSet });
    if (i < slideSets - 1 && slideBreather > 0) {
      segments.push({ kind: 'rest', index: i, total: slideBreather });
    }
  }

  // Determine which segment is active. Pre-workout (isWorkoutMode=false)
  // we leave activeSegIdx=-1 so every segment renders as upcoming — a
  // calm preview of the structure rather than a fake "in progress" look.
  let activeSegIdx = -1;
  if (isWorkoutMode) {
    for (let s = 0; s < segments.length; s++) {
      const seg = segments[s];
      const matchSet = seg.kind === 'set' && setPhase === 'set' && seg.index === currentSetIndex;
      const matchRest = seg.kind === 'rest' && setPhase === 'rest' && seg.index === currentSetIndex;
      if (matchSet || matchRest) { activeSegIdx = s; break; }
    }
  }

  // Build / refresh the segment DOM. Rebuild in full — cheap (tens of
  // children max) and keeps state simple.
  const html = segments.map((seg, s) => {
    let stateClass;
    let fillPct = 0;
    if (s < activeSegIdx) {
      stateClass = 'set-progress-bar-segment--complete';
      fillPct = 100;
    } else if (s === activeSegIdx) {
      stateClass = 'set-progress-bar-segment--active';
      const remaining = Math.max(0, setPhaseRemaining);
      const total = Math.max(1, seg.total);
      fillPct = Math.max(0, Math.min(100, ((total - remaining) / total) * 100));
    } else {
      stateClass = 'set-progress-bar-segment--upcoming';
    }
    const kindClass = seg.kind === 'set'
      ? 'set-progress-bar-segment--set'
      : 'set-progress-bar-segment--rest';
    // Wave 19.7 — active set segment gets a live `{rep} of {reps}` label
    // driven by handleLoopBoundary's per-loop tick. Completed +
    // upcoming segments stay at the static `{reps} reps` totals.
    let label;
    if (seg.kind === 'rest') {
      label = `Rest ${seg.total}s`;
    } else if (s === activeSegIdx) {
      // Active set segment — live rep counter via handleLoopBoundary.
      // Treat the in-progress first rep as rep 1 (not rep 0) on first paint;
      // legacy slides with reps=null show the counter without a denominator.
      const live = Math.max(1, (loopState.get(currentIndex) || {}).repsInSet || 0);
      label = reps > 0
        ? `Set ${seg.index + 1} · ${live} of ${reps}`
        : `Set ${seg.index + 1} · Rep ${live}`;
    } else {
      label = reps > 0 ? `Set ${seg.index + 1} · ${reps} reps` : `Set ${seg.index + 1}`;
    }
    return `<div class="set-progress-bar-segment ${kindClass} ${stateClass}"
                 role="presentation">
              <div class="set-progress-bar-segment-fill"
                   style="width: ${fillPct.toFixed(1)}%"></div>
              <div class="set-progress-bar-segment-label">${escapeHTML(label)}</div>
            </div>`;
  }).join('');
  $setProgressBar.innerHTML = html;
}

/**
 * Milestone Q — sage countdown overlay shown during the inter-set
 * breather. Sits on top of the paused video (set phase pauses video at
 * last visible frame; breather overlay fades in over it). Big sage
 * number + a restful glyph + "Breather" label.
 *
 * Hidden when:
 *   * not in workout mode
 *   * prep phase (coral prep overlay owns the viewport then)
 *   * set phase (video is playing)
 *   * rest slide (rest slide has its own dedicated rest overlay)
 */
function updateBreatherOverlay() {
  if (!$breatherOverlay || !$breatherNumber) return;
  const slide = slides[currentIndex];
  const isRest = !!(slide && slide.media_type === 'rest');
  const visible = isWorkoutMode
    && !isPrepPhase
    && !isRest
    && setPhase === 'rest';
  $breatherOverlay.hidden = !visible;
  if (visible) {
    $breatherNumber.textContent = String(Math.max(0, setPhaseRemaining));
  }
}

/**
 * Prep play-gating — during the prep countdown, the active video is
 * paused and reset to the first frame so nothing plays behind the coral
 * digits. Called by startPrepPhase + finishPrepPhase.
 */
function gateVideoForPrep(shouldGate) {
  // Both crossfade slots get gated together so neither leaks frames
  // behind the prep countdown. Prep is the last moment we can safely
  // zero the inactive slot — handleLoopBoundary won't do it until the
  // first natural-end fires post-prep.
  const a = document.getElementById(`video-${currentIndex}`);
  const b = document.getElementById(`video-${currentIndex}-b`);
  [a, b].forEach((v) => {
    if (!v) return;
    if (shouldGate) {
      try {
        v.pause();
        v.currentTime = 0;
      } catch (_) {
        // Ignore — some browsers throw on currentTime set while metadata loads.
      }
    }
  });
  if (!shouldGate) {
    // Resume only the visible / active slot; the inactive one stays
    // paused at frame 0 ready for the crossfade.
    const active = getActiveVideoForSlide(currentIndex);
    if (active) {
      active.play().catch((err) => {
        console.warn('video resume after prep failed:', err);
      });
    }
  }
}

// ============================================================
// Top-stack v1 — fullscreen ambient mode + chrome reveal
// ============================================================

/**
 * Request browser fullscreen on the document root. Caller MUST be inside
 * a user gesture (button click / tap) — browsers reject the API call
 * otherwise. We flip body.is-fullscreen via the fullscreenchange event
 * listener rather than directly, so the class reflects reality even if
 * the user exits via the browser's own UI (Esc key, mobile swipe-down).
 */
function requestFullscreen() {
  const el = document.documentElement;
  const req = el.requestFullscreen || el.webkitRequestFullscreen;
  if (req) {
    try { req.call(el); } catch (_) { /* swallow */ }
    return;
  }
  // iPhone Safari fallback — no Fullscreen API. Flip the body class
  // ourselves, lock scroll, and re-run the change handler so aria state +
  // icon swap match the real-API path. The fullscreenchange event is
  // browser-only; faux mode never fires it, hence the explicit call.
  fauxFullscreenActive = true;
  fauxFullscreenPrevHtmlOverflow = document.documentElement.style.overflow || '';
  fauxFullscreenPrevBodyOverflow = document.body.style.overflow || '';
  document.documentElement.style.overflow = 'hidden';
  document.body.style.overflow = 'hidden';
  onFullscreenChange();
}

function exitFullscreen() {
  if (fauxFullscreenActive) {
    fauxFullscreenActive = false;
    document.documentElement.style.overflow = fauxFullscreenPrevHtmlOverflow;
    document.body.style.overflow = fauxFullscreenPrevBodyOverflow;
    fauxFullscreenPrevHtmlOverflow = '';
    fauxFullscreenPrevBodyOverflow = '';
    onFullscreenChange();
    return;
  }
  const ex = document.exitFullscreen || document.webkitExitFullscreen;
  if (ex) {
    try { ex.call(document); } catch (_) { /* swallow */ }
  }
}

function isFullscreenActive() {
  return !!(
    document.fullscreenElement ||
    document.webkitFullscreenElement ||
    fauxFullscreenActive
  );
}

function toggleFullscreen() {
  if (isFullscreenActive()) {
    exitFullscreen();
  } else {
    requestFullscreen();
  }
}

function onFullscreenChange() {
  const active = isFullscreenActive();
  document.body.classList.toggle('is-fullscreen', active);
  // Reset chrome-visible when leaving fullscreen — it's pointless outside
  // ambient mode and the overlay alphas are full anyway.
  if (!active) {
    document.body.classList.remove('chrome-visible');
    if (chromeRevealTimer) {
      clearTimeout(chromeRevealTimer);
      chromeRevealTimer = null;
    }
  }
  // Swap enter/exit icons.
  if ($btnFullscreen) {
    $btnFullscreen.setAttribute('aria-pressed', active ? 'true' : 'false');
    $btnFullscreen.setAttribute('aria-label', active ? 'Exit fullscreen' : 'Enter fullscreen');
    const enter = $btnFullscreen.querySelector('.fs-icon-enter');
    const exit = $btnFullscreen.querySelector('.fs-icon-exit');
    if (enter) enter.hidden = active;
    if (exit) exit.hidden = !active;
  }
}

/**
 * Reveal chrome (edge-nav, mute, fullscreen, notes) at 100% alpha for 3s
 * after any tap / touch on the card viewport while in fullscreen. Does
 * nothing outside fullscreen — regular mode already keeps the overlays
 * at full alpha.
 */
function onCardViewportInteraction() {
  if (!document.body.classList.contains('is-fullscreen')) return;
  document.body.classList.add('chrome-visible');
  if (chromeRevealTimer) clearTimeout(chromeRevealTimer);
  chromeRevealTimer = setTimeout(() => {
    document.body.classList.remove('chrome-visible');
    chromeRevealTimer = null;
  }, CHROME_REVEAL_MS);
}

/**
 * Show workout complete screen. The celebratory cue is CSS-driven:
 * .workout-complete-glow radial gradient fades in, .workout-complete-icon
 * scales in over 200ms. We retrigger by removing + re-adding the `is-live`
 * class so the animation restarts cleanly even after a second workout.
 */
function finishWorkout() {
  clearWorkoutTimer();
  clearPrepTimer();
  isTimerRunning = false;
  isPrepPhase = false;

  updatePauseOverlay();
  updatePrepOverlay();
  updateRestCountdownOverlay();

  // Calculate total workout time
  const elapsedMs = Date.now() - workoutStartTime;
  const elapsedSeconds = Math.round(elapsedMs / 1000);
  $workoutTotalTime.textContent = `Total time: ${formatTime(elapsedSeconds)}`;

  $workoutComplete.hidden = false;
  // Kick the celebratory cue. Remove + rAF + add so the CSS animation
  // starts fresh even on a repeat workout.
  if ($workoutComplete) {
    $workoutComplete.classList.remove('is-live');
    // eslint-disable-next-line no-unused-expressions
    void $workoutComplete.offsetWidth;
    $workoutComplete.classList.add('is-live');
  }

  // Flip the ETA to "Done" end-state.
  workoutCompleteFlag = true;
  updateTimelineBar();
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
  if ($workoutComplete) $workoutComplete.classList.remove('is-live');
  updatePauseOverlay();
  updatePrepOverlay();
  updateRestCountdownOverlay();

  // Drop the top-stack fullscreen — we're back to browse mode so the
  // top-stack chrome belongs on-screen.
  if (isFullscreenActive()) exitFullscreen();

  // Show the start workout button again
  $startWorkoutBtn.hidden = false;

  // Rebuild the matrix + reset the end-state flag so the readout shows
  // the pre-workout stale total again.
  workoutCompleteFlag = false;
  buildProgressMatrix();
  updateProgressMatrix();
  updateTimelineBar();
}

// ============================================================
// HomefitLogo (item 10) — canonical v2 system
// ------------------------------------------------------------
// A slice of the progress-pill matrix that IS the product:
//   3 ghost pills (outer → inner, tapering larger + lighter) →
//   2-cycle circuit in a coral-tint band (2 exercises × 2 cycles) →
//   1 sage rest pill →
//   3 ghost pills (mirror on the right)
//
// Two variants share the same 11-element matrix geometry:
//   - buildHomefitLogoSvg()        matrix only, 48×9.5 viewBox.
//                                  Default — used in the footer next to
//                                  the wordmark span, favicons, tight
//                                  chrome.
//   - buildHomefitLogoLockupSvg()  matrix + wordmark stacked, 48×14.
//                                  For hero surfaces / marketing /
//                                  single-mark slots.
//
// Geometry canon is duplicated verbatim in
// `web-portal/src/components/HomefitLogo.tsx` and
// `app/lib/widgets/homefit_logo.dart`. Signed off at
// `docs/design/mockups/logo-ghost-outer.html`.
// ============================================================

// Shared 11-pill matrix SVG body. Returns rects only; caller wraps in
// <svg>. `yOffset` is applied to every Y so the same body can be reused
// by the lockup (which shifts the matrix down to make room for the
// wordmark row).
function _homefitMatrixBody(yOffset) {
  const dy = yOffset || 0;
  const y = (n) => (n + dy).toFixed(3).replace(/\.?0+$/, '');

  const coral = '#FF6B35';
  const coralTint = 'rgba(255, 107, 53, 0.15)';
  const sage = '#86EFAC';
  const ghostOuter = '#4B5563';
  const ghostMid = '#6B7280';
  const ghostInner = '#9CA3AF';

  return (
    // Left ghost pills: outer→inner, progressively larger + lighter.
    `<rect x="0" y="${y(2.75)}" width="2.5" height="1.5" rx="0.5" fill="${ghostOuter}"/>` +
    `<rect x="4" y="${y(2.45)}" width="3.5" height="2.1" rx="0.7" fill="${ghostMid}"/>` +
    `<rect x="9" y="${y(2.15)}" width="4.5" height="2.7" rx="0.9" fill="${ghostInner}"/>` +
    // Coral tint band behind the 2×2 circuit.
    `<rect x="14.5" y="${y(1)}" width="12.5" height="8.5" rx="1.2" fill="${coral}" opacity="0.15"/>` +
    // Ex2 / Ex3 — 2×2 grid (2 exercises × 2 cycles), solid coral.
    `<rect x="15" y="${y(2)}" width="5" height="3" rx="1" fill="${coral}"/>` +
    `<rect x="15" y="${y(6.5)}" width="5" height="3" rx="1" fill="${coral}"/>` +
    `<rect x="21.5" y="${y(2)}" width="5" height="3" rx="1" fill="${coral}"/>` +
    `<rect x="21.5" y="${y(6.5)}" width="5" height="3" rx="1" fill="${coral}"/>` +
    // Rest — sage.
    `<rect x="28" y="${y(2)}" width="5" height="3" rx="1" fill="${sage}"/>` +
    // Right ghost pills: inner→outer, mirror of left.
    `<rect x="34.5" y="${y(2.15)}" width="4.5" height="2.7" rx="0.9" fill="${ghostInner}"/>` +
    `<rect x="40.5" y="${y(2.45)}" width="3.5" height="2.1" rx="0.7" fill="${ghostMid}"/>` +
    `<rect x="45.5" y="${y(2.75)}" width="2.5" height="1.5" rx="0.5" fill="${ghostOuter}"/>`
  );
}

function buildHomefitLogoSvg() {
  return (
    `<svg class="homefit-logo" viewBox="0 0 48 9.5"` +
    ` xmlns="http://www.w3.org/2000/svg" aria-hidden="true">` +
    _homefitMatrixBody(0) +
    `</svg>`
  );
}

function buildHomefitLogoLockupSvg() {
  // Lockup variant — wordmark row + matrix translated +4.5 on Y.
  // Wordmark uses Montserrat 600, stretched via textLength so it
  // aligns to the 48-unit matrix width at any render size.
  return (
    `<svg class="homefit-logo homefit-logo--lockup" viewBox="0 -2 48 16"` +
    ` xmlns="http://www.w3.org/2000/svg" aria-hidden="true">` +
    `<text x="24" y="4.6" text-anchor="middle" textLength="48"` +
    ` lengthAdjust="spacingAndGlyphs"` +
    ` font-family="Montserrat, sans-serif" font-weight="600"` +
    ` font-size="6.5" fill="#F0F0F5" letter-spacing="-0.1">homefit.studio</text>` +
    _homefitMatrixBody(4.5) +
    `</svg>`
  );
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
// Service Worker Registration
// ============================================================

async function registerServiceWorker() {
  // Wave 4 Phase 1 — skip SW registration when embedded in the Flutter
  // WebView via LocalPlayerServer. The SW caches `/sw.js`-relative assets
  // against the current origin, and the embedded server has no sw.js
  // handler anyway; worse, a stale SW from a previous origin could cling
  // to this one via the localhost scheme. Production web player on
  // session.homefit.studio still registers normally.
  try {
    if (window.HomefitApi && window.HomefitApi.isLocalSurface && window.HomefitApi.isLocalSurface()) {
      return;
    }
  } catch (_) {
    // Defensive — if HomefitApi failed to load, continue with the
    // original behaviour. The bundle load order guarantees api.js runs
    // first, so this should never hit.
  }
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

  // Discreet build marker in the footer — see PLAYER_VERSION at the
  // top of this file. Stamped pre-fetch so it's visible even on plan
  // load failure.
  const $versionEl = document.getElementById('footer-version');
  if ($versionEl) $versionEl.textContent = PLAYER_VERSION;

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

    // Wave 19.6 — load the persisted "Show me" override for THIS plan and
    // compute the plan-wide consent rollup BEFORE the first render so
    // slideTreatment() has correct state when buildCard() resolves URLs.
    recomputePlanConsent();
    clientTreatmentOverride = readClientTreatmentOverride(plan && plan.id);
    // Defensive: a stale localStorage value pointing at a now-unconsented
    // treatment falls back to 'auto' (and persists the correction).
    if (clientTreatmentOverride === 'bw' && !planHasGrayscaleConsent) {
      clientTreatmentOverride = 'auto';
      writeClientTreatmentOverride(plan && plan.id, 'auto');
    } else if (clientTreatmentOverride === 'original' && !planHasOriginalConsent) {
      clientTreatmentOverride = 'auto';
      writeClientTreatmentOverride(plan && plan.id, 'auto');
    }

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
    // (Pre-2026-04-20 this also bound a treatment-segmented-control click
    // handler; the client-facing treatment picker was removed because the
    // practitioner's per-exercise preferred_treatment is the authority.)
    $cardViewport.addEventListener('click', handleMediaTap);
    // Tap on the video surface while fullscreen — briefly reveal chrome
    // (edge-nav, mute, fullscreen-toggle, notes) for 3s.
    $cardViewport.addEventListener('touchstart', onCardViewportInteraction, { passive: true });
    $cardViewport.addEventListener('click', onCardViewportInteraction);
    document.addEventListener('keydown', onKeyDown);

    // Workout timer events
    $startWorkoutBtn.addEventListener('click', startWorkout);
    $workoutCloseBtn.addEventListener('click', exitWorkout);

    // Fullscreen toggle — body.is-fullscreen drives ambient mode CSS.
    if ($btnFullscreen) {
      $btnFullscreen.addEventListener('click', toggleFullscreen);
    }
    document.addEventListener('fullscreenchange', onFullscreenChange);
    document.addEventListener('webkitfullscreenchange', onFullscreenChange);

    // Settings popover — opens on click, closes on outside click / Esc.
    // The checkbox drives the segmented-effect opt-out (Milestone P).
    if ($btnSettings && $settingsPopover) {
      // Prime the visible state from the persisted preference before
      // the first interaction, so reopens reflect what's actually live.
      if ($toggleSegmentedEffect) {
        $toggleSegmentedEffect.checked = segmentedEffectEnabled;
      }
      updateSegmentedEffectHint();

      $btnSettings.addEventListener('click', (e) => {
        e.stopPropagation();
        setSettingsPopoverOpen(!isSettingsPopoverOpen());
      });
      // Clicks inside the popover must NOT bubble to the document-level
      // outside-click handler below — stop at the popover boundary.
      $settingsPopover.addEventListener('click', (e) => {
        e.stopPropagation();
      });
      if ($toggleSegmentedEffect) {
        // The toggle dispatches its visual flip via CSS `:checked`, which
        // makes the switch FEEL responsive even when the JS handler never
        // runs. The Wave 19.4 device QA caught a path where iOS Safari
        // routed the tap through the surrounding label without ever
        // firing `change` on the input, so the bind below leaned only on
        // `change` and the rebind never happened — visually the switch
        // moved, but the dimmed-background source stayed glued. Wiring
        // both `change` AND `click` (deferred to the next tick so
        // `.checked` has already settled to its post-toggle value)
        // closes that gap. Idempotency is handled by
        // applySegmentedEffectChange's early-exit when the state didn't
        // actually flip, so the duplicate fire is harmless.
        const handleSegmentedToggle = () => {
          // Disabled state guard: when the active treatment is line there's
          // nothing to dim, so no-op even if the gesture leaks through.
          if ($toggleSegmentedEffect.disabled) return;
          applySegmentedEffectChange(!!$toggleSegmentedEffect.checked);
        };
        $toggleSegmentedEffect.addEventListener('change', handleSegmentedToggle);
        $toggleSegmentedEffect.addEventListener('click', () => {
          // Defer one tick — Safari fires `click` before the implicit
          // checkbox toggle has updated `.checked` on some code paths.
          setTimeout(handleSegmentedToggle, 0);
        });
      }

      // Wave 19.6 — "Show me" segmented override. Click on a segment
      // applies it (or no-ops if disabled). Paint once now so the
      // initial popover open reflects the persisted state + consent.
      if ($treatmentOverride) {
        paintTreatmentOverride();
        updateEnhancedBackgroundEnabled();
        $treatmentOverride.addEventListener('click', (e) => {
          const seg = e.target && e.target.closest ? e.target.closest('.treatment-segment') : null;
          if (!seg) return;
          if (seg.classList.contains('is-disabled')) {
            // Stays in the popover; tooltip carries the explanation.
            return;
          }
          const next = seg.getAttribute('data-treatment');
          applyClientTreatmentOverride(next);
        });
      }
      // Outside-click closes the popover. Capture=true so we see the
      // event before other handlers (card-viewport taps, etc.) can
      // swallow it.
      document.addEventListener('click', (e) => {
        if (!isSettingsPopoverOpen()) return;
        const t = e.target;
        if (t && (t.closest && (t.closest('#settings-popover') || t.closest('#btn-settings')))) return;
        setSettingsPopoverOpen(false);
      }, true);
    }

    // Card notes overlay — tap toggles 3-line clamp vs full.
    if ($cardNotes) {
      $cardNotes.addEventListener('click', (e) => {
        e.stopPropagation();
        const expanded = $cardNotes.classList.toggle('is-expanded');
        $cardNotes.setAttribute('aria-expanded', expanded ? 'true' : 'false');
      });
    }

    // (Item 7) The dedicated timer-chip click binding is retired — tapping
    // the media area via handleMediaTap() is the only pause/resume control.

    // Progress-pill matrix — touch handlers drive both long-press jump
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
        const blocks = buildMatrixBlocks();
        const nextTier = chooseMatrixSizeTier(countMatrixColumns(blocks), window.innerWidth);
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
