import Flutter
import UIKit
import AVFoundation
import Accelerate
import Vision
import CoreVideo

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
/// 2026-05-03: TEMPORARILY DISABLED while we investigate device-side
/// reports of permanent stuck-in-converting on fresh captures after the
/// #198 v8 landing. Flip back to true once the underlying conversion
/// hang is reproduced + root-caused. The dilator code itself is clean
/// per RCA — disabling is precautionary while we get more diagnostics.
private let handDilationEnabled: Bool = false

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
            processingQueue.async { [weak self] in
                self?.convertVideo(
                    inputPath: inputPath,
                    outputPath: outputPath,
                    segmentedOutputPath: segmentedOutputPath,
                    maskOutputPath: maskOutputPath,
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
                // `formatDescriptions` is [Any] in AVFoundation's legacy
                // typing; the first entry is the track's canonical format.
                // Conditional-cast so we pass nil cleanly if the array is
                // empty (edge case — shouldn't happen for a real track).
                let formatHint: CMFormatDescription?
                if let first = audioTrack.formatDescriptions.first {
                    formatHint = (first as! CMFormatDescription)
                } else {
                    formatHint = nil
                }
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

        // Pre-allocate the line drawing processor for reuse across frames.
        let processor = LineDrawingProcessor(
            width: videoWidth,
            height: videoHeight,
            blurKernel: blurKernel,
            thresholdBlock: thresholdBlock,
            contrastLow: contrastLow
        )

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

                    // Process the frame into a line drawing, writing into outBuffer.
                    // When maskPtr != nil the processor erases (forces to white) any
                    // pixel whose mask value is below 128 — the background.
                    guard processor.processFrame(pixelBuffer, mask: maskPtr, into: outBuffer) else {
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
                            if sProc.processFrame(pixelBuffer, mask: maskPtr, into: segBuffer) {
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
            var finalImage: CGImage = cgImage
            if #available(iOS 15.0, *) {
                if let masked = Self.applySegmentationToThumbnail(
                    cgImage: cgImage,
                    cropToPerson: autoPick,
                    grayscale: grayscale
                ) {
                    finalImage = masked
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
                    result([
                        "success": true,
                        "outputPath": outputPath,
                        // Wave Hero — picked timeMs (motion-peak sample
                        // on autoPick:true; caller's verbatim timeMs on
                        // autoPick:false). Persisted by Dart callers as
                        // the Hero offset.
                        "timeMs": pickedTimeMsForResult,
                    ])
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

        // Optional person-centred crop. We compute the bounding box of
        // mask pixels above a mid-threshold (128) and pad by ~10% before
        // cropping. If the bbox is degenerate (no person detected, or
        // covers ~the whole frame already) we return the un-cropped image.
        if cropToPerson {
            let maskThreshold: UInt8 = 128
            var minX = width, minY = height, maxX = -1, maxY = -1
            for y in 0..<height {
                let row = y * width
                for x in 0..<width {
                    if softMaskPtr[row + x] >= maskThreshold {
                        if x < minX { minX = x }
                        if x > maxX { maxX = x }
                        if y < minY { minY = y }
                        if y > maxY { maxY = y }
                    }
                }
            }

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
                    // 10% pad around the bbox on each axis.
                    let padX = Int(Double(bboxW) * 0.10)
                    let padY = Int(Double(bboxH) * 0.10)
                    let cropMinX = max(0, minX - padX)
                    let cropMinY = max(0, minY - padY)
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
                        return cropped
                    }
                }
            }
        }

        return finalImage
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
