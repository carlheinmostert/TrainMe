// =============================================================================
// HandoutWebViewScreen — Wave 6 (artifact-system, 2026-05-27)
// =============================================================================
//
// Full-screen WKWebView that renders the Printable Workout Guide artifact
// (formerly "take-home handout"). Two modes, selected at construction:
//
//   * REMOTE (default ctor) — loads the PUBLISHED guide at
//     `<webPlayerOrigin>/h/{planId}`. Mounted from the
//     SessionArtifactAccordion's `onPlayHandout` callback when the
//     artifact kind is `handout` on ClientSessionsScreen / MyWorkouts.
//     This is the share/published path; do NOT change its behaviour.
//
//   * LOCAL PREVIEW ([HandoutWebViewScreen.localPreview]) — renders the
//     guide from the LOCALLY BUNDLED `app/assets/web-player/handout.*`
//     assets via the same `homefit-local://` custom scheme the
//     Interactive Workout Guide preview uses
//     (`UnifiedPlayerSchemeHandler.swift` + `UnifiedPreviewSchemeBridge`).
//     Mounted from the Studio Preview artifact picker. The point of the
//     local variant: it bypasses the device's WKWebView HTTP cache, so the
//     practitioner always previews the freshest guide code shipped in THIS
//     build — even when the remote `/h/{planId}` URL is serving a stale
//     cached `handout.js`. Plan data still flows through the bundled
//     handout.js's normal `getPlanFull` call, which api.js routes to the
//     local scheme handler (`/api/plan/{planId}`) and the Dart bridge
//     answers from SQLite.
//
// Remote mode is online-only: if the practitioner is offline the WebView
// shows its own connection error; we don't fall back silently (per
// `feedback_no_silent_fallbacks`). Local mode never touches the network.
//
// CHROME (artifact-consistency wave, 2026-05-28). This screen previously
// hosted a standard Flutter AppBar, which read as a system bar and diverged
// from how the Interactive Workout Guide preview (`UnifiedPreviewScreen`) is
// presented. It now mirrors that surface: a full-bleed WebView with a single
// floating circular dismiss chip in the top-left. Same chrome vocabulary on
// both viewer surfaces.
//
// NATIVE PRINT BRIDGE (artifact-consistency wave, 2026-05-28). The page's
// in-page Print button calls `window.print()`, which is effectively a NO-OP
// inside WKWebView (no print dialog surfaces). We bridge the print intent to
// the native iOS print sheet (`UIPrintInteractionController` via
// `HomefitWebPrintChannel.swift`), which gives Print + Save-as-PDF for free.
// Two routes reach the bridge:
//   1. The page can explicitly call `window.HomefitPrint.postMessage('{...}')`
//      on the registered JS channel (the web sibling branch wires the button
//      to attempt this first, then fall back to `window.print()`).
//   2. A page-finished shim overrides `window.print` so the existing
//      `window.print()` call ALSO reaches the bridge — so the native sheet
//      works even before the web side is updated.
// No html2canvas / jsPDF on either surface.
// =============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel, PlatformException;
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart'
    show
        PlaybackMediaTypes,
        WebKitWebViewController,
        WebKitWebViewControllerCreationParams;

import '../config.dart';
import '../models/session.dart';
import '../services/local_storage_service.dart';
import '../services/unified_preview_scheme_bridge.dart';
import '../theme.dart';

/// JS channel the Printable Workout Guide page posts print intents on.
/// The page can call `window.HomefitPrint.postMessage(JSON.stringify({
/// type: 'print' }))`. Mirrored as a string literal in the web sibling
/// branch — do NOT rename one without the other.
const String _kPrintChannelName = 'HomefitPrint';

/// MethodChannel to the native print bridge. Name mirrored in
/// `HomefitWebPrintChannel.swift` (`channelName`). Do NOT change one
/// without the other.
const MethodChannel _printMethodChannel = MethodChannel('homefit/web-print');

