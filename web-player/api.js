/**
 * homefit.studio — Web Player data-access layer
 * =============================================
 * The ONE module that enumerates every Supabase operation the web player
 * (anon role) is allowed to perform. `app.js` MUST route all network I/O
 * through this module — direct `fetch('.../rest/v1/...')` calls elsewhere
 * are a layering violation (see `docs/DATA_ACCESS_LAYER.md`).
 *
 * ## The rule
 *
 *   - Anon web player is allowed to do exactly ONE thing: call
 *     `get_plan_full(p_plan_id)` via PostgREST's /rest/v1/rpc endpoint.
 *   - No direct table reads. Milestone C RLS denies them anyway.
 *   - If a future anon-safe RPC is added, add the method here first,
 *     then use it from `app.js`.
 *
 * ## Three-treatment playback (2026-04-19)
 *
 * The RPC now returns per-exercise `line_drawing_url` (always),
 * `grayscale_url`, and `original_url`. The latter two are signed URLs
 * into the private `raw-archive` bucket, present only when the client
 * (subject of the video) has granted that treatment. This module
 * normalises to always-present-but-nullable keys so `app.js` never
 * needs to check `undefined` vs `null`.
 *
 * ## Segmented-color raw variant (Option 1-augment, 2026-04-23)
 *
 * Milestone P extended `get_plan_full` with two more per-exercise keys:
 *   - grayscale_segmented_url
 *   - original_segmented_url
 * Both point at the dual-output segmented-color mp4 written alongside
 * the line drawing (`*.segmented.mp4`), consent-gated the same way as
 * the untouched grayscale/original URLs. This module normalises those
 * to explicit null when absent; `app.js` prefers the segmented URL and
 * falls back to the untouched original when the segmented file is
 * missing (legacy captures, older plans, 404 on playback).
 *
 * ## Mask sidecar (Milestone P2, 2026-04-23)
 *
 * Milestone P2 added ONE more per-exercise key:
 *   - mask_url
 * A signed URL to the Vision person-segmentation mask mp4 written out
 * as a grayscale H.264 sidecar (`*.mask.mp4`) during the same native
 * conversion pass. Consent-gated on (grayscale OR original) — the mask
 * is useless without at least one body treatment available. TODAY the
 * mask has no consumer: `app.js` is untouched and just ignores the
 * field. Storing it now is insurance so future playback-time
 * compositing (tunable backgroundDim, other effects) can be built
 * against already-published plans without re-capture. This module
 * normalises `mask_url` to explicit null when absent.
 *
 * ## Soft-trim window (Milestone X / Wave 20)
 *
 * Milestone X added two more per-exercise keys:
 *   - start_offset_ms
 *   - end_offset_ms
 * Practitioner-controlled in/out window per exercise. Both null = no
 * trim, full clip plays. Both set = `app.js` clamps the `<video>`
 * element's `currentTime` to `[start, end]` (in ms) and loops within
 * that window. The same trim applies to ALL THREE treatments since
 * they share source timing — switching treatment must NOT reset trim.
 * NO re-conversion: the underlying media file stays full-length; trim
 * is purely a playback-time clamp. This module normalises both keys
 * to explicit null when absent.
 *
 * ## Per-set DOSE (Wave 41 — current)
 *
 * `get_plan_full` now returns one row per exercise carrying:
 *   - sets: [{position, reps, hold_seconds, weight_kg,
 *            breather_seconds_after}, ...]   (empty for rest)
 *   - rest_seconds: integer | null           (rest exercises only)
 * The legacy top-level `reps` / `sets` (int) / `hold_seconds` /
 * `inter_set_rest_seconds` / `custom_duration_seconds` keys have been
 * REMOVED from the RPC. This module coerces every set field to a
 * number where applicable and leaves `weight_kg` as either a number or
 * null (null = bodyweight). Rest exercises always carry an empty
 * `sets: []`; their duration lives in `rest_seconds`.
 *
 * Exposed on `window.HomefitApi` so `app.js` (a plain script, not an
 * ES module) can reach it. When the web player gains a bundler this
 * turns into a proper `export`.
 */

