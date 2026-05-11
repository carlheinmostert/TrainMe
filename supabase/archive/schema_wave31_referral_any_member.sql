-- homefit.studio — Wave 31: referral code RPC accessible to any practice member
-- =============================================================================
-- Run via the linked CLI:
--   supabase db query --linked --file supabase/schema_wave31_referral_any_member.sql
-- Idempotent.
--
-- Bug: Milestone F's `generate_referral_code` guarded on
-- `user_is_practice_owner(p_practice_id)`, so non-owner practitioners hit a
-- 42501 when the share sheet tried to mint/fetch the practice's code.
--
-- Fix: relax the guard to "any member of the practice". A practitioner
-- sharing the practice's referral code is the whole point — owners and
-- practitioners both pay credits, both should be able to share. Code is
-- per-practice (PK on `referral_codes.practice_id`), so this RPC stays
-- idempotent regardless of caller role.
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.generate_referral_code(p_practice_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller    uuid := auth.uid();
  v_existing  text;
  v_slug      text;
  v_attempt   int  := 0;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'generate_referral_code requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF NOT (p_practice_id = ANY(SELECT user_practice_ids())) THEN
    RAISE EXCEPTION 'generate_referral_code: caller is not a member of practice %',
      p_practice_id
      USING ERRCODE = '42501';
  END IF;

  SELECT code INTO v_existing
    FROM referral_codes
   WHERE practice_id = p_practice_id
     AND revoked_at IS NULL;

  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;

  LOOP
    v_attempt := v_attempt + 1;
    v_slug := public._generate_slug_7();
    BEGIN
      INSERT INTO referral_codes (practice_id, code)
      VALUES (p_practice_id, v_slug);
      RETURN v_slug;
    EXCEPTION
      WHEN unique_violation THEN
        SELECT code INTO v_existing
          FROM referral_codes
         WHERE practice_id = p_practice_id
           AND revoked_at IS NULL;
        IF v_existing IS NOT NULL THEN
          RETURN v_existing;
        END IF;

        IF v_attempt >= 5 THEN
          RAISE EXCEPTION
            'generate_referral_code: could not allocate a unique slug after % attempts',
            v_attempt
            USING ERRCODE = '40P01';
        END IF;
    END;
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public.generate_referral_code(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.generate_referral_code(uuid) TO authenticated;

COMMIT;

-- Verification: confirm the guard now references user_practice_ids().
SELECT 'guard_relaxed' AS check, COUNT(*) AS n
  FROM pg_proc p
  JOIN pg_namespace n ON p.pronamespace = n.oid
 WHERE n.nspname = 'public'
   AND p.proname = 'generate_referral_code'
   AND pg_get_functiondef(p.oid) LIKE '%user_practice_ids%'
   AND pg_get_functiondef(p.oid) NOT LIKE '%user_is_practice_owner%';
