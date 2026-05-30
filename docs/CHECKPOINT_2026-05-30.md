# Checkpoint — 2026-05-30 — My Workouts empty-list true root cause + code-review-wave CI cleanup

An autonomous session (Carl away for a few hours, explicit "do this autonomously" mandate). The headline: yesterday's "My Workouts empty" bug was **not** the sync-timing race that PR #614 tried to fix — it was a **stale local-cache bug**. We root-caused it with hard cloud evidence, fixed it at the source (PR #615), shipped a paired printable-guide fix (#604), closed two already-resolved issues, filed two robustness follow-ups, and left one harder test PR (#582) still red with a precise diagnosis.

## Table of Contents

- [Status at session end](#status-at-session-end)
- [The My Workouts bug — true root cause](#the-my-workouts-bug--true-root-cause)
- [What shipped to staging](#what-shipped-to-staging)
- [Issues closed + follow-ups filed](#issues-closed--follow-ups-filed)
- [Still open / handed off](#still-open--handed-off)
- [Lessons](#lessons)
- [Fresh-session handoff](#fresh-session-handoff)

## Status at session end

- **Staging tip: `95356bb`** — two PRs merged this session on top of yesterday's `cf188b0`.
- **main:** untouched except this checkpoint (`f69a6c3` + docs). Carl's working tree is a detached HEAD he's curating — left alone all session; the checkpoint was committed via an ephemeral worktree.
- **Carl's iPhone:** still on `cf188b0` (yesterday's build). The My Workouts fix is on staging but **NOT yet installed** — it needs a new build, which waits for Carl's go-ahead (ask-before-deploy rule).
- **No staging → main promotion** this session.

## The My Workouts bug — true root cause

**Symptom:** fresh staging install, signed in correctly, **Clients tab populates but My Workouts is empty** — Carl has 5 self-captured workouts that never appear. PR #614 (yesterday, already on the device) did not fix it.

**Why #614 was the wrong fix:** #614 assumed the list was empty because My Workouts queried the local cache *before* the background sync filled it, and never re-queried. It added a "reload after sync" trigger. But the data was **already in the local database** — so re-querying changed nothing. The bug was never about *when* we read; it was about *what* was in the cache.

**The real cause (proven against the live staging database):**
- The cloud is pristine: exactly one "self" record ("Me"), correctly tagged with Carl's user id, not deleted; all 5 of his workouts correctly point at it.
- So the corruption is purely in the **local cache on his phone**, which has been carried forward across many app updates rather than reinstalled.
- The app finds "your own workouts" by looking up the local "Me" record by user id, then keeping only the workouts pointing at it. On Carl's long-lived install, that "Me" record was first cached **before** the app even had a column to store the user-id link (added in a later schema bump, with no backfill). The record got stranded with an empty user-id — so the lookup returned nothing, and My Workouts fell back to an empty list. (A delete-then-restore cycle could strand it the same way via a stale local "deleted" flag.) The Clients tab was unaffected because it lists clients a different way that ignores that link.

**The fix (PR #615):** make the local cache **self-heal**. On every cloud refresh we now repair those two cloud-authoritative fields (the user-id link + the live/deleted flag) even on records with unsynced local edits — without clobbering the user's pending edits. Plus a one-time schema repair (v51→v52) that clears the stale "deleted" flag immediately on first launch, so a device that's offline at launch still recovers without waiting for a sync. Backed by a new regression test suite that drives the real storage layer and reproduces both stale shapes (it fails without the fix, passes with it). The fix was independently adversarially reviewed (verdict: ship) before merge.

## What shipped to staging

| PR | What | Result |
| --- | --- | --- |
| [#615](https://github.com/carlheinmostert/TrainMe/pull/615) | My Workouts self-heal — repair stranded local "Me" record so workouts list populates | Merged `d199775` |
| [#604](https://github.com/carlheinmostert/TrainMe/pull/604) | Printable workout guide (#585) — stop hero images stretching horizontally in the PDF export | Merged `95356bb` |

#604's fix: the printable PDF export pre-bakes square hero images through the shared hero-resolver (the export tool ignores CSS cropping), and the blanket image-crop CSS rule was re-scoped back to video only — satisfying the repo's hero-resolver single-source guard.

## Issues closed + follow-ups filed

**Closed as already-resolved:**
- [#592](https://github.com/carlheinmostert/TrainMe/issues/592) — unsafe enum index decode → already fixed by the defensive-decoder PR (#572) that merged earlier.
- [#600](https://github.com/carlheinmostert/TrainMe/issues/600) — migration-monolith refactor → duplicate of [#575], consolidated there.

**Filed (robustness follow-ups from this investigation):**
- [#616](https://github.com/carlheinmostert/TrainMe/issues/616) — My Workouts should reload on app-resume and when its tab becomes visible, not only on an explicit token bump. Would have turned this hard empty into a self-correcting transient one.
- [#617](https://github.com/carlheinmostert/TrainMe/issues/617) — defence-in-depth: dedupe the "Me" record to the cloud id during cache refresh, plus a deterministic ordering guard on the self-record lookup (closes the one latent edge the adversarial review found — not reachable today, but worth removing).

## Still open / handed off

- **[#582](https://github.com/carlheinmostert/TrainMe/pull/582)** (widget smoke tests for #579) — **still red**, draft. The new smoke tests pump a real screen that reaches into platform channels + an uninitialised singleton the headless CI harness can't satisfy, so the test run times out at 10 minutes. An analyze-phase ambiguity was fixed along the way (it now gets *into* the test phase). Getting it green needs the platform channels properly mocked in the test (a real test-harness setup), and local verification is impossible on this Mac (the OpenCV native build breaks every local `flutter test`). Recommended next step is on the PR: mock the channels or reduce to non-widget unit tests against the storage layer directly. Left red rather than gutted.
- **My Workouts device confirmation** — the #615 fix is on staging only. Next build to Carl's phone should confirm My Workouts shows his 5 workouts. Note: because his existing install carries the stale cache, the v52 one-time repair is what fixes *his* device specifically (a clean reinstall would also work but wouldn't prove the migration path).

## Lessons

- **When a fix survives one round, stop coding and get runtime evidence.** #614 was a plausible-from-reading-the-code fix that was simply wrong about the failure mode. The decisive move was querying the live staging database to prove the cloud was perfect — which immediately reframed the bug from "sync timing" to "local cache corruption."
- **An update-install carries forward years of schema scars.** Bugs that only reproduce on a long-lived install (stale columns from pre-migration eras) won't show up on a clean reinstall or a fresh QA account. Self-healing hydration + one-time repair migrations are the durable answer, not "just reinstall."
- **Don't delete forensic evidence early.** Yesterday's device-DB dump was deleted at the start of today's session; the phone was then unreachable (with Carl), so the local cache couldn't be re-inspected. The cloud database happened to be enough to root-cause it, but the local dump would have been faster and confirmed the exact stale shape.

## Fresh-session handoff

**READ THIS FIRST.** Supersedes `docs/CHECKPOINT_2026-05-28.md`. Staging tip is `95356bb`. Carl's iPhone is still on `cf188b0` and needs a new build to pick up the My Workouts fix (#615) — **ask before installing**. The My Workouts empty-list bug is fixed at its true root cause (stale local "Me" record on long-lived installs; #614's reload-token theory was wrong). #604 also landed (printable-guide image distortion). Two issues closed (#592, #600), two follow-ups filed (#616 resume/tab reload, #617 dedupe + ordering). One PR still red and handed off: #582 (widget smoke tests — needs platform-channel mocking; local test env is broken by the OpenCV build). No staging → main promotion yet — a growing backlog is on staging awaiting the next promotion.
