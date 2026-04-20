import Link from 'next/link';
import { redirect } from 'next/navigation';
import { getServerClient } from '@/lib/supabase-server';
import { createPortalApi, PortalReferralApi } from '@/lib/supabase/api';
import { BrandHeader } from '@/components/BrandHeader';
import { NetworkShareCard } from '@/components/NetworkShareCard';
import { NetworkEarningsCard } from '@/components/NetworkEarningsCard';

type SearchParams = { practice?: string };

/**
 * `/network` — the practitioner's referral management surface.
 *
 * R-12 lift: the share link + rebate stats previously lived only on
 * the dashboard, which meant navigating away from /dashboard lost
 * access to them. Promoted to a dedicated page so the dashboard tile
 * can become a summary-plus-click-through and the nav gets a durable
 * home for network features.
 *
 * Voice: peer-to-peer. NEVER "referral rewards", "commission", "cash",
 * "payout", "downline". Labels below use "free credits", "rebate",
 * "your network".
 *
 * R-11 twin: the mobile app surfaces the same capabilities from
 * Settings → Network rebate / share code (shipped on feat/mobile-referral-share).
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

  // Three parallel fetches — code (idempotent generate), stats, referees.
  const referralApi = new PortalReferralApi(supabase);
  const [referralCode, referralStats, referees] = await Promise.all([
    referralApi.generateCode(practiceId),
    referralApi.dashboardStats(practiceId),
    referralApi.refereesList(practiceId),
  ]);

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

        <h1 className="font-heading text-3xl font-bold">Your network</h1>
        <p className="mt-2 max-w-2xl text-sm text-ink-muted">
          Share your code with colleagues. They land with 8 free credits
          instead of 3, and you earn a 5% lifetime rebate on every purchase
          they ever make.
        </p>

        <div className="mt-8 grid gap-6 lg:grid-cols-2">
          <NetworkShareCard
            practiceId={practiceId}
            initialCode={referralCode}
          />
          <NetworkEarningsCard stats={referralStats} referees={referees} />
        </div>
      </div>
    </main>
  );
}
