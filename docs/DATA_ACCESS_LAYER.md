# Data Access Layer

**Status:** adopted 2026-04-18. Binding on all three surfaces.
**Supersedes:** no prior document — this formalises ad-hoc conventions.

## Why this exists

On 2026-04-18 we shipped two related bugs inside a single day:

1. The web player was reading `plans` + `exercises` directly via
   PostgREST. Milestone C's RLS lockdown had turned those into silent
   empty results weeks earlier; the bug surfaced as "plan not found" on
   every published link. The fix was always "use the `get_plan_full`
   RPC", but nothing enforced it.
2. The same fix required renaming the RPC parameter `plan_id` →
   `p_plan_id` to resolve an ambiguous-column error. Because every
   surface wrote the RPC name and param shape inline, the rename was a
   shotgun edit across the codebase. Miss a site and it silently 500s.

Both of these are the same class of bug: the network contract between
the surfaces and Supabase was scattered across dozens of files. Fixing
it once, in one place, is the MVP-appropriate discipline.

No new deployment tier. No Node BFF. No Edge Function migration. Just
one file per surface that enumerates its allowed operations.

## The rule

| Actor                         | Supabase primitive           | Why                                                                                |
|-------------------------------|------------------------------|------------------------------------------------------------------------------------|
| Anon web player               | `get_plan_full` RPC only     | Milestone C denies anon SELECT on `plans` / `exercises`; the RPC is the only door. |
| Authenticated practitioner CRUD| Tables via RLS-scoped writes | RLS keyed on `practice_members.trainer_id = auth.uid()`.                           |
| Authenticated business ops    | SECURITY DEFINER RPCs        | Atomic credit burn + refund + bootstrap are in-DB to avoid race conditions.        |
| External webhook              | Edge Function + service role | PayFast ITN bypasses RLS; lives in `supabase/functions/payfast-webhook`.           |

Every surface gets exactly ONE file that wraps these primitives. No
other file in that surface is permitted to call `supabase.from(...)`,
`.rpc(...)`, `.storage.*`, or `fetch(...supabase.../rest/v1/...)`
directly. Enforcement is convention + code review for MVP; an ESLint /
`custom_lint` rule is a post-MVP sharpening.

## RPC inventory

All RPCs live in the `public` schema.

| Name                             | Params                                       | Returns          | Auth          | Consumed by       | Defined in                                      |
|----------------------------------|----------------------------------------------|------------------|---------------|-------------------|-------------------------------------------------|
| `get_plan_full`                  | `p_plan_id uuid`                             | `jsonb` / null   | anon + authed | web player        | `schema_milestone_a.sql` (+ rename fix)         |
| `practice_credit_balance`        | `p_practice_id uuid`                         | `integer`        | anon + authed | app, web portal   | `schema_milestone_a.sql`                        |
| `practice_has_credits`           | `p_practice_id uuid`, `p_cost integer`       | `boolean`        | authed only   | (unused — parked) | `schema_milestone_c.sql`                        |
| `consume_credit`                 | `p_practice_id`, `p_plan_id`, `p_credits`    | `jsonb`          | authed only   | app               | `schema_milestone_c.sql`                        |
| `refund_credit`                  | `p_plan_id uuid`                             | `boolean`        | authed only   | app               | `schema_milestone_e_safe_rpcs.sql`              |
| `bootstrap_practice_for_user`    | —                                            | `uuid`           | authed only   | app               | `schema_milestone_e_safe_rpcs.sql`              |
| `user_practice_ids`              | —                                            | `uuid[]`         | authed only   | RLS helpers       | `schema_milestone_c_recursion_fix.sql`          |
| `user_is_practice_owner`         | `pid uuid`                                   | `boolean`        | authed only   | RLS helpers       | `schema_milestone_c_recursion_fix.sql`          |

`user_practice_ids` / `user_is_practice_owner` are RLS internals — they
exist to break the policy-recursion trap. Client code never calls them
directly and no api.\* file exposes them.

Tables the surfaces actually touch:

