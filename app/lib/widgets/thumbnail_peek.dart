import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import '../models/exercise_capture.dart';
import 'capture_thumbnail.dart';

/// Thumbnail Peek — long-press on an exercise-card thumbnail opens an
/// iOS-style context menu. The preview zooms to ~240×240; videos auto-loop
/// muted; the action sheet below has:
///   - Open full-screen  (primary)
///   - Replace media
///   - Download original (videos only — opens the Save/Share bottom sheet)
///   - Delete exercise   (destructive, immediate, undo-via-toast)
///
/// No modal confirmation before delete — R-01 across the board.
class ThumbnailPeek extends StatelessWidget {
  final ExerciseCapture exercise;
  final VoidCallback onTap;
  final VoidCallback onOpenFullScreen;
  final VoidCallback onReplaceMedia;
  final VoidCallback onDelete;

  /// Fires when the practitioner taps "Download original" in the
  /// long-press menu for a video exercise. The handler is expected to
  /// call `showDownloadOriginalSheet(...)` with the plan's practice +
  /// plan ids so the signed-URL fallback can resolve. Null disables
  /// the action (e.g. the card is rendered in a context without plan
  /// coordinates — today only Studio wires it).
  final VoidCallback? onDownloadOriginal;

  const ThumbnailPeek({
    super.key,
    required this.exercise,
    required this.onTap,
    required this.onOpenFullScreen,
    required this.onReplaceMedia,
    required this.onDelete,
    this.onDownloadOriginal,
  });

  @override
  Widget build(BuildContext context) {
    // Rest periods never open a peek — they have no media.
    if (exercise.isRest) {
      return GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: CaptureThumbnail(exercise: exercise, size: 56),
      );
    }
    // Long-press + z-order fix (Wave 3 items 1 + retest after #47).
    //
    // Earlier fix used `CupertinoContextMenu.builder` with an unclipped
    // Stack holding both a 56×56 thumbnail and a 240×240 preview. The
    // Clip.none + overflow approach let the preview bleed through other
    // list items during open/dismiss ("popping behind the exercise" —
    // Carl, Wave 3).
    //
    // New approach: size-interpolate the builder return. Outer SizedBox
    // grows from 56×56 (t=0, closed) to 240×240 (t=1, open) — no
    // overflow, no Clip.none, no z-order surprises. The embedded list
    // render sees t=0 only, so the list's layout never flexes; iOS's
    // overlay sees the animated growth.
    final isVideo = exercise.mediaType == MediaType.video;
    return CupertinoContextMenu.builder(
      actions: [
        CupertinoContextMenuAction(
          trailingIcon: CupertinoIcons.fullscreen,
          onPressed: () {
            Navigator.of(context, rootNavigator: true).pop();
            onOpenFullScreen();
          },
          child: const Text('Open full-screen'),
        ),
        CupertinoContextMenuAction(
          trailingIcon: CupertinoIcons.photo,
          onPressed: () {
            Navigator.of(context, rootNavigator: true).pop();
            onReplaceMedia();
          },
          child: const Text('Replace media'),
        ),
        // Video-only: pull the original colour capture down to the
        // practitioner's device via Photos / share sheet. Wired into
        // the Studio card via `onDownloadOriginal`; no-ops for photos
        // and rest periods (rest never reaches this branch anyway).
        if (isVideo && onDownloadOriginal != null)
          CupertinoContextMenuAction(
            trailingIcon: CupertinoIcons.arrow_down_to_line,
            onPressed: () {
              Navigator.of(context, rootNavigator: true).pop();
              onDownloadOriginal!();
            },
            child: const Text('Download original'),
          ),
        CupertinoContextMenuAction(
          isDestructiveAction: true,
          trailingIcon: CupertinoIcons.delete,
          onPressed: () {
            Navigator.of(context, rootNavigator: true).pop();
            HapticFeedback.mediumImpact();
            onDelete();
          },
          child: const Text('Delete exercise'),
        ),
      ],
      builder: (BuildContext ctx, Animation<double> anim) {
        final t = anim.value.clamp(0.0, 1.0);
        final size = 56.0 + (240.0 - 56.0) * t;
        // Only build the video preview once the menu is opening — keeps
        // the list cheap (no VideoPlayerController per card at rest).
        final useBigPreview = t > 0.02;
        return SizedBox(
          width: size,
          height: size,
          child: useBigPreview
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: _PeekPreview(exercise: exercise),
                )
              : GestureDetector(
                  onTap: onTap,
                  behavior: HitTestBehavior.opaque,
                  child: CaptureThumbnail(exercise: exercise, size: 56),
                ),
        );
      },
    );
  }
}

class _PeekPreview extends StatefulWidget {
  final ExerciseCapture exercise;
  const _PeekPreview({required this.exercise});

  @override
  State<_PeekPreview> createState() => _PeekPreviewState();
}

class _PeekPreviewState extends State<_PeekPreview> {
  VideoPlayerController? _controller;
  bool _initialized = false;

  bool get _isVideo => widget.exercise.mediaType == MediaType.video;

  @override
  void initState() {
    super.initState();
    if (_isVideo) {
      final path = widget.exercise.displayFilePath;
      final controller = VideoPlayerController.file(File(path));
      _controller = controller;
      controller.initialize().then((_) {
        if (!mounted) return;
        setState(() => _initialized = true);
        controller.setLooping(true);
        controller.setVolume(0);
        controller.play();
      }).catchError((e) {
        // Fall back silently to the still thumbnail.
      });
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isVideo && _initialized && _controller != null) {
      return FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: _controller!.value.size.width,
          height: _controller!.value.size.height,
          child: VideoPlayer(_controller!),
        ),
      );
    }
    return CaptureThumbnail(exercise: widget.exercise, size: 240);
  }
}
