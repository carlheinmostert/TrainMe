import type {
  ReferralDashboardStats,
  ReferralRefereeRow,
} from '@/lib/supabase/api';

type Props = {
  stats: ReferralDashboardStats;
  referees: ReferralRefereeRow[];
};

// "Network earnings" card.
//
// Voice constraint: peer-to-peer. NEVER "earn rewards", "commission",
// "cash", "payout". Labels below use the user-friendly framing:
//   - "Free publishes available" (not "credits earned")
//   - "Free publishes banked" (not "lifetime earned")
//   - "Practitioners in your network" (not "referrals", not "downline")
//   - "Their PayFast spend" (neutral, observational)
//
// Empty state (R-04): a friendly nudge, never a guilt-trip about emptiness.
export function NetworkEarningsCard({ stats, referees }: Props) {
  const isEmpty = referees.length === 0 && stats.referee_count === 0;

  return (
    <section
      className="rounded-lg border border-surface-border bg-surface-base p-5"
      aria-labelledby="network-earnings-heading"
    >
      <h2
        id="network-earnings-heading"
        className="font-heading text-lg font-semibold"
      >
        Network rebate
      </h2>
      <p className="mt-1 text-sm text-ink-muted">
        Every PayFast purchase in your network adds a 5% rebate to your
        credit balance. Rebates never expire.
      </p>

      <div className="mt-5 grid grid-cols-2 gap-3 sm:grid-cols-4">
        <StatTile
          label="Free publishes available"
          value={fmtCredits(stats.rebate_balance_credits)}
          emphasis
        />
        <StatTile
          label="Free publishes banked"
          value={fmtCredits(stats.lifetime_rebate_credits)}
        />
        <StatTile
          label="Practitioners in your network"
          value={String(stats.referee_count)}
        />
        <StatTile
          label="Their PayFast spend"
          value={fmtZar(stats.qualifying_spend_total_zar)}
        />
      </div>

      {isEmpty ? (
        <EmptyState />
      ) : (
        <div className="mt-5 overflow-hidden rounded-md border border-surface-border">
          <div className="max-h-80 overflow-y-auto">
            <table className="w-full text-sm">
              <thead className="sticky top-0 bg-surface-raised text-xs uppercase tracking-wider text-ink-muted">
                <tr>
                  <th className="px-3 py-2 text-left font-medium">
                    Practitioner
                  </th>
                  <th className="px-3 py-2 text-left font-medium">Joined</th>
                  <th className="px-3 py-2 text-right font-medium">
                    Their spend
                  </th>
                  <th className="px-3 py-2 text-right font-medium">
                    Rebate for you
                  </th>
                </tr>
              </thead>
              <tbody className="divide-y divide-surface-border">
                {referees.map((r, idx) => (
                  <tr key={`${r.referee_practice_id ?? 'anon'}-${idx}`}>
                    <td className="px-3 py-2 text-ink">
                      <span className="flex items-center gap-2">
                        {r.is_named ? (
                          <span>{r.referee_label}</span>
                        ) : (
                          <span className="text-ink-muted">
                            {r.referee_label}
                          </span>
                        )}
                        {!r.is_named && (
                          <span
                            className="rounded-full border border-surface-border px-2 py-0.5 text-[10px] uppercase tracking-wider text-ink-dim"
                            title="This practitioner hasn't consented to being named."
                          >
                            Private
                          </span>
                        )}
                      </span>
                    </td>
                    <td className="px-3 py-2 text-ink-muted">
                      {fmtJoinDate(r.joined_at)}
                    </td>
                    <td className="px-3 py-2 text-right text-ink">
                      {fmtZar(r.qualifying_spend_zar)}
                    </td>
                    <td className="px-3 py-2 text-right font-semibold text-brand">
                      {fmtCredits(r.rebate_earned_credits)}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}
    </section>
  );
}

function StatTile({
  label,
  value,
  emphasis,
}: {
  label: string;
  value: string;
  emphasis?: boolean;
}) {
  return (
    <div className="rounded-md border border-surface-border bg-surface-raised px-3 py-3">
      <p className="text-[11px] font-medium uppercase tracking-wider text-ink-muted">
        {label}
      </p>
      <p
        className={`mt-1 font-heading text-xl font-bold ${emphasis ? 'text-brand' : 'text-ink'}`}
      >
        {value}
      </p>
    </div>
  );
}

function EmptyState() {
  return (
    <div className="mt-6 rounded-md border border-dashed border-surface-border bg-surface-raised/40 px-4 py-8 text-center">
      <p className="text-sm text-ink">
        No practitioners yet. Your code&rsquo;s ready when you are.
      </p>
      <p className="mt-1 text-xs text-ink-muted">
        Share the link above with a colleague — WhatsApp works best.
      </p>
    </div>
  );
}

/* -------------------------------------------------------------------------- */
/*  Formatters                                                                */
/* -------------------------------------------------------------------------- */

function fmtCredits(n: number): string {
  const rounded = Math.round(n * 10) / 10;
  const display =
    Number.isInteger(rounded) ? String(Math.round(rounded)) : rounded.toFixed(1);
  return `${display}`;
}

function fmtZar(n: number): string {
  return new Intl.NumberFormat('en-ZA', {
    style: 'currency',
    currency: 'ZAR',
    maximumFractionDigits: 0,
  }).format(n);
}

function fmtJoinDate(iso: string): string {
  if (!iso) return '—';
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return '—';
  return new Intl.DateTimeFormat('en-ZA', {
    month: 'short',
    day: 'numeric',
    year: 'numeric',
  }).format(d);
}
