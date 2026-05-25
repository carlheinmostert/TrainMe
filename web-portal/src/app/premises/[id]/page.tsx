import { cookies, headers } from 'next/headers';
import { notFound, redirect } from 'next/navigation';
import { getServerClient } from '@/lib/supabase-server';
import { createPortalApi } from '@/lib/supabase/api';
import { BrandHeader } from '@/components/BrandHeader';
import { PremisesDetailPanel } from '@/components/PremisesDetailPanel';
import { ACTIVE_PRACTICE_COOKIE } from '@/lib/active-practice';
import { playerOriginFromHost } from '@/lib/env';

type SearchParams = { practice?: string };
type RouteParams = { id: string };

/**
 * `/premises/[id]` — full-page detail / editor surface for a single
 * premises. Replaces the old `PremisesEditorDialog` modal flow (per
 * R-01 + no-popups-ever — see `feedback_no_popups_ever.md`).
 *
 * Entry points:
 *   - `/premises` list "Add premises" → POST `create_default_premises`
 *     → router.push here with the new id (draft row: placeholder name,
 *     NULL polygon).
 *   - `/premises` list row name / Edit → router.push here.
 *
 * Hydration is server-side via `get_premises` (SECURITY DEFINER +
 * practice-membership check). 404 redirects on missing / not-member.
 */
export default async function PremisesDetailPage({
  params,
  searchParams,
}: {
  params: Promise<RouteParams>;
  searchParams: Promise<SearchParams>;
}) {
  const supabase = await getServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect('/');

  const api = createPortalApi(supabase);
  const [{ id }, queryParams] = await Promise.all([params, searchParams]);
  const practices = await api.listMyPractices();
  if (practices.length === 0) redirect('/dashboard');

  const premises = await api.getPremises(id);
  if (!premises) notFound();

  const cookieStore = await cookies();
  const cookiePractice = cookieStore.get(ACTIVE_PRACTICE_COOKIE)?.value;
  // Prefer the query param (links from /premises preserve practice
  // context), then the premises row's own practice, then the cookie
  // fallback. Premises row's own practice wins authoritatively — the
  // detail surface should reflect the tenant that actually owns the
  // row, not a stale cookie pointing at a different practice.
  const selectedId =
    queryParams.practice ?? premises.practiceId ?? cookiePractice;
  const selected =
    practices.find((p) => p.id === selectedId) ??
    practices.find((p) => p.id === premises.practiceId) ??
    practices[0];
  const role = await api.getCurrentUserRole(selected.id, user.id);
  const isOwner = role === 'owner';

  // Practice slug + player origin → live URL preview in the slug editor.
  const profile = await api.getPracticePublicProfile(selected.id);
  const practiceSlug = profile?.slug ?? null;
  const reqHeaders = await headers();
  const playerOrigin = playerOriginFromHost(reqHeaders.get('host'));

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
        <PremisesDetailPanel
          initial={premises}
          practiceId={selected.id}
          practiceSlug={practiceSlug}
          playerOrigin={playerOrigin}
        />
      </div>
    </main>
  );
}
