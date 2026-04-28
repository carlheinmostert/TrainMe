import Link from 'next/link';
import { cookies } from 'next/headers';
import { redirect, notFound } from 'next/navigation';
import { getServerClient } from '@/lib/supabase-server';
import { createPortalApi } from '@/lib/supabase/api';
import { BrandHeader } from '@/components/BrandHeader';
import { ClientDetailPanel } from '@/components/ClientDetailPanel';
import { SessionsList } from '@/components/SessionsList';
import { ACTIVE_PRACTICE_COOKIE } from '@/lib/active-practice';

type SearchParams = { practice?: string };

/**
 * `/clients/[id]` — single-client detail + inline consent form + per-
 * client sessions.
 *
 * Layout:
 *   1. Header block (name + session count + practitioner email)
 *   2. Consent controls (inline form, no modal)
 *   3. Sessions section (reuses SessionsList — same component as the
 *      retired /sessions page)
 *   4. Back link
 *
 * Visibility mirrors /sessions: owner sees every session for this
 * client, practitioner sees only their own publishes for this client.
 */
export default async function ClientDetailPage({
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
  const { id: clientId } = await params;
  const query = await searchParams;
  // Wave 40 P7 — practice resolution mirrors /clients + /audit + /credits
  // (cookie fallback). Without this, the click chain on the dashboard
  // (`/clients?practice=X` → middleware strips qs → `/clients/X`) loses
  // the practice context and the page bounced through `/dashboard`.
  // The cookie set by middleware on the previous strip is the load-
  // bearing fallback once the qs is gone.
  const cookieStore = await cookies();
  const cookiePractice = cookieStore.get(ACTIVE_PRACTICE_COOKIE)?.value ?? '';
  const practiceId = query.practice ?? cookiePractice;

  // Without a practice we can't gate properly; route through the
  // dashboard default. The landing page will redirect into a real
  // practice selection.
  if (!practiceId) {
    redirect('/dashboard');
  }

  const role = await api.getCurrentUserRole(practiceId, user.id);
  if (role === null) {
    // RLS would refuse the RPCs anyway; bouncing is the clearer UX.
    redirect('/dashboard');
  }
  const isOwner = role === 'owner';

  // Resolve the client + its sessions + the caller's practices in
  // parallel. `getClientById` returns null for not-found OR not-a-member
  // (get_client_by_id conflates both to RETURN empty-set, which we
  // normalise to null). `listMyPractices` powers the header right-cluster
  // switcher (Wave 40 P3).
  const [client, sessions, practices] = await Promise.all([
    api.getClientById(clientId),
    api.listSessionsForClient(clientId),
    api.listMyPractices(),
  ]);

  if (!client) {
    notFound();
  }

  // Derive the practitioner-email badge. Use the most-recent publish
  // across this client's sessions, skipping the caller's own rows so
  // practitioners don't see their own email echoed back to them.
  const recentPractitionerEmail = deriveRecentPractitionerEmail(
    sessions,
    isOwner,
  );
  const sessionCount = sessions.length;

  return (
    <main className="flex min-h-screen flex-col">
      <BrandHeader
        showSignOut
        practiceId={practiceId}
        isOwner={isOwner}
        userEmail={user.email ?? ''}
        practices={practices}
      />
      <div className="mx-auto w-full max-w-5xl flex-1 px-6 py-10">
        <nav className="mb-4 text-sm text-ink-muted">
          <Link
            href={`/clients?practice=${practiceId}`}
            className="hover:text-brand"
          >
            &larr; Clients
          </Link>
        </nav>

        <ClientDetailPanel
          clientId={client.id}
          clientName={client.name}
          initialConsent={client.videoConsent}
          sessionCount={sessionCount}
          recentPractitionerEmail={recentPractitionerEmail}
          practiceQs={`?practice=${practiceId}`}
        />

        {/* Sessions section — reuses the /sessions component verbatim. */}
        <section className="mt-12" aria-labelledby="sessions-heading">
          <div className="flex items-baseline justify-between gap-4">
            <h2
              id="sessions-heading"
              className="font-heading text-2xl font-bold"
            >
              Sessions
            </h2>
            <span className="rounded-full bg-surface-raised px-3 py-0.5 text-xs font-semibold uppercase tracking-wider text-ink-muted">
              {sessionCount} {sessionCount === 1 ? 'session' : 'sessions'}
            </span>
          </div>

          {sessions.length === 0 ? (
            <p className="mt-4 rounded-lg border border-surface-border bg-surface-base p-6 text-sm text-ink-muted">
              No sessions yet for {client.name}. Publish one from the mobile
              app.
            </p>
          ) : (
            <SessionsList
              sessions={sessions}
              isOwnerView={isOwner}
              showSessionIcon
              fallbackClientName={client.name}
              clientAvatarUrl={client.avatarUrl}
            />
          )}
        </section>

        {/* Footer nudge — R-09 obvious, no cleverness. */}
        <nav className="mt-12 border-t border-surface-border pt-6 text-sm">
          <Link
            href={`/clients?practice=${practiceId}`}
            className="text-ink-muted transition hover:text-brand"
          >
            &larr; Back to Clients
          </Link>
        </nav>
      </div>
    </main>
  );
}

/**
 * Pick the most-recent publish's trainer email from this client's
 * sessions. Returns null when the owner is looking at their own
 * publishes or the client has no sessions — the caller decides whether
 * to render the "Practitioner: ..." line based on this being non-null.
 *
 * We only surface the email to the practice OWNER: practitioners don't
 * need their own email echoed back on their own client page, and we
 * don't expose peers' emails to non-owners (POPIA-adjacent: stay narrow).
 */
function deriveRecentPractitionerEmail(
  sessions: { lastPublishedAt: string | null; trainerEmail: string | null; isOwnSession: boolean }[],
  isOwner: boolean,
): string | null {
  if (!isOwner) return null;
  const sorted = [...sessions].sort((a, b) => {
    const ta = a.lastPublishedAt ? new Date(a.lastPublishedAt).getTime() : 0;
    const tb = b.lastPublishedAt ? new Date(b.lastPublishedAt).getTime() : 0;
    return tb - ta;
  });
  for (const s of sorted) {
    if (!s.isOwnSession && s.trainerEmail) return s.trainerEmail;
  }
  return null;
}
