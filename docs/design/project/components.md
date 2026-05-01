# homefit.studio — Component Inventory

All tokens referenced by name (see `tokens.json`). Dark-mode specs; light mirrors via `surface.light.*` / `ink.light.*`.

---

## Button

**Variants:** `primary` · `secondary` · `tertiary` · `destructive`
**Sizes:** `sm` (h=32) · `md` (h=40) · `lg` (h=48)
**Radius:** `radius.md` (all sizes)
**Typography:** `label.lg` (md/lg), `label.md` (sm)

### Primary
- Fill: `color.brand.default`
- Text: `color.ink.on-brand`
- Hover: fill `color.brand.light`
- Pressed: fill `color.brand.dark`
- Focus: `shadow.focus-ring`
- Disabled: fill `color.surface.dark.raised`, text `color.ink.dark.disabled`, no pointer

### Secondary
- Fill: transparent
- Border: 1px `color.surface.dark.border`
- Text: `color.ink.dark.primary`
- Hover: border `color.brand.default`, text `color.brand.default`
- Pressed: fill `color.brand.tint-bg`

### Tertiary (ghost)
- Fill: transparent, no border
- Text: `color.brand.default`
- Hover: fill `color.brand.tint-bg`

### Destructive
- Fill: `color.semantic.error`
- Text: `color.ink.on-brand`
- Hover: fill darkens 10%

**Padding:** `sm` → 0 `spacing.3`; `md` → 0 `spacing.4`; `lg` → 0 `spacing.5`.
**Icon+label gap:** `spacing.2`.

---

## Text Input

**Height:** 40 (`md`) · 48 (`lg`).
**Radius:** `radius.md`.
**Typography:** `body.md`.

- Fill: `color.surface.dark.base`
- Border: 1px `color.surface.dark.border`
- Text: `color.ink.dark.primary`
- Placeholder: `color.ink.dark.muted`
- Label (above): `label.md`, colour `color.ink.dark.secondary`
- Helper (below): `body.sm`, colour `color.ink.dark.muted`

**States:**
- Hover: border `color.ink.dark.muted`
- Focus: border `color.brand.default` + `shadow.focus-ring`
- Error: border `color.semantic.error`; helper colour `color.semantic.error`
- Disabled: fill `color.surface.dark.bg`, text `color.ink.dark.disabled`

---

## Card

Flat posture — no shadow. Separation via border.

**Variants:**
- `raised` — fill `surface.dark.raised`, border `surface.dark.border`
- `outlined` — fill transparent, border `surface.dark.border`
- `ghost` — fill `surface.dark.base`, no border

**Radius:** `radius.lg`. **Padding:** `spacing.5`. **Gap between cards:** `spacing.3`.
**Hover (interactive):** border `brand.default`, cursor pointer.

---

## Chip / Badge / Pill

**Height:** 24 (`sm`) · 28 (`md`).
**Radius:** `radius.full`.
**Padding:** 0 `spacing.3`.
**Typography:** `label.md`.

**Tone variants:**
- `neutral` — fill `surface.dark.raised`, text `ink.dark.secondary`
- `brand` — fill `brand.tint-bg`, border `brand.tint-border`, text `brand.light`
- `success/warning/error` — fill `semantic.* @ 12%`, text `semantic.*`
- `rest` — fill `semantic.rest @ 15%`, text `semantic.rest`

---

## Timer Chip (brand-specific, 3-state)

Pill, `radius.full`, height 32, padding 0 `spacing.4`. Monospace numerals.

- **Prep:** fill `brand.tint-bg`, border `brand.tint-border`, text `brand.light`, countdown colon-blink 1s linear infinite
- **Running:** fill `brand.default`, text `ink.on-brand`, no border. Embedded progress ring (2px stroke) around the left icon.
- **Paused:** fill `surface.dark.raised`, border `surface.dark.border`, text `ink.dark.secondary`

