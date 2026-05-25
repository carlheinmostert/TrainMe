/**
 * BuildInfo — discreet build-version marker.
 *
 * Renders the short git SHA + branch name at 35% opacity. Mirrors the
 * Flutter mobile pattern (build SHA at 35% opacity in the HomefitLogo
 * footer on Home) and the web-player's `.footer-version` chip.
 *
 * Values come from `NEXT_PUBLIC_GIT_SHA` + `NEXT_PUBLIC_GIT_BRANCH`,
 * which `next.config.mjs` populates at build time from Vercel's
 * VERCEL_GIT_COMMIT_SHA + VERCEL_GIT_COMMIT_REF env vars. Falls back to
 * 'dev' / 'local' for local development so the chip still renders.
 *
 * Mounted once in `app/layout.tsx`'s body so it shows on every route
 * (signed-in dashboards, sign-in gate, privacy/terms scaffolds, etc.).
 *
 * Positioning (iPhone-portrait follow-up, 2026-05-25):
 *   - `< md` — the chip renders as a normal block at the end of the
 *     `<body>` flow: full-width, right-aligned via `text-right`, with
 *     a top border separating it from the last card. No `position:
 *     fixed`, so it can never paint OVER card content. The previous
 *     fix added `pb-12` body padding to push content above the fixed
 *     chip, but `pb-12` only extends the body's flow extent — fixed
 *     layers still float over whatever paints at the chip's pixel
 *     coordinates regardless. Making the chip static at narrow widths
 *     side-steps the entire stacking question.
 *   - `md+` — the chip returns to its original `fixed bottom-2 right-3`
 *     home so the desktop chrome stays uncluttered. The `pointer-
 *     events-none` keeps it from intercepting clicks on the floating
 *     layer.
 *
 * Long-branch truncation:
 *   - `max-w-[60vw] truncate` clamps long branch labels on `md+` so a
 *     `fix/portal-iphone-portrait-rendering-followup` string can never
 *     paint wider than the safe right margin. On `< md` the chip is
 *     full-width so truncation is unnecessary, but the same classes
 *     are harmless there.
 *   - Full label always accessible via the `title` attribute (Safari
 *     surfaces it on long-press; desktop on hover).
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
      className="pointer-events-none mt-8 border-t border-surface-border/40 px-4 py-3 text-right font-mono text-[10px] tracking-wide text-ink opacity-[0.35] select-text md:fixed md:bottom-2 md:right-3 md:mt-0 md:max-w-[60vw] md:truncate md:border-0 md:px-0 md:py-0 md:text-left md:z-10"
    >
      {label}
    </div>
  );
}
