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
  const $lobbyTreatmentRow = document.getElementById('lobby-treatment-row');
  const $lobbyStartBtn = document.getElementById('lobby-start-btn');
  const $lobbyGearBtn = document.getElementById('lobby-gear-btn');
  const $lobbySettingsPopover = document.getElementById('lobby-settings-popover');
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

  // Default plan title format used to detect default-named plans:
  // "{DD MMM YYYY HH:MM}" e.g. "04 May 2026 14:30".
  const DEFAULT_TITLE_RE = /^\d{1,2}\s+[A-Za-z]{3}\s+\d{4}\s+\d{1,2}:\d{2}$/;

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
   *   - getDefaultTreatment()      -> the practitioner's effective treatment
   *   - reFetchPlan()              -> refetch + replace plan in-place
   */
  function showLobby(args) {
    api = args.helpers;
    plan = args.plan;
    slides = args.slides || [];
    activeTreatment = api.getDefaultTreatment ? api.getDefaultTreatment() : 'line';

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

    // Build marker: "plan v{N} · web-player {PLAYER_VERSION} · cache {active cache}".
    // The plan segment surfaces `plans.version` (incremented on every
    // Publish) so a freshly-republished plan is distinguishable from a
    // stale tab on the same URL. PLAYER_VERSION is the bundle's
    // compile-time string (mirrors sw.js cache name by convention). The
    // cache name is read live from the SW so a stale browser shell shows
    // up as a divergence between the bundle and cache values. Legacy
    // plans whose `plans.version` is null drop the plan segment entirely.
    populateVersionChip();
  }

  function populateVersionChip() {
    if (!$lobbyMetaVersion) return;
    const playerVersion =
      typeof PLAYER_VERSION === 'string' ? PLAYER_VERSION : '?';
    const planVersion =
      plan && plan.version != null ? `plan v${plan.version}` : null;
    const compose = (cacheLabel) => [
      planVersion,
      `web-player ${playerVersion}`,
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
          //   2. fall back to "Circuit".
          const circuitName = (s.circuitName && String(s.circuitName).trim())
            || (plan && plan.circuit_names && plan.circuit_names[s.circuit_id])
            || null;
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
    const heroOffset = pickHeroOffset(slide);
    const isLandscape = ((Number(slide.aspect_ratio) || 1) >= 1);
    const objPos = isLandscape
      ? `${heroOffset * 100}% center`
      : `center ${heroOffset * 100}%`;

    // Hero element — picked per active treatment. For Line + B&W/Colour
    // videos we render <video> (Line uses line_drawing_url, B&W/Colour
    // use grayscale_url / original_url). Photos always render as <img>.
    const heroHTML = renderHeroHTML(slide, objPos);

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

  function circuitGroupHTML(group) {
    const escape = api.escapeHTML;
    // Hotfix round 3 — Fix B — circuit chrome rebuilt around a real
    // two-column layout per row. The rail now lives in a dedicated
    // `.lobby-row-gutter` column (a real flex child) instead of an
    // absolutely-positioned `::before` pseudo-element.
    //
    // Why: PR 235's pseudo-element rail was being covered by the
    // active-row's coral border (intentional UX — coral border on the
    // focused row is correct) AND vanished after the first row due to
    // a stacking-context bug. With a real column, the rail sits in its
    // own layout slot OUTSIDE the card's bounding box, so the active
    // row's border simply wraps around its content; nothing covers
    // the rail.
    //
    // Container: still transparent (no coral backdrop / no border). All
    // grouping is conveyed visually by the coral tree-branch rail —
    // header rail piece + per-row connectors that concatenate into a
    // single continuous line, with an └ corner closing the last row.
    //
    // The header gets the same two-column treatment (gutter + content).
    //
    // Cycles chip: `×3` only — no "ROUNDS" suffix.
    const labelText = group.circuitName
      ? group.circuitName
      : 'Circuit';
    const cyclesText = `×${group.rounds || 1}`;
    const lastIdx = group.rows.length - 1;
    const rows = group.rows.map((r, i) => {
      const isLast = i === lastIdx;
      // Rest-inside-circuit rows render as a rest <li>, but still get
      // the rail treatment + `last` flag so the └ corner lands cleanly
      // when a circuit ends on a rest (uncommon, but possible).
      const html = r.isRest
        ? restRowHTML(r.slide, r.slideIndex)
        : exerciseRowHTML(r.slide, r.slideIndex, { last: isLast, position: r.position });
      // Mark every in-circuit row with `is-circuit` (legacy hook) AND
      // `in-circuit` (mockup-spec alias). For rest rows, also append
      // `last` directly (restRowHTML doesn't take an opts arg).
      const lastMod = (isLast && r.isRest) ? ' last' : '';
      return html.replace(
        'class="lobby-row',
        `class="lobby-row is-circuit in-circuit${lastMod}`
      );
    }).join('');
    return `
      <li class="lobby-circuit-group" data-circuit="${escape(group.circuitId || '')}">
        <div class="lobby-circuit-header">
          <div class="lobby-circuit-header-gutter" aria-hidden="true">
            <span class="lobby-circuit-header-gutter-rail"></span>
            <span class="lobby-circuit-header-gutter-connector"></span>
          </div>
          <div class="lobby-circuit-header-content">
            <span class="lobby-circuit-header-label">${escape(labelText)}</span>
            <span class="lobby-circuit-header-cycles" aria-label="${escape(group.rounds || 1)} rounds">${escape(cyclesText)}</span>
          </div>
        </div>
        ${rows}
      </li>
    `;
  }

  /**
   * Round 6 — compose the dose-line via the central formatReps() +
   * formatHold() helpers exposed on `window.HomefitLobbyHandoff` (set
   * up by app.js). Single source of truth so the lobby and the deck's
   * active-slide-header always agree on:
   *   - `N × R reps` (uniform) vs `R1/R2/R3 reps` (varying)
   *   - hold-mode parenthetical: `Ns hold (each)` (per_rep) /
   *     `Ns hold` (end_of_set, default — no qualifier) /
   *     `Ns hold (end)` (end_of_exercise)
   *
   * Photos use the same hold rules; if the photo lacks a sets[] array
   * (legacy fallback), playSetsForSlide() synthesises a default-mode
   * single set so formatHold() emits the unqualified `Ns hold` form
   * — matching the brief's "fall back gracefully to the legacy
   * holdSeconds scalar with no qualifier" requirement.
   */
  function buildDoseLine(slide) {
    if (!slide || slide.media_type === 'rest') return '';
    if (slide.media_type === 'photo' || slide.media_type === 'image') {
      const playSets = (api.playSetsForSlide ? api.playSetsForSlide(slide) : []);
      const hold = (api.formatHold && api.formatHold(playSets)) || '';
      if (hold) return hold;
      return 'Reference position';
    }
    const playSets = (api.playSetsForSlide ? api.playSetsForSlide(slide) : []);
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
   * Render the hero element (img or video) for a slide based on the
   * current `activeTreatment`. Photos always render as <img>. Videos
   * (incl. Line — Wave 5 fix per Q7 of the spec) render as <video> with
   * `preload="none"` + poster; the scroll-driven row coupler lazy-loads
   * when the row enters the viewport (current ± 1) and pauses others.
   *
   * Treatment URLs (resolveTreatmentUrl from app.js):
   *   - line     → line_drawing_url (the actual line-drawing video; falls
   *                back to legacy media_url via the api.js normaliser).
   *   - bw       → grayscale_url (consent-gated; segmented body-pop variant
   *                preferred over the untouched original).
   *   - original → original_url.
   * Photos: line_drawing_url / grayscale_url / original_url all point at
   * a JPG; we render a static <img> and apply the B&W CSS filter when
   * applicable. (Wave 22 photo three-treatment parity.)
   */
  function renderHeroHTML(slide, objPos) {
    const escape = api.escapeHTML;
    const isPhoto = slide.media_type === 'photo' || slide.media_type === 'image';
    const url = api.resolveTreatmentUrl
      ? api.resolveTreatmentUrl(slide, activeTreatment)
      : (slide.line_drawing_url || slide.thumbnail_url || null);
    const fallbackPoster = slide.thumbnail_url || slide.line_drawing_url || '';

    if (!url && !fallbackPoster) {
      return `<div class="lobby-hero-skeleton" aria-hidden="true"></div>`;
    }

    if (isPhoto) {
      // Photos are always static. CSS grayscale filter handles the B&W
      // treatment off the same source JPG.
      const src = url || fallbackPoster;
      const grayscale = (activeTreatment === 'bw') ? ' is-grayscale' : '';
      return `
        <img class="lobby-hero-media${grayscale}"
             src="${escape(src || '')}"
             alt="${escape(slide.name || 'Exercise')}"
             style="object-position: ${escape(objPos)};"
             loading="lazy"
             data-treatment="${activeTreatment}">
      `;
    }

    // Video — Line / B&W / Colour all animate. preload="none" + poster;
    // the scroll coupler metadata-loads on enter and pauses on leave.
    const videoSrc = url || fallbackPoster;
    const grayscale = (activeTreatment === 'bw') ? ' is-grayscale' : '';
    return `
      <video class="lobby-hero-media${grayscale}"
             data-src="${escape(videoSrc)}"
             data-poster="${escape(fallbackPoster)}"
             poster="${escape(fallbackPoster)}"
             style="object-position: ${escape(objPos)};"
             playsinline muted loop preload="none"
             data-treatment="${activeTreatment}"
             data-trim-start="${Number(slide.start_offset_ms) || 0}"
             data-trim-end="${Number(slide.end_offset_ms) || 0}">
      </video>
    `;
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
        await new Promise((resolve) => setTimeout(resolve, 50));
      }

      // Re-resolve the URL for THIS row's slide using whatever
      // treatment the row was rendered for (data-treatment carries it).
      const refreshed = slides[slideIdx];
      if (!refreshed) return;
      const treatment = target.getAttribute('data-treatment') || activeTreatment;
      const newUrl = api.resolveTreatmentUrl
        ? api.resolveTreatmentUrl(refreshed, treatment)
        : (refreshed.line_drawing_url || refreshed.thumbnail_url || null);
      if (!newUrl) return;
      // Update both attributes so the scroll coupler (which reads
      // data-src on viewport-enter) picks up the fresh URL too.
      target.setAttribute('data-src', newUrl);
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
  // Treatment selector (Line / B&W / Colour)
  // ==========================================================================

  function renderTreatmentRow() {
    if (!$lobbyTreatmentRow) return;
    const buttons = $lobbyTreatmentRow.querySelectorAll('button[data-value]');
    buttons.forEach((btn) => {
      const value = btn.getAttribute('data-value');
      const isActive = value === activeTreatment;
      btn.setAttribute('aria-checked', isActive ? 'true' : 'false');
      // Append a lock glyph if not yet rendered.
      if (!btn.querySelector('.lobby-lock')) {
        const lock = document.createElement('span');
        lock.className = 'lobby-lock';
        lock.setAttribute('aria-hidden', 'true');
        lock.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><rect x="5" y="11" width="14" height="9" rx="2"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/></svg>';
        btn.appendChild(lock);
      }
      // Lock state.
      const locked = isLockedTreatment(value);
      btn.setAttribute('data-locked', locked ? 'true' : 'false');
    });
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
    // hero re-render, no analytics ping). Round 4 one-tap-to-pick UX:
    // a tap on any pill (including the active one) dismisses the
    // popover so the gear feels light.
    if (value === activeTreatment) {
      closeLobbySettingsPopover();
      return;
    }
    const previous = activeTreatment;
    activeTreatment = value;
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
    renderList();
    // Reset active sentinel so the post-render reducer paints a fresh
    // active state (the previous DOM is gone, so the cached idx is
    // stale). recomputeActiveRow() picks the row whose centre is closest
    // to the viewport centre — same row in practice, but the highlight
    // gets re-applied to the new DOM nodes.
    activeRowIndex = -1;
    requestAnimationFrame(() => {
      activateInitialRow();
      recomputeActiveRow();
    });
    // Round 4 — close the popover after a successful pick. One-tap UX.
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

  function openLobbySettingsPopover() {
    if (!$lobbySettingsPopover || !$lobbyGearBtn) return;
    if (isLobbySettingsPopoverOpen()) return;
    $lobbySettingsPopover.hidden = false;
    // Tick to let the browser paint `display:block` before the
    // opacity/transform transition kicks in.
    requestAnimationFrame(() => {
      $lobbySettingsPopover.setAttribute('data-open', 'true');
    });
    $lobbyGearBtn.setAttribute('aria-expanded', 'true');
  }

  function closeLobbySettingsPopover() {
    if (!$lobbySettingsPopover || !$lobbyGearBtn) return;
    if (!isLobbySettingsPopoverOpen()) {
      // If we're not open, still ensure aria + hidden agree.
      $lobbyGearBtn.setAttribute('aria-expanded', 'false');
      $lobbySettingsPopover.hidden = true;
      return;
    }
    $lobbySettingsPopover.removeAttribute('data-open');
    $lobbyGearBtn.setAttribute('aria-expanded', 'false');
    // Wait for the transition to finish before adding `hidden` back —
    // otherwise the close is a hard pop. Match the CSS `160ms`.
    setTimeout(() => {
      // Guard against a re-open that happened during the transition.
      if (!isLobbySettingsPopoverOpen()) {
        $lobbySettingsPopover.hidden = true;
      }
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
      activateInitialRow();
      recomputeActiveRow();
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
        recomputeActiveRow();
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
    if (!scrollContainer) return;
    const rows = $lobbyList.querySelectorAll('.lobby-row[data-slide-index]');
    if (!rows.length) return;

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
    const idx = parseInt(row.getAttribute('data-slide-index'), 10);
    if (Number.isNaN(idx) || idx === activeRowIndex) return;
    activeRowIndex = idx;

    // Highlight the row + the matching pill.
    $lobbyList.querySelectorAll('.lobby-row.is-active-pill').forEach((el) => el.classList.remove('is-active-pill'));
    row.classList.add('is-active-pill');
    $lobbyMatrixInner.querySelectorAll('.pill.is-active').forEach((el) => el.classList.remove('is-active'));
    const targetPill = $lobbyMatrixInner.querySelector(`.pill[data-slide="${idx}"]`);
    if (targetPill) {
      targetPill.classList.add('is-active');
      // Centre-on-active — scroll the matrix horizontally so the active
      // pill is centred. Parity with the deck's matrix behaviour.
      try {
        targetPill.scrollIntoView({ inline: 'center', block: 'nearest', behavior: 'smooth' });
      } catch (_) { /* older browsers */ }
    }
    // Lazy-load video heroes for current ± 1.
    lazyKickVideosNear(idx);
  }

  /**
   * Load metadata + start playback for hero <video> elements within the
   * current row range. Pause + reset others.
   */
  function lazyKickVideosNear(idx) {
    const rows = $lobbyList.querySelectorAll('.lobby-row[data-slide-index]');
    rows.forEach((row) => {
      const rIdx = parseInt(row.getAttribute('data-slide-index'), 10);
      const within = Math.abs(rIdx - idx) <= 1;
      const v = row.querySelector('video');
      if (!v) return;
      if (within && !prefersReducedMotion()) {
        // Load on demand.
        if (!v.src && v.dataset.src) {
          v.src = v.dataset.src;
        }
        const start = Number(v.dataset.trimStart) || 0;
        const playPromise = v.play();
        if (playPromise && playPromise.catch) playPromise.catch(() => { /* autoplay blocked */ });
        if (!v._lobbyTrimWired) {
          v._lobbyTrimWired = true;
          v.addEventListener('loadedmetadata', () => {
            if (start > 0) v.currentTime = Math.max(0, start / 1000);
          });
          v.addEventListener('timeupdate', () => {
            const end = Number(v.dataset.trimEnd) || 0;
            if (end > 0 && v.currentTime * 1000 >= end) {
              v.currentTime = Math.max(0, start / 1000);
            }
          });
          // Soft fallback for signed-URL expiry — let app.js's global
          // handler catch the error and refetch the plan.
        }
      } else {
        if (!v.paused) try { v.pause(); } catch (_) {}
        try { v.currentTime = 0; } catch (_) {}
      }
    });
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

    if ($lobbyTreatmentRow) {
      $lobbyTreatmentRow.addEventListener('click', (evt) => {
        const btn = evt.target.closest('button[data-value]');
        if (!btn) return;
        // Same stopPropagation guard as the gear — clicks inside the
        // popover must not register as "outside" the popover.
        evt.stopPropagation();
        onTreatmentClick(btn.getAttribute('data-value'));
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
      // Then the lobby settings popover.
      if (isLobbySettingsPopoverOpen()) {
        closeLobbySettingsPopover();
      }
    });
  }

  // ==========================================================================
  // Expose
  // ==========================================================================

  window.HomefitLobby = Object.freeze({
    showLobby,
  });
})();
