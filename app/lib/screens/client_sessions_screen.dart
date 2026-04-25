import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/client.dart';
import '../models/session.dart';
import '../services/auth_service.dart';
import '../services/local_storage_service.dart';
import '../services/sync_service.dart';
import '../theme.dart';
import '../utils/session_title.dart';
import '../widgets/client_avatar_glyph.dart';
import '../widgets/client_consent_sheet.dart';
import '../widgets/orientation_lock_guard.dart';
import '../widgets/powered_by_footer.dart';
import '../widgets/session_card.dart';
import 'client_avatar_capture_screen.dart';
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

  /// Optional hook fired when the practitioner taps Delete client from
  /// the overflow menu. HomeScreen passes this so its local list state
  /// can remove the row immediately (the navigator pops before the
  /// parent's `_load` callback runs, so the optimistic hint matters).
  final VoidCallback? onDeleted;

  const ClientSessionsScreen({
    super.key,
    required this.client,
    required this.storage,
    this.onDeleted,
  });

  @override
  State<ClientSessionsScreen> createState() => _ClientSessionsScreenState();
}

class _ClientSessionsScreenState extends State<ClientSessionsScreen> {
  late PracticeClient _client;

  List<Session> _sessions = const [];
  bool _loading = true;
  String? _loadError;

  /// Kept for legacy wiring — Wave 18 moved publish to the Studio
  /// toolbar. No publish paths currently flip this set from
  /// ClientSessionsScreen, but the card still accepts the flag so a
  /// future parallel-publish UI has a home.
  final Set<String> _publishingIds = <String>{};

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

