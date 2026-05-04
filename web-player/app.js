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
const PLAYER_VERSION = 'v82-wave42-overrides';

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

  // Tag <body> so embed-only chrome tweaks can be expressed declaratively
  // in CSS (e.g. `body.is-embedded .active-slide-title { display: none }`).
  // Runs early enough that the class is in place before the first paint.
  if (window.isHomefitEmbedded()) {
    try {
      if (document.body) {
        document.body.classList.add('is-embedded');
      } else {
        document.addEventListener('DOMContentLoaded', function () {
          if (document.body) document.body.classList.add('is-embedded');
        });
      }
    } catch (_) {
      // Best-effort — failure to tag the body just means the floating
      // title stays visible inside the embed. No functional impact.
    }
  }

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

// ============================================================
// Wave 17 — Analytics consent + event tracking state
// ============================================================
//
// Session lifecycle: on plan load, startAnalyticsSession is called.
// If it returns a session ID, the banner is shown (unless localStorage
// records a prior decision). Consent drives whether events fire.
//
// `analyticsSessionId` — the session UUID from the server, or null if
// analytics is practitioner-disabled for this client.
// `analyticsConsented` — true once the client taps "Yes, share";
// false if "No thanks"; null before the decision.
// `analyticsTrainerName` — practitioner display name for banner copy.
// `analyticsSlideViewedAt` — timestamp map per slide index, for
// computing watched duration on skip/complete.

let analyticsSessionId = null;
let analyticsConsented = null;
let analyticsTrainerName = 'your practitioner';
let analyticsSlideViewedAt = {};
let analyticsCompletedSlides = {};
let analyticsPlanOpenTime = null;
let pauseStartedAt = null;

/**
 * Detect a coarse user-agent bucket for the analytics session.
 * No fingerprinting — just the browser family + form factor.
 */
function detectUserAgentBucket() {
  try {
    const ua = navigator.userAgent || '';
    const isMobile = /Mobi|Android/i.test(ua);
    if (/CriOS/i.test(ua) || (/Chrome/i.test(ua) && !/Edg/i.test(ua))) {
      return isMobile ? 'chrome_mobile' : 'chrome_desktop';
    }
    if (/Safari/i.test(ua) && !/Chrome/i.test(ua)) {
      return isMobile ? 'mobile_safari' : 'safari_desktop';
    }
    if (/Firefox/i.test(ua)) {
      return isMobile ? 'firefox_mobile' : 'firefox_desktop';
    }
    return 'other';
  } catch (_) {
    return 'other';
  }
}

/** localStorage key for persisted consent decision. */
function analyticsConsentKey(planId) {
  return 'homefit-analytics-consent-' + (planId || '');
}

/** localStorage key for the analytics session ID. */
function analyticsSessionKey(planId) {
  return 'homefit-session-id-' + (planId || '');
}

/**
 * Emit an analytics event if consent has been granted.
 * `plan_opened` is the exception — it fires regardless (per design doc).
 */
function emitAnalyticsEvent(kind, exerciseId, data) {
  if (!analyticsSessionId) return;
  // plan_opened fires even without consent (for banner funnel metrics).
  if (kind !== 'plan_opened' && analyticsConsented !== true) return;
  window.HomefitApi.logAnalyticsEvent(analyticsSessionId, kind, exerciseId, data);
}

/**
 * Show the consent banner (slides in from top).
 */
function showConsentBanner() {
  const existing = document.getElementById('analytics-consent-banner');
  if (existing) return; // already showing

  const planId = (plan && plan.id) || getPlanIdFromURL();
  const banner = document.createElement('div');
  banner.id = 'analytics-consent-banner';
  banner.className = 'analytics-consent-banner';
  banner.innerHTML =
    '<div class="analytics-consent-inner">' +
      '<p class="analytics-consent-title">Help ' + escapeHTML(analyticsTrainerName) + ' help you.</p>' +
      '<p class="analytics-consent-body">We\'ll share which exercises you complete, and when. Nothing else.<br>You can stop this anytime.</p>' +
      '<div class="analytics-consent-actions">' +
        '<button class="analytics-consent-btn analytics-consent-decline" type="button">No thanks</button>' +
        '<button class="analytics-consent-btn analytics-consent-accept" type="button">Yes, share</button>' +
      '</div>' +
      '<a class="analytics-consent-link" href="/what-we-share' + (planId ? '?p=' + encodeURIComponent(planId) : '') + '" target="_blank" rel="noopener">What\'s shared? \u2192</a>' +
    '</div>';

  document.body.appendChild(banner);
  // Force reflow then add the visible class for the slide-in animation.
  void banner.offsetWidth;
  banner.classList.add('is-visible');

  banner.querySelector('.analytics-consent-accept').addEventListener('click', function () {
    onConsentDecision(true);
  });
  banner.querySelector('.analytics-consent-decline').addEventListener('click', function () {
    onConsentDecision(false);
  });
}

function onConsentDecision(granted) {
  analyticsConsented = granted;
  const planId = (plan && plan.id) || getPlanIdFromURL();

  // Persist to localStorage so repeat opens don't re-prompt.
  try {
    localStorage.setItem(analyticsConsentKey(planId), granted ? 'yes' : 'no');
  } catch (_) { /* quota errors etc */ }

  // Write to server.
  window.HomefitApi.setAnalyticsConsent(analyticsSessionId, granted);

  // Dismiss the banner.
  const banner = document.getElementById('analytics-consent-banner');
  if (banner) {
    banner.classList.remove('is-visible');
    setTimeout(function () { banner.remove(); }, 400);
  }
}

/**
 * Initialise analytics for the loaded plan. Called once in init() after
 * the plan renders. Async — fires network calls but never blocks the
 * player render path.
 */
async function initAnalytics() {
  if (window.HomefitApi.isLocalSurface()) return;

  const planId = (plan && plan.id) || getPlanIdFromURL();
  if (!planId) return;

  analyticsPlanOpenTime = Date.now();

  // Start a server session.
  const sessionId = await window.HomefitApi.startAnalyticsSession(planId, detectUserAgentBucket());

  if (!sessionId) {
    // Practitioner disabled analytics for this client. No banner, no events.
    return;
  }

  analyticsSessionId = sessionId;

  // Persist session ID so the transparency page can read it.
  try {
    localStorage.setItem(analyticsSessionKey(planId), sessionId);
  } catch (_) {}

  // Fetch practitioner name for the banner copy.
  var ctx = await window.HomefitApi.getPlanSharingContext(planId);
  if (ctx && ctx.practitioner_name) {
    analyticsTrainerName = ctx.practitioner_name;
    // Lobby was rendered with "your practitioner" as fallback before this
    // async resolved. Patch its sub-line in place if the lobby is still
    // visible. Cheap: textContent swap, no full re-render.
    try {
      var $lobbyMeta = document.getElementById('lobby-meta-sub');
      var $lobbyMetaHeadline = document.getElementById('lobby-meta-headline');
      if ($lobbyMeta && $lobbyMeta.textContent && $lobbyMeta.textContent.indexOf('your practitioner') !== -1) {
        $lobbyMeta.textContent = $lobbyMeta.textContent.replace(
          /From your practitioner/g,
          'From ' + analyticsTrainerName,
        );
      }
    } catch (_) {}
  }

  // Fire plan_opened regardless of consent (per design doc).
  emitAnalyticsEvent('plan_opened', null, {
    referrer: (typeof document !== 'undefined' && document.referrer) || null,
  });

  // Check localStorage for a prior consent decision.
  var stored = null;
  try {
    stored = localStorage.getItem(analyticsConsentKey(planId));
  } catch (_) {}

  if (stored === 'yes') {
    analyticsConsented = true;
    // Re-confirm with the server in case localStorage drifted.
    window.HomefitApi.setAnalyticsConsent(analyticsSessionId, true);
  } else if (stored === 'no') {
    analyticsConsented = false;
  } else {
    // No prior decision — show the consent banner.
    showConsentBanner();
  }
}

/**
 * Wire the beforeunload / pagehide event for `plan_closed`.
 */
function installAnalyticsCloseHandler() {
  var closeFired = false;
  function onClose() {
    if (closeFired) return;
    closeFired = true;
    if (!analyticsSessionId || analyticsConsented !== true) return;
    var elapsed = analyticsPlanOpenTime ? Date.now() - analyticsPlanOpenTime : 0;
    var eventData = {
      elapsed_ms: elapsed,
      slide_index_at_close: currentIndex,
    };
    // Route through the API seam with keepalive for page-close reliability.
    // keepalive allows the request to outlive the page.
    try {
      window.HomefitApi.logAnalyticsEvent(
        analyticsSessionId,
        'plan_closed',
        null,
        eventData,
        { keepalive: true },
      );
    } catch (_) {
      emitAnalyticsEvent('plan_closed', null, eventData);
    }
  }
  // pagehide is more reliable than beforeunload on mobile Safari.
  window.addEventListener('pagehide', onClose);
  window.addEventListener('beforeunload', onClose);
}

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
  // Wave 42 — per-exercise client overrides. getEffective() returns the
  // practitioner's per-exercise preferred_treatment by default; the gear
  // panel can override per-exercise. Defensive fallback to 'line' when
  // the chosen treatment's URL is absent (consent removed mid-session,
  // legacy plan, etc.).
  const candidate = getEffective(exercise, 'treatment');
  if (candidate === 'bw' && !hasGray) return 'line';
  if (candidate === 'original' && !hasOrig) return 'line';
  return candidate || 'line';
}

// Workout timer state
let isWorkoutMode = false;
let isTimerRunning = false;
let remainingSeconds = 0;
let totalSeconds = 0;
let workoutTimer = null;
let workoutStartTime = null;

// ------------------------------------------------------------------
// v79-hardening (HIGH 1) — signed URL expiry guard.
//
// B&W/Original treatment video URLs are pgjwt-signed with a 1-hour TTL.
// A long workout + pauses can exceed this, causing a 403 → black frame.
// We listen for `error` events on <video> elements, re-fetch the plan,
// swap URLs, and retry. Max one retry per video to avoid infinite loops.
// ------------------------------------------------------------------
const _videoRetrySet = new Set(); // video element IDs that already retried
let _urlRefreshInFlight = false;

async function handleVideoError(evt) {
  const video = evt.target;
  if (!video || video.tagName !== 'VIDEO') return;
  const videoId = video.id;
  if (!videoId || _videoRetrySet.has(videoId)) return; // already retried once
  _videoRetrySet.add(videoId);

  const planId = (plan && plan.id) || getPlanIdFromURL();
  if (!planId) return;

  // Show subtle refreshing indicator
  const card = video.closest('.exercise-card');
  let refreshLabel = null;
  if (card) {
    refreshLabel = document.createElement('div');
    refreshLabel.className = 'video-refresh-indicator';
    refreshLabel.textContent = 'Refreshing\u2026';
    card.appendChild(refreshLabel);
  }

  try {
    // Coalesce multiple errors into a single re-fetch
    if (!_urlRefreshInFlight) {
      _urlRefreshInFlight = true;
      const fresh = await fetchPlan(planId);
      if (fresh && fresh.exercises) {
        // Update the exercises array in our slides with fresh URLs
        const freshExMap = {};
        fresh.exercises.forEach(function (ex) { freshExMap[ex.id] = ex; });
        slides.forEach(function (s, idx) {
          const f = freshExMap[s.id];
          if (!f) return;
          s.line_drawing_url = f.line_drawing_url;
          s.grayscale_url = f.grayscale_url;
          s.original_url = f.original_url;
          s.grayscale_segmented_url = f.grayscale_segmented_url;
          s.original_segmented_url = f.original_segmented_url;
          s.mask_url = f.mask_url;
        });
      }
      _urlRefreshInFlight = false;
    }

    // Re-resolve the URL for this video's slide
    const cardEl = video.closest('.exercise-card');
    const idx = cardEl ? Number(cardEl.getAttribute('data-index')) : NaN;
    const slide = Number.isFinite(idx) ? slides[idx] : null;
    if (slide) {
      const newUrl = resolveTreatmentUrl(slide, slideTreatment(slide));
      if (newUrl) {
        video.setAttribute('data-src', newUrl);
        video.setAttribute('src', newUrl);
        video.load();
      }
    }
  } catch (err) {
    console.warn('[homefit] URL refresh failed:', err);
  } finally {
    if (refreshLabel) {
      setTimeout(function () { refreshLabel.remove(); }, 2000);
    }
  }
}

// ------------------------------------------------------------------
// v79-hardening (HIGH 2) — background tab / screen lock timer drift.
//
// When the client locks their phone or switches tabs, setInterval is
// throttled. On return we fast-forward remainingSeconds by wall-clock
// elapsed, re-sync the set machine, and resume video.
// ------------------------------------------------------------------
let _backgroundedAt = null;

function onVisibilityChange() {
  if (document.hidden) {
    _backgroundedAt = Date.now();
  } else {
    if (!_backgroundedAt || !isWorkoutMode || !isTimerRunning) {
      _backgroundedAt = null;
      return;
    }
    const elapsedMs = Date.now() - _backgroundedAt;
    _backgroundedAt = null;
    const elapsedSec = Math.floor(elapsedMs / 1000);
    if (elapsedSec <= 0) return;

    // Fast-forward remaining seconds
    remainingSeconds = Math.max(0, remainingSeconds - elapsedSec);

    // Fast-forward the set-phase machine — Wave 41 per-set aware.
    // Each set carries its own breather_seconds_after; we read it
    // from the active set on every phase transition.
    if (!isRestSlide()) {
      const slide = slides[currentIndex];
      const playSets = playSetsForSlide(slide);
      let ticksLeft = elapsedSec;
      while (ticksLeft > 0 && remainingSeconds >= 0) {
        if (setPhaseRemaining > ticksLeft) {
          setPhaseRemaining -= ticksLeft;
          ticksLeft = 0;
        } else {
          ticksLeft -= setPhaseRemaining;
          setPhaseRemaining = 0;
          // Trigger phase advance
          const breatherForActiveSet = getBreatherForSet(slide, currentSetIndex);
          if (setPhase === 'set' && breatherForActiveSet > 0) {
            setPhase = 'rest';
            setPhaseRemaining = breatherForActiveSet;
            interSetRestForSlide = breatherForActiveSet;
          } else if (setPhase === 'rest') {
            const isLastSet = currentSetIndex >= totalSetsForSlide - 1;
            if (!isLastSet) {
              currentSetIndex++;
              setPhase = 'set';
              const nextSet = playSets[currentSetIndex];
              const nextIsLast = currentSetIndex >= playSets.length - 1;
              // Wave 41 fix — physical-only; breather lives in 'rest' phase.
              setPhaseRemaining = calculatePhysicalSetSeconds(nextSet, slide, nextIsLast);
            } else {
              // Exhausted all sets — clamp
              setPhaseRemaining = 0;
              break;
            }
          } else {
            // No breather — advance set
            const isLastSet = currentSetIndex >= totalSetsForSlide - 1;
            if (!isLastSet) {
              currentSetIndex++;
              const nextSet = playSets[currentSetIndex];
              const nextIsLast = currentSetIndex >= playSets.length - 1;
              // Wave 41 fix — physical-only; breather lives in 'rest' phase.
              setPhaseRemaining = calculatePhysicalSetSeconds(nextSet, slide, nextIsLast);
            } else {
              break;
            }
          }
        }
      }
    }

    if (remainingSeconds <= 0) {
      // Timer expired while backgrounded
      remainingSeconds = 0;
      clearWorkoutTimer();
      isTimerRunning = false;
      onTimerComplete();
      return;
    }

    // Resume video playback if in a set phase
    if (setPhase !== 'rest') {
      const cv = getActiveVideoForSlide(currentIndex);
      if (cv && cv.paused) {
        cv.play().catch(function () {});
      }
    }

    // Repaint everything
    updateUI();
    updateRepStack();
    updateBreatherOverlay();
    updateRestCountdownOverlay();
    updateProgressMatrix();
    updateTimelineBar();
  }
}
document.addEventListener('visibilitychange', onVisibilityChange);

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
// Total sets for the active slide (cached; same as
// playSetsForSlide(slides[currentIndex]).length post Wave 41).
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
//   }
// Skipped entirely for: photos, rest slides, videos longer than
// LOOP_CROSSFADE_MAX_DURATION (no perceptual seam at low loop frequency).
// ------------------------------------------------------------------
// Per-plan crossfade tuning (Wave 27). Defaults match historical
// behaviour; overrides ride on `plan.crossfade_lead_ms` /
// `plan.crossfade_fade_ms` from get_plan_full and clamp to the
// safe ranges below. NULL → use the default.
const DEFAULT_LOOP_CROSSFADE_LEAD_MS = 250;
const DEFAULT_LOOP_CROSSFADE_FADE_MS = 200;
const LOOP_CROSSFADE_LEAD_RANGE = [100, 800];
const LOOP_CROSSFADE_FADE_RANGE = [50, 600];
const LOOP_CROSSFADE_MIN_DURATION = 1.2; // < this → fall back to native loop (too short for crossfade)
const LOOP_CROSSFADE_MAX_DURATION = 12;  // > this → seam is rare, skip the dual-video machinery

