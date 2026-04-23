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
    const exercises = (payload.exercises || []).map((e) => ({
      ...e,
      line_drawing_url: e.line_drawing_url || e.media_url || null,
      grayscale_url: e.grayscale_url || null,
      original_url: e.original_url || null,
      grayscale_segmented_url: e.grayscale_segmented_url || null,
      original_segmented_url: e.original_segmented_url || null,
      mask_url: e.mask_url || null,
    }));
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
    // undefined). Keeps downstream code branch-light.
    const exercises = (payload.exercises || []).map((e) => ({
      ...e,
      line_drawing_url: e.line_drawing_url || e.media_url || null,
      grayscale_url: e.grayscale_url || null,
      original_url: e.original_url || null,
      grayscale_segmented_url: e.grayscale_segmented_url || null,
      original_segmented_url: e.original_segmented_url || null,
      mask_url: e.mask_url || null,
    }));
    exercises.sort((a, b) => (a.position ?? 0) - (b.position ?? 0));

    return { ...payload, exercises };
  }

  window.HomefitApi = Object.freeze({
    getPlanFull,
    isLocalSurface,
    getLocalPlanId,
    SUPABASE_URL,
    SUPABASE_ANON_KEY,
  });
})();