Transitions between states use `motion.normal` + `motion.emphasized`.

---

## Exercise Card (brand-specific)

### Header (collapsed)

- `card.raised` base, `radius.lg`, padding `spacing.3`
- **Thumbnail:** 56×56, `radius.md`, fill `surface.dark.bg` (placeholder for line-drawing). Larger than other card imagery — the thumbnail is the primary scanning cue in Studio.
- **Title:** `title.md`, `ink.dark.primary`. Editable via long-tap-on-title (inline edit mode with dashed underline).
- **Settings summary:** `label.md`, `ink.dark.secondary`, uppercase. Always shows values regardless of customisation state (e.g. `3 × 10 · rest 30s`). Default values ARE displayed — they treat the practitioner as an expert-adjuster, not a form-filler.
- **Customised dot:** 4px coral dot (`brand.default`), positioned bottom-right inside the card border, visible only when the practitioner has adjusted any setting away from defaults. Zero-chrome indicator — scannable down the list.

### Header rules (STRICT)

- **No chevron** — the card is the tap target.
- **No toggles, no buttons, no switches** in the header. They move to the expanded panel.
- **Card-row gestures:**
  - Tap (anywhere except thumbnail) → expand / collapse
  - Long-press (anywhere except thumbnail) → drag-to-reorder along the gutter rail
- **Thumbnail is its own gesture zone:**
  - Tap → full-screen media viewer
  - Long-press → Thumbnail Peek (see separate component below)
- Haptics: `selectionClick()` on expand/collapse, `mediumImpact()` on long-press triggers (drag OR peek).

### Expanded panel

Appears below the header with a 1px `surface.dark.border` separator:

- **Three vertical sliders** (reps, sets, hold) — each is `Column(label-row, slider full-width)`. Label-row shows uppercase `label.md` name left, monospace numeric value right.
- **Custom-duration toggle** — "Use video length as 1 rep · {Ns}" + switch. Surfaces only when the exercise has a video with a non-null `videoDurationMs`.
- **Audio-on-share toggle** — "Include audio on share" + switch. Surfaces only when the exercise has a video.
- **Notes sub-section** — tap-to-expand row that reveals a `body.md` text editor.
- Inter-element gap: `spacing.3`. Panel padding: `spacing.4`.

---

## Thumbnail Peek (brand-specific)

Long-press on an exercise-card thumbnail. Implemented as an iOS-style context menu (Flutter: `CupertinoContextMenu` or equivalent).

- **Preview:** the thumbnail zooms into a ~240×240 floating card centred on screen. If the media is a video, it auto-plays muted + looping. If it's a photo, shown at natural aspect ratio.
- **Action sheet** (below the preview):
  - `Open full-screen` (primary, `brand.default` text)
  - `Replace media`
  - `Delete exercise` (destructive, `semantic.error` text) — fires immediately on tap, no confirmation. Soft-deletes to the 7-day recycle bin. Toast "Exercise deleted · Undo" for 5s provides the reversal.
- Release to keep peek open; tap outside or pick an action to dismiss.
- Enter animation: `motion.normal` + `motion.emphasized`, scale 0.92 → 1.
- Haptic: `mediumImpact()` on open.

---

## Circuit Header

Sits above grouped exercise cards. The circuit header is also the **circuit's control surface** — tap to open the control sheet.

- Height: 32
- **Left:** `Circuit {letter}` label — `label.lg` uppercase, `brand.default`, letter-spacing 0.5
- **Right:** cycles chip — `×{N}` in `brand.tint-bg` / `brand.tint-border`, `label.md` monospace
- **Bottom border:** 2px `brand.tint-border`
- **Tap anywhere on the header** → opens the Circuit Control **bottom sheet** (never a modal):
  - Circuit name (editable, default `Circuit A` etc.)
  - Cycles stepper (`−` / `+`, min 1, max 10)
  - `Break circuit` — fires immediately on tap, no confirmation. Dismissal toast "Circuit broken · Undo" (5s) re-groups the cards if tapped.
