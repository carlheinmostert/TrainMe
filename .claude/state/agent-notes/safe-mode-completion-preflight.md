# Safe Mode completion — pre-flight notes

Captured 2026-05-21 against staging Supabase `vadjvkmldtoeyspyoqbx`.

## SQLite version

V2 already bumped `_dbVersion` to 43. This wave moves to **v44**.

- v42: `sessions.practice_id` (Public Profile pre-wave migration renumber).
- v43: `cached_practices.brand_color` + `cached_practices.public_logo_url` (V2 Public Profile branding mirror).
- v44 (this wave): `exercises.safe_mode_active`, `exercises.captured_in_premises_id`, `exercises.safe_raw_file_path` (all local — first two mirror cloud schema added in PR #389, third is local-only crash-recovery hint).

## ExerciseCapture model

Neither `safeModeActive`, `capturedInPremisesId`, nor `safeRawFilePath` currently exist in
`app/lib/models/exercise_capture.dart`. All three are added in Task 1.

## Cloud exercises table

`safe_mode_active boolean NOT NULL DEFAULT false` and
`captured_in_premises_id uuid NULL` already exist on `public.exercises` (PR #389).
This wave just plumbs writes through `replace_plan_exercises`.

## `replace_plan_exercises` actual signature

The RPC takes `(p_plan_id uuid, p_rows jsonb)` — jsonb rows array, NOT parallel
typed-array parameters as the plan's Task 5 text suggested. Each row already
carries its per-exercise jsonb keys. The cleanest preservation-compatible
migration adds two new keys to the per-row INSERT body:

```
COALESCE((r->>'safe_mode_active')::boolean, false),
NULLIF(r->>'captured_in_premises_id', '')::uuid
```

…and the Dart binding in `ApiClient.replacePlanExercises` doesn't need a
signature change — the caller composes rows in `UploadService` and includes
the two new keys per row.

Existing column list captured for column-preservation:
- id, plan_id, position, name, media_url, thumbnail_url, media_type, notes,
  circuit_id, include_audio, preferred_treatment, prep_seconds,
  video_reps_per_loop, start_offset_ms, end_offset_ms, aspect_ratio,
  rotation_quarters, body_focus, rest_seconds, focus_frame_offset_ms,
  hero_crop_offset

Existing child set INSERT preserved verbatim (no changes there).

This deviates from the plan's literal `boolean[] / uuid[]` parameter wording
in favour of matching the actual jsonb-rows API. Same audit outcome on
publish — `safe_mode_active` and `captured_in_premises_id` end up persisted
on `exercises` rows.
