'use client';

import { useRouter, useSearchParams, usePathname } from 'next/navigation';
import { useMemo, useState } from 'react';
import type { AuditChipTone } from '@/lib/supabase/api';

/**
 * AuditFilterBar — URL-driven filter controls for /audit.
 *
 * Design:
 *   - All state lives in the URL so links are shareable and the back
 *     button navigates filter history.
 *   - The bar is a controlled form — local state mirrors the URL, edits
 *     stay local until "Apply" to avoid URL spam + re-renders on every
 *     keystroke.
 *   - On Apply / Clear we `router.push` a new URL with the updated
 *     search params; the server component re-runs the RPC.
 *
 * Why Client Component: form state + event handlers + router.push. The
 * parent page is a Server Component that reads the params from the URL
 * and passes down the option lists + current values.
 */

export type ActorOption = {
  trainerId: string;
  email: string;
  fullName: string;
};

export type KindOption = {
  kind: string;
  label: string;
  tone: AuditChipTone;
};

export function AuditFilterBar({
  practiceId,
  actors,
  kindGroups,
  initialKinds,
  initialActor,
  initialFrom,
  initialTo,
}: {
  practiceId: string;
  actors: ActorOption[];
  kindGroups: { tone: AuditChipTone; label: string; kinds: KindOption[] }[];
  initialKinds: string[];
  initialActor: string | null;
  initialFrom: string | null;
  initialTo: string | null;
}) {
  const router = useRouter();
  const pathname = usePathname();
  const sp = useSearchParams();

  const [selectedKinds, setSelectedKinds] =
    useState<Set<string>>(new Set(initialKinds));
  const [actor, setActor] = useState<string>(initialActor ?? '');
  const [fromDate, setFromDate] = useState<string>(initialFrom ?? '');
  const [toDate, setToDate] = useState<string>(initialTo ?? '');

  const selectedCount = selectedKinds.size;
  const hasAnyFilter = useMemo(
    () => selectedCount > 0 || actor !== '' || fromDate !== '' || toDate !== '',
    [selectedCount, actor, fromDate, toDate],
  );

  function toggleKind(kind: string) {
    setSelectedKinds((prev) => {
      const next = new Set(prev);
      if (next.has(kind)) next.delete(kind);
      else next.add(kind);
      return next;
    });
  }

  function apply() {
    const params = new URLSearchParams(sp.toString());
    params.set('practice', practiceId);
    // Reset pagination on filter change — offset only makes sense within a
    // fixed filter set.
    params.delete('offset');

    if (selectedKinds.size > 0) {
      params.set('kinds', Array.from(selectedKinds).join(','));
    } else {
      params.delete('kinds');
    }
    if (actor) params.set('actor', actor);
    else params.delete('actor');
    if (fromDate) params.set('from', fromDate);
    else params.delete('from');
    if (toDate) params.set('to', toDate);
    else params.delete('to');

    router.push(`${pathname}?${params.toString()}`);
  }

  function clearAll() {
    setSelectedKinds(new Set());
    setActor('');
    setFromDate('');
    setToDate('');
    const params = new URLSearchParams();
    params.set('practice', practiceId);
    router.push(`${pathname}?${params.toString()}`);
  }

  return (
    <section
      className="mt-6 rounded-lg border border-surface-border bg-surface-base p-4"
      aria-label="Audit filters"
    >
      <div className="flex flex-col gap-4">
        {/* Kind multi-select, grouped by chip tone. */}
        <div>
          <div className="mb-2 flex items-baseline justify-between">
            <label className="text-xs font-medium uppercase tracking-wider text-ink-muted">
              Kind
            </label>
            {selectedCount > 0 && (
              <button
                type="button"
                className="text-xs text-ink-muted hover:text-brand"
                onClick={() => setSelectedKinds(new Set())}
              >
                Clear ({selectedCount})
              </button>
            )}
          </div>
          <div className="flex flex-col gap-2">
            {kindGroups.map((group) => (
              <div key={group.label} className="flex flex-wrap gap-1.5">
                <span className="mr-1 self-center text-[10px] uppercase tracking-wider text-ink-dim">
                  {group.label}
                </span>
                {group.kinds.map((k) => {
                  const active = selectedKinds.has(k.kind);
                  return (
                    <button
                      key={k.kind}
                      type="button"
                      onClick={() => toggleKind(k.kind)}
                      className={
                        'rounded-full px-2.5 py-1 text-xs transition ' +
                        (active
                          ? chipClass(group.tone, true)
                          : chipClass(group.tone, false))
                      }
                      aria-pressed={active}
                    >
                      {k.label}
                    </button>
                  );
                })}
              </div>
            ))}
          </div>
        </div>

        {/* Bottom row: Practitioner dropdown + Date range + Apply/Clear. */}
        <div className="flex flex-wrap items-end gap-4">
          <label className="flex min-w-[180px] flex-col gap-1">
            <span className="text-xs font-medium uppercase tracking-wider text-ink-muted">
              Practitioner
            </span>
            <select
              value={actor}
              onChange={(e) => setActor(e.target.value)}
              className="rounded-md border border-surface-border bg-surface-raised px-2 py-1.5 text-sm text-ink"
            >
              <option value="">All practitioners</option>
              {actors.map((a) => (
                <option key={a.trainerId} value={a.trainerId}>
                  {actorLabel(a)}
                </option>
              ))}
            </select>
          </label>

          <label className="flex flex-col gap-1">
            <span className="text-xs font-medium uppercase tracking-wider text-ink-muted">
              From
            </span>
            <input
              type="date"
              value={fromDate}
              onChange={(e) => setFromDate(e.target.value)}
              className="rounded-md border border-surface-border bg-surface-raised px-2 py-1.5 text-sm text-ink"
            />
          </label>

          <label className="flex flex-col gap-1">
            <span className="text-xs font-medium uppercase tracking-wider text-ink-muted">
              To
            </span>
            <input
              type="date"
              value={toDate}
              onChange={(e) => setToDate(e.target.value)}
              className="rounded-md border border-surface-border bg-surface-raised px-2 py-1.5 text-sm text-ink"
            />
          </label>

          <div className="flex flex-1 justify-end gap-2">
            {hasAnyFilter && (
              <button
                type="button"
                onClick={clearAll}
                className="rounded-md border border-surface-border bg-surface-raised px-3 py-1.5 text-sm text-ink-muted transition hover:text-ink"
              >
                Clear filters
              </button>
            )}
            <button
              type="button"
              onClick={apply}
              className="rounded-md bg-brand px-4 py-1.5 text-sm font-medium text-white transition hover:bg-brand-dark"
            >
              Apply
            </button>
          </div>
        </div>
      </div>
    </section>
  );
}

function actorLabel(a: ActorOption): string {
  if (a.fullName && a.fullName.trim().length > 0) {
    return `${a.fullName.trim()} (${a.email})`;
  }
  return a.email;
}

function chipClass(tone: AuditChipTone, active: boolean): string {
  if (active) {
    switch (tone) {
      case 'coral':
        return 'bg-brand-tint-bg text-brand ring-1 ring-brand';
      case 'sage':
        return 'bg-emerald-500/25 text-emerald-300 ring-1 ring-emerald-400';
      case 'red':
        return 'bg-red-500/25 text-red-300 ring-1 ring-red-400';
      default:
        return 'bg-surface-raised text-ink ring-1 ring-ink-muted';
    }
  }
  switch (tone) {
    case 'coral':
      return 'bg-brand-tint-bg/50 text-brand hover:bg-brand-tint-bg';
    case 'sage':
      return 'bg-emerald-500/10 text-emerald-400 hover:bg-emerald-500/20';
    case 'red':
      return 'bg-red-500/10 text-red-400 hover:bg-red-500/20';
    default:
      return 'bg-surface-raised text-ink-muted hover:text-ink';
  }
}