- Round indicator: `Round {n} of {N}` — `label.md`, `ink.dark.secondary`. Only surfaces on applied screens (slideshow / Workout preview), not in the Studio header.

---

## Rest Card

- `card.outlined`, border `semantic.rest @ 30%`
- Icon: pause glyph, `semantic.rest`
- Duration: `headline.sm`, `semantic.rest`
- Label "Rest" + total time: `label.lg`, `ink.dark.secondary`

---

## Credit Balance Chip (web portal)

Top-right of every screen.

- Height 32, `radius.full`, padding 0 `spacing.4`
- Fill: `surface.dark.raised`, border `surface.dark.border`
- Monospace number (JetBrains Mono, 14px, w600), space, "credits" in `label.md` `ink.dark.secondary`
- **Low state** (< 10 credits): border `semantic.warning`, number in `semantic.warning`
- **Zero state**: border `semantic.error`, number in `semantic.error`

---

## Toast / Snackbar

- Bottom-center, margin `spacing.6`
- Fill: `surface.dark.raised`, border `surface.dark.border`, radius `md`, padding `spacing.4`
- Enter: `motion.slow` + `motion.emphasized`, translate-y +12 → 0, opacity 0 → 1
- Auto-dismiss: 4s (info) · 6s (error)
- Tone bar: 3px left-edge fill, colour = semantic tone

---

## Modal / Dialog

- Overlay: `surface.dark.bg @ 70%`, `z.overlay`
- Sheet: `surface.dark.raised`, border `surface.dark.border`, radius `xl`, max-width 520px
- Header: `title.lg`, padding `spacing.5`
- Body: `body.lg`, padding 0 `spacing.5`
- Footer: flex-end, gap `spacing.3`, padding `spacing.5`
- Enter: `motion.normal` + `motion.emphasized`, scale 0.98 → 1

---

## Empty State

Canonical structure, used everywhere there's no data.

- Centered column, max-width 360, vertical rhythm `spacing.4`
- Icon glyph: 48×48, `ink.dark.muted`
- Title: `title.lg`, `ink.dark.primary`
- Body: `body.md`, `ink.dark.secondary`
- CTA: primary button, `md`

**Voice rule:** never apologise ("Sorry, nothing here yet"). State the fact, offer the next action.

---

## Loading State

- **Skeleton** for lists & cards: fill `surface.dark.raised`, animated linear gradient sweep left→right, 1.4s linear infinite. Use for any view that maps 1:1 to a data shape.
- **Matrix-mark spinner** for full-page / initial fetch: 48–96px mark using canonical v2 matrix geometry (the same 11-pill body rendered by `docs/design/project/logos/mark.svg` and by the inline `HomefitLogo` widget/component in each codebase). Animation: the three outer ghost greys on each side breathe inward via an opacity fade, staggered at 0 / 0.1s / 0.2s with `keyTimes = [0, 0.5, 1.0]` and easing `cubic-bezier(0.4, 0, 0.6, 1)`; the four coral middle pills and the coral tint band hold **static**; the single sage rest pill pulses opacity + a slight `scaleY(1→1.1→1)` on the same cycle. Period: `motion.loop` (1.4s = 43bpm — slow, calm). The matrix mark **never animates outside loading contexts** — static is the default on every non-loading surface. Baked SMIL reference at `docs/design/project/logos/mark-session.svg`; port-ready motion lab at `docs/design/mockups/matrix-session-motion.html`.
- **Inline spinner** for in-flight buttons: 16px circle, 2px stroke, `motion.normal` rotate.

Rule: pick by expected duration. < 300ms → nothing. 300ms–2s → inline. > 2s → skeleton or matrix-mark.

**Reduced motion:** when the OS / browser signals `prefers-reduced-motion: reduce` (web) or `MediaQuery.disableAnimations == true` (Flutter), render the static matrix mark — no breathing, no sage pulse.

