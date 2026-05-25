//
//  SafeModeV2Pipeline.swift  (bench)
//
//  macOS-compatible mirror of `VideoConverterChannel.applySafeModeV2ToPhoto`
//  (app/ios/Runner/VideoConverterChannel.swift). The pipeline itself is
//  identical step-for-step; the only swaps are the UIKit-specific pieces
//  that don't exist on macOS:
//
//   - UIImage(contentsOfFile:) -> CGImageSourceCreateImageAtIndex
//   - UIImage.imageOrientation -> kCGImagePropertyOrientation read from
//     the CGImageSource (then a manual CGContext rotate/draw to upright)
//   - UIGraphicsImageRenderer -> bitmap CGContext.draw
//   - UIImage.jpegData -> CGImageDestination (kUTTypeJPEG)
//
//  The diagnostic block at the end of the pipeline prints every internal
//  decision (per-face cosSim, subject choice, mask coverage, blur
//  fraction) so a developer running the CLI sees what NSLog would
//  surface on device. This is the whole point of the bench tool —
//  iOS NSLog is invisible via `idevicesyslog` on the v2 wave so we need
//  a developer-machine surface that prints to stdout.

import Foundation
import CoreGraphics
import CoreImage
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import Vision
import Metal

struct SafeModeV2PipelineParams {
    var threshold: Double = 0.5
    var headWidthFactor: CGFloat = 2.0
    var headHeightFactor: CGFloat = 1.5
    var maxAreaFraction: Double = 0.35
    /// Max working dimension. Mirrors the iOS pipeline's 1920 clamp.
    var maxWorkDim: Int = 1920
}

struct SafeModeV2FaceReport {
    let index: Int
    let bboxPixels: CGRect
    let cosSim: Double
    let rank: Int  // 1 = highest cosSim
}

struct SafeModeV2PipelineReport {
    let width: Int
    let height: Int
    let faces: [SafeModeV2FaceReport]
    let threshold: Double
    let bestSim: Double
    let subjectIdentified: Bool
    let subjectIdx: Int?
    let maskPositivePixels: Int
    let totalPixels: Int
    let subjectComponentPixels: Int  // 0 when no subject identified
    let blurPixels: Int               // count of keepMask==0 pixels
    let outputPath: String
}

enum SafeModeV2PipelineError: Error {
    case sourceNotFound(String)
    case decodeFailed(String)
    case allocFailed(String)
    case visionFailed(String)
    case encodeFailed(String)
    case wrongEmbeddingSize(actual: Int, expected: Int)
}

enum SafeModeV2Pipeline {

