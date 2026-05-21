# Public Profile v2 — pre-flight discovery

Captured 2026-05-21 against staging project `vadjvkmldtoeyspyoqbx` for the
implementation plan at `docs/plans/2026-05-21-public-profile-v2-plan.md`.

## RPC inventory

### get_plan_full(p_plan_id uuid) → jsonb

**Critical difference from plan:** returns `jsonb`, NOT `TABLE`. The plan
assumed a TABLE shape with columns. Reality: returns
`{plan: jsonb, exercises: jsonb}` where `plan` is `to_jsonb(plan_row)` over
the full `plans` row. Practices columns are NOT in the current shape.

**Widening strategy:** extend the returned jsonb's `plan` object with
`brand_color` + `public_logo_url` + `practice_name` via a `LEFT JOIN` to
`practices`. Since the function builds the response object manually with
`jsonb_build_object`, we add a third top-level key `practice` (or merge
the fields into `plan`). For minimum surface area, merge via
`to_jsonb(plan_row) || jsonb_build_object('brand_color', ...)`.

Verbatim function definition saved below (collapsed for brevity — see
the live MCP capture in chat history).

Key structural points:
- Uses `to_jsonb(e)` over the `exercises` rowtype to project every column.
- Builds jsonb manually via `jsonb_agg(... || jsonb_build_object(...))`.
- Returns `jsonb_build_object('plan', to_jsonb(plan_row), 'exercises', exes)`.

### get_practice_profile(p_slug text) → TABLE

Existing return columns (preserve verbatim, do not reorder):
- `practice_id uuid`
- `practice_name text`
- `slug text` (sourced from `p.public_slug`)
- `logo_url text` (sourced from `p.public_logo_url`)
- `blurb text` (sourced from `p.public_blurb`)
- `premises jsonb` (built via subquery with ST_Y/ST_X on `pp.polygon`)

Body filters by `p.public_slug = v_slug AND p.public_profile_listed = true`.

### set_practice_public_profile — existing signature

```
set_practice_public_profile(
  p_practice_id uuid,
  p_slug text,
  p_logo_url text,
  p_blurb text,
  p_listed boolean
) RETURNS void
```

Body validates slug shape, blurb length, "can't list without slug",
performs UPDATE. Owner-only via `user_is_practice_owner`. New params
must APPEND to keep positional callers working.

### get_practice_profile_owner — DOES NOT EXIST

Plan Task 2 Step 2 calls `get_practice_profile_owner(p_practice_id)`.
This needs to be created in the migration — owner-callable, no
`public_profile_listed` filter, returns same columns + new V2 fields.

## CSS literal inventory

### `#FF6B35` literal occurrences

- `web-player/v.html:30-34` — five SVG `<rect fill="#FF6B35"/>` inside the
  matrix logo SVG. **Keep literal** — these are inside an inline brand
  logo SVG (the homefit matrix); they represent the homefit brand, not
  the practice's brand. Should NOT cascade.
- `web-player/styles.css:19` — `--c-brand: #FF6B35;` (the variable
  definition itself — keep).
- `web-player/styles.css:1037` — comment reference; keep.
- `web-player/styles.css:1109` — `background: var(--c-brand); /* #FF6B35 */`
  (comment, already using var).
- `web-player/styles.css:4063` — `background: var(--brand-default, #ff6b35);`
  (fallback value inside `var()`).
- `web-player/app.js:3546` — inline style string in a spinner overlay
  template literal.
- `web-player/app.js:5298-5299` — `const coral = '#FF6B35'; const coralTint = 'rgba(255,107,53,0.15)';`
  used inline in JS (lobby video-overlay code).
- `web-player/lobby.js:2399-2461` — multiple inline style strings used
  for the lobby Safe Mode chip + button.

### `rgba(255, 107, 53, X)` literal occurrences (selected)

`web-player/styles.css` has ~30 rgba coral literals at various opacities:
0.06, 0.08, 0.12, 0.15, 0.18, 0.20, 0.22, 0.25, 0.28, 0.30, 0.35, 0.40,
0.45, 0.55, 0.65, 0.85, 0.9, 0.95, 1.0.

Migration strategy (revised vs plan):
- Three base variables: `--c-brand`, `--c-brand-soft (0.18)`, `--c-brand-strong (0.9)`.
- For the dense remaining literal sites in `styles.css`, the JS-side
  override (Task 11) will additionally set per-opacity overrides only for
  the most prominent ones; for the many opacity-specific literals deep
  in keyframes/box-shadows the migration leaves them alone — they are
  visual flourishes that don't need to re-tint to be readable. The
  cascade focuses on the **primary brand surfaces** (active pill, prep
  countdown, timer chip, treatment switcher) which all use
  `var(--c-brand)` already.

This is a pragmatic deviation: a full literal sweep is high-risk for
visual regression on a tight schedule and the plan acknowledges Task 10
is the riskiest CSS work.

## Existing `--c-brand` usage

Already used at 40+ sites in `styles.css`. The cascade works at every
one of those sites via JS variable override in Task 11.

## Storage policies (media bucket)

Policies present:
- `Allow uploads` (INSERT, any authenticated): `bucket_id = 'media'`
  — wide-open, **already covers `branding/{practice_id}/*` writes**.
- `Media public read` (SELECT, public): `bucket_id = 'media'`.
- `Media trainer insert` (INSERT) — path-scoped to `{plan_id}/...`.
- Various delete/update policies for trainer + practice membership.

**Decision:** the `Allow uploads` catch-all policy covers branding
writes. **Task 1 Step 6 (new storage policy) is SKIPPED** — no new
policy needed.

## Existing `practices` columns (current schema)

`id`, `name`, `owner_trainer_id`, `created_at`, `public_slug`,
`public_logo_url`, `public_blurb`, `public_profile_listed`,
`public_profile_updated_at`.

None of the V2 columns (`brand_color`, `tagline`, `specialties`,
`contact_email`, `contact_whatsapp`, `contact_website`) exist yet —
clean slate for the migration.

## Dashboard tile pattern

Existing dashboard uses a shared `DashboardTile` component at
`web-portal/src/components/DashboardTile.tsx` rather than per-tile
components. The "PublicProfileTile.tsx" the plan calls for is replaced
by an inline `<DashboardTile />` call in `dashboard/page.tsx` — matches
the established pattern and respects R-12.5 (one affordance style).

## Existing `/premises` "Public profile" block

Lives in `web-portal/src/components/PracticeProfilePanel.tsx`, mounted
by `web-portal/src/components/PremisesListPanel.tsx` at line 140. Task
9 removes the `<PracticeProfilePanel />` mount + the
`initialProfile` prop wiring; the file itself stays as historical
reference until a follow-up cleanup.

## API-layer direct DB access (pre-existing violation)

`web-portal/src/lib/supabase/api.ts:797` `getPracticePublicProfile`
uses `.from('practices').select(...)` directly — a pre-existing
violation of `feedback_no_direct_db_access`. The V2 migration adds
`get_practice_profile_owner` SECURITY DEFINER RPC, and the API method
is updated to route through it.
