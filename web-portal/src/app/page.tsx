import { Suspense } from 'react';
import { redirect } from 'next/navigation';
import { getServerClient } from '@/lib/supabase-server';
import { BrandHeader } from '@/components/BrandHeader';
import { SignInGate } from '@/components/SignInGate';
import { safeNext } from '@/lib/safe-next';

type SearchParams = { next?: string };

// Home — authenticated users jump to ?next= (or /dashboard if absent),
// everyone else sees sign-in.
//
// Wave 32 fix: previously this branch unconditionally redirected to
// /dashboard, which dropped the `?next=/credits` plumbing whenever the
// caller already had a valid session cookie. The mobile credits chip
// flow exposed this — Safari already had a session, so the chain went
// /credits → /?next=/credits → /dashboard and the user landed in the
// wrong place. Honour ?next= here too, with the same `safeNext` clamp
// the SignInGate and /auth/callback use.
export default async function HomePage({
  searchParams,
}: {
  searchParams: Promise<SearchParams>;
}) {
  const supabase = await getServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const params = await searchParams;
  const next = safeNext(params.next);

  // Diagnostic — Wave 32. Captured in Vercel runtime logs so Carl can
  // confirm the redirect chain on his next mobile QA run. Cheap to keep.
  // eslint-disable-next-line no-console
  console.log(
    `[redirect-chain] home/page → signed-in: ${Boolean(user)}, next: ${
      params.next ?? '(none)'
    }, redirect to: ${user ? next : '(render sign-in)'}`,
  );

  if (user) {
    redirect(next);
  }

  return (
    <main className="flex min-h-screen flex-col">
      <BrandHeader />
      <div className="flex flex-1 items-center justify-center px-6 py-12">
        {/* Suspense boundary — SignInGate uses useSearchParams to read */}
        {/* the ?next= post-sign-in destination; required by Next 15. */}
        <Suspense fallback={null}>
          <SignInGate />
        </Suspense>
      </div>
    </main>
  );
}