class HandoutWebViewScreen extends StatefulWidget {
  /// Plan id whose Printable Workout Guide this WebView opens.
  final String planId;

  /// Optional title. Used as the native print-job name (the screen itself
  /// no longer shows a title bar). Defaults to "Printable Workout Guide".
  final String? title;

  /// When true, render from the locally-bundled web-player assets via the
  /// `homefit-local://` scheme instead of the remote published URL. The
  /// [localSession] + [localStorage] fields MUST be non-null in this mode
  /// so the scheme bridge can answer `get_plan_full` from SQLite.
  final bool localPreviewMode;

  /// Session bound to the scheme bridge in local-preview mode. Null in
  /// remote mode (the cloud RPC supplies the plan data there).
  final Session? localSession;

  /// Local storage handle bound to the scheme bridge in local-preview
  /// mode. Null in remote mode.
  final LocalStorageService? localStorage;

  const HandoutWebViewScreen({
    super.key,
    required this.planId,
    this.title,
  })  : localPreviewMode = false,
        localSession = null,
        localStorage = null;

  /// Local-preview constructor — renders the bundled handout assets so the
  /// practitioner previews the freshest handout code from THIS build,
  /// bypassing the WKWebView HTTP cache for the remote `/h/{planId}` URL.
  /// Binds [UnifiedPreviewSchemeBridge] to [session] + [storage] for the
  /// duration the screen is mounted.
  const HandoutWebViewScreen.localPreview({
    super.key,
    required this.planId,
    required Session session,
    required LocalStorageService storage,
    this.title,
  })  : localPreviewMode = true,
        localSession = session,
        localStorage = storage;

  @override
  State<HandoutWebViewScreen> createState() => _HandoutWebViewScreenState();
}

