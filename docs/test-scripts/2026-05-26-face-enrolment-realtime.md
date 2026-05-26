# Face enrolment — real-time AVCaptureMetadataOutput tracking (2026-05-26)

Device QA for M37 (architectural fix that subsumes M32 + supersedes M35).

**Branch:** `feat/face-enrolment-realtime-tracking` → `staging`.
**What changed (summary):** Replaced the still-image `VNDetectFaceLandmarksRequest` pose path with a real-time `AVCaptureMetadataOutput` face-tracking stream. New native `FaceEnrolmentCameraChannel` + new Dart `FaceEnrolmentCamera` service. Frames are now grabbed silently from the video-data-output buffer queue — no `capturePhoto()` shutter sound. Pose values come from the camera ISP (yaw + roll, ±45° in 9° increments, reliable on the selfie cam).

**Pitch limitation:** `AVMetadataFaceObject` gives yaw + roll but not pitch. The agent's choice for `kPromptSequence` should be documented in the PR body (option 1 / 2 / 3 per the brief). If pitch prompts were dropped, only yaw-based prompts will fire.

## A. Smoke

- [ ] 1. Settings → Public Profile → "Face recognition for Self-trainer" → tap **Set up** → enrolment screen opens with the selfie camera live.
- [ ] 2. The camera preview is **silent** — no shutter sound on any frame, even when the system captures one for the embedding.
- [ ] 3. The close (X) button in the top-left dismisses the screen in every state (idle, sweeping, failed). No stuck states.

## B. Prompt advance

- [ ] 4. Prompt 0 (`Look straight ahead`) fires immediately on face detection. Looking at the camera causes the dot to fill coral + a haptic + advance to prompt 1.
- [ ] 5. Prompt 1 fires; turn your head per the instruction. **Haptic** confirms acceptance + advances to prompt 2.
- [ ] 6. Continue through the full prompt sequence. Each accept fires a haptic so you know to look back at the screen.
- [ ] 7. Final prompt accepts → screen advances to a "success" state → embeddings save via `register_self_face` → screen dismisses.

## C. Pose stream + match

- [ ] 8. While inside the enrolment screen, the pose values reported in the diagnostic HUD (if enabled in Settings → Diagnostics → Show Safe Mode hint overlay) change as you move your head. Yaw goes positive when you turn right; roll is reported.
- [ ] 9. When pose matches the prompt target + quality threshold passes, the frame is silently captured (no shutter sound) and the dot fills.

## D. Failure paths

- [ ] 10. Cover the camera lens with your palm → no face detected → no advance, no error. Uncover → resumes.
- [ ] 11. If you stall on a prompt for ~5 s, a soft hint appears under the prompt text (`Hold steadier`, `Try turning a little further`, etc).
- [ ] 12. If the entire sweep fails (e.g. you cancel mid-way or the camera errors), the failed state offers a `Try again` CTA + the close button works.

## E. Side effects + parity

- [ ] 13. After successful enrolment, Settings → Public Profile shows `Enrolled · N reference frames · Re-enrol` instead of the `Set up` CTA.
- [ ] 14. The same per-client enrolment flow (open a client → consent sheet → Set face) ALSO uses the new real-time tracking — no regression. Selfie cam toggle works the same way.
- [ ] 15. `dart_analyze` and CI pass (verified locally during salvage — `flutter analyze` clean on touched files).
