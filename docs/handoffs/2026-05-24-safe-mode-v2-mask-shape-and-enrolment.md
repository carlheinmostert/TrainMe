# Handover — Safe Mode v2: mask-shape optimization + multi-reference enrolment + open device bugs

**Created:** 2026-05-24 by Claude. Context window getting full at the end of a long session; Carl asked to bundle remaining work as a handoff for a fresh session rather than spawning more agents.

**Status:** session produced 11 merged PRs (#455, #457, #458, #460, #461, #462, #463, #466, #467, #468, #471). Three bugs surfaced + diagnosed live: hydration still failing on device (not fixed), bench-tool color fidelity (introduced by my workaround), and head-expansion bbox darkening backgrounds + paint-over-subject (next-up work). One major UX redesign workshopped + signed off but not yet specced: Face-ID-style multi-reference enrolment.

## Table of contents

- [What landed this session](#what-landed-this-session)
- [Open bugs](#open-bugs)
- [Workshopped designs (signed off, not yet specced)](#workshopped-designs-signed-off-not-yet-specced)
- [Next agent briefs — ready to copy-paste](#next-agent-briefs--ready-to-copy-paste)
  - [Brief 1 — Mask shape optimization (Phases 1+2+3) + bench color fidelity](#brief-1--mask-shape-optimization-phases-123--bench-color-fidelity)
  - [Brief 2 — Multi-reference face enrolment (Face ID-style)](#brief-2--multi-reference-face-enrolment-face-id-style)
  - [Brief 3 — Hybrid pick-highest threshold logic](#brief-3--hybrid-pick-highest-threshold-logic)
  - [Brief 4 — Diagnose on-device hydration failure](#brief-4--diagnose-on-device-hydration-failure)
- [Reference data](#reference-data)
- [Memory rules that apply](#memory-rules-that-apply)
- [How to resume](#how-to-resume)

## What landed this session

Eleven PRs merged to `staging`, in order:

| PR | Title | Effect |
|---|---|---|
| #455 | bytea encoding fix | Embedding upload no longer 400s |
| #457 | v2 capture-time photo path | Capture invokes `applySafeModeV2ToPhoto` |
| #458 | hard-refuse on missing embedding | Rejects capture instead of silent fall-through (toast surfaces) |
| #460 | threshold 0.65 → 0.5 + bbox clamp 35% + NSLog cosSim | Initial tuning + diagnostics |
| #461 | hydrate face embedding from local SQLite | READ side of cold-start hydration |
| #462 | capture audit events from mobile | Photo/video captures land in `capture_audit_events` |
| #463 | debug-gated tuning sheet long-press | Slider for live threshold tuning |
| #466 | tuning sheet UX (hit-test + prominent preview) | Long-press works from all three surfaces |
| #467 | persist embedding to local SQLite on enrol | WRITE side of cold-start hydration |
| #468 | portal /audit feed includes capture events | Practice manager sees photo/video rows |
| #471 | macOS CLI bench tool for v2 photo pipeline | Mac-side diagnostic — pulls embedding from cloud, runs identical Swift pipeline, reports cosSim values |

**Staging branch DB issue resolved twice this session:** drift in `schema_migrations` (duplicate `capture_audit_events` rows at `20260523145446` + `20260523152359`) blocked Branching from applying the audit-feed migration. Dropped the duplicate at `20260523152359` + pushed empty commit. Branching applied the pending migration cleanly. Memory rule `feedback_supabase_branching_one_source` already captures the pattern from last session.

## Open bugs

### Bug A — Hydration STILL re-prompts for face fingerprint on cold start

**Symptom:** Carl re-enrols → banner clears for current session → force-quit + relaunch → "Prepare a face fingerprint" CTA returns.

**Investigation state:** the staging-tip code is verified correct:
- `face_embedding_service.dart:_runEnsure` does call `SyncService.instance.storage.updateClientFaceEmbedding(...)` after the cloud RPC succeeds (PR #467's diff confirmed via `git show bb8e348`)
- `local_storage_service.dart` has the `updateClientFaceEmbedding` method
- `cached_clients.face_embedding BLOB` column added at SQLite `_dbVersion = 45` via `_addColumnIfMissing` (line ~1315)
- Capture screen's `_refreshCachedClient` calls `FaceEmbeddingService.instance.hydrateFromBytes(cid, embedding)` when bytes present

**Two unproven hypotheses, both invisible without device-log access:**
1. The local SQLite write is silently failing inside the try/catch (only `debugPrint` — invisible without Console.app)
2. The schema migration to v45 didn't actually run on Carl's device (column missing → INSERT fails silently)

**Next-up:** Brief 4 below proposes the diagnostic instrumentation needed (Console.app-visible `os_log` with public format specifiers; SQL pull of `cached_clients.face_embedding` length via a one-off debug RPC).

### Bug B — Bench tool darkens output images

**Symptom:** the bench tool's safe-variant output images look subtly darker / desaturated than the input HEIC. Bench tool only — does NOT affect the iPhone (iOS code uses `NSNull` working/output colorspaces which preserves source values).

**Root cause:** my earlier workaround for the Mac-vs-iOS `NSNull` divergence (mask values mis-quantized to 0 on macOS, causing all-blur) was to **remove** `NSNull` from the CIContext options entirely. That fixed the mask but introduced sRGB gamma conversion on the source pixels.

**Fix (bundled into Brief 1):** restore `NSNull` on the CIContext AND pass `colorSpace: nil` to the maskCI initializer. That way:
- Source values pass through with no gamma conversion (color preserved)
- Mask R8 bytes read raw (no gamma) — mask quantization stays correct on macOS

### Bug C — Head-expansion bbox blurs background + paints over subject

**Symptom 1:** the bystander's blur is a rectangle, not a face-shape. Background around the bystander's head gets blurred too.

**Symptom 2:** if Carl is standing behind a bystander, the bystander's blur rectangle covers part of Carl — Carl gets "taken out of the background".

**Root cause:** `paintHeadExpansion` in `VideoConverterChannel.swift` (and the bench-tool port) paints the WHOLE head-expanded bbox to keepMask=0 unconditionally. No intersection with PersonSegmenter mask, no exclusion of subject silhouette pixels.

**Fix:** Brief 1, Phase 1 — paint only pixels that are (a) mask-positive (segmentation says "person") AND (b) not in the subject silhouette. Plus Phase 3 (feathered mask edges) so the blur transition is smooth instead of a sharp rectangle boundary. Phase 2 (face landmarks → oval) is the polish layer.

## Workshopped designs (signed off, not yet specced)

### Hybrid pick-highest threshold logic (Brief 3 below)

Replaces the current "absolute threshold" approach with relative ranking:

- **0 faces detected** → frame is sharp (defensive default — current behavior)
- **1 face detected** → that face IS the subject. Always sharp. **Trusts practitioner intent** (the camera was deliberately pointed at this person). Fixes IMG_1375 (cosSim 0.25 — subject would be blurred under any reasonable absolute threshold).
- **2+ faces detected** → pick the face with the **highest cosSim** as the subject. Sharp. Blur the rest. No absolute threshold.
- **Optional safeguard (low-cosSim floor on solo case only):** if 1 face AND cosSim < 0.10, treat as no-subject mode (blur it). Catches the bystander-alone-no-client edge case.

**Failure-mode analysis** (Carl's table, from bench results):

| Approach | Client blurred? (UX fail) | Bystander sharp? (Privacy fail) |
|---|---|---|
| Current — hard threshold 0.5 | HIGH (any non-frontal pose) | LOW |
| Pure "highest face wins" | NEVER | HIGH if client absent |
| **Hybrid (proposed)** | LOW | HIGH only when client absent + bystander present (rare in gym workflow) |
| Multi-reference embedding | LOW | LOW |
| Hybrid + multi-ref | LOWEST | LOWEST |

**Ship the hybrid first, multi-reference enrolment as the follow-up that closes the residual privacy gap.**

### Multi-reference face enrolment — Face ID-style (Brief 2 below)

**Carl's signoff:** replace the current single-photo avatar capture UI ENTIRELY with a Face ID-style rotating-head sweep.

**Why this is the right call:**
1. Same entry point already exists (tap client avatar slot on the client detail screen)
2. Avatar + face references are conceptually one thing — both describe "what this client looks like"
3. The sweep naturally produces both: auto-picked frontal frame becomes the avatar thumbnail, full 5-8 embeddings become the recognition reference set

**Flow:**
- Tap client avatar slot → enter new Face Enrolment screen
- Coral circle outline around face in viewfinder
- Arc progress ring fills as client slowly rotates head L→centre→R, then maybe up/down
- App captures ~30 frames during rotation, runs face-detection on each, picks 5-8 that span pose space (using face landmark angles), runs MobileFaceNet on each
- Auto-pick the most-frontal frame as the avatar JPG
- Store all 5-8 vectors in new `client_face_embeddings (client_id, slot_index, embedding bytea, model_version)` child table
- ~10-15 seconds end-to-end

**Match-time logic change:** Swift channel `applySafeModeV2ToPhoto` signature changes from `subjectEmbedding: Data` (single 2048-byte) to `subjectEmbeddings: [Data]` (array). For each detected face, cosSim against each stored vector; take the MAX as that face's score.

**Schema migration:**
- Add `client_face_embeddings (client_id uuid, slot_index smallint, embedding bytea, model_version smallint, PRIMARY KEY (client_id, slot_index))`
- Backfill: for clients with existing single-vector `clients.face_embedding`, copy into the new table as `slot_index=0`
- Keep `clients.face_embedding` column for one release cycle (backward compat), then drop in a subsequent migration

**This is the design that closes the IMG_1375 (sideways-pose) failure entirely** — IMG_1375 would match the "looking sideways" reference at ~0.7 instead of the frontal reference at 0.25.

## Next agent briefs — ready to copy-paste

### Brief 1 — Mask shape optimization (Phases 1+2+3) + bench color fidelity

```
# Task: Safe Mode v2 mask-shape optimization — intersect with segmentation, face oval, feathered edge, + bench color fidelity fix

## Context

Three compounding visual problems with v2 photo Safe Mode bystander blur (confirmed live by Carl 2026-05-24 against the macOS bench tool at `tools/safe-mode-v2-bench/`):

1. **Rectangular blur paints background pixels** — head-expansion bbox is painted unconditionally; pixels inside the bbox that are background (not part of any person silhouette) get blurred too. Visible as a coral-blurred square stuck on the photo.
2. **Bystander blur paints over subject** — if subject (client) is standing behind a bystander, the bystander's blur rectangle covers part of the subject. Subject gets "taken out of the background".
3. **Bench tool darkens the whole output image** — my earlier `NSNull` colorspace workaround for the Mac-only mask quantization bug fixed the mask but introduced sRGB gamma conversion. iOS code is unaffected (it uses NSNull).

## Constraints

- Repo-relative paths only. Never absolute `/Users/chm/dev/TrainMe/...`.
- No emojis anywhere.
- Branch: `fix/safe-mode-v2-mask-shape-and-color` off `staging`.
- PR target: `staging` (NOT main).
- Touch BOTH the iOS native code at `app/ios/Runner/VideoConverterChannel.swift` (`applySafeModeV2ToPhoto`) AND the bench tool at `tools/safe-mode-v2-bench/Sources/SafeModeBench/SafeModeV2Pipeline.swift`. The two must remain byte-equivalent (per the bench tool's design intent).

## Phase 1 — Intersect bbox painting with segmentation mask + exclude subject silhouette

Current code (both files) in the subject-identified mode and the no-subject mode does:
```
for each non-subject face:
  paintHeadExpansion(keepMask, pixelRect, headWidthFactor: 2.0, headHeightFactor: 1.5)
```
where `paintHeadExpansion` unconditionally writes 0 to every pixel inside the expanded bbox.

Replace `paintHeadExpansion`'s inner loop with a conditional write:
```
for each pixel in expanded bbox:
  if mask[pixel] >= 128                      // segmentation says "person"
     AND subjectComponent[pixel] == 0        // and not the subject's silhouette
  then keepMask[pixel] = 0                    // blur
  // else leave keepMask[pixel] alone (preserves background AND subject behind)
```

In no-subject mode (no subject identified), `subjectComponent` is the all-zero placeholder, so the second condition is trivially satisfied — the bystander blur still works correctly when there's no subject to protect.

For this to work `paintHeadExpansion` needs access to BOTH the segmentation mask AND the subject component. Pass both as parameters. The non-subject-mode call site passes a NULL/empty subjectComponent (or always-zero buffer) so the same function works for both modes.

## Phase 2 — Replace rectangular bbox with face oval from VNDetectFaceLandmarks

Today the pipeline uses `VNDetectFaceRectanglesRequest`. Switch to `VNDetectFaceLandmarksRequest` which returns the same boundingBox PLUS face contour landmarks (16-point face oval).

For each non-subject face:
1. Take the face contour points (the outermost face oval landmark — `faceContour` returns ~16 normalized points)
2. Expand each point outward by ~25% from the face center to cover hair / chin / forehead / ears
3. Rasterize the resulting polygon into the keepMask (alongside the segmentation-mask intersection from Phase 1) — pixels inside the polygon AND inside the segmentation mask get blurred

This makes the blur shape follow the face/head contour instead of being a rectangle. Subjectively reads as "obscured person" rather than "blurry box".

Document any divergence from the current bbox-area clamp (`maxAreaFraction: 0.35`) — the oval naturally limits area, so the clamp might become a no-op for typical poses. Keep the clamp as a defensive cap.

## Phase 3 — Feather the mask edges

Currently the blur transition is a hard 0/255 step in the keepMask → the eye can spot the bbox outline even though the inside is Gaussian-blurred. Apply a small Gaussian blur to the MASK itself (radius ~8-12px scaled to frame size) before passing to CIBlendWithMask. The transition becomes a smooth fade over a 10-20px band.

Add the mask-feather step in BOTH files:
```
// Feather the keepMask edges. Same CIContext, just one extra CIFilter.
let featherRadius = 10.0 * max(1.0, minDim / 1080.0)
let maskBlurFilter = CIFilter(name: "CIGaussianBlur")!
maskBlurFilter.setValue(maskCI, forKey: kCIInputImageKey)
maskBlurFilter.setValue(featherRadius, forKey: kCIInputRadiusKey)
let featheredMask = maskBlurFilter.outputImage!.cropped(to: sourceCI.extent)
// Use `featheredMask` instead of `maskCI` in the CIBlendWithMask call.
```

## Phase 4 (bench-tool only) — Restore color fidelity

The bench tool currently uses the default CIContext (sRGB working colorspace) because the NSNull approach broke mask quantization on macOS. Carl noticed the resulting output is darker than the iOS-produced version.

Fix:
1. Restore `NSNull` on the CIContext options (matches iOS — no source gamma conversion):
   ```
   let ciOptions: [CIContextOption: Any] = [
       .workingColorSpace: NSNull(),
       .outputColorSpace: NSNull(),
   ]
   ```
2. Change the maskCI initializer to pass `colorSpace: nil` (raw R8 passthrough — no gamma conversion on the mask):
   ```
   let maskCI = CIImage(
       bitmapData: maskBytes,
       bytesPerRow: width,
       size: CGSize(width: width, height: height),
       format: .R8,
       colorSpace: nil  // KEY CHANGE — was CGColorSpaceCreateDeviceGray()
   )
   ```

This gives the bench tool color fidelity equivalent to iOS native output. Validate by re-running against Carl's 6 sample HEIC files at `/Users/chm/Desktop/Training Pic/` and confirming the output looks color-faithful (no darkening) AND the mask still works (sharp where it should be sharp).

## Validation

After the changes, re-run the bench tool sweep against Carl's 6 sample photos:
- Photos: `/Users/chm/Desktop/Training Pic/IMG_1372.HEIC` through `IMG_1377.HEIC`
- Embedding: pull from staging client `53004519-9b14-45d2-87c0-ac376b19b0b7` via `mcp__supabase__execute_sql` (`SELECT encode(face_embedding, 'hex') FROM clients WHERE id = '...';` → decode hex → `samples/embedding.bin` as 2048 raw bytes)
- Run `swift run -c release SafeModeBench --photo <p> --embedding samples/embedding.bin --threshold 0.5 --output /tmp/out.jpg` for each
- Confirm:
  - IMG_1376 + IMG_1377 (group photos): the OTHER person's face/head silhouette is blurred but background and any other body pixels are sharp; subject (Carl) is fully sharp including any body parts behind the bystander
  - IMG_1372 + IMG_1374 (solo Carl, identified): no visible darkening of the whole frame vs the input HEIC

Build an updated HTML report at `/Users/chm/Desktop/Safe Mode Bench Report.html` (mirror the existing one's structure) embedding side-by-side originals + new outputs.

## Acceptance criteria

1. iOS Swift `paintHeadExpansion` (or equivalent inside `applySafeModeV2ToPhoto`) only paints pixels that are mask-positive AND not in the subject silhouette.
2. Bench tool's equivalent does the same.
3. Both pipelines use `VNDetectFaceLandmarksRequest` instead of `VNDetectFaceRectanglesRequest`; the face oval polygon constrains the blur shape.
4. Both pipelines apply a small Gaussian blur to the mask (feather) before the CIBlendWithMask composite.
5. Bench tool restores `NSNull` colorspace + uses `colorSpace: nil` on maskCI; output color fidelity matches the input HEIC.
6. `mcp__dart__analyze_files` clean (no Dart changes expected, but run to confirm).
7. Re-run validation against Carl's 6 sample photos; bundled HTML report shows the improvements visually.

## Deliverable

- PR title: `fix(safe-mode-v2): face-oval blur shape, segmentation-aware bbox painting, feathered edges, bench color fidelity`
- PR body sections: **What changed**, **Why** (Carl's three complaints from 2026-05-24), **How to test** (bench tool sweep + Carl on iPhone after install), **Risk** (Vision landmarks API behavior on iOS 15+ vs simulator — document any divergence).
```

### Brief 2 — Multi-reference face enrolment (Face ID-style)

```
# Task: Face ID-style multi-reference face enrolment — replace single-photo avatar capture

## Context

Today's v2 Safe Mode uses a single face embedding per client, derived from the practitioner's single avatar photo. This forces a global cosSim threshold trade-off:
- Threshold too low → bystanders falsely identified as subject (privacy breach)
- Threshold too high → subject blurred when looking sideways or under different lighting (UX failure)

Carl's IMG_1375 (sideways pose, cosSim 0.25) confirms this isn't avoidable with a single reference.

Carl signed off on Face ID-style multi-reference enrolment (2026-05-24): replace the single-photo avatar capture UI entirely with a rotating-head sweep that captures 5-8 face embeddings spanning the client's pose space.

## Spec doc + mockup first

Before any code, ship a spec doc + interactive HTML mockup direct-to-main:

- `docs/specs/2026-05-24-safe-mode-v2-multi-reference-enrolment.md` — full spec with:
  - Why (the IMG_1375 problem + bystander overlap)
  - UX flow (tap avatar → rotating-head sweep → 5-8 frame auto-pick → confirm)
  - Schema change (`client_face_embeddings (client_id, slot_index, embedding, model_version)` child table)
  - Backward-compat migration (existing single-vector `clients.face_embedding` → backfill as `slot_index=0` in new table)
  - Match-time semantics (cosSim against MAX of stored vectors per detected face)
  - Native channel signature change (`subjectEmbedding: Data` → `subjectEmbeddings: [Data]`)
  - UX affordances (re-enrol flow — same entry point)
  - Failure modes (client refuses to rotate head, partial sweep, etc.)

- `docs/design/mockups/safe-mode-v2-enrolment.html` — interactive mockup of the enrolment screen:
  - Coral circle outline around face in viewfinder
  - Animated arc progress ring (CSS keyframe; fills as user "rotates" head — for mockup purposes, advance on tap)
  - Instructions text: "Slowly turn your head from left to right"
  - Confirm screen showing the 5-8 auto-picked frames + the chosen avatar thumbnail
  - Modeled on Apple's Face ID setup dome (minus TrueDepth visualization)
  - Carl opens in Cmd+Shift+V markdown/HTML preview pane

Both docs go to `main` directly per `feedback_specs_direct_to_main`. Commit them via ephemeral worktree from main, push, then `git checkout origin/main -- <files>` to pull them into Carl's current worktree so they appear in his files panel.

Stop after spec + mockup land. Do NOT implement the schema or code changes — Carl will review the mockup first.

## Reference data (for spec doc)

- Bench tool report (`/Users/chm/Desktop/Safe Mode Bench Report.html`) showed:
  - Subject cosSim range across 6 poses: 0.25 to 0.78
  - Bystander cosSim range: 0.31 to 0.36
  - IMG_1376's bystander (0.36) > IMG_1375's subject (0.25) → no clean global threshold
- Match-time logic must combine with the hybrid pick-highest (Brief 3): each detected face computes MAX cosSim across the 5-8 reference vectors; the relative ranking is what picks the subject

## Out of scope

- Schema migration apply (specced only)
- Native channel signature change (specced only)
- UI implementation
- All of the above ship in a follow-up PR after Carl signs off on the mockup
```

### Brief 3 — Hybrid pick-highest threshold logic

```
# Task: Hybrid pick-highest threshold logic for Safe Mode v2

## Context

Workshop output 2026-05-24 — Carl identified that the current absolute-threshold approach fails for legitimate poses (sideways looks, gym situations). New design: use cosSim RELATIVELY (rank within frame) instead of ABSOLUTELY (above/below global threshold).

Rules:
- 0 faces detected → frame is sharp (defensive — current behavior, no change)
- 1 face detected → that face IS the subject. Always sharp. Trusts practitioner intent.
- 2+ faces detected → pick the face with the highest cosSim as the subject. Sharp. Blur the rest. No absolute threshold.
- Optional low-cosSim floor on solo case only: if 1 face AND cosSim < 0.10, treat as no-subject mode (blur it). Catches the bystander-alone-no-client edge case.

This replaces the current `kSafeModeV2FaceMatchThreshold = 0.5` const. The threshold is no longer a global decision boundary — it's only used as the optional solo-floor.

## Constraints

- Repo-relative paths only.
- No emojis.
- Branch: `feat/safe-mode-v2-hybrid-pick-highest` off `staging`.
- PR target: `staging`.
- Touches BOTH iOS native (`app/ios/Runner/VideoConverterChannel.swift` — `applySafeModeV2ToPhoto`) AND bench tool (`tools/safe-mode-v2-bench/Sources/SafeModeBench/SafeModeV2Pipeline.swift`).

## Implementation

In `applySafeModeV2ToPhoto` (both files), the subject identification block currently looks like:
```
var subjectIdx: Int? = nil
var bestSim = -2.0
for (i, f) in faces.enumerated() {
    if f.cosSim > bestSim {
        bestSim = f.cosSim
        subjectIdx = i
    }
}
let subjectIdentified: Bool
if let _ = subjectIdx, bestSim >= threshold {
    subjectIdentified = true
} else {
    subjectIdentified = false
}
```

Replace with:
```
var subjectIdx: Int? = nil
var bestSim = -2.0
for (i, f) in faces.enumerated() {
    if f.cosSim > bestSim {
        bestSim = f.cosSim
        subjectIdx = i
    }
}

let subjectIdentified: Bool
let kSoloFloor = 0.10
if faces.count == 0 {
    subjectIdentified = false  // no-faces: defensive sharp (existing missRate=0.0 case)
} else if faces.count == 1 {
    // Solo face: trust practitioner intent UNLESS cosSim is suspiciously low
    // (catches bystander-alone-no-client). The 0.10 floor is well below any
    // legitimate same-person cosSim (Carl's worst was 0.25) but above the
    // typical bystander cosSim (random faces cluster 0.15-0.40).
    subjectIdentified = (bestSim >= kSoloFloor)
} else {
    // 2+ faces: relative pick — the highest-scoring face is the subject.
    // No absolute threshold gate.
    subjectIdentified = true
}
```

Update the DECISION NSLog line to include the new branch reason for debugging:
```
NSLog("[SafeMode v2] faces=%d bestSim=%.3f subjectIdentified=%@ branch=%@",
      faces.count, bestSim,
      subjectIdentified ? "true" : "false",
      faces.count == 0 ? "no-faces" :
        (faces.count == 1 ? "solo-floor" : "multi-relative"))
```

The Dart `kSafeModeV2FaceMatchThreshold` const stays but gets renamed to `kSafeModeV2SoloFloor = 0.10` (semantic shift — no longer an absolute threshold). All call sites updated. The debug-gated tuning sheet (`app/lib/widgets/debug/safe_mode_v2_tuning_sheet.dart`) becomes a "Solo-face floor" slider rather than a "Threshold" slider — label change + value range [0.0, 0.5] instead of [0.0, 1.0].

## Test-script append

In `docs/test-scripts/2026-05-23-safe-mode-embedding-roundtrip.md`, append:
- Item N: take a solo selfie at a sideways angle (mimics IMG_1375). Subject should be sharp (was previously blurred due to absolute threshold).
- Item N+1: take a group photo (you + bystander). Bystander should be blurred even if bystander cosSim > subject's worst-case cosSim — relative pick wins.
- Item N+2: have a bystander stand alone in front of the camera (you not in frame). Verify: their face should be sharp at the new solo-rule (cosSim > 0.10 floor). Per the design, this is the "intended" behavior — the practitioner pointed the camera deliberately. Privacy gap closes with multi-reference enrolment (Brief 2).

## Acceptance criteria

1. Single-face frames always identify the subject when cosSim > 0.10 floor.
2. Multi-face frames use relative-highest pick (no absolute threshold).
3. Zero-face frames stay defensively sharp.
4. NSLog includes branch reason.
5. Dart const renamed + tuning sheet labelled accordingly.
6. `mcp__dart__analyze_files` clean.

## Deliverable

- PR title: `feat(safe-mode-v2): hybrid pick-highest threshold — trust practitioner intent on solo, rank-pick on multi-face`
- PR body sections: **What changed**, **Why** (Carl's IMG_1375 problem + workshop), **How to test** (test-script items), **Risk** (single-bystander-alone case is intentionally permissive; multi-reference enrolment (Brief 2) closes that gap as a follow-up).
```

### Brief 4 — Diagnose on-device hydration failure

```
# Task: Diagnose why face-embedding hydration still re-prompts on cold start

## Context

PR #461 (cold-start hydration READ side) + PR #467 (enrol-time SQLite WRITE side) were both meant to close the "Prepare a face fingerprint CTA re-appears after force-quit" bug. Both landed and are confirmed correct in the staging-tip source.

Carl re-verified live 2026-05-24: re-enrol works for current session, but force-quit + relaunch → CTA returns. The fix is not working on his device.

Without device-log access, two unproven hypotheses:
1. Local SQLite write silently fails inside the try/catch (`debugPrint` only — invisible without Console.app)
2. SQLite schema migration to `_dbVersion = 45` didn't actually run on his device (column missing → INSERT fails silently)

## Diagnostic instrumentation needed

Add Console.app-visible `os_log` (NOT NSLog) statements at:
1. `FaceEmbeddingService._runEnsure`, right after `updateClientFaceEmbedding` returns — log success or caught-exception detail:
   ```
   debugPrint('[FaceEmbeddingService] local SQLite write succeeded for client=$clientId, bytes=${bytes.length}');
   ```
   Even though it's debugPrint, in profile builds it should still route to os_log via Flutter's bridge.

2. `LocalStorageService.updateClientFaceEmbedding` — log the rowsAffected count from the UPDATE:
   ```
   final n = await db.update(...);
   debugPrint('[LocalStorage] cached_clients.face_embedding UPDATE rowsAffected=$n for client=$clientId');
   ```
   If rowsAffected is 0, the row doesn't exist locally (sync hasn't pulled the client yet) — that's a separate bug.

3. `_refreshCachedClient` in `capture_mode_screen.dart` — log what `cached.faceEmbedding` reads back as:
   ```
   debugPrint('[CaptureScreen] _refreshCachedClient: cid=$cid faceEmbedding.length=${cached?.faceEmbedding?.length ?? "null"}');
   ```

4. `FaceEmbeddingService.hydrateFromBytes` — log every call:
   ```
   debugPrint('[FaceEmbeddingService] hydrateFromBytes called: cid=$clientId bytes=${bytes.length}');
   ```

Critically, the iOS-side `os_log` usage in `VideoConverterChannel.swift` MUST use `%{public}` format specifiers so values are visible (not redacted to `<private>`). Existing `NSLog("[SafeMode v2] face[%d] cosSim=%.3f", i, f.cosSim)` uses bare `%d`/`%.3f` — verify whether those are masked in profile-build console output and fix if so by switching to `os_log` with explicit public modifiers.

## Reproduction protocol (Carl runs this on device)

1. Open Console.app on Mac
2. Select iPhone CHM in sidebar (Devices)
3. Filter for `[FaceEmbeddingService]` OR `[LocalStorage]` OR `[CaptureScreen]`
4. On phone: force-quit app, relaunch, open an enrolled client → new session
5. Read the log:
   - If `_refreshCachedClient` logs `faceEmbedding.length=null` → SQLite write isn't landing (Bug A1 or A2)
   - If `_refreshCachedClient` logs a length but `hydrateFromBytes` isn't called → wire-up bug
   - If `hydrateFromBytes` IS called but banner still shows CTA → state-machine bug elsewhere

## Constraints

- Repo-relative paths only.
- No emojis.
- Branch: `chore/safe-mode-v2-hydration-diagnostics` off `staging`.
- PR target: `staging`.
- All instrumentation should be guarded by `kDebugMode || const String.fromEnvironment('ENV') == 'staging'` so prod builds don't spew debugPrint.

## Acceptance criteria

1. All four log points instrumented with Carl-readable tags.
2. iOS-native NSLogs use `%{public}` format specifiers OR switch to `os_log` with `OSLog(subsystem: "studio.homefit.app.dev", category: "SafeMode")` for Console.app visibility.
3. Test-script item appended documenting the Console.app reproduction protocol.
4. `mcp__dart__analyze_files` clean.

## Deliverable

- PR title: `chore(safe-mode-v2): add hydration-path diagnostics for Console.app debugging`
- PR body sections: **What changed**, **Why** (PR #461 + #467 are correct in source but failing on Carl's device — need device-log visibility), **How to test** (reproduction protocol), **Risk** (debug-only logging, no behavior change).
```

## Reference data

### Carl's test setup

- **iPhone CHM UDID:** `00008150-001A31D40E88401C`
- **Latest staging build SHA on iPhone at handoff:** `bb8e348` (installed 2026-05-24 08:57 SAST)
- **Test client UUID:** `53004519-9b14-45d2-87c0-ac376b19b0b7`
- **Test practice UUID:** `23d23dd6-41ee-40ec-b56f-ebdf35d9ddc9`
- **Sample photos:** `/Users/chm/Desktop/Training Pic/IMG_1372.HEIC` through `IMG_1377.HEIC` (6 HEIC files: 2 solo selfies, 1 sideways, 1 no-face, 2 group photos with bystander)
- **Bench tool location:** `/Users/chm/dev/TrainMe/.claude/worktrees/agent-a946b3e830966528f/tools/safe-mode-v2-bench/` (works on disk; PR #471 open for merge)
- **Bench report:** `/Users/chm/Desktop/Safe Mode Bench Report.html` (24 MB, all images base64-embedded)
- **Output images:** `/Users/chm/Desktop/Safe Mode Bench Output/` (with the WORKAROUND colorspace fix; will be regenerated by Brief 1 with proper color fidelity)

### Bench results table (Carl's 6 photos at threshold 0.5)

| Photo | Faces | Subject cosSim | Bystander cosSim | Decision | Blur % |
|---|---|---|---|---|---|
| IMG_1372 | 1 | 0.5405 | — | identified | 0.0% |
| IMG_1373 | 0 | — | — | no-faces | 0.0% |
| IMG_1374 | 1 | 0.7750 | — | identified | 0.0% |
| IMG_1375 | 1 | 0.2504 | — | NOT identified (failed) | 35.0% |
| IMG_1376 | 2 | 0.6724 | 0.3593 | identified (you) | 15.5% |
| IMG_1377 | 2 | 0.5908 | 0.3052 | identified (you) | 30.3% |

### Embedding fetch

The bench tool's `samples/embedding.bin` is Carl's enrolled face embedding pulled from the staging DB. To refresh:

```sql
SELECT encode(face_embedding, 'hex') FROM clients WHERE id = '53004519-9b14-45d2-87c0-ac376b19b0b7';
```

Decode hex to raw bytes (2048 bytes expected):
```sh
echo -n "<hex_string>" | xxd -r -p > samples/embedding.bin
```

## Memory rules that apply

- `feedback_supabase_branching_one_source` — never `apply_migration` while Branching is healthy. Both 2026-05-23 + 2026-05-24 saw drift recoveries; the auto-mode classifier now correctly blocks `apply_migration` calls.
- `feedback_no_silent_fallbacks` — the head-expansion bbox painting WAS a silent failure (background got blurred without anyone realizing); Brief 1 fixes it.
- `feedback_delegate_coding` — multi-file Swift + Dart work spawns to agents, not inline. All 4 briefs above are agent-shaped.
- `feedback_specs_direct_to_main` — Brief 2's spec + mockup go direct to main, not via PR.
- `feedback_branch_naming_discipline` — branch names follow `fix/` / `feat/` / `chore/` / `docs/` prefix. All 4 briefs comply.
- `feedback_test_scripts_as_markdown` — test items go to `docs/test-scripts/<date>-<slug>.md` with stable numbering.
- `feedback_no_direct_db_access` — all DB reads/writes through enumerated SECURITY DEFINER RPCs. Bench tool's `fetch_embedding.sh` uses raw psql — that's developer-tool territory, exempt from the rule.
- `gotcha_ios_debug_needs_debugger` — iPhone builds must be `--profile` not `--debug` (debug white-screens without `flutter run` attached).
- `gotcha_test_scripts_index_cascade` — grep for conflict markers after every test-script merge resolve.

## How to resume

1. **Read the open bug + workshop sections above** to load the design context.
2. **Decide which brief to dispatch first.** My recommendation:
   - Brief 1 first (mask-shape + bench color) — biggest immediate UX win, validates against the bench tool without device cycles.
   - Brief 3 second (hybrid pick-highest) — small change, big behavioral impact, unblocks Carl's "blurred when looking sideways" complaint.
   - Brief 4 in parallel (hydration diagnostics) — independent, no merge conflicts with the others.
   - Brief 2 last (multi-reference enrolment spec + mockup) — bigger UX redesign, ship spec first, code later.
3. **For each brief:** copy-paste verbatim into the `homefit-agent-brief` skill workflow. Spawn with `isolation: worktree`, `run_in_background: true`. The briefs are already self-contained — agents don't need outside context to execute.
4. **Coordinate test-script numbering.** All four briefs add items to `docs/test-scripts/2026-05-23-safe-mode-embedding-roundtrip.md`. The last-added item was 26 (after the previous handover wave). Expect conflicts when multiple PRs land — resolve by renumbering contiguously per `feedback_test_wave_discipline`.
5. **iPhone install cadence:** bundle Briefs 1+3 into one install cycle. Brief 4's instrumentation may need its own install for the diagnostic to be useful. Brief 2 is doc-only — no install needed.
6. **Bench tool re-validation:** after Brief 1 lands, re-run the sweep against Carl's 6 photos and regenerate `/Users/chm/Desktop/Safe Mode Bench Report.html` so Carl can eyeball the improvements before the iPhone install.

## Loose ends

- **PR #471 (bench tool) still open at handoff.** Auto-merge it once Flutter CI re-passes if desired. The bench tool already works on disk regardless.
- **Memory entry for "Mac-vs-iOS CIBlendWithMask NSNull divergence"** worth capturing once Brief 1 ships the proper fix — currently the fix is undocumented as a memory rule. Suggested file: `gotcha_cibrand_mask_nsnull_mac_quantization.md` (type: gotcha).
- **The 2026-05-23 handoff's Task 2 (Supabase Branching reconciliation)** was resolved in that session; this handoff's drift fix at 09:16 SAST 2026-05-24 was a fresh recurrence, not a leftover.
