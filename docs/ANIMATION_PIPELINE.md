# Animation Pipeline — Technical Decision

> **Status:** AI pipeline parked — Line Drawing MVP chosen (2026-04-16)
> **Date:** 2026-04-15 (original), updated 2026-04-16
> **Priority:** Parked as future premium feature. MVP uses on-device OpenCV line drawing conversion instead.

---

> **⚠️ Update (2026-04-16):** After exploring multiple AI approaches (Stability AI, Kling O1 on fal.ai, text-to-motion), the team decided to ship an MVP using **OpenCV-based line drawing conversion** instead. Trainers capture exercise footage on their phone → the app converts it to clean black-and-white line art on-device (no API, no GPU, instant). This avoids all the cost, latency, and infrastructure complexity of the AI pipeline. The AI pipeline below remains a valid future upgrade path for a "premium HD illustration" feature. See `line-drawing-convert.skill` in the project root for the converter implementation.

---

## 1. Decision Summary

TrainMe will use a **hybrid AI generation + deterministic equipment compositing** pipeline to produce 2D illustrated step-by-step exercise animations from trainer text prompts.

- The **AI** handles the human figure only (body positioning, anatomical correctness)
- **Equipment** (resistance bands, dumbbells, barbells, cables, machines) is modelled as separate vector assets and composited programmatically using skeleton joint data
- No licensed animation libraries — everything is generated or self-owned, avoiding lock-in and recurring costs

---

## 2. Why Not Licensed Libraries?

Options like Vector Fitness Exercises ($1,200-$2,000+), GymVisual, and Exercise Animatic were evaluated and rejected:

- **Expensive** — upfront cost plus scaling concerns as the catalogue grows
- **Lock-in** — dependent on a third-party's asset library, style, and licensing terms
- **Inflexible** — cannot generate novel exercises; limited to what's in the library
- **Style mismatch risk** — if TrainMe's brand evolves, relicensing or restyling is costly

The self-owned pipeline gives full control over style, unlimited exercise generation, and zero per-asset licensing cost.

---

## 3. Pipeline Architecture

### 3.1 Overview

```
Trainer text prompt
        │
        ▼
┌─────────────────────┐
│  Text-to-Motion     │  Generate 3D skeleton motion sequence
│  (HY-Motion 1.0 /   │  from exercise description
│   SayMotion API)     │
└────────┬────────────┘
         │
         ▼
┌─────────────────────┐
│  Keyframe Extraction│  Extract 4-8 key poses from the
│                     │  motion sequence
└────────┬────────────┘
         │
         ▼
┌─────────────────────┐
│  Pose → OpenPose    │  Convert 3D joint positions to
│  Skeleton Format    │  2D OpenPose skeleton images
└────────┬────────────┘
         │
         ▼
┌─────────────────────┐
│  ControlNet + FLUX  │  Generate consistent 2D illustrated
│  + Style LoRA       │  figure for each keyframe pose
│  + IP-Adapter       │  (character consistency across frames)
└────────┬────────────┘
         │
         ▼
┌─────────────────────┐
│  Equipment          │  Overlay vector equipment assets
│  Compositing Layer  │  anchored to skeleton joint positions
└────────┬────────────┘
         │
         ▼
┌─────────────────────┐
│  Animation Assembly │  Compile frames into step-by-step
│                     │  animation (Lottie / sprite sheet)
└─────────────────────┘
```

### 3.2 Stage Details

#### Stage 1: Text-to-Motion

**Primary:** Tencent HY-Motion 1.0 (open-source, self-hosted)
- Billion-parameter DiT model with RLHF
- Trained on 3,000+ hours of motion data
- Best open-source quality for natural human motion
- Output: SMPL-compatible 3D joint sequences
- Self-hosted = no per-generation cost beyond GPU compute

**Fallback:** DeepMotion SayMotion API
- Commercial API, $15-300/month depending on volume
- Outputs FBX/GLB/BVH/MP4
- Better for quick prototyping before self-hosting HY-Motion

