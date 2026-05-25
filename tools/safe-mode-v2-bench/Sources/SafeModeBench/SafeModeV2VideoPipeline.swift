//
//  SafeModeV2VideoPipeline.swift  (bench)
//
//  macOS-compatible mirror of `SafeModeV2VideoProcessor` in
//  app/ios/Runner/VideoConverterChannel.swift. The pipeline runs the
//  same hybrid state machine (first-frame identify + Vision tracker
//  between samples + sparse re-confirm via face-rec every 2 seconds
//  + on tracker-confidence drop) and the same per-frame composite
//  (CIBlendWithMask with the DeviceRGB output colorspace) so we can
//  iterate on cadence and threshold tunables without device cycles.
//
//  Stats surfaced via SafeModeV2VideoBenchReport:
//    - subjectIdentifiedFrames / framesProcessed
//    - trackerLossEvents
//    - reSeedEvents
//    - reConfirmEvents
//    - avgSubjectCosSim (across re-confirm + seeding picks only;
//      tracker-only frames don't run face-rec)
//    - avgFaceCount (mean detected face count per frame)
//    - safeMissRate (== framesProcessed where Vision detected zero
//      faces AND zero segmentation positive pixels — same definition
//      as iOS native `framesMissed`)
//    - durationMs (wall clock)
//
//  CoreML + Vision + CoreImage + AVFoundation are platform-independent
//  and behave identically across iOS 15+ / macOS 12+. The MobileFaceNet
//  model is byte-identical to the iOS-bundled one (shared via
//  Bundle.module).
//

import Foundation
import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import Vision
import Metal

/// Caller-facing knobs for a single video bench run.
struct SafeModeV2VideoPipelineParams {
    /// Solo-face cosSim floor (matches iOS `subjectEmbeddingSlots` solo
    /// branch). Multi-face frames ignore this and pick highest cosSim.
    var threshold: Double = 0.55
    /// Head-region painter multipliers (mirror iOS native).
    var headWidthFactor: CGFloat = 2.0
    var headHeightFactor: CGFloat = 1.5
    /// Per-head max area fraction (defensive clamp).
    var maxAreaFraction: Double = 0.35
    /// State machine cadences. Defaults mirror iOS native
    /// `SafeModeV2VideoProcessor.seedingFramesN` / `reConfirmIntervalSec`
    /// / `trackerConfidenceFloor` / `reSeedProximityRadiusFrac`.
    var seedingFramesN: Int = 3
    var reConfirmIntervalSec: Double = 2.0
    var trackerConfidenceFloor: Float = 0.5
    var reSeedProximityRadiusFrac: Double = 0.2
}

struct SafeModeV2VideoBenchReport {
    let srcPath: String
    let destPath: String
    let frameCount: Int
    let durationSeconds: Double
    let frameRate: Double
    let width: Int
    let height: Int
    let framesProcessed: Int
    let framesMissed: Int
    let safeMissRate: Double
    let subjectIdentifiedFrames: Int
    let trackerLossEvents: Int
    let reSeedEvents: Int
    let reConfirmEvents: Int
    let avgSubjectCosSim: Double
    let avgFaceCount: Double
    let durationMs: Int
}

enum SafeModeV2VideoPipelineError: Error {
    case sourceNotFound(String)
    case decodeFailed(String)
    case allocFailed(String)
    case writerFailed(String)
    case wrongEmbeddingSize(actual: Int, expected: Int)
}

/// macOS-compatible mirror of the iOS `SafeModeV2VideoProcessor`.
/// Public entry point: `SafeModeV2VideoPipeline.run(...)`.
enum SafeModeV2VideoPipeline {

    /// Lightweight per-face record used inside the state machine. Mirrors
    /// the iOS native `DetectedFaceV2` exactly.
    struct DetectedFaceV2 {
        let normalizedRect: CGRect
        let pixelRectTopLeft: CGRect
        let centerXPx: Int
        let centerYPx: Int
        let contourPolygonPx: [CGPoint]?
    }

    enum State {
        case seeding
        case tracking
        case reConfirming
        case lost
        case noSubject
    }

