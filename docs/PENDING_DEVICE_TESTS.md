# Pending Device Tests

Work that has landed on `main` but hasn't been visually verified on Carl's iPhone yet. Batched so Carl installs once and tests many.

Reference items by commit hash + feature name when reporting feedback.

---

## 2026-04-18 end-of-session checkpoint

**On device:** `feat/auth-progressive-upgrade` at build `e67669f` (SHA visible bottom-right of Pulse Mark footer on Home). Password + magic-link path **confirmed working** — nothing to re-verify there.

**Parallel agents running at time of this checkpoint:**

- `fix/studio-reorderable-listview` — Studio layout blow-out fix. Third attempt. Plain `ReorderableListView.builder` replacing the `CustomScrollView + SliverReorderableList` stack. Needs device verification next session — confirm that a plan with a circuit (e.g. 3 exercises linked + 2 rounds) renders without stacking to multi-viewport heights.
- `feat/progress-pills` — ETA widget completion (`7:42 left` + `~7:42 PM`, wall-clock drift when paused). Flutter `app/lib/widgets/progress_pill_matrix.dart` + web player pill matrix already in place. SW cache bump to `homefit-player-v11-pill-matrix`.

**Next-session priorities:**

1. Verify `fix/studio-reorderable-listview` on device. If clean → merge to main, delete branch. If still broken → re-diagnose (don't repeat the two main-side attempts `9bfc0f8` / `326c6b8`).
2. Verify `feat/progress-pills` + ETA on device. If clean → merge. Bumps SW cache → client web-player installs will force-refresh.
3. Merge `feat/auth-progressive-upgrade` after a final device walk-through (Sign-In screen → password path → magic-link path → Home banner → SetPasswordSheet).
4. Finish the PayFast sandbox smoke test (below) unless already done.

**Unmerged branches as of checkpoint:** `feat/auth-progressive-upgrade`, `feat/progress-pills`, `fix/studio-reorderable-listview`. Also stale: `fix/studio-stack-rail-rewrite` (superseded; safe to delete).

---

## Tomorrow's resume point (2026-04-18) — PayFast sandbox smoke test

Portal is live at `https://manage.homefit.studio` (as of 2026-04-17 evening). Smoke step 1/4 passed — `/credits` renders the bundle list. **Remaining steps:**

1. On `https://manage.homefit.studio/credits`, click **Buy Starter**.
2. Browser bounces to `sandbox.payfast.co.za`. Pay with sandbox test card:
   - Card: `4000 0000 0000 0002`
   - Expiry: any future month/year
   - CVV: any 3 digits
3. PayFast bounces back to `https://manage.homefit.studio/credits/return`.
4. Within ~5s, refresh the dashboard — the credit balance should show **+10**.

**If balance doesn't update within ~30s:**

- Check the Supabase `pending_payments` table — the intent row should have status `complete`.
- Check Supabase Edge Functions → Logs for `payfast-webhook` — look for which of the 4 authenticity gates (signature / IP / validate / amount) failed.
- Common sandbox gotcha: PayFast's sandbox IPs change periodically; if IP gate fails, we can temporarily set `PAYFAST_SKIP_IP_CHECK=true` as a function secret for testing (never in prod).

Once round-trip is clean, **D4 sandbox is signed off** and we move to **D2 — Flutter practice picker** in a background sub-agent.

---

## Pending — install and verify

### Commit `7fc84e6` — Studio card + Home UI refinements
- Slider labels shrunk (likely to be replaced by the next item — see below)
- Preview sub-section removed from expanded cards
- Chevron + drag handle sit flush as a pair
- Thumbnail tap opened `PlanPreviewScreen` at the exercise's slide index — **superseded** by the next item

### Commit `3c4778b` — Milestone B: Google social sign-in + AuthGate + sentinel claim
- Launch → Sign-In screen (Google button + Apple "Coming soon" pill).
- Tap Continue with Google → browser opens Google consent → redirect back to app → land on home screen as signed-in user.
- First sign-in auto-claims the Carl-sentinel practice with its pre-seeded 1000 credits.
- Sign out option — should land back on Sign-In screen.
- Publish a plan — verify `plan_issuances` audit row now uses your real auth.uid() as `trainer_id`.

### Commit `2de937e` — Slider vertical layout + thumbnail media viewer
- Slider rows now render as `Column`: `[label on left, value on right]` row above, slider full-width below. Full card width. No truncation, no "R..." artefacts.
- Thumbnail tap opens a full-screen `_MediaViewer`: auto-plays video (tap to pause/resume), or shows photo, with close button top-right. Rest exercises are non-tappable (no media).
- Replaces the behaviour from `7fc84e6` which incorrectly opened the workout-mode `PlanPreviewScreen`.

### Commit `7fc84e6` — Home screen inversion
- Sessions list bottom-anchored (`reverse: true` pattern from Studio).
- New Session button moved to just above the footer.
- Powered-by-homefit.studio footer pinned at the very bottom.

### Commit `fc30f69` — Rest page timer consolidation (Flutter preview)
- Deleted the fullscreen centered rest overlay.
- Timer chip now shows on rest slides (running/paused modes).
- Rest card simplified: icon + "Rest" label + "Next up: X" subtitle, no duplicate countdown number.
- Web player version of this already validated — test the Flutter preview.

### Earlier commits `6b8847a` / `dc992db` (validated briefly, worth re-verifying post-merge)
- Per-second `mediumImpact` haptic tick during video recording.
- Pulsing red dot as visual backup during recording.
- Peek box with no spinner.
- Pinch-to-zoom + 0.5x/1x/2x/3x lens row on camera.
- Long-press release reliably stops recording.

---

## When ready to test

```bash
cd /Users/chm/dev/TrainMe/.claude/worktrees/zen-euler-36b643/app && flutter build ios --release
```

VPN off →

```bash
xcrun devicectl device install app --device 00008150-001A31D40E88401C /Users/chm/dev/TrainMe/.claude/worktrees/zen-euler-36b643/app/build/ios/iphoneos/Runner.app
```

VPN on. Walk through each section and feed back by commit hash.
