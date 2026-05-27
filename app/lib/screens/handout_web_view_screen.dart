// =============================================================================
// HandoutWebViewScreen — Wave 6 (artifact-system, 2026-05-27)
// =============================================================================
//
// Full-screen WKWebView that loads the published workout-handout artifact
// at `<webPlayerOrigin>/h/{planId}`. Mounted from the ArtifactDeck's
// tap-front action when the artifact kind is `handout`.
//
// This is a thin viewer — the entire handout page is rendered server-
// side at `web-player/handout.{html,js,css}`. The Flutter side just
// wraps it in a Scaffold with an AppBar so the practitioner can dismiss
// back to Studio.
//
// Not the same WebView as [UnifiedPreviewScreen]: that surface drives
// the local custom scheme + bundled web-player code. Handouts are always
// online-only — they read the published plan from the cloud. If the
// practitioner is offline, the WebView shows its own connection error;
// we don't fall back silently (per `feedback_no_silent_fallbacks`).
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
import '../theme.dart';

class HandoutWebViewScreen extends StatefulWidget {
  /// Plan id whose handout artifact this WebView opens.
  final String planId;

  /// Optional title shown in the AppBar. Defaults to "Workout handout".
  final String? title;

  const HandoutWebViewScreen({
    super.key,
    required this.planId,
    this.title,
  });

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
    final url = '${AppConfig.webPlayerOrigin}/h/${widget.planId}';
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
    controller.loadRequest(Uri.parse(url));
    setState(() {
      _controller = controller;
    });
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
