import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../models/client.dart';
import '../models/exercise_capture.dart';
import '../models/session.dart';
import '../services/auth_service.dart';
import '../services/local_storage_service.dart';
import '../services/sync_service.dart';
import '../services/upload_service.dart';
import '../theme.dart';
import '../utils/session_title.dart';
import '../widgets/client_consent_sheet.dart';
import '../widgets/powered_by_footer.dart';
import '../widgets/session_card.dart';
import 'session_shell_screen.dart';

/// One client's page. Lists every local session that belongs to this
/// client and exposes "New Session" as the primary CTA.
///
/// The list filter accepts both new-flow sessions (linked by `client_id`)
/// and legacy sessions that predate the Clients-as-Home-spine IA shift
/// (linked by `clientName == client.name`). This fallback means we
/// didn't need a SQLite backfill when adding `client_id` in schema v16.
///
/// Design rules:
///  - R-01: delete fires immediately + Undo SnackBar (SessionCard owns
///    the swipe-to-delete affordance).
///  - R-02: app-bar is back-arrow + "Clients" label + nothing else.
///    All actions live in the body or the FAB.
///  - R-06: copy uses "practitioner"; peer-to-peer voice; no
///    "consent"/"legal"/"POPIA" in user-visible strings.
///  - R-09: FAB "New Session" is always visible when the practitioner
///    has a signed-in practice; the edit-client-name affordance is a
///    dashed underline, matching the portal pattern.
///  - R-11: this IS the mobile twin of the portal's `/clients/[id]`.
class ClientSessionsScreen extends StatefulWidget {
  final PracticeClient client;
  final LocalStorageService storage;

  const ClientSessionsScreen({
    super.key,
    required this.client,
    required this.storage,
  });

  @override
  State<ClientSessionsScreen> createState() => _ClientSessionsScreenState();
}

class _ClientSessionsScreenState extends State<ClientSessionsScreen> {
  late PracticeClient _client;
  late UploadService _uploadService;

  List<Session> _sessions = const [];
  bool _loading = true;
  String? _loadError;

  /// Sessions currently being published (spinner in-card).
  final Set<String> _publishingIds = <String>{};

  /// Last known publish error per session id. Null-stripped on reload.
  final Map<String, String> _publishErrors = <String, String>{};

  /// True while a rename RPC is in-flight. Disables the save path so
  /// double-taps don't produce duplicate calls.
  bool _renameSaving = false;

  /// True when the inline edit-client-name input is active.
  bool _editingName = false;
  late TextEditingController _nameController;
  final FocusNode _nameFocusNode = FocusNode();
  String? _renameError;

  @override
  void initState() {
    super.initState();
    _client = widget.client;
    _uploadService = UploadService(storage: widget.storage);
    _nameController = TextEditingController(text: _client.name);
    _loadSessions();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _nameFocusNode.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Data
  // ---------------------------------------------------------------------------

  Future<void> _loadSessions() async {
    if (_loadError != null || !_loading) {
      setState(() {
        _loadError = null;
        _loading = true;
      });
    }

    try {
      final userId = AuthService.instance.currentUserId;
      if (userId != null) {
        await widget.storage.claimOrphanSessions(userId);
      }
      final all = await widget.storage.getSessionsForUser(userId);
      final filtered = all
          .where((s) =>
              s.clientId == _client.id ||
              (s.clientId == null && s.clientName == _client.name))
          .toList(growable: false);

      // Fetch publish errors in parallel, skipped silently if schema
      // doesn't carry the column yet.
      final errorEntries = await Future.wait(
        filtered.map((s) async {
          final err = await _uploadService.getLastPublishError(s.id);
          return MapEntry(s.id, err);
        }),
      );

      if (!mounted) return;
      setState(() {
        _sessions = filtered;
        _publishErrors
          ..clear()
          ..addEntries(
            errorEntries
                .where((e) => e.value != null)
                .map((e) => MapEntry(e.key, e.value!)),
          );
        _loading = false;
        _loadError = null;
      });
    } catch (e) {
      final text = e.toString();
      final truncated = text.substring(0, min(200, text.length));
      if (!mounted) return;
      setState(() {
        _sessions = const [];
        _publishErrors.clear();
        _loading = false;
        _loadError = truncated;
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Actions — sessions
  // ---------------------------------------------------------------------------

  Future<void> _startNewSession() async {
    HapticFeedback.selectionClick();
    final now = DateTime.now();
    final title = formatSessionTitle(_client.name, now);
    final session = Session.create(
      clientName: _client.name,
      clientId: _client.id,
      title: title,
    );
    await widget.storage.saveSession(session);

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SessionShellScreen(
          session: session,
          storage: widget.storage,
          initialPage: 1, // Camera first.
        ),
      ),
    );
    _loadSessions();
  }

  Future<void> _openSession(Session session) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SessionShellScreen(
          session: session,
          storage: widget.storage,
          initialPage: 0, // Studio for existing sessions.
        ),
      ),
    );
    _loadSessions();
  }

