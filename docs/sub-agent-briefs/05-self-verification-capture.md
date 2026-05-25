# Brief — PR #5: Capture-time self-verification + exercises.self_verified stamping

**Target branch:** `feat/self-verification-capture`
**Target merge:** `staging`
**Depends on:** PR #1 (schema), PR #3 (face embedding native)
**Sensitive zone:** `app/lib/services/conversion_service.dart` (per `feedback_sensitive_code_review_before_merge`)

## Context

`docs/SELF_TRAINER_WAVE.md` § "Capture-entry path from My Workouts" § 5 + § "Schema deltas" § 6.

After capture + conversion, run MobileFaceNet on the captured frames; compare largest face to the user's registered embedding; stamp `exercises.self_verified` accordingly. This is the input to the publish-cost decision in PR #6.

## Acceptance criteria

1. **Native compare method** — `app/ios/Runner/HomefitFaceEmbeddingChannel.swift` (existing from PR #3) gains a second method: `verifyAgainstReference(videoPath: String, referenceEmbedding: [Float]) -> {matched: Bool, distance: Double}`. Loads MobileFaceNet, samples N frames from the video (e.g. 3 frames evenly), runs face detection per frame, takes largest face per frame, computes embedding, averages, compares cosine distance to reference embedding. Threshold: distance ≤ 0.6 = matched. (Confirm threshold against Safe Mode v2's existing discriminator threshold.)

2. **Photo path** — same method handles photo (single frame); branch on file extension. Use the safe variant if Safe Mode was active.

3. **ConversionService integration** — in `app/lib/services/conversion_service.dart`, after the existing conversion pipeline completes for an exercise:
   - Read `practitioners.face_embedding` from cache (must already be present since user opted in; if NULL, skip — leaves `self_verified` NULL).
   - Invoke native compare against the converted file.
   - Write result to local SQLite `exercises.self_verified` (boolean column; existing `exercises` table; SQLite v45 bump).
   - On publish, the value syncs to cloud `exercises.self_verified` (column added in PR #1).

4. **No capture blocking** — verification failure (mismatch or no face) does NOT block capture or conversion. The flag is purely informational; feeds the publish cost in PR #6.

5. **Conservative on missing data** — if reference embedding is NULL OR native compare throws OR no face detected → `self_verified = false`. Treat unknown as "not verified" so the publish path charges credits by default.

6. **Performance** — compare runs in background after conversion completes. Don't block UI. Already-converted exercises (legacy) get `self_verified = NULL`; the publish flow treats NULL as false.

7. **Test script** — `docs/test-scripts/2026-05-25-self-verification.md`. Items: (a) capture yourself (registered): `self_verified=true` stamped within 5s of conversion done; (b) capture gym equipment (no face): `self_verified=false`; (c) capture a different person: `self_verified=false`; (d) capture before consent given: `self_verified=NULL`; (e) re-take with different reference: re-verification reflects new reference.

## Hard rules

- **Repo-relative paths only**.
- **Sensitive zone — Carl reviews ConversionService changes before merge.**
- **No direct DB access from Dart for cloud writes** — local SQLite is fine for `self_verified` cache; cloud sync happens on publish via the existing `replace_plan_exercises` RPC (which needs the column added in PR #1).
- **R-10 N/A**.
- **No mobile deployment.**
- **No emojis.**
- **Branch**: `feat/self-verification-capture`.
