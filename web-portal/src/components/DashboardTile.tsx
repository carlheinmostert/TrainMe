'use client';

import type { ReactNode } from 'react';
import Link from 'next/link';
import * as Tooltip from '@radix-ui/react-tooltip';
import { Info } from 'lucide-react';

type Props = {
  /** Destination URL. R-12.1: every tile has a destination. */
  href: string;
  /** Short category label rendered as the small-cap header ("Credits", "Clients"). */
  label: string;
  /** The big number or phrase rendered as the tile's primary payload. */
  headline: string;
  /** Small supporting line below the headline — not more than one sentence. */
  subtitle: string;
  /** `warning` swaps the accent to the amber warning token (e.g. low credits). */
  tone?: 'default' | 'warning';
  /** Rendered icon JSX for the left icon slot — the cosmetic pass made
   *  icons mandatory so the grid reads as a glyph row at a glance.
   *  Pass a JSX element (e.g. `<Coins size={24} strokeWidth={1.75} />`)
   *  rather than a component reference, because component references
   *  cannot cross the RSC server→client boundary as plain props. */
  icon: ReactNode;
  /** Plain-English description surfaced in the hover/tap tooltip. One
   *  sentence; keep it scannable. */
  description: string;
  /** Coming-soon tiles render as non-clickable `<div>` cards: no chevron,
   *  no coral hover border, dimmed icon. The tooltip still works so
   *  practitioners can learn what's coming. */
  comingSoon?: boolean;
  /** Coral footer band flush with the card's bottom edge. The band is
   *  its own Link so the body click target and the band click target
   *  route independently — no nested anchors. C-12 of the 2026-05-22
   *  portal cosmetics stack: lets the Credits tile carry the network
   *  "earn free credits" affordance without consuming its own grid slot. */
  footerBand?: { copy: string; href: string };
  /** Renders a small `iOS` chip in the label row. C-13 of the 2026-05-22
   *  portal cosmetics stack: signals that the tile's content lives in
   *  the iOS app, not the portal. */
  requiresApp?: boolean;
  /** Small badge text rendered in the top-right corner — currently used
   *  by coming-soon tiles to surface "Soon" without consuming the
   *  headline row. */
  badge?: string;
};

/**
 * DashboardTile — the single affordance style for dashboard summary
 * tiles (R-12.5). Every tile is a `<Link>`, so the entire card is the
 * hit target. Hover brightens the border to coral, reveals the chevron
 * on the right, and (after a 400ms delay via the shared TooltipProvider)
 * surfaces a short popover describing what the tile is for.
 *
 * Cosmetic pass (2026-05-22):
 *   - Added a fixed 40px left icon slot (lucide-react icon, coral on
 *     hover) so the dashboard grid scans as a row of glyphs.
 *   - Wrapped the tile in a Radix Tooltip. Desktop hover triggers the
 *     popover; touch viewports get an "i" info glyph in the top-right
 *     corner that taps to open the same tooltip.
 *
 * Polish bundle (2026-05-22, C-7/C-8/C-9):
 *   - C-7: split into TWO independent `Tooltip.Root` instances — one
 *     anchored to the Link (desktop hover) and one anchored to the
 *     touch info button. Sharing one Root caused Radix to anchor at
 *     viewport (0,0) because two `Trigger asChild` siblings confuse
 *     its single-anchor model.
 *   - C-8: wrapper div + Link both carry `h-full` so the tile stretches
 *     to match the tallest sibling in its grid row. The Link's
 *     `items-start` keeps content top-aligned; only the card grows.
 *   - C-9: `comingSoon` opt-out renders the card as a non-interactive
 *     `<div>` (no Link, no chevron, no coral hover border) with a
 *     dimmed icon. The Radix Tooltip still anchors correctly via the
 *     same Root-per-trigger pattern.
 *
 * Dashboard rework (2026-05-22, C-12 + C-13):
 *   - `footerBand`: optional coral band flush with the card's bottom
 *     edge. Used by the Credits tile to surface the "earn free
 *     credits" affordance that used to live on the now-removed Network
 *     tile. The band is its own `<Link>`, sibling to the card body
 *     `<Link>` — no nested anchors.
 *   - `requiresApp`: optional `iOS` chip in the label row. Used by the
 *     Clients + Classes tiles to signal that their content lives in
 *     the iOS app.
 *   - `badge`: optional top-right corner badge (e.g. "Soon" on the
 *     Classes coming-soon tile).
 *
 * Accessibility:
 *   - Tile body remains a single Link — keyboard focus + Enter works,
 *     one focus ring per card.
 *   - Tooltip content is aria-described via Radix's default plumbing.
 *   - Info glyph is its own button under its own Tooltip.Root so the
 *     tap doesn't intercept the Link click on touch.
 */
