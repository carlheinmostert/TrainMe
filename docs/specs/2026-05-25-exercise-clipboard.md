# Exercise Clipboard — design

## Table of Contents

- [Summary](#summary)
- [Locked decisions](#locked-decisions)
- [Surfaces](#surfaces)
- [Data model](#data-model)
- [Behaviour](#behaviour)
  - [Copy](#copy)
  - [Paste](#paste)
  - [Deep-copy semantics](#deep-copy-semantics)
  - [Edge cases](#edge-cases)
- [Gesture inventory before / after](#gesture-inventory-before--after)
- [Implementation surface](#implementation-surface)
- [Out of scope at v1](#out-of-scope-at-v1)
- [CONTEXT.md addition](#contextmd-addition)
- [ADR worthiness](#adr-worthiness)
- [Open implementation questions](#open-implementation-questions)

## Summary

A transient, in-memory holding area that lets a practitioner copy exercises from any session they're editing (a real Client's session OR their own My Workouts session) and batch-paste them into the session they're currently in Studio mode of. Same practice only at v1. The clipboard's value compounds with the upcoming My Workouts surface — practitioners assemble custom plans by reaching into their personal library of self-captured exercises plus prior client sessions, without re-capturing what's already on disk.

Mock-up of all key visuals: [`docs/design/mockups/2026-05-25-exercise-clipboard.html`](../design/mockups/2026-05-25-exercise-clipboard.html).

## Locked decisions

| Id | Decision |
|---|---|
| **D1** | **Single-practice scope at v1.** Clipboard items can only be copied from and pasted into sessions within a single practice. Cross-practice paste (e.g. personal practice → "Sarah's Physio") deferred to a future wave. For solo practitioners (the common case) this is not a real limitation — their Self-client and real Clients all live in the same personal practice. |
| **D2** | **Pointer at copy, deep copy at paste.** Clipboard items are pointers `{source_exercise_id, source_session_id, display snapshot}`. The full deep-copy (media files duplicated, fresh UUIDs, new row inserted) runs at paste time. Pasted rows are fully independent of the source — edit hero / treatment / sets / weights without affecting the source. |
| **D3** | **In-memory only.** Clipboard clears on cold-start, crash, or process termination. No SQLite, no inspection chrome, no individual-item management surface. The clipboard is a transient tool. |
| **D4** | **Apple Mail multi-action swipe.** Partial right-swipe on a Studio card reveals two coral buttons: `[Copy]` `[Duplicate]`. Long right-swipe auto-commits **Copy** (the dominant action). Left-swipe = Delete (unchanged). New dependency: `flutter_slidable`. |
| **D5** | **Chip at top-right of the AppBar.** Visible only when count ≥ 1. Layout: `[📋 N ×]` — clipboard icon, count badge, separator, clear-all `×`. Mounted in Studio mode; remains visible during editor sheet display (sheet sits at ~85-95% per ADR-0019). |
| **D6** | **Copy available from two source surfaces.** (1) Studio card via swipe gesture per D4. (2) Editor sheet bottom AppBar — a `[📋 Copy]` button between the exercise name and the next-arrow, per the reachability inversion of ADR-0019. Paste is Studio-only. |
| **D7** | **Bottom sheet batch-paste, default-all-selected.** Tap chip → sheet opens with all items selected. Tap row to toggle. Primary CTA `Paste N items` pastes at the **end of the current session** in FIFO order. After paste: sheet auto-dismisses; items **stay** in clipboard (re-paste into another session is the headline value). `×` in header clears all. No per-item delete. |
| **D8** | **Deep-copy carry / reset rules** — see [Deep-copy semantics](#deep-copy-semantics) below. |
| **E1** | **Stale source = reactive pruning.** Clipboard observes exercise-deletion events and removes any items pointing to a deleted source immediately. Chip count decrements in real time. If the paste sheet is open, the dead row animates out. |
| **E2** | **Locked target = `Unlock to paste` integrated CTA.** When the current session is past the 14-day structural-edit grace (ADR-0016), the paste CTA reads `🔒 Unlock to paste · 1 credit`. Tap → existing 1-credit unlock bottom sheet → confirm → unlock and paste happen as one flow. |
| **Q10** | **Canonical term: "Clipboard"** with explicit *Avoid* disambiguation against the iOS pasteboard. |

## Surfaces

| Surface | Role | Notes |
|---|---|---|
| Studio card | Copy source | Swipe gesture per D4. |
| Editor sheet bottom AppBar | Copy source | Per-exercise Copy button. Sheet sits at ~88%; chip remains visible above. |
| Top-right chip | Chip lives here in Studio | Only mounted in Studio mode. Hidden everywhere else even though clipboard state remains in app memory. |
| Paste bottom sheet | Paste action | Opens on chip tap; closes on paste or backdrop tap. |

## Data model

In-memory only. No schema migration. No SQLite table.

```dart
class ClipboardItem {
  final String id;                  // local-only UUID
  final String sourceExerciseId;    // pointer
  final String sourceSessionId;     // pointer (for stale detection)
  final String? displayName;        // snapshot for chip / sheet render
  final String? displayThumbPath;   // snapshot for chip / sheet render
  final DateTime copiedAt;
}
```

Owned by a single `ClipboardService` (Dart class, app-singleton, ChangeNotifier) that exposes:
- `addItem(ExerciseCapture source, Session sourceSession)` — de-dupes by `sourceExerciseId`
- `removeItem(String itemId)` — unused in v1 UI but exposed for reactive pruning
- `clearAll()` — wired to chip `×` and paste sheet `× Clear all`
- `Stream<int> countStream` — drives chip visibility + badge
- `pasteAll({required Session target, required List<String> selectedItemIds})` — runs deep-copy machinery for each item, in selection order

Reactive pruning hook: `ClipboardService` subscribes to a deletion event stream on whichever surface today owns "exercise was just deleted" (most likely `LocalDbStorage.deleteExercise` or the session-edit code path). Wiring detail to be confirmed during implementation.

## Behaviour

### Copy

**From a Studio card:**

- **Long right-swipe** (full Dismissible-style threshold) auto-commits Copy. Card snaps back in place.
- **Partial right-swipe** holds the card in the revealed position; user taps `[Copy]` or `[Duplicate]`. Tapping outside the card dismisses the reveal. Tapping `Duplicate` runs the existing within-session duplicate path ([studio_mode_screen.dart:1075](../../app/lib/screens/studio_mode_screen.dart:1075)) unchanged.
- **Left-swipe** = Delete, unchanged.
- Rest periods (`mediaType: rest`) do not render a `[Copy]` button — the swipe-reveal omits it on rest rows.

**From the editor sheet:**

- A `[📋 Copy]` button in the reachability-inverted bottom AppBar, between the exercise name and the next-arrow.
- Tap → adds the currently-displayed exercise to the clipboard.
- Feedback: brief coral pulse on the button, light haptic. No SnackBar. When the sheet is dismissed, the chip animates in (or its count increments).

**Animation:**

The exercise's hero thumbnail shrinks into a coral particle and flies along a diagonal arc to the top-right chip. The chip pulses on landing; the count badge increments. Identical from both source surfaces so the user learns one visual language.

**De-duplication:**

`ClipboardService.addItem` is keyed by `sourceExerciseId`. Re-copying the same source is a no-op (chip pulses but count doesn't increase).

### Paste

- **Entry point:** tap the chip. Only the Studio mode surface mounts the chip, so paste is implicitly Studio-only.
- **Sheet content:** all items rendered as rows (`[✓] [thumb] [name] [source-session label]`). All checked by default. Tap a row to toggle.
- **CTA:** `Paste N items` updates as the user toggles. Tap to commit.
- **Insertion:** appended at the end of the current session, in FIFO order (oldest copied first).
- **Post-paste state:** sheet auto-dismisses. Items stay in clipboard (re-paste into another session is the headline value). Next time the sheet opens, all items are selected again (default-all-selected is the consistent expectation).
- **Reposition:** the existing reorderable list ([studio_mode_screen.dart:2214](../../app/lib/screens/studio_mode_screen.dart:2214)) handles any post-paste positioning. No drag-to-position from inside the sheet at v1.

### Deep-copy semantics

Mirror the existing `_duplicateExercise` machinery ([studio_mode_screen.dart:1075](../../app/lib/screens/studio_mode_screen.dart:1075)) generalised across sessions, with explicit rules per field.

**Carry — fields describing *what the footage is*:**

- Media files: `rawFilePath`, `convertedFilePath`, `thumbnailPath`, `archiveFilePath`, `segmentedRawFilePath`, `maskFilePath`, `safeRawFilePath` (Safe Mode variant) — full deep copies to a fresh exercise-id-scoped path.
- Thumbnail variants: `{originalId}_thumb_color.jpg`, `{originalId}_thumb_line.jpg` — copied to `{newId}_thumb_*` paths.
- Capture metadata: `name`, `notes`, `mediaType`, `prepSeconds`, `videoDurationMs`, `videoRepsPerLoop`, `aspectRatio`, `rotationQuarters`, `includeAudio`.
- Editing state: `startOffsetMs`, `endOffsetMs`, `preferredTreatment`.
- Sets / reps: full deep copy of the `sets` array, each with a fresh per-set UUID.
- **Safe Mode audit:** `safe_mode_active`, `captured_in_premises_id`. These describe the event of capture and must remain truthful wherever the row lands.
- **Self-verification:** `self_verified`. A true statement about the footage. Harmless when the target client isn't the user — publish-credit logic only checks `self_verified` when the target session's Client IS the user.

**Reset / re-derive — fields describing *where the row lives*:**

- `id` → fresh UUID.
- `sessionId` → target session's id.
- `position` → end of target session (computed post-insert).
- `createdAt` → now().
- `thumbnailsDirty` → `false` (variants are copied, not regenerated).

**Strip:**

- `circuitId` → `null`. Circuit membership is session-structural and does not survive cross-session paste. A future "Copy circuit" gesture could revisit this; v1 ships without it.

**Rest periods** are not copyable. The `[Copy]` button does not render on rest rows.

### Edge cases

| Case | Behaviour |
|---|---|
| Source exercise deleted between copy and paste | Reactive pruning — `ClipboardService` removes matching items immediately on the delete event. Chip count decrements. If the paste sheet is open, the dead row animates out. No paste-time toast needed (single-user, single-device, in-memory state means the race window is essentially zero). |
| Source session deleted | Same as above for every exercise in the deleted session. |
| Target session past 14-day grace (locked) | Paste CTA reads `🔒 Unlock to paste · 1 credit`. Tap → existing unlock bottom sheet → confirm → unlock + paste in one integrated flow. |
| Target client lacks consent for a treatment | Pasted row inherits `preferredTreatment` from source; playback consent is governed by the target Client's `video_consent`. If target client hasn't granted "Original", that treatment is locked on the new row until they do. Line drawing is always allowed (de-identified by pipeline). No paste-time warning at v1 — consent management is a separate practitioner action. |
| Same source exercise copied twice | No-op on the second copy. De-dupe keyed by `sourceExerciseId`. Chip pulses but count doesn't increment. |
| Same item pasted into two different sessions | Each paste creates an independent row with its own fresh UUID and its own deep-copied media files. Source unchanged. |
| Paste sheet open, user backgrounds the app, returns | State preserved within an app launch. If the app cold-starts (process killed by iOS), clipboard clears (D3). |
| Cross-practice attempt at v1 | Out of scope. Copy and paste are only available within sessions of the same practice. UI does not surface a cross-practice path. |

## Gesture inventory before / after

| Gesture | Before (today) | After |
|---|---|---|
| Right-swipe (any depth) | Duplicate in-session, single action | Long swipe = **Copy** (dominant). Partial swipe = reveal `[Copy] [Duplicate]`. |
| Left-swipe | Delete | Delete (unchanged) |
| Long-press card | (none) | (none — direct manipulation only) |

## Implementation surface

**New dependency:** `flutter_slidable` (multi-action swipe reveal — Flutter's built-in `Dismissible` is single-action-per-direction).

**New files:**

- `app/lib/services/clipboard_service.dart` — singleton `ChangeNotifier`, owns the in-memory item list, exposes addItem/clearAll/pasteAll.
- `app/lib/widgets/clipboard_chip.dart` — the top-right chip widget.
- `app/lib/widgets/paste_bottom_sheet.dart` — the paste sheet UI.
- `app/lib/widgets/clipboard_flight_animation.dart` — the particle-arc animation overlay.

**Modified files:**

- `app/lib/screens/studio_mode_screen.dart` — swap `Dismissible` for `Slidable` on exercise cards (only for non-rest rows). Wire `[Copy]` long-swipe + button to `ClipboardService.addItem`. Mount `ClipboardChip` in the AppBar. Handle locked-target CTA branch.
- The exercise editor sheet (file TBD during implementation — needs to be located) — add the Copy button to the reachability-inverted bottom AppBar.
- Wherever exercise deletion happens (likely `LocalDbStorage.deleteExercise` plus the Studio delete path) — emit a deletion event the clipboard subscribes to.

**Reused machinery:**

- The existing `_duplicateExercise` deep-copy file-copy helpers ([studio_mode_screen.dart:1075-1167](../../app/lib/screens/studio_mode_screen.dart:1075)) extract cleanly into a shared `cloneExerciseInto(targetSession)` function. Use this from the paste path so duplicate-in-session and paste-cross-session run the same code.
- The existing unlock-for-1-credit bottom sheet (called from the padlock chip elsewhere in Studio) — invoked from the paste sheet's `Unlock to paste` CTA path.

## Out of scope at v1

| Item | Why deferred |
|---|---|
| Cross-practice paste | Cross-tenancy media re-upload + consent semantics are non-trivial; not needed for solo practitioners (the common case). |
| Persistence across app restart | Carl's explicit "transient tool" stance. Surviving restart implies an inspection / management surface to build. |
| Per-item delete inside paste sheet | `×` Clear-all suffices for a transient tool. |
| Circuit-aware paste (re-create circuit when all siblings pasted) | Edge case; needs a separate "Copy circuit" gesture. |
| Copy of rest periods | Trivially reconstructable; session-structural, not reusable content. |
| Multi-device sync | Single-iPhone reality today; matches D3 transient stance. |
| Drag-and-drop from chip onto an insertion point | Bottom-sheet + end-of-session + manual reorder covers v1. |
| Surface badge / nudge when clipboard non-empty but user is outside Studio | Carl's chrome-minimalism preference: chip only appears where it can be acted upon. |

## CONTEXT.md addition

Add to the "Capture & playback" section (or its own micro-section near "Pill matrix"):

> **Clipboard**:
> An in-memory, transient, single-practice-scoped holding area for copied exercises. Items are pointers to source exercise rows; the deep copy happens at paste time. Items clear on app cold-start. Surfaced as a top-right coral chip in Studio mode when count ≥ 1. Not to be confused with the iOS pasteboard — the homefit Clipboard never touches the OS clipboard.
> _Avoid_: stash, tray, pasteboard, exercise bank (when speaking of the in-app feature)

## ADR worthiness

**Candidate ADR-0023 — Exercise Clipboard is transient by design.**

All three criteria pass:
- *Hard to reverse:* once practitioners learn "clipboard clears on app restart", flipping to persistent later changes the mental model.
- *Surprising without context:* a future engineer will reasonably ask "why doesn't this survive a cold-start, like every other piece of state?"
- *Result of a real trade-off:* persistent storage was the original recommendation and was rejected to avoid building inspection / management chrome ("It must be a transient tool").

Single-practice scope at v1 is **not** ADR-worthy. It's a forward-compatible deferral, not a hard architectural commitment — adding cross-practice later is additive, not breaking. Document in this spec; don't enshrine.

Author ADR-0023 alongside the implementation plan.

## Open implementation questions

These are for the implementation plan, not the brainstorm:

1. **State management library.** Is the app using bare `ChangeNotifier`, Provider, or Riverpod? Match existing convention rather than introducing a new pattern.
2. **Editor sheet file location.** Locate the per-exercise editor sheet implementation; add the Copy button to its bottom AppBar.
3. **Exercise deletion event source.** Confirm where exercise-deletions are observable — `LocalDbStorage.deleteExercise` is the likely candidate. If the codebase doesn't already emit events on delete, wiring this is part of the clipboard work.
4. **Animation library / approach.** Particle-arc to the chip — likely a custom `OverlayEntry` + `AnimationController` driving a `Transform`. No new dependency expected.
5. **`flutter_slidable` rollout scope.** Only Studio card list, or apply universally? Recommend Studio-only at v1; other lists (My Workouts, ClientSessions) stay on existing Dismissible to keep this PR focused.
