'use client';

import { useCallback, useEffect, useRef, useState } from 'react';
import QRCode from 'qrcode';
import { toBlob } from 'html-to-image';

import { createPortalShareKitApi } from '@/lib/supabase/api';
import { getBrowserClient } from '@/lib/supabase-browser';

// DOM-render dimensions — the preview box in the live page. 432×540 is
// 4:5 at a density that fits the /network grid column on desktop while
// still staying readable. html-to-image reads these via the `style:
// { width, height }` snapshot option so the output is consistent even
// when the rendered element is shrunk by its flex parent.
const CARD_WIDTH = 432;
const CARD_HEIGHT = 540;

// Export dimensions — 1080×1350 is locked in the Wave 10 brief (portrait
// crop safe for WhatsApp status, Instagram story, LinkedIn). The
// html-to-image call upscales the DOM output to exactly these numbers via
// `canvasWidth` / `canvasHeight`.
const EXPORT_WIDTH = 1080;
const EXPORT_HEIGHT = 1350;

/**
 * PngShareCard — Wave 10 Phase 3.
 *
 * Renders the downloadable 1080×1350 share card in the DOM using real
 * React + Tailwind (same CSS the mockup uses), then rasterises the
 * rendered element to a PNG on click via `html-to-image`. The same
 * blob powers both "Download PNG" (saves a file) and "Copy image to
 * clipboard" (for paste-into-WhatsApp-status on desktop).
 *
 * **Why client-side canvas?** Simpler for Wave 10. Server-side
 * Edge-Function rasterisation is the Wave 14 backlog item if client
 * perf becomes a problem at scale. For now, `html-to-image` gives us
 * WYSIWYG rendering without font-embedding drama — the preview IS the
 * PNG source. The `canvasWidth` / `pixelRatio` multiplier snaps the
 * exported image to 1080×1350 regardless of the rendered pixel size on
 * the user's screen.
 *
 * **QR:** rendered via the `qrcode` npm package to a data URL at mount
 * time (useEffect). `errorCorrectionLevel: 'M'` is the middle-ground
 * default; margin: 0 because the white card background already gives
 * the scanner enough quiet zone.
 *
 * **Fonts:** Montserrat + Inter load via `/layout.tsx` as a Google
 * Fonts stylesheet. We `await document.fonts.ready` before rasterising
 * so the PNG picks up the custom faces instead of falling back to
 * system-ui mid-render.
 *
 * **Analytics:** on each button click, fire-and-forget a `log_share_event`
 * row via `PortalShareKitApi`. Failure is swallowed — the share must
 * not break if telemetry is down.
 *
 * **Clipboard fallback:** `navigator.clipboard.write([new ClipboardItem])`
 * is supported everywhere modern (Chrome 76+, Edge, Firefox 127+, Safari
 * 16+). Older Safari throws; we catch and surface a toast directing the
 * user to the Download button.
 */

type Props = {
  practiceId: string;
  practitionerName: string;
  practiceName: string;
  referralCode: string | null;
  referralLink: string;
};

