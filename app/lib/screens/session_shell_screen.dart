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

  @override
  void initState() {
    super.initState();
    _session = widget.session;
    _pageController = PageController(initialPage: widget.initialPage);
    // If a previous publish crashed between cloud commit and the local
    // `saveSession(updated)` write (e.g. the conversion-queue wedge
    // triage before 23950b0 forced kill-and-restart), the local row is
    // missing planUrl/version/sentAt while Supabase has the plan
    // published. Studio then renders the share button as dim. Reconcile
    // here so the bio gets their share link back without re-publishing.
    unawaited(_reconcileWithCloudIfUnpublished());
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

      // Lock-state heal — always.
      DateTime? parseTs(dynamic v) =>
          v is String && v.isNotEmpty ? DateTime.tryParse(v) : null;
      final cloudFirstOpened = parseTs(cloud['first_opened_at']);
      final cloudPrepaid = parseTs(cloud['unlock_credit_prepaid_at']);
      if (cloudFirstOpened != updated.firstOpenedAt ||
          cloudPrepaid != updated.unlockCreditPrepaidAt) {
        updated = updated.copyWith(
          firstOpenedAt: cloudFirstOpened,
          unlockCreditPrepaidAt: cloudPrepaid,
          clearFirstOpenedAt: cloudFirstOpened == null,
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
        backgroundColor: AppColors.surfaceBg,
        // Allow camera mode to draw behind safe areas; each mode handles its
        // own SafeArea where needed.
        body: PageView(
          controller: _pageController,
          onPageChanged: (_) {
            // When the bio swipes between Studio and Camera, kill any
            // in-flight delete-undo banner / snackbar. Otherwise it can
            // persist across modes and occlude the camera shutter.
            final messenger = ScaffoldMessenger.of(context);
            messenger.hideCurrentMaterialBanner();
            messenger.clearSnackBars();
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
