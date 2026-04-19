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
- **Non-blocking publish** — Publishing runs in the background. The practitioner never waits for uploads. Core UX principle.
- **Line drawings de-identify** — POPIA-friendly by design. Client's face/body is abstracted away.
- **Single accent colour** — Coral orange throughout. No teal or competing accents. (The rest period blue-grey is a distinct visual category, not an accent.)
- **Progressive auth** — Email + optional password, magic-link fallback. Google / Apple SDK code stays wired but UI-removed (see `docs/BACKLOG_GOOGLE_SIGNIN.md`).
- **No modal confirmations** (R-01) — Destructive actions fire immediately with an undo SnackBar + 7-day soft-delete recycle bin. Never "Are you sure?".
- **Practitioner, always** (R-06) — UI copy uses "practitioner". "Bio" / "physio" / "trainer" / "coach" are retired role nouns. Client-facing copy uses `{TrainerName}` with "your practitioner" as the fallback.

## Mobile ↔ Web Player Parity (R-10)

The trainer Flutter app and the client web player at `session.homefit.studio`
are ONE logical product. **Every UX change must land in both surfaces in
the same PR/branch**. If a brief asks you to "update the player", that
means BOTH the Flutter player (`app/lib/screens/plan_preview_screen.dart` +
`widgets/progress_pill_matrix.dart`) AND the web player (`web-player/`).

When implementing, port the change to mobile FIRST (faster iteration),
verify on device, then mirror to web in the SAME branch. Never ship a
mobile-only or web-only player change.

When a sub-agent's brief says "the player", the agent must update both.
When Carl says "the player", he means both. Always remind him to test both.

Surfaces required to match:
- Pill matrix (sizing, colours, scroll behaviour, label grammar, fill rules)
- ETA / time row (format, fonts, colours)
- Bottom decoded grammar
- Prep overlay + flashing
- Pause / play affordances
- Peek overlay (centered, content)
- Logo
- Brand tokens (coral, sage, surface)

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

- **Practice** — top-level tenant. Created automatically on first sign-in (either claims the Carl-sentinel or spins up a fresh personal practice). A practitioner can belong to multiple practices; the publish-screen picker is where they choose which one pays.
- **Practice member** — practitioner-in-practice with a role (`owner` or `practitioner`). Owner can invite other practitioners and buy credits. Practitioners consume credits to publish.
- **Practitioner** — an authenticated user (Supabase `auth.users` row, email-backed). Creates and edits sessions. "Trainer" is the legacy column name in the DB (`trainer_id`) — UI copy is always "practitioner".
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
- **Studio mode** — bottom-anchored list (newest at the bottom for one-handed reach). Redesigned v1.1 (commit `e12b2fd`) per `docs/design/project/components.md`:
  - **Gutter Rail** — left-edge vertical rail, thumbnail + drag handle + ordinal. Circuit rounds nest under a Circuit Header.
  - **Inline Action Tray** — expand-card reveals edit controls in place of a separate tap target; no header buttons (R-02 header purity).
  - **Thumbnail Peek** — long-press on a thumbnail opens a peek sheet with delete / replace / treatment picker. Delete fires immediately with an undo SnackBar (R-01).
  - **Circuit Control Sheet** — long-press the Circuit Header opens a sheet for round count, break circuit (immediate undo), insert rest.
  - **Sliders** — vertical layout (label above, slider full-width below), pill-shaped.
  - **Known layout bug** — plans that contain a circuit cause the list to stack to multi-viewport heights. Two fixes attempted on main (`9bfc0f8`, `326c6b8`) did not land. Nuclear third attempt active on branch `fix/studio-reorderable-listview` (swap `CustomScrollView + SliverReorderableList` for plain `ReorderableListView.builder`). **Unmerged as of 2026-04-18 checkpoint.**
