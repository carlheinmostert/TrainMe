/**
 * homefit.studio web-player — Service Worker
 *
 * Purpose (2026-05-25 rewrite):
 *   The SW exists for ONE reason — clients doing workouts in gyms with
 *   bad signal need the lobby (`/p/{planId}`) and player to keep working
 *   when the network drops. Everything else in this file is structured
 *   to make the SW invisible by default so it can never serve a stale
 *   bundle on any other surface.
 *
 * Behavioural contract (2026-05-25):
 *
 *   1. The live transparency page (`/v/{practice}/{premises}/now`) is
 *      bypassed entirely. The fetch handler returns immediately for any
 *      request whose pathname starts with `/v/`, letting the browser
 *      hit the network. Live page polls every 12s, depends on Esri
 *      tiles + Supabase + Leaflet from unpkg — the literal opposite of
 *      an offline use case. live.html / live.js do not register a SW
 *      either, but a SW registered by a prior `/p/{id}` visit on the
 *      same origin has scope `/` and would otherwise intercept these
 *      requests. The bypass keeps that pre-existing SW out of the way.
 *
 *   2. HTML and JS / CSS / shell assets are network-first across the
 *      board. The SW tries `fetch(request)` first and only falls back
 *      to the cache on actual network failure. The cache is still
 *      populated on every successful response so the offline gym use
 *      case keeps working. Mutable thumbnails get a `cache: 'reload'`
 *      bypass so the browser HTTP cache doesn't pin a stale Hero frame
 *      for the hour Supabase Storage's max-age allows.
 *
 *   3. Media files (mp4 / jpg / png from `/storage/v1/object/public/`)
 *      are cache-first — those URLs are content-addressable + immutable
 *      so cache-first saves a network round-trip with no staleness
 *      risk.
 *
 *   4. A new SW takes control IMMEDIATELY:
 *        - install handler calls `self.skipWaiting()` so a newly
 *          installed SW does not sit behind the old controller.
 *        - activate handler calls `self.clients.claim()` so the new
 *          SW takes over already-open tabs on the very next event.
 *      Each web-player surface (app.js / lobby.js / live.js) listens
 *      for `navigator.serviceWorker.controller` change events and
 *      reloads the tab so the user sees the new bundle without a
 *      manual refresh. app.js guards the reload while a workout is
 *      mid-rep — see registerServiceWorker() there.
 *
 * What this rewrite makes obsolete:
 *
 *   Before today this comment block was the bandaid for Safari's lazy
 *   SW update poll — every PR touching `web-player/` had to append a
 *   "manual bump" entry to force Safari to re-fetch sw.js on next
 *   page interaction (memory rule `feedback_always_bump_sw_on_player_change.md`).
 *   With network-first + bypass + auto-claim + auto-reload, that rule
 *   is now redundant. The `__BUILD_SHA__` cache-name rewrite in
 *   `web-player/build.sh` still guarantees each deploy gets a unique
 *   cache — that mechanism is load-bearing and untouched.
 *
 * Historical bump trail (kept for archaeology, NOT for new entries —
 * the rule above retires the manual-bump ritual):
 *
 *   2026-05-25 — PR #7 (plan_artifacts): web-player/api.js + app.js
 *                surface payload.artifacts (no behaviour change today,
 *                forward-prep for ADR-0022 Reel artifact).
 *   2026-05-24 — feat(live): "View practice profile" link in
 *                practitioner popover on live page.
 *   2026-05-24 — fix(live): fit-to-polygon button CSS specificity.
 *   2026-05-23 — live-view UX bundle (viewer "You" pill, fit-to-polygon
 *                control, fitBounds padding tuning).
 *   2026-05-23 — per-capture audit + 24h roster on live page.
 *   2026-05-23 — live-view zoom + avatar-only pass.
 *   2026-05-23 — eager SW update check on register + visibilitychange.
 *   2026-05-23 — Mapbox snapshot replaced by Leaflet + Esri rewire.
 *   2026-05-15 — PNG-modal dead code removal.
 *   2026-05-15 — circuit animation attempts 7 / 9 / 10 (nested boxes).
 *   2026-05-15 — lobby PDF aspect ratio fix.
 *   2026-05-15 — gear popover landscape fix.
 *   2026-05-15 — lobby hero thumbnail legacy soft-fallback.
 *
 * From 2026-05-25 onwards, deploys do not append entries to this list;
 * the `__BUILD_SHA__` rewrite + auto-claim + auto-reload flush stale
 * bundles automatically.
 */

