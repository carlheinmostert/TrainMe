/**
 * HomefitLogo — React port of the canonical v2 logo system.
 *
 * The logo is a slice of a training-session matrix — the progress-pill
 * matrix is already the product's visual language, and the mark is
 * literally that matrix in miniature:
 *
 *   3 ghost pills (outer → inner, tapering larger + lighter) →
 *   2-cycle circuit sitting in a coral-tint band (2 exercises × 2 cycles) →
 *   1 sage rest pill →
 *   3 ghost pills (mirror on the right)
 *
 * Two variants share the same 11-element matrix geometry:
 *   - `HomefitLogo`        → matrix only, 48×9.5 viewBox. Default export.
 *                            Use in header brand-marks (paired with a
 *                            separate wordmark), favicons, app icons,
 *                            tight chrome, the footer mark.
 *   - `HomefitLogoLockup`  → matrix + wordmark stacked, 48×14 viewBox.
 *                            Use on hero surfaces, emails, marketing,
 *                            share cards — anywhere you want a single
 *                            self-contained mark.
 *
 * Geometry canon lives in this file; the Flutter widget at
 * `app/lib/widgets/homefit_logo.dart` and the web-player helper
 * `buildHomefitLogoSvg()` in `web-player/app.js` mirror it byte-for-byte.
 * Signed off at `docs/design/mockups/logo-ghost-outer.html`.
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
      viewBox="0 0 48 9.5"
      xmlns="http://www.w3.org/2000/svg"
      aria-hidden={ariaHidden}
    >
      {/* Left ghost pills: outer→inner, progressively larger + lighter */}
      <rect x="0"    y="2.75" width="2.5" height="1.5" rx="0.5" fill="#4B5563" />
      <rect x="4"    y="2.45" width="3.5" height="2.1" rx="0.7" fill="#6B7280" />
      <rect x="9"    y="2.15" width="4.5" height="2.7" rx="0.9" fill="#9CA3AF" />

      {/* Circuit tint band (coral @ 15%) */}
      <rect x="14.5" y="1"    width="12.5" height="8.5" rx="1.2" fill="#FF6B35" opacity="0.15" />

      {/* Ex2 / Ex3 — 2×2 grid (2 exercises × 2 cycles), solid coral */}
      <rect x="15"   y="2"    width="5" height="3" rx="1" fill="#FF6B35" />
      <rect x="15"   y="6.5"  width="5" height="3" rx="1" fill="#FF6B35" />
      <rect x="21.5" y="2"    width="5" height="3" rx="1" fill="#FF6B35" />
      <rect x="21.5" y="6.5"  width="5" height="3" rx="1" fill="#FF6B35" />

      {/* Rest — sage */}
      <rect x="28"   y="2"    width="5" height="3" rx="1" fill="#86EFAC" />

      {/* Right ghost pills: inner→outer, mirror of left */}
      <rect x="34.5" y="2.15" width="4.5" height="2.7" rx="0.9" fill="#9CA3AF" />
      <rect x="40.5" y="2.45" width="3.5" height="2.1" rx="0.7" fill="#6B7280" />
      <rect x="45.5" y="2.75" width="2.5" height="1.5" rx="0.5" fill="#4B5563" />
    </svg>
  );
}

/**
 * Lockup variant — wordmark stacked above the matrix. Use on hero
 * surfaces (sign-in, OG cards, email templates, share PNGs). The
 * matrix geometry is identical to `HomefitLogo`, just translated
 * +4.5 on Y to make room for the wordmark row. Wordmark uses
 * Montserrat 600 stretched via `textLength` so it aligns to the
 * 48-unit matrix width at any render size.
 */
export function HomefitLogoLockup({
  className,
  'aria-hidden': ariaHidden = true,
}: {
  className?: string;
  'aria-hidden'?: boolean;
}) {
  return (
    <svg
      className={className}
      viewBox="0 -2 48 16"
      xmlns="http://www.w3.org/2000/svg"
      aria-hidden={ariaHidden}
    >
      {/* Wordmark — Montserrat 600, stretched to match matrix width. */}
      <text
        x="24"
        y="4.6"
        textAnchor="middle"
        textLength="48"
        lengthAdjust="spacingAndGlyphs"
        fontFamily="Montserrat, sans-serif"
        fontWeight="600"
        fontSize="6.5"
        fill="#F0F0F5"
        letterSpacing="-0.1"
      >
        homefit.studio
      </text>

      {/* Matrix — identical geometry to HomefitLogo, translated +4.5 on Y. */}
      <rect x="0"    y="7.25" width="2.5" height="1.5" rx="0.5" fill="#4B5563" />
      <rect x="4"    y="6.95" width="3.5" height="2.1" rx="0.7" fill="#6B7280" />
      <rect x="9"    y="6.65" width="4.5" height="2.7" rx="0.9" fill="#9CA3AF" />
      <rect x="14.5" y="5.5"  width="12.5" height="8.5" rx="1.2" fill="#FF6B35" opacity="0.15" />
      <rect x="15"   y="6.5"  width="5" height="3" rx="1" fill="#FF6B35" />
      <rect x="15"   y="11"   width="5" height="3" rx="1" fill="#FF6B35" />
      <rect x="21.5" y="6.5"  width="5" height="3" rx="1" fill="#FF6B35" />
      <rect x="21.5" y="11"   width="5" height="3" rx="1" fill="#FF6B35" />
      <rect x="28"   y="6.5"  width="5" height="3" rx="1" fill="#86EFAC" />
      <rect x="34.5" y="6.65" width="4.5" height="2.7" rx="0.9" fill="#9CA3AF" />
      <rect x="40.5" y="6.95" width="3.5" height="2.1" rx="0.7" fill="#6B7280" />
      <rect x="45.5" y="7.25" width="2.5" height="1.5" rx="0.5" fill="#4B5563" />
    </svg>
  );
}
