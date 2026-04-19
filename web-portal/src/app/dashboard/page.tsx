import Link from 'next/link';
import { redirect } from 'next/navigation';
import { getServerClient } from '@/lib/supabase-server';
import { createPortalApi, PortalReferralApi } from '@/lib/supabase/api';
import { BrandHeader } from '@/components/BrandHeader';
import { CreditBalance } from '@/components/CreditBalance';
import { PracticeSwitcher } from '@/components/PracticeSwitcher';
import { NetworkShareCard } from '@/components/NetworkShareCard';
import { NetworkEarningsCard } from '@/components/NetworkEarningsCard';

type SearchParams = { practice?: string };

export default async function DashboardPage({
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
  const practices = await api.listMyPractices();

  if (practices.length === 0) {
    return (
      <main className="flex min-h-screen flex-col">
        <BrandHeader showSignOut />
        <div className="mx-auto max-w-2xl px-6 py-16">
          <h1 className="font-heading text-3xl font-bold">Welcome</h1>
          <p className="mt-3 text-ink-muted">
            You&rsquo;re signed in but not yet a member of any practice. Ask
            your practice owner to invite you, or contact support to set up a
            new practice.
          </p>
        </div>
      </main>
    );
  }

  const selectedId = params.practice ?? practices[0].id;
  const selected = practices.find((p) => p.id === selectedId) ?? practices[0];
  const balance = await api.getPracticeBalance(selected.id);
  const qs = `?practice=${selected.id}`;

  // Referral surface — code is idempotent, stats + referees return
  // zero rows during pre-backend dev (the typed surface mocks).
  const referralApi = new PortalReferralApi(supabase);
  const [referralCode, referralStats, referees] = await Promise.all([
    referralApi.generateCode(selected.id),
    referralApi.dashboardStats(selected.id),
    referralApi.refereesList(selected.id),
  ]);

  return (
    <main className="flex min-h-screen flex-col">
      <BrandHeader showSignOut practiceId={selected.id} />
      <div className="mx-auto w-full max-w-5xl flex-1 px-6 py-10">
        <div className="mb-8 flex flex-wrap items-center justify-between gap-4">
          <div>
            <h1 className="font-heading text-3xl font-bold">Dashboard</h1>
            <p className="text-sm text-ink-muted">
              Signed in as {user.email}
            </p>
          </div>
          <PracticeSwitcher practices={practices} selectedId={selected.id} />
        </div>

        <div className="grid gap-6 md:grid-cols-3">
          <CreditBalance balance={balance} />

          <Link
            href={`/credits${qs}`}
            className="rounded-lg border border-surface-border bg-surface-base p-5 transition hover:border-brand hover:shadow-focus-ring"
          >
            <h2 className="font-heading text-lg font-semibold">Buy credits</h2>
            <p className="mt-1 text-sm text-ink-muted">
              Top up via PayFast. Starter, Practice, and Clinic bundles
              available.
            </p>
          </Link>

          <Link
            href={`/audit${qs}`}
            className="rounded-lg border border-surface-border bg-surface-base p-5 transition hover:border-brand hover:shadow-focus-ring"
          >
            <h2 className="font-heading text-lg font-semibold">Audit log</h2>
            <p className="mt-1 text-sm text-ink-muted">
              Recent plan issuances — who published what, when, and for how
              many credits.
            </p>
          </Link>

          <Link
            href={`/members${qs}`}
            className="rounded-lg border border-surface-border bg-surface-base p-5 transition hover:border-brand hover:shadow-focus-ring"
          >
            <h2 className="font-heading text-lg font-semibold">Members</h2>
            <p className="mt-1 text-sm text-ink-muted">
              Practitioners in this practice.
              {selected.role === 'owner' ? ' Invite teammates.' : ''}
            </p>
          </Link>
        </div>

        {/* Referral surface — peer-to-peer voice. Share link + network stats. */}
        <div className="mt-6 grid gap-6 lg:grid-cols-2">
          <NetworkShareCard
            practiceId={selected.id}
            initialCode={referralCode}
          />
          <NetworkEarningsCard
            stats={referralStats}
            referees={referees}
          />
        </div>
      </div>
    </main>
  );
}
