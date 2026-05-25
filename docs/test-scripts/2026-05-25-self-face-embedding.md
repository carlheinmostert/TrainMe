# Test script — Self-trainer wave PR #3 (self-face embedding)

**Branch:** `feat/self-face-embedding` → `staging`
**Date:** 2026-05-25
**Surface:** Mobile only (no R-10 web parity)
**Spec:** `docs/sub-agent-briefs/03-self-face-embedding.md`,
`docs/SELF_TRAINER_WAVE.md` § "Schema deltas" § 2,
ADR `docs/adr/0020-self-trainer-as-practitioner-with-self-as-client.md`

Verifies the native MobileFaceNet embedding compute path (Swift) +
Dart wrapper + `register_self_face` RPC end-to-end.

Each item runs against the STAGING Supabase project
(`vadjvkmldtoeyspyoqbx`). The test account is `qa@homefit.studio` —
see `.env.test`. Direct DB checks use the staging service role key.

---

## Tests

- [ ] **1. Compute embedding from a known selfie returns 512 floats.**
  In the running app (signed in as the QA account), wire a temporary
  debug button or use the upcoming Settings → Public profile flow to
  invoke `FaceEmbeddingService.instance.computeForImage('<path to a
  selfie JPG>')`. Expect: returns a non-null `List<double>` of length
  exactly 512, every element finite, with L2 norm in `[0.99, 1.01]`
  (the embedder L2-normalises before packing). Console.app log under
  category `self.face_embedding` should show
  `compute: success — 512 floats`.

- [ ] **2. Compute on an empty wall / no-face image returns null.**
  Push a photo of a blank wall (or any image with zero faces) into the
  simulator via `xcrun simctl addmedia <device-id> <wall.jpg>`. Call
  `computeForImage` on its path. Expect: returns `null` (not an
  exception). Console.app log under category `self.face_embedding`
  should show `compute: no face detected in <path>`. The Dart wrapper
  must NOT throw — the brief's contract is "returns null on no-face".

- [ ] **3. RPC creates the Self-client on first call.**
  As QA user (clean state: no `clients` row with `user_id =
  <qa-uid>`), call
  `ApiClient.instance.registerSelfFace(embedding: <list of 512
  doubles>, consentedAt: DateTime.now())`. Expect: returns a non-empty
  uuid string. Direct DB check via `psql` / Supabase SQL editor:
  ```sql
  SELECT id, name, user_id, practice_id, created_by_user_id
  FROM clients
  WHERE user_id = '<qa-user-id>' AND deleted_at IS NULL;
  ```
  Expect: exactly one row, `name = 'Me'`, `user_id` matches QA uid,
  `practice_id` matches QA's personal practice id from `.env.test`,
  `created_by_user_id` matches QA uid.
  And:
  ```sql
  SELECT face_embedding IS NOT NULL AS has_emb,
         face_embedding_consented_at,
         face_embedding_computed_at
  FROM practitioners WHERE user_id = '<qa-user-id>';
  ```
  Expect: `has_emb = true`, both timestamps populated, computed_at
  within seconds of `now()`, consented_at matches the value passed
  in.

- [ ] **4. RPC overwrites embedding + timestamps on re-call (idempotent).**
  Re-call `registerSelfFace` with a DIFFERENT 512-double list and a
  new `consentedAt`. Expect: returns the SAME Self-client uuid
  returned in test 3 (proves the partial unique index kept the row;
  no duplicate insertion). DB check:
  ```sql
  SELECT count(*) FROM clients
  WHERE user_id = '<qa-user-id>' AND deleted_at IS NULL;
  ```
  Expect: `count = 1`. And:
  ```sql
  SELECT face_embedding_consented_at, face_embedding_computed_at
  FROM practitioners WHERE user_id = '<qa-user-id>';
  ```
  Expect: `consented_at` matches the NEW value passed in; `computed_at`
  advanced to a fresh `now()`.

- [ ] **5. Partial unique index prevents duplicate self-clients.**
  Attempt to manually insert a second self-client row via direct SQL
  as the service role:
  ```sql
  INSERT INTO clients (practice_id, name, user_id)
  VALUES ('<qa-practice-id>', 'Me Two', '<qa-user-id>');
  ```
  Expect: PostgreSQL raises a unique-violation
  (`duplicate key value violates unique constraint
  "clients_one_self_per_user_per_practice"`). This proves the index
  added by PR #1 is enforcing one-self-client-per-(practice, user).
  Cleanup not needed — the failed insert leaves no row.

- [ ] **6. Auth gate refuses anonymous callers.**
  Using `curl` with the staging anon key (no Authorization Bearer),
  POST to
  `https://vadjvkmldtoeyspyoqbx.supabase.co/rest/v1/rpc/register_self_face`
  with a body `{"p_embedding": [<512 zeros>], "p_consented_at":
  "2026-05-25T00:00:00Z"}`. Expect: 401 / 403 (the function REVOKEs
  EXECUTE from PUBLIC and only GRANTS to `authenticated` +
  `service_role`).

- [ ] **7. Vector dimension mismatch raises a clear error.**
  Call `registerSelfFace` with a list of length 100 (NOT 512). Expect:
  the RPC raises a PostgreSQL error about vector dimensionality
  (pgvector validates dim against the column type `vector(512)`). The
  Dart caller should see a `PostgrestException` with the dim-mismatch
  message — proves the wire path doesn't silently accept malformed
  embeddings.

  **Dart-layer twin** (added in the hotfix B wave, 2026-05-25):
  `app/test/services/face_embedding_service_test.dart` mocks the native
  channel returning a 100-element list and asserts
  `FaceEmbeddingService.computeForImage` returns null rather than
  propagating the bad-dim list. Run it locally with
  `cd app && flutter test test/services/face_embedding_service_test.dart`
  to verify the Dart wrapper's dim contract is enforced before the
  embedding ever reaches the RPC.

---

## Cleanup

After test 4, the QA account has a real Self-client + a real
embedding. To reset between repeated runs:

```sql
-- As service role (staging only).
DELETE FROM clients
WHERE user_id = '<qa-user-id>' AND name = 'Me';

UPDATE practitioners
SET face_embedding              = NULL,
    face_embedding_consented_at = NULL,
    face_embedding_computed_at  = NULL
WHERE user_id = '<qa-user-id>';
```

Then tests 3 → 5 can re-run from a clean slate.
