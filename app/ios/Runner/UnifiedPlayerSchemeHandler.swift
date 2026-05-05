import Flutter
import Foundation
import WebKit

/// Wave 4 Phase 2 — WKURLSchemeHandler that serves the web-player bundle
/// and archived session media directly from the Flutter app, without the
/// Phase 1 loopback shelf HTTP server.
///
/// Scheme: `homefit-local`
/// Host:   `plan`
/// Routes:
///   `homefit-local://plan/`                       → index.html (Flutter asset)
///   `homefit-local://plan/app.js`                 → app.js     (Flutter asset)
///   `homefit-local://plan/api.js`                 → api.js     (Flutter asset)
///   `homefit-local://plan/lobby.js`               → lobby.js   (Flutter asset)
///   `homefit-local://plan/styles.css`             → styles.css (Flutter asset)
///   `homefit-local://plan/api/plan/<planId>`      → plan JSON  (Dart method channel)
///   `homefit-local://plan/local/<exerciseId>/line`    → converted / raw file
///   `homefit-local://plan/local/<exerciseId>/archive` → raw-archive mp4
///
/// Why a custom scheme over loopback?
///   * No port allocation — the Phase 1 shelf asks the OS for an ephemeral
///     port and has to re-advertise it to the WebView; ugly on hot restart.
///   * No TCP handshake per request — every fetch from the bundle lands
///     as a direct function call on the scheme handler.
///   * Range streaming is first-class — we only serve the requested byte
///     range without the shelf's per-request `File.openRead(start, end)`
///     stream setup.
///   * The scheme is private — the WebView's cookie jar + CSP don't leak
///     into the http://127.0.0.1 origin (which could collide with unrelated
///     local dev servers on the device).
///
/// The handler delegates dynamic data resolution to the Dart side via a
/// `MethodChannel`. Dart owns the SQLite DB and the PathResolver, so the
/// Swift handler only needs two questions answered:
///
///   1. "For planId X, give me the full get_plan_full-shaped JSON"
///   2. "For exerciseId Y, kind {line,archive}, give me an absolute file path"
///
/// The channel name is `com.raidme.unified_preview_scheme`. Dart lives in
/// `app/lib/services/unified_preview_scheme_bridge.dart`.
///
/// # Stopped-task safety
///
/// `WKURLSchemeTask` raises an Obj-C `NSInternalInconsistencyException` if
/// `didReceive` / `didFinish` / `didFailWithError` is called after WebKit
/// has invoked `webView(_:stop:)` on the task. Swift can't `try`/`catch`
/// Obj-C runtime exceptions, so the app crashes. This is easy to hit any
/// time a previous video load races against the next swipe — WebKit
/// aborts the old <video> request while our async file I/O is still in
/// flight. Every task method is funnelled through `safeDidReceive` /
/// `safeDidFinish` / `safeDidFail` below; each one checks the stopped-set
/// under a lock before calling through.
@available(iOS 11.0, *)
final class UnifiedPlayerSchemeHandler: NSObject, WKURLSchemeHandler {
  static let schemeName = "homefit-local"
  static let host = "plan"
  static let methodChannelName = "com.raidme.unified_preview_scheme"

  private let channel: FlutterMethodChannel
  private let fileIO = DispatchQueue(label: "homefit.unified_preview.scheme.io", qos: .userInitiated)

  /// Live tasks keyed by an ObjectIdentifier of the task — lets us cancel
  /// in-flight reads when the WebView calls `webView(_:stop:)`.
  private var liveTasks: [ObjectIdentifier: DispatchWorkItem] = [:]
  private let liveTasksLock = NSLock()

  /// Stopped-task set. Populated by `webView(_:stop:)` and checked by
  /// every `safeDidReceive` / `safeDidFinish` / `safeDidFail` call.
  /// Entries stay until the handler is deallocated — WebKit never reuses
  /// a stopped task so unbounded growth is bounded by task churn per
  /// handler lifetime (typically one session preview).
  private var stoppedTasks: Set<ObjectIdentifier> = []
  private let stoppedTasksLock = NSLock()

