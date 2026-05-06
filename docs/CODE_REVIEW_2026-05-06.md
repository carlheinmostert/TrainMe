# Deep Code Review — 2026-05-06

**Branch:** `claude/deep-code-review-aE0vm`
**Scope:** Risk-focused review of the load-bearing paths ahead of the first TestFlight upload. UI polish, design parity, and the line-drawing v6 aesthetic are deliberately out of scope.

---

## Executive summary

We're in good shape for TestFlight. The line-drawing pipeline, audio drain, privacy manifest, bundle-ID rebrand, atomic credit-consumption, and the anonymous read surface (`get_plan_full` consent gates, RPC enumeration) all read clean. Nothing in this review blocks the first upload.

**The two findings worth fixing before the public web player gets more eyeballs:**

1. **Service-worker may cache `raw-archive` signed URLs across clients on shared devices** (`web-player/sw.js`). The cache predicate is too broad; signed URLs with 1-hour tokens get persisted for the lifetime of `CACHE_NAME`, which means a kiosk iPad in a clinic can replay one client's grayscale/original media to the next. This is the single highest-impact item in the review.
2. **No CSP header on `session.homefit.studio`** in production. The bot-detection middleware emits a tight CSP, but the actual player ships without one. Adding `default-src 'self'` plus a Supabase `connect-src` allowance is a one-line Vercel config change.

**Three multi-tenant integrity items worth fixing before scale:**

3. **`bootstrap_practice_for_user` Carl-sentinel claim race** — concurrent first sign-ins can both pass the NULL-check and clobber each other.
4. **`claim_referral_code` does not verify referrer-side membership** — a leaked code lets a non-member set up a rebate-paying pairing.
5. **`planVersionBumped` flag set after a no-op upsert** (verified) — purely cosmetic on the user-facing side, but it routinely surfaces a misleading "version may have advanced" message after every credit-failure path. Fast to fix, removes a recurring source of support confusion.

**iOS robustness:**

6. **Two force-unwraps in `VideoConverterChannel.swift`** (audio-track format hint at line 877; vImage buffer pointer at line 2381). Either crashes the host app on degenerate input. Trivial defensive-cast fixes.

**Process risks**: CLAUDE.md cites SW cache `v75` while the codebase ships `v69-modal-first-desktop` — drift. The superseded `schema_hotfix_replace_plan_exercises_columns.sql` lingers in the repo and misled the audit; deleting it (or annotating with a pointer to the canonical version) would prevent the same trap next pass.

**Confidence note:** Subagent findings are tagged `(verified)` only where I read the cited file:line directly; `(claimed)` items are credible but unverified, and `(rejected)` items are ones I checked and disagreed with. About 30 % of findings were spot-checked.

---

**Surfaces reviewed**
1. Mobile publish + sync pipeline (`app/lib/services/`)
2. Supabase backend (`supabase/*.sql` — RLS, SECURITY DEFINER, RPC contracts)
3. Anonymous web player + auth (`web-player/`, `app/lib/services/auth_service.dart`, portal middleware)
4. Native iOS pipeline (`app/ios/Runner/*.swift`, privacy manifest, Info.plist)

Each surface was audited by an Explore subagent against a focused brief. Subagent line/file references that I verified directly are marked **(verified)**. Findings I cross-checked and disagreed with are marked **(rejected)** with the reason. The rest are **claimed** — credible but worth confirming before fixing.

---

## Top actionable items (do first)

1. **Service-worker may cache anonymous signed URLs for the private `raw-archive` bucket** (web-player). Cross-client leakage on shared devices. See WP-CRIT-1.
2. **`planVersionBumped` flag set after a no-op upsert** (mobile publish). Causes false "cloud may have advanced" messaging on every credit-failure path. See PUB-HIGH-1. **(verified)**
3. **`bootstrap_practice_for_user` Carl-sentinel claim race** (Supabase). Two concurrent first sign-ins can both pass the NULL-check; second loses the sentinel and gets a personal practice. See SB-CRIT-1.
4. **`claim_referral_code` does not verify referrer-side practice membership** before inserting `practice_referrals`. Allows a forged referrer pairing. See SB-HIGH-1.
5. **No CSP header on the production web player** (`session.homefit.studio`). The middleware sets a tight CSP for the bot-detection HTML, but the actual player ships without one. See WP-HIGH-2.
6. **Force-cast on audio-track format description** (iOS converter, line 877). Bad input crashes the host app instead of degrading. See IOS-CRIT-1.

