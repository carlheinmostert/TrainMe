/**
 * TrainMe Web Player — Service Worker
 *
 * Caches the app shell and plan assets on first visit so the plan
 * works offline at the gym without mobile signal.
 */

const CACHE_NAME = 'homefit-player-v3-dark';

// App shell files — always cached
const APP_SHELL = [
  '/',
  '/index.html',
  '/styles.css',
  '/app.js',
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

  try {
    const response = await fetch(request);
    // Cache successful responses
    if (response.ok) {
      cache.put(request, response.clone());
    }
    return response;
  } catch (err) {
    // Network failed, try cache
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
      cache.put(request, response.clone());
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
