'use client';

import { useEffect, useState } from 'react';
import { getBrowserClient } from '@/lib/supabase-browser';
import {
  CONSENT_COOKIE,
  REFERRAL_COOKIE,
  writeReferralCookie,
} from '@/lib/referral-cookies';
import { GoogleSignInButton } from './GoogleSignInButton';

type Props = {
  referralCode: string | null;
  inviterLabel: string;
};

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
    writeReferralCookie(CONSENT_COOKIE, 'false');
    if (referralCode) writeReferralCookie(REFERRAL_COOKIE, referralCode);
  }, [referralCode]);

  async function handleGoogle() {
    setLoading(true);
    setError(null);

    // Persist consent + referral code via cookies so the /auth/callback
    // route can claim the code after the session exchange completes.
    if (referralCode) writeReferralCookie(REFERRAL_COOKIE, referralCode);
    writeReferralCookie(CONSENT_COOKIE, consent ? 'true' : 'false');

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

      <GoogleSignInButton onClick={handleGoogle} loading={loading} />

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
