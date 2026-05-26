-- =============================================================================
-- Artifact-system foundation (Wave 1)
-- =============================================================================
--
-- Implements the schema deltas + multi-kind publish RPC for the artifact-system
-- design ratified across ADRs 0024–0029 (`docs/ARTIFACT_SYSTEM.md`):
--
--   * Widens `plan_artifacts.kind` from the single value `'plan_url'` to the
--     six values registered in the design doc (`plan_url`, `handout`, `poster`,
--     `reel`, `ai_reel`, `calendar`). Only `plan_url` (paid) + `handout`
--     (free) are wired to a price helper in Wave 1; the others raise from
--     `publish_plan_artifacts` until later waves register them.
--
--   * Adds three columns to `plan_artifacts` that ADR 0022 + the design doc
--     anticipated but the original `plan_artifacts_on_publish` migration
--     deferred: `published_at`, `credits_charged`, `first_opened_at`.
--     `published_at` is the artifact-grain publish stamp (`plans.first_opened_at`
--     stays the legacy plan-grain first-open); `first_opened_at` is the
--     artifact-grain first-open (per ADR 0028 the edit-lock arms when ANY
--     artifact's `first_opened_at` is set, but Wave 1 only writes the column —
--     the lock semantics ship in Wave 3).
--
--   * Backfills `published_at = generated_at` for the 14 existing
--     `kind='plan_url'` rows so the new column has parity from row one.
--
--   * Adds `clients.email` (practitioner-typed transient pre-claim contact;
--     POPIA notice in the column comment). Used by Wave 2's claim flow as
--     a one-shot magic-link target; deleted once the recipient has signed
--     up and minted a verified consumer email.
--
--   * Adds `plan_issuances.kind` (nullable) so future per-artifact audit
--     rows distinguish which kind was published. Nullable + no backfill
--     because the Flutter UploadService still inserts plan_issuances
--     directly via `authenticated` INSERT (RLS-policy `plan_issuances_insert_own`)
--     — pre-existing rows keep NULL, post-migration rows from the new RPC
--     get the kind, and the Flutter callsite will be updated in Wave 3
--     when the publish flow moves into the new RPC. Wave 1 does NOT
--     revoke INSERT on plan_issuances for the same reason — the Flutter
--     flow has to keep writing while it owns the publish path.
--
--   * Introduces `_artifact_kind_price(p_kind, p_total_seconds)` —
--     SECURITY DEFINER + STABLE helper that returns the credit price for
--     a kind given the plan duration in seconds. Encodes ADR 0027's
--     locked policy: handout=0, plan_url=1 (<=4500s) or 2 (>4500s, the
--     same 75-min boundary as `consume_credit` and `preview_publish_cost`),
--     reel/ai_reel/poster/calendar return NULL (not yet shippable; caller
--     must raise).
--
--   * Introduces `publish_plan_artifacts(p_practice_id, p_plan_id, p_kinds)`
--     SECURITY DEFINER RPC — the multi-kind publish gate from ADR 0027 +
--     decision #21. Validates kinds, sums prices, calls `consume_credit`
--     ONCE on the sum (the existing implementation upserts a `plan_url`
--     row as a side effect, which is desirable when 'plan_url' is in the
--     set), and upserts a `plan_artifacts` row per kind. `UNIQUE(plan_id,
--     kind)` keeps the singleton invariant. Re-ticking an existing row
--     is a no-op (no re-charge) by virtue of the `consume_credit` call
--     being skipped when the paid sum is zero AND the existing row check.
--
--   * Extends `get_plan_full` artifact projection from
--     `{kind, status, generated_at}` to
--     `{kind, status, published_at, first_opened_at}` so the web handout +
--     future readers can read per-artifact publish state from the single
--     anon RPC. The R1-M4 whitelist note in the existing function is
--     preserved — output_url + metadata stay dropped.
--
-- Wave 1 deliberately defers: multi-select publish gate UI (Wave 3),
-- magic-link claim flow (Wave 2), brand-skin overrides (Wave 4), managed-
-- email edge function (Wave 5), portal audit feed updates (Wave 6).
--
-- Pre-flight against staging (2026-05-26) confirmed: 14 existing
-- plan_artifacts rows, all kind='plan_url'; plan_issuances has no `kind`
-- column; clients has no `email` column; `consume_credit` already upserts
-- the plan_url plan_artifacts row on the paid + free + prepaid paths;
-- `get_plan_full` is RETURNS jsonb (not RETURNS TABLE) so the artifact
-- projection is a sub-SELECT in the function body. Reference column
-- preservation rule: `feedback_schema_migration_column_preservation.md`.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. plan_artifacts — widen kind CHECK + add publish-state columns
-- -----------------------------------------------------------------------------

