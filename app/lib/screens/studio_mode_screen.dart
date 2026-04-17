import 'dart:async';
import 'dart:io';
import 'dart:math' show min;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';
import '../config.dart';
import '../models/exercise_capture.dart';
import '../models/session.dart';
import '../services/conversion_service.dart';
import '../services/local_storage_service.dart';
import '../services/path_resolver.dart';
import '../theme.dart';
import '../widgets/capture_thumbnail.dart';
import '../widgets/powered_by_footer.dart';
import '../widgets/shell_pull_tab.dart';
import 'plan_preview_screen.dart';

/// Post-session editing — the "Studio" mode.
///
/// Extracted from [SessionCaptureScreen]. Capture is gone — that's the
/// Camera mode's job. Studio is edit-only: expandable exercise cards
/// with Settings/Preview/Notes, sliders, drag reorder, circuit grouping,
/// rest-period insertion, inline-editable names, swipe-to-delete.
///
/// The import-from-library path still lives here — a bio preparing a
/// plan outside of a client session might want to pull in an older
/// video. Camera is gone from the add-exercise card, replaced by a
/// single "Capture" button that swipes to Camera mode.
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

bool _isStillImageConversion(ExerciseCapture exercise) {
  final converted = exercise.convertedFilePath;
  if (converted == null) return false;
  final ext = converted.toLowerCase();
  return ext.endsWith('.jpg') ||
      ext.endsWith('.jpeg') ||
      ext.endsWith('.png');
}

class _StudioModeScreenState extends State<StudioModeScreen> {
  late Session _session;
  late ConversionService _conversionService;
  StreamSubscription<ExerciseCapture>? _conversionSub;
  final ImagePicker _picker = ImagePicker();

