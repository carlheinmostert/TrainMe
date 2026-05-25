//
//  MobileFaceNetEmbedder.swift
//  Runner
//
//  Safe Mode v2 (2026-05-23) — face-recognition subject discriminator.
//
//  Wraps the bundled MobileFaceNet.mlmodel and exposes a single
//  `embed(face:) throws -> Data` method that takes a 112×112-ish face
//  CGImage and produces a 2048-byte Data blob (512 FP32 little-endian
//  floats, L2-normalized).
//
//  The spec (`docs/specs/2026-05-23-safe-mode-face-rec.md`) originally
//  called for a 128-d / 512-byte embedding. The pre-trained MobileFaceNet
//  weights we sourced (from github.com/xuexingyu24/MobileFaceNet_Tutorial_Pytorch,
//  4.9MB PyTorch state-dict) train a 512-d head — converting to a 128-d
//  head would require retraining. We ship the 512-d output as-is: cosine
//  similarity works identically at any dimension, and the Supabase
//  `clients.face_embedding bytea` column is length-agnostic. The Dart side
//  treats the blob as opaque bytes; the Swift side knows the dimension.
//
//  Model contract
//  --------------
//  Input:  Float32 tensor shape (1, 3, 112, 112), channel order RGB,
//          pixel values normalized to [-1, 1] via (pixel - 127.5) / 128.0.
//          This is the InsightFace / ArcFace canonical normalization.
//  Output: Float32 tensor shape (1, 512), already L2-normalized
//          (the model's final layer is `torch.div(out, out.norm())`).
//          We re-normalize defensively in Swift to guard against
//          numerical drift from quantization or the CoreML graph.
//
//  Loading: lazy, on first call to `embed`. Hard-fails (throws
//  EmbedderError.modelLoadFailed) if the bundled .mlmodel cannot be
//  located or compiled. Per feedback_no_silent_fallbacks the UI surfaces
//  this as a hard error — we do not return random / zero vectors.

import Foundation
import CoreML
import CoreImage
import Vision
import Accelerate
import UIKit

enum MobileFaceNetEmbedderError: Error {
    case modelNotBundled
    case modelLoadFailed(String)
    case preprocessingFailed(String)
    case inferenceFailed(String)
    case outputShapeMismatch(String)
}

/// Singleton wrapper around the bundled MobileFaceNet CoreML model.
/// Lazy-loaded on first `embed(face:)` call. Thread-safe via a serial
/// queue around the (non-thread-safe) MLModel instance — the model is
/// fast enough on Neural Engine that a serial queue is the right
/// trade-off for simplicity.
final class MobileFaceNetEmbedder {

    static let shared = MobileFaceNetEmbedder()

    /// Dimension of the produced embedding. 512 for the current bundled
    /// MobileFaceNet weights. Exposed for callers that want to allocate
    /// the right-sized Data buffer.
    static let embeddingDimension: Int = 512

    /// Byte length of the produced Data blob (FP32 = 4 bytes/element).
    /// `embed(face:)` always returns a Data of exactly this length.
    static let embeddingByteLength: Int = embeddingDimension * 4

    /// Model version stamp written to `clients.face_embedding_model_version`.
    /// Bump this when swapping the model file so the offline-first sync
    /// path can decide whether stored embeddings are still valid.
    static let modelVersion: Int = 1

    // MARK: - Private state

    private let lock = DispatchQueue(label: "studio.homefit.mobilefacenet.embedder")
    private var model: MLModel?
    private var inputFeatureName: String?
    private var outputFeatureName: String?
    private var loadError: Error?

    private init() {}

    // MARK: - Public API

    /// Generate the embedding for a face crop. The crop should already be
    /// roughly tight around the face — caller is responsible for the
    /// VNDetectFaceRectangles → bbox-with-pad → crop dance. We resize to
    /// 112×112 here regardless.
    ///
    /// Returns: 2048-byte Data (512 FP32 little-endian floats, L2-normalized).
    /// Throws: MobileFaceNetEmbedderError on load / preprocess / inference failure.
    func embed(face: CGImage) throws -> Data {
        try loadIfNeeded()

        guard let model = model,
              let inputName = inputFeatureName,
              let outputName = outputFeatureName else {
            throw MobileFaceNetEmbedderError.modelLoadFailed("model handle nil after load")
        }

        // 1. Build a 112×112 RGB Float32 MLMultiArray normalized to [-1, 1].
        let multiArray = try preprocessToMultiArray(cgImage: face)

        // 2. Run inference.
        let provider: MLDictionaryFeatureProvider
        do {
            provider = try MLDictionaryFeatureProvider(
                dictionary: [inputName: MLFeatureValue(multiArray: multiArray)]
            )
        } catch {
            throw MobileFaceNetEmbedderError.inferenceFailed(
                "MLDictionaryFeatureProvider: \(error.localizedDescription)"
            )
        }

        var outputs: MLFeatureProvider!
        var inferenceError: Error?
        lock.sync {
            do {
                outputs = try model.prediction(from: provider)
            } catch {
                inferenceError = error
            }
        }
        if let e = inferenceError {
            throw MobileFaceNetEmbedderError.inferenceFailed(e.localizedDescription)
        }

        // 3. Extract the output MultiArray and pack to Data.
        guard let outputFeature = outputs.featureValue(for: outputName),
              let outputArray = outputFeature.multiArrayValue else {
            throw MobileFaceNetEmbedderError.outputShapeMismatch(
                "output \(outputName) missing or not a MultiArray"
            )
        }
        return try packEmbedding(outputArray)
    }

