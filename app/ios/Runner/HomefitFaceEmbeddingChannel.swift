import Flutter
import UIKit
import Vision
import CoreImage
import AVFoundation
import os.log

// MARK: - Self-trainer face embedding channel (PR #3 + PR #5, 2026-05-25)
//
// Native platform channel for the self-trainer self-verification flow.
// Wraps the existing on-device MobileFaceNet pipeline (already loaded by
// SafeModeProcessor / generateFaceEmbeddingFromJpg in
// VideoConverterChannel.swift) and exposes two high-level methods:
//
//   * `computeEmbeddingForImage(imagePath: String) -> [Float]`
//   * `verifyAgainstReference(mediaPath: String, referenceEmbedding: [Double])
//        -> { matched: Bool, distance: Double }`
//
// Pipeline:
//   1. Load the JPG/PNG via UIImage and pre-render upright via
//      UIGraphicsImageRenderer so Vision sees pixels in human-up
//      orientation (the same EXIF-respecting technique used by the
//      photo Safe Mode path and the v2 enrolment path in
//      VideoConverterChannel.swift). Caps the work buffer at 1920 px
//      max-dim because the embedding only needs a 112×112 face crop —
//      no point burning Vision pass on a 12 MP HEIC.
//   2. Run VNDetectFaceRectanglesRequest with orientation .up.
//   3. Zero faces → emit `nil` via FlutterResult(nil). The Dart wrapper
//      treats nil as "no face detected" and returns null to its caller
//      (does NOT throw).
//   4. Multiple faces → pick the LARGEST bbox. Unlike the
//      multi-reference enrolment path, self-verification doesn't need to
//      reject ambiguous frames — the practitioner is on a Settings
//      screen taking a deliberate selfie, not capturing wild gym
//      footage. The largest face is overwhelmingly likely to be the
//      practitioner.
//   5. Crop the largest face's bbox with a 20% pad on every side (same
//      as the Safe Mode v2 enrolment path).
//   6. Hand the CGImage crop to `MobileFaceNetEmbedder.shared.embed(face:)`,
//      which returns 2048 bytes (512 FP32 little-endian, L2-normalized).
//   7. Unpack the bytes into `[Float]` and return via FlutterResult.
//
// The model dimension is 512, NOT 192. The spec text in
// `docs/SELF_TRAINER_WAVE.md` § "Schema deltas" calls for vector(192) but
// the bundled MobileFaceNet.mlmodel emits 512-d. The schema migration in
// this same PR amends the column type to vector(512); see
// `supabase/migrations/20260525114912_register_self_face_rpc.sql` for
// the rationale.
//
// Channel name: `studio.homefit.face_embedding`
//
// Diagnostics: os_log against subsystem `studio.homefit.app`, category
// `self.face_embedding` so Carl can filter in Console.app.

@available(iOS 11.0, *)
final class HomefitFaceEmbeddingChannel: NSObject {
    private static let log = OSLog(
        subsystem: "studio.homefit.app",
        category: "self.face_embedding"
    )

    private let channel: FlutterMethodChannel

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(
            name: "studio.homefit.face_embedding",
            binaryMessenger: messenger
        )
        super.init()
        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
        os_log("HomefitFaceEmbeddingChannel initialised",
               log: Self.log, type: .info)
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "computeEmbeddingForImage":
            guard let args = call.arguments as? [String: Any],
                  let path = args["imagePath"] as? String else {
                result(FlutterError(
                    code: "INVALID_ARGS",
                    message: "Missing imagePath for computeEmbeddingForImage",
                    details: nil
                ))
                return
            }
            // All heavy lifting off the platform thread.
            DispatchQueue.global(qos: .userInitiated).async {
                self.compute(imagePath: path, result: result)
            }

