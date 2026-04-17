const SUPABASE_URL = 'https://yrwcofhovrcydootivjx.supabase.co';
const SUPABASE_ANON_KEY = 'sb_publishable_cwhfavfji552BN8X0uPIpA_pwWQ-gw3';

export default async function middleware(request) {
  const url = new URL(request.url);
  const match = url.pathname.match(/^\/p\/([a-zA-Z0-9_-]+)/);
  if (!match) return; // Not a plan URL, pass through

  const ua = request.headers.get('user-agent') || '';
  const isBot = /WhatsApp|facebookexternalhit|Twitterbot|LinkedInBot|Slackbot|TelegramBot/i.test(ua);
  if (!isBot) return; // Normal browser, let SPA handle it

  const planId = match[1];

  try {
    // Fetch plan + first exercise thumbnail
    const response = await fetch(
      `${SUPABASE_URL}/rest/v1/plans?id=eq.${planId}&select=title,client_name,exercise_count,exercises(thumbnail_url,name,position)&exercises.order=position.asc&exercises.limit=1`,
      {
        headers: {
          'apikey': SUPABASE_ANON_KEY,
          'Authorization': `Bearer ${SUPABASE_ANON_KEY}`,
        }
      }
    );

    if (!response.ok) {
      return new Response('Not found', { status: 404 });
    }

    const plans = await response.json();
    if (!plans.length) {
      return new Response('Not found', { status: 404 });
    }

    const plan = plans[0];
    const title = plan.title || plan.client_name || 'Your Exercise Plan';
    const exerciseCount = plan.exercise_count || 0;
    const description = `${exerciseCount} exercise${exerciseCount !== 1 ? 's' : ''} ready for you`;
    const thumbnail = plan.exercises?.[0]?.thumbnail_url || '';
    const planUrl = `https://session.homefit.studio/p/${planId}`;

    // Return minimal HTML with OG tags + redirect
    const safePlanUrl = escapeHtml(planUrl);
    const html = `<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src 'self' https://*.supabase.co data:;">
  <meta property="og:type" content="website">
  <meta property="og:title" content="${escapeHtml(title)} — HomeFit">
  <meta property="og:description" content="${escapeHtml(description)}">
  <meta property="og:image" content="${escapeHtml(thumbnail)}">
  <meta property="og:url" content="${safePlanUrl}">
  <meta property="og:site_name" content="HomeFit Studio">
  <meta name="twitter:card" content="summary_large_image">
  <meta name="twitter:title" content="${escapeHtml(title)} — HomeFit">
  <meta name="twitter:description" content="${escapeHtml(description)}">
  <meta name="twitter:image" content="${escapeHtml(thumbnail)}">
  <meta http-equiv="refresh" content="0;url=${safePlanUrl}">
  <title>${escapeHtml(title)} — HomeFit</title>
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
