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

3. **Referral loop e2e** (updated for Milestone M credit model):
   - **Organic signup:** sign up WITHOUT a referral code. Immediately after bootstrap, the credit balance tile should show **3** (not 5). Query `credit_ledger` for that practice and expect exactly one row: `type='signup_bonus', delta=3`.
   - **Referral signup:** sign up via `/r/{existing-code}` with the POPIA consent checkbox on. Immediately after bootstrap + claim, the credit balance should show **8** (3 + 5). Query `credit_ledger` and expect TWO rows: `signup_bonus:3`, `referral_signup_bonus:5`.
   - **First (small) purchase by the referee — goodwill floor:** make a R250 / 10-credit starter-bundle sandbox purchase. Referrer's `/network` rebate balance should jump by exactly **1 credit** (raw 5% of R250 = 0.5 credits → floor clamps to 1). `referral_rebate_ledger` should have a `kind='lifetime_rebate', credits=1.0000` row, and `practice_referrals.goodwill_floor_applied` flipped to `true`.
   - **Second (larger) purchase by the referee — no floor:** make a R1000 / 40-credit clinic-bundle sandbox purchase. Referrer's rebate balance should jump by **2 credits** (raw 5% of R1000 = 2.0). `referral_rebate_ledger` should have another row: `kind='lifetime_rebate', credits=2.0000`. Goodwill flag stays `true`; no re-clamp.
   - Portal `/network` stats should reflect all three rows (1 credit + 2 credits = 3 credits banked; R1250 qualifying spend total).

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

7. **Studio MediaViewer — vertical treatment control** (branch `feat/vertical-treatment-control`):
   - Long-press a Studio thumbnail → "Open full-screen"
   - Verify the treatment segmented control now renders **vertically** on the left edge of the screen (centered in the safe area): Line on top, B&W in the middle, Original on the bottom. Orientation matches the vertical-swipe gesture that cycles treatments.
   - Tap each segment directly — should still jump to that treatment with the 220ms crossfade + selection haptic.
   - Tap a locked segment (pre-archive capture where B&W + Original are disabled) — lock glyph shows, tooltip reads "Older capture — re-record to enable."; consent bottom sheet still opens correctly where applicable.
   - Vertical swipe up/down on the video — still cycles treatments exactly as before.
   - Horizontal swipe left/right — still pages between exercises; treatment resets to Line.
   - Active treatment is B&W or Original AND client exists → the `Show {Name}` consent toggle now renders **directly below the vertical pill** (same left-edge stack). Flip it — instant, no modal; SyncService queues the write.
   - Exercise-name pill stays top-centered; close button stays top-right; page dots stay bottom-center. None of these collide with the left-edge vertical stack.
   - Regression: the plan preview screen (`plan_preview_screen.dart`) still renders the treatment control **horizontally** — no UX change there.

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

10. **Line-drawing audio restored** (branch `fix/line-drawing-audio`):
    - Capture a new video exercise with your voice talking over the movement (e.g. "squat, hold, up" while demoing).
    - Wait for the native line-drawing conversion to complete (Studio card leaves the spinner state).
    - Open the plan preview → Line treatment active → play the video → **verify the voiceover is audible**.
    - Cross-check with Treatment.original (raw archive) — should sound identical, same volume curve.
    - Toggle the per-exercise mic icon OFF on the Studio card → re-record the exercise → Line treatment must now play **silently** (no audio track muxed into the converted file at all, not just muted). Confirm with `ffprobe` on the converted file under `Documents/converted/{id}_line.*` if you want to be thorough: `Stream #0:0 Video`, no `Stream #0:1 Audio`.
    - Publish the plan → open on the web player at `session.homefit.studio/p/{uuid}` → Line tab → confirm audio plays there too (the published `line_drawing_url` is the same converted file that now has audio).
    - Regression: pre-existing captures (converted BEFORE this fix) remain silent until the practitioner re-captures them. This is expected — old files on disk aren't retroactively re-converted.

