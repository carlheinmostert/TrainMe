/// Tiny helper that builds URLs into the manage.homefit.studio web
/// portal. Every app→portal navigation MUST go through here so the
/// active practice rides along as a query param — otherwise the portal
/// shows whichever practice the user last picked there, out of context
/// with what they were doing in the app.
///
/// The portal honours `?practice=<uuid>` server-side: it validates the
/// caller's membership in that practice, sets an `hf_active_practice`
/// cookie, then 302-redirects to the same path without the param so
/// refresh / share doesn't re-trigger. See `web-portal/src/middleware.ts`.
///
/// Single source of truth — call sites should never `Uri.parse` a
/// hard-coded `https://manage.homefit.studio/...` string.

library;

/// Base origin of the practitioner-facing web portal.
const String portalOrigin = 'https://manage.homefit.studio';

/// Build a [Uri] for [path] (e.g. `/credits`, `/dashboard`) on the
/// portal, optionally tagging the active [practiceId] as a query param.
///
/// [path] should start with `/` (we don't normalise — keeps the call
/// site obvious). [practiceId] is the practice UUID; passing null /
/// empty drops the param entirely (the portal falls back to the
/// hf_active_practice cookie or the first membership).
Uri portalLink(String path, {String? practiceId}) {
  final qp = (practiceId != null && practiceId.isNotEmpty)
      ? '?practice=$practiceId'
      : '';
  return Uri.parse('$portalOrigin$path$qp');
}
