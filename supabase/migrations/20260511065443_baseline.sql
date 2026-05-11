-- ============================================================================
-- homefit.studio baseline schema migration
-- ============================================================================
-- Authored 2026-05-11 by introspecting live prod (Supabase project yrwcofhovrcydootivjx).
-- This single migration reproduces the current public-schema state and replaces
-- the ad-hoc supabase/schema_*.sql files for Supabase Branching adoption.
--
-- Source of truth: live PROD as of 2026-05-11. Where the existing schema_*.sql
-- files disagree with live (per the schema-migration-column-preservation memory),
-- LIVE WINS. Any cosmetic drift (e.g. helper-fn signatures that were hotfixed
-- outside the source files) is preserved as-is from pg_get_functiondef.
--
-- Scope of this file:
--   - public-schema tables, columns, defaults, constraints, indexes
--   - public-schema functions (110 total — 65 ours + 45 from the citext extension
--     re-published into public; the extension creates those, so this file does NOT
--     re-create them — CREATE EXTENSION citext does it for us)
--   - one public-schema view (publish_health)
--   - one public-schema enum (referral_rebate_kind)
--   - three triggers
--   - RLS enable + 36 policies
--   - table grants (the credit_ledger / referral_* lockdown pattern is preserved)
--   - function ACLs (sign_storage_url stays service-role only; consume_credit etc.
--     keep their explicit GRANT EXECUTE TO authenticated)
--
-- NOT in scope (Supabase-managed or out-of-band):
--   - auth.* schema (Supabase Auth owns it)
--   - storage.* schema and storage bucket DDL (apply via Storage API per env)
--   - data rows
--   - vault secret values (see Section 9 for the manual post-apply step)
--
-- Apply order: extensions -> types -> tables -> constraints -> indexes ->
--              functions -> triggers -> view -> RLS -> policies -> grants -> ACLs
--
-- Wrapped in a single transaction. If any statement fails the whole thing rolls back.
-- ============================================================================

BEGIN;

-- ============================================================================
-- Section 1: Extensions
-- ============================================================================
-- Note: Supabase preinstalls pgcrypto, pgjwt, supabase_vault, uuid-ossp,
-- pg_stat_statements in their normal schemas. The only public-schema extension
-- we depend on is citext (for pending_practice_members.email case-insensitive).
CREATE EXTENSION IF NOT EXISTS "citext" WITH SCHEMA "public";
CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";
CREATE EXTENSION IF NOT EXISTS "pgjwt" WITH SCHEMA "extensions";
CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";

-- ============================================================================
-- Section 2: Custom types
-- ============================================================================
CREATE TYPE "public"."referral_rebate_kind" AS ENUM ('signup_bonus_referrer', 'signup_bonus_referee', 'lifetime_rebate', 'redeemed');

-- ============================================================================
-- Section 3: Tables
-- ============================================================================
-- Ordered by FK dependency: parents before children.

CREATE TABLE "public"."practices" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL,
    "name" text NOT NULL,
    "owner_trainer_id" uuid,
    "created_at" timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT "practices_pkey" PRIMARY KEY (id)
);

CREATE TABLE "public"."practice_members" (
    "practice_id" uuid NOT NULL,
    "trainer_id" uuid NOT NULL,
    "role" text NOT NULL,
    "joined_at" timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT "practice_members_pkey" PRIMARY KEY (practice_id, trainer_id),
    CONSTRAINT "practice_members_role_check" CHECK ((role = ANY (ARRAY['owner'::text, 'practitioner'::text])))
);

CREATE TABLE "public"."pending_practice_members" (
    "email" public.citext NOT NULL,
    "practice_id" uuid NOT NULL,
    "added_by" uuid,
    "added_at" timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT "pending_practice_members_pkey" PRIMARY KEY (email, practice_id)
);

CREATE TABLE "public"."clients" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL,
    "practice_id" uuid NOT NULL,
    "name" text NOT NULL,
    "video_consent" jsonb DEFAULT '{"avatar": false, "original": false, "grayscale": false, "line_drawing": true}'::jsonb NOT NULL,
    "created_at" timestamp with time zone DEFAULT now() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
    "deleted_at" timestamp with time zone,
    "client_exercise_defaults" jsonb DEFAULT '{}'::jsonb NOT NULL,
    "consent_confirmed_at" timestamp with time zone,
    "avatar_path" text,
    "created_by_user_id" uuid,
    "deleted_by_user_id" uuid,
    CONSTRAINT "clients_pkey" PRIMARY KEY (id),
    CONSTRAINT "clients_practice_name_unique" UNIQUE (practice_id, name)
);

CREATE TABLE "public"."plans" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL,
    "client_name" text NOT NULL,
    "title" text,
    "circuit_cycles" jsonb DEFAULT '{}'::jsonb,
    "preferred_rest_interval_seconds" integer,
    "exercise_count" integer,
    "created_at" timestamp with time zone DEFAULT now(),
    "sent_at" timestamp with time zone DEFAULT now(),
    "version" integer DEFAULT 1 NOT NULL,
    "practice_id" uuid,
    "first_opened_at" timestamp with time zone,
    "client_id" uuid,
    "deleted_at" timestamp with time zone,
    "crossfade_lead_ms" smallint,
    "crossfade_fade_ms" smallint,
    "unlock_credit_prepaid_at" timestamp with time zone,
    "last_opened_at" timestamp with time zone,
    "circuit_names" jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT "plans_pkey" PRIMARY KEY (id)
);

CREATE TABLE "public"."exercises" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL,
    "plan_id" uuid NOT NULL,
    "position" integer NOT NULL,
    "name" text,
    "media_url" text,
    "thumbnail_url" text,
    "media_type" text NOT NULL,
    "notes" text,
    "circuit_id" text,
    "include_audio" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT now(),
    "preferred_treatment" text,
    "prep_seconds" integer,
    "start_offset_ms" integer,
    "end_offset_ms" integer,
    "video_reps_per_loop" integer,
    "aspect_ratio" numeric,
    "rotation_quarters" smallint DEFAULT 0,
    "body_focus" boolean,
    "rest_seconds" integer,
    "focus_frame_offset_ms" integer,
    "hero_crop_offset" numeric,
    CONSTRAINT "exercises_pkey" PRIMARY KEY (id),
    CONSTRAINT "exercises_plan_id_position_unique" UNIQUE (plan_id, "position") DEFERRABLE INITIALLY DEFERRED,
    CONSTRAINT "exercises_end_offset_ms_check" CHECK (((end_offset_ms IS NULL) OR (end_offset_ms >= 0))),
    CONSTRAINT "exercises_media_type_check" CHECK ((media_type = ANY (ARRAY['photo'::text, 'video'::text, 'rest'::text]))),
    CONSTRAINT "exercises_preferred_treatment_check" CHECK (((preferred_treatment IS NULL) OR (preferred_treatment = ANY (ARRAY['line'::text, 'grayscale'::text, 'original'::text])))),
    CONSTRAINT "exercises_prep_seconds_check" CHECK (((prep_seconds IS NULL) OR (prep_seconds > 0))),
    CONSTRAINT "exercises_rotation_quarters_check" CHECK (((rotation_quarters IS NULL) OR ((rotation_quarters >= 0) AND (rotation_quarters <= 3)))),
    CONSTRAINT "exercises_start_offset_ms_check" CHECK (((start_offset_ms IS NULL) OR (start_offset_ms >= 0))),
    CONSTRAINT "exercises_video_reps_per_loop_check" CHECK (((video_reps_per_loop IS NULL) OR (video_reps_per_loop > 0)))
);

CREATE TABLE "public"."exercise_sets" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL,
    "exercise_id" uuid NOT NULL,
    "position" integer NOT NULL,
    "reps" integer NOT NULL,
    "hold_seconds" integer DEFAULT 0 NOT NULL,
    "weight_kg" numeric,
    "breather_seconds_after" integer DEFAULT 60 NOT NULL,
    "created_at" timestamp with time zone DEFAULT now() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
    "hold_position" text DEFAULT 'end_of_set'::text NOT NULL,
    CONSTRAINT "exercise_sets_pkey" PRIMARY KEY (id),
    CONSTRAINT "exercise_sets_unique_position" UNIQUE (exercise_id, "position"),
    CONSTRAINT "exercise_sets_breather_nonneg" CHECK ((breather_seconds_after >= 0)),
    CONSTRAINT "exercise_sets_hold_nonneg" CHECK ((hold_seconds >= 0)),
    CONSTRAINT "exercise_sets_hold_position_valid" CHECK ((hold_position = ANY (ARRAY['per_rep'::text, 'end_of_set'::text, 'end_of_exercise'::text]))),
    CONSTRAINT "exercise_sets_position_positive" CHECK (("position" > 0)),
    CONSTRAINT "exercise_sets_reps_positive" CHECK ((reps > 0)),
    CONSTRAINT "exercise_sets_weight_kg_range" CHECK (((weight_kg IS NULL) OR (weight_kg > (0)::numeric)))
);

CREATE TABLE "public"."credit_ledger" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL,
    "practice_id" uuid NOT NULL,
    "delta" integer NOT NULL,
    "type" text NOT NULL,
    "plan_id" uuid,
    "payfast_payment_id" text,
    "notes" text,
    "created_at" timestamp with time zone DEFAULT now() NOT NULL,
    "trainer_id" uuid,
    CONSTRAINT "credit_ledger_pkey" PRIMARY KEY (id),
    CONSTRAINT "credit_ledger_type_check" CHECK ((type = ANY (ARRAY['purchase'::text, 'consumption'::text, 'refund'::text, 'adjustment'::text, 'signup_bonus'::text, 'referral_signup_bonus'::text])))
);

CREATE TABLE "public"."plan_issuances" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL,
    "plan_id" uuid NOT NULL,
    "practice_id" uuid NOT NULL,
    "trainer_id" uuid NOT NULL,
    "version" integer NOT NULL,
    "exercise_count" integer NOT NULL,
    "credits_charged" integer NOT NULL,
    "issued_at" timestamp with time zone DEFAULT now() NOT NULL,
    "prepaid_unlock_at" timestamp with time zone,
    CONSTRAINT "plan_issuances_pkey" PRIMARY KEY (id)
);

CREATE TABLE "public"."pending_payments" (
    "id" uuid NOT NULL,
    "practice_id" uuid NOT NULL,
    "credits" integer NOT NULL,
    "amount_zar" numeric NOT NULL,
    "bundle_key" text,
    "status" text DEFAULT 'pending'::text NOT NULL,
    "pf_payment_id" text,
    "notes" text,
    "created_at" timestamp with time zone DEFAULT now() NOT NULL,
    "completed_at" timestamp with time zone,
    CONSTRAINT "pending_payments_pkey" PRIMARY KEY (id),
    CONSTRAINT "pending_payments_amount_zar_check" CHECK ((amount_zar > (0)::numeric)),
    CONSTRAINT "pending_payments_credits_check" CHECK ((credits > 0)),
    CONSTRAINT "pending_payments_status_check" CHECK ((status = ANY (ARRAY['pending'::text, 'complete'::text, 'cancelled'::text, 'failed'::text])))
);

CREATE TABLE "public"."referral_codes" (
    "practice_id" uuid NOT NULL,
    "code" text NOT NULL,
    "created_at" timestamp with time zone DEFAULT now() NOT NULL,
    "revoked_at" timestamp with time zone,
    CONSTRAINT "referral_codes_code_key" UNIQUE (code),
    CONSTRAINT "referral_codes_pkey" PRIMARY KEY (practice_id),
    CONSTRAINT "referral_codes_code_check" CHECK (((length(code) = 7) AND (code ~ '^[a-hjkmnpqrstuvwxyz2-9]+$'::text)))
);

CREATE TABLE "public"."practice_referrals" (
    "referee_practice_id" uuid NOT NULL,
    "referrer_practice_id" uuid NOT NULL,
    "code_used" text NOT NULL,
    "claimed_at" timestamp with time zone DEFAULT now() NOT NULL,
    "signup_bonus_paid_at" timestamp with time zone,
    "referee_named_consent" boolean DEFAULT false NOT NULL,
    "goodwill_floor_applied" boolean DEFAULT false NOT NULL,
    CONSTRAINT "practice_referrals_pkey" PRIMARY KEY (referee_practice_id),
    CONSTRAINT "practice_referrals_check" CHECK ((referrer_practice_id <> referee_practice_id))
);

CREATE TABLE "public"."referral_rebate_ledger" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL,
    "referrer_practice_id" uuid NOT NULL,
    "referee_practice_id" uuid,
    "source_credit_ledger_id" uuid,
    "kind" public.referral_rebate_kind NOT NULL,
    "credits" numeric NOT NULL,
    "zar_amount" numeric,
    "created_at" timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT "referral_rebate_ledger_pkey" PRIMARY KEY (id),
    CONSTRAINT "referral_rebate_ledger_check" CHECK ((((kind = 'redeemed'::referral_rebate_kind) AND (credits < (0)::numeric)) OR ((kind <> 'redeemed'::referral_rebate_kind) AND (credits > (0)::numeric))))
);

CREATE TABLE "public"."audit_events" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL,
    "ts" timestamp with time zone DEFAULT now() NOT NULL,
    "practice_id" uuid NOT NULL,
    "actor_id" uuid,
    "kind" text NOT NULL,
    "ref_id" uuid,
    "meta" jsonb,
    CONSTRAINT "audit_events_pkey" PRIMARY KEY (id),
    CONSTRAINT "audit_events_kind_nonempty" CHECK ((length(kind) > 0))
);

CREATE TABLE "public"."share_events" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL,
    "practice_id" uuid NOT NULL,
    "trainer_id" uuid,
    "channel" text NOT NULL,
    "event_kind" text NOT NULL,
    "occurred_at" timestamp with time zone DEFAULT now() NOT NULL,
    "meta" jsonb,
    CONSTRAINT "share_events_pkey" PRIMARY KEY (id),
    CONSTRAINT "share_events_channel_check" CHECK ((channel = ANY (ARRAY['whatsapp_one_to_one'::text, 'whatsapp_broadcast'::text, 'email'::text, 'png_download'::text, 'png_clipboard'::text, 'tagline_copy'::text, 'code_copy'::text, 'link_copy'::text]))),
    CONSTRAINT "share_events_event_kind_check" CHECK ((event_kind = ANY (ARRAY['copy'::text, 'open_intent'::text, 'download'::text, 'clipboard_image'::text])))
);

CREATE TABLE "public"."error_logs" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL,
    "ts" timestamp with time zone DEFAULT now() NOT NULL,
    "practice_id" uuid,
    "trainer_id" uuid,
    "severity" text NOT NULL,
    "kind" text NOT NULL,
    "source" text NOT NULL,
    "message" text,
    "meta" jsonb,
    "sha" text,
    CONSTRAINT "error_logs_pkey" PRIMARY KEY (id),
    CONSTRAINT "error_logs_severity_check" CHECK ((severity = ANY (ARRAY['warn'::text, 'error'::text, 'fatal'::text])))
);

CREATE TABLE "public"."client_sessions" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL,
    "plan_id" uuid NOT NULL,
    "opened_at" timestamp with time zone DEFAULT now() NOT NULL,
    "user_agent_bucket" text,
    "consent_granted" boolean DEFAULT false NOT NULL,
    "consent_decided_at" timestamp with time zone,
    CONSTRAINT "client_sessions_pkey" PRIMARY KEY (id)
);

CREATE TABLE "public"."plan_analytics_events" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL,
    "client_session_id" uuid NOT NULL,
    "event_kind" text NOT NULL,
    "exercise_id" uuid,
    "event_data" jsonb,
    "occurred_at" timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT "plan_analytics_events_pkey" PRIMARY KEY (id),
    CONSTRAINT "plan_analytics_events_event_kind_check" CHECK ((event_kind = ANY (ARRAY['plan_opened'::text, 'plan_completed'::text, 'plan_closed'::text, 'exercise_viewed'::text, 'exercise_completed'::text, 'exercise_skipped'::text, 'exercise_replayed'::text, 'treatment_switched'::text, 'pause_tapped'::text, 'resume_tapped'::text, 'rest_shortened'::text, 'rest_extended'::text, 'exercise_navigation_jump'::text])))
);

CREATE TABLE "public"."plan_analytics_daily_aggregate" (
    "plan_id" uuid NOT NULL,
    "exercise_id" uuid,
    "day" date NOT NULL,
    "opens" integer DEFAULT 0 NOT NULL,
    "completions" integer DEFAULT 0 NOT NULL,
    "total_elapsed_ms" bigint DEFAULT 0 NOT NULL,
    "exercise_completes" integer DEFAULT 0 NOT NULL,
    "exercise_skips" integer DEFAULT 0 NOT NULL,
    "treatment_switches" integer DEFAULT 0 NOT NULL
);

CREATE TABLE "public"."plan_analytics_opt_outs" (
    "plan_id" uuid NOT NULL,
    "opted_out_at" timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT "plan_analytics_opt_outs_pkey" PRIMARY KEY (plan_id)
);

-- ============================================================================
-- Section 4: Foreign keys
-- ============================================================================
-- Applied after all tables exist so cyclical refs (and forward refs) work.

ALTER TABLE "public"."practice_members" ADD CONSTRAINT "practice_members_practice_id_fkey" FOREIGN KEY (practice_id) REFERENCES practices(id) ON DELETE CASCADE;
ALTER TABLE "public"."pending_practice_members" ADD CONSTRAINT "pending_practice_members_added_by_fkey" FOREIGN KEY (added_by) REFERENCES auth.users(id) ON DELETE SET NULL;
ALTER TABLE "public"."pending_practice_members" ADD CONSTRAINT "pending_practice_members_practice_id_fkey" FOREIGN KEY (practice_id) REFERENCES practices(id) ON DELETE CASCADE;
ALTER TABLE "public"."clients" ADD CONSTRAINT "clients_practice_id_fkey" FOREIGN KEY (practice_id) REFERENCES practices(id) ON DELETE CASCADE;
ALTER TABLE "public"."plans" ADD CONSTRAINT "plans_client_id_fkey" FOREIGN KEY (client_id) REFERENCES clients(id) ON DELETE SET NULL;
ALTER TABLE "public"."plans" ADD CONSTRAINT "plans_practice_id_fkey" FOREIGN KEY (practice_id) REFERENCES practices(id);
ALTER TABLE "public"."exercises" ADD CONSTRAINT "exercises_plan_id_fkey" FOREIGN KEY (plan_id) REFERENCES plans(id) ON DELETE CASCADE;
ALTER TABLE "public"."exercise_sets" ADD CONSTRAINT "exercise_sets_exercise_id_fkey" FOREIGN KEY (exercise_id) REFERENCES exercises(id) ON DELETE CASCADE;
ALTER TABLE "public"."credit_ledger" ADD CONSTRAINT "credit_ledger_plan_id_fkey" FOREIGN KEY (plan_id) REFERENCES plans(id) ON DELETE SET NULL;
ALTER TABLE "public"."credit_ledger" ADD CONSTRAINT "credit_ledger_practice_id_fkey" FOREIGN KEY (practice_id) REFERENCES practices(id) ON DELETE CASCADE;
ALTER TABLE "public"."plan_issuances" ADD CONSTRAINT "plan_issuances_plan_id_fkey" FOREIGN KEY (plan_id) REFERENCES plans(id) ON DELETE CASCADE;
ALTER TABLE "public"."plan_issuances" ADD CONSTRAINT "plan_issuances_practice_id_fkey" FOREIGN KEY (practice_id) REFERENCES practices(id);
ALTER TABLE "public"."pending_payments" ADD CONSTRAINT "pending_payments_practice_id_fkey" FOREIGN KEY (practice_id) REFERENCES practices(id) ON DELETE CASCADE;
ALTER TABLE "public"."referral_codes" ADD CONSTRAINT "referral_codes_practice_id_fkey" FOREIGN KEY (practice_id) REFERENCES practices(id) ON DELETE CASCADE;
ALTER TABLE "public"."practice_referrals" ADD CONSTRAINT "practice_referrals_referee_practice_id_fkey" FOREIGN KEY (referee_practice_id) REFERENCES practices(id) ON DELETE CASCADE;
ALTER TABLE "public"."practice_referrals" ADD CONSTRAINT "practice_referrals_referrer_practice_id_fkey" FOREIGN KEY (referrer_practice_id) REFERENCES practices(id) ON DELETE RESTRICT;
ALTER TABLE "public"."referral_rebate_ledger" ADD CONSTRAINT "referral_rebate_ledger_referee_practice_id_fkey" FOREIGN KEY (referee_practice_id) REFERENCES practices(id) ON DELETE SET NULL;
ALTER TABLE "public"."referral_rebate_ledger" ADD CONSTRAINT "referral_rebate_ledger_referrer_practice_id_fkey" FOREIGN KEY (referrer_practice_id) REFERENCES practices(id) ON DELETE CASCADE;
ALTER TABLE "public"."referral_rebate_ledger" ADD CONSTRAINT "referral_rebate_ledger_source_credit_ledger_id_fkey" FOREIGN KEY (source_credit_ledger_id) REFERENCES credit_ledger(id) ON DELETE SET NULL;
ALTER TABLE "public"."audit_events" ADD CONSTRAINT "audit_events_actor_id_fkey" FOREIGN KEY (actor_id) REFERENCES auth.users(id) ON DELETE SET NULL;
ALTER TABLE "public"."audit_events" ADD CONSTRAINT "audit_events_practice_id_fkey" FOREIGN KEY (practice_id) REFERENCES practices(id) ON DELETE CASCADE;
ALTER TABLE "public"."share_events" ADD CONSTRAINT "share_events_practice_id_fkey" FOREIGN KEY (practice_id) REFERENCES practices(id) ON DELETE CASCADE;
ALTER TABLE "public"."share_events" ADD CONSTRAINT "share_events_trainer_id_fkey" FOREIGN KEY (trainer_id) REFERENCES auth.users(id) ON DELETE SET NULL;
ALTER TABLE "public"."error_logs" ADD CONSTRAINT "error_logs_practice_id_fkey" FOREIGN KEY (practice_id) REFERENCES practices(id) ON DELETE SET NULL;
ALTER TABLE "public"."error_logs" ADD CONSTRAINT "error_logs_trainer_id_fkey" FOREIGN KEY (trainer_id) REFERENCES auth.users(id) ON DELETE SET NULL;
ALTER TABLE "public"."client_sessions" ADD CONSTRAINT "client_sessions_plan_id_fkey" FOREIGN KEY (plan_id) REFERENCES plans(id) ON DELETE CASCADE;
ALTER TABLE "public"."plan_analytics_events" ADD CONSTRAINT "plan_analytics_events_client_session_id_fkey" FOREIGN KEY (client_session_id) REFERENCES client_sessions(id) ON DELETE CASCADE;
ALTER TABLE "public"."plan_analytics_daily_aggregate" ADD CONSTRAINT "plan_analytics_daily_aggregate_plan_id_fkey" FOREIGN KEY (plan_id) REFERENCES plans(id) ON DELETE CASCADE;
ALTER TABLE "public"."plan_analytics_opt_outs" ADD CONSTRAINT "plan_analytics_opt_outs_plan_id_fkey" FOREIGN KEY (plan_id) REFERENCES plans(id) ON DELETE CASCADE;

