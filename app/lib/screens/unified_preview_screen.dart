import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart'
    show
        PlaybackMediaTypes,
        WebKitWebViewController,
        WebKitWebViewControllerCreationParams;

import '../models/session.dart';
import '../services/local_storage_service.dart';
import '../services/unified_preview_scheme_bridge.dart';
import '../theme.dart';
import '../widgets/orientation_lock_guard.dart';

/// Name of the iOS platform method channel that owns the
/// `AVAudioSession` lifecycle for the unified preview. Implemented in
/// `app/ios/Runner/UnifiedPreviewAudioChannel.swift`.
const MethodChannel _audioChannel =
    MethodChannel('com.raidme.unified_preview_audio');

/// Name of the `WKUserContentController` channel the WebView bundle
/// posts JSON messages to. Mirrored as `window.HomefitBridge` on the
/// JS side (see `web-player/app.js` — `installHomefitBridge`).
const String _bridgeChannelName = 'HomefitBridge';

/// Wave 4 Phase 2 — unified player screen.
///
/// Loads the bundled `web-player/` code inside a [WebView] via the
/// custom `homefit-local://plan/...` scheme handled natively by
/// `UnifiedPlayerSchemeHandler.swift` and resolved against the local
/// SQLite session by [UnifiedPreviewSchemeBridge].
///
/// Route shape:
///   `homefit-local://plan/?planId=<session-id>&src=local`
///
/// The same web-player bundle that runs at session.homefit.studio
/// reads `src=local` in api.js and routes `get_plan_full` against the
/// scheme handler, which builds the payload from SQLite. Media URLs in
/// that payload resolve to local archived files via the same handler.
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
  String? _error;
  bool _loading = true;
  bool _audioSessionActivated = false;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      // Phase 1 (loopback shelf HTTP server) was retired 2026-04-26 —
      // the dead path was a footgun (Wave 37 hotfix landed in the wrong
      // file). Custom `homefit-local://` scheme is now the only transport.
      // Bind the Dart-side resolver so the Swift scheme handler can
      // answer plan-JSON + media-path requests against this session.
      UnifiedPreviewSchemeBridge.instance.bind(
        session: widget.session,
        storage: widget.storage,
      );
      final uri = Uri(
        scheme: 'homefit-local',
        host: 'plan',
        path: '/',
        queryParameters: {
          'planId': widget.session.id,
          'src': 'local',
        },
      );

      // iOS needs inline media playback + no user-gesture requirement
      // so the web-player's `<video autoplay muted>` calls succeed on
      // first paint. On Android the defaults already allow both. In
      // Phase 2 the iOS variant ALSO registers a `WKURLSchemeHandler`
      // native-side that resolves `homefit-local://` URLs; that lives
      // in Swift (see UnifiedPlayerSchemeHandler) and is wired from
      // AppDelegate via `UnifiedPreviewSchemeRegistrar.register()`
      // before the FlutterView creates its WebView.
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
        ..addJavaScriptChannel(
          _bridgeChannelName,
          onMessageReceived: _onBridgeMessage,
        );

      // Safari Web Inspector — iOS 16.4+ gates WKWebView inspection
      // behind `isInspectable = true`. The underlying WebKit controller
      // exposes `setInspectable` on iOS 16.4+; a no-op on older runtimes.
      // Always on in debug/profile so device QA can attach Safari
      // Develop → iPhone → homefit.studio WebView without rebuilding.
      // Release builds leave inspection off (PII + CSP concerns).
      if (Platform.isIOS && (kDebugMode || kProfileMode)) {
        final platform = controller.platform;
        if (platform is WebKitWebViewController) {
          try {
            await platform.setInspectable(true);
          } catch (e) {
            // Older webview_flutter_wkwebview versions won't expose
            // setInspectable; silently skip so QA still works on the
            // loopback path.
            if (kDebugMode) {
              debugPrint('[UnifiedPreview] setInspectable unavailable: $e');
            }
          }
        }
      }

      controller.setNavigationDelegate(
          NavigationDelegate(
            onNavigationRequest: (req) {
              // Any navigation AWAY from the bundle's origin (share
              // sheet opens, stray link taps) is blocked. The bundle
              // only ever navigates same-origin. The custom URL scheme
              // has no port concept, so scheme + host is sufficient.
              final dest = Uri.tryParse(req.url);
              if (dest == null) return NavigationDecision.prevent;
              if (dest.scheme == uri.scheme && dest.host == uri.host) {
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
    // Drop the audio-session override so the OS reverts to ambient /
    // silent-respecting behaviour for whatever comes next. Done BEFORE
    // the bridge unbind so the platform call lands while the engine
    // still has a valid messenger.
    if (_audioSessionActivated) {
      unawaited(_setAudioPlayback(false));
    }
    UnifiedPreviewSchemeBridge.instance.unbind();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Native bridge — JSON messages posted from `window.HomefitBridge` in
  // `web-player/app.js`. Shape:
  //   { "type": "haptic", "kind": "selection"|"mediumImpact"|"heavyImpact" }
  //   { "type": "audio",  "active": true|false }
  // Malformed or unknown messages are logged (debug only) and ignored
  // so a stray payload can't crash the preview.
  // ---------------------------------------------------------------------------

  void _onBridgeMessage(JavaScriptMessage message) {
    Map<String, dynamic> payload;
    try {
      final decoded = jsonDecode(message.message);
      if (decoded is! Map<String, dynamic>) return;
      payload = decoded;
    } catch (_) {
      if (kDebugMode) {
        debugPrint('[UnifiedPreview] bridge: bad JSON: ${message.message}');
      }
      return;
    }

    final type = payload['type'];
    switch (type) {
      case 'haptic':
        final kind = payload['kind'];
        if (kind is String) _dispatchHaptic(kind);
        break;
      case 'audio':
        final active = payload['active'] == true;
        _audioSessionActivated = _audioSessionActivated || active;
        unawaited(_setAudioPlayback(active));
        break;
      default:
        if (kDebugMode) {
          debugPrint('[UnifiedPreview] bridge: unknown type "$type"');
        }
    }
  }

  void _dispatchHaptic(String kind) {
    switch (kind) {
      case 'selection':
        HapticFeedback.selectionClick();
        break;
      case 'mediumImpact':
        HapticFeedback.mediumImpact();
        break;
      case 'heavyImpact':
        HapticFeedback.heavyImpact();
        break;
      default:
        if (kDebugMode) {
          debugPrint('[UnifiedPreview] bridge: unknown haptic kind "$kind"');
        }
    }
  }

  Future<void> _setAudioPlayback(bool active) async {
    if (!Platform.isIOS) return;
    try {
      await _audioChannel.invokeMethod<void>(
        'setPlaybackCategory',
        {'active': active},
      );
    } on PlatformException catch (e) {
      if (kDebugMode) {
        debugPrint('[UnifiedPreview] audio channel failed: ${e.code} ${e.message}');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[UnifiedPreview] audio channel threw: $e');
      }
    }
  }


  @override
  Widget build(BuildContext context) {
    final controller = _controller;

    return OrientationLockGuard(
      // Practitioner verifies what the client sees, so the WebView
      // mirrors the client surface's allowed orientations: portrait OR
      // landscape. Studio's parent guard restores portrait when this
      // screen pops.
      allowed: const {
        DeviceOrientation.portraitUp,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      },
      child: Scaffold(
      backgroundColor: AppColors.surfaceBase,
      // No AppBar — every pixel of vertical space is precious for the
      // player, especially in landscape on iOS where Safari already
      // surfaces its own chrome. The back-out affordance is a small
      // overlay button (top-left) painted on top of the WebView.
      body: Stack(
        children: [
          if (_error != null)
            _ErrorView(message: _error!)
          else if (controller != null)
            Positioned.fill(child: WebViewWidget(controller: controller))
          else
            const SizedBox.expand(),
          // Top-left back-out chip. Same circular dark-pill styling as
          // the in-WebView right-rail chrome so the practitioner reads
          // it as preview chrome, not a system bar. Flush in the
          // top-left corner against the status-bar inset — no extra
          // padding (SafeArea was previously doubling the inset).
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
                tooltip: 'Close preview',
                icon: const Icon(
                  Icons.close_rounded,
                  color: AppColors.primary,
                ),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ),
          ),
          if (_loading)
            const ColoredBox(
              color: AppColors.surfaceBase,
              child: Center(
                child: CircularProgressIndicator(color: AppColors.primary),
              ),
            ),
        ],
      ),
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
