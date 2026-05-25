import Flutter
import UIKit
import AVFoundation
import Accelerate
import Vision
import CoreVideo
import CoreImage
import Metal
import os.log

// MARK: - Safe Mode v2 diagnostics log
//
// Console.app-visible structured log for the face-recognition path.
// Filter in Console.app on subsystem `studio.homefit.app.dev` +
// category `SafeMode` (or grep `[SafeMode v2]`) to follow per-capture
// face matching + threshold values during device QA. All values use the
// `%{public}` format specifier so they survive profile-build redaction
// (bare `%d`/`%.3f` would otherwise show as `<private>` in Console.app).
private let safeModeLog = OSLog(
    subsystem: "studio.homefit.app.dev",
    category: "SafeMode"
)

// MARK: - Line-drawing tuning constants (tweak-and-reinstall friendly)
//
// Exposed as named top-level constants so Carl can nudge them after device
// testing without re-spelunking the pipeline. Each constant is annotated with
// its previous ("old") hardcoded value and the current tuned value. Baseline:
// Carl's feedback 2026-04-19 — "line drawing must have more details and be
// less intense." More details ⇒ lower the edge-detection threshold. Less
// intense ⇒ lighten the black line overlay.
//
// The two-zone rendering (body crisp via Vision person segmentation,
// equipment at ~35%) lives below in `applyMaskedDim` and is intentionally
// NOT touched by these constants.
//
// Contract:
//   - `edgeThresholdLo` controls how sensitive the adaptive threshold is.
//     It replaces the previously-hardcoded `c = 2` offset inside
//     `adaptiveThreshold`. A gray pixel becomes BLACK (edge) when
//     `gray < localMean - edgeThresholdLo`. Lower value ⇒ more pixels pass
//     the test ⇒ more edges / finer detail preserved.
//         old: 2
//         new: 1   (≈30% reduction in the detection threshold → more detail)
//
//   - `edgeThresholdHi` is a multiplicative dampener on the Dart-supplied
//     `contrastLow` value (AppConfig.contrastLow = 80). The contrast-boost
//     pass clips anything below `contrastLow` to black and stretches the
//     rest. Scaling `contrastLow` down by `edgeThresholdHi` keeps more of
//     the faint mid-gray sketch strokes alive through the boost. Applied
//     as `effectiveContrastLow = Int(Double(contrastLow) * edgeThresholdHi)`.
//         old:   1.0   (use contrastLow as-is)
//         v1:    0.70  (≈30% reduction → too many faint edges, washed out)
//         v2:    0.88  (mild reduction → more detail, still discriminating)
//
//   - `lineAlpha` is a post-pipeline intensity scale on how dark the final
//     line pixels render. Applied as a LUT:
//         `out = 255 - (255 - gray) * lineAlpha`
//     White stays white (dim(255) = 255); black lines drop toward gray.
//         old:   1.0   (full-black lines)
//         v1:    0.65  (too grey — combined with v1 edgeThresholdHi, image
//                      looked "overexposed" — uniform grey, no crisp blacks)
//         v2:    0.85  (subtle softening — blacks still read as black)
//
// Tuning history:
//   v0 (pre-2026-04-19) original:      lo=2, hi=1.0,  alpha=1.0,  bgDim=0.35
//   v1 (2026-04-19 "less intense"):    lo=1, hi=0.70, alpha=0.65, bgDim=0.35  ← overexposed
//   v2 (2026-04-20):                   lo=1, hi=0.88, alpha=0.85, bgDim=0.35
//   v3 (2026-04-20 post BGRA fix):     lo=1, hi=0.88, alpha=0.90, bgDim=0.35
//   v4 (2026-04-20 "+20% darker"):     lo=1, hi=0.88, alpha=0.92, bgDim=0.35
//   v5 (2026-04-20 "+50% darker"):     lo=1, hi=0.88, alpha=0.96, bgDim=0.35
//   v6 (2026-04-20 "no progression"):  lo=1, hi=0.88, alpha=0.96, bgDim=0.70
//     ↑ Carl reported no visible darkness progression from v3..v5 even
//     though lineAlpha increased significantly. Root cause: lineAlpha
//     only darkens the BODY-zone pixels (person silhouette from Vision
//     segmentation). The background zone (floor, walls, equipment —
//     the majority of a typical gym frame) gets its own hardcoded
//     0.35 dim factor in applyMaskedDim. bgDim=0.35 clamps background
//     lines at ~166/255 regardless of lineAlpha. v6 doubles bgDim to
//     0.70 so background black pixels now land at ~76/255 — dark grey
//     instead of mid grey. Expect the equipment + environment sketches
//     to feel substantially darker now.
//   v7 (2026-04-22 "up the segmentation"): lo=1, hi=0.88, alpha=0.96, bgDim=0.50
//     ↑ Carl's 2026-04-22 ask: "can we up the segmentation video effect
//     which separates subject from background?" bgDim was over-lifting
//     the background zone — at 0.70 a black line lands at ~76/255, only
//     ~70% dimmed, so the body no longer popped against the environment.
//     Dropping bgDim to 0.50 pushes background black pixels to ~128/255
//     (mid grey) while the body zone stays untouched at full line-alpha
//     intensity, restoring the subject/background contrast. Edge + line
//     tuning unchanged — this is purely a segmentation-strength bump,
//     not an edge-detection change. Vision quality level already on
//     `.accurate` since v6; no change there.
//   v7.1 (2026-04-23 "segmented colour companion"):
//     lo=1, hi=0.88, alpha=0.96, bgDim=0.50 (UNCHANGED — tuning LOCKED).
//     Structural change only: `convertVideo` now runs a dual-output pass.
//     The existing line-drawing pipeline is unchanged; a SECOND writer
//     produces a parallel segmented-COLOUR .mp4 that applies the same
//     Vision person mask (body = full-colour passthrough; background =
//     dimmed colour via the shared `backgroundDim` constant). No edge
//     detection, no coral lines — this is the colour twin of the line
//     drawing. The segmented file is uploaded alongside the untouched
//     original to `raw-archive/{practice}/{plan}/{exercise}.segmented.mp4`
//     so the web player's Color and B&W treatments gain the body-pop
//     effect (B&W is CSS-filtered from the same source). The Vision
//     mask is generated ONCE per frame and consumed by both outputs.
//     Carl's 2026-04-22 signoff: "always keep the original file as well"
//     — the original untouched raw-archive file continues to upload;
//     the segmented file is additive, not a replacement.
//   v7.2 (2026-04-23 "mask sidecar"):
//     lo=1, hi=0.88, alpha=0.96, bgDim=0.50 (UNCHANGED — tuning LOCKED).
//     Structural change only: the dual-output pass gains a THIRD writer
//     that emits the Vision person-segmentation mask itself as a
//     grayscale H.264 mp4 sidecar. Same resolution + fps as the line-
//     drawing + segmented outputs so the mask is pixel-perfect aligned
//     with the segmented-colour file. Body luminance = 255 (full white
//     where the person is), background = 0 (black where they aren't);
//     the Planar8 mask is up-converted to BGRA for H.264 compatibility
//     because most H.264 encoders refuse single-channel input. Video-
//     only writer — no audio track (mask audio would be meaningless).
//     Uploaded to `raw-archive/{practice}/{plan}/{exercise}.mask.mp4`
//     and exposed via `get_plan_full` as a `mask_url` key. Insurance
//     for future playback-time compositing: today the mask has NO
//     consumer; storing it now means already-published plans will have
//     the data available when tunable backgroundDim / other effects
//     land, without needing to re-capture. Mask writer failure is
//     non-fatal — line-drawing + segmented passes continue.
//   v8 (2026-05-03 "hand-region mask dilation"):
//     lo=1, hi=0.88, alpha=0.96, bgDim=0.50 (UNCHANGED — tuning LOCKED).
//     Structural change only: `PersonSegmenter` now augments the Vision
//     person-segmentation mask with a hand-pose pass via
//     `VNDetectHumanHandPoseRequest` (iOS 14+, max two hands). For each
//     detected hand we paint a filled disc onto the mask centred on
//     the hand's keypoint centroid; radius adapts to the hand's
//     keypoint spread plus a base padding of `handDilationRadiusMin`.
//     Pixels under the disc become body (255), so dumbbells, bands,
//     cables, kettlebell handles — anything the practitioner is
//     gripping — fall inside the body zone of the existing two-zone
//     blend instead of getting dimmed into the background. The
//     existing `applyMaskedDim` tent-convolve still softens the
//     boundary, so the dilation reads as a smooth bulge around the
//     hands rather than a hard circle.
//     Cost: ~5–15ms/frame on Neural Engine on top of the existing
//     person-segmentation request. No-op when no hands are detected
//     (e.g. bodyweight push-ups) — `VNDetectHumanHandPoseRequest`
//     returns no observations and the mask passes through unchanged.
//     Tunable via `handDilationEnabled` / `handDilationRadiusFraction`
//     / `handDilationRadiusMin` / `handDilationConfidenceMin` below.
//     Same dilation runs for the line-drawing pass, the segmented-
//     colour companion (v7.1), AND the `processClientAvatar` /
//     `processPhotoBodyFocus` thumbnail paths via the shared
//     `PersonSegmenter`.
//
//   ✅ Edge / line tuning (edgeThresholdLo, edgeThresholdHi, lineAlpha)
//      remains LOCKED at v6 by Carl on 2026-04-20. Do NOT change these
//      three constants without explicit Carl-sign-off — they're the
//      product's signature line-drawing aesthetic.
//
//   ✅ Segmentation tuning (backgroundDim) bumped to v7 on 2026-04-22
//      with Carl's signoff. Subject/background separation is a separate
//      visual axis from edge detection; if the body isn't popping enough
//      on device, this is the first knob to turn.
//
// Safe tuning ranges (if you want to experiment on device):
//   edgeThresholdLo  : 0 … 4   (int)
//   edgeThresholdHi  : 0.5 … 1.0
//   lineAlpha        : 0.3 … 1.0    (darkens BODY zone only)
//   backgroundDim    : 0.2 … 1.0    (darkens BACKGROUND zone; 1.0 removes
//                                    the two-zone effect entirely)
private let edgeThresholdLo: Int = 1
private let edgeThresholdHi: Double = 0.88
private let lineAlpha: Double = 0.96

/// Two-zone dim applied to non-body (background) pixels after the main
/// line-drawing pipeline. Uses the same lift-from-black formula as
/// `lineAlpha` (`out = 255 - (255 - v) * bgDim`). Value of 1.0 would
/// mean "no dim" (background equal-strength to body). The 0.35 baseline
/// kept body popping but crushed equipment sketches to near-white.
/// v6 bumped this to 0.70 to recover equipment legibility; v7 (2026-04-22)
/// dropped it back to 0.50 to restore subject-pop after Carl's feedback
/// that the body wasn't separating strongly enough from the background.
private let backgroundDim: Double = 0.50

// MARK: - Hand-region dilation (v8)
//
// Vision's `VNGeneratePersonSegmentationRequest` produces a person-only
// silhouette — held equipment (dumbbells, bands, kettlebell handles) is
// excluded by design and gets dimmed into the background by the two-zone
// blend in `applyMaskedDim`. v8 augments the mask with a hand-pose pass
// (`VNDetectHumanHandPoseRequest`) and paints a filled disc onto the mask
// at each detected hand. The disc lands inside the body zone, so anything
// the practitioner is gripping pops with the body instead of fading.

/// Master switch for hand-region dilation. Disable to fall back to v7.2
/// behaviour (person-only silhouette).
///
/// History:
///   2026-05-03 — disabled defensively while investigating device-side
///   reports of "permanent stuck-in-converting on fresh captures". RCA
///   subsequently cleared v8's name (real cause was a UI double-count
///   bug + a damaged mp4 file with no recovery path). Re-enabled
///   2026-05-04 so held equipment (dumbbells, water bottles, bands)
///   reads as part of the body zone in line drawings + Hero shots.
private let handDilationEnabled: Bool = true

/// Disc radius as a fraction of the frame's shorter dimension. 0.10 →
/// disc radius ≈ 10% of `min(width, height)`. Generous enough to cover a
/// dumbbell head + grip in a typical capture but not so large that the
/// dilation visibly bulges the silhouette outside the gripped object.
/// Combined with `handDilationRadiusMin` so very low-resolution frames
/// don't shrink the disc to nothing.
private let handDilationRadiusFraction: Double = 0.10

/// Minimum disc radius in pixels — overrides the fraction-based radius
/// when the latter would be too small (e.g. heavily downsampled previews).
private let handDilationRadiusMin: Int = 60

/// The disc is also widened to cover the full keypoint spread × this
/// factor. Captures held implements that extend past the wrist/finger
/// keypoints (long-handle dumbbells, plate edges).
private let handDilationSpreadMultiplier: Double = 1.4

/// Minimum keypoint confidence to count toward the centroid + bounding box.
/// Lower than Vision's default suggestion (0.3) — we want to include
/// occluded fingertips when the practitioner is gripping a barbell.
private let handDilationConfidenceMin: Float = 0.20

/// Native iOS platform channel for video-to-line-drawing conversion.
///
/// Uses AVAssetReader/Writer for H.264/265 I/O (which OpenCV can't handle on iOS)
/// and Apple's Accelerate framework (vImage) for fast pixel-level image processing.
///
/// The line drawing algorithm matches the Dart/OpenCV implementation:
/// 1. Grayscale conversion
/// 2. Pencil sketch via divide: invert -> box blur -> divide
/// 3. Adaptive threshold for crisp structural lines
/// 4. Combine (min of both)
/// 5. Contrast boost
/// 6. Line-alpha dim (softens intensity — see `edgeThresholdLo/Hi/lineAlpha`)
class VideoConverterChannel {
    // Safe Mode v2 (2026-05-23) — video gate.
    //
    // The v1 photo path is removed entirely in this wave and replaced
    // by `applySafeModeV2ToPhoto` (per-client face-recognition
    // discriminator via MobileFaceNet). The v1 VIDEO path still uses
    // the legacy `SafeModeProcessor` anchor-box code at the
    // convertVideo writer pump below; for v2 the Dart side refuses to
    // start video recording inside a Safe Mode polygon (suppression
    // implemented in `safe_mode_service.dart` / `capture_mode_screen.dart`).
    //
    // This constant is a defensive backstop: if the Dart side ever
    // hands us a `safeOutputPath` on convertVideo, the writer
    // allocation is short-circuited and the safe-mp4 simply isn't
    // produced. The legacy code path remains compiled-in so v3 can
    // re-enable with keyframe-embed + tracking.
    static let kSafeModeVideoEnabled: Bool = false

    private let channel: FlutterMethodChannel
    private let processingQueue = DispatchQueue(
        label: "com.raidme.video_converter.processing",
        qos: .userInitiated
    )

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(
            name: "com.raidme.video_converter",
            binaryMessenger: messenger
        )
        channel.setMethodCallHandler(handle)
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "convertVideo":
            guard let args = call.arguments as? [String: Any],
                  let inputPath = args["inputPath"] as? String,
                  let outputPath = args["outputPath"] as? String,
                  let blurKernel = args["blurKernel"] as? Int,
                  let thresholdBlock = args["thresholdBlock"] as? Int,
                  let contrastLow = args["contrastLow"] as? Int else {
                result(FlutterError(
                    code: "INVALID_ARGS",
                    message: "Missing required arguments for convertVideo",
                    details: nil
                ))
                return
            }
            // `includeAudio` is optional for backward compat. Default to
            // true — the line-drawing output should retain the captured audio
            // track unless the practitioner explicitly muted the exercise.
            // See `ExerciseCapture.includeAudio` on the Dart side: the flag
            // controls playback volume AND whether the converter muxes the
            // audio track at all. Keeping it out of the file when muted is
            // a small privacy win (no ambient gym audio in the archive).
            //
            // Kill-switch (2026-04-20 audio-hang triage): the Dart side
            // passes `includeAudio: false` when the build is compiled with
            // `--dart-define=HOMEFIT_AUDIO_MUX_ENABLED=false`. That path is
            // the pre-PR-#39 behaviour (video-only output, no audio reader
            // or writer attached) and is known to complete cleanly — useful
            // while the mux hang is being triaged. See `config.dart`.
            let includeAudio = (args["includeAudio"] as? Bool) ?? true
            // v7.1 dual-output — optional second writer produces a segmented
            // COLOUR .mp4 (body passthrough, background dimmed via the same
            // Vision mask). Omit for legacy callers → line-drawing only.
            let segmentedOutputPath = args["segmentedOutputPath"] as? String
            // v7.2 mask sidecar — optional THIRD writer emits the Vision
            // mask itself as a grayscale H.264 mp4. Same pixel-grid as the
            // segmented composite so the two files are perfectly aligned
            // for future compositing. Omit for legacy callers → no mask
            // output. Independently best-effort; a failure here never
            // disturbs the line-drawing or segmented writers.
            let maskOutputPath = args["maskOutputPath"] as? String
            // Safe Mode (2026-05-21) — optional FOURTH writer emits a
            // bystander-blurred raw archive: same source frame, but
            // every segmented person OUTSIDE the largest detected
            // human bbox is replaced with a flat coral silhouette.
            // Only enabled when the capture happened inside a
            // Safe-Mode-enforcing premises. Independently best-effort:
            // a failure here MUST NOT disturb the line / segmented /
            // mask writers — the practitioner still gets a usable
            // line drawing even if the safe pass crashed.
            let safeOutputPath = args["safeOutputPath"] as? String
            processingQueue.async { [weak self] in
                self?.convertVideo(
                    inputPath: inputPath,
                    outputPath: outputPath,
                    segmentedOutputPath: segmentedOutputPath,
                    maskOutputPath: maskOutputPath,
                    safeOutputPath: safeOutputPath,
                    blurKernel: blurKernel,
                    thresholdBlock: thresholdBlock,
                    contrastLow: contrastLow,
                    includeAudio: includeAudio,
                    result: result
                )
            }

        case "extractThumbnail":
            guard let args = call.arguments as? [String: Any],
                  let inputPath = args["inputPath"] as? String,
                  let outputPath = args["outputPath"] as? String,
                  let timeMs = args["timeMs"] as? Int else {
                result(FlutterError(
                    code: "INVALID_ARGS",
                    message: "Missing required arguments for extractThumbnail",
                    details: nil
                ))
                return
            }
            // Optional: when true, ignore `timeMs` and pick a motion-peak
            // frame natively (samples at ~33/50/67% and picks the one with
            // the largest pixel-diff vs frame 0). Falls back to midpoint if
            // motion sampling fails.
            let autoPick = args["autoPick"] as? Bool ?? false
            // Optional: when true, run a luminance-preserving grayscale pass
            // after person-segmentation and before JPEG encoding. Used by the
            // practitioner-facing list thumbnails so they read legibly at small
            // sizes. Defaults to false to preserve the legacy contract on any
            // caller that still wants the raw/line-drawing treatment.
            let grayscale = args["grayscale"] as? Bool ?? false
            processingQueue.async { [weak self] in
                self?.extractThumbnail(
                    inputPath: inputPath,
                    outputPath: outputPath,
                    timeMs: timeMs,
                    autoPick: autoPick,
                    grayscale: grayscale,
                    result: result
                )
            }

        case "compressVideo":
            guard let args = call.arguments as? [String: Any],
                  let inputPath = args["inputPath"] as? String,
                  let outputPath = args["outputPath"] as? String else {
                result(FlutterError(
                    code: "INVALID_ARGS",
                    message: "Missing required arguments for compressVideo",
                    details: nil
                ))
                return
            }
            processingQueue.async { [weak self] in
                self?.compressVideo(
                    inputPath: inputPath,
                    outputPath: outputPath,
                    result: result
                )
            }

