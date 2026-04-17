-- homefit.studio / TrainMe — Supabase Schema (canonical fresh-install)
-- =============================================================================
-- Source of truth for what a FRESH database should look like. Carl runs this
-- manually in the Supabase SQL Editor. Existing databases migrate via the
-- dated `schema_*.sql` files (e.g. `schema_hardening.sql`,
-- `schema_milestone_a.sql`) which are idempotent and layer on top.
--
-- Order (fresh install): run this file top-to-bottom. Everything below is
-- CREATE-if-missing so re-runs are safe, EXCEPT the two DROPs at the top,
-- which only fire on a true from-scratch rebuild.
-- =============================================================================

-- WARNING: These drops wipe data. Only run on fresh/POV databases.
DROP TABLE IF EXISTS plan_issuances CASCADE;
DROP TABLE IF EXISTS credit_ledger CASCADE;
DROP TABLE IF EXISTS practice_members CASCADE;
DROP TABLE IF EXISTS practices CASCADE;
DROP TABLE IF EXISTS exercises CASCADE;
DROP TABLE IF EXISTS plans CASCADE;

-- ============================================================================
-- Practices — top-level tenant / billing boundary (Milestone A)
-- ============================================================================
CREATE TABLE practices (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name              text NOT NULL,
  -- Owner trainer. FK added in Milestone B once a trainers table exists.
  owner_trainer_id  uuid,
  created_at        timestamptz NOT NULL DEFAULT now()
);

-- Which trainers belong to which practice, and in what role.
CREATE TABLE practice_members (
  practice_id  uuid NOT NULL REFERENCES practices(id) ON DELETE CASCADE,
  trainer_id   uuid NOT NULL, -- FK added in Milestone B
  role         text NOT NULL CHECK (role IN ('owner', 'practitioner')),
  joined_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (practice_id, trainer_id)
);

-- ============================================================================
-- Plans — one record per sent exercise plan
-- ============================================================================
CREATE TABLE plans (
  id                              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_name                     text NOT NULL,
  title                           text,
  circuit_cycles                  jsonb DEFAULT '{}',
  preferred_rest_interval_seconds integer,
  exercise_count                  integer,
  version                         integer NOT NULL DEFAULT 1,
  -- Tenant / billing link (Milestone A). Nullable for now; becomes NOT NULL
  -- in Milestone C once every publish path stamps it.
  practice_id                     uuid REFERENCES practices(id),
  -- Set by the web player on first fetch via get_plan_full RPC. Drives the
  -- future publish-lock rule (Milestone C/D).
  first_opened_at                 timestamptz,
  created_at                      timestamptz DEFAULT now(),
  sent_at                         timestamptz DEFAULT now()
);

CREATE INDEX idx_plans_practice ON plans (practice_id);

