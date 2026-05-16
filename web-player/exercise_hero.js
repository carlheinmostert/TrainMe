/**
 * homefit.studio — Exercise Hero Resolver (web JS surface)
 * =========================================================
 *
 * Single stateless function that decides how to render an exercise's
 * hero/poster on any of the four web surfaces (lobby strip, active deck
 * slide, prep-phase countdown, share-as-PNG snapshot). Pure: no DOM ops,
 * no IO, no module-level state.
 *
 * Load-bearing principle (2026-05-14 refactor, amended 2026-05-15 PR-B):
 *   1. Hero pictures everywhere reflect the per-exercise
 *      `preferred_treatment` set by the practitioner. The resolver derives
 *      treatment INTERNALLY from `exercise.preferred_treatment` + body
 *      focus from `exercise.body_focus`. Callers do NOT pass treatment or
 *      bodyFocus arguments.
 *   2. No silent fallback across treatments when the file is truly
 *      MISSING. If the requested treatment's variant and the line
 *      drawing are both absent the resolver returns null — the caller
 *      renders an explicit "treatment not available" placeholder.
 *      Showing a DIFFERENT treatment's content silently when the real
 *      file should be there is worse than showing nothing: it hides bugs.
 *   3. Soft fallback to line drawing when consent is REVOKED. If the
 *      practitioner preferred B&W / Original but the client only granted
 *      line consent, `get_plan_full` returns `grayscale_url=null` while
 *      keeping `line_drawing_url` populated. Treat that as the
 *      consent-revoked signal and render line silently — line drawings
 *      are de-identified by design, so the visibility downgrade is the
 *      expected behaviour of the consent system, not a bug. The
 *      principle-2 placeholder still fires when line ALSO isn't there
 *      (genuine file-missing).
 *
 * Legitimate exceptions to "no fallback" (besides principle 3):
 *   - Signed-URL refresh on 403 (existing machinery, orthogonal).
 *   - Transient "generating…" state while a variant is being extracted
 *     (a separate pending indicator is the caller's responsibility — the
 *     resolver only ever says "not available right now").
 *
 * Loaded via `<script src="exercise_hero.js">` BEFORE `app.js` and
 * `lobby.js` so the resolver is available to all callers. Exposed as
 * `window.HomefitHero.resolve(exercise, opts)`.
 *
 * Surfaces:
 *   - 'lobby'    — pre-workout row strip (lobby.js renderHeroHTML).
 *   - 'deck'     — active slide playback (app.js buildMedia).
 *   - 'prep'     — prep-phase countdown hero (app.js buildPrepOverlay).
 *   - 'snapshot' — share-as-PNG poster pass (lobby.js triggerLobbyShare).
 *
 * Mid-session treatment switching: the gear popover + the lobby's
 * treatment pill both MUTATE `exercise.preferred_treatment` (and
 * `exercise.body_focus`) on the in-memory slide object. The next render
 * picks the new treatment up via the resolver. The resolver itself is
 * stateless and idempotent.
 *
 * See `docs/audits/photo-video-treatment-audit-2026-05-13.md` for the
 * audit that motivated this refactor.
 */