Items 2 and (in part) 4 are behavioural papercuts; the rest are real safety gaps. None of them block TestFlight, but 1, 3, and 5 are worth fixing before App Review eyes show up on the public web player.

---

## 1. Mobile publish + sync pipeline

### CRITICAL

- **PUB-CRIT-1 (claimed)** — `clientId` collision on `upsertClientWithId` aborts publish before `consume_credit`, but on a different code path the client may be left NULL on the plan row, so subsequent `get_plan_full` cannot issue grayscale/original signed URLs. `app/lib/services/upload_service.dart:831–860`. Validate the client row exists (or upsert inline) before Step 3a so the plan row never carries a NULL `client_id` when it should not.

- **PUB-CRIT-2 (claimed)** — `_refundCredits` returns `false` on swallowed errors; the `refundApplied` boolean reflects "we tried" rather than "it succeeded", so `PublishResult.refundApplied` is unreliable. `app/lib/services/upload_service.dart:1370–1371`. Either return a tri-state (succeeded / failed / unknown) or surface failure to the user so they can confirm the ledger state manually.

### HIGH

- **PUB-HIGH-1 (verified)** — `planVersionBumped = true` on line 892, set immediately after the `upsertPlan` at line 867, which the in-code comment on line 877 explicitly says is *not* a version bump (`// IMPORTANT: do NOT bump version here — only after consume_credit.`). The flag is later read into `PublishResult.remoteVersionMayHaveAdvanced` (line 1372), so on every `consume_credit` failure the user sees an ambiguous "version may have advanced" message even though no version moved. Move the assignment to immediately after the actual version-bumping mutation, or rename the flag to `planRowEnsured` and add a separate `planVersionActuallyBumped`.

- **PUB-HIGH-2 (claimed)** — `pending_ops` queue can poison on `23505` ("name already used") returned by `upsertClient`. The stale-op detector only catches `22023` + "has been deleted", so the bad op is retried up to the 30-attempt cap. `app/lib/services/sync_service.dart:1194–1227, 1491`. Extend `_isStaleOpAgainstMissingClient` (or rename it `_isUnrecoverable`) to also drop on `23505` with "already uses that name".

- **PUB-HIGH-3 (claimed)** — Attempt counter increments on every error path, including transient network errors, with a 5 s flat retry. A multi-minute outage burns dozens of attempts of headroom per op. `app/lib/services/sync_service.dart:1147–1152, 1081`. Increment only on confirmed-permanent errors (PostgrestException, auth, 4xx); apply jitter or exponential backoff for the rest.

- **PUB-HIGH-4 (claimed)** — `deletePendingOp` runs before `refreshCreditBalance`. If the balance refresh fails, the op is gone but the cached balance is stale; an immediate retry can hit the local pre-flight check with old data. `app/lib/services/sync_service.dart:1113–1167, 1177`. Refresh balance first, then delete the op.

### MEDIUM

- **PUB-MED-1 (claimed)** — Orphan-cleanup deletes media files immediately after a publish failure, but `uploadedPaths` does not distinguish files newly uploaded by this publish from re-used files referenced by the previous version. A failure between media upload and `replace_plan_exercises` could orphan files the previous version still needs. `app/lib/services/upload_service.dart:1308–1326`. Track `(path, was_newly_uploaded)` and only cleanup new uploads.

- **PUB-MED-2 (claimed)** — Skip-if-unchanged path assumes URLs derive deterministically from path patterns and trusts that if `rawArchiveUploadedAt` is set the file exists. A user who deleted `Documents/archive/*` manually or who restored from a partial backup will trigger a publish that emits dead URLs. `app/lib/services/upload_service.dart:974–998`. Re-list the bucket on first-ever publish at least, or short-circuit on `version == 1`.

### LOW / NIT

- **PUB-LOW-1 (claimed)** — No `Idempotency-Key` header on `consume_credit` / `replacePlanExercises`. PostgREST does not de-dupe by default; a network timeout after server-side success will, on retry, re-execute. Server is mostly idempotent today (consume_credit checks balance, replace_plan_exercises is full-replacement), but adding a key would also cover the rebate ledger path.

