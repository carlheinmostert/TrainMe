# Brief for Claude Design — how to sync with this repo

**Audience:** a session at `claude.ai/design` (hereafter *Claude Design*) that has been given read access to the `carlheinmostert/TrainMe` repo and is about to produce a design-system artifact for this product.

**Read this file first, every time.** It is the contract between the design session and the repo. The rest of `docs/design/` describes the product's current design state — this file describes the **shape, scope, and constraints** of what you're allowed to deliver.

**Your capabilities in this workflow:**

| You can | You cannot |
|---|---|
| Read any file in the repo | Write to the repo |
| Iterate with Carl in your canvas (HTML/CSS/JS previews, SVG renders) | Run shell commands, grep, or execute code against the repo |
| Produce a zip bundle as output | Commit, branch, or open PRs |

The zip is Carl's deliverable to carry back. He downloads it, walks it to a Claude Code session that has write access, and that session does the mechanical apply (rsync, mirror edits in Flutter/web-portal/web-player, commits, PR). **Your job ends at "here's a well-shaped zip."** Getting the shape wrong (defined in §7) makes the apply side stop and ask — which is exactly the friction this brief exists to eliminate.

If anything in here contradicts the raw files in `docs/design/project/`, the raw files win (they are the running truth). Flag the contradiction in your delivery's CHANGELOG so a follow-up PR can update this brief.

---

## 1. What the product is

**homefit.studio** — a multi-tenant SaaS for biokineticists, physiotherapists, and fitness practitioners. A practitioner captures exercises with a phone during a client session, the app turns them into clean line-drawing demonstrations, assembles a plan, and shares it with the client as a WhatsApp-friendly URL.

Three consuming surfaces, all dark-first, all share one accent colour (coral `#FF6B35`):

| Surface | Stack | Root in repo | Audience |
|---|---|---|---|
| Trainer app (mobile) | Flutter 3.41 + iOS native video | `app/` | Practitioner |
| Client web player | Static HTML/CSS/JS on Vercel | `web-player/` (also mirrored into `app/assets/web-player/` for offline WebView fallback) | Client, anon read |
| Practice portal | Next.js 15 App Router on Vercel | `web-portal/` | Practice owner |

Any design change must land as coherent across all three.

---

## 2. How design flows into the product

There is **no external Figma**. The design system is **git-native**:

```
claude.ai/design  (you)
   │  zip delivery ──► Carl downloads
   ▼
Carl's local Claude Code session
   │  applies per docs/design/APPLYING-UPDATES.md (if present) or this brief
   ▼
PR to main
   │  merge
   ▼
All three consuming codebases pick up the new tokens / assets / copy
```

Your artifact is the input to Claude Code (the coding agent on the repo side). A well-shaped artifact lets Claude Code apply the change mechanically, with diffs Carl can review step-by-step. A badly-shaped artifact forces Claude Code to stop and ask — which Carl now has tripped on enough to demand this brief exist.

---

## 3. Current design-system layout in the repo

```
docs/
└─ design/
   ├─ CLAUDE-DESIGN-BRIEF.md         ← this file
   ├─ README.md                      ← handoff note aimed at coding agents; may be stale, leave alone
   ├─ project/                       ← CANONICAL source of truth for tokens, components, voice, logos
   │  ├─ tokens.json                 ← typed design tokens (W3C community format)
   │  ├─ system.css                  ← applied tokens as CSS variables; mirrors tokens.json
   │  ├─ components.md               ← component specs + Design Rules R-01..R-12
   │  ├─ voice.md                    ← voice, tone, vocabulary (practitioner language)
   │  ├─ index.html                  ← browsable reference doc with 10 decision cards D-01..D-10
   │  └─ logos/                      ← matrix-mark SVGs (mark, mark-mono, lockup-horizontal, lockup-stacked, wordmark, favicon)
   ├─ mockups/                       ← interactive HTML prototypes, one per pattern
   │  ├─ logo-explorations.html
   │  ├─ logo-ghost-outer.html       ← matrix-mark logo geometry, signed off
   │  ├─ network-share-kit.html
   │  ├─ progress-pills.html         ← progress-pill matrix spec
   │  └─ web-player-wireframe.html
   ├─ chats/                         ← transcripts from earlier design sessions
   └─ screenshots/                   ← reference captures from the shipped app
```

