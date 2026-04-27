import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/client.dart';
import '../services/api_client.dart';
import '../services/path_resolver.dart';
import '../services/sync_service.dart';
import '../theme.dart';
import '../widgets/orientation_lock_guard.dart';

/// Wave 30 / Wave 34 — single-shot, full-screen camera surface for the
/// client avatar.
///
/// **Wave 34 rewrite:** the Flutter `camera` plugin is GONE on this
/// surface. Wave 33 confirmed via Console.app that the plugin enumerates
/// the iPhone's virtual multi-cam device (`.builtInDualWideCamera` /
/// `.builtInTripleCamera`) under one name `"Back Camera"` — that virtual
/// device auto-switches lenses based on subject distance, which is what
/// produced the fish-eye Carl reported through Waves 31, 32, 33. No
/// Dart-side picker can defeat the lens-switch (it's hidden behind the
/// virtual device).
///
/// This screen now owns NOTHING camera-related. The native side runs an
/// `AVCaptureSession` against the canonical 1× `.builtInWideAngleCamera`
/// directly (see `AvatarCameraChannel.swift`). The live preview is a
/// `UiKitView` hosting an `AVCaptureVideoPreviewLayer` whose connection
/// is pinned to `.portrait`. The shutter goes through a platform-channel
/// `avatarCameraCapture` call which writes JPEG to a temp path; the
/// existing `processClientAvatar` channel call (unchanged) consumes that
/// JPEG to produce the body-focus blurred PNG.
///
/// Diagnostic logging now lives in Swift via `os_log` against
/// subsystem `com.raidme.raidme`, category `avatar.capture` — Carl
/// filters Console.app on those exact strings. Dart-side
/// `dart:developer.log()` doesn't surface in Console.app for iOS Flutter
/// profile/release builds.
///
/// Deliberately NOT a long-press-record / pinch / lens-pill / multi-shot
/// surface — capture is a single still, retake/confirm preview, done.
///
/// Cloud upload + RPC are best-effort: a failure shows a SnackBar but
/// the local cached path persists so the avatar still renders next time
/// the practitioner opens the client.
class ClientAvatarCaptureScreen extends StatefulWidget {
  final PracticeClient client;

  const ClientAvatarCaptureScreen({super.key, required this.client});

  @override
  State<ClientAvatarCaptureScreen> createState() =>
      _ClientAvatarCaptureScreenState();
}