  int? _expandedIndex;
  bool _isEditingName = false;
  late TextEditingController _nameController;
  final FocusNode _nameFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _session = widget.session;
    _nameController = TextEditingController(text: _session.clientName);
    _nameFocusNode.addListener(_onNameFocusChange);
    _conversionService = ConversionService.instance;
    _listenToConversions();
  }

  @override
  void didUpdateWidget(covariant StudioModeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Parent (shell) may refresh session after camera captures. Merge
    // in any new exercises without clobbering in-progress name edit.
    if (oldWidget.session != widget.session) {
      setState(() {
        _session = widget.session;
        if (!_isEditingName) {
          _nameController.text = _session.clientName;
        }
      });
    }
  }

  @override
  void dispose() {
    _conversionSub?.cancel();
    _nameController.dispose();
    _nameFocusNode.removeListener(_onNameFocusChange);
    _nameFocusNode.dispose();
    super.dispose();
  }

  void _onNameFocusChange() {
    if (!_nameFocusNode.hasFocus && _isEditingName) {
      _saveClientName();
    }
  }

  void _pushSession(Session next) {
    _session = next;
    widget.onSessionChanged(next);
  }

  void _saveClientName() {
    final newName = _nameController.text.trim();
    if (newName.isNotEmpty && newName != _session.clientName) {
      setState(() {
        _pushSession(_session.copyWith(clientName: newName));
      });
      unawaited(widget.storage.saveSession(_session).catchError((e, st) {
        debugPrint('saveSession failed: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Unable to save — please try again')),
          );
        }
      }));
    }
    setState(() => _isEditingName = false);
  }

  void _listenToConversions() {
    _conversionSub = _conversionService.onConversionUpdate.listen((updated) {
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

  void _startEditingName() {
    _nameController.text = _session.clientName;
    setState(() => _isEditingName = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _nameFocusNode.requestFocus();
      _nameController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _nameController.text.length,
      );
    });
  }

  // ---------------------------------------------------------------------------
  // Import from library (multi-select)
  // ---------------------------------------------------------------------------

  static const _videoExtensions = {
    '.mp4', '.mov', '.m4v', '.avi', '.mkv', '.webm', '.3gp', '.hevc'
  };

  MediaType _detectMediaType(String path) {
    final ext = p.extension(path).toLowerCase();
    return _videoExtensions.contains(ext) ? MediaType.video : MediaType.photo;
  }

  Future<void> _importFromLibrary() async {
    try {
      final picked = await _picker.pickMultipleMedia();
      if (picked.isEmpty) return;

      // Sequential: file copy + save + queue per asset, in picker order.
      for (final xfile in picked) {
        final type = _detectMediaType(xfile.path);
        await _addCaptureFromFile(xfile.path, type);
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

  Future<void> _addCaptureFromFile(String sourcePath, MediaType type) async {
    final dir = await getApplicationDocumentsDirectory();
    final rawDir = Directory(p.join(dir.path, 'raw'));
    await rawDir.create(recursive: true);

    final ext = p.extension(sourcePath);
    final destPath =
        p.join(rawDir.path, '${DateTime.now().millisecondsSinceEpoch}$ext');
    await File(sourcePath).copy(destPath);

    final position = _session.exercises.length;
    final exercise = ExerciseCapture.create(
      position: position,
      rawFilePath: PathResolver.toRelative(destPath),
      mediaType: type,
      sessionId: _session.id,
    );

    await widget.storage.saveExercise(exercise);

    if (mounted) {
      setState(() {
        _pushSession(_session.copyWith(
          exercises: [..._session.exercises, exercise],
        ));
      });
    }

    _conversionService.queueConversion(exercise);
    _autoInsertRestPeriods();
  }

  // ---------------------------------------------------------------------------
  // Rest periods
  // ---------------------------------------------------------------------------

  Future<void> _insertRestBetween(int insertIndex) async {
    final exercises = List<ExerciseCapture>.from(_session.exercises);

    final hasRestBelow =
        insertIndex < exercises.length && exercises[insertIndex].isRest;
    final hasRestAbove =
        insertIndex > 0 && exercises[insertIndex - 1].isRest;
    if (hasRestBelow || hasRestAbove) {
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Rest period already adjacent'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }

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
          final hasRestBelow =
              nextIdx < exercises.length && exercises[nextIdx].isRest;
          final hasRestAbove = i >= 0 && exercises[i].isRest;
          if (!hasRestBelow && !hasRestAbove) {
            insertPositions.add(nextIdx);
          }
        }
        cumulativeSeconds = 0;
      }
    }

    if (insertPositions.isEmpty) return;

    var offset = 0;
    for (final pos in insertPositions) {
      final adjustedPos = pos + offset;
      final rest = ExerciseCapture.createRest(
        position: adjustedPos,
        sessionId: _session.id,
      );
      exercises.insert(adjustedPos, rest);
      offset++;
    }
    for (var i = 0; i < exercises.length; i++) {
      exercises[i] = exercises[i].copyWith(position: i);
    }

    setState(() {
      _pushSession(_session.copyWith(exercises: exercises));
    });

    for (final pos in insertPositions) {
      final adjustedPos = pos + insertPositions.indexOf(pos);
      if (adjustedPos < exercises.length) {
        unawaited(widget.storage
            .saveExercise(exercises[adjustedPos])
            .catchError((e, st) {
          debugPrint('saveExercise failed: $e');
        }));
      }
    }
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

    unawaited(widget.storage.deleteExercise(removed.id).catchError((e, st) {
      debugPrint('deleteExercise failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unable to save — please try again')),
        );
      }
    }));
    _saveExerciseOrder();

    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${removed.name ?? 'Exercise ${index + 1}'} deleted'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () async {
            await widget.storage.saveExercise(removed);
            await _refreshSession();
          },
        ),
      ),
    );
  }

  Future<void> _refreshSession() async {
    final refreshed = await widget.storage.getSession(_session.id);
    if (refreshed != null && mounted) {
      setState(() => _pushSession(refreshed));
    }
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
      final newCircuitId = const Uuid().v4();
      exercises[upperIndex] = upper.copyWith(circuitId: newCircuitId);
      exercises[lowerIndex] = lower.copyWith(circuitId: newCircuitId);
    } else if (upperCircuit != null && lowerCircuit == null) {
      exercises[lowerIndex] = lower.copyWith(circuitId: upperCircuit);
    } else if (upperCircuit == null && lowerCircuit != null) {
      exercises[upperIndex] = upper.copyWith(circuitId: lowerCircuit);
    } else if (upperCircuit != lowerCircuit) {
      final targetId = upperCircuit!;
      final sourceId = lowerCircuit!;
      for (var i = 0; i < exercises.length; i++) {
        if (exercises[i].circuitId == sourceId) {
          exercises[i] = exercises[i].copyWith(circuitId: targetId);
        }
      }
      var updatedCycles = Map<String, int>.from(_session.circuitCycles);
      if (!updatedCycles.containsKey(targetId) &&
          updatedCycles.containsKey(sourceId)) {
        updatedCycles[targetId] = updatedCycles[sourceId]!;
      }
      updatedCycles.remove(sourceId);
      _pushSession(_session.copyWith(circuitCycles: updatedCycles));
      unawaited(widget.storage.saveSession(_session).catchError((e, st) {
        debugPrint('saveSession failed: $e');
      }));
    }

    setState(() {
      _pushSession(_session.copyWith(exercises: exercises));
    });
    _saveAllExercises(exercises);
  }

  void _unlinkExercises(int upperIndex, int lowerIndex) {
    final exercises = List<ExerciseCapture>.from(_session.exercises);
    final circuitId = exercises[upperIndex].circuitId;
    if (circuitId == null) return;

    final circuitMembers = <int>[];
    for (var i = 0; i < exercises.length; i++) {
      if (exercises[i].circuitId == circuitId) {
        circuitMembers.add(i);
      }
    }

    final splitPos = circuitMembers.indexOf(lowerIndex);
    if (splitPos < 0) return;

    final upperGroup = circuitMembers.sublist(0, splitPos);
    final lowerGroup = circuitMembers.sublist(splitPos);

    if (upperGroup.length == 1) {
      exercises[upperGroup[0]] =
          exercises[upperGroup[0]].copyWith(clearCircuitId: true);
    }

    if (lowerGroup.length == 1) {
      exercises[lowerGroup[0]] =
          exercises[lowerGroup[0]].copyWith(clearCircuitId: true);
    } else {
      final newCircuitId = const Uuid().v4();
      for (final idx in lowerGroup) {
        exercises[idx] = exercises[idx].copyWith(circuitId: newCircuitId);
      }
      var updatedCycles = Map<String, int>.from(_session.circuitCycles);
      if (updatedCycles.containsKey(circuitId)) {
        updatedCycles[newCircuitId] = updatedCycles[circuitId]!;
      }
      _pushSession(_session.copyWith(circuitCycles: updatedCycles));
      unawaited(widget.storage.saveSession(_session).catchError((e, st) {
        debugPrint('saveSession failed: $e');
      }));
    }

    setState(() {
      _pushSession(_session.copyWith(exercises: exercises));
    });
    _saveAllExercises(exercises);
  }

  void _setCircuitCycles(String circuitId, int cycles) {
    setState(() {
      _pushSession(_session.setCircuitCycles(circuitId, cycles));
    });
    unawaited(widget.storage.saveSession(_session).catchError((e, st) {
      debugPrint('saveSession failed: $e');
    }));
  }

  Future<void> _saveAllExercises(List<ExerciseCapture> exercises) async {
    for (final ex in exercises) {
      await widget.storage.saveExercise(ex);
    }
  }

  // ---------------------------------------------------------------------------
  // Preview
  // ---------------------------------------------------------------------------

  void _previewCapture(ExerciseCapture exercise) {
    if (exercise.isRest) return;
    final path = exercise.displayFilePath;
    if (exercise.mediaType == MediaType.video &&
        !_isStillImageConversion(exercise)) {
      showDialog(
        context: context,
        builder: (context) => _VideoPreviewDialog(filePath: path),
      );
    } else {
      showDialog(
        context: context,
        builder: (context) => Dialog.fullscreen(
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.file(
                File(path),
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => const Center(
                  child: Icon(Icons.broken_image_outlined,
                      size: 64, color: Colors.white54),
                ),
              ),
              Positioned(
                top: MediaQuery.of(context).padding.top + 8,
                right: 8,
                child: IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close, color: Colors.white, size: 28),
                  style: IconButton.styleFrom(backgroundColor: Colors.black54),
                ),
              ),
            ],
          ),
        ),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.darkBg,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
          tooltip: 'Back to sessions',
        ),
        title: _isEditingName
            ? TextField(
                controller: _nameController,
                focusNode: _nameFocusNode,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.5,
                  fontSize: 20,
                  color: AppColors.textOnDark,
                ),
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                ),
                onSubmitted: (_) => _saveClientName(),
              )
            : GestureDetector(
                onTap: _startEditingName,
                child: CustomPaint(
                  painter:
                      _DashedUnderlinePainter(color: AppColors.grey500),
                  child: Text(
                    _session.clientName,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.5,
                      color: AppColors.textOnDark,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
        backgroundColor: AppColors.darkSurface,
        foregroundColor: AppColors.textOnDark,
        elevation: 0,
        actions: [
          // Import-from-library — multi-select. Lives in studio because
          // it's prep work (capture happens in Camera mode).
          IconButton(
            onPressed: _importFromLibrary,
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
      ),
      body: Stack(
        children: [
          _buildBody(),
          // Right-edge pull-tab hinting at Camera mode.
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

  Widget _buildBody() {
    if (_session.exercises.isEmpty) {
      return Column(
        children: [
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: _buildEmptyState(),
              ),
            ),
          ),
          const PoweredByFooter(),
        ],
      );
    }
    return _buildExerciseList();
  }

  /// Empty-state hint. Studio is edit-only — capture happens in Camera
  /// mode (swipe right or use the pull-tab) and existing media comes in
  /// via the library icon in the app bar.
  Widget _buildEmptyState() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: const [
        Icon(Icons.drive_file_rename_outline,
            size: 48, color: AppColors.grey500),
        SizedBox(height: 12),
        Text(
          'No exercises yet',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: AppColors.textOnDark,
          ),
        ),
        SizedBox(height: 6),
        Text(
          'Swipe right for Camera, or tap the library icon above to import.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: AppColors.grey500),
        ),
      ],
    );
  }

  Widget _buildExerciseList() {
    final exercises = _session.exercises;
    final totalDuration = _session.estimatedTotalDurationSeconds;
    return CustomScrollView(
      slivers: [
        SliverReorderableList(
          itemCount: exercises.length,
          onReorder: _onReorder,
          itemBuilder: _buildExerciseItem,
        ),
        if (totalDuration > 0)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            sliver: SliverToBoxAdapter(
              child: Text(
                'Estimated: ${formatDuration(totalDuration)}',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 12, color: AppColors.grey500),
              ),
            ),
          ),
        const SliverToBoxAdapter(
          child: PoweredByFooter(),
        ),
      ],
    );
  }

  Widget _buildExerciseItem(BuildContext context, int index) {
    final exercises = _session.exercises;
    final exercise = exercises[index];

    if (exercise.isRest) {
      final isInCircuit = exercise.circuitId != null;
      final restDecoration = isInCircuit
          ? const BoxDecoration(
              border: Border(
                left: BorderSide(color: AppColors.circuit, width: 3),
              ),
            )
          : null;

      return KeyedSubtree(
        key: ValueKey(exercise.id),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            children: [
              Container(
                decoration: restDecoration,
                padding: isInCircuit ? const EdgeInsets.only(left: 8) : null,
                child: _RestBar(
                  key: ValueKey('rest_${exercise.id}'),
                  exercise: exercise,
                  index: index,
                  onUpdate: (updated) => _updateExercise(index, updated),
                  onDelete: () => _deleteExercise(index),
                  dragHandle: ReorderableDragStartListener(
                    index: index,
                    child: const SizedBox(
                      width: 44,
                      height: 44,
                      child: Center(
                        child: Icon(
                          Icons.drag_handle,
                          color: AppColors.grey500,
                          size: 24,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (index < exercises.length - 1)
                _buildBetweenCardButtons(
                  upperIndex: index,
                  lowerIndex: index + 1,
                  isLinked: exercise.circuitId != null &&
                      exercises[index + 1].circuitId == exercise.circuitId,
                ),
            ],
          ),
        ),
      );
    }

    final isInCircuit = exercise.circuitId != null;
    final isFirstInCircuit = isInCircuit &&
        (index == 0 ||
            exercises[index - 1].circuitId != exercise.circuitId);
    final isLastInCircuit = isInCircuit &&
        (index == exercises.length - 1 ||
            exercises[index + 1].circuitId != exercise.circuitId);
    final hasNextInSameCircuit = isInCircuit &&
        index < exercises.length - 1 &&
        exercises[index + 1].circuitId == exercise.circuitId;
    final showBetweenButtons = index < exercises.length - 1;
    final isLinkedBelow = showBetweenButtons &&
        exercise.circuitId != null &&
        exercises[index + 1].circuitId == exercise.circuitId;

    return KeyedSubtree(
      key: ValueKey(exercise.id),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isFirstInCircuit) _buildCircuitHeader(exercise.circuitId!),
            _buildReorderableCard(
              exercise: exercise,
              index: index,
              isInCircuit: isInCircuit,
              isFirstInCircuit: isFirstInCircuit,
              isLastInCircuit: isLastInCircuit,
              hasNextInSameCircuit: hasNextInSameCircuit,
            ),
            if (showBetweenButtons)
              _buildBetweenCardButtons(
                upperIndex: index,
                lowerIndex: index + 1,
                isLinked: isLinkedBelow,
              ),
          ],
        ),
      ),
    );
  }

  void _onReorder(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex--;
    if (oldIndex == newIndex) return;

    setState(() {
      _expandedIndex = null;
      final exercises = List<ExerciseCapture>.from(_session.exercises);
      final moved = exercises.removeAt(oldIndex);
      exercises.insert(newIndex, moved);

      for (var i = 0; i < exercises.length; i++) {
        exercises[i] = exercises[i].copyWith(position: i);
      }

      // Circuit orphan cleanup
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

      final circuitCounts = <String, int>{};
      for (final ex in exercises) {
        if (ex.circuitId != null) {
          circuitCounts[ex.circuitId!] =
              (circuitCounts[ex.circuitId!] ?? 0) + 1;
        }
      }
      for (var i = 0; i < exercises.length; i++) {
        final cid = exercises[i].circuitId;
        if (cid != null && circuitCounts[cid] == 1) {
          exercises[i] = exercises[i].copyWith(clearCircuitId: true);
        }
      }

      _pushSession(_session.copyWith(exercises: exercises));
    });
    _saveExerciseOrder();

    final movedExercise = _session.exercises[newIndex];
    if (movedExercise.isRest) {
      int cumulativeSeconds = 0;
      for (var i = 0; i < newIndex; i++) {
        final ex = _session.exercises[i];
        if (!ex.isRest) {
          cumulativeSeconds += ex.effectiveDurationSeconds;
        }
      }
      if (cumulativeSeconds > 30) {
        setState(() {
          _pushSession(_session.copyWith(
            preferredRestIntervalSeconds: cumulativeSeconds,
          ));
        });
        unawaited(widget.storage.saveSession(_session).catchError((e, st) {
          debugPrint('saveSession failed: $e');
        }));
      }
    }
  }

  Widget _buildReorderableCard({
    required ExerciseCapture exercise,
    required int index,
    required bool isInCircuit,
    required bool isFirstInCircuit,
    required bool isLastInCircuit,
    required bool hasNextInSameCircuit,
  }) {
    final decoration = isInCircuit
        ? const BoxDecoration(
            border: Border(
              left: BorderSide(color: AppColors.circuit, width: 3),
            ),
          )
        : null;

    return Container(
      decoration: decoration,
      padding: isInCircuit ? const EdgeInsets.only(left: 8) : null,
      child: Dismissible(
        key: ValueKey('dismiss_${exercise.id}'),
        direction: DismissDirection.endToStart,
        onDismissed: (_) => _deleteExercise(index),
        background: Container(
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            color: AppColors.error,
            borderRadius: BorderRadius.circular(12),
          ),
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 24),
          child:
              const Icon(Icons.delete_outline, color: Colors.white, size: 28),
        ),
        child: _ExerciseCard(
          key: ValueKey('card_${exercise.id}'),
          exercise: exercise,
          index: index,
          isExpanded: _expandedIndex == index,
          isInCircuit: isInCircuit,
          onTap: () {
            setState(() {
              _expandedIndex = _expandedIndex == index ? null : index;
            });
          },
          onUpdate: (updated) => _updateExercise(index, updated),
          onPreview: () => _previewCapture(exercise),
          dragHandle: ReorderableDragStartListener(
            index: index,
            child: const SizedBox(
              width: 44,
              height: 44,
              child: Center(
                child: Icon(
                  Icons.drag_handle,
                  color: AppColors.grey500,
                  size: 24,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCircuitHeader(String circuitId) {
    final cycles = _session.getCircuitCycles(circuitId);
    return Container(
      decoration: const BoxDecoration(
        border: Border(
          left: BorderSide(color: AppColors.circuit, width: 3),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.only(left: 12, top: 4, bottom: 4),
        child: Row(
          children: [
            const Icon(Icons.repeat, size: 16, color: AppColors.circuit),
            const SizedBox(width: 6),
            const Text(
              'Circuit',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AppColors.circuit,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '$cycles',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AppColors.circuit,
              ),
            ),
            Text(
              cycles == 1 ? ' cycle' : ' cycles',
              style: TextStyle(
                fontSize: 12,
                color: AppColors.circuit.withValues(alpha: 0.7),
              ),
            ),
            Expanded(
              child: SliderTheme(
                data: SliderThemeData(
                  trackHeight: 3,
                  activeTrackColor: AppColors.circuit,
                  inactiveTrackColor:
                      AppColors.circuit.withValues(alpha: 0.2),
                  thumbColor: AppColors.circuit,
                  thumbShape: const _RectangularSliderThumbShape(
                      width: 6, height: 18, radius: 3),
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 14),
                  overlayColor: AppColors.circuit.withValues(alpha: 0.12),
                ),
                child: Slider(
                  value: cycles.clamp(1, 5).toDouble(),
                  min: 1,
                  max: 5,
                  divisions: 4,
                  onChanged: (v) => _setCircuitCycles(circuitId, v.round()),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBetweenCardButtons({
    required int upperIndex,
    required int lowerIndex,
    required bool isLinked,
  }) {
    final exercises = _session.exercises;
    final upperInCircuit = exercises[upperIndex].circuitId != null;
    final lowerInCircuit = exercises[lowerIndex].circuitId != null;
    final sameContinuousCircuit = isLinked && upperInCircuit && lowerInCircuit;

    final buttons = Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          GestureDetector(
            onTap: () {
              if (isLinked) {
                _unlinkExercises(upperIndex, lowerIndex);
              } else {
                _linkExercises(upperIndex, lowerIndex);
              }
            },
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isLinked
                    ? AppColors.circuit
                    : AppColors.darkSurfaceVariant,
                border: Border.all(
                  color: isLinked ? AppColors.circuit : AppColors.grey500,
                  width: 1.5,
                ),
              ),
              child: Icon(
                isLinked ? Icons.link : Icons.link_off,
                size: 14,
                color: isLinked ? Colors.white : AppColors.grey500,
              ),
            ),
          ),
          const SizedBox(width: 12),
          GestureDetector(
            onTap: () => _insertRestBetween(lowerIndex),
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.darkSurfaceVariant,
                border: Border.all(color: AppColors.rest, width: 1.5),
              ),
              child: const Icon(
                Icons.self_improvement,
                size: 14,
                color: AppColors.rest,
              ),
            ),
          ),
        ],
      ),
    );

    if (sameContinuousCircuit) {
      return Container(
        decoration: const BoxDecoration(
          border: Border(
            left: BorderSide(color: AppColors.circuit, width: 3),
          ),
        ),
        padding: const EdgeInsets.only(left: 8),
        child: buttons,
      );
    }
    return buttons;
  }
}

// =============================================================================
// Private helper widgets — extracted wholesale from session_capture_screen
// =============================================================================

class _ExerciseCard extends StatefulWidget {
  final ExerciseCapture exercise;
  final int index;
  final bool isExpanded;
  final bool isInCircuit;
  final VoidCallback onTap;
  final ValueChanged<ExerciseCapture> onUpdate;
  final VoidCallback onPreview;
  final Widget? dragHandle;

  const _ExerciseCard({
    super.key,
    required this.exercise,
    required this.index,
    required this.isExpanded,
    this.isInCircuit = false,
    required this.onTap,
    required this.onUpdate,
    required this.onPreview,
    this.dragHandle,
  });

  @override
  State<_ExerciseCard> createState() => _ExerciseCardState();
}

class _ExerciseCardState extends State<_ExerciseCard> {
  late double _repsValue;
  late double _setsValue;
  late double _holdValue;
  late TextEditingController _notesController;

  bool _isEditingName = false;
  late TextEditingController _nameController;
  final FocusNode _nameFocusNode = FocusNode();

  bool _isSettingsOpen = false;
  bool _isPreviewOpen = false;
  bool _isNotesOpen = false;

  @override
  void initState() {
    super.initState();
    _repsValue = (widget.exercise.reps ?? 10).toDouble();
    _setsValue = (widget.exercise.sets ?? 3).toDouble();
    _holdValue = (widget.exercise.holdSeconds ?? 0).toDouble();
    _notesController =
        TextEditingController(text: widget.exercise.notes ?? '');
    _nameController = TextEditingController(
      text: widget.exercise.name ?? 'Exercise ${widget.index + 1}',
    );
    _nameFocusNode.addListener(_onNameFocusChange);
  }

  @override
  void didUpdateWidget(covariant _ExerciseCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.exercise.id != widget.exercise.id) {
      _repsValue = (widget.exercise.reps ?? 10).toDouble();
      _setsValue = (widget.exercise.sets ?? 3).toDouble();
      _holdValue = (widget.exercise.holdSeconds ?? 0).toDouble();
      _notesController.text = widget.exercise.notes ?? '';
      _nameController.text =
          widget.exercise.name ?? 'Exercise ${widget.index + 1}';
      _isEditingName = false;
      _isSettingsOpen = false;
      _isPreviewOpen = false;
      _isNotesOpen = false;
    }
    if (oldWidget.isExpanded && !widget.isExpanded) {
      _isSettingsOpen = false;
      _isPreviewOpen = false;
      _isNotesOpen = false;
    }
  }

  @override
  void dispose() {
    _notesController.dispose();
    _nameController.dispose();
    _nameFocusNode.removeListener(_onNameFocusChange);
    _nameFocusNode.dispose();
    super.dispose();
  }

  void _onNameFocusChange() {
    if (!_nameFocusNode.hasFocus && _isEditingName) {
      _saveExerciseName();
    }
  }

  String get _displayName =>
      widget.exercise.name ?? 'Exercise ${widget.index + 1}';

  void _startEditingName() {
    _nameController.text = _displayName;
    setState(() => _isEditingName = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _nameFocusNode.requestFocus();
      _nameController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _nameController.text.length,
      );
    });
  }

  void _saveExerciseName() {
    final newName = _nameController.text.trim();
    if (newName.isNotEmpty && newName != _displayName) {
      final isDefault = newName == 'Exercise ${widget.index + 1}';
      widget.onUpdate(widget.exercise.copyWith(
        name: isDefault ? null : newName,
        clearName: isDefault,
      ));
    }
    setState(() => _isEditingName = false);
  }

  void _save() {
    widget.onUpdate(widget.exercise.copyWith(
      reps: _repsValue.round(),
      sets: _setsValue.round(),
      holdSeconds: _holdValue.round(),
      notes: _notesController.text.isEmpty ? null : _notesController.text,
    ));
  }

  static const _sliderTheme = SliderThemeData(
    trackHeight: 8,
    activeTrackColor: AppColors.primary,
    inactiveTrackColor: AppColors.darkBorder,
    thumbColor: AppColors.primary,
    thumbShape: _RectangularSliderThumbShape(width: 8, height: 24, radius: 4),
    overlayShape: RoundSliderOverlayShape(overlayRadius: 20),
    overlayColor: Color(0x1FFF6B35),
    trackShape: RoundedRectSliderTrackShape(),
  );

  Widget _buildStatusIcon() {
    switch (widget.exercise.conversionStatus) {
      case ConversionStatus.pending:
      case ConversionStatus.converting:
        return const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppColors.grey500,
          ),
        );
      case ConversionStatus.done:
        return const Icon(Icons.check_circle,
            size: 18, color: AppColors.success);
      case ConversionStatus.failed:
        return const Icon(Icons.error_outline,
            size: 18, color: AppColors.error);
    }
  }

  Widget _buildAudioToggle() {
    final isOn = widget.exercise.includeAudio;
    return GestureDetector(
      onTap: () {
        widget.onUpdate(widget.exercise.copyWith(includeAudio: !isOn));
      },
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Icon(
          isOn ? Icons.mic : Icons.mic_off,
          size: 18,
          color: isOn ? AppColors.circuit : AppColors.grey500,
        ),
      ),
    );
  }

  String _buildSettingsSummary() {
    final parts = <String>[];
    parts.add('${_repsValue.round()} reps');
    if (!widget.isInCircuit) parts.add('${_setsValue.round()} sets');
    if (_holdValue.round() > 0) parts.add('${_holdValue.round()}s hold');
    final duration = widget.exercise.effectiveDurationSeconds;
    final isCustom = widget.exercise.customDurationSeconds != null;
    parts.add(isCustom
        ? formatDuration(duration)
        : '~${formatDuration(duration)}');
    return parts.join(' \u00b7 ');
  }

  void _setCustomDuration(int seconds) {
    widget.onUpdate(widget.exercise.copyWith(customDurationSeconds: seconds));
  }

  void _clearCustomDuration() {
    widget.onUpdate(widget.exercise.copyWith(clearCustomDuration: true));
  }

  Widget _buildSubSection({
    required String title,
    String? subtitle,
    required bool isOpen,
    required VoidCallback onToggle,
    required Widget child,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onToggle,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.darkSurfaceVariant,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(
                  isOpen ? Icons.expand_more : Icons.chevron_right,
                  size: 20,
                  color: AppColors.textSecondaryOnDark,
                ),
                const SizedBox(width: 4),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textSecondaryOnDark,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      subtitle,
                      style: const TextStyle(
                        fontSize: 13,
                        color: AppColors.grey500,
                      ),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ),
                ] else
                  const Spacer(),
              ],
            ),
          ),
        ),
        if (isOpen)
          Padding(
            padding: const EdgeInsets.only(top: 8, left: 4, right: 4),
            child: child,
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: AppColors.darkSurface,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.darkBorder, width: 1),
      ),
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CaptureThumbnail(exercise: widget.exercise, size: 56),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: _isEditingName
                              ? TextField(
                                  controller: _nameController,
                                  focusNode: _nameFocusNode,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 15,
                                    color: AppColors.textOnDark,
                                  ),
                                  textCapitalization:
                                      TextCapitalization.words,
                                  decoration: const InputDecoration(
                                    border: InputBorder.none,
                                    isDense: true,
                                    contentPadding: EdgeInsets.zero,
                                  ),
                                  onSubmitted: (_) => _saveExerciseName(),
                                )
                              : GestureDetector(
                                  onTap: _startEditingName,
                                  child: CustomPaint(
                                    painter: _DashedUnderlinePainter(
                                        color: AppColors.grey500),
                                    child: Text(
                                      _displayName,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                        fontSize: 15,
                                        color: AppColors.textOnDark,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                        ),
                        const SizedBox(width: 6),
                        _buildStatusIcon(),
                        if (widget.exercise.mediaType == MediaType.video) ...[
                          const SizedBox(width: 4),
                          _buildAudioToggle(),
                        ],
                      ],
                    ),
                  ),
                  SizedBox(
                    width: 44,
                    height: 44,
                    child: Center(
                      child: Icon(
                        widget.isExpanded
                            ? Icons.expand_less
                            : Icons.expand_more,
                        color: AppColors.grey500,
                        size: 24,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  if (widget.dragHandle != null) widget.dragHandle!,
                ],
              ),
              if (widget.isExpanded) ...[
                const SizedBox(height: 12),
                const Divider(height: 1),
                const SizedBox(height: 12),
                if (widget.exercise.conversionStatus ==
                    ConversionStatus.failed)
                  Container(
                    padding: const EdgeInsets.all(12),
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF3B1111),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: AppColors.error.withValues(alpha: 0.4)),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.error_outline,
                            color: Color(0xFFFCA5A5), size: 20),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Line drawing conversion failed. The original is preserved.',
                            style: TextStyle(
                                color: Color(0xFFFCA5A5), fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ),
                _buildSubSection(
                  title: _buildSettingsSummary(),
                  isOpen: _isSettingsOpen,
                  onToggle: () =>
                      setState(() => _isSettingsOpen = !_isSettingsOpen),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _SliderRow(
                        label: 'Reps',
                        value: _repsValue,
                        min: 1,
                        max: 30,
                        divisions: 29,
                        displayValue: _repsValue.round().toString(),
                        theme: _sliderTheme,
                        onChanged: (v) {
                          setState(() => _repsValue = v);
                          _save();
                        },
                      ),
                      if (!widget.isInCircuit)
                        _SliderRow(
                          label: 'Sets',
                          value: _setsValue,
                          min: 1,
                          max: 10,
                          divisions: 9,
                          displayValue: _setsValue.round().toString(),
                          theme: _sliderTheme,
                          onChanged: (v) {
                            setState(() => _setsValue = v);
                            _save();
                          },
                        ),
                      _SliderRow(
                        label: 'Hold',
                        value: _holdValue,
                        min: 0,
                        max: 120,
                        divisions: 24,
                        displayValue: _holdValue.round() == 0
                            ? 'Off'
                            : '${_holdValue.round()}s',
                        theme: _sliderTheme,
                        onChanged: (v) {
                          setState(() => _holdValue = v);
                          _save();
                        },
                      ),
                      const SizedBox(height: 4),
                      _DurationSliderInline(
                        currentSeconds:
                            widget.exercise.effectiveDurationSeconds,
                        isCustom:
                            widget.exercise.customDurationSeconds != null,
                        onChanged: _setCustomDuration,
                        onReset: _clearCustomDuration,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                _buildSubSection(
                  title: 'Preview',
                  isOpen: _isPreviewOpen,
                  onToggle: () =>
                      setState(() => _isPreviewOpen = !_isPreviewOpen),
                  child: GestureDetector(
                    onTap: widget.onPreview,
                    child: Container(
                      height: 180,
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: AppColors.darkSurfaceVariant,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: widget.exercise.mediaType == MediaType.video &&
                                !_isStillImageConversion(widget.exercise)
                            ? Stack(
                                fit: StackFit.expand,
                                children: [
                                  if (widget.exercise.absoluteThumbnailPath !=
                                      null)
                                    Image.file(
                                      File(widget.exercise.absoluteThumbnailPath!),
                                      fit: BoxFit.contain,
                                      width: double.infinity,
                                      errorBuilder: (_, _, _) => Container(
                                        color: AppColors.darkSurfaceVariant,
                                      ),
                                    )
                                  else
                                    Container(
                                      color: AppColors.darkSurfaceVariant,
                                    ),
                                  Center(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.play_circle_outline,
                                          size: 48,
                                          color: widget.exercise
                                                      .absoluteThumbnailPath !=
                                                  null
                                              ? Colors.white70
                                              : AppColors.grey500,
                                        ),
                                        const SizedBox(height: 8),
                                        Text(
                                          'Tap to play',
                                          style: TextStyle(
                                            fontSize: 13,
                                            color: widget.exercise
                                                        .absoluteThumbnailPath !=
                                                    null
                                                ? Colors.white70
                                                : AppColors.grey500,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              )
                            : Image.file(
                                File(widget.exercise.displayFilePath),
                                fit: BoxFit.contain,
                                width: double.infinity,
                                errorBuilder: (_, _, _) => const Center(
                                  child: Icon(
                                    Icons.broken_image_outlined,
                                    size: 48,
                                    color: AppColors.grey500,
                                  ),
                                ),
                              ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                _buildSubSection(
                  title: 'Notes',
                  subtitle: widget.exercise.notes?.isNotEmpty == true
                      ? widget.exercise.notes!.substring(
                          0,
                          min(30, widget.exercise.notes!.length),
                        )
                      : 'Add notes...',
                  isOpen: _isNotesOpen,
                  onToggle: () =>
                      setState(() => _isNotesOpen = !_isNotesOpen),
                  child: TextField(
                    controller: _notesController,
                    decoration: const InputDecoration(
                      labelText: 'Notes',
                      hintText: 'e.g. Keep back straight, slow on the way down',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    maxLines: 2,
                    textCapitalization: TextCapitalization.sentences,
                    onChanged: (_) => _save(),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Slider row / duration slider / rest bar — copied verbatim from legacy file
// -----------------------------------------------------------------------------

class _SliderRow extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String displayValue;
  final SliderThemeData theme;
  final ValueChanged<double> onChanged;

  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.displayValue,
    required this.theme,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 40,
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.textSecondaryOnDark,
            ),
          ),
        ),
        Expanded(
          child: SliderTheme(
            data: theme,
            child: Slider(
              value: value,
              min: min,
              max: max,
              divisions: divisions,
              onChanged: onChanged,
            ),
          ),
        ),
        SizedBox(
          width: 36,
          child: Text(
            displayValue,
            textAlign: TextAlign.right,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: AppColors.textOnDark,
            ),
          ),
        ),
      ],
    );
  }
}

class _DurationSliderInline extends StatefulWidget {
  final int currentSeconds;
  final bool isCustom;
  final ValueChanged<int> onChanged;
  final VoidCallback onReset;

  const _DurationSliderInline({
    required this.currentSeconds,
    required this.isCustom,
    required this.onChanged,
    required this.onReset,
  });

  @override
  State<_DurationSliderInline> createState() => _DurationSliderInlineState();
}

class _DurationSliderInlineState extends State<_DurationSliderInline> {
  late double _value;

  @override
  void initState() {
    super.initState();
    _value = _snapToStep(widget.currentSeconds.toDouble());
  }

  @override
  void didUpdateWidget(covariant _DurationSliderInline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentSeconds != widget.currentSeconds) {
      _value = _snapToStep(widget.currentSeconds.toDouble());
    }
  }

  double _snapToStep(double v) => (v / 5).round().clamp(2, 120) * 5.0;

  String _formatDuration(int seconds) {
    if (seconds < 60) return '${seconds}s';
    final min = seconds ~/ 60;
    final sec = seconds % 60;
    if (sec == 0) return '${min}m';
    return '${min}m ${sec}s';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            const SizedBox(
              width: 40,
              child: Text(
                'Time',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textSecondaryOnDark,
                ),
              ),
            ),
            Expanded(
              child: SliderTheme(
                data: SliderThemeData(
                  trackHeight: 8,
                  activeTrackColor: AppColors.circuit,
                  inactiveTrackColor: AppColors.darkBorder,
                  thumbColor: AppColors.circuit,
                  thumbShape: const _RectangularSliderThumbShape(
                      width: 8, height: 24, radius: 4),
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 20),
                  overlayColor: AppColors.circuit.withValues(alpha: 0.12),
                  trackShape: const RoundedRectSliderTrackShape(),
                ),
                child: Slider(
                  value: _value,
                  min: 10,
                  max: 600,
                  divisions: 118,
                  onChanged: (v) {
                    final snapped = _snapToStep(v);
                    setState(() => _value = snapped);
                    widget.onChanged(snapped.round());
                  },
                ),
              ),
            ),
            SizedBox(
              width: 48,
              child: Text(
                _formatDuration(_value.round()),
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color:
                      widget.isCustom ? AppColors.circuit : AppColors.textOnDark,
                ),
              ),
            ),
          ],
        ),
        if (widget.isCustom)
          GestureDetector(
            onTap: widget.onReset,
            child: const Padding(
              padding: EdgeInsets.only(left: 40, top: 0),
              child: Text(
                'Reset to auto',
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.circuit,
                  decoration: TextDecoration.underline,
                  decorationColor: AppColors.circuit,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _RestBar extends StatefulWidget {
  final ExerciseCapture exercise;
  final int index;
  final ValueChanged<ExerciseCapture> onUpdate;
  final VoidCallback onDelete;
  final Widget dragHandle;

  const _RestBar({
    super.key,
    required this.exercise,
    required this.index,
    required this.onUpdate,
    required this.onDelete,
    required this.dragHandle,
  });

  @override
  State<_RestBar> createState() => _RestBarState();
}

class _RestBarState extends State<_RestBar> {
  late double _durationValue;

  @override
  void initState() {
    super.initState();
    _durationValue =
        (widget.exercise.holdSeconds ?? AppConfig.defaultRestDuration)
            .toDouble();
  }

  @override
  void didUpdateWidget(covariant _RestBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.exercise.id != widget.exercise.id) {
      _durationValue =
          (widget.exercise.holdSeconds ?? AppConfig.defaultRestDuration)
              .toDouble();
    }
  }

  String _formatDuration(int seconds) {
    if (seconds < 60) return '${seconds}s';
    final min = seconds ~/ 60;
    final sec = seconds % 60;
    if (sec == 0) return '$min min';
    return '${min}m ${sec}s';
  }

  @override
  Widget build(BuildContext context) {
    final seconds = _durationValue.round();
    return Container(
      height: 48,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: AppColors.darkSurfaceVariant,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.darkBorder, width: 1),
      ),
      child: Row(
        children: [
          const Padding(
            padding: EdgeInsets.only(left: 8, right: 6),
            child: Icon(
              Icons.self_improvement,
              size: 18,
              color: AppColors.rest,
            ),
          ),
          const Text(
            'Rest',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.rest,
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: SliderTheme(
              data: SliderThemeData(
                trackHeight: 4,
                activeTrackColor: AppColors.rest,
                inactiveTrackColor: AppColors.rest.withValues(alpha: 0.2),
                thumbColor: AppColors.rest,
                thumbShape: const _RectangularSliderThumbShape(
                    width: 6, height: 18, radius: 3),
                overlayShape:
                    const RoundSliderOverlayShape(overlayRadius: 14),
                overlayColor: AppColors.rest.withValues(alpha: 0.12),
                trackShape: const RoundedRectSliderTrackShape(),
              ),
              child: Slider(
                value: _durationValue,
                min: 5,
                max: 300,
                divisions: 59,
                onChanged: (v) {
                  setState(() => _durationValue = v);
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
              _formatDuration(seconds),
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.rest,
              ),
            ),
          ),
          GestureDetector(
            onTap: widget.onDelete,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Icon(
                Icons.close,
                size: 16,
                color: AppColors.rest.withValues(alpha: 0.5),
              ),
            ),
          ),
          const SizedBox(width: 4),
          widget.dragHandle,
        ],
      ),
    );
  }
}

