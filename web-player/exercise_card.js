/**
 * exercise_card.js — Shared exercise-card renderer + interactivity engine
 * =====================================================================
 *
 * Single source of truth for the exercise CARD that BOTH the Interactive
 * Workout Guide lobby (`/p/{planId}`, lobby.js) and the Printable Workout
 * Guide (`/h/{planId}`, handout.js) render. The card markup, hero, dose
 * line, circuit grouping and the scroll-driven active-row + video-swap
 * behaviour all live here so the two surfaces can NEVER visually diverge
 * (artifact-consistency pass 2, 2026-05-28).
 *
 * The lobby continues to own the guided-workout flow (Start Workout, pill
 * matrix, prep countdown, timers, rep stack) — that is the Interactive
 * Guide's distinguishing feature and is NOT in this module. This module is
 * the browseable REFERENCE layer: the card list + the active-card-on-scroll
 * highlight + the active-row video swap. The handout consumes it directly;
 * the lobby's own renderList already produces byte-identical markup (the
 * builders here are modelled on it verbatim) so the lobby is unchanged.
 *
 * Exposed as `window.HomefitExerciseCard`:
 *   - buildListHTML(slides, plan, helpers)      -> innerHTML string for the
 *                                                  card list (rows + circuit
 *                                                  groups + rests)
 *   - hydrateHeroCrops(container)               -> bake 1:1 crop data URLs
 *   - createInteractivity({ list, scroller })   -> scroll-driven active-row
 *                                                  highlight + video swap
 *                                                  controller
 *
 * Dependencies (loaded before this file, all CSP-clean `script-src 'self'`):
 *   - HomefitHero        (exercise_hero.js)   — treatment-correct hero shape
 *   - HomefitHeroResolver(hero_resolver.js)   — 1:1 square crop bake
 *   - HomefitDose        (dose_format.js)     — shared rep/hold/weight grammar
 *
 * The card uses the SAME `.lobby-row` / `.lobby-hero` / `.lobby-info` /
 * `.lobby-circuit*` class names the lobby uses so the shared CSS in
 * styles.css (and the handout's mirror) drives both surfaces identically.
 */