-- ============================================================================
-- Exercises — ordered exercises within a plan
-- ============================================================================
CREATE TABLE exercises (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_id                  uuid NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
  position                 integer NOT NULL,
  name                     text,
  media_url                text,
  thumbnail_url            text,
  media_type               text NOT NULL CHECK (media_type IN ('photo', 'video', 'rest')),
  reps                     integer,
  sets                     integer,
  hold_seconds             integer,
  notes                    text,
  circuit_id               text,
  include_audio            boolean DEFAULT false,
  custom_duration_seconds  integer,
  created_at               timestamptz DEFAULT now(),
  CONSTRAINT exercises_plan_id_position_unique UNIQUE (plan_id, position)
    DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX idx_exercises_plan ON exercises (plan_id, position);

-- ============================================================================
-- Credit ledger — append-only, balance = SUM(delta) (Milestone A)
-- ============================================================================
CREATE TABLE credit_ledger (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  practice_id         uuid NOT NULL REFERENCES practices(id) ON DELETE CASCADE,
  delta               integer NOT NULL,
  type                text NOT NULL CHECK (type IN ('purchase', 'consumption', 'refund', 'adjustment')),
  plan_id             uuid REFERENCES plans(id) ON DELETE SET NULL,
  payfast_payment_id  text,
  notes               text,
  created_at          timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_credit_ledger_practice_created
  ON credit_ledger (practice_id, created_at DESC);

-- ============================================================================
-- Plan issuances — append-only publish audit (Milestone A)
-- ============================================================================
CREATE TABLE plan_issuances (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_id          uuid NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
  practice_id      uuid NOT NULL REFERENCES practices(id),
  trainer_id       uuid NOT NULL, -- FK added in Milestone B
  version          integer NOT NULL,
  exercise_count   integer NOT NULL,
  credits_charged  integer NOT NULL,
  issued_at        timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_plan_issuances_practice_issued
  ON plan_issuances (practice_id, issued_at DESC);

-- ============================================================================
-- Functions
-- ============================================================================

-- Cheap balance read for a practice.
CREATE OR REPLACE FUNCTION public.practice_credit_balance(p_practice_id uuid)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(SUM(delta), 0)::integer
    FROM credit_ledger
   WHERE practice_id = p_practice_id;
$$;

GRANT EXECUTE ON FUNCTION public.practice_credit_balance(uuid) TO anon, authenticated;

-- Read-by-id RPC for the web player. Also stamps `first_opened_at` on first
-- fetch (atomic UPDATE RETURNING). Later fetches leave the column untouched.
CREATE OR REPLACE FUNCTION public.get_plan_full(plan_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  plan_row  plans;
  exes      jsonb;
BEGIN
  UPDATE plans
     SET first_opened_at = now()
   WHERE id = plan_id
     AND first_opened_at IS NULL
  RETURNING * INTO plan_row;

  IF plan_row IS NULL THEN
    SELECT * INTO plan_row FROM plans WHERE id = plan_id LIMIT 1;
  END IF;

  IF plan_row IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(e) ORDER BY e.position), '[]'::jsonb)
    INTO exes
    FROM exercises e
   WHERE e.plan_id = plan_id;

  RETURN jsonb_build_object(
    'plan',      to_jsonb(plan_row),
    'exercises', exes
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_plan_full(uuid) TO anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.get_plan_full(uuid) FROM public;

-- ============================================================================
-- Row Level Security — POV posture (permissive).
-- Milestone D tightens these to per-practice policies once auth.uid() is wired.
-- ============================================================================
ALTER TABLE plans             ENABLE ROW LEVEL SECURITY;
ALTER TABLE exercises         ENABLE ROW LEVEL SECURITY;
ALTER TABLE practices         ENABLE ROW LEVEL SECURITY;
ALTER TABLE practice_members  ENABLE ROW LEVEL SECURITY;
ALTER TABLE credit_ledger     ENABLE ROW LEVEL SECURITY;
ALTER TABLE plan_issuances    ENABLE ROW LEVEL SECURITY;

-- Anon can do everything on plans/exercises. This is the POV "security by
-- unguessable UUID" trust model and is superseded by schema_hardening.sql.
CREATE POLICY "Public read plans"       ON plans       FOR SELECT USING (true);
CREATE POLICY "Public insert plans"     ON plans       FOR INSERT WITH CHECK (true);
CREATE POLICY "Public update plans"     ON plans       FOR UPDATE USING (true);
CREATE POLICY "Public read exercises"   ON exercises   FOR SELECT USING (true);
CREATE POLICY "Public insert exercises" ON exercises   FOR INSERT WITH CHECK (true);
CREATE POLICY "Public delete exercises" ON exercises   FOR DELETE USING (true);

-- New tables get the same permissive policy for Milestone A.
CREATE POLICY pov_all ON practices        FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY pov_all ON practice_members FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY pov_all ON credit_ledger    FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY pov_all ON plan_issuances   FOR ALL USING (true) WITH CHECK (true);

-- ============================================================================
-- Storage bucket (run separately in Supabase dashboard or via SQL)
-- ============================================================================
-- INSERT INTO storage.buckets (id, name, public) VALUES ('media', 'media', true)
-- ON CONFLICT (id) DO NOTHING;
--
-- Storage RLS policies:
-- CREATE POLICY "Public read media"   ON storage.objects FOR SELECT USING (bucket_id = 'media');
-- CREATE POLICY "Public upload media" ON storage.objects FOR INSERT WITH CHECK (bucket_id = 'media');
