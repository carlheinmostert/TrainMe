# `supabase/migrations/` — sequential schema-change chain

From the `20260511065443_baseline.sql` baseline onward, **every** schema change to
the homefit.studio Supabase database lives as a new timestamped file in this
folder. This is the chain Supabase Branching reads to provision per-PR preview
databases and the persistent staging branch.

## Creating a new migration

```bash
supabase migration new <short_name>          # creates supabase/migrations/<TS>_<short_name>.sql
```

Edit the new file. Put the whole change inside a single `BEGIN; ... COMMIT;`
block so a partial apply rolls back atomically.

## Applying migrations

**Per environment (staging, prod, branch DBs):**

```bash
supabase db push                              # applies any unapplied migrations to the linked DB
```

`db push` reads `supabase_migrations.schema_migrations` and only runs files that
haven't been applied. Adding a row to that table marks a file as applied without
re-running it (useful when retro-fitting the baseline — see "Adopting the
baseline on prod" below).

## Hard rules

1. **Never bypass the migration chain.** Do not run `supabase db query --linked
   --file <one-off>.sql` for schema changes. That writes to the live DB without
   updating the migration tracking, which breaks Branching forever.
2. **Never edit a committed migration.** If a migration is wrong, write a new
   migration that fixes the previous one. Branch DBs replay from scratch — any
   edit to a historical file diverges them silently.
3. **Always pre-flight RPC edits against the live DB.** Pull the current
   definition with `pg_get_functiondef`, *not* from `supabase/schema_*.sql`
   (those files are legacy and lag the live DB). See the
   schema-migration-column-preservation memory for three real incidents.
4. **Wrap multi-statement migrations in a transaction.** `BEGIN; ... COMMIT;` —
   half-applied schema state is unrecoverable on a branch DB.

## What's in this folder vs the legacy `supabase/schema_*.sql` files

The 70-odd `supabase/schema_*.sql` files in the parent directory are the
historical record of how prod evolved between 2026-04-15 and 2026-05-11. They
are kept as a safety net while Supabase Branching is wired up. Do **not** apply
them — the baseline reproduces their cumulative effect exactly. Once Branching
is validated end-to-end on staging, those files will be moved to
`supabase/archive/`.

The Supabase Edge Functions sit in `supabase/functions/` and are deployed
independently via `supabase functions deploy <name>` — they're outside this
migration chain.

## Adopting the baseline on prod (one-time)

The baseline reflects what's already in prod. We **do not** want to re-run it
against prod — that would attempt to create tables that already exist. Instead,
mark the baseline as already-applied:

```sql
INSERT INTO supabase_migrations.schema_migrations (version, name, statements)
VALUES ('20260511065443', 'baseline', ARRAY[]::text[]);
```

(Run this once against prod via the dashboard SQL editor or `supabase db query
--linked` — it's the one acceptable use of direct query for migration
bookkeeping.)

Staging branch DBs and per-PR branch DBs are provisioned fresh from the
migration chain, so they DO run the baseline.

## Vault secrets are per-environment

The baseline's Section 12 lists two vault secrets (`supabase_jwt_secret`,
`supabase_url`) that `sign_storage_url` reads. These are environment-specific
and NOT in any migration file — populate them manually after the baseline runs
against a new branch DB. Without them, `get_plan_full` gracefully falls back to
line-drawing-only (consent-gated grayscale/original URLs return NULL).
