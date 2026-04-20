import Link from 'next/link';
import { redirect } from 'next/navigation';
import { getServerClient } from '@/lib/supabase-server';
import { createPortalApi } from '@/lib/supabase/api';
import { BrandHeader } from '@/components/BrandHeader';
import { ClientsList } from '@/components/ClientsList';

type SearchParams = { practice?: string };

/**
 * `/clients` — the portal's primary navigation destination.
 *
 * IA: clients are the spine of the practice. Sessions roll up beneath
 * them; top-level "Sessions" as a separate page has been retired (the
 * `SessionsList` component is now reused on `/clients/[id]`).
 *
 * Visibility mirrors /sessions (the retired page):
 *   - Practitioner → only their own clients are meaningful, but
 *     `list_practice_clients` returns every client in the practice. We
 *     show them all — sessions below each client's card still gate on
 *     the practitioner's own publishes (visible session count may be 0
 *     for a client some other practitioner works with).
 *   - Owner → every client, with the "Practitioner: {email}" row
 *     surfacing the most-recent publisher.
 *
 * R-11 twin: mobile app exposes clients via Settings → Your clients +
 * the Home screen session list; this page is the desktop-heavier twin
 * (dedicated page per client, inline consent, per-client sessions).
 */
export default async function ClientsPage({
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

  // Membership gate — mirror the retired /sessions behaviour.
  if (!practiceId) {
    redirect('/dashboard');
  }

  const role = await api.getCurrentUserRole(practiceId, user.id);
  if (role === null) {
    redirect('/dashboard');
  }
  const isOwner = role === 'owner';

  // Two fetches in parallel — clients for the grid, sessions for the
  // per-client stats (count + last-shared + practitioner). Both gated
  // by the same practice, both practice-scoped at the RPC layer.
  const [clients, sessions] = await Promise.all([
    api.listPracticeClients(practiceId),
    api.listPracticeSessions(practiceId),
  ]);

  const heading = isOwner ? 'Practice clients' : 'Clients';
  const count = clients.length;
  const subtitle =
    count === 0
      ? isOwner
        ? 'No clients in this practice yet.'
        : 'No clients yet.'
      : `${count} ${count === 1 ? 'client' : 'clients'}.`;

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

        <ClientsList
          clients={clients}
          sessions={sessions}
          isOwnerView={isOwner}
          practiceQs={`?practice=${practiceId}`}
        />
      </div>
    </main>
  );
}
