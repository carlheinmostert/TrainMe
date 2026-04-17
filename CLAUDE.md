# homefit.studio — Project Instructions

## What is this?

**homefit.studio** (internally codenamed TrainMe/Raidme) is a multi-tenant SaaS platform for biokineticists, physiotherapists, and fitness trainers to capture exercises during a client session, convert them into clean line-drawing demonstrations on-device, assemble a plan, and share it with the client via a WhatsApp-friendly link.

**Three surfaces:**
1. **Flutter mobile app** — the trainer's tool (dark mode, coral orange accent). Capture + Studio modes in a single session shell.
2. **Web player** at `session.homefit.studio/p/{planId}` — what the client sees. Anonymous, read-only.
3. **Web portal** at `manage.homefit.studio` — where practice owners buy credits, view the audit log, and invite practitioners. Next.js 15 App Router, authenticated via Supabase. Live on Vercel since 2026-04-17 evening.

## Brand

- **Name:** homefit.studio (lowercase, always)
- **Domain:** homefit.studio (registered at Hostinger)
- **Client plan URL:** `https://session.homefit.studio/p/{uuid}`
- **Primary accent:** Coral orange `#FF6B35`
- **Mode:** Dark-first (both trainer app and client web player)
- **Logo:** Pulse Mark — heartbeat line that traces a house roof silhouette. Rendered as inline SVG/CustomPaint in coral orange.
- **Typography:** Montserrat (headings, 600-800), Inter (body, 400-700)
- **Theme tokens:** See `app/lib/theme.dart` (Flutter) and `web-player/styles.css` `:root` (web)

## Architecture Principles

- **Multi-tenant from day one** — Practice is the tenant boundary. Never build features that assume single-tenancy.
- **Exercise visualisation is the core IP** — On-device line drawing conversion of real exercise footage. AI style transfer (Stability AI, Kling O1) parked as future premium.
- **No licensed animation libraries** — All visual content is self-generated.
- **On-device processing preferred** — No API costs, instant results, better privacy. Cloud AI is premium only.
- **Offline-first architecture** — The entire capture → convert → edit → preview flow is 100% offline. Only Publish touches the network. Future: publish queue that batches uploads when connectivity is available.
- **Non-blocking publish** — Publishing runs in the background. The bio never waits for uploads. Core UX principle.
- **Line drawings de-identify** — POPIA-friendly by design. Client's face/body is abstracted away.
- **Single accent colour** — Coral orange throughout. No teal or competing accents. (The rest period blue-grey is a distinct visual category, not an accent.)
- **Social login only** — No username/password. Future: Google/Apple social login or magic links.

## Tech Stack (current)

- **Mobile app:** Flutter 3.41.6 (Dart 3.11.4)
- **Native video pipeline:** iOS Swift + AVFoundation (AVAssetReader/Writer + vImage/Accelerate) via platform channel. Handles H.264/HEVC directly. Native code at `app/ios/Runner/VideoConverterChannel.swift`.
- **OpenCV binding:** `opencv_dart` v2.x (builds from source via hooks — not the old prebuilt pod that broke)
- **Local storage:** SQLite via `sqflite`. Schema version 13. All paths stored relative via `PathResolver`.
- **Conversion service:** Singleton pattern, survives screen navigation. FIFO queue processes captures sequentially.
- **Raw-video archive pipeline:** After conversion, the raw capture is AVAssetExportSession-compressed to 720p H.264 and archived locally at `{Documents}/archive/{exerciseId}.mp4`. 90-day retention. Cloud upload to a private bucket is deferred until the auth story is fully in place (backlog item).
- **Backend:** Supabase (yrwcofhovrcydootivjx.supabase.co). **CLI is linked** — Claude sessions can run migrations directly via `supabase db query --linked ...` instead of asking Carl to paste SQL in the dashboard.
  - **Tenancy:** `practices` + `practice_members` (role=owner|practitioner) form the tenancy boundary. A trainer can belong to multiple practices; first-ever sign-in claims the Carl-sentinel practice. Fresh sign-ins auto-create a personal practice.
  - **Plan data:** `plans`, `exercises` with full data model (circuits, rest periods, audio, custom durations, versions, thumbnails). `plans.practice_id` + `plans.first_opened_at`.
  - **Billing:** `credit_ledger` (append-only, consumption/purchase/refund/adjustment) + `plan_issuances` (append-only audit of every publish) + `pending_payments` (PayFast intent). Credit cost: `ceil(non_rest_count / 8)` clamped to `[1, 3]`.
  - **Atomic credit consumption:** `consume_credit(p_practice_id, p_plan_id, p_credits)` SECURITY DEFINER fn with FOR UPDATE locking. Called from publish flow. Accompanying `practice_credit_balance`, `practice_has_credits`.
  - **Anonymous plan read:** `get_plan_full(plan_id)` SECURITY DEFINER RPC. Web player calls this; no direct SELECT on plans/exercises for anon.
  - **RLS:** scoped-by-practice via the helper fns `user_practice_ids()` and `user_is_practice_owner(pid)`. Avoids the self-referential recursion trap that direct subqueries on `practice_members` would cause. The helper fns are SECURITY DEFINER and bypass RLS.
  - **Storage bucket:** `media` (public read for sharing plan URLs; INSERT/UPDATE/DELETE scoped by path-prefix→plan→practice membership).
