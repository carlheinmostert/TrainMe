# Checkpoint — 2026-05-26 — Artifact-system Waves 4 + 5 autonomous run

**Autonomous overnight run that landed the final two waves of the artifact-system rollout, plus a same-night code-review-driven follow-up PR.** Wave 4 (brand-skin subscription — credit-denominated 4 cr/month with 30-day free trial + 7-day lapse grace, re-paints handout chrome via a `.skin-active` CSS toggle that never touches the seal tokens) and Wave 5 (share sheet + managed email — `clients.email` with ADR-0024 verified-claim supersession, Resend-backed Edge function, two-path Flutter share sheet) merged sequentially to staging. After both landed, a `superpowers:code-reviewer` agent audited the combined diff and surfaced one sev1 (subscription debit RPCs were member-callable, not owner-only — applied the paired fix to Safe Mode too) plus several sev2s; a single follow-up PR closed all the reasonable findings. Two sub-agents died with truncated final messages mid-run; both were salvaged by the parent session per `feedback_dead_agent_salvage.md` — the pattern is now a recurring shape worth noticing.

## Table of Contents

- [Status at session end](#status-at-session-end)
- [The night's three PRs in narrative](#the-nights-three-prs-in-narrative)
- [The two dead-agent salvages](#the-two-dead-agent-salvages)
- [The code-review pass — what was kept vs triaged out](#the-code-review-pass--what-was-kept-vs-triaged-out)
- [Other parallel-session PRs that landed on staging today](#other-parallel-session-prs-that-landed-on-staging-today)
- [Outstanding Carl-side actions blocking E2E](#outstanding-carl-side-actions-blocking-e2e)
- [Lessons / gotchas](#lessons--gotchas)
- [Fresh-session handoff](#fresh-session-handoff)

## Status at session end

- **Staging tip:** `597a600` — PR #544 (artifact-system review-followups). The artifact-system stack on staging is now Waves 1+2+3+4+5+followups. Live on `staging.session.homefit.studio` + `staging.manage.homefit.studio`.
- **Main tip:** `c3c87a8` — docs-only (`docs(test-scripts): three-wave install — consolidated device-QA for staging 674e2ef`). All 5 artifact-system waves are staging-only pending Carl's next promotion window.
- **Carl's iPhone CHM:** untouched by tonight's run per `feedback_ask_before_mobile_deployment.md` — no `install-device.sh` / TestFlight upload happened. The iPhone is still on whatever was installed before the run.
- **Vercel deploys tonight:** 3 staging deploys for the artifact-system stack (one per PR), plus parallel-session deploys from the face-enrolment work below. Vercel spend NOT auto-checked per `feedback_vercel_spend_monitor.md`.
- **Blocked on Carl (unchanged from prior checkpoints):** Hostinger 301 redirects (`homefit.studio/privacy|terms`); `support@homefit.studio` mailbox; ZA lawyer red-pen of privacy/terms scaffold; PayFast production merchant account; Apple Developer Program activation.

## The night's three PRs in narrative

In merge order. All three landed on staging; all three are staging-only pending the next staging → main promotion.

### PR #539 — Wave 4 brand-skin subscription

`feat(artifact-system): Wave 4 — brand-skin subscription`. Squash-merged as `b543130`. Credit-denominated subscription that re-paints the chrome of every client-facing artifact (today: the workout handout at `/h/{planId}`) in the practitioner's brand identity. Locked numbers per ADR 0029: 4 credits/month, 30-day free trial on first subscription (debit starts day 31), 7-day grace window before chrome reverts, one skin per practice (multi-practice practitioners subscribe each independently). The homefit "powered by" seal at the footer stays coral regardless — that's the visual expression of the "monetize enhancement, not entry" decision.

**Schema:** new migration adding `credit_ledger.metadata jsonb` (scopes subscription state by practice for the practitioner-multi-practice case), widening `credit_ledger_type_check` with `brand_skin_month` + `brand_skin_month_trial`, a partial index on the two new types for the predicate hot path, and four new SECURITY DEFINER RPCs: `practice_has_active_brand_skin` (read predicate, anon-callable so the handout can render the skin without a logged-in viewer), `practice_brand_skin_state` (jsonb snapshot for the lapse banner copy), `start_brand_skin_trial` (one-time-per-practice), and `start_brand_skin_subscription` (atomic 4-credit debit with `FOR UPDATE` on practices). `get_plan_full` extended with a `brand_skin_active` boolean — every existing key preserved verbatim per `feedback_schema_migration_column_preservation.md`.

**Web-player:** `web-player/handout.css` declares `--brand-*` tokens at `:root` and a `body.handout-body.skin-active` block that re-points them to inline `--practice-brand-*` values set by JS. The seal triplet (`--seal-coral`, `--seal-coral-light`, `--seal-tint-border`) is **never** touched inside `.skin-active` — that's the architectural commitment locked at decision #23 of the design doc. `handout.js`'s new `applySkin()` derives light/dark/tint variations from the practice's hex `brand_color`, populates a brand lockup with the practice name + optional logo image.

**Portal:** new `/brand-skin` + `/brand-skin/subscribe` routes mirroring the Safe Mode subscribe UX exactly. State-aware CTA on the landing page (try trial / active / in-grace / lapsed branches), with a trial-then-paid fall-through on the subscribe form if the trial RPC returns `trial_already_used`. A `BrandSkinLapseBanner` mounts in `BrandHeader` on every authenticated page; surfaces only when the practice is in its 7-day grace window.

**Mobile:** `ApiClient.practiceHasActiveBrandSkin` + `getBrandSkinState` (read-only — Reader-App compliant, no subscribe path), plus a `BrandSkinLapseBanner` Flutter widget mounted in `studio_mode_screen.dart`. The mobile banner is informational only — no tap target, no CTA, no price string.

### PR #541 — Wave 5 share sheet + managed email

`feat(artifact-system): Wave 5 — share sheet + managed email`. Squash-merged as `93313c4` (after a same-PR test-assertion fix `971e72b`). Final wave of the artifact-system rollout. Three concerns:

1. **Schema for `clients.email` + ADR-0024 supersession.** New columns `clients.email` (practitioner-typed transient address) and `clients.email_verified_at` (NULL while typed sits there; stamped when a magic-link claim with a confirmed `auth.users.email` arrives). The Wave 2 `claim_plan` RPC is extended with the supersession branch + a `client.email.verified` audit row when it fires. A new `set_client_email` RPC validates email format, writes the typed value, and always clears `email_verified_at` (typed values are by definition unverified).

2. **`send-artifact-email` Edge function.** Deno runtime mirroring the existing `payfast-webhook` shape. JWT-authed; checks `client_id` membership against the caller's practices; refuses if `plan_id.client_id != client_id`. Calls Resend's HTTP API with a branded HTML template — the practice name + brand colour from `practices.public_profile` make the email match the brand-skin even before the brand-skin subscription exists. Calls `set_client_email` AFTER a successful Resend send so the typed value isn't lost on a Resend 500. Refuses to overwrite a verified `clients.email_verified_at`.

3. **Flutter share sheet + Studio wire-in.** New `ArtifactShareSheet` widget — modal bottom sheet with two CTAs: "Email this plan" (managed email, primary coral) and "Share link" (legacy OS share, secondary). Pre-fills the email field from the local SQLite cache. Falls through to the OS share directly when the session has no `client_id` (legacy / orphan rows). `studio_mode_screen.dart`'s `_shareFromToolbar` rewired to open the sheet.

The salvage on this PR also surfaced a test-version mismatch (the agent bumped `_dbVersion` 48 → 49 to land `cached_clients.email` + `cached_clients.email_verified_at` but didn't update two assertions in `idempotent_migration_test.dart`); CI caught it, the parent session pushed a one-line fix in the same PR.

### PR #544 — code-review follow-ups (sev1 + sev2)

`fix(artifact-system): code-review follow-ups (sev1 + sev2)`. Squash-merged as `597a600`. After Wave 5 merged, the `superpowers:code-reviewer` agent ran against the combined Wave 4 + Wave 5 diff and returned a triaged findings list. This PR closed the actionable ones:

1. **SEV1 — subscription debit RPCs were member-callable, not owner-only.** `start_brand_skin_trial`, `start_brand_skin_subscription`, AND the pre-existing `start_safe_mode_subscription` (same monetization-bypass class — flagged by the reviewer as a paired fix) all required only practice membership. The portal UI gated non-owners at the surface level, but the RPCs were bypassable by any practitioner-role member with a JWT — they could atomically drain 4 credits from any practice they belonged to with no consent. All three now require `role = 'owner'` and soft-fail with `{ok:false, reason:'owner_only'}` so the portal can render a friendly chip rather than show a bare 5xx. `start_safe_mode_trial` is intentionally NOT widened — it writes delta=0 (no credit movement). This is the single most important fix from the audit.

2. **SEV2 — `practice_brand_skin_state.next_renewal_at` returns NULL when inactive.** Was unconditionally returning `created_at + 30 days` even for 90-day-old fully-lapsed rows — a meaningless past date. Now NULL in the inactive branch.

3. **SEV2 — `send-artifact-email` strips upstream Resend error detail.** Resend's error body can contain rate-limit reasons, account state, and recipient-validation hints we don't want leaking through a Bearer-authed endpoint. Now logged server-side; response carries only `{ok:false, reason:'send_failed'}`.

4. **SEV2 — `applySkin` clears residue on the non-skin branch.** Under SW updates / hot reload during dev, the DOM gets reused but `applySkin`'s setters are additive. A new `clearSkin()` helper undoes the state the no-skin path leaves behind; idempotent + safe on first render.

5. **Doc comments.** `getBrandSkinState`'s silent-fallback contract is now documented as intentional for THIS surface (the Studio banner mounts everywhere — a network blip must not paint a wrong warning) and explicitly references `feedback_no_silent_fallbacks.md` so a future caller doesn't assume the same fallback semantics. CSS comment in `handout.css` corrected to `data-skin-practice` (matches the JS attribute name).

## The two dead-agent salvages

Both Wave 4 and Wave 5 sub-agents (each a `backend-architect` running in an isolated worktree) completed their runs with truncated final messages. The Wave 4 agent's summary ended at "Now wire the banner into BrandHeader:" — clearly mid-instruction. The Wave 5 agent's summary said "The output is empty (1 line). Test must be still building/running. Let me wait via the monitor." — clearly mid-monitoring. In both cases the harness sent a completion notification (status = completed) but the work was uncommitted and no PR had been opened. Per `feedback_dead_agent_salvage.md` the parent session verified the worktree state was intact + coherent, then either committed the agent's work as-is (Wave 5 — all eight deliverables present) or completed the missing pieces inline (Wave 4 — agent had landed the migration + handout CSS/JS + portal API client + the `BrandSkinLapseBanner` component, but had NOT mounted the banner in BrandHeader's JSX, authored the `/brand-skin` routes, added the mobile `ApiClient` methods, or built the Flutter Studio banner; parent session authored those four missing pieces against the agent's existing pattern).

This is the **second time in three days** that a `backend-architect` sub-agent has died with a truncated final message but intact worktree work. Pattern is now reliable enough to flag — the salvage workflow worked both times. Memory entry `feedback_dead_agent_salvage.md` is current; no update needed beyond the count-incrementing.

## The code-review pass — what was kept vs triaged out

The reviewer returned **1 sev1 + 9 sev2 + 6 nits**. Triage decisions per Carl's "all reasonably identified" guidance:

**Implemented (all 5 in PR #544 above):**
- sev1 #1 — owner-only RPC gates (covered above)
- sev2 #2 — Resend detail strip
- sev2 #8 — `applySkin` cleanup
- sev2 #9 — NULL `next_renewal_at` when inactive
- sev2 #10 + nit #11 — doc-only

**Skipped (with reason):**
- sev2 #3 — `_humanize` reason coverage in the share sheet: resolved transitively by #2 (server-side collapse to `send_failed`).
- sev2 #4 — partial-index planner check: observation only, no actionable fix without EXPLAIN access.
- sev2 #5 — materialized-view perf opt: follow-up wave.
- sev2 #6 — `email_stamped:false` surfacing: optional polish.
- sev2 #7 — "Top up at manage.homefit.studio" banner copy on the brand-skin lapse banner: Carl decision (Reader-App memory question), not code-side.
- nits #12–#16 — stylistic judgment calls.

## Other parallel-session PRs that landed on staging today

Tonight's autonomous run wasn't the only session shipping. Parallel face-enrolment + Safe Mode + home polish work also landed on staging during the run. Listed for completeness; none are mine:

| PR | SHA | Title |
| --- | --- | --- |
| #540 | `888db7d` | chore(home): polish active-pill padding + top-bar icon vertical alignment |
| #542 | `db71270` | fix(face-enrolment): restore on-screen pose debug HUD |
| #543 | `05bd52e` | fix(face-enrolment): decouple yaw/pitch tolerance budgets (M42) |
| #545 | `c347041` | fix(face-enrolment): flip ARKit yaw sign — left/right inverted (M42b) |

Wave 5 was rebased onto the parallel face-enrolment work (`8a4c735` M40 ARKit + `9815b70` safe-mode self-recognition fix) mid-flight — clean conflict-free rebase since face-enrolment iOS files don't overlap artifact-system scope.

## Outstanding Carl-side actions blocking E2E

The artifact-system stack is code-complete on staging but two Carl-side configuration steps are required before end-to-end testing can validate the new surfaces:

1. **Supabase Auth redirect allowlist** (Wave 2 dependency, still outstanding from this morning) — add 4 entries on both prod (`yrwcofhovrcydootivjx`) and staging (`vadjvkmldtoeyspyoqbx`) Supabase projects so the `/me` claim flow can deep-link. Runbook lives at `docs/handoffs/2026-05-26-wave2-auth-config-needed.md`. Wave 2 test items 1-3 work without it; items 4+ blocked until applied.

2. **Resend HTTP API key for `send-artifact-email`** (new Wave 5 dependency) — generate an HTTP API key from the Resend dashboard (the SMTP path used today is a different key). Then:
   ```
   supabase secrets set RESEND_API_KEY=re_xxx --project-ref vadjvkmldtoeyspyoqbx
   supabase functions deploy send-artifact-email --project-ref vadjvkmldtoeyspyoqbx
   ```
   Same for prod when promoting `staging → main`. Until both are done, the share sheet's email CTA returns 500 — the "Share link" path works unchanged.

3. **ADR 0028 wording amendment** (cosmetic, not blocking) — Wave 3's predicate uses `credits_charged > 0` to identify paid plans (more precise than "any artifact exists" which would lock self-trainer free plans + prepaid-unlock republishes). The ADR rationale stays correct but the predicate sentence needs a one-line clarification.

Once #1 + #2 are done, the suggested E2E walk is: capture/publish a plan → load `/h/{planId}` → verify the handout renders → claim from `/me?claim=<planId>` → verify supersession → subscribe to brand-skin via the portal → verify the lapse banner appears → managed-email share → verify Resend delivery. Then promote `staging → main` when satisfied; the release-train will tag `v2026-05-26.N` automatically.

## Lessons / gotchas

- **Salvage pattern is now a recurring shape.** Two more dead-agent-truncated-summary salvages today brings the running count to four since the memory was written. The signal is becoming reliable: when a sub-agent's completion notification arrives with a summary that ends mid-sentence ("Now wire X", "Let me wait via the monitor", etc.), expect the worktree to have intact but uncommitted work. The salvage workflow remains: verify the worktree state via `git status` + `git diff --stat` + `mcp__dart__analyze_files` (or equivalent), commit if complete or author the missing pieces inline, then PR + push.

- **CI-vs-author test-version drift.** The Wave 5 agent bumped `_dbVersion` 48 → 49 to land the new `cached_clients` columns but didn't update the two pinned assertions in `idempotent_migration_test.dart`. CI surfaced the failure cleanly; a same-PR follow-up commit fixed it. Worth checking that any wave touching `_dbVersion` also greps for hard-coded assertions on the version number.

- **Owner-only gating is a separate concern from membership gating, on the RPC side.** The portal UI gated non-owners at the surface level on both Safe Mode subscribe and brand-skin subscribe, but the RPCs were only checking membership. The reviewer caught it; the fix tightened all three subscription debit RPCs to `role = 'owner'`. Worth a future audit pass on every other practice-level write RPC — anything that mutates credit balance, billing, or owner-scoped state should be checking role, not just membership.

- **Disk pressure surfaced mid-run.** The macOS data volume hit 100% (118 MiB available on a 460 GiB drive) during the checkpoint write step. Cause: orphan `.claude/worktrees/agent-*` worktrees from this and prior runs — each carries a full Flutter build artifact tree at several hundred MB. Pruning the three worktrees from tonight's run freed ~1.1 GiB. Backlog item: more aggressive worktree cleanup or a periodic prune cron.

## Fresh-session handoff

**Read this checkpoint first.** Then in priority order:

- `docs/handoffs/2026-05-26-autonomous-execution-log.md` (on branch `feat/artifact-system-design`, NOT main) — full per-wave decision log including the salvage stories and the locked-numbers references for the brand-skin subscription.
- `docs/ARTIFACT_SYSTEM.md` (same design branch) — the design doc with the Visual surfaces table.
- `docs/adr/0029-brand-skin-subscription-monetize-enhancement-not-entry.md` + `docs/adr/0024-anonymous-link-survives-claim-is-opt-in.md` — the two ADRs the waves ride on.
- `docs/handoffs/2026-05-26-wave2-auth-config-needed.md` — the Supabase redirect allowlist runbook (still outstanding from Wave 2).
- `docs/test-scripts/2026-05-27-artifact-system-wave5.md` — the Wave 5 device-QA script for when the iPhone gets the next build.

Staging tip is `597a600` (review-followups). Main is unchanged from this morning's tip. Apply the two Carl-side configurations above, run the suggested E2E walk on staging, promote staging → main when satisfied. The release-train auto-tags.
