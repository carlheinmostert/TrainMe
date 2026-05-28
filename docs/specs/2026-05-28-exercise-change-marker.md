# Spec — Per-exercise "unpublished changes" marker (Studio)

Surface, on each Studio exercise card, whether that specific exercise has content edits that have not yet been published. Today the only "dirty" signal is session-wide (`Session.hasUnpublishedContentChanges`); the practitioner cannot tell WHICH exercises they changed since the last publish, which is confusing when reconciling what a re-publish will ship.

Decision origin: 2026-05-28 session. Carl chose per-exercise markers (over session-level-only) as the surface. This spec is for a FRESH session to execute — it was deliberately NOT crammed into the long session that surfaced it, because it requires a schema migration plus stamping every edit site, and a half-stamped marker would lie.

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

On the Studio exercise list, an exercise card shows a marker when `exercise.lastEditedAt` is after the session's last-publish timestamp (`session.sentAt`). The marker clears for all cards the moment the session is published. The signal is per-exercise content edits only.

## Data model change

Add a nullable `lastEditedAt` (epoch-ms) to the exercise model + local store. Cloud mirror is OPTIONAL and probably unnecessary — the marker is a practitioner-side authoring aid that only matters on the editing device; the cloud `exercises` table does not need it for v1. Decide during implementation, but default to local-only to keep the migration small.

- `ExerciseCapture` (`app/lib/models/exercise_capture.dart`): add `final DateTime? lastEditedAt;` + wire through the constructor, `copyWith`, `toMap`/`fromMap` (epoch-ms int column `last_edited_at`).
- SQLite (`app/lib/services/local_storage_service.dart`): bump `_dbVersion` 48 → 49; add `ALTER TABLE exercises ADD COLUMN last_edited_at INTEGER` in the migration ladder. Local-only (do NOT add to the Supabase mirror unless a concrete need surfaces — note this explicitly per `feedback_offline_first_pull_branches` reasoning, but here there is no cloud read of it).

## Detection rule

A card shows the marker when:

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

Edits that must NOT stamp (per the open-question resolution below):
- position / reorder (structural, not per-exercise content)
- thumbnail regeneration / `thumbnailsDirty` (derived asset, not authored content)
- archive / upload bookkeeping (`archivedAt`, `rawArchiveUploadedAt`)

Anchor sites in `app/lib/screens/studio_mode_screen.dart`: `_updateExercise` (~line 1136), the per-field edit handlers, and the editor sheet's save path. `saveExercise` / `saveExercises` in `local_storage_service.dart` just persist whatever the model carries — they should NOT auto-stamp.

## Marker visual

Mockup: `docs/design/mockups/2026-05-28-exercise-change-marker.html` (three options). Pick one with Carl before coding:
- **Option A — coral left-edge spine** (4px bar down the card's left edge). Recommended: scannable in a list, no content-space cost.
- **Option B — "Edited · not published" pill** under the sub-line. Most explicit, costs vertical space.
- **Option C — corner dot** with halo. Minimal, easy to miss in a long list.

## Clear-on-publish behaviour

Publishing stamps a new `session.sentAt` (already happens in the publish flow). After publish, every exercise's `lastEditedAt` is older than the new `sentAt`, so all markers clear automatically — no per-exercise reset write needed. Verify the publish flow updates `sentAt` (it does today for the version bump). No extra work beyond confirming.

## Edge cases

- **Offline-first:** `lastEditedAt` is written through the same local-write path as other edits; no `pending_ops` cloud sync needed (local-only column). The marker is correct offline.
- **Reinstall / fresh pull:** if the column is local-only and the device reinstalls, exercises pulled from cloud have `lastEditedAt == null` → no markers until next local edit. Acceptable (a freshly-pulled published session legitimately has no local edits).
- **Migration backfill:** existing rows get `last_edited_at = NULL` on the ALTER. NULL → no marker. Correct (we have no edit history for pre-migration rows; treat them as "clean since last publish").

## Out of scope

- Session-level "unpublished changes" badge (Carl chose per-exercise; a session badge could be a later add but is not in this spec).
- Cloud mirroring of `lastEditedAt`.
- Surfacing the marker on the client web player or any consumption surface (this is practitioner authoring config — `feedback_consumption_vs_config_surfaces`; mobile Studio only, no R-10 web parity).
- Diffing WHAT changed (just that it changed).

## Acceptance criteria

1. Edit a single exercise (e.g. change reps) on an already-published session → only THAT card shows the marker; siblings do not.
2. Publish → all markers clear.
3. Add a new exercise to an already-published session → the new card shows the marker.
4. Reorder exercises → no markers appear from the reorder alone.
5. A never-published session shows no markers regardless of edits.
6. Marker is correct offline.
7. `dart analyze` clean; SQLite migration 48→49 applies cleanly on an existing install (verify no data loss; existing rows backfill NULL).

## File map

- `app/lib/models/exercise_capture.dart` — add `lastEditedAt` + copyWith/toMap/fromMap + a content-edit helper.
- `app/lib/services/local_storage_service.dart` — `_dbVersion` 48→49, migration, column in insert/update.
- `app/lib/screens/studio_mode_screen.dart` — stamp `lastEditedAt` at each content-edit site (NOT reorder/position).
- `app/lib/widgets/` — the Studio exercise card widget renders the chosen marker, gated on the detection rule.
- `docs/design/mockups/2026-05-28-exercise-change-marker.html` — visual options (pick one first).
- Test script under `docs/test-scripts/` covering the acceptance criteria.
