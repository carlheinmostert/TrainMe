/// Public re-export of the per-exercise media viewer body.
///
/// The widget itself lives in `studio_mode_screen.dart` (where it shares a
/// closure of private dependencies — `_TrimPanel`, `_RotatePill`,
/// `_PlayPauseOverlayButton`, `_CrossfadeTunerSheet`, `_VideoPagePlaceholder`,
/// `_MediaViewerBodyDotIndicator`, `_ReachabilityDropPill`, etc.). This
/// barrel file exists so the rest of the codebase can `import
/// 'widgets/media_viewer_body.dart';` without reaching for a full screen
/// import.
///
/// The same `MediaViewerBody` is used in two places:
///   * Studio mode pushes it as a full-screen `Navigator.push` route
///     (the practitioner's per-exercise demo / tune surface).
///   * The new `ExerciseEditorSheet` Preview tab embeds it directly as
///     a child of the `DraggableScrollableSheet` body.
///
/// Both contexts ride the same widget; `MediaViewerBody` includes its
/// own `Scaffold` + `OrientationLockGuard` + `PopScope` so a fresh route
/// works as-is, and Flutter's nested-Scaffold semantics keep the embed
/// case clean (the inner Scaffold paints inside the sheet's content area
/// without disturbing the host's app bar / SnackBar plumbing).
///
/// `MediaViewerExitInbox` is the post-pop focus-handoff channel. The
/// viewer stamps the currently-visible exercise id into it on system
/// back / iOS edge swipe; the host (`StudioModeScreen` in route mode,
/// `ExerciseEditorSheet` in tab-embed mode) reads + clears it after
/// close.
library;

export '../screens/studio_mode_screen.dart'
    show MediaViewerBody, MediaViewerExitInbox;
