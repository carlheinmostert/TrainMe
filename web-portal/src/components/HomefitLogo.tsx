/**
 * HomefitLogo — React port of the "Full Session" mark.
 *
 * Renders a valid training-plan snippet using the exact visual
 * vocabulary of the progress-pill matrix:
 *
 *   ━━━━ [■ ■][■ ■]  ■  ■━━━━
 *        \  circuit / │  │
 *                     │  └─ rest (sage)
 *                     └─── standalone (coral)
 *
 * The logo IS the product. Reading left-to-right the shape is the
 * literal output the matrix would draw for that plan — coral pills
 * for exercises, a coral-tinted band behind the circuit columns,
 * entry + exit rail stubs, and a sage rest pill closing the sequence.
 *
 * Geometry matches the web-player's buildHomefitLogoSvg() in
 * web-player/app.js (single source of truth for the SVG shape)
 * and the Flutter widget at app/lib/widgets/homefit_logo.dart.
 *
 * No invented shapes. No icons, letters, or decorative curves.
 */
export function HomefitLogo({
  className,
  'aria-hidden': ariaHidden = true,
}: {
  className?: string;
  'aria-hidden'?: boolean;
}) {
  return (
    <svg
      className={className}
      viewBox="0 0 33.5 11.5"
      xmlns="http://www.w3.org/2000/svg"
      aria-hidden={ariaHidden}
    >
      {/* Rail entry stub — top row, just before band */}
      <path
        d="M0 3.5 L4.5 3.5"
        stroke="rgba(255, 107, 53, 0.7)"
        strokeWidth="0.7"
        strokeLinecap="round"
      />

      {/* Coral-tint band behind circuit columns */}
      <rect
        x="4.5"
        y="1.5"
        width="12.5"
        height="8.5"
        rx="1.5"
        fill="rgba(255, 107, 53, 0.15)"
      />

      {/* Circuit pills (cols 0,1 × rows 0,1) — coral */}
      <rect x="5"    y="2"   width="5" height="3" rx="1" fill="#FF6B35" />
      <rect x="5"    y="6.5" width="5" height="3" rx="1" fill="#FF6B35" />
      <rect x="11.5" y="2"   width="5" height="3" rx="1" fill="#FF6B35" />
      <rect x="11.5" y="6.5" width="5" height="3" rx="1" fill="#FF6B35" />

      {/* Standalone coral pill — col 2, row 0 only */}
      <rect x="18"   y="2"   width="5" height="3" rx="1" fill="#FF6B35" />

      {/* Rest sage pill — col 3, row 0 only */}
      <rect x="24.5" y="2"   width="5" height="3" rx="1" fill="#86EFAC" />

      {/* Rail exit stub — bottom row, just after last col */}
      <path
        d="M29.5 8 L33.5 8"
        stroke="rgba(255, 107, 53, 0.7)"
        strokeWidth="0.7"
        strokeLinecap="round"
      />
    </svg>
  );
}
