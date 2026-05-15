/**
 * TrainMe Web Player — Service Worker
 *
 * Caches the app shell and plan assets on first visit so the plan
 * works offline at the gym without mobile signal.
 */

// CACHE_NAME is auto-rewritten on every Vercel build by web-player/build.sh.
// The placeholder suffix on the next line is replaced with the 7-char git
// SHA of the deploy (e.g. 'homefit-player-a4bdc1c'). Bumping the cache name
// on every deploy is what forces the SW to re-fetch the app shell — without
// it, browsers happily serve stale HTML / headers / CSP from the cache
// long after a fix has shipped (two real outages on 2026-05-12 traced back
// here). See build.sh for the rewrite step.
//
// 2026-05-15 — bumped for PNG-modal dead-code removal (lobby.js / index.html /
// styles.css / app.js). PNG export was superseded by the PDF pipeline on
// 2026-05-14; stale CSS / HTML for the old modal needs to flush from cached
// clients. See chore/web-player-remove-png-modal.
//
// 2026-05-15 (later) — bumped again for the SEVENTH-attempt circuit-animation
// fix: hero <img> loading="lazy" → "eager" + drop await chain in
// renderCircuitLanesFor + add MutationObserver. PR #337 (6th attempt) was
// inert because lazy images outside viewport never fired `load`, hanging
// the await forever. See fix/circuit-geometry-attempt-7.
//
// 2026-05-15 (even later) — bumped for the SECOND-attempt lobby PDF aspect-
// ratio fix. PR #344 (first attempt) was based on a wrong-physics diagnosis
// and changed nothing observable. Real issue: export inner content box was
// 738px (794px outer - 56px padding) vs live lobby content box of 688px
// (720px max-width - 32px padding) → same content filled 1.073x more
// horizontal space, reading as horizontal stretch. Fix sets
// .lobby-export-page-inner max-width: 688px + margin: 0 auto so the export
// content lays out identically to the live lobby. See
// fix/pdf-aspect-content-width-match.
//
// 2026-05-15 (lobby gear popover landscape fix) — bumped for the cascade
// fix: dropped the shared `settings-popover` class from the lobby
// popover element + switched JS positioning to setProperty('important').
// PR #343 was inert in landscape because the deck's landscape media
// query (styles.css line 2401) re-asserted `position:absolute;
// top:134px; right:8px` whenever JS cleared inline styles on close,
// putting the popover below the gear and offscreen.
// See fix/gear-popover-drop-shared-class.
//
// 2026-05-15 (lobby hero thumbnails legacy soft-fallback) — bumped for
// pickPosterSrc soft-fallback in exercise_hero.js. PR #348's default-
// treatment swap (NULL → B&W) made legacy plans (pre-PR-#319 photo
// variant pipeline) render empty grey thumbnails: the iOS scheme bridge
// unconditionally emits `thumbnail_url_color`, but `_thumb_color.jpg`
// doesn't exist on disk for those plans → WKWebView gets
// fileDoesNotExist. Defence-in-depth: fall back to canonical
// `thumbnail_url` when the specific variant is missing; CSS .is-grayscale
// filter still applies. See fix/lobby-thumbnails-legacy-soft-fallback.
//
// 2026-05-15 (NINTH-attempt circuit fix) — bumped for the MutationObserver
// feedback-loop fix. PR #353 (eighth attempt) wired an observer on the
// circuit frame that watched childList+subtree changes to catch genuine
// row swaps. The observer also fired on our own SVG mutations inside
// paintLanesAndTracer (clear children, append paths) → queued another
// rAF → re-painted → fired observer → infinite loop. Main thread pegged
// → preview goes black on circuit plans, share button non-responsive,
// lobby thumbnails starved. Fix disconnects the observer at the top of
// paintLanesAndTracer and reconnects in a finally so genuine row
// changes still get caught afterwards.
// See fix/circuit-attempt-9-observer-disconnect-during-paint.
//
// 2026-05-15 (TENTH-attempt — nested CSS boxes) — bumped for the wholesale
// architecture replacement. The SVG-tracer + ResizeObserver +
// MutationObserver + getTotalLength architecture is gone; circuit chrome
// is now N visually-nested <div> rings emitted by lobby.js's
// circuitGroupHTML(), animated by a single CSS keyframe (`lobby-circuit-
// pulse`) staggered via `--box-index` custom property. No JS animation,
// no measurement, no observers, no rAF chain. This class of bugs cannot
// regress without explicitly removing the CSS. Bumps the cache so
// Safari clients flush the obsolete SVG-tracer code paths.
// See fix/circuit-animation-attempt-10-nested-boxes and
// docs/design/mockups/circuit-nested-boxes.html (variant 1).
const CACHE_NAME = 'homefit-player-__BUILD_SHA__';

