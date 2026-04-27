import Foundation
import UIKit
import CoreImage
import Vision
import Accelerate
import CoreVideo
import os.log

// MARK: - ClientAvatarProcessor (Wave 30)
//
// Single-still pipeline that takes a raw camera capture and produces a
// "body-focus blurred" PNG: subject crisp from the source frame, background
// heavily Gaussian-blurred. Output is consent-gated — the practitioner must
// have toggled `video_consent.avatar = true` before the capture flow opens.
//
// Reuses two pieces from `VideoConverterChannel.swift`:
//
//   1. `PersonSegmenter` — runs `VNGeneratePersonSegmentationRequest`
//      against the source CVPixelBuffer and returns an upscaled Planar8
//      mask. Same Vision quality level (`.accurate`) the line-drawing
//      pipeline already uses.
//
//   2. `vImage` Gaussian blur on the source BGRA buffer to produce the
//      background plate. Tent-convolves the mask first (5x5) so the
//      body/background boundary is a smooth feathered gradient, not a
//      cutout edge.
//
// Compositing rule per pixel (BGRA, alpha left at source 255):
//
//     w = softMask[i] / 255            // 1.0 = body, 0.0 = background
//     out_channel = source * w + blurred * (1 - w)
//
// Output is PNG (clean alpha edges; subject's silhouette stays soft).
//
// Performance budget on iPhone 15-class hardware:
//   * Vision .accurate one-shot: ~70-120ms for a 1080x1920 still.
//   * vImage Gaussian (radius 32): ~30-50ms at the same resolution.
//   * Compose loop: ~20-40ms.
//   Total: ~150-250ms. Below the 500ms threshold the brief implied; the
//   spinner-during-process surface is mostly UX padding.
//
// Thread safety: every entry point dispatches off the main thread via the
// supplied processing queue. The Flutter result callback is hopped back
// to main before delivery, matching the `convertVideo` / `extractThumbnail`
// pattern next door.

import Flutter

@available(iOS 15.0, *)
final class ClientAvatarProcessor {
    /// Diagnostic log channel. Subsystem matches the rest of the iOS
    /// runtime (`com.raidme.raidme`); `avatar.capture` keeps the
    /// avatar + photo body-focus pipelines on the same Console.app
    /// filter so Carl can capture both with one query.
    private static let log = OSLog(
        subsystem: "com.raidme.raidme",
        category: "avatar.capture"
    )

    /// Output encoding mode for the composed result.
    ///
    /// `.png` (avatar surface, default): clean alpha edges around the
    /// soft silhouette boundary; the avatar lens renders this as a
    /// circle on a dark background and any quantisation halo is
    /// visible. ~150-300 KB at 1600px long edge.
    ///
    /// `.jpg` (Wave 36 — exercise photo body-focus): cheaper to upload
    /// to `raw-archive` and matches the existing `*.jpg` raw photo
    /// pattern. The body silhouette inside the frame doesn't need
    /// alpha — it's compositing into a uniform blurred plate, not
    /// onto a transparent surface. Quality 90 keeps the body crisp
    /// without the file-size penalty PNG would charge.
    enum OutputFormat {
        case png
        case jpg
    }

