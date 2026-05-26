# Wave 2 — Artifact system: claim flow + consumer identity

**Status:** queued for QA after the Wave 2 PR lands on staging.

**Scope:** the consumer-side surfaces minted by Wave 2 — `/me` (magic-link
claim + signed-in My Workouts) and `/me/data` (per-practice consent panel).
Plus the click-through from the existing `/h/{planId}` handout claim chip.

**Prerequisite (blocker):** the Supabase Auth config change in
[`docs/handoffs/2026-05-26-wave2-auth-config-needed.md`](../handoffs/2026-05-26-wave2-auth-config-needed.md)
must be applied to **staging** before items 4+ can pass. Items 1–3 work
unauthenticated and can be exercised the moment the PR's preview deploy is
green.

**Where to test:** the per-PR Vercel preview URL on the
`feat/artifact-claim-consumer-identity` branch — both the web-player and
web-portal previews. Use a real iPhone Safari + a desktop browser for
cross-surface parity.

## Test list

### Anonymous (no Supabase Auth config change required)

- [ ] **1.** Open the per-PR preview URL at `/me` directly with no query
      string. The page renders the "All the plans your practitioners share,
      in one place" explainer card + the magic-link email form. The
      attaching banner (the coral chip that says "We'll save **this plan**
      to your home as soon as you sign in") is **hidden**. The matrix logo
      renders top-left and the `.studio` wordmark dot + word are **coral**.

- [ ] **2.** Open `/me?claim=<some-uuid>` in a fresh anonymous tab. The
      same form renders, but the attaching banner is now **visible** above
      the email input. Submitting the form (with any valid-looking email)
      transitions to the "Check your email" card with the entered email
      echoed in the body.

- [ ] **3.** Open any existing published plan at `/h/{planId}` (e.g. from a
      staging plan you've published with a handout). The "Save this plan to
      your phone" coral chip at the top-right is **clickable** (Wave 1
      shipped it as a no-op TODO; Wave 2 wires the click). Tapping it
      navigates the browser to `/me?claim={planId}` and the attaching
      banner surfaces (item 2 confirms).

### After Carl applies the Supabase Auth config (handoff doc)

- [ ] **4.** Submit the magic-link form on `/me` with your real inbox
      address. Within ~30 seconds you receive a `noreply@homefit.studio`
      email (the dark + coral template). The link in the email points at
      `https://<supabase-project>.supabase.co/auth/v1/verify?...&redirect_to=https%3A%2F%2F<preview-host>%2Fme`.

- [ ] **5.** Tap the magic-link in the email on the SAME device. You land
      on `/me` with a brief loading spinner, then the signed-in My Workouts
      state. The header shows the matrix logo + "My Workouts" title + an
      avatar chip in the top-right whose initials derive from your email
      local-part (e.g. `jd@example.com` → `JD`).

- [ ] **6.** On a fresh Supabase user (no prior claims), the signed-in
      state shows the empty card ("No saved plans yet. When your
      practitioner sends you a workout, open the link and tap 'Save this
      plan to your phone' — it lands here.").

- [ ] **7.** Repeat the flow from a `/h/{planId}` link belonging to a real
      published plan that has a `clients` row attached. Tap the claim chip,
      enter your email, click the magic-link. On landing at `/me`:
      - The empty state is **gone** — one plan card appears.
      - The card carries the artifact-kind glyph (player vs handout), the
        plan title, "N exercises · updated X ago".
      - The bottom coral-tint provenance banner shows the practitioner's
        initials avatar + name + practice name + sage live-dot.

- [ ] **8.** Tap the plan card on `/me`. It navigates to the appropriate
      surface — `/p/{planId}` for `Workout player` rows, `/h/{planId}` for
      `Workout handout` rows.

- [ ] **9.** Re-claim the same plan (open `/h/{planId}` in another tab,
      tap the chip, sign in again with the same email). The second claim
      is **idempotent** — no duplicate cards appear on `/me`. Check the
      browser console: `[me] claim failed` should NOT log; the `claim_plan`
      RPC returns `{ok: true, already_claimed: true}`.

- [ ] **10.** From `/me`, tap "Settings · N practitioners linked". You
      navigate to `/me/data`. The header shows the matrix logo + "Your
      data" title + a "Back" link top-right. Below: the intro card with
      the coral first-visit chip ("Here's what's currently shared — you
      can change it.").

- [ ] **11.** Each practice you've claimed surfaces as a card. The card
      header has a coral practitioner avatar (initials), the practitioner
      display name (derived from email local part), and the practice name.
      Below: six toggle rows in this exact order — Line drawing (locked,
      coral non-tappable pill + lock glyph), Black & white video, Original
      video, Profile photo, Face fingerprint, Workout stats.

- [ ] **12.** Tap the "Line drawing" pill on any card. **Nothing happens**
      — the pill stays in the locked-on state. The cursor doesn't change
      to a pointer. (The lock is decision #27 in the design doc.)

- [ ] **13.** Tap any other toggle. The pill animates to the new state
      immediately (optimistic). After ~200ms the "Saved" toast briefly
      appears at the bottom of the page (~1.8s lifetime). Reload `/me/data`
      — the new state persists.

- [ ] **14.** Tap a toggle, then very quickly inspect the network tab. A
      `POST /rest/v1/rpc/set_my_consent` fires with the body
      `{p_practice_client_id: "...", p_consent: {"<key>": <bool>}}` (a
      single-key patch, not the full six). Response 200; body
      `{ok: true, before: {...}, after: {...}}`.

- [ ] **15.** Open Supabase staging studio → audit_events. After flipping
      a toggle in item 13 the table shows a fresh row with `kind =
      'consumer.consent.update'`, `actor_id` = your consumer user UUID,
      `ref_id` = the practice_client_id, and `meta.from` / `meta.to`
      carrying the before/after consent jsonbs.

- [ ] **16.** Flip "Workout stats" ON for any practice. Then tap the
      bottom "Stop all stats" master switch. The pill animates ON, every
      per-card "Workout stats" pill across every practice card animates
      OFF, and a "Stats off everywhere" toast appears. Reload — the state
      persists.

- [ ] **17.** From the signed-in `/me`, tap "Sign out" (the pill on the
      right of the settings row). The page returns to the claim/sign-in
      state. Local storage no longer has `homefit.consumer.session.v1`.

- [ ] **18.** Open `/me/data` directly while NOT signed in (open in a
      fresh incognito window). The page should redirect to `/me` (a quick
      flash, then the claim form renders). No flash of the consent panel.

### Multi-practitioner spanning identity

Item 19 needs a SECOND practice with a SECOND published plan claimed by the
same email — exercise this if there are two staging practices with shared
client emails. Skip if not feasible.

- [ ] **19.** With the consumer signed in and linked to two practices, the
      `/me` settings sub-label reads "· 2 practitioners linked", and
      `/me/data` shows TWO cards stacked, one per practice. Each card has
      its OWN set of six toggle states; flipping a toggle on practice A
      does NOT change the matching toggle on practice B.

## Known limitations (out of scope for this wave)

- No Apple / Google sign-in — magic-link only (decision #12).
- No "back to handout" return arrow after signing in via a `/h/` chip —
  the consumer lands on `/me` and finds their plan in the list. A
  future improvement could deep-link straight back to the source artifact.
- No portal audit-feed surface for the new `artifact.claimed` /
  `consumer.consent.update` event kinds yet — they land in
  `audit_events` correctly but the portal Audit page doesn't render them
  (Wave 6 territory).
- Brand-skin overrides on `/me` + `/me/data` are intentionally **not**
  shipped — these surfaces stay homefit-coral regardless of which
  practitioner the consumer is linked to (locked in
  `docs/ARTIFACT_SYSTEM.md` Visual surfaces section).