export function PngShareCard({
  practiceId,
  practitionerName,
  practiceName,
  referralCode,
  referralLink,
}: Props) {
  const cardRef = useRef<HTMLDivElement | null>(null);
  const [qrDataUrl, setQrDataUrl] = useState<string | null>(null);
  const [toast, setToast] = useState<string | null>(null);
  const [busy, setBusy] = useState<'download' | 'clipboard' | null>(null);

  // Build the QR code once per referralLink change. `qrcode` is synchronous
  // enough to run in an effect — the call resolves in <1ms for typical URLs.
  useEffect(() => {
    let cancelled = false;
    QRCode.toDataURL(referralLink, {
      errorCorrectionLevel: 'M',
      margin: 0,
      width: 400,
      color: { dark: '#0c0e14', light: '#ffffff' },
    })
      .then((url) => {
        if (!cancelled) setQrDataUrl(url);
      })
      .catch(() => {
        // Leave qrDataUrl null — the preview will render an empty white
        // slot with an accessible label, and download still works (the
        // PNG just won't have a QR). Better than crashing the page.
      });
    return () => {
      cancelled = true;
    };
  }, [referralLink]);

  // Auto-dismiss toasts after 2.4s so they don't stack behind the copy
  // button's own in-card toast.
  useEffect(() => {
    if (!toast) return;
    const id = window.setTimeout(() => setToast(null), 2400);
    return () => window.clearTimeout(id);
  }, [toast]);

  // Filename builder — `homefit-share-<kebab-case>.png`. Matches the
  // annotation in the mockup. Falls back to "share" when the name is
  // empty so we never emit `homefit-share-.png`.
  const downloadFilename = useCallback(() => {
    const kebab = (practitionerName || 'share')
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, '-')
      .replace(/^-+|-+$/g, '') || 'share';
    return `homefit-share-${kebab}.png`;
  }, [practitionerName]);

  // Shared rasterisation step — returns a 1080×1350 PNG Blob.
  //
  // html-to-image composition:
  //   1. `width: CARD_WIDTH, height: CARD_HEIGHT` tells the lib the
  //      source box is 432×540 — matches the DOM element's intrinsic
  //      size even when the parent flex layout shrinks it.
  //   2. `canvasWidth: EXPORT_WIDTH, canvasHeight: EXPORT_HEIGHT`
  //      snaps the emitted PNG to exactly 1080×1350. This is the Wave
  //      10 brief's locked export size.
  //   3. `style: { width, height }` seeds the cloned node's inline
  //      style so the internal SVG foreignObject stage has unambiguous
  //      dimensions, regardless of the parent grid's constraints on
  //      the live element.
  //
  // pixelRatio is LEFT AT 1 on purpose — when `canvasWidth` is set,
  // html-to-image treats pixelRatio as a multiplier ON TOP of that,
  // so a 2.5 ratio produces a 2700×3375 PNG. The brief locks 1080×1350.
  const rasterise = useCallback(async (): Promise<Blob | null> => {
    const el = cardRef.current;
    if (!el) return null;
    // Ensure Google Fonts are actually ready before we snapshot — if we
    // rasterise before Montserrat + Inter finish loading, the PNG
    // silently falls back to system-ui which reads "off" against the
    // preview.
    try {
      await document.fonts.ready;
    } catch {
      // document.fonts not available (very old browser) — press on.
    }
    const blob = await toBlob(el, {
      width: CARD_WIDTH,
      height: CARD_HEIGHT,
      canvasWidth: EXPORT_WIDTH,
      canvasHeight: EXPORT_HEIGHT,
      pixelRatio: 1,
      cacheBust: true,
      // Background colour matches the card's outermost fill so rounded
      // corners don't show through as transparent.
      backgroundColor: '#0c0e14',
      // Skip web-font embedding — the fonts (Inter + Montserrat) are
      // loaded from Google Fonts as cross-origin stylesheets, and
      // html-to-image's `getCSSRules` can't read them due to CORS (it
      // logs "Error inlining remote css file"). The rendered PNG still
      // picks up the right faces because foreignObject honors the
      // page's `font-family` cascade — we just don't get bitmap-baked
      // @font-face rules in the SVG. Cleaner than CSP relaxation.
      skipFonts: true,
      style: {
        width: `${CARD_WIDTH}px`,
        height: `${CARD_HEIGHT}px`,
      },
    });
    return blob;
  }, []);

  // Log a fire-and-forget share_event row. Never awaited at the click
  // callsite — analytics must never block the UX.
  const logEvent = useCallback(
    (eventKind: 'download' | 'clipboard_image', channel: 'png_download' | 'png_clipboard') => {
      const supabase = getBrowserClient();
      const api = createPortalShareKitApi(supabase);
      void api.logEvent(practiceId, channel, eventKind, {
        code: referralCode,
      });
    },
    [practiceId, referralCode],
  );

  async function handleDownload() {
    if (busy) return;
    setBusy('download');
    logEvent('download', 'png_download');
    try {
      const blob = await rasterise();
      if (!blob) {
        setToast('Download failed — try again.');
        return;
      }
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = downloadFilename();
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      // Revoke on next frame so the browser has time to kick off the
      // download before the blob URL is invalidated.
      requestAnimationFrame(() => URL.revokeObjectURL(url));
      setToast('PNG saved');
    } catch {
      setToast('Download failed — try again.');
    } finally {
      setBusy(null);
    }
  }

  async function handleCopyImage() {
    if (busy) return;
    setBusy('clipboard');
    logEvent('clipboard_image', 'png_clipboard');
    try {
      // Feature-detect ClipboardItem — Safari before 16 lacks it.
      if (typeof window.ClipboardItem === 'undefined') {
        setToast('Copy not supported on this browser — use Download instead.');
        return;
      }
      const blob = await rasterise();
      if (!blob) {
        setToast('Copy failed — try again.');
        return;
      }
      const item = new window.ClipboardItem({ 'image/png': blob });
      await navigator.clipboard.write([item]);
      setToast('Image copied');
    } catch {
      setToast('Copy not supported — use Download instead.');
    } finally {
      setBusy(null);
    }
  }

  // Display values. The mockup's hero URL is rendered without scheme; the
  // code chip uses the raw code. Both fall back to sensible placeholders
  // so the preview is never empty while the RPC resolves.
  const displayUrl = referralLink.replace(/^https?:\/\//, '');
  const displayCode = referralCode ?? '·······';

  return (
    <>
      <div
        className="rounded-lg border border-surface-border bg-surface-base p-8 lg:grid lg:grid-cols-[minmax(0,1.5fr)_minmax(240px,1fr)] lg:items-center lg:gap-8"
      >
        {/* The card preview — rendered in React + Tailwind so the
            exported PNG uses the exact same DOM. The outer div scrolls
            horizontally on narrow viewports so the fixed-width card
            doesn't explode the page layout; the card itself stays
            CARD_WIDTH × CARD_HEIGHT so html-to-image always snapshots
            the same box. */}
        <div className="flex justify-center overflow-x-auto">
          <div
            ref={cardRef}
            // Fixed dimensions so html-to-image captures a predictable
            // box even when the parent grid column shrinks. The export
            // is snapped to 1080×1350 via canvasWidth/canvasHeight, so
            // the DOM size is "big enough to render sharp" rather than
            // "equals the output".
            style={{
              width: CARD_WIDTH,
              height: CARD_HEIGHT,
              minWidth: CARD_WIDTH,
              background:
                'radial-gradient(80% 60% at 20% 10%, rgba(255, 107, 53, 0.28) 0%, rgba(255, 107, 53, 0.02) 50%, transparent 100%), radial-gradient(60% 40% at 90% 100%, rgba(255, 107, 53, 0.14) 0%, transparent 70%), linear-gradient(180deg, #151824 0%, #0c0e14 100%)',
            }}
            className="relative flex flex-col overflow-hidden rounded-[20px] border border-surface-border p-[40px_36px] text-ink"
            role="img"
            aria-label={`homefit.studio share card for ${practitionerName}${referralCode ? `, code ${referralCode}` : ''}`}
          >
            {/* Grid overlay — the subtle coral cross-hatch. */}
            <div
              aria-hidden="true"
              className="pointer-events-none absolute inset-0"
              style={{
                backgroundImage:
                  'linear-gradient(rgba(255, 107, 53, 0.04) 1px, transparent 1px), linear-gradient(90deg, rgba(255, 107, 53, 0.04) 1px, transparent 1px)',
                backgroundSize: '28px 28px',
                maskImage:
                  'linear-gradient(180deg, transparent, black 20%, black 80%, transparent)',
                WebkitMaskImage:
                  'linear-gradient(180deg, transparent, black 20%, black 80%, transparent)',
              }}
            />

            {/* Top — logo + wordmark */}
            <div className="relative z-10 flex items-center gap-[10px]">
              <MatrixLogo />
              <span className="font-heading text-[16px] font-bold -tracking-[0.2px] text-ink">
                homefit.studio
              </span>
            </div>

            {/* Mid — practitioner name + tagline, pushed to bottom of column */}
            <div className="relative z-10 mt-auto">
              <div className="mb-2 font-sans text-[10px] font-semibold uppercase leading-none text-brand" style={{ letterSpacing: '1.2px' }}>
                Your practitioner
              </div>
              <h3 className="m-0 font-heading text-[30px] font-extrabold leading-[1.1] -tracking-[0.5px] text-ink">
                {practitionerName}
              </h3>
              <p className="m-0 font-sans text-[13px] leading-snug text-ink-muted">
                {practiceName}
              </p>

              <p className="mt-7 max-w-[88%] font-heading text-[18px] font-bold leading-[1.35] -tracking-[0.2px] text-ink">
                Plans your client will{' '}
                <span className="text-brand">love and follow</span>.
                <br />
                Ready before they leave.
              </p>
            </div>

            {/* Bottom — QR + URL block */}
            <div className="relative z-10 mt-7 flex items-center gap-4">
              <div
                className="flex h-[88px] w-[88px] flex-shrink-0 items-center justify-center rounded-[6px] bg-white p-[6px]"
                aria-hidden="true"
              >
                {qrDataUrl ? (
                  /* eslint-disable-next-line @next/next/no-img-element */
                  <img
                    src={qrDataUrl}
                    alt=""
                    className="h-full w-full"
                    draggable={false}
                  />
                ) : null}
              </div>
              <div className="min-w-0">
                <div className="mb-0.5 font-sans text-[10px] uppercase leading-none text-ink-muted" style={{ letterSpacing: '0.5px' }}>
                  Scan or visit
                </div>
                <div className="break-all font-mono text-[13px] font-semibold leading-tight text-brand" style={{ letterSpacing: '0.2px' }}>
                  {displayUrl}
                </div>
                <div
                  className="mt-1.5 inline-flex items-center gap-1.5 rounded-full border border-brand-tint-border bg-brand-tint-bg px-2.5 py-1 font-mono text-[11px] text-brand-light"
                  style={{ letterSpacing: '0.6px' }}
                >
                  CODE · {displayCode}
                </div>
              </div>
            </div>
          </div>
        </div>

        {/* Right-side CTAs + copy */}
        <div className="mt-6 flex flex-col gap-4 lg:mt-0">
          <div className="text-[11px] font-semibold uppercase tracking-wider text-brand">
            1080 × 1350 · PNG
          </div>
          <h3 className="m-0 font-heading text-xl font-bold tracking-tight">
            Downloadable share card
          </h3>
          <p className="m-0 text-sm text-ink-muted">
            Portrait crop works for WhatsApp status, Instagram story, and
            most LinkedIn embeds. Use it as a chat sticker, print it on a
            flyer, drop it into your email signature.
          </p>

          <div className="mt-1 flex flex-wrap gap-3">
            <button
              type="button"
              onClick={handleDownload}
              disabled={!!busy}
              className="inline-flex h-10 items-center justify-center gap-2 rounded-full bg-brand px-4 text-sm font-semibold text-surface-bg transition duration-fast ease-standard hover:bg-brand-light focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand/40 disabled:cursor-not-allowed disabled:opacity-60"
              aria-label="Download share card as PNG"
            >
              <DownloadGlyph />
              {busy === 'download' ? 'Saving...' : 'Download PNG'}
            </button>
            <button
              type="button"
              onClick={handleCopyImage}
              disabled={!!busy}
              className="inline-flex h-10 items-center justify-center gap-2 rounded-full border border-surface-border bg-transparent px-4 text-sm font-semibold text-ink transition duration-fast ease-standard hover:border-brand-tint-border hover:text-brand-light focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand/40 disabled:cursor-not-allowed disabled:opacity-60"
              aria-label="Copy share card image to clipboard"
            >
              <CopyImageGlyph />
              {busy === 'clipboard' ? 'Copying...' : 'Copy to clipboard'}
            </button>
          </div>
          <div className="font-mono text-[11px] uppercase tracking-wider text-ink-dim">
            Filename: {downloadFilename()}
          </div>
        </div>
      </div>

      {/* Shared live-region toast. Positioned the same way as the text
          copy toasts in <CopyButton/> so they feel like the same system. */}
      {toast && (
        <div
          role="status"
          aria-live="polite"
          className="pointer-events-none fixed inset-x-0 top-4 z-50 flex justify-center px-4"
        >
          <div className="pointer-events-auto rounded-md border border-surface-border bg-surface-raised px-4 py-3 text-sm text-ink shadow-focus-ring">
            {toast}
          </div>
        </div>
      )}
    </>
  );
}