export function DashboardTile({
  href,
  label,
  headline,
  subtitle,
  tone = 'default',
  icon,
  description,
  comingSoon = false,
  footerBand,
  requiresApp = false,
  badge,
}: Props) {
  const accent = tone === 'warning' ? 'text-warning' : 'text-brand';

  // Body content is identical between the interactive Link variant and
  // the coming-soon div variant — extracted so both branches stay in
  // sync without copy-paste drift.
  const body = (
    <>
      <div
        className={`flex h-10 w-10 shrink-0 items-center justify-center rounded-md transition ${
          comingSoon
            ? 'text-ink-dim/70'
            : 'text-ink-muted group-hover:text-brand group-focus-visible:text-brand'
        }`}
      >
        {icon}
      </div>
      <div className="flex min-w-0 flex-1 flex-col">
        <div className="flex items-center gap-2">
          <p className="text-xs font-medium uppercase tracking-wider text-ink-muted">
            {label}
          </p>
          {requiresApp && <IosChip />}
        </div>
        <p
          className={`mt-2 font-heading text-3xl font-bold leading-tight ${
            comingSoon ? 'text-ink-muted' : accent
          }`}
        >
          {headline}
        </p>
        <p className="mt-1 flex items-center gap-1 text-sm text-ink-muted">
          <span>{subtitle}</span>
          {!comingSoon && <ChevronRight />}
        </p>
      </div>
    </>
  );

  // Card chrome. When `footerBand` is present the border + rounded
  // corners + bg + hover affordance move to the OUTER wrapper so the
  // card body and band read as one continuous surface. Without this,
  // the body's own rounded-lg corners expose the page background
  // between body and band (the gap Carl flagged on the 2026-05-22
  // staging deploy of PR #428).
  const cardInteractiveOnBody =
    ' transition hover:border-brand hover:shadow-focus-ring focus:outline-none focus-visible:border-brand focus-visible:shadow-focus-ring';
  const cardInteractiveOnOuter =
    ' transition hover:border-brand hover:shadow-focus-ring focus-within:border-brand focus-within:shadow-focus-ring';

  const cardBodyClasses = footerBand
    ? `group relative flex items-start gap-4 p-5 pb-3${comingSoon ? '' : ' focus:outline-none'}`
    : `group relative flex h-full items-start gap-4 rounded-lg border border-surface-border bg-surface-base p-5${comingSoon ? '' : cardInteractiveOnBody}`;

  // Outer wrapper carries the visible chrome (border + rounded + bg)
  // ONLY when a footer band is present. Otherwise the body owns it
  // (today's behaviour for every non-Credits tile).
  const outerClasses = footerBand
    ? `relative flex h-full flex-col overflow-hidden rounded-lg border border-surface-border bg-surface-base${comingSoon ? '' : cardInteractiveOnOuter}`
    : 'relative h-full';

  return (
    <div className={outerClasses}>
      {/* Top-right Soon/badge label — sits above both the Tooltip Root
          and the touch-info button via z-stacking. */}
      {badge && (
        <span className="pointer-events-none absolute right-3 top-3 z-10 rounded border border-surface-border px-2 py-0.5 text-[10px] font-medium uppercase tracking-widest text-ink-dim">
          {badge}
        </span>
      )}

      {/* C-7: main Trigger gets its own Root so the popover anchors to
          THIS Trigger and not the touch info button (which lives in a
          sibling Root below). */}
      <Tooltip.Root>
        <Tooltip.Trigger asChild>
          {comingSoon ? (
            <div className={cardBodyClasses} aria-disabled="true">
              {body}
            </div>
          ) : (
            <Link href={href} className={cardBodyClasses}>
              {body}
            </Link>
          )}
        </Tooltip.Trigger>

        <Tooltip.Portal>
          <Tooltip.Content
            side="top"
            sideOffset={6}
            collisionPadding={12}
            className="z-50 max-w-[280px] rounded-md border border-surface-border bg-surface-raised px-3 py-2 text-xs leading-snug text-ink shadow-[0_8px_24px_rgba(0,0,0,0.35)] animate-[fadeSlideUp_120ms_ease-out]"
          >
            {description}
            <Tooltip.Arrow className="fill-surface-raised" />
          </Tooltip.Content>
        </Tooltip.Portal>
      </Tooltip.Root>

      {/* Touch-viewport info glyph — own Tooltip.Root so its popover
          anchors to the (i) button, not the parent tile. Hidden on
          hover-capable devices via `[@media(hover:hover)]:hidden`. */}
      <TouchInfoTooltip description={description} />

      {footerBand && (
        <Link
          href={footerBand.href}
          className="group/band flex flex-col items-start gap-1 border-t border-[rgba(255,107,53,0.25)] bg-[rgba(255,107,53,0.08)] px-5 py-2.5 text-xs font-medium text-brand-light transition hover:bg-[rgba(255,107,53,0.10)] focus:outline-none focus-visible:bg-[rgba(255,107,53,0.10)] sm:flex-row sm:items-center sm:justify-between sm:gap-3"
        >
          {/* iPhone-portrait follow-up (2026-05-25): the previous fix
              (min-w-0 flex-1 + whitespace-nowrap on the CTA) prevented
              wrapping but let the CTA get clipped on narrow viewports
              when natural copy + CTA width exceeded the band. We now
              stack vertically by default and only switch to a single
              row at `sm+` where there's room. Copy is on row 1, CTA
              "Earn more →" sits on its own row 2 left-aligned with the
              copy so the eye flows down into it as a clear call-to-
              action. On desktop the original one-line layout returns. */}
          <span className="min-w-0">{footerBand.copy}</span>
          <span className="whitespace-nowrap font-semibold text-brand transition group-hover/band:translate-x-0.5">
            Earn more &rarr;
          </span>
        </Link>
      )}
    </div>
  );
}

