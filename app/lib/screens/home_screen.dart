import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import '../models/exercise_capture.dart';
import '../models/session.dart';
import '../services/auth_service.dart';
import '../services/local_storage_service.dart';
import '../services/upload_service.dart';
import '../theme.dart';
import '../widgets/powered_by_footer.dart';
import 'session_capture_screen.dart'; // retained as fallback, see _useShell below
import 'session_shell_screen.dart';

/// Landing screen — the first thing the bio sees.
///
/// Shows a prominent "New Session" button and a list of recent unsent
/// sessions. Tapping a recent session goes to the plan editor so the
/// bio can pick up where she left off.
class HomeScreen extends StatefulWidget {
  final LocalStorageService storage;

  const HomeScreen({super.key, required this.storage});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Session> _sessions = [];
  bool _loading = true;
  late UploadService _uploadService;
  /// Set of session IDs currently being published.
  final Set<String> _publishingIds = {};
  /// Per-session last publish error, keyed by session id. Populated by
  /// [_loadSessions] via the UploadService adapter (schema v11
  /// `last_publish_error` column). Empty when schema v11 hasn't landed yet —
  /// that's fine, the UI just shows no error affordance.
  final Map<String, String> _publishErrors = {};

  /// Truncated error string when [_loadSessions] fails to read from SQLite.
  /// When non-null, [build] swaps the session list for an error card with a
  /// "Try again" button that calls [_loadSessions] again.
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _uploadService = UploadService(storage: widget.storage);
    _loadSessions();
  }

  Future<void> _loadSessions() async {
    // Clear any previous error on entry so the "Try again" button can
    // surface the spinner again instead of flashing the error card until
    // setState lands.
    if (_loadError != null || !_loading) {
      setState(() {
        _loadError = null;
        _loading = true;
      });
    }

    try {
      final sessions = await widget.storage.getActiveSessions();
      // Fetch publish errors in parallel — skipped silently if schema v11 is
      // not yet applied.
      final errorEntries = await Future.wait(
        sessions.map((s) async {
          final err = await _uploadService.getLastPublishError(s.id);
          return MapEntry(s.id, err);
        }),
      );
      if (!mounted) return;
      setState(() {
        _sessions = sessions;
        _publishErrors
          ..clear()
          ..addEntries(
            errorEntries.where((e) => e.value != null).map(
                  (e) => MapEntry(e.key, e.value!),
                ),
          );
        _loading = false;
        _loadError = null;
      });
    } catch (e) {
      // SQLite open / migration / corruption can leave the user on an
      // indefinite spinner. Surface the error with a retry affordance
      // instead. Truncate to 200 chars so the error card doesn't explode
      // to multi-viewport height on a noisy stack trace.
      final text = e.toString();
      final truncated = text.substring(0, min(200, text.length));
      if (!mounted) return;
      setState(() {
        _sessions = [];
        _publishErrors.clear();
        _loading = false;
        _loadError = truncated;
      });
    }
  }

  /// Toggle: true = new SessionShellScreen flow, false = legacy
  /// SessionCaptureScreen. Flip to false to roll back the Camera/Studio split.
  static const bool _useShell = true;

  /// Create a session immediately with a default date-time name and navigate.
  Future<void> _startNewSession() async {
    final now = DateTime.now();
    final defaultName = _formatSessionName(now);

    final session = Session.create(clientName: defaultName);
    await widget.storage.saveSession(session);

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _useShell
            ? SessionShellScreen(
                session: session,
                storage: widget.storage,
                // New session: bio wants the camera first.
                initialPage: 1,
              )
            : SessionCaptureScreen(
                session: session,
                storage: widget.storage,
              ),
      ),
    );

    // Refresh the list when returning from capture
    _loadSessions();
  }

  /// Format a DateTime as "16 Apr 2026 18:30".
  static String _formatSessionName(DateTime dt) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final day = dt.day;
    final month = months[dt.month - 1];
    final year = dt.year;
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    return '$day $month $year $hour:$minute';
  }

  /// Navigate to the session screen for an existing session.
  Future<void> _openSession(Session session) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _useShell
            ? SessionShellScreen(
                session: session,
                storage: widget.storage,
                // Existing session: land on Studio to edit.
                initialPage: 0,
              )
            : SessionCaptureScreen(
                session: session,
                storage: widget.storage,
              ),
      ),
    );

    // Refresh in case the session was sent or deleted
    _loadSessions();
  }

  /// Soft-delete a session and show an undo SnackBar.
  Future<void> _deleteSession(Session session) async {
    await widget.storage.softDeleteSession(session.id);
    _loadSessions();

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${session.clientName} deleted'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () async {
            await widget.storage.restoreSession(session.id);
            _loadSessions();
          },
        ),
      ),
    );
  }

  /// Publish a session to Supabase.
  Future<void> _publishSession(Session session) async {
    // Check for pending conversions
    final hasConversionsRunning = session.exercises.any((e) =>
        !e.isRest &&
        (e.conversionStatus == ConversionStatus.pending ||
         e.conversionStatus == ConversionStatus.converting));
    if (hasConversionsRunning) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Wait for conversions to finish before publishing'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }

    setState(() => _publishingIds.add(session.id));

    PublishResult? result;
    try {
      // Load the full session with exercises from storage
      final fullSession = await widget.storage.getSession(session.id);
      if (fullSession == null) return;

      result = await _uploadService.uploadPlan(fullSession);
    } catch (e) {
      // Defensive: uploadPlan now catches its own errors and returns a
      // PublishResult, but guard against programming errors here too.
      result = PublishResult.networkFailed(error: e);
    } finally {
      if (mounted) {
        setState(() => _publishingIds.remove(session.id));
        // Reload so the card reflects new version / lastPublishError.
        await _loadSessions();
      }
    }

    if (!mounted) return;

    if (result.success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Published v${result.version}'),
          duration: const Duration(seconds: 2),
        ),
      );
    } else {
      _showPublishErrorSnackBar(session, result.toErrorString());
    }
  }

  /// Show a SnackBar for a failed publish with a Retry action.
  void _showPublishErrorSnackBar(Session session, String error) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            'Publish failed: $error',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          duration: const Duration(seconds: 6),
          backgroundColor: AppColors.error,
          action: SnackBarAction(
            label: 'Retry',
            textColor: Colors.white,
            onPressed: () => _publishSession(session),
          ),
        ),
      );
  }

  /// Copy the plan URL to the clipboard and show a confirmation snackbar.
  Future<void> _copyLink(Session session) async {
    final url = session.planUrl;
    if (url == null) return;
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Link copied'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  /// Open the share sheet with the session's plan URL.
  Future<void> _shareSession(Session session) async {
    final url = session.planUrl;
    if (url == null) return;

    try {
      final box = context.findRenderObject() as RenderBox?;
      // Share only the URL so WhatsApp/Messages unfurl it into a clean
      // link preview instead of posting the URL-plus-preamble as plain text.
      await Share.share(
        url,
        sharePositionOrigin: box != null
            ? box.localToGlobal(Offset.zero) & box.size
            : const Rect.fromLTWH(0, 0, 100, 100),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Share failed: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surfaceBg,
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : (_loadError != null
                ? _buildLoadErrorCard(_loadError!)
                : _buildBody()),
      ),
    );
  }

  /// Coral-tinted error card shown when [_loadSessions] fails (typically
  /// SQLite open / migration / corruption). Match the brand's existing
  /// banner / card treatment — dark surface, coral accent, one button.
  Widget _buildLoadErrorCard(String error) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 480),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: AppColors.surfaceBase,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.surfaceBorder, width: 1),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.error_outline_rounded,
                    color: AppColors.primary,
                    size: 28,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          "Couldn't load your sessions.",
                          style: TextStyle(
                            fontFamily: 'Montserrat',
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textOnDark,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          error,
                          style: const TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 13,
                            color: AppColors.textSecondaryOnDark,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: _loadSessions,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                    ),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 12),
                    textStyle: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  child: const Text('Try again'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    // --- Inverted layout (matches studio_mode_screen, commit da58948) ---
    // Newest session anchors at the BOTTOM of the viewport — thumb reach.
    // New Session button sits just above the footer; tapping it is a
    // one-handed gesture near the bottom of the screen. Older sessions
    // scroll upward.
    //
    // Same reverse-iteration pattern as Studio:
    //   ListView(reverse: true) + itemBuilder that maps visualIndex ->
    //   dataIndex = len - 1 - visualIndex. Data stays ascending; only the
    //   UI translates. Swipe-to-delete and tap-to-open work on the
    //   translated dataIndex so semantics are unchanged.
    return Column(
      children: [
        // Minimal top bar — just the account affordance. No AppBar widget,
        // since the brand-design session is about to reshape this screen
        // and we don't want to bake in a title / chrome that's about to
        // change. The icon sits flush right so the full-screen session
        // list still feels airy.
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
          child: Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              onPressed: _openAccountSheet,
              icon: const Icon(
                Icons.account_circle_outlined,
                color: AppColors.textOnDark,
                size: 26,
              ),
              tooltip: 'Account',
            ),
          ),
        ),

        const SizedBox(height: 8),

        // Recent sessions header (kept as a minimal top anchor).
        if (_sessions.isNotEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 24),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Recent Sessions',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textSecondaryOnDark,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),

        const SizedBox(height: 8),

        // Bottom-anchored session list.
        Expanded(
          child: _sessions.isEmpty
              ? _buildEmptyState()
              : ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _sessions.length,
                  itemBuilder: (context, visualIndex) {
                    final dataIndex =
                        _sessions.length - 1 - visualIndex;
                    return _buildSessionCard(_sessions[dataIndex]);
                  },
                ),
        ),

        // "New Session" button — pinned just above the footer so it sits
        // in the thumb zone.
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
          child: SizedBox(
            width: double.infinity,
            height: 56,
            child: FilledButton.icon(
              onPressed: _startNewSession,
              icon: const Icon(Icons.add_a_photo_outlined, size: 24),
              label: const Text(
                'New Session',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
          ),
        ),

        const PoweredByFooter(),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Account / sign-out
  // ---------------------------------------------------------------------------

  /// Open a bottom sheet with account actions. Currently just a "Sign out"
  /// row; expands naturally when we add practice-switcher, profile, etc.
  /// Keeping it as a sheet (not a new screen) avoids committing to chrome
  /// that's about to be reshaped by the brand-design session.
  Future<void> _openAccountSheet() async {
    HapticFeedback.selectionClick();
    final user = AuthService.instance.currentSession?.user;
    final email = user?.email;

    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surfaceBase,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Drag handle affordance.
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceBorder,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                if (email != null) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
                    child: Text(
                      email,
                      style: const TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 13,
                        color: AppColors.textSecondaryOnDark,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
                FilledButton.icon(
                  onPressed: () async {
                    Navigator.of(sheetCtx).pop();
                    await _confirmAndSignOut();
                  },
                  icon: const Icon(Icons.logout, size: 20),
                  label: const Text('Sign out'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                    ),
                    textStyle: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Confirm and sign out. The AuthGate listens to Supabase auth state and
  /// swaps the tree back to SignInScreen once the session is cleared — no
  /// manual Navigator push needed here.
  Future<void> _confirmAndSignOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: AppColors.surfaceBase,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        ),
        title: const Text(
          'Sign out of homefit.studio?',
          style: TextStyle(
            fontFamily: 'Montserrat',
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: AppColors.textOnDark,
          ),
        ),
        content: const Text(
          "You'll need to sign in again to see your sessions.",
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 14,
            color: AppColors.textSecondaryOnDark,
            height: 1.4,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: AppColors.textSecondaryOnDark),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
            ),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await AuthService.instance.signOut();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Sign out failed: $e'),
          backgroundColor: AppColors.error,
        ),
      );
    }
    // No navigation here — AuthGate observes the session change and swaps
    // to SignInScreen automatically. Any in-memory state on this screen is
    // discarded when the HomeScreen widget is disposed.
  }

  Widget _buildEmptyState() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.fitness_center_outlined, size: 64, color: AppColors.grey600),
          SizedBox(height: 16),
          Text(
            'No sessions yet',
            style: TextStyle(fontSize: 16, color: AppColors.textSecondaryOnDark),
          ),
          SizedBox(height: 4),
          Text(
            'Tap New Session to get started',
            style: TextStyle(fontSize: 14, color: AppColors.grey600),
          ),
        ],
      ),
    );
  }

  /// Short publish-status label for the session card.
  static String _publishLabel(Session session) {
    if (session.version == 0) return 'Draft';
    final v = 'Published v${session.version}';
    final dt = session.lastPublishedAt;
    if (dt == null) return v;
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final date = '${dt.day} ${months[dt.month - 1]}';
    return '$v · $date';
  }

  Widget _buildSessionCard(Session session) {
    final exerciseCount = session.exercises.length;
    final pending = session.pendingConversions;
    final isPublishing = _publishingIds.contains(session.id);

    // Determine publish/share button states
    final hasConversionsRunning = session.exercises.any((e) =>
        !e.isRest &&
        (e.conversionStatus == ConversionStatus.pending ||
         e.conversionStatus == ConversionStatus.converting));
    final hasExercises = session.exercises.where((e) => !e.isRest).isNotEmpty;
    final canPublish = hasExercises && !hasConversionsRunning && !isPublishing;
    final isPublishedClean = session.isPublished && !_hasUnpublishedChanges(session);
    final lastError = _publishErrors[session.id];
    final hasPublishError = lastError != null && !isPublishing;

    return Dismissible(
      key: ValueKey(session.id),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) async => true,
      onDismissed: (_) => _deleteSession(session),
      background: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(
          color: AppColors.error,
          borderRadius: BorderRadius.circular(12),
        ),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        child: const Icon(Icons.delete_outline, color: Colors.white, size: 28),
      ),
      child: Card(
        elevation: 0,
        color: AppColors.surfaceBase,
        margin: const EdgeInsets.symmetric(vertical: 4),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: AppColors.surfaceBorder, width: 1),
        ),
        child: InkWell(
          onTap: () => _openSession(session),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                // Left: session info
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        session.clientName,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          color: AppColors.textOnDark,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: '$exerciseCount exercise${exerciseCount == 1 ? '' : 's'}'
                                  '${pending > 0 ? ' ($pending converting...)' : ''}',
                            ),
                            TextSpan(
                              text: ' \u00b7 ${_publishLabel(session)}',
                              style: TextStyle(
                                color: session.version > 0
                                    ? AppColors.circuit
                                    : AppColors.grey500,
                              ),
                            ),
                          ],
                        ),
                        style: const TextStyle(color: AppColors.textSecondaryOnDark, fontSize: 13),
                      ),
                    ],
                  ),
                ),

                // Right: Publish + Share + chevron
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Publish button
                    if (isPublishing)
                      const SizedBox(
                        width: 34,
                        height: 34,
                        child: Padding(
                          padding: EdgeInsets.all(7),
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColors.grey500,
                          ),
                        ),
                      )
                    else
                      SizedBox(
                        width: 34,
                        height: 34,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            IconButton(
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              iconSize: 20,
                              onPressed: canPublish
                                  ? () => _publishSession(session)
                                  : (hasPublishError
                                      // Publish button disabled (e.g. no
                                      // exercises) but we still have an error
                                      // to surface — let the tap show it.
                                      ? () => _showPublishErrorSnackBar(
                                          session, lastError)
                                      : null),
                              icon: Icon(
                                hasPublishError
                                    ? Icons.cloud_off_outlined
                                    : isPublishedClean
                                        ? Icons.check_circle
                                        : Icons.cloud_upload_outlined,
                                color: hasPublishError
                                    ? AppColors.error
                                    : isPublishedClean
                                        ? AppColors.circuit
                                        : canPublish
                                            ? AppColors.textOnDark
                                            : AppColors.grey600,
                                size: 20,
                              ),
                              tooltip: hasPublishError
                                  ? 'Publish failed — tap for details'
                                  : isPublishedClean
                                      ? 'Published'
                                      : 'Publish',
                            ),
                            if (hasPublishError)
                              Positioned(
                                top: 2,
                                right: 2,
                                child: Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: AppColors.error,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: AppColors.surfaceBase,
                                      width: 1,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),

                    // Copy link button
                    SizedBox(
                      width: 34,
                      height: 34,
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        iconSize: 20,
                        onPressed: session.isPublished
                            ? () => _copyLink(session)
                            : null,
                        icon: Icon(
                          Icons.link,
                          color: session.isPublished
                              ? AppColors.textOnDark
                              : AppColors.grey600,
                          size: 20,
                        ),
                        tooltip: 'Copy link',
                      ),
                    ),

                    // Share button
                    SizedBox(
                      width: 34,
                      height: 34,
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        iconSize: 20,
                        onPressed: session.isPublished
                            ? () => _shareSession(session)
                            : null,
                        icon: Icon(
                          Icons.ios_share,
                          color: session.isPublished
                              ? AppColors.textOnDark
                              : AppColors.grey600,
                          size: 20,
                        ),
                        tooltip: 'Share',
                      ),
                    ),

                    const SizedBox(width: 4),
                    const Icon(Icons.chevron_right, color: AppColors.grey500, size: 22),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Check whether a session has changes since last publish.
  ///
  /// Simple heuristic: compare exercise modification times against
  /// lastPublishedAt. Since we don't track per-exercise modification
  /// timestamps in the card view, we just check if it's published.
  bool _hasUnpublishedChanges(Session session) {
    // Not published yet — not "clean"
    if (!session.isPublished) return true;
    // For now, once published and not actively changed in this view,
    // consider it clean. The session screen no longer tracks dirty state,
    // so any re-publish from home is intentional.
    return false;
  }

}