    /// Run the v2 photo pipeline against `srcPath` with `subjectEmbeddings`
    /// (1–8 reference vectors) and `params`, writing the safe variant to
    /// `destPath`. Returns a `SafeModeV2PipelineReport` with every internal
    /// decision the iOS pipeline makes — that's the whole point of this
    /// tool.
    ///
    /// Multi-reference (2026-05-24) — the per-face cosSim is the MAX
    /// across every entry in `subjectEmbeddings`. Passing a one-element
    /// array reproduces the pre-multi-reference behaviour exactly
    /// (back-compat — verified by the bench tool's `--smoke-test`
    /// flag).
    static func run(
        srcPath: String,
        destPath: String,
        subjectEmbeddings: [Data],
        params: SafeModeV2PipelineParams
    ) throws -> SafeModeV2PipelineReport {

        guard FileManager.default.fileExists(atPath: srcPath) else {
            throw SafeModeV2PipelineError.sourceNotFound(srcPath)
        }
        guard !subjectEmbeddings.isEmpty else {
            throw SafeModeV2PipelineError.wrongEmbeddingSize(
                actual: 0,
                expected: MobileFaceNetEmbedder.embeddingByteLength
            )
        }
        for emb in subjectEmbeddings {
            guard emb.count == MobileFaceNetEmbedder.embeddingByteLength else {
                throw SafeModeV2PipelineError.wrongEmbeddingSize(
                    actual: emb.count,
                    expected: MobileFaceNetEmbedder.embeddingByteLength
                )
            }
        }

        // 1. Load the source CGImage + raw EXIF orientation via ImageIO.
        let srcURL = URL(fileURLWithPath: srcPath)
        guard let cgSource = CGImageSourceCreateWithURL(srcURL as CFURL, nil) else {
            throw SafeModeV2PipelineError.decodeFailed("CGImageSourceCreateWithURL failed")
        }
        guard let rawCG = CGImageSourceCreateImageAtIndex(cgSource, 0, nil) else {
            throw SafeModeV2PipelineError.decodeFailed("CGImageSourceCreateImageAtIndex failed")
        }
        let exifOrientation = readExifOrientation(cgSource: cgSource)

        let nativeCgW = rawCG.width
        let nativeCgH = rawCG.height
        guard nativeCgW > 0, nativeCgH > 0 else {
            throw SafeModeV2PipelineError.decodeFailed("Source has zero dimensions")
        }

        // displayW/H = the dimensions AFTER applying EXIF orientation
        // (the iOS pipeline's UIImage.imageOrientation handles this).
        let (displayW, displayH) = displayDimensionsAfterExifRotation(
            cgW: nativeCgW,
            cgH: nativeCgH,
            orientation: exifOrientation
        )

        let displayMax = max(displayW, displayH)
        let workScale = min(1.0, Double(params.maxWorkDim) / Double(displayMax))
        let width = max(1, Int((Double(displayW) * workScale).rounded()))
        let height = max(1, Int((Double(displayH) * workScale).rounded()))

        // 2. Render the source upright at (width, height) into a fresh
        //    BGRA CGContext. Mirrors UIGraphicsImageRenderer + uiImage.draw
        //    by applying the EXIF rotation transform before drawing.
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 =
            CGBitmapInfo.byteOrder32Little.rawValue |
            CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let uprightCtx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw SafeModeV2PipelineError.allocFailed("upright CGContext")
        }
        uprightCtx.interpolationQuality = .high
        drawUpright(
            cgImage: rawCG,
            into: uprightCtx,
            width: width,
            height: height,
            orientation: exifOrientation
        )
        guard let uprightCG = uprightCtx.makeImage() else {
            throw SafeModeV2PipelineError.allocFailed("upright makeImage")
        }

