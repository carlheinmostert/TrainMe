import Flutter
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
            do {
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
            } catch {
                // Audio setup failed — continue without audio
                audioReaderOutput = nil
                audioWriterInput = nil
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

        while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                continue
            }

            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            // Process the frame into a line drawing.
            guard let outputBuffer = processor.processFrame(pixelBuffer) else {
                continue
            }

            // Wait for the writer input to be ready.
            while !writerInput.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.01)
            }

            adaptor.append(outputBuffer, withPresentationTime: presentationTime)
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

        // Finish video writing.
        writerInput.markAsFinished()

        // --- Copy audio samples ---
        // Drain the audio track after all video frames are written. Audio
        // samples are small and fast to copy, so a simple serial loop is fine.
        if let audioOutput = audioReaderOutput, let audioInput = audioWriterInput {
            while let audioSample = audioOutput.copyNextSampleBuffer() {
                while !audioInput.isReadyForMoreMediaData {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                audioInput.append(audioSample)
            }
            audioInput.markAsFinished()
        }

        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting {
            semaphore.signal()
        }
        semaphore.wait()

        reader.cancelReading()

        if writer.status == .completed {
            DispatchQueue.main.async {
                result([
                    "success": true,
                    "framesProcessed": framesProcessed,
                    "outputPath": outputPath,
                ])
            }
        } else {
            DispatchQueue.main.async {
                result(FlutterError(
                    code: "WRITE_FAILED",
                    message: "AVAssetWriter finished with status \(writer.status.rawValue): \(writer.error?.localizedDescription ?? "unknown")",
                    details: nil
                ))
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
        let inputURL = URL(fileURLWithPath: inputPath)
        let asset = AVURLAsset(url: inputURL)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        let time = CMTime(value: CMTimeValue(timeMs), timescale: 1000)

        do {
            let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
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
            try jpegData.write(to: URL(fileURLWithPath: outputPath))
            DispatchQueue.main.async {
                result([
                    "success": true,
                    "outputPath": outputPath,
                ])
            }
        } catch {
            DispatchQueue.main.async {
                result(FlutterError(
                    code: "THUMBNAIL_FAILED",
                    message: "Could not extract thumbnail: \(error.localizedDescription)",
                    details: nil
                ))
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

    // Temporary buffer for vImage operations.
    private var tempBuffer: UnsafeMutableRawPointer?

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
        tempBuffer?.deallocate()
    }

    /// Process a single BGRA pixel buffer into a line drawing.
    /// Returns a new CVPixelBuffer with the result, or nil on failure.
    func processFrame(_ inputBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        CVPixelBufferLockBaseAddress(inputBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(inputBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(inputBuffer) else {
            return nil
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(inputBuffer)
        let bufWidth = CVPixelBufferGetWidth(inputBuffer)
        let bufHeight = CVPixelBufferGetHeight(inputBuffer)

        // --- Step 1: Convert BGRA to grayscale ---
        // Use weighted conversion: gray = 0.114*B + 0.587*G + 0.299*R
        // (BGRA order, so B is first byte)
        var srcBGRA = vImage_Buffer(
            data: baseAddress,
            height: vImagePixelCount(bufHeight),
            width: vImagePixelCount(bufWidth),
            rowBytes: bytesPerRow
        )

        // Convert BGRA to grayscale via weighted luminance:
        // gray = 0.114*B + 0.587*G + 0.299*R  (BGRA channel order)
        let srcPtr = baseAddress.assumingMemoryBound(to: UInt8.self)
        let grayPtr = grayBuffer.data.assumingMemoryBound(to: UInt8.self)

        for y in 0..<bufHeight {
            let srcRow = srcPtr + y * bytesPerRow
            let grayRow = grayPtr + y * grayBuffer.rowBytes
            for x in 0..<bufWidth {
                let offset = x * 4
                let b = Int(srcRow[offset])
                let g = Int(srcRow[offset + 1])
                let r = Int(srcRow[offset + 2])
                grayRow[x] = UInt8((r * 299 + g * 587 + b * 114) / 1000)
            }
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

        // --- Step 6: Convert grayscale back to BGRA and write to output pixel buffer ---
        var outputPixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            bufWidth,
            bufHeight,
            kCVPixelFormatType_32BGRA,
            nil,
            &outputPixelBuffer
        )

        guard status == kCVReturnSuccess, let outBuffer = outputPixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(outBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(outBuffer, []) }

        guard let outBase = CVPixelBufferGetBaseAddress(outBuffer) else {
            return nil
        }

        let outBytesPerRow = CVPixelBufferGetBytesPerRow(outBuffer)

        // Write grayscale as BGRA: B=G=R=gray, A=255
        let outGrayPtr = outputGrayBuffer.data.assumingMemoryBound(to: UInt8.self)
        let outPtr = outBase.assumingMemoryBound(to: UInt8.self)

        for y in 0..<bufHeight {
            let grayRow = outGrayPtr + y * outputGrayBuffer.rowBytes
            let outRow = outPtr + y * outBytesPerRow
            for x in 0..<bufWidth {
                let g = grayRow[x]
                let outOffset = x * 4
                outRow[outOffset]     = g  // B
                outRow[outOffset + 1] = g  // G
                outRow[outOffset + 2] = g  // R
                outRow[outOffset + 3] = 255  // A
            }
        }

        return outBuffer
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