---

## Error State

- Same structure as Empty State
- Icon: alert glyph, `semantic.error`
- Title: `title.lg`, `ink.dark.primary`
- Body: `body.md`, `ink.dark.secondary` — what failed, what they can do
- Primary CTA: "Try again" or "Reload"
- Secondary CTA (tertiary button): "Contact support"

---

## Success State

Inline, not a screen. Toast or dialog.
- Icon: check, `semantic.success`
- Message: `body.md`, `ink.dark.primary`

---

## Disabled State

Opacity 0.5 is banned — too ambiguous. Use explicit tokens:
- Fill: `surface.dark.raised`
- Text: `ink.dark.disabled`
- Border (if any): `surface.dark.border`
- Cursor: `not-allowed`
- When disabled because of credits / permissions, **always** show helper text below explaining why.

---

## Focus Ring

Single spec across all interactive elements.
- `outline: none`
- `box-shadow: shadow.focus-ring` (3px coral ring @ 30%)
- Applied on `:focus-visible`, not `:focus`.

---

## Bottom Nav (Flutter) / Top Nav (Web portal)

**Bottom nav:** 64h, fill `surface.dark.base`, top border `surface.dark.border`. 3 tabs (Home, Capture, Studio). Active: `brand.default` icon + label. Inactive: `ink.dark.muted`.

**Top nav (portal):** 56h, fill `surface.dark.base`, bottom border `surface.dark.border`. Left: wordmark lockup. Right: credit chip + avatar.

---

## Share Preview Card (WhatsApp OG)

1200×630 PNG server-rendered.
- Background: `surface.dark.bg`
- Matrix-mark horizontal lockup (`logos/lockup-horizontal.svg`, v2 geometry), top-left, 48h
- Plan title: `display.md`, `ink.dark.primary`, left-aligned
- Trainer name + practice: `title.md`, `ink.dark.secondary`
- Exercise count pill: `chip.brand`
- Right 40% of canvas: 3 line-drawing previews in a tilted stack (15° rotation each)

---

## What every component spec must include

1. Default + hover + focus + active + disabled + error (when applicable)
2. Size variants if any
3. Tokens by name — never raw hex in component spec
4. Interactive a11y: focus-visible ring, min hit target 44×44 on mobile
5. Motion token used for state transition

---

## Gutter Rail (brand-specific, Studio screen)

Vertical rail on the left edge of the Studio exercise list. Holds the insertion affordances + numbered position cues + (when active) drag-reorder handles. Keeps the card stream clean of action chrome so the practitioner can scan the flow unobstructed.

### Dimensions

- **Visible width:** 36px (card column shifts right by this amount)
- **Hit-target width:** 44px (extends invisibly rightward into the card margin — meets iOS HIG 44×44 minimum)
- **Dot glyph:** 6px circle, centred vertically in each inter-card gap and centred horizontally in the gutter

### Positions

Every exercise card has ONE gutter cell aligned with its vertical centre (for position-number display and long-press-to-drag handle) plus ONE gutter cell between itself and the next card (for insertion).

```
gutter   card column
┌──┬──────────────────────┐
│ 1│  [thumb] Goblet squat│   ← card gutter cell (number glyph)
│ ·│                      │   ← gap gutter cell (insertion dot)
│ 2│  [thumb] Bent-over   │
│ ·│                      │
│ 3│  [thumb] Forearm     │
└──┴──────────────────────┘
```

### Dot states

- **Idle** — 6px `ink.dark.muted` @ 30% opacity. Visible but quiet. Ambient signal of "tap me to insert."
- **Focused** (adjacent card focused via hover or recent interaction) — 60% opacity.
- **Active** (tapped) — 10px `brand.default` with a 4px halo of `brand.tint-bg`. Only one active at a time.
- Transitions: `motion.fast` + `motion.standard`.

### Position number