    /// Public entry. Reads the raw image from `rawPath`, runs the
    /// segmentation + blur compose, writes the output (PNG or JPG) to
    /// `outPath`. Returns `outPath` on success or a FlutterError on any
    /// failure.
    ///
    /// Mirrors the error-code style used by `convertVideo` so callers can
    /// pattern-match across pipelines (FILE_NOT_FOUND, JPEG_ENCODE_FAILED, etc.).
    static func process(
        rawPath: String,
        outPath: String,
        format: OutputFormat = .png,
        result: @escaping FlutterResult
    ) {
        guard FileManager.default.fileExists(atPath: rawPath),
              FileManager.default.isReadableFile(atPath: rawPath) else {
            DispatchQueue.main.async {
                result(FlutterError(
                    code: "FILE_NOT_FOUND",
                    message: "Raw avatar file does not exist: \(rawPath)",
                    details: nil
                ))
            }
            return
        }

        guard let raw = UIImage(contentsOfFile: rawPath),
              let rawCgImage = raw.cgImage else {
            DispatchQueue.main.async {
                result(FlutterError(
                    code: "DECODE_FAILED",
                    message: "Could not decode raw avatar image",
                    details: nil
                ))
            }
            return
        }

        // Wave 36 — bake EXIF orientation into the pixel buffer BEFORE
        // any downstream Vision / vImage / compose pass. `UIImage(contentsOfFile:)`
        // reads the JPEG's EXIF orientation into `imageOrientation`, but
        // `.cgImage` always returns the RAW pixel buffer — un-rotated.
        // Vision + vImage operate on raw pixels, and the PNG we write
        // out has no orientation field, so any non-`.up` source produces
        // a sideways avatar. The captured JPEG arrives upright in normal
        // viewers (Photos / Finder both honour EXIF), but our pipeline
        // doesn't — that's the W34 device-QA #1 fail.
        //
        // Fix: redraw the source through a CGContext sized for the
        // *displayed* (post-orientation) dimensions, applying the
        // orientation transform. The result is a true-upright CGImage
        // suitable for direct ingestion by Vision + vImage.
        let cgImage = redrawUpright(cgImage: rawCgImage, orientation: raw.imageOrientation)

        // Cap input dimension for predictable runtime on long-edge 4K stills
        // from the iPhone 15 Pro Max wide. Vision + vImage both scale ~O(n²)
        // in pixel count; clamping the long edge to ~1600px keeps the
        // composite under 250ms while preserving a soft, recognisable
        // silhouette (the avatar will be displayed at 32-40 dp in any UI).
        let maxLongEdge: CGFloat = 1600
        let working = downscaledCGImage(cgImage, maxLongEdge: maxLongEdge) ?? cgImage

        let width = working.width
        let height = working.height
        guard width > 0, height > 0 else {
            DispatchQueue.main.async {
                result(FlutterError(
                    code: "DEGENERATE_INPUT",
                    message: "Avatar source has zero dimension",
                    details: nil
                ))
            }
            return
        }

        guard let composed = composeAvatar(cgImage: working) else {
            DispatchQueue.main.async {
                result(FlutterError(
                    code: "COMPOSE_FAILED",
                    message: "Avatar segmentation/compose pass failed",
                    details: nil
                ))
            }
            return
        }

        // PNG keeps the soft silhouette edge clean for the avatar surface.
        // JPEG (Wave 36) is fine for exercise-photo body-focus — the
        // composite lands inside a frame on the player slide, not as a
        // circle-clipped avatar, so the quantisation halo isn't visible.
        let uiImage = UIImage(cgImage: composed)
        let encodedData: Data?
        let encodeErrorCode: String
        switch format {
        case .png:
            encodedData = uiImage.pngData()
            encodeErrorCode = "PNG_ENCODE_FAILED"
        case .jpg:
            encodedData = uiImage.jpegData(compressionQuality: 0.9)
            encodeErrorCode = "JPEG_ENCODE_FAILED"
        }
        guard let outData = encodedData else {
            DispatchQueue.main.async {
                result(FlutterError(
                    code: encodeErrorCode,
                    message: "Could not encode body-focus output",
                    details: nil
                ))
            }
            return
        }

        do {
            let outURL = URL(fileURLWithPath: outPath)
            try FileManager.default.createDirectory(
                at: outURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try outData.write(to: outURL)
            DispatchQueue.main.async {
                result([
                    "success": true,
                    "outputPath": outPath,
                    "width": width,
                    "height": height,
                ])
            }
        } catch {
            DispatchQueue.main.async {
                result(FlutterError(
                    code: "WRITE_FAILED",
                    message: "Could not write avatar PNG: \(error.localizedDescription)",
                    details: nil
                ))
            }
        }
    }

    // MARK: - Compose

    /// The actual segment + blur + compose pass. Returns nil on any
    /// CVPixelBuffer / Vision / vImage failure — the caller surfaces a
    /// COMPOSE_FAILED FlutterError.
    private static func composeAvatar(cgImage: CGImage) -> CGImage? {
        let width = cgImage.width
        let height = cgImage.height

        // Wave 37 — diagnostic for the W36 #6 photo banding bug. Logs
        // the working dimensions and the BGRA stride so Carl can
        // capture under Console.app filter `subsystem:com.raidme.raidme
        // category:avatar.capture`. Square avatars work fine; portrait
        // (9:16) photos have shown horizontal-band artefacts which we
        // suspect are stride / in-place-blur related. Keep this log
        // through QA — it's cheap and lets us correlate Console.app
        // output against a specific capture's geometry.
        os_log(
            "composeAvatar: input width=%{public}d height=%{public}d aspect=%{public}.3f",
            log: log,
            type: .info,
            width,
            height,
            Double(width) / Double(max(height, 1))
        )

        // --- Render source into a BGRA CVPixelBuffer (Vision-friendly). ---
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        var pbOut: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pbOut
        )
        guard status == kCVReturnSuccess, let pixelBuffer = pbOut else {
            NSLog("ClientAvatarProcessor: CVPixelBufferCreate failed (\(status))")
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            return nil
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        // Wave 37 — log the actual stride. CVPixelBufferCreate pads
        // bytesPerRow up to a 64-byte boundary on most iOS hardware,
        // so for non-square widths bytesPerRow > width * 4. Any stride
        // assumption that uses `width * 4` instead of bytesPerRow will
        // mis-walk pixels; this log lets us confirm the pad lands as
        // expected for the failing aspect ratios.
        os_log(
            "composeAvatar: bytesPerRow=%{public}d width*4=%{public}d pad=%{public}d",
            log: log,
            type: .info,
            bytesPerRow,
            width * 4,
            bytesPerRow - (width * 4)
        )
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 =
            CGBitmapInfo.byteOrder32Little.rawValue |
            CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let drawCtx = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            NSLog("ClientAvatarProcessor: CGContext init failed")
            return nil
        }
        drawCtx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Note: deliberately do NOT unlock yet — the segmenter + the inner
        // compose loop both need the BGRA bytes alive. We unlock at the
        // exit of the function (see the `defer` below).
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        // --- Run person segmentation. Reuses the existing pooled segmenter. ---
        let segmenter = PersonSegmenterShim(width: width, height: height)
        let maskPtr = segmenter.generateMaskOneShot(for: pixelBuffer)
        // maskPtr nil is acceptable — fall through to "everything is
        // background" (whole image blurred). Keeps the avatar surface alive
        // even when Vision misses the subject; the practitioner can always
        // retake.
        os_log(
            "composeAvatar: mask=%{public}@",
            log: log,
            type: .info,
            maskPtr != nil ? "ok" : "nil (no person)"
        )

        // --- Build the blurred background plate via vImage Gaussian. ---
        // Two-pass tent convolve approximates a Gaussian. The two
        // intermediate buffers ping-pong: pass 1 reads the source BGRA
        // (still inside `pixelBuffer.base`) → writes plate. Pass 2 reads
        // plate → writes scratch. We then alias `plate` to whichever of
        // the two holds the final output (`finalBlurredPtr`) before the
        // compositing loop runs.
        //
        // Wave 37 — split the previous "in-place on plate" second pass
        // into a real scratch buffer. `vImageTentConvolve_ARGB8888` does
        // NOT reliably support in-place operation when `tempBuffer` is
        // nil; the prior code path could leave bands of half-updated
        // rows on non-square inputs (W36 #6: 9:16 portrait photos
        // showed ~5 horizontal bands behind the subject). True-square
        // avatar captures dodged the failure mode often enough that it
        // shipped. Same kernel + edge mode as before; only the
        // ping-pong topology changes.
        let plateSize = bytesPerRow * height
        let plate = UnsafeMutablePointer<UInt8>.allocate(capacity: plateSize)
        defer { plate.deallocate() }
        let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: plateSize)
        defer { scratch.deallocate() }

