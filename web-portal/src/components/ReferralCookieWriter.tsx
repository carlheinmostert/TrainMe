'use client';

import { useEffect } from 'react';
import { REFERRAL_COOKIE, writeReferralCookie } from '@/lib/referral-cookies';

type Props = { code: string };

// Persists the referral code to a client-side cookie so the signup flow can
// recover it even if the user navigates around before creating an account.
// Server Components can't reliably set cookies outside Server Actions, so we
// do it on the client. Non-visual — renders nothing.
export function ReferralCookieWriter({ code }: Props) {
  useEffect(() => {
    if (!code) return;
    writeReferralCookie(REFERRAL_COOKIE, code);
  }, [code]);
  return null;
}
