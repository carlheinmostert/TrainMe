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
  - **Clients:** `clients` table (practice-scoped; unique on `(practice_id, name)`) carries the per-client `video_consent` jsonb `{line_drawing, grayscale, original}`. `line_drawing` is always true (de-identified by pipeline; consent can't be withdrawn). `plans.client_id` FK → `clients.id` (nullable on legacy rows; populated by `upsert_client` on new publishes). Client-management RPCs: `upsert_client`, `set_client_video_consent`, `get_client_by_id`, `list_practice_clients` (all SECURITY DEFINER + practice-membership checks).
  - **Plan data:** `plans`, `exercises` with full data model (circuits, rest periods, audio, custom durations, versions, thumbnails). `plans.practice_id` + `plans.first_opened_at` + `plans.client_id`.
  - **Billing:** `credit_ledger` (append-only, consumption/purchase/refund/adjustment) + `plan_issuances` (append-only audit of every publish) + `pending_payments` (PayFast intent). Credit cost: `ceil(non_rest_count / 8)` clamped to `[1, 3]`. Treatment switching on the player (line-drawing / B&W / original) is free — both files are stored once, consent gates playback.
  - **Atomic credit consumption:** `consume_credit(p_practice_id, p_plan_id, p_credits)` SECURITY DEFINER fn with FOR UPDATE locking. Called from publish flow. Accompanying `practice_credit_balance`, `practice_has_credits`.
  - **`credit_ledger` is RPC-write-only** — clients cannot INSERT/UPDATE/DELETE; only `consume_credit` / `refund_credit` (SECURITY DEFINER, owner `postgres`) may write. `authenticated` keeps SELECT (scoped by `credit_ledger_select_own` RLS policy); `anon` has no access at all. Purchases land via the PayFast webhook + sandbox bounce-back using the service-role key. See `supabase/schema_milestone_e_revoke_credit_ledger_writes.sql`.
  - **Anonymous plan read:** `get_plan_full(p_plan_id)` SECURITY DEFINER RPC. Web player calls this; no direct SELECT on plans/exercises for anon. Returns per-exercise `line_drawing_url` (always) + `grayscale_url` / `original_url` (consent-gated; NULL if the client hasn't granted that treatment). Signed URLs are generated inline via `public.sign_storage_url(bucket, path, expires_in)` — a pgjwt-backed helper that pulls the JWT secret + base URL from `vault.secrets` (`supabase_jwt_secret`, `supabase_url`). If either vault secret is missing, the helper returns NULL and clients gracefully fall back to line-drawing only.
  - **RLS:** scoped-by-practice via the helper fns `user_practice_ids()` and `user_is_practice_owner(pid)`. Avoids the self-referential recursion trap that direct subqueries on `practice_members` would cause. The helper fns are SECURITY DEFINER and bypass RLS.
  - **Storage buckets:**
    - `media` (public read for sharing plan URLs; INSERT/UPDATE/DELETE scoped by path-prefix→plan→practice membership). Stores the line-drawing treatment.
    - `raw-archive` (PRIVATE; SELECT blocked for anon+authenticated, service-role reads + signed URLs only). Stores the grayscale + original treatments (same file, treatment chosen client-side). Path shape: `{practice_id}/{plan_id}/{exercise_id}.mp4`. INSERT/UPDATE/DELETE gated by `can_write_to_raw_archive(path)` helper which parses the first path segment as practice_id and checks membership.
  - **Referral loop (Milestone F + Milestone M):** `referral_codes` (one opaque 7-char slug per practice, unambiguous alphabet) + `practice_referrals` (referee PK → exactly one referrer per referee; `goodwill_floor_applied` tracks first-rebate clamp) + `referral_rebate_ledger` (append-only, `numeric(10,4)` credits). Model (current, per Milestone M): signup bonuses live at signup time — `credit_ledger` kind `signup_bonus` (+3 organic) + kind `referral_signup_bonus` (+5 on claim) → 8 total for referees. Every referee PayFast purchase pays the referrer a 5% lifetime credit rebate; on the referrer's FIRST rebate from each referee, if raw 5% rounds to < 1 credit it's clamped UP to 1 (goodwill floor). Subsequent rebates are raw fractional 5%. **Single-tier only** — a `BEFORE INSERT` trigger rejects any row whose proposed referrer is already a referee (or vice versa), so A→B→C pays A nothing from C. POPIA-respecting: referee names default to anonymised "Practice N" labels; referees opt in via `referee_named_consent`. Webhook path: `record_purchase_with_rebates(...)` SECURITY DEFINER RPC wraps the purchase ledger insert + rebate rows in ONE transaction. Same lockdown pattern as `credit_ledger` (PR #3) — client INSERT/UPDATE/DELETE revoked on all three tables; SELECT scoped via `user_practice_ids()`, with the rebate ledger visible only to the referrer's practice.
- **Web player:** Static HTML/CSS/JS on Vercel, auto-deploys from GitHub (`web-player/` directory)
- **Domain:** Hostinger DNS, CNAME `session` → `cname.vercel-dns.com` (updated to `00596c638d4cefd8.vercel-dns-017.com.` per Vercel's new IP range)
- **OG meta tags:** Vercel Edge Middleware (`web-player/middleware.js`) serves bot-friendly HTML for WhatsApp link previews
- **Service worker:** `web-player/sw.js` caches app shell for offline. Current cache name `homefit-player-v16-three-treatment` — bump on major changes.

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
- **IA**: **Clients-as-Home spine** (R-11 twin of portal `/clients` + `/clients/[id]`). Home is the clients list with a `New Client` FAB; tap a client → `ClientSessionsScreen` with its editable name (dashed underline) + consent chip + per-client session list + `New Session` FAB. No quick-capture escape hatch — capture is always client-first.
- **Session shell** — horizontal PageView with Studio (edit) and Camera (capture) modes. Session creation carries the parent `client_id`. Session title format: `{DD Mon YYYY HH:MM}` (client prefix retired — client context is implicit in the nav).
- **Camera mode** — full-screen shutter, short-press = photo, long-press = video. Per-second haptic ticks + pulsing red dot during recording. 30s auto-stop with double-tap haptic. Pinch-to-zoom + 0.5x/1x/2x/3x lens pills. Peek box at left edge shows last thumbnail + count.
- **Studio mode** — bottom-anchored list (one-handed reach). Gutter Rail + Inline Action Tray + Thumbnail Peek + Circuit Control Sheet per `docs/design/project/components.md`. Studio header inline-edit writes `session.title` (not `clientName` — that's now a legacy mirror of `client.name`). Layout blow-out bug fixed: `CrossAxisAlignment.stretch` in Row with unbounded vertical was the root cause.
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
- **Publish** — pre-flight file check → `consume_credit` RPC → plan version bump → media upload → exercises upsert → orphan cleanup → raw-archive best-effort upload → `plan_issuances` audit. Compensating refund ledger row on any post-consume failure.

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
- Service worker caches app shell + video media (with content-type validation). Cache name bumped on major changes; current: `homefit-player-v16-three-treatment`.
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

**MVP is in active QA.** Target shipped well ahead of 2026-05-02. Both surfaces (mobile + portal) are live, converged on a client-spine IA, offline-first on mobile, three-treatment playback wired, referral loop shipped with 5% lifetime credit-rebate model, line-drawing aesthetic LOCKED at v6. Carl has been running device QA; no open bugs on the live stack.

**👉 For a fresh-session handoff, read `docs/CHECKPOINT_2026-04-22.md` first.** It captures the Wave 18 Studio-UI polish chain (18 → 18.8), two Supabase migrations (`schema_fix_milestone_r_srf.sql`, `schema_fix_publish_replace_exercises.sql`), the paused web-player wireframe workshop at `docs/design/mockups/web-player-wireframe.html`, and a "how to resume" section. Earlier checkpoints (`2026-04-21`, `2026-04-20`, `2026-04-20-late`) remain authoritative for their era.

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
- POPIA privacy page + terms of service (legal review pending).
- PayFast production cutover (blocked on Carl's merchant account).
- Dead-code sweep (PR #10 flagged `_PrepFlashWrapper`, `_TimerRingPainter`, `_PulseMarkPainter` etc.).
- `supabase/schema.sql` refresh via `supabase db dump`.
- Test plan Phase 1 — no tests exist for business-logic RPCs yet.

**Blocked on Carl:**
- PayFast production merchant account signup.
- Apple Developer Program activation (flip `_appleEnabled = true` + restore Apple button when ready).
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

**Prepaid credits.** The billing unit is the plan URL — one credit consumed per unique plan, scaled by exercise count (1-8 = 1 credit, 9-15 = 2, 16+ = 3). Practice managers buy credit bundles on the web portal via PayFast. Any practitioner in a practice can consume credits to publish.

**Version-bump policy (decided, not yet enforced):** the first publish of a plan URL consumes a credit. Non-structural edits (reps, sets, hold, notes, filter params) are free forever. Structural edits (add/delete/reorder) are free for the first 24h after publish OR until the client first opens the link, whichever comes first. Past that window, structural changes require a new credit. Enforcement lives in the Flutter Studio UI (disabled add/reorder affordances post-lock).

**JIT (just-in-time client-pay) mode was considered and rejected** — adherence-damaging, undermines the platform's core value prop.

**Credit bundle prices (provisional):** 10/R250, 50/R1125, 200/R4000. Revisit once there's real usage data.

## Compliance

POPIA (South Africa) at minimum. Line drawings naturally de-identify clients — major privacy advantage built into the visual pipeline.

## Key Documents

- `CLAUDE.md` — this file
- **`docs/CHECKPOINT_2026-04-22.md` — READ FIRST on fresh session.** Studio-UI polish marathon (Wave 18 chain through 18.8), two Supabase migrations, paused web-player wireframe workshop, how-to-resume. Earlier checkpoints (`2026-04-21.md`, `2026-04-20.md`, `2026-04-20-late.md`) remain for historical reference.
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

## Development Guidelines

- Favour speed and validation over perfection — MVP ship window is 2 weeks
- Use sub-agents in background for heavy implementation work; stay available for conversation
- **Sub-agent isolation + relative paths.** When spawning an agent with `isolation: "worktree"`, brief it with REPO-RELATIVE paths (`app/lib/foo.dart`, `docs/CHECKPOINT_2026-04-20.md`), not absolute `/Users/chm/dev/TrainMe/...` paths. Absolute paths seduce agents into writing to the main repo's working tree instead of their isolated worktree — that caused 4 parallel agents to leak stale state into main in a single session. A `PreToolUse` hook at `.claude/hooks/rewrite-agent-prompts.py` (wired in `.claude/settings.json`) strips the prefix + prepends a worktree-isolation banner as a backstop, but briefs should still be clean at authorship time.
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
