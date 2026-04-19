'use client';

import { FormEvent, useState } from 'react';
import { getBrowserClient } from '@/lib/supabase-browser';

/**
 * Sign-in surface for the web portal.
 *
 * R-11 twin of the mobile app's progressive auth:
 *   email + (optional) password  →  signInWithPassword
 *   email + no password / bad creds  →  fallback to signInWithOtp (magic link)
 *
 * Google OAuth stays as an alternative. Apple is scaffolded disabled
 * until the iOS Developer Program approval lands (same as mobile).
 */
export function SignInGate() {
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [googleLoading, setGoogleLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [info, setInfo] = useState<string | null>(null);

  async function handleEmailSubmit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    if (!email.trim()) {
      setError('Enter your email.');
      return;
    }
    setError(null);
    setInfo(null);
    setSubmitting(true);

    const supabase = getBrowserClient();

    // 1) If a password was provided, try password sign-in first.
    if (password.length > 0) {
      const { error: pwErr } = await supabase.auth.signInWithPassword({
        email: email.trim(),
        password,
      });
      if (!pwErr) {
        // Success — Supabase has set the session cookie; the browser
        // reload below triggers the server HomePage to redirect to
        // /dashboard.
        window.location.assign('/dashboard');
        return;
      }
      // Password failed — fall through to the magic-link path with a
      // friendly note so the user understands what happened.
      setInfo('Password didn\'t match — sending you a magic link instead.');
    }

    // 2) Magic-link fallback (also the default when no password given).
    const redirectTo = `${window.location.origin}/auth/callback`;
    const { error: otpErr } = await supabase.auth.signInWithOtp({
      email: email.trim(),
      options: { emailRedirectTo: redirectTo },
    });
    if (otpErr) {
      setError(otpErr.message);
      setSubmitting(false);
      return;
    }
    setInfo('Check your email — we just sent you a sign-in link.');
    setSubmitting(false);
  }

  async function handleGoogle() {
    setGoogleLoading(true);
    setError(null);
    setInfo(null);

    const supabase = getBrowserClient();
    const redirectTo = `${window.location.origin}/auth/callback`;

    const { error: err } = await supabase.auth.signInWithOAuth({
      provider: 'google',
      options: { redirectTo },
    });

    if (err) {
      setError(err.message);
      setGoogleLoading(false);
    }
    // On success the browser redirects — no need to reset loading.
  }

  return (
    <section
      className="w-full max-w-sm rounded-lg border border-surface-border bg-surface-base p-8"
      aria-labelledby="signin-heading"
    >
      <h1
        id="signin-heading"
        className="mb-2 font-heading text-2xl font-semibold"
      >
        Sign in
      </h1>
      <p className="mb-6 text-sm text-ink-muted">
        Manage your practice, credits, and plan audit.
      </p>

      <form onSubmit={handleEmailSubmit} className="space-y-3">
        <div>
          <label
            htmlFor="signin-email"
            className="mb-1 block text-xs font-medium text-ink-muted"
          >
            Email
          </label>
          <input
            id="signin-email"
            type="email"
            autoComplete="email"
            required
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            disabled={submitting || googleLoading}
            className="w-full rounded-md border border-surface-border bg-surface-raised px-3 py-2 text-sm text-ink placeholder:text-ink-dim focus:border-brand focus:outline-none focus:ring-1 focus:ring-brand disabled:cursor-not-allowed disabled:opacity-60"
            placeholder="you@practice.co.za"
          />
        </div>

        <div>
          <label
            htmlFor="signin-password"
            className="mb-1 block text-xs font-medium text-ink-muted"
          >
            Password <span className="text-ink-dim">(optional)</span>
          </label>
          <input
            id="signin-password"
            type="password"
            autoComplete="current-password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            disabled={submitting || googleLoading}
            className="w-full rounded-md border border-surface-border bg-surface-raised px-3 py-2 text-sm text-ink placeholder:text-ink-dim focus:border-brand focus:outline-none focus:ring-1 focus:ring-brand disabled:cursor-not-allowed disabled:opacity-60"
            placeholder="Skip for a magic-link email"
          />
        </div>

        <button
          type="submit"
          disabled={submitting || googleLoading}
          className="flex w-full items-center justify-center rounded-md bg-brand px-4 py-3 text-sm font-semibold text-white transition hover:bg-brand-hover disabled:cursor-not-allowed disabled:opacity-60"
        >
          {submitting ? 'Signing in…' : 'Continue'}
        </button>
      </form>

      <div className="my-5 flex items-center gap-3">
        <div className="h-px flex-1 bg-surface-border" />
        <span className="text-xs text-ink-dim">or</span>
        <div className="h-px flex-1 bg-surface-border" />
      </div>

      <button
        type="button"
        onClick={handleGoogle}
        disabled={submitting || googleLoading}
        className="flex w-full items-center justify-center gap-3 rounded-md bg-white px-4 py-3 text-sm font-medium text-[#1f1f1f] transition hover:bg-ink disabled:cursor-not-allowed disabled:opacity-60"
      >
        <GoogleIcon />
        {googleLoading ? 'Signing in…' : 'Continue with Google'}
      </button>

      <button
        type="button"
        disabled
        aria-disabled="true"
        className="mt-3 flex w-full items-center justify-center gap-3 rounded-md border border-surface-border bg-surface-raised px-4 py-3 text-sm font-medium text-ink-muted"
      >
        <AppleIcon />
        Continue with Apple
        <span className="ml-1 text-xs text-ink-dim">(coming soon)</span>
      </button>

      {error && (
        <p
          role="alert"
          className="mt-4 rounded-md border border-error/40 bg-error/10 px-3 py-2 text-sm text-error"
        >
          {error}
        </p>
      )}

      {info && (
        <p
          role="status"
          className="mt-4 rounded-md border border-brand/40 bg-brand/10 px-3 py-2 text-sm text-ink"
        >
          {info}
        </p>
      )}

      <p className="mt-6 text-xs text-ink-dim">
        By continuing, you agree to our terms of service and privacy policy.
      </p>
    </section>
  );
}

