# Checkpoint — 2026-04-26 (Waves 27 → 32: ~6 days, 30 commits)

**Read this first on fresh session.** Supersedes `CHECKPOINT_2026-04-24.md` for current state.

## TL;DR

Six waves in ~6 days. Closed the entire client-spine + lock + Studio-card + landscape + avatar + portal-context arc. As of EOD 2026-04-26: latest commit on `main` is **`193d547`**, iPhone CHM is on **`193d547`**. Vercel portal deploy was failing for ~24h (TS strict-mode error in middleware) — fixed in `193d547`; verify with `vercel ls` after read.

**Active wave at top of test-scripts index:** Wave 32 (SessionCard consolidation + 14d grace + W31 carryover fixes). 9 items, awaiting Carl's QA.

## Schema migrations applied this stretch

All applied via `supabase db query --linked` against the linked dev DB.

- `supabase/schema_wave27_per_plan_crossfade.sql` — `plans.crossfade_lead_ms` + `plans.crossfade_fade_ms` (smallint NULL).
- `supabase/schema_wave28_landscape_metadata.sql` — `exercises.aspect_ratio` (numeric NULL) + `exercises.rotation_quarters` (smallint default 0). Plus `replace_plan_exercises` re-published with both new columns in the INSERT list (recurring trap — every new column needs explicit add per `gotchas_publish_path.md`).
- `supabase/schema_wave29_unlock_plan.sql` — `plans.unlock_credit_prepaid_at` timestamptz NULL. New `unlock_plan_for_edit(uuid)` RPC: practice-membership check + `consume_credit` + sets prepaid timestamp. `consume_credit` patched to read + clear `unlock_credit_prepaid_at` atomically (FOR UPDATE on the plan row); when set, returns `{ok:true, prepaid_unlock_at}` without inserting a ledger row. Avoids double-charging on republish after unlock.
- `supabase/schema_wave30_client_avatar.sql` — `clients.avatar_path TEXT NULL`. `clients.video_consent` jsonb extended with `avatar` boolean (default false; existing rows backfilled). New `set_client_avatar(uuid, text)` RPC. `set_client_video_consent` extended with optional `p_avatar` flag (5-arg variant; 3-arg shim retained, reads existing avatar value to avoid clobbering). `list_practice_clients` / `get_client_by_id` `RETURNS TABLE` shape includes `avatar_path` + `consent.avatar`.
- `supabase/schema_wave31_referral_any_member.sql` — `generate_referral_code` guard relaxed from owner-only to any-member: `IF NOT (p_practice_id = ANY(SELECT user_practice_ids())) THEN RAISE 42501`. `revoke_referral_code` stays owner-only.

## SQLite versions

Local DB schema rolled v25 → v31 across the stretch:
- v27 — `sessions.crossfade_lead_ms` + `sessions.crossfade_fade_ms`.
- v28 — `exercises.aspect_ratio` + `exercises.rotation_quarters`.
- v29 — `sessions.unlock_credit_prepaid_at` + `cached_clients.consent_confirmed_at`.
- v30 — `sessions.first_opened_at` (Wave 29 follow-up; `_isPlanLocked` was reading a never-populated field).
- v31 — `cached_clients.avatar_path`.

## What landed by wave

### Wave 27 — Per-plan crossfade tuner + trim fix + play/pause rail (2026-04-25)
- Native dual-video crossfade retrofit in `_MediaViewer` (two `VideoPlayerController`s + `AnimatedOpacity` swap, mirrors web-player).
- Per-plan crossfade timing — `plans.crossfade_lead_ms` / `crossfade_fade_ms`. Bottom-sheet sliders in `_MediaViewer` (lead 100-800, fade 50-600). Web reads via `get_plan_full` auto-flow + `getLoopCrossfadeLeadMs/FadeMs()` getters with NULL → 250/200 fallback.
- Right trim handle bug — `_enforceTrimWindow` was wrapping `position >= endMs` to start on every tick; dragging right handle made the listener fire mid-drag and yank back. `_trimDragInProgress` flag suspends enforcement.
- Web player play/pause toggle on the right rail (replaced centered pause overlay). SVG `el.hidden = true` doesn't reflect to content attr — switched to `setAttribute('hidden','')` (gotcha now in memory).
- Crossfade trim-aware: detector compared position to natural duration; trim wrap fired first, crossfade never scheduled. Both surfaces now compute effective loop window from `[startOffsetMs, endOffsetMs]`.
- Native `_MediaViewer` had ONE listener; refactored to attach to BOTH controllers so trim enforcement runs whichever ticked.

