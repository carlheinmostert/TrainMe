'use client';

import * as Tooltip from '@radix-ui/react-tooltip';

/**
 * Client-side Radix Tooltip provider for the dashboard tile grid.
 *
 * Why a dedicated provider rather than mounting one at the root layout:
 *   - The dashboard is the only surface using tooltips today; mounting
 *     here keeps the provider out of every other route's hydration
 *     payload.
 *   - `delayDuration={400}` matches the cosmetic-pass spec — slow enough
 *     that mousing across the grid doesn't flash 6 popovers, fast
 *     enough to feel responsive when the practitioner pauses on a tile.
 *   - `disableHoverableContent` prevents Radix's default "stay open
 *     when cursor enters the content" behaviour. The tooltips here are
 *     descriptive only (not interactive), and disabling hoverable
 *     content stops the touch-viewport tap-then-tap-elsewhere pattern
 *     from leaving popovers stuck open.
 */
export function DashboardTooltipProvider({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <Tooltip.Provider
      delayDuration={400}
      skipDelayDuration={200}
      disableHoverableContent
    >
      {children}
    </Tooltip.Provider>
  );
}
