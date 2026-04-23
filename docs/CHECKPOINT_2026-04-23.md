# Checkpoint — 2026-04-23 (Wave 19.4 publish-path stabilisation)

**Read this first on fresh session.** Supersedes `CHECKPOINT_2026-04-22.md` for current state. Earlier checkpoints remain authoritative for their era.

## TL;DR

Wave 19.4 device QA surfaced a cascade of publish-path bugs. All four are fixed and landed on `main`. No open bugs on the live stack. Test script B4 was rewritten because its original premise ("accept the default name which collides with deleted client") is now unreachable — new default names carry a random 4-hex suffix, so the collision path is only reachable via deliberate manual same-name re-entry.

## What landed today

Four commits on `main`, in order:

1. **9db0651** `fix(publish): read LIVE client name from cache, not stale session.clientName`
   - Root cause: `session.clientName` is a legacy denormalised mirror. Renaming a client touched `cached_clients.name` but never the session rows, so publish kept using the old name.
   - Fix: resolve `effectiveClientName` via `session.clientId → cached_clients.name` in the publish path. Falls back to `session.clientName` for legacy rows without a `clientId`.

2. **ac78e48** `fix(publish): prefer upsert_client_with_id when session.clientId is known`
   - Even after (1), the `upsert_client` RPC is name-first — it still raises 23505 when the name matches a soft-deleted tombstone.
   - Fix: switch to `upsert_client_with_id` (id-first) when `session.clientId` is known. Bypasses the name-collision check because the row already exists.
   - `upload_service.dart` publish flow: id-first when known, name-only fallback for legacy.

3. **23950b0** `fix(conversion): add timeouts to every native invokeMethod so the queue can't wedge`
   - Symptom: "first video hanging, second converted immediately." Killing + reopening the app → conversion "finished" (native was done; Dart follow-up had hung).
   - Fix: timeouts on all 5 native channel calls in `conversion_service.dart`: `convertVideo` (3 min), `extractFrame` ×2 (30 s), `extractThumbnail` fallback (30 s), `getVideoDuration` (10 s). TimeoutException surfaces as a failed conversion instead of a silent wedge.

4. **8127a39** `fix: publish UX triple — default name collision, stale share button, cloud reconcile`
   - **Default-name collision**: picker minted sequential `New client N` and only scanned the local cache. `list_practice_clients` filters `deleted_at IS NULL`, so the cache was blind to tombstones. Server-side unique index is `deleted_at`-agnostic → 23505 loop.
   - **First attempt** (reverted): added Milestone W RPC `list_all_client_names(p_practice_id)` returning every name including soft-deleted. The picker union'd that with the cache and picked the lowest unused N. Worked but Carl pushed back: *"Shouldn't we use almost like an affiliate code to avoid crash conditions, so newclientxywf?"*
   - **Final fix**: default name is now `New client {4-hex-random}` via `dart:math` Random.secure. 65 536-name namespace per practice → collision with a tombstone is statistically zero. The Milestone W RPC file stays in `supabase/` as a safety net for future callers; the mobile picker no longer calls it.
   - **Stale share button**: if a publish crashed between cloud commit and the local `saveSession(updated)` write, local row was missing `planUrl/version/sentAt` while Supabase had the plan published. Studio rendered share dim. Fix: `SessionShellScreen._reconcileWithCloudIfUnpublished()` in `initState` backfills from cloud via new `ApiClient.getPlanPublishState(planId)`.

### Uncommitted (just edited, not yet committed)

- `docs/test-scripts/2026-04-23-wave19.4-session-upgrades.html` — **Item 4 (B-series) rewritten** to test the same server-side 23505 guard via manual same-name re-entry instead of the now-unreachable default-name collision path. Pattern: long-press → Delete → let Undo SnackBar dismiss → FAB New client → rename to exact deleted name → publish → expect user-visible SnackBar.

## Wave 19.4 QA status

Test script: `docs/test-scripts/2026-04-23-wave19.4-session-upgrades.html` (27 items).

Items confirmed passing from this session's dialogue:
- **A1** (Flutter preview open) — ✓
- **A2** (two-photo flow) — ✓
- **B3** (happy-path publish) — previously failed with 23505 collision, now passing per Carl's "Bugfix worked" confirmation.

Items still to run: most of A (beyond A2), B (4 is now rewritten), C through the end.

## Supabase migrations applied today

- **`schema_milestone_w_all_client_names.sql`** — `list_all_client_names(p_practice_id)` SECURITY DEFINER RPC. Returns every client name in a practice including soft-deleted. Practice-membership gated. Applied via `supabase db query --linked --file ...`. Not currently called by the mobile app (the random-suffix approach supplanted it), but kept as a safety net.

## Pending / deferred

Carried forward from mid-QA — not blocking:

- Drop the `totalSetsForSlide > 1 || interSetRestForSlide > 0` gate at `web-player/app.js:2370` so the set-progress-bar always renders in workout mode for non-rest slides. Carl approved earlier but got preempted by the publish cascade.
- Wire `tool/sync_web_player_bundle.dart` into `install-device.sh` as a safeguard (so the "wave 19 bundle was stale in the Flutter preview" regression can't recur).
- Continue Wave 19.4 device QA items 4 through 27 once Carl has a block of time.

## How to resume

1. Commit the B4 rewrite: `docs/test-scripts/2026-04-23-wave19.4-session-upgrades.html` — use a `docs:` message, e.g. `docs(test-scripts): rewrite Wave 19.4 B4 to use manual same-name collision path`.
2. If Carl's on device, ask him to continue the Wave 19.4 script from item 4 (now the rewritten version).
3. If mid-session changes are needed, remember R-10 (mobile + web player change in the same PR) and the offline-first invariants from CLAUDE.md.

## Load-bearing context that isn't obvious from the code

- `session.clientName` is a **legacy mirror** of `clients.name`. Never trust it post-rename. The source of truth is `cached_clients.name` keyed by `session.clientId`.
- `upsert_client` is **name-first** and will raise 23505 on a soft-deleted tombstone. Use `upsert_client_with_id` when a `clientId` is known — it's id-first and bypasses the name-collision check.
- `list_practice_clients` filters `deleted_at IS NULL` — the local cache is BLIND to tombstones. Any picker/picker-like logic that needs to avoid tombstones must call `list_all_client_names` OR sidestep the problem (random-suffix default names did the latter).
- Native `convertVideo` can "succeed" from the native side while the Dart follow-up wedges. The app kill-and-restart "fixes" it because the native write already landed. All native invokeMethod calls in `conversion_service.dart` now have timeouts to prevent silent wedges.
- Publish has two `saveSession` phases: pre-credit and post-credit. If the app is killed between cloud commit and the post-credit local save, the local row is stale. `SessionShellScreen._reconcileWithCloudIfUnpublished` heals this on next open.
