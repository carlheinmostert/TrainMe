'use client';

import { useEffect, useRef, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { getBrowserClient } from '@/lib/supabase-browser';
import { createPortalApi, RenamePracticeError } from '@/lib/supabase/api';

type SaveState =
  | { kind: 'idle' }
  | { kind: 'ok' }
  | { kind: 'err'; message: string };

type Props = {
  practiceId: string;
  initialName: string;
  /** Whether the caller is the OWNER of the practice. Practitioners see
   *  a read-only rendering of the current name with an "Only the owner
   *  can rename this" helper below. */
  canEdit: boolean;
};

/**
 * Inline practice-name field for the Account Settings page.
 *
 * Unlike the dashboard variant (PracticeContextLine), this one renders
 * as a labelled form row with the dashed-underline edit affordance —
 * matches the visual weight of the adjacent "Set password" block so
 * the two sections feel like siblings on the page.
 *
 * Interactions:
 *   - Click the name (or focus + Enter/Space) → switches to text input.
 *   - Enter commits, Esc cancels, blur commits.
 *   - Inline success/error below the row, auto-clears on re-entry.
 *   - Calls `router.refresh()` on success so any server-component caller
 *     picks up the new name immediately.
 *
 * Read-only fallback for practitioners: just the name in ink, plus a
 * helper string. No dashed underline.
 */
export function PracticeNameField({ practiceId, initialName, canEdit }: Props) {
  const router = useRouter();
  const [name, setName] = useState(initialName);
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(initialName);
  const [saving, startSave] = useTransition();
  const [state, setState] = useState<SaveState>({ kind: 'idle' });
  const inputRef = useRef<HTMLInputElement | null>(null);

  useEffect(() => {
    if (editing && inputRef.current) {
      inputRef.current.focus();
      inputRef.current.select();
    }
  }, [editing]);

  // If the parent re-renders with a new initialName (e.g. after a rename
  // elsewhere), pick it up so the display stays in sync.
  useEffect(() => {
    setName(initialName);
    setDraft(initialName);
  }, [initialName]);

  // Auto-dismiss success + error after a beat so repeated saves don't
  // stack visible copy. Error stays a little longer so the practitioner
  // has time to read it.
  useEffect(() => {
    if (state.kind === 'idle') return;
    const ttl = state.kind === 'err' ? 4000 : 2000;
    const id = window.setTimeout(() => setState({ kind: 'idle' }), ttl);
    return () => window.clearTimeout(id);
  }, [state]);

  function startEditing() {
    if (!canEdit) return;
    setDraft(name);
    setState({ kind: 'idle' });
    setEditing(true);
  }

  function cancel() {
    setDraft(name);
    setState({ kind: 'idle' });
    setEditing(false);
  }

  function commit() {
    const trimmed = draft.trim();
    if (trimmed === name) {
      setEditing(false);
      setState({ kind: 'idle' });
      return;
    }
    if (trimmed === '') {
      setState({ kind: 'err', message: 'Name can’t be empty.' });
      return;
    }
    startSave(async () => {
      try {
        const supabase = getBrowserClient();
        const api = createPortalApi(supabase);
        await api.renamePractice(practiceId, trimmed);
        setName(trimmed);
        setEditing(false);
        setState({ kind: 'ok' });
        router.refresh();
      } catch (e) {
        const message = mapRenameError(e);
        setState({ kind: 'err', message });
        // Stay in edit mode so the owner can retry without re-clicking.
      }
    });
  }

  return (
    <section
      className="rounded-lg border border-surface-border bg-surface-base p-6"
      aria-labelledby="practice-name-heading"
    >
      <h2
        id="practice-name-heading"
        className="font-heading text-lg font-semibold"
      >
        Practice name
      </h2>
      <p className="mt-1 text-sm text-ink-muted">
        {canEdit
          ? 'Shown throughout the portal and mobile app. Keep it short — it has to fit the dashboard.'
          : 'Only the practice owner can change this.'}
      </p>

      <div className="mt-5">
        {!editing && (
          <div className="flex flex-wrap items-center gap-3">
            {canEdit ? (
              <span
                role="button"
                tabIndex={0}
                onClick={startEditing}
                onKeyDown={(e) => {
                  if (e.key === 'Enter' || e.key === ' ') {
                    e.preventDefault();
                    startEditing();
                  }
                }}
                title="Click to rename"
                className="inline-block cursor-text border-b border-dashed border-ink-muted font-heading text-xl font-semibold text-ink transition hover:border-brand focus-visible:border-brand focus-visible:outline-none"
              >
                {name}
              </span>
            ) : (
              <span className="font-heading text-xl font-semibold text-ink">
                {name}
              </span>
            )}
            {canEdit && (
              <button
                type="button"
                onClick={startEditing}
                className="rounded-md border border-surface-border bg-surface-raised px-3 py-1.5 text-xs font-medium text-ink-muted transition hover:border-ink-muted hover:text-ink"
              >
                Rename
              </button>
            )}
          </div>
        )}

        {editing && (
          <div className="flex flex-col gap-2">
            <label htmlFor="account-practice-name-input" className="sr-only">
              Practice name
            </label>
            <input
              ref={inputRef}
              id="account-practice-name-input"
              type="text"
              value={draft}
              onChange={(e) => {
                setDraft(e.target.value);
                if (state.kind !== 'idle') setState({ kind: 'idle' });
              }}
              onKeyDown={(e) => {
                if (e.key === 'Enter') {
                  e.preventDefault();
                  commit();
                } else if (e.key === 'Escape') {
                  e.preventDefault();
                  cancel();
                }
              }}
              onBlur={() => {
                if (!saving) commit();
              }}
              disabled={saving}
              maxLength={60}
              aria-invalid={state.kind === 'err'}
              aria-describedby={
                state.kind === 'err' ? 'practice-name-error' : undefined
              }
              className={`max-w-md rounded-md border bg-surface-base px-3 py-2 font-heading text-xl font-semibold text-ink focus:outline-none disabled:opacity-60 ${
                state.kind === 'err'
                  ? 'border-error focus:border-error'
                  : 'border-brand focus:border-brand'
              }`}
            />
            <p className="text-xs text-ink-dim">
              Enter to save · Esc to cancel · max 60 characters
            </p>
          </div>
        )}

        {state.kind === 'ok' && (
          <p role="status" className="mt-3 text-sm text-success">
            Practice renamed.
          </p>
        )}

        {state.kind === 'err' && (
          <p
            id="practice-name-error"
            role="alert"
            className="mt-3 rounded-md border border-error/40 bg-error/10 px-3 py-2 text-sm text-error"
          >
            {state.message}
          </p>
        )}
      </div>
    </section>
  );
}

// ----------------------------------------------------------------------------
// Error mapper — mirrors the message bank in PracticeContextLine so the
// two surfaces present consistent copy.
// ----------------------------------------------------------------------------

function mapRenameError(e: unknown): string {
  if (e instanceof RenamePracticeError) {
    if (e.kind === 'too-long') {
      return 'Name’s a bit long — keep it under 60 characters.';
    }
    if (e.kind === 'empty') return 'Name can’t be empty.';
    if (e.kind === 'not-owner') {
      return 'Only the practice owner can rename it.';
    }
    return 'Practice not found. Try refreshing.';
  }
  const msg = e instanceof Error ? e.message : 'Something went wrong.';
  return `Couldn’t rename — ${msg}`;
}
