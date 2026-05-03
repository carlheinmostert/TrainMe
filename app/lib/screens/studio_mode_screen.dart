import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';
import '../config.dart';
import '../models/client.dart';
import '../models/exercise_capture.dart';
import '../models/session.dart';
import '../services/conversion_service.dart';
import '../services/local_storage_service.dart';
import '../services/media_prefetch_service.dart';
import '../services/path_resolver.dart';
import '../services/sticky_defaults.dart';
import '../services/upload_service.dart';
import '../main.dart' show rootScaffoldMessengerKey;
import '../theme.dart';
import '../models/treatment.dart';
import '../services/api_client.dart';
import '../services/sync_service.dart';
import '../widgets/unconsented_treatments_sheet.dart';
import '../widgets/circuit_control_sheet.dart';
import '../widgets/client_consent_sheet.dart';
import '../widgets/download_original_sheet.dart';
import '../widgets/gutter_rail.dart';
import '../widgets/inline_action_tray.dart';
import '../widgets/inline_editable_text.dart';
import '../widgets/preset_chip_row.dart';
import '../widgets/session_expired_banner.dart';
import '../widgets/shell_pull_tab.dart';
import '../widgets/studio_bottom_bar.dart';
import '../widgets/studio_exercise_card.dart';
import '../widgets/treatment_segmented_control.dart';
import '../widgets/undo_snackbar.dart';
import '../services/auth_service.dart';
import '../widgets/orientation_lock_guard.dart';
import '../widgets/plan_settings_sheet.dart';
import 'unified_preview_screen.dart';

/// Post-session editing — the "Studio" mode.
///
/// Redesign per `docs/design/project/components.md`:
///   - Gutter Rail on the left (position numbers, insertion dots,
///     circuit rail).
///   - Inline Action Tray expanding in-place between cards.
///   - Thumbnail Peek (long-press) with inline delete.
///   - Circuit Control Sheet (bottom sheet) replacing the old inline
///     circuit slider.
///   - No chevrons on exercise cards; whole row is the tap target.
///   - No modal "Are you sure?" confirmations — R-01 via
///     [showUndoSnackBar].
///   - Publish-lock badge in the summary chip row; dims credit-costing
///     affordances once the plan is locked.
///
/// Offline-first: every edit persists locally via
/// [LocalStorageService] first; publish sits on top of this and is
/// unchanged.
class StudioModeScreen extends StatefulWidget {
  final Session session;
  final LocalStorageService storage;
  final ValueChanged<Session> onSessionChanged;
  final VoidCallback onOpenCapture;

  const StudioModeScreen({
    super.key,
    required this.session,
    required this.storage,
    required this.onSessionChanged,
    required this.onOpenCapture,
  });

  @override
  State<StudioModeScreen> createState() => _StudioModeScreenState();
}

