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
//   v0 (pre-2026-04-19) original:      lo=2, hi=1.0,  alpha=1.0
//   v1 (2026-04-19 "less intense"):    lo=1, hi=0.70, alpha=0.65  ← overexposed
//   v2 (2026-04-20):                   lo=1, hi=0.88, alpha=0.85
//   v3 (2026-04-20 post BGRA fix):     lo=1, hi=0.88, alpha=0.90
//     ↑ after the BGRA-byte-order fix revealed the actual pencil-grey
//     tone, Carl asked to "tune up by 25%" — reducing the remaining
//     lift-from-black by ~25% (38 → ~29 on pure black input).
//
// Safe tuning ranges (if you want to experiment on device):
//   edgeThresholdLo : 0 … 4   (int)
//   edgeThresholdHi : 0.5 … 1.0
//   lineAlpha       : 0.3 … 1.0
private let edgeThresholdLo: Int = 1
private let edgeThresholdHi: Double = 0.88
private let lineAlpha: Double = 0.90

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
            processingQueue.async { [weak self] in
                self?.convertVideo(
                    inputPath: inputPath,
                    outputPath: outputPath,
                    blurKernel: blurKernel,
                    thresholdBlock: thresholdBlock,
                    contrastLow: contrastLow,
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
            processingQueue.async { [weak self] in
                self?.extractThumbnail(
                    inputPath: inputPath,
                    outputPath: outputPath,
                    timeMs: timeMs,
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

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Video Conversion

    private func convertVideo(
        inputPath: String,
        outputPath: String,
        blurKernel: Int,
        thresholdBlock: Int,
        contrastLow: Int,
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

        // --- Audio passthrough setup ---
        // Copy the audio track as-is (no re-encoding) so the converted video
        // retains the original audio. If the source has no audio track, we
        // simply skip this — the output will be video-only.
        var audioReaderOutput: AVAssetReaderTrackOutput?
        var audioWriterInput: AVAssetWriterInput?

        // Audio track — optional, skip gracefully if incompatible
        if let audioTrack = asset.tracks(withMediaType: .audio).first {
            let audioOutput = AVAssetReaderTrackOutput(
                track: audioTrack,
                outputSettings: nil
            )
            audioOutput.alwaysCopiesSampleData = false

            if reader.canAdd(audioOutput) {
                reader.add(audioOutput)
                audioReaderOutput = audioOutput

                let audioInput = AVAssetWriterInput(
                    mediaType: .audio,
                    outputSettings: nil
                )
                audioInput.expectsMediaDataInRealTime = false

                if writer.canAdd(audioInput) {
                    writer.add(audioInput)
                    audioWriterInput = audioInput
                } else {
                    // Audio format incompatible with output — skip audio
                    audioReaderOutput = nil
                }
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

        // Pre-allocate the line drawing processor for reuse across frames.
        let processor = LineDrawingProcessor(
            width: videoWidth,
            height: videoHeight,
            blurKernel: blurKernel,
            thresholdBlock: thresholdBlock,
            contrastLow: contrastLow
        )

        // Pre-allocate the person segmenter (iOS 15+). Returns nil on older iOS
        // and the pipeline falls through to unmasked output. Pooled across frames
        // so VNSequenceRequestHandler and the upscale destination are reused.
        var segmenter: Any? = nil
        if #available(iOS 15.0, *) {
            segmenter = PersonSegmenter(width: videoWidth, height: videoHeight)
        }

        var framesProcessed = 0
        var lastProgressReport = 0

        // --- Frame pump loop ---
        // Each iteration is wrapped in an autoreleasepool so that sample
        // buffers, CVPixelBuffers, and other AVFoundation temporaries are
        // released promptly instead of piling up until the outer @autoreleasepool
        // drains. On clips >15s this was the root cause of jetsam OOM kills.
        //
        // NOTE: the two `isReadyForMoreMediaData` busy-wait loops below are
        // intentionally left as short sleeps for now. Migrating to
        // `requestMediaDataWhenReady(on:using:)` is a larger refactor. The 60s
        // `finishWriting` timeout (see below) prevents indefinite UI hangs if
        // the writer ever wedges.
        while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
            autoreleasepool {
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

                // Wait for the writer input to be ready.
                // (Short sleep — see note above about requestMediaDataWhenReady refactor.)
                while !writerInput.isReadyForMoreMediaData {
                    Thread.sleep(forTimeInterval: 0.01)
                }

                adaptor.append(outBuffer, withPresentationTime: presentationTime)
                framesProcessed += 1

                // Report progress every 30 frames.
                if framesProcessed - lastProgressReport >= 30 {
                    lastProgressReport = framesProcessed
                    let progress: [String: Any] = [
                        "framesProcessed": framesProcessed,
                        "totalFrames": estimatedTotalFrames,
                    ]
                    DispatchQueue.main.async { [weak self] in
                        self?.channel.invokeMethod("onProgress", arguments: progress)
                    }
                }
            }
        }

        // Finish video writing.
        writerInput.markAsFinished()

        // --- Copy audio samples ---
        // Drain the audio track after all video frames are written. Audio
        // samples are small and fast to copy, so a simple serial loop is fine.
        // (Same busy-wait caveat applies — pending requestMediaDataWhenReady refactor.)
        if let audioOutput = audioReaderOutput, let audioInput = audioWriterInput {
            while let audioSample = audioOutput.copyNextSampleBuffer() {
                autoreleasepool {
                    while !audioInput.isReadyForMoreMediaData {
                        Thread.sleep(forTimeInterval: 0.01)
                    }
                    audioInput.append(audioSample)
                }
            }
            audioInput.markAsFinished()
        }

        // Wait for the writer to finish, with a hard timeout so a wedged writer
        // can't hang the UI forever.
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting {
            semaphore.signal()
        }
        let waitResult = semaphore.wait(timeout: .now() + 60)
        if waitResult == .timedOut {
            writer.cancelWriting()
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

        reader.cancelReading()

        if writer.status == .completed {
            DispatchQueue.main.async {
                result([
                    "success": true,
                    "framesProcessed": framesProcessed,
                    "outputPath": outputPath,
                ])
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

        let time = CMTime(value: CMTimeValue(timeMs), timescale: 1000)

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
            var finalImage: CGImage = cgImage
            if #available(iOS 15.0, *) {
                if let masked = Self.applySegmentationToThumbnail(cgImage: cgImage) {
                    finalImage = masked
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
            generator.generateCGImageAsynchronously(for: time) { cgImage, _, error in
                handleImage(cgImage, error)
            }
        } else {
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
                    handleImage(cgImage, nil)
                } catch {
                    handleImage(nil, error)
                }
            }
        }
    }

    // MARK: - Thumbnail Segmentation Helper

    /// Run person segmentation on a single still image and return a new
    /// CGImage with the background erased to white. Returns nil on any
    /// failure — callers should fall through to the un-masked source image.
    ///
    /// Used by both the VideoConverterChannel thumbnail path and the
    /// AppDelegate native_thumb channel, so both surfaces get body-only
    /// previews that match the video look.
    @available(iOS 15.0, *)
    static func applySegmentationToThumbnail(cgImage: CGImage) -> CGImage? {
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

        // Precompute the dim LUT once.
        var dimLUT = [UInt8](repeating: 0, count: 256)
        for v in 0...255 {
            let dimmed = 255.0 - (255.0 - Double(v)) * 0.35
            dimLUT[v] = UInt8(max(0, min(255, Int(dimmed.rounded()))))
        }

        let dstPtr = base.assumingMemoryBound(to: UInt8.self)
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
        // dim[v] = round(255 - (255 - v) * 0.35)
        // Near-white stays near-white, black drops to ~90 (dark-grey ghost).
        var dimLUT = [UInt8](repeating: 0, count: 256)
        for v in 0...255 {
            let dimmed = 255.0 - (255.0 - Double(v)) * 0.35
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
    }

    deinit {
        upscaledMaskBuffer.data.deallocate()
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
        let dstPtr = upscaledMaskBuffer.data.assumingMemoryBound(to: UInt8.self)
        return UnsafePointer(dstPtr)
    }
}
