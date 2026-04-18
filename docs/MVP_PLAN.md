# homefit.studio — MVP Plan

**Created:** 2026-04-18
**Target date:** 2026-05-02 (14 days)
**Status:** Active

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

## Referral / affiliate model (signed off)

- **Code shape:** opaque short random code, 6–8 chars (e.g. `m7xk3q`). No practice name or owner email leaked.
- **Signup URL:** `https://manage.homefit.studio/join/{code}` (captures `code` into a cookie or pending-signup row until sign-in completes).
- **Trigger:** referee's **first paid purchase** (not signup — signup is cheap signal).
- **Reward:** both-sided, credits only.
  - Referrer gets **+10 credits** (≈ R250 of value at starter bundle pricing).
  - Referee gets **+10 bonus credits** at the moment their first bundle lands.
- **Cap:** one-time per referee. No ongoing commission — PayFast revenue-share is out of scope for MVP.
- **Visible on:** `/dashboard` — "Share with colleagues" card with copyable link + current referral stats (how many practices joined, how many credits earned).
- **Integration point:** PayFast webhook (`payfast-webhook` edge function) extends to check for pending referral on first `credit_ledger` insert of type `purchase` for a practice, and emits the bonus rows atomically.

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

1. **Finish D4 sandbox smoke test** (Carl, 5 min) — complete the remaining 3 steps of yesterday's PayFast sandbox checkout to sign off D4 sandbox.
2. **D4 production PayFast cutover** — blocked on Carl's merchant account. When unblocked: flip `PAYFAST_SANDBOX=false`, swap merchant ID + key in Vercel + Supabase secrets.
3. **D2 — Flutter practice picker** — publish-screen dropdown with practices the trainer belongs to, credit balance per practice, cost of the current plan, clear "which practice pays" UX.
4. **Referral schema + RPC + web-portal UI**:
   - `referral_codes` table (practice_id → opaque code, uniqueness enforced)
   - `practice_referrals` table (referrer_practice → referee_practice, status, reward metadata)
   - `generate_referral_code(practice_id)` SECURITY DEFINER RPC
   - `claim_referral_code(code)` called at signup time (stores pending referral on the new practice)
   - `/dashboard` card: code + shareable link + copy button + stats
   - `/join/{code}` public route that sets a signed cookie and redirects to signup
5. **First-run onboarding polish** — post-signup flow:
   - Create practice with auto-generated name (editable)
   - 5 welcome credits visible with "credits explained" tooltip
   - Explicit "invite a colleague and you both get 10 credits" CTA
   - Link to first publish tutorial (can be a simple modal, not video)
6. **POPIA privacy + terms of service page** — `/legal/privacy` + `/legal/terms`. Linked from portal footer, web player footer, sign-up gate. Carl reviews text before ship.
7. **Support surface** — `support@homefit.studio` (or similar) that routes to Carl. Linked in portal footer, Flutter app "Help" screen, web player error states. At minimum: forwards to Carl's email.

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