/**
 * Info glyph for touch viewports — only renders on `(hover: none)`
 * devices. Wrapped in its OWN Tooltip.Root so the anchor stays on the
 * button. Tap opens the same description string the desktop hover does.
 */
function TouchInfoTooltip({ description }: { description: string }) {
  return (
    <Tooltip.Root>
      <Tooltip.Trigger asChild>
        <button
          type="button"
          aria-label="What is this?"
          onClick={(e) => {
            // Prevent the surrounding Link from navigating when the info
            // glyph is tapped on touch viewports.
            e.preventDefault();
            e.stopPropagation();
          }}
          className="pointer-events-auto absolute right-3 top-3 hidden h-6 w-6 items-center justify-center rounded-full text-ink-dim hover:text-brand focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand/40 [@media(hover:none)]:flex"
        >
          <Info size={14} strokeWidth={1.75} aria-hidden="true" />
        </button>
      </Tooltip.Trigger>

      <Tooltip.Portal>
        <Tooltip.Content
          side="top"
          sideOffset={6}
          collisionPadding={12}
          className="z-50 max-w-[280px] rounded-md border border-surface-border bg-surface-raised px-3 py-2 text-xs leading-snug text-ink shadow-[0_8px_24px_rgba(0,0,0,0.35)] animate-[fadeSlideUp_120ms_ease-out]"
        >
          {description}
          <Tooltip.Arrow className="fill-surface-raised" />
        </Tooltip.Content>
      </Tooltip.Portal>
    </Tooltip.Root>
  );
}

/**
 * IosChip — small "iOS" chip rendered in the label row of tiles whose
 * functional content lives in the iOS app. Mirrors `.tile .ios-chip.with-icon`
 * in `docs/design/mockups/portal-get-the-app.html`: 9.5px font, 700 weight,
 * coral text on coral-soft background with a coral-line border, prefixed
 * by a 7px coral square glyph.
 */
function IosChip() {
  return (
    <span
      aria-label="iOS app required"
      className="inline-flex items-center gap-1 rounded-sm border border-brand-tint-border bg-brand-tint-bg px-1.5 py-px text-[9.5px] font-bold uppercase tracking-wider text-brand-light"
    >
      <span
        aria-hidden="true"
        className="inline-block h-[7px] w-[7px] rounded-[2px] bg-brand"
      />
      iOS
    </span>
  );
}

function ChevronRight() {
  return (
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      className="h-4 w-4 text-ink-dim transition group-hover:translate-x-0.5 group-hover:text-brand group-focus-visible:translate-x-0.5 group-focus-visible:text-brand"
      aria-hidden="true"
    >
      <polyline points="9 18 15 12 9 6" />
    </svg>
  );
}
