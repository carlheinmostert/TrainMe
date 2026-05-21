# Safe Mode completion — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the 6 deferred items from PR #389's Safe Mode rollout so the feature is end-to-end complete: upload swap, audit stamping, photo Safe Mode, fail-closed UX, SQLite crash recovery, CLAUDE.md update.

**Architecture:** Mobile-app + Supabase changes. No portal work. Wave touches `app/ios/Runner/VideoConverterChannel.swift`, `app/lib/services/conversion_service.dart`, `app/lib/services/upload_service.dart`, `app/lib/services/local_storage_service.dart`, `app/lib/models/exercise_capture.dart`, `app/lib/screens/capture_mode_screen.dart`, plus a Supabase migration widening `replace_plan_exercises`. Single PR against `staging` on branch `feat/safe-mode-completion` — **wait until `feat/public-profile-v2` has merged to staging** before opening this PR, to avoid file conflicts on the SQLite migration sequence.

**Tech Stack:** Flutter / Dart, iOS Swift native (Vision + AVFoundation), Supabase PostgreSQL 17, SQLite (sqflite).

**Spec:** [docs/specs/2026-05-21-safe-mode-completion-design.md](../specs/2026-05-21-safe-mode-completion-design.md)
**Predecessor PR:** #389 (Safe Mode Phase 1 + 2).

---

## File structure

### Modified files
- `supabase/migrations/<timestamp>_safe_mode_completion.sql` — widen `replace_plan_exercises` to accept + persist `safe_mode_active` + `captured_in_premises_id`.
- `app/lib/services/local_storage_service.dart` — SQLite v43 bump: add `exercises.safe_raw_file_path TEXT`.
- `app/lib/models/exercise_capture.dart` — add `safeRawFilePath` field.
- `app/ios/Runner/VideoConverterChannel.swift` — Vision miss-rate tracking + `processPhotoSafeMode` native method.
- `app/lib/services/conversion_service.dart` — persist `safe_raw_file_path`; surface `SafeModeRejection` on > 5% miss rate.
- `app/lib/services/upload_service.dart` — swap upload to `safe.mp4` when present + Safe Mode was active.
- `app/lib/screens/capture_mode_screen.dart` — listen for `SafeModeRejection`, show inline rejection toast.
- `app/lib/services/api_client.dart` — extend `replacePlanExercises` to pass new audit fields.
- `app/test/idempotent_migration_test.dart` — bump expected SQLite version to 43.
- `CLAUDE.md` — Safe Mode section folded in.
- `docs/test-scripts/2026-05-21-safe-mode.md` — new section K (items 83-92).

---

## Task 0: Pre-flight discovery

**Files:** none modified — capture state only.

- [ ] **Step 1: Capture `replace_plan_exercises` signature from staging**

Via Supabase MCP `execute_sql` against project `vadjvkmldtoeyspyoqbx`:

```sql
SELECT pg_get_functiondef(p.oid)
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname = 'public' AND p.proname = 'replace_plan_exercises';
```

Save verbatim. The function's parameter list + INSERT column list must be carried forward; the migration in Task 4 appends two new array params at the end and adds two columns to the INSERT.

- [ ] **Step 2: Confirm current SQLite version**

```bash
grep -n "_dbVersion" app/lib/services/local_storage_service.dart | head -3
```

