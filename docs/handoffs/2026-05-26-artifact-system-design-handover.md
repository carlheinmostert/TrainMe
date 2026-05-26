# Handover — Artifact System design + visual phase

**Date:** 2026-05-26
**From:** cloud session (Claude Code on the web, headless Linux container)
**To:** a local agent that can open a browser / Safari and render mockups visually
**Branch:** `claude/artifact-system-design-hQNqE` (based on `main`)
**PR:** [#516](https://github.com/carlheinmostert/TrainMe/pull/516) — *draft*, base `main`, docs-only so far
**Primary artifacts produced this session:**
- `docs/ARTIFACT_SYSTEM.md` — the consolidated design doc (read this first, in full)
- `docs/design/mockups/2026-05-26-my-workouts-artifacts.html` — first visual mockup (My Workouts)

---

## 0. Why you exist / read-me-first

This is a **design session handover**, not an implementation task. A long grilling conversation between Carl and the cloud agent resolved the architecture of a new **"artifact system"** for homefit.studio, consolidated it into `docs/ARTIFACT_SYSTEM.md`, and started the **visual phase** (HTML mockups in `docs/design/mockups/`). The cloud agent could not open Safari or render HTML→PNG (headless container, no browser installed, no puppeteer). **You can.** That is the main reason for this handover: pick up the visual phase, show Carl rendered mockups, iterate, lock each surface.

**Your first actions:**
1. Read `docs/ARTIFACT_SYSTEM.md` end-to-end. It is the source of truth; this handover is the narrative + the bits not in the doc (conversation arc, working style, pending feedback).
2. Open `docs/design/mockups/2026-05-26-my-workouts-artifacts.html` in Safari and show Carl.
3. Collect his answers to the **two pending feedback questions** on that mockup (§7).
4. Then continue the mockup sequence (§8) — Publish gate next.

**Do not re-litigate settled decisions** (§3–§6) unless Carl reopens them. Several were hard-won through grilling and reversals; the decision log in the doc records the rejected alternatives.

---

## 1. What the artifact system is (one paragraph)

A published plan is no longer "the Plan URL." A **plan is one mutable source of truth** (its `exercises`, consent, version) that gets **rendered into many _artifacts_** — format-specific, independently-priced, independently-shared, **live** outputs. The interactive web player is just the first; the free overview page, a poster, a stitched reel, an AI reel, a calendar export are siblings. This is the realisation of the `plan_artifacts` table that [ADR 0022](../adr/0022-plan-artifacts-abstraction-before-reel.md) shipped as a one-row skeleton, and it generalises the [`FREE_LOBBY_EXPORT.md`](../FREE_LOBBY_EXPORT.md) idea ("one source of truth, two render targets: interactive vs static") into N targets. Strategic shape: deliver real value **free** (the overview page is a deliberate funnel), monetise the richer formats (player, premium reels) and the polish (brand-skin), never gate the door.

---

## 2. Conversation arc (how we got here — so you understand the user)

The session moved through these phases, in order:

1. **Initial model** (8 foundational decisions): plan = source of truth, per-artifact pricing, freshness client-side, all types always offered, singleton per type, publish as a multi-select gate.
2. **Identity debate** — Carl proposed *requiring login on every shared link* to simplify downstream features. The cloud agent **grilled hard against it** (adherence tax, low-tech patients, POPIA inversion, complexity-relocation). Outcome: **anonymous link survives; identity is opt-in via "claim."** Carl conceded and refined it into a clean consumer-convenience model.
3. **Collaboration clarification** — Carl corrected a misunderstanding: "collaboration" = a client↔practitioner **comms channel anchored to the plan** (comment/ask/complain), **not** co-editing. Parked as a future, claim-gated feature.
4. **Thread A — sharing & the engagement rail.**
5. **Thread B — the free artifact**, which reframed the shipped "PDF handout" into a **live interactive overview page** and surfaced **two reversals of shipped behaviour**.
6. **Thread C — consent + analytics** (practice-grain, client-controlled-on-claim, spanning identity, per-artifact analytics).
7. **Consolidation** — rewrote `ARTIFACT_SYSTEM.md` to match all of the above.
8. **Subscriptions / brand-skin** — confirmed the monetization philosophy ("enhancement not entry") and the brand-skin model; folded into the doc.
9. **Visual phase started** — built the My Workouts mockup; this handover.

---

## 3. RESOLVED decisions — the model & pipeline

1. **One plan = one source of truth.** Artifacts are live renderings; no plan content is copied into an artifact record.
2. **`plan_artifacts` is thin**, singleton per `(plan_id, kind)` — publish state, price paid, share/claim handles, render metadata. Never content.
3. **Every supported type is always offered** (render-on-demand). Type registry is global — a new kind lights up for all existing plans.
4. **Per-type pricing with an intentional free floor** (overview free; player paid; reels premium).
5. **Publish = multi-select gate** (nothing pre-checked); **Preview = single-artifact lens**; **Share = per-artifact**.
6. **Publish = one-time enablement.** Thereafter the artifact is live and tracks the plan — **no re-publish to push edits, no re-charge.**
7. **Freshness is client-side.** Enabled artifacts are live; the recipient "freezes" only via Download/Print. No server-side snapshots.

---

## 4. RESOLVED decisions — identity, sharing, claiming

**Identity / claiming:**
- **The anonymous public link survives.** Mandatory-login was considered and **rejected** (would tax adherence — the core thesis — wall out older/low-tech patients, invert the zero-client-PII POPIA moat, and grow complexity).
- **Account is opt-in via "claim."** The artifact carries a soft, **dismissible claim CTA** ("Save your plan"). **Auth = magic-link only for now** (no passwords; Apple/Google deferred).
- **The page already knows its `plan_id`** (it's in the URL), so claim attaches the *current plan* to the new account — that's the whole mechanism. **No silent identity token** (rejected — would identify non-claimers, reintroduce POPIA risk).
- **Claim chip escalates** (quiet → more insistent on return visits) but **never becomes a modal/wall** (R-01).
- **Claimed plans stay live-linked** to the creator's plan; claiming never snapshots.
- **My Workouts** (a new client web account on `session.homefit.studio` + the app inbox) is the **optional claim destination**, not a gate. The claimed account is a **spanning identity** linking otherwise-separate practice `clients` rows.
- **Collaboration** (anchored comms; NOT co-editing) is **parked**; it is auth/claim-gated by nature.

**Sharing & the engagement rail (Thread A):**
- **Email is the ongoing-engagement rail, not a delivery mechanism.** Delivery is solved by WhatsApp + link.
- **Two share paths:** (a) **managed email** (our Resend send, branded — doubles as the best claim-nudge); (b) **OS share sheet** (public link, any channel — the dominant WhatsApp path).
- **Claim is the primary rail-filler** (verified email, any channel). **Practitioner-typed email** (new `clients.email`) is a pre-claim fallback + nudge only; **the verified claim email supersedes and the typed one is deleted** (POPIA minimisation).
- **Loop closed by matching the claimed plan, not the email address;** the claimed account back-links to the practitioner's client record ("claimed · account linked").
- *Parked sub-decision:* show practitioner "claimed · linked" **status** only, vs **expose** the consumer's verified address.

---

## 5. RESOLVED decisions — the free artifact (Thread B + reversals)

- The artifact the doc once called `kind='pdf'` is reframed to a **live, interactive overview page** at `/o/{planId}` (proposed `kind = 'overview'`). **It is a page, not a PDF.**
- It is the **Free Lobby Export reborn** — supersedes [`FREE_LOBBY_EXPORT.md`](../FREE_LOBBY_EXPORT.md), which shipped as an **on-device multi-page PDF** ("PDF handout").
- It is **interactive**: claim CTA, **QR back to the live artifact**, consent-gated stills, a **Print / Save-PDF button** (browser print over a print stylesheet — **not** a generator), and a **version stamp** on the printed output.
- **Full consent uniformly** — it honours line/B&W/original exactly like the player (the "higher bar for print" idea was **rejected** — "don't nanny people").
- **Primary job:** the **no-phone / low-tech / printable fallback**, and the top of the funnel.
- **Free/paid split = the artifact split:** `overview` (`/o/`, free) vs the interactive `plan_url` player (`/p/`, paid 1–2 credits).
- The **WhatsApp inline image** (the original PNG) is **dropped as the primary form** — demoted to an optional later **`poster`** artifact. Mitigate the thinner link-unfurl with a **generated OG preview image** (`@vercel/og`).
- **iOS Reader-App rule:** claim/QR/upgrade copy must be purchase-neutral ("Save your plan", "Scan to play with timers" OK; "buy/upgrade/credits" not). See `feedback_ios_reader_app.md`.

**Two REVERSALS OF SHIPPED BEHAVIOUR (make consciously when implementing):**
1. **Free artifact: PDF → live page.** The shipped on-device "PDF handout" (PDF pipeline live since 2026-05-15) is **deprecated**; `LobbyExportCard` Flutter generator + its `lobby.css` R-10 parity tax are retired.
2. **Generation: on-device/offline/pre-publish → published 0-credit web artifact.** The on-device path only existed to dodge the credit-charging publish flow; now that publish is per-artifact and the overview is 0-credit, that scaffolding is obsolete. **Accepted loss:** no-signal offline handoff (narrow, and consistent with publish having always been online-only).

---

## 6. RESOLVED decisions — consent, analytics, billing, edit-lock, brand-skin

**Consent & POPIA (Thread C):**
- **Practice-grain** (one consent record per practice the client is linked to; *presented* to the client per relationship — "Smith Physio", "Cape Biokinetics"). Per-practitioner grain was **rejected** (practitioners in one practice share the client record).
- **Pre-claim: practitioner-proxy** (`clients.video_consent`, as today).
- **Post-claim: client-controlled, full autonomy** — *but with transparency*: the practitioner **sees** "analytics off for this client", they just can't override or fake it. (No clinical carve-out.)
- **Inherit on claim** (continuity — nothing visibly changes; the client adjusts from there). First consent-panel visit reads "here's what's currently shared — you can change it."
- **Spanning consumer identity:** consent lives on the consumer account at **consumer × practice** grain, overriding the proxy once it exists. Maps cleanly to rendering — every plan belongs to one practice, so an artifact reads that relationship's consent (per-relationship consent = per-plan gating).

**Analytics (Thread C):**
- **Per-artifact dimension.** Different artifacts have **different event vocabularies** (player = the 13 Wave-17 workout events; overview page = page-level events only: opened, treatment_changed, claim_tapped, qr_scanned, printed).
- **Claim upgrades anonymous guesses to known-person truth** (the adherence thesis made real).
- **Back-attribution: claim-forward only** — pre-claim anonymous sessions are **not** retroactively tied to a claiming client. *(Decided.)*
- *Proposed, NOT yet confirmed by Carl:* per-artifact event sets (vs one sparse universal schema); **display-first** analytics with nudges-via-the-rail as a fast-follow.

**Billing:**
- `overview` → **free**; `plan_url` player → existing duration-based **1 credit ≤75min / 2 credits >75min** (ADR 0007 unchanged); `reel`/`ai_reel` → **premium TBD**; `poster`/`calendar` → free/TBD.
- Charge once per artifact at publish; the gate sums selected paid kinds → `consume_credit` (atomic); compensating-refund on materialised-render failure.

**Edit-lock (extends ADR 0016):**
- **Plan-level, paid-only.** Non-structural edits (reps/sets/hold/notes/filter) free forever; structural edits (add/remove/reorder) free for **14 days after first open of any enabled artifact**, then lock → 1-credit `unlock_plan_for_edit` prepay. **Free-only plans never lock.**

**Brand-skin subscription (latest thread):**
- **Principle: monetize enhancement, not entry.** Free artifacts always work; brand-skin is a **paid upgrade on top** (**~2 credits/month**, credit-denominated like Safe Mode, ADR 0021). Never an entry paywall.
- **The homefit "powered by" seal + QR is PERMANENT on every artifact (no white-label),** in homefit coral, **designed as a credibility seal** (not a banner ad). It is **tri-party value**: client credibility signal, practitioner professionalism, homefit funnel.
- **The seal's QR carries the practitioner's referral code as link _attribution_** (`?ref={code}`), **never the QR destination** (a recipient always lands on their plan, not a practitioner-signup page). This gives the practitioner a reason to *want* the seal (earns referral rebates).
- **Brand content (logo, accent colour, practice name, contact) is sourced from the existing portal _public profile_** — *positioning, not new capture.* **NB: the public profile shipped on `staging`, not `main`** (see §9).
- **Skin is a live property:** on lapse, every artifact (incl. already-shared) **live-reverts to the homefit default** — renewal pressure intended; per-publish-date retention was **rejected**.
- Side effect: monetises **free-only practitioners** (buy credits purely for the skin).

---

## 7. The mockup built + PENDING FEEDBACK

**File:** `docs/design/mockups/2026-05-26-my-workouts-artifacts.html` (self-contained; phone frame + annotated legend).

**Locked visual decisions it embodies:**
- **My Workouts = one recency-sorted, badged list** (no split sections, no tabs).
- **Cards are thumbnail-led with a kind glyph corner badge** (top-left); single-coral brand, **no per-kind colour**.
- **Provenance:** received/claimed cards carry the **practitioner's avatar (coral-tint initials) + "From {Name} · {Practice}" + a "View-only" tag**; authored cards lead with "You", a Published/Draft state, and a trailing **edit-pencil** (received cards get a chevron).
- **Publish gate** decision (for the next mockup): **checklist with per-row price + live running total**.

**Carl has NOT yet answered these two questions — collect them first:**
1. **Provenance via practitioner-avatar presence** (subtle) vs a louder explicit "Shared" chip/banner — is the avatar + "From…" + View-only distinct *enough*?
2. **Edit-pencil (yours) vs chevron (received)** as the tell — does it land, or too subtle?

Iterate the mockup against his answers, then move on.

---

## 8. Remaining surfaces to mock (the visual backlog)

In rough priority order (Carl picked "all four" earlier; My Workouts done):
1. **Publish gate** — multi-select checklist, per-kind price, **nothing pre-checked**, live running total, free rows ($0) shown, already-enabled kinds marked. Mobile (Flutter) surface.
2. **`/o/` overview page** — the free interactive page: hero-frame exercise list, claim CTA, QR + version stamp, Print/Save-PDF button, the permanent "powered by homefit" seal, consent-gated treatment toggle. **Web** surface (R-10: it's the client-facing web counterpart).
3. **Share sheet** — the "WhatsApp or email?" split (managed-email path vs OS share sheet). Mobile.
4. **Client web account + web My Workouts** — the new auth/claim surface on `session.homefit.studio` (the spanning-identity consumer home). Web.
5. **Consumer consent panel** — "my practitioners / my data", one panel per linked practice (grain is fixed; layout is open). Web/app.
6. **Smaller:** per-plan artifact-status display in Studio ("overview live · player published · reel not yet"); the edit-lock chip (now paid-only); the brand-skin seal placements per artifact type.

---

## 9. Conventions & constraints you MUST follow

**Mockup house pattern** (`docs/design/mockups/`):
- Self-contained single-file HTML, **dated filename** (`YYYY-MM-DD-<name>.html`), inline `<style>` with a **CSS-variable token block** at `:root`, dark background, **phone frame** (~360–380 × 640–760, `border-radius` ~32–36px), annotated **legend/anatomy panels** beside the phone with explanatory notes. See the My Workouts file and `2026-05-25-exercise-clipboard.html` as templates. Some mockups also have PNG screenshots committed alongside — you can render those (the cloud agent couldn't).

**Brand tokens** (canonical: `docs/design/project/tokens.json` v1.2; mirrors `app/lib/theme.dart`, `web-player/styles.css`):
- **Coral `#FF6B35`** — the **single accent**, never paired with a second brand colour. Dark `#E85A24`, light `#FF8F5E`, tint-bg `rgba(255,107,53,0.12)`, tint-border `rgba(255,107,53,0.30)`.
- **Sage / rest `#86EFAC`** — a distinct *category* (rest periods), **not** an accent.
- Surfaces: bg `#0F1117`, base `#1A1D27`, raised `#242733`, border `#2E3140`.
- Ink: primary `#F0F0F5`, secondary `#9CA3AF`, muted `#6B7280`, disabled `#4B5563`.
- Type: **Montserrat** (display/headings 600–800), **Inter** (body 400–700).

**Design Rules (binding):**
- **R-01** — no modal confirmations; destructive actions fire immediately + undo SnackBar + 7-day recycle bin. The claim chip must obey this (escalate, never wall).
- **R-10** — mobile ↔ web player parity: a player UX change must land in **both** `app/lib/screens/plan_preview_screen.dart`/`widgets/progress_pill_matrix.dart` **and** `web-player/`. Relevant when the overview page / player visuals get implemented.
- **Single coral accent** — no competing accents; glyphs monochrome; coral reserved for state/identity cues.
- **R-06** — "practitioner" vocabulary (never bio/physio/trainer/coach in UI). Client-facing copy uses `{TrainerName}` / "your practitioner".

**Repo / environment reality:**
- This branch is based on **`main`**. The **self-trainer wave + Safe Mode transparency wave (incl. the portal _public profile_, the `plan_invitations` table, the My Workouts tab, `plan_artifacts` usage) shipped to `staging`, not `main`.** So when you grep `main` for the public profile / brand fields / plan_invitations you will **not** find them — they exist on `staging`. Confirm exact field names against `staging` (or `origin/staging`) when you need real column names.
- `plan_artifacts` skeleton (ADR 0022): columns `id, plan_id, kind, status, output_url, generated_at, error_message, metadata`, `UNIQUE(plan_id, kind)`, `kind CHECK ('plan_url')` only, **RPC-write-only**. The design widens `kind` and adds `published_at`, `credits_charged`, `first_opened_at` (see the doc's Schema deltas — all **proposed**).
- Relevant ADRs: **0007** (credit model), **0016** (edit-lock grace), **0021** (Safe Mode subscription, credit-denominated — the pattern brand-skin follows), **0022** (`plan_artifacts`). New ADRs to ratify are listed in `ARTIFACT_SYSTEM.md` → "ADRs to ratify".
- The cloud agent is **subscribed to PR #516 activity** (it gets webhook events for CI/comments). If you take over locally, coordinate so you don't both act on the same PR events.

---

## 10. OPEN questions (not yet decided — don't assume answers)

1. **Consumer identity model** — are claimed clients `auth.users`? Exact `client_accounts` ↔ practice-`clients` link-table shape? (Grain = consumer × practice is fixed; the table isn't.)
2. **Analytics event vocabulary** — confirm per-artifact event sets vs one sparse universal schema.
3. **Analytics actionability** — confirm display-first, nudges as fast-follow.
4. **Practitioner contact view** — show "claimed · linked" status only, or expose the consumer's verified email?
5. **Premium pricing** — `reel`/`ai_reel` (and whether `poster`/`calendar` are free or token-priced).
6. **Render infra for materialised kinds** — reel transcode + bucket + cache + signed-URL lifetime.
7. **Kind naming** — `overview` vs `handout` vs `lobby_page`.
8. **Consumer consent UI layout** — the "my practitioners / my data" panel.
9. **Collaboration** — the whole anchored-comms feature (parked).
10. **Brand-skin positioning** per artifact type + confirm public-profile field names on `staging`.
11. **Brand-skin price** — ~2 credits/month is the working number; confirm.

---

## 11. Carl's working style (so you pick up smoothly)

- **He wants to be grilled.** On consequential/architectural decisions he explicitly asks to be challenged *before* you design. Push back hard, surface traps, make him defend. He changed his mind on the biggest decision of the session (mandatory login) after being grilled, and thanked the process. Don't just agree.
- **Use forced-choice questions for forks** (the cloud agent used `AskUserQuestion`-style pickers), but he'll **dismiss** them if they're premature — that's a signal to step back, not push.
- **Plain language.** He flagged one response as "above my head" — when a point gets abstract, reground it in a concrete scenario (a specific practitioner/patient doing a specific thing).
- **He hands off direction** once he trusts the thread ("you guide from here") — be willing to make the call and state it.
- **Keep the doc current.** He values not letting `ARTIFACT_SYSTEM.md` drift behind the conversation; fold resolved decisions in promptly.
- **Monetization ethos: "free as much as possible."** Money comes from *enhancement* (brand-skin), *richer formats* (player, reels), and *real costs* (Safe Mode) — never from gating the entry/flow.
- He's on iOS / Mac; he likes to *see* things (hence this handover — open mockups in Safari for him).

---

## 12. Git state at handover

- Branch `claude/artifact-system-design-hQNqE`, pushed, tracking `origin`.
- Commits this session (newest last): doc created → consolidated rewrite → brand-skin section → My Workouts mockup → this handover.
- PR **#516** open as **draft** against `main`. CI is green/expected-skips for a docs-only PR (Vercel/Supabase skip, Flutter/portal pass).
- Nothing is merged. All work lives on the feature branch.
