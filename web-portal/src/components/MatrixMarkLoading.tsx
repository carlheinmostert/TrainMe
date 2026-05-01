/**
 * MatrixMarkLoading — Matrix-mark loading spinner for the web portal.
 *
 * Inline <svg> mirroring the canonical v2 matrix geometry (12 rects — same
 * as HomefitLogo.tsx). Outer ghost greys breathe inward on a staggered
 * 0 / 0.1s / 0.2s cycle, coral 4-cell + tint band stay static, sage rest
 * pill pulses opacity + scaleY on the shared motion.loop (1.4s) cycle.
 *
 * Animation keyframes + the `.mark--loading` class hooks live in
 * src/app/globals.css (so any future MatrixMarkLoading callsite picks up
 * the same rhythm via the token, not hard-coded numbers).
 *
 * Respects `prefers-reduced-motion: reduce` via globals.css media query —
 * when set, the mark renders statically (no breathing, no pulse).
 *
 * Design spec: docs/design/project/components.md → Loading State →
 * Matrix-mark spinner (v2 geometry).
 * Motion lab: docs/design/mockups/matrix-session-motion.html.
 * Baked SMIL reference: docs/design/project/logos/mark-session.svg.
 */
import * as React from 'react';

export type MatrixMarkLoadingProps = {
  /**
   * Height in CSS pixels. Width is derived from the 48:9.5 aspect ratio.
   * Sensible values: 38 (intrinsic), 48 (default), 96 (hero).
   */
  height?: number;
  /** Accessible label; defaults to "Loading". */
  label?: string;
  className?: string;
};

export function MatrixMarkLoading({
  height = 48,
  label = 'Loading',
  className,
}: MatrixMarkLoadingProps) {
  const width = height * (48 / 9.5);
  const classes = ['mark', 'mark--loading']
    .concat(className ? [className] : [])
    .join(' ');
  return (
    <svg
      className={classes}
      width={width}
      height={height}
      viewBox="0 0 48 9.5"
      xmlns="http://www.w3.org/2000/svg"
      role="img"
      aria-label={label}
    >
      {/* Coral tint band behind the 2x2 circuit. */}
      <rect x="14.5" y="1" width="12.5" height="8.5" rx="1.2" fill="#FF6B35" opacity="0.15" />
      {/* Left ghost pills: outer → inner (outer-1 breathes first, outer-3 last). */}
      <rect className="mark-grey-outer-1" x="0"    y="2.75" width="2.5" height="1.5" rx="0.5" fill="#4B5563" />
      <rect className="mark-grey-outer-2" x="4"    y="2.45" width="3.5" height="2.1" rx="0.7" fill="#6B7280" />
      <rect className="mark-grey-outer-3" x="9"    y="2.15" width="4.5" height="2.7" rx="0.9" fill="#9CA3AF" />
      {/* Coral 4-cell — static. */}
      <rect x="15"   y="2"    width="5"   height="3"   rx="1"   fill="#FF6B35" />
      <rect x="15"   y="6.5"  width="5"   height="3"   rx="1"   fill="#FF6B35" />
      <rect x="21.5" y="2"    width="5"   height="3"   rx="1"   fill="#FF6B35" />
      <rect x="21.5" y="6.5"  width="5"   height="3"   rx="1"   fill="#FF6B35" />
      {/* Sage rest pill — pulses. */}
      <rect className="mark-rest-pill" x="28"   y="2"    width="5"   height="3"   rx="1"   fill="#86EFAC" />
      {/* Right ghost pills: inner → outer (mirror). */}
      <rect className="mark-grey-outer-3" x="34.5" y="2.15" width="4.5" height="2.7" rx="0.9" fill="#9CA3AF" />
      <rect className="mark-grey-outer-2" x="40.5" y="2.45" width="3.5" height="2.1" rx="0.7" fill="#6B7280" />
      <rect className="mark-grey-outer-1" x="45.5" y="2.75" width="2.5" height="1.5" rx="0.5" fill="#4B5563" />
    </svg>
  );
}

export default MatrixMarkLoading;
