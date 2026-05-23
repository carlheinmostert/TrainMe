/**
 * homefit.studio — Live transparency page (`/v/{slug}/{premises}/now`)
 *
 * Safe Mode Transparency — Phase B (2026-05-22) + Live-view cosmetic
 * + functional pass (2026-05-23, items 15-19 of stack file).
 *
 * Architectural reversal (2026-05-23 evening): the map background is now
 * a live Leaflet map with Esri World Imagery satellite tiles + the
 * polygon as an L.polygon overlay, instead of a baked Mapbox Static
 * Images snapshot. Matches the pattern in
 * web-portal/src/components/PremisesPolygonEditor.tsx — free, key-less,
 * vendor-consistent.
 *
 * Polls `get_live_sessions(practiceSlug, premisesSlug)` every 12 seconds
 * and renders:
 *   - The practice's enforced-Safe-Mode polygon as a Leaflet polygon
 *     overlay on top of the satellite tiles.
 *   - Active practitioner cards as DOM elements absolute-positioned over
 *     the Leaflet container; their pixel position is recomputed on every
 *     Leaflet move/zoom event (and after each poll) via
 *     map.latLngToContainerPoint.
 *   - A sage "You are here" Leaflet marker anchored to the viewer's own
 *     geolocation (browser-only — never sent to our server).
 *   - Canonical brand lockup top-right + centred at bottom (per item
 *     15 + item 18 of the stack file).
 *   - Dynamic "{N} people are recording right now" headline with
 *     pluralisation (per item 17).
 */
