import { cookies } from 'next/headers';
import Link from 'next/link';
import { redirect } from 'next/navigation';
import { getServerClient } from '@/lib/supabase-server';
import { createPortalApi } from '@/lib/supabase/api';
import { BrandHeader } from '@/components/BrandHeader';
import { PremisesListPanel } from '@/components/PremisesListPanel';
import { ACTIVE_PRACTICE_COOKIE } from '@/lib/active-practice';

type SearchParams = { practice?: string };

/**
 * `/premises` — manage the physical sites that anchor Safe Mode + the
 * public directory listing for this practice.
 *
 * Members can view + add + edit premises. The directory opt-in lives
 * here too (separate from per-premises Safe Mode toggle) — a practice
 * can have premises without being directory-listed, and vice versa.
 *
 * Owner-only edits enforced inside the RPCs (`upsert_premises` allows
 * any member; `set_practice_public_profile` is owner-only — see the
 * server-side error mapping in PortalApi).
 */
export default async function PremisesPage({
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
  if (practices.length === 0) redirect('/dashboard');

  const cookieStore = await cookies();
  const cookiePractice = cookieStore.get(ACTIVE_PRACTICE_COOKIE)?.value;
  const cookieFallback =
    cookiePractice && practices.some((p) => p.id === cookiePractice)
      ? cookiePractice
      : practices[0].id;
  const selectedId = params.practice ?? cookieFallback;
  const selected = practices.find((p) => p.id === selectedId) ?? practices[0];
  const qs = `?practice=${selected.id}`;

  // Public-profile data no longer fetched here — moved to its own
  // /public-profile route in v2. /premises is now site-management
  // only (physical premises + Safe Mode enforcement).
  const [role, premises] = await Promise.all([
    api.getCurrentUserRole(selected.id, user.id),
    api.listPracticePremises(selected.id),
  ]);
  const isOwner = role === 'owner';

  return (
    <main className="flex min-h-screen flex-col">
      <BrandHeader
        showSignOut
        practiceId={selected.id}
        isOwner={isOwner}
        userEmail={user.email ?? ''}
        practices={practices}
      />
      <div className="mx-auto w-full max-w-4xl flex-1 px-6 py-10">
        <nav className="mb-4 text-sm text-ink-muted">
          <Link href={`/dashboard${qs}`} className="hover:text-brand">
            ← Dashboard
          </Link>
        </nav>

        <div className="mb-6 flex flex-col gap-2">
          <h1 className="font-heading text-3xl font-bold">Premises</h1>
          <p className="text-sm text-ink-muted">
            Register the physical sites where this practice operates.
            Inside an enforced premises, Safe Mode automatically blurs
            bystanders in any capture — no matter which practice the
            practitioner belongs to.
          </p>
        </div>

        <PremisesListPanel
          practiceId={selected.id}
          isOwner={isOwner}
          initialPremises={premises}
        />
      </div>
    </main>
  );
}
