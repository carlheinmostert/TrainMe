/**
 * handout.js — workout handout page at /h/{planId}
 * =====================================================================
 *
 * Artifact-system Wave 1 (ADR 0025). Renders the live workout handout
 * from the same `get_plan_full` anon RPC the player uses. Treatment
 * toggle is consent-gated. Print button is window.print(). Claim chip
 * is wired but routes nowhere until Wave 2 magic-link claim lands —
 * the click handler is a soft no-op + TODO.
 *
 * Data-access: ALL Supabase I/O goes through `window.HomefitApi.getPlanFull`.
 * Per feedback_no_direct_db_access.md — never call /rest/v1/rpc/* directly
 * from this file. If a future capability needs a new RPC, register it on
 * api.js first.
 */

(function () {
  'use strict';

  // ===========================  Bootstrap  ===============================

  const planId = extractPlanIdFromPath();
  if (!planId) {
    showError();
    return;
  }

  // Render-state. We keep this in a closure rather than mutating the DOM
  // imperatively from many sites — single source of truth.
  const state = {
    plan: null,
    exercises: [],
    artifacts: [],
    consent: { line_drawing: true, grayscale: false, original: false },
    treatment: 'line', // 'line' | 'bw' | 'original'
  };

  // Kick off the load.
  loadHandout(planId).catch((err) => {
    try { console.error('[handout] load failed:', err); } catch (_) {}
    showError();
  });

  // ===========================  Plan loading  ============================

  function extractPlanIdFromPath() {
    // Pattern: /h/{planId}
    const match = (window.location.pathname || '').match(/^\/h\/([A-Za-z0-9_-]+)\/?$/);
    if (!match) return null;
    return match[1];
  }

  async function loadHandout(id) {
    if (!window.HomefitApi || typeof window.HomefitApi.getPlanFull !== 'function') {
      throw new Error('HomefitApi not loaded');
    }

    let payload;
    try {
      payload = await window.HomefitApi.getPlanFull(id);
    } catch (err) {
      throw err;
    }
    if (!payload || !payload.plan) {
      throw new Error('Plan not found');
    }

    state.plan = payload.plan;
    state.exercises = Array.isArray(payload.exercises) ? payload.exercises : [];
    state.artifacts = Array.isArray(payload.artifacts) ? payload.artifacts : [];

    // Derive consent flags from the first exercise's URLs. The RPC nulls
    // grayscale_url / original_url when the client hasn't consented, so
    // the presence of a non-null URL on ANY exercise == that treatment is
    // available. (Per-exercise consent doesn't exist; consent is plan-grain
    // via clients.video_consent.)
    state.consent = deriveConsent(state.exercises);

    // Best-effort: stamp the per-artifact open. The RPC is a no-op if no
    // handout row exists yet (Wave 1 — the row gets minted by Wave 3's
    // multi-select publish gate; the page still renders for plans that
    // haven't been explicitly "handout-published" because the source data
    // is the same).
    try {
      recordHandoutOpened(id);
    } catch (_) { /* best-effort */ }

    render();
  }

  function deriveConsent(exercises) {
    const consent = { line_drawing: true, grayscale: false, original: false };
    for (const ex of exercises) {
      if (ex && ex.grayscale_url) consent.grayscale = true;
      if (ex && ex.original_url) consent.original = true;
    }
    return consent;
  }

  // ===========================  Render pass  =============================

  function render() {
    const $page = document.getElementById('handout-page');
    const $loading = document.getElementById('handout-loading');
    if (!$page || !$loading) return;

    renderHeader();
    renderTreatmentToggle();
    renderExerciseList();
    renderSealVersion();
    bindEvents();

    $loading.hidden = true;
    $page.hidden = false;

    // Update <title> + OG fallback so the bare URL (when bots don't hit
    // middleware) still shows the right copy on share. Bot user-agents
    // get the rewritten OG block from web-player/middleware.js.
    const title = state.plan.title || 'Your workout handout';
    document.title = title + ' — homefit.studio';
  }

  function renderHeader() {
    const $title = document.getElementById('handout-title');
    const $byline = document.getElementById('handout-byline');
    if ($title) $title.textContent = state.plan.title || 'Your workout';
    if ($byline) {
      const practitioner = practitionerLabel(state.plan);
      const practice = state.plan.practice_name || '';
      const parts = [];
      if (practitioner) parts.push('<b>' + escapeHtml(practitioner) + '</b>');
      if (practice) parts.push(escapeHtml(practice));
      $byline.innerHTML = parts.length ? ('from ' + parts.join(' · ')) : '';
    }
  }

  function practitionerLabel(plan) {
    // The plan row carries trainer info via to_jsonb(plan_row); fields are
    // not guaranteed across schema versions, so pick whatever's present.
    if (!plan) return '';
    return plan.trainer_display_name
      || plan.trainer_name
      || '';
  }

  function renderTreatmentToggle() {
    const $treatment = document.getElementById('handout-treatment');
    if (!$treatment) return;
    const buttons = $treatment.querySelectorAll('.handout-seg-item');
    buttons.forEach((btn) => {
      const t = btn.getAttribute('data-treatment');
      let available = true;
      if (t === 'bw') available = state.consent.grayscale;
      if (t === 'original') available = state.consent.original;

      btn.classList.toggle('is-locked', !available);
      btn.disabled = !available;
      btn.setAttribute('aria-selected', t === state.treatment ? 'true' : 'false');
      btn.classList.toggle('is-active', t === state.treatment);

      // Add a lock glyph for unavailable treatments (mockup parity).
      const existingLock = btn.querySelector('.lock-glyph');
      if (!available && !existingLock) {
        const lock = document.createElement('span');
        lock.className = 'lock-glyph';
        lock.setAttribute('aria-hidden', 'true');
        lock.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="5" y="11" width="14" height="9" rx="1.5"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/></svg>';
        btn.appendChild(lock);
      } else if (available && existingLock) {
        existingLock.remove();
      }
    });
  }

  function renderExerciseList() {
    const $list = document.getElementById('handout-list');
    if (!$list) return;
    $list.innerHTML = '';

    let currentCircuit = null;
    let circuitGroup = null;
    let circuitIndex = 0;

    state.exercises.forEach((ex, idx) => {
      const circuitId = ex && ex.circuit_id;
      const isRest = ex && ex.media_type === 'rest';

      // Close out previous circuit group when the circuit changes.
      if (circuitId !== currentCircuit) {
        currentCircuit = circuitId;
        circuitGroup = null;
        if (circuitId) {
          circuitIndex += 1;
          const cycles = circuitCyclesForId(state.plan, circuitId) || 1;
          const $h = document.createElement('div');
          $h.className = 'handout-circuit-h';
          $h.innerHTML =
            '<span>Circuit · ' + escapeHtml(String(cycles)) + ' round'
            + (cycles === 1 ? '' : 's')
            + '</span><span class="line"></span>';
          $list.appendChild($h);

          circuitGroup = document.createElement('div');
          circuitGroup.className = 'handout-circuit-group';
          $list.appendChild(circuitGroup);
        }
      }

      const $node = isRest
        ? buildRestNode(ex)
        : buildExerciseNode(ex, idx + 1);
      (circuitGroup || $list).appendChild($node);
    });
  }

  function circuitCyclesForId(plan, circuitId) {
    if (!plan || !plan.circuit_cycles || !circuitId) return 1;
    let map = plan.circuit_cycles;
    // The RPC returns jsonb that PostgREST shapes as a real object; guard
    // against legacy string-encoded JSON anyway.
    if (typeof map === 'string') {
      try { map = JSON.parse(map); } catch (_) { return 1; }
    }
    if (typeof map !== 'object') return 1;
    const n = Number(map[circuitId]);
    return Number.isFinite(n) && n > 0 ? n : 1;
  }

  function buildExerciseNode(ex, position) {
    const $wrap = document.createElement('div');
    $wrap.className = 'handout-ex';

    const thumbUrl = resolveThumbnailForTreatment(ex, state.treatment);
    const isBw = state.treatment === 'bw' && thumbUrl;

    const $thumb = document.createElement('div');
    $thumb.className = 'handout-ex-thumb' + (isBw ? ' is-bw' : '');
    if (thumbUrl) {
      const $img = document.createElement('img');
      $img.alt = '';
      $img.loading = 'lazy';
      $img.src = thumbUrl;
      $thumb.appendChild($img);
    } else {
      // Fallback: figure glyph placeholder so the row still has a thumb.
      const $fig = document.createElement('span');
      $fig.className = 'handout-ex-fig';
      $fig.setAttribute('aria-hidden', 'true');
      $fig.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.4"><circle cx="12" cy="5" r="2"/><path d="M12 7v6M8 11l4-2 4 2M9 13l-1.5 6M15 13l1.5 6"/></svg>';
      $thumb.appendChild($fig);
    }
    const $num = document.createElement('span');
    $num.className = 'handout-ex-num';
    $num.textContent = String(position);
    $thumb.appendChild($num);

    const $body = document.createElement('div');
    $body.className = 'handout-ex-body';

    const $name = document.createElement('div');
    $name.className = 'handout-ex-name';
    $name.textContent = ex.name || 'Exercise';
    $body.appendChild($name);

    const $stats = document.createElement('div');
    $stats.className = 'handout-ex-stats';
    $stats.innerHTML = renderStatsHTML(ex);
    $body.appendChild($stats);

    if (ex.notes && ex.notes.trim().length > 0) {
      const $note = document.createElement('div');
      $note.className = 'handout-ex-note';
      $note.textContent = ex.notes.trim();
      $body.appendChild($note);
    }

    $wrap.appendChild($thumb);
    $wrap.appendChild($body);
    return $wrap;
  }

  function buildRestNode(ex) {
    const $wrap = document.createElement('div');
    $wrap.className = 'handout-rest';

    const $dot = document.createElement('span');
    $dot.className = 'handout-rest-dot';
    $wrap.appendChild($dot);

    const $label = document.createElement('span');
    $label.className = 'handout-rest-label';
    $label.textContent = 'Rest';
    $wrap.appendChild($label);

    const seconds = Number(ex && ex.rest_seconds) || 0;
    if (seconds > 0) {
      const $dur = document.createElement('span');
      $dur.className = 'handout-rest-duration';
      $dur.textContent = formatDuration(seconds);
      $wrap.appendChild($dur);
    }
    return $wrap;
  }

  function renderStatsHTML(ex) {
    const sets = Array.isArray(ex.sets) ? ex.sets : [];
    const totalSets = sets.length;
    const parts = [];

    if (totalSets > 0) {
      // Reps — show the most-common reps value, falling back to "varies".
      const repsValues = sets.map((s) => Number(s && s.reps) || 0).filter((n) => n > 0);
      if (repsValues.length > 0) {
        const allSame = repsValues.every((r) => r === repsValues[0]);
        const repsLabel = allSame ? String(repsValues[0]) : (Math.min(...repsValues) + '–' + Math.max(...repsValues));
        parts.push('<span class="stat"><b>' + escapeHtml(repsLabel) + '</b> reps</span>');
      }

      // Sets count.
      parts.push('<span class="stat"><b>' + totalSets + '</b> set' + (totalSets === 1 ? '' : 's') + '</span>');

      // Hold — pick the first non-zero hold across the sets + its mode.
      const holdSet = sets.find((s) => Number(s && s.hold_seconds) > 0);
      if (holdSet) {
        const hold = Number(holdSet.hold_seconds);
        const mode = holdSet.hold_position;
        let modeLabel = '';
        if (mode === 'per_rep') modeLabel = 'hold';
        else if (mode === 'end_of_set') modeLabel = 'hold end-of-set';
        else if (mode === 'end_of_exercise') modeLabel = 'hold end';
        else modeLabel = 'hold';
        parts.push('<span class="stat">' + escapeHtml(modeLabel) + ' <b>' + hold + 's</b></span>');
      }
    }

    return parts.join('');
  }

  function resolveThumbnailForTreatment(ex, treatment) {
    if (!ex) return null;
    // Three-treatment thumbs (post Wave Three-Treatment-Thumbs):
    //   thumbnail_url_line (always when available)
    //   thumbnail_url_color (consent-gated)
    //   thumbnail_url_bw    (photos only)
    if (treatment === 'line') {
      return ex.thumbnail_url_line || ex.thumbnail_url || null;
    }
    if (treatment === 'bw') {
      // Photos have a dedicated bw thumb. Videos fall back to the color
      // thumb with a CSS grayscale filter (handled by .is-bw on the wrap).
      return ex.thumbnail_url_bw || ex.thumbnail_url_color || ex.thumbnail_url_line || ex.thumbnail_url || null;
    }
    if (treatment === 'original') {
      return ex.thumbnail_url_color || ex.thumbnail_url_line || ex.thumbnail_url || null;
    }
    return ex.thumbnail_url_line || ex.thumbnail_url || null;
  }

  // ===========================  Footer seal version  =====================

  function renderSealVersion() {
    const $v = document.getElementById('handout-seal-version');
    if (!$v) return;
    const version = state.plan && state.plan.version ? state.plan.version : 1;
    // Use the published_at from the handout artifact if available, else
    // fall back to plans.last_published_at or now.
    const handoutArtifact = (state.artifacts || []).find((a) => a && a.kind === 'handout');
    const planUrlArtifact = (state.artifacts || []).find((a) => a && a.kind === 'plan_url');
    const stampSource =
      (handoutArtifact && handoutArtifact.published_at)
      || (planUrlArtifact && planUrlArtifact.published_at)
      || state.plan.last_published_at
      || null;
    const stamp = stampSource ? formatVersionStamp(new Date(stampSource)) : 'unstamped';
    $v.textContent = 'v' + version + ' · ' + stamp;
  }

  function formatVersionStamp(date) {
    if (!(date instanceof Date) || isNaN(date.getTime())) return 'unstamped';
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    const d = date.getDate();
    const m = months[date.getMonth()];
    const y = date.getFullYear();
    const hh = String(date.getHours()).padStart(2, '0');
    const mm = String(date.getMinutes()).padStart(2, '0');
    return d + ' ' + m + ' ' + y + ' ' + hh + ':' + mm;
  }

  function formatDuration(seconds) {
    const s = Math.max(0, Math.round(seconds));
    if (s < 60) return s + 's';
    const m = Math.floor(s / 60);
    const r = s % 60;
    return r === 0 ? (m + 'm') : (m + 'm ' + r + 's');
  }

  // ===========================  Events  ==================================

  function bindEvents() {
    const $print = document.getElementById('handout-print-btn');
    if ($print) {
      $print.addEventListener('click', () => {
        // Best path on every browser: window.print() against the
        // @media print stylesheet in handout.css. Hides claim chip +
        // treatment toggle + print button; lays out paper-friendly.
        try { window.print(); } catch (_) {}
      });
    }

    const $treatment = document.getElementById('handout-treatment');
    if ($treatment) {
      $treatment.addEventListener('click', (event) => {
        const target = event.target && event.target.closest
          ? event.target.closest('.handout-seg-item')
          : null;
        if (!target || target.classList.contains('is-locked')) return;
        const t = target.getAttribute('data-treatment');
        if (!t || t === state.treatment) return;
        state.treatment = t;
        renderTreatmentToggle();
        renderExerciseList();
      });
    }

    const $claim = document.getElementById('handout-claim');
    if ($claim) {
      $claim.addEventListener('click', (event) => {
        // Wave 2: route to /me with the current plan as the claim target.
        // The /me page magic-link form pre-fills the redirect with
        // ?claim={planId} so the eventual click-through attaches THIS
        // plan to the new consumer account.
        if (event.target && event.target.closest('.handout-claim-x')) return;
        try {
          window.location.assign('/me?claim=' + encodeURIComponent(planId));
        } catch (_) {
          // Fall back to a logged hint if navigation fails (e.g. CSP
          // restriction or embedded surface).
          try { console.info('[handout] claim chip clicked — /me unreachable (plan_id=' + planId + ')'); } catch (_) {}
        }
      });
    }

    const $claimX = document.getElementById('handout-claim-x');
    if ($claimX) {
      $claimX.addEventListener('click', (event) => {
        event.stopPropagation();
        const $claim = document.getElementById('handout-claim');
        if ($claim) $claim.hidden = true;
      });
    }
  }

  // ===========================  Best-effort RPCs  ========================

  async function recordHandoutOpened(id) {
    // Per ADR 0022 / Wave 1 schema delta: stamp first_opened_at on the
    // plan_artifacts row keyed by (plan_id, kind='handout'). Anonymous-
    // callable per ADR 0024. Best-effort: errors are caught + logged.
    // The RPC is added to api.js as window.HomefitApi.recordArtifactOpened
    // in this same commit.
    if (!window.HomefitApi || typeof window.HomefitApi.recordArtifactOpened !== 'function') {
      return;
    }
    try {
      await window.HomefitApi.recordArtifactOpened(id, 'handout');
    } catch (err) {
      try { console.warn('[handout] record_artifact_opened failed:', err); } catch (_) {}
    }
  }

  // ===========================  Helpers  =================================

  function showError() {
    const $loading = document.getElementById('handout-loading');
    const $page = document.getElementById('handout-page');
    const $err = document.getElementById('handout-error');
    if ($loading) $loading.hidden = true;
    if ($page) $page.hidden = true;
    if ($err) $err.hidden = false;
  }

  function escapeHtml(str) {
    if (str === null || str === undefined) return '';
    return String(str)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }
})();
