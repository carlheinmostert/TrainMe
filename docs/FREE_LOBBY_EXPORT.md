# Free Lobby Export — Spec (Draft, partially superseded)

A freemium artefact derived from the lobby content. Practitioners give it
to clients without spending a credit; the artefact gateways back into the
paid interactive product via an upgrade hook. Strategic goal: lower the
adoption barrier so the next plan a practitioner publishes is paid.

Status: **draft, pre-implementation**. Author: Carl + Claude, 2026-05-04.

## Post-implementation update (2026-05-15)

**This spec is partially superseded.** The shipped format is **multi-page A4 PDF**, not PNG. The "Format decision" matrix in section 2 below is **reference-only** — the trade-off was re-run during implementation (2026-05-13 → 2026-05-14) and PDF won on multi-exercise layout and print fidelity. PNG remains as a desktop-only fallback inside the in-page modal (a workaround for the cross-browser blob-download bug; see `gotcha_desktop_blob_download` memory) and is **not** the primary surface.

Other shipped reality the rest of this spec doesn't reflect:

- **Pre-publish AND post-publish.** Open question #2 ("Pre-publish or post-publish?") resolved as **both**. The mobile Preview step embeds the lobby locally (via `unified_preview_screen.dart` scheme handler) and surfaces the Share button before a single credit is consumed. The post-publish path also works (same code, hosted on `session.homefit.studio`).
- **Triggered from the lobby's Share button**, not a Studio toolbar trigger. The export-only footer is hidden in the live lobby and only rendered into the export pipeline.
- **Always free, no metering.** Open question #1 resolved as **fully free, unlimited**.

Canonical practitioner-facing name: **PDF handout** (see [CONTEXT.md](../CONTEXT.md)). Internal/technical name: **Lobby export**.

The sections below remain useful for the original strategic framing, edge-case enumeration, and phasing rationale — but do NOT take format/availability decisions from them without cross-checking against shipped code.

---

## 1. Strategic frame

**Free product:** static "menu" view of the workout — list of exercises
with hero frames, reps/sets/hold/notes, circuit grouping. No timers, no
prep countdown, no treatment switching, no audio, no analytics.

**Paid product (unchanged):** the interactive deck at
`session.homefit.studio/p/{planId}` — workout-along experience with
timers, prep, treatment switching, audio, analytics.

**Upgrade hook:** every free artefact carries a small QR code + URL
pointing to the interactive plan. Same plan, different surface. The free
artefact ends with "scan to play with timers".

The free product is the *amputated* paid product, not a separate thing.
That's the architectural commitment: one source of truth (the lobby
template), two render targets (interactive vs static).

## 2. Format decision

| Format | Distribution | Fidelity | Verdict |
|---|---|---|---|
| **Image (PNG)** | WhatsApp / iMessage inline preview, Photos app, AirDrop | High | **MVP — primary export** |
| Self-contained HTML | Mail / file share, opens in any browser | Highest | Phase 2 if asked |
| Free static URL `/o/{planId}` | Same as paid URL but free | Highest, but blurs free/paid line | Phase 3 / open question |
| PDF | Universal | Dead-feeling, off-brand | **Rejected** |

Image wins on distribution friction. Sub-second to send, zero friction
to receive, beautiful inline in WhatsApp (the dominant channel — 84% of
SA healthcare workers use WhatsApp for work per `MARKET_RESEARCH.md`).

## 3. Architecture — `.is-export` root class

**Single source of truth: `web-player/lobby.html` + `lobby.css` + `lobby.js`.**

The export caller adds a class to the document root, snapshots, removes
the class. CSS does all the visual filtering. No template fork.

```js
// In the export pipeline
document.documentElement.classList.add('is-export');
const png = await snapshot();
document.documentElement.classList.remove('is-export');
```

