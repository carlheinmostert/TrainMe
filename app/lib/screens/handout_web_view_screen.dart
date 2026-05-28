// =============================================================================
// HandoutWebViewScreen — Wave 6 (artifact-system, 2026-05-27)
// =============================================================================
//
// Full-screen WKWebView that renders the workout-handout artifact. Two
// modes, selected at construction:
//
//   * REMOTE (default ctor) — loads the PUBLISHED handout at
//     `<webPlayerOrigin>/h/{planId}`. Mounted from the
//     SessionArtifactAccordion's `onPlayHandout` callback when the
//     artifact kind is `handout` on ClientSessionsScreen / MyWorkouts.
//     This is the share/published path; do NOT change its behaviour.
//
//   * LOCAL PREVIEW ([HandoutWebViewScreen.localPreview]) — renders the
//     handout from the LOCALLY BUNDLED `app/assets/web-player/handout.*`
//     assets via the same `homefit-local://` custom scheme the workout-
//     plan preview uses (`UnifiedPlayerSchemeHandler.swift` +
//     `UnifiedPreviewSchemeBridge`). Mounted from the Studio Preview
//     artifact picker. The point of the local variant: it bypasses the
//     device's WKWebView HTTP cache, so the practitioner always previews
//     the freshest handout code shipped in THIS build — even when the
//     remote `/h/{planId}` URL is serving a stale cached `handout.js`.
//     Plan data still flows through the bundled handout.js's normal
//     `getPlanFull` call, which api.js routes to the local scheme handler
//     (`/api/plan/{planId}`) and the Dart bridge answers from SQLite.
//
// Remote mode is online-only: if the practitioner is offline the WebView
// shows its own connection error; we don't fall back silently (per
// `feedback_no_silent_fallbacks`). Local mode never touches the network.
// =============================================================================

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart'
    show
        PlaybackMediaTypes,
        WebKitWebViewController,
        WebKitWebViewControllerCreationParams;

import 'dart:io' show Platform;

import '../config.dart';
import '../models/session.dart';
import '../services/local_storage_service.dart';
import '../services/unified_preview_scheme_bridge.dart';
import '../theme.dart';

class HandoutWebViewScreen extends StatefulWidget {
  /// Plan id whose handout artifact this WebView opens.
  final String planId;

  /// Optional title shown in the AppBar. Defaults to "Workout handout".
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
      ..setBackgroundColor(AppColors.surfaceBg);

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surfaceBg,
      appBar: AppBar(
        backgroundColor: AppColors.surfaceBg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: AppColors.textOnDark),
        title: Text(
          widget.title ?? 'Workout handout',
          style: const TextStyle(
            fontFamily: 'Montserrat',
            fontWeight: FontWeight.w700,
            fontSize: 16,
            color: AppColors.textOnDark,
            letterSpacing: -0.2,
          ),
        ),
      ),
      body: Stack(
        children: [
          if (_controller != null) WebViewWidget(controller: _controller!),
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
                      Text(
                        "Couldn't load the handout.",
                        style: const TextStyle(
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
        ],
      ),
    );
  }
}
