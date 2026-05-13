/**
 * homefit.studio — Exercise Hero Resolver (web JS surface)
 * =========================================================
 *
 * Single stateless function that decides how to render an exercise's
 * hero/poster on any of the four web surfaces (lobby strip, active deck
 * slide, prep-phase countdown, share-as-PNG snapshot). Pure: no DOM ops,
 * no IO, no module-level state. The caller passes in the exercise row
 * (as it arrives from `get_plan_full` or the embedded scheme bridge) plus
 * its EFFECTIVE treatment + body-focus + which surface is asking, and
 * gets back a typed record describing what to render.
 *
 * Why this exists: pre-resolver each surface independently re-derived
 * treatment + body-focus + photo-vs-video file selection without sharing
 * any contract. See `docs/audits/photo-video-treatment-audit-2026-05-13.md`
 * for the full divergence map and B6/D13 root-causes.
 *
 * Loaded via `<script src="exercise_hero.js">` BEFORE `app.js` and
 * `lobby.js` so the resolver is available to all callers. Exposed as
 * `window.HomefitHero.resolve(exercise, opts)`.
 *
 * Surfaces:
 *   - 'lobby'    — pre-workout row strip (lobby.js renderHeroHTML).
 *                  Caller renders <img> for inactive rows; the active
 *                  row swaps to <video> via swapToVideoOnActiveRow.
 *   - 'deck'     — active slide playback (app.js buildMedia). Caller
 *                  renders .video-loop-pair (two <video>) for videos,
 *                  rotation-wrapped <img> for photos.
 *   - 'prep'     — prep-phase countdown hero (app.js buildPrepOverlay).
 *                  Caller renders a static <img class="hero-poster">.
 *   - 'snapshot' — share-as-PNG poster pass (lobby.js triggerLobbyShare).
 *                  Caller pre-fetches `posterSrc` as a data URL for
 *                  html2canvas rasterisation. Critical: `<video poster>`
 *                  does NOT inherit CSS filters during rasterisation —
 *                  see `bakeFilterIntoDataUrl` below for the workaround.
 *
 * Photo vs video branching: photos always emit `mediaTag: 'img'`; videos
 * emit `mediaTag: 'video'` (deck) or `mediaTag: 'img'` with `videoSrc`
 * for lobby/snapshot (the caller decides whether to swap to <video>).
 * `mediaTag: 'skeleton'` is returned when the slide has neither a usable
 * src nor a poster (rest periods, or exercises with no media yet).
 *
 * Fallback chains for missing variants are spelled out in the body —
 * see `pickPosterSrc` and `pickPrimarySrc`. The web player's existing
 * `signed URL 403 → reFetchPlan → re-resolve` machinery (web-player/
 * app.js:445 + lobby.js:1242) keeps working unchanged because the
 * resolver is idempotent on its inputs.
 */

