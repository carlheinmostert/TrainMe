# Safe Mode — Accept Zero-Detection Captures

A proposed change to the Safe Mode fail-closed rule so that captures where Vision detected **no humans at all** (landscape, equipment, ceiling, empty-room) are accepted, while captures where Vision found *some* humans but missed others (the genuinely risky case) keep getting rejected.

Branch this implements against: `fix/safe-mode-accept-zero-detection`
Target: `staging` (per the staging-promotion rule).

## Table of Contents

1. [Summary](#1-summary)
2. [Current behavior](#2-current-behavior)
3. [Problem](#3-problem)
4. [Two proposed designs](#4-two-proposed-designs)
5. [Recommended approach](#5-recommended-approach)
6. [Acceptance criteria](#6-acceptance-criteria)
7. [Implementation guidance](#7-implementation-guidance)
8. [Edge cases preserved](#8-edge-cases-preserved)
9. [Testing](#9-testing)
10. [Out of scope](#10-out-of-scope)
11. [Open questions](#11-open-questions)
12. [Appendix A — Agent brief (for the next session)](#12-appendix-a--agent-brief-for-the-next-session)

## 1. Summary

Today, when Safe Mode is active and Vision can't detect any human in a capture, the capture is rejected. This is too defensive — it treats "Vision found nobody" identically to "Vision found someone and lost them" and rejects legitimate no-person captures (landscapes, equipment, demos at outdoor venues).

The proposed change: distinguish between "100% miss rate" (no humans in the frame at all → safe, no PII) and "partial miss rate" (Vision is struggling to track humans → genuinely risky). Accept the former, keep rejecting the latter.

## 2. Current behavior

When Safe Mode is active at the moment of capture (practitioner is inside an enforcing premises polygon — `practice_premises.enforced = true`), the pipeline is:

1. **Capture** stamps the exercise row with `safe_mode_active = true` (locked at shutter time so post-capture polygon exits don't undo the intent).
2. **Native conversion** (`app/ios/Runner/VideoConverterChannel.swift` — `SafeModeProcessor` for video, `applySafeModeToPhoto` / `processPhotoSafeMode` channel method for photo) produces a `_safe.{mp4,jpg}` variant where every detected human OTHER than the largest bounding box is painted coral.
3. **Native pipeline also reports** `safeFramesMissedRate` — fraction of frames where Vision found zero humans.
4. **`app/lib/services/conversion_service.dart`** evaluates the result. The rejection check is:

   ```dart
   if (result.safePath != null && result.safeMissRate > kSafeModeMaxMissRate) {
     await _deleteSafely(result.safePath);
     await _deleteSafely(result.convertedPath);
     // ...
     throw SafeModeRejection(exercise.id, result.safeMissRate);
   }
   ```

   `kSafeModeMaxMissRate = 0.05` (5%).

5. **`SafeModeRejection`** bubbles up to the capture screen, which deletes the exercise row and shows a coral toast (per `app/lib/screens/capture_mode_screen.dart`).

For a single-frame photo, the miss rate is binary: 0.0 (human found) or 1.0 (none found). Photos with no humans always trip the rejection. For a multi-frame video, the miss rate is a fraction across all frames.

## 3. Problem

The current rule rejects legitimate captures:

- A photo of a piece of equipment in an empty room.
- A demo recorded outdoors at an empty hiking trail or beach.
- A close-up of a resistance band attached to a doorframe.
- A shot of the ceiling pulley before the client arrives.
- A photo of a yoga mat layout from above.

By definition these contain no personal information about anybody. Rejecting them is friction without a privacy benefit — the rule treats "Vision found nobody" as evidence Vision is failing rather than evidence the frame is empty.

The counter-argument is real but narrower: Vision *can* miss real people (mirror reflections, heavy backlighting, people partially out of frame, hooded figures turned away). The current rule defends against all of those by treating every zero-detection as a possible false negative.

## 4. Two proposed designs

### Design A — Pure permissive

Rule: if `safeFramesMissedRate == 1.0` (no humans detected in any frame), accept the capture. Treat it as a no-PII frame — same path as a non-Safe-Mode capture.

- **Photo:** Vision found 0 humans → accept, no safe variant needed (the original is already safe by definition).
- **Video:** every frame had 0 detections → accept, use raw / unchanged.
- **Other miss rates (0 < miss rate ≤ 1.0):** existing rejection logic unchanged.

Pros: simple, one-line change to the threshold check.
Cons: trusts Vision's negative result completely. If Vision missed every person in a frame containing humans (mirror reflections, etc.), the un-blurred frame uploads.

### Design B — Nuanced bimodal

Rule: split the miss-rate spectrum into three zones:

| Miss rate | Today | Proposed |
|---|---|---|
| `0% ≤ miss ≤ 5%` | Accept with safe variant | Accept with safe variant (unchanged) |
| `5% < miss < 100%` | Reject | Reject (unchanged) — Vision is struggling; humans likely present but partially missed |
| `100%` (exactly) | Reject | **Accept** as no-PII — Vision is confident the frame is empty |

The middle band is what the defensive rule is actually defending against — intermittent detection where humans are present but Vision can't catch them all. Keep rejecting there. The 100% case is qualitatively different and should be accepted.

Pros: keeps the defensive instinct on the genuinely risky case. Only accepts when Vision is *confident* the frame is empty.
Cons: slightly more complex; still trusts Vision's negative result completely *in the 100% case* (the same risk as Design A, but narrowed to a more well-defined situation).

## 5. Recommended approach

**Design B (nuanced bimodal).** Reasoning:

- The cost of complexity is one extra conditional in `app/lib/services/conversion_service.dart`.
- The bimodal rule matches the actual privacy threat model — partial detection failures are where bystanders slip through, not "Vision detected nothing."
- Design A is essentially Design B's 100% bucket alone; ratifying Design B doesn't preclude moving to Design A later if the middle-band rejection turns out to never fire in practice. Easier to relax later than to tighten.
- The user-facing copy can be tighter: instead of "Safe Mode couldn't track anyone," the rejection toast becomes "Safe Mode found people but couldn't track them all — try again from a different angle." This *matches* the actual reason for rejection and gives the practitioner an actionable next step.

Carl may override and request Design A — it's a one-line variant of Design B. If so, drop the middle-band rejection clause and the rejection condition becomes simply `safeMissRate < 0.999 && safeMissRate > kSafeModeMaxMissRate`.

## 6. Acceptance criteria

1. **Empty-frame photo accepted.** A photo with no humans in the frame (gym wall, equipment, ceiling, outdoor landscape) captured inside an enforcing premises polygon → row persists, no `SafeModeRejection`, no coral toast. The raw frame is used as the canonical source (no safe variant produced because there's nothing to obscure).

2. **Empty-frame video accepted.** A video with zero humans detected across all frames → same as above. No safe variant; raw used.

3. **Partial-detection capture still rejected.** A capture where Vision found humans in some frames but missed them in others (miss rate strictly between 5% and 100%) → still throws `SafeModeRejection`, still deletes the row, still shows the toast. Copy updated to reflect the actual reason ("we couldn't track everyone in the shot — try a different angle").

4. **Fully-detected capture unchanged.** Captures where Vision detected humans consistently (miss rate ≤ 5%) → safe variant produced and used, unchanged from today.

5. **Photo and video paths consistent.** Both `MediaType.photo` and `MediaType.video` follow the same three-zone rule. (For a photo the middle band can't physically occur — only 0% or 100% — but the code path is the same.)

6. **Audit trail unchanged.** The cloud `exercises.safe_mode_active` boolean and `captured_in_premises_id` columns still stamp on every accepted capture (per the `replace_plan_exercises` RPC contract). The portal audit feed at `manage.homefit.studio/audit` shows the same chips. Whether a safe variant was *produced* is a separate concern from whether the capture was made in Safe Mode.

7. **Native pipeline unchanged.** No changes to `SafeModeProcessor` in `app/ios/Runner/VideoConverterChannel.swift` or to the `processPhotoSafeMode` / `applySafeModeToPhoto` channel methods. The change is entirely in the Dart-side evaluation of the native pipeline's results.

## 7. Implementation guidance

### Files likely to change

- `app/lib/services/conversion_service.dart` — the rejection conditional (currently around line 296). Add the bimodal carve-out for `safeMissRate >= 0.999`. Also touch the photo-Safe-Mode block (currently around line 1056) to set `safePhotoPath = null` (or skip the safe-variant assignment entirely) when miss rate is 100%, so downstream code naturally falls through to "use raw."
- `app/lib/screens/capture_mode_screen.dart` — the `SafeModeRejection` toast copy. Update to something like "Safe Mode found people but couldn't track them all — try again from a different angle." (Final wording is Carl's call — see Open Questions.)

Probably no Supabase / RPC / web-portal changes needed.

### Pseudocode for the conditional

```dart
// In conversion_service.dart, around line 296, replacing the current check:

const double kSafeModeFullEmptyThreshold = 0.999; // tolerate float jitter

final isFullyEmpty = result.safeMissRate >= kSafeModeFullEmptyThreshold;
final isPartialMiss = result.safeMissRate > kSafeModeMaxMissRate && !isFullyEmpty;

if (result.safePath != null && isPartialMiss) {
  // Existing rejection path — Vision is struggling, humans likely present.
  await _deleteSafely(result.safePath);
  await _deleteSafely(result.convertedPath);
  await _deleteSafely(result.segmentedPath);
  await _deleteSafely(result.maskPath);
  throw SafeModeRejection(exercise.id, result.safeMissRate);
}

if (result.safePath != null && isFullyEmpty) {
  // Fully-empty case — drop the safe variant (nothing to obscure;
  // the original is already safe by definition). Fall through to
  // the normal canonical-source path.
  await _deleteSafely(result.safePath);
  // Do NOT throw. Continue with raw as canonical source.
}
```

For photos (currently around line 1056), set `safePhotoPath = null` when `missRate >= kSafeModeFullEmptyThreshold` so `canonicalSource` (`safePhotoPath ?? exercise.absoluteRawFilePath`) falls through to the raw capture, and `safe_raw_file_path` doesn't get stamped on the local SQLite row.

### Audit / upload behavior

When Safe Mode was active but no safe variant was produced (the new accepted-empty case), the upload path needs to handle gracefully:

- `app/lib/services/upload_service.dart` — `_uploadRawArchives` already reads `exercise.safeRawFilePath` and only swaps when both `safeModeActive == true` AND `safeRawFilePath != null`. The new case (`safeModeActive == true && safeRawFilePath == null`) just uploads the raw archive normally. **Verify this works as expected** — should be no code change, but worth a read-through to confirm.
- `replace_plan_exercises` RPC still receives `safe_mode_active = true` per the audit-stamping contract. No RPC signature change.

### Constants / threshold considerations

- The "fully empty" comparison uses `>= 0.999` rather than `== 1.0` to tolerate floating-point jitter in the native miss-rate calculation. Document this in a comment alongside the constant.
- Extract `kSafeModeFullEmptyThreshold = 0.999` alongside the existing `kSafeModeMaxMissRate = 0.05` for clarity. Both at the top of `conversion_service.dart`.

## 8. Edge cases preserved

- **Mirror-reflection bystander.** A practitioner photographing a treadmill that reflects a passing client in a wall mirror. Vision detects the reflected human → miss rate < 100% → safe variant produced → bystander painted coral. **Unchanged.**
- **Heavily backlit person.** Vision struggles to detect against bright window light → some frames miss the detection, others find it → miss rate in the 5–100% band → **reject** (middle-band, unchanged).
- **Hooded figure turned away.** May trigger 100% miss if Vision can't recognize the silhouette → **would be accepted** under the new rule. This is the residual privacy risk of the change. Acceptable trade-off per Carl's framing.
- **Child in frame.** Vision sometimes misses children. If consistently missed → 100% → accept (risk). If intermittently missed → reject (middle-band catches it).
- **Multiple people, one obscured.** Vision finds 1 of 2 → miss rate is 0% (every frame had at least one detection), not 50%. The undetected person is not painted because they were never detected. This is the same as today — outside the scope of this change.

## 9. Testing

### Manual test wave on iPhone (per the `homefit-ship-to-phone` workflow)

Test script should land at `docs/test-scripts/2026-MM-DD-safe-mode-zero-detection-accept.md` per the markdown-test-script convention. Numbered checkboxes covering:

1. **Empty-room photo inside enforcing polygon:** capture → row persists, no toast.
2. **Equipment-only photo inside enforcing polygon:** capture → row persists.
3. **Outdoor landscape inside enforcing polygon:** capture → row persists.
4. **Selfie inside enforcing polygon (just the practitioner):** capture → safe variant produced (no bystanders to paint, but Vision found a human), row persists. Same as today.
5. **Practitioner + bystander photo inside enforcing polygon:** capture → safe variant produced with bystander painted coral. Same as today.
6. **Backlit / partial-detection photo:** capture → toast shows new copy "couldn't track everyone — try again." Row deleted. Same rejection behavior as today.
7. **Empty-room video inside enforcing polygon:** capture → row persists.
8. **Bystander walks past mid-video inside enforcing polygon:** capture → if Vision tracked them consistently, safe variant produced; if intermittently, rejected with new copy.

Add the test script entry at the TOP of `docs/test-scripts/index.html` per `feedback_always_test_script.md` and `feedback_test_scripts_as_markdown.md`.

### Unit-level (optional, not blocking)

Consider a Dart unit test on the conversion-service rejection branch:

- Mock a `ConversionResult` with `safeMissRate = 1.0, safePath != null` → expect no throw, expect safe path deleted.
- Mock `safeMissRate = 0.5, safePath != null` → expect `SafeModeRejection` thrown.
- Mock `safeMissRate = 0.0, safePath != null` → expect no throw, expect safe variant used.

If no unit-test scaffolding exists for `conversion_service.dart` yet, leave this as a future-work note. Don't block the wave on it.

## 10. Out of scope

- Native pipeline changes (`SafeModeProcessor`, `processPhotoSafeMode`, `applySafeModeToPhoto`).
- Premises / polygon CRUD.
- Audit feed copy on the portal.
- The `report_premises` abuse channel.
- Mobile UI of the Safe Mode top banner.
- Web portal Safe Mode chips.
- Supabase schema or RPC contracts.

## 11. Open questions

1. **Toast copy.** Suggested: "Safe Mode found people but couldn't track them all — try again from a different angle." Carl to confirm or reword.
2. **Telemetry.** Should we log the new "accepted empty" case so we can later analyze how often it fires? Out of scope for this PR but flag in the PR body — could land as a follow-up.
3. **`kSafeModeFullEmptyThreshold` value.** Recommend `0.999`. Justified by floating-point jitter in the native miss-rate calculation. Document in a code comment alongside the constant.

## 12. Appendix A — Agent brief (for the next session)

Use the following as the agent brief when implementing. Composed in the homefit-agent-brief style.

```markdown
# Task: Safe Mode — accept zero-detection captures (Design B, nuanced bimodal)

## Context

Today the Safe Mode fail-closed rule in `app/lib/services/conversion_service.dart`
rejects any capture where Vision's miss rate exceeds 5% — including the case where
Vision detected NO humans at all (a landscape, an empty room, a piece of equipment).
That last case is too defensive: by definition the frame contains no personal
information.

The full design discussion + recommended approach lives in
`docs/specs/2026-05-25-safe-mode-accept-zero-detection.md` — READ THAT FIRST.

This task implements Design B from that spec: the bimodal rule that splits
the miss-rate spectrum into three zones (accept 0–5%, reject 5–100%, accept 100%).

## Constraints (HARD RULES — read first)

- Use REPO-RELATIVE paths only in your tool calls. Never absolute `/Users/chm/dev/TrainMe/...` paths.
- No emojis anywhere — code, comments, commit messages, PR body, file names.
- Branch: `fix/safe-mode-accept-zero-detection` off `staging`.
- PR target: `staging` (NOT `main`). Carl promotes staging to main explicitly.
- Mobile + Flutter only — do NOT touch native iOS code, web-portal, web-player, or Supabase.
- No `CREATE OR REPLACE FUNCTION` — no RPC or schema changes are required.
- After any `.dart` edit, run `dart_analyze` (via the dart MCP) before reporting done.

## Acceptance criteria

(Copy from section 6 of `docs/specs/2026-05-25-safe-mode-accept-zero-detection.md`.)

## Files likely to change

- `app/lib/services/conversion_service.dart`
- `app/lib/screens/capture_mode_screen.dart` (toast copy)
- `docs/test-scripts/2026-MM-DD-safe-mode-zero-detection-accept.md` (new)
- `docs/test-scripts/index.html` (entry at top of active list)

Verify but probably no edit needed:

- `app/lib/services/upload_service.dart` (`_uploadRawArchives` swap logic)

## Deliverable

- PR title: `fix(safe-mode): accept zero-detection captures (no-PII landscape / equipment shots)`
- PR body: What changed, Why, How to test, Risk, Telemetry follow-up (flag the open question).
- Conventional Commits. No emojis.

## Out of scope

Per section 10 of `docs/specs/2026-05-25-safe-mode-accept-zero-detection.md`.
```