        case "processClientAvatar":
            // Wave 30 — single-still segmentation + Gaussian background blur.
            // Input is a raw camera capture; output is a body-focus PNG that
            // replaces the default initials monogram on the client detail view.
            // Vision quality matches the line-drawing pipeline (.accurate).
            guard let args = call.arguments as? [String: Any],
                  let rawPath = args["rawPath"] as? String,
                  let outPath = args["outPath"] as? String else {
                result(FlutterError(
                    code: "INVALID_ARGS",
                    message: "Missing required arguments for processClientAvatar",
                    details: nil
                ))
                return
            }
            processingQueue.async {
                if #available(iOS 15.0, *) {
                    ClientAvatarProcessor.process(
                        rawPath: rawPath,
                        outPath: outPath,
                        format: .png,
                        result: result
                    )
                } else {
                    DispatchQueue.main.async {
                        result(FlutterError(
                            code: "UNSUPPORTED_OS",
                            message: "Avatar processing requires iOS 15+",
                            details: nil
                        ))
                    }
                }
            }

        case "applySafeModeV2ToPhoto":
            // Safe Mode v2 (2026-05-23, multi-reference 2026-05-24) —
            // per-client face-recognition discriminator. Caller supplies
            // 1–8 L2-normalized FP32 face embeddings (derived from a live
            // Face-ID-style enrolment sweep via
            // `generateFaceEmbeddingsFromFrames`, or — during the
            // backward-compat window — a one-element array wrapping the
            // legacy single avatar embedding). We run face detection +
            // person segmentation on the photo, embed every detected
            // face, compute the per-face MAX cosSim across all provided
            // references, then pick the face with the highest score per
            // the hybrid pick-highest rule in
            // `docs/specs/2026-05-24-safe-mode-v2-multi-reference-enrolment.md`.
            //
            // Returns the same SafeModePhotoOutcome shape the v1 path
            // used so the Dart side's `kSafeModeMaxMissRate` decision
            // stays unchanged: processed (0/1), missRate (0.0/1.0),
            // lowConfidence (true when no subject was identified and
            // we fell through to no-subject mode).
            guard let args = call.arguments as? [String: Any],
                  let srcPath = args["srcPath"] as? String,
                  let destPath = args["destPath"] as? String else {
                result(FlutterError(
                    code: "INVALID_ARGS",
                    message: "Missing srcPath/destPath for applySafeModeV2ToPhoto",
                    details: nil
                ))
                return
            }
            // subjectEmbeddings arrives as List<FlutterStandardTypedData>
            // on the platform channel. The multi-reference signature
            // change (2026-05-24) replaces the single `subjectEmbedding`
            // blob with an array of 1–8 blobs. Per
            // feedback_no_silent_fallbacks the input validation is
            // strict — empty arrays, oversize arrays, or wrong-byte-length
            // elements are rejected loudly rather than silently degrading.
            //
            // Back-compat: legacy callers (single avatar embedding) wrap
            // their Data in a one-element list before invoking. The
            // deprecated `subjectEmbedding` (singular) parameter is no
            // longer accepted — Dart callers must use the new shape.
            let rawEmbeddings: Any? = args["subjectEmbeddings"]
            var subjectEmbeddings: [Data] = []
            if let list = rawEmbeddings as? [Any] {
                for element in list {
                    if let typed = element as? FlutterStandardTypedData {
                        subjectEmbeddings.append(typed.data)
                    } else if let raw = element as? Data {
                        subjectEmbeddings.append(raw)
                    } else {
                        result(FlutterError(
                            code: "INVALID_ARGS",
                            message: "subjectEmbeddings list contains a non-bytes element (\(type(of: element)))",
                            details: nil
                        ))
                        return
                    }
                }
            } else if rawEmbeddings == nil {
                result(FlutterError(
                    code: "INVALID_ARGS",
                    message: "Missing subjectEmbeddings for applySafeModeV2ToPhoto",
                    details: nil
                ))
                return
            } else {
                result(FlutterError(
                    code: "INVALID_ARGS",
                    message: "subjectEmbeddings must be a list of bytes; got \(type(of: rawEmbeddings!))",
                    details: nil
                ))
                return
            }
            if subjectEmbeddings.isEmpty {
                result(FlutterError(
                    code: "INVALID_ARGS",
                    message: "subjectEmbeddings must contain at least one embedding (got 0)",
                    details: nil
                ))
                return
            }
            if subjectEmbeddings.count > 8 {
                result(FlutterError(
                    code: "INVALID_ARGS",
                    message: "subjectEmbeddings must contain at most 8 embeddings (got \(subjectEmbeddings.count))",
                    details: nil
                ))
                return
            }
            let expectedByteLen = MobileFaceNetEmbedder.embeddingByteLength
            for (idx, emb) in subjectEmbeddings.enumerated() {
                if emb.count != expectedByteLen {
                    result(FlutterError(
                        code: "INVALID_ARGS",
                        message: "subjectEmbeddings[\(idx)] wrong size — got \(emb.count) bytes, expected \(expectedByteLen)",
                        details: nil
                    ))
                    return
                }
            }
            let threshold = (args["threshold"] as? Double) ?? 0.6
            processingQueue.async {
                if #available(iOS 15.0, *) {
                    let outcome = Self.applySafeModeV2ToPhoto(
                        srcPath: srcPath,
                        destPath: destPath,
                        subjectEmbeddings: subjectEmbeddings,
                        threshold: threshold
                    )
                    DispatchQueue.main.async {
                        switch outcome {
                        case .success(let processed, let missRate, let lowConfidence):
                            result([
                                "destPath": destPath,
                                "safeFramesProcessed": processed,
                                "safeFramesMissedRate": missRate,
                                "lowConfidence": lowConfidence,
                            ])
                        case .failure(let err):
                            result(FlutterError(
                                code: "PHOTO_SAFE_V2_FAILED",
                                message: err,
                                details: nil
                            ))
                        }
                    }
                } else {
                    DispatchQueue.main.async {
                        result(FlutterError(
                            code: "UNSUPPORTED_OS",
                            message: "Safe Mode v2 requires iOS 15+",
                            details: nil
                        ))
                    }
                }
            }

        case "generateFaceEmbedding":
            // Safe Mode v2 (2026-05-23) — produce the per-client face
            // embedding from an avatar JPG. Used both on avatar upload
            // (going-forward) and as a lazy backfill on Safe Mode
            // first-use for existing clients. Caller passes the JPG
            // path; we return a 2048-byte FlutterStandardTypedData blob
            // (512 FP32 little-endian floats, L2-normalized).
            //
            // Failure modes surfaced as FlutterError:
            //   - JPG missing / unreadable: code "FILE_NOT_FOUND".
            //   - Zero faces detected: code "NO_FACE_DETECTED".
            //   - Multiple ambiguous faces (top-two within 80% area):
            //     code "MULTIPLE_AMBIGUOUS_FACES" with details
            //     containing the area ratio so the UI can prompt the
            //     practitioner to pick a clearer avatar.
            //   - MobileFaceNet load / inference failure: code
            //     "FACE_EMBED_FAILED". Per feedback_no_silent_fallbacks
            //     the UI shows a hard error — never silently fall back
            //     to a stub embedding.
            guard let args = call.arguments as? [String: Any],
                  let srcPath = args["srcPath"] as? String else {
                result(FlutterError(
                    code: "INVALID_ARGS",
                    message: "Missing srcPath for generateFaceEmbedding",
                    details: nil
                ))
                return
            }
            processingQueue.async {
                if #available(iOS 15.0, *) {
                    let outcome = Self.generateFaceEmbeddingFromJpg(srcPath: srcPath)
                    DispatchQueue.main.async {
                        switch outcome {
                        case .success(let blob):
                            result(FlutterStandardTypedData(bytes: blob))
                        case .noFace:
                            result(FlutterError(
                                code: "NO_FACE_DETECTED",
                                message: "Avatar must contain a face",
                                details: nil
                            ))
                        case .multipleAmbiguous(let ratio):
                            result(FlutterError(
                                code: "MULTIPLE_AMBIGUOUS_FACES",
                                message: "Multiple faces of similar size detected — pick an avatar with a single clearly-dominant face",
                                details: ["topTwoAreaRatio": ratio]
                            ))
                        case .fileMissing:
                            result(FlutterError(
                                code: "FILE_NOT_FOUND",
                                message: "Avatar JPG not found at \(srcPath)",
                                details: nil
                            ))
                        case .failure(let msg):
                            result(FlutterError(
                                code: "FACE_EMBED_FAILED",
                                message: msg,
                                details: nil
                            ))
                        }
                    }
                } else {
                    DispatchQueue.main.async {
                        result(FlutterError(
                            code: "UNSUPPORTED_OS",
                            message: "Face embedding requires iOS 15+",
                            details: nil
                        ))
                    }
                }
            }

        case "generateFaceEmbeddingsFromFrames":
            // Safe Mode v2 multi-reference enrolment (2026-05-24) —
            // produce N face embeddings from a set of frame paths
            // captured during the Face-ID-style rotating-head sweep.
            // Native does Vision face landmarks per frame (extracting
            // pose yaw/pitch), accepts frames with exactly one face,
            // runs greedy farthest-point selection in (yaw, pitch)
            // space to pick `expectedSlotCount` slots that maximally
            // span the pose space, then runs MobileFaceNet on each
            // picked frame.
            //
            // Inputs (per
            // `docs/specs/2026-05-24-safe-mode-v2-multi-reference-enrolment.md`):
            //   - framePaths: List<String>, non-empty, each must exist
            //   - expectedSlotCount: Int, optional (default 6), clamped to [3, 8]
            //
            // Returns a map:
            //   {
            //     "embeddings":       List<FlutterStandardTypedData>,   // slot-ordered
            //     "frontalPickSlot":  Int,                              // index into the arrays
            //     "posesYaw":         List<Double>,                     // radians, slot-ordered
            //     "posesPitch":       List<Double>,                     // radians, slot-ordered
            //   }
            //
            // Per feedback_no_silent_fallbacks: every input validation
            // failure or model error surfaces as a FlutterError with a
            // clear code; the Dart side never receives a partial result.
            guard let args = call.arguments as? [String: Any] else {
                result(FlutterError(
                    code: "INVALID_ARGS",
                    message: "Missing arguments map for generateFaceEmbeddingsFromFrames",
                    details: nil
                ))
                return
            }
            let framePaths: [String]
            if let list = args["framePaths"] as? [String] {
                framePaths = list
            } else if let list = args["framePaths"] as? [Any] {
                var coerced: [String] = []
                for el in list {
                    if let s = el as? String { coerced.append(s) }
                }
                if coerced.count != list.count {
                    result(FlutterError(
                        code: "INVALID_ARGS",
                        message: "framePaths must be a list of strings",
                        details: nil
                    ))
                    return
                }
                framePaths = coerced
            } else {
                result(FlutterError(
                    code: "INVALID_ARGS",
                    message: "Missing or invalid framePaths for generateFaceEmbeddingsFromFrames",
                    details: nil
                ))
                return
            }
            if framePaths.isEmpty {
                result(FlutterError(
                    code: "INVALID_ARGS",
                    message: "framePaths must be non-empty",
                    details: nil
                ))
                return
            }
            for p in framePaths {
                if !FileManager.default.fileExists(atPath: p) {
                    result(FlutterError(
                        code: "FILE_NOT_FOUND",
                        message: "Frame not found at path: \(p)",
                        details: nil
                    ))
                    return
                }
            }
            let requestedSlotCount = (args["expectedSlotCount"] as? Int) ?? 6
            let clampedSlotCount = max(3, min(8, requestedSlotCount))
            processingQueue.async {
                if #available(iOS 15.0, *) {
                    let outcome = Self.generateFaceEmbeddingsFromFrames(
                        framePaths: framePaths,
                        expectedSlotCount: clampedSlotCount
                    )
                    DispatchQueue.main.async {
                        switch outcome {
                        case .success(let embeddings, let frontalPickIndex, let posesYaw, let posesPitch):
                            result([
                                "embeddings": embeddings.map { FlutterStandardTypedData(bytes: $0) },
                                "frontalPickSlot": frontalPickIndex,
                                "posesYaw": posesYaw,
                                "posesPitch": posesPitch,
                            ])
                        case .notEnoughFrames(let accepted, let needed):
                            result(FlutterError(
                                code: "NOT_ENOUGH_FRAMES",
                                message: "not enough valid frames for enrolment — got \(accepted), need \(needed)",
                                details: ["accepted": accepted, "needed": needed]
                            ))
                        case .failure(let msg):
                            result(FlutterError(
                                code: "FACE_EMBED_FAILED",
                                message: msg,
                                details: nil
                            ))
                        }
                    }
                } else {
                    DispatchQueue.main.async {
                        result(FlutterError(
                            code: "UNSUPPORTED_OS",
                            message: "Face embedding requires iOS 15+",
                            details: nil
                        ))
                    }
                }
            }

        case "processPhotoBodyFocus":
            // Wave 36 — body-focus segmented variant for exercise photos.
            // Reuses the same `ClientAvatarProcessor` pipeline (Vision
            // person-segmentation + vImage Gaussian blur composite) the
            // avatar surface uses, encoded as JPEG (smaller files, no
            // alpha halo concerns inside the player frame). Output sits
            // alongside the line-drawing JPG and the raw colour JPG —
            // uploaded to the private `raw-archive` bucket on publish.
            // No-op on iOS < 15 (Vision person segmentation requires it).
            guard let args = call.arguments as? [String: Any],
                  let rawPath = args["rawPath"] as? String,
                  let outPath = args["outPath"] as? String else {
                result(FlutterError(
                    code: "INVALID_ARGS",
                    message: "Missing required arguments for processPhotoBodyFocus",
                    details: nil
                ))
                return
            }
            processingQueue.async {
                if #available(iOS 15.0, *) {
                    ClientAvatarProcessor.process(
                        rawPath: rawPath,
                        outPath: outPath,
                        format: .jpg,
                        result: result
                    )
                } else {
                    DispatchQueue.main.async {
                        result(FlutterError(
                            code: "UNSUPPORTED_OS",
                            message: "Photo body-focus requires iOS 15+",
                            details: nil
                        ))
                    }
                }
            }

        case "getVideoDuration":
            guard let args = call.arguments as? [String: Any],
                  let inputPath = args["inputPath"] as? String else {
                result(FlutterError(
                    code: "INVALID_ARGS",
                    message: "Missing inputPath for getVideoDuration",
                    details: nil
                ))
                return
            }
            processingQueue.async {
                guard FileManager.default.fileExists(atPath: inputPath),
                      FileManager.default.isReadableFile(atPath: inputPath) else {
                    DispatchQueue.main.async {
                        result(FlutterError(
                            code: "FILE_NOT_FOUND",
                            message: "Input file does not exist: \(inputPath)",
                            details: nil
                        ))
                    }
                    return
                }
                let asset = AVURLAsset(url: URL(fileURLWithPath: inputPath))
                let seconds = CMTimeGetSeconds(asset.duration)
                // Return milliseconds as an Int64-friendly number; NSNumber keeps
                // it safe across the platform channel (Flutter expects `int`).
                let ms = Int64((seconds.isFinite ? seconds : 0) * 1000)
                DispatchQueue.main.async {
                    result(NSNumber(value: ms))
                }
            }

        case "getVideoRotatedAspect":
            // Returns the displayed (rotation-corrected) aspect ratio of
            // the video at `inputPath`. Flutter's video_player on iOS
            // visually applies the AVAsset's preferredTransform via
            // AVPlayerLayer, but `VideoPlayerController.value.aspectRatio`
            // is derived from the raw `naturalSize` — for iPhone portrait
            // captures that's the unrotated 16:9 instead of the displayed
            // 9:16. Hero tab uses this to letterbox the raw archive .mp4
            // correctly when `rotation_quarters` on the row is null/0
            // (cloud-pulled rows skip the practitioner-rotation column).
            guard let args = call.arguments as? [String: Any],
                  let inputPath = args["inputPath"] as? String else {
                result(FlutterError(
                    code: "INVALID_ARGS",
                    message: "Missing inputPath for getVideoRotatedAspect",
                    details: nil
                ))
                return
            }
            processingQueue.async {
                guard FileManager.default.fileExists(atPath: inputPath) else {
                    DispatchQueue.main.async {
                        result(FlutterError(
                            code: "FILE_NOT_FOUND",
                            message: "Input file does not exist: \(inputPath)",
                            details: nil
                        ))
                    }
                    return
                }
                let asset = AVURLAsset(url: URL(fileURLWithPath: inputPath))
                guard let track = asset.tracks(withMediaType: .video).first else {
                    DispatchQueue.main.async {
                        result(FlutterError(
                            code: "NO_VIDEO_TRACK",
                            message: "Asset has no video track: \(inputPath)",
                            details: nil
                        ))
                    }
                    return
                }
                let natural = track.naturalSize
                let t = track.preferredTransform
                // Mirrors the convertVideo rotation detection at line 549.
                // 90°/270° transforms have |b| == 1 && |c| == 1 — width
                // and height swap when applied. 0°/180° leave them alone.
                let rotated = abs(t.b) == 1.0 && abs(t.c) == 1.0
                let w = rotated ? natural.height : natural.width
                let h = rotated ? natural.width : natural.height
                let aspect = (h > 0) ? Double(w / h) : 0.0
                DispatchQueue.main.async {
                    if aspect > 0 {
                        result(NSNumber(value: aspect))
                    } else {
                        result(FlutterError(
                            code: "INVALID_DIMENSIONS",
                            message: "Could not derive aspect from track \(natural.width)x\(natural.height)",
                            details: nil
                        ))
                    }
                }
            }

        case "getPreferredBackCameraName":
            // Wave 33 — diagnostic + lens-disambiguation helper for the
            // avatar capture surface. The Flutter `camera` plugin maps
            // multi-cam iPhones to virtual devices that automatically
            // switch between Wide / UltraWide / Telephoto based on
            // framing distance. Even with a `setZoomLevel(1.0)` and a
            // name-substring filter the surfaced device list can still
            // include `.builtInDualWideCamera` / `.builtInTripleCamera`
            // virtual entries that report a sub-1.0× minZoom and give
            // the fish-eye look Carl reported.
            //
            // This method returns:
            //   - `name`           — AVCaptureDevice.localizedName of the
            //                        canonical 1× back wide-angle lens
            //                        (`.builtInWideAngleCamera`).
            //   - `uniqueID`       — its uniqueID for an exact match.
            //   - `position`       — "back" / "front".
            //   - `availableTypes` — string list of device-type rawValues
            //                        present on this device, for logging.
            //
            // Dart side reads `name` and uses it to pick from the
            // `availableCameras()` list. If the names disagree we fall
            // back to the previous Wave 32 substring filter — better
            // than nothing.
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [
                    .builtInWideAngleCamera,
                    .builtInUltraWideCamera,
                    .builtInTelephotoCamera,
                    .builtInDualCamera,
                    .builtInDualWideCamera,
                    .builtInTripleCamera,
                ],
                mediaType: .video,
                position: .back
            )
            let allBack = discovery.devices
            let preferred = AVCaptureDevice.default(
                .builtInWideAngleCamera,
                for: .video,
                position: .back
            )
            var payload: [String: Any] = [
                "availableTypes": allBack.map { $0.deviceType.rawValue },
                "availableNames": allBack.map { $0.localizedName },
                "availableUniqueIds": allBack.map { $0.uniqueID },
            ]
            if let preferred = preferred {
                payload["name"] = preferred.localizedName
                payload["uniqueID"] = preferred.uniqueID
                payload["position"] = "back"
                payload["minZoom"] = preferred.activeFormat.videoMaxZoomFactor > 0
                    ? NSNumber(value: Double(preferred.minAvailableVideoZoomFactor))
                    : NSNumber(value: 1.0)
                payload["maxZoom"] = NSNumber(value: Double(preferred.maxAvailableVideoZoomFactor))
            }
            DispatchQueue.main.async {
                result(payload)
            }

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Video Conversion

    private func convertVideo(
        inputPath: String,
        outputPath: String,
        segmentedOutputPath: String?,
        maskOutputPath: String?,
        safeOutputPath: String?,
        blurKernel: Int,
        thresholdBlock: Int,
        contrastLow: Int,
        includeAudio: Bool,
        result: @escaping FlutterResult
    ) {
        // --- Defense in depth: validate input file exists and is readable ---
        guard FileManager.default.fileExists(atPath: inputPath),
              FileManager.default.isReadableFile(atPath: inputPath) else {
            DispatchQueue.main.async {
                result(FlutterError(
                    code: "FILE_NOT_FOUND",
                    message: "Input file does not exist or is not readable: \(inputPath)",
                    details: nil
                ))
            }
            return
        }

        // --- Background task assertion ---
        // Bracket the entire processing dispatch with begin/end so that a brief
        // backgrounding during the convert doesn't corrupt the output. The
        // background task is ended in both the success and failure paths below.
        var bgTaskId: UIBackgroundTaskIdentifier = .invalid
        bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "video-convert") {
            // Expiration handler — best-effort cleanup if the OS is about to kill us.
            if bgTaskId != .invalid {
                UIApplication.shared.endBackgroundTask(bgTaskId)
                bgTaskId = .invalid
            }
        }

        // Helper to guarantee the background task is always released after
        // result(...) is delivered. Call exactly once per exit path.
        let endBackgroundTask: () -> Void = {
            if bgTaskId != .invalid {
                UIApplication.shared.endBackgroundTask(bgTaskId)
                bgTaskId = .invalid
            }
        }

        let inputURL = URL(fileURLWithPath: inputPath)
        let outputURL = URL(fileURLWithPath: outputPath)

        // Remove existing output file if present.
        try? FileManager.default.removeItem(at: outputURL)

        let asset = AVURLAsset(url: inputURL)

        // --- Reader setup ---
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            DispatchQueue.main.async {
                result(FlutterError(
                    code: "NO_VIDEO_TRACK",
                    message: "No video track found in: \(inputPath)",
                    details: nil
                ))
                endBackgroundTask()
            }
            return
        }

        let readerOutputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            DispatchQueue.main.async {
                result(FlutterError(
                    code: "READER_INIT_FAILED",
                    message: "Could not create AVAssetReader: \(error.localizedDescription)",
                    details: nil
                ))
                endBackgroundTask()
            }
            return
        }

        let readerOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: readerOutputSettings
        )
        readerOutput.alwaysCopiesSampleData = false
        reader.add(readerOutput)

        let naturalSize = videoTrack.naturalSize
        let transform = videoTrack.preferredTransform
        let videoWidth: Int
        let videoHeight: Int

        // Detect 90/270 degree rotation (common from phone cameras).
        if abs(transform.b) == 1.0 && abs(transform.c) == 1.0 {
            videoWidth = Int(naturalSize.height)
            videoHeight = Int(naturalSize.width)
        } else {
            videoWidth = Int(naturalSize.width)
            videoHeight = Int(naturalSize.height)
        }

        let frameRate = videoTrack.nominalFrameRate
        let estimatedTotalFrames = Int(Float(asset.duration.seconds) * frameRate)

        // --- Writer setup ---
        let writerOutputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: videoWidth,
            AVVideoHeightKey: videoHeight,
        ]

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            DispatchQueue.main.async {
                result(FlutterError(
                    code: "WRITER_INIT_FAILED",
                    message: "Could not create AVAssetWriter: \(error.localizedDescription)",
                    details: nil
                ))
                endBackgroundTask()
            }
            return
        }

        let writerInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: writerOutputSettings
        )
        writerInput.expectsMediaDataInRealTime = false

        // Apply the video track's transform so portrait videos stay portrait.
        writerInput.transform = transform

        // Pixel buffer attributes drive the adaptor's internal CVPixelBufferPool,
        // which we use to recycle output buffers frame-to-frame (avoids jetsam
        // from unbounded CVPixelBufferCreate allocations on longer clips).
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: videoWidth,
            kCVPixelBufferHeightKey as String: videoHeight,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )
        writer.add(writerInput)

        // --- Segmented-colour writer setup (v7.1 dual-output) ---
        //
        // Optional second writer that shares the reader and Vision mask with
        // the line-drawing pipeline above. Produces a parallel .mp4 where the
        // body zone is full-colour passthrough from the source frame and the
        // background zone is dimmed via the same `backgroundDim` constant
        // (no edge detection, no coral lines — this is the colour sibling of
        // the sketch).
        //
        // Best-effort: any failure below (writer init, input add, audio
        // attach) logs and falls through to line-drawing-only output. The
        // segmented file is additive; the original file continues to upload
        // via the existing compressVideo / raw-archive path so a missing
        // .segmented.mp4 downgrades gracefully to the pre-v7.1 client
        // experience.
        var segWriter: AVAssetWriter? = nil
        var segWriterInput: AVAssetWriterInput? = nil
        var segAdaptor: AVAssetWriterInputPixelBufferAdaptor? = nil
        var segAudioWriterInput: AVAssetWriterInput? = nil
        if let segPath = segmentedOutputPath {
            let segURL = URL(fileURLWithPath: segPath)
            try? FileManager.default.removeItem(at: segURL)
            do {
                let sw = try AVAssetWriter(outputURL: segURL, fileType: .mp4)
                let sInput = AVAssetWriterInput(
                    mediaType: .video,
                    outputSettings: writerOutputSettings
                )
                sInput.expectsMediaDataInRealTime = false
                sInput.transform = transform
                let sAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                    assetWriterInput: sInput,
                    sourcePixelBufferAttributes: pixelBufferAttributes
                )
                if sw.canAdd(sInput) {
                    sw.add(sInput)
                    segWriter = sw
                    segWriterInput = sInput
                    segAdaptor = sAdaptor
                    NSLog("[VideoConverter] segmented writer attached at \(segPath)")
                } else {
                    NSLog("[VideoConverter] segmented writer.canAdd(video) failed — skipping")
                }
            } catch {
                NSLog("[VideoConverter] segmented AVAssetWriter init failed: \(error.localizedDescription) — skipping")
            }
        }

        // --- Mask sidecar writer setup (v7.2) ---
        //
        // Optional third writer that emits the Vision person-segmentation
        // mask as a grayscale H.264 mp4. Same resolution, fps, and
        // pixel-buffer pool shape as the segmented composite so the two
        // files are pixel-perfect aligned for future playback-time
        // compositing.
        //
        // Encoding note: the Vision mask is Planar8 (single-channel), but
        // H.264 encoders on iOS refuse single-channel input. We render
        // the mask as BGRA with R=G=B=maskValue so any standard mp4
        // decoder can read it back. Alpha is always 255.
        //
        // Video-only — no audio input. A mask sidecar's audio track would
        // be meaningless, and skipping it keeps the file smaller.
        //
        // Best-effort: init / canAdd / startWriting failures log and
        // downgrade to "no mask output" without touching the line-drawing
        // or segmented writers.
        var maskWriter: AVAssetWriter? = nil
        var maskWriterInput: AVAssetWriterInput? = nil
        var maskAdaptor: AVAssetWriterInputPixelBufferAdaptor? = nil
        if let mPath = maskOutputPath {
            let mURL = URL(fileURLWithPath: mPath)
            try? FileManager.default.removeItem(at: mURL)
            do {
                let mw = try AVAssetWriter(outputURL: mURL, fileType: .mp4)
                let mInput = AVAssetWriterInput(
                    mediaType: .video,
                    outputSettings: writerOutputSettings
                )
                mInput.expectsMediaDataInRealTime = false
                mInput.transform = transform
                let mAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                    assetWriterInput: mInput,
                    sourcePixelBufferAttributes: pixelBufferAttributes
                )
                if mw.canAdd(mInput) {
                    mw.add(mInput)
                    maskWriter = mw
                    maskWriterInput = mInput
                    maskAdaptor = mAdaptor
                    NSLog("[VideoConverter] mask writer attached at \(mPath)")
                } else {
                    NSLog("[VideoConverter] mask writer.canAdd(video) failed — skipping")
                }
            } catch {
                NSLog("[VideoConverter] mask writer failed: \(error.localizedDescription) — skipping")
            }
        }

        // --- Safe Mode writer setup (2026-05-21) ---
        //
        // Optional FOURTH writer that produces a bystander-blurred copy
        // of the raw frame. The pipeline runs `VNDetectHumanRectangles`
        // alongside person segmentation; the LARGEST detected human
        // bbox is treated as the client. Every mask pixel that's
        // BOTH (a) classified as person AND (b) lies outside the
        // client bbox is rewritten to coral (#FF6B35). The result is
        // the same source video with bystanders silhouetted in coral,
        // suitable as the raw archive when capture happened inside an
        // enforcing Safe Mode premises.
        //
        // Identical encoding settings to the line writer (same shape,
        // same H.264 bitrate target) so file-size analytics stay
        // comparable. Best-effort: any failure below logs and skips —
        // the line + segmented + mask writers continue unaffected.
        var safeWriter: AVAssetWriter? = nil
        var safeWriterInput: AVAssetWriterInput? = nil
        var safeAdaptor: AVAssetWriterInputPixelBufferAdaptor? = nil
        // Safe Mode v2 video suppression (2026-05-23):
        // `kSafeModeVideoEnabled` is false in v2. Even if the Dart side
        // forwards a `safeOutputPath` we short-circuit here so the
        // legacy anchor-box compositor never runs against the writer
        // pump. The line / segmented / mask writers continue
        // unaffected — the convertVideo call still produces all the
        // standard outputs, just without the safe-mp4 sidecar.
        if let sfPath = safeOutputPath, Self.kSafeModeVideoEnabled {
            let sfURL = URL(fileURLWithPath: sfPath)
            try? FileManager.default.removeItem(at: sfURL)
            do {
                let sw = try AVAssetWriter(outputURL: sfURL, fileType: .mp4)
                let sInput = AVAssetWriterInput(
                    mediaType: .video,
                    outputSettings: writerOutputSettings
                )
                sInput.expectsMediaDataInRealTime = false
                sInput.transform = transform
                let sAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                    assetWriterInput: sInput,
                    sourcePixelBufferAttributes: pixelBufferAttributes
                )
                if sw.canAdd(sInput) {
                    sw.add(sInput)
                    safeWriter = sw
                    safeWriterInput = sInput
                    safeAdaptor = sAdaptor
                    NSLog("[VideoConverter] safe writer attached at \(sfPath)")
                } else {
                    NSLog("[VideoConverter] safe writer.canAdd(video) failed — skipping")
                }
            } catch {
                NSLog("[VideoConverter] safe writer failed: \(error.localizedDescription) — skipping")
            }
        }

        // --- Audio passthrough setup ---
        // Copy the audio track as-is (no re-encoding) so the converted video
        // retains the original audio. If the source has no audio track, or
        // the practitioner toggled `includeAudio = false` on this exercise,
        // we skip audio entirely — the output will be video-only.
        //
        // IMPORTANT: passthrough (`outputSettings: nil`) on the writer input
        // requires a `sourceFormatHint` so AVAssetWriter knows the codec and
        // sample-rate layout of the compressed samples it's about to mux. On
        // iOS 15+ without the hint, the writer silently drops the audio track
        // from the output file — which is exactly what caused Carl's "no sound
        // on line drawing" bug (2026-04-20). Keep the hint.
        var audioReaderOutput: AVAssetReaderTrackOutput?
        var audioWriterInput: AVAssetWriterInput?

        // Telemetry — surfaced in Console.app so we can see exactly which
        // setup branch was taken on the device run that triggered a hang.
        NSLog(
            "[VideoConverter] setup — includeAudio=\(includeAudio) " +
            "hasAudioTrack=\(asset.tracks(withMediaType: .audio).first != nil)"
        )

        if includeAudio, let audioTrack = asset.tracks(withMediaType: .audio).first {
            let audioOutput = AVAssetReaderTrackOutput(
                track: audioTrack,
                outputSettings: nil
            )
            audioOutput.alwaysCopiesSampleData = false

            if reader.canAdd(audioOutput) {
                reader.add(audioOutput)
                audioReaderOutput = audioOutput

                // Pull the source format description so the writer can
                // passthrough the compressed samples without re-encoding.
                // `formatDescriptions` is `[Any]` but elements are always
                // `CMFormatDescription` per AVFoundation's contract. Use
                // `.map` to skip when the array is empty (was the original
                // crash on malformed input — force-casting nil traps).
                // AVAssetWriter accepts a nil hint and derives the format
                // from the source samples.
                let formatHint: CMFormatDescription? = audioTrack.formatDescriptions.first.map { $0 as! CMFormatDescription }
                let audioInput = AVAssetWriterInput(
                    mediaType: .audio,
                    outputSettings: nil,
                    sourceFormatHint: formatHint
                )
                audioInput.expectsMediaDataInRealTime = false

                if writer.canAdd(audioInput) {
                    writer.add(audioInput)
                    audioWriterInput = audioInput
                    NSLog("[VideoConverter] audio mux attached — reader+writer inputs ready")
                } else {
                    // Audio format incompatible with output — skip audio
                    audioReaderOutput = nil
                    NSLog("[VideoConverter] audio mux skipped — writer.canAdd(audioInput)=false")
                }

                // v7.1: attach a second AVAssetWriterInput (same format hint)
                // to the segmented writer so the .segmented.mp4 carries the
                // same audio track as the line-drawing output. The reader
                // produces the audio sample exactly once per pump iteration;
                // we append the same CMSampleBuffer to BOTH writer audio
                // inputs in the audio pump below. Safe — passthrough samples
                // are immutable; the writers keep their own retain counts.
                if let sw = segWriter {
                    let segAudioInput = AVAssetWriterInput(
                        mediaType: .audio,
                        outputSettings: nil,
                        sourceFormatHint: formatHint
                    )
                    segAudioInput.expectsMediaDataInRealTime = false
                    if sw.canAdd(segAudioInput) {
                        sw.add(segAudioInput)
                        segAudioWriterInput = segAudioInput
                        NSLog("[VideoConverter] segmented audio mux attached")
                    } else {
                        NSLog("[VideoConverter] segmented audio mux skipped — canAdd=false")
                    }
                }
            } else {
                NSLog("[VideoConverter] audio mux skipped — reader.canAdd(audioOutput)=false")
            }
        }

        // --- Start reading and writing ---
        guard reader.startReading() else {
            DispatchQueue.main.async {
                result(FlutterError(
                    code: "READER_START_FAILED",
                    message: "AVAssetReader failed to start: \(reader.error?.localizedDescription ?? "unknown")",
                    details: nil
                ))
                endBackgroundTask()
            }
            return
        }

        guard writer.startWriting() else {
            DispatchQueue.main.async {
                result(FlutterError(
                    code: "WRITER_START_FAILED",
                    message: "AVAssetWriter failed to start: \(writer.error?.localizedDescription ?? "unknown")",
                    details: nil
                ))
                endBackgroundTask()
            }
            return
        }
        writer.startSession(atSourceTime: .zero)

        // v7.1: start the segmented writer in parallel. If it refuses to
        // start (disk full, sandbox violation), log and downgrade to
        // line-drawing-only so the main pipeline still succeeds.
        if let sw = segWriter {
            if sw.startWriting() {
                sw.startSession(atSourceTime: .zero)
                NSLog("[VideoConverter] segmented writer started")
            } else {
                NSLog(
                    "[VideoConverter] segmented writer startWriting failed: " +
                    "\(sw.error?.localizedDescription ?? "unknown") — disabling seg output"
                )
                segWriter = nil
                segWriterInput = nil
                segAdaptor = nil
                segAudioWriterInput = nil
            }
        }

        // v7.2: start the mask writer in parallel. Independent of the
        // segmented writer — either can fail without disturbing the
        // other or the line-drawing output.
        if let mw = maskWriter {
            if mw.startWriting() {
                mw.startSession(atSourceTime: .zero)
                NSLog("[VideoConverter] mask writer started")
            } else {
                NSLog(
                    "[VideoConverter] mask writer startWriting failed: " +
                    "\(mw.error?.localizedDescription ?? "unknown") — disabling mask output"
                )
                maskWriter = nil
                maskWriterInput = nil
                maskAdaptor = nil
            }
        }

        // Safe Mode: start the safe writer in parallel.
        if let sw = safeWriter {
            if sw.startWriting() {
                sw.startSession(atSourceTime: .zero)
                NSLog("[VideoConverter] safe writer started")
            } else {
                NSLog(
                    "[VideoConverter] safe writer startWriting failed: " +
                    "\(sw.error?.localizedDescription ?? "unknown") — disabling safe output"
                )
                safeWriter = nil
                safeWriterInput = nil
                safeAdaptor = nil
            }
        }

        // Pre-allocate the line drawing processor for reuse across frames.
        let processor = LineDrawingProcessor(
            width: videoWidth,
            height: videoHeight,
            blurKernel: blurKernel,
            thresholdBlock: thresholdBlock,
            contrastLow: contrastLow
        )

        // Derive EXIF orientation from the track's preferredTransform
        // so Vision evaluates faces in the upright frame. The raw
        // CVPixelBuffer fed to processFrame is still in the sensor's
        // native (unrotated) orientation — the AVAssetWriter applies
        // the transform on the OUTPUT side via `writerInput.transform`.
        // Without this hint Vision returned zero face observations
        // for portrait-recorded videos.
        let safeOrientation: CGImagePropertyOrientation = {
            if transform.b == 1.0 && transform.c == -1.0 { return .right }
            if transform.b == -1.0 && transform.c == 1.0 { return .left }
            if transform.a == -1.0 && transform.d == -1.0 { return .down }
            // Identity or unrecognised — TODO: extend coverage if more
            // capture paths surface non-portrait transforms.
            return .up
        }()

        // Safe Mode processor — composites coral over bystander pixels.
        // Only allocated when the safe writer survived its init/start
        // pair, so the cost stays off for normal captures.
        //
        // LATENT COORDINATE-FRAME ISSUE (2026-05-22, see PR
        // "fix(safe-mode): photo bystander blur — normalise buffer to
        // upright before Vision + segmentation"):
        //
        // The video path here has the same coordinate-space mismatch
        // that the photo path used to have. AVAssetReader hands us
        // buffers in raw sensor orientation (`videoWidth x videoHeight`
        // is landscape for an iPhone portrait recording — the
        // preferredTransform rotates to upright on the writer's OUTPUT
        // side). We pass `safeOrientation` to SafeModeProcessor so
        // Vision sees faces upright, but PersonSegmenter runs against
        // the LANDSCAPE buffer without an orientation hint — its mask
        // lives in landscape coords. Vision's face bbox is in upright
        // normalized coords; multiplying it by the landscape buffer's
        // pixel dims inside `SafeModeProcessor.processFrame` lands the
        // anchor in the wrong region of the buffer. For a portrait
        // recording the subject's segmented body pixels end up
        // OUTSIDE the anchor → mis-classified as bystanders →
        // Gaussian-blurred. Net effect: portrait-recorded videos blur
        // the subject as well as the bystanders.
        //
        // Photo path was fixed by pre-rendering the UIImage upright
        // via UIKit before allocating the pixel buffer (constant cost,
        // single-frame). Video path is more invasive because the
        // AVAssetWriter output is tied to the track's
        // `naturalSize`/`preferredTransform`; rotating every frame on
        // the GPU through CIAffineTransform before the Safe Mode pass
        // is one option, and routing orientation through
        // PersonSegmenter (`VNImageRequestHandler(cvPixelBuffer:
        // orientation: options:)`) + remapping the Vision bbox back
        // to landscape coords inside `processFrame` is another. Both
        // are non-trivial enough to land in a follow-up PR.
        //
        // Memory budget note: SafeModeProcessor allocates a width*height
        // 8-bit scratch mask plus the CoreImage render graph holds
        // intermediate floats per frame. At 1080p (1920x1080) the mask
        // is ~2MB; CoreImage adds another ~30MB for the blur tiles —
        // safe under jetsam. At 4K (3840x2160) the mask balloons to
        // ~8MB and the blur graph approaches ~120MB, which combined
        // with the four writer pipelines pushes the process near the
        // jetsam threshold. Today the capture pipeline encodes at
        // <=1080p, so we keep buffers at `videoWidth x videoHeight`
        // (the rotation-corrected encode size, not native sensor
        // size). If 4K capture is ever enabled, insert a CIImage
        // downscale before processFrame so the Safe Mode pass works
        // at <=1920x1080 and the result is up-rezzed back to the
        // writer's resolution. Tracked alongside the photo path's
        // 1920px clamp in `applySafeModeToPhoto`.
        let safeProcessor: SafeModeProcessor? = (safeWriter != nil)
            ? SafeModeProcessor(
                width: videoWidth,
                height: videoHeight,
                orientation: safeOrientation
              )
            : nil

        // v7.1 dual-output: optional colour-segmented processor. Same Vision
        // mask, but the compositing is a colour-passthrough body + dimmed
        // colour background (no sketch / edge detection). Only allocated
        // when the segmented writer is live — keeps memory off the table
        // for legacy callers.
        let segProcessor: SegmentedColorProcessor? = (segWriter != nil)
            ? SegmentedColorProcessor(width: videoWidth, height: videoHeight)
            : nil

        // Pre-allocate the person segmenter (iOS 15+). Returns nil on older iOS
        // and the pipeline falls through to unmasked output. Pooled across frames
        // so VNSequenceRequestHandler and the upscale destination are reused.
        var segmenter: Any? = nil
        if #available(iOS 15.0, *) {
            segmenter = PersonSegmenter(width: videoWidth, height: videoHeight)
        }

        // Shared mutable counters. All reads/writes are serialised onto their
        // owning input queues (video pump runs on `videoQueue`, audio pump on
        // `audioQueue`, final state inspection happens inside `group.notify`
        // after both pumps have left), so no additional locking is required.
        var framesProcessed = 0
        var lastProgressReport = 0
        var audioSamplesWritten = 0
        var safeFramesProcessed = 0
        var safeVideoFinished = false

        NSLog(
            "[VideoConverter] starting video pump — estimatedFrames=\(estimatedTotalFrames) " +
            "audioInputAttached=\(audioWriterInput != nil)"
        )

        // --- Concurrent drain (PR #41 — fixes the multi-track hang) ---
        //
        // PR #39 introduced an audio track to the `AVAssetReader` + `AVAssetWriter`
        // pair. PR #40 added the instrumentation that confirmed (Carl's device
        // log 2026-04-20) the video busy-wait was spinning indefinitely while
        // the audio input's writer-side interleave budget stayed unfilled —
        // AVAssetWriter backpressures one input whenever another attached
        // input is starved of samples. The fix is the Apple-canonical pattern:
        // each writer input gets its own dispatch queue and its own
        // `requestMediaDataWhenReady` callback, and both pumps run in parallel.
        // A DispatchGroup gates `finishWriting` until both inputs have marked
        // themselves finished.
        //
        // Autoreleasepools remain inside each iteration — on clips >15s they're
        // the difference between a clean drain and a jetsam OOM kill.

        let group = DispatchGroup()
        let videoQueue = DispatchQueue(label: "homefit.videoconverter.video")
        let audioQueue = DispatchQueue(label: "homefit.videoconverter.audio")

        // Video pump — processes each incoming sample into a line drawing,
        // appends through the pixel buffer adaptor, and finishes the input
        // when the reader is exhausted. Holds a strong capture on the
        // channel so progress invocations still fire even if the owning
        // VideoConverterChannel is released mid-conversion — the reader,
        // writer, and pumps are all self-sufficient once the drain starts.
        //
        // v7.1 dual-output: when `segAdaptor` is non-nil, each iteration
        // additionally composes a segmented-colour frame (sharing the
        // Vision mask generated above) and appends to the segmented
        // adaptor. Vision segmentation runs ONCE per frame regardless;
        // both outputs share the same mask pointer.
        //
        // `segVideoFinished` is tracked independently of the line-drawing
        // pump so we can markAsFinished + group.leave on its input as
        // soon as the reader drains — matching the line writer exactly.
        group.enter()
        if segWriterInput != nil { group.enter() }
        if maskWriterInput != nil { group.enter() }
        if safeWriterInput != nil { group.enter() }
        var videoPumpFinished = false
        var segVideoFinished = false
        var maskVideoFinished = false
        var segFramesProcessed = 0
        var maskFramesProcessed = 0
        let progressChannel = self.channel
        writerInput.requestMediaDataWhenReady(on: videoQueue) {
            while writerInput.isReadyForMoreMediaData {
                autoreleasepool {
                    guard let sampleBuffer = readerOutput.copyNextSampleBuffer() else {
                        if !videoPumpFinished {
                            videoPumpFinished = true
                            NSLog(
                                "[VideoConverter] video pump exited — frames=\(framesProcessed) " +
                                "segFrames=\(segFramesProcessed) " +
                                "maskFrames=\(maskFramesProcessed) " +
                                "safeFrames=\(safeFramesProcessed) " +
                                "readerStatus=\(reader.status.rawValue) " +
                                "readerError=\(reader.error?.localizedDescription ?? "nil")"
                            )
                            writerInput.markAsFinished()
                            NSLog("[VideoConverter] video input markAsFinished called")
                            group.leave()
                            if let segInput = segWriterInput, !segVideoFinished {
                                segVideoFinished = true
                                segInput.markAsFinished()
                                NSLog("[VideoConverter] segmented video input markAsFinished called")
                                group.leave()
                            }
                            if let mInput = maskWriterInput, !maskVideoFinished {
                                maskVideoFinished = true
                                mInput.markAsFinished()
                                NSLog("[VideoConverter] mask video input markAsFinished called")
                                group.leave()
                            }
                            if let sfInput = safeWriterInput, !safeVideoFinished {
                                safeVideoFinished = true
                                sfInput.markAsFinished()
                                NSLog("[VideoConverter] safe video input markAsFinished called")
                                group.leave()
                            }
                        }
                        return
                    }

                    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                        return
                    }

                    let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

                    // Allocate an output pixel buffer from the adaptor's pool
                    // (reuses backing memory frame-to-frame).
                    var outputPixelBuffer: CVPixelBuffer?
                    let allocStatus: CVReturn
                    if let pool = adaptor.pixelBufferPool {
                        allocStatus = CVPixelBufferPoolCreatePixelBuffer(
                            nil,
                            pool,
                            &outputPixelBuffer
                        )
                    } else {
                        // Pool not available (only before startSession on some OS versions);
                        // fall back to direct allocation so we at least make forward progress.
                        allocStatus = CVPixelBufferCreate(
                            kCFAllocatorDefault,
                            videoWidth,
                            videoHeight,
                            kCVPixelFormatType_32BGRA,
                            nil,
                            &outputPixelBuffer
                        )
                    }

                    guard allocStatus == kCVReturnSuccess,
                          let outBuffer = outputPixelBuffer else {
                        return
                    }

                    // Generate person segmentation mask (iOS 15+). If segmentation
                    // fails or is unavailable, maskPtr stays nil and the processor
                    // falls through to an unmasked line drawing.
                    var maskPtr: UnsafePointer<UInt8>? = nil
                    if #available(iOS 15.0, *), let seg = segmenter as? PersonSegmenter {
                        maskPtr = seg.generateMask(for: pixelBuffer)
                    }

                    // Safe Mode downstream-variants fix (2026-05-22). When
                    // Safe Mode is active, paint the bystander coral
                    // silhouettes onto the source frame BEFORE the line /
                    // segmented / mask processors read from it. Without
                    // this re-order, only the dedicated safe writer
                    // honoured Safe Mode and every other output (line
                    // drawing + segmented + thumbnail extraction) leaked
                    // bystander identity even though PR #402 swapped the
                    // canonical raw archive at the consumer end.
                    //
                    // `safeSourceBuffer` is the buffer the downstream
                    // processors read from. When the safe pass succeeds
                    // we point it at the safe-painted buffer; otherwise
                    // (no Safe Mode, or this frame's safe composite
                    // failed) it stays on the raw `pixelBuffer`.
                    //
                    // Carl-signed (2026-05-22): the LOCKED-v6 line-drawing
                    // tuning exception is APPROVED — feeding safe pixels
                    // into the edge detector is correct (a flat coral
                    // region produces a flat silhouette rather than
                    // identity-revealing edges).
                    var safeSourceBuffer: CVPixelBuffer = pixelBuffer
                    var safeOutForDownstream: CVPixelBuffer? = nil
                    if let sfAd = safeAdaptor,
                       let safeProc = safeProcessor,
                       !safeVideoFinished {
                        var sfOut: CVPixelBuffer?
                        let sfAlloc: CVReturn
                        if let pool = sfAd.pixelBufferPool {
                            sfAlloc = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &sfOut)
                        } else {
                            sfAlloc = CVPixelBufferCreate(
                                kCFAllocatorDefault,
                                videoWidth,
                                videoHeight,
                                kCVPixelFormatType_32BGRA,
                                nil,
                                &sfOut
                            )
                        }
                        if sfAlloc == kCVReturnSuccess, let sfBuffer = sfOut {
                            if safeProc.processFrame(
                                source: pixelBuffer,
                                mask: maskPtr,
                                into: sfBuffer
                            ) {
                                safeSourceBuffer = sfBuffer
                                safeOutForDownstream = sfBuffer
                            }
                        }
                    }

                    // Process the frame into a line drawing, writing into outBuffer.
                    // When maskPtr != nil the processor erases (forces to white) any
                    // pixel whose mask value is below 128 — the background.
                    // 2026-05-22: source from `safeSourceBuffer` so the line
                    // drawing honours the Safe Mode bystander paint when
                    // active. The Vision mask was computed against the raw
                    // `pixelBuffer` so the body-vs-background segmentation
                    // is unchanged — only the per-pixel RGB sampling shifts
                    // to the safe-painted buffer.
                    guard processor.processFrame(safeSourceBuffer, mask: maskPtr, into: outBuffer) else {
                        return
                    }

                    adaptor.append(outBuffer, withPresentationTime: presentationTime)
                    framesProcessed += 1

                    // v7.1 segmented-colour pass. Same Vision mask, different
                    // compositing (body passthrough, background dimmed). We
                    // allocate a second output pixel buffer from the segmented
                    // adaptor's pool, compose, and append. Best-effort — any
                    // failure (pool exhausted, append returned false) is
                    // logged at frame-level and the seg output continues to
                    // receive subsequent frames. If appends stall because the
                    // seg input isn't ready we briefly spin — matches the
                    // AVFoundation canonical pattern where one ready input
                    // drives the tick and the paired input's buffer absorbs
                    // the burst.
                    if let segAd = segAdaptor,
                       let segInput = segWriterInput,
                       let sProc = segProcessor,
                       !segVideoFinished {
                        var segOut: CVPixelBuffer?
                        let segAlloc: CVReturn
                        if let pool = segAd.pixelBufferPool {
                            segAlloc = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &segOut)
                        } else {
                            segAlloc = CVPixelBufferCreate(
                                kCFAllocatorDefault,
                                videoWidth,
                                videoHeight,
                                kCVPixelFormatType_32BGRA,
                                nil,
                                &segOut
                            )
                        }
                        if segAlloc == kCVReturnSuccess, let segBuffer = segOut {
                            // 2026-05-22: source from `safeSourceBuffer` so the
                            // segmented-colour composite honours Safe Mode
                            // bystander paint when active. The mask was
                            // computed against the raw frame so body
                            // detection is unchanged; only RGB shifts.
                            if sProc.processFrame(safeSourceBuffer, mask: maskPtr, into: segBuffer) {
                                // Brief spin-wait up to ~200ms for seg input
                                // to absorb backpressure. Beyond that we drop
                                // the frame rather than block the line pump.
                                var waited = 0
                                while !segInput.isReadyForMoreMediaData && waited < 200 {
                                    usleep(1000) // 1ms
                                    waited += 1
                                }
                                if segInput.isReadyForMoreMediaData {
                                    if segAd.append(segBuffer, withPresentationTime: presentationTime) {
                                        segFramesProcessed += 1
                                    }
                                }
                            }
                        }
                    }

                    // v7.2 mask-sidecar pass. Takes the same Vision mask
                    // already computed for the line-drawing + segmented
                    // outputs, expands Planar8 → BGRA (R=G=B=maskValue,
                    // alpha=255) so the H.264 encoder will accept it, and
                    // appends to the mask adaptor. Best-effort — any
                    // failure (pool exhausted, missing mask, append backed
                    // off) is swallowed and the other two passes continue
                    // unchanged. If no Vision mask was produced for this
                    // frame (iOS <15, empty scene), we emit an all-black
                    // frame so timeline alignment with the segmented file
                    // is preserved.
                    if let mAd = maskAdaptor,
                       let mInput = maskWriterInput,
                       !maskVideoFinished {
                        var mOut: CVPixelBuffer?
                        let mAlloc: CVReturn
                        if let pool = mAd.pixelBufferPool {
                            mAlloc = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &mOut)
                        } else {
                            mAlloc = CVPixelBufferCreate(
                                kCFAllocatorDefault,
                                videoWidth,
                                videoHeight,
                                kCVPixelFormatType_32BGRA,
                                nil,
                                &mOut
                            )
                        }
                        if mAlloc == kCVReturnSuccess, let mBuffer = mOut {
                            if MaskOutputProcessor.writePlanar8MaskAsBGRA(
                                mask: maskPtr,
                                width: videoWidth,
                                height: videoHeight,
                                into: mBuffer
                            ) {
                                // Same 200ms spin-wait as segmented — the
                                // writer can stall briefly when the audio
                                // input is still catching up.
                                var waited = 0
                                while !mInput.isReadyForMoreMediaData && waited < 200 {
                                    usleep(1000)
                                    waited += 1
                                }
                                if mInput.isReadyForMoreMediaData {
                                    if mAd.append(mBuffer, withPresentationTime: presentationTime) {
                                        maskFramesProcessed += 1
                                    }
                                }
                            }
                        }
                    }

                    // Safe Mode (2026-05-21, single-pass refactor 2026-05-22):
                    // Append the safe-painted buffer produced above to the
                    // safe writer. Pre-2026-05-22 this block ran the safe
                    // pass independently — but that left line/segmented/mask
                    // sourcing from the raw `pixelBuffer` (bystander leak).
                    // The buffer is now produced ONCE before the line pump
                    // (see `safeSourceBuffer` block) and reused here, so
                    // every downstream output honours Safe Mode.
                    //
                    // `safeOutForDownstream` holds the freshly-produced
                    // safe buffer; nil means either Safe Mode is off or
                    // this frame's safe composite failed (a Vision miss
                    // counter that the Dart side reads via `safeFramesMissedRate`
                    // for the fail-closed threshold).
                    if let sfAd = safeAdaptor,
                       let sfInput = safeWriterInput,
                       !safeVideoFinished,
                       let sfBuffer = safeOutForDownstream {
                        var waited = 0
                        while !sfInput.isReadyForMoreMediaData && waited < 200 {
                            usleep(1000)
                            waited += 1
                        }
                        if sfInput.isReadyForMoreMediaData {
                            if sfAd.append(sfBuffer, withPresentationTime: presentationTime) {
                                safeFramesProcessed += 1
                            }
                        }
                    }

                    // Report progress every 30 frames.
                    if framesProcessed - lastProgressReport >= 30 {
                        lastProgressReport = framesProcessed
                        let progress: [String: Any] = [
                            "framesProcessed": framesProcessed,
                            "totalFrames": estimatedTotalFrames,
                        ]
                        DispatchQueue.main.async {
                            progressChannel.invokeMethod("onProgress", arguments: progress)
                        }
                        NSLog(
                            "[VideoConverter] pump progress frame=\(framesProcessed)/\(estimatedTotalFrames) " +
                            "segFrames=\(segFramesProcessed) " +
                            "maskFrames=\(maskFramesProcessed) " +
                            "audioInputReady=\(audioWriterInput?.isReadyForMoreMediaData ?? false)"
                        )
                    }
                }
                if videoPumpFinished { return }
            }
        }

        // Audio pump — only started if the audio track was successfully
        // attached to both reader and writer during setup. Runs concurrently
        // with the video pump, on its own queue, so the AVAssetWriter can
        // interleave samples without either input starving the other.
        //
        // v7.1 dual-output: when `segAudioWriterInput` is live we append the
        // same CMSampleBuffer to BOTH audio writer inputs per iteration.
        // Audio samples are passthrough (no re-encoding) so the buffer is
        // immutable; each writer retains its own reference. If the seg
        // input is not ready we briefly spin (matches the video pump's
        // backpressure pattern) before dropping the sample. A dropped seg
        // audio sample produces a tiny gap in the segmented file's audio
        // track — non-fatal for playback.
        if let audioOutput = audioReaderOutput, let audioInput = audioWriterInput {
            NSLog(
                "[VideoConverter] starting audio pump — " +
                "readerStatus=\(reader.status.rawValue) " +
                "segAudioAttached=\(segAudioWriterInput != nil)"
            )
            group.enter()
            if segAudioWriterInput != nil { group.enter() }
            var audioPumpFinished = false
            var segAudioFinished = false
            audioInput.requestMediaDataWhenReady(on: audioQueue) {
                while audioInput.isReadyForMoreMediaData {
                    autoreleasepool {
                        guard let audioSample = audioOutput.copyNextSampleBuffer() else {
                            if !audioPumpFinished {
                                audioPumpFinished = true
                                NSLog(
                                    "[VideoConverter] audio drain complete — " +
                                    "samplesWritten=\(audioSamplesWritten)"
                                )
                                audioInput.markAsFinished()
                                NSLog("[VideoConverter] audio input markAsFinished called")
                                group.leave()
                                if let segAudio = segAudioWriterInput, !segAudioFinished {
                                    segAudioFinished = true
                                    segAudio.markAsFinished()
                                    NSLog("[VideoConverter] segmented audio input markAsFinished called")
                                    group.leave()
                                }
                            }
                            return
                        }
                        if audioInput.append(audioSample) {
                            audioSamplesWritten += 1
                        }
                        // Tee to the segmented writer's audio input. Spin
                        // briefly if it's still backpressured; drop the
                        // sample if the spin times out.
                        if let segAudio = segAudioWriterInput, !segAudioFinished {
                            var waited = 0
                            while !segAudio.isReadyForMoreMediaData && waited < 200 {
                                usleep(1000)
                                waited += 1
                            }
                            if segAudio.isReadyForMoreMediaData {
                                _ = segAudio.append(audioSample)
                            }
                        }
                    }
                    if audioPumpFinished { return }
                }
            }
        } else {
            NSLog(
                "[VideoConverter] audio drain skipped — " +
                "audioReaderOutput=\(audioReaderOutput != nil) " +
                "audioWriterInput=\(audioWriterInput != nil)"
            )
        }

        // --- Finalisation ---
        // Wait for BOTH pumps to finish (DispatchGroup) before calling
        // `finishWriting`. Notify on a global queue rather than
        // `processingQueue` (which is serial and still owns this call frame
        // until convertVideo returns — we don't want follow-up channel calls
        // to block behind finishWriting's 60s timeout).
        //
        // v7.1 dual-output: finish writing on BOTH writers in sequence,
        // each guarded by its own 60s semaphore. Line-drawing failure is
        // fatal (propagates as WRITE_FAILED). Segmented-writer failure is
        // best-effort — the result still reports success for the line
        // output, and segmentedOutputPath is simply omitted from the
        // return map so the Dart side knows the segmented file is absent.
        let notifyQueue = DispatchQueue.global(qos: .userInitiated)
        group.notify(queue: notifyQueue) {
            NSLog("[VideoConverter] calling finishWriting (60s timeout)")
            let semaphore = DispatchSemaphore(value: 0)
            writer.finishWriting {
                semaphore.signal()
            }
            let waitResult = semaphore.wait(timeout: .now() + 60)
            if waitResult == .timedOut {
                NSLog(
                    "[VideoConverter] finishWriting TIMEOUT after 60s — " +
                    "frames=\(framesProcessed) audioSamplesWritten=\(audioSamplesWritten) " +
                    "writerStatus=\(writer.status.rawValue) " +
                    "writerError=\(writer.error?.localizedDescription ?? "nil") " +
                    "readerStatus=\(reader.status.rawValue) " +
                    "readerError=\(reader.error?.localizedDescription ?? "nil")"
                )
                writer.cancelWriting()
                if let sw = segWriter { sw.cancelWriting() }
                if let mw = maskWriter { mw.cancelWriting() }
                reader.cancelReading()
                DispatchQueue.main.async {
                    result(FlutterError(
                        code: "TIMEOUT",
                        message: "Conversion timed out",
                        details: nil
                    ))
                    endBackgroundTask()
                }
                return
            }

            // v7.1: finish the segmented writer, best-effort. A failure
            // here doesn't poison the line-drawing result — the segmented
            // file is additive, and the pre-v7.1 client experience is
            // preserved when it's absent.
            var segSuccessPath: String? = nil
            if let sw = segWriter, let segPath = segmentedOutputPath {
                let segSem = DispatchSemaphore(value: 0)
                sw.finishWriting {
                    segSem.signal()
                }
                let segWait = segSem.wait(timeout: .now() + 60)
                if segWait == .timedOut {
                    NSLog(
                        "[VideoConverter] segmented finishWriting TIMEOUT — " +
                        "segFrames=\(segFramesProcessed) " +
                        "segWriterStatus=\(sw.status.rawValue) " +
                        "segWriterError=\(sw.error?.localizedDescription ?? "nil")"
                    )
                    sw.cancelWriting()
                    // Don't set segSuccessPath — segmented output is
                    // deliberately omitted from the result so Dart skips
                    // persisting / uploading a partial file.
                    try? FileManager.default.removeItem(at: URL(fileURLWithPath: segPath))
                } else if sw.status == .completed {
                    NSLog("[VideoConverter] segmented finishWriting completed — segFrames=\(segFramesProcessed)")
                    segSuccessPath = segPath
                } else {
                    NSLog(
                        "[VideoConverter] segmented finishWriting failed — " +
                        "segWriterStatus=\(sw.status.rawValue) " +
                        "segWriterError=\(sw.error?.localizedDescription ?? "nil")"
                    )
                    try? FileManager.default.removeItem(at: URL(fileURLWithPath: segPath))
                }
            }

            // v7.2: finish the mask writer. Same best-effort contract as
            // the segmented writer — failure here is silent; only the
            // mask-sidecar key is omitted from the result so Dart knows
            // to skip persisting / uploading a partial file. Line-drawing
            // + segmented outputs are already finalised by this point;
            // nothing this block does can poison them.
            var maskSuccessPath: String? = nil
            if let mw = maskWriter, let maskPath = maskOutputPath {
                let mSem = DispatchSemaphore(value: 0)
                mw.finishWriting {
                    mSem.signal()
                }
                let mWait = mSem.wait(timeout: .now() + 60)
                if mWait == .timedOut {
                    NSLog(
                        "[VideoConverter] mask finishWriting TIMEOUT — " +
                        "maskFrames=\(maskFramesProcessed) " +
                        "maskWriterStatus=\(mw.status.rawValue) " +
                        "maskWriterError=\(mw.error?.localizedDescription ?? "nil")"
                    )
                    mw.cancelWriting()
                    try? FileManager.default.removeItem(at: URL(fileURLWithPath: maskPath))
                } else if mw.status == .completed {
                    NSLog("[VideoConverter] mask finishWriting completed — maskFrames=\(maskFramesProcessed)")
                    maskSuccessPath = maskPath
                } else {
                    NSLog(
                        "[VideoConverter] mask finishWriting failed — " +
                        "maskWriterStatus=\(mw.status.rawValue) " +
                        "maskWriterError=\(mw.error?.localizedDescription ?? "nil")"
                    )
                    try? FileManager.default.removeItem(at: URL(fileURLWithPath: maskPath))
                }
            }

            // Safe Mode: finish the safe writer. Same best-effort contract.
            var safeSuccessPath: String? = nil
            if let sw = safeWriter, let safePath = safeOutputPath {
                let sfSem = DispatchSemaphore(value: 0)
                sw.finishWriting {
                    sfSem.signal()
                }
                let sfWait = sfSem.wait(timeout: .now() + 60)
                if sfWait == .timedOut {
                    NSLog(
                        "[VideoConverter] safe finishWriting TIMEOUT — " +
                        "safeFrames=\(safeFramesProcessed) " +
                        "safeWriterStatus=\(sw.status.rawValue) " +
                        "safeWriterError=\(sw.error?.localizedDescription ?? "nil")"
                    )
                    sw.cancelWriting()
                    try? FileManager.default.removeItem(at: URL(fileURLWithPath: safePath))
                } else if sw.status == .completed {
                    NSLog("[VideoConverter] safe finishWriting completed — safeFrames=\(safeFramesProcessed)")
                    safeSuccessPath = safePath
                } else {
                    NSLog(
                        "[VideoConverter] safe finishWriting failed — " +
                        "safeWriterStatus=\(sw.status.rawValue) " +
                        "safeWriterError=\(sw.error?.localizedDescription ?? "nil")"
                    )
                    try? FileManager.default.removeItem(at: URL(fileURLWithPath: safePath))
                }
            }

            reader.cancelReading()

            // Surface audio + error state in the device log so we can verify
            // on the next capture whether audio samples actually made it into
            // the output. A silent Line-treatment playback with
            // `audioSamplesWritten > 0` here means the issue is downstream
            // (player volume, mux, or decoder); zero means it's upstream
            // (gate disabled, reader failed, or source had no audio track).
            NSLog(
                "[VideoConverter] convert done — frames=\(framesProcessed) " +
                "audioIncluded=\(includeAudio) audioInputAttached=\(audioWriterInput != nil) " +
                "audioSamplesWritten=\(audioSamplesWritten) " +
                "segOutputWritten=\(segSuccessPath != nil) " +
                "segFrames=\(segFramesProcessed) " +
                "maskOutputWritten=\(maskSuccessPath != nil) " +
                "maskFrames=\(maskFramesProcessed) " +
                "safeOutputWritten=\(safeSuccessPath != nil) " +
                "safeFrames=\(safeFramesProcessed) " +
                "writerStatus=\(writer.status.rawValue) " +
                "writerError=\(writer.error?.localizedDescription ?? "nil") " +
                "readerStatus=\(reader.status.rawValue) " +
                "readerError=\(reader.error?.localizedDescription ?? "nil")"
            )

            if writer.status == .completed {
                DispatchQueue.main.async {
                    var payload: [String: Any] = [
                        "success": true,
                        "framesProcessed": framesProcessed,
                        "audioSamplesWritten": audioSamplesWritten,
                        "outputPath": outputPath,
                    ]
                    if let segPath = segSuccessPath {
                        payload["segmentedOutputPath"] = segPath
                        payload["segFramesProcessed"] = segFramesProcessed
                    }
                    if let maskPath = maskSuccessPath {
                        payload["maskOutputPath"] = maskPath
                        payload["maskFramesProcessed"] = maskFramesProcessed
                    }
                    if let safePath = safeSuccessPath {
                        payload["safeOutputPath"] = safePath
                        payload["safeFramesProcessed"] = safeFramesProcessed
                        // Vision miss-rate surfaced for the Dart side's
                        // fail-closed threshold check (Safe Mode
                        // completion wave, 2026-05-21). Zero when no
                        // safe processor ran; otherwise [0, 1].
                        payload["safeFramesMissedRate"] =
                            safeProcessor?.missRate ?? 0.0
                        // Low-confidence flag (2026-05-22). Sticky: true
                        // if any frame's two largest faces were within
                        // 80% of each other in area. Dart side uses this
                        // to surface a tap-to-confirm UI post-capture
                        // (separate Flutter PR). Defaults to false so
                        // pre-wave callers see no behaviour change.
                        payload["lowConfidence"] =
                            safeProcessor?.lowConfidence ?? false
                    }
                    result(payload)
                    endBackgroundTask()
                }
            } else {
                DispatchQueue.main.async {
                    result(FlutterError(
                        code: "WRITE_FAILED",
                        message: "AVAssetWriter finished with status \(writer.status.rawValue): \(writer.error?.localizedDescription ?? "unknown")",
                        details: nil
                    ))
                    endBackgroundTask()
                }
            }
        }
    }

    // MARK: - Video Compression (Raw Archive)

    /// Compress a video to 720p H.264 + AAC using AVAssetExportSession.
    /// Used by the local raw-archive pipeline so every captured clip has a
    /// compact archival copy for re-running future line-drawing filters.
    /// Fire-and-forget from Dart — failures must not disturb the main flow.
    private func compressVideo(
        inputPath: String,
        outputPath: String,
        result: @escaping FlutterResult
    ) {
        // --- Defense in depth: validate input file exists and is readable ---
        guard FileManager.default.fileExists(atPath: inputPath),
              FileManager.default.isReadableFile(atPath: inputPath) else {
            DispatchQueue.main.async {
                result(FlutterError(
                    code: "FILE_NOT_FOUND",
                    message: "Input file does not exist or is not readable: \(inputPath)",
                    details: nil
                ))
            }
            return
        }

        // --- Background task assertion ---
        // Bracket the export with begin/end so a brief backgrounding during
        // compression doesn't truncate the output. The background task is
        // ended on both success and failure paths below.
        var bgTaskId: UIBackgroundTaskIdentifier = .invalid
        bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "video-compress") {
            if bgTaskId != .invalid {
                UIApplication.shared.endBackgroundTask(bgTaskId)
                bgTaskId = .invalid
            }
        }
        let endBackgroundTask: () -> Void = {
            if bgTaskId != .invalid {
                UIApplication.shared.endBackgroundTask(bgTaskId)
                bgTaskId = .invalid
            }
        }

        let inputURL = URL(fileURLWithPath: inputPath)
        let outputURL = URL(fileURLWithPath: outputPath)

        // Ensure the parent directory exists.
        do {
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            DispatchQueue.main.async {
                result(FlutterError(
                    code: "COMPRESS_FAILED",
                    message: "Could not create output directory: \(error.localizedDescription)",
                    details: nil
                ))
                endBackgroundTask()
            }
            return
        }

        // Remove any pre-existing output file (AVAssetExportSession refuses to overwrite).
        try? FileManager.default.removeItem(at: outputURL)

        let asset = AVURLAsset(url: inputURL)

        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPreset1280x720
        ) else {
            DispatchQueue.main.async {
                result(FlutterError(
                    code: "COMPRESS_FAILED",
                    message: "Could not create AVAssetExportSession",
                    details: nil
                ))
                endBackgroundTask()
            }
            return
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = true

        exportSession.exportAsynchronously {
            switch exportSession.status {
            case .completed:
                let sizeBytes: Int64
                if let attrs = try? FileManager.default.attributesOfItem(atPath: outputPath),
                   let size = attrs[.size] as? NSNumber {
                    sizeBytes = size.int64Value
                } else {
                    sizeBytes = 0
                }
                DispatchQueue.main.async {
                    result([
                        "success": true,
                        "outputPath": outputPath,
                        "sizeBytes": NSNumber(value: sizeBytes),
                    ])
                    endBackgroundTask()
                }
            case .cancelled:
                DispatchQueue.main.async {
                    result(FlutterError(
                        code: "EXPORT_CANCELLED",
                        message: "Compression was cancelled",
                        details: nil
                    ))
                    endBackgroundTask()
                }
            default:
                let message = exportSession.error?.localizedDescription
                    ?? "Export finished with status \(exportSession.status.rawValue)"
                DispatchQueue.main.async {
                    result(FlutterError(
                        code: "COMPRESS_FAILED",
                        message: message,
                        details: nil
                    ))
                    endBackgroundTask()
                }
            }
        }
    }

    // MARK: - Thumbnail Extraction

    private func extractThumbnail(
        inputPath: String,
        outputPath: String,
        timeMs: Int,
        autoPick: Bool,
        grayscale: Bool = false,
        result: @escaping FlutterResult
    ) {
        // Defense in depth: verify the input file exists and is readable.
        guard FileManager.default.fileExists(atPath: inputPath),
              FileManager.default.isReadableFile(atPath: inputPath) else {
            DispatchQueue.main.async {
                result(FlutterError(
                    code: "FILE_NOT_FOUND",
                    message: "Input file does not exist or is not readable: \(inputPath)",
                    details: nil
                ))
            }
            return
        }

        let inputURL = URL(fileURLWithPath: inputPath)
        let asset = AVURLAsset(url: inputURL)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        // Tone-map HDR/Dolby Vision (iPhone 15 Pro+ default) to SDR so thumbnail
        // extraction succeeds on newer iOS. Without this, HDR content can fail
        // silently or produce blank frames. dynamicRangePolicy is iOS 18+.
        if #available(iOS 18.0, *) {
            generator.dynamicRangePolicy = .forceSDR
        }

        // Target time selection:
        //   - autoPick:false → use the caller-supplied `timeMs` verbatim
        //     (preserves the legacy contract).
        //   - autoPick:true  → pick the motion-peak of a 3-frame sample
        //     against frame 0, falling back to midpoint if sampling fails.
        //     This produces a more representative thumbnail for the trainer
        //     surfaces (Studio list, session cards, Camera peek).
        let targetTime: CMTime = {
            if !autoPick {
                return CMTime(value: CMTimeValue(timeMs), timescale: 1000)
            }
            return Self.pickMotionPeakTime(asset: asset, generator: generator)
        }()
        // Wave Hero — capture the resolved time so we can return it in
        // the response payload. Dart callers persist this as the
        // exercise's focus_frame_offset_ms (the practitioner-facing
        // "Hero" frame offset). On autoPick:true this is the motion-peak
        // sample; on autoPick:false it matches the verbatim caller arg.
        let resolvedSecondsForResult = CMTimeGetSeconds(targetTime)
        let pickedTimeMsForResult: Int = (resolvedSecondsForResult.isFinite
            && resolvedSecondsForResult >= 0)
            ? Int((resolvedSecondsForResult * 1000).rounded())
            : timeMs

        let handleImage: (CGImage?, Error?) -> Void = { cgImage, error in
            if let error = error {
                DispatchQueue.main.async {
                    result(FlutterError(
                        code: "THUMBNAIL_FAILED",
                        message: "Could not extract thumbnail: \(error.localizedDescription)",
                        details: nil
                    ))
                }
                return
            }
            guard let cgImage = cgImage else {
                DispatchQueue.main.async {
                    result(FlutterError(
                        code: "THUMBNAIL_FAILED",
                        message: "Thumbnail extraction returned no image",
                        details: nil
                    ))
                }
                return
            }
            // Apply person segmentation to the thumbnail (iOS 15+). If it
            // fails or is unavailable, fall through to the un-masked image.
            // On autoPick:true we also crop tight around the person using
            // the mask's bounding box for a more readable small-surface
            // thumbnail. When `grayscale` is true, segmentation skips the
            // two-zone background-dim pass and instead recolours the whole
            // frame to luminance — used by practitioner-facing list
            // thumbnails where the B&W frame is more legible than the
            // line-drawing treatment.
            //
            // Wave Lobby auto-pick — same free-axis centroid plumbing as
            // AppDelegate.extractFrame: when segmentation succeeds we
            // surface the mask's normalised centroid in the response
            // map so Dart can stamp `exercises.hero_crop_offset`.
            var finalImage: CGImage = cgImage
            var autoHeroCropOffset: Double? = nil
            if #available(iOS 15.0, *) {
                if let segResult = Self.applySegmentationToThumbnailWithCentroid(
                    cgImage: cgImage,
                    cropToPerson: autoPick,
                    grayscale: grayscale
                ) {
                    finalImage = segResult.image
                    autoHeroCropOffset = segResult.centroidOffset
                } else if grayscale {
                    // Segmentation bailed (no person / pre-iOS-15) but the
                    // caller still asked for a B&W thumbnail — honour the
                    // contract by grayscaling the full frame.
                    if let gray = Self.grayscaleCGImage(cgImage) {
                        finalImage = gray
                    }
                }
            } else if grayscale {
                if let gray = Self.grayscaleCGImage(cgImage) {
                    finalImage = gray
                }
            }
            let uiImage = UIImage(cgImage: finalImage)
            guard let jpegData = uiImage.jpegData(compressionQuality: 0.85) else {
                DispatchQueue.main.async {
                    result(FlutterError(
                        code: "JPEG_ENCODE_FAILED",
                        message: "Could not encode thumbnail as JPEG",
                        details: nil
                    ))
                }
                return
            }
            do {
                let outURL = URL(fileURLWithPath: outputPath)
                try FileManager.default.createDirectory(
                    at: outURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try jpegData.write(to: outURL)
                DispatchQueue.main.async {
                    // Wave Lobby — emit the auto-pick centroid as
                    // `autoHeroCropOffset` when segmentation produced a
                    // mask. Same omit-on-nil contract as
                    // AppDelegate.extractFrame's twin payload. Dart
                    // callers persist this onto
                    // `exercises.hero_crop_offset` when set.
                    var resultMap: [String: Any] = [
                        "success": true,
                        "outputPath": outputPath,
                        // Wave Hero — picked timeMs (motion-peak sample
                        // on autoPick:true; caller's verbatim timeMs on
                        // autoPick:false). Persisted by Dart callers as
                        // the Hero offset.
                        "timeMs": pickedTimeMsForResult,
                    ]
                    if let offset = autoHeroCropOffset {
                        resultMap["autoHeroCropOffset"] = offset
                    }
                    result(resultMap)
                }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(
                        code: "WRITE_FAILED",
                        message: "Could not write thumbnail: \(error.localizedDescription)",
                        details: nil
                    ))
                }
            }
        }

        if #available(iOS 16.0, *) {
            generator.generateCGImageAsynchronously(for: targetTime) { cgImage, _, error in
                handleImage(cgImage, error)
            }
        } else {
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let cgImage = try generator.copyCGImage(at: targetTime, actualTime: nil)
                    handleImage(cgImage, nil)
                } catch {
                    handleImage(nil, error)
                }
            }
        }
    }

    // MARK: - Motion-Peak Frame Selection

    /// Pick a representative frame inside `asset` by sampling three
    /// candidates (at 33%, 50%, 67% of the duration), measuring their
    /// grayscale mean absolute difference against frame 0, and returning
    /// the time of the candidate with the largest diff. Falls back to
    /// the midpoint if anything goes wrong or the asset has no duration.
    ///
    /// This is a heuristic — the goal is to avoid frame 0 for videos that
    /// start with the practitioner walking into position or a static
    /// prep pose. Cheap: pulls one baseline frame + three candidates at
    /// ~128 px downscales each, so total work is ~4 AVAssetImageGenerator
    /// calls. Still synchronous from the caller's point of view because
    /// we're already on the background processingQueue.
    static func pickMotionPeakTime(
        asset: AVAsset,
        generator: AVAssetImageGenerator
    ) -> CMTime {
        let duration = asset.duration
        let totalSeconds = CMTimeGetSeconds(duration)
        // Sanity: < ~0.3s of footage → just return midpoint (or zero).
        guard totalSeconds.isFinite, totalSeconds > 0.3 else {
            if totalSeconds.isFinite, totalSeconds > 0 {
                return CMTime(seconds: totalSeconds / 2.0, preferredTimescale: 600)
            }
            return .zero
        }

        // Baseline frame @ 0s.
        guard let baseline = try? generator.copyCGImage(
            at: .zero,
            actualTime: nil
        ) else {
            return CMTime(seconds: totalSeconds / 2.0, preferredTimescale: 600)
        }
        guard let baselineLuma = grayscaleFingerprint(from: baseline) else {
            return CMTime(seconds: totalSeconds / 2.0, preferredTimescale: 600)
        }

        let sampleFractions: [Double] = [0.33, 0.50, 0.67]
        var bestTime = CMTime(seconds: totalSeconds / 2.0, preferredTimescale: 600)
        var bestDiff: Double = -1

        for frac in sampleFractions {
            let t = CMTime(seconds: totalSeconds * frac, preferredTimescale: 600)
            guard let candidate = try? generator.copyCGImage(at: t, actualTime: nil),
                  let candidateLuma = grayscaleFingerprint(from: candidate),
                  candidateLuma.count == baselineLuma.count else {
                continue
            }
            var acc: Int = 0
            for i in 0..<candidateLuma.count {
                acc += abs(Int(candidateLuma[i]) - Int(baselineLuma[i]))
            }
            let diff = Double(acc) / Double(candidateLuma.count)
            if diff > bestDiff {
                bestDiff = diff
                bestTime = t
            }
        }

        // If every candidate failed, bestDiff is still -1 → bestTime is
        // midpoint, which is our fallback anyway.
        return bestTime
    }

    /// Downscale a CGImage to 64×64 grayscale and return the raw pixel
    /// bytes. Used as a cheap motion fingerprint (mean abs diff vs
    /// baseline). Nil on any allocation/context failure.
    private static func grayscaleFingerprint(from cgImage: CGImage) -> [UInt8]? {
        let size = 64
        let byteCount = size * size
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: byteCount)
        defer { buffer.deallocate() }
        buffer.initialize(repeating: 0, count: byteCount)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: buffer,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }
        ctx.interpolationQuality = .low
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
        // Copy out into a Swift-managed array so the caller doesn't
        // outlive our deferred deallocation.
        return Array(UnsafeBufferPointer(start: buffer, count: byteCount))
    }

    // MARK: - Thumbnail Segmentation Helper

    /// Run person segmentation on a single still image and return a new
    /// CGImage with the background erased to white. Returns nil on any
    /// failure — callers should fall through to the un-masked source image.
    ///
    /// Used by both the VideoConverterChannel thumbnail path and the
    /// AppDelegate native_thumb channel, so both surfaces get body-only
    /// previews that match the video look.
    ///
    /// When `cropToPerson` is true and segmentation succeeds, the output
    /// is additionally cropped to the person's mask bounding box with
    /// ~10% padding. Improves readability at small sizes (Studio list,
    /// Camera peek). Falls back gracefully to the un-cropped masked image
    /// if the bounding box is degenerate.
    ///
    /// When `grayscale` is true, the usual body/background two-zone dim is
    /// SKIPPED and each BGRA pixel is instead recoloured to its luminance
    /// ([R,G,B] × [0.299, 0.587, 0.114]) with all three channels set to
    /// that value. Used by practitioner-facing list thumbnails so the
    /// client is visible and readable at small sizes (the line-drawing
    /// treatment lives on the client-facing web player). The
    /// segmentation-based bounding-box crop still runs when
    /// `cropToPerson` is true — we just skip the body/background blend.
    @available(iOS 15.0, *)
    static func applySegmentationToThumbnail(
        cgImage: CGImage,
        cropToPerson: Bool = false,
        grayscale: Bool = false
    ) -> CGImage? {
        // Back-compat wrapper — the centroid-producing variant is below.
        // Existing call-sites (notably AppDelegate.extractFrame) that
        // don't care about the auto-pick centroid keep the old shape.
        return applySegmentationToThumbnailWithCentroid(
            cgImage: cgImage,
            cropToPerson: cropToPerson,
            grayscale: grayscale
        )?.image
    }

    /// Wave Lobby — segmentation result that ALSO carries the
    /// auto-pick centroid for the 1:1 hero crop. The centroid is a
    /// normalised [0,1] offset along the source's *free axis* (vertical
    /// for portrait CGImages, horizontal for landscape) — matches the
    /// free-axis convention used by `web-player/hero_resolver.js` +
    /// `app/lib/widgets/hero_crop_viewport.dart`.
    ///
    /// `centroidOffset` is nil when:
    ///   - segmentation produced no person mask (no body to centre on);
    ///   - the source is square (no free axis exists; centre crop is
    ///     a fixed no-op);
    ///   - the centroid was clamped to a degenerate value.
    ///
    /// Dart callers persist this onto `ExerciseCapture.heroCropOffset`
    /// so the lobby + every thumbnail consumer renders the practitioner
    /// (not whatever happens to be middle-of-frame) by default.
    struct SegmentedThumbnailResult {
        let image: CGImage
        let centroidOffset: Double?
    }

    /// Variant of [applySegmentationToThumbnail] that also computes a
    /// segmentation-mask centroid and returns it as a normalised
    /// free-axis offset (see [SegmentedThumbnailResult]). Returns nil
    /// only when segmentation/buffer setup fails — same contract as the
    /// non-centroid wrapper. When segmentation succeeds but the source
    /// is square (centroid is meaningless), the returned struct has a
    /// non-nil `image` and a nil `centroidOffset`.
    ///
    /// Implementation note: the centroid is the intensity-weighted
    /// average of the *soft* (tent-convolved) mask. Using the soft
    /// mask rather than thresholding at 128 makes the value resilient
    /// to small fragments + matches the body/background blend the
    /// thumbnail itself uses. We sum positions weighted by mask value
    /// in a single pass over the same buffer the body/background blend
    /// already touches, so the cost is sub-millisecond on a 720p
    /// thumbnail.
    @available(iOS 15.0, *)
    static func applySegmentationToThumbnailWithCentroid(
        cgImage: CGImage,
        cropToPerson: Bool = false,
        grayscale: Bool = false
    ) -> SegmentedThumbnailResult? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        // --- Render the CGImage into a BGRA CVPixelBuffer so Vision can eat it. ---
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        var pixelBufferOut: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBufferOut
        )
        guard status == kCVReturnSuccess, let pixelBuffer = pixelBufferOut else {
            NSLog("applySegmentationToThumbnail: CVPixelBufferCreate failed (\(status))")
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        // BGRA = little-endian 32 with premultiplied first-byte alpha.
        let bitmapInfo: UInt32 =
            CGBitmapInfo.byteOrder32Little.rawValue |
            CGImageAlphaInfo.premultipliedFirst.rawValue

        guard let ctx = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            NSLog("applySegmentationToThumbnail: CGContext init failed")
            return nil
        }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // --- Segment ---
        let segmenter = PersonSegmenter(width: width, height: height)
        guard let maskPtr = segmenter.generateMaskOneShot(for: pixelBuffer) else {
            // No person / error — just return original, caller falls through.
            return nil
        }

        // --- Two-zone blend (matches the video pipeline in `applyMaskedDim`).
        // Soften the mask with a 5x5 tent convolution so the body/background
        // boundary isn't a hard cutout, then lerp each colour channel between
        // a dimmed copy of the source pixel (background) and the source pixel
        // itself (body). dim(v) = 255 - (255 - v) * 0.35 keeps white paper
        // white and drops black lines to ~90 (dark-grey ghost).
        let maskByteCount = width * height
        let blurredMaskData = UnsafeMutableRawPointer.allocate(byteCount: maskByteCount, alignment: 16)
        defer { blurredMaskData.deallocate() }

        var srcMaskBuffer = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: maskPtr),
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: width
        )
        var blurredMaskBuffer = vImage_Buffer(
            data: blurredMaskData,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: width
        )
        let tentErr = vImageTentConvolve_Planar8(
            &srcMaskBuffer,
            &blurredMaskBuffer,
            nil,
            0, 0,
            5, 5,
            0,
            vImage_Flags(kvImageEdgeExtend)
        )
        let softMaskPtr: UnsafePointer<UInt8>
        if tentErr == kvImageNoError {
            softMaskPtr = UnsafePointer(blurredMaskData.assumingMemoryBound(to: UInt8.self))
        } else {
            softMaskPtr = maskPtr
        }

        let dstPtr = base.assumingMemoryBound(to: UInt8.self)

        if grayscale {
            // Practitioner-thumbnail path: recolour every pixel to its
            // BT.601 luminance. We keep the segmentation run (for the
            // crop-to-person bounding box below) but skip the two-zone
            // body/background blend entirely. Using integer arithmetic
            // with the canonical coefficients ×1000 keeps us away from
            // floating point inside the inner loop.
            //
            //     Y = 0.299·R + 0.587·G + 0.114·B
            //
            // BGRA layout: B at +0, G at +1, R at +2, A at +3.
            for y in 0..<height {
                let rowStart = y * bytesPerRow
                for x in 0..<width {
                    let p = rowStart + x * 4
                    let b = Int(dstPtr[p + 0])
                    let g = Int(dstPtr[p + 1])
                    let r = Int(dstPtr[p + 2])
                    let y8 = (r * 299 + g * 587 + b * 114 + 500) / 1000
                    let luma = UInt8(max(0, min(255, y8)))
                    dstPtr[p + 0] = luma
                    dstPtr[p + 1] = luma
                    dstPtr[p + 2] = luma
                    // Alpha at p+3 left at source.
                }
            }
        } else {
            // Precompute the dim LUT once.
            var dimLUT = [UInt8](repeating: 0, count: 256)
            for v in 0...255 {
                let dimmed = 255.0 - (255.0 - Double(v)) * 0.35
                dimLUT[v] = UInt8(max(0, min(255, Int(dimmed.rounded()))))
            }

            dimLUT.withUnsafeBufferPointer { lutBuf in
                guard let lut = lutBuf.baseAddress else { return }
                for y in 0..<height {
                    let rowStart = y * bytesPerRow
                    let maskRowStart = y * width
                    for x in 0..<width {
                        let w = Int(softMaskPtr[maskRowStart + x])
                        let inv = 255 - w
                        let p = rowStart + x * 4
                        // B, G, R are blended; A is left at source.
                        for c in 0..<3 {
                            let src = Int(dstPtr[p + c])
                            let dim = Int(lut[src])
                            let blended = (dim * inv + src * w + 127) / 255
                            dstPtr[p + c] = UInt8(blended)
                        }
                    }
                }
            }
        }

        guard let finalImage = ctx.makeImage() else {
            return nil
        }

        // Wave Lobby — auto-pick centroid. Single pass over the soft
        // mask, accumulating intensity-weighted column / row sums plus
        // the bbox we also need for `cropToPerson`. The free axis
        // (portrait → Y, landscape → X) is decided here against the
        // CGImage's own dimensions; AVAssetImageGenerator has already
        // applied the preferred track transform so the CGImage matches
        // the displayed orientation, which is what `hero_resolver.js`
        // and `hero_crop_viewport.dart` both think in.
        //
        // Centroid math: sum(value · position) / sum(value), only
        // counting pixels above an 8-bit threshold (32) so background
        // noise doesn't bias the centre. Result is then normalised
        // against the free-axis length, clamped to [0,1].
        //
        // We deliberately do this in the same physical loop as the
        // bbox scan — `cropToPerson` is OFTEN false (the post-
        // conversion B&W extract from `conversion_service.dart` calls
        // with autoPick=true → cropToPerson=true, but the regen path
        // and the AppDelegate.extractFrame autoPick=false path both
        // skip the crop). Even when cropToPerson is false, the
        // centroid is the cheap part of the scan and we want it on
        // every regen. Cost: O(W·H) integer adds; sub-ms on a 720p
        // frame.
        let bboxThreshold: UInt8 = 128
        let centroidThreshold: UInt8 = 32
        var minX = width, minY = height, maxX = -1, maxY = -1
        var weightSum: UInt64 = 0
        var weightedX: UInt64 = 0
        var weightedY: UInt64 = 0
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                let v = softMaskPtr[row + x]
                if v >= bboxThreshold {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
                if v >= centroidThreshold {
                    let w = UInt64(v)
                    weightSum &+= w
                    weightedX &+= w &* UInt64(x)
                    weightedY &+= w &* UInt64(y)
                }
            }
        }

        // Decide the free axis from the CGImage's own dimensions.
        // Square sources (within 1px) have no meaningful free axis;
        // we leave centroidOffset nil and consumers default to 0.5.
        var centroidOffset: Double? = nil
        if weightSum > 0 && abs(width - height) >= 1 {
            // CGImage Y increases DOWNWARD — same convention the
            // resolver uses (`heroCropOffset=0` = top-aligned), so the
            // raw normalised centroid is the value we want without a
            // flip.
            if height > width {
                // Portrait — free axis is Y. Normalise by height.
                let cy = Double(weightedY) / Double(weightSum)
                centroidOffset = cy / Double(height)
            } else {
                // Landscape — free axis is X. Normalise by width.
                let cx = Double(weightedX) / Double(weightSum)
                centroidOffset = cx / Double(width)
            }
            // Defensive clamp — should already be in [0,1] from the
            // weighting math, but guards against any pathological
            // weighting edge case.
            if let v = centroidOffset {
                if !v.isFinite {
                    centroidOffset = nil
                } else if v < 0 {
                    centroidOffset = 0
                } else if v > 1 {
                    centroidOffset = 1
                }
            }
        }

        // Optional person-centred crop. We compute the bounding box of
        // mask pixels above a mid-threshold (128) and pad by ~10% before
        // cropping. If the bbox is degenerate (no person detected, or
        // covers ~the whole frame already) we return the un-cropped image.
        if cropToPerson {
            let hasBox = maxX > minX && maxY > minY
            if hasBox {
                let bboxW = maxX - minX + 1
                let bboxH = maxY - minY + 1
                // Require the bbox to cover less than ~90% of the frame
                // in both dimensions — otherwise a crop is a no-op and
                // we'd just lose precision by round-tripping.
                let tightEnough = bboxW < Int(Double(width) * 0.9) ||
                                  bboxH < Int(Double(height) * 0.9)
                if tightEnough {
                    // 10% pad on each side EXCEPT top — Vision's mask often
                    // gives the face/hair lower confidence than torso pixels
                    // (motion blur, side-light, hair-on-bright-bg), so the
                    // bbox stops at the neck and the 10% pad isn't enough
                    // to recover. cropMinY uses padTop (25%) instead, so
                    // an under-segmented head still lands inside the crop.
                    // CGImage Y increases DOWNWARD — smaller y = closer to
                    // the top of the rendered image, hence decreasing
                    // cropMinY extends the crop UPWARD.
                    let padX = Int(Double(bboxW) * 0.10)
                    let padY = Int(Double(bboxH) * 0.10)
                    let padTop = Int(Double(bboxH) * 0.25)
                    let cropMinX = max(0, minX - padX)
                    let cropMinY = max(0, minY - padTop)
                    let cropMaxX = min(width - 1, maxX + padX)
                    let cropMaxY = min(height - 1, maxY + padY)
                    let cropW = cropMaxX - cropMinX + 1
                    let cropH = cropMaxY - cropMinY + 1
                    let cropRect = CGRect(
                        x: cropMinX,
                        y: cropMinY,
                        width: cropW,
                        height: cropH
                    )
                    if let cropped = finalImage.cropping(to: cropRect) {
                        // Centroid was computed against the
                        // PRE-CROP frame, which is the orientation the
                        // resolver expects (the bbox crop is for the
                        // SMALL practitioner-facing thumbnail, not the
                        // lobby render — the lobby reads the raw
                        // mp4 / line / colour JPG, which is uncropped).
                        return SegmentedThumbnailResult(
                            image: cropped,
                            centroidOffset: centroidOffset
                        )
                    }
                }
            }
        }

        return SegmentedThumbnailResult(
            image: finalImage,
            centroidOffset: centroidOffset
        )
    }

    // MARK: - Photo Safe Mode

    /// Outcome of `applySafeModeV2ToPhoto`. `success(processed,
    /// missRate, lowConfidence)` mirrors the v1 photo payload so the
    /// Dart side's `kSafeModeMaxMissRate` decision stays unchanged.
    /// In v2:
    ///   - `processed` is 0 or 1 (always 1 unless the pipeline fell
    ///     through to byte-copy fallback).
    ///   - `missRate` is 0.0 when a subject face was identified above
    ///     threshold OR when no faces were detected at all (the
    ///     solo-back-view case is intentional); 1.0 only when Vision
    ///     itself threw and we wrote source bytes verbatim.
    ///   - `lowConfidence` is true when faces were detected but none
    ///     matched the subject embedding above threshold — signals
    ///     "subject not in frame, fell through to no-subject mode".
    /// Failure carries a string so the channel layer can route it as
    /// a FlutterError.
    enum SafeModePhotoOutcome {
        case success(processed: Int, missRate: Double, lowConfidence: Bool)
        case failure(String)
    }

    // MARK: - Safe Mode v2 — face-recognition discriminator
    //
    // Replaces the v1 anchor-box approach (`applySafeModeToPhoto`, removed
    // in this wave). The contract is per
    // `docs/specs/2026-05-23-safe-mode-face-rec.md` with the multi-reference
    // update `docs/specs/2026-05-24-safe-mode-v2-multi-reference-enrolment.md`:
    //
    //   1. `generateFaceEmbeddingFromJpg(srcPath:)` — DEPRECATED, kept
    //      for one release cycle of back-compat. Produces a single
    //      2048-byte MobileFaceNet embedding from a single avatar JPG.
    //   2. `generateFaceEmbeddingsFromFrames(framePaths:expectedSlotCount:)`
    //      — current enrolment path. Takes the 5-8 captured sweep frames
    //      and returns an array of 2048-byte embeddings spanning the
    //      subject's pose space, plus the index of the most-frontal slot
    //      (used as the avatar JPG source).
    //   3. `applySafeModeV2ToPhoto(srcPath:destPath:subjectEmbeddings:threshold:)`
    //      — called at capture time. Identifies the subject face by
    //      taking the MAX cosine similarity over every embedding in
    //      `subjectEmbeddings`; blurs every other face's head-expanded
    //      region + (in subject identified mode) every non-subject
    //      silhouette.
    //
    // The v1 code path (`SafeModeProcessor.processFrame` invoked via the
    // old anchor-box pipeline) is still used by the VIDEO writer pump
    // for backwards compat — gated by `kSafeModeVideoEnabled` for v2,
    // which the Dart side flips off so video capture is forbidden
    // inside a Safe Mode polygon (v3 will re-enable with keyframe-embed
    // + tracking).

    /// Outcome of `generateFaceEmbeddingFromJpg`. The channel layer
    /// maps each case to a structured FlutterError so the Dart side
    /// can surface a clear UX message instead of a generic failure.
    enum FaceEmbeddingOutcome {
        case success(Data)
        case noFace
        case multipleAmbiguous(ratio: Double)
        case fileMissing
        case failure(String)
    }

    /// Generate the MobileFaceNet embedding for the supplied JPG.
    ///
    /// DEPRECATED (2026-05-24) — use `generateFaceEmbeddingsFromFrames`
    /// instead. Kept for one release cycle of back-compat with the
    /// legacy single-avatar enrolment path; Dart callers that still
    /// invoke `generateFaceEmbedding` (singular) continue to work, and
    /// the resulting Data can be wrapped in a one-element list before
    /// being passed to `applySafeModeV2ToPhoto`. Removed in a follow-up
    /// wave once all enrolment paths route through the multi-frame
    /// method.
    ///
    /// Pipeline:
    ///   1. Load the JPG via UIImage; pre-render upright via
    ///      `UIGraphicsImageRenderer` (same EXIF-respecting technique
    ///      as the photo Safe Mode path) so Vision sees pixels in the
    ///      human-up orientation.
    ///   2. Run `VNDetectFaceRectanglesRequest` with `orientation: .up`.
    ///   3. If zero faces: return `.noFace` (the channel handler maps
    ///      to a FlutterError with code "NO_FACE_DETECTED").
    ///   4. If multiple faces with the two largest within 80% area
    ///      ratio: return `.multipleAmbiguous(ratio:)` so the UI can
    ///      prompt the practitioner to pick a clearer avatar.
    ///   5. Otherwise: crop the largest face's bbox with a 20% pad on
    ///      every side, pass the CGImage to `MobileFaceNetEmbedder`,
    ///      return the resulting 2048-byte Data.
    @available(iOS 15.0, *)
    static func generateFaceEmbeddingFromJpg(srcPath: String) -> FaceEmbeddingOutcome {
        guard FileManager.default.fileExists(atPath: srcPath) else {
            return .fileMissing
        }
        guard let uiImage = UIImage(contentsOfFile: srcPath),
              let cgImage = uiImage.cgImage else {
            return .failure("Could not decode JPG at \(srcPath)")
        }

        // Pre-render upright. Re-uses the technique pioneered by PR #430
        // for the photo Safe Mode path: the UIGraphicsImageRenderer +
        // `uiImage.draw(in:)` combo applies EXIF orientation
        // automatically, yielding a top-left-origin buffer that Vision
        // can interpret with `orientation: .up`.
        let displayW: Int
        let displayH: Int
        switch uiImage.imageOrientation {
        case .left, .right, .leftMirrored, .rightMirrored:
            displayW = cgImage.height
            displayH = cgImage.width
        default:
            displayW = cgImage.width
            displayH = cgImage.height
        }
        // Clamp to 1920px max-dim (same as the photo Safe Mode path):
        // the embedding only needs a 112×112 crop, so we don't need
        // the full 12MP. Smaller buffer = faster Vision pass.
        let maxWorkDim = 1920
        let displayMax = max(displayW, displayH)
        let workScale = min(1.0, Double(maxWorkDim) / Double(displayMax))
        let width = max(1, Int((Double(displayW) * workScale).rounded()))
        let height = max(1, Int((Double(displayH) * workScale).rounded()))

        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1.0
        fmt.opaque = true
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height),
            format: fmt
        )
        let uprightUI = renderer.image { _ in
            uiImage.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        guard let uprightCG = uprightUI.cgImage else {
            return .failure("UIGraphicsImageRenderer produced no cgImage")
        }

        // Run VNDetectFaceRectanglesRequest. Use VNImageRequestHandler
        // since this is a single-frame path.
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(
            cgImage: uprightCG,
            orientation: .up,
            options: [:]
        )
        do {
            try handler.perform([request])
        } catch {
            return .failure("Vision face detect failed: \(error.localizedDescription)")
        }
        let observations = request.results ?? []
        if observations.isEmpty {
            return .noFace
        }

        // Sort faces by area, descending. Pick the largest as subject.
        // If the second-largest is >= 80% of the largest, we don't know
        // which face is the practitioner's intended client avatar —
        // refuse and prompt to recapture.
        var areas: [(rect: CGRect, area: CGFloat)] = observations.map {
            ($0.boundingBox, $0.boundingBox.width * $0.boundingBox.height)
        }
        areas.sort { $0.area > $1.area }
        if areas.count >= 2 {
            let ratio = areas[1].area / areas[0].area
            if ratio >= 0.80 {
                return .multipleAmbiguous(ratio: Double(ratio))
            }
        }
        let faceRect = areas[0].rect

        // Crop face bbox with 20% pad. Vision rects are normalized in
        // origin-bottom-left coords; convert to top-left pixel coords
        // for CGImage.cropping.
        let padFactor: CGFloat = 0.20
        let padW = faceRect.width * padFactor
        let padH = faceRect.height * padFactor
        let cropX0 = max(0, (faceRect.origin.x - padW)) * CGFloat(width)
        let cropY0Bottom = max(0, (faceRect.origin.y - padH)) * CGFloat(height)
        let cropW = min(1.0, faceRect.width + 2 * padW) * CGFloat(width)
        let cropH = min(1.0, faceRect.height + 2 * padH) * CGFloat(height)
        // Flip Y for top-left pixel grid.
        let cropY0Top = CGFloat(height) - cropY0Bottom - cropH
        let pixelCropRect = CGRect(
            x: cropX0.rounded(.down),
            y: max(0, cropY0Top.rounded(.down)),
            width: cropW.rounded(.up),
            height: cropH.rounded(.up)
        )
        guard let faceCrop = uprightCG.cropping(to: pixelCropRect) else {
            return .failure("CGImage cropping returned nil for rect \(pixelCropRect)")
        }

        // Hand to MobileFaceNet. Hard-fail per
        // feedback_no_silent_fallbacks — never return a zero / random
        // embedding when the model fails.
        do {
            let blob = try MobileFaceNetEmbedder.shared.embed(face: faceCrop)
            return .success(blob)
        } catch let err as MobileFaceNetEmbedderError {
            switch err {
            case .modelNotBundled:
                return .failure("MobileFaceNet.mlmodel not found in app bundle")
            case .modelLoadFailed(let msg):
                return .failure("MobileFaceNet load failed: \(msg)")
            case .preprocessingFailed(let msg):
                return .failure("MobileFaceNet preprocessing failed: \(msg)")
            case .inferenceFailed(let msg):
                return .failure("MobileFaceNet inference failed: \(msg)")
            case .outputShapeMismatch(let msg):
                return .failure("MobileFaceNet output shape mismatch: \(msg)")
            }
        } catch {
            return .failure("MobileFaceNet unknown error: \(error.localizedDescription)")
        }
    }

    // MARK: - Safe Mode v2 multi-reference enrolment (2026-05-24)

    /// Outcome of `generateFaceEmbeddingsFromFrames`. The channel handler
    /// maps each case to a structured FlutterError so the Dart side can
    /// surface a clear UX message instead of a generic failure.
    enum FaceEmbeddingsOutcome {
        case success(embeddings: [Data], frontalPickIndex: Int, posesYaw: [Double], posesPitch: [Double])
        case notEnoughFrames(accepted: Int, needed: Int)
        case failure(String)
    }

    /// Multi-reference face enrolment — produce 1 embedding per "slot"
    /// from a set of captured frames covering the subject's pose space.
    ///
    /// Pipeline (per
    /// `docs/specs/2026-05-24-safe-mode-v2-multi-reference-enrolment.md`):
    ///   1. For each `framePaths[i]`: load via UIImage, pre-render upright
    ///      (EXIF-respecting), run `VNDetectFaceLandmarksRequest`.
    ///   2. Reject frames with 0 or >1 face (sweep noise / bystander) —
    ///      they don't enter the pose-bucket pool.
    ///   3. For each accepted frame: read pose yaw + pitch (radians,
    ///      iOS 15+) from the VNFaceObservation.
    ///   4. Greedy farthest-point selection in (yaw, pitch) 2D space:
    ///      seed with the most-frontal frame (smallest |yaw| + |pitch|),
    ///      then iteratively add the frame whose (yaw, pitch) maximises
    ///      Euclidean distance to the nearest already-picked frame.
    ///      Stop at `expectedSlotCount` (caller-clamped to [3, 8]).
    ///   5. Reject the whole batch with `.notEnoughFrames` if fewer than
    ///      3 frames have a single detectable face — per
    ///      feedback_no_silent_fallbacks we refuse loudly rather than
    ///      shipping a one-slot pseudo-enrolment.
    ///   6. For each picked frame: crop the face bbox with a 20% pad
    ///      (same as the singular path), run MobileFaceNet, collect the
    ///      512-FP32 embedding.
    ///   7. Return all arrays in slot order along with the index of the
    ///      most-frontal pick (smallest |yaw| + |pitch| AMONG the slots,
    ///      which by construction equals slot 0 in the greedy seeding
    ///      above but is recomputed defensively in case of ties).
    @available(iOS 15.0, *)
    static func generateFaceEmbeddingsFromFrames(
        framePaths: [String],
        expectedSlotCount: Int
    ) -> FaceEmbeddingsOutcome {
        // ---------------------------------------------------------------
        // Defence: arguments are pre-validated by the channel handler
        // (non-empty + each file exists + slot count clamped) but we
        // re-clamp here to keep the function self-contained for the
        // bench tool / unit tests that call it directly.
        // ---------------------------------------------------------------
        let clampedSlotCount = max(3, min(8, expectedSlotCount))

        struct AcceptedFrame {
            let pathIndex: Int            // back-reference into framePaths
            let uprightCG: CGImage        // upright pixel buffer
            let width: Int
            let height: Int
            let faceRectNormalized: CGRect  // Vision normalized bbox (bottom-left)
            let yaw: Double               // radians
            let pitch: Double             // radians
        }

        var accepted: [AcceptedFrame] = []
        accepted.reserveCapacity(framePaths.count)

        for (pathIdx, path) in framePaths.enumerated() {
            guard let uiImage = UIImage(contentsOfFile: path),
                  let cgImage = uiImage.cgImage else {
                // Bad frame on disk — treat as skipped rather than aborting.
                continue
            }

            // EXIF-respecting upright pre-render, same technique as
            // generateFaceEmbeddingFromJpg + applySafeModeV2ToPhoto.
            let displayW: Int
            let displayH: Int
            switch uiImage.imageOrientation {
            case .left, .right, .leftMirrored, .rightMirrored:
                displayW = cgImage.height
                displayH = cgImage.width
            default:
                displayW = cgImage.width
                displayH = cgImage.height
            }
            let maxWorkDim = 1920
            let displayMax = max(displayW, displayH)
            let workScale = min(1.0, Double(maxWorkDim) / Double(displayMax))
            let width = max(1, Int((Double(displayW) * workScale).rounded()))
            let height = max(1, Int((Double(displayH) * workScale).rounded()))

            let fmt = UIGraphicsImageRendererFormat.default()
            fmt.scale = 1.0
            fmt.opaque = true
            let renderer = UIGraphicsImageRenderer(
                size: CGSize(width: width, height: height),
                format: fmt
            )
            let uprightUI = renderer.image { _ in
                uiImage.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            guard let uprightCG = uprightUI.cgImage else { continue }

            // VNDetectFaceLandmarksRequest gives us yaw/pitch on the
            // VNFaceObservation (iOS 15+, in radians). VNDetectFaceRectanglesRequest
            // omits the pose info we need for greedy farthest-point picking.
            let request = VNDetectFaceLandmarksRequest()
            let handler = VNImageRequestHandler(
                cgImage: uprightCG,
                orientation: .up,
                options: [:]
            )
            do {
                try handler.perform([request])
            } catch {
                // One frame's Vision pass failed — skip it, continue.
                continue
            }
            let observations = request.results ?? []
            // Strictly one face: 0 = no subject visible, >1 = bystander
            // crept in. Either way the frame is dropped from the pool.
            if observations.count != 1 { continue }
            let obs = observations[0]

            // Pose: VNFaceObservation.yaw / .pitch are NSNumber on iOS 15+.
            // Default to 0.0 when nil (very rare — usually means landmarks
            // didn't lock).
            let yawRad: Double = obs.yaw?.doubleValue ?? 0.0
            let pitchRad: Double = obs.pitch?.doubleValue ?? 0.0

            accepted.append(AcceptedFrame(
                pathIndex: pathIdx,
                uprightCG: uprightCG,
                width: width,
                height: height,
                faceRectNormalized: obs.boundingBox,
                yaw: yawRad,
                pitch: pitchRad
            ))
        }

        if accepted.count < 3 {
            return .notEnoughFrames(accepted: accepted.count, needed: 3)
        }

        // -----------------------------------------------------------------
        // Greedy farthest-point selection in (yaw, pitch) 2D space.
        // Step 1: seed with the most-frontal frame (smallest |yaw|+|pitch|).
        // Step 2: while we haven't filled `clampedSlotCount`, add the
        //         remaining frame whose Euclidean distance to its NEAREST
        //         already-picked frame is largest. Stop when we run out
        //         of remaining frames.
        // -----------------------------------------------------------------
        var pickedIndices: [Int] = []
        var remainingIndices = Set(0..<accepted.count)

        var frontalSeed = 0
        var frontalScore = Double.infinity
        for i in 0..<accepted.count {
            let score = abs(accepted[i].yaw) + abs(accepted[i].pitch)
            if score < frontalScore {
                frontalScore = score
                frontalSeed = i
            }
        }
        pickedIndices.append(frontalSeed)
        remainingIndices.remove(frontalSeed)

        while pickedIndices.count < clampedSlotCount && !remainingIndices.isEmpty {
            var bestCandidate = -1
            var bestMinDist = -1.0
            for candidate in remainingIndices {
                let cy = accepted[candidate].yaw
                let cp = accepted[candidate].pitch
                var minDist = Double.infinity
                for picked in pickedIndices {
                    let dy = accepted[picked].yaw - cy
                    let dp = accepted[picked].pitch - cp
                    let d = (dy * dy + dp * dp).squareRoot()
                    if d < minDist { minDist = d }
                }
                if minDist > bestMinDist {
                    bestMinDist = minDist
                    bestCandidate = candidate
                }
            }
            if bestCandidate < 0 { break }
            pickedIndices.append(bestCandidate)
            remainingIndices.remove(bestCandidate)
        }

        // -----------------------------------------------------------------
        // Embed each picked frame's face crop. Failure of MobileFaceNet
        // is hard — fail loud per feedback_no_silent_fallbacks rather than
        // returning a partial slot set.
        // -----------------------------------------------------------------
        var embeddings: [Data] = []
        var posesYaw: [Double] = []
        var posesPitch: [Double] = []
        embeddings.reserveCapacity(pickedIndices.count)
        posesYaw.reserveCapacity(pickedIndices.count)
        posesPitch.reserveCapacity(pickedIndices.count)

        for slotIdx in pickedIndices {
            let frame = accepted[slotIdx]
            let r = frame.faceRectNormalized
            let padFactor: CGFloat = 0.20
            let padW = r.width * padFactor
            let padH = r.height * padFactor
            let cropX0 = max(0, (r.origin.x - padW)) * CGFloat(frame.width)
            let cropY0Bottom = max(0, (r.origin.y - padH)) * CGFloat(frame.height)
            let cropW = min(1.0, r.width + 2 * padW) * CGFloat(frame.width)
            let cropH = min(1.0, r.height + 2 * padH) * CGFloat(frame.height)
            // Flip Y: Vision is bottom-left, CGImage cropping is top-left.
            let cropY0Top = CGFloat(frame.height) - cropY0Bottom - cropH
            let pixelCropRect = CGRect(
                x: cropX0.rounded(.down),
                y: max(0, cropY0Top.rounded(.down)),
                width: cropW.rounded(.up),
                height: cropH.rounded(.up)
            )
            guard let faceCrop = frame.uprightCG.cropping(to: pixelCropRect) else {
                return .failure(
                    "CGImage cropping returned nil for slot \(slotIdx) rect \(pixelCropRect)"
                )
            }
            do {
                let blob = try MobileFaceNetEmbedder.shared.embed(face: faceCrop)
                embeddings.append(blob)
                posesYaw.append(frame.yaw)
                posesPitch.append(frame.pitch)
            } catch let err as MobileFaceNetEmbedderError {
                switch err {
                case .modelNotBundled:
                    return .failure("MobileFaceNet.mlmodel not found in app bundle")
                case .modelLoadFailed(let msg):
                    return .failure("MobileFaceNet load failed: \(msg)")
                case .preprocessingFailed(let msg):
                    return .failure("MobileFaceNet preprocessing failed for slot \(slotIdx): \(msg)")
                case .inferenceFailed(let msg):
                    return .failure("MobileFaceNet inference failed for slot \(slotIdx): \(msg)")
                case .outputShapeMismatch(let msg):
                    return .failure("MobileFaceNet output shape mismatch for slot \(slotIdx): \(msg)")
                }
            } catch {
                return .failure("MobileFaceNet unknown error for slot \(slotIdx): \(error.localizedDescription)")
            }
        }

        // Frontal pick = slot whose pose is closest to (0, 0). By
        // construction of the greedy seeding this is slot 0, but we
        // recompute defensively in case ties get ordered differently
        // by future tuning.
        var frontalPickIndex = 0
        var bestFrontal = Double.infinity
        for i in 0..<posesYaw.count {
            let s = abs(posesYaw[i]) + abs(posesPitch[i])
            if s < bestFrontal {
                bestFrontal = s
                frontalPickIndex = i
            }
        }

        return .success(
            embeddings: embeddings,
            frontalPickIndex: frontalPickIndex,
            posesYaw: posesYaw,
            posesPitch: posesPitch
        )
    }

    /// Apply Safe Mode v2 to a single JPG. Replaces the v1
    /// anchor-box `applySafeModeToPhoto` entirely.
    ///
    /// Pipeline (per `docs/specs/2026-05-23-safe-mode-face-rec.md`,
    /// multi-reference update
    /// `docs/specs/2026-05-24-safe-mode-v2-multi-reference-enrolment.md`):
    ///   1. Pre-render the source upright (same UIGraphics technique
    ///      as v1) and allocate a working BGRA pixel buffer at
    ///      <=1920px max-dim.
    ///   2. Run face detection on the upright buffer.
    ///   3. For every detected face: crop, embed via MobileFaceNet,
    ///      compute the MAXIMUM cosine similarity across every entry
    ///      in `subjectEmbeddings`. The face with the highest per-face
    ///      max-cosSim is the subject candidate; the hybrid pick-highest
    ///      rule (solo-floor vs multi-relative) decides whether to
    ///      accept it.
    ///   4. Run PersonSegmenter on the same buffer.
    ///   5. Subject identified mode: scanline-flood-fill the segmentation
    ///      mask from the subject face centroid to find the connected
    ///      component = subject silhouette. Build keepSourceMask:
    ///        - subject silhouette → 255 (keep sharp)
    ///        - other mask-positive pixels → 0 (blur)
    ///        - background → 255 (keep sharp)
    ///      Then paint 0s in every non-subject face's head-expanded
    ///      bbox (defensive — silhouette undershoot at the head).
    ///   6. No subject mode: keepSourceMask = all 255; paint 0s in
    ///      every detected face's head-expanded bbox. Silhouettes
    ///      stay sharp — solo back-view self-recording case.
    ///   7. CIBlendWithMask composite source vs CIGaussianBlur(source).
    ///   8. Encode to JPG at destPath.
    ///
    /// `lowConfidence` in the return payload is set when no subject
    /// face was identified above threshold but at least one face was
    /// detected — surfaces the "subject not recognised, fell through
    /// to no-subject mode" signal so the Dart side can decide whether
    /// to nudge the practitioner.
    ///
    /// Multi-reference semantics (2026-05-24): `subjectEmbeddings` is
    /// a 1–8 element array. With one element the behaviour is identical
    /// to the original single-reference signature (back-compat for the
    /// legacy single-avatar callers). With multiple elements the
    /// per-face cosSim is taken as the MAX across all references —
    /// catches subjects at off-frontal angles whose own forward
    /// embedding scores poorly but whose three-quarter or profile
    /// reference matches well.
    @available(iOS 15.0, *)
    static func applySafeModeV2ToPhoto(
        srcPath: String,
        destPath: String,
        subjectEmbeddings: [Data],
        threshold: Double
    ) -> SafeModePhotoOutcome {
        guard FileManager.default.fileExists(atPath: srcPath) else {
            return .failure("Source photo not found: \(srcPath)")
        }
        guard let uiImage = UIImage(contentsOfFile: srcPath),
              let cgImage = uiImage.cgImage else {
            return .failure("Could not decode source photo: \(srcPath)")
        }
        guard !subjectEmbeddings.isEmpty else {
            return .failure("subjectEmbeddings must contain at least one embedding")
        }
        guard subjectEmbeddings.count <= 8 else {
            return .failure(
                "subjectEmbeddings must contain at most 8 embeddings — got \(subjectEmbeddings.count)"
            )
        }
        for (idx, emb) in subjectEmbeddings.enumerated() {
            if emb.count != MobileFaceNetEmbedder.embeddingByteLength {
                return .failure(
                    "subjectEmbeddings[\(idx)] wrong size — got \(emb.count) bytes, " +
                    "expected \(MobileFaceNetEmbedder.embeddingByteLength)"
                )
            }
        }

        // --- Upright pre-render at <=1920px max-dim (same as v1) ---
        let nativeCgW = cgImage.width
        let nativeCgH = cgImage.height
        guard nativeCgW > 0, nativeCgH > 0 else {
            return .failure("Source photo has zero dimensions")
        }
        let displayW: Int
        let displayH: Int
        switch uiImage.imageOrientation {
        case .left, .right, .leftMirrored, .rightMirrored:
            displayW = nativeCgH
            displayH = nativeCgW
        default:
            displayW = nativeCgW
            displayH = nativeCgH
        }
        let maxWorkDim = 1920
        let displayMax = max(displayW, displayH)
        let workScale = min(1.0, Double(maxWorkDim) / Double(displayMax))
        let width = max(1, Int((Double(displayW) * workScale).rounded()))
        let height = max(1, Int((Double(displayH) * workScale).rounded()))

        let renderFormat = UIGraphicsImageRendererFormat.default()
        renderFormat.scale = 1.0
        renderFormat.opaque = true
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height),
            format: renderFormat
        )
        let uprightUIImage = renderer.image { _ in
            uiImage.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        guard let uprightCG = uprightUIImage.cgImage else {
            return .failure("UIGraphicsImageRenderer produced no cgImage")
        }

        // --- Allocate source + dest BGRA pixel buffers ---
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        var srcBufOut: CVPixelBuffer?
        let srcStatus = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &srcBufOut
        )
        guard srcStatus == kCVReturnSuccess, let srcBuf = srcBufOut else {
            return .failure("CVPixelBufferCreate(src) status=\(srcStatus)")
        }
        CVPixelBufferLockBaseAddress(srcBuf, [])
        guard let srcBase = CVPixelBufferGetBaseAddress(srcBuf) else {
            CVPixelBufferUnlockBaseAddress(srcBuf, [])
            return .failure("CVPixelBufferGetBaseAddress(src)")
        }
        let srcRowBytes = CVPixelBufferGetBytesPerRow(srcBuf)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 =
            CGBitmapInfo.byteOrder32Little.rawValue |
            CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let srcCtx = CGContext(
            data: srcBase, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: srcRowBytes,
            space: colorSpace, bitmapInfo: bitmapInfo
        ) else {
            CVPixelBufferUnlockBaseAddress(srcBuf, [])
            return .failure("CGContext init (src)")
        }
        srcCtx.draw(uprightCG, in: CGRect(x: 0, y: 0, width: width, height: height))
        CVPixelBufferUnlockBaseAddress(srcBuf, [])

        var dstBufOut: CVPixelBuffer?
        let dstStatus = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &dstBufOut
        )
        guard dstStatus == kCVReturnSuccess, let dstBuf = dstBufOut else {
            return .failure("CVPixelBufferCreate(dst) status=\(dstStatus)")
        }

        // --- Face detection + landmarks ---
        // Switched from VNDetectFaceRectanglesRequest to
        // VNDetectFaceLandmarksRequest so we get the face contour polygon
        // alongside the boundingBox — used by the head-oval painter
        // below (replaces the rectangular bbox sweep that visibly
        // painted background pixels coral).
        let faceReq = VNDetectFaceLandmarksRequest()
        let visionHandler = VNImageRequestHandler(
            cgImage: uprightCG, orientation: .up, options: [:]
        )
        do {
            try visionHandler.perform([faceReq])
        } catch {
            // Vision threw — fall through to "no faces" path. We still
            // need to encode SOMETHING to destPath so the caller has a
            // file to look at; we'll write the source bytes verbatim
            // and report missRate=1.0.
            return encodeSourceAsFallback(
                srcBuf: srcBuf,
                dstBuf: dstBuf,
                width: width,
                height: height,
                colorSpace: colorSpace,
                bitmapInfo: bitmapInfo,
                scale: uiImage.scale,
                destPath: destPath,
                missRate: 1.0,
                lowConfidence: true,
                failReason: "Vision face detect threw: \(error.localizedDescription)"
            )
        }
        let observations = faceReq.results ?? []

        // --- Embed every face + compute cos similarity ---
        struct DetectedFace {
            let normalizedRect: CGRect       // Vision normalized, bottom-left origin
            let pixelRectTopLeft: CGRect     // Top-left origin, in upright pixel coords
            let centerXPx: Int
            let centerYPx: Int
            let cosSim: Double               // MAX across all entries in subjectEmbeddings
            /// Face-contour polygon in upright pixel coords (top-left origin).
            /// nil when Vision returned no landmarks for this face (rare) — the
            /// painter falls back to bbox-only in that case.
            let contourPolygonPx: [CGPoint]?
        }

        // Helper: convert a Vision normalized rect to a top-left
        // pixel rect, then expand by `pad` factor for the crop.
        func toPixelTopLeft(_ r: CGRect, pad: CGFloat = 0.20) -> CGRect {
            let padW = r.width * pad
            let padH = r.height * pad
            let nx0 = max(0, r.origin.x - padW)
            let ny0Bot = max(0, r.origin.y - padH)
            let nw = min(1.0, r.width + 2 * padW)
            let nh = min(1.0, r.height + 2 * padH)
            let px0 = nx0 * CGFloat(width)
            let py0Top = CGFloat(height) - (ny0Bot + nh) * CGFloat(height)
            let pw = nw * CGFloat(width)
            let ph = nh * CGFloat(height)
            return CGRect(
                x: max(0, px0).rounded(.down),
                y: max(0, py0Top).rounded(.down),
                width: pw.rounded(.up),
                height: ph.rounded(.up)
            )
        }

        var faces: [DetectedFace] = []
        for obs in observations {
            let r = obs.boundingBox
            let pixelRect = toPixelTopLeft(r, pad: 0.20)
            // Skip degenerate rects.
            if pixelRect.width < 8 || pixelRect.height < 8 { continue }
            guard let crop = uprightCG.cropping(to: pixelRect) else { continue }
            var sim: Double = -1.0
            do {
                let embed = try MobileFaceNetEmbedder.shared.embed(face: crop)
                // Multi-reference: take the MAX cosSim across all
                // enrolled reference embeddings for this client. Any
                // single matching reference suffices to claim the face;
                // a profile face only needs to score against the profile
                // reference, not the frontal one.
                var bestRefSim: Double = -2.0
                for ref in subjectEmbeddings {
                    let s = MobileFaceNetEmbedder.cosineSimilarity(embed, ref)
                    if s > bestRefSim { bestRefSim = s }
                }
                sim = bestRefSim
            } catch {
                // One face's embed failed — don't kill the whole pass.
                // Treat as no-match (low cos), continue with the others.
                NSLog("[SafeMode v2] face embed failed for one bbox: \(error.localizedDescription)")
                sim = -1.0
            }
            let cxNormBot = r.origin.x + r.width * 0.5
            let cyNormBot = r.origin.y + r.height * 0.5
            let cxPx = Int((cxNormBot * CGFloat(width)).rounded())
            let cyPx = Int(((1.0 - cyNormBot) * CGFloat(height)).rounded())
            let contourPolygon = faceContourPolygonPx(
                observation: obs,
                imageWidth: width,
                imageHeight: height,
                outwardExpansionFactor: 1.25
            )
            faces.append(DetectedFace(
                normalizedRect: r,
                pixelRectTopLeft: pixelRect,
                centerXPx: max(0, min(width - 1, cxPx)),
                centerYPx: max(0, min(height - 1, cyPx)),
                cosSim: sim,
                contourPolygonPx: contourPolygon
            ))
        }

        // --- Pick subject by max cosine similarity ---
        //
        // Hybrid pick-highest rule (2026-05-24 workshop):
        //   0 faces → no-subject mode (defensive sharp; existing behaviour
        //             with missRate=1.0 reported)
        //   1 face  → solo branch. Trust practitioner intent UNLESS cosSim
        //             is suspiciously low. The `threshold` argument is now
        //             interpreted as the solo-floor (typical default 0.10)
        //             — well below any legitimate same-person cosSim
        //             (Carl's worst was 0.25) but above the typical
        //             bystander cosSim (random faces cluster 0.15-0.40).
        //             This catches the bystander-alone-no-client edge
        //             case without rejecting legitimate solo selfies at
        //             sideways angles.
        //   2+ faces → relative pick. The highest-scoring face IS the
        //              subject; all others get coral-painted. No absolute
        //              threshold gate — even if both faces have low cosSim,
        //              one of them is closer to the enrolled embedding and
        //              that one wins.
        //
        // Replaces the old absolute-threshold gate (every face had to
        // clear `kSafeModeV2FaceMatchThreshold = 0.5` or the frame fell
        // into no-subject mode). The old gate failed for legitimate
        // poses (sideways looks, gym situations).
        var subjectIdx: Int? = nil
        var bestSim = -2.0
        for (i, f) in faces.enumerated() {
            if f.cosSim > bestSim {
                bestSim = f.cosSim
                subjectIdx = i
            }
        }

        let subjectIdentified: Bool
        let branchReason: String
        if faces.isEmpty {
            subjectIdentified = false
            branchReason = "no-faces"
        } else if faces.count == 1 {
            // Solo face: trust practitioner intent unless cosSim is
            // suspiciously low. `threshold` here is the solo-floor.
            subjectIdentified = (bestSim >= threshold)
            branchReason = "solo-floor"
        } else {
            // 2+ faces: relative pick — highest cosSim wins. No
            // absolute gate.
            subjectIdentified = true
            branchReason = "multi-relative"
        }

        // Diagnostics 2026-05-24: switched from bare NSLog to os_log with
        // %{public} format specifiers so cosSim / threshold / bestSim
        // values are readable in Console.app on profile builds (bare
        // %d / %.3f are masked to <private> by default).
        for (i, f) in faces.enumerated() {
            os_log(
                "[SafeMode v2] face[%{public}d] cosSim=%{public}.3f",
                log: safeModeLog,
                type: .info,
                i, f.cosSim
            )
        }
        os_log(
            "[SafeMode v2] refs=%{public}d faces=%{public}d soloFloor=%{public}.2f bestSim=%{public}.3f subjectIdentified=%{public}@ branch=%{public}@",
            log: safeModeLog,
            type: .info,
            subjectEmbeddings.count, faces.count, threshold, bestSim,
            subjectIdentified ? "true" : "false",
            branchReason
        )

        // --- Run PersonSegmenter on the upright buffer ---
        let segmenter = PersonSegmenter(width: width, height: height)
        let maskPtr = segmenter.generateMaskOneShot(for: srcBuf)

        // --- Build the keepSourceMask ---
        // Allocate fresh per call; small enough to not worry about pooling.
        let totalPx = width * height
        let keepMask = UnsafeMutablePointer<UInt8>.allocate(capacity: totalPx)
        defer {
            keepMask.deinitialize(count: totalPx)
            keepMask.deallocate()
        }
        // Default fill: all 255 (keep source).
        keepMask.initialize(repeating: 255, count: totalPx)

        if subjectIdentified, let subjI = subjectIdx, let mask = maskPtr {
            // Flood-fill from the subject face center to find the
            // connected component in the binary segmentation mask.
            // This component = subject silhouette. We mark its pixels
            // in `subjectComponent` (a parallel bitmap). All OTHER
            // mask-positive pixels become blur targets.
            let subject = faces[subjI]
            let subjectComponent = floodFillBinary(
                mask: mask,
                width: width,
                height: height,
                seedX: subject.centerXPx,
                seedY: subject.centerYPx,
                threshold: 128
            )
            defer {
                subjectComponent.deinitialize(count: totalPx)
                subjectComponent.deallocate()
            }

            // For every pixel that is mask-positive (>= 128) AND NOT in
            // the subject component → keep blurred (0). Subject pixels
            // and background pixels stay at 255 (already default).
            for y in 0..<height {
                let rowOffset = y * width
                for x in 0..<width {
                    let i = rowOffset + x
                    if mask[i] >= 128 && subjectComponent[i] == 0 {
                        keepMask[i] = 0
                    }
                }
            }

            // Defensive: paint 0s into every NON-subject face's
            // head region so a silhouette that undershot the chin/hair
            // still gets its face blurred. Painter intersects with the
            // segmentation mask AND excludes subject pixels, so a
            // bystander standing in front of the subject no longer
            // erases the subject's body behind them.
            for (i, f) in faces.enumerated() where i != subjI {
                paintHeadExpansion(
                    keepMask: keepMask,
                    width: width,
                    height: height,
                    pixelRect: f.pixelRectTopLeft,
                    contourPolygonPx: f.contourPolygonPx,
                    headWidthFactor: 2.0,
                    headHeightFactor: 1.5,
                    maxAreaFraction: 0.35,
                    segmentationMask: mask,
                    subjectComponent: subjectComponent
                )
            }
        } else {
            // No-subject mode: every detected face head region gets
            // painted, but still intersected with the segmentation mask
            // so we don't paint pure background pixels coral. Subject
            // component is nil — nothing to protect.
            for f in faces {
                paintHeadExpansion(
                    keepMask: keepMask,
                    width: width,
                    height: height,
                    pixelRect: f.pixelRectTopLeft,
                    contourPolygonPx: f.contourPolygonPx,
                    headWidthFactor: 2.0,
                    headHeightFactor: 1.5,
                    maxAreaFraction: 0.35,
                    segmentationMask: maskPtr,
                    subjectComponent: nil
                )
            }
        }

        // --- Composite via CIBlendWithMask ---
        // Blur radius scales with frame dim — same convention as the
        // v1 SafeModeProcessor (35.0 at 1080p).
        let minDim = Double(min(width, height))
        let blurRadius = 35.0 * max(0.25, minDim / 1080.0)

        // Disable Core Image colour management — we work in device-RGB
        // throughout the pipeline. Mirrors the v1 SafeModeProcessor init
        // (see `class SafeModeProcessor` in this file). Without these
        // NSNull options the default CIContext working colorspace is
        // `extendedLinearSRGB` (linear-light) and `colorSpace: nil` on
        // the render call below means "do not color-match the output";
        // CoreImage then writes LINEAR bytes into a buffer the JPG
        // encoder interprets as gamma-encoded sRGB, producing a ~2x
        // perceptual darkening of every safe-mode photo (mean luma drops
        // ~37%). Confirmed via `tools/safe-mode-v2-bench` 2026-05-25
        // against a TP2 iPhone 17 Pro capture: source luma 127.75,
        // post-render 79.88 with the bare CIContext, 132.60 once the
        // NSNull block was reinstated. PR #475 removed these options to
        // fix Brief 1's whole-frame blur (which was actually caused by
        // the simultaneous removal of the DeviceGray maskCI colorspace
        // + the 10px feather, both of which PR #475 also reverted). The
        // mask + feather reverts were correct; the CIContext options
        // revert was a side-effect that introduced the darkening bug
        // Carl reported during staging QA. Keep the DeviceGray maskCI
        // and the no-feather mask below; only re-introduce the NSNull
        // CIContext options.
        let ciContextOptions: [CIContextOption: Any] = [
            .workingColorSpace: NSNull(),
            .outputColorSpace: NSNull(),
        ]
        let ciContext: CIContext
        if let device = MTLCreateSystemDefaultDevice() {
            ciContext = CIContext(mtlDevice: device, options: ciContextOptions)
        } else {
            ciContext = CIContext(options: ciContextOptions)
        }
        guard let blurFilter = CIFilter(name: "CIGaussianBlur"),
              let blendFilter = CIFilter(name: "CIBlendWithMask") else {
            return .failure("CIFilter init failed (CIGaussianBlur / CIBlendWithMask)")
        }

        let sourceCI = CIImage(cvPixelBuffer: srcBuf)
        blurFilter.setValue(sourceCI, forKey: kCIInputImageKey)
        blurFilter.setValue(blurRadius, forKey: kCIInputRadiusKey)
        guard let rawBlur = blurFilter.outputImage else {
            return .failure("CIGaussianBlur produced no output")
        }
        let blurredCI = rawBlur.cropped(to: sourceCI.extent)

        // Wrap the keepMask as a CIImage (R8 luminance). The
        // `CIImage(bitmapData:bytesPerRow:size:format:colorSpace:)`
        // initializer is non-failing; CoreImage takes a defensive copy
        // of the data, so the maskBytes buffer lifetime here is fine.
        // `colorSpace: nil` keeps CoreImage from re-interpreting the
        // DeviceGray colorspace on the mask — gives CIBlendWithMask a
        // clear luminance interpretation. The `colorSpace: nil` variant
        // (set briefly by Brief 1 2026-05-24) interacted badly with the
        // CIBlendWithMask compositor and produced whole-frame blur on
        // any frame where the mask had a non-trivial structure.
        let maskBytes = Data(bytes: keepMask, count: totalPx)
        let maskCI = CIImage(
            bitmapData: maskBytes,
            bytesPerRow: width,
            size: CGSize(width: width, height: height),
            format: .R8,
            colorSpace: CGColorSpaceCreateDeviceGray()
        )

        // Pass the keepMask straight to CIBlendWithMask — no feather.
        // Brief 1's 10px Gaussian feather looked good in theory but
        // when combined with the colorspace setup interacted badly with
        // the compositor and produced whole-frame blur. Mask edges go
        // back to a hard 0/255 step until we figure out a feather
        // implementation that doesn't break compositing.
        let featheredMask: CIImage = maskCI

        blendFilter.setValue(sourceCI, forKey: kCIInputImageKey)
        blendFilter.setValue(blurredCI, forKey: kCIInputBackgroundImageKey)
        blendFilter.setValue(featheredMask, forKey: kCIInputMaskImageKey)
        guard let outputCI = blendFilter.outputImage else {
            return .failure("CIBlendWithMask produced no output")
        }
        ciContext.render(outputCI, to: dstBuf, bounds: sourceCI.extent, colorSpace: nil)

        // --- Encode dst → JPG ---
        CVPixelBufferLockBaseAddress(dstBuf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(dstBuf, .readOnly) }
        guard let dstBase = CVPixelBufferGetBaseAddress(dstBuf) else {
            return .failure("CVPixelBufferGetBaseAddress(dst)")
        }
        let dstRowBytes = CVPixelBufferGetBytesPerRow(dstBuf)
        guard let outCtx = CGContext(
            data: dstBase, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: dstRowBytes,
            space: colorSpace, bitmapInfo: bitmapInfo
        ) else {
            return .failure("CGContext init (dst)")
        }
        guard let outCG = outCtx.makeImage() else {
            return .failure("makeImage failed (dst)")
        }
        let outUI = UIImage(cgImage: outCG, scale: uiImage.scale, orientation: .up)
        guard let jpgData = outUI.jpegData(compressionQuality: 0.9) else {
            return .failure("jpegData encoding failed")
        }
        do {
            try jpgData.write(to: URL(fileURLWithPath: destPath))
        } catch {
            return .failure("write failed: \(error.localizedDescription)")
        }

        // missRate semantics: 0.0 when we found the subject above
        // threshold; 1.0 when we fell through to no-subject mode
        // because either no faces or no match (the Dart side may
        // tolerate the latter — it's the "solo back-view" case).
        // lowConfidence is true when faces were present but none
        // matched the subject — surfaces the "subject not in frame"
        // signal so the Dart side / UI can decide whether to nudge.
        let missRate: Double = subjectIdentified ? 0.0 : (faces.isEmpty ? 1.0 : 0.0)
        let lowConfidence: Bool = (!subjectIdentified && !faces.isEmpty)
        return .success(
            processed: 1,
            missRate: missRate,
            lowConfidence: lowConfidence
        )
    }

    /// Encode the source buffer as the destination JPG verbatim — used
    /// as a last-resort fallback when Vision throws / the pipeline
    /// cannot complete. Caller supplies the metrics to return.
    @available(iOS 15.0, *)
    private static func encodeSourceAsFallback(
        srcBuf: CVPixelBuffer,
        dstBuf: CVPixelBuffer,
        width: Int,
        height: Int,
        colorSpace: CGColorSpace,
        bitmapInfo: UInt32,
        scale: CGFloat,
        destPath: String,
        missRate: Double,
        lowConfidence: Bool,
        failReason: String
    ) -> SafeModePhotoOutcome {
        NSLog("[SafeMode v2] fallback encode: \(failReason)")
        CVPixelBufferLockBaseAddress(srcBuf, .readOnly)
        CVPixelBufferLockBaseAddress(dstBuf, [])
        if let s = CVPixelBufferGetBaseAddress(srcBuf),
           let d = CVPixelBufferGetBaseAddress(dstBuf) {
            let srcRowBytes = CVPixelBufferGetBytesPerRow(srcBuf)
            let dstRowBytes = CVPixelBufferGetBytesPerRow(dstBuf)
            let sPtr = s.assumingMemoryBound(to: UInt8.self)
            let dPtr = d.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                memcpy(dPtr + y * dstRowBytes, sPtr + y * srcRowBytes, width * 4)
            }
        }
        CVPixelBufferUnlockBaseAddress(srcBuf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(dstBuf, .readOnly) }
        guard let dstBase = CVPixelBufferGetBaseAddress(dstBuf) else {
            return .failure("fallback encode: dst base addr nil")
        }
        let dstRowBytes = CVPixelBufferGetBytesPerRow(dstBuf)
        guard let outCtx = CGContext(
            data: dstBase, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: dstRowBytes,
            space: colorSpace, bitmapInfo: bitmapInfo
        ) else {
            return .failure("fallback encode: CGContext init")
        }
        guard let outCG = outCtx.makeImage() else {
            return .failure("fallback encode: makeImage failed")
        }
        let outUI = UIImage(cgImage: outCG, scale: scale, orientation: .up)
        guard let jpgData = outUI.jpegData(compressionQuality: 0.9) else {
            return .failure("fallback encode: jpegData failed")
        }
        do {
            try jpgData.write(to: URL(fileURLWithPath: destPath))
        } catch {
            return .failure("fallback encode: write failed \(error.localizedDescription)")
        }
        return .success(processed: 0, missRate: missRate, lowConfidence: lowConfidence)
    }

    /// Scanline flood-fill on a Planar8 binary mask. Returns a
    /// newly-allocated bitmap where pixels in the same connected
    /// component as `(seedX, seedY)` are 1, all others 0. The caller
    /// owns the buffer + must deallocate.
    ///
    /// 4-connectivity (no diagonals) is sufficient for the
    /// segmentation mask shapes Vision produces (smooth silhouettes
    /// with no 1-pixel diagonal bridges).
    @available(iOS 15.0, *)
    private static func floodFillBinary(
        mask: UnsafePointer<UInt8>,
        width: Int,
        height: Int,
        seedX: Int,
        seedY: Int,
        threshold: UInt8
    ) -> UnsafeMutablePointer<UInt8> {
        let total = width * height
        let visited = UnsafeMutablePointer<UInt8>.allocate(capacity: total)
        visited.initialize(repeating: 0, count: total)

        // Bail if seed itself is outside the mask (subject's face
        // centroid not inside any silhouette). Return all-zero visited
        // — caller's effect is "no subject silhouette identified",
        // which means EVERY mask-positive pixel will get blurred.
        // That's actually correct fail-safe behaviour.
        guard seedX >= 0, seedX < width, seedY >= 0, seedY < height else {
            return visited
        }
        let seedIdx = seedY * width + seedX
        if mask[seedIdx] < threshold {
            // Seed is on background — search a small neighborhood to
            // find a nearby mask-positive pixel. Heads sometimes
            // segment with a 5-10 pixel gap at the very tip of the
            // chin / forehead; the face centroid lands just outside.
            var foundSeed = -1
            let searchRadius = 16
            outer: for dr in 1...searchRadius {
                for dy in -dr...dr {
                    for dx in -dr...dr {
                        if abs(dx) != dr && abs(dy) != dr { continue }
                        let nx = seedX + dx
                        let ny = seedY + dy
                        if nx < 0 || nx >= width || ny < 0 || ny >= height { continue }
                        let i = ny * width + nx
                        if mask[i] >= threshold {
                            foundSeed = i
                            break outer
                        }
                    }
                }
            }
            if foundSeed < 0 {
                return visited
            }
            return floodFillFromIdx(
                mask: mask, width: width, height: height,
                threshold: threshold, seedIdx: foundSeed,
                visited: visited
            )
        }
        return floodFillFromIdx(
            mask: mask, width: width, height: height,
            threshold: threshold, seedIdx: seedIdx,
            visited: visited
        )
    }

    /// Inner flood-fill given a confirmed-positive seed index.
    /// Iterative (explicit stack) — recursive would blow the iOS
    /// stack on a large silhouette.
    @available(iOS 15.0, *)
    private static func floodFillFromIdx(
        mask: UnsafePointer<UInt8>,
        width: Int,
        height: Int,
        threshold: UInt8,
        seedIdx: Int,
        visited: UnsafeMutablePointer<UInt8>
    ) -> UnsafeMutablePointer<UInt8> {
        var stack: [Int] = [seedIdx]
        stack.reserveCapacity(1024)
        visited[seedIdx] = 1
        while let idx = stack.popLast() {
            let x = idx % width
            let y = idx / width
            // 4-neighbors.
            if x > 0 {
                let n = idx - 1
                if visited[n] == 0 && mask[n] >= threshold {
                    visited[n] = 1
                    stack.append(n)
                }
            }
            if x < width - 1 {
                let n = idx + 1
                if visited[n] == 0 && mask[n] >= threshold {
                    visited[n] = 1
                    stack.append(n)
                }
            }
            if y > 0 {
                let n = idx - width
                if visited[n] == 0 && mask[n] >= threshold {
                    visited[n] = 1
                    stack.append(n)
                }
            }
            if y < height - 1 {
                let n = idx + width
                if visited[n] == 0 && mask[n] >= threshold {
                    visited[n] = 1
                    stack.append(n)
                }
            }
        }
        return visited
    }

    /// Paint 0s into a head-region clip around a face's bbox, intersected
    /// with the segmentation mask and excluding subject pixels.
    ///
    /// Three changes vs the prior wave that visibly painted rectangular
    /// coral squares over subjects-behind-bystanders:
    ///   1. Only pixels segmentation marked as person silhouette get
    ///      blurred — background pixels inside the bbox stay sharp.
    ///   2. Subject silhouette pixels are excluded — if the client is
    ///      standing behind the bystander, the client stays sharp.
    ///   3. When Vision returned a face-contour landmark polygon, the
    ///      polygon (expanded ~25% outward from face center, with a
    ///      synthetic top-of-head canopy) clips the painted region to
    ///      something head-shaped instead of a rectangle.
    ///
    /// `segmentationMask` may be nil if PersonSegmenter failed; in that
    /// case we fall back to the original unconditional paint inside the
    /// shape (privacy guarantee preserved).
    /// `subjectComponent` is nil in no-subject mode — every mask-positive
    /// pixel inside the shape is fair game.
    /// `contourPolygonPx` is nil when Vision didn't return landmarks for
    /// this face — painter falls back to the expanded bbox shape.
    @available(iOS 15.0, *)
    private static func paintHeadExpansion(
        keepMask: UnsafeMutablePointer<UInt8>,
        width: Int,
        height: Int,
        pixelRect: CGRect,
        contourPolygonPx: [CGPoint]?,
        headWidthFactor: CGFloat,
        headHeightFactor: CGFloat,
        maxAreaFraction: Double = 1.0,
        segmentationMask: UnsafePointer<UInt8>?,
        subjectComponent: UnsafePointer<UInt8>?
    ) {
        // For close-up selfies a single face can occupy 40-60% of the
        // frame; multiplying by 2.0 x 1.5 then paints 80-90% of the
        // frame, which reads to the user as "everything is blurred".
        // Clamp the expansion so any single face contributes at most
        // `maxAreaFraction` of the frame area. With the polygon-clip
        // path active this is mostly a no-op for typical poses but
        // still kicks in for the close-up case.
        var wFactor = headWidthFactor
        var hFactor = headHeightFactor
        let frameArea = Double(width) * Double(height)
        if frameArea > 0 && maxAreaFraction > 0 && maxAreaFraction < 1.0 {
            let expandedW = Double(pixelRect.width) * Double(wFactor)
            let expandedH = Double(pixelRect.height) * Double(hFactor)
            let expandedArea = expandedW * expandedH
            let allowedArea = frameArea * maxAreaFraction
            if expandedArea > allowedArea && expandedArea > 0 {
                let scale = (allowedArea / expandedArea).squareRoot()
                wFactor *= CGFloat(scale)
                hFactor *= CGFloat(scale)
            }
        }
        let cx = pixelRect.midX
        let cy = pixelRect.midY
        let halfW = pixelRect.width * wFactor * 0.5
        let halfH = pixelRect.height * hFactor * 0.5
        let bboxX0 = max(0, Int((cx - halfW).rounded(.down)))
        let bboxX1 = min(width, Int((cx + halfW).rounded(.up)))
        let bboxY0 = max(0, Int((cy - halfH).rounded(.down)))
        let bboxY1 = min(height, Int((cy + halfH).rounded(.up)))

        // Compute the scan window. When a polygon is available we widen
        // the scan to the polygon's axis-aligned bbox.
        let polygon = contourPolygonPx
        let scanX0: Int
        let scanX1: Int
        let scanY0: Int
        let scanY1: Int
        if let poly = polygon, poly.count >= 3 {
            var minX = CGFloat.greatestFiniteMagnitude
            var minY = CGFloat.greatestFiniteMagnitude
            var maxX = -CGFloat.greatestFiniteMagnitude
            var maxY = -CGFloat.greatestFiniteMagnitude
            for p in poly {
                if p.x < minX { minX = p.x }
                if p.y < minY { minY = p.y }
                if p.x > maxX { maxX = p.x }
                if p.y > maxY { maxY = p.y }
            }
            scanX0 = max(0, min(bboxX0, Int(minX.rounded(.down))))
            scanY0 = max(0, min(bboxY0, Int(minY.rounded(.down))))
            scanX1 = min(width, max(bboxX1, Int(maxX.rounded(.up))))
            scanY1 = min(height, max(bboxY1, Int(maxY.rounded(.up))))
        } else {
            scanX0 = bboxX0
            scanY0 = bboxY0
            scanX1 = bboxX1
            scanY1 = bboxY1
        }

        // Within the face contour polygon, Vision's per-face identity
        // wins: this is a bystander head, blur mask-positive pixels
        // unconditionally (the subject-component exclusion is too greedy
        // to apply here — when two people stand close in frame Vision's
        // segmentation often merges them into one component which
        // floodFillBinary then claims entirely as "subject", with the
        // result that the bystander would never get blurred). Outside
        // the polygon (in the bbox-fallback region, or when Vision
        // didn't return landmarks) the subject-component exclusion
        // remains active so we still protect the client when a
        // bystander stands in front.
        let havePolygon = (polygon?.count ?? 0) >= 3
        for y in scanY0..<scanY1 {
            let rowOffset = y * width
            for x in scanX0..<scanX1 {
                let i = rowOffset + x
                let insidePolygon: Bool = havePolygon
                    ? pointInPolygon(
                        x: CGFloat(x) + 0.5,
                        y: CGFloat(y) + 0.5,
                        polygon: polygon!
                    )
                    : false
                let insideBbox = (x >= bboxX0 && x < bboxX1
                    && y >= bboxY0 && y < bboxY1)
                if !insidePolygon && !insideBbox { continue }
                if let segMask = segmentationMask {
                    if segMask[i] < 128 { continue }
                    if insidePolygon {
                        // Face oval → bystander head. Blur unconditionally.
                        keepMask[i] = 0
                    } else {
                        // Bbox-fallback / bbox-only mode → protect the
                        // subject silhouette when present.
                        if let subj = subjectComponent, subj[i] == 1 { continue }
                        keepMask[i] = 0
                    }
                } else {
                    keepMask[i] = 0
                }
            }
        }
    }

    /// Build the face-contour polygon in upright pixel coords (top-left
    /// origin). Uses VNFaceLandmarks2D.faceContour and expands outward
    /// ~25% from face center to cover hair / chin / ears (Vision's
    /// contour traces the jawline tightly; without expansion the polygon
    /// misses the hairline). Adds 3 synthetic top-of-head canopy points
    /// above the highest contour point so the polygon covers the
    /// forehead region (Vision's contour stops at the temples).
    @available(iOS 15.0, *)
    private static func faceContourPolygonPx(
        observation: VNFaceObservation,
        imageWidth: Int,
        imageHeight: Int,
        outwardExpansionFactor: CGFloat
    ) -> [CGPoint]? {
        guard let landmarks = observation.landmarks,
              let contour = landmarks.faceContour else {
            return nil
        }
        let imageSize = CGSize(width: imageWidth, height: imageHeight)
        let raw = contour.pointsInImage(imageSize: imageSize)
        if raw.count < 3 { return nil }

        // Vision returns points in bottom-left-origin coords; flip Y to
        // top-left convention used by the rest of the pipeline.
        var topLeft: [CGPoint] = []
        topLeft.reserveCapacity(raw.count)
        for p in raw {
            topLeft.append(CGPoint(x: p.x, y: CGFloat(imageHeight) - p.y))
        }

        let bboxNorm = observation.boundingBox
        let cxNormBot = bboxNorm.origin.x + bboxNorm.width * 0.5
        let cyNormBot = bboxNorm.origin.y + bboxNorm.height * 0.5
        let cxPx = cxNormBot * CGFloat(imageWidth)
        let cyPx = CGFloat(imageHeight) - cyNormBot * CGFloat(imageHeight)
        let f = outwardExpansionFactor

        var expanded: [CGPoint] = []
        expanded.reserveCapacity(topLeft.count)
        for p in topLeft {
            let dx = p.x - cxPx
            let dy = p.y - cyPx
            expanded.append(CGPoint(
                x: cxPx + dx * f,
                y: cyPx + dy * f
            ))
        }

        // Synthetic top-of-head canopy.
        var topY = CGFloat.greatestFiniteMagnitude
        var leftX = CGFloat.greatestFiniteMagnitude
        var rightX = -CGFloat.greatestFiniteMagnitude
        for p in expanded {
            if p.y < topY { topY = p.y }
            if p.x < leftX { leftX = p.x }
            if p.x > rightX { rightX = p.x }
        }
        let bboxHeightPx = bboxNorm.height * CGFloat(imageHeight)
        let lift = bboxHeightPx * 0.35
        let topCanopyY = max(0, topY - lift)
        let topMidX = (leftX + rightX) * 0.5
        expanded.append(CGPoint(x: rightX, y: topCanopyY))
        expanded.append(CGPoint(x: topMidX, y: topCanopyY))
        expanded.append(CGPoint(x: leftX, y: topCanopyY))

        // Sort clockwise by angle from centroid so the polygon is simple.
        var cxSum: CGFloat = 0
        var cySum: CGFloat = 0
        for p in expanded {
            cxSum += p.x
            cySum += p.y
        }
        let centroidX = cxSum / CGFloat(expanded.count)
        let centroidY = cySum / CGFloat(expanded.count)
        expanded.sort { a, b in
            atan2(a.y - centroidY, a.x - centroidX) <
                atan2(b.y - centroidY, b.x - centroidX)
        }
        return expanded
    }

    /// Even-odd rule point-in-polygon test for a closed simple polygon.
    private static func pointInPolygon(
        x: CGFloat,
        y: CGFloat,
        polygon: [CGPoint]
    ) -> Bool {
        if polygon.count < 3 { return false }
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let xi = polygon[i].x, yi = polygon[i].y
            let xj = polygon[j].x, yj = polygon[j].y
            let crosses = ((yi > y) != (yj > y)) &&
                (x < (xj - xi) * (y - yi) / ((yj - yi) == 0 ? 0.0001 : (yj - yi)) + xi)
            if crosses { inside.toggle() }
            j = i
        }
        return inside
    }


    // MARK: - Grayscale Fallback

    /// Recolour every pixel of a CGImage to its BT.601 luminance and return
    /// a fresh CGImage. Used by the thumbnail path as a fallback whenever
    /// `applySegmentationToThumbnail` returned nil (e.g. iOS < 15 or no
    /// person detected) so the grayscale contract still holds for
    /// practitioner-facing list thumbnails.
    ///
    /// Mirrors the in-place loop inside `applySegmentationToThumbnail`
    /// so the visual output matches whether segmentation succeeds or not.
    /// Returns nil only on CGContext allocation failure — caller should
    /// fall through to the un-touched source image in that rare case.
    static func grayscaleCGImage(_ cgImage: CGImage) -> CGImage? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerRow = width * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 =
            CGBitmapInfo.byteOrder32Little.rawValue |
            CGImageAlphaInfo.premultipliedFirst.rawValue

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let data = ctx.data else { return nil }
        let ptr = data.assumingMemoryBound(to: UInt8.self)
        let actualRowBytes = ctx.bytesPerRow
        for y in 0..<height {
            let rowStart = y * actualRowBytes
            for x in 0..<width {
                let p = rowStart + x * 4
                let b = Int(ptr[p + 0])
                let g = Int(ptr[p + 1])
                let r = Int(ptr[p + 2])
                let y8 = (r * 299 + g * 587 + b * 114 + 500) / 1000
                let luma = UInt8(max(0, min(255, y8)))
                ptr[p + 0] = luma
                ptr[p + 1] = luma
                ptr[p + 2] = luma
            }
        }
        return ctx.makeImage()
    }
}