        case "verifyAgainstReference":
            guard let args = call.arguments as? [String: Any],
                  let mediaPath = args["mediaPath"] as? String,
                  let refRaw = args["referenceEmbedding"] as? [Any] else {
                result(FlutterError(
                    code: "INVALID_ARGS",
                    message: "Missing mediaPath or referenceEmbedding for "
                           + "verifyAgainstReference",
                    details: nil
                ))
                return
            }
            // Coerce the reference embedding to [Float]. The Dart side
            // sends a `List<double>` which Flutter codec delivers as
            // [Double] on the wire (NSNumber-bridged). Accept either
            // Double or NSNumber elements; reject any non-numeric.
            var reference: [Float] = []
            reference.reserveCapacity(refRaw.count)
            for elem in refRaw {
                if let d = elem as? Double {
                    reference.append(Float(d))
                } else if let n = elem as? NSNumber {
                    reference.append(n.floatValue)
                } else {
                    result(FlutterError(
                        code: "INVALID_ARGS",
                        message: "referenceEmbedding contained non-numeric "
                               + "element of type \(type(of: elem))",
                        details: nil
                    ))
                    return
                }
            }
            // Threshold (cosine similarity floor) — caller may override
            // via `threshold`. Default 0.5 mirrors Safe Mode v2's historic
            // `kSafeModeV2FaceMatchThreshold` (see VideoConverterChannel.swift
            // line 3753) — the absolute gate the v2 discriminator used
            // before the relative pick-highest rule replaced it. 0.5 sits
            // safely above the typical bystander cosSim cluster
            // (0.15-0.40) and below same-person cosSim (worst observed
            // 0.25 for a single frontal reference; >= 0.55 with a well-
            // enrolled multi-reference set per `kSafeModeV2MultiRefThreshold`).
            // For self-verification we use a single frontal reference
            // (the public-profile selfie), so 0.5 is appropriately
            // conservative.
            let thresholdArg = (args["threshold"] as? Double) ?? 0.5
            // Sample-frame count for videos (ignored for photos which
            // are always a single sample). Caller may override; default
            // 3 evenly-spaced samples is the brief's spec.
            let framesArg = (args["sampleFrames"] as? Int) ?? 3
            DispatchQueue.global(qos: .userInitiated).async {
                self.verify(
                    mediaPath: mediaPath,
                    reference: reference,
                    threshold: thresholdArg,
                    sampleFrames: max(1, framesArg),
                    result: result
                )
            }

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Pipeline

    /// Compute the 512-d MobileFaceNet embedding for the JPG/PNG at
    /// `imagePath`. Returns `[Float]` via FlutterResult on success;
    /// returns `nil` on no-face (does NOT throw — the Dart wrapper
    /// treats nil as a benign "no face" outcome).
    ///
    /// Returns a FlutterError ONLY for genuine failures: file missing,
    /// decode failure, Vision pipeline failure, MobileFaceNet load /
    /// inference failure. Per `feedback_no_silent_fallbacks`, the Dart
    /// caller MUST surface these errors verbatim — never silently
    /// substitute a zero / random embedding.
    private func compute(imagePath: String, result: @escaping FlutterResult) {
        guard FileManager.default.fileExists(atPath: imagePath) else {
            os_log("compute: file missing %{public}@",
                   log: Self.log, type: .error, imagePath)
            DispatchQueue.main.async {
                result(FlutterError(
                    code: "FILE_MISSING",
                    message: "Image file does not exist: \(imagePath)",
                    details: nil
                ))
            }
            return
        }

        guard let uiImage = UIImage(contentsOfFile: imagePath),
              let cgImage = uiImage.cgImage else {
            os_log("compute: decode failed %{public}@",
                   log: Self.log, type: .error, imagePath)
            DispatchQueue.main.async {
                result(FlutterError(
                    code: "DECODE_FAILED",
                    message: "Could not decode image at \(imagePath)",
                    details: nil
                ))
            }
            return
        }

        // Pre-render upright. Mirrors the technique used by
        // generateFaceEmbeddingFromJpg in VideoConverterChannel.swift
        // (PR #430) — UIGraphicsImageRenderer + uiImage.draw(in:)
        // applies EXIF orientation automatically, yielding a top-left-
        // origin buffer that Vision can interpret with orientation: .up.
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

        // Cap at 1920 px max-dim. The embedding only needs a 112×112
        // crop; pre-shrinking keeps the Vision pass fast even on 12 MP
        // HEICs from modern iPhones.
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
            os_log("compute: upright render produced no cgImage",
                   log: Self.log, type: .error)
            DispatchQueue.main.async {
                result(FlutterError(
                    code: "RENDER_FAILED",
                    message: "UIGraphicsImageRenderer produced no cgImage",
                    details: nil
                ))
            }
            return
        }

