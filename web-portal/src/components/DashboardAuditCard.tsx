import Link from 'next/link';
import {
  auditChipTone,
  type AuditChipTone,
  type AuditRow,
} from '@/lib/supabase/api';
import { ClientTime } from './ClientTime';

type Props = {
  href: string;
  rows: AuditRow[];
  /** Set when the underlying RPC failed; surfaced inline so the tile
   *  doesn't pretend "no events" when really the call errored. */
  error?: string | null;
};

/**
 * DashboardAuditCard — Wave 40 P4. Dashboard tile that previews the 5
 * most-recent audit events for the active practice. Replaces the old
 * single-line "Last publish" tile (which rendered a relative timestamp
 * but no row payload).
 *
 * Each row: kind chip (auditChipTone palette) + actor email (or "Client"
 * for anon plan.opened) + `<ClientTime>` relative timestamp. The whole
 * card is a `<Link>` to `/audit?practice=…` so it follows R-12.5 (single
 * affordance style — every tile clickable). No inline interaction.
 *
 * Empty state: "No events yet — publish from mobile to fill this." Same
 * tone as the old subtitle copy so practitioners with empty practices
 * see consistent guidance.
 */
export function DashboardAuditCard({ href, rows, error }: Props) {
  const hasRows = rows.length > 0 && !error;
  const headline = error
    ? 'Audit unavailable'
    : hasRows
      ? `${rows.length} ${rows.length === 1 ? 'event' : 'events'}`
      : 'No events yet';
  const subtitle = error
    ? 'Try again from /audit'
    : hasRows
      ? 'See full log'
      : 'Publish from mobile to fill this';

  return (
    <Link
      href={href}
      className="group relative flex flex-col rounded-lg border border-surface-border bg-surface-base p-5 transition hover:border-brand hover:shadow-focus-ring focus:outline-none focus-visible:border-brand focus-visible:shadow-focus-ring sm:col-span-2"
    >
      <div className="flex items-baseline justify-between gap-3">
        <p className="text-xs font-medium uppercase tracking-wider text-ink-muted">
          Audit
        </p>
        <p className="flex items-center gap-1 text-xs text-ink-muted">
          <span>{subtitle}</span>
          <ChevronRight />
        </p>
      </div>
      <p className="mt-1 font-heading text-2xl font-bold leading-tight text-brand">
        {headline}
      </p>

      {hasRows && (
        <ul className="mt-4 flex flex-col divide-y divide-surface-border/60">
          {rows.map((r, idx) => (
            <AuditPreviewRow key={`${r.ts}-${r.kind}-${idx}`} row={r} />
          ))}
        </ul>
      )}
    </Link>
  );
}

function AuditPreviewRow({ row }: { row: AuditRow }) {
  const tone = auditChipTone(row.kind);
  const isClientActor =
    row.kind === 'plan.opened' && !row.email && !row.trainerId;
  const actorLabel = row.email
    ? row.email
    : isClientActor
      ? 'Client'
      : '—';

  return (
    <li className="flex items-center gap-3 py-2 text-xs">
      <KindChip kind={row.kind} tone={tone} />
      <span className="min-w-0 flex-1 truncate text-ink-muted" title={actorLabel}>
        {actorLabel}
      </span>
      <span className="shrink-0 whitespace-nowrap text-ink-dim">
        <ClientTime ts={row.ts} />
      </span>
    </li>
  );
}

function KindChip({ kind, tone }: { kind: string; tone: AuditChipTone }) {
  return (
    <span
      className={`inline-block shrink-0 rounded-full px-2 py-0.5 text-[10px] font-medium ${chipClass(tone)}`}
    >
      {kindShortLabel(kind)}
    </span>
  );
}

function chipClass(tone: AuditChipTone): string {
  switch (tone) {
    case 'coral':
      return 'bg-brand-tint-bg text-brand';
    case 'sage':
      return 'bg-emerald-500/15 text-emerald-400';
    case 'red':
      return 'bg-red-500/15 text-red-400';
    default:
      return 'bg-surface-raised text-ink-muted';
  }
}

/**
 * Short label for the dashboard preview — drops the namespace prefix so
 * the chip stays compact (the audit page already shows the full label).
 * "plan.publish" → "publish", "credit.consumption" → "consumption", etc.
 */
function kindShortLabel(kind: string): string {
  const dot = kind.indexOf('.');
  const tail = dot >= 0 ? kind.slice(dot + 1) : kind;
  return tail.replaceAll('_', ' ');
}

function ChevronRight() {
  return (
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      className="h-3.5 w-3.5 text-ink-dim transition group-hover:translate-x-0.5 group-hover:text-brand group-focus-visible:translate-x-0.5 group-focus-visible:text-brand"
      aria-hidden="true"
    >
      <polyline points="9 18 15 12 9 6" />
    </svg>
  );
}