// MARK: - Line Drawing Processor

/// Processes individual video frames into line drawings using Accelerate/vImage.
///
/// Pre-allocates working buffers for a given frame size and reuses them across
/// frames to avoid per-frame allocation overhead.
private class LineDrawingProcessor {
    let width: Int
    let height: Int
    let blurKernel: UInt32
    let thresholdBlock: Int
    let contrastLow: Int

    // Pre-allocated grayscale buffers (Planar8 = 1 byte per pixel).
    private var grayBuffer: vImage_Buffer
    private var invertedBuffer: vImage_Buffer
    private var blurredBuffer: vImage_Buffer
    private var sketchBuffer: vImage_Buffer
    private var adaptiveBuffer: vImage_Buffer
    private var localMeanBuffer: vImage_Buffer
    private var combinedBuffer: vImage_Buffer
    private var outputGrayBuffer: vImage_Buffer

    // Pre-allocated planar alpha plane (all 255) used by the gray->BGRA
    // conversion at the end of processFrame.
    private var alphaPlaneBuffer: vImage_Buffer

    // Pre-allocated scratch for the softened person-segmentation mask. We
    // tent-convolve the raw mask into this buffer once per frame before using
    // it as a lerp weight between dimmed-background and full-strength-body
    // pixels. Pre-allocated so we never allocate per frame.
    private var blurredMaskBuffer: vImage_Buffer