- **Web player:** Static HTML/CSS/JS on Vercel, auto-deploys from GitHub (`web-player/` directory)
- **Domain:** Hostinger DNS, CNAME `session` → `cname.vercel-dns.com` (updated to `00596c638d4cefd8.vercel-dns-017.com.` per Vercel's new IP range)
- **OG meta tags:** Vercel Edge Middleware (`web-player/middleware.js`) serves bot-friendly HTML for WhatsApp link previews
- **Service worker:** `web-player/sw.js` caches app shell for offline. Cache name `homefit-player-v3-dark` — bump on major changes.

## Key Domain Model

- **Practice** — top-level tenant. Created automatically on first Google sign-in (either claims the Carl-sentinel or spins up a fresh personal practice). A trainer can belong to multiple practices; the publish-screen picker is where they choose which one pays.
- **Practice member** — trainer-in-practice with a role (`owner` or `practitioner`). Owner can invite other trainers and buy credits. Practitioners consume credits to publish.
- **Trainer** — an authenticated user (Supabase `auth.users` row, Google-backed). Creates and edits sessions.
- **Client** — receives plans via URL (no auth; URL is an unguessable UUID; data fetched via the `get_plan_full` RPC).
- **Session** — a workout plan
  - `id`, `clientName`, `title`, `circuitCycles` (JSON map), `preferredRestIntervalSeconds`, `version`, `planUrl`, `lastPublishedAt`, `sentAt`, `deletedAt`, `practiceId`, `firstOpenedAt`, `lastPublishError`, `publishAttemptCount`
- **ExerciseCapture** — one item in a session
  - `id`, `position`, `name`, `mediaType` (photo/video/rest), `rawFilePath`, `convertedFilePath`, `thumbnailPath`, `videoDurationMs`, `archiveFilePath`, `archivedAt`
  - `reps`, `sets`, `holdSeconds`, `notes`, `customDurationSeconds`
  - `circuitId`, `includeAudio`, `conversionStatus`
- **Circuits** — group of consecutive exercises with shared `circuitId`. `circuitCycles` on session = how many times the group repeats.
- **Rest periods** — `mediaType: rest`. Compact inline bars between exercise cards. Auto-inserted every N minutes (N learned from user's drag behaviour, default 10).
- **Plan versions** — increments on each Publish. URL stays the same; client always sees latest via the `get_plan_full` RPC.
- **Credit** — unit of publishing capacity. One plan = 1 credit (1-8 exercises), 2 credits (9-15), 3 credits (16+). Purchased in bundles via PayFast on the web portal. Consumed atomically on publish.

## Feature State

### Trainer App
- **Session shell** — horizontal PageView with Studio (edit) and Camera (capture) modes. New Session → Camera first. Existing session → Studio. Swipe between modes via edge pull-tabs (coral pills with edit/camera icons).
- **Camera mode** — full-screen shutter, short-press = photo, long-press = video. Per-second haptic ticks + pulsing red dot during recording. 30s auto-stop with double-tap haptic. Pinch-to-zoom + 0.5x/1x/2x/3x lens pills. Peek box at left edge shows last thumbnail + count. No retake — errors fix in Studio.
- **Studio mode** — bottom-anchored list (newest at the bottom for one-handed reach). Expandable exercise cards with vertical-layout sliders (label above, slider full-width below). Thumbnail tap opens a full-screen media viewer. Top-bar import icon supports multi-select photos/videos. Circuits via link button; drag-to-detach. Rest periods as inline bars.
- **Native conversion pipeline** — iOS AVAssetReader/Writer + vImage/Accelerate. H.264/HEVC input. Two-zone rendering: body crisp via MediaPipe/Vision person segmentation, equipment dimmed to ~35% for context.
- **Raw archive pipeline** — 720p H.264 compression of the raw capture saved to `{Documents}/archive/` (90-day retention). Cloud upload waits for auth-scoped storage.
- **Video-length-as-one-rep** — when a video exercise has a captured `videoDurationMs`, estimated duration uses that per-rep instead of the hardcoded 3s default.
- **Workout preview** — swipeable card deck with 15s prep countdown before every exercise, timer chip in bottom-right with three-mode tap behaviour (skip prep / pause / resume). Rest pages mirror the same chip. Swipe/arrow skips cancel the current timer cleanly.
- **Share** — URL-only iOS share sheet so WhatsApp/Messages unfurl a clean link preview.
- **Auth** — AuthGate wraps the app. No guest mode. Sign In screen with Google (live) and Apple (coming soon). First sign-in auto-claims the Carl-sentinel practice; subsequent sign-ins create a fresh personal practice.
- **Publish** — pre-flight file check → plan upsert → `consume_credit` RPC → media upload → exercises upsert → orphan cleanup → plan_issuances audit. Compensating refund ledger row on any post-consume failure.

### Client Web Player (session.homefit.studio)
- Anonymous read via `get_plan_full` RPC. Never queries the plans/exercises tables directly.
- Dark theme matching app.
- Swipeable card deck with progress bar + nav chevrons + dot indicators (dots hide past 10 slides).
- Circuit unrolling (each round shown as separate slide). Indicator bar: "Circuit · Round 2 of 3 · Exercise 1 of 3".
- Videos auto-play muted + looped on any active slide. Per-video play overlay only surfaces when the user explicitly pauses.
- Rest slides consolidated: rest card body + the same bottom-right timer chip. No more duplicate centred overlay.
- 15-second prep countdown always (even for the first exercise after Start Workout).
- Timer chip is the sole pause/play control — three modes: prep / running / paused. Tap to skip prep or toggle pause.
- Swipe / nav-chevron skips any slide including rest. Cancels current timer cleanly.
- WhatsApp OG preview via Vercel Edge Middleware.
- Service worker caches app shell + video media (with content-type validation). Cache name bumped on major changes.
- CSP + HSTS + Permissions-Policy headers.

### Web Portal (manage.homefit.studio — live on Vercel)
- Next.js 15 App Router (pinned to 15.5.15 for CVE-2025-66478 patch), @supabase/ssr cookie-based auth, Tailwind with brand tokens.
- Pages: Sign-In gate → Dashboard (practice switcher + credit balance) → Credits (bundle list + PayFast checkout) → Audit (plan_issuances table) → Members (owner-only invite UI).
- PayFast sandbox integration live; production merchant account pending.
- Never receives service role key — all writes via Supabase Edge Functions (`payfast-webhook`).
- Deployed to Vercel project `homefit-web-portal` under team `carlheinmosterts-projects`. DNS: `manage.homefit.studio` CNAME → `00596c638d4cefd8.vercel-dns-017.com.` at Hostinger. TLS via Vercel (auto-renew).
- Env vars set in Vercel (all envs): `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY` (publishable), `SUPABASE_SERVICE_ROLE_KEY` (secret), `APP_URL=https://manage.homefit.studio`, `PAYFAST_MERCHANT_ID=10000100`, `PAYFAST_MERCHANT_KEY=46f0cd694581a`, `PAYFAST_PASSPHRASE=`, `PAYFAST_SANDBOX=true`.
- Supabase auth: Site URL = `https://manage.homefit.studio`; redirect allowlist includes `https://manage.homefit.studio/**` + `http://localhost:3000/**`. Without this, Google OAuth bounced login to `session.homefit.studio` (the old Site URL).

## Current Phase

**Multi-tenant foundation is live.** Auth + RLS + credit deduction + audit all working end-to-end. First publish as a properly authenticated user happened 2026-04-17.

**Milestones complete:**
- **A** — Schema (practices, practice_members, credit_ledger, plan_issuances, plan.practice_id, plan.first_opened_at).
- **B** — Google Sign-In + AuthGate + sentinel-claim. Apple button scaffolded, pending Apple Developer enrolment approval.
- **C** — RLS lockdown scoped by practice membership. SECURITY DEFINER helpers `user_practice_ids()` / `user_is_practice_owner(pid)` avoid self-recursion.
- **D1** — Credit deduction at publish via `consume_credit` RPC. Refund ledger rows on failure.
- **D3** — Web portal deployed to Vercel at `manage.homefit.studio`. DNS + TLS live. Env vars + Supabase redirect allowlist configured.
- **D4 sandbox** — PayFast checkout flow + ITN webhook deployed. Edge function `payfast-webhook` ACTIVE v1. Smoke test step 1/4 confirmed (`/credits` bundle list renders on production URL).

**Milestones remaining:**
- **D2** — Publish-screen practice picker UI (Flutter).
- **D4 production** — Swap PayFast sandbox for real merchant credentials when Carl signs up.
- **E** — First-run onboarding polish for the second bio.

**Tomorrow's resume point (2026-04-18):**
1. Finish PayFast sandbox smoke test at `https://manage.homefit.studio/credits` → Buy Starter → test card `4000 0000 0000 0002` → verify return to `/credits/return` → dashboard balance +10.
2. If pass, sign off D4 sandbox and move to **D2** (Flutter practice picker in the publish flow).

**Blocked on Carl:**
- PayFast production merchant account (D4 prod).
- Apple Developer Program approval (~24-48h, enrolled 2026-04-17).

## Infrastructure Rules (learned the hard way)

- **On-device processing preferred** for MVP. Cloud APIs for premium features only.
- **Hosted REST APIs only** when cloud is needed. No self-hosted GPU pods.
- RunPod SSH from automated environments doesn't work reliably.
- Replicate free tier is too limited for SA-based developers (payment processing issues).
- Luma Labs phone verification doesn't work from SA.
- fal.ai works (email-only signup).
- Stability AI v2beta endpoints only.
- **OpenCV on iOS:** `VideoCapture` can't decode H.264/HEVC. Use native AVAssetReader/Writer via platform channel instead. OpenCV is fine for image-level operations (the actual line drawing algorithm).
- **HEVC simulator limitation:** iOS simulator can't decode HEVC. Works fine on real device.
- **Stale file paths after reinstall:** Fixed by storing relative paths via `PathResolver` and resolving at read time.
- **Flutter lifecycle quirk:** `window.rootViewController` may be nil in `didFinishLaunchingWithOptions` in Flutter 3.41.6. Use `self.registrar(forPlugin:)?.messenger()` instead.
- **Share.share() on simulator:** Needs `sharePositionOrigin` or silently fails. Provided in the call.
- **VPN interference:** NordVPN without split tunneling interferes with Xcode's device tunnel even over USB. Use quick toggle + `simctl install` / `xcrun simctl pbpaste` to avoid needing connected-debug for most things.
- **Claude Code operations note:** Running agents in background (`run_in_background: true`) lets Claude respond while long builds run. Never use `flutter run` — it's interactive and spawns lldb processes that don't clean up. Use `flutter build ios --debug --simulator` + `xcrun simctl install` + `xcrun simctl launch` instead.

## Business Case (validated)

Market research confirmed:
- **50-70% non-adherence** with home exercise programs. Only 35% fully adhere.
- **Compliance doubles** with visual instructions (38% → 77%)
- **#1 therapist barrier:** "Lack of time" to create visual plans
- **90% of SA healthcare workers** use messaging apps for work; **84% WhatsApp**
- **Nobody does on-device visual conversion** of trainer footage — we're unique
- **Groovi is the only SA competitor** (pre-built library, no custom capture)

See `docs/MARKET_RESEARCH.md` for the full research.

Pitch guidance: lead with adherence improvement and correct execution, not clinical outcomes (evidence still developing).

## Revenue Model

**Prepaid credits.** The billing unit is the plan URL — one credit consumed per unique plan, scaled by exercise count (1-8 = 1 credit, 9-15 = 2, 16+ = 3). Practice managers buy credit bundles on the web portal via PayFast. Any practitioner in a practice can consume credits to publish.

**Version-bump policy (decided, not yet enforced):** the first publish of a plan URL consumes a credit. Non-structural edits (reps, sets, hold, notes, filter params) are free forever. Structural edits (add/delete/reorder) are free for the first 24h after publish OR until the client first opens the link, whichever comes first. Past that window, structural changes require a new credit. Enforcement lives in the Flutter Studio UI (disabled add/reorder affordances post-lock).

**JIT (just-in-time client-pay) mode was considered and rejected** — adherence-damaging, undermines the platform's core value prop.

**Credit bundle prices (provisional):** 10/R250, 50/R1125, 200/R4000. Revisit once there's real usage data.

## Compliance

POPIA (South Africa) at minimum. Line drawings naturally de-identify clients — major privacy advantage built into the visual pipeline.

## Key Documents

- `CLAUDE.md` — this file
- `docs/POV_BRIEF.md` — Proof-of-value brief with vision and build plan
- `docs/MARKET_RESEARCH.md` — Competitive landscape + business case validation
- `docs/ANIMATION_PIPELINE.md` — AI pipeline (parked) technical spec
- `docs/BACKLOG.md` — Deferred work with rationale
- `docs/PENDING_DEVICE_TESTS.md` — Things landed on main that haven't been verified on Carl's iPhone yet
- `supabase/schema.sql` — Canonical fresh-install schema (reference)
- `supabase/schema_milestone_a.sql` — Practices, credits, audit schema
- `supabase/schema_milestone_c.sql` — RLS lockdown + consume_credit
- `supabase/schema_milestone_c_recursion_fix.sql` — SECURITY DEFINER helpers that fixed the policy recursion
- `supabase/schema_milestone_d4.sql` — PayFast pending_payments table
- `app/lib/theme.dart` — Brand theme tokens
- `app/lib/widgets/powered_by_footer.dart` — Shared Pulse Mark footer
- `app/ios/Runner/VideoConverterChannel.swift` — Native video pipeline
- `app/lib/screens/session_shell_screen.dart` — Capture/Studio mode shell
- `app/lib/services/upload_service.dart` — Publish flow with credit consumption
- `app/lib/services/auth_service.dart` — Sign-in + sentinel-claim logic
- `web-portal/` — Next.js practice-manager + credits portal
- `tools/filter-workbench/` — Python Streamlit tool for filter parameter tuning (blocked on cloud raw archive for real tuning)

## Development Guidelines

- Favour speed and validation over perfection — this is pre-product
- Use sub-agents in background for heavy implementation work; stay available for conversation
- Never use `flutter run` — use build + `simctl install` instead (see Infrastructure Rules)
- Build the Flutter app with: `cd app && flutter build ios --debug --simulator`
- Install with: `xcrun simctl install <device-id> <runner.app>`
- Launch with: `xcrun simctl launch <device-id> com.raidme.raidme`
- Web player auto-deploys via Vercel on `git push`
- Bump `sw.js` CACHE_NAME when making major web player changes
- Supabase schema changes: with the CLI linked, use `supabase db query --linked --file supabase/<file>.sql` to apply directly. Still keep a human-readable `.sql` file in `supabase/` for audit trail. Carl reviews the SQL file before apply.
- Supabase Edge Functions: `supabase functions deploy <name>` for the PayFast webhook and friends.
- Web portal deploys via Vercel on push (similar to web-player). DNS CNAME `manage.homefit.studio` → `00596c638d4cefd8.vercel-dns-017.com.` live at Hostinger.
- Always consider offline-first — the bio must be able to work without signal

## Simulator Testing Notes

- Physical device UDID (Carl's iPhone): `00008150-001A31D40E88401C`
- Current simulator: iPhone 16e (`E4285EC5-6210-4D27-B3AF-F63ADDE139D9`)
- Push media to simulator: `xcrun simctl addmedia <device-id> <file>`
- Read simulator clipboard: `xcrun simctl pbpaste <device-id>` (use this to grab shared URLs)
- Query Supabase directly: `curl -H "apikey: <key>" "https://yrwcofhovrcydootivjx.supabase.co/rest/v1/plans?..."`
