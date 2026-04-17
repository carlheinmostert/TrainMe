import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import '../models/exercise_capture.dart';
import '../models/session.dart';
import '../services/local_storage_service.dart';
import '../services/upload_service.dart';
import '../theme.dart';
import '../widgets/powered_by_footer.dart';
import 'session_capture_screen.dart';

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

  @override
  void initState() {
    super.initState();
    _uploadService = UploadService(storage: widget.storage);
    _loadSessions();
  }

  Future<void> _loadSessions() async {
    final sessions = await widget.storage.getActiveSessions();
    setState(() {
      _sessions = sessions;
      _loading = false;
    });
  }

  /// Create a session immediately with a default date-time name and navigate.
  Future<void> _startNewSession() async {
    final now = DateTime.now();
    final defaultName = _formatSessionName(now);

    final session = Session.create(clientName: defaultName);
    await widget.storage.saveSession(session);

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SessionCaptureScreen(
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
        builder: (_) => SessionCaptureScreen(
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

    try {
      // Load the full session with exercises from storage
      final fullSession = await widget.storage.getSession(session.id);
      if (fullSession == null) return;

      final result = await _uploadService.uploadPlan(fullSession);

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Published v${result.version}'),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Publish failed: $e'),
          duration: const Duration(seconds: 4),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _publishingIds.remove(session.id));
        _loadSessions();
      }
    }
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

    final text = '${session.displayTitle}\n\n'
        '${session.exercises.where((e) => !e.isRest).length} exercises ready for you:\n'
        '$url';
    try {
      final box = context.findRenderObject() as RenderBox?;
      await Share.share(
        text,
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
      backgroundColor: AppColors.darkBg,
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    return Column(
      children: [
        const SizedBox(height: 32),

        // Prominent "New Session" button
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
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

        const SizedBox(height: 32),

        // Recent sessions header
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

        // Session list
        Expanded(
          child: _sessions.isEmpty
              ? _buildEmptyState()
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _sessions.length,
                  itemBuilder: (context, index) =>
                      _buildSessionCard(_sessions[index]),
                ),
        ),

        // Powered by homefit.studio footer
        const PoweredByFooter(),
      ],
    );
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
        color: AppColors.darkSurface,
        margin: const EdgeInsets.symmetric(vertical: 4),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: AppColors.darkBorder, width: 1),
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
                        child: IconButton(
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          iconSize: 20,
                          onPressed: canPublish
                              ? () => _publishSession(session)
                              : null,
                          icon: Icon(
                            isPublishedClean
                                ? Icons.check_circle
                                : Icons.cloud_upload_outlined,
                            color: isPublishedClean
                                ? AppColors.circuit
                                : canPublish
                                    ? AppColors.textOnDark
                                    : AppColors.grey600,
                            size: 20,
                          ),
                          tooltip: isPublishedClean ? 'Published' : 'Publish',
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