/**
 * HomefitLogo v2 — matrix-only, inlined so the PNG export is fully
 * self-contained (no external SVG requests at rasterisation time).
 * Matches `docs/design/mockups/network-share-kit.html` viewBox exactly.
 * Display size 120×24 per the mockup `.png-card-top svg` rule.
 */
function MatrixLogo() {
  return (
    <svg
      viewBox="0 0 48 9.5"
      width={120}
      height={24}
      aria-hidden="true"
      xmlns="http://www.w3.org/2000/svg"
      style={{ filter: 'drop-shadow(0 0 12px rgba(255, 107, 53, 0.4))' }}
    >
      <rect x="0" y="2.75" width="2.5" height="1.5" rx="0.5" fill="#4B5563" />
      <rect x="4" y="2.45" width="3.5" height="2.1" rx="0.7" fill="#6B7280" />
      <rect x="9" y="2.15" width="4.5" height="2.7" rx="0.9" fill="#9CA3AF" />
      <rect x="14.5" y="1" width="12.5" height="8.5" rx="1.2" fill="#FF6B35" opacity="0.15" />
      <rect x="15" y="2" width="5" height="3" rx="1" fill="#FF6B35" />
      <rect x="15" y="6.5" width="5" height="3" rx="1" fill="#FF6B35" />
      <rect x="21.5" y="2" width="5" height="3" rx="1" fill="#FF6B35" />
      <rect x="21.5" y="6.5" width="5" height="3" rx="1" fill="#FF6B35" />
      <rect x="28" y="2" width="5" height="3" rx="1" fill="#86EFAC" />
      <rect x="34.5" y="2.15" width="4.5" height="2.7" rx="0.9" fill="#9CA3AF" />
      <rect x="40.5" y="2.45" width="3.5" height="2.1" rx="0.7" fill="#6B7280" />
      <rect x="45.5" y="2.75" width="2.5" height="1.5" rx="0.5" fill="#4B5563" />
    </svg>
  );
}

function DownloadGlyph() {
  return (
    <svg
      viewBox="0 0 14 14"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.6"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      className="h-3.5 w-3.5"
    >
      <path d="M7 1.5v8M3.5 6 7 9.5 10.5 6M2 12h10" />
    </svg>
  );
}

function CopyImageGlyph() {
  return (
    <svg
      viewBox="0 0 14 14"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.6"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      className="h-3.5 w-3.5"
    >
      <rect x="2" y="2" width="10" height="10" rx="1.5" />
      <path d="M10 5L5 10M4.5 4.5h0M9.5 9.5h0" />
    </svg>
  );
}
