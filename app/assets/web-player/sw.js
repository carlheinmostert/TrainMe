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
// Fetch: network-first for app shell + API; cache-first for media
// ============================================================
//
// 2026-05-16 — switched app shell (HTML / JS / CSS / config) from
// cache-first to network-first. Previous behaviour meant new deploys
// did not propagate to clients with an active SW until they fully
// closed every tab and started fresh — even Safari Private Browsing
// inherited the cached bytes. Production-broken: a fix shipped to
// staging stayed invisible to Carl's iPhone for the session's
// lifetime regardless of reload count.
//
// New shape:
//   * Supabase API → network-first (unchanged).
//   * Media files (mp4 / jpg / png from /storage/v1/object/public/media/)
//     → cache-first (unchanged — content-addressable URLs, immutable).
//   * Everything else (app shell + lobby.js + any future asset) →
//     network-first with cache fallback for offline.
//
// Cost: ~50-200ms added to first-paint per asset on cold reload when
// online (the network roundtrip previously skipped). Acceptable vs.
// the alternative of clients stuck on stale code indefinitely.
// Offline still works because the network-first strategy caches on
// success and falls back to cache on network failure.

self.addEventListener('fetch', (event) => {
  const { request } = event;
  const url = new URL(request.url);

  // Skip non-GET requests
  if (request.method !== 'GET') return;

  // Supabase API — network-first, cache only public media on success.
  if (url.hostname.includes('supabase.co')) {
    event.respondWith(networkFirstStrategy(request));
    return;
  }

  // Thumbnail variants (`_thumb.jpg`, `_thumb_line.jpg`,
  // `_thumb_color.jpg`, `_thumb_bw.jpg`) are NOT immutable — they get
  // re-uploaded on every Hero-star drag / hero-crop drag / republish
  // via PR #376's `thumbnailsDirty` flag. Cache-first would serve the
  // first-publish bytes indefinitely, masking every subsequent hero
  // change. Network-first + `cache: 'reload'` bypasses both the SW
  // cache AND the browser HTTP cache (Supabase Storage sends
  // `cache-control: public, max-age=3600` so a plain network-first
  // fetch would still serve a stale browser-cached copy for an hour
  // after a Hero change). Cache fallback keeps the lobby readable
  // offline.
  if (isMutableThumbRequest(request)) {
    event.respondWith(networkRevalidateStrategy(request));
    return;
  }

  // Media assets — cache-first (immutable content-addressable URLs).
  if (isMediaRequest(request)) {
    event.respondWith(cacheFirstStrategy(request));
    return;
  }

  // App shell + everything else — NETWORK-FIRST so new deploys
  // propagate on next reload instead of after a full tab-close cycle.
  event.respondWith(networkFirstAppShellStrategy(request));
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

async function networkFirstAppShellStrategy(request) {
  const cache = await caches.open(CACHE_NAME);
  try {
    const response = await fetch(request);
    if (response.ok) {
      // Cache successful responses so the app still works offline.
      // Both the old SW (cacheFirst) and this one cache app shell on
      // success — the difference is the read order: we now check the
      // network first, only falling back to cache on a network failure.
      cache.put(request, response.clone());
    }
    return response;
  } catch (err) {
    // Offline path — fall back to the cached copy if any.
    const cached = await cache.match(request);
    if (cached) return cached;
    // For navigation requests with no cache, fall back to the cached
    // index.html so the SPA shell can still mount; the app's own
    // offline UI (no-connection screen) handles the user message.
    if (request.mode === 'navigate') {
      const fallback = await cache.match('/index.html');
      if (fallback) return fallback;
    }
    throw err;
  }
}

// Like `networkFirstAppShellStrategy`, but forces `cache: 'reload'` on
// the network fetch so the browser's HTTP cache (which honours
// Supabase Storage's `cache-control: public, max-age=3600` for an
// hour) is bypassed. Used for mutable thumb URLs whose path stays the
// same across regenerations — see PR #383's discovery that a plain
// network-first still served stale browser-cached bytes for an hour
// after a Hero-star drag + republish.
async function networkRevalidateStrategy(request) {
  const cache = await caches.open(CACHE_NAME);
  try {
    // Build a new Request with `cache: 'reload'` because Request
    // objects' cache mode is read-only once constructed. Carry the
    // URL + headers; method is GET (filtered upstream).
    const reloadRequest = new Request(request.url, {
      method: 'GET',
      headers: request.headers,
      cache: 'reload',
      credentials: request.credentials,
      redirect: request.redirect,
    });
    const response = await fetch(reloadRequest);
    if (response.ok) {
      cache.put(request, response.clone());
    }
    return response;
  } catch (err) {
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

// Per-exercise thumbnail variants get re-uploaded whenever the
// practitioner moves the Hero star, drags the hero crop offset, or
// otherwise triggers `ConversionService.regenerateHeroThumbnails`
// (PR #376 `thumbnailsDirty` flow). The URL stays the same so a
// cache-first strategy would pin the lobby on the first-publish
// bytes forever — Carl hit this on 2026-05-17 device QA, the cloud
// `_thumb.jpg` updated correctly but Safari kept serving the
// pre-Hero-move frame.
//
// File names are stable: `{id}_thumb.jpg`, `{id}_thumb_line.jpg`,
// `{id}_thumb_color.jpg`, `{id}_thumb_bw.jpg`. Match any path ending
// in `_thumb.jpg`, `_thumb_<variant>.jpg`. Underscored prefix prevents
// false-matches on legitimately-immutable JPGs.
function isMutableThumbRequest(request) {
  const url = new URL(request.url);
  return /_thumb(_[a-z]+)?\.jpg$/i.test(url.pathname);
}
