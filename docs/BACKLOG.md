# Backlog — Deferred Work

Items that matter but aren't the current primary risk focus. Revisit when the POV is validated or when any of these start actually biting. Pulled from the 2026-04-17 "six points of optimization" discussion.

---

## Wave 39.3 — Dart timestamp UTC + per-viewer TZ rendering on portal

**Status:** Queued **2026-04-28**. Surfaced during Wave 39 unlock-flow QA. Fire after Wave 39 QA closes (Wave 39 build is on Carl's iPhone right now; bumping mobile would disrupt the QA loop).

**The bug — two-clock skew on the audit log.**
The portal audit page mixes timestamps from two sources that disagree by +2h on SA-local devices:
- `audit_events.ts` (`plan.opened`) — stamped server-side via Postgres `now()`, real UTC.
- `plan_issuances.issued_at` (`plan.publish`) — stamped client-side from Dart, **2h ahead** of real UTC for SA devices.

Root cause is in `app/lib/services/upload_service.dart` (and any other call site emitting timestamps to Supabase). The mobile code uses `DateTime.now().toIso8601String()`, which for a non-UTC `DateTime` emits *unmarked local time* (`2026-04-28T13:23:49.643561` — no `Z`, no offset). Postgres `timestamptz` parses unmarked input as UTC, so a publish that happened at SA wall 13:23 (= 11:23 UTC real instant) gets stored as 13:23 UTC (= a real instant 2h in the future). For SA practitioners the bug is invisible because the bug-shifted UTC value happens to equal SA wall time — but the moment a US-tz practitioner uses the system, or anyone tries to compute durations across event types, the times disagree.

Audit screen also formats SSR-side, currently pinned to `timeZone: 'UTC'` ([web-portal/src/app/audit/page.tsx](../web-portal/src/app/audit/page.tsx)) — this matches the bug-shifted client values for SA users today, but a proper render needs the viewer's local TZ.

**Scope of fix:**
1. **Mobile timestamp emission** — sweep `app/lib/services/upload_service.dart` and any other writer (start with the four call sites in upload_service: `sent_at`, `issued_at`, `created_at` mirror in plans upsert, the diagnostic log line). Replace `DateTime.now().toIso8601String()` with `DateTime.now().toUtc().toIso8601String()` so the wire format always carries `Z`. Same for any other module that POSTs timestamps to Supabase (grep for `toIso8601String` in `app/lib`).
2. **One-shot data backfill** — for every existing `plan_issuances.issued_at` and any other affected column written by the buggy path, subtract the offending TZ offset. SAFE option: query practitioners' iPhone TZ (we don't have it; treat as +2 for the SA-only MVP cohort) and run an UPDATE … SET issued_at = issued_at - interval '2 hours' on rows older than the fix-deploy timestamp. RISKIER option: leave historical data as-is and only fix going forward (the audit log will look weird across the cutover but the cutover is a one-day blip). Carl's call which trade-off he prefers.
3. **Portal — per-viewer-TZ time rendering.** Extract the audit table's `<td>` time cell into a tiny client component (`<ClientTime ts={iso} />`) that calls `new Date(iso).toLocaleString(navigator.language, { dateStyle: 'medium', timeStyle: 'short' })`. The browser-local TZ is what the practitioner expects (their wall clock). Keep `fmtDate(iso)` server-side fallback for the SSR window before hydration. Apply the same client-component swap to the "Prepaid via unlock at …" / "Used at …" subtitles for consistency.
4. **Test plan addition** — extend the Wave 40 test bundle with an item: open a published plan, immediately publish, look at audit feed; confirm both the `plan.opened` timestamp and the `plan.publish` timestamp align with the practitioner's wall clock (within a minute) and read in the same TZ.

**Why deferred (not patched alongside Wave 39):**
- Mobile rebuild would disrupt active Wave 39 unlock-flow QA on Carl's iPhone.
- The backfill question (option 1 vs 2 above) needs Carl's input.
- Wave 39 audit feed already works for SA-only viewing; the bug is invisible at MVP scale.

---

## Consent-driven analytics collection (Wave 17)

