import { cookies } from 'next/headers';
import { redirect } from 'next/navigation';
import Link from 'next/link';
import type { Metadata } from 'next';
import { getServerClient } from '@/lib/supabase-server';
import { createPortalApi } from '@/lib/supabase/api';
import { BrandHeader } from '@/components/BrandHeader';
import { ACTIVE_PRACTICE_COOKIE } from '@/lib/active-practice';
import { BrandSkinSubscribeForm } from './BrandSkinSubscribeForm';

export const metadata: Metadata = {
  title: 'Brand-skin subscription — homefit.studio',
  description:
    'Subscribe to brand-skin chrome on every workout handout. 4 credits / month with a 30-day free trial.',
};

type SearchParams = { practice?: string };

/**
 * `/brand-skin/subscribe` — confirmation surface for the brand-skin
 * subscription debit.
 *
 * Mirrors `/safe-mode/subscribe` exactly. Server-renders the practice
 * context + balance + state, then mounts a client form that calls
 * `start_brand_skin_trial` (if no trial used yet) OR
 * `start_brand_skin_subscription` (otherwise).
 *
 * Practice resolution: ?practice param → cookie → first membership.
 *
 * Owner-only — the RPCs enforce membership; we add this UI gate so a
 * non-owner sees a helpful message instead of the bare error.
 *
 * Wave: Artifact-system Wave 4 (ADR-0029).
 */
export default async function BrandSkinSubscribePage({
  searchParams,
}: {
  searchParams: Promise<SearchParams>;
}) {
  const supabase = await getServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect('/?next=/brand-skin/subscribe');

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
  // The trial is available only if (a) the practice has no past trial
  // (we infer from "no active trial state AND no current paid sub" —
  // a more precise check requires a separate query and is not worth the
  // round-trip; the RPC is idempotent and will return trial_already_used
  // on repeat).
  const offerTrial = !state.active;

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
        <h1 className="font-heading text-3xl font-bold">
          {offerTrial ? 'Start your brand-skin trial' : 'Renew brand-skin'}
        </h1>
        <p className="mt-3 text-base leading-relaxed text-ink">
          {offerTrial
            ? 'First 30 days free. We debit 4 credits on day 31 only if you keep going.'
            : 'Renew for another 30 days. 4 credits debited from this practice now.'}
        </p>

        {hasNoPractices ? (
          <p className="mt-8 text-sm text-warning">
            You&rsquo;re signed in but not yet a member of any practice.
            Ask a practice owner to invite you, or set up a new practice
            from the dashboard.
          </p>
        ) : !isOwner ? (
          <p className="mt-8 text-sm text-warning">
            Only the practice owner can subscribe. Ask them to visit
            this page from their account.
          </p>
        ) : (
          <BrandSkinSubscribeForm
            practiceId={practiceId}
            initialBalance={balance}
            offerTrial={offerTrial}
          />
        )}

        <p className="mt-10 text-xs text-ink-muted">
          <Link
            href={`/brand-skin${
              practiceId ? `?practice=${practiceId}` : ''
            }`}
            className="text-brand hover:underline"
          >
            ← Back to brand-skin overview
          </Link>
        </p>
      </div>
    </main>
  );
}
