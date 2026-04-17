# homefit.studio — Proof of Value (POV) Brief

> **Status:** Deployed — end-to-end pipeline live
> **Date:** 2026-04-16
> **Audience:** Internal + trusted bio tester
> **Goal:** Working demo to validate the workflow and get stakeholder buy-in
> **Live client URL:** `https://session.homefit.studio/p/{uuid}`
> **Domain:** homefit.studio (Hostinger) + Vercel hosting
> **Internal codename:** TrainMe/Raidme (bundle ID legacy)

---

## 1. What is Raidme?

A mobile app for biokineticists to create professional exercise plans during client sessions, instantly — no desktop, no post-session admin, no generic animation libraries.

The bio captures exercises on her phone while demonstrating them. The app converts each capture into a clean line drawing and lets her assemble a plan in minutes. The client receives a link and follows the exercises in a simple web player. No app download required for the client.

---

## 2. The Problem

After a session, a biokineticist needs to send the client home with an exercise programme. Today this looks like:

- **Handwritten sheets** — illegible, unprofessional, clients lose them
- **Generic PDFs** — stock images that don't match what was actually prescribed
- **Nothing at all** — the client tries to remember, gets it wrong, doesn't do it
- **Voice notes / text messages** — better than nothing, but no visual reference

The exercises demonstrated in the session — the ones the bio actually wants the client to do, with the specific form corrections — never make it into the plan in a usable format. The knowledge dies in the room.

---

## 3. The Solution

Capture it while it's happening. The bio films or photographs the client (or herself) doing each exercise during the session. The app instantly converts each capture to a clean black-and-white line drawing — professional-looking, consistent style, and naturally de-identified (you can't recognise the person). She drags them into order, adds reps and sets, and sends. The client gets a WhatsApp link to a web player within minutes of leaving the session.

---

## 4. POV Scope

The POV is not a product launch. It's a working tool to put in a real bio's hands for real sessions, to answer one question: **does this workflow work in practice?**

### 4.1 What's IN the POV

| Feature | Description |
|---------|-------------|
| **Capture** | Take photos and videos within the app. Each capture instantly converts to a line drawing. |
| **Review** | Thumbnail grid of all captures from the current session. Tap to preview. |
| **Trim** | Basic video trimming — set start and end points. |
| **Reorder** | Drag-and-drop to arrange exercises in the right sequence. |
| **Annotate** | Per exercise: reps, sets, hold duration, and a free-text note. |
| **Send** | Generate a shareable link. Share via WhatsApp (or any share sheet target). |
| **Web player** | Client opens link in browser. Swipeable exercise cards with line drawings/videos. No login. Works offline once loaded. |

### 4.2 What's NOT in the POV

| Excluded | Why |
|----------|-----|
| User accounts / auth | Bio uses the app directly, no login needed for POV |
| Multi-tenancy | Single bio, single practice — hardcoded or implicit |
| Exercise catalogue / reuse | Phase 2 — build after we understand usage patterns |
| Client app | The web player is the client experience for now |
| Billing | Not relevant until live product |
| Practice management | No team features, no admin panel |
| AI style transfer | Parked — line drawing is the MVP visual pipeline |
| Offline sync | Web player caches for offline, but app assumes connectivity for send |

### 4.3 The Flow

```
Session starts
    │
    ├─ Bio demonstrates exercise
    ├─ Bio taps capture (photo or video)
    ├─ App converts to line drawing instantly (on-device)
    ├─ Thumbnail appears in session strip
    │
    ├─ ... repeat for each exercise (typically 8-12) ...
    │
Session ends
    │
    ├─ Bio reviews captures, trims videos, reorders
    ├─ Bio adds reps/sets/notes per exercise
    ├─ Bio taps "Send" → share link via WhatsApp
    │
Client receives
    │
    ├─ WhatsApp message with link + preview card
    ├─ Taps link → web player opens
    └─ Follows exercises at home/gym
```

**Time budget:** Capture happens during the session (zero extra time). Editing + sending should take **under 5 minutes** between clients.

---

## 5. Technical Approach

### 5.1 Mobile App (Bio) — Flutter

