# Live view cosmetic + functional pass — 2026-05-23

Stack items 15-19 (per `docs/test-scripts/2026-05-23-stack.md` LOCKED
DECISIONS block). Ships as one PR against `staging`. Three surfaces
touched: web player, web portal premises editor, Supabase migration +
edge function.

**Branch:** `feat/live-view-cosmetic-pass-2026-05-23`
**Pre-deploy on Carl:** `supabase secrets set MAPBOX_TOKEN=<value> --project-ref vadjvkmldtoeyspyoqbx` on staging.

Open the live page in mobile Safari at a known-good staging URL:
`https://staging.session.homefit.studio/v/<practice-slug>/<premises-slug>/now`.

Strike items with `~~text~~` once they pass.

## Table of Contents

- [Pre-flight](#pre-flight) — items 1-2
- [Item 15 — top-right brand lockup](#item-15--top-right-brand-lockup) — items 3-5
- [Item 16 — practice mark (logo vs initials)](#item-16--practice-mark-logo-vs-initials) — items 6-9
- [Item 17 — dynamic hero + consolidation](#item-17--dynamic-hero--consolidation) — items 10-14
- [Item 18 — footer lockup](#item-18--footer-lockup) — items 15-16
- [Item 19 — satellite snapshot](#item-19--satellite-snapshot) — items 17-23
- [Failure modes](#failure-modes) — items 24-26

## Pre-flight

- [ ] **1.** PR merged to `staging`; Vercel deploy on `staging.session.homefit.studio` shows the new build SHA.
- [ ] **2.** Supabase Branching applied the migration (or the staging branch was rebased + the migration applied via MCP / dashboard). `practice_premises.snapshot_url` exists; `get_live_sessions` returns two new columns.

## Item 15 — top-right brand lockup

- [ ] **3.** Open the live page. Top-right corner shows the canonical homefit.studio lockup (matrix + wordmark) — NOT a hand-rolled 11-pill matrix-only.
- [ ] **4.** "powered by" caption sits to the LEFT of the lockup, inline, lowercase, tight gap (~8px).
- [ ] **5.** Wordmark colour split is right: `homefit` near-white (#F0F0F5), `.studio` (including the dot) coral (#FF6B35).

## Item 16 — practice mark (logo vs initials)

- [ ] **6.** Practice without an uploaded logo: top-left mark renders TWO-letter initials. "Muscle Works Gym" → `MW`; "QA Test Practice" → `QA`; single-word practice "Studio" → `ST` (first two characters).
- [ ] **7.** Practice WITH an uploaded logo (visit portal `/public-profile`, upload one, save, then refresh the live page): mark renders the logo image, NOT initials.
- [ ] **8.** Logo aspect respected: a wide / rectangular logo is letterbox-fit via `object-fit: contain` inside the 44×44 box; no auto-cropping. A square logo fills the box.
- [ ] **9.** Bad logo URL (manually set `public_logo_url` to a 404 path via SQL → reload): the `<img>` error fallback kicks in and initials render instead of a broken-image icon.

## Item 17 — dynamic hero + consolidation

- [ ] **10.** With ZERO active capture sessions: headline reads "Nobody is recording right now". Dot is muted-grey, no pulse.
- [ ] **11.** With ONE active capture session: headline reads "1 person is recording right now". Coral pulsing dot.
- [ ] **12.** With TWO+ sessions: headline reads "{N} people are recording right now" (e.g. "3 people are recording right now"). Coral pulsing dot.
- [ ] **13.** Below the map, the OLD "Nobody is recording right now" empty-state block is GONE. The map + cards stand on their own.
- [ ] **14.** The "What is Safe Mode?" explainer card now has an inline URL line below the paragraph: "What is Safe Mode? — manage.homefit.studio/safe-mode" (em-dash, plain text, no button chrome). Tap the URL → opens the portal `/safe-mode` page in a new tab.

## Item 18 — footer lockup

- [ ] **15.** Bottom of page: the canonical lockup (same as item 15) rendered centred, same scale (64px wide). Page is bookended by two identical marks.
- [ ] **16.** No "powered by" caption next to the bottom mark — the centred lockup stands alone (the top mark already has the caption).

## Item 19 — satellite snapshot

- [ ] **17.** With MAPBOX_TOKEN set on staging Supabase + a premises that has had its polygon edited since the migration applied: the map section shows a SATELLITE-IMAGERY background (Mapbox satellite-streets-v12 tiles), with the polygon overlaid as a dashed coral outline.
- [ ] **18.** Practitioner cards float at their GPS positions ON TOP of the satellite tile (NOT under it). Sage "you are here" dot also overlays.
- [ ] **19.** Snapshot fade-in is smooth — 200ms transition when the image loads, no flicker.
- [ ] **20.** Edit the polygon in the portal (premises editor → drag a vertex → Save polygon) → wait ~5 seconds → reload the live page. The satellite snapshot reflects the new polygon (auto-regen trigger fired).
- [ ] **21.** Open premises editor → click "Regenerate satellite snapshot" button (visible only when polygon already saved). Toast: "Snapshot refresh dispatched." Reload live page after ~5 seconds; snapshot is fresh.
- [ ] **22.** Non-owner member opens the same editor → clicks the button → error message: "You don't have permission on this practice." (42501 mapping).
- [ ] **23.** Draft premises (no polygon yet) does NOT show the "Regenerate satellite snapshot" button. The whole row is suppressed for draft rows.

## Failure modes

- [ ] **24.** Temporarily unset MAPBOX_TOKEN secret on staging → trigger a polygon edit → reload live page. Snapshot column comes back NULL; live page gracefully falls back to the polygon-only grid SVG. NO broken-image icon, no JS error.
- [ ] **25.** Mapbox returns a 5xx (simulate by setting MAPBOX_TOKEN to an obviously-bad value like `pk.test_bad`): edge function logs `mapbox-error`, snapshot_url stays NULL, live page falls back gracefully.
- [ ] **26.** With the snapshot loaded successfully, manually open Safari devtools → Network → set the snapshot URL to "Block resource". Reload. Snapshot fails to load; `onerror` handler hides the `<img>` and the polygon-only grid background re-renders.

## Operator notes (post-merge, Carl-side)

After the PR merges to `staging`:

1. **Set MAPBOX_TOKEN** on the staging Supabase project (one-time):
   ```
   supabase secrets set MAPBOX_TOKEN=<your-mapbox-public-token> --project-ref vadjvkmldtoeyspyoqbx
   ```
   Use a token scoped to `styles:read + tiles:read` only.

2. **Deploy the edge function** to staging:
   ```
   supabase functions deploy regen-premises-snapshot --project-ref vadjvkmldtoeyspyoqbx
   ```

3. **Trigger first snapshot** for one of the existing premises (so item 17 has something to display): visit the portal premises editor → click "Regenerate satellite snapshot". The first edit to any polygon also auto-fires.

4. **Promote to main** when staging QA passes — same MAPBOX_TOKEN + edge function deploy steps against prod project ref.
