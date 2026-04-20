import Link from 'next/link';
import { redirect } from 'next/navigation';
import { getServerClient } from '@/lib/supabase-server';
import { createPortalApi } from '@/lib/supabase/api';
import { BrandHeader } from '@/components/BrandHeader';
import { AccountPanel } from '@/components/AccountPanel';

type SearchParams = { practice?: string };

// App version. Kept as a constant + env override so CI can bake a real value
// later. TODO: wire to web-portal/package.json.version at build time.
const APP_VERSION =
  process.env.NEXT_PUBLIC_APP_VERSION ?? '0.1.0';

// Build SHA. Vercel exposes this automatically to builds. Falls back to 'dev'
// for local development. Rendered at 35% opacity (R-08 equivalent to the
// Flutter build-marker on the Pulse Mark footer).
const BUILD_SHA =
  process.env.NEXT_PUBLIC_VERCEL_GIT_COMMIT_SHA?.slice(0, 7) ??
  process.env.VERCEL_GIT_COMMIT_SHA?.slice(0, 7) ??
  'dev';

export default async function AccountPage({
  searchParams,
}: {
  searchParams: Promise<SearchParams>;
}) {
  const supabase = await getServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect('/');

  const params = await searchParams;
  const practiceId = params.practice ?? '';

  // Resolve role so the header can surface the owner-only Members link
  // while the caller is on /account. No practice in the qs → default to
  // false (the Members link hides, matching the practitioner fallback).
  const api = createPortalApi(supabase);
  const role = practiceId
    ? await api.getCurrentUserRole(practiceId, user.id)
    : null;
  const isOwner = role === 'owner';

  return (
    <main className="flex min-h-screen flex-col">
      <BrandHeader showSignOut practiceId={practiceId} isOwner={isOwner} />
      <div className="mx-auto w-full max-w-2xl flex-1 px-6 py-10">
        <nav className="mb-4 text-sm text-ink-muted">
          <Link
            href={practiceId ? `/dashboard?practice=${practiceId}` : '/dashboard'}
            className="hover:text-brand"
          >
            ← Dashboard
          </Link>
        </nav>

        <h1 className="font-heading text-3xl font-bold">Account</h1>
        <p className="mt-2 text-sm text-ink-muted">
          Signed in as{' '}
          <span className="text-ink">{user.email ?? 'unknown'}</span>.
        </p>

        <AccountPanel email={user.email ?? ''} />

        <section
          className="mt-12 border-t border-surface-border pt-8"
          aria-labelledby="about-heading"
        >
          <h2
            id="about-heading"
            className="font-heading text-lg font-semibold"
          >
            About
          </h2>
          <dl className="mt-4 grid grid-cols-[auto_1fr] gap-x-6 gap-y-2 text-sm">
            <dt className="text-ink-muted">App</dt>
            <dd className="text-ink">homefit.studio practice portal</dd>

            <dt className="text-ink-muted">Version</dt>
            <dd className="text-ink font-mono">{APP_VERSION}</dd>

            <dt className="text-ink-muted">Build</dt>
            <dd className="font-mono text-ink opacity-[0.35]">{BUILD_SHA}</dd>
          </dl>
        </section>
      </div>
    </main>
  );
}
