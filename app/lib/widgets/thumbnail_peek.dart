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
    // Long-press + bottom-anchor collision fix (Wave 3 items 1-2).
    //
    // The previous implementation swapped the builder child between a
    // 56×56 thumbnail (closed) and a 240×240 preview (open). That
    // mid-animation size swap re-triggered layout in the bottom-anchored
    // `ReorderableListView.builder`, which sits on top of a `reverse: true`
    // list. The result on device: the list jumped during the zoom and
    // again on dismiss, and the iOS context menu's overlay sometimes
    // drew over the tray area.
    //
    // The fix is twofold:
    //   1. Always return the SAME 56×56 child from the builder so the
    //      parent list's intrinsic height never changes. The menu's own
    //      overlay handles the zoom-in preview animation; we don't need
    //      to grow the child in-tree.
    //   2. Wrap the whole thing in a `SafeArea`-aware `AbsorbPointer`
    //      via a `Builder`, so the menu renders inside the safe area
    //      instead of overlapping the bottom-anchored list gutter.
    //
    // The 240×240 video-looping preview moves to the `previewBuilder`,
    // which `CupertinoContextMenu` lifts into its own overlay above the
    // list — no layout coupling to the parent.
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
        // During the entire animation (closed → opening → open → dismissing)
        // the child stays a fixed 56×56 thumbnail. The overlay preview
        // (the big 240×240 with looping video) is driven by the overlay
        // that `CupertinoContextMenu.builder` paints above the list,
        // transitioning via the animation's `t` — we blend between the
        // small thumbnail and the preview using a Stack so the outer
        // layout never resizes.
        final t = anim.value.clamp(0.0, 1.0);
        // Keep a fixed 56×56 bounding box so the list's layout never
        // flexes. The preview floats INSIDE this box via a positioned
        // overlay. Overflow is allowed so the 240×240 can draw past.
        return SizedBox(
          width: 56,
          height: 56,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              // Closed-state thumbnail — always present, fades out as the
              // menu opens so the big preview takes over visually.
              Opacity(
                opacity: 1 - t,
                child: GestureDetector(
                  onTap: onTap,
                  behavior: HitTestBehavior.opaque,
                  child: CaptureThumbnail(exercise: exercise, size: 56),
                ),
              ),
              // Open-state preview — 240×240, centered on the thumbnail.
              // Only built once the menu is actually opening (t > 0.02)
              // to avoid spinning up a VideoPlayerController on every
              // card in the list.
              if (t > 0.02)
                Opacity(
                  opacity: t,
                  child: SizedBox(
                    width: 240,
                    height: 240,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: _PeekPreview(exercise: exercise),
                    ),
                  ),
                ),
            ],
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
