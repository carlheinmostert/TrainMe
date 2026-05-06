# Deep Code Review — 2026-05-06

**Branch:** `claude/deep-code-review-aE0vm`
**Scope:** Risk-focused review of the load-bearing paths ahead of the first TestFlight upload. UI polish, design parity, and the line-drawing v6 aesthetic are deliberately out of scope.

---

## Executive summary

After reading every cited file:line directly, the codebase is in better shape than the first-pass audit suggested. About half of the subagent findings were rejected on verification — many were defensive code paths the audit missed, and a few were Postgres semantics the audit got wrong. The verified-real findings are below.

**Nothing here blocks the first TestFlight upload.** Three items are worth fixing before the public web player gets more eyeballs:

1. **iOS force-cast on audio-track format hint** *(verified)*. `VideoConverterChannel.swift:877` uses `as!` on `audioTrack.formatDescriptions.first`. The surrounding comment claims "conditional-cast so we pass nil cleanly", but the code does the opposite. Practical risk is near-zero (AVFoundation always returns `CMFormatDescription`), but the contradiction between comment and code is a fix-while-you're-there. One-line change.
2. **No CSP header on production web player** *(verified)*. `web-player/index.html` ships with no CSP meta tag, and the static-host layer doesn't add one. The bot-detection middleware emits a tight CSP for crawlers only. One Vercel `headers` rule fixes it.
3. **`planVersionBumped` flag set after a no-op upsert** *(verified)*. `upload_service.dart:892`, immediately after an upsert whose own comment (line 877) says "do NOT bump version here". The flag is read into `PublishResult.remoteVersionMayHaveAdvanced`, so every credit-failure path emits a misleading "version may have advanced" message. Cosmetic but recurring source of support confusion.

**Worth fixing post-MVP** (verified, but narrower scope than the original audit suggested):

4. **Service-worker can serve `raw-archive` signed URLs past consent revocation** for the same client. `web-player/sw.js:117–150`. The audit framed this as cross-client leakage; on closer reading, exact-URL cache keys plus 1-hour rolling tokens make cross-client collision essentially impossible. The real risk is that a client whose practitioner revokes grayscale/original consent keeps watching from the SW cache.
5. **`log_analytics_event` doesn't bind `p_session_id` to a plan**, allowing event spoofing if a session UUID is leaked. `schema_wave17_analytics.sql:177–213`. UUIDs aren't enumerable, so this is defense-in-depth, not an active exploit.
6. **`signOut()` uses Supabase's default `local` scope** — refresh token survives on the server. `auth_service.dart:262–282`. Pass `SignOutScope.global` for full revocation.

**Rejected on verification** (full list in section 5): nine of the original "claimed" findings, including all three publish-pipeline CRITICAL items, the bootstrap-practice race, the `claim_referral_code` referrer-side check, the `hold_position` column drift, and two iOS force-unwrap claims. See the verification log for what each spot-check showed.

**Process risks worth fixing:** CLAUDE.md cites SW cache `v75`; the codebase ships `v69-modal-first-desktop` *(verified)*. The superseded `schema_hotfix_replace_plan_exercises_columns.sql` lingers and was the source of the rejected `hold_position` finding — annotate or delete.

---

## 1. Mobile publish + sync pipeline

### Verified-real

- **PUB-HIGH-1 (verified)** — `planVersionBumped = true` set on line 892, immediately after an `upsertPlan` whose own comment on line 877 says `// IMPORTANT: do NOT bump version here — only after consume_credit.` The flag is later read into `PublishResult.remoteVersionMayHaveAdvanced` (line 1372), so every `consume_credit` failure surfaces "version may have advanced" even though no version moved. Move the assignment to after the actual version-bumping mutation, or rename the flag to `planRowEnsured` and add a separate `planVersionActuallyBumped`. `app/lib/services/upload_service.dart:892`.

- **PUB-MED-3 (verified, partial)** — Attempt counter on `pending_ops` increments on every error path including transient network blips (`sync_service.dart:1147–1152`). The 5 s flat retry-cooldown on line 1081 lessens the impact, but a multi-hour outage with periodic transient errors can still walk an op toward the 30-attempt drop. Increment only on permanent errors (`PostgrestException`, auth, 4xx); apply jitter or exponential backoff for transient.

- **PUB-MED-4 (verified, partial)** — `deletePendingOp` runs synchronously after `_applyOp` succeeds (line 1116), but the post-flush `pullAll` that refreshes the cached credit balance is fire-and-forget (line 1177, `unawaited`). If the refresh fails, the op is gone but the local balance is stale; the next user-triggered publish pre-flight uses old data. Impact is brief — `pullAll` runs again on next reconnect — but a `await pullAll(pid)` inside the loop, or moving the balance refresh ahead of the delete, would tighten the window.

