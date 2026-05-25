# Test script — Self-trainer wave PR #5 (capture-time self-verification)

**Branch:** `feat/self-verification-capture` → `staging`
**Date:** 2026-05-25
**Surface:** Mobile only (no R-10 web parity — the flag round-trips
through `replace_plan_exercises` but no visible web change in this PR)
**Spec:** `docs/sub-agent-briefs/05-self-verification-capture.md`,
`docs/SELF_TRAINER_WAVE.md` § "Capture-entry path from My Workouts" § 5

Verifies that the conversion pipeline stamps `exercises.self_verified`
correctly per the brief's tri-state contract: NULL when no reference
embedding is registered, `true` when MobileFaceNet matches the
practitioner's self-reference selfie, `false` when the subject differs
(or no face is detected, or the pipeline throws).

Each item runs against the STAGING Supabase project
(`vadjvkmldtoeyspyoqbx`). The test account is `qa@homefit.studio` —
see `.env.test`. Direct DB checks use the staging service role key.

Prerequisites: PR #3 (face embedding native + `register_self_face` RPC)
is merged. The QA account has either run `register_self_face` (for the
positive-path tests 1-2) or has been reset to `face_embedding = NULL`
(for the no-reference test 4). Use the cleanup block at the end of
`docs/test-scripts/2026-05-25-self-face-embedding.md` to flip between
states.

---

## Tests

- [ ] **1. Self-capture (registered): stamps `self_verified = true` within 5s of conversion done.**
  As QA user with a registered self-face embedding (run PR #3 test 3
  first), capture a fresh video / photo OF YOURSELF via the app's
  capture flow. Watch the Studio card transition from "converting" to
  "done". Within 5 seconds of the converting indicator clearing,
  Console.app under category `self.face_embedding` should log
  `verify: N sample(s) → sim=0.7xxx matched=true`. Direct DB check
  (Supabase SQL editor, after publishing the session so the row hits
  cloud — local-only test alternative below):
  ```sql
  SELECT id, self_verified
  FROM exercises
  WHERE plan_id = '<your test plan id>'
  ORDER BY position;
  ```
  Expect: every freshly-captured exercise's `self_verified = true`.
  Local-only alternative (no publish needed): run
  ```sh
  sqlite3 ~/Library/Developer/CoreSimulator/Devices/<sim-uuid>/data/Containers/Data/Application/<app-uuid>/Documents/raidme.db \
    "SELECT id, conversion_status, self_verified FROM exercises ORDER BY created_at DESC LIMIT 3"
  ```
  Expect: `self_verified = 1` for each self-captured exercise.

- [ ] **2. Capture of gym equipment (no face) stamps `self_verified = false`.**
  Same registered-self state as test 1. Capture a video / photo of an
  empty corner of the room (or any frame with zero detectable faces).
  After conversion completes, check the SQLite row as in test 1.
  Expect: `self_verified = 0` (not NULL — the pipeline ran but no face
  was found, which is conservative-false per the brief). Console.app
  should log `verify: no face detected in any sample of <path>`.

- [ ] **3. Capture of a different person stamps `self_verified = false`.**
  Same registered-self state. Capture a video / photo where the subject
  is NOT the practitioner (a friend, a YouTube playback on another
  screen, a printed photo of someone else). Expect: SQLite
  `self_verified = 0`. Console.app log should show
  `verify: N sample(s) → sim=0.xx matched=false` with a cosine
  similarity well below 0.5 (typically 0.15-0.40 for unrelated faces).

- [ ] **4. Capture before consent given stamps `self_verified = NULL`.**
  Reset the practitioner row to no embedding via the cleanup block in
  `docs/test-scripts/2026-05-25-self-face-embedding.md`. RESTART the
  app (the conversion service caches the fetched embedding for the
  session; the cache is invalidated only by an explicit reset call OR
  a fresh app launch). Capture a video / photo of yourself. After
  conversion completes, expect: SQLite `self_verified IS NULL`.
  Console.app log should show
  `self-verification: no practitioners.face_embedding registered —
  skipping (self_verified stays NULL)`.

- [ ] **5. Re-register with a different reference reflects in subsequent captures.**
  After test 1 (registered, captures stamp `self_verified = true`),
  call `register_self_face` again with the embedding of a DIFFERENT
  face (e.g. computed from a photo of a friend by feeding the friend's
  selfie through `FaceEmbeddingService.computeForImage`). Force-quit
  and relaunch the app (clears the in-memory cache). Capture a fresh
  video / photo of YOURSELF. Expect: SQLite `self_verified = 0` (the
  registered reference is now the friend's; the practitioner no longer
  matches). Re-register with the practitioner's selfie + relaunch +
  recapture → `self_verified = 1` again.

- [ ] **6. Cloud round-trip — publish carries the flag through `replace_plan_exercises`.**
  With a session containing exercises in mixed verification states
  (one matched, one no-face, one with `self_verified IS NULL` from the
  cleanup), publish the plan. After publish completes, check the cloud
  via the staging Supabase SQL editor:
  ```sql
  SELECT id, position, self_verified
  FROM exercises
  WHERE plan_id = '<your test plan id>'
  ORDER BY position;
  ```
  Expect: the three states round-trip exactly — `true`, `false`,
  `NULL`. This proves the migration's NULLIF + boolean cast preserves
  tri-state semantics through the JSON wire.

- [ ] **7. Verification failure NEVER blocks capture or publish.**
  Force a failure mode (e.g. point the camera at a static wall so no
  face is detected, OR temporarily revoke the practitioner's
  `practitioners.face_embedding` mid-capture to simulate an RPC
  failure on the lazy fetch). Capture + publish should both still
  succeed end-to-end. The Studio card should never show a verification
  error to the user; only the `self_verified` flag differs. This is
  the brief's acceptance criterion 4: "No capture blocking —
  verification failure does NOT block capture".

- [ ] **8. Safe Mode capture sources the safe variant for verification.**
  With Safe Mode active (inside an enforcing premises polygon),
  capture a video / photo of yourself. Expect: the verification
  pipeline runs against `exercises.safe_raw_file_path` (the coral-
  painted safe variant) and NOT the original raw bytes. Console.app
  log should show the verification path begins with
  `{Documents}/.../<exerciseId>_safe.mp4` (or `_safe.jpg`). This
  enforces `feedback_no_original_display_safe_mode`: even on the
  verification path, the original is never read by anything that could
  leak it.

---

## Cleanup

After the suite, the QA account has captured several test exercises
under a real Self-client. The cleanup is the same as the existing
test-script index pattern — delete the test plan from the app's UI
(soft-delete + 7-day recycle bin), then optionally hard-delete from
cloud if you want to fully reset:

```sql
-- As service role (staging only).
DELETE FROM plans
 WHERE client_id = (
   SELECT id FROM clients
    WHERE user_id = '<qa-user-id>' AND name = 'Me'
 );
```

The Self-client row + registered face embedding should NOT be reset
between tests 1-3 (they all share the same registered-self state). Use
the cleanup block in `2026-05-25-self-face-embedding.md` only when you
need to retest the NULL-reference branch (test 4).