class _ClientAvatarCaptureScreenState extends State<ClientAvatarCaptureScreen>
    with WidgetsBindingObserver {
  /// Channel for the existing avatar-processing pipeline (Vision body
  /// segmentation + Gaussian blur compose). Unchanged in Wave 34.
  static const MethodChannel _processor =
      MethodChannel('com.raidme.video_converter');

  /// Wave 34 — new dedicated channel for the native AVFoundation camera
  /// glass. See `AvatarCameraChannel.swift`.
  static const MethodChannel _camera = MethodChannel('com.raidme.avatar_camera');

  /// Wave 34 — view-type identifier for the native preview UiKitView.
  /// MUST match the registration in `AppDelegate.swift`.
  static const String _previewViewType = 'homefit/avatar_camera_preview';

  bool _initialised = false;
  bool _initFailed = false;
  bool _processing = false;

  /// Absolute path to the composed PNG once processing succeeds. Drives
  /// the preview pane (Retake / Use this).
  String? _composedPath;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Fire-and-forget — the screen is going away regardless of whether
    // the native side acknowledges. AvatarCameraChannel.stopSession is
    // idempotent so a stray call after teardown is harmless.
    unawaited(_camera.invokeMethod<void>('avatarCameraStop').catchError((_) {}));
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      // Drop the camera while backgrounded so iOS doesn't kill us for
      // hogging hardware. The PlatformView re-attaches to the new
      // session via `sessionDidStartNotification` when we resume.
      unawaited(
        _camera.invokeMethod<void>('avatarCameraStop').catchError((_) {}),
      );
      if (mounted) setState(() => _initialised = false);
    } else if (state == AppLifecycleState.resumed) {
      _startCamera();
    }
  }

  /// Boot (or re-boot) the native AVCaptureSession. Idempotent on the
  /// native side — safe to invoke from both `initState` and the
  /// app-lifecycle resume path.
  Future<void> _startCamera() async {
    try {
      final dynamic resp = await _camera
          .invokeMethod<Object?>('avatarCameraStart')
          .timeout(const Duration(seconds: 5));
      if (resp is Map) {
        debugPrint(
          'AvatarCamera started: '
          'device="${resp['deviceName']}" '
          'uniqueID="${resp['deviceUniqueID']}" '
          'type="${resp['deviceTypeRaw']}" '
          'minZoom=${resp['minZoom']} maxZoom=${resp['maxZoom']}',
        );
      }
      if (!mounted) return;
      setState(() {
        _initialised = true;
        _initFailed = false;
      });
    } catch (e) {
      debugPrint('AvatarCamera start failed: $e');
      if (!mounted) return;
      setState(() => _initFailed = true);
    }
  }

  // ---------------------------------------------------------------------------
  // Capture + native processing
  // ---------------------------------------------------------------------------

  Future<void> _capture() async {
    if (!_initialised || _processing) return;
    HapticFeedback.mediumImpact();
    setState(() => _processing = true);

    try {
      final tempDir = await getTemporaryDirectory();
      final captureId = const Uuid().v4();
      final rawPath = p.join(tempDir.path, 'avatar_raw_$captureId.jpg');
      final composedPath = p.join(tempDir.path, 'avatar_$captureId.png');

      // --- Native AVFoundation capture ---
      final dynamic capResp = await _camera.invokeMethod<Object?>(
        'avatarCameraCapture',
        <String, dynamic>{'outPath': rawPath},
      ).timeout(
        const Duration(seconds: 10),
        onTimeout: () =>
            throw TimeoutException('Camera capture timed out after 10s'),
      );
      if (capResp is! Map || capResp['success'] != true) {
        throw StateError('Unexpected camera response: $capResp');
      }

      // --- Body-focus blur compose (unchanged Wave 30 pipeline) ---
      final dynamic procResp = await _processor.invokeMethod<Object?>(
        'processClientAvatar',
        <String, dynamic>{
          'rawPath': rawPath,
          'outPath': composedPath,
        },
      ).timeout(
        const Duration(seconds: 30),
        onTimeout: () => throw TimeoutException(
          'Avatar processing timed out after 30s',
        ),
      );

      // Best-effort cleanup of the raw camera capture — we don't keep it.
      try {
        await File(rawPath).delete();
      } catch (_) {}

      if (procResp is Map && procResp['success'] == true) {
        if (!mounted) return;
        setState(() {
          _composedPath = composedPath;
          _processing = false;
        });
      } else {
        throw StateError('Unexpected processor response: $procResp');
      }
    } catch (e) {
      debugPrint('Avatar capture/process failed: $e');
      if (!mounted) return;
      setState(() => _processing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't process avatar — try again.")),
      );
    }
  }

  void _retake() {
    HapticFeedback.selectionClick();
    final stale = _composedPath;
    setState(() => _composedPath = null);
    if (stale != null) {
      try {
        File(stale).deleteSync();
      } catch (_) {}
    }
  }

  Future<void> _useThis() async {
    final composed = _composedPath;
    if (composed == null || _processing) return;
    HapticFeedback.mediumImpact();
    setState(() => _processing = true);

    try {
      // Move the temp PNG into the persistent avatars/ folder. Stored
      // relative for PathResolver round-trip resilience across iOS
      // container reinstalls.
      final docs = PathResolver.docsDir;
      final avatarsDir = Directory(p.join(docs, 'avatars'));
      if (!avatarsDir.existsSync()) {
        avatarsDir.createSync(recursive: true);
      }
      final localFilename = '${widget.client.id}.png';
      final localAbs = p.join(avatarsDir.path, localFilename);
      try {
        // Replace any prior file (re-capture).
        if (File(localAbs).existsSync()) {
          File(localAbs).deleteSync();
        }
      } catch (_) {}
      await File(composed).copy(localAbs);
      try {
        await File(composed).delete();
      } catch (_) {}

      final relLocal = PathResolver.toRelative(localAbs);

      // Cloud-side path. The bucket policy keys off the FIRST segment
      // being a practice_id the caller belongs to — so the
      // {practiceId}/{clientId}/avatar.png shape passes RLS for every
      // practitioner in the practice.
      final cloudPath =
          '${widget.client.practiceId}/${widget.client.id}/avatar.png';

      // Best-effort cloud upload. Failure does NOT block the local
      // pointer — the avatar still renders from the local file, and the
      // queued `set_client_avatar` op will fail-then-retry on the next
      // online drain (the storage upload itself doesn't queue, but
      // re-running this capture re-uploads, and Storage is idempotent
      // on path).
      bool uploaded = true;
      try {
        await ApiClient.instance.uploadRawArchive(
          path: cloudPath,
          file: File(localAbs),
          contentType: 'image/png',
        );
      } catch (e) {
        uploaded = false;
        debugPrint('Avatar raw-archive upload failed: $e');
      }

      // Local-first cache write + queued cloud RPC. We pass the cloud
      // path even on upload failure — a later re-attempt (re-capture)
      // will overwrite the bytes; the column tracks the canonical path.
      // The local PNG path stays accessible via the `avatar_path`-vs-
      // -local-file-system fallback rule (see _ClientHeader avatar slot).
      await SyncService.instance.queueSetAvatar(
        clientId: widget.client.id,
        avatarPath: cloudPath,
      );

      if (!mounted) return;
      Navigator.of(context).pop<_AvatarCaptureResult>(
        _AvatarCaptureResult(
          localRelativePath: relLocal,
          cloudPath: cloudPath,
          uploadedToCloud: uploaded,
        ),
      );
    } catch (e) {
      debugPrint('Avatar persist/upload failed: $e');
      if (!mounted) return;
      setState(() => _processing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't save avatar — try again.")),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // Single-shot still capture — no reason to allow landscape; the
    // shutter/preview chrome is laid out portrait-only. Explicit lock
    // (vs leaning on the guard's default) so the intent is obvious at
    // the call site.
    return OrientationLockGuard(
      allowed: const {DeviceOrientation.portraitUp},
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: _composedPath != null
              ? _buildPreview(_composedPath!)
              : _buildCameraSurface(),
        ),
      ),
    );
  }

  Widget _buildCameraSurface() {
    if (_initFailed) {
      return _buildErrorState();
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        // Native preview hosted via PlatformView. The session lives on
        // the native side; this UIView re-attaches to it via the
        // sessionDidStart notification.
        if (_initialised)
          const UiKitView(
            viewType: _previewViewType,
            creationParamsCodec: StandardMessageCodec(),
          )
        else
          const Center(
            child: CircularProgressIndicator(color: AppColors.primary),
          ),
        // Top bar: close + caption.
        Positioned(
          top: 12,
          left: 12,
          right: 12,
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 28),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Take an avatar still',
                  style: TextStyle(
                    fontFamily: 'Montserrat',
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ),
        // Hint band — explains the body-focus blur in plain language so
        // the practitioner knows what's about to happen.
        Positioned(
          left: 24,
          right: 24,
          bottom: 132,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Text(
              'Frame ${'\u201C'}${'them'}${'\u201D'} naturally — the background gets blurred '
              'on save.',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 13,
                color: Colors.white,
                height: 1.4,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
        // Bottom shutter.
        Positioned(
          left: 0,
          right: 0,
          bottom: 28,
          child: Center(
            child: GestureDetector(
              onTap: (_processing || !_initialised) ? null : _capture,
              child: Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 4),
                  color: _processing
                      ? AppColors.primary.withValues(alpha: 0.4)
                      : Colors.transparent,
                ),
                child: Center(
                  child: Container(
                    width: 60,
                    height: 60,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (_processing)
          Positioned.fill(
            child: Container(
              color: Colors.black54,
              alignment: Alignment.center,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(color: AppColors.primary),
                  const SizedBox(height: 16),
                  Text(
                    'Processing avatar…',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 14,
                      color: Colors.white.withValues(alpha: 0.95),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildPreview(String composedPath) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.file(
          File(composedPath),
          fit: BoxFit.contain,
        ),
        Positioned(
          top: 12,
          left: 12,
          child: IconButton(
            icon: const Icon(Icons.close, color: Colors.white, size: 28),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ),
        Positioned(
          left: 24,
          right: 24,
          bottom: 28,
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _processing ? null : _retake,
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.white70, width: 1.4),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                    ),
                  ),
                  child: const Text(
                    'Retake',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _processing ? null : _useThis,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                    ),
                  ),
                  child: _processing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor:
                                AlwaysStoppedAnimation<Color>(Colors.white),
                          ),
                        )
                      : const Text(
                          'Use this',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.videocam_off_outlined,
                color: Colors.white70, size: 48),
            const SizedBox(height: 12),
            const Text(
              'Camera unavailable',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Check Settings → Privacy → Camera and try again.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 13,
                color: Colors.white70,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.of(context).maybePop(),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
              ),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Result handed back from [ClientAvatarCaptureScreen] when the
/// practitioner taps "Use this". The caller (ClientSessionsScreen) uses
/// [localRelativePath] to immediately render the new avatar from disk
/// without waiting on a signed URL round-trip.
class _AvatarCaptureResult {
  final String localRelativePath;
  final String cloudPath;
  final bool uploadedToCloud;

  const _AvatarCaptureResult({
    required this.localRelativePath,
    required this.cloudPath,
    required this.uploadedToCloud,
  });
}

/// Public thin wrapper so callers don't have to know the result class is
/// scoped private. Push the screen and resolve to a (localPath, cloudPath)
/// or null if the user dismissed.
Future<ClientAvatarCaptureOutcome?> pushClientAvatarCapture(
  BuildContext context, {
  required PracticeClient client,
}) async {
  final raw = await Navigator.of(context).push<_AvatarCaptureResult>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => ClientAvatarCaptureScreen(client: client),
    ),
  );
  if (raw == null) return null;
  return ClientAvatarCaptureOutcome(
    localRelativePath: raw.localRelativePath,
    cloudPath: raw.cloudPath,
    uploadedToCloud: raw.uploadedToCloud,
  );
}

/// Public-facing twin of the private result class.
class ClientAvatarCaptureOutcome {
  final String localRelativePath;
  final String cloudPath;
  final bool uploadedToCloud;

  const ClientAvatarCaptureOutcome({
    required this.localRelativePath,
    required this.cloudPath,
    required this.uploadedToCloud,
  });
}
