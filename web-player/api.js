/**
 * homefit.studio — Web Player data-access layer
 * =============================================
 * The ONE module that enumerates every Supabase operation the web player
 * (anon role) is allowed to perform. `app.js` MUST route all network I/O
 * through this module — direct `fetch('.../rest/v1/...')` calls elsewhere
 * are a layering violation (see `docs/DATA_ACCESS_LAYER.md`).
 *
 * On 2026-04-18 the web player's `fetchPlan` helper was reading `plans`
 * + `exercises` directly via PostgREST. Milestone C's RLS lockdown turned
 * those reads into silent empty results, which surfaced as "plan not
 * found" in the UI. A second issue the same day renamed the RPC
 * parameter `plan_id` → `p_plan_id` and broke the contract a second time.
 * Both classes of bug become impossible the moment there's exactly one
 * place to change these call sites.
 *
 * ## The rule
 *
 *   - Anon web player is allowed to do exactly ONE thing: call
 *     `get_plan_full(p_plan_id)` via PostgREST's /rest/v1/rpc endpoint.
 *   - No direct table reads. Milestone C RLS denies them anyway.
 *   - If a future anon-safe RPC is added, add the method here first,
 *     then use it from `app.js`.
 *
 * Exposed on `window.HomefitApi` so `app.js` (a plain script, not an
 * ES module) can reach it. When the web player gains a bundler this
 * turns into a proper `export`.
 */

(function () {
  'use strict';

  // Centralised config. If either of these moves, update here — the rest
  // of the surface references `window.HomefitApi.*` only.
  const SUPABASE_URL = 'https://yrwcofhovrcydootivjx.supabase.co';
  const SUPABASE_ANON_KEY = 'sb_publishable_cwhfavfji552BN8X0uPIpA_pwWQ-gw3';

  /**
   * `get_plan_full(p_plan_id)` — SECURITY DEFINER RPC that bypasses RLS
   * and (as a side effect) stamps `plans.first_opened_at` on the first
   * anonymous fetch. Returns `{ plan: {...}, exercises: [...] }` or
   * null when the plan id is unknown.
   *
   * Parameter name is `p_plan_id` — NOT `plan_id`. The rename landed on
   * 2026-04-18 to resolve an ambiguous-column error in the RPC body.
   * That rename is the reason this module exists: any future rename
   * should be a one-line change here, not a shotgun hunt across the
   * JS surface.
   *
   * Throws 'Plan not found' when the RPC response is non-ok or the
   * payload is empty. `app.js`'s init() catches and shows the error
   * state; no other mapping is needed.
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
    return payload;
  }

  // Expose the API. Frozen to make accidental mutation (`HomefitApi.foo = ...`)
  // explode loudly rather than silently polluting the global.
  window.HomefitApi = Object.freeze({
    getPlanFull,
    // Re-exported for the one site that composes media URLs; everything
    // else that needs the base URL should use a typed method instead.
    SUPABASE_URL,
    SUPABASE_ANON_KEY,
  });
})();
