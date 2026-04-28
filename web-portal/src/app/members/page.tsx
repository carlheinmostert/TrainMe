import Link from 'next/link';
import { cookies } from 'next/headers';
import { redirect } from 'next/navigation';
import { getServerClient } from '@/lib/supabase-server';
import { createPortalApi, createPortalMembersApi } from '@/lib/supabase/api';
import { BrandHeader } from '@/components/BrandHeader';
import { MembersList } from '@/components/MembersList';
import { ACTIVE_PRACTICE_COOKIE } from '@/lib/active-practice';

// Wave 35 — never cache this route. The /members page reads the current
// roster + pending list on every render so role changes, removes, and
// adds reflect immediately on F5 / Cmd-R. Without this, Next.js 15.x's
// default RSC cache could replay a stale payload after `router.refresh()`
// and confuse the practitioner into thinking the role flip didn't take.
export const dynamic = 'force-dynamic';

type SearchParams = { practice?: string };

/**
 * /members — practice roster with owner-only add-by-email, pending list,
 * role change, remove, and leave. Wave 14 supersedes the Wave 5
 * invite-code flow: there's no more /join/:code landing page and the
 * invitee never handles a share URL or 7-character code. Instead, the
 * owner types their colleague's email and clicks Add; if the email
 * already has a homefit.studio account they're added immediately, and
 * if not the email is parked in pending_practice_members until they
 * sign up (a trigger on auth.users INSERT drains it).
 *
 * Sections:
 *   1. Add form (owner only) — email input + Add button. The inline
 *      toast routes on the RPC's `kind` discriminator: 'added' →
 *      success, 'already_member' → friendly "already there", 'pending'
 *      → "we'll add them automatically on signup".
 *   2. Members table — identical shape to Wave 5. Email · Name · Role
 *      · Joined · Actions. Own row tagged "you" with Leave.
 *   3. Pending table (owner only) — email · added by · added at ·
 *      Remove. Practitioners don't see this section because pending
 *      is strictly an owner-admin signal — other members have no
 *      actions they can take on pending rows.
 *
 * Design compliance:
 *   - R-01 (no modal confirms): Add + Remove-pending fire immediately;
 *     destructive errors surface as inline toasts, never confirmation
 *     dialogs.
 *   - R-06 (practitioner vocabulary): copy uses "member" / "practitioner"
 *     / "owner" throughout.
 *   - R-09 (obvious defaults): the Add form is the primary CTA at the
 *     top of the section, not buried in a disclosure.
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
  // Resolution order: explicit `?practice=` (in-portal Link), then the
  // `hf_active_practice` cookie set by middleware on the most recent
  // app→portal handoff. Middleware 302-strips the param after setting
  // the cookie, so without this fallback the dashboard tile click
  // bounces here, finds no param, and redirects back to /dashboard.
  const cookieStore = await cookies();
  const cookiePractice = cookieStore.get(ACTIVE_PRACTICE_COOKIE)?.value ?? '';
  const practiceId = params.practice ?? cookiePractice;

  // Fail gracefully when the caller lands here without selecting a
  // practice first (rare but possible via hand-crafted URLs). The
  // dashboard redirect flow is the canonical entry point.
  if (!practiceId) {
    redirect('/dashboard');
  }

  const [{ members, pending }, role, practices] = await Promise.all([
    membersApi.listMembersAndPending(practiceId),
    portalApi.getCurrentUserRole(practiceId, user.id),
    portalApi.listMyPractices(),
  ]);
  const isOwner = role === 'owner';

  return (
    <main className="flex min-h-screen flex-col">
      <BrandHeader
        showSignOut
        practiceId={practiceId}
        isOwner={isOwner}
        userEmail={user.email ?? ''}
        practices={practices}
      />
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
              Everyone who can publish plans under this practice. Owners
              can add practitioners by email; if the email already has a
              homefit.studio account they&rsquo;re added immediately, and
              if not they&rsquo;ll join automatically when they sign up.
            </p>
          </div>
        </div>

        <MembersList
          practiceId={practiceId}
          initialMembers={members}
          initialPending={pending}
          isOwner={isOwner}
        />
      </div>
    </main>
  );
}
