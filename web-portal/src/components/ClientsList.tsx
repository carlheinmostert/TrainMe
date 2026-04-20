'use client';

import Link from 'next/link';
import { useEffect, useMemo, useRef, useState } from 'react';
import type { PracticeClient, PracticeSession } from '@/lib/supabase/api';

type Props = {
  clients: PracticeClient[];
  /** Every session the caller can see — used to derive per-client counts and
   *  the practitioner email badge on the card (owner view only). */
  sessions: PracticeSession[];
  /** True when the signed-in user is the practice owner. Unlocks the
   *  per-practitioner filter and the "Practitioner: {email}" card metadata. */
  isOwnerView: boolean;
  /** Query-string fragment to preserve the active practice across links. */
  practiceQs: string;
};

type ClientStats = {
  sessionCount: number;
  /** Most recent publish across this client's sessions, ISO string or null. */
  lastPublishedAt: string | null;
  /** Email of the practitioner who most-recently published for this client.
   *  Used in the owner-view "Practitioner: ..." row. `You` is not carried here
   *  because we want owner rows to identify the author explicitly. */
  recentPractitionerEmail: string | null;
  /** Trainer id of the most-recent publisher; used by the practitioner filter. */
  recentTrainerId: string | null;
};

/**
 * Clients listing with search + (owner-only) practitioner filter. Server
 * passes every client and every session the caller can see; filtering is
 * local — the practice scale (tens of clients and sessions, not thousands)
 * makes a paginated RPC overkill for MVP. Revisit when a single practice
 * passes ~300 rows.
 *
 * Design compliance:
 * - R-01: every affordance fires immediately. No confirms. This page has
 *   no destructive action — deletes live on the detail page (and even
 *   there, we don't delete clients yet; that's a follow-up).
 * - R-06: copy says "practitioner" and "client", never "trainer"/"bio"/
 *   "physio"/"coach" in user-visible strings.
 * - R-09: the search input auto-focuses on mount; the practitioner filter
 *   defaults to "All practitioners" (owner) — no inferred dimming.
 */
export function ClientsList({
  clients,
  sessions,
  isOwnerView,
  practiceQs,
}: Props) {
  const [query, setQuery] = useState('');
  const [practitionerEmail, setPractitionerEmail] = useState<string>('all');
  const inputRef = useRef<HTMLInputElement | null>(null);

  useEffect(() => {
    inputRef.current?.focus();
  }, []);

  // Build stats map: clientName -> { sessionCount, lastPublishedAt, ... }.
  // Join is by name because `list_practice_sessions` exposes `client_name`
  // but not `client_id` (the RPC pre-dates Milestone G's client_id column).
  // Same-name across practices is a non-issue — both inputs are already
  // scoped to this practice by their respective RPCs.
  const statsByName = useMemo(() => {
    const m = new Map<string, ClientStats>();
    for (const s of sessions) {
      const name = s.clientName?.trim();
      if (!name) continue;
      const prior = m.get(name);
      if (!prior) {
        m.set(name, {
          sessionCount: 1,
          lastPublishedAt: s.lastPublishedAt,
          recentPractitionerEmail: s.trainerEmail ?? null,
          recentTrainerId: s.trainerId || null,
        });
        continue;
      }
      prior.sessionCount += 1;
      // Keep the latest publish as canonical; trainer metadata follows it.
      const priorTime = prior.lastPublishedAt
        ? new Date(prior.lastPublishedAt).getTime()
        : -Infinity;
      const thisTime = s.lastPublishedAt
        ? new Date(s.lastPublishedAt).getTime()
        : -Infinity;
      if (thisTime > priorTime) {
        prior.lastPublishedAt = s.lastPublishedAt;
        prior.recentPractitionerEmail = s.trainerEmail ?? null;
        prior.recentTrainerId = s.trainerId || null;
      }
    }
    return m;
  }, [sessions]);

  // Distinct practitioner options for the owner filter. Derived from the
  // sessions list (not a separate roster call) — only practitioners who
  // actually published something show up, which matches the filter intent.
  const practitionerOptions = useMemo(() => {
    if (!isOwnerView) return [];
    const seen = new Map<string, string>(); // email -> email (also acts as set)
    for (const s of sessions) {
      if (s.trainerEmail && !seen.has(s.trainerEmail)) {
        seen.set(s.trainerEmail, s.trainerEmail);
      }
    }
    return Array.from(seen.keys()).sort();
  }, [sessions, isOwnerView]);

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    return clients.filter((c) => {
      if (q && !c.name.toLowerCase().includes(q)) return false;
      if (practitionerEmail !== 'all') {
        const s = statsByName.get(c.name);
        if (!s || s.recentPractitionerEmail !== practitionerEmail) return false;
      }
      return true;
    });
  }, [clients, query, practitionerEmail, statsByName]);

  if (clients.length === 0) {
    return (
      <div className="mt-10 rounded-lg border border-surface-border bg-surface-base p-8 text-center text-ink-muted">
        You&rsquo;ll see clients here once you publish a plan for them.
      </div>
    );
  }

  return (
    <div>
      <div className="mt-6 grid gap-3 sm:grid-cols-[1fr_auto]">
        <div>
          <label htmlFor="clients-search" className="sr-only">
            Search clients
          </label>
          <input
            id="clients-search"
            ref={inputRef}
            type="search"
            inputMode="search"
            placeholder="Search clients by name"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            className="w-full rounded-md border border-surface-border bg-surface-raised px-3 py-2 text-sm text-ink placeholder:text-ink-dim focus:border-brand focus:outline-none"
          />
        </div>

        {isOwnerView && practitionerOptions.length > 0 && (
          <div>
            <label htmlFor="clients-practitioner" className="sr-only">
              Filter by practitioner
            </label>
            <select
              id="clients-practitioner"
              value={practitionerEmail}
              onChange={(e) => setPractitionerEmail(e.target.value)}
              className="w-full rounded-md border border-surface-border bg-surface-raised px-3 py-2 text-sm text-ink focus:border-brand focus:outline-none sm:w-auto"
            >
              <option value="all">All practitioners</option>
              {practitionerOptions.map((email) => (
                <option key={email} value={email}>
                  {email}
                </option>
              ))}
            </select>
          </div>
        )}
      </div>

      <p className="mt-2 text-xs text-ink-dim">
        {filtered.length} of {clients.length}{' '}
        {clients.length === 1 ? 'client' : 'clients'}
      </p>

      <ul className="mt-4 grid gap-3 sm:grid-cols-2">
        {filtered.map((c) => {
          const stats = statsByName.get(c.name);
          return (
            <li key={c.id}>
              <Link
                href={`/clients/${c.id}${practiceQs}`}
                className="flex h-full flex-col rounded-lg border border-surface-border bg-surface-base p-4 transition hover:border-brand hover:shadow-focus-ring focus-visible:border-brand focus-visible:outline-none"
              >
                <div className="flex items-start justify-between gap-3">
                  <h3 className="font-heading text-base font-semibold text-ink">
                    {c.name}
                  </h3>
                  <ConsentChip consent={c.videoConsent} />
                </div>

                <p className="mt-2 text-xs text-ink-muted">
                  {stats
                    ? `${stats.sessionCount} ${stats.sessionCount === 1 ? 'session' : 'sessions'}`
                    : 'No sessions yet'}
                  {stats?.lastPublishedAt && (
                    <>
                      {' · shared '}
                      <RelativeTime iso={stats.lastPublishedAt} />
                    </>
                  )}
                </p>

                {isOwnerView && stats?.recentPractitionerEmail && (
                  <p className="mt-2 text-xs text-ink-dim">
                    Practitioner:{' '}
                    <span className="break-all text-ink-muted">
                      {stats.recentPractitionerEmail}
                    </span>
                  </p>
                )}
              </Link>
            </li>
          );
        })}
      </ul>

      {filtered.length === 0 && clients.length > 0 && (
        <p className="mt-6 rounded-lg border border-surface-border bg-surface-base p-6 text-center text-sm text-ink-muted">
          No clients match those filters.
        </p>
      )}
    </div>
  );
}