- **Platform:** Flutter (Dart) — cross-platform iOS + Android from a single codebase
- **Why Flutter:** True native rendering (Skia/Impeller engine), mature OpenCV bindings (`opencv_dart`), sub-second hot reload for rapid UI iteration, pixel-identical behaviour across platforms. Camera + real-time image processing is Flutter's sweet spot.
- **Camera:** Native camera integration via `camera` package for photo + video capture
- **Line drawing conversion:** OpenCV runs on-device via `opencv_dart`. Pencil sketch divide + adaptive thresholding. No network call, no GPU, instant.
- **Video trimming:** Native video editor component (set in/out points) via `ffmpeg_kit_flutter`
- **Plan assembly:** Drag-and-drop card UI
- **Storage:** All captures stored locally first. Upload to cloud only when bio taps Send.
- **Share:** Generate unique plan URL, open system share sheet (WhatsApp as primary target)

### 5.2 Performance Architecture — Capture Must Never Block

The app's core loop is capture during a live session. If the bio has to wait between captures, she'll stop using it. Three operations are fully decoupled:

#### Layer 1: Capture (instant)

- Tap shutter → raw photo/video writes to local disk → thumbnail appears in session strip → camera ready for next capture
- **Target latency: <200ms** from tap to "ready for next capture"
- Raw file is the ground truth until conversion completes
- Session state (capture order, metadata) persists to local DB immediately

#### Layer 2: Conversion (background, async)

