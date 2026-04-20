import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart'
    show PlaybackMediaTypes, WebKitWebViewControllerCreationParams;

import '../models/session.dart';
import '../services/local_player_server.dart';
import '../services/local_storage_service.dart';
import '../theme.dart';

/// Wave 4 Phase 1 — unified player prototype screen.
///
/// Boots the [LocalPlayerServer], loads the bundled `web-player/` code
/// inside a [WebView], and disposes the server on exit. The goal of
/// Phase 1 is NOT to replace [PlanPreviewScreen] — it runs side-by-side
/// so the two implementations can be evaluated A/B.
///
/// Route shape:
///   `http://127.0.0.1:<port>/?planId=<session-id>&src=local`
///
/// The existing web-player bundle (identical code that runs at
/// session.homefit.studio) detects the `src=local` flag in api.js and
/// routes its `get_plan_full` read at `/api/plan/<planId>` on the local
/// server, which builds the payload from SQLite. Media URLs in that
/// payload point at `/local/<exerciseId>/{line,archive}` — the server
/// streams the stored archives straight off disk.
///
/// Phase 2 work (NOT in scope here):
///   * Swap the TCP transport for WKURLSchemeHandler (cuts the loopback
///     entirely, removes the port-allocation dance).
///   * Two-way bridge via `postMessage` so haptics and the iOS audio
///     session follow the web-player's state.
///   * Reuse this screen for the trainer-side plan preview everywhere
///     — once parity's verified, [PlanPreviewScreen] can be retired.
class UnifiedPreviewScreen extends StatefulWidget {
  final Session session;
  final LocalStorageService storage;

  const UnifiedPreviewScreen({
    super.key,
    required this.session,
    required this.storage,
  });

  @override
  State<UnifiedPreviewScreen> createState() => _UnifiedPreviewScreenState();
}

class _UnifiedPreviewScreenState extends State<UnifiedPreviewScreen> {
  WebViewController? _controller;
  Uri? _playerUri;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      await LocalPlayerServer.instance.start(
        session: widget.session,
        storage: widget.storage,
      );
      final uri = LocalPlayerServer.instance.buildPlayerUrl();

      // iOS needs inline media playback + no user-gesture requirement
      // so the web-player's `<video autoplay muted>` calls succeed on
      // first paint. On Android the defaults already allow both.
      final PlatformWebViewControllerCreationParams params =
          Platform.isIOS
              ? WebKitWebViewControllerCreationParams(
                  allowsInlineMediaPlayback: true,
                  mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
                )
              : const PlatformWebViewControllerCreationParams();

      final controller = WebViewController.fromPlatformCreationParams(params)
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(AppColors.surfaceBase)
        ..setNavigationDelegate(
          NavigationDelegate(
            onNavigationRequest: (req) {
              // Any navigation AWAY from the loopback origin (share
              // sheet opens) is blocked. Local bundle only navigates
              // same-origin; anything else is a stray tap on a
              // placeholder link.
              final dest = Uri.tryParse(req.url);
              if (dest != null &&
                  dest.host == uri.host &&
                  dest.port == uri.port) {
                return NavigationDecision.navigate;
              }
              return NavigationDecision.prevent;
            },
            onPageStarted: (_) {},
            onPageFinished: (_) {
              if (mounted) setState(() => _loading = false);
            },
            onWebResourceError: (err) {
              if (kDebugMode) {
                debugPrint(
                  '[UnifiedPreview] resource error: ${err.errorType} ${err.description}',
                );
              }
            },
          ),
        );

      await controller.loadRequest(uri);

      if (!mounted) return;
      setState(() {
        _controller = controller;
        _playerUri = uri;
      });
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[UnifiedPreview] boot failed: $e\n$st');
      }
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    // Stop the server when the screen closes. The controller shuts
    // itself down via Flutter's widget lifecycle. Use unawaited so
    // dispose() stays synchronous.
    unawaited(LocalPlayerServer.instance.stop());
    super.dispose();
  }

  // TODO(wave4-phase2): wire a postMessage bridge so the web-player can
  //   request haptic feedback (`HapticFeedback.selectionClick` on pill
  //   tap, `HapticFeedback.mediumImpact` on prep finish) and so the
  //   trainer app can update the iOS AVAudioSession category to
  //   playback when the first video plays (so a Silent-mode phone still
  //   emits audio like the production player on session.homefit.studio).
  //   Bridge shape: controller.addJavaScriptChannel('HomefitHost', ...)
  //   on the WebView side; `window.HomefitHost.postMessage(...)` calls
  //   from app.js.


  @override
  Widget build(BuildContext context) {
    final controller = _controller;

    return Scaffold(
      backgroundColor: AppColors.surfaceBase,
      appBar: AppBar(
        backgroundColor: AppColors.surfaceBase,
        foregroundColor: AppColors.textOnDark,
        elevation: 0,
        title: const Text(
          'Unified Preview (prototype)',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        actions: [
          if (_playerUri != null)
            IconButton(
              tooltip: 'Reload bundle',
              icon: const Icon(Icons.refresh),
              onPressed: () {
                _controller?.reload();
              },
            ),
        ],
      ),
      body: Stack(
        children: [
          if (_error != null)
            _ErrorView(message: _error!)
          else if (controller != null)
            WebViewWidget(controller: controller)
          else
            const SizedBox.expand(),
          if (_loading)
            const ColoredBox(
              color: AppColors.surfaceBase,
              child: Center(
                child: CircularProgressIndicator(color: AppColors.primary),
              ),
            ),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  const _ErrorView({required this.message});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline,
                color: AppColors.primary, size: 48),
            const SizedBox(height: 16),
            const Text(
              'Unified preview failed to start',
              style: TextStyle(
                color: AppColors.textOnDark,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              message,
              style: const TextStyle(
                color: AppColors.textSecondaryOnDark,
                fontSize: 13,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
