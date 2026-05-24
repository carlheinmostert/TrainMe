//
//  main.swift  (SafeModeBench)
//
//  CLI front-end for the Safe Mode v2 photo-pipeline bench. Reads a
//  source JPG + one or more raw FP32 embedding blobs, runs the pipeline
//  with the supplied threshold + head-expansion params, writes the safe
//  variant to destPath, and prints the diagnostic block to stdout.
//
//  Stdout format is line-oriented (one fact per line) so sweep.sh +
//  summary.py can parse it without an extra serialisation layer.
//
//  Multi-reference (2026-05-24): the bench now accepts an N-way
//  reference set via `--embeddings file1,file2,...` mirroring the
//  iOS native multi-reference signature. The legacy `--embedding file`
//  flag stays for back-compat — it's internally wrapped in a one-element
//  list before being handed to the pipeline. The `--smoke-test` mode
//  asserts that --embedding === --embeddings with the same file
//  duplicated (byte-equality of the output JPG) — a regression guard
//  on the per-face max degeneration to single-cosSim when N=1.

import Foundation

// MARK: - Arg parsing

struct ParsedArgs {
    var photo: String = ""
    /// Singular --embedding path. Kept for back-compat. When present
    /// it's wrapped in a one-element list before being handed to the
    /// pipeline.
    var embedding: String = ""
    /// Plural --embeddings comma-separated paths. When present it
    /// takes precedence over --embedding.
    var embeddings: [String] = []
    var output: String = ""
    var threshold: Double = 0.5
    var areaClamp: Double = 0.35
    var headExpandW: Double = 2.0
    var headExpandH: Double = 1.5
    var maxWorkDim: Int = 1920
    var showHelp: Bool = false
    /// When true: run the pipeline TWICE — once with --embedding (single)
    /// and once with --embeddings <same file>,<same file> — and assert
    /// the output JPG byte-equality. Exits non-zero on mismatch.
    var smokeTest: Bool = false
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
        case "--embeddings":
            guard i + 1 < args.count else { return (a, "--embeddings requires a value") }
            // Comma-separated list of file paths.
            let listArg = args[i + 1]
            let paths = listArg.split(separator: ",", omittingEmptySubsequences: true).map { String($0) }
            if paths.isEmpty {
                return (a, "--embeddings requires a non-empty comma-separated list")
            }
            a.embeddings = paths
            i += 2
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
        case "--smoke-test":
            a.smokeTest = true
            i += 1
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
    (--embedding <path.bin> | --embeddings <p1.bin,p2.bin,...,pN.bin>) \\
    [--threshold 0.5] \\
    [--area-clamp 0.35] \\
    [--head-expand-w 2.0] \\
    [--head-expand-h 1.5] \\
    [--max-work-dim 1920] \\
    --output <safe.jpg>

