import { ImageResponse } from 'next/og';
import { getServerClient } from '@/lib/supabase-server';
import { PortalReferralApi } from '@/lib/supabase/api';

// Dynamic Open Graph image for /r/{code}. This is what unfurls in
// WhatsApp, iMessage, Twitter, LinkedIn, etc. when the practitioner
// shares their referral link. The landing page's shareability — and
// the whole top-of-funnel — depends on this card.
//
// Next.js 15's built-in ImageResponse (next/og) compiles to an Edge
// function, no `@vercel/og` install required.

export const runtime = 'edge';
export const contentType = 'image/png';
export const size = { width: 1200, height: 630 };
export const alt = 'Invitation to homefit.studio';

const BRAND = '#FF6B35';
const BRAND_LIGHT = '#FF8F5E';
const BG = '#0F1117';
const INK = '#F0F0F5';
const INK_MUTED = '#9CA3AF';
const SURFACE_BASE = '#1A1D27';
const BORDER = '#2E3140';

// HomefitLogo geometry (see components/HomefitLogo.tsx for the shared
// component; @vercel/og can't import components so we re-emit the
// shape inline here). Source of truth: web-player/app.js's
// buildHomefitLogoSvg() and app/lib/widgets/homefit_logo.dart.
// v2 matrix (signed off at docs/design/mockups/logo-ghost-outer.html):
// 3 ghost pills taper in → 2×2 circuit in a coral band → sage rest →
// 3 ghost pills mirrored. Matrix-only variant — the OG card renders
// the "homefit.studio" text wordmark next to it.
const SAGE = '#86EFAC';
const BAND_TINT = 'rgba(255, 107, 53, 0.15)';
const GHOST_OUTER = '#4B5563';
const GHOST_MID = '#6B7280';
const GHOST_INNER = '#9CA3AF';

async function loadInviter(code: string): Promise<string> {
  try {
    const supabase = await getServerClient();
    const api = new PortalReferralApi(supabase);
    const meta = await api.landingMeta(code);
    return meta.inviter_display_name ?? 'A homefit.studio practitioner';
  } catch {
    return 'A homefit.studio practitioner';
  }
}

export default async function OgImage({
  params,
}: {
  params: { code: string };
}) {
  const inviter = await loadInviter(params.code);

  return new ImageResponse(
    (
      <div
        style={{
          width: '100%',
          height: '100%',
          background: BG,
          display: 'flex',
          flexDirection: 'column',
          padding: '80px',
          fontFamily: 'sans-serif',
          position: 'relative',
        }}
      >
        {/* Brand mark row */}
        <div
          style={{
            display: 'flex',
            alignItems: 'center',
            gap: '20px',
          }}
        >
          <svg
            width="160"
            height="32"
            viewBox="0 0 48 9.5"
            xmlns="http://www.w3.org/2000/svg"
          >
            {/* Left ghost pills: outer→inner, progressively larger + lighter */}
            <rect x="0"    y="2.75" width="2.5" height="1.5" rx="0.5" fill={GHOST_OUTER} />
            <rect x="4"    y="2.45" width="3.5" height="2.1" rx="0.7" fill={GHOST_MID} />
            <rect x="9"    y="2.15" width="4.5" height="2.7" rx="0.9" fill={GHOST_INNER} />
            {/* Coral tint band behind circuit columns */}
            <rect x="14.5" y="1"    width="12.5" height="8.5" rx="1.2" fill={BAND_TINT} />
            {/* Circuit pills 2×2 — solid coral */}
            <rect x="15"   y="2"    width="5" height="3" rx="1" fill={BRAND} />
            <rect x="15"   y="6.5"  width="5" height="3" rx="1" fill={BRAND} />
            <rect x="21.5" y="2"    width="5" height="3" rx="1" fill={BRAND} />
            <rect x="21.5" y="6.5"  width="5" height="3" rx="1" fill={BRAND} />
            {/* Rest — sage */}
            <rect x="28"   y="2"    width="5" height="3" rx="1" fill={SAGE} />
            {/* Right ghost pills: inner→outer, mirror of left */}
            <rect x="34.5" y="2.15" width="4.5" height="2.7" rx="0.9" fill={GHOST_INNER} />
            <rect x="40.5" y="2.45" width="3.5" height="2.1" rx="0.7" fill={GHOST_MID} />
            <rect x="45.5" y="2.75" width="2.5" height="1.5" rx="0.5" fill={GHOST_OUTER} />
          </svg>
          <div
            style={{
              fontSize: 36,
              fontWeight: 600,
              color: INK,
              letterSpacing: '-0.01em',
            }}
          >
            homefit.studio
          </div>
        </div>

        {/* Eyebrow pill */}
        <div
          style={{
            marginTop: 72,
            display: 'flex',
            alignSelf: 'flex-start',
            padding: '8px 18px',
            borderRadius: 9999,
            background: 'rgba(255, 107, 53, 0.12)',
            border: `1px solid rgba(255, 107, 53, 0.30)`,
            color: BRAND_LIGHT,
            fontSize: 22,
            fontWeight: 600,
            textTransform: 'uppercase',
            letterSpacing: '0.12em',
          }}
        >
          Invitation
        </div>

        {/* Headline */}
        <div
          style={{
            marginTop: 32,
            display: 'flex',
            fontSize: 72,
            fontWeight: 800,
            lineHeight: 1.05,
            color: INK,
            letterSpacing: '-0.03em',
            maxWidth: 1040,
          }}
        >
          {truncateName(inviter)} invited you to homefit.studio.
        </div>

        {/* Sub */}
        <div
          style={{
            marginTop: 24,
            display: 'flex',
            fontSize: 30,
            lineHeight: 1.3,
            color: INK_MUTED,
            maxWidth: 960,
          }}
        >
          Capture a session. Share a clean visual plan with your client via WhatsApp.
        </div>

        {/* Footer: code badge */}
        <div
          style={{
            position: 'absolute',
            bottom: 60,
            left: 80,
            right: 80,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
          }}
        >
          <div
            style={{
              display: 'flex',
              alignItems: 'center',
              padding: '14px 24px',
              borderRadius: 14,
              background: SURFACE_BASE,
              border: `1px solid ${BORDER}`,
              fontSize: 24,
              fontFamily: 'monospace',
              color: INK,
            }}
          >
            manage.homefit.studio/r/{params.code}
          </div>
          <div
            style={{
              display: 'flex',
              color: INK_MUTED,
              fontSize: 22,
            }}
          >
            Tap to get started
          </div>
        </div>
      </div>
    ),
    { ...size },
  );
}

/** Keep very long practice names from overflowing the 1200px card. */
function truncateName(name: string): string {
  const MAX = 48;
  if (name.length <= MAX) return name;
  return `${name.slice(0, MAX - 1).trimEnd()}\u2026`;
}
