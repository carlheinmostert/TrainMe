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

  const BRAND_HEX_RE = /^#[0-9A-Fa-f]{6}$/;
  const HTTPS_RE = /^https?:\/\//;

  function show(el) { if (el) el.hidden = false; }
  function hide(el) { if (el) el.hidden = true; }

  function escapeHtml(s) {
    const div = document.createElement('div');
    div.textContent = String(s == null ? '' : s);
    return div.innerHTML;
  }

  // Public Profile v2 — cascade the practice brand color into the same
  // CSS variables the rest of the player reads from. Mirror of
  // applyPracticeBranding(plan) in app.js but sourced from the profile
  // payload rather than a plan payload.
  //
  // Validation up-front via strict #RRGGBB regex; invalid / missing
  // values leave the homefit-coral defaults in styles.css :root.
  function applyProfileBranding(profile) {
    const root = document.documentElement;
    if (!root || !root.style) return;
    const raw = profile && typeof profile === 'object' ? profile.brandColor : null;
    if (typeof raw !== 'string' || !BRAND_HEX_RE.test(raw)) {
      root.style.removeProperty('--c-brand');
      root.style.removeProperty('--c-brand-strong');
      root.style.removeProperty('--c-brand-soft');
      root.style.removeProperty('--c-brand-tint-bg');
      root.style.removeProperty('--c-brand-tint-border');
      return;
    }
    const hex = raw.toUpperCase();
    const r = parseInt(hex.slice(1, 3), 16);
    const g = parseInt(hex.slice(3, 5), 16);
    const b = parseInt(hex.slice(5, 7), 16);
    const triplet = r + ', ' + g + ', ' + b;
    root.style.setProperty('--c-brand', hex);
    root.style.setProperty('--c-brand-strong', hex);
    root.style.setProperty('--c-brand-soft', 'rgba(' + triplet + ', 0.12)');
    root.style.setProperty('--c-brand-tint-bg', 'rgba(' + triplet + ', 0.12)');
    root.style.setProperty('--c-brand-tint-border', 'rgba(' + triplet + ', 0.30)');
  }

  function hydrateExtras(profile) {
    // Tagline (max 60 chars, DB-enforced).
    if (profile.tagline) {
      const el = document.getElementById('hero-tagline');
      el.textContent = profile.tagline;
      el.hidden = false;
    }

    // Hero CTA — points at contact_website. https:// validated.
    if (profile.contactWebsite && HTTPS_RE.test(profile.contactWebsite)) {
      const cta = document.getElementById('hero-cta');
      const display = profile.contactWebsite.replace(/^https?:\/\/(www\.)?/, '');
      cta.textContent = 'Visit ' + display + ' →';
      cta.href = profile.contactWebsite;
      cta.hidden = false;
    }

    // Specialties chips.
    const specialties = Array.isArray(profile.specialties) ? profile.specialties : [];
    if (specialties.length > 0) {
      const list = document.getElementById('specialties-chips');
      list.innerHTML = '';
      specialties.forEach((s) => {
        if (typeof s !== 'string' || s.length === 0) return;
        const span = document.createElement('span');
        span.className = 'v-chip';
        span.textContent = s;
        list.appendChild(span);
      });
      document.getElementById('specialties-section').hidden = false;
    }

    // Contact list — email + WhatsApp. Website is the hero CTA above,
    // never duplicated here.
    const contacts = [];
    if (profile.contactEmail) {
      contacts.push({
        label: 'Email',
        value: profile.contactEmail,
        href: 'mailto:' + profile.contactEmail,
      });
    }
    if (profile.contactWhatsapp) {
      const digits = profile.contactWhatsapp.replace(/[^\d]/g, '');
      if (digits.length > 0) {
        contacts.push({
          label: 'WhatsApp',
          value: profile.contactWhatsapp,
          href: 'https://wa.me/' + digits,
        });
      }
    }
    if (contacts.length > 0) {
      const list = document.getElementById('contact-list');
      list.innerHTML = '';
      contacts.forEach((c) => {
        const a = document.createElement('a');
        a.className = 'v-contact-row';
        a.href = c.href;
        if (c.href.startsWith('http')) {
          a.target = '_blank';
          a.rel = 'noopener noreferrer';
        }
        const lbl = document.createElement('div');
        lbl.className = 'v-contact-label';
        lbl.textContent = c.label;
        const val = document.createElement('div');
        val.className = 'v-contact-value';
        val.textContent = c.value;
        const wrap = document.createElement('div');
        wrap.appendChild(lbl);
        wrap.appendChild(val);
        a.appendChild(wrap);
        list.appendChild(a);
      });
      document.getElementById('contact-section').hidden = false;
    }
  }

  async function hydrateTeam(practiceId) {
    if (!practiceId) return;
    // Q-H2 fix (synthesis 2026-05-21): wrap the RPC call in try/catch so a
    // network drop / 5xx / RPC contract break doesn't propagate and kill
    // the whole /v/{slug} page (which gets caught by the outer catch and
    // mis-rendered as "Practice not found" — see Q-H3 too). The team
    // section is hideable; if hydration fails we keep it hidden and log
    // for diagnosis, rather than showing a broken / empty grid or
    // misrepresenting the whole profile.
    let members;
    try {
      members = await window.HomefitApi.getPracticePublicMembers(practiceId);
    } catch (e) {
      // eslint-disable-next-line no-console
      console.error('[hydrateTeam] RPC failed:', e);
      const section = document.getElementById('team-section');
      if (section) section.hidden = true;
      return;
    }
    if (!Array.isArray(members) || members.length === 0) {
      const section = document.getElementById('team-section');
      if (section) section.hidden = true;
      return;
    }
    const grid = document.getElementById('team-grid');
    grid.innerHTML = '';
    members.forEach((m) => {
      const name = m.displayName || 'Practitioner';
      const initials = name
        .split(/\s+/)
        .map((w) => (w.charAt(0) || '').toUpperCase())
        .filter(Boolean)
        .slice(0, 2)
        .join('') || '?';
      const card = document.createElement('div');
      card.className = 'v-team-card';

      const avatar = document.createElement('div');
      avatar.className = 'v-team-avatar';
      avatar.textContent = initials;

      const nameEl = document.createElement('div');
      nameEl.className = 'v-team-name';
      nameEl.textContent = name;

      const role = document.createElement('div');
      role.className = 'v-team-role';
      role.textContent = m.role === 'owner' ? 'Practice owner' : 'Practitioner';

      card.appendChild(avatar);
      card.appendChild(nameEl);
      card.appendChild(role);
      grid.appendChild(card);
    });
    document.getElementById('team-section').hidden = false;
  }

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
      // Image carries semantic meaning via the surrounding heading; the
      // logo container itself is decorative.
      elLogo.setAttribute('aria-hidden', 'true');
      elLogo.removeAttribute('aria-label');
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
      // F-H5 fix (synthesis 2026-05-21): the initials fallback is the
      // only visual identification when there's no logo asset. Tag it
      // for screen readers so users on AT don't hit two opaque letters.
      const labelName = profile.practiceName || 'Practice';
      elLogo.setAttribute('aria-label', labelName + ' logo');
      elLogo.setAttribute('aria-hidden', 'false');
      elLogo.setAttribute('role', 'img');
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

  function showLoadError() {
    hide(elLoading);
    hide(elNotFound);
    const el = document.getElementById('v-load-error');
    if (el) el.hidden = false;
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
        // True not-found — 404 from server or empty rows.
        hide(elLoading);
        show(elNotFound);
        return;
      }
      // Apply brand color cascade BEFORE render so the initial paint
      // is already tinted (no FOUC flash from coral to the practice
      // brand color).
      applyProfileBranding(profile);
      renderProfile(profile);
      hydrateExtras(profile);
      hide(elLoading);
      show(elProfile);
      // Team cards are an additional RPC call — fire-and-forget so the
      // main profile is visible the moment its data lands. The Team
      // section stays hidden until rows arrive.
      hydrateTeam(profile.practiceId);
    } catch (e) {
      // Q-H3 fix (synthesis 2026-05-21): distinguish transient errors
      // (network / 5xx / parse) from genuine not-found. Transient gets
      // a retry UI; not-found (null return) was already handled above.
      // eslint-disable-next-line no-console
      console.error('[v/init] profile load failed:', e, 'status=', e && e.status);
      if (e && e.transient) {
        showLoadError();
      } else {
        // Unknown / non-transient error (auth misconfig, malformed
        // slug accepted by regex, etc.) — fall through to not-found
        // rather than retry, since retrying won't help.
        hide(elLoading);
        show(elNotFound);
      }
    }
  }

  // Wire up the retry button on the load-error UI.
  const elLoadRetry = document.getElementById('v-load-retry');
  if (elLoadRetry) {
    elLoadRetry.addEventListener('click', function () {
      const el = document.getElementById('v-load-error');
      if (el) el.hidden = true;
      show(elLoading);
      init();
    });
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
