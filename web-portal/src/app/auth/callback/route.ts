import { NextResponse } from 'next/server';
import { getServerClient } from '@/lib/supabase-server';

// OAuth callback. Supabase redirects here with either a `code` (PKCE) or
// a fragment-encoded token. For the PKCE flow we exchange the code for a
// session cookie, then bounce to the dashboard.
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
  }

  return NextResponse.redirect(`${origin}${next}`);
}
