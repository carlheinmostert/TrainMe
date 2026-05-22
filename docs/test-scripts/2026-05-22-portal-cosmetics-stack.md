# 2026-05-22 — manage.homefit.studio portal cosmetics stack

Queue of cosmetic / UX tweaks for the web portal at `manage.homefit.studio` (Next.js app under `web-portal/`). Append-only as Carl raises items. **Nothing dispatched until Carl says "execute the stack" / "go".**

Scope: portal only. Mobile app + web player items go to their own stacks.

## Items

### C-1 — Consolidate identity/practice display: dashboard style wins, top bar absorbs it, current chips + dashboard block both go

**Carl's words:** "On the top bar it shows my practice name and then the logged-in user. Also, below that, on the dashboard, it shows 'Signed in as Carl Mostert' and 'In practice with [switcher]' — duplicate information. I prefer the look and feel of 'Signed in as Carl Mostert' and 'In practice [switcher]' at the top bar. That all must go."

**Current state (duplicate):**
- **Top bar** (`web-portal/src/components/HeaderRightCluster.tsx` mounted by `web-portal/src/components/BrandHeader.tsx`) — chip-style: practice name chip with switcher dropdown (`PracticeSwitcherChip`, line ~58) + signed-in email chip (line ~302).
- **Dashboard body** (`web-portal/src/app/dashboard/page.tsx:190` + `:197`) — text style: `<p>Signed in as {user.email}</p>` followed by `<PracticeContextLine ... />` rendering "In practice [name with switcher]".

**Target state:**
- Top bar shows the dashboard-style text: `Signed in as carl@example.com · In practice [Practice Name ⇄]` (or stacked — match the dashboard layout Carl likes). Practice name remains the interactive switcher (popover) per `PracticeContextLine`'s existing UX.
- Dashboard block (lines ~188–200 of `dashboard/page.tsx`) — REMOVE entirely. No more duplicate.
- Existing top-bar chips (`PracticeSwitcherChip` + email chip in `HeaderRightCluster.tsx`) — REPLACE with the text-line treatment, or delete those subcomponents if no other surface uses them.

