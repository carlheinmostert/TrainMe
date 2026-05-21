'use client';

import { useState } from 'react';
import { getBrowserClient } from '@/lib/supabase-browser';
import {
  createPortalApi,
  type PracticePremises,
  type PracticePublicProfile,
} from '@/lib/supabase/api';
import { PremisesEditorDialog } from './PremisesEditorDialog';
import { PracticeProfilePanel } from './PracticeProfilePanel';

type Props = {
  practiceId: string;
  practiceName: string;
  isOwner: boolean;
  initialPremises: PracticePremises[];
  initialProfile: PracticePublicProfile;
};

export function PremisesListPanel({
  practiceId,
  practiceName,
  isOwner,
  initialPremises,
  initialProfile,
}: Props) {
  const [premises, setPremises] = useState<PracticePremises[]>(initialPremises);
  const [editing, setEditing] = useState<PracticePremises | null>(null);
  const [creating, setCreating] = useState(false);
  const [deletingId, setDeletingId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const reload = async () => {
    const api = createPortalApi(getBrowserClient());
    const next = await api.listPracticePremises(practiceId);
    setPremises(next);
  };

  const handleDelete = async (p: PracticePremises) => {
    if (!confirm(`Delete "${p.name}"? It can be restored later via support.`)) {
      return;
    }
    setDeletingId(p.id);
    setError(null);
    try {
      const api = createPortalApi(getBrowserClient());
      await api.deletePremises(p.id);
      await reload();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Delete failed.');
    } finally {
      setDeletingId(null);
    }
  };

  const enforcedCount = premises.filter((p) => p.safeModeEnforced).length;

  return (
    <div className="flex flex-col gap-8">
      <section className="rounded-xl border border-surface-border bg-surface-base p-6">
        <div className="mb-4 flex items-start justify-between gap-4">
          <div>
            <h2 className="font-heading text-xl font-bold">
              Registered premises
            </h2>
            <p className="mt-1 text-xs text-ink-muted">
              {premises.length === 0
                ? 'No premises yet.'
                : `${premises.length} ${premises.length === 1 ? 'site' : 'sites'}, ${enforcedCount} enforcing Safe Mode.`}
            </p>
          </div>
          <button
            type="button"
            onClick={() => setCreating(true)}
            className="rounded-md bg-brand px-4 py-2 text-sm font-semibold text-surface-bg hover:bg-brand-light"
          >
            + Add premises
          </button>
        </div>

        {error && (
          <div className="mb-4 rounded-md border border-error/40 bg-error/10 px-3 py-2 text-sm text-error">
            {error}
          </div>
        )}

        {premises.length === 0 ? (
          <p className="rounded-md border border-dashed border-surface-border px-4 py-8 text-center text-sm text-ink-muted">
            Add your first site to enable Safe Mode for captures that happen
            there.
          </p>
        ) : (
          <ul className="flex flex-col divide-y divide-surface-border">
            {premises.map((p) => (
              <li key={p.id} className="flex flex-col gap-2 py-4 sm:flex-row sm:items-center sm:justify-between">
                <div className="flex flex-col gap-1">
                  <div className="flex flex-wrap items-center gap-2">
                    <span className="text-base font-semibold text-ink">{p.name}</span>
                    {p.safeModeEnforced ? (
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
                    {fmtArea(p.areaM2)} · {p.signalType.toUpperCase()}
                  </span>
                </div>
                <div className="flex gap-2">
                  <button
                    type="button"
                    onClick={() => setEditing(p)}
                    className="rounded-md border border-surface-border px-3 py-1.5 text-xs text-ink hover:bg-surface-raised"
                  >
                    Edit
                  </button>
                  <button
                    type="button"
                    onClick={() => handleDelete(p)}
                    disabled={deletingId === p.id}
                    className="rounded-md border border-error/40 px-3 py-1.5 text-xs text-error hover:bg-error/10 disabled:opacity-50"
                  >
                    {deletingId === p.id ? 'Deleting…' : 'Delete'}
                  </button>
                </div>
              </li>
            ))}
          </ul>
        )}
      </section>

      <PracticeProfilePanel
        practiceId={practiceId}
        practiceName={practiceName}
        isOwner={isOwner}
        initial={initialProfile}
      />

      {(creating || editing) && (
        <PremisesEditorDialog
          practiceId={practiceId}
          initial={editing}
          onClose={() => {
            setEditing(null);
            setCreating(false);
          }}
          onSaved={async () => {
            setEditing(null);
            setCreating(false);
            await reload();
          }}
        />
      )}
    </div>
  );
}

function fmtArea(m2: number): string {
  if (m2 < 10_000) return `${Math.round(m2).toLocaleString()} m²`;
  return `${(m2 / 1_000_000).toFixed(3)} km²`;
}