    /// Cosine similarity between two embedding blobs. Both inputs MUST
    /// be `embeddingByteLength` bytes long (FP32). Returns NaN if shapes
    /// don't match — caller should guard. Inputs are assumed L2-normalized
    /// (which the model output already is); cos_sim then = dot product.
    static func cosineSimilarity(_ a: Data, _ b: Data) -> Double {
        guard a.count == embeddingByteLength,
              b.count == embeddingByteLength else {
            return Double.nan
        }
        return a.withUnsafeBytes { aBuf -> Double in
            b.withUnsafeBytes { bBuf -> Double in
                let aPtr = aBuf.bindMemory(to: Float32.self)
                let bPtr = bBuf.bindMemory(to: Float32.self)
                var dot: Float = 0.0
                vDSP_dotpr(aPtr.baseAddress!, 1, bPtr.baseAddress!, 1, &dot, vDSP_Length(embeddingDimension))
                return Double(dot)
            }
        }
    }

    // MARK: - Subject pick (shared by v2 photo + v2 video paths)
    //
    // Shared "hybrid pick-highest" rule (per
    // `docs/specs/2026-05-23-safe-mode-face-rec.md` and the multi-reference
    // update `docs/specs/2026-05-24-safe-mode-v2-multi-reference-enrolment.md`)
    // factored out so the v2 photo (`applySafeModeV2ToPhoto`) and the v2
    // video state machine (`SafeModeV2VideoProcessor`) make the same
    // subject-vs-bystander decision frame for frame. Per-face cosSim is
    // taken as the MAX over every entry in `slots` — multi-reference
    // catches subjects at off-frontal angles whose frontal reference scores
    // poorly but whose three-quarter or profile reference matches well.

    /// Per-face cosine-similarity record handed back from `pickSubject`.
    /// `cosSim` is the MAX cosSim across every reference slot (see
    /// multi-reference spec). Indices align with the input `faces` array
    /// the caller passed in — callers can map back to their own per-face
    /// metadata (bbox, contour, etc.) by index.
    struct FaceMatch {
        public let index: Int
        public let cosSim: Double
        public init(index: Int, cosSim: Double) {
            self.index = index
            self.cosSim = cosSim
        }
    }

    /// Branch the hybrid pick-highest rule fell into. Surfaced for
    /// diagnostic logging — Carl's bench / device logs grep on this.
    enum PickBranch: String {
        case noFaces       = "no-faces"
        case soloFloor     = "solo-floor"
        case multiRelative = "multi-relative"
    }

    /// Result of `pickSubject(faces:slots:threshold:)`. `subjectIndex` is
    /// non-nil iff `subjectIdentified == true`; when nil the caller should
    /// run in no-subject mode (sharp silhouettes, only detected non-subject
    /// faces blurred — matches the v2 photo no-subject branch).
    struct SubjectPick {
        public let subjectIndex: Int?
        public let subjectIdentified: Bool
        public let bestSim: Double
        public let branch: PickBranch
        public let matches: [FaceMatch]
    }

