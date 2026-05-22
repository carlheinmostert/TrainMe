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