**You may update:** `project/` (all files), `mockups/` (additive — never delete existing mockups).
**You should not touch:** `README.md`, `chats/`, `screenshots/`, anything outside `docs/design/`.

---

## 4. Canonical files in `docs/design/project/` — roles and contract

### `tokens.json` — the root of truth for every primitive value

Typed W3C-format design tokens. Colour, typography scale, spacing, radius, shadow, motion, z-index, breakpoints. All three consuming codebases mirror this file:

| Token group | Consumer | Mirror file |
|---|---|---|
| Colour, typography, spacing, radius, shadow, motion | Flutter | `app/lib/theme.dart` + `app/lib/theme/motion.dart` |
| Colour, typography, spacing, radius, shadow, motion | Web player | `web-player/styles.css` (CSS variables in `:root`) |
| Colour, typography, spacing, radius, shadow, motion | Web portal | `web-portal/tailwind.config.ts` + `web-portal/src/lib/theme.ts` |

**Any change to a token value in `tokens.json` implies a matching change in all three mirror files.** Your CODE-MIGRATION.md must enumerate these mirror edits — skip one and the three surfaces drift.

Current file header:

```json
"$meta": {
  "name": "homefit.studio",
  "version": "1.0.0",
  "mode": "dark-first (light mirror defined)",
  "updated": "2026-04-18",
  "source-of-truth": true,
  "targets": ["app/lib/theme.dart", "web-player/styles.css", "web-portal/tailwind.config.ts"]
}
```

Bump `version` and `updated` on every delivery. Semver rules:
- **Patch** (`1.0.x`) — copy / description edits only, no primitive-value changes.
- **Minor** (`1.x.0`) — new tokens, new asset variants, new components. Existing token values unchanged.
- **Major** (`x.0.0`) — any existing token value changed. Forces Claude Code to do a repo-wide sweep. Use sparingly.

### `system.css` — the CSS-consumable companion to `tokens.json`

Same values, exposed as `--c-*`, `--text-*`, `--space-*` CSS variables. Consumed directly by `web-player/styles.css` and `web-portal/src/app/globals.css` via `@import` or copy. When you change `tokens.json`, update `system.css` in the same delivery.

**Known drift to reconcile:** as of this writing, `tokens.json` has `color.semantic.rest = #86EFAC` (sage) and `system.css` has `--c-rest: #64748B` (blue-grey). Whichever direction you pick, both files must agree.

### `components.md` — component inventory + Design Rules

Every component spec has: variants, sizes, radius, typography slot, states (default / hover / pressed / focus / disabled / error), spacing. References `tokens.json` by name — never hard-codes a value.

The tail of the file holds **Design Rules R-01 through R-12**. These are load-bearing brand rules, not style preferences. Do not drop them, rename them, or change their numbers. You may **add** new rules (R-13+) with strong justification. Current rules, as of 2026-04-22:

| ID | Rule |
|---|---|
| R-01 | No modal confirmations for destructive actions (undo SnackBar + 7-day recycle bin instead) |
| R-02 | Header purity — no metadata in headers |
| R-03 | Gesture zones over mode switches |
| R-04 | Defaults are starting points, not empty states |
| R-05 | The customised dot (per-exercise customisation indicator) |
| R-06 | Voice: practitioner, always |
| R-07 | Shadows are noise — use 1px border for separation |
| R-08 | Flutter: no `flutter run` — use build + simctl install |
| R-09 | Default to obvious. No behavioural inference. |
| R-10 | Player parity is non-negotiable — mobile preview + client web player land in the same PR |
| R-11 | Account & billing features land on Mobile + Portal as twins |
| R-12 | Portal dashboard hygiene — every tile clickable, one concept per tile |

### `voice.md` — vocabulary + tone rules

One page. South African English, practitioner-vocabulary canon, error-message formula. Small file; edits here are rare but permitted when the product expands into new copy territory.

### `index.html` — the browsable reference doc (and the decision-card store)

