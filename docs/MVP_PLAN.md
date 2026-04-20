# homefit.studio — MVP Plan

**Created:** 2026-04-18
**Target date:** 2026-05-02 (14 days)
**Status:** Active — end-of-day-1 checkpoint 2026-04-18

## Framing

POV passed. The system captures → converts → publishes → shares end-to-end with auth + RLS + credits + audit all live, and the web portal is serving at `manage.homefit.studio` with Google sign-in working. We're now working on MVP: the first version that survives strangers touching it with real money.

## MVP success criteria

1. **Second real bio (Melissa) is onboarded and happy** — she self-serves the full signup → first publish flow without Carl in the loop, and feels safe endorsing it to her network.
2. **Organic growth loop exists** — every practice has a shareable referral code that grants both-sided credits on the referee's first paid purchase.
3. **Money flows for real** — PayFast production credentials live, a real bundle purchase has completed end-to-end, credits landed in the ledger.
4. **No dead ends** — every error state has an explainable message, a retry path, or a support route. Publish failures are visible in-app.
5. **Privacy is real** — POPIA-compliant privacy page + terms of service linked from portal footer, web player footer, and sign-up gate.
6. **Look and feel is production-grade across all three surfaces** — Flutter app, web player (`session.homefit.studio`), and web portal (`manage.homefit.studio`) share a consistent, polished aesthetic. Every empty state, loading state, error state, and micro-interaction is intentional. Melissa's endorsement depends on it feeling professional to her clients, not just functional to her.

## Who Melissa is — and what she implies

- Carl's own biokineticist. Warm relationship, tolerates friction in her own experience.
- **High-influence node.** Large professional network in SA physio/bio circles. If she endorses → potential multiplier effect. If she quietly stops using it → nobody in her network ever hears about it.
- **Her clients are the visible face of her endorsement.** The WhatsApp plan link → web player experience needs to feel professional. A dodgy preview or a video that won't play reflects on *her*, not us.
- **Healthcare context matters.** POPIA, client confidentiality, brand integrity all have to be tight. Referral language stays peer-to-peer ("practitioner network"), never consumer-coupon ("earn rewards!").
- Planned onboarding date: **mid-Week 2** (around 2026-04-27).

## Referral / affiliate model (updated Milestone M, 2026-04-20)

- **Code shape:** opaque 7-char code from an unambiguous alphabet (no i/l/o/0/1). No practice name or owner email leaked.
- **Signup URL:** `https://session.homefit.studio/r/{code}` (captures `code` into a cookie until sign-in completes via Google OAuth).
- **Signup bonuses (at signup, NOT first purchase):**
  - Organic signup: **+3 credits** (`signup_bonus` ledger kind) — lets new practitioners try a publish or two before paying.
  - Referral claim: **+5 credits** on top (`referral_signup_bonus`) — net 8 total for referees.
- **Lifetime rebate (on every referee purchase):** **5%** of purchase amount, in credits, to the referrer. Fractional — stored as `numeric(10,4)` in `referral_rebate_ledger`.
- **Goodwill floor (first rebate only):** if `5% × purchase < 1`, round UP to 1 credit. Tracked via `practice_referrals.goodwill_floor_applied`. Covers the tiny-first-bundle case so a R250 starter bundle still pays the referrer something meaningful.
- **Cap:** single-tier only (A→B→C pays A nothing from C), enforced by DB trigger.
- **Visible on:** `/network` — "Share kit" card with copyable link + `/r/{code}` pitches + `Network rebate` stats.
- **Integration point:** PayFast webhook routes through `record_purchase_with_rebates` SECURITY DEFINER RPC, which wraps the `credit_ledger` purchase row + any `referral_rebate_ledger` rows in one transaction.

## Cross-cutting workstream — design polish

Running alongside Weeks 1 & 2, not a standalone item. Every screen touched gets a polish pass before it ships. Scope:

