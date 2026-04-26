import { NextResponse, type NextRequest } from 'next/server';
import { createServerClient, type CookieOptions } from '@supabase/ssr';
import { ACTIVE_PRACTICE_COOKIE, UUID_RE } from '@/lib/active-practice';

/**
 * Edge middleware — Wave 29.
 *
 * Honours `?practice=<uuid>` as the app→portal handoff signal.
 *
 * The mobile app builds outbound portal URLs via
 * `app/lib/services/portal_links.dart` and tags every link with the
 * active practice id. Without this hook, the portal would surface
 * whichever practice the user last picked in their last portal
 * session — out of context with what they were just doing in the app.
 *
 * Flow:
 *   1. If the request URL has no `practice` query param → no-op.
 *   2. Validate the param: must be a uuid AND the signed-in user must
 *      be a member of that practice (`practice_members.trainer_id =
 *      auth.uid()`). RLS already protects every downstream RPC, but
 *      this membership check stops us from setting the cookie to a
 *      foreign practice id.
 *   3. On valid match → set the `hf_active_practice` cookie to the
 *      requested id and 302-redirect to the same path with the
 *      `practice` param stripped. The cookie carries the context
 *      forward; the clean URL means refresh/share doesn't
 *      re-trigger this branch.
 *   4. On invalid id (not a member, not a uuid, signed-out, error) →
 *      silently strip the param via 302 anyway. We never reveal
 *      whether the caller is or isn't a member of a given practice;
 *      the URL is just cleaned up.
 *
 * The cookie is read by page-level fallback logic when no `?practice=`
 * is present. See `web-portal/src/app/dashboard/page.tsx` for the
 * primary fallback site; other pages all carry `?practice=` from
 * upstream Links, so they don't need their own fallback.
 */

const SUPABASE_URL =
  process.env.NEXT_PUBLIC_SUPABASE_URL ??
  'https://yrwcofhovrcydootivjx.supabase.co';

const SUPABASE_ANON_KEY =
  process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? 'placeholder-anon-key';

export async function middleware(request: NextRequest) {
  const url = request.nextUrl;
  const practiceParam = url.searchParams.get('practice');
  if (!practiceParam) {
    // Hot path — no param, nothing to do.
    return NextResponse.next();
  }

  // Build the redirect target up front: same path, same query EXCEPT
  // the `practice` key is dropped. We always strip it (success or
  // silent reject) so the URL stays clean either way.
  const cleanUrl = url.clone();
  cleanUrl.searchParams.delete('practice');
  const redirectResponse = NextResponse.redirect(cleanUrl, 302);

  if (!UUID_RE.test(practiceParam)) {
    // Not a UUID — just strip + redirect, never set the cookie.
    return redirectResponse;
  }

  // Validate membership. Must use the @supabase/ssr server client so
  // the auth cookies the middleware sees match the page's view of the
  // session. We pass a paired (request,response) cookie adapter that
  // the SDK uses to refresh tokens transparently — same pattern the
  // SDK docs recommend for middleware.
  const supabase = createServerClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    cookies: {
      getAll() {
        return request.cookies.getAll();
      },
      setAll(cookiesToSet: { name: string; value: string; options: CookieOptions }[]) {
        for (const { name, value, options } of cookiesToSet) {
          // Mirror onto the outbound response so refreshed tokens
          // make it back to the browser.
          redirectResponse.cookies.set(name, value, options);
        }
      },
    },
  });

  let isMember = false;
  try {
    const {
      data: { user },
    } = await supabase.auth.getUser();
    if (user) {
      const { data, error } = await supabase
        .from('practice_members')
        .select('practice_id')
        .eq('trainer_id', user.id)
        .eq('practice_id', practiceParam)
        .limit(1);
      isMember = !error && Array.isArray(data) && data.length > 0;
    }
  } catch {
    // RLS / network / signed-out — fall through to silent reject.
    isMember = false;
  }

  if (isMember) {
    // Pin this practice for THIS user's session. Httponly so client
    // JS can't tamper; sameSite=lax so it survives top-level redirects
    // (the typical "follow link from app" path).
    redirectResponse.cookies.set(ACTIVE_PRACTICE_COOKIE, practiceParam, {
      path: '/',
      httpOnly: true,
      sameSite: 'lax',
      secure: true,
      // 30 days — far longer than a session, but cheap to over-extend
      // since the cookie is harmless on its own (page logic still
      // validates membership before trusting it).
      maxAge: 60 * 60 * 24 * 30,
    });
  }

  return redirectResponse;
}

/**
 * Run on every page-level request. Excludes static assets, the Next
 * internals, and API routes (those don't carry `?practice=` from the
 * app and we don't want to redirect a JSON endpoint).
 */
export const config = {
  matcher: [
    '/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp)$|api/).*)',
  ],
};
