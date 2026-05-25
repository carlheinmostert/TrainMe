# Self-trainer wave — design doc

**Status:** living design doc · authored 2026-05-25 from the grilling session resolving 14 decision blocks · supersedes earlier "My Workouts as consumer mode" framing in [`CLIENT_WORKOUTS_AND_CLASSES.md`](./CLIENT_WORKOUTS_AND_CLASSES.md).

**Owners:** Carl + Claude

**Related artifacts:**
- ADRs: [0020](./adr/0020-self-trainer-as-practitioner-with-self-as-client.md), [0021](./adr/0021-safe-mode-subscription-credit-denominated.md), [0022](./adr/0022-plan-artifacts-abstraction-before-reel.md)
- Glossary updates: [`CONTEXT.md`](../CONTEXT.md) — `Self-trainer`, `Self-client`, `Self-verification`, `Self-reference selfie`, `My Workouts`, `Publish`, `Plan artifact`, `Safe Mode subscription`
- Predecessor doc: [`CLIENT_WORKOUTS_AND_CLASSES.md`](./CLIENT_WORKOUTS_AND_CLASSES.md) — keeps the IA shell decisions (two-capsule scope row, `HomeScope.workouts` enum, locked-teaser pattern); the consumer-only framing of its My Workouts section is superseded by this doc.

## Table of Contents