- **Native conversion pipeline** — iOS AVAssetReader/Writer + vImage/Accelerate. H.264/HEVC input. Two-zone rendering: body crisp via MediaPipe/Vision person segmentation, equipment dimmed to ~35% for context.
- **Raw archive pipeline** — 720p H.264 compression of the raw capture saved to `{Documents}/archive/` (90-day retention). Cloud upload waits for auth-scoped storage.
- **Video-length-as-one-rep** — when a video exercise has a captured `videoDurationMs`, estimated duration uses that per-rep instead of the hardcoded 3s default.
- **Workout preview** — swipeable card deck with 15s prep countdown before every exercise, timer chip in bottom-right with three-mode tap behaviour (skip prep / pause / resume). Rest pages mirror the same chip. Swipe/arrow skips cancel the current timer cleanly. Progress-pill matrix (see below) pending merge of `feat/progress-pills`.
- **Share** — URL-only iOS share sheet so WhatsApp/Messages unfurl a clean link preview.
- **Auth** — AuthGate wraps the app. Progressive: email + optional password → `signInWithPassword`; empty password OR bad creds falls through to `signInWithOtp` (magic link). Google / Apple SDK code stays wired in `auth_service.dart` but UI is removed — see `docs/BACKLOG_GOOGLE_SIGNIN.md` for the nonce-mismatch post-mortem. Home screen shows a one-time "Set a password?" banner for magic-link-only users; dismissal tracked in `shared_preferences`. First sign-in auto-claims the Carl-sentinel practice; subsequent sign-ins create a fresh personal practice.
- **Build-marker** — short git SHA baked at build time via `--dart-define=GIT_SHA=$(git rev-parse --short HEAD)`. Rendered at 35% opacity in the Pulse Mark footer on Home only. `install-sim.sh` / `install-device.sh` wire this automatically. Falls back to `"dev"`.
- **Publish** — pre-flight file check → plan upsert → `consume_credit` RPC → media upload → exercises upsert → orphan cleanup → plan_issuances audit. Compensating refund ledger row on any post-consume failure.

### Client Web Player (session.homefit.studio)
- Anonymous read via `get_plan_full` RPC. Never queries the plans/exercises tables directly.
- Dark theme matching app.
- **Progress-pill matrix** (pending merge of `feat/progress-pills`) — replaces the linear progress bar. Pills stack vertically for circuit cycles (row 1 = plan-level flow; rows 2..N = circuit rounds beneath their circuit head). States: idle / active (pulse-glow border + fluid-fill timer as two separate channels) / completed (muted) / rest (blue-grey fill). Auto-scrolls to keep the active pill horizontally centred. Long-press-and-slide navigator. Three size tiers (spacious / medium / dense). ETA widget at right-end: `7:42 left` + `~7:42 PM` — when paused, `remaining` holds but `finish` drifts +1s/sec (wall clock). Mockup at `docs/design/mockups/progress-pills.html`.
- Swipeable card deck with nav chevrons + dot indicators (dots hide past 10 slides).
- Circuit unrolling (each round shown as separate slide). Indicator bar: "Circuit · Round 2 of 3 · Exercise 1 of 3".
- Videos auto-play muted + looped on any active slide. Per-video play overlay only surfaces when the user explicitly pauses.
- Rest slides consolidated: rest card body + the same bottom-right timer chip. No more duplicate centred overlay.
- 15-second prep countdown always (even for the first exercise after Start Workout).
- Timer chip is the sole pause/play control — three modes: prep / running / paused. Tap to skip prep or toggle pause.
- Swipe / nav-chevron skips any slide including rest. Cancels current timer cleanly.
- WhatsApp OG preview via Vercel Edge Middleware.
- Service worker caches app shell + video media (with content-type validation). Cache name bumped on major changes (current target on `feat/progress-pills`: `homefit-player-v11-pill-matrix`).
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

**POV is passed. MVP is in flight.** Target: 2026-05-02 (14 days from 2026-04-18). Full plan in `docs/MVP_PLAN.md`. The first practitioner other than Carl is **Melissa** (biokineticist, high-influence SA network) — mid-Week-2 onboarding.