class _StudioModeScreenState extends State<StudioModeScreen>
    with
        SingleTickerProviderStateMixin,
        WidgetsBindingObserver,
        AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  late Session _session;
  late ConversionService _conversionService;
  StreamSubscription<ExerciseCapture>? _conversionSub;
  final ImagePicker _picker = ImagePicker();

  /// Shared ticker that drives the coral-halo breathing on every idle
  /// insertion dot in the list. One controller for the whole Studio so
  /// all dots pulse in sync — a coherent rhythm reads as "system wide"
  /// rather than independent widgets blinking on their own clocks.
  /// See Design Rule R-09: affordances default to obvious; a soft
  /// coral breath around the dot advertises "this is tappable".
  late final AnimationController _pulseController;

  /// Data index of the currently-expanded card, or null when collapsed.
  int? _expandedIndex;

  /// Data index of the "lower card" of an active insertion gap, or null
  /// when no tray is open. Tray sits between cards `[_activeInsertIndex
  /// - 1]` and `[_activeInsertIndex]`. Range: 0..exercises.length.
  int? _activeInsertIndex;

  /// Re-render at 60s cadence so the "edits open · 23h left" chip
  /// counts down without parent poking.
  Timer? _lockTimer;

  /// Wave 18 — publish + share state moved here from SessionCard so
  /// the toolbar can drive them directly. [isPublishing] is true for
  /// the duration of the `UploadService.uploadPlan` call; [_publishError]
  /// holds the last error string so the error glyph + tap handler work.
  bool _isPublishing = false;
  String? _publishError;
  late UploadService _uploadService;

  /// Wave 35 — id of the exercise the practitioner was last viewing in
  /// the media viewer ("Preview"). Set in `_applyFocusFromPreview`,
  /// drives a coral border + subtle elevation lift on the matching
  /// card. Cleared on the next user interaction (any tap on the list,
  /// any save, any scroll past). Session-only — never persisted.
  String? _focusedExerciseId;

  /// Wave 35 — GlobalKeys for `Scrollable.ensureVisible`. One key per
  /// row (data index keyed by exercise id) so the focus handoff can
  /// scroll the focused card into view. Stale entries are pruned on
  /// every list build via `_pruneRowKeys`.
  final Map<String, GlobalKey> _rowKeys = {};

  /// Wave 39 (Item 5) — reachability drop-pill state.
  ///
  /// One-handed-reach affordance: a coral pill bottom-right of the list
  /// pulls the entire list down ~50% so the top-of-list cards land in
  /// the practitioner's thumb zone. Latched by tap; resets on a second
  /// tap, any card tap, an upward scroll, or a foreground cycle.
  ///
  /// `_scrollController` is the ReorderableListView's controller. We
  /// own it here so the scroll listener can both (a) detect when the
  /// list has anything to scroll (gates pill visibility) and (b) detect
  /// the >20pt upward scroll that resets a latched drop.
  ///
  /// `_canShowReachabilityPill` mirrors `position.maxScrollExtent > 0`,
  /// updated via the scroll listener and a post-frame callback after
  /// every build (the list's content can grow / shrink as the
  /// practitioner adds and deletes cards).
  ///
  final ScrollController _scrollController = ScrollController();
  bool _isReachabilityLatched = false;
  bool _canShowReachabilityPill = false;

  /// Wave 40.6 — monotonic sequence number stamped by the conversion
  /// listener every time it applies a `done` event. Shell and parent
  /// refreshes (async SQLite reads) may only overwrite `_session` when
  /// the refreshed data is at least as fresh as the sequence-stamped
  /// version. This replaces the guard-stacking pattern (Wave 39.4 +
  /// Wave 40.5) which failed when 2+ photos raced.
  int _conversionSeq = 0;

  /// Buffer for conversion events that arrive before the exercise is in
  /// `_session.exercises` (the parent's async refresh hasn't pushed the
  /// new exercise yet). Keyed by exercise ID. Drained in `didUpdateWidget`
  /// when the parent push adds the exercise to our list.
  final Map<String, ExerciseCapture> _pendingConversions = {};

  /// Wave 17 — in-memory plan analytics summary, fetched once on init
  /// for published plans. Null = not yet fetched or unavailable.
  PlanAnalyticsSummary? _planAnalytics;

  /// Periodic re-fetch of `_planAnalytics` while the Studio screen is
  /// mounted. Events land server-side as the client opens / completes
  /// the plan, but the practitioner's already-open Studio view never
  /// updates without a poll. 30s cadence is the lightest path before
  /// adding realtime subscriptions. Also re-triggered on app foreground
  /// in `didChangeAppLifecycleState` for the common case where the
  /// practitioner watches the client use the plan on web while the
  /// phone is backgrounded.
  Timer? _analyticsPollTimer;

  @override
  void initState() {
    super.initState();
    _session = widget.session;
    _conversionService = ConversionService.instance;
    _uploadService = UploadService(storage: widget.storage);
    _listenToConversions();
    _lockTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
    // Wave 39 (Item 5) — observe lifecycle so a foreground cycle
    // resets the reachability drop. Scroll listener gates pill
    // visibility + watches for the >20pt upward scroll reset trigger.
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_onReachabilityScroll);
    // Wave 17 — fetch plan analytics for published plans.
    unawaited(_fetchPlanAnalytics());
    // Lazy line-drawing prefetch — pulls public media-bucket files for
    // any exercise on this session that's cloud-only (fresh sandbox /
    // app reinstall). Fire-and-forget; per-card spinner overlays
    // surface progress via MediaPrefetchService.statusFor. On each
    // successful download we re-read the session from SQLite so the
    // MiniPreview picks up the freshly-stamped `convertedFilePath`
    // and the missing-media banner clears.
    unawaited(
      MediaPrefetchService.instance.prefetchSession(
        _session,
        storage: widget.storage,
        onExerciseDownloaded: (_) {
          if (!mounted) return;
          unawaited(_refreshSession());
        },
      ),
    );
    // Poll plan analytics while the screen is mounted so the
    // practitioner sees fresh open / completion stats without leaving
    // the screen. `_fetchPlanAnalytics` is fire-and-forget and
    // self-guards against `!mounted` + unpublished plans.
    _analyticsPollTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _fetchPlanAnalytics(),
    );
  }

  /// Wave 17 — fetch plan analytics for published plans. Best-effort;
  /// failure silently leaves [_planAnalytics] null (exercise cards render
  /// without the stats bar). Called once on init.
  Future<void> _fetchPlanAnalytics() async {
    if (!_session.isPublished) return;
    final summary = await ApiClient.instance.getPlanAnalyticsSummary(
      _session.id,
    );
    if (!context.mounted) return;
    if (summary != null) {
      setState(() => _planAnalytics = summary);
    }
  }

  @override
  void didUpdateWidget(covariant StudioModeScreen old) {
    super.didUpdateWidget(old);
    if (old.session != widget.session) {
      // Wave 40.6 — merge the parent push with local state.
      var merged = _mergeConversionState(widget.session);

      // Drain buffered conversion events for exercises that just appeared
      // in the parent push. This fixes the "last photo spinner" bug:
      // fast photo conversions outrace the parent's async SQLite read,
      // so the listener buffers the `done` event until the exercise
      // actually appears in our list.
      if (_pendingConversions.isNotEmpty) {
        final exercises = List<ExerciseCapture>.from(merged.exercises);
        var applied = false;
        for (final entry in _pendingConversions.entries) {
          final idx = exercises.indexWhere((e) => e.id == entry.key);
          if (idx >= 0) {
            exercises[idx] = entry.value;
            applied = true;
          }
        }
        if (applied) {
          _pendingConversions.clear();
          merged = merged.copyWith(exercises: exercises);
        }
      }

      setState(() => _session = merged);
    }
  }

  /// Merge [incoming] with `_session` so that each exercise keeps the
  /// FRESHER conversion status between the two. Session-level fields
  /// (publish state, lock state, title, etc.) come from [incoming];
  /// exercise metadata (reps, sets, hold, notes, name, treatment, etc.)
  /// comes from LOCAL — the in-memory `_session` is authoritative for
  /// user edits that may not have flushed to SQLite yet.
  ///
  /// **Wave 40.6 hotfix:** the original impl took exercise metadata from
  /// `incoming` when conversion ranks were equal. If the shell's async
  /// `_reconcileWithCloudIfUnpublished` captured a pre-edit snapshot and
  /// pushed it after the user made edits, those edits were stomped.
  /// Fixed: local is ALWAYS the base for exercise metadata; only
  /// conversion-specific fields come from whichever side is fresher.
  Session _mergeConversionState(Session incoming) {
    final incomingById = <String, ExerciseCapture>{
      for (final e in incoming.exercises) e.id: e,
    };
    final merged = _session.exercises.map((local) {
      final cand = incomingById[local.id];
      if (cand == null) return local;
      if (_conversionRank(cand.conversionStatus) >
          _conversionRank(local.conversionStatus)) {
        // Incoming has fresher conversion state — overlay conversion
        // fields onto local (keeping local's metadata edits intact).
        return local.copyWith(
          conversionStatus: cand.conversionStatus,
          convertedFilePath: cand.convertedFilePath,
          thumbnailPath: cand.thumbnailPath,
          videoDurationMs: cand.videoDurationMs,
          archiveFilePath: cand.archiveFilePath,
          archivedAt: cand.archivedAt,
          segmentedRawFilePath: cand.segmentedRawFilePath,
          maskFilePath: cand.maskFilePath,
        );
      }
      // Local has equal or fresher conversion state — keep local as-is.
      return local;
    }).toList();

    // For exercises that exist in incoming but not in local (new rows
    // from a parent-side addition we haven't seen yet), append them.
    for (final cand in incoming.exercises) {
      if (!_session.exercises.any((e) => e.id == cand.id)) {
        merged.add(cand);
      }
    }

    // Session-level fields from incoming (publish state, lock state).
    // Exercise list from the merge.
    return incoming.copyWith(exercises: merged);
  }

  /// Maps [ConversionStatus] to a freshness rank — higher = newer.
  int _conversionRank(ConversionStatus status) {
    switch (status) {
      case ConversionStatus.pending:
        return 0;
      case ConversionStatus.converting:
        return 1;
      case ConversionStatus.failed:
        return 2;
      case ConversionStatus.done:
        return 3;
    }
  }

  @override
  void dispose() {
    _conversionSub?.cancel();
    _lockTimer?.cancel();
    _analyticsPollTimer?.cancel();
    _pulseController.dispose();
    // Wave 39 (Item 5) — unwire reachability hooks before super.
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.removeListener(_onReachabilityScroll);
    _scrollController.dispose();
    super.dispose();
  }

  /// Wave 39 (Item 5) — reset the reachability latch when the app
  /// returns from background. Any state that survived suspension is
  /// stale relative to the practitioner's new mental model: they
  /// re-enter Studio expecting the list to be at its default position.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      if (_isReachabilityLatched) {
        setState(() => _isReachabilityLatched = false);
      }
      // Common case: practitioner watches the client use the plan on
      // web while the phone is backgrounded. Coming back to the app
      // should show fresh stats without waiting up to 30s for the
      // periodic poll.
      unawaited(_fetchPlanAnalytics());
    }
  }

  /// Wave 39 (Item 5) — single scroll listener wired to
  /// `_scrollController`. Single responsibility now:
  ///
  ///   - Gate the pill's visibility — show it only when the list has
  ///     something to scroll. `maxScrollExtent <= 0` means everything
  ///     already fits; reachability is irrelevant.
  ///
  /// Wave 39.4 — the upward-scroll-resets-latch branch was removed.
  /// QA feedback: the latch should persist until the practitioner
  /// taps the pill again. Scrolling around the dropped list shouldn't
  /// snap it back. Card taps don't reset either (M3 also drops
  /// `_resetReachability` from the card onTap path). Latch state
  /// changes only via:
  ///   - `_toggleReachability` (pill tap),
  ///   - `didChangeAppLifecycleState` (resume from background — we
  ///      still treat resume as a clean-state reset, since the user's
  ///      mental model is that backgrounding "ends" the latch).
  void _onReachabilityScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    final canScroll = pos.maxScrollExtent > 0;
    if (canScroll != _canShowReachabilityPill) {
      setState(() => _canShowReachabilityPill = canScroll);
    }
  }

  /// Wave 39 (Item 5) — toggle the reachability latch from a pill tap.
  void _toggleReachability() {
    setState(() => _isReachabilityLatched = !_isReachabilityLatched);
  }

  /// Wave 39 (Item 5) — recompute `_canShowReachabilityPill` after a
  /// build settles. The scroll listener only fires while the user is
  /// scrolling; when the practitioner adds / deletes cards we need an
  /// explicit poke so the pill appears or hides without requiring a
  /// scroll gesture first.
  void _recomputeReachabilityVisibility() {
    if (!mounted || !_scrollController.hasClients) return;
    final canScroll = _scrollController.position.maxScrollExtent > 0;
    if (canScroll != _canShowReachabilityPill) {
      setState(() => _canShowReachabilityPill = canScroll);
    }
  }

  void _pushSession(Session next) {
    _session = next;
    widget.onSessionChanged(next);
  }

  /// Wave 35 — drop the Preview-handoff focus marker on the next user
  /// interaction (any field edit, save, or scroll). No-op when the
  /// marker isn't set so call sites can fire it freely.
  void _clearFocusOnInteraction() {
    if (_focusedExerciseId == null) return;
    setState(() {
      _focusedExerciseId = null;
    });
  }

  /// Wraps [_pushSession] and stamps [Session.lastContentEditAt] to
  /// `DateTime.now()` so the session-card indicator can flip from "sage
  /// check" to "coral cloud-sync" when the plan drifts past its last
  /// publish.
  ///
  /// Use this for every content mutation that would change what the
  /// CLIENT sees on the published plan:
  ///   reps, sets, hold, notes, name, custom duration, treatment,
  ///   prep seconds, muted flag, session title, add / delete / reorder,
  ///   circuit link / break / cycles.
  ///
  /// Do NOT use it for:
  ///   - conversion progress updates (line-drawing pipeline progress is
  ///     not a user edit),
  ///   - [_refreshSession] / load-from-storage (that's restoring state,
  ///     not mutating it),
  ///   - pure-UI state (scroll, expand/collapse, `_expandedIndex`).
  void _touchAndPush(Session next) {
    // Stamp + persist. The prior implementation only mutated in-memory
    // state via _pushSession, so SQLite's `last_content_edit_at` column
    // stayed null even after edits — the session-card icon correctly
    // computes dirty on first load, but a reload (or cold start)
    // wiped the stamp and the icon flipped back to "clean." Now we
    // persist directly here so every mutation path gets durable dirty
    // state. saveExercise calls in callers are still needed (they
    // write exercise-level columns); this just guarantees the session
    // row's timestamp lands.
    final stamped = next.copyWith(lastContentEditAt: DateTime.now());
    _pushSession(stamped);
    unawaited(
      widget.storage.saveSession(stamped).catchError((e, st) {
        debugPrint('saveSession (touchAndPush) failed: $e');
        return Future<void>.value();
      }),
    );
  }

  Future<void> _refreshSession() async {
    final seqBefore = _conversionSeq;
    final refreshed = await widget.storage.getSession(_session.id);
    if (refreshed == null || !mounted) return;
    // Wave 40.6 — if a conversion event landed while we were reading
    // SQLite, the in-memory state is fresher. Merge rather than replace.
    if (_conversionSeq != seqBefore) {
      final merged = _mergeConversionState(refreshed);
      setState(() => _pushSession(merged));
    } else {
      setState(() => _pushSession(refreshed));
    }
  }

  void _listenToConversions() {
    _conversionSub = _conversionService.onConversionUpdate.listen((updated) {
      if (!mounted) return;
      // Wave 40.6 — authoritative conversion path. The conversion
      // listener is the SOLE writer of conversion-state changes.
      //
      // 1. Bump the monotonic sequence counter so any concurrent
      //    async SQLite reads (shell refresh, parent re-push) that
      //    resolve later know they're stale.
      // 2. Apply the conversion payload to the in-memory exercise
      //    list synchronously (instant spinner clear).
      // 3. Kick off a background SQLite reconcile that merges ALL
      //    pending conversion events over the canonical snapshot.
      //    The reconcile also bumps the sequence, keeping the
      //    freshness guard intact.
      //
      // This replaces the Wave 39.4 two-part fix + Wave 40.5 guard
      // stacking which failed when 2+ photos raced because the
      // parent's async refresh could sneak between events.
      _conversionSeq++;
      final seqAtEvent = _conversionSeq;
      final exercises = List<ExerciseCapture>.from(_session.exercises);
      final idx = exercises.indexWhere((e) => e.id == updated.id);
      if (idx >= 0) {
        exercises[idx] = updated;
        setState(() {
          _pushSession(_session.copyWith(exercises: exercises));
        });
        unawaited(_reconcileFromStorage(updated, seqAtEvent));
      } else {
        unawaited(_fetchAndAppendMissing(updated));
      }
    });
  }

  /// Read the full session from SQLite (where the exercise IS stored
  /// since capture mode saves before queuing conversion), find the
  /// missing exercise, overlay the conversion result, and append to
  /// our in-memory list. This bypasses the parent-push timing entirely.
  Future<void> _fetchAndAppendMissing(ExerciseCapture updated) async {
    final fresh = await widget.storage.getSession(_session.id);
    if (fresh == null || !mounted) return;
    // Find the exercise in the fresh session.
    final fromSqlite = fresh.exercises.where((e) => e.id == updated.id);
    if (fromSqlite.isEmpty) return; // shouldn't happen, but guard
    // Use the conversion event's status (fresher than SQLite's).
    final resolved = fromSqlite.first.copyWith(
      conversionStatus: updated.conversionStatus,
      convertedFilePath: updated.convertedFilePath,
      thumbnailPath: updated.thumbnailPath,
      videoDurationMs: updated.videoDurationMs,
      archiveFilePath: updated.archiveFilePath,
      archivedAt: updated.archivedAt,
      segmentedRawFilePath: updated.segmentedRawFilePath,
      maskFilePath: updated.maskFilePath,
    );
    _conversionSeq++;
    if (!mounted) return;
    setState(() {
      final exercises = List<ExerciseCapture>.from(_session.exercises);
      // Check again in case a parent push arrived while we were reading.
      final idx = exercises.indexWhere((e) => e.id == updated.id);
      if (idx >= 0) {
        exercises[idx] = resolved;
      } else {
        exercises.add(resolved);
      }
      _pushSession(_session.copyWith(exercises: exercises));
    });
  }

  /// Wave 40.6 — read the canonical session from SQLite, then merge
  /// [authoritative] over the matching exercise row before pushing.
  /// Only applies when our [seqAtWrite] still matches `_conversionSeq`
  /// (no newer conversion event has landed in the meantime).
  ///
  /// **Wave 40.6 hotfix** — the original impl replaced `_session` wholesale
  /// with `fresh` (the SQLite snapshot). If the practitioner had edited
  /// exercise metadata (reps, sets, hold, notes, etc.) between the
  /// conversion event and the SQLite read, those edits existed only in
  /// `_session` and were stomped. Fixed by keeping `_session` as the base
  /// and only overlaying conversion-specific fields from `fresh` / the
  /// authoritative exercise.
  Future<void> _reconcileFromStorage(
    ExerciseCapture authoritative,
    int seqAtWrite,
  ) async {
    final fresh = await widget.storage.getSession(_session.id);
    if (fresh == null || !mounted) return;
    // If a newer conversion event arrived while we were reading SQLite,
    // skip this reconcile — the newer event's own reconcile will handle
    // it.
    if (_conversionSeq != seqAtWrite) return;

    // Build a lookup of SQLite exercises for conversion-state reconcile.
    final freshById = <String, ExerciseCapture>{
      for (final e in fresh.exercises) e.id: e,
    };

    // Keep in-memory exercises as the base (preserves unsaved metadata
    // edits). For each exercise, overlay conversion-specific fields
    // from whichever source is fresher: the authoritative conversion
    // event for its target row, or the SQLite snapshot for any OTHER
    // exercises whose conversion may have advanced since our last push.
    final merged = _session.exercises.map((local) {
      if (local.id == authoritative.id) {
        // The conversion event itself is always the freshest for its row.
        return local.copyWith(
          conversionStatus: authoritative.conversionStatus,
          convertedFilePath: authoritative.convertedFilePath,
          thumbnailPath: authoritative.thumbnailPath,
          videoDurationMs: authoritative.videoDurationMs,
          archiveFilePath: authoritative.archiveFilePath,
          archivedAt: authoritative.archivedAt,
          segmentedRawFilePath: authoritative.segmentedRawFilePath,
          maskFilePath: authoritative.maskFilePath,
        );
      }
      final freshRow = freshById[local.id];
      if (freshRow != null &&
          _conversionRank(freshRow.conversionStatus) >
              _conversionRank(local.conversionStatus)) {
        // SQLite has a fresher conversion state for this exercise
        // (e.g. a conversion that completed while we were reading).
        return local.copyWith(
          conversionStatus: freshRow.conversionStatus,
          convertedFilePath: freshRow.convertedFilePath,
          thumbnailPath: freshRow.thumbnailPath,
          videoDurationMs: freshRow.videoDurationMs,
          archiveFilePath: freshRow.archiveFilePath,
          archivedAt: freshRow.archivedAt,
          segmentedRawFilePath: freshRow.segmentedRawFilePath,
          maskFilePath: freshRow.maskFilePath,
        );
      }
      return local;
    }).toList();

    // Bump seq again so the reconcile result is also protected.
    _conversionSeq++;
    if (!mounted) return;
    setState(() {
      _pushSession(_session.copyWith(exercises: merged));
    });
  }

  // Wave 38 — `_saveClientName` + `_displayTitle` retired. The Studio
  // AppBar that hosted the inline-edit was removed; rename now lives on
  // the SessionCard (client detail page), which routes through
  // `SyncService.queueRenameSession` for offline-safe writes.

  // ---------------------------------------------------------------------------
  // Publish-lock state
  // ---------------------------------------------------------------------------
  //
  // Lock rules (Wave 32 revision):
  //   - Unpublished plan → edits free.
  //   - Published, client has NEVER opened → edits free indefinitely.
  //   - Published, client has opened, < 14 days since first open → edits free.
  //   - Published, client has opened, ≥ 14 days since first open → LOCKED.
  //   - LOCKED + unlock_credit_prepaid_at set → edits free (unlock paid;
  //     flag clears server-side on next publish).
  //
  // The padlock chip in the AppBar action bar is the only path to unlock —
  // tap → bottom sheet → 1 credit → editable again.

  /// Days of editing grace after the client first opens the plan. Wave 32:
  /// extended from 3d → 14d to match typical practitioner / client follow-up
  /// cadence (1-2 weeks); the practitioner needs free refinement until the
  /// follow-up session.
  static const int _kLockGraceDays = 14;

  bool get _isPlanLocked {
    if (!_session.isPublished) return false;
    final firstOpened = _session.firstOpenedAt;
    if (firstOpened == null) return false; // No clock until client opens.
    if (_session.unlockCreditPrepaidAt != null) return false;
    final since = DateTime.now().difference(firstOpened);
    return since >= const Duration(days: _kLockGraceDays);
  }

  /// Backwards-compat alias for the existing `_InlineActionTray` /
  /// `_buildRestRow` / Studio toolbar callsites that read the lock
  /// state. All of them want the same boolean — the post-grace lock —
  /// so a thin getter keeps the policy edit single-touch.
  bool get _isPublishLocked => _isPlanLocked;

  // `_inOpenEditWindow` / `_hoursRemainingInWindow` retired in Wave 18
  // along with `_buildPublishLockBadge`. If the edit-countdown chip
  // resurfaces we'll re-derive them inline — they were one-call
  // accessors with no lasting intrinsic value outside the chip.

  // ---------------------------------------------------------------------------
  // Import from library (multi-select)
  // ---------------------------------------------------------------------------

  static const _videoExtensions = {
    '.mp4',
    '.mov',
    '.m4v',
    '.avi',
    '.mkv',
    '.webm',
    '.3gp',
    '.hevc',
  };

  MediaType _detectMediaType(String path) {
    final ext = p.extension(path).toLowerCase();
    return _videoExtensions.contains(ext) ? MediaType.video : MediaType.photo;
  }

  Future<void> _importFromLibrary({int? insertAt}) async {
    try {
      final picked = await _picker.pickMultipleMedia();
      if (picked.isEmpty) return;
      for (final xfile in picked) {
        final type = _detectMediaType(xfile.path);
        await _addCaptureFromFile(xfile.path, type, insertAt: insertAt);
      }
    } catch (e) {
      debugPrint('Library import failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Import failed: $e')));
      }
    }
  }

  Future<void> _addCaptureFromFile(
    String sourcePath,
    MediaType type, {
    int? insertAt,
  }) async {
    final dir = await getApplicationDocumentsDirectory();
    final rawDir = Directory(p.join(dir.path, 'raw'));
    await rawDir.create(recursive: true);

    final ext = p.extension(sourcePath);
    final destPath = p.join(
      rawDir.path,
      '${DateTime.now().millisecondsSinceEpoch}$ext',
    );
    await File(sourcePath).copy(destPath);

    final exercises = List<ExerciseCapture>.from(_session.exercises);
    final position = insertAt ?? exercises.length;
    // Seed the synthetic first set up front so the card never renders
    // "No sets yet" and sticky-defaults prefill has something to overwrite.
    // saveExercise() also calls withPersistenceDefaults but only persists
    // it to SQLite — without seeding here the in-memory _session would
    // hold an empty-sets exercise and the editor sheet would open empty.
    var exercise = ExerciseCapture.create(
      position: position,
      rawFilePath: PathResolver.toRelative(destPath),
      mediaType: type,
      sessionId: _session.id,
    ).withPersistenceDefaults();
    // Wave 39 — merge SQLite snapshot with the in-memory overlay so rapid
    // edit-then-capture sequences pick up the latest override.
    final clientId = _session.clientId;
    if (clientId != null && clientId.isNotEmpty) {
      final cached = await SyncService.instance.storage.getCachedClientById(
        clientId,
      );
      StickyDefaults.primeFromSnapshot(
        clientId,
        cached?.clientExerciseDefaults ?? const <String, dynamic>{},
      );
      final effective = StickyDefaults.effectiveDefaults(
        clientId: clientId,
        cachedDefaults:
            cached?.clientExerciseDefaults ?? const <String, dynamic>{},
      );
      if (effective.isNotEmpty) {
        exercise = StickyDefaults.prefillCapture(exercise, effective);
      }
    }
    exercises.insert(position, exercise);
    for (var i = 0; i < exercises.length; i++) {
      exercises[i] = exercises[i].copyWith(position: i);
    }
    await widget.storage.saveExercise(exercise);

    if (mounted) {
      setState(() {
        _touchAndPush(_session.copyWith(exercises: exercises));
      });
    }
    _conversionService.queueConversion(exercise);
    _autoInsertRestPeriods();
  }

  /// Replace the media behind an existing exercise card. Keeps the row's
  /// position, reps/sets/hold, notes — only the file path, media-type
  /// and conversion status change. Queues a fresh conversion.
  Future<void> _replaceMedia(int dataIndex) async {
    try {
      final picked = await _picker.pickMedia();
      if (picked == null) return;
      final type = _detectMediaType(picked.path);
      final dir = await getApplicationDocumentsDirectory();
      final rawDir = Directory(p.join(dir.path, 'raw'));
      await rawDir.create(recursive: true);
      final ext = p.extension(picked.path);
      final destPath = p.join(
        rawDir.path,
        '${DateTime.now().millisecondsSinceEpoch}$ext',
      );
      await File(picked.path).copy(destPath);

      final exercises = List<ExerciseCapture>.from(_session.exercises);
      final original = exercises[dataIndex];
      final replaced = original.copyWith(
        rawFilePath: PathResolver.toRelative(destPath),
        mediaType: type,
        conversionStatus: ConversionStatus.pending,
        clearVideoDurationMs: true,
      );
      exercises[dataIndex] = replaced;
      setState(() {
        _touchAndPush(_session.copyWith(exercises: exercises));
      });
      await widget.storage.saveExercise(replaced);
      _conversionService.queueConversion(replaced);
    } catch (e) {
      debugPrint('Replace media failed: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Rest periods
  // ---------------------------------------------------------------------------

  Future<void> _insertRestBetween(int insertIndex) async {
    final exercises = List<ExerciseCapture>.from(_session.exercises);
    final hasRestBelow =
        insertIndex < exercises.length && exercises[insertIndex].isRest;
    final hasRestAbove = insertIndex > 0 && exercises[insertIndex - 1].isRest;
    if (hasRestBelow || hasRestAbove) return;

    // If the rest is being inserted BETWEEN two members of the same
    // circuit, the rest inherits that circuit's id. Circuits are not
    // broken by a rest insertion — breakage must be explicit via the
    // Circuit Control Sheet's "Break circuit" action.
    String? inheritedCircuit;
    if (insertIndex > 0 && insertIndex < exercises.length) {
      final above = exercises[insertIndex - 1];
      final below = exercises[insertIndex];
      if (above.circuitId != null && above.circuitId == below.circuitId) {
        inheritedCircuit = above.circuitId;
      }
    }

    var rest = ExerciseCapture.createRest(
      position: insertIndex,
      sessionId: _session.id,
    );
    if (inheritedCircuit != null) {
      rest = rest.copyWith(circuitId: inheritedCircuit);
    }
    exercises.insert(insertIndex, rest);
    for (var i = 0; i < exercises.length; i++) {
      exercises[i] = exercises[i].copyWith(position: i);
    }
    setState(() {
      _touchAndPush(_session.copyWith(exercises: exercises));
      if (_expandedIndex != null && _expandedIndex! >= insertIndex) {
        _expandedIndex = _expandedIndex! + 1;
      }
    });
    await widget.storage.saveExercise(rest);
    _saveExerciseOrder();
  }

  void _autoInsertRestPeriods() {
    final exercises = List<ExerciseCapture>.from(_session.exercises);
    final threshold = _session.effectiveRestIntervalSeconds;
    if (threshold < 60) return;

    int cumulativeSeconds = 0;
    final insertPositions = <int>[];

    for (var i = 0; i < exercises.length; i++) {
      final ex = exercises[i];
      if (ex.isRest) continue;
      cumulativeSeconds += ex.effectiveDurationSeconds;
      if (cumulativeSeconds >= threshold) {
        if (i < exercises.length - 1) {
          final nextIdx = i + 1;
          final hasRestBelow =
              nextIdx < exercises.length && exercises[nextIdx].isRest;
          if (!hasRestBelow) insertPositions.add(nextIdx);
        }
        cumulativeSeconds = 0;
      }
    }
    if (insertPositions.isEmpty) return;

    var offset = 0;
    for (final pos in insertPositions) {
      final adjusted = pos + offset;
      final rest = ExerciseCapture.createRest(
        position: adjusted,
        sessionId: _session.id,
      );
      exercises.insert(adjusted, rest);
      offset++;
    }
    for (var i = 0; i < exercises.length; i++) {
      exercises[i] = exercises[i].copyWith(position: i);
    }
    setState(() {
      _touchAndPush(_session.copyWith(exercises: exercises));
    });
    _saveExerciseOrder();
  }

  // ---------------------------------------------------------------------------
  // Exercise management
  // ---------------------------------------------------------------------------

  Future<void> _saveExerciseOrder() async {
    for (final ex in _session.exercises) {
      await widget.storage.saveExercise(ex);
    }
  }

  void _updateExercise(int index, ExerciseCapture updated) {
    final previous = _session.exercises[index];
    setState(() {
      final exercises = List<ExerciseCapture>.from(_session.exercises);
      exercises[index] = updated;
      _touchAndPush(_session.copyWith(exercises: exercises));
    });
    unawaited(
      widget.storage.saveExercise(updated).catchError((e, st) {
        debugPrint('saveExercise failed: $e');
      }),
    );
    // Sticky per-client defaults (Milestone R / Wave 8): every time the
    // practitioner edits one of the seven sticky fields on an existing
    // card, the new value becomes the default for the NEXT new capture
    // for this client. Forward-only — prior captures are unchanged.
    // Rest periods skip (they don't carry the reps/sets/hold/etc.
    // vocabulary).
    if (!updated.isRest) {
      // Per-set PLAN wave: deltas now flow through the per-set field
      // set (first_set_*) plus the surviving scalars. The legacy
      // custom_duration_per_rep sticky write was retired alongside the
      // manual per-rep editor.
      StickyDefaults.recordAllDeltas(
        clientId: _session.clientId,
        before: previous,
        after: updated,
      );
    }
  }

  Future<void> _deleteExercise(int index) async {
    final removed = _session.exercises[index];
    final originalExercises = List<ExerciseCapture>.from(_session.exercises);
    final exercises = reindexAfterRemove(_session.exercises, index);
    final originalExpandedIndex = _expandedIndex;
    setState(() {
      _touchAndPush(_session.copyWith(exercises: exercises));
      if (_expandedIndex == index) {
        _expandedIndex = null;
      } else if (_expandedIndex != null && _expandedIndex! > index) {
        _expandedIndex = _expandedIndex! - 1;
      }
    });

    try {
      await widget.storage.deleteExercise(removed.id);
    } catch (e, st) {
      debugPrint('deleteExercise failed: $e\n$st');
      if (!mounted) return;
      setState(() {
        _pushSession(_session.copyWith(exercises: originalExercises));
        _expandedIndex = originalExpandedIndex;
      });
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              "Couldn't delete '${removed.name ?? 'Exercise ${index + 1}'}'"
              ' — try again.',
            ),
            backgroundColor: AppColors.error,
            duration: const Duration(seconds: 4),
          ),
        );
      return;
    }

    _saveExerciseOrder();
    if (!mounted) return;
    if (!mounted) return;
    // ignore: use_build_context_synchronously
    showUndoSnackBar(
      context,
      label: '${removed.name ?? 'Exercise ${index + 1}'} deleted',
      onUndo: () async {
        await widget.storage.saveExercise(removed);
        await _refreshSession();
      },
    );
  }

  /// Swipe-right-to-duplicate: deep-copy the exercise at [index] including
  /// all media files, insert the clone at [index + 1], shift positions, and
  /// show an undo SnackBar per R-01 (no confirmation dialog).
  Future<void> _duplicateExercise(int index) async {
    final original = _session.exercises[index];
    if (original.isRest) return; // rest periods skip duplication

    final newId = const Uuid().v4();

    // Deep-copy files. Each helper resolves the original's relative path,
    // copies to a new path with the new exercise ID, and returns the
    // relative path for storage. Skips gracefully if the source doesn't
    // exist.
    String? newRawFilePath;
    String? newConvertedFilePath;
    String? newThumbnailPath;
    String? newArchiveFilePath;
    String? newSegmentedRawFilePath;
    String? newMaskFilePath;

    try {
      newRawFilePath = await _copyExerciseFile(
        original.rawFilePath,
        original.id,
        newId,
      );
      newConvertedFilePath = await _copyExerciseFile(
        original.convertedFilePath,
        original.id,
        newId,
      );
      newThumbnailPath = await _copyExerciseFile(
        original.thumbnailPath,
        original.id,
        newId,
      );
      // Also copy color + line thumbnail variants if they exist.
      await _copyThumbnailVariant(original.id, newId, '_thumb_color.jpg');
      await _copyThumbnailVariant(original.id, newId, '_thumb_line.jpg');

      newArchiveFilePath = await _copyExerciseFile(
        original.archiveFilePath,
        original.id,
        newId,
      );
      newSegmentedRawFilePath = await _copyExerciseFile(
        original.segmentedRawFilePath,
        original.id,
        newId,
      );
      newMaskFilePath = await _copyExerciseFile(
        original.maskFilePath,
        original.id,
        newId,
      );
    } catch (e) {
      debugPrint('duplicateExercise file copy failed: $e');
      // Continue with whatever we managed to copy.
    }

    // Build the duplicate exercise with a fresh UUID and position + 1.
    // Per-set PLAN wave: deep-copy each set with a fresh uuid so the
    // duplicate's child rows don't collide with the originals on the
    // UNIQUE (exercise_id, position) index.
    final duplicateSets = original.sets
        .map((s) => s.copyWith(id: const Uuid().v4()))
        .toList(growable: false);
    final duplicate = ExerciseCapture(
      id: newId,
      position: original.position + 1,
      rawFilePath: newRawFilePath ?? original.rawFilePath,
      convertedFilePath: newConvertedFilePath,
      thumbnailPath: newThumbnailPath,
      mediaType: original.mediaType,
      conversionStatus: original.conversionStatus,
      sets: duplicateSets,
      restHoldSeconds: original.restHoldSeconds,
      notes: original.notes,
      name: original.name,
      createdAt: DateTime.now(),
      sessionId: original.sessionId,
      circuitId: original.circuitId,
      includeAudio: original.includeAudio,
      prepSeconds: original.prepSeconds,
      videoDurationMs: original.videoDurationMs,
      archiveFilePath: newArchiveFilePath,
      archivedAt: original.archivedAt,
      segmentedRawFilePath: newSegmentedRawFilePath,
      maskFilePath: newMaskFilePath,
      preferredTreatment: original.preferredTreatment,
      startOffsetMs: original.startOffsetMs,
      endOffsetMs: original.endOffsetMs,
      videoRepsPerLoop: original.videoRepsPerLoop,
      aspectRatio: original.aspectRatio,
      rotationQuarters: original.rotationQuarters,
    );

    // Insert at index + 1 and shift all subsequent positions.
    final exercises = List<ExerciseCapture>.from(_session.exercises);
    exercises.insert(index + 1, duplicate);
    for (var i = index + 2; i < exercises.length; i++) {
      exercises[i] = exercises[i].copyWith(position: i);
    }

    setState(() {
      _touchAndPush(_session.copyWith(exercises: exercises));
      // Adjust expanded index if it shifted.
      if (_expandedIndex != null && _expandedIndex! > index) {
        _expandedIndex = _expandedIndex! + 1;
      }
    });

    // Persist: save the new exercise + update positions on shifted ones.
    unawaited(
      widget.storage.saveExercise(duplicate).catchError((e, st) {
        debugPrint('saveExercise (duplicate) failed: $e');
      }),
    );
    _saveExerciseOrder();

    if (!mounted) return;
    showUndoSnackBar(
      context,
      label: 'Duplicated · Undo',
      onUndo: () async {
        try {
          await widget.storage.deleteExercise(duplicate.id);
        } catch (e, st) {
          debugPrint('deleteExercise (duplicate undo) failed: $e\n$st');
          if (!mounted) return;
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              SnackBar(
                content: Text(
                  "Couldn't undo duplicate of "
                  "'${duplicate.name ?? 'Exercise'}' — try again.",
                ),
                backgroundColor: AppColors.error,
                duration: const Duration(seconds: 4),
              ),
            );
          return;
        }
        await _refreshSession();
      },
    );
  }

  /// Copy a single exercise file, replacing [oldId] with [newId] in the
  /// filename. Returns the new relative path, or null if the source is
  /// null or doesn't exist.
  Future<String?> _copyExerciseFile(
    String? relativePath,
    String oldId,
    String newId,
  ) async {
    if (relativePath == null || relativePath.isEmpty) return null;
    final absSource = PathResolver.resolve(relativePath);
    final sourceFile = File(absSource);
    if (!sourceFile.existsSync()) return null;

    // Replace the old exercise ID in the filename with the new one.
    final newRelative = relativePath.replaceAll(oldId, newId);
    final absDest = PathResolver.resolve(newRelative);

    // Ensure the destination directory exists.
    final destDir = Directory(p.dirname(absDest));
    if (!destDir.existsSync()) {
      destDir.createSync(recursive: true);
    }

    await sourceFile.copy(absDest);
    return newRelative;
  }

  /// Copy a thumbnail variant (e.g. `_thumb_color.jpg`) if it exists.
  /// These variants live next to the primary thumbnail but use a different
  /// suffix.
  Future<void> _copyThumbnailVariant(
    String oldId,
    String newId,
    String suffix,
  ) async {
    final thumbDir = p.join(PathResolver.docsDir, 'thumbnails');
    final sourceFile = File(p.join(thumbDir, '$oldId$suffix'));
    if (!sourceFile.existsSync()) return;
    final destPath = p.join(thumbDir, '$newId$suffix');
    await sourceFile.copy(destPath);
  }

  // ---------------------------------------------------------------------------
  // Circuits
  // ---------------------------------------------------------------------------

  void _linkExercises(int upperIndex, int lowerIndex) {
    final exercises = List<ExerciseCapture>.from(_session.exercises);
    final upper = exercises[upperIndex];
    final lower = exercises[lowerIndex];
    final upperCircuit = upper.circuitId;
    final lowerCircuit = lower.circuitId;

    if (upperCircuit == null && lowerCircuit == null) {
      final newId = const Uuid().v4();
      exercises[upperIndex] = upper.copyWith(circuitId: newId);
      exercises[lowerIndex] = lower.copyWith(circuitId: newId);
    } else if (upperCircuit != null && lowerCircuit == null) {
      exercises[lowerIndex] = lower.copyWith(circuitId: upperCircuit);
    } else if (upperCircuit == null && lowerCircuit != null) {
      exercises[upperIndex] = upper.copyWith(circuitId: lowerCircuit);
    } else if (upperCircuit != lowerCircuit) {
      final target = upperCircuit!;
      final source = lowerCircuit!;
      for (var i = 0; i < exercises.length; i++) {
        if (exercises[i].circuitId == source) {
          exercises[i] = exercises[i].copyWith(circuitId: target);
        }
      }
      final updatedCycles = Map<String, int>.from(_session.circuitCycles);
      if (!updatedCycles.containsKey(target) &&
          updatedCycles.containsKey(source)) {
        updatedCycles[target] = updatedCycles[source]!;
      }
      updatedCycles.remove(source);
      // Same merge rule for the custom name: transfer the source's name
      // when the target has none, otherwise keep target. Then drop the
      // source entry so the broken circuit-id doesn't leak names.
      final updatedNames = Map<String, String>.from(_session.circuitNames);
      if (!updatedNames.containsKey(target) &&
          updatedNames.containsKey(source)) {
        updatedNames[target] = updatedNames[source]!;
      }
      updatedNames.remove(source);
      _pushSession(_session.copyWith(
        circuitCycles: updatedCycles,
        circuitNames: updatedNames,
      ));
    }
    setState(() {
      _touchAndPush(_session.copyWith(exercises: exercises));
    });
    _saveAllExercises(exercises);
    unawaited(
      widget.storage.saveSession(_session).catchError((e, st) {
        debugPrint('saveSession failed: $e');
      }),
    );
  }

  void _breakCircuit(String circuitId) {
    // Remove the circuit-id from every member. Restore via undo.
    final originalExercises = List<ExerciseCapture>.from(_session.exercises);
    final originalCycles = Map<String, int>.from(_session.circuitCycles);
    final originalNames = Map<String, String>.from(_session.circuitNames);
    final exercises = List<ExerciseCapture>.from(_session.exercises);
    for (var i = 0; i < exercises.length; i++) {
      if (exercises[i].circuitId == circuitId) {
        exercises[i] = exercises[i].copyWith(clearCircuitId: true);
      }
    }
    final updatedCycles = Map<String, int>.from(_session.circuitCycles);
    updatedCycles.remove(circuitId);
    final updatedNames = Map<String, String>.from(_session.circuitNames);
    updatedNames.remove(circuitId);
    setState(() {
      _touchAndPush(
        _session.copyWith(
          exercises: exercises,
          circuitCycles: updatedCycles,
          circuitNames: updatedNames,
        ),
      );
    });
    _saveAllExercises(exercises);
    unawaited(
      widget.storage.saveSession(_session).catchError((e, st) {
        debugPrint('saveSession failed: $e');
      }),
    );
    showUndoSnackBar(
      context,
      label: 'Circuit broken',
      onUndo: () async {
        setState(() {
          // Undoing is itself a content mutation — stamp so the dirty
          // indicator settles against the restored state, not the
          // pre-break state.
          _touchAndPush(
            _session.copyWith(
              exercises: originalExercises,
              circuitCycles: originalCycles,
              circuitNames: originalNames,
            ),
          );
        });
        await _saveAllExercises(originalExercises);
        await widget.storage.saveSession(_session);
      },
    );
  }

  /// Split a circuit at the boundary between [upperIndex] and [lowerIndex].
  ///
  /// Items from [lowerIndex] through the end of the original circuit
  /// are re-tagged with a NEW circuit id (preserving their grouping as
  /// a new circuit). Items above the split stay on the original id.
  /// Whichever side drops to <2 members has its circuit id cleared —
  /// a single-member circuit has no semantic meaning.
  void _breakLinkBetween(int upperIndex, int lowerIndex) {
    final exercises = List<ExerciseCapture>.from(_session.exercises);
    if (upperIndex < 0 || lowerIndex >= exercises.length) return;
    final originalCircuitId = exercises[upperIndex].circuitId;
    if (originalCircuitId == null ||
        exercises[lowerIndex].circuitId != originalCircuitId) {
      return;
    }

    final newCircuitId = const Uuid().v4();
    var newGroupSize = 0;
    var i = lowerIndex;
    while (i < exercises.length &&
        exercises[i].circuitId == originalCircuitId) {
      exercises[i] = exercises[i].copyWith(circuitId: newCircuitId);
      newGroupSize++;
      i++;
    }

    // Count upper-side members still on the original id after the split.
    var upperGroupSize = 0;
    for (var j = 0; j < lowerIndex; j++) {
      if (exercises[j].circuitId == originalCircuitId) upperGroupSize++;
    }

    // Orphan cleanup — a single-member circuit is meaningless.
    if (upperGroupSize < 2) {
      for (var j = 0; j < exercises.length; j++) {
        if (exercises[j].circuitId == originalCircuitId) {
          exercises[j] = exercises[j].copyWith(clearCircuitId: true);
        }
      }
    }
    if (newGroupSize < 2) {
      for (var j = 0; j < exercises.length; j++) {
        if (exercises[j].circuitId == newCircuitId) {
          exercises[j] = exercises[j].copyWith(clearCircuitId: true);
        }
      }
    }

    // Inherit cycle count for the new circuit so the split feels
    // continuous (both halves spin the same N rounds).
    final originalCycles = _session.getCircuitCycles(originalCircuitId);
    final updatedCycles = Map<String, int>.from(_session.circuitCycles);
    if (newGroupSize >= 2) {
      updatedCycles[newCircuitId] = originalCycles;
    }
    if (upperGroupSize < 2) {
      updatedCycles.remove(originalCircuitId);
    }

    // Custom name follows the upper-half (the original circuit-id stays
    // there). The new lower-half starts unnamed; if its upper sibling
    // got dissolved (orphan cleanup), drop the original's name too.
    final updatedNames = Map<String, String>.from(_session.circuitNames);
    if (upperGroupSize < 2) {
      updatedNames.remove(originalCircuitId);
    }

    setState(() {
      _touchAndPush(
        _session.copyWith(
          exercises: exercises,
          circuitCycles: updatedCycles,
          circuitNames: updatedNames,
        ),
      );
    });
    _saveAllExercises(exercises);
    unawaited(
      widget.storage.saveSession(_session).catchError((e, st) {
        debugPrint('saveSession failed: $e');
      }),
    );
  }

  void _setCircuitCycles(String circuitId, int cycles) {
    setState(() {
      _touchAndPush(_session.setCircuitCycles(circuitId, cycles));
    });
    unawaited(
      widget.storage.saveSession(_session).catchError((e, st) {
        debugPrint('saveSession failed: $e');
      }),
    );
  }

  void _renameCircuit(String circuitId, String name) {
    // Diff-guard: avoid spurious _touchAndPush invocations when the
    // commit equals the current effective name (typing "CIRCUIT A" back
    // into the editor on a circuit that has no override should be a
    // no-op, not a dirty-bit flip + cloud round-trip on next publish).
    final current = _session.getCircuitName(circuitId);
    final trimmed = name.trim();
    final autoLabel = 'Circuit ${_circuitLetter(circuitId)}';
    // Case-insensitive auto-label match collapses the override — the
    // header renders the raw label uppercased for display, so a user
    // submitting "CIRCUIT A" is semantically identical to clearing.
    final isAutoLabel =
        trimmed.toLowerCase() == autoLabel.toLowerCase();
    final next = (trimmed.isEmpty || isAutoLabel) ? '' : trimmed;
    if ((current ?? '') == next) return;
    setState(() {
      _touchAndPush(_session.setCircuitName(circuitId, next));
    });
    unawaited(
      widget.storage.saveSession(_session).catchError((e, st) {
        debugPrint('saveSession failed: $e');
      }),
    );
  }

  Future<void> _saveAllExercises(List<ExerciseCapture> exercises) async {
    for (final ex in exercises) {
      await widget.storage.saveExercise(ex);
    }
  }

  Future<void> _openCircuitSheet(String circuitId) async {
    final cycles = _session.getCircuitCycles(circuitId);
    final letter = _circuitLetter(circuitId);
    final effectiveName =
        _session.getCircuitName(circuitId) ?? 'Circuit $letter';
    final result = await showCircuitControlSheet(
      context,
      initialName: effectiveName,
      initialCycles: cycles,
      // A circuit with 1 cycle is just a regular exercise — enforce ≥2.
      minCycles: 2,
      maxCycles: 10,
    );
    if (result == null) return;
    if (result.breakCircuit) {
      _breakCircuit(circuitId);
    } else {
      _setCircuitCycles(circuitId, result.cycles);
    }
  }

  /// Stable A/B/C… letter for a circuit id based on its first-appearance
  /// order in the current exercise list. Used only for display.
  String _circuitLetter(String circuitId) {
    final seen = <String>{};
    final letters = <String, int>{};
    var idx = 0;
    for (final ex in _session.exercises) {
      final cid = ex.circuitId;
      if (cid == null) continue;
      if (seen.add(cid)) {
        letters[cid] = idx++;
      }
    }
    final i = letters[circuitId] ?? 0;
    return String.fromCharCode('A'.codeUnitAt(0) + (i % 26));
  }

  // ---------------------------------------------------------------------------
  // Reorder
  // ---------------------------------------------------------------------------

  void _onReorder(int oldVisualIndex, int newVisualIndex) {
    // Wave 31 — edits on a locked plan no longer surface a toast or
    // get blocked. Only the Publish button materialises the change to
    // the client, so the credit gate lives on Publish alone.
    if (newVisualIndex > oldVisualIndex) newVisualIndex--;
    if (oldVisualIndex == newVisualIndex) return;

    final len = _session.exercises.length;
    final oldIndex = len - 1 - oldVisualIndex;
    final newIndex = len - 1 - newVisualIndex;

    setState(() {
      _expandedIndex = null;
      _activeInsertIndex = null;
      final exercises = List<ExerciseCapture>.from(_session.exercises);
      final moved = exercises.removeAt(oldIndex);
      exercises.insert(newIndex, moved);

      for (var i = 0; i < exercises.length; i++) {
        exercises[i] = exercises[i].copyWith(position: i);
      }

      // Circuit stitching — if a null-circuit item is sandwiched
      // between two items in the SAME circuit, pull it into that
      // circuit. Dragging an exercise INTO a circuit is interpreted as
      // "extend the circuit to include this item", never as "break
      // the circuit". Circuits are only broken by the explicit Break
      // action in the Circuit Control Sheet.
      for (var i = 1; i < exercises.length - 1; i++) {
        if (exercises[i].circuitId != null) continue;
        final prev = exercises[i - 1];
        final next = exercises[i + 1];
        if (prev.circuitId != null && prev.circuitId == next.circuitId) {
          exercises[i] = exercises[i].copyWith(circuitId: prev.circuitId);
        }
      }

      // Circuit orphan cleanup.
      for (var i = 0; i < exercises.length; i++) {
        if (exercises[i].circuitId == null) continue;
        final cid = exercises[i].circuitId;
        final prevSame = i > 0 && exercises[i - 1].circuitId == cid;
        final nextSame =
            i < exercises.length - 1 && exercises[i + 1].circuitId == cid;
        if (!prevSame && !nextSame) {
          exercises[i] = exercises[i].copyWith(clearCircuitId: true);
        }
      }

      _touchAndPush(_session.copyWith(exercises: exercises));
    });
    _saveExerciseOrder();
    HapticFeedback.selectionClick();
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin
    // R-09: Studio is portrait-only — bottom-anchored one-handed reach.
    //
    // Wave 38 — AppBar retired. Top of Studio is the exercise list with
    // a 12pt breath above the first card; all chrome (back, preview,
    // publish, unlock pill, stats, subtitle) lives in the bottom stack
    // so the practitioner's thumb reaches everything one-handed.
    return OrientationLockGuard(
      allowed: const {DeviceOrientation.portraitUp},
      child: Scaffold(
        backgroundColor: AppColors.surfaceBg,
        body: Stack(
          children: [
            SafeArea(
              // Wave 15 — the session-expired banner sits above the
              // Studio content so a mid-session revocation surfaces
              // without blocking ongoing edits. Reads continue from
              // SQLite; writes queue locally via SyncService. Tapping
              // Sign in routes through AuthService.signOut → AuthGate →
              // SignInScreen.
              //
              // Wave 38 — bottom: false because the StudioBottomBar wraps
              // its own SafeArea(top: false, bottom: true) so it sits
              // above the home indicator without doubling the inset.
              bottom: false,
              child: Column(
                children: [
                  SessionExpiredBanner(
                    onSignIn: () => AuthService.instance.signOut(),
                  ),
                  Expanded(child: _buildBody()),
                  StudioBottomBar(
                    session: _session,
                    isPublishing: _isPublishing,
                    canPublish: _canPublish,
                    isPlanLocked: _isPlanLocked,
                    publishError: _publishError,
                    clientName: _session.clientName,
                    onBack: () => Navigator.of(context).pop(),
                    // Wave 40 (M1) — first toolbar slot is Camera. Tap =
                    // same path as the right-edge swipe-left pull tab.
                    onCameraTap: widget.onOpenCapture,
                    onPreview: _openPreview,
                    onPublish: _publishFromToolbar,
                    onShare: _shareFromToolbar,
                    // Wave-settings — replaces the cloud-download icon
                    // with a gear that opens the PlanSettingsSheet. The
                    // save-all-to-Photos affordance moved INTO that
                    // sheet's Plan actions section (still routed to
                    // [_downloadAllToPhotos]).
                    onSettings: _openPlanSettings,
                    settingsHaveDeviations:
                        settingsDeviateFromDefaults(_session),
                    // Wave 30 — tapping Publish on a still-mid-grace plan
                    // routes to the unlock sheet (two-tap UX so the
                    // practitioner sees the unlocked state before the
                    // republish).
                    onPublishLockedTap: _openUnlockSheet,
                    onUnlockTap: _openUnlockSheet,
                    onShowPublishError: () {
                      final err = _publishError;
                      if (err != null) {
                        _showPublishErrorSnackBar(err, clipboardDetail: null);
                      }
                    },
                  ),
                ],
              ),
            ),
            Positioned.fill(
              child: ShellPullTab(
                side: ShellPullTabSide.right,
                onActivate: widget.onOpenCapture,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_session.exercises.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: _buildEmptyState(),
        ),
      );
    }
    // Wave 38 — 12pt breather above the first card. The list's own
    // padding (bottom: 8) already cushions below.
    //
    // Wave 39 (Item 5) — wrap the list in a LayoutBuilder + Stack so
    // the reachability drop-pill can sit bottom-right, above the
    // bottom toolbar. The `Transform.translate` on the list itself
    // shifts the WHOLE column down (including any sticky header) when
    // latched — `Curves.easeOut` over 200ms via TweenAnimationBuilder.
    return LayoutBuilder(
      builder: (context, constraints) {
        // Compute drop offset: half the available viewport, but never
        // more than what we'd need to put item 1 squarely in thumb
        // zone (~40% of viewport from the top). Math.min on two finite
        // doubles — both are derived from `constraints.maxHeight`,
        // which LayoutBuilder guarantees is finite. NaN-safe by
        // construction; no fallback needed.
        final viewportH = constraints.maxHeight;
        final halfDrop = viewportH * 0.5;
        final thumbZoneDrop = viewportH * 0.4;
        final dropTarget = halfDrop < thumbZoneDrop ? halfDrop : thumbZoneDrop;
        final dy = _isReachabilityLatched ? dropTarget : 0.0;

        // Schedule a post-frame visibility recompute so the pill
        // appears / hides correctly after add / delete (the scroll
        // listener only fires during scrolls; layout-only changes
        // need an explicit poke).
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _recomputeReachabilityVisibility();
        });

        // Wave 39.4 — wrap the translating list in a ClipRect bounded
        // to the body's available height so dropped content can't bleed
        // past the toolbar's top edge. Without this, the latched list
        // leaks downward over the StudioBottomBar (the body's Expanded
        // box doesn't auto-clip Transform.translate output, and the
        // outer Stack uses Clip.none for the pill).
        //
        // The pill sits OUTSIDE the ClipRect so it stays visible while
        // anchored bottom-right.
        return Stack(
          clipBehavior: Clip.none,
          children: [
            ClipRect(
              child: TweenAnimationBuilder<double>(
                tween: Tween<double>(begin: dy, end: dy),
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                builder: (context, value, child) {
                  return Transform.translate(
                    offset: Offset(0, value),
                    child: child,
                  );
                },
                child: Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: _buildExerciseList(),
                ),
              ),
            ),
            // Reachability pill — bottom-right, ~12pt clearance above
            // the StudioBottomBar (which lives outside this Stack, so
            // 12pt off the bottom of THIS box already clears it).
            if (_canShowReachabilityPill)
              Positioned(
                right: 12,
                bottom: 12,
                child: _ReachabilityDropPill(
                  latched: _isReachabilityLatched,
                  onTap: _toggleReachability,
                ),
              ),
          ],
        );
      },
    );
  }

  // Wave 38 — `_buildOpenedAnalyticsRow` + `_formatAnalyticsDate` retired.
  // The "First opened … · Last opened …" line moved into the bottom
  // stack's stats strip (`StudioBottomBar`); analytics + lock state +
  // subtitle now stack as a coherent block above the toolbar.

  Widget _buildEmptyState() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: const [
        Icon(
          Icons.drive_file_rename_outline,
          size: 48,
          color: AppColors.textSecondaryOnDark,
        ),
        SizedBox(height: 12),
        Text(
          'No exercises yet',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: 'Montserrat',
            fontSize: 20,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.3,
            color: AppColors.textOnDark,
          ),
        ),
        SizedBox(height: 8),
        // Wave 38 — Library import dropped from the bottom toolbar; it
        // re-surfaces inside the gutter's insertion tray once the list
        // has at least one card. From the empty state, the path is
        // swipe-right-to-Capture.
        Text(
          'Swipe right to Capture your first exercise.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 14,
            color: AppColors.textSecondaryOnDark,
          ),
        ),
      ],
    );
  }

  // Wave 18 — retired the exercise-count summary chip + publish-lock
  // badge from this position. Wave 30+31 routed the lock affordance
  // through the AppBar padlock chip + unlock sheet. Wave 38 retired
  // the AppBar entirely; lock + publish + back live in
  // `StudioBottomBar` now.

  Widget _buildExerciseList() {
    final exercises = _session.exercises;
    // Wave 35 — prune row keys for exercises that no longer exist
    // (handles delete + reorder gracefully). Cheap O(n) pass; the
    // map only grows to the size of the session.
    final liveIds = exercises.map((e) => e.id).toSet();
    _rowKeys.removeWhere((id, _) => !liveIds.contains(id));

    return NotificationListener<ScrollUpdateNotification>(
      // Wave 35 — drop the Preview-handoff focus marker the moment
      // the practitioner scrolls the list. We watch ScrollUpdate
      // (not Start) so the focus stays through the in-flight
      // ensureVisible animation that placed the focused card on
      // screen in the first place; once the user takes over, the
      // first reported delta past 4px clears the marker.
      onNotification: (n) {
        if (_focusedExerciseId != null &&
            n.dragDetails != null &&
            n.scrollDelta != null &&
            n.scrollDelta!.abs() > 4) {
          _clearFocusOnInteraction();
        }
        return false;
      },
      child: GestureDetector(
        // Tap outside the tray dismisses it.
        onTap: () {
          if (_activeInsertIndex != null) {
            setState(() => _activeInsertIndex = null);
          }
        },
        behavior: HitTestBehavior.translucent,
        // Plain Material ReorderableListView.builder — handles mixed-height
        // children reliably. Swapped in after two sliver-based attempts
        // produced viewport-height rows on device. reverse:true keeps the
        // bottom-anchored feel (newest at the bottom).
        child: ReorderableListView.builder(
          // Wave 39 (Item 5) — owned by `_StudioModeScreenState` so the
          // reachability drop-pill can listen for upward scrolls and
          // gate its visibility on `maxScrollExtent > 0`.
          scrollController: _scrollController,
          reverse: true,
          padding: const EdgeInsets.only(bottom: 8),
          itemCount: exercises.length,
          onReorder: _onReorder,
          // Custom drag via ReorderableDelayedDragStartListener inside
          // _buildRowWithContext. Disable the default right-edge handles.
          buildDefaultDragHandles: false,
          itemBuilder: (context, visualIndex) {
            final dataIndex = exercises.length - 1 - visualIndex;
            return KeyedSubtree(
              key: ValueKey('row_${exercises[dataIndex].id}'),
              child: _buildRowWithContext(dataIndex, visualIndex),
            );
          },
        ),
      ),
    );
  }

  /// One row + the gap below it. Gap always renders (insertion dot /
  /// circuit rail carry-through / action tray when active).
  ///
  /// Layout strategy: **Stack-based rail**. The card is a normal,
  /// non-positioned child that drives the row's height. The rail
  /// (CustomPaint) and number glyph are `Positioned` children in the
  /// left gutter strip; they inherit the card's height via `top: 0`
  /// and `bottom: 0`.
  ///
  /// Why not a `Row` with `Expanded`? Earlier `Row + Expanded +
  /// AnimatedContainer + Stack` compositions were unstable inside the
  /// sliver-based list that used to host these rows (rows claimed
  /// multiple viewports of vertical space on device). The list has
  /// since been swapped to a plain `ReorderableListView.builder`, but
  /// the Stack-based rail is kept as a defensive measure — it doesn't
  /// rely on intrinsic-height participation from the card subtree.
  /// See commits `9bfc0f8` and `89e4e2d` for earlier attempts.
  ///
  /// With `Stack`, the non-positioned card supplies the row height
  /// directly; positioned gutter children inherit it.
  Widget _buildRowWithContext(int dataIndex, int visualIndex) {
    final exercises = _session.exercises;
    final exercise = exercises[dataIndex];
    final isInCircuit = exercise.circuitId != null;
    final isFirstInCircuit =
        isInCircuit &&
        (dataIndex == 0 ||
            exercises[dataIndex - 1].circuitId != exercise.circuitId);
    final isLastInCircuit =
        isInCircuit &&
        (dataIndex == exercises.length - 1 ||
            exercises[dataIndex + 1].circuitId != exercise.circuitId);

    // Position-number glyph: exercises only, rest/circuit-header
    // contributions skipped (rests don't increment; header isn't in the
    // reorderable list).
    int? positionNumber;
    if (!exercise.isRest) {
      int n = 0;
      for (var i = 0; i <= dataIndex; i++) {
        if (!exercises[i].isRest) n++;
      }
      positionNumber = n;
    }

    // Card content (rest bar or exercise card). Always wrapped in a
    // ReorderableDelayedDragStartListener so ReorderableListView's
    // drag-to-reorder still works (buildDefaultDragHandles is off).
    //
    // Rest rows carry their OWN Dismissible wrapper inside
    // _buildRestRow (Wave 18.1 fix — the PresetChipRow on the rest bar
    // no longer scrolls horizontally, so the swipe-to-delete gesture
    // is guaranteed to land). Non-rest cards wrap with the generic
    // Dismissible below. Long-press on the thumbnail still opens the
    // Peek menu with an explicit Delete; both paths converge on
    // _deleteExercise.
    // Wave 35 — focused-card state. The Preview → Studio handoff sets
    // _focusedExerciseId after the viewer pops; the matching card gets
    // a coral border + subtle elevation lift. Cleared on any tap on
    // the list (the card's onTap handler) so the marker reads as a
    // "you were here" hint, not a sticky highlight.
    final isFocused =
        _focusedExerciseId != null && _focusedExerciseId == exercise.id;

    final Widget cardContent;
    if (exercise.isRest) {
      cardContent = _buildRestRow(dataIndex);
    } else {
      // Wave 35 — register a GlobalKey so `Scrollable.ensureVisible`
      // can scroll the matching row into view after the viewer pops.
      // One key per exercise id; stable across rebuilds.
      final rowKey = _rowKeys.putIfAbsent(exercise.id, () => GlobalKey());

      final Widget cardBody = StudioExerciseCard(
        key: rowKey,
        exercise: exercise,
        session: _session,
        index: dataIndex,
        isExpanded: _expandedIndex == dataIndex,
        isFocused: isFocused,
        isInCircuit: isInCircuit,
        // Wave 17 — per-exercise analytics stats from the in-memory
        // plan analytics summary. Null when no data is available.
        analyticsStats: _planAnalytics?.exerciseStats[exercise.id],
        onTap: () {
          // Wave 39.4 — card tap no longer resets the reachability
          // latch. The latch persists until the practitioner taps the
          // pill again (or backgrounds the app). Engaging with a card
          // while the list is dropped is the WHOLE POINT of dropping
          // it; resetting on tap defeated that affordance.
          setState(() {
            _expandedIndex = _expandedIndex == dataIndex ? null : dataIndex;
            _activeInsertIndex = null;
            // Wave 35 — any direct user interaction with the list
            // clears the Preview-handoff focus marker. We treat tap
            // on ANY card as the "you've moved on" signal, including
            // the focused card itself (re-tap = collapse + clear).
            _focusedExerciseId = null;
          });
        },
        // The editor sheet may navigate away from `dataIndex` via its
        // chevrons / dot row, so it reports the index it is currently
        // editing. Pipe that straight to `_updateExercise` — the card's
        // own `dataIndex` is just the entry point.
        onUpdate: (sheetIndex, u) {
          _clearFocusOnInteraction();
          _updateExercise(sheetIndex, u);
        },
        onThumbnailTap: () => _openMediaViewer(exercise),
        onReplaceMedia: () => _replaceMedia(dataIndex),
        onDelete: () => _deleteExercise(dataIndex),
        // Video-only: pipe the thumbnail peek's "Download original"
        // row into the Save / Share bottom sheet. Rest + photo rows
        // don't render this option (gated in ThumbnailPeek).
        onDownloadOriginal: exercise.mediaType == MediaType.video
            ? () => showDownloadOriginalSheet(
                context,
                exercise: exercise,
                practiceId: _session.practiceId,
                planId: _session.id,
              )
            : null,
      );
      cardContent = Dismissible(
        key: ValueKey('swipe_${exercise.id}'),
        direction: DismissDirection.horizontal,
        // Left-to-right swipe background: duplicate.
        background: Container(
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.only(left: 20),
          margin: const EdgeInsets.symmetric(vertical: 2),
          decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(14),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.copy_outlined, color: Colors.white, size: 20),
              SizedBox(width: 8),
              Text(
                'Duplicate',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
        // Right-to-left swipe background: delete.
        secondaryBackground: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 20),
          margin: const EdgeInsets.symmetric(vertical: 2),
          decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(14),
          ),
          child: const Icon(
            Icons.delete_outline,
            color: Colors.white,
            size: 24,
          ),
        ),
        confirmDismiss: (direction) async {
          if (direction == DismissDirection.startToEnd) {
            // Right-swipe → duplicate, then return false to keep
            // the card in place.
            unawaited(_duplicateExercise(dataIndex));
            return false;
          }
          // Left-swipe → delete (dismiss the card).
          return true;
        },
        onDismissed: (_) => _deleteExercise(dataIndex),
        child: cardBody,
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Circuit header — sits above the first card of each circuit.
          if (isFirstInCircuit) _buildCircuitHeaderRow(exercise.circuitId!),
          // The row: a Stack that the card's intrinsic height drives.
          ReorderableDelayedDragStartListener(
            index: visualIndex,
            child: Stack(
              children: [
                // Non-positioned child — drives the row's height. Left
                // margin of (kGutterVisibleWidth + 4) leaves the gutter
                // strip free for the rail.
                Padding(
                  padding: const EdgeInsets.only(left: kGutterVisibleWidth + 4),
                  child: cardContent,
                ),
                // Rail: Positioned on the LEFT gutter strip, stretches
                // top-to-bottom to inherit the card's height.
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: kGutterVisibleWidth,
                  child: RepaintBoundary(
                    child: CustomPaint(
                      painter: GutterCardPainter(
                        isInCircuit: isInCircuit,
                        isFirstInCircuit: isFirstInCircuit,
                        isLastInCircuit: isLastInCircuit,
                      ),
                    ),
                  ),
                ),
                // Number glyph — vertically centered across the full
                // card height. Pinned to the LEFT edge of the gutter
                // (with a 2px breathing pad) so the circuit rail at the
                // gutter midpoint is cleanly separated from the digit.
                // Gap from glyph centre to rail centre ≈ 14px.
                if (positionNumber != null)
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    width: kGutterVisibleWidth / 2,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 2),
                        child: GutterNumberGlyph(
                          value: positionNumber,
                          onBrand: isInCircuit,
                          dimmed: _isPublishLocked,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // Gap below this card. After the last data card the gap is
          // re-used as the trailing tail-append affordance — same
          // triangle, same tray, lowerIndex == exercises.length so
          // _importFromLibrary / _insertRestBetween append cleanly.
          if (dataIndex < exercises.length - 1)
            _buildGap(dataIndex + 1, exercise, exercises[dataIndex + 1])
          else
            _buildGap(exercises.length, exercise, null),
        ],
      ),
    );
  }

  Widget _buildRestRow(int dataIndex) {
    final exercise = _session.exercises[dataIndex];
    // Wave 18.1 — rest rows carry their own Dismissible (the generic
    // wrapper in _buildRowWithContext only covers non-rest cards).
    // The non-scrolling PresetChipRow inside _RestBar ensures the
    // horizontal swipe lands here, not on a ListView below.
    return Dismissible(
      key: ValueKey('rest-${exercise.id}'),
      direction: DismissDirection.endToStart,
      background: const SizedBox.shrink(),
      secondaryBackground: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        margin: const EdgeInsets.only(bottom: 6),
        decoration: BoxDecoration(
          color: AppColors.primary.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Delete',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
            SizedBox(width: 8),
            Icon(Icons.delete_outline, color: Colors.white, size: 22),
          ],
        ),
      ),
      confirmDismiss: (_) async => true,
      onDismissed: (_) => _deleteExercise(dataIndex),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        // Wave 18.3.1 — rest chip row can wrap to multiple lines when
        // custom values accumulate. Hardcoded `height: 52` was forcing
        // the inner Wrap into a tight cross-axis constraint which made
        // it render chips vertically (one-per-row). minHeight keeps the
        // single-line visual identical while letting the row grow.
        constraints: const BoxConstraints(minHeight: 52),
        decoration: BoxDecoration(
          // Wave 18.6 — outer container flipped from surfaceRaised to
          // surfaceBase so the inner chips (which fill with surfaceRaised
          // in their unselected state) sit against a contrasting
          // background instead of blending. Matches the way PLAN chips
          // render against the exercise card's surfaceBase body.
          color: AppColors.surfaceBase,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.rest.withValues(alpha: 0.3)),
        ),
        child: _RestBar(
          exercise: exercise,
          onUpdate: (u) => _updateExercise(dataIndex, u),
          onDelete: () {
            _deleteExercise(dataIndex);
          },
        ),
      ),
    );
  }

  Widget _buildCircuitHeaderRow(String circuitId) {
    final cycles = _session.getCircuitCycles(circuitId);
    final letter = _circuitLetter(circuitId);
    final autoLabel = 'Circuit $letter';
    final displayName = _session.getCircuitName(circuitId) ?? autoLabel;
    // Show the label uppercased for visual consistency with the legacy
    // "CIRCUIT A" treatment, but feed the inline editor the raw mixed-case
    // string so the practitioner doesn't have to type SHOUTING. The
    // initialValue carries through `displayName.toUpperCase()` so the
    // CustomPaint underline measures the rendered glyphs; on commit we
    // hand the raw input to setCircuitName.
    //
    // First-class dedicated slot: explicit bounded height so the header
    // NEVER inherits its size from the Row it lives in. This is the
    // origin of the circuit-only blow-out bug — a Row with
    // CrossAxisAlignment.stretch inside an unbounded vertical parent
    // (ReorderableListView) falls back to intrinsic sizing and the
    // Expanded subtree balloons the row to full viewport height. By
    // wrapping in a SizedBox with explicit height, the header occupies
    // exactly 32 logical pixels no matter what constraints flow in.
    //
    // After the 32px header we emit a 6px rail-carrying spacer so the
    // header's bottom coral border doesn't touch the first card below.
    // The spacer continues the rail so there's no visual break.
    const headerStyle = TextStyle(
      fontFamily: 'Inter',
      fontSize: 14,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.5,
      color: AppColors.primary,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 32,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const GutterCircuitHeaderCell(height: 32),
              const SizedBox(width: 4),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      // Inline-editable label. Tap to rename; submit /
                      // blur commits via _renameCircuit. Empty submission
                      // is rejected by InlineEditableText itself; typing
                      // back the auto label ("Circuit A") clears the
                      // override (handled in _renameCircuit).
                      Flexible(
                        child: InlineEditableText(
                          // Stable key per circuit-id so the widget
                          // survives across rebuilds; InlineEditableText
                          // syncs initialValue → controller via
                          // didUpdateWidget when not actively editing.
                          key: ValueKey('circuit-name-$circuitId'),
                          initialValue: displayName.toUpperCase(),
                          onCommit: (value) =>
                              _renameCircuit(circuitId, value),
                          textStyle: headerStyle,
                          hintText: autoLabel.toUpperCase(),
                        ),
                      ),
                      const Spacer(),
                      // Cycles chip — separate tap target. Tapping it
                      // opens the cycles / break-circuit sheet without
                      // colliding with the inline-edit gesture above.
                      GestureDetector(
                        onTap: () => _openCircuitSheet(circuitId),
                        behavior: HitTestBehavior.opaque,
                        child: Container(
                          height: 24,
                          padding:
                              const EdgeInsets.symmetric(horizontal: 10),
                          decoration: BoxDecoration(
                            color: AppColors.brandTintBg,
                            borderRadius: BorderRadius.circular(9999),
                            border: Border.all(
                              color: AppColors.brandTintBorder,
                            ),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            '×$cycles',
                            style: const TextStyle(
                              fontFamily: 'JetBrainsMono',
                              fontFamilyFallback: ['Menlo', 'Courier'],
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: AppColors.primary,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        // 6px rail-carrying spacer between the header's bottom border and
        // the first circuit card. The rail continues through so the visual
        // link is unbroken.
        const GutterSpacerCell(height: 6, railThrough: true),
      ],
    );
  }

  /// A gutter gap between two cards at `[lowerIndex - 1]` and
  /// `[lowerIndex]`. Shows the insertion dot + the inline action tray
  /// when active.
  ///
  /// Layout strategy: same Stack pattern as [_buildRowWithContext].
  /// The tray column drives the height; the gutter rail/dot paints in
  /// the left strip via `Positioned.fill`. When idle, the tray
  /// collapses (via `AnimatedSize` -> `SizedBox.shrink()`), so we pad
  /// the card column with a 20px minimum so the rail/dot have a
  /// paintable zone.
  Widget _buildGap(
    int lowerIndex,
    ExerciseCapture upper,
    ExerciseCapture? lower,
  ) {
    final isActive = _activeInsertIndex == lowerIndex;
    // Trailing gap (lower == null): no successor → no shared circuit, no
    // link/break, only Rest + Insert. Tail-append index lowerIndex ==
    // exercises.length is a unique sentinel vs. the inter-card gaps
    // (which use 1..exercises.length-1) so _activeInsertIndex stays
    // unambiguous.
    final sameCircuit =
        lower != null &&
        upper.circuitId != null &&
        upper.circuitId == lower.circuitId;

    final showRest = !upper.isRest && (lower == null || !lower.isRest);
    // Rests are first-class members of a circuit — semantically identical
    // to exercises for the purpose of linking. The only reason to NOT show
    // link is that the two items are already in the same circuit — in that
    // case we offer Break instead, to split the circuit at this point.
    // No successor → neither link nor break makes sense.
    final showLink = lower != null && !sameCircuit;
    final showBreak = lower != null && sameCircuit;

    return Stack(
      children: [
        // Card-column content: min-height placeholder + tray. The
        // placeholder gives the Stack a bounded height when the tray
        // is collapsed so the gutter rail / dot has something to paint
        // against.
        Padding(
          // Gap-specific left inset. Wider than the card's standard
          // `kGutterVisibleWidth + 4` so the flipped (apex-left)
          // triangle — which sits at x≈34 in the gutter — has clear
          // breathing room before the tray's left edge. The tray is
          // only this narrow, not the exercise card below it.
          padding: const EdgeInsets.only(left: kGutterVisibleWidth + 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Split the 20px baseline into EQUAL top + bottom slivers
              // (10 + 10) around the tray so the triangle, which is
              // painted at y = size.height / 2 of the whole Stack, sits
              // at the tray's true visual middle when the tray is open
              // — symmetric gap above and below, not skewed toward the
              // south card.
              const SizedBox(height: 10),
              InlineActionTray(
                visible: isActive,
                showRestAction: showRest,
                showLinkAction: showLink,
                showBreakAction: showBreak,
                showInsertAction: true,
                // Wave 31 — edits run free regardless of lock state.
                // Only the Publish button materialises a credit-costing
                // version bump.
                locked: false,
                onRestHere: () async {
                  setState(() => _activeInsertIndex = null);
                  await _insertRestBetween(lowerIndex);
                },
                onLinkCircuit: () {
                  setState(() => _activeInsertIndex = null);
                  _linkExercises(lowerIndex - 1, lowerIndex);
                },
                onBreakLink: () {
                  setState(() => _activeInsertIndex = null);
                  _breakLinkBetween(lowerIndex - 1, lowerIndex);
                },
                onInsertExercise: () async {
                  setState(() => _activeInsertIndex = null);
                  await _importFromLibrary(insertAt: lowerIndex);
                },
                onClose: () {
                  setState(() => _activeInsertIndex = null);
                },
              ),
              // Bottom half of the split baseline — balances the 10px
              // above the tray so the triangle sits at the tray's true
              // visual centre. Collapsed total = 10+0+10 = 20 (unchanged
              // from the prior single-sliver baseline).
              const SizedBox(height: 10),
            ],
          ),
        ),
        // Gutter rail / dot — fills the left strip plus a +10px
        // extension into the natural gap between the cards' rounded
        // corners (at mid-gap Y the cards' bodies curve inward, leaving
        // clear space for the insertion triangle's right channel). The
        // wider hit target also makes the triangle easier to tap.
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: kGutterVisibleWidth + 10,
          // Listener.onPointerDown fires on raw pointer contact — before
          // Flutter's gesture arena resolves. Guaranteed "moment of
          // contact" haptic. The earlier fix put a touch-down haptic
          // on `GutterGapCell` in gutter_rail.dart, but that widget
          // isn't the insert-dot used in the Studio layout — this
          // inline GestureDetector is. Wrapping with Listener here
          // captures the right widget.
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (_) => HapticFeedback.mediumImpact(),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                HapticFeedback.selectionClick();
                setState(() {
                  _activeInsertIndex = isActive ? null : lowerIndex;
                  _expandedIndex = null;
                });
              },
              child: RepaintBoundary(
                // The shared pulse controller drives only the halo opacity.
                // AnimatedBuilder rebuilds this small subtree 60Hz — everything
                // outside it (the row above, the tray) is unaffected.
                child: AnimatedBuilder(
                  animation: _pulseController,
                  builder: (context, _) {
                    // Ease-in-out so the halo lingers at peak/valley rather
                    // than sweeping linearly across. Reads as "breath".
                    final eased = Curves.easeInOut.transform(
                      _pulseController.value,
                    );
                    return CustomPaint(
                      painter: GutterGapPainter(
                        state: isActive
                            ? GutterDotState.active
                            : GutterDotState.idle,
                        continuousRail: sameCircuit,
                        dimmed: _isPublishLocked && !isActive,
                        // Pulse ALWAYS when idle — triangles inside a
                        // circuit are just as tappable as those between
                        // standalone exercises, so their affordance must
                        // read the same way. Killing the pulse there was
                        // an inconsistency bug.
                        pulsePhase: eased,
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Publish + Share — Wave 18 (moved from SessionCard)
  // ---------------------------------------------------------------------------

  /// True when publish is safe to fire: has exercises, no conversions in
  /// flight, not currently publishing. Lifted verbatim from the retired
  /// SessionCard rules.
  bool get _canPublish {
    final hasConversionsRunning = _session.exercises.any(
      (e) =>
          !e.isRest &&
          (e.conversionStatus == ConversionStatus.pending ||
              e.conversionStatus == ConversionStatus.converting),
    );
    final hasExercises = _session.exercises.where((e) => !e.isRest).isNotEmpty;
    return hasExercises && !hasConversionsRunning && !_isPublishing;
  }

  Future<void> _publishFromToolbar() async {
    // Extra guard — archive compression can trail the line-drawing
    // conversion; publishing before the raw-archive lands would
    // silently skip B&W / Original playback. Match the client-sessions
    // check so the toolbar never regresses that fix.
    final hasConversionsRunning = _session.exercises.any(
      (e) =>
          !e.isRest &&
          (e.conversionStatus == ConversionStatus.pending ||
              e.conversionStatus == ConversionStatus.converting),
    );
    final hasArchiveInFlight = _session.exercises.any(
      (e) =>
          !e.isRest &&
          e.mediaType == MediaType.video &&
          e.conversionStatus == ConversionStatus.done &&
          (e.archiveFilePath == null || e.archiveFilePath!.isEmpty),
    );
    if (hasConversionsRunning || hasArchiveInFlight) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              hasArchiveInFlight
                  ? 'Still archiving videos — one moment…'
                  : 'Wait for conversions to finish before publishing',
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      }
      return;
    }

    setState(() {
      _isPublishing = true;
      _publishError = null;
    });
    PublishResult? result;
    Session? loadedSession;
    try {
      loadedSession = await widget.storage.getSession(_session.id);
      if (loadedSession == null) return;
      result = await _uploadService.uploadPlan(loadedSession);
    } catch (e) {
      final practiceId =
          AuthService.instance.currentPracticeId.value ??
          loadedSession?.practiceId ??
          '';
      final trainerId = ApiClient.instance.currentUserId ?? '';
      result = PublishResult.networkFailed(
        error: PublishFailurePayload.fromPublishCatch(
          caught: e,
          practiceId: practiceId,
          trainerId: trainerId,
          refundLikelyAttempted: false,
          refundOutcomeUnknown: false,
          remoteVersionMayHaveAdvanced: false,
        ),
      );
    } finally {
      if (mounted) {
        // Refresh local state — `uploadPlan` rewrites the session row.
        await _refreshSession();
        setState(() => _isPublishing = false);
      }
    }

    if (!mounted) return;
    if (result.success) {
      final consentCheckSkipped = result.consentPreflightSkippedReason;
      final optionalArtifactFailure = result.optionalArtifactFailureReason;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Published \u2713'),
          duration: const Duration(days: 1),
          action: SnackBarAction(
            label: 'OK',
            textColor: AppColors.primary,
            onPressed: () {
              ScaffoldMessenger.of(context).hideCurrentSnackBar();
            },
          ),
        ),
      );
      // Per-set PLAN wave \u2014 surface a follow-up SnackBar when the
      // server fell back to default sets for one or more exercises
      // (publish payload missing / empty `sets[]`). The practitioner
      // needs a nudge to open the editor and set real reps/weight.
      final fallbackIds = result.fallbackSetExerciseIds;
      if (fallbackIds.isNotEmpty) {
        final n = fallbackIds.length;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '$n ${n == 1 ? 'exercise was' : 'exercises were'} '
              'saved with default sets. Open them to set reps and weight.',
              style: const TextStyle(
                fontFamily: 'Inter',
                color: Colors.white,
                fontSize: 13,
              ),
            ),
            backgroundColor: AppColors.primary,
            duration: const Duration(seconds: 8),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      if (consentCheckSkipped != null && consentCheckSkipped.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Published, but treatment-consent pre-check was skipped ($consentCheckSkipped). '
              'Server guard still enforced consent.',
              style: const TextStyle(
                fontFamily: 'Inter',
                color: Colors.white,
                fontSize: 13,
              ),
            ),
            backgroundColor: AppColors.surfaceRaised,
            duration: const Duration(seconds: 7),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      if (optionalArtifactFailure != null &&
          optionalArtifactFailure.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Published, but some optional treatment files are still processing ($optionalArtifactFailure). '
              'Line treatment is live now; retry publish later to backfill.',
              style: const TextStyle(
                fontFamily: 'Inter',
                color: Colors.white,
                fontSize: 13,
              ),
            ),
            backgroundColor: AppColors.surfaceRaised,
            duration: const Duration(seconds: 8),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } else if (result.isUnconsentedTreatments) {
      await _handleUnconsentedTreatments(result.unconsented!);
    } else if (result.isNeedsConsentConfirmation) {
      await _handleNeedsConsentConfirmation(result.consentConfirmationClient!);
    } else if (result.isPreflightFailure) {
      final errStr = result.toErrorString();
      setState(() => _publishError = errStr);
      _showMissingMediaSnackBar(result.missingFiles?.length ?? 0);
      _scrollToFirstBrokenCard();
    } else {
      final refundUnconfirmed = result.networkFailureRefundOutcomeUnknown;
      final versionDriftWarning = result.networkFailureVersionDriftReason;
      final errStr = result.toErrorString();
      setState(() => _publishError = errStr);
      _showPublishErrorSnackBar(
        errStr,
        clipboardDetail: result.networkFailureClipboardDetail,
      );
      if (refundUnconfirmed) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Credits may still be deducted. Check balance and contact support if it does not auto-reconcile.',
            ),
            duration: Duration(seconds: 8),
            behavior: SnackBarBehavior.floating,
            backgroundColor: AppColors.surfaceRaised,
          ),
        );
      }
      if (versionDriftWarning != null && versionDriftWarning.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '$versionDriftWarning Share link may already point to this version.',
            ),
            duration: const Duration(seconds: 8),
            behavior: SnackBarBehavior.floating,
            backgroundColor: AppColors.surfaceRaised,
          ),
        );
      }
    }
  }

  /// Wave 29 — handle the "consent never explicitly confirmed" gate.
  /// Open the consent sheet; on save (which stamps consent_confirmed_at
  /// via the RPC + local cache) re-fire publish.
  Future<void> _handleNeedsConsentConfirmation(PracticeClient client) async {
    final saved = await showClientConsentSheet(context, client: client);
    if (!mounted) return;
    if (saved != null) {
      await _publishFromToolbar();
    }
  }

  /// Wave 29 — open the unlock-for-edit sheet. Pre-pays one credit via
  /// `unlock_plan_for_edit`; on success the next publish is free
  /// (server-side `consume_credit` reads + clears the flag). Insufficient
  /// credits surfaces the same publish-error snackbar path.
  Future<void> _openUnlockSheet() async {
    HapticFeedback.selectionClick();
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: AppColors.surfaceBase,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Unlock plan for editing',
                style: TextStyle(
                  fontFamily: 'Montserrat',
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                  color: AppColors.textOnDark,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Adds back add / delete / reorder. Consumes 1 credit. '
                'Version stays at v${_session.version} until you republish.',
                style: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 14,
                  color: AppColors.textSecondaryOnDark,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(sheetCtx).pop(false),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: AppColors.surfaceBorder),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text(
                        'Cancel',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontWeight: FontWeight.w600,
                          color: AppColors.textOnDark,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => Navigator.of(sheetCtx).pop(true),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text(
                        'Unlock',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || confirmed != true) return;

    Map<String, dynamic> response;
    try {
      response = await ApiClient.instance.unlockPlanForEdit(
        planId: _session.id,
      );
    } catch (e) {
      if (!mounted) return;
      _showPublishErrorSnackBar('Unlock failed: $e');
      return;
    }

    if (!mounted) return;
    if (response['ok'] == true) {
      // Stamp local mirror so `_isPlanLocked` flips immediately; the
      // cloud row will re-confirm on the next session reload via
      // `getPlanPublishState` / `_refreshSession`.
      final prepaidIso = response['prepaid_at'];
      DateTime? prepaidAt;
      if (prepaidIso is String) {
        prepaidAt = DateTime.tryParse(prepaidIso);
      }
      final updated = _session.copyWith(
        unlockCreditPrepaidAt: prepaidAt ?? DateTime.now(),
      );
      setState(() => _pushSession(updated));
      unawaited(widget.storage.saveSession(updated));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Plan unlocked — edit and re-publish.'),
          duration: Duration(seconds: 3),
        ),
      );
    } else if (response['reason'] == 'insufficient_credits') {
      final balance = response['balance'];
      // Apple Reader-App compliance (Guideline 3.1.1): the previous
      // copy ended with "Buy more via manage.homefit.studio." which
      // points at the web purchase page from inside the app. Reviewers
      // treat that as a 3.1.1 nudge. The shorter line below states the
      // shortfall and stops there.
      _showPublishErrorSnackBar(
        'Not enough credits to unlock. Balance: ${balance ?? 0}.',
      );
    } else {
      _showPublishErrorSnackBar(
        'Unlock failed: ${response['reason'] ?? 'unknown'}',
      );
    }
  }

  Future<void> _handleUnconsentedTreatments(
    UnconsentedTreatmentsException exc,
  ) async {
    // For the Studio-origin publish we don't have the client row in
    // scope (ClientSessionsScreen owns it). Show the bottom sheet
    // without flipping consent locally — the RPC does that server-
    // side. If the practitioner picks "grant + retry", re-fire
    // publish; otherwise leave the error for Studio to surface.
    final action = await showUnconsentedTreatmentsSheet(
      context,
      exception: exc,
      clientId: _session.clientId ?? '',
      currentGrayscaleAllowed: false,
      currentColourAllowed: false,
    );
    if (!mounted) return;
    switch (action) {
      case UnconsentedTreatmentsAction.grantAndPublish:
        await _publishFromToolbar();
      case UnconsentedTreatmentsAction.backToStudio:
      case UnconsentedTreatmentsAction.dismissed:
        // No-op — practitioner dismissed the sheet.
        break;
    }
  }

  void _showPublishErrorSnackBar(String error, {String? clipboardDetail}) {
    final summary = 'Publish failed: $error';
    final clipboardText = clipboardDetail != null && clipboardDetail.isNotEmpty
        ? 'Publish failed:\n$clipboardDetail'
        : summary;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () async {
              await Clipboard.setData(ClipboardData(text: clipboardText));
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Error copied'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
            child: Text(summary, maxLines: 3, overflow: TextOverflow.ellipsis),
          ),
          duration: const Duration(seconds: 12),
          backgroundColor: AppColors.error,
          action: SnackBarAction(
            label: 'Retry',
            textColor: Colors.white,
            onPressed: _publishFromToolbar,
          ),
        ),
      );
  }

  void _showMissingMediaSnackBar(int count) {
    final plural = count > 1;
    final msg =
        '$count exercise${plural ? 's' : ''} ${plural ? 'have' : 'has'} '
        'missing media — fix before publishing.';
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 6),
          backgroundColor: AppColors.surfaceRaised,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: AppColors.primary, width: 1),
          ),
        ),
      );
  }

  void _scrollToFirstBrokenCard() {
    final exercises = _session.exercises;
    final brokenIdx = exercises.indexWhere(
      (e) => !e.isRest && _exerciseHasMissingMedia(e),
    );
    if (brokenIdx < 0) return;
    final brokenId = exercises[brokenIdx].id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final key = _rowKeys[brokenId];
      final ctx = key?.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
        alignment: 0.5,
      );
    });
  }

  bool _exerciseHasMissingMedia(ExerciseCapture e) {
    if (e.isRest) return false;
    final path = e.absoluteConvertedFilePath ?? e.absoluteRawFilePath;
    return path.isEmpty || !File(path).existsSync();
  }

  // Wave 38.1 hotfix — Import + Share restored to the bottom toolbar
  // alongside Preview + Publish; Carl's mockup spec was missing these
  // two slots in the W38 first cut. Share fires the iOS share sheet
  // with the published plan URL.
  Future<void> _shareFromToolbar() async {
    final url = _session.planUrl;
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Share failed: $e')));
      }
    }
  }

  /// Wave 41 — download all raw captures (videos + photos) in the
  /// current session to the iOS Camera Roll. Skips rest periods and
  /// exercises with no raw file. Uses `photo_manager` for the actual
  /// PHPhotoLibrary write, same as `OriginalVideoService.saveToPhotos`.
  // ---------------------------------------------------------------------------
  // Plan settings sheet — gear icon on the bottom toolbar.
  // ---------------------------------------------------------------------------

  /// Opens the plan-settings sheet. The sheet binds the existing
  /// rest-interval persistence path to its stepper, routes Save-All-to-
  /// Photos to [_downloadAllToPhotos], and routes Delete plan to the
  /// soft-delete path. UI-only Phase A — every other field is in-memory
  /// with `TODO(phase-b)` markers.
  void _openPlanSettings() {
    HapticFeedback.selectionClick();
    showPlanSettingsSheet(
      context: context,
      session: _session,
      clientName: _session.clientName,
      onRestIntervalChanged: (newValue) {
        // Persists via the existing _touchAndPush flow so the
        // session-card "dirty" indicator flips correctly. Every other
        // inline edit in Studio (circuit cycles, exercise renames)
        // routes the same way.
        _touchAndPush(
          _session.copyWith(preferredRestIntervalSeconds: newValue),
        );
      },
      onSaveAllToPhotos: _downloadAllToPhotos,
      onCopyPlanUrl: _copyPlanShareUrl,
      onDeletePlan: _softDeletePlanFromSettings,
      createdByLabel: _resolveCreatedByLabel(),
    );
  }

  /// Best-effort resolution of "Created by" for the Plan info section.
  /// Returns the practitioner's email when the session row was created
  /// under the currently-signed-in user; otherwise "—" (we don't have
  /// a per-user lookup table on-device).
  String _resolveCreatedByLabel() {
    final createdByUid = _session.createdByUserId;
    if (createdByUid == null) return '—';
    final auth = AuthService.instance;
    if (auth.currentUserId == createdByUid) {
      final email = ApiClient.instance.currentUserEmail;
      if (email != null && email.trim().isNotEmpty) return email;
    }
    return '—';
  }

  /// Copy the canonical plan URL to the clipboard + flash a SnackBar.
  Future<void> _copyPlanShareUrl() async {
    final url = '${AppConfig.webPlayerBaseUrl}/p/${_session.id}';
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        const SnackBar(
          content: Text('Plan URL copied'),
          duration: Duration(seconds: 2),
        ),
      );
  }

  /// Soft-delete the plan from inside the settings sheet.
  ///
  /// R-01: no modal confirmation — fires immediately, undo via the
  /// SnackBar (matching `client_sessions_screen.dart._deleteSession`).
  /// Pops the Studio screen so the parent ClientSessionsScreen's
  /// `_loadSessions` refresh runs.
  Future<void> _softDeletePlanFromSettings() async {
    final snapshot = _session;
    await widget.storage.softDeleteSession(snapshot.id);
    if (!mounted) return;

    // The local Studio Scaffold dies on pop — use the app-root messenger
    // installed via main.dart's scaffoldMessengerKey so the undo lands on
    // the parent (ClientSessionsScreen).
    final messenger = rootScaffoldMessengerKey.currentState;
    Navigator.of(context).pop();
    if (messenger == null) return;


    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            'Plan deleted',
          ),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () async {
              await widget.storage.restoreSession(snapshot.id);
            },
          ),
        ),
      );
  }

  Future<void> _downloadAllToPhotos() async {
    // Collect saveable exercises — skip rests and exercises with no raw file.
    final saveable = _session.exercises.where((e) {
      if (e.isRest) return false;
      final rawPath = e.absoluteRawFilePath;
      if (rawPath.isEmpty) return false;
      return File(rawPath).existsSync();
    }).toList();

    if (saveable.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No exercise files to save'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }

    // Request addOnly permission.
    final state = await PhotoManager.requestPermissionExtend(
      requestOption: const PermissionRequestOption(
        iosAccessLevel: IosAccessLevel.addOnly,
      ),
    );
    if (!state.hasAccess) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Photos permission denied — open Settings to allow'),
            duration: Duration(seconds: 3),
          ),
        );
      }
      return;
    }

    int saved = 0;
    final total = saveable.length;

    for (final exercise in saveable) {
      if (!mounted) return;
      saved++;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text('$saved/$total saving\u2026'),
            duration: const Duration(seconds: 30),
          ),
        );

      final file = File(exercise.absoluteRawFilePath);
      try {
        if (exercise.mediaType == MediaType.video) {
          await PhotoManager.editor.saveVideo(
            file,
            title: p.basename(file.path),
          );
        } else {
          // Photo — save as image.
          await PhotoManager.editor.saveImageWithPath(
            file.path,
            title: p.basename(file.path),
          );
        }
      } catch (e) {
        // Best-effort — log and continue with next file.
        debugPrint('Failed to save ${exercise.name}: $e');
      }
    }

    if (mounted) {
      final label = total == 1
          ? '1 file saved to Photos'
          : '$total files saved to Photos';
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(content: Text(label), duration: const Duration(seconds: 3)),
        );
    }
  }

  void _openPreview() {
    HapticFeedback.selectionClick();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            UnifiedPreviewScreen(session: _session, storage: widget.storage),
      ),
    );
  }

  Future<void> _openMediaViewer(ExerciseCapture exercise) async {
    if (exercise.isRest) return;
    // Build a list of the non-rest exercises so the viewer can page
    // through them. Rests don't have media, so pulling them out keeps
    // every page a real media slide.
    final mediaList = _session.exercises
        .where((e) => !e.isRest)
        .toList(growable: false);
    final initialIndex = mediaList.indexWhere((e) => e.id == exercise.id);
    if (initialIndex < 0) return;

    if (!mounted) return;
    // Wave 35 — clear any stale exit-inbox id from a previous viewer
    // pop that was already handled (defence-in-depth; the takeLast
    // call after the await is the canonical clear).
    MediaViewerExitInbox.lastClosedExerciseId = null;
    final result = await Navigator.of(context).push<Object?>(
      MaterialPageRoute<Object?>(
        fullscreenDialog: true,
        builder: (_) => MediaViewerBody(
          exercises: mediaList,
          initialIndex: initialIndex,
          session: _session,
          // When the practitioner cycles treatment on an exercise, the
          // viewer writes to local SQLite directly. We bubble the change
          // up here so the Studio card tiles + in-memory session stay in
          // sync without waiting for the route to pop.
          onExerciseUpdate: (updated) {
            final dataIndex = _session.exercises.indexWhere(
              (e) => e.id == updated.id,
            );
            if (dataIndex >= 0) {
              _updateExercise(dataIndex, updated);
            }
          },
          // Wave 27 — tuner sliders write through to the in-memory
          // session so the AnimatedOpacity duration tracks the slider
          // live. _touchAndPush also persists the row, so the value
          // survives a viewer close before refresh.
          onSessionUpdate: (next) {
            _touchAndPush(next);
          },
        ),
      ),
    );
    // When the viewer pops, refresh the session from disk so any writes
    // that bypassed the in-memory update path (offline queue, etc.) land
    // before the next render.
    if (!mounted) return;
    await _refreshSession();
    if (!mounted) return;
    // Wave 35 — focus handoff. The viewer pops with the id of the
    // exercise the practitioner was viewing at close-time. Two paths
    // populate the id:
    //   * Close × button → Navigator.pop returns the id directly.
    //   * System back / iOS edge swipe → result is null; the viewer's
    //     PopScope stamps the id into MediaViewerExitInbox.
    String? focusId;
    if (result is String && result.isNotEmpty) {
      focusId = result;
    } else {
      focusId = MediaViewerExitInbox.takeLastClosedExerciseId();
    }
    if (focusId != null) {
      _applyFocusFromPreview(focusId);
    }
  }

  /// Wave 35 — Preview → Studio focus handoff. Sets the focused exercise
  /// id in state, scrolls the matching card into view, and auto-expands
  /// it via the same path the user's tap on the card header would fire.
  /// Focus is session-only state; a `_clearFocus()` listener attached
  /// to scroll + tap will drop it on the next interaction.
  void _applyFocusFromPreview(String exerciseId) {
    final exercises = _session.exercises;
    final dataIndex = exercises.indexWhere((e) => e.id == exerciseId);
    if (dataIndex < 0) return;
    if (exercises[dataIndex].isRest) return;
    setState(() {
      _focusedExerciseId = exerciseId;
      _expandedIndex = dataIndex;
      _activeInsertIndex = null;
    });
    // Scroll the freshly-focused card into view AFTER the rebuild has
    // wired up the GlobalKey for that row. ensureVisible no-ops if the
    // key doesn't resolve to a Scrollable, so wrapping in addPostFrame
    // is the lightest belt-and-suspenders we can do.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final key = _rowKeys[exerciseId];
      final ctx = key?.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
        alignment: 0.5,
      );
    });
  }
}

