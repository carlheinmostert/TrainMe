# Safe Mode v2 video — face-recognition discriminator for videos (2026-05-25)

**Branch (Dart):** `feat/safe-mode-v2-video-dart` off `staging`.
**Branch (native):** `feat/safe-mode-v2-video-native` off `staging` (parallel agent).
**Surface:** Mobile capture + Studio (iOS only).
**Build verification:** Settings → About surfaces the short git SHA; the staging-tip SHA after both branches merge should match.

This wave extends Safe Mode v2 (face-recognition discriminator) from
photos to videos via a hybrid first-frame-identify + Vision tracker
+ sparse re-confirm pipeline. The v1 video largest-bbox heuristic is
removed in the same wave; every Safe Mode video capture now runs
through `applySafeModeV2ToVideo`. The Studio exercise card grows a
determinate coral progress bar during conversion so the practitioner
sees real progress instead of an indeterminate spinner.

Spec: `docs/specs/2026-05-25-safe-mode-v2-video.md`.
Companion specs to read for context:
- `docs/specs/2026-05-23-safe-mode-face-rec.md` (v2 photo algorithm)
- `docs/specs/2026-05-25-safe-mode-accept-zero-detection.md` (unified fail-closed rule)

## Table of contents

- [Prerequisites](#prerequisites)
- [A. Solo subject + bystander scenarios](#a-solo-subject--bystander-scenarios)
- [B. Subject continuity edge cases](#b-subject-continuity-edge-cases)
- [C. Fail-closed semantics](#c-fail-closed-semantics)
- [D. Performance + progress UX](#d-performance--progress-ux)
- [E. Algorithm version stamp + back-compat](#e-algorithm-version-stamp--back-compat)

## Prerequisites

- Both `feat/safe-mode-v2-video-dart` AND `feat/safe-mode-v2-video-native`
  merged to staging (this script is QA-blocked until both companion PRs land).
- Staging build installed on Carl's iPhone CHM via `./install-device.sh staging`.
- A staging client with at least 5 enrolled face references via the
  multi-reference enrolment screen (Settings → Clients → tap client →
  Set face → run the Face-ID-style sweep). The bound client for the
  test session must have a populated embedding slot bundle.
- A staging premises with an enforcing polygon covering Carl's
  current location so Safe Mode auto-activates on capture.
- Optional helper for items 2–4: a second person in frame for the
  bystander scenarios (Carl + one accomplice).

## A. Solo subject + bystander scenarios

- [ ] 1. **Solo subject video, no bystanders, inside enforcing polygon.** Open the bound client's sessions screen → new session → Camera. Confirm the coral Safe Mode banner shows at the top of the viewfinder and the v2 gate banner reads "ready" (no "Set face for Safe Mode" or "Preparing"). Long-press shutter for 15 seconds with just the practitioner in frame. Result: capture lands; conversion runs; the Studio card shows the determinate coral progress bar advancing; final safe variant plays back smoothly with the practitioner sharp throughout, no coral patches.
- [ ] 2. **Solo subject video with one bystander walking past.** Same setup. Practitioner kneels in centre frame; accomplice walks across the frame at the same approximate depth as the subject. Record 10 seconds. Result: practitioner stays sharp throughout the conversion output; bystander is painted coral the entire time they are in frame, with no flicker at the moment they enter or leave.
- [ ] 3. **Solo subject video with bystander closer to camera than subject.** Set up the phone on a bench so the practitioner is filmed at ~2m. Accomplice walks within 1m of the camera for ~3 seconds (passes between phone and practitioner). Record 10 seconds. Result: practitioner stays sharp (face-rec wins over v1's bbox-largest heuristic — this is THE regression v2 fixes); the closer-to-camera bystander is painted coral for the duration of their pass.
- [ ] 4. **Subject crosses paths with bystander.** Practitioner walks left-to-right across frame; accomplice walks right-to-left; their silhouettes briefly overlap mid-frame. Record 8 seconds. Result: no "who is the subject" flicker at the crossover frame; practitioner stays sharp throughout, bystander painted coral throughout.

## B. Subject continuity edge cases

- [ ] 5. **No-subject mode kicks in for back-to-camera sections.** Practitioner starts the recording front-to-camera (face visible), turns around for 4–5 seconds (back to camera), then turns back. Record 12 seconds total. Result: front sections produce subject-identified output (practitioner sharp); back-turned section produces no-subject output (no faces blurred because no faces detected; silhouette stays sharp); face-rec re-attempts within ~2 seconds of turning back around re-identify the subject without visible artifact.
- [ ] 6. **First-frame fail recovers within 2 seconds.** Start the recording with the practitioner's back to the camera. Hold for 4 seconds, then turn around and continue for 8 more seconds. Result: first 4 seconds run in no-subject mode (silhouettes sharp because no faces were detected); tracker seeds at the next M-cadence re-attempt after the subject turns around; remainder of video runs in subject-identified mode (practitioner sharp, hypothetical bystanders blurred).
- [ ] 7. **Tracker loss recovers immediately.** Practitioner records, then walks fully behind a piece of equipment (e.g. a Bosu ball held by accomplice, or a doorframe) for ~1 second, then emerges and continues. Result: occluded frames render in no-subject mode briefly; subject is re-identified on emergence with no visible re-identification artifact in the safe variant.

## C. Fail-closed semantics

- [ ] 8. **Empty room video inside enforcing polygon.** Point the phone at a wall with no humans in frame. Record 10 seconds. Result: native pipeline reports 100% miss rate, conversion is accepted as no-PII per the unified zero-detection rule, no safe variant is produced, audit event `safe_mode.accepted_empty` lands on the portal feed (https://manage.homefit.studio/audit). Exercise row is present in Studio (a regular, non-safe-mode video plays back). No orphan card.
- [ ] 9. **Heavily backlit video — intermittent face detection failure.** Record practitioner facing a bright window (sunlight or strong lamp behind them). Aim for poor face contrast so Vision intermittently loses detection across 10–80% of frames. Record 10 seconds. Result: middle-band miss rate, capture is rejected with the "couldn't track everyone — try a different angle" coral toast, NO orphan exercise card in Studio (orphan-fix from the zero-detection spec must still hold for video), conversion error log under the "N failed" pill shows a `SafeModeRejection` entry with `reason=missRateExceeded`.

## D. Performance + progress UX

- [ ] 10. **30-second video conversion time on iPhone 13 or newer.** Capture a 30-second clip with one or two faces visible throughout (Carl + optional accomplice in steady frame). When the conversion lands, observe the elapsed time printed in `conversion_error.log` (long-press the "N failed" pill if needed) OR check the Studio card's wall-clock disappear time. Assert conversion completes in ≤ 60 seconds wall-clock (2x real-time ceiling per spec section 6f). Typical solo-subject capture on iPhone 15 class hardware should hit closer to 1.2x–1.5x.
- [ ] 11. **Determinate coral progress bar visible during conversion.** While item 10 is converting, observe the exercise card on Studio. Assert a determinate coral progress bar appears at the bottom edge of the thumbnail (NOT the legacy indeterminate spinner). The bar should advance smoothly (not jumpy, not stuck) and reach 100% before the card flips to the converted state. Coral matches `AppColors.primary` / `#FF6B35`.
- [ ] 12. **Parallel captures show isolated progress.** Trigger two Safe Mode video captures in quick succession (long-press shutter, release, long-press again before the first conversion finishes). Both cards should appear in Studio with their own progress bars. The progress on card A must NOT bleed into card B and vice versa — the `_SafeModeV2VideoProgressOverlay` widget filters by `exerciseId` so each bar tracks its own conversion only.

## E. Algorithm version stamp + back-compat

- [ ] 13. **Algorithm version stamp + v1-video display + re-process affordance.** After items 1–6 are captured and published, check the cloud `exercises` table for `safe_mode_algorithm_version = 3` on those rows (via the portal audit feed or a Supabase staging query — `select id, safe_mode_algorithm_version, safe_mode_active from exercises where safe_mode_active = true order by created_at desc limit 10`). Item 8 (accepted empty) should also stamp 3 even though no safe variant was produced. Then: open Studio for any session that contains a v1-stamped video capture (if any exist from earlier staging activity — captures with `safe_mode_algorithm_version` 1 or 2 or NULL while `safe_mode_active = true`). The card must still display the previously-stored safe variant on every surface (Studio card, editor sheet, web player after publish). Long-press the v1 card and tap "Re-process Safe Mode" if the affordance exists for videos — v2 should re-run against the raw archive (if still within 90-day retention) and the stamp should bump to 3 on next publish. NOTE: the "Re-process Safe Mode" video affordance is out of scope for the Dart-side wave; if the option does not appear on the long-press menu for videos yet, mark this sub-test "deferred" and continue. The main assertion is that v1-stamped variants continue to play back untouched, with no privacy regression.