- **PUB-LOW-2 (claimed, accepted)** — Hard-coded 30-attempt drop with no UI surface. Users who rename a client offline for an extended period silently lose the rename. `sync_service.dart:1137`. Surface a "needs reconciliation" chip when ops drop.

### Rejected on verification

- **PUB-CRIT-1 (rejected)** — Audit claimed `clientId` collision could leave the plan row with NULL `client_id`. **Verified false:** `upload_service.dart:842–860` catches `PostgrestException` from both `upsertClientWithId` and `upsertClient`, maps the 23505 case to a clear user-facing message, and returns `PublishResult.networkFailed` BEFORE reaching `upsertPlan`. The plan row is never created with NULL `client_id` on this path.

- **PUB-CRIT-2 (rejected)** — Audit claimed `_refundCredits` returns `false` on swallowed errors so `refundApplied` is meaningless. **Verified false:** the `PublishFailurePayload` correctly distinguishes the tri-state via `refundLikelyAttempted: creditConsumed` and `refundOutcomeUnknown: creditConsumed && refundApplied != true` (`upload_service.dart:1370–1371`). The user-facing payload accurately reports "we tried, outcome unknown" vs "succeeded".

- **PUB-HIGH-2 (rejected)** — Audit claimed `_isStaleOpAgainstMissingClient` doesn't catch `23505 + 'already uses that name'` for `upsertClient`. **Verified false:** `sync_service.dart:1503–1508` explicitly handles exactly that case and drops the op.

- **PUB-MED-1 (rejected)** — Audit claimed orphan-cleanup deletes media files re-used by previous versions. **Verified false:** `uploadedPaths` is only appended on actual `_api.uploadMedia` calls (`upload_service.dart:1014, 1037, 1049, 1070`); the existence-check loop on line 1035 skips files already in storage, so they are never added to `uploadedPaths`. Only files newly uploaded by THIS publish can be cleaned up.

- **PUB-MED-2 (rejected)** — Audit claimed the skip-if-unchanged path could fire on first-ever publish with dead URLs. **Verified false:** `allPreviouslyUploaded` (line 974–976) requires every non-rest exercise to have `rawArchiveUploadedAt != null`; on first publish that's null for all exercises, so the fast-path is skipped and the existence-check + upload pass runs.

- **PUB-LOW-1 (claimed, low priority)** — No `Idempotency-Key` header on `consume_credit` / `replacePlanExercises`. Both server-side functions are idempotent by construction (`consume_credit` checks balance + creates a single ledger row; `replacePlanExercises` is full-replacement on the planId). Adding a key would be defense-in-depth on the rebate ledger path; not urgent.

---

## 2. Supabase backend

### Verified-real

(Nothing critical or high. The Supabase audit's spot-checked items either passed verification on first inspection or were rejected.)

- **SB-LOW-1 (claimed, defensible)** — `sign_storage_url` is called per-exercise inside `get_plan_full`. If the vault secret transiently fails mid-query, some exercises return signed URLs and others NULL. In practice the vault is stable, and the function gracefully degrades to line-drawing; the inconsistency window is theoretical. Pre-checking vault secrets once at the top of `get_plan_full` would tighten this.

### Rejected on verification

- **SB-CRIT-1 (rejected)** — Audit claimed `bootstrap_practice_for_user` has a sentinel-claim race because the `UPDATE ... WHERE owner_trainer_id IS NULL` has no advisory lock. **Verified false:** Postgres acquires a row-level write lock during UPDATE, and under read-committed (the default) the WHERE clause is re-evaluated against the locked row's current state (`EvalPlanQual`). A concurrent second UPDATE will block on the lock, then re-check `owner_trainer_id IS NULL`, find it false (the first transaction set it), and return zero rows. `v_claimed` is correctly set to `false` and Path (c) runs. The race the audit described doesn't exist. `schema_milestone_m_credit_model.sql:159–172`.

- **SB-HIGH-1 (rejected)** — Audit claimed `claim_referral_code` doesn't check referrer-side membership. **Verified misframed:** the function checks the *caller* is a member of the *referee* practice (line 261–269), which is the correct check. The "referrer" is whoever owns the code — by definition they get the rebate, regardless of whether the caller is also a member. Adding a "caller must be a member of the referrer" check would defeat the only legitimate use case (claiming someone else's code). Codes are 7-char opaque slugs; the only realistic attack is a leaked code, which the function correctly handles by accepting the claim.

