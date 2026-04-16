-- TrainMe / HomeFit — Supabase Schema
-- Run in Supabase SQL Editor to set up the database.
-- WARNING: This drops existing tables. Only run on fresh/POV databases.

DROP TABLE IF EXISTS exercises CASCADE;
DROP TABLE IF EXISTS plans CASCADE;

-- Plans table — one record per sent exercise plan
CREATE TABLE plans (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_name text NOT NULL,
  title text,
  circuit_cycles jsonb DEFAULT '{}',
  preferred_rest_interval_seconds integer,
  exercise_count integer,
  version integer NOT NULL DEFAULT 1,
  created_at timestamptz DEFAULT now(),
  sent_at timestamptz DEFAULT now()
);

-- To add the version column to an existing database, run:
-- ALTER TABLE plans ADD COLUMN IF NOT EXISTS version integer NOT NULL DEFAULT 1;

-- Exercises table — ordered exercises within a plan
CREATE TABLE exercises (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_id uuid NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
  position integer NOT NULL,
  name text,
  media_url text,
  thumbnail_url text,
  media_type text NOT NULL CHECK (media_type IN ('photo', 'video', 'rest')),
  reps integer,
  sets integer,
  hold_seconds integer,
  notes text,
  circuit_id text,
  include_audio boolean DEFAULT false,
  custom_duration_seconds integer,
  created_at timestamptz DEFAULT now()
);

-- Indexes
CREATE INDEX idx_exercises_plan ON exercises(plan_id, position);

-- Row Level Security — public read + insert (POV: security by unguessable UUID)
ALTER TABLE plans ENABLE ROW LEVEL SECURITY;
ALTER TABLE exercises ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Public read plans" ON plans FOR SELECT USING (true);
CREATE POLICY "Public insert plans" ON plans FOR INSERT WITH CHECK (true);
CREATE POLICY "Public update plans" ON plans FOR UPDATE USING (true);
CREATE POLICY "Public read exercises" ON exercises FOR SELECT USING (true);
CREATE POLICY "Public insert exercises" ON exercises FOR INSERT WITH CHECK (true);
CREATE POLICY "Public delete exercises" ON exercises FOR DELETE USING (true);

-- Storage bucket (run separately in Supabase dashboard or via SQL)
-- INSERT INTO storage.buckets (id, name, public) VALUES ('media', 'media', true)
-- ON CONFLICT (id) DO NOTHING;
--
-- Storage RLS policies:
-- CREATE POLICY "Public read media" ON storage.objects FOR SELECT USING (bucket_id = 'media');
-- CREATE POLICY "Public upload media" ON storage.objects FOR INSERT WITH CHECK (bucket_id = 'media');
