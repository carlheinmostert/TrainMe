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
 * Exposed on `window.HomefitApi` so `app.js` (a plain script, not an
 * ES module) can reach it. When the web player gains a bundler this
 * turns into a proper `export`.
 */

(function () {
  'use strict';

  const SUPABASE_URL = 'https://yrwcofhovrcydootivjx.supabase.co';
  const SUPABASE_ANON_KEY = 'sb_publishable_cwhfavfji552BN8X0uPIpA_pwWQ-gw3';

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
    // undefined). Keeps downstream code branch-light.
    const exercises = (payload.exercises || []).map((e) => ({
      ...e,
      line_drawing_url: e.line_drawing_url || e.media_url || null,
      grayscale_url: e.grayscale_url || null,
      original_url: e.original_url || null,
    }));
    exercises.sort((a, b) => (a.position ?? 0) - (b.position ?? 0));

    return { ...payload, exercises };
  }

  window.HomefitApi = Object.freeze({
    getPlanFull,
    SUPABASE_URL,
    SUPABASE_ANON_KEY,
  });
})();
