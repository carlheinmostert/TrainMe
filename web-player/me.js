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
 *      response into bundles (one bundle per plan_id) rendered as a
 *      vertical session accordion. 2026-05-27 (artifact-card accordion)
 *      — replaces the fanned-deck-per-bundle UI from PR #548 with a
 *      session card + peek + tappable chevron + inline expand pattern
 *      that mirrors mobile's ClientSessionsScreen / My Workouts
 *      (R-10 parity). Sibling artifacts (plan_url + handout for the
 *      same plan) collapse into one accordion the consumer expands
 *      to browse formats.
 *
 *      For owner bundles (viewer's user-id matches the bundle's
 *      practitioner_user_id), a "Use as template for a client" CTA
 *      renders INSIDE the expanded artifact area (not on the collapsed
 *      session card) and fires the
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

  // ===========================  Accordion rendering  =====================

  /**
   * Build one bundle as a session-accordion row.
   *
   * Markup (2026-05-27 afternoon iteration — replaces the chevron-only
   * tap zone with two stacked action buttons):
   *   <article class="me-session-row" data-has-artifacts="true|false">
   *     <div class="me-session-peek"></div>             // depth cue
   *     <div class="me-session-card">                   // body row
   *       <div class="me-session-card-body">
   *         <div class="me-session-glyph">N</div>       // exercise count
   *         <div class="me-session-meta">
   *           <h3 class="me-session-title">...</h3>
   *           <p class="me-session-sub">...</p>
   *           <div class="me-session-provenance">...</div>
   *         </div>
   *         <div class="me-action-stack">              // two pill buttons
   *           <button class="me-action-btn is-studio">  // top: Studio
   *             <svg>pencil</svg><span>...</span>       //      pencil + ›
   *           </button>
   *           <button class="me-action-btn is-artifacts"> // bottom: expand
   *             <svg>stacked cards</svg><span>...</span>  //   layers + ▾
   *           </button>
   *         </div>
   *       </div>
   *     </div>
   *     <div class="me-session-artifact-stack">         // accordion target
   *       <div class="me-session-artifact-inner">
   *         <a class="me-artifact-card is-front" ...>...</a>
   *         <a class="me-artifact-card" ...>...</a>
   *         <a class="me-session-template-cta" ...>...</a>   // owner-only
   *       </div>
   *     </div>
   *   </article>
   *
   * Behaviour:
   *   - Tap on the Studio button (top) fires a deep-link to the iOS app
   *     for owner bundles (`studio.homefit.app://template?session_id=`).
   *     For non-owner bundles on /me the Studio button is HIDDEN — the
   *     consumer has nothing to open in Studio.
   *   - Tap on the Artifacts button (bottom) toggles `.is-expanded` on
   *     the row. The accordion expansion is CSS-driven (grid-template-rows
   *     0fr -> 1fr) so the height animates cleanly.
   *   - The session card body is non-interactive on web — there's no
   *     Studio target on /me (consumer surface). The Studio button
   *     covers the practitioner-side "Use as template" affordance.
   *   - Accordion is mutually exclusive across the list (single open).
   *   - "Use as template" CTA lives INSIDE the expanded area for
   *     owner bundles — per the redesigned spec.
   */
  function buildPlanBundle(bundle, consumerUserId) {
    if (!bundle || !bundle.artifacts.length) return null;

    const $row = document.createElement('article');
    $row.className = 'me-session-row';
    $row.setAttribute('data-has-artifacts', 'true');

    // Peek card — drawn behind the session card, 4px right + 5px down
    // via CSS. Lifts upward + fades on .is-expanded.
    const $peek = document.createElement('div');
    $peek.className = 'me-session-peek';
    $peek.setAttribute('aria-hidden', 'true');
    $row.appendChild($peek);

    // Session card body.
    const $card = document.createElement('div');
    $card.className = 'me-session-card';

    const $cardBody = document.createElement('div');
    $cardBody.className = 'me-session-card-body';

    // Exercise-count glyph (mirrors mobile's _LeadingCountGlyph). When
    // the count is 0 the glyph is suppressed so the row reads clean.
    if (bundle.exerciseCount > 0) {
      const $glyph = document.createElement('div');
      $glyph.className = 'me-session-glyph';
      $glyph.textContent = bundle.exerciseCount > 99
        ? '99+'
        : String(bundle.exerciseCount);
      $cardBody.appendChild($glyph);
    }

    const $meta = document.createElement('div');
    $meta.className = 'me-session-meta';

    const $title = document.createElement('h3');
    $title.className = 'me-session-title';
    $title.textContent = bundle.planTitle;
    $meta.appendChild($title);

    const $sub = document.createElement('p');
    $sub.className = 'me-session-sub';
    $sub.innerHTML = buildBundleSubLine(bundle);
    $meta.appendChild($sub);

    const $prov = buildBundleProvenance(bundle);
    if ($prov) $meta.appendChild($prov);

    $cardBody.appendChild($meta);

    // ------- Two stacked action buttons (2026-05-27 afternoon iteration)
    // Top: Studio (pencil + chevron-right) — owner-only on /me; the
    //      non-owner consumer has nothing to open in Studio.
    // Bottom: Artifacts (stacked-cards + chevron-down) — toggles expand.
    //         Hidden when the row has no artifacts (handled via CSS on
    //         data-has-artifacts="false").
    const isOwner = !!(
      consumerUserId
      && bundle.practitionerUserId
      && consumerUserId === bundle.practitionerUserId
    );

    const $actionStack = document.createElement('div');
    $actionStack.className = 'me-action-stack';

    let $studioBtn = null;
    if (isOwner) {
      $studioBtn = document.createElement('button');
      $studioBtn.type = 'button';
      $studioBtn.className = 'me-action-btn is-studio';
      $studioBtn.setAttribute('aria-label', 'Open in Studio');
      $studioBtn.setAttribute('title', 'Open in Studio');
      // Pencil + chevron-right arrow (U+203A).
      $studioBtn.innerHTML = ''
        + '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">'
        +   '<path d="M12 20h9" />'
        +   '<path d="M16.5 3.5a2.121 2.121 0 0 1 3 3L7 19l-4 1 1-4 12.5-12.5z" />'
        + '</svg>'
        + '<span class="me-action-arrow" aria-hidden="true">›</span>';
      $actionStack.appendChild($studioBtn);
    }

    const $artifactsBtn = document.createElement('button');
    $artifactsBtn.type = 'button';
    $artifactsBtn.className = 'me-action-btn is-artifacts';
    $artifactsBtn.setAttribute('aria-label', 'Show published artifacts');
    $artifactsBtn.setAttribute('aria-expanded', 'false');
    $artifactsBtn.setAttribute('title', 'Show published artifacts');
    // Stacked-cards glyph + chevron-down arrow (U+25BE).
    $artifactsBtn.innerHTML = ''
      + '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">'
      +   '<rect x="3" y="8" width="14" height="11" rx="2" />'
      +   '<path d="M7 8V6a2 2 0 0 1 2-2h10a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2h-2" />'
      + '</svg>'
      + '<span class="me-action-arrow" aria-hidden="true">▾</span>';
    $actionStack.appendChild($artifactsBtn);

    $cardBody.appendChild($actionStack);

    $card.appendChild($cardBody);
    $row.appendChild($card);

    // Accordion stack — CSS grid template animates 0fr <-> 1fr. The
    // inner element draws the coral rail (::before pseudo) + the
    // artifact cards.
    const $stack = document.createElement('div');
    $stack.className = 'me-session-artifact-stack';

    const $inner = document.createElement('div');
    $inner.className = 'me-session-artifact-inner';

    bundle.artifacts.forEach((row, idx) => {
      const $art = buildArtifactCard(row, bundle, idx === 0);
      if ($art) $inner.appendChild($art);
    });

    if (isOwner) {
      $inner.appendChild(buildTemplateCta(bundle));
    }

    $stack.appendChild($inner);
    $row.appendChild($stack);

    bindActionButtons($row, $studioBtn, $artifactsBtn, bundle);

    return $row;
  }

  /**
   * Build one artifact card inside the expanded accordion area. The
   * front card (idx === 0) gets the coral accent border + accent-tinted
   * kind pill. Every card is an anchor element — tapping IS the
   * navigation. There are no "back cards" to rotate any more (replaced
   * by the chevron expand/collapse).
   */
  function buildArtifactCard(row, bundle, isFront) {
    const kind = String(row.kind);
    const label = kindToLabel(kind);
    if (!label) return null;

    const $card = document.createElement('a');
    $card.className = 'me-artifact-card' + (isFront ? ' is-front' : '');
    $card.setAttribute('data-kind', kind);
    $card.setAttribute('href', kindToHref(kind, bundle.planId));
    $card.setAttribute('role', 'link');

    const $glyph = document.createElement('div');
    $glyph.className = 'me-artifact-card-glyph' + (kind === 'handout' ? ' is-handout' : '');
    $glyph.innerHTML = kindToGlyphSvg(kind);
    $card.appendChild($glyph);

    const $meta = document.createElement('div');
    $meta.className = 'me-artifact-card-meta';

    const $label = document.createElement('p');
    $label.className = 'me-artifact-card-label';
    $label.textContent = label;
    $meta.appendChild($label);

    const $pill = document.createElement('span');
    $pill.className = 'me-artifact-card-pill';
    $pill.textContent = relativeTime(new Date(row.published_at || row.last_published_at || row.claimed_at || Date.now()));
    $meta.appendChild($pill);

    $card.appendChild($meta);
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
    // List the included artifact kinds so the consumer can tell how many
    // formats are stacked behind the chevron.
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
    $prov.className = 'me-session-provenance';

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
    $cta.className = 'me-session-template-cta';
    $cta.href = 'studio.homefit.app://template?session_id=' + encodeURIComponent(bundle.planId);
    $cta.setAttribute('role', 'link');

    const $icon = document.createElement('span');
    $icon.className = 'me-session-template-cta-icon';
    $icon.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">'
      + '<rect x="3" y="3" width="18" height="18" rx="2"></rect>'
      + '<path d="M8 12h8M12 8v8"></path>'
      + '</svg>';
    $cta.appendChild($icon);

    const $label = document.createElement('span');
    $label.className = 'me-session-template-cta-label';
    $label.textContent = 'Use as template for a client';
    $cta.appendChild($label);

    return $cta;
  }

  /**
   * Wire the two stacked action buttons (2026-05-27 afternoon iteration).
   *
   * Studio button (top, owner-only) — fires the same deep-link the
   * legacy "Use as template" CTA used: opens the iOS app at
   * `studio.homefit.app://template?session_id={planId}`. Click is
   * `stopPropagation`'d so the card body doesn't double-fire (the card
   * body itself is non-interactive on /me, but the propagation guard
   * keeps the future surface contract consistent with the mobile twin).
   *
   * Artifacts button (bottom) — toggles `.is-expanded` on the parent
   * .me-session-row. Accordion is mutually exclusive across the list:
   * opening row B auto-collapses any other expanded row.
   */
  function bindActionButtons($row, $studioBtn, $artifactsBtn, bundle) {
    if ($studioBtn) {
      $studioBtn.addEventListener('click', (event) => {
        event.preventDefault();
        event.stopPropagation();
        window.location.href =
          'studio.homefit.app://template?session_id=' +
          encodeURIComponent(bundle.planId);
      });
    }

    $artifactsBtn.addEventListener('click', (event) => {
      event.preventDefault();
      event.stopPropagation();
      const wasExpanded = $row.classList.contains('is-expanded');
      // Collapse every other expanded row first (single-open accordion).
      document.querySelectorAll('.me-session-row.is-expanded').forEach((r) => {
        if (r !== $row) {
          r.classList.remove('is-expanded');
          const innerBtn = r.querySelector('.me-action-btn.is-artifacts');
          if (innerBtn) {
            innerBtn.setAttribute('aria-expanded', 'false');
            innerBtn.setAttribute('aria-label', 'Show published artifacts');
          }
        }
      });
      if (wasExpanded) {
        $row.classList.remove('is-expanded');
        $artifactsBtn.setAttribute('aria-expanded', 'false');
        $artifactsBtn.setAttribute('aria-label', 'Show published artifacts');
      } else {
        $row.classList.add('is-expanded');
        $artifactsBtn.setAttribute('aria-expanded', 'true');
        $artifactsBtn.setAttribute('aria-label', 'Hide published artifacts');
      }
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
