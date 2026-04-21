# Analytics consent — MVP design

**Status:** Designed 2026-04-21 with Carl. Scheduled as **Wave 17**. All decisions below are LOCKED unless explicitly revisited.

**Author of decisions:** Carl.
**Drafter of spec:** Claude (this session).
**Name:** "Analytics" (not "telemetry" / "adherence tracking") — this is the same product name the future paid Analytics subscription will inherit.

## Why MVP needs this

The product-shape thesis — we don't know which exercises get completed, which get skipped, which treatments clients actually pick on the web player, how long a client lingers before the first tap — without instrumenting it. Shipping without this signal is shipping blind.

Secondary: the MVP dataset is the foundation of the **paid Analytics subscription** (Y2+). If we don't start collecting from Day 1, the paid product launches with an empty data lake.

POPIA-friendly from the start: consent-driven, metadata-only, pseudonymous session IDs, retention-capped, read-locked to the practice.

## Locked decisions

| Question | Decision |
|---|---|
| Consent model | **Hybrid (C).** Practitioner can flip `clients.video_consent.analytics_allowed` off globally per client. If allowed by practitioner, the client sees a banner on first open and has the last word per-plan. |
| Practitioner default | **ON.** Needs data to shape MVP. Toggle exists at the client level for opt-out. |
| Banner cadence | **Once-and-remember** per browser. localStorage + server-side session row. Practitioner can reset the consent prompt only by creating a new client. |
| Transparency view | **YES — on plan completion.** Client reaches the end slide → clickable CTA "See what's been shared with {TrainerName}" → modal lists event counts + "Stop sharing" button. |
| Retention | **180 days raw.** Roll into daily aggregate table + drop raw. Aggregates retained indefinitely. |
| Naming | **"Analytics"** throughout. Banner copy uses "share which exercises you complete" (plain-English), tables named `plan_analytics_*`. |

## Event inventory

Twelve event kinds. All payloads are JSONB — bounded, small, schema-evolving.

### Plan-level
- `plan_opened` — `{referrer?: str}`
- `plan_completed` — `{total_elapsed_ms: int, exercises_completed: int, exercises_skipped: int}`
- `plan_closed` — `{elapsed_ms: int, slide_index_at_close: int}`

### Exercise-level
- `exercise_viewed` — `{slide_position: int}`
- `exercise_completed` — `{watched_ms: int, threshold_met: bool}` (≥80% watched OR explicit "done" tap)
- `exercise_skipped` — `{watched_ms: int}` (<20%)
- `exercise_replayed` — `{from_ms: int}`

### Engagement
- `treatment_switched` — `{from: "line"|"grayscale"|"original", to: "line"|"grayscale"|"original"}`
- `pause_tapped` — `{elapsed_ms: int}`
- `resume_tapped` — `{pause_duration_ms: int}`
- `rest_shortened` — `{scheduled_ms: int, actual_ms: int}`
- `rest_extended` — `{scheduled_ms: int, actual_ms: int}`

**Explicitly not captured:**
- No video telemetry of what the client is physically doing
- No IP, IDFA, geolocation, device fingerprints
- No identifiable info beyond the plan link the client already opened
- No keystrokes, no mouse tracking

## Data model

