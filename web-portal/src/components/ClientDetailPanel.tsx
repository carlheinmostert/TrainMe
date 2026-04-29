'use client';

import { useRouter } from 'next/navigation';
import { useEffect, useRef, useState, useTransition } from 'react';
import { getBrowserClient } from '@/lib/supabase-browser';
import {
  createPortalApi,
  DeleteClientError,
  RenameClientError,
  type ClientVideoConsent,
} from '@/lib/supabase/api';

type Props = {
  clientId: string;
  clientName: string;
  initialConsent: ClientVideoConsent;
  sessionCount: number;
  /** Email of the practitioner who most-recently published for this client.
   *  Passed through when owner is looking at someone else's client, so the
   *  page can label authorship. Null when caller IS the recent publisher
   *  or when the client has no sessions. */
  recentPractitionerEmail: string | null;
  /** Query-string fragment carrying the active practice. Used by the
   *  Delete flow to route back to the clients list after firing. */
  practiceQs: string;
};

type Toast = { text: string; tone: 'info' | 'error' } | null;

/**
 * Client header + inline consent form. The two are a single component
 * because the save button sits below the toggles and the success/error
 * toast is bound to the form state.
 *
 * Design compliance:
 * - R-01: no modal "are you sure?" — the save button is the commit, the
 *   toast is the feedback, and the toggles can be flipped back at any
 *   moment.
 * - R-02: header purity — just the name + count + practitioner line.
 *   No inline actions compete with the form below.
 * - R-06: copy never says "trainer"/"bio"/"physio"/"coach". Always
 *   "practitioner". The practitioner email is labelled "Practitioner:".
 * - R-09: the default state of each toggle matches the current saved
 *   value — practitioners don't find their settings silently flipped.
 * - POPIA voice: no "consent"/"legal"/"POPIA"/"withdraw"/"rights" in
 *   user-visible strings. Copy frames the toggles as "what can {Name}
 *   see as?" — peer-to-peer, practitioner-framing.
 */
