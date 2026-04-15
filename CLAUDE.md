# TrainMe — Project Instructions

## What is TrainMe?

A multi-tenant SaaS platform for biokineticists and fitness trainers to build AI-animated exercise programs and distribute them to clients. Two surfaces: a web configuration portal (initial focus) and cross-platform client apps (future).

## Architecture Principles

- **Multi-tenant from day one** — Practice is the tenant boundary. Never build features that assume single-tenancy.
- **Animation pipeline is the core IP** — The AI-generated exercise animation system is the key differentiator. It uses a hybrid approach: AI generates the human figure, equipment is composited programmatically from SVG assets.
- **No licensed animation libraries** — All visual content is self-generated to avoid lock-in and recurring costs.
- **Social login only** — No username/password. Clients authenticate via Google/Apple social login or magic links.
- **Lottie as animation format** — Lightweight, scalable, works across web and mobile, supports playback control.

## Key Domain Model

- **Practice** — top-level tenant (clinic/studio/gym). Owns its exercise catalogue as IP.
- **Trainer** — belongs to a practice. Creates exercises via text prompts, builds training plans.
- **Client** — one account across the platform, can belong to multiple practices. Consumes plans.
- **Exercise** — prompt-generated 2D animated illustration with metadata (reps, duration, hashtags). Scoped to a practice's catalogue.
- **Plan** — ordered sequence of exercise instances with overridable parameters. Assigned to one or more clients. Living document — updated frequently.
- **Execution Instance** — recorded when a client steps through a plan. Tracks timestamps per step.

## Animation Pipeline (Critical Path)

The pipeline: Text prompt → LLM prompt enhancement → Text-to-motion (HY-Motion 1.0 / SayMotion) → Keyframe extraction → OpenPose skeleton → ControlNet + FLUX + Style LoRA rendering → Equipment SVG compositing → Lottie animation assembly.

Equipment is NEVER AI-generated. It's modelled as SVG vector assets anchored to skeleton joint positions. This is a deliberate design choice — AI handles bodies well but fails at equipment physics.

See `docs/ANIMATION_PIPELINE.md` for full technical specification.

## Current Phase

**Phase 0 — Animation Pipeline Prototype** (technical risk validation)

We are building a minimal prototype to validate the animation pipeline end-to-end before any product development. The prototype target: given "Standing bicep curl with dumbbell", produce a 4-6 frame 2D illustrated animation with SVG-composited equipment.

No product features (auth, multi-tenancy, UI) until the pipeline is proven feasible.

## Revenue Model

Pay-per-plan-issuance. The billing unit is a plan issued to a client. Minor updates don't trigger charges. Billing system is post-MVP but the data model should track issuance events.

## Compliance

POPIA (South Africa) at minimum. Assume personal and health-adjacent data will be stored. Architecture must support consent management and right to deletion.

## Key Documents

- `REQUIREMENTS.md` — Full requirements specification
- `docs/ANIMATION_PIPELINE.md` — Animation engine technical decision and pipeline architecture

## Development Guidelines

- This is early-stage — favour speed and validation over perfection
- The prototype phase should be scrappy and focused on proving the pipeline works
- Keep GPU/API costs low during prototyping (use hosted APIs like Replicate before self-hosting)
- Always consider offline-friendliness for future client app (cacheable assets, not streaming-only)
