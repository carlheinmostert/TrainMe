/**
 * Shared constants for the active-practice handoff between the mobile
 * app and the portal. The mobile app appends `?practice=<uuid>` to
 * any portal link; edge middleware (`src/middleware.ts`) validates the
 * caller's membership, stores the id in [ACTIVE_PRACTICE_COOKIE], and
 * 302-redirects to the same path with the param stripped. Server
 * components fall back to this cookie when no `?practice=` is in the
 * URL — see dashboard / credits page for the read sites.
 *
 * Kept in `lib/` (not `middleware.ts`) so server components can import
 * the constant without dragging the edge-runtime middleware module
 * into their bundle graph.
 */

export const ACTIVE_PRACTICE_COOKIE = 'hf_active_practice';

/** Loose UUID check used by both middleware and any future call site. */
export const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