Expected: `_dbVersion = 42` (after Public Profile v2 doesn't change this; the V2 wave does NOT touch SQLite). If Public Profile v2's wave bumps to 43, this plan moves to 44.

- [ ] **Step 3: Confirm exercise model already has `captured_in_premises_id` locally**

```bash
grep -n "captured_in_premises_id\|capturedInPremisesId" app/lib/models/exercise_capture.dart app/lib/services/local_storage_service.dart
```

Per PR #389 the column was added but may only live in cloud schema. If absent from SQLite, this plan also adds it.

- [ ] **Step 4: Commit pre-flight notes**

```bash
mkdir -p .claude/state/agent-notes
# Save signatures + version to .claude/state/agent-notes/safe-mode-completion-preflight.md
git add .claude/state/agent-notes/safe-mode-completion-preflight.md
git commit -m "chore: pre-flight for safe-mode-completion"
```

---

## Task 1: SQLite v43 migration

**Files:**
- Modify: `app/lib/services/local_storage_service.dart`
- Modify: `app/lib/models/exercise_capture.dart`
- Modify: `app/test/idempotent_migration_test.dart`

(If Public Profile v2 already moved SQLite to v43, this becomes v44. Adjust accordingly.)

- [ ] **Step 1: Bump `_dbVersion`**

```dart
// app/lib/services/local_storage_service.dart
static const _dbVersion = 43;  // was 42 — adds safe_raw_file_path for Safe Mode upload swap
```

- [ ] **Step 2: Add column + migration branch**

```dart
if (oldVersion < 43) {
  // 2026-05-21 — Safe Mode upload swap needs to know where the
  // converted safe.mp4 lives so the upload can substitute it for
  // the raw file in cloud. Local-only — not mirrored to Supabase.
  // NULL = no safe variant exists (Safe Mode was off or capture
  // pre-dates this column).
  await _addColumnIfMissing(db, 'exercises', 'safe_raw_file_path', 'TEXT');
}
```

If Task 0 Step 3 found `captured_in_premises_id` missing locally, add it in the same branch:

```dart
  await _addColumnIfMissing(db, 'exercises', 'captured_in_premises_id', 'TEXT');
  await _addColumnIfMissing(db, 'exercises', 'safe_mode_active', 'INTEGER NOT NULL DEFAULT 0');
```

- [ ] **Step 3: Extend `ExerciseCapture` model**

```dart
// app/lib/models/exercise_capture.dart
final String? safeRawFilePath;
// + add to constructor, copyWith, toMap, fromMap, equality, hashCode.
```

- [ ] **Step 4: Update `idempotent_migration_test.dart`**

```dart
expect(version.first['user_version'], 43);  // or 44 if shifted
```

- [ ] **Step 5: Commit**

```bash
git add app/lib/services/local_storage_service.dart app/lib/models/exercise_capture.dart app/test/idempotent_migration_test.dart
git commit -m "feat(mobile): SQLite v43 adds safe_raw_file_path for Safe Mode upload swap"
```

---

## Task 2: VideoConverterChannel — Vision miss-rate + photo support

**Files:**
- Modify: `app/ios/Runner/VideoConverterChannel.swift`

- [ ] **Step 1: Track Vision miss rate in SafeModeProcessor**

In the existing `SafeModeProcessor` class, add two stored properties:

```swift
private var framesTotal: Int = 0
private var framesMissed: Int = 0
```

In the per-frame loop, after `VNDetectHumanRectanglesRequest` resolves:

```swift
framesTotal += 1
if observations.isEmpty || largestBoundingBox == nil {
    framesMissed += 1
    // existing soft-skip behaviour (write the original frame to safe writer or leave un-blurred)
}
```

After `safeWriter.finishWriting`, expose the miss rate via a public accessor:

```swift
var missRate: Double {
    framesTotal == 0 ? 0.0 : Double(framesMissed) / Double(framesTotal)
}
```

- [ ] **Step 2: Surface miss rate in convertVideo result**

In `convertVideo`'s result payload (the existing `result(["safeOutputPath": ..., "safeFramesProcessed": ...])` line):

```swift
result([
    // ... existing keys ...
    "safeOutputPath": safeProcessor?.outputPath,
    "safeFramesProcessed": safeProcessor?.framesTotal ?? 0,
    "safeFramesMissedRate": safeProcessor?.missRate ?? 0.0,
])
```

- [ ] **Step 3: New native method `processPhotoSafeMode`**

After the existing `processPhotoBodyFocus` (or equivalent), add:

```swift
case "processPhotoSafeMode":
    guard let args = call.arguments as? [String: Any],
          let srcPath = args["srcPath"] as? String,
          let destPath = args["destPath"] as? String else {
        result(FlutterError(code: "BAD_ARGS", message: "src + dest required", details: nil))
        return
    }
    do {
        let processor = try SafeModeProcessor.singleFrame(srcPath: srcPath, destPath: destPath)
        result([
            "destPath": destPath,
            "safeFramesProcessed": processor.framesTotal,
            "safeFramesMissedRate": processor.missRate,
        ])
    } catch {
        result(FlutterError(code: "PHOTO_SAFE_FAILED", message: "\(error)", details: nil))
    }
```

Add a static factory on `SafeModeProcessor` that takes a single CGImage / UIImage path and applies the same composite logic as the per-frame loop but on one frame.

- [ ] **Step 4: Commit**

```bash
git add app/ios/Runner/VideoConverterChannel.swift
git commit -m "feat(mobile): Safe Mode photo support + Vision miss-rate tracking"
```

---

## Task 3: ConversionService — persist path + surface rejection

**Files:**
- Modify: `app/lib/services/conversion_service.dart`

- [ ] **Step 1: Define the rejection exception type**

```dart
// At top of conversion_service.dart or in a sibling file.
class SafeModeRejection implements Exception {
  final String exerciseId;
  final double missRate;
  SafeModeRejection(this.exerciseId, this.missRate);
  @override
  String toString() => 'SafeModeRejection($exerciseId, missRate=${(missRate * 100).toStringAsFixed(1)}%)';
}

const double kSafeModeMaxMissRate = 0.05;
```

- [ ] **Step 2: In `_convertVideo` success branch, check miss rate**

```dart
final missRate = (result['safeFramesMissedRate'] as num?)?.toDouble() ?? 0.0;
final safePath = result['safeOutputPath'] as String?;

if (safePath != null) {
  if (missRate > kSafeModeMaxMissRate) {
    // Above threshold — reject this capture.
    // Delete the partial files locally.
    await _deleteSafely(safePath);
    await _deleteSafely(linePath);
    await _deleteSafely(segmentedPath);
    await _deleteSafely(maskPath);
    // Bubble up so capture_mode_screen can show the toast + remove the row.
    throw SafeModeRejection(exerciseId, missRate);
  }
  // Below threshold — persist the safe path to SQLite for the upload swap.
  await _storage.updateExercise(
    exerciseId,
    {'safe_raw_file_path': safePath},
  );
}
```

- [ ] **Step 3: Same handling for photo path**

Where the existing photo conversion completes:

```dart
if (safeModeActive) {
  final photoResult = await _channel.invokeMethod('processPhotoSafeMode', {
    'srcPath': rawPath,
    'destPath': '${exerciseDir}/${exerciseId}_safe.jpg',
  });
  final missRate = (photoResult['safeFramesMissedRate'] as num?)?.toDouble() ?? 0.0;
  if (missRate > kSafeModeMaxMissRate) {
    await _deleteSafely(photoResult['destPath'] as String);
    throw SafeModeRejection(exerciseId, missRate);
  }
  await _storage.updateExercise(exerciseId, {'safe_raw_file_path': photoResult['destPath']});
}
```

- [ ] **Step 4: Commit**

```bash
git add app/lib/services/conversion_service.dart
git commit -m "feat(mobile): persist safe path + reject capture above 5% miss"
```

---

## Task 4: Capture screen — rejection toast

**Files:**
- Modify: `app/lib/screens/capture_mode_screen.dart`

- [ ] **Step 1: Catch `SafeModeRejection` from ConversionService listener**

Wherever the screen subscribes to the ConversionService stream (or the result futures), add:

```dart
} on SafeModeRejection catch (e) {
  // Discard the exercise row already created at capture time.
  await _storage.deleteExercise(e.exerciseId);
  // Show inline toast — no modal (R-01).
  if (mounted) {
    _showSafeRejectionToast();
  }
}
```

- [ ] **Step 2: Inline toast helper**

```dart
void _showSafeRejectionToast() {
  setState(() {
    _toast = _ToastState(
      message: "Safe Mode couldn't track everyone — try a steadier shot or better lighting.",
      kind: _ToastKind.error,
    );
  });
  // Auto-dismiss after 4 seconds.
  Future.delayed(const Duration(seconds: 4), () {
    if (mounted) setState(() => _toast = null);
  });
}
```

Render the toast as a coral-bordered overlay near the top of the viewfinder. Match the existing peek-overlay coral border treatment (see `feedback_active_only_motion.md` style).

- [ ] **Step 3: Commit**

```bash
git add app/lib/screens/capture_mode_screen.dart
git commit -m "feat(mobile): inline rejection toast for Safe Mode miss-rate over 5%"
```

---

## Task 5: Supabase migration — widen `replace_plan_exercises`

**Files:**
- Create: `supabase/migrations/<timestamp>_safe_mode_completion.sql`

Use the pre-flight signature capture. Append two new array params at the end of the existing parameter list — positional compat preserved. Add the two columns to the INSERT column list. Every other column in the existing INSERT preserved verbatim.

- [ ] **Step 1: Write migration header + the new RPC body**

```sql
BEGIN;

-- ============================================================================
-- Safe Mode completion — replace_plan_exercises widened to stamp
-- safe_mode_active + captured_in_premises_id per exercise on publish.
-- ============================================================================

-- ... PASTE THE EXISTING DEFINITION FROM PRE-FLIGHT STEP 1 ...
-- ...append two new array parameters at the end:
--   p_safe_mode_active boolean[] DEFAULT NULL,
--   p_captured_in_premises_id uuid[] DEFAULT NULL
-- ...and add to the INSERT column list:
--   safe_mode_active = coalesce(p_safe_mode_active[idx], false),
--   captured_in_premises_id = p_captured_in_premises_id[idx]
-- Every existing column STAYS in its current position.

COMMIT;
```

- [ ] **Step 2: Validate locally**

```bash
docker run --rm -d --name sm-completion -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=test -p 5499:5432 postgis/postgis:17-3.5
sleep 8
PGPASSWORD=postgres psql -h localhost -p 5499 -U postgres -d test -f supabase/migrations/<file>.sql
docker rm -f sm-completion
```

- [ ] **Step 3: Commit**

```bash
git add supabase/migrations/<timestamp>_safe_mode_completion.sql
git commit -m "feat(db): replace_plan_exercises stamps safe_mode_active + premises_id"
```

---

## Task 6: UploadService — swap raw → safe in cloud upload

**Files:**
- Modify: `app/lib/services/upload_service.dart`
- Modify: `app/lib/services/api_client.dart`

- [ ] **Step 1: Adjust the raw-archive upload to pick safe variant when available**

Find the existing raw-archive upload block (writes to `raw-archive/{practice_id}/{plan_id}/{exercise_id}.mp4`). Before invoking the upload, decide which local path to use:

```dart
final localPath = exercise.safeRawFilePath ?? exercise.rawFilePath;
// safe.mp4 takes priority when it exists. Either way, the cloud key
// stays the same (raw-archive/{practice}/{plan}/{exercise}.mp4) — the
// player + web player request that key and get whichever variant landed.

await _supabase.storage
    .from('raw-archive')
    .upload(cloudKey, File(localPath), fileOptions: FileOptions(upsert: true));
```

- [ ] **Step 2: Plumb new audit fields through `replacePlanExercises` Dart binding**

```dart
// app/lib/services/api_client.dart
Future<void> replacePlanExercises(...) async {
  await _client.rpc('replace_plan_exercises', params: {
    // ... existing params ...
    'p_safe_mode_active': exercises.map((e) => e.safeModeActive).toList(),
    'p_captured_in_premises_id': exercises.map((e) => e.capturedInPremisesId).toList(),
  });
}
```

- [ ] **Step 3: Commit**

```bash
git add app/lib/services/upload_service.dart app/lib/services/api_client.dart
git commit -m "feat(mobile): upload swap + audit-field plumbing for Safe Mode"
```

---

## Task 7: CLAUDE.md update

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Add a "Safe Mode" section under "Architecture Principles" or near "Feature State"**

Concise — about 30 lines. Cover:
- What it is (geofenced bystander-blur capture mode)
- How premises polygons work
- Upload swap behaviour (safe.mp4 replaces raw.mp4 in cloud; local archive keeps original)
- Audit stamping (`safe_mode_active` + `captured_in_premises_id` on `exercises`)
- Fail-closed UX (5% Vision miss = reject + auto-discard)
- The `report_premises` flow as the abuse channel
- File references: `SafeModeProcessor.swift`, `safe_mode_service.dart`, `capture_mode_screen.dart`

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(claude): document Safe Mode end-to-end"
```

---

## Task 8: Test script section K + open PR

**Files:**
- Modify: `docs/test-scripts/2026-05-21-safe-mode.md`

- [ ] **Step 1: Append section K**

```markdown
## K. Safe Mode completion (queued for after Public Profile v2 lands)

- [ ] 83. Capture a video inside an enforced polygon → publish the plan → open the plan URL on the web player → bystanders are coral-silhouetted in ALL treatments (line, B&W, original).
- [ ] 84. The cloud raw-archive key for the published exercise contains the safe.mp4 bytes (verify via Supabase Studio → media bucket → raw-archive prefix).
- [ ] 85. The device's local archive at `{Documents}/archive/{exercise_id}.mp4` still has the ORIGINAL un-blurred bytes (not overwritten).
- [ ] 86. Portal `/audit` for that publish shows `safe_mode_active=true` + the premises name in the new audit column.
- [ ] 87. Capture a video pointing at a wall (no humans) → Vision miss-rate ~100% → inline coral-bordered toast appears: "Safe Mode couldn't track everyone — try a steadier shot or better lighting." Capture is auto-discarded; no row in Studio.
- [ ] 88. Capture a video inside the polygon with one or two missed Vision frames (e.g. quick motion) → miss rate <5% → capture is kept. safe.mp4 has gap frames soft-skipped.
- [ ] 89. Capture a photo inside the polygon → published plan shows coral-silhouetted bystanders in the photo treatment (line + B&W + original).
- [ ] 90. Capture outside any polygon → Safe Mode off, no banner, raw upload behaviour unchanged.
- [ ] 91. SQLite version on device reads 43 (verify via Settings → diagnostics if available, or via `sqlite3 raidme.db "PRAGMA user_version"` on a debug build).
- [ ] 92. CLAUDE.md now has a Safe Mode section under Architecture Principles.
```

- [ ] **Step 2: Commit**

```bash
git add docs/test-scripts/2026-05-21-safe-mode.md
git commit -m "docs(test-scripts): section K for safe-mode-completion"
```

- [ ] **Step 3: Push branch + open draft PR**

```bash
git push -u origin feat/safe-mode-completion
gh pr create --base staging --draft \
  --title "feat(mobile+db): Safe Mode completion — upload swap, audit, photo, fail-closed" \
  --body "$(cat <<'EOF'
## Summary
Per spec at \`docs/specs/2026-05-21-safe-mode-completion-design.md\`.

Closes the parking-lot items from PR #389: upload swap (safe.mp4 replaces raw.mp4 in cloud), audit stamping on publish, photo Safe Mode, fail-closed UX at 5% Vision miss-rate, local crash-recovery column, CLAUDE.md update.

## Test plan
See section K in \`docs/test-scripts/2026-05-21-safe-mode.md\` (items 83-92).
EOF
)"
```

---

## Self-review notes

This plan depends on Public Profile v2 having merged to staging first (because both touch the SQLite migration sequence, and conflicts would be tedious to resolve). The implementation sub-agent should wait for the V2 PR to merge before starting Task 1.

If V2's wave bumps SQLite to v43 (it doesn't per the V2 plan, but check at execution time), this wave shifts to v44.
