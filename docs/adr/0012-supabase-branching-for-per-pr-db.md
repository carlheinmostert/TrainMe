# Supabase Branching for per-PR DB previews

Every PR gets an isolated Supabase database clone; migrations apply automatically on PR open. Staging has its own persistent branch (project ref `vadjvkmldtoeyspyoqbx`). Schema changes ship as timestamp-named files under `supabase/migrations/`. `supabase/archive/` is the historical paper trail of ad-hoc patch files that predate the 2026-05-11 cutover — don't apply them.
