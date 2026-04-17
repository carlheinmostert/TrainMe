import { NextResponse } from 'next/server';
import { getServerClient } from '@/lib/supabase-server';

export async function POST(request: Request) {
  const supabase = await getServerClient();
  await supabase.auth.signOut();
  return NextResponse.redirect(new URL('/', request.url), { status: 303 });
}

// Also accept GET as a convenience for manual testing / direct nav.
export async function GET(request: Request) {
  const supabase = await getServerClient();
  await supabase.auth.signOut();
  return NextResponse.redirect(new URL('/', request.url));
}