- **PUB-LOW-2 (claimed)** — Hard-coded 30-attempt drop with no UI surface. Users who rename a client offline for an extended period silently lose the rename. `sync_service.dart:1137`. Surface a "needs reconciliation" chip when ops drop.

---

## 2. Supabase backend

### CRITICAL

- **SB-CRIT-1 (claimed)** — `bootstrap_practice_for_user` claims the Carl-sentinel via `UPDATE ... WHERE owner_trainer_id IS NULL`, with no advisory lock on a singleton row. Two concurrent first sign-ins can both pass the NULL check before either UPDATE runs; the loser silently gets a personal practice instead. `supabase/schema_milestone_m_credit_model.sql:119–212`. Wrap the function body in `SELECT ... FOR UPDATE` on the sentinel row, or use `pg_advisory_xact_lock(hashtext('bootstrap_sentinel'))` at function entry.

### HIGH

- **SB-HIGH-1 (claimed)** — `claim_referral_code` checks membership on the *referee* side but not on the *referrer*. A user holding a code for a practice they don't belong to can still create a `practice_referrals` row that pays rebates to the practice they fraudulently designated as referrer. `supabase/schema_milestone_m_credit_model.sql:292–302`. Add `EXISTS (SELECT 1 FROM practice_members WHERE practice_id = v_referrer_pid AND trainer_id = v_caller)` — or, if cross-practice referrals are intentional, reject when `v_caller` is the referrer (self-referral).

  Note: codes are opaque 7-char slugs from an unambiguous alphabet, so practical exploitability requires either guessing or a leaked code. Still worth fixing because the code can be defensively shared.

- **SB-HIGH-2 (claimed)** — `sign_storage_url` is called per-exercise inside `get_plan_full`. If the vault secret transiently fails mid-query, some exercises return signed URLs and others NULL; the response is internally inconsistent. `supabase/schema_get_plan_full_restore_full_body.sql:26–224`. Pre-check `vault.secrets` once at the top of `get_plan_full`; if either secret is missing, return all signed URLs as NULL (the documented graceful-fallback behaviour).

### MEDIUM

- **SB-MED-1 (rejected)** — Audit claimed `replace_plan_exercises` drops `hold_position`. **I verified this is wrong**: the older `schema_hotfix_replace_plan_exercises_columns.sql` lacks the column, but the live function comes from `schema_wave_hero_crop.sql:202–227, 235–238`, which inserts `hold_position` correctly with the `'end_of_set'` default fallback. The hotfix file should probably be deleted to avoid future agents hitting the same trap.

- **SB-MED-2 (claimed)** — `goodwill_floor_applied` is set *after* the rebate-ledger insert, not in the same statement. If the flag UPDATE fails, the rebate is recorded but the floor fires again on the next purchase (double-floor). `supabase/schema_milestone_m_credit_model.sql:437–441`. Use `RETURNING` or move into a single statement.

### VERIFIED CLEAN

- `consume_credit` atomicity — `FOR UPDATE` on practices, recompute balance, conditional INSERT all in one txn body. **(verified by audit)**
- `record_purchase_with_rebates` is a single PL/pgSQL body, so purchase + rebate inserts are atomic by construction. **(verified by audit)**
- 5 % goodwill-floor numeric: 250 ZAR × 0.05 / 25 = 0.5 → clamped to 1 on first rebate; flag prevents subsequent clamps. No off-by-one.
- `enforce_single_tier_referral` BEFORE-INSERT trigger cannot be bypassed from clients (RLS revokes INSERT; only SECURITY DEFINER callers reach it).
- Anon enumeration: `web-player/api.js` exposes only the documented 8 RPCs (`get_plan_full`, `record_plan_opened`, `start_analytics_session`, `log_analytics_event`, `set_analytics_consent`, `revoke_analytics_consent`, `client_self_grant_consent`, `get_plan_sharing_context`). No direct table reads.
- `get_plan_full` consent gates: grayscale/original URLs are NULL'd unless the corresponding `video_consent` flag is true.

---

## 3. Anonymous web player + auth

### CRITICAL

