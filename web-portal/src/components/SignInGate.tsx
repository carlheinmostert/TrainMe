'use client';

import { useState } from 'react';
import { getBrowserClient } from '@/lib/supabase-browser';
import { GoogleSignInButton } from './GoogleSignInButton';

export function SignInGate() {
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleGoogle() {
    setLoading(true);
    setError(null);

    const supabase = getBrowserClient();
    const redirectTo = `${window.location.origin}/auth/callback`;

    const { error: err } = await supabase.auth.signInWithOAuth({
      provider: 'google',
      options: { redirectTo },
    });

    if (err) {
      setError(err.message);
      setLoading(false);
    }
    // On success the browser redirects — no need to setLoading(false).
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

      <GoogleSignInButton onClick={handleGoogle} loading={loading} />

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

      <p className="mt-6 text-xs text-ink-dim">
        By continuing, you agree to our terms of service and privacy policy.
      </p>
    </section>
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