        // 3. Allocate srcBuf + dstBuf BGRA CVPixelBuffers (mirrors iOS).
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
            throw SafeModeV2PipelineError.allocFailed("srcBuf status=\(srcStatus)")
        }
        CVPixelBufferLockBaseAddress(srcBuf, [])
        guard let srcBase = CVPixelBufferGetBaseAddress(srcBuf) else {
            CVPixelBufferUnlockBaseAddress(srcBuf, [])
            throw SafeModeV2PipelineError.allocFailed("srcBuf base addr")
        }
        let srcRowBytes = CVPixelBufferGetBytesPerRow(srcBuf)
        guard let srcCtx = CGContext(
            data: srcBase, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: srcRowBytes,
            space: colorSpace, bitmapInfo: bitmapInfo
        ) else {
            CVPixelBufferUnlockBaseAddress(srcBuf, [])
            throw SafeModeV2PipelineError.allocFailed("srcBuf CGContext")
        }
        srcCtx.draw(uprightCG, in: CGRect(x: 0, y: 0, width: width, height: height))
        CVPixelBufferUnlockBaseAddress(srcBuf, [])

        var dstBufOut: CVPixelBuffer?
        let dstStatus = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &dstBufOut
        )
        guard dstStatus == kCVReturnSuccess, let dstBuf = dstBufOut else {
            throw SafeModeV2PipelineError.allocFailed("dstBuf status=\(dstStatus)")
        }

        // 4. Face detection + landmarks on the upright CG. Switched from
        //    VNDetectFaceRectanglesRequest to VNDetectFaceLandmarksRequest
        //    so we get the face contour polygon (used by the head-oval
        //    painter below — replaces the rectangular bbox sweep).
        let faceReq = VNDetectFaceLandmarksRequest()
        let visionHandler = VNImageRequestHandler(
            cgImage: uprightCG, orientation: .up, options: [:]
        )
        do {
            try visionHandler.perform([faceReq])
        } catch {
            throw SafeModeV2PipelineError.visionFailed(
                "VNDetectFaceLandmarksRequest: \(error.localizedDescription)"
            )
        }
        let observations = faceReq.results ?? []

        // 5. Embed every face + compute cosSim.
        struct DetectedFace {
            let normalizedRect: CGRect
            let pixelRectTopLeft: CGRect
            let centerXPx: Int
            let centerYPx: Int
            let cosSim: Double
            /// Face-contour landmark polygon in upright pixel coords
            /// (top-left origin). nil when Vision returned no landmarks
            /// for this face (rare; fall back to bbox-only painting).
            let contourPolygonPx: [CGPoint]?
        }

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
            if pixelRect.width < 8 || pixelRect.height < 8 { continue }
            guard let crop = uprightCG.cropping(to: pixelRect) else { continue }
            var sim: Double = -1.0
            do {
                let embed = try MobileFaceNetEmbedder.shared.embed(face: crop)
                // Multi-reference (2026-05-24): take the MAX cosSim
                // across all enrolled reference embeddings. Identical
                // semantics to the iOS pipeline; with a one-element
                // reference array this degenerates to the original
                // single-reference path byte-for-byte.
                var bestRefSim: Double = -2.0
                for ref in subjectEmbeddings {
                    let s = MobileFaceNetEmbedder.cosineSimilarity(embed, ref)
                    if s > bestRefSim { bestRefSim = s }
                }
                sim = bestRefSim
            } catch {
                FileHandle.standardError.write(
                    "[SafeMode v2] face embed failed for one bbox: \(error.localizedDescription)\n"
                        .data(using: .utf8) ?? Data()
                )
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

        // 6. Pick subject — hybrid pick-highest rule.
        //
        //    0 faces → no-subject mode (defensive sharp).
        //    1 face  → solo branch. Trust practitioner intent unless
        //              cosSim is below the solo-floor (params.threshold,
        //              repurposed from absolute-threshold to solo-floor
        //              under the 2026-05-24 workshop rule). Default 0.10
        //              catches the bystander-alone-no-client edge case
        //              without rejecting legitimate solo selfies.
        //    2+      → relative pick. Highest cosSim is the subject. No
        //              absolute gate — even if both faces score low, one
        //              is closer to the enrolled embedding and wins.
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
            subjectIdentified = (bestSim >= params.threshold)
            branchReason = "solo-floor"
        } else {
            subjectIdentified = true
            branchReason = "multi-relative"
        }
        _ = branchReason  // available for future report fields

        // 7. Run PersonSegmenter, build keepMask.
        let segmenter = PersonSegmenter(width: width, height: height)
        let maskPtr = segmenter.generateMaskOneShot(for: srcBuf)
        let maskPositivePx: Int = (maskPtr != nil)
            ? segmenter.maskPositivePixelCount(threshold: 128)
            : 0

        let totalPx = width * height
        let keepMask = UnsafeMutablePointer<UInt8>.allocate(capacity: totalPx)
        defer {
            keepMask.deinitialize(count: totalPx)
            keepMask.deallocate()
        }
        keepMask.initialize(repeating: 255, count: totalPx)

        var subjectComponentPixels = 0

        if subjectIdentified, let subjI = subjectIdx, let mask = maskPtr {
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

            for i in 0..<totalPx {
                if subjectComponent[i] == 1 { subjectComponentPixels += 1 }
            }

            for y in 0..<height {
                let rowOffset = y * width
                for x in 0..<width {
                    let i = rowOffset + x
                    if mask[i] >= 128 && subjectComponent[i] == 0 {
                        keepMask[i] = 0
                    }
                }
            }

            for (i, f) in faces.enumerated() where i != subjI {
                paintHeadExpansion(
                    keepMask: keepMask,
                    width: width,
                    height: height,
                    pixelRect: f.pixelRectTopLeft,
                    contourPolygonPx: f.contourPolygonPx,
                    headWidthFactor: params.headWidthFactor,
                    headHeightFactor: params.headHeightFactor,
                    maxAreaFraction: params.maxAreaFraction,
                    segmentationMask: mask,
                    subjectComponent: subjectComponent
                )
            }
        } else {
            // No-subject mode — bystander pixels can still be intersected
            // against the segmentation mask (so we don't paint background
            // pixels inside the bbox), but there's no subject to exclude.
            // Pass nil for the subject component; the painter treats that
            // as "no subject to protect" (every mask-positive pixel inside
            // the bbox is fair game).
            for f in faces {
                paintHeadExpansion(
                    keepMask: keepMask,
                    width: width,
                    height: height,
                    pixelRect: f.pixelRectTopLeft,
                    contourPolygonPx: f.contourPolygonPx,
                    headWidthFactor: params.headWidthFactor,
                    headHeightFactor: params.headHeightFactor,
                    maxAreaFraction: params.maxAreaFraction,
                    segmentationMask: maskPtr,
                    subjectComponent: nil
                )
            }
        }

        // 8. Count blur pixels (keepMask == 0) for the report.
        var blurPixels = 0
        for i in 0..<totalPx {
            if keepMask[i] == 0 { blurPixels += 1 }
        }

        // 9. Composite via CIBlendWithMask (same as iOS).
        let minDim = Double(min(width, height))
        let blurRadius = 35.0 * max(0.25, minDim / 1080.0)

        // Disable Core Image colour management — we're working in
        // device-RGB throughout. Without the NSNull working/output
        // options, the default CIContext working colorspace is
        // `extendedLinearSRGB` (linear-light). Combined with `colorSpace:
        // nil` on the render call (meaning "do not color-match the
        // output"), CoreImage writes LINEAR bytes into the BGRA dstBuf,
        // and the downstream JPG encoder interprets those bytes as
        // gamma-encoded sRGB — a ~2x perceptual darkening. The v1 video
        // SafeModeProcessor (the stable proven path) uses the NSNull
        // block; mirror it byte-for-byte here. Confirmed via this bench
        // tool 2026-05-25: source mean luma 127.75, post-render 79.88
        // (~39% darker) until the NSNull options were reinstated.
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
            throw SafeModeV2PipelineError.encodeFailed("CIFilter init")
        }

        let sourceCI = CIImage(cvPixelBuffer: srcBuf)
        blurFilter.setValue(sourceCI, forKey: kCIInputImageKey)
        blurFilter.setValue(blurRadius, forKey: kCIInputRadiusKey)
        guard let rawBlur = blurFilter.outputImage else {
            throw SafeModeV2PipelineError.encodeFailed("CIGaussianBlur output")
        }
        let blurredCI = rawBlur.cropped(to: sourceCI.extent)

        // Mask is a raw R8 luminance buffer — no gamma conversion at any
        // step. `colorSpace: nil` keeps CoreImage from re-interpreting the
        // 0/255 bytes through sRGB (which on macOS subtly darkened the
        // whole composite — the iOS pipeline matches this by using the
        // same nil colorspace + NSNull working colorspace).
        let maskBytes = Data(bytes: keepMask, count: totalPx)
        let maskCI = CIImage(
            bitmapData: maskBytes,
            bytesPerRow: width,
            size: CGSize(width: width, height: height),
            format: .R8,
            colorSpace: CGColorSpaceCreateDeviceGray()
        )

        // Pass the keepMask straight to CIBlendWithMask — no feather.
        // Brief 1's 10px Gaussian feather interacted badly with the
        // CIBlendWithMask compositor and produced whole-frame blur on
        // any frame where the mask had non-trivial structure.
        let featheredMask: CIImage = maskCI

        blendFilter.setValue(sourceCI, forKey: kCIInputImageKey)
        blendFilter.setValue(blurredCI, forKey: kCIInputBackgroundImageKey)
        blendFilter.setValue(featheredMask, forKey: kCIInputMaskImageKey)
        guard let outputCI = blendFilter.outputImage else {
            throw SafeModeV2PipelineError.encodeFailed("CIBlendWithMask output")
        }
        ciContext.render(outputCI, to: dstBuf, bounds: sourceCI.extent, colorSpace: nil)

        // 10. Encode dstBuf -> JPG via CGImageDestination.
        try encodeDstAsJpg(
            dstBuf: dstBuf,
            width: width,
            height: height,
            colorSpace: colorSpace,
            bitmapInfo: bitmapInfo,
            destPath: destPath
        )

        // 11. Rank faces by cosSim for the report.
        let sortedByCos = faces.enumerated().sorted { $0.element.cosSim > $1.element.cosSim }
        var rankByIdx = [Int: Int]()
        for (rankZero, pair) in sortedByCos.enumerated() {
            rankByIdx[pair.offset] = rankZero + 1
        }
        let faceReports: [SafeModeV2FaceReport] = faces.enumerated().map { (i, f) in
            SafeModeV2FaceReport(
                index: i,
                bboxPixels: f.pixelRectTopLeft,
                cosSim: f.cosSim,
                rank: rankByIdx[i] ?? 0
            )
        }

        return SafeModeV2PipelineReport(
            width: width,
            height: height,
            faces: faceReports,
            threshold: params.threshold,
            bestSim: bestSim,
            subjectIdentified: subjectIdentified,
            subjectIdx: subjectIdentified ? subjectIdx : nil,
            maskPositivePixels: maskPositivePx,
            totalPixels: totalPx,
            subjectComponentPixels: subjectComponentPixels,
            blurPixels: blurPixels,
            outputPath: destPath
        )
    }

    // MARK: - EXIF orientation handling
    //
    // The iOS pipeline relies on UIImage.imageOrientation +
    // UIGraphicsImageRenderer to render upright. macOS has neither;
    // we read the EXIF orientation manually from CGImageSource and
    // apply the equivalent affine transform before drawing.

    private static func readExifOrientation(cgSource: CGImageSource) -> CGImagePropertyOrientation {
        guard let props = CGImageSourceCopyPropertiesAtIndex(cgSource, 0, nil) as? [CFString: Any],
              let rawOrient = props[kCGImagePropertyOrientation] as? UInt32,
              let orient = CGImagePropertyOrientation(rawValue: rawOrient) else {
            return .up
        }
        return orient
    }

    /// Apply the EXIF orientation as an affine transform to `ctx` and
    /// then draw `cgImage` at the rotated/mirrored target. Equivalent to
    /// UIGraphicsImageRenderer + uiImage.draw(in:) on iOS.
    private static func drawUpright(
        cgImage: CGImage,
        into ctx: CGContext,
        width: Int,
        height: Int,
        orientation: CGImagePropertyOrientation
    ) {
        // The source CGImage has dimensions (cgW, cgH). After the EXIF
        // rotation, the displayed dimensions become (width, height).
        // We apply the inverse of the EXIF transform so the drawn image
        // ends up "upright" in the destination.
        let w = CGFloat(width)
        let h = CGFloat(height)
        ctx.saveGState()
        switch orientation {
        case .up:
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        case .upMirrored:
            ctx.translateBy(x: w, y: 0)
            ctx.scaleBy(x: -1, y: 1)
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        case .down:
            ctx.translateBy(x: w, y: h)
            ctx.rotate(by: .pi)
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        case .downMirrored:
            ctx.translateBy(x: 0, y: h)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        case .leftMirrored:
            ctx.translateBy(x: 0, y: h)
            ctx.scaleBy(x: 1, y: -1)
            ctx.rotate(by: -.pi / 2)
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: h, height: w))
        case .left:
            // EXIF orientation 8 — needs 90° CCW rotation visually.
            // Canonical: translate (w, 0) + rotate +π/2.
            ctx.translateBy(x: w, y: 0)
            ctx.rotate(by: .pi / 2)
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: h, height: w))
        case .rightMirrored:
            ctx.translateBy(x: w, y: h)
            ctx.scaleBy(x: -1, y: 1)
            ctx.rotate(by: .pi / 2)
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: h, height: w))
        case .right:
            // EXIF orientation 6 — the stored 0th row is the visual right
            // edge. Need to rotate the stored landscape 90° CW visually
            // to display upright. Canonical transform per Apple's Image
            // I/O sample code: translate (0, h) + rotate -π/2.
            // (Prior code used (w, 0) + +π/2 which produced an upside-down
            // output — 180° wrong. Confirmed via Carl's TP2 photos.)
            ctx.translateBy(x: 0, y: h)
            ctx.rotate(by: -.pi / 2)
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: h, height: w))
        }
        ctx.restoreGState()
    }

    private static func displayDimensionsAfterExifRotation(
        cgW: Int,
        cgH: Int,
        orientation: CGImagePropertyOrientation
    ) -> (Int, Int) {
        switch orientation {
        case .left, .right, .leftMirrored, .rightMirrored:
            return (cgH, cgW)
        default:
            return (cgW, cgH)
        }
    }

    // MARK: - JPG encoding (CGImageDestination replaces UIImage.jpegData)

    private static func encodeDstAsJpg(
        dstBuf: CVPixelBuffer,
        width: Int,
        height: Int,
        colorSpace: CGColorSpace,
        bitmapInfo: UInt32,
        destPath: String
    ) throws {
        CVPixelBufferLockBaseAddress(dstBuf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(dstBuf, .readOnly) }

        guard let dstBase = CVPixelBufferGetBaseAddress(dstBuf) else {
            throw SafeModeV2PipelineError.encodeFailed("dstBuf base addr")
        }
        let dstRowBytes = CVPixelBufferGetBytesPerRow(dstBuf)
        guard let outCtx = CGContext(
            data: dstBase, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: dstRowBytes,
            space: colorSpace, bitmapInfo: bitmapInfo
        ) else {
            throw SafeModeV2PipelineError.encodeFailed("dst CGContext")
        }
        guard let outCG = outCtx.makeImage() else {
            throw SafeModeV2PipelineError.encodeFailed("dst makeImage")
        }

        // Ensure parent dir exists.
        let destURL = URL(fileURLWithPath: destPath)
        try? FileManager.default.createDirectory(
            at: destURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        guard let dest = CGImageDestinationCreateWithURL(
            destURL as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw SafeModeV2PipelineError.encodeFailed("CGImageDestination create")
        }
        let opts: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.9
        ]
        CGImageDestinationAddImage(dest, outCG, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw SafeModeV2PipelineError.encodeFailed("CGImageDestination finalize")
        }
    }

    // MARK: - Flood fill (identical to iOS)

    static func floodFillBinary(
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

        guard seedX >= 0, seedX < width, seedY >= 0, seedY < height else {
            return visited
        }
        let seedIdx = seedY * width + seedX
        if mask[seedIdx] < threshold {
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

    // MARK: - Head-region painter (identical to iOS)
    //
    // The painter no longer treats the head-expanded bbox as an
    // unconditional "blur everything inside this rectangle" sweep. Three
    // changes vs the original v2 wave:
    //
    //   1. Inside the bbox we only blur pixels that segmentation marked
    //      as part of a person silhouette AND that aren't part of the
    //      subject component. Background and subject pixels behind the
    //      bystander are preserved.
    //   2. If the face's contour landmark polygon is available, we use
    //      it (expanded outward ~25% from face center to cover hair /
    //      ears / chin) as the inner clipping shape instead of the raw
    //      bbox — the blur reads as "obscured person" instead of
    //      "blurry box".
    //   3. The maxAreaFraction defensive clamp is preserved; with the
    //      contour-polygon path it's effectively a no-op for typical
    //      poses but kicks in for the close-up-selfie case.
    //
    // `segmentationMask` may be nil if segmentation failed; in that case
    // the original "paint the whole bbox" behaviour is restored (worst
    // case: regresses to the old visual but the photo still gets blurred,
    // which is the load-bearing privacy guarantee).
    // `subjectComponent` may be nil for the no-subject mode — the
    // painter then treats every mask-positive pixel inside the shape as
    // a bystander pixel.

    static func paintHeadExpansion(
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

        // Compute the inner clipping shape's bbox (polygon or expanded
        // face bbox). When a polygon is available we clip to its
        // axis-aligned bounding box and then point-in-polygon test each
        // pixel; otherwise we fall back to the expanded face bbox.
        let polygon: [CGPoint]? = contourPolygonPx
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
        // the polygon (in the bbox-fallback region, or in the bbox-only
        // path when Vision didn't return landmarks) the
        // subject-component exclusion remains active so we still
        // protect the client when a bystander stands in front.
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
                    // No segmentation — fall back to unconditional paint.
                    keepMask[i] = 0
                }
            }
        }
    }

    /// Build the face-contour polygon in upright pixel coords (top-left
    /// origin). Uses VNFaceLandmarks2D.faceContour and expands every
    /// point outward by `outwardExpansionFactor` from the face's bbox
    /// center to cover hair / chin / ears (Vision's contour traces the
    /// jawline tightly; without expansion the polygon misses the hairline).
    ///
    /// Returns nil when Vision didn't return landmarks for this face, or
    /// when the contour has < 3 points — caller falls back to bbox-only
    /// painting in that case.
    static func faceContourPolygonPx(
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
        // the top-left convention the rest of the pipeline uses.
        var topLeft: [CGPoint] = []
        topLeft.reserveCapacity(raw.count)
        for p in raw {
            topLeft.append(CGPoint(x: p.x, y: CGFloat(imageHeight) - p.y))
        }

        // Expand each point outward from the face bbox center. The
        // contour only traces the jawline (chin → ear → ear); expanding
        // by ~25% from the face center pulls the polygon up over the
        // forehead and out past the ears.
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

        // Append synthetic top-of-head points above the highest expanded
        // contour point so the polygon covers the forehead / hair region
        // (Vision's contour stops at temples). We add 3 points across
        // the top of the face bbox lifted by ~30% of bbox height above.
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
        // Insert canopy points between the two ends (highest x at each
        // side). Sort polygon by clockwise winding around centroid so the
        // resulting shape stays simple.
        expanded.append(CGPoint(x: rightX, y: topCanopyY))
        expanded.append(CGPoint(x: topMidX, y: topCanopyY))
        expanded.append(CGPoint(x: leftX, y: topCanopyY))

        // Sort by angle from the face center for a clean simple polygon.
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
    static func pointInPolygon(
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
            // Strict comparison on Y avoids double-counting at vertices.
            let crosses = ((yi > y) != (yj > y)) &&
                (x < (xj - xi) * (y - yi) / ((yj - yi) == 0 ? 0.0001 : (yj - yi)) + xi)
            if crosses { inside.toggle() }
            j = i
        }
        return inside
    }
}