**Limitation acknowledged:** These models are trained on general motion datasets (HumanML3D), not gym-specific movements. For niche exercises, results may need prompt engineering or a curated skeleton library override. The M3GYM dataset (CVPR 2025) is fitness-specific and could be used to fine-tune later.

#### Stage 2: Keyframe Extraction

- From the generated motion sequence, extract 4-8 keyframes that represent the distinct phases of the exercise
- Keyframe selection based on velocity minima (transition points) and maximum joint displacement
- Each keyframe becomes one illustrated frame in the final animation

#### Stage 3: Pose to OpenPose Skeleton

- Project 3D joint positions to 2D using a fixed camera angle (front or side view, selectable)
- Convert to OpenPose 18-point skeleton format (standard ControlNet input)
- This is deterministic — no AI involved

#### Stage 4: ControlNet Rendering

- **ControlNet OpenPose** conditions the image generation on the exact pose
- **FLUX** (or Stable Diffusion XL) generates the illustrated figure
- **Style LoRA** trained on 15-20 reference images of the target illustration style ensures brand consistency
- **IP-Adapter** anchors character appearance across frames (same body, same outfit, same proportions)
- Denoising strength 0.3-0.5 balances pose accuracy with character consistency

**Infrastructure:** ComfyUI as orchestration layer, hosted on GPU cloud (RunPod, fal.ai, or Replicate)

**Expected performance:** ~5-10 seconds per frame, 4-8 frames per exercise = 20-80 seconds per exercise generation

#### Stage 5: Equipment Compositing (The Key Innovation)

This is where we solve the equipment problem that plagues all pure-AI approaches.

**Principle:** The AI never generates equipment. Equipment is modelled as **vector (SVG) assets** that are programmatically composited onto the rendered figure using joint positions from the skeleton data.

**Equipment asset library** (estimated 15-20 SVG assets to cover majority of exercises):

| Category | Assets | Anchor Points |
|----------|--------|---------------|
| Resistance bands | 3-4 variants (loop, tube, flat) | Stretch between two joint positions (e.g., foot → hand) |
| Dumbbells | 2-3 weights | Attach to hand joint positions |
| Barbells | 1-2 variants | Span between two hand positions |
| Kettlebells | 1-2 variants | Attach to hand joint position(s) |
| Cable handle | 1-2 variants | Attach to hand, line drawn to anchor point |
| Exercise mat | 1 | Floor plane beneath figure |
| Bench | 1-2 variants | Static placement relative to figure |
| Exercise ball | 1-2 sizes | Position relative to body contact point |
| Foam roller | 1 | Position relative to body contact point |

**How it works:**

1. The prompt is parsed (via LLM or keyword extraction) to identify equipment
2. The appropriate SVG asset is selected
3. Joint positions from the skeleton provide anchor coordinates
4. The equipment SVG is transformed (position, rotation, scale, stretch for bands) to connect the anchor points
5. The equipment layer is composited on top of (or behind, depending on depth) the rendered figure
6. For resistance bands: a bezier curve is drawn between anchor joints with band texture applied, simulating realistic stretch

**Advantages:**
- Equipment always looks correct — no AI hallucination of bent dumbbells or phantom bands
- Consistent visual style — SVG assets match the illustration aesthetic
- Physically plausible — bands stretch realistically between joint points
- Cheap to extend — adding a new equipment type is one SVG asset + anchor logic

#### Stage 6: Animation Assembly

- Compiled frames are assembled into the final animation
- **Target format: Lottie (JSON)** — lightweight, scalable, web and mobile native, supports interactivity
- Alternative formats: sprite sheet (PNG sequence), animated WebP, or short MP4
- Lottie preferred because:
  - Tiny file size (~12KB vs MB for video)
  - Vector-based, scales to any screen
  - Supports playback control (pause, step, speed) — critical for the plan player
  - Works offline when cached
  - Same format works in portal preview and future client app

---

## 4. Prompt Engineering Strategy

The trainer's freeform prompt needs to produce reliable motion generation. The system will:

