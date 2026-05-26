import { cookies } from 'next/headers';
import { redirect } from 'next/navigation';
import Link from 'next/link';
import type { Metadata } from 'next';
import { getServerClient } from '@/lib/supabase-server';
import { createPortalApi } from '@/lib/supabase/api';
import { BrandHeader } from '@/components/BrandHeader';
import { ACTIVE_PRACTICE_COOKIE } from '@/lib/active-practice';

export const metadata: Metadata = {
  title: 'Brand-skin — homefit.studio',
  description:
    'Subscribe to brand-skin to render every workout handout you publish in your own brand. 4 credits / month with a 30-day free trial.',
};

type SearchParams = { practice?: string };

/**
 * `/brand-skin` — landing page for the brand-skin subscription.
 *
 * State-aware:
 *   * No subscription, no trial used         → "Try free for 30 days" CTA
 *                                              that calls startBrandSkinTrial.
 *   * Active (paid OR trial), out of grace   → "Your brand-skin is active"
 *                                              confirmation.
 *   * Active (paid OR trial), inside grace   → "Renew before it lapses" CTA
 *                                              pointing at /subscribe.
 *   * Lapsed past day 37 OR trial-used + no
 *     active sub                             → "Subscribe · 4 credits / mo"
 *                                              CTA pointing at /subscribe.
 *
 * Practice resolution mirrors `/safe-mode/subscribe`: ?practice param
 * → cookie → first membership.
 *
 * Owner-only — the underlying RPCs enforce membership; this page adds a
 * UX gate so non-owners see a helpful message instead of the bare
 * permission error.
 */
export default async function BrandSkinPage({
  searchParams,
}: {
  searchParams: Promise<SearchParams>;
}) {
  const supabase = await getServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect('/?next=/brand-skin');

  const params = await searchParams;
  const cookieStore = await cookies();
  const cookiePractice = cookieStore.get(ACTIVE_PRACTICE_COOKIE)?.value ?? '';
  const portal = createPortalApi(supabase);

  const practices = await portal.listMyPractices();
  const cookieFallback =
    cookiePractice && practices.some((p) => p.id === cookiePractice)
      ? cookiePractice
      : practices[0]?.id ?? '';
  const practiceId = params.practice ?? cookieFallback;

  const [role, balance, state] = await Promise.all([
    practiceId
      ? portal.getCurrentUserRole(practiceId, user.id)
      : Promise.resolve(null),
    practiceId ? portal.getPracticeBalance(practiceId) : Promise.resolve(0),
    practiceId
      ? portal.getBrandSkinState(practiceId)
      : Promise.resolve({
          active: false,
          inGrace: false,
          trial: false,
          daysUntilLapse: null,
          nextRenewalAt: null,
        }),
  ]);

  const isOwner = role === 'owner';
  const hasNoPractices = practices.length === 0;
  const subscribeHref = `/brand-skin/subscribe${
    practiceId ? `?practice=${practiceId}` : ''
  }`;

  return (
    <main className="flex min-h-screen flex-col">
      <BrandHeader
        showSignOut
        practiceId={practiceId}
        isOwner={isOwner}
        userEmail={user.email ?? ''}
        practices={practices}
      />
      <div className="mx-auto w-full max-w-2xl flex-1 px-6 py-10">
        <h1 className="font-heading text-3xl font-bold">Brand-skin</h1>
        <p className="mt-3 text-base leading-relaxed text-ink">
          Render every workout handout you publish in your own brand
          identity — practice name, accent colour, and logo from your
          public profile. The homefit seal stays in the footer
          regardless, so clients always know where the artifact came
          from.
        </p>

        {hasNoPractices ? (
          <p className="mt-8 text-sm text-warning">
            You&rsquo;re signed in but not yet a member of any practice.
            Ask a practice owner to invite you, or set up a new practice
            from the dashboard.
          </p>
        ) : !isOwner ? (
          <p className="mt-8 text-sm text-warning">
            Only the practice owner can subscribe to brand-skin. Ask
            them to visit this page from their account.
          </p>
        ) : state.active && !state.inGrace ? (
          <div className="mt-8 rounded-2xl border border-success/40 bg-success/5 p-6">
            <p className="text-base font-semibold text-success">
              {state.trial
                ? 'Your brand-skin trial is active.'
                : 'Your brand-skin subscription is active.'}
            </p>
            <p className="mt-2 text-sm text-ink-muted">
              Every handout you publish renders in your brand.
              {state.daysUntilLapse !== null
                ? ` Roughly ${state.daysUntilLapse} days remain on the current cycle.`
                : ''}
            </p>
          </div>
        ) : state.active && state.inGrace ? (
          <div className="mt-8 rounded-2xl border border-brand/40 bg-brand/5 p-6">
            <p className="text-base font-semibold text-brand">
              Your brand-skin reverts in {state.daysUntilLapse ?? 0} days.
            </p>
            <p className="mt-2 text-sm text-ink-muted">
              Renew now to keep your brand on every artifact you&rsquo;ve
              already shared. The 7-day grace window is so you don&rsquo;t
              have to scramble; after that, handouts revert to the default
              homefit chrome.
            </p>
            <Link
              href={subscribeHref}
              className="mt-4 inline-block rounded-full bg-brand px-5 py-2 text-sm font-semibold text-surface-bg shadow hover:bg-brand-dark"
            >
              Renew · 4 credits / month
            </Link>
          </div>
        ) : (
          <div className="mt-8 space-y-4">
            <div className="rounded-2xl border border-surface-border bg-surface-base p-6">
              <p className="text-sm text-ink-muted">
                Current credit balance
              </p>
              <p className="mt-1 text-2xl font-bold text-ink">{balance}</p>
            </div>
            <Link
              href={subscribeHref}
              className="block w-full rounded-2xl bg-brand px-6 py-4 text-center text-base font-semibold text-surface-bg shadow transition hover:bg-brand-dark"
            >
              Subscribe · 4 credits / month
            </Link>
            <p className="text-xs text-ink-muted">
              First subscription includes a 30-day free trial — the
              4-credit debit doesn&rsquo;t happen until day 31. Renewal is
              manual; we&rsquo;ll remind you before the trial ends.
            </p>
          </div>
        )}

        <section className="mt-12 space-y-4 text-sm leading-relaxed text-ink-muted">
          <h2 className="font-heading text-base font-semibold text-ink">
            What you get
          </h2>
          <ul className="list-disc space-y-2 pl-5">
            <li>
              Every workout handout you publish renders with your
              practice name, brand colour, and logo at the top instead of
              the default homefit lockup.
            </li>
            <li>
              Live application — already-shared handouts re-skin on the
              next page load. Lapse, and they revert the same way.
            </li>
            <li>
              The homefit &ldquo;powered by&rdquo; seal at the footer
              stays coral and carries your referral QR regardless of the
              skin.
            </li>
            <li>
              One subscription per practice. If you belong to multiple
              practices, each one is its own subscription.
            </li>
          </ul>
        </section>
      </div>
    </main>
  );
}