function getLoopCrossfadeLeadMs() {
  const v = plan && plan.crossfade_lead_ms;
  if (v == null) return DEFAULT_LOOP_CROSSFADE_LEAD_MS;
  const n = Number(v);
  if (!Number.isFinite(n)) return DEFAULT_LOOP_CROSSFADE_LEAD_MS;
  return Math.max(LOOP_CROSSFADE_LEAD_RANGE[0], Math.min(LOOP_CROSSFADE_LEAD_RANGE[1], n));
}

function getLoopCrossfadeFadeMs() {
  const v = plan && plan.crossfade_fade_ms;
  if (v == null) return DEFAULT_LOOP_CROSSFADE_FADE_MS;
  const n = Number(v);
  if (!Number.isFinite(n)) return DEFAULT_LOOP_CROSSFADE_FADE_MS;
  return Math.max(LOOP_CROSSFADE_FADE_RANGE[0], Math.min(LOOP_CROSSFADE_FADE_RANGE[1], n));
}
const REP_TICK_PULSE_MS = 200;
const loopState = new Map();
let drainTimer = null;

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

// Wave 42 — per-exercise client overrides keyed by plan + exercise + property.
// Resolves effective state as `clientOverrides[exId]?.[prop] ?? practitionerDefault[exId][prop]`.
// One JSON blob per plan in localStorage; reset by the gear-panel "Reset to
// practitioner defaults" button. Replaces the prior global flags
// (homefit-muted, homefit.playback.segmentedEffect, homefit.playback.treatment::*).
const OVERRIDES_KEY_PREFIX = 'homefit.overrides::';
const OVERRIDE_PROPS = ['muted', 'treatment', 'bodyFocus'];
const TREATMENT_VALUES = ['line', 'bw', 'original'];
let clientOverrides = {}; // { [exerciseId]: { muted?, treatment?, bodyFocus? } }

function overridesStorageKey(planId) {
  return OVERRIDES_KEY_PREFIX + (planId || 'unknown');
}

function loadClientOverrides(planId) {
  try {
    const raw = window.localStorage.getItem(overridesStorageKey(planId));
    if (!raw) { clientOverrides = {}; return; }
    const parsed = JSON.parse(raw);
    clientOverrides = parsed && typeof parsed === 'object' ? parsed : {};
  } catch (_) {
    clientOverrides = {};
  }
}

function saveClientOverrides(planId) {
  try {
    window.localStorage.setItem(overridesStorageKey(planId), JSON.stringify(clientOverrides));
  } catch (_) {
    // Storage blocked — in-memory map still drives this session.
  }
}

function clearAllOverrides(planId) {
  clientOverrides = {};
  try { window.localStorage.removeItem(overridesStorageKey(planId)); } catch (_) {}
}

function hasAnyOverrides() {
  for (const k in clientOverrides) {
    if (Object.prototype.hasOwnProperty.call(clientOverrides, k)) {
      const entry = clientOverrides[k];
      if (entry && typeof entry === 'object') {
        for (const p in entry) {
          if (Object.prototype.hasOwnProperty.call(entry, p)) return true;
        }
      }
    }
  }
  return false;
}

/**
 * Practitioner default for [prop] on [exercise]. Source-of-truth for the
 * resolver fallback — also used by the gear panel to decide whether a
 * setOverride() write should clear the entry (= matches default) or
 * persist it (= diverges from default).
 *
 *   muted     → !exercise.include_audio (silent clip → muted by default)
 *   treatment → exercise.preferred_treatment ('line'|'grayscale'|'original'
 *               → 'line'|'bw'|'original'); null/missing → 'line'
 *   bodyFocus → exercise.body_focus !== false (NULL/true → true)
 */
function practitionerDefaultFor(exercise, prop) {
  if (!exercise) {
    if (prop === 'muted') return true;
    if (prop === 'treatment') return 'line';
    if (prop === 'bodyFocus') return true;
    return null;
  }
  if (prop === 'muted') return !exercise.include_audio;
  if (prop === 'treatment') return treatmentFromWire(exercise.preferred_treatment);
  if (prop === 'bodyFocus') return exercise.body_focus !== false;
  return null;
}

/** Effective state = client override if set, else practitioner default. */
function getEffective(exercise, prop) {
  if (!exercise) return practitionerDefaultFor(exercise, prop);
  const entry = clientOverrides[exercise.id];
  if (entry && Object.prototype.hasOwnProperty.call(entry, prop)) {
    return entry[prop];
  }
  return practitionerDefaultFor(exercise, prop);
}

function setOverride(exId, prop, value, defaultValue) {
  if (!exId) return;
  if (value === defaultValue) {
    if (clientOverrides[exId]) {
      delete clientOverrides[exId][prop];
      // Drop the empty container so hasAnyOverrides() stays accurate.
      let empty = true;
      for (const k in clientOverrides[exId]) {
        if (Object.prototype.hasOwnProperty.call(clientOverrides[exId], k)) {
          empty = false;
          break;
        }
      }
      if (empty) delete clientOverrides[exId];
    }
  } else {
    if (!clientOverrides[exId]) clientOverrides[exId] = {};
    clientOverrides[exId][prop] = value;
  }
  const planId = (plan && plan.id) || getPlanIdFromURL();
  saveClientOverrides(planId);
}

/**
 * Lobby helper — apply a treatment value as a per-exercise override across
 * the entire plan. Mirrors what setOverride does for one exercise but
 * walks every loaded slide so a single lobby tap propagates everywhere.
 *
 * Wave 5 lobby fixes (Carl device QA): always WRITE the global pick as
 * an explicit override on every exercise, regardless of the
 * practitioner's per-exercise default. The earlier "clear when matches
 * default" branch was wrong — if the practitioner default for an
 * exercise was B&W and the user picked Line globally, clearing meant
 * the row fell back to B&W (the default) instead of staying on Line.
 * Per-exercise gear popover (post-handoff in the deck) can still
 * individually override.
 *
 * Skips locked treatments per-exercise (consent absent → fall back to
 * 'line' for that one). Saves once at the end. Re-binds video sources
 * so deck videos pick up the new src on the next render. Used by
 * lobby.js's `applyTreatmentOverrideToAllExercises` handoff.
 */
