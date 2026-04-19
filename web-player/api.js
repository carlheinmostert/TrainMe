/**
 * homefit.studio Web Player — Single Enumerated Supabase Surface
 * ---------------------------------------------------------------
 * Per docs/DATA_ACCESS_LAYER.md: every Supabase call the web player makes
 * lives in this file, exposed as a small typed-at-the-edges API. The rest
 * of the player (app.js) consumes `WebPlayerApi.*` and never touches the
 * Supabase URL / anon key directly.
 *
 * All reads go through the `get_plan_full(p_plan_id)` SECURITY DEFINER
 * RPC. RLS forbids direct SELECTs on plans/exercises for anon.
 *
 * Three-treatment playback (2026-04-19):
 *   The RPC now returns `line_drawing_url`, `grayscale_url`, and
 *   `original_url` per exercise. `line_drawing_url` is always present
 *   (that's the default treatment and the only one that survives with no
 *   raw archive / no client okay-to-show-original). The other two are
 *   nullable — the renderer must degrade gracefully when they're absent.
 *
 * The web player never writes. No service-role key ever reaches the
 * browser.
 */

(function () {
  'use strict';

  const SUPABASE_URL = 'https://yrwcofhovrcydootivjx.supabase.co';
  const SUPABASE_ANON_KEY = 'sb_publishable_cwhfavfji552BN8X0uPIpA_pwWQ-gw3';

  /**
   * Fetch a plan + its exercises via the anon-safe `get_plan_full` RPC.
   *
   * Returns a plain-object plan with `exercises` nested, already sorted
   * by position ascending. Exercises carry the three treatment URLs:
   *
   *   exercise.line_drawing_url  // always present — the default
   *   exercise.grayscale_url     // nullable — null when consent-absent
   *   exercise.original_url      // nullable — null when consent-absent
   *
   * For backward-compat with plans published before the three-treatment
   * migration landed, the legacy `media_url` field is also kept. When
   * the RPC response omits `line_drawing_url`, we fall back to
   * `media_url` so the renderer still has something to show.
   *
   * @param {string} planId   UUID of the plan to fetch.
   * @returns {Promise<object>} plan with .exercises array
   * @throws  {Error} when the plan cannot be found / RPC errors.
   */
  async function fetchPlan(planId) {
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
      }
    );
    if (!response.ok) throw new Error('Plan not found');
    const payload = await response.json();
    if (!payload || !payload.plan) throw new Error('Plan not found');

    // Normalise the exercise shape so app.js can rely on treatment keys
    // always being present (nullable ones explicitly null rather than
    // undefined). Keeps downstream code branch-light.
    const exercises = (payload.exercises || []).map((e) => ({
      ...e,
      line_drawing_url: e.line_drawing_url || e.media_url || null,
      grayscale_url: e.grayscale_url || null,
      original_url: e.original_url || null,
    }));

    const plan = { ...payload.plan, exercises };
    plan.exercises.sort((a, b) => a.position - b.position);
    return plan;
  }

  // Publish globally — app.js is a classic <script>, not a module.
  window.WebPlayerApi = { fetchPlan };
})();
