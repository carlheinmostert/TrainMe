import Link from 'next/link';
import { cookies } from 'next/headers';
import { redirect } from 'next/navigation';
import { getServerClient } from '@/lib/supabase-server';
import {
  createPortalApi,
  PortalReferralApi,
} from '@/lib/supabase/api';
import { BrandHeader } from '@/components/BrandHeader';
import { BUNDLES, zar } from '@/lib/bundles';
import { BuyBundleButton } from '@/components/BuyBundleButton';
import { ACTIVE_PRACTICE_COOKIE } from '@/lib/active-practice';

type SearchParams = { practice?: string };

export default async function CreditsPage({
  searchParams,
}: {
  searchParams: Promise<SearchParams>;
}) {
  const supabase = await getServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  // Carry the destination through sign-in. Without this, a chip tap
  // from the mobile app while the portal session has expired bounced
  // through `/` and forward-defaulted to `/dashboard`, losing /credits.
  if (!user) redirect('/?next=/credits');

  const params = await searchParams;
  // Resolution order: explicit `?practice=` (e.g. coming through an
  // in-portal Link), then the `hf_active_practice` cookie set by
  // middleware on the most recent app→portal handoff. The mobile
  // credits chip opens this page with `?practice=<uuid>` — middleware
  // strips the param and pins the cookie, then redirects here, so
  // this fallback is the load-bearing one for the app→portal flow.
  const cookieStore = await cookies();
  const cookiePractice = cookieStore.get(ACTIVE_PRACTICE_COOKIE)?.value ?? '';
  const practiceId = params.practice ?? cookiePractice;

  // Owner-only gate. Per CLAUDE.md tenancy model: owners buy credits,
  // practitioners consume them. The /credits/purchase API route also
  // enforces this as defence-in-depth.
  //
  // Dashboard rework (C-12): also pull the network rebate stats so the
  // page can surface the secondary balance line ("Plus N free earned")
  // + the coral "Earn free credits from your network" banner above the
  // bundle grid. Both replace the standalone Network dashboard tile.
  const portal = createPortalApi(supabase);
  const referrals = new PortalReferralApi(supabase);
  const [role, practices, referralStats] = await Promise.all([
    practiceId
      ? portal.getCurrentUserRole(practiceId, user.id)
      : Promise.resolve(null),
    portal.listMyPractices(),
    practiceId
      ? referrals.dashboardStats(practiceId)
      : Promise.resolve({
          rebate_balance_credits: 0,
          lifetime_rebate_credits: 0,
          referee_count: 0,
          qualifying_spend_total_zar: 0,
        }),
  ]);
  const isOwner = role === 'owner';
  const rebateBalance = referralStats.rebate_balance_credits;
  const refereeCount = referralStats.referee_count;

  return (
    <main className="flex min-h-screen flex-col">
      <BrandHeader
        showSignOut
        practiceId={practiceId}
        isOwner={isOwner}
        userEmail={user.email ?? ''}
        practices={practices}
      />
      <div className="mx-auto w-full max-w-5xl flex-1 px-6 py-10">
        <h1 className="font-heading text-3xl font-bold">Buy credits</h1>
        <p className="mt-2 text-sm text-ink-muted">
          One credit is charged each time you publish a plan to a client.
          Payments are processed securely by PayFast (ZAR).
        </p>
        {rebateBalance > 0 && (
          <p className="mt-1 text-sm text-brand-light">
            Plus {fmtCredits(rebateBalance)} free credits earned from
            your network.
          </p>
        )}

        {/* C-12: earn-free-credits banner above the bundle grid.
            Replaces the discoverability the standalone Network
            dashboard tile used to provide. Full-card link to /network. */}
        <Link
          href={`/network?practice=${practiceId}`}
          className="mt-6 flex items-center gap-4 rounded-lg border border-brand-tint-border bg-[linear-gradient(90deg,rgba(255,107,53,0.12)_0%,rgba(255,107,53,0.04)_100%)] px-5 py-3.5 transition hover:border-brand focus:outline-none focus-visible:border-brand"
        >
          <span
            aria-hidden="true"
            className="flex h-9 w-9 shrink-0 items-center justify-center rounded-md border border-brand-tint-border bg-brand-tint-bg text-lg font-bold text-brand"
          >
            +
          </span>
          <span className="flex min-w-0 flex-1 flex-col">
            <span className="text-sm font-semibold text-ink">
              Earn free credits from your network
            </span>
            <span className="mt-0.5 text-[12.5px] text-ink-muted">
              5% lifetime rebate on every practitioner you refer
              {' · '}
              {refereeCount === 0
                ? '0 in your network so far'
                : `${refereeCount} ${refereeCount === 1 ? 'practitioner' : 'practitioners'} in your network so far`}
            </span>
          </span>
          <span
            aria-hidden="true"
            className="text-lg font-bold text-brand"
          >
            &rarr;
          </span>
        </Link>

        {!isOwner ? (
          <div className="mt-8 rounded-lg border border-surface-border bg-surface-base p-6">
            <h2 className="font-heading text-lg font-semibold">
              Your practice owner buys credits for this practice
            </h2>
            <p className="mt-2 text-sm text-ink-muted">
              You&rsquo;re signed in as a practitioner. Ask the practice
              owner to top up — you&rsquo;ll be able to publish as soon
              as they do.
            </p>
          </div>
        ) : (
          <div className="mt-8 grid grid-cols-1 gap-6 sm:grid-cols-2 lg:grid-cols-3">
            {BUNDLES.map((b) => {
              const perCredit = b.priceZar / b.credits;
              return (
                <article
                  key={b.key}
                  className="flex flex-col rounded-lg border border-surface-border bg-surface-base p-6"
                >
                  <h2 className="font-heading text-xl font-bold">{b.name}</h2>
                  <p className="mt-1 text-sm text-ink-muted">
                    {b.credits} credits
                  </p>
                  <p className="mt-4 font-heading text-3xl font-bold text-brand">
                    {zar(b.priceZar)}
                  </p>
                  <p className="mt-1 text-xs text-ink-dim">
                    {zar(perCredit)} per credit
                  </p>

                  <BuyBundleButton
                    bundleKey={b.key}
                    bundleName={b.name}
                    practiceId={practiceId}
                  />
                </article>
              );
            })}
          </div>
        )}
      </div>
    </main>
  );
}

function fmtCredits(n: number): string {
  const rounded = Math.round(n * 10) / 10;
  return Number.isInteger(rounded)
    ? String(Math.round(rounded))
    : rounded.toFixed(1);
}