-- ============================================================================
-- Section 5: Indexes
-- ============================================================================
-- Excludes PK/UNIQUE constraint-backed indexes (already created by the table DDL).

CREATE INDEX idx_audit_events_actor ON public.audit_events USING btree (actor_id);
CREATE INDEX idx_audit_events_practice_ts ON public.audit_events USING btree (practice_id, ts DESC);
CREATE INDEX idx_client_sessions_plan_opened ON public.client_sessions USING btree (plan_id, opened_at DESC);
CREATE INDEX idx_clients_active ON public.clients USING btree (practice_id) WHERE (deleted_at IS NULL);
CREATE INDEX idx_clients_practice ON public.clients USING btree (practice_id);
CREATE INDEX idx_credit_ledger_plan ON public.credit_ledger USING btree (plan_id) WHERE (plan_id IS NOT NULL);
CREATE INDEX idx_credit_ledger_practice_created ON public.credit_ledger USING btree (practice_id, created_at DESC);
CREATE INDEX idx_error_logs_kind_ts ON public.error_logs USING btree (kind, ts DESC);
CREATE INDEX idx_error_logs_practice_ts ON public.error_logs USING btree (practice_id, ts DESC);
CREATE INDEX idx_exercise_sets_exercise_position ON public.exercise_sets USING btree (exercise_id, "position");
CREATE INDEX idx_exercises_plan ON public.exercises USING btree (plan_id, "position");
CREATE INDEX idx_pending_payments_practice ON public.pending_payments USING btree (practice_id, created_at DESC);
CREATE INDEX idx_pending_payments_status ON public.pending_payments USING btree (status, created_at DESC);
CREATE INDEX idx_pending_practice_members_email ON public.pending_practice_members USING btree (email);
CREATE UNIQUE INDEX idx_plan_analytics_daily_agg_pk ON public.plan_analytics_daily_aggregate USING btree (plan_id, COALESCE(exercise_id, '00000000-0000-0000-0000-000000000000'::uuid), day);
CREATE INDEX idx_plan_analytics_events_kind_occurred ON public.plan_analytics_events USING btree (event_kind, occurred_at DESC);
CREATE INDEX idx_plan_analytics_events_session ON public.plan_analytics_events USING btree (client_session_id, occurred_at);
CREATE INDEX idx_plan_issuances_plan ON public.plan_issuances USING btree (plan_id, issued_at DESC);
CREATE INDEX idx_plan_issuances_practice_issued ON public.plan_issuances USING btree (practice_id, issued_at DESC);
CREATE INDEX idx_plan_issuances_prepaid_unlock ON public.plan_issuances USING btree (plan_id, prepaid_unlock_at) WHERE (prepaid_unlock_at IS NOT NULL);
CREATE INDEX idx_plans_client ON public.plans USING btree (client_id);
CREATE INDEX idx_plans_practice ON public.plans USING btree (practice_id);
CREATE INDEX plans_deleted_at_idx ON public.plans USING btree (deleted_at) WHERE (deleted_at IS NULL);
CREATE INDEX idx_practice_members_trainer ON public.practice_members USING btree (trainer_id);
CREATE INDEX idx_practice_referrals_referrer ON public.practice_referrals USING btree (referrer_practice_id, claimed_at DESC);
CREATE INDEX idx_referral_codes_code ON public.referral_codes USING btree (code) WHERE (revoked_at IS NULL);
CREATE INDEX idx_rebate_ledger_referee ON public.referral_rebate_ledger USING btree (referee_practice_id, created_at DESC) WHERE (referee_practice_id IS NOT NULL);
CREATE INDEX idx_rebate_ledger_referrer ON public.referral_rebate_ledger USING btree (referrer_practice_id, created_at DESC);
CREATE INDEX idx_share_events_practice_ts ON public.share_events USING btree (practice_id, occurred_at DESC);

-- ============================================================================
-- Section 6: Functions
-- ============================================================================
-- Sourced live from pg_get_functiondef. The schema-migration-column-preservation
-- memory's lesson: NEVER author these by copying from supabase/schema_*.sql files —
-- they lag the live DB. Future schema-changing PRs must use `supabase migration new`
-- and either edit the function in a deterministic CREATE OR REPLACE FUNCTION block.
--
-- 65 functions ordered alphabetically (overloads kept together).
-- All citext-extension functions (citext/citext_*/regexp_*/etc.) are owned by the
-- citext extension itself and reappear automatically when CREATE EXTENSION runs.

-- Function: public._clients_touch_updated_at()
CREATE OR REPLACE FUNCTION public._clients_touch_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$function$;

-- Function: public._exercise_sets_touch_updated_at()
CREATE OR REPLACE FUNCTION public._exercise_sets_touch_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$function$;

-- Function: public._generate_slug_7()
CREATE OR REPLACE FUNCTION public._generate_slug_7()
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
  -- 30 unambiguous characters: no i/l/o/0/1.
  v_alphabet constant text := 'abcdefghjkmnpqrstuvwxyz23456789';
  v_out text := '';
  v_i int;
  v_r int;
BEGIN
  FOR v_i IN 1..7 LOOP
    v_r := 1 + floor(random() * length(v_alphabet))::int;
    v_out := v_out || substr(v_alphabet, v_r, 1);
  END LOOP;
  RETURN v_out;
END;
$function$;

