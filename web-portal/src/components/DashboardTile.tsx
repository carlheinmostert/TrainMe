'use client';

import Link from 'next/link';
import * as Tooltip from '@radix-ui/react-tooltip';
import { Info, type LucideIcon } from 'lucide-react';

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
  /** lucide-react icon component rendered in the left icon slot. The
   *  cosmetic pass made icons mandatory — every tile carries one so the
   *  grid reads as a glyph row at a glance. */
  icon: LucideIcon;
  /** Plain-English description surfaced in the hover/tap tooltip. One
   *  sentence; keep it scannable. */
  description: string;
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
 * Touch-viewport pattern: the info glyph is hidden on hover-capable
 * devices via `[@media(hover:hover)]:hidden`. On touch it taps the same
 * Radix Tooltip via a controlled-state effect (`disableHoverableContent`
 * is on at the provider level so tooltips don't latch open after tap).
 *
 * Accessibility:
 *   - Tile body remains a single Link — keyboard focus + Enter works,
 *     one focus ring per card.
 *   - Tooltip content is aria-described via Radix's default plumbing.
 *   - Info glyph is its own button so the tooltip-on-tap doesn't
 *     intercept the Link click on touch.
 */
export function DashboardTile({
  href,
  label,
  headline,
  subtitle,
  tone = 'default',
  icon: Icon,
  description,
}: Props) {
  const accent = tone === 'warning' ? 'text-warning' : 'text-brand';

  return (
    <Tooltip.Root>
      <div className="relative">
        <Tooltip.Trigger asChild>
          <Link
            href={href}
            className="group relative flex items-start gap-4 rounded-lg border border-surface-border bg-surface-base p-5 transition hover:border-brand hover:shadow-focus-ring focus:outline-none focus-visible:border-brand focus-visible:shadow-focus-ring"
          >
            <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-md text-ink-muted transition group-hover:text-brand group-focus-visible:text-brand">
              <Icon size={24} strokeWidth={1.75} aria-hidden="true" />
            </div>
            <div className="flex min-w-0 flex-1 flex-col">
              <p className="text-xs font-medium uppercase tracking-wider text-ink-muted">
                {label}
              </p>
              <p
                className={`mt-2 font-heading text-3xl font-bold leading-tight ${accent}`}
              >
                {headline}
              </p>
              <p className="mt-1 flex items-center gap-1 text-sm text-ink-muted">
                <span>{subtitle}</span>
                <ChevronRight />
              </p>
            </div>
          </Link>
        </Tooltip.Trigger>

        {/* Touch-viewport info glyph — hidden on hover-capable devices.
            Tap surfaces the same Radix Tooltip the desktop hover does.
            Positioned absolute so it doesn't shove the tile content. */}
        <TouchInfoTrigger />
      </div>

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
 * Info glyph for touch viewports — only renders on `(hover: none)`
 * devices. Tapping opens the parent Radix Tooltip via the same Trigger
 * pathway; we use a separate Trigger asChild on a button so the tap
 * doesn't bubble up to the surrounding Link and navigate.
 */
function TouchInfoTrigger() {
  return (
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
