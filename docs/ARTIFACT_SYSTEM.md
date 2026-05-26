# Artifact system — design doc

**Status:** living design doc · authored 2026-05-26 from the grilling session that resolved the artifact-model decision blocks · **extends** [ADR 0022](./adr/0022-plan-artifacts-abstraction-before-reel.md) (which shipped the `plan_artifacts` skeleton for one kind) into the full distribution + billing spine.

**Owners:** Carl + Claude

**Related artifacts:**
- ADRs: [0007](./adr/0007-credit-billing-model.md) (credit model), [0016](./adr/0016-fourteen-day-structural-edit-grace.md) (edit-lock grace), [0022](./adr/0022-plan-artifacts-abstraction-before-reel.md) (`plan_artifacts` table)
- Predecessor seams: [`SELF_TRAINER_WAVE.md`](./SELF_TRAINER_WAVE.md) — `plan_invitations`, the "My Workouts" tab, and the universal `Publish` verb all land there and this design builds on them rather than forking.
- Proposed new ADRs to ratify (see [ADRs to ratify](#adrs-to-ratify)): artifacts-as-live-renderings, plan-level-lock-paid-only, per-artifact-pricing-with-free-floor.

## Table of Contents

- [North star](#north-star)
- [Locked decisions](#locked-decisions)
- [The model in one paragraph](#the-model-in-one-paragraph)
- [The publish=enablement / always-live reconciliation](#the-publishenablement--always-live-reconciliation)
- [Pipeline: Preview / Publish / Share](#pipeline-preview--publish--share)
- [Billing](#billing)
- [Edit-lock semantics](#edit-lock-semantics)
- [Consent & POPIA](#consent--popia)
- [Claiming & My Workouts](#claiming--my-workouts)
- [Analytics](#analytics)
- [Artifact-type roadmap](#artifact-type-roadmap)
- [Schema deltas (proposed)](#schema-deltas-proposed)
- [RPC surface (proposed)](#rpc-surface-proposed)
- [Open questions](#open-questions)
- [Non-goals](#non-goals)
- [ADRs to ratify](#adrs-to-ratify)
- [Decision log](#decision-log)

---

## North star

A published plan is no longer synonymous with "the Plan URL." A plan is a **single source of truth** — its exercises, sets, consent and versioning — that can be **rendered into many artifacts**: format-specific, independently-priced, independently-shared, *live* outputs. The interactive web player is simply the first artifact. A PDF handout, a stitched video reel, a one-page printable poster, a calendar export, and a premium AI style-transfer reel are its siblings.

This is the evolution ADR 0022 anticipated: it shipped `plan_artifacts` as a one-row audit shadow (`kind='plan_url'`, computed URL, written inside the publish transaction) precisely so the second artifact kind wouldn't fork the publish flow. This document turns that table into the actual **distribution and billing spine** of the product.

The strategic shape: a practitioner can deliver real value for **free** (the PDF page is a deliberate loss-leader / funnel), and the product monetizes when they reach for the richer formats — the interactive player and, later, the premium reels.

---

## Locked decisions

Resolved in the grilling session. Each is detailed below and captured in the [Decision log](#decision-log).

1. **One plan = one source of truth.** Artifacts are format-specific *live renderings*; no plan content is ever copied into an artifact record.
2. **`plan_artifacts` is the thin per-type record** — singleton per `(plan_id, kind)`. It carries publish state, price paid, share/claim handles, and render metadata. Never content.
3. **Every supported type is always offered** (render-on-demand). The type registry is global — adding a kind lights it up for every existing plan automatically.
4. **Pricing is per-type, with an intentional free floor.** PDF (and poster / calendar) free; player paid; reel / AI-reel premium.
5. **Publish is a multi-select gate.** Preview is a single-artifact lens; Publish lets you choose *which* artifacts to mint (nothing pre-checked); Share acts on one artifact's URL/claim.
6. **Publish = a one-time enablement event per artifact.** Thereafter the artifact is live forever and tracks the latest plan content — no re-publish needed for edits to flow.
7. **Freshness lives client-side.** Enabled artifacts are live pages; the recipient "freezes" a copy only by hitting Download (e.g. a PDF/reel file). We never store frozen snapshots server-side.
8. **Edit-lock is plan-level and paid-only.** It gates structural editing of the shared content; it engages only once a *paid* artifact has been published. Free-only plans never lock.
9. **Consent applies to every artifact.** The PDF honors line / B&W / original exactly like the player; line-drawing always available, B&W/original consent-gated.
10. **Analytics is per-artifact** — Wave 17 generalized with an artifact dimension.
11. **Recipients claim into "My Workouts"** via *both* a web client account (`session.homefit.studio`) and the app inbox; *both* claim mechanisms (anonymous link + email push) are supported.
12. **Roadmap types to accommodate:** stitched video reel, one-page poster, calendar/reminders export, AI style-transfer reel (beyond player + PDF).

---

## The model in one paragraph

The `plans` row and its `exercises` remain exactly as today — one mutable, version-bumped source of truth. `plan_artifacts` holds **at most one row per `(plan_id, kind)`**, where `kind` ∈ {`plan_url`, `pdf`, `poster`, `reel`, `ai_reel`, `calendar`}. A row's mere existence-with-`published_at` means "this artifact is enabled at a public URL and has been paid for (if paid)." The artifact's *content* is never stored on that row — it is **rendered on demand** from the live plan (a computed page for `plan_url`/`pdf`/`poster`, a materialised file in a bucket for `reel`/`ai_reel`, an ICS stream for `calendar`). Editing the plan updates every enabled artifact instantly. Money attaches at the artifact level (per-kind price, charged once at publish); the **content edit-lock** attaches at the plan level (one shared body of exercises, so one lock).

---

## The publish=enablement / always-live reconciliation

"Publish per artifact" and "artifacts are always live" *look* like they fight. They don't, once you separate two axes:

- **Enablement** is a one-time, per-artifact event. Publishing the player mints its URL and charges its price *once*. Publishing the PDF mints its page *once* (free). After that the artifact exists.
- **Freshness** is continuous and shared. Every *enabled* artifact is a live rendering of the latest plan. A structural or non-structural edit to the plan flows to all enabled artifacts with no re-publish and no re-charge.

So you never "re-publish to push an edit." You publish a kind once to bring it into existence; thereafter it tracks the plan. This is what makes per-artifact content snapshots unnecessary (and is why we explicitly rejected them — see [Non-goals](#non-goals)). The only place a frozen copy exists is in the *recipient's* hands, via Download (D7).

---

## Pipeline: Preview / Publish / Share

The existing **Camera → Preview → Publish → Share** workflow pill stays, but Preview/Publish/Share become artifact-aware:

- **Preview — single-artifact lens.** The practitioner picks an artifact type and previews *that* rendering. All supported types are always listed (D3); render-on-demand means even un-published types preview live.
- **Publish — multi-select gate.** A selection sheet lists every artifact type with its per-kind price. **Nothing is pre-checked** (D5 / explicit choice every publish — never charge by surprise). The practitioner ticks the kinds to mint; the sheet shows the running credit total; confirm charges the sum and mints/updates the `plan_artifacts` rows in one transaction (alongside the existing `plan_issuances` audit row). Already-enabled kinds shown as such (re-ticking is a no-op, not a re-charge).
- **Share — per-artifact.** Each enabled artifact has its own shareable handle (URL for computed/materialised kinds; ICS subscription link for calendar). Sharing is per-artifact; sharing several means sharing each link (a "share all" convenience is a UX detail, not load-bearing).

---

## Billing

- **Per-type price is a policy function**, not a flat number:
  - `pdf`, `poster`, `calendar` → **free** (0 credits). Deliberate funnel (D4). Note: a free artifact still incurs render/storage/egress cost we absorb — accepted as the funnel's cost of doing business.
  - `plan_url` (player) → the **existing duration-based price**: 1 credit ≤ 75 min estimated, 2 credits > 75 min (ADR 0007 unchanged).
  - `reel`, `ai_reel` → **premium, price TBD** (see [Open questions](#open-questions)).
- **Charge fires once per artifact at publish.** The publish RPC sums the selected paid kinds and consumes credits atomically via the existing `consume_credit` path.
- **Failure / refund.** Materialised kinds (`reel`, `ai_reel`, `pdf` if cached) can fail *after* the charge (transcode error). Reuse the existing compensating-refund-ledger pattern from the publish flow: charge on accept, refund row if the render terminally fails. Computed kinds (`plan_url`) can't fail this way.
- **"Plan becomes paid"** = the first time a paid artifact is published (`credits_charged > 0`). This is the trigger that arms the edit-lock — see below.

---

## Edit-lock semantics

The edit-lock (ADR 0016) is an **anti-abuse rule on the credit model**, not a freshness or format concept. It exists so a practitioner can't publish one plan for one credit and then quietly rewrite it into many different plans forever. It gates **structural edits** (add/delete/reorder); non-structural edits (reps, sets, hold, notes, filter params) are free forever.

In the artifact world it stays **plan-level** (D8), because all artifacts render the *same* shared exercises — "lock the PDF but not the player" is incoherent when there's one body of content underneath both. Concretely:

- The lock gates editing of the **plan's** content. The grace clock starts at the **first open of any enabled artifact** (`plans.first_opened_at`, redefined as artifact-agnostic). After 14 days, structural edits lock; a plan-level 1-credit prepay (`unlock_plan_for_edit`, unchanged) buys the next structural republish.
- **Only paid plans ever lock** (D8). If a plan has only ever published *free* artifacts (just the PDF page), no credit was spent, there's nothing to abuse, and the lock machinery never arms. The moment a paid artifact is published, the plan's content becomes credit-backed and the grace/lock logic engages.

This collapses the per-artifact-snapshot complexity entirely: one live version of the content, one lock, conditional on money having changed hands.

---

## Consent & POPIA

Consent treatments (line / B&W / original) apply to **every artifact** (D9), not just the player:

- **Line-drawing is always available** (de-identified by the pipeline; consent can't be withdrawn — see CLAUDE.md).
- **B&W and original are consent-gated** per the client's `video_consent` jsonb, served via the existing `sign_storage_url` signed-URL machinery. An artifact that would surface identifiable frames (an "original" PDF, a colour reel) must respect the same gate the player does.
- The PDF artifact therefore pulls consent + signed URLs into its renderer — it is **not** a line-only static handout. (This was an explicit choice over "PDF is always line-drawing only.")
- **Claimed clients** introduce a new POPIA surface: once a client claims a plan into a web account, do they gain the ability to manage/withdraw their own consent or opt out of analytics? Flagged in [Open questions](#open-questions).

---

## Claiming & My Workouts

**The biggest new build.** Recipients can claim an artifact into a durable **"My Workouts"** surface via **both** delivery mechanisms and **both** recipient surfaces (D11):

- **Mechanisms:** (1) the existing **anonymous link** (unguessable UUID, no auth — unchanged for the casual case); (2) **email push** — the practitioner sends the artifact to a client's email (Resend), and the email carries a claim link.
- **Surfaces:** (1) a **client web account** on `session.homefit.studio` — clients, who have *no* account today, can sign up on the player domain and collect claimed plans in a web "My Workouts"; (2) the **app inbox** — app users (incl. self-trainers) see claimed plans in their existing My Workouts tab.

This builds on the self-trainer wave's `plan_invitations` seam and the My Workouts tab rather than inventing a parallel model. But it opens real identity/consent questions (a brand-new client-facing auth surface; how a claimed client relates to the practice's `clients` row; whether claiming transfers consent ownership). These are scoped as a follow-on sub-wave, not part of the core artifact-model landing — see [Open questions](#open-questions).

---

## Analytics

Per-artifact (D10). Wave 17's analytics (`client_sessions`, `plan_analytics_events`, daily aggregates, opt-outs) gain an **artifact dimension** so PDF-page opens, reel views, and player engagement are tracked separately and can be compared per format. Roll-ups can still present plan-level totals, but the grain is the artifact. Consent-gating (`analytics_allowed`) and the opt-out flow carry over unchanged.

---

## Artifact-type roadmap

| `kind` | Format | Render locus | Price tier | Status |
|---|---|---|---|---|
| `plan_url` | Interactive web player | Computed page (live) | Paid (duration-based 1–2 cr) | **Shipped** (the existing player) |
| `pdf` | Multi-page handout | Computed page → downloadable file | Free | Designed here |
| `poster` | One-page printable summary | Computed page → downloadable file | Free (provisional) | Roadmap |
| `reel` | Stitched vertical video montage | Materialised MP4 in a bucket | Premium (TBD) | Roadmap (ADR 0022 anticipated) |
| `ai_reel` | AI style-transfer reel | Materialised MP4 (cloud render) | Premium (TBD) | Roadmap (parked premium) |
| `calendar` | Calendar / reminders export | ICS stream / subscription | Free (provisional) | Roadmap |

"Computed" kinds reuse `plan_url`'s live-page pattern (no stored output). "Materialised" kinds populate `plan_artifacts.output_url` with a signed URL to a rendered file and need a render pipeline + bucket + cache/expiry policy (the open question ADR 0022 already flagged).

---

## Schema deltas (proposed)

Extends the ADR 0022 table. **Proposed** — exact types to be finalised in the migration PR.

**`plan_artifacts`** (existing: `id, plan_id, kind, status, output_url, generated_at, error_message, metadata, UNIQUE(plan_id, kind)`):
- **Widen the `kind` CHECK** from `('plan_url')` to `('plan_url','pdf','poster','reel','ai_reel','calendar')` via `DROP CONSTRAINT … ADD CONSTRAINT`.
- `published_at timestamptz` — NULL = offered-but-not-minted; non-NULL = enabled/live. (Distinct from `generated_at`, which is render time.)
- `credits_charged numeric(10,4) default 0` — what this artifact cost at publish (0 for free kinds).
- `first_opened_at timestamptz` — per-artifact first open (analytics + feeds the plan-level grace trigger).
- `status` lifecycle formalised: `offered → rendering → ready → failed` for materialised kinds; computed kinds go straight to `ready`.
- Keep `output_url` NULL for computed kinds (player URL stays computed); populate for materialised kinds.
- Stays **RPC-write-only** (same lockdown as `credit_ledger`); the only writer is the publish flow.

**`plans`:**
- Redefine `first_opened_at` semantics as "first open of *any* enabled artifact" (no new column; the lock trigger reads it only when a paid artifact exists).

**Analytics tables** (`client_sessions`, `plan_analytics_events`):
- Add `artifact_kind` (or `artifact_id` FK) dimension so events attribute to a format.

**Claiming** (follow-on sub-wave):
- Reuse/extend `plan_invitations`; a `plan_claims` link table (recipient identity → plan, optional artifact kind) if the invitation model doesn't cover anonymous-web claims. Client web-account identity model is an open question.

---

## RPC surface (proposed)

- **Publish RPC becomes artifact-set-aware.** Accepts the set of `kind`s to publish; validates the lock state; sums paid-kind prices; calls `consume_credit` once for the total; upserts the `plan_artifacts` rows; writes the `plan_issuances` audit row — all in one transaction. Compensating refund on materialised-render failure.
- **`get_plan_full`** already returns an `artifacts` array (ADR 0022). Extend each entry with publish state + consent-gated per-treatment URLs so any artifact renderer (web player, PDF page, poster) reads from the one anon surface.
- **Lock RPCs** (`unlock_plan_for_edit`) unchanged — plan-level.

---

## Open questions

1. **Client web-account identity model** (largest unknown). Are claiming clients real `auth.users`? Anonymous-with-email? How does a claimed client relate to the practice's `clients` row (link, merge, mirror)? Does claiming transfer consent/analytics ownership to the client? POPIA review needed. This is a sub-wave of its own.
2. **Premium pricing** for `reel` / `ai_reel` (and whether `poster` / `calendar` are truly free or token-priced).
3. **Render infrastructure for materialised kinds** — reel transcode (vertical 9:16, cuts, watermark) and PDF generation: on-device vs server, which bucket, regenerate-on-demand vs cache, signed-URL lifetime. (ADR 0022 flagged this for `reel`/`pdf`.)
4. **Download / freeze UX** — per-artifact Download affordance: which kinds offer it, file naming, and whether a downloaded PDF embeds a "as of version N" stamp.
5. **`calendar` semantics** — ICS one-shot export vs live subscription feed; reminder cadence; timezone handling.
6. **Do free artifacts get claim / My Workouts too?** (Leaning yes — the funnel wants the free PDF to be claimable.)
7. **Backfill** — existing `plan_url` rows are already backfilled (ADR 0022); new columns land with safe defaults (`published_at = generated_at` for existing ready rows, `credits_charged` reconstructed from `plan_issuances` where possible).

---

## Non-goals

- **Per-artifact content divergence / snapshots.** Explicitly rejected (D1/D8). All artifacts render one live source; freezing happens only in the recipient's Download.
- **Multiple rows per type.** Singleton `(plan_id, kind)` enforced (D2/D7-singleton).
- **Subscription pricing for artifacts.** Credits only, consistent with ADR 0007 and the Safe Mode subscription's credit denomination (ADR 0021).
- **Re-publish-to-refresh.** Edits flow live to enabled artifacts; publishing is enablement, not a refresh cycle (D6).

---

## ADRs to ratify

These are hard-to-reverse, surprising-without-context decisions and warrant their own ADRs (to be authored alongside the first implementation PR):

- **Artifacts are live renderings; freshness is client-side.** (D1/D6/D7) — extends ADR 0022.
- **Plan-level edit-lock, paid-only trigger.** (D8) — extends ADR 0016.
- **Per-artifact pricing with an intentional free floor.** (D4) — extends ADR 0007.

---

## Decision log

| # | Decision | Rejected alternative | Why |
|---|---|---|---|
| D1 | One plan = source of truth; artifacts are live renderings | Artifacts hold their own content copy | Avoids snapshot machinery; keeps one mutable plan |
| D2 | `plan_artifacts` thin, singleton per `(plan_id, kind)` | Many rows per kind / content on the row | Singleton matches "one format = one output"; content stays on `plans`/`exercises` |
| D3 | All types always offered (render-on-demand) | Opt-in per-plan type enablement | New kinds light up everywhere automatically; no per-plan migration |
| D4 | Per-type pricing, free floor (PDF free) | Flat per-plan price; or PDF paid | Free PDF is a deliberate funnel/loss-leader |
| D5 | Publish = multi-select gate, nothing pre-checked | Pre-check all; or one-artifact-at-a-time only | Never charge by surprise; still allows publish-all in one pass |
| D6 | Publish = one-time enablement; then always live | Re-publish to push each edit (re-charge) | Edits flow live; publishing is enablement, not refresh |
| D7 | Freshness client-side via Download | Server-side frozen snapshots per send | No snapshot storage; freeze happens in recipient's hands |
| D8 | Plan-level lock, paid-only | Per-artifact lock + snapshots; or drop lock | Shared content → one lock; nothing to abuse until a credit is spent |
| D9 | Consent applies to every artifact (PDF too) | PDF always line-only | Parity; identifiable frames must respect the same gate everywhere |
| D10 | Per-artifact analytics | Player-only; or plan-level rollup only | Compare engagement per format; generalizes Wave 17 |
| D11 | Claim into My Workouts; web + app; link + email | App-only; or anon-link only | Maximum reach into app-less clients; builds on `plan_invitations` |
| D12 | Roadmap: reel, poster, calendar, AI reel | Player + PDF only | Model must stretch to materialised + non-page formats |
