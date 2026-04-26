'use client';

import { FormEvent, useState } from 'react';
import { useSearchParams } from 'next/navigation';
import { getBrowserClient } from '@/lib/supabase-browser';

/**
 * Validate a `?next=` query param before treating it as a post-sign-in
 * destination. Must be a same-origin app path: starts with a single `/`
 * and is not a protocol-relative URL (`//evil.example`). Anything else
 * collapses to /dashboard so an attacker can't smuggle a redirect.
 */
function safeNext(raw: string | null | undefined): string {
  if (!raw) return '/dashboard';
  if (!raw.startsWith('/')) return '/dashboard';
  if (raw.startsWith('//')) return '/dashboard';
  return raw;
}

/**
 * Sign-in surface for the web portal.
 *
 * R-11 twin of the mobile app's progressive auth:
 *   email + (optional) password  →  signInWithPassword
 *   email + no password / bad creds  →  fallback to signInWithOtp (magic link)
 *
 * Google + Apple OAuth have been removed from this UI pending rollout.
 * Google is parked per docs/BACKLOG_GOOGLE_SIGNIN.md (nonce-mismatch
 * post-mortem on mobile; the web path is cleaner but we're keeping
 * the surface consistent across platforms). Apple waits on the iOS
 * Developer Program approval. Bring both back when the mobile app
 * re-enables them — not before, so the two surfaces stay in lockstep
 * under R-11.
 */
export function SignInGate() {
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [info, setInfo] = useState<string | null>(null);
  // `?next=` carries the original destination forward when an
  // unauth'd user hits a gated page (e.g. /credits) and bounces here.
  // Defaults to /dashboard if absent / unsafe.
  const searchParams = useSearchParams();
  const next = safeNext(searchParams?.get('next'));

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
        // reload below triggers the server HomePage to redirect onward.
        // Honour ?next= so app→portal handoffs (e.g. /credits chip)
        // land back on the originally-requested page.
        window.location.assign(next);
        return;
      }
      // Password failed — fall through to the magic-link path with a
      // friendly note so the user understands what happened.
      setInfo('Password didn\'t match — sending you a magic link instead.');
    }

    // 2) Magic-link fallback (also the default when no password given).
    // Pass ?next= through so /auth/callback bounces the user back to
    // the page they originally tried to open (e.g. /credits).
    const redirectTo =
      `${window.location.origin}/auth/callback` +
      (next !== '/dashboard'
        ? `?next=${encodeURIComponent(next)}`
        : '');
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
            disabled={submitting}
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
            disabled={submitting}
            className="w-full rounded-md border border-surface-border bg-surface-raised px-3 py-2 text-sm text-ink placeholder:text-ink-dim focus:border-brand focus:outline-none focus:ring-1 focus:ring-brand disabled:cursor-not-allowed disabled:opacity-60"
            placeholder="Skip for a magic-link email"
          />
        </div>

        <button
          type="submit"
          disabled={submitting}
          className="flex w-full items-center justify-center rounded-md bg-brand px-4 py-3 text-sm font-semibold text-white transition hover:bg-brand-hover disabled:cursor-not-allowed disabled:opacity-60"
        >
          {submitting ? 'Signing in…' : 'Continue'}
        </button>
      </form>

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
