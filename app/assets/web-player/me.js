/**
 * me.js — consumer-side /me account page (Wave 2)
 * =====================================================================
 *
 * Two states orchestrated from one file:
 *
 *   1. Signed-out — magic-link claim form. If the page arrived with
 *      ?claim=<planId>, an "attaching banner" surfaces and the eventual
 *      sign-in click-through pre-stamps the redirect with that planId
 *      so the post-magic-link callback can call claim_plan(planId).
 *
 *   2. Signed-in — My Workouts list. Calls list_my_plans + lays out one
 *      card per (plan × published-artifact-kind) row.
 *
 * Flow:
 *
 *   - boot()                   resolves the session via window.HomefitApi
 *                              .restoreConsumerSession + window.location
 *                              .hash parsing.
 *   - If signed in AND ?claim=<planId> on URL → call claimPlan(planId),
 *     drop the claim param, render My Workouts.
 *   - If signed in (no claim)  render My Workouts.
 *   - If not signed in         render the claim/sign-in form.
 *
 * Data-access: ALL Supabase I/O goes through window.HomefitApi.
 * Per feedback_no_direct_db_access.md.
 */

(function () {
  'use strict';

  // ===========================  Bootstrap  ===============================

  document.addEventListener('DOMContentLoaded', boot);

  async function boot() {
    if (!window.HomefitApi || typeof window.HomefitApi.restoreConsumerSession !== 'function') {
      showError('HomefitApi not loaded.');
      return;
    }

    try {
      // Hash-fragment magic-link landing OR localStorage restore.
      const token = window.HomefitApi.restoreConsumerSession();

      // ?claim=<planId> — present when the consumer arrived from a /h/
      // or /p/ surface that asked "save this plan." We carry it through
      // sign-in via emailRedirectTo so the post-magic-link callback URL
      // still has it.
      const params = new URLSearchParams(window.location.search || '');
      const claimPlanId = params.get('claim');

      if (token && window.HomefitApi.isConsumerSignedIn()) {
        // Signed in. If we have a pending claim, attach it now then
        // refresh the URL so a reload doesn't re-attempt.
        if (claimPlanId) {
          await attemptClaim(claimPlanId);
          // Strip the ?claim= so a refresh doesn't double-fire.
          try {
            const url = new URL(window.location.href);
            url.searchParams.delete('claim');
            history.replaceState({}, document.title, url.toString());
          } catch (_) { /* best-effort */ }
        }
        await renderSignedInState();
        return;
      }

      // Not signed in — show the claim/sign-in card.
      renderClaimState(claimPlanId);
    } catch (err) {
      try { console.error('[me] boot failed:', err); } catch (_) {}
      showError('We hit a problem loading your account.');
    }
  }

  // ===========================  Signed-out: claim form  ==================

  function renderClaimState(claimPlanId) {
    hideAllPages();
    const $page = document.getElementById('me-claim');
    if (!$page) return;
    $page.hidden = false;

    if (claimPlanId) {
      const $banner = document.getElementById('me-attaching');
      if ($banner) $banner.hidden = false;
    }

    bindClaimForm(claimPlanId);
  }

  function bindClaimForm(claimPlanId) {
    const $form   = document.getElementById('me-claim-form');
    const $email  = document.getElementById('me-email');
    const $btn    = document.getElementById('me-claim-submit');
    const $status = document.getElementById('me-claim-status');
    if (!$form || !$email || !$btn) return;

    // Prevent re-binding on a state toggle.
    if ($form.dataset.bound === '1') return;
    $form.dataset.bound = '1';

    $form.addEventListener('submit', async (event) => {
      event.preventDefault();
      const email = ($email.value || '').trim();
      if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
        showStatus('Please enter a valid email address.', 'is-error');
        return;
      }
      setBusy($btn, true);
      hideStatus();
      const result = await window.HomefitApi.signInWithMagicLink(email, {
        claimPlanId: claimPlanId || null,
      });
      setBusy($btn, false);
      if (result && result.ok) {
        showSentState(email);
      } else {
        showStatus(
          'We couldn’t send the sign-in link. Please try again in a moment.',
          'is-error',
        );
        try { console.warn('[me] signInWithMagicLink failed:', result); } catch (_) {}
      }
    });
  }

  function setBusy($btn, busy) {
    if (!$btn) return;
    $btn.disabled = !!busy;
    $btn.textContent = busy ? 'Sending…' : 'Send me a link';
  }

  function showStatus(message, cls) {
    const $status = document.getElementById('me-claim-status');
    if (!$status) return;
    $status.hidden = false;
    $status.textContent = message;
    $status.classList.remove('is-error', 'is-info');
    if (cls) $status.classList.add(cls);
  }

  function hideStatus() {
    const $status = document.getElementById('me-claim-status');
    if ($status) {
      $status.hidden = true;
      $status.textContent = '';
    }
  }

  function showSentState(email) {
    hideAllPages();
    const $sent = document.getElementById('me-sent');
    const $sentEmail = document.getElementById('me-sent-email');
    if ($sentEmail) $sentEmail.textContent = email;
    if ($sent) $sent.hidden = false;

    const $resend = document.getElementById('me-sent-resend');
    if ($resend) {
      $resend.addEventListener('click', () => {
        // Re-show the claim form. Keep the URL ?claim=<planId> if present.
        const params = new URLSearchParams(window.location.search || '');
        const claimPlanId = params.get('claim');
        renderClaimState(claimPlanId);
      }, { once: true });
    }
  }

  // ===========================  Claim attempt  ===========================

  async function attemptClaim(planId) {
    if (!planId) return;
    const result = await window.HomefitApi.claimPlan(planId);
    if (!result || !result.ok) {
      // Quiet failure — the My Workouts list will simply not have this
      // plan if the claim failed. We log so the cause is visible in
      // devtools without surfacing a misleading error to the consumer
      // (the most common cause is `no_client_link` for a legacy / self-
      // trainer plan, which is genuinely not claimable).
      try { console.warn('[me] claim failed:', result); } catch (_) {}
    }
  }

  // ===========================  Signed-in: My Workouts  ==================

  async function renderSignedInState() {
    hideAllPages();
    const $page = document.getElementById('me-list');
    if (!$page) return;
    $page.hidden = false;

    bindSignedInEvents();

    const result = await window.HomefitApi.getMyPlans();
    if (!result) {
      // Could not load — show empty rather than a hard error; the consumer
      // can still hit Settings or sign out.
      renderEmpty();
      return;
    }

    const plans = Array.isArray(result.plans) ? result.plans : [];
    // Best-effort fetch of relationships purely for the settings sub-label.
    const relResult = await window.HomefitApi.getMyRelationships();
    const practitionerCount = (relResult && Array.isArray(relResult.relationships))
      ? new Set(relResult.relationships
          .map((r) => r.practitioner_user_id || r.practice_id)
          .filter(Boolean)
        ).size
      : 0;
    updateSettingsSubLabel(practitionerCount);
    updateAvatar(plans, relResult);

    if (plans.length === 0) {
      renderEmpty();
      return;
    }

    const $list = document.getElementById('me-plans-list');
    if (!$list) return;
    $list.innerHTML = '';
    plans.forEach((row) => {
      const $card = buildPlanCard(row);
      if ($card) $list.appendChild($card);
    });
  }

  function renderEmpty() {
    const $empty = document.getElementById('me-empty');
    const $list  = document.getElementById('me-plans-list');
    if ($empty) $empty.hidden = false;
    if ($list) $list.innerHTML = '';
  }

  function bindSignedInEvents() {
    const $signout = document.getElementById('me-signout-btn');
    if ($signout && !$signout.dataset.bound) {
      $signout.dataset.bound = '1';
      $signout.addEventListener('click', async () => {
        await window.HomefitApi.signOutConsumer();
        // After sign-out land back on the claim/sign-in form.
        const params = new URLSearchParams(window.location.search || '');
        const claimPlanId = params.get('claim');
        renderClaimState(claimPlanId);
      });
    }
  }

  function updateSettingsSubLabel(count) {
    const $sub = document.getElementById('me-settings-sub');
    if (!$sub) return;
    if (count === 0) {
      $sub.innerHTML = '&middot; your data';
    } else {
      $sub.innerHTML = '&middot; ' + count + ' practitioner' + (count === 1 ? '' : 's') + ' linked';
    }
  }

  function updateAvatar(plans, relResult) {
    // Best-effort: use the email from any plan row to derive initials.
    // The consumer's own email isn't returned by the RPCs; we fall back
    // to "ME" if nothing else is available.
    const $av = document.getElementById('me-avatar');
    if (!$av) return;
    let initials = 'ME';
    let title    = 'Signed in';
    try {
      // Pull the email out of the cached session blob if present.
      const raw = localStorage.getItem('homefit.consumer.session.v1');
      if (raw) {
        const blob = JSON.parse(raw);
        const at = blob && blob.access_token;
        if (at && typeof at === 'string') {
          // JWT payload is the middle segment.
          const parts = at.split('.');
          if (parts.length === 3) {
            const json = JSON.parse(atob(parts[1].replace(/-/g, '+').replace(/_/g, '/')));
            const email = json && (json.email || (json.user_metadata && json.user_metadata.email));
            if (email) {
              title = email;
              const local = String(email).split('@')[0] || '';
              const tokens = local.split(/[._\-+]/).filter(Boolean);
              if (tokens.length >= 2) {
                initials = (tokens[0][0] + tokens[1][0]).toUpperCase();
              } else if (tokens.length === 1 && tokens[0].length >= 2) {
                initials = tokens[0].substring(0, 2).toUpperCase();
              } else if (tokens.length === 1) {
                initials = (tokens[0][0] + 'X').toUpperCase();
              }
            }
          }
        }
      }
    } catch (_) {
      // JWT parsing failed — leave the placeholder initials.
    }
    $av.textContent = initials;
    $av.setAttribute('title', title);
    $av.setAttribute('aria-label', 'Signed in: ' + title);
  }

  function buildPlanCard(row) {
    if (!row || !row.plan_id || !row.kind) return null;
    const kind = String(row.kind);
    // Only the kinds the consumer can actually open today. Wave 1+2 ship
    // plan_url + handout; future kinds (reel etc.) become tap-targets once
    // their player surfaces exist.
    const kindLabel = kindToLabel(kind);
    if (!kindLabel) return null;

    const href = kindToHref(kind, row.plan_id);
    const $card = document.createElement('a');
    $card.className = 'me-plan-card';
    $card.href = href;
    $card.setAttribute('role', 'link');

    const $top = document.createElement('div');
    $top.className = 'me-card-top';

    const $glyph = document.createElement('div');
    $glyph.className = 'me-kind-glyph' + (kind === 'handout' ? ' is-handout' : '');
    $glyph.innerHTML = kindToGlyphSvg(kind);
    $top.appendChild($glyph);

    const $meta = document.createElement('div');
    $meta.className = 'me-card-meta';

    const $kind = document.createElement('p');
    $kind.className = 'me-card-kind';
    $kind.textContent = kindLabel;
    $meta.appendChild($kind);

    const $title = document.createElement('h3');
    $title.className = 'me-card-title';
    $title.textContent = row.plan_title || 'Workout plan';
    $meta.appendChild($title);

    const $sub = document.createElement('p');
    $sub.className = 'me-card-sub';
    $sub.innerHTML = buildSubLine(row);
    $meta.appendChild($sub);

    $top.appendChild($meta);

    const $chev = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    $chev.setAttribute('class', 'me-chev');
    $chev.setAttribute('viewBox', '0 0 24 24');
    $chev.setAttribute('fill', 'none');
    $chev.setAttribute('stroke', 'currentColor');
    $chev.setAttribute('stroke-width', '2');
    $chev.setAttribute('stroke-linecap', 'round');
    $chev.setAttribute('stroke-linejoin', 'round');
    $chev.setAttribute('aria-hidden', 'true');
    $chev.innerHTML = '<polyline points="9 6 15 12 9 18" />';
    $top.appendChild($chev);

    $card.appendChild($top);

    const $prov = buildProvenance(row);
    if ($prov) $card.appendChild($prov);

    return $card;
  }

  function buildSubLine(row) {
    const parts = [];
    const exerciseCount = Number(row.exercise_count);
    if (Number.isFinite(exerciseCount) && exerciseCount > 0) {
      parts.push(exerciseCount + ' exercise' + (exerciseCount === 1 ? '' : 's'));
    }
    const updated = row.published_at || row.last_published_at || null;
    if (updated) {
      parts.push('updated ' + relativeTime(new Date(updated)));
    } else if (row.claimed_at) {
      parts.push('saved ' + relativeTime(new Date(row.claimed_at)));
    }
    return parts.map((p, i) => i === 0 ? escapeHtml(p) : '<span class="me-dot"></span>' + escapeHtml(p)).join('');
  }

  function buildProvenance(row) {
    if (!row.practitioner_email && !row.practice_name) return null;
    const $prov = document.createElement('div');
    $prov.className = 'me-provenance';

    const $av = document.createElement('div');
    $av.className = 'me-prov-avatar';
    $av.textContent = emailInitials(row.practitioner_email);
    $prov.appendChild($av);

    const $text = document.createElement('div');
    $text.className = 'me-prov-text';
    const who = practitionerDisplayName(row.practitioner_email);
    const practice = row.practice_name || '';
    const html = [
      'from ',
      who ? '<span class="me-prov-who">' + escapeHtml(who) + '</span>' : '',
      practice ? ' <span class="me-prov-practice">&middot; ' + escapeHtml(practice) + '</span>' : '',
    ].join('');
    $text.innerHTML = html;
    $prov.appendChild($text);

    const $dot = document.createElement('div');
    $dot.className = 'me-live-dot';
    $dot.setAttribute('aria-label', 'live-linked');
    $prov.appendChild($dot);

    return $prov;
  }

  function kindToLabel(kind) {
    switch (kind) {
      case 'plan_url': return 'Workout player';
      case 'handout':  return 'Workout handout';
      // Roadmap kinds — surface them generically so future migrations
      // don't need a JS bump to land. The href will fall back to a
      // disabled card if no route exists yet.
      case 'poster':   return 'Workout poster';
      case 'reel':     return 'Workout reel';
      case 'ai_reel':  return 'AI reel';
      case 'calendar': return 'Calendar';
      default:         return null;
    }
  }

  function kindToHref(kind, planId) {
    switch (kind) {
      case 'plan_url': return '/p/' + encodeURIComponent(planId);
      case 'handout':  return '/h/' + encodeURIComponent(planId);
      default:         return '/h/' + encodeURIComponent(planId); // Sensible fallback
    }
  }

  function kindToGlyphSvg(kind) {
    if (kind === 'handout') {
      return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">'
        + '<path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z" />'
        + '<polyline points="14 3 14 8 19 8" />'
        + '<line x1="8" y1="13" x2="16" y2="13" />'
        + '<line x1="8" y1="17" x2="13" y2="17" />'
        + '</svg>';
    }
    // Default — workout-player play glyph.
    return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">'
      + '<circle cx="12" cy="12" r="9" />'
      + '<polygon points="10 8 16 12 10 16 10 8" fill="currentColor" stroke="none" />'
      + '</svg>';
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

  function practitionerDisplayName(email) {
    // No display_name in the RPC today — best-effort from the email local
    // part. e.g. "margaret.vorster@cape.health" -> "Margaret Vorster".
    if (!email || typeof email !== 'string') return 'your practitioner';
    const local = email.split('@')[0] || '';
    const tokens = local.split(/[._\-+]/).filter(Boolean);
    if (tokens.length === 0) return 'your practitioner';
    return tokens
      .map((t) => t.charAt(0).toUpperCase() + t.slice(1).toLowerCase())
      .join(' ');
  }

  function relativeTime(date) {
    if (!(date instanceof Date) || isNaN(date.getTime())) return 'recently';
    const seconds = Math.max(0, Math.floor((Date.now() - date.getTime()) / 1000));
    if (seconds < 60)      return 'just now';
    if (seconds < 3600)    return Math.floor(seconds / 60) + ' min ago';
    if (seconds < 86400)   return Math.floor(seconds / 3600) + ' hr ago';
    if (seconds < 604800)  return Math.floor(seconds / 86400) + ' day' + (Math.floor(seconds / 86400) === 1 ? '' : 's') + ' ago';
    if (seconds < 2592000) return Math.floor(seconds / 604800) + ' week' + (Math.floor(seconds / 604800) === 1 ? '' : 's') + ' ago';
    return date.toLocaleDateString();
  }

  // ===========================  Misc UI  =================================

  function hideAllPages() {
    ['me-loading', 'me-claim', 'me-list', 'me-sent', 'me-error']
      .forEach((id) => {
        const $el = document.getElementById(id);
        if ($el) $el.hidden = true;
      });
  }

  function showError(message) {
    hideAllPages();
    const $err  = document.getElementById('me-error');
    const $text = document.getElementById('me-error-text');
    if ($text && message) $text.textContent = message;
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
