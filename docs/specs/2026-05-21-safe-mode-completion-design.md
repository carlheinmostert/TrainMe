# Safe Mode completion — design

**Status:** approved 2026-05-21 (Carl) · queued for implementation after Public Profile v2 PR merges to staging
**Predecessor:** Safe Mode Phase 1 + Phase 2 shipped in PR #389. This design completes the parking-lot items the original sub-agent deferred.

## Table of contents

- [Scope](#scope)
- [Decisions captured](#decisions-captured)
- [Data model](#data-model)
- [Code paths](#code-paths)
- [Out of scope](#out-of-scope)

## Scope

Six items deliberately deferred from PR #389. Five mobile + DB code paths, one docs update:

1. **Upload swap** — when Safe Mode was active during a capture, `safe.mp4` replaces `raw.mp4` in the cloud raw-archive bucket. Local archive on the practitioner's device keeps the original.
2. **Audit stamping at publish** — `exercises.safe_mode_active` + `captured_in_premises_id` populated through the publish RPC.
3. **Photo Safe Mode** — single-frame coral-silhouette pass for photo captures (mirrors the existing video flow).
4. **Fail-closed UX** — threshold-based Vision-miss handling: reject capture + auto-discard + inline toast if >5% of frames fail Vision; below threshold, soft-skip is fine.
5. **Local crash-recovery column** — `safe_raw_file_path` on the SQLite `exercises` table so an in-flight upload swap can resume after app kill.
6. **CLAUDE.md update** — Safe Mode feature folded into the project doc so future sub-agents understand it.

## Decisions captured

| # | Decision |
|---|---|
| Upload swap | **Safe-only**: `safe.mp4` replaces `raw.mp4` in cloud; local archive untouched. |
| Audit stamping | Mechanical. `replace_plan_exercises` widened (column-preservation rule). |
| Photo Safe Mode | Mechanical. Mirror `processPhotoBodyFocus` shape. |
| Fail-closed UX | Threshold-based, **5%** miss-rate cap. Configurable constant. |
| Polygon abuse guard | **No server-side check** — trust + existing `report_premises` flow. (No code in this wave.) |
| Crash recovery | New SQLite column `safe_raw_file_path`. Local-only, no cloud mirror. |

## Data model

### Supabase (no change — already shipped in PR #389)

`exercises.safe_mode_active boolean` and `exercises.captured_in_premises_id uuid` already exist. This wave just *writes* them via the publish RPC.

### SQLite — version bump to v43

New column on `exercises`:

```sql
-- app/lib/services/local_storage_service.dart, _dbVersion 42 → 43
ALTER TABLE exercises ADD COLUMN safe_raw_file_path TEXT;
```

Used by ConversionService when a safe.mp4 is produced, read by UploadService at publish time to decide whether to swap. NULL = no safe variant exists (Safe Mode was off during this capture).

## Code paths

### Conversion path

`app/ios/Runner/VideoConverterChannel.swift`:

- Track Vision miss rate during `SafeModeProcessor` execution. Maintain two counters: `framesTotal`, `framesMissed`.
- After write completes, return `safeFramesMissedRate` (double 0-1) in the result payload alongside the existing `safeOutputPath` + `safeFramesProcessed`.
- New constant `kSafeModeMaxMissRate = 0.05`.

`app/lib/services/conversion_service.dart`:

- On video conversion success, if `safeOutputPath` is set AND `safeFramesMissedRate <= 0.05`, persist the path to SQLite via `exercises.safe_raw_file_path`.
- If `safeFramesMissedRate > 0.05`, fire a callback to the capture screen with a structured error (`SafeModeRejection`) so it can discard the capture + show inline toast.
- Below threshold, soft-skip stays as-is — gap frames in safe.mp4 are tolerated.

`app/lib/screens/capture_mode_screen.dart`:

- Listen for `SafeModeRejection` from ConversionService.
- On rejection: discard the in-progress exercise row, show coral-bordered inline toast at the top of the viewfinder: `"Safe Mode couldn't track everyone — try a steadier shot or better lighting"`. Toast auto-dismisses after 4s. No modal (R-01).

### Upload path

`app/lib/services/upload_service.dart`:

- When publishing an exercise where `safe_mode_active = true` (derived from `captured_in_premises_id IS NOT NULL` at capture time, persisted on the exercise row) AND `safe_raw_file_path IS NOT NULL`:
  - Upload `safe_raw_file_path` to `raw-archive/{practice_id}/{plan_id}/{exercise_id}.mp4` (same key as the raw would have used).
  - Do **not** upload the original `raw_file_path` to cloud.
  - The original raw file stays on the device's local archive (in `{Documents}/archive/`); practitioner can re-export via the existing local-export path if they ever need un-blurred footage of their own client.
- When Safe Mode was NOT active: upload behaviour unchanged.
- Idempotency-preserved: the existing skip-if-unchanged path still applies.

### Photo Safe Mode

`app/ios/Runner/VideoConverterChannel.swift`:

- New native method `processPhotoSafeMode(srcURL, destURL)`. Single-frame variant of the video path. Reuses `SafeModeProcessor` for the per-frame compositing.
- Returns `{ safeFramesProcessed: 0|1, safeFramesMissedRate: 0|1 }`.

Photo capture in Flutter:

- When Safe Mode is active and the capture is a photo, call the new native method after the existing line-drawing + body-focus passes complete.
- Same 5%-miss threshold (effectively 0% or 100% for a single-frame photo).
- Same rejection UX if miss-rate exceeds threshold.
- Persist `safe_raw_file_path` to SQLite same as videos.

### Publish path — audit stamping

`replace_plan_exercises` SECURITY DEFINER RPC:

- Pre-flight: capture current signature via `pg_get_functiondef` against staging Supabase `vadjvkmldtoeyspyoqbx`.
- Migration adds `p_safe_mode_active boolean[]` + `p_captured_in_premises_id uuid[]` as the LAST positional parameters (positional compat preserved for any caller still on the old signature — they pass NULL arrays).
- Body updates the INSERT/UPSERT column list to include the two new fields.
- Every other column in the existing parameter list + INSERT preserved verbatim (column-preservation rule).

Dart side:

- `ExerciseCapture` model already carries `captured_in_premises_id` from local capture time. Plumb both fields through `UploadService._exerciseToRpcRow` (or equivalent).

## Out of scope

Per Carl's decisions:

- Polygon abuse server-side guard (item 5 from parking lot). Rely on existing `report_premises` flow.
- Per-member visibility toggle for the public profile (was a stretch item; not in this wave).
- Re-export UI surface for the locally-archived original raw file (no new UI in this wave — practitioner can already access the archive directory directly via Files.app if iOS allows; if they can't, that's a separate UX request).
