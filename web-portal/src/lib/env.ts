/**
 * Strict-fail environment-variable helpers.
 *
 * Mirrors the policy `web-player/build.sh` adopted on 2026-05-11
 * (PR #293): when a required env var is missing, fail loudly at module
 * load instead of silently falling back to a hardcoded prod value.
 *
 * The audit at `docs/HARDCODED-AUDIT-2026-05-12.md` flagged five
 * `process.env.X ?? 'https://yrwcofhovrcydootivjx.supabase.co'`
 * callsites in the web portal (A5) and one referral-URL fallback (A9)
 * + one `placeholder-anon-key` fallback (C7). All silently route a
 * mis-configured staging deploy to prod, with no error in logs and no
 * crash — the next auth/network call returns a confusing "invalid API
 * key" or RLS denial.
 *
 * This module replaces those fallbacks with hard throws so a missing
 * env var surfaces immediately at boot.
 *
 * Build-time safety: Next.js evaluates module top-level code during
 * `next build`. Some Vercel project-init scenarios run a build before
 * env vars are wired (the "first deploy of a fresh project" path). To
 * avoid bricking those, the helpers accept a `buildPhaseFallback`
 * option that returns a placeholder ONLY during `next build`. At
 * runtime (inside a request handler / middleware) the strict-fail
 * always applies — so the deploy succeeds, but the first request
 * crashes loudly, surfacing the misconfiguration to the deployer
 * instead of silently routing to prod.
 */

/**
 * Detects the Next.js build phase. During `next build`, top-level
 * `process.env.NEXT_PHASE === 'phase-production-build'`. At runtime
 * (request handlers, middleware) it's `undefined` or
 * `'phase-production-server'`.
 */
function isBuildPhase(): boolean {
  return process.env.NEXT_PHASE === 'phase-production-build';
}

/**
 * Validate a pre-read env var. Throws if unset (or empty) at request
 * runtime; returns the placeholder during `next build` only.
 *
 * IMPORTANT: callers MUST pass `value` as a LITERAL `process.env.X` read
 * (not `process.env[name]`). Webpack only inlines `NEXT_PUBLIC_*` env
 * vars into client bundles when the access is a static property
 * (`process.env.NEXT_PUBLIC_FOO`); dynamic access via bracket notation
 * (`process.env[varName]`) is NEVER inlined and resolves to `undefined`
 * at runtime in the browser, regardless of whether the env var is set
 * on Vercel. The earlier version of this module did the dynamic read
 * inside `requireEnv` itself, which silently crashed every client
 * component that imported `supabase-browser.ts` (and any other
 * NEXT_PUBLIC_* consumer) at module load. This shape forces each
 * caller to do the literal read at the call site so Webpack can inline.
 */
export function requireEnv(
  name: string,
  value: string | undefined,
  buildPhasePlaceholder?: string,
): string {
  if (value && value.length > 0) {
    return value;
  }
  if (isBuildPhase() && buildPhasePlaceholder !== undefined) {
    // `next build` time. Return placeholder so the build doesn't crash;
    // the first request will trip the strict path and crash loudly.
    return buildPhasePlaceholder;
  }
  throw new Error(
    `${name} is not set. Configure it in the Vercel project's environment ` +
      `variables (per-env: production / preview / development). ` +
      `Misconfigured deployments must fail loudly instead of silently ` +
      `routing to prod (see docs/HARDCODED-AUDIT-2026-05-12.md A5/A9/C7).`,
  );
}

/**
 * Convenience: read the Supabase URL with strict-fail. Production
 * deploys MUST have `NEXT_PUBLIC_SUPABASE_URL` set; per-PR previews
 * have it auto-injected by the Vercel-Supabase integration; staging
 * has it set explicitly. There is no acceptable default — silently
 * falling back to a prod URL on a staging deploy is exactly the bug
 * the audit names.
 */
export function supabaseUrl(): string {
  // Build-phase placeholder is an obviously-invalid URL so a request
  // that hits it during the brief window between deploy and env-var
  // wiring crashes with a meaningful error.
  return requireEnv(
    'NEXT_PUBLIC_SUPABASE_URL',
    process.env.NEXT_PUBLIC_SUPABASE_URL,
    'https://missing-NEXT_PUBLIC_SUPABASE_URL.invalid',
  );
}

/**
 * Convenience: read the Supabase anon key with strict-fail. Same
 * rationale as [supabaseUrl].
 */
export function supabaseAnonKey(): string {
  return requireEnv(
    'NEXT_PUBLIC_SUPABASE_ANON_KEY',
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY,
    'missing-NEXT_PUBLIC_SUPABASE_ANON_KEY',
  );
}

/**
 * App / portal URL (the `manage.homefit.studio` host this portal runs
 * on, per env). Used by referral share links and credit return/cancel
 * URLs.
 */
export function appUrl(): string {
  return requireEnv(
    'NEXT_PUBLIC_APP_URL',
    process.env.NEXT_PUBLIC_APP_URL,
    'https://missing-NEXT_PUBLIC_APP_URL.invalid',
  );
}

/**
 * Web-player URL (the `session.homefit.studio` host the client-facing
 * player runs on, per env). Used to build the share-link href on
 * session cards + audit rows.
 */
export function webPlayerBaseUrl(): string {
  return requireEnv(
    'NEXT_PUBLIC_WEB_PLAYER_BASE_URL',
    process.env.NEXT_PUBLIC_WEB_PLAYER_BASE_URL,
    'https://missing-NEXT_PUBLIC_WEB_PLAYER_BASE_URL.invalid',
  );
}