    init(width: Int, height: Int, blurKernel: Int, thresholdBlock: Int, contrastLow: Int) {
        self.width = width
        self.height = height
        // Ensure blur kernel is odd and at least 1.
        let k = UInt32(max(blurKernel | 1, 1))
        self.blurKernel = k
        self.thresholdBlock = thresholdBlock | 1  // Ensure odd.
        self.contrastLow = contrastLow

        let rowBytes = width
        let dataSize = width * height

        grayBuffer = vImage_Buffer(
            data: UnsafeMutableRawPointer.allocate(byteCount: dataSize, alignment: 16),
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: rowBytes
        )
        invertedBuffer = vImage_Buffer(
            data: UnsafeMutableRawPointer.allocate(byteCount: dataSize, alignment: 16),
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: rowBytes
        )
        blurredBuffer = vImage_Buffer(
            data: UnsafeMutableRawPointer.allocate(byteCount: dataSize, alignment: 16),
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: rowBytes
        )
        sketchBuffer = vImage_Buffer(
            data: UnsafeMutableRawPointer.allocate(byteCount: dataSize, alignment: 16),
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: rowBytes
        )
        adaptiveBuffer = vImage_Buffer(
            data: UnsafeMutableRawPointer.allocate(byteCount: dataSize, alignment: 16),
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: rowBytes
        )
        localMeanBuffer = vImage_Buffer(
            data: UnsafeMutableRawPointer.allocate(byteCount: dataSize, alignment: 16),
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: rowBytes
        )
        combinedBuffer = vImage_Buffer(
            data: UnsafeMutableRawPointer.allocate(byteCount: dataSize, alignment: 16),
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: rowBytes
        )
        outputGrayBuffer = vImage_Buffer(
            data: UnsafeMutableRawPointer.allocate(byteCount: dataSize, alignment: 16),
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: rowBytes
        )

        // Solid alpha plane, initialised once to 255.
        let alphaData = UnsafeMutableRawPointer.allocate(byteCount: dataSize, alignment: 16)
        memset(alphaData, 255, dataSize)
        alphaPlaneBuffer = vImage_Buffer(
            data: alphaData,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: rowBytes
        )

        // Scratch for the softened mask. Allocated once and reused.
        blurredMaskBuffer = vImage_Buffer(
            data: UnsafeMutableRawPointer.allocate(byteCount: dataSize, alignment: 16),
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: rowBytes
        )
    }