| Table              | Shape of access                          | Notes                                                              |
|--------------------|------------------------------------------|--------------------------------------------------------------------|
| `plans`            | upsert (app), read via RPC (web player) | Anon cannot SELECT. Authed writes scoped by `practice_id` via RLS. |
| `exercises`        | upsert / delete (app), read via RPC     | Scoped through `plans.practice_id`.                                |
| `plan_issuances`   | insert (app), select (web portal)        | Append-only: no UPDATE/DELETE policies.                            |
| `practice_members` | select (app, web portal)                 | RLS returns only rows the caller belongs to.                       |
| `pending_payments` | insert/update/select (web portal admin)  | Service-role only writes; authed SELECT scoped by practice.        |
| `credit_ledger`    | insert purchase (service role)           | App goes through `consume_credit` / `refund_credit` RPCs.          |

Storage:

| Bucket  | Operations                         | Who         | Notes                                         |
|---------|------------------------------------|-------------|-----------------------------------------------|
| `media` | upload, remove, getPublicUrl       | app only    | Public SELECT (share links); INSERT/UPDATE/DELETE scoped by `plan_id` → `practice_id`. |

## Surface endpoints

### Flutter trainer app — `app/lib/services/api_client.dart`

`ApiClient.instance` (singleton). Exports:

- **Auth passthroughs:** `currentUserId`, `currentUserEmail`,
  `currentSession`, `authStateChanges`, `raw` (carve-out for OAuth
  id_token flows and the AuthGate stream subscription).
- **Auth methods:** `sendMagicLink`, `signInWithIdToken`, `signOut`.
- **RPCs:** `bootstrapPracticeForUser`, `practiceCreditBalance`,
  `consumeCredit`, `refundCredit`.
- **Table CRUD:** `upsertPlan`, `upsertExercises`,
  `deleteStaleExercises`, `insertPlanIssuance`.
- **Storage:** `uploadMedia`, `removeMedia`, `publicMediaUrl`
  (all hit the `media` bucket, which is exposed as a constant:
  `ApiClient.mediaBucket`).

Routed consumers: `auth_service.dart`, `upload_service.dart`. No other
file in `app/lib/` is permitted to import `Supabase.instance.client`
directly. The local SQLite layer
(`local_storage_service.dart`) is orthogonal and stays outside this
discipline.

### Web player — `web-player/api.js`

A plain-script IIFE that attaches `window.HomefitApi` with:

- `getPlanFull(planId)` — wraps the `get_plan_full` RPC with the
  `p_plan_id` parameter name. Throws `'Plan not found'` on any non-ok
  response or empty payload.
- `SUPABASE_URL`, `SUPABASE_ANON_KEY` — re-exported constants for any
  downstream consumer that needs the base URL for a future call that
  gets added to this file.

Loaded via `<script src="/api.js">` before `<script src="/app.js">`
in `index.html`. `app.js` is forbidden from calling `fetch(...)`
against the Supabase REST surface directly.

### Web portal — `web-portal/src/lib/supabase/api.ts`

Two classes, parameterised over a shared `CompatSupabase` type (handles
the generic-arity mismatch between `@supabase/ssr` 0.5.x and
`@supabase/supabase-js` 2.103.x):

**`PortalApi`** — constructed via `createPortalApi(supabase)`:
- `listMyPractices()` — returns `PracticeWithRole[]`.
- `listPracticeMembers(practiceId)` — returns `MemberRow[]`.
- `getCurrentUserRole(practiceId, userId)` — returns `'owner' | 'practitioner' | null`.
- `isUserInPractice(practiceId, userId)` — boolean membership guard.
- `getPracticeBalance(practiceId)` — wraps `practice_credit_balance` RPC.
- `listRecentIssuances(practiceId, limit = 50)` — audit page feed.

**`AdminApi`** — constructed via `await createAdminApi()`:
- `insertPendingPayment(row)` — PayFast intent record.
- `findPendingPayment(pid)` — lookup by `m_payment_id`.
- `applyPendingPayment(pid, ledgerRow)` — sandbox-optimistic credit
  apply (insert ledger row + flip intent to `complete`).

`createAdminApi` pulls the service-role key from env and throws if
it's missing — never silently falls back to anon. The callsites that
need admin power live in `src/app/credits/purchase/route.ts` and
`src/app/credits/return/page.tsx`.

Typed rows + RPC params flow from
`src/lib/supabase/database.types.ts`, which is generated from the live
schema.

## Typed contract generation

- **TypeScript (web-portal):** `supabase gen types typescript --linked
  --schema public > web-portal/src/lib/supabase/database.types.ts`.
  Regenerate after every migration that changes schema or RPC
  signatures. Both `getServerClient()` and `getBrowserClient()` are
  typed with `<Database>` so `supabase.from(...)` rows and
  `supabase.rpc(...)` params are compile-time checked.