- **Brand consistency across surfaces.** Pulse Mark, coral `#FF6B35`, Montserrat/Inter, dark-first. Shared tokens reviewed: `app/lib/theme.dart` ↔ `web-player/styles.css` ↔ web-portal Tailwind config.
- **Empty / loading / error states** — every list, every form, every async boundary. No raw spinners, no raw error strings.
- **Micro-interactions** — transitions, haptics (iOS), hover/focus states (web), form validation feedback. Consistent timing + easing.
- **Typography rhythm** — heading / body / caption hierarchy consistent across all three surfaces.
- **Spacing rhythm** — a shared spacing scale (4/8/12/16/24/32) applied consistently. No one-off gaps.
- **Accessibility baseline** — WCAG 2.1 AA colour contrast, keyboard nav on web, touch targets ≥ 44pt on mobile.

**Approach:**

1. **Audit pass first.** Run a structured design critique on all three surfaces against WCAG + brand consistency. Produces a prioritised hit-list of concrete items (not vibes). Spawns as a design-critique agent this week.
2. **Fix in-place as we ship.** Every Week 1/2 feature touches screens — each screen gets the critique items fixed before merge, not after.
3. **Second pass during Week 2.** Once features stabilise, a final consistency sweep: padding rhythm, typography scale, dark-palette uniformity.

**Surfaces in priority order:**

1. **Web player (`session.homefit.studio`)** — highest priority. What Melissa's clients see. Her endorsement's visible face.
2. **Flutter app** — what Melissa uses daily. Polish drives retention.
3. **Web portal (`manage.homefit.studio`)** — important but touched less often per user. Sign-in + dashboard + credits pages are the critical surfaces.

## Week-by-week cut

### Week 1 (2026-04-18 → 2026-04-24) — Melissa-ready infrastructure

**End-of-day-1 (2026-04-18) — shipped ahead of the Week-1 plan:**

- [x] **Brand design system v1.1** — tokens.json + components.md (Gutter Rail, Inline Action Tray, Thumbnail Peek, Circuit Control Sheet) + voice.md (practitioner vocabulary) + Design Rules R-01..R-08. Commit `0bfb252`.
- [x] **Studio redesign components** — Gutter Rail, Inline Action Tray, Thumbnail Peek, Circuit Control Sheet. Commit `e12b2fd`. (Layout blow-out bug is the live blocker — see below.)
- [x] **Auth pivot to email + password + magic-link** — `feat/auth-progressive-upgrade`, confirmed working on device. Google parked, Apple still scaffolded. Merge pending final walk-through.
- [x] **Build-marker infrastructure** — short SHA in Pulse Mark footer via `--dart-define`. `install-sim.sh` + `install-device.sh` wire automatically. Commit `808addb`.
- [x] **VPN constraint resolved** — device installs work with VPN on. No handoff dance needed.

**Week-1 work items:**

1. **Finish D4 sandbox smoke test** (Carl, 5 min) — complete the remaining 3 steps of yesterday's PayFast sandbox checkout to sign off D4 sandbox.
2. **D4 production PayFast cutover** — blocked on Carl's merchant account. When unblocked: flip `PAYFAST_SANDBOX=false`, swap merchant ID + key in Vercel + Supabase secrets.
3. **Studio layout bug fix** — BLOCKING. Plans with circuits blow the list to multi-viewport heights. Two fixes attempted on main (`9bfc0f8` `MainAxisSize.min`, `326c6b8` Stack-rail rewrite) didn't land. Third attempt on `fix/studio-reorderable-listview` swaps `CustomScrollView + SliverReorderableList` for plain `ReorderableListView.builder`. Needs device verification → merge.
4. **Progress-pill matrix + ETA widget** — `feat/progress-pills`. Flutter widget + web player port + ETA (`7:42 left` + `~7:42 PM`, wall-clock drift when paused) pending. Merge after ETA follow-up agent lands.
5. **D2 — Flutter practice picker** — publish-screen dropdown with practices the practitioner belongs to, credit balance per practice, cost of the current plan, clear "which practice pays" UX.
6. **Three-treatment video model — schema + UI**:
   - Schema: `clients` table, `exercises.media_treatment` enum (`line | bw | colour`), `clients.video_consent` jsonb per-exercise consent map.
   - Per-client consent gate in first-plan flow; sticky per client. Colour requires explicit consent.
   - Per-exercise picker in Studio (three-tab segment control on expanded card).
   - Treatment change past 24h = credit-consuming edit.
   - Private `raw-archive` bucket (service-role-only, 720p H.264 match local archive, retention until practice deletion).
   - Raw video upload wired into the publish flow async.
