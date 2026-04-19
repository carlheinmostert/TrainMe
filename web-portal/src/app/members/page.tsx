import Link from 'next/link';
import { redirect } from 'next/navigation';
import { getServerClient } from '@/lib/supabase-server';
import { createPortalApi } from '@/lib/supabase/api';
import { BrandHeader } from '@/components/BrandHeader';

type SearchParams = { practice?: string };

export default async function MembersPage({
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
  const [members, role] = await Promise.all([
    practiceId ? api.listPracticeMembers(practiceId) : Promise.resolve([]),
    practiceId
      ? api.getCurrentUserRole(practiceId, user.id)
      : Promise.resolve(null),
  ]);
  const isOwner = role === 'owner';

  return (
    <main className="flex min-h-screen flex-col">
      <BrandHeader showSignOut />
      <div className="mx-auto w-full max-w-3xl flex-1 px-6 py-10">
        <nav className="mb-4 text-sm text-ink-muted">
          <Link
            href={`/dashboard?practice=${practiceId}`}
            className="hover:text-brand"
          >
            ← Dashboard
          </Link>
        </nav>

        <div className="flex flex-wrap items-center justify-between gap-4">
          <h1 className="font-heading text-3xl font-bold">Members</h1>
          {isOwner && (
            <details className="rounded-md border border-surface-border bg-surface-base px-4 py-2">
              <summary className="cursor-pointer text-sm font-medium text-brand">
                Invite
              </summary>
              <form
                className="mt-3 flex flex-col gap-2"
                action="#"
                onSubmit={undefined}
              >
                <label className="text-xs text-ink-muted" htmlFor="invite-email">
                  Practitioner email
                </label>
                <input
                  id="invite-email"
                  name="email"
                  type="email"
                  placeholder="name@example.com"
                  className="rounded-md border border-surface-border bg-surface-raised px-3 py-2 text-sm"
                />
                <button
                  type="submit"
                  disabled
                  className="rounded-md bg-surface-raised px-3 py-2 text-sm text-ink-muted"
                >
                  Send invite (wiring pending)
                </button>
                <p className="text-xs text-warning">
                  Member-invite wiring is pending — Milestone D4 follow-up.
                </p>
              </form>
            </details>
          )}
        </div>

        {members.length === 0 ? (
          <p className="mt-10 rounded-lg border border-surface-border bg-surface-base p-8 text-center text-ink-muted">
            No members found for this practice.
          </p>
        ) : (
          <ul className="mt-8 divide-y divide-surface-border rounded-lg border border-surface-border bg-surface-base">
            {members.map((m) => (
              <li
                key={m.trainer_id}
                className="flex items-center justify-between px-5 py-4"
              >
                <div>
                  <p className="font-mono text-sm text-ink">
                    {m.trainer_id.slice(0, 8)}…
                  </p>
                  <p className="text-xs text-ink-dim">
                    Joined{' '}
                    {new Date(m.joined_at).toLocaleDateString('en-ZA', {
                      dateStyle: 'medium',
                    })}
                  </p>
                </div>
                <span
                  className={
                    m.role === 'owner'
                      ? 'rounded-full bg-brand/15 px-3 py-1 text-xs font-semibold uppercase text-brand'
                      : 'rounded-full bg-surface-raised px-3 py-1 text-xs font-semibold uppercase text-ink-muted'
                  }
                >
                  {m.role}
                </span>
              </li>
            ))}
          </ul>
        )}
      </div>
    </main>
  );
}
