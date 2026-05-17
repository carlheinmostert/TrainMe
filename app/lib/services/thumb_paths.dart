/// Single source of truth for thumbnail-variant path derivation.
///
/// Every per-exercise thumbnail variant on disk follows the convention
/// `{id}_thumb_<variant>.jpg`, derived from the canonical
/// `{id}_thumb.jpg` (which itself sits in
/// `{Documents}/thumbnails/`). Variants in use today:
///
///   * `_thumb_color.jpg` — raw colour frame (B&W / Original treatments
///     via CSS filter on the web player, segmented body-focus pipeline
///     on mobile).
///   * `_thumb_line.jpg`  — line-drawing JPG copy of the converted
///     line-drawing video.
///   * `_thumb_bw.jpg`    — bytes-baked greyscale + contrast 1.05 for
///     photos (videos already carry baked greyscale in `_thumb.jpg`).
///
/// Before this helper existed the `replaceFirst('_thumb.jpg',
/// '_thumb_{variant}.jpg')` swap was inlined at 10+ call sites across
/// `upload_service.dart`, `unified_preview_scheme_bridge.dart`,
/// `exercise_hero_resolver.dart`, and friends. Adding the 4th variant
/// (`_thumb_bw.jpg` on 2026-05-16, PR #377) duplicated the pattern
/// across all of them; the next variant would scale linearly. This
/// helper breaks that loop.
///
/// Pattern mirrors the `web-player/hero_resolver.js` single-source-of-
/// truth rule (`docs/HERO_RESOLVER.md`, PR #364) — every hero-image
/// surface goes through one resolver; every thumbnail-variant path
/// goes through these helpers.
library;

/// Returns the variant path for a given canonical `_thumb.jpg` path.
///
/// Example:
///   `thumbVariantPath('/foo/abc_thumb.jpg', 'bw')`
///     -> `/foo/abc_thumb_bw.jpg`
///
/// When the input doesn't end in `_thumb.jpg`, [String.replaceFirst]
/// returns the input unchanged. Callers are responsible for guarding
/// the no-op case via [isVariantSwapValid] — the swap silently no-ops
/// for pre-Bundle-2b legacy photo rows whose `thumbnailPath` pointed at
/// the raw capture file rather than a derived `_thumb.jpg` in the
/// `thumbnails/` directory.
String thumbVariantPath(String thumbPath, String variant) {
  return thumbPath.replaceFirst('_thumb.jpg', '_thumb_$variant.jpg');
}

/// True iff [variantPath] is meaningfully different from [thumbPath] —
/// i.e. the [thumbVariantPath] swap was meaningful (the input WAS a
/// canonical `{id}_thumb.jpg` path and the variant filename now sits
/// alongside it on disk, vs the no-op case where [thumbVariantPath]
/// returned the input unchanged).
///
/// Kept as a separate helper rather than collapsed into
/// [thumbVariantPath] (returning null for the no-op case, say) so the
/// existing call-site guards stay readable — every caller already
/// computes `variantPath != thumbPath` as the gate before touching
/// disk; this lets them keep that shape with a named predicate.
bool isVariantSwapValid(String thumbPath, String variantPath) {
  return variantPath != thumbPath;
}