- [North star](#north-star)
- [Glossary deltas](#glossary-deltas)
- [The three locked architectural decisions](#the-three-locked-architectural-decisions)
- [Schema deltas](#schema-deltas)
- [IA changes](#ia-changes)
- [Capture-entry path from My Workouts](#capture-entry-path-from-my-workouts)
- [Publish flow changes](#publish-flow-changes)
- [Safe Mode subscription model](#safe-mode-subscription-model)
- [Persona onboarding](#persona-onboarding)
- [Self-capture card design](#self-capture-card-design)
- [Migration plan](#migration-plan)
- [POPIA compliance](#popia-compliance)
- [Doc drift to sweep](#doc-drift-to-sweep)
- [PR sequence](#pr-sequence)
- [Held briefs](#held-briefs)
- [Open questions](#open-questions)
- [Non-goals](#non-goals)
- [Decision log](#decision-log)

---

## North star

homefit.studio acquires a third persona: **the Self-trainer**, a User who films themselves (vanity, form study, social posting). Safe Mode is what makes gym capture viable; the self-trainer wave is what makes the product *theirs*. They live in a single-tenant slice of the existing multi-tenant world — same `auth.users`, same `practice_members`, same `clients` / `plans` / `exercises` — and the wave's job is to make that work without bolting on a parallel data model.

The Self-trainer is **not a separate identity** from the Practitioner. They are a Practitioner whose only Client is themselves, registered via the existing Public profile selfie + a new MobileFaceNet embedding column. A Self-trainer who later adds a real Client becomes a working Practitioner without any identity migration.

Two orthogonal monetization axes are introduced — both denominated in credits, both gated by the existing `credit_ledger`:

- **Audience** — Publish costs 0 credits when subject is verified-self, 1-2 credits otherwise. Aggregated at session level.
- **Environment** — Capture inside a Safe Mode enforcing geofence requires an active subscription. 4 credits / month (R100 at R25/credit), 3-day free trial on first sub, manual renewal.

The "free hook" for new users is: capture yourself anywhere outside a protected gym, publish freely, share to whoever, no payment ever. The paywall arrives only when they cross into a gym (subscription) or start filming other people (credits).

---

## Glossary deltas

Eight new or amended glossary entries land in [`CONTEXT.md`](../CONTEXT.md) with this wave. Summarised here; canonical text in the glossary.

| Term | Status | One-line |
|---|---|---|
| **Self-trainer** | new (provisional term) | User whose practice contains only themselves; free outside premises, subscription required inside. |
| **Self-client** | new | A `clients` row with `user_id = auth.uid()`; one per User, lives in personal practice only, hidden from Clients tab. |
| **Self-verification** | new | On-device MobileFaceNet check at capture time; stamps `exercises.self_verified` boolean; flag feeds publish-cost decision. |
| **Self-reference selfie** | new | The Public profile selfie + its computed MobileFaceNet embedding; powers both Safe Mode transparency and self-verification. |
| **My Workouts** | amended | Tab rename from "Workouts"; user-scoped surface containing self-captures + inbound `plan_invitations`. |
| **Publish** | new (formalised) | Universal verb; cost is conditional at the RPC, not by action variant. |
| **Plan artifact** | new | One of N durable outputs per Publish; v1 ships `plan_url` only, prepared for `reel` later. |
| **Safe Mode subscription** | new | 30-day credit-denominated unlock for capture in enforcing geofences; 4 credits/month, manual renewal. |

---

## The three locked architectural decisions

Documented as ADRs because they are hard to reverse, surprising without context, and the result of real trade-offs:

1. **[ADR-0020](./adr/0020-self-trainer-as-practitioner-with-self-as-client.md)** — Self-trainer = Practitioner with `Self-client`; not a separate identity.
2. **[ADR-0021](./adr/0021-safe-mode-subscription-credit-denominated.md)** — Safe Mode subscription priced in credits, debited from `credit_ledger`; not Apple IAP.
3. **[ADR-0022](./adr/0022-plan-artifacts-abstraction-before-reel.md)** — Ship `plan_artifacts` table with one `kind`; pay the abstraction cost up-front so the Reel becomes a pure additive wave.

Three other decisions are load-bearing but documented inline here (not as ADRs) because they're consequences of the above or have clearer rationale already captured in this doc + `CONTEXT.md`:

- Self-clients exist only in the personal practice (revised from "per-practice" mid-design after the strandable-rows problem surfaced).
- The "Publish" cost preview is always-on, not just when non-zero (the "Free" signal is itself information).
- Existing Safe Mode users are grandfathered (perpetual free) rather than hit a hostile cutover paywall.

---

## Schema deltas

All additive. No drops, no renames, no breaking changes. Migration filename: `supabase/migrations/YYYYMMDDHHMMSS_self_trainer_wave.sql` (timestamp picked at PR open).

### 1. `clients.user_id`

```sql
ALTER TABLE clients
  ADD COLUMN user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL;

CREATE UNIQUE INDEX clients_one_self_per_user_per_practice
  ON clients (practice_id, user_id)
  WHERE user_id IS NOT NULL AND deleted_at IS NULL;
```

Populated only for self-client rows. Partial unique index enforces "one self-client per user per practice" (which, per the personal-practice-only rule, means exactly one per user total). Backfill: none (no existing self-clients).

### 2. `practitioners.face_embedding`

```sql
ALTER TABLE practitioners
  ADD COLUMN face_embedding vector(192),    -- pgvector; same dimension MobileFaceNet emits
  ADD COLUMN face_embedding_consented_at timestamptz,
  ADD COLUMN face_embedding_computed_at timestamptz;
```

The embedding is the math; `face_embedding_consented_at` records the moment the user explicitly opted into "use this for self-verification" (Q14.1); `face_embedding_computed_at` records when the embedding was generated (for staleness diagnostics). Backfill: none — existing users go through the consent prompt on next launch (per [migration plan](#migration-plan)).

If pgvector isn't yet installed: `CREATE EXTENSION IF NOT EXISTS vector;` at the top of the migration. Already a sibling of `pgjwt` which is in use.

### 3. `plan_artifacts` table

```sql
CREATE TABLE plan_artifacts (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_id       uuid NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
  kind          text NOT NULL CHECK (kind IN ('plan_url')),
  status        text NOT NULL DEFAULT 'ready'
                  CHECK (status IN ('pending', 'generating', 'ready', 'failed')),
  output_url    text,
  generated_at  timestamptz NOT NULL DEFAULT now(),
  error_message text,
  metadata      jsonb NOT NULL DEFAULT '{}'::jsonb,
  UNIQUE (plan_id, kind)
);

CREATE INDEX plan_artifacts_plan_id ON plan_artifacts (plan_id);

-- RLS: same access shape as plans; RPC-write-only.
ALTER TABLE plan_artifacts ENABLE ROW LEVEL SECURITY;
CREATE POLICY plan_artifacts_select_via_plan ON plan_artifacts FOR SELECT
  USING (
    plan_id IN (
      SELECT p.id FROM plans p
      JOIN clients c ON c.id = p.client_id
      WHERE c.practice_id = ANY (user_practice_ids())
    )
  );
REVOKE INSERT, UPDATE, DELETE ON plan_artifacts FROM authenticated, anon;

-- Backfill existing plans
INSERT INTO plan_artifacts (plan_id, kind, status, generated_at)
SELECT id, 'plan_url', 'ready', COALESCE(last_published_at, updated_at)
FROM plans
WHERE deleted_at IS NULL;
```

### 4. `credit_ledger.kind = 'safe_mode_month'`

The `credit_ledger.kind` column today is text with no CHECK constraint — already extensible. The new kind is purely conventional; no schema change needed except the index for the gating query:

```sql
CREATE INDEX credit_ledger_safe_mode_lookup
  ON credit_ledger (user_id, kind, created_at DESC)
  WHERE kind IN ('safe_mode_month', 'safe_mode_month_trial');
```

`safe_mode_month_trial` is the kind for the 3-day trial credit row (debit amount = 0; serves as the "I started a trial" marker so the gating fn can compute "are you inside trial window?" without a separate table).

### 5. `practice_members.safe_mode_grandfathered`

```sql
ALTER TABLE practice_members
  ADD COLUMN safe_mode_grandfathered boolean NOT NULL DEFAULT false;

-- Backfill: any user who has ever captured with safe_mode_active=true gets it.
UPDATE practice_members pm
SET safe_mode_grandfathered = true
WHERE EXISTS (
  SELECT 1 FROM exercises e
  JOIN plans p ON p.id = e.session_id
  JOIN clients c ON c.id = p.client_id
  WHERE c.practice_id = pm.practice_id
    AND e.safe_mode_active = true
);
```

Used by the gating fn (`is_in_active_safe_mode_sub`) to short-circuit to true for grandfathered users.

### 6. `exercises.self_verified` (likely; confirm column name)

```sql
ALTER TABLE exercises
  ADD COLUMN self_verified boolean;  -- NULL = not yet checked; true/false = verification result
```

Populated by the conversion pipeline after MobileFaceNet runs on the captured frames. NULL for legacy rows. The session-level aggregation in the publish flow treats NULL as "unverified" (conservative).

---

## IA changes

### Home scope row

**Before:**
```
[ Clients · Classes ]    [ Workouts ]
   flex 1.95                 flex 1
```

**After:**
```
[ My Workouts ]    [ Clients · Classes ]
   flex 1               flex 1.95
```

- Capsules swap order; widths unchanged (Q5.2).
- Right capsule (Practice mode) keeps internal segmented sub-scope `Clients ‖ Classes`.
- Single-word "Workouts" chip label becomes "My Workouts" (Q5.4 corrected). `HomeScope.workouts` enum name stays as an internal symbol.

### Cold-launch default

- New installs land on `HomeScope.workouts` (was `HomeScope.clients`).
- Returning users keep their persisted `home_scope_v1` preference (no forced re-routing).

### Chrome on My Workouts

Inherits the post-2026-05-22 minimal Home chrome (practice chip + credits pill + identity row all already retired). No new chips. Only additions on this scope:

- "New Session" FAB (bottom-right).
- "Updated N min ago" sync hint, when applicable — extends from Clients-scope-only.
- Sync-failed banner — extends from Clients-scope-only.
- Safe Mode active banner already renders independently of scope when geofenced; on this wave it gains an embedded sub-status chip (subscriber: "sub · N days left"; trial: "trial · N days left"; non-subscriber: "subscribe to capture here →" deep link to portal).

### Self-capture card design

The third archetype in the My Workouts list (alongside sage "From practitioner" and coral "Subscribed class" cards):

- **Glyph**: Hero frame from the session itself (Q10.1 (d)). During the conversion-pending state, fall back to a line-drawing motif placeholder (Q10.1 (c)).
- **Chip**: none (Q10.2). The absence of a source chip differentiates self-captures from inbound categorised content.
- **Title**: `{DD Mon YYYY HH:MM}` (existing session title format).
- **Subtitle**: `"{N} exercises · captured {relative time ago}"` (Q10.3).
- **Sort**: flat reverse-chronological across self-captures + inbound (Q10.4). No grouping.
- **Tap behaviour**: routes by ownership (Q10.5). Self-captures → Studio mode. Inbound from practitioner → Preview mode. Subscribed class → Preview mode. Branch on `clients.user_id = auth.uid()`.

---

## Capture-entry path from My Workouts

User taps the "New Session" FAB on My Workouts. Flow:

1. **Check self-client + face embedding state.**
   - If both exist: skip to step 4.
   - If neither exists: inline selfie prompt sheet (Q8.1, Q8.4). "Quick selfie to register yourself · so we know it's you in your videos." Front camera, single shot.
   - If selfie exists but embedding doesn't (existing Public profile user): inline consent prompt + background embedding compute (per migration plan).

2. **On selfie confirm** (or pre-existing selfie + consent): write the embedding to `practitioners.face_embedding` via new RPC `register_self_face(p_embedding vector(192), p_consented_at timestamptz)`. Same RPC creates the Self-client (`clients (practice_id, user_id, name)` with `name = 'Me'`, `practice_id = personal_practice_id`).

3. **On dismiss without registering**: user backs out of the FAB tap; no session created; they can try again later. No coerced flow.

4. **Mint session bound to self-client.** Same `create_session` flow as Client-detail screen, but `client_id = self_client_id`. Navigates straight into Session shell with Camera as the default mode.

5. **At capture time**: MobileFaceNet runs on captured frames (already loaded by Safe Mode v2). Largest face's embedding compared to registered embedding; distance below threshold → `self_verified = true` stamped on the `exercises` row. Above threshold or no face → `false`. Capture is never blocked by verification failure (Q2.4, Carl's correction — gym-equipment snapshots are valid use).

6. **Inside an enforcing geofence**: Safe Mode pipeline runs as today (bystander blur). The subscription-gating check (`is_in_active_safe_mode_sub(auth.uid())`) fires *before* the camera opens. If false, paywall sheet replaces the camera viewfinder (deep link to portal). If true, capture proceeds normally with the Safe Mode banner overhead.

---

## Publish flow changes

The universal `consume_credit` RPC gains conditional cost computation (Q11.2). New auxiliary RPC `preview_publish_cost(p_session_id uuid) RETURNS integer` runs the same logic without the debit, used by the Studio Publish pill to render `"Publish · Free"` / `"Publish · 1 credit"` / `"Publish · 2 credits"` pre-tap.

The cost logic (pseudocode):

```
preview_publish_cost(session_id) AS:
  plan := plans WHERE id = session_id
  client := clients WHERE id = plan.client_id
  exercises := exercises WHERE session_id = plan.id

  is_self_session := (client.user_id = auth.uid())
  all_verified := bool_and(coalesce(exercises.self_verified, false))

  IF is_self_session AND all_verified:
    RETURN 0
  ELSE:
    IF estimated_duration(exercises) <= 75 min:
      RETURN 1
    ELSE:
      RETURN 2
```

`consume_credit` runs the same logic and debits accordingly. A 0-credit publish writes a `kind='publish_free'` ledger row with `amount=0` for audit symmetry — the `plan_issuances` row still gets written.

Every Publish also writes one `plan_artifacts (plan_id, kind='plan_url', status='ready')` row in the same transaction.

The workflow pill keeps its CAPS chain: Capture → Adjust → Preview → Publish → Share. "Publish" label is universal (Q11.1). No confirmation dialog (Q11.3 / R-01). Existing "Published ✓" toast unchanged (Q11.4).

---

## Safe Mode subscription model

| Aspect | Decision |
|---|---|
| Who is gated | Anyone inside a Safe Mode enforcing geofence, regardless of role (Q7.1 (e)) |
| What's unlocked | Capture-in-premises only (Q7.2 (a)) |
| Pricing unit | Monthly subscription (Q7.4a (d)) |
| Cost | 4 credits / month (~R100 at R25/credit) (Q7.4c) |
| Trial | 3 days free on first subscription; no further trial on renewal / resub (Q7.4b) |
| Renewal | Manual (v1); push notification at day 25 + Settings → Subscription button (Q7.4e (ii)) |
| Lapse semantics | Honor what you sold: only future in-premises captures are gated; existing captures and Plan URLs stay accessible (Q7.5) |
| Billing channel | `manage.homefit.studio`; Reader-App compliant (no in-app prices) (Q7.4 (c) revised) |
| Currency | Credits (`kind='safe_mode_month'`, debit 4 from `credit_ledger`) |
| Independence from publish credits | Yes — sub gates Capture, publish credits gate the for-others Publish (Q7.4d) |
| Grandfathering | Users with any `exercises.safe_mode_active=true` history get `safe_mode_grandfathered=true`; perpetual free Safe Mode (Q13.3) |

Gating function (called at capture entry inside any enforcing premises):

```sql
CREATE FUNCTION is_in_active_safe_mode_sub(p_user_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT EXISTS (
    -- grandfathered → always true
    SELECT 1 FROM practice_members
    WHERE user_id = p_user_id AND safe_mode_grandfathered = true
  ) OR EXISTS (
    -- active paid sub within 30-day window
    SELECT 1 FROM credit_ledger
    WHERE user_id = p_user_id
      AND kind = 'safe_mode_month'
      AND created_at > now() - INTERVAL '30 days'
  ) OR EXISTS (
    -- active trial within 3-day window
    SELECT 1 FROM credit_ledger
    WHERE user_id = p_user_id
      AND kind = 'safe_mode_month_trial'
      AND created_at > now() - INTERVAL '3 days'
  );
$$;
```

---

## Persona onboarding

| Decision | Lock |
|---|---|
| When selfie registration prompts | Inline on first My Workouts FAB tap (Q8.1 (b)) |
| Empty state copy | "Record your first workout" primary CTA + secondary "Got a link from your practitioner?" affordance (Q8.2 (a)) |
| Practice mode visibility for cold-installers | Both capsules visible; no hiding (Q8.3 (a)) |
| Tap "New Session" before selfie | Block until registered (Q8.4 (a)); the inline sheet from Q8.1 IS the block |

---

## Migration plan

Three classes of existing user; minimal disruption strategy.

| User class today | After wave |
|---|---|
| Practitioner with no Public profile selfie | Sees renamed "My Workouts" tab; empty state; first FAB tap → inline selfie sheet → opt-in or back out |
| Practitioner with existing Public profile selfie | Same as above, *but* on next launch a background task computes the MobileFaceNet embedding from the existing selfie + creates the Self-client — gated on a one-time POPIA consent prompt for the new "use my face for self-verification" purpose (Q14.1 (b)) |
| Practitioner with prior `safe_mode_active=true` capture history | Grandfathered: `practice_members.safe_mode_grandfathered = true`; perpetual free Safe Mode; in-app banner explaining the change |

### Lazy backfill on next launch

On app launch post-update, for the current user:

1. Read `practitioners` row for `face_embedding` + `face_embedding_consented_at`.
2. If selfie exists AND consent not yet given: prompt POPIA consent dialog ("Use your photo for self-verification too? · This lets us recognise you in your captures for free · Yes / Not now").
3. If consent given (now or previously): if embedding is missing, run MobileFaceNet locally on the cached selfie → call `register_self_face(embedding, consented_at)` → server writes embedding + creates Self-client.
4. If "Not now": no embedding, no Self-client; user keeps existing transparency-only selfie. Can opt in later via Settings → Public profile.

Failure modes: MobileFaceNet compute fails (e.g. older iOS without the model on-device) → silently retry on next launch; user is non-self-trainer until success. Network failure on `register_self_face` → queued via existing `pending_ops` machinery; cache updates locally.

### Communication

Single in-app banner on first launch post-update (Q13.5 (a)):
- For everyone: "My Workouts is live · capture yourself, receive plans from your practitioner."
- Additional line for grandfathered users: "We've extended your Safe Mode access for free."
- Dismissible. No push notifications, no marketing email blast.

---

## POPIA compliance

The face embedding is "special personal information" under POPIA Section 26. Six compliance items (Q14):

1. **Consent specificity (Q14.1)** — Existing Public profile selfie consent was for transparency display only; self-verification is a different purpose. Lazy backfill is **consent-gated** — embedding only computed after the user taps Yes on the in-app POPIA prompt. Stamped at `practitioners.face_embedding_consented_at`.
2. **Storage location + cross-border (Q14.2)** — Embedding stored in Supabase (AWS-hosted region; verify before wave ships). No new exposure beyond existing PII. Update `web-portal/src/app/privacy/page.tsx` to include biometric data section.
3. **Decoupled deletion (Q14.3)** — Settings → Public profile gains a "Stop using face verification" link. Tap → deletes `face_embedding` (cloud + on-device cache) + soft-deletes Self-client + reverts user to non-self-trainer state. Selfie + name remain for Safe Mode transparency.
4. **Privacy policy + Apple privacy manifest (Q14.4)** — Wave checklist item: privacy policy delta (biometric data section) + `PrivacyInfo.xcprivacy` update (add `NSPrivacyCollectedDataType` entry: linked, not tracking, app-functionality purpose) + `docs/app-store-connect-privacy.md` click-through mirror.
5. **Encryption at rest (Q14.5)** — Rely on Supabase + AWS at-rest encryption for v1. Per-user column encryption added to security backlog as defence-in-depth.
6. **Breach notification readiness (Q14.6)** — Lightweight incident-response runbook (one paragraph in `docs/RESEND_SETUP.md` or new `docs/INCIDENT_RESPONSE.md`): Regulator + user notification template, 72-hour POPIA window.

---

## Doc drift to sweep

Two known stale references in [`CLIENT_WORKOUTS_AND_CLASSES.md`](./CLIENT_WORKOUTS_AND_CLASSES.md) flagged in `CONTEXT.md`:

1. Doc uses "My Workouts" throughout; shipped UI today reads "Workouts" — to be brought into line by the rename (one-line label change in `home_screen.dart` `HomeScopeSegmented`). After this wave the doc is correct.
2. Doc describes an "Identity row" of chips (Practice + Offline + Credits) below the scope row; that row was retired 2026-05-22. Update doc's chrome rules table to reflect actual post-retirement Home (brand lockup + scope row + sync hint + corner icons only).

Also: the doc's framing of "My Workouts as consumer mode" should be amended with a note pointing to this `SELF_TRAINER_WAVE.md` as the authoritative model (Self-trainer is a Practitioner; not a separate consumer identity).

---

## PR sequence

Each step is small enough to design + review + ship without rework on the others. Steps land in this order; later steps depend on earlier ones.

| # | PR title | Branch | Target | Risk | Spawnable autonomously? |
|---|---|---|---|---|---|
| 1 | Schema migrations (additive only) | `feat/self-trainer-schema` | staging | Low | **Yes** (additive, no behaviour change) |
| 2 | Home IA rename + layout swap + first-launch default | `feat/my-workouts-ia` | staging | Low | **Yes** (UI only, contained) |
| 3 | iOS native MobileFaceNet embedding compute + RPC wire-up | `feat/self-face-embedding` | staging | Medium | **Held** — needs device testing per `gotcha_ios_debug_needs_debugger` |
| 4 | Public profile consent UI + lazy backfill + Self-client creation | `feat/self-trainer-consent` | staging | Medium | **Held** — POPIA-sensitive, needs Carl review |
| 5 | Capture-time self-verification + `exercises.self_verified` stamping | `feat/self-verification-capture` | staging | Medium | **Held** — touches conversion pipeline (sensitive zone) |
| 6 | Publish flow cost preview + `consume_credit` cost logic + 0-credit publish row | `feat/publish-cost-preview` | staging | Medium-high | **Held** — sensitive client RPC change |
| 7 | `plan_artifacts` write on publish + `get_plan_full` extension | `feat/plan-artifacts-write` | staging | Medium | **Held** — anon-callable RPC change |
| 8 | Safe Mode subscription gate at capture entry + grandfather query + paywall sheet | `feat/safe-mode-subscription-gate` | staging | High | **Held** — billing-sensitive |
| 9 | My Workouts body + FAB wire-up + self-capture card archetype + tap routing | `feat/my-workouts-body` | staging | Medium | **Held** — depends on PR #4 + #5 + #6 |
| 10 | Migration in-app banner + grandfathered user copy | `feat/self-trainer-migration-banner` | staging | Low | **Held** — copy depends on Carl review |
| 11 | Privacy policy delta + `PrivacyInfo.xcprivacy` update + ASC checklist update | `feat/self-trainer-privacy-docs` | staging | Low | **Held** — legal review needed before merge |

PRs #1 and #2 will be spawned autonomously now. PRs #3-#11 have briefs ready under [`docs/sub-agent-briefs/`](./sub-agent-briefs/) for Carl to spawn after review.

---

## Held briefs

Sub-agent brief files staged under `docs/sub-agent-briefs/` for the held PRs. Each carries:
- Repo-relative paths (per `feedback_agent_worktree_isolation`)
- Target branch + naming convention (per `feedback_branch_naming_discipline`)
- RPC-only DB access convention (per `feedback_no_direct_db_access`)
- R-10 mobile/web parity rule where applicable
- Test script expectation (per `feedback_always_test_script`)
- Specific files to touch + acceptance criteria

Carl spawns these with the `homefit-agent-brief` skill when ready.

---

## Open questions

Carried forward from the grilling session — none block PR #1 or #2:

- **OQ-15** — Self-capture card "Hero frame" availability during conversion-pending: confirmed fallback to line-drawing motif (Q10.1 (c)); UX of the fallback to be designed.
- **OQ-16** — Subscription renewal auto-debit (v2 opt-in toggle) deferred until lapse-and-recover data exists.
- **OQ-17** — PDF handout migration into `plan_artifacts` deferred (Q12.4); needs its own bucket + signed URL design wave.
- **OQ-18** — Per-user column encryption for `face_embedding` defence-in-depth; security backlog (Q14.5).
- **OQ-19** — Reel artifact ("`kind='reel'`") rendering pipeline: vertical 9:16, beat-matching, watermark, sound. Separate focused wave when prioritised.
- **OQ-20** — When two-tier "active sub" needs to differentiate paid-month from trial in UX copy — currently both render "Subscribed · N days left" inside the Safe Mode banner; consider differentiating "Trial · N days left" if conversion data suggests it matters.
- **OQ-21** — Supabase project AWS region verification + privacy-policy lawful-basis-for-transfer wording (Q14.2). Lawyer red-pen item.

---

## Non-goals

Documented here so we don't drift back into them:

- A separate consumer identity (`consumer_profiles` table, no `practice_members` row). Rejected per ADR-0020; Self-trainer is a Practitioner.
- Apple IAP for the Safe Mode subscription. Rejected per ADR-0021; credit-denominated only.
- A `plans.kind` enum or `is_self_capture` boolean. Rejected per Q3 / ADR-0020; publish is universal, cost is conditional.
- Per-practice Self-clients. Rejected per Q4.3 revision; one Self-client per User, lives in personal practice only.
- A "Reader-App carve-out doesn't apply to subscription unlocks" workaround that ships in-app prices. The credit-denominated model means we don't need one — credits are already purchased on the portal.
- Forcing existing practitioners to re-register their selfie. The existing selfie is reused; only the embedding is computed lazily + consent-gated.
- Splitting the workflow pill copy by persona ("Save" for self / "Publish" for clients). Rejected per Q11.1; universal verb.
- Auto-renewal of subscriptions in v1. Deferred to v2 once we know lapse-and-recover patterns.

---

## Decision log

All 14 grilling-session decisions chronologically. Q-numbers map to the question blocks in the source session.

- **2026-05-25 Q1** — Identity model: (B) practitioner-with-self-as-client. Carl confirmed: self-picture registration in Settings + Safe Mode subscription as monetization vector.
- **2026-05-25 Q2** — Face registration mechanic: embedding + selfie thumbnail, cloud + on-device storage, soft-flag credit path on mismatch, permissive on no-face (Carl correction), manual re-registration. Settings Public profile is the home (Carl correction).
- **2026-05-25 Q3** — Always publish; session-level credit aggregation; abstract `plan_artifacts` table now, ship Plan URL only. Carl pushed back on initial "never publish by default" recommendation; reframed publish as universal verb with conditional cost.
- **2026-05-25 Q4** — `clients.user_id` column + partial unique index; lazy on Public profile save; per-practice (revised mid-wave); hidden in Clients tab; default name "Me".
- **2026-05-25 Q5** — Universal swap (My Workouts left); keep today's widths; first-launch default to My Workouts; rename Workouts → My Workouts (Carl's correction after initial reverse).
- **2026-05-25 Q6** — FAB pattern; identical flow; **Q4.3 revised to personal-practice-only** (the strandable-rows problem); default to Camera mode.
- **2026-05-25 Q7** — Anyone in geofence (not by role — Carl correction); capture-in-premises only; 3-day trial within first sub; **credit-denominated subscription** (Carl's reframe — replaces Apple IAP); 4 credits / month (R100); manual renewal; honor what you sold on lapse.
- **2026-05-25 Q8** — Inline selfie on first FAB tap; primary Record CTA; both capsules visible; block until registered.
- **2026-05-25 Q9** — Minimal Home chrome (Carl correction — practice + credits chips already retired 2026-05-22). Sub status inside Safe Mode banner, not standalone Home chip. "Updated N min ago" + sync-failed banner extended to My Workouts.
- **2026-05-25 Q10** — Hero frame as glyph (motif fallback); no chip on self-captures; "{N} exercises · captured Xh ago" subtitle; flat reverse-chron; tap routes by ownership.
- **2026-05-25 Q11** — Universal "Publish" label; always-on cost preview ("Publish · Free" / "Publish · N credits"); no confirmation; unchanged toast.
- **2026-05-25 Q12** — `plan_artifacts` table shape; write on every Publish; backfill in migration; defer PDF migration; extend `get_plan_full` for artifacts array.
- **2026-05-25 Q13** — Lazy embedding backfill; create Self-client at backfill moment; grandfather existing Safe Mode users; no migration action for first-launch default; minimal in-app banner.
- **2026-05-25 Q14** — Explicit re-consent for biometric purpose; verify region + privacy policy delta; decoupled deletion toggle; package policy + manifest update with wave; defer column encryption; lightweight incident runbook.
