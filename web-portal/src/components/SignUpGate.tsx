'use client';

import { useEffect, useState } from 'react';
import { getBrowserClient } from '@/lib/supabase-browser';

type Props = {
  referralCode: string | null;
  inviterLabel: string;
};

// Stored alongside the main session cookie so /auth/callback can read
// them after Supabase completes the OAuth round-trip.
const REFERRAL_COOKIE = 'homefit_referral_code';
const CONSENT_COOKIE = 'homefit_referral_consent';
const COOKIE_MAX_AGE_DAYS = 30;

export function SignUpGate({ referralCode, inviterLabel }: Props) {
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // POPIA: opt-in for visibility. Default UNCHECKED per R-09 obvious-default.
  // Privacy wins ties — referee appears as "Practice N" in the inviter's
  // dashboard unless they explicitly opt in here.
  const [consent, setConsent] = useState(false);

  // If a cookie already holds a stale consent flag, clear it on mount —
  // the checkbox is the canonical source for this session.
  useEffect(() => {
    writeCookie(CONSENT_COOKIE, 'false');
    if (referralCode) writeCookie(REFERRAL_COOKIE, referralCode);
  }, [referralCode]);

  async function handleGoogle() {
    setLoading(true);
    setError(null);

    // Persist consent + referral code via cookies so the /auth/callback
    // route can claim the code after the session exchange completes.
    if (referralCode) writeCookie(REFERRAL_COOKIE, referralCode);
    writeCookie(CONSENT_COOKIE, consent ? 'true' : 'false');

    const supabase = getBrowserClient();
    const redirectTo = `${window.location.origin}/auth/callback?flow=signup`;

    const { error: err } = await supabase.auth.signInWithOAuth({
      provider: 'google',
      options: { redirectTo },
    });

    if (err) {
      setError(err.message);
      setLoading(false);
    }
  }

  return (
    <section
      className="w-full rounded-lg border border-surface-border bg-surface-base p-8"
      aria-labelledby="signup-heading"
    >
      <h1
        id="signup-heading"
        className="mb-2 font-heading text-2xl font-semibold"
      >
        Create your account
      </h1>
      <p className="mb-6 text-sm text-ink-muted">
        Manage your practice, credits, and plans.
      </p>

      <button
        type="button"
        onClick={handleGoogle}
        disabled={loading}
        className="flex w-full items-center justify-center gap-3 rounded-md bg-white px-4 py-3 text-sm font-medium text-[#1f1f1f] transition hover:bg-ink disabled:cursor-not-allowed disabled:opacity-60"
      >
        <GoogleIcon />
        {loading ? 'Signing in…' : 'Continue with Google'}
      </button>

      {referralCode && (
        <div className="mt-6 border-t border-surface-border pt-6">
          <label className="flex cursor-pointer items-start gap-3">
            <input
              type="checkbox"
              checked={consent}
              onChange={(e) => setConsent(e.target.checked)}
              className="mt-1 h-4 w-4 flex-none rounded border-surface-border bg-surface-raised accent-brand focus-visible:shadow-focus-ring"
              aria-describedby="consent-help"
            />
            <span className="text-sm text-ink">
              Allow <span className="font-semibold">{inviterLabel}</span> to
              see my practice name in their network.
            </span>
          </label>
          <p id="consent-help" className="mt-2 pl-7 text-xs text-ink-dim">
            Otherwise you&rsquo;ll appear as &ldquo;Practice 1&rdquo;,
            &ldquo;Practice 2&rdquo;&hellip; in their dashboard. You can
            change this later in your settings.
          </p>
        </div>
      )}

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

/* -------------------------------------------------------------------------- */
/*  Helpers                                                                   */
/* -------------------------------------------------------------------------- */

function writeCookie(name: string, value: string) {
  if (typeof document === 'undefined') return;
  const maxAge = COOKIE_MAX_AGE_DAYS * 24 * 60 * 60;
  // SameSite=Lax so the cookie survives the OAuth redirect round-trip.
  document.cookie = `${name}=${encodeURIComponent(value)}; Path=/; Max-Age=${maxAge}; SameSite=Lax`;
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
