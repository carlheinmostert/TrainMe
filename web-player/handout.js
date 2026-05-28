/**
 * handout.js — Printable Workout Guide at /h/{planId}
 * =====================================================================
 *
 * A near-twin of the Interactive Workout Guide lobby (/p/{planId}).
 * Artifact-consistency pass 2 (2026-05-28): the printable now shares the
 * lobby's exercise CARD renderer + interactivity engine (exercise_card.js)
 * and the standard footer seal, so the two surfaces look nearly identical
 * on the first page. The ONLY intended first-page differences are the
 * Print button (here) vs the Start Workout button (lobby).
 *
 * Key alignment decisions (this surface MUST match the lobby, not redefine):
 *   - Card = HomefitExerciseCard.buildListHTML — the lobby's large 1:1
 *     hero card, circuit grouping (plan.circuit_names + letter fallback),
 *     shared dose grammar. No parallel rep/hold logic.
 *   - INTERACTIVE on screen — HomefitExerciseCard.createInteractivity drives
 *     the active-card highlight + active-row img→video swap as you scroll.
 *     @media print (handout.css) flattens everything to a static document.
 *     The printable does NOT get the guided-workout flow (no Start Workout,
 *     pill matrix, prep countdown, timers, rep stack) — that stays the
 *     Interactive Guide's distinguishing feature. The printable is a
 *     browseable interactive REFERENCE that also prints.
 *   - Get-the-app block = the lobby's PLAIN dark card + canonical glyph,
 *     at the TOP, rendered ONLY on the public web (!isLocalSurface()).
 *   - Footer = the standard "powered by homefit.studio" seal + matrix glyph
 *     + real referral QR (local, CSP-clean) + "Visual plans clients follow."
 *     tagline. NO version line in the seal.
 *   - Byline practitioner name from get_plan_sharing_context (the same
 *     source the lobby uses) with "your practitioner" fallback.
 *
 * Print button is window.print(). Claim chip routes to /me?claim={planId}.
 *
 * Data-access: ALL Supabase I/O goes through `window.HomefitApi`.
 * Per feedback_no_direct_db_access.md.
 */

