import Image from 'next/image';

/**
 * AppStoreBadge — Apple "Download on the App Store" badge wrapped in
 * an external Link. The SVG asset at `/app-store-badge.svg` is the
 * official Apple-supplied artwork; per Apple's brand guidelines we
 * must not redraw or restyle it ourselves.
 *
 * Used by:
 *  - `GetTheAppBanner` (loud dashboard banner)
 *  - `/clients` empty-state
 *  - `/account` Apps section
 *
 * Hover state: 1px coral border per the mockup's `.appstore-badge:hover`
 * rule. Achieved with a transparent border that turns coral on hover,
 * so the layout never shifts.
 *
 * Accessibility: the badge image carries the canonical alt-text
 * required by Apple's brand guidelines, the wrapping anchor opens in
 * a new tab with the rel attributes recommended for cross-origin
 * outbound links.
 */
export function AppStoreBadge({
  href,
  label,
}: {
  href: string;
  /** Visible-text equivalent for screen readers. The Apple badge image
   *  is already labelled, but we pass the link's accessible name through
   *  for cases where the badge image fails to load. */
  label: string;
}) {
  return (
    <a
      href={href}
      target="_blank"
      rel="noopener noreferrer"
      aria-label={`Download homefit.studio on the ${label}`}
      className="inline-flex h-10 items-center rounded-md border border-transparent transition hover:border-brand focus:outline-none focus-visible:border-brand"
    >
      <Image
        src="/app-store-badge.svg"
        alt={`Download on the ${label}`}
        width={120}
        height={40}
        priority={false}
        unoptimized
        className="block h-10 w-auto"
      />
    </a>
  );
}
