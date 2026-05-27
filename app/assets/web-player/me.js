/**
 * me.js — consumer-side /me account page
 * =====================================================================
 *
 * Two states orchestrated from one file:
 *
 *   1. Signed-out — magic-link claim form. If the page arrived with
 *      ?claim=<planId>, an "attaching banner" surfaces and the eventual
 *      sign-in click-through pre-stamps the redirect with that planId
 *      so the post-magic-link callback can call claim_plan(planId).
 *
 *   2. Signed-in — My Workouts list. Calls list_my_plans and groups the
 *      response into bundles (one bundle per plan_id) rendered as fanned
 *      card decks. Wave 6 (artifact-system, 2026-05-27) — the flat list
 *      retired; sibling artifacts (plan_url + handout for the same plan)
 *      collapse into one deck the consumer can flip through.
 *
 *      For owner bundles (viewer's user-id matches the bundle's
 *      practitioner_user_id), a "Use as template for a client" CTA
 *      renders below the deck and fires the
 *      `studio.homefit.app://template?session_id={planId}` deep-link.
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
 *
 * No share button anywhere — re-distribution flows through Studio only.
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
    if (!$form || !$email || !$btn) return;

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

    const consumerUserId = result.consumer_user_id || null;
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

    // Bundle by plan_id. Each plan can have multiple artifact rows
    // (plan_url + handout today; reel/poster/etc. in the future); we
    // collapse them into one deck per plan. Recency = newest of any
    // sibling artifact's published_at.
    const bundles = groupByPlanId(plans);
    bundles.forEach((bundle) => {
      const $bundle = buildPlanBundle(bundle, consumerUserId);
      if ($bundle) $list.appendChild($bundle);
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
    const $av = document.getElementById('me-avatar');
    if (!$av) return;
    let initials = 'ME';
    let title    = 'Signed in';
    try {
      const raw = localStorage.getItem('homefit.consumer.session.v1');
      if (raw) {
        const blob = JSON.parse(raw);
        const at = blob && blob.access_token;
        if (at && typeof at === 'string') {
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

  // ===========================  Bundle grouping  =========================

  /**
   * Collapse the flat (plan × kind) row list into one bundle per plan_id.
   * Each bundle preserves the order of its artifact rows as they came
   * back from the RPC (the RPC sorts by published_at desc, so the most
   * recent artifact for that plan lands at the front of the deck).
   *
   * Returns an array of objects:
   *   { planId, planTitle, practitionerUserId, practitionerEmail,
   *     practiceName, practiceBrandColor, exerciseCount,
   *     mostRecentPublishedAt, claimedAt, artifacts: [row, row, ...] }
   *
   * Recency ordering across bundles: newest bundle first (by the most
   * recent of any of its artifacts' published_at).
   */
  function groupByPlanId(rows) {
    const byPlan = new Map();
    rows.forEach((row) => {
      if (!row || !row.plan_id) return;
      const id = String(row.plan_id);
      let bundle = byPlan.get(id);
      if (!bundle) {
        bundle = {
          planId:              id,
          planTitle:           row.plan_title || 'Workout plan',
          practitionerUserId:  row.practitioner_user_id || null,
          practitionerEmail:   row.practitioner_email || null,
          practiceName:        row.practice_name || null,
          practiceBrandColor:  row.practice_brand_color || null,
          exerciseCount:       Number(row.exercise_count) || 0,
          mostRecentPublishedAt: null,
          claimedAt:           row.claimed_at || null,
          artifacts:           [],
        };
        byPlan.set(id, bundle);
      }
      bundle.artifacts.push(row);
      // Track the newest published_at across this plan's siblings.
      const pubRaw = row.published_at;
      if (pubRaw) {
        const pubTime = new Date(pubRaw).getTime();
        if (!bundle.mostRecentPublishedAt
            || pubTime > new Date(bundle.mostRecentPublishedAt).getTime()) {
          bundle.mostRecentPublishedAt = pubRaw;
        }
      }
    });
    // Order bundles newest-first by mostRecentPublishedAt, then by
    // claimedAt as a stable tiebreak when both are populated.
    return Array.from(byPlan.values()).sort((a, b) => {
      const ta = a.mostRecentPublishedAt ? new Date(a.mostRecentPublishedAt).getTime() : 0;
      const tb = b.mostRecentPublishedAt ? new Date(b.mostRecentPublishedAt).getTime() : 0;
      if (tb !== ta) return tb - ta;
      const ca = a.claimedAt ? new Date(a.claimedAt).getTime() : 0;
      const cb = b.claimedAt ? new Date(b.claimedAt).getTime() : 0;
      return cb - ca;
    });
  }

  // ===========================  Bundle rendering  ========================

  /**
   * Build one bundle: a fanned card deck of up to 3 visible artifacts
   * (DOM-lean — additional cards behind are not rendered). Tapping a
   * back card rotates it to the front. The front card is an `<a>` link
   * to the artifact's player; back cards have role="button" and rotate
   * to the front on tap.
   *
   * For owner bundles (the viewer is the practitioner who minted the
   * artifact), a "Use as template for a client" CTA renders below the
   * deck. It fires the studio.homefit.app://template?session_id=X
   * deep-link.
   */
  function buildPlanBundle(bundle, consumerUserId) {
    if (!bundle || !bundle.artifacts.length) return null;

    const $wrap = document.createElement('article');
    $wrap.className = 'me-bundle';

    // Mount the deck — separate from the meta block so the fan can
    // overflow vertically without pushing the title/sub down.
    const $deck = document.createElement('div');
    $deck.className = 'me-bundle-deck';
    $deck.setAttribute('aria-label', bundle.planTitle);

    // Render up to 3 cards. The CSS layout pins each by .me-bundle-pos-{n}.
    const visible = bundle.artifacts.slice(0, 3);
    visible.forEach((row, idx) => {
      const $card = buildBundleCard(row, bundle, idx);
      if ($card) $deck.appendChild($card);
    });
    $wrap.appendChild($deck);

    // Meta block — title, sub-line, provenance, and (owner-only)
    // template CTA.
    const $meta = document.createElement('div');
    $meta.className = 'me-bundle-meta';

    const $title = document.createElement('h3');
    $title.className = 'me-bundle-title';
    $title.textContent = bundle.planTitle;
    $meta.appendChild($title);

    const $sub = document.createElement('p');
    $sub.className = 'me-bundle-sub';
    $sub.innerHTML = buildBundleSubLine(bundle);
    $meta.appendChild($sub);

    const $prov = buildBundleProvenance(bundle);
    if ($prov) $meta.appendChild($prov);

    // Owner detection: render the "Use as template" CTA when the
    // viewer's consumer user id matches the bundle's practitioner_user_id.
    // The brief specifies firing the deep-link only — no in-app handler
    // wiring in this PR.
    const isOwner = !!(
      consumerUserId
      && bundle.practitionerUserId
      && consumerUserId === bundle.practitionerUserId
    );
    if (isOwner) {
      $meta.appendChild(buildTemplateCta(bundle));
    }

    $wrap.appendChild($meta);

    // Wire the click-to-rotate behavior. Each card has a data-idx; the
    // front card is whichever .me-bundle-pos-1 currently is. Rebinding
    // is cheap; deck holds at most 3 cards.
    bindDeckRotation($deck, bundle);

    return $wrap;
  }

  function buildBundleCard(row, bundle, position) {
    const kind = String(row.kind);
    const label = kindToLabel(kind);
    if (!label) return null;
    const isFront = position === 0;

    // Front card is an anchor (the consumer's tap = open the artifact).
    // Back cards are buttons (tap = rotate to front, no navigation).
    const $card = document.createElement(isFront ? 'a' : 'button');
    $card.className = 'me-bundle-card me-bundle-pos-' + (position + 1);
    $card.setAttribute('data-kind', kind);
    if (isFront) {
      $card.setAttribute('href', kindToHref(kind, bundle.planId));
      $card.setAttribute('role', 'link');
    } else {
      $card.setAttribute('type', 'button');
      $card.setAttribute('aria-label', label + ' — bring to front');
    }

    // Top row: glyph + label + kind pill.
    const $top = document.createElement('div');
    $top.className = 'me-bundle-card-top';

    const $glyph = document.createElement('div');
    $glyph.className = 'me-bundle-card-glyph' + (kind === 'handout' ? ' is-handout' : '');
    $glyph.innerHTML = kindToGlyphSvg(kind);
    $top.appendChild($glyph);

    const $label = document.createElement('span');
    $label.className = 'me-bundle-card-label';
    $label.textContent = label;
    $top.appendChild($label);

    const $pill = document.createElement('span');
    $pill.className = 'me-bundle-card-pill';
    $pill.textContent = relativeTime(new Date(row.published_at || row.last_published_at || row.claimed_at || Date.now()));
    $top.appendChild($pill);

    $card.appendChild($top);
    return $card;
  }

  function buildBundleSubLine(bundle) {
    const parts = [];
    if (bundle.exerciseCount > 0) {
      parts.push(bundle.exerciseCount + ' exercise' + (bundle.exerciseCount === 1 ? '' : 's'));
    }
    if (bundle.mostRecentPublishedAt) {
      parts.push('updated ' + relativeTime(new Date(bundle.mostRecentPublishedAt)));
    } else if (bundle.claimedAt) {
      parts.push('saved ' + relativeTime(new Date(bundle.claimedAt)));
    }
    // List the included artifact kinds — gives the consumer a hint
    // about how many cards are stacked.
    const kindList = bundle.artifacts
      .map((a) => kindToLabel(a.kind))
      .filter(Boolean);
    if (kindList.length > 1) {
      parts.push(kindList.length + ' formats');
    }
    return parts
      .map((p, i) => i === 0 ? escapeHtml(p) : '<span class="me-dot"></span>' + escapeHtml(p))
      .join('');
  }

  function buildBundleProvenance(bundle) {
    if (!bundle.practitionerEmail && !bundle.practiceName) return null;
    const $prov = document.createElement('div');
    $prov.className = 'me-bundle-provenance';

    const $av = document.createElement('div');
    $av.className = 'me-prov-avatar';
    $av.textContent = emailInitials(bundle.practitionerEmail);
    $prov.appendChild($av);

    const $text = document.createElement('div');
    $text.className = 'me-prov-text';
    const who = practitionerDisplayName(bundle.practitionerEmail);
    const practice = bundle.practiceName || '';
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

  function buildTemplateCta(bundle) {
    const $cta = document.createElement('a');
    $cta.className = 'me-bundle-cta';
    $cta.href = 'studio.homefit.app://template?session_id=' + encodeURIComponent(bundle.planId);
    $cta.setAttribute('role', 'link');

    const $icon = document.createElement('span');
    $icon.className = 'me-bundle-cta-icon';
    $icon.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">'
      + '<rect x="3" y="3" width="18" height="18" rx="2"></rect>'
      + '<path d="M8 12h8M12 8v8"></path>'
      + '</svg>';
    $cta.appendChild($icon);

    const $label = document.createElement('span');
    $label.className = 'me-bundle-cta-label';
    $label.textContent = 'Use as template for a client';
    $cta.appendChild($label);

    return $cta;
  }

  /**
   * Click handler: tapping a back card promotes it to position 1 by
   * cycling the DOM class names. The front card is always
   * `.me-bundle-pos-1`. We re-key positions in source order, then move
   * the tapped index to the front and shift the rest behind it.
   */
  function bindDeckRotation($deck, bundle) {
    $deck.addEventListener('click', (event) => {
      const $card = event.target.closest && event.target.closest('.me-bundle-card');
      if (!$card) return;
      // Anchor clicks on the front card navigate; everything else is a
      // back card and we intercept to rotate. The href on back cards is
      // not set, but we belt-and-brace against future changes.
      const isAnchor = $card.tagName.toLowerCase() === 'a';
      const posClass = Array.from($card.classList).find((c) => c.indexOf('me-bundle-pos-') === 0);
      if (!posClass) return;
      const pos = Number(posClass.replace('me-bundle-pos-', ''));
      if (pos === 1 && isAnchor) {
        // Front card — let the link navigate normally.
        return;
      }
      event.preventDefault();
      rotateDeck($deck, bundle, $card);
    });
  }

  function rotateDeck($deck, bundle, $tapped) {
    const tappedKind = $tapped.getAttribute('data-kind');
    if (!tappedKind) return;
    // Re-order the bundle's artifacts so the tapped one is at index 0,
    // then re-render. We rebuild the children rather than try to chase
    // CSS-only class swaps — the swap path tangles with the anchor-vs-
    // button element type difference (front card is <a>, back are
    // <button>).
    const reordered = [
      bundle.artifacts.find((a) => a.kind === tappedKind),
      ...bundle.artifacts.filter((a) => a.kind !== tappedKind),
    ].filter(Boolean);
    bundle.artifacts = reordered;
    // Strip + rebuild the deck.
    while ($deck.firstChild) $deck.removeChild($deck.firstChild);
    reordered.slice(0, 3).forEach((row, idx) => {
      const $card = buildBundleCard(row, bundle, idx);
      if ($card) $deck.appendChild($card);
    });
  }

  // ===========================  Per-kind helpers  ========================

  function kindToLabel(kind) {
    switch (kind) {
      case 'plan_url': return 'Workout player';
      case 'handout':  return 'Workout handout';
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
      default:         return '/h/' + encodeURIComponent(planId);
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
