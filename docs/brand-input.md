# homefit.studio — Brand Input Package for claude.ai/design

**Created:** 2026-04-18
**Purpose:** Context for a focused brand-formalization session. Paste this entire document as the starting prompt in claude.ai/design.

---

## What we want from this session

**Formalize what exists, resolve inconsistencies between three surfaces, produce implementable tokens.** This is NOT a ground-up rebrand. Coral + Pulse Mark + dark-first is working — preserve it. The job is to pin down tokens as code so three codebases stop drifting.

**Deliverables (prioritised):**

1. **Tokens as code** — colour palette (brand + neutrals + semantic), typography scale, spacing scale, radii, shadows, motion timing. As hex / px / ms values, not images or swatches.
2. **Component inventory** — buttons, form fields, cards, navigation, modals, toasts, empty/loading/error states. Enough specification to build against, not a full library.
3. **Logo & wordmark system** — Pulse Mark variants (full lockup, mark-only, dark/light), clear-space rules, minimum sizes.
4. **Voice & tone** — one page. Healthcare-professional, warm not clinical, South African English.
5. **Applied examples across three surfaces** — 3-5 key screens per surface.

**Explicitly out of scope:** photography style, marketing-site design, illustration library, brand guidelines PDF deck. Timebox: 1 day.

---

## Product summary

**homefit.studio** is a multi-tenant SaaS platform for biokineticists, physiotherapists, and fitness trainers in South Africa. The trainer captures a client's exercises during a session, converts them on-device into clean black-and-white line-drawing demos, assembles a plan with reps/sets/rest/circuits, and shares a WhatsApp-friendly link with the client.

**Three surfaces (all need a consistent language):**

1. **Flutter mobile app** (iOS-only for MVP) — the trainer's tool. Dark mode. Most time spent here.
2. **Web player** at `session.homefit.studio/p/{planId}` — what the client sees when they open the WhatsApp link. Anonymous, read-only. Dark theme.
3. **Web portal** at `manage.homefit.studio` — where practice owners buy credits, view an audit log, invite practitioners. Dark theme.

**Users:**

- **Trainer / biokineticist** — South African healthcare professional. Runs their own practice or is on staff at one. Tech-comfortable but not a power user. Wants to look modern and professional to their clients, not clinical.
- **Client (patient)** — ranges from post-op rehab to general fitness. Often on a mid-range Android in suburban South Africa. Opens the WhatsApp link on their phone, does the exercises at home.
- **Melissa (the first real bio besides Carl)** — a high-influence biokineticist with a large SA professional network. Her endorsement is the growth multiplier. Her clients must see something polished, not MVP-rough.

**Core context that shapes the brand:**