### Wave 28 — Landscape orientation support (2026-04-25)
- Camera capture warps-to-portrait fix (`capture_mode_screen.dart:870-878` width/height swap inverted on rotation).
- New `app/lib/widgets/orientation_lock_guard.dart` — race-safe static-stack guard. Each instance owns a `_StackEntry`; on dispose removes its OWN entry (not top — pop-order may not match push-order) and re-applies the current top (or global default if empty). Survives Flutter's back-to-back `B.initState→A.dispose` sequence on push.
- Global default flipped to portrait. iPad locked to iPhone-only orientations.
- `_MediaViewer` reflows for landscape: chrome positions branched, treatment control + mute/body focus/rotate/mute pills stack horizontally, trim panel compact, tune sheet → popover.
- `RotatedBox(quarterTurns: ...)` outside the dual-controller Stack so single rotation composes over both crossfade slots.
- Web player `@media (orientation: landscape) and (max-height: 540px)` block at bottom of styles.css. Reflows plan-bar, matrix, card-viewport, edge-nav, right-edge chrome stack, settings popover. Pre-workout Maximise pill (`#btn-landscape-maximise`) → real `requestFullscreen()` (iOS 16.4+ supported).
- `assets/web-player/` was drifting behind `web-player/` (manual sync script). `install-device.sh` now runs the sync as a step before `flutter build ios`. Memory entry added.
- `PlanPreviewScreen` deleted.
- New schema columns `aspect_ratio` + `rotation_quarters` flowed end-to-end (capture → SQLite → publish payload → cloud → web).

### Wave 29 — Locks + credits chip + Studio cleanup (2026-04-25)
- Structural-edit lock policy: 3 days post-`first_opened_at` (later revised to 14 days in Wave 32). Plans never opened stay open indefinitely.
- Padlock icon on Studio top action bar → unlock confirm sheet → `unlock_plan_for_edit` RPC consumes 1 credit + sets `unlock_credit_prepaid_at` atomically. Next republish skips `consume_credit` + clears the flag (no double-charge).
- Publish-time consent gate: `clients.consent_confirmed_at` stamped by `set_client_video_consent`. Publish flow gates: NULL → `ClientConsentSheet` modally before publish; cancel = abort, no credit consumed.
- Home credits chip right-aligned on the practice row. Live update via `SyncService.creditBalances` ValueNotifier. Tap → `manage.homefit.studio/credits?practice=<uuid>` via new `portalLink()` helper. Portal middleware validates `?practice=<uuid>` membership server-side, sets `hf_active_practice` cookie, 302-strips the param.
- Studio exercise card: PLAYBACK accordion retired (~358 lines). Edit-cog on thumbnail + state caption (treatment · audio · trim · rotation).
- Rest-row icon alignment polish.
- **Hot fix follow-up (`64f36ed`)**: lock UI was reading a never-populated field. Plumbed `plans.first_opened_at` + `unlock_credit_prepaid_at` cloud → local via `getPlanPublishState` + `SessionShell._reconcileWithCloudIfUnpublished` (now runs on EVERY session open, not only when local thinks unpublished).