// App shell files — always cached
const APP_SHELL = [
  '/',
  '/index.html',
  '/styles.css',
  '/config.js',
  '/app.js',
  '/api.js',
  '/lobby.js',
];

// ============================================================
// Install: pre-cache app shell
// ============================================================

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then((cache) => cache.addAll(APP_SHELL))
      .then(() => self.skipWaiting())
  );
});

// ============================================================
// Activate: clean up old caches
// ============================================================

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(
        keys
          .filter((key) => key !== CACHE_NAME)
          .map((key) => caches.delete(key))
      ))
      .then(() => self.clients.claim())
  );
});

// ============================================================
// Fetch: network-first for API, cache-first for static assets
// ============================================================

self.addEventListener('fetch', (event) => {
  const { request } = event;
  const url = new URL(request.url);

  // Skip non-GET requests
  if (request.method !== 'GET') return;

  // TODO_SUPABASE: Match your Supabase API domain here
  // API requests: network-first, cache response for offline
  if (url.hostname.includes('supabase.co')) {
    event.respondWith(networkFirstStrategy(request));
    return;
  }

  // Media assets (images, videos from Supabase storage): cache on fetch
  if (isMediaRequest(request)) {
    event.respondWith(cacheFirstStrategy(request));
    return;
  }

  // App shell and other static assets: cache-first
  event.respondWith(cacheFirstStrategy(request));
});

// ============================================================
// Caching strategies
// ============================================================

async function networkFirstStrategy(request) {
  const cache = await caches.open(CACHE_NAME);
  const url = new URL(request.url);

  try {
    const response = await fetch(request);
    // SECURITY: Never cache Supabase REST API responses — they contain PII
    // (client names, notes, plan data) that would persist indefinitely on any
    // device that ever loaded a plan. Only cache public media assets.
    const isRestApi = url.pathname.startsWith('/rest/')
      && url.pathname.includes('/v1/');
    const isPublicMedia = url.pathname.includes('/storage/v1/object/public/media/');

    if (response.ok && !isRestApi && isPublicMedia) {
      const contentType = response.headers.get('content-type') || '';
      if (contentType.startsWith('image/') || contentType.startsWith('video/')) {
        cache.put(request, response.clone());
      }
    }
    return response;
  } catch (err) {
    // Network failed, try cache (only media would be there now)
    const cached = await cache.match(request);
    if (cached) return cached;
    throw err;
  }
}

async function cacheFirstStrategy(request) {
  const cached = await caches.match(request);
  if (cached) return cached;

  try {
    const response = await fetch(request);
    if (response.ok) {
      const cache = await caches.open(CACHE_NAME);
      const url = new URL(request.url);
      const isMediaPath = isMediaRequest(request) ||
        url.pathname.includes('/storage/v1/object/public/media/');

      if (isMediaPath) {
        // Validate content-type for media to prevent bucket abuse where a
        // tampered object might be served as something unexpected.
        const contentType = response.headers.get('content-type') || '';
        if (contentType.startsWith('image/') || contentType.startsWith('video/')) {
          cache.put(request, response.clone());
        }
      } else {
        // App shell assets — always safe to cache.
        cache.put(request, response.clone());
      }
    }
    return response;
  } catch (err) {
    // For navigation requests, fall back to cached index.html
    if (request.mode === 'navigate') {
      const fallback = await caches.match('/index.html');
      if (fallback) return fallback;
    }
    throw err;
  }
}

// ============================================================
// Helpers
// ============================================================

function isMediaRequest(request) {
  const url = new URL(request.url);
  const ext = url.pathname.split('.').pop().toLowerCase();
  return ['jpg', 'jpeg', 'png', 'webp', 'gif', 'mp4', 'mov', 'webm'].includes(ext);
}