ALTER TABLE public.plan_artifacts
  DROP CONSTRAINT IF EXISTS plan_artifacts_kind_check;

ALTER TABLE public.plan_artifacts
  ADD CONSTRAINT plan_artifacts_kind_check
  CHECK (kind IN ('plan_url', 'handout', 'poster', 'reel', 'ai_reel', 'calendar'));

ALTER TABLE public.plan_artifacts
  ADD COLUMN IF NOT EXISTS published_at      timestamptz,
  ADD COLUMN IF NOT EXISTS credits_charged   numeric(10, 4) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS first_opened_at   timestamptz;

COMMENT ON COLUMN public.plan_artifacts.published_at IS
  'Artifact-grain publish stamp. NULL = offered but not minted (will not appear in Wave 1 — every minted row has this set). Distinct from plans.first_opened_at which is the legacy plan-grain first-open. Backfilled from generated_at on Wave 1.';

COMMENT ON COLUMN public.plan_artifacts.credits_charged IS
  'Per-artifact credit price charged at publish. Free kinds (handout) are 0. Sum over all rows for a plan == total credits consumed for that plan''s publish history (modulo refunds).';

COMMENT ON COLUMN public.plan_artifacts.first_opened_at IS
  'Per-artifact first-open stamp (set by the renderer on first anon fetch). Distinct from plans.first_opened_at, which is the LEGACY plan-grain stamp. ADR 0028 arms the edit-lock when any artifact''s first_opened_at is set — Wave 1 only writes the column; lock semantics ship in Wave 3.';

-- Backfill: every existing plan_url row gets published_at = generated_at.
UPDATE public.plan_artifacts
   SET published_at = generated_at
 WHERE kind = 'plan_url'
   AND published_at IS NULL;

-- -----------------------------------------------------------------------------
-- 2. clients.email — practitioner-typed transient pre-claim contact
-- -----------------------------------------------------------------------------

ALTER TABLE public.clients
  ADD COLUMN IF NOT EXISTS email text;

COMMENT ON COLUMN public.clients.email IS
  'POPIA-sensitive: practitioner-typed pre-claim contact email — used by the Wave 2 claim flow as a one-shot magic-link target. NOT verified; not a stable identifier. Deleted from this row the moment the recipient claims and the consumer account mints a verified email. Per ADR 0024 locked decision #14, the claimed account is the ongoing-engagement rail and this column is fallback only.';

-- -----------------------------------------------------------------------------
-- 3. plan_issuances.kind — per-artifact audit dimension (nullable)
-- -----------------------------------------------------------------------------
-- Nullable on purpose: the Flutter UploadService still inserts
-- plan_issuances directly via authenticated INSERT (policy
-- plan_issuances_insert_own). Old callers omit `kind` and get NULL.
-- The new publish_plan_artifacts RPC writes one row PER kind with the
-- kind filled in. Wave 3 will retire the direct INSERT in favour of
-- the RPC.

ALTER TABLE public.plan_issuances
  ADD COLUMN IF NOT EXISTS kind text;

ALTER TABLE public.plan_issuances
  DROP CONSTRAINT IF EXISTS plan_issuances_kind_check;

ALTER TABLE public.plan_issuances
  ADD CONSTRAINT plan_issuances_kind_check
  CHECK (kind IS NULL OR kind IN ('plan_url', 'handout', 'poster', 'reel', 'ai_reel', 'calendar'));

COMMENT ON COLUMN public.plan_issuances.kind IS
  'Per-artifact audit dimension. NULL for rows written by the legacy Flutter UploadService direct-INSERT path; set per kind for rows written by publish_plan_artifacts. Wave 3 will retire the direct-INSERT path.';

