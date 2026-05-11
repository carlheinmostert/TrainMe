# BACKLOG — Projects / Class Sales (revenue-share spec)

**Status:** Future feature — NOT MVP. Spec captured 2026-04-23, reconstructed from the session transcript 2026-05-11 (original doc was written into a sub-agent worktree that was cleaned up before commit). Decisions below are authoritative; quotations from the workshop are kept verbatim where they pin a knob.

Recorded so the MVP platform keeps the seams flexible. Nothing here is being built — it exists so future Carl and future Claude don't have to re-workshop the model. The MVP is already shaped well enough that this is purely additive when the time comes.

---

## §1 — Problem statement

Practitioners want to sell pre-made class bundles to many people, not just hand custom plans to one named client. The buyer journey must work **without a client app** — the practitioner shares a link into their own channels (WhatsApp, Instagram, email, whatever) and the buyer consumes on the web. There is **no platform shopfront** at launch. Discovery is the practitioner's job; we provide the rails.

Carl's framing (turn 19):

> "The idea is that the project will be sold by clicking on a Project retail link which would then facilitate the money transfer to homefit.studio. The practitioner using this publish function would get a percentage of the advertised price. We need to talk about how we protect from abuse as the main requirement is still that no client app is required (but could be delivered)."

---

## §2 — Conceptual shift from today's model

Today's model: **practitioner pays platform, plan is given free to a named client.**

Projects inverts it: **consumer pays platform, platform pays practitioner a share, plan is consumed by an anonymous buyer who bought access.**

That single inversion ripples through tenancy (no client_id), consent (no per-buyer consent object), the billing ledger (two ledgers, never one), the publish flow (credits still charged for cost-of-goods + a revenue ledger row at sale time), and the web player auth story (token-gated, not URL-gated).

---

## §3 — Domain model

Three distinct objects on the practitioner side. The mental model is clean: *Plans for clients, Projects for sales.*

### Plan (existing — unchanged)
Today's object. Ad-hoc, per-client, single-use. `plans` table, `client_id` FK. Credit consumed at publish. Nothing changes.

### Class (new)
The reusable workout unit inside a Project. **Same internal shape as a Plan** (circuits, exercises, rests, three-treatment, hold position, video reps per loop, etc.) but **practice-owned, not client-owned**. A Class has no `client_id`.

Plan and Class have identical internal structure but live in separate tables — same helper code reused, no shared parent table abstraction. Carl on this (turn 39, our framing he agreed with): *"Two tables keeps intent clear. Shared helper code for the internal structure — but no shared parent table. No abstraction-for-the-sake-of."*

### Project (new)
The retail product. Practice-owned (not practitioner-owned — see §19 for why). Contains N Classes (by reference, by copy, or mixed — see §4). Has:

- Title, narrative description, cover image
- Price (cents + currency)
- Status: `Draft` / `Live` / `Archived`
- One Class flagged as `is_free_preview` (optional, see §18)

A buyer doesn't "buy a plan" or "buy a session" — they **buy a Project, which unlocks its Classes**.

---

## §4 — Sharing model: shared-read with entitlement check

**Decision (turn 25, locked):** Updates ripple to existing buyers. Shared-read, no copy-on-purchase.

> Carl: "Any updates to the course must ripple to the existing clients. so no copy. similar to current."

Cheaper to host (one set of media files per Project), and the rippling is the value prop: "ongoing quality updates land for everyone who already bought." This is what digital courses do well.

Implication: buyer access is gated by an **entitlement check at read time**, not by owning copies of the assets.

Classes themselves can be **added to multiple Projects by reference OR copied in** (turn 29). The two semantics:
- **Reference**: insert a row in `project_classes` pointing at the existing Class. Updates to that Class ripple into every Project that references it.
- **Copy**: duplicate the Class row, then reference the copy. Updates stay local to that Project.

Practitioner picks at insertion time. Both supported.

---