    /// Run the video pipeline against `srcPath`, writing the safe variant
    /// to `destPath` and returning a `SafeModeV2VideoBenchReport`.
    ///
    /// `subjectEmbeddingSlots` carries 1-8 L2-normalised FP32 reference
    /// embeddings from the bound client's enrolment. Same byte shape as
    /// the iOS `applySafeModeV2ToVideo` channel parameter.
    static func run(
        srcPath: String,
        destPath: String,
        subjectEmbeddingSlots: [Data],
        params: SafeModeV2VideoPipelineParams
    ) throws -> SafeModeV2VideoBenchReport {

        guard FileManager.default.fileExists(atPath: srcPath) else {
            throw SafeModeV2VideoPipelineError.sourceNotFound(srcPath)
        }
        guard !subjectEmbeddingSlots.isEmpty else {
            throw SafeModeV2VideoPipelineError.wrongEmbeddingSize(
                actual: 0,
                expected: MobileFaceNetEmbedder.embeddingByteLength
            )
        }
        for emb in subjectEmbeddingSlots {
            guard emb.count == MobileFaceNetEmbedder.embeddingByteLength else {
                throw SafeModeV2VideoPipelineError.wrongEmbeddingSize(
                    actual: emb.count,
                    expected: MobileFaceNetEmbedder.embeddingByteLength
                )
            }
        }

        let startNs = Date().timeIntervalSince1970 * 1000.0

        let srcURL = URL(fileURLWithPath: srcPath)
        let dstURL = URL(fileURLWithPath: destPath)
        try? FileManager.default.removeItem(at: dstURL)
        try? FileManager.default.createDirectory(
            at: dstURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let asset = AVURLAsset(url: srcURL)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw SafeModeV2VideoPipelineError.decodeFailed("No video track in \(srcPath)")
        }

        let naturalSize = videoTrack.naturalSize
        let transform = videoTrack.preferredTransform
        let videoWidth: Int
        let videoHeight: Int
        if abs(transform.b) == 1.0 && abs(transform.c) == 1.0 {
            videoWidth = Int(naturalSize.height)
            videoHeight = Int(naturalSize.width)
        } else {
            videoWidth = Int(naturalSize.width)
            videoHeight = Int(naturalSize.height)
        }
        let frameRate = max(1.0, Double(videoTrack.nominalFrameRate))
        let durationSeconds = asset.duration.seconds
        let estimatedTotalFrames = max(1, Int(durationSeconds * frameRate))

        let visionOrientation: CGImagePropertyOrientation = {
            if transform.b == 1.0 && transform.c == -1.0 { return .right }
            if transform.b == -1.0 && transform.c == 1.0 { return .left }
            if transform.a == -1.0 && transform.d == -1.0 { return .down }
            return .up
        }()

        let readerOutputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw SafeModeV2VideoPipelineError.decodeFailed("AVAssetReader init: \(error.localizedDescription)")
        }
        let readerOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: readerOutputSettings
        )
        readerOutput.alwaysCopiesSampleData = false
        reader.add(readerOutput)

        let writerOutputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: videoWidth,
            AVVideoHeightKey: videoHeight,
        ]
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: dstURL, fileType: .mp4)
        } catch {
            throw SafeModeV2VideoPipelineError.writerFailed("AVAssetWriter init: \(error.localizedDescription)")
        }
        let writerInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: writerOutputSettings
        )
        writerInput.expectsMediaDataInRealTime = false
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

        guard reader.startReading() else {
            throw SafeModeV2VideoPipelineError.decodeFailed(
                "AVAssetReader.startReading: \(reader.error?.localizedDescription ?? "unknown")"
            )
        }
        guard writer.startWriting() else {
            throw SafeModeV2VideoPipelineError.writerFailed(
                "AVAssetWriter.startWriting: \(writer.error?.localizedDescription ?? "unknown")"
            )
        }
        writer.startSession(atSourceTime: .zero)

        let segmenter = PersonSegmenter(width: videoWidth, height: videoHeight)
        let ciContext: CIContext
        if let device = MTLCreateSystemDefaultDevice() {
            ciContext = CIContext(mtlDevice: device)
        } else {
            ciContext = CIContext()
        }
        guard let blurFilter = CIFilter(name: "CIGaussianBlur"),
              let blendFilter = CIFilter(name: "CIBlendWithMask") else {
            throw SafeModeV2VideoPipelineError.allocFailed("CIFilter init")
        }
        let minDim = Double(min(videoWidth, videoHeight))
        let blurRadius = 35.0 * max(0.25, minDim / 1080.0)

        let faceSequenceHandler = VNSequenceRequestHandler()
        let trackerSequenceHandler = VNSequenceRequestHandler()

        var state: State = .seeding
        var trackObservation: VNDetectedObjectObservation? = nil
        var subjectBboxNormalized: CGRect? = nil
        var subjectBboxPixelTopLeft: CGRect? = nil
        var lastReConfirmFrameIdx = 0
        let reConfirmIntervalFrames = max(1, Int(params.reConfirmIntervalSec * frameRate))
        let reSeedRadiusPx = Double(videoHeight) * params.reSeedProximityRadiusFrac

        var framesProcessed = 0
        var framesMissed = 0
        var subjectIdentifiedFrames = 0
        var trackerLossEvents = 0
        var reSeedEvents = 0
        var reConfirmEvents = 0
        var totalFaceCount = 0
        var subjectCosSimSum: Double = 0
        var subjectCosSimSamples: Int = 0

        // Synchronous pump — the bench runs serially to keep stats
        // deterministic and the per-frame diagnostic block reads naturally
        // top-to-bottom. The iOS path uses requestMediaDataWhenReady on a
        // background queue; we don't need that here.

        while reader.status == .reading {
            guard let sampleBuffer = readerOutput.copyNextSampleBuffer() else { break }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            var outputPixelBuffer: CVPixelBuffer?
            let allocStatus: CVReturn
            if let pool = adaptor.pixelBufferPool {
                allocStatus = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputPixelBuffer)
            } else {
                allocStatus = CVPixelBufferCreate(
                    kCFAllocatorDefault,
                    videoWidth, videoHeight,
                    kCVPixelFormatType_32BGRA, nil,
                    &outputPixelBuffer
                )
            }
            guard allocStatus == kCVReturnSuccess, let outBuffer = outputPixelBuffer else { continue }

            let segmentationMask = segmenter.generateMaskOneShot(for: pixelBuffer)

            let faceReq = VNDetectFaceLandmarksRequest()
            var faceObservations: [VNFaceObservation] = []
            do {
                try faceSequenceHandler.perform(
                    [faceReq],
                    on: pixelBuffer,
                    orientation: visionOrientation
                )
                faceObservations = faceReq.results ?? []
            } catch {
                faceObservations = []
            }

            let detectedFaces = buildDetectedFaces(
                observations: faceObservations,
                width: videoWidth,
                height: videoHeight
            )
            totalFaceCount += detectedFaces.count

            var picked = StateMachineStep(subjectFaceIdx: nil, cosSim: nil)

            switch state {
            case .seeding:
                let pick = runFaceRecPick(
                    pixelBuffer: pixelBuffer,
                    detectedFaces: detectedFaces,
                    subjectEmbeddingSlots: subjectEmbeddingSlots,
                    soloFloor: params.threshold
                )
                if let idx = pick.subjectFaceIdx {
                    let subject = detectedFaces[idx]
                    trackObservation = VNDetectedObjectObservation(boundingBox: subject.normalizedRect)
                    subjectBboxNormalized = subject.normalizedRect
                    subjectBboxPixelTopLeft = subject.pixelRectTopLeft
                    state = .tracking
                    lastReConfirmFrameIdx = framesProcessed
                    picked = StateMachineStep(subjectFaceIdx: idx, cosSim: pick.bestSim)
                    subjectCosSimSum += pick.bestSim
                    subjectCosSimSamples += 1
                } else if framesProcessed >= params.seedingFramesN - 1 {
                    state = .noSubject
                    lastReConfirmFrameIdx = framesProcessed
                }

            case .tracking:
                if let prevObs = trackObservation {
                    let trackReq = VNTrackObjectRequest(detectedObjectObservation: prevObs)
                    trackReq.trackingLevel = .accurate
                    var trackFailed = false
                    do {
                        try trackerSequenceHandler.perform(
                            [trackReq],
                            on: pixelBuffer,
                            orientation: visionOrientation
                        )
                    } catch {
                        trackFailed = true
                    }
                    let trackResult = trackReq.results?.first as? VNDetectedObjectObservation
                    if trackFailed {
                        trackerLossEvents += 1
                        state = .lost
                        trackObservation = nil
                        subjectBboxNormalized = nil
                        subjectBboxPixelTopLeft = nil
                    } else if let r = trackResult, r.confidence >= params.trackerConfidenceFloor {
                        trackObservation = r
                        subjectBboxNormalized = r.boundingBox
                        let bboxPx = pixelRectTopLeftFromNormalized(
                            r.boundingBox, width: videoWidth, height: videoHeight
                        )
                        subjectBboxPixelTopLeft = bboxPx
                        if framesProcessed - lastReConfirmFrameIdx >= reConfirmIntervalFrames {
                            state = .reConfirming
                            let step = doReConfirm(
                                state: &state,
                                trackObservation: &trackObservation,
                                subjectBboxNormalized: &subjectBboxNormalized,
                                subjectBboxPixelTopLeft: &subjectBboxPixelTopLeft,
                                lastReConfirmFrameIdx: &lastReConfirmFrameIdx,
                                reConfirmEvents: &reConfirmEvents,
                                reSeedEvents: &reSeedEvents,
                                frameIdx: framesProcessed,
                                reSeedRadiusPx: reSeedRadiusPx,
                                pixelBuffer: pixelBuffer,
                                detectedFaces: detectedFaces,
                                subjectEmbeddingSlots: subjectEmbeddingSlots,
                                soloFloor: params.threshold
                            )
                            picked = step
                            if let sim = step.cosSim {
                                subjectCosSimSum += sim
                                subjectCosSimSamples += 1
                            }
                        } else {
                            let idx = faceIndexNearestToBbox(
                                bbox: bboxPx, faces: detectedFaces
                            )
                            picked = StateMachineStep(subjectFaceIdx: idx, cosSim: nil)
                        }
                    } else {
                        trackerLossEvents += 1
                        state = .lost
                        trackObservation = nil
                        subjectBboxNormalized = nil
                        subjectBboxPixelTopLeft = nil
                    }
                } else {
                    state = .lost
                }

            case .reConfirming:
                let step = doReConfirm(
                    state: &state,
                    trackObservation: &trackObservation,
                    subjectBboxNormalized: &subjectBboxNormalized,
                    subjectBboxPixelTopLeft: &subjectBboxPixelTopLeft,
                    lastReConfirmFrameIdx: &lastReConfirmFrameIdx,
                    reConfirmEvents: &reConfirmEvents,
                    reSeedEvents: &reSeedEvents,
                    frameIdx: framesProcessed,
                    reSeedRadiusPx: reSeedRadiusPx,
                    pixelBuffer: pixelBuffer,
                    detectedFaces: detectedFaces,
                    subjectEmbeddingSlots: subjectEmbeddingSlots,
                    soloFloor: params.threshold
                )
                picked = step
                if let sim = step.cosSim {
                    subjectCosSimSum += sim
                    subjectCosSimSamples += 1
                }

            case .lost:
                let pick = runFaceRecPick(
                    pixelBuffer: pixelBuffer,
                    detectedFaces: detectedFaces,
                    subjectEmbeddingSlots: subjectEmbeddingSlots,
                    soloFloor: params.threshold
                )
                lastReConfirmFrameIdx = framesProcessed
                if let idx = pick.subjectFaceIdx {
                    let subject = detectedFaces[idx]
                    trackObservation = VNDetectedObjectObservation(boundingBox: subject.normalizedRect)
                    subjectBboxNormalized = subject.normalizedRect
                    subjectBboxPixelTopLeft = subject.pixelRectTopLeft
                    state = .tracking
                    reSeedEvents += 1
                    picked = StateMachineStep(subjectFaceIdx: idx, cosSim: pick.bestSim)
                    subjectCosSimSum += pick.bestSim
                    subjectCosSimSamples += 1
                } else {
                    state = .noSubject
                }

            case .noSubject:
                if framesProcessed - lastReConfirmFrameIdx >= reConfirmIntervalFrames {
                    lastReConfirmFrameIdx = framesProcessed
                    let pick = runFaceRecPick(
                        pixelBuffer: pixelBuffer,
                        detectedFaces: detectedFaces,
                        subjectEmbeddingSlots: subjectEmbeddingSlots,
                        soloFloor: params.threshold
                    )
                    if let idx = pick.subjectFaceIdx {
                        let subject = detectedFaces[idx]
                        trackObservation = VNDetectedObjectObservation(boundingBox: subject.normalizedRect)
                        subjectBboxNormalized = subject.normalizedRect
                        subjectBboxPixelTopLeft = subject.pixelRectTopLeft
                        state = .tracking
                        reSeedEvents += 1
                        picked = StateMachineStep(subjectFaceIdx: idx, cosSim: pick.bestSim)
                        subjectCosSimSum += pick.bestSim
                        subjectCosSimSamples += 1
                    }
                }
            }

            // Composite — same shape as the iOS native pipeline. Reuses
            // the v2 photo bench's flood-fill + paintHeadExpansion helpers
            // via the same module (single source of truth).
            let totalPx = videoWidth * videoHeight
            let keepMask = UnsafeMutablePointer<UInt8>.allocate(capacity: totalPx)
            defer {
                keepMask.deinitialize(count: totalPx)
                keepMask.deallocate()
            }
            keepMask.initialize(repeating: 255, count: totalPx)

            if let subjIdx = picked.subjectFaceIdx,
               let maskRaw = segmentationMask,
               subjIdx >= 0, subjIdx < detectedFaces.count {
                let subject = detectedFaces[subjIdx]
                let subjectComponent = SafeModeV2Pipeline.floodFillBinary(
                    mask: maskRaw,
                    width: videoWidth,
                    height: videoHeight,
                    seedX: subject.centerXPx,
                    seedY: subject.centerYPx,
                    threshold: 128
                )
                defer {
                    subjectComponent.deinitialize(count: totalPx)
                    subjectComponent.deallocate()
                }
                for y in 0..<videoHeight {
                    let rowOff = y * videoWidth
                    for x in 0..<videoWidth {
                        let i = rowOff + x
                        if maskRaw[i] >= 128 && subjectComponent[i] == 0 {
                            keepMask[i] = 0
                        }
                    }
                }
                for (i, f) in detectedFaces.enumerated() where i != subjIdx {
                    SafeModeV2Pipeline.paintHeadExpansion(
                        keepMask: keepMask,
                        width: videoWidth,
                        height: videoHeight,
                        pixelRect: f.pixelRectTopLeft,
                        contourPolygonPx: f.contourPolygonPx,
                        headWidthFactor: params.headWidthFactor,
                        headHeightFactor: params.headHeightFactor,
                        maxAreaFraction: params.maxAreaFraction,
                        segmentationMask: maskRaw,
                        subjectComponent: subjectComponent
                    )
                }
                subjectIdentifiedFrames += 1
            } else {
                for f in detectedFaces {
                    SafeModeV2Pipeline.paintHeadExpansion(
                        keepMask: keepMask,
                        width: videoWidth,
                        height: videoHeight,
                        pixelRect: f.pixelRectTopLeft,
                        contourPolygonPx: f.contourPolygonPx,
                        headWidthFactor: params.headWidthFactor,
                        headHeightFactor: params.headHeightFactor,
                        maxAreaFraction: params.maxAreaFraction,
                        segmentationMask: segmentationMask,
                        subjectComponent: nil
                    )
                }
            }

            let sourceCI = CIImage(cvPixelBuffer: pixelBuffer)
            blurFilter.setValue(sourceCI, forKey: kCIInputImageKey)
            blurFilter.setValue(blurRadius, forKey: kCIInputRadiusKey)
            let blurredCI = (blurFilter.outputImage ?? sourceCI).cropped(to: sourceCI.extent)
            let maskBytes = Data(bytes: keepMask, count: totalPx)
            let maskCI = CIImage(
                bitmapData: maskBytes,
                bytesPerRow: videoWidth,
                size: CGSize(width: videoWidth, height: videoHeight),
                format: .R8,
                colorSpace: CGColorSpaceCreateDeviceGray()
            )
            blendFilter.setValue(sourceCI, forKey: kCIInputImageKey)
            blendFilter.setValue(blurredCI, forKey: kCIInputBackgroundImageKey)
            blendFilter.setValue(maskCI, forKey: kCIInputMaskImageKey)
            if let outputCI = blendFilter.outputImage {
                let renderColorSpace = CGColorSpaceCreateDeviceRGB()
                ciContext.render(
                    outputCI, to: outBuffer,
                    bounds: sourceCI.extent,
                    colorSpace: renderColorSpace
                )
            } else {
                copyVerbatim(source: pixelBuffer, into: outBuffer)
            }

            // Append — wait for the input to be ready. expectsMediaDataInRealTime
            // is false so this is a tight serial loop.
            while !writerInput.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.001)
            }
            _ = adaptor.append(outBuffer, withPresentationTime: presentationTime)

            framesProcessed += 1
            if faceObservations.isEmpty && segmentationMask == nil {
                framesMissed += 1
            }
        }

        writerInput.markAsFinished()
        let finishSem = DispatchSemaphore(value: 0)
        writer.finishWriting { finishSem.signal() }
        finishSem.wait()
        reader.cancelReading()

        let endNs = Date().timeIntervalSince1970 * 1000.0
        let durationMs = Int(endNs - startNs)
        let safeMissRate: Double = framesProcessed == 0
            ? 0.0
            : Double(framesMissed) / Double(framesProcessed)
        let avgCosSim: Double = subjectCosSimSamples == 0
            ? 0.0
            : subjectCosSimSum / Double(subjectCosSimSamples)
        let avgFaceCount: Double = framesProcessed == 0
            ? 0.0
            : Double(totalFaceCount) / Double(framesProcessed)

        if writer.status != .completed {
            throw SafeModeV2VideoPipelineError.writerFailed(
                writer.error?.localizedDescription ?? "writer status=\(writer.status.rawValue)"
            )
        }
        _ = estimatedTotalFrames  // referenced for parity with iOS; unused here

        return SafeModeV2VideoBenchReport(
            srcPath: srcPath,
            destPath: destPath,
            frameCount: framesProcessed,
            durationSeconds: durationSeconds,
            frameRate: frameRate,
            width: videoWidth,
            height: videoHeight,
            framesProcessed: framesProcessed,
            framesMissed: framesMissed,
            safeMissRate: safeMissRate,
            subjectIdentifiedFrames: subjectIdentifiedFrames,
            trackerLossEvents: trackerLossEvents,
            reSeedEvents: reSeedEvents,
            reConfirmEvents: reConfirmEvents,
            avgSubjectCosSim: avgCosSim,
            avgFaceCount: avgFaceCount,
            durationMs: durationMs
        )
    }

    // MARK: - Helpers (mirror iOS `SafeModeV2VideoProcessor`)

    struct StateMachineStep {
        let subjectFaceIdx: Int?
        let cosSim: Double?
    }

    static func buildDetectedFaces(
        observations: [VNFaceObservation],
        width: Int,
        height: Int
    ) -> [DetectedFaceV2] {
        var out: [DetectedFaceV2] = []
        for obs in observations {
            let r = obs.boundingBox
            let padFactor: CGFloat = 0.20
            let padW = r.width * padFactor
            let padH = r.height * padFactor
            let nx0 = max(0, r.origin.x - padW)
            let ny0Bot = max(0, r.origin.y - padH)
            let nw = min(1.0, r.width + 2 * padW)
            let nh = min(1.0, r.height + 2 * padH)
            let px0 = nx0 * CGFloat(width)
            let py0Top = CGFloat(height) - (ny0Bot + nh) * CGFloat(height)
            let pw = nw * CGFloat(width)
            let ph = nh * CGFloat(height)
            let pixelRect = CGRect(
                x: max(0, px0).rounded(.down),
                y: max(0, py0Top).rounded(.down),
                width: pw.rounded(.up),
                height: ph.rounded(.up)
            )
            if pixelRect.width < 8 || pixelRect.height < 8 { continue }
            let cxNormBot = r.origin.x + r.width * 0.5
            let cyNormBot = r.origin.y + r.height * 0.5
            let cxPx = Int((cxNormBot * CGFloat(width)).rounded())
            let cyPx = Int(((1.0 - cyNormBot) * CGFloat(height)).rounded())
            let contour = SafeModeV2Pipeline.faceContourPolygonPx(
                observation: obs,
                imageWidth: width,
                imageHeight: height,
                outwardExpansionFactor: 1.25
            )
            out.append(DetectedFaceV2(
                normalizedRect: r,
                pixelRectTopLeft: pixelRect,
                centerXPx: max(0, min(width - 1, cxPx)),
                centerYPx: max(0, min(height - 1, cyPx)),
                contourPolygonPx: contour
            ))
        }
        return out
    }

    static func embedFaceFromBuffer(
        pixelBuffer: CVPixelBuffer,
        pixelRect: CGRect
    ) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let bufH = CVPixelBufferGetHeight(pixelBuffer)
        let cropRectBL = CGRect(
            x: pixelRect.origin.x,
            y: CGFloat(bufH) - pixelRect.origin.y - pixelRect.height,
            width: pixelRect.width,
            height: pixelRect.height
        )
        let ctx: CIContext
        if let device = MTLCreateSystemDefaultDevice() {
            ctx = CIContext(mtlDevice: device)
        } else {
            ctx = CIContext()
        }
        let cropped = ciImage.cropped(to: cropRectBL)
        guard let cg = ctx.createCGImage(cropped, from: cropped.extent) else { return nil }
        let cropW = Int(pixelRect.width)
        let cropH = Int(pixelRect.height)
        guard cropW > 0, cropH > 0 else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 =
            CGBitmapInfo.byteOrder32Little.rawValue |
            CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let flipCtx = CGContext(
            data: nil, width: cropW, height: cropH,
            bitsPerComponent: 8, bytesPerRow: cropW * 4,
            space: colorSpace, bitmapInfo: bitmapInfo
        ) else { return nil }
        flipCtx.translateBy(x: 0, y: CGFloat(cropH))
        flipCtx.scaleBy(x: 1, y: -1)
        flipCtx.draw(cg, in: CGRect(x: 0, y: 0, width: cropW, height: cropH))
        guard let upright = flipCtx.makeImage() else { return nil }
        return try? MobileFaceNetEmbedder.shared.embed(face: upright)
    }

    struct PickOutcome {
        let subjectFaceIdx: Int?
        let bestSim: Double
    }

    static func runFaceRecPick(
        pixelBuffer: CVPixelBuffer,
        detectedFaces: [DetectedFaceV2],
        subjectEmbeddingSlots: [Data],
        soloFloor: Double
    ) -> PickOutcome {
        if detectedFaces.isEmpty {
            return PickOutcome(subjectFaceIdx: nil, bestSim: -2.0)
        }
        var perFaceCosSim: [Double] = []
        perFaceCosSim.reserveCapacity(detectedFaces.count)
        for f in detectedFaces {
            guard let embed = embedFaceFromBuffer(
                pixelBuffer: pixelBuffer,
                pixelRect: f.pixelRectTopLeft
            ) else {
                perFaceCosSim.append(-1.0)
                continue
            }
            var bestRef: Double = -2.0
            for ref in subjectEmbeddingSlots {
                let s = MobileFaceNetEmbedder.cosineSimilarity(embed, ref)
                if s > bestRef { bestRef = s }
            }
            perFaceCosSim.append(bestRef)
        }
        var bestIdx: Int? = nil
        var bestSim: Double = -2.0
        for (i, sim) in perFaceCosSim.enumerated() {
            if sim > bestSim {
                bestSim = sim
                bestIdx = i
            }
        }
        let subjectIdentified: Bool
        if detectedFaces.count == 1 {
            subjectIdentified = (bestSim >= soloFloor)
        } else {
            subjectIdentified = true
        }
        return PickOutcome(
            subjectFaceIdx: subjectIdentified ? bestIdx : nil,
            bestSim: bestSim
        )
    }

    static func doReConfirm(
        state: inout State,
        trackObservation: inout VNDetectedObjectObservation?,
        subjectBboxNormalized: inout CGRect?,
        subjectBboxPixelTopLeft: inout CGRect?,
        lastReConfirmFrameIdx: inout Int,
        reConfirmEvents: inout Int,
        reSeedEvents: inout Int,
        frameIdx: Int,
        reSeedRadiusPx: Double,
        pixelBuffer: CVPixelBuffer,
        detectedFaces: [DetectedFaceV2],
        subjectEmbeddingSlots: [Data],
        soloFloor: Double
    ) -> StateMachineStep {
        reConfirmEvents += 1
        lastReConfirmFrameIdx = frameIdx
        let pick = runFaceRecPick(
            pixelBuffer: pixelBuffer,
            detectedFaces: detectedFaces,
            subjectEmbeddingSlots: subjectEmbeddingSlots,
            soloFloor: soloFloor
        )
        if let idx = pick.subjectFaceIdx {
            let candidate = detectedFaces[idx]
            if let prevBbox = subjectBboxPixelTopLeft {
                let dx = Double(candidate.centerXPx) - Double(prevBbox.midX)
                let dy = Double(candidate.centerYPx) - Double(prevBbox.midY)
                let dist = (dx * dx + dy * dy).squareRoot()
                if dist < reSeedRadiusPx {
                    state = .tracking
                    return StateMachineStep(subjectFaceIdx: idx, cosSim: pick.bestSim)
                }
            }
            trackObservation = VNDetectedObjectObservation(boundingBox: candidate.normalizedRect)
            subjectBboxNormalized = candidate.normalizedRect
            subjectBboxPixelTopLeft = candidate.pixelRectTopLeft
            state = .tracking
            reSeedEvents += 1
            return StateMachineStep(subjectFaceIdx: idx, cosSim: pick.bestSim)
        }
        state = .noSubject
        trackObservation = nil
        subjectBboxNormalized = nil
        subjectBboxPixelTopLeft = nil
        return StateMachineStep(subjectFaceIdx: nil, cosSim: nil)
    }

    static func pixelRectTopLeftFromNormalized(
        _ r: CGRect, width: Int, height: Int
    ) -> CGRect {
        let nx0 = max(0, r.origin.x)
        let ny0Bot = max(0, r.origin.y)
        let nw = min(1.0 - nx0, r.width)
        let nh = min(1.0 - ny0Bot, r.height)
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

    static func faceIndexNearestToBbox(
        bbox: CGRect, faces: [DetectedFaceV2]
    ) -> Int? {
        if faces.isEmpty { return nil }
        let bcx = bbox.midX
        let bcy = bbox.midY
        var bestIdx = 0
        var bestDistSq = Double.infinity
        for (i, f) in faces.enumerated() {
            let dx = Double(f.centerXPx) - Double(bcx)
            let dy = Double(f.centerYPx) - Double(bcy)
            let d2 = dx * dx + dy * dy
            if d2 < bestDistSq {
                bestDistSq = d2
                bestIdx = i
            }
        }
        return bestIdx
    }

    static func copyVerbatim(source: CVPixelBuffer, into dest: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(source, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        CVPixelBufferLockBaseAddress(dest, [])
        defer { CVPixelBufferUnlockBaseAddress(dest, []) }
        guard let s = CVPixelBufferGetBaseAddress(source),
              let d = CVPixelBufferGetBaseAddress(dest) else { return }
        let srcRow = CVPixelBufferGetBytesPerRow(source)
        let dstRow = CVPixelBufferGetBytesPerRow(dest)
        let h = CVPixelBufferGetHeight(source)
        let w = CVPixelBufferGetWidth(source)
        let sPtr = s.assumingMemoryBound(to: UInt8.self)
        let dPtr = d.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            memcpy(dPtr + y * dstRow, sPtr + y * srcRow, w * 4)
        }
    }
}
