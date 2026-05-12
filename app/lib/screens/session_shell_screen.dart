import 'dart:async';

import 'package:flutter/material.dart';
import '../config.dart';
import '../models/session.dart';
import '../services/api_client.dart';
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
/// Replaces the legacy single-screen capture UX (previously
/// `session_capture_screen.dart`, removed in the dead-code cleanup).
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

  /// Tracks the current page as the user swipes so `PopScope.canPop`
  /// updates in real time. Studio = 0 (pop exits to ClientSessions);
  /// Camera = 1 (pop routes back to Studio instead of exiting the shell).
  /// Seed from `initialPage` so the very first build doesn't briefly
  /// claim canPop:true on Camera.
  late int _currentPage;

  @override
  void initState() {
    super.initState();
    _session = widget.session;
    _currentPage = widget.initialPage;
    _pageController = PageController(initialPage: widget.initialPage);
    // Keep `_currentPage` in sync with controller offset during swipes
    // so canPop flips the moment the page crosses the midpoint. Without
    // this, a slow swipe from Camera → Studio wouldn't update canPop
    // until `onPageChanged` fired (after the snap settled).
    _pageController.addListener(_handlePageScroll);
    // If a previous publish crashed between cloud commit and the local
    // `saveSession(updated)` write (e.g. the conversion-queue wedge
    // triage before 23950b0 forced kill-and-restart), the local row is
    // missing planUrl/version/sentAt while Supabase has the plan
    // published. Studio then renders the share button as dim. Reconcile
    // here so the bio gets their share link back without re-publishing.
    unawaited(_reconcileWithCloudIfUnpublished());
  }

  void _handlePageScroll() {
    if (!_pageController.hasClients) return;
    final page = _pageController.page;
    if (page == null) return;
    // Round to nearest page so canPop is binary — avoids re-rendering
    // every animation frame.
    final nearest = page.round();
    if (nearest != _currentPage) {
      setState(() => _currentPage = nearest);
    }
  }

  Future<void> _reconcileWithCloudIfUnpublished() async {
    // Wave 29 follow-up: ALSO runs on already-published sessions so we
    // can pull `first_opened_at` + `unlock_credit_prepaid_at` from cloud
    // (they don't flow through any other path). The publish-state heal
    // only applies when local thinks it's unpublished but cloud has a
    // version — the lock-state heal applies always.
    try {
      final cloud = await ApiClient.instance.getPlanPublishState(_session.id);
      if (cloud == null || !mounted) return;

      Session updated = _session;
      bool changed = false;

      // Publish-state heal (only when local was unpublished).
      if (!_session.isPublished) {
        final rawVersion = cloud['version'];
        final cloudVersion = rawVersion is int
            ? rawVersion
            : (rawVersion is num ? rawVersion.toInt() : 0);
        final sentAtStr = cloud['sent_at'];
        if (cloudVersion > 0 && sentAtStr is String && sentAtStr.isNotEmpty) {
          final cloudSentAt = DateTime.tryParse(sentAtStr);
          if (cloudSentAt != null) {
            final planUrl = '${AppConfig.webPlayerBaseUrl}/p/${_session.id}';
            updated = updated.copyWith(
              version: cloudVersion,
              planUrl: planUrl,
              sentAt: cloudSentAt,
              lastPublishedAt: cloudSentAt,
            );
            changed = true;
          }
        }
      }

      // Lock-state + analytics heal — always.
      // Wave 33 — also pull `last_opened_at` so the Studio analytics row
      // ("First opened {date} · Last opened {date}") reads from the same
      // local mirror as the lock state. The lock policy itself keys
      // off firstOpenedAt + 14d; lastOpenedAt is purely UX signal.
      DateTime? parseTs(dynamic v) =>
          v is String && v.isNotEmpty ? DateTime.tryParse(v) : null;
      final cloudFirstOpened = parseTs(cloud['first_opened_at']);
      final cloudLastOpened = parseTs(cloud['last_opened_at']);
      final cloudPrepaid = parseTs(cloud['unlock_credit_prepaid_at']);
      if (cloudFirstOpened != updated.firstOpenedAt ||
          cloudLastOpened != updated.lastOpenedAt ||
          cloudPrepaid != updated.unlockCreditPrepaidAt) {
        updated = updated.copyWith(
          firstOpenedAt: cloudFirstOpened,
          lastOpenedAt: cloudLastOpened,
          unlockCreditPrepaidAt: cloudPrepaid,
          clearFirstOpenedAt: cloudFirstOpened == null,
          clearLastOpenedAt: cloudLastOpened == null,
          clearUnlockCreditPrepaidAt: cloudPrepaid == null,
        );
        changed = true;
      }

      if (!changed) return;
      await widget.storage.saveSession(updated);
      if (!mounted) return;
      setState(() => _session = updated);
    } catch (e) {
      debugPrint('SessionShell reconcile failed: $e');
    }
  }

  @override
  void dispose() {
    _pageController.removeListener(_handlePageScroll);
    _pageController.dispose();
    super.dispose();
  }

  /// Refresh the session from storage — called after either mode mutates it.
  ///
  /// Wave 40.5 — guard against regressing conversion state. StudioModeScreen's
  /// conversion listener applies `done` events synchronously via
  /// `onSessionChanged`, pushing a fresher session to `_session`. This
  /// async SQLite read can resolve AFTER that push and would overwrite
  /// the shell's `_session` with a stale version (still `pending` or
  /// `converting`). Adopt the SQLite version only when it's not stale
  /// — same logic as StudioModeScreen's `_shouldAdoptParentSession`.
  Future<void> _refreshSession() async {
    final refreshed = await widget.storage.getSession(_session.id);
    if (refreshed != null && mounted) {
      // Always push to Studio — Studio's _mergeConversionState handles
      // freshness per-exercise. The _shouldAdoptRefreshed guard was
      // swallowing pushes that carried new exercises, preventing Studio
      // from ever seeing the last photo.
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
    // iOS edge-swipe-to-pop is page-aware:
    //   - On Studio (page 0): canPop=true → edge-swipe + Studio AppBar
    //     back chevron pop the shell to ClientSessions (preserves the
    //     PR #281 hotfix that gave Studio a way out).
    //   - On Camera (page 1): canPop=false → edge-swipe is intercepted
    //     in `onPopInvokedWithResult` and routed via PageController to
    //     swipe back to Studio. This fixes the regression introduced
    //     when PR #281 dropped the blanket `PopScope(canPop: false)`
    //     wrapper — previously the whole shell was un-poppable, which
    //     trapped Studio (the bug PR #281 fixed) AND happened to keep
    //     Camera's edge-swipe inert. Now we keep Studio poppable while
    //     re-protecting Camera.
    return PopScope(
      canPop: _currentPage == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // We're on Camera (page > 0) and the user tried to pop —
        // route back to Studio instead of exiting the shell.
        if (_pageController.hasClients) {
          _goToStudio();
        }
      },
      child: Scaffold(
        backgroundColor: AppColors.surfaceBg,
        // Allow camera mode to draw behind safe areas; each mode handles its
        // own SafeArea where needed.
        body: PageView(
          controller: _pageController,
          onPageChanged: (page) {
            // When the bio swipes between Studio and Camera, kill any
            // in-flight delete-undo banner / snackbar. Otherwise it can
            // persist across modes and occlude the camera shutter.
            final messenger = ScaffoldMessenger.of(context);
            messenger.hideCurrentMaterialBanner();
            messenger.clearSnackBars();
            // Belt-and-braces: the scroll listener should already have
            // synced `_currentPage`, but make sure canPop is correct
            // once the snap settles.
            if (page != _currentPage) {
              setState(() => _currentPage = page);
            }
          },
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
