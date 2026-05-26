/**
 * me-data.js — consumer-side /me/data per-practice consent panel (Wave 2)
 * =====================================================================
 *
 * Renders one card per practice the calling consumer is linked to. Each
 * card carries six toggles whose values come from
 * `get_effective_consent` (merged consumer override over practitioner
 * proxy, with line_drawing pinned true). Flipping a toggle calls
 * `set_my_consent(practice_client_id, {<key>: <bool>})` — single-key
 * patch — so the consumer never accidentally writes a stale value for
 * a key they didn't touch.
 *
 * Master "Stop all stats" switch in the footer flips
 * analytics_allowed=false across every linked practice in one tap. It's
 * a sequence of set_my_consent calls, one per relationship. On any
 * failure we surface a toast but keep going — the per-card toggle will
 * reflect the true state on next reload.
 *
 * Data-access: ALL Supabase I/O goes through window.HomefitApi.
 */

(function () {
  'use strict';

  // ===========================  Bootstrap  ===============================

  // Six known keys + their UI mapping. Order = render order.
  const CONSENT_KEYS = [
    {
      key:      'line_drawing',
      label:    'Line drawing',
      desc:     "Always on — doesn't identify you",
      locked:   true,
      glyph:    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5">'
              + '<circle cx="12" cy="6" r="2.4" />'
              + '<path d="M12 8.5v6M12 11l-4 1M12 11l4 1M12 14.5l-3 4M12 14.5l3 4" />'
              + '</svg>',
    },
    {
      key:      'grayscale',
      label:    'Black & white video',
      desc:     'Your real video, no colour',
      locked:   false,
      glyph:    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor">'
              + '<circle cx="12" cy="12" r="8" stroke-width="1.6" />'
              + '<path d="M12 4a8 8 0 0 0 0 16z" fill="currentColor" />'
              + '</svg>',
    },
    {
      key:      'original',
      label:    'Original video',
      desc:     'Full colour, exactly as captured',
      locked:   false,
      glyph:    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6">'
              + '<rect x="3" y="6" width="14" height="12" rx="2" />'
              + '<path d="M17 10l4-2v8l-4-2z" />'
              + '</svg>',
    },
    {
      key:      'avatar',
      label:    'Profile photo',
      desc:     'Your face as a small avatar',
      locked:   false,
      glyph:    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6">'
              + '<circle cx="12" cy="9" r="3.5" />'
              + '<path d="M5 20c1.5-3.5 4-5 7-5s5.5 1.5 7 5" />'
              + '</svg>',
    },
    {
      // Live DB key is `safe_mode_face_recognition` (Safe Mode v2 wave).
      // The design doc names it `face_recognition` in prose; we use the
      // live key here so the RPC patch matches column shape.
      key:      'safe_mode_face_recognition',
      label:    'Face fingerprint',
      desc:     'Tell you apart from others on screen',
      locked:   false,
      glyph:    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6">'
              + '<circle cx="12" cy="11" r="3" />'
              + '<path d="M9 15.5c1 1 5 1 6 0" />'
              + '<path d="M4 7V5h2M20 7V5h-2M4 17v2h2M20 17v2h-2" />'
              + '</svg>',
    },
    {
      key:      'analytics_allowed',
      label:    'Workout stats',
      desc:     'Help your practitioner see what’s working',
      locked:   false,
      glyph:    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6">'
              + '<path d="M4 20h16" />'
              + '<path d="M7 16v-4M12 16V8M17 16v-7" />'
              + '</svg>',
    },
  ];

  let _relationships = [];
  let _toastTimer = null;

  document.addEventListener('DOMContentLoaded', boot);

  async function boot() {
    if (!window.HomefitApi || typeof window.HomefitApi.restoreConsumerSession !== 'function') {
      showError('HomefitApi not loaded.');
      return;
    }

    window.HomefitApi.restoreConsumerSession();

    if (!window.HomefitApi.isConsumerSignedIn()) {
      // Anonymous on /me/data → redirect to /me. Preserve no query state
      // (this surface has no plan-claim context).
      try { window.location.replace('/me'); } catch (_) {
        showError('You need to sign in to view your data preferences.');
      }
      return;
    }

    try {
      const result = await window.HomefitApi.getMyRelationships();
      if (!result || !Array.isArray(result.relationships)) {
        showError('We couldn’t load your linked practices.');
        return;
      }
      _relationships = result.relationships;
      render();
    } catch (err) {
      try { console.error('[me/data] boot failed:', err); } catch (_) {}
      showError('We hit a problem loading your preferences.');
    }
  }

  // ===========================  Render  ==================================

  function render() {
    const $loading = document.getElementById('md-loading');
    const $page    = document.getElementById('md-page');
    if ($loading) $loading.hidden = true;
    if ($page) $page.hidden = false;

    const $cards = document.getElementById('md-practice-cards');
    const $empty = document.getElementById('md-empty');
    const $footer = document.getElementById('md-footer-card');
    if (!$cards) return;

    $cards.innerHTML = '';
    if (_relationships.length === 0) {
      if ($empty) $empty.hidden = false;
      if ($footer) $footer.hidden = true;
      return;
    }
    if ($empty) $empty.hidden = true;
    if ($footer) $footer.hidden = false;

    _relationships.forEach((rel) => {
      const $card = buildPracticeCard(rel);
      if ($card) $cards.appendChild($card);
    });

    bindMasterRow();
    refreshMasterState();
  }

  function buildPracticeCard(rel) {
    if (!rel || !rel.practice_client_id) return null;
    const consent = rel.effective_consent || {};

    const $card = document.createElement('div');
    $card.className = 'md-practice-card';
    $card.setAttribute('data-practice-client-id', rel.practice_client_id);

    // Head
    const $head = document.createElement('div');
    $head.className = 'md-prac-head';

    const $avatar = document.createElement('div');
    $avatar.className = 'md-prac-avatar';
    $avatar.textContent = practitionerInitials(rel);
    $head.appendChild($avatar);

    const $meta = document.createElement('div');
    $meta.className = 'md-prac-meta';

    const $name = document.createElement('div');
    $name.className = 'md-prac-name';
    $name.textContent = practitionerDisplayName(rel);
    $meta.appendChild($name);

    const $practice = document.createElement('div');
    $practice.className = 'md-prac-practice';
    $practice.textContent = rel.practice_name || 'Practice';
    $meta.appendChild($practice);

    $head.appendChild($meta);
    $card.appendChild($head);

    // Toggle rows
    const $toggles = document.createElement('div');
    $toggles.className = 'md-toggles';
    CONSENT_KEYS.forEach((spec) => {
      const $row = buildToggleRow(rel, spec, consent);
      if ($row) $toggles.appendChild($row);
    });
    $card.appendChild($toggles);

    // Plan-count footer
    const planCount = Number(rel.plan_count) || 0;
    const $count = document.createElement('div');
    $count.className = 'md-plan-count';
    if (isStrictest(rel)) $count.classList.add('is-strict');
    $count.innerHTML =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" aria-hidden="true">'
      + '<rect x="5" y="3" width="14" height="18" rx="2" />'
      + '<path d="M8.5 8h7M8.5 12h7M8.5 16h4" />'
      + '</svg>'
      + escapeHtml(planCount + ' plan' + (planCount === 1 ? '' : 's') + ' from this practice')
      + (isStrictest(rel) ? ' — strictest setting' : '');
    $card.appendChild($count);

    return $card;
  }

  function buildToggleRow(rel, spec, consent) {
    const $row = document.createElement('div');
    $row.className = 'md-toggle-row';

    const $glyph = document.createElement('div');
    $glyph.className = 'md-toggle-glyph';
    $glyph.innerHTML = spec.glyph;
    $row.appendChild($glyph);

    const $body = document.createElement('div');
    $body.className = 'md-toggle-body';

    const $name = document.createElement('div');
    $name.className = 'md-toggle-name';
    $name.textContent = spec.label;
    if (spec.locked) {
      const $lock = document.createElement('span');
      $lock.className = 'md-lock-glyph';
      $lock.setAttribute('title', "Always on — de-identified by the pipeline");
      $lock.innerHTML =
        '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">'
        + '<rect x="5" y="11" width="14" height="9" rx="2" />'
        + '<path d="M8 11V8a4 4 0 0 1 8 0v3" />'
        + '</svg>';
      $name.appendChild(document.createTextNode(' '));
      $name.appendChild($lock);
    }
    $body.appendChild($name);

    const $desc = document.createElement('div');
    $desc.className = 'md-toggle-desc';
    $desc.textContent = spec.desc;
    $body.appendChild($desc);

    $row.appendChild($body);

    const isOn = !!consent[spec.key];

    const $pill = document.createElement('button');
    $pill.type = 'button';
    $pill.className = 'md-pill'
      + (spec.locked ? ' is-locked' : '')
      + (isOn && !spec.locked ? ' is-on' : '');
    $pill.setAttribute('role', 'switch');
    $pill.setAttribute('aria-checked', isOn ? 'true' : 'false');
    $pill.setAttribute('aria-label', spec.label);
    $pill.dataset.key = spec.key;
    $pill.dataset.practiceClientId = rel.practice_client_id;

    const $thumb = document.createElement('span');
    $thumb.className = 'md-pill-thumb';
    $pill.appendChild($thumb);

    if (!spec.locked) {
      $pill.addEventListener('click', () => onToggleClick($pill, spec.key, !isOn));
    }
    $row.appendChild($pill);
    return $row;
  }

  // ===========================  Toggle interactions  =====================

  async function onToggleClick($pill, key, nextValue) {
    if (!$pill || $pill.classList.contains('is-busy')) return;
    const practiceClientId = $pill.dataset.practiceClientId;
    if (!practiceClientId) return;

    $pill.classList.add('is-busy');

    // Optimistic flip — set the UI now, then call the RPC. On failure,
    // revert.
    const wasOn = $pill.classList.contains('is-on');
    setPillState($pill, nextValue);

    const patch = {};
    patch[key] = !!nextValue;
    const result = await window.HomefitApi.setMyConsent(practiceClientId, patch);

    $pill.classList.remove('is-busy');

    if (!result || !result.ok) {
      // Revert the optimistic change.
      setPillState($pill, wasOn);
      const reason = (result && result.reason) || 'unknown';
      showToast('Couldn’t save (' + reason + ')');
      try { console.warn('[me/data] set_my_consent failed:', result); } catch (_) {}
      return;
    }

    // Reflect the server's authoritative `after` consent on our local
    // cache so the master row + future renders stay in sync.
    const after = result.after || {};
    syncRelationshipConsent(practiceClientId, after);

    showToast('Saved');
    refreshMasterState();
  }

  function setPillState($pill, on) {
    if (!$pill) return;
    if (on) {
      $pill.classList.add('is-on');
      $pill.setAttribute('aria-checked', 'true');
    } else {
      $pill.classList.remove('is-on');
      $pill.setAttribute('aria-checked', 'false');
    }
  }

  function syncRelationshipConsent(practiceClientId, after) {
    if (!practiceClientId || !after) return;
    _relationships = _relationships.map((r) => {
      if (r && r.practice_client_id === practiceClientId) {
        return Object.assign({}, r, {
          effective_consent: Object.assign({}, r.effective_consent || {}, after),
        });
      }
      return r;
    });
  }

  // ===========================  Master switch  ===========================

  function bindMasterRow() {
    const $btn = document.querySelector('[data-control="master-analytics-off"]');
    if (!$btn || $btn.dataset.bound === '1') return;
    $btn.dataset.bound = '1';
    $btn.addEventListener('click', onMasterClick);
  }

  function refreshMasterState() {
    // The master pill is shown as "on" (i.e. "stop all stats is engaged")
    // when analytics_allowed is OFF on every linked practice.
    const $btn = document.querySelector('[data-control="master-analytics-off"]');
    if (!$btn) return;
    if (_relationships.length === 0) {
      setPillState($btn, false);
      return;
    }
    const allOff = _relationships.every(
      (r) => !((r.effective_consent || {}).analytics_allowed),
    );
    setPillState($btn, allOff);
  }

  async function onMasterClick(event) {
    const $btn = event.currentTarget;
    if (!$btn || $btn.classList.contains('is-busy')) return;
    if (_relationships.length === 0) return;

    // Toggle target: if any relationship currently has analytics on, we
    // turn them all off. If all are already off, we DO NOT turn them all
    // on — that would silently flip a sensitive setting on multiple
    // practices in one tap. The footer copy explicitly frames this as
    // "Stop all stats", a one-way switch toward off.
    const anyOn = _relationships.some(
      (r) => (r.effective_consent || {}).analytics_allowed,
    );
    if (!anyOn) {
      showToast('Already off everywhere');
      return;
    }

    $btn.classList.add('is-busy');

    let failures = 0;
    for (const rel of _relationships) {
      if (!rel || !rel.practice_client_id) continue;
      if (!((rel.effective_consent || {}).analytics_allowed)) continue;
      const result = await window.HomefitApi.setMyConsent(
        rel.practice_client_id,
        { analytics_allowed: false },
      );
      if (!result || !result.ok) {
        failures += 1;
        continue;
      }
      // Sync local cache for that relationship.
      syncRelationshipConsent(rel.practice_client_id, result.after || {});
      // Reflect in the per-card pill if rendered.
      const $cardPill = document.querySelector(
        '[data-key="analytics_allowed"][data-practice-client-id="' + rel.practice_client_id + '"]',
      );
      if ($cardPill) setPillState($cardPill, false);
    }

    $btn.classList.remove('is-busy');
    refreshMasterState();
    if (failures > 0) {
      showToast('Saved (' + failures + ' could not update)');
    } else {
      showToast('Stats off everywhere');
    }
  }

  // ===========================  Helpers  =================================

  function isStrictest(rel) {
    if (!_relationships || _relationships.length <= 1) return false;
    const score = (r) => {
      const c = r && r.effective_consent || {};
      // Higher = more open. Compare against this consumer's other rels.
      let s = 0;
      if (c.grayscale) s++;
      if (c.original) s++;
      if (c.avatar) s++;
      if (c.safe_mode_face_recognition) s++;
      if (c.analytics_allowed) s++;
      return s;
    };
    const target = score(rel);
    return _relationships.every((r) => score(r) >= target)
        && _relationships.some((r) => score(r) > target);
  }

  function practitionerInitials(rel) {
    if (!rel) return '??';
    if (rel.practitioner_email) {
      return emailInitials(rel.practitioner_email);
    }
    if (rel.practice_name) {
      const tokens = String(rel.practice_name).split(/\s+/).filter(Boolean);
      if (tokens.length >= 2) return (tokens[0][0] + tokens[1][0]).toUpperCase();
      if (tokens.length === 1 && tokens[0].length >= 2) return tokens[0].substring(0, 2).toUpperCase();
    }
    return '??';
  }

  function emailInitials(email) {
    if (!email || typeof email !== 'string') return '??';
    const local = email.split('@')[0] || '';
    const tokens = local.split(/[._\-+]/).filter(Boolean);
    if (tokens.length >= 2) {
      return (tokens[0][0] + tokens[1][0]).toUpperCase();
    }
    if (tokens.length === 1 && tokens[0].length >= 2) {
      return tokens[0].substring(0, 2).toUpperCase();
    }
    if (tokens.length === 1) {
      return (tokens[0][0] + 'X').toUpperCase();
    }
    return '??';
  }

  function practitionerDisplayName(rel) {
    if (!rel) return 'Your practitioner';
    if (rel.practitioner_email) {
      const email = rel.practitioner_email;
      const local = email.split('@')[0] || '';
      const tokens = local.split(/[._\-+]/).filter(Boolean);
      if (tokens.length === 0) return 'Your practitioner';
      return tokens
        .map((t) => t.charAt(0).toUpperCase() + t.slice(1).toLowerCase())
        .join(' ');
    }
    return 'Your practitioner';
  }

  function showToast(message) {
    let $toast = document.querySelector('.md-toast');
    if (!$toast) {
      $toast = document.createElement('div');
      $toast.className = 'md-toast';
      document.body.appendChild($toast);
    }
    $toast.textContent = message;
    requestAnimationFrame(() => {
      $toast.classList.add('is-visible');
    });
    if (_toastTimer) clearTimeout(_toastTimer);
    _toastTimer = setTimeout(() => {
      if ($toast) $toast.classList.remove('is-visible');
    }, 1800);
  }

  function showError(message) {
    const $loading = document.getElementById('md-loading');
    const $page    = document.getElementById('md-page');
    const $err     = document.getElementById('md-error');
    const $errText = document.getElementById('md-error-text');
    if ($loading) $loading.hidden = true;
    if ($page) $page.hidden = true;
    if ($errText && message) $errText.textContent = message;
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
