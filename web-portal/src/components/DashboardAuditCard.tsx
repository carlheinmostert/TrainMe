'use client';

import type { ReactNode } from 'react';
import Link from 'next/link';
import * as Tooltip from '@radix-ui/react-tooltip';
import { Info } from 'lucide-react';
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
  /** Rendered icon JSX for the left slot — same affordance pattern as
   *  DashboardTile so the dashboard grid reads consistently. Pass a
   *  JSX element, not a component reference (RSC boundary forbids
   *  passing function refs as props to client components). */
  icon: ReactNode;
  /** Tooltip copy. Plain English, one sentence. */
  description: string;
};

/**
 * DashboardAuditCard — Wave 40 P4 tile that previews the 5 most-recent
 * audit events. Cosmetic pass (2026-05-22) mirrors the DashboardTile
 * upgrades: left 40px icon slot + Radix Tooltip on hover with a touch-
 * viewport info glyph.
 *
 * Polish bundle (2026-05-22, C-7/C-8):
 *   - C-7: split into TWO independent `Tooltip.Root` instances — one
 *     for the main Link, one for the touch info button. Sharing a
 *     single Root caused Radix to anchor the popover at viewport (0,0)
 *     because two `Trigger asChild` siblings violate Radix's one-anchor
 *     model. Each Root now owns its own Trigger + Portal + Content.
 *   - C-8: wrapper div + Link both carry `h-full` so the audit card
 *     stretches to match the tallest sibling in its grid row (and lets
 *     its row-mates match THIS card when it's the tallest — which it
 *     usually is with 5 preview rows in flight).
 */
export function DashboardAuditCard({
  href,
  rows,
  error,
  icon,
  description,
}: Props) {
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
    <div className="relative h-full sm:col-span-2">
      <Tooltip.Root>
        <Tooltip.Trigger asChild>
          <Link
            href={href}
            className="group relative flex h-full items-start gap-4 rounded-lg border border-surface-border bg-surface-base p-5 transition hover:border-brand hover:shadow-focus-ring focus:outline-none focus-visible:border-brand focus-visible:shadow-focus-ring"
          >
            <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-md text-ink-muted transition group-hover:text-brand group-focus-visible:text-brand">
              {icon}
            </div>
            <div className="flex min-w-0 flex-1 flex-col">
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
            </div>
          </Link>
        </Tooltip.Trigger>

        <Tooltip.Portal>
          <Tooltip.Content
            side="top"
            sideOffset={6}
            collisionPadding={12}
            className="z-50 max-w-[280px] rounded-md border border-surface-border bg-surface-raised px-3 py-2 text-xs leading-snug text-ink shadow-[0_8px_24px_rgba(0,0,0,0.35)] animate-[fadeSlideUp_120ms_ease-out]"
          >
            {description}
            <Tooltip.Arrow className="fill-surface-raised" />
          </Tooltip.Content>
        </Tooltip.Portal>
      </Tooltip.Root>

      <TouchInfoTooltip description={description} />
    </div>
  );
}

function TouchInfoTooltip({ description }: { description: string }) {
  return (
    <Tooltip.Root>
      <Tooltip.Trigger asChild>
        <button
          type="button"
          aria-label="What is this?"
          onClick={(e) => {
            e.preventDefault();
            e.stopPropagation();
          }}
          className="pointer-events-auto absolute right-3 top-3 hidden h-6 w-6 items-center justify-center rounded-full text-ink-dim hover:text-brand focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand/40 [@media(hover:none)]:flex"
        >
          <Info size={14} strokeWidth={1.75} aria-hidden="true" />
        </button>
      </Tooltip.Trigger>

      <Tooltip.Portal>
        <Tooltip.Content
          side="top"
          sideOffset={6}
          collisionPadding={12}
          className="z-50 max-w-[280px] rounded-md border border-surface-border bg-surface-raised px-3 py-2 text-xs leading-snug text-ink shadow-[0_8px_24px_rgba(0,0,0,0.35)] animate-[fadeSlideUp_120ms_ease-out]"
        >
          {description}
          <Tooltip.Arrow className="fill-surface-raised" />
        </Tooltip.Content>
      </Tooltip.Portal>
    </Tooltip.Root>
  );
}

/* AuditPreviewRow rendered inside a parent Link → use <span>s, not
   list items with anchors, to avoid nested-interactive markup. */
function AuditPreviewRow({ row }: { row: AuditRow }) {
  const tone = auditChipTone(row.kind);
  const actorLabel = row.email ?? '—';
  const actorTooltip =
    row.kind === 'plan.opened' && row.email
      ? 'Plan owner — opened by anonymous client'
      : actorLabel;

  return (
    <li className="flex items-center gap-3 py-2 text-xs">
      <KindChip kind={row.kind} tone={tone} />
      <span
        className="min-w-0 flex-1 truncate text-ink-muted"
        title={actorTooltip}
      >
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
