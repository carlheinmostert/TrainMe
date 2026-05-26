# Artifact system — design doc

**Status:** living design doc · authored 2026-05-26, consolidated from the grilling session that resolved the identity/sharing/claiming, free-artifact, consent, and analytics threads · **extends** [ADR 0022](./adr/0022-plan-artifacts-abstraction-before-reel.md) (the `plan_artifacts` skeleton) and **supersedes** [`FREE_LOBBY_EXPORT.md`](./FREE_LOBBY_EXPORT.md) (the free artifact is reframed from an on-device PDF/PNG into a live web page — see [The free/paid split](#the-freepaid-split-is-the-artifact-split)).

**Owners:** Carl + Claude

**Related artifacts:**
- ADRs: [0007](./adr/0007-credit-billing-model.md) (credit model), [0016](./adr/0016-fourteen-day-structural-edit-grace.md) (edit-lock grace), [0022](./adr/0022-plan-artifacts-abstraction-before-reel.md) (`plan_artifacts`)
- Predecessor: [`FREE_LOBBY_EXPORT.md`](./FREE_LOBBY_EXPORT.md) — its strategic frame ("one source of truth, two render targets: interactive vs static") *is* this model; its shipped PDF/on-device form is now superseded.
- Predecessor seams: [`SELF_TRAINER_WAVE.md`](./SELF_TRAINER_WAVE.md) — `plan_invitations`, the My Workouts tab, the universal `Publish` verb.
- Proposed new ADRs: see [ADRs to ratify](#adrs-to-ratify).

## Table of Contents

- [North star](#north-star)
- [What an artifact is](#what-an-artifact-is)
- [Locked decisions](#locked-decisions)
- [The free/paid split is the artifact split](#the-freepaid-split-is-the-artifact-split)
- [Reversals of shipped behavior](#reversals-of-shipped-behavior)
- [Publish = enablement; artifacts are always live](#publish--enablement-artifacts-are-always-live)
- [Pipeline: Preview / Publish / Share](#pipeline-preview--publish--share)
- [Identity & claiming](#identity--claiming)
- [Sharing & the engagement rail](#sharing--the-engagement-rail)
- [Consent & POPIA](#consent--popia)
- [Analytics](#analytics)
- [Billing](#billing)
- [Brand-skin subscription & the always-on homefit seal](#brand-skin-subscription--the-always-on-homefit-seal)
- [Edit-lock semantics](#edit-lock-semantics)
- [Visual surfaces](#visual-surfaces)
- [Artifact-type roadmap](#artifact-type-roadmap)
- [Schema deltas (proposed)](#schema-deltas-proposed)
- [RPC surface (proposed)](#rpc-surface-proposed)
- [Open questions](#open-questions)
- [Non-goals](#non-goals)
- [ADRs to ratify](#adrs-to-ratify)
- [Decision log](#decision-log)

---

## North star

A published plan is not synonymous with "the Plan URL." A plan is a **single source of truth** — its exercises, sets, consent, versioning — that can be **rendered into many artifacts**: format-specific, independently-priced, independently-shared, *live* outputs. The free **workout handout** and the paid **workout player** are the first two; a poster, a stitched reel, a calendar export, and an AI style-transfer reel are siblings.

The strategic shape: a practitioner delivers real value for **free** (the workout handout is a deliberate loss-leader / funnel), and the product monetizes when they reach for the richer formats — the workout player and, later, premium reels. The free artifact gateways into the paid one.

---

## What an artifact is

The `plans` row and its `exercises` stay exactly as today — one mutable, version-bumped source of truth. `plan_artifacts` holds **at most one row per `(plan_id, kind)`**. A row's content is never stored on it — the artifact is **rendered on demand** from the live plan. Editing the plan updates every enabled artifact instantly. Money attaches at the artifact level (per-kind price, charged once at publish); the content **edit-lock** attaches at the plan level (one shared body of exercises → one lock).

---

## Locked decisions

Resolved across the grilling session. Detailed below; captured in the [Decision log](#decision-log).

**Model**
1. One plan = one source of truth; artifacts are live renderings, never content copies.
2. `plan_artifacts` is thin, singleton per `(plan_id, kind)` — publish state, price, share/claim handles, render metadata only.
3. Every supported type is always offered (render-on-demand); the type registry is global.
4. Pricing is per-type with an intentional free floor (workout handout free; workout player paid; reels premium).
5. Publish is a multi-select gate (nothing pre-checked); Preview is a single-artifact lens; Share is per-artifact.
6. Publish is one-time enablement; thereafter the artifact is live and tracks the plan — no re-publish to push edits.
7. Freshness lives client-side; recipients freeze a copy only via Download/Print.

**The free artifact**
8. The free artifact is a **live, interactive web page** (`/h/{planId}`), not a PDF. PDF/print is a *button on the page*, not the artifact.
9. It carries: a claim CTA, a QR back to the live artifact, consent-gated treatment, and a version stamp on print.
10. Full consent uniformly — the handout honors line/B&W/original exactly like the player (no "higher bar for print").

**Identity & sharing**
11. The anonymous public link **survives** — not overturned. Account is opt-in via **claim** (magic-link only for now).
12. The claim CTA is a persistent chip that **escalates** over time but never becomes a modal/wall (R-01).
13. Claimed plans stay **live-linked** to the creator's plan; claiming never snapshots.
14. **Claim is the primary engagement-rail filler** (verified email, any channel); practitioner-typed email is a pre-claim fallback + claim-nudge only, and is deleted once a verified one exists.
15. The claim loop is closed by **matching on the claimed plan**, not the email address; a claimed account back-links to the practitioner's client record.

**Consent & analytics**
16. Consent is **practice-grain**; practitioner-proxy pre-claim, **client-controlled post-claim** (full autonomy, with transparency to the practitioner).
17. On claim, consent **inherits** the practitioner's current setting (continuity); the consumer account is a **spanning identity** linking otherwise-separate practice client-rows.
18. Analytics is **per-artifact**; named adherence starts **claim-forward only** (pre-claim stays anonymous aggregate).

**Visual**
19. My Workouts = one recency-sorted, **badged** list (provenance + kind), not split sections.
20. Cards are **thumbnail-led with a kind glyph corner badge** (single-coral brand; no per-kind colour).
21. The Publish gate is a **checklist with per-row price + live running total**.

**Brand & monetization**
22. **Monetize enhancement, not entry** — free artifacts are always free; brand-skin is a paid upgrade *on top* (**4 credits/month**, credit-denominated like Safe Mode; **30-day free trial** on first subscription; **7-day lapse-grace** before chrome reverts; **one skin per practice** — a practitioner in multiple practices configures each separately).
23. The homefit **"powered by" seal + QR is permanent** on every artifact (no white-label), in homefit coral, designed as a *credibility seal*; the QR carries the practitioner's **referral code as link attribution**.
24. Brand identity (logo, accent colour, practice name, contact) is sourced from the **existing portal public profile** — positioning, not new capture.
25. Skin is a **live property** — lapse live-reverts every artifact (incl. already-shared) to the homefit default; no per-publish-date retention.

---

## The free/paid split is the artifact split

The product already had this idea, in [`FREE_LOBBY_EXPORT.md`](./FREE_LOBBY_EXPORT.md): *"The free product is the amputated paid product, not a separate thing — one source of truth, two render targets (interactive vs static)."* That sentence is the artifact model. This design generalizes "two render targets" into N.

- **Paid — the workout player** (`/p/{planId}`, kind `plan_url`): the full workout-along experience — timers, prep, treatment switching, audio, pill matrix, analytics. Priced (duration-based 1–2 credits).
- **Free — the workout handout** (`/h/{planId}`, kind `handout`): a page-format view of the plan — exercises with hero frames, reps/sets/hold/notes, circuit grouping. **But live and interactive**: it carries a claim CTA, a QR back to the live artifact, consent-gated stills, and a Print/Save-PDF button. Free (0 credits). Its job is the **no-phone / low-tech / printable fallback** *and* the top of the funnel. The name borrows directly from clinical vocabulary — a handout is what a practitioner hands a client, paper or digital.

**Why a page and not a PDF.** A PDF is dead — no claim, no live updates, no QR action, no analytics. The artifact must be interactive, so it's a page; print-to-PDF is a browser feature *of* that page (a print stylesheet, not a generator). This also returns to the lobby spec's original anti-goal ("No PDF, ever") — the shipped PDF was an implementation detour.

**Why a link and not an inline image.** The original lobby export was a PNG because an image unfurls beautifully inline in WhatsApp. We accept losing that: an inline image of a 10-exercise plan is too small to read (you tap to zoom regardless) and is *dead*; a link leads somewhere *actionable*, which is what adherence needs, and is a far better funnel (tappable claim + "play with timers" vs. scan-a-QR-with-a-second-device). Mitigation: invest in a **generated OG preview image** (`@vercel/og`) so the WhatsApp unfurl is an attractive card. The full-plan image survives only as an optional later **poster** artifact.

**iOS Reader-App constraint.** Nothing on the free page may read as a purchase path — "Save your plan" and "Scan to play with timers" are fine; "buy / upgrade / credits" are not (`feedback_ios_reader_app.md`).

---

## Reversals of shipped behavior

Recording these consciously — they remove working code, not just edit a doc:

1. **Free artifact: PDF → live page.** The shipped on-device "PDF handout" (the `LobbyExportCard` lobby export, PDF pipeline live since 2026-05-15) is deprecated in favor of the new **workout handout** at `/h/{planId}` — a live, interactive web page with a print/PDF button. The retired feature kept the practitioner-facing word "handout"; the live successor inherits it. The Flutter generator and its `lobby.css` R-10 parity tax are retired.
2. **Generation: on-device/offline/pre-publish → published web artifact.** The on-device path existed only to dodge the credit-charging publish flow (so the freebie could be free). Now that publish is per-artifact and the handout is a 0-credit artifact, that scaffolding is obsolete: you publish the handout for free through the normal flow. The pre-publish-vs-post-publish duality dissolves into "publish the free artifact, it costs nothing." **Accepted loss:** no-signal offline sharing — narrow, and consistent with publish having always been online-only (offline-first covers capture→edit→preview, not sharing).

---

## Publish = enablement; artifacts are always live

Two separate axes:

- **Enablement** is one-time, per-artifact. Publishing the player mints its URL and charges its price once; publishing the handout mints its page once (free). After that, the artifact exists.
- **Freshness** is continuous and shared. Every *enabled* artifact is a live rendering of the latest plan. Edits flow to all enabled artifacts with no re-publish and no re-charge.

You never re-publish to push an edit. The only frozen copy is in the *recipient's* hands, via Download/Print.

---

## Pipeline: Preview / Publish / Share

- **Preview — single-artifact lens.** Pick an artifact type and preview that rendering; all types always listed (render-on-demand previews live).
- **Publish — multi-select gate.** Lists every type with its per-kind price; **nothing pre-checked**; shows a live credit total; confirm charges the sum and mints/updates `plan_artifacts` rows in one transaction (alongside `plan_issuances`). Already-enabled kinds shown as such; re-ticking is a no-op, never a re-charge. The free workout handout is a 0-credit row in this gate.
- **Share — per-artifact**, two paths (see [Sharing](#sharing--the-engagement-rail)).

---

## Identity & claiming

**The anonymous public link survives untouched.** We considered requiring login on every shared link and rejected it: it would tax adherence (the thesis), wall out low-tech/older patients, invert the POPIA moat (zero-client-PII today), and grow complexity rather than shrink it. Instead:

- **Anonymous-first.** The link opens the artifact instantly, no auth — exactly as today. A sore-knee patient taps, does the exercises, leaves, and never has an identity. Zero friction, POPIA moat intact.
- **Account is opt-in via claim.** The artifact carries a soft, dismissible **claim CTA** ("Keep these in your app" / "Save your plan"). Claim auth is **magic-link only** for now (no passwords; Apple/Google deferred). On signup, **the page already knows its `plan_id`** (it's in the URL), so the current plan attaches to the new account — that's the whole mechanism. No silent identity token is minted (rejected — it would assign identity to non-claimers and reintroduce the POPIA problem).
- **The chip escalates, never walls.** Quiet at first, more insistent on return visits — but never a modal or a gate (R-01). It earns attention by offering what anonymous can't: all plans in one place, progress, history, reminders, re-finding without the WhatsApp link.
- **Claimed = live-linked.** A claim links the consumer to the *creator's live plan*; updates keep flowing. Claiming never snapshots.
- **My Workouts** (web account on `session.homefit.studio` + the app inbox) is the claim destination — an *optional* surface, not a gate. The claimed account is a **spanning identity** that threads together otherwise-separate practice client-rows (see [Consent](#consent--popia)).

**Collaboration** (parked): a future feature where the claimed client comments/chats *about* the plan (not co-editing it) — the plan becomes the interface point between client and practitioner. It is auth/claim-gated by nature. Not designed here.

---

## Sharing & the engagement rail

Today Share is a URL-only iOS share sheet. The artifact model splits it by **intent**, which maps to a real practitioner question — "WhatsApp or email?":

- **Share sheet (public link).** OS sheet flings the public link anywhere — WhatsApp/iMessage/etc. The dominant path. Anonymous, no contact captured.
- **Managed email.** Our UI sends a branded Resend email with the artifact link + claim CTA. This captures the address and doubles as the **best-converting claim nudge** (a branded "save your plan" email beats a bare WhatsApp link).

**Email is the ongoing-engagement rail, not a delivery mechanism.** Delivery is already solved by WhatsApp + the link (the page knows its `plan_id`, so any-channel claim works). The reason to hold an email is to *reach* the client once the plan is live and accumulating updates/replies.

- **Claim is the primary rail-filler.** When any client claims (any channel), magic-link signup yields a *verified* email. That fills the rail for the 84% who arrive via WhatsApp.
- **Practitioner-typed email** (`clients.email`, new) is a *pre-claim fallback contact* + claim-nudge only — unverified, typo-prone. **When a verified claim email exists, it supersedes and the typed one is deleted** (POPIA data-minimization).
- **Loop closed by the claimed plan, not the address.** A claimed plan belongs to a practitioner's client record, so the claimed account back-links there regardless of which email was used; the practitioner sees "claimed · account linked."

---

## Consent & POPIA

The consent matrix is six toggles per practice relationship. **Line drawing** is always-on (de-identified by the conversion pipeline; consent can't be withdrawn). **B&W**, **Original**, **Profile photo** (avatar), **Face fingerprint** (the MobileFaceNet biometric embedding from the Safe Mode v2 wave — used to tell the client apart from bystanders), and **Workout stats** (`analytics_allowed`) are all consumer-controllable post-claim, practitioner-proxy pre-claim.

Vocabulary on the client-facing surface uses plain language: "Face fingerprint" rather than "biometric embedding", "Workout stats" rather than "analytics".

**Grain and ownership:**
- **Practice-grain.** One consent record per practice a client is linked to (presented to the client per-relationship — "Smith Physio", "Cape Biokinetics"). Finer-than-practice was rejected: practitioners in one practice share the client record, so splitting consent per-practitioner is incoherent.
- **Pre-claim: practitioner-proxy.** The practitioner sets `video_consent` on the client row, as today.
- **Post-claim: client-controlled, full autonomy.** Once the client has an account linked to that practice, *they* own the consent for that relationship. No clinical carve-out — but with **transparency**: the practitioner sees "analytics off for this client," they just can't override or fake it.
- **Inherit on claim.** At claim, the client's self-consent *inherits* the practitioner's current setting (continuity — nothing visibly changes); the client adjusts from there. First visit to the consent panel reads "here's what's currently shared — you can change it."

**Spanning identity.** The claimed consumer account sits *above* practice client-rows and threads them together. Per-relationship consent lives on that account at **consumer × practice** grain and overrides the practitioner-proxy once it exists. This maps cleanly to rendering: every plan belongs to exactly one practice (`plans.practice_id` / `trainer_id`), so an artifact always reads the matching relationship's consent — per-relationship consent and per-plan gating are the same thing.

---

## Analytics

Per-artifact (D10), and transformed by claiming:

- **Claim upgrades anonymous guesses to known-person truth.** Wave-17 analytics are session-level ("someone opened this 4×"); a claimed client's engagement is attributable to a *person* ("Margaret completed 3/5, last Tuesday") — the adherence thesis made real.
- **Back-attribution: claim-forward only.** Pre-claim anonymous sessions are *not* retroactively tied to a claiming client (they engaged believing it was anonymous). Named adherence starts at the claim.
- **Consent ownership** follows the [consent model](#consent--popia) — client-controlled post-claim, transparent to the practitioner.
- **Per-artifact event vocabularies (proposed, confirm).** Artifacts don't speak the same language: the player has the rich workout funnel (the 13 Wave-17 events); the handout can only emit page-level events (opened, treatment_changed, claim_tapped, qr_scanned, printed). Proposal: per-artifact event sets rather than one sparse universal schema, so each format honestly reports what it can.
- **Actionability (proposed, confirm).** Display-first; the real payoff (fast-follow) is wiring adherence into the engagement rail — "Margaret hasn't opened her plan in 5 days → nudge."

---

## Billing

Per-type price is a policy function:
- `handout` → **free** (0 credits). Funnel; absorbs render/storage cost as cost-of-funnel.
- `plan_url` (player) → existing duration-based price: 1 credit ≤ 75 min, 2 credits > 75 min (ADR 0007 unchanged).
- `reel`, `ai_reel` → premium, **price TBD**.
- `poster`, `calendar` → free/TBD.

Charge fires once per artifact at publish; the gate sums selected paid kinds and consumes credits atomically via `consume_credit`. Materialised kinds (reel) can fail after charge — reuse the compensating-refund pattern. "Plan becomes paid" = first paid artifact published; that arms the edit-lock.

---

## Brand-skin subscription & the always-on homefit seal

**Principle: monetize enhancement, not entry.** Nothing is gated at the door — the free artifacts always work, free. The brand-skin is an *upgrade on top*: a practitioner who wants their own identity on those free artifacts pays a recurring fee of **4 credits/month** (R100 at the locked R25/credit bundle rate; credit-denominated like the Safe Mode subscription, ADR 0021). You never charge someone to get in; you charge them to look more professional once they're already in. This also quietly earns money from **free-only practitioners** — someone who never publishes a paid player but wants to look professional buys credits purely for the skin (revenue from the free tier without gating it). First subscription includes a **30-day free trial** (no debit until day 31). Renewal is manual — push notification at day 25, re-up via Settings → Subscription; no auto-debit in v1 (mirrors ADR 0021). **One skin per practice** — a practitioner who belongs to multiple practices subscribes (and configures) each independently; artifacts render with the skin of *the practice the plan was published from*.

**What the skin is.** The practitioner's brand identity — logo, accent colour, practice name, contact — applied across their artifacts. The source of truth is the **portal public profile** (shipped on `staging` with the self-trainer / Safe Mode transparency waves; not yet promoted to `main`, which is why it's invisible from this branch), which already captures this data. So brand-skin is *not* a data-capture feature — it's a **positioning/design problem**: where each piece of the public profile lands in each artifact type (a mockup question).

**The homefit seal is permanent.** homefit is never white-labeled away. Every artifact always carries a "powered by homefit" mark + QR, in homefit coral, regardless of subscription. This is deliberate and **tri-party**:
- **Client/patient** — a credibility signal: "my practitioner runs on a real, auditable system."
- **Practitioner** — the seal makes them look *more* serious, not less; their own logo *plus* a credible platform mark is the professionalism they're paying for.
- **homefit** — the permanent funnel, and the QR carries the practitioner's **referral code as link attribution** (`?ref={code}`), so the seal can *earn the practitioner referral rebates* — the strongest reason they're happy to keep it. The code is attribution on the artifact link, **never the QR destination** (the recipient always lands on their plan, not a practitioner-signup page).

The seal must be *designed as a seal* (credibility), not a banner ad — placement/prominence per artifact type is a visual-layer decision ("in the correct place").

**Skin is a live property — with a 7-day lapse grace.** While subscribed, the skin renders across all the practitioner's artifacts (free + paid) for that practice. When credits run out, the chrome **keeps rendering for 7 days** while a coral banner in the Studio + portal warns the practitioner to top up. On day 8 every artifact — *including ones already shared and sitting in clients' phones* — live-reverts to the homefit default look. We deliberately do **not** preserve skin per-publish-date: the renewal pressure is intended, and per-date retention is complexity we don't want. It falls straight out of the always-live artifact model.

**Implementation conventions (locked at the visual phase, 2026-05-26).**

- **The seal uses dedicated CSS tokens that the brand-skin never overrides.** `--seal-coral` and `--seal-coral-light` live at `:root` scope; the `.skin-{name}` override class only repaints `--brand-default`, `--brand-light`, `--brand-tint-bg`, `--brand-tint-border`, `--brand-glyph-bg`. The seal renderer reads `--seal-coral*` exclusively. That single un-overridden token is decision #23 in pixels.
- **The `.studio` wordmark is coral.** In every rendering of the homefit lockup — default-variant header AND footer seal in both variants — `.studio` (both the dot AND the word "studio") uses the coral token. Not muted grey. See `feedback_homefit_studio_wordmark.md` for the trap.
- **The canonical fictional practitioner brand is "Range Movement" (red `#dc2626`).** Established in `docs/design/mockups/2026-05-26-workout-handout-page.html`, reused across the studio-status-bits seal-placement pairs. Re-using one fictional practitioner across the design wave keeps the mental model consistent. Glyph follows the hero-figure convention (head + spine + arms + legs stick-figure), not an abstract symbol.

---

## Edit-lock semantics

The lock (ADR 0016) is an anti-abuse rule on the credit model, not a freshness/format concept. It stays **plan-level** (all artifacts render the same shared exercises → one lock) and **paid-only**:
- Non-structural edits (reps/sets/hold/notes/filter) are free forever — so the ongoing tweaks a live-linked relationship generates reach the client live, free.
- Structural edits (add/remove/reorder) are free for 14 days after first open of *any* enabled artifact, then lock; a plan-level 1-credit prepay (`unlock_plan_for_edit`) buys the next structural republish.
- A plan that has only ever published *free* artifacts never locks (no credit spent → nothing to abuse).

---

## Visual surfaces

**Visual phase closed 2026-05-26.** All seven mockups walked through with Carl in the Claude Code preview panel and signed off. The locked mockups live in `docs/design/mockups/`:

| Surface | Mockup file | Locked decisions |
|---|---|---|
| **My Workouts** (mobile) | `2026-05-26-my-workouts-artifacts.html` | One badged list (#19); thumbnail-led cards + kind glyph corner badge (#20); coral-tint provenance banner along the **bottom** of received cards; edit-pencil (yours) vs chevron (received) as the tell |
| **Publish gate** (mobile) | `2026-05-26-publish-gate.html` | Multi-select checklist + per-row price + live running total (#21); four row states (Available unchecked, Available checked, Live, Soon); CTA states the cost explicitly; nothing pre-checked |
| **Workout handout** (`/h/`, web) | `2026-05-26-workout-handout-page.html` | Two side-by-side renderings: default homefit-coral + Range Movement brand-skin. Claim chip + treatment toggle + exercise list + permanent homefit seal + QR + version stamp. `--seal-coral` token never overridden by skin |
| **Share sheet** (mobile) | `2026-05-26-share-sheet.html` | Two-path split — OS share (compact) vs managed-email (expanded with input + "Send · 1 email" CTA); footer note on claim-supersedes-typed-email |
| **Client web account** (`/me`, web) | `2026-05-26-client-web-account.html` | Two-state mockup: magic-link claim + signed-in My Workouts. Card pattern mirrors mobile My Workouts (R-10-style parity); spanning-identity link "Settings · N practitioners linked" |
| **Consumer consent panel** (`/me/data`, web) | `2026-05-26-consumer-consent-panel.html` | One card per linked practice with six toggles: Line drawing (locked-ON) · B&W · Original · Profile photo · Face fingerprint · Workout stats. "Stop all stats" master switch in the footer |
| **Studio status bits** (mobile + artifact thumbs) | `2026-05-26-studio-status-bits.html` | Per-plan status row pills (sage live / coral published / dashed not-yet); edit-lock chip triptych (free-only / grace countdown / unlock sheet); brand-skin seal placements as 4 collapsible default-vs-skin pairs |

**Open visual questions deferred to implementation:**
- Workout player itself (`/p/`) hasn't been re-mocked since it already shipped; its brand-skin integration follows the same pattern as the handout (the studio-status-bits seal-placement section shows it in miniature).
- Practitioner-facing portal audit feed surfaces for new per-artifact kinds — needs a portal mockup once the kinds are implemented.

**Practitioner-app surfaces are NOT brand-skinned.** The skin transforms client-facing *artifacts*, not the practitioner's own UI. My Workouts, Publish gate, Share sheet, Studio status row, edit-lock chip all stay homefit-coral. The consent panel and client web account are consumer-side but also stay homefit-coral — the consumer's UI shouldn't shift identity across multiple practitioners.

---

## Artifact-type roadmap

| `kind` | Format | Render locus | Price | Status |
|---|---|---|---|---|
| `plan_url` | Workout player (`/p/`) | Computed page (live) | Paid (1–2 cr) | **Shipped** |
| `handout` | Workout handout (`/h/`) — page + print/PDF | Computed page (live) | Free | Designed here (supersedes the on-device PDF handout) |
| `poster` | Single shareable image (WhatsApp/social) | Materialised image (`@vercel/og`) | Free/TBD | Roadmap (the demoted PNG) |
| `reel` | Stitched vertical video | Materialised MP4 in a bucket | Premium TBD | Roadmap (ADR 0022 anticipated) |
| `ai_reel` | AI style-transfer reel | Materialised MP4 (cloud render) | Premium TBD | Roadmap (parked premium) |
| `calendar` | Calendar / reminders export | ICS stream / subscription | Free/TBD | Roadmap |

---

## Schema deltas (proposed)

Exact types finalised in the migration PR.

**`plan_artifacts`** (existing: `id, plan_id, kind, status, output_url, generated_at, error_message, metadata, UNIQUE(plan_id, kind)`):
- Widen the `kind` CHECK to `('plan_url','handout','poster','reel','ai_reel','calendar')`.
- `published_at timestamptz` (NULL = offered, not minted), `credits_charged numeric(10,4) default 0`, `first_opened_at timestamptz` (per-artifact).
- `status` lifecycle: `offered → rendering → ready → failed` (materialised) / straight to `ready` (computed).
- Stays RPC-write-only.

**`clients`:** add `email text` (practitioner-typed, transient; deleted when a verified claim email supersedes; POPIA notice required).

**Consumer identity & consent:**
- A consumer account model (claimed clients) — likely `auth.users` + a `client_accounts` / claim-link table tying consumer ↔ practice client-rows (the spanning identity).
- A consent record at **consumer × practice** grain (client-controlled), overriding the practice's `clients.video_consent` (practitioner-proxy) once it exists. Six toggles: `line_drawing` (always true, locked), `grayscale` (B&W), `original`, `avatar` (profile photo), `face_recognition` (face fingerprint — already on the practitioner-side from the Safe Mode v2 wave), `analytics_allowed` (workout stats).
- `plan_claims` (or extend `plan_invitations`): consumer ↔ plan, matched on the claimed plan.

**`plans`:** `first_opened_at` redefined as "first open of *any* enabled artifact."

**Analytics:** add an artifact dimension (`artifact_kind`/`artifact_id`) to `client_sessions` / `plan_analytics_events`; add a claimed-identity link (claim-forward only); per-artifact event vocabularies.

---

## RPC surface (proposed)

- **Publish RPC** becomes artifact-set-aware: accepts the kinds to publish, validates lock state, sums paid-kind prices, calls `consume_credit` once, upserts `plan_artifacts` rows, writes `plan_issuances` — one transaction. Compensating refund on materialised-render failure.
- **`get_plan_full`** already returns an `artifacts` array (ADR 0022); extend with publish state + consent-gated per-treatment URLs so every renderer (player, handout) reads from the one anon surface. Add an `/h/`-friendly variant if needed.
- **Claim RPC**: magic-link signup → attach current `plan_id` → back-link to the practitioner's client record by matched plan.
- **Lock RPCs** (`unlock_plan_for_edit`) unchanged — plan-level.

---

## Open questions

1. **Consumer identity model** — are claimed clients `auth.users`, and exactly how does `client_accounts` link to practice `clients` rows? (The grain — consumer × practice — is fixed; the table shape isn't.)
2. **Analytics event vocabulary** — confirm per-artifact event sets vs one sparse universal schema.
3. **Analytics actionability** — confirm display-first, nudges as fast-follow.
4. **Practitioner view of contact** — show "claimed · linked" *status* only, or expose the consumer's verified email address?
5. **Premium pricing** — `reel` / `ai_reel` (and whether `poster` / `calendar` are free or token-priced).
6. **Render infra for materialised kinds** — reel transcode + bucket + cache + signed-URL lifetime (ADR 0022 flagged).
7. **Consumer consent UI** — the "my practitioners / my data" panel layout (mockup).
8. **Collaboration** — the whole anchored-comms feature (parked).
9. **Brand-skin positioning** — where each public-profile piece (logo / accent / name / contact) lands in each artifact type, and how the permanent homefit seal sits beside it (mockup); confirm the exact public-profile field names against `staging` when implementing.
<!-- open question #10 (brand-skin price) RESOLVED 2026-05-26: 4 credits/month, 30-day trial, 7-day lapse-grace, one skin per practice. See decision log #30. -->

---

## Non-goals

- **Per-artifact content divergence / snapshots** — one live source; freezing only in the recipient's Download/Print.
- **Multiple rows per type** — singleton `(plan_id, kind)`.
- **Silent identity tokens** — non-claimers stay genuinely anonymous; identity only on opt-in claim.
- **PDF as the free artifact** — it's a live page; PDF is a print button.
- **On-device / offline / pre-publish free generation** — superseded by the published 0-credit web artifact.
- **Co-editing collaboration** — collaboration is anchored comms, never the client editing the plan.
- **Subscription pricing for artifacts** — credits only (consistent with ADR 0007 / 0021).
- **Mandatory login on shared links** — the anonymous link survives.
- **White-label / removing the homefit seal** — the "powered by" mark + QR is permanent on every artifact, paid or not.
- **Per-publish-date skin retention** — the skin is a live property; lapse reverts every artifact.
- **Entry paywalls** — nothing is gated at the door; paid features are enhancements on top of a usable free floor.

---

## ADRs

All six ADRs flagged at the close of the visual phase landed in this branch on 2026-05-26 — alphabetically by number:

- [`docs/adr/0024-anonymous-link-survives-claim-is-opt-in.md`](./adr/0024-anonymous-link-survives-claim-is-opt-in.md) — Anonymous link on shared artifacts survives; claim is opt-in (rejected: mandatory login, silent identity token). Locks decisions #11–#15.
- [`docs/adr/0025-workout-handout-is-a-live-page-not-a-pdf.md`](./adr/0025-workout-handout-is-a-live-page-not-a-pdf.md) — Workout handout is a live interactive page at `/h/`, not a PDF. Deprecates the shipped on-device PDF handout pipeline. Locks decisions #8–#10.
- [`docs/adr/0026-practice-grain-consent-client-controlled-on-claim.md`](./adr/0026-practice-grain-consent-client-controlled-on-claim.md) — Consent is practice-grain; practitioner-proxy pre-claim, client-controlled post-claim with transparency-not-override. Locks decisions #16–#17.
- [`docs/adr/0027-per-artifact-pricing-with-free-floor.md`](./adr/0027-per-artifact-pricing-with-free-floor.md) — Pricing is per artifact kind; the floor is free. Extends ADR 0007. Locks decision #4.
- [`docs/adr/0028-edit-lock-is-paid-only-at-plan-level.md`](./adr/0028-edit-lock-is-paid-only-at-plan-level.md) — Edit-lock is plan-level, paid-only; free-only plans never lock. Extends ADR 0016.
- [`docs/adr/0029-brand-skin-subscription-monetize-enhancement-not-entry.md`](./adr/0029-brand-skin-subscription-monetize-enhancement-not-entry.md) — Brand-skin is a credit-denominated subscription on top of a permanent homefit seal. Locks decisions #22–#25 + #28–#29.

---

## Decision log

| # | Decision | Rejected alternative | Why |
|---|---|---|---|
| 1 | One plan = source of truth; artifacts are live renderings | Artifacts hold content copies | Avoids snapshot machinery |
| 2 | `plan_artifacts` thin, singleton per `(plan_id, kind)` | Many rows / content on row | One format = one output |
| 3 | All types always offered (render-on-demand) | Per-plan opt-in enablement | New kinds light up everywhere |
| 4 | Per-type pricing, free floor | Flat per-plan price | Free workout handout is the funnel |
| 5 | Publish = multi-select gate, nothing pre-checked | Pre-check all / one-at-a-time | Never charge by surprise |
| 6 | Publish = one-time enablement; then live | Re-publish to push edits | Edits flow live, no re-charge |
| 7 | Freshness client-side (Download/Print) | Server-side snapshots | No snapshot storage |
| 8 | Free artifact = live page, not PDF | Ship the PDF handout | A PDF is dead; artifact must be interactive |
| 9 | Page carries claim + QR + version stamp + print | Bare static export | Funnel + paper→digital bridge |
| 10 | Full consent uniformly on the page | Line-only / higher print bar | Don't nanny users |
| 11 | Anonymous link survives; claim is opt-in | Mandatory login on links | Protects adherence + POPIA moat |
| 12 | Magic-link claim auth; escalating-but-not-modal chip | Password wall / pre-checked | Lowest friction for patients (R-01) |
| 13 | Claimed plans stay live-linked | Snapshot on claim | Linkage is the point (updates, future comms) |
| 14 | Claim = primary rail-filler; typed email = fallback, deleted on verify | Email-send path is the rail | WhatsApp dominates; claim fills the rail; POPIA minimization |
| 15 | Close loop by claimed plan, not address | Match by email | Addresses are fuzzy; the plan is exact |
| 16 | Practice-grain consent; client-controlled post-claim w/ transparency | Per-practitioner grain / silent opt-out | Matches tenancy; data-subject autonomy + clinical visibility |
| 17 | Inherit consent on claim; spanning consumer identity | Reset to default | Continuity; links cross-practice client-rows |
| 18 | Per-artifact analytics; named adherence claim-forward only | Back-attribute pre-claim sessions | Don't de-anonymize past anonymous activity |
| 19 | My Workouts = one badged list | Two sections / segmented tabs | Compact, unified provenance+kind |
| 20 | Thumbnail-led cards + kind glyph badge | Per-kind colour-coding | Single-coral brand |
| 21 | Publish gate = checklist + running total | Card grid / stepper | Functional, clear cost |
| 22 | Monetize enhancement, not entry; brand-skin = paid upgrade on the free tier (~2 cr/mo) | Entry paywall / fully-free skin | No flow friction; value-based upsell; earns from free-only practitioners |
| 23 | homefit seal permanent (no white-label); QR carries referral code as attribution | White-label removal tier | Permanent funnel + tri-party credibility; referral reward keeps practitioners happy |
| 24 | Brand content from the existing portal public profile | New brand-capture UI | Data already captured (on staging); only positioning remains |
| 25 | Skin is a live property; lapse reverts all artifacts | Preserve skin per publish-date | Renewal pressure intended; avoids retention complexity |
| 26 | User-facing names: **workout handout** (free) + **workout player** (paid); DB kind `handout`, URL `/h/`, pairs with existing `plan_url` + `/p/` | "overview page" / "printout" / "page" | Practitioner vocabulary ("handout" is what a physio hands a patient); pairs cleanly with "player"; inherits lineage from the retired "PDF handout"; resolves open question #7 |
| 27 | Consent matrix is **six toggles**: Line drawing (locked-ON) · B&W · Original · Profile photo · **Face fingerprint** · Workout stats | Five-toggle matrix (omitting biometric) | Face-recognition embedding from Safe Mode v2 is biometric data; consumer must own consent to it. "Face fingerprint" / "Workout stats" labels chosen for the consumer surface in preference to "biometric embedding" / "analytics" |
| 28 | The `.studio` wordmark renders in **coral** on both the dot AND the word "studio", in every homefit lockup (default header + footer seal in both variants) | `.studio` in muted grey | Canonical brand convention that pre-dates this wave; caught mid-walkthrough. Memory entry `feedback_homefit_studio_wordmark.md` captures the trap |
| 29 | **Range Movement (red `#dc2626`, hero-figure glyph)** is the canonical fictional practitioner-brand example, reused across mockups that demonstrate brand-skin | Different invented brands per mockup | A consistent example builds the mental model faster; the practitioner glyph follows the homefit hero-figure DNA (stick figure) not abstract symbols |
| 30 | Brand-skin subscription numbers locked: **4 credits/month** (R100 at R25/cr), **30-day free trial**, **7-day lapse-grace**, **one skin per practice** | 2 cr/mo / 3-day trial / instant revert / one skin per practitioner | 4 cr/mo aligns with the R100 round-number psychology and the Safe Mode 4-cr/mo pattern (ADR 0021); 30-day trial gives the practitioner long enough to fall in love with the look on artifacts they're actively sharing; 7-day grace prevents one missed payment from yanking the skin out from under clients mid-look; per-practice scope matches the existing tenancy boundary and the practice-grain consent model |
