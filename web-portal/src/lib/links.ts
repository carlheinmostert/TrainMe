/**
 * External link constants — single source of truth for outbound URLs.
 *
 * Currently houses the App Store / TestFlight URL surfaced by the
 * GetTheAppBanner + per-page App Store badges (C-13 of the 2026-05-22
 * portal cosmetics stack).
 *
 * NOTE: The iOS app is not yet App-Store-Released — it's on TestFlight
 * (build 1.0.0+4 at time of writing). Flip APP_STORE_URL to the real
 * App Store URL once the app ships through review.
 *
 * If the TestFlight join URL below is a placeholder, Carl needs to
 * supply the real URL from App Store Connect → TestFlight → Public
 * Link. The placeholder will route to a generic TestFlight page that
 * tells the visitor the link is invalid — usable as a graceful
 * fallback while we wait.
 */

/** Outbound link for "Get the app" affordances across the portal.
 *  Returns the App Store URL once the app ships; TestFlight while in
 *  beta. */
export const APP_STORE_URL =
  'https://testflight.apple.com/join/PLACEHOLDER';

/** Display label for the App Store affordance — kept in sync with the
 *  badge image alt-text. Currently "App Store"; will stay that way
 *  even after the TestFlight→App Store flip. */
export const APP_STORE_LABEL = 'App Store';
