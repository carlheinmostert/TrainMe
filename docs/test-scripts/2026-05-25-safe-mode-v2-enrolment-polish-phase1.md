# Safe Mode v2 — enrolment polish Phase 1 (2026-05-25)

**Branch:** `feat/safe-mode-v2-enrolment-polish-phase1` off `staging`.
**Build:** profile mode, installed on iPhone CHM via `homefit-install-device` when the PR is unblocked. PR is **draft / `[QA-blocked]`** until Carl unblocks for QA.
**Bundle:** `studio.homefit.app.dev` (staging build).

Phase 1 of the enrolment polish wave (spec `docs/specs/2026-05-25-safe-mode-v2-enrolment-polish.md`). Six concerns shipped:

1. Camera flip toggle on the enrolment screen (top-right of viewfinder, sticky pref).
2. Consent-aware mode resolution (the 4-cell matrix from spec section 3).
3. Avatar-tap intercept consent gating — both consents off now shows a single SnackBar.
4. avatarOnly simple-shot capture path (no sweep, no embedding).
5. Consent sheet restructure — Safe Mode section header dropped; face-rec row moved into Profile group on both mobile + portal.
6. Test scaffolding for mode resolution (unit tests on the resolver only — pose/quality tests are Phase 2).

Phase 2 (real-time pose gating, quality scoring, manual avatar grid) is a separate PR after mockup signoff.

## Table of contents

- [Prerequisites](#prerequisites)
- [A. Consent sheet restructure](#a-consent-sheet-restructure)
- [B. Camera flip toggle](#b-camera-flip-toggle)
- [C. Consent matrix — all four cells](#c-consent-matrix--all-four-cells)
- [D. avatarOnly simple-shot capture](#d-avataronly-simple-shot-capture)
- [E. R-10 portal parity](#e-r-10-portal-parity)

## Prerequisites

- One test client on staging you can flip consents on without losing real data. The QA test practice (`qa@homefit.studio`) has 8 credits seeded — fine for capture but not used here. Pick any throwaway client.
- Both surfaces side-by-side: iPhone with the staging build + Safari open to `https://manage.homefit.studio` signed in to the same practice.

## A. Consent sheet restructure

- [ ] 1. Open the client detail screen on the iPhone. Tap the consent chip to open the bottom sheet. Confirm the section headers are now: **Video treatment** → **Profile** → **Analytics** (no separate "Safe Mode" header anywhere).
- [ ] 2. The Profile section contains two rows in this order: **Avatar still** (top), **Face recognition for Safe Mode** (below). A thin divider sits between them — same visual treatment as the dividers inside the Video treatment group.
- [ ] 3. Toggle Face recognition for Safe Mode on then off. Save. Re-open the sheet — the toggle's current state is reflected (the existing `set_client_safe_mode_consent` RPC still wires correctly through the new layout).

## B. Camera flip toggle

- [ ] 4. With **both consents on**, tap the client's avatar → enrolment screen opens. Top-right of the viewfinder, you should see a circular icon button (`cameraswitch_outlined`) on a dark raised surface. By default this opens with the **rear** camera (no coral border around the icon).
- [ ] 5. Tap the flip toggle. Camera tears down and re-initialises in selfie mode within ~1.5s. A coral hairline border now surrounds the toggle (visual cue that the practitioner-facing direction is active).
- [ ] 6. Cancel out of the enrolment screen (close chip top-left). Re-tap the avatar to re-open it. The selfie default persists — sticky pref retained. Tap to flip back to rear; cancel; re-open; rear sticks.
- [ ] 7. Start a sweep and try to tap the flip toggle mid-sweep. Expected: no flip; the toggle's tap is silently ignored (mid-sweep flips would corrupt the pose-uniqueness pick).

## C. Consent matrix — all four cells

For each row of the matrix, flip the consents on the test client, save the sheet, then tap the avatar glyph to observe the routing.

- [ ] 8. **Both consents ON** (`avatar=true`, `safe_mode_face_recognition=true`) → tap avatar → enrolment screen opens in full mode, sweep auto-starts after ~350ms. (Existing Wave-D behaviour — no regression.)
- [ ] 9. **Face-rec ON, avatar OFF** (`avatar=false`, `safe_mode_face_recognition=true`) → tap avatar → enrolment screen opens, sweep auto-starts. Complete the sweep and tap Done on the confirm screen. After "Saving…" the screen pops. The avatar slot remains empty (no avatar JPG persisted). The face embedding still got stored — confirm with the SQL from script `2026-05-24-safe-mode-multi-ref-enrolment.md` item 5 (slot count between 3–8).
- [ ] 10. **Face-rec OFF, avatar ON** (`avatar=true`, `safe_mode_face_recognition=false`) → tap avatar → enrolment screen opens in **simple-shot mode**: NO coral sweep ring, NO instruction text, a single big coral shutter button bottom-centred + a small title strip "Tap the shutter to capture {name}'s avatar". Single tap → brief "Saving…" → screen pops. Avatar slot now shows the captured frame. No `client_face_embeddings` row was created — verify with:
  ```sql
  SELECT count(*) FROM client_face_embeddings WHERE client_id = '<client_id>';
  ```
  Expected: 0 (or unchanged from before).
- [ ] 11. **Both consents OFF** → tap avatar → editor does NOT open. A coral-bordered SnackBar appears: "Toggle face recognition or avatar consent first." with an `Open consent` action. Tap the action; the consent bottom sheet opens with the Avatar row visually highlighted.

## D. avatarOnly simple-shot capture

- [ ] 12. From the avatarOnly mode (item 10 setup), test the camera flip. Toggle is functional in simple-shot mode too. Default direction sticky pref applies (rear unless the heuristic triggered selfie on first open).
- [ ] 13. From the avatarOnly mode, tap the close chip top-left BEFORE pressing the shutter. Screen pops cleanly with no persist. The avatar slot stays in whatever state it was.
- [ ] 14. From the avatarOnly mode, tap the shutter rapidly twice in a row. Only one capture is processed (the shutter visibly enters its in-flight spinner state, blocking the second tap). No duplicate-write or double-pop.

## E. R-10 portal parity

- [ ] 15. Open `https://manage.homefit.studio/clients/<the test client id>` in Safari. Expand the **Client consent** accordion. The Profile section contains: **Avatar still** AND **Face recognition for Safe Mode** as two rows. The header chip shows `{granted}/5 granted` (not `/4` — the safe-mode flag counts now).
- [ ] 16. Toggle the portal's Face recognition row. The Save button enables. Click Save — toast reads "Saved." Refresh the page; the toggle remembers its new state.
- [ ] 17. Toggle the portal's Face recognition OFF (with an enrolled client). Save. The server-side `set_client_safe_mode_consent` RPC zeros the embedding and clears slot rows. Verify with:
  ```sql
  SELECT face_embedding, (SELECT count(*) FROM client_face_embeddings WHERE client_id = c.id) AS slots
  FROM clients c WHERE id = '<client_id>';
  ```
  Expected: `face_embedding IS NULL`, `slots = 0`.
- [ ] 18. Flip the same toggle on the iPhone consent sheet. Save. Refresh the portal — the portal's toggle reflects the iPhone's new value (cross-surface read-through works).
