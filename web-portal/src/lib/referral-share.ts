// Copy + share helpers for the referral flow.
// Voice is peer-to-peer (R-06 + voice.md). We never use "earn", "commission",
// "reward", "cash", "payout", or any MLM-adjacent language.

import { appUrl } from './env';

// A9 (HARDCODED-AUDIT-2026-05-12) — strict-fail via env helper. The
// previous `?? 'https://manage.homefit.studio'` fallback meant a
// staging Vercel deploy with a missing `NEXT_PUBLIC_APP_URL` minted
// referral URLs pointing at PROD portal — a friend clicking it would
// land on prod looking for a code that lives in staging.
export function referralUrl(code: string): string {
  return `${appUrl()}/r/${code}`;
}

export type ShareChannel = 'whatsapp' | 'imessage' | 'email' | 'copy';

/** Pre-composed peer-to-peer message drafts. Short, professional, no hype. */
export function shareMessage(code: string): string {
  const url = referralUrl(code);
  return `I use homefit.studio to share exercise plans with my clients — you might like it too: ${url}`;
}

export function shareEmailSubject(): string {
  return 'Try homefit.studio';
}

export function shareEmailBody(code: string): string {
  const url = referralUrl(code);
  return [
    'Hi,',
    '',
    'I\'ve been using homefit.studio to share exercise plans with my clients. Capture a session on your phone, and your client gets a clean visual plan via a link they can open in WhatsApp. No app required on their side.',
    '',
    'Thought you might want to try it:',
    url,
    '',
    'Let me know what you think.',
  ].join('\n');
}

export function whatsappHref(code: string): string {
  return `https://wa.me/?text=${encodeURIComponent(shareMessage(code))}`;
}

export function imessageHref(code: string): string {
  return `sms:&body=${encodeURIComponent(shareMessage(code))}`;
}

export function mailtoHref(code: string): string {
  const subject = encodeURIComponent(shareEmailSubject());
  const body = encodeURIComponent(shareEmailBody(code));
  return `mailto:?subject=${subject}&body=${body}`;
}
