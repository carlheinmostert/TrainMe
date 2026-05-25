# Checkpoint — 2026-05-25 — Self-trainer wave shipped + code-review hotfix wave

**The self-trainer wave is now end-to-end on staging AND a same-day code-review hotfix wave closed 41 findings across 4 PRs.** The morning [foundation wave](./CHECKPOINT_2026-05-25-self-trainer-foundation.md) landed schema + IA + face-embedding + plan_artifacts + privacy docs + CI fix (six PRs). The completion wave that followed landed the practitioner-facing surface and the billing/payment plumbing (six more PRs). Twelve wave PRs in total. After they landed Carl asked for a full code review; five specialist reviewers ran in parallel against staging tip `f47d7f7` and surfaced 10 Criticals + 17 Mediums + a long Low-priority tail — most importantly the `credit_ledger` CHECK constraint that meant every self-trainer free publish would have failed at runtime (empirically confirmed: zero `publish_free` rows existed). Three hot-fix PRs (DB + mobile/iOS + docs) plus one direct-to-main docs commit shipped during the same UTC day to close all 41 actionable findings. Staging tip ended at `50ff86f`, main at `34cfcbc`. iPhone QA install still pending Carl's explicit go.

## Table of Contents

- [Status at session end](#status-at-session-end)
- [What "self-trainer shipped" actually means](#what-self-trainer-shipped-actually-means)
- [The completion wave's six PRs](#the-completion-waves-six-prs)
- [Sub-agent orchestration this session](#sub-agent-orchestration-this-session)
- [Code review + hotfix wave](#code-review--hotfix-wave)
- [Gotchas surfaced today](#gotchas-surfaced-today)
- [Memory entries to capture](#memory-entries-to-capture)
- [Open follow-ups](#open-follow-ups)
- [Blocked on Carl](#blocked-on-carl)
- [Fresh-session handoff](#fresh-session-handoff)

## Status at session end

- **Staging tip:** `50ff86f` — PR #511 (mobile + iOS hotfix). Live on `staging.session.homefit.studio` + `staging.manage.homefit.studio`.
- **Main tip:** `34cfcbc` — Hotfix C main-side commit (BACKLOG placeholder enum + ASC checklist EU region pin). The twelve self-trainer-wave PRs + three hotfix-to-staging PRs are all staging-only pending the next staging → main promotion.
- **Carl's iPhone CHM:** still on the pre-wave build. **No device install happened today** — Carl's standing rule (`feedback_ask_before_mobile_deployment`) keeps deployment as an explicit per-session ask. Recommended next install lands the foundation + completion + hotfix waves together.
- **SQLite schema:** v47 → **v48** (PR #508 added `cached_clients.user_id` to mirror the cloud column that surfaces the Self-client).
- **Supabase migrations applied today (in the wave):**
  - `20260525074056_self_trainer_wave.sql` (foundation #486)
  - `20260525094931_plan_artifacts_on_publish.sql` (foundation #493)
  - `20260525114912_register_self_face_rpc.sql` (foundation #494)
  - `20260525124222_self_verified_publish_plumbing.sql` (#503 self-verification stamping)
  - `20260525140921_publish_cost_preview.sql` (#507 — `preview_publish_cost` + `consume_credit` conditional free path)
  - `20260525144005_revoke_self_face_rpc.sql` (#502 — Self-client backfill)
  - `20260525144158_safe_mode_sub_gate.sql` (#504 Safe Mode subscription gate)
  - `20260525145747_list_practice_clients_user_id.sql` (#508 — exposes `clients.user_id` on the practice listing RPC)
  - `20260525160312_self_trainer_hotfix.sql` (#509 — hotfix A: credit_ledger CHECK widen, RLS REVOKEs, biometric SELECT lockdown, audit events, cost recompute, TOCTOU close — 15 findings)
- **Wedged infra (unchanged):** Supabase Branching `MIGRATIONS_FAILED` on the staging environment — pre-existing from 2026-05-11. Migrations apply cleanly to per-PR DBs and on the staging Postgres directly; only the Branching reconciliation is wedged. Handoff: `docs/handoffs/2026-05-23-safe-mode-embedding-and-branching-reconciliation.md`.

## What "self-trainer shipped" actually means

Plain English, for someone catching up cold:

- A practitioner is now also a **Self-client** — the same person plays two roles, one capturing on the trainer side, one being captured on the client side. Identity model is ADR-0020.
- Capture against the Self-client uses the same capture surface as any other client. New addition: at capture time, a **self-verification** check fires (does the face in the frame match the practitioner's enrolled embedding?) and stamps `exercises.self_verified=true` when it passes. The face embedding itself was already there from Safe Mode v2 — the new piece is using it as a verification discriminator.
- At publish time, if every exercise in the session is self-verified AND the session's client is the publishing user, **the publish is free** (zero credits debited, `credit_ledger` row written as `type='publish_free'` with `delta=0` for audit symmetry). Otherwise the existing duration-based pricing applies (1 or 2 credits). The Studio publish pill now shows the cost preview before the practitioner taps.
- Safe Mode in shared spaces (gyms, group sessions) is now **subscription-gated**, credit-denominated per ADR-0021 — 4 credits / month, paid out of the practitioner's existing credit balance. Capture entry checks the subscription state; absence routes to a paywall sheet. The portal has a `/subscribe` page for the same toggle.
- The Home screen has a new **My Workouts** scope (renamed from "Workouts" in foundation #487) with a real list body of self-captures and a FAB that mints a new self-session. Cold installs default to My Workouts (the Self-trainer journey is the lighter, lower-friction onboarding). Offline-first — cards render from local SQLite, sync refreshes in the background.
- The privacy policy and `PrivacyInfo.xcprivacy` were extended with the biometric-data section (foundation #492). ZA-lawyer red-pen is still pending — bracketed `[lawyer-review:]` placeholders remain in the copy and are tracked in `docs/BACKLOG.md`.
- An in-app intro banner (#501) surfaces on the first launch after a user is migrated to the self-trainer model, with grandfathered-user copy for existing accounts.

## The completion wave's six PRs

In staging-merge order. The first three landed in the prior session (after the foundation wave but before this checkpoint's handoff). The last three landed in this session.

### PR [#501](https://github.com/carlheinmostert/TrainMe/pull/501) — in-app intro banner + grandfathered user copy
`feat(self-trainer): in-app intro banner + grandfathered user copy`. Merge SHA `a0e0ead`. A coral top-of-Home banner that fires once after the user's account migrates into the self-trainer model. Distinct copy for fresh installs vs grandfathered accounts (existing practitioners who had no Self-client until the wave). Dismissible; persists dismissal per device. Tracked in the backlog as `[carl-review:]` for voice-pass.

### PR [#502](https://github.com/carlheinmostert/TrainMe/pull/502) — Public profile consent UI + lazy backfill + Self-client creation
`feat(self-trainer): Public profile consent UI + lazy backfill + Self-client creation`. Merge SHA `e2a7c05`. Three concerns:
1. Consent UI on Account / Profile surfaces the public-profile flag (whether the practitioner appears in the directory at all). POPIA-conscious copy.
2. Lazy backfill — when a practitioner whose account predates the self-trainer schema first touches a surface that needs a Self-client (capture FAB, publish), the row is created on-demand with sane defaults rather than via a one-shot migration.
3. Self-client creation flow itself — the row is inserted into `clients` with `user_id = auth.uid()`, `name` defaulted from the practitioner's profile, all consent keys at their conservative defaults until the user opts in.

### PR [#504](https://github.com/carlheinmostert/TrainMe/pull/504) — Safe Mode subscription gate + paywall sheet + portal subscribe page
`feat(safe-mode): subscription gate + paywall sheet + portal subscribe page`. Merge SHA `d5cf6d6`. Mobile capture entry checks `practice_safe_mode_subscription` (or the live-query equivalent) before allowing a capture inside an enforcing premises. Missing or lapsed subscription routes to a coral paywall sheet that explains the 4-credits/month price and offers a one-tap subscribe action. The portal carries the parallel `/subscribe` page so practice owners can manage the toggle on a real screen. Credit-denominated per ADR-0021 — no Apple IAP path opens; subscription is paid from the same credit balance the practitioner already buys via PayFast.

### PR [#503](https://github.com/carlheinmostert/TrainMe/pull/503) — capture-time self-verification + exercises.self_verified stamping
`feat(self-trainer): capture-time self-verification + exercises.self_verified stamping`. Merge SHA `f921717`. The ConversionService now invokes the face-embedding service against the captured frame, compares against the practitioner's enrolled embedding, and stamps `exercises.self_verified=true` on the row when the cosine similarity exceeds the threshold. Below threshold: row inserts with `self_verified=false` (no rejection — the capture is kept, just flagged unverified). The boolean column was added in the foundation schema PR #486; #503 wires the compute path. R-10 N/A (capture is mobile-only). Took the longest CI cycle of the wave (~7 min Flutter analyze+test + 12 min iOS build).

### PR [#507](https://github.com/carlheinmostert/TrainMe/pull/507) — publish cost preview + consume_credit conditional free path
`feat(self-trainer): publish cost preview + consume_credit conditional free path`. Merge SHA `4c7c9c6`. Adds the `preview_publish_cost(p_session_id uuid) RETURNS integer` SECURITY DEFINER RPC and extends `consume_credit` with the same conditional. Server-side rule: if the session's client is the publishing user AND every `exercises.self_verified` is true → cost 0 → write a `credit_ledger` audit row with `type='publish_free'` and `delta=0`, skip the balance check + debit, still insert the `plan_artifacts` row. Otherwise existing duration-based 1-or-2-credit path. The `IF p_credits IS NULL OR p_credits <= 0 RAISE` gate had to be relaxed because the server now computes the true cost; the function defends against a mismatch between the caller's `p_credits` and the server-computed value. Studio workflow pill renders `Publish · Free` / `Publish · 1 credit` / `Publish · 2 credits` from a preview call when the user enters the Publish step and refreshes after any add/delete. **Sensitive zone** — `consume_credit` is a load-bearing client RPC; the agent fetched the live signature via `pg_get_functiondef` before writing the migration to honour `feedback_schema_migration_column_preservation`. All existing branches preserved (prepaid-unlock fast path, SEC-2 consent backstop, insufficient-credits early return, normal debit, three jsonb return shapes).

### PR [#508](https://github.com/carlheinmostert/TrainMe/pull/508) — My Workouts body + FAB + self-capture cards + tap routing
`feat(self-trainer): My Workouts body + FAB + self-capture cards + tap routing`. Merge SHA `f47d7f7`. The wave-closing integration PR. Replaced `WorkoutsComingSoonView` (deleted) with `MyWorkoutsScreen` — an offline-first body widget that reads the cached Self-client, filters local sessions by `client_id == self.id`, and renders a reverse-chronological list of `SelfCaptureCard`s. Hero glyph via the canonical `resolveExerciseHero` per `feedback_hero_resolver_single_source` (no inline crop math). Tap → Studio mode (Self-client = practitioner = editor). FAB now mints a new local Session bound to the Self-client and navigates to SessionShellScreen with Camera as the default mode, gated by `client.consent.safeModeFaceRecognition`; missing consent routes to the inline consent sheet. SQLite v47 → v48 to add `cached_clients.user_id`. A targeted migration extends `list_practice_clients` + `get_client_by_id` to surface `user_id` — the cleaner alternative to stashing the Self-client id in SharedPreferences. Inbound-from-practitioner path (cards that aren't self-captures) was deferred — the empty state surfaces a muted "Got a link from your practitioner?" line as plain text without an `onTap`, since `plan_invitations` doesn't exist yet and shared-plan ingest is a future wave. 82/82 Flutter tests passing locally; `dart analyze` clean.

## Sub-agent orchestration this session

Three sub-agents spawned in series (each blocked on the prior PR's merge to avoid the file-overlap-sequential-merge trap), all auto-merged on green:

- PR #503 finished the in-flight verification capture work from the prior session — already had its own watcher; my background poller picked up the MERGED state and confirmed `f921717`.
- PR #507 spawned with the publish-cost-preview brief. The agent opened PR #507 (+738 -1), all checks went green, but the agent's own watcher only printed status without merging — I merged via `gh pr merge 507 --squash`.
- PR #508 spawned with the my-workouts-body brief. The agent opened PR #508 (+992 -349). Carl merged it himself the instant CI went green, racing my poller by seconds — confirmed by the agent's report.

Three brief corrections were applied to PR #508's spawn (each verified against the live staging DB via `pg_get_functiondef` + information_schema):
1. The brief referenced a `create_session` RPC that doesn't exist; session creation is local-SQLite-first, server-side only at publish.
2. The brief referenced a `clients.face_embedding_consented_at` column that doesn't exist; face-rec consent is a jsonb key `clients.video_consent['safe_mode_face_recognition']`.
3. The brief referenced a `plan_invitations` table for the inbound-from-practitioner path; that table doesn't exist and the path is deferred.

The agent solved the Self-client identification problem more cleanly than the brief suggested — instead of caching the Self-client id locally, it extended `list_practice_clients` to return `clients.user_id` so every surface uses the same lookup.

## Code review + hotfix wave

Carl asked for a full code review of the twelve wave PRs after they landed. Five specialist reviewers ran in parallel against staging tip `f47d7f7`:

1. **Schema + RPC + RLS + audit integrity** (security-engineer) — covered #486, #493, #494, #503's write path, #507, #508's RPC extensions.
2. **Mobile Flutter self-trainer flow** (code-reviewer) — covered #487, #501, #502, #503, #508.
3. **Billing + credits + subscription** (security-engineer) — covered #504, #507.
4. **Privacy + POPIA + consent surface** (code-reviewer) — covered #492, #501, #502.
5. **Native iOS face-embedding integration** (code-reviewer) — covered #494.

### Findings shape

- **10 Critical** (block QA or block promotion to main).
- **17 Medium** (foundational drift, missing audit, fragile invariants).
- **14 Low / informational**.
- Two findings (`credit_ledger.type` CHECK constraint missing `'publish_free'`, and the privacy-policy/ASC-checklist region drift) were surfaced by two independent reviewers — high signal.

### The single highest-impact finding

**`credit_ledger_type_check` constraint rejected `'publish_free'` at runtime — every self-trainer free publish would have hard-failed with SQLSTATE 23514.** The PR #507 migration's own header comment asserted "no CHECK constraint exists" — which was wrong. Both schema and billing reviewers reproduced it via live SQL. Empirical confirmation: zero `publish_free` rows in `credit_ledger` despite PR #507 being merged hours earlier. The self-trainer free-publish path had never successfully run end-to-end on staging.

### Hotfix wave PRs

In landing order:

| PR / Commit | Layer | Findings closed | Merge SHA |
|---|---|---|---|
| Hotfix C (direct to main) | docs main-side | 4 (BACKLOG enum, ASC region pin, R5-M5 + R3-M3 BACKLOG entries) | [`34cfcbc`](https://github.com/carlheinmostert/TrainMe/commit/34cfcbc) |
| [#509](https://github.com/carlheinmostert/TrainMe/pull/509) Hotfix A | DB | 15 (CA-1 CHECK widen, CA-4 column REVOKEs, CA-5 biometric SELECT lockdown, CB-6 PUBLIC REVOKE, CB-7 server-side cost recompute, CB-9 audit events, R1-M1 TOCTOU, R1-M3 prepaid p_credits, R1-M4 plan_artifacts metadata whitelist, R3-M1 owner-only, R3-M5 anon tighten, R4-M1 analytics default, R3-L1 refund_credit publish_free, R3-L2 prepaid comment, R4-L2 server-stamp consented_at) | `018b4d3` |
| [#510](https://github.com/carlheinmostert/TrainMe/pull/510) Hotfix D | docs staging-side | 5 (CB-8 portal region pin, M-7 selfie retention clarification, M-9 expiry honesty, R4-L1 POPIA s.71 marker, R5-M6 on-device embedding clarification) | `c7a94ee` |
| [#511](https://github.com/carlheinmostert/TrainMe/pull/511) Hotfix B | mobile + iOS | 17 (CA-2 banner placeholder strip, CA-3 face cache invalidation wiring, R2-M1 FAB practice resolution, R2-M2 bootstrap+FAB race, R2-M3 23505 retry, R2-M4 getMySelfFaceEmbedding tri-state, R2-M5 MyWorkouts ConversionService subscription, R4-M3 lazy backfill reminder, R5-M1 computeForImage dimension assert, R5-M2 verify-path shrink, R5-M3 raise min crop to 64px, R5-M4 threshold constant, R2-L2 unit test, R2-L3 FAB double-tap, R5-L1 unpackFloats precondition, R5-L2 vDSP_dotpr in verify, R5-L3 Dart dim-mismatch test) | `50ff86f` |

41 findings closed across 4 PRs in the same UTC day as the wave landed.

### Why the docs split into two PRs

The original Hotfix C brief said "single commit direct to main" — but five of the targeted findings live in files that only exist on staging (the portal `privacy/page.tsx` extensions from PR #492, the `SafeModeSubscribeForm.tsx` from PR #504, and the new biometric row in `app-store-connect-privacy.md`). The Hotfix C agent correctly identified the impedance mismatch and split the work: the main-side edits landed at `34cfcbc`, and I (the parent session) authored the staging-side edits as a separate PR #510 after the agent's brief blocked the staging push. Lesson noted for future docs hotfixes against a not-yet-promoted wave.

## Gotchas surfaced today

Three patterns that hit hard enough to be worth memorialising:

1. **Sub-agent watchers print, they don't merge.** The agent for PR #507 left a polling process behind that waited for all CI checks to complete and then printed the status array — but didn't run `gh pr merge`. The parent session has to either spawn its own merge-on-green poller or merge manually. Cost: PR #507 sat green-and-mergeable for several minutes before I caught it.
2. **`gh pr merge` reports success on stale state.** If you race a human merge (Carl merged #508 himself the moment CI went green; my `gh pr merge` fired seconds later), the CLI returns exit code 0 with no indication that the PR was already merged. The agent's report flagged it correctly because it verified `mergeCommit.oid` non-null afterward.
3. **Sub-agent briefs go stale against the live DB.** Briefs are written days or weeks before they spawn. By the time PR #09's brief fired, three of its referenced entities (`create_session` RPC, `face_embedding_consented_at` column, `plan_invitations` table) had either never existed or evolved. The pre-flight verification step (`information_schema.tables`, `pg_proc`, `pg_get_functiondef`) caught all three before the agent wasted cycles. Always pre-flight against the live DB before spawning, not just the brief's spec.

The handoff document this session inherited also flagged two from the prior session that stayed relevant:

4. **Branch sub-agent PRs from `origin/staging`, not `origin/main`,** when target is staging. The prior session's PR #02 agent followed its brief literally and branched from main, producing a 64-commit-conflict mess; PR #01's agent independently caught it and rebased. The `homefit-agent-brief` skill needs to bake this in.
5. **File-overlap-sequential-merge.** When two PRs touch the same Dart file (especially `home_screen.dart` or `api_client.dart`), whichever lands second WILL conflict — even when the changes are purely additive. Either serialise the spawning or budget a rebase round-trip on the second one. Today: PR #503 and #507 both touched `api_client.dart`; PR #507 and #508 both touched `home_screen.dart`. Strict serialisation avoided rebases.

## Memory entries to capture

After Carl reviews, candidates for `homefit-add-memory`:

- **`feedback_sub_agent_watcher_prints_only.md`** — Sub-agent watchers exit when CI completes but do not auto-merge. Parent session must spawn its own merge-on-green poller or merge manually. Don't trust the sub-agent's "watcher running" report as a merge guarantee.
- **`gotcha_gh_pr_merge_silent_success.md`** — `gh pr merge` returns 0 against an already-merged PR (e.g. when racing a human merge). Always verify `gh pr view N --json state,mergeCommit --jq '{state, sha: .mergeCommit.oid}'` returns `state=MERGED` AND non-null sha before declaring merged.
- **`feedback_pre_flight_brief_against_live_db.md`** — Sub-agent briefs go stale fast. Before spawning, verify every brief-referenced entity (RPC, table, column) against the live staging DB via `information_schema` / `pg_proc` / `pg_get_functiondef`. Pass corrections inline in the spawn prompt. Three stale references caught on PR #09's brief today (no `create_session` RPC, no `face_embedding_consented_at` column, no `plan_invitations` table).
- **`feedback_branch_sub_agent_from_staging.md`** — When the target merge is `staging`, the brief must instruct branching from `origin/staging`, not `origin/main`. The default `homefit-agent-brief` skill should encode this. Prior session lost ~20 min to a PR #02 agent that followed its brief literally and produced a 64-commit conflict.
- **`gotcha_file_overlap_sequential_merge.md`** — When multiple PRs touch the same Dart file (especially `home_screen.dart`, `api_client.dart`, `studio_mode_screen.dart`), serialise the spawning. Pure-additive overlaps still conflict at merge time. Budget a rebase round-trip on the second one or stage strictly.

## Open follow-ups

- **Wave-close device install** when Carl says go. Test script bundle: `docs/test-scripts/2026-05-25-publish-cost-preview.md` + `docs/test-scripts/2026-05-25-my-workouts-body.md` + the prior tests from #501, #502, #503, #504. Carl said "I'll test right at the end" — that signal is now live.
- **Lawyer red-pen** of the privacy section landed by foundation #492. Bracketed `[lawyer-review:]` placeholders are tracked in `docs/BACKLOG.md` under "ZA lawyer review — self-trainer wave POPIA copy". A grep command in the backlog verifies the sweep is clean later.
- **Voice-pass** of `[carl-review:]` placeholders across PRs #492, #501, #502. Backlog tracked.
- **Staging → main promotion** when Carl says ready. Twelve PRs to ship to prod; the `homefit-promote-staging-to-main` skill drafts the release PR + generates notes from titles. Notably this is the first promotion since the AM Safe Mode v2 polish wave landed; both sets ride the same train.
- **Supabase Branching reconciliation** still wedged — pre-existing, not introduced by this wave. Handoff at `docs/handoffs/2026-05-23-safe-mode-embedding-and-branching-reconciliation.md` remains the resume point.
- **Inbound-from-practitioner card path** on My Workouts (`plan_invitations` table + ingestion flow). Future wave; tracked as the design-doc CLIENT_WORKOUTS_AND_CLASSES § 1b.

## Blocked on Carl

Unchanged from prior checkpoints:

- Hostinger 301 redirects (`homefit.studio/privacy|terms` → `manage.homefit.studio/...`).
- `support@homefit.studio` mailbox setup.
- ZA lawyer red-pen of privacy + TOS scaffold (now with the biometric-data section to review).
- PayFast production merchant account.
- Apple Developer Program activation (separate timeline; first TestFlight upload of this stack will need it active).

## Fresh-session handoff

For the next session that loads cold and needs to pick up:

- **Read this checkpoint first**, then skim [`docs/CHECKPOINT_2026-05-25-self-trainer-foundation.md`](./CHECKPOINT_2026-05-25-self-trainer-foundation.md) for the foundation half + [`docs/CHECKPOINT_2026-05-25.md`](./CHECKPOINT_2026-05-25.md) for the same-day Safe Mode v2 polish wave that rode beneath this one.
- **Authoritative design + decision log:** [`docs/SELF_TRAINER_WAVE.md`](./SELF_TRAINER_WAVE.md) + the three ADRs at [`docs/adr/0020-self-trainer-as-practitioner-with-self-as-client.md`](./adr/0020-self-trainer-as-practitioner-with-self-as-client.md), [`docs/adr/0021-safe-mode-subscription-credit-denominated.md`](./adr/0021-safe-mode-subscription-credit-denominated.md), [`docs/adr/0022-plan-artifacts-abstraction-before-reel.md`](./adr/0022-plan-artifacts-abstraction-before-reel.md).
- **Glossary updates:** see `CONTEXT.md` for the eight new/amended terms (Self-trainer, Self-client, Self-verification, Self-reference selfie, My Workouts, Publish, Plan artifact, Safe Mode subscription).
- **Staging tip `50ff86f`, main tip `34cfcbc`** — main is docs-only ahead (Hotfix C). The 12 wave PRs + the 3 hotfix PRs (#509 DB, #510 docs staging, #511 mobile + iOS) are staging-only pending promotion.
- **iPhone CHM** has none of this. Next install lands the full wave + hotfix wave + the prior AM Safe Mode v2 polish + whatever else lands between checkpoint time and install time.
- **All 41 code-review findings closed** in the same UTC day as the wave landed. Critical bypass paths (RLS, biometric SELECT, CHECK constraint) sealed; consent-state caches wired; on-device biometric clarifications in policy + ASC checklist; portal expiry-honesty fixes shipped. ZA lawyer + Carl voice-pass placeholders ([lawyer-review:] × 4, [carl-review:] × 15) are now enumerated in `docs/BACKLOG.md` under "Self-trainer wave — lawyer + voice red-pen pending merge to main" — grep should return zero before staging→main promotion.
