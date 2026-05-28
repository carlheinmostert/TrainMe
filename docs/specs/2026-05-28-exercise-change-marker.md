# Spec — Per-exercise "unpublished changes" marker (Studio)

Surface, on each Studio exercise card, whether that specific exercise has content edits that have not yet been published. Today the only "dirty" signal is session-wide (`Session.hasUnpublishedContentChanges`); the practitioner cannot tell WHICH exercises they changed since the last publish, which is confusing when reconciling what a re-publish will ship.

Decision origin: 2026-05-28 session. Carl chose per-exercise markers (over session-level-only) as the surface. This spec is for a FRESH session to execute — it was deliberately NOT crammed into the long session that surfaced it, because it requires a schema migration plus stamping every edit site, and a half-stamped marker would lie.

> **Reorder reversal (2026-05-28, execution session).** The original draft below proposed that reorder must NOT light the spine. Carl reversed this during execution: **reorder DOES light the spine.** Rationale (Carl): order is a published-visible property of the whole plan — reordering means the published artifacts are now out of position and the plan needs republishing, so on a drag-reorder *every* exercise in the session lights up ("everything is out of position"). The relevant sections below (Edit sites to stamp, Acceptance criterion 4) have been updated to reflect this.

## Table of Contents

- [Goal](#goal)
- [Data model change](#data-model-change)
- [Detection rule](#detection-rule)
- [Edit sites to stamp](#edit-sites-to-stamp)
- [Marker visual](#marker-visual)
- [Clear-on-publish behaviour](#clear-on-publish-behaviour)
- [Edge cases](#edge-cases)
- [Out of scope](#out-of-scope)
- [Acceptance criteria](#acceptance-criteria)
- [File map](#file-map)

## Goal

Surface "has unpublished edits" with ONE consistent visual — a coral left-edge spine (Option A, locked 2026-05-28) — applied at TWO levels:

1. **Session card** (My Workouts + ClientSessionsScreen session lists): spine when ANY exercise in the session has unpublished edits. Uses the EXISTING `Session.hasUnpublishedContentChanges` signal — no new schema needed for this level.
2. **Exercise card** (Studio exercise list): spine on each exercise whose own content changed since last publish. Needs the new per-exercise `lastEditedAt` column.

Both render the identical 4px coral left-edge spine so the practitioner connects "this workout is dirty" (session list) to "these specific exercises are dirty" (inside Studio) at a glance. The session spine is effectively the OR of its exercise spines. All spines clear on publish.

Marker visual is LOCKED to Option A (coral left-edge spine). The "Edited" pill and corner-dot alternatives are rejected (pill costs vertical space; dot too easy to miss in a list). See the mockup.

## Data model change

Add a nullable `lastEditedAt` (epoch-ms) to the exercise model + local store. Cloud mirror is OPTIONAL and probably unnecessary — the marker is a practitioner-side authoring aid that only matters on the editing device; the cloud `exercises` table does not need it for v1. Decide during implementation, but default to local-only to keep the migration small.

- `ExerciseCapture` (`app/lib/models/exercise_capture.dart`): add `final DateTime? lastEditedAt;` + wire through the constructor, `copyWith`, `toMap`/`fromMap` (epoch-ms int column `last_edited_at`).
- SQLite (`app/lib/services/local_storage_service.dart`): bump `_dbVersion` 49 → 50 (staging had already advanced to 49 via the artifact-system Wave 5 migration; the implementation went to 50 rather than the 48→49 this draft originally assumed); add `ALTER TABLE exercises ADD COLUMN last_edited_at INTEGER` in the migration ladder. Local-only (do NOT add to the Supabase mirror unless a concrete need surfaces — note this explicitly per `feedback_offline_first_pull_branches` reasoning, but here there is no cloud read of it).

## Detection rule

**Session card** (no new schema — already available):

```
session.hasUnpublishedContentChanges == true
```

(which already encodes `isPublished && lastContentEditAt.isAfter(sentAt)`). Render the spine on the session-list card when true.

**Exercise card** shows the spine when:

```
exercise.lastEditedAt != null
  && session.isPublished
  && session.sentAt != null
  && exercise.lastEditedAt.isAfter(session.sentAt)
```

- `session.isPublished == false` → NO markers (never-published session; the whole thing is "new" and that is communicated by the Publish CTA, not per-card noise). Mirrors `Session.hasUnpublishedContentChanges` which short-circuits on `!isPublished`.
- This keeps the per-exercise rule consistent with the existing session-wide rule (`lastContentEditAt` vs `sentAt`), just at exercise granularity.

## Edit sites to stamp

`lastEditedAt = DateTime.now()` must be stamped whenever an exercise's PUBLISHED-VISIBLE CONTENT changes. The cleanest implementation is a single helper (e.g. `exercise.copyWithContentEdit({...})` that sets `lastEditedAt` alongside the field change) used at every content-edit call site, rather than blanket-stamping inside `saveExercise` (which is also called for non-content writes like reorder + position and would over-mark).

Content edits that MUST stamp (enumerate + verify each during implementation — missing one makes the marker lie):
- reps / sets / hold seconds / hold position
- notes
- video reps-per-loop, inter-set rest
- custom duration
- soft-trim in/out offsets
- preferred treatment
- body-focus toggle
- include-audio toggle
- circuit assignment / circuit name (if it changes the exercise row)
- swipe-to-duplicate creates a NEW exercise → its `lastEditedAt` = creation time (so it marks on an already-published session) — handled naturally if the duplicate sets `lastEditedAt = now`.
- **reorder / drag-to-reposition (REVERSED 2026-05-28 — see note at top).** On a user-initiated drag-reorder, stamp `lastEditedAt = now` on EVERY exercise in the session, so the whole list lights up. Order is a published-visible property of the plan; reordering invalidates the published layout and requires a republish, so the entire session is "out of position". This is the rare case; over-lighting is correct, not noise.

Edits that must NOT stamp:
- thumbnail regeneration / `thumbnailsDirty` (derived asset, not authored content)
- archive / upload bookkeeping (`archivedAt`, `rawArchiveUploadedAt`)
- side-effect position reindexing from delete/duplicate-insert (only the *user-initiated drag-reorder* stamps-all; the duplicated row itself gets `now`, but deleting an exercise does not relight its surviving siblings — the session-level structural signal already covers "structure changed").

Anchor sites in `app/lib/screens/studio_mode_screen.dart`: `_updateExercise` (~line 1136), the per-field edit handlers, and the editor sheet's save path. `saveExercise` / `saveExercises` in `local_storage_service.dart` just persist whatever the model carries — they should NOT auto-stamp.

## Marker visual

LOCKED: Option A — a 4px coral left-edge spine (`#FF6B35`, `border-radius: 0 2px 2px 0`), painted full-height down the left edge of any card with unpublished edits. Identical treatment on the exercise card and the session card. Mockup: `docs/design/mockups/2026-05-28-exercise-change-marker.html`.

Two render sites:
- **Session card** — the session-list card widget (used by My Workouts + ClientSessionsScreen). Spine gated on `session.hasUnpublishedContentChanges`. The cards have a filmstrip background + veil; the spine sits ABOVE the veil (higher z-index) so it stays coral-crisp over imagery.
- **Exercise card** — the Studio exercise-list card widget. Spine gated on the per-exercise detection rule below.

Implementation tip: factor the spine into one shared widget/decoration (e.g. a `ChangeSpine` overlay or a reusable `BoxDecoration` border) used by both card widgets, so the treatment cannot drift between levels (it must stay consistent — that is the whole point of the design).

## Clear-on-publish behaviour

Publishing stamps a new `session.sentAt` (already happens in the publish flow). After publish, every exercise's `lastEditedAt` is older than the new `sentAt`, so all markers clear automatically — no per-exercise reset write needed. Verify the publish flow updates `sentAt` (it does today for the version bump). No extra work beyond confirming.

## Edge cases

- **Offline-first:** `lastEditedAt` is written through the same local-write path as other edits; no `pending_ops` cloud sync needed (local-only column). The marker is correct offline.
- **Reinstall / fresh pull:** if the column is local-only and the device reinstalls, exercises pulled from cloud have `lastEditedAt == null` → no markers until next local edit. Acceptable (a freshly-pulled published session legitimately has no local edits).
- **Migration backfill:** existing rows get `last_edited_at = NULL` on the ALTER. NULL → no marker. Correct (we have no edit history for pre-migration rows; treat them as "clean since last publish").

## Out of scope

- Cloud mirroring of `lastEditedAt`.
- Surfacing the marker on the client web player or any consumption surface (this is practitioner authoring config — `feedback_consumption_vs_config_surfaces`; mobile Studio only, no R-10 web parity).
- Diffing WHAT changed (just that it changed).

## Acceptance criteria

1. Edit a single exercise (e.g. change reps) on an already-published session → only THAT exercise card shows the spine; siblings do not. AND the session card (in My Workouts / client list) shows the spine.
2. Publish → all spines clear at BOTH levels.
3. Add a new exercise to an already-published session → the new exercise card shows the spine + the session card shows the spine.
4. Reorder exercises (drag-reposition) on an already-published session → EVERY exercise card lights the spine (everything is "out of position") AND the session card shows the spine. (Reversed 2026-05-28 — was previously "no spine from reorder".)
5. A never-published session shows no spine at either level regardless of edits.
6. Spines are correct offline.
7. The session-card spine and exercise-card spine are visually identical (4px coral left edge) — confirm they share one implementation.
8. `dart analyze` clean; SQLite migration 49→50 applies cleanly on an existing install (existing rows backfill NULL → no exercise spines until next edit, but the SESSION spine still works immediately via the existing signal).

## File map

- `app/lib/models/exercise_capture.dart` — add `lastEditedAt` + copyWith/toMap/fromMap + a content-edit helper.
- `app/lib/services/local_storage_service.dart` — `_dbVersion` 49→50, migration, column in insert/update.
- `app/lib/screens/studio_mode_screen.dart` — stamp `lastEditedAt` at each content-edit site (NOT reorder/position).
- `app/lib/widgets/` — ONE shared spine widget/decoration consumed by BOTH the Studio exercise card AND the session-list card (so the treatment can't drift). The session card already lives in the widget used by My Workouts + ClientSessionsScreen (the filmstrip session card) — gate its spine on `session.hasUnpublishedContentChanges`. The exercise card gates on the per-exercise rule.
- `docs/design/mockups/2026-05-28-exercise-change-marker.html` — locked Option A shown at both levels.
- Test script under `docs/test-scripts/` covering the acceptance criteria (both levels).

Note (R-10): both surfaces are practitioner authoring config, NOT client consumption — mobile only, no web-player parity. The spine must never appear on the client web player.
