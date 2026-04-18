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
///   - Delete exercise   (destructive, immediate, undo-via-toast)
///
/// No modal confirmation before delete — R-01 across the board.
class ThumbnailPeek extends StatelessWidget {
  final ExerciseCapture exercise;
  final VoidCallback onTap;
  final VoidCallback onOpenFullScreen;
  final VoidCallback onReplaceMedia;
  final VoidCallback onDelete;

  const ThumbnailPeek({
    super.key,
    required this.exercise,
    required this.onTap,
    required this.onOpenFullScreen,
    required this.onReplaceMedia,
    required this.onDelete,
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
        // When the menu is closed (animation at start), render the small
        // tap-target thumbnail. When it opens, expand to a 240x240 preview
        // with a looping video for video exercises.
        final isOpen = anim.value > 0.05;
        if (!isOpen) {
          return GestureDetector(
            onTap: onTap,
            behavior: HitTestBehavior.opaque,
            child: CaptureThumbnail(exercise: exercise, size: 56),
          );
        }
        return SizedBox(
          width: 240,
          height: 240,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: _PeekPreview(exercise: exercise),
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