(function () {
  'use strict';

  const POLL_INTERVAL_MS = 12000;

  const elLoading = document.getElementById('live-loading');
  const elContent = document.getElementById('live-content');
  const elNotFound = document.getElementById('live-not-found');
  const elPracticeMark = document.getElementById('live-practice-mark');
  const elPracticeName = document.getElementById('live-practice-name');
  const elPracticeLoc = document.getElementById('live-practice-loc');
  const elMeta = document.getElementById('live-meta');
  const elMap = document.getElementById('live-map');
  const elCardLayer = document.getElementById('live-card-layer');
  const elReportModal = document.getElementById('live-report-modal');
  const elTopLogo = document.getElementById('live-top-logo');
  const elFooterLogo = document.getElementById('live-footer-logo');
  const elHeroH1 = document.getElementById('live-hero-h1');
  const elHeroTitle = document.getElementById('live-hero-title');

  let pollTimer = null;
  let viewerPos = null; // { lat, lng } — never leaves the browser.
  let lastUpdatedAt = 0;
  let metaTicker = null;

  // ---------------------------------------------------------------------
  // Leaflet state — created lazily on first poll (after the live-content
  // element is unhidden, so the map container has non-zero dimensions).
  // ---------------------------------------------------------------------
  let map = null;
  let polygonLayer = null;
  let viewerMarker = null;
  let lastSessions = []; // most recent session payload — re-projected on Leaflet events
  let mapFittedOnce = false; // only fit-bounds on the FIRST polygon paint
  let lastPolygonKey = null; // skip re-paint when the same polygon repeats

  // ---------------------------------------------------------------------
  // Item 25 (2026-05-23): avatar-only practitioner pins + tap-to-expand
  // popover. State machine — only ONE popover open at a time. The cached
  // contact + session payload keep the popover content cheap to re-render.
  // ---------------------------------------------------------------------
  let openSessionId = null;
  let elPopover = null;
  let practiceContactCached = null; // most recent practice contact (for popover Report)
  let outsideTapHandler = null;
  let escKeyHandler = null;

  function slugsFromPath() {
    // Per-premises shape: /v/{practice-slug}/{premises-slug}/now.
    const m = String(window.location.pathname || '').match(
      /^\/v\/([^/]+)\/([^/]+)\/now/,
    );
    if (!m) return null;
    return {
      practiceSlug: decodeURIComponent(m[1]).toLowerCase(),
      premisesSlug: decodeURIComponent(m[2]).toLowerCase(),
    };
  }

  function show(el) { if (el) el.hidden = false; }
  function hide(el) { if (el) el.hidden = true; }

  // ---------------------------------------------------------------------
  // Item 16 — practice mark: uploaded logo wins; else two-letter initials
  // derived from first letters of first two whitespace-separated tokens
  // of the practice name (uppercase). If only one token, first two
  // letters of that token.
  // ---------------------------------------------------------------------
  function deriveInitials(name) {
    const tokens = String(name || '').trim().split(/\s+/).filter(Boolean);
    if (tokens.length === 0) return '·';
    if (tokens.length === 1) {
      const t = tokens[0];
      return (t.length >= 2 ? t.substring(0, 2) : t.charAt(0)).toUpperCase();
    }
    return (tokens[0].charAt(0) + tokens[1].charAt(0)).toUpperCase();
  }

  function paintPracticeMark(name, logoUrl) {
    if (!elPracticeMark) return;
    while (elPracticeMark.firstChild) elPracticeMark.removeChild(elPracticeMark.firstChild);
    elPracticeMark.classList.remove('has-logo');
    if (logoUrl) {
      const img = document.createElement('img');
      img.src = logoUrl;
      img.alt = '';
      img.loading = 'lazy';
      img.addEventListener('error', () => {
        elPracticeMark.classList.remove('has-logo');
        while (elPracticeMark.firstChild) elPracticeMark.removeChild(elPracticeMark.firstChild);
        elPracticeMark.textContent = deriveInitials(name);
      });
      elPracticeMark.classList.add('has-logo');
      elPracticeMark.appendChild(img);
    } else {
      elPracticeMark.textContent = deriveInitials(name);
    }
  }

  // ---------------------------------------------------------------------
  // Items 15 + 18 — canonical lockup logos (matrix + wordmark stacked).
  // Mirrors `buildHomefitLogoLockupSvg()` from web-player/app.js so the
  // live page doesn't have to pull in app.js (separate bundle by design).
  // Wordmark colour split is locked: `homefit` is #F0F0F5, `.studio`
  // (with the dot) is coral #FF6B35 — per the brand block in CLAUDE.md.
  // ---------------------------------------------------------------------
  function _matrixBody(yOffset) {
    const dy = yOffset || 0;
    const y = (n) => (n + dy).toFixed(3).replace(/\.?0+$/, '');
    const coral = '#FF6B35';
    const sage = '#86EFAC';
    const ghostOuter = '#4B5563';
    const ghostMid = '#6B7280';
    const ghostInner = '#9CA3AF';
    return (
      `<rect x="0" y="${y(2.75)}" width="2.5" height="1.5" rx="0.5" fill="${ghostOuter}"/>` +
      `<rect x="4" y="${y(2.45)}" width="3.5" height="2.1" rx="0.7" fill="${ghostMid}"/>` +
      `<rect x="9" y="${y(2.15)}" width="4.5" height="2.7" rx="0.9" fill="${ghostInner}"/>` +
      `<rect x="14.5" y="${y(1)}" width="12.5" height="8.5" rx="1.2" fill="${coral}" opacity="0.15"/>` +
      `<rect x="15" y="${y(2)}" width="5" height="3" rx="1" fill="${coral}"/>` +
      `<rect x="15" y="${y(6.5)}" width="5" height="3" rx="1" fill="${coral}"/>` +
      `<rect x="21.5" y="${y(2)}" width="5" height="3" rx="1" fill="${coral}"/>` +
      `<rect x="21.5" y="${y(6.5)}" width="5" height="3" rx="1" fill="${coral}"/>` +
      `<rect x="28" y="${y(2)}" width="5" height="3" rx="1" fill="${sage}"/>` +
      `<rect x="34.5" y="${y(2.15)}" width="4.5" height="2.7" rx="0.9" fill="${ghostInner}"/>` +
      `<rect x="40.5" y="${y(2.45)}" width="3.5" height="2.1" rx="0.7" fill="${ghostMid}"/>` +
      `<rect x="45.5" y="${y(2.75)}" width="2.5" height="1.5" rx="0.5" fill="${ghostOuter}"/>`
    );
  }

  function buildLockupSvg() {
    return (
      '<svg viewBox="0 -2 48 16" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="homefit.studio">' +
      '<text x="24" y="4.6" text-anchor="middle" textLength="48"' +
      ' lengthAdjust="spacingAndGlyphs"' +
      ' font-family="Montserrat, sans-serif" font-weight="600"' +
      ' font-size="6.5" letter-spacing="-0.1">' +
      '<tspan fill="#F0F0F5">homefit</tspan>' +
      '<tspan fill="#FF6B35">.studio</tspan>' +
      '</text>' +
      _matrixBody(4.5) +
      '</svg>'
    );
  }

  function paintLogos() {
    if (elTopLogo) elTopLogo.innerHTML = buildLockupSvg();
    if (elFooterLogo) elFooterLogo.innerHTML = buildLockupSvg();
  }

  // ---------------------------------------------------------------------
  // Item 17 — dynamic hero headline with pluralisation.
  // ---------------------------------------------------------------------
  function paintHero(sessionCount) {
    if (!elHeroH1 || !elHeroTitle) return;
    let title;
    if (sessionCount === 0) {
      title = 'Nobody is recording right now';
      elHeroH1.classList.add('is-empty');
    } else if (sessionCount === 1) {
      title = '1 person is recording right now';
      elHeroH1.classList.remove('is-empty');
    } else {
      title = `${sessionCount} people are recording right now`;
      elHeroH1.classList.remove('is-empty');
    }
    elHeroTitle.textContent = title;
  }

  // ---------------------------------------------------------------------
  // Leaflet map — initialised lazily on first poll. Defaults to satellite
  // (matches the bystander mental model: "show me the venue"). The Esri
  // World Imagery tiles are key-less and identical to the editor's
  // satellite layer.
  // ---------------------------------------------------------------------
  function ensureMap() {
    if (map || !window.L || !elMap) return map;
    // Pin a generous maxZoom so the layer switcher doesn't re-clamp the
    // view mid-session. maxNativeZoom caps tile fetches at the highest
    // zoom each layer actually has imagery for; beyond that Leaflet
    // upscales (slight blur, but the venue still resolves).
    //
    // 2026-05-23 (item 24 of stack): bumped from 19/18 → 21/19. Esri
    // World Imagery has z19 native tiles in most SA urban areas; z20-21
    // are upscaled but available for users who want to lean in. The
    // previous 19/18 cap was conservative — bystanders zooming into a
    // dense gym layout hit the wall too early.
    const MAP_MAX_ZOOM = 21;
    const ESRI_MAX_NATIVE = 19;
    const OSM_MAX_NATIVE = 19;

    map = window.L.map(elMap, {
      // Sensible default until the polygon arrives + we fitBounds it.
      center: [-26.2041, 28.0473], // Johannesburg-ish; replaced on first polygon paint
      zoom: 17,
      maxZoom: MAP_MAX_ZOOM,
      zoomControl: true,
      attributionControl: true,
    });

    const street = window.L.tileLayer(
      'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
      {
        maxZoom: MAP_MAX_ZOOM,
        maxNativeZoom: OSM_MAX_NATIVE,
        attribution: '© OpenStreetMap contributors',
      },
    );
    const satellite = window.L.tileLayer(
      'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
      {
        maxZoom: MAP_MAX_ZOOM,
        maxNativeZoom: ESRI_MAX_NATIVE,
        attribution: 'Tiles © Esri — Source: Esri, Maxar, Earthstar Geographics',
      },
    );
    const labels = window.L.tileLayer(
      'https://server.arcgisonline.com/ArcGIS/rest/services/Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}',
      {
        maxZoom: MAP_MAX_ZOOM,
        maxNativeZoom: ESRI_MAX_NATIVE,
        attribution: 'Labels © Esri',
      },
    );
    // Default to satellite — bystanders want venue context.
    satellite.addTo(map);
    window.L.control
      .layers(
        { Satellite: satellite, Street: street },
        { Labels: labels },
        { collapsed: true },
      )
      .addTo(map);

    // Reproject practitioner cards + viewer dot whenever the map moves.
    map.on('move zoom moveend zoomend', () => {
      repositionCards();
      repositionViewerDot();
    });

    // First-paint sizing: Leaflet caches container size on init. If the
    // live-content section was hidden when ensureMap() ran (it isn't
    // today, but defensive), the map would render at 0×0. invalidateSize
    // on the next frame covers that and any modal-ish wrappers.
    requestAnimationFrame(() => {
      if (map) map.invalidateSize();
    });
    return map;
  }

  function paintPolygon(premises) {
    if (!map || !window.L) return;
    // Filter to the rings we actually have. Each premises entry has a
    // polygon array of [lng, lat] pairs (matches the editor's storage
    // shape).
    const rings = premises
      .map((p) => (p.polygon || [])
        .map((pt) => Array.isArray(pt) && pt.length >= 2
          ? [Number(pt[1]), Number(pt[0])] // Leaflet wants [lat, lng]
          : null)
        .filter(Boolean))
      .filter((r) => r.length >= 3);

    // Skip re-paint when the polygon hasn't changed (poll is every 12s;
    // tearing down + re-creating the Leaflet polygon causes a slight
    // flash). Cheap key: stringified ring coords.
    const key = JSON.stringify(rings);
    if (key === lastPolygonKey) return;
    lastPolygonKey = key;

    if (polygonLayer) {
      polygonLayer.remove();
      polygonLayer = null;
    }
    if (rings.length === 0) return;

    polygonLayer = window.L.polygon(rings, {
      color: '#FF6B35',
      weight: 2,
      dashArray: '4 3',
      fillColor: '#FF6B35',
      fillOpacity: 0.08,
    }).addTo(map);

    // Only auto-fit the FIRST time we see a polygon — subsequent re-paints
    // would yank a user's manual zoom/pan around. Tiny pad inset so the
    // dashed stroke isn't kissing the card edges.
    if (!mapFittedOnce) {
      try {
        map.fitBounds(polygonLayer.getBounds(), {
          padding: [20, 20],
          // Match the satellite native cap so initial fit lands on crisp
          // tiles; users can lean to z20-21 (upscaled) via the +
          // control if they want closer.
          maxZoom: 19,
        });
        mapFittedOnce = true;
      } catch (_) { /* getBounds throws on empty ring */ }
    }
  }

  function repositionCards() {
    if (!map || !elCardLayer) return;
    // Item 25: cards are now avatar pins (.live-pavatar). Same positional
    // contract: dataset.lat/lng → container point → top/left.
    const pins = elCardLayer.querySelectorAll('.live-pavatar');
    pins.forEach((pin) => {
      const lat = Number(pin.dataset.lat);
      const lng = Number(pin.dataset.lng);
      if (!Number.isFinite(lat) || !Number.isFinite(lng)) return;
      const pt = map.latLngToContainerPoint([lat, lng]);
      pin.style.left = `${pt.x}px`;
      pin.style.top = `${pt.y}px`;
    });
    // If a popover is open, reproject it too.
    if (openSessionId && elPopover) {
      const session = lastSessions.find((s) => s.sessionId === openSessionId);
      if (session && Number.isFinite(session.latitude) && Number.isFinite(session.longitude)) {
        const mapRect = elMap.getBoundingClientRect();
        const pt = map.latLngToContainerPoint([session.latitude, session.longitude]);
        // If the underlying avatar has scrolled out of the visible map,
        // close the popover gracefully.
        if (pt.x < 0 || pt.y < 0 || pt.x > mapRect.width || pt.y > mapRect.height) {
          closePopover();
        } else {
          positionPopover(pt.x, pt.y);
        }
      } else {
        closePopover();
      }
    }
  }

  function repositionViewerDot() {
    // Viewer dot is a Leaflet marker — Leaflet itself handles repositioning
    // on move/zoom. Nothing to do here. Kept as a hook in case we ever
    // switch to a DOM-positioned dot.
  }

  // -------------------------------------------------------------------
  // Item 25 (2026-05-23): each active session is a 40×40 circular
  // avatar pin (coral pulsing border = "actively recording"). Tap to
  // open a popover with the full card body (name + duration · venue +
  // Report). Predictable behaviour regardless of session count — the
  // pulse signals presence; no auto-expand.
  //
  // KNOWN LIMITATION: avatars overlap at high zoom when two
  // practitioners are within ~6m of each other. Cluster-into-"+N"-badge
  // behaviour is out of scope for this PR — follow-up.
  // -------------------------------------------------------------------
  function drawSessions(sessions, practiceContact) {
    if (!elCardLayer) return;
    practiceContactCached = practiceContact;

    // If the currently-open popover's session vanished from the new
    // payload (session ended, heartbeat stale), close gracefully before
    // we wipe the avatar layer.
    if (openSessionId && !sessions.some((s) => s.sessionId === openSessionId)) {
      closePopover();
    }

    // Clear existing avatar pins. (Viewer dot is a Leaflet marker;
    // popover lives on document.body separately.)
    while (elCardLayer.firstChild) elCardLayer.removeChild(elCardLayer.firstChild);

    sessions.forEach((s) => {
      const hasFix = Number.isFinite(s.latitude) && Number.isFinite(s.longitude);
      if (!hasFix) return;

      const pin = document.createElement('div');
      pin.className = 'live-pavatar';
      pin.dataset.lat = String(s.latitude);
      pin.dataset.lng = String(s.longitude);
      pin.dataset.sessionId = s.sessionId || '';

      // Accessibility — pin reads as a button, opens the practitioner
      // detail popover. The aria-label communicates who's recording
      // where; keyboard users get tab + Enter/Space parity with tap.
      const fullName = [s.firstName, s.lastName].filter(Boolean).join(' ') || 'Practitioner';
      const wherePart = s.premisesName ? s.premisesName : (s.manualMode ? 'a manual zone' : 'this venue');
      pin.setAttribute('role', 'button');
      pin.setAttribute('aria-label', `${fullName}, recording at ${wherePart}`);
      pin.setAttribute('tabindex', '0');

      if (s.avatarUrl) {
        const img = document.createElement('img');
        img.src = s.avatarUrl;
        img.alt = '';
        pin.appendChild(img);
      } else {
        // Coral-on-coral-tint initials fallback. Two-letter initials.
        pin.classList.add('is-initials');
        pin.textContent = sessionInitials(s.firstName, s.lastName);
      }

      const open = (evt) => {
        if (evt) {
          evt.preventDefault();
          evt.stopPropagation();
        }
        togglePopover(s);
      };
      pin.addEventListener('click', open);
      pin.addEventListener('keydown', (evt) => {
        if (evt.key === 'Enter' || evt.key === ' ') open(evt);
      });

      elCardLayer.appendChild(pin);
    });

    // Position pins once; reposition handlers keep them aligned on
    // subsequent map move/zoom events.
    repositionCards();
  }

  // -------------------------------------------------------------------
  // Popover state machine — only one open at a time. Opening a
  // different pin closes the current one; tapping the same pin toggles.
  // -------------------------------------------------------------------
  function togglePopover(session) {
    if (openSessionId === session.sessionId) {
      closePopover();
      return;
    }
    openPopover(session);
  }

  function openPopover(session) {
    closePopover(); // ensure single-open invariant
    if (!session || !map) return;
    if (!(Number.isFinite(session.latitude) && Number.isFinite(session.longitude))) return;

    const fullName = [session.firstName, session.lastName].filter(Boolean).join(' ') || 'Practitioner';
    const dur = formatDuration(session.startedAt);
    const zone = session.premisesName ? session.premisesName : (session.manualMode ? 'Manual' : 'In zone');

    elPopover = document.createElement('div');
    elPopover.className = 'live-popover';
    elPopover.setAttribute('role', 'dialog');
    elPopover.setAttribute('aria-label', `${fullName} — details`);

    const name = document.createElement('div');
    name.className = 'live-popover-name';
    name.textContent = fullName;

    const meta = document.createElement('div');
    meta.className = 'live-popover-meta';
    meta.textContent = `${dur} · ${zone}`;

    const report = document.createElement('button');
    report.className = 'live-popover-report';
    report.type = 'button';
    report.textContent = 'Report';
    report.addEventListener('click', (evt) => {
      evt.stopPropagation();
      openReportModal(session, practiceContactCached);
    });

    // The tail/pointer triangle. Direction class flipped by
    // positionPopover() based on auto-flip side.
    const tail = document.createElement('div');
    tail.className = 'live-popover-tail';

    elPopover.appendChild(name);
    elPopover.appendChild(meta);
    elPopover.appendChild(report);
    elPopover.appendChild(tail);

    // Append into the map shell so the popover shares the map's
    // positioning context (and z-stacks above the avatar layer cleanly).
    const shell = elMap && elMap.parentElement;
    (shell || document.body).appendChild(elPopover);

    openSessionId = session.sessionId;

    // Initial position — repositionCards() will re-do this on every
    // map move/zoom event.
    const pt = map.latLngToContainerPoint([session.latitude, session.longitude]);
    positionPopover(pt.x, pt.y);

    // Wire dismiss handlers. defer the outside-tap listener to the next
    // tick so the click that opened us doesn't immediately close us.
    setTimeout(() => {
      outsideTapHandler = (evt) => {
        if (!elPopover) return;
        // Ignore clicks inside the popover or on any avatar pin.
        if (elPopover.contains(evt.target)) return;
        if (evt.target.closest && evt.target.closest('.live-pavatar')) return;
        closePopover();
      };
      document.addEventListener('mousedown', outsideTapHandler, true);
      document.addEventListener('touchstart', outsideTapHandler, true);
    }, 0);

    escKeyHandler = (evt) => {
      if (evt.key === 'Escape') closePopover();
    };
    document.addEventListener('keydown', escKeyHandler);
  }

  function closePopover() {
    if (elPopover && elPopover.parentNode) {
      elPopover.parentNode.removeChild(elPopover);
    }
    elPopover = null;
    openSessionId = null;
    if (outsideTapHandler) {
      document.removeEventListener('mousedown', outsideTapHandler, true);
      document.removeEventListener('touchstart', outsideTapHandler, true);
      outsideTapHandler = null;
    }
    if (escKeyHandler) {
      document.removeEventListener('keydown', escKeyHandler);
      escKeyHandler = null;
    }
  }

  // Hand-rolled auto-flip: try the default side (above the avatar);
  // if there's not enough room, try below; then right; then left.
  // x/y are the avatar's pixel coords inside the map container.
  function positionPopover(avatarX, avatarY) {
    if (!elPopover || !elMap) return;
    const mapRect = elMap.getBoundingClientRect();
    const avatarOffset = 26; // half the 40px avatar + a small gap

    // Measure the popover. We need its size to compute flip targets;
    // briefly force it visible-but-offscreen so layout settles.
    const prevVisibility = elPopover.style.visibility;
    elPopover.style.visibility = 'hidden';
    elPopover.style.left = '-9999px';
    elPopover.style.top = '-9999px';
    elPopover.classList.remove('live-popover-below', 'live-popover-above', 'live-popover-left', 'live-popover-right');
    elPopover.classList.add('live-popover-above'); // start with tail-down assumption for size measure
    // Force layout
    // eslint-disable-next-line no-unused-vars
    const _ = elPopover.offsetHeight;
    const popW = elPopover.offsetWidth;
    const popH = elPopover.offsetHeight;
    elPopover.style.visibility = prevVisibility || '';

    // Candidate slots (top-left of popover) for each side, in priority
    // order: above → below → right → left.
    const slots = [
      {
        side: 'above',
        left: avatarX - popW / 2,
        top: avatarY - avatarOffset - popH,
      },
      {
        side: 'below',
        left: avatarX - popW / 2,
        top: avatarY + avatarOffset,
      },
      {
        side: 'right',
        left: avatarX + avatarOffset,
        top: avatarY - popH / 2,
      },
      {
        side: 'left',
        left: avatarX - avatarOffset - popW,
        top: avatarY - popH / 2,
      },
    ];

    const fits = (slot) => slot.left >= 4
      && slot.top >= 4
      && slot.left + popW <= mapRect.width - 4
      && slot.top + popH <= mapRect.height - 4;

    const chosen = slots.find(fits) || slots[0];

    // Clamp to the map container so the popover never escapes its edge,
    // even when no slot fits cleanly (small viewport case).
    const left = Math.max(4, Math.min(chosen.left, mapRect.width - popW - 4));
    const top = Math.max(4, Math.min(chosen.top, mapRect.height - popH - 4));

    elPopover.classList.remove('live-popover-above', 'live-popover-below', 'live-popover-left', 'live-popover-right');
    elPopover.classList.add(`live-popover-${chosen.side}`);
    elPopover.style.left = `${left}px`;
    elPopover.style.top = `${top}px`;

    // Position the tail so it points back at the avatar relative to
    // the popover's chosen side. Tail is the .live-popover-tail child.
    const tail = elPopover.querySelector('.live-popover-tail');
    if (tail) {
      if (chosen.side === 'above' || chosen.side === 'below') {
        const tx = Math.max(8, Math.min(popW - 8, avatarX - left));
        tail.style.left = `${tx}px`;
        tail.style.top = '';
      } else {
        const ty = Math.max(8, Math.min(popH - 8, avatarY - top));
        tail.style.top = `${ty}px`;
        tail.style.left = '';
      }
    }
  }

  function sessionInitials(first, last) {
    const a = (first || '').trim().charAt(0).toUpperCase();
    const b = (last || '').trim().charAt(0).toUpperCase();
    return (a + b) || '·';
  }

  function paintViewerDot() {
    if (!map || !window.L) return;
    if (!viewerPos) {
      if (viewerMarker) {
        viewerMarker.remove();
        viewerMarker = null;
      }
      return;
    }
    const icon = window.L.divIcon({
      className: 'live-you-marker',
      // Sage dot with a soft ring — mirrors the styles.css .live-you
      // appearance (which we kept for fallback). Inline style so the
      // marker is self-contained without needing another stylesheet hop.
      html:
        '<div style="width:16px;height:16px;border-radius:50%;' +
        'background:#86EFAC;box-shadow:0 0 0 4px rgba(134,239,172,0.25);' +
        '"></div>',
      iconSize: [16, 16],
      iconAnchor: [8, 8],
    });
    if (viewerMarker) {
      viewerMarker.setLatLng([viewerPos.lat, viewerPos.lng]);
      viewerMarker.setIcon(icon);
    } else {
      viewerMarker = window.L.marker([viewerPos.lat, viewerPos.lng], {
        icon,
        interactive: false,
        keyboard: false,
        title: 'You are here',
      }).addTo(map);
    }
  }

  function formatDuration(startedAtIso) {
    if (!startedAtIso) return 'live';
    const startedMs = Date.parse(startedAtIso);
    if (!Number.isFinite(startedMs)) return 'live';
    const elapsed = Math.max(0, Date.now() - startedMs);
    const mins = Math.floor(elapsed / 60000);
    if (mins < 1) return 'just now';
    if (mins < 60) return `${mins}m`;
    const hrs = Math.floor(mins / 60);
    return `${hrs}h ${mins % 60}m`;
  }

  function updateMetaTicker() {
    if (!lastUpdatedAt) return;
    const secs = Math.max(0, Math.floor((Date.now() - lastUpdatedAt) / 1000));
    elMeta.textContent = secs <= 2
      ? 'Updated just now'
      : `Updated ${secs}s ago`;
  }

  function paintHeader(data) {
    elPracticeName.textContent = data.practiceName || 'Practice';
    const firstPremises = data.premises[0];
    elPracticeLoc.textContent = firstPremises ? firstPremises.name : '';
    paintPracticeMark(data.practiceName, data.practiceLogoUrl);
  }

  // ---------------------------------------------------------------------
  // Poll loop
  // ---------------------------------------------------------------------
  let practiceContact = null;
  async function poll() {
    const slugs = slugsFromPath();
    if (!slugs) {
      show(elNotFound);
      hide(elLoading);
      return;
    }
    const data = await window.HomefitApi.getLiveSessions(
      slugs.practiceSlug,
      slugs.premisesSlug,
    );
    if (!data || !data.practiceId) {
      hide(elContent);
      hide(elLoading);
      show(elNotFound);
      return;
    }
    hide(elLoading);
    hide(elNotFound);
    show(elContent);

    paintHeader(data);

    // Map is created lazily AFTER live-content is unhidden so the
    // container has non-zero dimensions on first paint.
    ensureMap();
    if (map) {
      // Defensive: re-measure in case the parent only just became visible.
      map.invalidateSize();
    }

    paintPolygon(data.premises);

    if (!practiceContact) {
      practiceContact = await fetchPracticeContact(slugs.practiceSlug);
    }

    lastSessions = data.sessions;
    drawSessions(lastSessions, practiceContact);
    paintHero(lastSessions.length);
    paintViewerDot();
    lastUpdatedAt = Date.now();
    updateMetaTicker();
  }

  async function fetchPracticeContact(slug) {
    try {
      const profile = await window.HomefitApi.getPracticeProfile(slug);
      if (!profile) return null;
      return {
        practiceName: profile.practice_name || profile.practiceName || '',
        contactEmail: profile.contact_email || profile.contactEmail || '',
        contactWhatsapp: profile.contact_whatsapp || profile.contactWhatsapp || '',
      };
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------------
  // Report modal
  // ---------------------------------------------------------------------
  function openReportModal(session, contact) {
    const name = [session.firstName, session.lastName].filter(Boolean).join(' ') || 'this practitioner';
    const routeLine = contact && (contact.contactEmail || contact.contactWhatsapp)
      ? `via <strong>${escapeHtml(contact.contactEmail || contact.contactWhatsapp)}</strong>`
      : 'via their listed contact';
    const practiceLabel = contact && contact.practiceName
      ? escapeHtml(contact.practiceName)
      : 'The practice owner';
    elReportModal.innerHTML = `
      <div class="live-report-backdrop">
        <div class="live-report-card" role="dialog" aria-label="Report ${escapeHtml(name)}">
          <h2>Report ${escapeHtml(name)}</h2>
          <div class="live-report-routes">
            This report will be sent to <strong>${practiceLabel}</strong> ${routeLine}.
          </div>
          <textarea class="live-report-textarea"
            placeholder="What happened? (max 500 chars)"
            maxlength="500" id="live-report-reason"></textarea>
          <div class="live-report-actions">
            <button class="live-btn" id="live-report-cancel" type="button">Cancel</button>
            <button class="live-btn live-btn-primary" id="live-report-submit" type="button">Send report</button>
          </div>
        </div>
      </div>
    `;
    elReportModal.hidden = false;

    const close = () => {
      elReportModal.hidden = true;
      elReportModal.innerHTML = '';
    };
    document.getElementById('live-report-cancel').addEventListener('click', close);
    document.getElementById('live-report-submit').addEventListener('click', async () => {
      const reason = String(document.getElementById('live-report-reason').value || '').trim();
      if (!reason) {
        showToast('Please describe the issue first.', true);
        return;
      }
      document.getElementById('live-report-submit').disabled = true;
      const ok = await submitReport(session.sessionId, reason);
      if (ok) {
        showToast('Report sent. Thanks for keeping this venue safe.');
        close();
      } else {
        showToast('Could not send report. Try again later.', true);
        document.getElementById('live-report-submit').disabled = false;
      }
    });
  }

  async function submitReport(sessionId, reason) {
    const fingerprint = window.__homefitLiveFingerprint || '';
    const id = await window.HomefitApi.reportSession(sessionId, reason, fingerprint);
    return Boolean(id);
  }

  function escapeHtml(s) {
    return String(s || '').replace(/[&<>"']/g, (c) => ({
      '&': '&amp;',
      '<': '&lt;',
      '>': '&gt;',
      '"': '&quot;',
      "'": '&#39;',
    })[c]);
  }

  function showToast(message, isError) {
    const existing = document.querySelector('.live-toast');
    if (existing) existing.remove();
    const toast = document.createElement('div');
    toast.className = 'live-toast' + (isError ? ' error' : '');
    toast.textContent = message;
    document.body.appendChild(toast);
    setTimeout(() => toast.remove(), 3500);
  }

  function ensureFingerprint() {
    try {
      const key = 'homefit.fingerprint';
      let fp = window.localStorage.getItem(key);
      if (!fp) {
        fp = (typeof window.crypto !== 'undefined' && window.crypto.randomUUID)
          ? window.crypto.randomUUID()
          : ('fp-' + Math.random().toString(36).slice(2) + Date.now().toString(36));
        window.localStorage.setItem(key, fp);
      }
      return fp;
    } catch (_) {
      return '';
    }
  }
  window.__homefitLiveFingerprint = ensureFingerprint();

  function requestViewerLocation() {
    if (!navigator.geolocation) return;
    try {
      navigator.geolocation.getCurrentPosition(
        (pos) => {
          viewerPos = {
            lat: pos.coords.latitude,
            lng: pos.coords.longitude,
          };
          paintViewerDot();
        },
        () => {},
        { enableHighAccuracy: false, timeout: 6000, maximumAge: 60000 },
      );
    } catch (_) {}
  }

  function boot() {
    paintLogos();
    poll();
    pollTimer = window.setInterval(poll, POLL_INTERVAL_MS);
    metaTicker = window.setInterval(updateMetaTicker, 1000);
    requestViewerLocation();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
})();
