# 2026-05-25 — Portal back-arrow hoist into top bar

**Branch:** `chore/portal-back-arrow-into-topbar` (off `staging`)
**Target:** `staging`
**Surface:** `manage.homefit.studio` (web portal only — no mobile, no player)

## What changed

The per-page `<- Home` / `<- Premises` / `<- Credits` back link that
previously rendered as inline JSX below the top bar on 12 pages has
been **hoisted into the top bar's left slot**, mirror-symmetric to the
right-side identity cluster. The inline block has been deleted from
every page; the page title now sits directly under the header with
normal top spacing.

A new client component `HeaderBackLink` owns the route-to-target map
(`/premises -> /dashboard`, `/network -> /credits`, etc.) and reads
`usePathname()` to decide what to render. Routes not in the map render
nothing in the left slot. The active `?practice=<id>` query param is
preserved across the back nav.

## How to test

Open `manage.homefit.studio` (or the Vercel preview URL for this PR)
in a Safari/Chrome window — signed in.

### Pages with back arrow in the top bar (12)

For each page below: the **`<- Home`** (or `<- Premises` / `<- Credits`)
link appears in the **left of the top bar**, on the same vertical line
as the right-side `Signed in as ... / In practice ...` cluster. The
inline `<- ...` link that used to sit below the page title is **gone**.
The page title sits directly under the header.

- [ ] `/premises` — left of top bar shows `<- Home`. No inline link below the title.
- [ ] `/premises/{any-id}` — left of top bar shows `<- Premises` (NOT `<- Home`). Click it and land on `/premises`.
- [ ] `/public-profile` — left of top bar shows `<- Home`.
- [ ] `/safe-mode` — left of top bar shows `<- Home`.
- [ ] `/privacy` — left of top bar shows `<- Home`.
- [ ] `/getting-started` — left of top bar shows `<- Home`.
- [ ] `/members` — left of top bar shows `<- Home`. (Owner-only page.)
- [ ] `/terms` — left of top bar shows `<- Home`.
- [ ] `/credits` — left of top bar shows `<- Home`.
- [ ] `/help/credits` — left of top bar shows `<- Home`.
- [ ] `/account` — left of top bar shows `<- Home`.
- [ ] `/network` — left of top bar shows `<- Credits` (NOT `<- Home`). Click it and land on `/credits`.

### Practice-context preservation

- [ ] Switch to a non-default practice (right-side switcher). Navigate to `/credits`. The URL now reads `/credits?practice=<id>`. Click the back arrow — destination URL is `/dashboard?practice=<id>` (same practice id preserved).

### Pages with NO back arrow

- [ ] `/dashboard` — left slot of top bar is **empty**. No back arrow rendered.
- [ ] `/` — same: empty left slot (the root redirects to `/dashboard` for signed-in users; the dashboard shows no back arrow).
- [ ] `/clients` — left slot is empty (not in scope; no back link added).
- [ ] `/clients/{id}` — left slot is empty.

### Regression checks (must still work)

- [ ] `/audit` page: the `<- Prev` button at the bottom-left of the audit table (pagination) **still works**. Click it on page 2 → returns to page 1. This is pagination, not the hoisted back link — must be untouched.
- [ ] Right-side identity cluster: `Signed in as ... / In practice ... / Sign out` still renders correctly on every authenticated page. The practice switcher chevron still opens its popover and lets you switch practice.
- [ ] Centered brand lockup: still centered horizontally in the header on every page. Back arrow on the left + identity stack on the right do not push the brand off-center.

### Mobile responsive

- [ ] Narrow viewport (iPhone width, ~390px): the back arrow remains visible and tappable in the top bar. The brand lockup may shrink or wrap, but the back arrow is still reachable.

### Visual smoke

- [ ] The back arrow uses the same font + colour family as the right-side identity text (`text-xs text-ink-muted`, hover → `text-brand`). No visual mismatch.
- [ ] No leftover ~80px gap between the header and the page heading on the 12 changed pages. The headings sit immediately below the header bar.
