# Design Review — Ending Silent Failures in homefit.studio

**Date:** 2026-04-20  
**Trigger:** Multi-hour raw-archive debug session traced to four stacked silent-failure patterns (release-stripped `debugPrint`, `catch(e) { debugPrint(e) }` swallow, placeholder vault secret, missing `plans.client_id` link).

**Context prompting this review (Carl, verbatim):**
> "Every time there's a major problem, it comes down to code silently failing, especially critical pieces of code. So I don't want you to necessarily just go and handle the errors at all the different places. I would like a design review of how we deal with this, and then we can agree on that, and then go forth."

---

## Executive summary

- **The root cause is uniform treatment of non-uniform failure classes.** We apply one pattern (`try { ... } catch (e) { debugPrint(e); }`) to config drift, critical-path writes, best-effort cleanup, and network calls alike. The fix is to sort failures into tiers and route each tier to a different surface.
- **`debugPrint` is not observability.** Release builds strip it, debug logs don't persist, and nothing is aggregated. Until every swallowed exception lands in a durable log, we are flying blind.
- **The publish path is the most expensive silent-failure surface.** It's a distributed transaction across SQLite, Storage, Postgres, and an RPC, with five "best-effort" sub-steps. It needs a structured outcome record per publish, not scattered catch blocks.
- **Config drift beats runtime errors.** The vault-placeholder and missing-`client_id` bugs weren't exceptions — they were wrong-but-valid data. Those require **invariant checks**, not error handling.
- **Start with 3 load-bearing pieces**: (1) a `_loudSwallow` helper + `error_logs` table, (2) a boot-time self-check that fails loudly on misconfiguration, (3) a `publish_health` SQL view with a daily drift alert. Everything else compounds from there.

---

## Categorised inventory of silent-failure classes

