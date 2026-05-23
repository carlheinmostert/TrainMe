/**
 * homefit.studio — Live transparency page (`/v/{slug}/{premises}/now`)
 *
 * Safe Mode Transparency — Phase B (2026-05-22) + Live-view cosmetic
 * + functional pass (2026-05-23, items 15-19 of stack file).
 *
 * Polls `get_live_sessions(practiceSlug, premisesSlug)` every 12 seconds
 * and renders:
 *   - The practice's enforced-Safe-Mode polygon on a Mapbox satellite
 *     snapshot (with graceful fallback to a polygon-only SVG when the
 *     snapshot URL is NULL — e.g. MAPBOX_TOKEN secret missing).
 *   - Active practitioner cards floating at their last reported GPS
 *     position, projected over the polygon bounding box.
 *   - A sage "You are here" dot anchored to the viewer's own
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
  const elMapGrid = document.getElementById('live-map-grid');
  const elMapSvg = document.getElementById('live-map-svg');
  const elMapSnapshot = document.getElementById('live-map-snapshot');
  const elCardLayer = document.getElementById('live-card-layer');
  const elReportModal = document.getElementById('live-report-modal');
  const elTopLogo = document.getElementById('live-top-logo');
  const elFooterLogo = document.getElementById('live-footer-logo');
  const elHeroH1 = document.getElementById('live-hero-h1');
  const elHeroTitle = document.getElementById('live-hero-title');

  let pollTimer = null;
  let viewerPos = null; // { lat, lng } — never leaves the browser.
  let lastBounds = null; // last computed polygon bounds for the "You" dot
  let lastUpdatedAt = 0;
  let metaTicker = null;
  let lastSnapshotUrl = null;

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
  // letters of that token. Aspect rules mirror the LogoUploader (item 1):
  // max-width/max-height caps + object-fit: contain.
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
    // Clear children + classes so we can swap between modes safely.
    while (elPracticeMark.firstChild) elPracticeMark.removeChild(elPracticeMark.firstChild);
    elPracticeMark.classList.remove('has-logo');
    if (logoUrl) {
      const img = document.createElement('img');
      img.src = logoUrl;
      img.alt = '';
      img.loading = 'lazy';
      // On image error, fall back to initials so we never show a broken
      // image icon. Race-free because we read .has-logo at swap time.
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
      // Left ghost pills.
      `<rect x="0" y="${y(2.75)}" width="2.5" height="1.5" rx="0.5" fill="${ghostOuter}"/>` +
      `<rect x="4" y="${y(2.45)}" width="3.5" height="2.1" rx="0.7" fill="${ghostMid}"/>` +
      `<rect x="9" y="${y(2.15)}" width="4.5" height="2.7" rx="0.9" fill="${ghostInner}"/>` +
      // Coral tint band.
      `<rect x="14.5" y="${y(1)}" width="12.5" height="8.5" rx="1.2" fill="${coral}" opacity="0.15"/>` +
      // 2×2 circuit.
      `<rect x="15" y="${y(2)}" width="5" height="3" rx="1" fill="${coral}"/>` +
      `<rect x="15" y="${y(6.5)}" width="5" height="3" rx="1" fill="${coral}"/>` +
      `<rect x="21.5" y="${y(2)}" width="5" height="3" rx="1" fill="${coral}"/>` +
      `<rect x="21.5" y="${y(6.5)}" width="5" height="3" rx="1" fill="${coral}"/>` +
      // Rest pill.
      `<rect x="28" y="${y(2)}" width="5" height="3" rx="1" fill="${sage}"/>` +
      // Right ghost pills.
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
  //   N = 0 → "Nobody is recording right now"
  //   N = 1 → "1 person is recording right now"
  //   N ≥ 2 → "{N} people are recording right now"
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
  // Polygon / projection math (unchanged from prior version)
  // ---------------------------------------------------------------------
  function computeBounds(premises) {
    let minLat = Infinity, maxLat = -Infinity;
    let minLng = Infinity, maxLng = -Infinity;
    premises.forEach((p) => {
      (p.polygon || []).forEach((pt) => {
        if (!Array.isArray(pt) || pt.length < 2) return;
        const lng = Number(pt[0]);
        const lat = Number(pt[1]);
        if (!Number.isFinite(lat) || !Number.isFinite(lng)) return;
        if (lat < minLat) minLat = lat;
        if (lat > maxLat) maxLat = lat;
        if (lng < minLng) minLng = lng;
        if (lng > maxLng) maxLng = lng;
      });
    });
    if (!Number.isFinite(minLat) || !Number.isFinite(minLng)) return null;
    const padLat = ((maxLat - minLat) || 0.0005) * 0.08;
    const padLng = ((maxLng - minLng) || 0.0005) * 0.08;
    return {
      minLat: minLat - padLat,
      maxLat: maxLat + padLat,
      minLng: minLng - padLng,
      maxLng: maxLng + padLng,
    };
  }

  function project(bounds, lat, lng) {
    if (!bounds) return null;
    const x = ((lng - bounds.minLng) / (bounds.maxLng - bounds.minLng)) * 100;
    const y = ((bounds.maxLat - lat) / (bounds.maxLat - bounds.minLat)) * 125;
    return { x, y };
  }

  function drawPolygons(bounds, premises) {
    while (elMapSvg.firstChild) elMapSvg.removeChild(elMapSvg.firstChild);
    if (!bounds) return;
    premises.forEach((p) => {
      const ring = (p.polygon || []).map((pt) => project(bounds, pt[1], pt[0])).filter(Boolean);
      if (ring.length < 3) return;
      const pointsAttr = ring.map((pt) => `${pt.x.toFixed(2)},${pt.y.toFixed(2)}`).join(' ');
      const poly = document.createElementNS('http://www.w3.org/2000/svg', 'polygon');
      poly.setAttribute('points', pointsAttr);
      poly.setAttribute('fill', 'rgba(255, 107, 53, 0.06)');
      poly.setAttribute('stroke', '#FF6B35');
      poly.setAttribute('stroke-width', '0.6');
      poly.setAttribute('stroke-dasharray', '2 1.5');
      poly.setAttribute('vector-effect', 'non-scaling-stroke');
      elMapSvg.appendChild(poly);
    });
  }

  // ---------------------------------------------------------------------
  // Item 19 — paint the satellite snapshot when present; fall back
  // gracefully to the polygon-only grid SVG when NULL or on image load
  // failure.
  // ---------------------------------------------------------------------
  function paintSnapshot(url) {
    if (!elMapGrid || !elMapSnapshot) return;
    if (!url) {
      elMapGrid.classList.remove('has-snapshot');
      elMapSnapshot.classList.remove('is-loaded');
      elMapSnapshot.hidden = true;
      elMapSnapshot.src = '';
      lastSnapshotUrl = null;
      return;
    }
    if (lastSnapshotUrl === url) return; // already showing it.
    lastSnapshotUrl = url;
    elMapSnapshot.hidden = false;
    elMapSnapshot.classList.remove('is-loaded');
    elMapSnapshot.onload = () => {
      elMapGrid.classList.add('has-snapshot');
      elMapSnapshot.classList.add('is-loaded');
    };
    elMapSnapshot.onerror = () => {
      // Mapbox upload / network failure → silent fallback to polygon-only.
      elMapGrid.classList.remove('has-snapshot');
      elMapSnapshot.classList.remove('is-loaded');
      elMapSnapshot.hidden = true;
      lastSnapshotUrl = null;
    };
    elMapSnapshot.src = url;
  }

  function drawSessions(bounds, sessions, practiceContact) {
    // Clear all but the persistent "You" dot.
    Array.from(elCardLayer.children).forEach((child) => {
      if (!child.classList || !child.classList.contains('live-you')) {
        elCardLayer.removeChild(child);
      }
    });
    sessions.forEach((s) => {
      const card = document.createElement('div');
      card.className = 'live-pcard';
      const proj = (Number.isFinite(s.latitude) && Number.isFinite(s.longitude))
        ? project(bounds, s.latitude, s.longitude)
        : null;
      const cx = proj ? proj.x : 50;
      const cy = proj ? proj.y : 62;
      card.style.left = `${cx}%`;
      card.style.top = `${(cy / 125) * 100}%`;

      const avatar = document.createElement('div');
      avatar.className = 'live-pcard-avatar';
      if (s.avatarUrl) {
        const img = document.createElement('img');
        img.src = s.avatarUrl;
        img.alt = '';
        avatar.appendChild(img);
      } else {
        avatar.textContent = sessionInitials(s.firstName, s.lastName);
      }

      const info = document.createElement('div');
      info.style.minWidth = '0';

      const name = document.createElement('div');
      name.className = 'live-pcard-name';
      name.textContent = [s.firstName, s.lastName].filter(Boolean).join(' ') || 'Practitioner';
      info.appendChild(name);

      const meta = document.createElement('div');
      meta.className = 'live-pcard-meta';
      const dur = formatDuration(s.startedAt);
      const zone = s.premisesName ? s.premisesName : (s.manualMode ? 'Manual' : 'In zone');
      meta.textContent = `${dur} · ${zone}`;
      info.appendChild(meta);

      const report = document.createElement('button');
      report.className = 'live-pcard-report';
      report.type = 'button';
      report.textContent = 'Report';
      report.addEventListener('click', () => openReportModal(s, practiceContact));

      card.appendChild(avatar);
      card.appendChild(info);
      card.appendChild(report);
      elCardLayer.appendChild(card);
    });
  }

  function sessionInitials(first, last) {
    const a = (first || '').trim().charAt(0).toUpperCase();
    const b = (last || '').trim().charAt(0).toUpperCase();
    return (a + b) || '·';
  }

  function drawViewerDot() {
    Array.from(elCardLayer.querySelectorAll('.live-you')).forEach((n) => n.remove());
    if (!viewerPos || !lastBounds) return;
    const proj = project(lastBounds, viewerPos.lat, viewerPos.lng);
    if (!proj) return;
    if (proj.x < -10 || proj.x > 110 || proj.y < -10 || proj.y > 135) return;
    const dot = document.createElement('div');
    dot.className = 'live-you';
    dot.title = 'You are here';
    dot.style.left = `${proj.x}%`;
    dot.style.top = `${(proj.y / 125) * 100}%`;
    elCardLayer.appendChild(dot);
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

    // Snapshot URL — try the premises[0] copy first (more accurate when
    // future variants land per-premises), fall back to the top-level
    // copy from the head row.
    const snapshotUrl =
      (data.premises && data.premises[0] && data.premises[0].snapshotUrl) ||
      data.premisesSnapshotUrl ||
      null;
    paintSnapshot(snapshotUrl);

    lastBounds = computeBounds(data.premises);
    drawPolygons(lastBounds, data.premises);

    if (!practiceContact) {
      practiceContact = await fetchPracticeContact(slugs.practiceSlug);
    }

    drawSessions(lastBounds, data.sessions, practiceContact);
    paintHero(data.sessions.length);
    drawViewerDot();
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
          drawViewerDot();
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
