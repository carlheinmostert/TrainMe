import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
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

/// Wave 30 — single-shot, full-screen camera surface for the client
/// avatar. Practitioner taps the avatar slot on `ClientSessionsScreen`,
/// captures one still, native iOS pipeline produces a body-focus blurred
/// PNG (subject crisp / background heavily Gaussian-blurred), and the
/// result is committed locally + uploaded to the private `raw-archive`
/// bucket at `<practiceId>/<clientId>/avatar.png`.
///
/// Deliberately NOT a long-press-record / pinch / lens-pill / multi-shot
/// surface — capture is a single still, retake/confirm preview, done.
/// Reuses the camera plugin patterns from `capture_mode_screen.dart` but
/// strips out plan / exercise / video machinery.
///
/// Runs the full processing pass on the platform channel
/// (`processClientAvatar`); the spinner stays up while that returns.
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
  static const MethodChannel _processor =
      MethodChannel('com.raidme.video_converter');

  CameraController? _controller;
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
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final ctrl = _controller;
    if (ctrl == null) return;
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      ctrl.dispose();
      if (mounted) setState(() => _initialised = false);
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  Future<void> _initCamera() async {
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) {
        setState(() => _initFailed = true);
        return;
      }
      // Prefer the back camera; iPhone has both, the back is the natural
      // pick for capturing a client across the room. Practitioner can
      // exit + re-tap if they want a self-portrait — single-shot UX is
      // intentional.
      //
      // iPhone multi-camera virtual devices default to the 0.5× ultrawide
      // when zoom is unset, which fish-eyes the subject at avatar range.
      // Snap to 1.0× post-init so the standard wide is in play. Mirror of
      // capture_mode_screen._attachController.
      var idx = cams.indexWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
      );
      if (idx < 0) idx = 0;
      final controller = CameraController(
        cams[idx],
        ResolutionPreset.high,
        enableAudio: false,
      );
      await controller.initialize();
      try {
        final minZoom = await controller.getMinZoomLevel();
        final maxZoom = await controller.getMaxZoomLevel();
        await controller
            .setZoomLevel(1.0.clamp(minZoom, maxZoom).toDouble());
      } catch (_) {
        // Some simulators / single-lens devices throw — safe to ignore;
        // there's no ultrawide to flee from on those.
      }
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _initialised = true;
      });
    } catch (e) {
      debugPrint('ClientAvatarCaptureScreen camera init failed: $e');
      if (mounted) {
        setState(() => _initFailed = true);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Capture + native processing
  // ---------------------------------------------------------------------------

  Future<void> _capture() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _processing) {
      return;
    }
    HapticFeedback.mediumImpact();
    setState(() => _processing = true);

    try {
      final xFile = await controller.takePicture();
      // Keep raw + composed under the same scratch directory; we delete
      // the raw immediately after the composer succeeds — only the
      // composed PNG sticks around (and only until the practitioner
      // confirms Use this; we then move it to its persistent home).
      final tempDir = await getTemporaryDirectory();
      final composedPath = p.join(
        tempDir.path,
        'avatar_${const Uuid().v4()}.png',
      );

      final dynamic resp = await _processor.invokeMethod<Object?>(
        'processClientAvatar',
        <String, dynamic>{
          'rawPath': xFile.path,
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
        await File(xFile.path).delete();
      } catch (_) {}

      if (resp is Map && resp['success'] == true) {
        if (!mounted) return;
        setState(() {
          _composedPath = composedPath;
          _processing = false;
        });
      } else {
        throw StateError('Unexpected processor response: $resp');
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
    if (!_initialised || _controller == null) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.primary),
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        Center(
          child: AspectRatio(
            aspectRatio: _controller!.value.aspectRatio,
            child: CameraPreview(_controller!),
          ),
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
              onTap: _processing ? null : _capture,
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
