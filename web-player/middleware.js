// Vercel Edge Middleware that serves bot-friendly HTML with OG meta tags
// for WhatsApp / iMessage / Slack / Twitter etc. link previews.
//
// IMPORTANT: reads go through the `get_plan_full(p_plan_id)` SECURITY
// DEFINER RPC — NOT direct PostgREST SELECTs on `plans` / `exercises`.
// Milestone C locked anon SELECT on those tables; direct reads return
// empty, which silently broke every WhatsApp preview since the lockdown
// landed. Same contract used by `web-player/api.js`.
//
// Supabase URL + key are read from Vercel-injected env vars at edge
// runtime (NOT hardcoded). Strict-fail policy mirrors `build.sh`: if
// `NEXT_PUBLIC_SUPABASE_URL` is missing the middleware passes through
// (returns undefined) so the SPA can render — never silently routes to
// prod. The Vercel-Supabase integration provides per-environment values
// so staging deployments hit the staging branch DB and prod hits prod.
// Without this, bot user-agents hitting `staging.session.homefit.studio`
// would query PROD Supabase and 404 on every staging-published share.
//
// The OG-card URL host is derived from the incoming request's origin so
// a staging request gets a `staging.session.*` URL in the unfurl card
// rather than the hardcoded prod host. Critical for staging share links.