A single-file HTML page with brand tokens, component previews, and **ten reconciliation decision cards D-01 through D-10**. Each card has a `status` of `Proposed`, `Approved`, `Rejected`, or `Deferred`.

**Status promotion is Carl's call, not yours.** Do not flip any card from `Proposed` → `Approved` in your delivery. You may:
- Add new cards (D-11+).
- Edit the body of an existing `Proposed` card if new information changes the analysis.
- Mark a card `Rejected` or `Deferred` in response to something Carl has said in chat — but only with a rationale line that quotes or paraphrases his decision.

Current card titles (all `Proposed`):

| ID | Title |
|---|---|
| D-01 | "Secondary text on dark" — two greys calling themselves the same thing |
| D-02 | Dark-surface naming — literal vs semantic |
| D-03 | Semantic colour names — full words vs abbreviations |
| D-04 | Motion tokens — do they exist at all? |
| D-05 | Spacing scale |
| D-06 | Component state library — empty / loading / error / success / disabled |
| D-07 | Shadow posture — brand element or noise? |
| D-08 | The dead Flutter light theme |
| D-09 | Typography scale on web |
| D-10 | Tint / alpha-overlay tokens |

### `logos/` — the matrix-mark SVG canon

Six files at time of writing: `mark.svg`, `mark-mono.svg`, `lockup-horizontal.svg`, `lockup-stacked.svg`, `wordmark.svg`, `favicon.svg`.

**Geometry is frozen.** The matrix mark is: 3 ghost pills → 2×2 coral circuit chips in a tint band → 1 sage rest chip → 3 ghost pills (mirrored). `viewBox="0 0 48 9.5"` for matrix-only, `"0 -2 48 16"` for the lockup. Signed off at `docs/design/mockups/logo-ghost-outer.html`.

You may add animated variants (SMIL or CSS-driven) and size variants, but you may not change the underlying shape grammar.

**Critical pattern — the three consuming codebases render this geometry INLINE, not as a shared SVG asset.** There are no `mark.svg` files at `app/assets/`, `web-player/logos/`, or `web-portal/public/logos/`. The geometry is hand-ported into:

- `app/lib/widgets/homefit_logo.dart` — Flutter `CustomPaint`-based widget
- `web-portal/src/components/HomefitLogo.tsx` — React with inline `<svg>` JSX
- `web-player/app.js#buildHomefitLogoSvg()` — function returning an SVG string

Byte-for-byte mirrored. If you ship a new logo variant, your CODE-MIGRATION.md must include the inline-port instructions for each of these three files, **not** an "rsync this SVG into each codebase" step. (An earlier bundle assumed physical asset files and it generated noise — see section 7 for the correct pattern.)

---

## 5. Current token / asset snapshot (read these in the repo to confirm before authoring)

Before writing a bundle, `cat` the following files in the repo and base your delta on what's actually there, not what you remember:

- `docs/design/project/tokens.json`
- `docs/design/project/system.css`
- `docs/design/project/components.md`
- `docs/design/project/voice.md`
- `docs/design/project/index.html` (decision-card statuses)
- `docs/design/project/logos/*.svg`
- `app/lib/theme.dart`, `app/lib/theme/motion.dart` (Flutter mirror)
- `web-player/styles.css` `:root` block (web-player mirror)
- `web-portal/tailwind.config.ts`, `web-portal/src/lib/theme.ts` (web-portal mirror)
- `app/lib/widgets/homefit_logo.dart` + `web-portal/src/components/HomefitLogo.tsx` + `web-player/app.js#buildHomefitLogoSvg()` (logo geometry canon)

Known drifts as of 2026-04-22 (reconcile in your first delivery or flag as intentional):