export function ClientDetailPanel({
  clientId,
  clientName: initialClientName,
  initialConsent,
  sessionCount,
  recentPractitionerEmail,
  practiceQs,
}: Props) {
  const router = useRouter();
  const [displayName, setDisplayName] = useState(initialClientName);
  const [grayscale, setGrayscale] = useState(initialConsent.grayscale);
  const [original, setOriginal] = useState(initialConsent.original);
  // Wave 40.3 — Avatar (Wave-30 consent slot) finally surfaced on the
  // portal. Mirrors the mobile sheet's Profile group toggle.
  const [avatar, setAvatar] = useState(initialConsent.avatar);
  const [savedConsent, setSavedConsent] = useState(initialConsent);
  const [toast, setToast] = useState<Toast>(null);
  const [pending, startTransition] = useTransition();
  const [deleting, setDeleting] = useState(false);
  // Keep a stable alias so the rest of the component's f-strings stay
  // readable. The live name is `displayName`; rename updates it.
  const clientName = displayName;

  const dirty =
    grayscale !== savedConsent.grayscale ||
    original !== savedConsent.original ||
    avatar !== savedConsent.avatar;

  // "Narrowing" = the save would turn OFF a currently-granted treatment.
  // The soft warning below explains the effect on already-published plans.
  // Note: the claim that already-published plans KEEP working in their
  // prior treatment is NOT verified against the web player + get_plan_full
  // logic — see the comment below and the report. We err on the side of
  // dropping the reassurance rather than making a claim we can't back up.
  const narrowing =
    (savedConsent.grayscale && !grayscale) ||
    (savedConsent.original && !original) ||
    (savedConsent.avatar && !avatar);

  /**
   * Delete the client. R-01: fires immediately. After the RPC lands we
   * surface a 7-second Undo toast AND navigate the user back to
   * `/clients` so the page reads "this is gone" — the toast is the sole
   * recovery affordance. Undo fires `restore_client`, then `router.back()`
   * if we already navigated (otherwise the page stays put).
   */
  async function handleDelete() {
    if (deleting) return;
    setDeleting(true);
    try {
      const supabase = getBrowserClient();
      const api = createPortalApi(supabase);
      await api.deleteClient(clientId);
    } catch (e) {
      setDeleting(false);
      let msg = "Couldn't delete.";
      if (e instanceof DeleteClientError) {
        msg =
          e.kind === 'not-member'
            ? `You don't have permission to delete ${displayName}.`
            : `${displayName} not found.`;
      } else if (e instanceof Error) {
        msg = `Couldn't delete — ${e.message}`;
      }
      setToast({ text: msg, tone: 'error' });
      window.setTimeout(() => setToast(null), 4000);
      return;
    }

    // Fire Undo window via sessionStorage so ClientsList can render the
    // toast post-navigation. 7s TTL enforced there.
    try {
      sessionStorage.setItem(
        'portalUndoDelete',
        JSON.stringify({
          clientId,
          clientName: displayName,
          firedAtMs: Date.now(),
        }),
      );
    } catch {
      // sessionStorage may be unavailable in private mode — degrade to
      // no-undo. The delete itself still succeeded.
    }

    // Route back to the list. The list component reads the undo marker
    // on mount and surfaces the toast.
    router.replace(`/clients${practiceQs}`);
  }

  async function handleSave() {
    startTransition(async () => {
      try {
        const supabase = getBrowserClient();
        const api = createPortalApi(supabase);
        await api.setClientVideoConsent(clientId, grayscale, original, avatar);
        setSavedConsent({
          line_drawing: true,
          grayscale,
          original,
          avatar,
        });
        setToast({ text: 'Saved.', tone: 'info' });
      } catch (e) {
        const msg = e instanceof Error ? e.message : 'Something went wrong.';
        setToast({ text: `Couldn’t save — ${msg}`, tone: 'error' });
      }
      window.setTimeout(() => setToast(null), 2500);
    });
  }

  // Wave 40.3 — granted-count for the collapsed-state header chip.
  // line_drawing is locked-on so it always counts; we surface
  // "{granted}/{total}" so the practitioner sees the headline without
  // having to expand the panel. Total = 4 (line_drawing + grayscale +
  // original + avatar). Reads from the LIVE state so dragging a toggle
  // before saving updates the chip immediately — tighter feedback loop.
  const totalToggles = 4;
  const grantedToggles =
    1 + // line_drawing always
    (grayscale ? 1 : 0) +
    (original ? 1 : 0) +
    (avatar ? 1 : 0);

  return (
    <section aria-labelledby="client-heading">
      {/* 1. Header block */}
      <header className="flex flex-wrap items-start justify-between gap-4">
        <div className="min-w-0 flex-1">
          <EditableClientName
            clientId={clientId}
            name={displayName}
            onRenamed={setDisplayName}
          />
          <p className="mt-2 text-sm text-ink-muted">
            {sessionCount === 0
              ? `No sessions published for ${clientName} yet.`
              : `${sessionCount} ${sessionCount === 1 ? 'session' : 'sessions'} published for ${clientName}.`}
          </p>
          {recentPractitionerEmail && (
            <p className="mt-1 text-xs text-ink-dim">
              Practitioner:{' '}
              <span className="break-all text-ink-muted">
                {recentPractitionerEmail}
              </span>
            </p>
          )}
        </div>

        {/* Subtle Delete action — paired with EditableClientName so the
            practitioner finds it near where the client identity lives.
            R-01: fires immediately, Undo toast appears on /clients post-
            navigation. R-02: kept visually quiet; the consent panel is
            the primary affordance. */}
        <button
          type="button"
          onClick={handleDelete}
          disabled={deleting}
          aria-label={`Delete ${displayName}`}
          className="inline-flex shrink-0 items-center gap-1.5 rounded-md border border-surface-border bg-surface-base px-3 py-1.5 text-xs font-medium text-ink-muted transition hover:border-error hover:text-error disabled:cursor-not-allowed disabled:opacity-60"
        >
          <svg
            xmlns="http://www.w3.org/2000/svg"
            viewBox="0 0 20 20"
            fill="none"
            aria-hidden="true"
            className="h-3.5 w-3.5"
          >
            <path
              d="M6 7h8m-7 0v7a1 1 0 001 1h4a1 1 0 001-1V7M8 7V5a1 1 0 011-1h2a1 1 0 011 1v2"
              stroke="currentColor"
              strokeWidth="1.5"
              strokeLinecap="round"
              strokeLinejoin="round"
            />
          </svg>
          {deleting ? 'Deleting\u2026' : 'Delete'}
        </button>
      </header>

      {/* 2. Inline consent form — R-01 no modal.
       *
       * Wave 40.3 — wrapped in a <details> so the panel is collapsed by
       * default on every route load. Carl's framing: "you don't want to
       * see it the whole time. It's not the main show." The summary acts
       * as the chip — name + granted-count + caret. State is intentionally
       * not persisted across navigations: every visit to /clients/[id]
       * lands collapsed, the practitioner expands when they need to. */}
      <details className="group mt-8 overflow-hidden rounded-lg border border-surface-border bg-surface-base">
        <summary className="flex cursor-pointer list-none items-center justify-between gap-3 px-5 py-4 transition hover:bg-surface-raised/40 focus:outline-none focus-visible:ring-1 focus-visible:ring-brand">
          {/* WebKit puts a default disclosure marker on summary; suppress
           * it so the caret below is the only chevron. */}
          <style>{`details > summary::-webkit-details-marker{display:none}`}</style>
          <div className="flex min-w-0 flex-1 items-center gap-3">
            <h2 className="font-heading text-base font-semibold text-ink">
              Client consent
            </h2>
            <span className="inline-flex shrink-0 items-center rounded-full bg-emerald-500/15 px-2.5 py-0.5 text-xs font-medium text-emerald-400">
              {grantedToggles}/{totalToggles} granted
            </span>
          </div>
          <svg
            xmlns="http://www.w3.org/2000/svg"
            viewBox="0 0 20 20"
            fill="none"
            aria-hidden="true"
            className="h-4 w-4 shrink-0 text-ink-muted transition-transform group-open:rotate-180"
          >
            <path
              d="M5 7l5 6 5-6"
              stroke="currentColor"
              strokeWidth="1.6"
              strokeLinecap="round"
              strokeLinejoin="round"
            />
          </svg>
        </summary>

        <div className="border-t border-surface-border px-5 pb-5 pt-4">
          <p className="text-sm text-ink-muted">
          Line drawings are always available — they&rsquo;re how the plan
          de-identifies {clientName} by default. Add black &amp; white or
          full colour for plans where {clientName} prefers the real footage.
        </p>

        {/*
         * VIDEO TREATMENT group (R-11 parity with the mobile sheet's
         * grouped layout). Mobile's ClientConsentSheet was restructured
         * in PR #44 with an uppercase section header + grouped toggles
         * so that future consent groups (data sharing, communications,
         * etc.) slot in without relabelling the surface. Portal mirrors
         * that shape here.
         */}
        <p className="mt-5 text-[11px] font-semibold uppercase tracking-wider text-ink-dim">
          Video treatment
        </p>
        <ul className="mt-2 space-y-3">
          <ToggleRow
            label="Line drawing"
            helper="Always available — de-identifies the client."
            checked
            disabled
          />
          <ToggleRow
            label="Black & white"
            helper="Toned greyscale. Silhouette visible, faces soft."
            checked={grayscale}
            onChange={setGrayscale}
          />
          <ToggleRow
            label="Original colour"
            helper="Full colour footage, exactly as captured."
            checked={original}
            onChange={setOriginal}
          />
        </ul>

        {/* Wave 40.3 — Profile group mirrors the mobile sheet's second
         * section. The avatar toggle gates capture + storage of the
         * body-focus blurred still that replaces the initials monogram on
         * practitioner-facing surfaces. Different category from playback —
         * kept in its own group so the practitioner reads it as "what we
         * store of {Name}" not "how the client sees themselves". */}
        <p className="mt-5 text-[11px] font-semibold uppercase tracking-wider text-ink-dim">
          Profile
        </p>
        <ul className="mt-2 space-y-3">
          <ToggleRow
            label="Avatar still"
            helper={`Single capture with the background blurred — replaces the initials circle on ${clientName}.`}
            checked={avatar}
            onChange={setAvatar}
          />
        </ul>

        <div className="mt-6 flex flex-wrap items-center gap-3">
          <button
            type="button"
            onClick={handleSave}
            disabled={!dirty || pending}
            className="inline-flex items-center gap-2 rounded-md bg-brand px-4 py-2 text-sm font-semibold text-surface-bg transition hover:bg-brand-light disabled:cursor-not-allowed disabled:bg-surface-raised disabled:text-ink-disabled"
          >
            {pending ? 'Saving\u2026' : 'Save'}
          </button>
          {!dirty && !pending && (
            <p className="text-xs text-ink-dim">
              Toggles match what&rsquo;s saved. Flip one to enable Save.
            </p>
          )}
        </div>

        {narrowing && dirty && (
          <p className="mt-3 text-xs text-ink-muted">
            This applies to new plays from here on. Share any active plan
            link again for the change to take effect.
          </p>
        )}
        </div>
      </details>

      {/* Toast — R-01: inline status line, not a modal. */}
      {toast && (
        <div
          role="status"
          aria-live="polite"
          className="pointer-events-none fixed inset-x-0 top-4 z-50 flex justify-center px-4"
        >
          <div
            className={`pointer-events-auto rounded-md border px-4 py-3 text-sm shadow-focus-ring ${
              toast.tone === 'error'
                ? 'border-error bg-surface-raised text-ink'
                : 'border-surface-border bg-surface-raised text-ink'
            }`}
          >
            {toast.text}
          </div>
        </div>
      )}
    </section>
  );
}