1. **Parse the trainer's prompt** using an LLM to extract:
   - Primary movement (e.g., "hamstring curl")
   - Body position (e.g., "standing")
   - Equipment (e.g., "resistance band")
   - Direction/plane of motion
   
2. **Enhance the prompt** for the text-to-motion model:
   - Add biomechanical context ("flexion at the knee joint, hip stable")
   - Specify timing and range of motion
   - Remove equipment references (motion model generates body only)

3. **Route equipment** to the compositing layer based on extracted equipment type

This prompt enhancement step is an LLM call (Claude API or similar) that sits between the trainer input and the motion generation model.

---

## 5. Quality Assurance

- The **trainer is the quality gate** — they review the generated animation before it enters the catalogue
- If quality is insufficient, the trainer **tweaks their prompt and regenerates**
- The system tracks generation history so trainers can compare iterations
- Common exercises that produce poor AI results can be added to a **curated skeleton override library** — manually defined keyframe sequences that bypass the text-to-motion model

---

## 6. Cost Model

| Component | Cost | Notes |
|-----------|------|-------|
| GPU compute (motion gen + rendering) | ~$0.05-0.15 per exercise | Self-hosted HY-Motion + cloud GPU for ControlNet |
| LLM prompt enhancement | ~$0.01 per exercise | Claude API or similar |
| Equipment SVG assets | One-time design cost | 15-20 assets, commission or design in-house |
| Style LoRA training | One-time (~$5-20 in compute) | Train once on reference illustrations |
| Infrastructure (ComfyUI, storage) | ~$50-200/month | Scales with usage |

**At scale:** Thousands of exercises at $0.05-0.15 each is dramatically cheaper than licensing at $1-2 per exercise or $1,200+ for a fixed library.

---

## 7. Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Text-to-motion produces wrong movement | High for niche exercises | High | Prompt enhancement + curated skeleton override library |
| Character inconsistency across frames | Medium | Medium | Style LoRA + IP-Adapter + low denoising strength |
| Equipment compositing looks unnatural | Medium | Medium | Careful anchor point logic + bezier curves for flexible items |
| Generation too slow for trainer UX | Low-Medium | Medium | Async generation with notification; cache common exercises |
| GPU costs exceed budget at scale | Low | Medium | Self-host HY-Motion; batch generation during off-peak |

---

## 8. Prototype Scope (Phase 0 — Technical Risk Validation)

**Goal:** Validate the pipeline end-to-end with a single exercise before building any product features.

**Prototype deliverable:** Given the text prompt "Standing bicep curl with dumbbell", produce a 4-6 frame 2D illustrated step-by-step animation with the dumbbell composited from an SVG asset.

**Prototype steps:**

1. Set up text-to-motion generation (SayMotion API for speed, or HY-Motion local)
2. Extract keyframes from generated motion
3. Convert to OpenPose skeleton format
4. Render frames via ControlNet + FLUX (can use Replicate API to avoid local GPU setup)
5. Create one dumbbell SVG asset
6. Composite equipment onto rendered frames using joint positions
7. Assemble into a viewable animation (even a simple HTML page with frame stepping)

**Success criteria:**
- [ ] Human figure is anatomically plausible across all frames
- [ ] Character appearance is consistent across frames (same person)
- [ ] Dumbbell is correctly positioned in the hand(s) across all frames
- [ ] The exercise movement is recognizable as a bicep curl
- [ ] Total generation time is under 2 minutes
- [ ] The illustrated style is clean and professional enough for a fitness app

**Timeline estimate:** 3-5 days of focused technical work.

---

## 9. Future Enhancements

- **Fine-tune on fitness data:** Use M3GYM / Fit3D datasets to improve exercise-specific motion generation
- **Correction overlays:** Add visual cues (arrows, joint highlights, "wrong form" indicators)
- **Multiple camera angles:** Generate front and side views for complex exercises
- **Equipment physics simulation:** More realistic band tension, cable weight resistance
- **Style variations:** Allow practices to customize their illustration style via custom LoRA
- **Pre-generation cache:** Pre-generate common exercises so they're instant from the catalogue
