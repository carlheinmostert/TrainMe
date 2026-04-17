import Link from 'next/link';
import { redirect } from 'next/navigation';
import { getServerClient } from '@/lib/supabase-server';
import { BrandHeader } from '@/components/BrandHeader';

type SearchParams = { pid?: string; practice?: string };

// PayFast redirects the buyer here after a successful payment. Credits are
// NOT yet applied at this point — the authoritative signal is the ITN
// webhook (server-to-server). This page just reassures the buyer and sends
// them back to their dashboard where the balance will update shortly.
export default async function CreditsReturnPage({
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
        <div className="rounded-lg border border-brand/40 bg-brand/10 p-8 text-center">
          <h1 className="font-heading text-2xl font-bold text-brand">
            Payment received
          </h1>
          <p className="mt-3 text-sm text-ink">
            Thanks — PayFast has acknowledged your payment. Your credits will
            appear on your dashboard as soon as we receive PayFast&rsquo;s
            confirmation notification (usually within a few seconds).
          </p>
          {params.pid && (
            <p className="mt-4 text-xs text-ink-dim">
              Reference: <code className="font-mono">{params.pid}</code>
            </p>
          )}
          <div className="mt-8 flex justify-center gap-3">
            <Link
              href={
                practiceId
                  ? `/dashboard?practice=${practiceId}`
                  : '/dashboard'
              }
              className="rounded-md bg-brand px-5 py-2.5 text-sm font-semibold text-surface-bg transition hover:bg-brand-light"
            >
              Back to dashboard
            </Link>
            <Link
              href={
                practiceId ? `/credits?practice=${practiceId}` : '/credits'
              }
              className="rounded-md border border-surface-border px-5 py-2.5 text-sm font-semibold text-ink transition hover:border-brand"
            >
              Buy another bundle
            </Link>
          </div>
        </div>
      </div>
    </main>
  );
}
