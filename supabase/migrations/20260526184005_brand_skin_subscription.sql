-- ============================================================================
-- Brand-skin subscription (Wave 4 of the artifact-system rollout)
-- 2026-05-26 — feat/artifact-brand-skin-subscription
--
-- ADR: docs/adr/0029-brand-skin-subscription-monetize-enhancement-not-entry.md
-- Design: docs/ARTIFACT_SYSTEM.md § Brand-skin subscription
-- Mirrors: supabase/migrations/20260525144158_safe_mode_sub_gate.sql
--
-- Adds a credit-denominated subscription that re-paints the chrome of every
-- client-facing artifact (today: workout handout) in the practitioner's
-- brand identity. The homefit "powered by" seal stays coral regardless.
-- One skin per practice (scoped by metadata->>'practice_id').
--
-- Locked numbers (don't re-litigate — see ADR 0029):
--   * Price:        4 credits / month  (R100 at R25/cr)
--   * Trial:        30-day free trial on first subscription (delta=0)
--   * Grace:        7-day lapse window before chrome reverts
--   * Scope:        one skin per practice (multi-practice = multi-sub)
--
-- This migration ships:
--   1. Widen credit_ledger_type_check to admit 'brand_skin_month' +
--      'brand_skin_month_trial'.
--   2. Index on credit_ledger ((metadata->>'practice_id')) so the predicate
--      doesn't full-scan.
--   3. practice_has_active_brand_skin(p_practice_id) — read-only predicate.
--      Grants to authenticated + anon (the handout calls this anonymously via
--      get_plan_full → brand_skin_active).
--   4. practice_brand_skin_state(p_practice_id) — jsonb state for portal +
--      Studio banner copy. authenticated only.
--   5. start_brand_skin_trial(p_practice_id) — one-time-per-practice trial.
--   6. start_brand_skin_subscription(p_practice_id) — atomic 4-credit debit.
--   7. Re-create get_plan_full(uuid) to add `brand_skin_active` to the plan
--      jsonb. All existing fields preserved verbatim per
--      feedback_schema_migration_column_preservation.md — sourced from
--      20260526150953_artifact_system_foundation.sql.
--
-- Deviations from ADR/spec (documented for review):
--   * Spec § ADR 0029 talks about kind = 'brand_skin_month'; the underlying
--     column is `credit_ledger.type` not `kind` (same Safe Mode trap PR #8
--     hit). We use `type` consistently.
--   * `credit_ledger.practice_id` is NOT NULL. We use the *target practice*
--     as the ledger row's practice_id AND record it again in metadata.
--     The metadata-keyed predicate is what scopes "active" — the row's
--     practice_id column matches it 1:1, but the metadata path is the
--     contract per ADR 0029 ("scope by practice").
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 0. Add credit_ledger.metadata jsonb column
-- ---------------------------------------------------------------------------
-- The baseline schema (2026-05-11) ships credit_ledger without a metadata
-- column. ADR-0029 needs to scope subscription state by practice_id stored
-- on the ledger row itself (a practitioner in multiple practices subscribes
-- to brand-skin independently per practice). Two design options:
--
--   (a) Use credit_ledger.practice_id as the scope. Works for brand-skin
--       because the ledger row's practice_id IS the practice being charged.
--       Doesn't generalise — Safe Mode is user-scoped, not practice-scoped,
--       so a future cross-cutting predicate can't tell them apart by
--       practice_id alone.
--   (b) Add a metadata jsonb. Generalises. ADR-0029 spec explicitly names
--       `metadata->>'practice_id'` as the scope key.
--
-- We pick (b) per the spec. Adding metadata jsonb is non-destructive
-- (defaults NULL on existing rows; existing readers don't look at it).
ALTER TABLE public.credit_ledger
  ADD COLUMN IF NOT EXISTS metadata jsonb;

COMMENT ON COLUMN public.credit_ledger.metadata IS
  'Per-row arbitrary metadata for subscription ledger rows. Wave 4 (2026-05-26) '
  'uses metadata->>''practice_id'' to scope brand-skin subscription state '
  'inside a practitioner-multi-practice tenant. ADR-0029.';

-- ---------------------------------------------------------------------------
-- 1. Widen the credit_ledger type CHECK to admit the two new kinds
-- ---------------------------------------------------------------------------
-- Pre-flight: source the current constraint definition from pg_constraint
-- (per feedback_schema_migration_column_preservation) — replicated literally
-- from supabase/migrations/20260525144158_safe_mode_sub_gate.sql:62-71
-- (which is what most recently set the array) and adds the two new kinds.
ALTER TABLE public.credit_ledger
  DROP CONSTRAINT IF EXISTS credit_ledger_type_check;

ALTER TABLE public.credit_ledger
  ADD CONSTRAINT credit_ledger_type_check
  CHECK (type = ANY (ARRAY[
    'purchase'::text,
    'consumption'::text,
    'refund'::text,
    'adjustment'::text,
    'signup_bonus'::text,
    'referral_signup_bonus'::text,
    'safe_mode_month'::text,
    'safe_mode_month_trial'::text,
    'brand_skin_month'::text,
    'brand_skin_month_trial'::text
  ]));

COMMENT ON CONSTRAINT credit_ledger_type_check ON public.credit_ledger IS
  'Wave 2026-05-26 (artifact-system Wave 4): added brand_skin_month + '
  'brand_skin_month_trial. See ADR-0029 + docs/ARTIFACT_SYSTEM.md § '
  'Brand-skin subscription.';

-- ---------------------------------------------------------------------------
-- 2. Index on credit_ledger ((metadata->>'practice_id')) — predicate hot path
-- ---------------------------------------------------------------------------
-- practice_has_active_brand_skin scopes "active" by metadata->>'practice_id'
-- so the brand-skin and Safe Mode subscriptions can sit on the same ledger
-- without their predicates polluting each other's hot path. Without this
-- index every handout render would full-scan credit_ledger filtered down
-- by `type IN ('brand_skin_month', ...)` then by metadata->>'practice_id' —
-- fine at MVP volumes, painful at scale. Ship it now.
CREATE INDEX IF NOT EXISTS credit_ledger_brand_skin_lookup
  ON public.credit_ledger ((metadata ->> 'practice_id'), type, created_at DESC)
  WHERE type = ANY (ARRAY[
    'brand_skin_month'::text,
    'brand_skin_month_trial'::text
  ]);

COMMENT ON INDEX public.credit_ledger_brand_skin_lookup IS
  'Hot-path index for practice_has_active_brand_skin + practice_brand_skin_state. '
  'Partial on the two brand-skin ledger types so it only stores the rows that '
  'matter and stays small. ADR-0029.';

-- ---------------------------------------------------------------------------
-- 3. practice_has_active_brand_skin(p_practice_id) — read-only predicate
-- ---------------------------------------------------------------------------
-- Returns true if any 'brand_skin_month' OR 'brand_skin_month_trial' ledger
-- row exists for this practice in the trailing 30 days + 7-day grace = 37
-- days. Used by:
--   * get_plan_full (anonymous) to surface `brand_skin_active` on the plan
--     payload so the handout JS can apply the skin.
--   * Web portal /brand-skin landing page.
--   * Mobile Studio banner via ApiClient.practiceHasActiveBrandSkin.
--
-- STABLE — same input + same DB state == same output within a transaction.
-- SECURITY DEFINER — bypasses credit_ledger RLS (RPC-write-only since
--   milestone E, and the SELECT policy is per-practice-membership; the
--   handout has no authenticated caller, so we need the SECDEF wrapper).
-- Anonymous-callable per ADR 0029 (the handout's render needs it).
CREATE OR REPLACE FUNCTION public.practice_has_active_brand_skin(
  p_practice_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1
      FROM credit_ledger
     WHERE (metadata ->> 'practice_id') = p_practice_id::text
       AND type = ANY (ARRAY[
             'brand_skin_month'::text,
             'brand_skin_month_trial'::text
           ])
       AND created_at > now() - INTERVAL '37 days'
  );
$function$;

COMMENT ON FUNCTION public.practice_has_active_brand_skin(uuid) IS
  'Artifact-system Wave 4 — brand-skin subscription gate predicate. Returns '
  'true if the practice has a brand_skin_month or brand_skin_month_trial '
  'ledger row in the trailing 37 days (30-day month + 7-day grace). STABLE + '
  'SECURITY DEFINER + anon-callable per ADR-0029.';

REVOKE ALL ON FUNCTION public.practice_has_active_brand_skin(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.practice_has_active_brand_skin(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.practice_has_active_brand_skin(uuid) TO anon;

-- ---------------------------------------------------------------------------
-- 4. practice_brand_skin_state(p_practice_id) — jsonb state for UI copy
-- ---------------------------------------------------------------------------
-- Returns:
--   {
--     active:           bool,           -- true while chrome still renders
--     in_grace:         bool,           -- true if past 30 days but <37
--     trial:            bool,           -- true if the latest active row is the trial
--     days_until_lapse: int | null,     -- days until full revert; null if not active
--     next_renewal_at:  timestamptz | null  -- day-30 mark of the latest row
--   }
--
-- "Active" means there's a paid or trial row in the trailing 37 days.
-- "In grace" means the latest row is past day 30 but still inside day 37.
-- "Days until lapse" is the remaining gap to day 37 from the latest row's
-- created_at; null if no active row exists.
--
-- Authenticated only (the handout uses the boolean from
-- practice_has_active_brand_skin; the state JSON is portal/Studio-only).
-- SECURITY DEFINER + membership check.
CREATE OR REPLACE FUNCTION public.practice_brand_skin_state(
  p_practice_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller       uuid := auth.uid();
  v_is_member    boolean;
  v_latest       credit_ledger;
  v_active       boolean;
  v_in_grace     boolean;
  v_trial        boolean;
  v_days_left    integer;
  v_next_renew   timestamptz;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'practice_brand_skin_state requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_practice_id IS NULL THEN
    RAISE EXCEPTION 'practice_brand_skin_state: p_practice_id is required'
      USING ERRCODE = '22023';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM practice_members
     WHERE practice_id = p_practice_id
       AND trainer_id  = v_caller
  ) INTO v_is_member;

  IF NOT v_is_member THEN
    -- Soft-fail: return an inactive snapshot instead of raising. The portal
    -- routes practice switches through `?practice=<uuid>` and a stale link
    -- shouldn't crash the page.
    RETURN jsonb_build_object(
      'active',           false,
      'in_grace',         false,
      'trial',            false,
      'days_until_lapse', NULL,
      'next_renewal_at',  NULL
    );
  END IF;

  -- Pick the most recent paid OR trial row, regardless of age. We compute
  -- active / in_grace from the timestamp so a 90-day-old row returns
  -- {active:false} without needing a second query.
  SELECT *
    INTO v_latest
    FROM credit_ledger
   WHERE (metadata ->> 'practice_id') = p_practice_id::text
     AND type = ANY (ARRAY[
           'brand_skin_month'::text,
           'brand_skin_month_trial'::text
         ])
   ORDER BY created_at DESC
   LIMIT 1;

  IF v_latest.id IS NULL THEN
    RETURN jsonb_build_object(
      'active',           false,
      'in_grace',         false,
      'trial',            false,
      'days_until_lapse', NULL,
      'next_renewal_at',  NULL
    );
  END IF;

  v_trial := (v_latest.type = 'brand_skin_month_trial');
  v_next_renew := v_latest.created_at + INTERVAL '30 days';

  -- Active any time the chrome is still rendering (≤ 37 days from creation).
  v_active   := (v_latest.created_at > now() - INTERVAL '37 days');
  -- In grace = past day 30 but ≤ day 37.
  v_in_grace := (v_latest.created_at <= now() - INTERVAL '30 days')
                AND v_active;

  IF v_active THEN
    -- Days remaining until full revert (day 37).
    v_days_left := GREATEST(
      0,
      CEIL(
        EXTRACT(EPOCH FROM (v_latest.created_at + INTERVAL '37 days' - now()))
        / 86400
      )::integer
    );
  ELSE
    v_days_left := NULL;
  END IF;

  RETURN jsonb_build_object(
    'active',           v_active,
    'in_grace',         v_in_grace,
    'trial',            v_trial,
    'days_until_lapse', v_days_left,
    'next_renewal_at',  v_next_renew
  );
END;
$function$;

COMMENT ON FUNCTION public.practice_brand_skin_state(uuid) IS
  'Artifact-system Wave 4 — returns a jsonb snapshot of brand-skin '
  'subscription state for the practice: {active, in_grace, trial, '
  'days_until_lapse, next_renewal_at}. Used by portal /brand-skin + '
  'Studio lapse banner. STABLE + SECURITY DEFINER + membership-checked. '
  'ADR-0029.';

REVOKE ALL ON FUNCTION public.practice_brand_skin_state(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.practice_brand_skin_state(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 5. start_brand_skin_trial(p_practice_id) — one-time-per-practice trial
-- ---------------------------------------------------------------------------
-- Writes one brand_skin_month_trial row with delta=0 for the practice.
-- Idempotent — raises if a trial row already exists for this practice
-- (any age). One trial per practice for the lifetime of the practice.
--
-- The trial covers 30 days from insert; day 31 onward the practice
-- needs a paid row. The 7-day grace applies normally (so the trial
-- effectively renders the skin for 37 days before going dark).
--
-- Caller authorisation: must be a member of the practice. SECURITY
-- DEFINER + membership check.
CREATE OR REPLACE FUNCTION public.start_brand_skin_trial(
  p_practice_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller       uuid := auth.uid();
  v_is_member    boolean;
  v_ledger_id    uuid;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'start_brand_skin_trial requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_practice_id IS NULL THEN
    RAISE EXCEPTION 'start_brand_skin_trial: p_practice_id is required'
      USING ERRCODE = '22023';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM practice_members
     WHERE practice_id = p_practice_id
       AND trainer_id  = v_caller
  ) INTO v_is_member;

  IF NOT v_is_member THEN
    RAISE EXCEPTION 'start_brand_skin_trial: caller % is not a member of practice %', v_caller, p_practice_id
      USING ERRCODE = '42501';
  END IF;

  -- Idempotency: any prior trial row (of any age) for this practice
  -- blocks a new one. "One trial per practice".
  IF EXISTS (
    SELECT 1 FROM credit_ledger
    WHERE (metadata ->> 'practice_id') = p_practice_id::text
      AND type = 'brand_skin_month_trial'
  ) THEN
    RETURN jsonb_build_object(
      'ok',     false,
      'reason', 'trial_already_used'
    );
  END IF;

  INSERT INTO credit_ledger (
    practice_id, delta, type, notes, trainer_id, metadata
  ) VALUES (
    p_practice_id,
    0,
    'brand_skin_month_trial',
    'start_brand_skin_trial(): 30-day free trial start',
    v_caller,
    jsonb_build_object('practice_id', p_practice_id::text)
  )
  RETURNING id INTO v_ledger_id;

  RETURN jsonb_build_object(
    'ok',        true,
    'ledger_id', v_ledger_id
  );
END;
$function$;

COMMENT ON FUNCTION public.start_brand_skin_trial(uuid) IS
  'Artifact-system Wave 4 — start the 30-day brand-skin free trial for the '
  'practice. Idempotent (one trial per practice). Returns jsonb '
  '{ok:true, ledger_id} on first call or {ok:false, reason:trial_already_used}. '
  'SECURITY DEFINER + membership check. ADR-0029.';

REVOKE ALL ON FUNCTION public.start_brand_skin_trial(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.start_brand_skin_trial(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 6. start_brand_skin_subscription(p_practice_id) — atomic 4-credit debit
-- ---------------------------------------------------------------------------
-- Mirrors start_safe_mode_subscription: FOR UPDATE on the practice row,
-- check balance, insert the debit row, return the new balance.
--
-- Returns:
--   { ok:true, new_balance: N, ledger_id: uuid }              on success
--   { ok:false, reason:'insufficient_credits', balance: N }    on shortfall
--
-- Called from the web portal /brand-skin/subscribe. Reader-App compliance:
-- mobile never calls this directly.
CREATE OR REPLACE FUNCTION public.start_brand_skin_subscription(
  p_practice_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller       uuid := auth.uid();
  v_is_member    boolean;
  v_balance      integer;
  v_new_balance  integer;
  v_ledger_id    uuid;
  v_credits      integer := 4;   -- 4 credits / month, locked by ADR-0029
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'start_brand_skin_subscription requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_practice_id IS NULL THEN
    RAISE EXCEPTION 'start_brand_skin_subscription: p_practice_id is required'
      USING ERRCODE = '22023';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM practice_members
     WHERE practice_id = p_practice_id
       AND trainer_id  = v_caller
  ) INTO v_is_member;

  IF NOT v_is_member THEN
    RAISE EXCEPTION 'start_brand_skin_subscription: caller % is not a member of practice %', v_caller, p_practice_id
      USING ERRCODE = '42501';
  END IF;

  -- Serialise concurrent debits against the same practice.
  PERFORM 1 FROM practices WHERE id = p_practice_id FOR UPDATE;

  SELECT COALESCE(SUM(delta), 0)::integer
    INTO v_balance
    FROM credit_ledger
   WHERE practice_id = p_practice_id;

  IF v_balance < v_credits THEN
    RETURN jsonb_build_object(
      'ok',      false,
      'reason',  'insufficient_credits',
      'balance', v_balance
    );
  END IF;

  INSERT INTO credit_ledger (
    practice_id, delta, type, notes, trainer_id, metadata
  ) VALUES (
    p_practice_id,
    -v_credits,
    'brand_skin_month',
    'start_brand_skin_subscription(): 4 credits / 30 days',
    v_caller,
    jsonb_build_object('practice_id', p_practice_id::text)
  )
  RETURNING id INTO v_ledger_id;

  v_new_balance := v_balance - v_credits;

  RETURN jsonb_build_object(
    'ok',          true,
    'new_balance', v_new_balance,
    'ledger_id',   v_ledger_id
  );
END;
$function$;

COMMENT ON FUNCTION public.start_brand_skin_subscription(uuid) IS
  'Artifact-system Wave 4 — debit 4 credits for a 30-day brand-skin '
  'subscription. Atomic FOR UPDATE on practices. Returns jsonb on success '
  'or {ok:false, reason:insufficient_credits, balance} on shortfall. '
  'Portal-only entry point (Reader-App). ADR-0029. BILLING-SENSITIVE. '
  'TODO (wave fast-follow): day-25 renewal-reminder hook lands here.';

REVOKE ALL ON FUNCTION public.start_brand_skin_subscription(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.start_brand_skin_subscription(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 7. get_plan_full(uuid) — add brand_skin_active to the plan jsonb
-- ---------------------------------------------------------------------------
-- Re-create get_plan_full to surface practice_has_active_brand_skin so the
-- handout's render path can decide whether to apply the .skin-active class.
--
-- Body sourced verbatim from supabase/migrations/20260526150953_artifact_system_foundation.sql
-- (the most recent definition) — only the trailing RETURN jsonb_build_object
-- block is widened with the new `brand_skin_active` key. Every existing
-- field (line_drawing_url, grayscale_url, original_url, all the segmented
-- URL pairs, thumbnail_url_*, exercise_sets[], artifacts, brand_color,
-- public_logo_url, practice_name) is preserved per
-- feedback_schema_migration_column_preservation.md.
--
-- The brand_skin_active branch reads practice_has_active_brand_skin which
-- is anonymous-callable, matching get_plan_full's own anonymous contract.

CREATE OR REPLACE FUNCTION public.get_plan_full(p_plan_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  plan_row             plans;
  v_consent            jsonb;
  v_gray_ok            boolean;
  v_orig_ok            boolean;
  v_base_url           text;
  exes                 jsonb;
  v_brand_color        text;
  v_public_logo_url    text;
  v_practice_name      text;
  v_artifacts          jsonb;
  v_brand_skin_active  boolean := false;
BEGIN
  UPDATE plans
     SET first_opened_at = now()
   WHERE id = p_plan_id
     AND first_opened_at IS NULL
  RETURNING * INTO plan_row;

  IF plan_row IS NULL THEN
    SELECT * INTO plan_row FROM plans WHERE id = p_plan_id LIMIT 1;
  END IF;

  IF plan_row IS NULL THEN
    RETURN NULL;
  END IF;

  IF plan_row.client_id IS NOT NULL THEN
    SELECT video_consent INTO v_consent
      FROM clients WHERE id = plan_row.client_id LIMIT 1;
  END IF;

  IF v_consent IS NULL THEN
    v_consent := '{"line_drawing": true, "grayscale": false, "original": false}'::jsonb;
  END IF;

  v_gray_ok := COALESCE((v_consent ->> 'grayscale')::boolean, false);
  v_orig_ok := COALESCE((v_consent ->> 'original')::boolean, false);

  SELECT decrypted_secret INTO v_base_url
    FROM vault.decrypted_secrets
   WHERE name = 'supabase_url'
   LIMIT 1;

  IF plan_row.practice_id IS NOT NULL THEN
    SELECT pr.brand_color, pr.public_logo_url, pr.name
      INTO v_brand_color, v_public_logo_url, v_practice_name
      FROM practices pr
     WHERE pr.id = plan_row.practice_id
     LIMIT 1;
    v_brand_skin_active := public.practice_has_active_brand_skin(plan_row.practice_id);
  END IF;

  SELECT COALESCE(
           jsonb_agg(
             to_jsonb(e)
               || jsonb_build_object(
                    'line_drawing_url', e.media_url,
                    'grayscale_url',
                      CASE
                        WHEN v_gray_ok AND e.media_type = 'video' AND plan_row.practice_id IS NOT NULL
                        THEN public.sign_storage_url(
                               'raw-archive',
                               plan_row.practice_id::text || '/' ||
                               plan_row.id::text          || '/' ||
                               e.id::text                 || '.mp4',
                               1800)
                        WHEN v_gray_ok AND e.media_type = 'photo' AND plan_row.practice_id IS NOT NULL
                        THEN public.sign_storage_url(
                               'raw-archive',
                               plan_row.practice_id::text || '/' ||
                               plan_row.id::text          || '/' ||
                               e.id::text                 || '.jpg',
                               1800)
                        ELSE NULL
                      END,
                    'original_url',
                      CASE
                        WHEN v_orig_ok AND e.media_type = 'video' AND plan_row.practice_id IS NOT NULL
                        THEN public.sign_storage_url(
                               'raw-archive',
                               plan_row.practice_id::text || '/' ||
                               plan_row.id::text          || '/' ||
                               e.id::text                 || '.mp4',
                               1800)
                        WHEN v_orig_ok AND e.media_type = 'photo' AND plan_row.practice_id IS NOT NULL
                        THEN public.sign_storage_url(
                               'raw-archive',
                               plan_row.practice_id::text || '/' ||
                               plan_row.id::text          || '/' ||
                               e.id::text                 || '.jpg',
                               1800)
                        ELSE NULL
                      END,
                    'grayscale_segmented_url',
                      CASE
                        WHEN v_gray_ok AND e.media_type = 'video' AND plan_row.practice_id IS NOT NULL
                        THEN public.sign_storage_url(
                               'raw-archive',
                               plan_row.practice_id::text || '/' ||
                               plan_row.id::text          || '/' ||
                               e.id::text                 || '.segmented.mp4',
                               1800)
                        WHEN v_gray_ok AND e.media_type = 'photo' AND plan_row.practice_id IS NOT NULL
                        THEN public.sign_storage_url(
                               'raw-archive',
                               plan_row.practice_id::text || '/' ||
                               plan_row.id::text          || '/' ||
                               e.id::text                 || '.segmented.jpg',
                               1800)
                        ELSE NULL
                      END,
                    'original_segmented_url',
                      CASE
                        WHEN v_orig_ok AND e.media_type = 'video' AND plan_row.practice_id IS NOT NULL
                        THEN public.sign_storage_url(
                               'raw-archive',
                               plan_row.practice_id::text || '/' ||
                               plan_row.id::text          || '/' ||
                               e.id::text                 || '.segmented.mp4',
                               1800)
                        WHEN v_orig_ok AND e.media_type = 'photo' AND plan_row.practice_id IS NOT NULL
                        THEN public.sign_storage_url(
                               'raw-archive',
                               plan_row.practice_id::text || '/' ||
                               plan_row.id::text          || '/' ||
                               e.id::text                 || '.segmented.jpg',
                               1800)
                        ELSE NULL
                      END,
                    'mask_url',
                      CASE
                        WHEN (v_gray_ok OR v_orig_ok) AND e.media_type = 'video' AND plan_row.practice_id IS NOT NULL
                        THEN public.sign_storage_url(
                               'raw-archive',
                               plan_row.practice_id::text || '/' ||
                               plan_row.id::text          || '/' ||
                               e.id::text                 || '.mask.mp4',
                               1800)
                        ELSE NULL
                      END,
                    'sets',
                      COALESCE(
                        (
                          SELECT jsonb_agg(
                                   jsonb_build_object(
                                     'position',                 s.position,
                                     'reps',                     s.reps,
                                     'hold_seconds',             s.hold_seconds,
                                     'hold_position',            s.hold_position,
                                     'weight_kg',                s.weight_kg,
                                     'breather_seconds_after',   s.breather_seconds_after
                                   )
                                   ORDER BY s.position
                                 )
                            FROM public.exercise_sets s
                           WHERE s.exercise_id = e.id
                        ),
                        '[]'::jsonb
                      ),
                    'rest_seconds', e.rest_seconds,
                    'thumbnail_url_line',
                      CASE
                        WHEN e.media_type IN ('video', 'photo')
                          AND v_base_url IS NOT NULL
                          AND length(v_base_url) > 0
                          AND EXISTS (
                            SELECT 1 FROM storage.objects o
                             WHERE o.bucket_id = 'media'
                               AND o.name = plan_row.id::text || '/' ||
                                            e.id::text || '_thumb_line.jpg'
                          )
                        THEN rtrim(v_base_url, '/') ||
                             '/storage/v1/object/public/media/' ||
                             plan_row.id::text || '/' || e.id::text || '_thumb_line.jpg'
                        ELSE NULL
                      END,
                    'thumbnail_url_color',
                      CASE
                        WHEN (v_gray_ok OR v_orig_ok)
                          AND e.media_type IN ('video', 'photo')
                          AND plan_row.practice_id IS NOT NULL
                          AND EXISTS (
                            SELECT 1 FROM storage.objects o
                             WHERE o.bucket_id = 'raw-archive'
                               AND o.name = plan_row.practice_id::text || '/' ||
                                            plan_row.id::text || '/' ||
                                            e.id::text || '_thumb_color.jpg'
                          )
                        THEN public.sign_storage_url(
                               'raw-archive',
                               plan_row.practice_id::text || '/' ||
                               plan_row.id::text          || '/' ||
                               e.id::text                 || '_thumb_color.jpg',
                               1800)
                        ELSE NULL
                      END,
                    'thumbnail_url_bw',
                      CASE
                        WHEN e.media_type = 'photo'
                          AND v_base_url IS NOT NULL
                          AND length(v_base_url) > 0
                          AND EXISTS (
                            SELECT 1 FROM storage.objects o
                             WHERE o.bucket_id = 'media'
                               AND o.name = plan_row.id::text || '/' ||
                                            e.id::text || '_thumb_bw.jpg'
                          )
                        THEN rtrim(v_base_url, '/') ||
                             '/storage/v1/object/public/media/' ||
                             plan_row.id::text || '/' || e.id::text || '_thumb_bw.jpg'
                        ELSE NULL
                      END
                  )
               ORDER BY e.position
           ),
           '[]'::jsonb
         )
    INTO exes
    FROM exercises e
   WHERE e.plan_id = p_plan_id;

  -- R1-M4 + Wave 1 artifact-system extension: whitelisted projection.
  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'kind',             a.kind,
               'status',           a.status,
               'generated_at',     a.generated_at,
               'published_at',     a.published_at,
               'first_opened_at',  a.first_opened_at
             )
             ORDER BY a.generated_at DESC
           ),
           '[]'::jsonb
         )
    INTO v_artifacts
    FROM public.plan_artifacts a
   WHERE a.plan_id = p_plan_id;

  RETURN jsonb_build_object(
    'plan',
      to_jsonb(plan_row)
        || jsonb_build_object(
             'brand_color',        v_brand_color,
             'public_logo_url',    v_public_logo_url,
             'practice_name',      v_practice_name,
             'brand_skin_active',  v_brand_skin_active
           ),
    'exercises', exes,
    'artifacts', v_artifacts
  );
END;
$function$;

COMMENT ON FUNCTION public.get_plan_full(uuid) IS
  'Anonymous read of a plan, exercises, plan_artifacts. Wave 4 (2026-05-26) '
  'extends the plan jsonb with brand_skin_active so handout.js can apply the '
  '.skin-active class. ADR-0029.';

-- Grants for get_plan_full were already in place from earlier migrations
-- (anon + authenticated); they survive CREATE OR REPLACE so we don't re-issue.

COMMIT;