  init(messenger: FlutterBinaryMessenger) {
    self.channel = FlutterMethodChannel(
      name: UnifiedPlayerSchemeHandler.methodChannelName,
      binaryMessenger: messenger
    )
    super.init()
  }

  // MARK: - WKURLSchemeHandler

  func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
    guard let url = urlSchemeTask.request.url else {
      safeDidFail(urlSchemeTask, Self.error(.badURL, "missing request URL"))
      return
    }

    // url.path includes a leading slash; strip it for route matching.
    let rawPath = url.path
    let path = rawPath.hasPrefix("/") ? String(rawPath.dropFirst()) : rawPath

    // 1. Static bundle assets — resolve synchronously off main.
    if path.isEmpty || path == "index.html" {
      respondWithAsset(urlSchemeTask, assetName: "index.html", contentType: "text/html; charset=utf-8")
      return
    }
    if path == "app.js" {
      respondWithAsset(urlSchemeTask, assetName: "app.js", contentType: "application/javascript; charset=utf-8")
      return
    }
    if path == "api.js" {
      respondWithAsset(urlSchemeTask, assetName: "api.js", contentType: "application/javascript; charset=utf-8")
      return
    }
    if path == "lobby.js" {
      respondWithAsset(urlSchemeTask, assetName: "lobby.js", contentType: "application/javascript; charset=utf-8")
      return
    }
    if path == "styles.css" {
      respondWithAsset(urlSchemeTask, assetName: "styles.css", contentType: "text/css; charset=utf-8")
      return
    }
    if path == "html2canvas.min.js" {
      // Wave Free Lobby Export (2026-05-05) — vendored html2canvas
      // (~200 KB) lazy-loaded by lobby.js when the share button is
      // tapped. Same-origin via the homefit-local:// scheme; CSP
      // `script-src 'self'` rule on the public surface requires this.
      respondWithAsset(urlSchemeTask, assetName: "html2canvas.min.js", contentType: "application/javascript; charset=utf-8")
      return
    }

    // 2. Plan JSON.
    if let planId = match(path: path, pattern: "api/plan/") {
      respondWithPlanJson(urlSchemeTask, planId: planId)
      return
    }

    // 3. Local media — line / archive. Parse `local/<id>/<kind>`.
    if let (exerciseId, kind) = parseLocalMediaPath(path) {
      respondWithLocalMedia(urlSchemeTask, exerciseId: exerciseId, kind: kind)
      return
    }