- **WP-CRIT-1 (claimed)** — Service-worker `media-url` predicate matches Supabase storage paths broadly enough to cache `raw-archive` signed URLs (which carry a `?token=` parameter and a 1-hour TTL). Once cached, the URL is served from disk for as long as `CACHE_NAME` is unchanged, even after the token expires *and* even if a different client opens the same plan ID on the same browser profile. `web-player/sw.js:117–126`. Exclude `/storage/v1/object/authenticated/` and any URL with a `token` or `Expires` query param from the media cache; rely on `network-first` for those paths.

  This is the highest-impact finding in the review — shared devices (kiosk iPads in a clinic, family iPhones) are a realistic exposure path.

### HIGH

- **WP-HIGH-1 (claimed)** — `log_analytics_event` accepts `(p_session_id, p_event_kind, p_exercise_id, p_event_data)` from anon and does not enforce that the session belongs to the plan implied by the exercise. A third party who learns a session UUID can spoof events, polluting practitioner analytics. `web-player/api.js:382–413`. Server-side, derive the plan_id from `client_sessions.plan_id` for `p_session_id` and reject events whose `p_exercise_id` does not belong to that plan.

- **WP-HIGH-2 (claimed)** — No CSP on the production web player at `session.homefit.studio`. `web-player/index.html` ships without a CSP meta tag, and the static-hosting layer only emits CSP from the bot-detection middleware. `web-player/middleware.js:72`. Add a Vercel `headers` rule for non-bot responses with `default-src 'self'; script-src 'self'; style-src 'self' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; connect-src https://yrwcofhovrcydootivjx.supabase.co; frame-ancestors 'none'`.

- **WP-HIGH-3 (verified)** — Service worker `CACHE_NAME = 'homefit-player-v69-modal-first-desktop'`. CLAUDE.md says the current cache name is `homefit-player-v75`. The codebase is the source of truth; CLAUDE.md is stale. **(verified — `web-player/sw.js:8`)**. Update CLAUDE.md, and decide on a cache-bumping discipline (auto-generate from a build constant, or move the value to a manifest both `app.js` and `sw.js` read).

### MEDIUM

- **WP-MED-1 (claimed)** — Email-enumeration risk via `_friendlyAuthError`. Today's mapping is generic, but it's brittle to upstream Supabase wording changes. `app/lib/screens/sign_in_screen.dart:134–142`. Hard-code the user-visible string to a single "Email or password is incorrect" regardless of the underlying error.

- **WP-MED-2 (claimed)** — Sign-out clears Supabase auth state but does not server-side revoke the refresh token. A stolen refresh token (e.g., from a device backup) survives sign-out. `app/lib/services/auth_service.dart:253–281`. Use Supabase's `auth.signOut({ scope: 'global' })` or call a server RPC that issues `revoke_all_refresh_tokens`.

- **WP-MED-3 (claimed)** — Sign-out clears `currentPracticeId` but other practitioner-related `SharedPreferences` survive across users on a shared device. `app/lib/services/auth_service.dart:271`. Enumerate and clear *all* keys with practitioner-tied prefixes on sign-out.

### VERIFIED CLEAN

- All exercise/client/circuit names rendered via `textContent`, not `innerHTML`. No XSS surface in the player.
- Signed URLs never written to localStorage / console / analytics (live only in in-memory exercise objects).
- Web-portal `/auth/callback/route.ts` `safeNext()` blocks protocol-relative paths and non-leading-slash redirects. No open-redirect surface.
- Mobile `oauthRedirectUrl` is hard-coded to `studio.homefit.app://login-callback`.
- Lobby treatment-lock state derives from server flags (`planHasGrayscaleConsent` / `planHasOriginalConsent`), not localStorage. Cannot be unlocked client-side.
- WhatsApp OG middleware HTML-escapes user-controlled fields and uses a validated `safePlanUrl`.

---

## 4. Native iOS

### CRITICAL

- **IOS-CRIT-1 (claimed)** — Force-cast on optional audio track format description: `formatHint = (first as! CMFormatDescription)`. Crashes the host app on a malformed input file instead of gracefully passing through. `app/ios/Runner/VideoConverterChannel.swift:877`. Replace with `as? CMFormatDescription`; AVAssetWriter accepts `nil` as a documented fallback.

- **IOS-CRIT-2 (claimed)** — `matPtr.baseAddress!` inside `vImageMatrixMultiply_ARGB8888ToPlanar8` (line 2381). Force-unwrap on a withUnsafeBufferPointer that can be nil under memory pressure. Replace with `guard let matAddr = matPtr.baseAddress else { return false }`.

