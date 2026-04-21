'use client';

import { useEffect, useState } from 'react';

/**
 * CopyButton — shared clipboard trigger for the share-kit cards.
 *
 * Phase 1 behaviour:
 *   1. On click, call `navigator.clipboard.writeText(getText())`.
 *   2. Swap the button label to "Copied!" for 2s.
 *   3. Emit a polite live-region toast so the action is announced to
 *      screen readers and sighted users who navigated away from the
 *      button after clicking.
 *
 * `getText` is a thunk (not a pre-computed string) so callers can avoid
 * rebuilding the templates on every render just to wire the button.
 *
 * No fancy error surfacing: if clipboard access is denied (rare on
 * HTTPS — typically only incognito Safari) we silently fall back to
 * a manual selection hint in the toast.
 */
export function CopyButton({
  getText,
  label = 'Copy message',
  copiedLabel = 'Copied!',
  variant = 'primary',
  fullWidth = false,
  ariaLabel,
  onCopy,
}: {
  getText: () => string;
  label?: string;
  copiedLabel?: string;
  variant?: 'primary' | 'secondary';
  fullWidth?: boolean;
  ariaLabel?: string;
  /**
   * Optional fire-and-forget callback invoked on every click — whether
   * the clipboard write succeeded or failed. Used by Wave 10 Phase 3 to
   * log a `share_events` row. Do NOT await inside the callback; the UI
   * must not block on analytics.
   */
  onCopy?: () => void;
}) {
  const [state, setState] = useState<'idle' | 'copied' | 'failed'>('idle');
  const [toast, setToast] = useState<string | null>(null);

  // Auto-dismiss toast after 2s. Matches the label-flip duration so the
  // two cues land + leave together.
  useEffect(() => {
    if (state === 'idle') return;
    const id = window.setTimeout(() => {
      setState('idle');
      setToast(null);
    }, 2000);
    return () => window.clearTimeout(id);
  }, [state]);

  async function handleClick() {
    const text = getText();
    // Fire the analytics callback first so a clipboard exception below
    // still produces an event row. The caller's onCopy is fire-and-forget
    // by contract.
    if (onCopy) {
      try {
        onCopy();
      } catch {
        // Swallow — analytics must never break the UX.
      }
    }
    try {
      await navigator.clipboard.writeText(text);
      setState('copied');
      setToast('Copied!');
    } catch {
      setState('failed');
      setToast('Copy failed — select the text manually.');
    }
  }

  const base =
    'inline-flex items-center justify-center gap-2 rounded-full px-4 h-10 text-sm font-semibold transition duration-fast ease-standard focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand/40 disabled:cursor-not-allowed disabled:opacity-60';
  const variantCls =
    variant === 'primary'
      ? 'bg-brand text-surface-bg hover:bg-brand-light'
      : 'border border-surface-border bg-transparent text-ink hover:border-brand-tint-border hover:text-brand-light';
  const widthCls = fullWidth ? 'w-full' : '';

  return (
    <>
      <button
        type="button"
        onClick={handleClick}
        aria-label={ariaLabel ?? label}
        className={`${base} ${variantCls} ${widthCls}`}
      >
        <ClipboardGlyph />
        {state === 'copied' ? copiedLabel : label}
      </button>

      {/* Polite live-region toast. Fixed bottom-center like the existing
          rename toast in PracticeContextLine so the two read as one
          shared visual language. */}
      {toast && (
        <div
          role="status"
          aria-live="polite"
          className="pointer-events-none fixed inset-x-0 bottom-6 z-50 flex justify-center px-4"
        >
          <div className="pointer-events-auto rounded-md border border-surface-border bg-surface-raised px-4 py-3 text-sm text-ink shadow-focus-ring">
            {toast}
          </div>
        </div>
      )}
    </>
  );
}

function ClipboardGlyph() {
  return (
    <svg
      viewBox="0 0 14 14"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.6"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      className="h-3.5 w-3.5"
    >
      <rect x="3" y="3" width="8" height="9" rx="1.5" />
      <path d="M5 3V2a1 1 0 0 1 1-1h2a1 1 0 0 1 1 1v1" />
    </svg>
  );
}
