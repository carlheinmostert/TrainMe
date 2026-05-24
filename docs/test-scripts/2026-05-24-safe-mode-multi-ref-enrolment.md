# Safe Mode v2 — multi-reference enrolment + finishing wave (Wave-E) (2026-05-24)

**Branch:** `staging` tip after PRs #475 + #477 + #478 + #479 + Wave-E merged.
**Build:** profile mode, installed on iPhone CHM via `homefit-install-device` skill.
**Bundle:** `studio.homefit.app.dev` (staging build).

This wave closes the entry-point gap on the multi-reference enrolment flow:

- "Improve face recognition" nudge chip on client detail for legacy single-slot clients (the rows backfilled by the Wave-A `client_face_embeddings` migration).
- Capture-screen "Set face" CTA now routes through `FaceEnrolmentScreen` (Face-ID-style rotating-head sweep) instead of the old single-shot avatar capture screen, which has been deleted.
- Verification of the round-trip on a real device.

## Table of contents

- [Prerequisites](#prerequisites)
- [A. Enrolment — empty avatar slot](#a-enrolment--empty-avatar-slot)
- [B. Consent gates](#b-consent-gates)
- [C. Re-enrolment — existing avatar](#c-re-enrolment--existing-avatar)
- [D. "Improve face recognition" nudge chip](#d-improve-face-recognition-nudge-chip)
- [E. Compose-time match](#e-compose-time-match)
- [F. Cancel paths](#f-cancel-paths)
- [G. Capture-screen entry point](#g-capture-screen-entry-point)

## Prerequisites

Set up the following state on staging (project `vadjvkmldtoeyspyoqbx`) before running:

- One client with **no avatar** and **no face embeddings** (for items in section A). If you don't have one, open Clients → New Client → name them something throwaway → leave the avatar empty.
- One client with **exactly one** face embedding row (legacy single-slot, for item 11 in section D). Find one via:
  ```sql
  SELECT id, name
  FROM clients
  WHERE id IN (
    SELECT client_id FROM client_face_embeddings
    GROUP BY client_id HAVING count(*) = 1
  );
  ```
  These are the rows backfilled by the Wave-A migration (`20260524_client_face_embeddings_backfill.sql`). There should be ~3 of them on staging.
- One client with `safe_mode_face_recognition` consent **OFF** (for item 3 in section B). Easiest: pick any client → tap consent chip → toggle Safe Mode face recognition off → close sheet.

## A. Enrolment — empty avatar slot

- [ ] 1. Open the app. Navigate to the client with no avatar set. Tap the avatar glyph in the top-left of the client detail screen. Expected: `FaceEnrolmentScreen` opens fullscreen. Front camera initialises within ~1.5s. Coral circle outline + arc progress ring visible. Instruction text reads "Slowly turn your head from left to right".
- [ ] 2. Complete a full sweep: yaw L→R over ~6 seconds (turn head), then look up→down over ~4 seconds. Arc ring fills clockwise as buckets accumulate. Instruction text transitions through phases: yaw → pitch → "Almost there". On completion the screen advances to the confirm step.
- [ ] 3. Confirm screen shows N thumbnail tiles in a row (expect 3–8). One tile has a coral border + caption "Most-frontal frame". Done button bottom-centred.
- [ ] 4. Tap Done. Brief "Saving…" spinner. Screen pops back to client detail. The avatar slot now shows the picked frontal frame from the sweep.
- [ ] 5. Run this SQL on staging (replace `<client_id>` with the test client's UUID):
  ```sql
  SELECT count(*) AS slot_count, max(slot_index) AS max_slot
  FROM client_face_embeddings WHERE client_id = '<client_id>';
  ```
  Expected: `slot_count` between 3 and 8 inclusive; `max_slot = slot_count - 1`.

## B. Consent gates

- [ ] 6. Open the client you set with `safe_mode_face_recognition = false`. Tap the avatar glyph. Expected: no enrolment screen. A coral-bordered SnackBar appears with text "Enable Safe Mode face recognition in Client consent first." and an `Open consent` action.
- [ ] 7. Tap the `Open consent` action on that SnackBar. Expected: the consent bottom sheet opens with the avatar row visually highlighted.

## C. Re-enrolment — existing avatar

- [ ] 8. Back on the client from section A (now has a multi-ref enrolment). Tap the avatar glyph. Expected: a bottom sheet appears titled "Replace avatar and re-enrol" with one coral button and a Cancel text button. No "Are you sure?" interstitial.
- [ ] 9. Tap the coral "Replace avatar and re-enrol" button. Expected: `FaceEnrolmentScreen` re-opens.
- [ ] 10. Complete the sweep + tap Done. Run the SQL from item 5 again. Expected: the slot count may differ from the previous enrolment but is still between 3 and 8; the previous rows have been replaced transactionally (no orphan slot rows above the new `max_slot`).

## D. "Improve face recognition" nudge chip

- [ ] 11. Open the legacy single-slot client you identified in the prerequisites. Expected on client detail: below the **Client consent** chip, a second coral-outline chip is visible labelled "Improve face recognition · re-enrol in 15 seconds".
- [ ] 12. Tap the "Improve face recognition" chip. Expected: the same R-01 bottom sheet from section C appears ("Replace avatar and re-enrol"). Tap the coral button → `FaceEnrolmentScreen` opens.
- [ ] 13. Complete the sweep + tap Done. Return to client detail. Expected: the "Improve face recognition" chip is **gone** (slot count is now ≥ 2). Re-run the SQL from item 5 to confirm.

## E. Compose-time match

- [ ] 14. From the same client (now multi-ref enrolled), enter a session and switch to Camera mode. Frame yourself frontally with a second person clearly visible behind you. Capture a Safe Mode photo. Expected on the Studio thumbnail: your face stays sharp; the second person's face polygon is obscured by the coral fill. Run this SQL on the freshest exercise row to confirm `safe_mode_active`:
  ```sql
  SELECT safe_mode_active, captured_in_premises_id
  FROM exercises ORDER BY created_at DESC LIMIT 1;
  ```
  Expected: `safe_mode_active = true`.
- [ ] 15. Repeat the capture but this time turn your head ~45° to the side (the IMG_1375 scenario — a pose that scored 0.25 cosSim against a single frontal reference). No bystanders. Expected: your face still renders sharp in the Studio thumbnail (one of the enrolled side-pose embeddings clears the discriminator threshold). If you see your own face blurred coral, the multi-reference match-time `max` rule is regressing — capture diagnostic logs from Console.app and flag.

## F. Cancel paths

- [ ] (Optional) During any sweep step, tap the X cancel chip top-left of the enrolment screen. Expected: camera releases, you pop back to client detail, no DB rows change, no avatar JPG is written.

## G. Capture-screen entry point

- [ ] (Optional) From a fresh client with no avatar, enter a session → Camera mode. Top of the viewfinder shows the Safe Mode v2 banner with the "Set face" CTA. Tap it. Expected: `FaceEnrolmentScreen` opens (NOT the old single-shot avatar screen). Complete a sweep + tap Done → the banner advances to `ready` and capture buttons unlock.

---

If any item fails: reply `N broken` with a short description. Stack feedback in `docs/test-scripts/2026-05-24-stack.md` per `feedback_stack_means_queue`; don't trigger fix agents per-item.
