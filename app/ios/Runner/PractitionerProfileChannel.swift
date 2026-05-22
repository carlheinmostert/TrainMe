import Flutter
import UIKit
import Vision
import os.log

// MARK: - Safe Mode Transparency — Phase A (2026-05-22)
//
// Native face-detection channel used by the Settings "Public profile" save
// flow. The practitioner's avatar selfie must contain at least one face
// before the upload is allowed — bystander obscuring is reciprocal to
// practitioner identity disclosure, so an avatar without a clear face
// breaks the trust contract the live transparency page advertises.
//
// Channel name: `studio.homefit.practitioner_profile`. Single method:
//
//   * `verifyFaceInImage(path: String)` → returns
//       { "faceFound": Bool, "count": Int, "error": String? }
//     Detection runs via `VNDetectFaceRectanglesRequest` on the JPEG at
//     `path`. Errors land in the `error` field rather than as a
//     FlutterError so the Dart caller can show a friendly toast and let
//     the user retry without crashing the Settings save flow.
//
// Diagnostics use `os_log` against subsystem `studio.homefit.app` and
// category `practitioner.face` so Carl can filter in Console.app.

@available(iOS 11.0, *)
final class PractitionerProfileChannel: NSObject {
    private static let log = OSLog(
        subsystem: "studio.homefit.app",
        category: "practitioner.face"
    )

    private let channel: FlutterMethodChannel

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(
            name: "studio.homefit.practitioner_profile",
            binaryMessenger: messenger
        )
        super.init()
        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
        os_log("PractitionerProfileChannel initialised",
               log: Self.log, type: .info)
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "verifyFaceInImage":
            guard let args = call.arguments as? [String: Any],
                  let path = args["path"] as? String else {
                result(FlutterError(
                    code: "INVALID_ARGS",
                    message: "Missing path for verifyFaceInImage",
                    details: nil
                ))
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                self.verifyFace(path: path, result: result)
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func verifyFace(path: String, result: @escaping FlutterResult) {
        guard FileManager.default.fileExists(atPath: path) else {
            os_log("verifyFace: file missing %{public}@",
                   log: Self.log, type: .error, path)
            DispatchQueue.main.async {
                result(["faceFound": false, "count": 0, "error": "file-missing"])
            }
            return
        }

        let url = URL(fileURLWithPath: path)
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            os_log("verifyFace: could not decode JPEG at %{public}@",
                   log: Self.log, type: .error, path)
            DispatchQueue.main.async {
                result(["faceFound": false, "count": 0, "error": "decode-failed"])
            }
            return
        }

        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            let observations = request.results ?? []
            let count = observations.count
            let found = count > 0
            os_log("verifyFace: path=%{public}@ count=%d",
                   log: Self.log, type: .info, path, count)
            DispatchQueue.main.async {
                result([
                    "faceFound": found,
                    "count": count,
                    "error": NSNull(),
                ])
            }
        } catch {
            os_log("verifyFace: Vision error %{public}@",
                   log: Self.log, type: .error, error.localizedDescription)
            DispatchQueue.main.async {
                result([
                    "faceFound": false,
                    "count": 0,
                    "error": "vision-failed: \(error.localizedDescription)",
                ])
            }
        }
    }
}
