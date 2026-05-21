# Public Profile v2 — design

**Status:** approved 2026-05-21 (Carl) · ready for implementation plan
**Mockup:** [docs/design/mockups/public-profile-v2.html](../design/mockups/public-profile-v2.html)
**Predecessor:** PR #389 (Safe Mode + minimal public profile) introduced the `/v/{slug}` page and the `practices.public_*` columns. This design supersedes the editor surface and expands the public-facing page from utilitarian to advertising-grade.

## Table of contents

- [Purpose](#purpose)
- [Scope summary](#scope-summary)
- [Data model](#data-model)
- [Page IA + dashboard tile](#page-ia--dashboard-tile)
- [Web Player cascade](#web-player-cascade)
- [Edit-page UX](#edit-page-ux)
- [Migration plan](#migration-plan)
- [Testing](#testing)
- [Risks](#risks)
- [Out of scope for V1](#out-of-scope-for-v1)

## Purpose

Two product needs converge:

1. **White-label / co-brand the client-facing Web Player per practice.** A practice can upload their own logo and pick a brand color. Their clients open `session.homefit.studio/p/{planId}` and see the practice's logo in the persistent top-bar throughout the session, with every coral accent on the player re-tinted to the practice's color. The "powered by homefit.studio" wordmark stays in the player footer — this is co-brand, not full white-label.
2. **Promote the public profile from a buried `/premises` section to a dashboard-surfaced page that reads as an advertising page.** A practice gets a one-line tagline, a richer blurb, a list of specialties, contact methods (email + WhatsApp + a hero CTA to their own website), a "who you'll see" section of practitioners, and the existing premises list. The page is the practice's public face on homefit.studio.

Both editor surfaces live on a single new page at `/public-profile?practice=<uuid>`. The page gets its own dashboard tile.

## Scope summary

- Six new columns on `practices`. No new tables. PostGIS not involved.
- New portal page `/public-profile` (owner-edit, member-view, non-member 404).
- New dashboard tile **Public Profile** between Clients and Credits.
- Existing `/premises` page loses its "Public profile" `<details>` block — `/premises` becomes purely polygons.
- Existing `set_practice_public_profile` RPC widens its parameter list to accept the new fields. Existing `get_practice_profile` (anon) widens its return shape. Existing `get_plan_full` (anon) gains `brand_color` + `public_logo_url` in its return shape so the Web Player can cascade them at render time.
- Web Player CSS variables `--c-brand` + `--c-brand-soft` + `--c-brand-strong` adopted everywhere coral currently hard-codes `#FF6B35`. Each literal becomes `var(--c-brand)`. Practice-set brand color writes to these variables at page-load. Implementation plan will enumerate the exact occurrences.
- New hero CTA + new top-bar logo slot on the Web Player.
- Mobile Studio's Preview tab + the workflow Preview step take the same change (R-10 parity).
- One Supabase migration; one PR spans portal + player + Flutter mobile twin.

## Data model

Single migration adds six columns to `public.practices`. No defaults — NULL is the "not configured" sentinel.

```sql
ALTER TABLE public.practices
  ADD COLUMN brand_color text,            -- hex '#RRGGBB'; NULL = default coral
  ADD COLUMN tagline text,                -- short marketing one-liner, ≤ 60 chars
  ADD COLUMN specialties text[],          -- 0-8 free-form chips
  ADD COLUMN contact_email text,          -- mailto: target
  ADD COLUMN contact_whatsapp text,       -- E.164 normalized server-side
  ADD COLUMN contact_website text;        -- https:// only
```

Constraints (added in the same migration):

- `brand_color ~ '^#[0-9A-Fa-f]{6}$'` — 6-digit hex format. 3-digit shorthand and named colors are rejected; the editor uses an HTML5 `<input type="color">` which always returns 6-digit.
- `length(tagline) <= 60` — keeps the hero readable on phones.
- `array_length(specialties, 1) <= 8` — keeps the chip row from sprawling.
- `length(contact_email) <= 120`, `length(contact_whatsapp) <= 20`, `length(contact_website) <= 200`.

Reused columns (no migration impact):

| Column | New purpose |
| --- | --- |
| `practices.name` | Hero practice name + Web Player top-bar logo `alt` text |
| `practices.public_slug` | `/v/{slug}` URL, dashboard tile sub-link |
| `practices.public_blurb` | Hero blurb (the 280-char paragraph beneath the tagline) |
| `practices.public_logo_url` | **Both** the public profile hero AND the Web Player top-bar logo (same file, same URL) |
| `practices.public_profile_listed` | Whether `/v/{slug}` resolves (404 when false) |

Practitioner avatars on the public page pull from existing `practice_members` rows + each member's display name. V1 has no per-member opt-out (added later if needed via `practice_members.show_in_public_profile boolean`).

## Page IA + dashboard tile

### Page route

`/public-profile?practice=<uuid>` — new top-level portal route. Owner edits, member views, non-member redirects to `/dashboard`.

The existing "Public profile" `<details>` block on `/premises` is removed by this PR. `/premises` becomes purely about polygons.

### Page structure

Two `<details>` accordions, both collapsed by default. The deep-link route can pre-expand one of them via `?section=branding` or `?section=identity` so the dashboard tile's two sub-links land the practice in the right block.

```
/public-profile?practice=…

← Dashboard

Public profile
What clients see at session.homefit.studio/v/{slug}
[ Preview your page →  (opens /v/{slug} in new tab) ]

▸ Branding                              (collapsed by default)
▸ Identity & directory                  (collapsed by default)
```

### Dashboard tile

New "Public Profile" tile in the dashboard grid. Placed prominently — exact position decided in the implementation plan against the current tile order. Live state surfaced in the tile body:

- **Configured state** (≥ 1 of {brand_color, public_logo_url, tagline, specialties, contact_*} set):
  ```
  Public Profile
  {practice_name} · {N} fields set
  session.homefit.studio/v/{slug} →
  ```
  The URL line is a separate click target — opens `/v/{slug}` in a new tab without leaving the dashboard.
- **Empty state** (no public-facing fields set yet):
  ```
  Public Profile
  Not configured · set your branding & directory listing
  ```

The tile itself routes to `/public-profile?practice=<uuid>`.

## Web Player cascade

How the practice's branding reaches the client-facing player surface.

### RPC widening

`public.get_plan_full(p_plan_id)` is an anon-readable SECURITY DEFINER RPC. Its `RETURNS TABLE` is widened to include:

```
brand_color       text   -- nullable
public_logo_url   text   -- nullable
practice_name     text   -- already present via legacy column; surface in alt text
```

Every existing column in the RPC's `RETURNS TABLE` is carried forward verbatim per the schema-migration-column-preservation rule (see CLAUDE.md gotchas + `pg_get_functiondef` pre-flight).

These fields are not sensitive — they are already publicly readable via `/v/{slug}`. Widening `get_plan_full` does not broaden access; it just saves a round-trip.

### CSS variables

`web-player/styles.css` defines coral usage in many places, currently mixing literal `#FF6B35` and `var(--c-brand)`. This PR migrates every literal to the variable so brand-color overrides cascade uniformly:

```css
:root {
  --c-brand: #FF6B35;                       /* default; overridden at runtime */
  --c-brand-soft: rgba(255, 107, 53, 0.18); /* default; overridden at runtime */
  --c-brand-strong: rgba(255, 107, 53, 0.9);
}
```

`web-player/app.js` (after the plan payload arrives, before paint):

```js
if (plan.brand_color) {
  const root = document.documentElement;
  root.style.setProperty('--c-brand', plan.brand_color);
  root.style.setProperty('--c-brand-soft', toRgba(plan.brand_color, 0.18));
  root.style.setProperty('--c-brand-strong', toRgba(plan.brand_color, 0.9));
}
```

Sage rest color is unchanged — it is a semantic category, not a brand accent.

### Top-bar logo

The player's plan bar (row 1 of the layout, currently shows `clientName / planTitle`) gains a logo slot to the left of that text:

```html
<header class="plan-bar">
  <img class="plan-bar-logo" src="{public_logo_url}" alt="{practice_name} logo"
       onerror="this.style.display='none'">
  <div class="plan-bar-text">…</div>
</header>
```

CSS: `max-height: 32px; object-fit: contain;` — handles square and landscape logos. Fixed slot whether or not the logo is present so layout doesn't shift between practices that have/haven't uploaded.

Landscape orientation: the logo stays in the same horizontal position.

### Mobile twin (R-10)

Same change in `app/lib/screens/plan_preview_screen.dart` (the workflow Preview step that embeds the player) AND in Studio's Preview tab. Brand color injected into the Flutter `ThemeData` extension; logo rendered in the equivalent header slot. Per R-10 both surfaces ship in the same PR.

### Fallback ordering

1. `brand_color` is set → use it. Else fall back to `#FF6B35`.
2. `public_logo_url` is set AND the file loads → render it. Else: `onerror` removes the `<img>` and the bar's text slides into the freed space.
3. The "powered by homefit.studio" wordmark in the player footer is unchanged — the co-brand promise from the design.

## Edit-page UX

The owner's view of `/public-profile`.

### Branding section (when expanded)

- **Logo upload** — drag-and-drop zone OR "choose file" button. Accepts PNG / JPG / SVG ≤ 1 MB. On drop: upload to `media/branding/{practice_id}/logo.{ext}` (overwrites old). Server stamps `practices.public_logo_url`. Inline thumbnail with **Replace** + **Remove** buttons. No modal.
- **Brand color** — HTML5 `<input type="color">`. To the right: a "Reset to coral" link that clears `brand_color` to NULL.
- **Live preview strip** — a 100px-tall mockup of the player's pill matrix + active pill + a sample "Workout starts in 5" countdown. Re-tints in real time as the picker scrubs, so the practice sees the cascade before they save.
- **Contrast warning** — if the chosen color fails WCAG AA against `#0F1117`, a small grey note: `Tip: this color may be hard to read on dark surfaces.` Not a block — the practice can save regardless.

### Identity & directory section (when expanded)

- **Practice name** — inline-editable (dashed underline pattern, matches client name on `/clients/[id]`).
- **Tagline** — 60-char hard cap. Character counter goes red at 50.
- **Blurb** — 280-char hard cap. Counter goes red at 250 (existing pattern preserved).
- **Specialties** — chip editor: type + Enter to add, X on each chip to remove. Max 8 chips.
- **Email**, **WhatsApp**, **Website** — separate input rows. WhatsApp normalized to E.164 server-side. Website validated `https://` prefix client-side; server rejects non-https.
- **Slug** — same validation as today (`^[a-z0-9](?:[a-z0-9-]{1,38}[a-z0-9])?$`).
- **List in directory** — same boolean toggle as today. Separate concern from branding (a practice can be unbranded but listed, or branded but unlisted).

### Save flow

Single **Save** button at the bottom of each section. Explicit, not auto-save — in case a session timeout swallows half a save. After save:

- Success → inline pill `Saved · {time}` fades after 3s. No modal, no SnackBar, no nav redirect.
- Failure → red inline message with what went wrong.

### Permission UX

Non-owner members can VIEW the page but inputs are disabled with an info note: `Only the practice owner can edit branding & profile.`

### Default expand on deep-link

`/public-profile?practice=…&section=branding` pre-expands Branding. `&section=identity` pre-expands the other. The dashboard tile uses these query params so a click lands the practice on the right block. Subsequent visits remember the last collapsed state per-section via `localStorage`.

## Migration plan

Single migration file: `supabase/migrations/20260521150000_public_profile_v2.sql`.

Sections:

1. `ALTER TABLE public.practices ADD COLUMN IF NOT EXISTS …` for the six new fields.
2. `ALTER TABLE … ADD CONSTRAINT …` for the six check constraints.
3. `CREATE OR REPLACE FUNCTION public.set_practice_public_profile(...)` — expanded parameter list, preserves all existing columns in the function body per the column-preservation rule.
4. `CREATE OR REPLACE FUNCTION public.get_practice_profile(...)` — widened `RETURNS TABLE` to include all new fields. Existing columns preserved verbatim.
5. `CREATE OR REPLACE FUNCTION public.get_plan_full(...)` — adds `brand_color` and `public_logo_url` to its `RETURNS TABLE`. Existing columns preserved verbatim.
6. Storage policy: the existing `media` bucket's INSERT policy already allows writes to `{practice_id}/...` prefixes by practice members. Confirm coverage extends to `branding/{practice_id}/logo.*`; add a policy clause if it doesn't.

Rollout — single PR; portal + player + Flutter changes are interdependent and the migration is additive:

1. Migration applies on staging via Supabase Branching → adds NULL columns + updated RPCs.
2. Vercel rebuilds portal (new `/public-profile` page, new dashboard tile) → unset fields render as if they weren't there.
3. Vercel rebuilds web player → falls back to coral + matrix when columns are NULL.
4. Flutter ships in the same PR for R-10 parity. Lands on the next TestFlight cycle.

## Testing

A new section J appended to the active wave's test script (`docs/test-scripts/2026-05-21-safe-mode.md` since this design ships into the same wave; if the wave closes first, J becomes the first section of a new wave file):

1. Open `/public-profile` with no fields set → page renders, both sections expand on click, hero shows coral fallback + initials.
2. Set `brand_color` to `#10B981` → live preview strip tints immediately to green; Save → revisit `/v/{slug}` shows green tagline + green hero CTA border + green Safe Mode badges.
3. Open an existing published plan in the web player → coral elements are now green (active pill, prep countdown, treatment switcher active border, timer chip).
4. Upload a square logo (PNG, 256×256) → appears in the hero AND in the player's top-bar within ~1s.
5. Upload a landscape logo (SVG, 500×120) → renders correctly in both surfaces (CSS `object-fit: contain` handles the aspect change).
6. Fill every contact field → hero shows the website CTA, contact list shows email + WhatsApp rows.
7. Toggle `public_profile_listed` off → `/v/{slug}` returns "Practice not found"; toggle back on → page reappears with all fields intact.
8. Non-owner member view → all inputs disabled, info note visible, Save buttons absent. `/v/{slug}` still readable.
9. Migration cleanly applies on the existing Postgres 17 CI job.
10. Dashboard tile reflects "{N} fields set" correctly after each save.

## Risks

- **NULL fallback paths are load-bearing** — every existing practice has NULL for all six new columns at migration time. All player + page paths must handle NULL silently. Tested via #1, #3, #6.
- **`get_plan_full` is anon-readable** — the brand_color and public_logo_url widening is OK because both are already public via `/v/{slug}`. Not broadening access.
- **`get_plan_full` column preservation** — the column-shadowing trap (see `gotcha_42702` family of memory entries) bites RPCs with OUT columns. The implementation plan's first step is `pg_get_functiondef` on the live RPC to capture every existing column in the return shape.
- **Logo upload bucket policy** — `media` is public-read but path-scoped on write. Confirm the new `branding/{practice_id}/` prefix is covered by the existing INSERT policy before merging; add a clause if not.
- **Brand color contrast** — practitioners can pick low-contrast colors. We surface a tip but do not block. If a practice's player looks broken, we have one direction to point them.
- **Existing `set_practice_public_profile` RPC** — already in production. Renaming parameters or reordering would break the portal. New params append to the end of the signature; existing params keep their position.

## Out of scope for V1

Parking lot for follow-on iterations once the V1 ships and we have usage signal:

- Per-member visibility toggle on the public profile (`practice_members.show_in_public_profile`).
- Light-mode brand variants (separate logo + color for white surfaces — irrelevant today since both portal + player are dark-only).
- Custom domain for the public profile (`profile.{practicedomain}.co.za`).
- Versioning + audit history of branding changes.
- Multi-language tagline + blurb.
- Auto-generated OG image per practice for WhatsApp link previews of `/v/{slug}` (currently uses a generic homefit lockup; could blend in the practice's logo + brand color).
- A `/find` directory page listing many practices side-by-side (the "marketplace" purpose I floated in brainstorming).