- **SB-MED-1 (rejected, repeated from prior pass)** — `replace_plan_exercises` does not drop `hold_position`. The hotfix file `schema_hotfix_replace_plan_exercises_columns.sql` lacks the column, but it has been superseded by `schema_wave_hero_crop.sql:202–238`, which correctly handles `hold_position` with the `'end_of_set'` default fallback.

- **SB-MED-2 (rejected)** — Audit claimed `goodwill_floor_applied` could double-apply if the flag UPDATE fails after the rebate INSERT. **Verified false:** both statements execute within a single PL/pgSQL function body (`record_purchase_with_rebates`), which Postgres treats as one transaction. There is no partial-commit point between them; either both succeed or both roll back.

### Verified clean (subagent inspected directly)

- `consume_credit` atomicity — `FOR UPDATE` on practices, recompute balance, conditional INSERT in one txn body.
- `record_purchase_with_rebates` — single PL/pgSQL function body = atomic by construction.
- 5 % goodwill-floor numeric: 250 ZAR × 0.05 / 25 = 0.5 → clamped to 1 on first rebate; flag prevents subsequent clamps. No off-by-one.
- `enforce_single_tier_referral` BEFORE-INSERT trigger cannot be bypassed from clients (RLS revokes INSERT; only SECURITY DEFINER callers reach it).
- Anon enumeration: `web-player/api.js` exposes only the documented 8 RPCs. No direct table reads.
- `get_plan_full` consent gates: grayscale/original URLs are NULL'd unless the corresponding `video_consent` flag is true.

---

## 3. Anonymous web player + auth

### Verified-real

- **WP-HIGH-1 (verified)** — `web-player/index.html` ships with no CSP meta tag, and the static-host layer doesn't add one. Only `web-player/middleware.js:72` emits a CSP, and only on the bot-detection branch. Add a Vercel `headers` rule for non-bot responses with `default-src 'self'; script-src 'self'; style-src 'self' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; connect-src https://yrwcofhovrcydootivjx.supabase.co; frame-ancestors 'none'`.

- **WP-HIGH-2 (verified)** — Service worker `CACHE_NAME = 'homefit-player-v69-modal-first-desktop'` (`web-player/sw.js:8`). CLAUDE.md says current cache name is `homefit-player-v75`. Codebase is the source of truth; CLAUDE.md is stale.

- **WP-MED-1 (verified, downgraded from CRITICAL)** — Service worker caches signed URLs to the private `raw-archive` bucket. `isMediaRequest` (`sw.js:147–151`) matches purely on URL extension, so any path ending in `.mp4`/`.mov`/`.webm` is cached, including `/storage/v1/object/sign/raw-archive/...`. Downgraded from the audit's CRITICAL framing because cache keys include the full URL with query string, and signed URLs use 1-hour rolling tokens, so cross-client cache collision is essentially impossible. The real risk: a client whose practitioner revokes grayscale/original consent keeps watching from the SW cache until `CACHE_NAME` increments. Add an explicit `if (url.pathname.includes('/object/sign/'))` short-circuit in the fetch handler that skips caching.

- **WP-MED-2 (verified)** — `log_analytics_event` validates session existence and consent (`schema_wave17_analytics.sql:193–199`) but does not validate that `p_exercise_id` belongs to the same plan as `p_session_id`, nor that `p_event_kind` is in the documented enum. An attacker who learns a session UUID can pollute analytics. Session UUIDs aren't enumerable (256 bits), so the threat model is narrow — defense-in-depth, not an active exploit.

- **WP-MED-3 (verified)** — `signOut()` calls `Supabase.instance.client.auth.signOut()` with the default `local` scope (`auth_service.dart:270`), which clears the session client-side but does not revoke the refresh token server-side. A refresh token recovered from a device backup or stolen device survives the sign-out. Pass `SignOutScope.global` to revoke all sessions on the server.

- **WP-MED-4 (claimed, accepted)** — Sign-out clears `currentPracticeId` and the `_selectedPracticeIdPrefsKey` SharedPreference but no other practitioner-tied keys. On a shared device, prior-user state can persist. Enumerate and clear all practitioner-tied keys on sign-out.

### Rejected on verification

- **WP-MED-5 (rejected)** — Audit claimed potential email-enumeration via `_friendlyAuthError`. **Verified false:** `sign_in_screen.dart:134–143` only branches on "rate-limited" / "invalid email format" / generic. The mapping returns the same generic "Couldn't send link. Try again." for both unknown-email and wrong-password. Even if Supabase ever distinguishes the underlying error, the client-side mapping does not.

### Verified clean (subagent inspected directly)

