/**
 * homefit.studio — Canonical logo SVG builder (web JS surface)
 * ============================================================
 *
 * The matrix-of-pills logo, the canonical brand mark. Single source for
 * the SVG geometry so every web surface (interactive player lobby +
 * footer, Printable Workout Guide footer + get-app block) renders the
 * IDENTICAL glyph. Geometry canon is duplicated verbatim in
 * `web-portal/src/components/HomefitLogo.tsx` and
 * `app/lib/widgets/homefit_logo.dart`. Signed off at
 * `docs/design/mockups/logo-ghost-outer.html`.
 *
 * Exposes `window.buildHomefitLogoSvg` (matrix only, 48×9.5 viewBox) +
 * `window.buildHomefitLogoLockupSvg` (matrix + wordmark, 48×16). app.js
 * historically defined these top-level; it now delegates to this module
 * when present so the lobby + handout share ONE implementation. Loaded
 * via `<script src="homefit_logo.js">` BEFORE app.js / lobby.js /
 * handout.js. No inline scripts (CSP `script-src 'self'`).
 */
(function () {
  'use strict';

  // Shared 11-pill matrix SVG body. Returns rects only; the caller wraps
  // in <svg>. `yOffset` shifts every Y so the lockup can drop the matrix
  // below the wordmark row.
  function homefitMatrixBody(yOffset) {
    var dy = yOffset || 0;
    var y = function (n) { return (n + dy).toFixed(3).replace(/\.?0+$/, ''); };

    var coral = '#FF6B35';
    var sage = '#86EFAC';
    var ghostOuter = '#4B5563';
    var ghostMid = '#6B7280';
    var ghostInner = '#9CA3AF';

    return (
      '<rect x="0" y="' + y(2.75) + '" width="2.5" height="1.5" rx="0.5" fill="' + ghostOuter + '"/>' +
      '<rect x="4" y="' + y(2.45) + '" width="3.5" height="2.1" rx="0.7" fill="' + ghostMid + '"/>' +
      '<rect x="9" y="' + y(2.15) + '" width="4.5" height="2.7" rx="0.9" fill="' + ghostInner + '"/>' +
      '<rect x="14.5" y="' + y(1) + '" width="12.5" height="8.5" rx="1.2" fill="' + coral + '" opacity="0.15"/>' +
      '<rect x="15" y="' + y(2) + '" width="5" height="3" rx="1" fill="' + coral + '"/>' +
      '<rect x="15" y="' + y(6.5) + '" width="5" height="3" rx="1" fill="' + coral + '"/>' +
      '<rect x="21.5" y="' + y(2) + '" width="5" height="3" rx="1" fill="' + coral + '"/>' +
      '<rect x="21.5" y="' + y(6.5) + '" width="5" height="3" rx="1" fill="' + coral + '"/>' +
      '<rect x="28" y="' + y(2) + '" width="5" height="3" rx="1" fill="' + sage + '"/>' +
      '<rect x="34.5" y="' + y(2.15) + '" width="4.5" height="2.7" rx="0.9" fill="' + ghostInner + '"/>' +
      '<rect x="40.5" y="' + y(2.45) + '" width="3.5" height="2.1" rx="0.7" fill="' + ghostMid + '"/>' +
      '<rect x="45.5" y="' + y(2.75) + '" width="2.5" height="1.5" rx="0.5" fill="' + ghostOuter + '"/>'
    );
  }

  function buildHomefitLogoSvg() {
    return (
      '<svg class="homefit-logo" viewBox="0 0 48 9.5"' +
      ' xmlns="http://www.w3.org/2000/svg" aria-hidden="true">' +
      homefitMatrixBody(0) +
      '</svg>'
    );
  }

  function buildHomefitLogoLockupSvg() {
    return (
      '<svg class="homefit-logo homefit-logo--lockup" viewBox="0 -2 48 16"' +
      ' xmlns="http://www.w3.org/2000/svg" aria-hidden="true">' +
      '<text x="24" y="4.6" text-anchor="middle" textLength="48"' +
      ' lengthAdjust="spacingAndGlyphs"' +
      ' font-family="Montserrat, sans-serif" font-weight="600"' +
      ' font-size="6.5" letter-spacing="-0.1">' +
      '<tspan fill="#F0F0F5">homefit</tspan>' +
      '<tspan fill="#FF6B35">.studio</tspan>' +
      '</text>' +
      homefitMatrixBody(4.5) +
      '</svg>'
    );
  }

  // Expose on the global object so plain scripts (app.js, lobby.js,
  // handout.js) reach them without a bundler.
  window.buildHomefitLogoSvg = buildHomefitLogoSvg;
  window.buildHomefitLogoLockupSvg = buildHomefitLogoLockupSvg;
})();