**Milestones complete:**
- **A** — Schema (practices, practice_members, credit_ledger, plan_issuances, plan.practice_id, plan.first_opened_at).
- **B** — AuthGate + sentinel-claim. Auth model shifted 2026-04-18: email + optional password → magic-link fallback. Google parked (nonce mismatch — see `docs/BACKLOG_GOOGLE_SIGNIN.md`). Apple still scaffolded, waits on Apple Developer approval.
- **C** — RLS lockdown scoped by practice membership. SECURITY DEFINER helpers `user_practice_ids()` / `user_is_practice_owner(pid)` avoid self-recursion.
- **D1** — Credit deduction at publish via `consume_credit` RPC. Refund ledger rows on failure.
- **D3** — Web portal deployed to Vercel at `manage.homefit.studio`. DNS + TLS live.
- **D4 sandbox** — PayFast checkout flow + ITN webhook deployed.
- **Brand system v1.1** (2026-04-18) — `docs/design/project/tokens.json` + `components.md` + `voice.md` locked. Design Rules R-01..R-08 binding.
- **Studio redesign v1.1** (2026-04-18) — Gutter Rail + Inline Action Tray + Thumbnail Peek + Circuit Control Sheet components landed on main. Layout bug still pending (see below).
- **Build-marker infrastructure** (2026-04-18) — short SHA baked via `--dart-define`, rendered in Pulse Mark footer, scripted in `install-sim.sh` / `install-device.sh`.

**Milestones remaining (MVP blockers):**
- **Studio layout bug** — plans with circuits stack to multi-viewport heights. Third fix attempt on `fix/studio-reorderable-listview` (plain `ReorderableListView.builder`). Pending device verification.
- **Progress-pill matrix** — Flutter widget + web player version on `feat/progress-pills` awaiting merge. ETA widget completion running.
- **D2** — Publish-screen practice picker UI (Flutter).
- **D4 production** — Swap PayFast sandbox for real merchant credentials when Carl signs up.
- **Three-treatment video model** — line drawing (default) / black-and-white / original colour. Per-client consent gate. Colour requires explicit consent. Treatment change past 24h consumes a credit. Schema migration needed (`clients` table, `exercises.media_treatment` enum, `clients.video_consent` jsonb) + private `raw-archive` bucket (service-role-only, 720p H.264, retained until practice deletion). Not yet implemented.
- **Referral loop** (MVP Week 1) — opaque 6-8 char codes, `/join/{code}` capture, both-sided +10 credits on referee's first paid purchase.
- **First-run onboarding polish + legal + support surface** (MVP Week 1-2).

**Blocked on Carl:**
- PayFast production merchant account (D4 prod + referral reward trigger).
- Apple Developer Program approval (~24-48h, enrolled 2026-04-17). Flipping `_appleEnabled = true` + re-adding the Apple button unblocks Apple sign-in.
- Supabase dashboard: bump JWT expiry 30 → 90 days (Project Settings → Auth) for longer offline-session runway.
- Legal: POPIA privacy page + terms-of-service copy review.

