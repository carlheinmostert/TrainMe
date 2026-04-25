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

  /// Resting (closed-menu) thumbnail size. Wave 30 bumped Studio's
  /// card thumbnail from 56 → 88 so the caption-row beside it has
  /// roughly three lines of vertical company.
  final double size;

  const ThumbnailPeek({
    super.key,
    required this.exercise,
    required this.onTap,
    required this.onOpenFullScreen,
    required this.onReplaceMedia,
    required this.onDelete,
    this.onDownloadOriginal,
    this.size = 56,
  });

  @override
  Widget build(BuildContext context) {
    // Rest periods never open a peek — they have no media.
    if (exercise.isRest) {
      return GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: CaptureThumbnail(exercise: exercise, size: size),
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
        final currentSize = size + (240.0 - size) * t;
        // Only build the video preview once the menu is opening — keeps
        // the list cheap (no VideoPlayerController per card at rest).
        final useBigPreview = t > 0.02;
        // The moment the open animation kicks in (t > 0), strip chrome
        // from the still thumbnail. Otherwise the centred play-circle
        // glyph + media-type badge would be visible for the first
        // 0.02 of the animation, then vanish abruptly when the
        // _PeekPreview takes over — exactly the "popping in
        // background" Carl flagged on Wave 19.4 item 24.
        final chromeOff = t > 0.0;
        return SizedBox(
          width: currentSize,
          height: currentSize,
          child: useBigPreview
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: _PeekPreview(exercise: exercise),
                )
              : GestureDetector(
                  onTap: onTap,
                  behavior: HitTestBehavior.opaque,
                  child: CaptureThumbnail(
                    exercise: exercise,
                    size: size,
                    showChrome: !chromeOff,
                    showConversionOverlay: !chromeOff,
                  ),
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
    // Always render the still thumbnail underneath. The video texture,
    // when ready, stacks on top — never swap children mid-animation.
    //
    // Pre-fix the peek build returned EITHER a `CaptureThumbnail(240)`
    // OR a `VideoPlayer`, swapping the moment the controller
    // initialised (~100-300ms in). At 240×240 the still-thumbnail
    // fallback exposed a centred 96px play-circle glyph + a media-type
    // badge + (sometimes) a green check / spinner — all of which
    // flashed for a frame as the menu opened, then vanished when the
    // video texture replaced them. Carl saw this as "something popping
    // in background" (Wave 19.4 test item 24).
    //
    // Now: the still sits underneath WITHOUT chrome (no play-circle,
    // no media-type badge, no conversion overlay) and the video fades
    // in on top once ready. No swap, no flash, no chrome strobing.
    return Stack(
      fit: StackFit.expand,
      children: [
        CaptureThumbnail(
          exercise: widget.exercise,
          size: 240,
          showConversionOverlay: false,
          showChrome: false,
        ),
        if (_isVideo && _initialized && _controller != null)
          FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: _controller!.value.size.width,
              height: _controller!.value.size.height,
              child: VideoPlayer(_controller!),
            ),
          ),
      ],
    );
  }
}
