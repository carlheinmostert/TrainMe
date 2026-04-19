import Link from 'next/link';
import { redirect } from 'next/navigation';
import { getServerClient } from '@/lib/supabase-server';
import { BrandHeader } from '@/components/BrandHeader';
import { BUNDLES, zar } from '@/lib/bundles';
import { BuyBundleButton } from '@/components/BuyBundleButton';

type SearchParams = { practice?: string };

export default async function CreditsPage({
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
      <BrandHeader showSignOut practiceId={practiceId} />
      <div className="mx-auto w-full max-w-5xl flex-1 px-6 py-10">
        <nav className="mb-4 text-sm text-ink-muted">
          <Link
            href={`/dashboard?practice=${practiceId}`}
            className="hover:text-brand"
          >
            ← Dashboard
          </Link>
        </nav>

        <h1 className="font-heading text-3xl font-bold">Buy credits</h1>
        <p className="mt-2 text-sm text-ink-muted">
          One credit is charged each time you publish a plan to a client.
          Payments are processed securely by PayFast (ZAR).
        </p>

        <div className="mt-8 grid gap-6 sm:grid-cols-2 lg:grid-cols-3">
          {BUNDLES.map((b) => {
            const perCredit = b.priceZar / b.credits;
            return (
              <article
                key={b.key}
                className="flex flex-col rounded-lg border border-surface-border bg-surface-base p-6"
              >
                <h2 className="font-heading text-xl font-bold">{b.name}</h2>
                <p className="mt-1 text-sm text-ink-muted">
                  {b.credits} credits
                </p>
                <p className="mt-4 font-heading text-3xl font-bold text-brand">
                  {zar(b.priceZar)}
                </p>
                <p className="mt-1 text-xs text-ink-dim">
                  {zar(perCredit)} per credit
                </p>

                <BuyBundleButton
                  bundleKey={b.key}
                  bundleName={b.name}
                  practiceId={practiceId}
                />
              </article>
            );
          })}
        </div>
      </div>
    </main>
  );
}