| # | Class | Failure mode | Examples | Blast radius |
|---|---|---|---|---|
| **1** | **Swallowed exception on critical write** | `try/catch` + `debugPrint` on a path that must succeed | raw-archive upload, refund ledger row, plan_issuances audit | Weeks of data loss across all tenants |
| **2** | **Config drift / invariant violation** | Code runs fine; data is wrong-but-valid | Vault placeholder, missing `plans.client_id`, wrong CNAME | Whole feature dark; nothing throws |
| **3** | **Async UI wait on a dead resource** | Outer promise never resolves; user stares at spinner | AVPlayer 30s hang on 404, offline publish without timeout | One session, but catastrophic trust damage |
| **4** | **Compile/build stripping of diagnostics** | Observability disappears in the shipped artefact | `debugPrint` in release, `assert` stripped, `kDebugMode` branches | 100% of device QA sessions |
| **5** | **Fire-and-forget async** | Missing `await`, `.then()` without `.catchError`, orphaned futures | Common across upload_service; any `unawaited(...)` without backstop | Localised but invisible |
| **6** | **Schema / RPC contract drift** | Client writes field A; server reads field B; both paths succeed individually | `plans.client_id`; future risk as RPCs evolve | Silent data corruption |
| **7** | **Infra-side silent 400/403** | Server returns error body the client doesn't inspect | Supabase storage 400 on bad upsert; RLS denies → empty result set | Feature dark with zero signal |
| **8** | **Race / ordering bugs dressed as success** | Work completes out of order; state looks valid | AVAssetWriter serial drain (pre-PR #41); pending_ops flush races | Intermittent, hard to reproduce |

Classes 1, 2, 4, 7 are today's bleeders. 3 is the UX killer. 5, 6, 8 are latent.

---

## Proposed policy — three tiers

Every failure falls into exactly one tier. The tier dictates where it surfaces.

### Tier A — "Must fail loudly at boot / before use"

Config, secrets, schema contracts, feature prerequisites. Wrong-but-valid state.

- **Policy:** Self-check at app launch and at the start of each sensitive operation. On failure: block the action, show a practitioner-readable banner, write a structured `error_logs` row.
- **Never** silently degrade. Better to refuse to publish than to publish a dark plan.
- **Examples covered:** vault placeholder, missing `client_id`, missing RLS policy, missing SQLite column.

### Tier B — "Must surface to UI within N seconds"

Critical-path writes and user-initiated actions.

- **Policy:** `Result<T, E>`-style outcome at the boundary. Failure renders a toast/banner with an actionable message and a "send diagnostics" affordance. Never `catch { debugPrint }` on these.
- **Examples covered:** publish credit consumption, plan upsert, exercise upsert, auth, RPC calls that gate a user action.

### Tier C — "Swallow allowed, but log loudly"

True best-effort work. Orphan cleanup, raw-archive upload, analytics, cache warms.

- **Policy:** Must route through `_loudSwallow(context, error, stack, severity)`. Writes to local `Documents/diagnostics.log` AND, when online, POSTs to a Supabase `error_logs` table. **No bare catch blocks are permitted anywhere in the codebase**; lint/grep rule enforces this.
- A swallowed error at Tier C must also increment a feature-scoped counter so a cron can alert when "raw-archive upload failure rate > 20% over 1h".
- **Examples covered:** raw-archive upload, thumbnail generation, pending_ops flush retries.

**Rule of thumb:** if a product feature depends on the write succeeding for even one user, it's not Tier C.

---

## Startup / periodic validation — what would have caught today's bleeders

**Boot-time self-check (mobile + edge function):**

1. Mint a signed URL against a known-good seed object, `HEAD` it, assert 200. Catches vault placeholder, JWT secret rotation, bucket policy regression.
2. Call a `schema_contract()` RPC that returns a hash of expected columns + RPC signatures the client depends on; client verifies. Catches contract drift.
3. Verify `SUPABASE_URL`, anon key, and the currently-selected practice exist and are consistent. Elevate existing checks to hard-fail.

**Per-publish pre-flight (mobile):**

1. Every exercise has a converted file AND an archive file on disk (extend existing check).
2. Selected practice has a `client_id` for the session's client; if not, call `upsert_client` before `upsertPlan`.
3. Credit balance > required; if tied, refuse rather than optimistically consume.

**Daily cron (edge function or pg_cron):**

1. `publish_health` view — plans published in last 24h vs distinct `(plan_id, exercise_id)` rows in `raw-archive` storage. Non-zero delta = alert.
2. `signed_url_health` — sample 1% of recent signed URLs, HEAD them, log success rate.
3. `error_logs` rollup — any severity=`error` in last 1h POSTs to Carl's WhatsApp via the existing skill.

---

## Observability — 3-item MVP

1. **`error_logs` table + `_loudSwallow` helper.** Dart helper that every swallow must route through. Writes local first, POSTs when online. Severity enum (`info`/`warn`/`error`/`fatal`). Include `practice_id`, `plan_id`, `feature`, `context_json`. Fixes class 1+5+7 at the policy level. **This is the load-bearing one.**
2. **Boot self-check + "Diagnostics" screen.** Ships a green/red matrix of tier-A invariants. Practitioner can see and tap "send to support" which attaches the local log. Fixes class 2+4.
3. **`publish_health` SQL view + daily WhatsApp ping.** Cheapest possible monitoring; no new SaaS. Fixes the "how would we have known?" question for the class of bugs that already cost us weeks.

**Explicitly not now:** Sentry/Datadog, OpenTelemetry, custom dashboards, full distributed tracing. Revisit at 100+ practices.

---

## Specific mechanism proposals

### `_loudSwallow` helper (Dart, signature + behavior)

Signature:
```
Future<void> _loudSwallow({
  required String feature,
  required Object error,
  StackTrace? stack,
  Severity severity = Severity.error,
  Map<String, dynamic>? context,
})
```

Behavior:

- Append a JSON line to `{Documents}/diagnostics.log` (rotate at 5 MB).
- If online and `severity >= warn`, fire-and-forget `supabase.from('error_logs').insert(...)`. Never awaits the caller.
- In debug mode, also `debugPrint` and rethrow if `severity == fatal`.

Lint rule: ban bare `catch (e) {}`, require either `_loudSwallow` or a typed re-throw. Enforced by pre-commit grep:
```
catch\s*\([^)]*\)\s*\{(?!\s*(await\s+_loudSwallow|rethrow|throw))
```

### `Result<T, E>` at the boundary

Adopt `Result<Ok, Fail>` (sealed class) **only at three crossings**:

1. `ApiClient` — every public method returns `Future<Result<T, ApiError>>`.
2. `UploadService.publish` — returns `Result<PublishOk, PublishFail>` with a failure enum that the UI switches on.
3. Video pipeline platform channel — returns `Result<ConversionOk, ConversionFail>`.

Everywhere else, idiomatic throws are fine. Don't viralise Result into every function.

### Boot-time vault check (SQL + Dart)

Add `public.signed_url_self_check()` RPC (SECURITY DEFINER, callable by authenticated) that signs a URL against a seed object, fetches it server-side via `pg_net.http_get`, and returns `{ok: bool, reason: text}`. Client calls this once per cold launch; red banner on failure. Zero placeholders survive more than one launch.

### `publish_health` view (SQL sketch)

```sql
create view publish_health as
select
  date_trunc('day', issued_at) as day,
  count(*) filter (where kind = 'publish') as plans_published,
  count(*) filter (where archive_uploaded = true) as archives_present,
  count(*) filter (where kind = 'publish' and archive_uploaded = false) as archive_gap
from plan_issuances pi
left join lateral (...raw-archive existence check...) on true
group by 1;
```

Daily `pg_cron` job selects rows where `archive_gap > 0` and invokes the WhatsApp edge function.

### `publish_outcome` structured record

Replace the five scattered try/catches in `upload_service.dart` with a single `PublishOutcome` builder that accumulates `step_name → status` entries and gets persisted to `plan_issuances` (or a sibling table) as JSONB. Makes the entire publish observable in one row; no grep-the-logs archaeology.

---

## What NOT to do

- **Don't wrap every function in Result.** The boundary is the point — internal code stays idiomatic. Viral Result makes us less safe, not more.
- **Don't add modal error dialogs.** Violates R-01. Toasts + banners + an inline "diagnostics" affordance is the pattern.
- **Don't adopt Sentry yet.** It solves a problem we don't have at 5 practices. Our leaks are config drift and swallowed writes — neither is a runtime exception Sentry would catch.
- **Don't re-introduce debug-only logs as the primary signal.** Everything that matters must persist to the local log file at minimum, which works in release.
- **Don't retry silently.** A retry that eventually succeeds after 4 failures looks the same as "worked first time" in the logs. All retries must log the failed attempts at `warn`.
- **Don't block publish on tier-C work.** Raw-archive upload moves to a background queue with its own health metric, not an awaited step.

---

## Recommended sequencing (when implementation starts)

1. Land `error_logs` table + `_loudSwallow` + the lint rule in one PR. Migrate the 10 most critical swallow sites.
2. Land `publish_health` view + daily WhatsApp cron.
3. Land boot-time self-check + Diagnostics screen. Ship the vault-signed-URL probe inside it.
4. Refactor `upload_service.publish` to return `Result<PublishOk, PublishFail>` with a `PublishOutcome` record written to Postgres.
5. Sweep remaining swallow sites; set a CI rule that new `catch` blocks require a `_loudSwallow` call.

Items 1–3 are the MVP. Items 4–5 are the follow-up sweep once the observability floor exists.

---

## Relevant files for the eventual implementation

- `app/lib/services/upload_service.dart` — publish flow, five tier-C swallow sites today
- `app/lib/services/api_client.dart` — natural home for `Result<T, E>` boundary
- `app/lib/screens/plan_preview_screen.dart` — AVPlayer hang case; needs timeout + fail-fast
- `supabase/schema.sql` — add `error_logs` + `publish_health` view
- `app/lib/services/sync_service.dart` — pending_ops queue; good pattern to extend for tier-C background work
