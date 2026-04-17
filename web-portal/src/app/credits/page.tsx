import Link from 'next/link';
import { redirect } from 'next/navigation';
import { getServerClient } from '@/lib/supabase-server';
import { BrandHeader } from '@/components/BrandHeader';

// Hardcoded bundles for the POV. Will move to a DB table once PayFast is
// wired up in Milestone D4 (so we can version prices without a redeploy).
const BUNDLES = [
  { key: 'starter', name: 'Starter', credits: 10, priceZar: 250 },
  { key: 'practice', name: 'Practice', credits: 50, priceZar: 1125 },
  { key: 'clinic', name: 'Clinic', credits: 200, priceZar: 4000 },
] as const;

function zar(amount: number) {
  return new Intl.NumberFormat('en-ZA', {
    style: 'currency',
    currency: 'ZAR',
    maximumFractionDigits: 0,
  }).format(amount);
}

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
      <BrandHeader showSignOut />
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
        </p>

        {/* Milestone D4 banner — remove once PayFast is wired up. */}
        <div
          role="status"
          className="mt-6 rounded-lg border border-warn/40 bg-warn/10 px-4 py-3 text-sm text-warn"
        >
          <strong className="font-semibold">Milestone D4 TODO:</strong>{' '}
          PayFast checkout wiring is pending. &ldquo;Buy&rdquo; buttons
          currently hit a stub route that returns a placeholder URL.
        </div>

        <div className="mt-8 grid gap-6 sm:grid-cols-2 lg:grid-cols-3">
          {BUNDLES.map((b) => {
            const perCredit = b.priceZar / b.credits;
            return (
              <article
                key={b.key}
                className="flex flex-col rounded-lg border border-surface-border bg-surface-base p-6 shadow-card"
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

                <form
                  action="/credits/purchase"
                  method="post"
                  className="mt-6"
                >
                  <input type="hidden" name="bundle" value={b.key} />
                  <input type="hidden" name="practice" value={practiceId} />
                  <button
                    type="submit"
                    className="w-full rounded-md bg-brand px-4 py-2.5 text-sm font-semibold text-surface-bg transition hover:bg-brand-light focus-visible:outline-brand"
                  >
                    Buy {b.name}
                  </button>
                </form>
              </article>
            );
          })}
        </div>
      </div>
    </main>
  );
}
