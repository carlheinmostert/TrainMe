'use client';

import { useEffect, useMemo, useRef, useState } from 'react';
import type { PracticeSession } from '@/lib/supabase/api';

type Props = {
  sessions: PracticeSession[];
  /** True when the caller is the practice owner (drives the practitioner column). */
  isOwnerView: boolean;
};

type Toast = { text: string } | null;

/**
 * Client-side filterable session list. Server passes the full set; search
 * is local (no paging in MVP — practice sessions are tens, not thousands).
 *
 * Design compliance:
 * - R-01: copy fires immediately; no confirm modal. Toast is the feedback.
 * - R-06: copy speaks "session" + "published" + "opened". No "trainer",
 *   "bio", "physio", or "coach" in user-visible strings.
 * - R-09: the search input auto-focuses on mount, the copy button has a
 *   visible clipboard icon.
 *
 * POPIA: trainer email is only rendered when the owner is looking at
 * someone else's session. Practitioners don't see their own email on their
 * own rows — they know who they are.
 */
export function SessionsList({ sessions, isOwnerView }: Props) {
  const [query, setQuery] = useState('');
  const [toast, setToast] = useState<Toast>(null);
  const inputRef = useRef<HTMLInputElement | null>(null);

  useEffect(() => {
    // R-09: search is the primary affordance — focus it on mount.
    inputRef.current?.focus();
  }, []);

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return sessions;
    return sessions.filter((s) => {
      const hay = [
        s.title,
        s.clientName ?? '',
        s.trainerEmail ?? '',
      ]
        .join(' ')
        .toLowerCase();
      return hay.includes(q);
    });
  }, [query, sessions]);

  async function handleCopy(id: string) {
    const url = playerUrl(id);
    try {
      await navigator.clipboard.writeText(url);
      setToast({ text: 'Link copied. Paste it into WhatsApp or iMessage.' });
    } catch {
      setToast({ text: "Couldn't copy — copy the link manually from Open." });
    }
    window.setTimeout(() => setToast(null), 3500);
  }

  if (sessions.length === 0) {
    return (
      <div className="mt-10 rounded-lg border border-surface-border bg-surface-base p-8 text-center text-ink-muted">
        You haven&rsquo;t published any sessions yet. Publish one from the
        mobile app.
      </div>
    );
  }

  return (
    <div>
      {/* Filter */}
      <div className="mt-6">
        <label htmlFor="sessions-search" className="sr-only">
          Search sessions
        </label>
        <div className="relative">
          <input
            id="sessions-search"
            ref={inputRef}
            type="search"
            inputMode="search"
            placeholder="Search by title, client, or practitioner"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            className="w-full rounded-md border border-surface-border bg-surface-raised px-3 py-2 text-sm text-ink placeholder:text-ink-dim focus:border-brand focus:outline-none"
          />
        </div>
        <p className="mt-2 text-xs text-ink-dim">
          {filtered.length} of {sessions.length} sessions
        </p>
      </div>

      {/* Table (desktop) */}
      <div className="mt-4 hidden overflow-hidden rounded-lg border border-surface-border bg-surface-base sm:block">
        <table className="w-full text-left text-sm">
          <thead className="bg-surface-raised text-xs uppercase tracking-wider text-ink-muted">
            <tr>
              <th scope="col" className="px-4 py-3">Session</th>
              {isOwnerView && (
                <th scope="col" className="px-4 py-3">Practitioner</th>
              )}
              <th scope="col" className="px-4 py-3">Last published</th>
              <th scope="col" className="px-4 py-3">Last opened</th>
              <th scope="col" className="px-4 py-3 text-right">Actions</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-surface-border">
            {filtered.map((s) => (
              <tr key={s.id}>
                <td className="px-4 py-3 align-top">
                  <div className="flex items-start gap-2">
                    <div className="min-w-0 flex-1">
                      <p className="font-semibold text-ink">{s.title || 'Untitled'}</p>
                      {s.clientName && (
                        <p className="mt-0.5 text-xs text-ink-muted">
                          {s.clientName}
                        </p>
                      )}
                      <p className="mt-1 text-xs text-ink-dim">
                        {s.issuanceCount} {s.issuanceCount === 1 ? 'share' : 'shares'}
                        {' · '}
                        {s.exerciseCount} {s.exerciseCount === 1 ? 'exercise' : 'exercises'}
                      </p>
                    </div>
                    <VersionChip version={s.version} />
                  </div>
                </td>
                {isOwnerView && (
                  <td className="px-4 py-3 align-top text-xs text-ink-muted">
                    {!s.isOwnSession && s.trainerEmail ? (
                      <span className="break-all">{s.trainerEmail}</span>
                    ) : (
                      <span className="text-ink-dim">You</span>
                    )}
                  </td>
                )}
                {/* TODO(wave-r11-followup): 3-state publish indicator
                 *
                 * Mobile's session card is gaining a three-state publish
                 * indicator — never / published + clean / published +
                 * dirty (edits since sentAt) — in the iPhone Q1 batch.
                 * Once the `last_content_edit_at` column lands on the
                 * plans table + the mobile model, mirror the three
                 * states here: show a "Changes pending" pill (coral)
                 * when `s.lastContentEditAt > s.lastPublishedAt` and a
                 * "Published" tick when clean.
                 */}
                <td className="px-4 py-3 align-top text-xs text-ink-muted">
                  <RelativeTime iso={s.lastPublishedAt} fallback="—" />
                </td>
                <td className="px-4 py-3 align-top text-xs text-ink-muted">
                  <RelativeTime
                    iso={s.firstOpenedAt}
                    fallback="Not opened yet"
                    fallbackClass="text-ink-dim"
                  />
                </td>
                <td className="px-4 py-3 align-top">
                  <div className="flex justify-end gap-2">
                    <button
                      type="button"
                      onClick={() => handleCopy(s.id)}
                      className="inline-flex items-center gap-2 rounded-md border border-brand bg-transparent px-3 py-1.5 text-xs font-semibold text-brand transition hover:bg-brand/10"
                    >
                      <ClipboardIcon />
                      Copy link
                    </button>
                    <a
                      href={playerUrl(s.id)}
                      target="_blank"
                      rel="noopener noreferrer"
                      className="inline-flex items-center gap-1 rounded-md bg-brand px-3 py-1.5 text-xs font-semibold text-surface-bg transition hover:bg-brand-light"
                    >
                      Open
                      <ExternalIcon />
                    </a>
                  </div>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {/* Cards (mobile) */}
      <ul className="mt-4 space-y-3 sm:hidden">
        {filtered.map((s) => (
          <li
            key={s.id}
            className="rounded-lg border border-surface-border bg-surface-base p-4"
          >
            <div className="flex items-start justify-between gap-3">
              <div className="min-w-0">
                <p className="font-semibold text-ink">{s.title || 'Untitled'}</p>
                {s.clientName && (
                  <p className="mt-0.5 text-xs text-ink-muted">{s.clientName}</p>
                )}
              </div>
              <VersionChip version={s.version} />
            </div>

            <dl className="mt-3 grid grid-cols-2 gap-x-3 gap-y-1 text-xs">
              <dt className="text-ink-dim">Published</dt>
              <dd className="text-ink-muted">
                <RelativeTime iso={s.lastPublishedAt} fallback="—" />
              </dd>
              <dt className="text-ink-dim">Opened</dt>
              <dd className="text-ink-muted">
                <RelativeTime
                  iso={s.firstOpenedAt}
                  fallback="Not opened yet"
                  fallbackClass="text-ink-dim"
                />
              </dd>
              {isOwnerView && !s.isOwnSession && s.trainerEmail && (
                <>
                  <dt className="text-ink-dim">Practitioner</dt>
                  <dd className="break-all text-ink-muted">
                    {s.trainerEmail}
                  </dd>
                </>
              )}
              <dt className="text-ink-dim">Details</dt>
              <dd className="text-ink-muted">
                {s.issuanceCount} {s.issuanceCount === 1 ? 'share' : 'shares'}
                {' · '}
                {s.exerciseCount} {s.exerciseCount === 1 ? 'exercise' : 'exercises'}
              </dd>
            </dl>

            <div className="mt-4 flex gap-2">
              <button
                type="button"
                onClick={() => handleCopy(s.id)}
                className="inline-flex flex-1 items-center justify-center gap-2 rounded-md border border-brand bg-transparent px-3 py-2 text-xs font-semibold text-brand transition hover:bg-brand/10"
              >
                <ClipboardIcon />
                Copy link
              </button>
              <a
                href={playerUrl(s.id)}
                target="_blank"
                rel="noopener noreferrer"
                className="inline-flex flex-1 items-center justify-center gap-1 rounded-md bg-brand px-3 py-2 text-xs font-semibold text-surface-bg transition hover:bg-brand-light"
              >
                Open
                <ExternalIcon />
              </a>
            </div>
          </li>
        ))}
      </ul>

      {filtered.length === 0 && sessions.length > 0 && (
        <p className="mt-6 rounded-lg border border-surface-border bg-surface-base p-6 text-center text-sm text-ink-muted">
          No sessions match &ldquo;{query}&rdquo;.
        </p>
      )}

      {/* Toast — R-01: no modal, always a fixed-position status line. */}
      {toast && (
        <div
          role="status"
          aria-live="polite"
          className="pointer-events-none fixed inset-x-0 top-4 z-50 flex justify-center px-4"
        >
          <div className="pointer-events-auto rounded-md border border-surface-border bg-surface-raised px-4 py-3 text-sm text-ink shadow-focus-ring">
            {toast.text}
          </div>
        </div>
      )}
    </div>
  );
}

// ----------------------------------------------------------------------------
// Helpers
// ----------------------------------------------------------------------------

function playerUrl(planId: string): string {
  return `https://session.homefit.studio/p/${planId}`;
}

function VersionChip({ version }: { version: number }) {
  return (
    <span
      className="rounded-full bg-surface-raised px-2 py-0.5 text-[11px] font-semibold uppercase tracking-wider text-ink-muted"
      aria-label={`Version ${version}`}
    >
      v{version}
    </span>
  );
}

/**
 * Render an ISO timestamp as a relative "3 days ago" string with an
 * exact-timestamp `title` attribute for hover. Falls back to the provided
 * text when the timestamp is null.
 */
function RelativeTime({
  iso,
  fallback,
  fallbackClass,
}: {
  iso: string | null;
  fallback: string;
  fallbackClass?: string;
}) {
  if (!iso) {
    return <span className={fallbackClass}>{fallback}</span>;
  }
  const date = new Date(iso);
  const abs = date.toLocaleString('en-ZA', {
    dateStyle: 'medium',
    timeStyle: 'short',
  });
  return <span title={abs}>{relative(date)}</span>;
}

/**
 * Small relative-time formatter. No date-fns dep (constraint: no new
 * deps). Accuracy here is "scannable at a glance", not statistical.
 */
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

function ClipboardIcon() {
  return (
    <svg
      xmlns="http://www.w3.org/2000/svg"
      className="h-3.5 w-3.5"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <rect x="9" y="9" width="13" height="13" rx="2" ry="2" />
      <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" />
    </svg>
  );
}

function ExternalIcon() {
  return (
    <svg
      xmlns="http://www.w3.org/2000/svg"
      className="h-3 w-3"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6" />
      <polyline points="15 3 21 3 21 9" />
      <line x1="10" y1="14" x2="21" y2="3" />
    </svg>
  );
}