(function () {
  'use strict';

  // ===========================  Bootstrap  ===============================

  const LOAD_WATCHDOG_MS = 15000;
  let _loadComplete = false;
  let _interactivity = null;
  const _watchdog = setTimeout(() => {
    if (_loadComplete) return;
    _loadComplete = true;
    try { console.error('[handout] load watchdog fired — forcing error state'); } catch (_) {}
    showError('Load took too long. Please check your connection and try again.');
  }, LOAD_WATCHDOG_MS);

  const planId = extractPlanIdFromPath();
  if (!planId) {
    _loadComplete = true;
    clearTimeout(_watchdog);
    showError('Invalid plan link.');
    return;
  }

  // Single source of truth for render state.
  const state = {
    plan: null,
    exercises: [],
    artifacts: [],
    practitionerName: '',
  };

  // Pre-flight: api.js + config.js must have loaded successfully.
  if (!window.HomefitApi || typeof window.HomefitApi.getPlanFull !== 'function') {
    _loadComplete = true;
    clearTimeout(_watchdog);
    try {
      console.error(
        '[handout] window.HomefitApi missing — api.js failed at module '
        + 'load. Likely cause: stale cached handout.html missing '
        + '<script src="/config.js">. Hard-refresh / clear app cache.'
      );
    } catch (_) {}
    showError('Page failed to initialise. Please reload.');
    return;
  }

  loadHandout(planId).then(() => {
    _loadComplete = true;
    clearTimeout(_watchdog);
  }).catch((err) => {
    _loadComplete = true;
    clearTimeout(_watchdog);
    try { console.error('[handout] load failed:', err); } catch (_) {}
    const reason = err && err.message ? String(err.message) : '';
    showError(reason || null);
  });

  // ===========================  Plan loading  ============================

  function extractPlanIdFromPath() {
    const match = (window.location.pathname || '').match(/^\/h\/([A-Za-z0-9_-]+)\/?$/);
    if (!match) return null;
    return match[1];
  }

  function isLocalSurface() {
    // Delegate to api.js's canonical detector (embedded in-app WebView vs
    // the public web). Defensive default: treat unknown as public web so
    // the get-app block shows rather than silently hiding.
    if (window.HomefitApi && typeof window.HomefitApi.isLocalSurface === 'function') {
      try { return !!window.HomefitApi.isLocalSurface(); } catch (_) { return false; }
    }
    return false;
  }

  async function loadHandout(id) {
    if (!window.HomefitApi || typeof window.HomefitApi.getPlanFull !== 'function') {
      throw new Error('HomefitApi not loaded');
    }

    const payload = await window.HomefitApi.getPlanFull(id);
    if (!payload || !payload.plan) {
      throw new Error('Plan not found');
    }

    state.plan = payload.plan;
    state.exercises = Array.isArray(payload.exercises) ? payload.exercises : [];
    state.artifacts = Array.isArray(payload.artifacts) ? payload.artifacts : [];

    // 2026-05-17 — append `?v=<plan.version>` to per-exercise thumb URLs so
    // each republish forces a fresh fetch through every cache layer. Mirrors
    // lobby.js showLobby's cache-buster so the two surfaces fetch the same
    // bytes.
    bustThumbCaches(state.plan, state.exercises);

    // Brand-skin (Wave 4, ADR-0029). Unchanged from the prior handout.
    applySkin(state.plan);

    // Practitioner name — same source the lobby uses (get_plan_sharing_context
    // -> practitioner_name). Best-effort: the byline renders without it.
    // Fired in parallel with render so the byline updates when it resolves.
    fetchPractitionerName(id);

    // Best-effort per-artifact open stamp.
    try { recordHandoutOpened(id); } catch (_) { /* best-effort */ }

    render();
  }

  function bustThumbCaches(plan, exercises) {
    if (!plan || plan.version == null || !Array.isArray(exercises)) return;
    const v = String(plan.version);
    const thumbKeys = ['thumbnail_url', 'thumbnail_url_line', 'thumbnail_url_color', 'thumbnail_url_bw'];
    for (let i = 0; i < exercises.length; i++) {
      const ex = exercises[i];
      if (!ex) continue;
      for (let j = 0; j < thumbKeys.length; j++) {
        const k = thumbKeys[j];
        const u = ex[k];
        if (typeof u !== 'string' || !u || u.indexOf('?v=') !== -1) continue;
        ex[k] = u + (u.indexOf('?') === -1 ? '?v=' : '&v=') + v;
      }
    }
  }

  async function fetchPractitionerName(id) {
    if (!window.HomefitApi || typeof window.HomefitApi.getPlanSharingContext !== 'function') {
      return;
    }
    try {
      const ctx = await window.HomefitApi.getPlanSharingContext(id);
      const name = ctx && (ctx.practitioner_name || '').trim();
      if (name) {
        state.practitionerName = name;
        // Re-paint the byline now that we have the real name.
        try { renderHeader(); } catch (_) {}
      }
    } catch (err) {
      try { console.warn('[handout] get_plan_sharing_context failed:', err); } catch (_) {}
    }
  }

  // ===========================  Brand-skin  ==============================

  function applySkin(plan) {
    if (!plan) return;
    const active = plan.brand_skin_active === true;
    const colorRaw = (plan.brand_color || '').trim();
    const practiceName = (plan.practice_name || '').trim();
    const logoUrl = (plan.public_logo_url || '').trim();
    if (!active || !colorRaw || !practiceName) {
      clearSkin();
      return;
    }
    if (!/^#[0-9A-Fa-f]{6}$/.test(colorRaw)) {
      clearSkin();
      return;
    }

    const rgb = hexToRgb(colorRaw);
    if (!rgb) return;
    const dark = mixWithBlack(rgb, 0.18);
    const light = mixWithWhite(rgb, 0.18);

    const body = document.body;
    if (!body) return;
    body.classList.add('skin-active');
    body.setAttribute('data-skin-practice', (plan.practice_id || '').toString());

    body.style.setProperty('--practice-brand-color', colorRaw);
    body.style.setProperty('--practice-brand-color-dark', rgbToHex(dark));
    body.style.setProperty('--practice-brand-color-light', rgbToHex(light));
    body.style.setProperty('--practice-brand-tint-bg', 'rgba(' + rgb.r + ', ' + rgb.g + ', ' + rgb.b + ', 0.12)');
    body.style.setProperty('--practice-brand-tint-border', 'rgba(' + rgb.r + ', ' + rgb.g + ', ' + rgb.b + ', 0.30)');
    body.style.setProperty('--practice-brand-glyph-bg', 'rgba(' + rgb.r + ', ' + rgb.g + ', ' + rgb.b + ', 0.18)');

    const $skin = document.getElementById('handout-brand-skin');
    if (!$skin) return;
    $skin.removeAttribute('aria-hidden');
    const $glyph = $skin.querySelector('.handout-brand-skin-glyph');
    const $name  = $skin.querySelector('.handout-brand-skin-name');
    const $tag   = $skin.querySelector('.handout-brand-skin-tag');
    if ($glyph) {
      if (logoUrl) {
        $glyph.innerHTML = '';
        const $img = document.createElement('img');
        $img.src = logoUrl;
        $img.alt = '';
        $img.width = 22;
        $img.height = 22;
        $img.style.borderRadius = '4px';
        $img.style.objectFit = 'contain';
        $glyph.appendChild($img);
      } else {
        $glyph.innerHTML =
          '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" ' +
          'stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">' +
          '<circle cx="12" cy="5.5" r="2.2"/>' +
          '<path d="M12 7.7 L 12 14.5"/>' +
          '<path d="M12 10.5 L 6.5 8"/>' +
          '<path d="M12 10.5 L 17.5 8"/>' +
          '<path d="M12 14.5 L 8.5 19.5"/>' +
          '<path d="M12 14.5 L 15.5 19.5"/>' +
          '</svg>';
      }
    }
    if ($name) $name.textContent = practiceName;
    if ($tag) {
      const tagline = (plan.tagline || '').trim();
      $tag.textContent = tagline;
      $tag.style.display = tagline ? '' : 'none';
    }
  }

  function clearSkin() {
    const body = document.body;
    if (!body) return;
    body.classList.remove('skin-active');
    body.removeAttribute('data-skin-practice');
    body.style.removeProperty('--practice-brand-color');
    body.style.removeProperty('--practice-brand-color-dark');
    body.style.removeProperty('--practice-brand-color-light');
    body.style.removeProperty('--practice-brand-tint-bg');
    body.style.removeProperty('--practice-brand-tint-border');
    body.style.removeProperty('--practice-brand-glyph-bg');
  }

  function hexToRgb(hex) {
    const r = parseInt(hex.slice(1, 3), 16);
    const g = parseInt(hex.slice(3, 5), 16);
    const b = parseInt(hex.slice(5, 7), 16);
    if (Number.isNaN(r) || Number.isNaN(g) || Number.isNaN(b)) return null;
    return { r: r, g: g, b: b };
  }
  function rgbToHex(rgb) {
    const toHex = (n) => {
      const clamped = Math.max(0, Math.min(255, Math.round(n)));
      const s = clamped.toString(16);
      return s.length === 1 ? '0' + s : s;
    };
    return '#' + toHex(rgb.r) + toHex(rgb.g) + toHex(rgb.b);
  }
  function mixWithBlack(rgb, t) {
    return { r: rgb.r * (1 - t), g: rgb.g * (1 - t), b: rgb.b * (1 - t) };
  }
  function mixWithWhite(rgb, t) {
    return {
      r: rgb.r + (255 - rgb.r) * t,
      g: rgb.g + (255 - rgb.g) * t,
      b: rgb.b + (255 - rgb.b) * t,
    };
  }

  // ===========================  Render pass  =============================

  function render() {
    const $page = document.getElementById('handout-page');
    const $loading = document.getElementById('handout-loading');
    if (!$page || !$loading) {
      throw new Error('Page DOM not ready — handout chrome elements missing.');
    }

    try { renderHeader(); }
      catch (e) { try { console.warn('[handout] renderHeader failed:', e); } catch(_){} }
    try { renderImportBlock(); }
      catch (e) { try { console.warn('[handout] renderImportBlock failed:', e); } catch(_){} }
    try { renderExerciseList(); }
      catch (e) { try { console.warn('[handout] renderExerciseList failed:', e); } catch(_){} }
    try { renderSeal(); }
      catch (e) { try { console.warn('[handout] renderSeal failed:', e); } catch(_){} }
    try { bindEvents(); }
      catch (e) { try { console.warn('[handout] bindEvents failed:', e); } catch(_){} }

    $loading.hidden = true;
    $page.hidden = false;

    // Wire scroll-driven interactivity AFTER first paint so measured offsets
    // are accurate. The printable scrolls the document/body (no fixed inner
    // scroller), so the shared engine listens on window scroll.
    try { setupInteractivity(); }
      catch (e) { try { console.warn('[handout] setupInteractivity failed:', e); } catch(_){} }

    try {
      const title = (state.plan && state.plan.title) || 'Your Printable Workout Guide';
      document.title = title + ' — homefit.studio';
    } catch (_) { /* cosmetic */ }
  }

  function renderHeader() {
    const $title = document.getElementById('handout-title');
    const $byline = document.getElementById('handout-byline');
    if ($title) $title.textContent = (state.plan && state.plan.title) || 'Your workout';
    if ($byline) {
      // Practitioner name from get_plan_sharing_context (same source as the
      // lobby). Falls back to "your practitioner" when not yet resolved.
      const practitioner = state.practitionerName || '';
      const practice = (state.plan && state.plan.practice_name) || '';
      const parts = [];
      if (practitioner) parts.push('<b>' + escapeHtml(practitioner) + '</b>');
      else parts.push('<b>your practitioner</b>');
      if (practice) parts.push(escapeHtml(practice));
      $byline.innerHTML = 'from ' + parts.join(' · ');
    }
  }

  // ===========================  Exercise list  ===========================
  //
  // Uses the shared card renderer (HomefitExerciseCard) so the markup is
  // byte-identical to the lobby. Circuit grouping + dose grammar + hero
  // resolution all flow through the shared module.

  function renderExerciseList() {
    const $list = document.getElementById('handout-list');
    if (!$list) return;
    if (!window.HomefitExerciseCard || !window.HomefitExerciseCard.buildListHTML) {
      // Defensive — exercise_card.js failed to load. Render nothing rather
      // than a broken half-list; the watchdog + error state cover the
      // truly-failed case, but a missing optional module shouldn't blank
      // the whole page.
      try { console.warn('[handout] HomefitExerciseCard missing — list not rendered.'); } catch (_) {}
      return;
    }

    // Pass the shared whole-exercise duration estimator (HomefitDose) so the
    // dose line carries the SAME trailing `~Xs` segment the Interactive lobby
    // shows — the two dose lines read identically.
    const helpers = {};
    if (window.HomefitDose && typeof window.HomefitDose.calculateDuration === 'function') {
      helpers.calculateDuration = window.HomefitDose.calculateDuration;
    }
    $list.innerHTML = window.HomefitExerciseCard.buildListHTML(
      state.exercises,
      state.plan,
      helpers
    );

    // Bake 1:1 hero crops (same path the lobby uses).
    window.HomefitExerciseCard.hydrateHeroCrops($list);
  }

  function setupInteractivity() {
    const $list = document.getElementById('handout-list');
    if (!$list) return;
    if (!window.HomefitExerciseCard || !window.HomefitExerciseCard.createInteractivity) return;
    if (_interactivity) {
      try { _interactivity.destroy(); } catch (_) {}
      _interactivity = null;
    }
    _interactivity = window.HomefitExerciseCard.createInteractivity({
      list: $list,
      scroller: document.scrollingElement || document.documentElement,
    });
    // Light the first card so the active-card highlight is present before the
    // first scroll (mirrors the lobby's activateInitialRow). Activate
    // immediately, then once more on the next frame in case layout shifts as
    // hero crops / fonts settle. Don't rely on rAF alone — in a backgrounded
    // / non-painting context (some headless surfaces) rAF can be starved, so
    // the synchronous call is the guarantee and the rAF is the refinement.
    const ctrl = _interactivity;
    try { ctrl.activateInitialRow(); } catch (_) {}
    requestAnimationFrame(() => {
      try { ctrl.activateInitialRow(); } catch (_) {}
    });
  }

  // ===========================  Get-the-app block  =======================
  //
  // Standardised with the lobby's #lobby-import-card (task 3): the canonical
  // buildHomefitLogoSvg() glyph in a PLAIN dark card, at the TOP, the same
  // "Save this plan to your phone" framing, the same /me?claim={planId}
  // destination. Rendered ONLY on the public web — in the embedded in-app
  // WebView the device is already linked, so the block stays hidden.

  function renderImportBlock() {
    const $card = document.getElementById('handout-import-card');
    if (!$card) return;

    // Surface gating — hide entirely inside the embedded in-app WebView.
    if (isLocalSurface()) {
      $card.hidden = true;
      return;
    }

    // Stamp the claim target so /me attaches THIS plan on sign-in.
    if (state.plan && state.plan.id) {
      $card.setAttribute('href', '/me?claim=' + encodeURIComponent(state.plan.id));
    }

    const $glyph = document.getElementById('handout-import-glyph');
    if ($glyph && !$glyph.innerHTML) {
      const buildLogo = resolveBuildLogo();
      if (buildLogo) $glyph.innerHTML = buildLogo();
    }

    $card.hidden = false;
  }

  function resolveBuildLogo() {
    if (typeof window !== 'undefined' && typeof window.buildHomefitLogoSvg === 'function') {
      return window.buildHomefitLogoSvg;
    }
    if (typeof buildHomefitLogoSvg === 'function') return buildHomefitLogoSvg;
    return null;
  }

  // ===========================  Footer seal + QR  ========================
  //
  // The standard seal — ONE seal on both surfaces. "powered by
  // homefit.studio" + matrix glyph + real referral QR + "Visual plans
  // clients follow." tagline. No version line (the plan version shows on
  // the artefact cards / build chip). Coral via --seal-coral (never
  // re-skinned).

  function renderSeal() {
    renderSealLogo();
    renderSealQr();
  }

  function renderSealLogo() {
    const $logo = document.getElementById('handout-seal-logo');
    if (!$logo || $logo.innerHTML) return;
    const buildLogo = resolveBuildLogo();
    if (buildLogo) $logo.innerHTML = buildLogo();
  }

  /**
   * Render a REAL QR (local, CSP-clean via HomefitQR) encoding the
   * practitioner referral link. Sourced from plan.referral_code (added
   * to get_plan_full in 20260528090000_get_plan_full_referral_code.sql).
   * When the practice has no referral code the QR is hidden gracefully.
   */
  function renderSealQr() {
    const $qr = document.getElementById('handout-qr');
    if (!$qr) return;
    const code = state.plan && (state.plan.referral_code || '').toString().trim();
    if (!code) {
      $qr.hidden = true;
      return;
    }
    if (!window.HomefitQR || !window.HomefitQR.toSvg) {
      $qr.hidden = true;
      return;
    }
    const url = 'https://manage.homefit.studio/r/' + encodeURIComponent(code);
    try {
      const svg = window.HomefitQR.toSvg(url, { ecLevel: 'M', quietZone: 2 });
      $qr.hidden = false;
      $qr.innerHTML = svg;
      $qr.setAttribute('title', 'Scan to follow your practitioner');
      $qr.setAttribute('aria-label', 'QR code linking to your practitioner');
    } catch (err) {
      try { console.warn('[handout] QR render failed:', err); } catch (_) {}
      $qr.hidden = true;
    }
  }

  // ===========================  Events  ==================================

  function bindEvents() {
    const $print = document.getElementById('handout-print-btn');
    if ($print) {
      $print.addEventListener('click', () => {
        try { window.print(); } catch (_) {}
      });
    }

    // Notes expand/collapse — same affordance as the lobby's
    // [data-notes-toggle] buttons.
    const $list = document.getElementById('handout-list');
    if ($list) {
      $list.addEventListener('click', (evt) => {
        const toggle = evt.target.closest('[data-notes-toggle]');
        if (!toggle) return;
        const expanded = toggle.classList.toggle('is-expanded');
        toggle.setAttribute('aria-expanded', expanded ? 'true' : 'false');
      });
    }

    const $import = document.getElementById('handout-import-card');
    if ($import) {
      $import.addEventListener('click', (event) => {
        // The anchor already carries the href; this is belt-and-braces so a
        // non-anchor variant still routes. Let the native anchor navigation
        // run; only intercept if the href is the bare /me default.
        if ($import.getAttribute('href') !== '/me') return;
        event.preventDefault();
        try {
          window.location.assign('/me?claim=' + encodeURIComponent(planId));
        } catch (_) {}
      });
    }
  }

  // ===========================  Best-effort RPCs  ========================

  async function recordHandoutOpened(id) {
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

  function showError(reason) {
    const $loading = document.getElementById('handout-loading');
    const $page = document.getElementById('handout-page');
    const $err = document.getElementById('handout-error');
    if ($loading) $loading.hidden = true;
    if ($page) $page.hidden = true;
    if ($err) {
      $err.hidden = false;
      if (reason && typeof reason === 'string' && reason.length > 0) {
        const existing = $err.querySelector('.handout-error-reason');
        if (existing) existing.remove();
        const $chip = document.createElement('p');
        $chip.className = 'handout-error-reason';
        $chip.textContent = reason;
        $chip.style.fontSize = '11px';
        $chip.style.opacity = '0.6';
        $chip.style.marginTop = '12px';
        $chip.style.fontFamily = 'monospace';
        $err.appendChild($chip);
      }
    }
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
