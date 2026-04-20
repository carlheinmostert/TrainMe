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

5a. **Grayscale practitioner thumbnails** (`feat/grayscale-practitioner-thumbnails`) — follow-up to #5. PR #22's person-crop alone wasn't enough: the line-drawing medium itself stayed illegible at list sizes. Now practitioner-facing thumbnails extract from the raw capture + recolour to luminance (B&W). Client-facing surfaces (web player) are unchanged — line drawing stays there. On device:
   - **New capture → B&W thumbnail**: capture a fresh video exercise. Home client list, ClientSessions, Studio list, Thumbnail Peek, and the Camera peek box should all show a grayscale frame with the person centred and readable. No line-drawing strokes.
   - **Old captures unchanged**: captures that existed before installing this build should keep their old line-drawing thumbnail on disk. We intentionally skipped retroactive regeneration to avoid storage churn — re-capture to refresh.
   - **Web player unchanged**: publish the new capture → open the client URL in a browser. The exercise video should play the line-drawing treatment by default (coral `line_drawing_url`). The B&W treatment is still reachable via the segmented control only when the client has consent.
   - **Thumbnail is practitioner-only**: the web player does not expose the thumbnail JPEG. It renders the video frame live and reads `line_drawing_url` / `grayscale_url` / `original_url` from `get_plan_full` — not the client-side thumbnail. Quick check: network tab in the browser should never load `{id}_thumb.jpg`.
   - Edge case: capture where person-segmentation misses (no person in frame) → still produces a grayscale thumbnail of the full frame (no crop), which is still readable, just wider context.

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

8. **Home sync-failure banner** (branch `fix/surface-sync-errors`):
   - **Happy path (online + healthy cloud):** open the app with good signal → clients list populates as before → no banner, no empty-state → `Updated Xm ago` hint renders as today. Verify nothing regressed.
   - **Airplane-mode path (offline with cached clients):** toggle airplane mode on → pull-to-refresh the Home list → clients stay visible → offline chip appears next to the practice chip → **no red/coral sync-failure banner** (the offline state is expected, not surfaced as an error).
   - **Online + RPC failure path (the bug Carl hit):** force an RPC failure while online. Easiest reproduction:
     - Sign in, then in Supabase SQL editor run `revoke execute on function public.list_practice_clients(uuid) from authenticated;` for ~30s.
     - Relaunch the app or trigger a practice switch.
     - Expected: cached clients STILL visible on Home; a coral-bordered banner appears above the list: "Couldn't refresh. Tap to retry." Tapping it shows a spinner; while the RPC is still revoked, another tap increments the counter ("Couldn't refresh (2 tries). Tap to retry.").
     - Restore permissions: `grant execute on function public.list_practice_clients(uuid) to authenticated;` Tap retry → banner dismisses, `Updated just now` hint returns.
   - **Cache-empty + RPC failure** (the really nasty case): fresh install + online + RPC failure → empty-state card renders with a prominent "Try again" button instead of the old silent "No clients yet" that made Carl think his data was gone. Tap → retries; on success, normal empty-state (or populated list) appears.

9. **Studio MediaViewer polish — consent switch + swipe affordance** (branch `feat/mediaviewer-polish`):
   - Long-press a Studio thumbnail → "Open full-screen"
   - Active treatment is B&W or Original AND client exists → the consent affordance now renders as a dark pill with `Show {Name}` + an iOS-style Switch on the right (coral when on). Verify the Switch reads as a "setting you're tweaking", not an ack button. Flip it — immediate, no modal; SyncService queues the write. Toggle back — same.
   - Verify the Switch styling matches `ClientConsentSheet` (coral `activeTrackColor`, white thumb when on). Scale is slightly smaller (`Transform.scale 0.82`) to fit the compact pill.
   - "Exercise N of M" counter appears as a second line inside the name pill — confirm it stays pinned on swipe and that the count updates correctly.
   - Page dots at the bottom of the viewer — appear when the session has 2-10 exercises. Active dot grows to a short coral-free white capsule; inactive dots are small + translucent. Confirm they animate when swiping horizontally.
   - Plans with >10 exercises: dots hide (same pattern as `plan_preview_screen.dart`); the name-pill counter is the only where-are-we signal. Confirm behaviour.
   - Regression check: pre-archive captures still show locked B&W + Original segments; the consent row stays hidden when the archive is missing.

8. **Line-drawing audio restored** (branch `fix/line-drawing-audio`):
   - Capture a new video exercise with your voice talking over the movement (e.g. "squat, hold, up" while demoing).
   - Wait for the native line-drawing conversion to complete (Studio card leaves the spinner state).
   - Open the plan preview → Line treatment active → play the video → **verify the voiceover is audible**.
   - Cross-check with Treatment.original (raw archive) — should sound identical, same volume curve.
   - Toggle the per-exercise mic icon OFF on the Studio card → re-record the exercise → Line treatment must now play **silently** (no audio track muxed into the converted file at all, not just muted). Confirm with `ffprobe` on the converted file under `Documents/converted/{id}_line.*` if you want to be thorough: `Stream #0:0 Video`, no `Stream #0:1 Audio`.
   - Publish the plan → open on the web player at `session.homefit.studio/p/{uuid}` → Line tab → confirm audio plays there too (the published `line_drawing_url` is the same converted file that now has audio).
   - Regression: pre-existing captures (converted BEFORE this fix) remain silent until the practitioner re-captures them. This is expected — old files on disk aren't retroactively re-converted.

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