        // Run face detection.
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(
            cgImage: uprightCG,
            orientation: .up,
            options: [:]
        )
        do {
            try handler.perform([request])
        } catch {
            os_log("compute: Vision request failed %{public}@",
                   log: Self.log, type: .error, error.localizedDescription)
            DispatchQueue.main.async {
                result(FlutterError(
                    code: "VISION_FAILED",
                    message: "Vision face detection failed: \(error.localizedDescription)",
                    details: nil
                ))
            }
            return
        }

        let observations = request.results ?? []
        if observations.isEmpty {
            // No face detected — benign outcome for the self-trainer
            // flow. Dart wrapper surfaces this as `null` and the UI
            // prompts the user to retake the photo. Per the brief, this
            // is NOT a thrown error.
            os_log("compute: no face detected in %{public}@",
                   log: Self.log, type: .info, imagePath)
            DispatchQueue.main.async {
                result(nil)
            }
            return
        }

        // Pick the LARGEST face by bbox area. For self-trainer
        // verification (deliberate selfie) the largest face is
        // overwhelmingly the subject; we do not reject multi-face
        // frames here as the multi-reference enrolment path does.
        var areas: [(rect: CGRect, area: CGFloat)] = observations.map {
            ($0.boundingBox, $0.boundingBox.width * $0.boundingBox.height)
        }
        areas.sort { $0.area > $1.area }
        let faceRect = areas[0].rect