        // Heavy blur: kernel chosen to be ~6% of the long edge, which
        // produces the unmistakable "portrait-mode" background look without
        // bleeding individual hue blobs into the body silhouette. Must be
        // odd. vImage requires width >= 1 + 2 * radius and same for height.
        let longEdge = max(width, height)
        var kernel = max(15, (longEdge / 16) | 1)
        if kernel >= width { kernel = (width - 1) | 1 }
        if kernel >= height { kernel = (height - 1) | 1 }
        if kernel < 3 { kernel = 3 }

        os_log(
            "composeAvatar: blur kernel=%{public}d (longEdge=%{public}d)",
            log: log,
            type: .info,
            kernel,
            longEdge
        )

        let srcBgraPtr = base.assumingMemoryBound(to: UInt8.self)
        // Pass 1: source(BGRA) → plate.
        var pass1Src = vImage_Buffer(
            data: UnsafeMutableRawPointer(srcBgraPtr),
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: bytesPerRow
        )
        var pass1Dst = vImage_Buffer(
            data: UnsafeMutableRawPointer(plate),
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: bytesPerRow
        )
        let err1 = vImageTentConvolve_ARGB8888(
            &pass1Src,
            &pass1Dst,
            nil,
            0, 0,
            UInt32(kernel),
            UInt32(kernel),
            nil,
            vImage_Flags(kvImageEdgeExtend)
        )
        if err1 != kvImageNoError {
            os_log(
                "composeAvatar: vImageTentConvolve pass1 failed err=%{public}d",
                log: log,
                type: .error,
                Int(err1)
            )
            return nil
        }