class _HandoutWebViewScreenState extends State<HandoutWebViewScreen> {
  WebViewController? _controller;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  void _boot() {
    final Uri target;
    if (widget.localPreviewMode) {
      // Local-preview path. Bind the scheme bridge to this session so the
      // `homefit-local://plan/api/plan/{planId}` requests the bundled
      // handout.js fires (via api.js's local surface) resolve against the
      // device's SQLite DB. Same bridge the workout-plan preview uses.
      final session = widget.localSession;
      final storage = widget.localStorage;
      if (session != null && storage != null) {
        UnifiedPreviewSchemeBridge.instance.bind(
          session: session,
          storage: storage,
        );
      }
      // `homefit-local://plan/h/{planId}?src=local` —
      //   * host `plan` + `?src=local` → api.js `isLocalSurface()` true,
      //     so getPlanFull routes to `/api/plan/{planId}` (the bridge).
      //   * path `/h/{planId}` → the bundled handout.js
      //     `extractPlanIdFromPath()` regex matches, so the page finds its
      //     planId with NO web-bundle change (the native scheme handler
      //     serves `handout.html` for the `h/` prefix — see
      //     UnifiedPlayerSchemeHandler.swift route 2b).
      target = Uri(
        scheme: 'homefit-local',
        host: 'plan',
        path: '/h/${widget.planId}',
        queryParameters: const {'src': 'local'},
      );
    } else {
      // Remote (published) path. Cache-bust the URL with the short git SHA
      // so each new mobile build forces iOS WKWebView to refetch
      // handout.html / handout.js / handout.css from the network. Without
      // this, the WKWebView persistent HTTP cache can serve a pre-PR-#550
      // cached `handout.html` (the broken one that got stuck on "Loading
      // your plan") across app restarts — even after the server fix
      // shipped. PR #553 added a defensive watchdog inside handout.js so
      // the page never hangs forever; this changes the request URL itself
      // so the browser fetches the post-fix asset.
      //
      // Pattern mirrors the existing `?v=<plan.version>` thumbnail
      // cache-bust inside lobby.js (added 2026-05-17) — same mechanic at a
      // different layer. The handout.js regex `/^\/h\/([A-Za-z0-9_-]+)\/?$/`
      // extracts only the planId from the pathname, so the query string
      // never confuses routing on the page side.
      //
      // No `?` literal can appear in [AppConfig.webPlayerOrigin] or the
      // planId by construction, so a plain `?v=...` append is safe.
      // Belt-and-braces we still branch on whether the URL already has a
      // query string, in case the URL shape evolves later.
      final base = '${AppConfig.webPlayerOrigin}/h/${widget.planId}';
      final sep = base.contains('?') ? '&' : '?';
      target = Uri.parse('$base${sep}v=${AppConfig.buildSha}');
    }

    final PlatformWebViewControllerCreationParams params = Platform.isIOS
        ? WebKitWebViewControllerCreationParams(
            allowsInlineMediaPlayback: true,
            mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
          )
        : const PlatformWebViewControllerCreationParams();

    final controller = WebViewController.fromPlatformCreationParams(params)
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(AppColors.surfaceBg)
      // Native print bridge channel. The page posts a print intent here
      // (either explicitly via `window.HomefitPrint.postMessage(...)` or
      // through the `window.print` shim injected on page-finished below);
      // we forward it to the native iOS print sheet.
      ..addJavaScriptChannel(
        _kPrintChannelName,
        onMessageReceived: _onPrintMessage,
      );

    if (Platform.isIOS && (kDebugMode || kProfileMode)) {
      final platform = controller.platform;
      if (platform is WebKitWebViewController) {
        try {
          // ignore: discarded_futures
          platform.setInspectable(true);
        } catch (_) {
          // Older versions of webview_flutter_wkwebview don't expose
          // setInspectable. Skip silently — inspection is dev-only.
        }
      }
    }

    controller.setNavigationDelegate(
      NavigationDelegate(
        // In local-preview mode, confine navigation to the bundle's own
        // origin (scheme `homefit-local`, host `plan`). Any stray link tap
        // or share-sheet attempt that would leave the bundle is blocked —
        // mirrors UnifiedPreviewScreen's guard. Remote mode keeps the
        // permissive default (the published page may legitimately
        // navigate within the web-player origin).
        onNavigationRequest: widget.localPreviewMode
            ? (req) {
                final dest = Uri.tryParse(req.url);
                if (dest == null) return NavigationDecision.prevent;
                if (dest.scheme == 'homefit-local' && dest.host == 'plan') {
                  return NavigationDecision.navigate;
                }
                return NavigationDecision.prevent;
              }
            : null,
        onPageStarted: (_) {
          if (mounted) {
            setState(() {
              _loading = true;
              _error = null;
            });
          }
        },
        onPageFinished: (_) {
          if (mounted) setState(() => _loading = false);
          // Override the page's `window.print()` so the existing in-page
          // Print button reaches the native bridge even before the web
          // sibling branch is updated to call `window.HomefitPrint`
          // directly. WKWebView's native `window.print()` is a no-op, so
          // intercepting it loses nothing and gains the native sheet.
          // ignore: discarded_futures
          _injectPrintShim(_controller);
        },
        onWebResourceError: (err) {
          if (mounted) {
            setState(() {
              _loading = false;
              _error = err.description;
            });
          }
        },
      ),
    );
    controller.loadRequest(target);
    setState(() {
      _controller = controller;
    });
  }

