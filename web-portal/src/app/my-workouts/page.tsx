import Link from 'next/link';
import { cookies } from 'next/headers';
import { redirect } from 'next/navigation';
import { getServerClient } from '@/lib/supabase-server';
import { createPortalApi } from '@/lib/supabase/api';
import { BrandHeader } from '@/components/BrandHeader';
import { MyWorkoutsList } from '@/components/MyWorkoutsList';
import { ACTIVE_PRACTICE_COOKIE } from '@/lib/active-practice';

type SearchParams = { practice?: string };

/**
 * `/my-workouts` — M29 (2026-05-26): view-only mirror of the mobile
 * My Workouts list. Surfaces every plan where the signed-in user is
 * the SUBJECT (clients.user_id = auth.uid()) regardless of which
 * practice the plan lives in.
 *
 * Why this page is view-only:
 *  - The mobile app is the configuration surface for capture +
 *    publish (per feedback_consumption_vs_config_surfaces). The portal
 *    is for inspection: see what's published, see the source tag,
 *    drill in for read-only review.
 *  - No copy-link / open-in-player CTAs on the row — they belong on
 *    the canonical `/clients/[id]` surface for plans the practitioner
 *    SHARES with someone else. My Workouts is for personal libraries.
 *
 * The list itself is per-USER, not per-practice; a practitioner with
 * Self-clients in two practices sees both their self-capture libraries
 * merged here. The dashboard tile still passes the active-practice qs
 * for header navigation cohesion.
 */
export default async function MyWorkoutsPage({
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
  const cookieStore = await cookies();
  const cookiePractice = cookieStore.get(ACTIVE_PRACTICE_COOKIE)?.value ?? '';
  const practiceId = params.practice ?? cookiePractice;

  // Practice membership for the BrandHeader switcher. The workouts list
  // itself doesn't filter by practice — list_my_workouts() scans across
  // every practice the caller is a member of.
  const practices = await api.listMyPractices();
  if (practices.length === 0) {
    redirect('/dashboard');
  }

  // For the header active-practice highlight we want a valid id. Fall
  // through to first membership when nothing was passed.
  const resolvedPractice =
    practices.find((p) => p.id === practiceId)?.id ?? practices[0].id;
  const practiceQs = `?practice=${resolvedPractice}`;
  const role = await api.getCurrentUserRole(resolvedPractice, user.id);
  const isOwner = role === 'owner';

  const workouts = await api.listMyWorkouts();
  const count = workouts.length;
  const subtitle =
    count === 0
      ? 'No self-captures yet.'
      : `${count} ${count === 1 ? 'workout' : 'workouts'}.`;

  return (
    <main className="flex min-h-screen flex-col">
      <BrandHeader
        showSignOut
        practiceId={resolvedPractice}
        isOwner={isOwner}
        userEmail={user.email ?? ''}
        practices={practices}
      />
      <div className="mx-auto w-full max-w-5xl flex-1 px-6 py-10">
        <nav className="mb-4 text-sm text-ink-muted">
          <Link
            href={`/dashboard${practiceQs}`}
            className="hover:text-brand"
          >
            &larr; Home
          </Link>
        </nav>

        <h1 className="font-heading text-3xl font-bold">My Workouts</h1>
        <p className="mt-2 text-sm text-ink-muted">{subtitle}</p>
        <p className="mt-1 text-xs text-ink-dim">
          Workouts where you are both the practitioner and the subject.
          Capture happens in the iOS app — this surface is for review.
        </p>

        <MyWorkoutsList workouts={workouts} practiceQs={practiceQs} />
      </div>
    </main>
  );
}
