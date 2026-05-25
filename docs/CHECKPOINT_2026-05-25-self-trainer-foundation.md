# Checkpoint — Self-trainer wave foundation (autonomous run, 2026-05-25)

## Table of Contents

- [What this is](#what-this-is)
- [What was shipped autonomously](#what-was-shipped-autonomously)
- [What's open](#whats-open)
- [What's queued (held briefs)](#whats-queued-held-briefs)
- [What was NOT done and why](#what-was-not-done-and-why)
- [Recommended next steps on return](#recommended-next-steps-on-return)
- [Decisions made autonomously](#decisions-made-autonomously)
- [Memory entries to consider](#memory-entries-to-consider)

---

## What this is

Carl left for a few hours after greenlighting autonomous execution of the self-trainer wave foundation. Three boundaries he set:
1. Approve docs yourself, move forward.
2. Make decisions autonomously.
3. He hoped to come back to a working system.

I pushed back on (3) — the full 14-decision wave (schema + IA + face embedding native + POPIA consent + Safe Mode subscription gate + publish path changes + plan_artifacts wiring + migration UX) is multi-day work and "a working system in a few hours" was a promise I couldn't honestly keep without lying. Instead, I committed to a safer subset:

- All docs landed direct to main (per `feedback_specs_direct_to_main`)
- 2 low-risk PRs spawned to sub-agents and left open for Carl review (NOT auto-merged)
- 9 held briefs ready for one-command spawn after Carl's per-PR approval
- This checkpoint describing what happened, what's queued, and what's blocked

This file is the resume point.

## What was shipped autonomously

Six things landed direct to main on 2026-05-25:

| File | Purpose |
|---|---|
| `CONTEXT.md` | Eight new/amended glossary entries from the grilling session (Self-trainer, Self-client, Self-verification, Self-reference selfie, My Workouts, Publish, Plan artifact, Safe Mode subscription); flagged doc-drift |
| `docs/SELF_TRAINER_WAVE.md` | Living design doc consolidating all 14 Q-blocks; schema deltas, IA changes, PR sequence, decision log |
| `docs/adr/0020-self-trainer-as-practitioner-with-self-as-client.md` | ADR: identity model |
| `docs/adr/0021-safe-mode-subscription-credit-denominated.md` | ADR: subscription billing model (NOT Apple IAP) |
| `docs/adr/0022-plan-artifacts-abstraction-before-reel.md` | ADR: plan_artifacts schema preparation |
| `docs/sub-agent-briefs/` | Nine self-contained briefs for the held PRs + README explaining when to spawn each |

Commit on main: `6180ea3` (from earlier tip `f91f802`).

## What's open

Two sub-agents spawned in parallel; results captured below.

### PR #1 — `feat/self-trainer-schema` → staging

**Status:** OPEN (draft), Supabase Preview CI **SUCCESS**, ready for review
**URL:** https://github.com/carlheinmostert/TrainMe/pull/486
**Migration filename:** `supabase/migrations/20260525074056_self_trainer_wave.sql`

**CI status:**
- Supabase Preview: ✅ SUCCESS (authoritative — migration applies cleanly to fresh per-PR DB with pgvector)
- Local Postgres 17 check: ❌ FAIL — `vector` extension stub missing from `.github/workflows/migration-check.yml` preamble (pgjwt is stubbed, vector isn't). Out of scope for this PR; flagged inline for a follow-up CI infra fix.
- All other checks: ✅ green

**Deviations from the spec the agent caught and corrected** (each documented in PR body + commit messages):
1. `credit_ledger.kind` doesn't exist — the column is named `type`. Index built on `(trainer_id, type, created_at DESC)`; `safe_mode_month` and `safe_mode_month_trial` are conventional values for that column.
2. `exercises.session_id` doesn't exist — the FK is `exercises.plan_id`. Backfill + RLS queries corrected.
3. `plans.last_published_at` doesn't exist — backfill uses `COALESCE(sent_at, created_at, now())` instead.
4. `plan_artifacts` RLS policy joins through `plans.practice_id` directly (mirroring the `plan_issuances` RLS pattern) rather than the spec's join through `clients`. Simpler, faster, same security shape.
5. `practitioners.face_embedding vector(192)` is intentionally distinct from the existing `clients.face_embedding bytea` on staging (the Safe Mode v2 enrolment column). Different table, different purpose, different format. Documented in the column comment.

**Branch rebased to staging** rather than main — the spec assumes staging-side resources (the `practitioners` table from the 2026-05-22 Safe Mode Transparency wave). PR is one commit ahead of staging.

**Decision needed from Carl:** quick eyeball of the migration + the 5 deviations, then merge into staging.

### PR #2 — `feat/my-workouts-ia` → staging

**Status:** OPEN, CI **GREEN**, but **CONFLICTING** with staging — needs rebase before merge
**URL:** https://github.com/carlheinmostert/TrainMe/pull/487
**Commit:** `e5877d4`
**Files touched:** `app/lib/widgets/home_scope_segmented.dart`, `app/lib/screens/home_screen.dart`

**CI status:**
- ✅ Flutter app (analyze + test) — clean dart_analyze on touched files
- ✅ Flutter build iOS (debug, no codesign)
- ✅ Web portal, Web player, Data access seams, Custom rules, Vercel Preview
- ⚪ Supabase Preview: CANCELLED (typical for non-migration PRs)
- All real gates green

**Two follow-up actions needed from Carl:**

1. **Merge-resolution.** The agent branched from `main` per the brief, but staging is ~64 commits ahead with overlapping touches on `home_scope_segmented.dart` (and a wider docs / web cascade). Agent attempted `git merge origin/staging` to resolve but produced ~15 cross-file conflicts well beyond this PR's scope — aborted cleanly. **You'll need to either rebase the branch onto staging and resolve, or merge-resolve at merge time.** This is my fault — I should have instructed both agents to branch from staging not main (PR #1's agent caught it independently and rebased; PR #2's agent followed the brief literally).

2. **Visual simulator verification incomplete.** Agent built + installed on iPhone 16e successfully, but couldn't sign in: `.env.test` is gitignored (per CLAUDE.md `AGENT_QA_AUTH.md`) so it doesn't exist in isolated agent worktrees. The four simulator scenarios (cold install → My Workouts default, FAB → SnackBar, Clients capsule switch, sign-in + relaunch persistence) were NOT visually verified. Static verification only — all four edits are confirmed present in source post-build, dart_analyze clean. **You'll want to either sign in on the simulator yourself + re-run the smoke list, or just merge with caution since the static verification is solid.**

**No code-level deviations.** All four spec changes landed as specified: chip rename, capsule order swap, first-launch default, stub New Session FAB with SnackBar.

---

### Wave-2 PRs (spawned 2026-05-25 PM after PR #486 merged to staging)

After PR #486 (schema) merged to staging at `1e81c4e`, three more sub-agents were spawned in parallel for independent briefs.

### PR #3 — `feat/self-face-embedding` → staging

**Status:** OPEN, most CI green, **one important deviation needs Carl's call**
**URL:** https://github.com/carlheinmostert/TrainMe/pull/494
**Files touched:** `app/ios/Runner/HomefitFaceEmbeddingChannel.swift` (new), `app/ios/Runner/AppDelegate.swift`, `app/ios/Runner.xcodeproj/project.pbxproj`, `app/lib/services/face_embedding_service.dart` (extended; already existed for Safe Mode v2 client enrolment), `app/lib/services/api_client.dart`, `supabase/migrations/20260525114912_register_self_face_rpc.sql` (new), `docs/test-scripts/2026-05-25-self-face-embedding.md` (new)

**CI status:**
- ✅ Flutter app (analyze + test)
- ✅ Web portal, Web player, Web-player drift guard, Custom rules, Data access seams, Branch naming
- ✅ Vercel previews (web-player + portal)
- ⏳ Flutter build iOS (debug, no codesign): queued (Mac runner slow). Local sim build PASSED in 1092s.
- ❌ Apply all migrations against Postgres 17: **pre-existing inherited from PR #486** — Postgres 17 container lacks pgvector extension. Supabase Preview (real env, authoritative) is the gating check.
- ⏳ Supabase Preview / Populate vault.secrets: cancel / pending

**Important deviation — needs your call:**
- **The bundled `MobileFaceNet.mlmodel` emits 512-d embeddings, not 192-d.** The agent's migration `ALTER`s `practitioners.face_embedding` from `vector(192)` → `vector(512)` to match. Safe right now — column is NULL on every row (PR #486 only just added it; nothing reads or writes it yet). But this is a spec change you should consciously bless before merge rather than rubber-stamping.

**Other (minor) deviations:**
- `face_embedding_service.dart` already existed for Safe Mode v2 client-enrolment; agent added the new `computeForImage` method onto the existing singleton instead of creating a conflicting file. Good call.
- Personal practice resolved as first-owned (with non-owner fallback) — ADR-0020 doesn't pin a column for this. Worth a quick eyeball.

**No blockers.** The Postgres-17 migration-check failure predates this PR.

### PR #7 — `feat/plan-artifacts-write` → staging

**Status:** OPEN, CI mostly green, column-preservation work rigorous
**URL:** https://github.com/carlheinmostert/TrainMe/pull/493
**Files touched:** new migration `supabase/migrations/20260525094931_plan_artifacts_on_publish.sql`, `web-player/api.js`, `web-player/sw.js` (cache name bump + dated entry per `feedback_always_bump_sw_on_player_change`), `app/lib/services/api_client.dart`, models touched, `app/assets/web-player/{api,app}.js` mirror synced via `cp` after the auto-backgrounded `dart run` sync, `docs/test-scripts/2026-05-25-plan-artifacts-write.md` (new)

**CI status:**
- ✅ Supabase Preview (the authoritative migration validator — runs against a real env that has pgvector)
- ✅ web-player-drift-guard, Branch naming, Custom rules, Data access seams (Python), Web player (node --check), Web portal build, Vercel previews, ios-impact labeller
- ⏳ Flutter app (analyze + test), web portal build (second run), vault.secrets populate
- ❌ Apply all migrations against Postgres 17: **pre-existing inherited from PR #486's `CREATE EXTENSION vector;` (line 52). Out of scope for this PR.** Same as PR #3.

**Column-preservation rigour** (this is the headline — `feedback_schema_migration_column_preservation` lives here):
- `consume_credit(uuid, uuid, integer)` — live signature fetched via `pg_get_functiondef` on staging. **Preserved all 5 input-validation branches, the prepaid-unlock fast path, the insufficient-credits early return, the normal debit path, and all 3 distinct jsonb return shapes.** Only addition: two upsert blocks (one per success branch) writing to `plan_artifacts`.
- `get_plan_full(uuid)` — live signature fetched the same way. **Preserved every key in plan jsonb (`to_jsonb(plan_row)` + `brand_color` + `public_logo_url` + `practice_name`) and every per-exercise key (`line_drawing_url`, `grayscale_url`, `original_url`, `grayscale_segmented_url`, `original_segmented_url`, `mask_url`, `sets`, `rest_seconds`, `thumbnail_url_*`, plus all `to_jsonb(e)` columns).** Preserved the `first_opened_at` UPDATE side-effect and the `vault.decrypted_secrets` lookup. Only addition: top-level `artifacts` key from a `jsonb_agg` subquery.

**No deviations** beyond a minor note: SW comment-trail entry added per the brief's hard rule even though the 2026-05-25 SW rewrite retires the manual-bump ritual (`__BUILD_SHA__` rewrite handles eviction). Defensive — fine.

**No blockers.**

### PR #11 — `feat/self-trainer-privacy-docs` → staging

**Status:** OPEN, CI green, **legal review required before merge**
**URL:** https://github.com/carlheinmostert/TrainMe/pull/492
**Files touched:** `web-portal/src/app/privacy/page.tsx` (+92 lines as 5(d) sub-section under "What information we collect"), `app/ios/Runner/PrivacyInfo.xcprivacy` (one `NSPrivacyCollectedDataType` entry added), `docs/app-store-connect-privacy.md` (line item added)

**CI status:** Early signals all green — web-player drift guard, Branch naming, Custom rules, Data access seams, Web player node check, web-portal Vercel preview. Web portal build + Flutter pending but local builds were green.

**Manifest enum chosen:** `NSPrivacyCollectedDataTypeSensitiveInfo`. Apple's manifest taxonomy has no dedicated biometric enum — Sensitive Info is the canonical bucket per Apple's "Describing data use in privacy manifests" docs which explicitly list biometric data under it. Rationale captured as an XML comment in `PrivacyInfo.xcprivacy` and in the rationale column of `docs/app-store-connect-privacy.md` row 9.

**No code-level deviations.** Three minor adds beyond strict brief: chosen-enum rationale comment for future agents, three "8 rows" → "9 rows" consistency updates in the ASC checklist, `[lawyer-review:]` prefix exactly as suggested for greppability.

**Action needed from Carl + ZA lawyer:** the three `[lawyer-review:]` bracketed placeholders in the new privacy section. PR body has an explicit "Legal review required before merge" callout.

---

## What's queued (held briefs)

Files under `docs/sub-agent-briefs/`. One per held PR. Each carries: target branch, target merge (staging), repo-relative paths, RPC-only DB access rule, R-10 parity flag, test script requirement.

| Brief | PR | Status |
|---|---|---|
| `03-self-face-embedding.md` | iOS native MobileFaceNet embedding + RPC wire-up | **SPAWNED → PR #494 OPEN** (see Wave-2 PRs above) |
| `04-self-trainer-consent.md` | Public profile consent UI + lazy backfill | Held — POPIA-sensitive copy needs review |
| `05-self-verification-capture.md` | Capture-time verification + self_verified stamping | Held — touches `conversion_service.dart` (sensitive zone) |
| `06-publish-cost-preview.md` | Publish cost preview + consume_credit conditional | Held — `consume_credit` is a sensitive client RPC |
| `07-plan-artifacts-write.md` | plan_artifacts row on publish + get_plan_full extension | **SPAWNED → PR #493 OPEN** (see Wave-2 PRs above) |
| `08-safe-mode-subscription-gate.md` | Subscription gate at capture entry + paywall sheet | Held — billing-sensitive |
| `09-my-workouts-body.md` | My Workouts body wiring + FAB behaviour + cards | Held — depends on #4 + #5 + #6 |
| `10-self-trainer-migration-banner.md` | Migration in-app banner | Held — copy needs Carl review |
| `11-self-trainer-privacy-docs.md` | Privacy policy delta + PrivacyInfo.xcprivacy update | **SPAWNED → PR #492 OPEN** (see Wave-2 PRs above) — ZA lawyer red-pen still required for merge |

Recommended spawn order is in `docs/sub-agent-briefs/README.md`.

## What was NOT done and why

In honesty rather than completion-theatre:

- **No mobile deployment to Carl's iPhone.** Standing rule `feedback_ask_before_mobile_deployment` says never deploy to your phone without explicit per-session permission. You didn't give it; I didn't take it.
- **No PRs auto-merged.** Both spawned PRs are left open. Even though you authorised auto-approval for docs, your `feedback_sensitive_code_review_before_merge` rule says certain zones need your eye. The Home rendering pipeline (PR #2 touches it) is one of those zones. PR #1 is a schema migration that lands on staging where Supabase Branching applies it — but you should also eyeball it.
- **No real Safe Mode subscription, no real face verification, no real My Workouts body.** These are PRs #3–#9; held for your review of each brief before spawning.
- **No privacy policy update committed.** PR #11 brief is staged but the actual policy text needs your lawyer review pass before it lands. Compliance work that I wouldn't trust myself to ship unsupervised.

## Recommended next steps on return

In order:

1. **Read this checkpoint** + skim `docs/SELF_TRAINER_WAVE.md`. ~10 min.
2. **Review PR #1 + PR #2.** Quick CI check + skim the diff for each. If both green, merge to staging.
3. **Open `docs/sub-agent-briefs/README.md`** — it has the spawn-order recommendation. Five briefs are independent (#3, #7, #11) and can be parallelised after #1 + #2 land. The others have dependencies.
4. **Spawn PR #3 (face embedding native)** — unblocks #4, #5, #6, #9. This is the longest-tail brief.
5. **For PR #4 (consent), PR #10 (banner), and PR #11 (privacy):** review the **copy** in each brief before spawning. Those are the legal- and tone-sensitive ones.

If you want me to spawn more briefs without further review, message me which numbers and I'll fire them. If you want me to walk through any brief in detail, message which one.

## Decisions made autonomously

In the spirit of "decisions yourself", here are the calls I made without checking back:

- **Used a detached worktree for direct-to-main commits** (the existing `agent-a4bcbbf34aef9fc10` worktree was already on main and locked; cleaner to make my own at `.claude/worktrees/docs-self-trainer`). Will be cleaned up before this session ends.
- **`vector(192)` dimension for face embedding** — assumed MobileFaceNet's standard 192-float output. If your existing Safe Mode v2 code uses a different dim, PR #1 migration may need an adjustment.
- **Index built on `credit_ledger.user_id`** in PR #1 brief — flagged that this column may not exist (the legacy column is `trainer_id`); instructed the agent to verify and adapt.
- **`safe_mode_month_trial` as the kind name** for the trial-initiation ledger row. Internal symbol; can change.
- **4-credit price + R100 / month** = locked from the Q7.4c grilling decision. Just confirming.
- **PRs target `staging`, not `main`** — per `feedback_branch_naming_discipline`.

## Memory entries to consider

If any of these settled patterns feels memory-worthy after you've reviewed, consider running `homefit-add-memory`:

- **Always grill before executing on a wave that touches identity + billing** — the 14-block walk surfaced two reframes (Apple IAP → credit-denominated; per-practice → personal-practice-only self-clients) that would have been hard regressions to unwind in code. The grilling caught both at the design layer.
- **Detached worktrees on main work fine for direct-to-main commits** when the agent-* worktree path is already locked — `git worktree add --detach .claude/worktrees/X origin/main` + commit + `git push origin HEAD:main` is clean.
- **Pushing back honestly on scope** ("I cannot promise a working system in a few hours") preserved trust + delivered a real foundation. Carl explicitly authorised aggressive scope; pulling back to a defensible subset was the right call.
- **Agent briefs targeting `staging` MUST instruct branching from staging, not main.** PR #1's agent independently caught this; PR #2's agent followed the brief literally and produced a conflicting branch. The `homefit-agent-brief` skill should explicitly cover the "branch from staging, target staging" pattern. PR #2 wasted ~20 min of merge-resolution surface that PR #1 didn't.
- **`.env.test` is gitignored and won't reach isolated agent worktrees.** Any brief asking an agent to do simulator visual smoke beyond "build + launch" must surface this — give the agent the credentials inline, or set expectations that smoke can be static-only. Today PR #2's agent did the right thing (reported the limitation, didn't fake the smoke).
