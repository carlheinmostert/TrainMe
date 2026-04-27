'use client';

import { useEffect, useRef, useState, type ReactNode } from 'react';

/**
 * Wave 35 — shared portal Toast.
 *
 * Position: fixed, top-center, slide-down entrance / slide-up dismissal.
 * Carl's instruction (W5+14 #6): "All toasters must pop at top of page."
 * Earlier surfaces drifted to `bottom-6` which was getting clipped on
 * mobile Safari and on tall desktop pages — the Members page Add toast
 * was the trigger that surfaced this.
 *
 * Tones map to the existing design tokens already used by inline toasts:
 *   - 'success' → coral accent (matches brand voice; sage was reserved
 *     for rest semantics in the player).
 *   - 'error'   → red error token.
 *   - 'info'    → ink-on-surface, used for the pending / queued case
 *     where the action succeeded but the user-visible outcome is "later".
 *
 * Usage (callsite owns the open/close lifecycle):
 *
 *   const [toast, setToast] = useState<ToastState | null>(null);
 *   ...
 *   <Toast
 *     toast={toast}
 *     onDismiss={() => setToast(null)}
 *   />
 *
 * Auto-dismiss is the caller's job — keep using setTimeout +
 * clearTimeout in the host component. Placing the timer here would
 * fight the "click Undo to keep it open" patterns ClientsList +
 * SessionsList rely on.
 */
export type ToastTone = 'success' | 'error' | 'info';

export type ToastState = {
  tone: ToastTone;
  text: string;
  /** Optional inline action (e.g. "Undo"). Null for plain toasts. */
  action?: { label: string; onClick: () => void } | null;
  /**
   * Optional secondary line — used by MembersList's "Saved — they'll
   * join automatically when they sign up" copy where the headline is
   * status-coloured and the body is muted.
   */
  body?: string | null;
};

export function Toast({
  toast,
  onDismiss,
}: {
  toast: ToastState | null;
  onDismiss: () => void;
}) {
  // Animate in/out by tracking a delayed "visible" flag. We render
  // while `toast` is non-null OR while we're still animating the exit;
  // the outer container's mount-state owns the entrance, the inner
  // `data-state` attribute drives the slide direction.
  const [render, setRender] = useState<ToastState | null>(toast);
  const [open, setOpen] = useState(false);
  const exitTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    if (toast) {
      // New toast — clear any pending exit, render, then flip open on
      // the next tick so the slide-down transition fires.
      if (exitTimer.current) {
        clearTimeout(exitTimer.current);
        exitTimer.current = null;
      }
      setRender(toast);
      const t = setTimeout(() => setOpen(true), 10);
      return () => clearTimeout(t);
    }
    // toast cleared — start the exit animation, then unmount once the
    // 200ms slide-up completes.
    setOpen(false);
    exitTimer.current = setTimeout(() => {
      setRender(null);
      exitTimer.current = null;
    }, 200);
    return () => {
      if (exitTimer.current) {
        clearTimeout(exitTimer.current);
        exitTimer.current = null;
      }
    };
  }, [toast]);

  if (!render) return null;

  const tone = render.tone;
  const palette =
    tone === 'error'
      ? 'border-error/50 bg-surface-raised text-ink'
      : tone === 'info'
      ? 'border-brand/40 bg-surface-raised text-ink'
      : 'border-brand/40 bg-surface-raised text-ink';
  const accent =
    tone === 'error'
      ? 'text-error'
      : tone === 'info'
      ? 'text-brand'
      : 'text-brand';

  return (
    <div
      role="status"
      aria-live={tone === 'error' ? 'assertive' : 'polite'}
      className="pointer-events-none fixed inset-x-0 top-4 z-50 flex justify-center px-4"
      data-state={open ? 'open' : 'closed'}
      style={{
        transform: open ? 'translateY(0)' : 'translateY(-12px)',
        opacity: open ? 1 : 0,
        transition: 'transform 200ms ease-out, opacity 200ms ease-out',
      }}
    >
      <div
        className={`pointer-events-auto flex max-w-xl items-start gap-3 rounded-md border px-4 py-3 text-sm shadow-focus-ring ${palette}`}
      >
        <ToastBody render={render} accent={accent} />
        {render.action && (
          <button
            type="button"
            onClick={render.action.onClick}
            className="font-semibold text-brand transition hover:text-brand-light focus:outline-none"
          >
            {render.action.label}
          </button>
        )}
        <button
          type="button"
          onClick={onDismiss}
          aria-label="Dismiss"
          className="ml-2 text-xs font-semibold uppercase tracking-wider text-ink-muted transition hover:text-ink"
        >
          Dismiss
        </button>
      </div>
    </div>
  );
}

function ToastBody({
  render,
  accent,
}: {
  render: ToastState;
  accent: string;
}): ReactNode {
  if (render.body) {
    return (
      <div className="min-w-0">
        <p className={`font-semibold ${accent}`}>{render.text}</p>
        <p className="mt-0.5 text-xs text-ink-muted">{render.body}</p>
      </div>
    );
  }
  return <span className="min-w-0">{render.text}</span>;
}
