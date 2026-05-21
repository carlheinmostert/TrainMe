/**
 * homefit.studio — Public profile page (`/v/{slug}`)
 *
 * Renders a practice's public profile from `get_practice_profile(slug)`.
 * Shows the practice name + logo + blurb + a list of premises (name +
 * address + map link). No practitioner names exposed. The report button
 * surfaces a modal that posts to `report_premises`.
 *
 * Profile data is anonymous-readable when the practice has opted into
 * the directory (`public_profile_listed=true`). Unlisted slugs return
 * null from the RPC — surfaces as "Practice not found" so we don't
 * confirm an unlisted slug's existence.
 */
(function () {
  'use strict';

  const elLoading = document.getElementById('v-loading');
  const elNotFound = document.getElementById('v-not-found');
  const elProfile = document.getElementById('v-profile');
  const elName = document.getElementById('v-name');
  const elBlurb = document.getElementById('v-blurb');
  const elLogo = document.getElementById('v-logo');
  const elPremisesList = document.getElementById('v-premises-list');
  const elReportBtn = document.getElementById('v-report-btn');

  const elReportModal = document.getElementById('v-report-modal');
  const elReportDismiss = document.getElementById('v-report-dismiss');
  const elReportCancel = document.getElementById('v-report-cancel');
  const elReportSubmit = document.getElementById('v-report-submit');
  const elReportPremises = document.getElementById('v-report-premises');
  const elReportReason = document.getElementById('v-report-reason');
  const elReportError = document.getElementById('v-report-error');

  let currentProfile = null;

  function show(el) { if (el) el.hidden = false; }
  function hide(el) { if (el) el.hidden = true; }

  function getSlug() {
    const m = window.location.pathname.match(/^\/v\/([a-zA-Z0-9-]+)/);
    return m ? m[1].toLowerCase() : '';
  }

  function renderProfile(profile) {
    currentProfile = profile;
    elName.textContent = profile.practiceName || 'Practice';
    if (profile.blurb) {
      elBlurb.textContent = profile.blurb;
      elBlurb.hidden = false;
    } else {
      elBlurb.hidden = true;
    }

    if (profile.logoUrl) {
      const img = document.createElement('img');
      img.src = profile.logoUrl;
      img.alt = '';
      img.referrerPolicy = 'no-referrer';
      elLogo.innerHTML = '';
      elLogo.appendChild(img);
      elLogo.classList.add('v-logo--has-image');
    } else {
      // Fallback: render initials in a coral square.
      const initials = (profile.practiceName || 'H')
        .split(/\s+/)
        .map((w) => w.charAt(0))
        .filter(Boolean)
        .slice(0, 2)
        .join('')
        .toUpperCase();
      elLogo.textContent = initials || 'H';
      elLogo.classList.remove('v-logo--has-image');
    }

    elPremisesList.innerHTML = '';
    const premises = Array.isArray(profile.premises) ? profile.premises : [];

    if (premises.length === 0) {
      const empty = document.createElement('li');
      empty.className = 'v-premises-empty';
      empty.textContent = 'No premises listed yet.';
      elPremisesList.appendChild(empty);
    } else {
      premises.forEach((p) => {
        const li = document.createElement('li');
        li.className = 'v-premises-item';

        const head = document.createElement('div');
        head.className = 'v-premises-head';
        const name = document.createElement('span');
        name.className = 'v-premises-name';
        name.textContent = p.name || 'Unnamed';
        head.appendChild(name);

        if (p.safe_mode_enforced) {
          const badge = document.createElement('span');
          badge.className = 'v-safe-badge';
          badge.textContent = 'Safe Mode';
          head.appendChild(badge);
        }

        li.appendChild(head);

        if (p.address) {
          const addr = document.createElement('div');
          addr.className = 'v-premises-address';
          addr.textContent = p.address;
          li.appendChild(addr);
        }

        if (typeof p.centroid_lat === 'number' && typeof p.centroid_lng === 'number') {
          const map = document.createElement('a');
          map.className = 'v-premises-map';
          map.href = 'https://www.openstreetmap.org/?mlat=' + encodeURIComponent(p.centroid_lat) + '&mlon=' + encodeURIComponent(p.centroid_lng) + '#map=17/' + encodeURIComponent(p.centroid_lat) + '/' + encodeURIComponent(p.centroid_lng);
          map.target = '_blank';
          map.rel = 'noopener noreferrer';
          map.textContent = 'Open in maps →';
          li.appendChild(map);
        }

        elPremisesList.appendChild(li);
      });
    }

    // Populate the report modal premises picker.
    elReportPremises.innerHTML = '';
    const allOption = document.createElement('option');
    allOption.value = premises[0]?.id ?? '';
    allOption.textContent = premises.length === 0
      ? '— No premises to report —'
      : premises.length === 1
        ? premises[0].name
        : 'Pick a premises…';
    elReportPremises.appendChild(allOption);
    if (premises.length > 1) {
      premises.forEach((p) => {
        const opt = document.createElement('option');
        opt.value = p.id;
        opt.textContent = p.name;
        elReportPremises.appendChild(opt);
      });
    }

    elReportBtn.disabled = premises.length === 0;

    document.title = (profile.practiceName || 'Practice') + ' — homefit.studio';
  }

  function openReportModal() {
    elReportError.hidden = true;
    elReportError.textContent = '';
    elReportReason.value = '';
    show(elReportModal);
    setTimeout(() => elReportReason.focus(), 50);
  }

  function closeReportModal() {
    hide(elReportModal);
  }

  async function submitReport() {
    const reason = (elReportReason.value || '').trim();
    if (reason.length === 0) {
      elReportError.textContent = 'Add a reason before sending.';
      elReportError.hidden = false;
      return;
    }
    const premisesId = elReportPremises.value;
    if (!premisesId) {
      elReportError.textContent = 'Pick which premises to report.';
      elReportError.hidden = false;
      return;
    }
    elReportSubmit.disabled = true;
    elReportSubmit.textContent = 'Sending…';
    try {
      const id = await window.HomefitApi.reportPremises(premisesId, reason);
      if (id) {
        elReportSubmit.textContent = 'Sent ✓';
        setTimeout(closeReportModal, 1200);
      } else {
        elReportError.textContent = 'Send failed. Try again later.';
        elReportError.hidden = false;
      }
    } catch (e) {
      elReportError.textContent = 'Send failed. Try again later.';
      elReportError.hidden = false;
    } finally {
      setTimeout(() => {
        elReportSubmit.disabled = false;
        elReportSubmit.textContent = 'Send report';
      }, 1500);
    }
  }

  async function init() {
    const slug = getSlug();
    if (!slug) {
      hide(elLoading);
      show(elNotFound);
      return;
    }

    try {
      const profile = await window.HomefitApi.getPracticeProfile(slug);
      if (!profile) {
        hide(elLoading);
        show(elNotFound);
        return;
      }
      renderProfile(profile);
      hide(elLoading);
      show(elProfile);
    } catch (_) {
      hide(elLoading);
      show(elNotFound);
    }
  }

  elReportBtn.addEventListener('click', openReportModal);
  elReportDismiss.addEventListener('click', closeReportModal);
  elReportCancel.addEventListener('click', closeReportModal);
  elReportSubmit.addEventListener('click', submitReport);

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
