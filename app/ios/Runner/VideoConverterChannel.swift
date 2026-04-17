import Flutter
import UIKit
import AVFoundation
import Accelerate

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

                // Process the frame into a line drawing, writing into outBuffer.
                guard processor.processFrame(pixelBuffer, into: outBuffer) else {
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
            let uiImage = UIImage(cgImage: cgImage)
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
    }

    /// Process a single BGRA pixel buffer into a line drawing, writing the
    /// result into the supplied output pixel buffer (which is expected to be
    /// BGRA at the same dimensions). Returns true on success.
    func processFrame(_ inputBuffer: CVPixelBuffer, into outBuffer: CVPixelBuffer) -> Bool {
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
        // C = 2 matches the OpenCV adaptiveThreshold with C=2.
        adaptiveThreshold(
            gray: &grayBuffer,
            localMean: &localMeanBuffer,
            dst: &adaptiveBuffer,
            c: 2
        )

        // --- Step 4: Combine (take min / darkest of sketch and adaptive) ---
        pixelwiseMin(a: &sketchBuffer, b: &adaptiveBuffer, dst: &combinedBuffer)

        // --- Step 5: Contrast boost ---
        // output = clamp((input - contrastLow) * 255 / (255 - contrastLow), 0, 255)
        contrastBoost(src: &combinedBuffer, dst: &outputGrayBuffer, low: contrastLow)

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

        // vImage only exposes a Planar8 -> ARGB8888 assembler. Since the three
        // colour channels here all hold the same gray value, the resulting
        // byte order (B=G=R=gray, A=255) is visually identical whether the
        // buffer is interpreted as ARGB or BGRA — so we use the ARGB variant
        // and feed the pre-filled 255 plane as the A/first channel.
        _ = vImageConvert_Planar8toARGB8888(
            &alphaPlaneBuffer,   // A / first byte
            &outputGrayBuffer,   // R (same gray)
            &outputGrayBuffer,   // G
            &outputGrayBuffer,   // B
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
