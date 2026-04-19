import { NextResponse } from 'next/server';
import { getServerClient } from '@/lib/supabase-server';
import { PortalReferralApi } from '@/lib/supabase/api';

const REFERRAL_COOKIE = 'homefit_referral_code';
const CONSENT_COOKIE = 'homefit_referral_consent';

// OAuth callback. Supabase redirects here with either a `code` (PKCE) or
// a fragment-encoded token. For the PKCE flow we exchange the code for a
// session cookie, then bounce to the dashboard.
//
// Extended 2026-04-19 to claim referral codes captured at /r/{code} or
// /sign-up. Failure to claim is silent — we never block a user from
// reaching their dashboard over a dodgy referral link.
export async function GET(request: Request) {
  const { searchParams, origin } = new URL(request.url);
  const code = searchParams.get('code');
  const next = searchParams.get('next') ?? '/dashboard';

  if (code) {
    const supabase = await getServerClient();
    const { error } = await supabase.auth.exchangeCodeForSession(code);

    if (error) {
      return NextResponse.redirect(
        `${origin}/?auth_error=${encodeURIComponent(error.message)}`,
      );
    }

    // Referral claim — best-effort. This runs AFTER exchangeCodeForSession,
    // so the trainer's practice row should already be bootstrapped by the
    // existing sentinel-claim / auto-create flow.
    try {
      await tryClaimReferral(request);
    } catch {
      // Intentionally swallow — signup path must not fail on referral errors.
    }
  }

  const response = NextResponse.redirect(`${origin}${next}`);
  // Clear the referral cookies regardless of claim outcome so the user
  // doesn't drag them around indefinitely after signing in.
  response.cookies.delete(REFERRAL_COOKIE);
  response.cookies.delete(CONSENT_COOKIE);
  return response;
}

async function tryClaimReferral(request: Request) {
  const cookieHeader = request.headers.get('cookie') ?? '';
  const referralCode = parseCookie(cookieHeader, REFERRAL_COOKIE);
  if (!referralCode) return;

  const consentRaw = parseCookie(cookieHeader, CONSENT_COOKIE);
  const consent = consentRaw === 'true';

  const supabase = await getServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return;

  // Fetch the practice this user was bootstrapped into. RLS scopes
  // practice_members to rows where trainer_id = auth.uid(), so we can
  // safely select without an extra filter.
  const { data: members, error } = await supabase
    .from('practice_members')
    .select('practice_id, joined_at')
    .order('joined_at', { ascending: true })
    .limit(1);

  if (error || !members || members.length === 0) return;
  const practiceId = members[0].practice_id as string;

  const api = new PortalReferralApi(supabase);
  await api.claimCode(referralCode, practiceId, consent);
}

function parseCookie(header: string, name: string): string | null {
  const parts = header.split(';');
  for (const part of parts) {
    const [rawName, ...rest] = part.split('=');
    if (!rawName) continue;
    if (rawName.trim() === name) {
      return decodeURIComponent(rest.join('=').trim());
    }
  }
  return null;
}