// -----------------------------------------------------------------------------
// Rest bar — inline compact widget
// -----------------------------------------------------------------------------

class _RestBar extends StatefulWidget {
  final ExerciseCapture exercise;
  final ValueChanged<ExerciseCapture> onUpdate;
  final VoidCallback onDelete;

  const _RestBar({
    required this.exercise,
    required this.onUpdate,
    required this.onDelete,
  });

  @override
  State<_RestBar> createState() => _RestBarState();
}

class _RestBarState extends State<_RestBar> {
  bool _expanded = false;

  int get _duration => widget.exercise.restHoldSeconds ?? 30;

  static String _format(num v) {
    final seconds = v.round();
    if (seconds < 60) return '${seconds}s';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    if (s == 0) return '${m}m';
    return '${m}m${s}s';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.self_improvement,
                    size: 18,
                    color: AppColors.rest,
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'Rest',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.rest,
                    ),
                  ),
                  const Spacer(),
                  DashedUnderline(
                    child: Text(
                      _format(_duration),
                      style: TextStyle(
                        fontFamily: 'JetBrainsMono',
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: _expanded ? AppColors.primary : AppColors.rest,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
              child: PresetChipRow(
                controlKey: 'rest',
                canonicalPresets: const <num>[15, 30, 60, 90],
                currentValue: _duration,
                onChanged: (v) {
                  widget.onUpdate(
                    widget.exercise.copyWith(restHoldSeconds: v.round()),
                  );
                  setState(() => _expanded = false);
                },
                displayFormat: _format,
                accentColor: AppColors.rest,
                undoLabel: 'rest',
                // Wave 18.1 — non-scrolling chip row. The rest bar's
                // horizontal extent is the swipe-to-delete gesture path;
                // a horizontally-scrolling ListView would eat that swipe
                // before the outer Dismissible could see it.
                scrollable: false,
              ),
            ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Media viewer — unchanged in behaviour from the legacy file.
// -----------------------------------------------------------------------------

bool _isStillImageConversion(ExerciseCapture exercise) {
  final converted = exercise.convertedFilePath;
  if (converted == null) return false;
  final ext = converted.toLowerCase();
  return ext.endsWith('.jpg') || ext.endsWith('.jpeg') || ext.endsWith('.png');
}

/// Wave 35 — module-level inbox for the Preview → Studio focus handoff.
///
/// `MediaViewerBody` ("Preview" in user-facing copy) returns the id of the
/// exercise the practitioner was viewing at close-time so Studio can
/// scroll-into-view + auto-expand the matching card.
///
/// Two paths populate it:
///   1. The close × button calls `Navigator.pop(_focusIdForPop)` — the
///      parent's `await Navigator.push(...)` receives the id directly.
///   2. The system back gesture (iOS swipe-from-edge / Android back)
///      doesn't go through the close button; the route pops with a
///      null result. The viewer's `PopScope.onPopInvokedWithResult`
///      detects that case and stamps the id here so Studio can read
///      it after the await resolves to null.
///
/// Session-only state: never persisted, cleared every time the parent
/// reads it (so a fresh open of any unrelated route never inherits a
/// stale id).
/// Public exit inbox for the media viewer / preview body. Renamed from
/// `_MediaViewerExitInbox` so the new shared `MediaViewerBody` widget
/// (used both as a Studio route AND as the Preview tab in the
/// `ExerciseEditorSheet`) can stamp / read it from any host context.
class MediaViewerExitInbox {
  static String? lastClosedExerciseId;

  /// Read + clear the last-closed id atomically. Returns null when
  /// the inbox is empty (the close button took care of the handoff
  /// directly via `Navigator.pop(id)`).
  static String? takeLastClosedExerciseId() {
    final id = lastClosedExerciseId;
    lastClosedExerciseId = null;
    return id;
  }
}

/// Full-screen media viewer — the practitioner's "stand next to the
/// client and demo what each treatment looks like" surface.
///
/// Opened from a Studio thumbnail long-press → "Open full-screen". Pages
/// through every non-rest exercise in the session via PageView (rests
/// have no media). Each page is a photo or video; the video controller
/// is lazily created for the CURRENT page only and disposed when the
/// user swipes away, so memory stays bounded regardless of plan size.
///
/// Adds (R-10 does NOT apply here — practitioner-only surface):
///   • Vertical swipe cycles the active treatment with a 220ms crossfade.
///     Up = next (Line → B&W → Original → Line), Down = previous.
///     Disabled treatments are skipped over.
///   • Left-edge vertical [TreatmentSegmentedControl] — orientation
///     matches the vertical-swipe gesture so the visual control reads
///     the same axis as the gesture it represents. Locked segments (no
///     archive OR client said no) surface a short SnackBar pointing at
///     the client page, where consent now lives (Wave 3).
///   • Pre-archive captures (no `archiveFilePath`) keep B&W + Original
///     greyed out — Carl's call: don't fall back silently to Line, that
///     would mislead the practitioner during a "show me the difference"
///     demo.
class MediaViewerBody extends StatefulWidget {
  final List<ExerciseCapture> exercises;
  final int initialIndex;

  /// Fired whenever the practitioner changes the sticky preferred
  /// treatment on the current exercise (via vertical swipe OR a tap on
  /// the segmented control). The Studio screen wires this through
  /// `_updateExercise` so the in-memory session list — and the
  /// card-tile active ring — stay in sync with the SQLite row.
  ///
  /// The viewer itself is responsible for persisting via
  /// [LocalStorageService.saveExercise] so the write survives an
  /// immediate Close-before-refresh. The callback is an additional
  /// signal to the parent for UI coherence, not the primary persistence
  /// hop.
  final ValueChanged<ExerciseCapture>? onExerciseUpdate;

  /// Wave 27 — the parent session, source of crossfade timing values
  /// (and target for tuner writes). NULL only on legacy callsites; the
  /// tuner gear stays hidden when null so we never write through to a
  /// missing target.
  final Session? session;

  /// Wave 27 — fired when the tuner sliders / reset button update
  /// crossfade timings. Studio's `_pushSession` keeps the in-memory
  /// list aligned; the viewer also debounces a SQLite save through
  /// LocalStorageService so the value survives a viewer close before
  /// the parent's refresh.
  final ValueChanged<Session>? onSessionUpdate;

  /// Round 3 — true when this viewer is embedded inside the
  /// `ExerciseEditorSheet` Preview tab. Suppresses the top-right
  /// close (X) button (the sheet drag-down + tap-outside handle dismiss)
  /// and shifts the treatment-segment chrome down so it doesn't collide
  /// with the editor sheet's tab strip / body-focus + rotate pills.
  /// Defaults to false so the legacy full-screen route push is unchanged.
  final bool embeddedInSheet;

  const MediaViewerBody({
    super.key,
    required this.exercises,
    required this.initialIndex,
    this.onExerciseUpdate,
    this.session,
    this.onSessionUpdate,
    this.embeddedInSheet = false,
  });

  @override
  State<MediaViewerBody> createState() => _MediaViewerBodyState();
}

class _MediaViewerBodyState extends State<MediaViewerBody>
    with AutomaticKeepAliveClientMixin<MediaViewerBody> {
  @override
  bool get wantKeepAlive => true;

  late final PageController _pageController;
  late int _currentIndex;

  /// Mutable copy of the viewer's exercise list so preference writes
  /// reflect on the next page change without popping + re-pushing the
  /// route. Seeded from [widget.exercises] at initState.
  late List<ExerciseCapture> _exercises;

  /// Active treatment for the current page. Seeded from the exercise's
  /// stored `preferredTreatment` (null → Line). Every new page load
  /// re-reads from ITS OWN exercise, so moving to a neighbour does NOT
  /// carry the previous selection forward.
  Treatment _treatment = Treatment.line;

  /// Wave 27 — dual-video crossfade. Two VideoPlayerControllers point
  /// at the SAME source file; whichever is in the active slot is fully
  /// opaque, the other is held muted at frame 0 until preroll. On wrap
  /// detection slots swap, the fade duration comes from
  /// `session.crossfadeFadeMs ?? 200`. Mirrors `web-player/app.js` lines
  /// 1457-1620 conceptually, minus the rep-tick wiring (preview-only).
  VideoPlayerController? _videoControllerA;
  VideoPlayerController? _videoControllerB;

  /// 'a' or 'b' — whichever slot is currently visible and audio-bearing.
  String _activeSlot = 'a';

  /// True when the inactive slot has already been seeked + played for
  /// preroll on the current loop. Reset on every wrap so the next
  /// preroll fires exactly once per loop.
  bool _prebuffered = false;

  /// Last-seen position on the active controller. Used to detect a
  /// wrap (`position < lastPosition - duration/2`) which is the signal
  /// to swap slots. ms-precision is plenty for the seam window.
  int _lastActivePositionMs = 0;

  /// True once both slots have completed `initialize()` and the active
  /// has begun playback. Drives loading spinner vs. video render.
  bool _videoInitialized = false;

  /// Below this duration the wrap window is too short to crossfade
  /// gracefully; above this it's so long the second decode is wasted.
  /// Mirrors web `LOOP_CROSSFADE_MIN_DURATION` / `MAX_DURATION`.
  static const int _kCrossfadeMinDurationMs = 1200;
  static const int _kCrossfadeMaxDurationMs = 12000;

  /// Surface defaults when `session.crossfadeLeadMs` /
  /// `crossfadeFadeMs` are null. Mirrors the web player constants.
  static const int _kDefaultCrossfadeLeadMs = 250;
  static const int _kDefaultCrossfadeFadeMs = 200;

  /// Token used to ignore stale `initialize()` callbacks when the user
  /// swipes through treatments faster than a controller can come up.
  int _initToken = 0;

  /// Wave 27 — local mirror of the parent session so the tuner writes
  /// land in build() without waiting for a route pop. Seeded from
  /// widget.session in initState; null only when the parent didn't
  /// pass a session (legacy callsites — tuner gear hidden in that case).
  Session? _session;

  /// Whether the bottom-right play/pause control is currently visible.
  /// When paused, always true. When playing, true for ~2s after the last
  /// user interaction or state change, then fades out so the button
  /// doesn't clutter the demo-to-client view. Presence in the tree is
  /// unchanged — we only animate opacity so taps always hit.
  bool _controlsVisible = true;

  /// Auto-fade timer. Armed only while playing; cancelled on pause /
  /// user interaction / dispose.
  Timer? _controlsIdleTimer;

  /// Listener attached to the ACTIVE controller's value (whichever
  /// slot is currently visible). Tracks play/pause transitions that
  /// don't originate from `_togglePlayPause` AND drives the crossfade
  /// preroll + wrap-swap logic.
  VoidCallback? _videoListenerA;
  VoidCallback? _videoListenerB;
  bool _lastKnownIsPlaying = false;

  /// Wave 18 — the mute toggle is now a PERSISTENT per-exercise
  /// setting, not a transient viewer flag. [_isMuted] mirrors the
  /// current exercise's `!includeAudio` at init time and on every
  /// page change; tapping the pill writes through to
  /// `includeAudio` via [widget.onExerciseUpdate] AND
  /// `LocalStorageService.saveExercise` for durability across
  /// viewer-close-before-refresh.
  bool _isMuted = false;

  /// Wave 42 — Body Focus is now a per-exercise practitioner default
  /// stored on `ExerciseCapture.bodyFocus`. The previous Wave 25
  /// global per-device SharedPreferences flag is retired as a source
  /// of truth; see the [_enhancedBackground] getter below.

  /// Carl 2026-04-24: while a trim handle is being dragged, the video
  /// is paused and the practitioner can scrub. We remember whether
  /// the controller was playing pre-drag so we can resume on release.
  bool _trimDragWasPlaying = false;

  /// Wave 27 — suspends [_enforceTrimWindow] while a trim handle is
  /// mid-drag. Right-handle drags seek to the new end, the listener
  /// then sees `position >= endMs` and would yank back to start; this
  /// flag breaks that loop without affecting normal playback wrap.
  bool _trimDragInProgress = false;

  /// Wave 20 — debounce for the trim-panel SQLite write. The drag
  /// callback fires every gesture tick; we coalesce to one write per
  /// 200 ms so the disk doesn't take a beating during a long drag.
  Timer? _trimSaveTimer;

  /// 2026-05-03 — debounce for the Hero-frame SQLite + thumbnail-regen
  /// pass. Mirrors `_trimSaveTimer` but routes through
  /// `ConversionService.regenerateHeroThumbnails` (which itself writes
  /// the row + emits an update on the conversion stream). 250 ms keeps
  /// the regen idle until the practitioner stops scrubbing.
  Timer? _heroSaveTimer;

  /// 2026-05-03 — currently-selected trim-panel handle. Drives the
  /// white→coral fill swap + tooltip on the chosen handle. Cleared
  /// on tap-on-video and on play/resume so the panel reverts to the
  /// "all white during play" rule.
  _TrimHandle? _selectedTrimHandle;

  /// Wave 27 — debounce for the crossfade-tuner SQLite write. Slider
  /// drags emit one event per pixel; coalesce to one save per 250 ms.
  Timer? _crossfadePersistTimer;

  ExerciseCapture get _current => _exercises[_currentIndex];

  bool _isVideo(ExerciseCapture e) =>
      e.mediaType == MediaType.video && !_isStillImageConversion(e);

  /// True when the raw capture is a local file on disk (not a remote
  /// URL placeholder for a cloud-only session). Distinguishes a fresh
  /// capture that's still being archived by ConversionService from a
  /// session pulled from the cloud whose raw file needs downloading —
  /// the former gets a "still processing" toast on locked-segment tap;
  /// the latter triggers a signed-URL prefetch.
  bool _rawIsLocal(ExerciseCapture e) {
    final raw = e.absoluteRawFilePath;
    if (raw.isEmpty || raw.startsWith('http')) return false;
    return File(raw).existsSync();
  }

  /// True when the local raw source exists for this exercise — gates
  /// the B&W + Original treatment segments. For VIDEOS this is the
  /// 720p H.264 archive mp4 written by `compressVideo`. For PHOTOS
  /// (Wave 34) it's the raw color JPG (the color photo always exists
  /// on a fresh capture; "no archive" only happens for legacy photo
  /// rows whose raw file got pruned). Same binary contract as before:
  /// when this is false, the segmented control locks B&W + Original.
  bool _hasArchive(ExerciseCapture e) {
    if (_isVideo(e)) {
      final path = e.absoluteArchiveFilePath;
      if (path == null) return false;
      return File(path).existsSync();
    }
    // Photo path — Wave 34 unlocks treatment switching for photos.
    // The raw colour JPG is the source for both "Original" and "B&W"
    // treatments (B&W applies a `ColorFiltered` grayscale on top, no
    // separate file). Defensive `existsSync` so a pruned-on-disk
    // photo still falls back to line drawing rather than crashing.
    // Also defensive against the exotic "video converted to a still"
    // case where rawFilePath points at a .mov — those rows have no
    // colour photo to swap to, so leave the segments locked.
    final raw = e.absoluteRawFilePath;
    if (raw.isEmpty) return false;
    final ext = raw.toLowerCase();
    final rawIsImage =
        ext.endsWith('.jpg') ||
        ext.endsWith('.jpeg') ||
        ext.endsWith('.png') ||
        ext.endsWith('.heic');
    if (!rawIsImage) return false;
    return File(raw).existsSync();
  }

  bool _isTreatmentAvailable(Treatment t) {
    switch (t) {
      case Treatment.line:
        return true;
      case Treatment.grayscale:
      case Treatment.original:
        return _hasArchive(_current);
    }
  }

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _exercises = List<ExerciseCapture>.from(widget.exercises);
    _session = widget.session;
    _pageController = PageController(initialPage: _currentIndex);
    // Seed from the opening exercise's stored preference so the viewer
    // lands on the treatment the practitioner last chose. Falls back to
    // Line when `preferredTreatment == null` (the default).
    _treatment = _effectiveTreatmentFor(_current);
    // Wave 18 — mute is now a persistent setting, not a transient flag.
    // Seed from the current exercise's includeAudio (muted = !includeAudio).
    _isMuted = !_current.includeAudio;
    _initVideoForCurrent();
  }

  @override
  void didUpdateWidget(covariant MediaViewerBody old) {
    super.didUpdateWidget(old);
    // Wave 27 — keep the local session mirror in sync if the parent
    // pushes a fresh copy (e.g. after publish version-bump). Don't
    // overwrite while a debounced tuner write is pending — the parent
    // would re-emit our pending value after `saveSession` resolves and
    // would miss intermediate slider drags.
    final pending = _crossfadePersistTimer;
    if (old.session != widget.session &&
        (pending == null || !pending.isActive)) {
      _session = widget.session;
    }
  }

  /// Wave 42 — Body Focus reads from the per-exercise
  /// `bodyFocus` field. NULL → render with body-focus ON (the
  /// pre-feature default; legacy rows stay unchanged on first open).
  ///
  /// Per-exercise: switching pages re-reads ITS OWN value, so the
  /// pill state matches whatever the practitioner set on that
  /// specific exercise.
  bool get _enhancedBackground => _current.bodyFocus ?? true;

  /// Whether the Body Focus pill is meaningful for the current
  /// exercise + treatment. Line drawings have no background to dim,
  /// so the pill greys out + ignores taps when [_treatment] is
  /// [Treatment.line]. Photos / rest rows hide the pill entirely (the
  /// build() guard piggy-backs on `_isVideo`).
  bool get _enhancedBackgroundEnabled => _treatment != Treatment.line;

  /// Wave 42 — toggle the per-exercise Body Focus default. Writes to
  /// the local `ExerciseCapture.bodyFocus` field, persists through
  /// [LocalStorageService.saveExercise], bubbles to the parent so the
  /// Studio card mirror stays in sync, propagates the new value into
  /// the client's sticky defaults so the next new capture inherits
  /// it, and rebinds the active video so the new source loads. Same
  /// shape as the existing per-exercise mute / treatment writes.
  void _onEnhancedBackgroundToggle() {
    if (!_enhancedBackgroundEnabled) return;
    HapticFeedback.selectionClick();
    final before = _current;
    final next = !(before.bodyFocus ?? true);
    final updated = before.copyWith(bodyFocus: next);
    setState(() {
      _exercises[_currentIndex] = updated;
    });
    final cb = widget.onExerciseUpdate;
    if (cb != null) cb(updated);
    unawaited(
      SyncService.instance.storage.saveExercise(updated).catchError((e, _) {
        debugPrint('MediaViewer: saveExercise(bodyFocus) failed: $e');
      }),
    );
    // Wave 42 — propagate into client sticky defaults so the next new
    // capture inherits the latest choice.
    StickyDefaults.recordOverride(
      clientId: widget.session?.clientId,
      field: StickyDefaults.fBodyFocus,
      value: next,
    );
    // Rebind so the new source loads. _initVideoForCurrent rebuilds
    // the controller from scratch — same pattern the treatment switch
    // uses.
    if (_isVideo(_current)) {
      _initVideoForCurrent();
    }
  }

  /// Resolve the treatment to render for [e]: stored preference if set
  /// AND available (archive present for B&W / Original), otherwise
  /// [Treatment.line].
  ///
  /// If the stored preference is no longer available (e.g. the archive
  /// was purged after 90 days), we silently fall back to Line rather
  /// than showing a broken black frame.
  Treatment _effectiveTreatmentFor(ExerciseCapture e) {
    final pref = e.preferredTreatment;
    if (pref == null) return Treatment.line;
    if (pref == Treatment.line) return Treatment.line;
    // B&W / Original require a local archive.
    return _hasArchive(e) ? pref : Treatment.line;
  }

  /// Source file the active treatment should play.
  ///
  ///   • [Treatment.line] → the on-device line drawing converted file
  ///     (stored locally, always present once conversion is done). The
  ///     Enhanced Background flag is irrelevant — line drawings have
  ///     no background tone to dim.
  ///   • [Treatment.grayscale] / [Treatment.original] → the raw archive
  ///     mp4 (the grayscale rendering is a widget-level [ColorFiltered]
  ///     on top, no second source needed).
  ///
  /// Wave 25 — segmented playback parity with the web player. When
  /// [_enhancedBackground] is true (default) AND a segmented raw file
  /// exists locally, prefer the segmented variant (same Vision body
  /// mask the line drawing uses, body-pop + dimmed background). When
  /// false or when the segmented file is missing (legacy captures
  /// pre-v22, conversion failed), fall through to the untouched
  /// archive so practitioner playback never goes black.
  String? _sourcePathForTreatment(ExerciseCapture e, Treatment t) {
    switch (t) {
      case Treatment.line:
        return e.displayFilePath;
      case Treatment.grayscale:
      case Treatment.original:
        if (_enhancedBackground) {
          final seg = e.absoluteSegmentedRawFilePath;
          if (seg != null && File(seg).existsSync()) return seg;
        }
        return e.absoluteArchiveFilePath;
    }
  }

  /// Wave 27 — bring up BOTH crossfade slots from the same source path.
  /// Slot 'a' becomes active (visible + audio); slot 'b' is paused at
  /// frame 0, muted, ready for preroll. Single source file → both
  /// controllers point at the same `File` so the iOS H.264 decoder runs
  /// two simultaneous instances on the SAME bytes; AVFoundation handles
  /// this fine on real hardware (worth a memory-pressure follow-up if
  /// QA flags it on older devices).
  void _initVideoForCurrent() {
    final previousA = _videoControllerA;
    final previousB = _videoControllerB;
    final previousListenerA = _videoListenerA;
    final previousListenerB = _videoListenerB;
    if (previousListenerA != null) previousA?.removeListener(previousListenerA);
    if (previousListenerB != null) previousB?.removeListener(previousListenerB);
    previousA?.dispose();
    previousB?.dispose();
    _videoControllerA = null;
    _videoControllerB = null;
    _videoListenerA = null;
    _videoListenerB = null;
    _videoInitialized = false;
    _activeSlot = 'a';
    _prebuffered = false;
    _lastActivePositionMs = 0;
    if (!_isVideo(_current)) return;
    final path = _sourcePathForTreatment(_current, _treatment);
    if (path == null) return;
    final token = ++_initToken;
    final controllerA = VideoPlayerController.file(File(path));
    final controllerB = VideoPlayerController.file(File(path));
    _videoControllerA = controllerA;
    _videoControllerB = controllerB;
    Future.wait<void>([controllerA.initialize(), controllerB.initialize()])
        .then((_) {
          // Bail when the user swiped away or cycled treatments before init
          // resolved — adopting stale controllers would leak both.
          if (!mounted || token != _initToken) {
            controllerA.dispose();
            controllerB.dispose();
            return;
          }
          setState(() {
            _videoInitialized = true;
            _lastKnownIsPlaying = false;
          });
          // Native looping handles the short-clip / long-clip fallback
          // (clips outside the [_kCrossfadeMin, _kCrossfadeMax] window
          // skip the dual-video path entirely; the listener bails before
          // touching the inactive slot).
          controllerA.setLooping(true);
          controllerB.setLooping(true);
          controllerA.setVolume(_isMuted ? 0.0 : 1.0);
          controllerB.setVolume(0.0); // inactive stays muted always.
          _seekToTrimStart(controllerA);
          _seekToTrimStart(controllerB);
          // Listeners on BOTH controllers so trim enforcement runs whether
          // A or B is currently visible. _maybeCrossfade only fires for the
          // controller that is currently active (per-tick check).
          void listenerA() => _onVideoStateChanged(controllerA, token);
          void listenerB() => _onVideoStateChanged(controllerB, token);
          controllerA.addListener(listenerA);
          controllerB.addListener(listenerB);
          _videoListenerA = listenerA;
          _videoListenerB = listenerB;
          controllerA.play();
          _showControlsThenMaybeIdleFade();
        })
        .catchError((e) {
          debugPrint('MediaViewer: video init failed for $path — $e');
        });
  }

  /// Returns whichever controller is in the [_activeSlot] (visible +
  /// audio-bearing). Null when the slots haven't been initialised yet.
  VideoPlayerController? get _activeController =>
      _activeSlot == 'a' ? _videoControllerA : _videoControllerB;

  /// Returns the inactive (offscreen, muted, prebuffer-ready) slot.
  VideoPlayerController? get _inactiveController =>
      _activeSlot == 'a' ? _videoControllerB : _videoControllerA;

  /// Resolved crossfade lead time, ms. Reads live from `_session` so
  /// slider drags take effect on the next listener tick.
  int get _crossfadeLeadMs =>
      _session?.crossfadeLeadMs ?? _kDefaultCrossfadeLeadMs;

  /// Resolved crossfade fade duration, ms. Drives the AnimatedOpacity
  /// transition; reads live from `_session` so the visual swap timing
  /// updates immediately while tuning.
  int get _crossfadeFadeMs =>
      _session?.crossfadeFadeMs ?? _kDefaultCrossfadeFadeMs;

  /// Listeners are attached to BOTH controllers. Trim enforcement runs
  /// on whichever ticked (so the inactive can't run off into untrimmed
  /// territory while it's prerolled). Crossfade preroll + wrap-swap
  /// only runs for the currently-active controller.
  void _onVideoStateChanged(VideoPlayerController controller, int token) {
    if (!mounted || token != _initToken) return;
    _enforceTrimWindow(controller);
    if (identical(controller, _activeController)) {
      _maybeCrossfade(controller);
      final isPlaying = controller.value.isPlaying;
      if (isPlaying != _lastKnownIsPlaying) {
        _lastKnownIsPlaying = isPlaying;
        _showControlsThenMaybeIdleFade();
      }
    }
  }

  /// Wave 27 — preroll + wrap-swap. Mirrors `web-player/app.js`
  /// `LOOP_CROSSFADE_LEAD_MS` logic:
  ///   * outside the [_kCrossfadeMinDurationMs, _kCrossfadeMaxDurationMs]
  ///     window → no-op (native loop handles it).
  ///   * `(dur - pos) <= leadMs` and not yet prebuffered → seek inactive
  ///     to start, play it muted. Sets [_prebuffered] so we don't
  ///     re-prime mid-loop.
  ///   * `pos < lastPos - dur/2` → wrap detected. Swap [_activeSlot],
  ///     reset [_prebuffered], copy active volume to the new active so
  ///     audio handoff is seamless, mute the new inactive.
  void _maybeCrossfade(VideoPlayerController active) {
    // Trim drag drives explicit seeks on the active controller. Letting
    // the swap-on-wrap heuristic fire mid-drag flips _activeSlot mid-
    // gesture; the panel's onDragEnd then resumes the wrong controller.
    if (_trimDragInProgress) return;
    final durationMs = active.value.duration.inMilliseconds;
    // Trim window collapses the effective loop end. Without this the
    // preroll waits for natural duration but `_enforceTrimWindow` wraps
    // first — crossfade never fires inside a trimmed clip.
    final trimStart = _current.startOffsetMs;
    final trimEnd = _current.endOffsetMs;
    final hasTrim = trimStart != null && trimEnd != null && trimEnd > trimStart;
    final effectiveStartMs = hasTrim ? trimStart : 0;
    final effectiveEndMs = hasTrim ? trimEnd : durationMs;
    final effectiveWindowMs = effectiveEndMs - effectiveStartMs;
    if (effectiveWindowMs < _kCrossfadeMinDurationMs ||
        effectiveWindowMs > _kCrossfadeMaxDurationMs) {
      return;
    }
    final positionMs = active.value.position.inMilliseconds;
    final inactive = _inactiveController;
    if (inactive == null) return;

    // Wrap detection runs before preroll: a fresh wrap implicitly
    // means the previous loop's preroll already fired. Threshold uses
    // the trim window so a 2 s loop inside a 30 s file still detects.
    if (positionMs < _lastActivePositionMs - effectiveWindowMs ~/ 2) {
      _swapSlots();
      _lastActivePositionMs = positionMs;
      return;
    }
    _lastActivePositionMs = positionMs;

    if (!_prebuffered && (effectiveEndMs - positionMs) <= _crossfadeLeadMs) {
      _prebuffered = true;
      inactive.seekTo(Duration(milliseconds: effectiveStartMs));
      inactive.setVolume(0.0);
      inactive.play();
    }
  }

  /// Flip [_activeSlot] and rewire audio so the new active slot picks
  /// up the muted/unmuted state of the user's preference. The inactive
  /// gets pushed back to volume=0 and loses prebuffer status.
  void _swapSlots() {
    final outgoingActive = _activeController;
    final incomingActive = _inactiveController;
    if (outgoingActive == null || incomingActive == null) return;
    final volume = _isMuted ? 0.0 : 1.0;
    setState(() {
      _activeSlot = _activeSlot == 'a' ? 'b' : 'a';
      _prebuffered = false;
      // Reset wrap-detect baseline so the new active's first tick
      // doesn't false-fire against the outgoing's last position.
      _lastActivePositionMs = 0;
    });
    // Listeners stay on both controllers (attached at init). No move.
    incomingActive.setVolume(volume);
    // Park the outgoing slot at trim-start so the next preroll is one
    // seek away. Pause halts the second decoder during the fade-out
    // window — saves cycles on older devices.
    final trimStart = _current.startOffsetMs;
    final trimEnd = _current.endOffsetMs;
    final hasTrim = trimStart != null && trimEnd != null && trimEnd > trimStart;
    final parkMs = hasTrim ? trimStart : 0;
    outgoingActive.pause();
    outgoingActive.setVolume(0.0);
    outgoingActive.seekTo(Duration(milliseconds: parkMs));
  }

  /// Soft-trim clamp. Idempotent — called from the controller listener
  /// every time `position` advances. When the active exercise has both
  /// offsets set, wraps the loop so playback never escapes the window:
  ///
  ///   * position >= endOffsetMs → seek back to startOffsetMs
  ///     (preserves play state).
  ///   * position < startOffsetMs → seek forward to startOffsetMs
  ///     (covers the rare case where a stale frame leaks in before the
  ///     init seek lands).
  ///
  /// Treats null offsets as "no clamp" so legacy rows (and untrimmed
  /// captures) play through normally.
  void _enforceTrimWindow(VideoPlayerController controller) {
    // Wave 27 — while a trim handle is being dragged, the right-handle
    // seek would re-enter as `position >= endMs` and yank to start.
    if (_trimDragInProgress) return;
    final exercise = _current;
    final startMs = exercise.startOffsetMs;
    final endMs = exercise.endOffsetMs;
    if (startMs == null || endMs == null) return;
    if (endMs <= startMs) return; // pathological — fall through to no clamp.
    final positionMs = controller.value.position.inMilliseconds;
    if (positionMs >= endMs) {
      // Wrap to start. Keep the loop seamless — don't pause/play, just
      // reseat the head. seekTo here is async; subsequent ticks ignore
      // the duplicate-seek case via the >= check.
      controller.seekTo(Duration(milliseconds: startMs));
    } else if (positionMs < startMs) {
      controller.seekTo(Duration(milliseconds: startMs));
    }
  }

  /// Initial seek into the trim window when a new controller comes up.
  /// Called after `initialize()` resolves but before `play()` so the
  /// first painted frame is already inside the window.
  void _seekToTrimStart(VideoPlayerController controller) {
    final startMs = _current.startOffsetMs;
    final endMs = _current.endOffsetMs;
    if (startMs == null || endMs == null) return;
    if (endMs <= startMs) return;
    controller.seekTo(Duration(milliseconds: startMs));
  }

  /// Bring the button to full opacity, then (only if playing) arm a
  /// 2-second timer to fade it away. When paused the button stays
  /// visible indefinitely.
  void _showControlsThenMaybeIdleFade() {
    _controlsIdleTimer?.cancel();
    if (!mounted) return;
    setState(() => _controlsVisible = true);
    final c = _activeController;
    if (c == null || !_videoInitialized) return;
    if (!c.value.isPlaying) return;
    _controlsIdleTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      final controller = _activeController;
      if (controller == null || !controller.value.isPlaying) return;
      setState(() => _controlsVisible = false);
    });
  }

  @override
  void dispose() {
    _controlsIdleTimer?.cancel();
    _trimSaveTimer?.cancel();
    _heroSaveTimer?.cancel();
    _crossfadePersistTimer?.cancel();
    _rotationPersistTimer?.cancel();
    final listenerA = _videoListenerA;
    final listenerB = _videoListenerB;
    if (listenerA != null) _videoControllerA?.removeListener(listenerA);
    if (listenerB != null) _videoControllerB?.removeListener(listenerB);
    _videoControllerA?.dispose();
    _videoControllerB?.dispose();
    _pageController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Wave 20 — soft-trim editor wiring
  // ---------------------------------------------------------------------------

  /// Whether the trim panel should render for the current page. Hidden
  /// for: photos, rest rows, video duration < 1s. The host build()
  /// guards every callsite with this so the bottom chrome falls back
  /// to its original positions when the panel is absent.
  bool get _trimPanelVisible {
    if (!_isVideo(_current)) return false;
    if (!_videoInitialized) return false;
    final c = _activeController;
    if (c == null) return false;
    final durMs = c.value.duration.inMilliseconds;
    return durMs >= 1000;
  }

  /// Single shared offset added to every bottom chrome element when the
  /// trim panel is present. Panel height + 8 px gap. Compact = landscape
  /// shorter panel.
  double _bottomChromeTrimLiftFor({required bool compact}) => _trimPanelVisible
      ? (_TrimPanel.effectiveHeight(compact: compact) + 8)
      : 0;

  /// Optimistic update of the in-memory trim values + debounced disk
  /// write. Mirrors the pattern used for `_persistPreferredTreatment` /
  /// `_toggleMute`: bubble up to the parent for UI coherence, save to
  /// SQLite on a short delay so a long drag doesn't hammer the disk.
  void _persistTrim(int? startMs, int? endMs) {
    final exercise = _current;
    final updated = exercise.copyWith(
      startOffsetMs: startMs,
      endOffsetMs: endMs,
      clearStartOffsetMs: startMs == null,
      clearEndOffsetMs: endMs == null,
    );
    setState(() {
      _exercises[_currentIndex] = updated;
    });
    final cb = widget.onExerciseUpdate;
    if (cb != null) cb(updated);
    _trimSaveTimer?.cancel();
    _trimSaveTimer = Timer(const Duration(milliseconds: 200), () {
      unawaited(
        SyncService.instance.storage.saveExercise(updated).catchError((e, _) {
          debugPrint('MediaViewer: saveExercise(soft_trim) failed: $e');
        }),
      );
    });
  }

  void _resetTrim() {
    _persistTrim(null, null);
  }

  void _onTrimScrub(int positionMs) {
    final c = _activeController;
    if (c == null || !_videoInitialized) return;
    // Selecting / scrubbing always pauses the active video so the chosen
    // frame holds steady — mockup spec is explicit: tap-handle pauses,
    // tap-video-anywhere-else resumes.
    if (c.value.isPlaying) c.pause();
    _inactiveController?.pause();
    c.seekTo(Duration(milliseconds: positionMs));
  }

  /// 2026-05-03 — host-side wiring for the Hero handle on the trim
  /// panel. Optimistic update of the in-memory `focusFrameOffsetMs` +
  /// debounced thumbnail regen. Mirrors `_persistTrim`: bubble to parent
  /// for UI coherence, then schedule the heavy regen so a long drag
  /// doesn't kick off a regen on every gesture tick.
  ///
  /// `regenerateHeroThumbnails` writes the row, re-extracts the three
  /// treatment thumbnails, AND emits the updated exercise on the
  /// conversion stream — Studio cards refresh on the next paint.
  void _persistHero(int heroMs) {
    final exercise = _current;
    if (exercise.mediaType != MediaType.video) return;
    if (exercise.focusFrameOffsetMs == heroMs) return;
    final updated = exercise.copyWith(focusFrameOffsetMs: heroMs);
    setState(() {
      _exercises[_currentIndex] = updated;
    });
    final cb = widget.onExerciseUpdate;
    if (cb != null) cb(updated);
    _heroSaveTimer?.cancel();
    _heroSaveTimer = Timer(const Duration(milliseconds: 250), () {
      // Read by id off the live list so a navigate-next mid-debounce
      // doesn't regen against a stale exercise.
      final idx = _exercises.indexWhere((e) => e.id == exercise.id);
      if (idx < 0) return;
      final fresh = _exercises[idx];
      unawaited(
        ConversionService.instance
            .regenerateHeroThumbnails(fresh, heroMs)
            .then((next) {
          if (!mounted) return;
          // Bubble the regen-result (it has the freshly-written
          // thumbnailPath) so list-card surfaces pick up the new
          // poster without waiting for a full session reload.
          final freshIdx = _exercises.indexWhere((e) => e.id == next.id);
          if (freshIdx < 0) return;
          setState(() {
            _exercises[freshIdx] = next;
          });
          final cb2 = widget.onExerciseUpdate;
          if (cb2 != null) cb2(next);
        }).catchError((e, _) {
          debugPrint('MediaViewer: regenerateHeroThumbnails failed: $e');
        }),
      );
    });
  }

  /// Selection swap on the trim panel. Stored in host state so a
  /// rebuild (treatment cycle, etc.) preserves which handle is "holding"
  /// the playhead.
  void _onTrimSelectionChanged(_TrimHandle? handle) {
    if (_selectedTrimHandle == handle) return;
    setState(() => _selectedTrimHandle = handle);
  }

  void _onPageChanged(int index) {
    setState(() {
      _currentIndex = index;
      // Each exercise uses ITS OWN stored preference — moving to the
      // next exercise does NOT carry the previous treatment over. If
      // this exercise has never been cycled, preferredTreatment is
      // null and we render Line (the safe baseline).
      _treatment = _effectiveTreatmentFor(_current);
      // Wave 18 — mute also re-reads from THIS exercise's
      // includeAudio, so swiping to a neighbour updates the pill
      // glyph + the video volume in lockstep.
      _isMuted = !_current.includeAudio;
      // Trim-handle selection is per-exercise — clear it so the next
      // exercise doesn't open with a stale coral selection painted on
      // first frame.
      _selectedTrimHandle = null;
    });
    _initVideoForCurrent();
  }

  /// Switch to [next] — caller has already checked availability.
  /// Disposes the active controller and re-inits with the new source.
  /// The crossfade itself is handled by the [AnimatedSwitcher] keyed
  /// off the treatment name.
  ///
  /// Persists the new treatment as the exercise's sticky preference.
  /// Writes to local SQLite immediately; the cloud copy is updated on
  /// the next publish (the exercises table is publish-scoped, no
  /// mid-session sync path).
  void _onTreatmentChanged(Treatment next) {
    if (next == _treatment) return;
    HapticFeedback.selectionClick();
    setState(() => _treatment = next);
    _persistPreferredTreatment(next);
    _initVideoForCurrent();
  }

  /// Write [next] to the active exercise's `preferredTreatment` field.
  /// Also bubbles the updated exercise up via [widget.onExerciseUpdate]
  /// so the Studio screen's in-memory list stays in sync.
  ///
  /// Idempotent — called every time the treatment changes; if the new
  /// value equals the stored value the write is still performed (cheap
  /// and reinforces the "user's explicit choice wins" invariant from
  /// the task brief: flipping back to Line is a real preference, not a
  /// reset-to-default).
  void _persistPreferredTreatment(Treatment next) {
    final exercise = _current;
    final updated = exercise.copyWith(preferredTreatment: next);
    // Update the in-memory list so a subsequent page-change back to
    // this index reads the new preference without a DB round-trip.
    _exercises[_currentIndex] = updated;
    final cb = widget.onExerciseUpdate;
    if (cb != null) cb(updated);
    // Fire-and-forget local write. Errors logged; no UI surfaces
    // because the user has already seen the optimistic state change.
    // Uses SyncService.instance.storage instead of plumbing a fresh
    // LocalStorageService handle through the MediaViewerBody constructor
    // — same singleton the rest of the app shares.
    unawaited(
      SyncService.instance.storage.saveExercise(updated).catchError((e, _) {
        debugPrint('MediaViewer: saveExercise(preferred_treatment) failed: $e');
      }),
    );
  }

  /// Cycle to the next available treatment in the given direction.
  /// `delta = +1` advances (Line → B&W → Original → Line).
  /// `delta = -1` reverses. Disabled treatments are skipped — if no
  /// treatment besides Line is available the call is a no-op.
  void _cycleTreatment(int delta) {
    const order = Treatment.values; // line, grayscale, original
    var idx = order.indexOf(_treatment);
    for (var step = 0; step < order.length; step++) {
      idx = (idx + delta) % order.length;
      if (idx < 0) idx += order.length;
      final candidate = order[idx];
      if (_isTreatmentAvailable(candidate)) {
        _onTreatmentChanged(candidate);
        return;
      }
    }
    // Only Line is available — nothing to cycle to.
  }

  void _togglePlayPause() {
    final active = _activeController;
    if (active == null || !_videoInitialized) return;
    final wasPlaying = active.value.isPlaying;
    setState(() {
      if (wasPlaying) {
        active.pause();
        // Halt the prerolled inactive too — preroll resumes naturally on
        // the next cycle once playback restarts.
        _inactiveController?.pause();
        _prebuffered = false;
      } else {
        active.play();
        // Mockup spec: tap-the-video → resume playback AND clear any
        // current trim-handle selection. During play all handles stay
        // white; the playback flash is the only "you just passed it"
        // cue.
        _selectedTrimHandle = null;
      }
    });
    // Any tap — on the video body or the overlay button — resets the
    // idle timer. If we paused, the button stays visible; if we started
    // playing, it fades after 2s.
    _showControlsThenMaybeIdleFade();
  }

  /// Toggle the mute state. Decoupled from play/pause — the video
  /// keeps playing through a mute tap (Wave 3 decouple).
  ///
  /// Wave 18 — the tap now PERSISTS. `includeAudio` flips on the
  /// current exercise, the change propagates up via
  /// [widget.onExerciseUpdate] (Studio card mirror), and we fire-
  /// and-forget a [LocalStorageService.saveExercise] so the write
  /// survives an immediate close before the Studio refresh runs.
  void _toggleMute() {
    HapticFeedback.selectionClick();
    final nextMuted = !_isMuted;
    setState(() => _isMuted = nextMuted);
    // Active gets the user's volume; inactive stays muted always so the
    // ~250 ms preroll overlap doesn't double up audio.
    _activeController?.setVolume(nextMuted ? 0.0 : 1.0);
    _inactiveController?.setVolume(0.0);
    _showControlsThenMaybeIdleFade();

    // Persist through to the exercise row + parent list.
    final exercise = _current;
    final updated = exercise.copyWith(includeAudio: !nextMuted);
    _exercises[_currentIndex] = updated;
    final cb = widget.onExerciseUpdate;
    if (cb != null) cb(updated);
    unawaited(
      SyncService.instance.storage.saveExercise(updated).catchError((e, _) {
        debugPrint('MediaViewer: saveExercise(includeAudio) failed: $e');
      }),
    );
  }

  String _headerLabel(ExerciseCapture e, int index) {
    final n = e.name;
    if (n != null && n.trim().isNotEmpty) return n;
    return 'Exercise ${index + 1}';
  }

  /// Vertical-swipe handler. A flick of >300 px/s in either direction
  /// cycles the treatment. The threshold is loose enough that a casual
  /// flick reads, but tight enough that a horizontal swipe (handed off
  /// to the PageView) doesn't accidentally trigger.
  void _handleVerticalDragEnd(DragEndDetails details) {
    final v = details.primaryVelocity ?? 0;
    if (v.abs() < 300) return;
    // Negative velocity = upward swipe = next treatment.
    _cycleTreatment(v < 0 ? 1 : -1);
  }

  /// Wave 35 — id of the exercise the practitioner was viewing at the
  /// moment they closed the viewer. Returned via `Navigator.pop(id)` so
  /// the parent Studio screen can scroll-into-view + auto-expand the
  /// matching card. Returning the id (not the index) keeps the handoff
  /// stable against reorders that may have happened inside the viewer
  /// (preferred-treatment writes don't reorder, but this is safer.)
  String? get _focusIdForPop {
    if (_exercises.isEmpty) return null;
    if (_currentIndex < 0 || _currentIndex >= _exercises.length) return null;
    return _exercises[_currentIndex].id;
  }

  @override
  Widget build(BuildContext context) {
    // AutomaticKeepAliveClientMixin contract — required so the State
    // is registered with the enclosing PageView's keep-alive scope.
    // Without this the Preview tab in `ExerciseEditorSheet` would be
    // disposed when the practitioner swipes to Plan / Notes / Settings,
    // killing the video controllers + treatment listeners mid-edit
    // (the same gotcha that caused the photo-spinner regression).
    super.build(context);
    final hasArchive = _hasArchive(_current);
    // Wave 28 — viewer is the one Studio surface that allows landscape
    // (the editor stays portrait-locked). Both rotations + portraitUp;
    // upside-down stays excluded so the device-rotation animation feels
    // intentional instead of glitchy.
    return PopScope<Object?>(
      // canPop stays true — we don't want to block the gesture, only
      // observe it so we can substitute the result when the system
      // pops without going through the close button. Using
      // onPopInvokedWithResult (Flutter 3.22+) so we can detect that
      // the system pop already returned `null` and re-pop with the
      // exercise id. The `didPop` guard prevents the catch from
      // firing when the close button explicitly popped with the id.
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) return;
        if (result != null) return;
        final id = _focusIdForPop;
        if (id == null) return;
        // Re-push the id via the post-pop notification path. The
        // route is already gone from the stack, so we can't call
        // Navigator.pop again — instead, surface the id via the
        // `RouteSettings.arguments` channel we registered when the
        // viewer was pushed. We cheat slightly: the parent's
        // `_openMediaViewer` reads `lastFocusedExerciseId` off a
        // module-level inbox that this PopScope writes to.
        MediaViewerExitInbox.lastClosedExerciseId = id;
      },
      child: OrientationLockGuard(
        allowed: const {
          DeviceOrientation.portraitUp,
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        },
        child: Scaffold(
          backgroundColor: AppColors.surfaceBg,
          body: OrientationBuilder(
            builder: (context, orientation) {
              final isLandscape = orientation == Orientation.landscape;
              return Stack(
                fit: StackFit.expand,
                children: [
                  // Pager — one page per non-rest exercise. Vertical swipes
                  // tunnelled into the GestureDetector cycle the treatment;
                  // horizontal swipes pass through to the PageView.
                  PageView.builder(
                    controller: _pageController,
                    itemCount: _exercises.length,
                    onPageChanged: _onPageChanged,
                    itemBuilder: (context, index) {
                      final ex = _exercises[index];
                      final isCurrent = index == _currentIndex;
                      final isVideo = _isVideo(ex);
                      return GestureDetector(
                        onVerticalDragEnd: isCurrent
                            ? _handleVerticalDragEnd
                            : null,
                        onTap: isCurrent && isVideo ? _togglePlayPause : null,
                        behavior: HitTestBehavior.opaque,
                        child: Center(
                          child: isVideo
                              ? (isCurrent
                                    ? AnimatedSwitcher(
                                        duration: const Duration(
                                          milliseconds: 220,
                                        ),
                                        switchInCurve: Curves.easeOut,
                                        switchOutCurve: Curves.easeIn,
                                        child: _buildVideoFrame(),
                                      )
                                    : const _VideoPagePlaceholder())
                              : _buildPhotoFrame(ex, isCurrent: isCurrent),
                        ),
                      );
                    },
                  ),

                  // Treatment segmented pill — vertical book-spine in
                  // portrait (mirrors the vertical-swipe gesture); flat
                  // horizontal pill at top-center under the name pill in
                  // landscape (matches the wider canvas ergonomics).
                  //
                  // Wave 34 — also rendered for PHOTOS (was video-only
                  // through Wave 33). The cloud already shipped photos in
                  // three treatments via Wave 22; the mobile preview chrome
                  // was the missing piece.
                  if (!_current.isRest)
                    isLandscape
                        ? Positioned(
                            top: MediaQuery.of(context).padding.top + 64,
                            left: 0,
                            right: 0,
                            child: SafeArea(
                              top: false,
                              child: Center(
                                child: SizedBox(
                                  width: 260,
                                  child: TreatmentSegmentedControl(
                                    orientation: Axis.horizontal,
                                    active: _treatment,
                                    grayscaleAvailable: hasArchive,
                                    originalAvailable: hasArchive,
                                    onChanged: _onTreatmentChanged,
                                    onLockTap: _onLockedSegmentTap,
                                    lockedMessages: hasArchive
                                        ? null
                                        : const {
                                            Treatment.grayscale:
                                                'Older capture — re-record to enable.',
                                            Treatment.original:
                                                'Older capture — re-record to enable.',
                                          },
                                  ),
                                ),
                              ),
                            ),
                          )
                        : Positioned(
                            left: 12,
                            // Round 3 — when embedded in the editor sheet
                            // the canvas can shrink to the 0.55 detent
                            // (~460pt). The previously-centered vertical
                            // treatment pill (~220pt tall) collided with
                            // the bottom-left Body Focus / Rotate cluster
                            // at that height. Anchor near the top instead
                            // of center; the route-pushed full-screen path
                            // still uses centerLeft (taller canvas, no
                            // collision).
                            top: widget.embeddedInSheet
                                ? MediaQuery.of(context).padding.top + 12
                                : 0,
                            bottom: widget.embeddedInSheet ? null : 0,
                            child: SafeArea(
                              top: !widget.embeddedInSheet,
                              child: Align(
                                alignment: widget.embeddedInSheet
                                    ? Alignment.topLeft
                                    : Alignment.centerLeft,
                                child: TreatmentSegmentedControl(
                                  orientation: Axis.vertical,
                                  active: _treatment,
                                  grayscaleAvailable: hasArchive,
                                  originalAvailable: hasArchive,
                                  onChanged: _onTreatmentChanged,
                                  onLockTap: _onLockedSegmentTap,
                                  lockedMessages: hasArchive
                                      ? null
                                      : const {
                                          Treatment.grayscale:
                                              'Older capture — re-record to enable.',
                                          Treatment.original:
                                              'Older capture — re-record to enable.',
                                        },
                                ),
                              ),
                            ),
                          ),

                  // Exercise-name pill — top-centered in both orientations.
                  Positioned(
                    top: MediaQuery.of(context).padding.top + 12,
                    left: 0,
                    right: 0,
                    child: IgnorePointer(
                      child: Center(
                        child: Container(
                          constraints: BoxConstraints(
                            maxWidth: MediaQuery.of(context).size.width - 96,
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.6),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _headerLabel(_current, _currentIndex),
                                textAlign: TextAlign.center,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontFamily: 'Inter',
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Exercise ${_currentIndex + 1} of ${widget.exercises.length}',
                                textAlign: TextAlign.center,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontFamily: 'Inter',
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                  letterSpacing: 0.3,
                                  color: AppColors.textSecondaryOnDark,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),

                  // Bottom-right play/pause overlay. Lifted by trim-panel
                  // height (compact in landscape).
                  if (_isVideo(_current) && _videoInitialized)
                    Positioned(
                      right: 20,
                      bottom:
                          MediaQuery.of(context).padding.bottom +
                          ((widget.exercises.length > 1 &&
                                  widget.exercises.length <= 10)
                              ? 48
                              : 20) +
                          _bottomChromeTrimLiftFor(compact: isLandscape),
                      child: _PlayPauseOverlayButton(
                        isPlaying: _activeController?.value.isPlaying ?? false,
                        visible: _controlsVisible,
                        onTap: _togglePlayPause,
                      ),
                    ),

                  // Page dots — bottom-center in both orientations.
                  if (widget.exercises.length > 1 &&
                      widget.exercises.length <= 10)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom:
                          MediaQuery.of(context).padding.bottom +
                          16 +
                          _bottomChromeTrimLiftFor(compact: isLandscape),
                      child: IgnorePointer(
                        child: _MediaViewerBodyDotIndicator(
                          total: widget.exercises.length,
                          activeIndex: _currentIndex,
                        ),
                      ),
                    ),

                  // Bottom-left chrome cluster: mute + body focus + rotate.
                  // Portrait stacks vertical (mute at base, body focus
                  // above); landscape stacks them in a single horizontal
                  // row to recover vertical canvas. Rotate-90 is the new
                  // pill — videos only.
                  //
                  // Wave 34 — photos render the cluster with ONLY the
                  // body-focus pill (mute + rotate stay video-only).
                  // Photos still get a visible Body Focus toggle so the
                  // practitioner can mark a per-plan preference that the
                  // web player honours via Wave 22's segmented URL.
                  if (!_current.isRest &&
                      (_isVideo(_current) ? _videoInitialized : true))
                    Positioned(
                      left: 20,
                      bottom:
                          MediaQuery.of(context).padding.bottom +
                          12 +
                          _bottomChromeTrimLiftFor(compact: isLandscape),
                      child: _buildBottomLeftChromeCluster(
                        isLandscape: isLandscape,
                      ),
                    ),

                  // Raw-archive download chip — coral pill on the
                  // active video tile while a B&W / Original fetch is
                  // in flight (kicked off by tapping a locked segment
                  // on a cloud-only session). Mirrors the line-drawing
                  // _DownloadingChip pattern in StudioExerciseCard;
                  // disappears when the prefetch settles to done /
                  // failed (`_hasArchive` then unlocks the segment
                  // organically on the next rebuild).
                  if (_isVideo(_current))
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom:
                          MediaQuery.of(context).padding.bottom +
                          72 +
                          _bottomChromeTrimLiftFor(compact: isLandscape),
                      child: IgnorePointer(
                        child: Center(
                          child: ValueListenableBuilder<MediaPrefetchStatus>(
                            valueListenable: MediaPrefetchService.instance
                                .archiveStatusFor(_current.id),
                            builder: (context, status, _) {
                              if (status != MediaPrefetchStatus.downloading) {
                                return const SizedBox.shrink();
                              }
                              return const _ArchiveDownloadingChip();
                            },
                          ),
                        ),
                      ),
                    ),

                  // Soft-trim editor. Compact bar in landscape.
                  if (_trimPanelVisible)
                    Positioned(
                      left: 12,
                      right: 12,
                      bottom: MediaQuery.of(context).padding.bottom + 8,
                      child: _TrimPanel(
                        durationMs:
                            _activeController!.value.duration.inMilliseconds,
                        startOffsetMs: _current.startOffsetMs,
                        endOffsetMs: _current.endOffsetMs,
                        heroOffsetMs: _current.focusFrameOffsetMs,
                        reps: _current.sets.isNotEmpty
                            ? _current.sets.first.reps
                            : null,
                        selectedHandle: _selectedTrimHandle,
                        activeController: _activeController,
                        compact: isLandscape,
                        onTrimChanged: (s, e) => _persistTrim(s, e),
                        onHeroChanged: _persistHero,
                        onSelectionChanged: _onTrimSelectionChanged,
                        onScrub: _onTrimScrub,
                        onGuardHit: () => HapticFeedback.lightImpact(),
                        onReset: _resetTrim,
                        onDragStart: () {
                          _trimDragInProgress = true;
                          final active = _activeController;
                          if (active == null) return;
                          _trimDragWasPlaying = active.value.isPlaying;
                          if (_trimDragWasPlaying) active.pause();
                          _inactiveController?.pause();
                        },
                        onDragEnd: () {
                          _trimDragInProgress = false;
                          final active = _activeController;
                          if (active == null) {
                            _trimDragWasPlaying = false;
                            return;
                          }
                          _prebuffered = false;
                          if (_trimDragWasPlaying) active.play();
                          _trimDragWasPlaying = false;
                        },
                        onHandleSeek: _onTrimScrub,
                      ),
                    ),

                  // Close X — top-right in both orientations. Wave 35:
                  // pops with the current exercise id so Studio can scroll-
                  // into-view + auto-expand the matching card on return.
                  // Returning the id (not the index) keeps the handoff
                  // robust against any reorders that may have happened
                  // inside the viewer.
                  //
                  // Round 3 — hidden when embedded in the editor sheet.
                  // The sheet's drag-down + tap-outside dismiss; an X
                  // button on the embedded viewer would pop the sheet
                  // (since it's the topmost route), creating two redundant
                  // dismiss affordances + Carl found the visual noise
                  // distracting.
                  if (!widget.embeddedInSheet)
                    Positioned(
                      top: MediaQuery.of(context).padding.top + 8,
                      right: 8,
                      child: IconButton(
                        onPressed: () =>
                            Navigator.of(context).pop(_focusIdForPop),
                        icon: const Icon(
                          Icons.close,
                          color: Colors.white,
                          size: 28,
                        ),
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.black54,
                        ),
                        tooltip: 'Close',
                      ),
                    ),

                  // Tune gear — top-right column under the close X.
                  if (_crossfadeTunerVisible)
                    Positioned(
                      top: MediaQuery.of(context).padding.top + 8 + 48 + 4,
                      right: 12,
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: () =>
                              _openCrossfadeTuner(asPopover: isLandscape),
                          customBorder: const CircleBorder(),
                          child: Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.55),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.tune_rounded,
                              color: AppColors.primary,
                              size: 18,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// Bottom-left chrome cluster — mute + body focus + rotate-90 pills.
  /// Portrait: vertical column (rotate stacked above body focus, body
  /// focus above mute). Landscape: single horizontal row (mute, body
  /// focus, rotate) so the pills don't eat vertical canvas.
  ///
  /// Rotate-90 only renders for videos (rest rows are guarded by the
  /// caller; photos by the inner `_isVideo` check). Long-press resets
  /// rotation_quarters to 0; tap advances by one quarter clockwise.
  Widget _buildBottomLeftChromeCluster({required bool isLandscape}) {
    // Wave 34 — photos render only the Body Focus pill. Mute (no audio
    // on a photo) and Rotate (rotation is a video-only EXIF concern,
    // photos are already correct on capture) are video-only.
    final isVideo = _isVideo(_current);
    final mute = _TogglePill(
      iconWhenActive: Icons.volume_off_rounded,
      iconWhenInactive: Icons.volume_up_rounded,
      labelWhenActive: 'Muted',
      labelWhenInactive: 'Audio on',
      active: _isMuted,
      onTap: _toggleMute,
    );
    final bodyFocus = _TogglePill(
      iconWhenActive: Icons.blur_on_rounded,
      iconWhenInactive: Icons.blur_off_rounded,
      labelWhenActive: 'Body focus',
      labelWhenInactive: 'Body focus',
      active: _enhancedBackground,
      enabled: _enhancedBackgroundEnabled,
      onTap: _onEnhancedBackgroundToggle,
      tooltipWhenActive: 'Body focus ON — background dimmed for clarity.',
      tooltipWhenInactive:
          'Body focus OFF — playing the untouched colour file.',
      tooltipWhenDisabled: 'Body focus applies to colour playback only.',
    );
    final rotate = _RotatePill(
      onTap: _onRotateTap,
      onLongPress: _onRotateReset,
    );

    if (!isVideo) {
      // Photo path — body focus only.
      return bodyFocus;
    }

    if (isLandscape) {
      // Single row, oldest-to-newest left-to-right.
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          mute,
          const SizedBox(width: 8),
          bodyFocus,
          const SizedBox(width: 8),
          rotate,
        ],
      );
    }
    // Portrait stays the historical bottom-up stack: mute (base),
    // body focus, rotate (top). Reversed Column children so the base
    // pill sits at the bottom of the cluster's bounding box.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        rotate,
        const SizedBox(height: 8),
        bodyFocus,
        const SizedBox(height: 8),
        mute,
      ],
    );
  }

  /// Advance the active exercise's `rotation_quarters` by +1 mod 4. Also
  /// flips the stored `aspect_ratio` when the new rotation is odd
  /// (1 or 3) — width and height swap visually, so callers that read
  /// the field for sizing don't need to know about rotation.
  ///
  /// Wave 28 contract: depends on Agent 1's `int? rotationQuarters` +
  /// `double? aspectRatio` fields on [ExerciseCapture] (and matching
  /// `copyWith` parameters). If those are missing the analyzer will
  /// surface the gap loud and clear.
  void _onRotateTap() {
    final exercise = _current;
    HapticFeedback.selectionClick();
    final current = (exercise.rotationQuarters ?? 0) % 4;
    final next = (current + 1) % 4;
    final oldAspect = exercise.aspectRatio;
    final newAspect = (next.isOdd != current.isOdd && oldAspect != null)
        ? 1 / oldAspect
        : oldAspect;
    final updated = exercise.copyWith(
      rotationQuarters: next,
      aspectRatio: newAspect,
    );
    setState(() {
      _exercises[_currentIndex] = updated;
    });
    final cb = widget.onExerciseUpdate;
    if (cb != null) cb(updated);
    _persistRotation(updated);
  }

  /// Long-press handler — reset rotation back to 0 and restore the
  /// canonical aspect by reverse-flipping if the current rotation was
  /// odd. Cheap escape hatch for accidental taps.
  void _onRotateReset() {
    final exercise = _current;
    final current = (exercise.rotationQuarters ?? 0) % 4;
    if (current == 0 && exercise.aspectRatio != null) return;
    HapticFeedback.lightImpact();
    final oldAspect = exercise.aspectRatio;
    final newAspect = (current.isOdd && oldAspect != null)
        ? 1 / oldAspect
        : oldAspect;
    final updated = exercise.copyWith(
      rotationQuarters: 0,
      aspectRatio: newAspect,
    );
    setState(() {
      _exercises[_currentIndex] = updated;
    });
    final cb = widget.onExerciseUpdate;
    if (cb != null) cb(updated);
    _persistRotation(updated);
  }

  // Rotation persist debouncer — same 200 ms cadence as `_persistTrim`
  // so rapid taps coalesce into a single SQLite write.
  Timer? _rotationPersistTimer;
  void _persistRotation(ExerciseCapture updated) {
    _rotationPersistTimer?.cancel();
    _rotationPersistTimer = Timer(const Duration(milliseconds: 200), () {
      unawaited(
        SyncService.instance.storage.saveExercise(updated).catchError((e, _) {
          debugPrint('MediaViewer: saveExercise(rotation) failed: $e');
        }),
      );
    });
  }

  /// Tap handler for a locked segment in the segmented control.
  ///
  /// Two reasons a segment can be locked:
  ///   1. The local raw-archive file isn't on disk yet (cloud-only
  ///      session post-PR #190). We silently kick off a background
  ///      download from the private `raw-archive` bucket via
  ///      [MediaPrefetchService.prefetchRawArchive]. A coral
  ///      "Downloading original…" chip overlays the active media
  ///      tile while the pull is in flight; on completion the
  ///      relevant local column is stamped (`archive_file_path` for
  ///      videos, `raw_file_path` for photos), `_hasArchive` flips
  ///      true on the next rebuild, and the active treatment switches
  ///      to whichever segment the user tapped (B&W or Original) so
  ///      they see the result without a second tap.
  ///   2. Archive exists but the client hasn't granted that treatment.
  ///      We surface a SnackBar pointing the practitioner at the client
  ///      consent page, with the actual client name + treatment word
  ///      interpolated so the next step is concrete.
  ///
  /// Haptic + chip overlay / SnackBar; no modal (R-01).
  void _onLockedSegmentTap(Treatment t) {
    HapticFeedback.lightImpact();
    if (!mounted) return;

    final exercise = _current;
    final missingArchive = !_hasArchive(exercise);
    final session = _session;
    // session.practiceId is NULL on cloud-pulled rows because the local
    // sessions table has no practice_id column (and toMap() doesn't emit
    // one). Mirror the publish path's fallback: read the active practice
    // from AuthService when the session itself doesn't carry it.
    final practiceId =
        session?.practiceId ?? AuthService.instance.currentPracticeId.value;
    final planId = session?.id;
    final treatmentWord = t == Treatment.grayscale ? 'B&W' : 'Original';

    // Fresh capture, archive still being built locally by ConversionService
    // (the 720p H.264 mp4 lands in {Documents}/archive/ ~20-30s after the
    // raw recording stops). The raw file is on disk but the archive isn't
    // yet, and the cloud has nothing either (publish hasn't run). Firing
    // prefetchRawArchive here would always fail with a futile signed-URL
    // round-trip. Once the conversion service emits the archive-stamped
    // row, _hasArchive flips true on the next rebuild and the segment
    // unlocks automatically — no user action required.
    if (missingArchive && _isVideo(exercise) && _rawIsLocal(exercise)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$treatmentWord still processing — try again in a moment.'),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }

    if (missingArchive && practiceId != null && planId != null) {
      // Cloud-only session — the raw file (mp4 for videos, jpg for
      // photos) hasn't been pulled yet. Fire a background download;
      // the chip overlay on the active media tile is the only
      // feedback. On completion we update the in-memory exercise so
      // _hasArchive flips true, then switch the active treatment to
      // the one the user tapped.
      //
      // Optimistic treatment switch is deferred to the onDownloaded
      // callback because _initVideoForCurrent / the photo render path
      // both read the local file directly — switching now (before the
      // file lands) would briefly try to render a non-existent path.
      unawaited(
        MediaPrefetchService.instance.prefetchRawArchive(
          exercise: exercise,
          practiceId: practiceId,
          planId: planId,
          storage: SyncService.instance.storage,
          onDownloaded: (downloadedId) {
            if (!mounted) return;
            // Re-read the freshly-stamped row from SQLite so the
            // viewer's in-memory copy carries the new path.
            unawaited(_refreshDownloadedExercise(downloadedId, t));
          },
          onFailed: (_) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text("Couldn't download original — try again."),
                duration: Duration(seconds: 3),
              ),
            );
          },
        ),
      );
      return;
    }

    // Archive exists but consent is missing (the "real" lock case).
    // Surface the SnackBar pointing the practitioner at the client
    // consent page.
    final rawClientName = session?.clientName ?? '';
    final clientName = rawClientName.trim().isEmpty
        ? 'this client'
        : rawClientName;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Grant $clientName consent for $treatmentWord to unlock.',
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// Pull the freshly-stamped row from SQLite and merge into the
  /// viewer's in-memory `_exercises` so `_hasArchive` flips true on
  /// the next rebuild. Then switch the active treatment to [tapped]
  /// (B&W or Original) so the user sees the file they were waiting
  /// for without having to tap the segment a second time.
  ///
  /// If the prefetch fired for an exercise other than the currently-
  /// shown one (rare — the user paged away mid-download), we still
  /// update the in-memory copy but skip the treatment switch.
  Future<void> _refreshDownloadedExercise(
    String exerciseId,
    Treatment tapped,
  ) async {
    final fresh = await SyncService.instance.storage.getExerciseById(
      exerciseId,
    );
    if (fresh == null || !mounted) return;
    final idx = _exercises.indexWhere((e) => e.id == exerciseId);
    if (idx < 0) return;
    setState(() {
      _exercises[idx] = fresh;
    });
    final cb = widget.onExerciseUpdate;
    if (cb != null) cb(fresh);
    // Only switch treatment when the download landed for the page
    // currently in view — otherwise we'd reach across PageView pages
    // and surprise the user.
    if (idx != _currentIndex) return;
    if (!_hasArchive(_exercises[_currentIndex])) return;
    if (tapped == _treatment) return;
    if (tapped == Treatment.line) return;
    setState(() => _treatment = tapped);
    _persistPreferredTreatment(tapped);
    _initVideoForCurrent();
  }

  /// Wave 27 — stacked dual-video crossfade. Both VideoPlayer widgets
  /// are in the tree, the inactive one is opacity 0; the
  /// AnimatedOpacity duration uses the live `crossfadeFadeMs` so a
  /// slider drag reflows the next swap immediately.
  /// Wave 34 — photo render with three-treatment support. The pager's
  /// non-current pages always draw the line drawing (cheaper, avoids
  /// re-decoding the raw on every swipe); only the current page reflects
  /// the active [_treatment].
  ///
  /// Source picks:
  ///   * [Treatment.line] → `displayFilePath` (the on-device line
  ///     drawing JPG, always present once conversion completes).
  ///   * [Treatment.grayscale] → raw colour JPG wrapped in a
  ///     `ColorFiltered` grayscale matrix (single source, CSS-style
  ///     filter — same pattern videos use for B&W).
  ///   * [Treatment.original] → raw colour JPG.
  ///
  /// Wave 36 — Body Focus toggle finally affects photo preview. When
  /// `_enhancedBackground` is on AND the active treatment is grayscale
  /// or original AND a local segmented JPG exists at
  /// `segmentedRawFilePath`, render that instead of the raw colour JPG.
  /// Falls through to the raw original gracefully when the segmented
  /// file is missing (legacy photo, segmentation failed during conversion,
  /// etc.). Line treatment is unaffected — the line drawing already
  /// abstracts the body, body-focus is meaningless there.
  Widget _buildPhotoFrame(ExerciseCapture ex, {required bool isCurrent}) {
    String resolvedPath = ex.displayFilePath;
    if (isCurrent && _treatment != Treatment.line) {
      // Wave 36 — when body focus is on, prefer the segmented JPG
      // produced by the on-device Vision pipeline. The local file lives
      // alongside the raw colour JPG at `<exerciseId>.segmented.jpg`.
      // Mobile preview plays local files only (standing rule) so we
      // never reach for the cloud signed URL.
      if (_enhancedBackground) {
        final segAbs = ex.absoluteSegmentedRawFilePath;
        if (segAbs != null && segAbs.isNotEmpty) {
          final segExt = segAbs.toLowerCase();
          final segIsImage =
              segExt.endsWith('.jpg') ||
              segExt.endsWith('.jpeg') ||
              segExt.endsWith('.png');
          if (segIsImage && File(segAbs).existsSync()) {
            resolvedPath = segAbs;
          }
        }
      }
      // Fallback when body focus is off OR the segmented file is
      // missing — play the untouched raw colour JPG. Same rule as
      // pre-Wave-36 (this branch was the only path before).
      if (resolvedPath == ex.displayFilePath) {
        final raw = ex.absoluteRawFilePath;
        // Only switch source when the raw file is itself an image. The
        // exotic "video converted to a still" path (mediaType=video +
        // convertedFilePath=*.jpg) leaves the raw as a .mov/.mp4 — try
        // to Image.file that and we crash. In that case keep the line
        // drawing rendered for all treatments.
        final ext = raw.toLowerCase();
        final rawIsImage =
            ext.endsWith('.jpg') ||
            ext.endsWith('.jpeg') ||
            ext.endsWith('.png') ||
            ext.endsWith('.heic');
        if (rawIsImage && raw.isNotEmpty && File(raw).existsSync()) {
          resolvedPath = raw;
        }
      }
    }
    Widget image = Image.file(
      File(resolvedPath),
      key: ValueKey('photo-$resolvedPath'),
      fit: BoxFit.contain,
      errorBuilder: (_, e, s) => const Icon(
        Icons.broken_image_outlined,
        size: 64,
        color: Colors.white54,
      ),
    );
    if (isCurrent && _treatment == Treatment.grayscale) {
      image = ColorFiltered(colorFilter: grayscaleColorFilter, child: image);
    }
    // Wave 36 — body-focus state is part of the key so toggling the
    // pill rebuilds the photo frame even when the treatment hasn't
    // changed. Without this, a flip from raw → segmented (or back)
    // could leave the previous Image cached for a frame.
    final keySuffix = isCurrent
        ? '${_treatment.name}-${_enhancedBackground ? 'bf' : 'raw'}'
        : 'line';
    return KeyedSubtree(
      key: ValueKey('photo-frame-${ex.id}-$keySuffix'),
      child: image,
    );
  }

  Widget _buildVideoFrame() {
    final a = _videoControllerA;
    final b = _videoControllerB;
    if (a == null || b == null || !_videoInitialized) {
      return const SizedBox.expand(
        key: ValueKey('media-viewer-loading'),
        child: Center(child: CircularProgressIndicator(color: Colors.white54)),
      );
    }
    final fadeMs = _crossfadeFadeMs;
    // Wave 28 — rotation lives outside the slot Stack so a single
    // RotatedBox composes over both crossfade slots; rotating between
    // slot swaps would double-rotate or cancel in flight.
    final quarters = (_current.rotationQuarters ?? 0) % 4;
    final rawAspect = a.value.aspectRatio;
    // Visible aspect swaps when the rotation is a quarter or three-
    // quarters turn — width and height effectively trade places so the
    // letterboxing math reads natural.
    final aspect = quarters.isOdd ? 1 / rawAspect : rawAspect;
    Widget slot(VideoPlayerController c, bool visible) {
      return AnimatedOpacity(
        duration: Duration(milliseconds: fadeMs),
        opacity: visible ? 1.0 : 0.0,
        curve: Curves.easeInOut,
        child: VideoPlayer(c),
      );
    }

    Widget stack = AspectRatio(
      aspectRatio: aspect,
      child: RotatedBox(
        quarterTurns: quarters,
        child: Stack(
          fit: StackFit.expand,
          children: [slot(a, _activeSlot == 'a'), slot(b, _activeSlot == 'b')],
        ),
      ),
    );
    if (_treatment == Treatment.grayscale) {
      stack = ColorFiltered(colorFilter: grayscaleColorFilter, child: stack);
    }
    return KeyedSubtree(
      key: ValueKey('media-viewer-${_treatment.name}-q$quarters'),
      child: stack,
    );
  }

  // ---------------------------------------------------------------------------
  // Wave 27 — crossfade tuner (lead + fade sliders, reset-to-default)
  // ---------------------------------------------------------------------------

  /// Whether the tuner gear should render. Hidden when the parent
  /// didn't pass a session (legacy callsite) or for non-video pages.
  bool get _crossfadeTunerVisible =>
      _session != null && _isVideo(_current) && _videoInitialized;

  /// Optimistic in-memory update + debounced disk write for the
  /// tuner sliders. AnimatedOpacity reads from `_session.crossfadeFadeMs`
  /// in build() so the value flows live; the listener reads
  /// `_crossfadeLeadMs` per tick so preroll updates live too.
  void _persistCrossfade({int? leadMs, int? fadeMs, bool reset = false}) {
    final session = _session;
    if (session == null) return;
    final updated = reset
        ? session.copyWith(
            clearCrossfadeLeadMs: true,
            clearCrossfadeFadeMs: true,
          )
        : session.copyWith(
            crossfadeLeadMs: leadMs ?? session.crossfadeLeadMs,
            crossfadeFadeMs: fadeMs ?? session.crossfadeFadeMs,
          );
    setState(() => _session = updated);
    final cb = widget.onSessionUpdate;
    if (cb != null) cb(updated);
    _crossfadePersistTimer?.cancel();
    _crossfadePersistTimer = Timer(const Duration(milliseconds: 250), () {
      unawaited(
        SyncService.instance.storage.saveSession(updated).catchError((e, _) {
          debugPrint('MediaViewer: saveSession(crossfade) failed: $e');
        }),
      );
    });
  }

  void _openCrossfadeTuner({bool asPopover = false}) {
    final session = _session;
    if (session == null) return;
    HapticFeedback.selectionClick();
    final body = _CrossfadeTunerSheet(
      initialLeadMs: session.crossfadeLeadMs ?? _kDefaultCrossfadeLeadMs,
      initialFadeMs: session.crossfadeFadeMs ?? _kDefaultCrossfadeFadeMs,
      compact: asPopover,
      onChanged: ({int? leadMs, int? fadeMs}) {
        _persistCrossfade(leadMs: leadMs, fadeMs: fadeMs);
      },
      onReset: () {
        _persistCrossfade(reset: true);
      },
    );
    if (asPopover) {
      // Landscape — anchor a dialog near the top-right gear instead of
      // a bottom sheet. A bottom sheet in landscape would eat ~half the
      // canvas; the popover lives in the dead-zone above the gear pill.
      // Carl 2026-04-25 (Wave 28 item 7): popover content was extending
      // below the visible area on iPhone landscape (~350px available
      // after the top anchor). Cap height to the available space and
      // scroll internally if content overflows.
      showDialog<void>(
        context: context,
        barrierColor: Colors.black.withValues(alpha: 0.25),
        builder: (ctx) {
          final media = MediaQuery.of(ctx);
          final topInset = media.padding.top;
          final bottomInset = media.padding.bottom;
          final anchorTop = topInset + 8 + 48 + 4 + 32 + 8;
          final maxHeight = (media.size.height - anchorTop - bottomInset - 12)
              .clamp(160.0, 480.0);
          return SafeArea(
            child: Stack(
              children: [
                Positioned(
                  top: anchorTop,
                  right: 12,
                  child: Material(
                    color: Colors.transparent,
                    child: Container(
                      width: 280,
                      constraints: BoxConstraints(maxHeight: maxHeight),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceBase,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: AppColors.surfaceBorder),
                        boxShadow: const [
                          BoxShadow(
                            color: Colors.black54,
                            blurRadius: 16,
                            offset: Offset(0, 4),
                          ),
                        ],
                      ),
                      child: SingleChildScrollView(child: body),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      );
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => body,
    );
  }
}

/// Shared horizontal pill toggle used by both the mute pill and the
/// Body focus pill in [MediaViewerBody]'s bottom-left chrome cluster.
/// Coral 1.5px border, coral fill + white text when [active], outlined
/// + coral text when inactive. Optional [enabled]=false fades the pill
/// to 40% and disables tap; optional tooltips fire on long-press.
class _TogglePill extends StatelessWidget {
  final IconData iconWhenActive;
  final IconData iconWhenInactive;
  final String labelWhenActive;
  final String labelWhenInactive;
  final bool active;
  final bool enabled;
  final VoidCallback onTap;
  final String? tooltipWhenActive;
  final String? tooltipWhenInactive;
  final String? tooltipWhenDisabled;

  const _TogglePill({
    required this.iconWhenActive,
    required this.iconWhenInactive,
    required this.labelWhenActive,
    required this.labelWhenInactive,
    required this.active,
    required this.onTap,
    this.enabled = true,
    this.tooltipWhenActive,
    this.tooltipWhenInactive,
    this.tooltipWhenDisabled,
  });

  @override
  Widget build(BuildContext context) {
    final iconData = active ? iconWhenActive : iconWhenInactive;
    final label = active ? labelWhenActive : labelWhenInactive;
    final fillColor = active ? AppColors.primary : Colors.transparent;
    final textColor = active ? Colors.white : AppColors.primary;

    final pill = Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: fillColor,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.primary, width: 1.5),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(iconData, color: textColor, size: 16),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: textColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final msg = !enabled
        ? tooltipWhenDisabled
        : (active ? tooltipWhenActive : tooltipWhenInactive);
    final wrapped = msg != null
        ? Tooltip(
            message: msg,
            triggerMode: TooltipTriggerMode.tap,
            child: pill,
          )
        : pill;
    return enabled ? wrapped : Opacity(opacity: 0.4, child: wrapped);
  }
}

/// Compact coral pill that advances the active exercise's playback
/// rotation by one quarter-turn clockwise on tap, and resets it on
/// long-press. Lives in the bottom-left chrome cluster next to mute /
/// body-focus, hidden for photos and rest rows by the host's guard.
class _RotatePill extends StatelessWidget {
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _RotatePill({required this.onTap, required this.onLongPress});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Rotate playback 90°',
      triggerMode: TooltipTriggerMode.longPress,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.primary, width: 1.5),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.rotate_right_rounded,
                  color: AppColors.primary,
                  size: 16,
                ),
                SizedBox(width: 6),
                Text(
                  'Rotate',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.primary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Coral, circular, bottom-right play/pause button on top of the
/// [MediaViewerBody]. Presence in the tree is stable whenever the current
/// page is a video — it's opacity that swings (via [AnimatedOpacity]) so
/// taps always hit, even during a fade. Caller is responsible for
/// scheduling the fade (see `_showControlsThenMaybeIdleFade`).
///
/// Icon glyph morphs: `play_arrow_rounded` when paused,
/// `pause_rounded` when playing. 56-px touch target, coral
/// [AppColors.primary] fill at 85% alpha (enough to read, still lets
/// a sliver of video tone through), white glyph.
class _PlayPauseOverlayButton extends StatelessWidget {
  final bool isPlaying;
  final bool visible;
  final VoidCallback onTap;

  const _PlayPauseOverlayButton({
    required this.isPlaying,
    required this.visible,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // IgnorePointer when fully faded so a "ghost" button doesn't eat
    // swipes. AnimatedOpacity keeps the transition smooth.
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
        child: Material(
          shape: const CircleBorder(),
          color: AppColors.primary.withValues(alpha: 0.85),
          elevation: 4,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: 56,
              height: 56,
              child: Icon(
                isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                color: Colors.white,
                size: 32,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Bottom-of-viewer dot row that tells the practitioner "horizontal
/// swipe moves between exercises". Mirrors the style established in
/// `plan_preview_screen.dart` — active dot grows to a short capsule;
/// inactive dots are small + translucent. Caller guards on slide
/// count <= 10; past that the name-pill counter carries the signal.
class _MediaViewerBodyDotIndicator extends StatelessWidget {
  final int total;
  final int activeIndex;

  const _MediaViewerBodyDotIndicator({
    required this.total,
    required this.activeIndex,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(total, (index) {
        final isActive = index == activeIndex;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.symmetric(horizontal: 4),
          width: isActive ? 24 : 8,
          height: 8,
          decoration: BoxDecoration(
            // Wave 18 — active dot is coral; inactive is a muted
            // coral-tint so the pager reads in brand.
            color: isActive
                ? AppColors.primary
                : AppColors.primary.withValues(alpha: 0.25),
            borderRadius: BorderRadius.circular(4),
          ),
        );
      }),
    );
  }
}

/// Dark placeholder shown on non-current video pages during horizontal
/// swipe transitions. Avoids spinning up a VideoPlayerController per
/// page — only the current page's controller is ever initialised.
class _VideoPagePlaceholder extends StatelessWidget {
  const _VideoPagePlaceholder();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Icon(Icons.play_circle_outline, size: 72, color: Colors.white24),
    );
  }
}

/// Coral chip — shown over the active video tile in `_MediaViewer`
/// while the raw archive (B&W / Original source) is being pulled from
/// the private `raw-archive` Supabase bucket. Only feedback for the
/// locked-segment tap on a cloud-only session; vanishes once the file
/// lands and `_hasArchive` flips true.
///
/// Mirrors the line-drawing `_DownloadingChip` in `studio_exercise_card.dart`
/// (same fontFamily / weight / radius / spinner stroke). Sized for
/// the larger viewer surface — slightly more padding so the chip
/// reads at a glance from arm's length.
class _ArchiveDownloadingChip extends StatelessWidget {
  const _ArchiveDownloadingChip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(9999),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 1.6,
              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
            ),
          ),
          SizedBox(width: 10),
          Text(
            'Downloading original…',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Colors.white,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// Wave 20 — Soft-trim editor for the [MediaViewerBody].
// 2026-05-03 — extended to host the Hero-frame pick. The trim panel now
// shows THREE handles on a single shared track:
//   * begin clip (left bracket)
//   * Hero (★ star, slightly larger so it reads above the brackets at
//     collisions)
//   * end clip (right bracket)
// All three handles are white when idle; selected handle goes coral
// (single colour swap, no glow ring, no scale). Tap a handle → the host
// pauses + seeks via [onScrub] and the handle becomes selected. Tap the
// video (outside the panel) → host calls [setSelection] back to null.
// During playback all handles stay white; when the playhead crosses an
// offset within ±100ms, the corresponding handle pulses coral for ~600ms
// then fades. No tooltip during play. The flash is the only "you just
// passed it" cue.
// ============================================================================

/// Bottom-anchored trim panel shown beneath the video on the [MediaViewerBody]
/// when the active exercise is a video at least 1 second long. Three
/// handles (begin clip, Hero ★, end clip) share the timeline; coral fill
/// between begin/end shows the trimmed slice; greyed bookends show the
/// discarded frames. Live readout underneath. "Reset to full video" link
/// reveals when either offset is non-null.
///
/// State ownership: trim/hero values + selected handle are HOST-owned (the
/// `_MediaViewerBodyState` debounces SQLite writes). The flash animations
/// are panel-owned (per-handle [AnimationController]s, fed by the active
/// video controller's position ticks via [activeController]).
///
/// Drag rules enforced HERE (kept tight so the host doesn't have to
/// duplicate the math):
///   * minimum 0.3s window between begin/end handles — bumping the guard
///     fires a light-haptic via the [onGuardHit] callback.
///   * begin/end handles cannot cross.
///   * Hero offset is clamped to `[startOffsetMs, endOffsetMs]`. Dragging
///     begin past Hero or end past Hero → Hero stays at the new bound
///     (doesn't slide).
///   * tap inside the coral range emits a [onScrub] with the resolved
///     ms position; tap inside the greyed bookends is a no-op.
///   * tap a handle → fires [onSelectionChanged] with the matching enum
///     value AND [onScrub] with the handle's ms position so the host
///     pauses + seeks.
class _TrimPanel extends StatefulWidget {
  /// Total length of the underlying media in ms. Comes straight off the
  /// `VideoPlayerController.value.duration`. Caller must guarantee >= 1000.
  final int durationMs;

  /// Active in-point in ms. Null = "no trim — start at 0". The widget
  /// always paints with concrete values, falling back to 0 when null.
  final int? startOffsetMs;

  /// Active out-point in ms. Null = "no trim — end at duration".
  final int? endOffsetMs;

  /// Active Hero offset in ms (the practitioner-picked representative
  /// frame). Null when no Hero has been picked — in that case the star
  /// renders at the midpoint of the trim window, but tapping / dragging
  /// it commits the picked offset via [onHeroChanged].
  final int? heroOffsetMs;

  /// Reps count for the live readout's loop math. Null / 0 collapses
  /// the math to "—".
  final int? reps;

  /// Currently-selected handle, or null when nothing is selected (during
  /// playback or after a tap-on-video). Drives the white→coral fill swap
  /// + the time tooltip rendered above the selected handle. Selection is
  /// EXCLUSIVE — at most one handle is "holding" the playhead.
  final _TrimHandle? selectedHandle;

  /// Active video controller — panel listens for position ticks to drive
  /// the playback flash. Null when no controller is ready (the panel
  /// degrades gracefully — flash simply won't fire). The panel never
  /// mutates the controller; seeks go through [onScrub] / [onHandleSeek].
  final VideoPlayerController? activeController;

  /// Fired continuously while the user drags either trim handle. Caller
  /// is responsible for persisting (debounced).
  final void Function(int startMs, int endMs) onTrimChanged;

  /// Fired when the user commits a Hero offset — drag-end on the star,
  /// or a tap on the star (which seeks to the saved offset). Caller
  /// should debounce a SQLite write + trigger
  /// [ConversionService.regenerateHeroThumbnails].
  final void Function(int heroMs) onHeroChanged;

  /// Fired when the user taps a handle (or null when selection should
  /// clear, e.g. after a tap-on-video). The host stores this so a
  /// subsequent rebuild renders the coral fill + tooltip on the right
  /// handle.
  final void Function(_TrimHandle? handle) onSelectionChanged;

  /// Fired on a tap inside the coral range. Caller seeks the active
  /// video controller. No-op for taps in the greyed bookends.
  final void Function(int positionMs) onScrub;

  /// Fired when a drag bumps the 0.3s minimum-window guard, so the host
  /// can fire a light haptic. Throttled by the widget — not every tick.
  final VoidCallback onGuardHit;

  /// Fired when the practitioner taps "Reset to full video". Caller
  /// should clear both offsets via copyWith(clearStartOffsetMs: true,
  /// clearEndOffsetMs: true).
  final VoidCallback onReset;

  /// Fired the moment a drag begins on any handle. Caller pauses the
  /// active video so the practitioner can scrub freely without the
  /// loop confusing the visual. Carl 2026-04-24: was: video kept
  /// playing under the drag, which felt fighty.
  final VoidCallback? onDragStart;

  /// Fired when the drag releases. Caller resumes playback (only if
  /// the video was actually playing pre-drag — caller's responsibility
  /// to remember that state).
  final VoidCallback? onDragEnd;

  /// Fired CONTINUOUSLY during a handle drag with the current ms
  /// position of the dragged handle. Caller seeks the active video
  /// controller to that frame so the practitioner sees a live preview
  /// of where they're trimming TO. Carl 2026-04-24: was a paused
  /// snapshot of wherever the video happened to be when drag started.
  final void Function(int positionMs)? onHandleSeek;

  /// Compact mode for landscape — drops the second live-readout row and
  /// shrinks the panel to a single horizontal scrubber bar. Frees up
  /// vertical canvas in landscape where height is the scarce axis.
  final bool compact;

  const _TrimPanel({
    required this.durationMs,
    required this.startOffsetMs,
    required this.endOffsetMs,
    required this.heroOffsetMs,
    required this.reps,
    required this.selectedHandle,
    required this.activeController,
    required this.onTrimChanged,
    required this.onHeroChanged,
    required this.onSelectionChanged,
    required this.onScrub,
    required this.onGuardHit,
    required this.onReset,
    this.onDragStart,
    this.onDragEnd,
    this.onHandleSeek,
    this.compact = false,
  });

  /// Layout constant — total panel height including its internal padding.
  /// The host uses this to lift the bottom chrome (mute pill / page dots
  /// / play-pause overlay) by `panelHeight + 8` so they don't overlap.
  static const double panelHeight = 96;
  static const double compactPanelHeight = 64;

  /// The effective height for the given mode — used by the host's
  /// `_bottomChromeTrimLift` math.
  static double effectiveHeight({required bool compact}) =>
      compact ? compactPanelHeight : panelHeight;

  @override
  State<_TrimPanel> createState() => _TrimPanelState();
}

class _TrimPanelState extends State<_TrimPanel>
    with TickerProviderStateMixin {
  // Cache the bar width on each layout pass so onPan* can convert
  // pixels → ms without touching the BuildContext.
  double _barWidth = 0;

  // Throttle haptic guard hits + live-frame seek calls — at 60Hz drag
  // we'd fire dozens per second otherwise. Seeks at >30Hz on iOS
  // Safari can stutter; haptics at >4Hz feel mushy.
  DateTime _lastGuardHapticAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastHandleSeekAt = DateTime.fromMillisecondsSinceEpoch(0);

  static const int _minWindowMs = 300; // 0.3s minimum window per the brief.
  static const int _seekThrottleMs = 33; // ~30Hz cap on live seek.
  // Playback-flash window. The mockup spec calls for ±100ms tolerance
  // around each handle's offset; once the playhead crosses the offset
  // (i.e. moves from <offset to >=offset within the same tick), we fire
  // the flash. Re-entrancy guarded via [_flashedThisLoop].
  static const int _flashCrossingToleranceMs = 100;

  // Per-handle flash animation controllers. Started independently when
  // the playhead crosses each handle's offset; status listener drops
  // the corresponding entry from [_flashedThisLoop] on completion so
  // the next loop fires again. 600ms duration matches the CSS keyframe
  // in the signed-off mockup.
  late final AnimationController _flashBegin;
  late final AnimationController _flashHero;
  late final AnimationController _flashEnd;

  /// Per-handle once-per-loop guard. The pos listener can fire several
  /// times within the ±100ms window before the playhead clears it —
  /// this keeps the flash from re-triggering until the playhead leaves
  /// the window. Cleared on play→pause / detach so a fresh play doesn't
  /// silently swallow the very first crossing.
  final Set<_TrimHandle> _withinWindow = <_TrimHandle>{};

  /// The controller we're currently subscribed to. Compared in
  /// [didUpdateWidget] so we can detach + re-attach when the host swaps
  /// in a fresh `VideoPlayerController` (treatment cycle, page change).
  VideoPlayerController? _subscribedController;
  VoidCallback? _positionListener;

  int get _effectiveStartMs => widget.startOffsetMs ?? 0;
  int get _effectiveEndMs => widget.endOffsetMs ?? widget.durationMs;
  /// Hero offset, clamped to the trim window. Falls back to the trim-
  /// window midpoint when null so the star always has a render position
  /// even before the practitioner picks one.
  int get _effectiveHeroMs {
    final raw = widget.heroOffsetMs ??
        ((_effectiveStartMs + _effectiveEndMs) ~/ 2);
    if (raw < _effectiveStartMs) return _effectiveStartMs;
    if (raw > _effectiveEndMs) return _effectiveEndMs;
    return raw;
  }
  bool get _hasTrim =>
      widget.startOffsetMs != null || widget.endOffsetMs != null;

  @override
  void initState() {
    super.initState();
    _flashBegin = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _flashHero = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _flashEnd = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _attachToController(widget.activeController);
  }

  @override
  void didUpdateWidget(covariant _TrimPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.activeController, widget.activeController)) {
      _detachFromController();
      _attachToController(widget.activeController);
    }
  }

  @override
  void dispose() {
    _detachFromController();
    _flashBegin.dispose();
    _flashHero.dispose();
    _flashEnd.dispose();
    super.dispose();
  }

  void _attachToController(VideoPlayerController? c) {
    if (c == null) return;
    _subscribedController = c;
    _withinWindow.clear();
    final listener = _onControllerTick;
    c.addListener(listener);
    _positionListener = listener;
  }

  void _detachFromController() {
    final c = _subscribedController;
    final listener = _positionListener;
    if (c != null && listener != null) {
      c.removeListener(listener);
    }
    _subscribedController = null;
    _positionListener = null;
  }

  /// Called on every controller value-change. Drives the playback-flash
  /// detection: when the active video is playing AND the playhead is
  /// within ±[_flashCrossingToleranceMs] of a handle offset (and we
  /// haven't already flashed for this loop), kick off the corresponding
  /// AnimationController. Selection state is irrelevant — the flash
  /// fires whether or not a handle is selected. The mockup spec is
  /// explicit: during play the handles all stay white and the flash is
  /// the only cue.
  void _onControllerTick() {
    final c = _subscribedController;
    if (c == null) return;
    final v = c.value;
    if (!v.isInitialized) return;
    if (!v.isPlaying) {
      // Reset baseline so a fresh play doesn't immediately fire on
      // whatever position the controller paused at.
      _withinWindow.clear();
      return;
    }
    final pos = v.position.inMilliseconds;
    _checkCrossing(_TrimHandle.start, _effectiveStartMs, pos);
    _checkCrossing(_TrimHandle.hero, _effectiveHeroMs, pos);
    _checkCrossing(_TrimHandle.end, _effectiveEndMs, pos);
  }

  void _checkCrossing(_TrimHandle handle, int offsetMs, int posMs) {
    final delta = (posMs - offsetMs).abs();
    final within = delta <= _flashCrossingToleranceMs;
    if (within) {
      if (!_withinWindow.contains(handle)) {
        _withinWindow.add(handle);
        _fireFlash(handle);
      }
    } else {
      _withinWindow.remove(handle);
    }
  }

  void _fireFlash(_TrimHandle handle) {
    final ctrl = switch (handle) {
      _TrimHandle.start => _flashBegin,
      _TrimHandle.hero => _flashHero,
      _TrimHandle.end => _flashEnd,
    };
    // Restart from 0 every time so an overlapping crossing doesn't
    // visually stutter the fade. forward() with reset is cheap.
    ctrl.stop();
    ctrl.forward(from: 0);
  }

  void _maybeFireGuard() {
    final now = DateTime.now();
    if (now.difference(_lastGuardHapticAt).inMilliseconds < 250) return;
    _lastGuardHapticAt = now;
    widget.onGuardHit();
  }

  /// Trailing-edge seek + drag-end. The throttle in `_updateHandle`
  /// can skip the very last gesture tick; firing one final seek here
  /// guarantees the video lands on the position the user actually
  /// released at (zero drift on resume). The Hero handle case ALSO
  /// commits the new offset via [onHeroChanged] so the host can fire
  /// the debounced thumbnail regen.
  void _onHandleReleased(_TrimHandle handle) {
    final commitMs = switch (handle) {
      _TrimHandle.start => _effectiveStartMs,
      _TrimHandle.end => _effectiveEndMs,
      _TrimHandle.hero => _effectiveHeroMs,
    };
    widget.onHandleSeek?.call(commitMs);
    if (handle == _TrimHandle.hero) {
      widget.onHeroChanged(commitMs);
    }
    widget.onDragEnd?.call();
  }

  void _updateHandle(_TrimHandle handle, double dx) {
    if (_barWidth <= 0) return;
    final dMs = (dx / _barWidth * widget.durationMs).round();
    var startMs = _effectiveStartMs;
    var endMs = _effectiveEndMs;
    var heroMs = _effectiveHeroMs;
    if (handle == _TrimHandle.start) {
      startMs = (startMs + dMs).clamp(0, widget.durationMs - _minWindowMs);
      // Don't cross the end handle.
      if (startMs > endMs - _minWindowMs) {
        startMs = endMs - _minWindowMs;
        _maybeFireGuard();
      }
      // Hero stays clamped to the new window — if we just dragged begin
      // past Hero, Hero parks at the new begin (doesn't slide further).
      if (heroMs < startMs) heroMs = startMs;
    } else if (handle == _TrimHandle.end) {
      endMs = (endMs + dMs).clamp(_minWindowMs, widget.durationMs);
      if (endMs < startMs + _minWindowMs) {
        endMs = startMs + _minWindowMs;
        _maybeFireGuard();
      }
      if (heroMs > endMs) heroMs = endMs;
    } else {
      // Hero handle drag — clamp tightly inside [startMs, endMs].
      heroMs = (heroMs + dMs).clamp(startMs, endMs);
    }
    final trimChanged =
        startMs != _effectiveStartMs || endMs != _effectiveEndMs;
    final heroChanged = heroMs != _effectiveHeroMs;
    if (!trimChanged && !heroChanged) return;
    if (trimChanged) widget.onTrimChanged(startMs, endMs);
    // Hero clamp on a begin/end drag also writes via onHeroChanged so
    // the host can persist the clamped offset (otherwise the saved
    // value drifts outside the trim window).
    if (heroChanged) widget.onHeroChanged(heroMs);
    // Live-frame scrub — show the frame the user is dragging TO.
    // Throttled because iOS Safari seekTo on H.264 can stutter
    // when called every gesture tick.
    final cb = widget.onHandleSeek;
    if (cb != null) {
      final now = DateTime.now();
      if (now.difference(_lastHandleSeekAt).inMilliseconds >= _seekThrottleMs) {
        _lastHandleSeekAt = now;
        final seekMs = switch (handle) {
          _TrimHandle.start => startMs,
          _TrimHandle.end => endMs,
          _TrimHandle.hero => heroMs,
        };
        cb(seekMs);
      }
    }
  }

  void _onTapHandle(_TrimHandle handle) {
    HapticFeedback.selectionClick();
    final commitMs = switch (handle) {
      _TrimHandle.start => _effectiveStartMs,
      _TrimHandle.end => _effectiveEndMs,
      _TrimHandle.hero => _effectiveHeroMs,
    };
    widget.onSelectionChanged(handle);
    widget.onScrub(commitMs);
  }

  void _onTapBar(TapUpDetails details) {
    if (_barWidth <= 0) return;
    final dx = details.localPosition.dx.clamp(0.0, _barWidth);
    final tapMs = (dx / _barWidth * widget.durationMs).round();
    // Only seek into the coral window — taps in the greyed bookends are
    // a no-op (those frames don't exist in the trimmed slice).
    if (tapMs < _effectiveStartMs || tapMs > _effectiveEndMs) return;
    // A tap on the bar between handles also clears any current handle
    // selection — the practitioner is jumping to an arbitrary frame,
    // not "holding" any of the three offsets.
    widget.onSelectionChanged(null);
    widget.onScrub(tapMs);
  }

  String _fmt(int ms) {
    final totalSec = (ms / 1000).round();
    final m = totalSec ~/ 60;
    final s = totalSec % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  /// Hi-res tooltip-style format (mockup uses `0:08.4`). Tenths of a
  /// second so Hero scrubbing reads precisely.
  String _fmtHiRes(int ms) {
    if (ms < 0) ms = 0;
    final totalSeconds = ms ~/ 1000;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    final tenths = (ms % 1000) ~/ 100;
    return '$minutes:${seconds.toString().padLeft(2, '0')}.$tenths';
  }

  String _trimmedReadout() {
    final trimmedMs = _effectiveEndMs - _effectiveStartMs;
    final trimmedFmt = _fmt(trimmedMs);
    final r = widget.reps;
    if (r == null || r <= 0) {
      return 'Trimmed: $trimmedFmt · — reps loops';
    }
    final loopMs = trimmedMs * r;
    return 'Trimmed: $trimmedFmt · $r reps loops in ${_fmt(loopMs)}';
  }

  @override
  Widget build(BuildContext context) {
    final isCompact = widget.compact;
    return Container(
      height: _TrimPanel.effectiveHeight(compact: isCompact),
      padding: isCompact
          ? const EdgeInsets.fromLTRB(10, 6, 10, 6)
          : const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Scrubber bar — fixed height to keep the layout deterministic.
          // Bumped from 40 → 44 so the Hero star (26px tall) has clearance
          // when the tooltip layers above it.
          SizedBox(
            height: 44,
            child: LayoutBuilder(
              builder: (context, constraints) {
                _barWidth = constraints.maxWidth;
                final startFrac = (_effectiveStartMs / widget.durationMs).clamp(
                  0.0,
                  1.0,
                );
                final endFrac = (_effectiveEndMs / widget.durationMs).clamp(
                  0.0,
                  1.0,
                );
                final heroFrac = (_effectiveHeroMs / widget.durationMs).clamp(
                  0.0,
                  1.0,
                );
                final startX = startFrac * _barWidth;
                final endX = endFrac * _barWidth;
                final heroX = heroFrac * _barWidth;
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: _onTapBar,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      // Bookend track (greyed bg).
                      Positioned(
                        left: 0,
                        right: 0,
                        top: 18,
                        height: 8,
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ),
                      // Coral fill between begin/end.
                      Positioned(
                        left: startX,
                        width: (endX - startX).clamp(0.0, _barWidth),
                        top: 18,
                        height: 8,
                        child: Container(
                          decoration: BoxDecoration(
                            color: AppColors.brandTintBg,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: AppColors.primary.withValues(alpha: 0.7),
                              width: 1,
                            ),
                          ),
                        ),
                      ),
                      // Begin handle — left bracket. Z-order: brackets
                      // first so the larger star can layer above them
                      // when collisions occur (per mockup state C).
                      _buildBracketHandle(
                        handle: _TrimHandle.start,
                        x: startX,
                        flash: _flashBegin,
                      ),
                      // End handle — right bracket.
                      _buildBracketHandle(
                        handle: _TrimHandle.end,
                        x: endX,
                        flash: _flashEnd,
                      ),
                      // Hero handle — star, slightly larger so it reads
                      // above the brackets at collisions.
                      _buildHeroHandle(
                        x: heroX,
                        flash: _flashHero,
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 4),
          // Tick row + live readout.
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '0:00',
                style: TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 9,
                  color: Colors.white.withValues(alpha: 0.45),
                ),
              ),
              Text(
                '${_fmt(_effectiveStartMs)}–${_fmt(_effectiveEndMs)}',
                style: const TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 9,
                  color: AppColors.primary,
                ),
              ),
              Text(
                _fmt(widget.durationMs),
                style: TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 9,
                  color: Colors.white.withValues(alpha: 0.45),
                ),
              ),
            ],
          ),
          if (!isCompact) ...[
            const Spacer(),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    _trimmedReadout(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: Colors.white,
                    ),
                  ),
                ),
                if (_hasTrim)
                  GestureDetector(
                    onTap: () {
                      HapticFeedback.selectionClick();
                      widget.onReset();
                    },
                    behavior: HitTestBehavior.opaque,
                    child: const Padding(
                      padding: EdgeInsets.only(left: 8),
                      child: Text(
                        '⤺ Reset to full video',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppColors.primary,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// Bracket handle (begin / end) — 14×22 white/coral glyph centered on
  /// the offset's x position. Tap → select + seek; horizontal drag →
  /// re-position. Surrounded by a transparent 36×40 hit zone so the
  /// touch target lands the Apple HIG side of comfortable.
  Widget _buildBracketHandle({
    required _TrimHandle handle,
    required double x,
    required AnimationController flash,
  }) {
    final selected = widget.selectedHandle == handle;
    final tooltipMs = handle == _TrimHandle.start
        ? _effectiveStartMs
        : _effectiveEndMs;
    return Positioned(
      left: x - 18, // 36/2 hit-zone half
      top: 0,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _onTapHandle(handle),
        onHorizontalDragStart: (_) {
          HapticFeedback.selectionClick();
          widget.onSelectionChanged(handle);
          widget.onDragStart?.call();
        },
        onHorizontalDragUpdate: (d) => _updateHandle(handle, d.delta.dx),
        onHorizontalDragEnd: (_) => _onHandleReleased(handle),
        onHorizontalDragCancel: () => _onHandleReleased(handle),
        child: SizedBox(
          width: 36,
          height: 44,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              // Tooltip — only when this handle is the selected one.
              // Sits above the glyph; positioned outside the bar via
              // negative top so it doesn't collide with the track.
              if (selected)
                Positioned(
                  top: -6,
                  child: _HandleTooltip(label: _fmtHiRes(tooltipMs)),
                ),
              // The glyph itself — flash AnimationController drives the
              // white→coral fill colour during playback crossings.
              AnimatedBuilder(
                animation: flash,
                builder: (context, _) {
                  final color = _resolveHandleColor(
                    selected: selected,
                    flashValue: flash.value,
                  );
                  return CustomPaint(
                    size: const Size(14, 22),
                    painter: _BracketPainter(
                      color: color,
                      isLeft: handle == _TrimHandle.start,
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Hero handle — 26×26 white/coral filled star. Slightly larger than
  /// the brackets so it reads above them at collisions (per mockup
  /// state C). Same tap + drag wiring; the drag path also clamps tightly
  /// inside the trim window.
  Widget _buildHeroHandle({
    required double x,
    required AnimationController flash,
  }) {
    final selected = widget.selectedHandle == _TrimHandle.hero;
    final tooltipMs = _effectiveHeroMs;
    return Positioned(
      left: x - 22, // 44/2 hit-zone half
      top: -2, // Star is taller than the bracket — nudge up so its
      //          centre still lands on the track midline.
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _onTapHandle(_TrimHandle.hero),
        onHorizontalDragStart: (_) {
          HapticFeedback.selectionClick();
          widget.onSelectionChanged(_TrimHandle.hero);
          widget.onDragStart?.call();
        },
        onHorizontalDragUpdate: (d) =>
            _updateHandle(_TrimHandle.hero, d.delta.dx),
        onHorizontalDragEnd: (_) => _onHandleReleased(_TrimHandle.hero),
        onHorizontalDragCancel: () => _onHandleReleased(_TrimHandle.hero),
        child: SizedBox(
          width: 44,
          height: 48,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              if (selected)
                Positioned(
                  top: -6,
                  child: _HandleTooltip(label: '★ ${_fmtHiRes(tooltipMs)}'),
                ),
              AnimatedBuilder(
                animation: flash,
                builder: (context, _) {
                  final color = _resolveHandleColor(
                    selected: selected,
                    flashValue: flash.value,
                  );
                  return CustomPaint(
                    size: const Size(26, 26),
                    painter: _StarPainter(color: color),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Idle = white. Selected = coral (single colour swap, no glow ring,
  /// no scale — mockup spec). Flashing during play interpolates white
  /// ↔ coral following the keyframe in the mockup CSS.
  Color _resolveHandleColor({
    required bool selected,
    required double flashValue,
  }) {
    if (selected) return AppColors.primary;
    if (flashValue == 0) return Colors.white;
    // Mockup keyframe: 0%→white, 15%→coral, 55%→coral, 100%→white. Map
    // that piecewise so the pulse holds at coral for the middle 40%.
    final Color resolved;
    if (flashValue < 0.15) {
      resolved =
          Color.lerp(Colors.white, AppColors.primary, flashValue / 0.15)!;
    } else if (flashValue < 0.55) {
      resolved = AppColors.primary;
    } else {
      resolved = Color.lerp(
        AppColors.primary,
        Colors.white,
        (flashValue - 0.55) / 0.45,
      )!;
    }
    return resolved;
  }
}

/// Three handle slots on the trim panel timeline.
enum _TrimHandle { start, hero, end }

/// Hi-res time tooltip — the small coral pill that floats above the
/// selected handle. Mirrors the mockup's `.tooltip` style: dark surface,
/// coral border + text, JetBrainsMono 9.5px.
class _HandleTooltip extends StatelessWidget {
  final String label;
  const _HandleTooltip({required this.label});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: const Color(0xF20F1117),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: AppColors.primary.withValues(alpha: 0.55),
            width: 1,
          ),
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontFamily: 'JetBrainsMono',
            fontSize: 9.5,
            fontWeight: FontWeight.w700,
            color: AppColors.primary,
            height: 1.1,
          ),
        ),
      ),
    );
  }
}

/// Custom painter for the begin/end bracket glyphs. Mirrors the mockup
/// CSS clip-path:
///   begin = polygon(0 0, 100% 0, 100% 4px, 5px 4px, 5px (100%-4px),
///                   100% (100%-4px), 100% 100%, 0 100%);
///   end   = mirror of begin.
class _BracketPainter extends CustomPainter {
  final Color color;
  final bool isLeft;

  const _BracketPainter({required this.color, required this.isLeft});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final w = size.width;
    final h = size.height;
    const stem = 5.0;
    const cap = 4.0;
    final path = Path();
    if (isLeft) {
      path.moveTo(0, 0);
      path.lineTo(w, 0);
      path.lineTo(w, cap);
      path.lineTo(stem, cap);
      path.lineTo(stem, h - cap);
      path.lineTo(w, h - cap);
      path.lineTo(w, h);
      path.lineTo(0, h);
      path.close();
    } else {
      path.moveTo(0, 0);
      path.lineTo(w, 0);
      path.lineTo(w, h);
      path.lineTo(0, h);
      path.lineTo(0, h - cap);
      path.lineTo(w - stem, h - cap);
      path.lineTo(w - stem, cap);
      path.lineTo(0, cap);
      path.close();
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _BracketPainter old) =>
      old.color != color || old.isLeft != isLeft;
}

/// Five-point star painter for the Hero handle. Mirrors the mockup
/// clip-path:
///   polygon(50% 0%, 61% 35%, 98% 35%, 68% 57%, 79% 91%, 50% 70%,
///           21% 91%, 32% 57%, 2% 35%, 39% 35%);
class _StarPainter extends CustomPainter {
  final Color color;

  const _StarPainter({required this.color});

  static const List<Offset> _starPoints = [
    Offset(0.50, 0.00),
    Offset(0.61, 0.35),
    Offset(0.98, 0.35),
    Offset(0.68, 0.57),
    Offset(0.79, 0.91),
    Offset(0.50, 0.70),
    Offset(0.21, 0.91),
    Offset(0.32, 0.57),
    Offset(0.02, 0.35),
    Offset(0.39, 0.35),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.45)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5);
    final path = Path();
    for (var i = 0; i < _starPoints.length; i++) {
      final p = _starPoints[i];
      final dx = p.dx * size.width;
      final dy = p.dy * size.height;
      if (i == 0) {
        path.moveTo(dx, dy);
      } else {
        path.lineTo(dx, dy);
      }
    }
    path.close();
    // Soft shadow first so the star reads above the bracket on collisions.
    canvas.save();
    canvas.translate(0, 1);
    canvas.drawPath(path, shadowPaint);
    canvas.restore();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _StarPainter old) => old.color != color;
}

// -----------------------------------------------------------------------------
// Wave 27 — crossfade tuner sheet
// -----------------------------------------------------------------------------

/// Bottom sheet with two sliders (lead + fade) and a "Reset to defaults"
/// button. Values commit immediately on slider release via [onChanged];
/// the parent debounces a SQLite save through SyncService.
class _CrossfadeTunerSheet extends StatefulWidget {
  final int initialLeadMs;
  final int initialFadeMs;
  final void Function({int? leadMs, int? fadeMs}) onChanged;
  final VoidCallback onReset;

  /// True when rendered inside a landscape popover (dialog-anchored).
  /// Drops the drag-handle + the rounded-top-only chrome that only
  /// makes sense for a bottom sheet, since the parent Container in the
  /// popover already provides the surface decoration.
  final bool compact;

  const _CrossfadeTunerSheet({
    required this.initialLeadMs,
    required this.initialFadeMs,
    required this.onChanged,
    required this.onReset,
    this.compact = false,
  });

  @override
  State<_CrossfadeTunerSheet> createState() => _CrossfadeTunerSheetState();
}

class _CrossfadeTunerSheetState extends State<_CrossfadeTunerSheet> {
  late int _lead;
  late int _fade;

  static const int _leadMin = 100;
  static const int _leadMax = 800;
  static const int _fadeMin = 50;
  static const int _fadeMax = 600;
  static const int _step = 10;

  @override
  void initState() {
    super.initState();
    _lead = widget.initialLeadMs.clamp(_leadMin, _leadMax);
    _fade = widget.initialFadeMs.clamp(_fadeMin, _fadeMax);
  }

  @override
  void didUpdateWidget(covariant _CrossfadeTunerSheet old) {
    super.didUpdateWidget(old);
    // External resets (parent's "Reset to defaults" → null → default
    // values) should reflect in the sheet without re-opening it.
    if (old.initialLeadMs != widget.initialLeadMs) {
      _lead = widget.initialLeadMs.clamp(_leadMin, _leadMax);
    }
    if (old.initialFadeMs != widget.initialFadeMs) {
      _fade = widget.initialFadeMs.clamp(_fadeMin, _fadeMax);
    }
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    final body = Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        widget.compact ? 16 : 12,
        20,
        widget.compact ? 16 : 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!widget.compact)
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: AppColors.surfaceBorder,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          const Text(
            'Loop crossfade tuning',
            style: TextStyle(
              fontFamily: 'Montserrat',
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: AppColors.textOnDark,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Tune how the seam between video loops blends. '
            'Affects this plan only — saved on publish.',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 12,
              fontWeight: FontWeight.w400,
              color: AppColors.textSecondaryOnDark,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 18),
          _TunerSliderRow(
            label: 'Lead time',
            valueLabel: '$_lead ms',
            helper: 'How early to start the next loop before the seam.',
            value: _lead.toDouble(),
            min: _leadMin.toDouble(),
            max: _leadMax.toDouble(),
            divisions: (_leadMax - _leadMin) ~/ _step,
            onChanged: (v) {
              setState(() => _lead = (v / _step).round() * _step);
              widget.onChanged(leadMs: _lead);
            },
          ),
          const SizedBox(height: 14),
          _TunerSliderRow(
            label: 'Fade duration',
            valueLabel: '$_fade ms',
            helper: 'How long the crossfade itself takes.',
            value: _fade.toDouble(),
            min: _fadeMin.toDouble(),
            max: _fadeMax.toDouble(),
            divisions: (_fadeMax - _fadeMin) ~/ _step,
            onChanged: (v) {
              setState(() => _fade = (v / _step).round() * _step);
              widget.onChanged(fadeMs: _fade);
            },
          ),
          const SizedBox(height: 18),
          Center(
            child: TextButton(
              onPressed: () {
                setState(() {
                  _lead = 250;
                  _fade = 200;
                });
                widget.onReset();
              },
              style: TextButton.styleFrom(foregroundColor: AppColors.primary),
              child: const Text(
                'Reset to defaults',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
    if (widget.compact) {
      // Popover host already provides the surface chrome — return the
      // raw column so we don't double-frame it.
      return body;
    }
    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets),
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.surfaceBase,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          border: Border(top: BorderSide(color: AppColors.surfaceBorder)),
        ),
        child: body,
      ),
    );
  }
}

class _TunerSliderRow extends StatelessWidget {
  final String label;
  final String valueLabel;
  final String helper;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;

  const _TunerSliderRow({
    required this.label,
    required this.valueLabel,
    required this.helper,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppColors.textOnDark,
              ),
            ),
            Text(
              valueLabel,
              style: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.primary,
              ),
            ),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: AppColors.primary,
            inactiveTrackColor: AppColors.surfaceBorder,
            thumbColor: AppColors.primary,
            overlayColor: AppColors.primary.withValues(alpha: 0.18),
            valueIndicatorColor: AppColors.primary,
            trackHeight: 3,
          ),
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
        Text(
          helper,
          style: const TextStyle(
            fontFamily: 'Inter',
            fontSize: 11,
            fontWeight: FontWeight.w400,
            color: AppColors.textSecondaryOnDark,
            height: 1.3,
          ),
        ),
      ],
    );
  }
}

/// Wave 39 (Item 5) — Studio reachability drop-pill.
///
/// 36×36 coral circular pill. Glyph swaps between
/// `arrow_downward_rounded` (latched-up, ready to drop) and
/// `arrow_upward_rounded` (already dropped, ready to reset). Tap fires
/// `onTap` — owner toggles the latched state.
///
/// Brand: coral fill, white glyph, soft shadow at 0.25 opacity for
/// just-enough lift off the dark list background. Matches the chrome
/// of `practice_chip.dart` and `inline_action_tray.dart` (coral over
/// surface, no inner stroke).
class _ReachabilityDropPill extends StatelessWidget {
  final bool latched;
  final VoidCallback onTap;

  const _ReachabilityDropPill({required this.latched, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: AppColors.primary,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Icon(
            latched ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
            size: 20,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}