    /// Pick the subject face from a set of pre-extracted per-face
    /// embeddings using the hybrid pick-highest rule:
    ///
    /// - **0 faces**  → no-subject mode (`branch = .noFaces`,
    ///                  `subjectIdentified = false`).
    /// - **1 face**   → solo branch. Trust practitioner intent UNLESS
    ///                  the single face's cosSim is below the solo-floor
    ///                  (`threshold`). Catches the bystander-alone-no-client
    ///                  edge case without rejecting legitimate solo
    ///                  selfies at sideways angles (Carl's worst was 0.25;
    ///                  random bystander faces typically cluster
    ///                  0.15–0.40; production default solo-floor 0.10).
    /// - **2+ faces** → relative pick. The face with the highest cosSim
    ///                  IS the subject; no absolute gate. Even if both
    ///                  faces score low, one of them is closer to the
    ///                  enrolled reference and that one wins.
    ///
    /// Per-face cosSim is the MAX across every entry in `slots` — the
    /// multi-reference rule. Caller is responsible for ensuring every
    /// element of `faceEmbeddings` is `embeddingByteLength` bytes (the
    /// embed() pipeline guarantees this); mismatched element sizes
    /// produce `Double.nan` cosSim values via `cosineSimilarity`.
    ///
    /// `slots` MUST contain at least one reference. With zero references
    /// the function returns no-subject mode unconditionally — the caller
    /// should have rejected the capture upstream (the `SafeModeService`
    /// subjectEmbedding ValueListenable gate).
    static func pickSubject(
        faceEmbeddings: [Data],
        slots: [Data],
        soloFloor: Double
    ) -> SubjectPick {
        // Per-face cosSim = max over reference slots. Records assemble
        // in the same order as `faceEmbeddings` so callers can index back
        // into their own bbox / contour arrays.
        var matches: [FaceMatch] = []
        matches.reserveCapacity(faceEmbeddings.count)
        for (i, faceEmbed) in faceEmbeddings.enumerated() {
            var bestRefSim: Double = -2.0
            for ref in slots {
                let s = cosineSimilarity(faceEmbed, ref)
                if s > bestRefSim { bestRefSim = s }
            }
            matches.append(FaceMatch(index: i, cosSim: bestRefSim))
        }

        // Pick the face with the highest cosSim across all references.
        var bestIdx: Int? = nil
        var bestSim: Double = -2.0
        for m in matches {
            if m.cosSim > bestSim {
                bestSim = m.cosSim
                bestIdx = m.index
            }
        }

        let subjectIdentified: Bool
        let branch: PickBranch
        if matches.isEmpty || slots.isEmpty {
            subjectIdentified = false
            branch = .noFaces
        } else if matches.count == 1 {
            // Solo branch — trust practitioner intent unless cosSim is
            // suspiciously low. The single-face threshold IS the solo
            // floor here.
            subjectIdentified = (bestSim >= soloFloor)
            branch = .soloFloor
        } else {
            // 2+ faces — relative pick, no absolute gate.
            subjectIdentified = true
            branch = .multiRelative
        }

        return SubjectPick(
            subjectIndex: subjectIdentified ? bestIdx : nil,
            subjectIdentified: subjectIdentified,
            bestSim: bestSim,
            branch: branch,
            matches: matches
        )
    }

    /// Variant of `pickSubject` for callers that have already computed
    /// the per-face MAX cosine similarity (i.e. they ran their own
    /// embed + cosSim loop inline). Skips MobileFaceNet entirely —
    /// applies only the hybrid pick-highest decision over the supplied
    /// matches.
    ///
    /// Used by:
    ///   - v2 photo path (`applySafeModeV2ToPhoto`) — keeps the embed
    ///     loop in place so the per-face crops + contour polygons live
    ///     on the existing `DetectedFace` struct.
    ///   - v2 video path (`SafeModeV2VideoProcessor`) — same reasoning;
    ///     the per-frame embed loop runs during seeding /
    ///     re-confirmation, then the pre-computed cosSim values are
    ///     handed to this picker.
    static func pickSubjectFromPrecomputed(
        matches: [FaceMatch],
        soloFloor: Double
    ) -> SubjectPick {
        var bestIdx: Int? = nil
        var bestSim: Double = -2.0
        for m in matches {
            if m.cosSim > bestSim {
                bestSim = m.cosSim
                bestIdx = m.index
            }
        }

        let subjectIdentified: Bool
        let branch: PickBranch
        if matches.isEmpty {
            subjectIdentified = false
            branch = .noFaces
        } else if matches.count == 1 {
            subjectIdentified = (bestSim >= soloFloor)
            branch = .soloFloor
        } else {
            subjectIdentified = true
            branch = .multiRelative
        }

        return SubjectPick(
            subjectIndex: subjectIdentified ? bestIdx : nil,
            subjectIdentified: subjectIdentified,
            bestSim: bestSim,
            branch: branch,
            matches: matches
        )
    }

    // MARK: - Loading

    private func loadIfNeeded() throws {
        var loadResult: Error?
        lock.sync {
            guard model == nil, loadError == nil else { return }
            do {
                try loadLocked()
            } catch {
                loadError = error
                loadResult = error
            }
        }
        if let e = loadError {
            throw e
        }
        if let e = loadResult {
            throw e
        }
    }

