# Portal iPhone-portrait rendering — test wave 2026-05-25

## Table of Contents
- [What changed](#what-changed)
- [How to test](#how-to-test)
- [Dashboard fits the viewport](#1-dashboard-fits-the-viewport)
- [Other portal pages fit the viewport](#2-other-portal-pages-fit-the-viewport)
- [Header — safe-area inset + no overlap](#3-header--safe-area-inset--no-overlap)
- [Build chip — below content, not over it](#4-build-chip--below-content-not-over-it)
- [Desktop regression check](#5-desktop-regression-check)
- [Back-arrow hoist regression check](#6-back-arrow-hoist-regression-check)

## What changed

Three responsive-layout fixes applied to the web portal so it reads cleanly
on iPhone Safari portrait (~390 px viewport):

1. **Page width** — `body` gains `overflow-x-hidden` and `pb-12` so any
   accidental shadow overflow is trapped and the fixed build chip never
   paints over the bottom-most card. The `DashboardTile` footer band
   (Credits tile) now lets its copy span shrink + wrap so
   "Earn free credits from your network" reads in full instead of
   truncating to `Earn n...`.
2. **Header safe-area** — `BrandHeader` gains
   `pt-[env(safe-area-inset-top)]` so the brand lockup no longer paints
   into the iOS status-bar zone. Root layout now declares
   `viewportFit: 'cover'` so the env() insets resolve to non-zero on
   iPhone (the inset is no-op without it).
3. **Header identity stack** — on `< md` viewports the identity stack
   (signed-in email, practice switcher, sign-out) flows below the brand
   in its own right-aligned row instead of overlapping the centred
   lockup. The brand lockup also shrinks on narrow viewports
   (`h-14 sm:h-16 md:h-20 lg:h-24`).
4. **Build chip** — `BuildInfo` clamps to `max-w-[60vw]` + `truncate`
   so a long branch label doesn't bleed off-screen at narrow widths.
   Full label remains accessible via the `title` attribute.

## How to test

Open a Vercel preview of `staging.manage.homefit.studio` in iPhone
Safari **portrait** (real device preferred; DevTools iPhone 12/13/14
emulation at 390 x 844 acceptable for items 1, 2, 4, 5, 6). For item 3
the safe-area inset only resolves on a real iOS device or when the
"Show device frame" mode in Safari Web Inspector is active.

Tick boxes as you go. Stable numbering — feedback can reference items
like "3.b broken" without ambiguity.

---

## 1. Dashboard fits the viewport

- [ ] 1.a Open `/dashboard` on iPhone portrait. The header brand lockup
      sits below the iOS status bar (time / wifi / battery) with visible
      gap, not over it.
- [ ] 1.b Scroll the dashboard. Every tile (Credits, Clients, Classes,
      Public profile, Premises, Account, Audit, Members if owner) fits
      inside the viewport with no right-edge clipping and no horizontal
      page scroll.
- [ ] 1.c The Credits tile's coral footer band reads
      **"Earn free credits from your network"** in full (or wraps to
      two lines), and the `Earn more →` CTA sits on the right with no
      truncation.
- [ ] 1.d The `GetTheAppBanner` (visible only on practices that have
      not published yet) fits in the viewport with the App Store badge
      and QR trigger reachable.

## 2. Other portal pages fit the viewport

For each route below, open it on iPhone portrait and confirm no
horizontal page scroll, every interactive element reachable, no
right-edge clipping on cards.

- [ ] 2.a `/clients`
- [ ] 2.b `/clients/[id]` (open any client)
- [ ] 2.c `/credits`
- [ ] 2.d `/audit` — the audit log table is allowed to scroll
      horizontally inside its own card (the table has more columns than
      fit on iPhone), but the surrounding chrome must not.
- [ ] 2.e `/network`
- [ ] 2.f `/members` (owner accounts only)
- [ ] 2.g `/account`
- [ ] 2.h `/premises`
- [ ] 2.i `/premises/[id]` (open any premises)
- [ ] 2.j `/public-profile`
- [ ] 2.k `/safe-mode`
- [ ] 2.l `/getting-started`
- [ ] 2.m `/help/credits`
- [ ] 2.n `/privacy`
- [ ] 2.o `/terms`

## 3. Header — safe-area inset + no overlap

- [ ] 3.a The brand lockup is fully visible below the iOS status-bar
      zone on iPhone portrait (status bar pixels are not painted over
      the lockup). Confirm on a real device — desktop browser
      emulation does not paint the status bar so item 3.a needs the
      device or a TestFlight-style standalone PWA install.
- [ ] 3.b At iPhone portrait the identity cluster (Signed in as X /
      In practice Y / Sign out) renders **below** the brand on its own
      right-aligned row. It must not overlap the centred lockup.
- [ ] 3.c The practice switcher chevron still opens its popover, the
      practitioner can switch practices, and the Sign out link still
      signs them out.
- [ ] 3.d On `/dashboard`, the left slot has nothing (no back-arrow —
      R-12 root, working as intended).
- [ ] 3.e On `/credits`, the left slot shows `← Home` and tapping it
      navigates to the dashboard.

## 4. Build chip — below content, not over it

- [ ] 4.a Scroll to the bottom of `/dashboard`. The fixed build chip
      (`<sha> · <branch>` at 35% opacity, bottom-right) sits in a
      visually clear zone below the last card — no card content paints
      under or over it.
- [ ] 4.b Same check on `/clients`, `/audit`, `/network`,
      `/public-profile`, `/premises` — the build chip never overlaps
      the last card.
- [ ] 4.c The chip itself is not wider than ~60% of viewport width
      (no overflow off the right edge even when the branch name is
      long, e.g. `fix/portal-iphone-portrait-rendering`).
- [ ] 4.d Tap-and-hold the chip on the device — the full label appears
      via the `title` tooltip (Safari may surface it as a long-press
      preview).

## 5. Desktop regression check

Open the same routes on a desktop viewport (≥ 1024 px width):

- [ ] 5.a `/dashboard` header layout is unchanged from before the fix:
      brand centred, back-link in absolute left slot (none on the
      dashboard root), identity cluster in absolute right slot at the
      same vertical centre as the lockup.
- [ ] 5.b The brand lockup renders at its previous size (`h-24` /
      ~96 px tall) on `lg+` viewports.
- [ ] 5.c The dashboard tile grid still reflows to 2-column on `sm` /
      ~640 px and 3-column on `lg` / ~1024 px.
- [ ] 5.d The Credits footer band still reads
      "Earn free credits from your network" + "Earn more →" on one
      line at desktop widths.

## 6. Back-arrow hoist regression check

(Sanity check that the #484 back-arrow hoist still works exactly as
before — the rendering fix should not have regressed it.)

- [ ] 6.a `/credits` — header left slot reads `← Home`, links to
      `/dashboard?practice=<active>`.
- [ ] 6.b `/network` — header left slot reads `← Credits`, links to
      `/credits?practice=<active>`.
- [ ] 6.c `/premises` — header left slot reads `← Home`.
- [ ] 6.d `/premises/[id]` — header left slot reads `← Premises`.
- [ ] 6.e `/account`, `/members`, `/public-profile`, `/safe-mode`,
      `/privacy`, `/terms`, `/help/credits`, `/getting-started` — all
      show `← Home`.
- [ ] 6.f `/dashboard`, `/clients`, `/clients/[id]`, `/audit` — header
      left slot is empty (these pages either are root surfaces or carry
      their own inline back nav, by design — not in scope for this
      wave).
