-- ============================================================================
-- Milestone S — share_events append-only analytics table (Wave 10 Phase 3)
-- ============================================================================
--
-- WHY
--   The portal `/network` page offers practitioners four channels to share
--   their referral code with colleagues: WhatsApp one-to-one, WhatsApp
--   status/broadcast, Email, and the new PNG share card (Phase 3). Each
--   channel has at least two actions (copy-to-clipboard + native-intent
--   launch; plus PNG download + image-clipboard-write). We need a
--   telemetry trail so:
--
--     * Future waves (Wave 12+ "Share-funnel dashboard") can show the
--       practitioner which channels they've used + conversion rates.
--     * Carl can measure which templates drive real referrals vs. which
--       feel good but don't move the needle (A/B fodder).
--     * Silent failures on the clipboard / download path get an
--       observability hook — if we ever see 0 `download` events for a
--       week we know the button's broken, not "nobody used it".
--
--   The existing `plan_issuances` and `credit_ledger` tables cover
--   publish + billing. `share_events` covers the top-of-funnel (the
--   practitioner's sharing activity, not the eventual conversion).
--
-- WHAT THIS MIGRATION DOES
--   1. Creates `public.share_events` — append-only, one row per share
--      action. `practice_id` is required (every event lives in a tenant);
--      `trainer_id` is FK to auth.users (nullable; SET NULL so user-
--      deletion doesn't cascade-destroy telemetry). `channel` + `event_kind`
--      are CHECK'd enums; `meta` is a free-form jsonb for future expansion
--      (e.g. template-variant for A/B, colleague-name-substituted flag).
--   2. Index on `(practice_id, occurred_at DESC)` for the dashboard query
--      pattern ("show me this practice's share activity, newest first").
--   3. RLS enabled + SELECT policy scoped via `user_practice_ids()` — the
--      same helper milestone C introduced to avoid recursive policy
--      subqueries on `practice_members`.
--   4. SECURITY DEFINER RPC `log_share_event(practice, channel, kind, meta)`
--      — the single enumerated write path. The RPC inserts with
--      `auth.uid()` as `trainer_id`, checks membership via
--      `user_practice_ids()`, and returns the new row's id.
--   5. No INSERT grant to authenticated/anon — mirrors the Milestone E
--      lockdown of `credit_ledger`. RLS policies for INSERT/UPDATE/DELETE
--      are intentionally absent; the RPC is the only write path.
--
-- WHAT THIS MIGRATION DOES *NOT* DO
--   * No `list_share_events` RPC yet — the SELECT policy + direct table
--     reads cover the Wave 12+ dashboard. If that dashboard needs rollups
--     / joins, introduce a dedicated RPC then.
--   * No retention policy. Append-only. Revisit if row count grows past
--     a few million; until then, disk is cheap and history is useful.
--   * No foreign key to `referral_codes` — the event doesn't have to be
--     tied to a specific code revision. The code string lives in `meta`
--     if a caller wants it (nullable for non-code channels).
--
-- IDEMPOTENT
--   Every statement uses IF NOT EXISTS / CREATE OR REPLACE / DROP POLICY
--   IF EXISTS. Safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Table
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.share_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  practice_id UUID NOT NULL REFERENCES public.practices(id) ON DELETE CASCADE,
  trainer_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  channel TEXT NOT NULL CHECK (channel IN (
    'whatsapp_one_to_one',
    'whatsapp_broadcast',
    'email',
    'png_download',
    'png_clipboard',
    'tagline_copy',
    'code_copy',
    'link_copy'
  )),
  event_kind TEXT NOT NULL CHECK (event_kind IN (
    'copy',
    'open_intent',
    'download',
    'clipboard_image'
  )),
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  meta JSONB
);

COMMENT ON TABLE public.share_events IS
  'Append-only log of practitioner share-card actions (copy, open-intent, '
  'download, clipboard-image). Populated via log_share_event() RPC; never '
  'written directly by clients. See supabase/schema_milestone_s_share_events.sql.';

COMMENT ON COLUMN public.share_events.channel IS
  'Which share surface triggered the event. whatsapp_one_to_one = 1:1 card; '
  'whatsapp_broadcast = status/broadcast card; email = email card; '
  'png_download = downloadable PNG card (binary file emitted); '
  'png_clipboard = downloadable PNG card (image blob to clipboard); '
  'tagline_copy = below-PNG tagline-helper row; '
  'code_copy = hero code badge; link_copy = full referral URL.';

COMMENT ON COLUMN public.share_events.event_kind IS
  'The action taken. copy = text-to-clipboard; open_intent = wa.me/mailto '
  'launch; download = binary file save; clipboard_image = image blob to clipboard.';

-- ---------------------------------------------------------------------------
-- 2. Index for the dashboard query pattern
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_share_events_practice_ts
  ON public.share_events(practice_id, occurred_at DESC);

-- ---------------------------------------------------------------------------
-- 3. RLS + SELECT policy
-- ---------------------------------------------------------------------------
ALTER TABLE public.share_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS share_events_select_own ON public.share_events;
CREATE POLICY share_events_select_own ON public.share_events
  FOR SELECT TO authenticated
  USING (practice_id IN (SELECT public.user_practice_ids()));

-- No INSERT/UPDATE/DELETE policies — the table is RPC-write-only.
-- The authenticated/anon roles don't need a direct INSERT grant either;
-- log_share_event() runs SECURITY DEFINER as owner postgres so it bypasses
-- both RLS and per-role grants.

-- Explicit REVOKE on writes is belt-and-braces; the absence of both a
-- grant and a policy is already enough, but an explicit revoke keeps the
-- "RPC-only writes" invariant obvious on inspection.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.share_events FROM authenticated, anon;

-- SELECT grant for authenticated (policy above scopes the rows).
GRANT SELECT ON public.share_events TO authenticated;

-- anon never touches analytics — web player is anon and has no business
-- knowing about the portal's share activity.
REVOKE SELECT ON public.share_events FROM anon;

-- ---------------------------------------------------------------------------
-- 4. log_share_event RPC — the single write path
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.log_share_event(
  p_practice_id UUID,
  p_channel TEXT,
  p_event_kind TEXT,
  p_meta JSONB DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id UUID;
BEGIN
  -- Membership check — mirror the pattern used by consume_credit and the
  -- client CRUD RPCs. Practitioner must belong to the practice they're
  -- logging events against.
  IF NOT (p_practice_id IN (SELECT public.user_practice_ids())) THEN
    RAISE EXCEPTION 'not a member of practice %', p_practice_id
      USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.share_events(
    practice_id, trainer_id, channel, event_kind, meta
  )
  VALUES (
    p_practice_id, auth.uid(), p_channel, p_event_kind, p_meta
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

COMMENT ON FUNCTION public.log_share_event(UUID, TEXT, TEXT, JSONB) IS
  'Append a share_events row. Single enumerated write path (no INSERT grant '
  'on the underlying table). Membership-gated via user_practice_ids(). '
  'Channel + event_kind are CHECK-constrained on the table; bad values '
  'return a 23514 check_violation. Called fire-and-forget from the portal '
  '/network share components.';

-- Lock down to authenticated only — anon has no business logging share
-- events (they'd fail the auth.uid() check anyway, but explicit is better).
REVOKE EXECUTE ON FUNCTION public.log_share_event(UUID, TEXT, TEXT, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.log_share_event(UUID, TEXT, TEXT, JSONB) TO authenticated;

-- ---------------------------------------------------------------------------
-- 5. Verification (prints to apply output)
-- ---------------------------------------------------------------------------
-- Expect one row: share_events with rowsecurity = true.
SELECT tablename, rowsecurity
  FROM pg_tables
 WHERE schemaname = 'public'
   AND tablename = 'share_events';

-- Expect zero rows initially (fresh table).
SELECT count(*) AS initial_row_count FROM public.share_events;

-- Expect one policy: share_events_select_own on share_events, FOR SELECT.
SELECT policyname, cmd
  FROM pg_policies
 WHERE schemaname = 'public'
   AND tablename = 'share_events';

-- Expect EXECUTE granted to authenticated on log_share_event.
SELECT routine_name, grantee, privilege_type
  FROM information_schema.routine_privileges
 WHERE routine_schema = 'public'
   AND routine_name = 'log_share_event'
   AND grantee IN ('authenticated', 'anon')
 ORDER BY grantee, privilege_type;
