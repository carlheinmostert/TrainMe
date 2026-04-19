import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';
import '../models/exercise_capture.dart';
import '../models/session.dart';
import '../services/conversion_service.dart';
import '../services/local_storage_service.dart';
import '../services/path_resolver.dart';
import '../theme.dart';
import '../widgets/circuit_control_sheet.dart';
import '../widgets/gutter_rail.dart';
import '../widgets/inline_action_tray.dart';
import '../widgets/inline_editable_text.dart';
import '../widgets/shell_pull_tab.dart';
import '../widgets/studio_exercise_card.dart';
import '../widgets/undo_snackbar.dart';
import 'clients_screen.dart';
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

  void _saveClientName(String newName) {
    if (newName.isEmpty || newName == _session.clientName) return;
    setState(() {
      _pushSession(_session.copyWith(clientName: newName));
    });
    unawaited(widget.storage.saveSession(_session).catchError((e, st) {
      debugPrint('saveSession failed: $e');
    }));
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
        initialValue: _session.clientName,
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
          // subject-utility, not header chrome. Routes to the Your-clients
          // screen where the practitioner finds the client and toggles
          // which treatments are allowed.
          _ViewingPrefsButton(
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const ClientsScreen(),
                ),
              );
            },
          ),
          const SizedBox(width: 8),
          _buildPublishLockBadge(),
        ],
      ),
    );
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

  void _openMediaViewer(ExerciseCapture exercise) {
    if (exercise.isRest) return;
    // Build a list of the non-rest exercises so the viewer can page
    // through them. Rests don't have media, so pulling them out keeps
    // every page a real media slide.
    final mediaList =
        _session.exercises.where((e) => !e.isRest).toList(growable: false);
    final initialIndex =
        mediaList.indexWhere((e) => e.id == exercise.id);
    if (initialIndex < 0) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _MediaViewer(
          exercises: mediaList,
          initialIndex: initialIndex,
        ),
      ),
    );
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

/// Full-screen media viewer with horizontal swipe across exercises.
///
/// Opened from a Studio thumbnail tap. Pages through every non-rest
/// exercise in the session (rests have no media) via PageView. Each
/// page is a photo or video; the video controller is lazily created
/// for the CURRENT page only and disposed when the user swipes away,
/// so memory stays bounded regardless of plan size.
class _MediaViewer extends StatefulWidget {
  final List<ExerciseCapture> exercises;
  final int initialIndex;
  const _MediaViewer({required this.exercises, required this.initialIndex});

  @override
  State<_MediaViewer> createState() => _MediaViewerState();
}

class _MediaViewerState extends State<_MediaViewer> {
  late final PageController _pageController;
  late int _currentIndex;
  VideoPlayerController? _videoController;
  bool _videoInitialized = false;

  ExerciseCapture get _current => widget.exercises[_currentIndex];

  bool _isVideo(ExerciseCapture e) =>
      e.mediaType == MediaType.video && !_isStillImageConversion(e);

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: _currentIndex);
    _initVideoForCurrent();
  }

  void _initVideoForCurrent() {
    _videoController?.dispose();
    _videoController = null;
    _videoInitialized = false;
    if (!_isVideo(_current)) return;
    final controller = VideoPlayerController.file(
      File(_current.displayFilePath),
    );
    _videoController = controller;
    controller.initialize().then((_) {
      // Page might have changed before init finishes — only adopt the
      // result if this is still the active controller.
      if (!mounted || _videoController != controller) return;
      setState(() => _videoInitialized = true);
      controller.setLooping(true);
      controller.play();
    }).catchError((e) {
      debugPrint('Media viewer video init failed: $e');
    });
  }

  @override
  void dispose() {
    _videoController?.dispose();
    _pageController.dispose();
    super.dispose();
  }

  void _onPageChanged(int index) {
    setState(() => _currentIndex = index);
    _initVideoForCurrent();
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
  }

  String _headerLabel(ExerciseCapture e, int index) {
    final n = e.name;
    if (n != null && n.trim().isNotEmpty) return n;
    return 'Exercise ${index + 1}';
  }

  @override
  Widget build(BuildContext context) {
    final showPausedPlayIcon = _isVideo(_current) &&
        _videoInitialized &&
        _videoController != null &&
        !_videoController!.value.isPlaying;
    return Scaffold(
      backgroundColor: AppColors.surfaceBg,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Pager — one page per non-rest exercise. Video pages show
          // the VideoPlayer only when the page IS current; otherwise
          // they render a dark placeholder so adjacent pages don't
          // spin up extra controllers.
          PageView.builder(
            controller: _pageController,
            itemCount: widget.exercises.length,
            onPageChanged: _onPageChanged,
            itemBuilder: (context, index) {
              final ex = widget.exercises[index];
              final isCurrent = index == _currentIndex;
              final isVideo = _isVideo(ex);
              return GestureDetector(
                onTap: isCurrent && isVideo ? _togglePlayPause : null,
                behavior: HitTestBehavior.opaque,
                child: Center(
                  child: isVideo
                      ? (isCurrent &&
                              _videoInitialized &&
                              _videoController != null
                          ? AspectRatio(
                              aspectRatio:
                                  _videoController!.value.aspectRatio,
                              child: VideoPlayer(_videoController!),
                            )
                          : isCurrent
                              ? const CircularProgressIndicator(
                                  color: Colors.white54)
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
          // Exercise-name header — small pill at the top, always visible.
          // Sits below the safe-area inset so it clears the notch / bar.
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
                  child: Text(
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
                ),
              ),
            ),
          ),
          if (showPausedPlayIcon)
            const Center(
              child: Icon(
                Icons.play_arrow,
                size: 72,
                color: Colors.white54,
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
