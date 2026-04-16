-- Raidme POV — Database Schema
-- Run this in the Supabase SQL Editor (Dashboard → SQL Editor → New query)

-- Plans table
create table plans (
  id uuid primary key default gen_random_uuid(),
  client_name text not null,
  title text,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

-- Exercises within a plan
create table exercises (
  id uuid primary key default gen_random_uuid(),
  plan_id uuid not null references plans(id) on delete cascade,
  position integer not null,
  media_url text,
  media_type text not null check (media_type in ('photo', 'video')),
  reps integer,
  sets integer,
  hold_seconds integer,
  notes text,
  created_at timestamptz default now()
);

-- Index for fast plan lookups
create index idx_exercises_plan_id on exercises(plan_id);
create index idx_exercises_position on exercises(plan_id, position);

-- Enable Row Level Security (required for publishable key access)
alter table plans enable row level security;
alter table exercises enable row level security;

-- POV policies: allow public read (anyone with the link can view)
-- and public insert (the app can create plans without auth)
create policy "Anyone can view plans" on plans
  for select using (true);

create policy "Anyone can create plans" on plans
  for insert with check (true);

create policy "Anyone can view exercises" on exercises
  for select using (true);

create policy "Anyone can create exercises" on exercises
  for insert with check (true);

-- Storage bucket for media files
-- NOTE: Create the bucket manually in Dashboard → Storage → New bucket:
--   Name: media
--   Public: ON (so web player can load images/videos directly)