function GoogleIcon() {
  return (
    <svg
      className="h-5 w-5"
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 48 48"
      aria-hidden="true"
    >
      <path
        fill="#FFC107"
        d="M43.6 20.5H42V20H24v8h11.3c-1.6 4.6-6 8-11.3 8-6.6 0-12-5.4-12-12s5.4-12 12-12c3 0 5.8 1.1 7.9 3l5.7-5.7C34 6.1 29.3 4 24 4 12.9 4 4 12.9 4 24s8.9 20 20 20 20-8.9 20-20c0-1.3-.1-2.4-.4-3.5z"
      />
      <path
        fill="#FF3D00"
        d="M6.3 14.7l6.6 4.8C14.7 15.9 19 13 24 13c3 0 5.8 1.1 7.9 3l5.7-5.7C34 6.1 29.3 4 24 4 16.3 4 9.7 8.3 6.3 14.7z"
      />
      <path
        fill="#4CAF50"
        d="M24 44c5.2 0 9.9-2 13.4-5.2l-6.2-5.2C29.2 35.1 26.8 36 24 36c-5.3 0-9.7-3.4-11.3-8l-6.5 5C9.6 39.6 16.2 44 24 44z"
      />
      <path
        fill="#1976D2"
        d="M43.6 20.5H42V20H24v8h11.3c-.8 2.3-2.3 4.3-4.1 5.6l6.2 5.2C41.1 36.1 44 30.6 44 24c0-1.3-.1-2.4-.4-3.5z"
      />
    </svg>
  );
}

function AppleIcon() {
  return (
    <svg
      className="h-5 w-5"
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 24 24"
      fill="currentColor"
      aria-hidden="true"
    >
      <path d="M17.05 20.28c-.98.95-2.05.8-3.08.35-1.09-.46-2.09-.48-3.24 0-1.44.62-2.2.44-3.06-.35C2.79 15.25 3.51 7.59 9.05 7.31c1.35.07 2.29.74 3.08.8 1.18-.24 2.31-.93 3.57-.84 1.51.12 2.65.72 3.4 1.8-3.12 1.87-2.38 5.98.48 7.13-.57 1.5-1.31 2.99-2.54 4.09zM12 7.25c-.15-2.23 1.66-4.07 3.74-4.25.29 2.58-2.34 4.5-3.74 4.25z" />
    </svg>
  );
}
