'use client';

import { useState, useTransition } from 'react';
import { getBrowserClient } from '@/lib/supabase-browser';
import { createPortalApi, type ClientVideoConsent } from '@/lib/supabase/api';

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
  clientName,
  initialConsent,
  sessionCount,
  recentPractitionerEmail,
}: Props) {
  const [grayscale, setGrayscale] = useState(initialConsent.grayscale);
  const [original, setOriginal] = useState(initialConsent.original);
  const [savedConsent, setSavedConsent] = useState(initialConsent);
  const [toast, setToast] = useState<Toast>(null);
  const [pending, startTransition] = useTransition();

  const dirty =
    grayscale !== savedConsent.grayscale || original !== savedConsent.original;

  // "Narrowing" = the save would turn OFF a currently-granted treatment.
  // The soft warning below explains the effect on already-published plans.
  // Note: the claim that already-published plans KEEP working in their
  // prior treatment is NOT verified against the web player + get_plan_full
  // logic — see the comment below and the report. We err on the side of
  // dropping the reassurance rather than making a claim we can't back up.
  const narrowing =
    (savedConsent.grayscale && !grayscale) ||
    (savedConsent.original && !original);

  async function handleSave() {
    startTransition(async () => {
      try {
        const supabase = getBrowserClient();
        const api = createPortalApi(supabase);
        await api.setClientVideoConsent(clientId, grayscale, original);
        setSavedConsent({
          line_drawing: true,
          grayscale,
          original,
        });
        setToast({ text: 'Saved.', tone: 'info' });
      } catch (e) {
        const msg = e instanceof Error ? e.message : 'Something went wrong.';
        setToast({ text: `Couldn’t save — ${msg}`, tone: 'error' });
      }
      window.setTimeout(() => setToast(null), 2500);
    });
  }

  return (
    <section aria-labelledby="client-heading">
      {/* 1. Header block */}
      <header>
        <h1
          id="client-heading"
          className="font-heading text-3xl font-bold text-ink"
        >
          {clientName}
        </h1>
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
      </header>

      {/* 2. Inline consent form — R-01 no modal. */}
      <div className="mt-8 rounded-lg border border-surface-border bg-surface-base p-5">
        <h2 className="font-heading text-lg font-semibold text-ink">
          What can {clientName} see as?
        </h2>
        <p className="mt-1 text-sm text-ink-muted">
          Line drawings are always available — they&rsquo;re how the plan
          de-identifies {clientName} by default. Add black &amp; white or
          full colour for plans where {clientName} prefers the real footage.
        </p>

        <ul className="mt-5 space-y-3">
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

      {/* Toast — R-01: inline status line, not a modal. */}
      {toast && (
        <div
          role="status"
          aria-live="polite"
          className="pointer-events-none fixed inset-x-0 bottom-6 z-50 flex justify-center px-4"
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