function applyTreatmentOverrideToAllExercises(treatment) {
  if (treatment !== 'line' && treatment !== 'bw' && treatment !== 'original') return;
  if (!plan || !slides) return;
  for (let i = 0; i < slides.length; i++) {
    const ex = slides[i];
    if (!ex || ex.media_type === 'rest' || !ex.id) continue;
    let target = treatment;
    // Don't write an override that points at an unconsented treatment.
    if (target === 'bw' && !planHasGrayscaleConsent) target = 'line';
    if (target === 'original' && !planHasOriginalConsent) target = 'line';
    // ALWAYS write — never clear-on-match. The user picked this
    // treatment globally; per-exercise practitioner defaults must not
    // win.
    if (!clientOverrides[ex.id]) clientOverrides[ex.id] = {};
    clientOverrides[ex.id].treatment = target;
  }
  saveClientOverrides(plan && plan.id);
  // Re-render the deck with new src URLs so post-handoff playback picks
  // up the new treatment.
  try { rebindVideoSources(); } catch (_) { /* deck not yet primed */ }
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
const $btnLandscapeMaximise = document.getElementById('btn-landscape-maximise');
const $btnPlayPause = document.getElementById('btn-playpause');
const $btnPlayPauseIconPlay = $btnPlayPause
  ? $btnPlayPause.querySelector('.pp-icon-play')
  : null;
const $btnPlayPauseIconPause = $btnPlayPause
  ? $btnPlayPause.querySelector('.pp-icon-pause')
  : null;
const $restCountdownOverlay = document.getElementById('rest-countdown-overlay');
const $restCountdownNumber = document.getElementById('rest-countdown-number');
const $cardNotes = document.getElementById('card-notes');
const $cardNotesText = document.getElementById('card-notes-text');

// Wave 21 — vertical rep-block stack (replaces the Wave 19.7 horizontal
// .set-progress-bar). Pinned to the LEFT edge of .card-viewport,
// vertically centered. One micro-block per rep + one thinner block per
// inter-set rest, stacked bottom-up. Section labels (S1, R, S2, …) sit
// in a left gutter outside the column.
//
// Rendering ownership:
//   * Skeleton (sections + blocks) is rebuilt via updateRepStack()
//     whenever the active slide / set count / breather changes.
//   * Per-rep fills are painted via paintActiveRepBlock() driven by
//     handleLoopBoundary() — discrete bumps, no time drift (the prior
//     time-based fill raced ahead of the rep label by ~rep 4 of 10).
//   * Rest fills are time-based: paintRestFill() runs on the 1Hz
//     onTimerTick() while setPhase === 'rest'.
//
// #breather-overlay still sits on top of the paused video and shows a
// big sage countdown + restful-person glyph during the inter-set rest.
const $repStack = document.getElementById('rep-stack');
const $repStackColumn = document.getElementById('rep-stack-column');
const $repStackLabels = document.getElementById('rep-stack-labels');
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
  // Wave Circuit-Names — practitioner-set custom labels per circuit_id
  // (mirrors plans.circuit_names jsonb on the cloud / mobile
  // SQLite sessions.circuit_names). Missing key or empty string =
  // "no custom name; the active-slide header omits the circuit prefix".
  const names = plan.circuit_names || {};
  const result = [];
  let i = 0;
  while (i < exercises.length) {
    const ex = exercises[i];
    if (!ex.circuit_id) {
      result.push({
        ...ex,
        circuitRound: null,
        circuitTotalRounds: null,
        positionInCircuit: null,
        circuitSize: null,
        circuitName: null,
      });
      i++;
    } else {
      const circuitId = ex.circuit_id;
      const group = [];
      while (i < exercises.length && exercises[i].circuit_id === circuitId) {
        group.push(exercises[i]);
        i++;
      }
      const totalRounds = Number.parseInt(cycles[circuitId], 10) || 3;
      const rawName = names[circuitId];
      const circuitName = (typeof rawName === 'string' && rawName.trim())
        ? rawName.trim()
        : null;
      for (let round = 1; round <= totalRounds; round++) {
        group.forEach((gex, idx) => {
          result.push({
            ...gex,
            circuitRound: round,
            circuitTotalRounds: totalRounds,
            positionInCircuit: idx + 1,
            circuitSize: group.length,
            circuitName,
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

  // Push the per-plan crossfade fade-duration into a CSS var so the
  // .video-loop-slot transition picks it up. Cascades from :root.
  document.documentElement.style.setProperty(
    '--loop-crossfade-fade-ms',
    `${getLoopCrossfadeFadeMs()}ms`,
  );

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

  // Lazy-load videos for the first slide + neighbours. Videos are built
  // with data-src (not src) to prevent Safari crashing on 46 simultaneous
  // preload="auto" elements.
  lazyLoadNearbyVideos(currentIndex);

  // Prime the top-stack header + notes overlay for the first slide.
  updateActiveSlideHeader();
  updateCardNotes();

  updateUI();
  // updateUI() doesn't touch the play/pause toggle, so prime it here so
  // its hidden state + glyph reflect workout-mode on first paint.
  updatePlayPauseToggle();
}

function buildCard(slide, index) {
  // Rest card
  if (slide.media_type === 'rest') {
    return buildRestCard(slide, index);
  }

  const mediaHTML = buildMedia(slide, index);
  const mediaType = slide.media_type === 'video' ? 'video' : 'photo';
  // Wave 28 — landscape support. Each exercise carries its post-rotation
  // effective aspect ratio (NULL on legacy plans). Stash it on the card
  // as a CSS var so portrait/landscape media queries can size the slot
  // before the video metadata fires. NULL → no inline style → CSS
  // defaults win exactly as before.
  const ar = Number(slide.aspect_ratio);
  const arAttr = Number.isFinite(ar) && ar > 0
    ? ` style="--exercise-aspect-ratio: ${ar};"`
    : '';

  return `
    <div class="exercise-card" data-index="${index}" data-media-type="${mediaType}"${arAttr}>
      <div class="card-inner">
        <div class="card-media" data-media-index="${index}">
          ${mediaHTML}
          ${buildPrepOverlay(slide)}
        </div>
      </div>
    </div>
  `;
}

/**
 * Wave 28 — landscape support. Practitioner's manual playback rotation
 * for each exercise, expressed in quarter-turns. Maps NULL / garbage
 * to 0 so legacy plans render identically to today. The CSS transform
 * lives on a wrapper element (.video-loop-pair for videos,
 * .media-rotation-wrap for photos), never directly on the <video> /
 * <img> — that keeps the dual-video crossfade opacity transitions on
 * a clean stacking context.
 */
function getExerciseRotationDeg(slide) {
  const q = Number(slide && slide.rotation_quarters) || 0;
  return ((q % 4) + 4) % 4 * 90;
}

function buildRestCard(slide, index) {
  // Rest card: icon + "Rest" title + "Next up: X" subtitle. Name + grammar
  // live in the top-stack active-slide-header (not inside the card). Tap
  // to pause/resume is via the .card-media area (handleMediaTap).
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
          ${buildPrepOverlay(slide)}
        </div>
      </div>
    </div>
  `;
}

/**
 * Item 15: prep countdown overlay — big coral number fades over the last
 * 200ms of each second. Lives inside card-media but above it. JS toggles
 * visibility + drives the digit text + fade timing.
 *
 * Wave Hero — when the slide carries a `thumbnail_url`, render the
 * Hero still as a full-bleed `<img>` underneath the digit so the
 * practitioner's chosen frame greets the client during the runway.
 * The video element behind the overlay is paused/idle during prep, so
 * showing the Hero gives the upcoming exercise a clean, intentional
 * hero-shot instead of the freeze-frame at trim start. The image is
 * crossfaded out via CSS when the overlay's [hidden] attribute lands
 * (overlay→.prep-overlay-number transition handles the digit; the
 * .hero-poster's own transition handles the image).
 */
function buildPrepOverlay(slide) {
  const heroSrc = slide && slide.thumbnail_url
    ? `<img class="hero-poster" src="${escapeHTML(slide.thumbnail_url)}" alt="" aria-hidden="true">`
    : '';
  return `
    <div class="prep-overlay" hidden>
      ${heroSrc}
      <div class="prep-overlay-number">15</div>
    </div>
  `;
}

/**
 * Wave 41 — decoded grammar for the active slide. Reads `slide.sets[]`
 * (post per-set PLAN refactor) and produces a per-set summary:
 *   Uniform:           `3 × 10 @ 15 kg · 60 s rest`
 *   Pyramid (varied):  `10/8/6 @ 12.5/15/17.5 kg · 60 s rest`
 *   Bodyweight:        `3 × 10 · 30 s hold · 60 s rest`
 *   Mixed breathers:   `3 sets · varied`
 *   Circuit (1 set):   `10 reps @ 15 kg · 30 s hold`  (round count owned by matrix)
 *   Rest:              `30 s rest`
 *
 * Returns a plain string (no HTML) — the caller sets textContent.
 */
function buildDecodedGrammar(slide) {
  if (!slide) return '';
  if (slide.media_type === 'rest') {
    const v = slide.rest_seconds;
    const secs = (v != null && Number.isFinite(Number(v)) && Number(v) > 0)
      ? Math.round(Number(v))
      : 30;
    return `${secs} s rest`;
  }

  const playSets = playSetsForSlide(slide);
  if (!playSets.length) return '';

  const isCircuit = !!slide.circuitRound;

  // Helpers for shape detection.
  const repsList = playSets.map((s) => s.reps);
  const weightsList = playSets.map((s) => s.weight_kg);
  const holdsList = playSets.map((s) => s.hold_seconds);
  const breathersList = playSets.map((s) => s.breather_seconds_after);

  const repsUniform = repsList.every((r) => r === repsList[0]);
  const weightsUniform = weightsList.every((w) => w === weightsList[0]);
  const holdsUniform = holdsList.every((h) => h === holdsList[0]);
  const breathersUniform = breathersList.every((b) => b === breathersList[0]);
  const allBodyweight = weightsList.every((w) => w == null);

  // Circuit slides represent ONE set per round; the round count is
  // surfaced by the matrix. Drop the `N ×` prefix.
  if (isCircuit) {
    const set = playSets[0];
    const parts = [];
    parts.push(`${set.reps} reps`);
    if (set.weight_kg != null) parts.push(`@ ${formatWeightKg(set.weight_kg)}`);
    if (set.hold_seconds > 0) parts.push(`${set.hold_seconds} s hold`);
    return parts.join(' · ');
  }

  // Mixed breathers (varied schemes that aren't reducible to a single
  // tagline) collapse to a "varied" tail per the brief.
  if (!breathersUniform && (!repsUniform || !weightsUniform)) {
    return `${playSets.length} sets · varied`;
  }

  const parts = [];
  if (repsUniform && weightsUniform) {
    // Uniform shape — `N × R [@ W kg]`
    let head = `${playSets.length} × ${repsList[0]}`;
    if (!allBodyweight) head += ` @ ${formatWeightKg(weightsList[0])}`;
    parts.push(head);
  } else {
    // Pyramid / varied reps or weights — emit slash-joined sequences.
    const repsStr = repsList.join('/');
    if (allBodyweight) {
      parts.push(repsStr);
    } else if (weightsUniform) {
      parts.push(`${repsStr} @ ${formatWeightKg(weightsList[0])}`);
    } else {
      const weightsStr = weightsList
        .map((w) => (w == null ? 'BW' : formatWeightKg(w).replace(' kg', '')))
        .join('/');
      parts.push(`${repsStr} @ ${weightsStr} kg`);
    }
  }

  if (holdsUniform && holdsList[0] > 0) {
    parts.push(`${holdsList[0]} s hold`);
  } else if (!holdsUniform && holdsList.some((h) => h > 0)) {
    parts.push('varied hold');
  }

  if (breathersUniform && breathersList[0] > 0) {
    parts.push(`${breathersList[0]} s rest`);
  }

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
  //
  // Wave Circuit-Names: when the slide is part of a circuit AND the
  // practitioner has set a custom label, prefix the title with
  // "{circuitName}: ". The matrix already shows circuit position
  // visually (so we still skip Round X of Y), but a named circuit
  // ("Push Day") is information the matrix doesn't carry. Auto-labels
  // ("Circuit A") never reach the player — they live only in the
  // practitioner-facing Studio gutter — so showing them on the player
  // would just add noise.
  const baseTitle = grammar ? `${name} · ${grammar}` : name;
  const circuitName = !isRest && slide.circuitName ? slide.circuitName : null;
  $activeSlideTitle.textContent = circuitName
    ? `${circuitName}: ${baseTitle}`
    : baseTitle;
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
    // Wave 42 — the standalone mute speaker button on the player chrome
    // was retired; the gear panel is the only entry point for mute.
    // We still render `muted` on the <video> element for Safari autoplay
    // compliance; applyMuteStateToAllVideos() unmutes per-exercise
    // effective state inside the Start Workout user gesture.
    const mutedAttr = 'muted';
    const posterAttr = exercise.thumbnail_url ? `poster="${escapeHTML(exercise.thumbnail_url)}"` : '';
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
    // Wave 28 — practitioner's manual playback rotation lives on the
    // pair wrapper so it composes cleanly with the per-video opacity
    // crossfade. 0deg → no transform style → identical CSS to legacy.
    const rotDeg = getExerciseRotationDeg(exercise);
    const rotStyle = rotDeg ? ` style="transform: rotate(${rotDeg}deg);"` : '';
    return `
      <div class="video-loop-pair" data-pair-index="${index}" data-rotation-deg="${rotDeg}"${rotStyle}>
        <video
          id="video-${index}"
          class="video-loop-slot ${grayscaleClass}"
          data-src="${escapeHTML(resolvedUrl)}"
          data-treatment="${slideT}"
          data-active="true"
          data-loop-slot="a"
          playsinline
          loop
          ${mutedAttr}
          preload="none"
          ${posterAttr}
        ></video>
        <video
          id="video-${index}-b"
          class="video-loop-slot ${grayscaleClass}"
          data-src="${escapeHTML(resolvedUrl)}"
          data-treatment="${slideT}"
          data-active="false"
          data-loop-slot="b"
          playsinline
          loop
          muted
          preload="none"
          ${posterAttr}
          aria-hidden="true"
        ></video>
      </div>
    `;
  }

  // Photo / image (Wave 22 — three-treatment parity with videos).
  //
  // `slideT` resolved above honours practitioner sticky `preferred_treatment`
  // AND the client-controlled "Show me" override. `resolvedUrl` is:
  //   line     → the line-drawing JPG (public `media` bucket — always)
  //   bw       → grayscale_segmented_url || grayscale_url (signed, consent-
  //              gated). When body-focus is ON (default), the segmented JPG
  //              produced on-device by ClientAvatarProcessor is preferred —
  //              same Vision body-pop look as videos. When OFF, falls back
  //              to the untouched raw colour JPG. CSS .is-grayscale applies
  //              the grayscale filter either way.
  //   original → original_segmented_url || original_url (signed, consent-
  //              gated). Same body-focus toggle behaviour as bw.
  //
  // Wave 36 — segmented JPG variant for photos. Up to W22 photos shared a
  // single raw colour source; Wave 36 ships a body-focus segmented JPG
  // alongside it (path: `<exerciseId>.segmented.jpg` in `raw-archive`),
  // surfaced via `grayscale_segmented_url` / `original_segmented_url`.
  // Legacy photos with only the raw colour still render correctly because
  // resolveTreatmentUrl falls back to the untouched original when the
  // segmented variant is null.
  //
  // Treatment swaps hot-swap the <img> src on the next render — no
  // crossfade needed (single frame, no motion artefact). Legacy photos
  // with no separate raw stay on line drawing because slideTreatment()
  // falls back to 'line' when grayscale_url + original_url are both
  // null.
  //
  // Use `data-treatment` for the same hook the video render emits, so
  // future per-element preview/inspect tooling treats both surfaces
  // uniformly.
  const grayscaleClass = slideT === 'bw' ? 'is-grayscale' : '';
  // Wave 28 — wrap photos in a thin rotation container so the same
  // wrapper-anchored rotation pattern that videos use works for images
  // too. Wrapper is a no-op for legacy plans (rotation 0 → no inline
  // style); CSS rules in styles.css give the wrapper inherent fill.
  const rotDeg = getExerciseRotationDeg(exercise);
  const rotStyle = rotDeg ? ` style="transform: rotate(${rotDeg}deg);"` : '';
  return `<div class="media-rotation-wrap" data-rotation-deg="${rotDeg}"${rotStyle}><img src="${escapeHTML(resolvedUrl)}" alt="${escapeHTML(exercise.name || 'Exercise')}" class="${grayscaleClass}" data-treatment="${slideT}" loading="lazy"></div>`;
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
  // Wave 42 — body focus is now per-exercise (PR #146 schema) overlaid
  // by client overrides via getEffective().
  const bodyFocusOn = getEffective(exercise, 'bodyFocus');
  if (treatment === 'bw') {
    if (bodyFocusOn) {
      return exercise.grayscale_segmented_url || exercise.grayscale_url || null;
    }
    // Body focus OFF — skip the segmented variant and play the
    // untouched original. When the raw original is missing we still
    // fall through to the segmented copy so the slide can play at all.
    return exercise.grayscale_url || exercise.grayscale_segmented_url || null;
  }
  if (treatment === 'original') {
    if (bodyFocusOn) {
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
  // Wave 41 — read off slide.sets[]. For a uniform scheme we surface
  // `S|R|H`; for varied schemes we collapse to `R*` so the pill still
  // fits in tight chrome.
  const playSets = playSetsForSlide(slide);
  if (!playSets.length) return '';
  const parts = [];
  const isCircuit = !!slide.circuitRound;
  const repsList = playSets.map((s) => s.reps);
  const holdsList = playSets.map((s) => s.hold_seconds);
  const repsUniform = repsList.every((r) => r === repsList[0]);
  const holdsUniform = holdsList.every((h) => h === holdsList[0]);

  if (!isCircuit) parts.push(String(playSets.length));
  parts.push(repsUniform ? String(repsList[0]) : `${repsList[0]}*`);
  if (holdsUniform && holdsList[0] > 0) parts.push(String(holdsList[0]));
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
      // Bug fix 2026-05-04: floor remainingSeconds even though the source
      // is now integer — defends against any future fractional path
      // landing here.
      const showSecs = isWorkoutActive
        ? Math.max(0, Math.floor(remainingSeconds))
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
    emitAnalyticsEvent('exercise_navigation_jump', null, {
      from_slide: currentIndex,
      to_slide: target,
      method: 'pill',
    });
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

  // -- Wave 17 analytics: evaluate the LEAVING slide before switching. --
  var leavingIndex = currentIndex;
  var leavingSlide = slides[leavingIndex];
  if (leavingSlide && isWorkoutMode && analyticsConsented === true) {
    var viewedAt = analyticsSlideViewedAt[leavingIndex];
    var watchedMs = viewedAt ? Date.now() - viewedAt : 0;
    var slideDur = calculateDuration(leavingSlide) * 1000;
    var watchedPct = slideDur > 0 ? watchedMs / slideDur : 0;

    if (leavingSlide.media_type !== 'rest') {
      if (analyticsCompletedSlides[leavingIndex]) {
        // Already completed — navigating back counts as replay.
        if (index === leavingIndex) { /* no-op on same-slide */ }
      } else if (watchedPct >= 0.8 || remainingSeconds <= 0) {
        analyticsCompletedSlides[leavingIndex] = true;
        emitAnalyticsEvent('exercise_completed', leavingSlide.id, {
          watched_ms: Math.round(watchedMs),
          threshold_met: watchedPct >= 0.8,
        });
      } else if (watchedPct < 0.2 && watchedMs > 500) {
        emitAnalyticsEvent('exercise_skipped', leavingSlide.id, {
          watched_ms: Math.round(watchedMs),
        });
      }
    }
  }

  // -- Wave 17 analytics: detect replay (navigating back to a completed slide). --
  if (isWorkoutMode && analyticsConsented === true && analyticsCompletedSlides[index]) {
    var replaySlide = slides[index];
    if (replaySlide && replaySlide.media_type !== 'rest') {
      emitAnalyticsEvent('exercise_replayed', replaySlide.id, {
        from_ms: analyticsSlideViewedAt[index] ? Date.now() - analyticsSlideViewedAt[index] : 0,
      });
    }
  }

  // Pause any playing videos on current card
  pauseAllVideos();

  // Wave 19.7 — tear down the crossfade machinery on the slide we're
  // leaving so a stale `ended` event can't tick reps on the new slide,
  // (rep counter is time-derived now — no per-slide state to reset.)
  teardownLoopForSlide(currentIndex);

  // Cancel any in-flight prep countdown; the new slide gets its own setup.
  clearPrepTimer();

  currentIndex = index;

  // -- Wave 17 analytics: record when this slide was first viewed. --
  if (isWorkoutMode) {
    analyticsSlideViewedAt[index] = Date.now();
    var activeSlide = slides[index];
    if (activeSlide && activeSlide.media_type !== 'rest') {
      emitAnalyticsEvent('exercise_viewed', activeSlide.id, {
        slide_position: index,
      });
    }
  }
  updateUI();
  // After a jump, recompute immediately so we don't wait 1s for the ticker.
  updateTimelineBar();
  // Slide state changed — re-evaluate the pause/prep overlay visibility on
  // the new active slide and hide them on the old one.
  updatePlayPauseToggle();
  updatePrepOverlay();
  // Wave 42 — repaint the gear panel against the new active slide so
  // the per-exercise effective state shown matches what's playing. Also
  // applies muted state because mute is per-exercise.
  paintGearPanel();
  applyMuteStateToAllVideos();

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
    // -- Wave 17 analytics: rest_shortened when skipping a rest slide early. --
    if (analyticsConsented === true) {
      var skipSlide = slides[currentIndex];
      if (skipSlide && skipSlide.media_type === 'rest' && remainingSeconds > 0) {
        var scheduledMs = calculateDuration(skipSlide) * 1000;
        var viewedAt = analyticsSlideViewedAt[currentIndex];
        var actualMs = viewedAt ? Date.now() - viewedAt : 0;
        emitAnalyticsEvent('rest_shortened', null, {
          scheduled_ms: Math.round(scheduledMs),
          actual_ms: Math.round(actualMs),
        });
      }
    }
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

/**
 * Lazy-load videos for slides near the current index. Videos are created
 * with `data-src` (not `src`) and `preload="none"` to prevent Safari from
 * buffering all 46 elements at once (which crashes WebKit on iOS).
 *
 * This function sets `src` from `data-src` for the current slide ± 2.
 * Previously-loaded videos are NEVER unloaded — removing `src` from a
 * loaded video causes stuttering when the user navigates back. The
 * initial `preload="none"` + no `src` prevents the crash; once loaded,
 * videos stay in memory.
 */
function lazyLoadNearbyVideos(centerIdx) {
  if (!$cardTrack) return;
  const WINDOW = 2; // load current ± 2 slides
  $cardTrack.querySelectorAll('video[data-src]').forEach((v) => {
    const card = v.closest('.exercise-card');
    if (!card) return;
    const idx = Number(card.getAttribute('data-index'));
    if (!Number.isFinite(idx)) return;
    const near = Math.abs(idx - centerIdx) <= WINDOW;
    const hasSrc = v.hasAttribute('src') && v.getAttribute('src');
    if (near && !hasSrc) {
      v.setAttribute('src', v.getAttribute('data-src'));
      v.preload = 'auto';
      v.load();
    }
    // Do NOT unload distant videos — causes stuttering on back-navigation.
  });
}

function autoPlayCurrentVideo() {
  lazyLoadNearbyVideos(currentIndex);
  const currentVideo = getActiveVideoForSlide(currentIndex);
  if (!currentVideo) return;
  // If the video has data, play immediately. If not (just lazy-loaded),
  // wait for `canplay` before calling play(). Prevents the silent
  // rejection that Safari produces when play() is called on an empty source.
  if (currentVideo.readyState >= 2) { // HAVE_CURRENT_DATA
    currentVideo.play().catch((err) => {
      console.warn('video autoplay blocked:', err);
    });
  } else {
    currentVideo.addEventListener('canplay', function onCanPlay() {
      currentVideo.removeEventListener('canplay', onCanPlay);
      currentVideo.play().catch((err) => {
        console.warn('video autoplay blocked:', err);
      });
    });
  }
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

  state = state || { activeSlot: 'a', armed: false };
  state.activeSlot = active.getAttribute('data-loop-slot') || 'a';
  state.armed = true;
  state.prebuffered = false;
  loopState.set(idx, state);

  attachLoopListeners(idx, active);
}

function attachLoopListeners(idx, videoEl) {
  if (!videoEl) return;

  // `lastTime` lets timeupdate detect both:
  //   * the prebuffer trigger (currentTime > effectiveEnd - leadMs)
  //   * the loop seam itself (currentTime < lastTime → just wrapped)
  // We can't rely on the `ended` event because the native `loop`
  // attribute suppresses it — the browser silently seeks back to 0
  // and continues. timeupdate fires every ~250ms on iOS Safari, which
  // is dense enough to catch both events reliably.
  let lastTime = 0;

  const onTimeUpdate = () => {
    const dur = videoEl.duration;
    if (!Number.isFinite(dur) || dur <= 0) return;
    // Trim window collapses the effective loop end. Without this the
    // crossfade triggers off natural duration, which the trim-wrap
    // beats to the punch — preroll never fires inside a trimmed clip.
    const slide = slides[idx];
    const startSec = (slide && Number.isFinite(slide.start_offset_ms) && slide.start_offset_ms > 0)
      ? slide.start_offset_ms / 1000 : 0;
    const endSec = (slide && Number.isFinite(slide.end_offset_ms) && slide.end_offset_ms > 0)
      ? Math.min(slide.end_offset_ms / 1000, dur) : dur;
    const windowSec = Math.max(0, endSec - startSec);
    const inWindow = windowSec >= LOOP_CROSSFADE_MIN_DURATION
                  && windowSec <= LOOP_CROSSFADE_MAX_DURATION;
    const state = loopState.get(idx);
    if (!state) { lastTime = videoEl.currentTime; return; }

    const t = videoEl.currentTime;

    // Wrap detect: trim or natural-loop both seek backwards. Threshold
    // is half the trim window so a tiny skip-back doesn't false-fire.
    if (lastTime > 0 && t + 0.05 < lastTime && (lastTime - t) > windowSec / 2) {
      lastTime = t;
      handleLoopBoundary(idx);
      return;
    }

    // Prebuffer trigger — measured against the trim end, not natural duration.
    if (!state.prebuffered && inWindow && (endSec - t) * 1000 <= getLoopCrossfadeLeadMs()) {
      const inactive = getInactiveVideoForSlide(idx);
      if (inactive) {
        state.prebuffered = true;
        try {
          inactive.currentTime = startSec;
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
 * One loop just ended on slide `idx`. Crossfade only — flip data-active
 * so the prebuffered inactive slot becomes the visible active slot,
 * reset the now-inactive slot to currentTime=0 + pause so it's ready
 * for the next cycle. Rep counter is time-derived in the painter; the
 * loop seam doesn't touch it.
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
    const startSec = (Number.isFinite(slide.start_offset_ms) && slide.start_offset_ms > 0)
      ? slide.start_offset_ms / 1000 : 0;
    const endSec = (Number.isFinite(slide.end_offset_ms) && slide.end_offset_ms > 0)
      ? Math.min(slide.end_offset_ms / 1000, dur) : dur;
    const windowSec = Math.max(0, endSec - startSec);
    const inWindow = windowSec >= LOOP_CROSSFADE_MIN_DURATION
                  && windowSec <= LOOP_CROSSFADE_MAX_DURATION;
    if (state.prebuffered && inWindow) {
      // Visible swap. CSS handles the opacity transition.
      newActive.setAttribute('data-active', 'true');
      oldActive.setAttribute('data-active', 'false');
      // Audio handoff: the new active slot inherits the muted state
      // of the old one.
      newActive.muted = oldActive.muted;
      // Park the just-superseded slot at trim-start so the next preroll
      // is one seek away.
      try {
        oldActive.pause();
        oldActive.currentTime = startSec;
      } catch (_) { /* swallow */ }
      // Re-arm listeners on the new active slot.
      detachLoopListeners(oldActive);
      attachLoopListeners(idx, newActive);
      state.activeSlot = newActive.getAttribute('data-loop-slot') || state.activeSlot;
    }
  }
  state.prebuffered = false;
  loopState.set(idx, state);

  // Carl 2026-04-24 — the rep counter is now derived from elapsed time
  // (the duration is the source of truth, not the loop seam). The loop
  // seam still drives the crossfade above, but no longer touches the
  // rep counter. The painter computes repsInSet from the timer on every
  // 1Hz tick. Keeping handleLoopBoundary scoped to crossfade duties only.
}

/**
 * Wave 21 — fill the next rep block in the active set with solid
 * coral. Driven by handleLoopBoundary's per-loop-seam tick (i.e. one
 * rep per video loop). Discrete jump (200ms ease-in via the fill
 * child's CSS transition); no partial fills, no time drift.
 *
 * The "next-to-land" block carries `--active`; once we mark this rep
 * filled we promote the following block to active so the 1Hz pulse
 * tracks "where the next rep will land".
 */
function paintActiveRepBlock() {
  if (!$repStackColumn) return;
  const slide = slides[currentIndex];
  if (!slide || slide.media_type === 'rest') return;

  // Duration is the source of truth — rep stack fill derives from
  // elapsed proportion of the set phase, not video loop count. Same
  // logic for photos and videos; active block doubles as a per-rep
  // progress bar via `activeFillPct`.
  // Wave 41 — read reps from the active set object so pyramids /
  // varied breathers paint correctly.
  let repsInSet = 0;
  let activeFillPct = 0;
  const playSetsActive = playSetsForSlide(slide);
  if (isWorkoutMode && setPhase === 'set') {
    const activeIdx = Math.min(currentSetIndex, playSetsActive.length - 1);
    const activeSet = playSetsActive[activeIdx];
    const totalReps = (activeSet && activeSet.reps) || 0;
    const isLast = activeIdx >= playSetsActive.length - 1;
    const perSet = calculatePerSetSeconds(activeSet, slide, isLast);
    // The breather is baked into perSet; subtract it for the rep-fill
    // window so the active rep block reaches 100% at "last rep" and
    // the breather plays its own sage block.
    const breatherForActive = activeSet ? (activeSet.breather_seconds_after || 0) : 0;
    const physicalSet = Math.max(1, perSet - breatherForActive);
    if (totalReps > 0 && physicalSet > 0) {
      // Wave 41 fix — setPhaseRemaining now counts the physical window
      // only (breather lives in the 'rest' phase). Elapsed-in-physical
      // is therefore physicalSet - setPhaseRemaining directly.
      const elapsedInPhysical = Math.max(0, Math.min(physicalSet, physicalSet - setPhaseRemaining));
      const perRep = physicalSet / totalReps;
      repsInSet = Math.min(totalReps, Math.floor(elapsedInPhysical / perRep));
      const intraRep = elapsedInPhysical - (repsInSet * perRep);
      activeFillPct = Math.max(0, Math.min(100, (intraRep / perRep) * 100));
    }
  }

  // 2026-05-04 — End-of-exercise badge retired (Carl: "serves no
  // purpose"). The previous gating block toggled `.is-pending` on the
  // badge to reveal it during the final rest phase; both the badge and
  // its CSS rules are gone, so the gating is dead code.

  const setSections = $repStackColumn.querySelectorAll('.rep-stack-section--set');
  setSections.forEach((section) => {
    const setIdx = parseInt(section.getAttribute('data-set-index'), 10);
    if (Number.isNaN(setIdx)) return;
    const blocks = section.querySelectorAll('.rep-stack-block--rep');
    let landedRep;
    let activeRep = -1;
    if (setIdx < currentSetIndex) {
      landedRep = blocks.length;
    } else if (setIdx === currentSetIndex && setPhase === 'set' && isWorkoutMode) {
      landedRep = repsInSet;
      activeRep = repsInSet + 1;
    } else if (setIdx === currentSetIndex && setPhase === 'rest' && isWorkoutMode) {
      landedRep = blocks.length;
    } else {
      landedRep = 0;
    }
    for (let i = 0; i < blocks.length; i++) {
      const b = blocks[i];
      const repNum = i + 1; // bottom-up
      const fill = b.querySelector('.rep-stack-block-fill');
      if (repNum <= landedRep) {
        b.classList.add('rep-stack-block--filled');
        b.classList.remove('rep-stack-block--active');
        if (fill) fill.style.height = '';
      } else if (repNum === activeRep) {
        b.classList.add('rep-stack-block--active');
        b.classList.remove('rep-stack-block--filled');
        // Inline height overrides the CSS default; the active block's
        // linear-1s transition flows smoothly between 1Hz repaints.
        if (fill) fill.style.height = `${activeFillPct.toFixed(1)}%`;
      } else {
        b.classList.remove('rep-stack-block--filled');
        b.classList.remove('rep-stack-block--active');
        if (fill) fill.style.height = '';
      }
    }
  });
}

/** Reset the rep-in-set counter for the active slide (slide jump, set boundary). */
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
  updateRepStack();
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

// ----------------------------------------------------------------
// Wave 20 — soft-trim playback clamp
// ----------------------------------------------------------------
//
// Per-exercise practitioner-controlled in/out window stored on
// `slide.start_offset_ms` + `slide.end_offset_ms` (ms). Both null =
// no trim, full clip plays. Both set = clamp `currentTime` to the
// window and wrap the loop back to start when we cross the out-point.
//
// Hooked via delegated `loadedmetadata` + `timeupdate` listeners on
// `$cardViewport` (see init()). The same trim applies across all
// three treatments since they share source timing.

/**
 * Resolve `<video id="video-N">` → the slide payload that drives it,
 * so we can read its trim window. Returns null when the element isn't
 * ours / index out of range.
 */
function resolveSlideForVideoElement(video) {
  if (!video || !video.id || video.id.indexOf('video-') !== 0) return null;
  const idx = parseInt(video.id.slice('video-'.length), 10);
  if (Number.isNaN(idx)) return null;
  if (!slides || idx < 0 || idx >= slides.length) return null;
  return slides[idx];
}

/**
 * `loadedmetadata` handler — runs once per video src after the browser
 * knows the duration. When the slide has a trim window, seek into it
 * before the first painted frame so the loop begins inside the window.
 */
function onVideoLoadedMetadata(evt) {
  const video = evt && evt.target;
  if (!video || video.tagName !== 'VIDEO') return;
  const slide = resolveSlideForVideoElement(video);
  if (!slide) return;
  const startMs = slide.start_offset_ms;
  const endMs = slide.end_offset_ms;
  if (startMs == null || endMs == null) return;
  if (endMs <= startMs) return;
  try {
    video.currentTime = startMs / 1000;
  } catch (_) {
    // Some browsers throw if currentTime is set too early; ignore — the
    // first timeupdate clamp will catch up.
  }
}

/**
 * `timeupdate` handler — wraps the loop at the out-point. Fires roughly
 * every 250 ms in modern browsers (browser-driven, not setInterval), so
 * the seam is tight enough for a clean loop. Idempotent: a duplicate
 * seek when already at start is harmless.
 */
function onVideoTimeUpdate(evt) {
  const video = evt && evt.target;
  if (!video || video.tagName !== 'VIDEO') return;
  const slide = resolveSlideForVideoElement(video);
  if (!slide) return;
  const startMs = slide.start_offset_ms;
  const endMs = slide.end_offset_ms;
  if (startMs == null || endMs == null) return;
  if (endMs <= startMs) return;
  const tMs = video.currentTime * 1000;
  if (tMs >= endMs || tMs < startMs) {
    try {
      video.currentTime = startMs / 1000;
    } catch (_) { /* swallow — next tick retries */ }
  }
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
    updatePlayPauseToggle();
  }
}

// ============================================================
// Workout Timer
// ============================================================

/**
 * Wave 41 — return the per-rep video duration in seconds for a given
 * slide. Photos default to SECONDS_PER_REP. Videos derive from
 * `video_duration_ms / video_reps_per_loop` (legacy null reps_per_loop
 * treated as 1 — preserves pre-Wave-24 timing on old plans).
 */
function perRepSecondsForSlide(slide) {
  if (!slide) return SECONDS_PER_REP;
  if (slide.media_type === 'video') {
    const videoDurMs = slide.video_duration_ms || 0;
    const videoReps = slide.video_reps_per_loop || 1;
    if (videoDurMs > 0 && videoReps > 0) {
      return (videoDurMs / 1000) / videoReps;
    }
  }
  return SECONDS_PER_REP;
}

/**
 * Wave 41 — coerce a per-set entry to safe defaults. Used by
 * playSetsForSlide() and the rep-stack rendering, both of which need
 * to defend against unexpected nulls (e.g. a circuit slide whose
 * `sets[]` came back empty from the server).
 */
function _coerceSet(rawSet) {
  if (!rawSet) {
    return {
      reps: 10,
      hold_seconds: 0,
      hold_position: 'end_of_set',
      weight_kg: null,
      breather_seconds_after: 0,
    };
  }
  // Wave 43 — three-mode hold_position. Unknown / missing values fall
  // through to the new default 'end_of_set' (math identical to legacy
  // behaviour when hold_seconds === 0; per-rep-multiplying durations
  // keep their per_rep stamp via the v36 / wave43 backfills).
  const rawHp = rawSet.hold_position;
  const holdPosition = (rawHp === 'per_rep' || rawHp === 'end_of_set' || rawHp === 'end_of_exercise')
    ? rawHp
    : 'end_of_set';
  return {
    reps: Math.max(1, Number(rawSet.reps) || 10),
    hold_seconds: Math.max(0, Number(rawSet.hold_seconds) || 0),
    hold_position: holdPosition,
    weight_kg: rawSet.weight_kg == null ? null : Number(rawSet.weight_kg),
    breather_seconds_after: Math.max(0, Number(rawSet.breather_seconds_after) || 0),
  };
}

/**
 * Wave 41 — return the actual sets[] this slide will play, after
 * applying circuit-cycle expansion / trimming.
 *
 * Standalone (non-circuit) slides: just slide.sets[] verbatim.
 *
 * Circuit slides (each round is a separate slide via unrollExercises):
 *   - The slide represents ONE round of one exercise inside the
 *     circuit. We only play ONE set on this slide, picked from the
 *     slide's authored `sets[]`:
 *     • round index N maps to `sets[N - 1]` when present
 *     • round index N maps to `sets[last]` when N > sets.length
 *       (replay the final set on every extra round)
 *   - Trimming is implicit: if cycles < sets.length, the unroller
 *     never produces those rounds, so they never reach the player.
 *
 * Always returns at least one set (synthesises a single-set fallback
 * when slide.sets[] is empty — protects against legacy / partial
 * data without crashing the timer).
 */
function playSetsForSlide(slide) {
  if (!slide) return [_coerceSet(null)];
  const raw = Array.isArray(slide.sets) ? slide.sets : [];

  if (slide.circuitRound) {
    if (raw.length === 0) return [_coerceSet(null)];
    const idx = Math.min(slide.circuitRound - 1, raw.length - 1);
    return [_coerceSet(raw[idx])];
  }

  if (raw.length === 0) return [_coerceSet(null)];
  return raw.map(_coerceSet);
}

/**
 * Backwards-compat helper retained for call sites that just need the
 * count (matrix sizing, rep-stack key, jump math). Uses
 * playSetsForSlide() for circuit-aware truth.
 */
function effectiveSetsForSlide(slide) {
  if (!slide) return 1;
  return playSetsForSlide(slide).length;
}

/**
 * Wave 41 — per-set duration in seconds for one entry of slide.sets[].
 *
 * Wave 43 — three-mode hold_position:
 *   per_rep         → hold_total = reps × hold      (legacy contract)
 *   end_of_set      → hold_total = 1 × hold         (new default)
 *   end_of_exercise → hold_total = hold on LAST set; 0 elsewhere
 *
 *   per_rep_seconds = perRepSecondsForSlide(slide)
 *   per_set         = (reps × per_rep_seconds)
 *                   + hold_total
 *                   + set.breather_seconds_after
 *
 * The set's trailing breather is BAKED IN to the per-set total —
 * calculateDuration() sums these directly without re-adding rest. The
 * old `inter_set_rest_seconds` × N formula is gone.
 *
 * @param {object} setOrSlide  Either the set object (with reps + hold_*)
 *                             or the slide (with media_type) — the
 *                             single-arg legacy signature reads the
 *                             active set off the global state machine.
 * @param {object} [maybeSlide] Slide object when the first arg is a set.
 * @param {boolean} [isLastSetInExercise] True when this set is the last
 *                             playable set in its slide. Required for
 *                             `end_of_exercise` mode to contribute its
 *                             hold; ignored in the other two modes. The
 *                             single-arg fallback resolves this from
 *                             `currentSetIndex` / `totalSetsForSlide`
 *                             when not supplied. For circuit slides
 *                             (one effective set per slide), defaults
 *                             to true.
 */
function calculatePerSetSeconds(setOrSlide, maybeSlide, isLastSetInExercise) {
  // Two-arg signature: (set, slide) — preferred. Single-arg legacy
  // signature: (slide) — maps to the currently-active set on that
  // slide. The single-arg path covers ~10 call sites that have always
  // assumed uniform-sets timing; we honour their ask by reading the
  // active set off the global state machine.
  let set;
  let slide;
  let lastFlag = isLastSetInExercise;
  if (
    setOrSlide
    && typeof setOrSlide === 'object'
    && 'media_type' in setOrSlide
    && !('breather_seconds_after' in setOrSlide)
  ) {
    slide = setOrSlide;
    const playSets = playSetsForSlide(slide);
    const activeIdx = Math.max(0, Math.min(currentSetIndex || 0, playSets.length - 1));
    set = playSets[activeIdx];
    if (lastFlag === undefined) {
      // Single-arg fallback — derive from the active set's index
      // against the slide's effective set count. Circuit slides
      // produce one play-set so isLast collapses to true.
      lastFlag = activeIdx >= playSets.length - 1;
    }
  } else {
    set = setOrSlide;
    slide = maybeSlide;
    if (lastFlag === undefined) {
      // Two-arg, last flag omitted: legacy callers from before Wave 43.
      // Default to FALSE to preserve byte-stable durations on plans
      // that haven't opted into end_of_exercise. The hold contributes
      // 0 in that mode, which matches the v36 backfill's choice for
      // pre-existing plans (per_rep / end_of_set only).
      lastFlag = false;
    }
  }

  const perRep = perRepSecondsForSlide(slide);
  const reps = Math.max(1, (set && set.reps) || 1);
  const hold = Math.max(0, (set && set.hold_seconds) || 0);
  const breather = Math.max(0, (set && set.breather_seconds_after) || 0);
  const holdPosition = (set && set.hold_position) || 'end_of_set';
  // Wave 43 — three-mode hold_total.
  let holdTotal;
  if (holdPosition === 'per_rep') {
    holdTotal = reps * hold;
  } else if (holdPosition === 'end_of_exercise') {
    holdTotal = lastFlag ? hold : 0;
  } else {
    // 'end_of_set' (also the default for unknown wire values).
    holdTotal = hold;
  }
  const phys = (reps * perRep) + holdTotal;
  return Math.max(1, Math.round(phys + breather));
}

/**
 * Wave 41 — physical (rep-fill) portion of a set, excluding the trailing
 * breather. Used by the set/rest state machine to size the 'set' phase
 * correctly; the breather gets its own 'rest' phase via advanceSetPhase.
 *
 * Pre-this-fix: setPhaseRemaining was initialised to the full perSet
 * (which includes the breather), causing each non-final set to spend
 * physical + 2×breather in its 'set' phase. Symptom: rep stack fills
 * to "all reps done" then sits idle for `breather` seconds before the
 * sage rest block lit up.
 */
function calculatePhysicalSetSeconds(setOrSlide, maybeSlide, isLastSetInExercise) {
  const total = calculatePerSetSeconds(setOrSlide, maybeSlide, isLastSetInExercise);
  // Resolve the breather the same way calculatePerSetSeconds resolves
  // the set object — handle both two-arg and single-arg signatures.
  let set;
  if (
    setOrSlide
    && typeof setOrSlide === 'object'
    && 'media_type' in setOrSlide
    && !('breather_seconds_after' in setOrSlide)
  ) {
    const slide = setOrSlide;
    const playSets = playSetsForSlide(slide);
    const activeIdx = Math.max(0, Math.min(currentSetIndex || 0, playSets.length - 1));
    set = playSets[activeIdx];
  } else {
    set = setOrSlide;
  }
  const breather = Math.max(0, (set && set.breather_seconds_after) || 0);
  return Math.max(1, total - breather);
}

/**
 * Wave 41 — total duration in seconds for an exercise slide.
 *
 * Rest slides: `slide.rest_seconds` (with sensible 30s fallback when
 * the value is missing — protects against partial migration data).
 *
 * Exercise slides: sum of per-set durations from playSetsForSlide().
 * Each per-set total already includes its own
 * `breather_seconds_after`, so no extra rest math at this layer.
 */
function calculateDuration(slide) {
  if (slide.media_type === 'rest') {
    const v = slide.rest_seconds;
    if (v == null || !Number.isFinite(Number(v)) || Number(v) <= 0) return 30;
    return Math.max(1, Math.round(Number(v)));
  }

  // Wave 43 — pass isLastSetInExercise per iteration so end_of_exercise
  // hold contributes only on the final set. Circuit slides produce one
  // play-set so the last-set check collapses to true.
  const playSets = playSetsForSlide(slide);
  let total = 0;
  for (let i = 0; i < playSets.length; i++) {
    const isLast = i === playSets.length - 1;
    total += calculatePerSetSeconds(playSets[i], slide, isLast);
  }
  return Math.max(1, total);
}

/**
 * Wave 41 — compatibility shim for the small handful of call sites
 * that still ask "what's THIS set's trailing breather?". Returns the
 * `breather_seconds_after` on the active set, or 0 when out of range.
 */
function getBreatherForSet(slide, setIndex) {
  const playSets = playSetsForSlide(slide);
  if (setIndex < 0 || setIndex >= playSets.length) return 0;
  return Math.max(0, playSets[setIndex].breather_seconds_after || 0);
}

/**
 * Pre-Wave-41 helper — kept under its old name so the visibilitychange
 * fast-forward + a couple of legacy call sites continue to compile.
 * Returns the trailing breather of the currently-active set.
 */
function getInterSetRestSeconds(slide) {
  return getBreatherForSet(slide, currentSetIndex || 0);
}

/**
 * Format seconds as m:ss
 */
function formatTime(seconds) {
  // Bug fix 2026-05-04: floor at the display layer as belt-and-braces.
  // The source-fix in jumpToRep ensures integer remainingSeconds, but
  // any future fractional source upstream would otherwise leak into the
  // matrix as `23:54.6666...`. Coerce to a non-negative integer first.
  const total = Math.max(0, Math.floor(Number(seconds) || 0));
  const m = Math.floor(total / 60);
  const s = total % 60;
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
  document.body.classList.add('is-workout-mode');
  updateLandscapeMaximisePillVisibility();

  // Hide the start button
  $startWorkoutBtn.hidden = true;

  // v79-hardening (HIGH 3): now inside a user gesture, apply the
  // persisted mute preference to all videos. Renders initially muted for
  // Safari autoplay; this call unmutes where appropriate.
  applyMuteStateToAllVideos();

  // v79-hardening (MEDIUM 2): auto-dismiss the consent banner when
  // "Start Workout" is tapped. Treat undecided as "declined for this
  // session" — don't persist to localStorage so it reappears next load.
  if (analyticsConsented === null) {
    analyticsConsented = false;
    const consentBanner = document.getElementById('analytics-consent-banner');
    if (consentBanner) {
      consentBanner.classList.remove('is-visible');
      setTimeout(function () { consentBanner.remove(); }, 400);
    }
  }

  // Top-stack v1 — request browser fullscreen so the video fills the
  // viewport. Must be inside the button's click gesture; the browser
  // rejects the API call otherwise.
  requestFullscreen();

  if (currentIndex === 0) {
    // Already on the first slide — goTo() short-circuits when index is
    // unchanged, so manually kick off the workout phase.
    autoPlayCurrentVideo();
    enterWorkoutPhaseForCurrent();
    // -- Wave 17 analytics: record the first slide as viewed since goTo()
    // won't fire for index 0 when we're already there. --
    analyticsSlideViewedAt[0] = Date.now();
    if (analyticsConsented === true) {
      var firstSlide = slides[0];
      if (firstSlide && firstSlide.media_type !== 'rest') {
        emitAnalyticsEvent('exercise_viewed', firstSlide.id, { slide_position: 0 });
      }
    }
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

  // Carl 2026-04-24 — repaint the rep stack now that the new slide's
  // setPhase / currentSetIndex / setPhaseRemaining are fresh. updateUI()
  // ran the structure rebuild before us with stale 'rest' state from the
  // previous slide, which would render every block filled for ~2s until
  // the next 1Hz tick. Repainting here closes that visible gap.
  updateRepStack();

  // Same race for the breather sage countdown chip — `updateUI()` saw
  // stale `setPhase === 'rest'` carried over from the previous slide's
  // trailing breather, which left the chip visible during the new
  // slide's prep countdown ("different timers on screen", Carl 2026-04-24).
  // Repaint after the state machine has flipped phase back to 'set'.
  updateBreatherOverlay();
  updateRestCountdownOverlay();

  if (slide.media_type === 'rest') {
    // Rest — no prep, auto-start countdown. The bottom-right timer chip
    // is the single source of truth for the rest countdown.
    startTimer();
  } else {
    // Exercise — check if video is ready. If not (lazy-loaded, still
    // buffering), show a loading indicator and defer the prep phase
    // until the video has data. Prevents timers running on a black/still
    // screen.
    var video = getActiveVideoForSlide(currentIndex);
    if (video && video.readyState < 2) { // < HAVE_CURRENT_DATA
      showVideoLoadingOverlay();
      var prepFired = false;
      var safetyTimer = null;
      var slideAtEntry = currentIndex;
      function fireOnce() {
        if (prepFired || currentIndex !== slideAtEntry) return;
        prepFired = true;
        if (safetyTimer) clearTimeout(safetyTimer);
        hideVideoLoadingOverlay();
        startPrepPhase();
      }
      video.addEventListener('canplay', function onReady() {
        video.removeEventListener('canplay', onReady);
        fireOnce();
      });
      safetyTimer = setTimeout(fireOnce, 8000);
    } else {
      startPrepPhase();
    }
  }
}

/** Overlay shown while waiting for a lazy-loaded video to buffer. */
function showVideoLoadingOverlay() {
  var existing = document.getElementById('video-loading-overlay');
  if (existing) return;
  var overlay = document.createElement('div');
  overlay.id = 'video-loading-overlay';
  overlay.style.cssText = 'position:fixed;inset:0;display:flex;align-items:center;justify-content:center;background:rgba(15,17,23,0.7);z-index:9999;';
  overlay.innerHTML = '<div style="text-align:center;color:#F0F0F5;font-family:Inter,sans-serif;">' +
    '<div style="width:32px;height:32px;border:3px solid rgba(255,107,53,0.3);border-top-color:#FF6B35;border-radius:50%;animation:spin 0.8s linear infinite;margin:0 auto 12px;"></div>' +
    '<div style="font-size:13px;opacity:0.7;">Loading video\u2026</div></div>';
  // Add keyframe if not already present
  if (!document.getElementById('video-loading-spin')) {
    var style = document.createElement('style');
    style.id = 'video-loading-spin';
    style.textContent = '@keyframes spin{to{transform:rotate(360deg)}}';
    document.head.appendChild(style);
  }
  document.body.appendChild(overlay);
}

function hideVideoLoadingOverlay() {
  var el = document.getElementById('video-loading-overlay');
  if (el) el.remove();
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
  // Wave 41 — circuit slides resolve to 1 set (one round = one set
  // chosen from the authored sets[]). Standalone slides play every
  // authored set in order. playSetsForSlide() handles both.
  const playSets = playSetsForSlide(slide);
  totalSetsForSlide = playSets.length;
  setPhase = 'set';
  // Wave 43 — the first set is also the last when there's only one
  // play-set on this slide (circuit slides always; pyramids only when
  // they happen to authour a single set).
  // Wave 41 fix — setPhaseRemaining sizes the 'set' phase only; the
  // trailing breather is counted in the subsequent 'rest' phase via
  // advanceSetPhase. Use physical-only here (perSet minus breather).
  setPhaseRemaining = calculatePhysicalSetSeconds(
    playSets[0],
    slide,
    playSets.length <= 1,
  );
  // The breather is per-set; cache the FIRST set's breather here for
  // legacy consumers that still read `interSetRestForSlide`. Phase
  // transitions refresh this from the active set.
  interSetRestForSlide = playSets[0].breather_seconds_after || 0;
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
  updatePlayPauseToggle();
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
  updatePlayPauseToggle();
  updateRestCountdownOverlay();
  updateRepStack();
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

  // Carl 2026-04-24 — paint the rep stack BEFORE the phase boundary
  // check so the final frame of the set phase actually shows
  // `repsInSet === totalReps` (rep 10 landing) before advanceSetPhase()
  // flips us to 'rest'. Without this, the painter only ever saw the
  // 'rest' branch at this tick and rep 10 was perceived as "skipped".
  updateRepStack();

  // Milestone Q — phase boundary inside the active slide (set → rest or
  // rest → set). The overall `remainingSeconds` keeps ticking; only the
  // phase-local counter wraps.
  if (!isRestSlide() && setPhaseRemaining <= 0) {
    advanceSetPhase();
    // Repaint after advance so the rest branch shows immediately on the
    // SAME tick that rep 10 finished landing. (advanceSetPhase already
    // calls updateRepStack at its tail, but be explicit for clarity.)
    updateRepStack();
  }

  // Matrix active-pill fill needs a per-second nudge too.
  updateProgressMatrix();
  updateRestCountdownOverlay();
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
  // Wave 41 — read breather + next-set duration off the active set
  // object so pyramid / varied schemes flow correctly. The single
  // cached `interSetRestForSlide` is updated alongside for legacy
  // consumers (rest-fill paint, viz-change fast-forward).
  const slide = slides[currentIndex];
  const playSets = playSetsForSlide(slide);

  if (setPhase === 'set') {
    // Every set (INCLUDING the last) is followed by its own
    // breather_seconds_after when > 0. The trailing rest gives the
    // client a "you're done, breathe" cue before the slide advances.
    const activeBreather = getBreatherForSet(slide, currentSetIndex);
    if (activeBreather > 0) {
      // Enter breather. Pause the video at its current frame (no reset).
      setPhase = 'rest';
      setPhaseRemaining = activeBreather;
      interSetRestForSlide = activeBreather;
      pauseActiveVideoForBreather();
    } else {
      // No breather — skip straight to the next set, keep the video
      // playing without interruption. (Last set + no breather is the
      // legacy single-block path; handled by remainingSeconds=0.)
      const isLastSet = currentSetIndex >= totalSetsForSlide - 1;
      if (isLastSet) return;
      currentSetIndex++;
      setPhase = 'set';
      const nextSet = playSets[currentSetIndex];
      const nextIsLast = currentSetIndex >= playSets.length - 1;
      // Wave 41 fix — physical-only; breather is counted in next 'rest' phase.
      setPhaseRemaining = calculatePhysicalSetSeconds(nextSet, slide, nextIsLast);
      interSetRestForSlide = nextSet.breather_seconds_after || 0;
    }
  } else {
    // rest → next set. Bump set index, resume video. Trailing rest
    // after the last set ends with the slide via onTimerComplete.
    const isLastSet = currentSetIndex >= totalSetsForSlide - 1;
    if (isLastSet) return;
    currentSetIndex++;
    setPhase = 'set';
    const nextSet = playSets[currentSetIndex];
    const nextIsLast = currentSetIndex >= playSets.length - 1;
    // Wave 41 fix — physical-only; breather is counted in next 'rest' phase.
    setPhaseRemaining = calculatePhysicalSetSeconds(nextSet, slide, nextIsLast);
    interSetRestForSlide = nextSet.breather_seconds_after || 0;
    resumeActiveVideoAfterBreather();
  }
  updateRepStack();
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
// is driven by updatePlayPauseToggle(); countdown numbers read from the ETA row.

/**
 * Timer hit zero -- advance to next slide. goTo() re-enters the workout
 * phase (prep for exercises, auto-start for rest) for the new slide.
 */
function onTimerComplete() {
  hideTimerDisplay();

  // -- Wave 17 analytics: mark completed slide + detect rest_extended. --
  if (analyticsConsented === true) {
    var completingSlide = slides[currentIndex];
    if (completingSlide) {
      if (completingSlide.media_type === 'rest') {
        // Check if rest ran past its scheduled time.
        var viewedAt = analyticsSlideViewedAt[currentIndex];
        var actualMs = viewedAt ? Date.now() - viewedAt : 0;
        var scheduledMs = calculateDuration(completingSlide) * 1000;
        if (actualMs > scheduledMs + 1500) {
          // User let rest extend past schedule (>1.5s tolerance for timer drift).
          emitAnalyticsEvent('rest_extended', null, {
            scheduled_ms: Math.round(scheduledMs),
            actual_ms: Math.round(actualMs),
          });
        }
      } else {
        // Exercise timer completed — mark as completed.
        if (!analyticsCompletedSlides[currentIndex]) {
          analyticsCompletedSlides[currentIndex] = true;
          var viewedAtEx = analyticsSlideViewedAt[currentIndex];
          var watchedMs = viewedAtEx ? Date.now() - viewedAtEx : 0;
          emitAnalyticsEvent('exercise_completed', completingSlide.id, {
            watched_ms: Math.round(watchedMs),
            threshold_met: true,
          });
        }
      }
    }
  }

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

  // -- Wave 17 analytics: pause_tapped --
  if (analyticsConsented === true) {
    var activeSlide = slides[currentIndex];
    var viewedAt = analyticsSlideViewedAt[currentIndex];
    var elapsedMs = viewedAt ? Date.now() - viewedAt : 0;
    emitAnalyticsEvent('pause_tapped', activeSlide ? activeSlide.id : null, {
      elapsed_ms: Math.round(elapsedMs),
    });
  }
  // Track when the pause started so resume can compute pause_duration_ms.
  pauseStartedAt = Date.now();

  isTimerRunning = false;
  clearWorkoutTimer();
  // Keep the video in sync so it doesn't keep playing while the timer is paused.
  const currentVideo = getActiveVideoForSlide(currentIndex);
  if (currentVideo && !currentVideo.paused) {
    currentVideo.pause();
  }
  updatePlayPauseToggle();
  updateRestCountdownOverlay();
  updateBreatherOverlay();
  // ETA clock keeps running in the background — remaining stays static,
  // finish-time drifts forward. Nudge once to reflect immediately.
  updateTimelineBar();
}

/**
 * Resume a paused timer
 */
function resumeTimer() {
  if (isTimerRunning) return;

  // -- Wave 17 analytics: resume_tapped --
  if (analyticsConsented === true) {
    var pauseDur = pauseStartedAt ? Date.now() - pauseStartedAt : 0;
    var activeSlide = slides[currentIndex];
    emitAnalyticsEvent('resume_tapped', activeSlide ? activeSlide.id : null, {
      pause_duration_ms: Math.round(pauseDur),
    });
  }
  pauseStartedAt = null;

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
  updatePlayPauseToggle();
  updateRestCountdownOverlay();
  updateBreatherOverlay();
  updateTimelineBar();
}

/**
 * Item 7: single mode-aware tap handler for the media area.
 * Prep → skip prep. Running → pause. Paused → resume.
 *
 * Bail when the user just swiped, so the synthetic click that follows a
 * touchend doesn't pause/resume by accident.
 */
function handleMediaTap(e) {
  // Wave 42 — the inline mute button was retired in favour of the gear
  // panel. Mute is now per-exercise via clientOverrides.
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
  updatePlayPauseToggle();
}

/**
 * Wave 42 — apply per-exercise effective mute state to every live
 * <video> element. The mute speaker icon was retired (gear panel only);
 * this function is called from startWorkout() (inside a user gesture so
 * Safari allows unmuting) and any time a mute override changes via the
 * gear panel.
 */
function applyMuteStateToAllVideos() {
  if (!$cardTrack) return;
  const videos = $cardTrack.querySelectorAll('video[id^="video-"]');
  videos.forEach((video) => {
    const card = video.closest('.exercise-card');
    if (!card) return;
    const idx = Number(card.getAttribute('data-index'));
    if (!Number.isFinite(idx)) return;
    const slide = slides[idx];
    if (!slide) return;
    // Crossfade slot B stays muted always — only the active slot reflects
    // the effective mute state. This matches the legacy behaviour where
    // only one slot ever played audio.
    if (video.getAttribute('data-loop-slot') === 'b') {
      video.muted = true;
      return;
    }
    video.muted = !!getEffective(slide, 'muted');
  });
}

// ============================================================
// Wave 42 — Consolidated gear panel (per-exercise client overrides)
// ============================================================
//
// Replaces the legacy three-control split (mute speaker, segmented
// treatment control, gear-popover Body Focus toggle) with a single
// gear panel exposing all three as per-exercise overrides on top of
// the practitioner's per-exercise defaults.
//
// State lives in `clientOverrides` (defined near the top of this file).
// The resolver getEffective(exercise, prop) is the single source of
// truth for muted / treatment / bodyFocus — every renderer + every
// <video> sync goes through it.

const $btnSettings = document.getElementById('btn-settings');
const $settingsPopover = document.getElementById('settings-popover');
const $resetOverridesBtn = document.getElementById('reset-overrides-btn');

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

/** Open / close the settings popover. */
function setSettingsPopoverOpen(open) {
  if (!$settingsPopover || !$btnSettings) return;
  if (open) {
    $settingsPopover.hidden = false;
    // Repaint state when opening so the panel reflects the active slide.
    paintGearPanel();
    requestAnimationFrame(() => {
      $settingsPopover.setAttribute('data-open', 'true');
    });
    $btnSettings.setAttribute('aria-expanded', 'true');
  } else {
    $settingsPopover.setAttribute('data-open', 'false');
    $btnSettings.setAttribute('aria-expanded', 'false');
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
    // Always update data-src so lazy-loading picks up the new URL.
    videoEl.setAttribute('data-src', nextUrl);
    const prevTreatment = videoEl.getAttribute('data-treatment') || 'line';
    videoEl.setAttribute('data-treatment', slideT);
    videoEl.classList.toggle('is-grayscale', slideT === 'bw');

    const currentAttr = videoEl.getAttribute('src');
    if (!currentAttr) return; // not lazy-loaded yet

    // Compare file PATHS (strip ?token= signed URL params). If the
    // path is identical, the treatment change is CSS-only (e.g. B&W ↔
    // Original = same raw file, just grayscale filter toggle). If paths
    // differ, the actual video file changed (line ↔ raw, segmented ↔
    // non-segmented) and we need a src swap.
    var currentPath = currentAttr.split('?')[0];
    var nextPath = nextUrl.split('?')[0];
    if (currentPath === nextPath) return; // same file, CSS handles it

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

  // Wave 22 — photo slides need the same treatment-flip handling. Wave 28
  // wrapped photos in a `.media-rotation-wrap` div so the rotation pattern
  // matches videos; the previous `.card-media > img` selector silently
  // returned zero matches once that wrapper landed, leaving photo `src`
  // attributes stuck on whatever buildCard() rendered initially (typically
  // line drawing). Use the descendant path through the rotation wrapper.
  // Hot-swap is trivial: change src + toggle the `.is-grayscale` class.
  // Single frame, no playback state to preserve.
  const photoImgs = $cardTrack.querySelectorAll('.card-media .media-rotation-wrap > img');
  photoImgs.forEach((imgEl) => {
    const card = imgEl.closest('.exercise-card');
    if (!card) return;
    const idx = Number(card.getAttribute('data-index'));
    if (!Number.isFinite(idx)) return;
    const slide = slides[idx];
    if (!slide || slide.media_type !== 'photo') return;
    const slideT = slideTreatment(slide);
    const nextUrl = resolveTreatmentUrl(slide, slideT);
    if (!nextUrl) return;
    imgEl.setAttribute('data-treatment', slideT);
    imgEl.classList.toggle('is-grayscale', slideT === 'bw');
    const currentAttr = imgEl.getAttribute('src');
    if (currentAttr !== nextUrl) imgEl.setAttribute('src', nextUrl);
  });
}

// ----------------------------------------------------------------
// Wave 42 — Gear panel painters + handlers
// ----------------------------------------------------------------

/** SVG markup for the mute/body-focus state icons. */
const ICON_AUDIO_ON = '<polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5"/><path d="M15.54 8.46a5 5 0 0 1 0 7.07"/><path d="M19.07 4.93a10 10 0 0 1 0 14.14"/>';
const ICON_AUDIO_OFF = '<polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5"/><line x1="23" y1="9" x2="17" y2="15"/><line x1="17" y1="9" x2="23" y2="15"/>';
const ICON_BODY_FOCUS_ON = '<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="3" fill="currentColor"/>';
const ICON_BODY_FOCUS_OFF = '<circle cx="12" cy="12" r="9"/>';

/**
 * Repaint every row in the gear panel from `clientOverrides` + the
 * active slide's practitioner defaults. Called on open and after any
 * mutation. No-ops when the panel isn't in the DOM.
 */
function paintGearPanel() {
  if (!$settingsPopover) return;
  const slide = slides[currentIndex];

  // Mute row
  const muteBtn = $settingsPopover.querySelector('.settings-row-btn[data-prop="muted"]');
  if (muteBtn) {
    const muted = !!getEffective(slide, 'muted');
    const overridden = !!(slide && clientOverrides[slide.id] && Object.prototype.hasOwnProperty.call(clientOverrides[slide.id], 'muted'));
    muteBtn.classList.toggle('is-overridden', overridden);
    muteBtn.classList.toggle('is-on', !muted);
    muteBtn.setAttribute('aria-pressed', muted ? 'false' : 'true');
    muteBtn.setAttribute('aria-label', muted ? 'Unmute audio' : 'Mute audio');
    const iconHost = muteBtn.querySelector('[data-state-icon]');
    if (iconHost) {
      iconHost.innerHTML = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${muted ? ICON_AUDIO_OFF : ICON_AUDIO_ON}</svg>`;
    }
  }

  // Treatment pills
  const treatmentRow = $settingsPopover.querySelector('.settings-row-segmented[data-prop="treatment"]');
  if (treatmentRow) {
    const effective = getEffective(slide, 'treatment') || 'line';
    const overridden = !!(slide && clientOverrides[slide.id] && Object.prototype.hasOwnProperty.call(clientOverrides[slide.id], 'treatment'));
    treatmentRow.classList.toggle('is-overridden', overridden);
    const pills = treatmentRow.querySelectorAll('.treatment-pills > button');
    pills.forEach((pill) => {
      const v = pill.getAttribute('data-value');
      let disabled = false;
      if (v === 'bw' && !planHasGrayscaleConsent) disabled = true;
      if (v === 'original' && !planHasOriginalConsent) disabled = true;
      pill.classList.toggle('is-disabled', disabled);
      pill.setAttribute('aria-disabled', disabled ? 'true' : 'false');
      if (disabled) {
        pill.setAttribute('title', "Your practitioner hasn't enabled this format");
      } else {
        pill.removeAttribute('title');
      }
      const active = !disabled && effective === v;
      pill.classList.toggle('is-active', active);
      pill.classList.toggle('is-overridden', active && overridden);
      pill.setAttribute('aria-checked', active ? 'true' : 'false');
    });
  }

  // Body focus row
  const bfBtn = $settingsPopover.querySelector('.settings-row-btn[data-prop="bodyFocus"]');
  if (bfBtn) {
    const slideT = slide && slide.media_type === 'video' ? slideTreatment(slide) : 'line';
    const bfDisabled = slideT === 'line';
    const bfOn = !!getEffective(slide, 'bodyFocus');
    const overridden = !!(slide && clientOverrides[slide.id] && Object.prototype.hasOwnProperty.call(clientOverrides[slide.id], 'bodyFocus'));
    bfBtn.classList.toggle('is-disabled', bfDisabled);
    bfBtn.classList.toggle('is-overridden', overridden && !bfDisabled);
    bfBtn.classList.toggle('is-on', bfOn);
    bfBtn.disabled = bfDisabled;
    bfBtn.setAttribute('aria-pressed', bfOn ? 'true' : 'false');
    bfBtn.setAttribute('aria-label', bfOn ? 'Body focus on' : 'Body focus off');
    if (bfDisabled) {
      bfBtn.setAttribute('title', 'Body focus applies to colour playback only');
    } else {
      bfBtn.removeAttribute('title');
    }
    const iconHost = bfBtn.querySelector('[data-state-icon]');
    if (iconHost) {
      iconHost.innerHTML = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${bfOn ? ICON_BODY_FOCUS_ON : ICON_BODY_FOCUS_OFF}</svg>`;
    }
  }

  // Reset button
  if ($resetOverridesBtn) {
    const any = hasAnyOverrides();
    $resetOverridesBtn.classList.toggle('is-empty', !any);
    $resetOverridesBtn.disabled = !any;
  }
}

/**
 * Mute toggle handler — flips the per-exercise mute override on the
 * active slide and re-applies muted state to every <video>.
 */
function onGearMuteClick() {
  const slide = slides[currentIndex];
  if (!slide) return;
  const currentEffective = !!getEffective(slide, 'muted');
  const next = !currentEffective;
  const def = practitionerDefaultFor(slide, 'muted');
  setOverride(slide.id, 'muted', next, def);
  applyMuteStateToAllVideos();
  paintGearPanel();
}

/**
 * Treatment pill handler — sets the per-exercise treatment override on
 * the active slide and rebinds video/photo sources.
 */
function onGearTreatmentClick(value) {
  const slide = slides[currentIndex];
  if (!slide) return;
  if (TREATMENT_VALUES.indexOf(value) === -1) return;
  // Block unconsented treatments at the click layer (the pill is also
  // visually disabled, but defence in depth).
  if (value === 'bw' && !planHasGrayscaleConsent) return;
  if (value === 'original' && !planHasOriginalConsent) return;

  const previousEffective = getEffective(slide, 'treatment') || 'line';

  // Wave 17 analytics — emit on actual treatment flips.
  if (analyticsConsented === true && previousEffective !== value) {
    const fromWire = previousEffective === 'bw' ? 'grayscale' : previousEffective;
    const toWire = value === 'bw' ? 'grayscale' : value;
    emitAnalyticsEvent('treatment_switched', slide.id, { from: fromWire, to: toWire });
    // Lobby PR 4 — also emit `treatment_changed` with `source: 'gear'`
    // so the lobby's `source: 'lobby'` events sit on the same event
    // channel for downstream analytics. Existing `treatment_switched`
    // remains for backward-compat consumers.
    emitAnalyticsEvent('treatment_changed', slide.id, {
      from: fromWire, to: toWire, source: 'gear',
    });
  }

  const def = practitionerDefaultFor(slide, 'treatment');
  setOverride(slide.id, 'treatment', value, def);
  rebindVideoSources();
  paintGearPanel();
}

/**
 * Body focus toggle — flips the per-exercise body-focus override on
 * the active slide and rebinds video sources (segmented vs. raw file
 * differ at the URL level).
 */
function onGearBodyFocusClick() {
  const slide = slides[currentIndex];
  if (!slide) return;
  const slideT = slide.media_type === 'video' ? slideTreatment(slide) : 'line';
  if (slideT === 'line') return; // disabled state guard
  const next = !getEffective(slide, 'bodyFocus');
  const def = practitionerDefaultFor(slide, 'bodyFocus');
  setOverride(slide.id, 'bodyFocus', next, def);
  rebindVideoSources();
  paintGearPanel();
}

/** Reset button — drop every override for the active plan. */
function onGearResetClick() {
  const planId = (plan && plan.id) || getPlanIdFromURL();
  clearAllOverrides(planId);
  applyMuteStateToAllVideos();
  rebindVideoSources();
  paintGearPanel();
}

/**
 * Drive the right-edge play/pause toggle (#btn-playpause). Glyph
 * semantics = "what is playing right now":
 *   Workout running / prep / preview → PAUSE icon (tap pauses).
 *   Workout paused mid-set           → PLAY icon (tap resumes).
 * The button is hidden outside workout mode — the centered tap-to-pause
 * still handles preview-state interactions on the media area itself.
 */
function updatePlayPauseToggle() {
  if (!$btnPlayPause) return;
  // Hide outside workout mode; the start-workout button is the only
  // playback affordance pre-workout.
  if (isWorkoutMode) $btnPlayPause.removeAttribute('hidden');
  else { $btnPlayPause.setAttribute('hidden', ''); return; }
  const showPlayIcon = !isPrepPhase && !isTimerRunning;
  // setAttribute/removeAttribute rather than `.hidden = bool` —
  // SVGElement's hidden IDL reflection is inconsistent across browsers,
  // so the content attribute (which the `[hidden]` selector matches)
  // can end up out of sync.
  toggleHiddenAttr($btnPlayPauseIconPlay, !showPlayIcon);
  toggleHiddenAttr($btnPlayPauseIconPause, showPlayIcon);
  $btnPlayPause.setAttribute('aria-pressed', showPlayIcon ? 'true' : 'false');
  $btnPlayPause.setAttribute(
    'aria-label',
    showPlayIcon ? 'Resume workout' : 'Pause workout'
  );
}

function toggleHiddenAttr(el, hide) {
  if (!el) return;
  if (hide) el.setAttribute('hidden', '');
  else el.removeAttribute('hidden');
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
 * Wave 21 — render the vertical rep-block stack on the LEFT edge of
 * the video. Replaces the old horizontal segmented bar.
 *
 * Layout (bottom-up):
 *   Set 1 → reps fill upward → trailing rest block
 *   Set 2 → reps fill upward → trailing rest block
 *   …
 *   Set N → reps fill upward → trailing rest block (the "you're done,
 *           breathe" cue before the slide advances; owned by
 *           advanceSetPhase()).
 *
 * Skeleton rebuild — full innerHTML swap is cheap (tens of children
 * max) and keeps state derivation simple. Section heights are weighted
 * by `--rep-stack-section-grow` (rep count) so denser sets get more
 * vertical space proportionally; rest blocks are fixed-height.
 *
 * Per-rep paint lives in paintActiveRepBlock() (driven by
 * handleLoopBoundary). Rest fills are time-based via paintRestFill()
 * called from the 1Hz onTimerTick().
 *
 * Hidden when:
 *   * rest slides (rest slide already gets #rest-countdown-overlay)
 *   * photos
 *   * single-set with no breather (nothing meaningful to show)
 *   * legacy slides with reps null/0 (cleanest fallback per Carl —
 *     no fake-block fabrication)
 */
function updateRepStack() {
  if (!$repStack || !$repStackColumn || !$repStackLabels) return;
  const slide = slides[currentIndex];

  // Wave 41 — slide.sets[] is the source of truth. Standalone slides
  // play every authored set; circuit slides resolve to one set per
  // round (handled in playSetsForSlide).
  const playSets = slide && slide.media_type !== 'rest'
    ? playSetsForSlide(slide)
    : [];
  const totalRepsAll = playSets.reduce((acc, s) => acc + (s.reps || 0), 0);

  const eligible = !!slide
    && slide.media_type !== 'rest'
    && playSets.length > 0
    && totalRepsAll > 0
    && !(playSets.length === 1 && playSets[0].reps === 1);
  $repStack.hidden = !eligible;
  // Carl 2026-04-24: toggle a class on the card-viewport so CSS can
  // shift the prev chevron out of the stack's tap zone. JS-driven
  // (instead of `:has()`) for cross-version Safari reliability.
  if ($cardViewport) {
    $cardViewport.classList.toggle('has-rep-stack', eligible);
  }
  if (!eligible) {
    $repStackColumn.innerHTML = '';
    $repStackLabels.innerHTML = '';
    $repStack.removeAttribute('data-stack-key');
    return;
  }

  // Skeleton key — encode the per-set shape so a structural change
  // (added/removed set, weight change, breather toggle) triggers a
  // rebuild. Same-shape reruns hit the fast path and just repaint.
  const setSig = playSets
    .map((s) => `${s.reps}-${s.hold_seconds}-${s.weight_kg ?? 'BW'}-${s.breather_seconds_after}`)
    .join(',');
  const key = `${currentIndex}|${setSig}`;
  const oldKey = $repStack.getAttribute('data-stack-key');
  if (oldKey === key) {
    paintActiveRepBlock();
    paintRestFill();
    return;
  }

  // At slide change, drain the previous slide's filled blocks
  // top-to-bottom in a wave (not all at once). Bottom-up flex layout
  // means DOM index 0 is the bottom; for visual top-first drain we
  // assign the longest delay to index 0.
  const oldIdx = oldKey ? parseInt(oldKey.split('|')[0], 10) : null;
  const isSlideChange = oldKey !== null && oldIdx !== currentIndex;
  const DRAIN_BLOCK_MS = 200;
  const DRAIN_TOTAL_MS = 600;
  if (isSlideChange && !$repStack.dataset.draining) {
    $repStack.dataset.draining = 'true';
    const fills = Array.from(
      $repStackColumn.querySelectorAll('.rep-stack-block-fill')
    );
    const total = fills.length;
    const stagger = total > 1
      ? Math.max(0, Math.floor((DRAIN_TOTAL_MS - DRAIN_BLOCK_MS) / (total - 1)))
      : 0;
    fills.forEach((f, i) => {
      const delay = (total - 1 - i) * stagger;
      f.style.transition = `height ${DRAIN_BLOCK_MS}ms ease-out ${delay}ms`;
    });
    $repStackColumn.classList.add('is-draining');
    // Track the timer so a second slide-change mid-drain can cancel
    // the stale callback before it touches the new structure.
    if (drainTimer) clearTimeout(drainTimer);
    drainTimer = setTimeout(() => {
      drainTimer = null;
      delete $repStack.dataset.draining;
      $repStackColumn.classList.remove('is-draining');
      fills.forEach((f) => { f.style.transition = ''; });
      $repStack.removeAttribute('data-stack-key');
      updateRepStack();
    }, DRAIN_TOTAL_MS);
    return;
  }
  if ($repStack.dataset.draining) return;
  $repStack.setAttribute('data-stack-key', key);

  // Wave 41 — interleave per-set + per-set breather. The trailing
  // rest after the FINAL set has an empty aside (2026-05-04 — Carl
  // dropped the green "End of exercise" badge that used to live
  // there); non-final rests show a forward-look weight chip.
  // Bug fix 2026-05-03 (A): the LAST set's trailing rest block was
  // conditional on `breather_seconds_after > 0`, so a set with zero
  // breather (common for the final set) silently dropped its R block.
  // The last set ALWAYS gets a trailing rest section (CLAUDE.md:
  // "Trailing rest after
  // EVERY set, incl. last"); middle sets stay conditional since a
  // zero-breather middle slot is meaningfully empty.
  const sections = [];
  for (let i = 0; i < playSets.length; i++) {
    const set = playSets[i];
    const isLast = i === playSets.length - 1;
    sections.push({
      kind: 'set',
      index: i,
      reps: set.reps,
      hold_seconds: set.hold_seconds,
      weight_kg: set.weight_kg,
      isFirst: i === 0,
      prevWeight: i > 0 ? playSets[i - 1].weight_kg : null,
    });
    if (set.breather_seconds_after > 0 || isLast) {
      sections.push({
        kind: 'rest',
        index: i,
        total: set.breather_seconds_after || 0,
        nextWeight: isLast ? null : playSets[i + 1].weight_kg,
        prevWeight: set.weight_kg,
        isFinal: isLast,
      });
    }
  }

  // Column DOM — sections stack bottom-up via flex column-reverse.
  // `--rep-stack-section-grow` weights each section by its rep count
  // so dense sets get more vertical space; rest sections use a fixed
  // height (set in CSS via flex-basis), grow=0 keeps them compact.
  const colHtml = sections.map((sec) => {
    if (sec.kind === 'set') {
      const blocks = [];
      for (let r = 0; r < sec.reps; r++) {
        blocks.push(`<div class="rep-stack-block rep-stack-block--rep" data-rep-index="${r}">
          <div class="rep-stack-block-fill"></div>
        </div>`);
      }
      // Bug fix 2026-05-03 (D): combine weight + hold into a SINGLE
      // uniform pill per set. Separate weight chip + hold label
      // produced different widths per set; the unified pill gets a
      // fixed min-width / min-height so a "5 kg" set matches a
      // "120 kg · 12 s" set visually. Hold suffix folds in via " · ".
      const chip = renderWeightChipHtml({
        weightKg: sec.weight_kg,
        urgent: sec.isFirst || (sec.weight_kg !== sec.prevWeight),
        leadGlyph: sec.isFirst
          ? (sec.weight_kg != null ? 'bolt' : null)
          : (sec.weight_kg !== sec.prevWeight && sec.weight_kg != null ? 'bolt' : null),
        holdSeconds: sec.hold_seconds,
      });
      return `<div class="rep-stack-section rep-stack-section--set"
                   data-set-index="${sec.index}"
                   style="--rep-stack-section-grow: ${sec.reps};">
                <div class="rep-stack-section-blocks">${blocks.join('')}</div>
                <div class="rep-stack-section-aside">${chip}</div>
              </div>`;
    }
    // Rest section — sage divider plus a forward-look chip (next
    // set's weight). Non-final rests show a forward-look weight chip;
    // the FINAL rest now shows nothing (no aside) — Carl 2026-05-04
    // dropped the green "End of exercise" badge ("serves no purpose").
    // The final rest section keeps its sage rest block + the breather
    // chip that lives in the matrix overlay.
    const aside = sec.isFinal
      ? '' // 2026-05-04 — End-of-exercise badge retired.
      : renderWeightChipHtml({
          weightKg: sec.nextWeight,
          urgent: sec.nextWeight !== sec.prevWeight,
          leadGlyph: sec.nextWeight !== sec.prevWeight && sec.nextWeight != null ? 'bolt' : null,
        });
    return `<div class="rep-stack-section rep-stack-section--rest"
                 data-rest-index="${sec.index}"
                 style="flex: 1 1 0;">
              <div class="rep-stack-section-blocks">
                <div class="rep-stack-block rep-stack-block--rest" data-rest-index="${sec.index}">
                  <div class="rep-stack-block-fill"></div>
                </div>
              </div>
              <div class="rep-stack-section-aside">${aside}</div>
            </div>`;
  }).join('');
  $repStackColumn.innerHTML = colHtml;

  // Labels gutter — same section count, mirroring the column's
  // bottom-up order via column-reverse.
  const labelHtml = sections.map((sec) => {
    if (sec.kind === 'set') {
      return `<div class="rep-stack-labels-section rep-stack-labels-section--set"
                   style="flex: ${sec.reps} 1 0;">S${sec.index + 1}</div>`;
    }
    return `<div class="rep-stack-labels-section rep-stack-labels-section--rest"
                 style="flex: 1 1 0; margin-top: 2px;">R</div>`;
  }).join('');
  $repStackLabels.innerHTML = labelHtml;

  // Apply current state — fills + active marker for the running phase.
  paintActiveRepBlock();
  paintRestFill();
}

/**
 * Wave 41 — render the floating weight chip alongside a set group or
 * rest divider. Bodyweight (null kg) renders as a muted "Bodyweight"
 * chip with no urgent styling. The `urgent` flag adds the brand-tint
 * background; `leadGlyph` adds a coral bolt before the value.
 *
 * 2026-05-04: chip is now CSS-rotated to a vertical "book-spine"
 * orientation when it sits in a `.rep-stack-section-aside` slot
 * (writing-mode: vertical-rl + rotate(180deg) — same pattern as the
 * mobile _MediaViewer treatment pill). The HTML output is unchanged;
 * only the CSS scoping `.rep-stack-section-aside .weight-chip` flips
 * orientation. Document order remains glyph → label → hold-suffix so
 * after the visual flip, bottom-up reads as bolt → "120" → "kg" →
 * "· 12 s".
 */
function renderWeightChipHtml({ weightKg, urgent, leadGlyph, holdSeconds }) {
  const isBodyweight = weightKg == null;
  const classes = ['weight-chip'];
  if (isBodyweight) classes.push('weight-chip--bodyweight');
  if (urgent && !isBodyweight) classes.push('weight-chip--up');
  const glyph = leadGlyph === 'bolt' ? '<span class="weight-chip-bolt" aria-hidden="true">⚡</span>' : '';
  const baseLabel = isBodyweight ? 'Bodyweight' : formatWeightKg(weightKg);
  // Bug fix 2026-05-03 (D): optional hold suffix folds into the same
  // pill so per-set pills render as a single uniform unit.
  const holdSuffix = holdSeconds > 0 ? ` · ${holdSeconds} s` : '';
  return `<span class="${classes.join(' ')}">${glyph}${baseLabel}${holdSuffix}</span>`;
}

/**
 * Wave 41 — format a kg value: integer like "15 kg", non-integer
 * rounded to one decimal like "12.5 kg".
 */
function formatWeightKg(kg) {
  if (kg == null) return 'Bodyweight';
  const n = Number(kg);
  if (!Number.isFinite(n)) return 'Bodyweight';
  if (Number.isInteger(n)) return `${n} kg`;
  // One decimal — strip a trailing .0 if Number.isInteger missed it
  // (e.g. 12.5 → "12.5", 15.0 → "15") to keep the typography tight.
  const rounded = Math.round(n * 10) / 10;
  if (Number.isInteger(rounded)) return `${rounded} kg`;
  return `${rounded.toFixed(1)} kg`;
}

/**
 * Wave 21 — paint the rest-block fill bottom-up over its duration.
 * Time-based (linear over `interSetRestForSlide` seconds). Driven by
 * the 1Hz onTimerTick while setPhase === 'rest'. Marks every prior
 * rest as filled so back-set positions are visually accurate.
 */
function paintRestFill() {
  if (!$repStackColumn) return;
  const slide = slides[currentIndex];
  if (!slide || slide.media_type === 'rest') return;
  const restBlocks = $repStackColumn.querySelectorAll('.rep-stack-block--rest');
  if (!restBlocks.length) return;
  // Wave 41 — each rest block reads its OWN duration off the
  // matching set's breather_seconds_after. Prior rests show as fully
  // filled; the active rest fills proportionally; future rests stay
  // empty.
  const playSets = playSetsForSlide(slide);
  restBlocks.forEach((block) => {
    const restIdx = parseInt(block.getAttribute('data-rest-index'), 10);
    const fill = block.querySelector('.rep-stack-block-fill');
    if (Number.isNaN(restIdx) || !fill) return;
    const setForBlock = playSets[restIdx];
    const totalForBlock = Math.max(1, (setForBlock && setForBlock.breather_seconds_after) || 1);
    if (restIdx < currentSetIndex) {
      // A prior set's rest — fully done.
      block.classList.add('rep-stack-block--filled');
      block.classList.remove('rep-stack-block--active');
      fill.style.height = '100%';
    } else if (restIdx === currentSetIndex && setPhase === 'rest' && isWorkoutMode) {
      // Currently filling.
      block.classList.add('rep-stack-block--active');
      block.classList.remove('rep-stack-block--filled');
      const remaining = Math.max(0, setPhaseRemaining);
      const pct = Math.max(0, Math.min(100, ((totalForBlock - remaining) / totalForBlock) * 100));
      fill.style.height = pct.toFixed(1) + '%';
    } else {
      block.classList.remove('rep-stack-block--filled');
      block.classList.remove('rep-stack-block--active');
      fill.style.height = '0%';
    }
  });
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
    let result;
    try { result = req.call(el); } catch (_) { result = null; }
    // iOS Safari 16.4+ supports Element.requestFullscreen on arbitrary
    // elements. Older Safari throws or returns undefined; webkit-prefixed
    // returned undefined synchronously. Use the Promise to fall back to
    // faux when the real API rejects (older iOS, restricted contexts).
    if (result && typeof result.then === 'function') {
      result.catch(() => engageFauxFullscreen());
      return;
    }
    // No-Promise path: defer one frame and check whether the API engaged.
    setTimeout(() => {
      if (!document.fullscreenElement &&
          !document.webkitFullscreenElement &&
          !fauxFullscreenActive) {
        engageFauxFullscreen();
      }
    }, 200);
    return;
  }
  engageFauxFullscreen();
}

/**
 * Landscape pre-workout Maximise pill is gated by body classes
 * `is-workout-mode` and `is-fullscreen` via CSS. This helper exists so
 * call sites that mutate either flag refresh both classes in one place.
 * Visibility itself is CSS-driven — no JS toggle needed beyond the
 * body class state.
 */
function updateLandscapeMaximisePillVisibility() {
  document.body.classList.toggle('is-workout-mode', isWorkoutMode);
}

function engageFauxFullscreen() {
  if (fauxFullscreenActive) return;
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

  updatePlayPauseToggle();
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

  // -- Wave 17 analytics: plan_completed --
  if (analyticsConsented === true) {
    var completedCount = 0;
    var skippedCount = 0;
    for (var i = 0; i < slides.length; i++) {
      if (slides[i].media_type === 'rest') continue;
      if (analyticsCompletedSlides[i]) completedCount++;
      else skippedCount++;
    }
    emitAnalyticsEvent('plan_completed', null, {
      total_elapsed_ms: elapsedMs,
      exercises_completed: completedCount,
      exercises_skipped: skippedCount,
    });
  }

  // -- Wave 17: inject the completion CTA into the workout-complete overlay. --
  renderCompletionCTA();

  // Flip the ETA to "Done" end-state.
  workoutCompleteFlag = true;
  updateTimelineBar();
}

/**
 * Wave 17 — render the analytics completion CTA in the workout-complete
 * overlay. Links to the transparency page and offers an Exit button.
 */
function renderCompletionCTA() {
  // Only show if analytics was active and consent was granted.
  if (!analyticsSessionId || analyticsConsented !== true) return;
  // Don't double-inject.
  if (document.getElementById('analytics-completion-cta')) return;

  var planId = (plan && plan.id) || getPlanIdFromURL();
  var cta = document.createElement('div');
  cta.id = 'analytics-completion-cta';
  cta.className = 'analytics-completion-cta';
  cta.innerHTML =
    '<a class="analytics-cta-link" href="/what-we-share' +
    (planId ? '?p=' + encodeURIComponent(planId) : '') +
    '" target="_blank" rel="noopener">See what\'s been shared with ' +
    escapeHTML(analyticsTrainerName) + ' \u2192</a>';
  // Insert after the existing workout-complete-time element.
  if ($workoutTotalTime && $workoutTotalTime.parentNode) {
    $workoutTotalTime.parentNode.insertBefore(cta, $workoutCloseBtn);
  }
}

/**
 * Close workout mode and return to browse
 */
function exitWorkout() {
  isWorkoutMode = false;
  isTimerRunning = false;
  isPrepPhase = false;
  document.body.classList.remove('is-workout-mode');
  updateLandscapeMaximisePillVisibility();

  clearWorkoutTimer();
  clearPrepTimer();

  workoutStartTime = null;

  $workoutComplete.hidden = true;
  if ($workoutComplete) $workoutComplete.classList.remove('is-live');
  updatePlayPauseToggle();
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

/**
 * Tap a rep / rest block in the vertical stack to jump the workout
 * timer to that point. Mirror of clicking a matrix pill at the top.
 * Active only during workout mode + timer running.
 */
function _canJumpRepStack() {
  if (!isWorkoutMode || !isTimerRunning || isPrepPhase) return false;
  const slide = slides[currentIndex];
  if (!slide) return false;
  const playSets = playSetsForSlide(slide);
  if (!playSets.length) return false;
  const firstSet = playSets[0];
  // Wave 43 — for the "is there ANY playable time?" check, the
  // last-set flag matches "single-set slide" so end_of_exercise hold
  // contributes when present. Falls back to default false otherwise.
  return firstSet.reps > 0
    && calculatePerSetSeconds(firstSet, slide, playSets.length <= 1) > 0;
}

function _repaintAfterJump() {
  updateRepStack();
  updateBreatherOverlay();
  updateRestCountdownOverlay();
  updateProgressMatrix();
  updateTimelineBar();
  updateActiveSlideHeader();
}

/**
 * Wave 41 — sum the per-set durations from sets[0..setIdx-1]. Each
 * set's per-set total already includes its own breather, so this is
 * just a cumulative scan with no extra rest math.
 */
function _cumulativeSecondsBeforeSet(slide, playSets, setIdx) {
  let sum = 0;
  for (let i = 0; i < setIdx && i < playSets.length; i++) {
    const isLast = i === playSets.length - 1;
    sum += calculatePerSetSeconds(playSets[i], slide, isLast);
  }
  return sum;
}

/** Jump to rep `repIdx` (0-based) of set `setIdx`. */
function jumpToRep(setIdx, repIdx) {
  if (!_canJumpRepStack()) return;
  const slide = slides[currentIndex];
  const playSets = playSetsForSlide(slide);
  if (setIdx < 0 || setIdx >= playSets.length) return;

  const targetSet = playSets[setIdx];
  const targetIsLast = setIdx >= playSets.length - 1;
  const targetPerSet = calculatePerSetSeconds(targetSet, slide, targetIsLast);
  const targetReps = Math.max(1, targetSet.reps || 1);
  const breatherForTarget = targetSet.breather_seconds_after || 0;
  // Physical (rep-fill) seconds within this set, minus baked-in breather.
  const physicalSet = Math.max(1, targetPerSet - breatherForTarget);
  // Bug fix 2026-05-04: round to integer at the source. (repIdx/targetReps)
  // * physicalSet is fractional whenever physicalSet doesn't divide evenly
  // by targetReps (e.g. 121s / 12 reps = 10.083). Without this floor,
  // setPhaseRemaining + remainingSeconds inherit the fraction and the
  // 1s decrement loop preserves it for the rest of the slide, leaking
  // 23:54.6666... into the matrix display.
  const elapsedInPhysical = Math.round((repIdx / targetReps) * physicalSet);

  currentSetIndex = setIdx;
  setPhase = 'set';
  // Wave 41 fix — setPhaseRemaining sizes the 'set' phase only (physical
  // window). Breather is counted by the subsequent 'rest' phase.
  setPhaseRemaining = Math.max(0, physicalSet - elapsedInPhysical);
  interSetRestForSlide = breatherForTarget;

  const elapsedTotal = _cumulativeSecondsBeforeSet(slide, playSets, setIdx) + elapsedInPhysical;
  remainingSeconds = Math.max(0, totalSeconds - elapsedTotal);
  resumeActiveVideoAfterBreather();
  _repaintAfterJump();
}

/** Jump to the breather following set `setIdx`. */
function jumpToRest(setIdx) {
  if (!_canJumpRepStack()) return;
  const slide = slides[currentIndex];
  const playSets = playSetsForSlide(slide);
  if (setIdx < 0 || setIdx >= playSets.length) return;

  const targetSet = playSets[setIdx];
  const targetIsLast = setIdx >= playSets.length - 1;
  const breatherForTarget = targetSet.breather_seconds_after || 0;
  const targetPerSet = calculatePerSetSeconds(targetSet, slide, targetIsLast);
  const physicalSet = Math.max(1, targetPerSet - breatherForTarget);

  currentSetIndex = setIdx;
  setPhase = 'rest';
  setPhaseRemaining = breatherForTarget;
  interSetRestForSlide = breatherForTarget;

  // Elapsed = everything before this set + this set's physical portion
  // (we're at the breather start, so reps just landed).
  const elapsedTotal = _cumulativeSecondsBeforeSet(slide, playSets, setIdx) + physicalSet;
  remainingSeconds = Math.max(0, totalSeconds - elapsedTotal);
  pauseActiveVideoForBreather();
  _repaintAfterJump();
}

async function init() {
  registerServiceWorker();

  // Wave 33 hotfix — flag the local-preview surface (mobile WebView)
  // so practitioner-only chrome (e.g. the landscape Maximise pill) can
  // be CSS-gated out. The pill is an iOS-Safari-chrome workaround for
  // live client viewers; rendering it inside the WebView wrapped by
  // Flutter mobile preview was leaking giant artwork into the canvas
  // when the WebView container hit the (orientation: landscape) +
  // (max-height: 540) media-query window.
  if (window.HomefitApi && window.HomefitApi.isLocalSurface()) {
    document.body.classList.add('is-local-preview');
  }

  // Discreet build marker in the footer — see PLAYER_VERSION at the
  // top of this file. Stamped pre-fetch so it's visible even on plan
  // load failure.
  const $versionEl = document.getElementById('footer-version');
  if ($versionEl) $versionEl.textContent = PLAYER_VERSION;

  // Delegated tap handler for the navigable rep stack. stopPropagation
  // prevents the tap from also toggling video pause/play.
  if ($repStackColumn) {
    $repStackColumn.addEventListener('click', (evt) => {
      const block = evt.target.closest('.rep-stack-block');
      if (!block) return;
      evt.stopPropagation();
      evt.preventDefault();
      if (block.classList.contains('rep-stack-block--rep')) {
        const section = block.closest('.rep-stack-section--set');
        if (!section) return;
        const setIdx = parseInt(section.getAttribute('data-set-index'), 10);
        const repIdx = parseInt(block.getAttribute('data-rep-index'), 10);
        if (Number.isNaN(setIdx) || Number.isNaN(repIdx)) return;
        emitAnalyticsEvent('exercise_navigation_jump', slides[currentIndex]?.id || null, {
          from_set: currentSetIndex,
          to_set: setIdx,
          to_rep: repIdx,
          method: 'rep_stack',
        });
        jumpToRep(setIdx, repIdx);
      } else if (block.classList.contains('rep-stack-block--rest')) {
        const restIdx = parseInt(block.getAttribute('data-rest-index'), 10);
        if (Number.isNaN(restIdx)) return;
        emitAnalyticsEvent('exercise_navigation_jump', slides[currentIndex]?.id || null, {
          from_set: currentSetIndex,
          to_set: restIdx,
          method: 'rep_stack_rest',
        });
        jumpToRest(restIdx);
      }
    });
  }

  const planId = getPlanIdFromURL();

  try {
    plan = await fetchPlan(planId);

    if (!plan || !plan.exercises || plan.exercises.length === 0) {
      throw new Error('Empty plan');
    }

    // Wave 33 — fire the engagement-analytics stamp once per session
    // start. Idempotently sets `plans.first_opened_at` (preserving any
    // prior value) + advances `plans.last_opened_at`. Skipped on the
    // local surface (mobile preview WebView) so the practitioner's
    // own rehearsal doesn't corrupt the signal.
    //
    // Fire-and-forget — no await; engagement is a side-channel and
    // must never block the player render path.
    window.HomefitApi.recordPlanOpened(plan.id);

    // Sort exercises by position
    plan.exercises.sort((a, b) => a.position - b.position);

    // Unroll circuits into flat slides array
    slides = unrollExercises(plan);
    // Reset per-slide loop bookkeeping — stale entries from a prior
    // plan would leak otherwise (no in-session plan switch today, but
    // future-proof + cheap).
    loopState.clear();

    // Wave 42 — load per-exercise client overrides for THIS plan and
    // compute the plan-wide consent rollup BEFORE the first render so
    // slideTreatment() has correct state when buildCard() resolves URLs.
    recomputePlanConsent();
    loadClientOverrides(plan && plan.id);
    // Defensive: drop any treatment override whose value points at an
    // unconsented treatment (consent could have been revoked since the
    // last visit). Persist the correction.
    let overridesDirty = false;
    for (const exId in clientOverrides) {
      if (!Object.prototype.hasOwnProperty.call(clientOverrides, exId)) continue;
      const entry = clientOverrides[exId];
      if (!entry) continue;
      if (entry.treatment === 'bw' && !planHasGrayscaleConsent) {
        delete entry.treatment;
        overridesDirty = true;
      } else if (entry.treatment === 'original' && !planHasOriginalConsent) {
        delete entry.treatment;
        overridesDirty = true;
      }
    }
    if (overridesDirty) saveClientOverrides(plan && plan.id);

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

    // Wave 20 — soft-trim playback clamp. Delegated listeners on the
    // viewport so newly-rendered <video> elements don't need their own
    // wire-up. `loadedmetadata` seeks into the trim window before the
    // first painted frame; `timeupdate` wraps the loop at the out-point.
    // The crossfade detector in `attachLoopListeners` reads the same
    // trim window so preroll fires at the trimmed end, not natural end.
    $cardViewport.addEventListener('loadedmetadata', onVideoLoadedMetadata, true);
    $cardViewport.addEventListener('timeupdate', onVideoTimeUpdate, true);
    // v79-hardening (HIGH 1): delegated error handler catches expired
    // signed URLs (403 → MediaError) and re-fetches plan data.
    $cardViewport.addEventListener('error', handleVideoError, true);
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

    // Landscape pre-workout Maximise pill — taps are a user gesture so
    // requestFullscreen succeeds on iOS Safari 16.4+; older Safari falls
    // back to faux fullscreen via the Promise-rejection path.
    if ($btnLandscapeMaximise) {
      $btnLandscapeMaximise.addEventListener('click', () => {
        if (!isFullscreenActive()) requestFullscreen();
      });
    }
    // Visibility is CSS-driven (body class + landscape media query),
    // but seed the body class once at startup for the initial paint.
    updateLandscapeMaximisePillVisibility();

    // Play/pause toggle — same dispatch as the centered tap-to-pause.
    // Hidden outside workout mode; click is a no-op there as a defence.
    if ($btnPlayPause) {
      $btnPlayPause.addEventListener('click', (e) => {
        e.stopPropagation();
        if (!isWorkoutMode) return;
        if (isPrepPhase) {
          finishPrepPhase();
        } else if (isTimerRunning) {
          pauseTimer();
        } else if (remainingSeconds > 0) {
          resumeTimer();
        }
        updatePlayPauseToggle();
      });
    }
    document.addEventListener('fullscreenchange', onFullscreenChange);
    document.addEventListener('webkitfullscreenchange', onFullscreenChange);

    // Wave 42 — Consolidated gear panel: per-exercise client overrides
    // for muted / treatment / bodyFocus. Single entry point; no global
    // chrome surfaces these controls anymore.
    if ($btnSettings && $settingsPopover) {
      paintGearPanel();

      $btnSettings.addEventListener('click', (e) => {
        e.stopPropagation();
        setSettingsPopoverOpen(!isSettingsPopoverOpen());
      });
      $settingsPopover.addEventListener('click', (e) => {
        e.stopPropagation();
      });

      const muteBtn = $settingsPopover.querySelector('.settings-row-btn[data-prop="muted"]');
      if (muteBtn) muteBtn.addEventListener('click', onGearMuteClick);

      const treatmentRow = $settingsPopover.querySelector('.settings-row-segmented[data-prop="treatment"]');
      if (treatmentRow) {
        treatmentRow.addEventListener('click', (e) => {
          const pill = e.target && e.target.closest ? e.target.closest('.treatment-pills > button') : null;
          if (!pill) return;
          if (pill.classList.contains('is-disabled')) return;
          const v = pill.getAttribute('data-value');
          onGearTreatmentClick(v);
        });
      }

      const bfBtn = $settingsPopover.querySelector('.settings-row-btn[data-prop="bodyFocus"]');
      if (bfBtn) bfBtn.addEventListener('click', onGearBodyFocusClick);

      if ($resetOverridesBtn) $resetOverridesBtn.addEventListener('click', onGearResetClick);

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
        if (Number.isFinite(idx) && idx !== currentIndex) {
          emitAnalyticsEvent('exercise_navigation_jump', null, {
            from_slide: currentIndex,
            to_slide: idx,
            method: 'pill',
          });
          jumpToSlide(idx);
        }
      });
      // Re-choose size tier on viewport resize — rebuild is cheap.
      // Wave 28: debounce ~150ms so a rapid portrait↔landscape rotation
      // (which fires resize multiple times as iOS Safari settles the new
      // visual viewport) doesn't thrash buildProgressMatrix(). The
      // post-debounce pass recomputes the size tier, rebuilds the matrix
      // if the tier changed, and restores the active-pill state without
      // a scroll animation (the matrix flex-fits, so there's no scroll
      // offset to preserve — we just want correct layout immediately).
      let matrixResizeTimer = null;
      window.addEventListener('resize', () => {
        if (matrixResizeTimer) clearTimeout(matrixResizeTimer);
        matrixResizeTimer = setTimeout(() => {
          matrixResizeTimer = null;
          const prev = matrixSizeTier;
          const blocks = buildMatrixBlocks();
          const nextTier = chooseMatrixSizeTier(countMatrixColumns(blocks), window.innerWidth);
          if (nextTier !== prev) {
            buildProgressMatrix();
            updateProgressMatrix();
          } else {
            updateProgressMatrix();
          }
        }, 150);
      });
    }

    // PR 4 — Lobby surface. The lobby is the pre-workout entry point: a
    // vertical menu of hero frames + sticky Start CTA. The deck (#app)
    // stays hidden underneath until Start is tapped. Autoplay + the
    // legacy in-deck "Start Workout" button stay suppressed while the
    // lobby owns the foreground.
    //
    // The lobby calls `window.HomefitLobbyHandoff.startWorkout()` to hand
    // off control. That handoff:
    //   1. unhides #app + autoPlayCurrentVideo()
    //   2. invokes startWorkout() (which fires its own state machine).
    // analytics workout_started is emitted by the LOBBY at Start tap (not
    // here on first prep frame any longer — re-anchored per spec).
    if (window.HomefitLobby && typeof window.HomefitLobby.showLobby === 'function') {
      // Expose the helpers the lobby needs. Frozen so lobby code can't
      // mutate app state through this surface — only read/call.
      window.HomefitLobbyHandoff = Object.freeze({
        calculateDuration: calculateDuration,
        sumTotalDurationSeconds: function () {
          let total = 0;
          for (let i = 0; i < slides.length; i++) total += calculateDuration(slides[i]);
          return total;
        },
        playSetsForSlide: playSetsForSlide,
        getExerciseRotationDeg: getExerciseRotationDeg,
        resolveTreatmentUrl: resolveTreatmentUrl,
        escapeHTML: escapeHTML,
        emitAnalyticsEvent: emitAnalyticsEvent,
        planHasGrayscaleConsent: function () { return planHasGrayscaleConsent; },
        planHasOriginalConsent: function () { return planHasOriginalConsent; },
        applyTreatmentOverrideToAllExercises: applyTreatmentOverrideToAllExercises,
        getDefaultTreatment: function () {
          // Pick the first exercise's effective treatment as the
          // global default. Falls back to 'line' for empty/rest-only
          // plans (impossible at this point but cheap defence).
          for (let i = 0; i < slides.length; i++) {
            const s = slides[i];
            if (s && s.media_type !== 'rest') {
              const t = getEffective(s, 'treatment');
              if (t === 'bw' && !planHasGrayscaleConsent) return 'line';
              if (t === 'original' && !planHasOriginalConsent) return 'line';
              return t || 'line';
            }
          }
          return 'line';
        },
        getPractitionerName: function () { return analyticsTrainerName; },
        rebindVideoSources: rebindVideoSources,
        startWorkout: function () {
          // Reveal the deck, autoplay, and let the legacy startWorkout
          // path take over (timer, fullscreen, prep countdown, etc.).
          if ($app) $app.hidden = false;
          autoPlayCurrentVideo();
          startWorkout();
        },
        reFetchPlan: async function () {
          // Re-fetch the plan after a self-grant so signed URLs for the
          // newly-granted treatment land in the cached state.
          const planId = (plan && plan.id) || getPlanIdFromURL();
          if (!planId) return null;
          const fresh = await fetchPlan(planId);
          if (!fresh) return null;
          plan = fresh;
          plan.exercises.sort((a, b) => a.position - b.position);
          slides = unrollExercises(plan);
          recomputePlanConsent();
          // Re-render the deck so post-handoff playback has fresh src.
          try { renderPlan(); } catch (_) { /* defer to first goTo */ }
          return { plan: plan, slides: slides };
        },
        // Build a matrix HTML string for the lobby — re-uses the deck's
        // pill builder shape but emits clickable <button>s and skips the
        // active-slide auto-fill (lobby is pre-workout).
        buildLobbyMatrix: function (slidesArg) {
          // Use the existing buildMatrixBlocks() output for circuit
          // grouping fidelity, but with simple flat pills.
          const blocks = (typeof buildMatrixBlocks === 'function') ? buildMatrixBlocks() : null;
          if (!blocks) {
            return slidesArg.map((s, i) => {
              const isRest = s.media_type === 'rest';
              return `<div class="pill size-medium${isRest ? ' is-rest' : ''}" data-slide="${i}" role="button" tabindex="0"><span class="pill-fill"></span></div>`;
            }).join('');
          }
          const pillHTML = (slideIdx) => {
            const slide = slidesArg[slideIdx];
            const isRest = slide && slide.media_type === 'rest';
            const dur = calculateDuration(slide);
            return `<div class="pill size-medium${isRest ? ' is-rest' : ''}" data-slide="${slideIdx}" data-estimate="${dur}" role="button" tabindex="0">
                      <span class="pill-fill"></span>
                    </div>`;
          };
          return blocks.map((block) => {
            if (block.kind === 'single') {
              const dur = calculateDuration(slidesArg[block.slideIndex]) || 1;
              return `<div class="matrix-col" style="--pill-weight: ${dur};">${pillHTML(block.slideIndex)}</div>`;
            }
            const { rounds, groupSize } = block;
            const firstRow = rounds[0] || [];
            const rowDurations = firstRow.map((idx) => calculateDuration(slidesArg[idx]) || 1);
            const circuitWeight = rowDurations.reduce((a, b) => a + b, 0) || 1;
            const rowTemplate = rowDurations.map((d) => `${d}fr`).join(' ');
            const roundsHTML = rounds.map((row, ri) => {
              const rowPills = row.map((slideIdx) => pillHTML(slideIdx)).join('');
              return `<div class="matrix-circuit-row" data-round="${ri + 1}" style="--row-template-fs: ${rowTemplate};">${rowPills}</div>`;
            }).join('');
            return `<div class="matrix-circuit" data-circuit="${block.circuitId}" style="--circuit-cols: ${groupSize}; --circuit-weight: ${circuitWeight};">${roundsHTML}</div>`;
          }).join('');
        },
      });

      // Hide #app until lobby hands off, suppress autoplay + the legacy
      // start-workout button.
      $startWorkoutBtn.hidden = true;
      if ($app) $app.hidden = true;

      window.HomefitLobby.showLobby({
        plan: plan,
        slides: slides,
        helpers: window.HomefitLobbyHandoff,
      });
    } else {
      // Lobby script unavailable — fall back to legacy entry. Safe
      // backstop for older bundle versions still in service worker.
      autoPlayCurrentVideo();
      $startWorkoutBtn.hidden = false;
    }

    // -- Wave 17: initialise analytics + wire close handler. --
    // Fire-and-forget — analytics init is async but must never block the
    // player render path or the Start Workout button.
    initAnalytics();
    installAnalyticsCloseHandler();

  } catch (err) {
    console.error('Failed to load plan:', err);
    $loading.hidden = true;

    // v79-hardening (MEDIUM 1): distinguish network errors from
    // empty-plan / not-found responses. TypeError is the standard
    // fetch network-error type; also catch any error that doesn't look
    // like our own 'Plan not found' / 'Empty plan' strings.
    const isNetwork = (
      err instanceof TypeError ||
      (err && err.message && !/plan not found|empty plan/i.test(err.message))
    );

    const $errorTitle = document.getElementById('error-title');
    const $errorText = document.getElementById('error-text');
    const $retryBtn = document.getElementById('error-retry-btn');

    if (isNetwork) {
      if ($errorTitle) $errorTitle.textContent = 'No internet connection';
      if ($errorText) $errorText.textContent =
        'Connect to Wi-Fi or mobile data and try again.';
      if ($retryBtn) {
        $retryBtn.hidden = false;
        $retryBtn.onclick = function () {
          $error.hidden = true;
          $loading.hidden = false;
          $loading.classList.remove('fade-out');
          init();
        };
      }
    } else {
      if ($errorTitle) $errorTitle.textContent = 'Plan not found';
      if ($errorText) $errorText.textContent =
        'This link may have expired or the plan may no longer be available. Contact your practitioner for a new link.';
      if ($retryBtn) $retryBtn.hidden = true;
    }
    $error.hidden = false;
  }
}

// Start the app
init();
