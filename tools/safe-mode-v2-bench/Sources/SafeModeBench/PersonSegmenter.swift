//
//  PersonSegmenter.swift  (bench)
//
//  macOS-compatible mirror of the `PersonSegmenter` and
//  `HandPoseDilator` classes from
//  app/ios/Runner/VideoConverterChannel.swift. Vision's
//  VNGeneratePersonSegmentationRequest and VNDetectHumanHandPoseRequest
//  are both available on macOS 12+ with identical APIs; we pin to
//  macOS 15 in the Package manifest.
//
//  The hand-pose dilator is included for byte-for-byte parity with the
//  iOS pipeline (the photo path uses generateMaskOneShot which augments
//  with hand dilation). Disable by flipping `handDilationEnabled` to
//  false at the top of this file — useful for isolating whether a stray
//  hand disc is what's filling the keepMask.

import Foundation
import Vision
import Accelerate
import CoreVideo

// MARK: - Hand-dilation tunables (mirrored from VideoConverterChannel.swift)

let handDilationEnabled: Bool = true
let handDilationRadiusFraction: Double = 0.10
let handDilationRadiusMin: Int = 60
let handDilationSpreadMultiplier: Double = 1.4
let handDilationConfidenceMin: Float = 0.20

// MARK: - PersonSegmenter

final class PersonSegmenter {
    let width: Int
    let height: Int

    private let sequenceHandler = VNSequenceRequestHandler()
    private let request: VNGeneratePersonSegmentationRequest
    private var upscaledMaskBuffer: vImage_Buffer
    private let handDilator: HandPoseDilator?

    init(width: Int, height: Int) {
        self.width = width
        self.height = height

        let req = VNGeneratePersonSegmentationRequest()
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

        self.handDilator = handDilationEnabled
            ? HandPoseDilator(width: width, height: height)
            : nil
    }

    deinit {
        upscaledMaskBuffer.data.deallocate()
    }

    private func augmentWithHandDilation(pixelBuffer: CVPixelBuffer) {
        guard let dilator = handDilator else { return }
        let dstPtr = upscaledMaskBuffer.data.assumingMemoryBound(to: UInt8.self)
        dilator.augment(mask: dstPtr, pixelBuffer: pixelBuffer)
    }

    /// One-shot variant used by the photo Safe Mode v2 path.
    func generateMaskOneShot(for pixelBuffer: CVPixelBuffer) -> UnsafePointer<UInt8>? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        do {
            try handler.perform([request])
        } catch {
            FileHandle.standardError.write(
                "PersonSegmenter: VNImageRequestHandler.perform failed: \(error.localizedDescription)\n"
                    .data(using: .utf8) ?? Data()
            )
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
            FileHandle.standardError.write(
                "PersonSegmenter: vImageScale_Planar8 failed with \(scaleErr)\n"
                    .data(using: .utf8) ?? Data()
            )
            return nil
        }
        augmentWithHandDilation(pixelBuffer: pixelBuffer)
        let dstPtr = upscaledMaskBuffer.data.assumingMemoryBound(to: UInt8.self)
        return UnsafePointer(dstPtr)
    }

    /// Count of pixels at or above the binary threshold in the mask
    /// buffer. Diagnostic helper — call after generateMaskOneShot to
    /// report what fraction of the frame Vision marked as person.
    func maskPositivePixelCount(threshold: UInt8 = 128) -> Int {
        let total = width * height
        let ptr = upscaledMaskBuffer.data.assumingMemoryBound(to: UInt8.self)
        var count = 0
        for i in 0..<total {
            if ptr[i] >= threshold { count += 1 }
        }
        return count
    }
}

// MARK: - HandPoseDilator

final class HandPoseDilator {
    let width: Int
    let height: Int

    private let sequenceHandler = VNSequenceRequestHandler()
    private let request: VNDetectHumanHandPoseRequest
    private let baseRadius: Int

    init(width: Int, height: Int) {
        self.width = width
        self.height = height

        let req = VNDetectHumanHandPoseRequest()
        req.maximumHandCount = 2
        self.request = req

        let shortSide = Swift.min(width, height)
        let fractional = Int((Double(shortSide) * handDilationRadiusFraction).rounded())
        self.baseRadius = Swift.max(handDilationRadiusMin, fractional)
    }

    func augment(mask: UnsafeMutablePointer<UInt8>, pixelBuffer: CVPixelBuffer) {
        do {
            try sequenceHandler.perform([request], on: pixelBuffer)
        } catch {
            return
        }
        guard let observations = request.results, !observations.isEmpty else {
            return
        }
        for obs in observations {
            paintHandDisc(observation: obs, mask: mask)
        }
    }

    private func paintHandDisc(
        observation: VNHumanHandPoseObservation,
        mask: UnsafeMutablePointer<UInt8>
    ) {
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
        let centerX = Int((cxNorm * Double(width)).rounded())
        let centerY = Int(((1.0 - cyNorm) * Double(height)).rounded())

        let spreadX = (maxX - minX) * Double(width)
        let spreadY = (maxY - minY) * Double(height)
        let spreadDiag = (spreadX * spreadX + spreadY * spreadY).squareRoot()
        let spreadRadius = Int((spreadDiag * 0.5 * handDilationSpreadMultiplier).rounded())
        let radius = Swift.max(baseRadius, spreadRadius)

        paintDisc(centerX: centerX, centerY: centerY, radius: radius, mask: mask)
    }

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
