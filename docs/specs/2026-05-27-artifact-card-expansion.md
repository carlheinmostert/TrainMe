# Artifact card expansion — design spec

Authored 2026-05-27 after device-QA feedback on PR #548. Supersedes the fanned-deck-above-the-exercise-list UI that #548 shipped on Studio with the per-session accordion-expand pattern described below.

## Table of Contents

- [Context](#context)
- [Decisions](#decisions)
- [Surfaces](#surfaces)
- [Visual states](#visual-states)
- [Interaction model](#interaction-model)
- [Animation timings](#animation-timings)
- [Edge cases](#edge-cases)
- [R-10 parity](#r-10-parity)
- [Implementation pointers](#implementation-pointers)
- [Migration from PR #548](#migration-from-pr-548)
- [Out of scope](#out-of-scope)
- [Open questions](#open-questions)
- [Companion artefacts](#companion-artefacts)

## Context

PR #548 shipped the artifact-stacking UI by adding a fanned-deck zone ABOVE the exercise list on Studio. Carl's device-QA verdict: the implementation matched the original brief, but the brief itself misread the practitioner's mental model. Studio is the editing surface, not the browsing surface — adding a parallel "browse my published artifacts for this session" UI there pollutes the editing context.

The correct anchor for artifact browsing is the per-session card on the surfaces where a practitioner picks WHICH session to view. Today those surfaces show session cards as a vertical list. Adding a subtle "this session has published artifacts" depth cue + a tap-to-expand interaction puts artifact browsing where it belongs without adding a new top-level UI region.

## Decisions

Captured during brainstorming with Carl on 2026-05-27 morning:

1. **Surface scope** — ClientSessionsScreen (Clients tab → drill-in to a client) AND My Workouts (mobile) AND web `/me`. Studio is NOT a surface for this UI.
2. **Depth hint** — a single peek card edge, offset 4-5px down + right behind the session card, count-independent (1 artifact looks the same as 5).
3. **Expansion direction** — push siblings down, expand in place. Tapped card stays put; subsequent session cards reflow down to make room.
4. **Multi-expand policy** — accordion. Only one session expanded at a time. Tapping a new card auto-collapses the previous.
5. **Artifact card width** — full-width, same horizontal extent as the parent session card. NOT inset.
6. **Parent-child grouping cue** — vertical 3px coral hairline rail running flush with the left edge of the artifact stack, emerging from the bottom-left of the session card.
7. **Tap-conflict resolution** — the chevron at the right side of the session card is the ONLY tap target for expand / collapse. Tapping anywhere else on the session card still opens Studio (existing behaviour preserved).

## Surfaces

### ClientSessionsScreen (mobile, Flutter)

Path: Clients tab → tap a client card → ClientSessionsScreen for that client. Lists all sessions belonging to that client as a vertical card list.

`app/lib/screens/client_sessions_screen.dart` (canonical source). The session-card widget is the per-row element that gets the new depth + chevron + expand behaviour.

### My Workouts (mobile, Flutter)

Path: Home tab → My Workouts. The Self-client's session list. Same vertical card pattern as ClientSessionsScreen.

`app/lib/screens/my_workouts_screen.dart` (or equivalent — confirm exact file name during implementation). The session-card widget should share a common widget with ClientSessionsScreen so the depth + chevron + expand behaviour comes for free on both surfaces. If it doesn't share today, refactor to a shared widget BEFORE adding the new behaviour.

### Web `/me`

Path: `https://session.homefit.studio/me` (and staging twin). The consumer view of claimed artifacts, signed in via magic link.

`web-player/me.js` + `me.html` + `me.css`. Today (post-PR #548) renders horizontal fanned-deck bundles per source session. The redesign flips `/me` to the same vertical accordion pattern as mobile. The bundle concept stays (one bundle per source session) but the visual treatment becomes a session card + peek + chevron + vertical accordion.

## Visual states

Three states per session card. All apply identically to all three surfaces unless noted.

### Rest — session has artifacts

- Session card renders as today (filmstrip + count glyph + title + sub-text).
- A peek card edge sits behind the session card, offset 4-5px down + right. Same width as the session card; slightly tinted (one shade lighter than the session-card background); opacity ~0.92.
- A chevron-down glyph (24pt visible) appears at the right end of the card-body row, wrapped in a 44pt invisible tap target.
- The chevron is coral (not text-dim) to signal interactivity.

### Rest — session has zero artifacts

- Session card renders EXACTLY as today.
- No peek card. No chevron. No expand affordance.
- Card behaves exactly as today — tap anywhere = enter Studio. Unpublished sessions are visually unchanged.

### Expanded

- Tapped session card stays put.
- Peek card lifts upward (transform translateY(-6px) + scale(0.98)) and fades to opacity 0.
- Subsequent session cards push down to make room.
- Artifact cards animate into the gap below the session card, staggered.
- A 3px coral rail draws downward (scaleY 0 → 1) along the left edge of the artifact stack, starting just below the session card's bottom edge.
- Chevron rotates 180° (becomes chevron-up) to indicate the expanded state.

## Interaction model

### Tap zones on the session card

Two distinct tap targets:

1. **Chevron tap zone** (44pt invisible square around the visible 24pt chevron glyph, extending into the card padding). ONLY appears when the session has at least one artifact. Tap → toggle the artifact stack expand state. Stops propagation; does NOT trigger Studio navigation.
2. **Card body** (everything else — filmstrip, count glyph, title row, sub-text). Tap → existing behaviour: navigate into Studio mode for this session.

The chevron tap zone uses Apple HIG minimum hit area (44pt) even though the visible glyph is smaller — necessary because the chevron sits adjacent to the highly-touchable card body. Hover/active state on the chevron tap zone gives a subtle coral tint (0.08 alpha) to telegraph the tap zone boundary.

### Accordion behaviour

- Tapping the chevron on session A expands A.
- Tapping the chevron on session B while A is expanded: A collapses (its artifact cards stagger out, rail fades out, peek slides back in, chevron rotates back); B expands. The full collapse-then-expand cycle is sequenced, not simultaneous (~180ms collapse, then immediate expansion of B).
- Tapping the chevron on session A while A is already expanded: A collapses.
- Tap on a session card BODY (not chevron) while any other session is expanded: the open session collapses, then the tapped session opens Studio. (Body tap should not interrupt the collapse animation; if practitioner is mid-collapse, the Studio navigation can dispatch immediately.)

### Tap behaviour on artifact cards

Per PR #548's existing implementation (preserved):

- **Workout plan card** → opens the existing in-app preview deck.
- **Handout card** → opens a full-screen WebView at `https://session.homefit.studio/h/{planId}` (or staging twin).
- **Future-kind card (e.g., class video before that kind exists)** → fires a "Coming soon" SnackBar (NOT a modal — per R-01).

## Animation timings

All easings reference `cubic-bezier(.2, .9, .25, 1.2)` (the "snappy spring with slight overshoot" curve already in use across the app per the existing PR #548 work).

| Phase | Duration | Easing | Notes |
| --- | --- | --- | --- |
| Sibling cards push down | 140ms | ease-out | Linear feel; cards translate down to make room. |
| Peek card lift + fade | 220ms | snappy spring | translateY(-6px) + scale(0.98), opacity 0.92 → 0. Starts at t=0. |
| Artifact cards stagger in | 320ms each, 50ms delay per card | snappy spring | translateY(-8px) → 0, opacity 0 → 1. Card N starts at t = 50ms + 60ms × (N-1). |
| Coral rail draw | 380ms | snappy spring | scaleY 0 → 1 from top. Starts at t=30ms (slight delay so siblings push down first). |
| Chevron rotation | 280ms | snappy spring | 0deg → 180deg (rotates the down-glyph to up-glyph). Starts at t=0. |

Collapse animations are time-reversed with slightly faster timings (cut all durations to ~70%) so the collapse feels more responsive than the expand.

`prefers-reduced-motion: reduce` overrides:
- Peek lift, rail draw, stagger all become instant (0ms duration).
- Sibling push-down becomes 0ms (snap).
- Chevron rotation stays (~140ms, still snappy) — it's a directional indicator, not decoration.

## Edge cases

- **Brand-skin subscribed practice** — front (first) artifact card uses the practice's brand color instead of coral for its accent border. Rail color stays coral. Reasoning: the rail is the structural parent-child indicator; only the artifact card's own chrome reflects the brand-skin state.
- **Brand-skin in grace** — front artifact card chrome shifts to a dimmed brand color. Rail unchanged.
- **Single artifact** — expand still works the same; just one artifact card animates in. Front-card coral accent applies.
- **Many artifacts (5+)** — stagger continues at 50ms per card. Total expansion animation tops out at ~480ms even for 8 artifacts (the last cards animate in toward the end). If the artifact count exceeds the screen height, the surface should not auto-scroll — let the practitioner scroll naturally.
- **Unpublished session in the list** — no peek, no chevron, no expand affordance. Tap = enter Studio (today's behaviour).
- **Web `/me`** — the consumer might have artifacts claimed from multiple practitioners. Each bundle (one per source session) still gets the same accordion treatment. The "Use as template for a client" CTA from PR #548 stays on owner-viewed bundles, lives INSIDE the expanded artifact area (not on the collapsed session card).

## R-10 parity

R-10 (mobile ↔ web player parity) historically applies to player/consumption surfaces only. The redesign explicitly applies to consumption-side `/me` (web) AS WELL AS configuration-side ClientSessionsScreen + My Workouts (mobile), so all three need to ship the same UI in the same wave.

The cross-surface implementation must use a shared design token reference (the existing CSS variable system on web, the existing theme.dart on mobile). Visual divergence between mobile and web `/me` is a bug, not a feature.

## Implementation pointers

Not a plan — that's the writing-plans skill's job — but enough breadcrumbs that the implementer doesn't have to re-derive the surface map.

### Mobile (Flutter)

- Shared widget: `app/lib/widgets/session_card.dart` (create if it doesn't exist; refactor into shared widget if two near-identical implementations exist on ClientSessionsScreen + My Workouts).
- New stateful widget: `app/lib/widgets/session_card_with_artifacts.dart` (or extend `session_card.dart` if the new behaviour is opt-in via a flag).
- State management for accordion: a parent-level controller on each screen tracks "which session ID is currently expanded" and the session-card widget consumes it.
- Animation: Flutter `AnimatedSize` for the expand/collapse vertical reflow, `AnimatedOpacity` + `Transform.translate` for the artifact-card stagger. Use the existing `ArtifactCardWidget` from PR #548 as the artifact card visual — only the CONTAINER changes.
- Artifact data source: same query/RPC PR #548 used (`get_session_artifacts` or equivalent). Don't re-write the data layer.

### Web (`web-player/me.*`)

- New CSS in `me.css`: `.session-row`, `.session-row .peek`, `.session-row.expanded .artifact-stack-inner::before` (rail), `.artifact-card` overrides for full-width.
- JS in `me.js`: replace the existing fanned-deck rendering with the vertical accordion. Accordion state lives on the parent `.sessions-list` container.
- The shared `hero_resolver.js` already returns the correct image for the artifact-card thumbnails — no change there.
- Server-side `get_consumer_artifacts` RPC (or whatever PR #548 named it) returns the same shape; only the rendering changes.

### Mockup as canonical visual reference

`docs/design/mockups/2026-05-27-artifact-card-expansion.html` — interactive HTML mockup with click-to-toggle wiring. Open in browser to see the rest state, the expanded state, the tap-zone behaviour, and the animation timings. Implementer should match the mockup pixel-for-pixel on first pass.

## Migration from PR #548

PR #548 shipped:
- Studio fanned-deck zone (REMOVE).
- `/me` horizontal fanned-deck bundles (REPLACE with accordion).
- Artifact card visual widget — kind-pill, thumbnail, coral accent on front card (KEEP and reuse).
- "Coming soon" SnackBar for future-kind taps (KEEP).
- "No Share button anywhere on /me" — load-bearing for monetization (KEEP — the redesign does not re-introduce a Share button).
- "Use as template for a client" CTA on owner-viewed bundles (KEEP — moves into the expanded artifact area).
- Brand-skin awareness on the front artifact card (KEEP).

Net: the artifact-card visual layer survives. The container/layout above it is replaced. Estimate: substantial but bounded — the visual widget that took the most design iteration in #548 is the part being preserved.

## Out of scope

- Adding new artifact kinds (workout plan + handout is the current set; class video is a "coming soon" pill).
- Changing the artifact data model.
- Changing the publish flow.
- Changing Studio in any way (the redesign explicitly does NOT touch Studio).
- Per-exercise artifact stacking (deferred — earns its way in only when per-exercise artifact kinds exist).
- The "Use as template" deep-link handler in the iOS app — already a separate stack item from the parallel session's discussion. The CTA fires the URL; intercepting it is a separate work item.

## Open questions

- Should the rail color shift to the practice's brand-skin color when subscribed (parity with the front artifact card), or stay coral (structural indicator)? Default: stay coral.
- Should the expanded state survive scroll? If the practitioner scrolls past the expanded session, on scroll-back the session is still expanded — or should scroll-out auto-collapse? Default: state survives scroll.
- Should the chevron tap zone show a hover/press background on web (where there's no touch but there's a cursor) at all, or stay pristine? Default: show the same coral tint on web for cursor users.

## Iteration log — 2026-05-27 afternoon

After PR #549 (`273d774`) shipped the initial accordion implementation, Carl
device-QA'd on iPhone CHM and surfaced four refinements. The following
supersede earlier sections where they conflict.

### Rail visibility — inset 10dp gutter

The original spec had artifact cards full-width and flush with the session
card's left edge. On device the rail was obscured by the card chrome (visible
only as a 1-pixel sliver). Resolution: artifact cards are now inset 10dp from
the session card's left edge. The rail lives in the resulting 13dp gutter
(10dp visible space + 3dp rail width), fully exposed and unobscured. The
cards are still substantial — this is a meaningfully smaller inset than the
16-20dp child-card pattern that was originally rejected.

### Tap-affordance — two stacked action buttons

The single chevron-only tap zone made the card body feel like a passive
toggle rather than a tappable Studio entry. Resolution: two small stacked
action buttons on the right end of the card-body row, each with an icon
and a directional arrow:

- **Top button — Studio entry**: pencil glyph + chevron-right (`›`). Always
  visible on every session card. Tap fires the same enterStudio action as
  the card body. Existing "tap card body to enter Studio" behaviour is
  preserved (the button is an additional explicit affordance, not a
  replacement).
- **Bottom button — Artifacts expand**: stacked-cards glyph + chevron-down
  (`▾`). Visible only when the session has at least one artifact. Chevron
  rotates 180° on expand. Tap toggles the artifact stack.

The single-chevron expand affordance from earlier in this spec is REPLACED
by the bottom button described above. Hit-zone extension via negative margin
gives each button a 44pt-equivalent vertical hit area. Per-button hover and
active states give visual feedback distinct from each other.

Order matters: Studio on top (primary action, mirrors the card body
gesture), Artifacts on bottom (down-chevron naturally points to where the
artifact stack will appear below the card).

### Animation — slowed for "deal of cards" rhythm

Earlier timings (140ms sibling push-down, 320ms artifact stagger, 50ms
per-card delay) felt too fast on device — cards just appeared rather than
seeming to slide out from behind the session card. Resolution: new timings
that give the eye time to read the "shuffling" motion.

| Phase | New duration | Was | Notes |
| --- | --- | --- | --- |
| Sibling cards push down | 200ms | 140ms | ease-out |
| Peek card lift + fade | 380ms | 220ms | snappy spring |
| Container grow | 540ms | 360ms | snappy spring |
| Artifact card slide | 820ms each | 320ms | snappy spring `cubic-bezier(.2,.85,.25,1.18)` |
| Per-card stagger | 140ms | 50ms | Cards land 80 / 220 / 360 / 500 / 640ms after expand starts |
| Coral rail draw | 640ms | 380ms | 60ms head-start delay (was 30ms) |
| Chevron rotate | 280ms | 280ms | unchanged |

Total time for the last (4th) card to land: ~1.46s. Reduced-motion override
unchanged — all motion becomes instant except the chevron rotate.

The cards are clipped behind the session card via `overflow: hidden` on the
artifact-stack-inner container, with starting translateY values proportional
to stack depth (card 1: -180%, card 2: -280%, card 3: -380%, card 4: -480%)
so deeper cards travel farther. This reinforces the "deck of cards
underneath" mental model.

### Companion artefacts (updated)


- **Interactive mockup**: `docs/design/mockups/2026-05-27-artifact-card-expansion.html`
- **Stack file pointer**: `docs/test-scripts/2026-05-27-stack.md` (the queue Carl drives from)
- **PR being superseded**: [#548](https://github.com/carlheinmostert/TrainMe/pull/548) — "feat(artifact-system): artifact stacking UI for Studio + My Workouts"
- **Test script that becomes obsolete**: `docs/test-scripts/2026-05-27-artifact-stacking.md` — the 29-item device-QA list for #548. Will be marked as superseded once the redesign ships.
