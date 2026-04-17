import 'package:flutter/material.dart';
import '../models/session.dart';
import '../services/local_storage_service.dart';
import '../theme.dart';
import 'capture_mode_screen.dart';
import 'studio_mode_screen.dart';

/// Two-mode session workspace split into separate temporal contexts.
///
/// - Index 0: [StudioModeScreen] — post-session editing (the "base" mode).
/// - Index 1: [CaptureModeScreen] — in-session camera capture.
///
/// Users swipe horizontally (via [PageView]) between the two. Edge pull-tabs
/// on each side act as a visual affordance that the other mode exists.
///
/// Entry semantics:
/// - "New Session" from home → opens with [initialPage] = 1 (Capture).
/// - Tap existing session card → opens with [initialPage] = 0 (Studio).
///
/// This is a speculative UX against the legacy single-screen
/// [SessionCaptureScreen]. The legacy screen is still in the tree as a
/// fallback — home_screen routing is the one-line rollback.
class SessionShellScreen extends StatefulWidget {
  final Session session;
  final LocalStorageService storage;

  /// 0 = Studio, 1 = Capture.
  final int initialPage;

  const SessionShellScreen({
    super.key,
    required this.session,
    required this.storage,
    required this.initialPage,
  });

  @override
  State<SessionShellScreen> createState() => _SessionShellScreenState();
}

class _SessionShellScreenState extends State<SessionShellScreen> {
  late final PageController _pageController;
  late Session _session;

  @override
  void initState() {
    super.initState();
    _session = widget.session;
    _pageController = PageController(initialPage: widget.initialPage);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  /// Refresh the session from storage — called after either mode mutates it.
  Future<void> _refreshSession() async {
    final refreshed = await widget.storage.getSession(_session.id);
    if (refreshed != null && mounted) {
      setState(() => _session = refreshed);
    }
  }

  /// Swipe from Studio -> Capture (page 1).
  void _goToCapture() {
    _pageController.animateToPage(
      1,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  /// Swipe from Capture -> Studio (page 0).
  void _goToStudio() {
    _pageController.animateToPage(
      0,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    // PopScope with canPop:false disables iOS's edge-swipe-to-pop gesture at
    // the route level. Without this, swiping right while on the Capture page
    // (index 1) races the shell's PageView: iOS wins at the screen edge and
    // pops the whole shell back to Home instead of paging to Studio.
    //
    // The Exit button in Capture mode's top corner still works — it calls
    // Navigator.of(context).pop() explicitly, which bypasses canPop.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        // Intentionally empty: we swallow implicit pop attempts (iOS edge
        // swipe, Android back gesture) so the PageView owns horizontal nav.
        // Explicit Navigator.pop() from the Exit button still routes home.
      },
      child: Scaffold(
        backgroundColor: AppColors.darkBg,
        // Allow camera mode to draw behind safe areas; each mode handles its
        // own SafeArea where needed.
        body: PageView(
          controller: _pageController,
          onPageChanged: (_) {},
          physics: const ClampingScrollPhysics(),
          children: [
            StudioModeScreen(
              session: _session,
              storage: widget.storage,
              onSessionChanged: (s) => setState(() => _session = s),
              onOpenCapture: _goToCapture,
            ),
            CaptureModeScreen(
              session: _session,
              storage: widget.storage,
              onCapturesChanged: _refreshSession,
              onExitToStudio: _goToStudio,
            ),
          ],
        ),
      ),
    );
  }
}
