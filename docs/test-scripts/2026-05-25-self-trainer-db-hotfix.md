# Self-trainer DB hotfix (2026-05-25)

Branch: `fix/self-trainer-db-hotfix`
Migration: `supabase/migrations/20260525160312_self_trainer_hotfix.sql`
Target: `staging` → squash-merge after green CI.

Addresses 15 findings from the post-self-trainer-wave audit. Most checks
below are server-side SQL — run against the staging Supabase project
(`vadjvkmldtoeyspyoqbx`) using the SQL editor or the staging-linked
Supabase CLI. The Flutter-side checks should be run from `qa@homefit.studio`
on staging.

## Critical fixes

- [ ] **1. CA-1 — publish_free is an accepted credit_ledger.type.**
  Run: `INSERT INTO credit_ledger (practice_id, delta, type, plan_id, notes, trainer_id) VALUES ('00000000-0000-0000-0000-000000000000', 0, 'publish_free', NULL, 'CA-1 dry run — rollback', '00000000-0000-0000-0000-000000000000');`
  Expect: foreign-key violation on practice_id (NOT a CHECK constraint
  violation on type). Roll back. Confirms `publish_free` passes the
  widened CHECK.

- [ ] **2. CA-4a — authenticated cannot UPDATE clients.user_id directly.**
  As `qa@homefit.studio` (staging), run: `UPDATE clients SET user_id =
  auth.uid() WHERE id = '<some-client-id>';` against the SQL editor with
  the authenticated role.
  Expect: `permission denied for table clients` (column-level update
  privilege revoked).

- [ ] **3. CA-4b — authenticated cannot UPDATE exercises.self_verified
  directly.**
  As `qa@homefit.studio`, run: `UPDATE exercises SET self_verified =
  true WHERE id = '<some-exercise-id>';` with the authenticated role.
  Expect: `permission denied`.

- [ ] **4. CA-4c — replace_plan_exercises (SECURITY DEFINER) still writes
  self_verified.** Publish a self-trainer plan from the QA staging app
  with a verified capture. Query `SELECT self_verified FROM exercises
  WHERE plan_id = '<plan-id>';` — non-null TRUE rows confirm the
  definer-mode write path is unaffected.

- [ ] **5. CA-5 — authenticated cannot SELECT practitioners.face_embedding
  directly.** As `qa@homefit.studio`, run `SELECT face_embedding FROM
  practitioners WHERE user_id = auth.uid();`. Expect: empty / permission
  error on the column. (Pre-hotfix returned the vector.)

- [ ] **6. CA-5b — get_my_self_face_embedding() still returns own
  embedding.** As `qa@homefit.studio`, run `SELECT
  get_my_self_face_embedding();`. Expect: returns the real[] vector for
  the caller. SECURITY DEFINER path unaffected by the column REVOKE.

- [ ] **7. CB-6a — is_self_trainer_all_verified is now single-arg.** Run
  `SELECT proname, pg_get_function_arguments(oid) FROM pg_proc WHERE
  proname = 'is_self_trainer_all_verified';`. Expect: exactly one
  signature, args `p_plan_id uuid`. The two-arg form must be gone.

- [ ] **8. CB-6b — is_self_trainer_all_verified is NOT executable by
  anon or PUBLIC.** Run `SELECT has_function_privilege('anon',
  'public.is_self_trainer_all_verified(uuid)', 'EXECUTE'), has_function_privilege('public',
  'public.is_self_trainer_all_verified(uuid)', 'EXECUTE');`. Expect:
  both `false`.

- [ ] **9. CB-6c — preview_publish_cost is NOT executable by anon /
  PUBLIC.** Run `SELECT has_function_privilege('anon',
  'public.preview_publish_cost(uuid)', 'EXECUTE');`. Expect: `false`.
  Authenticated still: `true`.

- [ ] **10. CB-7 — consume_credit paid path rejects mismatched
  p_credits.** With a non-self-trainer plan whose cloud
  `exercise_sets` total ≤ 4500s (so server cost = 1), invoke from a
  practice-member session: `SELECT public.consume_credit('<practice-id>',
  '<plan-id>', 2);`. Expect: `22023` exception "p_credits=2 does not
  match server-computed cost=1". Inverse case (server cost = 2,
  p_credits = 1) also rejected.