    deinit {
        grayBuffer.data.deallocate()
        invertedBuffer.data.deallocate()
        blurredBuffer.data.deallocate()
        sketchBuffer.data.deallocate()
        adaptiveBuffer.data.deallocate()
        localMeanBuffer.data.deallocate()
        combinedBuffer.data.deallocate()
        outputGrayBuffer.data.deallocate()
        alphaPlaneBuffer.data.deallocate()
        blurredMaskBuffer.data.deallocate()
    }

    /// Process a single BGRA pixel buffer into a line drawing, writing the
    /// result into the supplied output pixel buffer (which is expected to be
    /// BGRA at the same dimensions). Returns true on success.
    ///
    /// When `mask` is supplied, it must be a Planar8 buffer of width*height
    /// bytes (0 = background, 255 = person). The mask is softened with a
    /// tent convolution and then used as a lerp weight between a DIMMED copy
    /// of the sketch (background) and the full-strength sketch (body), so
    /// both body and equipment show but the body visibly pops. See
    /// `applyMaskedDim` for the exact blend math.
    func processFrame(_ inputBuffer: CVPixelBuffer, mask: UnsafePointer<UInt8>? = nil, into outBuffer: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(inputBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(inputBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(inputBuffer) else {
            return false
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(inputBuffer)
        let bufWidth = CVPixelBufferGetWidth(inputBuffer)
        let bufHeight = CVPixelBufferGetHeight(inputBuffer)

        // --- Step 1: Convert BGRA -> grayscale via vImage ---
        // vImageMatrixMultiply_ARGB8888ToPlanar8 applies a 4-channel weighted
        // sum. The pixels are physically laid out as B, G, R, A (so channel 0
        // is B, channel 1 is G, channel 2 is R, channel 3 is A). Using Rec.601
        // luma weights scaled to /256: R=77, G=151, B=28 → [B=28, G=151, R=77, A=0].
        var srcBGRA = vImage_Buffer(
            data: baseAddress,
            height: vImagePixelCount(bufHeight),
            width: vImagePixelCount(bufWidth),
            rowBytes: bytesPerRow
        )
        let matrix: [Int16] = [28, 151, 77, 0]
        matrix.withUnsafeBufferPointer { matPtr in
            _ = vImageMatrixMultiply_ARGB8888ToPlanar8(
                &srcBGRA,
                &grayBuffer,
                matPtr.baseAddress!,
                256,
                nil,
                0,
                vImage_Flags(kvImageNoFlags)
            )
        }

        // --- Step 2: Pencil sketch via divide ---
        // 2a. Invert: invertedBuffer = 255 - gray
        invertPixels(src: &grayBuffer, dst: &invertedBuffer)

        // 2b. Box blur the inverted image (approximates gaussian blur).
        vImageBoxConvolve_Planar8(
            &invertedBuffer,
            &blurredBuffer,
            nil,
            0, 0,
            blurKernel,
            blurKernel,
            0,
            vImage_Flags(kvImageEdgeExtend)
        )

        // 2c. Divide: sketch = gray * 256 / (255 - blurred + 1)
        //     This produces the pencil sketch effect.
        divideForSketch(
            gray: &grayBuffer,
            blurred: &blurredBuffer,
            dst: &sketchBuffer
        )

        // --- Step 3: Adaptive threshold ---
        // Compute local mean via box blur with thresholdBlock kernel.
        let tbk = UInt32(thresholdBlock)
        vImageBoxConvolve_Planar8(
            &grayBuffer,
            &localMeanBuffer,
            nil,
            0, 0,
            tbk,
            tbk,
            0,
            vImage_Flags(kvImageEdgeExtend)
        )

        // Threshold: pixel is black (0) if gray < localMean - C, else white (255).
        // C is now driven by the `edgeThresholdLo` tuning constant at the top
        // of this file (was hardcoded at 2; current 1 → ~30% more detail).
        adaptiveThreshold(
            gray: &grayBuffer,
            localMean: &localMeanBuffer,
            dst: &adaptiveBuffer,
            c: edgeThresholdLo
        )

        // --- Step 4: Combine (take min / darkest of sketch and adaptive) ---
        pixelwiseMin(a: &sketchBuffer, b: &adaptiveBuffer, dst: &combinedBuffer)

        // --- Step 5: Contrast boost ---
        // output = clamp((input - low) * 255 / (255 - low), 0, 255)
        //
        // `low` is the Dart-supplied `contrastLow` (AppConfig.contrastLow = 80)
        // scaled down by `edgeThresholdHi` (top-of-file tuning constant) so
        // more of the faint mid-gray sketch strokes survive the boost ⇒ more
        // detail. Example: 80 * 0.70 = 56.
        let effectiveContrastLow = max(
            0,
            min(254, Int((Double(contrastLow) * edgeThresholdHi).rounded()))
        )
        contrastBoost(src: &combinedBuffer, dst: &outputGrayBuffer, low: effectiveContrastLow)

        // --- Step 5.25: Line-alpha dim ---
        // Post-pipeline intensity scale — lightens black lines without
        // touching background whites. See `lineAlpha` constant at the top of
        // this file. NO-OP when lineAlpha >= 0.999.
        if lineAlpha < 0.999 {
            applyLineAlpha(dst: &outputGrayBuffer, alpha: lineAlpha)
        }

        // --- Step 5.5: Apply person segmentation mask (optional) ---
        // Two-zone blend: body pixels render at full strength, background
        // pixels render a dimmed version of the SAME sketch so equipment
        // (leg press, dumbbells, bench) stays visible as a ghost while the
        // body pops. The mask is softened first so the body/background
        // boundary doesn't look like a cutout glued onto paper.
        if let maskPtr = mask {
            applyMaskedDim(dst: &outputGrayBuffer, mask: maskPtr)
        }

        // --- Step 6: Convert grayscale back to BGRA and write into outBuffer ---
        CVPixelBufferLockBaseAddress(outBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(outBuffer, []) }

        guard let outBase = CVPixelBufferGetBaseAddress(outBuffer) else {
            return false
        }

        let outBytesPerRow = CVPixelBufferGetBytesPerRow(outBuffer)

        var outBGRA = vImage_Buffer(
            data: outBase,
            height: vImagePixelCount(bufHeight),
            width: vImagePixelCount(bufWidth),
            rowBytes: outBytesPerRow
        )

        // vImage only exposes a Planar8 -> ARGB8888 assembler. The function
        // writes the FOUR planar inputs into memory in the order given —
        // the trailing "ARGB" in the name is the byte order written, not a
        // semantic label on the inputs. So we remap the args to produce
        // BGRA byte order, which matches `kCVPixelFormatType_32BGRA` above.
        //
        // Previous (buggy) mapping wrote [A=255, R=g, G=g, B=g] into a buffer
        // iOS reads as [B, G, R, A] → blue channel pinned at 255, alpha
        // varying with gray. Dark lines composited onto a white background
        // read as ≈(222, 222, 255) → the "purple-blue tint on dark parts"
        // Carl reported on the hand-drawn treatment.
        //
        // Correct mapping: write bytes [B=g, G=g, R=g, A=255].
        _ = vImageConvert_Planar8toARGB8888(
            &outputGrayBuffer,   // 1st byte (semantically "A") → iOS reads as B
            &outputGrayBuffer,   // 2nd byte ("R") → iOS reads as G
            &outputGrayBuffer,   // 3rd byte ("G") → iOS reads as R
            &alphaPlaneBuffer,   // 4th byte ("B") → iOS reads as A (255 = opaque)
            &outBGRA,
            vImage_Flags(kvImageNoFlags)
        )

        return true
    }

    // MARK: - Pixel Operations

    /// Invert all pixels: dst = 255 - src
    private func invertPixels(src: inout vImage_Buffer, dst: inout vImage_Buffer) {
        let count = Int(src.height) * src.rowBytes
        let srcPtr = src.data.assumingMemoryBound(to: UInt8.self)
        let dstPtr = dst.data.assumingMemoryBound(to: UInt8.self)
        for i in 0..<count {
            dstPtr[i] = 255 &- srcPtr[i]
        }
    }

    /// Pencil sketch divide: dst = clamp(gray * 256 / (255 - blurred + 1), 0, 255)
    private func divideForSketch(
        gray: inout vImage_Buffer,
        blurred: inout vImage_Buffer,
        dst: inout vImage_Buffer
    ) {
        let count = Int(gray.height) * gray.rowBytes
        let grayPtr = gray.data.assumingMemoryBound(to: UInt8.self)
        let blurPtr = blurred.data.assumingMemoryBound(to: UInt8.self)
        let dstPtr = dst.data.assumingMemoryBound(to: UInt8.self)

        for i in 0..<count {
            let g = Int(grayPtr[i])
            let b = Int(blurPtr[i])
            let divisor = 255 - b + 1
            let value = (g * 256) / divisor
            dstPtr[i] = UInt8(min(value, 255))
        }
    }

    /// Adaptive threshold: dst = (gray < localMean - c) ? 0 : 255
    private func adaptiveThreshold(
        gray: inout vImage_Buffer,
        localMean: inout vImage_Buffer,
        dst: inout vImage_Buffer,
        c: Int
    ) {
        let count = Int(gray.height) * gray.rowBytes
        let grayPtr = gray.data.assumingMemoryBound(to: UInt8.self)
        let meanPtr = localMean.data.assumingMemoryBound(to: UInt8.self)
        let dstPtr = dst.data.assumingMemoryBound(to: UInt8.self)

        for i in 0..<count {
            let g = Int(grayPtr[i])
            let m = Int(meanPtr[i])
            dstPtr[i] = (g < m - c) ? 0 : 255
        }
    }

    /// Pixel-wise min of two buffers.
    private func pixelwiseMin(
        a: inout vImage_Buffer,
        b: inout vImage_Buffer,
        dst: inout vImage_Buffer
    ) {
        let count = Int(a.height) * a.rowBytes
        let aPtr = a.data.assumingMemoryBound(to: UInt8.self)
        let bPtr = b.data.assumingMemoryBound(to: UInt8.self)
        let dstPtr = dst.data.assumingMemoryBound(to: UInt8.self)

        for i in 0..<count {
            dstPtr[i] = min(aPtr[i], bPtr[i])
        }
    }

    /// Apply a person segmentation mask to the output gray buffer in place,
    /// producing a two-zone blend that keeps equipment visible as a ghost
    /// while the body pops at full strength.
    ///
    /// Pipeline per frame:
    ///   1. Tent-convolve the raw 0/255 mask with a 5x5 kernel so its edges
    ///      become a smooth gradient. Without this, the body looks like a
    ///      cutout glued onto paper — the edge lines up suspiciously well
    ///      with the client's silhouette.
    ///   2. For every pixel, let w = softMask[i] / 255. Lerp:
    ///         out = dim(src) * (1 - w) + src * w
    ///      where `dim(v) = 255 - (255 - v) * 0.35`.
    ///      - At w = 1 (body core): out = src → full-strength sketch.
    ///      - At w = 0 (clear background): out = dim(src). White paper
    ///        stays white (dim(255) = 255). Black line pixels
    ///        render at ~90/255 — dark grey ghost.
    ///      - Between (soft edge): smooth crossfade, no visible seam.
    ///
    /// The dim curve is precomputed into a 256-byte LUT once per call so the
    /// inner loop is a handful of integer ops per pixel.
    private func applyMaskedDim(dst: inout vImage_Buffer, mask: UnsafePointer<UInt8>) {
        let count = Int(dst.height) * dst.rowBytes

        // --- Step 1: Soften the mask into blurredMaskBuffer. ---
        // vImageTentConvolve_Planar8 with a 5x5 kernel is fast and gives a
        // smooth falloff across ~3-5 pixels of the mask edge.
        var srcMask = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: mask),
            height: vImagePixelCount(dst.height),
            width: vImagePixelCount(dst.width),
            rowBytes: Int(dst.width)  // person-segmenter writes tightly-packed rows
        )
        let tentErr = vImageTentConvolve_Planar8(
            &srcMask,
            &blurredMaskBuffer,
            nil,
            0, 0,
            5, 5,
            0,
            vImage_Flags(kvImageEdgeExtend)
        )

        // If the tent convolve fails for any reason, fall back to using the
        // raw mask so we still produce the right two-zone blend, just with a
        // harder edge.
        let softMaskPtr: UnsafePointer<UInt8>
        if tentErr == kvImageNoError {
            softMaskPtr = UnsafePointer(blurredMaskBuffer.data.assumingMemoryBound(to: UInt8.self))
        } else {
            softMaskPtr = mask
        }

        // --- Step 2: Precompute the dim LUT. ---
        // dim[v] = round(255 - (255 - v) * backgroundDim)
        // White stays white, black drops to `255 * (1 - backgroundDim)`.
        // Previously hardcoded at 0.35 — now exposed as the file-level
        // `backgroundDim` constant (see tuning history at top of file).
        var dimLUT = [UInt8](repeating: 0, count: 256)
        for v in 0...255 {
            let dimmed = 255.0 - (255.0 - Double(v)) * backgroundDim
            dimLUT[v] = UInt8(max(0, min(255, Int(dimmed.rounded()))))
        }

        // --- Step 3: Per-pixel lerp. ---
        // out = (dim(src) * (255 - w) + src * w + 127) / 255
        // Using +127 for rounding so the midpoint converges correctly.
        let dstPtr = dst.data.assumingMemoryBound(to: UInt8.self)
        dimLUT.withUnsafeBufferPointer { lutPtr in
            guard let lut = lutPtr.baseAddress else { return }
            for i in 0..<count {
                let src = Int(dstPtr[i])
                let dim = Int(lut[src])
                let w = Int(softMaskPtr[i])
                let inv = 255 - w
                let blended = (dim * inv + src * w + 127) / 255
                dstPtr[i] = UInt8(blended)
            }
        }
    }

    /// Line-alpha dim: lighten black lines toward gray without touching the
    /// near-white background. Implemented as a 256-byte LUT:
    ///     out = 255 - (255 - gray) * alpha
    /// With alpha = 0.65: pure black (0) → 89, mid-gray (128) → ~173, white
    /// (255) stays 255. Applied in-place on the output gray buffer so the
    /// subsequent Planar8 → BGRA assembly just picks up the lighter pixels.
    ///
    /// Tuned via the file-level `lineAlpha` constant. Skipped entirely when
    /// the caller passes alpha >= 0.999.
    private func applyLineAlpha(dst: inout vImage_Buffer, alpha: Double) {
        let count = Int(dst.height) * dst.rowBytes
        var lut = [UInt8](repeating: 0, count: 256)
        for v in 0...255 {
            let out = 255.0 - (255.0 - Double(v)) * alpha
            lut[v] = UInt8(max(0, min(255, Int(out.rounded()))))
        }
        let dstPtr = dst.data.assumingMemoryBound(to: UInt8.self)
        lut.withUnsafeBufferPointer { bp in
            guard let l = bp.baseAddress else { return }
            for i in 0..<count {
                dstPtr[i] = l[Int(dstPtr[i])]
            }
        }
    }

    /// Contrast boost: output = clamp((input - low) * 255 / (255 - low), 0, 255)
    private func contrastBoost(
        src: inout vImage_Buffer,
        dst: inout vImage_Buffer,
        low: Int
    ) {
        let count = Int(src.height) * src.rowBytes
        let srcPtr = src.data.assumingMemoryBound(to: UInt8.self)
        let dstPtr = dst.data.assumingMemoryBound(to: UInt8.self)

        let range = max(255 - low, 1)

        for i in 0..<count {
            let v = Int(srcPtr[i]) - low
            if v <= 0 {
                dstPtr[i] = 0
            } else {
                let boosted = (v * 255) / range
                dstPtr[i] = UInt8(min(boosted, 255))
            }
        }
    }
}

// MARK: - Segmented Colour Processor (v7.1 dual-output)

/// Per-frame compositing for the segmented-COLOUR companion video.
///
/// Input : BGRA source pixel buffer + planar8 Vision person mask.
/// Output: BGRA pixel buffer where body-zone pixels are full-colour
///         passthrough and background-zone pixels are dimmed via the
///         same `backgroundDim` constant the line-drawing pipeline uses.
///
/// No edge detection, no sketch — this is the colour sibling of the
/// line drawing, designed to drive the web player's Colour + B&W
/// treatments with the same body-pop separation users already see on
/// the Line treatment. B&W is applied client-side via CSS filter on
/// the same source URL.
///
/// Mask handling mirrors `LineDrawingProcessor.applyMaskedDim`:
///   1. tent-convolve the raw mask so the body/background boundary
///      becomes a smooth gradient (no cutout glue edge);
///   2. per pixel, let w = softMask[i] / 255; lerp each BGR channel
///      between dim(channel) at w=0 and channel at w=1 (alpha left
///      untouched at source). White paper stays white; black pixels
///      drop toward mid-grey.
///
/// Reuses the same scratch buffer pattern as LineDrawingProcessor —
/// one allocation at init, freed at deinit — so per-frame cost is
/// just the tent convolve + the inner loop.
private class SegmentedColorProcessor {
    let width: Int
    let height: Int

