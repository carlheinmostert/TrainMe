'use client';

import { useEffect, useRef, useState } from 'react';
import { getBrowserClient } from '@/lib/supabase-browser';

type PasswordState =
  | { kind: 'idle' }
  | { kind: 'saving' }
  | { kind: 'ok' }
  | { kind: 'err'; message: string };

type SignOutState =
  | { kind: 'idle' }
  | { kind: 'pending'; endsAt: number };

// Window (ms) during which the sign-out can be cancelled after pressing the
// button. Matches the R-01 undo pattern on mobile — destructive action fires
// immediately in UI terms, but the real call is delayed for 3 seconds.
const UNDO_WINDOW_MS = 3000;

// Minimum password length. Supabase's own default is 6, but we nudge the
// copy to 8 as a sane baseline. If the server rejects a shorter password
// under a different project setting, the error surfaces inline.
const MIN_LEN = 8;

type Props = {
  email: string;
};

export function AccountPanel({ email }: Props) {
  return (
    <div className="mt-8 flex flex-col gap-8">
      <PasswordSection />
      <SignOutSection email={email} />
    </div>
  );
}

function PasswordSection() {
  const [password, setPassword] = useState('');
  const [confirm, setConfirm] = useState('');
  const [state, setState] = useState<PasswordState>({ kind: 'idle' });

  async function handleSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (state.kind === 'saving') return;

    // Local validation first — cheaper + clearer than a server round-trip.
    if (password.length < MIN_LEN) {
      setState({
        kind: 'err',
        message: `Password must be at least ${MIN_LEN} characters.`,
      });
      return;
    }
    if (password !== confirm) {
      setState({
        kind: 'err',
        message: 'Passwords do not match.',
      });
      return;
    }

    setState({ kind: 'saving' });
    try {
      const supabase = getBrowserClient();
      const { error } = await supabase.auth.updateUser({ password });
      if (error) {
        setState({ kind: 'err', message: error.message });
        return;
      }
      // Success: clear the form so a second visit starts fresh.
      setPassword('');
      setConfirm('');
      setState({ kind: 'ok' });
    } catch (err) {
      setState({
        kind: 'err',
        message: err instanceof Error ? err.message : 'Something went wrong.',
      });
    }
  }

  // Derived helper — strength hint. Cheap heuristic: length + character mix.
  const strength = hintStrength(password);

  return (
    <section
      className="rounded-lg border border-surface-border bg-surface-base p-6"
      aria-labelledby="password-heading"
    >
      <h2
        id="password-heading"
        className="font-heading text-lg font-semibold"
      >
        Set or change password
      </h2>
      <p className="mt-1 text-sm text-ink-muted">
        Add a password so you don&rsquo;t have to wait for a magic link on
        every sign-in. If you already have one, this replaces it.
      </p>

      <form onSubmit={handleSubmit} className="mt-5 flex flex-col gap-4">
        <div className="flex flex-col gap-1.5">
          <label
            htmlFor="new-password"
            className="text-xs font-medium text-ink-muted"
          >
            New password
          </label>
          <input
            id="new-password"
            name="new-password"
            type="password"
            autoComplete="new-password"
            required
            minLength={MIN_LEN}
            value={password}
            onChange={(e) => {
              setPassword(e.target.value);
              if (state.kind === 'err' || state.kind === 'ok') {
                setState({ kind: 'idle' });
              }
            }}
            className="rounded-md border border-surface-border bg-surface-raised px-3 py-2 text-sm text-ink outline-none transition focus:border-brand"
          />
          <StrengthHint password={password} strength={strength} />
        </div>

        <div className="flex flex-col gap-1.5">
          <label
            htmlFor="confirm-password"
            className="text-xs font-medium text-ink-muted"
          >
            Confirm new password
          </label>
          <input
            id="confirm-password"
            name="confirm-password"
            type="password"
            autoComplete="new-password"
            required
            minLength={MIN_LEN}
            value={confirm}
            onChange={(e) => {
              setConfirm(e.target.value);
              if (state.kind === 'err' || state.kind === 'ok') {
                setState({ kind: 'idle' });
              }
            }}
            className="rounded-md border border-surface-border bg-surface-raised px-3 py-2 text-sm text-ink outline-none transition focus:border-brand"
          />
        </div>

        <div className="flex items-center gap-4">
          <button
            type="submit"
            disabled={state.kind === 'saving'}
            className="rounded-md bg-brand px-4 py-2.5 text-sm font-semibold text-surface-bg transition hover:bg-brand-light disabled:cursor-not-allowed disabled:opacity-60"
          >
            {state.kind === 'saving' ? 'Saving…' : 'Save password'}
          </button>

          {state.kind === 'ok' && (
            <p
              role="status"
              className="text-sm text-success"
            >
              Password updated.
            </p>
          )}
        </div>

        {state.kind === 'err' && (
          <p
            role="alert"
            className="rounded-md border border-error/40 bg-error/10 px-3 py-2 text-sm text-error"
          >
            {state.message}
          </p>
        )}
      </form>
    </section>
  );
}

