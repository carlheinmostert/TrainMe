# 2026-05-25 clipboard hero flight (M15 — PR `feat/clipboard-hero-flight`)

Replaces the abstract coral-particle copy animation with the
Carl-approved Variant 1 "lift-and-arc" hero flight, and adds the
mirror paste animation (staggered for batch pastes).

Source spec: M15 in `docs/test-scripts/2026-05-25-stack.md` →
mockup `docs/design/mockups/2026-05-25-clipboard-copy-animation.html`
Variant 1.

Touched files:
- `app/lib/widgets/clipboard_flight_animation.dart` — hero-flight
  widget; legacy point-flight kept as deprecated shim only.
- `app/lib/screens/studio_mode_screen.dart` — copy + paste flight
  orchestration; in-flight paste-reveal opacity wrap.

Walk on iPhone CHM after install. Tick by number; strike on pass.

## Copy animation (lift-and-arc)

- [ ] **1.** Open any session in Studio with at least 2 captured
  exercises. Right-swipe slowly past the long-swipe threshold on the
  TOP exercise card. The card's hero thumbnail (the same image you
  see on the card) lifts off the source card with a small scale-up,
  arcs UP to the top-right clipboard chip, shrinks as it goes, and
  lands. Chip pulses, count goes `0 → 1`. A light haptic fires on
  landing. NOT the old tiny coral dot flying the WRONG way (into the
  card). Direction is card → chip, subject is the hero, not a
  particle.

- [ ] **2.** Partial-right-swipe a SECOND exercise, tap the `Copy`
  pill in the reveal. Same lift-and-arc plays from this card's hero
  to the chip. Count goes `1 → 2`. Source card stays put (D6 — copy
  never removes the source).

- [ ] **3.** Eyeball the curve — the arc should be concave-UP (the
  thumbnail rises through a midpoint above the straight-line path
  between card and chip). Total flight feels close to 700 ms. Not a
  hard cut, not a bounce.

## Paste animation (mirror, staggered)

- [ ] **4.** Pop back to Home → open a DIFFERENT session in Studio
  (target session) — chip carries the count over from the copy
  session. Tap the chip body → paste sheet opens with all items
  selected. Tap `Paste N items`. For EACH selected item, a hero
  emerges FROM the chip, arcs DOWN to the bottom of the list, GROWS
  from chip-size to card-hero-size, and settles into the new row.
  Each landing fires a light haptic. The destination card fades up
  as its flight lands (not before).

- [ ] **5.** With 3+ items pasted at once, eyeball the stagger —
  the flights MUST NOT all leave the chip simultaneously. They
  spray ~80 ms apart so you see a satisfying cascade rather than a
  single mass arrival. The chip count decrements item-by-item as
  each flight lands (e.g. `3 → 2 → 1 → 0`), not all at once at
  paste time.

- [ ] **6.** Paste a single item — only one hero flies, no stagger
  visible (sanity check that the stagger doesn't regress the
  single-item case). Card fades up after the flight, not before.
  Source clipboard item is removed from the chip on landing.
