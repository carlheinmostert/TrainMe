# Backlog — Deferred Work

Items that matter but aren't the current primary risk focus. Revisit when the POV is validated or when any of these start actually biting. Pulled from the 2026-04-17 "six points of optimization" discussion.

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
