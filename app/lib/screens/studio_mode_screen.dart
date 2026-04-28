import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';
import '../models/client.dart';
import '../models/exercise_capture.dart';
import '../models/session.dart';
import '../services/conversion_service.dart';
import '../services/local_storage_service.dart';
import '../services/path_resolver.dart';
import '../services/sticky_defaults.dart';
import '../services/upload_service.dart';
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
import '../widgets/preset_chip_row.dart';
import '../widgets/session_expired_banner.dart';
import '../widgets/shell_pull_tab.dart';
import '../widgets/studio_bottom_bar.dart';
import '../widgets/studio_exercise_card.dart';
import '../widgets/treatment_segmented_control.dart';
import '../widgets/undo_snackbar.dart';
import '../services/auth_service.dart';
import '../widgets/orientation_lock_guard.dart';
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
    with SingleTickerProviderStateMixin {
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

  /// Wave 18.7 — cached sticky per-rep default for DURATION PER REP's
  /// Manual seed path. Loaded once from the cached client's
  /// `client_exercise_defaults.custom_duration_per_rep` key and
  /// refreshed whenever the practitioner commits a new Manual value.
  /// Null means "no sticky default; fall back to 5s". Keeps the Studio
  /// card synchronous — the DurationPerRepRow receives a resolved int?
  /// rather than a Future.
  int? _stickyCustomDurationPerRep;

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
    // Wave 18.7 — prime the sticky per-rep cache for this session's
    // client so the DURATION PER REP control can seed Manual from the
    // client's last-used value (not just the hard-coded 5s).
    unawaited(_loadStickyCustomDurationPerRep());
  }

  /// Wave 18.7 — load the client's sticky `custom_duration_per_rep`
  /// default from the cached client row. Best-effort: failure silently
  /// leaves the seed null (which the card then treats as "fall back
  /// to 5s"). Called once on init and again whenever the practitioner
  /// commits a new Manual value (so the next Manual seed inherits).
  Future<void> _loadStickyCustomDurationPerRep() async {
    final clientId = _session.clientId;
    if (clientId == null || clientId.isEmpty) return;
    try {
      final cached =
          await SyncService.instance.storage.getCachedClientById(clientId);
      if (!mounted) return;
      final raw =
          cached?.clientExerciseDefaults['custom_duration_per_rep'];
      int? parsed;
      if (raw is int) {
        parsed = raw;
      } else if (raw is num) {
        parsed = raw.toInt();
      } else if (raw is String) {
        parsed = int.tryParse(raw);
      }
      if (parsed != _stickyCustomDurationPerRep) {
        setState(() => _stickyCustomDurationPerRep = parsed);
      }
    } catch (e) {
      debugPrint('studio: loadStickyCustomDurationPerRep failed: $e');
    }
  }

  @override
  void didUpdateWidget(covariant StudioModeScreen old) {
    super.didUpdateWidget(old);
    if (old.session != widget.session) {
      setState(() => _session = widget.session);
    }
  }

  @override
  void dispose() {
    _conversionSub?.cancel();
    _lockTimer?.cancel();
    _pulseController.dispose();
    super.dispose();
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
    unawaited(widget.storage.saveSession(stamped).catchError((e, st) {
      debugPrint('saveSession (touchAndPush) failed: $e');
      return Future<void>.value();
    }));
  }

  Future<void> _refreshSession() async {
    final refreshed = await widget.storage.getSession(_session.id);
    if (refreshed != null && mounted) {
      setState(() => _pushSession(refreshed));
    }
  }

  void _listenToConversions() {
    _conversionSub =
        _conversionService.onConversionUpdate.listen((updated) {
      if (!mounted) return;
      setState(() {
        final exercises = List<ExerciseCapture>.from(_session.exercises);
        final idx = exercises.indexWhere((e) => e.id == updated.id);
        if (idx >= 0) {
          exercises[idx] = updated;
          _pushSession(_session.copyWith(exercises: exercises));
        }
      });
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
    '.mp4', '.mov', '.m4v', '.avi', '.mkv', '.webm', '.3gp', '.hevc'
  };

  MediaType _detectMediaType(String path) {
    final ext = p.extension(path).toLowerCase();
    return _videoExtensions.contains(ext)
        ? MediaType.video
        : MediaType.photo;
  }

  Future<void> _importFromLibrary({int? insertAt}) async {
    try {
      final picked = await _picker.pickMultipleMedia();
      if (picked.isEmpty) return;
      for (final xfile in picked) {
        final type = _detectMediaType(xfile.path);
        await _addCaptureFromFile(
          xfile.path,
          type,
          insertAt: insertAt,
        );
      }
    } catch (e) {
      debugPrint('Library import failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Import failed: $e')),
        );
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

    // Seed an exercise. ExerciseCapture.create(...) leaves reps / sets
    // / hold null; they read through as StudioDefaults on the card for
    // fresh clients. For clients with prior captures we overlay the
    // sticky per-client defaults (Milestone R / Wave 8) onto those
    // nulls — forward-only propagation, invisible to the practitioner.
    final exercises = List<ExerciseCapture>.from(_session.exercises);
    final position = insertAt ?? exercises.length;
    var exercise = ExerciseCapture.create(
      position: position,
      rawFilePath: PathResolver.toRelative(destPath),
      mediaType: type,
      sessionId: _session.id,
    );
    final clientId = _session.clientId;
    if (clientId != null && clientId.isNotEmpty) {
      final cached =
          await SyncService.instance.storage.getCachedClientById(clientId);
      if (cached != null && cached.clientExerciseDefaults.isNotEmpty) {
        exercise = StickyDefaults.prefillCapture(
          exercise,
          cached.clientExerciseDefaults,
        );
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
    final hasRestBelow = insertIndex < exercises.length &&
        exercises[insertIndex].isRest;
    final hasRestAbove =
        insertIndex > 0 && exercises[insertIndex - 1].isRest;
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
          final hasRestBelow = nextIdx < exercises.length &&
              exercises[nextIdx].isRest;
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
    unawaited(widget.storage.saveExercise(updated).catchError((e, st) {
      debugPrint('saveExercise failed: $e');
    }));
    // Sticky per-client defaults (Milestone R / Wave 8): every time the
    // practitioner edits one of the seven sticky fields on an existing
    // card, the new value becomes the default for the NEXT new capture
    // for this client. Forward-only — prior captures are unchanged.
    // Rest periods skip (they don't carry the reps/sets/hold/etc.
    // vocabulary).
    if (!updated.isRest) {
      StickyDefaults.recordAllDeltas(
        clientId: _session.clientId,
        before: previous,
        after: updated,
      );
      // Wave 18.7 — persist per-rep custom duration as a separate
      // sticky key so DURATION PER REP's Manual seed can mirror the
      // client's last-used per-rep cadence on the NEXT new capture.
      // (The existing `custom_duration_seconds` sticky key stores the
      // TOTAL — a per-rep-aware seed needs per-rep granularity
      // because reps can change between captures.)
      _maybeRecordCustomDurationPerRep(previous, updated);
    }
  }

  /// Wave 18.7 — if the practitioner committed a Manual per-rep value
  /// (customDurationSeconds changed and reps is known), queue a write
  /// to the client's `custom_duration_per_rep` sticky key. Updates
  /// the in-memory cache so the next card render seeds from the new
  /// value.
  void _maybeRecordCustomDurationPerRep(
    ExerciseCapture before,
    ExerciseCapture after,
  ) {
    final clientId = _session.clientId;
    if (clientId == null || clientId.isEmpty) return;
    final reps = after.reps ?? 0;
    if (reps <= 0) return;
    // Only write on transitions that look like a Manual commit — the
    // "From video" clear path (after.customDurationSeconds == null) is
    // NOT a sticky override, so we skip those.
    final total = after.customDurationSeconds;
    if (total == null) return;
    if (total == before.customDurationSeconds &&
        before.reps == after.reps) {
      return; // no-op
    }
    final perRep = (total / reps).round();
    if (perRep <= 0) return;
    if (perRep == _stickyCustomDurationPerRep) return;
    _stickyCustomDurationPerRep = perRep;
    unawaited(SyncService.instance
        .queueSetExerciseDefault(
          clientId: clientId,
          field: 'custom_duration_per_rep',
          value: perRep,
        )
        .catchError((e, st) {
      debugPrint('queueSetExerciseDefault(custom_duration_per_rep) '
          'failed: $e');
      return null;
    }));
  }

  void _deleteExercise(int index) {
    final removed = _session.exercises[index];
    final exercises = List<ExerciseCapture>.from(_session.exercises);
    exercises.removeAt(index);
    for (var i = 0; i < exercises.length; i++) {
      exercises[i] = exercises[i].copyWith(position: i);
    }
    setState(() {
      _touchAndPush(_session.copyWith(exercises: exercises));
      if (_expandedIndex == index) {
        _expandedIndex = null;
      } else if (_expandedIndex != null && _expandedIndex! > index) {
        _expandedIndex = _expandedIndex! - 1;
      }
    });
    unawaited(
      widget.storage.deleteExercise(removed.id).catchError((e, st) {
        debugPrint('deleteExercise failed: $e');
      }),
    );
    _saveExerciseOrder();
    showUndoSnackBar(
      context,
      label: '${removed.name ?? 'Exercise ${index + 1}'} deleted',
      onUndo: () async {
        await widget.storage.saveExercise(removed);
        await _refreshSession();
      },
    );
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
      final updatedCycles =
          Map<String, int>.from(_session.circuitCycles);
      if (!updatedCycles.containsKey(target) &&
          updatedCycles.containsKey(source)) {
        updatedCycles[target] = updatedCycles[source]!;
      }
      updatedCycles.remove(source);
      _pushSession(_session.copyWith(circuitCycles: updatedCycles));
    }
    setState(() {
      _touchAndPush(_session.copyWith(exercises: exercises));
    });
    _saveAllExercises(exercises);
    unawaited(widget.storage.saveSession(_session).catchError((e, st) {
      debugPrint('saveSession failed: $e');
    }));
  }

  void _breakCircuit(String circuitId) {
    // Remove the circuit-id from every member. Restore via undo.
    final originalExercises =
        List<ExerciseCapture>.from(_session.exercises);
    final originalCycles = Map<String, int>.from(_session.circuitCycles);
    final exercises = List<ExerciseCapture>.from(_session.exercises);
    for (var i = 0; i < exercises.length; i++) {
      if (exercises[i].circuitId == circuitId) {
        exercises[i] = exercises[i].copyWith(clearCircuitId: true);
      }
    }
    final updatedCycles = Map<String, int>.from(_session.circuitCycles);
    updatedCycles.remove(circuitId);
    setState(() {
      _touchAndPush(_session.copyWith(
        exercises: exercises,
        circuitCycles: updatedCycles,
      ));
    });
    _saveAllExercises(exercises);
    unawaited(widget.storage.saveSession(_session).catchError((e, st) {
      debugPrint('saveSession failed: $e');
    }));
    showUndoSnackBar(
      context,
      label: 'Circuit broken',
      onUndo: () async {
        setState(() {
          // Undoing is itself a content mutation — stamp so the dirty
          // indicator settles against the restored state, not the
          // pre-break state.
          _touchAndPush(_session.copyWith(
            exercises: originalExercises,
            circuitCycles: originalCycles,
          ));
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

    setState(() {
      _touchAndPush(_session.copyWith(
        exercises: exercises,
        circuitCycles: updatedCycles,
      ));
    });
    _saveAllExercises(exercises);
    unawaited(widget.storage.saveSession(_session).catchError((e, st) {
      debugPrint('saveSession failed: $e');
    }));
  }

  void _setCircuitCycles(String circuitId, int cycles) {
    setState(() {
      _touchAndPush(_session.setCircuitCycles(circuitId, cycles));
    });
    unawaited(widget.storage.saveSession(_session).catchError((e, st) {
      debugPrint('saveSession failed: $e');
    }));
  }

  void _renameCircuit(String circuitId, String name) {
    // Circuit "name" is not yet a first-class session field — we piggy-back
    // on circuitCycles for the spec's MVP. Persist as a
    // circuitId -> count map; names live in-memory until a follow-up
    // migration adds a dedicated column. For now: no-op.
    //
    // Leaving the hook wired so the sheet's name field still feels alive.
    // If callers need the value they can read it back from the sheet's
    // returned CircuitSheetResult.
  }

  Future<void> _saveAllExercises(List<ExerciseCapture> exercises) async {
    for (final ex in exercises) {
      await widget.storage.saveExercise(ex);
    }
  }

  Future<void> _openCircuitSheet(String circuitId) async {
    final cycles = _session.getCircuitCycles(circuitId);
    final letter = _circuitLetter(circuitId);
    final result = await showCircuitControlSheet(
      context,
      initialName: 'Circuit $letter',
      initialCycles: cycles,
      // A circuit with 1 cycle is just a regular exercise — enforce ≥2.
      minCycles: 2,
      maxCycles: 10,
    );
    if (result == null) return;
    _renameCircuit(circuitId, result.name);
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
        final nextSame = i < exercises.length - 1 &&
            exercises[i + 1].circuitId == cid;
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
                  onPreview: _openPreview,
                  onPublish: _publishFromToolbar,
                  // Wave 30 — tapping Publish on a still-mid-grace plan
                  // routes to the unlock sheet (two-tap UX so the
                  // practitioner sees the unlocked state before the
                  // republish).
                  onPublishLockedTap: _openUnlockSheet,
                  onUnlockTap: _openUnlockSheet,
                  onShowPublishError: () {
                    final err = _publishError;
                    if (err != null) _showPublishErrorSnackBar(err);
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
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: _buildExerciseList(),
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
        if (_focusedExerciseId != null && n.dragDetails != null &&
            n.scrollDelta != null && n.scrollDelta!.abs() > 4) {
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
    final isFirstInCircuit = isInCircuit &&
        (dataIndex == 0 ||
            exercises[dataIndex - 1].circuitId != exercise.circuitId);
    final isLastInCircuit = isInCircuit &&
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
        isExpanded: _expandedIndex == dataIndex,
        isFocused: isFocused,
        isInCircuit: isInCircuit,
        // Wave 18.7 — the card reads the sticky per-rep default when
        // seeding DURATION PER REP's Manual mode. Null means "no sticky
        // default for this client; fall back to 5s".
        stickyCustomDurationPerRep: _stickyCustomDurationPerRep,
        onTap: () {
          setState(() {
            _expandedIndex =
                _expandedIndex == dataIndex ? null : dataIndex;
            _activeInsertIndex = null;
            // Wave 35 — any direct user interaction with the list
            // clears the Preview-handoff focus marker. We treat tap
            // on ANY card as the "you've moved on" signal, including
            // the focused card itself (re-tap = collapse + clear).
            _focusedExerciseId = null;
          });
        },
        onUpdate: (u) {
          _clearFocusOnInteraction();
          _updateExercise(dataIndex, u);
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
        direction: DismissDirection.endToStart,
        background: Container(
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
        confirmDismiss: (_) async => true,
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
          if (isFirstInCircuit)
            _buildCircuitHeaderRow(exercise.circuitId!),
          // The row: a Stack that the card's intrinsic height drives.
          ReorderableDelayedDragStartListener(
            index: visualIndex,
            child: Stack(
              children: [
                // Non-positioned child — drives the row's height. Left
                // margin of (kGutterVisibleWidth + 4) leaves the gutter
                // strip free for the rail.
                Padding(
                  padding: const EdgeInsets.only(
                    left: kGutterVisibleWidth + 4,
                  ),
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
            Icon(
              Icons.delete_outline,
              color: Colors.white,
              size: 22,
            ),
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
          // background instead of blending. Matches the way DOSE chips
          // render against the exercise card's surfaceBase body.
          color: AppColors.surfaceBase,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: AppColors.rest.withValues(alpha: 0.3),
          ),
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
            child: GestureDetector(
              onTap: () => _openCircuitSheet(circuitId),
              behavior: HitTestBehavior.opaque,
              child: Container(
                height: 32,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                // No bottom border — the 6px rail-carrying spacer below
                // (added in _buildCircuitHeaderRow's Column) plus the
                // header's own tinted background + coral text already
                // read as a distinct bar. A 2px coral underline here was
                // redundant and visually compressed the space between
                // the header and the first card.
                child: Row(
                  children: [
                    Text(
                      'CIRCUIT $letter',
                      style: const TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5,
                        color: AppColors.primary,
                      ),
                    ),
                    const Spacer(),
                    Container(
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
                  ],
                ),
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
    final sameCircuit = lower != null &&
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
    final hasConversionsRunning = _session.exercises.any((e) =>
        !e.isRest &&
        (e.conversionStatus == ConversionStatus.pending ||
            e.conversionStatus == ConversionStatus.converting));
    final hasExercises =
        _session.exercises.where((e) => !e.isRest).isNotEmpty;
    return hasExercises && !hasConversionsRunning && !_isPublishing;
  }

  Future<void> _publishFromToolbar() async {
    // Extra guard — archive compression can trail the line-drawing
    // conversion; publishing before the raw-archive lands would
    // silently skip B&W / Original playback. Match the client-sessions
    // check so the toolbar never regresses that fix.
    final hasConversionsRunning = _session.exercises.any((e) =>
        !e.isRest &&
        (e.conversionStatus == ConversionStatus.pending ||
            e.conversionStatus == ConversionStatus.converting));
    final hasArchiveInFlight = _session.exercises.any((e) =>
        !e.isRest &&
        e.mediaType == MediaType.video &&
        e.conversionStatus == ConversionStatus.done &&
        (e.archiveFilePath == null || e.archiveFilePath!.isEmpty));
    if (hasConversionsRunning || hasArchiveInFlight) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(hasArchiveInFlight
                ? 'Still archiving videos — one moment…'
                : 'Wait for conversions to finish before publishing'),
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
    try {
      final fullSession = await widget.storage.getSession(_session.id);
      if (fullSession == null) return;
      result = await _uploadService.uploadPlan(fullSession);
    } catch (e) {
      result = PublishResult.networkFailed(error: e);
    } finally {
      if (mounted) {
        // Refresh local state — `uploadPlan` rewrites the session row.
        await _refreshSession();
        setState(() => _isPublishing = false);
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
    } else if (result.isUnconsentedTreatments) {
      await _handleUnconsentedTreatments(result.unconsented!);
    } else if (result.isNeedsConsentConfirmation) {
      await _handleNeedsConsentConfirmation(
        result.consentConfirmationClient!,
      );
    } else {
      final errStr = result.toErrorString();
      setState(() => _publishError = errStr);
      _showPublishErrorSnackBar(errStr);
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
      _showPublishErrorSnackBar(
        'Not enough credits to unlock. Balance: ${balance ?? 0}. '
        'Buy more via manage.homefit.studio.',
      );
    } else {
      _showPublishErrorSnackBar('Unlock failed: ${response['reason'] ?? 'unknown'}');
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

  void _showPublishErrorSnackBar(String error) {
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
            onPressed: _publishFromToolbar,
          ),
        ),
      );
  }

  // Wave 38 — `_shareFromToolbar` retired. The new bottom toolbar
  // (back / preview / publish) no longer has a share action; share
  // affordance is reached from the published-session card via the
  // dedicated `NetworkShareSheet` in W30.

  void _openPreview() {
    HapticFeedback.selectionClick();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => UnifiedPreviewScreen(
          session: _session,
          storage: widget.storage,
        ),
      ),
    );
  }

  Future<void> _openMediaViewer(ExerciseCapture exercise) async {
    if (exercise.isRest) return;
    // Build a list of the non-rest exercises so the viewer can page
    // through them. Rests don't have media, so pulling them out keeps
    // every page a real media slide.
    final mediaList =
        _session.exercises.where((e) => !e.isRest).toList(growable: false);
    final initialIndex =
        mediaList.indexWhere((e) => e.id == exercise.id);
    if (initialIndex < 0) return;

    if (!mounted) return;
    // Wave 35 — clear any stale exit-inbox id from a previous viewer
    // pop that was already handled (defence-in-depth; the takeLast
    // call after the await is the canonical clear).
    _MediaViewerExitInbox.lastClosedExerciseId = null;
    final result = await Navigator.of(context).push<Object?>(
      MaterialPageRoute<Object?>(
        fullscreenDialog: true,
        builder: (_) => _MediaViewer(
          exercises: mediaList,
          initialIndex: initialIndex,
          session: _session,
          // When the practitioner cycles treatment on an exercise, the
          // viewer writes to local SQLite directly. We bubble the change
          // up here so the Studio card tiles + in-memory session stay in
          // sync without waiting for the route to pop.
          onExerciseUpdate: (updated) {
            final dataIndex = _session.exercises
                .indexWhere((e) => e.id == updated.id);
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
    //     PopScope stamps the id into _MediaViewerExitInbox.
    String? focusId;
    if (result is String && result.isNotEmpty) {
      focusId = result;
    } else {
      focusId = _MediaViewerExitInbox.takeLastClosedExerciseId();
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
  int get _duration => widget.exercise.holdSeconds ?? 30;

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
      child: Row(
        // Wave 18.3.1 — top-align so the icon + "Rest" pair stay
        // anchored at the top of the row when the chip row wraps to
        // multiple lines. Center would drift them down as the chip row
        // grows.
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Wave 30 — icon + label as ONE element. Earlier the two were
          // padded independently (icon top:11, label top:12) and read as
          // "icon centred + label nudged down". Shared 40pt SizedBox
          // matches the chip row's vertical box, with center alignment
          // giving icon + label a single visual centre line.
          const SizedBox(
            height: 40,
            child: Padding(
              padding: EdgeInsets.only(left: 4, right: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Icon(
                    Icons.self_improvement,
                    size: 18,
                    color: AppColors.rest,
                  ),
                  SizedBox(width: 8),
                  Text(
                    'Rest',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.rest,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: PresetChipRow(
              controlKey: 'rest',
              canonicalPresets: const <num>[15, 30, 60, 90],
              currentValue: _duration,
              onChanged: (v) {
                widget.onUpdate(
                  widget.exercise.copyWith(holdSeconds: v.round()),
                );
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
          // Delete × removed — swipe-left on the whole rest row
          // triggers onDelete via the rest-row Dismissible wired up in
          // _buildRestRow. Consistent with exercise cards, which get
          // their own Dismissible wrapper in _buildRowWithContext.
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
  return ext.endsWith('.jpg') ||
      ext.endsWith('.jpeg') ||
      ext.endsWith('.png');
}

/// Wave 35 — module-level inbox for the Preview → Studio focus handoff.
///
/// `_MediaViewer` ("Preview" in user-facing copy) returns the id of the
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
class _MediaViewerExitInbox {
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
class _MediaViewer extends StatefulWidget {
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

  const _MediaViewer({
    required this.exercises,
    required this.initialIndex,
    this.onExerciseUpdate,
    this.session,
    this.onSessionUpdate,
  });

  @override
  State<_MediaViewer> createState() => _MediaViewerState();
}

class _MediaViewerState extends State<_MediaViewer> {
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

  /// Wave 25 — Enhanced Background flag (R-10 twin of the web player's
  /// gear-popover switch). When true, B&W + Original treatments play
  /// the segmented raw file (Vision body-pop + dimmed background, same
  /// mask the line drawing uses). When false, they play the untouched
  /// archive — the practitioner sees exactly the colour file the
  /// segmented variant was derived from. Defaults true to mirror the
  /// web player.
  ///
  /// Persisted per-device under [_enhancedBackgroundPrefsKey] in
  /// SharedPreferences — single global preference, not per-exercise —
  /// hydrated in [initState] so the viewer opens on the practitioner's
  /// last choice.
  bool _enhancedBackground = true;

  /// Carl 2026-04-24: while a trim handle is being dragged, the video
  /// is paused and the practitioner can scrub. We remember whether
  /// the controller was playing pre-drag so we can resume on release.
  bool _trimDragWasPlaying = false;

  /// Wave 27 — suspends [_enforceTrimWindow] while a trim handle is
  /// mid-drag. Right-handle drags seek to the new end, the listener
  /// then sees `position >= endMs` and would yank back to start; this
  /// flag breaks that loop without affecting normal playback wrap.
  bool _trimDragInProgress = false;
  static const String _enhancedBackgroundPrefsKey =
      'homefit.preview.enhanced_background';

  /// Wave 20 — debounce for the trim-panel SQLite write. The drag
  /// callback fires every gesture tick; we coalesce to one write per
  /// 200 ms so the disk doesn't take a beating during a long drag.
  Timer? _trimSaveTimer;

  /// Wave 27 — debounce for the crossfade-tuner SQLite write. Slider
  /// drags emit one event per pixel; coalesce to one save per 250 ms.
  Timer? _crossfadePersistTimer;

  ExerciseCapture get _current => _exercises[_currentIndex];

  bool _isVideo(ExerciseCapture e) =>
      e.mediaType == MediaType.video && !_isStillImageConversion(e);

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
    final rawIsImage = ext.endsWith('.jpg') ||
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
    // Wave 25 — hydrate the Enhanced Background toggle from SharedPreferences
    // off the main frame so initState stays sync. Once we know the persisted
    // value, rebind the active video IF the resolved source path actually
    // changes (segmented vs untouched archive). No flicker on the common
    // case where the persisted value matches the default (true).
    _hydrateEnhancedBackgroundPreference();
  }

  @override
  void didUpdateWidget(covariant _MediaViewer old) {
    super.didUpdateWidget(old);
    // Wave 27 — keep the local session mirror in sync if the parent
    // pushes a fresh copy (e.g. after publish version-bump). Don't
    // overwrite while a debounced tuner write is pending — the parent
    // would re-emit our pending value after `saveSession` resolves and
    // would miss intermediate slider drags.
    final pending = _crossfadePersistTimer;
    if (old.session != widget.session && (pending == null || !pending.isActive)) {
      _session = widget.session;
    }
  }

  /// Wave 25 — read the Enhanced Background toggle from SharedPreferences.
  /// Async-safe: bails on `!mounted`. When the persisted value differs
  /// from the in-memory default we rebind the active video so playback
  /// switches sources without the practitioner having to tap the pill.
  Future<void> _hydrateEnhancedBackgroundPreference() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getBool(_enhancedBackgroundPrefsKey);
      if (stored == null || !mounted) return;
      if (stored == _enhancedBackground) return;
      setState(() => _enhancedBackground = stored);
      // Only rebind if currently rendering a treatment that consults the
      // toggle — Line is unaffected, so don't churn the controller.
      if (_treatment != Treatment.line && _isVideo(_current)) {
        _initVideoForCurrent();
      }
    } catch (e) {
      debugPrint('MediaViewer: enhanced-bg pref hydrate failed — $e');
    }
  }

  /// Whether the Enhanced Background toggle is meaningful for the current
  /// exercise + treatment. Line drawings have no background to dim, so
  /// the pill greys out + ignores taps when [_treatment] is
  /// [Treatment.line]. Photos / rest rows hide the pill entirely (the
  /// build() guard piggy-backs on `_isVideo`).
  bool get _enhancedBackgroundEnabled => _treatment != Treatment.line;

  /// Wave 25 — toggle the Enhanced Background pill. Writes to
  /// SharedPreferences (fire-and-forget) and rebinds the active video
  /// so the new source loads. Called only when the pill is enabled —
  /// the build-time guard prevents taps when [_treatment] is
  /// [Treatment.line].
  void _onEnhancedBackgroundToggle() {
    if (!_enhancedBackgroundEnabled) return;
    HapticFeedback.selectionClick();
    setState(() => _enhancedBackground = !_enhancedBackground);
    // Persist — fire-and-forget; the user has already seen the optimistic
    // pill state change, no need to await.
    unawaited(
      () async {
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool(
            _enhancedBackgroundPrefsKey,
            _enhancedBackground,
          );
        } catch (e) {
          debugPrint('MediaViewer: enhanced-bg pref save failed — $e');
        }
      }(),
    );
    // Rebind so the new source loads. _initVideoForCurrent rebuilds the
    // controller from scratch — same pattern the treatment switch uses.
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
    Future.wait<void>([controllerA.initialize(), controllerB.initialize()]).then((_) {
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
    }).catchError((e) {
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
    final hasTrim =
        trimStart != null && trimEnd != null && trimEnd > trimStart;
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
    final hasTrim =
        trimStart != null && trimEnd != null && trimEnd > trimStart;
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
  double _bottomChromeTrimLiftFor({required bool compact}) =>
      _trimPanelVisible
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
    c.seekTo(Duration(milliseconds: positionMs));
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
    // LocalStorageService handle through the _MediaViewer constructor
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
        _MediaViewerExitInbox.lastClosedExerciseId = id;
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
                      onVerticalDragEnd:
                          isCurrent ? _handleVerticalDragEnd : null,
                      onTap: isCurrent && isVideo ? _togglePlayPause : null,
                      behavior: HitTestBehavior.opaque,
                      child: Center(
                        child: isVideo
                            ? (isCurrent
                                ? AnimatedSwitcher(
                                    duration:
                                        const Duration(milliseconds: 220),
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
                          top: 0,
                          bottom: 0,
                          child: SafeArea(
                            child: Align(
                              alignment: Alignment.centerLeft,
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
                          maxWidth:
                              MediaQuery.of(context).size.width - 96,
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
                    bottom: MediaQuery.of(context).padding.bottom +
                        ((widget.exercises.length > 1 &&
                                widget.exercises.length <= 10)
                            ? 48
                            : 20) +
                        _bottomChromeTrimLiftFor(compact: isLandscape),
                    child: _PlayPauseOverlayButton(
                      isPlaying:
                          _activeController?.value.isPlaying ?? false,
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
                    bottom: MediaQuery.of(context).padding.bottom +
                        16 +
                        _bottomChromeTrimLiftFor(compact: isLandscape),
                    child: IgnorePointer(
                      child: _MediaViewerDotIndicator(
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
                    bottom: MediaQuery.of(context).padding.bottom +
                        12 +
                        _bottomChromeTrimLiftFor(compact: isLandscape),
                    child: _buildBottomLeftChromeCluster(
                      isLandscape: isLandscape,
                    ),
                  ),

                // Soft-trim editor. Compact bar in landscape.
                if (_trimPanelVisible)
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: MediaQuery.of(context).padding.bottom + 8,
                    child: _TrimPanel(
                      durationMs: _activeController!
                          .value.duration.inMilliseconds,
                      startOffsetMs: _current.startOffsetMs,
                      endOffsetMs: _current.endOffsetMs,
                      reps: _current.reps,
                      compact: isLandscape,
                      onTrimChanged: (s, e) => _persistTrim(s, e),
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
                        onTap: () => _openCrossfadeTuner(
                          asPopover: isLandscape,
                        ),
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
      tooltipWhenDisabled:
          'Body focus applies to colour playback only.',
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
  /// Consent now lives at the client level (ClientSessionsScreen). The
  /// inline toggle that used to sit below this pill is gone, so when a
  /// segment is locked we gently point the practitioner at where to go
  /// grant access. Haptic + short SnackBar; no modal (R-01).
  void _onLockedSegmentTap() {
    HapticFeedback.lightImpact();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Grant consent on the client page to enable this treatment.',
        ),
        duration: Duration(seconds: 2),
      ),
    );
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
          final segIsImage = segExt.endsWith('.jpg') ||
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
        final rawIsImage = ext.endsWith('.jpg') ||
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
      image = ColorFiltered(
        colorFilter: grayscaleColorFilter,
        child: image,
      );
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
        child: Center(
          child: CircularProgressIndicator(color: Colors.white54),
        ),
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
          children: [
            slot(a, _activeSlot == 'a'),
            slot(b, _activeSlot == 'b'),
          ],
        ),
      ),
    );
    if (_treatment == Treatment.grayscale) {
      stack = ColorFiltered(
        colorFilter: grayscaleColorFilter,
        child: stack,
      );
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
                        border:
                            Border.all(color: AppColors.surfaceBorder),
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
/// Body focus pill in [_MediaViewer]'s bottom-left chrome cluster.
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
        ? Tooltip(message: msg, triggerMode: TooltipTriggerMode.tap, child: pill)
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

  const _RotatePill({
    required this.onTap,
    required this.onLongPress,
  });

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
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
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
/// [_MediaViewer]. Presence in the tree is stable whenever the current
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
                isPlaying
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
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
class _MediaViewerDotIndicator extends StatelessWidget {
  final int total;
  final int activeIndex;

  const _MediaViewerDotIndicator({
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
      child: Icon(
        Icons.play_circle_outline,
        size: 72,
        color: Colors.white24,
      ),
    );
  }
}

// ============================================================================
// Wave 20 — Soft-trim editor for the [_MediaViewer].
// ============================================================================

/// Bottom-anchored trim panel shown beneath the video on the [_MediaViewer]
/// when the active exercise is a video at least 1 second long. Two coral
/// drag-handles set the in/out window; coral fill between them shows the
/// trimmed slice; greyed bookends show the discarded frames. Live readout
/// underneath. "Reset to full video" link reveals when either offset is
/// non-null.
///
/// Pure widget — owns NO state. The host (`_MediaViewerState`) holds the
/// canonical trim values and rebuilds this widget whenever they change.
/// Drag callbacks fire continuously; the host is expected to debounce its
/// SQLite write, not us.
///
/// Drag rules enforced HERE (kept tight so the host doesn't have to
/// duplicate the math):
///   * minimum 0.3s window between handles — bumping the guard fires a
///     light-haptic via the [onGuardHit] callback.
///   * handles cannot cross.
///   * tap inside the coral range emits a [onScrub] with the resolved
///     ms position; tap inside the greyed bookends is a no-op.
///
/// Long-press 4× zoom is NOT shipped in v1 — punted to a follow-up. The
/// drag affordance alone is acceptable per the brief.
class _TrimPanel extends StatefulWidget {
  /// Total length of the underlying media in ms. Comes straight off the
  /// `VideoPlayerController.value.duration`. Caller must guarantee >= 1000.
  final int durationMs;

  /// Active in-point in ms. Null = "no trim — start at 0". The widget
  /// always paints with concrete values, falling back to 0 when null.
  final int? startOffsetMs;

  /// Active out-point in ms. Null = "no trim — end at duration".
  final int? endOffsetMs;

  /// Reps count for the live readout's loop math. Null / 0 collapses
  /// the math to "—".
  final int? reps;

  /// Fired continuously while the user drags either handle. Caller is
  /// responsible for persisting (debounced).
  final void Function(int startMs, int endMs) onTrimChanged;

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

  /// Fired the moment a drag begins on either handle. Caller pauses
  /// the active video so the practitioner can scrub freely without
  /// the loop confusing the visual. Carl 2026-04-24: was: video kept
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
    required this.reps,
    required this.onTrimChanged,
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

class _TrimPanelState extends State<_TrimPanel> {
  // Cache the bar width on each layout pass so onPan* can convert
  // pixels → ms without touching the BuildContext.
  double _barWidth = 0;

  // Throttle haptic guard hits + live-frame seek calls — at 60Hz drag
  // we'd fire dozens per second otherwise. Seeks at &gt;30Hz on iOS
  // Safari can stutter; haptics at &gt;4Hz feel mushy.
  DateTime _lastGuardHapticAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastHandleSeekAt = DateTime.fromMillisecondsSinceEpoch(0);

  static const int _minWindowMs = 300; // 0.3s minimum window per the brief.
  static const int _seekThrottleMs = 33; // ~30Hz cap on live seek.

  int get _effectiveStartMs => widget.startOffsetMs ?? 0;
  int get _effectiveEndMs => widget.endOffsetMs ?? widget.durationMs;
  bool get _hasTrim => widget.startOffsetMs != null || widget.endOffsetMs != null;

  void _maybeFireGuard() {
    final now = DateTime.now();
    if (now.difference(_lastGuardHapticAt).inMilliseconds < 250) return;
    _lastGuardHapticAt = now;
    widget.onGuardHit();
  }

  /// Trailing-edge seek + drag-end. The throttle in `_updateHandle`
  /// can skip the very last gesture tick; firing one final seek here
  /// guarantees the video lands on the position the user actually
  /// released at (zero drift on resume).
  void _onHandleReleased(_TrimHandle handle) {
    widget.onHandleSeek?.call(
      handle == _TrimHandle.start ? _effectiveStartMs : _effectiveEndMs,
    );
    widget.onDragEnd?.call();
  }

  void _updateHandle(_TrimHandle handle, double dx) {
    if (_barWidth <= 0) return;
    final dMs = (dx / _barWidth * widget.durationMs).round();
    var startMs = _effectiveStartMs;
    var endMs = _effectiveEndMs;
    if (handle == _TrimHandle.start) {
      startMs = (startMs + dMs).clamp(0, widget.durationMs - _minWindowMs);
      // Don't cross the end handle.
      if (startMs > endMs - _minWindowMs) {
        startMs = endMs - _minWindowMs;
        _maybeFireGuard();
      }
    } else {
      endMs = (endMs + dMs).clamp(_minWindowMs, widget.durationMs);
      if (endMs < startMs + _minWindowMs) {
        endMs = startMs + _minWindowMs;
        _maybeFireGuard();
      }
    }
    if (startMs == _effectiveStartMs && endMs == _effectiveEndMs) return;
    widget.onTrimChanged(startMs, endMs);
    // Live-frame scrub — show the frame the user is dragging TO.
    // Throttled because iOS Safari seekTo on H.264 can stutter
    // when called every gesture tick.
    final cb = widget.onHandleSeek;
    if (cb != null) {
      final now = DateTime.now();
      if (now.difference(_lastHandleSeekAt).inMilliseconds >= _seekThrottleMs) {
        _lastHandleSeekAt = now;
        cb(handle == _TrimHandle.start ? startMs : endMs);
      }
    }
  }

  void _onTapBar(TapUpDetails details) {
    if (_barWidth <= 0) return;
    final dx = details.localPosition.dx.clamp(0.0, _barWidth);
    final tapMs = (dx / _barWidth * widget.durationMs).round();
    // Only seek into the coral window — taps in the greyed bookends are
    // a no-op (those frames don't exist in the trimmed slice).
    if (tapMs < _effectiveStartMs || tapMs > _effectiveEndMs) return;
    widget.onScrub(tapMs);
  }

  String _fmt(int ms) {
    final totalSec = (ms / 1000).round();
    final m = totalSec ~/ 60;
    final s = totalSec % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
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
          SizedBox(
            height: 40,
            child: LayoutBuilder(
              builder: (context, constraints) {
                _barWidth = constraints.maxWidth;
                final startFrac = (_effectiveStartMs / widget.durationMs)
                    .clamp(0.0, 1.0);
                final endFrac = (_effectiveEndMs / widget.durationMs)
                    .clamp(0.0, 1.0);
                final startX = startFrac * _barWidth;
                final endX = endFrac * _barWidth;
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
                        top: 16,
                        height: 8,
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ),
                      // Coral fill between handles.
                      Positioned(
                        left: startX,
                        width: (endX - startX).clamp(0.0, _barWidth),
                        top: 16,
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
                      // Start handle.
                      Positioned(
                        left: startX - 14,
                        top: 0,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onPanStart: (_) {
                            HapticFeedback.selectionClick();
                            widget.onDragStart?.call();
                          },
                          onPanUpdate: (d) => _updateHandle(
                            _TrimHandle.start,
                            d.delta.dx,
                          ),
                          onPanEnd: (_) => _onHandleReleased(_TrimHandle.start),
                          onPanCancel: () => _onHandleReleased(_TrimHandle.start),
                          child: const _TrimHandlePill(),
                        ),
                      ),
                      // End handle.
                      Positioned(
                        left: endX - 14,
                        top: 0,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onPanStart: (_) {
                            HapticFeedback.selectionClick();
                            widget.onDragStart?.call();
                          },
                          onPanUpdate: (d) => _updateHandle(
                            _TrimHandle.end,
                            d.delta.dx,
                          ),
                          onPanEnd: (_) => _onHandleReleased(_TrimHandle.end),
                          onPanCancel: () => _onHandleReleased(_TrimHandle.end),
                          child: const _TrimHandlePill(),
                        ),
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
}

enum _TrimHandle { start, end }

/// Coral pill drag-handle for the trim panel. 28×40 keeps the touch
/// target generous (Apple HIG minimum is 44×44 but the panel is dense;
/// the panel-level GestureDetector hit area is closer to 40×40 with the
/// surrounding margin, plus the bar's own onTapUp gives a fallback).
class _TrimHandlePill extends StatelessWidget {
  const _TrimHandlePill();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 28,
      height: 40,
      decoration: BoxDecoration(
        color: AppColors.primary,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.85),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: const Center(
        child: SizedBox(
          width: 2,
          height: 16,
          child: DecoratedBox(
            decoration: BoxDecoration(color: Colors.white),
          ),
        ),
      ),
    );
  }
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
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.primary,
                ),
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


