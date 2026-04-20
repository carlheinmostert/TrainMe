import Flutter
import Foundation
import AVFoundation

/// Wave 4 Phase 2 — iOS audio-session owner for the embedded
/// web-player WebView.
///
/// The public web player at session.homefit.studio relies on the Safari
/// default audio session, which respects the Silent-mode switch. Inside
/// the trainer app's WebView that default would mute the preview any
/// time the practitioner has the Ring/Silent switch down — which Carl
/// does constantly during sessions. The PR #41 concurrent-drain fix
/// means Line-treatment clips now carry audio, so making it audible
/// through Silent mode is load-bearing for the unified preview.
///
/// This channel flips the AVAudioSession category to `.playback` while
/// the preview is on screen and restores `.ambient` on dispose. The
/// `setPlaybackCategory` method accepts a boolean `active` argument
/// that maps to those two states.
///
/// The channel name is mirrored in `unified_preview_screen.dart`
/// (`_audioChannel`). Do NOT change one without the other.
final class UnifiedPreviewAudioChannel {
  static let channelName = "com.raidme.unified_preview_audio"

  private let channel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    self.channel = FlutterMethodChannel(
      name: UnifiedPreviewAudioChannel.channelName,
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "setPlaybackCategory" else {
      result(FlutterMethodNotImplemented)
      return
    }
    let args = call.arguments as? [String: Any]
    let active = (args?["active"] as? Bool) ?? false
    let session = AVAudioSession.sharedInstance()
    do {
      if active {
        // `.playback` ignores the Silent switch and keeps audio audible.
        // `.mixWithOthers` lets a background music app keep running
        // alongside the preview — polite default for a demo surface.
        try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try session.setActive(true, options: [])
      } else {
        // Return to the default ambient category — silent-mode aware,
        // mixes with other audio, doesn't take the audio focus.
        try session.setCategory(.ambient, mode: .default, options: [])
        // Deactivating notifies other apps their session is primary
        // again. `.notifyOthersOnDeactivation` is a best-effort hint.
        try session.setActive(false, options: [.notifyOthersOnDeactivation])
      }
      result(nil)
    } catch {
      result(FlutterError(
        code: "AUDIO_SESSION",
        message: "setCategory/setActive failed: \(error.localizedDescription)",
        details: "\(error)"
      ))
    }
  }
}