    // Softened-mask scratch. One allocation, reused every frame.
    private var blurredMaskBuffer: vImage_Buffer

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        blurredMaskBuffer = vImage_Buffer(
            data: UnsafeMutableRawPointer.allocate(byteCount: width * height, alignment: 16),
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: width
        )
    }

    deinit {
        blurredMaskBuffer.data.deallocate()
    }

    /// Compose a segmented-colour frame.
    ///
    /// `mask` may be nil — in that case we fall through to a straight
    /// BGRA copy (no body-pop). Returns false on any lock / base-address
    /// failure so the caller can skip the append.
    func processFrame(
        _ inputBuffer: CVPixelBuffer,
        mask: UnsafePointer<UInt8>?,
        into outBuffer: CVPixelBuffer
    ) -> Bool {
        CVPixelBufferLockBaseAddress(inputBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(inputBuffer, .readOnly) }

        guard let srcBase = CVPixelBufferGetBaseAddress(inputBuffer) else {
            return false
        }

        let srcBytesPerRow = CVPixelBufferGetBytesPerRow(inputBuffer)
        let bufWidth = CVPixelBufferGetWidth(inputBuffer)
        let bufHeight = CVPixelBufferGetHeight(inputBuffer)

        CVPixelBufferLockBaseAddress(outBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(outBuffer, []) }

        guard let dstBase = CVPixelBufferGetBaseAddress(outBuffer) else {
            return false
        }
        let dstBytesPerRow = CVPixelBufferGetBytesPerRow(outBuffer)

        let srcPtr = srcBase.assumingMemoryBound(to: UInt8.self)
        let dstPtr = dstBase.assumingMemoryBound(to: UInt8.self)

        // Precompute dim LUT once per frame. Matches the dim curve used
        // by the line-drawing background-zone blend, so the two treatments
        // share a visual language — background gets identically lifted
        // regardless of which output the client flips to.
        var dimLUT = [UInt8](repeating: 0, count: 256)
        for v in 0...255 {
            let dimmed = 255.0 - (255.0 - Double(v)) * backgroundDim
            dimLUT[v] = UInt8(max(0, min(255, Int(dimmed.rounded()))))
        }

        if let maskPtr = mask {
            // Soften the mask via tent convolve so the body/background
            // boundary is a smooth gradient, not a hard cutout.
            var srcMaskBuf = vImage_Buffer(
                data: UnsafeMutableRawPointer(mutating: maskPtr),
                height: vImagePixelCount(bufHeight),
                width: vImagePixelCount(bufWidth),
                rowBytes: bufWidth
            )
            let tentErr = vImageTentConvolve_Planar8(
                &srcMaskBuf,
                &blurredMaskBuffer,
                nil,
                0, 0,
                5, 5,
                0,
                vImage_Flags(kvImageEdgeExtend)
            )
            let softMaskPtr: UnsafePointer<UInt8>
            if tentErr == kvImageNoError {
                softMaskPtr = UnsafePointer(blurredMaskBuffer.data.assumingMemoryBound(to: UInt8.self))
            } else {
                softMaskPtr = maskPtr
            }

            dimLUT.withUnsafeBufferPointer { lutBuf in
                guard let lut = lutBuf.baseAddress else { return }
                for y in 0..<bufHeight {
                    let srcRow = y * srcBytesPerRow
                    let dstRow = y * dstBytesPerRow
                    let maskRow = y * bufWidth
                    for x in 0..<bufWidth {
                        let w = Int(softMaskPtr[maskRow + x])
                        let inv = 255 - w
                        let sp = srcRow + x * 4
                        let dp = dstRow + x * 4
                        // BGRA: blend B, G, R independently; carry alpha
                        // straight through from source (typically 255).
                        for c in 0..<3 {
                            let s = Int(srcPtr[sp + c])
                            let d = Int(lut[s])
                            let blended = (d * inv + s * w + 127) / 255
                            dstPtr[dp + c] = UInt8(blended)
                        }
                        dstPtr[dp + 3] = srcPtr[sp + 3]
                    }
                }
            }
        } else {
            // No mask — straight copy. Keeps the seg output alive on
            // older iOS where Vision segmentation isn't available;
            // the client gets the colour source with no body-pop effect
            // rather than an empty file.
            for y in 0..<bufHeight {
                let srcRow = srcBase.advanced(by: y * srcBytesPerRow)
                let dstRow = dstBase.advanced(by: y * dstBytesPerRow)
                memcpy(dstRow, srcRow, bufWidth * 4)
            }
        }

        return true
    }
}

