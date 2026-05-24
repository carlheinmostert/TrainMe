//
//  main.swift  (SafeModeBench)
//
//  CLI front-end for the Safe Mode v2 photo-pipeline bench. Reads a
//  source JPG + a raw FP32 embedding blob, runs the pipeline with the
//  supplied threshold + head-expansion params, writes the safe variant
//  to destPath, and prints the diagnostic block to stdout.
//
//  Stdout format is line-oriented (one fact per line) so sweep.sh +
//  summary.py can parse it without an extra serialisation layer.

import Foundation

// MARK: - Arg parsing

struct ParsedArgs {
    var photo: String = ""
    var embedding: String = ""
    var output: String = ""
    var threshold: Double = 0.5
    var areaClamp: Double = 0.35
    var headExpandW: Double = 2.0
    var headExpandH: Double = 1.5
    var maxWorkDim: Int = 1920
    var showHelp: Bool = false
}

func parseArgs(_ raw: [String]) -> (ParsedArgs, String?) {
    var a = ParsedArgs()
    var i = 1
    let args = raw
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "-h", "--help":
            a.showHelp = true
            i += 1
        case "--photo":
            guard i + 1 < args.count else { return (a, "--photo requires a value") }
            a.photo = args[i + 1]; i += 2
        case "--embedding":
            guard i + 1 < args.count else { return (a, "--embedding requires a value") }
            a.embedding = args[i + 1]; i += 2
        case "--output":
            guard i + 1 < args.count else { return (a, "--output requires a value") }
            a.output = args[i + 1]; i += 2
        case "--threshold":
            guard i + 1 < args.count, let v = Double(args[i + 1]) else { return (a, "--threshold requires a number") }
            a.threshold = v; i += 2
        case "--area-clamp":
            guard i + 1 < args.count, let v = Double(args[i + 1]) else { return (a, "--area-clamp requires a number") }
            a.areaClamp = v; i += 2
        case "--head-expand-w":
            guard i + 1 < args.count, let v = Double(args[i + 1]) else { return (a, "--head-expand-w requires a number") }
            a.headExpandW = v; i += 2
        case "--head-expand-h":
            guard i + 1 < args.count, let v = Double(args[i + 1]) else { return (a, "--head-expand-h requires a number") }
            a.headExpandH = v; i += 2
        case "--max-work-dim":
            guard i + 1 < args.count, let v = Int(args[i + 1]) else { return (a, "--max-work-dim requires an integer") }
            a.maxWorkDim = v; i += 2
        default:
            return (a, "Unknown argument: \(arg)")
        }
    }
    return (a, nil)
}

let usage = """
SafeModeBench — macOS CLI bench for the Safe Mode v2 photo pipeline.

Mirrors the `applySafeModeV2ToPhoto` flow in
app/ios/Runner/VideoConverterChannel.swift byte-for-byte and prints the
internal decisions (per-face cosSim, subject choice, mask coverage,
blur fraction) so we can debug the all-frame-blur bug without device
cycles.

USAGE:
  swift run SafeModeBench \\
    --photo <path.jpg> \\
    --embedding <path.bin> \\
    [--threshold 0.5] \\
    [--area-clamp 0.35] \\
    [--head-expand-w 2.0] \\
    [--head-expand-h 1.5] \\
    [--max-work-dim 1920] \\
    --output <safe.jpg>

ARGS:
  --photo          Source JPG (selfie / capture frame to debug).
  --embedding      Raw FP32 little-endian face embedding (2048 bytes).
                   See fetch_embedding.sh for pulling it from Supabase.
  --output         Where to write the safe-variant JPG.
  --threshold      Cosine-sim threshold for subjectIdentified (default 0.5).
  --area-clamp     Max fraction of frame each head-expansion may cover
                   (default 0.35 matches iOS).
  --head-expand-w  Face bbox horizontal multiplier (default 2.0).
  --head-expand-h  Face bbox vertical multiplier   (default 1.5).
  --max-work-dim   Max working pixel dim (default 1920 matches iOS).

DIAGNOSTIC OUTPUT:
  Per detected face: bbox + cosSim + rank.
  DECISION: subjectIdentified + bestSim + threshold + subjectIdx.
  SEGMENTATION: maskPositive / totalPixels (% of frame Vision marked as person).
  FLOOD-FILL: subjectComponent pixels (% of mask-positive).
  COMPOSITE: blurFraction (% of frame painted to blur).
  OUTPUT: written safe-variant path.
"""

let (parsed, parseErr) = parseArgs(CommandLine.arguments)

if parsed.showHelp || CommandLine.arguments.count == 1 {
    print(usage)
    exit(parsed.showHelp ? 0 : 1)
}

if let err = parseErr {
    FileHandle.standardError.write("error: \(err)\n\n".data(using: .utf8)!)
    print(usage)
    exit(2)
}

