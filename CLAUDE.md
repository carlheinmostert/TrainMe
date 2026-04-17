# homefit.studio — Project Instructions

## What is this?

**homefit.studio** (internally codenamed TrainMe/Raidme) is a multi-tenant SaaS platform for biokineticists, physiotherapists, and fitness trainers to capture exercises during a client session, convert them into clean line-drawing demonstrations on-device, assemble a plan, and share it with the client via a WhatsApp-friendly link.

**Two surfaces:**
1. **Flutter mobile app** — the trainer's tool (dark mode, coral orange accent)
2. **Web player** at `session.homefit.studio/p/{planId}` — what the client sees

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
- **Local storage:** SQLite via `sqflite`. Schema version 10. All paths stored relative via `PathResolver`.
- **Conversion service:** Singleton pattern, survives screen navigation. FIFO queue processes captures sequentially.
- **Backend:** Supabase (yrwcofhovrcydootivjx.supabase.co)
  - Tables: `plans`, `exercises` with full data model (circuits, rest periods, audio, custom durations, versions, thumbnails)
  - Storage bucket: `media` (public)
  - RLS: public read + insert + update + delete (security by unguessable UUID for POV)
- **Web player:** Static HTML/CSS/JS on Vercel, auto-deploys from GitHub (`web-player/` directory)
- **Domain:** Hostinger DNS, CNAME `session` → `cname.vercel-dns.com` (updated to `00596c638d4cefd8.vercel-dns-017.com.` per Vercel's new IP range)
- **OG meta tags:** Vercel Edge Middleware (`web-player/middleware.js`) serves bot-friendly HTML for WhatsApp link previews
- **Service worker:** `web-player/sw.js` caches app shell for offline. Cache name `homefit-player-v3-dark` — bump on major changes.

## Key Domain Model

- **Practice** — top-level tenant (not yet implemented, single-tenant for POV)
- **Trainer** — builds plans (no auth yet, single-user POV)
- **Client** — receives plans via URL (no auth, URL is unguessable UUID)
- **Session** — a workout plan
  - `id`, `clientName`, `title`, `circuitCycles` (JSON map), `preferredRestIntervalSeconds`, `version`, `planUrl`, `lastPublishedAt`, `sentAt`, `deletedAt`
- **ExerciseCapture** — one item in a session
  - `id`, `position`, `name`, `mediaType` (photo/video/rest), `rawFilePath`, `convertedFilePath`, `thumbnailPath`
  - `reps`, `sets`, `holdSeconds`, `notes`, `customDurationSeconds`
  - `circuitId`, `includeAudio`, `conversionStatus`
- **Circuits** — group of consecutive exercises with shared `circuitId`. `circuitCycles` on session = how many times the group repeats.
- **Rest periods** — `mediaType: rest`. Compact inline bars between exercise cards. Auto-inserted every N minutes (N learned from user's drag behaviour, default 10).
- **Plan versions** — increments on each Publish. URL stays the same; client always sees latest.

## Feature State (MVP complete)

### Trainer App
- One-tap new session (default name: current date/time)
- Import from photo library (photo or video)
- Live camera capture (photo = tap, video = long press)
- Native iOS video-to-video line drawing conversion with audio passthrough
- Photo line drawing via OpenCV
- Expandable exercise cards with three independent sub-sections (Settings / Preview / Notes)
- Thick pill-shaped sliders for reps/sets/hold, custom duration override
- Circuit grouping via link buttons, drag-to-detach
- Rest periods as compact inline bars with learned auto-insert interval
- Inline-editable exercise names and session names (dashed underline)
- Drag handles for reordering
- Swipe-to-delete sessions with undo snackbar
- Soft-delete recycle bin, 7-day retention
- Estimated duration per exercise and per session
- Slideshow preview with progress bar, nav buttons, workout timer mode (play gates, rest auto-start, pause/resume)
- Publish + Copy Link + Share buttons on home screen session cards
- Background publishing — bio keeps working while upload runs
- Audio toggle per video exercise (default muted, explicit opt-in)

### Client Web Player
- Dark theme matching app
- Swipeable card deck
- Progress bar + nav chevrons + dot indicators (dots hide past 10 slides)
- Circuit unrolling (each round shown as separate slide)
- Circuit indicator bar: "Circuit · Round 2 of 3 · Exercise 1 of 3"
- Rest period cards with calming countdown
- Video playback with conditional audio based on `include_audio`
- Workout timer mode with play gates, auto-advance, rest auto-start
- "Start Workout" button, pause/resume
- WhatsApp OG preview via Edge Middleware
- Service worker for offline use

## Current Phase

**POV deployed end-to-end, ready for first bio tester.**

Next logical steps:
- Deploy to Carl's iPhone for real-world capture testing
- First trusted-bio trial
- Iterate on bio feedback
- Move from POV to MVP (add auth, multi-tenancy, billing)

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

Pay-per-plan-issuance. Billing unit is a plan issued to a client. Plan versions increment on each publish but minor updates don't re-bill (model decision to make post-MVP). Billing itself is post-MVP.

## Compliance

POPIA (South Africa) at minimum. Line drawings naturally de-identify clients — major privacy advantage built into the visual pipeline.

## Key Documents

- `CLAUDE.md` — this file
- `docs/POV_BRIEF.md` — Proof-of-value brief with vision and build plan
- `docs/MARKET_RESEARCH.md` — Competitive landscape + business case validation
- `docs/ANIMATION_PIPELINE.md` — AI pipeline (parked) technical spec
- `supabase/schema.sql` — Database schema
- `app/lib/theme.dart` — Brand theme tokens
- `app/lib/widgets/powered_by_footer.dart` — Shared Pulse Mark footer
- `app/ios/Runner/VideoConverterChannel.swift` — Native video pipeline

## Development Guidelines

- Favour speed and validation over perfection — this is pre-product
- Use sub-agents in background for heavy implementation work; stay available for conversation
- Never use `flutter run` — use build + `simctl install` instead (see Infrastructure Rules)
- Build the Flutter app with: `cd app && flutter build ios --debug --simulator`
- Install with: `xcrun simctl install <device-id> <runner.app>`
- Launch with: `xcrun simctl launch <device-id> com.raidme.raidme`
- Web player auto-deploys via Vercel on `git push`
- Bump `sw.js` CACHE_NAME when making major web player changes
- Supabase schema changes: update `supabase/schema.sql`, user runs SQL manually in Supabase SQL Editor
- Always consider offline-first — the bio must be able to work without signal

## Simulator Testing Notes

- Physical device UDID (Carl's iPhone): `00008150-001A31D40E88401C`
- Current simulator: iPhone 16e (`E4285EC5-6210-4D27-B3AF-F63ADDE139D9`)
- Push media to simulator: `xcrun simctl addmedia <device-id> <file>`
- Read simulator clipboard: `xcrun simctl pbpaste <device-id>` (use this to grab shared URLs)
- Query Supabase directly: `curl -H "apikey: <key>" "https://yrwcofhovrcydootivjx.supabase.co/rest/v1/plans?..."`