(function () {
  'use strict';

  // ==========================================================================
  // Treatment poster URL fallback chain
  // ==========================================================================
  //
  // The wire shape diverges between the public web player and the
  // embedded WKWebView preview:
  //
  //   - Public: `get_plan_full` returns ONE thumbnail field per exercise
  //     (`thumbnail_url`). For videos that's the B&W _thumb.jpg variant
  //     extracted on-device during conversion; for photos it's the raw
  //     colour JPG.
  //
  //   - Embedded: the scheme bridge emits THREE fields per exercise
  //     (`thumbnail_url`, `thumbnail_url_line`, `thumbnail_url_color`)
  //     which resolve to /local/{id}/hero, /local/{id}/hero_line, and
  //     /local/{id}/hero_color respectively. The native handler picks
  //     the right variant on disk.
  //
  // The fallback chain is:
  //   Line     → `thumbnail_url_line` → legacy `thumbnail_url`
  //   Original → `thumbnail_url_color` → legacy `thumbnail_url`
  //   B&W      → `thumbnail_url_color` → legacy `thumbnail_url`
  //              (caller applies `.is-grayscale` CSS filter)
  //
  // Until Bundle 2's PR 6 ships the photo variant pipeline + uploads
  // `_thumb_color.jpg` + `_thumb_line.jpg` for the public surface,
  // public Line + Original posters fall back to the legacy field —
  // which IS the line drawing for photos but B&W for videos. Embedded
  // surface gets the right variant immediately since the bridge already
  // emits all three URL fields.
  function pickPosterSrc(exercise, treatment) {
    if (!exercise) return null;
    var legacy = exercise.thumbnail_url || null;
    if (treatment === 'line') {
      return exercise.thumbnail_url_line || legacy;
    }
    // bw + original both want the color JPG; CSS `.is-grayscale`
    // applies the filter for B&W playback.
    return exercise.thumbnail_url_color || legacy;
  }

  // ==========================================================================
  // Primary (playback) URL fallback chain
  // ==========================================================================
  //
  // Mirrors `resolveTreatmentUrl` in app.js. Kept here as a single
  // source of truth so callers don't end up forking the fallback
  // semantics.
  //
  // Body-focus ON  → segmented variant preferred (raw bg dimmed, body
  //                   pristine). Falls back to untouched original.
  // Body-focus OFF → untouched original preferred. Falls back to
  //                   segmented (so the slide can still play if the
  //                   raw variant is missing).
  //
  // 'line' is unaffected by body-focus — line drawing IS its own
  // pipeline, not a dual-output variant.
  function pickPrimarySrc(exercise, treatment, bodyFocus) {
    if (!exercise) return null;
    if (treatment === 'bw') {
      if (bodyFocus) {
        return exercise.grayscale_segmented_url || exercise.grayscale_url || null;
      }
      return exercise.grayscale_url || exercise.grayscale_segmented_url || null;
    }
    if (treatment === 'original') {
      if (bodyFocus) {
        return exercise.original_segmented_url || exercise.original_url || null;
      }
      return exercise.original_url || exercise.original_segmented_url || null;
    }
    // 'line' + unknown treatments → line drawing (the always-available default).
    return exercise.line_drawing_url || exercise.media_url || null;
  }

  // ==========================================================================
  // Caps — what surfaces should advertise as available for THIS exercise
  // ==========================================================================
  //
  // `hasBodyFocus`     — videos only. Photos have no segmented variant
  //                      pipeline today (see audit F21) so the toggle is
  //                      a no-op. Callers should disable the body-focus
  //                      pill with the existing tooltip when this is
  //                      false.
  //
  // `availableTreatments` — the treatments the slide can actually play.
  //                         Falls back to ['line'] when neither
  //                         grayscale nor original have URLs (consent
  //                         withheld, or signed-URL expiry).
  //
  // `treatmentLockedTo`   — set to 'line' when the requested treatment
  //                          has no URL. Caller can short-circuit to
  //                          Line rendering and disable the picker
  //                          segment for the locked treatment.
  function computeCaps(exercise, treatment) {
    var availableTreatments = ['line'];
    var hasGray = !!(exercise && (exercise.grayscale_segmented_url || exercise.grayscale_url));
    var hasOrig = !!(exercise && (exercise.original_segmented_url || exercise.original_url));
    if (hasGray) availableTreatments.push('bw');
    if (hasOrig) availableTreatments.push('original');

    var lockedTo = null;
    if (treatment === 'bw' && !hasGray) lockedTo = 'line';
    if (treatment === 'original' && !hasOrig) lockedTo = 'line';

    var hasBodyFocus = !!(exercise && exercise.media_type === 'video');

    return {
      hasBodyFocus: hasBodyFocus,
      availableTreatments: availableTreatments,
      treatmentLockedTo: lockedTo,
    };
  }

  // ==========================================================================
  // Main resolver
  // ==========================================================================

  /**
   * Resolve the hero/poster shape for a single exercise on a single surface.
   *
   * @param {object} exercise - slide row from get_plan_full / embedded bridge.
   *   Required fields (any may be null):
   *     - media_type:                'photo' | 'video' | 'image' | 'rest'
   *     - line_drawing_url, media_url
   *     - grayscale_url, grayscale_segmented_url
   *     - original_url, original_segmented_url
   *     - thumbnail_url, thumbnail_url_line, thumbnail_url_color
   *     - start_offset_ms, end_offset_ms     (soft trim window)
   *
   * @param {object} opts
   * @param {'line'|'bw'|'original'} opts.treatment - effective treatment for THIS exercise.
   * @param {boolean} opts.bodyFocus               - effective body-focus for THIS exercise.
   * @param {'lobby'|'deck'|'prep'|'snapshot'} opts.surface
   *
   * @returns {{
   *   mediaTag: 'img'|'video'|'skeleton',
   *   src: string|null,
   *   posterSrc: string|null,
   *   videoSrc: string|null,
   *   domClass: string,
   *   filterCss: string|null,
   *   caps: { hasBodyFocus: boolean, availableTreatments: string[], treatmentLockedTo: string|null }
   * }}
   *
   * Field semantics:
   *   - `mediaTag`   — what the caller should emit:
   *                      'img'      = static image (photos always, video
   *                                    lobby/prep/snapshot inactive rows)
   *                      'video'    = playing video (deck active slide,
   *                                    lobby active row post-swap)
   *                      'skeleton' = rest period or no media yet
   *   - `src`        — the URL to put on `<img src>` or `<video src>` for
   *                    the active-treatment playback frame. Same as
   *                    `videoSrc` for videos; same as `posterSrc` for
   *                    photos in `bw`/`original` (single JPG + CSS filter).
   *   - `posterSrc`  — the URL to use as `<video poster>` (when caller
   *                    emits a <video>) or as the inactive-row `<img src>`
   *                    (lobby). Treatment-correct: matches the active
   *                    treatment unless the variant is unavailable.
   *   - `videoSrc`   — for videos, the actual mp4 URL. NEVER use this as
   *                    `<img src>` — iOS WKWebView lenient-renders mp4 in
   *                    <img>, allocating HW decoders invisibly. Always
   *                    null for photos.
   *   - `domClass`   — additional class to apply (eg. 'is-grayscale').
   *                    Caller appends to its own classes.
   *   - `filterCss`  — explicit `filter:` CSS string for callers that
   *                    can't apply the class (eg. the snapshot bake
   *                    path). null when no filter needed.
   *   - `caps`       — see `computeCaps` above.
   */
  function resolveExerciseHero(exercise, opts) {
    var options = opts || {};
    var treatment = options.treatment || 'line';
    var bodyFocus = options.bodyFocus !== false;
    var surface = options.surface || 'deck';

    // Rest periods: no hero, no poster, no playable src.
    if (!exercise || exercise.media_type === 'rest') {
      return {
        mediaTag: 'skeleton',
        src: null,
        posterSrc: null,
        videoSrc: null,
        domClass: '',
        filterCss: null,
        caps: { hasBodyFocus: false, availableTreatments: [], treatmentLockedTo: null },
      };
    }

    var isPhoto = exercise.media_type === 'photo' || exercise.media_type === 'image';
    var caps = computeCaps(exercise, treatment);

    // If the requested treatment isn't available, fall back to 'line'
    // (every conversion produces a line drawing — it's the always-
    // available default). This matches `slideTreatment` in app.js.
    var effective = caps.treatmentLockedTo === 'line' ? 'line' : treatment;

    var posterSrc = pickPosterSrc(exercise, effective);
    var primarySrc = pickPrimarySrc(exercise, effective, bodyFocus);

    // Apply the grayscale class when on the B&W treatment. For photos
    // and for video posters (which don't inherit CSS filters from
    // <video> siblings), this is the only thing flipping the visual
    // from colour to B&W since both share the same colour-JPG source.
    var domClass = effective === 'bw' ? 'is-grayscale' : '';
    var filterCss = effective === 'bw' ? 'grayscale(1) contrast(1.05)' : null;

    if (isPhoto) {
      // Photos always render as <img>. The treatment URL IS a JPG (Wave
      // 22 photo three-treatment parity). Both `src` and `posterSrc`
      // point at the same file; CSS filter handles B&W.
      var photoSrc = primarySrc || posterSrc || null;
      return {
        mediaTag: photoSrc ? 'img' : 'skeleton',
        src: photoSrc,
        posterSrc: posterSrc || photoSrc,
        videoSrc: null,
        domClass: domClass,
        filterCss: filterCss,
        caps: caps,
      };
    }

    // Video. `videoSrc` is the actual mp4 URL the caller should put on
    // `<video src>` when emitting a video tag. `posterSrc` is what
    // shows in lobby <img> mode + as the <video poster> during buffer.
    // `src` mirrors `videoSrc` for the deck surface; for lobby (which
    // renders <img> for inactive rows), `src` is `posterSrc` so the
    // caller can do `mediaTag === 'img' ? src : videoSrc` uniformly.
    var videoSrc = primarySrc;
    var mediaTag;
    var src;

    if (surface === 'deck') {
      // Deck active slide always plays a <video>. Caller wraps in
      // .video-loop-pair and stamps poster= from posterSrc.
      mediaTag = videoSrc ? 'video' : 'skeleton';
      src = videoSrc;
    } else if (surface === 'prep') {
      // Prep phase is a static hero (the <video> is paused at
      // currentTime=0 underneath the overlay). Use posterSrc.
      mediaTag = posterSrc ? 'img' : 'skeleton';
      src = posterSrc;
    } else {
      // lobby + snapshot: render <img> + data-video-src; the caller's
      // single-active-video swap logic decides when to upgrade to
      // <video>. Skeleton when there's no poster (would-be img src=''
      // shows broken-image, AND can't put mp4 in <img> per the v51 fix).
      mediaTag = posterSrc ? 'img' : 'skeleton';
      src = posterSrc;
    }

    return {
      mediaTag: mediaTag,
      src: src,
      posterSrc: posterSrc,
      videoSrc: videoSrc,
      domClass: domClass,
      filterCss: filterCss,
      caps: caps,
    };
  }

  // ==========================================================================
  // Snapshot helper — bake a CSS filter into a data URL via canvas
  // ==========================================================================
  //
  // `<video poster>` does NOT inherit CSS filters during html2canvas
  // rasterisation, so even with `.is-grayscale` applied to the <video>
  // element, the rasterised PNG renders the poster URL as-is. To get
  // a treatment-correct snapshot we have to bake the filter into the
  // poster's pixel data BEFORE html2canvas reads it.
  //
  // Implementation: load the source URL into an HTMLImageElement, draw
  // into a same-origin canvas with `ctx.filter` set, export to a data
  // URL. The caller then swaps the image into the live DOM and
  // immediately into html2canvas; the bitmap pre-filtered.
  //
  // Used by `web-player/lobby.js triggerLobbyShare()` for the active
  // video's poster. Inactive lobby rows are already <img> with the
  // `.is-grayscale` class, and html2canvas's `onclone` step DOES inherit
  // CSS, so they don't need this treatment.
  //
  // Returns a Promise resolving to a `data:image/...` URL, or null on
  // error.
  function bakeFilterIntoDataUrl(srcUrl, filterCss) {
    if (!srcUrl) return Promise.resolve(null);
    if (!filterCss) {
      // No filter needed — caller can use the original URL.
      return Promise.resolve(srcUrl);
    }
    return new Promise(function (resolve) {
      try {
        var img = new Image();
        img.crossOrigin = 'anonymous';
        img.onload = function () {
          try {
            var canvas = document.createElement('canvas');
            canvas.width = img.naturalWidth || img.width || 1;
            canvas.height = img.naturalHeight || img.height || 1;
            var ctx = canvas.getContext('2d');
            if (!ctx) {
              resolve(null);
              return;
            }
            // Canvas 2D `filter` is supported on every browser we
            // target (Safari 14+, Chrome 70+, Firefox 70+). If the
            // implementation silently ignores it the result is the
            // unfiltered bitmap, which is at worst a no-op.
            try { ctx.filter = filterCss; } catch (_) { /* ignore */ }
            ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
            try {
              resolve(canvas.toDataURL('image/png'));
            } catch (_) {
              // Canvas tainted (cross-origin without ACAO). The caller
              // falls back to the original URL — rasterisation will
              // skip the filter but at least produce a poster frame.
              resolve(null);
            }
          } catch (_) {
            resolve(null);
          }
        };
        img.onerror = function () { resolve(null); };
        img.src = srcUrl;
      } catch (_) {
        resolve(null);
      }
    });
  }

  // ==========================================================================
  // Expose
  // ==========================================================================

  window.HomefitHero = Object.freeze({
    resolve: resolveExerciseHero,
    bakeFilterIntoDataUrl: bakeFilterIntoDataUrl,
  });
})();