```sql
-- One row per plan open. Rotates per open so repeat opens are
-- correlatable within a viewing but not trivially across sessions.
CREATE TABLE public.client_sessions (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_id          UUID NOT NULL REFERENCES public.plans(id) ON DELETE CASCADE,
  opened_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  user_agent_bucket TEXT,               -- 'mobile_safari' / 'chrome_desktop' / 'firefox_mobile' — bucket, not raw UA
  consent_granted  BOOLEAN NOT NULL DEFAULT false,
  consent_decided_at TIMESTAMPTZ
);
CREATE INDEX idx_client_sessions_plan_opened ON public.client_sessions(plan_id, opened_at DESC);

-- Append-only fact table. One row per event. Small payload.
CREATE TABLE public.plan_analytics_events (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  client_session_id UUID NOT NULL REFERENCES public.client_sessions(id) ON DELETE CASCADE,
  event_kind        TEXT NOT NULL CHECK (event_kind IN (
    'plan_opened','plan_completed','plan_closed',
    'exercise_viewed','exercise_completed','exercise_skipped','exercise_replayed',
    'treatment_switched','pause_tapped','resume_tapped',
    'rest_shortened','rest_extended'
  )),
  exercise_id       UUID,              -- nullable for plan-level events
  event_data        JSONB,
  occurred_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_plan_analytics_events_session ON public.plan_analytics_events(client_session_id, occurred_at);
CREATE INDEX idx_plan_analytics_events_kind_occurred ON public.plan_analytics_events(event_kind, occurred_at DESC);

-- Daily rollup table for retention-survival data. Raw events drop
-- at 180 days; aggregates live forever.
CREATE TABLE public.plan_analytics_daily_aggregate (
  plan_id             UUID NOT NULL REFERENCES public.plans(id) ON DELETE CASCADE,
  exercise_id         UUID,
  day                 DATE NOT NULL,
  opens               INT NOT NULL DEFAULT 0,
  completions         INT NOT NULL DEFAULT 0,
  total_elapsed_ms    BIGINT NOT NULL DEFAULT 0,
  exercise_completes  INT NOT NULL DEFAULT 0,
  exercise_skips      INT NOT NULL DEFAULT 0,
  treatment_switches  INT NOT NULL DEFAULT 0,
  PRIMARY KEY (plan_id, COALESCE(exercise_id, '00000000-0000-0000-0000-000000000000'), day)
);

-- New consent key on the existing video_consent JSONB. Mirrors
-- the `grayscale`, `original`, `line_drawing` pattern.
-- Default TRUE per Carl's decision (MVP needs data; opt-out via UI).
-- No migration for existing rows — code path falls through to true
-- when key is missing.
```

### `clients.video_consent` shape, after Wave 17

```json
{
  "line_drawing": true,
  "grayscale": false,
  "original": false,
  "analytics_allowed": true
}
```

