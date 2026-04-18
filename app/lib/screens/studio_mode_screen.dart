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

class _StudioModeScreenState extends State<StudioModeScreen> {
  late Session _session;
  late ConversionService _conversionService;
  StreamSubscription<ExerciseCapture>? _conversionSub;
  final ImagePicker _picker = ImagePicker();

  int? _expandedIndex;
  bool _isEditingName = false;
  late TextEditingController _nameController;
  final FocusNode _nameFocusNode = FocusNode();

  // --- Bottom-anchored display (chat-app pattern) ---
  // Carl's one-handed-use requirement: newest exercise should sit at the
  // BOTTOM of the viewport (near the thumb). Even when the list is short
  // and doesn't fill the screen, items must anchor at the bottom — older
  // captures push upward as new ones are added.
  //
  // Approach: CustomScrollView(reverse: true) + reversed iteration. Data
  // stays in ascending position order (1..N). The UI translates at the
  // boundary — itemBuilder maps visualIndex -> dataIndex, _onReorder maps
  // visual drop slots -> data slots. Every neighbor/circuit check inside
  // _buildExerciseItem receives DATA indices. Drag handles receive VISUAL
  // indices (what ReorderableList's API expects).

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
      // No scroll-to-newest needed: the reversed CustomScrollView keeps
      // the newest item bottom-anchored (thumb zone) automatically.
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