## §5 — Editing live Projects

Three sub-cases, each with a clean answer (turn 31):

1. **Non-structural edit** (fix reps, rename an exercise, re-shoot a video): **free**, ripples instantly. Same as today's version-bump-for-free rule.
2. **Add a new Class to a live Project**: **costs credits at publish** (hosting cost scales linearly). Buyers automatically gain access to the new Class.
3. **Delete a Class from a live Project**: **blocked**. A buyer paid for N Classes; we cannot remove what they paid for. Archive-don't-delete, or an explicit "expire this Class in 30 days" flow when we really need it.

Free hand on polish, metered hand on expansion, guardrail on shrinkage.

---

## §6 — Buyer journey (end-to-end)

**Decision (turn 51, locked):** Same URL for retail and delivery. Auth state decides which mode renders.

> Carl: "I want the same url. If not bought the project presents a sales pitch. If you log in the project goes into delivery mode. the practinioner will have shared branding so I think this is fine."

The ribbon:

1. Practitioner shares the retail URL: `session.homefit.studio/r/{project_slug}` (or equivalent — same shape as today's referral landing URL).
2. **Logged-out visit** → retail surface: title, narrative, cover, Class list with thumbnails, price, buy button, optional free-preview Class playable inline.
3. Buyer clicks **Buy** → enters email → PayFast checkout → pays.
4. PayFast ITN webhook → platform mints a **per-buyer access token** → emails magic link to that email.
5. Buyer clicks the magic link → long-lived browser session cookie established.
6. **Logged-in visit to the same URL** → renders in **delivery mode**: Class selector with per-Class progress chips ("Class 1 · Foundations", "Class 2 · Progression", …).
7. Tap a Class → today's web-player experience, treatment-gated by the buyer's purchase (not by `video_consent` — that's a different gate).

---

## §7 — Consumer auth

**Decision (turns 29 + 31):** Magic-link at purchase. Long-lived browser session cookie. New device = fresh magic link to the buyer's email.

Cheap friction on casual WhatsApp-forwarding (someone receiving the URL second-hand has to ask the original buyer for the magic link, which lands in the buyer's inbox — annoying enough to deter casual sharing without breaking the real buyer's experience).

No "full account" at launch. The buyer doesn't sign up; they just enter their email at the paywall and receive magic links forever after to that address. If we later want to give them a portal listing every Project they've bought, that's an additive feature on top of the per-Project tokens already in place.

---

## §8 — Progress tracking

**Decision (turn 51):** Server-side per buyer token.

> Carl: "If we are send magic link and making them sign in, then we should remember their progress."

Schema: `project_progress(token, class_id, last_position_seconds, completed_at, PK(token, class_id))`.

Survives device switches. Powers progress chips on the delivery view. Unlocks the analytics loop ("87% drop at Class 4 → practitioner should fix it") later.

---

## §9 — Consent model

**Decision (turn 25):** No consent object on Projects.

> Carl: "There is no consent requirement as the assumption is that the project is created by consenting adults."

Assumption: the practitioner films themselves or works with a consenting model. Project content is sellable retail material, fundamentally different from a one-off plan recorded with a named client. The per-client `video_consent` jsonb on `clients` stays exactly as-is for the Plan flow and is not relevant on the Project flow.

---

## §10 — Credit model: practitioner still pays at publish

**Decision (turn 25, locked):** Practitioner still pays credits at publish — cost-of-goods for hosting + conversion. Revenue share is topline.

> Carl: "I am thinking the actual publishing of a project should cost some credits as to cover at least the hosting cost."

Two separate ledgers, never share the shape with `credit_ledger`. The existing `credit_ledger` keeps its current shape; the revenue side is a separate `project_sales_ledger`.

**Credits-on-publish formula** (turn 31): reuse today's per-Class formula, summed across the Project: `credits = sum(ceil(non_rest_count / 8) clamped [1,3])`. A 4-Class Project with 10 exercises each = 4×2 = 8 credits at publish. Adding a 5th Class later = +2 credits.

---

## §11 — Revenue share

**Decision (turn 29):** 70% practitioner / 30% platform. Configurable per practice.

> Carl: "70 for practitioner 30 for platform — configurable per practice from our side."

Mechanics:

- New column on `practices`: `project_revenue_share_pct numeric(5,4) default 0.7000`.
- Owner-only admin tooling to adjust per practice.
- **Split is FROZEN at purchase time** into the `project_purchases` row (`revenue_share_pct_snapshot` column). Rate changes only affect future sales. A buyer who paid R500 at the 70/30 split locks in a R350 practitioner cut forever, regardless of later rate edits.

---

## §12 — PayFast mechanics (single-merchant model)

**Decision (turn 39, locked):** All money lands in homefit's PayFast account. Platform disburses practitioner share on a monthly payout cycle.

The three patterns considered (turn 39):

1. PayFast Split Payments — requires every practitioner to have their own PayFast merchant account with full FICA. Too much onboarding friction. Rejected.
2. **Single merchant + platform payouts** ← chosen.
3. Stripe Connect — beautiful but Stripe for SA is limited. Future option (see §15 Tier 2).

Per-sale flow:

1. Buyer pays full price via PayFast.
2. Funds land in homefit's PayFast account.
3. ITN webhook fires → write to `project_sales_ledger`:
   - `gross_cents`, `platform_cut_cents`, `practitioner_cut_cents`, `revenue_share_pct_snapshot`, `hold_until = purchase + 14 days`, `status = pending`.
4. Row sits `pending` during the refund window.

Refund handling (turn 43):

> Carl: "Whichever covers me the most, 14 days?"

Refund window = **14 days OR first-Class-viewed, whichever first**. Both apply, whichever closes the window first wins.

- Refund before `hold_until` and before any Class viewed → platform refunds full amount. Ledger row marked refunded. Nothing owed to practitioner.
- Past `hold_until` → row moves to `settled`. Refunds past `hold_until` become clawbacks against the next payout (rare; punt to later).
- **Partial refunds: punt.** Full refund or nothing at launch.

Payout cycle:

- **Monthly.** Aggregate all `settled` rows per practitioner where `hold_until < now`.
- EFT via PayFast Batch Payouts or manual EFT from business account, depending on volume.
- Write a `practitioner_payouts` row. Mark source ledger rows as `paid`.
- **Payout minimum threshold** (~R250). Below threshold rolls to next cycle.
- **No banking details at sale time** → sale completes anyway. Ledger flagged `awaiting_payout_details`. Funds hold indefinitely until resolved. No lost money.

---

## §13 — Accounting (gross vs net)

**Decision (turn 43, locked):** Gross accounting.

> Carl: "Gross if fine."

Standard marketplace treatment (Takealot, Uber Eats):

- Platform revenue = 100% of sales.
- Practitioner payout = commission expense.

The ledger shape we settle on must preserve the option to switch to net accounting later if our accountant ever asks — just a reporting layer change, no data shape rewrite.

---

## §14 — Regulatory / NPS Act note

Collecting money on behalf of practitioners in SA brushes against the **National Payment System Act**. Most marketplaces operate under the "commercial agent" exemption — homefit acts as agent collecting for the practitioner under an explicit agreement.

> Carl-Claude exchange (turn 39): "You should get a one-time legal opinion on it before scaling, but it's not a launch blocker. The agreement between homefit and each practitioner ('you appoint us as your agent to collect payments on your behalf') does the legal work."

Action: bake the agency clause into the practitioner terms of service the first time we sell anything. One-time legal opinion before scaling. Not a launch blocker.

---

## §15 — VAT (three-tier path)

**Tier 1 (launch — SA only).** SA-VAT applies per practitioner's own registration status. Most sole-practitioner biokineticists are under the R1M annual threshold and do not charge VAT. Platform shows VAT if applicable and passes through. Simple, legal.

**Tier 2 (growth — international).** Open to rest-of-world via a Merchant of Record service: Paddle, Lemon Squeezy, or Stripe Tax. MOR handles VAT globally and takes ~5–8%. Eaten out of the platform cut on foreign sales, or practitioner takes a slightly lower international split.

**Tier 3 (scale — own MOR).** Becoming our own MOR. Requires real tax counsel and meaningful volume to justify.

> Carl-Claude recommendation (turn 31): "Launch Tier 1. Document Tier 2 as the next step. Don't build Tier 3."

---

## §16 — Abuse mitigations

The "no app required" requirement is load-bearing, which kills device-binding as a defence. Layered approach:

- **Per-buyer unique token** in the URL — never the `project_id`.
- **Session-scoped signed URLs**, short TTL, regenerated per view.
- **View-rate anomaly detection** — e.g. >80 plays/hr from 5+ IPs auto-pauses the token and notifies the practitioner. Thresholds TBD (see §25).
- **Watermark overlay** — buyer's email faint-corner on the video element, CSS-only.
- **Magic-link re-verify on new device / IP.**
- **TOS + account termination clause** for commercial deterrence.

Stance (turn 21, agreed): *"Make casual WhatsApp-forwarding annoying, not unbreakable DRM."* Determined pirates will pirate. The goal is to collapse the casual sharing vector, not build perfect DRM.

---

## §17 — Lifecycle states

**Decision (turn 51):** Draft / Live / Archived. No separate "preview link" state.

- **Draft** → practitioner-only visible. Serves as the practitioner's own preview (they can hit their own retail URL and see it). No public access.
- **Live** → retail URL works. Sales accepted. Existing buyers consume.
- **Archived** → existing buyers retain access. Retail URL returns **410 Gone**. Practitioner cannot remove a sold Project; can only stop new sales.

Preview via the practitioner's own account. Separate preview-link tokens add a state without obvious benefit.

---

## §18 — Free-preview Class (conversion lever)

**Decision (turn 51, yes):** Practitioner can flag one Class per Project as free-preview.

Schema: `project_classes.is_free_preview boolean default false` with a **one-per-project** uniqueness constraint (partial unique index where `is_free_preview = true`).

Retail page can gate-free or auto-play that Class before the paywall. Major conversion lever — it's how every digital course platform drives purchases ("try before you buy").

---

## §19 — Practice departure handling

**Decision (turn 31):** Project is **practice-owned**, not practitioner-owned.

A practitioner who leaves the practice does not take the Project with them. The practice continues to earn from existing sales. How the practice owner splits with the departed practitioner is the practice's problem under the practice's own employment / partnership agreement, not the platform's.

Simpler than tracking per-practitioner ownership. Aligns with how `plans` already work (`plans.practice_id`, no `plans.trainer_id` ownership concept beyond the audit log `trainer_id`).

---

## §20 — Data model (additive — no MVP changes required)

**Structural assessment (turn 73):** the MVP discipline already in place gives Projects the bones it needs. Multi-tenant practices, RLS via `user_practice_ids()`, RPC-write-only ledgers, `{practice_id}/...` storage path prefix, single-enumerated-surface rule in `docs/DATA_ACCESS_LAYER.md` — everything Projects needs is additive. No migrations, no RLS rewrites, no contract breaks.

### 9 new tables

```sql
-- The retail product
create table projects (
  id            uuid primary key default gen_random_uuid(),
  practice_id   uuid not null references practices(id),
  title         text not null,
  slug          text not null unique,
  description   text,
  cover_url     text,
  price_cents   integer not null,
  currency      text not null default 'ZAR',
  status        text not null default 'draft' check (status in ('draft','live','archived')),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  archived_at   timestamptz
);

-- Reusable workout unit (analogous to `plans` minus client_id)
create table classes (
  id            uuid primary key default gen_random_uuid(),
  practice_id   uuid not null references practices(id),
  title         text not null,
  body          text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- Exercises inside a Class.
-- OPEN QUESTION (see §25): new table `class_exercises` OR extend `exercises`
-- with a nullable `class_id` alongside `plan_id`. Pick at Phase 1 schema design.
create table class_exercises (
  -- mirror of exercises shape, FK to classes
  ...
);

-- Composition: Project ↔ Class join, with position and free-preview flag
create table project_classes (
  project_id      uuid not null references projects(id) on delete cascade,
  class_id        uuid not null references classes(id),
  position        integer not null,
  is_free_preview boolean not null default false,
  primary key (project_id, class_id)
);
create unique index project_classes_one_free_preview
  on project_classes(project_id) where is_free_preview;

-- A buyer paid for a Project (one row per purchase event)
create table project_purchases (
  id                          uuid primary key default gen_random_uuid(),
  project_id                  uuid not null references projects(id),
  buyer_email                 text not null,
  gross_cents                 integer not null,
  platform_cut_cents          integer not null,
  practitioner_cut_cents      integer not null,
  revenue_share_pct_snapshot  numeric(5,4) not null,
  hold_until                  timestamptz not null,
  status                      text not null
                              check (status in ('pending','settled','refunded','awaiting_payout_details')),
  paid_at                     timestamptz,
  refunded_at                 timestamptz,
  payfast_pf_payment_id       text
);

-- Per-buyer access token (this is what the URL carries — never project_id)
create table project_buyer_tokens (
  token        text primary key,
  project_id   uuid not null references projects(id),
  buyer_email  text not null,
  created_at   timestamptz not null default now(),
  last_seen_at timestamptz,
  revoked_at   timestamptz
);

-- Per-buyer per-Class progress
create table project_progress (
  token                  text not null references project_buyer_tokens(token) on delete cascade,
  class_id               uuid not null references classes(id),
  last_position_seconds  integer not null default 0,
  completed_at           timestamptz,
  primary key (token, class_id)
);

-- Append-only sales ledger (the accounting source of truth)
create table project_sales_ledger (
  id                     uuid primary key default gen_random_uuid(),
  project_id             uuid not null references projects(id),
  purchase_id            uuid not null references project_purchases(id),
  kind                   text not null check (kind in ('sale','refund','clawback')),
  gross_cents            integer not null,
  platform_cut_cents     integer not null,
  practitioner_cut_cents integer not null,
  currency               text not null,
  recorded_at            timestamptz not null default now()
);

-- Aggregated monthly payouts (one row per practitioner per period)
create table practitioner_payouts (
  id              uuid primary key default gen_random_uuid(),
  practitioner_id uuid not null references auth.users(id),
  practice_id     uuid not null references practices(id),
  period_start    date not null,
  period_end      date not null,
  gross_cents     integer not null,
  paid_at         timestamptz,
  batch_ref       text
);

-- Banking details for payouts (encrypted at rest)
create table practitioner_bank_details (
  practitioner_id          uuid primary key references auth.users(id),
  account_holder           text not null,
  account_number_encrypted text not null,
  branch_code              text not null,
  bank_name                text not null,
  fica_meta                jsonb,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now()
);
```

### 1 new column on `practices`

```sql
alter table practices
  add column project_revenue_share_pct numeric(5,4) not null default 0.7000;
```

### 2 new nullable columns on `credit_ledger`

```sql
alter table credit_ledger
  add column project_id uuid references projects(id),
  add column class_id   uuid references classes(id);
```

So a `kind = consumption` row written at Project publish time can attribute the consumed credits to the Project (and optionally to the specific Class added in an incremental publish).

### RLS

Every new table scoped by `user_practice_ids()` for practice-owned reads / writes, except:

- `project_buyer_tokens`, `project_progress` — anon SELECT/UPSERT gated by token presented as a function argument (never by direct table read).
- `project_sales_ledger`, `project_purchases`, `practitioner_payouts`, `practitioner_bank_details` — practice-scoped read (SELECT via `user_practice_ids()`), but **all writes via SECURITY DEFINER RPCs only**. Same lockdown pattern as `credit_ledger` (PR #3 / Milestone E).

### No migrations, no RLS rewrites, no contract breaks to existing tables.

---

## §21 — Storage path convention

Media consumed by many buyers lives under the **Project**, not the Plan. The existing Plan path stays unchanged.

```
media        bucket: {practice_id}/projects/{project_id}/{exercise_id}.{ext}
raw-archive  bucket: {practice_id}/projects/{project_id}/{exercise_id}.mp4
```

Cheap to decide now, expensive to migrate later. Both `media` (line-drawing) and `raw-archive` (raw colour) buckets use this prefix shape. The `can_write_to_raw_archive(path)` helper that parses the first path segment as `practice_id` already supports this without modification.

---

## §22 — Single-enumerated-surface conformance

Every new RPC follows the anon-shape `(token, resource_id)` pattern set by today's `get_plan_full(plan_id)`. From the workshop (turn 21): *"Any new anon RPCs added in MVP should pass `(token, resource_id)`, not just `(resource_id)`. Sets the pattern."*

**Hard rule reaffirmed by Carl (turn 77):** No direct DB access. All reads and writes go through the per-surface access layer (`app/lib/services/api_client.dart`, `web-portal/src/lib/supabase/api.ts`, `web-player/api.js`) into SECURITY DEFINER RPCs. Already in `docs/DATA_ACCESS_LAYER.md`. Recorded as binding in memory.

### Anon surfaces (web player)

- `get_project_retail(slug)` — returns retail page payload (Project + Class list + free-preview signed URLs if applicable). No token required; safe to cache by slug.
- `get_project_session(token, class_id)` — validates the token, records `last_seen_at`, logs view, returns signed URLs for the requested Class.
- `record_project_progress(token, class_id, last_position_seconds, completed boolean)` — append-or-update into `project_progress`.

### Authenticated / practitioner-facing surfaces (mobile + portal)

All SECURITY DEFINER with practice-membership checks via `user_practice_ids()`:

- `upsert_project(project_payload jsonb)` — Draft state.
- `upsert_class(class_payload jsonb)` — reuse plan-editor patterns, practice-scoped.
- `add_class_to_project(project_id, class_id, position, copy boolean)` — `copy=true` duplicates the Class first.
- `remove_class_from_project(project_id, class_id)` — Draft state only.
- `publish_project(project_id)` — atomic: consumes credits via existing `consume_credit` pattern (now with `project_id` attribution), flips status to `live`, writes a `plan_issuances`-style audit row.
- `archive_project(project_id)`.
- `set_class_free_preview(project_id, class_id, is_free_preview)`.
- `set_practitioner_bank_details(payload jsonb)`.
- `request_payout_for_period(period_start, period_end)` — owner-only.

### Service-role surfaces (PayFast webhook)

- `mint_project_buyer_token(project_id, buyer_email)` — generates an opaque token, inserts into `project_buyer_tokens`.
- `record_project_purchase(payfast_payload jsonb)` — atomic insert into `project_purchases` + `project_sales_ledger`. Same pattern as today's `record_purchase_with_rebates`.

---

## §23 — 7-phase rollout plan

When Projects becomes active work, suggested ordering:

1. **Phase 1 — Schema + RLS lockdown.** Apply the additive migration. Stub the RPCs (return-empty / throw). No UI. Lock the open question on `class_exercises` vs `exercises.class_id` here.
2. **Phase 2 — Class authoring.** Reuse plan editor patterns. Practice-scoped Class library. No Project surface yet.
3. **Phase 3 — Project authoring + composition.** Mobile + portal surfaces for Draft Projects. `project_classes` join. Reference-vs-copy semantics on insert.
4. **Phase 4 — Retail page + buyer journey.** `/r/{slug}` rendered server-side. Magic-link issuance + long-lived browser cookie auth. Free-preview gating.
5. **Phase 5 — Player delivery + progress.** Same URL, auth-state-aware. Server-side per-token progress, progress chips on the delivery view.
6. **Phase 6 — PayFast integration + payout pipeline.** Single-merchant flow. ITN webhook → `record_project_purchase`. Monthly payout aggregation. Practitioner bank details surface. Practice revenue-share admin.
7. **Phase 7 — Polish.** View-rate anomaly detection. Watermark overlay. Retention / archive flow. Analytics dashboards (drop-off per Class, conversion-from-free-preview, etc.).

---

## §24 — Decision log

The 18 decisions locked in the 2026-04-23 session, one line each:

1. Shared-read, no copy on purchase. Updates ripple to existing buyers.
2. No consent object on Projects (consenting-adults assumption).
3. Practitioner still pays credits at publish (cost-of-goods for hosting).
4. `plans.client_id` not overloaded — Projects are their own entities.
5. One-time purchase at launch; subscriptions later if the model expands to add Classes over time.
6. Self-paced (no scheduled-release locking).
7. Quality updates ripple to existing buyers; new Classes cost new credits.
8. 70/30 default split, configurable per practice, frozen at purchase time.
9. Magic-link auth for buyers (no full account at launch).
10. Classes can be referenced OR copied across Projects (different semantics, both supported).
11. Refund window: 14 days OR first-Class-viewed, whichever first.
12. VAT: SA Tier 1 at launch; MOR Tier 2 future; never become own MOR.
13. Gross accounting for SARS.
14. Same URL for retail + delivery (auth state determines mode).
15. Server-side progress tracking per buyer token.
16. Free-preview Class supported (one per Project).
17. Project is practice-owned (departed practitioner doesn't take it).
18. Draft / Live / Archived states; no separate preview-link state.

---

## §25 — Open questions

Carried forward; pick at the Phase that touches each:

- **VAT rate display logic** on the retail page when the practitioner is VAT-registered. Tier 1 path is "pass through if applicable" — exact wording + UI placement TBD at Phase 4.
- **Buyer email change** — can a buyer move their access to a new email address (re-magic-link to a new address)? Lean yes for support reasons; verify cleanly at the auth layer.
- **View-rate anomaly thresholds.** Carl's 80-plays-per-hour-from-5+-IPs was illustrative, not load-bearing. Pick real thresholds at Phase 7 against actual usage data.
- **`class_exercises` vs `exercises.class_id`.** Whether Classes get their own exercises table (mirrors `exercises`) or whether `exercises` grows a nullable `class_id` alongside `plan_id`. Both work; both have trade-offs. **Pick at Phase 1 schema design.** The mirror table keeps the two paths isolated and lets each evolve; the column-on-`exercises` route lets us reuse all existing exercise infrastructure with zero forks. Lean toward the column-add route, but defer.
- **International payment rails** — Stripe, Paddle, or Lemon Squeezy when Tier 2 arrives. Decide at the Phase 6 international-expansion follow-up.
- **Cover-image upload pipeline.** Probably reuse the line-drawing storage approach (private bucket → signed URL) but for still images. Same `{practice_id}/projects/{project_id}/cover.{ext}` shape. Decide at Phase 3.

---

## Soft hedge while MVP work continues

The MVP doesn't need to change anything to accommodate Projects. The one thing to protect is the **single-enumerated-surface discipline** — every time a screen is tempted to call Supabase directly instead of going through `ApiClient` / `api.ts` / `web-player/api.js`, Projects work gets harder later. Already a binding rule (`docs/DATA_ACCESS_LAYER.md`, plus the no-direct-DB-access rule Carl locked in turn 77). Its value compounds the closer we get to building this.