- **Glyph:** `label.sm` monospace numeral (JetBrains Mono, 9px, w600), `ink.dark.muted` @ 60%.
- Rendered in the card gutter cell, centred with the card's vertical midpoint.
- Sequence counts exercises only; rest cards and circuit headers do NOT increment the counter.
- Use: voice coaching ("today we're doing seven exercises; let's start with number one…"), client reference ("I'm stuck on number 4 — message {TrainerName}").
- Hidden when drag-reorder is active (the handle replaces the number).

### Circuit rail

When two or more adjacent cards share a `circuitId`, the gutter between them (and over them) renders a continuous 3px `brand.default` vertical rail at 85% opacity instead of individual dots.

- **Starts:** top edge of the first card in the circuit (top cap, 3px radius).
- **Ends:** bottom edge of the last card in the circuit (bottom cap, 3px radius).
- **Dots hidden** along the rail — the rail carries the signal.
- **Numbered position glyphs** remain visible overlaid on the rail in `ink.on-brand` (white).
- Reads instantly as "these cards repeat together."

### Long-press-to-drag

Long-press on a card (anywhere except the thumbnail) → reorder mode engages:

- Card's position-number in the gutter → replaced with a drag-handle glyph (`≡`, `ink.dark.secondary`).
- All other gutter content dims to 30% opacity.
- User drags up/down along the gutter. Release reorders.
- Haptic: `mediumImpact()` on engage, `selectionClick()` on drop.
- Cancel: drag back to start position + release, or tap elsewhere.

---

## Inline Action Tray (brand-specific, Studio screen)

The insertion menu that appears when a gutter dot becomes active. Lives inline in the card column, not as a floating overlay.

### Structure

- Container: `surface.dark.base`, border 1px `brand.default`, `radius.md`, padding `spacing.3`.
- Inline at the gap position — the card stack opens a ~44px gap around the active dot to accommodate it.
- Reveal animation: height 0 → 44px, `motion.normal` + `motion.emphasized`. Card above slides up a hair, card below slides down.

### Actions (in order)

1. `+ Rest here` — primary; fill `brand.default`, text `ink.on-brand`. Most common between-card action mid-session.
2. `⛓ Link into circuit` — secondary; `chip.neutral` style. Only enabled when a card exists above AND below this gap that aren't already in the same circuit.
3. `+ Exercise here` — secondary; `chip.neutral`. Opens the media import sheet with the insertion position pre-selected.
4. `×` close — tertiary, right-aligned, `ink.dark.muted`. Also dismisses on tap anywhere outside the tray.

### Contextual adaptation

- If the position is inside an existing circuit, `Link into circuit` is hidden.
- If the position is adjacent to a rest bar, `Rest here` is hidden (no double rests).
- If the position is at the very top or very bottom of the list (not between two cards), `Link` is hidden.

### Haptic

`selectionClick()` on tray open, `mediumImpact()` on any action fired.

---

## Studio Screen (assembly)

Ties the above components together. Dark-first. Flutter `CustomScrollView` with `reverse: true` — newest at bottom for one-handed reach.

### Layout (top-to-bottom)

1. **App bar** (56h):
   - Session name, `title.lg`, `ink.dark.primary`. Editable via long-tap-on-title (inline edit).
   - Right: import icon (multi-select photos/videos), overflow menu (recycle bin, share, publish, rename, duplicate).
   - **No other actions in the app bar.** Everything else lives in the gutter rail or per-card.
2. **Summary chip row** (28h, padding `spacing.3`):
   - `{N} exercises` — `chip.neutral`
   - `~{M} min` — `chip.neutral` (estimated duration — sums per-exercise expected times)
   - **Publish-lock badge** — dynamic; see below.
3. **List body** (fills available space above pull-tab and footer):
   - Left gutter (36px visible, 44px hit). Card column fills the rest.
   - Circuit headers, exercise cards, rest bars interleave as content dictates.
   - Bottom-anchored via `reverse: true` — the newest captured/imported exercise appears at the bottom edge.
