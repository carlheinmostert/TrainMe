# Safe Mode — Accept Zero-Detection Captures (+ companion fixes)

Three changes bundled into one PR that all share the Safe Mode rejection code path in `app/lib/services/conversion_service.dart`:

1. **Accept zero-detection captures.** Captures where Vision detected NO humans at all (landscape, equipment, ceiling, empty room, outdoor demo) are accepted instead of rejected. They contain no personal information by definition.
2. **Telemetry on every accepted-empty event.** Logged to the existing `capture_audit_events` table with a scene fingerprint (no image bytes, just numerics). Surfaced in the portal audit feed + live-page 24h drawer. Lets Carl verify in production that the relaxation isn't silently letting real PII through.
3. **Fix the orphan-exercise-after-rejection bug.** When a capture IS rejected today, the safe variant + intermediate files get cleaned up but the exercise row sometimes persists with no content. Diagnose root cause and fix at root cause.

Branch this implements against: `fix/safe-mode-accept-zero-detection`
Target: `staging` (per the staging-promotion rule).

## Table of Contents

1. [Summary](#1-summary)
2. [Current behaviour](#2-current-behaviour)
3. [Problems being addressed](#3-problems-being-addressed)
4. [The rule (single, unified)](#4-the-rule-single-unified)
5. [Telemetry](#5-telemetry)
6. [Companion fix: orphan exercise after rejection](#6-companion-fix-orphan-exercise-after-rejection)
7. [Acceptance criteria](#7-acceptance-criteria)
8. [Implementation guidance](#8-implementation-guidance)
9. [Edge cases preserved](#9-edge-cases-preserved)
10. [Testing](#10-testing)
11. [Out of scope](#11-out-of-scope)
12. [Open questions](#12-open-questions)
13. [Appendix A — Agent brief](#13-appendix-a--agent-brief)

## 1. Summary

The Safe Mode fail-closed rule was over-defensive: it treated "Vision found nobody in the frame" identically to "Vision found someone and lost them." The first case (empty room, equipment, landscape) is no-PII by definition and should be accepted. The second case (partial detection failure) is the actual privacy risk and should keep getting rejected.

The other two changes are tightly coupled to the same rejection code path: instrumentation so we can see how often the new accept-empty path fires in production, and a fix for a long-standing bug where rejected captures leave behind empty exercise rows in Studio.

## 2. Current behaviour

When Safe Mode is active at the moment of capture (practitioner is inside an enforcing premises polygon — `practice_premises.enforced = true`):

1. **Capture** stamps the exercise row with `safe_mode_active = true` (locked at shutter time so post-capture polygon exits don't undo the intent).
2. **Native conversion** produces a `_safe.{mp4,jpg}` variant where every detected human OTHER than the recognised subject is painted coral.
3. **Native pipeline reports** `safeFramesMissedRate` — fraction of frames where Vision found zero humans.
4. **`app/lib/services/conversion_service.dart`** evaluates the result:

   ```dart
   if (result.safePath != null && result.safeMissRate > kSafeModeMaxMissRate) {
     await _deleteSafely(result.safePath);
     await _deleteSafely(result.convertedPath);
     // ...
     throw SafeModeRejection(exercise.id, result.safeMissRate);
   }
   ```

   `kSafeModeMaxMissRate = 0.05` (5%).

5. **`SafeModeRejection`** bubbles up. The conversion service's catch block calls `_storage.deleteExercise(rejection.exerciseId)` best-effort, broadcasts on the `onSafeModeRejection` stream, and the capture screen shows a coral toast.

For a single-frame photo, the miss rate is binary: 0.0 (human found) or 1.0 (none found). For a multi-frame video, it's a fraction across all frames.

## 3. Problems being addressed

### 3a. Empty-frame captures get rejected

The current rule rejects legitimate no-PII captures:

- A photo of equipment in an empty room.
- A demo recorded outdoors at an empty trail or beach.
- A close-up of a resistance band attached to a doorframe.
- A shot of the ceiling pulley before the client arrives.
- A photo of a yoga mat layout from above.

Rejecting these is friction without a privacy benefit. The rule treats "Vision found nobody" as evidence Vision is failing rather than evidence the frame is empty.

The counter-argument exists but is narrower: Vision can sometimes miss real people (mirror reflections, heavy backlighting, hooded figures turned away). The current rule defends against all of those by treating every zero-detection as a possible false negative.

### 3b. Rejected captures leave orphan exercise rows

When a capture trips the rejection today, the safe variant files + intermediate artifacts get cleaned up but the exercise row sometimes persists with no content. Result: an empty card shows up in Studio with no thumbnail, no playable media.

The deletion code IS present in `conversion_service.dart`'s `SafeModeRejection` catch block (`await _storage.deleteExercise(rejection.exerciseId)`), but it's wrapped in a try/catch that swallows failures with `debugPrint` only — the comment even acknowledges "the row will become an orphan but the user gets the toast either way." This was intended as a sanctioned best-effort failure mode for the rare case where the SQLite delete throws, but Carl is seeing it consistently in QA, not occasionally.

Three plausible root causes — investigation will narrow it down:

1. **The DB delete silently fails.** Best-effort = no surfacing. If SQLite is locked or the ID lookup misses, an orphan persists with no visible error.
2. **The delete works but Studio doesn't refresh its in-memory list.** The conversion service's `_updateController` stream might not emit a "removed" event that Studio's listener picks up. Row gone in SQLite, still rendered.
3. **The exercise row gets re-created after the delete.** If a step in the chain calls `saveExercise` after the rejection delete (e.g., a status update racing the cleanup), it'll re-insert with the partial state — exactly matching the "exercise with no content" symptom.

## 4. The rule (single, unified)

The rule applies the same way to both photos and videos. Photos only ever reach the endpoints by arithmetic (one frame, binary miss rate); videos can land anywhere.

| Miss rate | Today | Proposed |
|---|---|---|
| `0% ≤ miss ≤ 5%` | Accept with safe variant | Accept with safe variant (unchanged) |
| `5% < miss < 100%` | Reject | Reject (unchanged) — Vision is struggling; humans likely present but partially missed |
| `100%` (exactly) | Reject | **Accept** as no-PII — frame contains no humans |

The middle band (5–100%) is "physically impossible" for photos because a single-frame miss rate can only land on 0% or 100%. So the middle-band rejection clause is vacuous for photos — but the if-branch reads identically. One code path, one rule.

**Why no practitioner override on rejection:** considered and dropped. An override would turn the technical guardrail into a social one — a malicious practitioner could capture a client + bystander, get the correct rejection, then tap "accept anyway" to bypass. Audit trails make abuse traceable but not preventable. The legitimate use case (empty room, equipment) is already covered by the 100% accept branch; the practitioner doesn't need to override anything for those. For middle-band rejections (videos with intermittent bystander detection), the correct answer is "re-shoot from a different angle" — exactly what the rejection toast asks for.

## 5. Telemetry

Every time the new `100% miss → accept` branch fires, write one row to the existing `capture_audit_events` table.

### Schema (no migration needed)

The `capture_audit_events` table already exists with shape:
- `id uuid`
- `practice_id uuid`
- `premises_id uuid`
- `trainer_id uuid`
- `kind text`
- `started_at timestamptz`
- `ended_at timestamptz`
- `metadata jsonb`
- `created_at timestamptz`

The new event kind: `safe_mode.accepted_empty`. Stored as a new value of the `kind` text column — no enum migration needed.

### Metadata payload

```json
{
  "exercise_id": "uuid",
  "media_type": "photo" | "video",
  "miss_rate": 1.0,
  "scene_fingerprint": {
    "mean_r": 0..255,
    "mean_g": 0..255,
    "mean_b": 0..255,
    "grayscale_entropy": 0.0..8.0,
    "complexity_score": 0.0..1.0
  }
}
```

The scene fingerprint distinguishes "actually empty room" from "complex scene Vision missed." A landscape photo has low entropy in the body-tone bands and even brightness. A heavily-backlit scene with a hooded figure in the corner has high entropy in the upper third and a brightness bimodality. Carl won't have to inspect every row — outliers will stand out in the feed.

Computed on-device in Dart from the raw capture's first frame (photo: the frame itself; video: a single sampled frame at t=0). Implementation lives in a new private helper in `conversion_service.dart`. Use the `image` package (already in `pubspec.yaml` for thumbnail extraction) for the pixel-level math.

### Storage path

New RPC `record_safe_mode_capture_event(p_kind, p_premises_id, p_metadata jsonb)` — SECURITY DEFINER, owner `postgres`, scoped to `user_practice_ids()` for the `practice_id`. Mirrors the same pattern as the existing per-capture event writers. Insert is fire-and-forget from Dart — failure must NOT bubble back to the capture flow.

### Privacy posture for the telemetry itself

- No image bytes, no thumbnails, no face crops.
- Scene fingerprint is aggregate numerics — channel means, entropy scalars, a single complexity score — cannot be reverse-engineered into a recognisable image.
- The raw frame itself stays in the raw-archive bucket under existing RLS.
- Same RLS scoping as every other `capture_audit_events` row: visible to the practice via `user_practice_ids()`, not exposed to the public live-page roster.

### Surfaces (where Carl sees it)

1. **Portal audit feed at `manage.homefit.studio/audit`** — new chip alongside the existing `safe_mode_active` chip. Label: `accepted-empty`. Per-row info already includes practitioner + premises + timestamp.
2. **Live-page 24h drawer at `/v/{practice}/{premises}/now`** — same event row in near-real-time.
3. **Per-event drill-in modal** — tap the chip in either surface, see the scene-fingerprint numerics in a tooltip-style modal. If a row looks suspicious (e.g. high entropy in the body-tone band of an empty-room claim), tap through to the exercise and eyeball the frame in the editor sheet.

### Cost

One row per accepted-empty capture. Even at 100 captures/day per practice, 36k rows/year — trivial. No webhook spam. Background insert.

## 6. Companion fix: orphan exercise after rejection

### Diagnosis approach

The implementing agent diagnoses BEFORE fixing. Iron law: no fixes without root-cause investigation first. Reproduce the bug:

1. Build the app with the new rule on the agent's worktree.
2. Trigger a middle-band rejection in the simulator (mock a `_ConvertResult` with `safeMissRate = 0.5, safePath != null` and inject through the conversion queue).
3. Verify Studio's exercise list AFTER the rejection: does the row persist in SQLite (`SELECT * FROM exercises WHERE id = ...`)? Does Studio render an empty card?

Map the observed symptom to one of the three hypotheses in section 3b. Then fix at root cause — NOT by adding more aggressive cleanup downstream.

### Likely fix shapes (informed guess; agent confirms with evidence)

- **If hypothesis 1 (silent delete failure):** add explicit error surfacing on the catch (`debugPrint` → `os_log` with structured fields visible in Console.app, plus emit a `safe_mode.delete_failed` event to `capture_audit_events`). Then chase why the delete failed — most likely a missing row or a transaction-isolation issue.
- **If hypothesis 2 (Studio doesn't refresh):** ensure `_updateController.add(deletedExercise.copyWith(deleted: true))` fires alongside the SQLite delete, OR add a dedicated removal stream that Studio's listener subscribes to.
- **If hypothesis 3 (re-create races delete):** identify the racing call site and gate it on the rejection state — e.g., short-circuit `saveExercise` if the exercise has been deleted in the same conversion run. May require adding a deletion-tombstone check in the conversion-service in-memory state.

### Regression guard

Add a Dart unit test that exercises the rejection flow against an in-memory storage mock and asserts:
1. The exercise row is deleted from SQLite after rejection.
2. The `onSafeModeRejection` stream emits exactly one event.
3. Studio's update stream emits a removal event the listener can use to drop the card.

This test should FAIL on `staging` tip today and pass after the fix.

## 7. Acceptance criteria

1. **Empty-frame photo accepted.** A photo with no humans in the frame (gym wall, equipment, ceiling, outdoor landscape) captured inside an enforcing premises polygon → row persists, no `SafeModeRejection`, no coral toast. The raw frame is used as the canonical source (no safe variant produced because there's nothing to obscure). One audit-event row written to `capture_audit_events` with `kind = 'safe_mode.accepted_empty'`.

2. **Empty-frame video accepted.** Same as above for a video where Vision detected zero humans across all frames.

3. **Partial-detection capture still rejected.** A capture where Vision found humans in some frames but missed them in others (miss rate strictly between 5% and 100%) → still throws `SafeModeRejection`, still cleans up files, still shows the toast. Copy updated to reflect the actual reason ("we couldn't track everyone in the shot — try a different angle").

4. **Fully-detected capture unchanged.** Captures where Vision detected humans consistently (miss rate ≤ 5%) → safe variant produced and used, unchanged from today.

5. **Photo and video paths share the same code branch.** Same if-conditional, same constant, same audit event — only the natural arithmetic of single-frame vs multi-frame causes the photo to land only on endpoints.

6. **Audit trail for accepted captures.** Every accepted-empty capture writes one `capture_audit_events` row with `kind = 'safe_mode.accepted_empty'` and the scene fingerprint in `metadata`. Visible in the portal audit feed and the live-page 24h drawer. Tappable to expand the metadata into a modal.

7. **Audit trail for the capture itself unchanged.** The cloud `exercises.safe_mode_active` boolean and `captured_in_premises_id` columns still stamp on every accepted capture. The portal audit feed at `manage.homefit.studio/audit` shows the same chips as today. Whether a safe variant was *produced* is a separate concern from whether the capture was made in Safe Mode.

8. **Rejected captures leave no orphan rows.** A capture that trips the middle-band rejection results in zero rows for that exercise ID in SQLite AND zero cards rendered in Studio. Verified by the regression test in section 6.

9. **Telemetry write is fire-and-forget.** Failure to write the audit row never blocks the capture flow or surfaces an error to the practitioner. Logged via `debugPrint` only on failure.

10. **Native pipeline unchanged.** No changes to `SafeModeProcessor`, `processPhotoSafeMode`, `applySafeModeToPhoto`, or any native iOS code. The work is entirely Dart-side + a new SECURITY DEFINER RPC.

## 8. Implementation guidance

### Files likely to change

- `app/lib/services/conversion_service.dart` — rejection conditional (around line 449), add the `isFullyEmpty` carve-out. Photo block (around line 1247) needs the same treatment so `safePhotoPath` falls through to null when miss rate is 100%, letting the canonical-source resolver pick the raw. Add the telemetry call. Diagnose + fix orphan-exercise bug per section 6.
- `app/lib/screens/capture_mode_screen.dart` — `SafeModeRejection` toast copy. Update to "Couldn't track everyone in the shot — try a different angle" (or Carl's final wording).
- `app/lib/services/api_client.dart` — new `recordSafeModeCaptureEvent({...})` method wrapping the RPC.
- New SQL migration `supabase/migrations/YYYYMMDDHHMMSS_safe_mode_capture_event_rpc.sql` — `CREATE OR REPLACE FUNCTION record_safe_mode_capture_event(...)`.
- `web-portal/src/app/audit/page.tsx` (or the relevant audit feed component) — render the new chip kind.
- `web-portal/src/app/v/[practice]/[premises]/now/page.tsx` (or the relevant live-page drawer) — render the new chip kind.
- New test file `app/test/services/conversion_service_rejection_test.dart` — regression test for the orphan-exercise fix.
- New test wave file `docs/test-scripts/YYYY-MM-DD-safe-mode-zero-detection-accept.md`.

### Pseudocode for the unified rule

```dart
// conversion_service.dart, replacing the current rejection check
const double kSafeModeFullEmptyThreshold = 0.999; // tolerate float jitter

final isFullyEmpty = result.safeMissRate >= kSafeModeFullEmptyThreshold;
final isPartialMiss =
    result.safeMissRate > kSafeModeMaxMissRate && !isFullyEmpty;

if (result.safePath != null && isPartialMiss) {
  // Existing rejection path — Vision is struggling.
  await _deleteSafely(result.safePath);
  await _deleteSafely(result.convertedPath);
  await _deleteSafely(result.segmentedPath);
  await _deleteSafely(result.maskPath);
  throw SafeModeRejection(exercise.id, result.safeMissRate);
}

if (result.safePath != null && isFullyEmpty) {
  // Fully-empty case — drop the safe variant (nothing to obscure).
  await _deleteSafely(result.safePath);
  // Fire-and-forget telemetry — never blocks the capture flow.
  unawaited(_recordSafeModeAcceptedEmpty(
    exerciseId: exercise.id,
    premisesId: exercise.capturedInPremisesId,
    mediaType: exercise.mediaType,
    missRate: result.safeMissRate,
    rawFilePath: exercise.absoluteRawFilePath,
  ));
  // Fall through to the normal canonical-source path.
}
```

### Scene fingerprint computation

```dart
// New private helper in conversion_service.dart
Future<Map<String, dynamic>> _computeSceneFingerprint(String rawFilePath) async {
  // Decode the first frame to a small image (e.g. 256x256) for cheap math.
  // Use the `image` package's decodeImage / copyResize.
  // Compute:
  //   - mean R, G, B (ints 0..255)
  //   - grayscale entropy (Shannon entropy of the histogram, 0..8)
  //   - complexity score (e.g. normalised Laplacian variance, 0..1)
  // Return as a Map<String, dynamic> ready for jsonb storage.
}
```

Implement defensively — never throw. If decode fails, return an empty `{"error": "decode_failed"}` map so the audit row still writes with a marker.

### RPC

```sql
CREATE OR REPLACE FUNCTION public.record_safe_mode_capture_event(
  p_kind text,
  p_premises_id uuid,
  p_metadata jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_practice_id uuid;
  v_trainer_id uuid;
  v_event_id uuid;
BEGIN
  v_trainer_id := auth.uid();
  IF v_trainer_id IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  -- Resolve the practice from the premises.
  SELECT practice_id INTO v_practice_id
  FROM practice_premises
  WHERE id = p_premises_id;
  IF v_practice_id IS NULL THEN
    RAISE EXCEPTION 'premises not found: %', p_premises_id;
  END IF;

  -- Membership check (practitioner must belong to the practice).
  IF NOT (v_practice_id = ANY (user_practice_ids())) THEN
    RAISE EXCEPTION 'not a member of practice %', v_practice_id;
  END IF;

  INSERT INTO capture_audit_events (
    practice_id, premises_id, trainer_id, kind, metadata
  ) VALUES (
    v_practice_id, p_premises_id, v_trainer_id, p_kind, p_metadata
  ) RETURNING id INTO v_event_id;

  RETURN v_event_id;
END;
$$;
```

### Upload-path verification

`app/lib/services/upload_service.dart` — `_uploadRawArchives` already reads `exercise.safeRawFilePath` and only swaps when both `safeModeActive == true` AND `safeRawFilePath != null`. The new "accepted empty" case (`safeModeActive == true && safeRawFilePath == null`) just uploads the raw archive normally. **Verify this works as expected** — should be no code change.

### Constants

Add at the top of `conversion_service.dart` next to `kSafeModeMaxMissRate`:

```dart
/// Captures where Vision detected zero humans in every frame are
/// accepted as no-PII (landscape, equipment, empty room). The >=
/// comparison (vs == 1.0) tolerates floating-point jitter in the
/// native miss-rate calculation.
const double kSafeModeFullEmptyThreshold = 0.999;
```

## 9. Edge cases preserved

- **Mirror-reflection bystander.** A practitioner photographing a treadmill that reflects a passing client in a wall mirror. Vision detects the reflected human → miss rate < 100% → safe variant produced → bystander painted coral. **Unchanged.**
- **Heavily backlit person.** Vision struggles to detect against bright window light → some frames miss, others find → miss rate in the 5–100% band → **reject** (middle-band, unchanged). Telemetry NOT written (we only log accepted-empty, not rejections — those are already audit-traceable via the exercise deletion).
- **Hooded figure turned away.** May trigger 100% miss if Vision can't recognise the silhouette → **would be accepted** under the new rule. The scene-fingerprint telemetry catches this: high entropy in upper-frame body-tone bands → outlier worth investigating in the audit feed. Residual privacy risk that's now observable, not invisible.
- **Child in frame.** Vision sometimes misses children. Consistent miss → 100% → accept (risk, but logged with fingerprint). Intermittent → reject (middle-band catches it).
- **Multiple people, one obscured.** Vision finds 1 of 2 → miss rate is 0% (every frame had at least one detection), not 50%. The undetected person is not painted because they were never detected. Same as today — outside the scope of this change.

## 10. Testing

### Manual test wave on iPhone (per `homefit-ship-to-phone`)

New test script at `docs/test-scripts/YYYY-MM-DD-safe-mode-zero-detection-accept.md`. Numbered checkboxes:

1. **Empty-room photo inside enforcing polygon:** capture → row persists, no toast, exercise visible in Studio.
2. **Equipment-only photo inside enforcing polygon:** capture → row persists.
3. **Outdoor landscape inside enforcing polygon:** capture → row persists.
4. **Selfie inside enforcing polygon (just the practitioner):** capture → safe variant produced (Vision found a human), row persists. Same as today.
5. **Practitioner + bystander photo inside enforcing polygon:** capture → safe variant produced with bystander painted coral. Same as today.
6. **Backlit / partial-detection photo:** capture → toast shows new copy "couldn't track everyone — try again." Row deleted. **Crucially: no empty card left behind in Studio.**
7. **Empty-room video inside enforcing polygon:** capture → row persists.
8. **Bystander walks past mid-video inside enforcing polygon:** capture → if Vision tracked them consistently, safe variant produced; if intermittently, rejected with new copy. No orphan card.
9. **Telemetry visible in portal audit feed:** after items 1–3 and 7, open `manage.homefit.studio/audit` and confirm the `accepted-empty` chip appears with practitioner + premises + timestamp.
10. **Telemetry visible in live-page drawer:** during items 1–3 and 7, the live page `/v/{practice}/{premises}/now` 24h drawer surfaces the new chip in near-real-time.
11. **Scene fingerprint modal:** tap the chip in the audit feed; modal shows the metadata (mean RGB, entropy, complexity). Numerics look right for the scene type.

Add the test script entry at the top of `docs/test-scripts/index.md`'s "Active wave" list per `feedback_test_wave_discipline.md`.

### Unit-level (in-PR, not optional)

`app/test/services/conversion_service_rejection_test.dart`:

- Mock `_ConvertResult` with `safeMissRate = 1.0, safePath != null` → expect no throw, expect safe path deleted, expect telemetry call recorded.
- Mock `safeMissRate = 0.5, safePath != null` → expect `SafeModeRejection` thrown, expect exercise row deleted from SQLite, expect Studio's update stream emits a removal event.
- Mock `safeMissRate = 0.0, safePath != null` → expect no throw, expect safe variant used as canonical source.
- Mock `safeMissRate = 0.06` (just over threshold) → expect rejection, expect no telemetry.
- Mock `safeMissRate = 0.999` → expect accepted-empty path (tests the jitter buffer).

The orphan-exercise regression test MUST be the FIRST test added in this file — written to fail on `staging` tip before the fix lands.

## 11. Out of scope

- Native pipeline changes (`SafeModeProcessor`, `processPhotoSafeMode`, `applySafeModeToPhoto`).
- Premises / polygon CRUD.
- Web portal audit feed copy beyond rendering the new chip.
- The `report_premises` abuse channel.
- Mobile UI of the Safe Mode top banner.
- Web portal Safe Mode chips beyond the new event kind.
- Adding a practitioner-override on rejection (explicitly considered and dropped — see section 4).
- Future dashboard chart for accept-empty rate over time (data lands in this PR but visualisation is separate).

## 12. Open questions

1. **Toast copy.** Suggested: "Couldn't track everyone in the shot — try a different angle." Carl to confirm or reword.
2. **Scene-fingerprint complexity score formula.** Recommend normalised Laplacian variance of the grayscale frame, clamped to 0..1 by dividing by a typical empty-scene baseline (~50). The implementing agent benchmarks against a few real test photos and adjusts the divisor. Documented in code comments alongside the helper.
3. **Audit feed chip wording.** Suggested: `accepted-empty`. Could also be `no-bystanders` or `empty-frame`. Carl picks during PR review.

## 13. Appendix A — Agent brief

Use the following as the agent brief when implementing. Composed in the homefit-agent-brief style.

```markdown
# Task: Safe Mode — accept zero-detection captures + telemetry + orphan-row fix

## Context

Three changes that share Safe Mode's rejection code path, bundled into one PR:

1. Accept captures where Vision detected zero humans (landscape, equipment, empty room) — same path as today's accepted captures, no safe variant produced.
2. Log every "accepted because empty" event to the existing `capture_audit_events` table with a scene fingerprint, surfaced in the portal audit feed and the live-page 24h drawer.
3. Fix the orphan-exercise-after-rejection bug: today when a capture trips the rejection, the safe variant + intermediate files get cleaned up but the exercise row sometimes persists with no content. Diagnose root cause and fix at root cause.

The full spec lives in `docs/specs/2026-05-25-safe-mode-accept-zero-detection.md` — READ THAT FIRST. Read it completely before touching any code.

## Constraints (HARD RULES — read first)

- REPO-RELATIVE paths only in tool calls. Never absolute `/Users/chm/dev/TrainMe/...` paths.
- No emojis anywhere — code, comments, commit messages, PR body, file names.
- Branch: `fix/safe-mode-accept-zero-detection` off `staging`.
- PR target: `staging` (NOT `main`). Carl promotes staging to main explicitly.
- After any `.dart` edit, run `dart_analyze` (via the dart MCP) before reporting done.
- NO PHONE INSTALL. PR stays `[QA-blocked]` draft. The `feedback_ask_before_mobile_deployment` memory rule is binding.
- One Supabase migration is needed (the new RPC). File goes under `supabase/migrations/YYYYMMDDHHMMSS_safe_mode_capture_event_rpc.sql` per the Branching cutover convention. Do NOT touch the existing `capture_audit_events` table schema — only insert into it via the new RPC.
- No `CREATE OR REPLACE FUNCTION` on existing RPCs. The new RPC is new — that's fine. If you find yourself needing to modify an existing RPC, stop and surface to Carl.

## Investigation discipline for the orphan-row fix

Iron law: no fixes without root-cause investigation. Section 6 lists three hypotheses. Reproduce the bug FIRST. Map the observed symptom to the right hypothesis. THEN fix at root cause. Add the regression test BEFORE the fix lands (test should fail on staging tip, pass after the fix).

## Acceptance criteria

(Copy from section 7 of the spec.)

## Files likely to change

- `app/lib/services/conversion_service.dart` (rule + telemetry call + orphan-row fix)
- `app/lib/screens/capture_mode_screen.dart` (toast copy)
- `app/lib/services/api_client.dart` (new RPC wrapper)
- `supabase/migrations/YYYYMMDDHHMMSS_safe_mode_capture_event_rpc.sql` (new)
- `web-portal/src/app/audit/page.tsx` (new chip rendering)
- `web-portal/src/app/v/[practice]/[premises]/now/page.tsx` (new chip rendering — confirm path)
- `app/test/services/conversion_service_rejection_test.dart` (new)
- `docs/test-scripts/YYYY-MM-DD-safe-mode-zero-detection-accept.md` (new test wave)
- `docs/test-scripts/index.md` (add at top of Active wave)

Verify but probably no edit needed:

- `app/lib/services/upload_service.dart` (`_uploadRawArchives` swap logic)

## Deliverable

- PR title: `fix(safe-mode): accept zero-detection captures + telemetry + orphan-row fix`
- PR body: What changed, Why, How to test, Risk, link to this spec.
- Conventional Commits. No emojis.
- Draft, prefixed `[QA-blocked]`.

## Out of scope

Per section 11 of the spec.
```
