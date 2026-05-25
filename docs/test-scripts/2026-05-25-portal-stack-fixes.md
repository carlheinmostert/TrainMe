# 2026-05-25 — Portal stack fixes (M5, M6, M7 + iPhone-portrait coverage)

**Branch:** `fix/portal-stack-2026-05-25` (off `staging`)
**Target:** `staging`
**Surface:** `manage.homefit.studio` (portal only)

## Table of Contents

- [What changed](#what-changed)
- [How to test](#how-to-test)
- [PayFast staging-to-staging bounce-back](#payfast-staging-to-staging-bounce-back-m5)
- [Get the iOS app card — real app icon](#get-the-ios-app-card--real-app-icon-m6)
- [Safe Mode subscribe — practice fallback + trial copy](#safe-mode-subscribe--practice-fallback--trial-copy-m7)
- [iPhone-portrait regression sweep](#iphone-portrait-regression-sweep)

## What changed

Three discrete fixes landed in one PR (the portal half of the
`2026-05-25-stack.md` triage):

1. **M5 — PayFast return URL is now per-env.** `getAppUrl()` in
   `web-portal/src/lib/payfast.ts` previously read `process.env.APP_URL`
   FIRST and fell back to `NEXT_PUBLIC_APP_URL` second. The Vercel
   `APP_URL` var was hardcoded to `https://manage.homefit.studio` across
   every env (preview + production), so staging checkouts returned to
   the prod portal and forced re-login. The helper now reads strictly
   from `NEXT_PUBLIC_APP_URL` via the strict-fail `appUrl()` env helper
   — the same per-env value the rest of the portal already uses for
   referral share links and player Preview hrefs. The webhook
   `notify_url` was already per-env (built from `supabaseUrl()`); only
   the return + cancel URLs were affected.

2. **M6 — Get-the-iOS-app banner renders the actual iOS app icon.** The
   dashboard `GetTheAppBanner` previously surfaced the matrix-logo
   glyph (`HomefitLogo`) as the install-card icon. The matrix logo is
   the brand mark; the iOS app icon Carl sees on his home screen is a
   3×3 grid of coral square pills with a sage centre on dark `#0F1117`
   (per `tools/icon-render/render_app_icon.py`). The banner now renders
   that icon (180×180 `60x60@3x` variant copied to
   `web-portal/public/ios-app-icon.png`) inside iOS's rounded-square
   mask so the card matches what the user will see on iOS once
   installed.

3. **M7 — Safe Mode subscribe page picks up the active practice from
   the dashboard fallback chain.** The page previously resolved
   `practiceId = params.practice ?? cookiePractice` — if neither was
   set, the body short-circuited to "Pick a practice in the header
   above first", even though the header was already showing the first
   practice via `HeaderIdentityStack`'s own fallback. The page now
   applies the same three-tier resolution `/dashboard` uses
   (`?practice=` → cookie → `practices[0]`), so the body's Subscribe
   CTA always aligns with the header's active practice. Also stripped
   the regressed `First subscription includes a 3-day free trial`
   bullet (Hotfix D M-9 had cleared the CTA copy but missed the body
   bullet + meta description).

Items 1-3 in the broader stack file (page-wide responsive width,
top-bar status-bar collision, build-chip overlap) were already
addressed by PRs #495, #499, #503 ahead of this PR. The "iPhone-
portrait regression sweep" section below re-walks them to confirm
no regression slipped in.

## How to test

Open the Vercel preview URL for this PR. Most items work in any modern
browser; iPhone-portrait items (M6.b, 2.x, 3.x, 4.x) want either a
real iPhone in Safari or Chrome DevTools "iPhone 14 Pro" emulation at
393 px.

Sign in as a practitioner who is OWNER of at least one practice. The
QA test account (`qa@homefit.studio` on staging) works.

Stable flat numbering — feedback can reference items like "M5.3
broken" without ambiguity.

---

## PayFast staging-to-staging bounce-back (M5)

- [ ] M5.1 Open `/credits` on the staging preview deploy. Click any
      Buy button. The browser is redirected to
      `sandbox.payfast.co.za/eng/process?...`. Inspect the URL: the
      `return_url` query param is URL-encoded but should decode to a
      URL starting with `https://staging.manage.homefit.studio/credits/return`
      — NOT `https://manage.homefit.studio/...`.
- [ ] M5.2 Same check for `cancel_url`: must decode to
      `https://staging.manage.homefit.studio/credits/cancel?...`.
- [ ] M5.3 `notify_url` (webhook) should decode to
      `https://vadjvkmldtoeyspyoqbx.supabase.co/functions/v1/payfast-webhook`
      — the STAGING Supabase project, not prod. Confirms the webhook
      ITN lands in the staging Supabase project's ledger, not prod's.
- [ ] M5.4 Complete a sandbox purchase via PayFast's test interface.
      Land back on `https://staging.manage.homefit.studio/credits/return?pid=...`
      with the active staging session still valid — no forced re-login.
- [ ] M5.5 Production smoke (only do this on the next prod deploy):
      open `/credits` on `manage.homefit.studio`, click Buy, decode
      `return_url`. Must start with `https://manage.homefit.studio/`,
      NOT the staging host. Confirms the fix didn't reverse-break prod.

## Get the iOS app card — real app icon (M6)

(Requires a practice that has NOT yet published — the
`GetTheAppBanner` only renders for fresh practices. Create a fresh
test practice if needed, or use a practice with no `plan_issuances`.)

- [ ] M6.1 Open `/dashboard` while signed in to a fresh practice. The
      coral-tinted "Get the iOS app to start capturing sessions" banner
      appears above the dashboard grid.
- [ ] M6.2 The 56×56 icon at the left of the banner shows the actual
      iOS app icon: a **3×3 grid of coral square pills with a sage
      (green) centre pill on a dark near-black background**. Carl can
      cross-reference with the same icon visible on his iPhone home
      screen — they must match.
- [ ] M6.3 The icon's container has rounded corners (~22% radius,
      matching iOS's rounded-square mask). The icon image fills the
      container without distortion or letterboxing.
- [ ] M6.4 Right-click the icon in DevTools → Inspect. The `<img>` src
      resolves to `/ios-app-icon.png` (a 180×180 PNG served from the
      portal's public directory). Image loads with HTTP 200 in the
      Network tab.
- [ ] M6.5 Desktop regression: header brand lockup (top of every page)
      still renders the canonical 5:3-pill matrix logo, NOT the
      square-pill iOS icon. The icon-only divergence is scoped to the
      install card.

## Safe Mode subscribe — practice fallback + trial copy (M7)

- [ ] M7.1 Open `/safe-mode/subscribe` directly (no `?practice=`
      query param) in a fresh browser session. The header's identity
      stack shows "In practice {Practice Name}" with a real practice
      name selected.
- [ ] M7.2 The page body shows a coral "Subscribe · 4 credits / month"
      button — NOT the "Pick a practice in the header above first"
      warning. The current credit balance card sits above the button.
- [ ] M7.3 Switch to a different practice via the header chevron. The
      URL gains `?practice=<id>` and the page re-renders against the
      newly-selected practice. The Subscribe button continues to
      render with the new practice's balance.
- [ ] M7.4 Sign in as a practitioner who is NOT a member of any
      practice (or directly URL-mutate to bypass the cookie). The page
      shows "You're signed in but not yet a member of any practice"
      message — NOT the old "Pick a practice" copy.
- [ ] M7.5 Sign in as a practitioner-role (non-owner) member of a
      practice that does NOT have an active Safe Mode subscription.
      Open `/safe-mode/subscribe`. The page shows the "Only the
      practice owner can subscribe" message.
- [ ] M7.6 The page body's "What you get" section has FOUR bullets:
      30 days of capture, on-device bystander blur, no auto-renewal,
      captures stay accessible forever. The `First subscription
      includes a 3-day free trial` bullet must be absent (Hotfix D
      M-9 cleanup).
- [ ] M7.7 Inspect the page's HTML head meta description. It reads
      `Subscribe to Safe Mode capture inside enforcing premises. 4
      credits / month, no auto-renewal.` — no "3-day free trial" string
      anywhere.

## iPhone-portrait regression sweep

(Re-walks items already shipped via PRs #495/#499/#503 — confirms this
PR didn't reintroduce overflow / overlap / chip-position issues.)

Open the staging preview in Safari iPhone-portrait or DevTools "iPhone
14 Pro" at 393 px width.

- [ ] R.1 `/dashboard`: paste the W3.1 diagnostic in the console —
      `Array.from(document.querySelectorAll('*')).filter(el => el.scrollWidth > document.documentElement.clientWidth + 1)`.
      Result must be `[]`.
- [ ] R.2 `/safe-mode/subscribe`: same diagnostic. Result must be `[]`.
- [ ] R.3 `/dashboard`: scroll to the bottom. Build chip (`<sha> ·
      <branch>` at 35% opacity) renders as an in-flow line below the
      last card with a thin top border — never overlapping a card.
- [ ] R.4 `/dashboard` header: the brand lockup sits below the iOS
      status-bar zone (real device only — DevTools doesn't render the
      status bar). Identity cluster stacks BELOW the lockup on its own
      right-aligned row.
- [ ] R.5 Get-the-app card on `/dashboard`: the iOS icon, copy, App
      Store badge, and QR popover trigger all fit inside the viewport
      with no right-edge clipping. The copy may wrap to multiple lines.
- [ ] R.6 `/safe-mode/subscribe` on iPhone-portrait: the page body fits
      in the viewport with no horizontal scroll. The Subscribe button
      spans full-width. The "What you get" bullets read in full
      without right-edge truncation.
- [ ] R.7 Desktop sanity (≥ 1024 px): the install card on `/dashboard`
      renders the icon + copy on the left and App Store badge + QR on
      the right in a single row. No regression versus pre-PR.