// ----------------------------------------------------------------------------
// ToggleRow — pill-styled inline row. One per treatment.
// ----------------------------------------------------------------------------

function ToggleRow({
  label,
  helper,
  checked,
  onChange,
  disabled = false,
}: {
  label: string;
  helper: string;
  checked: boolean;
  onChange?: (next: boolean) => void;
  disabled?: boolean;
}) {
  const interactive = !disabled && typeof onChange === 'function';

  function handleClick() {
    if (interactive) onChange(!checked);
  }

  function handleKey(e: React.KeyboardEvent<HTMLDivElement>) {
    if (!interactive) return;
    if (e.key === ' ' || e.key === 'Enter') {
      e.preventDefault();
      onChange(!checked);
    }
  }

  // Compose the pill visual by state. Coral tint when on (additive visual
  // weight); neutral surface when off; muted + strike when disabled.
  const shell = disabled
    ? 'cursor-not-allowed border-surface-border bg-surface-raised/50'
    : checked
      ? 'cursor-pointer border-brand/60 bg-brand/10 hover:border-brand'
      : 'cursor-pointer border-surface-border bg-surface-raised hover:border-brand';

  const dot = checked
    ? 'border-brand bg-brand'
    : 'border-surface-border bg-transparent';

  return (
    <li>
      <div
        role={interactive ? 'checkbox' : undefined}
        aria-checked={interactive ? checked : undefined}
        aria-disabled={disabled || undefined}
        tabIndex={interactive ? 0 : -1}
        onClick={handleClick}
        onKeyDown={handleKey}
        className={`flex items-start justify-between gap-4 rounded-md border p-4 transition ${shell} focus-visible:outline-none`}
      >
        <div>
          <p className="text-sm font-semibold text-ink">{label}</p>
          <p className="mt-1 text-xs text-ink-muted">{helper}</p>
        </div>
        <span
          aria-hidden="true"
          className={`mt-0.5 inline-flex h-5 w-5 shrink-0 items-center justify-center rounded-full border ${dot}`}
        >
          {checked && (
            <svg
              viewBox="0 0 20 20"
              fill="none"
              className="h-3 w-3"
              aria-hidden="true"
            >
              <path
                d="M4 10l3 3 8-8"
                stroke="#0F1117"
                strokeWidth="2.2"
                strokeLinecap="round"
                strokeLinejoin="round"
              />
            </svg>
          )}
        </span>
      </div>
    </li>
  );
}