        // Pass 2: plate → scratch (NOT in-place — see Wave 37 note above).
        var pass2Src = vImage_Buffer(
            data: UnsafeMutableRawPointer(plate),
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: bytesPerRow
        )
        var pass2Dst = vImage_Buffer(
            data: UnsafeMutableRawPointer(scratch),
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: bytesPerRow
        )
        let err2 = vImageTentConvolve_ARGB8888(
            &pass2Src,
            &pass2Dst,
            nil,
            0, 0,
            UInt32(kernel),
            UInt32(kernel),
            nil,
            vImage_Flags(kvImageEdgeExtend)
        )
        if err2 != kvImageNoError {
            os_log(
                "composeAvatar: vImageTentConvolve pass2 failed err=%{public}d",
                log: log,
                type: .error,
                Int(err2)
            )
            return nil
        }
        // Final blurred plate lives in `scratch`. Alias the variable
        // the compositing loop reads to it; `plate` becomes a one-pass
        // intermediate that gets freed by its `defer`.
        let finalBlurredPtr = scratch

        // --- Soften the mask via tent convolve to feather the body edge. ---
        let maskByteCount = width * height
        let blurredMask = UnsafeMutableRawPointer.allocate(byteCount: maskByteCount, alignment: 16)
        defer { blurredMask.deallocate() }

        let softMaskPtr: UnsafePointer<UInt8>?
        if let raw = maskPtr {
            var srcMaskBuf = vImage_Buffer(
                data: UnsafeMutableRawPointer(mutating: raw),
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: width
            )
            var dstMaskBuf = vImage_Buffer(
                data: blurredMask,
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: width
            )
            let tentErr = vImageTentConvolve_Planar8(
                &srcMaskBuf,
                &dstMaskBuf,
                nil,
                0, 0,
                9, 9,
                0,
                vImage_Flags(kvImageEdgeExtend)
            )
            if tentErr == kvImageNoError {
                softMaskPtr = UnsafePointer(blurredMask.assumingMemoryBound(to: UInt8.self))
            } else {
                softMaskPtr = raw
            }
        } else {
            softMaskPtr = nil
        }

        // --- Composite: source where mask says "body", plate elsewhere. ---
        // BGRA layout: B at +0, G at +1, R at +2, A at +3. We blend BGR and
        // leave alpha at source (typically 255). `finalBlurredPtr`
        // points to whichever ping-pong buffer holds the two-pass
        // blurred plate (Wave 37: now `scratch`, not `plate`).
        let dstPtr = base.assumingMemoryBound(to: UInt8.self)
        if let mask = softMaskPtr {
            for y in 0..<height {
                let row = y * bytesPerRow
                let mrow = y * width
                for x in 0..<width {
                    let w = Int(mask[mrow + x])
                    let inv = 255 - w
                    let p = row + x * 4
                    for c in 0..<3 {
                        let s = Int(dstPtr[p + c])
                        let bgnd = Int(finalBlurredPtr[p + c])
                        // Round-half-up integer lerp.
                        let blended = (s * w + bgnd * inv + 127) / 255
                        dstPtr[p + c] = UInt8(blended)
                    }
                    // alpha at p+3 left as-is
                }
            }
        } else {
            // No person detected — fall through to "everything is plate"
            // (full Gaussian look). Still recognisable as the room/scene;
            // the practitioner can retake.
            for y in 0..<height {
                let row = y * bytesPerRow
                for x in 0..<width {
                    let p = row + x * 4
                    dstPtr[p + 0] = finalBlurredPtr[p + 0]
                    dstPtr[p + 1] = finalBlurredPtr[p + 1]
                    dstPtr[p + 2] = finalBlurredPtr[p + 2]
                    // alpha unchanged
                }
            }
        }

