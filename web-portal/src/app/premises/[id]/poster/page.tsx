import { cookies, headers } from 'next/headers';
import { notFound, redirect } from 'next/navigation';
import { getServerClient } from '@/lib/supabase-server';
import { createPortalApi } from '@/lib/supabase/api';
import { playerOriginFromHost } from '@/lib/env';
import { HomefitLogoLockup } from '@/components/HomefitLogo';
import QRCode from 'qrcode';

type RouteParams = { id: string };
type SearchParams = { print?: string };

/**
 * `/premises/[id]/poster` — Safe Mode Transparency printable A4 poster.
 *
 * Renders the venue-facing poster the owner prints and tapes up at
 * reception. The QR code encodes `https://session.homefit.studio/v/{slug}/now`.
 *
 * Visiting with `?print=1` auto-fires `window.print()` on load so the
 * "Download poster" button in the premises editor flows straight into
 * the browser's print-to-PDF dialog. Visiting without it = preview.
 *
 * Owner-authenticated: anyone but a practice member sees 404.
 *
 * Spec: docs/specs/2026-05-22-safe-mode-transparency.md
 */
export default async function PosterPage({
  params,
  searchParams,
}: {
  params: Promise<RouteParams>;
  searchParams: Promise<SearchParams>;
}) {
  const supabase = await getServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect('/');

  const api = createPortalApi(supabase);
  const [{ id }, query] = await Promise.all([params, searchParams]);
  const premises = await api.getPremises(id);
  if (!premises) notFound();

  const profile = await api.getPracticePublicProfile(premises.practiceId);
  if (!profile) notFound();

  // Resolve the live page URL the QR encodes. The URL is per-premises:
  // `/v/{practice-slug}/{premises-slug}/now`. Falls back to a clearly
  // placeholder URL when either slug is missing — the QR still scans
  // but lands on a "not found" page; the warning banner below tells
  // the owner what to fix.
  const reqHeaders = await headers();
  const playerOrigin = playerOriginFromHost(reqHeaders.get('host'));
  const practiceSlug = profile.slug ?? '';
  const premisesSlug = premises.publicSlug ?? '';
  const slugMissing = !practiceSlug || !premisesSlug;
  const liveUrl = slugMissing
    ? `${playerOrigin}/v/${practiceSlug || 'your-practice'}/${premisesSlug || 'your-premises'}/now`
    : `${playerOrigin}/v/${practiceSlug}/${premisesSlug}/now`;

  // Stamp first_poster_downloaded_at on ?print=1 — this is the contract
  // that locks the slug for printed QR codes. Fire-and-forget; never
  // blocks the render. Idempotent server-side (only stamps when NULL).
  const shouldStampDownload = searchParamsPrint(query) && !slugMissing;

  // Render the QR as an inline SVG string. errorCorrectionLevel 'M'
  // is enough for the on-paper scan distance; margin 2 leaves the
  // canonical quiet zone the spec needs.
  const qrSvg = await QRCode.toString(liveUrl, {
    type: 'svg',
    errorCorrectionLevel: 'M',
    margin: 2,
    width: 220,
    color: { dark: '#0F1117', light: '#FFFFFF' },
  });

  const shouldAutoPrint = query.print === '1';
  const practiceName = profile.practiceName || 'Practice';
  const venueLine = premises.name || '';
  const address = premises.address || '';

  // Lock the slug for printed posters. Fire-and-forget so a vault /
  // RPC hiccup never blocks the print dialog.
  if (shouldStampDownload) {
    void api.markPosterDownloaded(id).catch(() => undefined);
  }

  return (
    <>
      {/* Tailwind's preflight doesn't fight us here — the poster owns
          its layout via inline styles + a single <style> block scoped
          to .poster-root so this route doesn't leak into the rest of
          the portal. */}
      <style
        // eslint-disable-next-line react/no-danger
        dangerouslySetInnerHTML={{
          __html: posterCss,
        }}
      />

      <div className="poster-root">
        {slugMissing && (
          <div className="poster-warning">
            <strong>
              {!practiceSlug
                ? 'Set a public practice slug first.'
                : 'Set a public premises slug first.'}
            </strong>{' '}
            {!practiceSlug
              ? 'Open /public-profile and pick a slug for your practice — without it, the QR code on this poster won’t resolve to a real live page.'
              : 'Open the premises editor and confirm the public URL slug — without it, the QR code on this poster won’t resolve to a real live page.'}
          </div>
        )}

        <div className="poster-page">
          <div className="poster-header">
            {/* Top brand mark — "powered by" sits to the LEFT of the
                lockup, both at the same vertical baseline. Doubled
                from 120px → 240px so the mark reads as a substantial
                anchor at A4 viewing distance, paired with the
                bottom-right footer at the same scale so the
                top-and-tail framing is symmetric. The lockup itself
                is the print variant — homefit ink-dark, .studio coral.
                Single source of truth: web-portal/src/components/
                HomefitLogo.tsx. */}
            <div className="poster-powered-inline">
              <div className="poster-powered">powered by</div>
              <HomefitLogoLockup className="poster-lockup-hero" print />
            </div>
            <div className="poster-practice">
              <div className="poster-practice-name">{practiceName}</div>
              {(venueLine || address) && (
                <div className="poster-practice-loc">
                  {[venueLine, address].filter(Boolean).join(' · ')}
                </div>
              )}
            </div>
          </div>

          {/* Coral camera graphic — clean line-art, single colour, sits
              between the header and the hero so the page reads
              [breathing space → header → camera → hero]. Stroke-first
              vocabulary matches the canonical matrix logo's restrained
              geometric feel without competing with the wordmark above.
              Body 3:2, rounded corners (rx=8 at 100px scale ≈ 0.08
              proportionally — same warmth as the matrix pills). Small
              viewfinder bump top-centre + lens circle in the middle.
              The lens has a thin inner ring (filled coral) so the
              graphic reads as CAMERA, not eye / video / target. */}
          <svg
            className="poster-camera-icon"
            viewBox="0 0 100 70"
            xmlns="http://www.w3.org/2000/svg"
            aria-hidden="true"
          >
            {/* Viewfinder bump — small rectangle on top-centre of body */}
            <rect
              x="38"
              y="6"
              width="24"
              height="8"
              rx="2"
              fill="none"
              stroke="#FF6B35"
              strokeWidth="3"
              strokeLinejoin="round"
            />
            {/* Body — 3:2 rounded rectangle */}
            <rect
              x="6"
              y="14"
              width="88"
              height="50"
              rx="6"
              fill="none"
              stroke="#FF6B35"
              strokeWidth="3"
              strokeLinejoin="round"
            />
            {/* Lens outer ring */}
            <circle
              cx="50"
              cy="39"
              r="15"
              fill="none"
              stroke="#FF6B35"
              strokeWidth="3"
            />
            {/* Lens inner — filled coral disc, the only fill on the
                whole mark, so the graphic reads unmistakably as a
                camera lens rather than an open shape. */}
            <circle cx="50" cy="39" r="6" fill="#FF6B35" />
            {/* Shutter-release dot, top-right corner of body —
                small filled coral square, the canonical "this is a
                camera" cue. */}
            <rect x="78" y="20" width="6" height="3" rx="1" fill="#FF6B35" />
          </svg>

          <div className="poster-hero">
            {/* Headline copy locked 2026-05-23 (stack item 9). The
                line is rhythmically split around the em-dash so the
                wordmark sits as the final beat: "Safe recording is
                allowed here — using homefit.studio". The wordmark
                colour split is brand-locked (homefit ink-dark,
                .studio coral); the rest of the line stays in the
                page's ink colour so the wordmark is the only coral
                accent in the headline. */}
            <h1>
              Safe recording is allowed here —{' '}
              <span className="poster-hero-wm">
                using homefit<span className="poster-dot-studio">.studio</span>
              </span>
            </h1>
            <p className="poster-sub">
              Practitioners film exercise demos for their clients. Anyone in
              the background — including you — is automatically obscured by
              {' '}
              <span className="poster-wm">
                homefit<span className="poster-dot-studio">.studio</span>
              </span>
              {' '}Safe Mode.
            </p>
          </div>

          <div className="poster-body">
            <div className="poster-explain">
              <h2>What this means for you</h2>
              <p>
                Practitioners at {practiceName} record exercise demonstrations
                for their clients. The app they use automatically obscures the
                face and body of anyone caught in the background — that
                includes you.
              </p>
              <p>
                The app uses face recognition to lock the obscuring to the one
                client registered at the start of each session. Anyone else who
                walks into the frame — including you passing by — stays
                obscured.
              </p>
              <p>
                Every practitioner recording here has identified themselves
                publicly.{' '}
                <strong>
                  You can see who is currently recording, when they started,
                  and where they are in the venue
                </strong>{' '}
                by scanning the code on the right.
              </p>
            </div>

            <div className="poster-qr-card">
              <div
                className="poster-qr"
                // The QR encoder emits a self-contained <svg>; dropping it
                // straight in as innerHTML is safe — same-origin server-
                // rendered string with no user content.
                dangerouslySetInnerHTML={{ __html: qrSvg }}
              />
              <div className="poster-qr-label">
                Scan to see who is recording right now
              </div>
              <div className="poster-qr-url">{liveUrl.replace(/^https?:\/\//, '')}</div>
            </div>
          </div>

          {/* Caveat box — full-width below the two-column body. Pulled
              OUT of the left column because the asymmetric column heights
              (long body copy left vs. short QR card right) left a tall
              empty band on the right side of the page. Anchoring the
              stop-and-act CTA across the full width gives both columns a
              clean common baseline and gives the "if you're worried"
              framing the visual weight it deserves. */}
          <div className="poster-caveat">
            <strong>Worried about a practitioner&rsquo;s behavior?</strong>{' '}
            Scan the code, find their session, and tap &ldquo;Report&rdquo;.
            The practice owner at {practiceName} is notified directly via
            their listed contact and can act.
          </div>

          <div className="poster-trust">
            {/* Stack item 10: the "Learn more at .../what-we-share"
                line is dropped entirely. The page is now /safe-mode
                (PR #444's addition) which is the bystander's
                authoritative entry point — /what-we-share is a
                client-facing analytics-opt-out page that doesn't
                belong in front of bystanders. No replacement copy. */}
            <div className="poster-trust-links">
              <div>
                How Safe Mode works:{' '}
                <strong className="poster-wm">
                  homefit<span className="poster-dot-studio">.studio</span>
                  /safe-mode
                </strong>
              </div>
            </div>
            {/* Bottom brand mark — paired with the top mark at the
                same 240px scale and the same "powered by" + lockup
                inline arrangement. Tight spacing (≤ 1em gap) so the
                two read as one composite signature rather than two
                separate elements. Print variant of the canonical
                HomefitLogoLockup. */}
            <div className="poster-powered-inline">
              <div className="poster-powered">powered by</div>
              <HomefitLogoLockup className="poster-lockup-footer" print />
            </div>
          </div>
        </div>
      </div>

      {shouldAutoPrint && (
        <script
          // eslint-disable-next-line react/no-danger
          dangerouslySetInnerHTML={{
            __html: `window.addEventListener('load', function(){ setTimeout(function(){ window.print(); }, 200); });`,
          }}
        />
      )}
    </>
  );
}

const posterCss = `
  @page { size: A4; margin: 16mm; }
  .poster-root {
    background: #F3F4F6;
    min-height: 100vh;
    padding: 32px;
    display: flex;
    align-items: flex-start;
    justify-content: center;
    font-family: 'Inter', -apple-system, system-ui, sans-serif;
    color: #0F1117;
  }
  .poster-warning {
    position: fixed; top: 16px; left: 50%; transform: translateX(-50%);
    background: #FFF3ED; border: 2px solid #FF6B35;
    color: #0F1117; padding: 10px 16px; border-radius: 10px;
    font-size: 13px; max-width: 520px; z-index: 10;
  }
  .poster-page {
    width: 210mm;
    min-height: 297mm;
    background: #FFFFFF;
    /* Padding trimmed from 32mm/24mm to 24mm/18mm (stack pass 2)
       to reclaim ~14mm of vertical budget the 2x top + bottom
       brand marks now eat. With a 240px-wide lockup at ~3:1 aspect
       (so ~28mm tall vs the old ~14mm), the header band carries
       its own breathing room — no need for the old top padding to
       double it up. */
    padding: 24mm 20mm 18mm;
    box-shadow: 0 24px 64px rgba(0,0,0,0.15);
    display: flex;
    flex-direction: column;
  }
  .poster-header {
    display: flex; justify-content: space-between; align-items: center;
    padding-bottom: 16mm; border-bottom: 1px solid #E5E7EB;
  }
  /* Coral camera graphic — sits between the header and the hero,
     centred horizontally. Doubled from the original 110px so the
     mark reads as a substantial visual anchor at A4 viewing
     distance — at ~220px the body + lens silhouette is unmistakable
     from a few metres away (poster context, not screen context).
     Vertical margins bumped to give the larger graphic its own
     breathing band: 18mm above (vs 14mm) clears the header
     border-rule, 4mm below balances against the trimmed hero
     margin so the camera doesn't crowd the headline. */
  .poster-camera-icon {
    display: block;
    width: 220px;
    height: auto;
    /* Top margin trimmed from 18mm to 14mm to claw back vertical
       budget the larger top-mark consumes (stack pass 2). 4mm
       bottom margin preserved — the headline still has the same
       ~12mm air to the camera once the hero's 8mm top margin is
       added on. */
    margin: 14mm auto 4mm;
  }
  /* Hero-size canonical lockup at the top of the poster. Doubled
     from 120px to 240px (stack item 8) so the brand mark reads at
     A4 viewing distance — paired with the bottom-right footer at
     the same scale so the top-and-tail framing is symmetric. The
     lockup's intrinsic aspect is 48:16 (≈ 3:1), so 240px wide
     yields ~80px tall. */
  .poster-lockup-hero { width: 240px; height: auto; display: block; }
  /* Top + bottom mark composite — "powered by" sits inline to the
     LEFT of the lockup. Tight gap (12px ≈ 1em at 12pt) so the two
     pieces read as one signature unit rather than two adjacent
     elements. */
  .poster-powered-inline {
    display: flex; align-items: center; gap: 12px;
  }
  .poster-practice { text-align: right; }
  .poster-practice-name {
    font-family: 'Montserrat', system-ui, sans-serif; font-weight: 700;
    font-size: 16px; color: #0F1117;
  }
  .poster-practice-loc {
    font-family: 'Montserrat', system-ui, sans-serif; font-weight: 600;
    font-size: 12px; color: #4B5563; letter-spacing: 0.3px; margin-top: 2px;
  }
  /* Hero margin trimmed from 24mm → 8mm because the larger camera
     graphic now carries the visual separation between header and
     headline (its own 4mm bottom margin + 8mm here = the same ~12mm
     air the smaller graphic needed). */
  .poster-hero { margin-top: 8mm; text-align: center; }
  .poster-hero h1 {
    font-family: 'Montserrat', system-ui, sans-serif; font-weight: 800;
    font-size: 44pt; line-height: 1.05; letter-spacing: -0.5px; color: #0F1117;
  }
  .poster-accent { color: #FF6B35; }
  /* Hero wordmark — brand-locked colour split (homefit print-ink,
     .studio coral). Inherits the h1 Montserrat 800 weight so the
     wordmark integrates with the headline rather than sitting as a
     visually distinct block. The homefit portion uses #1A1D27
     (print ink, matches the canonical print lockup variant); the
     .studio span overrides to coral. */
  .poster-hero-wm { color: #1A1D27; }
  .poster-sub {
    margin-top: 6mm; font-size: 14pt; color: #4B5563; line-height: 1.4;
    max-width: 70%; margin-left: auto; margin-right: auto;
  }
  .poster-body {
    margin-top: 20mm;
    display: grid; grid-template-columns: 1fr 80mm; gap: 16mm;
    align-items: start;
  }
  .poster-body h2 {
    font-family: 'Montserrat', system-ui, sans-serif; font-weight: 700;
    font-size: 11pt; letter-spacing: 1.2px; text-transform: uppercase;
    color: #4B5563; margin-bottom: 4mm;
  }
  .poster-body p {
    font-size: 11pt; line-height: 1.55; color: #0F1117; margin-bottom: 4mm;
  }
  .poster-body p strong { color: #0F1117; }
  .poster-qr-card {
    background: #FAFAFA; border: 2px solid #FF6B35; border-radius: 12px;
    padding: 8mm; text-align: center;
  }
  .poster-qr {
    width: 100%; aspect-ratio: 1 / 1; border: 4px solid #0F1117;
    border-radius: 4px; padding: 6px; margin-bottom: 4mm;
    background: #FFFFFF; display: flex; align-items: center; justify-content: center;
  }
  .poster-qr svg { width: 100%; height: 100%; display: block; }
  .poster-qr-label {
    font-family: 'Montserrat', sans-serif; font-weight: 700;
    font-size: 10pt; color: #0F1117; line-height: 1.3; margin-bottom: 2mm;
  }
  .poster-qr-url {
    font-family: 'Menlo', monospace; font-size: 8pt; color: #4B5563;
    word-break: break-all;
  }
  /* Full-width below the two-column body. Top margin matches the body's
     top margin so the caveat reads as its own banded section rather than
     a stray block under the columns. */
  .poster-caveat {
    margin-top: 12mm; padding: 7mm 9mm;
    background: rgba(255, 107, 53, 0.06);
    border-left: 3px solid #FF6B35;
    font-size: 11pt; color: #0F1117; line-height: 1.55;
  }
  .poster-caveat strong {
    font-family: 'Montserrat', sans-serif; font-weight: 700;
  }
  .poster-trust {
    margin-top: auto;
    /* Top padding trimmed from 16mm to 10mm (stack pass 2): the
       240px bottom mark is now physically large enough to anchor
       the foot of the page on its own — the old big band of
       whitespace above it was redundant. */
    padding-top: 10mm; border-top: 1px solid #E5E7EB;
    display: flex; justify-content: space-between; align-items: center;
    font-size: 9pt; color: #4B5563;
  }
  .poster-trust-links {
    display: flex; flex-direction: column; gap: 2mm;
  }
  .poster-powered {
    /* Lowercase per brief, kept lowercase regardless of surrounding
       capitalisation; sits inline to the left of the lockup. */
    font-family: 'Montserrat', sans-serif; font-weight: 600;
    text-transform: lowercase; font-size: 11pt; color: #4B5563;
    line-height: 1; white-space: nowrap;
  }
  /* Footer-scale lockup — matches the hero scale (stack item 11):
     the top and bottom marks are deliberately the same size so the
     poster reads as top-and-tail symmetric. */
  .poster-lockup-footer { width: 240px; height: auto; display: block; }
  .poster-wm { font-family: 'Montserrat', sans-serif; font-weight: 700; }
  .poster-dot-studio { color: #FF6B35; }

  @media print {
    /* Print bug fix: without these resets, the on-screen layout's
       min-height 100vh on .poster-root + min-height 297mm / width
       210mm on .poster-page push content past the printable area
       (A4 minus 16mm margins = 178 x 265mm), overflowing into a
       second blank page (and sometimes a third with a hairline of
       the footer). Strip the explicit dimensions in print — the
       @page rule + the content's natural height take over. */
    html, body { margin: 0; padding: 0; background: white; }
    .poster-root {
      background: white;
      padding: 0;
      min-height: 0;
      display: block;
    }
    .poster-page {
      box-shadow: none;
      width: auto;
      min-height: 0;
      /* Print margins live on @page now; the inner padding can
         drop substantially so the content sits cleanly inside the
         printable area without doubling the margin band. */
      padding: 0;
    }
    .poster-warning { display: none; }
  }
`;

function searchParamsPrint(query: SearchParams): boolean {
  return query.print === '1';
}
