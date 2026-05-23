# Safe Mode Transparency — design

**Status:** approved 2026-05-22 (Carl) · ready for implementation plan
**Predecessor:** Safe Mode Phase 1 + Phase 2 (PR #389), Safe Mode completion (PR #402 + #403), Persistent banner + hysteresis (PR #413 + #420). This design adds the externally-verifiable layer on top: identity disclosure, public transparency, and reporting routed to the venue.
**Mockups:**
- [docs/design/mockups/safe-mode-poster.html](../design/mockups/safe-mode-poster.html) — printable A4 poster.
- [docs/design/mockups/safe-mode-live-page.html](../design/mockups/safe-mode-live-page.html) — live activity page.

## Table of contents

- [Purpose](#purpose)
- [Scope summary](#scope-summary)
- [The transparency contract](#the-transparency-contract)
- [Six-point Safe Mode gate](#six-point-safe-mode-gate)
- [Data model](#data-model)
- [Identity flow (practitioner-side)](#identity-flow-practitioner-side)
- [Live transparency page](#live-transparency-page)
- [Printable poster](#printable-poster)
- [Reporting flow](#reporting-flow)
- [Heartbeat + polling cadence](#heartbeat--polling-cadence)
- [Practice profile gate (owner-side)](#practice-profile-gate-owner-side)
- [Migration plan](#migration-plan)
- [Phasing](#phasing)
- [Risks](#risks)
- [Out of scope for V1](#out-of-scope-for-v1)

## Purpose

Today, Safe Mode is a real privacy feature on the platform — but it's invisible to anyone standing in the room. A gym owner can't tell a homefit.studio practitioner apart from someone using the iPhone camera app. The privacy contract holds for the bystander's IMAGE (obscured in any capture), but not for the bystander's TRUST (they have no way to know what's happening or who's responsible).

This design closes that gap. It makes Safe Mode externally verifiable: anyone in the venue can scan a QR code and see, in real-time, who is recording, who they are, and where they are — and report them to the venue owner directly if something feels off.

The trade is symmetric: bystanders give up some privacy (their image, even obscured) → practitioners give up matching privacy (their full name, their face, their live location during a session, their practice's public profile). No anonymous filming. No half-set-up shells.

## Scope summary

- Practitioner identity becomes mandatory before Safe Mode can activate (auto or manual).
- Practice public profile becomes mandatory before any practitioner in that practice can use Safe Mode in any enforced polygon.
- New live transparency page at `session.homefit.studio/v/{slug}/now` shows active sessions in real-time with name + photo + position + report button.
- New printable poster, downloadable from the portal premises editor as a PDF (via browser print dialog).
- Reporting routes to the practice owner's listed contact — homefit.studio is escalation backstop only.
- Existing polled retry cycle (30s normal / 15s trailing) gains a compliance check; failures trigger the existing hysteresis deactivation.

## The transparency contract

The reciprocal trade is the design's anchor. Documenting it explicitly:

| Party | Gives up | Gets |
|---|---|---|
| Bystander | Their image in the capture frame (even though it's obscured) | Visibility into who is recording + ability to report directly to the venue |
| Practitioner | Full name, face photo, live position, practice profile information | Permission to capture in private/enforced spaces |
| Practice owner | Practice contact details + public profile | Accountability for their team's compliance; transparency proof for clients + venues |
| homefit.studio | Platform compute + storage | Trust as the verifiable layer |

The contract is binary: any practitioner who refuses any part of it cannot use Safe Mode. Practice owners who refuse cannot deploy their team into enforced polygons.

## Six-point Safe Mode gate

Before Safe Mode can transition to `active` (auto or manual), six conditions must ALL be true. Any one missing → `unavailable` state with a specific reason.

Practitioner-level (the person controls):

1. `first_name` set + non-empty.
2. `last_name` set + non-empty.
3. `avatar_url` set + face-detect verified at capture time.

Practice-level (the owner controls):

4. `public_slug` set on `practices` table.
5. `public_blurb` set + non-empty.
6. `public_profile_listed = true`.

No practice logo requirement — practitioner avatars carry the visual on the public profile + live page.

## Data model

### `users` / `practitioners` table

Add three columns to whatever currently holds practitioner identity (likely `auth.users.user_metadata` JSON, OR a new `practitioners` profile table — implementation choice).

```sql
-- Either as columns on a new practitioners table:
ALTER TABLE public.practitioners
  ADD COLUMN first_name text,
  ADD COLUMN last_name text,
  ADD COLUMN avatar_url text;

-- Constraints:
-- length(first_name) BETWEEN 1 AND 60
-- length(last_name) BETWEEN 1 AND 60
-- avatar_url ~ '^https://.+' (or specific storage path pattern)
```

### `practices` table

Existing columns from Public Profile v2 are reused as-is. No new columns.

### `active_capture_sessions` table (new)

Append-only-ish state table tracking current and recent capture sessions.

```sql
CREATE TABLE public.active_capture_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  practice_id uuid NOT NULL REFERENCES practices(id),
  trainer_id uuid NOT NULL REFERENCES auth.users(id),
  premises_id uuid REFERENCES premises(id), -- nullable for manual mode
  started_at timestamptz NOT NULL DEFAULT now(),
  last_heartbeat_at timestamptz NOT NULL DEFAULT now(),
  last_latitude double precision,
  last_longitude double precision,
  ended_at timestamptz, -- null while active
  manual_mode boolean NOT NULL DEFAULT false
);

-- Index for live-page reads (active sessions per polygon)
CREATE INDEX idx_active_sessions_practice_live
  ON active_capture_sessions (practice_id, ended_at)
  WHERE ended_at IS NULL;

-- Heartbeat staleness query
CREATE INDEX idx_active_sessions_heartbeat
  ON active_capture_sessions (last_heartbeat_at)
  WHERE ended_at IS NULL;
```

### `safe_mode_session_reports` table (new)

```sql
CREATE TABLE public.safe_mode_session_reports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id uuid NOT NULL REFERENCES active_capture_sessions(id),
  practice_id uuid NOT NULL REFERENCES practices(id),
  reporter_fingerprint text, -- stable client-side device fingerprint, no PII
  reason text NOT NULL CHECK (length(reason) BETWEEN 1 AND 500),
  reported_at timestamptz NOT NULL DEFAULT now(),
  practice_notified_at timestamptz, -- when the email/whatsapp was sent
  escalated_at timestamptz -- when homefit team picked it up if practice didn't respond
);
```

### `practitioner_audit_log` table (new, append-only)

```sql
CREATE TABLE public.practitioner_audit_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  trainer_id uuid NOT NULL REFERENCES auth.users(id),
  field text NOT NULL, -- 'first_name', 'last_name', 'avatar_url'
  old_value text,
  new_value text,
  changed_at timestamptz NOT NULL DEFAULT now()
);
```

## Identity flow (practitioner-side)

### Settings: profile-completion UI

Settings gains a new section "Public profile" (distinct from "Practice public profile" which lives on the portal):

- **Avatar** — circular display of current photo + "Update photo" button. Tap → in-app selfie capture using `image_picker` with `source: ImageSource.camera` + `preferredCameraDevice: front`. No gallery picker — selfie only.
- **First name** — single-line text field, max 60 chars.
- **Last name** — single-line text field, max 60 chars.

On save:

1. Run `VNDetectFaceRectanglesRequest` on the captured photo (native iOS). If no face → reject with "We need a clear photo of your face. Try again."
2. Upload photo to `media/avatars/{trainer_id}.jpg` via existing path-scoped storage policy.
3. Call new RPC `set_practitioner_profile(first_name, last_name, avatar_url)` — writes the row + appends to `practitioner_audit_log` per changed field.

### First-time disclosure card

Before the first save of name + photo, show a single full-screen disclosure card:

> **Heads up — this becomes public**
>
> Your name and photo will appear publicly on every venue's live transparency page when you record there using Safe Mode. Anyone scanning the venue's poster can see who you are.
>
> This is the trade: bystanders give up their image (obscured) → you give up your identity (public).
>
> [ Got it ] [ Cancel ]

Tap "Got it" → save proceeds. Tap "Cancel" → return to Settings without saving.

### Gate behavior on incomplete profile

When the practitioner attempts to engage Safe Mode (auto or manual) and any of the 6 gate points fails, the camera surface shows a permission-gate-style screen (analogous to the GPS gate from S-6):

- If practitioner-level points missing → "Add your name and photo in Settings to record in Safe Mode zones. This information is publicly visible." + [Open Settings] button.
- If practice-level points missing → "Your practice's public profile is incomplete. Ask your owner to set it up at manage.homefit.studio/public-profile. Until then, Safe Mode is disabled." + [Open Portal] button.

This is forced-flow (not blocking) — the practitioner can fix it inline and proceed.

## Live transparency page

Live at `session.homefit.studio/v/{slug}/now`. Anonymous-readable (no auth required).

### IA + mockup

See [docs/design/mockups/safe-mode-live-page.html](../design/mockups/safe-mode-live-page.html). Key elements:

- **Top bar** — practice logo (or initials fallback) + practice name + location · matrix logo on right.
- **Hero** — "**Recording right now**" with pulsing coral dot · sub-line explaining what Safe Mode is · "Updated Xs ago" timestamp.
- **Map (primary surface)** — 4:5 aspect ratio. Polygon outline (dashed coral). Active practitioners shown as floating cards anchored to their current GPS positions. Sage "You are here" dot when the viewer grants geolocation. Optional zone labels (decorative for V1; tied to floor plan in V2).
- **Practitioner cards** — avatar (40px) + full name (Montserrat 700) + duration + zone + Report button. Whole card is a link to `/v/{slug}` (the practice profile). Coral border + soft pulsing glow ring.
- **Explainer block** — "What is Safe Mode?" with link to /what-we-share.
- **Footer** — powered by homefit.studio with matrix logo.

### Polling cadence

Page polls a new anonymous-readable RPC every 10-15 seconds:

```sql
CREATE OR REPLACE FUNCTION public.get_live_sessions(p_slug text)
  RETURNS TABLE (...) -- session id, practitioner name + avatar, started_at, lat/lng, ...
  LANGUAGE plpgsql SECURITY DEFINER
AS $$
  -- Resolve practice_id from slug
  -- Return active_capture_sessions where last_heartbeat_at >= now() - 60s
  -- And ended_at IS NULL
$$;
```

No server-sent events / WebSockets for V1 — simple polling. Battery + network cost negligible at 10-15s cadence.

### Viewer's geolocation (sage "You" dot)

Pure client-side. On page load:

```js
if (navigator.geolocation) {
  navigator.geolocation.getCurrentPosition(
    (pos) => placeViewerDot(pos.coords.latitude, pos.coords.longitude),
    () => showGeoOptInButton(),
    { enableHighAccuracy: false, timeout: 5000 }
  );
}
```

The viewer's coordinates never hit our server. Dot is placed purely in the browser, anchored to the same polygon-projection math used for practitioner cards.

## Printable poster

Live at `manage.homefit.studio/premises/{id}/poster`. Owner-authenticated (only practice owner of the premises can view).

### IA + mockup

See [docs/design/mockups/safe-mode-poster.html](../design/mockups/safe-mode-poster.html). A4 size, light mode, ink-friendly. Key elements:

- **Header** — canonical `HomefitLogoLockup` (print variant — `homefit` ink-dark `#1A1D27`, `.studio` coral) at hero scale (left) + practice name + location (right).
- **Hero** — "**Recording** _is happening here._" + sub-line explaining bystander obscuring + practitioner identity disclosure.
- **Body grid** — left column: "What this means for you" with two paragraphs + caveat box about reporting; right column: QR card with QR code + scan instruction + URL.
- **Caveat box** — coral-bordered. "Worried about a practitioner's behavior? Scan the code, find their session, and tap 'Report'. The practice owner is notified directly via their listed contact and can act."
- **Trust strip** — "Learn more at homefit.studio/what-we-share" (left) + "powered by" with the canonical `HomefitLogoLockup` (print variant) at footer scale stacked below (right).

### PDF download

Owner clicks "Download poster" in the premises editor → opens `/premises/{id}/poster` in a new tab → JavaScript auto-fires `window.print()` on load → browser print dialog opens → owner picks "Save as PDF" → done.

No server-side PDF generation. The poster page has full `@media print` styling so the print preview matches the on-screen render exactly.

The same URL doubles as a preview — owner can visit it without printing to see what the poster looks like.

## Reporting flow

Tap "Report" on a practitioner card on the live page → modal opens:

```
Report {practitioner name}

This report will be sent to:
  MUSCLE WORKS GYM
  via {practice.contact_email or contact_whatsapp}

Reason (required):
[ textarea, max 500 chars ]

[ Cancel ] [ Send report ]
```

On submit, server-side flow:

1. Insert row into `safe_mode_session_reports`.
2. Send email / WhatsApp message to practice's listed contact (`contact_email` first, then `contact_whatsapp` if email not set).
3. Stamp `practice_notified_at`.
4. If `escalated_at IS NULL` after 48h AND no practice response (TBD signal), homefit team gets a daily digest.

Reporter fingerprint = stable browser-side device id (localStorage-backed UUID, no PII). Used purely for rate-limiting per-(session, device) at the server (already done by `report_premises` flow per CLAUDE.md).

## Heartbeat + polling cadence

### Practitioner-side (heartbeat)

While the camera surface is active AND Safe Mode is active:

- Every **20 seconds**, the app calls a new RPC `heartbeat_capture_session(session_id, lat, lng)`.
- Server updates `active_capture_sessions.last_heartbeat_at = now()` + `last_latitude` + `last_longitude`.
- On camera dispose / session end → call `end_capture_session(session_id)` → set `ended_at = now()`.

### Server-side (staleness sweep)

A periodic Postgres job (or RPC-time filter) marks sessions where `last_heartbeat_at < now() - 60 seconds` as effectively ended (filtered out of `get_live_sessions` results). Live page polling naturally drops them within ~15s.

If the app is killed without calling `end_capture_session` → session disappears from the live page within ~75 seconds total (60s heartbeat staleness + ~15s next poll). Acceptable lag.

### Live page polling

Live page polls `get_live_sessions(slug)` every 10-15 seconds. Page shows "Updated Xs ago" timestamp so the viewer knows freshness.

## Practice profile gate (owner-side)

When the practice owner opens `/public-profile` in the portal, if `public_slug` / `public_blurb` / `public_profile_listed` are not all set, surface a coral-bordered notice at the top:

> **Important:** Complete the fields below to enable Safe Mode recording in enforced premises. Without these, your practitioners cannot record in any private space.

Once all three are set, the notice disappears. Real-time enforcement: if the owner later disables any of the three (e.g., flips `public_profile_listed = false`), all active Safe Mode sessions for that practice's practitioners immediately enter the hysteresis trailing window and deactivate on the next miss cycle (60s grace).

## Migration plan

Single migration: `supabase/migrations/{timestamp}_safe_mode_transparency.sql`.

1. New `practitioners` table (or columns added to existing user metadata).
2. New `active_capture_sessions` table + indexes.
3. New `safe_mode_session_reports` table.
4. New `practitioner_audit_log` table.
5. New SECURITY DEFINER RPCs:
   - `set_practitioner_profile(first_name, last_name, avatar_url)` — writes columns + audit log.
   - `can_use_safe_mode(p_trainer_id, p_practice_id)` — returns the 6-point check result + list of missing requirements.
   - `start_capture_session(p_practice_id, p_premises_id, p_lat, p_lng, p_manual)` — insert into `active_capture_sessions`, return id.
   - `heartbeat_capture_session(p_session_id, p_lat, p_lng)` — update `last_heartbeat_at`, `last_latitude`, `last_longitude`.
   - `end_capture_session(p_session_id)` — stamp `ended_at`.
   - `get_live_sessions(p_slug)` — anonymous-readable, returns active sessions for the slug's practice.
   - `report_session(p_session_id, p_reason, p_fingerprint)` — insert into `safe_mode_session_reports`, trigger notification edge function.

All new RPCs are SECURITY DEFINER + scoped via `user_practice_ids()` helper for any authenticated calls. Anonymous-readable RPCs (`get_live_sessions`) are explicitly safe — they return only public-by-design fields (practitioner name + avatar, session start time, position, no client data).

## Phasing

**Phase A — Identity gate** (Settings UI, schema, gate-check RPC):
- New `practitioners` table + columns.
- Settings UI for first name, last name, selfie capture, face-detect verification.
- First-time disclosure card.
- `set_practitioner_profile` RPC.
- `can_use_safe_mode` RPC.
- Wire the 6-point check into `SafeModeService.checkLocation` — if any check fails, route practitioner to a permission-gate-style "complete your profile" screen.
- `practitioner_audit_log` table + triggers.

**Phase B — Live page + heartbeat**:
- New `active_capture_sessions` table.
- `start_capture_session` / `heartbeat_capture_session` / `end_capture_session` RPCs.
- New `/v/{slug}/now` page on web player.
- Practitioner-side: 20s heartbeat ticker while Safe Mode active.
- Persistent banner sub-line gains a hint: "Visible at /v/{slug}/now" when in an enforced polygon.

**Phase C — QR code + printable poster**:
- New `/premises/{id}/poster` route on the portal.
- Premises editor row gets "Download poster" button → opens poster URL in new tab → auto-prints.
- QR code generation: pure server-side SVG (no external service) — render QR for `/v/{slug}/now` URL.

**Phase D — Reporting + escalation**:
- New `safe_mode_session_reports` table.
- `report_session` RPC.
- Edge function: send report to practice's listed contact (email primary, WhatsApp fallback).
- Daily digest to homefit team for 48h-unanswered reports.

**Phase E (future)** — floor plans (V2), owner-side push notifications, per-practitioner deep-linking on practice profile, audit log surfacing in portal.

## Risks

- **Practitioner pushback on identity disclosure.** Some practitioners may resent the public name + photo requirement, especially those who joined for the platform but didn't sign up for being publicly trackable. Mitigation: the disclosure card is explicit; Safe Mode is opt-in if outside polygons; practitioners can choose to never record in enforced spaces.
- **Practice owner gate creates blocked teams.** A team of 5 practitioners all blocked because the owner hasn't completed `/public-profile` is a real friction risk. Mitigation: the portal's `/public-profile` page surfaces a prominent banner explaining the consequence; the gate is hardline by design (Carl signed off).
- **Live page polling load.** Every viewer polling every 10-15s could add up if many polygons see traffic. Mitigation: anonymous edge-cached responses (60s stale-while-revalidate), no per-viewer DB hit at scale.
- **Heartbeat reliability.** Network drops / app backgrounding could cause stale active sessions. Mitigation: 60s staleness sweep. False-positive (dead session lingers up to 75s) is acceptable.
- **Bystanders' geolocation accuracy.** Indoor GPS is unreliable (10-50m drift). The viewer's "You are here" dot may be slightly off; acceptable for orientation purposes.
- **PDF print fidelity.** Browser print-to-PDF varies by browser. Mitigation: `@media print` carefully scoped + tested on Safari, Chrome, Firefox. Owner gets the same result regardless of their browser.
- **Reporter rate-limiting at the practice contact.** A single bad-actor could spam reports to a practice. Mitigation: per-(session, fingerprint) rate limit on `report_session`, daily aggregate cap.

## Out of scope for V1

- **Floor plans** (V2 — Carl's call). V1 dots ride on the polygon satellite.
- **Per-practitioner deep linking** on the practice profile (`/v/{slug}#practitioner-{id}`). V1 cards link to `/v/{slug}` root.
- **Practice logo enforcement.** Practitioner avatars carry the visual.
- **Server-side PDF generation.** Browser print dialog handles it (Option α from the discussion).
- **WebSocket / SSE for live page.** Polling is sufficient.
- **iOS LiDAR / depth-based subject selection.** Covered separately in the face-based discriminator change (S-13).
- **Practitioner-facing "your active sessions" view.** Could be useful as a self-audit surface but not required for V1.
- **Audit log surfacing in portal.** Backend stores it; UI surfacing waits.
- **Multi-language tagline + blurb.** English only for V1.
- **Compass / direction indicator on the viewer's dot.** Just position is enough.
- **Practitioner identity verification (KYC).** Anyone can sign up with a face + name — no government ID. Trust + reporting handles abuse.
- **Auto-generated floor plans via RoomPlan / LiDAR.** V3 territory.
