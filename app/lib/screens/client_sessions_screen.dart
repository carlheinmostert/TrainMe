import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/client.dart';
import '../models/session.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../services/conversion_service.dart';
import '../models/exercise_capture.dart';
import '../services/local_storage_service.dart';
import '../services/sync_service.dart';
import '../theme.dart';
import '../utils/session_title.dart';
import '../widgets/client_avatar_glyph.dart';
import '../widgets/client_consent_sheet.dart';
import '../widgets/orientation_lock_guard.dart';
import '../widgets/session_card.dart';
import 'face_enrolment_screen.dart';
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

  /// Wave 17 — in-memory cache of plan analytics summaries, keyed by
  /// plan id (session.id). Cloud-only; fetched on demand for each
  /// published session. Not persisted to SQLite.
  final Map<String, PlanAnalyticsSummary?> _analyticsCache = {};
  bool _analyticsFetched = false;

  /// True while a rename RPC is in-flight. Disables the save path so
  /// double-taps don't produce duplicate calls.
  bool _renameSaving = false;

  /// 2026-05-13 — subscription to [ConversionService.onConversionUpdate].
  ///
  /// Re-pulls sessions from SQLite whenever an in-flight conversion
  /// completes (or transitions state) so the session-card filmstrip
  /// background paints the new Hero thumbnails the moment they're
  /// stamped, without forcing the practitioner to pull-to-refresh.
  ///
  /// Companion to the `_loadSessions()` call inside `_openSession` and
  /// `_startNewSession`: the navigator-pop refresh handles metadata
  /// changes (rename, delete, reorder) but the post-pop refresh fires
  /// BEFORE the converter finishes processing fresh captures, so the
  /// filmstrip stays empty (no `thumbnail_path` yet) until conversion
  /// resolves. This subscription bridges that window.
  StreamSubscription<ExerciseCapture>? _conversionSub;
  // 2026-05-25 — orphan-after-rejection fix. ClientSessions cards
  // surface a filmstrip / pending-count derived from the in-memory
  // session list; without this subscription a Safe Mode rejection
  // would leave a stale spinner-status entry in the count until the
  // next foreground or unrelated conversion event landed.
  StreamSubscription<ExerciseRemoval>? _removalSub;

  /// True when the inline edit-client-name input is active.
  bool _editingName = false;
  late TextEditingController _nameController;
  final FocusNode _nameFocusNode = FocusNode();
  String? _renameError;

  /// Number of locally-cached face embedding slots for this client.
  /// Drives the "Improve face recognition" nudge chip: rendered only
  /// when the count is exactly 1 (legacy single-vector clients from
  /// the 2026-05-23 wave, backfilled into slot_index=0 by the
  /// Wave-A migration). 0 = no enrolment at all (the Safe Mode banner
  /// in the capture screen handles that case). 2+ = already
  /// multi-reference, chip absent. Null = not yet loaded.
  int? _faceEmbeddingSlotCount;

  @override
  void initState() {
    super.initState();
    _client = widget.client;
    _nameController = TextEditingController(text: _client.name);
    _loadSessions();
    unawaited(_loadFaceEmbeddingSlotCount());

    // 2026-05-13 — subscribe to conversion-state updates so the session
    // card filmstrip refreshes when a fresh capture's thumbnail lands.
    // Filter by sessions in our list to avoid no-op reloads from
    // captures in other clients (unlikely while this screen is on top,
    // but cheap to guard).
    _conversionSub = ConversionService.instance.onConversionUpdate.listen(
      _handleConversionUpdate,
    );

    // 2026-05-25 — Safe Mode rejection / orphan-after-rejection guard.
    // The removal stream fires whenever a SafeModeRejection deletes a
    // row from SQLite; refresh in the same way as a conversion event
    // so the card-level filmstrip + pending count drop the orphan.
    _removalSub = ConversionService.instance.onExerciseRemoved.listen(
      _handleExerciseRemoval,
    );

    // 2026-05-13 — auto-open the consent sheet the first time this
    // practitioner enters this client's detail view. The check is
    // strictly `_client.consentExplicitlySetAt == null` so it covers
    // newly-created clients AND legacy clients whose consent was never
    // explicitly toggled (no backfill — see migration
    // 20260513065845_consent_explicitly_set_at.sql).
    if (!_client.consentExplicitlySet) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _openConsent();
      });
    }
  }

  @override
  void dispose() {
    _conversionSub?.cancel();
    _removalSub?.cancel();
    _nameController.dispose();
    _nameFocusNode.dispose();
    super.dispose();
  }

  /// Conversion-stream handler. Reloads if the firing exercise belongs
  /// to any session we currently render. Guarded by `mounted` so a
  /// post-dispose event is a no-op.
  void _handleConversionUpdate(ExerciseCapture ex) {
    if (!mounted) return;
    final sessionIds = _sessions.map((s) => s.id).toSet();
    if (!sessionIds.contains(ex.sessionId)) return;
    _loadSessions();
  }

  /// Removal-stream handler (2026-05-25 — orphan-after-rejection fix).
  /// Fires when a Safe Mode rejection deletes a row from SQLite. The
  /// payload carries the last-known [ExerciseCapture] so we can scope
  /// the reload to sessions in our list (matches the cheap-guard
  /// pattern used by [_handleConversionUpdate]). When the exercise
  /// snapshot is unavailable (rare edge — row already gone) we fall
  /// back to a blanket reload because the rejection still needs to
  /// flush a stuck spinner somewhere in the list.
  void _handleExerciseRemoval(ExerciseRemoval removal) {
    if (!mounted) return;
    final ex = removal.exercise;
    if (ex == null) {
      _loadSessions();
      return;
    }
    final sessionIds = _sessions.map((s) => s.id).toSet();
    if (!sessionIds.contains(ex.sessionId)) return;
    _loadSessions();
  }

  // ---------------------------------------------------------------------------
  // Data
  // ---------------------------------------------------------------------------

  /// Read the local cached embedding slots for this client and update
  /// [_faceEmbeddingSlotCount]. Cheap SQLite lookup; the chip's
  /// visibility derives from the slot count + the
  /// `safe_mode_face_recognition` consent toggle.
  ///
  /// Per `feedback_no_silent_fallbacks`, a query failure is reported in
  /// debug logs rather than silently producing a 0 count — that would
  /// make the chip silently disappear instead of letting the
  /// practitioner see an "Improve face recognition" affordance they
  /// could legitimately tap.
  Future<void> _loadFaceEmbeddingSlotCount() async {
    try {
      final slots = await widget.storage
          .getCachedClientFaceEmbeddings(clientId: _client.id);
      if (!mounted) return;
      setState(() {
        _faceEmbeddingSlotCount = slots.length;
      });
    } catch (e) {
      // Don't poison the UI on a transient SQLite blip — but DO log so
      // we can spot it in Console.app. The chip will stay hidden until
      // a successful read populates the count.
      debugPrint('[ClientSessions] face-embedding slot count read failed: $e');
    }
  }

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
      // Wave 17 — kick off analytics fetch for published sessions.
      _fetchAnalytics();
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

  /// Wave 17 — fetch plan analytics for all published sessions. Fire-and-
  /// forget per plan; each result lands in [_analyticsCache] and triggers
  /// a rebuild so the stats line fades in below the card.
  Future<void> _fetchAnalytics() async {
    if (_analyticsFetched) return;
    _analyticsFetched = true;
    final published = _sessions.where((s) => s.isPublished).toList();
    if (published.isEmpty) return;
    for (final session in published) {
      final summary =
          await ApiClient.instance.getPlanAnalyticsSummary(session.id);
      if (!mounted) return;
      setState(() {
        _analyticsCache[session.id] = summary;
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

  /// Tap on the avatar glyph next to the client name.
  ///
  /// Wave-D (2026-05-24) — the avatar slot is now also the entry point
  /// for Safe Mode v2 multi-reference face enrolment. The single-shot
  /// avatar capture is replaced by the Face-ID-style rotating-head
  /// sweep (`FaceEnrolmentScreen`) which produces 3-8 face embeddings
  /// AND writes the most-frontal frame as the avatar JPG. Spec:
  /// docs/specs/2026-05-24-safe-mode-v2-multi-reference-enrolment.md
  ///
  /// Flow per spec [Re-enrol affordance]:
  ///
  ///   1. `client.avatarAllowed == false` → open the consent sheet
  ///      highlighted on the avatar row (display consent for the web
  ///      player — orthogonal to face-recognition consent below).
  ///   2. `client.safeModeFaceRecognitionAllowed == false` → inline
  ///      coral toast nudging the practitioner to enable Safe Mode
  ///      face recognition in the consent sheet first. No enrolment
  ///      UI rendered.
  ///   3. No existing avatar → push [FaceEnrolmentScreen] directly.
  ///   4. Existing avatar → bottom sheet with "Replace avatar and
  ///      re-enrol" → push [FaceEnrolmentScreen].
  ///
  /// Per R-01 (no modal confirmations) the bottom sheet is dismiss-
  /// able by tapping outside / pulling down. The coral button fires
  /// immediately without an "are you sure" interstitial.
  Future<void> _openAvatarFlow() async {
    HapticFeedback.selectionClick();

    // Step 1 — display consent gate (web-player avatar share).
    if (!_client.avatarAllowed) {
      await _openConsent(highlightAvatar: true);
      return;
    }

    // Step 2 — Safe Mode face-recognition consent gate. Without this
    // we cannot store the enrolment embeddings at all (the RPC
    // refuses + the discriminator has nothing to match against). Show
    // a coral toast pointing the practitioner at the consent sheet
    // rather than silently dropping into a single-photo capture.
    if (!_client.safeModeFaceRecognitionAllowed) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            "Enable Safe Mode face recognition in Client consent first.",
            style: TextStyle(fontFamily: 'Inter', fontSize: 14),
          ),
          backgroundColor: AppColors.surfaceBase,
          duration: const Duration(seconds: 4),
          shape: RoundedRectangleBorder(
            side: const BorderSide(color: AppColors.primary, width: 1.5),
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          ),
          action: SnackBarAction(
            label: 'Open consent',
            textColor: AppColors.primary,
            onPressed: () {
              if (!mounted) return;
              unawaited(_openConsent(highlightAvatar: true));
            },
          ),
        ),
      );
      return;
    }

    // Step 3 / 4 — empty avatar slot → enrol straight away. Existing
    // avatar → confirm via bottom sheet first (single-button R-01
    // sheet, no "are you sure").
    final hasExistingAvatar =
        _client.avatarPath != null && _client.avatarPath!.isNotEmpty;
    bool shouldEnrol = !hasExistingAvatar;
    if (hasExistingAvatar) {
      shouldEnrol = await _confirmReEnrolSheet() ?? false;
    }
    if (!shouldEnrol || !mounted) return;

    final ok = await FaceEnrolmentScreen.push(context, client: _client);
    if (!mounted) return;
    if (ok) {
      // The enrolment service has already written to local SQLite +
      // queued the cloud avatar upload. Reload the client snapshot so
      // the avatar glyph paints the new bytes immediately on rebuild.
      try {
        final refreshed = await SyncService.instance.storage
            .getCachedClientById(_client.id);
        if (!mounted) return;
        if (refreshed != null) {
          setState(() {
            _client = refreshed.toPracticeClient();
          });
        }
      } catch (e) {
        debugPrint('Avatar reload after enrolment failed: $e');
      }
      // Refresh the slot count so the "Improve face recognition" nudge
      // chip disappears once the practitioner upgrades a legacy
      // single-slot client to a multi-reference enrolment.
      unawaited(_loadFaceEmbeddingSlotCount());
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Face enrolment saved.'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  /// R-01-compliant bottom sheet for the re-enrol case. Single coral
  /// "Replace and re-enrol" CTA + a Cancel text button. Returns true
  /// if the practitioner committed.
  Future<bool?> _confirmReEnrolSheet() {
    return showModalBottomSheet<bool>(
      context: context,
      backgroundColor: AppColors.surfaceBase,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  "Replace avatar and re-enrol",
                  style: TextStyle(
                    fontFamily: 'Montserrat',
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  "Capture a fresh set of face angles. The old "
                  "avatar and embeddings will be replaced.",
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 13,
                    color: AppColors.textSecondaryOnDark,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius:
                          BorderRadius.circular(AppTheme.radiusMd),
                    ),
                  ),
                  child: const Text(
                    'Replace avatar and re-enrol',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text(
                    'Cancel',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: AppColors.textSecondaryOnDark,
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
        // Wave 44 identity overhaul: leading shows back to Clients,
        // title carries the entity (avatar + dashed-underline name with
        // inline-edit). Body-level header retired — it lived as a
        // duplicate above the consent chip.
        leading: IconButton(
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
          tooltip: 'Back to Clients',
        ),
        leadingWidth: 44,
        // Slack-style channel header: small avatar + name on the title
        // slot. Tap-to-edit lives on the name itself; the avatar tap
        // routes to the existing capture / consent flow so practitioners
        // still have a one-tap path from this screen.
        titleSpacing: 0,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClientAvatarGlyph(
              client: _client,
              diameter: 32,
              onTap: _openAvatarFlow,
            ),
            const SizedBox(width: 10),
            Flexible(
              child: _buildAppBarEditableName(),
            ),
          ],
        ),
        centerTitle: false,
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
            _buildConsentRow(),
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
          ],
        ),
      ),
      ),
    );
  }

  /// Slim consent + (when active) inline-rename surface that sits above
  /// the sessions list. The body-level avatar + name + dashed underline
  /// have moved into the AppBar (Wave 44 identity overhaul). What
  /// remains here:
  ///   * consent chip (mobile twin of the portal accordion)
  ///   * the rename TextField + error/help footer when the practitioner
  ///     taps the AppBar title (it's too small to host a TextField at
  ///     the brand size and to fit the error+cancel cluster).
  Widget _buildConsentRow() {
    final showImproveChip = _shouldShowImproveFaceRecognitionChip();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_editingName) ...[
            _buildInlineRenameField(),
            const SizedBox(height: 10),
          ],
          Row(
            children: [
              // Consent chip — collapsed-state header; tapping expands
              // into the bottom sheet (mobile twin of the portal accordion).
              _ConsentChip(
                label: 'Client consent',
                grantedCount: _consentGrantedCount(_client),
                totalCount: 5,
                onTap: () => _openConsent(),
              ),
              // Wave 18 — removed the "N sessions" count. The list
              // itself is the count; doubling it here was redundant.
            ],
          ),
          if (showImproveChip) ...[
            const SizedBox(height: 8),
            _ImproveFaceRecognitionChip(
              onTap: _openAvatarFlow,
            ),
          ],
        ],
      ),
    );
  }

  /// Wave-E (2026-05-24) — the "Improve face recognition" nudge chip
  /// renders only when:
  ///   * the slot count is exactly 1 (legacy single-vector client,
  ///     backfilled by the 2026-05-23 wave's migration); AND
  ///   * the practitioner has Safe Mode face-recognition consent
  ///     granted for this client (without it the chip would lead to a
  ///     SnackBar dead-end, which contradicts feedback_no_silent_fallbacks).
  ///
  /// Returns false while the slot count is still loading
  /// (`_faceEmbeddingSlotCount == null`) so the chip never flashes on
  /// the screen during the SQLite read.
  bool _shouldShowImproveFaceRecognitionChip() {
    final count = _faceEmbeddingSlotCount;
    if (count == null) return false;
    if (count != 1) return false;
    if (!_client.safeModeFaceRecognitionAllowed) return false;
    return true;
  }

  /// Dashed-underline label rendered in the AppBar title slot. Tap →
  /// `_startEditingName` which flips the inline-rename TextField below
  /// the AppBar (drawn via [_buildInlineRenameField]).
  Widget _buildAppBarEditableName() {
    return InkWell(
      onTap: _startEditingName,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 2),
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
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: AppColors.textOnDark,
                letterSpacing: -0.2,
              ),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
        ),
      ),
    );
  }

  /// Inline TextField + status footer used when [_editingName] is true.
  /// Lives just below the AppBar (in the body's first slot) so it can
  /// surface error states + a Cancel link without crowding the chrome.
  Widget _buildInlineRenameField() {
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
            fontSize: 18,
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
            // Wave 38 — inline rename writes through SyncService.
            // Reflect the new title in our in-memory list immediately
            // so the rest of the row (dashed underline, version line)
            // re-paints without a roundtrip.
            onRenamed: (renamed) {
              if (!mounted) return;
              setState(() {
                _sessions = _sessions
                    .map((s) => s.id == renamed.id ? renamed : s)
                    .toList(growable: false);
              });
            },
            // Wave 17 analytics — moved INSIDE the card boundary
            // 2026-05-04 so the new filmstrip background frames the
            // stats row. The previous `_PlanAnalyticsRow` widget is
            // retired with this commit.
            analyticsSummary: _analyticsCache[session.id],
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
///
/// Wave 40.3 — extended with `grantedCount` / `totalCount` so the chip
/// renders the same `{granted}/{total} granted` headline the portal's
/// collapsed-state Visibility summary uses. The mobile chip IS the
/// collapsed view; tapping reveals the same sheet content the portal
/// accordion expands into.
class _ConsentChip extends StatelessWidget {
  final String label;
  final int grantedCount;
  final int totalCount;
  final VoidCallback onTap;

  const _ConsentChip({
    required this.label,
    required this.grantedCount,
    required this.totalCount,
    required this.onTap,
  });

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
              const SizedBox(width: 6),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF86EFAC).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '$grantedCount/$totalCount granted',
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF86EFAC),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Wave-E (2026-05-24) — soft nudge for legacy single-slot face-
/// recognition enrolments to upgrade to the full multi-reference set.
/// Surfaces on the client detail screen below the consent chip when
/// the client has exactly one cached embedding slot AND Safe Mode
/// face-recognition consent is granted. Tapping it routes through the
/// same `_openAvatarFlow` as the avatar glyph itself, so the re-enrol
/// bottom sheet appears and the practitioner ends up in the
/// FaceEnrolmentScreen.
class _ImproveFaceRecognitionChip extends StatelessWidget {
  final VoidCallback onTap;

  const _ImproveFaceRecognitionChip({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surfaceRaised,
      shape: StadiumBorder(
        side: BorderSide(color: AppColors.primary.withValues(alpha: 0.55)),
      ),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: const [
              Icon(
                Icons.auto_awesome_outlined,
                size: 14,
                color: AppColors.primary,
              ),
              SizedBox(width: 6),
              Text(
                'Improve face recognition',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textOnDark,
                ),
              ),
              SizedBox(width: 6),
              Text(
                're-enrol in 15 seconds',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: AppColors.textSecondaryOnDark,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Wave 40.3 — count the granted consent slots for the chip header.
/// Mirrors the portal's `grantedToggles` formula: line_drawing always
/// counts, plus whichever of grayscale / colour / avatar / analytics
/// are on. Total is fixed at 5 (Wave 17 added analytics).
int _consentGrantedCount(PracticeClient client) {
  return 1 +
      (client.grayscaleAllowed ? 1 : 0) +
      (client.colourAllowed ? 1 : 0) +
      (client.avatarAllowed ? 1 : 0) +
      (client.analyticsAllowed ? 1 : 0);
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
