import Link from 'next/link';
import { cookies } from 'next/headers';
import { redirect } from 'next/navigation';
import { getServerClient } from '@/lib/supabase-server';
import { PortalReferralApi } from '@/lib/supabase/api';
import { BrandHeader } from '@/components/BrandHeader';
import { SignUpGate } from '@/components/SignUpGate';

type SearchParams = { ref?: string };

const REFERRAL_COOKIE = 'homefit_referral_code';

// Public sign-up page. Primary role during the referral flow:
//   1. Capture the referral code (from ?ref= or the REFERRAL_COOKIE)
//   2. Present a POPIA-safe consent checkbox with privacy-first default
//   3. Hand off to the existing Google OAuth flow. The cookie + consent
//      persist through the OAuth round-trip so /auth/callback can call
//      claim_referral_code after the practice bootstrap completes.
export default async function SignUpPage({
  searchParams,
}: {
  searchParams: Promise<SearchParams>;
}) {
  const supabase = await getServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (user) redirect('/dashboard');

  const params = await searchParams;
  const cookieStore = await cookies();
  const cookieCode = cookieStore.get(REFERRAL_COOKIE)?.value ?? null;
  const code = params.ref ?? cookieCode ?? null;

  let inviterName: string | null = null;
  if (code) {
    const api = new PortalReferralApi(supabase);
    const meta = await api.landingMeta(code);
    inviterName = meta.inviter_display_name;
  }

  const inviterLabel = inviterName ?? 'A colleague';

  return (
    <main className="flex min-h-screen flex-col">
      <BrandHeader />
      <div className="flex flex-1 items-center justify-center px-5 py-10 sm:px-6 sm:py-16">
        <div className="w-full max-w-md">
          {code && (
            <aside
              className="mb-5 rounded-lg border border-brand-tint-border bg-brand-tint-bg px-4 py-3"
              role="note"
              aria-label="Invitation details"
            >
              <p className="text-sm text-ink">
                <span className="font-semibold">{inviterLabel}</span> invited
                you to homefit.studio.
              </p>
              <p className="mt-1 text-xs text-ink-muted">
                You&rsquo;ll land with 8 free credits the moment you sign
                up (3 on the house, plus 5 more for using this invitation).
              </p>
            </aside>
          )}

          <SignUpGate
            referralCode={code}
            inviterLabel={inviterName ? inviterName : 'your inviter'}
          />

          <p className="mt-6 text-center text-xs text-ink-dim">
            Already have an account?{' '}
            <Link href="/" className="text-brand hover:text-brand-light">
              Sign in
            </Link>
            .
          </p>
        </div>
      </div>
    </main>
  );
}