    /// Caller MUST hold `lock`. Loads MobileFaceNet.mlmodel from the
    /// main bundle (or its compiled .mlmodelc cousin), introspects
    /// the model description to find input + output feature names,
    /// and caches the MLModel instance.
    private func loadLocked() throws {
        // Xcode compiles .mlmodel → .mlmodelc at build time. The compiled
        // form is what ships in the .app bundle. Try the compiled name
        // first (production path); fall back to the .mlmodel URL only
        // for unusual setups (e.g. some test runners ship the raw file).
        var modelURL: URL?
        if let compiled = Bundle.main.url(forResource: "MobileFaceNet", withExtension: "mlmodelc") {
            modelURL = compiled
        } else if let raw = Bundle.main.url(forResource: "MobileFaceNet", withExtension: "mlmodel") {
            // Compile on the fly. Slow (~1-2s); production path uses the
            // precompiled .mlmodelc above. This branch exists only as
            // a defensive fallback for non-Xcode build environments.
            do {
                modelURL = try MLModel.compileModel(at: raw)
            } catch {
                throw MobileFaceNetEmbedderError.modelLoadFailed(
                    "MLModel.compileModel failed: \(error.localizedDescription)"
                )
            }
        }
        guard let url = modelURL else {
            throw MobileFaceNetEmbedderError.modelNotBundled
        }

        let config = MLModelConfiguration()
        // Allow the Neural Engine when available — MobileFaceNet is
        // small enough that ANE prep cost is amortized after one run.
        config.computeUnits = .all

        let loaded: MLModel
        do {
            loaded = try MLModel(contentsOf: url, configuration: config)
        } catch {
            throw MobileFaceNetEmbedderError.modelLoadFailed(error.localizedDescription)
        }

        // Inspect the model description to find the input + output
        // feature names. The CoreML graph the converter produced is
        // expected to expose exactly one input (a 112×112×3 tensor) and
        // one output (a 512-d vector), but we don't hard-code the names
        // so that swapping in a re-converted model with different
        // labels doesn't silently break the path.
        let desc = loaded.modelDescription
        guard desc.inputDescriptionsByName.count >= 1 else {
            throw MobileFaceNetEmbedderError.modelLoadFailed("model has no inputs")
        }
        guard desc.outputDescriptionsByName.count >= 1 else {
            throw MobileFaceNetEmbedderError.modelLoadFailed("model has no outputs")
        }
        // Prefer the first input named "input" / first output named
        // "embedding" / "var_..." if present, else fall back to dictionary
        // order (which is undefined but works for single-input/output models).
        let inputName = desc.inputDescriptionsByName.keys.first ?? "input"
        let outputName = desc.outputDescriptionsByName.keys.first ?? "embedding"

        self.model = loaded
        self.inputFeatureName = inputName
        self.outputFeatureName = outputName

        NSLog(
            "[MobileFaceNetEmbedder] loaded mlmodel — input=\(inputName) output=\(outputName) dim=\(Self.embeddingDimension)"
        )
    }

    // MARK: - Preprocessing

