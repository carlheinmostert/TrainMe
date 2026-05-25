# Three-wave install — device QA (2026-05-25)

Wave-close install bundling three parallel-session waves merged to staging today. Branch: `staging`. Build SHA: `674e2ef`. Mode: profile.

**What changed** — 18 ios-impact PRs:
- **Wave 1** — Self-trainer foundation + completion + hot-fixes (15 PRs #486 → #511). Checkpoint: [`docs/CHECKPOINT_2026-05-25-self-trainer-wave-shipped.md`](../CHECKPOINT_2026-05-25-self-trainer-wave-shipped.md).
- **Wave 2** — Safe Mode v2 video pipeline (#506 native + #497 Dart). v1 video pipeline removed. Handover: [`docs/handoffs/2026-05-25-safe-mode-v2-video-wave.md`](../handoffs/2026-05-25-safe-mode-v2-video-wave.md).
- **Wave 3** — Exercise Clipboard (#505). Handover: [`docs/handoffs/2026-05-25-exercise-clipboard.md`](../handoffs/2026-05-25-exercise-clipboard.md).

**Schema** — SQLite v47 → v48 (`cached_clients.user_id` added). 9 Supabase migrations on staging. New dep: `flutter_slidable: ^3.1.2`.

**Scope of this script** — cross-cutting golden-path items only. Detailed per-PR walks live in the 17 wave-specific scripts; see "Per-PR detail" below to drill in when something fails.

## A. Smoke + IA

- [ ] 1. Cold launch lands on **My Workouts** (not Clients) — new IA default per #487.
- [ ] 2. Build chip at footer reads `staging · 674e2ef`.
- [ ] 3. Migration intro banner renders if shown — copy contains NO `[carl-review:]` or `[lawyer-review:]` placeholder tokens (CA-2 ship-stopper fix).
- [ ] 4. Tap the **Clients** capsule → switches to clients list cleanly.
- [ ] 5. Tap back to **My Workouts** → renders the list body (or empty-state with the "Got a link from your practitioner?" muted line; that text is non-tappable by design — see Known gaps below).

## B. Self-trainer capture + self-verification

- [ ] 6. Tap the FAB on My Workouts *without* face-rec consent → **consent sheet appears** (PR #502 + Hotfix B M-2 race fix). No crash, no silent grant.
- [ ] 7. Grant face-rec + avatar consent → enrolment screen begins (pose-gated sweep per #496 — 6-segment ring, rejected slots show raw score, no Start button).
- [ ] 8. Capture a photo into a self-session → Studio card shows the exercise. Long-press the failed-pill / inspect: `self_verified=true` stamped (PR #503 + Hotfix B CA-3 cache-invalidation).
- [ ] 9. Capture a video into the same session → **coral determinate progress bar** appears under the thumbnail during conversion (new Safe Mode v2 video overlay, PR #497). Verify it disappears cleanly on completion — no spinner stuck.
- [ ] 10. Settings → Public profile → toggle **Stop using face verification** off → confirm the embedding is cleared on-device + cloud, but the selfie photo persists (Hotfix D M-7, CA-5 RLS REVOKE).

## C. Publish cost preview + free path

- [ ] 11. Open a self-session with **all exercises self-verified** → Studio workflow pill reads **"Publish · Free"** (PR #507).
- [ ] 12. Tap publish → completes without credit debit. (No need to check the ledger inline; the pill is the signal.)
- [ ] 13. Add an unverified exercise to the same session (e.g. capture with someone else's face, or skip face) → pill **recalculates** to "Publish · 1 credit" or "Publish · 2 credits" depending on duration.
- [ ] 14. Open a normal client session (non-self) → pill shows the duration-based price as before (1 or 2 credits). No regression on the existing publish path.

## D. Safe Mode v2 video pipeline (Wave 2 — net-new)

- [ ] 15. Inside an enforcing premises, record a video → coral progress bar fills smoothly (Wave 2 item #11 from this script covers this — note algo stamp).
- [ ] 16. **Cover lens with palm** during a video capture → SafeModeRejection toast inside ~4s (palm = face AND segmentation both fail — the new rejection trigger per spec 6b). **No orphan exercise row left in Studio** (PR #490 fix).
- [ ] 17. Backlit but face still detectable → capture **accepted** with safe variant (no rejection — single-signal v1 behaviour is retired).
- [ ] 18. After capture, inspect the exercise row → `safe_mode_algorithm_version = 3` (NOT 2 — Wave 2 binds both photo + video to v3).

## E. Safe Mode subscription gate (#504)

- [ ] 19. Inside enforcing premises *without an active subscription* → **paywall sheet** appears at capture entry. Copy reads **"Subscribe · 4 credits / month"** — **no trial promise, no "we'll notify you" promise** (Hotfix D M-9 fix).
- [ ] 20. Tap subscribe in-app → routes correctly (portal page or in-app flow per the PR).

## F. Exercise Clipboard (Wave 3 — net-new)

- [ ] 21. In Studio, **partial right-swipe** on an exercise card reveals `[Copy] [Duplicate]` buttons. **Long right-swipe** auto-commits Copy.
- [ ] 22. Tap Copy → **coral particle animation** flies diagonally to the top-right chip → chip shows `[icon 1 ×]`.
- [ ] 23. Copy 3 exercises from this session → chip badge reads `3`. **Switch to another session** (different client) → chip **persists** at 3 (D1 single-practice scope).
- [ ] 24. Tap chip → paste sheet opens with all 3 selected by default → CTA reads `Paste 3 items` → tap → all 3 appear at end of the target session in FIFO order.
- [ ] 25. Switch practice (practice chip top-left) → clipboard chip count **filters down** to only items from the current practice (D1 enforcement per S-1 fix).
- [ ] 26. On a session **past the 14-day grace window**, try to paste → CTA reads **"Unlock to paste · 1 credit"** with a **dashed coral border** (PR #505 S-6 fix). Confirm → unlocks + pastes in one flow.

## G. Portal sanity (manage.staging.homefit.studio)

Not strictly device QA, but easiest to walk while the phone is in hand.

- [ ] 27. Open `staging.manage.homefit.studio/subscribe` → page reads **"Subscribe · 4 credits / month"** (no trial promise; no "we'll notify").
- [ ] 28. Open `/privacy` → § 5(d) names the data region as **"eu-central-1 (Frankfurt)"** (Hotfix D CB-8 fix).

## H. Known gaps — should FAIL (confirm failure mode)

- [ ] 29. My Workouts empty-state "Got a link from your practitioner?" line is **muted text, not tappable** — `plan_invitations` table doesn't exist yet; inbound-from-practitioner card path deferred to a future wave. Expected behaviour, not a bug.

## Per-PR detail

If any item above fails, open the matching per-PR script for a more focused walk:

- Wave 1 — [#501 banner](2026-05-25-self-trainer-banner.md) · [#502 consent + Self-client](2026-05-25-self-trainer-consent.md) · [#503 self-verification](2026-05-25-self-verification.md) · [#504 paywall](2026-05-25-safe-mode-paywall.md) · [#507 publish cost preview](2026-05-25-publish-cost-preview.md) · [#508 My Workouts body](2026-05-25-my-workouts-body.md) · [#494 face embedding](2026-05-25-self-face-embedding.md) · [#493 plan artifacts](2026-05-25-plan-artifacts-write.md) · [#490 zero-detection accept](2026-05-25-safe-mode-zero-detection-accept.md) · [#491 enrolment polish 1](2026-05-25-safe-mode-v2-enrolment-polish-phase1.md) · [#496 enrolment polish 2](2026-05-25-safe-mode-v2-enrolment-polish-phase2.md) · [#509 DB hotfix](2026-05-25-self-trainer-db-hotfix.md) · [#511 mobile hotfix](2026-05-25-self-trainer-mobile-hotfix.md)
- Wave 2 — [#506 + #497 Safe Mode v2 video](2026-05-25-safe-mode-v2-video.md) (13 items)
- Wave 3 — [#505 Exercise Clipboard](2026-05-25-exercise-clipboard.md) (20 items)
- Adjacent — [#482 + #485 Safe Mode photo colorspace](2026-05-25-safe-mode-photo-colorspace.md) (the AM polish day that rode beneath all three waves)