`line_drawing` stays always-true. `analytics_allowed` defaults true on new clients; existing clients fall through to true when the key is absent (for MVP, after GA we'd migrate the missing keys to false to be conservative).

## RLS + RPC surface

**Anon writes** — web player calls an RPC, not direct INSERT.

```sql
-- Starts a session, returns its id for the player to pass on every event.
-- If the practitioner has disabled analytics for this client, returns
-- NULL + the player skips the banner + no events are written.
CREATE FUNCTION public.start_analytics_session(
  p_plan_id uuid,
  p_user_agent_bucket text
) RETURNS uuid ...

-- Persists a single event. Rate-limited per session_id at ~1/sec
-- inside PL/pgSQL to kill noise.
CREATE FUNCTION public.log_analytics_event(
  p_session_id uuid,
  p_event_kind text,
  p_exercise_id uuid,
  p_event_data jsonb
) RETURNS void ...

-- Called once when the client accepts or rejects the banner.
CREATE FUNCTION public.set_analytics_consent(
  p_session_id uuid,
  p_granted boolean
) RETURNS void ...

-- Called by the "Stop sharing" button in the transparency modal.
-- Truncates consent for this session + all future sessions on this
-- plan (via a flag on client_sessions? or a per-plan opt-out row?).
CREATE FUNCTION public.revoke_analytics_consent(
  p_plan_id uuid,
  p_session_id uuid
) RETURNS void ...
```

**Authenticated reads** — practitioner scope only.

```sql
-- Per-plan rollup for the Studio stats widget.
CREATE FUNCTION public.get_plan_analytics_summary(p_plan_id uuid)
RETURNS TABLE (
  opens int, completions int, last_opened_at timestamptz,
  exercise_stats jsonb -- array of {exercise_id, viewed, completed, skipped}
) ...

-- Per-client rollup for the client detail page.
CREATE FUNCTION public.get_client_analytics_summary(p_client_id uuid) ...
```

RLS on `plan_analytics_events` / `client_sessions`: SELECT scoped by `practice_id IN (SELECT user_practice_ids())`. No INSERT/UPDATE/DELETE for `authenticated` — RPC-only writes.

### Retention cron

Supabase-scheduled function, daily at 02:00 UTC:

```sql
-- 1. Roll yesterday's events into plan_analytics_daily_aggregate.
-- 2. Delete raw events where occurred_at < now() - interval '180 days'.
-- 3. Delete client_sessions with no remaining events (cascade already
--    cleaned them).
```

## Web-player UX

### First open — consent banner

Coral banner slides in from the top on first render, once per browser per plan:

```
Help {TrainerName} help you.
We'll share which exercises you complete, and when. Nothing else.
You can stop this anytime.

                          [ No thanks ]  [ Yes, share ]
```

Tap "Yes, share" → banner dismisses, consent written, event capture starts.
Tap "No thanks" → banner dismisses, consent written as false, only `plan_opened` stored with `consent_granted=false` for telemetry on the banner itself (did people open?).

Banner remembers choice in localStorage + server. Repeat opens don't re-prompt.

### Transparency CTA on completion

After the final exercise + the `plan_completed` event fires, the end screen shows:

```
Nice work.

[ See what's been shared with {TrainerName} ]
[ Exit ]
```

Tap → modal slides up:

```
You shared this with {TrainerName}:

  • 3 plan opens
  • 12 of 12 exercises completed
  • 45 minutes total watching time
  • Last opened: 2h ago

Nothing else was collected.

[ Stop sharing ]                [ Close ]
```

"Stop sharing" → `revoke_analytics_consent(plan_id, session_id)` fires → `consent_granted` flips to false for all future sessions on this plan → modal closes with a toast "Sharing stopped. {TrainerName} won't see new data from this plan."

## Practitioner UX (MVP)

In Studio, under each plan in the plan list:

```
21 Apr 2026 16:12 · garry · 3 exercises
  Opened 3× · 12/12 completed · last 2h ago
```

That's it for MVP. No dashboard, no cohort analysis — those are paid Analytics features. Just the three numbers under the plan title in the list.

Per-exercise dot grid on the plan detail screen: each exercise gets a small bar "12/12 viewed · 11/12 completed · 1 skipped".

**No practitioner-facing consent UI in MVP** beyond the toggle on the client detail page:

```
Video consent for {ClientName}
  ☑ Line drawing (always on)
  ☐ Grayscale
  ☐ Original colour
  ☑ Allow anonymous usage analytics
```

## Timeline guess

~1 week of focused work:

- Day 1: Supabase migration + RPCs + retention cron
- Day 2: Web player event emitters + session lifecycle
- Day 3: Consent banner + transparency modal + CTA wiring
- Day 4: Flutter Studio stats widget + client consent toggle + publish-time note
- Day 5: QA + polish

Not blocking anything. Could land right after Wave 15+16 device-QA settles.

## Test plan outline (for the eventual Wave 17 test script)

- Banner appears once, not on repeat opens.
- "No thanks" → events not written.
- Transparency modal counts match server events.
- Stop sharing → `consent_granted=false` → next event ignored (consent-check RPC-side).
- Practitioner toggle off → banner never shows + client sessions record consent_granted=false automatically.
- 180-day retention cron: seed fake data past 180d, run cron, confirm raw gone, aggregate retained.

## Open for later (not MVP)

- Per-exercise pain scale (ask client to rate each exercise 1-5). Out of MVP scope; future Analytics feature.
- Weekly adherence summary email to the client. Same.
- Cross-client cohort dashboards. Same.
- Export CSV of events. Same.
