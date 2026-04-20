import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart'
    show PlaybackMediaTypes, WebKitWebViewControllerCreationParams;

import '../models/session.dart';
import '../services/local_player_server.dart';
import '../services/local_storage_service.dart';
import '../services/unified_preview_scheme_bridge.dart';
import '../theme.dart';

/// Wave 4 Phase 2 — transport toggle.
///
/// Phase 1 served the web-player bundle over a loopback shelf HTTP server
/// bound to `127.0.0.1:<ephemeral>`. Phase 2 replaces that with a custom
/// `WKURLSchemeHandler` (see `UnifiedPlayerSchemeHandler.swift`) scheme
/// `homefit-local://plan/...` — no port allocation, no shelf process,
/// cleaner Range streaming. Flip this flag back to `true` for an
/// emergency rollback to the shelf path; the dead code is retained for
/// that reason (delete in a follow-up once the new transport has baked
/// on device for a week).
const bool kUseShelfFallback = false;

/// Name of the iOS platform method channel that owns the
/// `AVAudioSession` lifecycle for the unified preview. Implemented in
/// `app/ios/Runner/UnifiedPreviewAudioChannel.swift`.
const MethodChannel _audioChannel =
    MethodChannel('com.raidme.unified_preview_audio');

/// Name of the `WKUserContentController` channel the WebView bundle
/// posts JSON messages to. Mirrored as `window.HomefitBridge` on the
/// JS side (see `web-player/app.js` — `installHomefitBridge`).
const String _bridgeChannelName = 'HomefitBridge';

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
  bool _audioSessionActivated = false;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      // Resolve the transport URL. Phase 2 default: a custom
      // `homefit-local://plan/` scheme handled natively. Phase 1
      // rollback path: boot the shelf server and use its loopback URL.
      Uri uri;
      if (kUseShelfFallback) {
        await LocalPlayerServer.instance.start(
          session: widget.session,
          storage: widget.storage,
        );
        uri = LocalPlayerServer.instance.buildPlayerUrl();
      } else {
        // Bind the Dart-side resolver so the Swift scheme handler can
        // answer plan-JSON + media-path requests against this session.
        UnifiedPreviewSchemeBridge.instance.bind(
          session: widget.session,
          storage: widget.storage,
        );
        uri = Uri(
          scheme: 'homefit-local',
          host: 'plan',
          path: '/',
          queryParameters: {
            'planId': widget.session.id,
            'src': 'local',
          },
        );
      }

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
        )
        ..setNavigationDelegate(
          NavigationDelegate(
            onNavigationRequest: (req) {
              // Any navigation AWAY from the bundle's origin (share
              // sheet opens, stray link taps) is blocked. The bundle
              // only ever navigates same-origin.
              final dest = Uri.tryParse(req.url);
              if (dest == null) return NavigationDecision.prevent;
              final sameScheme = dest.scheme == uri.scheme;
              if (kUseShelfFallback) {
                if (sameScheme &&
                    dest.host == uri.host &&
                    dest.port == uri.port) {
                  return NavigationDecision.navigate;
                }
              } else {
                // Phase 2: compare scheme + host for the custom URL
                // scheme. There is no port concept.
                if (sameScheme && dest.host == uri.host) {
                  return NavigationDecision.navigate;
                }
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
    // Drop the audio-session override so the OS reverts to ambient /
    // silent-respecting behaviour for whatever comes next. Done BEFORE
    // the server teardown so the platform call lands while the engine
    // still has a valid messenger.
    if (_audioSessionActivated) {
      unawaited(_setAudioPlayback(false));
    }
    // Stop the shelf server when the screen closes — a no-op if Phase
    // 2's native scheme path was used. The controller shuts itself
    // down via Flutter's widget lifecycle. Use unawaited so dispose()
    // stays synchronous.
    if (kUseShelfFallback) {
      unawaited(LocalPlayerServer.instance.stop());
    } else {
      UnifiedPreviewSchemeBridge.instance.unbind();
    }
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
