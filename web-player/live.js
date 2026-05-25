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

  // ==========================================================================
  // Service worker self-heal — auto-reload on new SW take-over
  // ==========================================================================
  //
  // The live page (/v/{practice}/{premises}/now) does NOT register a SW —
  // live.html only loads config.js + api.js + live.js. But a SW registered
  // by a prior visit to /p/{planId} on this origin has scope `/` and would
  // otherwise control this tab's fetches. The companion SW change (see
  // web-player/sw.js) already short-circuits the fetch handler for `/v/*`
  // so the controller is invisible for live-page subresources; this
  // listener is the second half — when a new SW takes over (the user had
  // a stale controller from a prior /p visit and a deploy just landed),
  // reload so the new bundle is in memory immediately. No workout-guard
  // needed; the live page has no client-facing in-progress state to
  // protect.
  if ('serviceWorker' in navigator) {
    navigator.serviceWorker.addEventListener('controllerchange', () => {
      window.location.reload();
    });
  }

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
  const elRosterLayer = document.getElementById('live-roster-layer');

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
  let fitControlEl = null;   // item 28: container for the fit-to-polygon button

  // ---------------------------------------------------------------------
  // Item 25 (2026-05-23): avatar-only practitioner pins + tap-to-expand
  // popover. State machine — only ONE popover open at a time. The cached
  // contact + session payload keep the popover content cheap to re-render.
  // ---------------------------------------------------------------------
  let openSessionId = null;
  let elPopover = null;
  let practiceContactCached = null; // most recent practice contact (for popover Report)
  let practiceSlugCached = null;    // most recent practice slug (for popover "View practice profile" link)
  let outsideTapHandler = null;
  let escKeyHandler = null;

  // ---------------------------------------------------------------------
  // PR A (2026-05-23): per-capture 24h roster + grace-fade state.
  //
  // The roster is polled on the same 12s cadence as the live sessions
  // payload; the data drives both the side drawer (recently-active list)
  // and the grace-period fade on map avatars (currently-active flipping
  // false → drawer-only over a 60s wall-clock window).
  //
  // graceTrainers maps trainer_id → {pin (DOM), lastLatLng, fadeStart}.
  // When a trainer disappears from the "currently active" set BUT still
  // has roster events in the last 24h, we hold the pin for 60s with a
  // slow opacity fade. If they become active again inside that window,
  // we cancel the grace + snap back to the live pulse.
  // ---------------------------------------------------------------------
  let lastRoster = []; // [{trainerId, currentlyActive, firstName, ...events}]
  let drawerOpen = false;
  let selectedTrainerId = null;
  let elDrawer = null;
  let elDrawerPill = null;
  let elTimeline = null;
  let drawerOutsideTapHandler = null;
  let drawerEscKeyHandler = null;
  let graceTrainers = new Map(); // trainer_id → {pin, startedAt, lastLatLng}
  let graceTickTimer = null;
  const GRACE_DURATION_MS = 60000;

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

    // Item 28 (2026-05-23): manual "fit to polygon" button. Sits in the
    // topleft chrome stack below the +/- zoom control. Re-runs the same
    // fitMapToPolygon() call the auto-fit-on-first-paint uses so framing
    // is identical. Disabled until polygonLayer is loaded.
    const FitControl = window.L.Control.extend({
      options: { position: 'topleft' },
      onAdd() {
        const container = window.L.DomUtil.create(
          'div',
          'leaflet-bar live-fit-control',
        );
        const btn = window.L.DomUtil.create('a', 'live-fit-btn', container);
        btn.href = '#';
        btn.setAttribute('role', 'button');
        btn.setAttribute('aria-label', 'Fit polygon to view');
        btn.setAttribute('title', 'Fit polygon to view');
        // Square-with-inward-arrows glyph (corners collapse / fit-to-view
        // convention). Stroke uses currentColor so CSS hover colour
        // applies without touching the SVG.
        btn.innerHTML =
          '<svg viewBox="0 0 16 16" width="16" height="16" ' +
          'fill="none" stroke="currentColor" stroke-width="1.6" ' +
          'stroke-linecap="round" stroke-linejoin="round" ' +
          'aria-hidden="true" focusable="false">' +
          '<path d="M2 5.5V2h3.5"/>' +
          '<path d="M14 5.5V2h-3.5"/>' +
          '<path d="M2 10.5V14h3.5"/>' +
          '<path d="M14 10.5V14h-3.5"/>' +
          '</svg>';
        // Initial state — disabled until paintPolygon() runs.
        if (!polygonLayer) {
          container.classList.add('is-disabled');
          btn.setAttribute('aria-disabled', 'true');
          btn.setAttribute('title', 'No polygon to fit yet');
        }
        fitControlEl = container;
        window.L.DomEvent.on(btn, 'click', (e) => {
          window.L.DomEvent.preventDefault(e);
          window.L.DomEvent.stopPropagation(e);
          if (container.classList.contains('is-disabled')) return;
          fitMapToPolygon();
        });
        // Prevent map-drag / dblclick-zoom when interacting with the
        // button area.
        window.L.DomEvent.disableClickPropagation(container);
        window.L.DomEvent.disableScrollPropagation(container);
        return container;
      },
    });
    new FitControl().addTo(map);

    // Reproject practitioner cards + viewer dot whenever the map moves.
    map.on('move zoom moveend zoomend', () => {
      repositionCards();
      repositionViewerDot();
      repositionGracePins();
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
    if (rings.length === 0) {
      // No polygon → disable the manual fit button (item 28).
      if (fitControlEl) {
        fitControlEl.classList.add('is-disabled');
        const fitBtn = fitControlEl.querySelector('.live-fit-btn');
        if (fitBtn) {
          fitBtn.setAttribute('aria-disabled', 'true');
          fitBtn.setAttribute('title', 'No polygon to fit yet');
        }
      }
      return;
    }

    polygonLayer = window.L.polygon(rings, {
      color: '#FF6B35',
      weight: 2,
      dashArray: '4 3',
      fillColor: '#FF6B35',
      fillOpacity: 0.08,
    }).addTo(map);

    // Item 28: enable the manual fit-to-polygon button now that the
    // polygon layer exists.
    if (fitControlEl) {
      fitControlEl.classList.remove('is-disabled');
      const fitBtn = fitControlEl.querySelector('.live-fit-btn');
      if (fitBtn) {
        fitBtn.removeAttribute('aria-disabled');
        fitBtn.setAttribute('title', 'Fit polygon to view');
      }
    }

    // Only auto-fit the FIRST time we see a polygon — subsequent re-paints
    // would yank a user's manual zoom/pan around. Tight pad inset so the
    // polygon fills the visible area on small residential plots.
    //
    // 2026-05-23 (item 29): tightened padding 20→10 + raised maxZoom 19→20.
    // The previous 20px-per-edge inset left small polygons taking ~25% of
    // the visible map area (Carl's screenshot 2026-05-23). Z20 trades a
    // small upscale-sharpness cost on close-up fits for filling the
    // screen. Z21 stays reserved for manual user wheel/pinch.
    if (!mapFittedOnce) {
      try {
        map.fitBounds(polygonLayer.getBounds(), {
          padding: [10, 10],
          maxZoom: 20,
        });
        mapFittedOnce = true;
      } catch (_) { /* getBounds throws on empty ring */ }
    }
  }

  // Shared bounds-fit helper used by both the auto-fit-on-first-paint and
  // the item 28 manual "fit to polygon" button. Single source of truth
  // means the two callsites can never drift on padding / maxZoom.
  function fitMapToPolygon() {
    if (!map || !polygonLayer) return false;
    try {
      map.fitBounds(polygonLayer.getBounds(), {
        padding: [10, 10],
        maxZoom: 20,
      });
      return true;
    } catch (_) {
      return false;
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

    // "View practice profile" link — only rendered when the practice is
    // publicly listed (fetchPracticeContact returned non-null) AND we have
    // a cached slug to build the href from. Real <a href> so middle-click
    // / cmd-click opens a new tab; the popover's outside-tap handler
    // already exempts clicks inside elPopover via elPopover.contains().
    let profileLink = null;
    if (practiceContactCached && practiceSlugCached) {
      const practiceName = practiceContactCached.practiceName || 'this practice';
      profileLink = document.createElement('a');
      profileLink.className = 'live-popover-profile';
      profileLink.href = `/v/${encodeURIComponent(practiceSlugCached)}`;
      profileLink.setAttribute(
        'aria-label',
        `View ${practiceName} on homefit.studio`,
      );
      profileLink.textContent = 'View practice profile ';
      const chev = document.createElement('span');
      chev.className = 'live-popover-profile-chev';
      chev.setAttribute('aria-hidden', 'true');
      chev.textContent = '→'; // right-pointing arrow
      profileLink.appendChild(chev);
    }

    // The tail/pointer triangle. Direction class flipped by
    // positionPopover() based on auto-flip side.
    const tail = document.createElement('div');
    tail.className = 'live-popover-tail';

    // Action row — Report leads (more important on a transparency
    // page); "View practice profile" link follows. Wrap in a flex row
    // so they sit side-by-side with consistent baseline alignment.
    const actions = document.createElement('div');
    actions.className = 'live-popover-actions';
    actions.appendChild(report);
    if (profileLink) actions.appendChild(profileLink);

    elPopover.appendChild(name);
    elPopover.appendChild(meta);
    elPopover.appendChild(actions);
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
    // Item 26 (2026-05-23): sage dot now carries a permanent "You" pill
    // to its right so a fresh bystander immediately reads it as
    // self-location (mainstream Google/Apple Maps convention). The
    // wrapper is positioned so the dot stays exactly on the GPS coord
    // (iconAnchor pins the dot center, label flows right).
    const icon = window.L.divIcon({
      className: 'live-you-marker',
      html:
        '<div class="live-you-wrap">'
          + '<div class="live-you-dot"></div>'
          + '<div class="live-you-label">You</div>'
        + '</div>',
      // Wrapper is wider than the dot to accommodate the label. The dot
      // sits at the left edge of the wrapper; anchor at (8, 8) keeps the
      // dot center on the GPS coord regardless of label width.
      iconSize: [72, 16],
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
    // Cache the practice slug so the popover can construct a
    // /v/{practice-slug} link without re-parsing the path on each open.
    practiceSlugCached = slugs.practiceSlug;
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

    // PR A (2026-05-23): fetch the 24h roster on the same cadence. The
    // RPC is anon + idempotent + read-only; failure leaves the roster
    // empty and the side drawer simply doesn't appear.
    try {
      const roster = await window.HomefitApi.getPremisesActiveRoster(
        slugs.practiceSlug,
        slugs.premisesSlug,
        24,
      );
      handleRosterPayload(Array.isArray(roster) ? roster : []);
    } catch (_) {
      handleRosterPayload([]);
    }
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

  // =====================================================================
  // PR A (2026-05-23) — Per-capture 24h roster + grace fade
  // =====================================================================

  /**
   * Compare the incoming roster payload against the previous one + the
   * current `lastSessions` (currently active set) and:
   *   - Drive the grace-period fade for trainers who just went inactive
   *     (in roster, NOT in lastSessions, lookup by trainer_id).
   *   - Cancel any grace fade for trainers who came back active.
   *   - Re-render the side drawer (collapsed pill OR expanded panel).
   *
   * The roster is the source of truth for "who has been here in the last
   * 24h"; `lastSessions` is the source of truth for "who is recording
   * right now". The two intersect to drive the live pulse + drawer
   * placement.
   */
  function handleRosterPayload(roster) {
    lastRoster = roster;

    // Trainer IDs currently broadcasting a live session (heartbeat ≤60s).
    const liveIds = new Set(
      (lastSessions || []).map((s) => s.trainerId).filter(Boolean),
    );

    // Drive grace-fade transitions. Any trainer in the roster who is
    // NOT currently live but was last seen recently could be in the
    // fade window. We trust the roster's `currentlyActive` flag (server
    // computes it from active_capture_sessions), so we only need to
    // detect the FLIP from active → not-active.
    roster.forEach((r) => {
      const wasInGrace = graceTrainers.has(r.trainerId);
      if (r.currentlyActive) {
        // If they were in a grace fade, cancel cleanly — the live
        // drawSessions call will repaint them with the full pulse.
        if (wasInGrace) {
          cancelGrace(r.trainerId);
        }
      } else if (!wasInGrace) {
        // Newly inactive. Did they have a pin on the last live cycle?
        // If so, start the 60s fade; otherwise they were already in
        // the drawer-only state and we just rerender the list.
        const prevSession = (lastSessions || []).find(
          (s) => s.trainerId === r.trainerId,
        );
        // No previous pin → nothing to fade. Skip.
        if (!prevSession) return;
        // We already wiped pins in drawSessions(); the fade has to be
        // a synthetic pin so the visual position is preserved.
        startGraceFade(r.trainerId, prevSession, r);
      }
    });

    // Garbage-collect any grace entries whose trainer disappeared from
    // the roster entirely (24h window expired between polls).
    for (const tid of Array.from(graceTrainers.keys())) {
      if (!roster.find((r) => r.trainerId === tid)) {
        cancelGrace(tid);
      }
    }

    renderRosterUi(roster, liveIds);
  }

  // ---------------------------------------------------------------------
  // Grace fade: hold an avatar at its last known map position for 60s
  // with a slow opacity fade. After 60s the pin is removed; the drawer
  // entry remains. The animation respects prefers-reduced-motion via the
  // CSS @media query on .live-pavatar.is-grace.
  // ---------------------------------------------------------------------
  function startGraceFade(trainerId, prevSession, rosterEntry) {
    if (!elCardLayer || !map || !window.L) return;
    if (!Number.isFinite(prevSession.latitude) || !Number.isFinite(prevSession.longitude)) {
      return;
    }
    const pin = document.createElement('div');
    pin.className = 'live-pavatar is-grace';
    pin.dataset.lat = String(prevSession.latitude);
    pin.dataset.lng = String(prevSession.longitude);
    pin.dataset.sessionId = prevSession.sessionId || '';
    pin.dataset.trainerId = trainerId;
    pin.style.opacity = '0.85';
    const fullName = [rosterEntry.firstName, rosterEntry.lastName]
      .filter(Boolean).join(' ') || 'Practitioner';
    pin.setAttribute('aria-label', `${fullName} (recently active)`);
    if (rosterEntry.avatarUrl) {
      const img = document.createElement('img');
      img.src = rosterEntry.avatarUrl;
      img.alt = '';
      pin.appendChild(img);
    } else {
      pin.classList.add('is-initials');
      pin.textContent = sessionInitials(rosterEntry.firstName, rosterEntry.lastName);
    }
    elCardLayer.appendChild(pin);
    // Initial position via the map projection.
    const pt = map.latLngToContainerPoint([prevSession.latitude, prevSession.longitude]);
    pin.style.left = `${pt.x}px`;
    pin.style.top = `${pt.y}px`;
    const entry = {
      pin,
      startedAt: Date.now(),
      lastLatLng: { lat: prevSession.latitude, lng: prevSession.longitude },
    };
    graceTrainers.set(trainerId, entry);

    // Schedule the opacity fade to 0 over 60s. CSS transition handles
    // the actual interpolation; we just kick it off on the next frame.
    requestAnimationFrame(() => {
      pin.style.transition = 'opacity 60000ms linear';
      pin.style.opacity = '0';
    });

    // Ensure the global tick is running so we GC the pin after 60s.
    ensureGraceTick();
  }

  function cancelGrace(trainerId) {
    const entry = graceTrainers.get(trainerId);
    if (!entry) return;
    if (entry.pin && entry.pin.parentNode) {
      entry.pin.parentNode.removeChild(entry.pin);
    }
    graceTrainers.delete(trainerId);
    if (graceTrainers.size === 0 && graceTickTimer) {
      window.clearInterval(graceTickTimer);
      graceTickTimer = null;
    }
  }

  function ensureGraceTick() {
    if (graceTickTimer) return;
    graceTickTimer = window.setInterval(() => {
      const now = Date.now();
      for (const [tid, entry] of Array.from(graceTrainers.entries())) {
        if (now - entry.startedAt >= GRACE_DURATION_MS) {
          cancelGrace(tid);
        }
      }
    }, 1000);
  }

  // Reproject grace pins along with live pins on map move/zoom.
  function repositionGracePins() {
    if (!map) return;
    graceTrainers.forEach((entry) => {
      if (!entry || !entry.pin || !entry.lastLatLng) return;
      const pt = map.latLngToContainerPoint([entry.lastLatLng.lat, entry.lastLatLng.lng]);
      entry.pin.style.left = `${pt.x}px`;
      entry.pin.style.top = `${pt.y}px`;
    });
  }

  // ---------------------------------------------------------------------
  // Drawer / pill rendering
  // ---------------------------------------------------------------------
  function renderRosterUi(roster, liveIds) {
    if (!elRosterLayer) return;

    // "Recently active" = in the 24h roster but NOT currently live.
    const recent = roster.filter(
      (r) => !r.currentlyActive && !liveIds.has(r.trainerId),
    );

    // If nothing to surface (no recent + drawer not currently open),
    // wipe the layer cleanly.
    if (recent.length === 0 && !drawerOpen) {
      while (elRosterLayer.firstChild) elRosterLayer.removeChild(elRosterLayer.firstChild);
      elDrawer = null;
      elDrawerPill = null;
      elTimeline = null;
      return;
    }

    // Drawer open path renders the panel + (optionally) the timeline.
    if (drawerOpen) {
      renderDrawerExpanded(recent);
    } else {
      renderDrawerCollapsedPill(recent);
    }
  }

  function renderDrawerCollapsedPill(recent) {
    // Clean slate
    while (elRosterLayer.firstChild) elRosterLayer.removeChild(elRosterLayer.firstChild);
    elDrawer = null;
    elTimeline = null;
    if (recent.length === 0) {
      elDrawerPill = null;
      return;
    }

    // Recent-within-1-hour driver: coral text if at least one entry.
    const oneHourAgo = Date.now() - 3600000;
    const hasFresh = recent.some((r) => {
      const t = Date.parse(r.lastEventAt || '');
      return Number.isFinite(t) && t >= oneHourAgo;
    });

    elDrawerPill = document.createElement('button');
    elDrawerPill.type = 'button';
    elDrawerPill.className = 'live-roster-pill' + (hasFresh ? ' is-recent' : '');
    elDrawerPill.setAttribute(
      'aria-label',
      `${recent.length} recently active in the last 24 hours`,
    );

    const count = document.createElement('div');
    count.className = 'live-roster-pill-count';
    count.textContent = `+${recent.length}`;
    elDrawerPill.appendChild(count);

    const caption = document.createElement('div');
    caption.className = 'live-roster-pill-caption';
    caption.textContent = 'Recent 24h';
    elDrawerPill.appendChild(caption);

    elDrawerPill.addEventListener('click', (evt) => {
      evt.preventDefault();
      evt.stopPropagation();
      openDrawer();
    });

    elRosterLayer.appendChild(elDrawerPill);
  }

  function renderDrawerExpanded(recent) {
    // Wipe the layer and rebuild — cheaper than diffing on every 12s poll.
    while (elRosterLayer.firstChild) elRosterLayer.removeChild(elRosterLayer.firstChild);
    elDrawerPill = null;

    elDrawer = document.createElement('div');
    elDrawer.className = 'live-roster-drawer';
    elDrawer.setAttribute('role', 'dialog');
    elDrawer.setAttribute('aria-label', 'Recently active practitioners (last 24 hours)');

    const header = document.createElement('div');
    header.className = 'live-roster-drawer-header';
    const title = document.createElement('div');
    title.className = 'live-roster-drawer-title';
    title.textContent = 'Recent · 24h';
    header.appendChild(title);
    const closeBtn = document.createElement('button');
    closeBtn.type = 'button';
    closeBtn.className = 'live-roster-drawer-close';
    closeBtn.setAttribute('aria-label', 'Close drawer');
    closeBtn.textContent = '×';
    closeBtn.addEventListener('click', (evt) => {
      evt.preventDefault();
      evt.stopPropagation();
      closeDrawer();
    });
    header.appendChild(closeBtn);
    elDrawer.appendChild(header);

    const list = document.createElement('div');
    list.className = 'live-roster-drawer-list';
    if (recent.length === 0) {
      const empty = document.createElement('div');
      empty.className = 'live-roster-drawer-empty';
      empty.textContent = 'Nobody recorded here in the last 24 hours.';
      list.appendChild(empty);
    } else {
      recent.forEach((r) => list.appendChild(buildRosterRow(r)));
    }
    elDrawer.appendChild(list);

    elRosterLayer.appendChild(elDrawer);

    // Apply dim classes to map + card layer while drawer is open.
    if (elCardLayer) elCardLayer.classList.add('is-drawer-open');
    if (elMap) elMap.classList.add('is-drawer-open');

    // Timeline popover persistence — if the user had a row selected
    // before this re-render, restore it (data may have updated).
    if (selectedTrainerId) {
      const r = recent.find((rr) => rr.trainerId === selectedTrainerId);
      if (r) {
        renderTimeline(r);
      } else {
        // Selection vanished from the roster — clean up.
        selectedTrainerId = null;
        if (elTimeline && elTimeline.parentNode) {
          elTimeline.parentNode.removeChild(elTimeline);
        }
        elTimeline = null;
      }
    }
  }

  function buildRosterRow(r) {
    const row = document.createElement('button');
    row.type = 'button';
    row.className = 'live-roster-row';
    if (selectedTrainerId === r.trainerId) row.classList.add('is-selected');
    row.dataset.trainerId = r.trainerId;

    const fullName = [r.firstName, r.lastName].filter(Boolean).join(' ') || 'Practitioner';
    const minsAgo = minutesSince(r.lastEventAt);
    const captureCount = r.eventCount24h || (r.events || []).length;
    const captureLabel = captureCount === 1 ? '1 capture' : `${captureCount} captures`;

    const avatar = document.createElement('div');
    avatar.className = 'live-roster-row-avatar';
    if (r.avatarUrl) {
      const img = document.createElement('img');
      img.src = r.avatarUrl;
      img.alt = '';
      avatar.appendChild(img);
    } else {
      avatar.textContent = sessionInitials(r.firstName, r.lastName);
    }
    row.appendChild(avatar);

    const meta = document.createElement('div');
    meta.className = 'live-roster-row-meta';
    const name = document.createElement('div');
    name.className = 'live-roster-row-name';
    name.textContent = fullName;
    meta.appendChild(name);
    const sub = document.createElement('div');
    sub.className = 'live-roster-row-sub';
    if (minsAgo !== null && minsAgo < 60) sub.classList.add('is-recent');
    sub.textContent = `${formatMinsAgo(minsAgo)} · ${captureLabel}`;
    meta.appendChild(sub);
    row.appendChild(meta);

    row.addEventListener('click', (evt) => {
      evt.preventDefault();
      evt.stopPropagation();
      selectTrainer(r);
    });

    return row;
  }

  function minutesSince(iso) {
    if (!iso) return null;
    const ms = Date.parse(iso);
    if (!Number.isFinite(ms)) return null;
    return Math.max(0, Math.floor((Date.now() - ms) / 60000));
  }

  function formatMinsAgo(mins) {
    if (mins === null) return 'recently';
    if (mins < 1) return 'just now';
    if (mins < 60) return `${mins}m ago`;
    const h = Math.floor(mins / 60);
    if (h < 24) return `${h}h ago`;
    return `${Math.floor(h / 24)}d ago`;
  }

  function selectTrainer(rosterEntry) {
    selectedTrainerId = rosterEntry.trainerId;
    // Update row selection state.
    if (elDrawer) {
      const rows = elDrawer.querySelectorAll('.live-roster-row');
      rows.forEach((r) => {
        if (r.dataset.trainerId === selectedTrainerId) {
          r.classList.add('is-selected');
        } else {
          r.classList.remove('is-selected');
        }
      });
    }
    renderTimeline(rosterEntry);
  }

  // ---------------------------------------------------------------------
  // Timeline popover (Scene 3)
  // ---------------------------------------------------------------------
  function renderTimeline(rosterEntry) {
    if (!elRosterLayer) return;
    if (elTimeline && elTimeline.parentNode) {
      elTimeline.parentNode.removeChild(elTimeline);
    }
    elTimeline = document.createElement('div');
    elTimeline.className = 'live-roster-timeline';
    elTimeline.setAttribute('role', 'dialog');
    const fullName = [rosterEntry.firstName, rosterEntry.lastName]
      .filter(Boolean).join(' ') || 'Practitioner';
    elTimeline.setAttribute('aria-label', `${fullName} — last 24 hours`);

    // Auto-flip: if the map shell is narrower than ~480px (drawer 220 +
    // timeline 240 + a hair), render the timeline BELOW the drawer
    // instead of beside it.
    if (elMap) {
      const rect = elMap.getBoundingClientRect();
      if (rect.width < 480) elTimeline.classList.add('is-below');
    }

    // Header — avatar + name + subline
    const header = document.createElement('div');
    header.className = 'live-roster-timeline-header';
    const avatar = document.createElement('div');
    avatar.className = 'live-roster-timeline-avatar';
    if (rosterEntry.avatarUrl) {
      const img = document.createElement('img');
      img.src = rosterEntry.avatarUrl;
      img.alt = '';
      avatar.appendChild(img);
    } else {
      avatar.textContent = sessionInitials(rosterEntry.firstName, rosterEntry.lastName);
    }
    header.appendChild(avatar);
    const headerMeta = document.createElement('div');
    headerMeta.style.minWidth = '0';
    const nameEl = document.createElement('div');
    nameEl.className = 'live-roster-timeline-name';
    nameEl.textContent = fullName;
    headerMeta.appendChild(nameEl);
    const subEl = document.createElement('div');
    subEl.className = 'live-roster-timeline-sub';
    const captureCount = rosterEntry.eventCount24h || (rosterEntry.events || []).length;
    subEl.textContent = `Last 24h · ${captureCount === 1 ? '1 capture' : `${captureCount} captures`}`;
    headerMeta.appendChild(subEl);
    header.appendChild(headerMeta);
    elTimeline.appendChild(header);

    // Event list — photos + videos, most-recent first
    const list = document.createElement('div');
    list.className = 'live-roster-timeline-list';
    const events = Array.isArray(rosterEntry.events) ? rosterEntry.events : [];
    if (events.length === 0) {
      const empty = document.createElement('div');
      empty.className = 'live-roster-drawer-empty';
      empty.textContent = 'No captures in the last 24 hours.';
      list.appendChild(empty);
    } else {
      // 2026-05-25 — buildEventRow returns null for non-capture audit
      // kinds (e.g. safe_mode_accepted_empty telemetry rows) which
      // count toward the per-trainer aggregate but don't render a
      // visual dot. Skip nulls to avoid `appendChild(null)`.
      events.forEach((ev) => {
        const row = buildEventRow(ev);
        if (row) list.appendChild(row);
      });
    }
    elTimeline.appendChild(list);

    // Footer actions — Report. Reuses the existing report-modal flow
    // (it expects a session shape; synthesize one from the roster).
    const actions = document.createElement('div');
    actions.className = 'live-roster-timeline-actions';
    const reportBtn = document.createElement('button');
    reportBtn.type = 'button';
    reportBtn.className = 'live-roster-timeline-report';
    reportBtn.textContent = `Report ${fullName.split(' ')[0] || 'practitioner'}`;
    reportBtn.addEventListener('click', (evt) => {
      evt.preventDefault();
      evt.stopPropagation();
      // No active session id available; the modal handles the missing
      // sessionId by surfacing the report against the practitioner's
      // most-recent event instead. Report flow remains unchanged.
      const fakeSession = {
        sessionId: '', // server-side rate-limit treats empty as missing
        firstName: rosterEntry.firstName,
        lastName: rosterEntry.lastName,
      };
      openReportModal(fakeSession, practiceContactCached);
    });
    actions.appendChild(reportBtn);
    elTimeline.appendChild(actions);

    elRosterLayer.appendChild(elTimeline);
  }

  function buildEventRow(ev) {
    const row = document.createElement('div');
    row.className = 'live-roster-event';
    const dot = document.createElement('div');
    // 2026-05-25 — only photo/video events render as visual dots in
    // the drawer. The get_premises_active_roster RPC also returns
    // `safe_mode_accepted_empty` audit rows (added via the new
    // record_safe_mode_capture_event RPC); those are practitioner-
    // facing telemetry, not bystander-transparency events, so they
    // get rolled into the per-trainer event count without a visual
    // dot. We default to the photo class for anything unknown so a
    // future kind doesn't crash the drawer.
    const isVideo = ev.kind === 'video';
    const isCapture = ev.kind === 'photo' || ev.kind === 'video';
    if (!isCapture) {
      // Skip the row entirely — the trainer's event_count_24h already
      // includes it in the aggregate; we just don't render a dot for
      // non-capture audit kinds.
      return null;
    }
    dot.className = 'live-roster-event-dot ' + (isVideo ? 'is-video' : 'is-photo');
    row.appendChild(dot);

    const label = document.createElement('div');
    label.className = 'live-roster-event-label';
    const time = document.createElement('div');
    time.className = 'live-roster-event-time';

    const startMs = Date.parse(ev.started_at || '');
    const endMs = ev.ended_at ? Date.parse(ev.ended_at) : null;
    if (isVideo && Number.isFinite(startMs) && Number.isFinite(endMs)) {
      const durSecs = Math.max(0, Math.round((endMs - startMs) / 1000));
      label.textContent = `Video (${formatDurationSecs(durSecs)})`;
      time.textContent = `${formatClock(startMs)} → ${formatClock(endMs)}`;
    } else if (isVideo && Number.isFinite(startMs)) {
      label.textContent = 'Video';
      time.textContent = formatClock(startMs);
    } else {
      label.textContent = 'Photo';
      time.textContent = Number.isFinite(startMs) ? formatClock(startMs) : '';
    }

    row.appendChild(label);
    row.appendChild(time);
    return row;
  }

  function formatDurationSecs(secs) {
    if (!Number.isFinite(secs) || secs < 0) return '0s';
    if (secs < 60) return `${secs}s`;
    const m = Math.floor(secs / 60);
    const s = secs % 60;
    if (s === 0) return `${m}m`;
    return `${m}m ${s}s`;
  }

  function formatClock(ms) {
    if (!Number.isFinite(ms)) return '';
    try {
      const d = new Date(ms);
      const hh = String(d.getHours()).padStart(2, '0');
      const mm = String(d.getMinutes()).padStart(2, '0');
      return `${hh}:${mm}`;
    } catch (_) {
      return '';
    }
  }

  // ---------------------------------------------------------------------
  // Drawer open / close machinery
  // ---------------------------------------------------------------------
  function openDrawer() {
    if (drawerOpen) return;
    drawerOpen = true;
    selectedTrainerId = null;
    // Close any session popover that's open — the drawer + popover
    // would otherwise visually clash.
    closePopover();
    // Render with the current snapshot — poll loop will refresh.
    const liveIds = new Set((lastSessions || []).map((s) => s.trainerId).filter(Boolean));
    renderRosterUi(lastRoster, liveIds);

    // Outside-tap + ESC dismissal. Defer the outside-tap by a tick so
    // the click that opened us doesn't immediately close us.
    setTimeout(() => {
      drawerOutsideTapHandler = (evt) => {
        if (!elDrawer) return;
        if (elDrawer.contains(evt.target)) return;
        if (elTimeline && elTimeline.contains(evt.target)) return;
        // Tapping outside both the drawer + the timeline (anywhere on
        // the map or beyond) closes the drawer.
        closeDrawer();
      };
      document.addEventListener('mousedown', drawerOutsideTapHandler, true);
      document.addEventListener('touchstart', drawerOutsideTapHandler, true);
    }, 0);
    drawerEscKeyHandler = (evt) => {
      if (evt.key === 'Escape') closeDrawer();
    };
    document.addEventListener('keydown', drawerEscKeyHandler);
  }

  function closeDrawer() {
    if (!drawerOpen) return;
    drawerOpen = false;
    selectedTrainerId = null;
    if (elCardLayer) elCardLayer.classList.remove('is-drawer-open');
    if (elMap) elMap.classList.remove('is-drawer-open');
    if (drawerOutsideTapHandler) {
      document.removeEventListener('mousedown', drawerOutsideTapHandler, true);
      document.removeEventListener('touchstart', drawerOutsideTapHandler, true);
      drawerOutsideTapHandler = null;
    }
    if (drawerEscKeyHandler) {
      document.removeEventListener('keydown', drawerEscKeyHandler);
      drawerEscKeyHandler = null;
    }
    // Repaint as collapsed pill (or wipe entirely).
    const liveIds = new Set((lastSessions || []).map((s) => s.trainerId).filter(Boolean));
    renderRosterUi(lastRoster, liveIds);
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