export default async function middleware(request) {
  const url = new URL(request.url);
  const planMatch = url.pathname.match(/^\/p\/([a-zA-Z0-9_-]+)/);
  // Workout handout (artifact-system Wave 1 / ADR 0025) — same OG pattern
  // as /p/{planId}. The bot sees the plan title + first non-rest hero
  // image. The unfurl card is the same as the player so practitioners
  // pasting either link into WhatsApp get an equivalent preview.
  const handoutMatch = url.pathname.match(/^\/h\/([a-zA-Z0-9_-]+)/);
  const profileMatch = url.pathname.match(/^\/v\/([a-z0-9-]+)/);
  if (!planMatch && !handoutMatch && !profileMatch) return; // Not a known surface, pass through

  const ua = request.headers.get('user-agent') || '';
  const isBot = /WhatsApp|facebookexternalhit|Twitterbot|LinkedInBot|Slackbot|TelegramBot/i.test(ua);
  if (!isBot) return; // Normal browser, let SPA handle it

  // Strict-fail env resolution: prefer publishable-key shape, fall back
  // to the legacy anon-key name (same precedence as `build.sh`). If
  // either is missing we log + pass through — never fall back to prod.
  const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const SUPABASE_ANON_KEY =
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY
    || process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

  if (!SUPABASE_URL || !SUPABASE_ANON_KEY) {
    console.error(
      '[middleware] NEXT_PUBLIC_SUPABASE_URL or anon/publishable key is not set. '
        + 'Bot unfurl pass-through. Configure the Vercel-Supabase integration for '
        + 'this environment.',
    );
    return; // Pass through; SPA handles the request.
  }

  // Derive the OG `og:url` from the incoming request origin so staging
  // unfurls show `staging.session.homefit.studio/...` instead of the
  // prod host. Falls back to the full URL if origin can't be parsed.
  let originHost;
  try {
    originHost = new URL(request.url).origin;
  } catch (_) {
    originHost = 'https://session.homefit.studio';
  }

  // Practice public profile (`/v/{slug}`) — separate RPC, different OG copy.
  if (profileMatch) {
    const slug = profileMatch[1];
    try {
      const response = await fetch(
        `${SUPABASE_URL}/rest/v1/rpc/get_practice_profile`,
        {
          method: 'POST',
          headers: {
            'apikey': SUPABASE_ANON_KEY,
            'Authorization': `Bearer ${SUPABASE_ANON_KEY}`,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({ p_slug: slug }),
        },
      );
      if (!response.ok) return new Response('Not found', { status: 404 });
      const rows = await response.json();
      if (!Array.isArray(rows) || rows.length === 0) {
        return new Response('Not found', { status: 404 });
      }
      const row = rows[0];
      const title = row.practice_name || 'Practice';
      const premises = Array.isArray(row.premises) ? row.premises : [];
      const enforced = premises.filter((p) => p && p.safe_mode_enforced).length;
      const description = row.blurb
        || (premises.length > 0
              ? `${premises.length} ${premises.length === 1 ? 'premises' : 'premises'} · ${enforced} enforcing Safe Mode`
              : 'A practice profile on homefit.studio');
      const image = row.logo_url || '';
      const profileUrl = `${originHost}/v/${slug}`;
      const safeProfileUrl = escapeHtml(profileUrl);
      const html = `<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src 'self' https: data:;">
  <meta property="og:type" content="website">
  <meta property="og:title" content="${escapeHtml(title)} — homefit.studio">
  <meta property="og:description" content="${escapeHtml(description)}">
  <meta property="og:image" content="${escapeHtml(image)}">
  <meta property="og:url" content="${safeProfileUrl}">
  <meta property="og:site_name" content="homefit.studio">
  <meta name="twitter:card" content="summary">
  <meta name="twitter:title" content="${escapeHtml(title)} — homefit.studio">
  <meta name="twitter:description" content="${escapeHtml(description)}">
  <meta http-equiv="refresh" content="0;url=${safeProfileUrl}">
  <title>${escapeHtml(title)} — homefit.studio</title>
</head>
<body><p>Loading…</p></body>
</html>`;
      return new Response(html, {
        headers: { 'Content-Type': 'text/html; charset=utf-8' },
      });
    } catch (_) {
      return; // Pass through on error.
    }
  }

  const planId = (planMatch && planMatch[1]) || (handoutMatch && handoutMatch[1]);
  const isHandout = !planMatch && !!handoutMatch;

  try {
    // Anon-safe read via SECURITY DEFINER RPC (param name is p_plan_id,
    // NOT plan_id — renamed 2026-04-18 to resolve an ambiguous-column
    // error in the RPC body).
    const response = await fetch(
      `${SUPABASE_URL}/rest/v1/rpc/get_plan_full`,
      {
        method: 'POST',
        headers: {
          'apikey': SUPABASE_ANON_KEY,
          'Authorization': `Bearer ${SUPABASE_ANON_KEY}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ p_plan_id: planId }),
      },
    );

    if (!response.ok) {
      return new Response('Not found', { status: 404 });
    }

    const payload = await response.json();
    const plan = payload && payload.plan;
    if (!plan) {
      return new Response('Not found', { status: 404 });
    }

    const exercises = Array.isArray(payload.exercises) ? payload.exercises : [];
    // First non-rest exercise's thumbnail is the preferred card image.
    const firstVisible = exercises.find(
      (e) => e && e.media_type !== 'rest' && e.thumbnail_url,
    );

    const title = plan.title || plan.client_name || 'Your exercise plan';
    const exerciseCount = plan.exercise_count
      || exercises.filter((e) => e && e.media_type !== 'rest').length;
    // Handout copy differs from player copy — the handout is the
    // print-friendly hand-off ("save / print your plan"), the player is
    // the workout-along experience.
    const description = isHandout
      ? `${exerciseCount} exercise${exerciseCount !== 1 ? 's' : ''} · Printable Workout Guide`
      : `${exerciseCount} exercise${exerciseCount !== 1 ? 's' : ''} ready for you`;
    const thumbnail = firstVisible?.thumbnail_url || '';
    const planUrl = `${originHost}${isHandout ? '/h/' : '/p/'}${planId}`;

    // Return minimal HTML with OG tags + redirect.
    // Brand: always "homefit.studio" (lowercase, one word). The bot sees
    // this exact string in the unfurl card.
    const safePlanUrl = escapeHtml(planUrl);
    const html = `<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src 'self' https://*.supabase.co data:;">
  <meta property="og:type" content="website">
  <meta property="og:title" content="${escapeHtml(title)} — homefit.studio">
  <meta property="og:description" content="${escapeHtml(description)}">
  <meta property="og:image" content="${escapeHtml(thumbnail)}">
  <meta property="og:url" content="${safePlanUrl}">
  <meta property="og:site_name" content="homefit.studio">
  <meta name="twitter:card" content="summary_large_image">
  <meta name="twitter:title" content="${escapeHtml(title)} — homefit.studio">
  <meta name="twitter:description" content="${escapeHtml(description)}">
  <meta name="twitter:image" content="${escapeHtml(thumbnail)}">
  <meta http-equiv="refresh" content="0;url=${safePlanUrl}">
  <title>${escapeHtml(title)} — homefit.studio</title>
</head>
<body>
  <p>Loading your exercise plan...</p>
</body>
</html>`;

    return new Response(html, {
      headers: { 'Content-Type': 'text/html; charset=utf-8' },
    });
  } catch (error) {
    // On error, let the SPA handle it
    return;
  }
}

function escapeHtml(str) {
  if (str === null || str === undefined || str === '') return '';
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;')
    .replace(/\//g, '&#47;');
}

export const config = {
  matcher: ['/p/:path*', '/h/:planId*', '/v/:slug*'],
};
