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

1. **Practice mode** (creator) — what exists today. Practitioners build plans for clients (1-on-1, credit-gated publish) and, future, classes (1-to-many, subscription / once-off monetization).
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
| Credits chip | Visible | **Hidden** (subscription monetization) | Hidden |
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

### 2. My Workouts real surface

When the locked teaser ships its real implementation, the body becomes a list of imported plans + subscribed classes. The mockup already shows the visual model:

- Each row = a content card with sage glyph (practitioner-sent) or coral glyph (subscribed class)
- Tap → opens the plan player (same `web-player/` codebase, but bundled in-app via WebView or — better — ported to native Flutter screens that reuse the existing `app/lib/screens/plan_preview_screen.dart` engine).
- No bottom CTA today; later: "Add a workout" → opens a paste-link / scan-QR sheet for power-user import (alternative to the email path).
- **No practice context, no credits.** Consumer mode is identity-clean.

**Data model:**
- `consumer_profiles` (or just lean on `auth.users` + a flag column) — keyed off the consumer's `auth.users.id`, tracks email, display name, opt-ins. No practice membership.
- `consumer_workouts` view — joins `plan_invitations.accepted_by_user_id = current_user.id` with `plans` for the list query.
- Future: `consumer_class_subscriptions` for class-side content.

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

- New data model: `classes` table (plan-like but with subscription / one-time pricing, capacity, possibly cohort scheduling).
- New publish flow: same Studio editor, but the "publish" action produces a class rather than a single-client plan.
- Monetization: subscription (PayFast recurring or App Store IAP) or one-time purchase. **Credits don't apply** — the practitioner is paid per consumer-side purchase, not per publish.
- Consumer side: a class shows up in their My Workouts list with the coral "Subscribed class" / "Purchased class" pill (mockup already shows the visual).
- Re-uses the email-magic-link bridge from section 1 for sending class invites to specific people.

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
10. **PR — Class subscription monetization (PayFast recurring or App Store IAP)** — the commercial layer.
11. **PR — Power-user "Add a workout" paste-link import** — post-MVP fallback path.

Each step is small enough to design + review + ship without rework on the others. Steps 2-4 unblock the lobby CTA; steps 5-7 unblock My Workouts; steps 8-10 unblock Classes. Step 11 is independent.

---

## Decisions log (chronological)

- **2026-05-13** — Two-capsule layout chosen over three-segment / bottom-tab-bar / PageView. Practice + My Workouts capsules side-by-side; chips below scope row.
- **2026-05-13** — Naming locked: "Clients", "Classes", "My Workouts".
- **2026-05-13** — First-launch routing: intent-inferred (no choose-your-side splash).
- **2026-05-13** — Import bridge: email-magic-link via `plan_invitations` (not clipboard sniff, not manual paste). Unified pipeline for self-service and practitioner-initiated invites.
- **2026-05-13** — TestFlight v2 ships front-end shell only; backend deferred to a sequence of follow-up PRs (this doc).
- **2026-05-13** — Web-player lobby CTA included in TestFlight v2 with a no-op "coming soon" toast on submit.

---

## Non-goals

Documented here so we don't accidentally drift back into them:

- A single unified "Library" view that intermixes Clients and My Workouts content. The mental model is two distinct *identities*, not one bucket of stuff.
- A choose-your-side first-run splash. Considered and rejected — friction without value when arrival context already disambiguates.
- A clipboard-sniff deferred deep link. iOS would surface a privacy banner on every cold launch.
- Auto-claiming a public link the moment a signed-in user views it. Considered but rejected — ambiguity around shared-with-spouse cases. The user must explicitly opt in via the email path.
- A "Programs" or "Marketplace" third top-level scope at the same level as the two existing capsules. If a third identity emerges, it gets its own capsule on the row; we don't conflate creator and consumer surfaces.