7. **Referral schema + RPC + web-portal UI**:
   - `referral_codes` table (practice_id → opaque code, uniqueness enforced)
   - `practice_referrals` table (referrer_practice → referee_practice, status, reward metadata)
   - `generate_referral_code(practice_id)` SECURITY DEFINER RPC
   - `claim_referral_code(code)` called at signup time (stores pending referral on the new practice)
   - `/dashboard` card: code + shareable link + copy button + stats
   - `/join/{code}` public route that sets a signed cookie and redirects to signup
8. **First-run onboarding polish** — post-signup flow:
   - Create practice with auto-generated name (editable)
   - 5 welcome credits visible with "credits explained" tooltip
   - Explicit "invite a colleague and you both get 10 credits" CTA
   - Link to first publish tutorial (can be a simple modal, not video)
9. **POPIA privacy + terms of service page** — `/legal/privacy` + `/legal/terms`. Linked from portal footer, web player footer, sign-up gate. Carl reviews text before ship.
10. **Support surface** — `support@homefit.studio` (or similar) that routes to Carl. Linked in portal footer, Flutter app "Help" screen, web player error states. At minimum: forwards to Carl's email.
11. **Supabase JWT expiry bump** (Carl, 1 min) — Project Settings → Auth → 30 → 90 days for longer offline-session runway.

### Week 2 (2026-04-25 → 2026-05-02) — growth loop + trust

8. **Referral reward trigger** — extend `payfast-webhook` to detect first paid purchase → insert both-sided credit bonuses atomically (same transaction as the purchase ledger row).
9. **Practice member invite flow** — magic-link-based, for adding receptionist or another physio to an existing practice. Separate from referrals (no money flows, invitee joins shared credit pool).
10. **Publish-attempt log in-app** — Flutter Home screen shows "last publish attempt" with timestamp + success/fail + retry button if failed. Bio can see what happened without calling Carl.
11. **Production smoke-test checklist + rollback plan** — written document Carl runs before flipping to production PayFast. Includes DB backup pointer, revert commits for each of the 11 MVP items, edge function rollback procedure.
12. **Melissa onboards mid-Week 2** — send her the link. Shadow her through her first session if she wants, but don't intervene in the flow itself (that's the actual test).
13. **Iterate on Melissa's feedback** — 2-3 days of bug/UX triage based on her real usage. Ideally she invites 2-3 peers during this window → validate the growth loop before MVP cutoff.

## Deferred past MVP (explicitly)

- **Android app** — iOS only for MVP. Swift native pipeline stays the cornerstone.
- **AI style transfer** (Stability AI, Kling O1, SayMotion) — still premium-tier, still parked.
- **Filter workbench cloud archive** — dev tool. Not customer-facing.
- **Pull-to-latch scroll physics** — parked per Carl's earlier decision.
- **Ongoing referral commission** (rev-share on every purchase) — PayFast complexity not worth MVP budget.
- **iPhone-model-locked features** (LiDAR, etc.) — Carl's rule: no device-capability gates.
- **Apple Sign-In activation** — waits for Apple Developer Program approval (~24-48h from 2026-04-17). When ready, flip `_appleEnabled = true` in `sign_in_screen.dart`.
- **Web portal member invite UX polish** — Week 2 #9 is functional, not pretty. Polish post-MVP.

## Risks to MVP timeline

- **PayFast production cutover blocked on Carl's merchant account signup.** Independent of everything else — if Carl doesn't kick that off Week 1, Week 2 rewards trigger can't be tested with real money.
- **Apple Developer approval might not arrive in time.** Mitigated: Apple button stays scaffolded + disabled. Doesn't block MVP.
- **Melissa's iPhone model / iOS version.** If she's on something unusual, device-matrix risks surface late.
- **Referral fraud vectors** — self-referral (creating two accounts to double-dip), code sharing on public forums. MVP accepts this risk; add rate-limits post-MVP if abuse emerges.

## Ownership

- **Carl:** PayFast merchant signup, legal text review (POPIA/terms), Melissa relationship + intro, iPhone device testing, final QA signoff.
- **Claude (sub-agents):** schema, RPCs, Dart UI, Next.js pages, edge function extensions, onboarding copy, smoke-test docs.
- **Blocked-on-human items explicitly flagged** — D4 production + legal review + Apple approval.