  Future<void> _deleteSession(Session session) async {
    await widget.storage.softDeleteSession(session.id);
    _loadSessions();

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${_sessionDisplayName(session)} deleted'),
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

  Future<void> _publishSession(Session session) async {
    final hasConversionsRunning = session.exercises.any((e) =>
        !e.isRest &&
        (e.conversionStatus == ConversionStatus.pending ||
            e.conversionStatus == ConversionStatus.converting));
    if (hasConversionsRunning) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content:
                Text('Wait for conversions to finish before publishing'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }

    setState(() => _publishingIds.add(session.id));

    PublishResult? result;
    try {
      final fullSession = await widget.storage.getSession(session.id);
      if (fullSession == null) return;
      result = await _uploadService.uploadPlan(fullSession);
    } catch (e) {
      result = PublishResult.networkFailed(error: e);
    } finally {
      if (mounted) {
        setState(() => _publishingIds.remove(session.id));
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

  void _showPublishErrorSnackBar(Session session, String error) {
    final fullText = 'Publish failed: $error';
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () async {
              await Clipboard.setData(ClipboardData(text: fullText));
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Error copied'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
            child: Text(
              fullText,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          duration: const Duration(seconds: 12),
          backgroundColor: AppColors.error,
          action: SnackBarAction(
            label: 'Retry',
            textColor: Colors.white,
            onPressed: () => _publishSession(session),
          ),
        ),
      );
  }

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

  Future<void> _shareSession(Session session) async {
    final url = session.planUrl;
    if (url == null) return;
    try {
      final box = context.findRenderObject() as RenderBox?;
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

  // ---------------------------------------------------------------------------
  // Actions — client
  // ---------------------------------------------------------------------------

  Future<void> _openConsent() async {
    HapticFeedback.selectionClick();
    final updated =
        await showClientConsentSheet(context, client: _client);
    if (updated != null && mounted) {
      setState(() => _client = updated);
    }
  }

  void _startEditingName() {
    setState(() {
      _editingName = true;
      _renameError = null;
      _nameController.text = _client.name;
    });
    // Focus + select-all next frame so the full name clobbers easily.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _nameFocusNode.requestFocus();
      _nameController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _nameController.text.length,
      );
    });
  }

  void _cancelEditingName() {
    setState(() {
      _editingName = false;
      _renameError = null;
      _nameController.text = _client.name;
    });
  }

  Future<void> _commitEditingName() async {
    if (_renameSaving) return;
    final trimmed = _nameController.text.trim();
    if (trimmed == _client.name) {
      setState(() {
        _editingName = false;
        _renameError = null;
      });
      return;
    }
    if (trimmed.isEmpty) {
      setState(() => _renameError = "Name can't be empty.");
      return;
    }

    setState(() {
      _renameSaving = true;
      _renameError = null;
    });

    // Offline-first: queue the rename. Local state updates immediately
    // + the UI flips out of edit mode; the cloud push happens in the
    // background (or the next time we reconnect). Duplicate-name
    // errors are caught at the SQLite UNIQUE constraint level via the
    // thrown exception — unwrap it so the inline error copy matches
    // the online path.
    try {
      final updated = await SyncService.instance.queueRenameClient(
        clientId: _client.id,
        newName: trimmed,
      );
      if (!mounted) return;
      if (updated == null) {
        setState(() {
          _renameSaving = false;
          _renameError = 'Client not found. Try refreshing.';
        });
        return;
      }
      setState(() {
        _client = _client.copyWith(name: trimmed);
        _renameSaving = false;
        _editingName = false;
        _renameError = null;
      });
      HapticFeedback.selectionClick();
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString();
      final isDuplicate =
          msg.contains('UNIQUE') || msg.contains('unique') || msg.contains('2067');
      setState(() {
        _renameSaving = false;
        _renameError = isDuplicate
            ? 'Another client in this practice already uses that name.'
            : "Couldn't rename — try again.";
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surfaceBg,
      appBar: AppBar(
        backgroundColor: AppColors.surfaceBg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        iconTheme: const IconThemeData(color: AppColors.textOnDark),
        title: const Text(
          'Clients',
          style: TextStyle(
            fontFamily: 'Montserrat',
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: AppColors.textOnDark,
          ),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(
                          color: AppColors.primary),
                    )
                  : (_loadError != null
                      ? _buildLoadErrorCard(_loadError!)
                      : _buildList()),
            ),
            _buildNewSessionButton(),
            const PoweredByFooter(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final consentLabel = _consentSummary(_client);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildEditableName(),
          const SizedBox(height: 10),
          Row(
            children: [
              _ConsentChip(label: consentLabel, onTap: _openConsent),
              const SizedBox(width: 10),
              Text(
                '${_sessions.length} session${_sessions.length == 1 ? '' : 's'}',
                style: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 13,
                  color: AppColors.textSecondaryOnDark,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildEditableName() {
    if (!_editingName) {
      // Dashed underline affordance — matches the portal's
      // `EditableClientName` pattern. Tap anywhere on the name to edit.
      return InkWell(
        onTap: _startEditingName,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: CustomPaint(
            painter: _DashedUnderlinePainter(
              color: AppColors.textSecondaryOnDark,
            ),
            child: Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(
                _client.name.isEmpty ? 'Unnamed client' : _client.name,
                style: const TextStyle(
                  fontFamily: 'Montserrat',
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textOnDark,
                  letterSpacing: -0.3,
                ),
              ),
            ),
          ),
        ),
      );
    }

    // Edit mode — TextField with brand border, error message below.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _nameController,
          focusNode: _nameFocusNode,
          enabled: !_renameSaving,
          maxLength: 80,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _commitEditingName(),
          onChanged: (_) {
            if (_renameError != null) {
              setState(() => _renameError = null);
            }
          },
          style: const TextStyle(
            fontFamily: 'Montserrat',
            fontSize: 24,
            fontWeight: FontWeight.w700,
            color: AppColors.textOnDark,
          ),
          decoration: InputDecoration(
            counterText: '',
            filled: true,
            fillColor: AppColors.surfaceBase,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 10,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              borderSide: BorderSide(
                color: _renameError != null
                    ? AppColors.error
                    : AppColors.primary,
                width: 1.4,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              borderSide: BorderSide(
                color: _renameError != null
                    ? AppColors.error
                    : AppColors.primary,
                width: 1.4,
              ),
            ),
          ),
        ),
        if (_renameError != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              _renameError!,
              style: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 12,
                color: AppColors.error,
              ),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              children: [
                const Text(
                  'Enter to save',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 12,
                    color: AppColors.textSecondaryOnDark,
                  ),
                ),
                const SizedBox(width: 12),
                InkWell(
                  onTap: _renameSaving ? null : _cancelEditingName,
                  child: const Text(
                    'Cancel',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primary,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildList() {
    if (_sessions.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.fitness_center_outlined,
                size: 56,
                color: AppColors.grey600,
              ),
              const SizedBox(height: 14),
              Text(
                'No sessions for ${_client.name} yet',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 15,
                  color: AppColors.textSecondaryOnDark,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Tap New Session to capture one',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 13,
                  color: AppColors.grey600,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      color: AppColors.primary,
      onRefresh: _loadSessions,
      child: ListView.builder(
        reverse: true,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _sessions.length,
        itemBuilder: (context, visualIndex) {
          final dataIndex = _sessions.length - 1 - visualIndex;
          final session = _sessions[dataIndex];
          return SessionCard(
            session: session,
            isPublishing: _publishingIds.contains(session.id),
            publishError: _publishErrors[session.id],
            onOpen: () => _openSession(session),
            onDelete: () => _deleteSession(session),
            onPublish: () => _publishSession(session),
            onCopyLink:
                session.isPublished ? () => _copyLink(session) : null,
            onShare: session.isPublished ? () => _shareSession(session) : null,
            onShowPublishError: () => _showPublishErrorSnackBar(
              session,
              _publishErrors[session.id] ?? 'Unknown error',
            ),
          );
        },
      ),
    );
  }

  Widget _buildNewSessionButton() {
    return Padding(
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
    );
  }

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
                          "Couldn't load sessions.",
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
                      borderRadius:
                          BorderRadius.circular(AppTheme.radiusMd),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
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

  /// Display label for a session in delete SnackBar. Prefers the
  /// explicit `title`, else falls back to `clientName`.
  static String _sessionDisplayName(Session session) {
    final t = session.title;
    if (t != null && t.trim().isNotEmpty) return t;
    return session.clientName;
  }

  /// One-line summary of the client's viewing preferences. Used as the
  /// label for the consent chip in the header.
  static String _consentSummary(PracticeClient client) {
    if (client.grayscaleAllowed && client.colourAllowed) {
      return 'Line + B&W + Original';
    }
    if (client.grayscaleAllowed) return 'Line + B&W';
    if (client.colourAllowed) return 'Line + Original';
    return 'Line only';
  }
}

/// Small pill shown in the per-client header. Tapping opens the existing
/// [showClientConsentSheet] — mobile-appropriate UX, R-11 carve-out.
class _ConsentChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _ConsentChip({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surfaceRaised,
      shape: StadiumBorder(
        side: BorderSide(color: AppColors.primary.withValues(alpha: 0.35)),
      ),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.visibility_outlined,
                size: 14,
                color: AppColors.primary,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textOnDark,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Paints a dashed underline below the child. Matches the portal's
/// editable-title affordance so the two surfaces feel like twins.
class _DashedUnderlinePainter extends CustomPainter {
  final Color color;

  const _DashedUnderlinePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;

    const dashWidth = 4.0;
    const dashGap = 3.0;
    double x = 0;
    final y = size.height - 0.5;
    while (x < size.width) {
      final end = (x + dashWidth).clamp(0.0, size.width);
      canvas.drawLine(Offset(x, y), Offset(end, y), paint);
      x += dashWidth + dashGap;
    }
  }

  @override
  bool shouldRepaint(covariant _DashedUnderlinePainter old) =>
      old.color != color;
}