      if (!mounted) return;
      setState(() {
        _sessions = filtered;
        _loading = false;
        _loadError = null;
      });
    } catch (e) {
      final text = e.toString();
      final truncated = text.substring(0, min(200, text.length));
      if (!mounted) return;
      setState(() {
        _sessions = const [];
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

  // Wave 18 — publish + share moved to the Studio toolbar. The
  // ClientSessionsScreen remains a pure list: create / delete / open,
  // nothing else. If a session is marked dirty by the new
  // saveExercise stamp, the practitioner will see the coral indicator
  // via Session.hasUnpublishedContentChanges once they're inside
  // Studio. UploadService + `_publishSession` / `_shareSession` /
  // `_showPublishErrorSnackBar` / `_handleUnconsentedTreatments` /
  // `unconsented_treatments_sheet` were all deleted here — their
  // counterparts live in StudioModeScreen now.

  // ---------------------------------------------------------------------------
  // Actions — client
  // ---------------------------------------------------------------------------

  /// Delete the client + cascade-soft-delete every session.
  ///
  /// Fires immediately (R-01: no modal confirmation). The actual
  /// destructive work goes through the offline-first queue so Undo is
  /// a local cache flip — instant and roundtrip-free.
  ///
  /// On Undo, the client re-appears on Home (via [widget.onDeleted]'s
  /// parent re-render) and every cascaded session lands back in the
  /// per-client list.
  Future<void> _deleteClient() async {
    HapticFeedback.mediumImpact();
    final snapshot = _client;

    int cascadeTs;
    try {
      cascadeTs = await SyncService.instance.queueDeleteClient(
        clientId: snapshot.id,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Couldn't delete ${snapshot.name}: $e"),
          duration: const Duration(seconds: 4),
          backgroundColor: AppColors.error,
        ),
      );
      return;
    }

    widget.onDeleted?.call();
    if (!mounted) return;

    // Pop BEFORE showing the SnackBar — the parent screen (Home) owns
    // the messenger; posting on this disposed scaffold swallows the
    // action silently. The showUndoSnackBar helper looks up the
    // messenger of the context it's given, so we grab the ancestor
    // messenger now before navigating away.
    final rootMessenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();

    rootMessenger.clearSnackBars();
    rootMessenger.showSnackBar(
      SnackBar(
        content: Text(
          '${snapshot.name.isEmpty ? 'Client' : snapshot.name} deleted',
          style: const TextStyle(
            fontFamily: 'Inter',
            fontSize: 14,
            color: AppColors.textOnDark,
          ),
        ),
        backgroundColor: AppColors.surfaceRaised,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 7),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: AppColors.surfaceBorder),
        ),
        action: SnackBarAction(
          label: 'Undo',
          textColor: AppColors.primary,
          onPressed: () async {
            await SyncService.instance.queueRestoreClient(
              clientId: snapshot.id,
              cascadeTimestampMs: cascadeTs,
            );
          },
        ),
      ),
    );
  }

  Future<void> _openConsent({bool highlightAvatar = false}) async {
    HapticFeedback.selectionClick();
    final updated = await showClientConsentSheet(
      context,
      client: _client,
      highlightAvatar: highlightAvatar,
    );
    if (updated != null && mounted) {
      setState(() => _client = updated);
    }
  }

  /// Tap on the avatar glyph next to the client name. Two paths:
  ///
  ///   * `client.avatarAllowed == false`: open the consent sheet with
  ///     the avatar row highlighted. Capture only proceeds after consent.
  ///   * `client.avatarAllowed == true`: open the dedicated single-shot
  ///     [ClientAvatarCaptureScreen]. Confirmation reloads the local
  ///     [_client] so the new avatar paints immediately.
  ///
  /// Long-tapping is reserved for a future "remove avatar" flow; today
  /// it's a no-op. Single tap is the only affordance.
  Future<void> _openAvatarFlow() async {
    HapticFeedback.selectionClick();
    if (!_client.avatarAllowed) {
      await _openConsent(highlightAvatar: true);
      return;
    }
    final outcome = await pushClientAvatarCapture(context, client: _client);
    if (outcome == null) return;
    if (!mounted) return;
    // Optimistically reflect the new path locally; SyncService has
    // already queued the cloud-side write. The avatar glyph sees the
    // new path on rebuild + finds the local PNG file in the avatars/
    // directory immediately.
    setState(() {
      _client = _client.copyWith(avatarPath: outcome.cloudPath);
    });
    if (!outcome.uploadedToCloud) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Saved locally — we'll upload when you're back online."),
        ),
      );
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
    return OrientationLockGuard(
      child: Scaffold(
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
        actions: [
          PopupMenuButton<_ClientMenuAction>(
            icon: const Icon(Icons.more_vert_rounded),
            tooltip: 'More',
            color: AppColors.surfaceRaised,
            onSelected: (action) {
              switch (action) {
                case _ClientMenuAction.delete:
                  _deleteClient();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem<_ClientMenuAction>(
                value: _ClientMenuAction.delete,
                child: Row(
                  children: [
                    Icon(
                      Icons.delete_outline_rounded,
                      color: AppColors.error,
                      size: 20,
                    ),
                    SizedBox(width: 10),
                    Text(
                      'Delete client',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 14,
                        color: AppColors.textOnDark,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
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
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Wave 30 — avatar glyph + editable name on a single row so the
          // glyph reads as part of the client identity, not a chip in the
          // chrome. Tap on the glyph opens the capture flow (or the
          // consent sheet when avatar consent isn't granted yet).
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              ClientAvatarGlyph(
                client: _client,
                diameter: 44,
                onTap: _openAvatarFlow,
              ),
              const SizedBox(width: 14),
              Expanded(child: _buildEditableName()),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _ConsentChip(
                label: 'Client consent',
                onTap: () => _openConsent(),
              ),
              // Wave 18 — removed the "N sessions" count. The list
              // itself is the count; doubling it here was redundant.
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
            onOpen: () => _openSession(session),
            onDelete: () => _deleteSession(session),
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

/// Items in the per-client overflow menu. Scoped to this file — adding
/// a new action is a one-enum-value change plus a handler branch.
enum _ClientMenuAction {
  delete,
}
