import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';
import '../models/client.dart';
import '../models/exercise_capture.dart';
import '../models/session.dart';
import '../services/conversion_service.dart';
import '../services/local_storage_service.dart';
import '../services/path_resolver.dart';
import '../theme.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../models/treatment.dart';
import '../services/sync_service.dart';
import '../widgets/circuit_control_sheet.dart';
import '../widgets/client_consent_sheet.dart';
import '../widgets/gutter_rail.dart';
import '../widgets/inline_action_tray.dart';
import '../widgets/inline_editable_text.dart';
import '../widgets/practice_chip.dart';
import '../widgets/shell_pull_tab.dart';
import '../widgets/studio_exercise_card.dart';
import '../widgets/treatment_segmented_control.dart';
import '../widgets/undo_snackbar.dart';
import 'plan_preview_screen.dart';

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

  @override
  void initState() {
    super.initState();
    _session = widget.session;
    _conversionService = ConversionService.instance;
    _listenToConversions();
    _lockTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
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

  /// Rename the current session. Writes to [Session.title] — the
  /// practitioner-editable display name that session cards render — NOT
  /// [Session.clientName] (which is now a legacy mirror of the parent
  /// [Client.name] and would make the rename invisible on the session
  /// list because cards read `title ?? clientName`).
  void _saveClientName(String newName) {
    final trimmed = newName.trim();
    final currentDisplay = _displayTitle(_session);
    if (trimmed.isEmpty || trimmed == currentDisplay) return;
    setState(() {
      _pushSession(_session.copyWith(title: trimmed));
    });
    unawaited(widget.storage.saveSession(_session).catchError((e, st) {
      debugPrint('saveSession failed: $e');
    }));
  }

  /// Same resolution order as `SessionCard._cardTitle`: title when set,
  /// else clientName. Used by the inline-edit's initial value so the
  /// rename field shows whatever the list shows.
  static String _displayTitle(Session s) {
    final t = s.title;
    if (t != null && t.trim().isNotEmpty) return t;
    return s.clientName;
  }

  // ---------------------------------------------------------------------------
  // Publish-lock state
  // ---------------------------------------------------------------------------
  //
  // Lock rules:
  //   - Before first publish → edits free (lock inactive).
  //   - Published AND < 24h since first publish AND client has not opened →
  //     open edit window. Chip counts down.
  //   - Client has opened OR 24h elapsed → locked. Credit-costing affordances
  //     (new exercise, drag-reorder, delete, break circuit) dim and
  //     show the "counts as a new version · 1 credit" toast on tap.

  bool get _isPublishLocked {
    if (!_session.isPublished) return false;
    if (_session.firstOpenedAt != null) return true;
    final last = _session.lastPublishedAt;
    if (last == null) return false;
    return DateTime.now().difference(last) >= const Duration(hours: 24);
  }

  bool get _inOpenEditWindow => _session.isPublished && !_isPublishLocked;

  int get _hoursRemainingInWindow {
    final last = _session.lastPublishedAt;
    if (last == null) return 0;
    final remaining =
        const Duration(hours: 24) - DateTime.now().difference(last);
    return remaining.inHours.clamp(0, 24);
  }

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

    // Seed an exercise. Note: ExerciseCapture.create(...) leaves reps /
    // sets / hold null — they read through as StudioDefaults via the
    // card. We don't pre-fill them on the model so "customised" detection
    // stays accurate (R-05): a card with no user input reads as
    // uncustomised.
    final exercises = List<ExerciseCapture>.from(_session.exercises);
    final position = insertAt ?? exercises.length;
    final exercise = ExerciseCapture.create(
      position: position,
      rawFilePath: PathResolver.toRelative(destPath),
      mediaType: type,
      sessionId: _session.id,
    );
    exercises.insert(position, exercise);
    for (var i = 0; i < exercises.length; i++) {
      exercises[i] = exercises[i].copyWith(position: i);
    }
    await widget.storage.saveExercise(exercise);

    if (mounted) {
      setState(() {
        _pushSession(_session.copyWith(exercises: exercises));
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
        _pushSession(_session.copyWith(exercises: exercises));
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
      _pushSession(_session.copyWith(exercises: exercises));
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
      _pushSession(_session.copyWith(exercises: exercises));
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
    setState(() {
      final exercises = List<ExerciseCapture>.from(_session.exercises);
      exercises[index] = updated;
      _pushSession(_session.copyWith(exercises: exercises));
    });
    unawaited(widget.storage.saveExercise(updated).catchError((e, st) {
      debugPrint('saveExercise failed: $e');
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
      _pushSession(_session.copyWith(exercises: exercises));
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
      _pushSession(_session.copyWith(exercises: exercises));
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
      _pushSession(_session.copyWith(
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
          _pushSession(_session.copyWith(
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
    if (_isPublishLocked) {
      showPublishLockToast(context);
      return;
    }
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
      _pushSession(_session.copyWith(
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
      _pushSession(_session.setCircuitCycles(circuitId, cycles));
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
      breakLocked: _isPublishLocked,
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
    // Reorder is a "credit-costing" structural change once the plan is
    // locked. Intercept and surface the tooltip-toast instead.
    if (_isPublishLocked) {
      showPublishLockToast(context);
      return;
    }
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

      _pushSession(_session.copyWith(exercises: exercises));
    });
    _saveExerciseOrder();
    HapticFeedback.selectionClick();
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surfaceBg,
      appBar: _buildAppBar(),
      body: Stack(
        children: [
          SafeArea(child: _buildBody()),
          Positioned.fill(
            child: ShellPullTab(
              side: ShellPullTabSide.right,
              onActivate: widget.onOpenCapture,
            ),
          ),
        ],
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: () => Navigator.of(context).pop(),
        tooltip: 'Back to sessions',
      ),
      title: InlineEditableText(
        // Show whatever the session list shows — title when set, else
        // clientName. Keeps the header and the card in sync.
        initialValue: _displayTitle(_session),
        onCommit: _saveClientName,
        textStyle: const TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 20,
          letterSpacing: -0.5,
          color: AppColors.textOnDark,
        ),
      ),
      backgroundColor: AppColors.surfaceBase,
      foregroundColor: AppColors.textOnDark,
      elevation: 0,
      actions: [
        IconButton(
          onPressed: () => _importFromLibrary(),
          icon: const Icon(Icons.photo_library_outlined),
          tooltip: 'Add from library',
        ),
        if (_session.exercises.isNotEmpty)
          IconButton(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => PlanPreviewScreen(session: _session),
                ),
              );
            },
            icon: const Icon(Icons.slideshow_outlined),
            tooltip: 'Preview plan',
          ),
      ],
      // Thin strip below the app-bar hosting the practice chip — shows
      // which practice will own the next publish but rendered
      // non-interactive (R-09: dimmed affordance) because switching
      // practice mid-session is a footgun (session state stays bound
      // to the practice it was created under).
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(36),
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          alignment: Alignment.centerLeft,
          child: const PracticeChip(enabled: false),
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
    return Column(
      children: [
        _buildSummaryRow(),
        Expanded(child: _buildExerciseList()),
      ],
    );
  }

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
        Text(
          'Swipe right to Capture, or tap the library icon to import.',
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

  Widget _buildSummaryRow() {
    final nonRest =
        _session.exercises.where((e) => !e.isRest).length;
    final totalDuration = _session.estimatedTotalDurationSeconds;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: [
          _Chip(label: '$nonRest exercises'),
          const SizedBox(width: 8),
          if (totalDuration > 0)
            _Chip(label: '~${formatDuration(totalDuration)}'),
          const Spacer(),
          // Viewing-preferences entry (three-treatment model). Reads as a
          // subject-utility, not header chrome. Opens the consent sheet
          // for the session's linked client inline; no detour through
          // a client list now that Home IS the client list.
          _ViewingPrefsButton(
            onTap: _openConsentForSessionClient,
          ),
          const SizedBox(width: 8),
          _buildPublishLockBadge(),
        ],
      ),
    );
  }

  /// Open the client-consent bottom sheet for the client linked to this
  /// session. Resolves the client row via [Session.clientId] when set,
  /// else by [Session.clientName] within the current practice. Shows a
  /// gentle SnackBar when no match is found (typically the legacy path
  /// where the quick-flow never minted a client row).
  Future<void> _openConsentForSessionClient() async {
    HapticFeedback.selectionClick();
    final practiceId = AuthService.instance.currentPracticeId.value;
    if (practiceId == null || practiceId.isEmpty) return;

    final clients =
        await ApiClient.instance.listPracticeClients(practiceId);
    if (!mounted) return;

    PracticeClient? match;
    final cid = _session.clientId;
    if (cid != null) {
      for (final c in clients) {
        if (c.id == cid) {
          match = c;
          break;
        }
      }
    }
    if (match == null) {
      final lower = _session.clientName.toLowerCase();
      for (final c in clients) {
        if (c.name.toLowerCase() == lower) {
          match = c;
          break;
        }
      }
    }

    if (match == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Publish first to set viewing preferences.'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    await showClientConsentSheet(context, client: match);
  }

  Widget _buildPublishLockBadge() {
    if (!_session.isPublished) return const SizedBox.shrink();
    if (_inOpenEditWindow) {
      final hours = _hoursRemainingInWindow;
      final warning = hours < 1;
      return Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: AppColors.surfaceRaised,
          borderRadius: BorderRadius.circular(9999),
          border: Border.all(
            color: warning
                ? AppColors.warning
                : AppColors.surfaceBorder,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.edit_outlined,
              size: 14,
              color: warning
                  ? AppColors.warning
                  : AppColors.textSecondaryOnDark,
            ),
            const SizedBox(width: 6),
            Text(
              'Edits open · ${hours}h left',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
                color: warning
                    ? AppColors.warning
                    : AppColors.textSecondaryOnDark,
              ),
            ),
          ],
        ),
      );
    }
    // Locked
    return GestureDetector(
      onTap: () => showPublishLockToast(context),
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: AppColors.surfaceRaised,
          borderRadius: BorderRadius.circular(9999),
          border: Border.all(color: AppColors.surfaceBorder),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.lock_outline,
              size: 14,
              color: AppColors.textSecondaryOnDark,
            ),
            SizedBox(width: 6),
            Text(
              'Edit-only · new structure costs 1 credit',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
                color: AppColors.textSecondaryOnDark,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExerciseList() {
    final exercises = _session.exercises;
    return GestureDetector(
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
    // Non-rest cards are ALSO wrapped in a Dismissible so swipe-left
    // on the card fires delete with the standard undo SnackBar — the
    // iOS-native pattern, matching user expectation. Long-press on the
    // thumbnail still opens the Peek menu with an explicit Delete; both
    // paths converge on _deleteExercise.
    Widget cardBody = exercise.isRest
        ? _buildRestRow(dataIndex)
        : StudioExerciseCard(
            key: ValueKey('card_${exercise.id}'),
            exercise: exercise,
            isExpanded: _expandedIndex == dataIndex,
            isInCircuit: isInCircuit,
            onTap: () {
              setState(() {
                _expandedIndex =
                    _expandedIndex == dataIndex ? null : dataIndex;
                _activeInsertIndex = null;
              });
            },
            onUpdate: (u) => _updateExercise(dataIndex, u),
            onThumbnailTap: () => _openMediaViewer(exercise),
            onReplaceMedia: () => _replaceMedia(dataIndex),
            onDelete: () {
              if (_isPublishLocked) {
                showPublishLockToast(context);
                return;
              }
              _deleteExercise(dataIndex);
            },
          );

    final Widget cardContent = Dismissible(
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
      confirmDismiss: (_) async {
        if (_isPublishLocked) {
          showPublishLockToast(context);
          return false;
        }
        return true;
      },
      onDismissed: (_) => _deleteExercise(dataIndex),
      child: cardBody,
    );

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
          // Gap below this card (unless it's the last card).
          if (dataIndex < exercises.length - 1)
            _buildGap(dataIndex + 1, exercise, exercises[dataIndex + 1]),
        ],
      ),
    );
  }

  Widget _buildRestRow(int dataIndex) {
    final exercise = _session.exercises[dataIndex];
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      height: 48,
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
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
    ExerciseCapture lower,
  ) {
    final isActive = _activeInsertIndex == lowerIndex;
    final sameCircuit = upper.circuitId != null &&
        upper.circuitId == lower.circuitId;

    final showRest = !upper.isRest && !lower.isRest;
    // Rests are first-class members of a circuit — semantically identical
    // to exercises for the purpose of linking. The only reason to NOT show
    // link is that the two items are already in the same circuit — in that
    // case we offer Break instead, to split the circuit at this point.
    final showLink = !sameCircuit;
    final showBreak = sameCircuit;

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
                locked: _isPublishLocked,
                onLockedAction: () {
                  showPublishLockToast(context);
                  setState(() => _activeInsertIndex = null);
                },
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
      ],
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

    // Resolve the client linked to this session so the viewer can render
    // its inline consent toggle and persist changes via SyncService.
    // Prefer the local cache (instant, offline-friendly) — fall back to
    // a fresh fetch only when the cache is cold. Identical resolution
    // strategy to _openConsentForSessionClient: id first, then name.
    final practiceId = AuthService.instance.currentPracticeId.value;
    PracticeClient? client;
    if (practiceId != null && practiceId.isNotEmpty) {
      final cached =
          await widget.storage.getCachedClientsForPractice(practiceId);
      final cachedAsPublic = cached
          .map((c) => c.toPracticeClient())
          .toList(growable: false);
      client = _matchClient(cachedAsPublic, _session);
      if (client == null) {
        try {
          final remote =
              await ApiClient.instance.listPracticeClients(practiceId);
          client = _matchClient(remote, _session);
        } catch (_) {
          // Offline + cache miss — viewer will gracefully render without
          // the consent toggle (treatments still cycle / segmented control
          // still works for Line; B&W + Original are gated by the
          // pre-archive check anyway).
        }
      }
    }

    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _MediaViewer(
          exercises: mediaList,
          initialIndex: initialIndex,
          client: client,
        ),
      ),
    );
  }

  /// Resolve a [PracticeClient] from a list using the same id-then-name
  /// fallback as [_openConsentForSessionClient]. Returns null when no
  /// row matches — the caller treats that as "no consent affordance".
  static PracticeClient? _matchClient(
    List<PracticeClient> clients,
    Session session,
  ) {
    final cid = session.clientId;
    if (cid != null) {
      for (final c in clients) {
        if (c.id == cid) return c;
      }
    }
    final lower = session.clientName.toLowerCase();
    for (final c in clients) {
      if (c.name.toLowerCase() == lower) return c;
    }
    return null;
  }
}