class _DashedUnderlinePainter extends CustomPainter {
  final Color color;
  _DashedUnderlinePainter({this.color = Colors.grey});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;

    double startX = 0;
    const dashWidth = 4.0;
    const dashGap = 3.0;
    while (startX < size.width) {
      canvas.drawLine(
        Offset(startX, size.height),
        Offset(startX + dashWidth, size.height),
        paint,
      );
      startX += dashWidth + dashGap;
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _VideoPreviewDialog extends StatefulWidget {
  final String filePath;
  const _VideoPreviewDialog({required this.filePath});

  @override
  State<_VideoPreviewDialog> createState() => _VideoPreviewDialogState();
}

class _VideoPreviewDialogState extends State<_VideoPreviewDialog> {
  late VideoPlayerController _controller;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(File(widget.filePath))
      ..initialize().then((_) {
        if (mounted) {
          setState(() => _initialized = true);
          _controller.play();
        }
      }).catchError((e) {
        debugPrint('Video player init failed: $e');
      });
    _controller.setLooping(true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _togglePlayPause() {
    if (!_initialized) return;
    setState(() {
      if (_controller.value.isPlaying) {
        _controller.pause();
      } else {
        _controller.play();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      child: GestureDetector(
        onTap: _togglePlayPause,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Container(color: Colors.black),
            if (_initialized)
              Center(
                child: AspectRatio(
                  aspectRatio: _controller.value.aspectRatio,
                  child: VideoPlayer(_controller),
                ),
              )
            else
              const Center(
                child: CircularProgressIndicator(color: Colors.white54),
              ),
            if (_initialized && !_controller.value.isPlaying)
              const Center(
                child: Icon(Icons.play_arrow, size: 72, color: Colors.white54),
              ),
            Positioned(
              top: MediaQuery.of(context).padding.top + 8,
              right: 8,
              child: IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close, color: Colors.white, size: 28),
                style: IconButton.styleFrom(backgroundColor: Colors.black54),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RectangularSliderThumbShape extends SliderComponentShape {
  final double width;
  final double height;
  final double radius;

  const _RectangularSliderThumbShape({
    this.width = 8,
    this.height = 24,
    this.radius = 4,
  });

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) =>
      Size(width, height);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final canvas = context.canvas;
    final paint = Paint()
      ..color = sliderTheme.thumbColor ?? Colors.black87
      ..style = PaintingStyle.fill;
    final rect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: center, width: width, height: height),
      Radius.circular(radius),
    );
    canvas.drawRRect(rect, paint);
  }
}
