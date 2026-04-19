const SUPABASE_URL = 'https://yrwcofhovrcydootivjx.supabase.co';
const SUPABASE_ANON_KEY = 'sb_publishable_cwhfavfji552BN8X0uPIpA_pwWQ-gw3';

// Vercel Edge Middleware that serves bot-friendly HTML with OG meta tags
// for WhatsApp / iMessage / Slack / Twitter etc. link previews.
//
// IMPORTANT: reads go through the `get_plan_full(p_plan_id)` SECURITY
// DEFINER RPC — NOT direct PostgREST SELECTs on `plans` / `exercises`.
// Milestone C locked anon SELECT on those tables; direct reads return
// empty, which silently broke every WhatsApp preview since the lockdown
// landed. Same contract used by `web-player/api.js`.

export default async function middleware(request) {
  const url = new URL(request.url);
  const match = url.pathname.match(/^\/p\/([a-zA-Z0-9_-]+)/);
  if (!match) return; // Not a plan URL, pass through

  const ua = request.headers.get('user-agent') || '';
  const isBot = /WhatsApp|facebookexternalhit|Twitterbot|LinkedInBot|Slackbot|TelegramBot/i.test(ua);
  if (!isBot) return; // Normal browser, let SPA handle it

  const planId = match[1];

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
    const description = `${exerciseCount} exercise${exerciseCount !== 1 ? 's' : ''} ready for you`;
    const thumbnail = firstVisible?.thumbnail_url || '';
    const planUrl = `https://session.homefit.studio/p/${planId}`;

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
  matcher: '/p/:path*',
};