    /// Resize a face CGImage to 112×112, convert to RGB Float32, normalize
    /// to [-1, 1] via (pixel - 127.5) / 128.0, and pack into an
    /// MLMultiArray of shape (1, 3, 112, 112) in NCHW order.
    private func preprocessToMultiArray(cgImage: CGImage) throws -> MLMultiArray {
        let targetW = 112
        let targetH = 112

        // 1. Draw into a 112×112 RGBA8888 bitmap context. This pre-renders
        //    the source CGImage at the model's input resolution and gives
        //    us a contiguous byte buffer we can iterate.
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        // RGBA premultipliedLast (R, G, B, A byte order).
        let bitmapInfo: UInt32 =
            CGImageAlphaInfo.noneSkipLast.rawValue |
            CGBitmapInfo.byteOrderDefault.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: targetW,
            height: targetH,
            bitsPerComponent: 8,
            bytesPerRow: targetW * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw MobileFaceNetEmbedderError.preprocessingFailed("CGContext allocation failed")
        }
        // Use high-quality interpolation — model accuracy degrades with
        // poor resampling at 112×112. Cost is negligible (~0.5ms).
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))

        guard let dataPtr = ctx.data else {
            throw MobileFaceNetEmbedderError.preprocessingFailed("CGContext.data nil")
        }
        let pixels = dataPtr.assumingMemoryBound(to: UInt8.self)

        // 2. Allocate the MLMultiArray (NCHW float32) and populate.
        //    The MobileFaceNet PyTorch impl normalizes as
        //    `(pixel - 127.5) / 128.0` → [-1, 1] range.
        let multiArray: MLMultiArray
        do {
            multiArray = try MLMultiArray(
                shape: [1, 3, NSNumber(value: targetH), NSNumber(value: targetW)],
                dataType: .float32
            )
        } catch {
            throw MobileFaceNetEmbedderError.preprocessingFailed(
                "MLMultiArray init: \(error.localizedDescription)"
            )
        }

        let mlPtr = UnsafeMutablePointer<Float32>(OpaquePointer(multiArray.dataPointer))
        // Strides for an NCHW (1,3,112,112) Float32 array: H*W between
        // channels, W between rows.
        let channelStride = targetH * targetW
        let rowStride = targetW

        for y in 0..<targetH {
            let srcRowOffset = y * targetW * 4
            let dstRowOffset = y * rowStride
            for x in 0..<targetW {
                let srcPx = srcRowOffset + x * 4
                let r = Float32(pixels[srcPx + 0])
                let g = Float32(pixels[srcPx + 1])
                let b = Float32(pixels[srcPx + 2])
                let rn = (r - 127.5) / 128.0
                let gn = (g - 127.5) / 128.0
                let bn = (b - 127.5) / 128.0
                // NCHW layout: channel R first, then G, then B.
                mlPtr[0 * channelStride + dstRowOffset + x] = rn
                mlPtr[1 * channelStride + dstRowOffset + x] = gn
                mlPtr[2 * channelStride + dstRowOffset + x] = bn
            }
        }

        return multiArray
    }

    // MARK: - Output packing

    /// Extract the FP32 values from the output MultiArray (expected shape
    /// is roughly (1, 512) but we tolerate any shape that flattens to
    /// `embeddingDimension` elements), L2-normalize defensively, and pack
    /// into little-endian Data.
    private func packEmbedding(_ output: MLMultiArray) throws -> Data {
        let totalElements = output.count
        guard totalElements == Self.embeddingDimension else {
            throw MobileFaceNetEmbedderError.outputShapeMismatch(
                "expected \(Self.embeddingDimension) elements, got \(totalElements)"
            )
        }

        // CoreML MultiArray may be FP16 or FP32 depending on the converter.
        // We need FP32 for the Data blob — convert if necessary.
        var floats = [Float32](repeating: 0, count: totalElements)
        switch output.dataType {
        case .float32:
            let src = UnsafePointer<Float32>(OpaquePointer(output.dataPointer))
            for i in 0..<totalElements {
                floats[i] = src[i]
            }
        case .float16:
            // Two-byte half-floats. Use vImage to convert.
            let src = output.dataPointer.assumingMemoryBound(to: UInt8.self)
            var srcBuffer = vImage_Buffer(
                data: UnsafeMutableRawPointer(mutating: src),
                height: 1,
                width: vImagePixelCount(totalElements),
                rowBytes: totalElements * 2
            )
            var dstBuffer = vImage_Buffer(
                data: &floats,
                height: 1,
                width: vImagePixelCount(totalElements),
                rowBytes: totalElements * 4
            )
            let status = vImageConvert_Planar16FtoPlanarF(&srcBuffer, &dstBuffer, 0)
            if status != kvImageNoError {
                throw MobileFaceNetEmbedderError.outputShapeMismatch(
                    "vImage half→float conversion failed (\(status))"
                )
            }
        case .double:
            let src = UnsafePointer<Double>(OpaquePointer(output.dataPointer))
            for i in 0..<totalElements {
                floats[i] = Float32(src[i])
            }
        default:
            throw MobileFaceNetEmbedderError.outputShapeMismatch(
                "unsupported output dataType: \(output.dataType.rawValue)"
            )
        }

        // L2-normalize defensively. The PyTorch impl normalizes inside
        // the graph, but quantization / FP16 paths can introduce drift.
        var sumSq: Float = 0.0
        vDSP_svesq(floats, 1, &sumSq, vDSP_Length(totalElements))
        let norm = sqrt(sumSq)
        if norm > 1e-9 {
            var invNorm = 1.0 / norm
            vDSP_vsmul(floats, 1, &invNorm, &floats, 1, vDSP_Length(totalElements))
        }
        // If norm ≈ 0 something is badly wrong with the model output;
        // we still return the (zero-ish) vector so the caller can see
        // a low cosine similarity rather than throwing — the embedder
        // contract is "produce 2048 bytes", not "guarantee well-formed
        // embedding".

        // Pack as little-endian Data. Swift Float32 is already host-endian
        // on iOS (always little-endian on ARM64), so a raw byte copy suffices.
        return floats.withUnsafeBufferPointer { buf in
            Data(buffer: buf)
        }
    }
}
