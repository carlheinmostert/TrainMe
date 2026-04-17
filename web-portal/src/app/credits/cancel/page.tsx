import Link from 'next/link';
import { redirect } from 'next/navigation';
import { getServerClient } from '@/lib/supabase-server';
import { BrandHeader } from '@/components/BrandHeader';

type SearchParams = { pid?: string; practice?: string };

// PayFast sends the buyer here if they hit Cancel during checkout. No
// credits are issued; the pending_payments row stays `pending` until a
// future cleanup job marks it `cancelled` (or the webhook upgrades it on a
// retry).
export default async function CreditsCancelPage({
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

  return (
    <main className="flex min-h-screen flex-col">
      <BrandHeader showSignOut />
      <div className="mx-auto w-full max-w-2xl flex-1 px-6 py-16">
        <div className="rounded-lg border border-surface-border bg-surface-base p-8 text-center">
          <h1 className="font-heading text-2xl font-bold">
            Payment cancelled
          </h1>
          <p className="mt-3 text-sm text-ink-muted">
            No charge was made and no credits were purchased. You can try
            again whenever you&rsquo;re ready.
          </p>
          <div className="mt-8 flex justify-center gap-3">
            <Link
              href={
                practiceId ? `/credits?practice=${practiceId}` : '/credits'
              }
              className="rounded-md bg-brand px-5 py-2.5 text-sm font-semibold text-surface-bg transition hover:bg-brand-light"
            >
              Try again
            </Link>
            <Link
              href={
                practiceId
                  ? `/dashboard?practice=${practiceId}`
                  : '/dashboard'
              }
              className="rounded-md border border-surface-border px-5 py-2.5 text-sm font-semibold text-ink transition hover:border-brand"
            >
              Back to dashboard
            </Link>
          </div>
        </div>
      </div>
    </main>
  );
}
