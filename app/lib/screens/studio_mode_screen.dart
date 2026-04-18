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

class _StudioModeScreenState extends State<StudioModeScreen> {
  late Session _session;
  late ConversionService _conversionService;
  StreamSubscription<ExerciseCapture>? _conversionSub;
  final ImagePicker _picker = ImagePicker();

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

    final rest = ExerciseCapture.createRest(
      position: insertIndex,
      sessionId: _session.id,
    );
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
      minCycles: 1,
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
      child: CustomScrollView(
        reverse: true,
        slivers: [
          SliverReorderableList(
            itemCount: exercises.length,
            onReorder: _onReorder,
            itemBuilder: (context, visualIndex) {
              final dataIndex = exercises.length - 1 - visualIndex;
              return KeyedSubtree(
                key: ValueKey('row_${exercises[dataIndex].id}'),
                child: _buildRowWithContext(dataIndex, visualIndex),
              );
            },
          ),
        ],
      ),
    );
  }

  /// One row + the gap below it. Gap always renders (insertion dot /
  /// circuit rail carry-through / action tray when active).
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

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Circuit header — sits above the first card of each circuit.
          if (isFirstInCircuit)
            _buildCircuitHeaderRow(exercise.circuitId!),
          // NOTE: previously wrapped in IntrinsicHeight with
          // crossAxisAlignment.stretch. That combination broke when the
          // expanded exercise card contained AnimatedSize / AnimatedContainer
          // widgets (no intrinsic-height support), causing the Row to
          // allocate max-available height per row — visually producing a
          // huge empty gap between cards, especially around circuit members.
          // Using crossAxisAlignment.start lets the card dictate height;
          // the gutter cell paints its rail within its own fixed 80px zone
          // aligned to the top of the card.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
                // Gutter cell.
                ReorderableDelayedDragStartListener(
                  index: visualIndex,
                  child: GutterCardCell(
                    numberGlyph: positionNumber,
                    isInCircuit: isInCircuit,
                    isFirstInCircuit: isFirstInCircuit,
                    isLastInCircuit: isLastInCircuit,
                    dimmed: _isPublishLocked,
                  ),
                ),
                const SizedBox(width: 4),
                // Card column.
                Expanded(
                  child: exercise.isRest
                      ? _buildRestRow(dataIndex)
                      : ReorderableDelayedDragStartListener(
                          index: visualIndex,
                          child: StudioExerciseCard(
                            key: ValueKey('card_${exercise.id}'),
                            exercise: exercise,
                            isExpanded: _expandedIndex == dataIndex,
                            isInCircuit: isInCircuit,
                            onTap: () {
                              setState(() {
                                _expandedIndex =
                                    _expandedIndex == dataIndex
                                        ? null
                                        : dataIndex;
                                _activeInsertIndex = null;
                              });
                            },
                            onUpdate: (u) =>
                                _updateExercise(dataIndex, u),
                            onThumbnailTap: () =>
                                _openMediaViewer(exercise),
                            onReplaceMedia: () =>
                                _replaceMedia(dataIndex),
                            onDelete: () {
                              if (_isPublishLocked) {
                                showPublishLockToast(context);
                                return;
                              }
                              _deleteExercise(dataIndex);
                            },
                          ),
                        ),
                ),
              ],
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const GutterSpacerCell(height: 32, railThrough: true),
          const SizedBox(width: 4),
          Expanded(
            child: GestureDetector(
              onTap: () => _openCircuitSheet(circuitId),
              behavior: HitTestBehavior.opaque,
              child: Container(
                height: 32,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: const BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: AppColors.brandTintBorder,
                      width: 2,
                    ),
                  ),
                ),
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
    );
  }

  /// A gutter gap between two cards at `[lowerIndex - 1]` and
  /// `[lowerIndex]`. Shows the insertion dot + the inline action tray
  /// when active.
  Widget _buildGap(
    int lowerIndex,
    ExerciseCapture upper,
    ExerciseCapture lower,
  ) {
    final isActive = _activeInsertIndex == lowerIndex;
    final sameCircuit = upper.circuitId != null &&
        upper.circuitId == lower.circuitId;

    final showRest = !upper.isRest && !lower.isRest;
    final showLink = !sameCircuit && !upper.isRest && !lower.isRest;

    return Row(
      // Start alignment — same reason as _buildRowWithContext:
      // IntrinsicHeight + stretch breaks when the action-tray child
      // uses AnimatedSize / AnimatedOpacity (no intrinsic support).
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GutterGapCell(
            state: isActive
                ? GutterDotState.active
                : GutterDotState.idle,
            continuousRail: sameCircuit,
            dimmed: _isPublishLocked && !isActive,
            onTap: () {
              setState(() {
                _activeInsertIndex = isActive ? null : lowerIndex;
                _expandedIndex = null;
              });
            },
          ),
          const SizedBox(width: 4),
          Expanded(
            child: InlineActionTray(
              visible: isActive,
              showRestAction: showRest,
              showLinkAction: showLink,
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
              onInsertExercise: () async {
                setState(() => _activeInsertIndex = null);
                await _importFromLibrary(insertAt: lowerIndex);
              },
              onClose: () {
                setState(() => _activeInsertIndex = null);
              },
            ),
          ),
        ],
    );
  }

  void _openMediaViewer(ExerciseCapture exercise) {
    if (exercise.isRest) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _MediaViewer(exercise: exercise),
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
        GestureDetector(
          onTap: widget.onDelete,
          behavior: HitTestBehavior.opaque,
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Icon(
              Icons.close,
              size: 16,
              color: AppColors.rest,
            ),
          ),
        ),
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

class _MediaViewer extends StatefulWidget {
  final ExerciseCapture exercise;
  const _MediaViewer({required this.exercise});

  @override
  State<_MediaViewer> createState() => _MediaViewerState();
}

class _MediaViewerState extends State<_MediaViewer> {
  VideoPlayerController? _controller;
  bool _initialized = false;

  bool get _isVideo =>
      widget.exercise.mediaType == MediaType.video &&
      !_isStillImageConversion(widget.exercise);

  @override
  void initState() {
    super.initState();
    if (_isVideo) {
      final controller = VideoPlayerController.file(
          File(widget.exercise.displayFilePath));
      _controller = controller;
      controller.initialize().then((_) {
        if (!mounted) return;
        setState(() => _initialized = true);
        controller.setLooping(true);
        controller.play();
      }).catchError((e) {
        debugPrint('Media viewer video init failed: $e');
      });
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _togglePlayPause() {
    final c = _controller;
    if (c == null || !_initialized) return;
    setState(() {
      if (c.value.isPlaying) {
        c.pause();
      } else {
        c.play();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surfaceBg,
      body: GestureDetector(
        onTap: _isVideo ? _togglePlayPause : null,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_isVideo)
              Center(
                child: _initialized && _controller != null
                    ? AspectRatio(
                        aspectRatio: _controller!.value.aspectRatio,
                        child: VideoPlayer(_controller!),
                      )
                    : const CircularProgressIndicator(
                        color: Colors.white54),
              )
            else
              Center(
                child: Image.file(
                  File(widget.exercise.displayFilePath),
                  fit: BoxFit.contain,
                  errorBuilder: (_, e, s) => const Icon(
                    Icons.broken_image_outlined,
                    size: 64,
                    color: Colors.white54,
                  ),
                ),
              ),
            if (_isVideo &&
                _initialized &&
                _controller != null &&
                !_controller!.value.isPlaying)
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
      ),
    );
  }
}
