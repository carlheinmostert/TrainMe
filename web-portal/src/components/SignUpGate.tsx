'use client';

import { FormEvent, useEffect, useState } from 'react';
import { getBrowserClient } from '@/lib/supabase-browser';
import { createPortalApi } from '@/lib/supabase/api';

type Props = {
  referralCode: string | null;
  inviterLabel: string;
};

// Stored alongside the main session cookie so /auth/callback can read
// them after Supabase completes the sign-in round-trip (magic-link tap
// back into the portal).
const REFERRAL_COOKIE = 'homefit_referral_code';
const CONSENT_COOKIE = 'homefit_referral_consent';
const COOKIE_MAX_AGE_DAYS = 30;

/**
 * Sign-up surface — mirrors SignInGate's progressive auth (R-11 twin):
 *   email + (optional) password  →  signInWithPassword / sign up
 *   email + no password  →  signInWithOtp (magic link)
 *
 * Google + Apple OAuth intentionally absent until we re-enable them
 * across both surfaces. See SignInGate's module doc for the reasoning.
 *
 * The POPIA consent checkbox is the business-critical widget on this
 * page — it lets the referee opt in to being named in the inviter's
 * dashboard. Default UNCHECKED per R-09 (privacy wins ties).
 */
export function SignUpGate({ referralCode, inviterLabel }: Props) {
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [info, setInfo] = useState<string | null>(null);
  const [consent, setConsent] = useState(false);

  // If a cookie already holds a stale consent flag, clear it on mount —
  // the checkbox is the canonical source for this session.
  useEffect(() => {
    writeCookie(CONSENT_COOKIE, 'false');
    if (referralCode) writeCookie(REFERRAL_COOKIE, referralCode);
  }, [referralCode]);

  async function handleSubmit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    if (!email.trim()) {
      setError('Enter your email.');
      return;
    }
    setError(null);
    setInfo(null);
    setSubmitting(true);

    // Persist consent + referral code via cookies so the /auth/callback
    // route can claim the code after the session completes.
    if (referralCode) writeCookie(REFERRAL_COOKIE, referralCode);
    writeCookie(CONSENT_COOKIE, consent ? 'true' : 'false');

    const supabase = getBrowserClient();

    // 1) If a password was provided, try password sign-in first. Supabase
    //    returns an "Invalid login credentials" error if the email isn't
    //    registered yet — in that case we fall through to the magic-link
    //    path with a friendly note, which also creates the account.
    if (password.length > 0) {
      const { error: pwErr } = await supabase.auth.signInWithPassword({
        email: email.trim(),
        password,
      });
      if (!pwErr) {
        // Bootstrap practice — mirrors mobile AuthService. Password
        // sign-in bypasses /auth/callback, so we have to bootstrap
        // here to close the parity gap for first-time web sign-ins.
        // Idempotent: a no-op for users who already have a practice.
        // Best-effort: log and continue on failure; the next sign-in
        // retries automatically.
        try {
          const portal = createPortalApi(supabase);
          await portal.bootstrapPractice();
        } catch (bootstrapError) {
          // eslint-disable-next-line no-console
          console.error(
            '[SignUpGate] bootstrap_practice_for_user failed:',
            bootstrapError,
          );
        }
        window.location.assign('/dashboard');
        return;
      }
      setInfo(
        'We\'ll send you a sign-in link — tap it to finish creating your account.',
      );
    }

    // 2) Magic-link fallback (also the default when no password given).
    //    shouldCreateUser defaults to true — signInWithOtp will create
    //    the account on first use.
    const redirectTo = `${window.location.origin}/auth/callback?flow=signup`;
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

      <form onSubmit={handleSubmit} className="space-y-3">
        <div>
          <label
            htmlFor="signup-email"
            className="mb-1 block text-xs font-medium text-ink-muted"
          >
            Email
          </label>
          <input
            id="signup-email"
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
            htmlFor="signup-password"
            className="mb-1 block text-xs font-medium text-ink-muted"
          >
            Password <span className="text-ink-dim">(optional)</span>
          </label>
          <input
            id="signup-password"
            type="password"
            autoComplete="new-password"
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

/* -------------------------------------------------------------------------- */
/*  Helpers                                                                   */
/* -------------------------------------------------------------------------- */

function writeCookie(name: string, value: string) {
  if (typeof document === 'undefined') return;
  const maxAge = COOKIE_MAX_AGE_DAYS * 24 * 60 * 60;
  // SameSite=Lax so the cookie survives the OAuth/magic-link redirect round-trip.
  document.cookie = `${name}=${encodeURIComponent(value)}; Path=/; Max-Age=${maxAge}; SameSite=Lax`;
}
