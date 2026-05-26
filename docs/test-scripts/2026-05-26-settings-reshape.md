## 2026-05-26 settings reshape + Self-face home + consent jsonb hygiene (PR `fix/settings-reshape-and-self-face-home`)

Three items from `docs/test-scripts/2026-05-25-stack.md` (mobile half):
M22 (Self-face enrolment home in Public Profile), M23 (Self-client jsonb
hygiene + lazy backfill), M25 (Diagnostics unification behind 7-tap gate).

Strike the number when the listed verification path passes.

## M25 — Diagnostics unification behind 7-tap easter egg

- [ ] **1.** Open Settings. Scroll to the `About` section. The `Diagnostics`
  row MUST NOT be visible — only the version row (`0.1.0 · {sha}`) shows.
  This inverts the previous behaviour where Diagnostics was permanently
  visible.

- [ ] **2.** Tap the version row 7 times in quick succession. A new
  `Diagnostics` row appears underneath with the subtitle `Live health
  probes, IDs, debug toggles.`. The inline `_DiagnosticsPanel` (User ID
  / Practice ID / Build SHA copy rows) from the previous build MUST NOT
  appear in Settings — those rows now live inside DiagnosticsScreen.

- [ ] **3.** Tap the `Diagnostics` row. The DiagnosticsScreen opens. The
  `Context` card now contains a `User ID` row at the top (in addition to
  Build SHA / Practice / Pending ops / Connectivity / Debug build). Tap
  the User ID row — a SnackBar reads `User ID copied`. Verify by pasting
  into a text field.

- [ ] **4.** Scroll the DiagnosticsScreen to the new `Debug toggles`
  section. It contains a single row labelled `Show Safe Mode hint
  overlay`. Tap it — the switch flips. Pull-to-refresh: the toggle
  state persists.

## M22 — Public Profile as the Self-face enrolment home

Pre-condition: signed in as a practitioner who has a saved avatar (e.g.
the QA test account) but no face_embedding yet. If face is already
enrolled, tap `Remove enrolment` first to reset.

- [ ] **5.** Open Settings → Public profile. Below the First / Last name
  fields, a `Face recognition for Self-trainer` section is visible (only
  when an avatar exists). Status text reads `Enrol your face for
  self-verification. 5-6 pose-gated frames, ~30 seconds. Lets the app
  confirm self-captures are you, which unlocks the free Publish path.`
  A `Set up` button is present in coral outline.

- [ ] **6.** Tap `Set up`. The FaceEnrolmentScreen opens IN SELFIE MODE
  (front camera). Without a manual flip, the practitioner sees themself
  immediately. Run through the 6-pose sweep. On Done, the screen pops
  back to Public Profile.

- [ ] **7.** After the sweep, a `Face recognition enrolled` SnackBar
  appears. The section now reads `Enrolled. Self-captures are confirmed
  as you, which unlocks the free Publish path.` with TWO buttons:
  `Re-enrol` (coral outline) and `Remove enrolment` (red text).

- [ ] **8.** Verify the Self-client cloud row now has
  `safe_mode_face_recognition: true` AND a non-null
  `practitioners.face_embedding_consented_at` AND a non-null
  `practitioners.face_embedding`. Carl can run this in the Supabase SQL
  editor (replace `<uid>`):
  ```sql
  SELECT c.video_consent->>'safe_mode_face_recognition' AS face_rec,
         p.face_embedding_consented_at IS NOT NULL AS consent_stamped,
         p.face_embedding IS NOT NULL AS embedding_stored
    FROM public.clients c
    JOIN public.practitioners p ON p.user_id = c.user_id
   WHERE c.user_id = '<uid>' AND c.deleted_at IS NULL;
  ```
  All three values must be `t / true`.

- [ ] **9.** Tap `Remove enrolment`. SnackBar reads `Face verification
  removed` with `Undo`. Section flips back to `Set up` state. Cloud
  check: `practitioners.face_embedding_consented_at` is now NULL.

- [ ] **10.** Tap `Set up` again. This time the practitioner is already
  enrolled — the `Re-enrol` flow runs end-to-end without error. Done
  state shows the `Enrolled` copy again.

## M23 — Self-client video_consent jsonb hygiene

- [ ] **11.** After M22 item 6 (sweep completed), open the Supabase SQL
  editor and confirm the Self-client jsonb has ALL 6 keys:
  ```sql
  SELECT video_consent FROM public.clients
   WHERE user_id = '<uid>' AND deleted_at IS NULL;
  ```
  Expected keys (any order): `line_drawing`, `grayscale`, `original`,
  `avatar`, `analytics_allowed`, `safe_mode_face_recognition`. No key
  may be missing.

- [ ] **12.** Verify the backfill ran on EXISTING Self-client rows. On
  staging, the QA account's Self-client may have been minted before
  this migration. Run:
  ```sql
  SELECT id, name, video_consent
    FROM public.clients
   WHERE user_id IS NOT NULL AND deleted_at IS NULL;
  ```
  Every row's jsonb must contain all 6 keys. Run this BEFORE installing
  the build to capture the pre-state, and AFTER the migration applies
  on the PR-clone DB to confirm the backfill landed.

- [ ] **13.** Migration idempotency — re-running the migration must not
  flip any `safe_mode_face_recognition: false` back to true. On a
  freshly-revoked Self-client (after M22 item 9), the `face_embedding`
  is NULL — the backfill SHOULD NOT add the key if it already exists,
  and SHOULD reflect `face_embedding IS NOT NULL` (i.e. false) when
  filling in missing keys.