// -----------------------------------------------------------------------------
// Summary chip
// -----------------------------------------------------------------------------

class _Chip extends StatelessWidget {
  final String label;
  const _Chip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(9999),
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: const TextStyle(
          fontFamily: 'Inter',
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
          color: AppColors.textSecondaryOnDark,
        ),
      ),
    );
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
  late double _duration;

  @override
  void initState() {
    super.initState();
    _duration = (widget.exercise.holdSeconds ?? 30).toDouble();
  }

  @override
  void didUpdateWidget(covariant _RestBar old) {
    super.didUpdateWidget(old);
    if (old.exercise.id != widget.exercise.id) {
      _duration = (widget.exercise.holdSeconds ?? 30).toDouble();
    }
  }

  String _format(int seconds) {
    if (seconds < 60) return '${seconds}s';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    if (s == 0) return '${m}m';
    return '${m}m${s}s';
  }

  @override
  Widget build(BuildContext context) {
    final seconds = _duration.round();
    return Row(
      children: [
        const Padding(
          padding: EdgeInsets.only(left: 12),
          child: Icon(
            Icons.self_improvement,
            size: 18,
            color: AppColors.rest,
          ),
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
        Expanded(
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: 4,
              activeTrackColor: AppColors.rest,
              inactiveTrackColor:
                  AppColors.rest.withValues(alpha: 0.2),
              thumbColor: AppColors.rest,
              overlayColor: AppColors.rest.withValues(alpha: 0.12),
              thumbShape:
                  const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape:
                  const RoundSliderOverlayShape(overlayRadius: 14),
              trackShape: const RoundedRectSliderTrackShape(),
            ),
            child: Slider(
              value: _duration,
              min: 5,
              max: 300,
              divisions: 59,
              onChanged: (v) {
                setState(() => _duration = v);
                widget.onUpdate(
                  widget.exercise.copyWith(holdSeconds: v.round()),
                );
              },
            ),
          ),
        ),
        SizedBox(
          width: 42,
          child: Text(
            _format(seconds),
            textAlign: TextAlign.right,
            style: const TextStyle(
              fontFamily: 'JetBrainsMono',
              fontFamilyFallback: ['Menlo', 'Courier'],
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.rest,
            ),
          ),
        ),
        // Delete × removed — swipe-left on the whole rest row now
        // triggers the same onDelete via the outer Dismissible in
        // _buildRowWithContext. Consistent with exercise cards.
      ],
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
///   • Top-anchored [TreatmentSegmentedControl] mirrors the gesture and
///     lets the practitioner jump directly. Locked segments (no archive
///     OR client said no) tap into the inline consent toggle.
///   • Inline consent toggle below the control — only when the active
///     treatment is B&W or Original and a client row is resolvable. One
///     tap fires immediately (R-01: no confirmation modals); writes go
///     through [SyncService.queueSetConsent] (offline-first).
///   • Pre-archive captures (no `archiveFilePath`) keep B&W + Original
///     greyed out — Carl's call: don't fall back silently to Line, that
///     would mislead the practitioner during a "show me the difference"
///     demo.
class _MediaViewer extends StatefulWidget {
  final List<ExerciseCapture> exercises;
  final int initialIndex;

  /// The client linked to this session. May be null when the lookup
  /// missed (legacy plan with no `client_id`, name mismatch, or offline
  /// + cache cold). Without a client the consent toggle is hidden and
  /// the only callable treatment is Line.
  final PracticeClient? client;

  const _MediaViewer({
    required this.exercises,
    required this.initialIndex,
    required this.client,
  });

  @override
  State<_MediaViewer> createState() => _MediaViewerState();
}

class _MediaViewerState extends State<_MediaViewer> {
  late final PageController _pageController;
  late int _currentIndex;

  /// Active treatment for the current page. Reset to Line whenever the
  /// page changes (Carl: every new exercise starts with the safe
  /// baseline).
  Treatment _treatment = Treatment.line;

  /// Mutable copy of the client so consent toggles update local state
  /// without waiting for a round-trip. Mirrors the SyncService cache
  /// write that fires immediately.
  PracticeClient? _client;

  /// Active video controller (whichever treatment is on screen). One
  /// controller at a time keeps memory + decode budget bounded.
  VideoPlayerController? _videoController;
  bool _videoInitialized = false;

  /// Token used to ignore stale `initialize()` callbacks when the user
  /// swipes through treatments faster than a controller can come up.
  int _initToken = 0;

  /// Whether the bottom-right play/pause control is currently visible.
  /// When paused, always true. When playing, true for ~2s after the last
  /// user interaction or state change, then fades out so the button
  /// doesn't clutter the demo-to-client view. Presence in the tree is
  /// unchanged — we only animate opacity so taps always hit.
  bool _controlsVisible = true;

  /// Auto-fade timer. Armed only while playing; cancelled on pause /
  /// user interaction / dispose.
  Timer? _controlsIdleTimer;

  /// Listener attached to the active [VideoPlayerController] so the
  /// button icon tracks play/pause transitions that don't originate
  /// from `_togglePlayPause` (e.g. looping, buffering stalls).
  VoidCallback? _videoListener;
  bool _lastKnownIsPlaying = false;

  ExerciseCapture get _current => widget.exercises[_currentIndex];

  bool _isVideo(ExerciseCapture e) =>
      e.mediaType == MediaType.video && !_isStillImageConversion(e);

  /// True when the local raw archive exists for this exercise. The
  /// pre-archive guard from the brief: B&W + Original segments stay
  /// disabled until the practitioner re-records.
  bool _hasArchive(ExerciseCapture e) {
    final path = e.absoluteArchiveFilePath;
    if (path == null) return false;
    return File(path).existsSync();
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
    _client = widget.client;
    _pageController = PageController(initialPage: _currentIndex);
    _initVideoForCurrent();
  }

  /// Source file the active treatment should play.
  ///
  ///   • [Treatment.line] → the on-device line drawing converted file
  ///     (stored locally, always present once conversion is done).
  ///   • [Treatment.grayscale] / [Treatment.original] → the raw archive
  ///     mp4 (same file for both — the grayscale rendering is a
  ///     widget-level [ColorFiltered], no second source needed).
  String? _sourcePathForTreatment(ExerciseCapture e, Treatment t) {
    switch (t) {
      case Treatment.line:
        return e.displayFilePath;
      case Treatment.grayscale:
      case Treatment.original:
        return e.absoluteArchiveFilePath;
    }
  }

  void _initVideoForCurrent() {
    final previous = _videoController;
    final previousListener = _videoListener;
    if (previous != null && previousListener != null) {
      previous.removeListener(previousListener);
    }
    previous?.dispose();
    _videoController = null;
    _videoListener = null;
    _videoInitialized = false;
    if (!_isVideo(_current)) return;
    final path = _sourcePathForTreatment(_current, _treatment);
    if (path == null) return;
    final token = ++_initToken;
    final controller = VideoPlayerController.file(File(path));
    _videoController = controller;
    controller.initialize().then((_) {
      // Bail when the user swiped away or cycled treatments before init
      // resolved — adopting a stale controller would leak the new one.
      if (!mounted || token != _initToken) {
        controller.dispose();
        return;
      }
      setState(() {
        _videoInitialized = true;
        _lastKnownIsPlaying = false;
      });
      controller.setLooping(true);
      // Attach a listener so the play/pause button icon stays in sync
      // with the controller even when the transition didn't go through
      // `_togglePlayPause` (e.g. programmatic pause on end-of-media).
      void listener() => _onVideoStateChanged(controller, token);
      controller.addListener(listener);
      _videoListener = listener;
      controller.play();
      // Controller will flip to `isPlaying == true` shortly after play().
      // Show controls immediately so the user sees the pause affordance,
      // then arm the idle fade.
      _showControlsThenMaybeIdleFade();
    }).catchError((e) {
      debugPrint('MediaViewer: video init failed for $path — $e');
    });
  }

  /// Called via the video controller's listener. Triggers a rebuild
  /// whenever the playing state flips so the button icon + fade state
  /// stay in sync with the actual controller.
  void _onVideoStateChanged(VideoPlayerController controller, int token) {
    if (!mounted || token != _initToken) return;
    final isPlaying = controller.value.isPlaying;
    if (isPlaying == _lastKnownIsPlaying) return;
    _lastKnownIsPlaying = isPlaying;
    _showControlsThenMaybeIdleFade();
  }

  /// Bring the button to full opacity, then (only if playing) arm a
  /// 2-second timer to fade it away. When paused the button stays
  /// visible indefinitely.
  void _showControlsThenMaybeIdleFade() {
    _controlsIdleTimer?.cancel();
    if (!mounted) return;
    setState(() => _controlsVisible = true);
    final c = _videoController;
    if (c == null || !_videoInitialized) return;
    if (!c.value.isPlaying) return;
    _controlsIdleTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      final controller = _videoController;
      if (controller == null || !controller.value.isPlaying) return;
      setState(() => _controlsVisible = false);
    });
  }

  @override
  void dispose() {
    _controlsIdleTimer?.cancel();
    final controller = _videoController;
    final listener = _videoListener;
    if (controller != null && listener != null) {
      controller.removeListener(listener);
    }
    controller?.dispose();
    _pageController.dispose();
    super.dispose();
  }

  void _onPageChanged(int index) {
    setState(() {
      _currentIndex = index;
      // Carl: each new exercise starts on Line — the safe baseline.
      // Sticking the previous treatment forward would be confusing
      // when the new exercise is pre-archive (segment would jump back
      // to Line silently).
      _treatment = Treatment.line;
    });
    _initVideoForCurrent();
  }

  /// Switch to [next] — caller has already checked availability.
  /// Disposes the active controller and re-inits with the new source.
  /// The crossfade itself is handled by the [AnimatedSwitcher] keyed
  /// off the treatment name.
  void _onTreatmentChanged(Treatment next) {
    if (next == _treatment) return;
    HapticFeedback.selectionClick();
    setState(() => _treatment = next);
    _initVideoForCurrent();
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
    final c = _videoController;
    if (c == null || !_videoInitialized) return;
    setState(() {
      if (c.value.isPlaying) {
        c.pause();
      } else {
        c.play();
      }
    });
    // Any tap — on the video body or the overlay button — resets the
    // idle timer. If we paused, the button stays visible; if we started
    // playing, it fades after 2s.
    _showControlsThenMaybeIdleFade();
  }

  /// Flip the consent bit for the active treatment and persist via the
  /// offline-first queue. Updates the local mirror immediately so the
  /// affordance reads as "instant" — matches R-01 (no confirmation).
  ///
  /// Line drawing has no consent toggle (always allowed); the caller
  /// only invokes this for B&W / Original.
  Future<void> _toggleConsentForActiveTreatment() async {
    final client = _client;
    if (client == null) return;
    if (_treatment == Treatment.line) return;

    HapticFeedback.selectionClick();
    var grayscale = client.grayscaleAllowed;
    var colour = client.colourAllowed;
    if (_treatment == Treatment.grayscale) {
      grayscale = !grayscale;
    } else {
      colour = !colour;
    }

    // Optimistic local update — feels instant. The cache write inside
    // queueSetConsent confirms it on disk a tick later.
    setState(() {
      _client = client.copyWith(
        grayscaleAllowed: grayscale,
        colourAllowed: colour,
      );
    });

    try {
      await SyncService.instance.queueSetConsent(
        clientId: client.id,
        grayscaleAllowed: grayscale,
        colourAllowed: colour,
      );
    } catch (_) {
      // Roll the optimistic update back on hard failure — the
      // SyncService.queueSetConsent does its own SnackBar-via-caller
      // pattern, but here we fail quietly into the previous state to
      // avoid surfacing a flapping toggle.
      if (!mounted) return;
      setState(() => _client = client);
    }
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

  @override
  Widget build(BuildContext context) {
    final hasArchive = _hasArchive(_current);
    return Scaffold(
      backgroundColor: AppColors.surfaceBg,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Pager — one page per non-rest exercise. Vertical swipes
          // tunnelled into the GestureDetector cycle the treatment;
          // horizontal swipes pass through to the PageView.
          PageView.builder(
            controller: _pageController,
            itemCount: widget.exercises.length,
            onPageChanged: _onPageChanged,
            itemBuilder: (context, index) {
              final ex = widget.exercises[index];
              final isCurrent = index == _currentIndex;
              final isVideo = _isVideo(ex);
              return GestureDetector(
                // Vertical gestures only fire on the active page — neighbours
                // would never receive them anyway because they're offscreen.
                onVerticalDragEnd: isCurrent ? _handleVerticalDragEnd : null,
                onTap: isCurrent && isVideo ? _togglePlayPause : null,
                behavior: HitTestBehavior.opaque,
                child: Center(
                  child: isVideo
                      ? (isCurrent
                          ? AnimatedSwitcher(
                              duration: const Duration(milliseconds: 220),
                              switchInCurve: Curves.easeOut,
                              switchOutCurve: Curves.easeIn,
                              child: _buildVideoFrame(),
                            )
                          : const _VideoPagePlaceholder())
                      : Image.file(
                          File(ex.displayFilePath),
                          fit: BoxFit.contain,
                          errorBuilder: (_, e, s) => const Icon(
                            Icons.broken_image_outlined,
                            size: 64,
                            color: Colors.white54,
                          ),
                        ),
                ),
              );
            },
          ),

          // Top stack — segmented control + (optional) consent toggle.
          // Sits ABOVE the close button row visually but to its left so
          // the X stays in the corner. Only renders when the current
          // exercise is a video — for stills there's nothing to switch
          // between. Wrapped in a SafeArea so it clears the notch.
          if (_isVideo(_current))
            Positioned(
              top: MediaQuery.of(context).padding.top + 8,
              left: 16,
              right: 56, // leaves room for the close button
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TreatmentSegmentedControl(
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
                  if (_shouldShowConsentRow()) ...[
                    const SizedBox(height: 8),
                    _ConsentToggleRow(
                      clientName: _client!.name,
                      allowed: _treatment == Treatment.grayscale
                          ? _client!.grayscaleAllowed
                          : _client!.colourAllowed,
                      onChanged: (_) => _toggleConsentForActiveTreatment(),
                    ),
                  ],
                ],
              ),
            ),

          // Exercise-name pill — sits BELOW the segmented control so
          // the practitioner reads "what treatment" then "which exercise"
          // top-to-bottom. Second line inside the pill is the swipe
          // affordance: "Exercise N of M" so the practitioner (and the
          // client they're demo-ing to) always has immediate
          // where-are-we context.
          Positioned(
            top: _isVideo(_current)
                ? MediaQuery.of(context).padding.top +
                    (_shouldShowConsentRow() ? 120 : 60)
                : MediaQuery.of(context).padding.top + 12,
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
          // Bottom-right play/pause affordance. Always in the tree for
          // videos so taps always hit — visibility is opacity-driven.
          // When paused it stays at 100%; when playing it fades to 0
          // after a 2s idle so it doesn't overlay demo-to-client view.
          // Sits above the bottom dot-indicator row to avoid overlap.
          if (_isVideo(_current) && _videoInitialized)
            Positioned(
              right: 20,
              bottom: MediaQuery.of(context).padding.bottom +
                  ((widget.exercises.length > 1 &&
                          widget.exercises.length <= 10)
                      ? 48
                      : 20),
              child: _PlayPauseOverlayButton(
                isPlaying: _videoController?.value.isPlaying ?? false,
                visible: _controlsVisible,
                onTap: _togglePlayPause,
              ),
            ),
          // Page dots — swipe affordance at the bottom. Hidden past 10
          // slides (matches the pattern in `plan_preview_screen.dart`);
          // the counter inside the name pill above carries the
          // where-are-we signal at larger plan sizes.
          if (widget.exercises.length > 1 && widget.exercises.length <= 10)
            Positioned(
              left: 0,
              right: 0,
              bottom: MediaQuery.of(context).padding.bottom + 16,
              child: IgnorePointer(
                child: _MediaViewerDotIndicator(
                  total: widget.exercises.length,
                  activeIndex: _currentIndex,
                ),
              ),
            ),
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            right: 8,
            child: IconButton(
              onPressed: () => Navigator.of(context).pop(),
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
        ],
      ),
    );
  }

  /// True when the consent row should render: the active treatment is
  /// gated (B&W or Original), we have a real client row, and the
  /// archive exists (without an archive there's nothing to consent to).
  bool _shouldShowConsentRow() {
    if (_treatment == Treatment.line) return false;
    if (_client == null) return false;
    if (!_hasArchive(_current)) return false;
    return true;
  }

  /// Tap handler for a locked segment in the segmented control.
  ///
  /// When the lock is "no archive" we can't unlock anything from here
  /// (Carl: re-record path). When the lock is "no consent" the toggle
  /// row above is the fix — switching there is exactly what the
  /// segmented control would have done if the segment was available, so
  /// we behave as if the segment was tapped (showing the toggle in its
  /// "Tap to allow" state). This keeps the affordance R-09: the lock
  /// tells you why, the tap takes you to the fix.
  void _onLockedSegmentTap() {
    HapticFeedback.lightImpact();
  }

  /// Build the active video frame for the AnimatedSwitcher. Keyed off
  /// the treatment so the switcher knows when to crossfade. Wraps in a
  /// ColorFiltered for grayscale.
  Widget _buildVideoFrame() {
    final controller = _videoController;
    if (controller == null || !_videoInitialized) {
      return const SizedBox.expand(
        key: ValueKey('media-viewer-loading'),
        child: Center(
          child: CircularProgressIndicator(color: Colors.white54),
        ),
      );
    }
    Widget videoView = AspectRatio(
      aspectRatio: controller.value.aspectRatio,
      child: VideoPlayer(controller),
    );
    if (_treatment == Treatment.grayscale) {
      videoView = ColorFiltered(
        colorFilter: grayscaleColorFilter,
        child: videoView,
      );
    }
    return KeyedSubtree(
      key: ValueKey('media-viewer-${_treatment.name}'),
      child: videoView,
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

/// Inline consent affordance shown below the segmented control when the
/// active treatment is B&W or Original.
///
/// Voice: peer-to-peer (R-06 + voice.md). Never "consent" / "POPIA" /
/// "withdraw" / "rights". Rendered as a short label + a real iOS-style
/// [Switch] — Carl's feedback: the pillbox reads unambiguously as a
/// "setting" the practitioner is tweaking, not an ack button they keep
/// pressing. Switch styling mirrors `client_consent_sheet.dart`.
///
/// One flip fires immediately; no confirmation modal (R-01). Writes go
/// through [SyncService.queueSetConsent] offline-first at the call site.
class _ConsentToggleRow extends StatelessWidget {
  final String clientName;
  final bool allowed;
  final ValueChanged<bool> onChanged;

  const _ConsentToggleRow({
    required this.clientName,
    required this.allowed,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final name = clientName.trim().isEmpty ? 'your client' : clientName;
    return Container(
      height: 40,
      padding: const EdgeInsets.only(left: 14, right: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(9999),
        border: Border.all(
          color: AppColors.surfaceBorder,
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              'Show $name',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 13,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.2,
                color: AppColors.textOnDark,
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Shrink the standard Switch footprint so the pill reads as a
          // compact row and doesn't dominate the top-left stack.
          Transform.scale(
            scale: 0.82,
            child: Switch(
              value: allowed,
              onChanged: onChanged,
              activeThumbColor: Colors.white,
              activeTrackColor: AppColors.primary,
              inactiveThumbColor: AppColors.textSecondaryOnDark,
              inactiveTrackColor: AppColors.surfaceBorder,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
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
            color: isActive ? Colors.white : Colors.white30,
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

/// Small "Viewing" chip that routes to the Your-clients screen. Lives in
/// the studio summary row so the practitioner can jump to the consent
/// sheet without leaving the session context. Copy is deliberately
/// peer-to-peer — never "Consent" / "Legal" (R-voice).
class _ViewingPrefsButton extends StatelessWidget {
  final VoidCallback onTap;

  const _ViewingPrefsButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: AppColors.surfaceRaised,
          borderRadius: BorderRadius.circular(9999),
          border: Border.all(color: AppColors.surfaceBorder),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.visibility_outlined,
              size: 14,
              color: AppColors.textSecondaryOnDark,
            ),
            SizedBox(width: 6),
            Text(
              'Viewing',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.3,
                color: AppColors.textSecondaryOnDark,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