- **South African healthcare professional market.** WhatsApp is the dominant communication channel (90% of SA healthcare workers use it for work). Apple / Stripe / Luma-Labs pricing doesn't apply here — the market is pound-sensitive but visually sophisticated.
- **POPIA compliance** (South Africa's GDPR equivalent). Line drawings naturally de-identify clients — privacy is baked into the visual pipeline.
- **Lead generation via peer endorsement**, not paid acquisition. Every bio is a potential multiplier. The product has to feel good enough to recommend unprompted.

---

## Canonical brand foundation (preserve)

### Name

**homefit.studio** — always lowercase. Never "HomeFit Studio" or "Homefit". The `.studio` is part of the identity.

### Logo — Pulse Mark

A heartbeat / ECG line that traces a house roof silhouette. Flat, up-45°, peak, down-45°, flat. Like an ECG pulse monitor but the peak is a rooftop.

**Canonical SVG path** (viewBox `0 0 52 36`):

```svg
<svg viewBox="0 0 52 36" xmlns="http://www.w3.org/2000/svg">
  <path d="M2.6 25.2 L13 25.2 L18.2 7.2 L26 28.8 L33.8 7.2 L39 25.2 L49.4 25.2"
        fill="none" stroke="currentColor" stroke-width="2.5"
        stroke-linecap="round" stroke-linejoin="round"/>
</svg>
```

**Why it works:** the ECG reference ties us to health. The house roof ties us to "home" fitness. Single stroke, no fill — works at any size, any background.

**Animated variant:** pulses on loading screens. See `web-player/styles.css` `.pulse-mark` class (CSS keyframes).

**What we need from the design session:**

- Wordmark lockups (Pulse Mark + "homefit.studio" wordmark in approved combinations).
- Mark-only variant sizing rules.
- Clear-space rules (minimum padding around logo).
- Minimum size (both pixel and physical).
- Light-background variant (currently only dark-background is defined).

### Mode

**Dark-first, always.** Both trainer app and client web player default to dark. No light-mode toggle. The Flutter light theme exists in `theme.dart` but is effectively dead code (ships unused). Design session should either formalise a light variant or explicitly kill the option.

### Voice

Bold, energetic, professional. Not clinical. Not fitness-bro. Premium workout feel, respectful of the therapeutic context. South African English (not American — use "colour" not "color" in UX copy, "exercise" not "workout").

**Language we use:**
- "Exercise" (not "workout", not "movement")
- "Plan" (not "program", not "routine")
- "Credits" (not "tokens", not "points")
- "Trainer / practitioner / bio" (not "coach", not "user")
- "Client / patient" (audience-dependent)
- "Capture" and "Studio" (the two modes of the Flutter app)

**Pitch language (validated by market research):**
- Lead with adherence improvement (38% → 77% with visual instructions)
- Emphasise "correct execution" and "time saved"
- DON'T claim improved clinical outcomes directly (evidence still developing, regulated territory)

---

## Current token inventory — three surfaces, side by side

**This is where the formalization work is.** Each surface has tokens that are _mostly_ aligned but with drift. The session should produce a single canonical token list, then we translate back into each codebase.

### Brand colours

| Token | Flutter (`AppColors`) | Web player (`:root`) | Web portal (Tailwind) |
|-------|----------------------|----------------------|----------------------|
| Primary | `primary = #FF6B35` | `--color-primary: #FF6B35` | `brand.DEFAULT: #FF6B35` |
| Primary Dark | `primaryDark = #E85A24` | `--color-primary-dark: #E85A24` | `brand.dark: #E85A24` |
| Primary Light | `primaryLight = #FF8F5E` | `--color-primary-light: #FF8F5E` | `brand.light: #FF8F5E` |
| Primary Surface | `primarySurface = #FFF3ED` | `--color-primary-surface: #FFF3ED` | `brand.surface: #FFF3ED` |
| Primary tint bg | (derived via `withValues(alpha: 0.12)`) | `--color-primary-tint-bg: rgba(255,107,53,0.12)` | (missing) |
| Primary tint border | (not defined) | `--color-primary-tint-border: rgba(255,107,53,0.30)` | (missing) |

### Dark-surface neutrals

| Concept | Flutter | Web player | Web portal |
|---------|---------|------------|------------|
| Background | `darkBg = #0F1117` | `--color-dark-bg: #0F1117` | `surface.bg: #0F1117` |
| Surface | `darkSurface = #1A1D27` | `--color-dark-surface: #1A1D27` | `surface.base: #1A1D27` ← name drift |
| Surface variant | `darkSurfaceVariant = #242733` | `--color-dark-surface-variant: #242733` | `surface.raised: #242733` ← name drift |
| Border | `darkBorder = #2E3140` | `--color-dark-border: #2E3140` | `surface.border: #2E3140` |

**Drift flagged:** web portal calls it `surface.base` and `surface.raised` while the other two call it `darkSurface` and `darkSurfaceVariant`. One naming wins.

### Text on dark

| Concept | Flutter | Web player | Web portal |
|---------|---------|------------|------------|
| Primary | `textOnDark = #F0F0F5` | `--color-text: #F0F0F5` | `ink.DEFAULT: #F0F0F5` |
| Secondary | `textSecondaryOnDark = #9CA3AF` | `--color-text-secondary: #6B7280` ← drift | `ink.muted: #9CA3AF` |
| Muted | (not defined) | `--color-text-muted: #4B5563` | `ink.dim: #6B7280` ← drift |

**Drift flagged:** web player's "secondary" is `#6B7280`, but Flutter + web portal use `#9CA3AF`. Two different greys calling themselves "secondary text on dark". Need to reconcile.

### Semantic

| Concept | Flutter | Web player | Web portal |
|---------|---------|------------|------------|
| Success | `success = #22C55E` | `--color-success: #22C55E` | `ok: #22C55E` ← name drift |
| Warning | `warning = #F59E0B` | `--color-warning: #F59E0B` | `warn: #F59E0B` ← name drift |
| Error | `error = #EF4444` | `--color-error: #EF4444` | `err: #EF4444` ← name drift |
| Rest | `rest = #64748B` | `--color-rest: #64748B` | `rest: #64748B` |

**Drift flagged:** web portal uses abbreviated names (`ok`/`warn`/`err`). Align on full names.

### Radii

All three agree:

- `sm: 8px` / `md: 12px` / `lg: 16px` / `xl: 20px`

### Shadows

| Concept | Flutter | Web player | Web portal |
|---------|---------|------------|------------|
| Card | (unused — elevation=0) | `--shadow-card: 0 1px 3px rgba(0,0,0,0.35), 0 4px 12px rgba(0,0,0,0.25)` | `shadow-card: same as web player` |
| Card hover | (N/A on mobile) | `--shadow-card-hover: 0 2px 8px rgba(0,0,0,0.45), 0 8px 24px rgba(0,0,0,0.35)` | (missing) |
| Brand glow | (not used) | `--shadow-glow-primary: 0 4px 16px rgba(255,107,53,0.35)` | `shadow-brand-glow: same` |

**Drift flagged:** Flutter uses no shadows anywhere (elevation=0 on cards). Web surfaces use them. Design session should decide: are shadows a brand element or noise?

### Motion / transitions

| Concept | Flutter | Web player | Web portal |
|---------|---------|------------|------------|
| Fast | (per-component) | `--transition-fast: 150ms ease` | (missing) |
| Normal | (per-component) | `--transition-normal: 250ms ease` | (missing) |
| Slow | (per-component) | `--transition-slow: 400ms cubic-bezier(0.16, 1, 0.3, 1)` | (missing) |

**Drift flagged:** only web-player has motion tokens. Flutter uses Material defaults. Web portal uses Tailwind defaults. Three different motion feels.

### Typography scale (Flutter)

```
displayLarge   Montserrat  57px  w800  letter-spacing -1.5
displayMedium  Montserrat  45px  w700  -0.5
displaySmall   Montserrat  36px  w700  -0.3
headlineLarge  Montserrat  32px  w700  -0.5
headlineMedium Montserrat  28px  w700  -0.3
headlineSmall  Montserrat  24px  w600  -0.2
titleLarge     Montserrat  20px  w700  -0.3
titleMedium    Inter       16px  w600
titleSmall     Inter       14px  w600
bodyLarge      Inter       16px  w400  line-height 1.5
bodyMedium     Inter       14px  w400  line-height 1.5
bodySmall      Inter       12px  w400  line-height 1.5
labelLarge     Inter       14px  w600  letter-spacing 0.1
labelMedium    Inter       12px  w600  letter-spacing 0.5
labelSmall     Inter       11px  w600  letter-spacing 0.5
```

**Drift flagged:** web player and web portal have no explicit typography scale — they use inline styles + Tailwind defaults. Should inherit Flutter's scale verbatim.

### Spacing scale

**Not formally defined anywhere.** De-facto usage in Flutter is 4/8/12/16/20/24/32/40 based on grepping. Design session should pick a canonical scale (likely 4/8/12/16/24/32/48/64) and we apply it everywhere.

### Component states

**Not formally defined anywhere.** No canonical empty / loading / error states. Every screen invents its own. This is the biggest gap.

**Needed:**
- Empty state (no data yet, no content, first-run)
- Loading state (initial fetch, in-flight action, skeleton vs spinner)
- Error state (network, validation, auth)
- Success state (confirmation, completion)
- Disabled state (insufficient permissions, insufficient credits, read-only)

---

## Constraints the design session must respect

1. **Two-week MVP.** Output has to translate to code in 1-2 days. Beautiful Figma decks that don't map to tokens are low-value.
2. **Preserve coral `#FF6B35` as the single accent.** No new brand colours. Don't reintroduce teal (previously used, removed). Rest blue-grey `#64748B` is a distinct category, not an accent.
3. **Preserve Pulse Mark.** Don't redesign the logo.
4. **Dark-first stays.** Either formalise a light variant or explicitly kill the Flutter light theme (currently dead code).
5. **Montserrat + Inter stays.** Both on Google Fonts. No new typefaces.
6. **No licensed libraries for animations.** All motion has to be CSS / Flutter-native. No Lottie paid assets.
7. **POPIA-friendly visuals.** Line-drawing conversion naturally de-identifies clients. Don't break that advantage with photography of real people on marketing surfaces — abstract + line-art wins.

---

## Known inconsistencies (hit list — session should resolve all)

Organised from biggest impact to smallest:

1. **Two different "secondary text on dark" greys.** `#6B7280` (web player) vs `#9CA3AF` (Flutter + portal). Pick one.
2. **Dark-surface naming drift.** `darkSurface`/`darkSurfaceVariant` vs `surface.base`/`surface.raised`. Pick one naming.
3. **Semantic-colour naming drift.** `success/warning/error` vs `ok/warn/err`. Pick one (recommend full names for explicitness).
4. **No canonical motion tokens.** Only web player has them. Need fast/normal/slow timings that work on all three surfaces.
5. **No canonical spacing scale.** Three surfaces use ad-hoc spacing. Pick 4/8/12/16/24/32/48/64 or similar.
6. **No canonical empty/loading/error states.** Every screen invents its own. Specify one of each.
7. **Shadow usage inconsistent.** Flutter uses zero shadows; web uses them. Decide: brand element or noise?
8. **Dead light theme in Flutter.** Decide: formalise or delete.
9. **Typography scale not mirrored in web.** Web surfaces use inline sizes. Mirror Flutter's scale.
10. **Tint / alpha-overlay tokens only in web player.** Flutter computes them via `withValues(alpha: …)`; portal doesn't use them at all. Define canonical tints and mirror.

---

## Suggested components to specify

Minimum viable component inventory for the session to produce. One spec per component covering: default / hover / focus / active / disabled / error states + size variants.

**Input:**
- Button (primary / secondary / tertiary / destructive) × (sm / md / lg) × states
- Text input (default / filled / outlined)
- Select / dropdown
- Checkbox / radio / toggle

**Display:**
- Card (raised / outlined / ghost)
- Chip / badge / pill
- Avatar / icon button
- Progress bar / spinner / skeleton

**Navigation:**
- Top nav (web portal)
- Tab bar / bottom nav (Flutter)
- Breadcrumb

**Feedback:**
- Toast / snackbar
- Modal / dialog / sheet
- Empty state
- Loading state
- Error state
- Success state

**Brand-specific:**
- Exercise card (photo + reps/sets/hold/rest)
- Circuit header
- Rest card
- Timer chip (three-state: prep / running / paused)
- Credit balance chip
- Share preview card (WhatsApp OG)

---

## Screenshots to include (Carl to capture before session)

Attach these when starting the claude.ai/design session so it can critique against real state, not abstract.

**Flutter app — dark mode only:**

- Sign-in screen
- Home screen (session list, with at least 2 sessions visible)
- Session shell — Studio mode with 3-4 exercises including one circuit and one rest period, one card expanded
- Session shell — Capture mode (camera active)
- Workout preview slideshow mid-exercise (video playing, timer chip visible)
- Rest-period slide in preview
- Empty state (Home screen with zero sessions)

**Web player (session.homefit.studio):**

- A live published plan — first card
- Circuit round-2-of-3 card
- Rest slide with timer chip
- Loading state (hard refresh)
- Error state (visit an invalid plan URL — "Plan not found")
- WhatsApp preview (screenshot of actual WhatsApp chat showing the link unfurl)

**Web portal (manage.homefit.studio):**

- Sign-in page
- Dashboard (signed in, with some credit balance visible)
- `/credits` bundle list
- `/audit` page (with or without rows)
- `/members` page
- `/credits/return` success state

---

## Output format we want back

Ideally the claude.ai/design session ends with:

1. **`tokens.json`** — a single JSON file with all colour / typography / spacing / radius / shadow / motion tokens. Structure:
   ```json
   {
     "color": {
       "brand": { "default": "#FF6B35", "dark": "#E85A24", "light": "#FF8F5E", "surface": "#FFF3ED" },
       "surface": { "dark.bg": "#0F1117", ... },
       "ink": { "primary": "#F0F0F5", ... },
       "semantic": { "success": "#22C55E", ... }
     },
     "typography": { "heading.display.lg": { "family": "Montserrat", "size": 57, "weight": 800, "letter-spacing": -1.5 }, ... },
     "spacing": { "0": 0, "1": 4, "2": 8, "3": 12, "4": 16, ... },
     "radius": { "sm": 8, "md": 12, "lg": 16, "xl": 20 },
     "shadow": { "card": "...", "brand-glow": "..." },
     "motion": { "fast": "150ms ease", "normal": "250ms ease", "slow": "400ms cubic-bezier(...)" }
   }
   ```

2. **`components.md`** — one section per component with states + size variants, referencing tokens by name (not raw hex).

3. **Pulse Mark asset pack** — SVG variants (full lockup / mark-only / horizontal / stacked / dark / light) as individual `.svg` files.

4. **Voice guide** — one page. Do / don't word list. Tone examples for onboarding, error messages, CTAs.

5. **Applied examples** — screenshots or PNG mockups of the key screens listed above, with the new token system applied.

We'll translate that into `app/lib/theme.dart`, `web-player/styles.css`, and `web-portal/tailwind.config.ts` as one commit.

---

## End of input package.
