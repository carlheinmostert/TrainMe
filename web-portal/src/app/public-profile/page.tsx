import { cookies, headers } from 'next/headers';
import Link from 'next/link';
import { redirect } from 'next/navigation';
import { getServerClient } from '@/lib/supabase-server';
import { createPortalApi } from '@/lib/supabase/api';
import { BrandHeader } from '@/components/BrandHeader';
import { ACTIVE_PRACTICE_COOKIE } from '@/lib/active-practice';
import { playerOriginFromHost } from '@/lib/env';
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

  // Derive the player origin from the current portal host so the
  // Preview button + inline `<code>` label point at the same deploy
  // ring (staging-portal → staging-player, prod-portal → prod-player).
  // Without this, the staging button 404s on the prod player because
  // Public Profile v2 isn't promoted to prod yet.
  const reqHeaders = await headers();
  const playerOrigin = playerOriginFromHost(reqHeaders.get('host'));
  // Display hostname for the inline `<code>` label (strip protocol).
  const playerHostLabel = playerOrigin.replace(/^https?:\/\//, '');

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
              {playerHostLabel}/v/{profile?.slug ?? 'your-slug'}
            </code>
            . Logo + brand color also cascade into every plan you publish.
          </p>
          {/* Preview button: gate on `listed` because get_practice_profile
              filters WHERE public_profile_listed = true for ALL callers
              (anon + authenticated owner alike), so an unlisted slug 404s
              even for its owner. Downgraded from hidden to disabled-with-
              tooltip so practitioners can see the affordance exists. */}
          {profile?.slug ? (
            profile.listed ? (
              <a
                href={`${playerOrigin}/v/${profile.slug}`}
                target="_blank"
                rel="noopener noreferrer"
                className="self-start rounded-md border border-surface-border bg-surface-raised px-3 py-1.5 text-xs text-ink hover:border-brand hover:text-brand"
              >
                Preview your page ↗
              </a>
            ) : (
              <span
                title="Toggle 'List in the directory' to preview — the public page is hidden until the practice is listed."
                aria-disabled="true"
                className="cursor-not-allowed self-start rounded-md border border-surface-border bg-surface-raised px-3 py-1.5 text-xs text-ink-muted opacity-60"
              >
                Preview your page ↗
              </span>
            )
          ) : null}
        </div>

        <PublicProfileEditor
          practiceId={selected.id}
          practiceName={selected.name}
          isOwner={isOwner}
          initial={profile}
          initialSection={params.section}
          playerHostLabel={playerHostLabel}
        />
      </div>
    </main>
  );
}
