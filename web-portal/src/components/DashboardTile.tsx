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
        <p className="text-xs font-medium uppercase tracking-wider text-ink-muted">
          {label}
        </p>
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

  return (
    <div className="relative h-full">
      {/* C-7: main Trigger gets its own Root so the popover anchors to
          THIS Trigger and not the touch info button (which lives in a
          sibling Root below). */}
      <Tooltip.Root>
        <Tooltip.Trigger asChild>
          {comingSoon ? (
            <div
              className="group relative flex h-full items-start gap-4 rounded-lg border border-surface-border bg-surface-base p-5"
              aria-disabled="true"
            >
              {body}
            </div>
          ) : (
            <Link
              href={href}
              className="group relative flex h-full items-start gap-4 rounded-lg border border-surface-border bg-surface-base p-5 transition hover:border-brand hover:shadow-focus-ring focus:outline-none focus-visible:border-brand focus-visible:shadow-focus-ring"
            >
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
