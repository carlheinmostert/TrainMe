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
 *
 * iPhone-portrait fix (2026-05-25):
 *   - `max-w-[60vw]` + `truncate` clamp long `fix/whatever-very-long-
 *     branch-name` strings on narrow viewports so the chip never paints
 *     wider than the safe right margin. The chip's `select-text` still
 *     copies the full label via the title attribute when QA needs to
 *     read it in full.
 *   - The root layout's `pb-12` body padding keeps content above the
 *     chip's footprint — this component itself only owns the chip's
 *     anchored position. No z-index bump needed; cards in the page
 *     flow render in a higher stacking context implicitly because the
 *     chip is `pointer-events-none` + `z-10` on a fixed layer below the
 *     normal flow.
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
      title={label}
      className="pointer-events-none fixed bottom-2 right-3 z-10 max-w-[60vw] truncate font-mono text-[10px] tracking-wide text-ink opacity-[0.35] select-text"
    >
      {label}
    </div>
  );
}
