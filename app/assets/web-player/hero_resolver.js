/**
 * homefit.studio — Hero Crop Resolver (web JS surface)
 * ====================================================
 *
 * Single module owning the "crop a portrait/landscape source JPG into a
 * 1:1 hero" operation. Pure: no DOM ops, no IO except the image load.
 *
 * WHY THIS EXISTS
 * ---------------
 * The crop is shared logic that used to be duplicated across every
 * consuming surface (Flutter Studio card / filmstrip / camera peek;
 * web player live lobby; web player PDF export). Five copies of
 * "given a portrait/landscape JPG + a stored offset, produce the 1:1
 * view" — every surface had to know the math, and the PDF surface
 * silently got it wrong because html2canvas ignores CSS `object-fit`
 * + `object-position`.
 *
 * This module replaces the live-lobby path (CSS `object-position` on
 * an `<img>` whose `object-fit: cover` does the crop at render time)
 * with a canvas-baked data URL whose intrinsic dimensions are already
 * 1:1. The PDF surface inherits the fix as a side effect: html2canvas
 * just rasterises the already-square image.
 *
 * The source JPG on disk stays portrait/landscape. The crop happens
 * at consumption time, per surface, against the in-memory exercise
 * row (which carries `aspect_ratio` + `hero_crop_offset`).
 *
 * SCOPE
 * -----
 * Web-only for this iteration. The Flutter consumers still build
 * `Alignment` math by hand against the same `hero_crop_offset` field;
 * a follow-up migration is filed in `docs/BACKLOG.md`. The brief
 * deliberately splits this work so the web-side fix (incl. the PDF
 * bug) ships independently of any Flutter refactor.
 *
 * Loaded via `<script src="hero_resolver.js">` BEFORE `lobby.js` so
 * `window.HomefitHeroResolver` is available when the lobby renders.
 *
 * USAGE
 * -----
 *   const dataUrl = await window.HomefitHeroResolver.getHeroSquareImage({
 *     exerciseId,
 *     treatment,         // 'line' | 'bw' | 'original'
 *     sourceUrl,
 *     heroCropOffset,    // 0.0..1.0 (default 0.5)
 *     targetSize,        // edge length in CSS pixels
 *   });
 *   // dataUrl is a square JPEG that html2canvas + <img> both render
 *   // exactly the same. No CSS object-position needed downstream.
 *
 * CACHE
 * -----
 * Results memoize in-module against the
 * (exerciseId|treatment|offset|targetSize) tuple. A typical plan has
 * 30-50 heroes; the cache size cap is generous enough to cover the
 * whole plan plus a treatment switch (line/bw/original) without
 * evictions. Treatment switch hits cache; page navigation hits cache;
 * scroll-driven re-render hits cache.
 *
 * No external dependencies. No inline scripts (CSP `script-src
 * 'self'`).
 */

