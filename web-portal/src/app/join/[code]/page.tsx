import Link from 'next/link';
import type { Metadata } from 'next';
import { getServerClient } from '@/lib/supabase-server';
import { BrandHeader } from '@/components/BrandHeader';
import { JoinInvite } from './JoinInvite';
import { JoinSignInPrompt } from './JoinSignInPrompt';

type Params = Promise<{ code: string }>;

export async function generateMetadata({
  params,
}: {
  params: Params;
}): Promise<Metadata> {
  const { code } = await params;
  return {
    title: `Join a practice · homefit.studio`,
    description: `Accept the invite to collaborate on a homefit.studio practice.`,
    robots: { index: false, follow: false },
    openGraph: {
      title: 'You were invited to join a practice on homefit.studio',
      description:
        'Accept the invite to start publishing plans with your colleagues.',
      type: 'website',
      siteName: 'homefit.studio',
    },
    alternates: { canonical: `/join/${encodeURIComponent(code)}` },
  };
}

/**
 * /join/:code — invite-claim landing page.
 *
 * Flow:
 *   1. If unauthenticated → bounce to sign-in with `?redirectTo=/join/{code}`
 *      preserved in the query, so once the user finishes the magic-link
 *      round-trip they come straight back here.
 *   2. If authenticated → render the "Join as practitioner" CTA and hand
 *      the claim to the client-side `JoinInvite` component (needs the
 *      browser Supabase client because the claim RPC must run under the
 *      same session cookies the sign-in just set).
 *
 * We deliberately do NOT "peek" at the invite code server-side. Wave 5
 * ships without a `peek` RPC because it would need its own auth-less
 * surface and leaks nothing useful — the practice name appears only
 * after the claim succeeds. If a user wants to know what they're
 * joining, they can ask the owner who sent them the link.
 */
export default async function JoinPage({ params }: { params: Params }) {
  const { code } = await params;
  const normalized = code.toUpperCase();

  const supabase = await getServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    // Not signed in → render the sign-in sub-page with the join path
    // preserved so the auth callback can bounce straight back here.
    // `next` is the querystring shape consumed by `/auth/callback`.
    return <JoinSignInPrompt code={normalized} />;
  }

  return (
    <main className="flex min-h-screen flex-col">
      <BrandHeader />
      <section className="flex flex-1 items-start justify-center px-5 py-10 sm:px-6 sm:py-16">
        <div className="w-full max-w-xl">
          <p className="inline-flex items-center gap-2 rounded-full border border-brand-tint-border bg-brand-tint-bg px-3 py-1 text-xs font-medium uppercase tracking-wider text-brand-light">
            <span
              aria-hidden="true"
              className="h-1.5 w-1.5 rounded-full bg-brand"
            />
            Practice invitation
          </p>

          <h1 className="mt-4 font-heading text-3xl font-bold leading-tight sm:text-4xl">
            Join a practice.
          </h1>

          <p className="mt-4 text-body-lg text-ink-muted">
            Someone shared an invite code with you. Accept it to start
            publishing plans with their practice.
          </p>

          <JoinInvite code={normalized} />

          <p className="mt-10 text-xs text-ink-dim">
            Not what you expected?{' '}
            <Link href="/dashboard" className="text-brand hover:text-brand-light">
              Back to dashboard
            </Link>
            .
          </p>
        </div>
      </section>
    </main>
  );
}
