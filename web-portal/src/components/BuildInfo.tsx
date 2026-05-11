/**
 * BuildInfo — discreet build-version marker.
 *
 * Renders the short git SHA + branch name at 35% opacity in the fixed
 * bottom-right corner of every page. Mirrors the Flutter mobile pattern
 * (build SHA at 35% opacity in the HomefitLogo footer on Home) and the
 * web-player's `.footer-version` chip.
 *
 * Values come from `NEXT_PUBLIC_GIT_SHA` + `NEXT_PUBLIC_GIT_BRANCH`,
 * which `next.config.mjs` populates at build time from Vercel's
 * VERCEL_GIT_COMMIT_SHA + VERCEL_GIT_COMMIT_REF env vars. Falls back to
 * 'dev' / 'local' for local development so the chip still renders.
 *
 * Mounted once in `app/layout.tsx`'s body so it shows on every route
 * (signed-in dashboards, sign-in gate, privacy/terms scaffolds, etc.).
 * `position: fixed` with a low z-index so it never competes with modals
 * or content; `pointer-events: none` so it can't intercept clicks.
 */
export function BuildInfo() {
  const sha = process.env.NEXT_PUBLIC_GIT_SHA ?? 'dev';
  const branch = process.env.NEXT_PUBLIC_GIT_BRANCH ?? 'local';
  // Compact label — `<sha> · <branch>`. Matches the web-player footer
  // format so QA can spot prod vs preview at a glance across surfaces.
  const label = `${sha} · ${branch}`;
  return (
    <div
      aria-hidden="true"
      className="pointer-events-none fixed bottom-2 right-3 z-10 font-mono text-[10px] tracking-wide text-ink opacity-[0.35] select-text"
    >
      {label}
    </div>
  );
}