-- -----------------------------------------------------------------------------
-- 4. _artifact_kind_price — registry of per-kind credit prices
-- -----------------------------------------------------------------------------
-- Encodes ADR 0027:
--   handout                 : 0 credits (free floor)
--   plan_url                : 1 credit if total_seconds <= 4500 (75 min),
--                             else 2 credits (matches consume_credit's
--                             server-side recomputation)
--   poster/reel/ai_reel/cal : NULL — kind not yet shippable; caller raises

CREATE OR REPLACE FUNCTION public._artifact_kind_price(
  p_kind          text,
  p_total_seconds integer
)
RETURNS numeric(10, 4)
LANGUAGE plpgsql
IMMUTABLE
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  CASE p_kind
    WHEN 'handout' THEN
      RETURN 0;
    WHEN 'plan_url' THEN
      IF p_total_seconds IS NULL OR p_total_seconds <= 4500 THEN
        RETURN 1;
      ELSE
        RETURN 2;
      END IF;
    ELSE
      -- poster / reel / ai_reel / calendar — not yet shippable.
      RETURN NULL;
  END CASE;
END;
$function$;

COMMENT ON FUNCTION public._artifact_kind_price(text, integer) IS
  'Per-artifact credit price helper. Returns NULL for kinds not yet shippable; caller must check + raise. Encodes ADR 0027 (handout free, plan_url duration-based 1 or 2 credits).';

