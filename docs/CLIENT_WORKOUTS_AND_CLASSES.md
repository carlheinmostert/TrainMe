# Clients, Classes & My Workouts — design doc

**Status:** living design doc · front-end shell shipped in TestFlight v2 · backend deferred to follow-up PRs

**Owners:** Carl + Claude

**Related artifacts:**
- Mockup: `docs/design/mockups/home-app-shell.html`
- Rendered states: `docs/design/mockups/home-app-shell.*.png`
- TestFlight v2 PR: #315 (front-end shell only; this doc covers everything that's NOT in that PR)

---

## North star

homefit.studio is becoming a **two-mode product** in one app shell:

1. **Practice mode** (creator) — what exists today. Practitioners build plans for clients (1-on-1, credit-gated publish) and, future, classes (1-to-many, once-off purchase at MVP; subscriptions a later phase).
2. **My Workouts mode** (consumer) — what comes next. End-clients receive plans from their practitioner and/or subscribe / buy classes; they play workouts inside the app instead of in the browser.

Both modes live in one binary. A user can be just-a-practitioner, just-a-consumer, or both. The IA accommodates all three.

The TestFlight v2 release locks the **shell** in place — two capsules on a single row, locked teaser bodies for Classes and My Workouts, chip-fade rules per mode. Future PRs progressively swap the teaser bodies for real implementations without moving the shell.

---

## Information architecture (locked)

### The two-capsule scope row

```
[ Clients · Classes Soon ]      [ My Workouts Soon ]
        Practice capsule              Workouts capsule
         (flex 1.95)                    (flex 1)
```

- **Left capsule** = Practice mode. Internal sub-scope split: Clients / Classes.
- **Right capsule** = My Workouts. Single segment today; future sub-scopes (e.g. "From practitioner" / "My classes") could split inside this capsule if needed.
- Two visually-distinct primitives tell the truth that Practice (creator) and My Workouts (consumer) are different *identities*, not peer tabs.
- Adding a third top-level identity later (e.g. "Marketplace") would mean a third capsule — the layout primitive scales.

### Chrome rules per scope

