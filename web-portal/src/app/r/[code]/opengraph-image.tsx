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

// SVG path data for the Pulse Mark (shared with theme.ts).
const PULSE_MARK_PATH =
  'M2.6 25.2 L13 25.2 L18.2 7.2 L26 28.8 L33.8 7.2 L39 25.2 L49.4 25.2';

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
            width="84"
            height="58"
            viewBox="0 0 52 36"
            xmlns="http://www.w3.org/2000/svg"
          >
            <path
              d={PULSE_MARK_PATH}
              fill="none"
              stroke={BRAND}
              strokeWidth="3"
              strokeLinecap="round"
              strokeLinejoin="round"
            />
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
