import Link from 'next/link';
import { redirect } from 'next/navigation';
import { getServerClient } from '@/lib/supabase-server';
import { createPortalApi } from '@/lib/supabase/api';
import { BrandHeader } from '@/components/BrandHeader';
import { SessionsList } from '@/components/SessionsList';

type SearchParams = { practice?: string };

/**
 * `/sessions` — the portal twin of the mobile Home screen's session list.
 *
 * R-11 (Account & billing twins): capabilities mirror mobile but the form
 * is web-appropriate (table on desktop, stacked cards on mobile).
 *
 * Visibility:
 *   - Practitioner (non-owner) → only their own sessions.
 *   - Owner                    → every session across the practice,
 *     with the authoring practitioner's email shown on rows that aren't
 *     theirs (POPIA — don't echo the owner's own email back at them).
 */
export default async function SessionsPage({
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

  // Membership + role gate. No practice → land them on the dashboard so
  // the PracticeSwitcher can get them back here with a practice in the qs.
  if (!practiceId) {
    redirect('/dashboard');
  }

  const role = await api.getCurrentUserRole(practiceId, user.id);
  if (role === null) {
    // Not a member — bounce to dashboard. The RPC would 42501 us anyway.
    redirect('/dashboard');
  }

  const isOwner = role === 'owner';
  const sessions = await api.listPracticeSessions(practiceId);
  const count = sessions.length;

  const heading = isOwner ? 'Practice sessions' : 'Your sessions';
  const subtitle = isOwner
    ? count === 1
      ? 'All sessions published across the practice, 1 total.'
      : `All sessions published across the practice, ${count} total.`
    : count === 1
      ? "1 session you've published."
      : `${count} sessions you've published.`;

  return (
    <main className="flex min-h-screen flex-col">
      <BrandHeader showSignOut practiceId={practiceId} />
      <div className="mx-auto w-full max-w-5xl flex-1 px-6 py-10">
        <nav className="mb-4 text-sm text-ink-muted">
          <Link
            href={`/dashboard?practice=${practiceId}`}
            className="hover:text-brand"
          >
            &larr; Dashboard
          </Link>
        </nav>

        <h1 className="font-heading text-3xl font-bold">{heading}</h1>
        <p className="mt-2 text-sm text-ink-muted">{subtitle}</p>

        <SessionsList sessions={sessions} isOwnerView={isOwner} />
      </div>
    </main>
  );
}
