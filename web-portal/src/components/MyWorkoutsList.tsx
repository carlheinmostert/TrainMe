'use client';

import { useMemo, useState } from 'react';
import Link from 'next/link';
import type { MyWorkout } from '@/lib/supabase/api';
import { SourceTagChip } from './SourceTagChip';

/**
 * M29 (2026-05-26) — view-only list of the practitioner's My Workouts.
 *
 * Mirrors the visual shape of `SessionsList` (`/clients/[id]` session
 * list) but:
 *  - No Copy-link / Open-in-player actions — drill-in routes through
 *    `/my-workouts/[id]` for read-only inspection.
 *  - Adds the SourceTagChip alongside the title (today every row is
 *    `self`).
 *  - No practitioner column — every row's practitioner is the caller.
 *
 * Search is local (practitioner workout volume is small; pagination
 * would be premature).
 */
export function MyWorkoutsList({
  workouts,
  practiceQs,
}: {
  workouts: MyWorkout[];
  /** Active practice qs to thread into drill-in links. Empty string OK
   *  for users whose Self-clients span multiple practices — the drill-in
   *  derives the practice from the workout row's `practice_id`. */
  practiceQs: string;
}) {
  const [query, setQuery] = useState('');

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return workouts;
    return workouts.filter((w) =>
      [w.title, w.clientName ?? '', w.sharedByEmail ?? '']
        .join(' ')
        .toLowerCase()
        .includes(q),
    );
  }, [query, workouts]);

  if (workouts.length === 0) {
    return (
      <div className="mt-10 rounded-lg border border-surface-border bg-surface-base p-8 text-center text-ink-muted">
        <p>No self-captures yet.</p>
        <p className="mt-2 text-xs text-ink-dim">
          Open the iOS app and record a workout from My Workouts — it will
          appear here once published.
        </p>
      </div>
    );
  }

  return (
    <div>
      <div className="mt-6">
        <label htmlFor="my-workouts-search" className="sr-only">
          Search workouts
        </label>
        <input
          id="my-workouts-search"
          type="search"
          inputMode="search"
          placeholder="Search by title"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          className="w-full rounded-md border border-surface-border bg-surface-raised px-3 py-2 text-sm text-ink placeholder:text-ink-dim focus:border-brand focus:outline-none"
        />
        <p className="mt-2 text-xs text-ink-dim">
          {filtered.length} of {workouts.length} workouts
        </p>
      </div>

      {/* Cards — single column at every breakpoint. The dataset is small;
          a table felt heavier than necessary for a view-only surface. */}
      <ul className="mt-4 space-y-3">
        {filtered.map((w) => (
          <li
            key={w.id}
            className="rounded-lg border border-surface-border bg-surface-base"
          >
            <Link
              href={`/my-workouts/${w.id}${practiceQs}`}
              className="block px-4 py-4 transition hover:bg-surface-raised"
            >
              <div className="flex items-start gap-3">
                <div className="min-w-0 flex-1">
                  <div className="flex items-center gap-2 flex-wrap">
                    <p className="font-semibold text-ink">
                      {w.title || 'Untitled workout'}
                    </p>
                    <SourceTagChip
                      sourceTag={w.sourceTag}
                      sharedByEmail={w.sharedByEmail}
                    />
                  </div>
                  <p className="mt-1 text-xs text-ink-dim">
                    {w.issuanceCount}{' '}
                    {w.issuanceCount === 1 ? 'share' : 'shares'}
                    {' · '}
                    {w.exerciseCount}{' '}
                    {w.exerciseCount === 1 ? 'exercise' : 'exercises'}
                    {' · v'}
                    {w.version}
                  </p>
                  <p className="mt-2 text-xs text-ink-muted">
                    <RelativeTime
                      iso={w.lastPublishedAt}
                      fallback="Not published yet"
                    />
                  </p>
                </div>
                <span className="text-ink-dim" aria-hidden="true">
                  &rsaquo;
                </span>
              </div>
            </Link>
          </li>
        ))}
      </ul>

      {filtered.length === 0 && workouts.length > 0 && (
        <p className="mt-6 rounded-lg border border-surface-border bg-surface-base p-6 text-center text-sm text-ink-muted">
          No workouts match &ldquo;{query}&rdquo;.
        </p>
      )}
    </div>
  );
}

/**
 * Local mini RelativeTime. Lighter than importing the SessionsList
 * helper; the My Workouts surface only renders one timestamp per row.
 */
function RelativeTime({
  iso,
  fallback,
}: {
  iso: string | null;
  fallback: string;
}) {
  if (!iso) {
    return <span className="text-ink-dim">{fallback}</span>;
  }
  const t = Date.parse(iso);
  if (!Number.isFinite(t)) {
    return <span className="text-ink-dim">{fallback}</span>;
  }
  const deltaMs = Date.now() - t;
  const fmt = formatRelative(deltaMs);
  return (
    <span title={new Date(t).toLocaleString()}>Published {fmt}</span>
  );
}

function formatRelative(deltaMs: number): string {
  const absMs = Math.abs(deltaMs);
  const past = deltaMs >= 0;
  const minutes = Math.round(absMs / 60_000);
  if (minutes < 1) return past ? 'just now' : 'in a moment';
  if (minutes < 60) return past ? `${minutes}m ago` : `in ${minutes}m`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return past ? `${hours}h ago` : `in ${hours}h`;
  const days = Math.round(hours / 24);
  if (days < 30) return past ? `${days}d ago` : `in ${days}d`;
  const months = Math.round(days / 30);
  if (months < 12) return past ? `${months}mo ago` : `in ${months}mo`;
  const years = Math.round(months / 12);
  return past ? `${years}y ago` : `in ${years}y`;
}
