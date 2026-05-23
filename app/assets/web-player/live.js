/**
 * homefit.studio — Live transparency page (`/v/{slug}/now`)
 *
 * Safe Mode Transparency — Phase B (2026-05-22). See
 * docs/specs/2026-05-22-safe-mode-transparency.md.
 *
 * Polls `get_live_sessions(slug)` every 12 seconds and renders:
 *   - The practice's enforced-Safe-Mode polygons as an inline SVG.
 *   - Active practitioner cards floating at their last reported GPS
 *     position, projected over the polygon bounding box.
 *   - A sage "You are here" dot anchored to the viewer's own
 *     geolocation (browser-only — never sent to our server).
 *
 * No external map provider, no Mapbox, no Leaflet — pure SVG over a
 * neutral grid background. The polygon is the surface; the cards
 * are the content.
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
  const elMapSvg = document.getElementById('live-map-svg');
  const elCardLayer = document.getElementById('live-card-layer');
  const elEmpty = document.getElementById('live-empty');
  const elReportModal = document.getElementById('live-report-modal');
  const elTopLogo = document.getElementById('live-top-logo');
  const elFooterLogo = document.getElementById('live-footer-logo');

  let pollTimer = null;
  let viewerPos = null; // { lat, lng } — never leaves the browser.
  let lastBounds = null; // last computed polygon bounds for the "You" dot
  let lastUpdatedAt = 0;
  let metaTicker = null;

  function slugsFromPath() {
    // New per-premises shape: /v/{practice-slug}/{premises-slug}/now.
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

  function initials(first, last) {
    const a = (first || '').trim().charAt(0).toUpperCase();
    const b = (last || '').trim().charAt(0).toUpperCase();
    return (a + b) || '·';
  }

  // ---------------------------------------------------------------------
  // Polygon / projection math
  // ---------------------------------------------------------------------
  // Pure equirectangular projection over the bounding box of all premises
  // polygons. 4:5 aspect-ratio container (viewBox 0..100 × 0..125). The
  // bounds are padded by 8% on every side so polygons + cards never
  // brush the container edge.
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
    // Pad by 8% of the span so polygons never touch the edge.
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
    // Flip lat because SVG y grows downward.
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
      // Anchor: midpoint if no coords yet (rare; initial second before
      // first heartbeat).
      const cx = proj ? proj.x : 50;
      const cy = proj ? proj.y : 62;
      // Convert SVG-coord space (0..100 × 0..125) to percentage of the
      // map-grid div. Same proportions since both layers share the
      // 4:5 box.
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
        avatar.textContent = initials(s.firstName, s.lastName);
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
    if (sessions.length === 0) {
      show(elEmpty);
    } else {
      hide(elEmpty);
    }
  }

  function drawViewerDot() {
    // Remove old, then re-add if we have bounds + a position.
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

  // ---------------------------------------------------------------------
  // Practice header + logos
  // ---------------------------------------------------------------------
  // Inline matrix logo — matches the canonical 48×9.5 viewBox geometry
  // used by buildHomefitLogoSvg() in app.js. Inlined here so live.html
  // does not have to pull in app.js (separate bundle by design).
  function matrixLogoSvg() {
    return ''
      + '<svg viewBox="0 0 48 9.5" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="homefit.studio">'
      + '<rect x="0" y="2" width="5" height="3" rx="1" fill="#9CA3AF" opacity="0.55"/>'
      + '<rect x="0" y="6.5" width="5" height="3" rx="1" fill="#9CA3AF" opacity="0.55"/>'
      + '<rect x="6.5" y="2" width="5" height="3" rx="1" fill="#6B7280" opacity="0.6"/>'
      + '<rect x="6.5" y="6.5" width="5" height="3" rx="1" fill="#6B7280" opacity="0.6"/>'
      + '<rect x="14.5" y="1" width="12.5" height="8.5" rx="1.2" fill="#FF6B35" opacity="0.15"/>'
      + '<rect x="15" y="2" width="5" height="3" rx="1" fill="#FF6B35"/>'
      + '<rect x="15" y="6.5" width="5" height="3" rx="1" fill="#FF6B35"/>'
      + '<rect x="21.5" y="2" width="5" height="3" rx="1" fill="#FF6B35"/>'
      + '<rect x="21.5" y="6.5" width="5" height="3" rx="1" fill="#FF6B35"/>'
      + '<rect x="28" y="2" width="5" height="3" rx="1" fill="#86EFAC"/>'
      + '<rect x="34.5" y="2" width="5" height="3" rx="1" fill="#6B7280" opacity="0.6"/>'
      + '<rect x="34.5" y="6.5" width="5" height="3" rx="1" fill="#6B7280" opacity="0.6"/>'
      + '<rect x="41" y="2" width="5" height="3" rx="1" fill="#9CA3AF" opacity="0.55"/>'
      + '<rect x="41" y="6.5" width="5" height="3" rx="1" fill="#9CA3AF" opacity="0.55"/>'
      + '</svg>';
  }

  function paintLogos() {
    elTopLogo.innerHTML = matrixLogoSvg();
    elFooterLogo.innerHTML = matrixLogoSvg();
  }

  function paintHeader(data) {
    elPracticeName.textContent = data.practiceName || 'Practice';
    const firstPremises = data.premises[0];
    elPracticeLoc.textContent = firstPremises ? firstPremises.name : '';
    const mark = (data.practiceName || '·').charAt(0).toUpperCase();
    elPracticeMark.textContent = mark;
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
    // First successful response: hydrate the page.
    hide(elLoading);
    hide(elNotFound);
    show(elContent);

    paintHeader(data);

    lastBounds = computeBounds(data.premises);
    drawPolygons(lastBounds, data.premises);

    // Sample of the practice's listed contact email/whatsapp for the
    // report modal — fetched once via the public practice profile.
    if (!practiceContact) {
      practiceContact = await fetchPracticeContact(slugs.practiceSlug);
    }

    drawSessions(lastBounds, data.sessions, practiceContact);
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
    // Safe Mode Transparency — Phase D (2026-05-22).
    // Posts to `report_session` RPC. The RPC's transactional pg_net
    // hook fires the `safe-mode-report` edge function which emails
    // the practice's listed contact via Resend.
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

  // Reporter fingerprint — localStorage-backed UUID. Generated once
  // per visitor + reused for all reports from this device.
  function ensureFingerprint() {
    try {
      const key = 'homefit.fingerprint';
      let fp = window.localStorage.getItem(key);
      if (!fp) {
        // RFC4122-ish; crypto.randomUUID is available in modern browsers,
        // fall back to Math.random for older surfaces.
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
  // Expose for Phase D — report_session uses this.
  window.__homefitLiveFingerprint = ensureFingerprint();

  // ---------------------------------------------------------------------
  // Viewer geolocation (browser-only)
  // ---------------------------------------------------------------------
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

  // ---------------------------------------------------------------------
  // Boot
  // ---------------------------------------------------------------------
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
