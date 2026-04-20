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

7. **Delete client + cascade undo** (branch `feat/delete-client`, Milestone L):
   - Home → swipe-left on a client row → red "Delete" reveals → card slides out
   - UndoSnackBar appears at the bottom with a 7-second window
   - Tap Undo → the client row comes back; every session that was cascaded lands back under ClientSessions
   - Swipe + don't tap Undo → wait 7s → row stays gone
   - Open the per-client screen → overflow menu (top-right `⋮`) → "Delete client" — fires immediately, pops to Home, SnackBar with Undo appears
   - Offline path: airplane mode + swipe-delete → "N pending" chip bumps by 1 → toggle online → drains; cloud rows now tombstoned
   - Offline path: airplane mode + swipe-delete + Undo during the 7s window → both ops queue + cancel out server-side (delete lands, restore lands right after)
   - Resurrection check: create a new client with the SAME name as a just-deleted one → `upsert_client_with_id` RPC returns a 23505 "a deleted client already uses that name" — surface the error cleanly
   - Portal `/clients` page → hover the row (desktop) → delete icon fades in bottom-right → click → row vanishes + bottom-centre toast with Undo for 7s → Undo reinstates
   - Portal `/clients/[id]` → Delete button in the header → click → navigates to `/clients` + the list page surfaces the Undo toast via sessionStorage handshake
   - Confirm in DB after a delete: `SELECT deleted_at FROM clients WHERE id=...` is non-null, `SELECT id, deleted_at FROM plans WHERE client_id=...` mirrors the same timestamp
   - Confirm after Undo: both `deleted_at` back to null on the client AND the cascaded plans

8. **Studio MediaViewer — treatment cycling + inline consent** (branch `feat/studio-mediaviewer-treatments`):
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