| Where | Symptom |
|---|---|
| `color.semantic.rest` | `tokens.json` says sage `#86EFAC`, `system.css` says blue-grey `#64748B`. Pick one. |
| `motion` | `tokens.json` has `motion.pulse` (legacy name from retired v1.0 "Pulse Mark" heartbeat logo). A future delivery may rename to `motion.loop` or split into `motion.loop` + `motion.session`. Flutter has `AppMotion.pulseCycle` still. |
| Flutter dead code | `app/lib/widgets/powered_by_footer.dart` and `app/lib/screens/sign_in_screen.dart` both contain `_PulseMarkPainter` classes — retired v1.0 heartbeat logo painters that are no longer referenced. Flag for deletion when a delivery touches motion. |
| Web-player class naming | `web-player/styles.css` and `web-player/index.html` still reference a `.pulse-mark` CSS class — the class name is wrong but the element inside is already the new matrix geometry. Flag for rename when a delivery touches logo animations. |

---

## 6. Where each design primitive is consumed (mirror points)

Your CODE-MIGRATION.md drives a coding agent. For that agent to do the right thing, the mirror-point map has to be accurate. Here it is as of 2026-04-22:

### Flutter (`app/`)

| Primitive | File |
|---|---|
| Colour / typography / spacing / radius / shadow tokens | `app/lib/theme.dart` (`AppColors`, `AppTypography`, `AppSpacing`, `AppRadius`) |
| Motion tokens | `app/lib/theme/motion.dart` (`AppMotion`) |
| Feature flags | `app/lib/theme/flags.dart` |
| Logo geometry | `app/lib/widgets/homefit_logo.dart` (inline `CustomPaint`) |
| Progress-pill matrix | `app/lib/widgets/progress_pill_matrix.dart` |
| Powered-by footer | `app/lib/widgets/powered_by_footer.dart` |
| WebView-bundled player fallback | `app/assets/web-player/*` (mirror of `web-player/`; any web-player migration must be applied twice) |
| Logo asset files | None — geometry is inline, no `assets/logos/` directory |

### Web player (`web-player/`)

| Primitive | File |
|---|---|
| Tokens as CSS variables | `web-player/styles.css` `:root` (lines ~1–60) |
| Logo geometry | `web-player/app.js#buildHomefitLogoSvg()` (function returns SVG string) |
| OG-card server render | `web-player/middleware.js` (Vercel Edge) |
| Service worker | `web-player/sw.js` (bump `CACHE_NAME` on visual regressions to force refresh) |
| Logo asset files | None — geometry is inline, no `logos/` directory |

### Web portal (`web-portal/`)

| Primitive | File |
|---|---|
| Tailwind theme tokens | `web-portal/tailwind.config.ts` |
| TypeScript token references | `web-portal/src/lib/theme.ts` |
| Logo geometry | `web-portal/src/components/HomefitLogo.tsx` (React with inline `<svg>`) |
| Global CSS | `web-portal/src/app/globals.css` |
| Logo asset files | None — geometry is inline, no `public/logos/` directory |

If a delivery introduces something that genuinely needs a shared asset (an animated SMIL SVG, an OG-card PNG, an App Store screenshot), that is the **one case** where you'd add physical files — and your CODE-MIGRATION.md must say precisely where in each consuming codebase they go, along with any build-system registration (pubspec.yaml entry, Next `public/`, etc.).

---

## 7. Shape of a sync delivery — differential, not full mirror

Your output is a zip named `homefit.studio.zip` (or `design-system-update-v<X.Y>.zip` — short is preferred). **The zip is a DELTA, not a full-repo export.** Since you can already read the repo, don't send files back that haven't changed. Only include files you're proposing to add, change, or replace.

Inside the zip:

```
<top-level-folder>/
├─ README.md                       ← one screen of prose: what changed and why
├─ CHANGELOG.md                    ← per-value delta table vs current repo state
├─ CODE-MIGRATION.md               ← mirror-point edits + verification steps
└─ docs/
   └─ design/
      ├─ project/                  ← sparse overlay — ONLY files that changed
      │  ├─ tokens.json            ← (only if any token changed)
      │  ├─ system.css             ← (only if any CSS var changed)
      │  ├─ components.md          ← (only if any spec or Design Rule changed)
      │  ├─ voice.md               ← (only if any copy rule changed)
      │  ├─ index.html             ← (only if a card was added or a body edited)
      │  └─ logos/
      │     └─ <new-or-changed>.svg
      └─ mockups/                  ← NEW mockups only (never overwrite or delete existing)
         └─ <new-mockup>.html
```

