# Sub-agent briefs — self-trainer wave held PRs

These are the briefs for PRs #3 – #11 of the self-trainer wave (per `docs/SELF_TRAINER_WAVE.md` § PR sequence). They are **held** because each touches a zone that requires Carl review before spawning per the standing safety rules:

- iOS native code (PR #3) — needs device testing per `gotcha_ios_debug_needs_debugger`
- POPIA-sensitive UX (PR #4) — needs legal-shape review
- Conversion pipeline (PR #5) — sensitive code zone per `feedback_sensitive_code_review_before_merge`
- Sensitive client RPCs (PRs #6, #7, #8) — billing, anon-callable, or core auth
- Body wiring dependent on the above (PRs #9, #10)
- Legal artifacts (PR #11)

PRs #1 and #2 were spawned autonomously per Carl's authorization on 2026-05-25 (see `docs/CHECKPOINT_2026-05-25-self-trainer-foundation.md`).

## How to spawn one

When Carl is ready to ship a held PR, he runs the `homefit-agent-brief` skill (or just pastes the brief contents into a new Agent call with `subagent_type: general-purpose` and `isolation: worktree`). Each brief is self-contained — repo-relative paths only, target branch named, R-10 parity flagged where applicable, RPC-only DB access enforced, test script expectation included.

## Brief inventory

| File | PR | Title | Branch | Depends on |
|---|---|---|---|---|
| `03-self-face-embedding.md` | #3 | iOS native MobileFaceNet embedding compute + RPC wire-up | `feat/self-face-embedding` | PR #1 (schema) |
| `04-self-trainer-consent.md` | #4 | Public profile consent UI + lazy backfill + Self-client creation | `feat/self-trainer-consent` | #1, #3 |
| `05-self-verification-capture.md` | #5 | Capture-time self-verification + exercises.self_verified stamping | `feat/self-verification-capture` | #1, #3 |
| `06-publish-cost-preview.md` | #6 | Publish flow cost preview + consume_credit conditional logic | `feat/publish-cost-preview` | #1, #5 |
| `07-plan-artifacts-write.md` | #7 | plan_artifacts write on publish + get_plan_full extension | `feat/plan-artifacts-write` | #1 |
| `08-safe-mode-subscription-gate.md` | #8 | Safe Mode subscription gate at capture entry + paywall sheet | `feat/safe-mode-subscription-gate` | #1 |
| `09-my-workouts-body.md` | #9 | My Workouts body + FAB wire-up + self-capture cards + tap routing | `feat/my-workouts-body` | #2, #4, #5, #6 |
| `10-self-trainer-migration-banner.md` | #10 | Migration in-app banner + grandfathered user copy | `feat/self-trainer-migration-banner` | #1 |
| `11-self-trainer-privacy-docs.md` | #11 | Privacy policy delta + PrivacyInfo.xcprivacy + ASC checklist | `feat/self-trainer-privacy-docs` | none (parallel) |

## Spawn order recommendation

When Carl returns, the natural order is:

1. Confirm PRs #1 + #2 merged cleanly (CI green, no surprises).
2. Spawn PR #3 (face embedding native) — unblocks several downstream.
3. Spawn PR #7 (plan_artifacts write) in parallel — independent of #3.
4. Spawn PR #11 (privacy docs) in parallel — independent.
5. After #3 merges: spawn PR #4 (consent UI) and PR #5 (verification capture) in parallel.
6. After #5 merges: spawn PR #6 (publish cost) and PR #8 (subscription gate) in parallel.
7. After #4, #5, #6 all merge: spawn PR #9 (My Workouts body) — final integration.
8. Spawn PR #10 (migration banner) anytime once #1 is on staging.
