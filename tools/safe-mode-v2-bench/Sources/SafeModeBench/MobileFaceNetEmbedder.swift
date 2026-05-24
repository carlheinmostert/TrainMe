//
//  MobileFaceNetEmbedder.swift  (bench)
//
//  macOS-compatible mirror of
//  app/ios/Runner/MobileFaceNetEmbedder.swift. The iOS file imports
//  UIKit purely for namespace consistency with the rest of the channel;
//  the embedder itself only uses CoreML + CoreImage + Accelerate which
//  are identical on macOS. The model file (MobileFaceNet.mlmodel) is
//  copied byte-for-byte from the iOS target and ships as a SwiftPM
//  resource that's compiled to .mlmodelc at `swift build` time.
//
//  Contract is unchanged from iOS:
//   - Input:  Float32 (1,3,112,112) NCHW, RGB, normalized (px-127.5)/128.0.
//   - Output: Float32 (1,512), L2-normalized (we re-normalize defensively).
//   - embed(face:) returns a 2048-byte little-endian Data blob.
//   - cosineSimilarity(a,b) returns dot(a,b) since inputs are unit-norm.
//
//  Loading source: Bundle.module rather than Bundle.main, since SwiftPM
//  bundles resources per-target. Falls back to the raw .mlmodel +
//  on-the-fly compile (slow path) when the precompiled .mlmodelc is
//  missing — SwiftPM's resource pipeline produces the .mlmodelc by
//  default but the fallback exists for unusual checkout states.

import Foundation
import CoreML
import CoreImage
import Vision
import Accelerate

enum MobileFaceNetEmbedderError: Error {
    case modelNotBundled
    case modelLoadFailed(String)
    case preprocessingFailed(String)
    case inferenceFailed(String)
    case outputShapeMismatch(String)
}

final class MobileFaceNetEmbedder {

    static let shared = MobileFaceNetEmbedder()

    static let embeddingDimension: Int = 512
    static let embeddingByteLength: Int = embeddingDimension * 4
    static let modelVersion: Int = 1

    private let lock = DispatchQueue(label: "studio.homefit.mobilefacenet.embedder.bench")
    private var model: MLModel?
    private var inputFeatureName: String?
    private var outputFeatureName: String?
    private var loadError: Error?

    private init() {}

    /// Generate the 2048-byte (512 FP32) embedding for a face CGImage.
    /// Caller passes a roughly-tight face crop; we resize to 112x112 here.
    func embed(face: CGImage) throws -> Data {
        try loadIfNeeded()

        guard let model = model,
              let inputName = inputFeatureName,
              let outputName = outputFeatureName else {
            throw MobileFaceNetEmbedderError.modelLoadFailed("model handle nil after load")
        }

        let multiArray = try preprocessToMultiArray(cgImage: face)

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

        guard let outputFeature = outputs.featureValue(for: outputName),
              let outputArray = outputFeature.multiArrayValue else {
            throw MobileFaceNetEmbedderError.outputShapeMismatch(
                "output \(outputName) missing or not a MultiArray"
            )
        }
        return try packEmbedding(outputArray)
    }

    /// Cosine similarity between two L2-normalized embedding blobs.
    /// Returns dot product (== cosine because both are unit-norm).
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

