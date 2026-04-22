import Link from 'next/link';
import type { Metadata } from 'next';
import { getServerClient } from '@/lib/supabase-server';
import { PortalReferralApi } from '@/lib/supabase/api';
import { HomefitLogo } from '@/components/HomefitLogo';
import { ReferralCookieWriter } from '@/components/ReferralCookieWriter';

type Params = Promise<{ code: string }>;

async function loadMeta(code: string) {
  const supabase = await getServerClient();
  const api = new PortalReferralApi(supabase);
  return api.landingMeta(code);
}

export async function generateMetadata({
  params,
}: {
  params: Params;
}): Promise<Metadata> {
  const { code } = await params;
  const meta = await loadMeta(code);
  const inviter = meta.inviter_display_name ?? 'A homefit.studio practitioner';
  const title = `${inviter} invited you to homefit.studio`;
  const description =
    'Capture a session, share a clean visual plan with your client via WhatsApp. Built for practitioners.';

  return {
    title,
    description,
    openGraph: {
      title,
      description,
      type: 'website',
      siteName: 'homefit.studio',
    },
    twitter: {
      card: 'summary_large_image',
      title,
      description,
    },
  };
}

export default async function ReferralLandingPage({
  params,
}: {
  params: Params;
}) {
  const { code } = await params;
  const meta = await loadMeta(code);

  const inviter = meta.inviter_display_name ?? 'A homefit.studio practitioner';
  const signUpHref = `/sign-up?ref=${encodeURIComponent(code)}`;

  return (
    <main className="flex min-h-screen flex-col">
      {/* Persist referral code in a client-side cookie for users who navigate
          away before signing up. The ?ref= query also carries the code. */}
      <ReferralCookieWriter code={code} />
      <header className="border-b border-surface-border bg-surface-base/80 backdrop-blur">
        <div className="mx-auto flex max-w-5xl items-center px-6 py-4">
          <Link
            href="/"
            className="flex items-center gap-3 text-ink hover:text-brand-light transition"
            aria-label="homefit.studio home"
          >
            <HomefitLogo className="h-7 w-auto" />
            <span className="font-heading text-lg font-semibold">
              homefit.studio
            </span>
          </Link>
        </div>
      </header>

      <section className="flex flex-1 items-start justify-center px-5 py-10 sm:px-6 sm:py-16">
        <div className="w-full max-w-xl">
          {/* Peer-to-peer inviter chip. Voice: "a colleague invited you" — never "earn", "reward". */}
          <p className="inline-flex items-center gap-2 rounded-full border border-brand-tint-border bg-brand-tint-bg px-3 py-1 text-xs font-medium uppercase tracking-wider text-brand-light">
            <span aria-hidden="true" className="h-1.5 w-1.5 rounded-full bg-brand" />
            Invitation
          </p>

          <h1 className="mt-4 font-heading text-3xl font-bold leading-tight sm:text-4xl">
            {inviter} invited you to homefit.studio.
          </h1>

          <p className="mt-4 text-body-lg text-ink-muted">
            Capture a session on your phone, and your client opens a clean
            visual plan via a WhatsApp link. No app install required on
            their side.
          </p>

          <ul className="mt-6 space-y-3 text-body-md text-ink-muted">
            <FeatureRow>
              Capture an exercise in seconds. Your client sees a line-drawing
              demo that respects their privacy.
            </FeatureRow>
            <FeatureRow>
              Build a plan, share the link. Works in WhatsApp, iMessage, or
              email — no account needed on your client&rsquo;s side.
            </FeatureRow>
            <FeatureRow>
              Prepaid credits. Pay once, publish plans for as long as you
              want — credits never expire.
            </FeatureRow>
          </ul>

          <div className="mt-8 flex flex-col items-stretch gap-3 sm:flex-row sm:items-center">
            <Link
              href={signUpHref}
              className="inline-flex items-center justify-center rounded-md bg-brand px-6 py-3 text-base font-semibold text-surface-bg transition hover:bg-brand-light focus-visible:shadow-focus-ring"
            >
              Get started
            </Link>
            <p className="text-xs text-ink-dim">
              You&rsquo;ll land with{' '}
              <span className="font-semibold text-ink-muted">
                8 free credits
              </span>{' '}
              the moment you sign up — 3 on the house, plus 5 more for using this invitation link.
            </p>
          </div>

          <p className="mt-10 text-xs text-ink-dim">
            homefit.studio is made for biokineticists, physiotherapists, and
            other practitioners. Already have an account?{' '}
            <Link href="/" className="text-brand hover:text-brand-light">
              Sign in
            </Link>
            .
          </p>
        </div>
      </section>
    </main>
  );
}

function FeatureRow({ children }: { children: React.ReactNode }) {
  return (
    <li className="flex items-start gap-3">
      <span
        aria-hidden="true"
        className="mt-1.5 h-1.5 w-1.5 flex-none rounded-full bg-brand"
      />
      <span>{children}</span>
    </li>
  );
}
