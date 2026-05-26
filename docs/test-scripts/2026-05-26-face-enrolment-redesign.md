# Face enrolment redesign — M30 explicit prompts + M31 state machine (2026-05-26)

**Branch:** `feat/face-enrolment-redesign` off `staging`.
**Targets:** `staging`.

## Context

Carl's stack items M30 + M31 from the 2026-05-25 enrolment run:

- **M31 (sev1):** the enrolment screen rendered the initial "Look at the camera to begin" prompt UNDERNEATH the "Not enough variety captured" failure overlay (both visible at once) AND the close X button silently no-oped, trapping the user on the failed screen.
- **M30:** the silent autostart-and-let-the-user-figure-it-out flow gave practitioners no clue they had to move their head through six discrete angles. With everyone defaulting to "stare straight ahead", every quality-passed frame landed in the front bucket and pose-uniqueness rejected the rest → 0 of 6 captured + the M31 dead-end.

This wave replaces the silent flow with six explicit prompts (one per pose) and gives every state — including failed — its own clean render path with working CTAs.

Applies to BOTH paths today (per-client avatar enrolment) AND the future Self-trainer self-face enrolment from M22 — the screen widget is shared so the new flow benefits both surfaces.

## Setup

1. `git fetch origin && git checkout feat/face-enrolment-redesign`
2. Install on phone via the install pathway Carl approves.
3. Sign in. Pick (or create) a client with both Avatar consent AND Safe Mode face-recognition consent ON.

## Test items

### Prompt flow (M30)

- [ ] 1. Tap the client's avatar circle (or the "Set face" CTA on the capture screen) to open the enrolment screen. The header should show the close X chip top-left, the camera-flip toggle top-right, and a "Step 1 of 6" pill between them. The dashed face guide circle and the 6-segment guidance ring appear over the camera preview.

- [ ] 2. The first prompt copy below the ring reads **"Look straight ahead"** (Montserrat 19pt, bold). Above the ring centre sits a coral circular icon with a centred crosshair glyph (the direction hint for straight-ahead). Six small progress dots beneath the prompt show the current step coral-outlined and the rest faded.

- [ ] 3. Look straight at the camera. Within ~1-2 seconds the screen advances to step 2: **"Turn slowly to your right"** with a rightward arrow icon. The first dot fills coral; the second is outlined; the rest stay faded. The "Step" counter shows "Step 2 of 6".

- [ ] 4. Turn slowly to your right. When your face yaw passes ~30 degrees the screen advances to step 3: **"Turn slowly to your left"** with a leftward arrow.

- [ ] 5. Continue through steps 4 ("Tilt head up slightly", upward arrow), 5 ("Tilt head down slightly", downward arrow), and 6 ("Look straight ahead with a slight smile", smile-face icon).

- [ ] 6. After step 6 accepts, the screen transitions to either the avatar-selection grid (full consent mode) or the saving spinner (embedding-only mode). Confirm the enrolment lands — the avatar/embedding writes succeed and you return to client detail.

### Stall handling (M30)

- [ ] 7. Re-open the enrolment screen. Look straight at the camera (this should accept step 1 quickly). On step 2 ("Turn slowly to your right"), DON'T move. After ~5 seconds, an amber hint copy appears below the prompt: **"Turn a little further to the right"** (Inter 13pt, warning amber).

- [ ] 8. Keep holding still on step 2. After ~15 seconds total, a coral-bordered **"Skip this pose"** chip appears bottom-centre. Tap it — the screen advances to step 3 without capturing a frame for step 2. The "Step 3 of 6" pill updates immediately.

### Failed state + close button (M31)

- [ ] 9. Re-open the enrolment screen. Cover the camera with your hand so the face detector never sees a face. Wait through all six prompts skipping each via the chip when it appears, OR wait for the 180-second sweep timeout. The screen transitions to the **Failed view**.

- [ ] 10. The Failed view shows: coral close X chip top-left, a 64pt error-icon circle (rose), heading **"Couldn't capture enough variety"** (Montserrat 20pt bold), a body explanation, a coral **"Try again"** button full-width, and an outlined **"Close"** button full-width below. The initial "Look at the camera" prompt and the slot counter are gone — single render path, no overlap with the sweep view.

- [ ] 11. Tap the **close X chip** top-left of the Failed view. The screen pops back to client detail immediately. (Before this wave, the X did nothing — the M31 sev1.)

- [ ] 12. Re-trigger the Failed state. This time tap **"Try again"** at the bottom. The screen resets: prompt sequence starts at step 1 again with the initial "Look straight ahead" copy, ring is empty, all dots are reset, and no error overlay remains.

- [ ] 13. From the Failed view, tap the **"Close"** outlined button at the bottom. The screen pops back identically to the X chip.

### Close button works in EVERY state (M31)

- [ ] 14. Re-open enrolment. Mid-prompt (any step 1-6 active), tap the close X top-left. Screen pops back to client detail within ~1 second. (Before this wave the X relied on a service state transition that didn't always fire.)

- [ ] 15. Re-open enrolment. Wait until you've captured 4-6 angles and the avatar grid view appears. Tap the close X top-left. Screen pops back — nothing persists; the in-flight enrolment is discarded.

## Notes

- The pose-acceptance tolerance per prompt is ±20 degrees (Manhattan-sum) from the bucket centre. Quality threshold (composite 60) still applies — a low-light blurry frame won't auto-accept even at the right angle.
- The legacy "Done · 3 of 6" early-finish chip from Wave-D Phase 2 is retired — practitioners now skip per-prompt, which is the more discoverable interaction.
- The legacy rose-tinted reject toast that showed raw quality scores is also retired in favour of the per-prompt amber soft hints.

## What to report

For each item: **N pass** or **N fail — short note**. Stack any new bugs into `docs/test-scripts/YYYY-MM-DD-stack.md` rather than appending here.