(function () {
  'use strict';

  const SUPABASE_URL = 'https://yrwcofhovrcydootivjx.supabase.co';
  const SUPABASE_ANON_KEY = 'sb_publishable_cwhfavfji552BN8X0uPIpA_pwWQ-gw3';

  /**
   * Wave 4 Phase 1 — unified player prototype.
   *
   * When the page is loaded from the Flutter-embedded `LocalPlayerServer`
   * (scheme http, host 127.0.0.1 / localhost, query ?src=local), route the
   * "plan full" read at `/api/plan/<planId>` on the same origin instead of
   * hitting Supabase. The local server returns a shape-identical payload
   * built from the device's SQLite DB, with media URLs pointing at
   * `/local/<exerciseId>/line` + `/local/<exerciseId>/archive` so the bundle
   * plays archived local files without the network.
   *
   * The web-player (session.homefit.studio) production path falls through
   * to the Supabase RPC — nothing changes when `window.location.hostname`
   * is not a loopback address. Keeps a single bundle serving both surfaces.
   */
  function isLocalSurface() {
    try {
      const host = window.location.hostname;
      // Wave 4 Phase 1: Dart `shelf` loopback → 127.0.0.1 / localhost.
      // Wave 4 Phase 2: `homefit-local://plan/...` custom scheme → 'plan'.
      if (host !== '127.0.0.1' && host !== 'localhost' && host !== 'plan') return false;
      const params = new URLSearchParams(window.location.search || '');
      return params.get('src') === 'local';
    } catch (_) {
      return false;
    }
  }

  function getLocalPlanId() {
    try {
      const params = new URLSearchParams(window.location.search || '');
      return params.get('planId');
    } catch (_) {
      return null;
    }
  }

  /**
   * Coerce a numeric-ish value to a finite number, or `def` when the
   * value is null/undefined/NaN/non-finite. Used by the per-set
   * normaliser below — server may send strings (numeric jsonb is rare
   * in PostgREST output, but we belt-and-brace) or null.
   */
  function _coerceNum(v, def) {
    if (v === null || v === undefined) return def;
    const n = Number(v);
    if (!Number.isFinite(n)) return def;
    return n;
  }

  /**
   * Coerce a numeric-ish value to a finite number, OR explicit null
   * when the source is null/undefined. Used for `weight_kg` which
   * carries a load-bearing null = bodyweight signal.
   */
  function _coerceNumOrNull(v) {
    if (v === null || v === undefined) return null;
    const n = Number(v);
    if (!Number.isFinite(n)) return null;
    return n;
  }

  /**
   * Wave 41 per-set normaliser. The server sends each exercise with a
   * `sets: [{position, reps, hold_seconds, weight_kg,
   * breather_seconds_after}, ...]` array (empty for rest). We coerce
   * every numeric field and preserve `weight_kg`'s null-vs-number
   * distinction (null = bodyweight; number = kg).
   */
  function _normaliseSets(rawSets) {
    if (!Array.isArray(rawSets)) return [];
    return rawSets
      .map((s, i) => ({
        position: _coerceNum(s && s.position, i),
        reps: Math.max(0, _coerceNum(s && s.reps, 0)),
        hold_seconds: Math.max(0, _coerceNum(s && s.hold_seconds, 0)),
        weight_kg: _coerceNumOrNull(s && s.weight_kg),
        breather_seconds_after: Math.max(
          0,
          _coerceNum(s && s.breather_seconds_after, 0),
        ),
      }))
      .sort((a, b) => a.position - b.position);
  }

  /**
   * Per-exercise normaliser, shared between the live RPC path and the
   * mobile WebView (`getPlanFullLocal`) so both surfaces see the same
   * key shape. Drops the legacy top-level `reps` / `sets` (int) /
   * `hold_seconds` / `inter_set_rest_seconds` / `custom_duration_seconds`
   * keys — `app.js` reads everything from `sets: [...]` now.
   */
  function _normaliseExercise(e) {
    return {
      ...e,
      line_drawing_url: e.line_drawing_url || e.media_url || null,
      grayscale_url: e.grayscale_url || null,
      original_url: e.original_url || null,
      grayscale_segmented_url: e.grayscale_segmented_url || null,
      original_segmented_url: e.original_segmented_url || null,
      mask_url: e.mask_url || null,
      // Milestone X — per-exercise soft-trim window (Wave 20).
      // Both null = no trim, full clip plays. Both set = mobile + web
      // player clamp `<video>.currentTime` to [start, end] in ms and
      // loop within the window. Same trim applies across all three
      // treatments since they share source timing.
      start_offset_ms: e.start_offset_ms ?? null,
      end_offset_ms: e.end_offset_ms ?? null,
      // Wave 24 — number of reps captured in the source video. NULL =
      // legacy / pre-migration row (player treats as 1 rep per loop,
      // preserving pre-Wave-24 playback math). Drives the per-rep
      // duration derivation in calculatePerSetSeconds.
      video_reps_per_loop: e.video_reps_per_loop ?? null,
      // Wave 41 per-set DOSE. Always present as an array (empty for
      // rest exercises). Each entry: position, reps, hold_seconds,
      // weight_kg (null = bodyweight), breather_seconds_after.
      sets: _normaliseSets(e.sets),
      // Top-level rest_seconds for rest exercises (null otherwise).
      // Legacy fallback to `hold_seconds` / `custom_duration_seconds`
      // only kicks in if the server returns them on a rest row — the
      // RPC has dropped those keys but defensive readers stay cheap.
      rest_seconds: e.rest_seconds == null
        ? (e.media_type === 'rest'
            ? _coerceNumOrNull(e.hold_seconds ?? e.custom_duration_seconds)
            : null)
        : _coerceNumOrNull(e.rest_seconds),
      // Wave 42 — per-exercise body-focus default (PR #146 schema).
      // NULL = practitioner hasn't expressed a preference; treat as ON.
      // Client overrides ride on top of this default per-exercise.
      body_focus: e.body_focus ?? null,
    };
  }

  async function getPlanFullLocal(planId) {
    const effectiveId = planId || getLocalPlanId();
    if (!effectiveId) throw new Error('Plan not found');
    const response = await fetch(`/api/plan/${encodeURIComponent(effectiveId)}`, {
      method: 'GET',
      headers: { 'Accept': 'application/json' },
    });
    if (!response.ok) throw new Error('Plan not found');
    const payload = await response.json();
    if (!payload || !payload.plan) throw new Error('Plan not found');
    const exercises = (payload.exercises || []).map(_normaliseExercise);
    exercises.sort((a, b) => (a.position ?? 0) - (b.position ?? 0));
    return { ...payload, exercises };
  }

  /**
   * `get_plan_full(p_plan_id)` — SECURITY DEFINER RPC that bypasses RLS
   * and (as a side effect) stamps `plans.first_opened_at` on the first
   * anonymous fetch.
   *
   * Parameter name is `p_plan_id` — NOT `plan_id`. The rename landed on
   * 2026-04-18 to resolve an ambiguous-column error in the RPC body.
   *
   * Three-treatment normalisation: every exercise comes back with
   *   line_drawing_url (always; falls back to legacy `media_url` for
   *                     pre-migration plans)
   *   grayscale_url    (null unless client consent grants grayscale)
   *   original_url     (null unless client consent grants original)
   *
   * Throws 'Plan not found' when the RPC response is non-ok or empty.
   */
  async function getPlanFull(planId) {
    if (isLocalSurface()) return getPlanFullLocal(planId);
    const response = await fetch(
      `${SUPABASE_URL}/rest/v1/rpc/get_plan_full`,
      {
        method: 'POST',
        headers: {
          'apikey': SUPABASE_ANON_KEY,
          'Authorization': `Bearer ${SUPABASE_ANON_KEY}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ p_plan_id: planId }),
      },
    );
    if (!response.ok) throw new Error('Plan not found');
    const payload = await response.json();
    if (!payload || !payload.plan) throw new Error('Plan not found');

    // Normalise exercise shape so app.js can rely on treatment keys
    // always being present (nullable ones explicitly null rather than
    // undefined). Keeps downstream code branch-light. Shared with the
    // mobile WebView path via _normaliseExercise.
    const exercises = (payload.exercises || []).map(_normaliseExercise);
    exercises.sort((a, b) => (a.position ?? 0) - (b.position ?? 0));

    return { ...payload, exercises };
  }

  /**
   * `record_plan_opened(p_plan_id)` — Wave 33 SECURITY DEFINER RPC that
   * idempotently stamps `plans.first_opened_at = COALESCE(first_opened_at, now())`
   * + `plans.last_opened_at = now()` on every call. Drives the Studio
   * "First opened {date} · Last opened {date}" analytics row.
   *
   * Best-effort: errors are caught + logged but never thrown to the
   * caller. The plan still renders if this round-trip fails — engagement
   * analytics is a side-channel, not load-bearing.
   *
   * Skipped on the local surface (mobile preview WebView): the device
   * preview is the practitioner's own private rehearsal, not a real
   * client open. Stamping last_opened_at every time the practitioner
   * peeks at their own plan would corrupt the engagement signal.
   */
  async function recordPlanOpened(planId) {
    if (!planId) return;
    if (isLocalSurface()) return;
    try {
      await fetch(
        `${SUPABASE_URL}/rest/v1/rpc/record_plan_opened`,
        {
          method: 'POST',
          headers: {
            'apikey': SUPABASE_ANON_KEY,
            'Authorization': `Bearer ${SUPABASE_ANON_KEY}`,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({ p_plan_id: planId }),
        },
      );
    } catch (err) {
      // Engagement signal is non-critical — log + continue.
      try { console.warn('[homefit] record_plan_opened failed:', err); } catch (_) {}
    }
  }

  // ==================================================================
  // Wave 17 — Analytics consent + event tracking RPCs
  // ==================================================================

  /**
   * `start_analytics_session(p_plan_id, p_user_agent_bucket)` — starts an
   * anonymous analytics session for this plan view. Returns the session UUID
   * or null if the practitioner has disabled analytics for this client.
   *
   * The returned session ID is the handle passed to every subsequent event
   * call; a null return means the player should skip the consent banner
   * entirely and never emit events.
   *
   * Skipped on the local surface (mobile preview WebView) — same reasoning
   * as recordPlanOpened: practitioner rehearsal isn't a real client open.
   */
  async function startAnalyticsSession(planId, userAgentBucket) {
    if (!planId) return null;
    if (isLocalSurface()) return null;
    try {
      const response = await fetch(
        `${SUPABASE_URL}/rest/v1/rpc/start_analytics_session`,
        {
          method: 'POST',
          headers: {
            'apikey': SUPABASE_ANON_KEY,
            'Authorization': `Bearer ${SUPABASE_ANON_KEY}`,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({
            p_plan_id: planId,
            p_user_agent_bucket: userAgentBucket || 'other',
          }),
        },
      );
      if (!response.ok) return null;
      const result = await response.json();
      // The RPC returns the UUID directly (scalar) or null.
      return result || null;
    } catch (err) {
      try { console.warn('[homefit] start_analytics_session failed:', err); } catch (_) {}
      return null;
    }
  }

  /**
   * `log_analytics_event(p_session_id, p_event_kind, p_exercise_id, p_event_data)`
   * — persists a single event row. Rate-limited server-side (~1/sec per session).
   *
   * Fire-and-forget; errors are logged but never thrown.
   */
  async function logAnalyticsEvent(sessionId, eventKind, exerciseId, eventData) {
    if (!sessionId || !eventKind) return;
    if (isLocalSurface()) return;
    try {
      await fetch(
        `${SUPABASE_URL}/rest/v1/rpc/log_analytics_event`,
        {
          method: 'POST',
          headers: {
            'apikey': SUPABASE_ANON_KEY,
            'Authorization': `Bearer ${SUPABASE_ANON_KEY}`,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({
            p_session_id: sessionId,
            p_event_kind: eventKind,
            p_exercise_id: exerciseId || null,
            p_event_data: eventData || null,
          }),
        },
      );
    } catch (err) {
      try { console.warn('[homefit] log_analytics_event failed:', err); } catch (_) {}
    }
  }

  /**
   * `set_analytics_consent(p_session_id, p_granted)` — records the client's
   * consent decision (accept or reject) for this session.
   */
  async function setAnalyticsConsent(sessionId, granted) {
    if (!sessionId) return;
    if (isLocalSurface()) return;
    try {
      await fetch(
        `${SUPABASE_URL}/rest/v1/rpc/set_analytics_consent`,
        {
          method: 'POST',
          headers: {
            'apikey': SUPABASE_ANON_KEY,
            'Authorization': `Bearer ${SUPABASE_ANON_KEY}`,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({
            p_session_id: sessionId,
            p_granted: !!granted,
          }),
        },
      );
    } catch (err) {
      try { console.warn('[homefit] set_analytics_consent failed:', err); } catch (_) {}
    }
  }

  /**
   * `revoke_analytics_consent(p_plan_id, p_session_id)` — called from the
   * "Stop sharing" button on the transparency page. Revokes consent for
   * this session and flags the plan for no further analytics.
   */
  async function revokeAnalyticsConsent(planId, sessionId) {
    if (!planId) return;
    if (isLocalSurface()) return;
    try {
      await fetch(
        `${SUPABASE_URL}/rest/v1/rpc/revoke_analytics_consent`,
        {
          method: 'POST',
          headers: {
            'apikey': SUPABASE_ANON_KEY,
            'Authorization': `Bearer ${SUPABASE_ANON_KEY}`,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({
            p_plan_id: planId,
            p_session_id: sessionId || null,
          }),
        },
      );
    } catch (err) {
      try { console.warn('[homefit] revoke_analytics_consent failed:', err); } catch (_) {}
    }
  }

  /**
   * `get_plan_sharing_context(p_plan_id)` — returns minimal practitioner +
   * practice + client context for the transparency page greeting.
   *
   * Returns { practitioner_name, practice_name, client_first_name,
   * analytics_allowed } or null when the plan is deleted / analytics
   * disabled at the client level.
   */
  async function getPlanSharingContext(planId) {
    if (!planId) return null;
    try {
      const response = await fetch(
        `${SUPABASE_URL}/rest/v1/rpc/get_plan_sharing_context`,
        {
          method: 'POST',
          headers: {
            'apikey': SUPABASE_ANON_KEY,
            'Authorization': `Bearer ${SUPABASE_ANON_KEY}`,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({ p_plan_id: planId }),
        },
      );
      if (!response.ok) return null;
      const rows = await response.json();
      // RPC returns TABLE — PostgREST wraps as an array. Grab first row.
      if (Array.isArray(rows) && rows.length > 0) return rows[0];
      if (rows && !Array.isArray(rows)) return rows;
      return null;
    } catch (err) {
      try { console.warn('[homefit] get_plan_sharing_context failed:', err); } catch (_) {}
      return null;
    }
  }

  window.HomefitApi = Object.freeze({
    getPlanFull,
    recordPlanOpened,
    startAnalyticsSession,
    logAnalyticsEvent,
    setAnalyticsConsent,
    revokeAnalyticsConsent,
    getPlanSharingContext,
    isLocalSurface,
    getLocalPlanId,
    SUPABASE_URL,
    SUPABASE_ANON_KEY,
  });
})();