- A background processing queue picks up raw captures and converts to line drawings
- Runs on a separate isolate (Dart's equivalent of a background thread) — never touches the UI thread
- **Photo conversion:** ~200ms per image — queue drains almost instantly
- **Video conversion:** ~10-15 seconds for a 15-second clip at 30fps — queue may back up briefly
- Session strip shows conversion state per item:
  - Raw thumbnail with subtle progress indicator → crossfades to line drawing when done
- Converted files write to local disk alongside the raw originals
- If the app crashes or is interrupted, the queue rebuilds from unconverted raw files on next launch

#### Layer 3: Upload (on Send only)

- Nothing touches the network until the bio taps Send
- On Send: converted assets upload to cloud storage, plan metadata posts to API, shareable link generates
- **Only converted (line drawing) versions upload** — raw footage stays on device (smaller uploads, faster send, better privacy)
- If conversion queue isn't fully drained when Send is tapped: show "Converting 2 remaining..." with progress, then auto-proceed to upload
- Upload runs in background — bio can close the app after tapping Send and it completes

#### Resilience

- **Crash recovery:** Raw captures persist to disk immediately. Session state persists to local SQLite. On relaunch, the app restores the session and re-queues any unconverted items.
- **No data loss, ever.** If the phone dies, she loses nothing. When she reopens, everything is there.
- **Network failure on Send:** Retry with backoff. Assets that uploaded successfully aren't re-uploaded. The bio sees "Sending... (retrying)" not an error wall.

#### Capacity

| Scenario | Queue depth | Drain time | Bio impact |
|----------|------------|------------|------------|
| 10 photos rapid-fire | 10 items | ~2 seconds | None — she won't notice |
| 5 photos + 3 videos (15s each) | 8 items | ~50 seconds | Thumbnails convert progressively while she works with client |
| Hit Send with 2 videos still converting | 2 items | ~25 seconds | Brief "Converting..." then auto-sends |

### 5.3 Backend — Supabase (Hosted, Zero Ops)

Supabase (supabase.com) provides database, file storage, and auto-generated API as a managed service. No server to provision or maintain.

- **Database:** Supabase Postgres — plan metadata (exercise order, reps, sets, notes, asset URLs)
- **Storage:** Supabase Storage — line drawing images/videos, CDN-delivered
- **API:** Auto-generated REST API from table schema. No custom backend code for POV.
- **No auth for POV** — plans accessible by link (unguessable UUID URL, like Google Docs "anyone with the link")
- **Free tier:** 500MB database, 1GB file storage, 50K API requests/month — plenty for POV
- **Region:** EU West (closest to South Africa)

**Architecture evolution path:**
- POV: Flutter app talks directly to Supabase auto-generated API (zero custom backend code)
- MVP: Add Supabase Edge Functions (Deno/TypeScript) for auth, business rules, billing hooks
- Scale: Migrate to dedicated API server (Railway/Fly.io) connecting to the same Supabase Postgres

Each step is additive — the database, storage, Flutter app, and web player carry forward unchanged.

### 5.4 Web Player — Vercel (Static Hosting)

Vercel serves the client-facing web player. Not the backend — just the shopfront.

- **Static web app** — HTML/CSS/JS hosted on global CDN, auto-deploys from GitHub on `git push`
- **Responsive** — optimised for portrait phone screens (clients open from WhatsApp on their phone)
- **One exercise at a time** — swipeable cards with progress indicator ("3 of 10"), not a wall of content
- **Video playback** — tap to play line-drawing video if available
- **Offline** — service worker caches all assets on first load so client can use at the gym without signal
- **No login** — URL contains the plan identifier
- **WhatsApp preview:** One edge function generates Open Graph meta tags per plan (title, first exercise thumbnail, exercise count) so the shared link renders a rich preview card in WhatsApp
- **Free tier:** More than sufficient for POV traffic

### 5.5 Line Drawing Pipeline

Already validated. Uses the bundled `line-drawing-convert` skill (OpenCV):

- **Photos:** Single frame conversion, ~200ms
- **Videos:** Frame-by-frame conversion, ~1s per second of footage
- **On-device:** Runs entirely on phone CPU via `opencv_dart`. No network, no GPU, no API.
- **Tuning:** blur_kernel=31, threshold_block=9, contrast_low=80 (good defaults, adjustable later)
- **Output:** Same format as input (jpg→jpg, mp4→mp4)
- **Video cap:** 30 seconds max. UI encourages 10-15 seconds via progress ring that turns amber at 15s.
- **Orientation:** Portrait-first. Landscape handled gracefully but not optimised for.

---

## 6. Success Criteria

The POV succeeds if a real biokineticist can:

- [ ] Capture 8-10 exercises during a real session without disrupting her flow
- [ ] Assemble and send the plan in under 5 minutes after the session
- [ ] The client can open the link and follow the exercises without confusion
- [ ] The bio says: "I would use this with all my clients"

The POV fails if:

- The capture step is too disruptive to the session
- The editing takes so long that she can't finish before the next client
- The line drawings are too abstract to understand the exercise
- The client can't figure out the web player without help

---

## 7. What Comes After POV

If the POV validates, the roadmap to MVP adds:

| Phase | Feature | Why |
|-------|---------|-----|
| MVP | User accounts (social login) | Multi-bio usage, data ownership |
| MVP | Multi-tenancy (Practice model) | Multiple bios per practice |
| MVP | Exercise catalogue | Reuse captures across plans and clients |
| MVP | Client history | Bio sees all plans sent to a client |
| MVP | Plan templates | Standard plans assembled from catalogue |
| Post-MVP | Client app | Richer experience, push notifications, progress tracking |
| Post-MVP | AI style transfer | Premium "HD illustration" mode using Stability AI / Kling O1 |
| Post-MVP | Billing | Pay-per-plan-issuance model |
| Post-MVP | Execution tracking | Client marks exercises as done, bio sees compliance |

---

## 8. Resolved Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| **Framework** | Flutter (Dart) | Best OpenCV bindings, true native rendering, sub-second hot reload. Dart is near-identical to C# syntactically. |
| **Video length** | 30s hard cap, UI nudges 10-15s | One rep is 3-15 seconds. Progress ring turns amber at 15s, auto-stops at 30s. |
| **WhatsApp preview** | OG meta tags per plan | Server renders title + first exercise thumbnail + count. Test early — massive UX impact for free. |
| **Exercises per plan** | Design for 8-12, no hard limit | Scrollable session strip during capture, vertical card list for editing. One-at-a-time in web player. |
| **Orientation** | Portrait-first | Bios film vertically. Exercise subjects are taller than wide. Player designed for portrait. Landscape handled but not optimised. |
| **Capture architecture** | Three decoupled async layers | Capture (instant) → Conversion (background queue) → Upload (on Send only). Never block the camera. |
| **Local persistence** | All captures saved to disk immediately | Crash recovery, no data loss. Raw + converted versions both retained on device. |
| **Upload strategy** | Converted files only, on Send | Raw footage stays on device. Smaller uploads, faster send, better privacy. |

## 9. Build Plan

### Phase 1 — Foundations (Week 1)

Two parallel tracks with no dependencies between them.

**Track A: Flutter app shell + camera + conversion**

| Step | Deliverable | Risk |
|------|------------|------|
| Scaffold Flutter project (iOS + Android) | Empty app runs on both platforms | Low |
| Camera integration (`camera` package) | Tap to capture photo, hold to record video | Low |
| Integrate `opencv_dart` + port line drawing algorithm | Photos convert to line drawings on-device | **Medium — key risk** |
| Session strip UI | Thumbnails appear as captures are taken | Low |
| Three-layer async architecture | Capture instant, conversion in background isolate, local persistence | Medium |
| Video recording with 30s cap + progress ring | Ring turns amber at 15s, auto-stops at 30s | Low |

**Milestone:** Capture exercises on phone, see them convert to line drawings in real-time. Everything local, no backend.

**Track B: Supabase + web player**

| Step | Deliverable | Risk |
|------|------------|------|
| Create Supabase project, define `plans` + `exercises` tables | Schema live, API auto-generated | Low |
| Create storage bucket for media assets | Upload/download working | Low |
| Build web player (static HTML/CSS/JS) | Swipeable exercise cards, video playback | Low |
| Seed test data manually via Supabase dashboard | Fake plan with line drawings viewable in player | Low |
| Deploy web player to Vercel | Live at a URL, auto-deploys from GitHub | Low |
| Add OG meta tag edge function | WhatsApp preview card renders correctly | Low |

**Milestone:** Open a link on your phone and step through a plan in the browser. Data is fake, but the experience is real.

### Phase 2 — Plan Assembly UI (Week 2)

Builds on Phase 1 Track A. Requires capture flow working.

| Step | Deliverable | Risk |
|------|------------|------|
| "Start session" flow | Bio enters client name, starts capturing | Low |
| Plan editor screen | Vertical card list of captured exercises | Low |
| Drag-and-drop reorder | Long-press to drag, reorder persists | Low |
| Exercise annotation | Tap card → edit reps, sets, hold duration, free-text note | Low |
| Video trimming | Set in/out points on video captures | Medium |
| Preview mode | Tap thumbnail → full-screen line drawing preview. Option to re-capture. | Low |

**Milestone:** Bio can capture a full session, arrange the plan, and annotate every exercise. Still fully local — no backend connection.

### Phase 3 — Integration (Week 3, first half)

Both tracks merge. Requires Phase 1 Track B and Phase 2 complete.

| Step | Deliverable | Risk |
|------|------------|------|
| Wire Flutter to Supabase (`supabase_flutter` SDK) | App can create plans and upload assets | Low |
| Build "Send" flow | Upload assets → create plan record → generate link → share sheet | Medium |
| Connect web player to real Supabase data | Player fetches plan + assets dynamically | Low |
| End-to-end test | Capture on phone → send → open link on another phone → see plan | Low |
| WhatsApp share test | Verify preview card renders with real plan data | Low |

**Milestone:** The POV works end-to-end. Bio captures, edits, sends. Client receives link and follows exercises.

### Phase 4 — Harden for Real Use (Week 3, second half)

POV works but must survive a real session before handing it to the bio.

| Step | Deliverable | Risk |
|------|------------|------|
| Crash recovery testing | Kill app mid-session → relaunch → session restored | Medium |
| Network failure handling | Send with no signal → retry when connection returns | Medium |
| Load test with 12-15 exercises incl. videos | Conversion queue, upload time, storage within limits | Low |
| Battery + memory profiling | OpenCV + camera don't drain phone over a 45-min session | Low |
| iOS + Android device testing | Both platforms work identically | Medium |
| UX walkthrough | Step through the flow as if you're the bio, note friction points, polish | Low |

**Milestone:** Phone handed to the bio. "Use it in your session tomorrow."

### Timeline Summary

```
Week 1                    Week 2                    Week 3
├─ Track A: Flutter       ├─ Phase 2: Plan          ├─ Phase 3: Integration
│  camera + conversion    │  assembly UI             │  (first half)
│                         │  reorder, annotate,      │
├─ Track B: Supabase      │  trim, preview           ├─ Phase 4: Harden
│  + web player           │                          │  (second half)
│  (parallel)             │                          │
▼                         ▼                          ▼
Can capture + convert     Full plan assembly          POV in bio's hands
locally on phone          working locally             for real sessions
```

### Key Risk

The **`opencv_dart` integration** in Phase 1 Track A is the one unknown. The line drawing algorithm is proven (Python/OpenCV), but porting it to Dart bindings on mobile is untested. If this hits a wall, the fallback is to run the OpenCV conversion in a platform channel (native Swift/Kotlin calling OpenCV directly). More work, but proven pattern. We'll know within 2-3 days of starting Track A.

---

## 10. Remaining Open Questions

1. **Domain name?** Need to register something (e.g. `raidme.app`). Plan URLs will be `{domain}/p/{uuid}` — short enough for WhatsApp, unguessable for security.

2. **How does the bio identify clients in POV?** No auth means no user accounts. Simplest: bio types client name when starting a session. Plan is labelled with that name. Good enough for POV.