### Wave 30 — Studio polish + Network sheet + Body focus preview + Client avatar (2026-04-25)
- Session list icon swapped `Icons.camera_alt_outlined` → `Icons.list_alt_rounded`.
- Locked-publish UX routes to unlock sheet (replaces silent toaster).
- Thumbnail bumped 56→88 (caused W30 #16 layout regression — fixed in W31).
- Rest-row icon + label re-paired into one centred unit.
- Home top-left `Icons.group_add_outlined` → `_NetworkShareSheet` (referral code + QR + system share + portal link). `network_share_kit_screen.dart` retired (~1551 lines).
- Body Focus on session preview: bridge + local_player_server emit `grayscale_segmented_url` + `original_segmented_url` and accept `kind=segmented`.
- **Client avatar with body-focus blur (NEW FEATURE):** new native `ClientAvatarProcessor.swift` (Vision `.accurate` person-segmentation + vImage tent-convolve Gaussian blur + integer round-half-up lerp composite). New `ClientAvatarCaptureScreen` (single-shot camera). New `ClientAvatarGlyph` widget (40px circular, three-tier fallback: local file → signed URL → initials monogram). Cloud upload to `raw-archive/<practice>/<client>/avatar.png`. 4th consent toggle on `ClientConsentSheet`.

### Wave 31 — Studio polish + Avatar lens + Credits URL + Referral RPC (2026-04-26)
- Studio exercise card layout regression: caption was double-stacked BELOW the row instead of inside the title Column. Fixed.
- Shell pull-tab icon asymmetric: Camera→Studio = `list_alt_rounded`; Studio→Camera = `camera_alt_outlined`.
- Locked-plan EDITS proceed silently (only Publish gates). Stripped six `if (_isPublishLocked) showPublishLockToast` guards.
- Insert-triangle CLONED from existing inter-exercise gutter (`GutterGapPainter` + `InlineActionTray` Rest/Exercise pills). `_buildGap` extended to accept nullable `lower`. First implementation was wrong (custom `_InsertExerciseSlot`); redo agent landed correctly.
- Avatar capture lens: switched from picking `availableCameras().first` to filtering name-substring `ultra`/`tele`. **THIS WAS NOT ENOUGH** — see Wave 32.
- Credits chip URL bug: real cause was portal `SignInGate` dropping the original destination on auth round-trip. Wave 31 added `?next=` threading via `safeNext()` + Suspense wrapper. **STILL FAILED** on third pass — see Wave 32.
- Referral RPC guard relaxed from owner to any-member. "View network stats →" link removed from share sheet.

### Wave 32 — SessionCard + 14d grace + W31 carryover fixes (2026-04-26 EOD)
- **SessionCard consolidation (Carl spec):** number badge OVERLAYS leading icon at bottom-right (icon stays). Status row trimmed to `v3 · 25 Apr`. New THIRD ROW dedicated to lock state with explicit copy + 8×8 `Container` colour-coded dot. Five tones (fresh sage / warning amber / urgent coral / locked red / unlocked light coral). Time-format helper auto-collapses zero-units; clamps `≤0` to "1m left".
- **Lock-grace policy 3d → 14d** (Carl: "matches typical practitioner / client follow-up cadence"). `_kLockGraceDays` constant + CLAUDE.md "Revenue Model" updated.
- **Circuit rail colour overlap fix:** `GutterGapPainter` shared a Paint instance leaking coral onto the rail; renamed `railPaint` (locally-scoped) + clipped the rail through a 16px band centred on the triangle.
- **Avatar capture (real fix):** name-substring filter (`ultra` / `tele`) wasn't enough on Wave 31 — added `controller.lockCaptureOrientation(DeviceOrientation.portraitUp)` after `controller.initialize()`. The camera plugin reads device orientation at capture time and bakes EXIF transform; `setPreferredOrientations` only governs Flutter UI layout. `dev.log` lines under `avatar.capture` subsystem.
- **Credits chip portal (third pass):** the `?next=` plumbing landed in W31 but the home `/` page ignored `?next=` when user was ALREADY signed in — fell through to `/dashboard`. W32: home page server component honours `?next=` if signed-in + `safeNext` clamps. Extracted shared `safeNext()` to `web-portal/src/lib/safe-next.ts`. `[wave32-redirect-trace]` server-side logs at every redirect point.
- **Preview videos render (Wave 31 carryover bug):** iOS scheme handler now accepts `kind=segmented` (was `line | archive` only). Bridge `_resolveMediaPath` falls back to `rawFilePath` when video's `convertedFilePath` is a JPG fallback (still-image conversion) — previously bundle's `<video>` element silently failed on `image/jpeg` content-type.
- **Hot fix:** portal Vercel deploy had been failing for ~24h with TS strict-mode error at `web-portal/src/middleware.ts:76` (`setAll(cookiesToSet)` implicit `any`). Added `cookiesToSet: { name: string; value: string; options: CookieOptions }[]` + import `CookieOptions` from `@supabase/ssr`. Build unblocked.

## Live state (EOD 2026-04-26)

- Latest commit on `main`: **`193d547`** (Wave 32).
- iPhone CHM bundle: **`193d547`** (per `databaseSequenceNumber: 4532`).
- Web player cache (deployed): **`v65-maximise-pill`** (last bump in Wave 30).
- Portal deploy: just unblocked by middleware TS fix; verify with `vercel ls --scope=carlheinmosterts-projects` first thing on fresh session.
- Active worktree branch: `claude/recursing-newton-240bde` (synced with main).
- Active wave at top of test-scripts index: **Wave 32** (`docs/test-scripts/2026-04-26-wave32-bundle.html`, 9 items × 7 sections). **Awaiting Carl's QA.**
- All Wave 31 results captured (5 pass, 2 fail, 1 pass-with-note, 2 untested) — fails rolled into Wave 32; pass-with-note also rolled in.

## Known load-bearing context that isn't obvious from the code

- **Lock policy = REPUBLISH cost gate, NOT edit blocker.** Wave 31 stripped all edit-blocking; locked plans accept all edits silently. Only the Publish action gates. Carl's mental model: "if I republish a structurally-changed plan past 14 days, that's a new arc of treatment, pay 1 credit". Don't accidentally re-introduce edit gates.
- **Test-script results JSON files are gitignored** AND **the server runs from `/Users/chm/dev/TrainMe/docs/`, not the active worktree.** When Carl says "results are available", read from `/Users/chm/dev/TrainMe/docs/test-scripts/*.results.json` — NOT the worktree path. (Memory entry: `feedback_test_scripts_as_markdown.md`.)
- **`assets/web-player/` drift from `web-player/` is a recurring trap.** `install-device.sh` now runs the sync automatically; if anyone bypasses install-device (`flutter build ios` directly), they MUST run `cd app && dart run tool/sync_web_player_bundle.dart` first. Verify with `grep PLAYER_VERSION app/assets/web-player/app.js` matching the source.
- **`replace_plan_exercises` RPC needs explicit column updates.** Each new column on `exercises` must be added to the RPC's INSERT list. Wave 28 caught this, Wave 22 / Wave 24 also patched in passing. Worth a future audit.
- **SVG `el.hidden = bool` doesn't reflect to content attribute reliably.** `[hidden]` selector won't match. Use `setAttribute('hidden','')` / `removeAttribute('hidden')` (memory: `infrastructure_gotchas.md`).
- **Web is consumption, mobile is configuration** (memory: `feedback_consumption_vs_config_surfaces.md`). Don't put practitioner tuning controls on the web player. Only options a general client might change.
- **No JS-style `\uXXXX` escapes in HTML test scripts.** They render as literal text. Use the actual char or HTML entity. (Memory: `feedback_test_scripts_unicode.md`.)
- **Don't acknowledge the auto preview-panel hook output** when writing/editing `docs/test-scripts/*.html`. Carl finds the "visible in preview panel" sentence noise; suppress it. (Memory: `feedback_no_preview_mentions.md`.)

## Pending / known-issue carry-over for Wave 33

None blocking. Wave 32 awaiting QA — fails will roll into next wave per Carl's pattern.

## How to resume

1. Read this checkpoint.
2. `git status` — should be clean.
3. `vercel ls --scope=carlheinmosterts-projects | head` — confirm portal deploy is now Ready (was failing for 24h before Wave 32 hot fix).
4. If Carl reports Wave 32 results, read from `/Users/chm/dev/TrainMe/docs/test-scripts/2026-04-26-wave32-bundle.results.json` (main repo path, NOT worktree).
5. New requirements queued mid-test go into the NEXT wave file (Wave 33). Carl's discipline rule.
6. CLAUDE.md is now authoritative on the 14-day lock-grace policy.