**Deferred past MVP (explicitly):**
- Android app — iOS only for MVP. Swift native pipeline stays the cornerstone.
- AI style transfer (Stability AI, Kling O1, SayMotion) — still premium-tier, still parked.
- Ongoing referral commission (rev-share on every purchase).

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
- **VPN interference:** resolved 2026-04-18 — Carl confirms `install-device.sh` now runs with NordVPN on. `xcrun devicectl` + Claude API coexist fine. Keep the split-tunneling note in case it recurs after a NordVPN / iOS update.
- **Google Sign-In nonce mismatch:** iOS `GoogleSignIn` 8.x auto-injects a nonce claim into the id_token; Flutter `google_sign_in` v6/v7 never exposes the raw nonce to Dart; Supabase `signInWithIdToken` rejects. Parked — MVP ships with email + password + magic link. See `docs/BACKLOG_GOOGLE_SIGNIN.md` for the full post-mortem and re-enablement options.
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
- `docs/POV_BRIEF.md` — Proof-of-value brief with vision and build plan (historic; POV passed)
- `docs/MVP_PLAN.md` — Active 14-day plan to 2026-05-02 (Melissa onboarding + referral loop + PayFast prod + polish)
- `docs/MARKET_RESEARCH.md` — Competitive landscape + business case validation
- `docs/ANIMATION_PIPELINE.md` — AI pipeline (parked) technical spec
- `docs/BACKLOG.md` — Deferred work with rationale
- `docs/BACKLOG_GOOGLE_SIGNIN.md` — Google Sign-In nonce-mismatch post-mortem + re-enablement paths
- `docs/DATA_ACCESS_LAYER.md` — The binding rule on how each surface talks to Supabase (one file per surface, typed contracts, how to add a new RPC)
- `docs/PENDING_DEVICE_TESTS.md` — Things landed on main that haven't been verified on Carl's iPhone yet
- `docs/design/project/index.html` — Design system doc (browsable)
- `docs/design/project/components.md` — Component inventory + Design Rules R-01..R-08
- `docs/design/project/voice.md` — Voice + tone, practitioner vocabulary, error-message formula
- `docs/design/project/tokens.json` — Canonical design tokens (colour / spacing / radius / motion / typography)
- `docs/design/mockups/progress-pills.html` — Progress-pill matrix mockup
- `supabase/schema.sql` — Canonical fresh-install schema (reference)
- `supabase/schema_milestone_a.sql` — Practices, credits, audit schema
- `supabase/schema_milestone_c.sql` — RLS lockdown + consume_credit
- `supabase/schema_milestone_c_recursion_fix.sql` — SECURITY DEFINER helpers that fixed the policy recursion
- `supabase/schema_milestone_d4.sql` — PayFast pending_payments table
- `app/lib/theme.dart` — Brand theme tokens
- `app/lib/widgets/powered_by_footer.dart` — Shared Pulse Mark footer (+ build-SHA marker)
- `app/lib/widgets/gutter_rail.dart` / `inline_action_tray.dart` / `thumbnail_peek.dart` / `circuit_control_sheet.dart` / `set_password_sheet.dart` / `undo_snackbar.dart` — v1.1 Studio components + auth upgrade + R-01 undo
- `app/ios/Runner/VideoConverterChannel.swift` — Native video pipeline
- `app/lib/screens/session_shell_screen.dart` — Capture/Studio mode shell
- `app/lib/screens/sign_in_screen.dart` — Progressive email + password + magic-link gate
- `app/lib/services/api_client.dart` — Single enumerated Supabase surface for the Flutter app (see `docs/DATA_ACCESS_LAYER.md`)
- `app/lib/services/upload_service.dart` — Publish flow with credit consumption (routes through `ApiClient`)
- `app/lib/services/auth_service.dart` — Sign-in + sentinel-claim logic (Google/Apple wired but UI-removed; routes through `ApiClient`)
- `web-player/api.js` — Web player's single enumerated Supabase surface (anon `get_plan_full` RPC only)
- `web-portal/src/lib/supabase/api.ts` — Web portal's typed Supabase surface (PortalApi + AdminApi)
- `web-portal/src/lib/supabase/database.types.ts` — Generated Supabase types (regenerate after schema migrations)
- `install-sim.sh` — Simulator reset + rebuild + relaunch with SHA marker
- `install-device.sh` — Physical iPhone release build + install (runs with VPN on)
- `web-portal/` — Next.js practice-manager + credits portal
- `tools/filter-workbench/` — Python Streamlit tool for filter parameter tuning (blocked on cloud raw archive for real tuning)

## Development Guidelines

- Favour speed and validation over perfection — MVP ship window is 2 weeks
- Use sub-agents in background for heavy implementation work; stay available for conversation
- Never use `flutter run` (R-08) — use build + `simctl install` instead
- Simulator: `./install-sim.sh` (builds with SHA marker, uninstalls for a fresh Sign-In screen, relaunches on iPhone 16e)
- Physical device: `./install-device.sh` (pulls main, release build, installs to iPhone CHM; runs with VPN on)
- Manual build: `cd app && flutter build ios --debug --simulator --dart-define=GIT_SHA=$(git -C /Users/chm/dev/TrainMe rev-parse --short HEAD)`
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
