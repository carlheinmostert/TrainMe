# Wave 40 — Plan

**Status:** Scoped 2026-04-28. Locked after Wave 39.4 hotfix lands. Don't fire implementation agents until Wave 39.4 has merged.

## Theme

Two surfaces, both shifted from "what the app *can* do" to "what the practitioner *should* do":
- **Mobile Camera** — promote capture to first-class, demote library import to a secondary affordance inside Camera; add a permanent hint + slide-up-to-lock recording gesture so 30s+ video demos don't depend on a held finger.
- **Portal hygiene** — strip redundant nav, surface client engagement signals consistently, fix the broken Clients drill-in.

---

## Mobile (Flutter)

### M1 · Studio toolbar — Camera replaces Library

- First slot in the bottom toolbar's workflow chain becomes a **coral camera icon**. Tapping it = same as swipe-left to Capture mode (no modal).
- The `photo_library_outlined` icon currently in slot 1 is **deleted from the toolbar**. The library affordance survives in M2.
- Updated chain: `Back · Camera → Preview → Publish/Unlock → Share`.

### M2 · Library import inside Camera

- Bottom-left of the camera viewfinder: 44×44pt round icon (translucent black background, 22pt photo-stack glyph).
- Position: ~16pt from screen edges. Sits well below the existing peek box (which stays mid-left).
- Tap → opens iOS multi-select photo picker.
- **For each picked photo, fire the SAME pipeline as a captured photo**: peek-box animation + conversion queue entry + StudioCard append. No batched silent ingest.
- The picker is the existing import path (already wired in `studio_mode_screen.dart` for the now-retired toolbar slot) — refactor the call site to live in capture mode instead.

### M3 · Permanent hint copy

Replace the current auto-fading hint with a permanent caption under the shutter, 55% opacity, 10.5pt Inter, three states:
- **Idle:** `Tap for photo · Hold for video · Slide ↑ to lock`
- **Pressed-recording:** `Slide finger ↑ onto 🔒 to lock`
- **Locked:** `Tap ⬛ to stop`

### M4 · Slide-up-to-lock recording gesture

- Press-and-hold shutter starts video recording (existing behaviour preserved).
- Once recording starts: a **lock target** fades in (~200ms) at 80pt above the shutter — 56pt round, translucent black, lock glyph.
- A subtle drag-track (4pt wide, 32pt tall, vertical gradient) appears between shutter and lock target, suggesting the gesture path.
- While the finger remains pressed on the shutter, dragging vertically up onto the lock target snaps locked: haptic confirmation, lock target turns coral, shutter inner morphs from red dot to white square.
- Release: recording continues.
- **To stop:** tap the morphed shutter (the white square). Mirrors iPhone Camera; the visual transformation does the explaining.

### M5 · Right-edge vertical lens pills

- Move the lens stack (`.5 / 1× / 2 / 3`) from around the shutter to a **vertical column on the right edge** of the viewfinder.
- 44×44pt pills, 8pt gap between, vertically centred. Active pill inverts (white background, black text). Translucent black for inactive.
- This keeps the lock-drag corridor (centre-vertical) clean.
- Pinch-to-zoom continues to work; tapping pills is a discoverable shortcut.

### M6 · Toolbar icon glyph swap + sizing bump

Studio bottom toolbar (`app/lib/widgets/studio_bottom_bar.dart`):
- Glyphs swap to the set drawn in [docs/design/mockups/wave40-camera-layout.html](design/mockups/wave40-camera-layout.html):
  - Library → Camera (coral): video-camera glyph
  - Preview: play-triangle (already correct, confirm)
  - Publish: cloud-upload arrow (existing, confirm)
  - Share: share-network glyph (3 connected dots, confirm)
  - Unlock (locked state, replaces Publish): lock_outline (existing — keep)
- Sizing bump: `_ToolbarIconButton` container `44 × 44` → `48 × 48`, `Icon size: 24` → `Icon size: 28`. Triangle (`_Triangle`) scales proportionally — increase `width: 8 → 10`, `height: 12 → 14`. Splash radius `22 → 24`.

---

## Portal (Next.js — `manage.homefit.studio`)

### P1 · Strip top-bar nav links (Home)

- Remove the top nav menu items: `Clients · Credits · Network · Audit · Members · Account`. The dashboard's clickable stat tiles ARE the navigation; the top bar duplicating them is redundant.
- **Keep:** the account menu (avatar/dropdown on the right) and the practice switcher (see P3).

### P2 · Show signed-in user identity in the header

- Render the signed-in user's email next to the account menu chip — visible at a glance, no hover required.
- Format: `[carlhein@me.com ▾]` — chip with email + dropdown caret. Click opens the existing account dropdown (sign out, account settings).

### P3 · Practice switcher placement

