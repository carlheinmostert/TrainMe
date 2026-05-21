# 2026-05-21 — Coordination checkpoint

**Status as of writing:** Safe Mode QA wave in progress (most items passed); Public Profile v2 sub-agent executing in background; Safe Mode completion spec+plan queued for after V2 lands.

## Table of contents

- [What landed today on staging](#what-landed-today-on-staging)
- [What's in flight](#whats-in-flight)
- [What's queued](#whats-queued)
- [When you come back: one-shot consolidated test](#when-you-come-back-one-shot-consolidated-test)
- [Decisions you made today](#decisions-you-made-today)
- [References](#references)

## What landed today on staging

Eight PRs merged across the day, all on `staging`:

| PR | Commit | What |
|---|---|---|
| #389 | `29ed42c` | Safe Mode Phase 1 + Phase 2 (schema, portal `/premises`, mobile capture pipeline, native Swift `SafeModeProcessor`) |
| #390 | `c320779` | Premises editor unblocks — tile render fix, Nominatim autocomplete, disable hint, 42702 `list_practice_premises` hotfix |
| #391 | `1ca1ce4` | CSP allow OSM tiles + Nominatim |
| #392 | `27829ec` | Permissions-Policy `geolocation=(self)` + map auto-pan on geo resolve |
| #393 | `f24aab6` | Drop strict `countrycodes=za` filter + "Use my location" button |
| #394 | `ac6cb1c` | Photon parallel geocoder + Esri satellite layer |
| #395 | `4512c68` | Address dropdown anchor fix + Edit-mode polygon render race fix |
| #396 | `09ee6c6` | Top-of-page nav progress bar (portal) |
| #397 | `b4e042b` | Polygon vertex drag fix |
| #398 | `2a8621f` | Map zoom holds on layer switch |

Staging tip (after all merges): `2a8621f` (latest at coordination-doc writing). Public Profile v2 PR will land on top once the agent completes.

## What's in flight

**Public Profile v2 sub-agent** — `feat/public-profile-v2` branch.
- Checkpoint 1: ✅ Migration written + locally validated.
- Checkpoint 2: ✅ Portal page + 6 components + types extended.
- Checkpoint 3: ⏳ Web Player CSS variable migration + cascade + top-bar logo.
- Checkpoint 4: ⏳ Flutter mobile twin + test section J + PR.

Plan: [docs/plans/2026-05-21-public-profile-v2-plan.md](plans/2026-05-21-public-profile-v2-plan.md) (17 tasks total).
Spec: [docs/specs/2026-05-21-public-profile-v2-design.md](specs/2026-05-21-public-profile-v2-design.md).
Mockup: [docs/design/mockups/public-profile-v2.html](design/mockups/public-profile-v2.html).

Estimated remaining wall time: 1.5-2.5 hours.

## What's queued

**Safe Mode completion sub-agent** — `feat/safe-mode-completion` branch, **dispatched manually after Public Profile v2 PR merges**.

Closes the 6 parking-lot items from PR #389:
1. Upload swap (safe.mp4 replaces raw.mp4 in cloud; local archive keeps original)
2. Audit stamping at publish (`safe_mode_active` + `captured_in_premises_id` on `exercises`)
3. Photo Safe Mode (single-frame native pass)
4. Fail-closed UX (5% Vision miss-rate cap, reject + auto-discard + inline toast)
5. SQLite v43 `safe_raw_file_path` column for crash recovery
6. CLAUDE.md update folding Safe Mode in

Spec: [docs/specs/2026-05-21-safe-mode-completion-design.md](specs/2026-05-21-safe-mode-completion-design.md).
Plan: [docs/plans/2026-05-21-safe-mode-completion-plan.md](plans/2026-05-21-safe-mode-completion-plan.md) (8 tasks).

Estimated wall time once dispatched: 1.5-2.5 hours.

## When you come back: one-shot consolidated test

Open **[docs/test-scripts/2026-05-21-safe-mode.md](test-scripts/2026-05-21-safe-mode.md)** in the Claude Code preview pane (Cmd+Shift+V). That file is the single source of truth. By the time both sub-agents finish, it will contain:

- **Section B** (Portal — Premises page, items 6-20) — mostly passed today; only 11 (right-click vertex remove) untested.
- **Section C** (Portal — Public profile section, items 21-30) — passed today; this section will get displaced by **Section J** once V2 lands (V2 redesigns where Public Profile lives).
- **Section D** (Web player `/v/{slug}`, items 31-40) — untested today.
- **Section E** (Mobile Safe Mode banner inside polygon, items 41-48) — untested.
- **Section F** (Mobile Vision compositing, items 49-54) — untested.
- **Section G** (Should-FAIL items, 55-57) — KNOWN to fail today; will pass once Safe Mode completion lands.
- **Section H** (Regression sweep, items 58-62) — untested.
- **Section I** (PR #390 portal follow-ups, items 63-71) — untested. (Items 66 about debounce and 70-71 about CSP are now low-priority verification.)
- **Section J** (Public Profile v2, items 72-82) — **added by V2 sub-agent**.
- **Section K** (Safe Mode completion, items 83-92) — **added by Safe Mode completion sub-agent**.

Hard refresh `https://staging.manage.homefit.studio` and `https://staging.session.homefit.studio` before starting. iPhone needs a fresh `./install-device.sh staging` to pick up the Safe Mode completion mobile changes.

For the iPhone build, you may want to bump `pubspec.yaml` build number first (currently `1.0.0+4`) — the Safe Mode completion includes the SQLite v43 migration, worth a TestFlight upload after device QA passes.

## Decisions you made today

For the audit trail / future-Claude context:

| Topic | Decision |
|---|---|
| Test scripts format | Markdown with `- [x] ~~strikethrough~~` checkboxes in CC Desktop preview pane. File is source of truth, edited live. Memory updated: `feedback_test_scripts_as_markdown`. |
| Public Profile branding model | Co-brand (practice logo + brand color override coral; "powered by homefit.studio" stays in footer). |
| Brand color scope | Full override — every coral on the player becomes the practice's color. |
| Public Profile logo placement | Persistent top-bar throughout the session (not lobby-only). |
| Public Profile portal IA | Single new page `/public-profile` with two `<details>` accordions (Branding, Identity & directory) + dashboard tile. The block is removed from `/premises`. |
| Public Profile data model | Six new columns on `practices` (brand_color, tagline, specialties, contact_email/whatsapp/website). Reuse existing public_logo_url for both directory hero AND web player top-bar. |
| Website surfacing | Hero CTA button under the tagline ("Visit yourpractice.co.za →"), not in the bottom contact list. |
| Map: satellite | Esri World Imagery free tier + transparent Labels overlay for Google-Maps-Hybrid view. Layer switcher uncollapsed top-right. |
| Map: address picker | Photon (komoot) + Nominatim queried in parallel, deduped by ~50m lat/lng proximity, each result shows source label. No country filter. |
| Map: GPS button | Explicit "📍 Use my current location" user-gesture button (re-prompts browsers that have a sticky-denied permission). |
| Safe Mode upload swap | Safe-only: safe.mp4 replaces raw.mp4 in cloud. Local archive on device keeps original for practitioner re-export. |
| Safe Mode fail-closed | Threshold at 5% Vision miss-rate. Above → reject + auto-discard + inline toast. Below → soft-skip gap frames. |
| Safe Mode abuse guard | No server-side polygon-vs-owner-GPS check. Trust + existing `report_premises` flow. |

## References

- Mockup: [docs/design/mockups/public-profile-v2.html](design/mockups/public-profile-v2.html)
- V2 spec: [docs/specs/2026-05-21-public-profile-v2-design.md](specs/2026-05-21-public-profile-v2-design.md)
- V2 plan: [docs/plans/2026-05-21-public-profile-v2-plan.md](plans/2026-05-21-public-profile-v2-plan.md)
- Completion spec: [docs/specs/2026-05-21-safe-mode-completion-design.md](specs/2026-05-21-safe-mode-completion-design.md)
- Completion plan: [docs/plans/2026-05-21-safe-mode-completion-plan.md](plans/2026-05-21-safe-mode-completion-plan.md)
- Live test script: [docs/test-scripts/2026-05-21-safe-mode.md](test-scripts/2026-05-21-safe-mode.md)
- Safe Mode handover from PR #389: [docs/SAFE_MODE_HANDOVER_2026-05-21.md](SAFE_MODE_HANDOVER_2026-05-21.md)
