# Test script — Self-trainer mobile + iOS hotfix B

**Branch:** `fix/self-trainer-mobile-hotfix` → `staging`
**Date:** 2026-05-25
**Surface:** Mobile (Flutter + iOS native) only.
**Scope:** Cleanup pass after the self-trainer wave PRs #502/#503/#504/#507/#508. 17 findings.

Each item maps to a single finding ID from the post-wave review. Items
1-2 are critical (visible-to-users); 3-8 are medium (behaviour drift /
small races); 9-12 are iOS-native quality + memory; 13-17 are lows
that fit into this PR.

---

## Tests

- [ ] **1. CA-2 — banner `[carl-review:]` markers gone from rendered UI.**
  Cold launch on a device where the `self_trainer_intro_dismissed`
  SharedPreferences key is absent (fresh install, or clear via debug
  diagnostics screen). Expect: the coral banner at the top of the
  Clients/My Workouts surface reads `My Workouts is live`, then
  `Capture yourself, get plans from your practitioner — all in one
  place.`, then `Got it`. NO `[carl-review:]` prefix anywhere in the
  banner. The bracket text MUST remain only in source-file COMMENTS
  (verify by grepping `[carl-review:]` in
  `app/lib/widgets/self_trainer_intro_banner.dart` — should show
  comments only).

- [ ] **2. CA-3 — `resetSelfFaceEmbeddingCache` wired into both
  consent-state-change sites.** Verify via grep:
  `grep -rn resetSelfFaceEmbeddingCache app/lib/` should report 3
  sites: definition in `conversion_service.dart` + caller in
  `self_face_consent_sheet.dart` (after `registerSelfFace` succeeds)
  + caller in `public_profile_screen.dart` (after `revokeSelfFace`
  succeeds). End-to-end: register face → immediately capture a video
  → expect `self_verified = true` in SQLite (not NULL — proves the
  cache was reset before the first capture re-fetched).

- [ ] **3. R2-M1 / M-9 — FAB owner-practice resolution matches
  `register_self_face`'s `joined_at ASC` tiebreak.** With QA account
  in 2+ practices (one owner, one non-owner), tap the My Workouts FAB
  to create a self-session. Expect: the resulting Self-client lives in
  the owner-practice (oldest joined_at). If you join a second owner
  practice later, the FAB still resolves to the FIRST one (oldest
  membership). Read `_resolveOwnerOrCurrentPracticeId` in
  `home_screen.dart` — should iterate the cached practices (already
  sorted by `joined_at ASC`) preferring owner role, then fallback to
  the oldest membership of any role.

- [ ] **4. R2-M2 / M-11 — bootstrap + FAB consent path race
  protected by shared mutex.** Set up: fresh user with avatar but no
  face consent. On Home cold launch, the bootstrap post-frame fires
  `SelfTrainerBootstrap.maybePromptForLazyBackfill` AND simultaneously
  tap the My Workouts FAB. Expect: only ONE consent sheet opens (the
  one that ran first); the second call returns early because
  `SelfTrainerBootstrap.consentPromptInFlight` is true. Repeat the
  race a few times — never two sheets stacked.

- [ ] **5. R2-M3 — `register_self_face` 23505 retry path.**
  Simulate the race: in two simulator instances signed in as the same
  account (or via two rapid `registerSelfFace` calls before either
  finishes), trigger concurrent consent flows. One call may hit
  PostgreSQL `23505 duplicate key` per the RPC's own comment. Expect:
  the Dart wrapper retries once internally and surfaces the resolved
  Self-client id to the caller. No `PostgrestException` leaks to UI.

- [ ] **6. R2-M4 / M-4 — `getMySelfFaceEmbedding` tri-state, retries
  on unknown.** Cut the network mid-capture. The first capture after
  net-loss should: log `[ConversionService] self-verification:
  get_my_self_face_embedding returned unknown state` and SKIP the
  verification step (NOT permanently mark "not registered"). Restore
  network; the NEXT capture re-fetches and stamps `self_verified`
  correctly. Compare to staging-tip behaviour where a single network
  flake permanently cached `null` for the rest of the session.

- [ ] **7. R2-M5 — `MyWorkoutsScreen` subscribes to conversion +
  removal streams.** Capture a video on a fresh self-session while
  My Workouts is the active scope (Clients → My Workouts toggle). Do
  NOT navigate away. Expect: the session card filmstrip thumbnail
  appears the moment conversion completes (no need to pull-to-refresh
  or navigate back). Trigger a Safe Mode rejection on a different
  capture; the orphaned spinner card disappears from the session
  immediately (subscribed to `onExerciseRemoved`).

