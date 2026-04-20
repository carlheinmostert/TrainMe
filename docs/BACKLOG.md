# Backlog — Deferred Work

Items that matter but aren't the current primary risk focus. Revisit when the POV is validated or when any of these start actually biting. Pulled from the 2026-04-17 "six points of optimization" discussion.

---

## Unified player — Flutter + Web share a single rendering codebase

**Status:** Scheduled as **Wave 4** (next iteration after Wave 3 QA wraps, 2026-04-20). Pre-MVP. Decision Carl, 2026-04-20.

**Why now:** the mobile preview and the web player have independently-maintained implementations of pill matrix / swipe / prep countdown / treatment rendering / mute / pause. R-10 ("every UX change must land in both surfaces") keeps drifting — the raw-archive debug + treatment-picker-removal session on 2026-04-20 made clear the maintenance cost is real and compounding. Unifying before MVP is cheaper than unifying after.

**Architecture (recommended):** WKWebView on iOS hosting the web player bundle. Local file access resolved via one of:

1. **In-process local HTTP server** (Dart `shelf` package) serving `Documents/archive/` and `Documents/converted/`. Web-player hits `http://localhost:<port>/...`. Simplest Dart-side; adds a process.
2. **WKURLSchemeHandler** custom scheme (e.g. `homefit-local://{exerciseId}/archive.mp4`) resolved in Swift. More iOS-native; better streaming for larger files.

Prefer (2) for perf + cleanliness; prototype (1) first for speed. Either way, Flutter passes the plan state as JSON via `postMessage` / platform channel, web-player renders.

**What we keep native:** Taptic Engine haptics (per-second record ticks, prep flashes), iOS audio session (silent switch respect), app lifecycle hooks. Bridged via message channel.

**What we trade:** a small perf floor vs pure native video, and a WebView bundle on-device. Worth it for code-dedup.

**What it obsoletes:** R-10 parity rule (same code = no parity drift). `plan_preview_screen.dart` becomes a thin WebView host.

**Dead-end alternatives:** Flutter Web for the player (video decode quirks + heavy bundle), dart2js interop (complex, few gains).

**Scope estimate:** 1–2 focused weeks. Spin up: local server or URL handler, plan-state bridge, migrate R-10-sensitive features off Dart. Test matrix: pre-publish preview, post-publish preview, web (browser), WebView (iOS).

---

## Silent failure observability — error_logs + _loudSwallow + boot self-check

**Status:** Scheduled as **Wave 7** (Carl, 2026-04-20 — wants it done properly as its own wave, not shoehorned into another). Design reviewed: see [`docs/design-reviews/silent-failures-2026-04-20.md`](design-reviews/silent-failures-2026-04-20.md).

**3-item MVP:**
1. `error_logs` table + `_loudSwallow` helper + pre-commit lint rule banning bare `catch (e) {}`.
2. Boot-time self-check screen — includes live `signed_url_self_check()` probe that would have caught today's vault placeholder on first launch.
3. `publish_health` SQL view + daily WhatsApp ping via the existing CallMeBot skill.

**Explicitly NOT:** Sentry/Datadog (overkill at 5 practices), viral `Result<T,E>` (only at 3 boundaries: ApiClient, UploadService.publish, video platform channel), modal error dialogs (violates R-01), silent retries (every failed attempt must log at warn).

**Sequencing note:** Wave 4 (unified player) will touch many swallow sites. Worth migrating them through `_loudSwallow` opportunistically during that refactor so Wave 7's sweep has less to cover.

---

## Replace `sign_storage_url` pgjwt helper with Supabase's native signed-URL path

**Status:** Technical debt. Currently unblocked by the legacy HS256 JWT secret (set 2026-04-20). Fix before the legacy path is removed from Supabase.

**Context:** `public.sign_storage_url(bucket, path, expires_in)` in `supabase/schema_milestone_g_three_treatment.sql` manually mints HS256 JWTs via pgjwt, signing with the legacy `vault.secrets['supabase_jwt_secret']` value. Supabase has migrated to a new JWT Signing Keys system (per-key identifiers, key rotation) and the single-secret legacy path is being phased out. When the legacy secret is finally retired, every signed URL minted by our helper will 400 overnight and the web player's B&W / Original treatments will stop working again — exactly the outage we just burned hours recovering from (2026-04-20 raw-archive session).

