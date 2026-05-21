# Safe Mode — handover for the next session

**Branch:** `claude/add-gym-mode-2elAf`
**PR:** [#389 (draft)](https://github.com/carlheinmostert/TrainMe/pull/389)
**Last commit at handover:** `41b156b` (CI fixes — portal typecheck + PostGIS image swap)
**Authored:** 2026-05-21, by a remote-execution Claude session
**Picking up:** Carl on his laptop, fresh Claude Code session

---

## For the next AI: how to behave

You're picking up a feature that's already been designed, scoped, implemented, and pushed. Carl is in the middle of **manually testing** the device build and will be reporting pass/fail as he goes. Your job is the babysitting role, not the design role.

### Carl's testing rhythm — IMPORTANT
- He'll paste results in any format (`"6 pass, 7 fail because X"`, `"9 fail no polygon appears"`, etc.).
- **Stack his feedback. Strike items as they pass.** Once an item passes, remove it from the active list so the remaining work is always visible.
- **If he asks a question, bring back the net remaining test list every time.** He explicitly asked for this — don't make him scroll up to remember what's left.
- He skipped section A (schema sanity). Don't push him to revisit it.

### Tone
- Tight. He doesn't want commentary, he wants the next thing to test.
- Match the existing repo voice (`CLAUDE.md`, recent CHECKPOINT_*.md files): direct, no fluff, code references with file:line.

### What you can and can't do
- You **can** edit files, run builds (`flutter`, `npm`, `psql`), inspect the running iPhone via the `xcodebuild` / `ios-simulator` MCPs Carl has wired into his local Claude Code.
- You **can** push fixes for any test failures that are small + tractable.
- You **can't** modify the design spec without asking — the spec was settled over a 6-round conversation; Carl will tell you if the rules change.
- **Don't** start coding the follow-up waves (see "What's NOT done" below) without his explicit go-ahead. Test results may inform the order he wants to tackle them.

### Commit + push posture
- Make small commits per test-failure fix.
- Push to `claude/add-gym-mode-2elAf` (the PR's branch). Don't open a new branch.
- The PR is **draft** — keep it draft until Carl says otherwise.

---

## What this feature is (one paragraph)

**Safe Mode** is a geofenced privacy posture. A practice registers premises (polygons) on the portal, and inside an enforced polygon every capture (regardless of which practice the practitioner belongs to) has its bystanders silhouetted in flat coral inside the raw archive. The client passes through untouched. Built from a 6-round design conversation captured in the PR description. Three independent opt-ins per practice: define a premises, enforce Safe Mode at it (per-premises), list the practice in the public directory (practice-level).

---

## What's done (this PR)

### Phase 1 — schema + portal + web profile page (`97f4abd`)
- `supabase/migrations/20260521120000_safe_mode.sql`
  - PostGIS extension in `extensions` schema
  - `practices` gains `public_slug, public_logo_url, public_blurb, public_profile_listed, public_profile_updated_at`
  - New `practice_premises` table (`geometry(Polygon, 4326)`, 12-vertex / 1 km² CHECK constraints, soft-delete)
  - New `premises_reports` table (RPC-write-only)
  - `exercises` gains `captured_in_premises_id`, `safe_mode_active`
  - 9 new RPCs: `upsert_premises`, `delete_premises`, `restore_premises`, `list_practice_premises`, `set_practice_public_profile`, `find_premises_at` (anon), `get_practice_profile` (anon), `report_premises` (anon), `practice_premises_default_slug`
- Portal `/premises` page with Leaflet+OSM polygon editor (click-to-place, drag-to-adjust, right-click to remove)
- Portal `Public profile` section (slug + logo URL + blurb + directory toggle, owner-only)
- Dashboard tile for Premises
- Web player `/v/{slug}` public profile page (`v.html` + `v.js` + new `v-*` styles in `styles.css`)
- Bot OG-card support extended in `web-player/middleware.js`
- SW `APP_SHELL` includes `v.html` + `v.js`

### Phase 2 — mobile capture pipeline + native Swift compositing (`dbb93c1`)
- `geolocator: ^13.0.2` in `pubspec.yaml`
- `NSLocationWhenInUseUsageDescription` in `app/ios/Runner/Info.plist`
- `app/lib/services/safe_mode_service.dart` — session-scoped singleton, state machine `unchecked → checking → unavailable | notInZone | active`
- `ApiClient.findPremisesAt(lat, lng)` + `reportPremises()` + `SafeModeMatch` value type
- `main.dart` initializes the service at bootstrap
- `SessionShellScreen.initState` fires `checkLocation()` (fire-and-forget)
- Capture screen renders a coral "Safe Mode active · {premises}" banner below the top bar (driven by `ListenableBuilder` on `SafeModeService.instance`)
- `ConversionService._convertVideo` threads a new `safeOutputPath` arg through to the platform channel
- `app/ios/Runner/VideoConverterChannel.swift` — 4th `AVAssetWriter` alongside line/segmented/mask. New `SafeModeProcessor` class runs `VNDetectHumanRectanglesRequest` per frame, picks the largest bbox = client, composites coral over every mask pixel outside that bbox. Result payload returns `safeOutputPath` + `safeFramesProcessed`.

### CI fixes (`41b156b`)
- `PremisesPolygonEditor.tsx` — TS narrowing on `zoom` derivation
- `.github/workflows/migration-check.yml` — swapped `postgres:17` → `postgis/postgis:17-3.5` so `CREATE EXTENSION postgis` resolves

---

## What's NOT done — follow-up wave list

These are the gaps the test list will surface as "expected fails" (section G). Pick them up in this priority order:

1. **Upload swap.** The `safe.mp4` file produced by `SafeModeProcessor` lives on disk after conversion but isn't uploaded yet. The player still gets the un-blurred original at `raw-archive/{practice}/{plan}/{ex}.mp4`. Extend `app/lib/services/upload_service.dart` to upload the safe file in place of the regular raw archive when both exist on disk. ~30 lines. **This is the most important follow-up** — without it the feature isn't visible to clients.
2. **Audit stamping at publish.** `exercises.safe_mode_active` and `exercises.captured_in_premises_id` aren't being written. Read `SafeModeService.instance.premisesId` at publish time and pass through to `replace_plan_exercises` RPC. The RPC's column list needs the new fields too — see the schema-migration-column-preservation memory in `CLAUDE.md`.
3. **Persist `safe_raw_file_path` to SQLite.** Today the file lives on disk only. For crash recovery on the upload swap (item 1), we need the column. SQLite version bump + `app/lib/models/exercise_capture.dart` field + `local_db.dart` migration.
4. **Photo Safe Mode.** Add `processPhotoSafeMode` native channel method (mirrors `processPhotoBodyFocus`). The Swift building blocks are all in `SafeModeProcessor`; needs a single-frame variant.
5. **Fail-closed UX.** Today missed-Vision-detection frames are soft-skipped (gap in safe.mp4). Per spec, the capture itself should be rejected with an inline toast. Needs UX work in `capture_mode_screen.dart`.
6. **Polygon abuse pre-validation.** Server-side check that the polygon contains the practice owner's current GPS at submission time. Catches obvious griefing. Add to `upsert_premises` RPC.
7. **CLAUDE.md update.** Feature spec hasn't been added to the project doc yet. After Carl signs off on the design, fold the Safe Mode section into the Architecture Principles + Tech Stack sections.

---

## CI status

At handover, `41b156b` was just pushed. Re-runs in flight. Pre-fix status:
- ✅ web player (node --check), custom rules, data access seams, app/** detection, web-player Vercel preview
- ❌ web portal lint+typecheck+build → **fixed in 41b156b**
- ❌ migration check (Postgres 17) → **fixed in 41b156b**
- ❌ Vercel web-portal deploy → consequential to typecheck fail, should clear
- ⏳ Flutter analyze + test → in flight, not pre-validated locally (no Dart toolchain in the remote env)

If Flutter analyze fails when you pick up: look at the new files first (`safe_mode_service.dart`) and the imports added to `main.dart`, `session_shell_screen.dart`, `conversion_service.dart`, `capture_mode_screen.dart`, `api_client.dart`.

---

## Deploy to device

```bash
git fetch origin claude/add-gym-mode-2elAf
git checkout claude/add-gym-mode-2elAf
./install-device.sh staging
```

If `install-device.sh` hard-pulls main internally, edit it or build manually:

```bash
cd app
flutter build ios --release --dart-define=GIT_SHA=$(git -C .. rev-parse --short HEAD) --dart-define=ENV=staging
# then use ios-deploy or Xcode to install to the iPhone CHM device id
# (00008150-001A31D40E88401C per CLAUDE.md)
```

---

## Test list — start here

Carl skipped section **A** (schema sanity). He's testing in order from B onward. Strike items as they pass; bring back the remaining list when he asks a question.

### B. Portal — Premises page
6. Dashboard renders a new **Premises** tile next to Clients / Network / Credits / Members. Headline reads `No premises` or `N sites · N enforce Safe Mode`.
7. Tap the Premises tile. URL is `/premises?practice=<uuid>`. Header reads `Premises` with spec-explainer copy.
8. Tap **+ Add premises**. Modal opens. Map renders centred on current GPS or Cape Town fallback.
9. Tap 3 points → coral polygon with numbered vertex pins. Vertex counter `3 / 12`. Area in m² (km² above 10,000 m²).
10. Drag a vertex pin → polygon reshapes live, area updates.
11. Right-click a vertex pin → vertex removes. Counter decrements.
12. Tap **Undo** → last placed vertex removes.
13. Tap **Clear** → polygon disappears, counters reset.
14. Try to tap a 13th point → no new vertex placed.
15. Draw a tiny polygon (~1 m²). Save → error `Polygon too small (min 25 m²)`.
16. Draw a sensible polygon, fill Name, leave Address empty, Safe Mode checked. Save → row appears with `Safe Mode on` coral badge.
17. Row shows m²/km² area + `GPS` signal type chip.
18. Edit row → modal opens populated. Toggle Safe Mode OFF, Save → row updates with `Registered only` grey badge.
19. Delete row → confirm prompt → row disappears.
20. Refresh → deleted row stays gone.

### C. Portal — Public profile section
21. `Public profile` section present with URL preview `session.homefit.studio/v/your-slug`.
22. Slug pre-populated from practice name. Edit; invalid chars stripped live.
23. Slug starting with hyphen → error `Slug must be 3–40 lowercase letters, digits, or hyphens.`
24. Blurb >280 chars → counter red, `Save profile` disables.
25. List OFF + Save → `Saved ✓`.
26. List ON without a slug → error `Pick a slug before listing in the directory.`
27. Fill slug + check List + Save → saved.
28. Sign in as non-owner member. Premises list still loads; public profile section is read-only.
29. As practitioner, upsert a premises → succeeds.
30. Sign back in as owner.

### D. Web player — `/v/{slug}`
31. Open `https://staging.session.homefit.studio/v/<slug>` on mobile Safari. Practice name centred, blurb below, coral logo placeholder with initials.
32. Premises list shows name + address + coral `Safe Mode` badge for enforced ones.
33. Tap **Open in maps →** → opens OpenStreetMap on centroid.
34. Tap **Report this practice** → modal opens with premises dropdown.
35. Submit with empty reason → error `Add a reason before sending.`
36. Submit with real reason → `Sent ✓`, modal auto-closes.
37. Verify: `select * from public.premises_reports order by created_at desc limit 5;` — latest row matches.
38. Open `/v/nonexistent-slug-12345` → renders `Practice not found`.
39. Toggle `List in the directory` OFF, refresh → `Practice not found`. Toggle back ON → profile returns.
40. Send the `/v/{slug}` URL via WhatsApp. Link preview shows practice name + blurb.

### E. Mobile — Safe Mode banner (inside polygon)
41. Stand inside an enforced polygon (or simulate via Xcode → Debug → Simulate Location).
42. Open a client → **+ New session** → swipe to **Camera**.
43. First time: iOS permission dialog. Tap **Allow**.
44. Coral banner appears: `Safe Mode active · <Premises name>` with shield icon.
45. Capture a short video (~3s) with yourself in frame. Studio thumbnail peek shows capture.
46. Walk outside the polygon (or simulate). Capture another video. Banner stays visible (session-sticky grace).
47. Swipe back to Studio. Banner still visible.
48. Exit the session. Open a session NOT created in a polygon. Banner does NOT appear.

### F. Mobile — Vision compositing
49. Locate `<exercise-id>_safe.mp4` in app's `Documents/converted/` directory.
50. Play it. Client passes through normally; **other people are flat coral silhouette**; background unchanged.
51. Xcode device log: `[VideoConverter] safe writer attached at ...` → `safe writer started` → `safe finishWriting completed — safeFrames=N`.
52. `<exercise-id>_line.mp4` unchanged from non-Safe-Mode capture.
53. `<exercise-id>_segmented.mp4` unchanged — bystanders still pop in B&W.
54. Record pointing at a wall (no humans). Log shows `safeFrames=0`, `_safe.mp4` empty/missing. Line + segmented + mask still wrote.

### G. Known gaps (these should FAIL — confirm the failure mode)
55. Publish the session from step 45. Open the plan URL. B&W and Original treatments **still show un-blurred bystanders**. → Confirms missing upload-swap.
56. Portal `/audit` for that publish does NOT carry `safe_mode_active` / `captured_in_premises_id`. → Confirms missing audit-stamping.
57. Photo capture inside the polygon: line-drawing JPG unchanged from non-Safe-Mode photo. → Confirms photo parity not wired.

### H. Regression sweep
58. Capture a video **outside** any polygon. No banner. Log: `safeOutputWritten=false`, `safeFrames=0`. Other outputs unchanged.
59. Publish that plan. Web player plays back B&W and Original normally.
60. Toggle iOS location permission OFF. Open a session inside a polygon. Banner does NOT appear. Capture works normally.
61. Existing portal pages (`/clients`, `/credits`, `/audit`, `/members`, `/network`) all still load.
62. Existing `/p/{planId}` plan pages still render. Lobby still works. Three-treatment selector works. Start workout works.

---

## Quick refs

- **Spec** lives in the PR description (#389) — read it before changing the design.
- **Algorithm for the Vision pass** is documented inline in `app/ios/Runner/VideoConverterChannel.swift` at the `SafeModeProcessor` class.
- **PostGIS** is in the `extensions` schema; references like `extensions.geometry`, `extensions.ST_Contains` everywhere in the migration.
- **iPhone CHM** UDID: `00008150-001A31D40E88401C`.
- **Staging Supabase project ref:** `vadjvkmldtoeyspyoqbx`.
- **Test account** for QA: `qa@homefit.studio` (password in `.env.test`), staging only.