- [ ] **8. R4-M3 — Settings reminder row for dismissed-but-not-consented
  users.** Setup: avatar present, NO consent, prompt-shown flag set
  (i.e. user dismissed the bootstrap prompt or the prompt fired but
  the user backed out). Open Settings → Public profile section.
  Expect: a coral-bordered row reading "Turn on face verification —
  self-captures publish free." appears immediately below the
  "Name + face photo" row. Tap it → consent sheet opens. Complete
  consent → the row disappears next time Settings re-loads. R-01:
  the reminder is inline, NOT a modal.

- [ ] **9. R5-M1 / M-5 — Dart `computeForImage` dim assertion.** Unit
  test: `cd app && flutter test test/services/face_embedding_service_test.dart`.
  Expect: all 4 tests pass (rejects 100-element response, accepts
  512-element response, returns null on native nil, constant equals
  512). Manually: tap any photo selfie path that returns a malformed
  embedding (no real-world repro — proven via the unit test). Also
  verify: `grep -rn 'kSelfFaceEmbeddingFloats' app/lib/` shows the
  constant defined in `safe_mode.dart` and used in
  `face_embedding_service.dart`.

- [ ] **10. R5-M2 / M-10 — verify-path memory spike on 4K video
  bounded.** Record a 4K (3840×2160) video on the iPhone (deliberately
  high-res — Settings → Camera → Record Video → 4K 30 fps). Trigger
  a Safe Mode verification on a self-session capture sourced from
  that video. Open Xcode Instruments → Allocations and watch peak
  memory during `extractEmbeddingsFromVideo`. Expect: peak under
  ~100 MB per frame (was ~120 MB pre-fix on the 4K source — the
  shrink-to-1920px helper now runs before Vision sees the frame).
  Read Console.app under category `self.face_embedding` to confirm
  the verify path ran without warnings.

- [ ] **11. R5-M3 — min face crop raised to 64×64.** Capture a video
  where the subject is far from the camera (e.g. full body across a
  living room). Trigger Safe Mode verification on it. Expect: the
  log under category `self.face_embedding` shows `embedLargestFace:
  rejecting NxN face crop (min 64)` where N < 64, AND the verify
  result reports `noFace: true`. Subjects close to the camera (>
  64 px wide face) should still verify normally.

- [ ] **12. R5-M4 — threshold named constant + dead-clamp collapsed.**
  Grep `app/ios/Runner/HomefitFaceEmbeddingChannel.swift` for
  `kSelfFaceSingleRefMatchThreshold` — should show one declaration
  + one usage (default arg to `threshold`). Grep for
  `max(0.05, min(0.20, 0.1))` — should return ZERO matches (was the
  dead inset clamp, collapsed to `let inset = 0.10`). Verify the
  comment near the constant explains the bench calibration target.

- [ ] **13. R2-L2 — race-protection regression test.** Unit test:
  `cd app && flutter test test/services/conversion_service_rejection_test.dart`.
  Expect: the new `stampSelfVerifiedForTest` test passes. Documents
  the contract that the self-verification stamping path re-reads
  SQLite immediately before persisting, so an intermediate write
  (e.g. raw-archive completion) on the same row isn't clobbered.

- [ ] **14. R2-L3 — FAB double-tap protected.** On the My Workouts
  surface, double-tap the New Session FAB rapidly. Expect: only ONE
  session minted, ONE consent sheet opened, ONE navigation push to
  `SessionShellScreen`. The button visibly disables (`onPressed:
  null`) while `_creatingSession` is true.

- [ ] **15. R5-L1 — `unpackFloats` rejects short blobs loudly.**
  Cannot trigger without a synthetic native bug, but verify: in a
  DEBUG build (`flutter build ios --debug --simulator`), modify
  `MobileFaceNetEmbedder.embed` temporarily to return a 1024-byte
  blob (half the expected 2048). Run any consent flow. Expect: the
  app crashes at the `assert(data.count == count * 4)` in
  `unpackFloats`. Restore the embedder; rebuild. (Release behaviour
  is documented: returns nil + Console.app warning rather than
  crash.)

- [ ] **16. R5-L2 — `cosineSimilarity` uses `vDSP_dotpr`.** Grep
  `app/ios/Runner/HomefitFaceEmbeddingChannel.swift` for
  `vDSP_dotpr` — should show ONE call (inside the verify path's
  private `cosineSimilarity` helper). Verify the `import Accelerate`
  line was added at the top of the file.

- [ ] **17. R5-L3 — test script for self-face embedding mentions the
  Dart unit test.** Open `docs/test-scripts/2026-05-25-self-face-embedding.md`
  in the preview pane. Item 7's "Dart-layer twin" paragraph should
  reference `app/test/services/face_embedding_service_test.dart` with
  the run command. Confirms the dim contract is checked at BOTH the
  RPC pgvector layer AND the Dart wrapper layer.

---

## Out-of-scope

Items NOT addressed in this PR (parked for future waves):
- Hotfix A (SQL signature changes from the same review) — landing
  in a parallel branch.
- Voice / wording pass on the banner copy — Carl does this separately.
