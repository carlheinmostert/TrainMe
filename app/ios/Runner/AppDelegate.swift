import Flutter
import UIKit
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate {
  // Retain the video converter channel as a stored property. Prevents
  // the instance from being released and losing its method-call handler.
  private var videoConverter: VideoConverterChannel?

  // Wave 40.5 — native haptic feedback channel. Bypasses iOS's suppression
  // of Flutter HapticFeedback.* while AVCaptureSession holds the audio engine.
  private var haptics: HomefitHapticsChannel?

  // Wave 4 Phase 2 — iOS AVAudioSession owner for the embedded
  // web-player WebView. Stored here so the handler isn't deallocated
  // the moment the `didFinishLaunchingWithOptions` scope ends.
  private var unifiedPreviewAudio: UnifiedPreviewAudioChannel?

  // Wave 34 — native AVFoundation camera glass for the client-avatar
  // capture surface (only). Bypasses the Flutter `camera` plugin's
  // virtual multi-cam device which produced fish-eyed avatars on
  // multi-lens iPhones. See AvatarCameraChannel.swift for the why.
  private var avatarCamera: AvatarCameraChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    // Get the Flutter engine's binary messenger via the plugin registry.
    // This avoids depending on window.rootViewController which may not be
    // set as a FlutterViewController during didFinishLaunchingWithOptions
    // in Flutter 3.41.6's newer engine lifecycle.
    guard let registrar = self.registrar(forPlugin: "VideoConverterPlugin") else {
      NSLog("Failed to obtain VideoConverterPlugin registrar")
      return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
    let messenger = registrar.messenger()

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

        // Defense in depth: verify the input file exists and is readable.
        guard FileManager.default.fileExists(atPath: inputPath),
              FileManager.default.isReadableFile(atPath: inputPath) else {
          result(FlutterError(
            code: "FILE_NOT_FOUND",
            message: "Input file does not exist or is not readable: \(inputPath)",
            details: nil
          ))
          return
        }

        let timeMs = args["timeMs"] as? Int ?? 0
        // Optional: when true, ignore `timeMs` and pick a motion-peak
        // frame natively + crop tight around the person. See
        // VideoConverterChannel.pickMotionPeakTime for the heuristic.
        let autoPick = args["autoPick"] as? Bool ?? false
        // Optional: when true, recolour the extracted frame to
        // luminance (B&W) before JPEG encoding. Used by practitioner-
        // facing list thumbnails where the grayscale frame is more
        // legible at small sizes than the body-masked line-drawing look.
        let grayscale = args["grayscale"] as? Bool ?? false

        let url = URL(fileURLWithPath: inputPath)
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // autoPick needs slack on both sides — Vision frames land between
        // keyframes and requestedTimeToleranceBefore=.zero forces a full
        // decode to the exact time, which can fail or return nil on some
        // HEVC captures. Mirror the tolerances used in VideoConverterChannel.
        if autoPick {
          generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
          generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        } else {
          generator.requestedTimeToleranceBefore = .zero
          generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        }
        // Tone-map HDR/Dolby Vision (iPhone 15 Pro+ default) to SDR so thumbnail
        // extraction succeeds on newer iOS. dynamicRangePolicy is iOS 18+.
        if #available(iOS 18.0, *) {
          generator.dynamicRangePolicy = .forceSDR
        }

        let handleImage: (CGImage?, Error?) -> Void = { cgImage, error in
          if let error = error {
            DispatchQueue.main.async {
              result(FlutterError(
                code: "EXTRACT",
                message: "Frame extraction failed: \(error.localizedDescription)",
                details: "\(error)"
              ))
            }
            return
          }
          guard let cgImage = cgImage else {
            DispatchQueue.main.async {
              result(FlutterError(code: "EXTRACT", message: "No image returned", details: nil))
            }
            return
          }
          // Apply Vision person segmentation (iOS 15+) so thumbnails match
          // the body-only look of the line-drawing video pipeline. Any
          // failure falls through to the un-masked source image. With
          // autoPick we also crop tight around the person for readability
          // at Studio-list / Camera-peek sizes. When `grayscale` is true
          // the two-zone blend is skipped and the whole frame is
          // recoloured to luminance — practitioner-facing surfaces use
          // this path so the client reads clearly at small sizes.
          var finalImage: CGImage = cgImage
          // Only apply segmentation (body-focus + crop) when autoPick is
          // true. When false, the caller wants a plain unprocessed frame
          // (e.g. the "original" treatment thumbnail).
          if autoPick || grayscale {
            if #available(iOS 15.0, *) {
              if let masked = VideoConverterChannel.applySegmentationToThumbnail(
                cgImage: cgImage,
                cropToPerson: autoPick,
                grayscale: grayscale
              ) {
                finalImage = masked
              } else if grayscale {
                if let gray = VideoConverterChannel.grayscaleCGImage(cgImage) {
                  finalImage = gray
                }
              }
            } else if grayscale {
              if let gray = VideoConverterChannel.grayscaleCGImage(cgImage) {
                finalImage = gray
              }
            }
          }
          let uiImage = UIImage(cgImage: finalImage)
          guard let jpegData = uiImage.jpegData(compressionQuality: 0.9) else {
            DispatchQueue.main.async {
              result(FlutterError(code: "JPEG", message: "Failed to create JPEG", details: nil))
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
              result(outputPath)
            }
          } catch {
            DispatchQueue.main.async {
              result(FlutterError(
                code: "WRITE",
                message: "Failed to write thumbnail: \(error.localizedDescription)",
                details: "\(error)"
              ))
            }
          }
        }

        // autoPick work (motion-peak sampling) must run off-main — it
        // makes several synchronous copyCGImage calls that would otherwise
        // janky the caller's queue. Non-autoPick path preserves the old
        // behaviour (CMTime construction is trivial).
        DispatchQueue.global(qos: .userInitiated).async {
          let time: CMTime = autoPick
            ? VideoConverterChannel.pickMotionPeakTime(asset: asset, generator: generator)
            : CMTime(value: CMTimeValue(timeMs), timescale: 1000)

          if #available(iOS 16.0, *) {
            generator.generateCGImageAsynchronously(for: time) { cgImage, _, error in
              handleImage(cgImage, error)
            }
          } else {
            do {
              let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
              handleImage(cgImage, nil)
            } catch {
              handleImage(nil, error)
            }
          }
        }
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    // Register the full video converter channel using the same messenger.
    // Stored on self so the handler registration persists for the app lifetime.
    videoConverter = VideoConverterChannel(messenger: messenger)

    // Wave 40.5 — native haptics channel. UIImpactFeedbackGenerator fires
    // even while the camera mic is hot, unlike Flutter's HapticFeedback.
    haptics = HomefitHapticsChannel(messenger: messenger)

    // Wave 4 Phase 2 — audio-session owner for the unified preview
    // WebView. Without this, Silent-mode phones mute the embedded
    // <video> audio even though PR #41's concurrent-drain gave Line
    // treatment real audio tracks.
    unifiedPreviewAudio = UnifiedPreviewAudioChannel(messenger: messenger)

    // Wave 4 Phase 2 — custom URL scheme handler. Installs a one-shot
    // swizzle on `-[WKWebViewConfiguration init]` so every
    // configuration created by `webview_flutter_wkwebview` picks up
    // the `homefit-local://` handler before the WKWebView consumes
    // the config. See UnifiedPlayerSchemeHandler.swift.
    if #available(iOS 11.0, *) {
      UnifiedPreviewSchemeRegistrar.register(messenger: messenger)
    }

    // Wave 34 — register the native avatar camera channel + its
    // PlatformView factory. AVFoundation is iOS 11+, no fallback needed.
    if #available(iOS 11.0, *) {
      avatarCamera = AvatarCameraChannel(messenger: messenger)
      let avatarPreviewFactory = AvatarCameraPreviewFactory(messenger: messenger)
      registrar.register(
        avatarPreviewFactory,
        withId: "homefit/avatar_camera_preview"
      )
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
