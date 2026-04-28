'use client';

import Link from 'next/link';
import { useEffect, useMemo, useRef, useState } from 'react';
import { getBrowserClient } from '@/lib/supabase-browser';
import {
  createPortalApi,
  DeleteClientError,
  type PracticeClient,
  type PracticeSession,
} from '@/lib/supabase/api';
import { ClientAvatar } from './ClientAvatar';

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
  /**
   * Client ids removed optimistically by a Delete-with-Undo flow. The
   * row vanishes immediately; Undo re-adds it. Kept out of the `clients`
   * prop to let the server-rendered list stay the source of truth for
   * the initial render.
   */
  const [hiddenIds, setHiddenIds] = useState<Set<string>>(new Set());
  /**
   * Delete-in-flight toast. Carries enough state to fire Undo without
   * re-reading the row. 7-second auto-dismiss per the R-01 undo window.
   */
  const [toast, setToast] = useState<DeleteToast | null>(null);
  const inputRef = useRef<HTMLInputElement | null>(null);
  const toastTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    inputRef.current?.focus();
  }, []);

  // On mount, check for a pending Undo marker left by the detail page's
  // Delete action (it navigates back here; the toast needs to surface
  // on the list, not the unmounted detail component). Entries older
  // than the 7-second window are ignored.
  useEffect(() => {
    try {
      const raw = sessionStorage.getItem('portalUndoDelete');
      if (!raw) return;
      sessionStorage.removeItem('portalUndoDelete');
      const parsed = JSON.parse(raw) as {
        clientId: string;
        clientName: string;
        firedAtMs: number;
      };
      const age = Date.now() - (parsed.firedAtMs ?? 0);
      if (age < 0 || age > 7000) return;
      const remaining = Math.max(1000, 7000 - age);
      // Hide the row even though server-side render included it (server
      // used a snapshot taken before the delete landed). We also seed
      // the toast's client field from the marker — the prop-level clients
      // list may well include the row, but we don't rely on it.
      setHiddenIds((prev) => {
        const next = new Set(prev);
        next.add(parsed.clientId);
        return next;
      });
      const fallbackClient = clients.find((c) => c.id === parsed.clientId);
      if (fallbackClient) {
        setToast({
          kind: 'deleted',
          text: `${parsed.clientName || fallbackClient.name} deleted`,
          client: fallbackClient,
        });
        if (toastTimer.current) clearTimeout(toastTimer.current);
        toastTimer.current = setTimeout(() => setToast(null), remaining);
      }
    } catch {
      // sessionStorage + JSON errors are non-fatal.
    }
    // Only run once on mount with the initial clients prop. Subsequent
    // prop changes don't need a re-check; the marker was consumed above.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Cancel the pending auto-dismiss on unmount; avoids a state update
  // on an unmounted component if the user navigates away mid-window.
  useEffect(() => {
    return () => {
      if (toastTimer.current) clearTimeout(toastTimer.current);
    };
  }, []);

  function scheduleToastDismiss() {
    if (toastTimer.current) clearTimeout(toastTimer.current);
    toastTimer.current = setTimeout(() => setToast(null), 7000);
  }

  async function handleDelete(client: PracticeClient) {
    // Optimistic hide.
    setHiddenIds((prev) => {
      const next = new Set(prev);
      next.add(client.id);
      return next;
    });

    try {
      const api = createPortalApi(getBrowserClient());
      await api.deleteClient(client.id);
    } catch (e) {
      // Rollback on failure. Show a plain error toast.
      setHiddenIds((prev) => {
        const next = new Set(prev);
        next.delete(client.id);
        return next;
      });
      const msg =
        e instanceof DeleteClientError
          ? e.kind === 'not-member'
            ? `You don't have permission to delete ${client.name}.`
            : `${client.name} not found.`
          : e instanceof Error
            ? `Couldn't delete — ${e.message}`
            : "Couldn't delete.";
      setToast({ kind: 'error', text: msg, client: null });
      scheduleToastDismiss();
      return;
    }

    setToast({
      kind: 'deleted',
      text: `${client.name} deleted`,
      client,
    });
    scheduleToastDismiss();
  }

  async function handleUndo(client: PracticeClient) {
    if (toastTimer.current) clearTimeout(toastTimer.current);
    setToast(null);
    try {
      const api = createPortalApi(getBrowserClient());
      await api.restoreClient(client.id);
    } catch (e) {
      const msg =
        e instanceof Error ? `Couldn't undo — ${e.message}` : "Couldn't undo.";
      setToast({ kind: 'error', text: msg, client: null });
      scheduleToastDismiss();
      return;
    }
    // Reinstate the row.
    setHiddenIds((prev) => {
      const next = new Set(prev);
      next.delete(client.id);
      return next;
    });
  }

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
      if (hiddenIds.has(c.id)) return false;
      if (q && !c.name.toLowerCase().includes(q)) return false;
      if (practitionerEmail !== 'all') {
        const s = statsByName.get(c.name);
        if (!s || s.recentPractitionerEmail !== practitionerEmail) return false;
      }
      return true;
    });
  }, [clients, hiddenIds, query, practitionerEmail, statsByName]);

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
            <li key={c.id} className="group relative">
              <Link
                href={`/clients/${c.id}${practiceQs}`}
                className="flex h-full flex-col rounded-lg border border-surface-border bg-surface-base p-4 transition hover:border-brand hover:shadow-focus-ring focus-visible:border-brand focus-visible:outline-none"
              >
                <div className="flex items-start gap-3">
                  {/* Wave 40 P6 + Wave 40.4 — initials avatar mirrors the
                      mobile ClientCard treatment. When `c.avatarUrl` is
                      non-null (signed URL minted by `list_practice_clients`
                      via `sign_storage_url`), the disc renders the body-
                      focus avatar JPG that the practitioner captured on
                      mobile; otherwise it falls back to initials. */}
                  <ClientAvatar
                    name={c.name}
                    imageUrl={c.avatarUrl}
                    size="md"
                  />
                  <h3 className="min-w-0 flex-1 font-heading text-base font-semibold text-ink">
                    {c.name}
                  </h3>
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

              {/* Delete button — positioned absolute over the card, fades in
                  on hover / focus-within (keyboard-accessible). Stops the
                  Link navigation with stopPropagation + preventDefault on
                  the surrounding anchor is done via button outside the
                  anchor (it's a sibling). R-01: fires immediately, no modal. */}
              <button
                type="button"
                onClick={() => handleDelete(c)}
                aria-label={`Delete ${c.name}`}
                title="Delete client"
                className="absolute bottom-3 right-3 inline-flex h-8 w-8 items-center justify-center rounded-md border border-transparent bg-surface-raised/80 text-ink-muted opacity-0 transition hover:border-error hover:text-error focus:opacity-100 group-hover:opacity-100"
              >
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  viewBox="0 0 20 20"
                  fill="none"
                  aria-hidden="true"
                  className="h-4 w-4"
                >
                  <path
                    d="M6 7h8m-7 0v7a1 1 0 001 1h4a1 1 0 001-1V7M8 7V5a1 1 0 011-1h2a1 1 0 011 1v2"
                    stroke="currentColor"
                    strokeWidth="1.5"
                    strokeLinecap="round"
                    strokeLinejoin="round"
                  />
                </svg>
              </button>
            </li>
          );
        })}
      </ul>

      {filtered.length === 0 && clients.length > 0 && (
        <p className="mt-6 rounded-lg border border-surface-border bg-surface-base p-6 text-center text-sm text-ink-muted">
          No clients match those filters.
        </p>
      )}

      {/* Delete-with-Undo toast. R-01: bottom-centre, 7s auto-dismiss,
          "Undo" button restores optimistically. The error variant has no
          Undo (nothing to undo — the delete didn't land). */}
      {toast && (
        <div
          role="status"
          aria-live="polite"
          className="pointer-events-none fixed inset-x-0 top-4 z-50 flex justify-center px-4"
        >
          <div
            className={`pointer-events-auto flex items-center gap-4 rounded-md border px-4 py-3 text-sm shadow-focus-ring ${
              toast.kind === 'error'
                ? 'border-error bg-surface-raised text-ink'
                : 'border-surface-border bg-surface-raised text-ink'
            }`}
          >
            <span>{toast.text}</span>
            {toast.kind === 'deleted' && toast.client && (
              <button
                type="button"
                onClick={() => {
                  const c = toast.client;
                  if (c) handleUndo(c);
                }}
                className="font-semibold text-brand transition hover:text-brand-light focus:outline-none"
              >
                Undo
              </button>
            )}
          </div>
        </div>
      )}
    </div>
  );
}

type DeleteToast =
  | {
      kind: 'deleted';
      text: string;
      /** Snapshot of the deleted client so Undo can fire without re-reading. */
      client: PracticeClient;
    }
  | { kind: 'error'; text: string; client: null };

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
