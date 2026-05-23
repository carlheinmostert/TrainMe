'use client';

import { useEffect, useRef, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { getBrowserClient } from '@/lib/supabase-browser';
import {
  createPortalApi,
  PremisesError,
  type PracticePremises,
} from '@/lib/supabase/api';

type Toast =
  | { kind: 'deleted'; text: string; premises: PracticePremises }
  | { kind: 'safe-mode-toggled'; text: string; premises: PracticePremises; from: boolean }
  | { kind: 'error'; text: string };

type Props = {
  practiceId: string;
  isOwner: boolean;
  initialPremises: PracticePremises[];
  /**
   * Practice public slug (from `practices.public_slug`). When non-empty,
   * each Safe-Mode-enforced row surfaces a "Live" button opening the
   * per-premises transparency URL `session.homefit.studio/v/{practice-slug}/{premises-slug}/now`.
   * When the practice slug isn't set (owner hasn't filled in /public-profile),
   * Live + Poster buttons are hidden — there's no public URL to link to.
   */
  practiceSlug: string | null;
  /**
   * Origin of the web player (`session.homefit.studio` on prod). Computed
   * server-side from the request host so dev / staging point at the
   * matching player deployment.
   */
  playerOrigin: string;
};

/**
 * Manage-premises panel for the `/premises` page.
 *
 * R-01 (no modal confirmations) + no-popups-ever flow:
 *   - "Add premises" mints a draft row via `create_default_premises`
 *     and routes to `/premises/{id}` for inline editing. No dialog.
 *   - Each row's name links to `/premises/{id}`; Edit does the same.
 *   - Delete fires immediately with an undo toast (7s window).
 *
 * The old `PremisesEditorDialog` modal is gone — composing a premises
 * was the only path that still used a modal in the portal, which
 * broke R-01.
 */
export function PremisesListPanel({
  practiceId,
  initialPremises,
  practiceSlug,
  playerOrigin,
}: Props) {
  const router = useRouter();
  const [premises, setPremises] = useState<PracticePremises[]>(initialPremises);
  const [hiddenIds, setHiddenIds] = useState<Set<string>>(new Set());
  const [toast, setToast] = useState<Toast | null>(null);
  const [creating, startCreating] = useTransition();
  const [createError, setCreateError] = useState<string | null>(null);
  const toastTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  // Per-premises in-flight flag for the Safe Mode toggle — drives the
  // pulsing dim affordance during the RPC round-trip. We track this
  // separately from the optimistic state in `premises` so the badge can
  // show "saving" without flipping the displayed mode if the RPC ends
  // up rolling back.
  const [pendingSafeModeIds, setPendingSafeModeIds] = useState<Set<string>>(
    () => new Set(),
  );

  // Keep local state in sync if the server-rendered list changes
  // (e.g. after the detail page renames a row and router.refresh()).
  useEffect(() => {
    setPremises(initialPremises);
  }, [initialPremises]);

  // Auto-dismiss the toast after 7s; matches the ClientsList pattern.
  useEffect(() => {
    return () => {
      if (toastTimer.current) clearTimeout(toastTimer.current);
    };
  }, []);

  function scheduleToastDismiss(ms: number = 7000) {
    if (toastTimer.current) clearTimeout(toastTimer.current);
    toastTimer.current = setTimeout(() => setToast(null), ms);
  }

  async function handleSafeModeToggle(p: PracticePremises) {
    const from = p.safeModeEnforced;
    const to = !from;

    // Optimistic flip — update local state immediately so the badge swaps
    // colour without waiting for the round-trip.
    setPremises((prev) =>
      prev.map((row) =>
        row.id === p.id ? { ...row, safeModeEnforced: to } : row,
      ),
    );
    setPendingSafeModeIds((prev) => {
      const next = new Set(prev);
      next.add(p.id);
      return next;
    });

    try {
      const api = createPortalApi(getBrowserClient());
      await api.togglePremisesSafeMode({ premisesId: p.id, to });
    } catch (e) {
      // Rollback on failure.
      setPremises((prev) =>
        prev.map((row) =>
          row.id === p.id ? { ...row, safeModeEnforced: from } : row,
        ),
      );
      setPendingSafeModeIds((prev) => {
        const next = new Set(prev);
        next.delete(p.id);
        return next;
      });
      const msg =
        e instanceof PremisesError && e.kind === 'not-member'
          ? `You don't have permission to toggle Safe Mode on ${p.name}.`
          : e instanceof Error
            ? `Couldn't update Safe Mode — ${e.message}`
            : "Couldn't update Safe Mode.";
      setToast({ kind: 'error', text: msg });
      scheduleToastDismiss();
      return;
    }

    setPendingSafeModeIds((prev) => {
      const next = new Set(prev);
      next.delete(p.id);
      return next;
    });

    // Undo toast — 5-second window per the brief. Single Undo click
    // re-flips by calling the same RPC with the original value.
    setToast({
      kind: 'safe-mode-toggled',
      text: to
        ? `Safe Mode on for ${p.name}`
        : `Safe Mode off for ${p.name}`,
      premises: { ...p, safeModeEnforced: to },
      from,
    });
    scheduleToastDismiss(5000);
  }

  async function handleSafeModeUndo(p: PracticePremises, restoreTo: boolean) {
    if (toastTimer.current) clearTimeout(toastTimer.current);
    setToast(null);
    // Reuse the same flow but with the previous value as the target.
    // Optimistic re-flip first.
    setPremises((prev) =>
      prev.map((row) =>
        row.id === p.id ? { ...row, safeModeEnforced: restoreTo } : row,
      ),
    );
    setPendingSafeModeIds((prev) => {
      const next = new Set(prev);
      next.add(p.id);
      return next;
    });
    try {
      const api = createPortalApi(getBrowserClient());
      await api.togglePremisesSafeMode({ premisesId: p.id, to: restoreTo });
    } catch (e) {
      // Rollback the rollback — restore the post-toggle value.
      setPremises((prev) =>
        prev.map((row) =>
          row.id === p.id ? { ...row, safeModeEnforced: !restoreTo } : row,
        ),
      );
      const msg =
        e instanceof Error ? `Couldn't undo — ${e.message}` : "Couldn't undo.";
      setToast({ kind: 'error', text: msg });
      scheduleToastDismiss();
    } finally {
      setPendingSafeModeIds((prev) => {
        const next = new Set(prev);
        next.delete(p.id);
        return next;
      });
    }
  }

  function handleAdd() {
    setCreateError(null);
    startCreating(async () => {
      try {
        const api = createPortalApi(getBrowserClient());
        const newId = await api.createDefaultPremises(practiceId);
        if (!newId) throw new Error('Server returned an empty premises id.');
        router.push(`/premises/${newId}?practice=${practiceId}`);
      } catch (e) {
        const msg =
          e instanceof PremisesError && e.kind === 'not-member'
            ? "You don't have permission to add premises on this practice."
            : e instanceof Error
              ? `Couldn't add premises — ${e.message}`
              : "Couldn't add premises.";
        setCreateError(msg);
      }
    });
  }

  async function handleDelete(p: PracticePremises) {
    // Optimistic hide.
    setHiddenIds((prev) => {
      const next = new Set(prev);
      next.add(p.id);
      return next;
    });

    try {
      const api = createPortalApi(getBrowserClient());
      await api.deletePremises(p.id);
    } catch (e) {
      // Rollback on failure.
      setHiddenIds((prev) => {
        const next = new Set(prev);
        next.delete(p.id);
        return next;
      });
      const msg =
        e instanceof PremisesError && e.kind === 'not-member'
          ? `You don't have permission to delete ${p.name}.`
          : e instanceof Error
            ? `Couldn't delete — ${e.message}`
            : "Couldn't delete.";
      setToast({ kind: 'error', text: msg });
      scheduleToastDismiss();
      return;
    }

    setToast({ kind: 'deleted', text: `${p.name} deleted`, premises: p });
    scheduleToastDismiss();
  }

  async function handleUndo(p: PracticePremises) {
    if (toastTimer.current) clearTimeout(toastTimer.current);
    setToast(null);
    try {
      const api = createPortalApi(getBrowserClient());
      await api.restorePremises(p.id);
    } catch (e) {
      const msg =
        e instanceof Error ? `Couldn't undo — ${e.message}` : "Couldn't undo.";
      setToast({ kind: 'error', text: msg });
      scheduleToastDismiss();
      return;
    }
    setHiddenIds((prev) => {
      const next = new Set(prev);
      next.delete(p.id);
      return next;
    });
  }

  const visiblePremises = premises.filter((p) => !hiddenIds.has(p.id));
  const enforcedCount = visiblePremises.filter((p) => p.safeModeEnforced).length;

  return (
    <div className="flex flex-col gap-8">
      <section className="rounded-xl border border-surface-border bg-surface-base p-6">
        <div className="mb-4 flex items-start justify-between gap-4">
          <div>
            <h2 className="font-heading text-xl font-bold">
              Registered premises
            </h2>
            <p className="mt-1 text-xs text-ink-muted">
              {visiblePremises.length === 0
                ? 'No premises yet.'
                : `${visiblePremises.length} ${visiblePremises.length === 1 ? 'site' : 'sites'}, ${enforcedCount} enforcing Safe Mode.`}
            </p>
          </div>
          <button
            type="button"
            onClick={handleAdd}
            disabled={creating}
            className="rounded-md bg-brand px-4 py-2 text-sm font-semibold text-surface-bg hover:bg-brand-light disabled:cursor-not-allowed disabled:opacity-60"
          >
            {creating ? 'Adding...' : '+ Add premises'}
          </button>
        </div>

        {createError && (
          <div
            role="alert"
            className="mb-4 rounded-md border border-error/40 bg-error/10 px-3 py-2 text-sm text-error"
          >
            {createError}
          </div>
        )}

        {visiblePremises.length === 0 ? (
          <p className="rounded-md border border-dashed border-surface-border px-4 py-8 text-center text-sm text-ink-muted">
            Add your first site to enable Safe Mode for captures that happen
            there.
          </p>
        ) : (
          <ul className="flex flex-col divide-y divide-surface-border">
            {visiblePremises.map((p) => {
              const detailHref = `/premises/${p.id}?practice=${practiceId}`;
              const isDraft = !p.polygonGeoJson;
              // Live + Poster URLs require both the practice slug AND
              // the premises slug to resolve. Drafts have no polygon
              // (the live page would render an empty map) so suppress
              // Live there too.
              const hasPublicUrls =
                Boolean(practiceSlug) &&
                Boolean(p.publicSlug) &&
                !isDraft;
              const liveUrl = hasPublicUrls
                ? `${playerOrigin}/v/${practiceSlug}/${p.publicSlug}/now`
                : null;
              const posterHref = `/premises/${p.id}/poster?print=1`;
              return (
                <li
                  key={p.id}
                  className="flex flex-col gap-2 py-4 sm:flex-row sm:items-center sm:justify-between"
                >
                  <div className="flex flex-col gap-1">
                    <div className="flex flex-wrap items-center gap-2">
                      <a
                        href={detailHref}
                        className="text-base font-semibold text-ink underline-offset-4 hover:text-brand hover:underline"
                      >
                        {p.name}
                      </a>
                      {isDraft ? (
                        <span className="rounded-full border border-dashed border-surface-border px-2 py-0.5 text-xs text-ink-muted">
                          Draft - no polygon yet
                        </span>
                      ) : (
                        // Interactive Safe Mode badge — one click flips the
                        // state via the toggle_premises_safe_mode RPC. Styled
                        // to look like the prior static badge so the visual
                        // weight on the row is unchanged; only the affordance
                        // is added.
                        // R-01: no confirm modal; undo via toast (5s window).
                        // Permission gating mirrors the Edit link (any practice
                        // member or owner). Pending state during the RPC
                        // round-trip dims + animates the badge subtly so the
                        // user has feedback that the click registered.
                        (() => {
                          const pending = pendingSafeModeIds.has(p.id);
                          const on = p.safeModeEnforced;
                          const baseCls = on
                            ? 'bg-brand/15 text-brand hover:bg-brand/25 border border-transparent'
                            : 'border border-dashed border-surface-border text-ink-muted hover:border-brand/40 hover:text-ink';
                          const pendingCls = pending
                            ? 'opacity-60 animate-pulse cursor-wait'
                            : 'cursor-pointer';
                          return (
                            <button
                              type="button"
                              onClick={() => {
                                if (pending) return;
                                void handleSafeModeToggle(p);
                              }}
                              disabled={pending}
                              aria-pressed={on}
                              aria-label={
                                on
                                  ? `Safe Mode is on for ${p.name}. Click to turn off.`
                                  : `Safe Mode is off for ${p.name}. Click to turn on.`
                              }
                              title={
                                on
                                  ? 'Safe Mode on — click to turn off'
                                  : 'Click to turn Safe Mode on'
                              }
                              className={`rounded-full px-2 py-0.5 text-xs font-medium transition focus:outline-none focus-visible:ring-2 focus-visible:ring-brand/60 ${baseCls} ${pendingCls}`}
                            >
                              {on ? 'Safe Mode on' : 'Registered only'}
                            </button>
                          );
                        })()
                      )}
                    </div>
                    {p.address && (
                      <span className="text-xs text-ink-muted">{p.address}</span>
                    )}
                    <span className="text-xs text-ink-muted">
                      {isDraft
                        ? 'No boundary yet'
                        : `${fmtArea(p.areaM2)} - ${p.signalType.toUpperCase()}`}
                    </span>
                  </div>
                  <div className="flex flex-wrap items-center gap-1.5">
                    {/* Public actions: Live + Poster.
                        Hidden on mobile (sm:flex) — see overflow menu below. */}
                    {liveUrl && (
                      <a
                        href={liveUrl}
                        target="_blank"
                        rel="noopener"
                        title="Open the live transparency view in a new tab"
                        className="hidden items-center gap-1.5 rounded-md border border-surface-border px-2.5 py-1.5 text-xs text-ink hover:bg-surface-raised sm:inline-flex"
                      >
                        <EyeIcon />
                        Live
                      </a>
                    )}
                    {p.safeModeEnforced && hasPublicUrls && (
                      <a
                        href={posterHref}
                        target="_blank"
                        rel="noopener"
                        title="Download the printable transparency poster"
                        className="hidden items-center gap-1.5 rounded-md border border-brand/30 px-2.5 py-1.5 text-xs text-brand hover:bg-brand/10 sm:inline-flex"
                      >
                        <DownloadIcon />
                        Poster
                      </a>
                    )}
                    {/* Mobile overflow: Live + Poster combined into a
                        single dropdown so the row stays scannable. The
                        Edit + Delete pair always stays visible. */}
                    {hasPublicUrls && (
                      <details className="relative inline-block sm:hidden">
                        <summary
                          className="cursor-pointer list-none rounded-md border border-surface-border px-2.5 py-1.5 text-xs text-ink hover:bg-surface-raised"
                          aria-label="Public actions menu"
                        >
                          Public ▾
                        </summary>
                        <div className="absolute right-0 top-full z-10 mt-1 flex w-44 flex-col gap-1 rounded-md border border-surface-border bg-surface-raised p-1 shadow-lg">
                          <a
                            href={liveUrl ?? '#'}
                            target="_blank"
                            rel="noopener"
                            className="flex items-center gap-2 rounded-md px-2 py-1.5 text-xs text-ink hover:bg-surface-base"
                          >
                            <EyeIcon />
                            Live view
                          </a>
                          {p.safeModeEnforced && (
                            <a
                              href={posterHref}
                              target="_blank"
                              rel="noopener"
                              className="flex items-center gap-2 rounded-md px-2 py-1.5 text-xs text-brand hover:bg-surface-base"
                            >
                              <DownloadIcon />
                              Poster
                            </a>
                          )}
                        </div>
                      </details>
                    )}
                    {/* Thin vertical rule separator — public actions
                        (left) vs private actions (right). Per the
                        mockup. */}
                    {hasPublicUrls && (
                      <span
                        aria-hidden="true"
                        className="hidden h-5 w-px bg-surface-border sm:inline-block"
                      />
                    )}
                    <a
                      href={detailHref}
                      className="rounded-md border border-surface-border px-3 py-1.5 text-xs text-ink hover:bg-surface-raised"
                    >
                      Edit
                    </a>
                    <button
                      type="button"
                      onClick={() => handleDelete(p)}
                      className="rounded-md border border-error/40 px-3 py-1.5 text-xs text-error hover:bg-error/10"
                    >
                      Delete
                    </button>
                  </div>
                </li>
              );
            })}
          </ul>
        )}
      </section>

      {/*
        Public-profile editor moved to its own /public-profile route in
        Public Profile v2. The v1 in-page block lived here behind a
        <details> accordion; surfacing branding + slug + directory opt-in
        on /premises mixed two surfaces (physical sites vs marketing /
        directory). The dashboard tile + dedicated route is the entry
        point now. PracticeProfilePanel.tsx is currently orphaned —
        retained for backport reference until the next cleanup wave.
      */}

      {toast && (
        <div
          role="status"
          className="fixed inset-x-0 bottom-6 z-40 mx-auto flex w-fit max-w-md items-center gap-3 rounded-lg border border-surface-border bg-surface-raised px-4 py-3 text-sm text-ink shadow-2xl"
        >
          <span>{toast.text}</span>
          {toast.kind === 'deleted' && (
            <button
              type="button"
              onClick={() => handleUndo(toast.premises)}
              className="rounded-md border border-brand px-2 py-1 text-xs font-semibold text-brand hover:bg-brand/10"
            >
              Undo
            </button>
          )}
          {toast.kind === 'safe-mode-toggled' && (
            <button
              type="button"
              onClick={() => handleSafeModeUndo(toast.premises, toast.from)}
              className="rounded-md border border-brand px-2 py-1 text-xs font-semibold text-brand hover:bg-brand/10"
            >
              Undo
            </button>
          )}
        </div>
      )}
    </div>
  );
}

function fmtArea(m2: number): string {
  if (m2 < 10_000) return `${Math.round(m2).toLocaleString()} m²`;
  return `${(m2 / 1_000_000).toFixed(3)} km²`;
}

function EyeIcon() {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={2}
      strokeLinecap="round"
      strokeLinejoin="round"
      className="h-3.5 w-3.5 flex-shrink-0"
      aria-hidden="true"
    >
      <circle cx={12} cy={12} r={3} />
      <path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12Z" />
    </svg>
  );
}

function DownloadIcon() {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={2}
      strokeLinecap="round"
      strokeLinejoin="round"
      className="h-3.5 w-3.5 flex-shrink-0"
      aria-hidden="true"
    >
      <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4" />
      <polyline points="7 10 12 15 17 10" />
      <line x1={12} y1={15} x2={12} y2={3} />
    </svg>
  );
}