**Status:** Designed **2026-04-21** with Carl. Full design locked in [`docs/design-reviews/analytics-consent-mvp-2026-04-21.md`](design-reviews/analytics-consent-mvp-2026-04-21.md). MVP pillar — ships alongside the other MVP features, not as a post-MVP add-on. Foundation for the future paid Analytics subscription (Y2+).

**Locked decisions:**
- Consent model **C** — hybrid: practitioner toggle on client (default ON) + client per-plan banner (last word).
- Cadence: once-and-remember per browser via localStorage + server session.
- Transparency via a **static page at `session.homefit.studio/what-we-share`** (+ contextual `?p={planId}` variant that greets by practitioner name + wires stop-sharing). Linked from consent banner, completion screen, player menu. One source of truth outside the player — citable in emails, QR codes, future help docs.
- Retention: 180 days raw events, daily aggregates forever.
- Naming: **Analytics** (same noun as the future paid product).

**Scope:**
- 2 new Supabase tables (`client_sessions`, `plan_analytics_events`) + 1 rollup (`plan_analytics_daily_aggregate`).
- New `analytics_allowed` key on `clients.video_consent` (default true).
- 4 write RPCs + 3 read RPCs (anon `get_plan_sharing_context` for the contextual transparency page + 2 practitioner-scoped rollups) + daily retention cron.
- Web-player: consent banner with inline "What's shared?" link, 12 event emitters, completion-screen CTA linking out to the static page.
- New static page at `web-player/what-we-share.html` — two variants on the same URL, updatable independently of the player bundle.
- Flutter Studio: 3-number stats under each plan + per-exercise bars + new consent checkbox in the client detail page.

**Event inventory (12):** plan_opened, plan_completed, plan_closed, exercise_viewed, exercise_completed, exercise_skipped, exercise_replayed, treatment_switched, pause_tapped, resume_tapped, rest_shortened, rest_extended. Metadata-only — no video telemetry, no IP/IDFA/geo/fingerprints.

**Explicitly NOT in Wave 17:** per-exercise pain scale, weekly client adherence emails, cross-client cohort dashboards, CSV export. All Y2+ paid Analytics.

**Timeline:** ~1 focused week. Not blocking other work. Can land right after Wave 15+16 device-QA settles.

---

## Add practice member by email — supersede Wave 5 invite-code flow (Wave 14)

