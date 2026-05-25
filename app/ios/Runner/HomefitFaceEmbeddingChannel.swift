import Flutter
import UIKit
import Vision
import CoreImage
import os.log

// MARK: - Self-trainer face embedding channel (PR #3, 2026-05-25)
//
// Native platform channel for the self-trainer self-verification flow.
// Wraps the existing on-device MobileFaceNet pipeline (already loaded by
// SafeModeProcessor / generateFaceEmbeddingFromJpg in
// VideoConverterChannel.swift) and exposes a single high-level method:
//
//   * `computeEmbeddingForImage(imagePath: String) -> [Float]`
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
