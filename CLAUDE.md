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
- **Logo:** Matrix of pills — a slice of a training session (3 ghost exercises tapering in from each side → 2-cycle circuit in a coral tint band → rest). Two variants: matrix-only (tight chrome — headers, footers, favicons, paired with a separate wordmark) + lockup (matrix + wordmark stacked, for hero surfaces, OG cards, emails). Geometry and callers in `HomefitLogo.tsx` / `homefit_logo.dart` / `buildHomefitLogoSvg()`. Signed off at `docs/design/mockups/logo-ghost-outer.html`.
- **Typography:** Montserrat (headings, 600-800), Inter (body, 400-700)
- **Theme tokens:** See `app/lib/theme.dart` (Flutter) and `web-player/styles.css` `:root` (web)

## Versioning

Three surfaces, three independent versioning schemes — by design. Do not try to unify them; the cadences differ on purpose.

- **Web (portal + player)** — git SHA is the version. Each merge to `main` triggers a Vercel deploy and the deployed SHA + branch is rendered at 35% opacity in the page footer / corner chip on every route (`web-portal/src/components/BuildInfo.tsx` mounted in the root layout; `web-player/app.js` + `lobby.js` populate `#footer-version` / `#lobby-meta-version` from `window.HOMEFIT_CONFIG.gitSha` + `gitBranch`, which `web-player/build.sh` writes at deploy time from Vercel's `VERCEL_GIT_COMMIT_SHA` + `VERCEL_GIT_COMMIT_REF`). Date-based release tags (`v2026-MM-DD.N`) land on `main` merges for human-readable history. Falls back to `dev` / `local` for local development so the chip still renders.
- **Mobile (Flutter)** — `pubspec.yaml` `version: 1.0.0+1` controls TestFlight uploads. The `+N` build number must increment on every upload (Apple Connect rejects duplicates). Git tags as `mobile-v{version}+{build}`. Apple gates cadence; web deploys daily, mobile maybe weekly.
- **Database (Supabase)** — migration filename timestamp is the version. SQL files in `supabase/schema_*.sql` are append-only and applied in order via `supabase db query --linked --file ...`. The local SQLite mirror has its own `app/lib/services/local_db.dart` `_dbVersion` integer that bumps on every column-add / table-add migration.

The fixed-corner build chip on the web surfaces is the canonical way to confirm what's deployed; for mobile, the Settings → About panel surfaces the same SHA marker.

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
- **Native haptic channel:** `HomefitHapticsChannel.swift` — `UIImpactFeedbackGenerator`-based platform channel. Note: iOS suppresses ALL vibration during active AVCaptureSession mic use (hardware-level protection). Use visual feedback (coral border glow) for camera UX instead.
- **OpenCV binding:** `opencv_dart` v2.x (builds from source via hooks — not the old prebuilt pod that broke)
- **Local storage:** SQLite via `sqflite`. All paths stored relative via `PathResolver`.
- **Conversion service:** Singleton pattern, survives screen navigation. FIFO queue processes captures sequentially. Studio uses `AutomaticKeepAliveClientMixin` to survive PageView page-swaps (without it, swiping to Camera disposed Studio and killed the conversion listener — root cause of the photo-spinner bug).
- **Raw-video archive pipeline:** After conversion, the raw capture is AVAssetExportSession-compressed to 720p H.264 and archived locally at `{Documents}/archive/{exerciseId}.mp4`. 90-day retention. Cloud upload to a private bucket is deferred until the auth story is fully in place (backlog item).
- **Backend:** Supabase (yrwcofhovrcydootivjx.supabase.co). **CLI is linked** — Claude sessions can run migrations directly via `supabase db query --linked ...` instead of asking Carl to paste SQL in the dashboard.
  - **Tenancy:** `practices` + `practice_members` (role=owner|practitioner) form the tenancy boundary. A trainer can belong to multiple practices; first-ever sign-in claims the Carl-sentinel practice. Fresh sign-ins auto-create a personal practice.
  - **Clients:** `clients` table (practice-scoped; unique on `(practice_id, name)`) carries the per-client `video_consent` jsonb `{line_drawing, grayscale, original, avatar, analytics_allowed}`. `line_drawing` is always true (de-identified by pipeline; consent can't be withdrawn). `analytics_allowed` gates plan-usage analytics collection on the web player. `plans.client_id` FK → `clients.id` (nullable on legacy rows; populated by `upsert_client` on new publishes). Client-management RPCs: `upsert_client`, `set_client_video_consent`, `get_client_by_id`, `list_practice_clients` (all SECURITY DEFINER + practice-membership checks).
  - **Plan data:** `plans`, `exercises` with full data model (circuits, rest periods, audio, custom durations, versions, thumbnails). `plans.practice_id` + `plans.first_opened_at` + `plans.client_id`.
  - **Analytics (Wave 17):** `client_sessions` (one row per unique visitor session on a plan), `plan_analytics_events` (append-only, 13 event types from `plan_opened` through `exercise_navigation_jump`), `plan_analytics_daily_aggregate` (pre-rolled daily stats), `plan_analytics_opt_outs` (client opt-out records). 7 RPCs: `record_plan_event`, `record_session_start`, `get_plan_analytics`, `get_exercise_analytics`, `opt_out_plan_analytics`, `check_analytics_opt_out`, `get_plan_analytics_summary`. Client consent via `analytics_allowed` key in `video_consent` jsonb (practitioner-toggled) + client-side consent banner on web player. RLS scoped by practice membership.
  - **Billing:** `credit_ledger` (append-only, consumption/purchase/refund/adjustment) + `plan_issuances` (append-only audit of every publish) + `pending_payments` (PayFast intent). Credit cost: 1 credit if estimated plan duration ≤ 75 min, 2 credits if > 75 min. Treatment switching on the player (line-drawing / B&W / original) is free — both files are stored once, consent gates playback.
  - **Atomic credit consumption:** `consume_credit(p_practice_id, p_plan_id, p_credits)` SECURITY DEFINER fn with FOR UPDATE locking. Called from publish flow. Accompanying `practice_credit_balance`, `practice_has_credits`.
  - **`credit_ledger` is RPC-write-only** — clients cannot INSERT/UPDATE/DELETE; only `consume_credit` / `refund_credit` (SECURITY DEFINER, owner `postgres`) may write. `authenticated` keeps SELECT (scoped by `credit_ledger_select_own` RLS policy); `anon` has no access at all. Purchases land via the PayFast webhook + sandbox bounce-back using the service-role key. See `supabase/schema_milestone_e_revoke_credit_ledger_writes.sql`.
  - **Anonymous plan read:** `get_plan_full(p_plan_id)` SECURITY DEFINER RPC. Web player calls this; no direct SELECT on plans/exercises for anon. Returns per-exercise `line_drawing_url` (always) + `grayscale_url` / `original_url` (consent-gated; NULL if the client hasn't granted that treatment). Signed URLs are generated inline via `public.sign_storage_url(bucket, path, expires_in)` — a pgjwt-backed helper that pulls the JWT secret + base URL from `vault.secrets` (`supabase_jwt_secret`, `supabase_url`). If either vault secret is missing, the helper returns NULL and clients gracefully fall back to line-drawing only.
  - **RLS:** scoped-by-practice via the helper fns `user_practice_ids()` and `user_is_practice_owner(pid)`. Avoids the self-referential recursion trap that direct subqueries on `practice_members` would cause. The helper fns are SECURITY DEFINER and bypass RLS.
  - **Storage buckets:**
    - `media` (public read for sharing plan URLs; INSERT/UPDATE/DELETE scoped by path-prefix→plan→practice membership). Stores the line-drawing treatment.
    - `raw-archive` (PRIVATE; SELECT blocked for anon+authenticated, service-role reads + signed URLs only). Stores the grayscale + original treatments (same file, treatment chosen client-side). Path shape: `{practice_id}/{plan_id}/{exercise_id}.mp4`. INSERT/UPDATE/DELETE gated by `can_write_to_raw_archive(path)` helper which parses the first path segment as practice_id and checks membership.
  - **Referral loop (Milestone F + Milestone M):** `referral_codes` (one opaque 7-char slug per practice, unambiguous alphabet) + `practice_referrals` (referee PK → exactly one referrer per referee; `goodwill_floor_applied` tracks first-rebate clamp) + `referral_rebate_ledger` (append-only, `numeric(10,4)` credits). Model (current, per Milestone M): signup bonuses live at signup time — `credit_ledger` kind `signup_bonus` (+3 organic) + kind `referral_signup_bonus` (+5 on claim) → 8 total for referees. Every referee PayFast purchase pays the referrer a 5% lifetime credit rebate; on the referrer's FIRST rebate from each referee, if raw 5% rounds to < 1 credit it's clamped UP to 1 (goodwill floor). Subsequent rebates are raw fractional 5%. **Single-tier only** — a `BEFORE INSERT` trigger rejects any row whose proposed referrer is already a referee (or vice versa), so A→B→C pays A nothing from C. POPIA-respecting: referee names default to anonymised "Practice N" labels; referees opt in via `referee_named_consent`. Webhook path: `record_purchase_with_rebates(...)` SECURITY DEFINER RPC wraps the purchase ledger insert + rebate rows in ONE transaction. Same lockdown pattern as `credit_ledger` (PR #3) — client INSERT/UPDATE/DELETE revoked on all three tables; SELECT scoped via `user_practice_ids()`, with the rebate ledger visible only to the referrer's practice.
- **Email:** Resend SMTP relay for Supabase auth emails (magic links, password resets, signup confirmations). Sender `noreply@homefit.studio`, display name `homefit team`, host `smtp.resend.com:465`, username `resend`. DKIM record on `resend._domainkey.homefit.studio`; SPF + bounce-handling MX on `send.homefit.studio` — apex SPF deliberately untouched so future Hostinger mailboxes (e.g. `support@`) can be set up without collision. Supabase email rate limit raised from default 4/hour to 30/hour. All 6 auth email templates (confirm-signup, magic-link, reset-password, change-email, invite-user, reauthentication) are branded dark + coral, applied 2026-05-10 via the Management API (`PATCH /v1/projects/{ref}/config/auth`), and source-of-truth lives in `supabase/email-templates/`. The matrix logo at the top of each template is a 768×152px PNG (rendered by `tools/email-logo-render/render.py` from the canonical SVG geometry in `web-portal/src/components/HomefitLogo.tsx`) inlined as a base64 data URI — works in 95%+ of email clients without waiting for a Vercel deploy of `web-portal/public/email/logo.png`. Re-apply with the one-liner in the folder's README. The Supabase CLI doesn't expose auth template config but the Management API does — Personal Access Token lives in the macOS Keychain after `supabase login`. Setup runbook: `docs/RESEND_SETUP.md`.
- **Web player:** Static HTML/CSS/JS on Vercel, auto-deploys from GitHub (`web-player/` directory)
- **Domain:** Hostinger DNS, CNAME `session` → `cname.vercel-dns.com` (updated to `00596c638d4cefd8.vercel-dns-017.com.` per Vercel's new IP range)
- **OG meta tags:** Vercel Edge Middleware (`web-player/middleware.js`) serves bot-friendly HTML for WhatsApp link previews
- **Service worker:** `web-player/sw.js` caches app shell for offline. Current cache name `homefit-player-v75` — bump on major changes.

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
- **Credit** — unit of publishing capacity. One plan = 1 credit (estimated duration ≤ 75 min), 2 credits (> 75 min). Purchased in bundles via PayFast on the web portal. Consumed atomically on publish.
- **Client session** (`client_sessions`) — one row per unique visitor session on a published plan. Tracks anonymous session-level engagement.
- **Plan analytics event** (`plan_analytics_events`) — append-only, 13 event types: `plan_opened`, `exercise_started`, `exercise_completed`, `exercise_skipped`, `workout_started`, `workout_completed`, `workout_paused`, `workout_resumed`, `treatment_changed`, `body_focus_toggled`, `rest_skipped`, `rest_extended`, `exercise_navigation_jump`. Consent-gated via `analytics_allowed` key in the client's `video_consent` jsonb.
- **Analytics opt-out** (`plan_analytics_opt_outs`) — client-initiated opt-out per plan (via `/what-we-share` page). Stops all future event recording for that plan.

## Feature State

### Trainer App
- **IA**: **Clients-as-Home spine** (R-11 twin of portal `/clients` + `/clients/[id]`). Home is the clients list with a `New Client` FAB; tap a client → `ClientSessionsScreen` with its editable name (dashed underline) + consent chip + per-client session list + `New Session` FAB. No quick-capture escape hatch — capture is always client-first.
- **Session shell** — horizontal PageView with Studio (edit) and Camera (capture) modes. Session creation carries the parent `client_id`. Session title format: `{DD Mon YYYY HH:MM}` (client prefix retired — client context is implicit in the nav).
- **Camera mode** — full-screen shutter, short-press = photo, long-press = video. Pulsing red dot during recording. 30s auto-stop. Pinch-to-zoom + right-edge vertical lens pills (0.5x ultrawide via CameraDescription swap, 1x/2x/3x). Slide-up-to-lock recording gesture with coral screen-edge border glow in armed zone (visual feedback replaces haptics which iOS suppresses during mic use). Permanent shutter hint (3 states: idle/recording/locked). Camera icon on Studio toolbar; library moved to viewfinder bottom-left. Peek box at left edge shows last thumbnail + count.
- **Studio mode** — bottom-anchored list (one-handed reach). Gutter Rail + Inline Action Tray + Thumbnail Peek + Circuit Control Sheet per `docs/design/project/components.md`. Studio header inline-edit writes `session.title` (not `clientName` — that's now a legacy mirror of `client.name`). Right-swipe on exercise card = swipe-to-duplicate (deep copy + undo via SnackBar). Treatment-aware video thumbnails: 3 variants per video (line from converted, B&W with body-focus from raw, color without body-focus from raw). Toolbar layout: workflow pill (Camera → Preview → Publish → Share with raised `surfaceRaised` background) + right-aligned Download utility (`cloud_download_outlined`, saves all session exercises to camera roll). Icons white-default (coral reserved for state cues); 48px toolbar, 28px icons. Publish success = dismissible "Published ✓" toast (checkmark icon retired). Uses `AutomaticKeepAliveClientMixin` to survive PageView page-swaps.
- **Progress-pill matrix** — empty pills, full-coral completed, sage rest, 3-number ETA, luxurious bottom row. Replaces the linear progress bar on both player + preview.
- **Native conversion pipeline** — iOS AVAssetReader/Writer + vImage/Accelerate. Two-zone rendering: body-zone crisp via Vision person segmentation, background-zone dimmed via the `backgroundDim` constant. **Line-drawing tuning LOCKED at v6**: see `VideoConverterChannel.swift` top-of-file comment. BGRA byte-order bug fixed mid-tune.
- **Raw archive pipeline** — 720p H.264 local archive AND cloud upload to private `raw-archive` Supabase bucket on publish (best-effort; non-blocking). Three-treatment feature pulls from this at playback time.
- **Video-length-as-one-rep** — when a video exercise has a captured `videoDurationMs`, estimated duration uses that per-rep.
- **Workout preview** — swipeable card deck with 15s prep countdown + big coral countdown overlay on video during prep. Tap video = mode-aware pause. YouTube-style centered play/pause overlay. Three-treatment segmented control "Line · B&W · Original" below exercise name; disabled segments show lock glyph + tooltip.
- **Share** — URL-only iOS share sheet so WhatsApp/Messages unfurl a clean preview.
- **Auth** — AuthGate + AuthService. Progressive email + optional password → `signInWithPassword`; empty or bad password → magic-link fallback. Google/Apple SDK code wired but UI-removed. Password can be set/changed from Settings at any time.
- **Practice switcher** — coral chip top-left of Home + Studio. Bottom-sheet picker lists memberships with `{credits} · {role}` to disambiguate. Selection persisted in `SharedPreferences`. Studio shows the chip but it's non-interactive (no mid-session switch).
- **Offline-first** (Milestone K) — `SyncService` + cache tables mirror cloud; all client reads from cache; client create/rename/consent writes go through `pending_ops` FIFO queue, flushed on reconnect. Subtle chip top of Home: "N pending" / "Offline". Publish stays online-only.
- **Build-marker** — short git SHA via `--dart-define=GIT_SHA=$(git rev-parse --short HEAD)`. Rendered at 35% opacity in the HomefitLogo footer on Home only.
- **Publish** — pre-flight file check → `consume_credit` RPC → plan version bump → media upload → exercises upsert → orphan cleanup → raw-archive best-effort upload → `plan_issuances` audit. Compensating refund ledger row on any post-consume failure. **Skip-if-unchanged optimisation:** metadata-only republishes (all exercises have `rawArchiveUploadedAt` set) skip ALL upload loops — zero list calls, zero file uploads. Only the metadata RPCs hit the network (~2s). Mixed publishes (some new exercises) use a storage-listing existence check to skip already-uploaded files.
- **Plan analytics** (Wave 17) — analytics consent toggle in client consent section. Per-client session cards show plan stats (Opened N x, X/Y completed, last Nh ago). Per-exercise stats bar with icons (eye/check/skip) for view/completion/skip counts.
- **Sticky defaults** (Wave 39.4) — `videoRepsPerLoop` + `interSetRestSeconds` carried forward from the client's last exercise via `client_exercise_defaults`.

### Client Web Player (session.homefit.studio)
- Anonymous read via `get_plan_full` RPC (single enumerated anon surface in `web-player/api.js`). Never queries tables directly.
- Dark theme matching app.
- **Progress-pill matrix** — empty pills, full-coral completed, sage `#86EFAC` rest. Active pill: pulse-glow border + fluid-fill timer. Auto-scrolls to keep the active pill centred. ETA widget at right-end: 3-number `1:36 · 7:42 left · ~7:42 PM`. R-10 parity with mobile preview.
- **Three-treatment segmented control** — Line · B&W · Original. CSS `filter: grayscale(1) contrast(1.05)` for the B&W treatment (same source video as Original). Consent-gated via `get_plan_full` signed URLs.
- **Prep-phase flash** — big coral countdown numbers overlay the video; top-bar token + active pill flash synchronously at 1 Hz.
- Swipeable card deck with nav chevrons + dot indicators (dots hide past 10 slides).
- Circuit unrolling (each round shown as separate slide). Indicator bar: "Circuit · Round 2 of 3 · Exercise 1 of 3".
- Videos auto-play muted + looped on any active slide. Per-video play overlay only surfaces when the user explicitly pauses.
- Rest slides consolidated: rest card body + the same bottom-right timer chip. No more duplicate centred overlay.
- 15-second prep countdown always (even for the first exercise after Start Workout).
- Timer chip is the sole pause/play control — three modes: prep / running / paused. Tap to skip prep or toggle pause.
- Swipe / nav-chevron skips any slide including rest. Cancels current timer cleanly.
- WhatsApp OG preview via Vercel Edge Middleware.
- Service worker caches app shell + video media (with content-type validation). Cache name bumped on major changes; current: `homefit-player-v75`.
- **Analytics consent banner** (Wave 17) — "Help {TrainerName} help you" banner on first visit. 12 event emitters (`plan_opened` through `rest_extended`) + 13th `exercise_navigation_jump` (pill + rep-stack taps). Completion CTA at workout end. `/what-we-share` transparency page with stop-sharing button. Opt-in gated by practitioner's `analytics_allowed` consent key.
- **Lazy video loading** — videos built with `data-src` + `preload="none"`, loaded on demand (current +/- 2 slides). Prevents Safari WebKit crash on large plans (46+ simultaneous video elements). Autoplay waits for `canplay` event.
- **Network-first media** in service worker (prevents stale/partial video caching). Cache name: `homefit-player-v75`.
- CSP + HSTS + Permissions-Policy headers. Inline scripts moved to external `.js` files for CSP `script-src 'self'` compliance.

### Web Portal (manage.homefit.studio — live on Vercel)
- Next.js 15 App Router (pinned to 15.5.15 for CVE-2025-66478 patch), @supabase/ssr cookie-based auth, Tailwind with brand tokens.
- **Navigation:** top-bar nav stripped (dashboard tiles ARE the menu). Right-cluster header: practice switcher + signed-in email chip.
- Pages: Sign-In gate → Dashboard (5 stat tiles, each clickable, credit balance + 5 most recent audit events with real data) → Clients (drill-in with client avatars via signed URLs from `raw-archive` bucket) → Credits (bundle list + PayFast checkout) → Audit (plan_issuances table with kind chips wrapping inline, full actor coverage 14/14 kinds, dedicated Client column) → Members (owner-only invite UI).
- **Client consent redesign** (Wave 40.3) — consent section collapsed by default (`<details>` accordion). Avatar consent toggle surfaced. `client.consent.update` audit event with `{from, to}` diff payload. Label: "Client consent" (was "Visibility").
- **Audit timestamps** render in browser-local timezone via `<ClientTime>` component.
- PayFast sandbox integration live; production merchant account pending.
- Never receives service role key — all writes via Supabase Edge Functions (`payfast-webhook`).
- Deployed to Vercel project `homefit-web-portal` under team `carlheinmosterts-projects`. DNS: `manage.homefit.studio` CNAME → `00596c638d4cefd8.vercel-dns-017.com.` at Hostinger. TLS via Vercel (auto-renew).
- Env vars set in Vercel (all envs): `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY` (publishable), `SUPABASE_SERVICE_ROLE_KEY` (secret), `APP_URL=https://manage.homefit.studio`, `PAYFAST_MERCHANT_ID=10000100`, `PAYFAST_MERCHANT_KEY=46f0cd694581a`, `PAYFAST_PASSPHRASE=`, `PAYFAST_SANDBOX=true`.
- Supabase auth: Site URL = `https://manage.homefit.studio`; redirect allowlist includes `https://manage.homefit.studio/**` + `http://localhost:3000/**` + `studio.homefit.app://login-callback` + `studio.homefit.app://**` (last two added 2026-05-10 — without them, the iOS app's magic-link `emailRedirectTo` silently fell back to the Site URL and emails opened Safari at manage.homefit.studio instead of deep-linking into the app). Without the apex/localhost entries, Google OAuth bounced login to `session.homefit.studio` (the old Site URL).

## Current Phase

**MVP shipped, active polish + analytics (2026-04-29).** Target hit well ahead of 2026-05-02. Both surfaces (mobile + portal) live, client-spine IA, offline-first on mobile, three-treatment playback, referral loop with 5% lifetime credit-rebate model, line-drawing aesthetic LOCKED at v6. **App Store readiness wave landed 2026-04-28** — bundle ID rebranded to `studio.homefit.app`, version `1.0.0+1`, privacy manifest + nutrition label declared, privacy/terms scaffolds live at `manage.homefit.studio/privacy|terms`, Reader-App compliance pattern in place (no in-app purchase paths), iOS app icon shipped. **Post-TestFlight-prep waves (2026-04-28/29):** camera UX overhaul (slide-to-lock, 0.5x ultrawide, visual feedback), portal chrome polish (stripped nav, right-cluster header, client avatars, full audit actor coverage 14/14), plan analytics (Wave 17 — 13 event types, consent banner, transparency page, per-exercise stats on mobile), swipe-to-duplicate, lazy video loading for large plans. Now blocked only on Carl-side items (Apple Developer activation, Hostinger redirects, lawyer red-pen).

**👉 For a fresh-session handoff:**
- **`docs/CHECKPOINT_2026-05-04.md` — READ FIRST.** Big polish + diagnostics day: 27 PRs (#196 → #223) including the hold-position 3-mode picker (Wave 43), inline-editable circuit names (Wave Circuit-Names), settings-sheet tabs (Now/Defaults/Plan), Hero-frame static thumbnails, filmstrip session-card backgrounds with floating count glyph + uniform 30% veil + white text. Two Supabase migrations applied. SQLite v33 → v37. Diagnostic tooling shipped: orphan-agent detection hooks (#201) + long-press conversion-error log reader (#213). v8 hand-pose disabled then re-enabled (RCA cleared). All 27 merged; Carl's iPhone is on PR #223.
- `docs/CHECKPOINT_2026-05-01.md` — Per-set PLAN post-merge QA: 8 stacked PRs (#149-#156) on top of `c6f5e6e`. (Note: those 8 PRs are now merged + obsolete vs. the 2026-05-04 polish wave on top.)
- `docs/TESTFLIGHT_PREP.md` — what's needed for the first upload + Carl's checklist
- `docs/CHECKPOINT_2026-04-26.md` — feature waves 27 → 32 (per-plan crossfade tuner, native dual-video retrofit, landscape support, 14-day structural-edit lock, publish-time consent gate, Home credits chip, body-focus blur, SessionCard consolidation; schema v25 → v31)
- Earlier checkpoints (`2026-04-24`, `2026-04-23`, `2026-04-22`, `2026-04-21`, `2026-04-20`, `2026-04-20-late`) remain authoritative for their era.

**Milestones complete:**
- **A** — Schema (practices, practice_members, credit_ledger, plan_issuances, plan.practice_id, plan.first_opened_at).
- **B** — Auth: email + optional password → magic-link fallback; practice bootstrap via `bootstrap_practice_for_user`; practice switcher on both surfaces. Google parked (nonce mismatch — see `docs/BACKLOG_GOOGLE_SIGNIN.md`). Apple scaffolded, waits on Developer Program.
- **C** — RLS lockdown scoped by practice membership. SECURITY DEFINER helpers `user_practice_ids()` / `user_is_practice_owner(pid)`. `credit_ledger` is RPC-write-only (milestone E).
- **D1** — Credit deduction at publish via `consume_credit` RPC. Refund ledger rows on failure.
- **D3** — Web portal deployed at `manage.homefit.studio`.
- **D4 sandbox** — PayFast checkout + ITN webhook, sandbox-optimistic return path routed through `record_purchase_with_rebates`.
- **Brand system v1.1** — `docs/design/project/tokens.json` + `components.md` + `voice.md`. Design Rules R-01..R-12 binding.
- **Studio v1.1** — Gutter Rail + Inline Action Tray + Thumbnail Peek + Circuit Control Sheet. Layout blow-out fixed (`CrossAxisAlignment.stretch` in Row with unbounded vertical was the root cause).
- **Progress-pill matrix** — empty pills, full-coral completed, sage rest, 3-number ETA, luxurious bottom row.
- **Three-treatment video** (Milestone G) — `clients` table, `video_consent` jsonb, private `raw-archive` bucket, pgjwt-based signed URLs, `get_plan_full` returns `line_drawing_url` / `grayscale_url` / `original_url` per exercise, consent-gated. Vault secret `supabase_jwt_secret` populated. Mobile + web player both have segmented control Line · B&W · Original.
- **Referral loop** (Milestone F, credit model updated in Milestone M) — 5% lifetime credit rebate with a 1-credit goodwill floor on the referrer's FIRST rebate from each referee. Single-tier only enforced at DB level, portal `/network` page, mobile Settings Network section, `/r/{code}` landing with OG image, POPIA consent checkbox at signup. Signup bonuses live at SIGNUP (not first purchase): +3 organic, +5 more on referral claim → 8 total for referral signups. See `supabase/schema_milestone_m_credit_model.sql`.
- **R-11 client-spine IA** (Milestone H/I/J) — portal `/clients` + `/clients/[id]` with inline editable names; mobile Home replaced with clients list; ClientSessionsScreen mirrors portal detail page. "Your clients" row removed from Settings (redundant).
- **R-12 dashboard hygiene** — portal dashboard is 5 stat tiles, every tile clickable, `/network` broke out referral UI to its own page, nav expanded to Clients · Credits · Network · Audit · Members · Account (Members owner-only).
- **Offline-first** (Milestone K) — `SyncService` + cache tables (`cached_clients`, `cached_practices`, `cached_credit_balance`, `pending_ops`) + `connectivity_plus` listener + `upsert_client_with_id` RPC for client-generated UUIDs. All reads from cache; all client writes queued. Publish stays online-only.
- **Line-drawing tuning LOCKED at v6** — `edgeThresholdLo=1, edgeThresholdHi=0.88, lineAlpha=0.96, backgroundDim=0.70`. See `VideoConverterChannel.swift` top-of-file comment; aesthetic signoff is load-bearing, don't tweak without explicit Carl sign-off.

**Shipped 2026-05-03/04 (Wave 43 + filmstrip polish wave — 27 PRs #196 → #223):**
- **Wave 43 hold-position 3-mode** (#216) — per-set `hold_position TEXT` ENUM `('per_rep', 'end_of_set', 'end_of_exercise')` defaulting to `end_of_set`. Math branches per mode in both surfaces (web player + Flutter). 3-pill segmented control under the Hold stepper in Plan tab. Migration backfills existing rows with `hold_seconds > 0` to `'per_rep'` so already-shipped plans keep their displayed durations. Wording: "Per rep / End of set / End". SQLite v36, Supabase migration `schema_wave43_hold_position.sql` applied.
- **Wave Circuit-Names** (#205) — practitioner-editable circuit labels via `plans.circuit_names jsonb` map. Studio header inline-edit. SQLite v37, Supabase migration `schema_wave_circuit_names.sql` applied.
- **Studio settings → tabs** (#217) — settings sheet split into Now / Defaults / Plan tabs to stop the sheet being scrolly. Detent stays 85%. Phase B placeholder treatment (#211) preserved per-tab.
- **Hero-frame static thumbnails** (#218) — Studio cards + editor sheet header thumbnails are static Hero frames, not playing video loops. Closes Carl's "show the Hero shot" feature ask.
- **Filmstrip session-card backgrounds** (#220) — up to 4 video heroes tiled horizontally as the card background, B&W via `ColorFilter.matrix`, 1px black hairlines between cells, card height +30%. Analytics row pulled INSIDE the card boundary (out of `client_sessions_screen.dart`'s parent column) so the filmstrip frames the whole row.
- **Card iteration sweep** (#221 + #222 + #223) — drop the leading icon block, replace with a floating count glyph (`_LeadingCountGlyph` — coral 42pt single-digit / 34pt multi-digit Inter with tabular figures + drop shadow); uniform 30% dark veil over the filmstrip (was L-to-R 0.92→0.55→0.30 gradient); body text swap `textSecondaryOnDark` → `textOnDark` so the muted grey reads white against the lighter veil.
- **Segmentation polish** (#219) — v8 hand-pose dilation re-enabled (was defensively off in #212 during stuck-conversion debugging; subsequent RCA cleared it). Asymmetric crop pad: 25% top, 10% other sides — Vision's mask gives faces/hair lower confidence than torso, so the bbox stops at the neck and 10% pad isn't enough to recover. Heads now stay in auto-picked Hero thumbnails.
- **Bug-fix wave** — soft-delete SnackBar root-messenger (#206), trim-handle selection leak across exercises (#206), index.html conflict-marker leak cleanup (#208), HeroStarBadge dedupe to shared widget (#209), Photos UX hardening cluster (#210 — Info.plist text reword + extension allowlist + first-denial chip + ToggleRow dedupe), conversion stuck-count UI fix (#212), rep-stack collapse rescue v1+v2 (#214/#215).
- **Diagnostic tooling** — orphan-agent detection hooks (#201 — PostToolUse + SessionStart hooks scan `.claude/worktrees/agent-*` for dead-parent worktrees, emit `<orphan-agents-detected>` system reminder on next session); long-press conversion-error log reader on the "N failed" pill (#213 — bottom sheet shows last 5 entries from `{Documents}/conversion_error.log` with copy-all + delete-log).
- **Memory entries added** — `gotcha_test_scripts_index_cascade.md` (multi-region conflict cascade in `docs/test-scripts/index.html`); `gotcha_corrupted_raw_video.md` (AVFoundation Code=-11829 = unrecoverable damaged mp4 + diagnostic path).

**Shipped 2026-04-28/29 (Waves 39.4, 40.x, 17):**
- **Wave 39.4** — sticky defaults extended to `videoRepsPerLoop` + `interSetRestSeconds`. Photo last-exercise refresh fix (AutomaticKeepAliveClientMixin on Studio). Reachability drop-pill latch persists until manual untoggle. Dart wire timestamps forced to UTC at all Postgres-bound `upload_service.dart` sites. Portal audit timestamps render in browser-local TZ via `<ClientTime>` component.
- **Wave 40 (M1-M6 + P1-P8)** — camera icon replaces Library on Studio toolbar; library moved to viewfinder bottom-left. Permanent shutter hint (3 states). Slide-up-to-lock recording gesture with coral border glow. 0.5x ultrawide via CameraDescription swap. Right-edge vertical lens pills. Toolbar icons white-default (coral reserved for state cues), size bump 44→48/24→28. Portal: top-bar nav stripped, right-cluster practice switcher + email chip, dashboard audit card with real data, audit kind chips wrap inline, client avatar images via signed URLs, `/clients` drill-in routing fix, session-icon parity.
- **Wave 40.1** — audit actor never NULL for `plan.opened` (derives via `plan_issuances.trainer_id`). Dedicated Client column on audit table.
- **Wave 40.3** — client consent section collapsed by default on portal + mobile. Avatar consent toggle surfaced. `client.consent.update` audit event with `{from, to}` diff payload. Label renamed "Visibility" → "Client consent".
- **Wave 40.4** — portal client avatar image rendering (signed URLs via `list_practice_clients` + `get_client_by_id` returning `avatar_url`).
- **Wave 40.5** — full actor coverage on audit feed: 14/14 kinds (was 5/14). Schema: `credit_ledger.trainer_id`, `clients.created_by_user_id`, `clients.deleted_by_user_id`. 9 RPCs updated. Native haptic platform channel (`HomefitHapticsChannel.swift`).
- **Wave 40.6** — photo last-exercise refresh FINAL fix (AutomaticKeepAliveClientMixin). Treatment-aware video thumbnails (3 variants per video). Visual lock-engage feedback (coral border glow replaces haptics during mic use). Haptic channel simplified to `UIImpactFeedbackGenerator`.
- **Wave 17 — Analytics** — schema: `client_sessions`, `plan_analytics_events`, `plan_analytics_daily_aggregate`, `plan_analytics_opt_outs` + 7 RPCs + RLS. Web player: consent banner, 12+1 event emitters, completion CTA, `/what-we-share` transparency page with stop-sharing button. Mobile: analytics consent toggle, plan stats under session cards, per-exercise stats bar. Retention cron documented (not deployed).
- **Swipe-to-duplicate** — right-swipe on Studio exercise card deep-copies exercise (new UUID, files copied, inserted below). Undo via SnackBar.
- **Studio toolbar layout** — workflow pill (Camera → Preview → Publish → Share with raised background) + right-aligned Download utility. Download saves all session exercises to camera roll with progress toast. Publish checkmark retired → dismissible "Published ✓" toast.
- **Duration-based credit pricing** — 1 credit for plans ≤ 75min estimated duration, 2 credits for > 75min. Replaces the old exercise-count formula (ceil(n/8) clamped [1,3]).
- **Web player hardening (v79-v80):**
  - Lazy video loading — `data-src` + `preload="none"`, loaded on demand (current ± 2 slides). Prevents Safari crash on large plans. Network-first media in service worker. CSP fix (inline scripts → external files).
  - Signed URL expiry recovery — video `error` listener auto-refreshes URLs from `get_plan_full` on 403.
  - Timer drift fix — `visibilitychange` listener fast-forwards `remainingSeconds` by wall-clock delta on tab resume / screen unlock.
  - Autoplay fix — all videos start `muted`; unmute after "Start Workout" (user gesture). Mute toggle always visible (client can override `include_audio` default).
  - Treatment switching — CSS-only for B&W ↔ Original (same file, different filter). Src swap only for line ↔ anything. Path comparison strips signed URL tokens.
  - Video loading gate — coral spinner overlay defers timer until `canplay`. Prep-phase dedup via `fireOnce()` guard prevents canplay + timeout race.
  - Network retry — "No connection" screen with Retry button (distinct from "Plan not found").
  - Consent banner auto-dismisses on "Start Workout" tap.
  - `<noscript>` fallback for JS-disabled browsers.
  - `prefers-reduced-motion` media query disables animations.

**Shipped 2026-04-28 (TestFlight prep wave):**
- **Bundle ID rebrand** (PR #125) — `com.raidme.raidme` → `studio.homefit.app` across pbxproj × 6 configs, Info.plist URL scheme, `AppConfig.oauthRedirectUrl`, install scripts, os_log subsystems. Version bumped `0.1.0+1` → `1.0.0+1`. Android `applicationId`, macOS, Dart `name: raidme` package, MethodChannel names, and `raidme.db` SQLite filename deliberately untouched (separate refactors, not blocking TestFlight). When SIWA / Google re-enabled later, the Supabase allowlist already covers `studio.homefit.app://` (added 2026-05-10 for magic-link deep-linking); only the Google/Apple OAuth client config still needs the bundle ID.
- **Privacy manifest + App Store Connect nutrition label** (PR #122) — `app/ios/Runner/PrivacyInfo.xcprivacy` populated with 8 `NSPrivacyCollectedDataTypes` entries (email, name, photos-or-videos, audio, other-user-content, user-id, purchase-history, product-interaction — all linked, none tracking). `NSPrivacyTracking=false`. `docs/app-store-connect-privacy.md` is Carl's click-through guide for the manual ASC privacy form — must mirror the manifest.
- **Privacy + Terms scaffold** (PR #123) — `web-portal/src/app/privacy/page.tsx` (21 sections, POPIA-aligned, sub-processors table, retention windows, bracketed placeholders for legal-pending wording) + `web-portal/src/app/terms/page.tsx` (15 sections, lighter scaffold). Settings → Legal section (Privacy + Terms) opens both URLs in `LaunchMode.inAppBrowserView` (Safari View Controller). `docs/PRIVACY_DEPLOYMENT.md` is the Hostinger 301-redirect runbook (`homefit.studio/privacy|terms` → `manage.homefit.studio/...`).
- **Reader-App compliance** (PR #124) — stripped every in-app credit-purchase path. Removed Settings "Top up credits" `_ActionRow` + `_openCreditsTopUp` method, de-tappified the home credits chip (was `InkWell` opening manage.homefit.studio), trimmed "Buy more via manage.homefit.studio" copy from snackbars + `PublishResult.toErrorString`. Zero-balance state shows plain text "You're out of credits. Top up at manage.homefit.studio." — non-tappable. Network section's `/dashboard` link kept (referral, not commerce). Locked in `feedback_ios_reader_app.md` memory entry.
- **App icon redesign** (PR #127 → #131, eight iterations) — replaced Flutter blue-F placeholder with a 3×3 grid of **square** (5×5, deliberately divergent from canonical 5:3) coral pills with sage centre on dark `#0F1117`, scaled to 65% canvas width for iOS icon-grid breathing room. Geometry in `tools/icon-render/render_app_icon.py`. Icon-only divergence — matrix logo on web/mobile keeps canonical 5:3. Locked in `feedback_app_icon_divergence.md` memory entry.
- **App Store metadata draft** — `docs/app-store-metadata.md`: subtitle locked at `Visual plans clients follow.` (28 chars), support URL `mailto:support@homefit.studio`, primary category Health & Fitness (secondary Productivity), description ~2,400 chars within budget, age-rating questionnaire mapping (4+ result; flag UGC + medical/treatment as Mild). `support@homefit.studio` mailbox setup pending Carl.

**Shipped 2026-04-24:**
- **Wave 22 — Photos three-treatment parity** — photos finally match videos. Mobile uploads raw color JPG to `raw-archive` (consent-gated) alongside the line-drawing JPG to `media`. `get_plan_full` returns 3 URLs per photo. Web player applies CSS `filter: grayscale(1) contrast(1.05)` on `<img class="is-grayscale">` for B&W (single source). `schema_wave22_photos_three_treatment.sql`.
- **Wave 24 — Video reps per loop + retire DURATION PER REP UI** — practitioner records videos with N reps (default 3, was implicitly 1). Per-rep time always derives from `video_duration ÷ video_reps_per_loop`. Legacy `custom_duration_seconds` UI removed; column kept for legacy reads. New PACING field "REPS IN VIDEO" at top. Capture screen has "Aim for ~3 reps per video" hint. `schema_wave24_video_reps_per_loop.sql`. SQLite v25 → v26.
- **Wave 25 — Mobile Enhanced Background "Body focus" toggle** — `_MediaViewer` finally plays the segmented body-pop variant for B&W + Original (was always playing raw, diverging from the web player). Horizontal pill at bottom-left above mute pill ("Body focus" with blur icon). Persists per-device via SharedPreferences. Web gear popover heading also renamed "Enhanced background" → "Body focus" for parity.
- **Vertical rep-block stack** — replaces the horizontal segmented progress bar. Bottom-up "stacking your reps" metaphor. 1:1 micro-blocks per rep + uniform-sized rest blocks. Section labels (S1, R, S2, …) in left gutter with thin connector brackets. Active block doubles as per-rep progress bar (linear fill flows over rep window). Trailing rest after EVERY set (incl. last). Top-down wave drain animation on slide change (~600ms). Tap any block to jump the workout timer. Circuit slides honoured as 1 set per slide. **Duration is the source of truth** — rep counter derives from elapsed time, NOT video loop count (commits `cedfe07`, `6ffc7af`, `5e1b3bc`).
- **Soft-trim editor (Wave 20)** — practitioner-controlled in/out window per exercise. `_MediaViewer` bottom panel with two coral drag-handles. Trim handles pause video on drag-down, scrub video to dragged frame in real time, resume on release. `start_offset_ms` + `end_offset_ms` columns; web + mobile playback both clamp to window. `schema_milestone_x_soft_trim.sql`.
- **"Show me" client treatment override** — per-plan localStorage. Practitioner's choice (default) honours per-exercise `preferred_treatment`; client can override globally to Drawn / B&W / Colour. Unconsented options locked. Body focus switch disables when treatment = Drawn.
- **Player chrome polish** — vertical chrome stack on right edge (mute beside fullscreen, settings stacked under). No ambient dim. Discreet build-version marker in footer (mirrors mobile build-SHA pattern). Dual-video crossfade hides the loop seam (no iOS Safari stutter). Breather sage countdown chip clears cleanly at slide change. Prev chevron shifts past rep stack via JS-toggled `has-rep-stack` class on `.card-viewport`.
- **`replace_plan_exercises` RPC patches** — discovered the RPC was silently dropping `inter_set_rest_seconds` since Milestone Q (Wave 20 fix) and `video_reps_per_loop` for Wave 24 (added). Each new column on `exercises` needs explicit add to that RPC's INSERT column list. Worth a future audit.

**Shipped 2026-04-20:**
- **Credit model overhaul (Milestone M)** — signup bonuses move to bootstrap/claim: +3 organic, +8 referred. Referrer 5% lifetime rebate with a 1-credit goodwill floor on first payout. One-time +10 bonuses removed. `schema_milestone_m_credit_model.sql`.
- **Delete client (Milestone L)** — `delete_client` / `restore_client` RPCs with cascade to plans via matched `deleted_at` timestamps. Portal + mobile twins, UndoSnackBar on both. Hotfix PR #37 qualified `clients.id` to dodge PL/pgSQL `42702` SETOF OUT-col shadowing.
- **Portal practice rename + popover switcher (Milestone N)** — retired the dropdown. Inline editable "In practice: {Name}  ⇄ Switch" with custom popover; Account Settings has a Practice-name card; owner-only via `rename_practice` RPC. Mobile R-11 twin is a backlog follow-up.
- **Per-exercise treatment preference (Milestone O)** — swipe-to-set persists via `preferred_treatment` column (SQLite v18 + Supabase). Studio card has a 3-tile row below the exercise name. Vertical pill in `_MediaViewer` uses rotated book-spine text.
- **B&W thumbnails on practitioner-facing surfaces** — Studio/Home/ClientSessions/Camera peek all render a B&W frame from the raw capture with motion-peak + person-crop. Line-drawing stays on the client web player.
- **Logo v2 canonical** — retired heartbeat/roof. New matrix: 3 ghost greys per side (`#4B5563` / `#6B7280` / `#9CA3AF`), 2×2 circuit in coral tint band, sage rest. Matrix `viewBox="0 0 48 9.5"` + lockup `viewBox="0 -2 48 16"`. Three impls kept in sync: `HomefitLogo.tsx`, `homefit_logo.dart`, `buildHomefitLogoSvg()`.
- **Audio on Line treatment** — converter captures + muxes audio always; `includeAudio` flag is now a playback-mute preference. Concurrent drain via `requestMediaDataWhenReady` on separate dispatch queues with `DispatchGroup` gating `finishWriting`. PR #41 is the load-bearing fix.
- **Test-script infrastructure** — `docs/test-scripts/_server.py` (port 3457) serves static docs + accepts POST to `/api/test-results/{slug}.json`. Test scripts are HTML with numbered pass/fail buttons + notes on both states. Wave 1 + Wave 2 complete; Wave 3 backlog created.
- **Business case 5-year model** (PR #35, still open) — `docs/business-case/homefit-studio-business-case-v1.xlsx` + `executive-summary.html` with Chart.js + live sliders.

**Backlog (not urgent — nothing currently broken):**
- **D2** publish-screen practice picker polish.
- Three-treatment end-to-end validation on device (vault secret is set; needs capture → publish → switch to B&W with consent granted round-trip).
- Referral loop end-to-end validation (create via /r/{code}, sandbox purchase, verify ledger rows).
- POPIA privacy page + terms of service — scaffolds shipped 2026-04-28 (PR #123) at `manage.homefit.studio/privacy|terms`. ZA lawyer red-pen pending; bracketed placeholders flag the spots needing wording.
- Hostinger 301 redirects: `homefit.studio/privacy|terms` → `manage.homefit.studio/...`. Runbook at `docs/PRIVACY_DEPLOYMENT.md`. One-line rules in hPanel; not done yet (currently the apex serves the parked-domain placeholder which Apple Review will reject).
- `support@homefit.studio` mailbox — referenced as the App Store support URL; Carl to set up at Hostinger alongside `privacy@`.
- PayFast production cutover (blocked on Carl's merchant account).
- Dead-code sweep (PR #10 flagged `_PrepFlashWrapper`, `_TimerRingPainter`, `_PulseMarkPainter` etc.).
- `supabase/schema.sql` refresh via `supabase db dump`.
- Test plan Phase 1 — no tests exist for business-logic RPCs yet.
- **When SIWA / Google re-enabled** (post-MVP): the Supabase auth redirect allowlist already includes `studio.homefit.app://login-callback` + `studio.homefit.app://**` (added 2026-05-10 alongside Resend SMTP wire-up so magic-link deep-linking would work for TestFlight users); only the Apple/Google OAuth client config still needs the bundle ID. See also `docs/BACKLOG_GOOGLE_SIGNIN.md`.

**Blocked on Carl:**
- PayFast production merchant account signup.
- Apple Developer Program activation (Individual enrollment per 2026-04-28; flip `_appleEnabled = true` + restore Apple button when ready). First TestFlight upload then targets bundle ID `studio.homefit.app`.
- Legal review of privacy + TOS copy.

**Deferred past MVP:**
- Android app — iOS only for MVP.
- AI style transfer (Stability AI, Kling O1, SayMotion) — premium-tier, parked.
- Ongoing referral commission (rev-share per purchase).

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
- **iOS haptic suppression during mic use (2026-04-28):** iOS suppresses ALL vibration hardware while an `AVCaptureSession` with audio input is active. No API bypass exists (`UIImpactFeedbackGenerator`, `CHHapticEngine`, `AudioServicesPlaySystemSound` all fail silently). Use visual feedback (coral border glow, pulsing indicators) for camera/recording UX. See `gotcha_ios_haptic_mic_suppression.md`.
- **PageView disposes offscreen pages (2026-04-28):** Without `AutomaticKeepAliveClientMixin`, swiping away from a PageView child disposes it — killing stream subscriptions and state. Root cause of the photo-spinner bug that survived 7 fix attempts. Any `StatefulWidget` in a PageView that subscribes to streams MUST use `AutomaticKeepAliveClientMixin`. See `gotcha_pageview_keepalive.md`.
- **Schema migration column preservation (2026-04-28):** When re-creating an RPC via `CREATE OR REPLACE FUNCTION`, carry forward EVERY column from the existing `RETURNS TABLE`. Wave 40.5 dropped `client_exercise_defaults` and `avatar_url` from `list_practice_clients`, silently wiping sticky defaults on every sync. Always read the existing function signature first (`\df+ public.<fn_name>`) before writing a migration. See `feedback_schema_migration_column_preservation.md`.
- **Safari CSP blocks inline `<script>` (2026-04-28):** CSP `script-src 'self'` blocks inline script tags. Move all scripts to external `.js` files. Caught on the `/what-we-share` page.
- **Safari service worker caching is aggressive:** needs cache name bumps + explicit `unregister()` for testing. Network-first strategy for media prevents stale/partial video caching.
- **Offline-first guarantee (2026-04-19):** Home / ClientSessions / PracticeChip / Settings credit-balance all read from SQLite cache first (`cached_clients`, `cached_practices`, `cached_credit_balance`). Client create / rename / consent operations queue into `pending_ops` and flush the moment connectivity returns. Publish stays online-only by design — credit consumption is load-bearing. See `app/lib/services/sync_service.dart` for the orchestrator.

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

**Prepaid credits.** The billing unit is the plan URL — one credit consumed per unique plan, scaled by estimated duration (≤ 75 min = 1 credit, > 75 min = 2 credits). The 75-minute threshold is purely anti-abuse; the vast majority of real-world plans cost 1 credit. Practice managers buy credit bundles on the web portal via PayFast. Any practitioner in a practice can consume credits to publish.

**Version-bump policy (Wave 32 revision):** the first publish of a plan URL consumes a credit. Non-structural edits (reps, sets, hold, notes, filter params) are free forever. Structural edits (add/delete/reorder) are free indefinitely while the client has not opened the link. Once the client opens the link, the practitioner has 14 days (2 weeks) of free structural editing; past that window, the plan locks. The 14-day grace matches typical practitioner / client follow-up cadence — clients return 1-2 weeks later for a follow-up session and the practitioner needs the freedom to refine the plan based on what they observe. The Studio AppBar surfaces a padlock chip → bottom sheet → 1-credit unlock pre-pays the next republish (server stamps `plans.unlock_credit_prepaid_at`; `consume_credit` reads + clears it on the next publish so there's no double charge). Enforcement lives in the Flutter Studio UI (`_isPlanLocked` against `firstOpenedAt + 14 days`) plus the atomic `unlock_plan_for_edit` RPC.

**JIT (just-in-time client-pay) mode was considered and rejected** — adherence-damaging, undermines the platform's core value prop.

**Credit bundle prices (provisional):** 10/R250, 50/R1125, 200/R4000. Revisit once there's real usage data.

## Compliance

POPIA (South Africa) at minimum. Line drawings naturally de-identify clients — major privacy advantage built into the visual pipeline.

## Versioning

Each surface uses the version concept that fits its deploy cadence — they're intentionally separate, not synchronised.

- **Web (player + portal):** the git SHA *is* the version. Vercel deploys every push, the build-marker footer renders the short SHA, and `release-tag.yml` auto-tags every merge to `main` as `v{YYYY-MM-DD}.{N}` (N = nth release on that UTC date — e.g. `v2026-05-11.3` for the third release-train PR landing today). Direct pushes to `main` (docs-only) deliberately don't tag, so the date-tag stream is a clean prod-state bookmark.
- **Mobile:** `app/pubspec.yaml` carries the marketing-version + build-number (`X.Y.Z+N`). `bump-version.sh` is the only entry point that increments it; by default it now also commits the bump and creates an annotated `mobile-v{version}+{build}` tag (e.g. `mobile-v1.0.0+4`) pushed to origin. Every TestFlight upload has a discoverable git anchor. Pass `--no-tag` to skip the commit/tag step for legacy bundling.
- **DB:** the migration filename is the version. `supabase/migrations/YYYYMMDDHHMMSS_<name>.sql` is the timestamp-ordered chain Supabase Branching applies on every per-PR DB. No separate version number; the latest applied filename answers "what schema is live".

The three cadences live in the same repo on purpose. A web tweak doesn't need a TestFlight upload; a schema migration doesn't need a web rebuild; a TestFlight upload doesn't need a schema change. Each tag scheme exists so we can answer "which commit shipped that?" without consulting the others.

## Key Documents

- `CLAUDE.md` — this file
- **`docs/TESTFLIGHT_PREP.md` — READ FIRST for upload readiness.** Bundle ID rebrand summary, what's needed for App Store Connect record creation, Carl's pre-upload checklist. Updated 2026-04-28.
- **`docs/CHECKPOINT_2026-05-04.md`** — most recent checkpoint (27 PRs #196 → #223 — Wave 43 hold-position, Wave Circuit-Names, settings tabs, Hero-frame thumbnails, filmstrip session cards, count glyph, uniform veil, white text). SQLite v37. Supabase: two migrations applied. Diagnostic tooling: orphan hooks + long-press conversion-error log reader.
- `docs/CHECKPOINT_2026-05-01.md` — Per-set PLAN post-merge QA wave (8 stacked PRs #149-#156, all merged + obsoleted by the 2026-05-04 wave on top).
- `docs/CHECKPOINT_2026-04-26.md` — feature waves 27 → 32 (Waves 27 → 32, schema v25 → v31). Earlier checkpoints (`2026-04-24`, `2026-04-22`, `2026-04-21`, `2026-04-20`, `2026-04-20-late`) remain for historical reference.
- `docs/app-store-metadata.md` — App Store listing copy: name, subtitle, description, keywords, support/marketing URLs, age-rating answers, App Review notes template. Subtitle + support URL locked.
- `docs/app-store-connect-privacy.md` — click-through checklist for the manual ASC App Privacy form. Mirrors `PrivacyInfo.xcprivacy`.
- `docs/PRIVACY_DEPLOYMENT.md` — Hostinger 301-redirect runbook for `homefit.studio/privacy|terms` → `manage.homefit.studio/...`.
- `docs/RESEND_SETUP.md` — Resend SMTP setup runbook for Supabase auth emails (DNS records at Hostinger, API key, Supabase SMTP form). Wired 2026-05-10.
- `supabase/email-templates/` — Branded HTML for all 6 Supabase auth emails (dark + coral, system-font stack, table-based for Outlook). Apply manually via dashboard; see folder README for the click-through.
- `docs/POV_BRIEF.md` — Proof-of-value brief with vision and build plan (historic; POV passed)
- `docs/MVP_PLAN.md` — Active 14-day plan to 2026-05-02 (Melissa onboarding + referral loop + PayFast prod + polish)
- `docs/MARKET_RESEARCH.md` — Competitive landscape + business case validation
- `docs/ANIMATION_PIPELINE.md` — AI pipeline (parked) technical spec
- `docs/BACKLOG.md` — Deferred work with rationale
- `docs/BACKLOG_GOOGLE_SIGNIN.md` — Google Sign-In nonce-mismatch post-mortem + re-enablement paths
- `docs/DATA_ACCESS_LAYER.md` — The binding rule on how each surface talks to Supabase (one file per surface, typed contracts, how to add a new RPC)
- **`docs/CI.md`** — CI/CD release pipeline: three-tier model (feature branches → staging → prod), branch naming, per-branch testing on web + phone, Supabase Branching cutover plan, automation. Authored 2026-05-11.
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
- `supabase/schema_milestone_g_three_treatment.sql` — clients table + video_consent + raw-archive bucket + sign_storage_url helper + extended get_plan_full
- `supabase/schema_milestone_m_credit_model.sql` — 3/8 free signup credits + 5% lifetime rebate with 1-credit goodwill floor; replaces Milestone F's +10/+10 first-purchase bonuses
- `app/lib/theme.dart` — Brand theme tokens
- `app/lib/widgets/homefit_logo.dart` — Canonical v2 logo widget (matrix-only `HomefitLogo` + `HomefitLogoLockup`)
- `app/lib/widgets/powered_by_footer.dart` — Shared "powered by" footer (+ build-SHA marker)
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
- `tools/icon-render/render_app_icon.py` — Python/Pillow renderer for the iOS app icon set. Pill geometry deliberately diverges from the canonical matrix logo (5×5 squares vs 5:3 rest-bars) — see `feedback_app_icon_divergence.md` memory.
- `app/ios/Runner/PrivacyInfo.xcprivacy` — Apple privacy manifest. 8 collected-data-type declarations; must mirror `docs/app-store-connect-privacy.md` and the App Store Connect form Carl fills in.
- `web-portal/src/app/privacy/page.tsx` + `web-portal/src/app/terms/page.tsx` — POPIA-aligned scaffolds with bracketed placeholders for legal-pending wording.

## Development Guidelines

- Favour speed and validation over perfection — MVP ship window is 2 weeks
- Use sub-agents in background for heavy implementation work; stay available for conversation
- **Sub-agent isolation + relative paths.** When spawning an agent with `isolation: "worktree"`, brief it with REPO-RELATIVE paths (`app/lib/foo.dart`, `docs/CHECKPOINT_2026-04-20.md`), not absolute `/Users/chm/dev/TrainMe/...` paths. Absolute paths seduce agents into writing to the main repo's working tree instead of their isolated worktree — that caused 4 parallel agents to leak stale state into main in a single session. A `PreToolUse` hook at `.claude/hooks/rewrite-agent-prompts.py` (wired in `.claude/settings.json`) strips the prefix + prepends a worktree-isolation banner as a backstop, but briefs should still be clean at authorship time.
- Never use `flutter run` (R-08) — use build + `simctl install` instead
- Simulator: `./install-sim.sh` (builds with SHA marker, uninstalls for a fresh Sign-In screen, relaunches on iPhone 16e)
- Physical device: `./install-device.sh` (pulls main, release build, installs to iPhone CHM; runs with VPN on)
- Manual build: `cd app && flutter build ios --debug --simulator --dart-define=GIT_SHA=$(git -C /Users/chm/dev/TrainMe rev-parse --short HEAD)`
- Install with: `xcrun simctl install <device-id> <runner.app>`
- Launch with: `xcrun simctl launch <device-id> studio.homefit.app`
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
