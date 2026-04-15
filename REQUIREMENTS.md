# TrainMe — Requirements Specification

> **Status:** Draft v1 — Post-brainstorm
> **Date:** 2026-04-15
> **Next step:** Technical feasibility research (AI animation engine), then `/sc:design` for architecture

---

## 1. Product Overview

**TrainMe** is a platform for biokineticists and fitness professionals to build, manage, and distribute exercise training programs to their clients.

It consists of two primary surfaces:

1. **Configuration Portal (web)** — where trainers build exercise catalogues and training plans
2. **Client App (cross-platform, future)** — where clients consume and execute their assigned plans

The initial build focuses on the **configuration portal MVP**.

---

## 2. User Roles

| Role | Description |
|------|-------------|
| **Platform Admin** | TrainMe team. Manages practices, system config, billing. CLI/backend access initially. |
| **Practice Admin** | Manages trainers, clients, practice settings, catalogue oversight. May also be a trainer. |
| **Trainer** | Builds catalogue exercises (via prompts), creates plans, manages assigned clients. |
| **Client** | Consumes plans on the app (future). Has one account across multiple practices. |

---

## 3. Organizational Model

### 3.1 Practice (Tenant)

- The top-level organizational unit (clinic, studio, gym)
- Multi-tenant from day one — each practice is an isolated tenant
- Provisioned via backend/CLI initially (self-service onboarding is a future feature)
- Has its own branding (logo, colors) applied to client-facing surfaces
- All client-facing surfaces include **"Powered by TrainMe"** co-branding
- Owns its exercise catalogue as intellectual property

### 3.2 Membership

- A practice has many trainers
- A practice has many clients
- A trainer belongs to one practice (assumed for MVP)
- A client can belong to multiple practices and have plans from each
- A client has a single account across the platform

---

## 4. Exercise Catalogue

### 4.1 Exercise Creation

- Trainers create exercises by typing a **freeform text prompt** describing the exercise
- The system generates a **2D illustrated, step-by-step animation** from the prompt
- The animation must be anatomically correct and demonstrate proper form
- Animations should support visual correction cues (arrows, joint highlights, "wrong form" indicators) — MVP nice-to-have
- If the generated animation is not satisfactory, the trainer **tweaks the prompt and regenerates**
- No manual frame editor in MVP — prompt iteration is the editing mechanism

### 4.2 Exercise Metadata

| Field | Source | Description |
|-------|--------|-------------|
| Animation | AI-generated | 2D step-by-step illustrated animation |
| Prompt | Trainer | The text prompt used to generate the animation |
| Suggested reps | Trainer | Default rep count, overridable in plans |
| Suggested duration | Trainer | Default time allocation, overridable in plans |
| Hashtags | Trainer | Freeform tags for categorization (e.g., `#hamstring`, `#resistance-band`, `#rehab`) |
| Notes | Trainer | Creator's notes on the exercise |
| Created by | System | Trainer who created the exercise |

### 4.3 Catalogue Scope & Permissions

- The catalogue is **scoped to the practice** — it is the practice's IP
- All trainers within a practice can **view** all catalogue exercises
- Trainers can **clone** another trainer's exercise and modify the clone
- Trainers **cannot edit** another trainer's original exercise
- Editing others' originals is a potential future feature
- Hashtags are freeform and editable across all artefacts they appear on, enabling practice-specific taxonomy

---

## 5. Training Plans

### 5.1 Plan Structure

A plan is an **ordered sequence of exercise instances** designed to be executed in order like a guided workout.

**Exercise instance within a plan:**

| Field | Inherited from catalogue | Overridable | Plan-only |
|-------|--------------------------|-------------|-----------|
| Animation | Yes | No | — |
| Reps | Yes (suggested) | Yes | — |
| Duration | Yes (suggested) | Yes | — |
| Sets | — | — | Yes |
| Rest period | — | — | Yes |
| Step notes | — | — | Yes (notes to client for this step) |
| Sequence position | — | — | Yes (drag-and-drop ordering) |

**Plan-level metadata:**

| Field | Description |
|-------|-------------|
| Name | Plan title |
| Overall notes | Notes to client about the plan as a whole |
| Calculated total duration | Sum of individual durations + rest periods |
| Assigned clients | One or more clients |
| Status | Active / inactive |

### 5.2 Plan Builder

- Drag-and-drop interface to compose exercises into a plan
- Exercises pulled from the practice catalogue
- Parameters (reps, duration, sets, rest periods) configurable per exercise instance
- Step-level and plan-level notes fields
- Total duration calculated and displayed as exercises are added/configured
- **In-portal plan preview/player**: a "Play" button that steps through the plan from the client's perspective — showing animations, timers, and notes exactly as the client would experience them

### 5.3 Plan Assignment & Sharing

- A plan can be assigned to **one or multiple clients**
- When a shared plan is updated, **all assigned clients receive the update**
- To give a client an individualized plan, the trainer can **disconnect the client from the group plan** and the system creates a **copy** of the current plan for that client, which can then be independently tweaked
- Plan frequency (e.g., "do this twice a week") is communicated via notes — the system does not manage scheduling in MVP

### 5.4 Plan Lifecycle

- Plans are **living documents** — trainers can tweak them at any time (common after fortnightly reassessments)
- No version history in MVP
- When a plan is modified, assigned clients receive an **in-app push notification**
- The plan is not precious — changes happen frequently and casually (even based on WhatsApp conversations)

---

## 6. Plan Execution (Data Model — MVP; UI in Client App — Future)

Even though the client app is post-MVP, the data model must support execution tracking:

- When a client steps through a plan on their device, it creates an **execution instance**
- Each execution records:
  - Date and time of execution
  - Timestamps per step (when "next" was tapped)
  - Total execution time
- The guided player experience includes:
  - Step-by-step animation playback
  - Timer per exercise showing allocated vs elapsed time
  - Visual indicator if the client is behind schedule
  - "Next" navigation through the sequence

---

## 7. Client Management

### 7.1 Registration & Onboarding

- Trainer registers a client in the portal (basic details)
- System sends an **email invitation** to the client
- Client onboards via **social login** (Google, Apple, etc.) — no username/password
- **Magic link** available as fallback for login issues
- Minimal friction is critical — this audience has low motivation for account setup

### 7.2 Client Account Model

- A client has **one account** across the entire platform
- A client can be associated with **multiple practices**
- Each practice's plans appear separately in the client's app
- Client data is scoped to the practice that created it (multi-tenant isolation)

---

## 8. Notifications

| Event | Channel | MVP |
|-------|---------|-----|
| Client invited | Email | Yes |
| Plan assigned | Push notification | Yes |
| Plan updated | Push notification | Yes |
| Client inactive (future) | Dashboard alert to trainer | No |

No email or SMS notifications beyond the initial invite. Push notifications and in-app indicators only.

---

## 9. Authentication & Authorization

| Mechanism | For |
|-----------|-----|
| Social login (Google, Apple, etc.) | All users — primary auth method |
| Magic link | Fallback for login issues |
| Role-based access | Platform admin, practice admin, trainer, client |

No email/password authentication. Social identity is the only auth path.

---

## 10. Branding & Multi-Tenancy

- Each practice can configure: **logo, brand colors**
- Client-facing surfaces display practice branding
- **"Powered by TrainMe"** always visible as co-branding
- Multi-tenant architecture from day one
- Tenant isolation for data, catalogue, and plans
- Practices provisioned via CLI/backend initially

---

## 11. Revenue Model

- **Pay-per-plan-issuance**: the billing unit is a plan issued to a client
- Minor updates to an existing plan for the same client do not trigger additional charges
- Abuse potential acknowledged (single morphing plan) — to be addressed later
- Billing/usage tracking is **not in MVP** but the data model should support it (track plan issuance events)

---

## 12. Privacy & Compliance

- Assume the platform will store **personal and health-adjacent data**
- POPIA (South Africa) compliance required at minimum
- Architecture must support compliance requirements (data residency, consent, right to deletion)
- Specific compliance scope to be defined during design phase

---

## 13. Technical Considerations

### 13.1 AI Animation Engine (Critical Path)

- **This is the highest-risk, highest-priority technical dependency**
- Must research and validate a tool/API that can generate 2D illustrated exercise animations from text prompts
- Requirements for the engine:
  - Input: freeform text describing an exercise
  - Output: 2D illustrated step-by-step animation
  - Anatomically correct body positioning
  - Support for various exercise types (bodyweight, resistance band, weights, stretching, etc.)
  - Reasonable generation time (trainer will wait, but not minutes)
  - Cost-effective at scale (every exercise creation triggers generation)
- **This must be researched and validated before architecture decisions are made**

### 13.2 Offline Considerations

- Not required for MVP
- Architecture should not make offline support impossible for the future client app
- Practically: animations should be downloadable/cacheable assets, not streaming-only

### 13.3 Scale

- Start small (single pilot practice) but architect for multi-tenant scale
- No specific year-one targets defined
- Standard cloud-native scaling patterns appropriate

---

## 14. MVP Scope Summary

### In Scope

- [ ] Practice & trainer setup (backend-provisioned)
- [ ] Client registration & email invite
- [ ] Social login + magic link authentication
- [ ] Exercise catalogue with AI-generated 2D animations (prompt-based)
- [ ] Freeform hashtag categorization for exercises
- [ ] Plan builder with drag-and-drop + parameter overrides
- [ ] Step-level and plan-level notes
- [ ] In-portal plan preview/player (step-through with animations and timers)
- [ ] Plan assignment to individual and multiple clients
- [ ] Plan fork (disconnect client from group plan with copy)
- [ ] Plan change push notifications
- [ ] Practice co-branding (logo, colors + "Powered by TrainMe")
- [ ] Multi-tenant data architecture
- [ ] Privacy/compliance foundations
- [ ] Execution tracking data model (no UI yet)

### Out of Scope (Future)

- Client-facing mobile app (guided workout player)
- Execution tracking UI & analytics dashboard
- Billing/usage tracking UI
- Self-service practice onboarding
- Offline mode for client app
- Cross-practice catalogue sharing
- Plan version history
- Editing other trainers' catalogue exercises
- Email/SMS notifications
- Trainer activity/compliance reporting

---

## 15. Open Questions

1. **AI animation engine** — which tool/API/model will power the 2D exercise animation generation? This is the critical path blocker and must be researched first.
2. **Animation storage** — what format should generated animations be stored in for portability across web and future native apps? (Lottie, sprite sheets, GIF, video?)
3. **Compliance specifics** — beyond POPIA, are there other jurisdictions or certifications to target? Is the health data detailed enough to fall under medical data regulations?
4. **Billing triggers** — what precisely constitutes a "plan issuance" vs a "minor update"? Needs definition before billing implementation.
5. **Practice branding depth** — how much customization beyond logo and colors? Custom domain? Custom email templates?

---

## 16. Recommended Next Steps

1. **AI Animation Engine Research** — investigate and prototype candidate tools for generating 2D exercise animations from text prompts. This unblocks all other work.
2. **`/sc:design`** — system architecture design (multi-tenant data model, auth, API design, animation pipeline)
3. **`/sc:workflow`** — implementation planning and sprint breakdown