    safeDidFail(urlSchemeTask, Self.error(.unsupportedURL, "no route for \(path)"))
  }

  func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
    let key = ObjectIdentifier(urlSchemeTask)

    // Mark stopped FIRST so any in-flight completion on the scheme handler's
    // dispatch queues no-ops before touching the task.
    stoppedTasksLock.lock()
    stoppedTasks.insert(key)
    stoppedTasksLock.unlock()

    // Then cancel the work item (if any) so the file-IO queue aborts its
    // read when it next checks `isCancelled`.
    liveTasksLock.lock()
    let item = liveTasks.removeValue(forKey: key)
    liveTasksLock.unlock()
    item?.cancel()
  }

  // MARK: - Stopped-task guards

  /// Returns true if the WebView has already called `stop:` on this task.
  private func isStopped(_ task: WKURLSchemeTask) -> Bool {
    let key = ObjectIdentifier(task)
    stoppedTasksLock.lock()
    defer { stoppedTasksLock.unlock() }
    return stoppedTasks.contains(key)
  }

  private func safeDidReceive(_ task: WKURLSchemeTask, _ response: URLResponse) {
    if isStopped(task) { return }
    task.didReceive(response)
  }

  private func safeDidReceive(_ task: WKURLSchemeTask, _ data: Data) {
    if isStopped(task) { return }
    task.didReceive(data)
  }

  private func safeDidFinish(_ task: WKURLSchemeTask) {
    if isStopped(task) { return }
    task.didFinish()
  }

  private func safeDidFail(_ task: WKURLSchemeTask, _ error: Error) {
    if isStopped(task) { return }
    task.didFailWithError(error)
  }

  // MARK: - Static asset handler

  private func respondWithAsset(
    _ task: WKURLSchemeTask,
    assetName: String,
    contentType: String
  ) {
    // Flutter bundles declared pubspec assets under Runner.app at
    // `Frameworks/App.framework/flutter_assets/assets/web-player/<name>`.
    // `FlutterDartProject.lookupKey(forAsset:)` maps the asset name to
    // the bundle key the plugin system uses at runtime.
    let assetPath = "assets/web-player/\(assetName)"
    let key = FlutterDartProject.lookupKey(forAsset: assetPath)
    guard let resource = Bundle.main.path(forResource: key, ofType: nil) else {
      safeDidFail(task, Self.error(.fileDoesNotExist, "asset missing: \(assetPath)"))
      return
    }
    let fileURL = URL(fileURLWithPath: resource)
    do {
      let data = try Data(contentsOf: fileURL)
      guard let requestURL = task.request.url else {
        safeDidFail(task, Self.error(.badURL, "missing request URL mid-response"))
        return
      }
      let response = makeResponse(
        url: requestURL,
        statusCode: 200,
        headers: [
          "Content-Type": contentType,
          "Content-Length": "\(data.count)",
          "Cache-Control": "no-store, max-age=0",
          "Cross-Origin-Resource-Policy": "same-origin",
        ]
      )
      // WebKit accepts URLResponse OR HTTPURLResponse. Custom schemes
      // get a plain URLResponse; mimeType + content-length suffice.
      safeDidReceive(task, response)
      safeDidReceive(task, data)
      safeDidFinish(task)
    } catch {
      safeDidFail(task, Self.error(.cannotOpenFile, "read failed: \(error.localizedDescription)"))
    }
  }

  // MARK: - Plan JSON handler (delegates to Dart)

  private func respondWithPlanJson(_ task: WKURLSchemeTask, planId: String) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      // Bail early if the task was stopped between scheduling and firing
      // on main. `channel.invokeMethod` below would still land in a
      // callback that touches the task, so this short-circuit avoids the
      // round-trip entirely.
      if self.isStopped(task) { return }
      self.channel.invokeMethod("resolvePlanJson", arguments: ["planId": planId]) { [weak self] result in
        guard let self = self else { return }
        if let error = result as? FlutterError {
          self.safeDidFail(task, Self.error(
            .cannotLoadFromNetwork,
            "resolvePlanJson: \(error.code) \(error.message ?? "")"
          ))
          return
        }
        guard let json = result as? String, let data = json.data(using: .utf8) else {
          self.safeDidFail(task, Self.error(.cannotLoadFromNetwork, "resolvePlanJson returned non-string"))
          return
        }
        guard let requestURL = task.request.url else {
          self.safeDidFail(task, Self.error(.badURL, "missing request URL mid-response"))
          return
        }
        let response = self.makeResponse(
          url: requestURL,
          statusCode: 200,
          headers: [
            "Content-Type": "application/json; charset=utf-8",
            "Content-Length": "\(data.count)",
            "Cache-Control": "no-store, max-age=0",
          ]
        )
        self.safeDidReceive(task, response)
        self.safeDidReceive(task, data)
        self.safeDidFinish(task)
      }
    }
  }

  // MARK: - Local media handler (delegates path resolution to Dart)

  private func respondWithLocalMedia(
    _ task: WKURLSchemeTask,
    exerciseId: String,
    kind: String
  ) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      if self.isStopped(task) { return }
      self.channel.invokeMethod(
        "resolveMediaPath",
        arguments: ["exerciseId": exerciseId, "kind": kind]
      ) { [weak self] result in
        guard let self = self else { return }
        if let error = result as? FlutterError {
          self.safeDidFail(task, Self.error(
            .fileDoesNotExist,
            "resolveMediaPath: \(error.code) \(error.message ?? "")"
          ))
          return
        }
        guard let path = result as? String, !path.isEmpty else {
          self.safeDidFail(task, Self.error(.fileDoesNotExist, "no media for \(exerciseId)/\(kind)"))
          return
        }
        // Wave 32 — diagnostic for the "video doesn't render" bug. Logs the
        // served path + content-type so a still-image fallback (jpg) being
        // handed to a <video> tag is obvious in Console.app.
        NSLog("[UnifiedPreview] serve \(exerciseId)/\(kind) → \(path) (\(self.contentTypeFor(path)))")
        self.streamFileWithRangeSupport(task, filePath: path)
      }
    }
  }

  /// Stream a file with HTTP `Range` support so iOS AVPlayer can seek
  /// inside large archive files without loading them fully. When the
  /// request's `Range` header is absent we reply 200 with the full body;
  /// otherwise we reply 206 with a byte-range slice.
  private func streamFileWithRangeSupport(_ task: WKURLSchemeTask, filePath: String) {
    let url = URL(fileURLWithPath: filePath)
    let rangeHeader = task.request.value(forHTTPHeaderField: "Range")

    // Capture requestURL on the calling queue — we can't trust the task
    // itself to still be alive by the time the fileIO queue picks up the
    // work item. (The task reference is still fine because WKWebView
    // retains it until stop: + didFail/didFinish completes, but reading
    // .request from a stopped task is a documented no-go on some iOS
    // versions.)
    guard let requestURL = task.request.url else {
      safeDidFail(task, Self.error(.badURL, "missing request URL"))
      return
    }

    // DispatchWorkItem reference has to be stable so the block can check
    // its own `isCancelled` on cancel-during-read races.
    var workItemRef: DispatchWorkItem?
    let workItem = DispatchWorkItem { [weak self] in
      guard let self = self else { return }
      if workItemRef?.isCancelled == true { return }
      if self.isStopped(task) { return }
      do {
        let attrs = try FileManager.default.attributesOfItem(atPath: filePath)
        guard let length = attrs[.size] as? Int else {
          self.safeDidFail(task, Self.error(.resourceUnavailable, "cannot stat \(filePath)"))
          return
        }
        if workItemRef?.isCancelled == true { return }
        let contentType = self.contentTypeFor(filePath)

        guard let range = rangeHeader, !range.isEmpty else {
          // No Range — send the whole thing. Still advertise Accept-Ranges
          // so future requests for the same URL (e.g. AVPlayer pre-roll)
          // know they can seek.
          let data = try Data(contentsOf: url)
          if workItemRef?.isCancelled == true { return }
          let response = self.makeResponse(
            url: requestURL,
            statusCode: 200,
            headers: [
              "Content-Type": contentType,
              "Content-Length": "\(length)",
              "Accept-Ranges": "bytes",
              "Cache-Control": "no-store, max-age=0",
            ]
          )
          self.safeDidReceive(task, response)
          self.safeDidReceive(task, data)
          self.safeDidFinish(task)
          return
        }

        // Parse `bytes=<start>-<end>`
        guard let (start, end) = self.parseRange(rangeHeader: range, totalLength: length) else {
          let response = self.makeResponse(
            url: requestURL,
            statusCode: 416,
            headers: [
              "Content-Range": "bytes */\(length)",
              "Content-Length": "0",
            ]
          )
          self.safeDidReceive(task, response)
          self.safeDidFinish(task)
          return
        }

        let chunkLength = end - start + 1
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(start))
        if workItemRef?.isCancelled == true { return }
        let chunk = handle.readData(ofLength: chunkLength)
        if workItemRef?.isCancelled == true { return }

        let response = self.makeResponse(
          url: requestURL,
          statusCode: 206,
          headers: [
            "Content-Type": contentType,
            "Accept-Ranges": "bytes",
            "Content-Length": "\(chunkLength)",
            "Content-Range": "bytes \(start)-\(end)/\(length)",
            "Cache-Control": "no-store, max-age=0",
          ]
        )
        self.safeDidReceive(task, response)
        self.safeDidReceive(task, chunk)
        self.safeDidFinish(task)
      } catch {
        if workItemRef?.isCancelled == true { return }
        self.safeDidFail(task, Self.error(.cannotOpenFile, "stream failed: \(error.localizedDescription)"))
      }
    }
    workItemRef = workItem

    liveTasksLock.lock()
    liveTasks[ObjectIdentifier(task)] = workItem
    liveTasksLock.unlock()

    fileIO.async(execute: workItem)
  }

  private func parseRange(rangeHeader: String, totalLength: Int) -> (Int, Int)? {
    // Accept `bytes=<start>-<end>` or `bytes=<start>-`
    guard rangeHeader.hasPrefix("bytes=") else { return nil }
    let spec = rangeHeader.dropFirst("bytes=".count)
    let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2 else { return nil }
    guard let start = Int(parts[0]), start >= 0 else { return nil }
    let endPart = parts[1]
    let end: Int
    if endPart.isEmpty {
      end = totalLength - 1
    } else {
      guard let parsed = Int(endPart) else { return nil }
      end = parsed
    }
    if start > end || end >= totalLength { return nil }
    return (start, end)
  }

  // MARK: - Helpers

  /// Build a synthetic HTTPURLResponse-looking response using URLResponse.
  /// WKWebView's custom-scheme path wants status code + headers; it gets
  /// them through an `HTTPURLResponse`.
  private func makeResponse(
    url: URL,
    statusCode: Int,
    headers: [String: String]
  ) -> URLResponse {
    return HTTPURLResponse(
      url: url,
      statusCode: statusCode,
      httpVersion: "HTTP/1.1",
      headerFields: headers
    ) ?? URLResponse(
      url: url,
      mimeType: headers["Content-Type"],
      expectedContentLength: Int(headers["Content-Length"] ?? "0") ?? 0,
      textEncodingName: nil
    )
  }

  private func match(path: String, pattern prefix: String) -> String? {
    guard path.hasPrefix(prefix) else { return nil }
    let id = String(path.dropFirst(prefix.count))
    if id.isEmpty || id.contains("/") { return nil }
    return id.removingPercentEncoding ?? id
  }

  /// Parses `local/<exerciseId>/(line|archive|segmented|hero)`. Returns nil
  /// on mismatch. `segmented` is the body-pop variant added in Wave 30; the
  /// Dart bridge already accepts it, so the iOS guard had to follow or
  /// every Body-Focus video request 404'd silently. `hero` is the on-device
  /// Hero JPG (Wave Hero Crop, PR #218), wired post PR #255 to give the
  /// lobby a real image URL for the <img src> poster.
  private func parseLocalMediaPath(_ path: String) -> (String, String)? {
    guard path.hasPrefix("local/") else { return nil }
    let rest = path.dropFirst("local/".count)
    let parts = rest.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
    guard parts.count == 2 else { return nil }
    let exerciseId = String(parts[0])
    let kind = String(parts[1])
    if exerciseId.isEmpty { return nil }
    guard kind == "line" || kind == "archive" || kind == "segmented"
            || kind == "hero" || kind == "hero_color" || kind == "hero_line" else {
      NSLog("[UnifiedPreview] rejected unknown kind '\(kind)' for exercise \(exerciseId)")
      return nil
    }
    return (exerciseId.removingPercentEncoding ?? exerciseId, kind)
  }

  private func contentTypeFor(_ path: String) -> String {
    let lower = path.lowercased()
    if lower.hasSuffix(".mp4") || lower.hasSuffix(".m4v") { return "video/mp4" }
    if lower.hasSuffix(".mov") { return "video/quicktime" }
    if lower.hasSuffix(".webm") { return "video/webm" }
    if lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") { return "image/jpeg" }
    if lower.hasSuffix(".png") { return "image/png" }
    if lower.hasSuffix(".heic") { return "image/heic" }
    return "application/octet-stream"
  }

  private static func error(_ code: URLError.Code, _ message: String) -> NSError {
    return NSError(
      domain: NSURLErrorDomain,
      code: code.rawValue,
      userInfo: [NSLocalizedDescriptionKey: message]
    )
  }
}