        return drawCtx.makeImage()
    }

    /// Bake `imageOrientation` into the raw pixel buffer so downstream
    /// Vision + vImage + compose see an upright source.
    ///
    /// Wave 36 fix for W34 device-QA #1: captured avatar JPEG arrives with
    /// EXIF orientation = right (top), which iOS Photos / Finder honour but
    /// our pipeline did not — Vision saw a sideways frame, the segmented
    /// PNG came out 90° left. By redrawing the source through a UIImage
    /// (which honours `imageOrientation` at draw-time) we get a strictly
    /// upright CGImage to feed forward.
    ///
    /// Returns the input unchanged when orientation is already `.up`
    /// (nominal AVCapturePhotoOutput-with-portrait-connection case) so
    /// the happy path adds zero overhead.
    private static func redrawUpright(cgImage: CGImage, orientation: UIImage.Orientation) -> CGImage {
        if orientation == .up { return cgImage }

        // Compute the post-orientation size. Quarter / three-quarter
        // rotations swap width <-> height; mirror-only orientations keep
        // the dimensions intact.
        let originalWidth = CGFloat(cgImage.width)
        let originalHeight = CGFloat(cgImage.height)
        let displayedSize: CGSize
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            displayedSize = CGSize(width: originalHeight, height: originalWidth)
        default:
            displayedSize = CGSize(width: originalWidth, height: originalHeight)
        }

        // UIGraphicsImageRenderer + .draw() applies the orientation at
        // render time. The result's underlying CGImage is upright (the
        // pixels themselves now match the displayed orientation, and
        // the orientation is .up).
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: displayedSize, format: format)
        let upright = renderer.image { _ in
            UIImage(cgImage: cgImage, scale: 1, orientation: orientation)
                .draw(in: CGRect(origin: .zero, size: displayedSize))
        }
        return upright.cgImage ?? cgImage
    }

    /// Downsample if the long edge exceeds [maxLongEdge]. Returns the
    /// original CGImage when already within budget. nil on context-create
    /// failure (caller falls back to the original).
    private static func downscaledCGImage(_ cgImage: CGImage, maxLongEdge: CGFloat) -> CGImage? {
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        let longEdge = max(w, h)
        if longEdge <= maxLongEdge { return cgImage }
        let scale = maxLongEdge / longEdge
        let newW = Int((w * scale).rounded())
        let newH = Int((h * scale).rounded())
        guard newW > 0, newH > 0 else { return cgImage }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 =
            CGBitmapInfo.byteOrder32Little.rawValue |
            CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: newW,
            height: newH,
            bitsPerComponent: 8,
            bytesPerRow: newW * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage()
    }
}

// MARK: - PersonSegmenterShim
//
// Thin compile-time shim around `VideoConverterChannel`'s file-private
// `PersonSegmenter` so the avatar pipeline can reuse the exact same
// Vision setup without exporting an API surface from the video file.
// Mirrors the init / generateMaskOneShot signatures.
@available(iOS 15.0, *)
private final class PersonSegmenterShim {
    let width: Int
    let height: Int
    private let request: VNGeneratePersonSegmentationRequest

    private var upscaledMaskBuffer: vImage_Buffer

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
    }

    deinit {
        upscaledMaskBuffer.data.deallocate()
    }

    func generateMaskOneShot(for pixelBuffer: CVPixelBuffer) -> UnsafePointer<UInt8>? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        do {
            try handler.perform([request])
        } catch {
            NSLog("PersonSegmenterShim: VNImageRequestHandler.perform failed: \(error.localizedDescription)")
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
            NSLog("PersonSegmenterShim: vImageScale_Planar8 failed \(scaleErr)")
            return nil
        }
        let dstPtr = upscaledMaskBuffer.data.assumingMemoryBound(to: UInt8.self)
        return UnsafePointer(dstPtr)
    }
}
