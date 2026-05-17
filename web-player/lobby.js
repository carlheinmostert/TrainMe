/**
 * homefit.studio — Web Player Lobby Controller (PR 4/4 of the lobby train, 2026-05-04)
 * ====================================================================================
 *
 * The lobby is the pre-workout surface at session.homefit.studio/p/{planId}.
 * It replaces the legacy "first card + Start Workout button" entry with a
 * vertical menu of hero frames so the client previews the session before
 * tapping Start. Once Start is tapped, the lobby is hidden and the existing
 * deck (`#app`) takes over. Reload returns the user to the lobby. One-way
 * door per session.
 *
 * R-10 parity: this module ships in the shared `web-player/` bundle so the
 * mobile Workflow Preview WebView gets the same lobby for free.
 *
 * Coupling with `app.js`:
 *   - app.js exposes `window.HomefitLobbyHandoff` with the data the lobby
 *     controller needs (slides, plan, treatment helpers, analytics emit).
 *   - This file calls `window.HomefitLobbyHandoff.startWorkout()` to hand
 *     off control to the deck.
 *   - Treatment selector applies the practitioner-pivoted "Show me"
 *     override globally (per-exercise overrides ride on top in the deck
 *     gear popover post-handoff).
 *
 * No external dependencies. No inline scripts (CSP `script-src 'self'`).
 */