4. **Pull-tab** — right-edge vertical coral tab (22w × 72h, `radius` top-left/bottom-left `radius.md`). Swipes the Session Shell left to reveal Capture mode.
5. **Footer** (48h, `surface.dark.base`, top-border `surface.dark.border`):
   - "powered by homefit.studio" with matrix-mark (horizontal lockup, v2 geometry).

### Publish-lock badge

Sits at the end of the summary chip row.

- **Open edit window** (published < 24h ago AND client has not opened the link):
  - Pill, `chip.neutral` style, `label.md`.
  - Text: `Edits open · {hoursRemaining}h left` (counts down from 24).
  - On reaching `<1h`: border switches to `semantic.warning` tone, same shape.
- **Locked** (24h elapsed OR client opened the link):
  - Pill, tone = `neutral`, lock glyph prefix.
  - Text: `Edit-only · new structure costs 1 credit`
  - Affordances that cost a new credit (gutter dots for new exercises, drag-reorder, delete exercise, break circuit) become dimmed. Tapping them surfaces an inline tooltip "This counts as a new version · 1 credit".

### Defaults and customisation

Each new exercise card is seeded with settings per the following priority (fallback order):

1. **Client-specific history** (if available) — for this `clientName`, the last values used for an exercise of the same type. _MVP-deferred: this path requires a history lookup that isn't in the schema yet; ship (3) for MVP, add (1) in a follow-up._
2. **Practitioner's last-used values** — the values they last set across any client. _MVP-deferred — same reason._
3. **Global defaults** (MVP baseline): reps `10`, sets `3`, hold `0s`, rest `30s`.

Regardless of seed source, the **customised dot** appears the moment ANY setting deviates from the seed (including notes written, audio toggled, custom-duration overridden) — so the practitioner can scan which cards they've curated vs. which are cruising on auto-seed.

### No modal confirmations — ever

All destructive actions (delete exercise, break circuit, remove rest, undo a circuit) fire **immediately** with no confirmation dialog. Reversal is provided by:

- **7-day recycle bin** for deleted exercises, accessible from the app bar's overflow menu
- **Toast with `Undo`** for 5s after any destructive action (circuit break, rest removal, drag-to-detach, etc.)
- **Gutter re-link** for accidentally broken circuits (long-press-drag an orphaned card back onto the circuit rail)

This is a hard brand rule, see Design Rules below.

---

## Design Rules (brand-wide, referenced from every component)

These rules bind every Flutter screen, every CSS surface, every Tailwind component.

### R-01 · No modal confirmations for destructive actions

Destructive actions fire immediately. Reversal lives in a 5-second toast + a 7-day soft-delete recycle bin. Modals are reserved for informational one-time dialogs (e.g. a first-run welcome card), never for "Are you sure?" — the correct answer to that question is "yes, it's my action, and I can undo it."

### R-02 · Header purity

Any list-item card header (exercise card, session card, rest card, etc.) has only three interactive gestures:

- Tap → expand / collapse OR open the item
- Long-press → drag-to-reorder OR context-menu (pick one per surface, never both)
- Separate sub-regions with their own gesture semantics are permitted only if they're visually distinct (e.g. an image thumbnail).

**Banned in headers:** toggle switches, secondary buttons, action menus, chevrons, any tap target that competes with the primary expand/long-press gestures.

### R-03 · Gesture zones over mode switches

Prefer per-region gestures (tap-anywhere-on-card, long-press-on-thumbnail) over global mode switches (e.g. a "Read/Edit" toggle). Practitioners navigate via muscle memory; mode switches add friction and invite "why isn't this working?" moments.

### R-04 · Defaults are starting points, not empty states

Lists of editable items (exercises, sessions, rest durations) are always seeded with sensible defaults. Never show "Set reps" or "Add notes" as a placeholder — show the default value (`3 × 10`) and let the practitioner react. Empty-state copy is reserved for **list-level** absence (no exercises yet), not item-level.

