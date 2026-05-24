// swift-tools-version:6.0
//
// safe-mode-v2-bench
//
// Standalone macOS CLI for debugging the Safe Mode v2 photo pipeline
// that lives in app/ios/Runner/VideoConverterChannel.swift. Mirrors the
// `applySafeModeV2ToPhoto` pipeline byte-for-byte (CoreML + Vision +
// CoreImage are all macOS-compatible) so we can iterate on cosine-sim
// thresholds + head-expansion params without device cycles.
//
// macOS 15 is the deployment floor: the iOS pipeline targets iOS 15 for
// VNGeneratePersonSegmentationRequest; the macOS 12 equivalent has the
// same API but we pin to macOS 15+ because Carl's dev machine is on
// Sequoia and there's no reason to support older targets.

import PackageDescription

let package = Package(
    name: "SafeModeBench",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .executableTarget(
            name: "SafeModeBench",
            path: "Sources/SafeModeBench",
            resources: [
                // .process() runs the .mlmodel through coremlcompiler at
                // build time, producing a .mlmodelc that we load via
                // Bundle.module.url(forResource:withExtension:). Same
                // mechanism Xcode uses for the iOS app target.
                .process("MobileFaceNet.mlmodel")
            ],
            swiftSettings: [
                // CLI runs strictly serially — no actor isolation needed.
                // The iOS target uses Swift 5 conventions; we mirror that
                // here so the extracted code compiles without rewriting
                // the singleton + DispatchQueue pattern.
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