function SignOutSection({ email }: { email: string }) {
  const [state, setState] = useState<SignOutState>({ kind: 'idle' });
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  // Always clear the pending timer on unmount — otherwise the sign-out
  // would still fire after the user navigates away mid-undo window.
  useEffect(() => {
    return () => {
      if (timerRef.current) clearTimeout(timerRef.current);
    };
  }, []);

  function handleStart() {
    if (state.kind === 'pending') return;
    const endsAt = Date.now() + UNDO_WINDOW_MS;
    setState({ kind: 'pending', endsAt });
    timerRef.current = setTimeout(() => {
      // Submit the existing server-action form — reuses the tested cookie
      // clearing path in /auth/sign-out/route.ts.
      const form = document.createElement('form');
      form.method = 'POST';
      form.action = '/auth/sign-out';
      document.body.appendChild(form);
      form.submit();
    }, UNDO_WINDOW_MS);
  }

  function handleUndo() {
    if (timerRef.current) {
      clearTimeout(timerRef.current);
      timerRef.current = null;
    }
    setState({ kind: 'idle' });
  }

  return (
    <section
      className="rounded-lg border border-surface-border bg-surface-base p-6"
      aria-labelledby="signout-heading"
    >
      <h2
        id="signout-heading"
        className="font-heading text-lg font-semibold"
      >
        Sign out
      </h2>
      <p className="mt-1 text-sm text-ink-muted">
        End the session for <span className="text-ink">{email || 'this account'}</span> on
        this browser. You can undo within 3 seconds.
      </p>

      {state.kind === 'idle' ? (
        <button
          type="button"
          onClick={handleStart}
          className="mt-5 rounded-md border border-surface-border bg-surface-raised px-4 py-2.5 text-sm font-medium text-ink transition hover:border-ink-muted"
        >
          Sign out
        </button>
      ) : (
        <SignOutCountdown endsAt={state.endsAt} onUndo={handleUndo} />
      )}
    </section>
  );
}

function SignOutCountdown({
  endsAt,
  onUndo,
}: {
  endsAt: number;
  onUndo: () => void;
}) {
  const [remaining, setRemaining] = useState(() =>
    Math.max(0, Math.ceil((endsAt - Date.now()) / 1000)),
  );

  useEffect(() => {
    // Tick once per second for the visible counter. The actual redirect is
    // driven by the setTimeout in SignOutSection — this is purely cosmetic.
    const id = setInterval(() => {
      setRemaining(Math.max(0, Math.ceil((endsAt - Date.now()) / 1000)));
    }, 250);
    return () => clearInterval(id);
  }, [endsAt]);

  return (
    <div
      role="status"
      aria-live="polite"
      className="mt-5 flex flex-wrap items-center justify-between gap-3 rounded-md border border-warning/40 bg-warning/10 px-4 py-3"
    >
      <p className="text-sm text-ink">
        Signing out in <span className="font-mono text-warning">{remaining}s</span>
        …
      </p>
      <button
        type="button"
        onClick={onUndo}
        className="rounded-md border border-warning/60 px-3 py-1.5 text-xs font-semibold uppercase tracking-wide text-warning transition hover:bg-warning/15"
      >
        Undo
      </button>
    </div>
  );
}

// -- small helpers -----------------------------------------------------------

type Strength = 'weak' | 'ok' | 'strong';

function hintStrength(password: string): Strength {
  if (password.length < MIN_LEN) return 'weak';
  const classes = [
    /[a-z]/,
    /[A-Z]/,
    /\d/,
    /[^A-Za-z0-9]/,
  ].filter((re) => re.test(password)).length;
  if (password.length >= 12 && classes >= 3) return 'strong';
  if (classes >= 2) return 'ok';
  return 'weak';
}

function StrengthHint({
  password,
  strength,
}: {
  password: string;
  strength: Strength;
}) {
  // Don't show the hint until the user types — keep the form calm on load.
  if (password.length === 0) {
    return (
      <p className="text-xs text-ink-dim">
        At least {MIN_LEN} characters. A mix of letters, numbers, and
        symbols is stronger.
      </p>
    );
  }

  const label =
    strength === 'strong'
      ? 'Strong'
      : strength === 'ok'
        ? 'OK'
        : 'Weak';
  const color =
    strength === 'strong'
      ? 'text-success'
      : strength === 'ok'
        ? 'text-warning'
        : 'text-error';

  return (
    <p className={`text-xs ${color}`} aria-live="polite">
      Password strength: {label}
    </p>
  );
}
