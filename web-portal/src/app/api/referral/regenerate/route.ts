import { NextResponse } from 'next/server';
import { getServerClient } from '@/lib/supabase-server';
import { PortalReferralApi } from '@/lib/supabase/api';

// Rotate the practice's referral code. RLS + the backend RPCs enforce
// that only members of the practice can trigger this. We still verify
// auth here so unauth'd callers get a clean 401 instead of a Postgrest
// error.
export async function POST(request: Request) {
  const supabase = await getServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    return NextResponse.json({ error: 'not signed in' }, { status: 401 });
  }

  const body = (await request.json().catch(() => null)) as {
    practiceId?: string;
  } | null;
  const practiceId = body?.practiceId;
  if (!practiceId) {
    return NextResponse.json({ error: 'practiceId required' }, { status: 400 });
  }

  const api = new PortalReferralApi(supabase);
  const revoked = await api.revokeCode(practiceId);
  if (!revoked) {
    return NextResponse.json({ error: 'revoke failed' }, { status: 500 });
  }

  const code = await api.generateCode(practiceId);
  if (!code) {
    return NextResponse.json({ error: 'generate failed' }, { status: 500 });
  }

  return NextResponse.json({ code });
}