- **Web player (`api.js`):** no bundler, so no TS. The module is thin
  enough (one function today) that hand-maintained is fine. If it grows
  past ~5 methods, migrate to a bundled ESM module and share the types
  file with the web portal.
- **Dart (Flutter app):** Supabase ships no first-party Dart type
  generator. We evaluated `supabase_codegen` (third-party,
  experimental) and chose to **hand-maintain** the `ApiClient` Dart
  API for MVP — the RPC surface is five methods and the parameter
  shapes are small. Revisit post-MVP if the surface doubles.

The 2026-04-18 `plan_id` → `p_plan_id` rename would have failed at
typecheck on the web-portal; on Flutter and web-player it would still
have required a manual sweep (and this document is the audit trail for
that sweep).

## How to add a new RPC

1. Write the SQL in a new file under `supabase/` — name it
   `schema_<milestone_or_feature>.sql`. Make it idempotent (every
   statement re-runnable). Include `REVOKE ALL` + explicit
   `GRANT EXECUTE` for the minimum role that needs it (anon vs.
   authenticated).
2. Apply via the linked CLI: `supabase db query --linked --file
   supabase/<file>.sql`.
3. Regenerate the TypeScript types:
   ```
   supabase gen types typescript --linked --schema public \
     > web-portal/src/lib/supabase/database.types.ts
   ```
4. Add a typed method to each surface that needs it:
   - `app/lib/services/api_client.dart` — mirror the SQL param names
     (`p_*`), return a domain-appropriate Dart type, document failure
     modes.
   - `web-portal/src/lib/supabase/api.ts` — add to `PortalApi` or
     `AdminApi` depending on whose client invokes it.
   - `web-player/api.js` — only if the anon player needs it (rare;
     most new RPCs are authed-only).
5. Call sites use the new method via
   `ApiClient.instance.foo()` / `api.foo()` /
   `window.HomefitApi.foo()`. They MUST NOT reach through to the raw
   Supabase client or `fetch(...)`.
6. Add a row to the RPC inventory above and cross-link the defining
   SQL file.

## Migration path if this outgrows the pattern

The `PortalApi` / `AdminApi` split is already the shape that a Supabase
Edge Function would take if/when business logic grows past what SQL
functions can comfortably express. The precedent exists in
`supabase/functions/payfast-webhook` (a 4-gate PayFast ITN validator
with external signature verification). When a new operation starts
needing external HTTP, multi-step orchestration, or cryptographic
verification, it moves to a new Edge Function and the surface file
gains a `callEdgeFunction('foo', payload)` wrapper — not a new
direct-Supabase callsite.

Until then, adding to these files is cheaper than adding a new tier.

## What this does NOT do

- **No caching layer.** PostgREST + Supabase CDN remain the only
  caches. React Query / SWR / Dart `FutureProvider` stay out of this
  file. A surface that needs caching adds it around the `api.*` call
  site, not inside the client.
- **No rate limiting.** Deferred to Supabase / Vercel edge.
- **No structured observability.** Errors flow up; surfaces log them.
  A post-MVP pass can wrap every method in a shared instrument.
- **No offline sync.** Flutter's SQLite layer
  (`local_storage_service.dart`) is the offline store and stays
  distinct. `ApiClient` is the network path only; a future publish-
  queue that batches uploads offline lives *above* `ApiClient`, not
  inside it.
- **No auth.users join.** The audit page still renders trainer UUIDs.
  A future `public.trainers` view would expose emails behind RLS and
  be added as `api.listTrainers()`.

## Verification checklist

When you add or change an `api.*` method:

- [ ] TS: `cd web-portal && npm run typecheck && npm run build`.
- [ ] Dart: `cd app && flutter analyze && flutter build ios --debug
  --simulator --dart-define=GIT_SHA=test`.
- [ ] Web player: `node --check web-player/api.js && node --check
  web-player/app.js`.
- [ ] Every consumer grep returns zero matches for direct Supabase
  calls outside the api file:
  - `grep -r "supabase\.from\|supabase\.rpc\|supabase\.storage"
    web-portal/src/app web-portal/src/components`
  - `grep -r "Supabase\.instance\.client\|_supabase\." app/lib` (should
    only match `api_client.dart`)
  - `grep -r "rest/v1/rpc" web-player/*.js` (should only match
    `api.js`)
