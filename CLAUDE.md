# TrainMe — Project Instructions

## What is TrainMe?

A multi-tenant SaaS platform for biokineticists and fitness trainers to build exercise programs with clean visual demonstrations and distribute them to clients. Trainers capture exercise footage on their phone; the app converts it to professional line-art demos. Two surfaces: a web configuration portal (initial focus) and cross-platform client apps (future).

## Architecture Principles

- **Multi-tenant from day one** — Practice is the tenant boundary. Never build features that assume single-tenancy.
- **Exercise visualisation is the core IP** — The exercise demonstration system is the key differentiator. MVP uses on-device line drawing conversion of real exercise footage. AI-based approaches (Stability AI, Kling O1) are future premium features.
- **No licensed animation libraries** — All visual content is self-generated to avoid lock-in and recurring costs.
- **On-device processing preferred** — Where possible, run conversions locally (no API costs, instant results, better privacy). Cloud AI is for premium features only.
- **Offline-first architecture** — The entire capture → convert → edit → preview flow is 100% offline. Only Publish touches the network. Never break this. Future: add a publish queue that batches uploads when connectivity is available.
- **Non-blocking publish** — Publishing runs in the background. The bio never waits for uploads. This is a core UX principle — protect it in all future updates.
- **Social login only** — No username/password. Clients authenticate via Google/Apple social login or magic links.
- **Lottie as animation format** — For future AI-generated animations. Line drawing video output uses standard video formats (mp4/mov).

## Key Domain Model

- **Practice** — top-level tenant (clinic/studio/gym). Owns its exercise catalogue as IP.
- **Trainer** — belongs to a practice. Creates exercises via text prompts, builds training plans.
- **Client** — one account across the platform, can belong to multiple practices. Consumes plans.
- **Exercise** — visual demonstration (line drawing converted from trainer footage) with metadata (reps, duration, hashtags). Scoped to a practice's catalogue.
- **Plan** — ordered sequence of exercise instances with overridable parameters. Assigned to one or more clients. Living document — updated frequently.
- **Execution Instance** — recorded when a client steps through a plan. Tracks timestamps per step.

## Exercise Visual Pipeline

**MVP — Line Drawing Conversion (decided 2026-04-16):**
Trainer films/photographs client doing exercise → OpenCV converts to clean line drawing on-device → Professional-looking exercise demo for the training plan.

- Uses pencil sketch divide + adaptive thresholding (no AI, no GPU, no API)
- Runs on phone CPU — instant processing, zero cost per conversion
- Privacy benefit: line drawings naturally de-identify the client (POPIA-friendly)
- Dependencies: opencv-python-headless, numpy, Pillow
- Converter bundled as `line-drawing-convert.skill` in project root
- Workflow: capture in app → convert inline → trainer reviews → save to exercise catalogue

**Future — AI Style Transfer (premium feature, parked):**
- Stability AI Control Sketch/Structure API — single image style transfer (works, tested)
- Kling O1 on fal.ai — video-to-video style transfer (best quality, ~$0.10-0.50/video)
- Text-to-motion pipeline — awaiting SayMotion API credentials from DeepMotion
- Equipment SVG compositing validated with mock data

See `docs/ANIMATION_PIPELINE.md` for full technical specification of the AI pipeline.

## Current Phase

**Phase 0 → Phase 1 transition** — Visual pipeline validated, moving toward product.

- Line drawing conversion proven as MVP approach for exercise visualisation
- AI pipeline validated end-to-end (mock motion + real Stability AI rendering) — parked as future premium
- SayMotion API credentials still pending from DeepMotion (for text-to-motion track)
- Next: build the app capture → convert → catalogue flow

## Infrastructure Rules (learned the hard way)

- **On-device processing preferred** for MVP. Cloud APIs for premium features only.
- **Hosted REST APIs only** when cloud is needed. No self-hosted GPU pods.
- RunPod SSH from automated environments doesn't work reliably (PTY issues, disk limits, dependency hell)
- Replicate free tier is too limited for SA-based developers (payment processing issues)
- Luma Labs phone verification doesn't work from SA
- fal.ai works (email-only signup) — hosts Kling O1 and other video models
- Stability AI is the working image generation provider (v2beta endpoints only)

## Revenue Model

Pay-per-plan-issuance. The billing unit is a plan issued to a client. Minor updates don't trigger charges. Billing system is post-MVP but the data model should track issuance events.

## Compliance

POPIA (South Africa) at minimum. Assume personal and health-adjacent data will be stored. Architecture must support consent management and right to deletion.

## Key Documents

- `REQUIREMENTS.md` — Full requirements specification
- `docs/ANIMATION_PIPELINE.md` — Animation engine technical decision and pipeline architecture
- `line-drawing-convert.skill` — Bundled line drawing converter (MVP visual pipeline)

## Development Guidelines

- This is early-stage — favour speed and validation over perfection
- The prototype phase should be scrappy and focused on proving the pipeline works
- Keep GPU/API costs low during prototyping (use hosted APIs like Replicate before self-hosting)
- Always consider offline-friendliness for future client app (cacheable assets, not streaming-only)