**Proper fix:** stop minting JWTs in Postgres. Either:
- **Edge Function that signs URLs.** `get_plan_full` returns bucket+path pairs (no URLs). Web player posts them to an Edge Function which calls `supabase.storage.from(bucket).createSignedUrl(path, 1800)` using the service role. Returns signed URLs.
- **Direct client-side signing.** Web player calls `storage.from(bucket).createSignedUrl(...)` directly after authenticating with anon key + a bucket-access RPC that pre-approves paths. More moving parts; probably the Edge Function path is cleaner.

**Related:** if we do this, consider moving the consent gate into the Edge Function too (check `video_consent` server-side before minting each URL) so the web player never has to see raw paths it shouldn't.

**Trigger to do it:** Supabase announces legacy JWT secret end-of-life, OR we rotate the legacy secret and notice we can't update our vault entry, OR routine hardening pass.

---

## Replace `sign_storage_url` pgjwt helper with Supabase's native signed-URL path

**Status:** Technical debt. Currently unblocked by the legacy HS256 JWT secret (set 2026-04-20). Fix before the legacy path is removed from Supabase.

**Context:** `public.sign_storage_url(bucket, path, expires_in)` in `supabase/schema_milestone_g_three_treatment.sql` manually mints HS256 JWTs via pgjwt, signing with the legacy `vault.secrets['supabase_jwt_secret']` value. Supabase has migrated to a new JWT Signing Keys system (per-key identifiers, key rotation) and the single-secret legacy path is being phased out. When the legacy secret is finally retired, every signed URL minted by our helper will 400 overnight and the web player's B&W / Original treatments will stop working again — exactly the outage we just burned hours recovering from (2026-04-20 raw-archive session).

**Proper fix:** stop minting JWTs in Postgres. Either:
- **Edge Function that signs URLs.** `get_plan_full` returns bucket+path pairs (no URLs). Web player posts them to an Edge Function which calls `supabase.storage.from(bucket).createSignedUrl(path, 1800)` using the service role. Returns signed URLs.
- **Direct client-side signing.** Web player calls `storage.from(bucket).createSignedUrl(...)` directly after authenticating with anon key + a bucket-access RPC that pre-approves paths. More moving parts; probably the Edge Function path is cleaner.

**Related:** if we do this, consider moving the consent gate into the Edge Function too (check `video_consent` server-side before minting each URL) so the web player never has to see raw paths it shouldn't.

**Trigger to do it:** Supabase announces legacy JWT secret end-of-life, OR we rotate the legacy secret and notice we can't update our vault entry, OR routine hardening pass.

---

## Filter workbench — wire to cloud raw archive once auth lands

**Status:** Deferred. Blocks real filter tuning.

Current limitation: `tools/filter-workbench/` pulls the `media_url` from Supabase, which is the already-filtered + already-two-zoned line-drawing output. Tuning filter params against post-filter content isn't meaningful — the slider tweaks layer on top of work already done. Segmentation re-runs on a line drawing instead of raw pixels.

Fix path once the cloud raw archive (archive pipeline Phase 2) lands post-auth: point the workbench's Supabase client at the private `raw-archive/{trainer_id}/{session_id}/{exercise_id}.mp4` bucket instead of the public `media/` bucket. Frame extraction + filter + segmentation then operate on the true pre-filter source.

Short-term workaround: AirDrop a raw video from the iPhone to the Mac and drop it in `tools/filter-workbench/samples/`. The CLI workbench (`workbench.py`) already accepts local samples; the Streamlit UI could be extended with a "local sample vs Supabase plan" source toggle if needed in the interim. Carl asked to wait for the proper cloud path rather than workaround.

---

## One-handed reachability — pull-to-latch scroll physics (Studio)

**Status:** Deferred. Custom behaviour, probably a few days of careful work.

**Want:** Let the bio drag the Studio list down and have it LATCH in the dragged position (not bounce back on release) so items that were near the top are now in the thumb zone. Tap an item, viewport snaps back to natural rest.