```css
/* Hide live-only chrome under the export class */
.is-export .lobby-cta-bar,
.is-export .lobby-treatment-row,
.is-export .lobby-settings-popover,
.is-export .pill.is-active,
.is-export .lobby-row.is-active-pill,
.is-export .build-version-marker {
  display: none;
}

/* Reveal export-only content (default: display: none) */
.is-export .lobby-export-header,
.is-export .lobby-export-footer {
  display: block;
}

/* Force expanded states (no tap affordances in a static doc) */
.is-export .lobby-row .notes-collapsed { display: none; }
.is-export .lobby-row .notes-expanded { display: block; }
```

**Bonus:** the same class is toggleable in Safari DevTools, so we can
design the export visual interactively in Workflow Preview without a
rebuild. That's how we'll iterate on layout.

## 4. What's hidden vs added

### Hidden under `.is-export`

- Sticky CTA bar (Start workout button, gear icon)
- Treatment selector + popover
- Pill matrix active-state glow + pulsing border
- Active-row highlight on the list
- Build-version marker
- Tap affordances (notes click-to-expand, pill click-to-jump)
- Hero `<video>` autoplay → swap for static `<img>` of the hero frame
  (this also dodges WhatsApp's lack of `<video>` support if anyone ever
  shares HTML, and avoids on-device decoder pressure during snapshot)

### Added under `.is-export`

- **Export header** — practice name, practitioner name, client name,
  date sent. The "official document" feel: all info that's currently
  implied by chat context but missing in a forwarded artefact.
- **Export footer** — small homefit logo + QR code → interactive plan
  URL + tagline ("scan to play with timers"). The upgrade hook.
- Optional v2: legend strip explaining the visual grammar (rest band,
  circuit bracket) since the static doc has no animations to teach it.

## 5. Generation pipeline (mobile)

Two viable paths, ranked:

### Path A — Flutter `RepaintBoundary` (preferred)

Build a `LobbyExportCard` widget that mirrors the lobby visual at
1080-wide × N-tall. Paint to PNG via `RepaintBoundary` + `toImage()`.

**Pros:** all on-device, offline-friendly (fits homefit's offline-first
ethos), no WebView lifecycle, fastest, cheapest.

**Cons:** layout duplicated between Flutter widget and `lobby.css`. R-10
parity tax: every visual change to the lobby must mirror to the export
widget. Acceptable if export visual is locked early.

### Path B — WKWebView snapshot

Render the existing lobby in a hidden WKWebView at the export viewport
size, set `.is-export` on `document.documentElement`, await layout +
hero `<img>` decodes, call `WKWebView.takeSnapshot(...)` over the full
scrollable height.

**Pros:** zero layout duplication; one source of truth for visuals.

**Cons:** WebView lifecycle, async hero loads to await, slower, more
moving parts. *Same surface that's currently freezing in the lobby
freeze investigation* — meta-risk if we adopt this before that's solved.

**Recommendation:** Path A for MVP. Revisit Path B if the freeze fix
exposes the WebView as more reliable than expected, or if the export
layout starts diverging from the live lobby layout in painful ways.

## 6. UX surface in the trainer app

Trigger lives next to the existing Share affordance on the Studio
toolbar. Two share options once a session has captures:

- **Share interactive plan** — current behaviour, consumes a credit on
  publish, returns `/p/{planId}` URL.
- **Export free overview** — new, no credit, generates PNG, opens iOS
  share sheet (image type, so WhatsApp/Messages preview inline).

