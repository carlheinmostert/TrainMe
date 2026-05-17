# Checkpoint — 2026-05-15 — Publish-flow refactor + storage policies recovery + 9 fix waves

**The day a small QA round turned into a full publish-flow refactor + an emergency Supabase storage policies recovery + 9 separate fixes for the recurring lobby bugs.** 20 PRs merged to staging. iPhone CHM ends the day on staging tip `6d3444b`. The recurring circuit-animation bug is now on attempt #10 (mockup-locked, pending Carl's variant pick) — but as a fundamentally new architecture (pure CSS pulse on N nested bounding boxes, no JS, no SVG, no observers).

## Table of Contents

- [Status at session end](#status-at-session-end)
- [The day's big decisions](#the-days-big-decisions)
- [Today's PR wave (20 PRs)](#todays-pr-wave-20-prs)
- [The publish-flow refactor (PR-A / PR-B / PR-C)](#the-publish-flow-refactor-pr-a--pr-b--pr-c)
- [The Supabase baseline-recovery story](#the-supabase-baseline-recovery-story)
- [The circuit animation saga — 9 attempts, attempt #10 ready](#the-circuit-animation-saga--9-attempts-attempt-10-ready)
- [QA state at session end](#qa-state-at-session-end)
- [Outstanding items for next session](#outstanding-items-for-next-session)
- [Memory rules added today](#memory-rules-added-today)
- [Fresh-session handoff guide](#fresh-session-handoff-guide)

## Status at session end

- **Staging tip:** `6d3444b` (Merge of PR #360 — circuit MutationObserver disconnect during paint).
- **iPhone CHM:** build SHA `6d3444b` installed via `./install-device.sh staging`, ENV=staging, bundle `studio.homefit.app.dev`.
- **Main tip:** moved several times for direct-to-main docs (publish-progress-sheet wireframe, publish-flow-refactor spec, three rounds of circuit-pulse mockups, this checkpoint).
- **Staging Supabase branch (`vadjvkmldtoeyspyoqbx`):** two new migrations auto-applied today via Supabase Branching:
  - `20260515135502_storage_bucket_policies_recovery.sql` (PR #354 — restored media + raw-archive RLS policies that the baseline migration silently dropped).
  - `20260515140953_baseline_recovery_phase2_auth_trigger.sql` (PR #355 — restored the `claim_pending_practice_memberships_trigger` on `auth.users`).
- **Vercel staging surfaces:** `staging.session.homefit.studio` and `staging.manage.homefit.studio` auto-deploy on every staging merge; both at parity with staging code.
- **Blocked on Carl (unchanged):** Hostinger 301 redirects · `support@homefit.studio` mailbox · ZA lawyer red-pen · PayFast production merchant.

## The day's big decisions

Three load-bearing product decisions ratified today, all now reflected in code on staging:

1. **B&W is the primary treatment.** Line drawing demoted to one option among several. New exercises capture with `preferred_treatment = grayscale` by default. The web player's lobby resolver flips legacy-NULL rows to B&W as the read-time fallback.

2. **Publish is atomic.** Every treatment file must land in the cloud or the whole publish fails. Credit refunds silently on any failure. No more "partial-success" toast. Replaced with a multi-phase progress bottom sheet that shows the practitioner exactly where the publish is.

3. **Consent decouples from upload.** Every treatment variant uploads on every publish regardless of consent. Consent stays as a pure player-side visibility gate (`get_plan_full` already returns NULL signed URLs for revoked treatments). Practitioners can toggle consent later without needing to re-publish — files are already in the cloud.

Plus a fourth load-bearing rule, captured as a memory entry:

4. **No exception-driven control flow.** Never "catch this exception and treat as success" — use idempotent APIs (e.g. `upsert: true`), state stamps, or SECURITY DEFINER RPCs instead. Flagged when an agent proposed catching `StorageException` 409 as success on raw-archive re-uploads.

## Today's PR wave (20 PRs)

In merge order:

| # | PR | Theme |
|---|---|---|
| 341 | Editor sheet LateInit fix | P0 regression from PR #340 |
| 342 | Circuit animation 7th attempt (eager + drop await) | Recurring bug — failed |
| 343 | Gear popover CSS override (1st attempt) | Failed in landscape |
| 344 | PDF aspect ratio 1st attempt (inner padding) | Was wrong-physics — failed |
| 345 | Publish toast diagnostic sheet | Worked — Show which files affordance added |
| 346 | **PR-A** — Decouple consent from upload | Worked |
| 347 | Studio card title spacing | Worked |
| 348 | **PR-B** — Default treatment swap line→B&W + soft fallback | Worked |
| 349 | **PR-C** — Atomic publish + progress sheet + workflow chip | UX validated end-to-end |
| 350 | PDF aspect ratio 2nd attempt (content-width match 688px) | Worked |
| 351 | Publish-sheet failures reactive wiring | Worked |
| 352 | Gear popover cascade fix (drop shared class + !important) | Worked |
| 353 | Circuit animation 8th attempt (measure rows + aspect-ratio) | Worked for static frame; introduced MO loop |
| 354 | **P0 — Storage bucket policies recovery** | Unblocked publish |
| 355 | Baseline recovery phase 2 — `auth.users` INSERT trigger | Companion to #354 |
| 356 | Silence consent preflight toast | Cosmetic |
| 357 | useRootNavigator on UploadDiagnosticSheet | Fixed modal stacking |
| 358 | Republish idempotency (`upsert: true` + photo stamps) | Worked |
| 359 | Lobby thumbnails legacy soft-fallback | Worked |
| 360 | Circuit animation 9th attempt (MO disconnect during paint) | Pending Carl device test |

## The publish-flow refactor (PR-A / PR-B / PR-C)

The refactor that landed today is captured in two browsable docs on `main`:

- **`docs/design/mockups/publish-flow-refactor.html`** — the spec doc Carl signed off on (B&W default + atomic publish + consent decouple).
- **`docs/design/mockups/publish-progress-sheet.html`** — the wireframe for the 4 sheet state variants (mid-publish, failure, success, dismissed-chip).

**PR-A (#346)** — consent decouple. `_uploadRawArchives` no longer skips uploads based on client consent. Three layers of skip-if-unchanged logic remain intact (fast-path metadata-only, `rawArchiveUploadedAt` per-exercise, storage-listing existence check) — they're orthogonal to consent.

**PR-B (#348)** — default treatment swap. Capture flow + editor + sticky defaults + web-player resolver all flip line → B&W. Soft-fallback rule: when the practitioner's preferred treatment lacks client consent (signed URL returns NULL), the player silently falls back to line drawing — distinct from the no-fallback principle which still covers genuine file-missing cases.

**PR-C (#349)** — atomic publish + progress sheet UX. Step 7.5 (raw-archive uploads) reordered to run BEFORE exercise upsert. Any failure throws `PublishFailedException` which unwinds the credit consume + media-bucket orphan cleanup. New `Stream<PublishProgress>` model + `PublishProgressSheet` widget + workflow-toolbar chip. Legacy "Some optional treatment files are still processing" toast retired entirely.

**PR #351** retrofit: the failure list now rides on the stream event (`p.failures`) rather than a captured prop, so the "Show which files →" tap-target renders correctly on first failure render.

**PR #358** retrofit: `upsert: true` on `uploadRawArchive` + stamp `rawArchiveUploadedAt` on successful photo uploads too, so the skip-if-unchanged fast-path now kicks in for photo plans on re-publish.

## The Supabase baseline-recovery story

When the CI/CD release-train cutover happened on 2026-05-11, the baseline migration `supabase/migrations/20260511065443_baseline.sql` was generated via `pg_dump --schema=public`. That tool **silently omits everything outside the public schema** — including:

- All `storage.objects` RLS policies (storage is a separate schema).
- All triggers on `auth.users` (auth is another separate schema).

Both surfaced today as P0 regressions:

- The media bucket lost public SELECT; the raw-archive bucket lost INSERT/UPDATE/DELETE policies. **Every publish failed with `42501 RLS violation`** on any Supabase Branching-cloned DB (which is every per-PR preview + the persistent staging branch). Fixed by PR #354 — new dated migration that re-applies the historic policies idempotently via DROP IF EXISTS + CREATE.

- The `claim_pending_practice_memberships_trigger` on `auth.users` was dropped. Invitees signing up via the by-email invite flow never had their pending memberships drained. Fixed by PR #355.

**The lesson:** `pg_dump --schema=public` is dangerous as a baseline snapshot when there are hand-applied artefacts in `storage.*` / `auth.*` / `vault.*`. Future baseline rotations should include a follow-up audit for non-public-schema DDL.

## The circuit animation saga — 9 attempts, attempt #10 ready

**The bug:** the coral animated tracer on the lobby's circuit doesn't show on iOS embedded preview. Recurring all year. Today made it through attempts 7, 8, 9 — and we finally figured out the pattern.

| Attempt | PR | Date | What was patched | Why it failed |
|---|---|---|---|---|
| 1-2 | #257/#258 | 2026-05-05 | DOM frame markup | Didn't address measurement timing |
| 3 | #259 | 2026-05-05 | Introduced SVG lanes + `renderCircuitLanesFor` | Introduced the single-measurement bug |
| 4 | #260 | 2026-05-05 | CSS animation → WAAPI | Fixed CSS var bug; underlying geometry still stale |
| 5 | #317 | 2026-05-13 | 1 rAF retry of `getTotalLength` | Retried wrong thing (animation, not measurement) |
| 6 | #322 | 2026-05-13 | 30-frame poll + CSS-vs-WAAPI hardening | Same — wrong layer |
| 7 | #337 | 2026-05-15 AM | await image load events | Lazy images don't fire load — hangs forever |
| 8 | #342 | 2026-05-15 AM | loading=lazy → eager + drop await + MutationObserver | Race window narrows but `frame.offsetHeight` still wrong |
| 9 | #353 | 2026-05-15 PM | Measure rows individually + aspect-ratio CSS | Introduced MutationObserver feedback loop — main thread pegged, page went black on circuit plans |
| 10 | #360 | 2026-05-15 PM | Disconnect MutationObserver during paint | Surgical fix to the #353 loop — pending device test |

**The pattern:** every attempt patched a layer of the existing complex implementation (SVG path geometry from runtime DOM measurement + WAAPI + retry loops + observers + font/image load awaits). The fault wasn't in any one layer — it was in the architecture's complexity. Each fix introduced new failure modes.

**The new strategy (mockup-locked, pending Carl's pick):** replace the SVG tracer entirely with **pure CSS keyframes on N nested bounding boxes**, where N = circuit cycles. A ×3 circuit shows 3 visible nested borders. The pulse animation moves across them. The rep count becomes visually literal.

Three mockup waves on `main`, increasingly refined:

- `docs/design/mockups/circuit-concentric-pulse.html` (4 variants — first cut)
- `docs/design/mockups/circuit-pulse-treatments.html` (8 variants — full design space)
- `docs/design/mockups/circuit-nested-boxes.html` (6 variants — current — N rounds = N boxes)

**Why this fundamentally avoids the prior 9 attempts' problems:**
- No JS — pure CSS keyframes
- No DOM mutation — MutationObservers can't trigger
- No measurement — `offsetHeight`, `getTotalLength`, retry loops all gone
- Animations run on compositor thread, not main thread → same code path in Safari and WKWebView
- The entire class of bugs literally cannot occur

**Next step:** Carl picks a variant from `circuit-nested-boxes.html`, then a 10th-attempt fix agent ships it.

## QA state at session end

Carl ran a re-QA round on the 9-PR wave after the second install (build `7f89ebf`). Results — see [docs/test-scripts/index.html](test-scripts/index.html) for individual test scripts:

**PASS (12 items):**
- Hero treatment principle holds across surfaces (items 1–5 from the 2026-05-14 QA list — re-confirmed)
- Editor sheet opens with content (PR #341 P0 unblock worked)
- Demo tab default + swipe works
- New exercise capture defaults to B&W
- Publish progress sheet renders with 5 phases
- Swipe-dismiss → coral chip in workflow toolbar
- Success → all rows green + 1s "All set" + auto-dismiss + share lights up
- Atomic publish failure UX (refund + retry button + halt)
- Partial-success toast retired
- B&W default on player + soft fallback to line + file-missing placeholder
- Studio card title spacing equalised
- Storage policies P0 fix landed — 1-photo plan publishes successfully

**FAIL or regressed today (8 items):**
- Circuit animation in embedded preview (attempts 7 + 8 both failed; #9 / #360 pending verification)
- PDF preview circuit grouping — same root as #1 (geometry); should resolve with #360
- Gear popover landscape (PR #343) — failed; #352 cascade fix shipped; pending verification
- PDF aspect ratio (PR #344 1st attempt) — was wrong physics; #350 real fix shipped; pending verification
- "Show which files →" tap-target — invisible (fixed by #351 reactive wiring); tappable (fixed by #357 useRootNavigator) — both shipped, pending verification
- Larger plan publish failure ("0 of 42 files") — root cause was storage policies (#354) + photo stamps (#358); pending verification
- Lobby preview going black on circuit plans — root cause was MutationObserver feedback loop in #353; fix is #360; pending verification
- Share button non-responsive — likely same root as the MO loop; should resolve with #360

**CANNOT TEST (5 items):**
- Items 3, 4: pull-refresh + rotate inside the lobby (blocked by item 1)
- Item 10: 8+ exercise multi-page PDF (blocked by publish failure)
- Item 13: progress bar didn't render with 0/6 progress (likely fine, but nothing to show with 0 progress)
- Item 21: legacy publish toast diagnostic (toast is gone; new equivalent is "Show which files →")

## Outstanding items for next session

**P0 — pending Carl device test of build `6d3444b`:**
- Item 1 (and items 2, 3, 4 indirectly): does the 9th-attempt circuit MutationObserver disconnect fix the animation + preview-going-black + share-button-non-responsive cluster?
- Item 7-8: does the gear popover cascade fix work in landscape?
- Item 9: does the PDF aspect ratio content-width fix render correctly on Mac?
- Item 5 (large plan preview): should work now that the MO loop is gone
- Republish a 6-photo plan: should now succeed via the `upsert: true` + stamps idempotency fix

**Pending Carl's design pick:**
- 10th-attempt circuit animation variant from `docs/design/mockups/circuit-nested-boxes.html`. Once Carl picks (probably variant 1 outward-ripple, 3 synchronous heartbeat, or 5 outer-only-minimal), spawn the fix agent.

**Polish / not urgent:**
- Duplicate "42" entry in `docs/test-scripts/index.html` — pre-existing from before today.
- Long-term: audit baseline.sql for any OTHER non-public-schema DDL that pg_dump silently dropped (extensions, vault secrets, grants on private buckets). Today's #354 + #355 covered storage + auth.users; vault and possibly others may need a phase 3.

## Memory rules added today

- **`feedback_no_exception_control_flow.md`** — Never "catch this exception and treat as success". Use idempotent APIs (`upsert: true`), state stamps, or SECURITY DEFINER RPCs instead. Flagged 2026-05-15 when an agent proposed catching 409 as success.

## Fresh-session handoff guide

For a fresh Claude session picking up this work:

1. **Read this checkpoint** — captures all the day's work end-to-end.
2. **Read `docs/design/mockups/publish-flow-refactor.html`** — the load-bearing spec for the 3-PR refactor.
3. **Read `docs/design/mockups/publish-progress-sheet.html`** — the publish UX wireframe.
4. **Read `docs/design/mockups/circuit-nested-boxes.html`** — the 6-variant 10th-attempt mockup (the one Carl needs to pick from).
5. **Read `CLAUDE.md`** — project rules.
6. **Read the latest memory files** under `~/.claude/projects/-Users-chm-dev-TrainMe/memory/MEMORY.md` — invariants Carl has set over time. Today's new addition: `feedback_no_exception_control_flow.md`.
7. **Carl's iPhone is on staging `6d3444b`** — open the `studio.homefit.app.dev` icon. Test scripts under `docs/test-scripts/` cover today's PRs.

**If Carl asks "did the 9th circuit attempt fix it":** point him at the new mockup at `circuit-nested-boxes.html` — the 9th attempt is a stopgap for the MutationObserver loop, but the 10th attempt is the real architectural fix.

**If Carl asks "why does the same circuit bug keep coming back":** point him at the "9 attempts" table in this checkpoint. The pattern is the diagnosis — every fix patched a layer of the same complex implementation. Attempt #10 replaces the architecture entirely (CSS-only nested-box pulse) so the entire class of bugs disappears.

**If Carl asks about publish failures:** the storage policies P0 was fixed by #354. The republish idempotency was fixed by #358. Both should hold. If a fresh publish failure surfaces, first thing to check: which file failed via the diagnostic sheet (`Show which files →` tap-through, now wired correctly via #351 + #357).

**Open question state when handing off:** Carl is mid-QA on build `6d3444b`. He's stepped away from the conversation flow to think about the 10th-attempt animation pick. Next agent should wait for him to (a) pick a variant from the nested-box mockup, OR (b) report device QA results from build `6d3444b`. Either path leads to spawning the 10th-attempt fix agent.