| Element | Clients | Classes | My Workouts |
|---|---|---|---|
| Brand lockup + logo | Visible | Visible | Visible |
| Scope row (two capsules) | Visible | Visible | Visible |
| **Identity row (below scope row)** | Practice + Offline + Credits | Practice + Offline | **Not rendered** |
| Practice chip | Visible | Visible | Hidden |
| Credits chip | Visible | **Hidden** (classes don't use credits) | Hidden |
| Offline-sync chip | Visible (when offline / queued) | Visible | Hidden — see open question OQ-3 |
| Network-share corner icon | Visible | Visible | Hidden (referrals are practitioner-only) |
| Help + Settings corner icons | Visible | Visible | Visible |
| Bottom CTA slot | "New Client" | Empty (today) → "New Class" later | Empty (today) → "Add a workout" later |

**Why chips below the scope row, not above:** the chips are properties of the Practice capsule, not the app shell. Putting them below anchors them visibly to the capsule that owns them; flipping to My Workouts collapses the row entirely (no fade, no placeholder). `AnimatedSize` with 180ms ease handles the layout shift so it reads as deliberate.

### Persistence

- SharedPreferences key `home_scope_v1` stores the enum name (`clients`, `classes`, `workouts`).
- Defaults to `clients` on first launch.
- Last-selected scope survives app restart.

---

## Vocabulary — UI ↔ Flutter ↔ Supabase

The codebase has drifted on three axes over its lifetime: UI copy says one thing, the Flutter model class is named after the old UI copy, the DB column was named after an even older intent. This section is the canonical mapping. Update it whenever a new entity lands.

### The "session" naming footgun

The word **session** points at THREE unrelated things in this codebase. Internalise the distinction or pain will follow:

| Phrase you'll hear | What it actually is | Lives in |
|---|---|---|
| **Session** (UI / Studio / Camera) | The workout package the practitioner captures and publishes — what the consumer plays at `session.homefit.studio/p/{uuid}` | `plans` table (yes, called "plans" on the DB) |
| **Client session** | One anonymous visit to a published plan, for analytics | `client_sessions` table |
| **Auth session** | A Supabase JWT login | `auth.sessions` table (managed by Supabase) |

When somebody says "session" without qualifying, they usually mean the first one. The other two carry the qualifier.

### The CPE hierarchy

Internal shorthand for the workout content model: **C** · **P** · **E** —
**C**lient-or-**C**lass → **P**lan → **E**xercise.

A useful mnemonic for design / code review / PR discussions:

- "Move this logic up to the **P** layer" — i.e. onto `plans`, not on each exercise.
- "That's a **C**-side decision" — i.e. belongs on the Client or Class parent, not on the Plan.
- "The conversion pipeline lives at the **E** layer" — i.e. per-row in the `exercises` table.

⚠️ **Don't use "CPE" in user-facing copy or in conversations with practitioners.** In the SA biokinetics / physio / fitness-trainer world, CPE is **Continuing Professional Education** (HPCSA registration upkeep). Reserve our usage for engineering / design contexts where the meaning is unambiguous from the room.

There is **exactly one** one-to-many relationship for workout content in the schema today, and one new column extends it to support classes:

```
                       ┌─────────────┐
                       │   Client    │   ← 1-on-1 owner (today)
                       │  (clients)  │
                       └──────┬──────┘
                              │ FK: plans.client_id
                              ↓
                       ┌─────────────┐
                       │   Class     │   ← many-recipient owner (future)
                       │  (classes)  │
                       └──────┬──────┘
                              │ FK: plans.class_id
                              ↓
            ┌─────────────────────────────────┐
            │              Plan                │   ← the shareable unit
            │           (plans row)            │     (UI: "Session")
            │  client_id XOR class_id (CHECK)  │
            └─────────────────┬────────────────┘
                              │ FK: exercises.session_id
                              ↓ (many)
                       ┌──────────────┐
                       │   Exercise   │   ← one row = one video / photo
                       │  (exercises) │     / rest period inside the Plan
                       └──────────────┘
```

- **Client and Class are peers** — both own Plans via a nullable FK on `plans`. Exactly one of `plans.client_id` / `plans.class_id` is non-null (`CHECK (num_nonnulls(client_id, class_id) = 1)`).
- **Plan is the shareable unit.** Its UUID becomes the URL `session.homefit.studio/p/{uuid}`. UI calls it a "Session"; URL + DB call it a "Plan". One row.
- **Exercise is the only child.** Reps, sets, hold, video duration, circuits, rest periods, hold-position — all live as columns on the exercise row OR jsonb maps on the parent plan. **There is no separate sets / reps / circuits table.**

This symmetry is also why the IA inside Practice mode is `[ Clients · Classes ]` — the segmented control simply lets the practitioner switch which kind of Plan parent they're viewing.

### Today — what exists in this PR's world

| UI term | Flutter model | Supabase | Lifecycle / scope | Notes |
|---|---|---|---|---|
| **Practice** | `Practice` / `PracticeMembership` | `practices` + `practice_members` | Top-level tenant | Multi-tenancy boundary; auto-created on first sign-in. |
| **Practitioner** | `AuthService.currentUser` | `auth.users` ↔ `practice_members.user_id` | Authenticated user | DB columns occasionally say `trainer_id` for legacy reasons; UI copy is **always "practitioner"** (R-06). |
| **Client** | `PracticeClient` | `clients` | Practice-scoped (`practice_id` FK) | UI copy is always "client". |
| **Session** (UI) | `Session` | `plans` (row) | Client-scoped (`client_id` FK) | **The renaming gap.** UI says "session"; Flutter class is `Session`; the same record is `plans` on the DB because the consumer-facing URL is `/p/{uuid}` (a plan link). One row, three names. |
| **Plan** (URL) | (same record) | `plans.id` → `session.homefit.studio/p/{uuid}` | Same record as above | "Plan" is the consumer-facing word for the same Session — they are literally the same row. |
| **Plan version** | `Session.version` | `plans.version` (int) | Per-Session | Increments on every Publish; the URL stays the same. |
| **Exercise** | `ExerciseCapture` | `exercises` | Session-scoped (`session_id` / FK to `plans.id`) | Holds reps/sets/hold/notes/media path. |
| **Circuit** | `Session.circuitCycles` (Map) + `Exercise.circuitId` | `exercises.circuit_id` + `plans.circuit_cycles` (jsonb) + `plans.circuit_names` (jsonb) | Session-scoped | A grouping; not its own table. |
| **Rest period** | `ExerciseCapture` with `mediaType: rest` | `exercises` row with `media_type = 'rest'` | Session-scoped | Distinct *visual* category, not a distinct table. |
| **Credit** | rendered by `HomeCreditsChip`; consumed by `consume_credit` RPC | `credit_ledger` (append-only) + `practice_credit_balance` RPC | Practice-scoped | 1 credit per Clients-mode publish ≤ 75 min, 2 credits if > 75 min. **Classes will not use credits.** |
| **Plan analytics event** | (web-player only) | `plan_analytics_events` | Per visitor session | Consent-gated via the client's `analytics_allowed` flag. |
| **Client visitor session** | (web-player only) | `client_sessions` | One row per anon visit | See footgun callout above. |
| **Plan issuance (audit)** | n/a | `plan_issuances` | Per publish | Append-only audit log; consumed by the portal Audit page. |
| **Referral code** | rendered by `NetworkShareSheet` | `referral_codes` + `practice_referrals` + `referral_rebate_ledger` | Practice-scoped | 5% lifetime rebate model (Milestone M). |

### Future — what this design proposes adding

| UI term | Flutter model (proposed) | Supabase (proposed) | Lifecycle / scope | Notes |
|---|---|---|---|---|
| **Class** | `Class` | `classes` (new table) | Practice-scoped | Practitioner-published, consumer-buyable. Subscription or once-off. **No credits**. A Class is a *collection of Plans* — same structural role as a Client, just with many-recipient monetization instead of one-recipient credits. |
| **Class plan** | (reuses `Session` / `Plan`) | `plans.class_id` FK (new, nullable) | Class-scoped | **There's no separate "class session" entity.** Plans inside a Class are structurally identical to Plans under a Client — same `plans` row shape, same `exercises` rows, same conversion / preview / playback pipeline. The only schema change is one nullable FK on `plans`. |
| **Plan invitation** | `PlanInvitation` | `plan_invitations` (new) | Plan + email + accepted_by_user_id | The email-magic-link bridge. One row per invite. Bound to a `plan_id` and optionally to a `class_id` once classes ship. |
| **Workout** (consumer-facing) | `ConsumerWorkout` | View joining `plan_invitations.accepted_by_user_id = current_user.id` UNION `class_purchases` | Consumer-scoped | What lands in My Workouts. A single row could be a 1-on-1 plan (from a practitioner) OR a class instance (subscribed/bought). The UI calls all of them "workouts". |
| **Consumer profile** | `ConsumerProfile` | `auth.users` + `consumer_profiles` (new, optional metadata table) | Per auth.user, **no `practice_members` row** | Users who only consume content. Same `auth.users` table as practitioners — the absence of a `practice_members` row is what marks them as consumer-only. |
| **Class purchase** | `ClassPurchase` | `class_purchases(consumer_user_id, class_id, purchased_at)` (new) | Consumer + Class | One-time, lifetime access. Web-portal-driven (no iOS IAP — Reader-App compliance, same channel as today's credit purchases). The **only** Class access table at MVP. |
| **Class subscription** | n/a at MVP | n/a at MVP | n/a at MVP | **Deferred to future phase** (PR sequence step 12). Decision 2026-05-13 — start with once-off; subscriptions add recurring auth + lapse handling + dunning + prorated upgrades, none of which is needed to validate the monetization story. |
| **Plan claim** | (action, not entity) | `claim_plan(p_token)` RPC + the `plan_invitations.accepted_by_user_id` write | — | "Claiming" a plan = accepting an invite. After claim, the public `/p/{uuid}` URL stops serving to anonymous viewers (handled inside `get_plan_full`). |

### Retired — terms NOT to use

| Term | Why it's retired |
|---|---|
| **Project** | Earlier mental model for a unifying parent that would hold both 1-on-1 Sessions and group Classes. **Superseded** by the two-parallel-scope design (Clients ‖ Classes). Don't use "project" anywhere in copy or code. |
| **Patient** / **Bio** / **Physio** / **Trainer** / **Coach** (as role nouns) | All retired in favour of **practitioner** (Design Rule R-06). The DB column `plans.trainer_id` still exists for backwards-compat but should never appear in user-facing copy. |
| **JIT (just-in-time client-pay)** | Considered for the revenue model, rejected (adherence-damaging). Don't propose it again. |

### Naming gaps that will stay

A few mismatches we'll keep on purpose because renaming would be more disruptive than the confusion is worth:

- **`Session` (Flutter) ↔ `plans` (DB)** — the rename gap was already paid for once when "TrainMe / Raidme" → "homefit.studio" landed. Renaming the Flutter `Session` class to `Plan` would touch hundreds of call sites for no user-visible benefit. The UI says "session" because that's what practitioners think they're capturing; the URL says "plan" because that's what clients think they're receiving. Both are right.
- **`trainer_id`** column on `plans` — legacy from when the role noun was "trainer". Rename would require a coordinated migration + RLS policy update; not worth it. Use it via the wrapper RPCs, never expose to UI.
- **`raidme.db`** SQLite filename — pre-rename artifact. Not user-visible. Leave alone.

### Adds new open questions to the queue

- **OQ-6** ✓ **Resolved 2026-05-13** — Classes are a separate `classes` table, not an overload on `plans.kind`. Lifecycles diverge (no credits, has subscription, has cohort/capacity), and decoupling the migration from the existing `plans` RPCs (`replace_plan_exercises`, `get_plan_full`, `consume_credit`) keeps the credit model + RLS rules clean.
- **OQ-7** ✓ **Resolved 2026-05-13** — A Class is a *collection of Plans* (peer of Client). Plans gain one new nullable FK column `plans.class_id` alongside the existing `plans.client_id`; exactly one must be non-null (CHECK constraint). The `exercises` table is unchanged. The conversion / preview / playback pipeline is identical for class plans and client plans.

---

## TestFlight v2 ships (in PR #315)

Front-end only. Bodies for Classes + My Workouts are **locked teasers** — mock cards behind a 62% opacity overlay with a lock glyph. The Workouts teaser shows mixed content sources (sage chip = practitioner-sent, coral chip = subscribed class) so the future model is visible.

**What works:**
- Two-capsule scope row with persistence (`HomeScope.{clients, classes, workouts}`)
- Chip-row collapse + fade on scope change
- Web-player lobby has the "Get the app & import this session" CTA → opens email sheet → tapping Send fires a polite "Thanks! We'll let you know when import is live." toast (no backend round-trip)
- All copy and visual rules signed off via mockup

**What's intentionally a no-op:**
- The lobby import sheet's `Send import link` button (TestFlight v2 stub — toast only)
- The Classes capsule (teaser body, never lands on a real screen)
- The My Workouts capsule (teaser body, never lands on a real screen)

---

## What's deferred (this doc's territory)

Each section below corresponds to one or more future PRs. The PR sequencing at the bottom of this doc proposes an order.

### 1. Email-magic-link import bridge

The web-player lobby's "Import to the app" CTA needs a real backend to wire up to. Plan:

- **`plan_invitations` table** — `plan_id` + `recipient_email` + `token` + `created_at` + `accepted_at` + `accepted_by_user_id`. The token is the URL path (`/i/{token}`). Acceptance binds the invite to the consumer's `auth.users` row.
- **`/i/{token}` Universal Link path** on `session.homefit.studio`. iOS opens the app (if installed) or falls back to the in-browser claim page.
- **`apple-app-site-association`** JSON served from `session.homefit.studio/.well-known/` declaring `studio.homefit.app`'s bundle ID can intercept the `/i/*` path prefix. Universal Links require this file — no other deferred-deep-link tricks needed.
- **`claim_plan(p_token TEXT)` RPC** — SECURITY DEFINER. Validates the token, ties the plan to the requesting `auth.users.id`, returns the plan. Idempotent if same user claims twice.
- **`get_plan_full` extension** — already returns the plan via `/p/{uuid}`. New check: if the plan has been claimed (`plan_invitations.accepted_by_user_id IS NOT NULL` AND requester is anon or a different user), return a "this plan has been imported" gate instead of the plan data. Practitioner edit path is unaffected; their access is independent of the consumer claim.
- **Resend SMTP template** for the import-link email. Reuse the existing Resend wire-up that already serves Supabase auth emails (`noreply@homefit.studio` sender; DKIM on `resend._domainkey.homefit.studio`). New template lives in `supabase/email-templates/import_plan_invite.html`.
- **Self-service flow** (web-player lobby): user types email → server creates `plan_invitations` row → email sent. The same `plan_invitations` table also serves practitioner-initiated invites (see section 4) — one pipeline, two entry points.

**Scope note:** `plan_invitations` is for **Client-owned Plans** (`plans.client_id IS NOT NULL`). Class-owned Plans use a different access model — see the next section.

### 1b. Sharing units: Plan vs Class — two access models

The unit of sharing is different for Client-owned Plans vs Class-owned Plans. This is a parked design surface — flagging now so we don't accidentally treat Classes as "a bundle of Plan invitations" when they're a different shape.

**Client-owned Plan** (today's model, extended in section 1):
- Unit of sharing = **one Plan**. The `plans.id` UUID is the URL.
- Access via public link OR `plan_invitations` (email-bound claim).
- Lifetime = single transaction; once claimed, the Plan is bound to that consumer forever.
- One Plan = one credit (consumed at publish time).

**Class-owned Plan** (future model, the new complication):
- Unit of sharing = **a Class** (which contains N Plans).
- A consumer doesn't buy a Plan — they subscribe to or once-off purchase a Class.
- A Class is a **live container**: the practitioner can add new Plans over time, and every consumer who has purchased the Class sees the new Plans appear in their My Workouts automatically (OQ-8 resolved live — see open questions).
- **MVP is once-off purchase only**; subscriptions are a future phase (PR sequence step 12). See decision-log entry 2026-05-13.
- One credit is NOT consumed per Plan inside a Class — Classes monetize via purchase revenue, not credits. Confirms the Clients-only credit rule.

**Public-link semantics for Class-owned Plans** (resolved — see OQ-10 below): the `/p/{uuid}` URL will reject anon access for any Plan with `class_id IS NOT NULL`. Otherwise a subscriber forwards the raw URL and bypasses payment. Access check sketch lives below in the **Data model additions** section after all the resolutions are applied.

**My Workouts representation of class membership:** does a subscribed 6-week-class-with-18-Plans show as 18 rows in the consumer's My Workouts list, or as 1 Class card that expands into 18 Plans? The mock cards in the teaser show flat workouts; the real surface likely needs a hybrid (Class as a parent card, Plans as drill-in detail). **OQ-11** below.

**Data model additions** (MVP scope, post-resolutions):

- `class_purchases(consumer_user_id, class_id, purchased_at)` — one-off access. Lifetime; no expiry. Live container: covers all Plans currently in the Class AND any added later (OQ-8 resolved live).
- No `class_invitations` table — access is grant-on-purchase, not invitation-token-based. (The email-magic-link bridge in section 1 stays Client-only.)
- No `plans.class_position` — Plans inside a Class are ordered by `plans.created_at` ascending (OQ-12 resolved by date).
- No `class_subscriptions` at MVP — subscriptions are a future-phase addition (decision 2026-05-13). When added, will be a second access table checked alongside `class_purchases` in `get_plan_full`.
- Public `/p/{uuid}` URL rejects anon access for Plans with `class_id IS NOT NULL` (OQ-10 resolved — Class Plans are never anonymously playable).

**Access check** (MVP, simplified by the resolutions):

```
get_plan_full(plan_id) — access check (MVP)

  IF plan.client_id IS NOT NULL:
    -- Client-owned Plan (1-on-1) — see section 1
    [unchanged from today + plan_invitations]

  ELSE IF plan.class_id IS NOT NULL:
    -- Class-owned Plan (MVP: once-off purchase only)
    IF requester is practitioner of plan's practice:
      → return plan (practitioner preview)
    ELSE IF EXISTS (
      SELECT 1 FROM class_purchases
      WHERE class_id = plan.class_id
        AND consumer_user_id = auth.uid()
    ):
      → return plan
    ELSE:
      → return "this class is by purchase" gate
      -- anonymous requests always land here; no public URL path
```

**My Workouts UI** (OQ-11 resolved hierarchical): a Class shows as a single parent card in the consumer's list. Tap → drill into a new Class-detail screen that lists the Plans inside (ordered by `plans.created_at`). Tap a Plan → play.

This section captures the surface; the actual schema + RPC design lands in PR step 9 (Classes schema) + step 10 (Class once-off purchase via PayFast or web-portal-driven, NOT iOS IAP for Reader-App compliance — same channel pattern as today's credit purchases).

### 2. My Workouts real surface

When the locked teaser ships its real implementation, the body becomes a list of imported plans + subscribed classes. The mockup already shows the visual model:

- Each row = a content card with sage glyph (practitioner-sent) or coral glyph (subscribed class)
- Tap → opens the plan player (same `web-player/` codebase, but bundled in-app via WebView or — better — ported to native Flutter screens that reuse the existing `app/lib/screens/plan_preview_screen.dart` engine).
- No bottom CTA today; later: "Add a workout" → opens a paste-link / scan-QR sheet for power-user import (alternative to the email path).
- **No practice context, no credits.** Consumer mode is identity-clean.

**Data model:**
- `consumer_profiles` (or just lean on `auth.users` + a flag column) — keyed off the consumer's `auth.users.id`, tracks email, display name, opt-ins. No practice membership.
- `consumer_workouts` view — UNION of `plan_invitations.accepted_by_user_id = auth.uid()` JOINed with `plans` (Client-owned), and `class_purchases.consumer_user_id = auth.uid()` JOINed with `classes` JOINed with `plans` (Class-owned).
- Future-phase (when subscriptions ship): the view extends to UNION in `class_subscriptions` as a second Class-access source.

### 3. Authentication for consumers

Consumers need to sign in to claim a plan or play in-app. Plan:

- Email + magic-link via Supabase auth (same primitive practitioners use).
- Apple Sign-In once Apple Developer Program is active.
- **Intent-inferred routing** at first launch:
  - Cold-launch via Universal Link (`/i/{token}`) → consumer sign-up flow, email pre-filled from the invite token → lands directly in My Workouts with the plan ready.
  - Cold-launch from springboard with no link → practitioner sign-up flow → bootstrap practice → Clients home (today's behavior).
  - Returning user → last-used mode.
- The practitioner's "Upgrade to practitioner" path stays in Settings — consumers who decide to become creators later can self-promote without re-installing.

### 4. Practitioner-initiated email share from Studio

The Share sheet in Studio currently has two paths today (copy link / iOS share sheet). Add a third:

- **Send via email** — opens a small composer with the recipient's email + optional message. On send, creates a `plan_invitations` row (same table as section 1) and fires the Resend template. The plan is now bound to that email; the recipient will get an app-launching link.
- Optionally: pull from a contact list of past clients to pre-fill emails.
- This is symmetric with the self-service path in section 1 — both produce a `plan_invitations` row.

### 5. Classes real surface (Practice mode)

The future Classes sub-tab in the Practice capsule becomes a real list of classes the practitioner has published.

- New data model: `classes` table — separate from `plans` (resolves OQ-6). One-time price column at MVP; cohort scheduling is OQ-5, deferred.
- Plans inside a Class are regular `plans` rows with `class_id` set (resolves OQ-7). Ordered by `plans.created_at` ascending (resolves OQ-12). The conversion / preview / playback pipeline is unchanged from today's 1-on-1 plans.
- Publish flow: same Studio editor; the practitioner picks the Class as the Plan's parent instead of a Client. A Class can accumulate Plans over time — there's no "publish the whole Class" moment, just per-Plan adds.
- **Monetization at MVP = once-off purchase only** (`class_purchases`). Subscriptions are PR sequence step 12, post-MVP. **Credits don't apply** to classes — practitioners are paid per consumer-side purchase, not per Plan published.
- **Channel:** purchases happen on `manage.homefit.studio` (web portal), same Reader-App compliance pattern as today's credit purchases. No iOS IAP — avoids Apple's 15-30%.
- Consumer side: a Class shows up in My Workouts as a single parent card (resolves OQ-11). Tap drills into a new Class-detail screen listing the Plans inside.
- Note: the email-magic-link bridge in section 1 stays Client-only. Class access is grant-on-purchase (no invitation token needed); the consumer signs in, pays on the portal, and the Class appears in My Workouts.

### 6. Privacy + POPIA implications

- **Claim model is POPIA-friendly:** once a plan is imported, the public URL stops working for everyone else. No accidental cross-sharing of someone else's plan.
- Consumer data minimisation: capture email + display name only. Opt-ins for analytics already covered by the existing `analytics_allowed` consent key per client.
- Need to update `web-portal/src/app/privacy/page.tsx` to cover consumer-side data flows and the email-magic-link import path.
- Terms of service update: consumer-side terms (acceptable use, what happens if they delete the app, etc.).

### 7. iOS Universal Links setup

- Add `Associated Domains` entitlement in `app/ios/Runner/Runner.entitlements` for `applinks:session.homefit.studio`.
- Serve `apple-app-site-association` from `session.homefit.studio/.well-known/apple-app-site-association` (no extension, `Content-Type: application/json`). Declare `studio.homefit.app` paths: `["/i/*"]` (only invite URLs trigger the app; `/p/*` public-link URLs stay in browser).
- Test with a TestFlight build before broad rollout — Universal Links are notoriously fiddly to debug.

### 8. The "Add a workout" power-user import (post-MVP)

Once the email-magic-link path is live, add a Settings or in-Workouts entry point: paste a `session.homefit.studio/p/{uuid}` URL → app calls `claim_plan` directly (no email step). For users who got a public link and decide to import it. Lower priority than the email path because it's the rare case.

---

## Open questions

Still need to resolve before the relevant PRs land:

- **OQ-1** — Should the "Send via email" path in Studio (section 4) compose via Resend with `noreply@homefit.studio` as the From, OR open the iOS Mail compose sheet pre-filled (sends from the practitioner's own account)? Recommendation: Resend-based (controlled branding, deliverability, accept-tracking), but iOS-Mail-based is more personal for the 1-on-1 case. Could support both.
- **OQ-2** — Consumer-side practice context: a consumer with a practitioner who's a member of multiple practices — does the plan say "from Dr. Sarah · Carl's Practice" or just "from Dr. Sarah"? Mockup currently uses both.
- **OQ-3** — Offline-sync chip on My Workouts: today's `OfflineSyncChip` is wired into the practitioner's `SyncService.pendingOps`. Consumer mode has different sync needs (downloading workouts for offline play). Defer until My Workouts ships; might need a different chip with different copy.
- **OQ-4** — Re-imports: if a consumer deletes the app and re-installs, does their imported plan come back from the cloud? (`plan_invitations.accepted_by_user_id` is durable, so technically yes, once they sign in again.)
- **OQ-5** — Class capacity / cohort scheduling: do we ship classes as "always available" (subscribe = library access) or as scheduled cohorts (start date, end date)? Likely always-available for MVP; cohorts as a later layer.
- **OQ-8** ✓ **Resolved 2026-05-13 — live.** A one-off Class purchase grants ongoing access to all Plans in the Class, including ones added later. Functionally a "lifetime access" with no recurring billing. Simplifies the data model (no `snapshot_plan_ids` jsonb on `class_purchases`) and matches the subscription path. Implication: the practitioner has incentive to keep adding content (retains subscribers, rewards one-off buyers); price one-off purchases to reflect lifetime value vs subscription NPV.
- **OQ-9** — Subscription lapse semantics. **Moot at MVP** — no subscriptions in v1 (decision 2026-05-13: once-off only). Revisit when subscriptions ship. Three plausible answers when we do: (a) hard cut — all Plans become inaccessible; (b) grandfather — Plans they've started stay accessible forever; (c) grace window — N days post-lapse before lockout. Hard-cut is the simplest implementation (falls out of the access check naturally); grandfather requires a `class_plan_consumer_access` audit table.
- **OQ-10** ✓ **Resolved 2026-05-13 — public link suppressed.** `session.homefit.studio/p/{uuid}` will reject anon access for any Plan with `class_id IS NOT NULL`. Class Plans are subscription-or-purchase only; never anonymously playable. Prevents subscribers from forwarding the raw URL to bypass payment.
- **OQ-11** ✓ **Resolved 2026-05-13 — hierarchical Class card.** My Workouts shows a Class as a single parent card. Tap → drill into a new "Class detail" screen that lists the Plans inside. Tap a Plan from there → play it. The teaser mock cards stay as-is for TestFlight v2 (locked / illustrative); the real surface adds the Class card type when Classes ship.
- **OQ-12** ✓ **Resolved 2026-05-13 — by date.** Plans inside a Class are ordered by `plans.created_at` ascending. No `plans.class_position` column needed; no explicit reorder UX. The practitioner controls sequence by the order they add Plans to the Class. Simpler MVP; explicit ordering can be a follow-up if reorder turns out to be valuable.

---

## Proposed PR sequence

Rough order. Each PR is independently mergeable; the shell from PR #315 is the common foundation.

1. **PR #315 (this one)** — front-end shell. Two capsules, locked teasers, web-lobby CTA stub. ✓
2. **PR — Universal Links + apple-app-site-association** — small but load-bearing. Required before any `/i/{token}` URL can route to the app.
3. **PR — `plan_invitations` schema + `claim_plan` RPC + `get_plan_full` gate** — backend foundation. Doesn't require UI; can be validated via SQL + curl.
4. **PR — Resend SMTP import-link template + web-lobby wire-up** — flip the "coming soon" toast into a real submit + email.
5. **PR — Consumer sign-up flow + first-launch intent-inferred routing** — AuthGate variants for the two paths.
6. **PR — My Workouts body** — swap the locked teaser for a real list. Requires the Universal Link path to be working in TestFlight.
7. **PR — In-app player for consumers** — port the web-player engine to native Flutter screens (or wrap in a WebView for v1).
8. **PR — Studio Share → Send via email** — symmetric pipeline from the practitioner side.
9. **PR — Classes schema + Studio Class editor** — Practice mode's Classes capsule gets a real body.
10. **PR — Class once-off purchase (PayFast or web-portal-driven, no IAP)** — the commercial layer, MVP scope. Reader-App compliance demands purchases happen on `manage.homefit.studio`, same channel as today's credit top-ups.
11. **PR — Power-user "Add a workout" paste-link import** — post-MVP fallback path.
12. **(Future phase) — Class subscriptions** — recurring billing alongside one-off purchases. Adds `class_subscriptions` table, dunning/lapse handling (OQ-9 resolution required), grace-window or grandfather policy, prorated upgrades from one-off to subscription. Deferred until once-off has validated the monetization story.

Each step is small enough to design + review + ship without rework on the others. Steps 2-4 unblock the lobby CTA; steps 5-7 unblock My Workouts; steps 8-10 unblock Classes. Step 11 is independent.

---

## Decisions log (chronological)

- **2026-05-13** — Two-capsule layout chosen over three-segment / bottom-tab-bar / PageView. Practice + My Workouts capsules side-by-side; chips below scope row.
- **2026-05-13** — Naming locked: "Clients", "Classes", "My Workouts".
- **2026-05-13** — First-launch routing: intent-inferred (no choose-your-side splash).
- **2026-05-13** — Import bridge: email-magic-link via `plan_invitations` (not clipboard sniff, not manual paste). Unified pipeline for self-service and practitioner-initiated invites.
- **2026-05-13** — TestFlight v2 ships front-end shell only; backend deferred to a sequence of follow-up PRs (this doc).
- **2026-05-13** — Web-player lobby CTA included in TestFlight v2 with a no-op "coming soon" toast on submit.
- **2026-05-13** — Classes will live in a new `classes` table (NOT overloaded on `plans.kind`). Decoupled lifecycles + clean credit model. Resolves OQ-6.
- **2026-05-13** — Class is a *peer of Client*, both owning Plans via nullable FKs on `plans` (`client_id` XOR `class_id`, CHECK-enforced). No new "class session" entity; class Plans use the same `plans` + `exercises` machinery as 1-on-1 Plans. Resolves OQ-7.
- **2026-05-13** — Adopted internal shorthand **CPE** (Client-or-Class · Plan · Exercise) for the three-level workout content model. Engineering / design / code-review usage only — explicitly NOT for user-facing copy or practitioner conversations (collides with Continuing Professional Education in the HPCSA world).
- **2026-05-13** — Flagged: Plan and Class are **two distinct units of sharing** with different access models. Plan-sharing is invitation-token-based (`plan_invitations`); Class-sharing is grant-on-payment. `get_plan_full` will branch on Plan parent.
- **2026-05-13** — OQ-8 resolved **live**: one-off Class purchases grant access to all Plans currently in the Class AND future additions. Functionally "lifetime access"; no `snapshot_plan_ids` column needed on `class_purchases`.
- **2026-05-13** — OQ-10 resolved **public link suppressed**: `/p/{uuid}` rejects anon access for any Plan with `class_id IS NOT NULL`. Class Plans are purchase-only.
- **2026-05-13** — OQ-11 resolved **hierarchical**: My Workouts shows a Class as a single parent card; tap drills into a new Class-detail screen listing the Plans inside.
- **2026-05-13** — OQ-12 resolved **by date**: Plans inside a Class ordered by `plans.created_at` ascending. No `plans.class_position` column. Explicit reorder UX deferred.
- **2026-05-13** — **MVP monetization is once-off only.** No `class_subscriptions` table at v1; subscriptions are a future phase (step 12 in the PR sequence). Once-off-first lets us validate the monetization story before paying for recurring-billing complexity (auth alignment, lapse handling, dunning, prorating, grace windows). OQ-9 becomes moot at MVP; will be reopened when subscriptions ship.
- **2026-05-13** — Class purchases (when implemented) will be **web-portal-driven**, not iOS IAP. Same Reader-App compliance pattern as today's credit purchases (no in-app payment paths; consumer is directed to `manage.homefit.studio`). Avoids Apple's 15-30% IAP fee.

---

## Non-goals

Documented here so we don't accidentally drift back into them:

- A single unified "Library" view that intermixes Clients and My Workouts content. The mental model is two distinct *identities*, not one bucket of stuff.
- A choose-your-side first-run splash. Considered and rejected — friction without value when arrival context already disambiguates.
- A clipboard-sniff deferred deep link. iOS would surface a privacy banner on every cold launch.
- Auto-claiming a public link the moment a signed-in user views it. Considered but rejected — ambiguity around shared-with-spouse cases. The user must explicitly opt in via the email path.
- A "Programs" or "Marketplace" third top-level scope at the same level as the two existing capsules. If a third identity emerges, it gets its own capsule on the row; we don't conflate creator and consumer surfaces.
