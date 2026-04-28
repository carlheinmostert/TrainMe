# Privacy + Terms — Deployment Notes

Owner: Carl Mostert · Last updated: 2026-04-28

This document captures the operational steps required to make the
new `/privacy` and `/terms` pages reachable from every URL Apple App
Review (or any other reviewer) might try.

## Where the live pages are

The canonical pages live on the practice portal:

- <https://manage.homefit.studio/privacy>
- <https://manage.homefit.studio/terms>

These are static Next.js routes in `web-portal/src/app/privacy/page.tsx`
and `web-portal/src/app/terms/page.tsx`. They auto-deploy on push to
`main` via Vercel (project `homefit-web-portal`).

## The Hostinger problem

Apple reviewers historically follow whatever URL is filed in App
Store Connect under "Privacy Policy URL". For homefit.studio that has
been `https://homefit.studio/privacy` (the apex), which currently
serves a **Hostinger parked page** — HTTP 200, but the placeholder
content, not real privacy text. A reviewer landing there will reject
the build.

The apex `homefit.studio` is registered at Hostinger and DNS for the
sub-domains (`session.`, `manage.`) is delegated to Vercel, but the
apex itself is still pointed at Hostinger's parking server.

## Recommended fix — Hostinger redirect rules (option A)

Simplest one-line fix. Carl owns the Hostinger account.

1. Sign in to <https://hpanel.hostinger.com/>.
2. Open the `homefit.studio` domain → **Domain → Redirects**.
3. Add a 301 redirect:
   - **From**: `homefit.studio/privacy`
   - **To**: `https://manage.homefit.studio/privacy`
   - **Status**: 301 (Permanent)
4. Add a second 301 redirect:
   - **From**: `homefit.studio/terms`
   - **To**: `https://manage.homefit.studio/terms`
   - **Status**: 301 (Permanent)
5. (Optional but nice) add `homefit.studio` → `https://manage.homefit.studio/`
   so the apex stops showing Hostinger's parked page entirely.

After saving, verify with:

```bash
curl -sI https://homefit.studio/privacy | grep -iE 'HTTP/|location'
```

Expected:

```
HTTP/2 301
location: https://manage.homefit.studio/privacy
```

## Alternative — point the apex at Vercel (option B)

If Carl wants the apex to be a real homefit.studio landing page in
future, the cleaner path is:

1. Create a new Vercel project (or repoint `homefit-web-portal`) that
   serves the apex.
2. In Vercel project → Settings → Domains, add `homefit.studio`.
3. Update Hostinger DNS so the apex `A` record points at Vercel's IP
   (Vercel surfaces the value when you add the domain), or use
   `ALIAS`/`ANAME` if Hostinger supports it.
4. Add Vercel rewrites in `vercel.json`:

   ```json
   {
     "rewrites": [
       { "source": "/privacy", "destination": "https://manage.homefit.studio/privacy" },
       { "source": "/terms",   "destination": "https://manage.homefit.studio/terms" }
     ]
   }
   ```

Option B is more work; Option A solves the App Review blocker today.

## After the redirect is live

Update App Store Connect → App Information → Privacy Policy URL to:

- <https://homefit.studio/privacy> (preferred — clean apex URL)
  *or*
- <https://manage.homefit.studio/privacy> (works equally well; saves
  a redirect hop for the reviewer).

Either way, the page must load real privacy text without a Hostinger
banner. Verify with:

```bash
curl -sL https://homefit.studio/privacy | grep -iE 'homefit|privacy'
```

## Legal-review status

The pages currently rendered at those URLs are **draft scaffolds**.
Bracketed `[BRACKETED PLACEHOLDER]` markers are intentional — they
flag the spots where a South African attorney needs to confirm
wording. Hand the live URLs to the lawyer; their job is copy-edit,
not greenfield drafting.

When the lawyer returns red-pen edits:

1. Apply edits to `web-portal/src/app/privacy/page.tsx` and
   `web-portal/src/app/terms/page.tsx`.
2. Bump the `LAST_UPDATED` and `VERSION` constants at the top of
   each file.
3. Push to `main`. Vercel redeploys.

## In-app links

The Flutter app surfaces Privacy + Terms in `Settings → Legal`
(see `app/lib/screens/settings_screen.dart`). Both rows open the
relevant page in an in-app browser (Safari View Controller via
`url_launcher` `LaunchMode.inAppBrowserView`). Apple App Review
specifically requires an in-app legal-URL path, not just an
App Store listing link.
