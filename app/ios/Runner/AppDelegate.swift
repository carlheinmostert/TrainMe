import Flutter
import UIKit
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    // Get the Flutter engine's binary messenger via the plugin registry.
    // This avoids depending on window.rootViewController which may not be
    // set as a FlutterViewController during didFinishLaunchingWithOptions
    // in Flutter 3.41.6's newer engine lifecycle.
    let messenger = self.registrar(forPlugin: "VideoConverterPlugin")!.messenger()

    // Register a simple thumbnail extraction channel.
    // This bypasses video_thumbnail package issues.
    let thumbChannel = FlutterMethodChannel(
      name: "com.raidme.native_thumb",
      binaryMessenger: messenger
    )

    thumbChannel.setMethodCallHandler { (call, result) in
      if call.method == "extractFrame" {
        guard let args = call.arguments as? [String: Any],
              let inputPath = args["inputPath"] as? String,
              let outputPath = args["outputPath"] as? String else {
          result(FlutterError(code: "ARGS", message: "Missing inputPath or outputPath", details: nil))
          return
        }
        let timeMs = args["timeMs"] as? Int ?? 0

        DispatchQueue.global(qos: .userInitiated).async {
          let url = URL(fileURLWithPath: inputPath)
          let asset = AVURLAsset(url: url)
          let generator = AVAssetImageGenerator(asset: asset)
          generator.appliesPreferredTrackTransform = true
          generator.requestedTimeToleranceBefore = .zero
          generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

          let time = CMTime(value: CMTimeValue(timeMs), timescale: 1000)

          do {
            let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
            let uiImage = UIImage(cgImage: cgImage)
            guard let jpegData = uiImage.jpegData(compressionQuality: 0.9) else {
              DispatchQueue.main.async {
                result(FlutterError(code: "JPEG", message: "Failed to create JPEG", details: nil))
              }
              return
            }
            try jpegData.write(to: URL(fileURLWithPath: outputPath))
            DispatchQueue.main.async {
              result(outputPath)
            }
          } catch {
            DispatchQueue.main.async {
              result(FlutterError(code: "EXTRACT", message: "Frame extraction failed: \(error.localizedDescription)", details: "\(error)"))
            }
          }
        }
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    // Register the full video converter channel using the same messenger.
    let _ = VideoConverterChannel(messenger: messenger)

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
