import Link from 'next/link';
import { cookies } from 'next/headers';
import { redirect, notFound } from 'next/navigation';
import { getServerClient } from '@/lib/supabase-server';
import { createPortalApi } from '@/lib/supabase/api';
import { BrandHeader } from '@/components/BrandHeader';
import { SourceTagChip } from '@/components/SourceTagChip';
import { ClientTime } from '@/components/ClientTime';
import { ACTIVE_PRACTICE_COOKIE } from '@/lib/active-practice';

type SearchParams = { practice?: string };

/**
 * `/my-workouts/[id]` — M29 (2026-05-26): read-only drill-in for a
 * single self-capture workout.
 *
 * No edit / publish / share CTAs by design (matches the brief):
 *  - Editing belongs on the iOS app (capture + plan composition).
 *  - Sharing self-captures isn't a flow today — the workouts are
 *    inherently a private library. The shared-plan direction is
 *    the OTHER way (incoming from another practitioner).
 *
 * Authorization model: we resolve the workout via `listMyWorkouts()`
 * (the same RPC that powers the list) and locate the requested id
 * there. If the id isn't in the caller's My Workouts result-set, we
 * fall through to notFound() — that's the simplest safe authorization
 * gate ("you can only drill into rows that appear in your list").
 *
 * This avoids loading `get_plan_full` here (which is anonymous-callable
 * and would happily return any plan id); the My Workouts RPC already
 * gates by `clients.user_id = auth.uid()`.
 */
export default async function MyWorkoutDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<SearchParams>;
}) {
  const supabase = await getServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect('/');

  const api = createPortalApi(supabase);
  const { id: workoutId } = await params;
  const query = await searchParams;
  const cookieStore = await cookies();
  const cookiePractice = cookieStore.get(ACTIVE_PRACTICE_COOKIE)?.value ?? '';
  const practiceFromUrl = query.practice ?? cookiePractice;

  const [workouts, practices] = await Promise.all([
    api.listMyWorkouts(),
    api.listMyPractices(),
  ]);

  const workout = workouts.find((w) => w.id === workoutId);
  if (!workout) {
    // Either the id is bogus or the caller isn't the subject. Either
    // way the right answer is 404 — we don't leak whether the row
    // exists in someone else's My Workouts.
    notFound();
  }

  // Practice context for the header switcher: prefer the workout's
  // practice (the most relevant context for this row), fall back to
  // the qs/cookie if the workout's practice isn't in the user's
  // membership set somehow, then to the first membership.
  const resolvedPractice =
    practices.find((p) => p.id === (workout.practiceId ?? practiceFromUrl))
      ?.id ?? practices[0]?.id ?? '';
  const role = resolvedPractice
    ? await api.getCurrentUserRole(resolvedPractice, user.id)
    : null;
  const isOwner = role === 'owner';
  const practiceQs = resolvedPractice ? `?practice=${resolvedPractice}` : '';

  return (
    <main className="flex min-h-screen flex-col">
      <BrandHeader
        showSignOut
        practiceId={resolvedPractice}
        isOwner={isOwner}
        userEmail={user.email ?? ''}
        practices={practices}
      />
      <div className="mx-auto w-full max-w-3xl flex-1 px-6 py-10">
        <nav className="mb-4 text-sm text-ink-muted">
          <Link
            href={`/my-workouts${practiceQs}`}
            className="hover:text-brand"
          >
            &larr; My Workouts
          </Link>
        </nav>

        <header className="mb-6">
          <div className="flex items-center gap-3 flex-wrap">
            <h1 className="font-heading text-3xl font-bold">
              {workout.title || 'Untitled workout'}
            </h1>
            <SourceTagChip
              sourceTag={workout.sourceTag}
              sharedByEmail={workout.sharedByEmail}
            />
          </div>
          <p className="mt-2 text-sm text-ink-muted">
            Read-only view. Editing and re-publishing happen in the iOS app.
          </p>
        </header>

        <section
          aria-labelledby="metadata-heading"
          className="rounded-lg border border-surface-border bg-surface-base p-6"
        >
          <h2
            id="metadata-heading"
            className="text-sm font-semibold uppercase tracking-wider text-ink-muted"
          >
            Details
          </h2>
          <dl className="mt-4 grid grid-cols-1 gap-x-6 gap-y-3 text-sm sm:grid-cols-2">
            <div>
              <dt className="text-xs uppercase tracking-wider text-ink-dim">
                Exercises
              </dt>
              <dd className="mt-1 text-ink">
                {workout.exerciseCount}{' '}
                {workout.exerciseCount === 1 ? 'exercise' : 'exercises'}
              </dd>
            </div>
            <div>
              <dt className="text-xs uppercase tracking-wider text-ink-dim">
                Version
              </dt>
              <dd className="mt-1 text-ink">v{workout.version}</dd>
            </div>
            <div>
              <dt className="text-xs uppercase tracking-wider text-ink-dim">
                Shares
              </dt>
              <dd className="mt-1 text-ink">
                {workout.issuanceCount}{' '}
                {workout.issuanceCount === 1 ? 'share' : 'shares'}
              </dd>
            </div>
            <div>
              <dt className="text-xs uppercase tracking-wider text-ink-dim">
                Last published
              </dt>
              <dd className="mt-1 text-ink">
                {workout.lastPublishedAt ? (
                  <ClientTime ts={workout.lastPublishedAt} />
                ) : (
                  <span className="text-ink-dim">Not published yet</span>
                )}
              </dd>
            </div>
            <div>
              <dt className="text-xs uppercase tracking-wider text-ink-dim">
                First opened
              </dt>
              <dd className="mt-1 text-ink">
                {workout.firstOpenedAt ? (
                  <ClientTime ts={workout.firstOpenedAt} />
                ) : (
                  <span className="text-ink-dim">Not opened yet</span>
                )}
              </dd>
            </div>
            {workout.clientName && (
              <div>
                <dt className="text-xs uppercase tracking-wider text-ink-dim">
                  Subject
                </dt>
                <dd className="mt-1 text-ink">{workout.clientName}</dd>
              </div>
            )}
          </dl>
        </section>

        <p className="mt-6 text-xs text-ink-dim">
          To capture another self-workout or edit this one&rsquo;s
          exercises, open the iOS app and navigate to My Workouts.
        </p>

        <nav className="mt-12 border-t border-surface-border pt-6 text-sm">
          <Link
            href={`/my-workouts${practiceQs}`}
            className="text-ink-muted transition hover:text-brand"
          >
            &larr; Back to My Workouts
          </Link>
        </nav>
      </div>
    </main>
  );
}