(function () {
  'use strict';

  // ==========================================================================
  // DOM handles
  // ==========================================================================

  const $lobby = document.getElementById('lobby');
  const $lobbyMeta = document.getElementById('lobby-meta');
  const $lobbyMetaHeadline = document.getElementById('lobby-meta-headline');
  const $lobbyMetaSub = document.getElementById('lobby-meta-sub');
  const $lobbyMetaStamp = document.getElementById('lobby-meta-stamp');
  const $lobbyMetaVersion = document.getElementById('lobby-meta-version');
  const $lobbyMatrix = document.getElementById('lobby-matrix');
  const $lobbyMatrixInner = document.getElementById('lobby-matrix-inner');
  const $lobbyList = document.getElementById('lobby-list');
  const $lobbyStartBtn = document.getElementById('lobby-start-btn');
  const $lobbyShareBtn = document.getElementById('lobby-share-btn');
  const $lobbyGearBtn = document.getElementById('lobby-gear-btn');
  const $lobbySettingsPopover = document.getElementById('lobby-settings-popover');
  const $lobbyResetOverridesBtn = document.getElementById('lobby-reset-overrides-btn');
  // Lobby-settings-unify (2026-05-14): the lobby popover hosts the same
  // unified treatment + body-focus + reset panel as the deck. The
  // legacy `#lobby-treatment-row` element was retired in favour of the
  // shared `.settings-row-segmented[data-prop="treatment"]` markup —
  // its pill click handler lives on the popover root via delegation.
  const $lobbyTreatmentPills = $lobbySettingsPopover
    ? $lobbySettingsPopover.querySelector('.settings-row-segmented[data-prop="treatment"]')
    : null;
  const $lobbyBodyFocusBtn = $lobbySettingsPopover
    ? $lobbySettingsPopover.querySelector('.settings-row-btn[data-prop="bodyFocus"]')
    : null;
  const $selfGrantModal = document.getElementById('lobby-self-grant-modal');
  const $selfGrantTitle = document.getElementById('lobby-self-grant-title');
  const $selfGrantName = document.getElementById('lobby-self-grant-name');
  const $selfGrantBody = document.getElementById('lobby-self-grant-body');
  const $selfGrantError = document.getElementById('lobby-self-grant-error');
  const $selfGrantAllow = document.getElementById('lobby-self-grant-allow');

  // ==========================================================================
  // State
  // ==========================================================================

  let api = null;        // window.HomefitLobbyHandoff handle
  let plan = null;
  let slides = [];
  let activeTreatment = 'line';
  let pendingGrantKind = null;     // 'grayscale' | 'original'
  let activeRowIndex = -1;          // -1 = nothing active yet (sentinel)
  let scrollRafToken = null;        // rAF-throttled scroll handler
  let scrollListenerWired = false;
  let scrollContainer = null;       // .lobby-inner — the scroll root
  let _lazyKickToken = null;        // pending setTimeout for lazyKickVideosNear (debounce)

  // Default plan title format used to detect default-named plans:
  // "{DD MMM YYYY HH:MM}" e.g. "04 May 2026 14:30".
  const DEFAULT_TITLE_RE = /^\d{1,2}\s+[A-Za-z]{3}\s+\d{4}\s+\d{1,2}:\d{2}$/;

  // ==========================================================================
  // Circuit breaker — diagnostic for the iOS WKWebView lobby freeze
  // ==========================================================================
  //
  // The lobby freezes ~5–8s into sustained scrolling on iPhone WKWebView:
  // the WebView "goes black", heartbeat console.log dies, no JS errors, no
  // network. PR #249's smooth-scroll fix didn't resolve it. This breaker
  // surfaces the runaway callsite by tracking call rate per name.
  //
  //   - cbBump(name): inline counter at function entry. Returns false if
  //     either we just tripped this name (→ caller bails out and we log
  //     a single warning), or the name was already tripped within the
  //     last 5s (caller bails silently — no log spam).
  //   - cb(name, fn): same as cbBump but wraps a synchronous callback.
  //   - cbAsync(name, asyncFn): same for async callbacks (e.g. setTimeout
  //     bodies that await).
  //   - 2s heartbeat: prints `[CB-hb] {name: count, ...}` to console for
  //     any name with > 0 calls in the last second. Wired ONCE inside
  //     showLobby() (guarded by `_cbHbWired`). Works in iOS Safari Web
  //     Inspector — that's the only way to see the runaway on device.
  //
  // Threshold: 60 calls / 1000ms — picks up rAF (60Hz) re-entry loops
  // without flagging a single rAF callback chain. Trip auto-clears
  // after 5s so we re-arm and can catch follow-up runaways.

  const _cbCounts = new Map();          // name → number[] (recent timestamps)
  const _cbTripped = new Map();         // name → number (trip timestamp)
  const _cbDropLogged = new Set();      // names we've logged a drop for since trip
  let _cbHbWired = false;

  function cbBump(name) {
    const now = performance.now();
    let arr = _cbCounts.get(name);
    if (!arr) { arr = []; _cbCounts.set(name, arr); }
    arr.push(now);
    // Trim to a 1-second sliding window.
    while (arr.length && now - arr[0] > 1000) arr.shift();
    if (_cbTripped.has(name)) {
      // Silent drop, but log once per trip so Carl knows we're suppressing.
      if (!_cbDropLogged.has(name)) {
        _cbDropLogged.add(name);
        try {
          console.warn(`[CB] ${name} suppressed (already tripped) — re-arming in 5s`);
        } catch (_) { /* console may be gone in some webviews */ }
      }
      return false;
    }
    if (arr.length > 60) {
      _cbTripped.set(name, now);
      try {
        console.warn(`[CB] ${name} runaway: ${arr.length} calls in last 1000ms — aborting`);
      } catch (_) {}
      setTimeout(() => {
        _cbTripped.delete(name);
        _cbDropLogged.delete(name);
      }, 5000);
      return false;
    }
    return true;
  }

  function cb(name, fn) {
    if (!cbBump(name)) return undefined;
    return fn();
  }

  async function cbAsync(name, asyncFn) {
    if (!cbBump(name)) return undefined;
    return await asyncFn();
  }

  function startCircuitBreakerHeartbeat() {
    if (_cbHbWired) return;
    _cbHbWired = true;
    setInterval(() => {
      const now = performance.now();
      const summary = {};
      _cbCounts.forEach((arr, name) => {
        // Trim again — the counts may not have been touched in this window.
        while (arr.length && now - arr[0] > 1000) arr.shift();
        if (arr.length > 0) summary[name] = arr.length;
      });
      // v49 — include the live <video> element count in the lobby. Under
      // the v48 structural fix, this should always be 0 or 1. If it's
      // ever 2+, the swap path leaked a ghost video element somewhere.
      try {
        if ($lobbyList) {
          const videoCount = $lobbyList.querySelectorAll('video').length;
          summary.videos = videoCount;
        }
      } catch (_) {}
      // Only log when there's activity to surface OR when the video
      // count is non-zero (so we always have a video-count signal when
      // the lobby is active).
      const keys = Object.keys(summary);
      if (keys.length === 0) return;
      try {
        // Stringify so the WebView log shows the structure even if the
        // logger doesn't pretty-print objects.
        console.log('[CB-hb] ' + JSON.stringify(summary));
      } catch (_) {}
    }, 2000);
  }

  // ==========================================================================
  // Public API
  // ==========================================================================

  /**
   * Called by app.js once it has loaded the plan and unrolled slides.
   * Builds the lobby DOM and shows it. App.js suppresses its own auto-start
   * and start-workout button when the lobby is in charge.
   *
   * @param {object} args
   * @param {object} args.plan      - The plan as returned by fetchPlan()
   * @param {Array}  args.slides    - unrolled slide list
   * @param {object} args.helpers   - Functions exposed by app.js:
   *   - calculateDuration(slide)
   *   - sumTotalDurationSeconds()
   *   - playSetsForSlide(slide)
   *   - getExerciseRotationDeg(slide)
   *   - resolveTreatmentUrl(exercise, treatment)
   *   - escapeHTML(s)
   *   - emitAnalyticsEvent(kind, exerciseId, data)
   *   - planHasGrayscaleConsent()  -> bool
   *   - planHasOriginalConsent()   -> bool
   *   - startWorkout()
   *   - rebindVideoSources()       (re-renders the deck with current treatment)
   *   - applyTreatmentOverrideToAllExercises(treatment)
   *   - getEffective(exercise, prop)  -> per-exercise effective state
   *                                       (replaces getDefaultTreatment;
   *                                       Bundle 1 hero-resolver migration)
   *   - reFetchPlan()                 -> refetch + replace plan in-place
   */
  function showLobby(args) {
    api = args.helpers;
    plan = args.plan;
    slides = args.slides || [];

    // 2026-05-17 — append `?v=<plan.version>` to per-exercise thumb URLs
    // so each republish forces a fresh fetch through every cache layer
    // (resolver in-memory cache, SW cache, browser HTTP cache that
    // honours Supabase Storage's `cache-control: public, max-age=3600`).
    // The thumb file PATH is reused across regenerations under PR #376's
    // `thumbnailsDirty` flow, so without a URL-level buster the lobby
    // pins on first-publish bytes until cache expires. PR #383's SW
    // network-first + PR #384's `cache: 'reload'` raced the page-load
    // hydrate: the SW wasn't reliably intercepting before
    // `hydrateHeroCrops` had already fetched + rasterised the stale URL.
    // Version-busting is invariant across all three layers AND survives
    // races. `plan.version` increments on every publish (see
    // `plans.version` column).
    if (plan && plan.version != null) {
      const v = String(plan.version);
      const thumbKeys = [
        'thumbnail_url',
        'thumbnail_url_line',
        'thumbnail_url_color',
        'thumbnail_url_bw',
      ];
      for (let i = 0; i < slides.length; i++) {
        const slide = slides[i];
        if (!slide) continue;
        for (let j = 0; j < thumbKeys.length; j++) {
          const k = thumbKeys[j];
          const u = slide[k];
          if (typeof u !== 'string' || !u || u.indexOf('?v=') !== -1) continue;
          slide[k] = u + (u.indexOf('?') === -1 ? '?v=' : '&v=') + v;
        }
      }
    }
    // The lobby treatment-pill picker still surfaces ONE selected
    // treatment ("which one is highlighted"). Seed it from the first
    // non-rest slide's effective treatment so the picker matches what
    // the client actually sees. Each row then renders with its OWN
    // per-exercise effective treatment via the resolver — no more
    // lobby-global B6 leak.
    activeTreatment = (function () {
      if (!api.getEffective) return 'line';
      for (let i = 0; i < slides.length; i++) {
        const s = slides[i];
        if (s && s.media_type !== 'rest') {
          let t = api.getEffective(s, 'treatment') || 'line';
          if (t === 'bw' && !(api.planHasGrayscaleConsent && api.planHasGrayscaleConsent())) t = 'line';
          if (t === 'original' && !(api.planHasOriginalConsent && api.planHasOriginalConsent())) t = 'line';
          return t;
        }
      }
      return 'line';
    })();

    renderMeta();
    renderMatrix();
    renderList();
    renderTreatmentRow();
    wireEvents();

    // Hide the start workout button on the deck — the lobby owns this.
    const $startBtn = document.getElementById('start-workout-btn');
    if ($startBtn) $startBtn.hidden = true;

    // Hide the deck while the lobby is up.
    const $app = document.getElementById('app');
    if ($app) $app.hidden = true;

    $lobby.hidden = false;
    document.body.classList.add('is-lobby-mode');

    // Diagnostic heartbeat — see circuit-breaker block at the top of this
    // file. Wired exactly once.
    startCircuitBreakerHeartbeat();

    // Wire scroll-driven row↔matrix coupling AFTER first paint so
    // measured offsets are accurate. Default the first non-rest row to
    // active immediately (no scroll yet — the IntersectionObserver
    // approach left the matrix unhighlighted at scroll-top because
    // viewport-centre crossed nothing).
    requestAnimationFrame(() => {
      activateInitialRow();
      setupScrollCoupling();
    });
  }

  /**
   * Called when the start CTA is tapped. Hides the lobby, shows the
   * deck, and asks app.js to begin the workout. Analytics
   * `workout_started` is emitted here (re-anchored from first prep frame).
   */
  function dismissLobbyAndStart() {
    if (!api) return;
    document.body.classList.remove('is-lobby-mode');
    $lobby.hidden = true;
    const $app = document.getElementById('app');
    if ($app) $app.hidden = false;

    if (api.emitAnalyticsEvent) {
      api.emitAnalyticsEvent('workout_started', null, {
        source: 'lobby',
        slide_count: slides.length,
      });
    }

    // Hand off — app.js wires the rest of the deck.
    if (api.startWorkout) api.startWorkout();
  }

  // ==========================================================================
  // Metadata strip
  // ==========================================================================

  function renderMeta() {
    if (!plan) return;
    const title = (plan.title || '').trim();
    const isDefaultNamed = !title || DEFAULT_TITLE_RE.test(title);
    const clientName = (plan.client_name || '').trim();
    const practitionerName = api.getPractitionerName ? api.getPractitionerName() : 'your practitioner';

    // Compose stats: "{N exercises · ~MM min · From {Practitioner}}"
    const exerciseCount = countExercises(slides);
    const totalSec = api.sumTotalDurationSeconds ? api.sumTotalDurationSeconds() : 0;
    const minutes = Math.max(1, Math.round(totalSec / 60));
    const exLabel = exerciseCount === 1 ? '1 exercise' : `${exerciseCount} exercises`;
    const durLabel = `~${minutes} min`;
    const fromLabel = practitionerName ? `From ${practitionerName}` : '';

    const subParts = [exLabel, durLabel, fromLabel].filter(Boolean);

    if (isDefaultNamed) {
      // Headline = "Hi {ClientName}". Sub-line = stats.
      $lobbyMetaHeadline.classList.remove('is-custom-title');
      $lobbyMetaHeadline.textContent = clientName ? `Hi ${clientName}` : 'Hi there';
      $lobbyMetaSub.textContent = subParts.join(' · ');
    } else {
      // Headline = plan title (custom). Sub-line = "Hi {ClientName} · stats".
      $lobbyMetaHeadline.classList.add('is-custom-title');
      $lobbyMetaHeadline.textContent = title;
      const fullSub = clientName
        ? [`Hi ${clientName}`].concat(subParts).join(' · ')
        : subParts.join(' · ');
      $lobbyMetaSub.textContent = fullSub;
    }

    // Date stamp — small/dim. Use the plan title when default-named (it
    // already IS the date stamp); otherwise fall back to last_published.
    if (isDefaultNamed && title) {
      $lobbyMetaStamp.textContent = title;
    } else {
      const last = plan.last_published_at || plan.updated_at || null;
      $lobbyMetaStamp.textContent = last ? formatStamp(last) : '';
    }

    // Build marker: "plan v{N} · {gitSha} · {gitBranch} · cache {active cache}".
    // The plan segment surfaces `plans.version` (incremented on every
    // Publish) so a freshly-republished plan is distinguishable from a
    // stale tab on the same URL. The git SHA + branch + active cache
    // are the source of truth for "what code is this client running";
    // a divergence between gitSha and cache name on the chip means
    // the SW hasn't refreshed yet. The legacy `web-player PLAYER_VERSION`
    // segment was dropped 2026-05-16 — the hand-coded constant was
    // never bumped in lockstep with deploys and ended up reading
    // `v70-png-modal-removed` weeks after the PNG modal was removed,
    // misleading QA into thinking the player was stale when gitSha
    // already showed the latest commit.
    populateVersionChip();
  }

  function populateVersionChip() {
    if (!$lobbyMetaVersion) return;
    const planVersion =
      plan && plan.version != null ? `plan v${plan.version}` : null;
    // Git SHA + branch from window.HOMEFIT_CONFIG (populated by
    // web-player/build.sh from Vercel's VERCEL_GIT_COMMIT_SHA +
    // VERCEL_GIT_COMMIT_REF env vars). Degrades to 'dev' / 'local' for
    // surfaces without git metadata (Flutter LocalPlayerServer, bare
    // local server) so the chip still renders meaningful text.
    const _cfg = (typeof window !== 'undefined' && window.HOMEFIT_CONFIG) || {};
    const gitSha = (typeof _cfg.gitSha === 'string' && _cfg.gitSha) || 'dev';
    const gitBranch = (typeof _cfg.gitBranch === 'string' && _cfg.gitBranch) || 'local';
    const compose = (cacheLabel) => [
      planVersion,
      `${gitSha} · ${gitBranch}`,
      `cache ${cacheLabel}`,
    ].filter(Boolean).join(' · ');

    // Set the bundle version immediately so we don't block on the SW.
    $lobbyMetaVersion.textContent = compose('…');
    if (!('caches' in window)) {
      $lobbyMetaVersion.textContent = compose('n/a');
      return;
    }
    caches.keys().then((keys) => {
      const active = keys.find((k) => k.startsWith('homefit-player-'));
      const swLabel = active ? active.replace(/^homefit-player-/, '') : 'none';
      $lobbyMetaVersion.textContent = compose(swLabel);
    }).catch(() => {
      $lobbyMetaVersion.textContent = compose('?');
    });
  }

  function countExercises(slides) {
    // Count unique non-rest exercises. Circuits stay grouped (one exercise
    // = one row), not unrolled. We can't fully de-dupe circuit rounds
    // without the original plan.exercises array; fall back to the slide
    // list and dedupe by id.
    const seen = new Set();
    let count = 0;
    for (let i = 0; i < slides.length; i++) {
      const s = slides[i];
      if (!s || s.media_type === 'rest') continue;
      const key = s.id != null ? s.id : `_idx_${i}`;
      if (seen.has(key)) continue;
      seen.add(key);
      count++;
    }
    return count;
  }

  function formatStamp(iso) {
    try {
      const d = new Date(iso);
      if (isNaN(d.getTime())) return '';
      return d.toLocaleString(undefined, {
        day: '2-digit', month: 'short', year: 'numeric',
        hour: '2-digit', minute: '2-digit',
      });
    } catch (_) {
      return '';
    }
  }

  // ==========================================================================
  // Pill matrix
  // ==========================================================================

  function renderMatrix() {
    if (!$lobbyMatrixInner) return;
    if (!api.buildLobbyMatrix) {
      // Fallback — a flat row of pills, one per slide.
      $lobbyMatrixInner.innerHTML = slides.map((s, i) => {
        const isRest = s.media_type === 'rest';
        return `<button type="button" class="pill size-medium${isRest ? ' is-rest' : ''}" data-slide="${i}" aria-label="Jump to ${api.escapeHTML(s.name || 'Rest')}"><span class="pill-fill"></span></button>`;
      }).join('');
      return;
    }
    // app.js can produce a grouped matrix HTML for us (circuits as a
    // tinted band). The clickable hooks live on `.pill[data-slide]`.
    $lobbyMatrixInner.innerHTML = api.buildLobbyMatrix(slides);
  }

  // ==========================================================================
  // Hero list — vertical scroll
  // ==========================================================================

  function renderList() {
    if (!$lobbyList) return;

    // Build up an array of "row groups" where consecutive circuit-id slides
    // collapse to one circuit group with a header. Circuit slides are
    // unrolled in the deck (1 slide per round) — for the lobby we want
    // ONE row per exercise instance (de-dupe by id). Same dedupe applies
    // to rest slides that sit inside a circuit (would otherwise be emitted
    // once per round, e.g. 3 "Rest" rows for a 3-round circuit with one
    // rest in it — the bug Carl reported as 3 synthesised "Breather" rows
    // for a single plan-level rest).
    //
    // Hotfix round 3 — Fix C — default-name fallback position counter.
    // Studio's create-exercise factory (app/lib/models/exercise_capture.dart)
    // does NOT persist a default name — `name` arrives as null from
    // `get_plan_full` for any exercise the practitioner hasn't renamed.
    // The mobile UI's `Exercise N` fallback only fires at display time
    // (progress_pill_matrix.dart). So the lobby has to synthesise its own
    // position-numeric fallback. We increment `exercisePosition` for each
    // de-duped non-rest exercise and pass it through to exerciseRowHTML
    // so a null/empty `slide.name` becomes "Exercise 1", "Exercise 2", …
    // Custom-named exercises render their name as-is (no number).
    // Round 5 — Fix 1 — circuit letter map for the default-name fallback.
    // Studio's `_circuitLetter(circuitId)` (app/lib/screens/studio_mode_screen.dart)
    // assigns A, B, C… by first-appearance order in the exercise list,
    // wrapping with mod 26 if more than 26 distinct circuits exist. Mirror
    // that algorithm here so lobby + Studio render the same letters when
    // the practitioner hasn't customised. Walk slides in their natural
    // order (which mirrors `plan.exercises`); each new circuit_id picks
    // up the next letter index.
    const circuitLetters = (() => {
      const map = {};
      let nextIdx = 0;
      for (let i = 0; i < slides.length; i++) {
        const s = slides[i];
        if (!s || !s.circuit_id) continue;
        if (Object.prototype.hasOwnProperty.call(map, s.circuit_id)) continue;
        map[s.circuit_id] = String.fromCharCode(
          'A'.charCodeAt(0) + (nextIdx % 26),
        );
        nextIdx += 1;
      }
      return map;
    })();

    const items = [];
    const seenIds = new Set();
    let circuitGroup = null;
    let exercisePosition = 0;

    for (let i = 0; i < slides.length; i++) {
      const s = slides[i];
      if (!s) continue;

      // Dedupe by exercise id — circuit unroll multiplies a single
      // exercise (or rest) into N rounds. The lobby groups circuits, so
      // each underlying exercise must appear exactly once.
      const idKey = s.id != null ? String(s.id) : `_idx_${i}`;
      if (seenIds.has(idKey)) continue;
      seenIds.add(idKey);

      if (s.media_type === 'rest') {
        // Hotfix round 2 — Fix 2(c) — duplicate-header root cause.
        //
        // Previously a rest slide unconditionally CLOSED the open
        // `circuitGroup`. When a rest sat INSIDE a circuit (between two
        // exercises in the same circuit_id), the close-and-reopen dance
        // emitted TWO `.lobby-circuit-group` <li>s with the same id —
        // hence the duplicate coral header Carl reported on the first
        // circuit of his published session.
        //
        // Fix: a rest whose `circuit_id` matches the open group's id
        // belongs INSIDE that group's row stream — append it to
        // `circuitGroup.rows` instead of closing the group. The plain
        // exerciseRowHTML doesn't know how to render a rest, so we
        // mark these rows with `kind: 'rest-in-circuit'` and
        // `circuitGroupHTML` interleaves the rest row HTML.
        if (circuitGroup && s.circuit_id && circuitGroup.circuitId === s.circuit_id) {
          circuitGroup.rows.push({ slide: s, slideIndex: i, isRest: true });
          continue;
        }
        // Plan-level rest (or a rest after a different circuit) — close
        // the open group cleanly.
        if (circuitGroup) { items.push(circuitGroup); circuitGroup = null; }
        items.push({ kind: 'rest', slide: s, slideIndex: i });
        continue;
      }

      // Non-rest exercise — bump the position counter for the default-name
      // fallback (rests are excluded so the numbering matches what a client
      // expects: "Exercise 1, Exercise 2" through the workout's actual moves).
      exercisePosition += 1;

      // Circuit slide — group them. The dedupe above already keeps only
      // the first-round occurrence of each circuit exercise.
      if (s.circuit_id && s.circuitRound != null) {
        if (!circuitGroup || circuitGroup.circuitId !== s.circuit_id) {
          if (circuitGroup) items.push(circuitGroup);
          // Resolve the circuit's display name. Source of truth (ordered):
          //   1. plan.circuit_names[circuit_id] (Wave Circuit-Names) — the
          //      practitioner-set custom label; already mirrored onto each
          //      circuit slide as `circuitName` by `unrollExercises`.
          //   2. Round 5 — Fix 1 — fall back to "Circuit {Letter}" using
          //      the first-appearance-order map, mirroring Studio's
          //      `_circuitLetter` helper (app/lib/screens/studio_mode_screen.dart).
          //      Studio header inline-edits this same fallback shape, so
          //      the lobby reads consistently with what the practitioner
          //      sees in the editor.
          const customName = (s.circuitName && String(s.circuitName).trim())
            || (plan
              && plan.circuit_names
              && plan.circuit_names[s.circuit_id]
              && String(plan.circuit_names[s.circuit_id]).trim())
            || '';
          const letter = circuitLetters[s.circuit_id] || 'A';
          const circuitName = customName || `Circuit ${letter}`;
          circuitGroup = {
            kind: 'circuit',
            circuitId: s.circuit_id,
            circuitName: circuitName,
            rounds: s.circuitTotalRounds || 1,
            rows: [],
          };
        }
        circuitGroup.rows.push({ slide: s, slideIndex: i, position: exercisePosition });
        continue;
      }

      // Standalone exercise — emit a single row.
      if (circuitGroup) { items.push(circuitGroup); circuitGroup = null; }
      items.push({ kind: 'single', slide: s, slideIndex: i, position: exercisePosition });
    }
    if (circuitGroup) items.push(circuitGroup);

    $lobbyList.innerHTML = items.map(itemToHTML).join('');
    // ATTEMPT #10 (2026-05-15) — no post-render JS for circuits. The
    // SVG-tracer architecture (v54 + nine fixes) is gone; nested-box
    // animation is pure CSS keyframes driven by class assignment in
    // circuitGroupHTML(). No measurement, no observers, no rAF chain.
    // Pill scroll-fill wave — stamp each matrix pill with the ordinal
    // position of its owning lobby row. setActiveRow uses these to fill
    // pills as the user scrolls forward, drain them on scroll-back.
    stampPillRowOrdinals();
    // Hero-crop resolver refactor (2026-05-16) — replace each freshly-
    // rendered `<img src>` with a square 1:1 data URL produced from
    // the source JPG + `hero_crop_offset`. The brief un-cropped flash
    // is clipped by the parent's `overflow: hidden` so the row layout
    // never reflows. Re-runs (treatment switch, re-render) hit the
    // resolver's cache.
    hydrateHeroCrops();
  }

  // ==========================================================================
  // Pill scroll-fill — slide-index → row-ordinal mapping
  // ==========================================================================
  //
  // The lobby renders ONE row per exercise (across all rounds in a circuit).
  // The matrix renders ONE pill per slide (every round of every exercise).
  // To fill pills progressively as the user scrolls through the row list,
  // we need: for each pill, the ordinal of the row that owns its exercise.
  //
  // Mapping: slides[i].id is the EXERCISE's UUID — shared across all rounds
  // of a circuit exercise (unrollExercises spreads `...gex` so `id` carries
  // through). The lobby row's data-id is that same exercise UUID. So we
  // can match pill → row by comparing slide.id to row.dataset.id.

  function stampPillRowOrdinals() {
    if (!$lobbyList || !$lobbyMatrixInner) return;
    const rows = $lobbyList.querySelectorAll('.lobby-row[data-slide-index]');
    const ordinalById = new Map();
    rows.forEach((row, ordinal) => {
      const id = row.dataset.id;
      if (id) ordinalById.set(id, ordinal);
    });
    const pills = $lobbyMatrixInner.querySelectorAll('.pill[data-slide]');
    pills.forEach((pill) => {
      const slideIdx = parseInt(pill.getAttribute('data-slide'), 10);
      if (Number.isNaN(slideIdx)) return;
      const slide = slides[slideIdx];
      if (!slide) return;
      const ord = ordinalById.get(slide.id);
      if (ord != null) pill.dataset.rowOrd = String(ord);
    });
  }

  function updatePillFills(activeRowEl) {
    if (!$lobbyMatrixInner || !activeRowEl) return;
    const rows = Array.from($lobbyList.querySelectorAll('.lobby-row[data-slide-index]'));
    const activeOrdinal = rows.indexOf(activeRowEl);
    if (activeOrdinal < 0) return;
    const pills = $lobbyMatrixInner.querySelectorAll('.pill[data-row-ord]');
    pills.forEach((pill) => {
      const ord = parseInt(pill.dataset.rowOrd, 10);
      if (Number.isNaN(ord)) return;
      if (ord <= activeOrdinal) pill.classList.add('is-filled');
      else pill.classList.remove('is-filled');
    });
  }

  function itemToHTML(item) {
    if (item.kind === 'rest') return restRowHTML(item.slide, item.slideIndex);
    if (item.kind === 'single') {
      return exerciseRowHTML(item.slide, item.slideIndex, { position: item.position });
    }
    if (item.kind === 'circuit') return circuitGroupHTML(item);
    return '';
  }

  // Hotfix round 3 — Fix B — two-column gutter layout for in-circuit
  // rows. PR 235 used absolute-positioned `::before` / `::after` pseudo-
  // elements at `left: 8px` which got covered by the active-row coral
  // border (correct UX — coral border on focused row is intentional)
  // AND by stacking-context bugs that caused the rail to vanish after
  // the first row. Replacement: real two-column flex layout per row,
  // with a fixed-width `.lobby-row-gutter` column that owns the rail
  // pieces and a `.lobby-row-content` column that carries the existing
  // hero + info card. The rail is rendered as <span> children of the
  // gutter (not pseudo-elements) so it sits OUTSIDE the card's border
  // and can never be covered by a stacking context above it.
  //
  // Hotfix round 3 — Fix C — default-name fallback. Studio doesn't
  // persist a default name (the factory at exercise_capture.dart:416
  // leaves `name` as null). When `slide.name` is null/empty, synthesise
  // "Exercise N" from the position counter the renderList loop
  // maintains. Custom-named exercises render their name as-is (no
  // number; trust the practitioner). Position counts de-duplicated
  // non-rest exercises and is shared across standalones + circuits.
  function exerciseRowHTML(slide, slideIndex, _opts) {
    const escape = api.escapeHTML;
    const opts = _opts || {};

    // Default-name fallback: if the practitioner didn't rename the
    // exercise, the cloud row has `name: null` (Studio never persists
    // an "Exercise N" string). Synthesise one from the position.
    const rawName = (slide.name || '').trim();
    const displayName = rawName
      ? rawName
      : (opts.position ? `Exercise ${opts.position}` : 'Exercise');
    const name = escape(displayName);

    const dose = buildDoseLine(slide);
    const notes = (slide.notes || '').trim();

    // Hero element — picked per active treatment. For Line + B&W/Colour
    // videos we render <video> (Line uses line_drawing_url, B&W/Colour
    // use grayscale_url / original_url). Photos always render as <img>.
    //
    // 2026-05-16 hero-crop-resolver refactor: the `<img>` is rendered
    // with NO `object-position` style. The crop (vertical centre by
    // `slide.hero_crop_offset` for portrait sources; horizontal centre
    // for landscape) is baked into a 1:1 data URL by the resolver after
    // the row mounts — see hydrateHeroCrops below. html2canvas honours
    // the resulting square <img src> directly, so the PDF export path
    // gets the same crop as the live lobby with no extra work.
    const heroHTML = renderHeroHTML(slide);

    // `last` flag is supplied by `circuitGroupHTML` for the final in-
    // circuit row so the rail piece can clamp at 50% to form an L corner.
    const isLast = !!opts.last;
    const lastClass = isLast ? ' last' : '';

    // Two-column structure: gutter on the left for the rail (only
    // rendered for in-circuit rows; circuitGroupHTML rewrites the
    // outer <li> class to add `in-circuit`, then CSS wakes up the
    // gutter children). Standalone rows still render the gutter span
    // markup but CSS hides it; this keeps the row HTML uniform so
    // promotion to in-circuit is a class-only swap.
    return `
      <li class="lobby-row${lastClass}" role="listitem"
          data-slide-index="${slideIndex}"
          data-id="${escape(slide.id || '')}">
        <div class="lobby-row-gutter" aria-hidden="true">
          <span class="lobby-row-gutter-rail"></span>
          <span class="lobby-row-gutter-connector"></span>
        </div>
        <div class="lobby-row-content">
          <div class="lobby-hero" data-hero-target>
            ${heroHTML}
          </div>
          <div class="lobby-info">
            <h3 class="lobby-info-name">${name}</h3>
            ${dose ? `<p class="lobby-info-dose">${escape(dose)}</p>` : ''}
            ${notes ? `<button type="button" class="lobby-info-notes" aria-expanded="false" data-notes-toggle>${escape(notes)}</button>` : ''}
          </div>
        </div>
      </li>
    `;
  }

  function restRowHTML(slide, slideIndex) {
    const seconds = Math.max(1, Math.round(Number(slide.rest_seconds) || 30));
    // Wave 5 lobby fixes — rename "Breather" → "Rest" (Carl): plan-level
    // rests are explicit "Rest" exercises, distinct from per-set
    // breathers that appear in the dose-line as "30s rest".
    //
    // Hotfix round 3 — Fix B — same two-column shape as exerciseRowHTML
    // so a rest-inside-circuit row gets a rail piece in the gutter and
    // the label in the content column. Standalone rests collapse the
    // gutter via CSS (no `in-circuit` class).
    return `
      <li class="lobby-row is-rest" role="listitem"
          data-slide-index="${slideIndex}"
          data-id="${api.escapeHTML(slide.id || '')}">
        <div class="lobby-row-gutter" aria-hidden="true">
          <span class="lobby-row-gutter-rail"></span>
          <span class="lobby-row-gutter-connector"></span>
        </div>
        <div class="lobby-row-content">
          <span class="lobby-rest-label">Rest · ${seconds}s</span>
        </div>
      </li>
    `;
  }

  // Maximum number of visible nested-box rings. Beyond five the visual
  // gets silly and adjacent rings start to merge optically. Plans with
  // more than five rounds still display correctly — only the chrome
  // caps at five (the `×N` chip in the header still reads truthfully).
  const CIRCUIT_BOX_CAP = 5;

  function circuitGroupHTML(group) {
    const escape = api.escapeHTML;
    // ATTEMPT #10 (2026-05-15) — pure-CSS nested boxes, N = round count.
    //
    // The prior nine attempts patched layers of an SVG-tracer architecture
    // that depended on runtime DOM measurement, ResizeObservers,
    // MutationObservers, font-load awaits and getTotalLength polling.
    // Every fix introduced new failure modes; the most recent (PR #360)
    // was a stopgap. Replaced wholesale with N actual nested DOM rings.
    //
    // Structure:
    //   <li class="lobby-circuit"> (positioning + cycles data)
    //     <header> Circuit name · ×N
    //     <.lobby-circuit-box .lobby-circuit-box-outer> (when N > 1)
    //       … (additional rings, one per round, up to the cap)
    //         <.lobby-circuit-box .lobby-circuit-box-inner> (always present)
    //           <.lobby-circuit-body> (rows live here, padding handled by CSS)
    //
    // N visible boxes = circuit-cycle count, capped at CIRCUIT_BOX_CAP.
    // ×1 → 1 box (just the inner). ×3 → 3 boxes. ×N → min(N, cap).
    // Geometry sized via CSS only — no measurement, no observers,
    // no JS animation. Animation is a pure CSS keyframe (`v1-pulse`)
    // applied via class with `animation-delay` for the outward ripple.
    //
    // Rows still emit as <div>, NOT <li>, so the browser doesn't auto-
    // close the outer <li>. (PRs #257/#258 lesson preserved.) The
    // selector `.lobby-row[data-slide-index]` matches both <li> and
    // <div> so scroll-coupling (recomputeActiveRow, setActiveRow,
    // lazyKickVideosNear) keeps working unchanged.
    //
    // Cycles chip: `×3` only — no "ROUNDS" suffix.
    // Round 5 — Fix 1 — `group.circuitName` is now always non-null (the
    // renderList loop substitutes "Circuit {Letter}" when neither
    // `s.circuitName` nor `plan.circuit_names[circuit_id]` resolves).
    const labelText = group.circuitName
      ? group.circuitName
      : 'Circuit';
    const rounds = Math.max(1, group.rounds || 1);
    const visibleBoxes = Math.min(rounds, CIRCUIT_BOX_CAP);
    const cyclesText = `×${rounds}`;
    const lastIdx = group.rows.length - 1;
    const rows = group.rows.map((r, i) => {
      const isLast = i === lastIdx;
      const html = r.isRest
        ? restRowHTML(r.slide, r.slideIndex)
        : exerciseRowHTML(r.slide, r.slideIndex, { last: isLast, position: r.position });
      const lastMod = (isLast && r.isRest) ? ' last' : '';
      // Transform the row's outer <li> → <div> + add circuit classes.
      return html
        .replace(/^\s*<li\b/, '<div')
        .replace(/<\/li>(\s*)$/, '</div>$1')
        .replace(
          'class="lobby-row',
          `class="lobby-row is-circuit in-circuit${lastMod}`
        );
    }).join('');

    // Build the nested rings outside-in. The innermost ring is always
    // the deepest div and wraps `.lobby-circuit-body`. For a ×3 plan we
    // emit boxes numbered 3 (outermost) → 2 → 1 (innermost). Each box
    // gets its own staggered `animation-delay` via the `--box-index`
    // custom property (0 = innermost, N-1 = outermost) so the CSS
    // keyframe can stagger ripples without per-N selectors.
    let body = `<div class="lobby-circuit-body">${rows}</div>`;
    for (let depth = 0; depth < visibleBoxes; depth++) {
      // depth=0 is innermost, depth=visibleBoxes-1 is outermost.
      const isInner = depth === 0;
      const isOuter = depth === visibleBoxes - 1;
      const classes = [
        'lobby-circuit-box',
        `lobby-circuit-box-depth-${depth}`,
        isInner ? 'lobby-circuit-box-inner' : '',
        isOuter ? 'lobby-circuit-box-outer' : '',
      ].filter(Boolean).join(' ');
      body = `<div class="${classes}" style="--box-index:${depth}; --box-total:${visibleBoxes}">${body}</div>`;
    }

    return `
      <li class="lobby-circuit" data-circuit="${escape(group.circuitId || '')}" data-cycles="${rounds}" data-visible-boxes="${visibleBoxes}">
        <div class="lobby-circuit-header">
          <span class="lobby-circuit-header-label">${escape(labelText)}</span>
          <span class="lobby-circuit-header-cycles" aria-label="${escape(rounds)} rounds">${escape(cyclesText)}</span>
        </div>
        ${body}
      </li>
    `;
  }

  // ==========================================================================
  // Circuit chrome — N nested coral-bordered boxes, pure CSS animation
  // ==========================================================================
  //
  // ATTEMPT #10 (2026-05-15) — the previous SVG-tracer architecture lived
  // here. It ran nine fixes through the year (PRs #257/#258 → #260 → #317
  // → #322 → #337 → #342 → #353 → #360) trying to keep an SVG path animated
  // in sync with runtime DOM measurement of the circuit frame. Every fix
  // patched a layer of an architecture that always raced — ResizeObservers
  // re-firing into MutationObservers, getTotalLength polling, font-load
  // awaits, WAAPI vs CSS-keyframe priority dances on position:fixed
  // ancestors. The whole class of bugs is gone now: the new chrome is N
  // visually-nested <div> boxes emitted by circuitGroupHTML(), animated by
  // pure CSS keyframes (`v1-pulse`) declared in styles.css. No JS animation,
  // no measurement, no observers, no retries. The mockup that drove this
  // is `docs/design/mockups/circuit-nested-boxes.html` (variant 1, outward
  // ripple). The exported PDF inherits the same nested-box DOM but the
  // animation is suppressed in the `html.is-exporting` / `.lobby-export-page`
  // contexts so a static frame rasterises.

  /**
   * Round 6 — compose the dose-line via the central formatReps() +
   * formatHold() helpers exposed on `window.HomefitLobbyHandoff` (set
   * up by app.js). Single source of truth so the lobby and the deck's
   * active-slide-header always agree on:
   *   - `N × R reps` (uniform) vs `R1/R2/R3 reps` (varying)
   *   - hold-mode parenthetical: `Ns hold (per rep)` (per_rep) /
   *     `Ns hold (per set)` (end_of_set, default) /
   *     `Ns hold (after last rep)` (end_of_exercise)
   *
   * Round 7 — sets sourced via `allSetsForSlide()` (NOT
   * `playSetsForSlide()`). The lobby groups circuits and renders ONE
   * row per exercise across all rounds, so we need every authored set,
   * regardless of `slide.circuitRound`. The deck path stays on
   * `playSetsForSlide()` because per-round filtering is correct there.
   * Pre-Round-7 bug: a pyramid-in-circuit (e.g. [12,10,8]) rendered as
   * `1 × 12 reps` because the deck's circuit filter returned only the
   * first round's single set.
   *
   * Photos use the same hold rules; if the photo lacks a sets[] array
   * (legacy fallback), allSetsForSlide() synthesises a default-mode
   * single set so formatHold() emits the unqualified `Ns hold (per set)`
   * form — matching the brief's "fall back gracefully to the legacy
   * holdSeconds scalar" requirement.
   */
  function buildDoseLine(slide) {
    if (!slide || slide.media_type === 'rest') return '';
    const setsResolver = api.allSetsForSlide || api.playSetsForSlide;
    if (slide.media_type === 'photo' || slide.media_type === 'image') {
      const playSets = setsResolver ? setsResolver(slide) : [];
      const hold = (api.formatHold && api.formatHold(playSets)) || '';
      if (hold) return hold;
      return 'Reference position';
    }
    const playSets = setsResolver ? setsResolver(slide) : [];
    if (!playSets.length) return '';

    const breathersList = playSets.map((s) => s.breather_seconds_after || 0);
    const breathersUniform = breathersList.every((b) => b === breathersList[0]);

    const parts = [];

    // Reps shape — `N × R reps` (uniform) / `R1/R2/R3 reps` (varying).
    const repsSeg = (api.formatReps && api.formatReps(playSets)) || '';
    if (repsSeg) parts.push(repsSeg);

    // Hold (mode-aware via formatHold()).
    const holdSeg = (api.formatHold && api.formatHold(playSets)) || '';
    if (holdSeg) parts.push(holdSeg);

    // Weight (Wave Lobby-Weight, 2026-05-05) — mirrors the deck's
    // active-slide-header. `@ 15 kg` (uniform) / `@ 12.5/15 kg` (varying).
    // All-bodyweight → empty (no segment).
    const weightSeg = (api.formatWeight && api.formatWeight(playSets)) || '';
    if (weightSeg) parts.push(weightSeg);

    // Inter-set rest.
    if (breathersUniform && breathersList[0] > 0) {
      parts.push(`${breathersList[0]}s rest`);
    }

    // Estimated duration.
    const dur = (api.calculateDuration && api.calculateDuration(slide)) || 0;
    if (dur > 0) parts.push(`~${formatDur(dur)}`);

    return parts.join(' · ');
  }

  function pickHeroOffset(slide) {
    if (!slide) return 0.5;
    if (slide.hero_crop_offset == null) return 0.5;
    const n = Number(slide.hero_crop_offset);
    if (!Number.isFinite(n)) return 0.5;
    return Math.max(0, Math.min(1, n));
  }

  function formatDur(seconds) {
    const sec = Math.max(0, Math.round(seconds));
    if (sec < 60) return `${sec}s`;
    const m = Math.floor(sec / 60);
    const s = sec % 60;
    return `${m}:${String(s).padStart(2, '0')}`;
  }

  /**
   * Render the hero element for a slide on the lobby surface. Delegates
   * to `window.HomefitHero.resolve` (web-player/exercise_hero.js) which
   * picks the treatment-correct primary URL + poster URL + caps for
   * THIS exercise. Photos always render as <img>. Videos render as
   * <img> with `data-video-src` carrying the mp4; the scroll-driven
   * `swapToVideoOnActiveRow` lifts it to <video> on the active row
   * only.
   *
   * Hero-resolver no-fallback refactor (2026-05-14): the resolver
   * derives treatment + body-focus internally from
   * `slide.preferred_treatment` / `slide.body_focus`. The lobby's
   * treatment-pill picker mutates those fields on the in-memory
   * slide (via `applyTreatmentOverrideToAllExercises` in app.js)
   * BEFORE this function runs. When the requested treatment isn't
   * available the resolver returns `mediaTag: 'unavailable'` and
   * the row renders a coral-tinted placeholder — NEVER a different
   * treatment's content.
   *
   * Hero-crop resolver refactor (2026-05-16): the `<img>` no longer
   * carries `style="object-position: ..."`. The per-hero crop metadata
   * (source URL, exercise id, treatment, hero_crop_offset) is stamped
   * onto `data-*` attributes; `hydrateHeroCrops` walks each freshly-
   * rendered hero and, via `window.HomefitHeroResolver`, replaces
   * `<img src>` with a 1:1 data URL whose intrinsic dimensions ARE the
   * square crop. The live lobby still honours the practitioner's chosen
   * offset; html2canvas + the PDF export inherit the fix because by
   * export time the live `<img src>` IS the square crop.
   */
  function renderHeroHTML(slide) {
    const escape = api.escapeHTML;
    if (!slide) return `<div class="lobby-hero-skeleton" aria-hidden="true"></div>`;
    if (!window.HomefitHero || !window.HomefitHero.resolve) {
      // Defensive — exercise_hero.js failed to load.
      return `<div class="lobby-hero-skeleton" aria-hidden="true"></div>`;
    }

    const hero = window.HomefitHero.resolve(slide, { surface: 'lobby' });

    if (hero.mediaTag === 'skeleton') {
      return `<div class="lobby-hero-skeleton" aria-hidden="true"></div>`;
    }

    if (hero.mediaTag === 'unavailable') {
      // Treatment not available — render the no-fallback placeholder
      // with the exercise name + requested treatment label. NEVER
      // substitute a different treatment.
      return `
        <div class="hero-not-available lobby-hero-media"
             aria-hidden="true"
             data-treatment="${escape(hero.treatment)}">
          <div class="hero-not-available-name">${escape(slide.name || 'Exercise')}</div>
          <div class="hero-not-available-sub">${escape(hero.treatment.toUpperCase())} not available</div>
        </div>
      `;
    }

    const isPhoto = slide.media_type === 'photo' || slide.media_type === 'image';
    const grayscale = hero.domClass ? ' ' + hero.domClass : '';

    // Crop metadata for the post-render hydrate pass. The resolver
    // reads `data-hero-source` (the per-treatment thumbnail JPG URL)
    // and `data-hero-offset` (clamped 0..1, default 0.5) to produce
    // the cropped 1:1 data URL. The initial `<img src>` is the raw
    // source URL — the parent `.lobby-hero { aspect-ratio: 1/1;
    // overflow: hidden; }` reserves the slot, and the brief un-cropped
    // flash before hydration is clipped to the square viewport.
    // Typical hydrate time is < 50ms on a 540×540 target so the flash
    // is negligible.
    const heroOffset = pickHeroOffset(slide);
    const heroId = escape(String(slide.id || ''));

    if (isPhoto) {
      // Photos are always static <img>. CSS .is-grayscale handles B&W.
      // loading="eager" (not "lazy") — kept from a prior attempt at
      // fixing the circuit animation (when the SVG tracer needed the
      // hero images decoded so the frame measurement was stable). The
      // nested-box chrome no longer needs that, but ~30 small JPGs per
      // plan is fine on cellular and avoiding lazy-load makes scroll
      // less janky, so the choice stays.
      const src = hero.src || hero.posterSrc || '';
      return `
        <img class="lobby-hero-media${grayscale}"
             src="${escape(src)}"
             alt="${escape(slide.name || 'Exercise')}"
             loading="eager"
             data-treatment="${escape(hero.treatment)}"
             data-hero-id="${heroId}"
             data-hero-offset="${heroOffset}"
             data-hero-source="${escape(src)}">
      `;
    }

    // Video. Render <img> as the static placeholder;
    // swapToVideoOnActiveRow lifts it to <video> when the row becomes
    // active. The mp4 URL travels on `data-video-src` — NEVER on
    // `<img src>` (iOS WKWebView mp4-in-img trap).
    // loading="eager" — historical: the SEVENTH-attempt SVG-tracer fix needed
    // synchronous image decode to measure circuit-frame bounds. The tracer
    // is gone (attempt #10 went to nested DOM boxes) but the eager loading
    // is still load-bearing for poster-to-video swap timing.
    //
    // `data-poster-src` mirrors `<img src>` for the swap-to-video path.
    // hydrateHeroCrops keeps the two in sync after the data URL swap so
    // `swapToVideoOnActiveRow` reads the cropped poster into the
    // `<video poster>` attribute.
    const videoSrc = hero.videoSrc || '';
    const posterSrc = hero.posterSrc || '';
    return `
      <img class="lobby-hero-media${grayscale}"
           src="${escape(posterSrc)}"
           alt="${escape(slide.name || 'Exercise')}"
           loading="eager"
           data-treatment="${escape(hero.treatment)}"
           data-video-src="${escape(videoSrc)}"
           data-poster-src="${escape(posterSrc)}"
           data-hero-id="${heroId}"
           data-hero-offset="${heroOffset}"
           data-hero-source="${escape(posterSrc)}"
           data-trim-start="${Number(slide.start_offset_ms) || 0}"
           data-trim-end="${Number(slide.end_offset_ms) || 0}">
    `;
  }

  /**
   * Walk the just-rendered hero imgs and replace each `<img src>` with
   * a square (1:1) JPEG data URL produced by HomefitHeroResolver. Runs
   * after $lobbyList.innerHTML = ... but BEFORE the user typically
   * sees the row settle (the parent `.lobby-hero { aspect-ratio: 1/1;
   * overflow: hidden; }` reserves the slot, and the un-cropped flash
   * before swap is clipped to the square viewport).
   *
   * Treatment-switch / re-render hits the resolver's cache — same
   * (exerciseId, treatment, offset, targetSize) tuple returns the
   * memoised data URL on subsequent calls.
   *
   * PDF export inheritance: the live `<img src>` is the data URL by
   * the time triggerLobbyShare's cloneNode runs, so the export path
   * sees the same crop with no extra work. html2canvas just rasterises
   * the already-square bitmap.
   *
   * Failure mode: the resolver propagates real image-load errors via
   * Promise rejection; we let those bubble (no try/catch — per
   * `feedback_no_exception_control_flow.md`). The existing capture-
   * phase `error` listener on the lobby root (signed-URL expiry
   * recovery) handles legitimate 403 / network failures by re-fetching
   * the plan and swapping data-src. A rejected resolver promise
   * leaves the un-cropped src in place — degraded but not broken.
   */
  function hydrateHeroCrops() {
    if (!$lobbyList) return;
    if (!window.HomefitHeroResolver || !window.HomefitHeroResolver.getHeroSquareImage) {
      // Defensive — hero_resolver.js failed to load. The live lobby
      // would still render un-cropped images (acceptable degraded
      // state — no offset honouring, but the parent's `overflow:
      // hidden` keeps the layout intact).
      return;
    }
    const heros = $lobbyList.querySelectorAll(
      'img.lobby-hero-media[data-hero-source]'
    );
    heros.forEach((img) => {
      const source = img.dataset.heroSource || '';
      if (!source) return;
      // Already a data URL → resolved by a previous hydrate pass.
      // Idempotent on re-runs (treatment switch, re-render) — short-
      // circuit avoids redoing the resolver cache lookup.
      if (source.startsWith('data:')) return;
      const id = img.dataset.heroId || '';
      const treatment = img.dataset.treatment || '';
      const offset = Number(img.dataset.heroOffset);
      // Target size: lobby thumbnails render at ~40% of viewport
      // width (the `.lobby-hero { flex: 0 0 40%; }` rule), capped by
      // the row's natural slot. 540px on the long edge gives a crisp
      // retina-grade square (canvas backing store is 540 * dpr) and
      // keeps the data URL around ~80KB per hero — fine for the PDF
      // export's per-page budget. The PDF rasteriser operates at
      // scale=2 against the already-square bitmap, so the rendered
      // pixels are plenty for A4 print fidelity.
      const targetSize = 540;
      window.HomefitHeroResolver.getHeroSquareImage({
        exerciseId: id,
        treatment: treatment,
        sourceUrl: source,
        heroCropOffset: Number.isFinite(offset) ? offset : 0.5,
        targetSize: targetSize,
      }).then((dataUrl) => {
        if (!dataUrl) return;
        // Re-check the element is still in the DOM — a treatment
        // switch between dispatch and resolution would have replaced
        // it via innerHTML. The new row's hydrate pass starts fresh
        // against the same source URL (cache hit, no re-crop).
        if (!img.isConnected) return;
        img.src = dataUrl;
        img.dataset.heroSource = dataUrl;
        // Keep data-poster-src in sync so the swap-to-video path
        // picks the cropped poster up when this row becomes active.
        if (img.dataset.posterSrc) {
          img.dataset.posterSrc = dataUrl;
        }
      });
    });
  }

  // ==========================================================================
  // Round 6 — Fix 5: lobby hero signed-URL 403 recovery
  // ==========================================================================
  //
  // Tracks <video> elements that already retried in this session so
  // we don't hammer the RPC on a permanent black-frame condition (eg.
  // the file genuinely 404s rather than the URL having expired). The
  // Set is keyed by the slide id resolved off the row's
  // `data-slide-index` attribute.
  const _lobbyHeroRetried = new Set();
  let _lobbyRefreshInFlight = false;

  async function onLobbyHeroError(evt) {
    const target = evt && evt.target;
    if (!target || target.tagName !== 'VIDEO') return;
    // The error fires for any non-fatal hiccup (eg. mid-fetch network
    // blip) too. We only care when there's a `src` set — empty src
    // means the scroll coupler hasn't lit this row yet.
    const src = target.currentSrc || target.getAttribute('src') || '';
    if (!src) return;
    const row = target.closest('.lobby-row[data-slide-index]');
    if (!row) return;
    const slideIdx = parseInt(row.getAttribute('data-slide-index'), 10);
    if (Number.isNaN(slideIdx)) return;
    const slide = slides[slideIdx];
    if (!slide || !slide.id) return;
    if (_lobbyHeroRetried.has(slide.id)) return;
    _lobbyHeroRetried.add(slide.id);

    if (!api || !api.reFetchPlan) return;

    try {
      // Coalesce simultaneous errors across multiple visible heroes
      // into ONE plan re-fetch.
      if (!_lobbyRefreshInFlight) {
        _lobbyRefreshInFlight = true;
        const fresh = await api.reFetchPlan();
        _lobbyRefreshInFlight = false;
        if (fresh && fresh.slides) {
          slides = fresh.slides;
        }
      } else {
        // Another error already kicked off the re-fetch — wait a tick
        // and re-read the (now-updated) `slides` reference.
        await new Promise((resolve) => {
          setTimeout(() => {
            cb('heroErrorRetry', resolve);
          }, 50);
        });
      }

      // Re-resolve the URL for THIS row's slide. The resolver derives
      // treatment from `refreshed.preferred_treatment` internally
      // (hero-resolver no-fallback refactor, 2026-05-14).
      const refreshed = slides[slideIdx];
      if (!refreshed) return;
      const newUrl = api.resolveTreatmentUrl
        ? api.resolveTreatmentUrl(refreshed)
        : (refreshed.line_drawing_url || refreshed.thumbnail_url || null);
      if (!newUrl) return;
      // Update data-video-src AND src on the live <video>. The data attr
      // is what swapToVideoOnActiveRow reads when re-creating the element
      // on next active-row enter, so a future swap-back-then-swap-in
      // round-trip (e.g. user scrolls away and back) gets the fresh URL.
      target.setAttribute('data-video-src', newUrl);
      target.setAttribute('src', newUrl);
      // Reload + resume. If the row isn't in the viewport the
      // playback will pause again on the next coupler tick, but the
      // URL is now fresh for the next enter.
      try { target.load(); } catch (_) { /* best-effort */ }
      const tryPlay = target.play();
      if (tryPlay && typeof tryPlay.catch === 'function') {
        tryPlay.catch(() => { /* autoplay denied — couplet will retry */ });
      }
    } catch (err) {
      _lobbyRefreshInFlight = false;
      try { console.warn('[homefit-lobby] hero refresh failed:', err); } catch (_) {}
    }
  }

  // ==========================================================================
  // Treatment + body-focus + reset (Lobby-settings-unify, 2026-05-14)
  // ==========================================================================
  //
  // The lobby gear popover hosts the SAME unified panel as the deck:
  // treatment selector, body-focus toggle, "Reset to practitioner"
  // button. Everything writes a PLAN-SCOPED override; toggling here is
  // equivalent to toggling on the deck gear, and one tap re-renders
  // every row in the lobby + the post-handoff deck.
  //
  // The painter lives in app.js (`paintGearPanel(rootEl)`) and is
  // exposed via `api.paintGearPanel`. The lobby's job is:
  //   1. Append lock glyphs to consent-locked treatment pills (still
  //      lobby-specific UX — deck doesn't render the lock glyph),
  //      then ask app.js to paint the rest of the panel state.
  //   2. Click-delegate inside the popover: pills, body-focus btn,
  //      reset btn. All three call into app.js handlers; this file
  //      only adds the "locked pill → self-grant modal" branch.
  //   3. On any successful pick: re-render the hero list so the rows
  //      pick up the new resolver state.

  function renderTreatmentRow() {
    if (!$lobbyTreatmentPills) return;
    // Lobby-only chrome: append a lock glyph + data-locked attr to
    // consent-locked pills so the gear popover's pills carry the
    // self-grant affordance. (The deck popover has no equivalent —
    // there's no self-grant path mid-workout.)
    const pillButtons = $lobbyTreatmentPills.querySelectorAll('.treatment-pills > button[data-value]');
    pillButtons.forEach((btn) => {
      const value = btn.getAttribute('data-value');
      if (!btn.querySelector('.lobby-lock')) {
        const lock = document.createElement('span');
        lock.className = 'lobby-lock';
        lock.setAttribute('aria-hidden', 'true');
        lock.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><rect x="5" y="11" width="14" height="9" rx="2"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/></svg>';
        btn.appendChild(lock);
      }
      const locked = isLockedTreatment(value);
      btn.setAttribute('data-locked', locked ? 'true' : 'false');
    });
    // Defer to the shared painter for active/overridden/disabled state.
    if (api.paintGearPanel) api.paintGearPanel($lobbySettingsPopover);
    // Reflect the plan-scoped active treatment in the lobby's own
    // shadow state (used by the legacy `activeTreatment` reads further
    // up — kept for analytics continuity).
    if (api.getEffective && slides.length) {
      let referenceSlide = null;
      for (let i = 0; i < slides.length; i++) {
        const s = slides[i];
        if (s && s.media_type !== 'rest') { referenceSlide = s; break; }
      }
      if (referenceSlide) {
        activeTreatment = api.getEffective(referenceSlide, 'treatment') || 'line';
      }
    }
  }

  function isLockedTreatment(value) {
    if (value === 'line') return false;
    if (value === 'bw') return !(api.planHasGrayscaleConsent && api.planHasGrayscaleConsent());
    if (value === 'original') return !(api.planHasOriginalConsent && api.planHasOriginalConsent());
    return false;
  }

  function onTreatmentClick(value) {
    // Locked pill → self-grant modal. Round 4 UX choice: close the
    // popover so the modal owns the spotlight (no competing chrome).
    if (isLockedTreatment(value)) {
      closeLobbySettingsPopover();
      openSelfGrantModal(value === 'bw' ? 'grayscale' : 'original');
      return;
    }
    // Tapping the already-active pill → just close the popover (no
    // hero re-render, no analytics ping). Round 4 one-tap-to-pick UX.
    if (value === activeTreatment) {
      closeLobbySettingsPopover();
      return;
    }
    const previous = activeTreatment;
    activeTreatment = value;
    // Plan-scoped write — same handler the deck gear pill uses, so the
    // lobby pill + deck gear pill stay in lock-step.
    if (api.applyTreatmentOverrideToAllExercises) {
      api.applyTreatmentOverrideToAllExercises(value);
    }
    if (api.emitAnalyticsEvent && previous !== value) {
      const fromWire = previous === 'bw' ? 'grayscale' : previous;
      const toWire = value === 'bw' ? 'grayscale' : value;
      api.emitAnalyticsEvent('treatment_changed', null, {
        from: fromWire, to: toWire, source: 'lobby',
      });
    }
    renderTreatmentRow();
    if (api.paintGearPanel) api.paintGearPanel($lobbySettingsPopover);
    renderList();
    // Reset active sentinel so the post-render reducer paints a fresh
    // active state (the previous DOM is gone, so the cached idx is
    // stale). recomputeActiveRow() picks the row whose centre is closest
    // to the viewport centre — same row in practice, but the highlight
    // gets re-applied to the new DOM nodes.
    activeRowIndex = -1;
    requestAnimationFrame(() => {
      cb('treatmentRaf', () => {
        activateInitialRow();
        recomputeActiveRow();
      });
    });
    // Round 4 — close the popover after a successful pick. One-tap UX.
    closeLobbySettingsPopover();
  }

  /** Lobby body-focus toggle — plan-scoped write, then re-paint +
   *  re-render lobby. Deck rebinds happen inside the app.js handler. */
  function onLobbyBodyFocusClick() {
    if (!api.onGearBodyFocusClickLobby) return;
    api.onGearBodyFocusClickLobby();
    renderTreatmentRow();
    // Re-render lobby rows so the body-focus state shows up in heroes.
    renderList();
    activeRowIndex = -1;
    requestAnimationFrame(() => {
      cb('lobbyBodyFocusRaf', () => {
        activateInitialRow();
        recomputeActiveRow();
      });
    });
  }

  /** Lobby reset — clears the plan-scoped override and restores each
   *  slide's practitioner-original treatment + body-focus. Re-renders
   *  the lobby so heroes return to the mixed-treatment original state. */
  function onLobbyResetClick() {
    if (!api.onGearResetClick) return;
    api.onGearResetClick();
    renderTreatmentRow();
    renderList();
    activeRowIndex = -1;
    requestAnimationFrame(() => {
      cb('lobbyResetRaf', () => {
        activateInitialRow();
        recomputeActiveRow();
      });
    });
    // Round 4 UX — close popover after reset.
    closeLobbySettingsPopover();
  }

  // ==========================================================================
  // Lobby settings popover (gear-anchored, opens upward)
  // ==========================================================================
  //
  // Round 4 (2026-05-04): the treatment row used to live inline above
  // the Start button. It now hides behind a gear in the sticky CTA bar.
  // Practitioners pre-set per-exercise `preferred_treatment` per client,
  // so 95% of clients never need the global override — the gear pattern
  // earns it back its premium spot only when actually needed.
  //
  // Behaviour:
  //   - Gear tap toggles open/closed.
  //   - Outside-tap closes (capture-phase document listener).
  //   - Escape closes (a11y).
  //   - A treatment pick closes (one-tap-to-pick).
  //   - A locked-pill tap closes BEFORE the self-grant modal opens
  //     (the modal owns the spotlight).
  //
  // Implementation note: the popover element is `position: absolute`
  // INSIDE `.lobby-cta-bar`, so it inherits the bar's stacking context
  // and slides up via CSS (no JS positioning). aria-expanded mirrors
  // the gear button's state so screen readers know what's happening.

  function isLobbySettingsPopoverOpen() {
    if (!$lobbySettingsPopover) return false;
    return $lobbySettingsPopover.getAttribute('data-open') === 'true';
  }

  // BUG 14 fix (2026-05-15): on iOS WKWebView the popover's
  // `position: absolute; bottom: calc(100% + 8px)` inside the
  // `position: fixed` `.lobby-cta-bar` rendered partially offscreen —
  // the absolute coordinate space inherited from the fixed bar didn't
  // line up the way Safari paints it on the live web player. Switch to
  // `position: fixed` with viewport-aware coordinates computed from the
  // gear button's clientRect on every open. Any prior inline `position`
  // / `top` / `left` / `right` / `bottom` is cleared on close so the
  // stylesheet's static absolute layout stays the desktop fallback if
  // JS positioning is ever skipped.
  function repositionLobbySettingsPopover() {
    if (!$lobbySettingsPopover || !$lobbyGearBtn) return;
    var gearRect = $lobbyGearBtn.getBoundingClientRect();
    if (!gearRect) return;
    // Render once invisibly to measure the popover's intrinsic size.
    var prevVisibility = $lobbySettingsPopover.style.visibility;
    $lobbySettingsPopover.style.visibility = 'hidden';
    // 2026-05-15: every position-related property goes via setProperty
    // with 'important' so the cascade has zero ambiguity. PR #343 left
    // the popover inheriting the deck's landscape rules (top:134px;
    // right:8px) via the shared `.settings-popover` class even though
    // that class has now been dropped from the element. Belt-and-braces:
    // if any stylesheet ever reintroduces a positional rule for any
    // ancestor / variant class, !important on the JS-set values keeps
    // this popover anchored to the gear button regardless.
    $lobbySettingsPopover.style.setProperty('position', 'fixed', 'important');
    $lobbySettingsPopover.style.setProperty('right', 'auto', 'important');
    $lobbySettingsPopover.style.setProperty('bottom', 'auto', 'important');
    $lobbySettingsPopover.style.setProperty('top', '0px', 'important');
    $lobbySettingsPopover.style.setProperty('left', '0px', 'important');
    var popRect = $lobbySettingsPopover.getBoundingClientRect();
    var popW = popRect.width || 280;
    var popH = popRect.height || 180;
    var viewportW = window.innerWidth || document.documentElement.clientWidth || 0;
    var viewportH = window.innerHeight || document.documentElement.clientHeight || 0;
    // Anchor the popover so its bottom-right corner sits 8px above the
    // gear's top-right corner. Clamp to a 16px viewport margin so it
    // can't run off-screen on narrow phones.
    var gap = 8;
    var margin = 16;
    var left = Math.round(gearRect.right - popW);
    if (left < margin) left = margin;
    if (left + popW > viewportW - margin) left = Math.max(margin, viewportW - margin - popW);
    var top = Math.round(gearRect.top - gap - popH);
    if (top < margin) top = margin;
    if (top + popH > viewportH - margin) top = Math.max(margin, viewportH - margin - popH);
    $lobbySettingsPopover.style.setProperty('left', left + 'px', 'important');
    $lobbySettingsPopover.style.setProperty('top', top + 'px', 'important');
    $lobbySettingsPopover.style.visibility = prevVisibility || '';
  }

  function clearLobbySettingsPopoverPosition() {
    if (!$lobbySettingsPopover) return;
    // 2026-05-15: `removeProperty` is the correct mirror to
    // `setProperty(..., 'important')` — assigning '' to style.X leaves
    // any !important flag in place on some browsers. Strip every
    // position-related override cleanly so the stylesheet (lobby base
    // rules: position:fixed; no top/left) wins on the next paint.
    $lobbySettingsPopover.style.removeProperty('position');
    $lobbySettingsPopover.style.removeProperty('top');
    $lobbySettingsPopover.style.removeProperty('left');
    $lobbySettingsPopover.style.removeProperty('right');
    $lobbySettingsPopover.style.removeProperty('bottom');
    $lobbySettingsPopover.style.removeProperty('visibility');
  }

  function openLobbySettingsPopover() {
    if (!$lobbySettingsPopover || !$lobbyGearBtn) return;
    if (isLobbySettingsPopoverOpen()) return;
    $lobbySettingsPopover.hidden = false;
    // Paint state on open so the panel reflects the current
    // plan-scoped override + practitioner defaults. Mirrors the deck's
    // `setSettingsPopoverOpen(true)` behaviour.
    if (api && api.paintGearPanel) api.paintGearPanel($lobbySettingsPopover);
    // Reposition before the transition starts so the popover slides up
    // from the correct anchor instead of jumping after open.
    repositionLobbySettingsPopover();
    // Tick to let the browser paint `display:block` before the
    // opacity/transform transition kicks in.
    requestAnimationFrame(() => {
      cb('popoverOpenRaf', () => {
        $lobbySettingsPopover.setAttribute('data-open', 'true');
      });
    });
    $lobbyGearBtn.setAttribute('aria-expanded', 'true');
  }

  function closeLobbySettingsPopover() {
    if (!$lobbySettingsPopover || !$lobbyGearBtn) return;
    if (!isLobbySettingsPopoverOpen()) {
      // If we're not open, still ensure aria + hidden agree.
      $lobbyGearBtn.setAttribute('aria-expanded', 'false');
      $lobbySettingsPopover.hidden = true;
      clearLobbySettingsPopoverPosition();
      return;
    }
    $lobbySettingsPopover.removeAttribute('data-open');
    $lobbyGearBtn.setAttribute('aria-expanded', 'false');
    // Wait for the transition to finish before adding `hidden` back —
    // otherwise the close is a hard pop. Match the CSS `160ms`.
    setTimeout(() => {
      cb('popoverCloseTimeout', () => {
        // Guard against a re-open that happened during the transition.
        if (!isLobbySettingsPopoverOpen()) {
          $lobbySettingsPopover.hidden = true;
          clearLobbySettingsPopoverPosition();
        }
      });
    }, 180);
  }

  function toggleLobbySettingsPopover() {
    if (isLobbySettingsPopoverOpen()) {
      closeLobbySettingsPopover();
    } else {
      openLobbySettingsPopover();
    }
  }

  // ==========================================================================
  // Self-grant modal
  // ==========================================================================

  function openSelfGrantModal(kind) {
    pendingGrantKind = kind;
    const isBW = kind === 'grayscale';
    $selfGrantTitle.textContent = isBW ? 'Allow B&W playback?' : 'Allow full-colour playback?';
    $selfGrantName.textContent = (plan && plan.client_name) || 'this client';
    const treatmentLabel = isBW ? 'B&W' : 'full-colour';
    $selfGrantBody.textContent =
      `Your practitioner has line-drawing only enabled. Allow them to also show you ${treatmentLabel} footage of your exercises?`;
    $selfGrantError.hidden = true;
    $selfGrantError.textContent = '';
    $selfGrantAllow.removeAttribute('aria-disabled');
    $selfGrantAllow.disabled = false;
    $selfGrantModal.hidden = false;
  }

  function closeSelfGrantModal() {
    $selfGrantModal.hidden = true;
    pendingGrantKind = null;
  }

  async function onAllowSelfGrant() {
    if (!pendingGrantKind || !plan || !plan.id) return;
    if (!window.HomefitApi || !window.HomefitApi.clientSelfGrantConsent) {
      $selfGrantError.textContent = 'Cannot reach server right now. Try again.';
      $selfGrantError.hidden = false;
      return;
    }
    $selfGrantAllow.setAttribute('aria-disabled', 'true');
    $selfGrantAllow.disabled = true;
    $selfGrantError.hidden = true;

    const result = await window.HomefitApi.clientSelfGrantConsent(plan.id, pendingGrantKind);
    if (!result || !result.ok) {
      $selfGrantError.textContent = 'Could not grant consent. Please try again.';
      $selfGrantError.hidden = false;
      $selfGrantAllow.removeAttribute('aria-disabled');
      $selfGrantAllow.disabled = false;
      return;
    }

    // Refetch plan so signed URLs for the newly-granted treatment land in
    // the cached state. app.js handles the re-render.
    if (api.reFetchPlan) {
      try {
        const refreshed = await api.reFetchPlan();
        if (refreshed && refreshed.plan) plan = refreshed.plan;
        if (refreshed && refreshed.slides) slides = refreshed.slides;
      } catch (_) { /* fall through; we keep the current state */ }
    }

    // Now switch the active treatment to the just-granted one.
    activeTreatment = pendingGrantKind === 'grayscale' ? 'bw' : 'original';
    if (api.applyTreatmentOverrideToAllExercises) {
      api.applyTreatmentOverrideToAllExercises(activeTreatment);
    }
    renderTreatmentRow();
    renderList();
    activeRowIndex = -1;
    requestAnimationFrame(() => {
      cb('selfGrantRaf', () => {
        activateInitialRow();
        recomputeActiveRow();
      });
    });
    closeSelfGrantModal();
  }

  // ==========================================================================
  // Row ↔ matrix coupling (scroll-driven, single-active-row reducer)
  // ==========================================================================
  //
  // The first cut used IntersectionObserver with a rootMargin pulling the
  // crossing line down 40% of the viewport. Two real bugs surfaced on
  // device QA:
  //
  //   1. At scroll-top, the first row sits ABOVE the artificial
  //      crossing line — so the observer never fires for it and the
  //      matrix renders unhighlighted until the user scrolls past row 1.
  //
  //   2. Multiple rows can cross the line simultaneously (or near-tie on
  //      ratio), causing the active pill to flicker between neighbours.
  //
  // Replacement: rAF-throttled scroll handler + a deterministic reducer
  // that picks the row whose VERTICAL CENTRE is closest to the scroll
  // container's vertical centre. Single winner per scroll frame, no
  // threshold ambiguity. Plus we activate the first non-rest row at
  // mount so something is always highlighted before the first scroll.

  function setupScrollCoupling() {
    scrollContainer = document.querySelector('.lobby-inner');
    if (!scrollContainer) return;
    if (scrollListenerWired) return;
    scrollListenerWired = true;

    const onScroll = () => {
      if (scrollRafToken != null) return;
      scrollRafToken = requestAnimationFrame(() => {
        scrollRafToken = null;
        cb('scrollRaf', recomputeActiveRow);
      });
    };
    scrollContainer.addEventListener('scroll', onScroll, { passive: true });
    // Resize / orientation changes also shift centres.
    window.addEventListener('resize', onScroll, { passive: true });
  }

  function activateInitialRow() {
    // Pick the first non-rest row as the default active row. Falls
    // through to whatever row is at the top of the list if everything is
    // rest (impossible in real plans, cheap defence). This fires before
    // the user's first scroll so the matrix is never unhighlighted.
    const rows = $lobbyList.querySelectorAll('.lobby-row[data-slide-index]');
    if (!rows.length) return;
    let target = null;
    for (let i = 0; i < rows.length; i++) {
      if (!rows[i].classList.contains('is-rest')) { target = rows[i]; break; }
    }
    if (!target) target = rows[0];
    setActiveRow(target);
  }

  function recomputeActiveRow() {
    if (!cbBump('recomputeActiveRow')) return;
    if (!scrollContainer) return;
    const rows = $lobbyList.querySelectorAll('.lobby-row[data-slide-index]');
    if (!rows.length) return;

    // Round 7 — Fix 3 — symmetric scroll-top guard. Mirror of the
    // scroll-bottom guard below. At scroll position 0 the first row's
    // centre sits ~80–100px below the viewport top while the viewport
    // centre is ~400px down, so the second row wins the nearest-to-
    // centre reducer and the first row's pill never highlights when
    // the user scrolls back up to the top. Detection: scrollTop within
    // ~4px of zero (matches the 4px tolerance on atBottom).
    const atTop = scrollContainer.scrollTop <= 4;
    if (atTop) {
      // Pick the first non-rest row (matches activateInitialRow's
      // semantics so the user's "scrolled back up" highlight matches
      // the page-load highlight). Falls back to the very first row if
      // every row is rest (impossible in real plans).
      let firstNonRest = null;
      for (let i = 0; i < rows.length; i++) {
        if (!rows[i].classList.contains('is-rest')) { firstNonRest = rows[i]; break; }
      }
      const target = firstNonRest || rows[0];
      if (target) setActiveRow(target);
      return;
    }

    // Hotfix round 3 — Fix E — scroll-bottom edge case for the last
    // row. The nearest-to-centre reducer below works for every row
    // except the last: at scroll-bottom there's no more scroll left
    // to bring the last row's centre up to viewport centre, so its
    // distance to centre stays > some interior row's distance and the
    // last pill never lights up. Detection: scroll position is within
    // ~4px of maxScrollTop (the floor).
    const atBottom = (scrollContainer.scrollTop + scrollContainer.clientHeight)
                     >= (scrollContainer.scrollHeight - 4);
    if (atBottom) {
      // Pick the last row that's at all visible (any vertical overlap
      // with the container). Falls back to the very last row in the
      // list if nothing intersects (degenerate empty-scroll case).
      const rootRectBottom = scrollContainer.getBoundingClientRect();
      let lastVisible = null;
      for (let i = rows.length - 1; i >= 0; i--) {
        const rect = rows[i].getBoundingClientRect();
        if (rect.bottom < rootRectBottom.top || rect.top > rootRectBottom.bottom) {
          continue;
        }
        lastVisible = rows[i];
        break;
      }
      const target = lastVisible || rows[rows.length - 1];
      if (target) setActiveRow(target);
      return;
    }

    // Viewport centre of the scroll container, in viewport coordinates.
    // getBoundingClientRect is robust against sticky / fixed offsets.
    const rootRect = scrollContainer.getBoundingClientRect();
    const viewportCentre = rootRect.top + rootRect.height / 2;

    let bestRow = null;
    let bestDist = Infinity;
    for (let i = 0; i < rows.length; i++) {
      const r = rows[i];
      const rect = r.getBoundingClientRect();
      // Skip rows that are fully outside the container (above OR below).
      if (rect.bottom < rootRect.top || rect.top > rootRect.bottom) continue;
      const rowCentre = rect.top + rect.height / 2;
      const dist = Math.abs(rowCentre - viewportCentre);
      if (dist < bestDist) {
        bestDist = dist;
        bestRow = r;
      }
    }
    if (bestRow) setActiveRow(bestRow);
  }

  function setActiveRow(row) {
    if (!cbBump('setActiveRow')) return;
    const idx = parseInt(row.getAttribute('data-slide-index'), 10);
    if (Number.isNaN(idx) || idx === activeRowIndex) return;
    activeRowIndex = idx;

    // Highlight the row + the matching pill.
    $lobbyList.querySelectorAll('.lobby-row.is-active-pill').forEach((el) => el.classList.remove('is-active-pill'));
    row.classList.add('is-active-pill');
    // Pill scroll-fill — fill all pills owned by rows at-or-before this
    // active row. For circuits, all rounds of the exercise fill together
    // (they share the same exercise.id, so all pills with the same row
    // ordinal cross the threshold simultaneously). Empties on scroll-back.
    updatePillFills(row);
    $lobbyMatrixInner.querySelectorAll('.pill.is-active').forEach((el) => el.classList.remove('is-active'));
    const targetPill = $lobbyMatrixInner.querySelector(`.pill[data-slide="${idx}"]`);
    if (targetPill) {
      targetPill.classList.add('is-active');
      // Centre-on-active — scroll the matrix horizontally so the active
      // pill is centred. Parity with the deck's matrix behaviour.
      //
      // Hotfix: skip when the pill is already visible inside the matrix
      // viewport, AND use instant scroll instead of smooth. iOS WKWebView's
      // smooth-scroll on this element interacts badly with the lobby's
      // rAF-throttled scroll handler — under sustained scrolling the
      // smooth-scroll animation fires repeated scroll events that re-enter
      // the handler chain, eventually pinning the JS event loop. Symptom:
      // WebView appears to "go black" 5-8s after a scroll, with no JS
      // errors and no network activity (heartbeat dies). Bypassing smooth
      // here breaks that loop without losing the centre-on-active visual.
      const matrixRect = $lobbyMatrixInner.getBoundingClientRect();
      const pillRect = targetPill.getBoundingClientRect();
      const pillVisible =
        pillRect.left >= matrixRect.left && pillRect.right <= matrixRect.right;
      if (!pillVisible) {
        try {
          targetPill.scrollIntoView({ inline: 'center', block: 'nearest', behavior: 'auto' });
        } catch (_) { /* older browsers */ }
      }
    }
    // Debounce video kick during fast scroll. Each active-row change
    // means: pause + clear src + load() on the previous active video,
    // then attach src + load() + play() on the new one. Under sustained
    // scrolling `setActiveRow` fires repeatedly, churning HW decoder
    // attach/detach. 150ms debounce: while the user keeps scrolling,
    // the timeout never fires; once they settle on a row, the kick
    // runs once for the settled row.
    if (_lazyKickToken != null) {
      clearTimeout(_lazyKickToken);
      _lazyKickToken = null;
    }
    const targetIdx = idx;
    _lazyKickToken = setTimeout(() => {
      _lazyKickToken = null;
      swapToVideoOnActiveRow(targetIdx);
    }, 150);
  }

  /**
   * Load metadata + start playback for the hero <video> element on the
   * ACTIVE row only. Aggressively clear src + call load() on every other
   * row's video to release HW H.264 decoders.
   *
   * Why single-active-video (was current ± 1, up to 3 simultaneously):
   * iOS allocates ~3–4 concurrent HW decoders per device, and embedded
   * WKWebView gets a stricter allocation than mobile Safari proper. The
   * lobby + the OS + whatever else holds decoders pushes the cap, the
   * media subsystem stalls, and the JS event loop dies with it (PR #250's
   * circuit-breaker confirmed the freeze is host-side: heartbeat dies
   * with no CB trip, JS counts stay low). Going single-active-video puts
   * us well under the cap regardless of what else the OS is decoding.
   *
   * Pause alone is NOT enough to release the HW decoder — the element
   * keeps the slot reserved until the source is dropped. We must clear
   * the `src` attribute AND call `load()` to fully tear down the
   * MediaSource and free the decoder. The `poster=` attribute on the
   * <video> element keeps the static Hero frame visible during this
   * teardown so the user never sees a black box.
   *
   * v48 STRUCTURAL FIX: instead of trying to manage a long-lived <video>
   * per row via src on/off + load(), we now ensure that ONLY the active
   * row contains a <video> element at all. Inactive rows render <img>.
   * Becoming active = swap <img> → <video> via parentNode.replaceChild;
   * losing focus = swap <video> → <img>. The orphaned <video> is GC'd
   * and its decoder slot fully reclaimed because the element no longer
   * exists in the document tree. iOS WKWebView can't keep a ghost
   * decoder alive on a node that isn't there.
   */
  function swapToVideoOnActiveRow(idx) {
    if (!cbBump('lazyKickVideosNear')) return;
    const rows = $lobbyList.querySelectorAll('.lobby-row[data-slide-index]');
    rows.forEach((row) => {
      const rIdx = parseInt(row.getAttribute('data-slide-index'), 10);
      const isActive = rIdx === idx;
      const hero = row.querySelector('.lobby-hero-media');
      if (!hero) return;
      // Skip photos — they were rendered as <img> already by the photo
      // branch in renderHeroHTML; the absence of `data-video-src` is
      // the marker.
      if (!hero.dataset.videoSrc) return;

      const isVideoTag = hero.tagName === 'VIDEO';

      if (isActive && !prefersReducedMotion()) {
        // Active row — must be a <video>. If currently an <img>, swap.
        if (isVideoTag) return; // Already a video; nothing to do.
        const v = document.createElement('video');
        v.className = hero.className;
        v.setAttribute('playsinline', '');
        v.muted = true;
        v.loop = true;
        v.preload = 'auto';
        v.style.cssText = hero.style.cssText;
        // Carry data-* across so the swap-back path knows what to restore.
        v.dataset.treatment = hero.dataset.treatment || '';
        v.dataset.videoSrc = hero.dataset.videoSrc;
        v.dataset.posterSrc = hero.dataset.posterSrc || '';
        v.dataset.trimStart = hero.dataset.trimStart || '0';
        v.dataset.trimEnd = hero.dataset.trimEnd || '0';
        // 2026-05-17 — carry hydrateHeroCrops metadata across the swap.
        // Without this, the swap-back below recreates an <img> with no
        // data-hero-* attributes, so hydrateHeroCrops skips it and the
        // raw (non-1:1) poster stretches into the 1:1 container under
        // the default object-fit:fill (PR #364 deliberately removed
        // object-fit:cover from `img.lobby-hero-media`, relying on the
        // hydrate path to produce a 1:1 data URL). The race surfaces
        // when the user scrolls fast — hydrate hasn't yet rewritten
        // data-poster-src to a data URL before the active-row toggle
        // swaps in the <video>, so the swap-back later inherits the
        // raw URL.
        v.dataset.heroId = hero.dataset.heroId || '';
        v.dataset.heroOffset = hero.dataset.heroOffset || '0.5';
        // Poster shows the static Hero frame while the video buffers; no
        // black flash during the decoder warm-up.
        if (v.dataset.posterSrc) v.setAttribute('poster', v.dataset.posterSrc);
        v.setAttribute('src', v.dataset.videoSrc);
        // Trim listeners — same loop semantics as before.
        const start = Number(v.dataset.trimStart) || 0;
        v.addEventListener('loadedmetadata', () => {
          if (start > 0) v.currentTime = Math.max(0, start / 1000);
        });
        v.addEventListener('timeupdate', () => {
          const end = Number(v.dataset.trimEnd) || 0;
          if (end > 0 && v.currentTime * 1000 >= end) {
            v.currentTime = Math.max(0, start / 1000);
          }
        });
        hero.parentNode.replaceChild(v, hero);
        const playPromise = v.play();
        if (playPromise && playPromise.catch) playPromise.catch(() => { /* autoplay blocked */ });
      } else {
        // Inactive row — must be an <img> (or skeleton if no poster).
        // If currently a <video>, swap back.
        if (!isVideoTag) return; // Already an img/skeleton; nothing to do.
        // Best-effort tear-down; the orphaned video gets GC'd anyway, but
        // pausing first stops audible playback if any.
        try { hero.pause(); } catch (_) {}
        const posterSrc = hero.dataset.posterSrc || hero.getAttribute('poster') || '';
        // No poster → swap back to a skeleton placeholder (NOT an <img>
        // with empty src; that shows broken-image, AND we MUST never put
        // a video URL in <img src> per the v51 fix).
        if (!posterSrc) {
          const skel = document.createElement('div');
          skel.className = 'lobby-hero-skeleton lobby-hero-media';
          skel.setAttribute('aria-hidden', 'true');
          skel.style.cssText = hero.style.cssText;
          skel.dataset.treatment = hero.dataset.treatment || '';
          skel.dataset.videoSrc = hero.dataset.videoSrc || '';
          skel.dataset.posterSrc = '';
          skel.dataset.trimStart = hero.dataset.trimStart || '0';
          skel.dataset.trimEnd = hero.dataset.trimEnd || '0';
          hero.parentNode.replaceChild(skel, hero);
          return;
        }
        const img = document.createElement('img');
        img.className = hero.className.replace(/\blobby-hero-skeleton\b/, '').trim();
        img.setAttribute('alt', '');
        img.setAttribute('loading', 'lazy');
        img.style.cssText = hero.style.cssText;
        img.dataset.treatment = hero.dataset.treatment || '';
        img.dataset.videoSrc = hero.dataset.videoSrc || '';
        img.dataset.posterSrc = posterSrc;
        img.dataset.trimStart = hero.dataset.trimStart || '0';
        img.dataset.trimEnd = hero.dataset.trimEnd || '0';
        // 2026-05-17 — attach hydrateHeroCrops metadata so the resolver
        // re-crops the raw poster into a 1:1 data URL after swap-back.
        // Without these data-hero-* attrs the new <img> is invisible to
        // hydrateHeroCrops, leaving the raw (non-1:1) poster stretched
        // in the 1:1 container under the default object-fit:fill. See
        // the swap-to-video branch above for the matching carry-across.
        img.dataset.heroId = hero.dataset.heroId || '';
        img.dataset.heroOffset = hero.dataset.heroOffset || '0.5';
        img.dataset.heroSource = posterSrc;
        img.setAttribute('src', posterSrc);
        hero.parentNode.replaceChild(img, hero);
      }
    });
    // 2026-05-17 — re-hydrate any freshly-swapped <img> so its src
    // crops to 1:1. Idempotent: hydrateHeroCrops short-circuits on
    // data: URLs already in flight via the resolver cache.
    hydrateHeroCrops();
  }

  function prefersReducedMotion() {
    try {
      return window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    } catch (_) { return false; }
  }

  // ==========================================================================
  // Event wiring
  // ==========================================================================

  function wireEvents() {
    if (!$lobbyStartBtn || $lobbyStartBtn._wired) return;
    $lobbyStartBtn._wired = true;
    $lobbyStartBtn.addEventListener('click', dismissLobbyAndStart);

    // Round 6 — Fix 5: lobby hero <video> 403 / signed-URL-expiry
    // recovery. The deck has its own delegated error handler on
    // `$cardViewport` (Wave-79 hardening) but lobby hero videos live
    // OUTSIDE that container, so a client who sits on the lobby past
    // the 30-min B&W / Original signed-URL TTL was hitting permanent
    // black frames. We listen for `error` events bubbling from the
    // lobby root (capture phase, since media-element `error` events
    // do NOT bubble through the normal phase). On error: re-fetch
    // the plan via `api.reFetchPlan()`, locate the matching slide
    // by id, swap `data-src` + `src` on the affected <video>, and
    // call `.load()` so the next viewport-enter triggers playback.
    // Idempotent — each <video> retries at most once per session.
    if ($lobbyList && !$lobbyList._heroErrorWired) {
      $lobbyList._heroErrorWired = true;
      $lobbyList.addEventListener('error', onLobbyHeroError, true);
    }

    if ($lobbyGearBtn && !$lobbyGearBtn._wired) {
      $lobbyGearBtn._wired = true;
      $lobbyGearBtn.addEventListener('click', (evt) => {
        // Stop the click from bubbling to the document outside-tap
        // listener below — otherwise the same tap would immediately
        // re-close the popover that just opened.
        evt.stopPropagation();
        toggleLobbySettingsPopover();
      });
    }

    if ($lobbyShareBtn && !$lobbyShareBtn._wired) {
      $lobbyShareBtn._wired = true;
      $lobbyShareBtn.addEventListener('click', (evt) => {
        evt.stopPropagation();
        // ALWAYS show the modal immediately — even before the PDF
        // completes — so the user never sees "nothing happens" again.
        // The modal initially shows a spinner; it's swapped to the
        // rendered preview thumbnail + Download / Share affordances
        // (or an error message + Retry button) when triggerLobbyShare
        // resolves.
        showExportModalLoading();
        triggerLobbyShare().catch((err) => {
          try { console.warn('[homefit-lobby] share failed:', err); } catch (_) {}
          showExportError(
            `Couldn't generate the PDF: ${(err && err.message) || err}`,
            () => { triggerLobbyShare().catch(() => {}); },
          );
          if ($lobbyShareBtn) $lobbyShareBtn.disabled = false;
        });
      });
    }

    if ($lobbyTreatmentPills && !$lobbyTreatmentPills._wired) {
      $lobbyTreatmentPills._wired = true;
      $lobbyTreatmentPills.addEventListener('click', (evt) => {
        const btn = evt.target.closest('.treatment-pills > button[data-value]');
        if (!btn) return;
        // Same stopPropagation guard as the gear — clicks inside the
        // popover must not register as "outside" the popover.
        evt.stopPropagation();
        // Disabled pills (when no slides loaded yet) are no-ops; the
        // self-grant path takes over for consent-locked pills inside
        // onTreatmentClick.
        if (btn.classList.contains('is-disabled') && !btn.getAttribute('data-locked')) return;
        onTreatmentClick(btn.getAttribute('data-value'));
      });
    }

    if ($lobbyBodyFocusBtn && !$lobbyBodyFocusBtn._wired) {
      $lobbyBodyFocusBtn._wired = true;
      $lobbyBodyFocusBtn.addEventListener('click', (evt) => {
        evt.stopPropagation();
        // Disabled-state guard mirrors the painter — photos / line
        // treatment / rest have no segmented variant.
        if ($lobbyBodyFocusBtn.disabled) return;
        onLobbyBodyFocusClick();
      });
    }

    if ($lobbyResetOverridesBtn && !$lobbyResetOverridesBtn._wired) {
      $lobbyResetOverridesBtn._wired = true;
      $lobbyResetOverridesBtn.addEventListener('click', (evt) => {
        evt.stopPropagation();
        if ($lobbyResetOverridesBtn.disabled) return;
        onLobbyResetClick();
      });
    }

    // Outside-tap dismissal — wire ONCE at the document level so we
    // don't multiply listeners on subsequent showLobby() calls. The
    // capture-phase guard stops the listener firing while the popover
    // is closed.
    if (!document._lobbySettingsOutsideTapWired) {
      document._lobbySettingsOutsideTapWired = true;
      document.addEventListener('click', (evt) => {
        if (!$lobbySettingsPopover || !isLobbySettingsPopoverOpen()) return;
        const inside = evt.target.closest && (
          evt.target.closest('#lobby-settings-popover') ||
          evt.target.closest('#lobby-gear-btn')
        );
        if (!inside) closeLobbySettingsPopover();
      });
    }

    // BUG 14 fix companion: when the viewport changes (orientation
    // rotate, keyboard show/hide, browser-chrome reveal on scroll),
    // re-anchor the popover so it stays glued to the gear button. The
    // body of the lobby IS scrollable on iOS, so a passive scroll
    // listener keeps the popover from drifting away from the gear.
    if (!window._lobbySettingsReanchorWired) {
      window._lobbySettingsReanchorWired = true;
      const reanchor = () => {
        if (isLobbySettingsPopoverOpen()) repositionLobbySettingsPopover();
      };
      window.addEventListener('resize', reanchor, { passive: true });
      window.addEventListener('orientationchange', reanchor, { passive: true });
      window.addEventListener('scroll', reanchor, { passive: true, capture: true });
    }

    if ($lobbyMatrixInner) {
      $lobbyMatrixInner.addEventListener('click', (evt) => {
        const pill = evt.target.closest('.pill[data-slide]');
        if (!pill) return;
        const slideIdx = parseInt(pill.getAttribute('data-slide'), 10);
        if (Number.isNaN(slideIdx)) return;
        const target = $lobbyList.querySelector(`.lobby-row[data-slide-index="${slideIdx}"]`);
        if (target) {
          target.scrollIntoView({ behavior: 'smooth', block: 'center' });
        }
      });
    }

    if ($lobbyList) {
      $lobbyList.addEventListener('click', (evt) => {
        const toggle = evt.target.closest('[data-notes-toggle]');
        if (!toggle) return;
        const expanded = toggle.classList.toggle('is-expanded');
        toggle.setAttribute('aria-expanded', expanded ? 'true' : 'false');
      });
    }

    if ($selfGrantModal) {
      $selfGrantModal.addEventListener('click', (evt) => {
        const dismiss = evt.target.closest('[data-dismiss="self-grant"]');
        if (dismiss) {
          closeSelfGrantModal();
          return;
        }
      });
      if ($selfGrantAllow && !$selfGrantAllow._wired) {
        $selfGrantAllow._wired = true;
        $selfGrantAllow.addEventListener('click', onAllowSelfGrant);
      }
    }

    document.addEventListener('keydown', (evt) => {
      if (evt.key !== 'Escape') return;
      // Self-grant modal first (it's the more-front element when both
      // are open — but in Round 4 they're mutually exclusive by design).
      if ($selfGrantModal && !$selfGrantModal.hidden) {
        closeSelfGrantModal();
        return;
      }
      // Import sheet next.
      if (isImportSheetOpen()) {
        closeImportSheet();
        return;
      }
      // Then the lobby settings popover.
      if (isLobbySettingsPopoverOpen()) {
        closeLobbySettingsPopover();
      }
    });

    // ----- Import-to-app card (TestFlight v2 — static "Coming soon") -----
    // The PR #315 stub shipped an email-collection form whose submit
    // was a no-op. Carl flagged that as misleading during staging QA
    // (item 10); replaced with a static teaser card that advertises
    // the future feature without asking for an email. When the
    // plan_invitations + magic-link backend ships, the card gets its
    // tap target back; the position + framing stay the same.
    //
    // Matrix-only logo is injected here via buildHomefitLogoSvg()
    // (from app.js) so the chrome stays canonical — earlier the icon
    // was hand-rolled in markup and drifted from the brand geometry.
    const importCard = document.getElementById('lobby-import-card');
    const importGlyph = document.getElementById('lobby-import-glyph');

    if (importCard && !importCard._wired) {
      importCard._wired = true;
      importCard.hidden = false;
      // buildHomefitLogoSvg lives at the top level of app.js (no IIFE
      // wrapper), so it's reachable as `window.buildHomefitLogoSvg` in
      // a browser. We tolerate the bare name too so this works in any
      // context that defines it on the global object.
      const buildLogo =
        (typeof window !== 'undefined'
          && typeof window.buildHomefitLogoSvg === 'function')
          ? window.buildHomefitLogoSvg
          : (typeof buildHomefitLogoSvg === 'function'
              ? buildHomefitLogoSvg
              : null);
      if (importGlyph && buildLogo) {
        importGlyph.innerHTML = buildLogo();
      }
    }
  }

  // ==========================================================================
  // Free Lobby Export — multi-page PDF (Wave PDF Pagination, 2026-05-14)
  // ==========================================================================
  //
  // Practitioner taps the share button → walk the lobby slide list →
  // chunk into pages of up to ROWS_PER_PAGE entries, never splitting a
  // circuit across pages → for each page, build an offscreen DOM
  // snapshot root (.lobby-export-page) with page chrome (full header on
  // page 1, compact running header on pages 2+, footer with page count
  // on every page) → html2canvas renders each page to a canvas →
  // jsPDF.addImage + addPage assembles the multi-page PDF → modal swaps
  // its spinner for the page-1 thumbnail + Download / Share buttons.
  //
  // Pivots from the 2026-05-05 PNG flow because (a) one rasterised PNG
  // of an arbitrarily long lobby is unreadable on phone screens; (b)
  // the file is huge and a pain to share; (c) a PDF is a recognised
  // print-friendly artifact clients can save / print / forward.
  //
  // Polish (Carl 2026-05-14 QA — items #10.1, #10.3, #10.4):
  //   * Active-row coral highlight stripped per-page via .is-exporting
  //     CSS suppression + the .lobby-export-page wrapper class.
  //   * Circuit chrome (SVG lanes overlay + spiraling tracer) settled
  //     to a static frame and given explicit overflow:visible parents
  //     so symmetric corners rasterise cleanly.
  //   * Full list captured by walking the slide MODEL (not the live
  //     scrolling list DOM) — no viewport clipping possible.
  //
  // iOS Save / Share flow:
  //   * Embedded WKWebView (mobile workflow Preview): the PDF is sent
  //     base64-encoded over `HomefitBridge.shareFile` to Dart, which
  //     writes a temp file and presents `UIActivityViewController`
  //     (Share.shareXFiles). The user picks "Save to Files", AirDrop,
  //     Messages, etc.
  //   * Mobile Safari (live web player at session.homefit.studio):
  //     `navigator.share({ files: [pdfFile] })` surfaces the same iOS
  //     share sheet directly. If the Web Share API rejects files,
  //     fall back to opening the PDF in a new tab — iOS's PDF viewer
  //     has a built-in "Save to Files" toolbar.
  //   * Desktop browsers: the modal's `<a download>` anchor downloads
  //     the PDF to the user's filesystem.

  let _html2canvasPromise = null;
  function loadHtml2Canvas() {
    if (typeof window.html2canvas === 'function') {
      return Promise.resolve(window.html2canvas);
    }
    if (_html2canvasPromise) return _html2canvasPromise;
    _html2canvasPromise = new Promise((resolve, reject) => {
      const script = document.createElement('script');
      script.src = '/html2canvas.min.js';
      script.async = true;
      script.onload = () => {
        if (typeof window.html2canvas === 'function') resolve(window.html2canvas);
        else reject(new Error('html2canvas loaded but not on window'));
      };
      script.onerror = () => reject(new Error('html2canvas failed to load'));
      document.head.appendChild(script);
    });
    return _html2canvasPromise;
  }

  // Resolve the jsPDF constructor regardless of how the UMD bundle
  // exposed itself. The official 2.5.x bundle attaches `window.jspdf`
  // (lowercase namespace) with `.jsPDF` constructor. Older bundles set
  // `window.jsPDF` directly. We tolerate both shapes so a future bundle
  // upgrade doesn't silently break this path.
  function resolveJsPdf() {
    if (typeof window === 'undefined') return null;
    if (window.jspdf && typeof window.jspdf.jsPDF === 'function') {
      return window.jspdf.jsPDF;
    }
    if (typeof window.jsPDF === 'function') return window.jsPDF;
    return null;
  }

  // Self-injecting export modal — does NOT rely on the modal markup
  // being present in index.html. Safari + Chrome service workers can
  // serve stale index.html (without the modal block) alongside fresh
  // lobby.js, leaving showExportModal-via-getElementById to fail open
  // into a noisy about:blank fallback. This builder creates the DOM
  // and inline-styles every node so it works regardless of cached
  // HTML/CSS state.
  //
  // PDF pivot 2026-05-14: structure is the same, but the affordances
  // are PDF-shaped (Download PDF / Share buttons, "1 of N pages" badge
  // under the preview thumbnail). Modal nodes are tagged with
  // `data-*` attributes so we can reach into them without fragile
  // tree walks. The preview is a static <canvas>-derived dataURL of
  // page 1 — we hold the first-page canvas reference from the PDF
  // build loop so there's zero extra rasterisation work.
  function ensureExportModal() {
    let modal = document.getElementById('lobby-export-modal');
    if (modal && modal._injected) return modal;
    if (!modal) {
      modal = document.createElement('div');
      modal.id = 'lobby-export-modal';
      modal.setAttribute('role', 'dialog');
      modal.setAttribute('aria-modal', 'true');
      modal.hidden = true;
      document.body.appendChild(modal);
    }
    modal._injected = true;
    // Inline styles so we don't depend on cached styles.css.
    Object.assign(modal.style, {
      position: 'fixed',
      inset: '0',
      zIndex: '1000',
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      padding: '24px',
      boxSizing: 'border-box',
    });
    modal.innerHTML = '';
    const backdrop = document.createElement('div');
    backdrop.setAttribute('data-modal-backdrop', '');
    Object.assign(backdrop.style, {
      position: 'absolute',
      inset: '0',
      background: 'rgba(15, 17, 23, 0.85)',
      backdropFilter: 'blur(8px)',
      webkitBackdropFilter: 'blur(8px)',
    });
    const card = document.createElement('div');
    card.setAttribute('data-modal-card', '');
    Object.assign(card.style, {
      position: 'relative',
      background: '#1A1D24',
      border: '1px solid rgba(255,255,255,0.08)',
      borderRadius: '16px',
      padding: '20px',
      maxWidth: 'min(520px, 100%)',
      maxHeight: 'calc(100vh - 48px)',
      display: 'flex',
      flexDirection: 'column',
      gap: '14px',
      boxShadow: '0 16px 48px rgba(0, 0, 0, 0.45)',
      boxSizing: 'border-box',
      overflowY: 'auto',
    });
    const header = document.createElement('div');
    Object.assign(header.style, {
      display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: '12px',
    });
    const title = document.createElement('h2');
    title.textContent = 'Your plan, ready to share';
    Object.assign(title.style, {
      margin: '0', fontFamily: "'Montserrat', -apple-system, sans-serif",
      fontSize: '16px', fontWeight: '600', color: '#FFFFFF',
    });
    const closeBtn = document.createElement('button');
    closeBtn.textContent = '×';
    closeBtn.setAttribute('aria-label', 'Close');
    Object.assign(closeBtn.style, {
      background: 'transparent', border: '0', color: 'rgba(255,255,255,0.6)',
      fontSize: '24px', lineHeight: '1', cursor: 'pointer', padding: '4px 8px',
      borderRadius: '6px',
    });
    header.appendChild(title);
    header.appendChild(closeBtn);

    const spinner = document.createElement('p');
    spinner.setAttribute('data-export-spinner', '');
    Object.assign(spinner.style, {
      margin: '0',
      color: 'rgba(255,255,255,0.7)',
      fontFamily: "'Inter', -apple-system, sans-serif",
      fontSize: '13px',
      textAlign: 'center',
      padding: '36px 8px',
    });
    spinner.textContent = 'Generating preview…';

    const previewWrap = document.createElement('div');
    previewWrap.setAttribute('data-preview-wrap', '');
    Object.assign(previewWrap.style, {
      display: 'none',
      flexDirection: 'column',
      gap: '8px',
      alignItems: 'center',
    });
    const img = document.createElement('img');
    img.alt = 'Page 1 of plan PDF';
    Object.assign(img.style, {
      width: '100%', height: 'auto', maxHeight: 'calc(100vh - 280px)',
      objectFit: 'contain', borderRadius: '8px', background: '#0F1117',
      border: '1px solid rgba(255,255,255,0.08)',
    });
    const badge = document.createElement('span');
    badge.setAttribute('data-page-badge', '');
    Object.assign(badge.style, {
      display: 'inline-block', background: 'rgba(255,107,53,0.12)',
      color: '#FF6B35', fontFamily: "'JetBrains Mono', ui-monospace, monospace",
      fontSize: '11px', fontWeight: '600', padding: '4px 10px',
      borderRadius: '999px', border: '1px solid rgba(255,107,53,0.30)',
    });
    badge.textContent = '1 of 1 pages';
    previewWrap.appendChild(img);
    previewWrap.appendChild(badge);

    const errorMsg = document.createElement('p');
    errorMsg.setAttribute('data-export-error', '');
    Object.assign(errorMsg.style, {
      margin: '0', display: 'none',
      color: '#FF6B35',
      fontFamily: "'Inter', -apple-system, sans-serif",
      fontSize: '13px',
      textAlign: 'center',
      padding: '24px 8px',
    });

    const actions = document.createElement('div');
    actions.setAttribute('data-actions', '');
    Object.assign(actions.style, {
      display: 'none',
      flexDirection: 'row',
      gap: '8px',
      alignItems: 'stretch',
    });
    const downloadLink = document.createElement('a');
    downloadLink.textContent = 'Download PDF';
    downloadLink.setAttribute('data-download', '');
    Object.assign(downloadLink.style, {
      flex: '1 1 0',
      display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
      background: '#FF6B35', color: '#0F1117',
      fontFamily: "'Montserrat', -apple-system, sans-serif",
      fontWeight: '600', fontSize: '14px', padding: '12px 16px',
      borderRadius: '999px', textDecoration: 'none', cursor: 'pointer',
    });
    const shareBtn = document.createElement('button');
    shareBtn.type = 'button';
    shareBtn.textContent = 'Share';
    shareBtn.setAttribute('data-share', '');
    Object.assign(shareBtn.style, {
      flex: '1 1 0',
      display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
      background: 'rgba(255,255,255,0.06)', color: '#FFFFFF',
      border: '1px solid rgba(255,255,255,0.15)',
      fontFamily: "'Montserrat', -apple-system, sans-serif",
      fontWeight: '600', fontSize: '14px', padding: '12px 16px',
      borderRadius: '999px', cursor: 'pointer',
    });
    actions.appendChild(downloadLink);
    actions.appendChild(shareBtn);

    const retryBtn = document.createElement('button');
    retryBtn.type = 'button';
    retryBtn.textContent = 'Retry';
    retryBtn.setAttribute('data-retry', '');
    Object.assign(retryBtn.style, {
      display: 'none',
      width: '100%',
      background: '#FF6B35', color: '#0F1117', border: '0',
      fontFamily: "'Montserrat', -apple-system, sans-serif",
      fontWeight: '600', fontSize: '14px', padding: '12px 16px',
      borderRadius: '999px', cursor: 'pointer',
    });

    const hint = document.createElement('p');
    hint.setAttribute('data-hint', '');
    Object.assign(hint.style, {
      margin: '0', textAlign: 'center', color: 'rgba(255,255,255,0.6)',
      fontFamily: "'Inter', -apple-system, sans-serif", fontSize: '12px',
      display: 'none',
    });

    card.appendChild(header);
    card.appendChild(spinner);
    card.appendChild(previewWrap);
    card.appendChild(errorMsg);
    card.appendChild(actions);
    card.appendChild(retryBtn);
    card.appendChild(hint);
    modal.appendChild(backdrop);
    modal.appendChild(card);

    const close = () => {
      modal.hidden = true;
      // Revoke any pending blob URL to free memory.
      try {
        const href = downloadLink.getAttribute('href');
        if (href && href.startsWith('blob:')) URL.revokeObjectURL(href);
      } catch (_) {}
      downloadLink.removeAttribute('href');
      img.src = '';
    };
    closeBtn.addEventListener('click', close);
    backdrop.addEventListener('click', close);
    document.addEventListener('keydown', (evt) => {
      if (evt.key === 'Escape' && !modal.hidden) close();
    });
    modal._refs = {
      img,
      badge,
      spinner,
      previewWrap,
      errorMsg,
      actions,
      downloadLink,
      shareBtn,
      retryBtn,
      hint,
      close,
    };
    return modal;
  }

  // Switch the modal into "preview ready" mode — show the page-1
  // thumbnail, the "N of M pages" badge, the Download + Share buttons,
  // and a contextual hint per environment. Wires the Share button to
  // the supplied `onShare` callback (which routes through native bridge
  // / Web Share / new-tab fallback depending on environment), and the
  // Download button to `onDownload` if provided (iOS WKWebView ignores
  // `<a download>` clicks, so we route through the native bridge there).
  function showExportModal(opts) {
    const modal = ensureExportModal();
    const refs = modal._refs;
    if (!refs) return false;
    const { previewImageDataUrl, blobUrl, fileName, pageCount, onShare, onDownload, onRetry } = opts;
    refs.spinner.style.display = 'none';
    refs.errorMsg.style.display = 'none';
    refs.retryBtn.style.display = 'none';
    refs.previewWrap.style.display = 'flex';
    refs.actions.style.display = 'flex';
    refs.hint.style.display = 'block';

    refs.img.src = previewImageDataUrl || '';
    refs.badge.textContent = pageCount === 1
      ? '1 of 1 page'
      : `1 of ${pageCount} pages`;

    refs.downloadLink.href = blobUrl;
    refs.downloadLink.setAttribute('download', fileName);

    // BUG 8 fix (2026-05-15): bare `<a download>` is silently ignored by
    // iOS WKWebView (and `window.open` of a blob URL was the historical
    // fallback, but that also misbehaves under the custom scheme handler).
    // When `onDownload` is supplied — currently set by the caller on
    // iOS embedded surfaces — we run it instead of the default anchor
    // click, routing the PDF through `homefitBridge.shareFile` which
    // surfaces UIActivityViewController with Save to Files preselectable.
    // Desktop / live web Safari falls through to the native anchor
    // behaviour (the click handler returns truthy → default not
    // prevented → browser triggers the download).
    refs.downloadLink.onclick = (evt) => {
      if (typeof onDownload === 'function') {
        evt.preventDefault();
        try { onDownload(); } catch (err) {
          try { console.warn('[homefit-lobby] download btn rejected:', err); } catch (_) {}
        }
      }
      // else: anchor's native href + download attribute take over.
    };

    // Wire share button — replace any prior listener.
    refs.shareBtn.onclick = (evt) => {
      evt.preventDefault();
      if (typeof onShare === 'function') {
        try { onShare(); } catch (err) {
          try { console.warn('[homefit-lobby] share btn rejected:', err); } catch (_) {}
        }
      }
    };
    refs.retryBtn.onclick = (evt) => {
      evt.preventDefault();
      if (typeof onRetry === 'function') {
        try { onRetry(); } catch (err) {
          try { console.warn('[homefit-lobby] retry rejected:', err); } catch (_) {}
        }
      }
    };

    // Contextual hint copy. Embedded WKWebView routes through Dart
    // bridge, mobile Safari uses navigator.share, desktop downloads.
    var isEmbedded = (typeof window !== 'undefined'
      && typeof window.isHomefitEmbedded === 'function'
      && window.isHomefitEmbedded());
    var isTouch = (typeof navigator !== 'undefined'
      && /iphone|ipad|ipod|android/i.test(String(navigator.userAgent || '')));
    if (isEmbedded || isTouch) {
      refs.hint.textContent = 'Tap Download PDF to save, or Share to send.';
    } else {
      refs.hint.textContent = 'Download saves the PDF to your computer. Share opens your browser’s share menu when available.';
    }
    modal.hidden = false;
    return true;
  }

  // Render the modal with a spinner immediately on click — guarantees
  // the user sees SOMETHING happen even if PDF generation hangs or
  // returns silently. Replaced with the actual preview (via
  // showExportModal) or an error message (via showExportError) when
  // triggerLobbyShare resolves. Supports a progress message so the
  // user can see which page is rendering during longer PDFs.
  function showExportModalLoading(progressMsg) {
    const modal = ensureExportModal();
    const refs = modal._refs;
    if (!refs) return;
    refs.previewWrap.style.display = 'none';
    refs.actions.style.display = 'none';
    refs.errorMsg.style.display = 'none';
    refs.retryBtn.style.display = 'none';
    refs.hint.style.display = 'none';
    refs.spinner.style.display = 'block';
    refs.spinner.textContent = typeof progressMsg === 'string' && progressMsg
      ? progressMsg
      : 'Generating PDF…';
    modal.hidden = false;
  }

  // Surface CORS / taint / pagination failures so they don't disappear
  // into the console. Reuses the export modal — hides the preview +
  // download / share buttons and shows a message + a Retry button.
  function showExportError(message, onRetry) {
    const modal = ensureExportModal();
    const refs = modal._refs;
    if (!refs) {
      try { window.alert(message); } catch (_) {}
      return;
    }
    refs.spinner.style.display = 'none';
    refs.previewWrap.style.display = 'none';
    refs.actions.style.display = 'none';
    refs.hint.style.display = 'none';
    refs.errorMsg.style.display = 'block';
    refs.errorMsg.textContent = message;
    if (typeof onRetry === 'function') {
      refs.retryBtn.style.display = 'block';
      refs.retryBtn.onclick = (evt) => {
        evt.preventDefault();
        try { onRetry(); } catch (err) {
          try { console.warn('[homefit-lobby] retry rejected:', err); } catch (_) {}
        }
      };
    } else {
      refs.retryBtn.style.display = 'none';
    }
    modal.hidden = false;
  }

  // Pre-fetch every image src + video poster in the lobby and convert
  // each to a base64 DATA URL. Data URLs are guaranteed same-origin and
  // need no separate load — they're inlined in the src attribute. This
  // sidesteps two problems we hit with blob: URLs:
  //   - Live-DOM swap to a blob URL caused a brief broken-image flash
  //     while the browser fetched the blob (Carl's round 7 question
  //     mark).
  //   - blob URL revoke timing was racing with html2canvas paint.
  //
  // PDF tainted-canvas hotfix (2026-05-14): adds a per-fetch timeout via
  // AbortController. Without this, a stalled cross-origin response (CDN
  // hiccup, partially-buffered Supabase signed URL) could leave a fetch
  // pending indefinitely; preloadAsDataUrls would never resolve and the
  // PDF pipeline would sit forever on its "Rendering page N of M…"
  // message because the await on this function never returns. Bounded
  // failure surfaces in `errors[]` and routes to the existing
  // "Error + Retry" modal state.
  async function preloadAsDataUrls(rootEl) {
    const sources = new Set();
    rootEl.querySelectorAll('img').forEach((img) => {
      if (img.src) sources.add(img.src);
    });
    rootEl.querySelectorAll('video').forEach((v) => {
      if (v.poster) sources.add(v.poster);
    });
    const map = new Map(); // origSrc → dataUrl
    const errors = [];
    // 2026-05-13 — embedded WKWebView quirk. The custom `homefit-local://`
    // scheme handler serves images same-origin, but `fetch(url, { mode:
    // 'cors' })` against a non-http(s) scheme can stall forever in
    // WebKit's CORS preflight path (no preflight to emit, but the
    // fetch hangs without returning). Drop `mode: 'cors'` for embedded
    // surfaces — same-origin fetch needs no opt-in and html2canvas
    // doesn't taint on same-origin <img> reads. Live web player keeps
    // explicit CORS in case the SDN serves images from a cross-origin
    // bucket alias.
    const isEmbedded = (typeof window !== 'undefined'
      && typeof window.isHomefitEmbedded === 'function'
      && window.isHomefitEmbedded());
    const fetchOpts = isEmbedded
      ? { credentials: 'omit' }
      : { mode: 'cors', credentials: 'omit' };
    // Per-fetch budget. BUG 10a fix (2026-05-15): bumped from 8s to 15s
    // on iOS embedded WKWebView. The custom `homefit-local://` scheme
    // handler shares the network queue with the heavier-than-Safari
    // WebKit layout pass; a slow hero JPG can take 6-10s to settle even
    // when the file is already on disk. 8s was too tight and one missed
    // image would cause html2canvas to try the fetch directly during
    // page rasterisation, blowing the per-page budget. Desktop / live
    // web Safari keeps the 8s budget — they fetch faster and signed-URL
    // stalls there should fail fast.
    const FETCH_TIMEOUT_MS = isEmbedded ? 15000 : 8000;
    async function fetchWithTimeout(src) {
      // AbortController is supported in every browser we ship to (Safari
      // 11.1+, Chrome 66+). The try/catch around AbortController
      // construction is defensive against a hypothetical surface where
      // it's missing — fall back to an unguarded fetch.
      let controller;
      try { controller = new AbortController(); } catch (_) { controller = null; }
      const opts = controller
        ? Object.assign({}, fetchOpts, { signal: controller.signal })
        : fetchOpts;
      let timer = null;
      if (controller) {
        timer = setTimeout(() => {
          try { controller.abort(); } catch (_) {}
        }, FETCH_TIMEOUT_MS);
      }
      try {
        return await fetch(src, opts);
      } finally {
        if (timer) clearTimeout(timer);
      }
    }
    await Promise.all(Array.from(sources).map(async (src) => {
      if (!src) return;
      if (src.startsWith('data:')) return;
      try {
        const res = await fetchWithTimeout(src);
        if (!res.ok) {
          errors.push(`${res.status} on ${shortUrl(src)}`);
          return;
        }
        const blob = await res.blob();
        if (!/^image\//i.test(blob.type)) {
          errors.push(`non-image blob (${blob.type}) on ${shortUrl(src)}`);
          return;
        }
        const dataUrl = await new Promise((resolve, reject) => {
          const reader = new FileReader();
          reader.onload = () => resolve(reader.result);
          reader.onerror = () => reject(reader.error);
          reader.readAsDataURL(blob);
        });
        map.set(src, dataUrl);
      } catch (err) {
        const msg = (err && err.name === 'AbortError')
          ? 'timeout'
          : ((err && err.message) || err);
        errors.push(`${msg} on ${shortUrl(src)}`);
      }
    }));
    return { map, errors };
  }

  function shortUrl(u) {
    try {
      const url = new URL(u);
      const last = url.pathname.split('/').pop() || url.pathname;
      return last.length > 32 ? last.slice(0, 28) + '…' : last;
    } catch (_) {
      return String(u).slice(0, 32);
    }
  }

  /// Convert a Blob to a `data:image/...` URL. Used by the embedded
  /// share path — the native bridge takes a string payload, not a
  /// Blob handle. Falls back to null if the reader rejects.
  function blobToDataUrl(blob) {
    return new Promise((resolve, reject) => {
      try {
        const reader = new FileReader();
        reader.onload = () => resolve(reader.result);
        reader.onerror = () => reject(reader.error);
        reader.readAsDataURL(blob);
      } catch (err) {
        reject(err);
      }
    });
  }

  function formatExportError(diag, headline) {
    const lines = [`Couldn't generate the PDF: ${headline}.`];
    lines.push(
      `Pre-fetched ${diag.fetched}/${diag.sources} images, rendered ${diag.pagesRendered}/${diag.pageCount} pages.`,
    );
    if (diag.h2cError) lines.push(`html2canvas: ${diag.h2cError}`);
    if (diag.pdfError) lines.push(`jsPDF: ${diag.pdfError}`);
    if (diag.taintErr) lines.push(`Canvas: ${diag.taintErr}`);
    if (diag.preloadErrors.length) {
      const sample = diag.preloadErrors.slice(0, 3).join('; ');
      lines.push(`Preload: ${sample}${diag.preloadErrors.length > 3 ? ` (+${diag.preloadErrors.length - 3} more)` : ''}`);
    }
    lines.push(`Reload and try again.`);
    return lines.join(' ');
  }

  // Rows-per-page target. The locked design budget is 5 entries —
  // tight enough that page 1 fits the full header AND a meaningful
  // chunk of the plan; loose enough that 4-page PDFs cap reasonable
  // plans (≤ 20 exercises). A circuit counts as 1 entry regardless
  // of how many in-circuit rows it owns (the whole group occupies
  // one slot on the page so the chrome stays symmetric).
  const PDF_ROWS_PER_PAGE = 5;

  // jsPDF dims for A4 portrait in mm. We rasterise each page at 794px
  // wide (96dpi A4) and add to the PDF at the matching mm width — no
  // resampling. Height is dynamic per page (canvas height ÷ scale)
  // since pages may run shorter when the chunk is small.
  const PDF_PAGE_WIDTH_PX = 794;   // 210mm at 96dpi
  const PDF_PAGE_WIDTH_MM = 210;
  const PDF_PAGE_HEIGHT_MM = 297;

  // Chunk the rendered .lobby-list items (circuit groups + standalone
  // rows + rest rows) into page-sized arrays. A circuit group is a
  // SINGLE atomic entry — we never split one across pages. If a circuit
  // doesn't fit in the remaining slot count on the current page, we
  // flush the page and start the circuit on a fresh one (rule #2 in
  // the spec).
  //
  // Input: an array of live <li> DOM nodes (the children of #lobby-list).
  // Output: array<array<HTMLElement>> — one inner array per page.
  function chunkLobbyItemsForPdf(items) {
    const pages = [];
    let current = [];
    let remaining = PDF_ROWS_PER_PAGE;
    for (const el of items) {
      // We treat every direct child of .lobby-list as one slot. The
      // visual height of a circuit (header + N in-circuit rows) is
      // larger than a single row — but at 5 entries per page the
      // worst case (one circuit with 4 in-circuit rows + a standalone
      // row) still fits comfortably in 794px column. The "don't split
      // a circuit" rule is the load-bearing constraint, not the row
      // count budget.
      if (remaining <= 0) {
        pages.push(current);
        current = [];
        remaining = PDF_ROWS_PER_PAGE;
      }
      current.push(el);
      remaining -= 1;
    }
    if (current.length) pages.push(current);
    return pages;
  }

  // Compose the human-readable summary line for page 1's header. Mirrors
  // the live .lobby-meta-sub structure: "Hi {Client} · N exercises · ~MM min · From {Practitioner}".
  // Defensive — every field is best-effort; missing fields just drop out.
  function buildPdfSummaryLine() {
    if (!api || !plan) return '';
    const parts = [];
    const clientName = (plan.client_name || '').trim();
    if (clientName) parts.push(`Hi ${clientName}`);
    let count = 0;
    try {
      count = (typeof countExercises === 'function')
        ? countExercises(slides)
        : slides.filter((s) => s && s.media_type !== 'rest').length;
    } catch (_) { count = slides.length; }
    if (count > 0) parts.push(count === 1 ? '1 exercise' : `${count} exercises`);
    let durSec = 0;
    try {
      durSec = api.sumTotalDurationSeconds ? api.sumTotalDurationSeconds() : 0;
    } catch (_) {}
    if (durSec > 0) {
      const minutes = Math.max(1, Math.round(durSec / 60));
      parts.push(`~${minutes} min`);
    }
    let practitionerName = '';
    try {
      practitionerName = api.getPractitionerName ? api.getPractitionerName() : '';
    } catch (_) {}
    if (practitionerName) parts.push(`From ${practitionerName}`);
    return parts.join(' · ');
  }

  // Resolve the plan's display title for the PDF header. Defaults to
  // "Your plan" if the practitioner hasn't named it (which is common —
  // Studio leaves the title as a `{DD Mon YYYY HH:MM}` date stamp by
  // default; for the PDF chrome we prefer the friendlier fallback).
  function buildPdfTitle() {
    if (!plan) return 'Your plan';
    const t = (plan.title || '').trim();
    if (!t) return 'Your plan';
    return t;
  }

  // Build the off-screen .lobby-export-page wrapper for one page. Clones
  // each item so the live DOM stays untouched, wraps with appropriate
  // header (full vs running) and footer (page N of M + brand line),
  // returns the wrapper element. Caller appends to <body>, html2canvas
  // reads it, then removes.
  function buildExportPageElement(items, pageIndex, pageCount, planTitle, summaryLine) {
    const wrap = document.createElement('div');
    wrap.className = 'lobby-export-page';
    // BUG 6c (2026-05-15): inner wrapper holds the padding so the outer
    // 794px width equals the A4 content area. Without this split,
    // html2canvas captured the full bordered-box width (794px including
    // 56px horizontal padding) and addImage then stretched the 1588px
    // canvas to fill 210mm, inflating content horizontally by ~7%.
    const inner = document.createElement('div');
    inner.className = 'lobby-export-page-inner';

    if (pageIndex === 0) {
      const header = document.createElement('div');
      header.className = 'lobby-export-page-header';
      const titleEl = document.createElement('h1');
      titleEl.className = 'lobby-export-page-title';
      titleEl.textContent = planTitle;
      const summaryEl = document.createElement('p');
      summaryEl.className = 'lobby-export-page-summary';
      summaryEl.textContent = summaryLine;
      header.appendChild(titleEl);
      if (summaryLine) header.appendChild(summaryEl);
      inner.appendChild(header);
    } else {
      const running = document.createElement('div');
      running.className = 'lobby-export-page-running';
      const runTitle = document.createElement('span');
      runTitle.className = 'lobby-export-running-title';
      runTitle.textContent = planTitle;
      const runPage = document.createElement('span');
      runPage.textContent = `page ${pageIndex + 1} of ${pageCount}`;
      running.appendChild(runTitle);
      running.appendChild(runPage);
      inner.appendChild(running);
    }

    // Body — a fresh .lobby-list <ul> hosting cloned items. We keep
    // the .lobby-list class so the existing row styles apply, but
    // strip the id (#lobby-list is unique on the live page; we don't
    // want a duplicate id in the document during the snapshot).
    const body = document.createElement('div');
    body.className = 'lobby-export-page-body';
    const ul = document.createElement('ul');
    ul.className = 'lobby-list';
    for (const el of items) {
      const clone = el.cloneNode(true);
      // Strip dynamic state classes — we never want the live active-row
      // coral highlight in the rendered page (#10.1). The CSS in
      // styles.css also covers this defensively, but doing it on the
      // clone is the cleanest path.
      clone.classList.remove('is-active', 'is-active-pill');
      // Active-row <video> elements (swapped in by swapToVideoOnActiveRow)
      // are unreliable in html2canvas — the rasteriser can't read the
      // current frame from an iOS WKWebView <video>, especially mid-play
      // or in an auto-paused state, and falls back to a solid grey block
      // in the PDF. The fix is to swap each <video> back to an <img>
      // using its cropped data-URL poster BEFORE rasterising; html2canvas
      // renders <img> perfectly. The poster src is already a 1:1 cropped
      // data URL (hydrateHeroCrops mirrors the resolver's output onto
      // both data-hero-source AND data-poster-src), so this swap costs
      // zero extra work — just structural conversion.
      clone.querySelectorAll('video').forEach((v) => {
        try { v.pause(); } catch (_) {}
        const posterSrc = v.dataset.posterSrc
          || v.getAttribute('poster')
          || '';
        if (posterSrc) {
          const img = document.createElement('img');
          img.className = v.className;
          img.setAttribute('alt', v.getAttribute('alt') || '');
          img.style.cssText = v.style.cssText;
          img.src = posterSrc;
          // Carry data-* across so any downstream code that walks the
          // clone for diagnostics still sees the same metadata shape.
          Object.keys(v.dataset).forEach((k) => {
            img.dataset[k] = v.dataset[k];
          });
          v.parentNode.replaceChild(img, v);
        } else {
          // No poster available — keep the <video> but stripped. Better
          // than nothing; html2canvas may still grey-block but at least
          // no autoplay or loop bleeds into the export.
          v.removeAttribute('autoplay');
          v.removeAttribute('loop');
        }
      });
      ul.appendChild(clone);
    }
    body.appendChild(ul);
    inner.appendChild(body);

    const footer = document.createElement('div');
    footer.className = 'lobby-export-page-footer';
    const count = document.createElement('span');
    count.className = 'lobby-export-page-count';
    count.textContent = `Page ${pageIndex + 1} of ${pageCount}`;
    const brand = document.createElement('span');
    brand.className = 'lobby-export-page-brand';
    brand.textContent = 'Visual plans clients follow. · homefit.studio';
    footer.appendChild(count);
    footer.appendChild(brand);
    inner.appendChild(footer);

    wrap.appendChild(inner);
    return wrap;
  }

  // Convert a Blob to base64-without-data-URL-prefix. Used by the
  // embedded share-file bridge: the Dart side expects raw base64 +
  // mime / filename as separate fields.
  function blobToBase64(blob) {
    return new Promise((resolve, reject) => {
      try {
        const reader = new FileReader();
        reader.onload = () => {
          const r = String(reader.result || '');
          const idx = r.indexOf('base64,');
          if (idx < 0) return reject(new Error('reader returned non-base64'));
          resolve(r.substring(idx + 7));
        };
        reader.onerror = () => reject(reader.error);
        reader.readAsDataURL(blob);
      } catch (err) {
        reject(err);
      }
    });
  }

  async function triggerLobbyShare() {
    if (!$lobby) throw new Error('lobby root missing');
    if (!$lobbyList) throw new Error('lobby list missing');
    if ($lobbyShareBtn) $lobbyShareBtn.disabled = true;
    const diag = {
      sources: 0, fetched: 0, swapped: 0,
      preloadErrors: [],
      pageCount: 0, pagesRendered: 0,
      h2cError: null, pdfError: null, taintErr: null,
    };
    try {
      const html2canvas = await loadHtml2Canvas();
      const JsPdfCtor = resolveJsPdf();
      if (!JsPdfCtor) {
        showExportError(
          'PDF library failed to load. Reload the page and try again.',
          () => { triggerLobbyShare().catch(() => {}); },
        );
        return;
      }

      // Pre-fetch every cross-origin image as a base64 data URL. Data
      // URLs are inlined into the src attribute — no separate fetch, no
      // taint surface, no broken-image flicker on the live page.
      const { map: dataUrlMap, errors: preloadErrors } = await preloadAsDataUrls($lobby);
      diag.fetched = dataUrlMap.size;
      diag.preloadErrors = preloadErrors;
      const imgCount = $lobby.querySelectorAll('img').length;
      const videoCount = $lobby.querySelectorAll('video').length;
      diag.sources = imgCount + videoCount;

      // Fail-loud early when every cross-origin preload failed. If we
      // have sources but the dataUrlMap is empty AND we logged errors,
      // there's no value in proceeding to html2canvas — it would also
      // fail (or hang) on the same URLs. Surface the existing
      // "Couldn't generate the PDF" error + Retry button now instead.
      // The check is intentionally narrow (>0 sources, 0 fetched, 1+
      // errors) so partial-success and zero-image cases still proceed.
      if (diag.sources > 0 && dataUrlMap.size === 0 && preloadErrors.length > 0) {
        showExportError(
          formatExportError(diag, 'every image preload failed'),
          () => { triggerLobbyShare().catch(() => {}); },
        );
        return;
      }

      // Bundle 1 of the hero-resolver migration (audit D13). The active
      // video's <video poster> doesn't inherit the .is-grayscale CSS
      // filter during html2canvas rasterisation, so even when the rest
      // of the lobby renders correctly in B&W via onclone CSS, the
      // video row's poster shows up untreated. Bake the filter into a
      // canvas-derived data URL BEFORE the live-DOM swap step picks it
      // up — html2canvas reads the baked bitmap and the snapshot
      // matches the playing treatment.
      if (window.HomefitHero && window.HomefitHero.bakeFilterIntoDataUrl) {
        const videoEls = $lobby.querySelectorAll('video');
        for (const v of videoEls) {
          const t = v.dataset && v.dataset.treatment ? v.dataset.treatment : '';
          if (t !== 'bw') continue;
          const originalPoster = v.dataset.posterSrc || v.getAttribute('poster') || '';
          if (!originalPoster) continue;
          const sourceForBake = dataUrlMap.get(originalPoster) || originalPoster;
          try {
            const baked = await window.HomefitHero.bakeFilterIntoDataUrl(
              sourceForBake,
              'grayscale(1) contrast(1.05)',
            );
            if (baked && baked !== originalPoster) {
              dataUrlMap.set(originalPoster, baked);
              if (sourceForBake !== originalPoster) {
                dataUrlMap.set(sourceForBake, baked);
              }
            } else if (!baked) {
              diag.preloadErrors.push(`bake failed for ${shortUrl(originalPoster)}`);
            }
          } catch (err) {
            diag.preloadErrors.push(`bake error: ${(err && err.message) || err}`);
          }
        }
      }

      // Build the page chunks. The live #lobby-list contains the rendered
      // items already (circuit groups + standalone rows + rest rows); we
      // simply chunk the children. Cloning preserves the rendered hero
      // markup including any swapped data-URL images that the live DOM
      // is already showing.
      const liveItems = Array.from($lobbyList.children).filter((el) => {
        // The #lobby-list children are either <li class="lobby-row"> or
        // <li class="lobby-circuit">. Skip anything that snuck in (e.g.
        // a <script> tag, defensive).
        return el && el.tagName === 'LI';
      });
      if (liveItems.length === 0) {
        showExportError('No exercises in this plan to export.', null);
        return;
      }
      const pageChunks = chunkLobbyItemsForPdf(liveItems);
      const pageCount = pageChunks.length;
      diag.pageCount = pageCount;

      const planTitle = buildPdfTitle();
      const summaryLine = buildPdfSummaryLine();

      // Swap data-URL images on the LIVE DOM up front — every cloned page
      // chunk inherits the swap, and the html2canvas reads of the
      // off-screen export root never touch network. Restored in `finally`.
      const imgs = Array.from($lobby.querySelectorAll('img'));
      const videos = Array.from($lobby.querySelectorAll('video'));
      const originalSrcs = new Map();
      const originalPosters = new Map();

      const root = document.documentElement;
      root.classList.add('is-exporting');

      // Nested-box circuit chrome (attempt #10) is pure CSS — the
      // animation is suppressed via `html.is-exporting .lobby-circuit-box`
      // in styles.css, which freezes the keyframe at a bright-coral
      // settled frame. No JS animation cancellation needed.

      let pdfBlob = null;
      let firstPageDataUrl = null;
      try {
        for (const img of imgs) {
          const swap = dataUrlMap.get(img.src);
          if (swap) {
            originalSrcs.set(img, img.src);
            img.src = swap;
            img.removeAttribute('crossorigin');
            diag.swapped += 1;
          } else if (img.src && !img.src.startsWith('data:')) {
            diag.preloadErrors.push(`unmapped img: ${shortUrl(img.src)}`);
          }
        }
        for (const v of videos) {
          const swap = dataUrlMap.get(v.poster);
          if (swap) {
            originalPosters.set(v, v.poster);
            v.poster = swap;
          }
        }

        // Force-decode swapped imgs so each clone hands html2canvas a
        // fully painted bitmap.
        await Promise.all(imgs.map((img) => {
          if (!img.src) return Promise.resolve();
          if (typeof img.decode === 'function') return img.decode().catch(() => {});
          return new Promise((resolve) => {
            if (img.complete && img.naturalWidth > 0) return resolve();
            img.addEventListener('load', () => resolve(), { once: true });
            img.addEventListener('error', () => resolve(), { once: true });
            setTimeout(resolve, 2000);
          });
        }));

        await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));

        // Build the PDF doc up front. Orientation portrait, mm units,
        // A4. Each page added with addImage at its computed height.
        const pdf = new JsPdfCtor({ orientation: 'portrait', unit: 'mm', format: 'a4' });

        for (let i = 0; i < pageChunks.length; i++) {
          // Progress message on the spinner so the modal doesn't sit
          // silent during a 3-page render.
          showExportModalLoading(`Rendering page ${i + 1} of ${pageCount}…`);

          const pageEl = buildExportPageElement(
            pageChunks[i], i, pageCount, planTitle, summaryLine,
          );
          document.body.appendChild(pageEl);

          let pageCanvas;
          try {
            // One RAF + decode wait to let the off-screen page lay out
            // before html2canvas reads it.
            await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
            const pageImgs = Array.from(pageEl.querySelectorAll('img'));
            // Per-page decode with 2s timeout guard. Matches the initial
            // $lobby decode at the top of triggerLobbyShare. Without this,
            // a hung `decode()` on a broken data URL (or a Safari quirk)
            // would freeze the pipeline on this page indefinitely — no
            // error, no progress, just the "Rendering page N of M…"
            // spinner forever.
            await Promise.all(pageImgs.map((im) => {
              if (typeof im.decode !== 'function') return Promise.resolve();
              return Promise.race([
                im.decode().catch(() => {}),
                new Promise((r) => setTimeout(r, 2000)),
              ]);
            }));

            // Backstop swap inside html2canvas's clone. The live-DOM swap
            // above (lines 2920+) already replaces every cross-origin
            // <img>.src with a same-origin data URL, and cloneNode inherits
            // those data URLs into the off-screen page wrapper. BUT if a
            // hero was repainted between preload and swap, or a poster
            // attribute slipped through (or a new <img> was injected by a
            // bg layout pass), html2canvas's internal clone could still
            // contain a Supabase signed URL. With `useCORS: true` it would
            // re-fetch the URL with crossorigin="anonymous"; if Supabase's
            // CORS preflight stalled, the canvas paint would hang.
            //
            // The onclone callback fires AFTER html2canvas has cloned
            // pageEl into its internal iframe. We re-walk the cloned
            // <img>/<video> nodes and force a final swap against the
            // dataUrlMap. Any node still pointing at a non-data URL
            // (preload failure) gets its src stripped — html2canvas will
            // render an empty <img> placeholder instead of fetching, so
            // the page still renders + we still get a PDF (sans that one
            // hero). This is the explicit fail-loud fallback: a missing
            // hero is recoverable; a hung pipeline is not.
            const onclone = (clonedDoc) => {
              try {
                clonedDoc.querySelectorAll('img').forEach((img) => {
                  const cur = img.getAttribute('src') || '';
                  if (!cur || cur.startsWith('data:')) return;
                  const swap = dataUrlMap.get(cur);
                  if (swap) {
                    img.setAttribute('src', swap);
                    img.removeAttribute('crossorigin');
                  } else {
                    // No preload entry for this URL — strip src instead
                    // of letting html2canvas try (and possibly hang on)
                    // the cross-origin fetch.
                    img.removeAttribute('src');
                  }
                });
                clonedDoc.querySelectorAll('video').forEach((v) => {
                  const cur = v.getAttribute('poster') || '';
                  if (!cur || cur.startsWith('data:')) return;
                  const swap = dataUrlMap.get(cur);
                  if (swap) v.setAttribute('poster', swap);
                  else v.removeAttribute('poster');
                });
              } catch (_) {}
            };

            // BUG 10a fix (2026-05-15): 30s hard ceiling (was 15s).
            // Multi-page renders on iOS WKWebView regularly burned 15-20s
            // on page 2+ when one image hadn't fully pre-fetched and
            // html2canvas had to refetch under heavier WebView layout
            // contention. 30s gives the slow path enough oxygen without
            // making the user wait forever on a truly stuck pipeline.
            // Combined with `imageTimeout: 4000` below, this ensures
            // the spinner doesn't sit forever if html2canvas's internal
            // image-loading gets stuck on an unswappable URL. On timeout
            // we surface the existing "Couldn't generate the PDF"
            // error + Retry path.
            const PAGE_RENDER_TIMEOUT_MS = 30000;
            const h2cPromise = html2canvas(pageEl, {
              backgroundColor: '#0F1117',
              scale: 2, // 2x for retina-quality output regardless of devicePixelRatio
              useCORS: true,
              allowTaint: false,
              logging: false,
              // Per-image timeout — html2canvas defaults to 15s which
              // multiplies across the page. 4s is enough for a fully
              // pre-fetched data URL (instant) plus generous slack for
              // any same-origin font/asset; if a fetch is going to fail
              // it will fail by now, surfacing as an html2canvas reject
              // and routing to the error modal with Retry.
              imageTimeout: 4000,
              onclone,
              ignoreElements: (el) => {
                if (!el || typeof el.id !== 'string') return false;
                return el.id === 'lobby-export-modal'
                  || el.id === 'lobby-self-grant-modal';
              },
            });
            const timeoutPromise = new Promise((_, reject) => {
              setTimeout(
                () => reject(new Error(`page ${i + 1} render timeout (${PAGE_RENDER_TIMEOUT_MS / 1000}s)`)),
                PAGE_RENDER_TIMEOUT_MS,
              );
            });
            pageCanvas = await Promise.race([h2cPromise, timeoutPromise]);
          } catch (err) {
            diag.h2cError = (err && err.message) || String(err);
            try { document.body.removeChild(pageEl); } catch (_) {}
            throw err;
          }

          try { document.body.removeChild(pageEl); } catch (_) {}

          if (!pageCanvas) {
            throw new Error(`page ${i + 1} canvas was null`);
          }

          // Capture the page-1 thumbnail data URL up front (the canvas
          // is consumed by addImage but toDataURL is safe to call first).
          try { pageCanvas.toDataURL('image/png'); }
          catch (err) { diag.taintErr = (err && err.message) || String(err); }

          // Aspect-preserving fit: width = A4 width (210mm), height
          // derived from canvas aspect. Compute pixel→mm scale from
          // the canvas's actual rasterised size (scale=2 multiplies
          // the 794-px CSS width to 1588).
          const canvasW = pageCanvas.width;
          const canvasH = pageCanvas.height;
          const mmPerPx = PDF_PAGE_WIDTH_MM / canvasW;
          let pageHeightMm = canvasH * mmPerPx;
          // Cap at A4 portrait height — anything taller is clipped.
          // In practice 5 entries comfortably fit under 297mm; this
          // is the safety net.
          if (pageHeightMm > PDF_PAGE_HEIGHT_MM) pageHeightMm = PDF_PAGE_HEIGHT_MM;

          const dataUrl = pageCanvas.toDataURL('image/jpeg', 0.92);
          if (i === 0) firstPageDataUrl = dataUrl;

          if (i > 0) pdf.addPage();
          try {
            pdf.addImage(dataUrl, 'JPEG', 0, 0, PDF_PAGE_WIDTH_MM, pageHeightMm);
          } catch (err) {
            diag.pdfError = (err && err.message) || String(err);
            throw err;
          }

          // BUG 10a fix (2026-05-15): explicit canvas cleanup so the GC
          // can reclaim the 1588×N bitmap before the next page renders.
          // Without this, iOS WKWebView held ~10MB per page in flight
          // and a 4-page render could trip the WebView's per-process
          // memory ceiling — visible as the page-2 spinner stalling
          // and then a hard reload. Shrinking width/height to 0 nudges
          // the canvas backing store free even if a stray reference
          // pins the wrapper.
          try {
            pageCanvas.width = 0;
            pageCanvas.height = 0;
          } catch (_) {}
          pageCanvas = null;

          diag.pagesRendered += 1;
        }

        try {
          pdfBlob = pdf.output('blob');
        } catch (err) {
          diag.pdfError = (err && err.message) || String(err);
          throw err;
        }
      } finally {
        // Restore live DOM regardless of success / failure. Nested-box
        // circuit chrome (attempt #10) is pure CSS — the animation
        // resumes on its own once `is-exporting` is removed.
        originalSrcs.forEach((src, img) => { try { img.src = src; } catch (_) {} });
        originalPosters.forEach((poster, v) => { try { v.poster = poster; } catch (_) {} });
        root.classList.remove('is-exporting');
      }

      if (!pdfBlob) {
        showExportError(
          formatExportError(diag, 'PDF assembly returned no blob'),
          () => { triggerLobbyShare().catch(() => {}); },
        );
        return;
      }

      const fileName = `homefit-plan-${Date.now()}.pdf`;
      const pdfFile = new File([pdfBlob], fileName, { type: 'application/pdf' });
      const blobUrl = URL.createObjectURL(pdfBlob);

      // Compose the share routing. Three surfaces, three paths:
      //   1. Embedded Flutter WebView (workflow Preview tab) → bridge.shareFile
      //   2. Mobile Safari → navigator.share({ files: [pdfFile] }) → iOS share sheet
      //   3. Desktop / fallback → modal Download anchor (already wired)
      const isEmbedded = (typeof window !== 'undefined'
        && typeof window.isHomefitEmbedded === 'function'
        && window.isHomefitEmbedded());

      const onShare = async () => {
        try {
          if (isEmbedded) {
            // Native bridge — base64-encode and forward. Dart writes
            // a temp file and surfaces UIActivityViewController (which
            // includes Save to Files, AirDrop, Messages, Mail, etc.).
            const b64 = await blobToBase64(pdfBlob);
            if (window.homefitBridge && typeof window.homefitBridge.shareFile === 'function') {
              window.homefitBridge.shareFile(b64, fileName, 'application/pdf');
              return;
            }
            // Backward-compat — older Dart side doesn't know shareFile yet.
            // Fall through to a window.open of the blob URL; iOS WKWebView
            // renders the PDF inline.
            try { window.open(blobUrl, '_blank'); } catch (_) {}
            return;
          }
          // Live web — try Web Share API with files first.
          if (navigator.canShare && navigator.canShare({ files: [pdfFile] })) {
            await navigator.share({
              files: [pdfFile],
              title: 'Your homefit plan',
              text: 'Your visual plan from homefit.studio',
            });
            return;
          }
          // Mobile Safari may reject files but still supports text-share —
          // open the blob URL in a new tab so iOS's PDF viewer takes over.
          try { window.open(blobUrl, '_blank'); } catch (_) {}
        } catch (err) {
          if (err && err.name === 'AbortError') return; // user cancelled
          try { console.warn('[homefit-lobby] share rejected:', err); } catch (_) {}
        }
      };

      // BUG 8 fix (2026-05-15): WKWebView ignores `<a download>` clicks
      // entirely. On the embedded Flutter surface, Download routes
      // through the same `homefitBridge.shareFile` path as Share — the
      // iOS share sheet UIActivityViewController already exposes Save
      // to Files, which is the practitioner's natural "download"
      // affordance on iOS. Live web + desktop fall through to the
      // anchor's native download behaviour (onDownload undefined).
      const onDownload = isEmbedded
        ? async () => {
            try {
              const b64 = await blobToBase64(pdfBlob);
              if (window.homefitBridge && typeof window.homefitBridge.shareFile === 'function') {
                window.homefitBridge.shareFile(b64, fileName, 'application/pdf');
                return;
              }
              // Bridge missing (older Dart side) — fall back to
              // window.open which iOS WKWebView renders inline.
              try { window.open(blobUrl, '_blank'); } catch (_) {}
            } catch (err) {
              try { console.warn('[homefit-lobby] download rejected:', err); } catch (_) {}
            }
          }
        : undefined;

      showExportModal({
        previewImageDataUrl: firstPageDataUrl || '',
        blobUrl,
        fileName,
        pageCount,
        onShare,
        onDownload,
        onRetry: () => { triggerLobbyShare().catch(() => {}); },
      });

      // 5-minute window before the blob URL is revoked — long enough for
      // a curious user to come back and re-download. Revoked unconditionally
      // when the modal closes (see close handler in ensureExportModal).
      setTimeout(() => {
        try { URL.revokeObjectURL(blobUrl); } catch (_) {}
      }, 5 * 60 * 1000);

      // On embedded surfaces, also auto-fire the share flow so the iOS
      // share sheet pops without the user having to tap Share. The modal
      // preview stays visible as a confirmation of WHAT they're sharing.
      // Mobile Safari requires a user gesture for navigator.share, so
      // we don't auto-fire there.
      if (isEmbedded) {
        // Small delay so the modal's preview has a chance to paint
        // before the share sheet covers the screen.
        setTimeout(() => { onShare().catch(() => {}); }, 250);
      }
    } catch (err) {
      try { console.warn('[homefit-lobby] PDF flow failed:', err); } catch (_) {}
      const headline = (err && err.message) || 'unexpected failure';
      showExportError(
        formatExportError(diag, headline),
        () => { triggerLobbyShare().catch(() => {}); },
      );
    } finally {
      if ($lobbyShareBtn) $lobbyShareBtn.disabled = false;
    }
  }

  // ==========================================================================
  // Expose
  // ==========================================================================

  window.HomefitLobby = Object.freeze({
    showLobby,
  });
})();