(function () {
  'use strict';

  // ==========================================================================
  // Cache
  // ==========================================================================
  //
  // Map<cacheKey, Promise<string>> so concurrent requests for the
  // same hero coalesce on the first in-flight canvas op. The Promise
  // resolves to the JPEG data URL. We hold the Promise (not the
  // resolved string) because the second caller might land while the
  // first is still rasterising — both share the same eventual result.
  //
  // 200-entry soft cap: at the cache size where evictions start, the
  // session has rendered ~4 full plans' worth of heroes across all
  // three treatments. The eviction policy is LRU-ish but lazy: when
  // the cap is hit, we drop the oldest 25 entries in a single sweep
  // (cheaper than per-insert eviction).
  var CACHE_MAX = 200;
  var CACHE_EVICT_BATCH = 25;
  var _cache = new Map();

  function buildCacheKey(opts) {
    return [
      opts.exerciseId || '',
      opts.treatment || '',
      String(opts.heroCropOffset == null ? 0.5 : opts.heroCropOffset),
      String(opts.targetSize || 0),
    ].join('|');
  }

  function evictIfOver() {
    if (_cache.size <= CACHE_MAX) return;
    // Map preserves insertion order — the oldest keys are at the front.
    var i = 0;
    for (var k of _cache.keys()) {
      _cache.delete(k);
      if (++i >= CACHE_EVICT_BATCH) break;
    }
  }

  // ==========================================================================
  // Crop math
  // ==========================================================================
  //
  // The source image's natural dimensions determine the crop window.
  //
  //   - LANDSCAPE (w > h):  use full height, centred horizontally.
  //                          For now ignore heroCropOffset on landscape
  //                          (the legacy live-lobby CSS treated it as
  //                          a horizontal offset, but no consumer yet
  //                          exercises that — Flutter doesn't have a
  //                          horizontal scrubber, and Carl's principle
  //                          is "1 crop offset per source, vertical
  //                          for portrait, ignored for landscape").
  //                          See note inline below.
  //
  //   - PORTRAIT (h > w):    use full width, vertically positioned by
  //                          heroCropOffset where 0.0 = top-aligned,
  //                          1.0 = bottom-aligned, 0.5 = centred.
  //
  //   - SQUARE  (w == h):    no math, just draw.
  //
  // Returns { sx, sy, sw, sh } — the source-rect into the natural
  // image. The destination is always (0, 0, targetSize, targetSize).
  function computeCropRect(naturalW, naturalH, heroCropOffset) {
    var w = naturalW || 0;
    var h = naturalH || 0;
    if (w <= 0 || h <= 0) {
      // Pathological — the image somehow has no dimensions. Caller
      // surfaces the error via the existing img.onerror path.
      return { sx: 0, sy: 0, sw: 1, sh: 1 };
    }

    if (Math.abs(w - h) < 1) {
      // Square (within 1px tolerance).
      return { sx: 0, sy: 0, sw: w, sh: h };
    }

    if (w > h) {
      // Landscape. Centre the square horizontally; full height.
      // heroCropOffset is currently ignored on landscape sources —
      // see the head-of-function note. If this ever needs to honour
      // a horizontal offset, the math is symmetric to the portrait
      // branch below.
      var sxL = (w - h) / 2;
      return { sx: sxL, sy: 0, sw: h, sh: h };
    }

    // Portrait. Full width; the square slides vertically from 0
    // (top-aligned) to (h - w) (bottom-aligned).
    var clamped = heroCropOffset;
    if (clamped == null || !isFinite(clamped)) clamped = 0.5;
    if (clamped < 0) clamped = 0;
    if (clamped > 1) clamped = 1;
    var syP = clamped * (h - w);
    return { sx: 0, sy: syP, sw: w, sh: w };
  }

  // ==========================================================================
  // Image loader — returns a decoded HTMLImageElement
  // ==========================================================================
  //
  // Load via the <img> element rather than fetch+blob because:
  //   1. The lobby's source URLs (data: URLs after preloadAsDataUrls,
  //      or signed Supabase URLs on first paint) are already known-
  //      good <img> targets — the rest of the lobby renders them this
  //      way.
  //   2. crossOrigin: 'anonymous' is the same trust dance the rest of
  //      lobby.js does — same-origin reads + Supabase ACAO header.
  //   3. <img>.decode() guarantees the bitmap is in memory before we
  //      drawImage, so the canvas op never races a partially-decoded
  //      bitmap.
  //
  // No try/catch: real load failures should propagate so the caller
  // surfaces them via the existing error-handling path. Per
  // `feedback_no_exception_control_flow.md`.
  function loadImage(url) {
    return new Promise(function (resolve, reject) {
      var img = new Image();
      img.crossOrigin = 'anonymous';
      img.onload = function () {
        if (typeof img.decode === 'function') {
          img.decode().then(function () { resolve(img); }, function (e) { reject(e); });
        } else {
          resolve(img);
        }
      };
      img.onerror = function () {
        reject(new Error('hero_resolver: image load failed for ' + shortUrl(url)));
      };
      img.src = url;
    });
  }

  function shortUrl(u) {
    try {
      var url = new URL(u);
      var last = url.pathname.split('/').pop() || url.pathname;
      return last.length > 32 ? last.slice(0, 28) + '…' : last;
    } catch (_) {
      return String(u || '').slice(0, 32);
    }
  }

  // ==========================================================================
  // Canvas op — draw the source rect into a square target
  // ==========================================================================
  //
  // Honour devicePixelRatio internally so the rasterised JPEG is
  // crisp on retina. The CSS-pixel `targetSize` becomes the layout
  // dimension; the canvas backing store is targetSize * dpr.
  //
  // JPEG quality 0.92 mirrors the PDF rasteriser's choice (see
  // lobby.js PDF_PAGE_HEIGHT). PNG is rejected here: lossless on a
  // photo source is a 4x size hit for zero visible quality on the
  // small lobby thumbnail.
  function rasteriseToSquare(img, cropRect, targetSize) {
    var dpr = (typeof window !== 'undefined' && window.devicePixelRatio) || 1;
    var pxSize = Math.max(1, Math.round(targetSize * dpr));
    var canvas = document.createElement('canvas');
    canvas.width = pxSize;
    canvas.height = pxSize;
    var ctx = canvas.getContext('2d');
    if (!ctx) {
      throw new Error('hero_resolver: canvas 2d context unavailable');
    }
    ctx.drawImage(
      img,
      cropRect.sx, cropRect.sy, cropRect.sw, cropRect.sh,
      0, 0, pxSize, pxSize,
    );
    return canvas.toDataURL('image/jpeg', 0.92);
  }

  // ==========================================================================
  // Public API
  // ==========================================================================

  /**
   * Resolve a square (1:1) data URL for a hero image. The returned
   * Promise resolves to a JPEG data URL whose natural dimensions are
   * already targetSize × targetSize at devicePixelRatio. Callers
   * place it directly on `<img src>` — no CSS `object-fit` /
   * `object-position` needed.
   *
   * @param {object}  opts
   * @param {string}  opts.exerciseId       Cache key component. Use the wire `exercise.id`.
   * @param {string}  opts.treatment        Cache key component. 'line' | 'bw' | 'original'.
   * @param {string}  opts.sourceUrl        Per-treatment thumbnail JPG URL (signed Supabase URL or data: URL).
   * @param {number=} opts.heroCropOffset   0.0..1.0; default 0.5. Vertical centre for portrait sources; ignored for landscape.
   * @param {number}  opts.targetSize       Edge length in CSS pixels. The square canvas honours devicePixelRatio internally.
   *
   * @returns {Promise<string>} JPEG data URL of the square crop.
   */
  function getHeroSquareImage(opts) {
    var key = buildCacheKey(opts);
    var hit = _cache.get(key);
    if (hit) return hit;

    if (!opts || !opts.sourceUrl || !opts.targetSize) {
      // Bad call — fail loud so the regression is obvious. Per
      // `feedback_no_exception_control_flow.md` we don't paper over.
      return Promise.reject(new Error('hero_resolver: missing sourceUrl or targetSize'));
    }

    var task = loadImage(opts.sourceUrl).then(function (img) {
      var rect = computeCropRect(
        img.naturalWidth || img.width,
        img.naturalHeight || img.height,
        opts.heroCropOffset,
      );
      return rasteriseToSquare(img, rect, opts.targetSize);
    });

    _cache.set(key, task);
    evictIfOver();
    return task;
  }

  /**
   * Discard cached entries. Provided for test scripts and the
   * service-worker cache-bump path; production code does not call
   * this. No-arg form clears everything.
   */
  function clearCache() {
    _cache.clear();
  }

  /**
   * Diagnostic — exposes the current cache size + cap. Used by the
   * 2026-05-16 device-QA script's "cache works" test (item 7) so the
   * tester can verify treatment-switch round-trip hits the cache
   * instead of redoing the canvas op.
   */
  function inspect() {
    return { size: _cache.size, cap: CACHE_MAX };
  }

  // ==========================================================================
  // Expose
  // ==========================================================================

  window.HomefitHeroResolver = Object.freeze({
    getHeroSquareImage: getHeroSquareImage,
    clearCache: clearCache,
    inspect: inspect,
    // Exported for unit-test-style probes; not load-bearing.
    _computeCropRect: computeCropRect,
  });
})();
