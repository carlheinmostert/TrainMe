import Link from 'next/link';
import { redirect } from 'next/navigation';
import { getServerClient } from '@/lib/supabase-server';
import { createPortalApi, createPortalMembersApi } from '@/lib/supabase/api';
import { BrandHeader } from '@/components/BrandHeader';
import { MembersList } from '@/components/MembersList';

type SearchParams = { practice?: string };

/**
 * /members — practice roster with owner-only invite / role / remove and
 * everyone-sees-everyone transparency.
 *
 * Wave 5 scope (see docs/BACKLOG.md "Members area — identity, invite codes,
 * role, remove, leave"):
 *
 * - Table: Email · Name · Role · Joined · Actions. Own row is tagged
 *   "(you)" with a Leave button.
 * - Invite: owner-only button at the top mints a fresh 7-char code,
 *   copies the `/join/{code}` URL, and surfaces it in a toast. Each code
 *   is one-time — claiming or revoking invalidates it.
 * - Role change: owner-only dropdown per non-self row. DB enforces
 *   last-owner + self-change guards.
 * - Remove: owner-only destructive button per non-self row. Hard delete
 *   with success toast (no undo for Wave 5).
 * - Leave: self-service button on your own row. Redirects to `/` after.
 *
 * Practitioners see the read-only table; the Actions column shows "—" for
 * them except on their own row, which always carries Leave.
 */
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

  const portalApi = createPortalApi(supabase);
  const membersApi = createPortalMembersApi(supabase);
  const params = await searchParams;
  const practiceId = params.practice ?? '';

  // Fail gracefully when the caller lands here without selecting a
  // practice first (rare but possible via hand-crafted URLs). The
  // dashboard redirect flow is the canonical entry point.
  if (!practiceId) {
    redirect('/dashboard');
  }

  const [members, role] = await Promise.all([
    membersApi.listMembers(practiceId),
    portalApi.getCurrentUserRole(practiceId, user.id),
  ]);
  const isOwner = role === 'owner';

  return (
    <main className="flex min-h-screen flex-col">
      <BrandHeader showSignOut practiceId={practiceId} isOwner={isOwner} />
      <div className="mx-auto w-full max-w-3xl flex-1 px-6 py-10">
        <nav className="mb-4 text-sm text-ink-muted">
          <Link
            href={`/dashboard?practice=${practiceId}`}
            className="hover:text-brand"
          >
            ← Dashboard
          </Link>
        </nav>

        <div className="flex flex-wrap items-start justify-between gap-4">
          <div>
            <h1 className="font-heading text-3xl font-bold">Members</h1>
            <p className="mt-2 max-w-xl text-sm text-ink-muted">
              Everyone who can publish plans under this practice. Every
              member can see the roster; only owners can invite, change
              roles, or remove.
            </p>
          </div>
        </div>

        {members.length === 0 ? (
          <p className="mt-10 rounded-lg border border-surface-border bg-surface-base p-8 text-center text-ink-muted">
            No members found for this practice.
          </p>
        ) : (
          <MembersList
            practiceId={practiceId}
            initialMembers={members}
            isOwner={isOwner}
          />
        )}
      </div>
    </main>
  );
}