        // Crop with 20% pad — same convention as Safe Mode v2 enrolment
        // (generateFaceEmbeddingFromJpg). Vision bboxes are normalised
        // and origin-bottom-left; convert to top-left pixel coordinates
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
            os_log("compute: CGImage.cropping returned nil",
                   log: Self.log, type: .error)
            DispatchQueue.main.async {
                result(FlutterError(
                    code: "CROP_FAILED",
                    message: "CGImage cropping returned nil for rect \(pixelCropRect)",
                    details: nil
                ))
            }
            return
        }

        // Run MobileFaceNet. Hard-fail per
        // `feedback_no_silent_fallbacks` — never return a zero / random
        // embedding when the model fails. The error string surfaces
        // verbatim in the Dart layer.
        do {
            let blob = try MobileFaceNetEmbedder.shared.embed(face: faceCrop)
            let floats = unpackFloats(from: blob)
            os_log("compute: success — %d floats",
                   log: Self.log, type: .info, floats.count)
            DispatchQueue.main.async {
                result(floats)
            }
        } catch let err as MobileFaceNetEmbedderError {
            let (code, message) = mapEmbedderError(err)
            os_log("compute: embedder error %{public}@ — %{public}@",
                   log: Self.log, type: .error, code, message)
            DispatchQueue.main.async {
                result(FlutterError(
                    code: code,
                    message: message,
                    details: nil
                ))
            }
        } catch {
            os_log("compute: unknown embedder error %{public}@",
                   log: Self.log, type: .error, error.localizedDescription)
            DispatchQueue.main.async {
                result(FlutterError(
                    code: "EMBEDDER_UNKNOWN",
                    message: "MobileFaceNet unknown error: \(error.localizedDescription)",
                    details: nil
                ))
            }
        }
    }

    // MARK: - Verification pipeline (PR #5)

    /// Verify whether the subject in [mediaPath] matches [reference]
    /// (the registered self-reference embedding).
    ///
    /// Branches on file extension:
    ///   * `.jpg` / `.jpeg` / `.png` / `.heic` — single-frame photo path.
    ///   * `.mp4` / `.mov` / `.m4v` — video path; samples [sampleFrames]
    ///     evenly across the timeline (excluding the first and last
    ///     frame to avoid boundary artefacts), runs face detection +
    ///     embedding per frame, takes the LARGEST face per frame, then
    ///     averages the per-frame embeddings (L2-renormalised) before
    ///     comparing against [reference].
    ///
    /// Result shape:
    ///   * `{ "matched": Bool, "distance": Double }` on success.
    ///   * `{ "matched": false, "distance": nil, "noFace": true }` when
    ///     no face was detected in any sampled frame — Dart treats this
    ///     as a conservative `self_verified = false` (per
    ///     `feedback_no_silent_fallbacks` we surface the reason so the
    ///     conversion service can decide whether to retry).
    ///   * FlutterError on hard failures (file missing, decode failure,
    ///     embedder load failure). Dart treats hard failures as
    ///     `self_verified = false` (conservative — unknown defaults to
    ///     unverified so the publish path charges credits by default).
    ///
    /// `distance` semantics: 1.0 - cosineSimilarity. Range [0, 2]; a
    /// match has small distance (close to 0). The cosineSimilarity helper
    /// returns dot product on L2-normalised vectors (range [-1, 1]); we
    /// convert to a distance so the threshold semantics match the
    /// brief's wording. Internally we still compare against the
    /// SIMILARITY threshold (matched iff sim >= threshold) — keeps
    /// parity with Safe Mode v2's `kSafeModeV2FaceMatchThreshold`
    /// convention.
    private func verify(
        mediaPath: String,
        reference: [Float],
        threshold: Double,
        sampleFrames: Int,
        result: @escaping FlutterResult
    ) {
        guard FileManager.default.fileExists(atPath: mediaPath) else {
            os_log("verify: file missing %{public}@",
                   log: Self.log, type: .error, mediaPath)
            DispatchQueue.main.async {
                result(FlutterError(
                    code: "FILE_MISSING",
                    message: "Media file does not exist: \(mediaPath)",
                    details: nil
                ))
            }
            return
        }
        // Sanity-check the reference dimension. The Dart side reads the
        // embedding from `practitioners.face_embedding` via the
        // `get_my_self_face_embedding()` RPC which returns 512 floats
        // (the bundled MobileFaceNet output). A mismatched dimension is
        // a programmer error worth surfacing, not silently coercing.
        if reference.count != MobileFaceNetEmbedder.embeddingDimension {
            os_log("verify: reference dim mismatch %d (expected %d)",
                   log: Self.log, type: .error,
                   reference.count, MobileFaceNetEmbedder.embeddingDimension)
            DispatchQueue.main.async {
                result(FlutterError(
                    code: "REFERENCE_DIM_MISMATCH",
                    message: "Reference embedding has \(reference.count) "
                           + "floats; expected "
                           + "\(MobileFaceNetEmbedder.embeddingDimension)",
                    details: nil
                ))
            }
            return
        }

        // Branch on file extension. Lower-cased so case variants
        // (`.JPG`, `.MP4`) don't slip through.
        let ext = (mediaPath as NSString).pathExtension.lowercased()
        let videoExts: Set<String> = ["mp4", "mov", "m4v"]
        let photoExts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif"]

        var embeddings: [[Float]] = []
        if videoExts.contains(ext) {
            embeddings = extractEmbeddingsFromVideo(
                path: mediaPath,
                sampleFrames: sampleFrames
            )
        } else if photoExts.contains(ext) {
            if let single = extractEmbeddingFromPhoto(path: mediaPath) {
                embeddings = [single]
            }
        } else {
            os_log("verify: unsupported file extension '%{public}@' for %{public}@",
                   log: Self.log, type: .error, ext, mediaPath)
            DispatchQueue.main.async {
                result(FlutterError(
                    code: "UNSUPPORTED_EXTENSION",
                    message: "Unsupported file extension '.\(ext)' — "
                           + "verifyAgainstReference accepts mp4/mov/m4v "
                           + "for videos and jpg/jpeg/png/heic/heif for photos.",
                    details: nil
                ))
            }
            return
        }

        if embeddings.isEmpty {
            // No face in any sampled frame. Benign outcome — Dart
            // stamps `self_verified = false`.
            os_log("verify: no face detected in any sample of %{public}@",
                   log: Self.log, type: .info, mediaPath)
            DispatchQueue.main.async {
                result([
                    "matched": false,
                    "distance": NSNull(),
                    "noFace": true,
                ])
            }
            return
        }

        // Average + L2-renormalise the per-frame embeddings. Averaging
        // smooths out single-frame jitter (motion blur, brief occlusion,
        // off-angle pose) — a single-frame mismatch shouldn't fail
        // verification if the rest of the video clearly contains the
        // subject.
        let avg = averageAndNormalise(embeddings: embeddings)
        let sim = cosineSimilarity(avg, reference)
        let distance = 1.0 - sim
        let matched = sim >= threshold
        os_log("verify: %d sample(s) → sim=%.4f matched=%{public}@",
               log: Self.log, type: .info,
               embeddings.count, sim, matched ? "true" : "false")
        DispatchQueue.main.async {
            result([
                "matched": matched,
                "distance": distance,
                "similarity": sim,
                "sampleCount": embeddings.count,
            ])
        }
    }

    /// Extract a single face embedding from a still-image path. Returns
    /// nil when no face is detected OR when the embedder throws — both
    /// are non-fatal in the verification context.
    private func extractEmbeddingFromPhoto(path: String) -> [Float]? {
        guard let uiImage = UIImage(contentsOfFile: path),
              let cgImage = uiImage.cgImage else {
            os_log("extractEmbeddingFromPhoto: decode failed %{public}@",
                   log: Self.log, type: .error, path)
            return nil
        }
        let upright = renderUpright(uiImage: uiImage, cgImage: cgImage)
        return embedLargestFace(in: upright)
    }

    /// Extract face embeddings from up to [sampleFrames] evenly-spaced
    /// frames in [path]. Empty-array return = no face detected in any
    /// sample, or asset load failure. We swallow per-frame errors so a
    /// single bad sample doesn't kill the whole verification.
    private func extractEmbeddingsFromVideo(
        path: String,
        sampleFrames: Int
    ) -> [[Float]] {
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)
        let duration = CMTimeGetSeconds(asset.duration)
        if !duration.isFinite || duration <= 0.05 {
            os_log("extractEmbeddingsFromVideo: invalid duration %.3fs for %{public}@",
                   log: Self.log, type: .error, duration, path)
            return []
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        if #available(iOS 18.0, *) {
            generator.dynamicRangePolicy = .forceSDR
        }

        // Sample N points evenly across the timeline, excluding the
        // first and last 10% (frequently boundary artefacts / hand on
        // camera / end-of-record blur). For sampleFrames=3 + duration=10s
        // this picks 2.5s / 5.0s / 7.5s.
        let n = max(1, sampleFrames)
        let inset = max(0.05, min(0.20, 0.1))  // 10% inset, clamped [5%, 20%]
        let usable = duration * (1.0 - 2.0 * inset)
        var sampleTimes: [CMTime] = []
        for i in 0..<n {
            let t: Double
            if n == 1 {
                t = duration * 0.5
            } else {
                let frac = (Double(i) + 0.5) / Double(n)  // 0.166, 0.5, 0.833 for n=3
                t = (duration * inset) + (usable * frac)
            }
            sampleTimes.append(CMTime(seconds: t, preferredTimescale: 600))
        }

        var out: [[Float]] = []
        for time in sampleTimes {
            do {
                let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
                if let emb = embedLargestFace(in: cgImage) {
                    out.append(emb)
                }
            } catch {
                // Per-frame failure is non-fatal. Could be a blank /
                // unreadable frame; the average over the remaining
                // samples is still informative.
                os_log("extractEmbeddingsFromVideo: copyCGImage failed at %.2fs — %{public}@",
                       log: Self.log, type: .info,
                       CMTimeGetSeconds(time), error.localizedDescription)
            }
        }
        return out
    }

    /// Run Vision face detection on [cgImage], pick the largest face by
    /// bbox area, crop with 20% pad (same convention as Safe Mode v2),
    /// run MobileFaceNet, return the 512 floats. Returns nil on no-face
    /// or on per-frame embedder failure (caller decides).
    private func embedLargestFace(in cgImage: CGImage) -> [Float]? {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(
            cgImage: cgImage,
            orientation: .up,
            options: [:]
        )
        do {
            try handler.perform([request])
        } catch {
            os_log("embedLargestFace: Vision failed %{public}@",
                   log: Self.log, type: .error, error.localizedDescription)
            return nil
        }
        let observations = request.results ?? []
        if observations.isEmpty { return nil }

        // Largest face by bbox area.
        var bestArea: CGFloat = -1.0
        var bestRect: CGRect = .zero
        for obs in observations {
            let r = obs.boundingBox
            let area = r.width * r.height
            if area > bestArea {
                bestArea = area
                bestRect = r
            }
        }

        // Crop with 20% pad. Vision normalised rect is origin-bottom-left;
        // convert to top-left pixel coordinates for CGImage.cropping.
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        let pad: CGFloat = 0.20
        let padW = bestRect.width * pad
        let padH = bestRect.height * pad
        let cropX = max(0, bestRect.origin.x - padW) * w
        let cropYBot = max(0, bestRect.origin.y - padH) * h
        let cropW = min(1.0, bestRect.width + 2 * padW) * w
        let cropH = min(1.0, bestRect.height + 2 * padH) * h
        let cropYTop = h - cropYBot - cropH
        let pixelRect = CGRect(
            x: cropX.rounded(.down),
            y: max(0, cropYTop.rounded(.down)),
            width: cropW.rounded(.up),
            height: cropH.rounded(.up)
        )
        if pixelRect.width < 8 || pixelRect.height < 8 { return nil }
        guard let faceCrop = cgImage.cropping(to: pixelRect) else { return nil }

        do {
            let blob = try MobileFaceNetEmbedder.shared.embed(face: faceCrop)
            return unpackFloats(from: blob)
        } catch {
            os_log("embedLargestFace: MobileFaceNet failed %{public}@",
                   log: Self.log, type: .error, error.localizedDescription)
            return nil
        }
    }

    /// EXIF-respecting upright re-render so Vision sees pixels in
    /// human-up orientation. Mirrors the technique used by
    /// `compute(imagePath:)` above and the v2 enrolment path in
    /// VideoConverterChannel.swift.
    private func renderUpright(uiImage: UIImage, cgImage: CGImage) -> CGImage {
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
        let upright = renderer.image { _ in
            uiImage.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return upright.cgImage ?? cgImage
    }

    /// Average the supplied embeddings element-wise and L2-renormalise
    /// the result so it lives on the unit hypersphere — matches the
    /// shape MobileFaceNet emits (and the reference embedding stored in
    /// `practitioners.face_embedding`).
    private func averageAndNormalise(embeddings: [[Float]]) -> [Float] {
        precondition(!embeddings.isEmpty,
                     "averageAndNormalise: called with empty input")
        let dim = embeddings[0].count
        var sum = [Float](repeating: 0, count: dim)
        for emb in embeddings {
            for i in 0..<dim {
                sum[i] += emb[i]
            }
        }
        let inv = 1.0 / Float(embeddings.count)
        for i in 0..<dim {
            sum[i] *= inv
        }
        // L2-renormalise. Defensive guard against a zero-magnitude
        // result (shouldn't happen with real face embeddings but cheap
        // to check).
        var sq: Float = 0
        for v in sum { sq += v * v }
        let mag = sqrtf(sq)
        if mag > 1e-9 {
            let invMag = 1.0 / mag
            for i in 0..<dim {
                sum[i] *= invMag
            }
        }
        return sum
    }

    /// Cosine similarity between two L2-normalised float vectors of
    /// equal length. Mirrors `MobileFaceNetEmbedder.cosineSimilarity`
    /// (which operates on Data blobs); this float-array twin lives here
    /// because the verify pipeline holds the averaged embedding as
    /// [Float] rather than re-packing it to Data just to compare.
    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        precondition(a.count == b.count,
                     "cosineSimilarity: dim mismatch \(a.count) vs \(b.count)")
        var dot: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
        }
        return Double(dot)
    }

    // MARK: - Helpers

    /// Unpack the embedder's 2048-byte Data (512 FP32 LE) into a Swift
    /// `[Float]` for the Flutter result channel. Length is always
    /// `MobileFaceNetEmbedder.embeddingDimension` (512).
    private func unpackFloats(from data: Data) -> [Float] {
        let count = MobileFaceNetEmbedder.embeddingDimension
        var out = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let src = raw.bindMemory(to: Float32.self)
            // Defensive: tolerate any byte count that is at least
            // `count` floats; we never accept a short embedding (the
            // embedder contract is exact-size or throw).
            let available = min(count, src.count)
            for i in 0..<available {
                out[i] = src[i]
            }
        }
        return out
    }

    private func mapEmbedderError(_ err: MobileFaceNetEmbedderError) -> (String, String) {
        switch err {
        case .modelNotBundled:
            return ("MODEL_NOT_BUNDLED",
                    "MobileFaceNet.mlmodel not found in app bundle")
        case .modelLoadFailed(let msg):
            return ("MODEL_LOAD_FAILED",
                    "MobileFaceNet load failed: \(msg)")
        case .preprocessingFailed(let msg):
            return ("PREPROCESS_FAILED",
                    "MobileFaceNet preprocessing failed: \(msg)")
        case .inferenceFailed(let msg):
            return ("INFERENCE_FAILED",
                    "MobileFaceNet inference failed: \(msg)")
        case .outputShapeMismatch(let msg):
            return ("OUTPUT_SHAPE_MISMATCH",
                    "MobileFaceNet output shape mismatch: \(msg)")
        }
    }
}
