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

- `card.raised` base
- Thumbnail: 96×96, `radius.md`, fill `surface.dark.bg` (placeholder for line-drawing)
- Title: `title.lg`, `ink.dark.primary`
- Meta row (reps × sets · hold · rest): `label.md`, `ink.dark.secondary`, chips separated by a 1px × 12px `surface.dark.border` divider
- Expanded: reveals circuit badge, notes (`body.md`), video thumbnail grid

---

## Circuit Header

Sits above grouped exercise cards.

- Height: 40
- Left: `Circuit` label — `label.lg` uppercase, `brand.default`, letter-spacing 0.5
- Middle: round indicator `Round 2 of 3` — `label.md`, `ink.dark.secondary`
- Right: collapse chevron
- Bottom border: 2px `brand.tint-border`

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
- **Pulse Mark spinner** for full-page / initial fetch: 48px mark, `brand.default`, `motion.pulse`.
- **Inline spinner** for in-flight buttons: 16px circle, 2px stroke, `motion.normal` rotate.

Rule: pick by expected duration. < 300ms → nothing. 300ms–2s → inline. > 2s → skeleton or Pulse Mark.

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
- Pulse Mark horizontal lockup, top-left, 48h
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