12. **Portal practice rename + popover switcher** (branch `feat/portal-rename-practice-inline-switcher`, Milestone N — **portal-only, mobile twin is a follow-up**):
    - **(a) Dashboard inline rename — owner:** sign in as `carlhein@me.com` (owner of `carlhein@me.com Practice`). The dashboard should render `Signed in as carlhein@me.com` followed by `In practice: carlhein@me.com Practice   ⇄ Switch`. Click the practice name → it switches to a text input with the old name selected. Type a new name, hit Enter → the sentence re-renders with the new name, a bottom-centre toast says "Practice renamed." After ~2.5s the toast fades. Refresh the page → name persists.
    - **(b) Account Settings rename — owner:** `/account?practice={yourPracticeId}` shows a new "Practice name" card above the password section, with the name as a dashed-underline title + a "Rename" button. Click either → edit mode. Commit via Enter; inline green "Practice renamed." confirms. Dashboard header subtitle + sidebar reflects the change.
    - **(c) Rename error paths:**
      - Type a name >60 chars → inline error "Name's a bit long — keep it under 60 characters." Input stays focused.
      - Clear the field + hit Enter → "Name can't be empty."
      - Hit Esc mid-edit → draft reverts, no RPC call fires.
    - **(d) Switch via `⇄` popover — multi-practice:** sign-in as `carlhein@me.com` (belongs to two practices). Click `⇄ Switch` → a dark rounded card (~240px wide) fades + slides up just below the link. The ACTIVE practice is listed first with a coral ✓ and shows "{N} credits" under the name; the other membership is below it, tappable. Click the other row → dashboard navigates to `?practice={otherId}` and re-renders with the new context. Click `⇄ Switch` again → close on outside-click, Escape, or after a pick.
    - **(e) Owner-only edit rule:** sign-in as `carlhein@me.com` (practitioner role on `carlhein@icloud.com Practice`). Switch context to that practice (via popover). The dashboard practice-name should render as plain bold ink (no dashed underline); hovering shows the tooltip "Only the practice owner can rename." On `/account`, the Practice-name card copy reads "Only the practice owner can change this." and no Rename button is shown. Try calling `rename_practice(practiceId, 'hack')` via a browser console RPC → 42501 `only the practice owner can rename it`.
    - **(f) Single-membership users don't see the `⇄ Switch`:** sign-in as `carlhein@icloud.com` (owner of exactly one practice). The `⇄ Switch` affordance should be hidden; the editable name is still there. Account page works identically.
    - DB sanity: `SELECT name FROM practices WHERE id = '{id}';` reflects the latest rename. `SELECT proname FROM pg_proc WHERE proname = 'rename_practice';` returns 1 row.
    - **Out-of-scope:** the mobile practice-chip bottom-sheet still shows the old "switcher only" UX. R-11 twin (inline rename + popover-style switcher on the mobile sheet) is a separate follow-up PR.

11. **Studio MediaViewer — coral bottom-right play/pause** (branch `fix/mediaviewer-play-pause-overlay`):
    - Long-press a Studio thumbnail → "Open full-screen" on a video exercise
    - Video auto-starts; coral circular **pause** button appears bottom-right immediately (~85% opacity, white glyph, 56-px touch target, sitting above the bottom page-dots row with no overlap)
    - Wait ~2 seconds: button fades to 0 over ~300 ms so it no longer overlays the demo-to-client view
    - Tap the video body anywhere: button reappears and toggles state (playing → paused). While paused the button stays visible indefinitely as a **play** glyph.
    - Tap the coral button directly: it toggles state. This is the bug-2 regression check — a direct tap on the icon *must* actually call the toggle (the old centred white icon absorbed taps with no action).
    - Resume with another direct button tap: glyph flips to pause, idle timer re-arms, fade kicks in ~2s later.
    - Swipe horizontally to the next video exercise: button stays wired + fade restarts for the new video. Vertical treatment swipes also preserve behaviour.
    - No "Play video" / "Pause video" visible text (R-06 voice).

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

12. **Delete client + cascade undo** (branch `feat/delete-client`, Milestone L):
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

13. **Line-drawing audio — actually restored** (branch `fix/line-drawing-audio-actually`):
    - PR #29 fixed the Swift `sourceFormatHint` path correctly, but the Dart pipeline was collapsing `includeAudio` to `false` for every fresh capture: `ExerciseCapture.includeAudio` defaults to `false` in the model (intentional — the flag is a SHARE-time concern per its docstring + the "Include audio on share" Studio toggle label), and `conversion_service.dart` was threading that default through to the native converter. Result: the Swift gate skipped the audio track setup entirely, the output mp4 was video-only, and Line treatment played silent — even on a brand-new capture. This follow-up unconditionally passes `includeAudio: true` into the converter (the model flag stays a playback/share concern — `plan_preview_screen.dart:425` already uses it to set player volume; web player uses it for the `muted` attribute).
    - Capture a new video exercise with voice-over after installing this build.
    - Wait for conversion to complete (Studio card leaves the spinner).
    - Xcode device log or `xcrun devicectl device process console --device 00008150-001A31D40E88401C` should show a line: `[VideoConverter] convert done — frames=… audioIncluded=true audioInputAttached=true audioSamplesWritten=N …` where N > 0. If `audioSamplesWritten=0`, the bug has moved — not fixed.
    - Open plan preview → Line treatment → audio plays.
    - Cross-check B&W / Original tabs — should sound identical (they already worked; pulled from raw archive).
    - Optional `ffprobe` round-trip: pull the converted file off the device via Xcode → `ffprobe -v error -show_streams <file>` → expect both a `codec_type=video` AND a `codec_type=audio` stream.
    - Toggle per-exercise mic icon OFF in Studio → preview the same exercise → video plays **muted** via the player's volume=0 (audio is still in the file; we no longer gate at convert time — acceptable regression for the simpler model. The ffprobe output will still show an audio stream).
    - Regression: pre-existing captures converted before this build remain silent. Expected — old files on disk aren't retroactively re-muxed.
