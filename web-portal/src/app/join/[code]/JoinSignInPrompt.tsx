'use client';

import { type FormEvent, useState } from 'react';
import { getBrowserClient } from '@/lib/supabase-browser';
import { BrandHeader } from '@/components/BrandHeader';

type Props = {
  /** Normalized upper-case invite code. */
  code: string;
};

/**
 * Sign-in gate specialised for `/join/[code]`.
 *
 * This is a direct cousin of the top-level `SignInGate`, but the magic-link
 * callback URL embeds `?next=/join/{code}` so the auth/callback route
 * bounces the user straight back to the claim page after email verification.
 * Password sign-in uses a manual `window.location.assign` to the same
 * destination.
 *
 * Kept separate from the main SignInGate to avoid muddying that component
 * with a `next` prop — it's the primary sign-in surface and the simpler
 * mental model is worth the duplication here.
 */
export function JoinSignInPrompt({ code }: Props) {
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [info, setInfo] = useState<string | null>(null);

  const joinPath = `/join/${encodeURIComponent(code)}`;

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

    if (password.length > 0) {
      const { error: pwErr } = await supabase.auth.signInWithPassword({
        email: email.trim(),
        password,
      });
      if (!pwErr) {
        // Full reload so the join page server component picks up the
        // new session cookie on its next render.
        window.location.assign(joinPath);
        return;
      }
      setInfo("Password didn't match — sending you a magic link instead.");
    }

    const redirectTo = `${window.location.origin}/auth/callback?next=${encodeURIComponent(joinPath)}`;
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
    <main className="flex min-h-screen flex-col">
      <BrandHeader />
      <section className="flex flex-1 items-center justify-center px-5 py-10 sm:px-6 sm:py-16">
        <section
          className="w-full max-w-sm rounded-lg border border-surface-border bg-surface-base p-8"
          aria-labelledby="join-signin-heading"
        >
          <h1
            id="join-signin-heading"
            className="mb-2 font-heading text-2xl font-semibold"
          >
            Sign in to join
          </h1>
          <p className="mb-6 text-sm text-ink-muted">
            You&rsquo;ve been invited to a practice. Sign in or create an
            account to accept.
          </p>

          <form onSubmit={handleEmailSubmit} className="space-y-3">
            <div>
              <label
                htmlFor="join-email"
                className="mb-1 block text-xs font-medium text-ink-muted"
              >
                Email
              </label>
              <input
                id="join-email"
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
                htmlFor="join-password"
                className="mb-1 block text-xs font-medium text-ink-muted"
              >
                Password <span className="text-ink-dim">(optional)</span>
              </label>
              <input
                id="join-password"
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
              className="mt-4 rounded-md border border-error/40 bg-error/10 px-3 py-2 text-xs text-error"
            >
              {error}
            </p>
          )}
          {info && (
            <p
              role="status"
              className="mt-4 rounded-md border border-brand/40 bg-brand/10 px-3 py-2 text-xs text-brand-light"
            >
              {info}
            </p>
          )}
        </section>
      </section>
    </main>
  );
}
