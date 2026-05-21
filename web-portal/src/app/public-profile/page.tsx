import { cookies } from 'next/headers';
import Link from 'next/link';
import { redirect } from 'next/navigation';
import { getServerClient } from '@/lib/supabase-server';
import { createPortalApi } from '@/lib/supabase/api';
import { BrandHeader } from '@/components/BrandHeader';
import { ACTIVE_PRACTICE_COOKIE } from '@/lib/active-practice';
import { PublicProfileEditor } from './PublicProfileEditor';

type SearchParams = { practice?: string; section?: 'branding' | 'identity' };

/**
 * `/public-profile` — the owner-facing editor for branding (logo +
 * brand colour) and identity / directory listing (slug + tagline +
 * blurb + specialties + contact links).
 *
 * Mirrors `/premises` shape: server component, picks an active
 * practice via cookie + ?practice= query, gets role + profile in
 * parallel, hands them to the client `PublicProfileEditor` shell.
 *
 * The two panels (Branding + Identity) live behind `<details>`
 * accordions per R-01 ("inline state only, no modals").
 */
export default async function PublicProfilePage({
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

  const [role, profile] = await Promise.all([
    api.getCurrentUserRole(selected.id, user.id),
    api.getPracticePublicProfile(selected.id),
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
      <div className="mx-auto w-full max-w-3xl flex-1 px-6 py-10">
        <nav className="mb-4 text-sm text-ink-muted">
          <Link href={`/dashboard${qs}`} className="hover:text-brand">
            ← Dashboard
          </Link>
        </nav>

        <div className="mb-6 flex flex-col gap-2">
          <h1 className="font-heading text-3xl font-bold">Public profile</h1>
          <p className="text-sm text-ink-muted">
            What clients see at{' '}
            <code className="rounded bg-surface-raised px-1 py-0.5 text-[11px] text-ink">
              session.homefit.studio/v/{profile?.slug ?? 'your-slug'}
            </code>
            . Logo + brand color also cascade into every plan you publish.
          </p>
          {profile?.slug && profile.listed && (
            <a
              href={`https://session.homefit.studio/v/${profile.slug}`}
              target="_blank"
              rel="noopener noreferrer"
              className="self-start rounded-md border border-surface-border bg-surface-raised px-3 py-1.5 text-xs text-ink hover:border-brand hover:text-brand"
            >
              Preview your page ↗
            </a>
          )}
        </div>

        <PublicProfileEditor
          practiceId={selected.id}
          practiceName={selected.name}
          isOwner={isOwner}
          initial={profile}
          initialSection={params.section}
        />
      </div>
    </main>
  );
}
