# Safe Mode v2 — photo colorspace + reprocess affordance device QA (2026-05-25)

**Branch:** `staging` tip after PRs #482 + #485 merged.
**Build:** profile mode, SHA `277e839`, installed on iPhone CHM via `homefit-install-device` skill.
**Bundle:** `studio.homefit.app.dev`.

Wave covers two stacked fixes for the dark-Safe-Mode-photo bug surfaced during this morning's QA:

- **PR #482** — the Safe Mode photo render call now passes an explicit sRGB output colorspace to CoreImage instead of `nil`. Pre-fix CI was emitting linear-light bytes that the JPG encoder mis-interpreted as gamma-encoded sRGB, dropping mean brightness ~33% across the whole frame. Bench evidence post-fix shows brightness within ±0.4% of source on all three channels and a sharpness ratio of 1.02 (basically identical to source — confirms the compositor isn't accidentally blurring the entire image, which was the sev1 that PR #475 introduced).
- **PR #485** — `kSafeModeAlgorithmVersion` bumped from 2 to 3. Surfaces a "Re-process Safe Mode" row in the editor sheet's Settings tab on every existing v2-captured photo. Lets you regenerate old dark captures through the corrected pipeline without re-recording.

The bench HTML report from the fix iteration lives at `/tmp/safe-mode-bench-iter-1.html` for visual reference.

What did NOT change: video Safe Mode path (different code), capture-time flow gating (colorspace fix applies automatically the moment the build is on the phone), multi-reference enrolment (Wave-D items from 2026-05-24 are unaffected and remain valid).

## Table of contents

- [Prerequisites](#prerequisites)
- [A. New photo capture — bright + bystander-only blur](#a-new-photo-capture--bright--bystander-only-blur)
- [B. Existing dark photo — re-process affordance](#b-existing-dark-photo--re-process-affordance)
- [C. Republish round-trip](#c-republish-round-trip)
- [D. Regression guard — no whole-frame blur](#d-regression-guard--no-whole-frame-blur)

## Prerequisites

You should already be signed in to the staging "test" client (`9453d8ed-…`) with a multi-reference enrolment on file. If the app lands on Sign-In, sign in with the staging creds from `.env.test`. You'll need at least one dark Safe Mode photo captured before this build is installed — there should already be a handful from this morning's QA.

## A. New photo capture — bright + bystander-only blur

- [ ] 1. Open the Clients screen. Tap into the "test" client. Tap into a session → Camera mode.
- [ ] 2. Top of the viewfinder still shows the coral Safe Mode banner (geofence enforcement active).
- [ ] 3. Capture a photo with you AND another person in frame. Pre-fix this would render very dark and possibly with the whole frame blurred. Post-fix the safe variant should look like a normal exposure with ONLY the bystander's face / head region softened.
- [ ] 4. Tap into the new exercise. Editor sheet → Preview tab. The displayed photo should be visibly bright (not the dim mud you saw earlier today) and your face / body should be sharp.
- [ ] 5. Swipe to the Settings tab. The "Re-process Safe Mode" row should NOT be present (the photo was captured at version 3 already, so the gate `3 < 3` evaluates false).
- [ ] 6. Capture a solo selfie. Verify it's also bright + sharp (no bystanders → zero blur regions painted).

## B. Existing dark photo — re-process affordance

- [ ] 7. Navigate to any existing Safe Mode photo captured before this build — the dark ones from this morning's QA wave.
- [ ] 8. Open the editor sheet → Settings tab. A "Re-process Safe Mode" row should now appear at the bottom of the tab. (Pre-#485 it was hidden because the version gate `2 < 2` evaluated false.)
- [ ] 9. Tap the row. A SnackBar should confirm "Safe Mode re-processed." within a couple of seconds.
- [ ] 10. Close and re-open the editor sheet. The Hero thumbnail in the header should now show the re-processed bright version, not the original dark one. The "Re-process Safe Mode" row should be gone (the photo's stored version is now 3 = current, so the gate `3 < 3` again evaluates false).
- [ ] 11. Repeat on two more old dark photos. Confirm none of them produce a whole-frame-blurred output.

## C. Republish round-trip

- [ ] 12. Pick a published session that has re-processed photos. Open Studio → workflow pill → Publish. The publish should succeed as a republish (no credit consumed — metadata-only republish).
- [ ] 13. Open the client web player URL on Safari (camera roll or audit feed). The re-processed photo's hero should display the bright safe variant, not the dark one.
- [ ] 14. (Optional) Open the web portal's audit feed at `manage.homefit.studio/audit` — the republish event should appear with the practice as actor.

## D. Regression guard — no whole-frame blur

- [ ] 15. Pick the most "complex" photo you have (multiple people, busy background, mixed lighting). After capture or re-process, confirm that NON-bystander regions stay crisp — windows, walls, furniture, painting frames, your own face. If everything is blurred, that's the sev1 from PR #475 reappearing and we abort.
