# Pending Device Tests

Work that has landed on `main` but hasn't been visually verified on Carl's iPhone yet. Batched so Carl installs once and tests many.

---

## 2026-04-20 checkpoint (current)

**On device:** `fa3efa7` — the offline-first merge. Everything below has landed on main + is in production. Carl is actively QA-ing.

### Recently verified ✅
- Auth loop (password sign-in + magic-link fallback + bad-password fallthrough)
- Portal + mobile UI refactors (clients spine, dashboard R-12, new /network page)
- PayFast sandbox end-to-end (after the passphrase fix)
- Multi-practice switcher on both surfaces
- Pencil-grey line-drawing (final v6 locked)
- "Free credits" vocabulary sweep
- Practice name visibility on mobile
- Leading icon badges on session + client cards
- Session rename wires to `title` (not `clientName`) so the list reflects it

### Open device QA — needs verification round-trip

1. **Offline-first e2e** (`fa3efa7`):
   - Airplane mode → create a client → rename → toggle consent → confirm chip shows "N pending"
   - Airplane mode off → chip drains to hidden → cloud reflects all changes
   - Force-quit + relaunch while offline → cache survives, Home still populated
   - Create a client offline with a name that matches an existing cloud client → `upsert_client_with_id` rewire path kicks in on flush; verify local session refs update

2. **Three-treatment e2e** (vault secret is populated):
   - Capture + publish a new session for a client with `grayscale: true` consent
   - Open plan in mobile preview → B&W tab active → confirm grayscale renders
   - Open same plan in web player → B&W tab active → confirm CSS filter renders
   - Consent-revoke: toggle `grayscale: false` → reload preview → B&W tab disabled with lock

3. **Referral loop e2e**:
   - Create a new account via `/r/{existing-code}` with the POPIA consent checkbox on
   - Make a sandbox purchase
   - Verify in DB: `referral_rebate_ledger` has signup-bonus rows for both sides + lifetime rebate
   - Portal `/network` shows updated stats

4. **Large-plan publish path** — circuits + videos + rests combo, verify the raw-archive cloud upload (step 7.5 in `upload_service.dart`) doesn't regress primary publish on failure.

5. **Thumbnail readability (`feat/thumbnail-readability`)** — motion-peak frame pick + person-centred crop for video thumbnails. Landed via PR, but only visually validated is what the simulator can offer (synthetic camera has no person → crop falls back to un-cropped masked image). On device:
   - Capture a short video of yourself moving (squats, arm raises, anything with torso motion).
   - Check the Studio list thumbnail: should frame the body tightly with ~10% padding, not show empty floor/ceiling.
   - Compare against an older thumbnail on the device — it should be readable at the small list size.
   - Edge case: capture a stationary shot (practitioner standing still). Motion-peak should fall back gracefully to midpoint; person-crop should still tighten.
   - Edge case: capture a video without a person in frame (e.g. pointing at equipment). Person-segmentation will return nil → thumbnail falls through to the un-cropped masked image (same look as before).

6. **Studio MediaViewer — treatment cycling + inline consent** (branch `feat/studio-mediaviewer-treatments`):
   - Long-press a Studio thumbnail → "Open full-screen"
   - Verify top-left segmented control renders: Line · B&W · Original
   - Swipe up — cycles Line → B&W → Original → Line with a 220ms crossfade, per-step haptic
   - Swipe down — reverse cycle
   - Tap a segment directly — jumps, same crossfade
   - Active treatment != Line AND client exists → consent chip shows below control ("✓ {Name} can see this" or "Tap to allow")
   - Tap chip → flips state immediately (R-01 no-modal), SyncService queues the write
   - On a pre-archive capture (old session) → B&W + Original segments are greyed out with a lock glyph and tooltip "Older capture — re-record to enable."
   - Horizontal swipe between exercises — page changes, treatment resets to Line (intended)
   - Tap video — play/pause still works
   - Close button returns to Studio

7. **Studio MediaViewer polish — consent switch + swipe affordance** (branch `feat/mediaviewer-polish`):
   - Long-press a Studio thumbnail → "Open full-screen"
   - Active treatment is B&W or Original AND client exists → the consent affordance now renders as a dark pill with `Show {Name}` + an iOS-style Switch on the right (coral when on). Verify the Switch reads as a "setting you're tweaking", not an ack button. Flip it — immediate, no modal; SyncService queues the write. Toggle back — same.
   - Verify the Switch styling matches `ClientConsentSheet` (coral `activeTrackColor`, white thumb when on). Scale is slightly smaller (`Transform.scale 0.82`) to fit the compact pill.
   - "Exercise N of M" counter appears as a second line inside the name pill — confirm it stays pinned on swipe and that the count updates correctly.
   - Page dots at the bottom of the viewer — appear when the session has 2-10 exercises. Active dot grows to a short coral-free white capsule; inactive dots are small + translucent. Confirm they animate when swiping horizontally.
   - Plans with >10 exercises: dots hide (same pattern as `plan_preview_screen.dart`); the name-pill counter is the only where-are-we signal. Confirm behaviour.
   - Regression check: pre-archive captures still show locked B&W + Original segments; the consent row stays hidden when the archive is missing.

### Things to actively watch for
- **iOS 26.4 SDK gap** — any sub-agent build will fail in their sandbox on this; only Carl's main machine has the SDK installed. Not a code issue.
- **`sessions.client_id` backfill** — runs on every Home load; should be a no-op after first run per practice.
- **Offline pending-ops → online flush timing** — if a rapid sequence of creates+renames goes through while offline, the name-conflict rewire path is the edge case.

---

## Historic (archived — all shipped + verified)

Pre-2026-04-20 pending items that are now all complete. Kept here for reference only; do not re-verify.

- Studio layout blow-out bug — fixed, root cause was `CrossAxisAlignment.stretch` in a Row inside an unbounded-height parent
- Progress-pill matrix (both surfaces) — shipped
- `feat/auth-progressive-upgrade` — shipped as email + optional password + magic-link fallback
- Three-treatment segmented control — shipped on mobile + web player
- Referral backend + portal landing + mobile share card — shipped
- Mobile + portal Settings/Account pair — shipped
- Logo redesign to HomefitLogo — shipped on all surfaces
- PayFast sandbox smoke test — verified + signed off