// ----------------------------------------------------------------------------
// Consent chip — composable "Line drawing only" / "+ Grayscale" / "+ Original"
// ----------------------------------------------------------------------------

function ConsentChip({
  consent,
}: {
  consent: { grayscale: boolean; original: boolean };
}) {
  const parts: { label: string; tone: 'muted' | 'tint' | 'brand' }[] = [
    { label: 'Line drawing', tone: 'muted' },
  ];
  if (consent.grayscale) parts.push({ label: 'B&W', tone: 'tint' });
  if (consent.original) parts.push({ label: 'Colour', tone: 'brand' });

  // Single-chip rendering with separators. Consent expands rather than
  // replacing — matches the voice: additive, not paternalistic.
  const colourClass =
    parts.some((p) => p.tone === 'brand')
      ? 'border-brand/60 bg-brand/10 text-brand-light'
      : parts.some((p) => p.tone === 'tint')
        ? 'border-brand/30 bg-brand/[0.06] text-ink'
        : 'border-surface-border bg-surface-raised text-ink-muted';

  const label =
    parts.length === 1
      ? 'Line drawing only'
      : parts
          .map((p, i) => (i === 0 ? p.label : `+ ${p.label}`))
          .join(' ');

  return (
    <span
      className={`inline-flex shrink-0 items-center rounded-full border px-2 py-0.5 text-[11px] font-medium tracking-wide ${colourClass}`}
    >
      {label}
    </span>
  );
}

// ----------------------------------------------------------------------------
// Relative-time helper — kept local to avoid a new shared util until it's
// needed by a third surface. SessionsList has its own copy; we'd collapse
// them at that point.
// ----------------------------------------------------------------------------

function RelativeTime({ iso }: { iso: string }) {
  const date = new Date(iso);
  const abs = date.toLocaleString('en-ZA', {
    dateStyle: 'medium',
    timeStyle: 'short',
  });
  return <span title={abs}>{relative(date)}</span>;
}

function relative(d: Date): string {
  const diffMs = Date.now() - d.getTime();
  const diffSec = Math.round(diffMs / 1000);
  if (diffSec < 60) return 'just now';
  const diffMin = Math.round(diffSec / 60);
  if (diffMin < 60) return `${diffMin} min${diffMin === 1 ? '' : 's'} ago`;
  const diffHr = Math.round(diffMin / 60);
  if (diffHr < 24) return `${diffHr} hour${diffHr === 1 ? '' : 's'} ago`;
  const diffDay = Math.round(diffHr / 24);
  if (diffDay < 7) return `${diffDay} day${diffDay === 1 ? '' : 's'} ago`;
  const diffWk = Math.round(diffDay / 7);
  if (diffWk < 5) return `${diffWk} week${diffWk === 1 ? '' : 's'} ago`;
  const diffMo = Math.round(diffDay / 30);
  if (diffMo < 12) return `${diffMo} month${diffMo === 1 ? '' : 's'} ago`;
  const diffYr = Math.round(diffDay / 365);
  return `${diffYr} year${diffYr === 1 ? '' : 's'} ago`;
}