**Key rules for the delta:**

- **Sparse, not full.** If `voice.md` is unchanged, it is NOT in the zip. No placeholder files, no "identical copy just in case." Presence in the zip means something changed.
- **Full contents for changed files, not patches or diffs.** The apply side overlays the bundle with `rsync -av <bundle>/docs/design/ docs/design/` — without `--delete`, so unchanged repo files persist. Patches/unified diffs are harder to apply mechanically and harder to review.
- **`docs/design/mockups/`** is strictly additive. Never include a filename that already exists in the repo's `docs/design/mockups/`. Never propose overwriting a signed-off mockup.
- **Deletions** (rare) must be expressed in CODE-MIGRATION.md as an explicit `rm <path>` step, plus a CHANGELOG entry explaining why. Never express a deletion by omitting a file — omission always means "unchanged."
- **Logo files in `project/logos/`.** Include only net-new variants or replacements for files you're changing. Unchanged SVGs stay out of the zip.
- **`CHANGELOG.md` is load-bearing.** Because the zip is sparse, the CHANGELOG is the ground truth for what changed. Every value delta — colour hex, spacing number, font size, radius, motion duration, copy string, logo filename, decision-card body — must be enumerated with OLD and NEW values. If Claude Code finds a mirror-file value that disagrees with `tokens.json` and the CHANGELOG is silent about it, the apply stops. Silent drift is the main failure mode.

**Example CHANGELOG entry:**

```markdown
## Tokens

### Colours
- **color.semantic.rest** — `#86EFAC` (sage) → `#64748B` (blue-grey)
  - Reason: reconciling with `system.css` which has always used blue-grey.
  - Mirror edits: `app/lib/theme.dart` `AppColors.rest`, `web-player/styles.css` `--c-rest` (no change needed, already `#64748B`), `web-portal/src/lib/theme.ts` `colors.rest`.

### Motion
- **motion.pulse** → **motion.loop** (rename only; value identical at `1.4s cubic-bezier(0.4, 0, 0.6, 1) infinite`).
  - Reason: the v1.0 "Pulse Mark" heartbeat was retired; the rhythm is now shared across loading contexts only.
  - Mirror edits: `AppMotion.pulseCycle` → `AppMotion.loopCycle`, `.pulse-mark` → `.mark-loading`.

## Files included in this bundle
- `docs/design/project/tokens.json` — updated (rest colour, motion rename)
- `docs/design/project/system.css` — updated (rest colour, motion rename)
- `docs/design/project/components.md` — updated (component spec using motion.loop)
- `docs/design/mockups/matrix-session-motion.html` — NEW