-- Function: public.add_practice_member_by_email(p_practice_id uuid, p_email text)
CREATE OR REPLACE FUNCTION public.add_practice_member_by_email(p_practice_id uuid, p_email text)
 RETURNS TABLE(kind text, trainer_id uuid, email text, full_name text, role text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- PL/pgSQL 42702 trap: RETURNS TABLE OUT columns are visible as variables
-- inside the function body, and collide with real table columns of the
-- same name inside INSERT / ON CONFLICT / UPDATE targets
-- (pending_practice_members.email, practice_members.role, etc.).
-- `#variable_conflict use_column` tells the parser to resolve ambiguous
-- names to the TABLE column first. Same class of bug the delete_client
-- hotfix hit (Milestone L).
#variable_conflict use_column
DECLARE
  v_caller uuid := auth.uid();
  v_clean  citext;
  v_user   auth.users%rowtype;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'auth required' USING ERRCODE = '28000';
  END IF;

  IF NOT public.user_is_practice_owner(p_practice_id) THEN
    RAISE EXCEPTION 'owner-only' USING ERRCODE = '42501';
  END IF;

  -- Normalise: trim + lower + citext-cast. Reject obvious garbage
  -- before the auth.users probe so callers get a clean "invalid email"
  -- instead of a lookup miss masked as "pending".
  v_clean := lower(trim(COALESCE(p_email, '')))::citext;
  IF position('@' in v_clean::text) = 0
     OR length(v_clean::text) < 5 THEN
    RAISE EXCEPTION 'invalid email' USING ERRCODE = '22023';
  END IF;

  -- Live lookup against auth.users. Email column is citext on Supabase.
  SELECT *
    INTO v_user
    FROM auth.users u
   WHERE u.email::citext = v_clean
   LIMIT 1;

  IF v_user.id IS NOT NULL THEN
    -- Account exists. Already a member?
    IF EXISTS (
      SELECT 1 FROM public.practice_members pm
       WHERE pm.practice_id = p_practice_id
         AND pm.trainer_id  = v_user.id
    ) THEN
      RETURN QUERY
        SELECT
          'already_member'::text                              AS kind,
          v_user.id                                           AS trainer_id,
          v_user.email::text                                  AS email,
          COALESCE(
            (v_user.raw_user_meta_data->>'full_name'),
            (v_user.raw_user_meta_data->>'name'),
            ''
          )::text                                             AS full_name,
          (
            SELECT pm.role
              FROM public.practice_members pm
             WHERE pm.practice_id = p_practice_id
               AND pm.trainer_id  = v_user.id
          )::text                                             AS role;
      RETURN;
    END IF;

    -- Not a member yet — insert and return 'added'.
    INSERT INTO public.practice_members (practice_id, trainer_id, role, joined_at)
    VALUES (p_practice_id, v_user.id, 'practitioner', now());

    RETURN QUERY
      SELECT
        'added'::text                                         AS kind,
        v_user.id                                             AS trainer_id,
        v_user.email::text                                    AS email,
        COALESCE(
          (v_user.raw_user_meta_data->>'full_name'),
          (v_user.raw_user_meta_data->>'name'),
          ''
        )::text                                               AS full_name,
        'practitioner'::text                                  AS role;
    RETURN;
  END IF;

  -- No auth.users row yet. Stash pending. Idempotent via the PK:
  -- re-adding the same email refreshes added_by + added_at so the
  -- /members page always shows the most recent nudge.
  INSERT INTO public.pending_practice_members (email, practice_id, added_by)
  VALUES (v_clean, p_practice_id, v_caller)
  ON CONFLICT (email, practice_id) DO UPDATE
     SET added_by = EXCLUDED.added_by,
         added_at = now();

  RETURN QUERY
    SELECT
      'pending'::text                                         AS kind,
      NULL::uuid                                              AS trainer_id,
      v_clean::text                                           AS email,
      ''::text                                                AS full_name,
      'practitioner'::text                                    AS role;
END;
$function$;

-- Function: public.bootstrap_practice_for_user()
CREATE OR REPLACE FUNCTION public.bootstrap_practice_for_user()
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller     uuid := auth.uid();
  v_existing   uuid;
  v_sentinel   uuid;
  v_claimed    boolean;
  v_new_pid    uuid;
  v_has_bonus  boolean;
  v_meta_name  text;
  v_email      text;
  v_local      text;
  v_base       text;
  v_practice_name text;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'bootstrap_practice_for_user requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  -- (a) Already has a membership? Return the first practice.
  SELECT practice_id INTO v_existing
    FROM practice_members
   WHERE trainer_id = v_caller
   LIMIT 1;

  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;

  -- (b) Carl-sentinel practice — race-safe conditional-UPDATE claim.
  -- Restored from schema_milestone_e_safe_rpcs.sql:204-212. Loser of a
  -- concurrent claim race gets v_claimed = false and falls through to
  -- path (c); winner stamps owner_trainer_id and inserts the member row.
  SELECT id INTO v_sentinel
    FROM practices
   WHERE name = 'Carl Practice'
   LIMIT 1;

  IF v_sentinel IS NOT NULL THEN
    WITH claim AS (
      UPDATE practices
         SET owner_trainer_id = v_caller
       WHERE id = v_sentinel
         AND owner_trainer_id IS NULL
      RETURNING id
    )
    SELECT EXISTS (SELECT 1 FROM claim) INTO v_claimed;

    IF v_claimed THEN
      INSERT INTO practice_members (practice_id, trainer_id, role)
      VALUES (v_sentinel, v_caller, 'owner')
      ON CONFLICT DO NOTHING;
      RETURN v_sentinel;
    END IF;
    -- Fall through: someone else won the claim. Build a fresh practice.
  END IF;

  -- (c) Fresh personal practice. SEC-2 (M-B5): name is bounded.
  SELECT raw_user_meta_data->>'full_name', email
    INTO v_meta_name, v_email
    FROM auth.users
   WHERE id = v_caller;

  -- Pick a base. Prefer full_name; fall back to the email local-part;
  -- finally fall back to the literal 'My'.
  v_base := NULLIF(btrim(coalesce(v_meta_name, '')), '');

  IF v_base IS NULL AND v_email IS NOT NULL AND position('@' IN v_email) > 1 THEN
    v_local := split_part(v_email, '@', 1);
    v_base := NULLIF(btrim(v_local), '');
  END IF;

  IF v_base IS NULL THEN
    v_base := 'My';
  END IF;

  -- Cap at 60 chars (matches rename_practice). 60 chars + ' Practice' (9)
  -- gives a 69-char ceiling — well within any reasonable display surface.
  v_practice_name := btrim(left(v_base, 60)) || ' Practice';

  -- Defence-in-depth: if btrim/left somehow leaves an empty base, fall
  -- back to the literal default rather than producing ' Practice'.
  IF v_practice_name = ' Practice' OR length(btrim(v_practice_name)) = 0 THEN
    v_practice_name := 'My Practice';
  END IF;

  INSERT INTO practices (name, owner_trainer_id)
  VALUES (v_practice_name, v_caller)
  RETURNING id INTO v_new_pid;

  INSERT INTO practice_members (practice_id, trainer_id, role)
  VALUES (v_new_pid, v_caller, 'owner');

  -- Grant the organic signup bonus (+3). Idempotency: check first.
  SELECT EXISTS (
    SELECT 1 FROM credit_ledger
     WHERE practice_id = v_new_pid
       AND type = 'signup_bonus'
  ) INTO v_has_bonus;

  IF NOT v_has_bonus THEN
    -- Wave 40.5: stamp trainer_id
    INSERT INTO credit_ledger (practice_id, delta, type, notes, trainer_id)
    VALUES (v_new_pid, 3, 'signup_bonus', 'Organic signup bonus', v_caller);
  END IF;

  RETURN v_new_pid;
END;
$function$;

-- Function: public.can_write_to_raw_archive(p_path text)
CREATE OR REPLACE FUNCTION public.can_write_to_raw_archive(p_path text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_practice_id uuid;
BEGIN
  IF p_path IS NULL OR length(p_path) = 0 THEN
    RETURN false;
  END IF;

  -- storage.foldername returns each directory component; first is practice_id.
  BEGIN
    v_practice_id := ((storage.foldername(p_path))[1])::uuid;
  EXCEPTION WHEN others THEN
    RETURN false; -- malformed path / non-uuid first segment
  END;

  IF v_practice_id IS NULL THEN
    RETURN false;
  END IF;

  RETURN v_practice_id IN (SELECT public.user_practice_ids())
      OR public.user_is_practice_owner(v_practice_id);
END;
$function$;

-- Function: public.claim_pending_practice_memberships()
CREATE OR REPLACE FUNCTION public.claim_pending_practice_memberships()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.email IS NULL THEN
    RETURN NEW;
  END IF;

  -- Drain: insert every pending row's practice into practice_members.
  -- The NOT EXISTS guard protects against a race where the user is
  -- already a member (e.g. created_by trigger order quirks, defensive
  -- replay). joined_at = now() so the roster shows the effective
  -- join timestamp, not the original invite time.
  INSERT INTO public.practice_members (practice_id, trainer_id, role, joined_at)
  SELECT ppm.practice_id, NEW.id, 'practitioner', now()
    FROM public.pending_practice_members ppm
   WHERE ppm.email = NEW.email::citext
     AND NOT EXISTS (
       SELECT 1 FROM public.practice_members pm
        WHERE pm.practice_id = ppm.practice_id
          AND pm.trainer_id  = NEW.id
     );

  -- Clear out the pending rows for this email regardless of how many
  -- inserts happened above (some may have been skipped by the
  -- idempotency guard). The pending row's job is done either way.
  DELETE FROM public.pending_practice_members
   WHERE email = NEW.email::citext;

  RETURN NEW;
END;
$function$;

-- Function: public.claim_referral_code(p_code text, p_referee_practice_id uuid, p_consent_to_naming boolean)
CREATE OR REPLACE FUNCTION public.claim_referral_code(p_code text, p_referee_practice_id uuid, p_consent_to_naming boolean)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller         uuid := auth.uid();
  v_referrer_pid   uuid;
  v_is_member      boolean;
  v_has_bonus      boolean;
  v_inserted       boolean := false;
  v_self_referrer  boolean;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'claim_referral_code requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_code IS NULL OR p_referee_practice_id IS NULL THEN
    RETURN false;
  END IF;

  p_code := lower(trim(p_code));

  SELECT EXISTS (
    SELECT 1 FROM practice_members
     WHERE practice_id = p_referee_practice_id
       AND trainer_id  = v_caller
  ) INTO v_is_member;

  IF NOT v_is_member THEN
    RETURN false;
  END IF;

  SELECT practice_id INTO v_referrer_pid
    FROM referral_codes
   WHERE code = p_code
     AND revoked_at IS NULL;

  IF v_referrer_pid IS NULL THEN
    RETURN false;
  END IF;

  IF v_referrer_pid = p_referee_practice_id THEN
    RETURN false;  -- same-practice self-referral
  END IF;

  -- SEC-2 (M-B6): multi-practice self-referral. The same trainer can't
  -- own (or be a member of) the referrer practice AND claim the code on
  -- behalf of a referee practice they also belong to. Rejects silently
  -- (matches the milestone-F silent-fail contract).
  SELECT EXISTS (
    SELECT 1 FROM practice_members
     WHERE practice_id = v_referrer_pid
       AND trainer_id  = v_caller
  ) INTO v_self_referrer;

  IF v_self_referrer THEN
    RETURN false;
  END IF;

  IF EXISTS (
    SELECT 1 FROM practice_referrals
     WHERE referee_practice_id = p_referee_practice_id
  ) THEN
    RETURN false;
  END IF;

  BEGIN
    INSERT INTO practice_referrals (
      referee_practice_id,
      referrer_practice_id,
      code_used,
      referee_named_consent
    ) VALUES (
      p_referee_practice_id,
      v_referrer_pid,
      p_code,
      COALESCE(p_consent_to_naming, false)
    );
    v_inserted := true;
  EXCEPTION
    WHEN check_violation THEN
      RETURN false;
    WHEN unique_violation THEN
      RETURN false;
  END;

  IF v_inserted THEN
    SELECT EXISTS (
      SELECT 1 FROM credit_ledger
       WHERE practice_id = p_referee_practice_id
         AND type = 'referral_signup_bonus'
    ) INTO v_has_bonus;

    IF NOT v_has_bonus THEN
      -- Wave 40.5: stamp trainer_id
      INSERT INTO credit_ledger (practice_id, delta, type, notes, trainer_id)
      VALUES (
        p_referee_practice_id,
        5,
        'referral_signup_bonus',
        'Referral signup bonus (code ' || p_code || ')',
        v_caller
      );
    END IF;
  END IF;

  RETURN true;
END;
$function$;

-- Function: public.client_self_grant_consent(p_plan_id uuid, p_kind text)
CREATE OR REPLACE FUNCTION public.client_self_grant_consent(p_plan_id uuid, p_kind text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_practice_id   uuid;
  v_client_id     uuid;
  v_prev_consent  jsonb;
  v_new_consent   jsonb;
  v_kind_norm     text;
BEGIN
  -- Argument validation. Mirrors set_client_video_consent's ERRCODE
  -- pattern so the wire-level errors look familiar.
  IF p_plan_id IS NULL THEN
    RAISE EXCEPTION 'client_self_grant_consent: p_plan_id is required'
      USING ERRCODE = '22023';
  END IF;

  IF p_kind IS NULL THEN
    RAISE EXCEPTION 'client_self_grant_consent: p_kind is required'
      USING ERRCODE = '22023';
  END IF;

  v_kind_norm := lower(trim(p_kind));
  IF v_kind_norm NOT IN ('grayscale', 'original') THEN
    RAISE EXCEPTION 'client_self_grant_consent: p_kind must be one of grayscale, original'
      USING ERRCODE = '22023';
  END IF;

  -- Resolve plan → client. anon has no SELECT on plans/clients (Milestone
  -- C RLS), but this fn is SECURITY DEFINER so the lookup runs as
  -- postgres.
  SELECT p.practice_id, p.client_id
    INTO v_practice_id, v_client_id
    FROM plans p
   WHERE p.id = p_plan_id
     AND p.deleted_at IS NULL
   LIMIT 1;

  IF v_practice_id IS NULL THEN
    RAISE EXCEPTION 'client_self_grant_consent: plan % not found', p_plan_id
      USING ERRCODE = '22023';
  END IF;

  IF v_client_id IS NULL THEN
    RAISE EXCEPTION 'client_self_grant_consent: plan % has no linked client', p_plan_id
      USING ERRCODE = '22023';
  END IF;

  -- Capture previous consent for the audit diff. Default shape mirrors
  -- the migration G default so legacy clients (pre-Wave 40.3) still
  -- produce a clean diff.
  SELECT video_consent INTO v_prev_consent
    FROM clients
   WHERE id = v_client_id
   LIMIT 1;

  IF v_prev_consent IS NULL THEN
    v_prev_consent := jsonb_build_object(
      'line_drawing', true,
      'grayscale',    false,
      'original',     false
    );
  END IF;

  -- Build the new consent jsonb. We preserve every key on v_prev_consent
  -- and only flip the requested kind to true. line_drawing stays true
  -- (the schema CHECK / set_client_video_consent enforce this on the
  -- practitioner path; we keep parity here for safety).
  v_new_consent := v_prev_consent || jsonb_build_object('line_drawing', true);

  IF v_kind_norm = 'grayscale' THEN
    v_new_consent := v_new_consent || jsonb_build_object('grayscale', true);
  ELSIF v_kind_norm = 'original' THEN
    v_new_consent := v_new_consent || jsonb_build_object('original', true);
  END IF;

  UPDATE clients
     SET video_consent        = v_new_consent,
         consent_confirmed_at = now()
   WHERE id = v_client_id;

  -- Emit audit row only if the consent actually changed. A second
  -- self-grant of an already-true kind is a no-op (silently succeeds,
  -- no audit noise).
  IF v_prev_consent IS DISTINCT FROM v_new_consent THEN
    INSERT INTO public.audit_events (
      practice_id,
      actor_id,
      kind,
      ref_id,
      meta
    ) VALUES (
      v_practice_id,
      NULL, -- anon caller — no auth.uid()
      'client.consent.update',
      v_client_id,
      jsonb_build_object(
        'from',   v_prev_consent,
        'to',     v_new_consent,
        'source', 'client_self_grant',
        'kind',   v_kind_norm
      )
    );
  END IF;
END;
$function$;

-- Function: public.consume_credit(p_practice_id uuid, p_plan_id uuid, p_credits integer)
CREATE OR REPLACE FUNCTION public.consume_credit(p_practice_id uuid, p_plan_id uuid, p_credits integer)
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
  v_prepaid_at   timestamptz;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'consume_credit requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_practice_id IS NULL THEN
    RAISE EXCEPTION 'consume_credit: p_practice_id is required'
      USING ERRCODE = '22023';
  END IF;

  IF p_credits IS NULL OR p_credits <= 0 THEN
    RAISE EXCEPTION 'consume_credit: p_credits must be positive (got %)', p_credits
      USING ERRCODE = '22023';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM practice_members
     WHERE practice_id = p_practice_id
       AND trainer_id  = v_caller
  ) INTO v_is_member;

  IF NOT v_is_member THEN
    RAISE EXCEPTION 'consume_credit: caller % is not a member of practice %', v_caller, p_practice_id
      USING ERRCODE = '42501';
  END IF;

  -- SEC-2 (C-2 / restore Milestone V): publish-time consent backstop.
  -- Runs BEFORE both the prepaid-unlock fast path and the normal
  -- credit-burn branch so a malformed plan can never burn a credit
  -- (or consume a prepaid unlock) with treatments the client hasn't
  -- consented to. validate_plan_treatment_consent is SECURITY DEFINER
  -- and membership-checks internally, so this is safe to call without
  -- additional guarding here.
  IF p_plan_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.validate_plan_treatment_consent(p_plan_id)
  ) THEN
    RAISE EXCEPTION
      'consume_credit: plan % has exercises with unconsented treatments', p_plan_id
      USING ERRCODE = 'P0003';
  END IF;

  PERFORM 1 FROM practices WHERE id = p_practice_id FOR UPDATE;

  SELECT unlock_credit_prepaid_at
    INTO v_prepaid_at
    FROM plans
   WHERE id = p_plan_id
     AND practice_id = p_practice_id
   FOR UPDATE;

  IF v_prepaid_at IS NOT NULL THEN
    UPDATE plans
       SET unlock_credit_prepaid_at = NULL,
           first_opened_at          = NULL,
           last_opened_at           = NULL
     WHERE id = p_plan_id;

    SELECT COALESCE(SUM(delta), 0)::integer
      INTO v_balance
      FROM credit_ledger
     WHERE practice_id = p_practice_id;

    RETURN jsonb_build_object(
      'ok',                true,
      'new_balance',       v_balance,
      'prepaid_unlock_at', v_prepaid_at
    );
  END IF;

  SELECT COALESCE(SUM(delta), 0)::integer
    INTO v_balance
    FROM credit_ledger
   WHERE practice_id = p_practice_id;

  IF v_balance < p_credits THEN
    RETURN jsonb_build_object(
      'ok',      false,
      'reason',  'insufficient_credits',
      'balance', v_balance
    );
  END IF;

  -- Wave 40.5: stamp trainer_id on the consumption ledger row.
  INSERT INTO credit_ledger (practice_id, delta, type, plan_id, notes, trainer_id)
  VALUES (
    p_practice_id,
    -p_credits,
    'consumption',
    p_plan_id,
    'consume_credit(' || p_credits::text || ')',
    v_caller
  );

  v_new_balance := v_balance - p_credits;

  RETURN jsonb_build_object(
    'ok',          true,
    'new_balance', v_new_balance
  );
END;
$function$;

-- Function: public.delete_client(p_client_id uuid)
CREATE OR REPLACE FUNCTION public.delete_client(p_client_id uuid)
 RETURNS TABLE(id uuid, practice_id uuid, name text, deleted_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller       uuid := auth.uid();
  v_practice_id  uuid;
  v_now          timestamptz := now();
  v_existing_ts  timestamptz;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'delete_client requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_client_id IS NULL THEN
    RAISE EXCEPTION 'delete_client: p_client_id is required'
      USING ERRCODE = '22023';
  END IF;

  SELECT c.practice_id, c.deleted_at
    INTO v_practice_id, v_existing_ts
    FROM clients c
   WHERE c.id = p_client_id
   LIMIT 1;

  IF v_practice_id IS NULL THEN
    RETURN;
  END IF;

  IF NOT (v_practice_id IN (SELECT public.user_practice_ids())) THEN
    RAISE EXCEPTION 'delete_client: caller % is not a member of practice %',
      v_caller, v_practice_id
      USING ERRCODE = '42501';
  END IF;

  IF v_existing_ts IS NOT NULL THEN
    RETURN QUERY
    SELECT c.id, c.practice_id, c.name, c.deleted_at
      FROM clients c
     WHERE c.id = p_client_id;
    RETURN;
  END IF;

  -- Wave 40.5: stamp deleted_by_user_id
  UPDATE clients AS c
     SET deleted_at = v_now,
         updated_at = v_now,
         deleted_by_user_id = v_caller
   WHERE c.id = p_client_id;

  UPDATE plans AS p
     SET deleted_at = v_now
   WHERE p.client_id = p_client_id
     AND p.deleted_at IS NULL;

  RETURN QUERY
  SELECT c.id, c.practice_id, c.name, c.deleted_at
    FROM clients c
   WHERE c.id = p_client_id;
END;
$function$;

-- Function: public.enforce_single_tier_referral()
CREATE OR REPLACE FUNCTION public.enforce_single_tier_referral()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF EXISTS (
    SELECT 1 FROM practice_referrals
     WHERE referee_practice_id = NEW.referrer_practice_id
  ) THEN
    RAISE EXCEPTION
      'single-tier referral: practice % is already a referee, cannot be a referrer',
      NEW.referrer_practice_id
      USING ERRCODE = '23514';
  END IF;

  -- Defence-in-depth: a practice that's already a referrer cannot become
  -- a referee (same chain-length rule in the other direction).
  IF EXISTS (
    SELECT 1 FROM practice_referrals
     WHERE referrer_practice_id = NEW.referee_practice_id
  ) THEN
    RAISE EXCEPTION
      'single-tier referral: practice % already has referees, cannot become a referee',
      NEW.referee_practice_id
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$function$;

-- Function: public.generate_referral_code(p_practice_id uuid)
CREATE OR REPLACE FUNCTION public.generate_referral_code(p_practice_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$;

-- Function: public.get_client_analytics_summary(p_client_id uuid)
CREATE OR REPLACE FUNCTION public.get_client_analytics_summary(p_client_id uuid)
 RETURNS TABLE(total_plans integer, total_opens integer, total_completions integer, last_opened_at timestamp with time zone, avg_completion_rate numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller      UUID := auth.uid();
  v_practice_id UUID;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'get_client_analytics_summary requires authentication'
      USING ERRCODE = '28000';
  END IF;

  -- Resolve client and check membership
  SELECT c.practice_id INTO v_practice_id
    FROM clients c
   WHERE c.id = p_client_id
     AND c.deleted_at IS NULL;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF v_practice_id NOT IN (SELECT public.user_practice_ids()) THEN
    RAISE EXCEPTION 'get_client_analytics_summary: caller is not a member of this practice'
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH client_plans AS (
    SELECT p.id AS plan_id
    FROM plans p
    WHERE p.client_id = p_client_id
      AND p.deleted_at IS NULL
  ),
  session_agg AS (
    SELECT
      COUNT(DISTINCT cs.plan_id)::INT AS plans_opened,
      COUNT(*)::INT AS total_open_count,
      MAX(cs.opened_at) AS max_opened
    FROM client_sessions cs
      JOIN client_plans cp ON cp.plan_id = cs.plan_id
    WHERE cs.consent_granted = true
  ),
  completion_agg AS (
    SELECT COUNT(*)::INT AS total_comp
    FROM plan_analytics_events e
      JOIN client_sessions cs ON cs.id = e.client_session_id
      JOIN client_plans cp ON cp.plan_id = cs.plan_id
    WHERE e.event_kind = 'plan_completed'
  )
  SELECT
    (SELECT COUNT(*)::INT FROM client_plans),
    sa.total_open_count,
    ca.total_comp,
    sa.max_opened,
    CASE WHEN sa.total_open_count > 0
      THEN ROUND(ca.total_comp::numeric / sa.total_open_count, 2)
      ELSE 0::numeric
    END
  FROM session_agg sa
    CROSS JOIN completion_agg ca;
END;
$function$;

-- Function: public.get_client_by_id(p_client_id uuid)
CREATE OR REPLACE FUNCTION public.get_client_by_id(p_client_id uuid)
 RETURNS TABLE(id uuid, name text, video_consent jsonb, consent_confirmed_at timestamp with time zone, avatar_path text, avatar_url text, client_exercise_defaults jsonb)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller       uuid := auth.uid();
  v_practice_id  uuid;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'get_client_by_id requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  SELECT c.practice_id INTO v_practice_id
    FROM clients c
   WHERE c.id = p_client_id
     AND c.deleted_at IS NULL
   LIMIT 1;

  IF v_practice_id IS NULL THEN
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM practice_members pm
     WHERE pm.practice_id = v_practice_id AND pm.trainer_id = v_caller
  ) AND NOT public.user_is_practice_owner(v_practice_id) THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT c.id,
         c.name,
         c.video_consent,
         c.consent_confirmed_at,
         c.avatar_path,
         CASE
           WHEN c.avatar_path IS NOT NULL AND length(c.avatar_path) > 0
           THEN public.sign_storage_url('raw-archive', c.avatar_path, 3600)
           ELSE NULL
         END AS avatar_url,
         COALESCE(c.client_exercise_defaults, '{}'::jsonb) AS client_exercise_defaults
    FROM clients c
   WHERE c.id = p_client_id
     AND c.deleted_at IS NULL;
END;
$function$;

-- Function: public.get_plan_analytics_summary(p_plan_id uuid)
CREATE OR REPLACE FUNCTION public.get_plan_analytics_summary(p_plan_id uuid)
 RETURNS TABLE(opens integer, completions integer, last_opened_at timestamp with time zone, exercise_stats jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller      UUID := auth.uid();
  v_practice_id UUID;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'get_plan_analytics_summary requires authentication'
      USING ERRCODE = '28000';
  END IF;

  -- Resolve plan and check membership
  SELECT p.practice_id INTO v_practice_id
    FROM plans p
   WHERE p.id = p_plan_id
     AND p.deleted_at IS NULL;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF v_practice_id NOT IN (SELECT public.user_practice_ids()) THEN
    RAISE EXCEPTION 'get_plan_analytics_summary: caller is not a member of this practice'
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH session_agg AS (
    SELECT
      COUNT(*)::INT AS total_opens,
      MAX(cs.opened_at) AS max_opened_at
    FROM client_sessions cs
    WHERE cs.plan_id = p_plan_id
      AND cs.consent_granted = true
  ),
  completion_agg AS (
    SELECT COUNT(*)::INT AS total_completions
    FROM plan_analytics_events e
      JOIN client_sessions cs ON cs.id = e.client_session_id
    WHERE cs.plan_id = p_plan_id
      AND e.event_kind = 'plan_completed'
  ),
  exercise_agg AS (
    SELECT jsonb_agg(jsonb_build_object(
      'exercise_id', ea.exercise_id,
      'viewed', ea.viewed_count,
      'completed', ea.completed_count,
      'skipped', ea.skipped_count
    )) AS stats
    FROM (
      SELECT
        e.exercise_id,
        COUNT(*) FILTER (WHERE e.event_kind = 'exercise_viewed')::INT AS viewed_count,
        COUNT(*) FILTER (WHERE e.event_kind = 'exercise_completed')::INT AS completed_count,
        COUNT(*) FILTER (WHERE e.event_kind = 'exercise_skipped')::INT AS skipped_count
      FROM plan_analytics_events e
        JOIN client_sessions cs ON cs.id = e.client_session_id
      WHERE cs.plan_id = p_plan_id
        AND e.exercise_id IS NOT NULL
        AND e.event_kind IN ('exercise_viewed', 'exercise_completed', 'exercise_skipped')
      GROUP BY e.exercise_id
    ) ea
  )
  SELECT
    sa.total_opens,
    ca.total_completions,
    sa.max_opened_at,
    COALESCE(exa.stats, '[]'::jsonb)
  FROM session_agg sa
    CROSS JOIN completion_agg ca
    CROSS JOIN exercise_agg exa;
END;
$function$;

-- Function: public.get_plan_full(p_plan_id uuid)
CREATE OR REPLACE FUNCTION public.get_plan_full(p_plan_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  plan_row    plans;
  v_consent   jsonb;
  v_gray_ok   boolean;
  v_orig_ok   boolean;
  exes        jsonb;
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
                    -- Three-treatment thumbnails (Wave 2026-05-05).
                    -- Existence-checked against storage.objects so older
                    -- plans (pre-PR #263) get NULL → legacy fallback in the
                    -- web player, not 404 → broken-image glyph.
                    'thumbnail_url_line',
                      CASE
                        WHEN e.media_type = 'video'
                          AND EXISTS (
                            SELECT 1 FROM storage.objects o
                             WHERE o.bucket_id = 'media'
                               AND o.name = plan_row.id::text || '/' ||
                                            e.id::text || '_thumb_line.jpg'
                          )
                        THEN 'https://yrwcofhovrcydootivjx.supabase.co/storage/v1/object/public/media/' ||
                             plan_row.id::text || '/' || e.id::text || '_thumb_line.jpg'
                        ELSE NULL
                      END,
                    'thumbnail_url_color',
                      CASE
                        WHEN (v_gray_ok OR v_orig_ok)
                          AND e.media_type = 'video'
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
                      END
                  )
               ORDER BY e.position
           ),
           '[]'::jsonb
         )
    INTO exes
    FROM exercises e
   WHERE e.plan_id = p_plan_id;

  RETURN jsonb_build_object(
    'plan',      to_jsonb(plan_row),
    'exercises', exes
  );
END;
$function$;

-- Function: public.get_plan_sharing_context(p_plan_id uuid)
CREATE OR REPLACE FUNCTION public.get_plan_sharing_context(p_plan_id uuid)
 RETURNS TABLE(practitioner_name text, practice_name text, client_first_name text, analytics_allowed boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_practice_id    UUID;
  v_client_id      UUID;
  v_trainer_id     UUID;
  v_practice_label TEXT;
  v_client_name    TEXT;
  v_analytics      BOOLEAN;
  v_trainer_meta   JSONB;
  v_trainer_name   TEXT;
BEGIN
  -- Resolve plan
  SELECT p.practice_id, p.client_id
    INTO v_practice_id, v_client_id
    FROM plans p
   WHERE p.id = p_plan_id
     AND p.deleted_at IS NULL;

  IF NOT FOUND THEN
    RETURN; -- returns empty result set
  END IF;

  -- Get practice name
  SELECT pr.name INTO v_practice_label
    FROM practices pr
   WHERE pr.id = v_practice_id;

  -- Get client first name + analytics consent
  IF v_client_id IS NOT NULL THEN
    SELECT
      split_part(c.name, ' ', 1),
      COALESCE((c.video_consent ->> 'analytics_allowed')::boolean, true)
    INTO v_client_name, v_analytics
      FROM clients c
     WHERE c.id = v_client_id
       AND c.deleted_at IS NULL;

    IF NOT FOUND THEN
      -- Client deleted — fall back
      v_client_name := NULL;
      v_analytics := false;
    END IF;
  ELSE
    v_client_name := NULL;
    v_analytics := true; -- no client means no client-level opt-out
  END IF;

  -- If analytics disabled at client level, return NULL row (page falls back to generic)
  IF v_analytics IS FALSE THEN
    RETURN;
  END IF;

  -- Get most recent practitioner who published this plan
  SELECT pi.trainer_id INTO v_trainer_id
    FROM plan_issuances pi
   WHERE pi.plan_id = p_plan_id
   ORDER BY pi.issued_at DESC
   LIMIT 1;

  IF v_trainer_id IS NOT NULL THEN
    SELECT u.raw_user_meta_data
      INTO v_trainer_meta
      FROM auth.users u
     WHERE u.id = v_trainer_id;

    -- SEC-2 (H-5): user-controlled display_name / full_name remain the
    -- preferred disclosure chain. The previous fallback to
    -- split_part(email, '@', 1) leaked the practitioner's email-prefix
    -- to anon callers; replaced with 'your practitioner'. Practice name
    -- is returned alongside in `practice_name`, so client-side copy
    -- ("Shared by your practitioner at {practice_name}") still has a
    -- specific brand to anchor on without leaking individual identity.
    v_trainer_name := COALESCE(
      NULLIF(btrim(v_trainer_meta ->> 'display_name'), ''),
      NULLIF(btrim(v_trainer_meta ->> 'full_name'),    ''),
      'your practitioner'
    );
  ELSE
    v_trainer_name := 'your practitioner';
  END IF;

  RETURN QUERY SELECT
    v_trainer_name,
    v_practice_label,
    v_client_name,
    v_analytics;
END;
$function$;

-- Function: public.leave_practice(p_practice_id uuid)
CREATE OR REPLACE FUNCTION public.leave_practice(p_practice_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller        uuid := auth.uid();
  v_role          text;
  v_owner_count   int;
  v_member_count  int;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'auth required' USING ERRCODE = '28000';
  END IF;

  -- Lock the caller's row. P0002 if they're not a member.
  SELECT pm.role
    INTO v_role
    FROM public.practice_members pm
   WHERE pm.practice_id = p_practice_id
     AND pm.trainer_id  = v_caller
   FOR UPDATE;

  IF v_role IS NULL THEN
    RAISE EXCEPTION 'not a member of this practice'
      USING ERRCODE = '42501';
  END IF;

  -- Count TOTAL members (including self) to detect the solo-member case.
  SELECT COUNT(*)
    INTO v_member_count
    FROM public.practice_members
   WHERE practice_id = p_practice_id;

  IF v_member_count <= 1 THEN
    RAISE EXCEPTION 'cannot leave a practice where you are the only member'
      USING ERRCODE = '22023';
  END IF;

  -- Last-owner guard: if you're an owner, make sure at least one OTHER
  -- owner would remain after you leave.
  IF v_role = 'owner' THEN
    SELECT COUNT(*)
      INTO v_owner_count
      FROM public.practice_members
     WHERE practice_id = p_practice_id
       AND role = 'owner'
       AND trainer_id <> v_caller;

    IF v_owner_count = 0 THEN
      RAISE EXCEPTION 'promote another owner before leaving'
        USING ERRCODE = '22023';
    END IF;
  END IF;

  DELETE FROM public.practice_members
   WHERE practice_id = p_practice_id
     AND trainer_id  = v_caller;
END;
$function$;

-- Function: public.list_all_client_names(p_practice_id uuid)
CREATE OR REPLACE FUNCTION public.list_all_client_names(p_practice_id uuid)
 RETURNS TABLE(name text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller uuid := auth.uid();
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'list_all_client_names requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_practice_id IS NULL THEN
    RAISE EXCEPTION 'list_all_client_names: p_practice_id is required'
      USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM practice_members
     WHERE practice_id = p_practice_id AND trainer_id = v_caller
  ) AND NOT public.user_is_practice_owner(p_practice_id) THEN
    RAISE EXCEPTION 'list_all_client_names: caller % is not a member of practice %',
      v_caller, p_practice_id
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
    SELECT c.name
      FROM clients c
     WHERE c.practice_id = p_practice_id;
END;
$function$;

-- Function: public.list_practice_audit(p_practice_id uuid, p_offset integer, p_limit integer, p_kinds text[], p_actor uuid, p_from timestamp with time zone, p_to timestamp with time zone)
CREATE OR REPLACE FUNCTION public.list_practice_audit(p_practice_id uuid, p_offset integer DEFAULT 0, p_limit integer DEFAULT 50, p_kinds text[] DEFAULT NULL::text[], p_actor uuid DEFAULT NULL::uuid, p_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_to timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS TABLE(ts timestamp with time zone, kind text, trainer_id uuid, email text, full_name text, title text, credits_delta numeric, balance_after numeric, ref_id uuid, meta jsonb, client_id uuid, client_name text, total_count bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_owner_id uuid;
BEGIN
  IF NOT (p_practice_id IN (SELECT public.user_practice_ids())) THEN
    RAISE EXCEPTION 'not a member of this practice'
      USING ERRCODE = '42501';
  END IF;

  -- Pre-fetch the practice owner for fallback attribution. One query
  -- instead of per-row lateral joins.
  SELECT pm.trainer_id INTO v_owner_id
    FROM practice_members pm
   WHERE pm.practice_id = p_practice_id
     AND pm.role = 'owner'
   LIMIT 1;

  RETURN QUERY
  WITH unioned AS (
    -- ------------------------------------------------------------------
    -- plan_issuances -> kind = 'plan.publish'
    -- ------------------------------------------------------------------
    SELECT
      pi.issued_at                                    AS a_ts,
      'plan.publish'::text                            AS a_kind,
      pi.trainer_id                                   AS a_trainer_id,
      u.email::text                                   AS a_email,
      COALESCE(u.raw_user_meta_data->>'full_name', '')::text AS a_full_name,
      p.title::text                                   AS a_title,
      NULL::numeric                                   AS a_credits_delta,
      NULL::numeric                                   AS a_balance_after,
      pi.plan_id                                      AS a_ref_id,
      jsonb_build_object(
        'version',           pi.version,
        'prepaid_unlock_at', pi.prepaid_unlock_at
      )                                               AS a_meta,
      p.client_id                                     AS a_client_id,
      cli.name::text                                  AS a_client_name
    FROM public.plan_issuances pi
    JOIN public.plans p ON p.id = pi.plan_id
    LEFT JOIN auth.users u ON u.id = pi.trainer_id
    LEFT JOIN public.clients cli ON cli.id = p.client_id
    WHERE pi.practice_id = p_practice_id

    UNION ALL

    -- ------------------------------------------------------------------
    -- credit_ledger -> kind = 'credit.' || type
    -- Wave 40.5: full actor coverage.
    --   Priority: cl.trainer_id (stamped on new rows) ->
    --             plan_issuances (for consumption/refund with plan_id) ->
    --             practice owner (fallback for historical rows).
    -- ------------------------------------------------------------------
    SELECT
      cl.created_at                                   AS a_ts,
      ('credit.' || cl.type)::text                    AS a_kind,
      COALESCE(cl.trainer_id, derived_pi.trainer_id, v_owner_id) AS a_trainer_id,
      COALESCE(
        cl_u.email,
        derived_u.email,
        owner_u.email
      )::text                                         AS a_email,
      COALESCE(
        cl_u.raw_user_meta_data->>'full_name',
        derived_u.raw_user_meta_data->>'full_name',
        owner_u.raw_user_meta_data->>'full_name',
        ''
      )::text                                         AS a_full_name,
      cl.notes::text                                  AS a_title,
      cl.delta::numeric                               AS a_credits_delta,
      (SUM(cl.delta) OVER (
        ORDER BY cl.created_at, cl.id
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
      ))::numeric                                     AS a_balance_after,
      cl.plan_id                                      AS a_ref_id,
      CASE
        WHEN cl.payfast_payment_id IS NOT NULL
          THEN jsonb_build_object('payfast_payment_id', cl.payfast_payment_id)
        ELSE NULL
      END                                             AS a_meta,
      pl.client_id                                    AS a_client_id,
      cli.name::text                                  AS a_client_name
    FROM public.credit_ledger cl
    LEFT JOIN public.plans pl ON pl.id = cl.plan_id
    LEFT JOIN public.clients cli ON cli.id = pl.client_id
    -- Direct trainer_id lookup (Wave 40.5 rows)
    LEFT JOIN auth.users cl_u ON cl_u.id = cl.trainer_id
    -- Plan-based derivation (consumption/refund with plan_id, pre-40.5)
    LEFT JOIN LATERAL (
      SELECT pi.trainer_id
        FROM public.plan_issuances pi
       WHERE pi.plan_id = cl.plan_id
       ORDER BY pi.issued_at DESC
       LIMIT 1
    ) derived_pi ON cl.plan_id IS NOT NULL AND cl.trainer_id IS NULL
    LEFT JOIN auth.users derived_u ON derived_u.id = derived_pi.trainer_id
    -- Practice owner fallback (pre-40.5 rows without plan_id)
    LEFT JOIN auth.users owner_u
      ON owner_u.id = v_owner_id
      AND cl.trainer_id IS NULL
      AND derived_pi.trainer_id IS NULL
    WHERE cl.practice_id = p_practice_id

    UNION ALL

    -- ------------------------------------------------------------------
    -- referral_rebate_ledger -> kind = 'referral.rebate'
    -- Wave 40.5: derive the referrer practice owner as the actor.
    -- ------------------------------------------------------------------
    SELECT
      rrl.created_at                                  AS a_ts,
      'referral.rebate'::text                         AS a_kind,
      owner_pm.trainer_id                             AS a_trainer_id,
      owner_u.email::text                             AS a_email,
      COALESCE(owner_u.raw_user_meta_data->>'full_name', '')::text AS a_full_name,
      NULL::text                                      AS a_title,
      rrl.credits::numeric                            AS a_credits_delta,
      NULL::numeric                                   AS a_balance_after,
      rrl.referee_practice_id                         AS a_ref_id,
      jsonb_build_object(
        'referee_practice_id',     rrl.referee_practice_id,
        'source_credit_ledger_id', rrl.source_credit_ledger_id,
        'rebate_kind',             rrl.kind,
        'zar_amount',              rrl.zar_amount
      )                                               AS a_meta,
      NULL::uuid                                      AS a_client_id,
      NULL::text                                      AS a_client_name
    FROM public.referral_rebate_ledger rrl
    LEFT JOIN public.practice_members owner_pm
      ON owner_pm.practice_id = rrl.referrer_practice_id
     AND owner_pm.role = 'owner'
    LEFT JOIN auth.users owner_u ON owner_u.id = owner_pm.trainer_id
    WHERE rrl.referrer_practice_id = p_practice_id

    UNION ALL

    -- ------------------------------------------------------------------
    -- clients (created_at) -> kind = 'client.create'
    -- Wave 40.5: created_by_user_id as actor, fallback to practice owner.
    -- ------------------------------------------------------------------
    SELECT
      c.created_at                                    AS a_ts,
      'client.create'::text                           AS a_kind,
      COALESCE(c.created_by_user_id, v_owner_id)     AS a_trainer_id,
      COALESCE(creator_u.email, owner_u.email)::text  AS a_email,
      COALESCE(
        creator_u.raw_user_meta_data->>'full_name',
        owner_u.raw_user_meta_data->>'full_name',
        ''
      )::text                                         AS a_full_name,
      c.name::text                                    AS a_title,
      NULL::numeric                                   AS a_credits_delta,
      NULL::numeric                                   AS a_balance_after,
      c.id                                            AS a_ref_id,
      NULL::jsonb                                     AS a_meta,
      c.id                                            AS a_client_id,
      c.name::text                                    AS a_client_name
    FROM public.clients c
    LEFT JOIN auth.users creator_u ON creator_u.id = c.created_by_user_id
    LEFT JOIN auth.users owner_u
      ON owner_u.id = v_owner_id AND c.created_by_user_id IS NULL
    WHERE c.practice_id = p_practice_id
      AND c.deleted_at IS NULL

    UNION ALL

    -- ------------------------------------------------------------------
    -- clients (deleted_at) -> kind = 'client.delete'
    -- Wave 40.5: deleted_by_user_id as actor, fallback to practice owner.
    -- ------------------------------------------------------------------
    SELECT
      c.deleted_at                                    AS a_ts,
      'client.delete'::text                           AS a_kind,
      COALESCE(c.deleted_by_user_id, v_owner_id)     AS a_trainer_id,
      COALESCE(deleter_u.email, owner_u.email)::text  AS a_email,
      COALESCE(
        deleter_u.raw_user_meta_data->>'full_name',
        owner_u.raw_user_meta_data->>'full_name',
        ''
      )::text                                         AS a_full_name,
      c.name::text                                    AS a_title,
      NULL::numeric                                   AS a_credits_delta,
      NULL::numeric                                   AS a_balance_after,
      c.id                                            AS a_ref_id,
      NULL::jsonb                                     AS a_meta,
      c.id                                            AS a_client_id,
      c.name::text                                    AS a_client_name
    FROM public.clients c
    LEFT JOIN auth.users deleter_u ON deleter_u.id = c.deleted_by_user_id
    LEFT JOIN auth.users owner_u
      ON owner_u.id = v_owner_id AND c.deleted_by_user_id IS NULL
    WHERE c.practice_id = p_practice_id
      AND c.deleted_at IS NOT NULL

    UNION ALL

    -- ------------------------------------------------------------------
    -- practice_members -> kind = 'member.join'
    -- ------------------------------------------------------------------
    SELECT
      pm.joined_at                                    AS a_ts,
      'member.join'::text                             AS a_kind,
      pm.trainer_id                                   AS a_trainer_id,
      u.email::text                                   AS a_email,
      COALESCE(u.raw_user_meta_data->>'full_name', '')::text AS a_full_name,
      pm.role::text                                   AS a_title,
      NULL::numeric                                   AS a_credits_delta,
      NULL::numeric                                   AS a_balance_after,
      pm.trainer_id                                   AS a_ref_id,
      NULL::jsonb                                     AS a_meta,
      NULL::uuid                                      AS a_client_id,
      NULL::text                                      AS a_client_name
    FROM public.practice_members pm
    LEFT JOIN auth.users u ON u.id = pm.trainer_id
    WHERE pm.practice_id = p_practice_id

    UNION ALL

    -- ------------------------------------------------------------------
    -- audit_events catchall (member.role_change / member.remove /
    -- practice.rename / client.restore / plan.opened / ...)
    --
    -- plan.opened: derive actor from latest plan_issuance (Wave 40.1).
    -- All other audit_events carry actor_id directly.
    -- ------------------------------------------------------------------
    SELECT
      ae.ts                                           AS a_ts,
      ae.kind                                         AS a_kind,
      COALESCE(ae.actor_id, derived_open_pi.trainer_id) AS a_trainer_id,
      COALESCE(u.email, derived_open_u.email)::text   AS a_email,
      COALESCE(
        u.raw_user_meta_data->>'full_name',
        derived_open_u.raw_user_meta_data->>'full_name',
        ''
      )::text                                         AS a_full_name,
      NULL::text                                      AS a_title,
      NULL::numeric                                   AS a_credits_delta,
      NULL::numeric                                   AS a_balance_after,
      ae.ref_id                                       AS a_ref_id,
      ae.meta                                         AS a_meta,
      CASE
        WHEN ae.kind LIKE 'plan.%' THEN plan_for_ae.client_id
        WHEN ae.kind LIKE 'client.%' THEN ae.ref_id
        ELSE NULL
      END                                             AS a_client_id,
      CASE
        WHEN ae.kind LIKE 'plan.%' THEN cli_for_plan.name::text
        WHEN ae.kind LIKE 'client.%' THEN cli_for_ae.name::text
        ELSE NULL
      END                                             AS a_client_name
    FROM public.audit_events ae
    LEFT JOIN auth.users u ON u.id = ae.actor_id
    LEFT JOIN public.plans plan_for_ae
      ON ae.kind LIKE 'plan.%' AND plan_for_ae.id = ae.ref_id
    LEFT JOIN public.clients cli_for_plan
      ON cli_for_plan.id = plan_for_ae.client_id
    LEFT JOIN public.clients cli_for_ae
      ON ae.kind LIKE 'client.%' AND cli_for_ae.id = ae.ref_id
    LEFT JOIN LATERAL (
      SELECT pi.trainer_id
        FROM public.plan_issuances pi
       WHERE pi.plan_id = ae.ref_id
       ORDER BY pi.issued_at DESC
       LIMIT 1
    ) derived_open_pi
      ON ae.kind = 'plan.opened' AND ae.actor_id IS NULL
    LEFT JOIN auth.users derived_open_u
      ON derived_open_u.id = derived_open_pi.trainer_id
    WHERE ae.practice_id = p_practice_id
  ),
  filtered AS (
    SELECT *
      FROM unioned un
     WHERE (p_kinds IS NULL OR un.a_kind        = ANY (p_kinds))
       AND (p_actor IS NULL OR un.a_trainer_id  = p_actor)
       AND (p_from  IS NULL OR un.a_ts         >= p_from)
       AND (p_to    IS NULL OR un.a_ts         <= p_to)
  )
  SELECT
    f.a_ts            AS ts,
    f.a_kind          AS kind,
    f.a_trainer_id    AS trainer_id,
    f.a_email         AS email,
    f.a_full_name     AS full_name,
    f.a_title         AS title,
    f.a_credits_delta AS credits_delta,
    f.a_balance_after AS balance_after,
    f.a_ref_id        AS ref_id,
    f.a_meta          AS meta,
    f.a_client_id     AS client_id,
    f.a_client_name   AS client_name,
    COUNT(*) OVER ()::bigint AS total_count
  FROM filtered f
  ORDER BY f.a_ts DESC
  OFFSET GREATEST(p_offset, 0)
  LIMIT  GREATEST(p_limit, 1);
END;
$function$;

-- Function: public.list_practice_clients(p_practice_id uuid)
CREATE OR REPLACE FUNCTION public.list_practice_clients(p_practice_id uuid)
 RETURNS TABLE(id uuid, name text, video_consent jsonb, consent_confirmed_at timestamp with time zone, avatar_path text, avatar_url text, client_exercise_defaults jsonb, last_plan_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller uuid := auth.uid();
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'list_practice_clients requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_practice_id IS NULL THEN
    RAISE EXCEPTION 'list_practice_clients: p_practice_id is required'
      USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM practice_members pm
     WHERE pm.practice_id = p_practice_id AND pm.trainer_id = v_caller
  ) AND NOT public.user_is_practice_owner(p_practice_id) THEN
    RAISE EXCEPTION 'list_practice_clients: caller % is not a member of practice %',
      v_caller, p_practice_id
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT c.id,
         c.name,
         c.video_consent,
         c.consent_confirmed_at,
         c.avatar_path,
         CASE
           WHEN c.avatar_path IS NOT NULL AND length(c.avatar_path) > 0
           THEN public.sign_storage_url('raw-archive', c.avatar_path, 3600)
           ELSE NULL
         END AS avatar_url,
         COALESCE(c.client_exercise_defaults, '{}'::jsonb) AS client_exercise_defaults,
         (SELECT MAX(COALESCE(p.sent_at, p.created_at))
            FROM plans p
           WHERE p.client_id = c.id
             AND p.deleted_at IS NULL) AS last_plan_at
    FROM clients c
   WHERE c.practice_id = p_practice_id
     AND c.deleted_at IS NULL
   ORDER BY last_plan_at DESC NULLS LAST, c.name ASC;
END;
$function$;

-- Function: public.list_practice_members_and_pending(p_practice_id uuid)
CREATE OR REPLACE FUNCTION public.list_practice_members_and_pending(p_practice_id uuid)
 RETURNS TABLE(trainer_id uuid, email text, full_name text, role text, joined_at timestamp with time zone, is_current_user boolean, is_pending boolean, added_by uuid, added_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Same 42702 guard as add_practice_member_by_email — OUT column names
-- collide with real table columns inside the UNION body (pm.role,
-- ppm.email, etc.). See the comment there for detail.
#variable_conflict use_column
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth required' USING ERRCODE = '28000';
  END IF;

  -- Any practice member can see the roster + pending. Transparency is
  -- the Wave 5 design choice; we keep it for Wave 14.
  IF NOT (p_practice_id IN (SELECT public.user_practice_ids())) THEN
    RAISE EXCEPTION 'not a member of this practice'
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    pm.trainer_id                                  AS trainer_id,
    u.email::text                                  AS email,
    COALESCE(
      (u.raw_user_meta_data->>'full_name'),
      (u.raw_user_meta_data->>'name'),
      ''
    )::text                                        AS full_name,
    pm.role                                        AS role,
    pm.joined_at                                   AS joined_at,
    (pm.trainer_id = auth.uid())                   AS is_current_user,
    FALSE                                          AS is_pending,
    NULL::uuid                                     AS added_by,
    NULL::timestamptz                              AS added_at
  FROM public.practice_members pm
  JOIN auth.users u ON u.id = pm.trainer_id
  WHERE pm.practice_id = p_practice_id

  UNION ALL

  SELECT
    NULL::uuid                                     AS trainer_id,
    ppm.email::text                                AS email,
    ''::text                                       AS full_name,
    'practitioner'::text                           AS role,
    NULL::timestamptz                              AS joined_at,
    FALSE                                          AS is_current_user,
    TRUE                                           AS is_pending,
    ppm.added_by                                   AS added_by,
    ppm.added_at                                   AS added_at
  FROM public.pending_practice_members ppm
  WHERE ppm.practice_id = p_practice_id

  ORDER BY is_pending ASC, joined_at ASC NULLS LAST, added_at ASC NULLS LAST;
END;
$function$;

-- Function: public.list_practice_members_with_profile(p_practice_id uuid)
CREATE OR REPLACE FUNCTION public.list_practice_members_with_profile(p_practice_id uuid)
 RETURNS TABLE(trainer_id uuid, email text, full_name text, role text, joined_at timestamp with time zone, is_current_user boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth required' USING ERRCODE = '28000';
  END IF;

  -- Any practice member can see fellow members. Use the helper fn rather
  -- than a direct subquery on practice_members (avoids RLS recursion).
  IF NOT (p_practice_id IN (SELECT public.user_practice_ids())) THEN
    RAISE EXCEPTION 'not a member of this practice'
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
    SELECT
      pm.trainer_id,
      u.email::text,
      COALESCE(
        (u.raw_user_meta_data->>'full_name'),
        (u.raw_user_meta_data->>'name'),
        ''
      )::text AS full_name,
      pm.role,
      pm.joined_at,
      (pm.trainer_id = auth.uid()) AS is_current_user
    FROM public.practice_members pm
    JOIN auth.users u ON u.id = pm.trainer_id
    WHERE pm.practice_id = p_practice_id
    ORDER BY pm.joined_at;
END;
$function$;

-- Function: public.list_practice_plans(p_practice_id uuid)
CREATE OR REPLACE FUNCTION public.list_practice_plans(p_practice_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_caller    uuid    := auth.uid();
  v_is_owner  boolean := public.user_is_practice_owner(p_practice_id);
  v_is_member boolean := p_practice_id = ANY(ARRAY(SELECT public.user_practice_ids()));
  v_plans     jsonb;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'list_practice_plans requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_practice_id IS NULL THEN
    RAISE EXCEPTION 'list_practice_plans: p_practice_id is required'
      USING ERRCODE = '22023';
  END IF;

  IF NOT v_is_member AND NOT v_is_owner THEN
    RAISE EXCEPTION 'list_practice_plans: caller % is not a member of practice %',
      v_caller, p_practice_id
      USING ERRCODE = '42501';
  END IF;

  WITH visible_plans AS (
    SELECT p.*
      FROM plans p
     WHERE p.practice_id = p_practice_id
       AND p.deleted_at IS NULL
       AND (
         v_is_owner
         OR NOT EXISTS (
              SELECT 1 FROM plan_issuances pi
               WHERE pi.plan_id = p.id
            )
         OR EXISTS (
              SELECT 1 FROM plan_issuances pi
               WHERE pi.plan_id    = p.id
                 AND pi.trainer_id = v_caller
            )
       )
  ),
  plan_exercises AS (
    SELECT
      e.plan_id,
      jsonb_agg(
        jsonb_build_object(
          'id',                  e.id,
          'position',            e.position,
          'name',                e.name,
          'media_url',           e.media_url,
          'line_drawing_url',    CASE
                                   WHEN e.media_type = 'rest' THEN NULL
                                   ELSE e.media_url
                                 END,
          'thumbnail_url',       e.thumbnail_url,
          'media_type',          e.media_type,
          'notes',               e.notes,
          'circuit_id',          e.circuit_id,
          'include_audio',       e.include_audio,
          'created_at',          e.created_at,
          'preferred_treatment', e.preferred_treatment,
          'prep_seconds',        e.prep_seconds,
          'start_offset_ms',     e.start_offset_ms,
          'end_offset_ms',       e.end_offset_ms,
          'video_reps_per_loop', e.video_reps_per_loop,
          'aspect_ratio',        e.aspect_ratio,
          'rotation_quarters',   e.rotation_quarters,
          'body_focus',          e.body_focus,
          'rest_seconds',        e.rest_seconds,
          'sets',                COALESCE(
                                   (SELECT jsonb_agg(
                                             jsonb_build_object(
                                               'position',                s.position,
                                               'reps',                    s.reps,
                                               'hold_seconds',            s.hold_seconds,
                                               'weight_kg',               s.weight_kg,
                                               'breather_seconds_after',  s.breather_seconds_after
                                             )
                                             ORDER BY s.position
                                           )
                                      FROM public.exercise_sets s
                                     WHERE s.exercise_id = e.id),
                                   '[]'::jsonb
                                 )
        )
        ORDER BY e.position
      ) AS exercises
    FROM exercises e
    JOIN visible_plans vp ON vp.id = e.plan_id
    GROUP BY e.plan_id
  ),
  latest_issuance AS (
    SELECT DISTINCT ON (pi.plan_id)
           pi.plan_id,
           pi.trainer_id  AS last_trainer_id,
           pi.issued_at   AS last_issued_at
      FROM plan_issuances pi
      JOIN visible_plans vp ON vp.id = pi.plan_id
     ORDER BY pi.plan_id, pi.issued_at DESC
  )
  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'id',                              vp.id,
               'practice_id',                     vp.practice_id,
               'client_id',                       vp.client_id,
               'client_name',                     COALESCE(c.name, vp.client_name),
               'title',                           vp.title,
               'circuit_cycles',                  vp.circuit_cycles,
               'circuit_names',                   vp.circuit_names,
               'preferred_rest_interval_seconds', vp.preferred_rest_interval_seconds,
               'created_at',                      vp.created_at,
               'sent_at',                         vp.sent_at,
               'version',                         vp.version,
               'first_opened_at',                 vp.first_opened_at,
               'last_opened_at',                  vp.last_opened_at,
               'deleted_at',                      vp.deleted_at,
               'crossfade_lead_ms',               vp.crossfade_lead_ms,
               'crossfade_fade_ms',               vp.crossfade_fade_ms,
               'unlock_credit_prepaid_at',        vp.unlock_credit_prepaid_at,
               'last_published_at',               li.last_issued_at,
               'last_trainer_id',                 li.last_trainer_id,
               'exercises',                       COALESCE(pe.exercises, '[]'::jsonb)
             )
             ORDER BY COALESCE(li.last_issued_at, vp.created_at) DESC NULLS LAST, vp.id
           ),
           '[]'::jsonb
         )
    INTO v_plans
    FROM visible_plans vp
    LEFT JOIN clients          c  ON c.id     = vp.client_id
    LEFT JOIN latest_issuance  li ON li.plan_id = vp.id
    LEFT JOIN plan_exercises   pe ON pe.plan_id = vp.id;

  RETURN jsonb_build_object('plans', v_plans);
END;
$function$;

-- Function: public.list_practice_sessions(p_practice_id uuid)
CREATE OR REPLACE FUNCTION public.list_practice_sessions(p_practice_id uuid)
 RETURNS TABLE(id uuid, title text, client_name text, trainer_id uuid, trainer_email text, version integer, last_published_at timestamp with time zone, first_opened_at timestamp with time zone, issuance_count integer, exercise_count integer, is_own_session boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_uid       uuid    := auth.uid();
  v_is_owner  boolean := public.user_is_practice_owner(p_practice_id);
  v_is_member boolean := p_practice_id = ANY(ARRAY(SELECT public.user_practice_ids()));
BEGIN
  IF NOT v_is_member THEN
    RAISE EXCEPTION 'not a member of this practice' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH latest_issuance AS (
    -- Most recent publish per plan, in this practice. Carries trainer_id
    -- (who published last) and issued_at (our "last_published_at").
    SELECT DISTINCT ON (pi.plan_id)
           pi.plan_id,
           pi.trainer_id  AS last_trainer_id,
           pi.issued_at   AS last_issued_at
      FROM plan_issuances pi
     WHERE pi.practice_id = p_practice_id
     ORDER BY pi.plan_id, pi.issued_at DESC
  ),
  issuance_counts AS (
    SELECT pi.plan_id, COUNT(*)::integer AS issuance_count
      FROM plan_issuances pi
     WHERE pi.practice_id = p_practice_id
     GROUP BY pi.plan_id
  ),
  exercise_counts AS (
    SELECT e.plan_id, COUNT(*)::integer AS exercise_count
      FROM exercises e
     WHERE e.media_type IS DISTINCT FROM 'rest'
     GROUP BY e.plan_id
  )
  SELECT
    p.id,
    p.title,
    COALESCE(c.name, p.client_name)           AS client_name,
    li.last_trainer_id                         AS trainer_id,
    u.email::text                              AS trainer_email,
    p.version,
    li.last_issued_at                          AS last_published_at,
    p.first_opened_at,
    COALESCE(ic.issuance_count, 0)             AS issuance_count,
    COALESCE(ec.exercise_count, 0)             AS exercise_count,
    (li.last_trainer_id = v_uid)               AS is_own_session
  FROM plans p
  LEFT JOIN clients          c  ON p.client_id    = c.id
  LEFT JOIN latest_issuance  li ON p.id           = li.plan_id
  LEFT JOIN auth.users       u  ON li.last_trainer_id = u.id
  LEFT JOIN issuance_counts  ic ON p.id           = ic.plan_id
  LEFT JOIN exercise_counts  ec ON p.id           = ec.plan_id
  WHERE p.practice_id = p_practice_id
    AND (
      v_is_owner
      OR li.last_trainer_id = v_uid
    )
  ORDER BY li.last_issued_at DESC NULLS LAST, p.id;
END;
$function$;

-- Function: public.list_sessions_for_client(p_client_id uuid)
CREATE OR REPLACE FUNCTION public.list_sessions_for_client(p_client_id uuid)
 RETURNS TABLE(id uuid, title text, client_name text, trainer_id uuid, trainer_email text, version integer, last_published_at timestamp with time zone, first_opened_at timestamp with time zone, issuance_count integer, exercise_count integer, is_own_session boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_uid          uuid    := auth.uid();
  v_practice_id  uuid;
  v_is_owner     boolean;
  v_is_member    boolean;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'list_sessions_for_client requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_client_id IS NULL THEN
    RAISE EXCEPTION 'list_sessions_for_client: p_client_id is required'
      USING ERRCODE = '22023';
  END IF;

  SELECT c.practice_id INTO v_practice_id
    FROM public.clients c
   WHERE c.id = p_client_id
     AND c.deleted_at IS NULL
   LIMIT 1;

  IF v_practice_id IS NULL THEN
    RETURN;
  END IF;

  v_is_owner  := public.user_is_practice_owner(v_practice_id);
  v_is_member := v_practice_id = ANY(ARRAY(SELECT public.user_practice_ids()));

  IF NOT v_is_member AND NOT v_is_owner THEN
    RAISE EXCEPTION 'list_sessions_for_client: caller % is not a member of practice %',
      v_uid, v_practice_id
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH latest_issuance AS (
    SELECT DISTINCT ON (pi.plan_id)
           pi.plan_id,
           pi.trainer_id  AS last_trainer_id,
           pi.issued_at   AS last_issued_at
      FROM plan_issuances pi
     WHERE pi.practice_id = v_practice_id
     ORDER BY pi.plan_id, pi.issued_at DESC
  ),
  issuance_counts AS (
    SELECT pi.plan_id, COUNT(*)::integer AS issuance_count
      FROM plan_issuances pi
     WHERE pi.practice_id = v_practice_id
     GROUP BY pi.plan_id
  ),
  exercise_counts AS (
    SELECT e.plan_id, COUNT(*)::integer AS exercise_count
      FROM exercises e
     WHERE e.media_type IS DISTINCT FROM 'rest'
     GROUP BY e.plan_id
  )
  SELECT
    p.id,
    p.title,
    COALESCE(c.name, p.client_name)            AS client_name,
    li.last_trainer_id                          AS trainer_id,
    u.email::text                               AS trainer_email,
    p.version,
    li.last_issued_at                           AS last_published_at,
    p.first_opened_at,
    COALESCE(ic.issuance_count, 0)              AS issuance_count,
    COALESCE(ec.exercise_count, 0)              AS exercise_count,
    (li.last_trainer_id = v_uid)                AS is_own_session
  FROM plans p
  LEFT JOIN clients          c  ON p.client_id    = c.id
  LEFT JOIN latest_issuance  li ON p.id           = li.plan_id
  LEFT JOIN auth.users       u  ON li.last_trainer_id = u.id
  LEFT JOIN issuance_counts  ic ON p.id           = ic.plan_id
  LEFT JOIN exercise_counts  ec ON p.id           = ec.plan_id
  WHERE p.client_id = p_client_id
    AND p.deleted_at IS NULL
    AND (
      v_is_owner
      OR li.last_trainer_id = v_uid
    )
  ORDER BY li.last_issued_at DESC NULLS LAST, p.id;
END;
$function$;

-- Function: public.log_analytics_event(p_session_id uuid, p_event_kind text, p_exercise_id uuid, p_event_data jsonb)
CREATE OR REPLACE FUNCTION public.log_analytics_event(p_session_id uuid, p_event_kind text, p_exercise_id uuid DEFAULT NULL::uuid, p_event_data jsonb DEFAULT NULL::jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_consent   BOOLEAN;
  v_last_at   TIMESTAMPTZ;
BEGIN
  -- Validate session exists and consent is granted
  SELECT consent_granted INTO v_consent
    FROM client_sessions
   WHERE id = p_session_id;

  IF NOT FOUND OR v_consent IS NOT TRUE THEN
    RETURN; -- silently skip
  END IF;

  -- Rate limit: skip if last event for this session was < 1 second ago
  SELECT MAX(occurred_at) INTO v_last_at
    FROM plan_analytics_events
   WHERE client_session_id = p_session_id;

  IF v_last_at IS NOT NULL AND (now() - v_last_at) < interval '1 second' THEN
    RETURN; -- rate-limited
  END IF;

  INSERT INTO plan_analytics_events (client_session_id, event_kind, exercise_id, event_data)
    VALUES (p_session_id, p_event_kind, p_exercise_id, p_event_data);
END;
$function$;

-- Function: public.log_error(p_severity text, p_kind text, p_source text, p_message text, p_meta jsonb, p_practice_id uuid, p_sha text)
CREATE OR REPLACE FUNCTION public.log_error(p_severity text, p_kind text, p_source text, p_message text DEFAULT NULL::text, p_meta jsonb DEFAULT NULL::jsonb, p_practice_id uuid DEFAULT NULL::uuid, p_sha text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_id uuid;
BEGIN
  IF p_severity IS NULL OR p_severity NOT IN ('warn','error','fatal') THEN
    RAISE EXCEPTION 'log_error: severity must be one of warn/error/fatal (got %)', p_severity
      USING ERRCODE = '22023';
  END IF;
  IF p_kind IS NULL OR length(p_kind) = 0 THEN
    RAISE EXCEPTION 'log_error: kind is required' USING ERRCODE = '22023';
  END IF;
  IF p_source IS NULL OR length(p_source) = 0 THEN
    RAISE EXCEPTION 'log_error: source is required' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.error_logs
    (severity, kind, source, message, meta, practice_id, trainer_id, sha)
  VALUES
    (p_severity, p_kind, p_source, p_message, p_meta, p_practice_id, auth.uid(), p_sha)
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$function$;

-- Function: public.log_share_event(p_practice_id uuid, p_channel text, p_event_kind text, p_meta jsonb)
CREATE OR REPLACE FUNCTION public.log_share_event(p_practice_id uuid, p_channel text, p_event_kind text, p_meta jsonb DEFAULT NULL::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$;

-- Function: public.practice_credit_balance(p_practice_id uuid)
CREATE OR REPLACE FUNCTION public.practice_credit_balance(p_practice_id uuid)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT COALESCE(SUM(delta), 0)::integer
    FROM credit_ledger
   WHERE practice_id = p_practice_id;
$function$;

-- Function: public.practice_has_credits(p_practice_id uuid, p_cost integer)
CREATE OR REPLACE FUNCTION public.practice_has_credits(p_practice_id uuid, p_cost integer)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT public.practice_credit_balance(p_practice_id) >= COALESCE(p_cost, 0);
$function$;

-- Function: public.practice_rebate_balance(p_practice_id uuid)
CREATE OR REPLACE FUNCTION public.practice_rebate_balance(p_practice_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT COALESCE(SUM(credits), 0)::numeric(10,4)
    FROM referral_rebate_ledger
   WHERE referrer_practice_id = p_practice_id;
$function$;

-- Function: public.record_audit_event(p_practice_id uuid, p_kind text, p_ref_id uuid, p_meta jsonb, p_actor_id uuid)
CREATE OR REPLACE FUNCTION public.record_audit_event(p_practice_id uuid, p_kind text, p_ref_id uuid DEFAULT NULL::uuid, p_meta jsonb DEFAULT NULL::jsonb, p_actor_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_id uuid;
BEGIN
  INSERT INTO public.audit_events (practice_id, actor_id, kind, ref_id, meta)
  VALUES (
    p_practice_id,
    COALESCE(p_actor_id, auth.uid()),
    p_kind,
    p_ref_id,
    p_meta
  )
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$function$;

-- Function: public.record_plan_opened(p_plan_id uuid)
CREATE OR REPLACE FUNCTION public.record_plan_opened(p_plan_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_practice_id uuid;
BEGIN
  IF p_plan_id IS NULL THEN
    -- No-op on null; the web player can call this defensively.
    RETURN;
  END IF;

  -- Stamp first_opened_at / last_opened_at and capture the practice for the
  -- audit insert in one round-trip.
  UPDATE plans
     SET first_opened_at = COALESCE(first_opened_at, now()),
         last_opened_at  = now()
   WHERE id = p_plan_id
  RETURNING practice_id INTO v_practice_id;

  -- Plan not found → don't fabricate an audit row.
  IF v_practice_id IS NULL THEN
    RETURN;
  END IF;

  -- Drop a `plan.opened` audit_events row. Actor NULL — the anon web player
  -- has no auth.uid(). The audit page renders actor IS NULL as the literal
  -- "Client" label.
  INSERT INTO public.audit_events (practice_id, actor_id, kind, ref_id, meta)
  VALUES (
    v_practice_id,
    NULL,
    'plan.opened',
    p_plan_id,
    NULL
  );
END;
$function$;

-- Function: public.record_purchase_with_rebates(p_practice_id uuid, p_credits integer, p_amount_zar numeric, p_payfast_payment_id text, p_bundle_key text, p_cost_per_credit_zar numeric, p_trainer_id uuid)
CREATE OR REPLACE FUNCTION public.record_purchase_with_rebates(p_practice_id uuid, p_credits integer, p_amount_zar numeric, p_payfast_payment_id text, p_bundle_key text, p_cost_per_credit_zar numeric, p_trainer_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_purchase_id          uuid;
  v_referral             practice_referrals%ROWTYPE;
  v_rebate_rows          integer := 0;
  v_rebate_credits       numeric(10,4);
  v_goodwill_applied     boolean := false;
BEGIN
  IF p_practice_id IS NULL THEN
    RAISE EXCEPTION 'record_purchase_with_rebates: p_practice_id is required'
      USING ERRCODE = '22023';
  END IF;
  IF p_credits IS NULL OR p_credits <= 0 THEN
    RAISE EXCEPTION 'record_purchase_with_rebates: p_credits must be positive'
      USING ERRCODE = '22023';
  END IF;
  IF p_amount_zar IS NULL OR p_amount_zar <= 0 THEN
    RAISE EXCEPTION 'record_purchase_with_rebates: p_amount_zar must be positive'
      USING ERRCODE = '22023';
  END IF;
  IF p_cost_per_credit_zar IS NULL OR p_cost_per_credit_zar <= 0 THEN
    RAISE EXCEPTION 'record_purchase_with_rebates: p_cost_per_credit_zar must be positive'
      USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_referral
    FROM practice_referrals
   WHERE referee_practice_id = p_practice_id
   LIMIT 1;

  -- Wave 40.5: stamp trainer_id on the purchase ledger row
  INSERT INTO credit_ledger (practice_id, delta, type, payfast_payment_id, notes, trainer_id)
  VALUES (
    p_practice_id,
    p_credits,
    'purchase',
    p_payfast_payment_id,
    'PayFast ' || COALESCE(p_bundle_key, 'bundle') || ' (' || p_credits::text || ' credits)',
    p_trainer_id
  )
  RETURNING id INTO v_purchase_id;

  IF v_referral.referrer_practice_id IS NOT NULL THEN
    v_rebate_credits := ROUND(
      (p_amount_zar * 0.05) / p_cost_per_credit_zar,
      4
    );

    IF NOT COALESCE(v_referral.goodwill_floor_applied, false)
       AND v_rebate_credits < 1 THEN
      v_rebate_credits := 1;
      v_goodwill_applied := true;
    END IF;

    IF v_rebate_credits > 0 THEN
      INSERT INTO referral_rebate_ledger
        (referrer_practice_id, referee_practice_id,
         source_credit_ledger_id, kind, credits, zar_amount)
      VALUES
        (v_referral.referrer_practice_id, v_referral.referee_practice_id,
         v_purchase_id, 'lifetime_rebate', v_rebate_credits, p_amount_zar);
      v_rebate_rows := v_rebate_rows + 1;
    END IF;

    IF NOT COALESCE(v_referral.goodwill_floor_applied, false) THEN
      UPDATE practice_referrals
         SET goodwill_floor_applied = true
       WHERE referee_practice_id = v_referral.referee_practice_id;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'ok',                 true,
    'purchase_ledger_id', v_purchase_id,
    'rebate_rows',        v_rebate_rows,
    'goodwill_applied',   v_goodwill_applied
  );
END;
$function$;

-- Function: public.referral_dashboard_stats(p_practice_id uuid)
CREATE OR REPLACE FUNCTION public.referral_dashboard_stats(p_practice_id uuid)
 RETURNS TABLE(rebate_balance_credits numeric, lifetime_rebate_credits numeric, referee_count integer, qualifying_spend_total_zar numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller  uuid := auth.uid();
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'referral_dashboard_stats requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM practice_members
     WHERE practice_id = p_practice_id AND trainer_id = v_caller
  ) THEN
    RAISE EXCEPTION 'referral_dashboard_stats: caller is not a member of practice %',
      p_practice_id
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
    SELECT
      COALESCE(SUM(rl.credits), 0)::numeric(10,4) AS rebate_balance_credits,
      COALESCE(SUM(CASE WHEN rl.kind <> 'redeemed' THEN rl.credits ELSE 0 END), 0)::numeric(10,4)
                                                  AS lifetime_rebate_credits,
      (SELECT COUNT(*)::int
         FROM practice_referrals pr
        WHERE pr.referrer_practice_id = p_practice_id) AS referee_count,
      COALESCE((
        SELECT SUM(zar_amount)
          FROM referral_rebate_ledger rl2
         WHERE rl2.referrer_practice_id = p_practice_id
           AND rl2.kind = 'lifetime_rebate'
      ), 0)::numeric(10,2) AS qualifying_spend_total_zar
    FROM referral_rebate_ledger rl
   WHERE rl.referrer_practice_id = p_practice_id;
END;
$function$;

-- Function: public.referral_referees_list(p_practice_id uuid)
CREATE OR REPLACE FUNCTION public.referral_referees_list(p_practice_id uuid)
 RETURNS TABLE(referee_label text, referee_practice_id uuid, is_named boolean, joined_at timestamp with time zone, qualifying_spend_zar numeric, rebate_earned_credits numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller uuid := auth.uid();
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'referral_referees_list requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM practice_members
     WHERE practice_id = p_practice_id AND trainer_id = v_caller
  ) THEN
    RAISE EXCEPTION 'referral_referees_list: caller is not a member of practice %',
      p_practice_id
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH ordered AS (
    SELECT
      pr.referee_practice_id,
      pr.referee_named_consent,
      pr.claimed_at,
      ROW_NUMBER() OVER (ORDER BY pr.claimed_at ASC) AS ordinal
      FROM practice_referrals pr
     WHERE pr.referrer_practice_id = p_practice_id
  ),
  earned AS (
    SELECT
      rl.referee_practice_id,
      SUM(CASE WHEN rl.kind <> 'redeemed' THEN rl.credits ELSE 0 END) AS credits_earned,
      SUM(CASE WHEN rl.kind = 'lifetime_rebate' THEN rl.zar_amount ELSE 0 END) AS zar_spend
      FROM referral_rebate_ledger rl
     WHERE rl.referrer_practice_id = p_practice_id
     GROUP BY rl.referee_practice_id
  )
  SELECT
    CASE
      WHEN o.referee_named_consent THEN COALESCE(p.name, 'Practice ' || o.ordinal::text)
      ELSE 'Practice ' || o.ordinal::text
    END AS referee_label,
    CASE WHEN o.referee_named_consent THEN o.referee_practice_id ELSE NULL END
      AS referee_practice_id,
    o.referee_named_consent AS is_named,
    o.claimed_at AS joined_at,
    COALESCE(e.zar_spend, 0)::numeric(10,2) AS qualifying_spend_zar,
    COALESCE(e.credits_earned, 0)::numeric(10,4) AS rebate_earned_credits
    FROM ordered o
    LEFT JOIN earned e
      ON e.referee_practice_id = o.referee_practice_id
    LEFT JOIN practices p
      ON p.id = o.referee_practice_id
   ORDER BY o.ordinal ASC;
END;
$function$;

-- Function: public.refund_credit(p_plan_id uuid)
CREATE OR REPLACE FUNCTION public.refund_credit(p_plan_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller          uuid := auth.uid();
  v_consumption     credit_ledger%ROWTYPE;
  v_already_refunded boolean;
  v_is_member       boolean;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'refund_credit requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_plan_id IS NULL THEN
    RAISE EXCEPTION 'refund_credit: p_plan_id is required'
      USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_consumption
    FROM credit_ledger
   WHERE plan_id = p_plan_id
     AND type    = 'consumption'
   ORDER BY created_at DESC
   LIMIT 1;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM practice_members
     WHERE practice_id = v_consumption.practice_id
       AND trainer_id  = v_caller
  ) INTO v_is_member;

  IF NOT v_is_member THEN
    RAISE EXCEPTION 'refund_credit: caller % is not a member of practice %',
      v_caller, v_consumption.practice_id
      USING ERRCODE = '42501';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM credit_ledger
     WHERE plan_id = p_plan_id
       AND type    = 'refund'
  ) INTO v_already_refunded;

  IF v_already_refunded THEN
    RETURN false;
  END IF;

  -- Wave 40.5: stamp trainer_id
  INSERT INTO credit_ledger (practice_id, delta, type, plan_id, notes, trainer_id)
  VALUES (
    v_consumption.practice_id,
    ABS(v_consumption.delta),
    'refund',
    p_plan_id,
    'refund_credit(' || p_plan_id::text || ')',
    v_caller
  );

  RETURN true;
END;
$function$;

-- Function: public.remove_pending_practice_member(p_practice_id uuid, p_email text)
CREATE OR REPLACE FUNCTION public.remove_pending_practice_member(p_practice_id uuid, p_email text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth required' USING ERRCODE = '28000';
  END IF;

  IF NOT public.user_is_practice_owner(p_practice_id) THEN
    RAISE EXCEPTION 'owner-only' USING ERRCODE = '42501';
  END IF;

  DELETE FROM public.pending_practice_members
   WHERE email       = lower(trim(COALESCE(p_email, '')))::citext
     AND practice_id = p_practice_id;
END;
$function$;

-- Function: public.remove_practice_member(p_practice_id uuid, p_trainer_id uuid)
CREATE OR REPLACE FUNCTION public.remove_practice_member(p_practice_id uuid, p_trainer_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller     uuid := auth.uid();
  v_role       text;
  v_owner_count int;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'auth required' USING ERRCODE = '28000';
  END IF;

  IF NOT public.user_is_practice_owner(p_practice_id) THEN
    RAISE EXCEPTION 'owner-only' USING ERRCODE = '42501';
  END IF;

  IF p_trainer_id = v_caller THEN
    RAISE EXCEPTION 'use leave_practice to remove yourself'
      USING ERRCODE = '22023';
  END IF;

  -- Lock the target row. P0002 if they're not a member.
  SELECT pm.role
    INTO v_role
    FROM public.practice_members pm
   WHERE pm.practice_id = p_practice_id
     AND pm.trainer_id  = p_trainer_id
   FOR UPDATE;

  IF v_role IS NULL THEN
    RAISE EXCEPTION 'member not found' USING ERRCODE = 'P0002';
  END IF;

  -- Last-owner guard.
  IF v_role = 'owner' THEN
    SELECT COUNT(*)
      INTO v_owner_count
      FROM public.practice_members
     WHERE practice_id = p_practice_id
       AND role = 'owner'
       AND trainer_id <> p_trainer_id;

    IF v_owner_count = 0 THEN
      RAISE EXCEPTION 'cannot remove the last owner'
        USING ERRCODE = '22023';
    END IF;
  END IF;

  -- Wave 14 retired practice_invite_codes; the legacy "revoke unclaimed
  -- codes" UPDATE has been removed. Nothing else to clean up before the
  -- DELETE — auth.users + credit_ledger + plan_issuances are FK-attached
  -- to auth.users, not to this pivot, so they survive the removal.

  DELETE FROM public.practice_members
   WHERE practice_id = p_practice_id
     AND trainer_id  = p_trainer_id;
END;
$function$;

-- Function: public.rename_client(p_client_id uuid, p_new_name text)
CREATE OR REPLACE FUNCTION public.rename_client(p_client_id uuid, p_new_name text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_practice_id uuid;
  v_deleted_at  timestamptz;
  v_trimmed text := btrim(coalesce(p_new_name, ''));
BEGIN
  IF v_trimmed = '' THEN
    RAISE EXCEPTION 'name required' USING ERRCODE = '22023';
  END IF;

  SELECT practice_id, deleted_at INTO v_practice_id, v_deleted_at
  FROM clients
  WHERE id = p_client_id;

  IF v_practice_id IS NULL THEN
    RAISE EXCEPTION 'client not found' USING ERRCODE = 'P0002';
  END IF;

  IF v_deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'client has been deleted' USING ERRCODE = '22023';
  END IF;

  IF NOT (v_practice_id IN (SELECT public.user_practice_ids())) THEN
    RAISE EXCEPTION 'not a member of this client''s practice'
      USING ERRCODE = '42501';
  END IF;

  BEGIN
    UPDATE clients
    SET name = v_trimmed,
        updated_at = now()
    WHERE id = p_client_id;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'a client with that name already exists'
      USING ERRCODE = '23505';
  END;
END;
$function$;

-- Function: public.rename_practice(p_practice_id uuid, p_new_name text)
CREATE OR REPLACE FUNCTION public.rename_practice(p_practice_id uuid, p_new_name text)
 RETURNS SETOF practices
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_trimmed text := btrim(coalesce(p_new_name, ''));
BEGIN
  -- Empty-after-trim → named error.
  IF v_trimmed = '' THEN
    RAISE EXCEPTION 'name required' USING ERRCODE = '22023';
  END IF;

  -- Length cap. 60 chars is the UX contract for dashboard rendering.
  IF char_length(v_trimmed) > 60 THEN
    RAISE EXCEPTION 'name too long (max 60 chars)' USING ERRCODE = '22023';
  END IF;

  -- Existence check BEFORE the ownership check so the error surface is
  -- "practice not found" (P0002) rather than "not a member" (42501) for
  -- a bad uuid. Same precedence rename_client uses.
  IF NOT EXISTS (SELECT 1 FROM practices WHERE id = p_practice_id) THEN
    RAISE EXCEPTION 'practice not found' USING ERRCODE = 'P0002';
  END IF;

  -- Owner-only. `user_is_practice_owner` is the Milestone C SECURITY
  -- DEFINER helper — bypasses RLS on practice_members so we don't
  -- self-recurse. Practitioners (non-owner members) hit this branch.
  IF NOT public.user_is_practice_owner(p_practice_id) THEN
    RAISE EXCEPTION 'only the practice owner can rename it'
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  UPDATE practices
     SET name = v_trimmed
   WHERE id = p_practice_id
  RETURNING *;
END;
$function$;

-- Function: public.rename_session(p_plan_id uuid, p_new_title text)
CREATE OR REPLACE FUNCTION public.rename_session(p_plan_id uuid, p_new_title text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller       uuid := auth.uid();
  v_practice_id  uuid;
  v_trimmed      text := btrim(coalesce(p_new_title, ''));
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'rename_session requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_plan_id IS NULL THEN
    RAISE EXCEPTION 'rename_session: p_plan_id is required'
      USING ERRCODE = '22023';
  END IF;

  IF v_trimmed = '' THEN
    RAISE EXCEPTION 'rename_session: title required'
      USING ERRCODE = '22023';
  END IF;

  -- Look up the practice so we can gate membership. SECURITY DEFINER
  -- bypasses RLS — gate explicitly.
  SELECT practice_id INTO v_practice_id
    FROM plans
   WHERE id = p_plan_id
   LIMIT 1;

  IF v_practice_id IS NULL THEN
    RAISE EXCEPTION 'rename_session: plan % not found', p_plan_id
      USING ERRCODE = 'P0002';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM practice_members
     WHERE practice_id = v_practice_id AND trainer_id = v_caller
  ) AND NOT public.user_is_practice_owner(v_practice_id) THEN
    RAISE EXCEPTION 'rename_session: caller % is not a member of practice %',
      v_caller, v_practice_id
      USING ERRCODE = '42501';
  END IF;

  UPDATE plans
     SET title = v_trimmed
   WHERE id = p_plan_id;
END;
$function$;

-- Function: public.replace_plan_exercises(p_plan_id uuid, p_rows jsonb)
CREATE OR REPLACE FUNCTION public.replace_plan_exercises(p_plan_id uuid, p_rows jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller        uuid := auth.uid();
  v_practice_id   uuid;
  v_fallback_ids  uuid[] := ARRAY[]::uuid[];
  v_plan_version  integer;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'replace_plan_exercises requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_plan_id IS NULL THEN
    RAISE EXCEPTION 'replace_plan_exercises: p_plan_id is required'
      USING ERRCODE = '22023';
  END IF;

  SELECT practice_id INTO v_practice_id
    FROM public.plans
   WHERE id = p_plan_id
   LIMIT 1;

  IF v_practice_id IS NULL THEN
    RAISE EXCEPTION 'replace_plan_exercises: plan % not found', p_plan_id
      USING ERRCODE = '22023';
  END IF;

  IF NOT (v_practice_id IN (SELECT public.user_practice_ids())) THEN
    RAISE EXCEPTION 'replace_plan_exercises: caller % is not a member of practice %',
      v_caller, v_practice_id
      USING ERRCODE = '42501';
  END IF;

  IF EXISTS (
    SELECT 1
      FROM jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) AS r
     WHERE r ? 'plan_id'
       AND NULLIF(r->>'plan_id', '') IS NOT NULL
       AND (r->>'plan_id')::uuid IS DISTINCT FROM p_plan_id
  ) THEN
    RAISE EXCEPTION
      'replace_plan_exercises: per-row plan_id must match p_plan_id (%)', p_plan_id
      USING ERRCODE = '22023';
  END IF;

  -- Wipe + rewrite. Cascade FK on exercise_sets → exercises drops child rows.
  DELETE FROM public.exercises WHERE plan_id = p_plan_id;

  IF jsonb_array_length(coalesce(p_rows, '[]'::jsonb)) > 0 THEN
    INSERT INTO public.exercises (
      id,
      plan_id,
      position,
      name,
      media_url,
      thumbnail_url,
      media_type,
      notes,
      circuit_id,
      include_audio,
      preferred_treatment,
      prep_seconds,
      video_reps_per_loop,
      start_offset_ms,
      end_offset_ms,
      aspect_ratio,
      rotation_quarters,
      body_focus,
      rest_seconds,
      focus_frame_offset_ms,
      hero_crop_offset
    )
    SELECT
      (r->>'id')::uuid,
      p_plan_id,
      (r->>'position')::integer,
      r->>'name',
      r->>'media_url',
      r->>'thumbnail_url',
      r->>'media_type',
      r->>'notes',
      r->>'circuit_id',
      COALESCE((r->>'include_audio')::boolean, false),
      r->>'preferred_treatment',
      NULLIF(r->>'prep_seconds', '')::integer,
      NULLIF(r->>'video_reps_per_loop', '')::integer,
      NULLIF(r->>'start_offset_ms', '')::integer,
      NULLIF(r->>'end_offset_ms', '')::integer,
      NULLIF(r->>'aspect_ratio', '')::numeric,
      NULLIF(r->>'rotation_quarters', '')::smallint,
      NULLIF(r->>'body_focus', '')::boolean,
      NULLIF(r->>'rest_seconds', '')::integer,
      NULLIF(r->>'focus_frame_offset_ms', '')::integer,
      NULLIF(r->>'hero_crop_offset', '')::numeric
    FROM jsonb_array_elements(p_rows) AS r;

    -- Child set rows. For each exercise in p_rows, expand its `sets` array.
    -- Wave 43: includes hold_position. Unknown values fall back to the new
    -- default 'end_of_set' — keeps stale TestFlight builds publishing.
    INSERT INTO public.exercise_sets (
      exercise_id,
      position,
      reps,
      hold_seconds,
      hold_position,
      weight_kg,
      breather_seconds_after
    )
    SELECT
      (r->>'id')::uuid                                        AS exercise_id,
      COALESCE((s.value->>'position')::integer, s.ordinality::integer) AS position,
      GREATEST(COALESCE(NULLIF(s.value->>'reps', '')::integer, 1), 1)   AS reps,
      GREATEST(COALESCE(NULLIF(s.value->>'hold_seconds', '')::integer, 0), 0) AS hold_seconds,
      CASE
        WHEN s.value->>'hold_position' IN ('per_rep', 'end_of_set', 'end_of_exercise')
          THEN s.value->>'hold_position'
        ELSE 'end_of_set'
      END                                                     AS hold_position,
      NULLIF(s.value->>'weight_kg', '')::numeric(5,1)         AS weight_kg,
      GREATEST(COALESCE(NULLIF(s.value->>'breather_seconds_after', '')::integer, 60), 0) AS breather_seconds_after
    FROM jsonb_array_elements(p_rows) AS r,
         LATERAL jsonb_array_elements(COALESCE(r->'sets', '[]'::jsonb))
           WITH ORDINALITY AS s(value, ordinality)
    WHERE r->>'media_type' IN ('video', 'photo')
      AND jsonb_array_length(COALESCE(r->'sets', '[]'::jsonb)) > 0;

    -- Synthetic single-set fallback for video/photo rows that arrived
    -- without a `sets` array. Keeps publishes from old clients (or buggy
    -- callers) playable instead of silently empty. Defaults
    -- hold_position = 'end_of_set' to match the per-row column default.
    WITH inserted AS (
      INSERT INTO public.exercise_sets (
        exercise_id, position, reps, hold_seconds, hold_position, weight_kg, breather_seconds_after
      )
      SELECT
        (r->>'id')::uuid, 1, 1, 0, 'end_of_set', NULL, 60
        FROM jsonb_array_elements(p_rows) AS r
       WHERE r->>'media_type' IN ('video', 'photo')
         AND jsonb_array_length(COALESCE(r->'sets', '[]'::jsonb)) = 0
      RETURNING exercise_id
    )
    SELECT COALESCE(array_agg(exercise_id), ARRAY[]::uuid[])
      INTO v_fallback_ids
      FROM inserted;
  END IF;

  SELECT version INTO v_plan_version
    FROM public.plans
   WHERE id = p_plan_id
   LIMIT 1;

  RETURN jsonb_build_object(
    'plan_version',             v_plan_version,
    'fallback_set_exercise_ids', to_jsonb(v_fallback_ids)
  );
END;
$function$;

-- Function: public.restore_client(p_client_id uuid)
CREATE OR REPLACE FUNCTION public.restore_client(p_client_id uuid)
 RETURNS TABLE(id uuid, practice_id uuid, name text, deleted_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller      uuid := auth.uid();
  v_practice_id uuid;
  v_deleted_ts  timestamptz;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'restore_client requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_client_id IS NULL THEN
    RAISE EXCEPTION 'restore_client: p_client_id is required'
      USING ERRCODE = '22023';
  END IF;

  SELECT c.practice_id, c.deleted_at
    INTO v_practice_id, v_deleted_ts
    FROM clients c
   WHERE c.id = p_client_id
   LIMIT 1;

  IF v_practice_id IS NULL THEN
    RETURN;
  END IF;

  IF NOT (v_practice_id IN (SELECT public.user_practice_ids())) THEN
    RAISE EXCEPTION 'restore_client: caller % is not a member of practice %',
      v_caller, v_practice_id
      USING ERRCODE = '42501';
  END IF;

  IF v_deleted_ts IS NULL THEN
    RETURN QUERY
    SELECT c.id, c.practice_id, c.name, c.deleted_at
      FROM clients c
     WHERE c.id = p_client_id;
    RETURN;
  END IF;

  -- Wave 40.5: clear deleted_by_user_id on restore
  UPDATE clients AS c
     SET deleted_at = NULL,
         updated_at = now(),
         deleted_by_user_id = NULL
   WHERE c.id = p_client_id;

  UPDATE plans AS p
     SET deleted_at = NULL
   WHERE p.client_id = p_client_id
     AND p.deleted_at = v_deleted_ts;

  INSERT INTO audit_events (practice_id, actor_id, kind, ref_id)
  VALUES (v_practice_id, v_caller, 'client.restore', p_client_id);

  RETURN QUERY
  SELECT c.id, c.practice_id, c.name, c.deleted_at
    FROM clients c
   WHERE c.id = p_client_id;
END;
$function$;

-- Function: public.revoke_analytics_consent(p_plan_id uuid, p_session_id uuid)
CREATE OR REPLACE FUNCTION public.revoke_analytics_consent(p_plan_id uuid, p_session_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  -- SEC-2 (H-3): require that (session_id, plan_id) actually exists. Anon
  -- callers can no longer kill analytics for arbitrary plans by guessing
  -- a session UUID. Genuine revoke calls from the web player carry the
  -- real session id minted by start_analytics_session.
  IF p_plan_id IS NULL OR p_session_id IS NULL THEN
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM client_sessions
     WHERE id = p_session_id
       AND plan_id = p_plan_id
  ) THEN
    RETURN;
  END IF;

  -- Revoke consent on the current session
  UPDATE client_sessions
     SET consent_granted = false,
         consent_decided_at = now()
   WHERE id = p_session_id
     AND plan_id = p_plan_id;

  -- Record plan-level opt-out for future sessions
  INSERT INTO plan_analytics_opt_outs (plan_id)
    VALUES (p_plan_id)
    ON CONFLICT (plan_id) DO NOTHING;
END;
$function$;

-- Function: public.revoke_referral_code(p_practice_id uuid)
CREATE OR REPLACE FUNCTION public.revoke_referral_code(p_practice_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller uuid := auth.uid();
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'revoke_referral_code requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF NOT user_is_practice_owner(p_practice_id) THEN
    RAISE EXCEPTION 'revoke_referral_code: caller is not owner of practice %',
      p_practice_id
      USING ERRCODE = '42501';
  END IF;

  -- Delete the active row so generate_referral_code can insert a fresh slug.
  -- Historical practice_referrals rows stay intact (code_used is free text).
  -- We use DELETE-and-regenerate instead of "revoked_at" + PK contention
  -- because the PK is practice_id — only one row per practice allowed.
  -- If you need to preserve the audit of "what code was used" long-term,
  -- the slug is already copied to practice_referrals.code_used.
  DELETE FROM referral_codes WHERE practice_id = p_practice_id;

  RETURN true;
END;
$function$;

-- Function: public.set_analytics_consent(p_session_id uuid, p_granted boolean)
CREATE OR REPLACE FUNCTION public.set_analytics_consent(p_session_id uuid, p_granted boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  UPDATE client_sessions
     SET consent_granted = p_granted,
         consent_decided_at = now()
   WHERE id = p_session_id;
END;
$function$;

-- Function: public.set_client_avatar(p_client_id uuid, p_avatar_path text)
CREATE OR REPLACE FUNCTION public.set_client_avatar(p_client_id uuid, p_avatar_path text)
 RETURNS TABLE(id uuid, practice_id uuid, name text, avatar_path text, video_consent jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller       uuid := auth.uid();
  v_practice_id  uuid;
  v_deleted_at   timestamptz;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'set_client_avatar requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_client_id IS NULL THEN
    RAISE EXCEPTION 'set_client_avatar: p_client_id is required'
      USING ERRCODE = '22023';
  END IF;

  -- p_avatar_path NULL is allowed: lets the practitioner clear the avatar
  -- (e.g. "remove avatar" affordance). Empty string normalised to NULL so
  -- the column never carries a sentinel.
  IF p_avatar_path = '' THEN
    p_avatar_path := NULL;
  END IF;

  SELECT c.practice_id, c.deleted_at
    INTO v_practice_id, v_deleted_at
    FROM clients c
   WHERE c.id = p_client_id
   LIMIT 1;

  IF v_practice_id IS NULL THEN
    RAISE EXCEPTION 'set_client_avatar: client % not found', p_client_id
      USING ERRCODE = '22023';
  END IF;

  IF v_deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'set_client_avatar: client has been deleted'
      USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM practice_members pm
     WHERE pm.practice_id = v_practice_id AND pm.trainer_id = v_caller
  ) AND NOT public.user_is_practice_owner(v_practice_id) THEN
    RAISE EXCEPTION 'set_client_avatar: caller % is not a member of practice %',
      v_caller, v_practice_id
      USING ERRCODE = '42501';
  END IF;

  UPDATE clients c
     SET avatar_path = p_avatar_path
   WHERE c.id = p_client_id;

  RETURN QUERY
  SELECT c.id, c.practice_id, c.name, c.avatar_path, c.video_consent
    FROM clients c
   WHERE c.id = p_client_id;
END;
$function$;

-- Function: public.set_client_exercise_default(p_client_id uuid, p_field text, p_value jsonb)
CREATE OR REPLACE FUNCTION public.set_client_exercise_default(p_client_id uuid, p_field text, p_value jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller   UUID := auth.uid();
  v_practice UUID;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'set_client_exercise_default requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_client_id IS NULL THEN
    RAISE EXCEPTION 'set_client_exercise_default: p_client_id is required'
      USING ERRCODE = '22023';
  END IF;

  IF p_field IS NULL OR length(trim(p_field)) = 0 THEN
    RAISE EXCEPTION 'set_client_exercise_default: p_field must be non-empty'
      USING ERRCODE = '22023';
  END IF;

  SELECT practice_id INTO v_practice
    FROM public.clients
   WHERE id = p_client_id
   LIMIT 1;

  IF v_practice IS NULL THEN
    RAISE EXCEPTION 'set_client_exercise_default: client % not found', p_client_id
      USING ERRCODE = '22023';
  END IF;

  -- Fix: IN (SELECT SRF()) instead of = ANY (SRF).
  IF NOT (v_practice IN (SELECT public.user_practice_ids())) THEN
    RAISE EXCEPTION 'set_client_exercise_default: caller % is not a member of practice %',
      v_caller, v_practice
      USING ERRCODE = '42501';
  END IF;

  UPDATE public.clients
     SET client_exercise_defaults = jsonb_set(
           COALESCE(client_exercise_defaults, '{}'::jsonb),
           ARRAY[p_field],
           COALESCE(p_value, 'null'::jsonb),
           true
         )
   WHERE id = p_client_id;
END;
$function$;

-- Function: public.set_client_video_consent(p_client_id uuid, p_line_drawing boolean, p_grayscale boolean, p_original boolean)
CREATE OR REPLACE FUNCTION public.set_client_video_consent(p_client_id uuid, p_line_drawing boolean, p_grayscale boolean, p_original boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_existing_avatar boolean;
BEGIN
  SELECT COALESCE((video_consent ->> 'avatar')::boolean, false)
    INTO v_existing_avatar
    FROM clients WHERE id = p_client_id;

  PERFORM public.set_client_video_consent(
    p_client_id,
    p_line_drawing,
    p_grayscale,
    p_original,
    COALESCE(v_existing_avatar, false)
  );
END;
$function$;

-- Function: public.set_client_video_consent(p_client_id uuid, p_line_drawing boolean, p_grayscale boolean, p_original boolean, p_avatar boolean)
CREATE OR REPLACE FUNCTION public.set_client_video_consent(p_client_id uuid, p_line_drawing boolean, p_grayscale boolean, p_original boolean, p_avatar boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_existing_analytics boolean;
BEGIN
  SELECT COALESCE((video_consent ->> 'analytics_allowed')::boolean, true)
    INTO v_existing_analytics
    FROM clients WHERE id = p_client_id;

  PERFORM public.set_client_video_consent(
    p_client_id,
    p_line_drawing,
    p_grayscale,
    p_original,
    p_avatar,
    COALESCE(v_existing_analytics, true)
  );
END;
$function$;

-- Function: public.set_client_video_consent(p_client_id uuid, p_line_drawing boolean, p_grayscale boolean, p_original boolean, p_avatar boolean, p_analytics_allowed boolean)
CREATE OR REPLACE FUNCTION public.set_client_video_consent(p_client_id uuid, p_line_drawing boolean, p_grayscale boolean, p_original boolean, p_avatar boolean, p_analytics_allowed boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller       uuid := auth.uid();
  v_practice_id  uuid;
  v_deleted_at   timestamptz;
  v_prev_consent jsonb;
  v_new_consent  jsonb;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'set_client_video_consent requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_client_id IS NULL THEN
    RAISE EXCEPTION 'set_client_video_consent: p_client_id is required'
      USING ERRCODE = '22023';
  END IF;

  IF p_line_drawing IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'set_client_video_consent: line_drawing consent cannot be withdrawn (must be true)'
      USING ERRCODE = '22023';
  END IF;

  SELECT practice_id, deleted_at, video_consent
    INTO v_practice_id, v_deleted_at, v_prev_consent
    FROM clients WHERE id = p_client_id LIMIT 1;

  IF v_practice_id IS NULL THEN
    RAISE EXCEPTION 'set_client_video_consent: client % not found', p_client_id
      USING ERRCODE = '22023';
  END IF;

  IF v_deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'set_client_video_consent: client has been deleted'
      USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM practice_members
     WHERE practice_id = v_practice_id AND trainer_id = v_caller
  ) AND NOT public.user_is_practice_owner(v_practice_id) THEN
    RAISE EXCEPTION 'set_client_video_consent: caller % is not a member of practice %',
      v_caller, v_practice_id
      USING ERRCODE = '42501';
  END IF;

  v_new_consent := jsonb_build_object(
    'line_drawing', true,
    'grayscale',    COALESCE(p_grayscale, false),
    'original',     COALESCE(p_original, false),
    'avatar',       COALESCE(p_avatar, false),
    'analytics_allowed', COALESCE(p_analytics_allowed, true)
  );

  UPDATE clients
     SET video_consent = v_new_consent,
         consent_confirmed_at = now()
   WHERE id = p_client_id;

  IF v_prev_consent IS DISTINCT FROM v_new_consent THEN
    INSERT INTO public.audit_events (
      practice_id,
      actor_id,
      kind,
      ref_id,
      meta
    ) VALUES (
      v_practice_id,
      v_caller,
      'client.consent.update',
      p_client_id,
      jsonb_build_object(
        'from', v_prev_consent,
        'to',   v_new_consent
      )
    );
  END IF;
END;
$function$;

-- Function: public.set_practice_member_role(p_practice_id uuid, p_trainer_id uuid, p_new_role text)
CREATE OR REPLACE FUNCTION public.set_practice_member_role(p_practice_id uuid, p_trainer_id uuid, p_new_role text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller     uuid := auth.uid();
  v_old_role   text;
  v_owner_count int;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'auth required' USING ERRCODE = '28000';
  END IF;

  IF NOT public.user_is_practice_owner(p_practice_id) THEN
    RAISE EXCEPTION 'owner-only' USING ERRCODE = '42501';
  END IF;

  IF p_trainer_id = v_caller THEN
    RAISE EXCEPTION 'cannot change your own role'
      USING ERRCODE = '22023';
  END IF;

  IF p_new_role NOT IN ('owner', 'practitioner') THEN
    RAISE EXCEPTION 'invalid role: %', p_new_role
      USING ERRCODE = '22023';
  END IF;

  -- Lock the target row so a concurrent update can't race the last-owner
  -- check. If the row doesn't exist, P0002 bubbles up.
  SELECT pm.role
    INTO v_old_role
    FROM public.practice_members pm
   WHERE pm.practice_id = p_practice_id
     AND pm.trainer_id  = p_trainer_id
   FOR UPDATE;

  IF v_old_role IS NULL THEN
    RAISE EXCEPTION 'member not found' USING ERRCODE = 'P0002';
  END IF;

  IF v_old_role = p_new_role THEN
    -- No-op: role already matches. Return without writing.
    RETURN;
  END IF;

  -- Demotion check: if we're demoting the target from 'owner' to
  -- 'practitioner', make sure at least one OTHER owner exists.
  IF v_old_role = 'owner' AND p_new_role <> 'owner' THEN
    SELECT COUNT(*)
      INTO v_owner_count
      FROM public.practice_members
     WHERE practice_id = p_practice_id
       AND role = 'owner'
       AND trainer_id <> p_trainer_id;

    IF v_owner_count = 0 THEN
      RAISE EXCEPTION 'cannot demote the last owner'
        USING ERRCODE = '22023';
    END IF;
  END IF;

  UPDATE public.practice_members
     SET role = p_new_role
   WHERE practice_id = p_practice_id
     AND trainer_id  = p_trainer_id;
END;
$function$;

-- Function: public.sign_practice_raw_archive_url(p_practice_id uuid, p_plan_id uuid, p_exercise_id uuid, p_expires_in integer, p_extension text)
CREATE OR REPLACE FUNCTION public.sign_practice_raw_archive_url(p_practice_id uuid, p_plan_id uuid, p_exercise_id uuid, p_expires_in integer DEFAULT 1800, p_extension text DEFAULT 'mp4'::text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'extensions'
AS $function$
DECLARE
  v_caller    uuid    := auth.uid();
  v_is_owner  boolean := public.user_is_practice_owner(p_practice_id);
  v_is_member boolean := p_practice_id = ANY(ARRAY(SELECT public.user_practice_ids()));
  v_ext       text;
  v_path      text;
  v_url       text;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'sign_practice_raw_archive_url requires authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_practice_id IS NULL OR p_plan_id IS NULL OR p_exercise_id IS NULL THEN
    RAISE EXCEPTION 'sign_practice_raw_archive_url: all uuid args are required'
      USING ERRCODE = '22023';
  END IF;

  IF NOT v_is_owner AND NOT v_is_member THEN
    RAISE EXCEPTION 'sign_practice_raw_archive_url: caller % is not a member of practice %',
      v_caller, p_practice_id
      USING ERRCODE = '42501';
  END IF;

  -- Whitelist the extension to a small known set. The bucket layout only
  -- ever has mp4 (videos) and jpg (photos); anything else is a bug.
  -- Strip a leading dot for tolerance (caller can pass `.mp4` or `mp4`).
  v_ext := lower(coalesce(nullif(p_extension, ''), 'mp4'));
  IF left(v_ext, 1) = '.' THEN
    v_ext := substr(v_ext, 2);
  END IF;
  IF v_ext NOT IN ('mp4', 'jpg') THEN
    RAISE EXCEPTION 'sign_practice_raw_archive_url: unsupported extension %', v_ext
      USING ERRCODE = '22023';
  END IF;

  v_path := p_practice_id::text || '/' || p_plan_id::text || '/' ||
            p_exercise_id::text || '.' || v_ext;

  v_url := public.sign_storage_url(
    p_bucket      => 'raw-archive',
    p_path        => v_path,
    p_expires_in  => p_expires_in
  );

  RETURN v_url;
END;
$function$;

-- Function: public.sign_storage_url(p_bucket text, p_path text, p_expires_in integer)
CREATE OR REPLACE FUNCTION public.sign_storage_url(p_bucket text, p_path text, p_expires_in integer DEFAULT 1800)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_jwt_secret  text;
  v_base_url    text;
  v_token       text;
  v_payload     jsonb;
BEGIN
  IF p_bucket IS NULL OR p_path IS NULL THEN
    RETURN NULL;
  END IF;

  -- Pull the JWT secret + base URL from vault. Use a safe SELECT so a missing
  -- row just returns NULL (instead of erroring).
  SELECT decrypted_secret INTO v_jwt_secret
    FROM vault.decrypted_secrets
   WHERE name = 'supabase_jwt_secret'
   LIMIT 1;

  SELECT decrypted_secret INTO v_base_url
    FROM vault.decrypted_secrets
   WHERE name = 'supabase_url'
   LIMIT 1;

  IF v_jwt_secret IS NULL OR length(v_jwt_secret) = 0
     OR v_base_url IS NULL OR length(v_base_url) = 0 THEN
    RETURN NULL;
  END IF;

  v_payload := jsonb_build_object(
    'url', p_bucket || '/' || p_path,
    'iat', extract(epoch from now())::bigint,
    'exp', extract(epoch from now())::bigint + COALESCE(p_expires_in, 1800)
  );

  -- extensions.sign takes json (not jsonb). Cast explicitly so the right
  -- overload resolves.
  v_token := extensions.sign(v_payload::json, v_jwt_secret, 'HS256');

  RETURN rtrim(v_base_url, '/')
      || '/storage/v1/object/sign/'
      || p_bucket
      || '/'
      || p_path
      || '?token='
      || v_token;
EXCEPTION
  WHEN others THEN
    -- Never propagate signing failures out of the SELECT path; degrade to NULL.
    RETURN NULL;
END;
$function$;

-- Function: public.signed_url_self_check()
CREATE OR REPLACE FUNCTION public.signed_url_self_check()
 RETURNS TABLE(ok boolean, jwt_secret_present boolean, supabase_url_present boolean, sample_url text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_jwt_present boolean;
  v_url_present boolean;
  v_url         text;
BEGIN
  -- Probe the vault secrets. Silent-NULL-on-missing is the current
  -- `sign_storage_url` contract, so we check presence explicitly here.
  v_jwt_present := EXISTS (
    SELECT 1
      FROM vault.decrypted_secrets
     WHERE name = 'supabase_jwt_secret'
       AND decrypted_secret IS NOT NULL
       AND length(decrypted_secret) > 0
  );
  v_url_present := EXISTS (
    SELECT 1
      FROM vault.decrypted_secrets
     WHERE name = 'supabase_url'
       AND decrypted_secret IS NOT NULL
       AND length(decrypted_secret) > 0
  );

  jwt_secret_present   := v_jwt_present;
  supabase_url_present := v_url_present;

  IF v_jwt_present AND v_url_present THEN
    BEGIN
      -- Exercise the signing path. The path doesn't need to exist —
      -- we're only asserting that signing succeeds end-to-end.
      v_url := public.sign_storage_url(
        'raw-archive',
        'selfcheck/nonexistent.mp4',
        60
      );
      ok := v_url IS NOT NULL;
      -- Trim the URL to 48 chars so we don't leak a full usable token
      -- into wherever this ends up logged. Prefix is enough to eyeball
      -- "looks right" vs "returned NULL".
      sample_url := CASE
        WHEN v_url IS NOT NULL THEN substring(v_url, 1, 48) || '...'
        ELSE NULL
      END;
    EXCEPTION WHEN others THEN
      ok := false;
      sample_url := NULL;
    END;
  ELSE
    ok := false;
    sample_url := NULL;
  END IF;

  RETURN NEXT;
END;
$function$;

-- Function: public.start_analytics_session(p_plan_id uuid, p_user_agent_bucket text)
CREATE OR REPLACE FUNCTION public.start_analytics_session(p_plan_id uuid, p_user_agent_bucket text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_client_id         UUID;
  v_analytics_allowed BOOLEAN;
  v_session_id        UUID;
BEGIN
  -- Check plan exists and resolve client
  SELECT client_id INTO v_client_id
    FROM plans
   WHERE id = p_plan_id
     AND deleted_at IS NULL;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  -- Check plan-level opt-out (from revoke_analytics_consent)
  IF EXISTS (SELECT 1 FROM plan_analytics_opt_outs WHERE plan_id = p_plan_id) THEN
    RETURN NULL;
  END IF;

  -- Check client-level analytics consent.
  -- Default TRUE when key is missing (per design doc).
  IF v_client_id IS NOT NULL THEN
    SELECT COALESCE((video_consent ->> 'analytics_allowed')::boolean, true)
      INTO v_analytics_allowed
      FROM clients
     WHERE id = v_client_id
       AND deleted_at IS NULL;

    IF NOT FOUND THEN
      RETURN NULL;
    END IF;

    IF v_analytics_allowed IS FALSE THEN
      RETURN NULL;
    END IF;
  END IF;

  INSERT INTO client_sessions (plan_id, user_agent_bucket)
    VALUES (p_plan_id, p_user_agent_bucket)
    RETURNING id INTO v_session_id;

  RETURN v_session_id;
END;
$function$;

-- Function: public.unlock_plan_for_edit(p_plan_id uuid)
CREATE OR REPLACE FUNCTION public.unlock_plan_for_edit(p_plan_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller       uuid := auth.uid();
  v_practice_id  uuid;
  v_prepaid_at   timestamptz;
  v_balance      integer;
  v_new_balance  integer;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'unlock_plan_for_edit requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_plan_id IS NULL THEN
    RAISE EXCEPTION 'unlock_plan_for_edit: p_plan_id is required'
      USING ERRCODE = '22023';
  END IF;

  SELECT practice_id, unlock_credit_prepaid_at
    INTO v_practice_id, v_prepaid_at
    FROM plans
   WHERE id = p_plan_id
   LIMIT 1;

  IF v_practice_id IS NULL THEN
    RAISE EXCEPTION 'unlock_plan_for_edit: plan % not found', p_plan_id
      USING ERRCODE = 'P0002';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM practice_members
     WHERE practice_id = v_practice_id AND trainer_id = v_caller
  ) THEN
    RAISE EXCEPTION 'unlock_plan_for_edit: caller % is not a member of practice %',
      v_caller, v_practice_id
      USING ERRCODE = '42501';
  END IF;

  -- SEC-2 (M-B4): publish-time consent backstop. A malformed plan can't
  -- even pre-pay an unlock; rejection happens before any credit is moved.
  -- validate_plan_treatment_consent does its own membership check.
  IF EXISTS (
    SELECT 1 FROM public.validate_plan_treatment_consent(p_plan_id)
  ) THEN
    RAISE EXCEPTION
      'unlock_plan_for_edit: plan % has exercises with unconsented treatments', p_plan_id
      USING ERRCODE = 'P0003';
  END IF;

  -- Already prepaid (idempotent re-tap from the sheet): return current
  -- balance + the existing stamp. No double-charge.
  IF v_prepaid_at IS NOT NULL THEN
    SELECT COALESCE(SUM(delta), 0)::integer
      INTO v_balance
      FROM credit_ledger
     WHERE practice_id = v_practice_id;
    RETURN jsonb_build_object(
      'ok',          true,
      'balance',     v_balance,
      'prepaid_at',  v_prepaid_at
    );
  END IF;

  PERFORM 1 FROM practices WHERE id = v_practice_id FOR UPDATE;
  PERFORM 1 FROM plans     WHERE id = p_plan_id     FOR UPDATE;

  SELECT COALESCE(SUM(delta), 0)::integer
    INTO v_balance
    FROM credit_ledger
   WHERE practice_id = v_practice_id;

  IF v_balance < 1 THEN
    RETURN jsonb_build_object(
      'ok',      false,
      'reason',  'insufficient_credits',
      'balance', v_balance
    );
  END IF;

  -- HOTFIX: trainer_id added (Wave 40.5 actor coverage).
  INSERT INTO credit_ledger (practice_id, delta, type, plan_id, notes, trainer_id)
  VALUES (
    v_practice_id,
    -1,
    'consumption',
    p_plan_id,
    'unlock_plan_for_edit',
    v_caller
  );

  v_new_balance := v_balance - 1;

  UPDATE plans
     SET unlock_credit_prepaid_at = now()
   WHERE id = p_plan_id
  RETURNING unlock_credit_prepaid_at INTO v_prepaid_at;

  RETURN jsonb_build_object(
    'ok',          true,
    'balance',     v_new_balance,
    'prepaid_at',  v_prepaid_at
  );
END;
$function$;

-- Function: public.upsert_client(p_practice_id uuid, p_name text)
CREATE OR REPLACE FUNCTION public.upsert_client(p_practice_id uuid, p_name text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller uuid := auth.uid();
  v_id     uuid;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'upsert_client requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_practice_id IS NULL THEN
    RAISE EXCEPTION 'upsert_client: p_practice_id is required'
      USING ERRCODE = '22023';
  END IF;

  IF p_name IS NULL OR length(trim(p_name)) = 0 THEN
    RAISE EXCEPTION 'upsert_client: p_name must be non-empty'
      USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM practice_members
     WHERE practice_id = p_practice_id AND trainer_id = v_caller
  ) AND NOT public.user_is_practice_owner(p_practice_id) THEN
    RAISE EXCEPTION 'upsert_client: caller % is not a member of practice %',
      v_caller, p_practice_id
      USING ERRCODE = '42501';
  END IF;

  SELECT id INTO v_id
    FROM clients
   WHERE practice_id = p_practice_id AND name = trim(p_name)
   LIMIT 1;

  IF v_id IS NOT NULL THEN
    RETURN v_id;
  END IF;

  -- Wave 40.5: stamp created_by_user_id
  INSERT INTO clients (practice_id, name, created_by_user_id)
  VALUES (p_practice_id, trim(p_name), v_caller)
  ON CONFLICT (practice_id, name) DO UPDATE SET name = EXCLUDED.name
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$function$;

-- Function: public.upsert_client_with_id(p_id uuid, p_practice_id uuid, p_name text)
CREATE OR REPLACE FUNCTION public.upsert_client_with_id(p_id uuid, p_practice_id uuid, p_name text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_trimmed     text := btrim(coalesce(p_name, ''));
  v_existing_id uuid;
BEGIN
  IF v_trimmed = '' THEN
    RAISE EXCEPTION 'name required' USING ERRCODE = '22023';
  END IF;

  IF NOT (p_practice_id IN (SELECT public.user_practice_ids())) THEN
    RAISE EXCEPTION 'not a member of this practice'
      USING ERRCODE = '42501';
  END IF;

  IF EXISTS (SELECT 1 FROM clients WHERE id = p_id) THEN
    RETURN p_id;
  END IF;

  SELECT id INTO v_existing_id
  FROM clients
  WHERE practice_id = p_practice_id AND name = v_trimmed;
  IF v_existing_id IS NOT NULL THEN
    RETURN v_existing_id;
  END IF;

  -- Wave 40.5: stamp created_by_user_id
  INSERT INTO clients (id, practice_id, name, created_by_user_id)
  VALUES (p_id, p_practice_id, v_trimmed, auth.uid());
  RETURN p_id;
END;
$function$;

-- Function: public.user_is_practice_owner(pid uuid)
CREATE OR REPLACE FUNCTION public.user_is_practice_owner(pid uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM practice_members
    WHERE practice_id = pid AND trainer_id = auth.uid() AND role = 'owner'
  );
$function$;

-- Function: public.user_practice_ids()
CREATE OR REPLACE FUNCTION public.user_practice_ids()
 RETURNS SETOF uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ SELECT practice_id FROM practice_members WHERE trainer_id = auth.uid(); $function$;

-- Function: public.validate_plan_treatment_consent(p_plan_id uuid)
CREATE OR REPLACE FUNCTION public.validate_plan_treatment_consent(p_plan_id uuid)
 RETURNS TABLE(exercise_id uuid, preferred_treatment text, consent_key text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller       uuid := auth.uid();
  v_practice_id  uuid;
  v_client_id    uuid;
  v_consent      jsonb;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'validate_plan_treatment_consent requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_plan_id IS NULL THEN
    RAISE EXCEPTION 'validate_plan_treatment_consent: p_plan_id is required'
      USING ERRCODE = '22023';
  END IF;

  -- Resolve plan + membership. SECURITY DEFINER bypasses RLS, so we must
  -- check membership explicitly.
  SELECT p.practice_id, p.client_id
    INTO v_practice_id, v_client_id
    FROM public.plans p
   WHERE p.id = p_plan_id
     AND p.deleted_at IS NULL
   LIMIT 1;

  IF v_practice_id IS NULL THEN
    RAISE EXCEPTION 'validate_plan_treatment_consent: plan % not found', p_plan_id
      USING ERRCODE = 'P0002';
  END IF;

  IF NOT (v_practice_id IN (SELECT public.user_practice_ids())) THEN
    RAISE EXCEPTION 'validate_plan_treatment_consent: caller % is not a member of practice %',
      v_caller, v_practice_id
      USING ERRCODE = '42501';
  END IF;

  -- Legacy plans without client_id: nothing to validate; return empty.
  IF v_client_id IS NULL THEN
    RETURN;
  END IF;

  SELECT c.video_consent
    INTO v_consent
    FROM public.clients c
   WHERE c.id = v_client_id
   LIMIT 1;

  -- Missing consent row (shouldn't happen — FK from plans to clients
  -- guarantees the row exists, and the default is always set). Treat as
  -- no violations rather than blocking — matches get_plan_full's fallback
  -- of "line-drawing only" for robustness.
  IF v_consent IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT
    e.id                                        AS exercise_id,
    e.preferred_treatment                       AS preferred_treatment,
    CASE e.preferred_treatment
      WHEN 'line'      THEN 'line_drawing'
      WHEN 'grayscale' THEN 'grayscale'
      WHEN 'original'  THEN 'original'
    END                                         AS consent_key
    FROM public.exercises e
   WHERE e.plan_id = p_plan_id
     AND e.preferred_treatment IS NOT NULL
     AND e.preferred_treatment IN ('grayscale', 'original')
     AND COALESCE(
           (v_consent ->> CASE e.preferred_treatment
             WHEN 'grayscale' THEN 'grayscale'
             WHEN 'original'  THEN 'original'
           END)::boolean,
           false
         ) = false
   ORDER BY e.position NULLS LAST, e.id;
END;
$function$;

-- ============================================================================
-- Section 7: Triggers
-- ============================================================================

CREATE TRIGGER "trg_clients_touch_updated_at" BEFORE UPDATE ON "public"."clients"
    FOR EACH ROW EXECUTE FUNCTION _clients_touch_updated_at();

CREATE TRIGGER "trg_exercise_sets_touch_updated_at" BEFORE UPDATE ON "public"."exercise_sets"
    FOR EACH ROW EXECUTE FUNCTION _exercise_sets_touch_updated_at();

CREATE TRIGGER "trg_enforce_single_tier_referral" BEFORE INSERT ON "public"."practice_referrals"
    FOR EACH ROW EXECUTE FUNCTION enforce_single_tier_referral();

-- ============================================================================
-- Section 8: Views
-- ============================================================================

CREATE OR REPLACE VIEW "public"."publish_health" AS
 SELECT practice_id,
    count(*) FILTER (WHERE ((NOT (id IN ( SELECT DISTINCT plan_issuances.plan_id
           FROM plan_issuances))) AND (created_at < (now() - '00:10:00'::interval)))) AS stuck_pending,
    count(DISTINCT id) FILTER (WHERE ((created_at > (now() - '24:00:00'::interval)) AND (version > COALESCE(( SELECT count(*) AS count
           FROM plan_issuances pi
          WHERE (pi.plan_id = p.id)), (0)::bigint)))) AS failed_24h,
    COALESCE(( SELECT count(*) AS count
           FROM plan_issuances pi
          WHERE ((pi.practice_id = p.practice_id) AND (pi.issued_at > (now() - '24:00:00'::interval)))), (0)::bigint) AS succeeded_24h,
    ( SELECT max(pi.issued_at) AS max
           FROM plan_issuances pi
          WHERE (pi.practice_id = p.practice_id)) AS last_issued_ts
   FROM plans p
  WHERE ((practice_id IS NOT NULL) AND (deleted_at IS NULL))
  GROUP BY practice_id;

-- ============================================================================
-- Section 9: Row Level Security
-- ============================================================================
-- Enable RLS on every public table (RLS state mirrors live).

ALTER TABLE "public"."audit_events" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."client_sessions" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."clients" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."credit_ledger" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."error_logs" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."exercise_sets" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."exercises" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."pending_payments" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."pending_practice_members" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."plan_analytics_daily_aggregate" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."plan_analytics_events" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."plan_analytics_opt_outs" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."plan_issuances" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."plans" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."practice_members" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."practice_referrals" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."practices" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."referral_codes" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."referral_rebate_ledger" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."share_events" ENABLE ROW LEVEL SECURITY;

-- Policies (grouped by table)

-- Policies on audit_events
CREATE POLICY "audit_events_select_own" ON "public"."audit_events"
    AS PERMISSIVE
    FOR SELECT
    TO authenticated
    USING ((practice_id IN ( SELECT user_practice_ids() AS user_practice_ids)));

-- Policies on client_sessions
CREATE POLICY "client_sessions_select_own" ON "public"."client_sessions"
    AS PERMISSIVE
    FOR SELECT
    TO authenticated
    USING ((EXISTS ( SELECT 1
   FROM plans p
  WHERE ((p.id = client_sessions.plan_id) AND (p.practice_id IN ( SELECT user_practice_ids() AS user_practice_ids))))));

-- Policies on clients
CREATE POLICY "clients_delete_member" ON "public"."clients"
    AS PERMISSIVE
    FOR DELETE
    TO public
    USING (((practice_id IN ( SELECT user_practice_ids() AS user_practice_ids)) OR user_is_practice_owner(practice_id)));
CREATE POLICY "clients_insert_member" ON "public"."clients"
    AS PERMISSIVE
    FOR INSERT
    TO public
    WITH CHECK (((practice_id IN ( SELECT user_practice_ids() AS user_practice_ids)) OR user_is_practice_owner(practice_id)));
CREATE POLICY "clients_select_member" ON "public"."clients"
    AS PERMISSIVE
    FOR SELECT
    TO public
    USING (((practice_id IN ( SELECT user_practice_ids() AS user_practice_ids)) OR user_is_practice_owner(practice_id)));
CREATE POLICY "clients_update_member" ON "public"."clients"
    AS PERMISSIVE
    FOR UPDATE
    TO public
    USING (((practice_id IN ( SELECT user_practice_ids() AS user_practice_ids)) OR user_is_practice_owner(practice_id)))
    WITH CHECK (((practice_id IN ( SELECT user_practice_ids() AS user_practice_ids)) OR user_is_practice_owner(practice_id)));

-- Policies on credit_ledger
CREATE POLICY "credit_ledger_select_own" ON "public"."credit_ledger"
    AS PERMISSIVE
    FOR SELECT
    TO public
    USING ((practice_id IN ( SELECT user_practice_ids() AS user_practice_ids)));

-- Policies on error_logs
CREATE POLICY "error_logs_select_own" ON "public"."error_logs"
    AS PERMISSIVE
    FOR SELECT
    TO authenticated
    USING (((practice_id IS NULL) OR (practice_id IN ( SELECT user_practice_ids() AS user_practice_ids))));

-- Policies on exercise_sets
CREATE POLICY "exercise_sets_select_member" ON "public"."exercise_sets"
    AS PERMISSIVE
    FOR SELECT
    TO public
    USING ((EXISTS ( SELECT 1
   FROM (exercises e
     JOIN plans p ON ((p.id = e.plan_id)))
  WHERE ((e.id = exercise_sets.exercise_id) AND ((p.practice_id IN ( SELECT user_practice_ids() AS user_practice_ids)) OR user_is_practice_owner(p.practice_id))))));

-- Policies on exercises
CREATE POLICY "exercises_delete_own" ON "public"."exercises"
    AS PERMISSIVE
    FOR DELETE
    TO public
    USING ((plan_id IN ( SELECT plans.id
   FROM plans
  WHERE (plans.practice_id IN ( SELECT user_practice_ids() AS user_practice_ids)))));
CREATE POLICY "exercises_insert_own" ON "public"."exercises"
    AS PERMISSIVE
    FOR INSERT
    TO public
    WITH CHECK ((plan_id IN ( SELECT plans.id
   FROM plans
  WHERE (plans.practice_id IN ( SELECT user_practice_ids() AS user_practice_ids)))));
CREATE POLICY "exercises_select_own" ON "public"."exercises"
    AS PERMISSIVE
    FOR SELECT
    TO public
    USING ((plan_id IN ( SELECT plans.id
   FROM plans
  WHERE (plans.practice_id IN ( SELECT user_practice_ids() AS user_practice_ids)))));
CREATE POLICY "exercises_update_own" ON "public"."exercises"
    AS PERMISSIVE
    FOR UPDATE
    TO public
    USING ((plan_id IN ( SELECT plans.id
   FROM plans
  WHERE (plans.practice_id IN ( SELECT user_practice_ids() AS user_practice_ids)))))
    WITH CHECK ((plan_id IN ( SELECT plans.id
   FROM plans
  WHERE (plans.practice_id IN ( SELECT user_practice_ids() AS user_practice_ids)))));

-- Policies on pending_payments
CREATE POLICY "pending_payments_select_own" ON "public"."pending_payments"
    AS PERMISSIVE
    FOR SELECT
    TO public
    USING ((practice_id IN ( SELECT user_practice_ids() AS user_practice_ids)));

-- Policies on pending_practice_members
CREATE POLICY "pending_practice_members_select_own" ON "public"."pending_practice_members"
    AS PERMISSIVE
    FOR SELECT
    TO authenticated
    USING ((practice_id IN ( SELECT user_practice_ids() AS user_practice_ids)));

-- Policies on plan_analytics_daily_aggregate
CREATE POLICY "plan_analytics_daily_aggregate_select_own" ON "public"."plan_analytics_daily_aggregate"
    AS PERMISSIVE
    FOR SELECT
    TO authenticated
    USING ((EXISTS ( SELECT 1
   FROM plans p
  WHERE ((p.id = plan_analytics_daily_aggregate.plan_id) AND (p.practice_id IN ( SELECT user_practice_ids() AS user_practice_ids))))));

-- Policies on plan_analytics_events
CREATE POLICY "plan_analytics_events_select_own" ON "public"."plan_analytics_events"
    AS PERMISSIVE
    FOR SELECT
    TO authenticated
    USING ((EXISTS ( SELECT 1
   FROM (client_sessions cs
     JOIN plans p ON ((p.id = cs.plan_id)))
  WHERE ((cs.id = plan_analytics_events.client_session_id) AND (p.practice_id IN ( SELECT user_practice_ids() AS user_practice_ids))))));

-- Policies on plan_analytics_opt_outs
CREATE POLICY "plan_analytics_opt_outs_select_own" ON "public"."plan_analytics_opt_outs"
    AS PERMISSIVE
    FOR SELECT
    TO authenticated
    USING ((EXISTS ( SELECT 1
   FROM plans p
  WHERE ((p.id = plan_analytics_opt_outs.plan_id) AND (p.practice_id IN ( SELECT user_practice_ids() AS user_practice_ids))))));

-- Policies on plan_issuances
CREATE POLICY "plan_issuances_insert_own" ON "public"."plan_issuances"
    AS PERMISSIVE
    FOR INSERT
    TO public
    WITH CHECK ((practice_id IN ( SELECT user_practice_ids() AS user_practice_ids)));
CREATE POLICY "plan_issuances_select_own" ON "public"."plan_issuances"
    AS PERMISSIVE
    FOR SELECT
    TO public
    USING ((practice_id IN ( SELECT user_practice_ids() AS user_practice_ids)));

-- Policies on plans
CREATE POLICY "plans_delete_own" ON "public"."plans"
    AS PERMISSIVE
    FOR DELETE
    TO public
    USING ((practice_id IN ( SELECT user_practice_ids() AS user_practice_ids)));
CREATE POLICY "plans_insert_own" ON "public"."plans"
    AS PERMISSIVE
    FOR INSERT
    TO public
    WITH CHECK ((practice_id IN ( SELECT user_practice_ids() AS user_practice_ids)));
CREATE POLICY "plans_select_own" ON "public"."plans"
    AS PERMISSIVE
    FOR SELECT
    TO public
    USING ((practice_id IN ( SELECT user_practice_ids() AS user_practice_ids)));
CREATE POLICY "plans_update_own" ON "public"."plans"
    AS PERMISSIVE
    FOR UPDATE
    TO public
    USING ((practice_id IN ( SELECT user_practice_ids() AS user_practice_ids)))
    WITH CHECK ((practice_id IN ( SELECT user_practice_ids() AS user_practice_ids)));

-- Policies on practice_members
CREATE POLICY "members_delete_owner" ON "public"."practice_members"
    AS PERMISSIVE
    FOR DELETE
    TO public
    USING (user_is_practice_owner(practice_id));
CREATE POLICY "members_insert_self_or_owner" ON "public"."practice_members"
    AS PERMISSIVE
    FOR INSERT
    TO public
    WITH CHECK ((((role = 'owner'::text) AND (trainer_id = auth.uid())) OR user_is_practice_owner(practice_id)));
CREATE POLICY "members_select_own_practices" ON "public"."practice_members"
    AS PERMISSIVE
    FOR SELECT
    TO public
    USING ((practice_id IN ( SELECT user_practice_ids() AS user_practice_ids)));
CREATE POLICY "members_update_owner" ON "public"."practice_members"
    AS PERMISSIVE
    FOR UPDATE
    TO public
    USING (user_is_practice_owner(practice_id))
    WITH CHECK (user_is_practice_owner(practice_id));

-- Policies on practice_referrals
CREATE POLICY "referral_referrals_select_either_side" ON "public"."practice_referrals"
    AS PERMISSIVE
    FOR SELECT
    TO public
    USING (((referrer_practice_id IN ( SELECT user_practice_ids() AS user_practice_ids)) OR (referee_practice_id IN ( SELECT user_practice_ids() AS user_practice_ids))));

-- Policies on practices
CREATE POLICY "practices_delete_owner" ON "public"."practices"
    AS PERMISSIVE
    FOR DELETE
    TO public
    USING (user_is_practice_owner(id));
CREATE POLICY "practices_insert_authed" ON "public"."practices"
    AS PERMISSIVE
    FOR INSERT
    TO public
    WITH CHECK ((auth.uid() IS NOT NULL));
CREATE POLICY "practices_select_member" ON "public"."practices"
    AS PERMISSIVE
    FOR SELECT
    TO public
    USING ((id IN ( SELECT user_practice_ids() AS user_practice_ids)));
CREATE POLICY "practices_update_owner" ON "public"."practices"
    AS PERMISSIVE
    FOR UPDATE
    TO public
    USING (user_is_practice_owner(id))
    WITH CHECK (user_is_practice_owner(id));

-- Policies on referral_codes
CREATE POLICY "referral_codes_select_member" ON "public"."referral_codes"
    AS PERMISSIVE
    FOR SELECT
    TO public
    USING ((practice_id IN ( SELECT user_practice_ids() AS user_practice_ids)));

-- Policies on referral_rebate_ledger
CREATE POLICY "rebate_ledger_select_referrer" ON "public"."referral_rebate_ledger"
    AS PERMISSIVE
    FOR SELECT
    TO public
    USING ((referrer_practice_id IN ( SELECT user_practice_ids() AS user_practice_ids)));

-- Policies on share_events
CREATE POLICY "share_events_select_own" ON "public"."share_events"
    AS PERMISSIVE
    FOR SELECT
    TO authenticated
    USING ((practice_id IN ( SELECT user_practice_ids() AS user_practice_ids)));

-- ============================================================================
-- Section 10: Table grants (RPC-write-only lockdown pattern preserved)
-- ============================================================================
-- Most public tables get blanket grants to anon/authenticated and rely on RLS.
-- A subset is locked down (RPC-write-only) — credit_ledger, referral_codes,
-- practice_referrals, referral_rebate_ledger, error_logs, exercise_sets,
-- pending_practice_members, share_events. The grants below mirror live ACLs exactly.

GRANT ALL ON TABLE "public"."audit_events" TO "anon";
GRANT ALL ON TABLE "public"."audit_events" TO "authenticated";
GRANT ALL ON TABLE "public"."audit_events" TO "service_role";
GRANT ALL ON TABLE "public"."client_sessions" TO "anon";
GRANT ALL ON TABLE "public"."client_sessions" TO "authenticated";
GRANT ALL ON TABLE "public"."client_sessions" TO "service_role";
GRANT ALL ON TABLE "public"."clients" TO "anon";
GRANT ALL ON TABLE "public"."clients" TO "authenticated";
GRANT ALL ON TABLE "public"."clients" TO "service_role";
REVOKE ALL ON TABLE "public"."credit_ledger" FROM "anon";
REVOKE ALL ON TABLE "public"."credit_ledger" FROM "authenticated";
GRANT SELECT ON TABLE "public"."credit_ledger" TO "authenticated";
GRANT ALL ON TABLE "public"."credit_ledger" TO "service_role";
REVOKE ALL ON TABLE "public"."error_logs" FROM "anon";
GRANT REFERENCES, SELECT, TRIGGER, TRUNCATE ON TABLE "public"."error_logs" TO "anon";
REVOKE ALL ON TABLE "public"."error_logs" FROM "authenticated";
GRANT REFERENCES, SELECT, TRIGGER, TRUNCATE ON TABLE "public"."error_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."error_logs" TO "service_role";
REVOKE ALL ON TABLE "public"."exercise_sets" FROM "anon";
GRANT REFERENCES, SELECT, TRIGGER, TRUNCATE ON TABLE "public"."exercise_sets" TO "anon";
REVOKE ALL ON TABLE "public"."exercise_sets" FROM "authenticated";
GRANT REFERENCES, SELECT, TRIGGER, TRUNCATE ON TABLE "public"."exercise_sets" TO "authenticated";
GRANT ALL ON TABLE "public"."exercise_sets" TO "service_role";
GRANT ALL ON TABLE "public"."exercises" TO "anon";
GRANT ALL ON TABLE "public"."exercises" TO "authenticated";
GRANT ALL ON TABLE "public"."exercises" TO "service_role";
GRANT ALL ON TABLE "public"."pending_payments" TO "anon";
GRANT ALL ON TABLE "public"."pending_payments" TO "authenticated";
GRANT ALL ON TABLE "public"."pending_payments" TO "service_role";
REVOKE ALL ON TABLE "public"."pending_practice_members" FROM "anon";
GRANT REFERENCES, SELECT, TRIGGER, TRUNCATE ON TABLE "public"."pending_practice_members" TO "anon";
REVOKE ALL ON TABLE "public"."pending_practice_members" FROM "authenticated";
GRANT REFERENCES, SELECT, TRIGGER, TRUNCATE ON TABLE "public"."pending_practice_members" TO "authenticated";
GRANT ALL ON TABLE "public"."pending_practice_members" TO "service_role";
GRANT ALL ON TABLE "public"."plan_analytics_daily_aggregate" TO "anon";
GRANT ALL ON TABLE "public"."plan_analytics_daily_aggregate" TO "authenticated";
GRANT ALL ON TABLE "public"."plan_analytics_daily_aggregate" TO "service_role";
GRANT ALL ON TABLE "public"."plan_analytics_events" TO "anon";
GRANT ALL ON TABLE "public"."plan_analytics_events" TO "authenticated";
GRANT ALL ON TABLE "public"."plan_analytics_events" TO "service_role";
GRANT ALL ON TABLE "public"."plan_analytics_opt_outs" TO "anon";
GRANT ALL ON TABLE "public"."plan_analytics_opt_outs" TO "authenticated";
GRANT ALL ON TABLE "public"."plan_analytics_opt_outs" TO "service_role";
GRANT ALL ON TABLE "public"."plan_issuances" TO "anon";
GRANT ALL ON TABLE "public"."plan_issuances" TO "authenticated";
GRANT ALL ON TABLE "public"."plan_issuances" TO "service_role";
GRANT ALL ON TABLE "public"."plans" TO "anon";
GRANT ALL ON TABLE "public"."plans" TO "authenticated";
GRANT ALL ON TABLE "public"."plans" TO "service_role";
GRANT ALL ON TABLE "public"."practice_members" TO "anon";
GRANT ALL ON TABLE "public"."practice_members" TO "authenticated";
GRANT ALL ON TABLE "public"."practice_members" TO "service_role";
REVOKE ALL ON TABLE "public"."practice_referrals" FROM "anon";
REVOKE ALL ON TABLE "public"."practice_referrals" FROM "authenticated";
GRANT SELECT ON TABLE "public"."practice_referrals" TO "authenticated";
GRANT ALL ON TABLE "public"."practice_referrals" TO "service_role";
GRANT ALL ON TABLE "public"."practices" TO "anon";
GRANT ALL ON TABLE "public"."practices" TO "authenticated";
GRANT ALL ON TABLE "public"."practices" TO "service_role";
GRANT ALL ON TABLE "public"."publish_health" TO "anon";
GRANT ALL ON TABLE "public"."publish_health" TO "authenticated";
GRANT ALL ON TABLE "public"."publish_health" TO "service_role";
REVOKE ALL ON TABLE "public"."referral_codes" FROM "anon";
REVOKE ALL ON TABLE "public"."referral_codes" FROM "authenticated";
GRANT SELECT ON TABLE "public"."referral_codes" TO "authenticated";
GRANT ALL ON TABLE "public"."referral_codes" TO "service_role";
REVOKE ALL ON TABLE "public"."referral_rebate_ledger" FROM "anon";
REVOKE ALL ON TABLE "public"."referral_rebate_ledger" FROM "authenticated";
GRANT SELECT ON TABLE "public"."referral_rebate_ledger" TO "authenticated";
GRANT ALL ON TABLE "public"."referral_rebate_ledger" TO "service_role";
REVOKE ALL ON TABLE "public"."share_events" FROM "anon";
GRANT REFERENCES, TRIGGER ON TABLE "public"."share_events" TO "anon";
REVOKE ALL ON TABLE "public"."share_events" FROM "authenticated";
GRANT REFERENCES, SELECT, TRIGGER ON TABLE "public"."share_events" TO "authenticated";
GRANT ALL ON TABLE "public"."share_events" TO "service_role";

-- ============================================================================
-- Section 11: Function ACLs
-- ============================================================================
-- Default for public-schema functions in Supabase is EXECUTE granted to all roles
-- (including anon). We tighten a few selectively:
--   - sign_storage_url: postgres + service_role only (anon cannot EXECUTE).
--     Mobile/web must route through sign_practice_raw_archive_url which is
--     SECURITY DEFINER and does its own membership check (see gotcha memory).
--   - consume_credit / refund_credit: blocked from anon by default Supabase
--     setup; only authenticated/service_role/postgres can call.
--
-- Anything not listed here is left at Supabase's default (EXECUTE to all roles).

REVOKE ALL ON FUNCTION "public"."can_write_to_raw_archive"(p_path text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION "public"."can_write_to_raw_archive"(p_path text) TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."can_write_to_raw_archive"(p_path text) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."can_write_to_raw_archive"(p_path text) TO "postgres";
REVOKE ALL ON FUNCTION "public"."consume_credit"(p_practice_id uuid, p_plan_id uuid, p_credits integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION "public"."consume_credit"(p_practice_id uuid, p_plan_id uuid, p_credits integer) TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."consume_credit"(p_practice_id uuid, p_plan_id uuid, p_credits integer) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."consume_credit"(p_practice_id uuid, p_plan_id uuid, p_credits integer) TO "postgres";
REVOKE ALL ON FUNCTION "public"."get_client_by_id"(p_client_id uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION "public"."get_client_by_id"(p_client_id uuid) TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."get_client_by_id"(p_client_id uuid) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."get_client_by_id"(p_client_id uuid) TO "postgres";
REVOKE ALL ON FUNCTION "public"."leave_practice"(p_practice_id uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION "public"."leave_practice"(p_practice_id uuid) TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."leave_practice"(p_practice_id uuid) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."leave_practice"(p_practice_id uuid) TO "postgres";
REVOKE ALL ON FUNCTION "public"."list_practice_clients"(p_practice_id uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION "public"."list_practice_clients"(p_practice_id uuid) TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."list_practice_clients"(p_practice_id uuid) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."list_practice_clients"(p_practice_id uuid) TO "postgres";
REVOKE ALL ON FUNCTION "public"."list_practice_members_with_profile"(p_practice_id uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION "public"."list_practice_members_with_profile"(p_practice_id uuid) TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."list_practice_members_with_profile"(p_practice_id uuid) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."list_practice_members_with_profile"(p_practice_id uuid) TO "postgres";
REVOKE ALL ON FUNCTION "public"."practice_credit_balance"(p_practice_id uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION "public"."practice_credit_balance"(p_practice_id uuid) TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."practice_credit_balance"(p_practice_id uuid) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."practice_credit_balance"(p_practice_id uuid) TO "postgres";
REVOKE ALL ON FUNCTION "public"."practice_has_credits"(p_practice_id uuid, p_cost integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION "public"."practice_has_credits"(p_practice_id uuid, p_cost integer) TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."practice_has_credits"(p_practice_id uuid, p_cost integer) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."practice_has_credits"(p_practice_id uuid, p_cost integer) TO "postgres";
REVOKE ALL ON FUNCTION "public"."record_purchase_with_rebates"(p_practice_id uuid, p_credits integer, p_amount_zar numeric, p_payfast_payment_id text, p_bundle_key text, p_cost_per_credit_zar numeric, p_trainer_id uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION "public"."record_purchase_with_rebates"(p_practice_id uuid, p_credits integer, p_amount_zar numeric, p_payfast_payment_id text, p_bundle_key text, p_cost_per_credit_zar numeric, p_trainer_id uuid) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."record_purchase_with_rebates"(p_practice_id uuid, p_credits integer, p_amount_zar numeric, p_payfast_payment_id text, p_bundle_key text, p_cost_per_credit_zar numeric, p_trainer_id uuid) TO "postgres";
REVOKE ALL ON FUNCTION "public"."remove_practice_member"(p_practice_id uuid, p_trainer_id uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION "public"."remove_practice_member"(p_practice_id uuid, p_trainer_id uuid) TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."remove_practice_member"(p_practice_id uuid, p_trainer_id uuid) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."remove_practice_member"(p_practice_id uuid, p_trainer_id uuid) TO "postgres";
REVOKE ALL ON FUNCTION "public"."rename_session"(p_plan_id uuid, p_new_title text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION "public"."rename_session"(p_plan_id uuid, p_new_title text) TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."rename_session"(p_plan_id uuid, p_new_title text) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."rename_session"(p_plan_id uuid, p_new_title text) TO "postgres";
REVOKE ALL ON FUNCTION "public"."set_client_avatar"(p_client_id uuid, p_avatar_path text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION "public"."set_client_avatar"(p_client_id uuid, p_avatar_path text) TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."set_client_avatar"(p_client_id uuid, p_avatar_path text) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."set_client_avatar"(p_client_id uuid, p_avatar_path text) TO "postgres";
REVOKE ALL ON FUNCTION "public"."set_client_exercise_default"(p_client_id uuid, p_field text, p_value jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION "public"."set_client_exercise_default"(p_client_id uuid, p_field text, p_value jsonb) TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."set_client_exercise_default"(p_client_id uuid, p_field text, p_value jsonb) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."set_client_exercise_default"(p_client_id uuid, p_field text, p_value jsonb) TO "postgres";
REVOKE ALL ON FUNCTION "public"."set_client_video_consent"(p_client_id uuid, p_line_drawing boolean, p_grayscale boolean, p_original boolean, p_avatar boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION "public"."set_client_video_consent"(p_client_id uuid, p_line_drawing boolean, p_grayscale boolean, p_original boolean, p_avatar boolean) TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."set_client_video_consent"(p_client_id uuid, p_line_drawing boolean, p_grayscale boolean, p_original boolean, p_avatar boolean) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."set_client_video_consent"(p_client_id uuid, p_line_drawing boolean, p_grayscale boolean, p_original boolean, p_avatar boolean) TO "postgres";
REVOKE ALL ON FUNCTION "public"."set_client_video_consent"(p_client_id uuid, p_line_drawing boolean, p_grayscale boolean, p_original boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION "public"."set_client_video_consent"(p_client_id uuid, p_line_drawing boolean, p_grayscale boolean, p_original boolean) TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."set_client_video_consent"(p_client_id uuid, p_line_drawing boolean, p_grayscale boolean, p_original boolean) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."set_client_video_consent"(p_client_id uuid, p_line_drawing boolean, p_grayscale boolean, p_original boolean) TO "postgres";
REVOKE ALL ON FUNCTION "public"."set_practice_member_role"(p_practice_id uuid, p_trainer_id uuid, p_new_role text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION "public"."set_practice_member_role"(p_practice_id uuid, p_trainer_id uuid, p_new_role text) TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."set_practice_member_role"(p_practice_id uuid, p_trainer_id uuid, p_new_role text) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."set_practice_member_role"(p_practice_id uuid, p_trainer_id uuid, p_new_role text) TO "postgres";
REVOKE ALL ON FUNCTION "public"."sign_storage_url"(p_bucket text, p_path text, p_expires_in integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION "public"."sign_storage_url"(p_bucket text, p_path text, p_expires_in integer) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."sign_storage_url"(p_bucket text, p_path text, p_expires_in integer) TO "postgres";
REVOKE ALL ON FUNCTION "public"."unlock_plan_for_edit"(p_plan_id uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION "public"."unlock_plan_for_edit"(p_plan_id uuid) TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."unlock_plan_for_edit"(p_plan_id uuid) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."unlock_plan_for_edit"(p_plan_id uuid) TO "postgres";
REVOKE ALL ON FUNCTION "public"."upsert_client"(p_practice_id uuid, p_name text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION "public"."upsert_client"(p_practice_id uuid, p_name text) TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."upsert_client"(p_practice_id uuid, p_name text) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."upsert_client"(p_practice_id uuid, p_name text) TO "postgres";
REVOKE ALL ON FUNCTION "public"."user_is_practice_owner"(pid uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION "public"."user_is_practice_owner"(pid uuid) TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."user_is_practice_owner"(pid uuid) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."user_is_practice_owner"(pid uuid) TO "postgres";
REVOKE ALL ON FUNCTION "public"."user_practice_ids"() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION "public"."user_practice_ids"() TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."user_practice_ids"() TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."user_practice_ids"() TO "postgres";
REVOKE ALL ON FUNCTION "public"."validate_plan_treatment_consent"(p_plan_id uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION "public"."validate_plan_treatment_consent"(p_plan_id uuid) TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."validate_plan_treatment_consent"(p_plan_id uuid) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."validate_plan_treatment_consent"(p_plan_id uuid) TO "postgres";

-- ============================================================================
-- Section 12: Post-apply manual step — Vault secrets (PER ENVIRONMENT)
-- ============================================================================
-- public.sign_storage_url reads two secrets from vault.secrets:
--   - supabase_jwt_secret  : the project's JWT signing secret (Project Settings -> API)
--   - supabase_url         : e.g. 'https://<project-ref>.supabase.co'
--
-- Without these, get_plan_full and sign_practice_raw_archive_url return NULL for
-- consent-gated grayscale/original URLs (graceful fallback to line-drawing only).
--
-- After applying this baseline to an environment, run (with your env's values):
--
--   SELECT vault.create_secret('<paste JWT signing secret>',
--                              'supabase_jwt_secret');
--   SELECT vault.create_secret('https://<project-ref>.supabase.co',
--                              'supabase_url');
--
-- These are deliberately NOT embedded in this migration because they're
-- environment-specific and must not be committed to git.
-- ============================================================================

COMMIT;

-- END OF BASELINE MIGRATION