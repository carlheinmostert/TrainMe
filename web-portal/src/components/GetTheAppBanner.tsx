import QRCode from 'qrcode';
import { HomefitLogo } from '@/components/HomefitLogo';
import { APP_STORE_URL, APP_STORE_LABEL } from '@/lib/links';
import { AppStoreBadge } from '@/components/AppStoreBadge';

/**
 * GetTheAppBanner — loud coral banner that nudges fresh practitioners
 * to install the iOS app. C-13 of the 2026-05-22 portal cosmetics
 * stack; Carl-approved Variant A from
 * `docs/design/mockups/portal-get-the-app.html`.
 *
 * Auto-dismissal: rendered conditionally by the dashboard page based
 * on whether the practice has any plan_issuances (proxied through the
 * audit-card query). Once a practice has published, the banner stops
 * rendering on subsequent dashboard loads. There is no manual dismiss
 * affordance — Carl's call: the heuristic is "you've done the thing
 * the banner asks about, so it's no longer relevant".
 *
 * Persistent affordance: even after this banner stops showing, the
 * `/account` page has an "Apps" section that surfaces the same App
 * Store badge + QR code, so a returning user on a new device can
 * always find the install link.
 *
 * QR code is generated at request time via the `qrcode` npm package
 * and rendered inline as SVG — no client-side runtime cost, no
 * external image fetch. The banner is a server component so the QR
 * generation runs once per request and the resulting HTML is part of
 * the dashboard's streamed response.
 */
export async function GetTheAppBanner() {
  // Generate the QR code as an SVG string at request time. The `qrcode`
  // package returns an `<svg>` payload we can drop straight into the
  // popover. `margin: 1` removes the default 4-module quiet zone so the
  // QR fills the popover's white frame.
  const qrSvg = await QRCode.toString(APP_STORE_URL, {
    type: 'svg',
    errorCorrectionLevel: 'M',
    margin: 1,
    color: {
      dark: '#0F1117',
      light: '#FFFFFF',
    },
  });

  return (
    <section
      aria-label="Get the iOS app"
      className="mb-6 rounded-xl border border-brand-tint-border bg-[linear-gradient(135deg,rgba(255,107,53,0.18)_0%,rgba(255,107,53,0.04)_60%)] p-5 sm:px-6"
    >
      {/* Desktop / wide layout: glyph + copy + badge + QR in a row.
          Mobile (< 640px): stacks vertically — glyph + copy on row 1,
          badge + QR on row 2. */}
      <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:gap-5">
        {/* Glyph + copy block — always grouped together so the headline
            stays adjacent to the matrix mark. */}
        <div className="flex flex-1 items-center gap-4">
          <div
            aria-hidden="true"
            className="flex h-14 w-14 shrink-0 items-center justify-center overflow-hidden rounded-xl border border-surface-border bg-surface-bg"
          >
            <HomefitLogo className="h-7 w-7" />
          </div>
          <div className="flex min-w-0 flex-1 flex-col">
            <p className="font-heading text-[17px] font-bold leading-tight tracking-tight text-ink">
              Get the iOS app to start capturing sessions
            </p>
            <p className="mt-1 text-[13px] leading-snug text-ink-muted">
              Clients and Classes live in the app — the portal only
              manages your account, credits, and audit log.{' '}
              <span className="ml-1 inline-flex items-center rounded border border-surface-border px-1.5 py-0.5 align-middle text-[11.5px] font-medium uppercase tracking-wider text-ink-dim">
                Android coming soon
              </span>
            </p>
          </div>
        </div>

        {/* Badge + QR cluster. On mobile this row sits below the copy;
            on desktop it sits to the right of it. */}
        <div className="flex items-center gap-3">
          <AppStoreBadge href={APP_STORE_URL} label={APP_STORE_LABEL} />
          <QrPopoverTrigger qrSvg={qrSvg} />
        </div>
      </div>
    </section>
  );
}

