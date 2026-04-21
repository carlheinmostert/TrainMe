import Link from 'next/link';
import { redirect } from 'next/navigation';
import { getServerClient } from '@/lib/supabase-server';
import { createPortalApi, PortalReferralApi } from '@/lib/supabase/api';
import { BrandHeader } from '@/components/BrandHeader';
import { NetworkEarningsCard } from '@/components/NetworkEarningsCard';
import { ShareKit } from '@/components/ShareKit/ShareKit';
import { referralUrl } from '@/lib/referral-share';
import type { ShareKitSlots } from '@/lib/share-kit/templates';

type SearchParams = { practice?: string };

/**
 * `/network` — the practitioner's share + rebate surface.
 *
 * Wave 6 Phase 1 (2026-04-20): the single `<NetworkShareCard/>` is
 * retired in favour of `<ShareKit/>` — three pre-composed pitch
 * templates (WhatsApp 1:1, WhatsApp broadcast, Email) with copy-to-
 * clipboard + visual OG unfurl previews. Phase 2 adds wa.me / mailto:
 * intents; Phase 3 adds the PNG share card + QR. See
 * `docs/design/mockups/network-share-kit.html` for the spec.
 *
 * Voice: peer-to-peer (R-06 + voice.md). NEVER "referral rewards",
 * "commission", "cash", "payout", "downline". Labels below use
 * "free credits", "rebate", "your network".
 *
 * R-11 twin: the mobile app surfaces the same capabilities from
 * Settings → Network rebate / share code (shipped on
 * feat/mobile-referral-share).
 */
export default async function NetworkPage({
  searchParams,
}: {
  searchParams: Promise<SearchParams>;
}) {
  const supabase = await getServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect('/');

  const api = createPortalApi(supabase);
  const params = await searchParams;
  const practiceId = params.practice ?? '';

  // Membership gate — mirror /clients / /credits / /audit.
  if (!practiceId) {
    redirect('/dashboard');
  }

  const role = await api.getCurrentUserRole(practiceId, user.id);
  if (role === null) {
    redirect('/dashboard');
  }
  const isOwner = role === 'owner';

  // Four parallel fetches — code (idempotent generate), stats,
  // referees, practices (for the practice-name slot in the email
  // signature).
  const referralApi = new PortalReferralApi(supabase);
  const [referralCode, referralStats, referees, myPractices] =
    await Promise.all([
      referralApi.generateCode(practiceId),
      referralApi.dashboardStats(practiceId),
      referralApi.refereesList(practiceId),
      api.listMyPractices(),
    ]);

  // Practice name — used in the email signature ("{fullName} /
  // {practiceName}") and surfaces as the kicker on hero/debug rows.
  // Falls back to "Your Practice" so the UI never shows a blank line.
  const activePractice = myPractices.find((p) => p.id === practiceId);
  const practiceName = activePractice?.name ?? 'Your Practice';

  // Derive a display name for the practitioner. Supabase stores custom
  // names under `user_metadata.full_name` (Google OAuth) or
  // `user_metadata.name` (manual-set). If neither is present, fall
  // back to the local-part of the email — gives us "carlhein" instead
  // of a random UUID. Never shown as a UUID.
  const metadata =
    (user.user_metadata as Record<string, unknown> | undefined) ?? {};
  const metadataFullName =
    (typeof metadata.full_name === 'string' && metadata.full_name.trim()) ||
    (typeof metadata.name === 'string' && metadata.name.trim()) ||
    '';
  const emailLocalPart = (user.email ?? '').split('@')[0] ?? '';
  const fullName = metadataFullName || titleCase(emailLocalPart) || 'A friend';
  const firstName = fullName.split(/\s+/)[0] || fullName;

  // Build the share URL via the same helper used by the legacy card,
  // so Phase 2 intent links keep a single source of truth.
  const referralLink = referralCode
    ? referralUrl(referralCode)
    : 'https://manage.homefit.studio/r/loading';

  const shareKitSlots: ShareKitSlots = {
    firstName,
    fullName,
    practiceName,
    referralLink,
  };

  return (
    <main className="flex min-h-screen flex-col">
      <BrandHeader showSignOut practiceId={practiceId} isOwner={isOwner} />
      <div className="mx-auto w-full max-w-5xl flex-1 px-6 py-10">
        <nav className="mb-4 text-sm text-ink-muted">
          <Link
            href={`/dashboard?practice=${practiceId}`}
            className="hover:text-brand"
          >
            ← Dashboard
          </Link>
        </nav>

        {/* Hero — the product pitch the practitioner wants to forward.
            Two rows: top row is H1 + sub + share-code chip; below that
            a body paragraph, a three-feature amplifier of the sub, and
            a one-line closer. Mirrors the mockup hero. The chip is
            read-only; regenerate / copy-link is on the individual
            format cards below. */}
        <section className="mb-12 border-b border-surface-border pb-10">
          <div className="flex flex-col gap-6 sm:flex-row sm:items-start sm:justify-between sm:gap-8">
            <div className="max-w-[640px]">
              <h1 className="font-heading text-3xl font-extrabold leading-tight tracking-tight">
                Create a professional home care plan your client will love
                and follow in under 5 min.
              </h1>
              <p className="mt-3 text-base font-medium text-ink">
                Captured in-session. Published on your device. Delivered on
                WhatsApp — before the door closes.
              </p>
            </div>
            <CodeBadge code={referralCode} />
          </div>

          <p className="mt-6 max-w-[720px] text-sm text-ink-muted">
            No app install, no library of generic animations, no studio
            time. Demonstrate the exercise once and homefit.studio turns it
            into a clean line-drawing your client can follow at home — with
            your reps, sets, and timing baked in. Every link is branded to
            you and carries a signed audit trail, so you know who opened
            which plan and when.
          </p>

          <div className="mt-8 grid gap-5 sm:grid-cols-3 sm:gap-6">
            <div>
              <div className="font-mono text-[11px] font-semibold uppercase tracking-wider text-brand">
                Captured in-session
              </div>
              <p className="mt-2 text-sm text-ink-muted">
                One-handed shutter, long-press for video. Line-drawing
                conversion runs on-device while you move to the next
                exercise. Your client's face is abstracted — POPIA is
                built in.
              </p>
            </div>
            <div>
              <div className="font-mono text-[11px] font-semibold uppercase tracking-wider text-brand">
                Published on your device
              </div>
              <p className="mt-2 text-sm text-ink-muted">
                No cloud wait, no render queue. The plan is a link by the
                time you tap publish, and the upload finishes in the
                background while you walk to reception.
              </p>
            </div>
            <div>
              <div className="font-mono text-[11px] font-semibold uppercase tracking-wider text-brand">
                Delivered on WhatsApp
              </div>
              <p className="mt-2 text-sm text-ink-muted">
                Paste the link, send. No download, no login. Your client
                taps and the exercises play. 84% of South African
                healthcare clients are already on WhatsApp — we meet them
                there.
              </p>
            </div>
          </div>

          <p className="mt-8 max-w-[640px] text-sm font-medium text-ink">
            The plan your client receives is the plan they'll actually do.
          </p>
        </section>

        {/* Primary share surface — three copy-to-clipboard templates +
            Wave 10 PNG share card + tagline helper. ShareKit is a client
            component (Phase 3 wires useShareAnalytics) so the
            practiceId + code props below become the analytics scope. */}
        <ShareKit
          slots={shareKitSlots}
          practiceId={practiceId}
          referralCode={referralCode}
          practitionerFullName={fullName}
          practiceName={practiceName}
        />

        {/* Earnings + referee list retained from the previous layout. */}
        <div className="mt-16 border-t border-surface-border pt-10">
          <h2 className="font-heading text-[22px] font-bold tracking-tight">
            Your network
          </h2>
          <p className="mt-1 max-w-[640px] text-sm text-ink-muted">
            Rebate ledger and colleagues who signed up through your code.
          </p>
          <div className="mt-5">
            <NetworkEarningsCard
              stats={referralStats}
              referees={referees}
            />
          </div>
        </div>
      </div>
    </main>
  );
}