  @override
  void dispose() {
    // Release the scheme bridge so a stale session binding can't answer a
    // later preview's requests. No-op when remote mode never bound it.
    if (widget.localPreviewMode) {
      UnifiedPreviewSchemeBridge.instance.unbind();
    }
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Native print bridge
  // ---------------------------------------------------------------------------

  /// Inject a shim that re-points `window.print()` at the native bridge.
  /// Idempotent (re-running on a re-navigated page just re-installs it).
  /// We keep the original under `window.__nativePrint` purely for clarity;
  /// it's a no-op on WKWebView so there's nothing useful to fall back to.
  Future<void> _injectPrintShim(WebViewController? controller) async {
    if (controller == null) return;
    const js = '''
      (function () {
        if (window.__homefitPrintShimInstalled) return;
        window.__homefitPrintShimInstalled = true;
        window.__nativePrint = window.print;
        window.print = function () {
          try {
            window.$_kPrintChannelName.postMessage(JSON.stringify({ type: 'print' }));
          } catch (e) {
            // Channel missing (non-iOS / web): fall back to the original.
            if (typeof window.__nativePrint === 'function') {
              window.__nativePrint();
            }
          }
        };
      })();
    ''';
    try {
      await controller.runJavaScript(js);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[Handout] print shim injection failed: $e');
      }
    }
  }

  /// Handle a print intent posted from the page on the [_kPrintChannelName]
  /// JS channel. The payload is tolerated as either a bare string or a JSON
  /// object with `{ "type": "print" }`; anything else is ignored.
  void _onPrintMessage(JavaScriptMessage message) {
    final raw = message.message.trim();
    var isPrint = false;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map && decoded['type'] == 'print') {
        isPrint = true;
      } else if (decoded is String && decoded == 'print') {
        isPrint = true;
      }
    } catch (_) {
      // Not JSON — accept a bare "print" string.
      if (raw == 'print') isPrint = true;
    }
    if (!isPrint) {
      if (kDebugMode) {
        debugPrint('[Handout] ignored print message: $raw');
      }
      return;
    }
    // ignore: discarded_futures
    _presentPrintSheet();
  }

  /// Ask the native side to present the iOS print/share sheet for the
  /// frontmost WebView. No-op (with a debug log) on platforms without the
  /// bridge or when the channel reports an error.
  Future<void> _presentPrintSheet() async {
    if (!Platform.isIOS) return;
    try {
      await _printMethodChannel.invokeMethod<dynamic>(
        'presentPrintSheet',
        {'jobName': widget.title ?? 'Printable Workout Guide'},
      );
    } on PlatformException catch (e) {
      if (kDebugMode) {
        debugPrint('[Handout] native print failed: ${e.code} ${e.message}');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[Handout] native print error: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // No AppBar — full-bleed WebView with a single floating dismiss chip,
    // mirroring how UnifiedPreviewScreen (the Interactive Workout Guide
    // preview) presents itself. The page renders its own chrome (title,
    // print button); the app only owns the back-out affordance.
    return Scaffold(
      backgroundColor: AppColors.surfaceBg,
      body: Stack(
        children: [
          if (_controller != null)
            Positioned.fill(child: WebViewWidget(controller: _controller!)),
          if (_loading)
            const Positioned.fill(
              child: Center(
                child: SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor:
                        AlwaysStoppedAnimation<Color>(AppColors.primary),
                  ),
                ),
              ),
            ),
          if (_error != null)
            Positioned.fill(
              child: Container(
                color: AppColors.surfaceBg,
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.error_outline,
                        size: 36,
                        color: AppColors.textSecondaryOnDark,
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        "Couldn't load the guide.",
                        style: TextStyle(
                          fontFamily: 'Montserrat',
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                          color: AppColors.textOnDark,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _error!,
                        style: const TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 12.5,
                          color: AppColors.textSecondaryOnDark,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          // Top-left back-out chip. Same circular dark-pill styling as the
          // Interactive Workout Guide preview (UnifiedPreviewScreen) so the
          // practitioner reads it as viewer chrome, not a system bar.
          Positioned(
            top: MediaQuery.of(context).padding.top,
            left: 0,
            child: Material(
              color: Colors.black.withValues(alpha: 0.55),
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: IconButton(
                iconSize: 20,
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.all(8),
                constraints: const BoxConstraints.tightFor(
                  width: 40,
                  height: 40,
                ),
                tooltip: 'Close',
                icon: const Icon(
                  Icons.close_rounded,
                  color: AppColors.primary,
                ),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