/**
 * Inline-editable client name.
 *
 * Affordance: dashed underline on the title hints at "click to edit"
 * (common pattern in Linear, Notion, Airtable). Clicking or focusing
 * the title switches to an input; Enter saves, Esc cancels, blur saves.
 *
 * While saving: input is disabled + the dashed underline turns into a
 * subtle brand-coloured pulse. On error (duplicate / empty / etc.) the
 * input stays in edit mode with an inline error below so the
 * practitioner can fix and retry without re-clicking in.
 */
function EditableClientName({
  clientId,
  name,
  onRenamed,
}: {
  clientId: string;
  name: string;
  onRenamed: (newName: string) => void;
}) {
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(name);
  const [error, setError] = useState<string | null>(null);
  const [saving, startSave] = useTransition();
  const inputRef = useRef<HTMLInputElement | null>(null);

  // Focus + select-all when entering edit mode so the whole
  // date-timestamp name is easy to blast over with real text.
  useEffect(() => {
    if (editing && inputRef.current) {
      inputRef.current.focus();
      inputRef.current.select();
    }
  }, [editing]);

  // Keep draft in sync if the parent updates `name` (e.g. another
  // tab renamed; or a save in this component just completed).
  useEffect(() => {
    setDraft(name);
  }, [name]);

  function startEditing() {
    setDraft(name);
    setError(null);
    setEditing(true);
  }

  function cancel() {
    setDraft(name);
    setError(null);
    setEditing(false);
  }

  function commit() {
    const trimmed = draft.trim();
    if (trimmed === name) {
      // No-op save — just exit edit mode.
      setEditing(false);
      setError(null);
      return;
    }
    if (trimmed === '') {
      setError('Name can’t be empty.');
      return;
    }
    startSave(async () => {
      try {
        const supabase = getBrowserClient();
        const api = createPortalApi(supabase);
        await api.renameClient(clientId, trimmed);
        onRenamed(trimmed);
        setError(null);
        setEditing(false);
      } catch (e) {
        if (e instanceof RenameClientError) {
          if (e.kind === 'duplicate') {
            setError('Another client in this practice already uses that name.');
          } else if (e.kind === 'empty') {
            setError('Name can’t be empty.');
          } else if (e.kind === 'not-member') {
            setError('You don’t have permission to rename this client.');
          } else {
            setError('Client not found. Try refreshing.');
          }
        } else {
          const msg = e instanceof Error ? e.message : 'Something went wrong.';
          setError(`Couldn’t rename — ${msg}`);
        }
        // Stay in edit mode so the practitioner can fix + retry.
      }
    });
  }

  if (!editing) {
    // Dashed underline = "click to edit" affordance. No pencil icon —
    // the underline is the whole signal; keeps the headline clean.
    return (
      <h1
        id="client-heading"
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
        className="inline-block cursor-text border-b border-dashed border-ink-muted pb-1 font-heading text-3xl font-bold text-ink transition hover:border-brand focus-visible:border-brand focus-visible:outline-none"
      >
        {name}
      </h1>
    );
  }

  return (
    <div>
      <label htmlFor="client-name-input" className="sr-only">
        Client name
      </label>
      <input
        ref={inputRef}
        id="client-name-input"
        type="text"
        value={draft}
        onChange={(e) => {
          setDraft(e.target.value);
          if (error) setError(null);
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
          // Blur saves; Esc cancels. If there's an error the input stays
          // focused by virtue of re-render, so blur is effectively only
          // triggered by user-intentional tab-out/click-away.
          if (!saving) commit();
        }}
        disabled={saving}
        maxLength={80}
        aria-invalid={error !== null}
        aria-describedby={error ? 'client-name-error' : undefined}
        className={`w-full max-w-lg rounded-md border bg-surface-base px-3 py-2 font-heading text-3xl font-bold text-ink focus:outline-none disabled:opacity-60 ${
          error
            ? 'border-error focus:border-error'
            : 'border-brand focus:border-brand'
        }`}
      />
      {error && (
        <p
          id="client-name-error"
          role="alert"
          className="mt-2 text-sm text-error"
        >
          {error}
        </p>
      )}
      {!error && (
        <p className="mt-2 text-xs text-ink-dim">
          Press Enter to save · Esc to cancel
        </p>
      )}
    </div>
  );
}
