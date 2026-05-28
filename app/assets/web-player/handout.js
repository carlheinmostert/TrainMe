/**
 * handout.js — Printable Workout Guide at /h/{planId}
 * =====================================================================
 *
 * Artifact-system Wave 1 (ADR 0025), aligned with the Interactive
 * Workout Guide lobby (artifact-consistency wave, 2026-05-28). Renders
 * the live plan from the same `get_plan_full` anon RPC the player uses.
 *
 * Key alignment decisions (this surface MUST match the lobby, not
 * redefine it):
 *   - No view/treatment toggle. Each exercise renders STATICALLY in its
 *     own `preferred_treatment` via the mandated hero resolver
 *     (HomefitHero.resolve + HomefitHeroResolver), exactly like the
 *     lobby. Consent revocation falls DOWN to line silently (resolver).
 *   - Dose grammar is the SHARED dose module (HomefitDose) — no parallel
 *     rep/hold logic that could drift from the lobby.
 *   - Circuit grouping mirrors the lobby (plan.circuit_names + letter
 *     fallback).
 *   - The byline practitioner name comes from get_plan_sharing_context
 *     (api.getPlanSharingContext), the same source the lobby uses — NOT
 *     the non-existent plan.trainer_display_name / plan.trainer_name.
 *   - Footer = the standard "powered by homefit.studio" seal + a REAL
 *     QR (rendered locally via HomefitQR, CSP-clean) to the practice
 *     referral link.
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
    try { renderExerciseList(); }
      catch (e) { try { console.warn('[handout] renderExerciseList failed:', e); } catch(_){} }
    try { renderImportBlock(); }
      catch (e) { try { console.warn('[handout] renderImportBlock failed:', e); } catch(_){} }
    try { renderSeal(); }
      catch (e) { try { console.warn('[handout] renderSeal failed:', e); } catch(_){} }
    try { bindEvents(); }
      catch (e) { try { console.warn('[handout] bindEvents failed:', e); } catch(_){} }

    $loading.hidden = true;
    $page.hidden = false;

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
  // Circuit grouping + letter fallback mirror the lobby's renderList
  // (lobby.js:527-901). Each exercise renders statically in its own
  // preferred_treatment via the hero resolver.

  function renderExerciseList() {
    const $list = document.getElementById('handout-list');
    if (!$list) return;
    $list.innerHTML = '';

    const slides = state.exercises;

    // Circuit letter map (mirror Studio's _circuitLetter + lobby).
    const circuitLetters = (() => {
      const map = {};
      let nextIdx = 0;
      for (let i = 0; i < slides.length; i++) {
        const s = slides[i];
        if (!s || !s.circuit_id) continue;
        if (Object.prototype.hasOwnProperty.call(map, s.circuit_id)) continue;
        map[s.circuit_id] = String.fromCharCode('A'.charCodeAt(0) + (nextIdx % 26));
        nextIdx += 1;
      }
      return map;
    })();

    let currentCircuit = null;
    let circuitGroup = null;
    let exercisePosition = 0;

    slides.forEach((ex, idx) => {
      if (!ex) return;
      const circuitId = ex.circuit_id || null;
      const isRest = ex.media_type === 'rest';

      // Close the open circuit group when the circuit changes.
      if (circuitId !== currentCircuit) {
        currentCircuit = circuitId;
        circuitGroup = null;
        if (circuitId) {
          const cycles = circuitCyclesForId(state.plan, circuitId) || 1;
          // Circuit display name — custom (plan.circuit_names) then the
          // letter fallback, matching the lobby.
          const customName = (ex.circuitName && String(ex.circuitName).trim())
            || (state.plan
              && state.plan.circuit_names
              && state.plan.circuit_names[circuitId]
              && String(state.plan.circuit_names[circuitId]).trim())
            || '';
          const letter = circuitLetters[circuitId] || 'A';
          const circuitName = customName || ('Circuit ' + letter);

          const $h = document.createElement('div');
          $h.className = 'handout-circuit-h';
          $h.innerHTML =
            '<span>' + escapeHtml(circuitName) + ' · ×' + escapeHtml(String(cycles))
            + '</span><span class="line"></span>';
          $list.appendChild($h);

          circuitGroup = document.createElement('div');
          circuitGroup.className = 'handout-circuit-group';
          $list.appendChild(circuitGroup);
        }
      }

      let $node;
      if (isRest) {
        $node = buildRestNode(ex);
      } else {
        exercisePosition += 1;
        $node = buildExerciseNode(ex, exercisePosition);
      }
      (circuitGroup || $list).appendChild($node);
    });

    // Hydrate hero crops to 1:1 (same path the lobby uses).
    hydrateHeroCrops();
  }

  function circuitCyclesForId(plan, circuitId) {
    if (!plan || !plan.circuit_cycles || !circuitId) return 1;
    let map = plan.circuit_cycles;
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

    // Hero — via the mandated resolver. Static <img> only (never a
    // <video>; the printable guide is a still document). The resolver
    // derives the treatment from ex.preferred_treatment internally and
    // falls down to line when consent revoked a variant.
    const $thumb = document.createElement('div');
    $thumb.className = 'handout-ex-thumb';

    const heroImg = buildHeroImg(ex);
    if (heroImg.$img) {
      $thumb.appendChild(heroImg.$img);
      if (heroImg.isBw) $thumb.classList.add('is-bw');
    } else {
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
    // Default-name fallback — mirror the lobby (Studio doesn't persist a
    // default name; synthesize "Exercise N").
    const rawName = (ex.name || '').trim();
    $name.textContent = rawName || ('Exercise ' + position);
    $body.appendChild($name);

    // Dose line — shared dose module (HomefitDose) so rep/hold/weight
    // grammar is byte-identical to the lobby. No `~Xs` duration segment
    // (no per-rep video timing context on the static handout).
    const dose = buildDose(ex);
    if (dose) {
      const $dose = document.createElement('div');
      $dose.className = 'handout-ex-dose';
      $dose.textContent = dose;
      $body.appendChild($dose);
    }

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

  function buildDose(ex) {
    if (window.HomefitDose && window.HomefitDose.buildDoseLine) {
      // No calculateDuration on the handout — omit the trailing ~Xs.
      return window.HomefitDose.buildDoseLine(ex, {});
    }
    return '';
  }

  /**
   * Build the static hero <img> for an exercise via the mandated
   * resolver chain (HomefitHero.resolve → HomefitHeroResolver crop).
   * Returns { $img, isBw }. The img carries data-hero-* attributes so
   * hydrateHeroCrops can re-crop it to a 1:1 data URL post-mount, exactly
   * like the lobby. NEVER renders a <video> (mp4-in-img trap + the
   * printable guide is a still). Returns { $img: null } when no treatment
   * is available so the caller renders the figure placeholder.
   */
  function buildHeroImg(ex) {
    if (!window.HomefitHero || !window.HomefitHero.resolve) {
      return { $img: null, isBw: false };
    }
    const hero = window.HomefitHero.resolve(ex, { surface: 'handout' });
    if (hero.mediaTag === 'skeleton' || hero.mediaTag === 'unavailable') {
      return { $img: null, isBw: false };
    }
    // For videos the resolver returns posterSrc as `src` on non-deck
    // surfaces; for photos it's the JPG. Either way it's a still image.
    const src = hero.src || hero.posterSrc || null;
    if (!src) return { $img: null, isBw: false };

    const $img = document.createElement('img');
    $img.alt = '';
    $img.loading = 'lazy';
    $img.src = src;
    $img.setAttribute('data-treatment', hero.treatment || 'line');
    $img.setAttribute('data-hero-id', String(ex.id || ''));
    $img.setAttribute('data-hero-offset', String(pickHeroOffset(ex)));
    $img.setAttribute('data-hero-source', src);
    const isBw = (hero.domClass || '').indexOf('is-grayscale') !== -1;
    if (isBw) $img.classList.add('is-grayscale');
    return { $img: $img, isBw: isBw };
  }

  function pickHeroOffset(ex) {
    if (!ex || ex.hero_crop_offset == null) return 0.5;
    const n = Number(ex.hero_crop_offset);
    if (!Number.isFinite(n)) return 0.5;
    return Math.max(0, Math.min(1, n));
  }

  /**
   * Re-crop every freshly-rendered hero <img> to a 1:1 data URL via
   * HomefitHeroResolver — the SAME single-source crop path the lobby
   * uses (lobby.js hydrateHeroCrops). Satisfies the hero-resolver rule
   * (docs/HERO_RESOLVER.md): no inline crop math, no object-fit:cover.
   */
  function hydrateHeroCrops() {
    const $list = document.getElementById('handout-list');
    if (!$list) return;
    if (!window.HomefitHeroResolver || !window.HomefitHeroResolver.getHeroSquareImage) {
      return; // degraded but layout intact (overflow:hidden clips the slot)
    }
    const heros = $list.querySelectorAll('img[data-hero-source]');
    heros.forEach((img) => {
      const source = img.dataset.heroSource || '';
      if (!source || source.startsWith('data:')) return;
      const id = img.dataset.heroId || '';
      const treatment = img.dataset.treatment || '';
      const offset = Number(img.dataset.heroOffset);
      window.HomefitHeroResolver.getHeroSquareImage({
        exerciseId: id,
        treatment: treatment,
        sourceUrl: source,
        heroCropOffset: Number.isFinite(offset) ? offset : 0.5,
        targetSize: 200,
      }).then((dataUrl) => {
        if (!dataUrl || !img.isConnected) return;
        img.src = dataUrl;
        img.dataset.heroSource = dataUrl;
      });
    });
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

  // ===========================  Get-the-app block  =======================
  //
  // Standardised with the lobby's #lobby-import-card (task 7): canonical
  // buildHomefitLogoSvg() glyph + the "Save this plan to your phone"
  // magic-link framing. The handout keeps its tappable claim chip →
  // /me?claim={planId}. The header claim chip markup already carries the
  // copy; here we inject the canonical logo glyph into the chip's glyph
  // slot so the brand mark matches the lobby. The lobby card is NOT a
  // logo in the chip — it sits below the list — but the canonical glyph
  // is the shared element. We render the canonical glyph in the claim
  // chip's leading slot.

  function renderImportBlock() {
    const $glyph = document.getElementById('handout-claim-glyph');
    if (!$glyph) return;
    const buildLogo = resolveBuildLogo();
    if (buildLogo) {
      $glyph.innerHTML = buildLogo();
    }
  }

  function resolveBuildLogo() {
    if (typeof window !== 'undefined' && typeof window.buildHomefitLogoSvg === 'function') {
      return window.buildHomefitLogoSvg;
    }
    if (typeof buildHomefitLogoSvg === 'function') return buildHomefitLogoSvg;
    return null;
  }

  // ===========================  Footer seal + QR  ========================

  function renderSeal() {
    renderSealVersion();
    renderSealQr();
  }

  function renderSealVersion() {
    const $v = document.getElementById('handout-seal-version');
    if (!$v) return;
    const version = state.plan && state.plan.version ? state.plan.version : 1;
    const handoutArtifact = (state.artifacts || []).find((a) => a && a.kind === 'handout');
    const planUrlArtifact = (state.artifacts || []).find((a) => a && a.kind === 'plan_url');
    const stampSource =
      (handoutArtifact && handoutArtifact.published_at)
      || (planUrlArtifact && planUrlArtifact.published_at)
      || (state.plan && state.plan.last_published_at)
      || null;
    const stamp = stampSource ? formatVersionStamp(new Date(stampSource)) : 'unstamped';
    // "Published · v{N} · {stamp}" — aligns the version framing with the
    // /me artifact card pill ("Published · v{N}").
    $v.textContent = 'Published · v' + version + ' · ' + stamp;
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
      // No referral code — hide the QR slot gracefully.
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
        try { window.print(); } catch (_) {}
      });
    }

    const $claim = document.getElementById('handout-claim');
    if ($claim) {
      $claim.addEventListener('click', (event) => {
        if (event.target && event.target.closest('.handout-claim-x')) return;
        try {
          window.location.assign('/me?claim=' + encodeURIComponent(planId));
        } catch (_) {
          try { console.info('[handout] claim chip clicked — /me unreachable (plan_id=' + planId + ')'); } catch (_) {}
        }
      });
    }

    const $claimX = document.getElementById('handout-claim-x');
    if ($claimX) {
      $claimX.addEventListener('click', (event) => {
        event.stopPropagation();
        const $c = document.getElementById('handout-claim');
        if ($c) $c.hidden = true;
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