-- -----------------------------------------------------------------------------
-- 5. publish_plan_artifacts — the multi-kind atomic publish RPC
-- -----------------------------------------------------------------------------
-- SECURITY DEFINER. Membership-gated.
--
-- Inputs:
--   p_practice_id  : the practice paying for this publish.
--   p_plan_id      : the plan whose artifacts are being minted.
--   p_kinds        : text[] of kinds to publish. Empty / NULL raises.
--
-- Behaviour:
--   * Validates caller is a member of the practice.
--   * Validates every kind is in the widened CHECK list.
--   * Computes the plan's total seconds (same formula consume_credit
--     uses) so the per-kind price helper can branch.
--   * Sums per-kind prices via _artifact_kind_price. If any kind returns
--     NULL the RPC raises (kind not yet shippable in Wave 1).
--   * If the sum is > 0:
--       - calls consume_credit(p_practice_id, p_plan_id, sum) ONCE.
--         consume_credit's existing implementation will write the
--         credit_ledger row + upsert a plan_artifacts row for kind='plan_url'
--         when plan_url is in the requested set (the upsert is unconditional
--         in consume_credit — that's pre-existing behaviour we ride on top
--         of). If consume_credit returns ok=false (insufficient credits),
--         the RPC returns the failure shape verbatim.
--   * If the sum is 0:
--       - skips consume_credit (it rejects p_credits <= 0 on the paid path,
--         and the self-trainer free path is a separate code branch we
--         don't want to spoof). We just upsert the artifact rows directly.
--   * Upserts every requested plan_artifacts row (idempotent on UNIQUE
--     (plan_id, kind)). Re-publishing an existing kind does NOT re-charge —
--     the credit-charging is the sum minus the already-published kinds'
--     prices. (Wave 1 keeps the math simple: caller is expected to pass
--     ONLY the kinds it wants to newly mint; the practitioner-facing
--     Publish gate from Wave 3 will surface already-Live kinds as
--     non-tickable. Defensive: this RPC tolerates re-ticks by computing
--     the unpaid delta.)
--   * Writes a plan_issuances row PER published kind, stamped with the
--     per-kind credits_charged value. This is the new audit trail that
--     extends ADR 0007 to per-artifact granularity.
--
-- Returns:
--   jsonb { ok: bool, new_balance: int?, reason: text?, published: text[] }

CREATE OR REPLACE FUNCTION public.publish_plan_artifacts(
  p_practice_id uuid,
  p_plan_id     uuid,
  p_kinds       text[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_caller            uuid := auth.uid();
  v_is_member         boolean;
  v_total_seconds     integer := 0;
  v_kind              text;
  v_price             numeric(10, 4);
  v_paid_sum          numeric(10, 4) := 0;
  v_paid_sum_int      integer;
  v_consume_result    jsonb;
  v_existing_kinds    text[];
  v_kinds_to_publish  text[] := ARRAY[]::text[];
  v_kind_prices       jsonb := '{}'::jsonb;
  v_plan_version      integer;
  v_exercise_count    integer;
BEGIN
  -- ===== Validation ========================================================

  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'publish_plan_artifacts requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_practice_id IS NULL THEN
    RAISE EXCEPTION 'publish_plan_artifacts: p_practice_id is required'
      USING ERRCODE = '22023';
  END IF;

  IF p_plan_id IS NULL THEN
    RAISE EXCEPTION 'publish_plan_artifacts: p_plan_id is required'
      USING ERRCODE = '22023';
  END IF;

  IF p_kinds IS NULL OR array_length(p_kinds, 1) IS NULL THEN
    RAISE EXCEPTION 'publish_plan_artifacts: p_kinds must be non-empty'
      USING ERRCODE = '22023';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM practice_members
     WHERE practice_id = p_practice_id
       AND trainer_id  = v_caller
  ) INTO v_is_member;

  IF NOT v_is_member THEN
    RAISE EXCEPTION
      'publish_plan_artifacts: caller % is not a member of practice %',
      v_caller, p_practice_id
      USING ERRCODE = '42501';
  END IF;

  -- Plan ownership: defence-in-depth. consume_credit also checks this,
  -- but the free path here skips that call so we need our own gate.
  IF NOT EXISTS (
    SELECT 1 FROM public.plans
     WHERE id = p_plan_id
       AND practice_id = p_practice_id
  ) THEN
    RAISE EXCEPTION
      'publish_plan_artifacts: plan % does not belong to practice %',
      p_plan_id, p_practice_id
      USING ERRCODE = '42501';
  END IF;

  -- Validate every kind against the CHECK list. The CHECK on plan_artifacts
  -- would catch this at INSERT time, but raising EARLY gives a clean error
  -- message rather than a generic constraint violation.
  FOREACH v_kind IN ARRAY p_kinds LOOP
    IF v_kind NOT IN ('plan_url', 'handout', 'poster', 'reel', 'ai_reel', 'calendar') THEN
      RAISE EXCEPTION
        'publish_plan_artifacts: unknown kind "%" (allowed: plan_url, handout, poster, reel, ai_reel, calendar)',
        v_kind
        USING ERRCODE = '22023';
    END IF;
  END LOOP;

  -- ===== Compute plan total seconds =======================================
  -- Same formula consume_credit uses. Used by the price helper.
  SELECT COALESCE(SUM(
            (s.reps * 3)
            + CASE s.hold_position
                WHEN 'per_rep'         THEN s.reps * s.hold_seconds
                WHEN 'end_of_set'      THEN s.hold_seconds
                WHEN 'end_of_exercise' THEN
                  CASE WHEN s.position = (
                        SELECT MAX(s2.position) FROM public.exercise_sets s2
                         WHERE s2.exercise_id = s.exercise_id
                       )
                       THEN s.hold_seconds ELSE 0
                  END
              END
            + s.breather_seconds_after
         ), 0)::integer
    INTO v_total_seconds
    FROM public.exercise_sets s
    JOIN public.exercises   e ON e.id = s.exercise_id
   WHERE e.plan_id = p_plan_id
     AND e.media_type <> 'rest';

  -- ===== Filter to newly-published kinds + sum unpaid =====================
  -- A kind that already has a row in plan_artifacts with published_at IS
  -- NOT NULL is a no-op (already-Live). We DO NOT re-charge for it.
  SELECT COALESCE(array_agg(kind), ARRAY[]::text[])
    INTO v_existing_kinds
    FROM public.plan_artifacts
   WHERE plan_id = p_plan_id
     AND published_at IS NOT NULL;

  FOREACH v_kind IN ARRAY p_kinds LOOP
    -- Skip already-published kinds — no-op + don't re-charge.
    IF v_kind = ANY(v_existing_kinds) THEN
      CONTINUE;
    END IF;

    v_price := public._artifact_kind_price(v_kind, v_total_seconds);
    IF v_price IS NULL THEN
      RAISE EXCEPTION
        'publish_plan_artifacts: kind "%" is not yet shippable in this wave',
        v_kind
        USING ERRCODE = 'P0003';
    END IF;

    v_paid_sum := v_paid_sum + v_price;
    v_kind_prices := v_kind_prices || jsonb_build_object(v_kind, v_price);
    v_kinds_to_publish := array_append(v_kinds_to_publish, v_kind);
  END LOOP;

  -- Every requested kind was already-published → no-op success.
  IF array_length(v_kinds_to_publish, 1) IS NULL THEN
    RETURN jsonb_build_object(
      'ok',         true,
      'published',  ARRAY[]::text[],
      'reason',     'already_published'
    );
  END IF;

  -- ===== Consume credits if needed =======================================
  -- The current consume_credit only accepts integer p_credits in {1, 2}.
  -- Wave 1's only paid kind is plan_url (1 or 2 credits) and handout is
  -- free, so the sum is always 0, 1, or 2 — well within range. If a future
  -- wave introduces a non-integer-priced kind (e.g. premium reel at 5
  -- credits) the publish RPC will need to chunk consume_credit calls,
  -- but that's not a Wave 1 concern.
  IF v_paid_sum > 0 THEN
    v_paid_sum_int := v_paid_sum::integer;
    IF v_paid_sum_int::numeric <> v_paid_sum THEN
      RAISE EXCEPTION
        'publish_plan_artifacts: fractional credit sums not supported in this wave (sum=%); future kind requires consume_credit widening',
        v_paid_sum
        USING ERRCODE = '0A000';
    END IF;

    v_consume_result := public.consume_credit(p_practice_id, p_plan_id, v_paid_sum_int);
    IF NOT (v_consume_result->>'ok')::boolean THEN
      -- Pass the failure shape through unchanged (insufficient_credits etc).
      RETURN v_consume_result;
    END IF;
  END IF;

  -- ===== Upsert plan_artifacts rows =======================================
  -- consume_credit's existing implementation upserts the plan_url row
  -- on the paid path. We re-upsert here to set published_at +
  -- credits_charged for every requested kind, including plan_url. The
  -- upsert is idempotent — re-running with the same kind set is safe.
  FOREACH v_kind IN ARRAY v_kinds_to_publish LOOP
    INSERT INTO public.plan_artifacts (
      plan_id, kind, status, generated_at, published_at, credits_charged
    )
    VALUES (
      p_plan_id,
      v_kind,
      'ready',
      now(),
      now(),
      COALESCE((v_kind_prices->>v_kind)::numeric, 0)
    )
    ON CONFLICT (plan_id, kind) DO UPDATE
      SET generated_at    = EXCLUDED.generated_at,
          published_at    = COALESCE(plan_artifacts.published_at, EXCLUDED.published_at),
          credits_charged = plan_artifacts.credits_charged + EXCLUDED.credits_charged,
          status          = 'ready';
  END LOOP;

  -- ===== Audit: plan_issuances row per kind ==============================
  -- One row per newly-published kind. Carries the per-kind credit charge
  -- so the portal audit feed can later break down "this publish cost N
  -- credits across these K artifacts." Pre-Wave-1 rows have NULL kind
  -- (legacy Flutter direct-INSERT path); post-Wave-1 rows from this RPC
  -- have a populated kind.
  SELECT version, (
    SELECT COUNT(*) FROM public.exercises
     WHERE plan_id = p_plan_id
       AND media_type <> 'rest'
  )::integer
    INTO v_plan_version, v_exercise_count
    FROM public.plans
   WHERE id = p_plan_id;

  FOREACH v_kind IN ARRAY v_kinds_to_publish LOOP
    INSERT INTO public.plan_issuances (
      plan_id, practice_id, trainer_id, version, exercise_count,
      credits_charged, issued_at, kind
    )
    VALUES (
      p_plan_id,
      p_practice_id,
      v_caller,
      COALESCE(v_plan_version, 1),
      COALESCE(v_exercise_count, 0),
      COALESCE((v_kind_prices->>v_kind)::numeric, 0)::integer,
      now(),
      v_kind
    );
  END LOOP;

  RETURN jsonb_build_object(
    'ok',         true,
    'published',  v_kinds_to_publish,
    'paid_sum',   v_paid_sum
  );
END;
$function$;

COMMENT ON FUNCTION public.publish_plan_artifacts(uuid, uuid, text[]) IS
  'Multi-kind atomic publish RPC. Sums per-kind prices via _artifact_kind_price, calls consume_credit once on the total, upserts plan_artifacts rows + writes per-kind plan_issuances audit rows in one transaction. Membership-gated. Re-ticking an already-published kind is a no-op. Returns jsonb { ok, published: text[], paid_sum, ... } or the failure shape from consume_credit on insufficient credits.';

-- ACL: same posture as consume_credit. authenticated may call; anon cannot.
REVOKE ALL ON FUNCTION public.publish_plan_artifacts(uuid, uuid, text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.publish_plan_artifacts(uuid, uuid, text[]) TO authenticated;

-- _artifact_kind_price is an internal helper — only invoked from within
-- the RPC. No execute grant outside service_role.
REVOKE ALL ON FUNCTION public._artifact_kind_price(text, integer) FROM PUBLIC;

-- -----------------------------------------------------------------------------
-- 6. Extend get_plan_full's artifact projection
-- -----------------------------------------------------------------------------
-- The existing artifact projection emits {kind, status, generated_at}.
-- Wave 1 needs {kind, status, published_at, first_opened_at} so the web
-- handout can show "Live since X" + drive the future per-artifact analytics.
-- generated_at stays in the projection — it's a useful "when was the
-- row first created" signal even for re-published artifacts.
--
-- IMPORTANT: this CREATE OR REPLACE preserves EVERY other column in the
-- existing function body — exercises projection, treatment URLs, sets,
-- thumbnails, brand colour, public profile, etc. Reference rule:
-- feedback_schema_migration_column_preservation.md.

CREATE OR REPLACE FUNCTION public.get_plan_full(p_plan_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  plan_row          plans;
  v_consent         jsonb;
  v_gray_ok         boolean;
  v_orig_ok         boolean;
  v_base_url        text;
  exes              jsonb;
  v_brand_color     text;
  v_public_logo_url text;
  v_practice_name   text;
  v_artifacts       jsonb;
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
  -- Pre-Wave-1: {kind, status, generated_at}.
  -- Wave 1: add {published_at, first_opened_at}; keep generated_at for
  -- backwards compat. metadata + output_url stay dropped (R1-M4 whitelist
  -- — both can leak internal generator state or signed storage URLs).
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
             'brand_color',     v_brand_color,
             'public_logo_url', v_public_logo_url,
             'practice_name',   v_practice_name
           ),
    'exercises', exes,
    'artifacts', v_artifacts
  );
END;
$function$;

-- -----------------------------------------------------------------------------
-- 7. record_artifact_opened — first-open stamp on the artifact row
-- -----------------------------------------------------------------------------
-- Per-artifact analogue of record_plan_opened. Idempotently stamps
-- plan_artifacts.first_opened_at on the (plan_id, kind) row. Called by
-- the workout handout page at /h/ on first anon fetch.
--
-- The plan-level record_plan_opened RPC still fires (driven by
-- get_plan_full's existing UPDATE on plans.first_opened_at). This RPC
-- adds the per-artifact dimension needed by ADR 0028's edit-lock arming
-- logic in Wave 3.
--
-- Anonymous-safe SECURITY DEFINER per ADR 0024 (artifact links open
-- without auth). Best-effort: silently no-ops if the row doesn't exist
-- (handout artifact hasn't been published yet — caller renders the
-- "plan not found" page based on get_plan_full's own NULL return).

CREATE OR REPLACE FUNCTION public.record_artifact_opened(
  p_plan_id uuid,
  p_kind    text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF p_plan_id IS NULL OR p_kind IS NULL THEN
    RETURN;
  END IF;

  UPDATE public.plan_artifacts
     SET first_opened_at = COALESCE(first_opened_at, now())
   WHERE plan_id = p_plan_id
     AND kind    = p_kind;
END;
$function$;

COMMENT ON FUNCTION public.record_artifact_opened(uuid, text) IS
  'Idempotently stamps plan_artifacts.first_opened_at on (plan_id, kind). Anonymous-callable per ADR 0024. Best-effort no-op when the row does not exist.';

REVOKE ALL ON FUNCTION public.record_artifact_opened(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_artifact_opened(uuid, text) TO anon, authenticated;

COMMIT;
