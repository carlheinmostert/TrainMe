// Shared constants + helper for the referral signup cookies. The code and
// consent flag bounce through Supabase's OAuth redirect, so they have to live
// in cookies (SameSite=Lax). Before this module, the names were duplicated
// across SignUpGate, ReferralCookieWriter, and auth/callback/route.ts — a
// rename-risk the DAL layering doesn't catch.

export const REFERRAL_COOKIE = 'homefit_referral_code';
export const CONSENT_COOKIE = 'homefit_referral_consent';
export const REFERRAL_COOKIE_MAX_AGE_DAYS = 30;

/**
 * Writes a referral-related cookie on the client. Must be called from a
 * 'use client' component — silently no-ops during SSR where `document` is
 * undefined. SameSite=Lax so the cookie survives the OAuth redirect.
 */
export function writeReferralCookie(name: string, value: string): void {
  if (typeof document === 'undefined') return;
  const maxAge = REFERRAL_COOKIE_MAX_AGE_DAYS * 24 * 60 * 60;
  document.cookie = `${name}=${encodeURIComponent(value)}; Path=/; Max-Age=${maxAge}; SameSite=Lax`;
}