// MARK: - Mask Output Processor (v7.2)

/// Writes a Vision person-segmentation Planar8 mask into a BGRA pixel
/// buffer so it can be muxed through an `AVAssetWriter` configured for
/// H.264 — most iOS H.264 encoders refuse single-channel input, so we
/// expand each mask byte as `B = G = R = maskValue, A = 255`. The
/// resulting video is a grayscale silhouette (body=white, background=
/// black) that a future playback-time compositor can blend directly
/// against the segmented-colour file for tunable dim / other effects.
///
/// Stateless — no per-frame allocations. All work is a single sweep
/// over the destination buffer. If `mask` is nil (iOS <15, empty
/// scene), we emit an all-black frame so the mask timeline stays
/// aligned with the segmented file.
private enum MaskOutputProcessor {
    static func writePlanar8MaskAsBGRA(
        mask: UnsafePointer<UInt8>?,
        width: Int,
        height: Int,
        into outBuffer: CVPixelBuffer
    ) -> Bool {
        CVPixelBufferLockBaseAddress(outBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(outBuffer, []) }

        guard let dstBase = CVPixelBufferGetBaseAddress(outBuffer) else {
            return false
        }
        let dstBytesPerRow = CVPixelBufferGetBytesPerRow(outBuffer)
        let dstPtr = dstBase.assumingMemoryBound(to: UInt8.self)

        if let maskPtr = mask {
            for y in 0..<height {
                let dstRow = y * dstBytesPerRow
                let maskRow = y * width
                for x in 0..<width {
                    let v = maskPtr[maskRow + x]
                    let dp = dstRow + x * 4
                    // BGRA: R = G = B = mask value, A = 255.
                    dstPtr[dp + 0] = v
                    dstPtr[dp + 1] = v
                    dstPtr[dp + 2] = v
                    dstPtr[dp + 3] = 255
                }
            }
        } else {
            // No mask for this frame — emit black with full alpha so the
            // timeline stays aligned with the segmented file and any
            // future compositor reads "no person here" for this frame.
            for y in 0..<height {
                let dstRow = y * dstBytesPerRow
                for x in 0..<width {
                    let dp = dstRow + x * 4
                    dstPtr[dp + 0] = 0
                    dstPtr[dp + 1] = 0
                    dstPtr[dp + 2] = 0
                    dstPtr[dp + 3] = 255
                }
            }
        }

        return true
    }
}

// MARK: - Person Segmentation

/// Runs `VNGeneratePersonSegmentationRequest` per frame and upscales the
/// resulting mask to a target size. Pooled across frames so the sequence
/// request handler and the upscale destination buffer are created once.
///
/// iOS 15+ only. The caller must gate with `@available(iOS 15.0, *)`.
@available(iOS 15.0, *)
private class PersonSegmenter {
    let width: Int
    let height: Int

    private let sequenceHandler = VNSequenceRequestHandler()
    private let request: VNGeneratePersonSegmentationRequest

    // Pre-allocated upscale destination. Vision typically returns a
    // 256x256 (or thereabouts) mask; we scale it to frame size once per
    // frame and reuse this buffer's backing memory across every frame.
    private var upscaledMaskBuffer: vImage_Buffer

    // v8 — optional hand-pose dilator. Painted onto the mask after
    // upscaling so equipment held in either hand pops with the body
    // instead of fading into the background. nil when disabled at the
    // top-of-file flag or when running on iOS < 14 (HumanHandPose API).
    private let handDilator: HandPoseDilator?

    init(width: Int, height: Int) {
        self.width = width
        self.height = height

        let req = VNGeneratePersonSegmentationRequest()
        // .accurate runs on the Neural Engine on modern iPhones and produces
        // cleaner edges than .balanced/.fast. For a 30fps conversion on
        // iPhone 17 Pro this adds ~8-15ms/frame — well within budget.
        req.qualityLevel = .accurate
        req.outputPixelFormat = kCVPixelFormatType_OneComponent8
        self.request = req

        let dataSize = width * height
        upscaledMaskBuffer = vImage_Buffer(
            data: UnsafeMutableRawPointer.allocate(byteCount: dataSize, alignment: 16),
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: width
        )

        // PersonSegmenter is iOS 15+ so VNDetectHumanHandPoseRequest
        // (iOS 14+) is unconditionally available here.
        self.handDilator = handDilationEnabled
            ? HandPoseDilator(width: width, height: height)
            : nil
    }

    deinit {
        upscaledMaskBuffer.data.deallocate()
    }

    /// Apply hand-pose dilation to the freshly upscaled mask. Called from
    /// both the per-frame and one-shot paths after the upscale has landed
    /// in `upscaledMaskBuffer`. No-op when no dilator is allocated or when
    /// no hands are detected — the original mask passes through unchanged.
    private func augmentWithHandDilation(pixelBuffer: CVPixelBuffer) {
        guard let dilator = handDilator else { return }
        let dstPtr = upscaledMaskBuffer.data.assumingMemoryBound(to: UInt8.self)
        dilator.augment(mask: dstPtr, pixelBuffer: pixelBuffer)
    }

    /// Run segmentation on the supplied BGRA pixel buffer and return a pointer
    /// to an internally-owned upscaled Planar8 mask of size width*height.
    /// The returned pointer is valid until the next call to `generateMask`
    /// (or until the segmenter is deallocated) — do NOT hold onto it across
    /// frames.
    ///
    /// Returns nil if Vision fails for any reason. Callers should treat nil
    /// as "skip masking this frame" — the pipeline falls through to the
    /// un-masked line drawing.
    func generateMask(for pixelBuffer: CVPixelBuffer) -> UnsafePointer<UInt8>? {
        do {
            try sequenceHandler.perform([request], on: pixelBuffer)
        } catch {
            NSLog("PersonSegmenter: VNSequenceRequestHandler.perform failed: \(error.localizedDescription)")
            return nil
        }

        guard let observation = request.results?.first as? VNPixelBufferObservation else {
            // No observation = no person detected in an empty frame. Not an
            // error — but there's no mask to apply so skip.
            return nil
        }

        let maskPB = observation.pixelBuffer
        let maskWidth = CVPixelBufferGetWidth(maskPB)
        let maskHeight = CVPixelBufferGetHeight(maskPB)

        CVPixelBufferLockBaseAddress(maskPB, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(maskPB, .readOnly) }

        guard let maskBase = CVPixelBufferGetBaseAddress(maskPB) else {
            return nil
        }

        let maskRowBytes = CVPixelBufferGetBytesPerRow(maskPB)

        // Fast path: Vision returned a mask already at target size.
        if maskWidth == width && maskHeight == height {
            // Copy into our owned buffer so the caller can use it after we
            // release the pixel buffer lock above. Respect row strides — the
            // source may have padding between rows.
            let dstPtr = upscaledMaskBuffer.data.assumingMemoryBound(to: UInt8.self)
            let dstRowBytes = upscaledMaskBuffer.rowBytes
            if maskRowBytes == dstRowBytes {
                memcpy(dstPtr, maskBase, maskRowBytes * maskHeight)
            } else {
                for row in 0..<maskHeight {
                    memcpy(
                        dstPtr.advanced(by: row * dstRowBytes),
                        maskBase.advanced(by: row * maskRowBytes),
                        width
                    )
                }
            }
            augmentWithHandDilation(pixelBuffer: pixelBuffer)
            return UnsafePointer(dstPtr)
        }

        // Common case: upscale from Vision's internal resolution to frame size.
        var srcBuffer = vImage_Buffer(
            data: maskBase,
            height: vImagePixelCount(maskHeight),
            width: vImagePixelCount(maskWidth),
            rowBytes: maskRowBytes
        )
        let scaleErr = vImageScale_Planar8(
            &srcBuffer,
            &upscaledMaskBuffer,
            nil,
            vImage_Flags(kvImageNoFlags)
        )
        if scaleErr != kvImageNoError {
            NSLog("PersonSegmenter: vImageScale_Planar8 failed with \(scaleErr)")
            return nil
        }
        augmentWithHandDilation(pixelBuffer: pixelBuffer)
        let dstPtr = upscaledMaskBuffer.data.assumingMemoryBound(to: UInt8.self)
        return UnsafePointer(dstPtr)
    }