/**
 * Hero chip — displays the practitioner's share code + its fully-
 * qualified URL. Read-only; no clipboard affordance (the format cards
 * below carry the copy actions). Empty state = a subtle "Generating…"
 * label so the layout doesn't reflow once the RPC resolves.
 */
function CodeBadge({ code }: { code: string | null }) {
  const url = code
    ? referralUrl(code).replace(/^https?:\/\//, '')
    : 'generating link…';

  return (
    <div className="flex flex-col items-start gap-2 sm:items-end">
      <div className="font-mono text-[11px] font-semibold uppercase tracking-wider text-ink-dim">
        Your share code
      </div>
      <div className="inline-flex items-center gap-2.5 rounded-full border border-brand-tint-border bg-brand-tint-bg px-4 py-2.5 font-mono text-lg font-semibold tracking-widest text-brand-light">
        <CodeGlyph />
        {code ?? '·······'}
      </div>
      <div className="font-mono text-[11px] text-ink-muted">{url}</div>
    </div>
  );
}

function CodeGlyph() {
  return (
    <svg
      width="14"
      height="14"
      viewBox="0 0 14 14"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d="M9.5 2.5h2v2M4.5 11.5h-2v-2M11.5 4.5v7h-7v-7z" opacity="0.4" />
      <path d="M2.5 6.5h3v3h-3zM8.5 2.5v3M2.5 2.5h3v1" />
    </svg>
  );
}

/**
 * Very small title-case helper so we can turn `carlhein` into
 * `Carlhein` when we have no full-name metadata. Intentional: we
 * prefer the user-set metadata, but a bare email prefix looks
 * weird left lowercase in the email signature.
 */
function titleCase(s: string): string {
  if (!s) return '';
  return s
    .split(/[.\-_]+/)
    .filter(Boolean)
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(' ');
}
