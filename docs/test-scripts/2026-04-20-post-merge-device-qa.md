# Device QA — 2026-04-20 post-merge bundle

**On phone:** build from this morning's `install-device.sh` (all 8 merged PRs) + the live `delete_client` RPC fix. No new install needed to run these tests.

**Out-of-scope / still in flight:**
- Line-drawing audio on fresh capture — root-cause agent still hunting
- Vertical pill text rotation — per-exercise-treatment-preference agent still running
- Share-kit redesign at `/network` — impl agent still running
- Business case xlsx review — refactor agent still running

---

## 1. Delete client — drain recovery (highest priority)

The 3 stuck pending ops should now drain on next sync cycle.

- [ ] Force-close the app and reopen. Pending chip should count down **3 → 0**.
- [ ] Delete a fresh client from Home (swipe-left). Should drain immediately — no new pile-up.
- [ ] Tap Undo within 7 seconds. Client + cascaded sessions come back.
- [ ] Offline test: airplane mode ON → swipe-delete → "N pending" increments → airplane mode OFF → drains.
- [ ] Delete from the client detail screen (overflow `⋮` → Delete client). Pops to Home with Undo SnackBar.

## 2. B&W thumbnails (fresh capture)

- [ ] Capture a new video exercise with yourself moving.
- [ ] Studio list thumbnail shows a **readable B&W frame** with the person centred — not old line-drawing strokes.
- [ ] Old captures keep their existing thumbnails (intentional — not retroactively regenerated).
- [ ] Web player playback of the same exercise still shows line drawing by default (client surface unchanged).

## 3. MediaViewer — play/pause overlay

Long-press a thumbnail → "Open full-screen" on a video exercise.

- [ ] **Coral circular button bottom-right**, not the old centred white arrow.
- [ ] Video autoplays → button fades to 0 after ~2s.
- [ ] Paused → button stays visible indefinitely as a play glyph.
- [ ] Tap the coral button directly → it **actually toggles**. (This was the bug — old icon absorbed taps with no action.)
- [ ] Tap the video body → also toggles. Button reappears + idle timer re-arms.
- [ ] Swipe horizontally to next video — button stays wired.

## 4. Sync-failure banner

- [ ] Airplane mode ON with cached clients → list stays visible, "Offline" chip shows, **no** coral error banner (offline is expected, not an error).
- [ ] Online + RPC-failure path (only if you want to exercise it): in Supabase SQL editor run `revoke execute on function public.list_practice_clients(uuid) from authenticated;` for ~30s, relaunch app. Cached clients stay visible + coral banner: "Couldn't refresh. Tap to retry." Restore with `grant execute on function public.list_practice_clients(uuid) to authenticated;`.

## 5. Portal — Network tile copy

Open https://manage.homefit.studio/dashboard (after the latest Vercel deploy).

- [ ] Network tile shows **"Earn Free Credits"** on zero balance (not the old "Free Publishes Banked").
- [ ] `/network` page intro says "free credits" throughout.

## 6. Web player — new logo

Open any published plan URL (`session.homefit.studio/p/…`).

- [ ] Header renders the **new matrix logo** (coral band + grey ghosts), not the old heartbeat Pulse Mark.
- [ ] `/r/{code}` preview card OG image also has the new logo.

---

## Feedback format

Check items off directly, or just message me what's broken / wonky / right.