    /// Caller MUST hold `lock`. Loads MobileFaceNet via Bundle.module
    /// (SwiftPM-per-target resources). Tries the precompiled .mlmodelc
    /// first; falls back to compiling the .mlmodel on the fly.
    private func loadLocked() throws {
        var modelURL: URL?
        if let compiled = Bundle.module.url(forResource: "MobileFaceNet", withExtension: "mlmodelc") {
            modelURL = compiled
        } else if let raw = Bundle.module.url(forResource: "MobileFaceNet", withExtension: "mlmodel") {
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
        config.computeUnits = .all

        let loaded: MLModel
        do {
            loaded = try MLModel(contentsOf: url, configuration: config)
        } catch {
            throw MobileFaceNetEmbedderError.modelLoadFailed(error.localizedDescription)
        }

        let desc = loaded.modelDescription
        guard desc.inputDescriptionsByName.count >= 1 else {
            throw MobileFaceNetEmbedderError.modelLoadFailed("model has no inputs")
        }
        guard desc.outputDescriptionsByName.count >= 1 else {
            throw MobileFaceNetEmbedderError.modelLoadFailed("model has no outputs")
        }
        let inputName = desc.inputDescriptionsByName.keys.first ?? "input"
        let outputName = desc.outputDescriptionsByName.keys.first ?? "embedding"

        self.model = loaded
        self.inputFeatureName = inputName
        self.outputFeatureName = outputName

        FileHandle.standardError.write(
            "[MobileFaceNetEmbedder] loaded — input=\(inputName) output=\(outputName) dim=\(Self.embeddingDimension)\n"
                .data(using: .utf8) ?? Data()
        )
    }

    // MARK: - Preprocessing

    private func preprocessToMultiArray(cgImage: CGImage) throws -> MLMultiArray {
        let targetW = 112
        let targetH = 112

        let colorSpace = CGColorSpaceCreateDeviceRGB()
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
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))

        guard let dataPtr = ctx.data else {
            throw MobileFaceNetEmbedderError.preprocessingFailed("CGContext.data nil")
        }
        let pixels = dataPtr.assumingMemoryBound(to: UInt8.self)

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
                mlPtr[0 * channelStride + dstRowOffset + x] = rn
                mlPtr[1 * channelStride + dstRowOffset + x] = gn
                mlPtr[2 * channelStride + dstRowOffset + x] = bn
            }
        }

        return multiArray
    }

    // MARK: - Output packing

    private func packEmbedding(_ output: MLMultiArray) throws -> Data {
        let totalElements = output.count
        guard totalElements == Self.embeddingDimension else {
            throw MobileFaceNetEmbedderError.outputShapeMismatch(
                "expected \(Self.embeddingDimension) elements, got \(totalElements)"
            )
        }

        var floats = [Float32](repeating: 0, count: totalElements)
        switch output.dataType {
        case .float32:
            let src = UnsafePointer<Float32>(OpaquePointer(output.dataPointer))
            for i in 0..<totalElements {
                floats[i] = src[i]
            }
        case .float16:
            let src = output.dataPointer.assumingMemoryBound(to: UInt8.self)
            var srcBuffer = vImage_Buffer(
                data: UnsafeMutableRawPointer(mutating: src),
                height: 1,
                width: vImagePixelCount(totalElements),
                rowBytes: totalElements * 2
            )
            // Wrap `floats` in a withUnsafeMutableBufferPointer so the
            // vImage_Buffer's `data` pointer outlives the conversion
            // call. The iOS sibling uses `&floats` which trips Swift 6's
            // [#TemporaryPointers] check.
            let status = floats.withUnsafeMutableBufferPointer { buf -> vImage_Error in
                var dstBuffer = vImage_Buffer(
                    data: UnsafeMutableRawPointer(buf.baseAddress!),
                    height: 1,
                    width: vImagePixelCount(totalElements),
                    rowBytes: totalElements * 4
                )
                return vImageConvert_Planar16FtoPlanarF(&srcBuffer, &dstBuffer, 0)
            }
            if status != kvImageNoError {
                throw MobileFaceNetEmbedderError.outputShapeMismatch(
                    "vImage half->float conversion failed (\(status))"
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

        var sumSq: Float = 0.0
        vDSP_svesq(floats, 1, &sumSq, vDSP_Length(totalElements))
        let norm = sqrt(sumSq)
        if norm > 1e-9 {
            var invNorm = 1.0 / norm
            vDSP_vsmul(floats, 1, &invNorm, &floats, 1, vDSP_Length(totalElements))
        }

        return floats.withUnsafeBufferPointer { buf in
            Data(buffer: buf)
        }
    }
}