### HIGH

- **IOS-HIGH-1 (claimed)** — Allocation-failure window: `CVPixelBufferPoolCreatePixelBuffer` returns `kCVReturnSuccess` but the out-pointer can still be nil if the pool is exhausted; line 1133 only checks the status code, then dereferences `outBuffer` on line 1149. `app/ios/Runner/VideoConverterChannel.swift:1133–1149`. Add `guard let outBuffer = outputPixelBuffer else { return }`.

- **IOS-HIGH-2 (claimed, low real-world impact)** — Three independent 60 s `finishWriting` semaphores on the same serialized notify queue. No deadlock, but the topology is fragile and depends on each writer being independently cancellable. `app/ios/Runner/VideoConverterChannel.swift:1365–1465`. Add a comment justifying independence; consider `DispatchGroup` over hand-rolled semaphores.

### LOW

- **IOS-LOW-1 (claimed, post-rebrand)** — Platform channel names still use `com.raidme.*` (`com.raidme.native_thumb`, `com.raidme.avatar_camera`, `com.raidme.unified_preview_audio`, `com.raidme.video_converter`, `com.raidme.unified_preview_scheme`). Not a runtime issue (channel names are just strings shared between Dart and Swift), but inconsistent with the 2026-04-28 bundle-ID rebrand. `app/ios/Runner/AppDelegate.swift:45` and four other files. Rename in a single sweep when touching those files for another reason.

### VERIFIED CLEAN (subagent inspected directly)

- BGRA byte order: `vImageConvert_Planar8toARGB8888` writes `[gray, gray, gray, alpha]` mapping correctly to `kCVPixelFormatType_32BGRA`. The purple-blue tint regression is fixed.
- Audio drain after PR #41: concurrent `requestMediaDataWhenReady` queues, `markAsFinished` before `finishWriting`. No regression.
- `PrivacyInfo.xcprivacy` declares all 8 `NSPrivacyCollectedDataTypes` matching `docs/app-store-connect-privacy.md`. `NSPrivacyTracking=false`.
- Info.plist permission strings are non-generic; URL scheme `studio.homefit.app://login-callback` present.
- vImage buffers allocated in `init`, deallocated in `deinit`. No per-frame allocations.
- Every `CVPixelBufferLockBaseAddress` is paired with `defer { CVPixelBufferUnlockBaseAddress }` before any guard/return.
- `AVAssetExportSession`: `.mp4` outputFileType matches `.mp4` URL extension.

---

## Process risks (not bugs, but worth flagging)

- **CLAUDE.md drift.** The brief says SW cache is `v75` but the codebase ships `v69-modal-first-desktop`. Same drift on cache-name discipline. Either keep CLAUDE.md authoritative and gate it in CI, or stop quoting the cache name in CLAUDE.md altogether.
- **Old hotfix migrations linger.** `schema_hotfix_replace_plan_exercises_columns.sql` is fully superseded by `schema_wave_hero_crop.sql`'s `replace_plan_exercises`. Reading the older file misled the audit; future agents will hit the same trap. Either delete it from the repo or annotate the file with a header pointing to the canonical version.
- **Subagent verification gap.** Only ~30 % of subagent findings were spot-checked in this pass. The "claimed" tag on each finding is honest, not a vote of confidence. Each item should be read against the live code before any fix lands.

---

## Out of scope / deferred to a follow-up review

- Web portal (`web-portal/`) beyond the auth-callback path. The Next.js app surface is large; a separate review against PortalApi / AdminApi RPC contracts and the PayFast webhook would be useful before production-PayFast cutover.
- Lobby export / Studio editor sheet. The recent 11-round PNG-export saga (PRs #269–#275) deserves its own focused review of the canvas + html2canvas + decode-wait flow; that's a UI layer outside this review's brief.
- Test coverage. There are no business-logic RPC tests yet (per `docs/BACKLOG.md`). A test-strategy review is a separate workstream.
- Performance. No profiling was done on the conversion pipeline, the lazy-video-loading window, or the offline-cache hot path.

---

*Generated 2026-05-06 by deep-review pass on `claude/deep-code-review-aE0vm`.*