## Files NOT included (unchanged)
- `docs/design/project/voice.md`
- `docs/design/project/index.html`
- `docs/design/project/logos/*` (all existing SVGs unchanged)
```

The "Files included" + "Files NOT included" summary at the bottom of the CHANGELOG is a load-bearing sanity check. The apply side uses it to confirm that "file absent from zip" means "intentionally unchanged" and not "Claude Design forgot to include it."

**CODE-MIGRATION.md is the execution plan.** For each consuming codebase, enumerate exactly:

1. File path (repo-relative).
2. What to change (rename a symbol, swap a value, add a new file, delete a file).
3. Grep commands the apply side should run afterward and expect zero hits from (for residuals).
4. Verification: `flutter analyze` for Flutter, `npm run build` for web-portal, manual browser check for web-player.
5. The exact apply command for the docs overlay: `rsync -av <bundle>/docs/design/ docs/design/` — **without `--delete`**, since the bundle is a sparse overlay.

---

## 8. Ground rules — non-negotiable

1. **Do not flip decision-card statuses.** `Proposed` → `Approved` is Carl's job in a separate PR.
2. **Do not change a token value without a CHANGELOG entry.** Silent drift is the main failure mode of design-system syncs.
3. **Do not propose physical SVG asset files in consuming codebases.** Logos are inline. Only ship an asset file if the delivery genuinely introduces a new shared binary (SMIL animation, PNG, etc.) — and even then, place it in `docs/design/project/logos/` as the source of truth, with CODE-MIGRATION.md saying whether to mirror into each codebase.
4. **Do not delete or overwrite existing mockups.** Add new ones; keep the old as an archive.
5. **Do not invent discipline-specific role words.** The vocabulary is "practitioner" (see `voice.md` R-06). Never "bio", "physio", "trainer", "coach", "user".
6. **Do not reintroduce retired design elements.** Specifically: the v1.0 "Pulse Mark" (heartbeat-line ECG stroke + rooftop silhouette logo) is retired — the matrix mark replaced it. Teal as a rest-period colour was retired in favour of sage or blue-grey (see drift note in §5). Do not bring these back without a decision card.
7. **Stay inside `docs/design/`.** Your zip should never propose edits to `CLAUDE.md`, `docs/*.md` outside `design/`, or any non-design repo paths.
8. **When in doubt, propose — don't decide.** Add a new decision card (D-11+) rather than changing values unilaterally.

---

## 9. Preflight reading — before authoring a delivery

You can read files but can't run shell commands. Before writing a bundle, read these files in this order. Each one answers a specific question about current state.

**Tokens — the delta baseline**
- `docs/design/project/tokens.json` — the whole file.
- `docs/design/project/system.css` — the `:root` block at the top (first ~80 lines). Compare against `tokens.json` for drifts.

**Consuming-code mirrors — confirm current values before proposing changes**
- `app/lib/theme.dart` — Flutter colour, typography, spacing, radius, shadow.
- `app/lib/theme/motion.dart` — Flutter motion tokens (`AppMotion`).
- `web-player/styles.css` — `:root` block (first ~80 lines).
- `web-portal/tailwind.config.ts` — Tailwind theme.
- `web-portal/src/lib/theme.ts` — TypeScript token references.

**Logo geometry — byte-identical across three, confirm before proposing any variant**
- `app/lib/widgets/homefit_logo.dart` — Flutter `CustomPaint` inline.
- `web-portal/src/components/HomefitLogo.tsx` — React inline `<svg>`.
- `web-player/app.js` — find `buildHomefitLogoSvg()` and `buildHomefitLogoLockupSvg()`.

**Decisions and rules — don't flip, don't renumber**
- `docs/design/project/index.html` — skim for the `D-01` through `D-10` card blocks and their current statuses.
- `docs/design/project/components.md` — skim for the `R-01` through `R-12` section headings (tail of file).

**Retired-element residuals — flag for CODE-MIGRATION.md cleanup**
- `app/lib/widgets/powered_by_footer.dart` — may still contain `_PulseMarkPainter`.
- `app/lib/screens/sign_in_screen.dart` — same.
- `web-player/styles.css` — may still reference `.pulse-mark` class.
- `web-player/index.html` — may still have `<svg class="pulse-mark">`.
- `app/assets/web-player/` — mirror of `web-player/` bundled into the Flutter app. Any web-player migration applies here too.

Anything surprising — especially a token value in a mirror file that doesn't match `tokens.json` — is a drift. Either reconcile it in your delivery or flag it in the CHANGELOG as an intentional leave-alone. Silent drift is the main failure mode that forces the Claude Code apply session to stop and ask Carl.

---

## 10. One-liner prompt Carl uses with Claude Code to apply your delivery

Once this file lands in the repo and your zip is well-shaped, the coding agent's entry prompt collapses to:

> Apply the design-system update at `~/Downloads/<filename>.zip` following `docs/design/APPLYING-UPDATES.md` and the contracts in `docs/design/CLAUDE-DESIGN-BRIEF.md`.

If `docs/design/APPLYING-UPDATES.md` doesn't exist yet, your first delivery should ship it — it's the Claude-Code-side SOP, the mirror of this brief. A template for that file is a known-good artefact; ask Carl if he wants the previous one you authored in the v1.2 bundle carried over as-is.

---

## 11. If this brief is wrong

If you read this file and then read the repo and spot a contradiction — a token group you don't see here, a consuming file that isn't listed, a Design Rule that has disappeared — **your delivery should update this file** in the same commit as the other changes. The brief is living documentation. It is allowed to evolve. It is not allowed to lie.
