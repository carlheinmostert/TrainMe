import Link from 'next/link';
import { redirect } from 'next/navigation';
import { getServerClient } from '@/lib/supabase-server';
import {
  createPortalApi,
  type PlanIssuanceRow as IssuanceRow,
} from '@/lib/supabase/api';
import { BrandHeader } from '@/components/BrandHeader';

type SearchParams = { practice?: string };

function fmtDate(iso: string) {
  try {
    return new Date(iso).toLocaleString('en-ZA', {
      dateStyle: 'medium',
      timeStyle: 'short',
    });
  } catch {
    return iso;
  }
}

function extractTitle(row: IssuanceRow): string {
  const p = row.plans;
  if (!p) return '—';
  const single = Array.isArray(p) ? p[0] : p;
  return single?.title ?? '—';
}

export default async function AuditPage({
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
  const practiceId = params.practice ?? '';
  const rows = practiceId ? await api.listRecentIssuances(practiceId) : [];

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

        <h1 className="font-heading text-3xl font-bold">Audit log</h1>
        <p className="mt-2 text-sm text-ink-muted">
          50 most recent plan issuances for this practice.
        </p>

        {rows.length === 0 ? (
          <p className="mt-10 rounded-lg border border-surface-border bg-surface-base p-8 text-center text-ink-muted">
            No issuances yet. Publish a plan from the mobile app to see it
            here.
          </p>
        ) : (
          <div className="mt-8 overflow-hidden rounded-lg border border-surface-border bg-surface-base">
            <table className="w-full text-left text-sm">
              <thead className="bg-surface-raised text-xs uppercase tracking-wider text-ink-muted">
                <tr>
                  <th scope="col" className="px-4 py-3">Date</th>
                  <th scope="col" className="px-4 py-3">Trainer</th>
                  <th scope="col" className="px-4 py-3">Plan title</th>
                  <th scope="col" className="px-4 py-3">Credits</th>
                  <th scope="col" className="px-4 py-3">URL</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-surface-border">
                {rows.map((r) => (
                  <tr key={r.id}>
                    <td className="px-4 py-3 text-ink-muted">
                      {fmtDate(r.created_at)}
                    </td>
                    <td className="px-4 py-3 font-mono text-xs text-ink-dim">
                      {r.trainer_id ? r.trainer_id.slice(0, 8) : '—'}
                    </td>
                    <td className="px-4 py-3">{extractTitle(r)}</td>
                    <td className="px-4 py-3 text-brand">
                      {r.credits_charged ?? 0}
                    </td>
                    <td className="px-4 py-3">
                      {r.plan_url ? (
                        <a
                          href={r.plan_url}
                          target="_blank"
                          rel="noopener noreferrer"
                          className="text-brand hover:underline"
                        >
                          Open
                        </a>
                      ) : (
                        '—'
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </main>
  );
}