/// Installs a shared `UnifiedPlayerSchemeHandler` on every new
/// `WKWebViewConfiguration` via one-time method swizzling.
///
/// Why swizzling? `webview_flutter_wkwebview 3.24` owns the WKWebView
/// configuration internally; it doesn't expose `setURLSchemeHandler:
/// forURLScheme:` through the Dart plugin surface. `WKWebView` also
/// requires the scheme handler to be set on the *configuration* BEFORE
/// the WebView is initialised — there's no post-init hook.
///
/// Swizzling `WKWebViewConfiguration.init()` lets us register the
/// handler on every new config instance before the plugin hands it to
/// `WKWebView.initWithFrame:configuration:`. The handler only intercepts
/// `homefit-local://` — every other URL passes through unchanged, so
/// unrelated `webview_flutter` consumers (if we ever add one) aren't
/// affected.
///
/// `register(messenger:)` is idempotent — the swizzle exchange only
/// runs once, guarded by a `static let` dispatch_once-style latch. The
/// shared handler reference is replaced on every call so the active
/// messenger is always current after hot restart.
@available(iOS 11.0, *)
@objc final class UnifiedPreviewSchemeRegistrar: NSObject {
  private static let swizzleOnce: Void = {
    swizzleConfigurationInit()
  }()
  private static var sharedHandler: UnifiedPlayerSchemeHandler?