**Files to touch:**
- `web-portal/src/components/HeaderRightCluster.tsx` — swap chip layout for text-line layout (port `PracticeContextLine` styling or render it directly).
- `web-portal/src/components/PracticeContextLine.tsx` — likely reuse as-is in the header (verify it doesn't have dashboard-specific padding/sizing — may need a `variant="header"` prop or a sibling component sharing the popover internals).
- `web-portal/src/app/dashboard/page.tsx` — remove the `Signed in as` `<p>` (line 190) + the `<PracticeContextLine />` block (line 197) + the surrounding comment block (line ~192–196).
- Verify no other page imports `PracticeContextLine` for the same purpose (`grep -rn PracticeContextLine web-portal/src`) — if `account/page.tsx` uses it, leave that one alone (account page is the canonical settings surface).

**Open questions for implementer:**
- Stacked vs inline in the header? Dashboard renders them as two lines; top bar has horizontal space constraints on narrow viewports. Suggest: inline on desktop (`md:`+), stacked on mobile, separated by `·`.
- The practice switcher's popover — does it need re-anchoring when mounted in the header vs the dashboard? Test the popover positioning after the move.

**Test scope:**
- Top bar shows "Signed in as {email} · In practice {Practice Name}" on every authenticated portal page (dashboard, clients, credits, audit, members, account).
- Practice name in the top bar opens the switcher popover; switching practices updates the page.
- Dashboard no longer has the duplicate "Signed in as" + "In practice" block under the page header.
- Mobile width: layout doesn't overflow or wrap awkwardly.

### C-2 — Promote Account to a tile, kill the "Dashboard" word, "the dashboard is the website"

**Carl's words:** "The account settings, which were hidden in a drop-down menu at the top right, must become a card in the actual dashboard. The word 'dashboard' must be removed. I don't think we're going to have a much more complicated UI than just these cards. The dashboard is the website. I don't need to call it a dashboard."

**Two parts:**

**1. Account becomes a DashboardTile.**
- Currently reachable only via `HeaderRightCluster.tsx:328` (`Account settings` link inside the `AccountMenuChip` dropdown).
- Add a new `<DashboardTile>` to `web-portal/src/app/dashboard/page.tsx` linking to `/account?practice={id}`. Position it alongside the existing tiles (Clients, Credits, Network, Audit, Members) — last in the row reads as a sensible "settings" placement.
- Icon + title: `Account` (or `Account & settings`). Sub-label TBD — practice rename, email, password live on `/account/page.tsx` so something like "Email, password, practice name."
- Remove the `Account settings` link from the `AccountMenuChip` dropdown (`HeaderRightCluster.tsx:328`). The dropdown then only has `Sign out` — at which point consider collapsing the chip + dropdown into a plain `Sign out` text button next to the identity line (companion to C-1).

**2. "Dashboard" word goes away everywhere user-visible.**
- `web-portal/src/app/dashboard/page.tsx:189` — `<h1>Dashboard</h1>` → DELETE the h1 entirely. Carl's rule: this IS the site, no label needed. The header / logo provides identity.
- Browser tab title — check `web-portal/src/app/dashboard/page.tsx` or its parent layout for `metadata.title`. Currently likely "Dashboard | homefit.studio" or similar; change to "homefit.studio" or "Manage · homefit.studio".
- Any breadcrumbs / nav references to "Dashboard" — sweep for user-visible occurrences. The route stays `/dashboard` (don't rename the URL path — breaks bookmarks + redirects); only the visible word changes.
- Keep internal identifiers untouched: `DashboardTile`, `DashboardAuditCard`, `dashboardStats` API call, code comments referencing "dashboard" — those are implementation language, not user-facing. (Don't waste time renaming.)

**Files to touch:**
- `web-portal/src/app/dashboard/page.tsx` — remove h1 (line 189), add Account tile (alongside lines 213–246).
- `web-portal/src/components/HeaderRightCluster.tsx` — remove `Account settings` link from `AccountMenuChip` (line ~328); consider collapsing the chip once it only has Sign out.
- `web-portal/src/app/layout.tsx` (root) and/or `web-portal/src/app/dashboard/layout.tsx` if exists — update `metadata.title` to drop "Dashboard".
- Grep `web-portal/src` for visible "Dashboard" strings in JSX (`>Dashboard<`, `title="Dashboard"`, etc.) and remove user-visible occurrences.

**Open questions for implementer:**
- Account tile copy — `Account` (one word) vs `Account & settings` vs `Settings`? Lean to `Account` since that's the existing route name + matches the dropdown wording.
- Sign-out affordance after stripping the dropdown — does the email chip become a plain `Sign out` button, or does Sign out move to the Account page itself? Recommend Sign out stays in the header (one-click affordance for shared devices) but as a plain text link, not a chip+dropdown.

**Test scope:**
- Dashboard page (`/dashboard`) renders tiles WITHOUT the `<h1>Dashboard</h1>` heading above them.
- New Account tile renders alongside the other tiles and routes to `/account?practice={id}`.
- Browser tab no longer says "Dashboard"; page title is `homefit.studio` (or similar).
- Header chip dropdown — if kept, no longer shows `Account settings`; if collapsed, header shows plain `Sign out` text link.
- Sign-out still works from the header without dropdown depth.

### C-3 — Every tile gets a left-aligned concept icon + hover-to-reveal explanation popover

**Carl's words:** "Each dashboard card must have an icon on the left-hand side which represents the concept being managed there. When you hover over a card, it should show a pop-up explaining what the function of that card is."

**Current state:**
- `web-portal/src/components/DashboardTile.tsx` renders label + headline + subtitle in a vertical text column. No icon. Chevron-right glyph on the right (line 74) hints at "click to drill in" but there's no concept iconography.
- `web-portal/src/components/DashboardAuditCard.tsx` — same family, no icon either.
- Cards are: Credits, Network, Clients, Audit, Members (owner-only), + Account (post-C-2).

**Target state:**

**1. Left-aligned concept icon on every tile.**
- Add an `icon` prop to `DashboardTile` (and matching slot in `DashboardAuditCard`). Render in a fixed-width column on the left of the existing text stack.
- Icon set — pick from `lucide-react` (already in `web-portal`'s deps if present, else add). Suggested mappings:
  - Credits → `Coins` or `Wallet`
  - Network → `Share2` or `Users`
  - Clients → `UserRound` or `Contact`
  - Audit → `ScrollText` or `History`
  - Members → `UsersRound` or `Shield` (owner-only flavour)
  - Account → `Settings` or `CircleUser`
- Size: 24px, stroke 1.75. Coral on hover/focus (matches existing `group-hover:text-brand` pattern on the chevron, line 74). Default `text-ink-muted` so the icon doesn't compete with the headline.
- Layout: `flex items-start gap-4` on the tile root; icon in a `shrink-0` slot, text column flexes.

**2. Hover-to-reveal explanation popover.**
- On hover (desktop) and on focus (keyboard) — show a popover anchored to the tile with a 1–2 sentence plain-English explanation of what the card manages.
- Trigger pattern: `aria-describedby` linkage + a styled tooltip. Lean towards a Radix `Tooltip` (already used elsewhere in the portal? grep needed) for a11y + focus parity. If Radix isn't in `web-portal`'s deps, hand-roll with `onMouseEnter` / `onFocus` + a positioned `<div>` — keep CSS-only fallback for `prefers-reduced-motion`.
- Position: above the card on desktop, with a small caret pointing down to the tile. Max-width ~280px so the text wraps naturally.
- Touch devices — no hover. Long-press → popover, OR an info `(i)` glyph next to the icon that taps open the popover. Recommend the (i) glyph for clarity over long-press gestures.
- Copy (suggested starting drafts — Carl can tune):
  - **Credits** — "Buy publishing credits and see what's left. One credit publishes one plan."
  - **Network** — "Invite other practitioners with your referral link. You earn 5% back in free credits on everything they buy."
  - **Clients** — "All clients across your practice. Drill in to see their plans, consent, and analytics."
  - **Audit** — "Append-only log of every publish, purchase, and consent change in your practice."
  - **Members** — "Add or remove practitioners in your practice. Owners can also rename the practice."
  - **Account** — "Your email, password, and the active practice's name."

**Files to touch:**
- `web-portal/src/components/DashboardTile.tsx` — add `icon` prop, layout flex with icon column, add hover/focus popover with `description` prop.
- `web-portal/src/components/DashboardAuditCard.tsx` — mirror the icon + description treatment so the audit card stays consistent with siblings.
- `web-portal/src/app/dashboard/page.tsx` — pass the icon component + description string for each tile at lines 213–248.
- Check `web-portal/package.json` for `lucide-react` or similar; add if missing. Radix Tooltip (`@radix-ui/react-tooltip`) similarly — add if not present (small dep, well-supported).

**Open questions for implementer:**
- Radix Tooltip vs hand-rolled? Radix is ~6kb, handles keyboard + screen reader correctly out of the box. Recommend Radix unless the portal explicitly avoids it.
- Touch device pattern — info glyph next to icon, or rely on long-press? Recommend (i) glyph for discoverability.
- Should the popover fire on the card's interior text too, or only when hovering the icon? Recommend full-card hover region — the popover is contextual help, not a tooltip on a specific glyph.

**Test scope:**
- Each tile renders an icon on the left of the text content (Credits, Network, Clients, Audit, Members, Account).
- Hovering any tile (desktop) reveals a popover with a 1–2 sentence description; popover dismisses on mouse-out.
- Keyboard focus reveals the same popover (Tab through the dashboard tiles, popover surfaces for the focused tile).
- Touch viewport — info glyph next to icon taps to open the popover; tapping outside dismisses.
- Tile click still routes to the destination (hover popover doesn't intercept the click).
- Icons render in coral on hover, matching the chevron's existing hover behaviour.

### C-4 — Top-left brand: always the lockup (wordmark above matrix, exact-width). `.studio` always coral.

**Carl's words:** "The logo at the top left, with the wordmark to the right of it, is not compliant. I always want the wordmark to be on top of the logo, and it must be exactly as wide as the logo. If the logo itself gets resized, the wordmark must just follow it. Also, the `.studio` part of the wordmark must be in coral. Always."

**This is a brand-canonical change.** Three surfaces share the logo geometry by design (matrix-only + lockup variants). Updates must land on all three so the brand stays consistent.

**Current state (non-compliant):**
- `web-portal/src/components/BrandHeader.tsx:71-74` renders `<HomefitLogo />` (matrix only) followed by a separate `<span>homefit.studio</span>` text. That's the "matrix + wordmark side-by-side" pattern Carl is rejecting.
- `web-portal/src/components/HomefitLogo.tsx:91-105` — the existing `HomefitLogoLockup` already has wordmark-above-matrix at exactly 48-unit width via `textLength="48" lengthAdjust="spacingAndGlyphs"` (line 96-97). Wordmark fill is uniform `#F0F0F5` (line 101) — needs to split into "homefit" light + ".studio" coral.

**Target state:**

**1. Top-left of every authenticated portal page uses `HomefitLogoLockup` (not the matrix-only `HomefitLogo`).**
- `BrandHeader.tsx:71-74` — replace `<HomefitLogo className="h-7 w-auto" />` + the standalone `<span>` with `<HomefitLogoLockup className="h-10 w-auto" />` (height bump because the lockup's viewBox is 16 tall vs 9.5 — match the optical weight of today's combined chrome). Delete the now-redundant `<span>`.
- The lockup's `viewBox` already guarantees the wordmark is exactly as wide as the matrix (both span 0→48 on the X axis). Resizing the SVG via Tailwind `h-N` keeps the proportion locked — no per-instance math needed.
- Verify every other portal page that mounts `<HomefitLogo />` directly: keep matrix-only ONLY where there's already a separate brand context (e.g. favicon-class chrome). On user-visible headers / hero surfaces, use the lockup.

**2. Wordmark colour split: `homefit` stays light, `.studio` always coral.**
- `HomefitLogo.tsx:92-105` — split the single `<text>` into the same text wrapper containing `<tspan>` children:
  ```svg
  <text x="24" y="4.6" textAnchor="middle" textLength="48"
        lengthAdjust="spacingAndGlyphs" fontFamily="Montserrat, sans-serif"
        fontWeight="600" fontSize="6.5" letterSpacing="-0.1">
    <tspan fill="#F0F0F5">homefit</tspan><tspan fill="#FF6B35">.studio</tspan>
  </text>
  ```
- Verify the `textLength="48"` constraint still applies across the spans correctly. If WebKit splits the lengthAdjust per-tspan, fall back to `<text>` + nested `<tspan>` with explicit `x` coordinates that sum to 48.

**3. Parity sweep (R-10-style — logo is brand-canonical, not portal-only):**
- `app/lib/widgets/homefit_logo.dart` — the Flutter twin. The lockup widget needs the same coral `.studio` colour split. RichText with two TextSpans is the Dart analogue.
- `web-player/app.js` — `buildHomefitLogoSvg()` (referenced in the HomefitLogo.tsx top-comment, line 25) needs the matching tspan split for the web player's lobby + footer surfaces.
- `tools/email-logo-render/render.py` — the Python PNG renderer that produces the 768×152 base64-inlined matrix logo for Supabase auth emails. If Carl wants the coral `.studio` in those emails too (likely yes), regenerate the PNG and re-apply via the Management API runbook in `docs/RESEND_SETUP.md`.
- `web-portal/src/app/r/[code]/opengraph-image.tsx:33` — referral OG card. Inspect whether it renders the lockup; if so, mirror the colour split.
- Mobile splash screen / app-icon assets — `tools/icon-render/render_app_icon.py` deliberately diverges per `feedback_app_icon_divergence.md` (5×5 square pills). DON'T touch the app icon. The colour-split rule is for the wordmark only; app icon has no wordmark.

**Files to touch:**
- `web-portal/src/components/HomefitLogo.tsx` — split the wordmark `<text>` in `HomefitLogoLockup` into two `<tspan>` segments.
- `web-portal/src/components/BrandHeader.tsx` — swap `HomefitLogo` → `HomefitLogoLockup`, drop the standalone `<span>`, tune `h-N` for optical weight.
- `app/lib/widgets/homefit_logo.dart` — port the colour split to the Flutter lockup widget.
- `web-player/app.js` — `buildHomefitLogoSvg()`: same tspan split.
- `tools/email-logo-render/render.py` + re-apply via `docs/RESEND_SETUP.md` runbook (open question — see below).
- `docs/design/project/voice.md` / `docs/design/project/tokens.json` / `CLAUDE.md` brand section — document the new "`.studio` always coral" rule so future agents don't revert it. Memory file `brand_system.md` also wants an update line.

**Open questions for implementer:**
- Email PNG regeneration — yes/no? The matrix logo in auth emails is wordmark-less today (just the matrix above optional "homefit team" sender text in plain text), so this may be a no-op. Verify by reading the template HTML in `supabase/email-templates/`. If they use the lockup, re-render the PNG.
- Existing `<HomefitLogo />` (matrix-only) usages — keep most as-is. The matrix is the favicon / app icon / tight-chrome variant. The brand rule "wordmark above matrix, exact-width" only kicks in where a wordmark renders at all. Audit each usage individually.
- WebKit `textLength` + `tspan` interaction — needs a real Safari + iOS WKWebView render check before merging. If it splits incorrectly (e.g. ".studio" overflows past 48), the fallback is a single `<text>` with two `<tspan>` children at explicit `dx` offsets, or hand-positioned `<text>` elements that sum to 48 width.

**Memory update — IMPORTANT:**
After merge, update `/Users/chm/.claude/projects/-Users-chm-dev-TrainMe/memory/brand_system.md` to record the new rule: "Wordmark always above matrix, exact-width. `.studio` always coral `#FF6B35`. `homefit` light `#F0F0F5`." Also update `feedback_brand_assets_actual_files.md` if the canonical SVG files under `docs/design/project/logos/` need regeneration to match.

**Test scope:**
- Portal top-left renders matrix with wordmark stacked ABOVE it; wordmark spans exactly the matrix's width.
- `homefit` part of the wordmark renders in light grey; `.studio` part renders in coral.
- Resizing the logo (browser zoom, or changing the `h-N` class) keeps the wordmark width locked to the matrix width — no drift, no overflow.
- Mobile app shows the same colour-split lockup wherever the lockup variant is used.
- Web player lobby + footer show the same colour-split lockup.
- Auth emails — if they use the lockup, the new PNG renders with `.studio` in coral.

### C-5 — Auth email templates: `homefit` colour off-token (uses `#FFFFFF` instead of `#F0F0F5`)

**Source:** Flagged 2026-05-22 by the email parity agent during C-4 execution.
**Symptom:** All 6 templates under `supabase/email-templates/` render the wordmark with `color:#FFFFFF` for the `homefit` half. The locked brand spec (per `tokens.json` `ink.dark.primary`) is `#F0F0F5`. `.studio` is already coral and correct.
**Scope:** 1-line CSS change in each of 6 template files + matching 1-line tweak in `tools/email-logo-render/render.py` (where `OLD_HEADER` and `new_header()` define the wordmark colours, if those constants are token-aware).
**Re-apply:** Same Management API runbook as `docs/RESEND_SETUP.md` (target staging only).
**Risk:** Visual diff is sub-perceptible (`#FFFFFF` vs `#F0F0F5` on dark email surfaces). Pure token-compliance hygiene, not user-visible.
**Recommendation:** Bundle with the next routine email-template touch — not a standalone PR.

### C-6 — Practice switcher is missing / hidden when you'd expect it

**Source:** Carl, 2026-05-22 (after staging deploy of the cosmetic pass): "We need a practice switcher. I don't want to have to log out and log back in with a different username. Actually, that won't change my practice. What happened to our practice switcher? Can we put it back?"

**Symptom:** Carl can't find a way to switch between practices from the new header.

**File:** `web-portal/src/components/HeaderIdentityStack.tsx` — `PracticeLine` function at line ~75.

**Current shipped behaviour (per Q15 of grilling):** the chevron-switcher renders ONLY when `practices.length > 1`. Single-practice users see "In practice {Name}" as plain prose with no affordance. This is identical to the old `PracticeContextLine.SwitchPopover` behaviour (also hid on single practice).

**Two reads of the report — needs clarification when executing:**

1. **(Bug) Carl has multiple practices but the chevron isn't appearing.** Diagnose data flow:
   - `web-portal/src/app/dashboard/page.tsx:43` calls `await api.listMyPractices()` and passes the result to `BrandHeader` at line 180. Verify the RPC returns >1 row for Carl's account.
   - If RPC returns the right list but `HeaderIdentityStack`'s `selected && (...)` guard at line 65 drops the line, that's a `selectedId`-propagation bug (line 81 of BrandHeader passes `practiceId ?? null`).
   - Check inner pages (`/clients`, `/audit`, etc.) — same data plumbing? Or do they pass empty `practices=[]` so the line collapses everywhere except `/dashboard`?
2. **(Design change) Carl has one practice and wants the switcher affordance restored anyway.** Override Q15's "single practice = no chevron" rule. Render the chevron always, opening a popover that either shows the empty state ("No other practices yet") or invites the user to be added as a member of another practice. Carl's phrasing "can we put it back" suggests this is the lived experience — the old chip-style switcher MAY have always shown a chevron visually even when only one practice existed; needs a regression check against the pre-cosmetic-pass behaviour.

**Recommendation for execution:** start with (1) — verify the data + propagation. If Carl has multiple practices and the chevron isn't showing, fix the data plumbing. If he has one practice, ask whether he wants Q15's spec reversed (always show the chevron) or whether the empty-state design is acceptable.

**Related:** the inner pages (`/clients`, `/clients/[id]`, `/audit`, `/credits`, `/members`, `/network`, `/account`, `/premises`, `/public-profile`) all use `BrandHeader showSignOut={true}` — verify each one threads `practices` AND `practiceId` through so the switcher works from any route, not just `/dashboard`. Q4 of the grilling locked "header on every authenticated page."

### C-7 — Dashboard tile tooltips render at top-left of viewport instead of anchored to the card

**Source:** Carl, 2026-05-22 (live on staging): "The pop-up notes that you created for me on the cards on the dashboard are rendering at the top left-hand side of the screen, so they are not rendering in the context of the card."

**Symptom:** hovering a dashboard tile opens the description popover, but it floats in the top-left of the viewport (~0,0) instead of above the hovered tile.

**File:** `web-portal/src/components/DashboardTile.tsx` (line ~65-110, `Tooltip.Root` + `Tooltip.Trigger asChild` + `Tooltip.Portal` + `Tooltip.Content`). Same pattern in `web-portal/src/components/DashboardAuditCard.tsx`.

**Likely root cause (investigation needed during execution):**

1. **`Tooltip.Trigger asChild` ref-forwarding to `Link`.** Radix needs the trigger to forward its ref to a real DOM element so it can measure the anchor's bounding rect. Next.js `Link` forwards refs to the underlying `<a>` — should work — but if for any reason the ref isn't reaching the DOM node, Radix can't compute position and falls back to (0,0). Possible interaction with the parent `<div className="relative">` wrapper at line 67.
2. **`Tooltip.Portal` + measurement timing.** Portal renders into `document.body`, breaking out of any parent transforms/stacking contexts (which is correct). But if the Trigger isn't measured at open time, the Content positions at the viewport origin. Could be a hydration race.
3. **The `TouchInfoTrigger` sibling trigger inside the same `Tooltip.Root`.** Two `Tooltip.Trigger` elements (one on the Link, one on the info button) sharing a single Root may be confusing Radix's anchor resolution — the second trigger might be winning and reporting position (0,0) because the info button has `display:none` until `@media(hover:none)` kicks in.

**Fix shape (suggested — pick during execution):**

- Refactor so the Link is the Trigger and the info button is in its own separate `Tooltip.Root` (one Root per Trigger). Two roots, two contents (or one shared description rendered twice — small dup).
- Or use Radix `Popover` instead of `Tooltip` for the info-button-on-touch case, since that's semantically a tap-to-reveal not a hover-to-reveal.
- Verify ref-forwarding on the Trigger → Link chain by adding `ref` logging on mount.
- Confirm in Safari + Chrome (Radix positioning can drift across browsers).

**Test scope:**
- Hover any tile on `/dashboard` (desktop) → popover appears ABOVE the tile with the caret pointing down at it.
- Tab through tiles via keyboard → popover for the focused tile renders anchored to it.
- Touch viewport: tap the `(i)` info glyph → popover renders anchored to the glyph.
- Verified on Safari + Chrome at 1280px + 375px viewports.

### C-8 — Dashboard tile heights should align per row, dictated by the tallest card

**Source:** Carl, 2026-05-22: "When cards are displayed in the Dashboard, the height of cards on every row should be the same. The height can be dictated by the card that needs the most space, but the other ones shouldn't be dynamic. They should all conform. It's easier on the eye."

**Files:** `web-portal/src/components/DashboardTile.tsx`, `web-portal/src/components/DashboardAuditCard.tsx`, `web-portal/src/app/dashboard/page.tsx` (grid container at line ~253 `<div className="grid gap-6 sm:grid-cols-2 lg:grid-cols-3">`).

**Diagnosis (CSS grid stretches cells by default — so why don't the cards stretch?):**

The grid container has default `align-items: stretch`, so each grid CELL is sized to the tallest item in its row. The problem is the tile's internal structure breaks the visual stretch:

```tsx
<Tooltip.Root>                          // renders nothing (context provider)
  <div className="relative">            // ← grid item, will stretch
    <Tooltip.Trigger asChild>
      <Link className="flex p-5 ...">   // ← visible card, NOT stretched
        ...content...
      </Link>
    </Tooltip.Trigger>
    <TouchInfoTrigger />
  </div>
  <Tooltip.Portal>...</Tooltip.Portal>
</Tooltip.Root>
```

`Tooltip.Root` is a React context provider — emits no DOM. So the grid item is the `<div className="relative">`. That div stretches to fill the cell (good). But the visible `<Link>` inside doesn't fill the div — because the div is `display: block` and the Link has no `h-full`. Result: equal-height cells with visually inconsistent cards inside them.

**Fix shape (small, contained):**

- Add `h-full` to the wrapper `<div className="relative h-full">` in both `DashboardTile` and `DashboardAuditCard`.
- Add `h-full` to the inner `<Link>` so it fills the wrapper.
- Verify the card's internal flex layout still works — Link is `flex items-start gap-4`; the icon column + text column will still align at the top, the card just gets taller.
- The DashboardAuditCard is the tallest in row 2 (rows of audit events). With this fix, the Account + Members tiles in the same row will match its height — extra vertical space inside those tiles. Acceptable per Carl's spec.

**Open question for execution:**
- The extra vertical real estate inside the simpler tiles (Credits, Network, Clients, Account, Members) when row-mate Audit is tall — does the tile content stay top-aligned (current `items-start`)? Or center-align so the headline+subtitle sit visually middle? Top-align is the safer default; switch to center only if Carl flags it.

**Test scope:**
- `/dashboard` desktop 3-column: row 1 (Credits / Network / Clients) — all same height. Row 2 (Audit / Account / Members) — all same height as the tallest (Audit).
- 2-column tablet: same rule per row.
- 1-column mobile: each tile its natural height (no row alignment needed at 1 col).

### C-9 — Add "Classes" tile to portal dashboard with "Coming soon" treatment (and explicitly NOT a Workouts tile)

**Source:** Carl, 2026-05-22: "I want us to add, similar to what we did on the mobile app, a classes card and outfit it with the same 'Coming Soon' verbiage. This will just allow us to have the dashboard reflect the reality. The workouts card shouldn't be on the portal because somebody just consuming the product won't use the portal."

**Files:** `web-portal/src/app/dashboard/page.tsx` (add new tile), `web-portal/src/components/DashboardTile.tsx` (likely needs a `disabled` / `comingSoon` variant — see below), possibly a new lucide icon for Classes.

**Why workouts is intentionally excluded:** The portal is the practitioner's admin surface. End consumers (clients) never use the portal — they use the web player at `session.homefit.studio` (and they don't get a workouts dashboard, they get a workout URL). Classes is a practitioner-facing concept (build once, share with many enrollees) — that belongs on the portal. Workouts is consumer-facing (a single plan a client follows) — that doesn't.

**Mobile reference (for parity):**
- `app/lib/widgets/classes_coming_soon_view.dart` — the mobile "Coming Soon" view with three sample mock cards ("Glutes & Hamstrings", "Posture Reset", "Beginner Mobility"), a "Coming soon" pill, and a headline "Build a class once, share it with everyone who buys or [enrolls]".
- `app/lib/screens/home_screen.dart:17, 106, 138` — Scope segmented control includes Classes (locked teaser until ships).

**Portal scope (much smaller than mobile — single dashboard tile, not a full screen):**
- Add one new `<DashboardTile>` to the dashboard grid. Position: end of the grid (after Members, owner-only). Order becomes `Credits · Network · Clients · Audit · Premises · Public profile · Account · Members · Classes`.
- Label: `Classes`
- Headline: `Coming soon`
- Subtitle: `Build once, share with everyone who enrolls`
- Icon: lucide `Layers` or `BookOpen` (suggest `Layers` — visually distinct from `BookOpen` which could read as Audit/log).
- Description tooltip: "A subscription/class library — practitioners build a programme once and enrollees subscribe to follow it. Coming after MVP ships."
- Disabled / non-routing state: the tile should NOT be a clickable Link. Either render as a `<div>` styled like a tile (no chevron, no hover-coral) OR add a `comingSoon` prop to `DashboardTile` that swaps the Link for a div and dims the icon.
- Visual hint: muted ink throughout, no coral hover, opacity ~85% so it reads as "future" not "available". Matches the mobile coming-soon pill aesthetic.

**Implementation choice for `DashboardTile` (decide during execution):**

1. **Add a `comingSoon: boolean` prop** — when true, render as `<div>` not `<Link>`, suppress chevron, drop the `hover:border-brand`, dim the icon. Tooltip still works. One prop, one branch.
2. **Make a new `<DashboardComingSoonTile>` component** — separate component, no Link, no chevron, no tone. Cleaner separation but duplicates the icon+tooltip+layout boilerplate.

Recommend (1) — single prop is a smaller diff and keeps the dashboard's tile inventory in one shape.

**Open questions for implementer:**
- Members tile is owner-only. Classes is universal? Yes — show to all practitioners (owners + practitioners). Future ship will probably gate enrollment fees by owner role, but the teaser tile is non-functional.
- "Coming soon" copy parity with mobile — mobile says "Coming soon" pill; portal says "Coming soon" as headline. Acceptable difference because the portal tile has different real estate.
- Grid order with the new tile: 9 tiles for owners (Credits, Network, Clients, Audit, Premises, Public profile, Account, Members, Classes) = 3 rows of 3 — clean. Non-owners get 8 tiles (Members hidden) = 3 rows where the last has 2 tiles. Acceptable.

**Test scope:**
- `/dashboard` renders a new Classes tile, positioned last (after Members for owners, after Account for non-owners).
- Tile is visually present but NOT clickable. No chevron. Hover reveals tooltip but no coral border.
- Headline reads "Coming soon"; subtitle "Build once, share with everyone who enrolls".
- Workouts tile is NOT present (deliberately).
- Owner + non-owner both see the Classes tile (only Members is gated).

### C-10 — Reorder dashboard tiles (supersedes Q5 grilled order)

**Source:** Carl, 2026-05-22 (reading the order out top-left to bottom-right).

**New order (locked):**
1. Credits
2. Network
3. Clients
4. Members
5. Public profile
6. Premises
7. Account
8. Audit

**Supersedes:** Q5 of the grilling session, which locked `Credits · Network · Clients · Audit · Account · Members`. That order is retired.

**File:** `web-portal/src/app/dashboard/page.tsx` — reorder the JSX of `<DashboardTile>` / `<DashboardAuditCard>` blocks in the grid at line ~253. No component changes needed.

**Implications + open questions to resolve at execution:**

1. **Members at position 4 (was last).** Members is owner-only — the existing `{isOwner && (<DashboardTile ... Members />)}` guard means non-owners see a GAP at position 4. New order for non-owners would be: Credits · Network · Clients · [gap] · Public profile · Premises · Account · Audit = 7 tiles with a hole at index 3 (or the tiles below shift up, which would re-create a 7-tile grid with Public Profile at position 4 etc.). With CSS grid + conditional render, tiles below the hidden Members will naturally reflow into its slot. Confirm Carl is OK with non-owners seeing: `Credits · Network · Clients · Public profile · Premises · Account · Audit` (no Members) as the natural reflow.

2. **Where does the Classes tile (C-9) sit in this order?** Carl read 8 tiles. The Classes "Coming soon" tile from C-9 wasn't placed in the read. Two options for execution:
   - **(a) End — position 9:** `... · Audit · Classes`. Treats Classes as the "future" tile, sits at the visual bottom.
   - **(b) Adjacent to functionally similar tile:** insert next to Clients or Network (whichever it pairs with semantically). Probably not — "Coming soon" reads better at the end.
   - Recommend (a). Confirm during execution if C-9 has been merged by then.

3. **Audit at position 8 (last).** Audit is the multi-row card (tallest tile per C-8's row-alignment fix). Putting it at the END means it always sits alone or with at most 1 row-mate. With 8 tiles in 3 columns, Audit (#8) sits in row 3 with positions 7 (Account) and possibly 9 (Classes if added). Row alignment from C-8 will make Account and Classes match Audit's height. Probably acceptable but worth a visual sanity-check in the mockup.

**Test scope:**
- `/dashboard` owner view: tiles in exact order Credits · Network · Clients · Members · Public profile · Premises · Account · Audit (· Classes if C-9 shipped).
- Non-owner view: Members hidden, tiles reflow naturally.
- Visual: row 3 contains Audit alongside (Account, Classes) which are now match-height per C-8.

### C-11 — Premises page "Add premises" opens a modal — violates R-01 + `feedback_no_popups_ever`

**Source:** Carl, 2026-05-22: "In the newly added premises page, when we add a premise, we broke the rule of not using modal forms. Please can this be corrected when we click on Add Premises?"

**Files (current — modal pattern):**
- `web-portal/src/components/PremisesEditorDialog.tsx` — the modal component. Mounted by PremisesListPanel on "Add premises" click. Contains polygon editor + name + address + Safe Mode fields.
- `web-portal/src/components/PremisesListPanel.tsx` — owns the open/close state of the dialog.
- `web-portal/src/app/premises/page.tsx` — page that hosts the list panel.

**Rules being violated:**
- **R-01** (no modal confirmations / destructive-immediate + undo) — design system rule, see `docs/design/project/components.md`.
- **`feedback_no_popups_ever.md`** — Carl's load-bearing extension: "Creating a new entity (client / session / exercise) never opens a bottom-sheet or modal. Mint with a default placeholder + navigate to detail + inline rename."

**Fix shape (matches the existing client/session/exercise pattern):**

1. **Add an "Add premises" RPC** that mints a default-placeholder premises row server-side:
   - Name: `"New premises"` (or `"Premises {N}"` with N as practice count + 1 for slight differentiation)
   - Polygon: empty / NULL
   - Address: empty
   - `enforced: false` (Safe Mode off by default)
   - Returns the new premises ID
   - File: `supabase/migrations/{ts}_add_premises_default.sql` — `create_default_premises(p_practice_id uuid) RETURNS uuid` SECURITY DEFINER with practice-membership check.
2. **Add a `/premises/[id]` detail route** that hosts the editor (polygon map + name + address + Safe Mode toggle).
   - Same polygon editor component from today's `PremisesEditorDialog` — lift the editor body into a `PremisesEditor` page-level component. The Dialog wrapper goes away.
   - Inline-editable name at the top (dashed-underline pattern, mirroring `EditableClientName` on `/clients/[id]`).
   - Address: inline-editable too, or with a "Search address" input that's part of the page (not popped).
   - Safe Mode toggle: inline.
   - Save: optimistic / autosave on each edit OR explicit "Save" button at the page level (no modal Save/Cancel).
3. **Refactor `PremisesListPanel`**: "Add premises" button → calls RPC → navigates to `/premises/{newId}`. No dialog state. The list rows already link to edit — those should now route to `/premises/[id]` too, not pop a dialog.
4. **Delete `PremisesEditorDialog.tsx`** once nothing imports it.

**Open questions to confirm at execution:**

- Save semantics on the detail page: autosave per-field (mirrors `/clients/[id]` inline rename) OR explicit Save button (matches the polygon editor's "draw, then commit" mental model)? Recommend autosave per-field for name/address/Safe Mode toggle, and an explicit "Save polygon" button INLINE on the map (not in a header bar) for the polygon, because the polygon is a multi-step interaction the user wants to commit deliberately.
- Delete affordance: also can't be a modal confirmation. Use the R-01 undo-snackbar pattern — Delete fires immediately, snackbar lets you undo within 7 days (recycle bin).
- Audit: `practice.premises.created` / `.deleted` / `.updated` events — verify they fire on the new flow too.

**Test scope:**
- `/premises` page: click "Add premises" → no modal opens. Router navigates to `/premises/{newId}` showing the default-placeholder name and an empty polygon editor.
- Inline-rename name at the top works (dashed underline).
- Polygon editor fills the page, not a dialog. Save commits the polygon.
- Address search input is inline on the page.
- Safe Mode toggle is inline.
- "Edit" on an existing premise row in the list also routes to `/premises/{id}`, not a modal.
- Delete uses undo-snackbar, no confirm modal.

**Mobile parity (R-10-ish):** verify the mobile premises management flow doesn't have a modal either. If it does, file as a follow-up (different surface, different PR). Mobile premises capture-time check is GPS-only — the "edit a premises polygon" is portal-only today.