- Right-cluster: `[Practice: BigBoss ⇄] [carlhein@me.com ▾]` aligned to the right of the top bar. Practice switcher sits to the LEFT of the account-menu chip. (Carl confirmed 2026-04-28.)
- The switcher chip stays clickable → opens the existing Milestone N popover with the practice list.

### P4 · Dashboard audit CARD shows real data

- The dashboard tile that previews "recent audit activity" currently renders nothing.
- Fix: pull the 5 most recent audit events for the active practice (sage chip per kind + actor email + relative timestamp). Click the card → routes to `/audit?practice=…`.
- Same `listAudit` call as the dedicated page, with `limit: 5`.

### P5 · Audit kind legend — inline chips

- The kind chips legend (CREDITS IN / DESTRUCTIVE / NEUTRAL groups) currently wraps each kind to its own line, taking ~5 vertical lines. Carl wants the chips to flow inline, wrapping naturally — group label inline as a quiet `<small>` left-of-cluster, then chips wrap horizontally.
- Target visual: 1-2 wrap lines total instead of 5.

### P6 · Clients list: use client avatar glyph

- Each client row gets the same avatar treatment as mobile (Wave 30 — body-focus blurred avatar JPG when present, initials circle as fallback).
- Pull from `cached_clients` if the column exposes the avatar URL, otherwise initials.

### P7 · Clients drill-in — fix the routing bug

- **Bug:** Clicking a client on `/clients` routes to `/dashboard` instead of `/clients/[id]`.
- Investigate: most likely an `onClick` handler error or a `Link href` misconfiguration. Probably introduced in the Milestone L (delete client) or N (popover switcher) churn.
- Fix the router target so client tiles open their detail page.

### P8 · Client detail — session icon parity

- Inside `/clients/[id]`, each session row uses the SAME session icon used on mobile's SessionCard (the small thumbnail + body-focus avatar + exercise count badge).
- Pull the avatar/thumbnail from the same data source mobile uses (cloud `clients.avatar_url` if present, plus the latest exercise's thumbnail).

---

## Settings + audit follow-ups (from Wave 39 QA)

### S1 · System defaults configurable in app Settings

- Wave 39 surfaced this as Item 3: practitioners want to tune the system-wide defaults (`StudioDefaults`) — reps, sets, hold, prep, custom-duration, video-reps, inter-set-rest.
- Add a Settings section (mobile): "Default values for new exercises" — seven editable fields, each with the current `StudioDefaults` value as placeholder.
- Persist per-device in `SharedPreferences` under stable keys. Override `StudioDefaults` reads to consult the per-device value first.
- Reset button: "Restore homefit defaults" — clears the overrides.

### S2 · Audit feed: always-have-actor + dedicated Client column

- Wave 39 Item 9: practitioners want the audit Actor column to never be NULL. Today `plan.opened` rows show "Client" as a label substitute; Carl wants the actor column always populated by SOMEONE meaningful AND a separate Client column for the affected client.
- Schema:
  - For `plan.opened`, "actor" stays the anon web player but the Actor column should display the **practitioner who owns the plan** (i.e. the trainer who last published it). Pull `plan_issuances.trainer_id` for the latest issuance and surface as actor.
  - Add a `client_id` derivable column to the audit RPC (join `plans.client_id` for plan-shaped rows; fall back to `clients.id` for client-shaped rows; `NULL` for purely practice-shaped rows like member.join).
  - Render a new "Client" column in the audit table; show the client name when present, "—" otherwise.
- This requires a schema migration to extend `list_practice_audit` to thread `client_id` and the derived practitioner actor for `plan.opened`.

---

## Test bundle

`docs/test-scripts/2026-04-29-wave40-bundle.html` (date approximate). Sections:
- **A · Mobile Camera** — items per M1–M6 (~7 items)
- **B · Portal hygiene** — items per P1–P8 (~9 items)
- **C · Settings + audit** — items per S1–S2 (~5 items)

Author the bundle as part of the Wave 40 implementation; promote to slot 1 in `docs/test-scripts/index.html` and demote Wave 39.4.

---

## Deferred to Wave 40+ or 41

- Wave 39.3 (Dart UTC timestamps + per-viewer-TZ portal rendering) — already in [BACKLOG.md](BACKLOG.md). Could fold into Wave 40 if scope allows; otherwise standalone.
- Camera multi-import: peek-box animation per imported photo (sketched in M2; refine if the queue-batching ergonomics need work).

---

## Implementation order

When Wave 39.4 has merged:
1. Mobile camera + toolbar (M1–M6) — single agent, single worktree. Mockup at [docs/design/mockups/wave40-camera-layout.html](design/mockups/wave40-camera-layout.html).
2. Portal hygiene (P1–P8) — separate agent, separate worktree (no file overlap with mobile).
3. Settings + audit (S1–S2) — last; Settings is mobile-only, audit columns touch portal.

Mobile and portal agents can run in parallel after Wave 39.4 lands.