if parsed.photo.isEmpty || parsed.embedding.isEmpty || parsed.output.isEmpty {
    FileHandle.standardError.write("error: --photo, --embedding, and --output are all required.\n\n".data(using: .utf8)!)
    print(usage)
    exit(2)
}

// MARK: - Load embedding

let embeddingURL = URL(fileURLWithPath: parsed.embedding)
let embeddingData: Data
do {
    embeddingData = try Data(contentsOf: embeddingURL)
} catch {
    FileHandle.standardError.write("error: could not read embedding at \(parsed.embedding): \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(3)
}

if embeddingData.count != MobileFaceNetEmbedder.embeddingByteLength {
    FileHandle.standardError.write(
        "error: embedding wrong size — got \(embeddingData.count) bytes, expected \(MobileFaceNetEmbedder.embeddingByteLength) (= 512 FP32).\n"
            .data(using: .utf8)!
    )
    exit(3)
}

// Sanity-check: an L2-normalized FP32 vector should have norm ~= 1.0.
// Print as part of the diagnostic block so a corrupted embedding (e.g.
// hex-decoded vs raw bytes) is immediately visible.
let embeddingNorm: Double = embeddingData.withUnsafeBytes { buf -> Double in
    let ptr = buf.bindMemory(to: Float32.self)
    var s: Double = 0
    for i in 0..<MobileFaceNetEmbedder.embeddingDimension {
        let v = Double(ptr[i])
        s += v * v
    }
    return s.squareRoot()
}

// MARK: - Run pipeline

var params = SafeModeV2PipelineParams()
params.threshold = parsed.threshold
params.headWidthFactor = CGFloat(parsed.headExpandW)
params.headHeightFactor = CGFloat(parsed.headExpandH)
params.maxAreaFraction = parsed.areaClamp
params.maxWorkDim = parsed.maxWorkDim

print("------------------------------------------------------------")
print("SafeModeBench v1")
print("photo:        \(parsed.photo)")
print("embedding:    \(parsed.embedding) (\(embeddingData.count) bytes, L2 norm=\(String(format: "%.4f", embeddingNorm)))")
print("threshold:    \(String(format: "%.3f", parsed.threshold))")
print("areaClamp:    \(String(format: "%.3f", parsed.areaClamp))")
print("headExpand:   w=\(String(format: "%.2f", parsed.headExpandW)) h=\(String(format: "%.2f", parsed.headExpandH))")
print("maxWorkDim:   \(parsed.maxWorkDim)")
print("------------------------------------------------------------")

let startTs = Date()
do {
    let report = try SafeModeV2Pipeline.run(
        srcPath: parsed.photo,
        destPath: parsed.output,
        subjectEmbedding: embeddingData,
        params: params
    )
    let elapsedMs = Date().timeIntervalSince(startTs) * 1000.0

    print("frame:        \(report.width)x\(report.height) (\(report.totalPixels) px)")
    print("faces:        \(report.faces.count)")
    for f in report.faces {
        let bbox = String(
            format: "(%.0f,%.0f,%.0fx%.0f)",
            f.bboxPixels.origin.x, f.bboxPixels.origin.y,
            f.bboxPixels.width, f.bboxPixels.height
        )
        print(String(
            format: "face[%d]: bbox=%@ pixels  cosSim=%.4f  rank=%d",
            f.index, bbox, f.cosSim, f.rank
        ))
    }
    print(String(
        format: "DECISION: subjectIdentified=%@  subjectIdx=%@  bestSim=%.4f  threshold=%.4f",
        report.subjectIdentified ? "true" : "false",
        report.subjectIdx.map { String($0) } ?? "nil",
        report.bestSim,
        report.threshold
    ))
    let maskFraction = (report.totalPixels > 0)
        ? Double(report.maskPositivePixels) / Double(report.totalPixels)
        : 0.0
    print(String(
        format: "SEGMENTATION: maskPositivePixels=%d / totalPixels=%d (%.1f%%)",
        report.maskPositivePixels, report.totalPixels, maskFraction * 100.0
    ))
    if report.subjectIdentified {
        let subjFraction = (report.maskPositivePixels > 0)
            ? Double(report.subjectComponentPixels) / Double(report.maskPositivePixels)
            : 0.0
        print(String(
            format: "FLOOD-FILL: subjectComponentPixels=%d (%.1f%% of mask-positive)",
            report.subjectComponentPixels, subjFraction * 100.0
        ))
    } else {
        print("FLOOD-FILL: (skipped — no subject identified)")
    }
    let blurFraction = (report.totalPixels > 0)
        ? Double(report.blurPixels) / Double(report.totalPixels)
        : 0.0
    print(String(
        format: "COMPOSITE: blurPixels=%d (%.1f%% of frame painted to blur target)",
        report.blurPixels, blurFraction * 100.0
    ))
    print("OUTPUT: written to \(report.outputPath)")
    print(String(format: "elapsed:      %.1f ms", elapsedMs))
    exit(0)
} catch {
    FileHandle.standardError.write("pipeline error: \(error)\n".data(using: .utf8)!)
    exit(4)
}