    // Delete-undo uses a MaterialBanner (top of screen) instead of a bottom
    // SnackBar. Two reasons: (1) a bottom snackbar would collide with the
    // camera shutter if the bio swipes to Camera mode before it times out,
    // and (2) banners are the semantically-correct Material component for
    // a dismissable top notification with an action.
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentMaterialBanner();
    messenger.clearSnackBars();
    messenger.showMaterialBanner(
      MaterialBanner(
        backgroundColor: AppColors.surfaceBase,
        contentTextStyle: const TextStyle(color: AppColors.textOnDark),
        content: Text(
          '${removed.name ?? 'Exercise ${index + 1}'} deleted',
        ),
        actions: [
          TextButton(
            onPressed: () async {
              messenger.hideCurrentMaterialBanner();
              await widget.storage.saveExercise(removed);
              await _refreshSession();
            },
            child: const Text(
              'Undo',
              style: TextStyle(
                color: AppColors.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          TextButton(
            onPressed: () => messenger.hideCurrentMaterialBanner(),
            child: const Text(
              'Dismiss',
              style: TextStyle(color: AppColors.textSecondaryOnDark),
            ),
          ),
        ],
      ),
    );
    // Auto-hide after 3 seconds (banners don't auto-dismiss by default).
    Future.delayed(const Duration(seconds: 3), () {
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentMaterialBanner();
    });
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

  /// Open the full PlanPreviewScreen positioned on the slide for the
  /// exercise at [dataIndex]. Circuit members land on their first round.
  /// Retained for a future Studio-level "Preview workout" entry point —
  /// the thumbnail tap now goes to [_openMediaViewer] instead.
  // ignore: unused_element
  void _openPlanPreviewAt(int dataIndex) {
    final slideIndex = PlanPreviewScreen.slideIndexForExerciseIndex(
      _session,
      dataIndex,
    );
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlanPreviewScreen(
          session: _session,
          initialSlideIndex: slideIndex,
        ),
      ),
    );
  }

  /// Lightweight full-screen viewer for the media behind a thumbnail.
  /// Not the workout simulator — just "show me the content". Video
  /// exercises get a looping autoplay player; photos get a zoomable
  /// Image.file; rest periods are silently ignored (no media).
  void _openMediaViewer(ExerciseCapture exercise) {
    if (exercise.isRest) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _MediaViewer(exercise: exercise),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surfaceBg,
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
        backgroundColor: AppColors.surfaceBase,
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
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: _buildEmptyState(),
        ),
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
    // `reverse: true` makes the scroll origin the bottom of the viewport.
    // Slivers are laid out bottom-to-top in array order. So sliver[0] sits
    // at the bottom; sliver[1] sits above it.
    //
    // Combined with reversed iteration inside the reorderable list
    // (visualIndex 0 == newest data item), the newest exercise anchors at
    // the bottom (thumb zone) even when the list is short.
    return CustomScrollView(
      reverse: true,
      slivers: [
        SliverReorderableList(
          itemCount: exercises.length,
          onReorder: _onReorder,
          itemBuilder: (context, visualIndex) {
            final dataIndex = exercises.length - 1 - visualIndex;
            return _buildExerciseItem(context, dataIndex, visualIndex);
          },
        ),
        if (totalDuration > 0)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            sliver: SliverToBoxAdapter(
              child: Text(
                'Estimated: ${formatDuration(totalDuration)}',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 12, color: AppColors.grey500),
              ),
            ),
          ),
      ],
    );
  }

  /// Builds one exercise row. [dataIndex] is the index into the underlying
  /// `_session.exercises` list (ascending 0..N-1); [visualIndex] is the
  /// slot inside the reversed [SliverReorderableList] (0 == bottom of
  /// viewport == newest).
  ///
  /// All circuit/neighbor reasoning uses DATA indices so semantics stay
  /// identical to the old ascending list. Only drag handles receive
  /// [visualIndex] because that's what [ReorderableDragStartListener]
  /// needs to talk to its ancestor list.
  Widget _buildExerciseItem(
      BuildContext context, int dataIndex, int visualIndex) {
    final exercises = _session.exercises;
    final exercise = exercises[dataIndex];

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
                  index: dataIndex,
                  onUpdate: (updated) => _updateExercise(dataIndex, updated),
                  onDelete: () => _deleteExercise(dataIndex),
                  dragHandle: ReorderableDragStartListener(
                    index: visualIndex,
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
              if (dataIndex < exercises.length - 1)
                _buildBetweenCardButtons(
                  upperIndex: dataIndex,
                  lowerIndex: dataIndex + 1,
                  isLinked: exercise.circuitId != null &&
                      exercises[dataIndex + 1].circuitId == exercise.circuitId,
                ),
            ],
          ),
        ),
      );
    }

    final isInCircuit = exercise.circuitId != null;
    final isFirstInCircuit = isInCircuit &&
        (dataIndex == 0 ||
            exercises[dataIndex - 1].circuitId != exercise.circuitId);
    final isLastInCircuit = isInCircuit &&
        (dataIndex == exercises.length - 1 ||
            exercises[dataIndex + 1].circuitId != exercise.circuitId);
    final hasNextInSameCircuit = isInCircuit &&
        dataIndex < exercises.length - 1 &&
        exercises[dataIndex + 1].circuitId == exercise.circuitId;
    final showBetweenButtons = dataIndex < exercises.length - 1;
    final isLinkedBelow = showBetweenButtons &&
        exercise.circuitId != null &&
        exercises[dataIndex + 1].circuitId == exercise.circuitId;

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
              dataIndex: dataIndex,
              visualIndex: visualIndex,
              isInCircuit: isInCircuit,
              isFirstInCircuit: isFirstInCircuit,
              isLastInCircuit: isLastInCircuit,
              hasNextInSameCircuit: hasNextInSameCircuit,
            ),
            if (showBetweenButtons)
              _buildBetweenCardButtons(
                upperIndex: dataIndex,
                lowerIndex: dataIndex + 1,
                isLinked: isLinkedBelow,
              ),
          ],
        ),
      ),
    );
  }

  /// [ReorderableList] calls this with VISUAL indices (0 == top slot of the
  /// widget, which in reverse mode is the bottom of the viewport — our
  /// newest data item). We translate to data indices before running the
  /// existing reorder/circuit-cleanup logic.
  void _onReorder(int oldVisualIndex, int newVisualIndex) {
    // Standard ReorderableList convention: when dragging downward through
    // the visual list, the framework passes newIndex = oldIndex+1 meaning
    // "slot after old". Normalise to a pure swap index.
    if (newVisualIndex > oldVisualIndex) newVisualIndex--;
    if (oldVisualIndex == newVisualIndex) return;

    final len = _session.exercises.length;
    // visualIndex 0 is the newest (data index len-1), so reversal is:
    //   dataIndex = len - 1 - visualIndex.
    final oldIndex = len - 1 - oldVisualIndex;
    final newIndex = len - 1 - newVisualIndex;

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
    required int dataIndex,
    required int visualIndex,
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
        onDismissed: (_) => _deleteExercise(dataIndex),
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
          index: dataIndex,
          isExpanded: _expandedIndex == dataIndex,
          isInCircuit: isInCircuit,
          onTap: () {
            setState(() {
              _expandedIndex =
                  _expandedIndex == dataIndex ? null : dataIndex;
            });
          },
          onUpdate: (updated) => _updateExercise(dataIndex, updated),
          onThumbnailTap: () => _openMediaViewer(exercise),
          dragHandle: ReorderableDragStartListener(
            index: visualIndex,
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
                    : AppColors.surfaceRaised,
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
                color: AppColors.surfaceRaised,
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
  final VoidCallback onThumbnailTap;
  final Widget? dragHandle;

  const _ExerciseCard({
    super.key,
    required this.exercise,
    required this.index,
    required this.isExpanded,
    this.isInCircuit = false,
    required this.onTap,
    required this.onUpdate,
    required this.onThumbnailTap,
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
      _isNotesOpen = false;
    }
    if (oldWidget.isExpanded && !widget.isExpanded) {
      _isSettingsOpen = false;
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
    inactiveTrackColor: AppColors.surfaceBorder,
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
              color: AppColors.surfaceRaised,
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
      color: AppColors.surfaceBase,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.surfaceBorder, width: 1),
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
                  // Tap thumbnail to open the full plan preview on this
                  // exercise's slide. Expand/collapse now lives solely on
                  // the chevron (see below) so the two affordances don't
                  // fight for the same gesture.
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.onThumbnailTap,
                    child: CaptureThumbnail(
                        exercise: widget.exercise, size: 56),
                  ),
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
                  // Chevron + drag handle: paired controls on the right. The
                  // chevron has its own 44x44 GestureDetector so the tap
                  // lands here even though the whole card is an InkWell
                  // (the detector wins the gesture arena for pointer-downs
                  // inside the 44x44 box). Keeping both icons at 24px /
                  // AppColors.grey500 makes them read as a unit.
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.onTap,
                    child: SizedBox(
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
                  ),
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
    // Vertical layout: label + value share the top row (label grows to fill,
    // value right-aligned), slider gets the full width below. Removes the
    // label truncation problem entirely — "Reps" now has the whole card
    // width to breathe in, not a clamped 34px box.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textSecondaryOnDark,
                ),
              ),
            ),
            Text(
              displayValue,
              style: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: AppColors.textOnDark,
              ),
            ),
          ],
        ),
        SliderTheme(
          data: theme,
          child: Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
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
    // Same vertical layout as _SliderRow — label row on top (with
    // right-aligned value), slider gets the full card width below.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Time',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textSecondaryOnDark,
                ),
              ),
            ),
            Text(
              _formatDuration(_value.round()),
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color:
                    widget.isCustom ? AppColors.circuit : AppColors.textOnDark,
              ),
            ),
          ],
        ),
        SliderTheme(
          data: SliderThemeData(
            trackHeight: 8,
            activeTrackColor: AppColors.circuit,
            inactiveTrackColor: AppColors.surfaceBorder,
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
        if (widget.isCustom)
          Align(
            alignment: Alignment.centerLeft,
            child: GestureDetector(
              onTap: widget.onReset,
              child: const Text(
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
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surfaceBorder, width: 1),
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

// -----------------------------------------------------------------------------
// Media viewer — full-screen playback/display of a single exercise's media.
// Not the workout simulator; just "show me the content behind this thumbnail".
// Reached by tapping the thumbnail on an exercise card.
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
      final controller =
          VideoPlayerController.file(File(widget.exercise.displayFilePath));
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
        // Tap body to toggle play/pause on video; photos ignore.
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
                    : const CircularProgressIndicator(color: Colors.white54),
              )
            else
              Center(
                child: Image.file(
                  File(widget.exercise.displayFilePath),
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const Icon(
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
                child: Icon(Icons.play_arrow,
                    size: 72, color: Colors.white54),
              ),
            Positioned(
              top: MediaQuery.of(context).padding.top + 8,
              right: 8,
              child: IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close, color: Colors.white, size: 28),
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