// CACHE_NAME is auto-rewritten on every Vercel build by web-player/build.sh.
// The sentinel `__BUILD_SHA__` on the next line is replaced with the 7-char
// git SHA of the deploy (e.g. 'homefit-player-a4bdc1c'). Each deploy gets a
// unique cache name so the SW activate step naturally evicts the previous
// bundle. See build.sh for the rewrite mechanism — do not edit the literal.
const CACHE_NAME = 'homefit-player-__BUILD_SHA__';

// App shell files — always cached on first install so the player works
// offline at the gym even on a cold visit.
const APP_SHELL = [
  '/',
  '/index.html',
  '/styles.css',
  '/config.js',
  '/app.js',
  '/api.js',
  '/lobby.js',
  '/v.html',
  '/v.js',
  // Workout handout (artifact-system Wave 1 / ADR 0025).
  '/handout.html',
  '/handout.css',
  '/handout.js',
  // Shared modules used by BOTH the interactive lobby and the Printable
  // Workout Guide (artifact-consistency wave, 2026-05-28). Precached so
  // the offline app shell can render either surface without the network.
  '/exercise_hero.js',
  '/hero_resolver.js',
  '/homefit_logo.js',
  '/dose_format.js',
  '/qrcode.js',
];

// ============================================================
// Install: pre-cache app shell, take over immediately
// ============================================================

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then((cache) => cache.addAll(APP_SHELL))
      // skipWaiting promotes this SW from "installed" to "active" as
      // soon as the old SW finishes its current event loop tick — no
      // waiting on every tab to close. Paired with clients.claim()
      // below so already-open tabs see the new controller too.
      .then(() => self.skipWaiting())
  );
});

// ============================================================
// Activate: claim open tabs, drop old caches
// ============================================================

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(
        keys
          .filter((key) => key !== CACHE_NAME)
          .map((key) => caches.delete(key))
      ))
      // clients.claim() makes this SW the controller of every page in
      // its scope that's already open. Combined with skipWaiting() in
      // install, a new deploy reaches every open tab on the next
      // event tick without a manual reload. The page-side
      // `controllerchange` listener (app.js / lobby.js / live.js) then
      // triggers the actual reload so the new bundle is in memory.
      .then(() => self.clients.claim())
  );
});

// ============================================================
// Fetch: live page bypass, network-first HTML, cache-first media
// ============================================================

self.addEventListener('fetch', (event) => {
  const { request } = event;
  const url = new URL(request.url);

  // Skip non-GET requests — POSTs / PATCHes etc. are never cacheable.
  if (request.method !== 'GET') return;

  // ----------------------------------------------------------------
  // LIVE PAGE BYPASS — the transparency page must never go through
  // the SW. It depends on real-time polling + third-party tiles and
  // has no offline use case. By returning here without calling
  // event.respondWith(), the browser does its default fetch and the
  // SW is invisible for any URL under `/v/*` even though our scope
  // is `/`. This includes the live.html document itself, live.js,
  // Leaflet from unpkg (different origin so it'd be passthrough
  // anyway), and any Supabase poll. See feedback in this file's
  // header about why this design ships.
  // ----------------------------------------------------------------
  if (url.pathname.startsWith('/v/')) {
    return;
  }

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

  // App shell + HTML + everything else — NETWORK-FIRST so new
  // deploys propagate on the next reload instead of after a full
  // tab-close cycle. Falls back to the cache on a real network
  // failure so the offline gym case keeps working.
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
      // Network-first read order means a deploy reaches the client on
      // the next reload — the cache is the offline fallback, not the
      // first stop.
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
