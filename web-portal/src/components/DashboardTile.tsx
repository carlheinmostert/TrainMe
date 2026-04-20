import Link from 'next/link';

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
};

/**
 * DashboardTile — the single affordance style for dashboard summary
 * tiles (R-12.5). Every tile is a `<Link>`, so the entire card is the
 * hit target. Hover brightens the border to coral and reveals the
 * chevron at the right so practitioners get the same visual signal
 * across every tile.
 *
 * Usage on `/dashboard`:
 *   <DashboardTile
 *     href={`/credits?practice=${id}`}
 *     label="Credits"
 *     headline={`${balance} credits`}
 *     subtitle="Buy more"
 *   />
 *
 * Accessibility: tile is a single Link — keyboard focus + Enter works,
 * one focus ring per card. No nested interactive elements inside.
 */
export function DashboardTile({
  href,
  label,
  headline,
  subtitle,
  tone = 'default',
}: Props) {
  const accent = tone === 'warning' ? 'text-warning' : 'text-brand';

  return (
    <Link
      href={href}
      className="group relative flex flex-col rounded-lg border border-surface-border bg-surface-base p-5 transition hover:border-brand hover:shadow-focus-ring focus:outline-none focus-visible:border-brand focus-visible:shadow-focus-ring"
    >
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
    </Link>
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
