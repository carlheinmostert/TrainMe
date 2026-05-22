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
  | { kind: 'error'; text: string };

type Props = {
  practiceId: string;
  isOwner: boolean;
  initialPremises: PracticePremises[];
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
}: Props) {
  const router = useRouter();
  const [premises, setPremises] = useState<PracticePremises[]>(initialPremises);
  const [hiddenIds, setHiddenIds] = useState<Set<string>>(new Set());
  const [toast, setToast] = useState<Toast | null>(null);
  const [creating, startCreating] = useTransition();
  const [createError, setCreateError] = useState<string | null>(null);
  const toastTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

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

  function scheduleToastDismiss() {
    if (toastTimer.current) clearTimeout(toastTimer.current);
    toastTimer.current = setTimeout(() => setToast(null), 7000);
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
                      ) : p.safeModeEnforced ? (
                        <span className="rounded-full bg-brand/15 px-2 py-0.5 text-xs font-medium text-brand">
                          Safe Mode on
                        </span>
                      ) : (
                        <span className="rounded-full border border-surface-border px-2 py-0.5 text-xs text-ink-muted">
                          Registered only
                        </span>
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
                  <div className="flex gap-2">
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
        </div>
      )}
    </div>
  );
}

function fmtArea(m2: number): string {
  if (m2 < 10_000) return `${Math.round(m2).toLocaleString()} m²`;
  return `${(m2 / 1_000_000).toFixed(3)} km²`;
}
