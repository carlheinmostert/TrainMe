# Session Checkpoint — 2026-04-21

> **Hi future Claude.** Carl will greet you with "Where were we?" in a fresh session.
> Read this doc + `CLAUDE.md` + `docs/test-scripts/index.html` first.

## One-sentence status

**Marathon sprint: 7 wave PRs merged (Waves 4 Phase 2, 5, 7, 8, 9, 10, 11), Wave 14 added (add-member-by-email replaced Wave 5's invite-code half), Wave 15 added (offline-sync robustness), Wave 13 scheduled (Resend SMTP), Wave 4 Phase 1 QA passed 12/12 on device, Wave 5+14 QA in flight awaiting Carl's return to reconnect the device.**

## The arc of today

Morning handoff: Carl opened with "where were we?" and I read the 2026-04-20-late checkpoint. Queue had 7 wave implementations merged + awaiting device QA (Waves 4 P2, 5, 7, 8, 9, 10, 11). The day became a cascade:

1. **Merge train** — all 7 waves merged in suggested order with Carl's explicit approval. Two PRs needed manual rebase + force-push (#80 Wave 10, #82 Wave 11) — types regen + settings_screen conflict resolutions.

2. **Install-device** for first device QA. Immediately broke on Wave 4 Phase 2 test 1.1 — unified preview said "Plan not found". Root cause: Phase 1 agent had flagged this exact landmine in their surprises list — `isLocalSurface()` in `web-player/api.js` only accepted `127.0.0.1` / `localhost` hostnames, not the new `homefit-local://plan/…` scheme's `plan`. [PR #84](https://github.com/carlheinmostert/TrainMe/pull/84).

3. **App crash on next-exercise swipe.** `WKURLSchemeTask` throws Obj-C `NSInternalInconsistencyException` (Swift can't catch) if `didReceive` / `didFinish` is called after WebKit invokes `stop:` on the task. When practitioner swipes to next exercise, WebKit aborts previous `<video>` load; our async file-read completes in background and calls `task.didReceive` on a stopped task → SIGABRT. Fixed with `Set<ObjectIdentifier>` of stopped tasks + `safeDidReceive` / `safeDidFinish` / `safeDidFail` helpers. [PR #86](https://github.com/carlheinmostert/TrainMe/pull/86).

4. **Wave 4 Phase 2 QA: 12/12 pass.** Results committed as audit trail ([PR #87](https://github.com/carlheinmostert/TrainMe/pull/87)). Index.html moved Wave 4 P2 out of active bucket into Past waves ([PR #88](https://github.com/carlheinmostert/TrainMe/pull/88)) — Carl flagged this as a pattern: "gives me a happy feeling when I don't have to look at it." Saved to memory as feedback rule.

5. **Wave 5 QA — SQL bug cascade.**
   - Test 1.1: `/members` page shows no members. Root cause: `list_practice_members_with_profile` used `= ANY (public.user_practice_ids())` but `user_practice_ids()` is a set-returning function → `42809: op ANY/ALL (array) requires array on right side`. PostgREST 500 → portal silent empty. [PR #89](https://github.com/carlheinmostert/TrainMe/pull/89) (use `IN (SELECT …)`).
   - Test: join-as-practitioner crashed with "column reference practice_id is ambiguous" on `claim_practice_invite`. Classic PL/pgSQL 42702 OUT-column shadowing — `IF NOT EXISTS (SELECT 1 FROM practice_members WHERE practice_id = ...)` collided with the RETURNS TABLE OUT column. Alias `practice_members pm` + qualify. [PR #90](https://github.com/carlheinmostert/TrainMe/pull/90).

6. **Email rate limit.** Magic-link testing hit Supabase's built-in SMTP throttle (~4/hr). Logged as **Wave 13 — Resend SMTP** in BACKLOG ([PR #91](https://github.com/carlheinmostert/TrainMe/pull/91)) with a full playbook. Will lift the throttle when Carl has 10 min to do the Resend signup + Hostinger DNS + Supabase dashboard config.

7. **Pivot: kill invite-code flow, replace with add-by-email.** Carl pushed back on the Wave 5 invite-code UX — too much friction to QA (needs private windows or separate browser profiles, magic-link throttle, etc.). Proposed direct-add-by-email; he asked "why can't we just record a pending row and auto-claim on signup?" — correct question. Scheduled + shipped as **Wave 14** ([PR #97](https://github.com/carlheinmostert/TrainMe/pull/97)). Owner types email → if `auth.users` has it, instant join; if not, row lands in new `pending_practice_members` table; `auth.users` INSERT trigger drains matching pending rows on signup. Deleted: `practice_invite_codes`, `mint_practice_invite_code`, `claim_practice_invite`, `/join/[code]`, mobile "Join a practice" card.

8. **Stuck pending-ops queue (19 → 25 → 24).** Carl reported 19 delete ops stuck. Diagnostic cascade:
   - Hypothesis 1 (delete_client not idempotent on missing client) → [PR #92](https://github.com/carlheinmostert/TrainMe/pull/92) (delete + restore now RETURN empty on missing row).
   - SyncService doesn't flush on boot — [PR #93](https://github.com/carlheinmostert/TrainMe/pull/93) added drain-on-boot + auth-state listener + `dart:developer` log (profile builds strip `debugPrint` from os_log).
   - Typo: `pendingCount` vs `pendingOpCount` broke the build — [PR #95](https://github.com/carlheinmostert/TrainMe/pull/95).
   - Diagnostics revealed session-not-found 403s — every RPC failing because JWT was revoked. Sign out + sign in, but queue still stuck.
   - Queue had mostly `setExerciseDefault` + `renameClient` + `setConsent` ops on client `fc2c8be9-…` that genuinely doesn't exist on server (never successfully upserted). Fix: drop stale ops against missing clients + 30-attempt cap. [PR #96](https://github.com/carlheinmostert/TrainMe/pull/96).
   - Last stuck op was 23505 "a deleted client already uses that name" — classifier expanded. [PR #98](https://github.com/carlheinmostert/TrainMe/pull/98).
   - Queue finally drained to 0.

9. **Wave 15 — offline-sync robustness.** While Carl was out, shipped three preventative fixes so today's class of bugs can't recur silently:
   - `UpsertClientNullResultException` — null-return upserts now throw + flow through the classifier / attempt cap. (Today's fc2c8be9 ghost was because null-return silently re-queued without incrementing attempts.)
   - `_guardAuth` funnel in `ApiClient` — detects `session_not_found` → forces sign-out → flips a `sessionExpired` ValueNotifier.
   - `SessionExpiredBanner` — coral persistent banner on Home + Studio surfaces the expired-session state. CTA navigates to sign-in, re-auth auto-triggers flush.
   - "Force sync now" on Diagnostics. One-tap manual drain.
   - Polish shipped: `pullAll` on signin + 5s retry backoff.
   - [PR #100](https://github.com/carlheinmostert/TrainMe/pull/100).

10. **`isInspectable = true` on WKWebView** in debug/profile ([PR #101](https://github.com/carlheinmostert/TrainMe/pull/101)). Makes Safari Web Inspector attach cleanly on device; closes the Wave 4 P2 QA gap that required indirect verification.

11. **Housekeeping in flight** (at time of checkpoint write): `chore/simplify-2026-04-21-sprint` agent running a DRY + dead-code pass over today's ~15 PRs.

## PRs merged today (in order)

#83 (list_clients deleted_at), #84 (hostname `plan`), #85 (gitignore results),
#86 (stopped-task guard), #87 (Wave 4 P2 QA results), #88 (index.html shuffle),
#89 (SRF membership guard), #90 (claim_invite ambiguous), #91 (Wave 13 backlog),
#92 (delete/restore idempotent), #93 (sync drain-on-boot), #95 (typo),
#96 (stale-op drop), #97 (**Wave 14**), #98 (classifier expand), #99 (test script rewrite),
#100 (**Wave 15**), #101 (isInspectable).

Plus the initial 7-wave merge train: #72 (Wave 4 P1 was pre-existing, not today), #76 (Wave 5), #77 (Wave 4 P2), #78 (Wave 8), #79 (Wave 7), #80 (Wave 10), #81 (Wave 9), #82 (Wave 11).

## What's on device right now

- **iPhone CHM**, UDID `00008150-001A31D40E88401C` (iPhone 17 Pro).
- **SHA** at last install: PR #100 (post Wave 15). **PR #101 (isInspectable) is NOT on device yet** — Carl is out; reinstall on return.
- Wave 4 P2 QA passed 12/12.

## Wave QA state

| Wave | PR | State |
|---|---|---|
| 4 Phase 2 | [#77](https://github.com/carlheinmostert/TrainMe/pull/77) | ✅ 12/12 passed, results committed |
| 5 + 14 (Members) | [#76](https://github.com/carlheinmostert/TrainMe/pull/76) + [#97](https://github.com/carlheinmostert/TrainMe/pull/97) | 🟡 Live-testing; add-by-email + pending flow confirmed working; full QA deferred until Carl reconnects |
| 7 (observability) | [#79](https://github.com/carlheinmostert/TrainMe/pull/79) | Awaiting device QA |
| 8 (sticky defaults) | [#78](https://github.com/carlheinmostert/TrainMe/pull/78) | Awaiting device QA |
| 9 (audit expansion) | [#81](https://github.com/carlheinmostert/TrainMe/pull/81) | Awaiting device QA |
| 10 (share-kit Phase 3) | [#80](https://github.com/carlheinmostert/TrainMe/pull/80) | Awaiting device QA |
| 11 (mobile share-kit) | [#82](https://github.com/carlheinmostert/TrainMe/pull/82) | Awaiting device QA |
| 15 (sync robustness) | [#100](https://github.com/carlheinmostert/TrainMe/pull/100) | Awaiting device QA + reinstall (PR #101 also needs to roll up) |

## Locked decisions (new today)

- **Wave 14 supersedes Wave 5's invite-code flow.** Direct add-by-email + `pending_practice_members` + `auth.users` INSERT trigger. Single-tier, consent is implicit-by-invite (user can `leave_practice` anytime). No link-based invites in MVP.
- **Wave 15 offline-sync classifier drops stale ops against missing clients.** Specific: 22023 "not found" / "has been deleted", 23505 "deleted client already uses name", RenameClientError(notFound), set_consent returned false. Plus 30-attempt generic safety cap. Plus 5s retry backoff. Plus auto-signout on `session_not_found`.
- **isInspectable = true on debug/profile WebView only.** Release stays off.
- **Results JSON is gitignored** (PR #85). Commit at wave close with `git add -f` as audit trail.
- **Test scripts index: completed waves move to Past section + active bucket renumbers.** Saved as feedback memory.

## Blocked on Carl

- **Device reinstall** after reconnect — PR #101 + #100 need to land on iPhone.
- **Wave 5+14 QA completion** — the full 20-item script once he's back at the desk.
- **Wave 13 Resend SMTP** — 10-min Resend signup + Hostinger DNS + Supabase dashboard config. Full playbook in BACKLOG.
- **Stale PR dispositions** ([#1](https://github.com/carlheinmostert/TrainMe/pull/1), [#9](https://github.com/carlheinmostert/TrainMe/pull/9), [#10](https://github.com/carlheinmostert/TrainMe/pull/10), [#35](https://github.com/carlheinmostert/TrainMe/pull/35)). He said "ignore for now" earlier.
- **Vercel spend**: MTD $4.16 / bill due $0. Well within Pro plan.

## Outstanding waves

| Wave | Status |
|---|---|
| Wave 12+ (share-kit experiments) | Deferred, unscoped |
| Wave 13 (Resend SMTP) | Blocked on Carl |
| Wave 15.5 / 16 (nice-to-haves: dropped-op audit, orphan cleanup, amber chip) | Queued |

All lower-numbered waves (1–11 + 14) are shipped.

## Infrastructure state

- **Supabase** — sentinel practice `00000000-0000-0000-0000-0000000ca71e`. Wave 14 migration applied live (`pending_practice_members` + 3 RPCs + `auth.users` trigger). Recent hotfix migrations all applied.
- **Docs server** — port 3457, still serving.
- **iOS syslog** — `/tmp/ios-syslog.log` grew to 5.5 GB during today's debugging; rotate before it eats the disk.
- **Worktrees** — ~15 locked agent-* worktrees under `.claude/worktrees/`. Safe to `git worktree remove --force` for merged branches; didn't touch without explicit go-ahead.

## Design rules in force

Unchanged: R-01 (undo-not-confirm), R-02, R-06 practitioner vocab, R-08 never `flutter run`, R-09, R-10 player parity, R-11 portal↔mobile twins, R-12 dashboard hygiene. Line-drawing v6 LOCKED.

**New feedback memory entries today:**
- `feedback_test_scripts_move_to_past.md` — move completed waves out of the active bucket.

## How to resume

1. Read `CLAUDE.md`.
2. Read this doc.
3. Read `docs/test-scripts/index.html` — reflects current wave QA state.
4. If Carl says "where were we?" → summarise this arc + list the device-QA backlog.
5. Default next step: `./install-device.sh` to roll PR #101 + #100 onto the phone, then walk Wave 15 test script (11 items) + resume Wave 5+14 (20 items).

**Carl's likely first prompt:** "where were we?" or "let me resume QA". Hand him the wave-15 script first — it's the newest and easiest to stress-test.