### R-05 · The customised dot

Items that have been adjusted away from their seed value carry a 4px `brand.default` dot at the bottom-right of the card border. Nothing else indicates "customised." No text, no highlight, no border change. Dot appears/disappears in lockstep with deviation.

### R-06 · Voice: practitioner, always

No discipline-specific labels in UI copy. "Bio" / "physio" / "trainer" / "coach" are all retired as nouns for the product's primary user. Everyone is a **practitioner**. Client-facing copy uses `{TrainerName}` where available, falling back to "your practitioner" only when the name is unknown.

### R-07 · Shadows are noise

No shadows on any surface except the focus-ring token. Separation uses `surface.dark.border` hairlines. Elevation is implied by `surface.dark.raised` fill, not by `box-shadow`.

### R-08 · Flutter: no `flutter run`

Always build + install + launch. `flutter run` spawns debug processes that don't clean up cleanly. See infrastructure notes.

### R-09 · Default to obvious. No behavioural inference.

UI affordances default to their most obvious form — breathing glow on tappable dots, full labels on buttons, visible hit targets. We never dim, hide, or quiet an affordance based on inferred user skill, use count, or time-in-app.

Customisation belongs in Settings, as explicit pro-user toggles (e.g. "reduce motion", "hide insertion-dot pulse"). The system must not decide on its own that a user has "graduated" — that's paternalistic and penalises newcomers returning after a break.

Rationale: Melissa and her peers will use this intermittently, often after weeks off. A UI that has quietly toned itself down since last visit feels broken. Obvious-by-default is forgiving; user-controlled toning-down is respectful.

### R-10 · Player parity is non-negotiable

Mobile (Flutter) and web (`session.homefit.studio`) players are ONE
logical product. Every change to either surface MUST land in both the
same iteration. Drift breaks the trainer's experience: she demos to the
client on the web link, so any feature gap reads as "your tool is
inconsistent". Don't ship player updates to one surface without porting
to the other.

### R-11 · Account & billing features land on Mobile + Portal as twins

Anything in account, billing, settings, preferences, or referral falls
into the practitioner's admin surface and MUST ship to BOTH the mobile
app and the manage portal in the same iteration. Capture and edit
features stay split (mobile is the editor, web player is the consumer —
governed by R-10). Player playback features are governed by R-10.

Twins do not have to be visually identical — platform-appropriate UX
wins (bottom sheet on mobile, full page on web; SnackBar undo on
mobile, inline countdown banner on web). What must match is the
*capability set*: if a user can set a password on one surface, they
can set it on the other; if they can see referral stats on one, they
can see them on the other. The mobile twin is allowed to be lighter
(phone is for in-the-moment, desktop is for admin) — but never absent.

Before implementing any account / billing / settings / referral
feature, explicitly call out which surfaces it touches. Default to
"both", justify "one" only if the action is fundamentally tied to the
device (e.g. iOS share sheet, Camera mode).

### R-12 · Portal dashboard hygiene

1. **Every tile has a destination.** No pure-display tiles. A stat
   tile is a link-tile that clicks through to its deep-dive page.
2. **No orphaned functionality.** If a feature exists only on the
   dashboard, promote it to a dedicated page; the dashboard tile
   becomes a summary-plus-click-through.
3. **Primary nav covers every destination.** If a page isn't
   reachable from the nav, it's orphaned (fix the nav) or shouldn't
   exist (delete the page). Exceptions: quick/public pages like
   `/r/[code]`, `/sign-up`, `/auth/*`.
4. **Dashboard is a summary, not a workspace.** Key number + one tap
   to drill in. No inline forms, no long lists, no nested actions.
5. **One affordance style per card type.** Clickable tiles have a
   consistent hover state + arrow/chevron. Stat-only cards (rare)
   look obviously non-interactive.