  swift run SafeModeBench --smoke-test \\
    --photo <path.jpg> \\
    --embedding <path.bin> \\
    --output <safe-tmp.jpg>

ARGS:
  --photo          Source JPG (selfie / capture frame to debug).
  --embedding      Raw FP32 little-endian face embedding (2048 bytes).
                   Internally wrapped in a one-element list. Back-compat
                   path — new sweeps should prefer --embeddings.
                   See fetch_embedding.sh for pulling it from Supabase.
  --embeddings     Comma-separated list of 1–8 raw FP32 embedding files
                   (each 2048 bytes). Mirrors the iOS native
                   `subjectEmbeddings: [Data]` parameter shape. Per-face
                   cosSim is taken as the MAX across all references.
  --output         Where to write the safe-variant JPG.
  --threshold      Solo-face cosSim floor (default 0.5 for back-compat
                   with prior sweep scripts; production iOS now defaults
                   to 0.10 via kSafeModeV2SoloFloor). Only consulted in
                   the solo branch — multi-face frames use a relative
                   pick (highest cosSim wins; no absolute gate).
  --area-clamp     Max fraction of frame each head-expansion may cover
                   (default 0.35 matches iOS).
  --head-expand-w  Face bbox horizontal multiplier (default 2.0).
  --head-expand-h  Face bbox vertical multiplier   (default 1.5).
  --max-work-dim   Max working pixel dim (default 1920 matches iOS).
  --smoke-test     Regression guard for the multi-reference change.
                   Runs the pipeline TWICE — once with --embedding (a
                   single reference) and once with --embeddings <same
                   file>,<same file> — then byte-compares the output
                   JPGs. Exits 0 if identical, 5 if they differ. Use
                   to confirm the per-face max degenerates to single
                   cosSim when N=1.

DIAGNOSTIC OUTPUT:
  Per detected face: bbox + cosSim + rank.
  DECISION: subjectIdentified + bestSim + soloFloor + subjectIdx + branch
            (branch ∈ {no-faces, solo-floor, multi-relative}).
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

if parsed.photo.isEmpty || parsed.output.isEmpty {
    FileHandle.standardError.write("error: --photo and --output are required.\n\n".data(using: .utf8)!)
    print(usage)
    exit(2)
}
if parsed.embedding.isEmpty && parsed.embeddings.isEmpty {
    FileHandle.standardError.write(
        "error: one of --embedding or --embeddings is required.\n\n".data(using: .utf8)!
    )
    print(usage)
    exit(2)
}

// MARK: - Load embeddings

/// Read one embedding file from disk + sanity-check its size.
func loadEmbedding(_ path: String) -> Data? {
    let url = URL(fileURLWithPath: path)
    do {
        let data = try Data(contentsOf: url)
        if data.count != MobileFaceNetEmbedder.embeddingByteLength {
            FileHandle.standardError.write(
                "error: embedding at \(path) wrong size — got \(data.count) bytes, expected \(MobileFaceNetEmbedder.embeddingByteLength) (= 512 FP32).\n"
                    .data(using: .utf8)!
            )
            return nil
        }
        return data
    } catch {
        FileHandle.standardError.write(
            "error: could not read embedding at \(path): \(error.localizedDescription)\n"
                .data(using: .utf8)!
        )
        return nil
    }
}

/// L2 norm of an FP32 embedding for the sanity-print at the top of the
/// diagnostic block. Should be ~1.0 for a properly L2-normalised vector;
/// any large deviation means the bytes are wrong (hex vs raw, partial
/// download, etc.).
func l2Norm(_ data: Data) -> Double {
    return data.withUnsafeBytes { buf -> Double in
        let ptr = buf.bindMemory(to: Float32.self)
        var s: Double = 0
        for i in 0..<MobileFaceNetEmbedder.embeddingDimension {
            let v = Double(ptr[i])
            s += v * v
        }
        return s.squareRoot()
    }
}

// MARK: - Smoke-test branch

if parsed.smokeTest {
    if parsed.embedding.isEmpty {
        FileHandle.standardError.write(
            "error: --smoke-test requires --embedding (the single reference is duplicated for the N=2 leg).\n"
                .data(using: .utf8)!
        )
        exit(2)
    }
    guard let baseEmbed = loadEmbedding(parsed.embedding) else { exit(3) }

    var params = SafeModeV2PipelineParams()
    params.threshold = parsed.threshold
    params.headWidthFactor = CGFloat(parsed.headExpandW)
    params.headHeightFactor = CGFloat(parsed.headExpandH)
    params.maxAreaFraction = parsed.areaClamp
    params.maxWorkDim = parsed.maxWorkDim

    let singleOutPath = parsed.output + ".smoke-single.jpg"
    let dupOutPath = parsed.output + ".smoke-duplicated.jpg"

    print("SMOKE-TEST: running pipeline twice — N=1 (single reference) then N=2 (duplicated reference).")
    print("  pass 1: --embedding -> \(singleOutPath)")
    do {
        _ = try SafeModeV2Pipeline.run(
            srcPath: parsed.photo,
            destPath: singleOutPath,
            subjectEmbeddings: [baseEmbed],
            params: params
        )
    } catch {
        FileHandle.standardError.write(
            "smoke-test pipeline 1 error: \(error)\n".data(using: .utf8) ?? Data()
        )
        exit(4)
    }
    print("  pass 2: --embeddings <same>,<same> -> \(dupOutPath)")
    do {
        _ = try SafeModeV2Pipeline.run(
            srcPath: parsed.photo,
            destPath: dupOutPath,
            subjectEmbeddings: [baseEmbed, baseEmbed],
            params: params
        )
    } catch {
        FileHandle.standardError.write(
            "smoke-test pipeline 2 error: \(error)\n".data(using: .utf8) ?? Data()
        )
        exit(4)
    }

    guard let bytesSingle = try? Data(contentsOf: URL(fileURLWithPath: singleOutPath)) else {
        FileHandle.standardError.write(
            "smoke-test: could not read \(singleOutPath)\n".data(using: .utf8) ?? Data()
        )
        exit(5)
    }
    guard let bytesDup = try? Data(contentsOf: URL(fileURLWithPath: dupOutPath)) else {
        FileHandle.standardError.write(
            "smoke-test: could not read \(dupOutPath)\n".data(using: .utf8) ?? Data()
        )
        exit(5)
    }
    if bytesSingle == bytesDup {
        print("SMOKE-TEST PASS: N=1 and N=2 (duplicated reference) produced byte-identical output (\(bytesSingle.count) bytes).")
        exit(0)
    } else {
        FileHandle.standardError.write(
            "SMOKE-TEST FAIL: N=1 (\(bytesSingle.count) bytes) and N=2 (\(bytesDup.count) bytes) outputs differ — per-face max does not degenerate to single cosSim correctly.\n"
                .data(using: .utf8) ?? Data()
        )
        exit(5)
    }
}

// MARK: - Standard (non-smoke-test) branch

var subjectEmbeddings: [Data] = []
var embeddingLabels: [String] = []

if !parsed.embeddings.isEmpty {
    if parsed.embeddings.count > 8 {
        FileHandle.standardError.write(
            "error: --embeddings supports at most 8 references (got \(parsed.embeddings.count)).\n"
                .data(using: .utf8)!
        )
        exit(2)
    }
    for path in parsed.embeddings {
        guard let data = loadEmbedding(path) else { exit(3) }
        subjectEmbeddings.append(data)
        embeddingLabels.append(path)
    }
} else {
    guard let data = loadEmbedding(parsed.embedding) else { exit(3) }
    subjectEmbeddings.append(data)
    embeddingLabels.append(parsed.embedding)
}

// MARK: - Run pipeline

var params = SafeModeV2PipelineParams()
params.threshold = parsed.threshold
params.headWidthFactor = CGFloat(parsed.headExpandW)
params.headHeightFactor = CGFloat(parsed.headExpandH)
params.maxAreaFraction = parsed.areaClamp
params.maxWorkDim = parsed.maxWorkDim

print("------------------------------------------------------------")
print("SafeModeBench v2 (multi-reference)")
print("photo:        \(parsed.photo)")
print("references:   \(subjectEmbeddings.count)")
for (i, label) in embeddingLabels.enumerated() {
    let norm = l2Norm(subjectEmbeddings[i])
    print("  [\(i)] \(label) (\(subjectEmbeddings[i].count) bytes, L2 norm=\(String(format: "%.4f", norm)))")
}
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
        subjectEmbeddings: subjectEmbeddings,
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
    // Derive the hybrid-pick branch reason from face count for log
    // readability. Mirrors the iOS native pipeline log format.
    let branchReason: String
    if report.faces.isEmpty {
        branchReason = "no-faces"
    } else if report.faces.count == 1 {
        branchReason = "solo-floor"
    } else {
        branchReason = "multi-relative"
    }
    print(String(
        format: "DECISION: subjectIdentified=%@  subjectIdx=%@  bestSim=%.4f  soloFloor=%.4f  branch=%@",
        report.subjectIdentified ? "true" : "false",
        report.subjectIdx.map { String($0) } ?? "nil",
        report.bestSim,
        report.threshold,
        branchReason
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