- [ ] **11. CB-9a — register_self_face writes a granted audit row.**
  In the QA staging app, opt into self-trainer face verification. Query
  `SELECT kind, meta FROM audit_events WHERE actor_id = '<qa-user-id>'
  ORDER BY ts DESC LIMIT 5;`. Expect a row with kind
  `practitioner.face_consent.granted`, meta `{consented_at, embedding_dim:512}`.

- [ ] **12. CB-9b — revoke_self_face writes a revoked audit row.** In
  the QA app, revoke self-trainer consent. Query `audit_events` again
  → expect kind `practitioner.face_consent.revoked`, meta
  `{embedding_cleared:true, self_client_soft_deleted:true}`.

## Medium fixes

- [ ] **13. R1-M1 / R3-M6 — FOR SHARE lock on consume_credit free
  path.** Hard to exercise visually but verify the SQL is present —
  in the staging migration file, the `consume_credit` body must
  contain a `PERFORM 1 FROM public.exercises WHERE plan_id = p_plan_id
  FOR SHARE;` block before the self_free check.

- [ ] **14. R1-M4 — get_plan_full strips plan_artifacts.metadata.**
  Open a published staging plan via the anonymous web player URL,
  then in the browser devtools network tab inspect the
  `get_plan_full` response. Confirm: every entry in
  `data.artifacts[*]` has ONLY `{kind, status, generated_at}` — no
  `metadata`, no `output_url`.

- [ ] **15. R3-M1 — start_safe_mode_subscription rejects non-owner.**
  As an `authenticated` practitioner in a practice they're NOT an
  owner of, call `SELECT public.start_safe_mode_subscription('<practice-id>');`.
  Expect: `42501` exception "caller % is not an owner of practice %".
  Owner role: succeeds (debits 4 credits if balance allows).

- [ ] **16. R3-M5a — is_in_active_safe_mode_sub rejects cross-user
  queries.** As `qa@homefit.studio`, run `SELECT
  public.is_in_active_safe_mode_sub('<some-OTHER-user-id>');`. Expect:
  `42501` "may only query its own subscription state".

- [ ] **17. R3-M5b — is_in_active_safe_mode_sub is NOT anon-executable.**
  Query: `SELECT has_function_privilege('anon',
  'public.is_in_active_safe_mode_sub(uuid)', 'EXECUTE');`. Expect:
  `false`.

- [ ] **18. R4-M1 — Self-client video_consent has
  analytics_allowed=false.** After running register_self_face for a
  new user, query `SELECT video_consent FROM clients WHERE user_id =
  '<that-user-id>' AND deleted_at IS NULL;`. Expect:
  `analytics_allowed:false` key explicitly set. Then publish a plan
  for that Self-client and verify analytics events are NOT recorded
  on the web player (no rows in `plan_analytics_events` for that
  session).

## Low fixes

- [ ] **19. R3-L1 — refund_credit deletes publish_free rows.** Stage:
  insert a synthetic `publish_free` ledger row for a test plan. Call
  `SELECT public.refund_credit('<plan-id>');` as a practice member.
  Expect: returns `true`, the publish_free row is gone from
  `credit_ledger`.

- [ ] **20. R3-L2 — consume_credit prepaid-unlock path comments are
  present.** Visual check on the migration file — the SQL block
  immediately above the `IF v_prepaid_at IS NOT NULL` branch must
  carry an inline comment explaining the deliberate no-ledger-row
  decision (so future readers don't "fix" it by adding a refund row).

- [ ] **21. R4-L2 — register_self_face stamps now() server-side.**
  Call `register_self_face` with a p_consented_at far in the past
  (e.g. `'2020-01-01T00:00Z'`). Query the row: `SELECT
  face_embedding_consented_at FROM practitioners WHERE user_id =
  auth.uid();`. Expect: timestamp ≈ now() (not 2020-01-01). Confirms
  the param is ignored.

## End-to-end smoke

- [ ] **22. Self-trainer free publish still works.** From the QA app,
  register self-face, capture + verify two exercises, publish. Expect:
  no credits consumed (balance unchanged), `credit_ledger` has a new
  `publish_free` row with delta=0, plan_artifacts has a `plan_url`
  ready row.

- [ ] **23. Non-self-trainer paid publish still works.** From the QA
  app, publish a regular client plan (not self). Expect: 1 credit
  consumed, `credit_ledger` has a `consumption` row, plan opens
  normally on the web player.

- [ ] **24. consume_credit blocks lying clients.** From a manually
  crafted RPC call passing `p_credits=1` for a plan whose true cost is
  2, expect 22023 exception (not silent overcharge / undercharge).