**Why native alternatives don't fit:** `BouncingScrollPhysics` only holds the stretched position during the active gesture — releasing snaps it back, so items aren't reachable without a second finger. iOS system Reachability works but Carl finds it terrible UX. Standard scroll physics don't have a "latched stretch" state.

**Implementation sketch:** Subclass `ScrollPhysics`, override `applyPhysicsToUserOffset` + `createBallisticSimulation` to allow the scroll offset to extend past the natural minimum (in `reverse: true` that's past the visual top), and prevent the simulation from returning to zero on release below a threshold. Tapping an item anywhere in the app invokes a snap-back animation. Most of the complexity is in the interaction model — drag gestures, tap-to-snap-back, conflict with drag-reorder (`ReorderableListView` has its own drag-start detection).

**Risk:** Non-standard scroll behaviour is user-experience debt. Bios switching between this app and every other app will be surprised by list content that doesn't bounce back. Only revisit if the one-handed friction is observed to be a real problem in testing.

---

## Point 2 — Performance / feel

**Status:** Deferred. POV currently feels fast on a new iPhone. Revisit when we hit a real bottleneck or when we test on lower-spec devices.

- **Startup latency.** Cold start chains `PathResolver.initialize` → `SystemChrome` → `Supabase.initialize` → `storage.init` + migrations + `purgeExpiredSessions` + `purgeOldArchives`. Cut time-to-first-paint by kicking Supabase init and purges to post-first-frame via `unawaited(...)`.
- **List scroll jank with 30+ captures.** Expansion + drag reorder + per-row thumbnails. Partly addressed: `Image.file` `cacheWidth` sized to widget, N+1 queries resolved via `WHERE IN (...)`. Further wins: promote card-expanded state to a `ValueNotifier` so only the open card rebuilds; avoid passing fresh closures each build.
- **Video convert speed on device.** `autoreleasepool` + `CVPixelBufferPool` landed. Per-pixel Swift loops for BGRA↔gray remain hot — `vImage` rewrite (`vImageMatrixMultiply_ARGB8888ToPlanar8` + `vImageConvert_Planar8toARGB8888`) would ~halve convert time.
- **Rebuild storms.** `setState` at the top of large screens (particularly the old `session_capture_screen.dart`) rebuilds the entire card list. Capture/Studio split will reduce this but not eliminate it.
- **Battery / thermal on long sessions.** 90 min of live camera + background conversion queue + SQLite writes under thermal pressure hasn't been measured. Worth profiling with Xcode Instruments when it matters.
- **Publish over SA 4G.** Sequential uploads, no chunking, no resumable transfer. 20 captures × tens of MB = minutes. Single signal drop = start over (see Point 3 below).

---

## Point 3 — Resilience

**Status:** Deferred. All valid scenarios; prioritise when we onboard additional bios or move past the POV.

### High priority when we pick this up
1. **Background-safe publish via native iOS background `URLSession`.** Current Dart-level `http` uploads die on backgrounding or signal drop. Platform-channel the storage PUTs into a `URLSessionConfiguration.background` so the bio can background the app (walk out to their car) mid-upload without losing progress. This is the single biggest resilience win.
2. **Phone-full handling.** Proactive check of available storage before a capture starts; user-facing "your phone is nearly full" warning. Today we fail silently at the file-write step.
3. **Local DB backup / export.** A weekly auto-export of sessions + metadata (+ maybe a manual "export my plans" button) into `Documents/backups/`. Defends against SQLite corruption, accidental reset, phone loss. Cheap insurance.

### Lower priority
- **Crash-mid-capture testing.** Today we save the raw file + DB row before conversion; on next launch the queue resumes via `getUnconvertedExercises`. Probably OK; should be stress-tested.
- **Partial-clip salvage on call/alarm interrupt.** Camera teardown on `AppLifecycleState.inactive` discards the in-flight clip (tough-love stance, 2026-04-17). Keep unless feedback pushes back.
- **DB corruption recovery.** No recovery path today. Tied to backup/export above.
- **Stolen / lost phone.** Published plans survive in the cloud; trainer's archive is local-only. The cloud raw-archive (Phase 2, post-auth) will solve this.
- **Reinstall survival.** Relative paths via `PathResolver` plus schema migrations should hold. Worth one round of deliberate testing before MVP.
