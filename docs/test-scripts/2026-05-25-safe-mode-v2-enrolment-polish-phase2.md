# Safe Mode v2 — Enrolment polish Phase 2 device QA (2026-05-25)

**Branch:** PR #TBD targeting `feat/safe-mode-v2-enrolment-polish-phase1` (stacked on Phase 1 PR #491). When Phase 1 merges to staging, this PR rebases onto staging.
**Build:** installed via `homefit-ship-to-phone` after Phase 1 lands and Phase 2 rebases. SHA TBD.
**Bundle:** `studio.homefit.app.dev`.

Wave covers three concerns layered on top of Phase 1's mode scaffolding (PR #491):

- **Real-time pose-gated capture** — sweep no longer timer-driven. Vision streams the current face pose; the sweep only accepts a frame when its pose differs from every existing slot by >= 25 degrees Manhattan distance AND its quality score >= 60.
- **Per-embedding quality scoring** — composite 0..100 score per candidate (face confidence, sharpness, lighting, pose uniqueness, embedding norm). Rejected slots flash a rose-tinted reject toast with the raw score visible.
- **Manual avatar selection** — post-sweep grid of all captured slots; practitioner taps which becomes the avatar JPG (frontal-pick highlighted by default; tap any cell to override).

Five mockup design decisions signed off by Carl (see `docs/design/mockups/safe-mode-v2-enrolment-polish.html`):

1. 6 pose buckets (front, front-left, front-right, left, right, slight-up) — not 8.
2. Reject toast shows raw quality score ("Slot rejected — 42") not soft copy.
3. Pose labels word-form ("front-left", "slight-up") — not "front-left, 0° pitch".
4. Dashed face guide inside the ring (not Wave-D's solid breathing circle).
5. No "Start" button — sweep auto-begins when Vision sees a face.

What did NOT change: Phase 1 scaffolding (camera toggle, consent matrix, consent sheet restructure, avatarOnly simple-shot capture). Phase 1's test wave still covers items 1-5.

## Table of contents

- [Prerequisites](#prerequisites)
- [A. Sweep start — guidance ring + auto-begin](#a-sweep-start--guidance-ring--auto-begin)
- [B. Pose-gated capture mid-sweep](#b-pose-gated-capture-mid-sweep)
- [C. Quality scoring + reject feedback](#c-quality-scoring--reject-feedback)
- [D. Manual avatar selection grid](#d-manual-avatar-selection-grid)
- [E. Retake + Confirm flow](#e-retake--confirm-flow)

## Prerequisites

Phase 1 PR #491 merged + installed. You should be signed in to the staging "test" client (`9453d8ed-…`) with both face-rec consent AND avatar consent ON (so the editor opens in `full` mode and exercises the post-sweep grid).

## A. Sweep start — guidance ring + auto-begin

- [ ] 1. Tap the avatar circle on the test client. Editor opens. Viewfinder shows the dashed coral face guide inside a 6-segment ring (all segments dim). No "Start" button visible — sweep is gated only on Vision seeing a face.
- [ ] 2. Look at the camera. Within ~1s of Vision seeing your face, the slot counter changes from "0 of 6 captured." to "1 of 6 captured." and one segment lights coral. No tap required.
- [ ] 3. Hint text reads "Look at the camera to begin." until first slot, then becomes directional ("Turn slightly to your right.").

## B. Pose-gated capture mid-sweep

- [ ] 4. Hold your head perfectly still after the first slot. Sweep should NOT accept any new slots — pose distance to existing slot is 0. Slot counter stays at 1.
- [ ] 5. Turn your head slowly to the left. As soon as your pose differs from the existing slot by ~25 degrees, a new slot accepts (counter advances, second segment lights).
- [ ] 6. Continue covering each bucket. Hint text directs you to the nearest missing bucket each time (e.g. after capturing left, hint says "Turn slightly to your right.").
- [ ] 7. Cover all 6 buckets. Sweep auto-completes (transitions to grid view in section D).

## C. Quality scoring + reject feedback

- [ ] 8. Move into a poorly lit area (e.g. under a desk lamp casting heavy shadow). Slot quality scores should visibly drop. The per-slot badge near the slot counter shows the live score; coral for >= 80, amber for 60-79.
- [ ] 9. In dim conditions where the composite score drops below 60, the reject toast appears at the bottom: rose-tinted pill with text like "Slot rejected — quality too low · 42." Raw number visible (per Carl's mockup signoff). Toast auto-dismisses after a few seconds.
- [ ] 10. Move back into good light. Sweep resumes accepting slots normally.
- [ ] 11. If you complete the sweep with average quality < 70, a yellow advisory appears: "Quality is low — try better lighting or get closer." Otherwise no advisory.

## D. Manual avatar selection grid

- [ ] 12. Sweep completes (or you tap Done). Post-sweep grid appears: 3x2 layout of captured face crops. Each cell shows: face crop, quality score badge, pose label in word-form ("front-left", "slight-up").
- [ ] 13. Mini quality histogram appears at the top of the grid — 6 bars colour-coded per score band (coral >= 80, amber 60-79, grey < 60).
- [ ] 14. The frontal-pick cell has a coral border by default (the auto choice).
- [ ] 15. Tap any other cell. Coral border moves to the tapped cell. Tap a third cell — border moves again. Selection is single-cell, exclusive.
- [ ] 16. "Confirm" button bottom-right (coral, primary), "Retake" bottom-left (secondary).

## E. Retake + Confirm flow

- [ ] 17. Tap "Retake" on the grid. All slots discarded; the sweep restarts from "0 of 6 captured." Service state machine resets cleanly (no leftover slot data).
- [ ] 18. Run a fresh sweep. Tap "Confirm" on the grid (with the default frontal pick OR a manually-chosen cell). Editor pops; you return to the client detail screen. Avatar circle shows the chosen frame within 1-2 seconds.
- [ ] 19. Re-open the editor (tap avatar circle again). The sweep re-runs; the new sweep REPLACES the existing slots in the cloud `client_face_embeddings` table (verified by the per-client embedding-count returning to 6 after the new sweep).
- [ ] 20. Test the `embeddingOnly` mode: toggle avatar consent OFF on the test client (face-rec stays ON). Re-open editor. Sweep runs identically but the post-sweep grid is SKIPPED — editor pops on sweep complete, no avatar persisted, embeddings still saved.