No popup, no modal (per R-01 + Carl's "no popups ever" rule). The export
flow goes: tap → toast "Generating overview…" → iOS share sheet appears
with the PNG attached → user picks WhatsApp / Messages / Mail / Save.

## 7. Upgrade hook (the gateway back to paid)

Footer of the PNG includes a QR code pointing to the plan's interactive
URL. The plan must already be published for the QR to resolve to a live
deck, OR we use a special pre-publish landing page.

**Three options for the QR target:**

1. **Already-published plan only** — export is post-publish. QR points
   straight to `/p/{planId}`. Simple, but ties free export to paid
   publish (less clean as a freemium hook).
2. **Free static URL `/o/{planId}`** — host the same lobby content as a
   static HTML page. QR points there. Client gets the menu in their
   browser without an app or signup. Practitioner hasn't paid. The
   `/o/` page itself contains a "scan to play interactively" link that
   IS gated behind publish. Cleanest free-tier story; needs a new
   route + middleware path.
3. **No QR** — practitioner shares the PNG via WhatsApp; if client
   wants interactive, practitioner sends the URL separately. Simplest
   but loses the most valuable upgrade signal.

**Recommendation:** start with #1 (post-publish only) for MVP. Move to
#2 once we've validated the format + share flow. #2 requires a new
Vercel route + a thin SSR layer; not blocking.

Important — **iOS Reader-App compliance** (memory:
`feedback_ios_reader_app.md`): the QR / footer copy must not mention
prices, "buy", "credits", "upgrade" in a way that reads as a purchase
path. "Scan to play with timers" is fine; "Scan to upgrade" is not.

## 8. Edge cases

- **WhatsApp image height limit** — WhatsApp downscales images past
  ~1600px height on some devices. Plans with 12+ exercises will exceed
  this. Mitigations: 1) cap PNG height, scale rows tighter; 2) split
  into 2 tiles for very long workouts; 3) accept the downscale (still
  legible). Real-device test required before sign-off.
- **Photo-only plans** — hero frame is just the photo. No work needed.
- **Video-only plans** — hero frame is the Hero shot already extracted
  by Wave-Hero-Crop. Already on-device as a static JPG.
- **Mixed plans** — same; per-exercise hero is uniform.
- **Plan with rest periods** — rest cards still render, same visual
  language. Legend strip helps.
- **Practitioner without an avatar** — header gracefully degrades to
  practitioner name only.
- **Client name unset** — header omits the "for {client}" line.
- **Pre-publish state** — if export is allowed pre-publish (option 2 or
  3 of the QR section), no QR rendered; or QR points to a "this plan
  isn't published yet" landing page.
- **Hero-frame missing** — fallback to a coral-tinted placeholder with
  the exercise name centred. Same fallback the live lobby uses.

## 9. Open questions

1. **Credit-metered or fully free?** MVP recommendation: fully free,
   unlimited. Friction-free adoption matters more than monetisation at
   this scale. Revisit if abuse signal appears.
2. **Pre-publish or post-publish?** MVP recommendation: post-publish
   only. Simpler product story, no orphan-artefact risk.
3. **Per-client or per-plan?** Same artefact regardless of client (the
   client name is just a header field). Per-plan.
4. **Branding density** — how loud is the homefit logo in the artefact?
   MVP: small, footer only. Revisit after share-rate data.
5. **Analytics** — do we track export generation? Would tell us the
   adoption-funnel volume. Likely yes, gated by analytics consent like
   everything else.
6. **Long-term — server-side render?** If `/o/{planId}` ships in phase
   2, OG-card-style server-render via `@vercel/og` could supersede the
   on-device path entirely. Not for MVP.

## 10. Phasing

**MVP (Phase 1):**
- `.is-export` CSS class + hidden/added blocks in `lobby.html` / `lobby.css`
- `LobbyExportCard` Flutter widget (Path A) — mirrors lobby layout
- Export trigger on Studio toolbar (next to Share)
- iOS share sheet with PNG attachment
- QR → published plan URL only (option 1)
- Test script under `docs/test-scripts/` covering: trigger, layout
  parity, WhatsApp send, iMessage send, AirDrop, very long workout,
  photo-only plan, video-only plan

**Phase 2 (validate first):**
- `/o/{planId}` static HTML route (server-side rendered)
- QR points to `/o/{planId}` (option 2)
- Self-contained `.html` download as alt format

**Phase 3 (if signal):**
- Apple Wallet `.pkpass` variant
- Server-side OG image via `@vercel/og`
- Practitioner-customisable footer copy

## 11. Anti-goals

- No PDF, ever
- No new modal / popup (R-01 + "no popups ever")
- No prices / buy buttons / "upgrade" CTA copy in the artefact (Reader
  App rule)
- No credit consumption on free export
- No server-side dependency for the MVP path (offline-first ethos)
- No `<video>` in the artefact (image only)
- No fork of the lobby template — `.is-export` class is the *only*
  visual divergence point