  /// Install the shared handler and run the `WKWebViewConfiguration`
  /// swizzle. Call ONCE from `AppDelegate.didFinishLaunchingWithOptions`.
  @objc static func register(messenger: FlutterBinaryMessenger) {
    sharedHandler = UnifiedPlayerSchemeHandler(messenger: messenger)
    _ = swizzleOnce
  }

  /// Pull the shared handler during `WKWebViewConfiguration.init()` so
  /// the swizzled initialiser can attach it to every new config.
  fileprivate static var handler: UnifiedPlayerSchemeHandler? {
    return sharedHandler
  }

  private static func swizzleConfigurationInit() {
    let cls = WKWebViewConfiguration.self
    let originalSelector = #selector(NSObject.init)
    let swizzledSelector = #selector(WKWebViewConfiguration.homefit_swizzled_init)
    guard
      let originalMethod = class_getInstanceMethod(cls, originalSelector),
      let swizzledMethod = class_getInstanceMethod(cls, swizzledSelector)
    else {
      NSLog("[UnifiedPreview] swizzle failed: selectors not found")
      return
    }
    method_exchangeImplementations(originalMethod, swizzledMethod)
  }
}

@available(iOS 11.0, *)
private extension WKWebViewConfiguration {
  /// Replacement for `-[WKWebViewConfiguration init]`. After swizzle
  /// exchange, the method with THIS name becomes the public entry point
  /// — calling `self.homefit_swizzled_init()` inside it invokes the
  /// ORIGINAL Foundation init. We register the unified-preview scheme
  /// handler on the returned configuration before handing it back to
  /// the caller (which is typically `webview_flutter_wkwebview`'s
  /// internal WebView factory).
  ///
  /// The `setURLSchemeHandler` call only raises an exception if:
  ///   (a) the scheme is a built-in (http/https/ws/etc.) — ours isn't, or
  ///   (b) a handler is already registered for this scheme on the
  ///       same configuration — each `WKWebViewConfiguration` is fresh
  ///       from init, so this path is unreachable in practice.
  /// Defensive NSLog covers any future surprise.
  @objc func homefit_swizzled_init() -> WKWebViewConfiguration {
    let config = self.homefit_swizzled_init()
    guard let handler = UnifiedPreviewSchemeRegistrar.handler else {
      return config
    }
    let scheme = UnifiedPlayerSchemeHandler.schemeName
    // Skip if the scheme is one WebKit reserves — belt + braces.
    // `handlesURLScheme(_:)` returns true for http/https/file/about etc.
    if WKWebView.handlesURLScheme(scheme) {
      NSLog("[UnifiedPreview] refusing to register reserved scheme: \(scheme)")
      return config
    }
    config.setURLSchemeHandler(handler, forURLScheme: scheme)
    return config
  }
}