- All exercise/client/circuit names rendered via `textContent`, not `innerHTML`. No XSS.
- Signed URLs never written to localStorage / console / analytics (live only in in-memory exercise objects).
- Web-portal `safeNext()` blocks protocol-relative paths and non-leading-slash redirects. No open-redirect.
- Mobile `oauthRedirectUrl` is hard-coded to `studio.homefit.app://login-callback`.
- Lobby treatment-lock state derives from server flags, not localStorage. Cannot be unlocked client-side.
- WhatsApp OG middleware HTML-escapes user-controlled fields and uses a validated `safePlanUrl`.

---

## 4. Native iOS

### Verified-real

- **IOS-HIGH-1 (verified)** — Force-cast on optional audio track format description: `formatHint = (first as! CMFormatDescription)`. The surrounding comment on lines 873–874 says "Conditional-cast so we pass nil cleanly if the array is empty (edge case — shouldn't happen for a real track)" — but the code uses `as!`, not `as?`. AVFoundation does always return `CMFormatDescription` here, so practical crash risk is near-zero, but the comment-vs-code mismatch is a paper cut. `app/ios/Runner/VideoConverterChannel.swift:877`. Replace with `formatHint = first as? CMFormatDescription`.

- **IOS-LOW-1 (claimed, accepted)** — Platform channel names still use `com.raidme.*` after the 2026-04-28 bundle-ID rebrand. Not a runtime issue (channel names are decoupled from bundle IDs), but inconsistent. Rename in a single sweep when those files are touched for another reason.

- **IOS-NIT-1 (claimed, downgraded)** — Three independent 60 s `finishWriting` semaphores on the same serialized notify queue (`VideoConverterChannel.swift:1365–1465`). Topology is fragile but no actual deadlock. Add a comment justifying independence; consider `DispatchGroup` over hand-rolled semaphores if anything in this area is touched.

### Rejected on verification

- **IOS-CRIT-2 (rejected)** — Audit claimed `matPtr.baseAddress!` could be nil under memory pressure. **Verified false:** `withUnsafeBufferPointer` on a non-empty Swift array is documented to return non-nil `baseAddress`. The matrix `[Int16] = [28, 151, 77, 0]` (line 2376) has count > 0 by construction, so the force-unwrap is guaranteed safe. `VideoConverterChannel.swift:2381`.

- **IOS-HIGH-1 / pool exhaustion (rejected)** — Audit recommended adding `guard let outBuffer = outputPixelBuffer else { return }`. **Verified false:** `VideoConverterChannel.swift:1133–1135` already has exactly that guard: `guard allocStatus == kCVReturnSuccess, let outBuffer = outputPixelBuffer else { return }`. The audit was looking at a phantom version.

### Verified clean (subagent inspected directly)

- BGRA byte order: `vImageConvert_Planar8toARGB8888` writes correctly mapping to `kCVPixelFormatType_32BGRA`. Purple-blue tint regression fixed.
- Audio drain after PR #41: concurrent queues, `markAsFinished` before `finishWriting`. No regression.
- `PrivacyInfo.xcprivacy` declares all 8 `NSPrivacyCollectedDataTypes`. `NSPrivacyTracking=false`.
- Info.plist permission strings are non-generic; URL scheme `studio.homefit.app://login-callback` present.
- vImage buffers allocated in `init`, deallocated in `deinit`. No per-frame allocations.
- Every `CVPixelBufferLockBaseAddress` is paired with `defer { CVPixelBufferUnlockBaseAddress }`.
- `AVAssetExportSession`: `.mp4` outputFileType matches `.mp4` URL extension.

---

## 5. Verification log — what the second pass checked

Every `(verified)` and `(rejected)` tag above corresponds to a direct read of the cited file:line during this review. The convention:

- **(verified)** — finding holds after reading the live code.
- **(rejected)** — finding does not hold; the verification line gives the reason.
- **(claimed, accepted)** — finding plausible from the audit's reading; not directly contradicted by spot-check, but worth confirming on the day of the fix.
- **(claimed, defensible)** — theoretical concern; very low real-world risk.
- **(verified, partial)** — finding has a real basis but the impact is narrower than the audit framed.

All `(rejected)` items are the result of the audit looking at older / superseded code, missing surrounding error-handling, or being wrong about Postgres semantics. The most common rejection cause was "the defensive code path the audit recommended already exists immediately after the cited line".

---

## Out of scope / deferred to a follow-up review

- Web portal (`web-portal/`) beyond the auth-callback path. Worth its own pass before production-PayFast cutover.
- Lobby export / Studio editor sheet. The PNG-export saga (PRs #269–#275) deserves a focused review.
- Test coverage. No business-logic RPC tests yet (per `docs/BACKLOG.md`). Separate workstream.
- Performance profiling (conversion pipeline, lazy-video-loading window, offline-cache hot path).

---

*Generated 2026-05-06. Verified pass on `claude/deep-code-review-aE0vm`.*