**Status:** Shipped **Wave 14** (Carl, 2026-04-21). **Replaces the Wave 5 invite-code flow** (PR #76, which Carl rejected after QA friction). Migration: `supabase/schema_milestone_u_add_member_by_email.sql`.

**Why:** Wave 5's "mint code → share /join/{code} link → invitee signs in → calls claim_practice_invite" had three blockers for MVP-stage QA:
- Magic-link emails hit Supabase's built-in SMTP throttle (~4/hr project-wide) — caused a live QA outage 2026-04-21.
- Testing needed fresh browser profiles to avoid session collision between owner + invitee in the same browser.
- Invitee-side confusion around the 7-character code and landing page.

**New model:** owner on `/members` types the invitee's email and clicks **Add**. The RPC branches on whether an `auth.users` row already exists:
- Exists + not yet in practice → added to `practice_members` immediately; the practice appears in their switcher on their next home render.
- Exists + already a member → returns `already_member` kind for a friendly "already there" toast.
- No account yet → parked in `pending_practice_members` (email + practice_id PK). A trigger on `auth.users` INSERT drains matching rows into `practice_members` on first signup and deletes the pending row. The invitee never sees an invite link or code.

**What shipped:**
- `supabase/schema_milestone_u_add_member_by_email.sql` — drops `practice_invite_codes`, `mint_practice_invite_code`, `claim_practice_invite`. Creates `pending_practice_members` + 3 new RPCs (`add_practice_member_by_email`, `remove_pending_practice_member`, `list_practice_members_and_pending`). Installs `claim_pending_practice_memberships` AFTER INSERT trigger on `auth.users`. Recreates `list_practice_audit` without the dead `invite.mint` / `invite.claim` branches.
- Portal `/members` rewrite — email input + Add button, Members + Pending sections, Remove on pending rows. `/join/[code]` route deleted entirely (page.tsx + JoinInvite.tsx + JoinSignInPrompt.tsx).
- Mobile: `claimPracticeInvite` / `ClaimInviteResult` / `ClaimInviteError` / `ClaimInviteErrorKind` removed from `app/lib/services/api_client.dart`. Settings "Join a practice" card removed from `app/lib/screens/settings_screen.dart` — zero invitee-side mobile UI; practices just appear in the switcher on first launch after the trigger fires.

**Why no mobile UI:** the invitee-side flow is passive by design. The trigger runs server-side on INSERT; the mobile app's first authenticated `listMyPractices()` call picks up the newly-drained membership row. No UI = no friction = no QA wave 3 bugs.

**Tested live:** three-case RPC spot-check (`added` / `already_member` / `pending`) against Carl's sentinel practice. The pending table + trigger are unit-inspected; end-to-end trigger firing needs a fresh-email signup to exercise — deferred to Wave 14 QA wave if Carl wants a formal pass.

---

## Resend SMTP for Supabase Auth — lift built-in email throttle (Wave 13)

**Status:** Scheduled **Wave 13** (Carl, 2026-04-21). **Triggered by an active QA outage** — Wave 5 invite-claim testing hit Supabase's built-in SMTP rate limit (~4 magic-link emails per hour, global-per-project). With Melissa + external testers onboarding soon this will be a recurring block.

**Provider choice:** Resend. 3k emails/month free tier; simplest DKIM setup; already LI-widely used by Vercel/Next ecosystems. Postmark / SendGrid / AWS SES would work too but Resend has the lowest friction for a new project.

**Scope (one PR + dashboard work):**

1. **Resend account + domain verification**
   - Sign up at [resend.com](https://resend.com).
   - Add domain `homefit.studio`. Resend emits 3 DNS records: one `TXT` for SPF, two `CNAME` for DKIM (`resend._domainkey` + `resend.send.domainkey`).
   - In [Hostinger DNS](https://hpanel.hostinger.com/) → `homefit.studio` → Manage DNS records → add the three records exactly as Resend shows.
   - Resend → **Verify** — propagation <2 min typically.
   - Resend → **API Keys** → create key named `supabase-auth-prod`, permission `Sending access`, domain `homefit.studio`. Copy the `re_...` key (shown once).

2. **Supabase SMTP wiring** (dashboard-only; no CLI/API surface)
   - [Supabase dashboard](https://supabase.com/dashboard/project/yrwcofhovrcydootivjx) → **Authentication → Settings → SMTP Settings**.
   - Toggle **Enable Custom SMTP**.
   - Host: `smtp.resend.com` · Port: `465` · Username: `resend` · Password: paste API key.
   - Sender email: `noreply@homefit.studio` (decide on `hello@` vs `noreply@` before wiring — this is the From address every magic link shows).
   - Sender name: `homefit.studio`.

3. **Validate**
   - Sign out; request a magic link for a test user.
   - Resend dashboard → **Emails** — row should appear immediately.
   - Inbox → email delivered from `noreply@homefit.studio`, DKIM + SPF pass in the Gmail/iCloud raw-headers view.
   - Supabase dashboard → **Authentication → Rate Limits** — "Enable custom SMTP" note should say the built-in throttle no longer applies.

4. **Playbook doc** — add `docs/infra/smtp-setup.md` with the above steps + a rollback section ("how to revert to built-in SMTP if Resend API key is revoked / bill runs hot"). Link from [`CLAUDE.md`](CLAUDE.md) under Architecture Principles.

5. **Secret handling** — the `re_...` API key lives in the Supabase SMTP settings only (not in our repo, not in Vercel env). If we need second-source storage for audit, add a vault secret named `resend_api_key_smtp` via `vault.create_secret()` — it's unused by any code today, just a backup.

**Blocked on Carl for:** Resend signup, Hostinger DNS edits, Supabase dashboard config. The migration code is zero lines; no repo changes except the playbook doc.

**Acceptance test:** request 10 magic links in <5 minutes without throttling.

**Out of scope (don't do in Wave 13):** custom transactional email templates, bulk marketing, webhook event handling for delivery failures. Those belong to a later email-observability wave.

---

## Network share-kit Phase 3 — PNG + QR + analytics (Wave 10)

**Status:** Scheduled **Wave 10** (after Phase 2 intents land). Design already exists at [`docs/design/mockups/network-share-kit.html`](design/mockups/network-share-kit.html) (PNG card section around line 1410).

**Scope:**
- Server-side or client-side PNG render of the 1080×1350 share card. Source of truth is the mockup — practitioner name, practice name, share code, QR, tagline (`"Plans your client will love and follow. Ready before they leave."`).
- Real scannable QR for `session.homefit.studio/r/{code}` — replace the CSS stand-in at `.qr`. Use a headless QR lib (e.g. `qrcode` npm package, zero deps).
- `Download PNG` button → binary download; filename `homefit-share-{kebab-case-practitioner}.png`.
- `Copy to clipboard` → image blob via `navigator.clipboard.write([new ClipboardItem({'image/png': blob})])`. Safari support is the constraint — verify on iOS Safari + desktop Safari before shipping.
- Analytics event on each share action (Copy / Open-in-app / Download-PNG) → append to `plan_issuances`-style table (propose new `share_events` append-only table, indexed by `practice_id`, `channel`, `occurred_at`).
- Sharing telemetry surfaces on `/network` below-the-fold or on `/audit` — defer the UI decision to design review.

**Decisions not yet locked:**
- Render location (server Edge Function vs client Canvas) — client is simpler, but server is cacheable + consistent across browsers. Lean server.
- Font embedding — server-side Canvas needs the Montserrat + Inter fonts bundled; add to Vercel build.

---

## Mobile R-11 twin for Network share-kit (Wave 11)

**Status:** Scheduled **Wave 11** (after Wave 10 PNG/QR — share card needs to exist before mobile renders it). Depends on Wave 5 Members for consistent identity surfaces if the input hints at a "colleague picker".

**Scope:** mobile Settings → Network currently exposes only the share code + referral link. Port the portal's three-template + PNG share card to the Flutter Settings Network screen to honour R-11.
- New widget: `NetworkShareKitScreen` or a sheet from Settings → "Share homefit.studio".
- Three cards (WhatsApp 1:1, broadcast, email) matching portal visuals. Copy-to-clipboard via `Clipboard.setData`.
- Native intent launchers — `url_launcher` package with `wa.me` + `mailto:` URLs. Mirrors Wave 10 Phase 2 URL-builder helpers (port templates.ts → Dart).
- PNG share card: if Wave 10 settles on server-render, mobile just fetches and offers iOS share sheet. If client-render, mobile needs its own rasteriser (Flutter `RepaintBoundary.toImage`).

**Decisions not yet locked:**
- Should mobile deep-link into the portal `/network` page instead of duplicating the UI? Likely no — offline-first principle says the practitioner needs to share without a signal. But port minimum viable instead of full parity.

---

## Network share-kit experiments (Wave 12+, not yet locked)

**Status:** Deferred ideas. Each could stand alone as a future wave; not yet triaged.

- **Template A/B** — swap WhatsApp 1:1 copy via a flag, measure referral conversion per variant.
- **Personalised pitch** — pull the practitioner's highest-opened plan as social proof inside the email body.
- **Share-funnel dashboard** — "who opened your share card but didn't sign up" on `/network` below the fold; depends on Wave 10 analytics events landing first.

---

## Audit expansion — full event log with filters + CSV export (Wave 9)

**Status:** Scheduled **Wave 9** (after Wave 5 Members lands — several event kinds originate there). Design locked 2026-04-20.

**Scope expansion:** today `/audit` shows `plan_issuances` only (truncated trainer_id, no filters). Expand to a unified practice event log:

- **Event sources:** `plan_issuances` (publishes), `credit_ledger` (purchases / refunds / signup bonuses / adjustments / consumption), `referral_rebate_ledger` (rebates in), `clients.created_at` / `deleted_at`, `practice_members.joined_at`, `practice_invite_codes.created_at`.
- **New `audit_events` table** (id, ts, practice_id, actor_id, kind, ref_id, meta jsonb) for mutations without natural sources: member removals, role changes, practice renames, client restores.
- **Single RPC** `list_practice_audit(p_practice_id, p_offset, p_limit, p_kinds[], p_actor, p_from, p_to)` — SECURITY DEFINER, unions across all sources, returns `{ts, kind, trainer_id, email, full_name, title, credits_delta, balance_after, ref_id, meta}`.

**UI:** table with `Date · Actor (email + name) · Kind chip · Description · Credit Δ · Balance after · Link`. Kind-chip colours: coral (publish/consumption), sage (credits-in), red (refund/deletion), grey (neutral membership/rename). Filter bar above: multi-select Kind + Practitioner + Date range. Pagination (50/page, total count shown). `Export CSV` button — client-side conversion of the currently-filtered set.

**Visibility:** all practice members see everything — transparency is intentional. No role-based filtering.

**Identity fix:** same SECURITY DEFINER `join auth.users` pattern as Wave 5 Members. Shows email + full name.

---

## Members area — identity, invite codes, role, remove, leave (Wave 5)

**Status:** Scheduled **Wave 5** — Carl, 2026-04-20. Bumped sticky-defaults to Wave 8.

**Problem:** current `/members` is a scaffold — truncated trainer_id UUIDs, disabled invite form ("wiring pending — Milestone D4 follow-up"), no remove / role / leave.

**Scope:**

1. **Identity surface.** New `list_practice_members_with_profile(p_practice_id)` RPC (SECURITY DEFINER, owner-only) joins `practice_members` → `auth.users`. Returns `{trainer_id, email, full_name, role, joined_at, is_current_user}`.

2. **Invite codes — per-practitioner-per-practice.** New `practice_invite_codes(code TEXT PK, practice_id, created_by, created_at, claimed_by, claimed_at, revoked_at)` table. 7-char opaque slug with unambiguous alphabet (same pattern as referral codes). Owner mints a code per practitioner. **No expiry. Multi-code per practice, one per invited person. Auto-join on claim.** Landing page `/join/:code` shows practice name + "Join as practitioner" button; after auth, `claim_practice_invite(p_code)` inserts into `practice_members` as role=`practitioner` + stamps `claimed_at`.

3. **Remove member.** `remove_practice_member(p_practice_id, p_trainer_id)` — owner-only. Hard-deletes row. Also revokes any unclaimed invite codes minted for them. Credit ledger attribution preserved (FK to `auth.users`, not the pivot).

4. **Role change.** `set_practice_member_role(p_practice_id, p_trainer_id, p_new_role)` — owner-only. DB-enforced blocks: (a) can't demote the last owner, (b) can't change your own role.

5. **Self-service leave.** `leave_practice(p_practice_id)` — any member. Blocks: (a) last owner with practitioners remaining — must promote someone first, (b) only member — destructive-delete flow out of scope for this wave.

**UI (`/members`):**
- Table: `Email · Name · Role · Joined · Actions`.
- Own row tagged "(you)" with `Leave practice` button in actions.
- Top of page: "Invite a practitioner" mints a new code + copies to clipboard.
- Owners see Role dropdown + Remove button per non-self row; practitioners see table only.

**UI (`/join/:code`):** auth gate → practice name header + "Join as practitioner" button → claim RPC → redirect to `/dashboard`.

---

## Unified player — Flutter + Web share a single rendering codebase

**Status:** Scheduled as **Wave 4** (next iteration after Wave 3 QA wraps, 2026-04-20). Pre-MVP. Decision Carl, 2026-04-20.

**Why now:** the mobile preview and the web player have independently-maintained implementations of pill matrix / swipe / prep countdown / treatment rendering / mute / pause. R-10 ("every UX change must land in both surfaces") keeps drifting — the raw-archive debug + treatment-picker-removal session on 2026-04-20 made clear the maintenance cost is real and compounding. Unifying before MVP is cheaper than unifying after.

**Architecture (recommended):** WKWebView on iOS hosting the web player bundle. Local file access resolved via one of:

1. **In-process local HTTP server** (Dart `shelf` package) serving `Documents/archive/` and `Documents/converted/`. Web-player hits `http://localhost:<port>/...`. Simplest Dart-side; adds a process.
2. **WKURLSchemeHandler** custom scheme (e.g. `homefit-local://{exerciseId}/archive.mp4`) resolved in Swift. More iOS-native; better streaming for larger files.

Prefer (2) for perf + cleanliness; prototype (1) first for speed. Either way, Flutter passes the plan state as JSON via `postMessage` / platform channel, web-player renders.

**What we keep native:** Taptic Engine haptics (per-second record ticks, prep flashes), iOS audio session (silent switch respect), app lifecycle hooks. Bridged via message channel.

**What we trade:** a small perf floor vs pure native video, and a WebView bundle on-device. Worth it for code-dedup.

**What it obsoletes:** R-10 parity rule (same code = no parity drift). `plan_preview_screen.dart` becomes a thin WebView host.

**Dead-end alternatives:** Flutter Web for the player (video decode quirks + heavy bundle), dart2js interop (complex, few gains).

**Scope estimate:** 1–2 focused weeks. Spin up: local server or URL handler, plan-state bridge, migrate R-10-sensitive features off Dart. Test matrix: pre-publish preview, post-publish preview, web (browser), WebView (iOS).

---

## Silent failure observability — error_logs + _loudSwallow + boot self-check

**Status:** Scheduled as **Wave 7** (Carl, 2026-04-20 — wants it done properly as its own wave, not shoehorned into another). Design reviewed: see [`docs/design-reviews/silent-failures-2026-04-20.md`](design-reviews/silent-failures-2026-04-20.md).

**3-item MVP:**
1. `error_logs` table + `_loudSwallow` helper + pre-commit lint rule banning bare `catch (e) {}`.
2. Boot-time self-check screen — includes live `signed_url_self_check()` probe that would have caught today's vault placeholder on first launch.
3. `publish_health` SQL view + daily WhatsApp ping via the existing CallMeBot skill.

**Explicitly NOT:** Sentry/Datadog (overkill at 5 practices), viral `Result<T,E>` (only at 3 boundaries: ApiClient, UploadService.publish, video platform channel), modal error dialogs (violates R-01), silent retries (every failed attempt must log at warn).

**Sequencing note:** Wave 4 (unified player) will touch many swallow sites. Worth migrating them through `_loudSwallow` opportunistically during that refactor so Wave 7's sweep has less to cover.

---

## Replace `sign_storage_url` pgjwt helper with Supabase's native signed-URL path

**Status:** Technical debt. Currently unblocked by the legacy HS256 JWT secret (set 2026-04-20). Fix before the legacy path is removed from Supabase.

**Context:** `public.sign_storage_url(bucket, path, expires_in)` in `supabase/schema_milestone_g_three_treatment.sql` manually mints HS256 JWTs via pgjwt, signing with the legacy `vault.secrets['supabase_jwt_secret']` value. Supabase has migrated to a new JWT Signing Keys system (per-key identifiers, key rotation) and the single-secret legacy path is being phased out. When the legacy secret is finally retired, every signed URL minted by our helper will 400 overnight and the web player's B&W / Original treatments will stop working again — exactly the outage we just burned hours recovering from (2026-04-20 raw-archive session).

**Proper fix:** stop minting JWTs in Postgres. Either:
- **Edge Function that signs URLs.** `get_plan_full` returns bucket+path pairs (no URLs). Web player posts them to an Edge Function which calls `supabase.storage.from(bucket).createSignedUrl(path, 1800)` using the service role. Returns signed URLs.
- **Direct client-side signing.** Web player calls `storage.from(bucket).createSignedUrl(...)` directly after authenticating with anon key + a bucket-access RPC that pre-approves paths. More moving parts; probably the Edge Function path is cleaner.

**Related:** if we do this, consider moving the consent gate into the Edge Function too (check `video_consent` server-side before minting each URL) so the web player never has to see raw paths it shouldn't.

**Trigger to do it:** Supabase announces legacy JWT secret end-of-life, OR we rotate the legacy secret and notice we can't update our vault entry, OR routine hardening pass.

---

## Replace `sign_storage_url` pgjwt helper with Supabase's native signed-URL path

**Status:** Technical debt. Currently unblocked by the legacy HS256 JWT secret (set 2026-04-20). Fix before the legacy path is removed from Supabase.

**Context:** `public.sign_storage_url(bucket, path, expires_in)` in `supabase/schema_milestone_g_three_treatment.sql` manually mints HS256 JWTs via pgjwt, signing with the legacy `vault.secrets['supabase_jwt_secret']` value. Supabase has migrated to a new JWT Signing Keys system (per-key identifiers, key rotation) and the single-secret legacy path is being phased out. When the legacy secret is finally retired, every signed URL minted by our helper will 400 overnight and the web player's B&W / Original treatments will stop working again — exactly the outage we just burned hours recovering from (2026-04-20 raw-archive session).

**Proper fix:** stop minting JWTs in Postgres. Either:
- **Edge Function that signs URLs.** `get_plan_full` returns bucket+path pairs (no URLs). Web player posts them to an Edge Function which calls `supabase.storage.from(bucket).createSignedUrl(path, 1800)` using the service role. Returns signed URLs.
- **Direct client-side signing.** Web player calls `storage.from(bucket).createSignedUrl(...)` directly after authenticating with anon key + a bucket-access RPC that pre-approves paths. More moving parts; probably the Edge Function path is cleaner.

**Related:** if we do this, consider moving the consent gate into the Edge Function too (check `video_consent` server-side before minting each URL) so the web player never has to see raw paths it shouldn't.

**Trigger to do it:** Supabase announces legacy JWT secret end-of-life, OR we rotate the legacy secret and notice we can't update our vault entry, OR routine hardening pass.

---

## Filter workbench — wire to cloud raw archive once auth lands

**Status:** Deferred. Blocks real filter tuning.

Current limitation: `tools/filter-workbench/` pulls the `media_url` from Supabase, which is the already-filtered + already-two-zoned line-drawing output. Tuning filter params against post-filter content isn't meaningful — the slider tweaks layer on top of work already done. Segmentation re-runs on a line drawing instead of raw pixels.

Fix path once the cloud raw archive (archive pipeline Phase 2) lands post-auth: point the workbench's Supabase client at the private `raw-archive/{trainer_id}/{session_id}/{exercise_id}.mp4` bucket instead of the public `media/` bucket. Frame extraction + filter + segmentation then operate on the true pre-filter source.

Short-term workaround: AirDrop a raw video from the iPhone to the Mac and drop it in `tools/filter-workbench/samples/`. The CLI workbench (`workbench.py`) already accepts local samples; the Streamlit UI could be extended with a "local sample vs Supabase plan" source toggle if needed in the interim. Carl asked to wait for the proper cloud path rather than workaround.

---

## One-handed reachability — pull-to-latch scroll physics (Studio)

**Status:** Deferred. Custom behaviour, probably a few days of careful work.

**Want:** Let the bio drag the Studio list down and have it LATCH in the dragged position (not bounce back on release) so items that were near the top are now in the thumb zone. Tap an item, viewport snaps back to natural rest.

**Why native alternatives don't fit:** `BouncingScrollPhysics` only holds the stretched position during the active gesture — releasing snaps it back, so items aren't reachable without a second finger. iOS system Reachability works but Carl finds it terrible UX. Standard scroll physics don't have a "latched stretch" state.

**Implementation sketch:** Subclass `ScrollPhysics`, override `applyPhysicsToUserOffset` + `createBallisticSimulation` to allow the scroll offset to extend past the natural minimum (in `reverse: true` that's past the visual top), and prevent the simulation from returning to zero on release below a threshold. Tapping an item anywhere in the app invokes a snap-back animation. Most of the complexity is in the interaction model — drag gestures, tap-to-snap-back, conflict with drag-reorder (`ReorderableListView` has its own drag-start detection).

**Risk:** Non-standard scroll behaviour is user-experience debt. Bios switching between this app and every other app will be surprised by list content that doesn't bounce back. Only revisit if the one-handed friction is observed to be a real problem in testing.

---

## Point 2 — Performance / feel

**Status:** Deferred. POV currently feels fast on a new iPhone. Revisit when we hit a real bottleneck or when we test on lower-spec devices.

- **Startup latency.** Cold start chains `PathResolver.initialize` → `SystemChrome` → `Supabase.initialize` → `storage.init` + migrations + `purgeExpiredSessions` + `purgeOldArchives`. Cut time-to-first-paint by kicking Supabase init and purges to post-first-frame via `unawaited(...)`.
- **List scroll jank with 30+ captures.** Expansion + drag reorder + per-row thumbnails. Partly addressed: `Image.file` `cacheWidth` sized to widget, N+1 queries resolved via `WHERE IN (...)`. Further wins: promote card-expanded state to a `ValueNotifier` so only the open card rebuilds; avoid passing fresh closures each build.
- **Video convert speed on device.** `autoreleasepool` + `CVPixelBufferPool` landed. Per-pixel Swift loops for BGRA↔gray remain hot — `vImage` rewrite (`vImageMatrixMultiply_ARGB8888ToPlanar8` + `vImageConvert_Planar8toARGB8888`) would ~halve convert time.
- **Rebuild storms.** `setState` at the top of large screens (particularly the old `session_capture_screen.dart`) rebuilds the entire card list. Capture/Studio split will reduce this but not eliminate it.
- **Battery / thermal on long sessions.** 90 min of live camera + background conversion queue + SQLite writes under thermal pressure hasn't been measured. Worth profiling with Xcode Instruments when it matters.
- **Publish over SA 4G.** Sequential uploads, no chunking, no resumable transfer. 20 captures × tens of MB = minutes. Single signal drop = start over (see Point 3 below).

---

## Point 3 — Resilience

**Status:** Deferred. All valid scenarios; prioritise when we onboard additional bios or move past the POV.

### High priority when we pick this up
1. **Background-safe publish via native iOS background `URLSession`.** Current Dart-level `http` uploads die on backgrounding or signal drop. Platform-channel the storage PUTs into a `URLSessionConfiguration.background` so the bio can background the app (walk out to their car) mid-upload without losing progress. This is the single biggest resilience win.
2. **Phone-full handling.** Proactive check of available storage before a capture starts; user-facing "your phone is nearly full" warning. Today we fail silently at the file-write step.
3. **Local DB backup / export.** A weekly auto-export of sessions + metadata (+ maybe a manual "export my plans" button) into `Documents/backups/`. Defends against SQLite corruption, accidental reset, phone loss. Cheap insurance.

### Lower priority
- **Crash-mid-capture testing.** Today we save the raw file + DB row before conversion; on next launch the queue resumes via `getUnconvertedExercises`. Probably OK; should be stress-tested.
- **Partial-clip salvage on call/alarm interrupt.** Camera teardown on `AppLifecycleState.inactive` discards the in-flight clip (tough-love stance, 2026-04-17). Keep unless feedback pushes back.
- **DB corruption recovery.** No recovery path today. Tied to backup/export above.
- **Stolen / lost phone.** Published plans survive in the cloud; trainer's archive is local-only. The cloud raw-archive (Phase 2, post-auth) will solve this.
- **Reinstall survival.** Relative paths via `PathResolver` plus schema migrations should hold. Worth one round of deliberate testing before MVP.

---

## T2 follow-up — publish durability hardening (post-sprint closeout)

**Status:** Classification + practitioner-visible diagnostics shipped (`docs/T2_PUBLISH_RELIABILITY.md`, PRs `#166`–`#167`, hardening `#171` / `#174` / `#176` / `#177` / `#179`). Deeper durability items below remain deferred.

**Shipped (warning/diagnostic layer):**

- **Consent pre-flight RPC outage (`#174`):** fails open to server `consume_credit` backstop (`P0003`); Studio warns when preflight was skipped.
- **Refund outcome uncertainty (`#171`, `#176`):** structured payload + clipboard text + snackbar to verify balance when refund RPC completion is unknown after debit.
- **Optional raw-archive artifact failures (`#177`):** success path stays success; Studio warns when best-effort raw-archive sidecars failed (retry publish to backfill).
- **Version drift after partial publish (`#171`, `#179`):** clipboard diagnostics + snackbar when cloud plan version may already be ahead of local after `networkFailed`.

**Remaining carry-over:**

1. **Version drift — mitigation decision.** **Chosen (2026-05-02): UX-only + warnings/retry** unless production/support shows recurring broken-remote-state incidents; storage PUTs cannot share a Postgres transaction, so full atomicity is a larger saga/idempotency effort. Revisit if strict version+exercise coupling becomes a requirement.
2. **`refund_credit` deeper surfacing.** RPC remains swallow-by-design on failure; add explicit **retry/reconcile/support** affordance without blocking publish retry (beyond balance-verification copy).
3. **Optional artifact telemetry.** Snackbars cover visible lag on raw-archive paths; evaluate **logging/analytics/support pings** for segmented/mask/issuance gaps.

Device QA capture: [`T2_DEVICE_QA_OUTCOMES_2026-05-01.md`](T2_DEVICE_QA_OUTCOMES_2026-05-01.md).
