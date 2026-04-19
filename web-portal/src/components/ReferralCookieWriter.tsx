'use client';

import { useEffect } from 'react';

const REFERRAL_COOKIE = 'homefit_referral_code';
const MAX_AGE_DAYS = 30;

type Props = { code: string };

// Persists the referral code to a client-side cookie so the signup flow can
// recover it even if the user navigates around before creating an account.
// Server Components can't reliably set cookies outside Server Actions, so we
// do it on the client. Non-visual — renders nothing.
export function ReferralCookieWriter({ code }: Props) {
  useEffect(() => {
    if (!code) return;
    const maxAge = MAX_AGE_DAYS * 24 * 60 * 60;
    document.cookie = `${REFERRAL_COOKIE}=${encodeURIComponent(code)}; Path=/; Max-Age=${maxAge}; SameSite=Lax`;
  }, [code]);
  return null;
}