(function () {
  'use strict';

  // ==========================================================================
  // Treatment from wire — map the backend's `preferred_treatment` enum
  // ==========================================================================
  //
  // The wire value lives on `exercise.preferred_treatment` as one of
  // 'line' | 'grayscale' | 'original' | null. Internally the web player
  // uses 'line' | 'bw' | 'original'. Mirrors `treatmentFromWire` in
  // `app.js` — kept here as the resolver's own derivation so it stays
  // self-contained.
  //
  // Default-default: NULL maps to 'bw' (B&W / grayscale) per the
  // 2026-05-15 publish-flow refactor (PR-B). The Flutter app already
  // writes an explicit `'grayscale'` on every new capture; this fallback
  // matters only for legacy NULL rows captured pre-2026-05-12.
  function treatmentFromWire(wire) {
    if (wire === 'line') return 'line';
    if (wire === 'original') return 'original';
    // 'grayscale' or anything else (NULL, undefined) → B&W.
    return 'bw';
  }

  // ==========================================================================
  // Treatment poster URL — strict per-treatment lookup, no cross-treatment fallback
  // ==========================================================================
  //
  // Returns the poster URL for the requested treatment, or null if that
  // variant isn't available. Callers MUST handle null by rendering a
  // placeholder; the resolver does NOT silently substitute a different
  // treatment.
  //
  // Wire shape:
  //   - Public (`get_plan_full`): up to FOUR thumbnail fields —
  //     `thumbnail_url`, `thumbnail_url_line`, `thumbnail_url_color`,
  //     `thumbnail_url_bw` (photos only, post-2026-05-16). For videos
  //     `thumbnail_url` is the B&W `_thumb.jpg` extract; for photos it
  //     is the raw colour JPG. Photo three-treatment parity (Wave 22)
  //     writes the line-drawing JPG path to `thumbnail_url` for photos
  //     too, so the same field holds DIFFERENT semantic content for the
  //     two media types — see audit F21 for the divergence.
  //
  //   - Embedded (scheme bridge): FOUR fields — `thumbnail_url`,
  //     `thumbnail_url_line`, `thumbnail_url_color`, `thumbnail_url_bw`
  //     (photos only). The native handler picks the right `_thumb*.jpg`
  //     on disk.
  //
  // Strict rules:
  //   - Line: `thumbnail_url_line` ONLY. If absent, null.
  //     EXCEPTION: For photos on the public surface, `thumbnail_url`
  //     IS the line-drawing JPG (Wave 22 semantics). So when
  //     `thumbnail_url_line` is absent AND the exercise is a photo, we
  //     fall through to `thumbnail_url` — that's not a treatment
  //     fallback, it's the same logical field under a different name.
  //   - B&W: For videos, `thumbnail_url` (the B&W variant). For photos,
  //     prefer `thumbnail_url_bw` (bytes-baked greyscale + contrast 1.05
  //     sibling, 2026-05-16) so PDF export + embedded preview render
  //     the B&W look without depending on a CSS filter. Fall back to
  //     `thumbnail_url_color` (CSS filter does the grayscale at render
  //     time) and finally `thumbnail_url` for legacy plans. If absent,
  //     null.
  //   - Original: `thumbnail_url_color` ONLY. If absent, null.
  //
  // LEGACY PLAN SOFT FALLBACK (2026-05-15):
  //   Plans captured before PR #319 (2026-05-13 photo variant pipeline)
  //   have only `thumbnail_url` on disk — neither `_thumb_color.jpg` nor
  //   `_thumb_line.jpg` was generated. The iOS scheme bridge emits all
  //   four URLs unconditionally; WKWebView resolving the missing variants
  //   returns `URLError.fileDoesNotExist` and renders an empty grey square.
  //   PR #348's default-treatment swap (NULL → B&W) made this visible on
  //   every legacy plan opened in embedded preview.
  //   Defence-in-depth: when the requested variant URL isn't present, fall
  //   back to the canonical `thumbnail_url`. The CSS `.is-grayscale` filter
  //   on the <img> still applies, so a B&W render still looks B&W; an
  //   Original render of a legacy photo will be its (only) stored variant.
  function pickPosterSrc(exercise, treatment) {
    if (!exercise) return null;
    var isPhoto = exercise.media_type === 'photo' || exercise.media_type === 'image';

    if (treatment === 'line') {
      if (exercise.thumbnail_url_line) return exercise.thumbnail_url_line;
      // Photos: `thumbnail_url` IS the line drawing under Wave 22 photo
      // three-treatment parity (the public surface uploads the line
      // drawing JPG as the canonical thumbnail). This is the SAME logical
      // field, not a treatment fallback.
      // Legacy soft fallback: also fall back to `thumbnail_url` for videos
      // when `thumbnail_url_line` isn't on disk.
      if (exercise.thumbnail_url) return exercise.thumbnail_url;
      return null;
    }

    if (treatment === 'bw') {
      // 2026-05-16 — photos now have a baked B&W sibling `_thumb_bw.jpg`
      // with greyscale + contrast 1.05 already applied to the bytes.
      // Prefer it so render paths that can't apply CSS filters (PDF
      // export via html2canvas, the iOS WKWebView scheme bridge) get a
      // pre-baked B&W bitmap. The lobby's `.is-grayscale` CSS class
      // becomes a no-op visual overlay on these bytes (idempotent —
      // re-applying grayscale to already-grey pixels doesn't change
      // anything). The `filterCss` arm below detects this case and
      // omits the filter to avoid the contrast double-apply.
      if (isPhoto && exercise.thumbnail_url_bw) return exercise.thumbnail_url_bw;
      // Videos: the canonical `_thumb.jpg` IS the B&W extract from raw.
      // No CSS filter needed — the bytes are already greyscale.
      if (!isPhoto && exercise.thumbnail_url) return exercise.thumbnail_url;
      // Photos legacy soft fallback: pre-2026-05-16 plans (no
      // `_thumb_bw.jpg` on disk). Use `thumbnail_url_color` + CSS
      // filter for B&W — same path the lobby used before the bake
      // shipped. Backfill (`ConversionService.backfillMissingVariants`
      // on app launch + `thumbnails_dirty` re-upload on next publish)
      // promotes legacy plans to the baked path within one publish
      // cycle of the practitioner installing this update.
      if (isPhoto && exercise.thumbnail_url_color) return exercise.thumbnail_url_color;
      // Legacy soft fallback: for photos with no _thumb_color.jpg on disk,
      // fall back to the canonical thumbnail. CSS filter still applies.
      if (isPhoto && exercise.thumbnail_url) return exercise.thumbnail_url;
      return null;
    }

    if (treatment === 'original') {
      if (exercise.thumbnail_url_color) return exercise.thumbnail_url_color;
      // Legacy soft fallback: no _thumb_color.jpg on disk → use the
      // canonical thumbnail. For legacy photos that's already the (only)
      // stored variant; for legacy videos that's the B&W extract — not
      // ideal but better than an empty grey square.
      if (exercise.thumbnail_url) return exercise.thumbnail_url;
      return null;
    }
    return null;
  }

  // Whether the poster URL selected for the given exercise + treatment
  // is ALREADY baked-grey on disk. When true, callers should skip the
  // CSS `grayscale(1) contrast(1.05)` filter so already-grey bitmaps
  // don't get the contrast curve applied a second time (visible as
  // crushed mid-tones).
  //
  // Cases that count as "already baked grey":
  //   * Videos in B&W: `thumbnail_url` is the `_thumb.jpg` extract from
  //     the segmented body-focus pipeline, which writes greyscale bytes.
  //   * Photos in B&W when `thumbnail_url_bw` is populated: the
  //     2026-05-16 baked sibling already applied greyscale + contrast.
  function posterIsBakedGrey(exercise, treatment) {
    if (!exercise || treatment !== 'bw') return false;
    var isPhoto = exercise.media_type === 'photo' || exercise.media_type === 'image';
    if (isPhoto) return !!exercise.thumbnail_url_bw;
    return !!exercise.thumbnail_url;
  }

  // ==========================================================================
  // Primary (playback) URL — strict per-treatment lookup, no cross-treatment fallback
  // ==========================================================================
  //
  // Returns the playback URL for the requested treatment, or null if
  // that variant isn't available. NO silent fallback to a different
  // treatment.
  //
  // Body-focus ON  → segmented variant ONLY. Falls through to untouched
  //                   raw is NOT a cross-treatment substitution — it's
  //                   the same treatment, different body-focus rendering
  //                   on the same source. Photos have no segmented JPG
  //                   pipeline on this branch, so body-focus is ignored
  //                   for photos.
  //
  // 'line' is unaffected by body-focus (line drawings are their own
  // pipeline).
  function pickPrimarySrc(exercise, treatment, bodyFocus) {
    if (!exercise) return null;
    if (treatment === 'bw') {
      if (bodyFocus) {
        // Segmented variant for body-focus ON. When body-focus is ON the
        // segmented variant IS the right rendering of grayscale — falling
        // back to the untouched original is the SAME treatment expressed
        // differently, not a cross-treatment substitution, so we allow it.
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
    // 'line' is the always-available variant in the conversion pipeline.
    return exercise.line_drawing_url || exercise.media_url || null;
  }

  // ==========================================================================
  // Caps — what surfaces should advertise as available for THIS exercise
  // ==========================================================================
  //
  // `hasBodyFocus`     — videos only. Photos have no segmented variant
  //                      pipeline today; callers should disable the
  //                      body-focus pill with the existing tooltip.
  //
  // `availableTreatments` — the treatments the slide can actually play.
  //                         Always includes 'line'; adds 'bw' / 'original'
  //                         when the underlying URLs exist.
  //
  // `treatmentLockedTo`   — set to 'line' when the practitioner's chosen
  //                          treatment ISN'T available locally (consent
  //                          absent, signed-URL expiry, missing file).
  //                          The main resolver applies the consent-revoked
  //                          soft fallback to 'line' when the line drawing
  //                          IS present; otherwise it returns 'unavailable'.
  //                          By the time the resolver returns, caps reflect
  //                          the EFFECTIVE treatment (post-fallback).
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
   * Treatment and body-focus are derived INTERNALLY from
   * `exercise.preferred_treatment` and `exercise.body_focus`. The caller
   * does NOT pass these as arguments. To switch treatments mid-session
   * (gear popover, lobby treatment pill), mutate
   * `exercise.preferred_treatment` on the in-memory slide and re-render.
   *
   * @param {object} exercise - slide row from get_plan_full / embedded bridge.
   *   Required fields (any may be null):
   *     - media_type:          'photo' | 'video' | 'image' | 'rest'
   *     - preferred_treatment: 'line' | 'grayscale' | 'original' | null
   *     - body_focus:          boolean | null  (null defaults to true)
   *     - line_drawing_url, media_url
   *     - grayscale_url, grayscale_segmented_url
   *     - original_url, original_segmented_url
   *     - thumbnail_url, thumbnail_url_line, thumbnail_url_color, thumbnail_url_bw
   *
   * @param {object} opts
   * @param {'lobby'|'deck'|'prep'|'snapshot'} opts.surface
   *
   * @returns {{
   *   mediaTag: 'img'|'video'|'unavailable'|'skeleton',
   *   src: string|null,
   *   posterSrc: string|null,
   *   videoSrc: string|null,
   *   domClass: string,
   *   filterCss: string|null,
   *   treatment: 'line'|'bw'|'original',
   *   caps: { hasBodyFocus: boolean, availableTreatments: string[], treatmentLockedTo: string|null }
   * }}
   *
   * Field semantics:
   *   - `mediaTag`     — what the caller should emit:
   *                        'img'         = static image (photos always; video
   *                                        lobby/prep/snapshot inactive rows)
   *                        'video'       = playing video (deck active slide,
   *                                        lobby active row post-swap)
   *                        'unavailable' = the requested treatment AND the
   *                                        line drawing are both absent
   *                                        (file truly missing / URL expired).
   *                                        Caller renders the coral-tinted
   *                                        "treatment not available" placeholder.
   *                                        Consent-revoked case (requested
   *                                        treatment absent but line drawing
   *                                        present) is handled by the soft
   *                                        fallback — caller sees treatment='line'
   *                                        instead of 'unavailable'.
   *                        'skeleton'    = rest period or no media at all.
   *   - `src`          — primary URL (playback for videos, image for photos).
   *                       NULL when mediaTag is 'unavailable' or 'skeleton'.
   *   - `posterSrc`    — poster URL (treatment-correct). NULL when the
   *                       per-treatment thumbnail variant isn't available.
   *   - `videoSrc`     — for videos, the actual mp4 URL. NEVER use this as
   *                       `<img src>` — iOS WKWebView lenient-renders mp4
   *                       in <img>, allocating HW decoders invisibly.
   *   - `domClass`     — class to apply (eg. 'is-grayscale' for photos
   *                       in B&W treatment).
   *   - `filterCss`    — explicit `filter:` CSS string for callers that
   *                       can't apply the class (eg. the snapshot bake
   *                       path).
   *   - `treatment`    — the effective treatment the resolver picked.
   *                       Normally equals `treatmentFromWire(exercise.preferred_treatment)`,
   *                       except when the consent-revoked soft fallback
   *                       kicks in (preferred treatment's URL absent but
   *                       line drawing present) — then 'line'. Rest
   *                       periods always report 'line'.
   *   - `caps`         — see `computeCaps`.
   */
  function resolveExerciseHero(exercise, opts) {
    var options = opts || {};
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
        treatment: 'line',
        caps: { hasBodyFocus: false, availableTreatments: [], treatmentLockedTo: null },
      };
    }

    // Derive treatment + body-focus internally. The caller may have
    // mutated `preferred_treatment` (gear popover / lobby pill) but does
    // NOT pass treatment as an argument.
    var treatment = treatmentFromWire(exercise.preferred_treatment);
    var bodyFocus = exercise.body_focus !== false; // null/undefined/true → true

    var isPhoto = exercise.media_type === 'photo' || exercise.media_type === 'image';
    var caps = computeCaps(exercise, treatment);

    // Soft fallback to line drawing for CONSENT-REVOKED case (PR-B,
    // 2026-05-15). When the requested treatment's playback variant is
    // absent from the wire payload but the line drawing IS present, the
    // gap is consent-driven — the client granted line consent only, so
    // `get_plan_full` returned `grayscale_url=null` while keeping
    // `line_drawing_url` populated. Render line silently rather than the
    // coral "treatment not available" placeholder.
    //
    // The no-fallback principle still covers the FILE-MISSING case
    // (the file is truly absent / URL expired): both the requested
    // variant AND the line drawing are NULL → fall through to the
    // unavailable placeholder below.
    if (caps.treatmentLockedTo === 'line' && treatment !== 'line') {
      var hasLinePlayback = !!(exercise.line_drawing_url || exercise.media_url);
      // For photos the Wave 22 line variant lives on `thumbnail_url` when
      // `thumbnail_url_line` isn't populated — treat both as evidence the
      // line drawing exists.
      var hasLinePoster = !!(
        exercise.thumbnail_url_line ||
        (isPhoto && exercise.thumbnail_url)
      );
      if (hasLinePlayback || hasLinePoster) {
        // Mutate the in-memory slide to 'line' so subsequent caller
        // logic (poster picker, src picker, filter CSS, dom class) all
        // run on the fallback treatment without further branching.
        // Mirrors the treatment-pill mutation pattern documented at
        // the top of the file.
        treatment = 'line';
        // Recompute caps for the new treatment so callers see the
        // post-fallback availability instead of the locked state.
        caps = computeCaps(exercise, treatment);
      } else {
        // No line drawing either → genuine file-missing case.
        // Surface the coral placeholder per the no-fallback principle.
        return {
          mediaTag: 'unavailable',
          src: null,
          posterSrc: null,
          videoSrc: null,
          domClass: '',
          filterCss: null,
          treatment: treatment, // report what was REQUESTED, not what we'd
                                // silently render — so the caller's
                                // placeholder can label the gap.
          caps: caps,
        };
      }
    }

    var posterSrc = pickPosterSrc(exercise, treatment);
    var primarySrc = pickPrimarySrc(exercise, treatment, bodyFocus);

    // Apply the grayscale class when on the B&W treatment AND the source
    // file is colour. For videos the canonical `_thumb.jpg` is ALREADY
    // greyscale on disk, so no extra filter is needed; we still flag
    // `is-grayscale` for the `<video>` element so the playing colour mp4
    // is rendered B&W. For photos the source is always raw colour, so
    // the filter is the only thing converting the pixels.
    //
    // 2026-05-16 — when the poster URL is `thumbnail_url_bw` (photos)
    // OR the canonical `_thumb.jpg` for videos, the bytes are already
    // baked grey-plus-contrast. Suppress the filter so we don't push
    // the contrast curve a second time. The CSS class still applies to
    // the <video> element when present (videos play colour mp4s under
    // the bw treatment when `body_focus` is off and no segmented file
    // exists), but on `<img>` the bake handles it.
    var bakedGreyPoster = posterIsBakedGrey(exercise, treatment);
    var domClass = treatment === 'bw' ? 'is-grayscale' : '';
    var filterCss = treatment === 'bw' && !bakedGreyPoster
        ? 'grayscale(1) contrast(1.05)'
        : null;

    if (isPhoto) {
      // Photos always render as <img>. The treatment URL IS a JPG.
      var photoSrc = primarySrc;
      var photoPoster = posterSrc;
      if (!photoSrc) {
        // Photo line/colour file isn't present for the requested
        // treatment. Render the unavailable placeholder.
        return {
          mediaTag: 'unavailable',
          src: null,
          posterSrc: null,
          videoSrc: null,
          domClass: '',
          filterCss: null,
          treatment: treatment,
          caps: caps,
        };
      }
      return {
        mediaTag: 'img',
        src: photoSrc,
        posterSrc: photoPoster || photoSrc,
        videoSrc: null,
        domClass: domClass,
        filterCss: filterCss,
        treatment: treatment,
        caps: caps,
      };
    }

    // Video. `videoSrc` is the actual mp4 URL the caller should put on
    // `<video src>` when emitting a video tag. `posterSrc` is what
    // shows in lobby <img> mode + as the <video poster> during buffer.
    var videoSrc = primarySrc;
    var mediaTag;
    var src;

    if (!videoSrc && !posterSrc) {
      // Nothing on the wire — placeholder.
      return {
        mediaTag: 'unavailable',
        src: null,
        posterSrc: null,
        videoSrc: null,
        domClass: '',
        filterCss: null,
        treatment: treatment,
        caps: caps,
      };
    }

    if (surface === 'deck') {
      // Deck active slide always plays a <video>. Caller wraps in
      // .video-loop-pair and stamps poster= from posterSrc.
      mediaTag = videoSrc ? 'video' : 'unavailable';
      src = videoSrc;
    } else if (surface === 'prep') {
      // Prep phase is a static hero. Use posterSrc.
      mediaTag = posterSrc ? 'img' : 'unavailable';
      src = posterSrc;
    } else {
      // lobby + snapshot: render <img> + data-video-src; the active-row
      // swap logic decides when to upgrade to <video>.
      mediaTag = posterSrc ? 'img' : 'unavailable';
      src = posterSrc;
    }

    return {
      mediaTag: mediaTag,
      src: src,
      posterSrc: posterSrc,
      videoSrc: videoSrc,
      domClass: domClass,
      filterCss: filterCss,
      treatment: treatment,
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
            try { ctx.filter = filterCss; } catch (_) { /* ignore */ }
            ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
            try {
              resolve(canvas.toDataURL('image/png'));
            } catch (_) {
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
    // Exported for callers (lobby treatment pill, gear popover) that
    // need to mutate `exercise.preferred_treatment` and want to map
    // a user-facing treatment ('line'/'bw'/'original') back to the
    // wire enum ('line'/'grayscale'/'original').
    treatmentFromWire: treatmentFromWire,
    treatmentToWire: function (t) {
      if (t === 'bw') return 'grayscale';
      if (t === 'original') return 'original';
      return 'line';
    },
  });
})();