(function () {
  'use strict';

  // =========================================================================
  // Small helpers
  // =========================================================================

  function escapeHTML(str) {
    if (str === null || str === undefined) return '';
    return String(str)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  function prefersReducedMotion() {
    try {
      return window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    } catch (_) { return false; }
  }

  function pickHeroOffset(slide) {
    if (!slide || slide.hero_crop_offset == null) return 0.5;
    const n = Number(slide.hero_crop_offset);
    if (!Number.isFinite(n)) return 0.5;
    return Math.max(0, Math.min(1, n));
  }

  // Default circuit rounds when plan.circuit_cycles has no entry. Mirrors
  // app.js unrollExercises (`Number.parseInt(cycles[circuitId], 10) || 3`)
  // so the Printable Guide's circuit `×N` chip matches the lobby's.
  const DEFAULT_CIRCUIT_ROUNDS = 3;
  function circuitCyclesForId(plan, circuitId) {
    if (!plan || !circuitId) return DEFAULT_CIRCUIT_ROUNDS;
    let map = plan.circuit_cycles;
    if (typeof map === 'string') {
      try { map = JSON.parse(map); } catch (_) { return DEFAULT_CIRCUIT_ROUNDS; }
    }
    if (typeof map !== 'object' || map === null) return DEFAULT_CIRCUIT_ROUNDS;
    const n = Number.parseInt(map[circuitId], 10);
    return Number.isFinite(n) && n > 0 ? n : DEFAULT_CIRCUIT_ROUNDS;
  }

  // =========================================================================
  // Dose line
  // =========================================================================
  //
  // Always delegates to the shared HomefitDose grammar so the rep/hold/weight
  // wording is byte-identical to the lobby. `helpers.calculateDuration` is
  // optional: when supplied (both surfaces, when video timing context is
  // available) a trailing `~Xs` estimated-duration segment is appended,
  // exactly like the lobby's buildDoseLine. When absent the segment is
  // omitted. Passing it keeps the handout's dose line identical to the lobby.

  function buildDoseLine(slide, helpers) {
    if (window.HomefitDose && window.HomefitDose.buildDoseLine) {
      const opts = {};
      if (helpers && typeof helpers.calculateDuration === 'function') {
        opts.calculateDuration = helpers.calculateDuration;
      }
      return window.HomefitDose.buildDoseLine(slide, opts);
    }
    return '';
  }

  // =========================================================================
  // Hero element
  // =========================================================================
  //
  // Modelled verbatim on lobby.js renderHeroHTML. Photos render a static
  // <img>; videos ALSO render an <img> with the mp4 carried on
  // `data-video-src` (never `<img src>` — iOS WKWebView mp4-in-img trap).
  // The active-row swap (createInteractivity) lifts the active row's <img>
  // to a <video>. `surface: 'lobby'` makes the resolver hand back posterSrc +
  // videoSrc exactly the way the lobby gets them.

  function renderHeroHTML(slide) {
    if (!slide) return '<div class="lobby-hero-skeleton" aria-hidden="true"></div>';
    if (!window.HomefitHero || !window.HomefitHero.resolve) {
      return '<div class="lobby-hero-skeleton" aria-hidden="true"></div>';
    }

    const hero = window.HomefitHero.resolve(slide, { surface: 'lobby' });

    if (hero.mediaTag === 'skeleton') {
      return '<div class="lobby-hero-skeleton" aria-hidden="true"></div>';
    }

    if (hero.mediaTag === 'unavailable') {
      // Treatment not available — coral-tinted placeholder. NEVER substitute
      // a different treatment (matches the lobby's no-fallback contract).
      return (
        '<div class="hero-not-available lobby-hero-media" aria-hidden="true" data-treatment="'
        + escapeHTML(hero.treatment) + '">'
        + '<div class="hero-not-available-name">' + escapeHTML(slide.name || 'Exercise') + '</div>'
        + '<div class="hero-not-available-sub">' + escapeHTML((hero.treatment || '').toUpperCase()) + ' not available</div>'
        + '</div>'
      );
    }

    const isPhoto = slide.media_type === 'photo' || slide.media_type === 'image';
    const grayscale = hero.domClass ? ' ' + hero.domClass : '';
    const heroOffset = pickHeroOffset(slide);
    const heroId = escapeHTML(String(slide.id || ''));

    if (isPhoto) {
      const src = hero.src || hero.posterSrc || '';
      return (
        '<img class="lobby-hero-media' + grayscale + '"'
        + ' src="' + escapeHTML(src) + '"'
        + ' alt="' + escapeHTML(slide.name || 'Exercise') + '"'
        + ' loading="eager"'
        + ' data-treatment="' + escapeHTML(hero.treatment) + '"'
        + ' data-hero-id="' + heroId + '"'
        + ' data-hero-offset="' + heroOffset + '"'
        + ' data-hero-source="' + escapeHTML(src) + '">'
      );
    }

    // Video — static <img> placeholder; createInteractivity lifts it to a
    // <video> on the active row. mp4 travels on data-video-src.
    const videoSrc = hero.videoSrc || '';
    const posterSrc = hero.posterSrc || '';
    return (
      '<img class="lobby-hero-media' + grayscale + '"'
      + ' src="' + escapeHTML(posterSrc) + '"'
      + ' alt="' + escapeHTML(slide.name || 'Exercise') + '"'
      + ' loading="eager"'
      + ' data-treatment="' + escapeHTML(hero.treatment) + '"'
      + ' data-video-src="' + escapeHTML(videoSrc) + '"'
      + ' data-poster-src="' + escapeHTML(posterSrc) + '"'
      + ' data-hero-id="' + heroId + '"'
      + ' data-hero-offset="' + heroOffset + '"'
      + ' data-hero-source="' + escapeHTML(posterSrc) + '"'
      + ' data-trim-start="' + (Number(slide.start_offset_ms) || 0) + '"'
      + ' data-trim-end="' + (Number(slide.end_offset_ms) || 0) + '">'
    );
  }

  // =========================================================================
  // Row builders (modelled verbatim on lobby.js)
  // =========================================================================

  function exerciseRowHTML(slide, slideIndex, opts) {
    opts = opts || {};
    const rawName = (slide.name || '').trim();
    const displayName = rawName
      ? rawName
      : (opts.position ? 'Exercise ' + opts.position : 'Exercise');
    const name = escapeHTML(displayName);

    const dose = buildDoseLine(slide, opts.helpers);
    const notes = (slide.notes || '').trim();
    const heroHTML = renderHeroHTML(slide);

    const isLast = !!opts.last;
    const lastClass = isLast ? ' last' : '';

    return (
      '<li class="lobby-row' + lastClass + '" role="listitem"'
      + ' data-slide-index="' + slideIndex + '"'
      + ' data-id="' + escapeHTML(slide.id || '') + '">'
      + '<div class="lobby-row-gutter" aria-hidden="true">'
      + '<span class="lobby-row-gutter-rail"></span>'
      + '<span class="lobby-row-gutter-connector"></span>'
      + '</div>'
      + '<div class="lobby-row-content">'
      + '<div class="lobby-hero" data-hero-target>' + heroHTML + '</div>'
      + '<div class="lobby-info">'
      + '<h3 class="lobby-info-name">' + name + '</h3>'
      + (dose ? '<p class="lobby-info-dose">' + escapeHTML(dose) + '</p>' : '')
      + (notes ? '<button type="button" class="lobby-info-notes" aria-expanded="false" data-notes-toggle>' + escapeHTML(notes) + '</button>' : '')
      + '</div>'
      + '</div>'
      + '</li>'
    );
  }

  function restRowHTML(slide, slideIndex) {
    const seconds = Math.max(1, Math.round(Number(slide.rest_seconds) || 30));
    return (
      '<li class="lobby-row is-rest" role="listitem"'
      + ' data-slide-index="' + slideIndex + '"'
      + ' data-id="' + escapeHTML(slide.id || '') + '">'
      + '<div class="lobby-row-gutter" aria-hidden="true">'
      + '<span class="lobby-row-gutter-rail"></span>'
      + '<span class="lobby-row-gutter-connector"></span>'
      + '</div>'
      + '<div class="lobby-row-content">'
      + '<span class="lobby-rest-label">Rest · ' + seconds + 's</span>'
      + '</div>'
      + '</li>'
    );
  }

  // Max number of visible nested-box rings (matches lobby CIRCUIT_BOX_CAP).
  const CIRCUIT_BOX_CAP = 5;

  function circuitGroupHTML(group) {
    const labelText = group.circuitName ? group.circuitName : 'Circuit';
    const rounds = Math.max(1, group.rounds || 1);
    const visibleBoxes = Math.min(rounds, CIRCUIT_BOX_CAP);
    const cyclesText = '×' + rounds;
    const lastIdx = group.rows.length - 1;
    const rows = group.rows.map((r, i) => {
      const isLast = i === lastIdx;
      const html = r.isRest
        ? restRowHTML(r.slide, r.slideIndex)
        : exerciseRowHTML(r.slide, r.slideIndex, { last: isLast, position: r.position, helpers: group.helpers });
      const lastMod = (isLast && r.isRest) ? ' last' : '';
      // Transform the row's outer <li> → <div> + add circuit classes
      // (the browser auto-closes an <li> when it hits a nested <li>).
      return html
        .replace(/^\s*<li\b/, '<div')
        .replace(/<\/li>(\s*)$/, '</div>$1')
        .replace('class="lobby-row', 'class="lobby-row is-circuit in-circuit' + lastMod);
    }).join('');

    // Build the nested rings outside-in (matches lobby circuitGroupHTML).
    let body = '<div class="lobby-circuit-body">' + rows + '</div>';
    for (let depth = 0; depth < visibleBoxes; depth++) {
      const isInner = depth === 0;
      const isOuter = depth === visibleBoxes - 1;
      const depthClass = isInner
        ? 'lobby-circuit-box-inner'
        : 'lobby-circuit-box-depth-' + depth;
      body = '<div class="lobby-circuit-box ' + depthClass + '"'
        + ' style="--box-index: ' + depth + ';">'
        + body
        + '</div>';
      // The header only mounts on the OUTERMOST ring wrapper, prepended
      // once the loop reaches the final iteration.
      if (isOuter) {
        body = '<header class="lobby-circuit-header">'
          + '<span class="lobby-circuit-header-label">' + escapeHTML(labelText) + '</span>'
          + '<span class="lobby-circuit-header-cycles">' + escapeHTML(cyclesText) + '</span>'
          + '</header>'
          + body;
      }
    }

    return '<li class="lobby-circuit" data-circuit-id="' + escapeHTML(group.circuitId || '') + '">' + body + '</li>';
  }

  // =========================================================================
  // List builder — circuit grouping + default-name fallback (verbatim lobby)
  // =========================================================================

  function buildListHTML(slides, plan, helpers) {
    slides = Array.isArray(slides) ? slides : [];

    // Circuit letter map (first-appearance order, mod 26) — mirrors Studio's
    // _circuitLetter + the lobby.
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

    const items = [];
    const seenIds = new Set();
    let circuitGroup = null;
    let exercisePosition = 0;

    for (let i = 0; i < slides.length; i++) {
      const s = slides[i];
      if (!s) continue;

      const idKey = s.id != null ? String(s.id) : '_idx_' + i;
      if (seenIds.has(idKey)) continue;
      seenIds.add(idKey);

      if (s.media_type === 'rest') {
        // Rest INSIDE an open circuit belongs to that group's row stream.
        if (circuitGroup && s.circuit_id && circuitGroup.circuitId === s.circuit_id) {
          circuitGroup.rows.push({ slide: s, slideIndex: i, isRest: true });
          continue;
        }
        if (circuitGroup) { items.push(circuitGroup); circuitGroup = null; }
        items.push({ kind: 'rest', slide: s, slideIndex: i });
        continue;
      }

      exercisePosition += 1;

      // Circuit slide — group consecutive same-circuit slides. The dedupe
      // above keeps only the first-round occurrence. We treat any slide
      // with a circuit_id as a circuit member (the handout payload doesn't
      // carry the lobby's synthesized `circuitRound`, so we don't gate on
      // it — circuit_id presence is the marker).
      if (s.circuit_id) {
        if (!circuitGroup || circuitGroup.circuitId !== s.circuit_id) {
          if (circuitGroup) items.push(circuitGroup);
          const customName = (s.circuitName && String(s.circuitName).trim())
            || (plan
              && plan.circuit_names
              && plan.circuit_names[s.circuit_id]
              && String(plan.circuit_names[s.circuit_id]).trim())
            || '';
          const letter = circuitLetters[s.circuit_id] || 'A';
          const circuitName = customName || ('Circuit ' + letter);
          circuitGroup = {
            kind: 'circuit',
            circuitId: s.circuit_id,
            circuitName: circuitName,
            rounds: s.circuitTotalRounds || circuitCyclesForId(plan, s.circuit_id) || 1,
            rows: [],
            helpers: helpers,
          };
        }
        circuitGroup.rows.push({ slide: s, slideIndex: i, position: exercisePosition });
        continue;
      }

      if (circuitGroup) { items.push(circuitGroup); circuitGroup = null; }
      items.push({ kind: 'single', slide: s, slideIndex: i, position: exercisePosition });
    }
    if (circuitGroup) items.push(circuitGroup);

    return items.map((item) => {
      if (item.kind === 'rest') return restRowHTML(item.slide, item.slideIndex);
      if (item.kind === 'single') {
        return exerciseRowHTML(item.slide, item.slideIndex, { position: item.position, helpers: helpers });
      }
      if (item.kind === 'circuit') return circuitGroupHTML(item);
      return '';
    }).join('');
  }

  // =========================================================================
  // Hero-crop hydration — bake 1:1 square data URLs (verbatim lobby)
  // =========================================================================

  function hydrateHeroCrops(container) {
    if (!container) return;
    if (!window.HomefitHeroResolver || !window.HomefitHeroResolver.getHeroSquareImage) {
      return; // degraded but layout intact (overflow:hidden clips the slot)
    }
    const heros = container.querySelectorAll('img.lobby-hero-media[data-hero-source]');
    heros.forEach((img) => {
      const source = img.dataset.heroSource || '';
      if (!source) return;
      if (source.startsWith('data:')) return; // already resolved
      const id = img.dataset.heroId || '';
      const treatment = img.dataset.treatment || '';
      const offset = Number(img.dataset.heroOffset);
      window.HomefitHeroResolver.getHeroSquareImage({
        exerciseId: id,
        treatment: treatment,
        sourceUrl: source,
        heroCropOffset: Number.isFinite(offset) ? offset : 0.5,
        targetSize: 540,
      }).then((dataUrl) => {
        if (!dataUrl) return;
        if (!img.isConnected) return;
        img.src = dataUrl;
        img.dataset.heroSource = dataUrl;
        if (img.dataset.posterSrc) img.dataset.posterSrc = dataUrl;
      });
    });
  }

  // =========================================================================
  // Interactivity controller — active-row highlight + active-row video swap
  // =========================================================================
  //
  // A trimmed-down twin of the lobby's scroll engine (setupScrollCoupling /
  // recomputeActiveRow / setActiveRow / swapToVideoOnActiveRow). It is
  // scoped to the supplied list + scroll container. It deliberately does
  // NOT carry: the pill matrix, pill-fill coupling, the circuit-breaker
  // heartbeat, or any workout-timer logic — those belong to the Interactive
  // Guide's guided-workout flow which this surface (the printable) doesn't
  // get (task 2 boundary).
  //
  // What it does, identical to the lobby:
  //   - highlight the row nearest the viewport centre as you scroll
  //     (adds `.is-active-pill` so `.lobby-row.is-active-pill >
  //     .lobby-row-content` lights its coral border)
  //   - swap that row's hero <img> → <video> (autoplay, muted, looped,
  //     trim-clamped) and swap every other row back to <img>
  //
  // For @media print the @print sheet flattens the cards to static; this
  // controller does nothing on paper because print doesn't scroll.

  function createInteractivity(args) {
    const list = args && args.list;
    const scroller = (args && args.scroller) || document.scrollingElement || document.documentElement;
    if (!list) return { activateInitialRow: function () {}, recompute: function () {}, destroy: function () {} };

    let activeRowIndex = -1;
    let scrollThrottleToken = null;
    let lazyKickToken = null;
    let wired = false;

    function rows() {
      return list.querySelectorAll('.lobby-row[data-slide-index]');
    }

    function scrollerRect() {
      // When the scroller is the page (documentElement / body), use the
      // viewport rect; otherwise use the element's box.
      if (scroller === document.documentElement || scroller === document.body || scroller === document.scrollingElement) {
        return { top: 0, height: window.innerHeight, bottom: window.innerHeight };
      }
      const r = scroller.getBoundingClientRect();
      return { top: r.top, height: r.height, bottom: r.bottom };
    }

    function scrollMetrics() {
      if (scroller === document.documentElement || scroller === document.body || scroller === document.scrollingElement) {
        const el = document.scrollingElement || document.documentElement;
        return {
          scrollTop: el.scrollTop,
          clientHeight: window.innerHeight,
          scrollHeight: el.scrollHeight,
        };
      }
      return {
        scrollTop: scroller.scrollTop,
        clientHeight: scroller.clientHeight,
        scrollHeight: scroller.scrollHeight,
      };
    }

    function setActiveRow(row) {
      const idx = parseInt(row.getAttribute('data-slide-index'), 10);
      if (Number.isNaN(idx) || idx === activeRowIndex) return;
      activeRowIndex = idx;

      list.querySelectorAll('.lobby-row.is-active-pill').forEach((el) => el.classList.remove('is-active-pill'));
      row.classList.add('is-active-pill');

      if (lazyKickToken != null) {
        clearTimeout(lazyKickToken);
        lazyKickToken = null;
      }
      const targetIdx = idx;
      lazyKickToken = setTimeout(() => {
        lazyKickToken = null;
        swapToVideoOnActiveRow(targetIdx);
      }, 150);
    }

    function recompute() {
      const rs = rows();
      if (!rs.length) return;
      const m = scrollMetrics();

      const atTop = m.scrollTop <= 4;
      if (atTop) {
        let firstNonRest = null;
        for (let i = 0; i < rs.length; i++) {
          if (!rs[i].classList.contains('is-rest')) { firstNonRest = rs[i]; break; }
        }
        const target = firstNonRest || rs[0];
        if (target) setActiveRow(target);
        return;
      }

      const atBottom = (m.scrollTop + m.clientHeight) >= (m.scrollHeight - 4);
      const rect = scrollerRect();
      if (atBottom) {
        let lastVisible = null;
        for (let i = rs.length - 1; i >= 0; i--) {
          const r = rs[i].getBoundingClientRect();
          if (r.bottom < rect.top || r.top > rect.bottom) continue;
          lastVisible = rs[i];
          break;
        }
        const target = lastVisible || rs[rs.length - 1];
        if (target) setActiveRow(target);
        return;
      }

      const viewportCentre = rect.top + rect.height / 2;
      let bestRow = null;
      let bestDist = Infinity;
      for (let i = 0; i < rs.length; i++) {
        const r = rs[i].getBoundingClientRect();
        if (r.bottom < rect.top || r.top > rect.bottom) continue;
        const rowCentre = r.top + r.height / 2;
        const dist = Math.abs(rowCentre - viewportCentre);
        if (dist < bestDist) {
          bestDist = dist;
          bestRow = rs[i];
        }
      }
      if (bestRow) setActiveRow(bestRow);
    }

    function swapToVideoOnActiveRow(idx) {
      const rs = rows();
      rs.forEach((row) => {
        const rIdx = parseInt(row.getAttribute('data-slide-index'), 10);
        const isActive = rIdx === idx;
        const hero = row.querySelector('.lobby-hero-media');
        if (!hero) return;
        if (!hero.dataset.videoSrc) return; // photo — no swap
        const isVideoTag = hero.tagName === 'VIDEO';

        if (isActive && !prefersReducedMotion()) {
          if (isVideoTag) return;
          const v = document.createElement('video');
          v.className = hero.className;
          v.setAttribute('playsinline', '');
          v.muted = true;
          v.loop = true;
          v.preload = 'auto';
          v.style.cssText = hero.style.cssText;
          v.dataset.treatment = hero.dataset.treatment || '';
          v.dataset.videoSrc = hero.dataset.videoSrc;
          v.dataset.posterSrc = hero.dataset.posterSrc || '';
          v.dataset.trimStart = hero.dataset.trimStart || '0';
          v.dataset.trimEnd = hero.dataset.trimEnd || '0';
          v.dataset.heroId = hero.dataset.heroId || '';
          v.dataset.heroOffset = hero.dataset.heroOffset || '0.5';
          if (v.dataset.posterSrc) v.setAttribute('poster', v.dataset.posterSrc);
          v.setAttribute('src', v.dataset.videoSrc);
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
          if (!isVideoTag) return;
          try { hero.pause(); } catch (_) {}
          const posterSrc = hero.dataset.posterSrc || hero.getAttribute('poster') || '';
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
          img.dataset.heroId = hero.dataset.heroId || '';
          img.dataset.heroOffset = hero.dataset.heroOffset || '0.5';
          img.dataset.heroSource = posterSrc;
          img.setAttribute('src', posterSrc);
          hero.parentNode.replaceChild(img, hero);
        }
      });
      // Re-hydrate any freshly-swapped <img> to 1:1 (idempotent on data: URLs).
      hydrateHeroCrops(list);
    }

    function activateInitialRow() {
      const rs = rows();
      if (!rs.length) return;
      let target = null;
      for (let i = 0; i < rs.length; i++) {
        if (!rs[i].classList.contains('is-rest')) { target = rs[i]; break; }
      }
      if (!target) target = rs[0];
      setActiveRow(target);
    }

    function onScroll() {
      // Throttle with a short timeout rather than requestAnimationFrame.
      // The lobby uses rAF (it has to interleave with its matrix
      // centre-on-active smooth-scroll re-entrancy guard); this surface has
      // no matrix, and a timeout fires reliably even when the document isn't
      // actively painting (rAF can be starved in a backgrounded / headless
      // context). 16ms ≈ one frame, so scroll-tracking stays smooth.
      if (scrollThrottleToken != null) return;
      scrollThrottleToken = setTimeout(() => {
        scrollThrottleToken = null;
        recompute();
      }, 16);
    }

    function wire() {
      if (wired) return;
      wired = true;
      // The handout scrolls the document/body (no fixed inner scroller), so
      // listen on the right target. When a dedicated element scroller is
      // supplied (not the page), listen on it; otherwise window scroll.
      const isPageScroller = scroller === document.documentElement
        || scroller === document.body
        || scroller === document.scrollingElement;
      if (isPageScroller) {
        window.addEventListener('scroll', onScroll, { passive: true });
      } else {
        scroller.addEventListener('scroll', onScroll, { passive: true });
      }
      window.addEventListener('resize', onScroll, { passive: true });
    }

    function destroy() {
      const isPageScroller = scroller === document.documentElement
        || scroller === document.body
        || scroller === document.scrollingElement;
      if (isPageScroller) window.removeEventListener('scroll', onScroll);
      else scroller.removeEventListener('scroll', onScroll);
      window.removeEventListener('resize', onScroll);
      if (scrollThrottleToken != null) clearTimeout(scrollThrottleToken);
      if (lazyKickToken != null) clearTimeout(lazyKickToken);
      wired = false;
    }

    wire();

    return {
      activateInitialRow: activateInitialRow,
      recompute: recompute,
      destroy: destroy,
    };
  }

  // =========================================================================
  // Expose
  // =========================================================================

  window.HomefitExerciseCard = Object.freeze({
    buildListHTML: buildListHTML,
    hydrateHeroCrops: hydrateHeroCrops,
    createInteractivity: createInteractivity,
    // Exposed for surfaces that want to compose their own list logic.
    renderHeroHTML: renderHeroHTML,
    exerciseRowHTML: exerciseRowHTML,
    restRowHTML: restRowHTML,
    circuitGroupHTML: circuitGroupHTML,
    buildDoseLine: buildDoseLine,
    escapeHTML: escapeHTML,
  });
})();