/**
 * QrPopoverTrigger — 40px square button that reveals a QR popover on
 * hover/focus. The popover stays open while the user moves the mouse
 * between the button and the popover (CSS group-hover). On touch
 * viewports it opens on focus (tab) since hover doesn't exist.
 *
 * The popover sits absolutely positioned beneath the trigger,
 * top-aligned with a small triangle indicator per the mockup's
 * `.qr-pop::before` rule. The QR SVG is embedded inline so there's
 * no extra network round-trip.
 */
function QrPopoverTrigger({ qrSvg }: { qrSvg: string }) {
  return (
    <div className="group/qr relative">
      <button
        type="button"
        aria-label="Show QR code to install on iPhone"
        aria-haspopup="dialog"
        className="flex h-10 w-10 items-center justify-center rounded-md border border-surface-border bg-surface-raised text-ink-muted transition hover:border-brand-tint-border hover:text-ink focus:outline-none focus-visible:border-brand focus-visible:text-ink"
      >
        <QrGlyph />
      </button>

      {/* Popover. Hidden by default; revealed on hover of the group OR
          on focus of the button (`:focus-within` on the group). On
          mobile / touch, focus-after-tap surfaces the popover. */}
      <div
        role="dialog"
        aria-label="QR code for the iOS app"
        className="pointer-events-none invisible absolute right-0 top-[calc(100%+10px)] z-30 w-[180px] rounded-lg border border-surface-border bg-surface-raised p-3 opacity-0 shadow-[0_16px_36px_rgba(0,0,0,0.6)] transition-opacity duration-150 group-hover/qr:pointer-events-auto group-hover/qr:visible group-hover/qr:opacity-100 group-focus-within/qr:pointer-events-auto group-focus-within/qr:visible group-focus-within/qr:opacity-100"
      >
        {/* Triangle indicator pointing up at the trigger button.
            Sits inside the popover and rotates 45deg to create the
            arrow tail. Borrowed from the mockup's `.qr-pop::before`. */}
        <span
          aria-hidden="true"
          className="absolute -top-[7px] right-4 h-3 w-3 rotate-45 border-l border-t border-surface-border bg-surface-raised"
        />

        <div
          className="overflow-hidden rounded bg-white p-1.5"
          // QR is server-rendered SVG — safe to inline. `dangerouslySetInnerHTML`
          // is the standard React way to drop pre-built SVG markup; the
          // string is generated from a constant URL we control, not user input.
          dangerouslySetInnerHTML={{ __html: qrSvg }}
        />
        <p className="mt-2 text-center text-[11px] text-ink-muted">
          Scan with your iPhone camera
        </p>
      </div>
    </div>
  );
}

/** Pure-CSS QR mini-glyph for the trigger button — a 3-corner pattern
 *  that telegraphs "scannable code" without needing a separate icon
 *  asset. Geometry mirrors the mockup's `.qr-mini` background. */
function QrGlyph() {
  return (
    <svg
      width="20"
      height="20"
      viewBox="0 0 20 20"
      aria-hidden="true"
      fill="currentColor"
    >
      {/* Three corner finder squares (top-left, top-right, bottom-left)
          with a small inner cut-out so they read as QR finders. */}
      <path d="M0 0h7v7H0V0zm1.5 1.5v4h4v-4h-4z" />
      <path d="M13 0h7v7h-7V0zm1.5 1.5v4h4v-4h-4z" />
      <path d="M0 13h7v7H0v-7zm1.5 1.5v4h4v-4h-4z" />
      {/* Centre dot for the three finders. */}
      <rect x="2.5" y="2.5" width="2" height="2" />
      <rect x="15.5" y="2.5" width="2" height="2" />
      <rect x="2.5" y="15.5" width="2" height="2" />
      {/* Scattered data modules in the bottom-right quadrant — purely
          decorative, just enough to read as a real QR. */}
      <rect x="10" y="10" width="2" height="2" />
      <rect x="14" y="10" width="2" height="2" />
      <rect x="10" y="14" width="2" height="2" />
      <rect x="14" y="14" width="2" height="2" />
      <rect x="17" y="13" width="2" height="2" />
      <rect x="12" y="17" width="2" height="2" />
      <rect x="16" y="17" width="2" height="2" />
    </svg>
  );
}
