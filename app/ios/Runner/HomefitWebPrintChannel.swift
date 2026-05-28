import Flutter
import UIKit
import WebKit

/// Native print bridge for the in-app Printable Workout Guide WebView.
///
/// **Why this exists.** The Printable Workout Guide renders inside a
/// `WKWebView` (see `HandoutWebViewScreen` on the Dart side). Its in-page
/// "Print" button calls `window.print()`, which is effectively a NO-OP
/// inside `WKWebView` — WebKit on iOS does not surface a print dialog for
/// the JS `print()` call the way desktop browsers do. So tapping Print
/// did nothing.
///
/// This channel bridges the print intent to the native iOS print pipeline:
/// `UIPrintInteractionController` driven by the WebView's own
/// `viewPrintFormatter()`. Presenting that controller gives the
/// practitioner Print-to-AirPrint AND "Save as PDF" (via the share button
/// in the print preview) for free, with no html2canvas / jsPDF on either
/// surface.
///
/// **How the WebView is located.** `webview_flutter_wkwebview` does not
/// expose the underlying `WKWebView` instance to Dart, so we can't pass a
/// handle across the channel. Instead, at print time we walk the key
/// window's view hierarchy and pick the frontmost on-screen `WKWebView`.
/// The Printable Workout Guide is a full-screen route presented over the
/// app, so it is the topmost WebView whenever the print action fires.
/// `viewPrintFormatter()` captures the full scrollable document, not just
/// the visible viewport.
///
/// Channel name: `homefit/web-print`
/// Method: `presentPrintSheet` — optional `jobName` String argument used as
///         the print-job title (defaults to "Printable Workout Guide").
///
/// The Dart side (`HandoutWebViewScreen`) is the only caller; it invokes
/// this channel both when the page posts a `print` message on the
/// `HomefitPrint` JS channel and from a fallback shim that intercepts
/// `window.print()`.
final class HomefitWebPrintChannel {
  static let channelName = "homefit/web-print"

  private let channel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    self.channel = FlutterMethodChannel(
      name: HomefitWebPrintChannel.channelName,
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "presentPrintSheet" else {
      result(FlutterMethodNotImplemented)
      return
    }

    let args = call.arguments as? [String: Any]
    let jobName = (args?["jobName"] as? String) ?? "Printable Workout Guide"

    // Locate the frontmost on-screen WKWebView.
    guard let webView = HomefitWebPrintChannel.frontmostWebView() else {
      result(FlutterError(
        code: "NO_WEBVIEW",
        message: "No on-screen WKWebView found to print.",
        details: nil
      ))
      return
    }

    // Present the native print UI. Must run on the main thread; the
    // method-call handler is already on main, but be explicit for safety.
    DispatchQueue.main.async {
      let printInfo = UIPrintInfo.printInfo()
      printInfo.outputType = .general
      printInfo.jobName = jobName

      let controller = UIPrintInteractionController.shared
      controller.printInfo = printInfo
      // viewPrintFormatter() captures the full document, paginated by
      // UIKit. This is the documented way to print a WKWebView's contents.
      controller.printFormatter = webView.viewPrintFormatter()
      controller.showsPaperSelectionForLoadedPapers = true

      let completion: UIPrintInteractionController.CompletionHandler = { _, completed, error in
        if let error = error {
          result(FlutterError(
            code: "PRINT_FAILED",
            message: "Print interaction failed: \(error.localizedDescription)",
            details: "\(error)"
          ))
          return
        }
        // `completed` is false when the user cancels the print sheet —
        // that's a normal outcome, not an error. Return the boolean so the
        // Dart caller can distinguish "printed/saved" from "cancelled".
        result(completed)
      }

      // On iPad the print sheet is a popover and needs an anchor; on
      // iPhone it presents modally. Anchor to the WebView when a popover
      // presentation is required.
      if UIDevice.current.userInterfaceIdiom == .pad {
        controller.present(
          from: webView.bounds,
          in: webView,
          animated: true,
          completionHandler: completion
        )
      } else {
        controller.present(animated: true, completionHandler: completion)
      }
    }
  }

  // MARK: - View-hierarchy walk

  /// Returns the frontmost on-screen `WKWebView` in the active key window,
  /// or nil when none is mounted. Performs a reverse depth-first search so
  /// the most recently added (topmost) WebView wins — which is the
  /// full-screen Printable Workout Guide route when it is presented.
  private static func frontmostWebView() -> WKWebView? {
    guard let window = keyWindow() else { return nil }
    return findWebView(in: window)
  }

  /// Depth-first search that prefers later siblings (drawn on top). Returns
  /// the deepest topmost `WKWebView`.
  private static func findWebView(in view: UIView) -> WKWebView? {
    // Walk subviews back-to-front so the topmost (last-added) branch is
    // explored first.
    for subview in view.subviews.reversed() {
      if let found = findWebView(in: subview) {
        return found
      }
    }
    if let webView = view as? WKWebView, !webView.isHidden, webView.window != nil {
      return webView
    }
    return nil
  }

  /// Resolves the active key window across the iOS 13+ multi-scene world
  /// and the older single-window model.
  private static func keyWindow() -> UIWindow? {
    if #available(iOS 13.0, *) {
      let scenes = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .filter { $0.activationState == .foregroundActive }
      let windows = scenes.flatMap { $0.windows }
      if let key = windows.first(where: { $0.isKeyWindow }) {
        return key
      }
      // Fall back to any visible window in a foreground-active scene.
      return windows.first(where: { !$0.isHidden }) ?? windows.first
    } else {
      return UIApplication.shared.keyWindow
    }
  }
}