    /// One-shot variant for single-frame paths (thumbnails). Uses the
    /// request-handler-per-call `VNImageRequestHandler` since there's no
    /// temporal coherence to preserve. The returned mask is still owned by
    /// this segmenter's pre-allocated buffer.
    func generateMaskOneShot(for pixelBuffer: CVPixelBuffer) -> UnsafePointer<UInt8>? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        do {
            try handler.perform([request])
        } catch {
            NSLog("PersonSegmenter: VNImageRequestHandler.perform failed: \(error.localizedDescription)")
            return nil
        }

        guard let observation = request.results?.first as? VNPixelBufferObservation else {
            return nil
        }

        let maskPB = observation.pixelBuffer
        let maskWidth = CVPixelBufferGetWidth(maskPB)
        let maskHeight = CVPixelBufferGetHeight(maskPB)

        CVPixelBufferLockBaseAddress(maskPB, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(maskPB, .readOnly) }

        guard let maskBase = CVPixelBufferGetBaseAddress(maskPB) else {
            return nil
        }

        let maskRowBytes = CVPixelBufferGetBytesPerRow(maskPB)

        if maskWidth == width && maskHeight == height {
            let dstPtr = upscaledMaskBuffer.data.assumingMemoryBound(to: UInt8.self)
            let dstRowBytes = upscaledMaskBuffer.rowBytes
            if maskRowBytes == dstRowBytes {
                memcpy(dstPtr, maskBase, maskRowBytes * maskHeight)
            } else {
                for row in 0..<maskHeight {
                    memcpy(
                        dstPtr.advanced(by: row * dstRowBytes),
                        maskBase.advanced(by: row * maskRowBytes),
                        width
                    )
                }
            }
            augmentWithHandDilation(pixelBuffer: pixelBuffer)
            return UnsafePointer(dstPtr)
        }

        var srcBuffer = vImage_Buffer(
            data: maskBase,
            height: vImagePixelCount(maskHeight),
            width: vImagePixelCount(maskWidth),
            rowBytes: maskRowBytes
        )
        let scaleErr = vImageScale_Planar8(
            &srcBuffer,
            &upscaledMaskBuffer,
            nil,
            vImage_Flags(kvImageNoFlags)
        )
        if scaleErr != kvImageNoError {
            NSLog("PersonSegmenter: vImageScale_Planar8 failed with \(scaleErr)")
            return nil
        }
        augmentWithHandDilation(pixelBuffer: pixelBuffer)
        let dstPtr = upscaledMaskBuffer.data.assumingMemoryBound(to: UInt8.self)
        return UnsafePointer(dstPtr)
    }
}

// MARK: - Hand-pose dilation (v8)

/// Runs `VNDetectHumanHandPoseRequest` per frame and paints filled discs
/// onto a Planar8 mask buffer at each detected hand. Used by
/// `PersonSegmenter` to expand the person silhouette to cover gripped
/// equipment (dumbbells, bands, kettlebells, plates) so they fall inside
/// the body zone of the two-zone blend.
///
/// Pooled across frames the same way `PersonSegmenter` is — the
/// `VNSequenceRequestHandler` and the underlying request are created
/// once and reused.
///
/// iOS 14+ only. The caller must gate with `@available(iOS 14.0, *)`.
@available(iOS 14.0, *)
private class HandPoseDilator {
    let width: Int
    let height: Int

    private let sequenceHandler = VNSequenceRequestHandler()
    private let request: VNDetectHumanHandPoseRequest

    /// Base disc radius in pixels. Computed once at init from the frame's
    /// shorter dimension via `handDilationRadiusFraction` (with a minimum
    /// floor of `handDilationRadiusMin`). The actual painted radius can
    /// grow larger when a hand's keypoint spread exceeds the base.
    private let baseRadius: Int

    init(width: Int, height: Int) {
        self.width = width
        self.height = height

        let req = VNDetectHumanHandPoseRequest()
        // Two hands is the common case for held equipment (barbell,
        // landmine, double-dumbbell). The default is 2 already; setting
        // it explicitly so future Apple changes don't surprise us.
        req.maximumHandCount = 2
        self.request = req

        let shortSide = Swift.min(width, height)
        let fractional = Int((Double(shortSide) * handDilationRadiusFraction).rounded())
        self.baseRadius = Swift.max(handDilationRadiusMin, fractional)
    }

    /// Detect hands in `pixelBuffer` and paint a filled disc onto `mask`
    /// at each one. `mask` MUST be a tightly-packed Planar8 buffer of
    /// `width * height` bytes (matches `PersonSegmenter.upscaledMaskBuffer`).
    /// Disc pixels are set to 255 — pixels already at 255 stay at 255.
    /// No-op when Vision fails or no hands are detected.
    func augment(mask: UnsafeMutablePointer<UInt8>, pixelBuffer: CVPixelBuffer) {
        do {
            try sequenceHandler.perform([request], on: pixelBuffer)
        } catch {
            // Hand detection is best-effort — a failure leaves the
            // mask in its pre-augmentation state. Don't log per-frame;
            // the segmentation pipeline already logs Vision errors and
            // a flood here would just be noise on tricky scenes.
            return
        }
        guard let observations = request.results, !observations.isEmpty else {
            return
        }
        for obs in observations {
            paintHandDisc(observation: obs, mask: mask)
        }
    }

    /// Compute the centroid + spread of confident keypoints on a single
    /// hand observation, then paint a filled disc onto the mask.
    private func paintHandDisc(
        observation: VNHumanHandPoseObservation,
        mask: UnsafeMutablePointer<UInt8>
    ) {
        // `recognizedPoints(.all)` throws if the request hasn't finished;
        // by the time we're here it has. Treat any throw as "skip this
        // hand" — partial hand detections aren't worth dilating around.
        guard let points = try? observation.recognizedPoints(.all),
              !points.isEmpty else {
            return
        }

        var sumX: Double = 0
        var sumY: Double = 0
        var count: Int = 0
        var minX: Double = 1.0
        var maxX: Double = 0.0
        var minY: Double = 1.0
        var maxY: Double = 0.0

        for (_, point) in points {
            if point.confidence < handDilationConfidenceMin { continue }
            // Vision normalised coords: origin lower-left, range 0…1.
            let x = Double(point.location.x)
            let y = Double(point.location.y)
            sumX += x
            sumY += y
            count += 1
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }

        if count == 0 { return }

        let cxNorm = sumX / Double(count)
        let cyNorm = sumY / Double(count)
        // Flip Y because Vision's origin is lower-left but our mask
        // buffer rows count from the top.
        let centerX = Int((cxNorm * Double(width)).rounded())
        let centerY = Int(((1.0 - cyNorm) * Double(height)).rounded())

        // Adaptive radius — the larger of the base radius and the
        // keypoint-spread radius (half the bounding-box diagonal,
        // scaled by `handDilationSpreadMultiplier`). Wide grips
        // (barbell, kettlebell handle held with both hands close
        // together) get a generous halo; tight fists (dumbbell handle)
        // fall back to the base.
        let spreadX = (maxX - minX) * Double(width)
        let spreadY = (maxY - minY) * Double(height)
        let spreadDiag = (spreadX * spreadX + spreadY * spreadY).squareRoot()
        let spreadRadius = Int((spreadDiag * 0.5 * handDilationSpreadMultiplier).rounded())
        let radius = Swift.max(baseRadius, spreadRadius)

        paintDisc(centerX: centerX, centerY: centerY, radius: radius, mask: mask)
    }

    /// Paint a filled disc at `(centerX, centerY)` with radius `radius`
    /// onto the Planar8 `mask`. Pixels inside the disc are set to 255;
    /// pixels outside are left untouched. Bounds-clipped on every side.
    private func paintDisc(
        centerX: Int,
        centerY: Int,
        radius: Int,
        mask: UnsafeMutablePointer<UInt8>
    ) {
        if radius <= 0 { return }
        let r2 = radius * radius
        let yMin = Swift.max(0, centerY - radius)
        let yMax = Swift.min(height - 1, centerY + radius)
        let xMin = Swift.max(0, centerX - radius)
        let xMax = Swift.min(width - 1, centerX + radius)
        if yMin > yMax || xMin > xMax { return }

        for y in yMin...yMax {
            let dy = y - centerY
            let dy2 = dy * dy
            let row = y * width
            for x in xMin...xMax {
                let dx = x - centerX
                if dx * dx + dy2 <= r2 {
                    mask[row + x] = 255
                }
            }
        }
    }
}

// ============================================================================
// SafeModeProcessor — Safe Mode bystander-blur compositor (2026-05-22)
// ============================================================================
//
// Produces a copy of the source video frame with bystanders blurred via a
// heavy Gaussian (CIGaussianBlur radius ≈ 35 on 1080p) and the subject
// passed through untouched. Used by the Safe Mode 4th-output writer in
// `convertVideo` when the capture happened inside a Safe-Mode-enforcing
// premises (resolved at session-start by `SafeModeService` on the Dart side).
//
// Algorithm
// ---------
// 1. Run `VNDetectFaceRectanglesRequest` on the source frame. Faces scale
//    with camera proximity far more reliably than torso/upper-body
//    bounding boxes — a centered bystander with a big torso no longer
//    out-votes the closer subject whose torso is partly cropped.
// 2. Pick the LARGEST face by area = the subject.
// 3. Derive a subject "anchor" bbox from the chosen face: the face
//    centroid + an expanded region covering head + torso + legs (face
//    bbox extended downward by ~6× its height and sideways by ~2× its
//    width). Mask pixels inside this anchor are subject pixels; mask
//    pixels outside are bystander pixels. Background (mask < 128) is
//    always passthrough.
// 4. Build a "keep source" 8-bit mask: 255 where source should show
//    (subject pixels + background), 0 where blurred should show
//    (bystander pixels). Composite via CIBlendWithMask:
//       output = blendWithMask(source, blurredSource, keepSourceMask)
//    Renderer is a cached CIContext (reused across frames).
// 5. Ambiguity flag: if the second-largest face is within ~20% area of
//    the chosen face, the result payload carries `lowConfidence: true`
//    so the Dart side can prompt the practitioner to confirm the
//    subject post-capture. The tap-to-confirm UI is a separate PR;
//    this processor just surfaces the signal.
//
// If face detection returns zero faces the safe pass is skipped for
// the frame (the writer skips its append; the per-frame loss is
// preferable to silently failing-open and shipping a clean untreated
// bystander into the raw archive). Those frames count toward `missRate`.
//
// Performance
// -----------
// VNDetectFaceRectanglesRequest is ~5-15ms per frame on iPhone 15.
// CIGaussianBlur(radius: 35) + CIBlendWithMask on a 1080p frame renders
// in ~10-15ms on the same hardware. Total per-frame cost is ~25-30ms —
// fine for the post-capture pass, well below 33ms at 30 fps. The
// CIContext is allocated once (Metal-backed) and reused; CIFilter
// instances are reused; per-frame allocations are limited to CIImage
// wrappers (cheap) and a single 8-bit mask buffer (allocated once and
// re-filled per frame).
//
// V1 LOCKED params (2026-05-22, Carl-signed)
// ------------------------------------------
//   gaussianBlurRadius = 35.0   // on 1080p source; scaled by source dim
//   subjectExpandHorz  = 2.0    // face bbox grows by 2× horizontally
//   subjectExpandDown  = 6.0    // face bbox grows by 6× downward (torso+legs)
//   subjectExpandUp    = 0.4    // face bbox grows slightly upward (hair)
//   lowConfidenceRatio = 0.80   // 2nd face area >= 80% of 1st area => flag
//
// No coral tint on the blurred region — pure Gaussian, conventional
// "sensitive photo blur" pattern. The previous flat-coral painting is
// retired.

private class SafeModeProcessor {
    let width: Int
    let height: Int
    // EXIF orientation to hint to Vision so faces are scored in their
    // upright frame. For iPhone front-camera portrait video the natural
    // buffer is landscape with a 90deg CW rotation encoded in the
    // track's preferredTransform — Vision needs `.right` to interpret
    // it. Photos derive from `UIImage.imageOrientation`. Defaults to
    // `.up` (no rotation) which is the safe fallback for already-baked
    // upright buffers.
    let orientation: CGImagePropertyOrientation

    // Re-used Vision request handler so the framework can keep its
    // face-detector warm across frames. Vision's `VNSequenceRequestHandler`
    // is the canonical pattern for per-frame requests on the same video.
    private let sequenceHandler = VNSequenceRequestHandler()
    private let faceRequest: VNDetectFaceRectanglesRequest

    // V1 LOCKED tuning constants (2026-05-22). Comments mirror the
    // top-of-class doc. Tuned for 1080p source; blur radius scales
    // proportionally if the source dimension differs.
    private static let baseGaussianBlurRadius: Double = 35.0
    private static let baseSourceDim: Double = 1080.0
    private static let subjectExpandHorz: CGFloat = 2.0
    private static let subjectExpandDown: CGFloat = 6.0
    private static let subjectExpandUp: CGFloat = 0.4
    private static let lowConfidenceRatio: CGFloat = 0.80

    // CoreImage compositor — cached once, reused per frame. Metal-backed
    // CIContext is the cheapest renderer we have access to without
    // touching MPS directly. Allocating per-frame would spike memory and
    // throw away Vision's KVO-cached pipeline state.
    private let ciContext: CIContext
    private let blurFilter: CIFilter
    private let blendFilter: CIFilter

    // Resolved blur radius for this frame size. Scales the locked 35.0
    // value by `min(width, height) / 1080` so portrait 720p captures
    // get a proportionally lighter blur (still visually heavy — the
    // perceived blur on smaller frames remains "anonymising").
    private let resolvedBlurRadius: Double

    // Scratch 8-bit "keep source" mask. Allocated once and re-filled
    // per frame. Wrapped in a CGContext-style bitmap that we hand to
    // CIImage as a luminance source.
    private var keepSourceMaskData: UnsafeMutablePointer<UInt8>
    private let maskRowBytes: Int

    // Vision miss-rate tracking (Safe Mode completion wave,
    // 2026-05-21). `framesTotal` counts every frame the processor was
    // asked to handle; `framesMissed` counts frames where Vision
    // either threw, returned no faces, or yielded a degenerate
    // (zero-area) largest face. `missRate` is the ratio — used by the
    // Dart side to decide whether the capture should be rejected
    // (>5% threshold) or kept (gap frames soft-skipped).
    private(set) var framesTotal: Int = 0
    private(set) var framesMissed: Int = 0
    var missRate: Double {
        framesTotal == 0 ? 0.0 : Double(framesMissed) / Double(framesTotal)
    }

    // Low-confidence flag (2026-05-22). Set to true if, on any frame
    // processed, the two largest faces were within `lowConfidenceRatio`
    // of each other in area — meaning the subject vs bystander
    // discriminator could plausibly have picked the wrong face. Sticky:
    // once any frame triggers ambiguity we surface the flag to the
    // Dart side so the practitioner sees the tap-to-confirm UI
    // post-capture. The tap-to-confirm UI itself is a separate Flutter
    // PR; this processor only surfaces the signal.
    private(set) var lowConfidence: Bool = false

    init(width: Int, height: Int, orientation: CGImagePropertyOrientation = .up) {
        self.width = width
        self.height = height
        self.orientation = orientation
        self.faceRequest = VNDetectFaceRectanglesRequest()

        // Metal-backed CIContext if available, falls back to software.
        // Init options: disable colour management — we're working in
        // device-RGB throughout the pipeline.
        let options: [CIContextOption: Any] = [
            .workingColorSpace: NSNull(),
            .outputColorSpace: NSNull(),
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            self.ciContext = CIContext(mtlDevice: device, options: options)
        } else {
            self.ciContext = CIContext(options: options)
        }
        // CoreImage filter REGISTRATION names — not Swift class names.
        // `CIBlendWithMask` is correct; `CIBlendWithMaskFilter` is the
        // Swift class wrapper, NOT the registration string and returns
        // nil from `CIFilter(name:)`. PR #423 conflated the two and the
        // force-unwrap trapped at runtime (`EXC_BREAKPOINT/SIGTRAP`),
        // bricking the app via the `restoreQueue` boot-loop until the
        // demote-on-init guard in `conversion_service.dart` landed.
        guard let blurFilter = CIFilter(name: "CIGaussianBlur"),
              let blendFilter = CIFilter(name: "CIBlendWithMask") else {
            fatalError("Core Image filters CIGaussianBlur/CIBlendWithMask not available — iOS version mismatch?")
        }
        self.blurFilter = blurFilter
        self.blendFilter = blendFilter

        // Scale blur radius to the actual frame size. The locked 35.0
        // is for 1080p; on smaller frames the perceptual blur stays
        // similar by proportionally reducing radius.
        let minDim = Double(min(width, height))
        let scale = minDim / Self.baseSourceDim
        self.resolvedBlurRadius = Self.baseGaussianBlurRadius * max(0.25, scale)

        // Allocate the scratch keep-source mask buffer once. Single
        // channel (8-bit luminance) at frame resolution. Aligned to
        // 16 bytes via posix_memalign would be marginally better for
        // vImage but CIImage tolerates an unaligned pointer fine —
        // CoreImage copies the data on upload to GPU.
        self.maskRowBytes = width
        let bufSize = width * height
        self.keepSourceMaskData = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        self.keepSourceMaskData.initialize(repeating: 255, count: bufSize)
    }

    deinit {
        keepSourceMaskData.deinitialize(count: width * height)
        keepSourceMaskData.deallocate()
    }

    /// Coordinate-frame contract:
    ///
    /// The caller MUST hand us a `source` CVPixelBuffer whose pixel
    /// orientation matches the `orientation` passed to `init`. Vision
    /// returns face bounding boxes in normalized coords relative to
    /// the oriented (upright) image — `boundingBox * (width, height)`
    /// only lands in the right region of the buffer when buffer pixels
    /// and orientation agree. Similarly the `mask` (from
    /// `PersonSegmenter`) must be in the SAME coordinate space as
    /// `source` so anchor-vs-mask classification produces the right
    /// keep/blur decision.
    ///
    /// Photo path: `applySafeModeToPhoto` pre-renders the source
    /// UIImage upright via UIKit before allocating the pixel buffer,
    /// then constructs this processor with `orientation: .up`.
    /// Segmentation runs on the upright buffer without an orientation
    /// hint (PersonSegmenter's default), which produces a mask in
    /// the upright space — everyone agrees.
    ///
    /// Video path: the AVAssetReader hands us buffers in raw sensor
    /// orientation (typically landscape for iPhone portrait recording)
    /// and we pass the EXIF orientation derived from the track's
    /// `preferredTransform`. The PersonSegmenter mask is in the
    /// LANDSCAPE buffer's coords while Vision's bbox is in UPRIGHT
    /// normalized coords — they disagree. See latent-issue comment at
    /// the SafeModeProcessor construction site in the video pump for
    /// the planned follow-up (either pre-rotate the buffer or pass
    /// orientation through to PersonSegmenter + remap the bbox).
    func processFrame(
        source: CVPixelBuffer,
        mask: UnsafePointer<UInt8>?,
        into outBuffer: CVPixelBuffer
    ) -> Bool {
        // Every frame the caller asks us to handle counts toward the
        // total. A "miss" is any path that returns false — Vision threw,
        // returned no faces, or yielded a zero-area face. The Dart side
        // compares missRate against kSafeModeMaxMissRate to decide
        // whether to keep or reject the capture.
        framesTotal += 1

        // --- Find the largest face via Vision ---
        // Skip processing if Vision fails — caller will retry on the
        // next frame. The pump's progress doesn't depend on safe output
        // succeeding for every frame.
        do {
            // Pass orientation so Vision evaluates faces in their
            // upright frame. Without this hint Vision sees the raw
            // sensor orientation (typically landscape for iPhone
            // portrait video) and either yields zero detections or
            // detections with bboxes rotated 90deg from the human view.
            try sequenceHandler.perform(
                [faceRequest],
                on: source,
                orientation: orientation
            )
        } catch {
            framesMissed += 1
            return false
        }
        let observations = faceRequest.results ?? []
        if observations.isEmpty {
            framesMissed += 1
            return false
        }

        // Vision returns normalized rects in origin-bottom-left
        // coordinates. Pick the LARGEST by area = subject. Track the
        // second-largest so we can flag ambiguity.
        var bestArea: CGFloat = 0
        var secondBestArea: CGFloat = 0
        var subjectFace: CGRect = .zero
        for obs in observations {
            let r = obs.boundingBox
            let area = r.width * r.height
            if area > bestArea {
                secondBestArea = bestArea
                bestArea = area
                subjectFace = r
            } else if area > secondBestArea {
                secondBestArea = area
            }
        }
        if bestArea <= 0 {
            framesMissed += 1
            return false
        }

        // Ambiguity check — sticky across frames within this capture.
        // Once any frame's two largest faces were within ratio, we
        // surface the flag so the post-capture UX can prompt the
        // practitioner to confirm.
        if bestArea > 0,
           secondBestArea / bestArea >= Self.lowConfidenceRatio {
            lowConfidence = true
        }

        // --- Build subject "anchor" bbox in pixel coords ---
        // The face bbox alone would only cover the head; we extend it
        // downward (torso + legs) and outward (arms / hips). The
        // expansion factors are V1 heuristics — close enough to the
        // person silhouette that the segmentation mask inside the box
        // is overwhelmingly the subject's body.
        //
        // Normalized → pixel, with Y flipped (Vision = bottom-left
        // origin, BGRA buffer = top-left origin).
        let faceW = subjectFace.width * CGFloat(width)
        let faceH = subjectFace.height * CGFloat(height)
        let faceCx = (subjectFace.origin.x + subjectFace.width * 0.5) * CGFloat(width)
        // Vision Y is bottom-left; flip to top-left for our pixel grid.
        let faceTopY = (1.0 - subjectFace.origin.y - subjectFace.height) * CGFloat(height)
        let faceBotY = (1.0 - subjectFace.origin.y) * CGFloat(height)

        // Expand: face bbox grows horz/up/down by V1 constants. The
        // resulting "anchor" is a generous rectangle around the person
        // identified by face; mask pixels inside this box AND inside
        // the person-mask are the subject. Mask pixels outside this
        // box BUT inside the person mask are bystanders.
        let halfExpandedW = faceW * (1.0 + Self.subjectExpandHorz) * 0.5
        let expandUpPx = faceH * Self.subjectExpandUp
        let expandDownPx = faceH * Self.subjectExpandDown
        let anchorX0 = max(0, Int((faceCx - halfExpandedW).rounded(.down)))
        let anchorX1 = min(width, Int((faceCx + halfExpandedW).rounded(.up)))
        let anchorY0 = max(0, Int((faceTopY - expandUpPx).rounded(.down)))
        let anchorY1 = min(height, Int((faceBotY + expandDownPx).rounded(.up)))

        // --- Build "keep source" 8-bit mask ---
        // 255 = source shows (subject + background); 0 = blurred shows
        // (bystanders). When mask == nil we can't tell person from
        // background — pass everything through (no blur), but Vision
        // did succeed so this doesn't count as a miss.
        if mask == nil {
            // Pure passthrough — copy source to outBuffer and bail.
            return copySourceVerbatim(source: source, into: outBuffer)
        }
        let personMask = mask!

        // Build the keep-source mask: default 255 (keep source).
        // For each pixel where personMask >= 128, decide:
        //   inside anchor → 255 (subject, keep source)
        //   outside anchor → 0 (bystander, show blurred)
        // For each pixel where personMask < 128, leave at 255
        // (background, keep source).
        //
        // Tight inner loop — avoid per-pixel function calls.
        let ksm = keepSourceMaskData
        for y in 0..<height {
            let pmRow = personMask + y * width
            let ksmRow = ksm + y * maskRowBytes
            let inAnchorY = (y >= anchorY0 && y < anchorY1)
            for x in 0..<width {
                let pm = pmRow[x]
                if pm >= 128 {
                    let inAnchor = inAnchorY && x >= anchorX0 && x < anchorX1
                    ksmRow[x] = inAnchor ? 255 : 0
                } else {
                    ksmRow[x] = 255
                }
            }
        }

        // --- CoreImage composite ---
        // source CIImage, blurred CIImage, mask CIImage → blendWithMask.
        guard let sourceCI = ciImageFromBGRA(source) else {
            framesMissed += 1
            return false
        }
        // Crop blur output to source extent — CIGaussianBlur expands
        // the image bounds outward by the radius. Without this the
        // composite ends up with translucent edges around the frame.
        blurFilter.setValue(sourceCI, forKey: kCIInputImageKey)
        blurFilter.setValue(resolvedBlurRadius, forKey: kCIInputRadiusKey)
        guard let rawBlur = blurFilter.outputImage else {
            framesMissed += 1
            return false
        }
        let blurredCI = rawBlur.cropped(to: sourceCI.extent)

        guard let maskCI = ciImageFromGrayscale(
            data: ksm,
            width: width,
            height: height,
            rowBytes: maskRowBytes
        ) else {
            framesMissed += 1
            return false
        }

        // CIBlendWithMask: output = inputImage where mask is white,
        // inputBackgroundImage where mask is black. We want source
        // where mask is white (keep), blurred where mask is black
        // (bystander). Filter registration name is "CIBlendWithMask"
        // (no "Filter" suffix — see init guard above).
        blendFilter.setValue(sourceCI, forKey: kCIInputImageKey)
        blendFilter.setValue(blurredCI, forKey: kCIInputBackgroundImageKey)
        blendFilter.setValue(maskCI, forKey: kCIInputMaskImageKey)
        guard let outputCI = blendFilter.outputImage else {
            framesMissed += 1
            return false
        }

        // Render into outBuffer (BGRA). The output extent matches
        // source extent because we cropped the blur.
        ciContext.render(
            outputCI,
            to: outBuffer,
            bounds: sourceCI.extent,
            colorSpace: nil
        )
        return true
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// Wrap a BGRA `CVPixelBuffer` in a `CIImage`. Returns nil on
    /// allocation failure (rare).
    private func ciImageFromBGRA(_ pb: CVPixelBuffer) -> CIImage? {
        return CIImage(cvPixelBuffer: pb)
    }

    /// Wrap a single-channel 8-bit luminance buffer in a `CIImage`.
    /// CoreImage copies the data on upload, so the caller is free to
    /// re-fill `data` for the next frame after this call returns.
    private func ciImageFromGrayscale(
        data: UnsafeMutablePointer<UInt8>,
        width: Int,
        height: Int,
        rowBytes: Int
    ) -> CIImage? {
        // Copy the bitmap rather than aliasing the scratch buffer with
        // `bytesNoCopy(..., deallocator: .none)`. The Data wrapper would
        // outlive the next frame's re-fill of `keepSourceMaskData`,
        // creating a use-after-free if CoreImage held onto the CIImage
        // beyond the call (e.g. inside its render graph). One memcpy
        // per frame is negligible compared to the Vision/CoreImage
        // pass; correctness wins.
        let bitmap = Data(bytes: data, count: rowBytes * height)
        let fmt = CIFormat.R8
        let cs = CGColorSpaceCreateDeviceGray()
        // CIImage from raw bitmap. Y-flip is not needed; CIImage's
        // origin convention matches the buffer we built.
        return CIImage(
            bitmapData: bitmap,
            bytesPerRow: rowBytes,
            size: CGSize(width: width, height: height),
            format: fmt,
            colorSpace: cs
        )
    }

    /// Plain copy from source to destination BGRA buffer. Used when
    /// Vision detected a face but no segmentation mask was provided —
    /// we can't tell subject from bystander, so pass the frame through.
    private func copySourceVerbatim(
        source: CVPixelBuffer,
        into outBuffer: CVPixelBuffer
    ) -> Bool {
        CVPixelBufferLockBaseAddress(source, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard let srcBase = CVPixelBufferGetBaseAddress(source) else { return false }
        let srcRowBytes = CVPixelBufferGetBytesPerRow(source)

        CVPixelBufferLockBaseAddress(outBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(outBuffer, []) }
        guard let dstBase = CVPixelBufferGetBaseAddress(outBuffer) else { return false }
        let dstRowBytes = CVPixelBufferGetBytesPerRow(outBuffer)

        let srcPtr = srcBase.assumingMemoryBound(to: UInt8.self)
        let dstPtr = dstBase.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            memcpy(dstPtr + y * dstRowBytes, srcPtr + y * srcRowBytes, width * 4)
        }
        return true
    }
}
