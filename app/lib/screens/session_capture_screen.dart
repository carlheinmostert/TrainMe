import 'dart:async';
import 'dart:io';
import 'dart:math' show min;
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:uuid/uuid.dart';
import '../config.dart';
import '../models/exercise_capture.dart';
import '../models/session.dart';
import '../services/local_storage_service.dart';
import '../services/conversion_service.dart';
import '../services/path_resolver.dart';
import '../theme.dart';
import '../utils/duration_format.dart';
import '../widgets/branded_slider_theme.dart';
import '../widgets/capture_thumbnail.dart';
import '../widgets/circuit_accent.dart';
import '../widgets/drag_handle.dart';
import '../widgets/inline_editable_text.dart';
import '../widgets/powered_by_footer.dart';
import 'plan_preview_screen.dart';

/// Returns true when a video exercise's converted output is a still image
/// (i.e. the fallback frame-extraction path produced a .jpg/.png instead
/// of a video file, because OpenCV couldn't decode the video on iOS).
bool _isStillImageConversion(ExerciseCapture exercise) {
  final converted = exercise.convertedFilePath;
  if (converted == null) return false;
  final ext = converted.toLowerCase();
  return ext.endsWith('.jpg') || ext.endsWith('.jpeg') || ext.endsWith('.png');
}

/// Unified session workspace — capture, annotate, and publish in one screen.
///
/// Shows all captured exercises as expandable cards with inline editing.
/// Three action buttons at the bottom: Import, Capture, and Publish.
/// After publishing, the Publish button becomes "Published" with a share
/// icon. Editing exercises marks the session as dirty, showing "Update".
/// The client name is editable via the AppBar title.
class SessionCaptureScreen extends StatefulWidget {
  final Session session;
  final LocalStorageService storage;

  const SessionCaptureScreen({
    super.key,
    required this.session,
    required this.storage,
  });

  @override
  State<SessionCaptureScreen> createState() => _SessionCaptureScreenState();
}

class _SessionCaptureScreenState extends State<SessionCaptureScreen> {
  late Session _session;
  late ConversionService _conversionService;
  StreamSubscription<ExerciseCapture>? _conversionSub;
  final ImagePicker _picker = ImagePicker();

  int? _expandedIndex;

  @override
  void initState() {
    super.initState();
    _session = widget.session;
    _conversionService = ConversionService.instance;
    _listenToConversions();
  }

  @override
  void dispose() {
    _conversionSub?.cancel();
    // Note: _conversionService is a singleton — never dispose it.
    super.dispose();
  }

  /// Commit the inline client-name edit.
  void _saveClientName(String newName) {
    if (newName.isNotEmpty && newName != _session.clientName) {
      setState(() {
        _session = _session.copyWith(clientName: newName);
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
  }

  /// Listen for conversion updates and refresh the exercise list.
  void _listenToConversions() {
    _conversionSub = _conversionService.onConversionUpdate.listen((updated) {
      setState(() {
        final exercises = List<ExerciseCapture>.from(_session.exercises);
        final idx = exercises.indexWhere((e) => e.id == updated.id);
        if (idx >= 0) {
          exercises[idx] = updated;
          _session = _session.copyWith(exercises: exercises);
        }
      });
    });
  }

  // ---------------------------------------------------------------------------
  // Import from photo library
  // ---------------------------------------------------------------------------

  /// Import a photo from the device's photo library.
  Future<void> _importPhoto() async {
    try {
      final picked = await _picker.pickImage(source: ImageSource.gallery);
      if (picked == null) return;

      await _addCaptureFromFile(picked.path, MediaType.photo);
    } catch (e) {
      debugPrint('Photo import failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Import failed: $e')),
        );
      }
    }
  }

  /// Import a video from the device's photo library.
  Future<void> _importVideo() async {
    try {
      final picked = await _picker.pickVideo(source: ImageSource.gallery);
      if (picked == null) return;

      await _addCaptureFromFile(picked.path, MediaType.video);
    } catch (e) {
      debugPrint('Video import failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Import failed: $e')),
        );
      }
    }
  }

  /// Show a bottom sheet to choose photo or video import.
  void _showImportOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.darkSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Import from Library',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textOnDark,
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.photo_outlined, color: AppColors.textSecondaryOnDark),
                title: const Text('Photo', style: TextStyle(color: AppColors.textOnDark)),
                subtitle: const Text('Import a still image', style: TextStyle(color: AppColors.textSecondaryOnDark)),
                onTap: () {
                  Navigator.pop(context);
                  _importPhoto();
                },
              ),
              ListTile(
                leading: const Icon(Icons.videocam_outlined, color: AppColors.textSecondaryOnDark),
                title: const Text('Video', style: TextStyle(color: AppColors.textOnDark)),
                subtitle: const Text('Import a video clip', style: TextStyle(color: AppColors.textSecondaryOnDark)),
                onTap: () {
                  Navigator.pop(context);
                  _importVideo();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Live camera capture
  // ---------------------------------------------------------------------------

  /// Open the live camera capture screen.
  Future<void> _openCameraCapture() async {
    final result = await Navigator.of(context).push<ExerciseCapture>(
      MaterialPageRoute(
        builder: (_) => _CameraCaptureScreen(
          session: _session,
          storage: widget.storage,
        ),
      ),
    );

    if (result != null) {
      setState(() {
        _session = _session.copyWith(
          exercises: [..._session.exercises, result],
        );
      });
  
      _conversionService.queueConversion(result);
      _autoInsertRestPeriods();
    }

    // Refresh session from storage in case multiple captures were added
    await _refreshSession();
  }

  // ---------------------------------------------------------------------------
  // Shared helpers
  // ---------------------------------------------------------------------------

  /// Copy an imported file to app storage and create an exercise from it.
  Future<void> _addCaptureFromFile(String sourcePath, MediaType type) async {
    final dir = await getApplicationDocumentsDirectory();
    final rawDir = Directory(p.join(dir.path, 'raw'));
    await rawDir.create(recursive: true);

    // Copy to app's document directory for persistence
    final ext = p.extension(sourcePath);
    final destPath = p.join(rawDir.path, '${DateTime.now().millisecondsSinceEpoch}$ext');
    await File(sourcePath).copy(destPath);

    final position = _session.exercises.length;
    final exercise = ExerciseCapture.create(
      position: position,
      rawFilePath: PathResolver.toRelative(destPath),
      mediaType: type,
      sessionId: _session.id,
    );

    await widget.storage.saveExercise(exercise);

    setState(() {
      _session = _session.copyWith(
        exercises: [..._session.exercises, exercise],
      );
    });


    _conversionService.queueConversion(exercise);
    _autoInsertRestPeriods();
  }

  // ---------------------------------------------------------------------------
  // Rest periods
  // ---------------------------------------------------------------------------

  /// Insert a rest period between two exercises at [insertIndex].
  ///
  /// The rest is placed at [insertIndex], pushing later exercises down.
  /// If a rest already exists at that position, this is a no-op.
  Future<void> _insertRestBetween(int insertIndex) async {
    final exercises = List<ExerciseCapture>.from(_session.exercises);

    // Don't insert if there's already a rest adjacent (above or below)
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

    // Re-index positions
    for (var i = 0; i < exercises.length; i++) {
      exercises[i] = exercises[i].copyWith(position: i);
    }

    setState(() {
      _session = _session.copyWith(exercises: exercises);
      // Adjust expanded index if it shifted
      if (_expandedIndex != null && _expandedIndex! >= insertIndex) {
        _expandedIndex = _expandedIndex! + 1;
      }
    });

    await widget.storage.saveExercise(rest);
    _saveExerciseOrder();
  }

  /// Auto-insert rest periods when cumulative exercise time exceeds the
  /// session's rest interval threshold.
  ///
  /// Walks exercises in position order, summing estimated durations for
  /// non-rest exercises. When the accumulator exceeds the threshold, a rest
  /// period is inserted at that position and the accumulator resets.
  ///
  /// Does not insert at the very beginning or end. Existing rest periods
  /// are skipped in the accumulation.
  void _autoInsertRestPeriods() {
    final exercises = List<ExerciseCapture>.from(_session.exercises);
    final threshold = _session.effectiveRestIntervalSeconds;

    // Don't auto-insert if threshold is unreasonably small.
    if (threshold < 60) return;

    int cumulativeSeconds = 0;
    final insertPositions = <int>[];

    for (var i = 0; i < exercises.length; i++) {
      final ex = exercises[i];
      if (ex.isRest) continue; // Skip existing rests in accumulation

      cumulativeSeconds += ex.effectiveDurationSeconds;

      if (cumulativeSeconds >= threshold) {
        // Only insert if we're not at the very end
        if (i < exercises.length - 1) {
          // Check that a rest doesn't already exist adjacent (above or below)
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

    // Insert rests at computed positions (reverse to keep indices stable)
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

    // Re-index positions
    for (var i = 0; i < exercises.length; i++) {
      exercises[i] = exercises[i].copyWith(position: i);
    }

    setState(() {
      _session = _session.copyWith(exercises: exercises);
    });

    // Persist new rest exercises
    for (final pos in insertPositions) {
      final adjustedPos = pos + (insertPositions.indexOf(pos));
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

  /// Reload session from storage to pick up any changes.
  Future<void> _refreshSession() async {
    final refreshed = await widget.storage.getSession(_session.id);
    if (refreshed != null && mounted) {
      setState(() => _session = refreshed);
    }
  }

  // ---------------------------------------------------------------------------
  // Exercise management
  // ---------------------------------------------------------------------------

  Future<void> _saveExerciseOrder() async {

    for (final ex in _session.exercises) {
      await widget.storage.saveExercise(ex);
    }
  }

  /// Update an exercise's metadata (reps, sets, hold, notes).
  void _updateExercise(int index, ExerciseCapture updated) {
    setState(() {
      final exercises = List<ExerciseCapture>.from(_session.exercises);
      exercises[index] = updated;
      _session = _session.copyWith(exercises: exercises);
    });

    unawaited(widget.storage.saveExercise(updated).catchError((e, st) {
      debugPrint('saveExercise failed: $e');
    }));
  }

  /// Delete an exercise and show an undo SnackBar.
  void _deleteExercise(int index) {
    final removed = _session.exercises[index];
    final exercises = List<ExerciseCapture>.from(_session.exercises);
    exercises.removeAt(index);

    // Reindex positions
    for (var i = 0; i < exercises.length; i++) {
      exercises[i] = exercises[i].copyWith(position: i);
    }

    setState(() {
      _session = _session.copyWith(exercises: exercises);
      if (_expandedIndex == index) {
        _expandedIndex = null;
      } else if (_expandedIndex != null && _expandedIndex! > index) {
        _expandedIndex = _expandedIndex! - 1;
      }
    });



    // Persist deletion
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
            // Restore the exercise
            await widget.storage.saveExercise(removed);
            await _refreshSession();
          },
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Circuit linking / unlinking
  // ---------------------------------------------------------------------------

  /// Link two adjacent exercises into a circuit.
  ///
  /// [upperIndex] is the index of the exercise above the link button,
  /// [lowerIndex] is the one below. Handles all merge scenarios:
  /// - Neither in a circuit: create a new circuit
  /// - One in a circuit: add the other to the existing circuit
  /// - Both in different circuits: merge circuits
  void _linkExercises(int upperIndex, int lowerIndex) {
    final exercises = List<ExerciseCapture>.from(_session.exercises);
    final upper = exercises[upperIndex];
    final lower = exercises[lowerIndex];

    final upperCircuit = upper.circuitId;
    final lowerCircuit = lower.circuitId;

    if (upperCircuit == null && lowerCircuit == null) {
      // Neither in a circuit — create a new one
      final newCircuitId = const Uuid().v4();
      exercises[upperIndex] = upper.copyWith(circuitId: newCircuitId);
      exercises[lowerIndex] = lower.copyWith(circuitId: newCircuitId);
    } else if (upperCircuit != null && lowerCircuit == null) {
      // Upper is in a circuit, lower is not — add lower to upper's circuit
      exercises[lowerIndex] = lower.copyWith(circuitId: upperCircuit);
    } else if (upperCircuit == null && lowerCircuit != null) {
      // Lower is in a circuit, upper is not — add upper to lower's circuit
      exercises[upperIndex] = upper.copyWith(circuitId: lowerCircuit);
    } else if (upperCircuit != lowerCircuit) {
      // Both in different circuits — merge lower's circuit into upper's
      final targetId = upperCircuit!;
      final sourceId = lowerCircuit!;
      for (var i = 0; i < exercises.length; i++) {
        if (exercises[i].circuitId == sourceId) {
          exercises[i] = exercises[i].copyWith(circuitId: targetId);
        }
      }
      // Migrate cycle count from source circuit if target doesn't have one
      var updatedCycles = Map<String, int>.from(_session.circuitCycles);
      if (!updatedCycles.containsKey(targetId) &&
          updatedCycles.containsKey(sourceId)) {
        updatedCycles[targetId] = updatedCycles[sourceId]!;
      }
      updatedCycles.remove(sourceId);
      _session = _session.copyWith(circuitCycles: updatedCycles);
      unawaited(widget.storage.saveSession(_session).catchError((e, st) {
        debugPrint('saveSession failed: $e');
      }));
    }

    setState(() {
      _session = _session.copyWith(exercises: exercises);
    });
    _saveAllExercises(exercises);
  }

  /// Unlink exercises at the boundary between [upperIndex] and [lowerIndex].
  ///
  /// Splits the circuit: exercises at and above upperIndex keep the existing
  /// circuitId; exercises at and below lowerIndex get a new circuitId (or
  /// become standalone if they'd be alone).
  void _unlinkExercises(int upperIndex, int lowerIndex) {
    final exercises = List<ExerciseCapture>.from(_session.exercises);
    final circuitId = exercises[upperIndex].circuitId;
    if (circuitId == null) return;

    // Find all exercises in this circuit, in position order
    final circuitMembers = <int>[];
    for (var i = 0; i < exercises.length; i++) {
      if (exercises[i].circuitId == circuitId) {
        circuitMembers.add(i);
      }
    }

    // Split point: members at or before upperIndex keep the old id,
    // members at or after lowerIndex get a new id (or cleared)
    final splitPos = circuitMembers.indexOf(lowerIndex);
    if (splitPos < 0) return;

    final upperGroup = circuitMembers.sublist(0, splitPos);
    final lowerGroup = circuitMembers.sublist(splitPos);

    // If upper group has only 1 member, remove it from the circuit
    if (upperGroup.length == 1) {
      exercises[upperGroup[0]] =
          exercises[upperGroup[0]].copyWith(clearCircuitId: true);
    }

    // If lower group has only 1 member, remove it from the circuit
    if (lowerGroup.length == 1) {
      exercises[lowerGroup[0]] =
          exercises[lowerGroup[0]].copyWith(clearCircuitId: true);
    } else {
      // Lower group gets a new circuit id
      final newCircuitId = const Uuid().v4();
      for (final idx in lowerGroup) {
        exercises[idx] = exercises[idx].copyWith(circuitId: newCircuitId);
      }
      // Copy the cycle count from the original circuit
      var updatedCycles = Map<String, int>.from(_session.circuitCycles);
      if (updatedCycles.containsKey(circuitId)) {
        updatedCycles[newCircuitId] = updatedCycles[circuitId]!;
      }
      _session = _session.copyWith(circuitCycles: updatedCycles);
      unawaited(widget.storage.saveSession(_session).catchError((e, st) {
        debugPrint('saveSession failed: $e');
      }));
    }

    setState(() {
      _session = _session.copyWith(exercises: exercises);
    });
    _saveAllExercises(exercises);
  }

  /// Update the cycle count for a circuit.
  void _setCircuitCycles(String circuitId, int cycles) {
    setState(() {
      _session = _session.setCircuitCycles(circuitId, cycles);
    });
    unawaited(widget.storage.saveSession(_session).catchError((e, st) {
      debugPrint('saveSession failed: $e');
    }));
  }

  /// Save all exercises to storage (used after circuit changes).
  Future<void> _saveAllExercises(List<ExerciseCapture> exercises) async {
    for (final ex in exercises) {
      await widget.storage.saveExercise(ex);
    }
  }

  // ---------------------------------------------------------------------------
  // Preview
  // ---------------------------------------------------------------------------

  /// Show a full-screen preview of a capture.
  /// Photos get a simple Image.file viewer; videos get a full video player.
  /// If a video was converted to a still line drawing image (fallback when
  /// OpenCV can't decode H.264/H.265 on iOS), show it as an image instead.
  void _previewCapture(ExerciseCapture exercise) {
    // Rest periods have no media to preview.
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
                errorBuilder: (_, __, ___) => const Center(
                  child: Icon(Icons.broken_image_outlined,
                      size: 64, color: Colors.white54),
                ),
              ),
              Positioned(
                top: MediaQuery.of(context).padding.top + 8,
                right: 8,
                child: IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon:
                      const Icon(Icons.close, color: Colors.white, size: 28),
                  style:
                      IconButton.styleFrom(backgroundColor: Colors.black54),
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
        title: InlineEditableText(
          initialValue: _session.clientName,
          onCommit: _saveClientName,
          textStyle: const TextStyle(
            fontWeight: FontWeight.w700,
            letterSpacing: -0.5,
            fontSize: 20,
            color: AppColors.textOnDark,
          ),
        ),
        backgroundColor: AppColors.darkSurface,
        foregroundColor: AppColors.textOnDark,
        elevation: 0,
        actions: [
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
      body: _buildBody(),
    );
  }

  /// Main body — shows exercise list with a wireframe add card at the end,
  /// or just the add card when the list is empty.
  Widget _buildBody() {
    if (_session.exercises.isEmpty) {
      // Empty state: centered wireframe card with footer at bottom
      return Column(
        children: [
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: _buildAddExerciseCard(),
              ),
            ),
          ),
          const PoweredByFooter(),
        ],
      );
    }
    // Non-empty: exercise list is built separately with the card appended
    return _buildExerciseList();
  }

  /// Wireframe "Add Exercise" card — dashed-look placeholder card with
  /// Import and Capture buttons.
  Widget _buildAddExerciseCard() {
    final totalDuration = _session.estimatedTotalDurationSeconds;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_session.exercises.isNotEmpty && totalDuration > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'Estimated: ${formatDuration(totalDuration)}',
              style: const TextStyle(fontSize: 12, color: AppColors.grey500),
            ),
          ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
          decoration: BoxDecoration(
            color: AppColors.darkSurfaceVariant,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.darkBorder, width: 1.5),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _showImportOptions,
                      icon: const Icon(Icons.photo_library_outlined, size: 20),
                      label: const Text('Import'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.textSecondaryOnDark,
                        side: const BorderSide(color: AppColors.darkBorder),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _openCameraCapture,
                      icon: const Icon(Icons.videocam_outlined, size: 20),
                      label: const Text('Capture'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.textSecondaryOnDark,
                        side: const BorderSide(color: AppColors.darkBorder),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              const Text(
                'Add an exercise',
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.grey500,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Exercise list — reorderable list with drag handles.
  ///
  /// Each exercise is a single item in a ReorderableListView. Circuit visual
  /// grouping is achieved via per-card accent left border decoration. Circuit
  /// headers render above the first card in a circuit group. Between-card
  /// buttons (link + rest insert) render below each card.
  ///
  /// Rest periods render as compact [_RestBar] widgets instead of full cards.
  Widget _buildExerciseList() {
    final exercises = _session.exercises;

    return CustomScrollView(
      slivers: [
        SliverReorderableList(
          itemCount: exercises.length,
          onReorder: _onReorder,
          itemBuilder: _buildExerciseItem,
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          sliver: SliverToBoxAdapter(
            child: _buildAddExerciseCard(),
          ),
        ),
        const SliverToBoxAdapter(
          child: PoweredByFooter(),
        ),
      ],
    );
  }

  /// Builds a single exercise item for the reorderable list.
  Widget _buildExerciseItem(BuildContext context, int index) {
    final exercises = _session.exercises;
    final exercise = exercises[index];

    // --- Rest period: compact inline bar ---
    if (exercise.isRest) {
      final isInCircuit = exercise.circuitId != null;

      final restBar = _RestBar(
        key: ValueKey('rest_${exercise.id}'),
        exercise: exercise,
        index: index,
        onUpdate: (updated) => _updateExercise(index, updated),
        onDelete: () => _deleteExercise(index),
        dragHandle: DragHandle(index: index),
      );

      return KeyedSubtree(
        key: ValueKey(exercise.id),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            children: [
              isInCircuit ? CircuitAccent(child: restBar) : restBar,
              // Between-card buttons after rest bar (if not last item)
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

    // --- Regular exercise: full card ---
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
    final bool showBetweenButtons = index < exercises.length - 1;
    final bool isLinkedBelow = showBetweenButtons &&
        exercise.circuitId != null &&
        exercises[index + 1].circuitId == exercise.circuitId;

    return KeyedSubtree(
      key: ValueKey(exercise.id),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isFirstInCircuit)
              _buildCircuitHeader(exercise.circuitId!),
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


  /// Handle reorder: update positions, collapse expanded cards, save.
  void _onReorder(int oldIndex, int newIndex) {
    // ReorderableListView passes newIndex as if the old item is still present
    if (newIndex > oldIndex) newIndex--;
    if (oldIndex == newIndex) return;

    setState(() {
      // Collapse any expanded card
      _expandedIndex = null;

      final exercises = List<ExerciseCapture>.from(_session.exercises);
      final moved = exercises.removeAt(oldIndex);
      exercises.insert(newIndex, moved);

      // Re-index positions
      for (var i = 0; i < exercises.length; i++) {
        exercises[i] = exercises[i].copyWith(position: i);
      }

      // --- Circuit orphan cleanup after reorder ---
      // 1. Clear circuitId for exercises dragged away from their circuit mates
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

      // 2. Dissolve single-member circuits (a circuit of one makes no sense)
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

      _session = _session.copyWith(exercises: exercises);
    });
    _saveExerciseOrder();

    // Learn preferred rest interval: if a rest was moved, compute cumulative
    // exercise time before it and store as the session's preferred interval.
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
          _session = _session.copyWith(
            preferredRestIntervalSeconds: cumulativeSeconds,
          );
        });
        unawaited(widget.storage.saveSession(_session).catchError((e, st) {
          debugPrint('saveSession failed: $e');
        }));
      }
    }
  }

  /// Build a single exercise card with drag handle and optional circuit border.
  Widget _buildReorderableCard({
    required ExerciseCapture exercise,
    required int index,
    required bool isInCircuit,
    required bool isFirstInCircuit,
    required bool isLastInCircuit,
    required bool hasNextInSameCircuit,
  }) {
    final card = Dismissible(
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
        dragHandle: DragHandle(index: index),
      ),
    );

    return isInCircuit ? CircuitAccent(child: card) : card;
  }

  /// Build the circuit header row with cycle slider.
  Widget _buildCircuitHeader(String circuitId) {
    final cycles = _session.getCircuitCycles(circuitId);

    // Add accent left border to match the cards below. The header uses a
    // slightly larger interior offset than the card rows (12px total) so the
    // "Circuit" label breathes away from the accent rule.
    return CircuitAccent(
      child: Padding(
        padding: const EdgeInsets.only(left: 4, top: 4, bottom: 4),
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
                data: brandedSliderTheme(
                  accent: AppColors.circuit,
                  trackHeight: 3,
                  thumbWidth: 6,
                  thumbHeight: 18,
                  thumbRadius: 3,
                  overlayRadius: 14,
                  inactiveTrackColor:
                      AppColors.circuit.withValues(alpha: 0.2),
                ),
                child: Slider(
                  value: cycles.clamp(1, 5).toDouble(),
                  min: 1,
                  max: 5,
                  divisions: 4,
                  onChanged: (v) {
                    _setCircuitCycles(circuitId, v.round());
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Build the link/unlink button and rest insert button between two exercise
  /// items.
  ///
  /// When the exercises above and below are in the same circuit, the row
  /// also gets the accent left border to maintain visual continuity.
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
          // Link / unlink button
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
                  color: isLinked
                      ? AppColors.circuit
                      : AppColors.grey500,
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
          // Rest insert button
          GestureDetector(
            onTap: () => _insertRestBetween(lowerIndex),
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.darkSurfaceVariant,
                border: Border.all(
                  color: AppColors.rest,
                  width: 1.5,
                ),
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
      return CircuitAccent(child: buttons);
    }

    return buttons;
  }

  /// Bottom action bar — icon buttons with labels, like a tab bar.
}

// ---------------------------------------------------------------------------
// Exercise card — expandable card with thumbnail, metadata, and editing
// ---------------------------------------------------------------------------

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

  // Independent collapsible sub-sections
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
  }

  @override
  void didUpdateWidget(covariant _ExerciseCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.exercise.id != widget.exercise.id) {
      _repsValue = (widget.exercise.reps ?? 10).toDouble();
      _setsValue = (widget.exercise.sets ?? 3).toDouble();
      _holdValue = (widget.exercise.holdSeconds ?? 0).toDouble();
      _notesController.text = widget.exercise.notes ?? '';
      _isSettingsOpen = false;
      _isPreviewOpen = false;
      _isNotesOpen = false;
    }
    // Auto-close all sub-sections when card collapses
    if (oldWidget.isExpanded && !widget.isExpanded) {
      _isSettingsOpen = false;
      _isPreviewOpen = false;
      _isNotesOpen = false;
    }
  }

  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  /// Display name: custom name if set, otherwise "Exercise {index+1}".
  String get _displayName =>
      widget.exercise.name ?? 'Exercise ${widget.index + 1}';

  /// Commit the inline name edit.
  void _saveExerciseName(String newName) {
    if (newName.isNotEmpty && newName != _displayName) {
      // If the user typed back the default placeholder, clear the custom name
      final isDefault = newName == 'Exercise ${widget.index + 1}';
      widget.onUpdate(widget.exercise.copyWith(
        name: isDefault ? null : newName,
        clearName: isDefault,
      ));
    }
  }

  void _save() {
    widget.onUpdate(widget.exercise.copyWith(
      reps: _repsValue.round(),
      sets: _setsValue.round(),
      holdSeconds: _holdValue.round(),
      notes: _notesController.text.isEmpty ? null : _notesController.text,
    ));
  }

  /// Shared slider theme — thick track, rectangular thumb, primary fill.
  static final SliderThemeData _sliderTheme = brandedSliderTheme(
    accent: AppColors.primary,
    overlayRadius: 20,
  );

  /// Build a conversion status icon for the collapsed header row.
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
        return const Icon(Icons.check_circle, size: 18, color: AppColors.success);
      case ConversionStatus.failed:
        return const Icon(Icons.error_outline, size: 18, color: AppColors.error);
    }
  }

  /// Build a small microphone toggle for the collapsed header row.
  /// Tapping toggles includeAudio and auto-saves via onUpdate.
  Widget _buildAudioToggle() {
    final isOn = widget.exercise.includeAudio;
    return GestureDetector(
      onTap: () {
        widget.onUpdate(
          widget.exercise.copyWith(includeAudio: !isOn),
        );
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

  /// Build a compact one-line summary of settings for the summary bar.
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

  /// Set a custom duration override and auto-save.
  void _setCustomDuration(int seconds) {
    widget.onUpdate(widget.exercise.copyWith(customDurationSeconds: seconds));
  }

  /// Reset to auto-calculated duration.
  void _clearCustomDuration() {
    widget.onUpdate(widget.exercise.copyWith(clearCustomDuration: true));
  }

  /// Reusable collapsible sub-section with dark header background.
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
              // ── Level 1: Collapsed header row ──
              Row(
                children: [
                  // Thumbnail
                  CaptureThumbnail(
                    exercise: widget.exercise,
                    size: 56,
                  ),
                  const SizedBox(width: 12),

                  // Name + status (left-aligned, takes available space)
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: InlineEditableText(
                            key: ValueKey('name_${widget.exercise.id}'),
                            initialValue: _displayName,
                            onCommit: _saveExerciseName,
                            textStyle: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 15,
                              color: AppColors.textOnDark,
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

                  // Right-aligned: chevron + drag handle with 44px tap targets
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
                  if (widget.dragHandle != null)
                    widget.dragHandle!,
                ],
              ),

              // ── Expanded view: three independent collapsible sub-sections ──
              if (widget.isExpanded) ...[
                const SizedBox(height: 12),
                const Divider(height: 1),
                const SizedBox(height: 12),

                // Conversion error banner (always visible when relevant)
                if (widget.exercise.conversionStatus ==
                    ConversionStatus.failed)
                  Container(
                    padding: const EdgeInsets.all(12),
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF3B1111),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.error.withValues(alpha: 0.4)),
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

                // ── Settings sub-section ──
                _buildSubSection(
                  title: _buildSettingsSummary(),
                  isOpen: _isSettingsOpen,
                  onToggle: () =>
                      setState(() => _isSettingsOpen = !_isSettingsOpen),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Reps slider
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

                      // Sets slider — hidden when in a circuit
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

                      // Hold slider
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

                      // Duration override
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

                // ── Preview sub-section ──
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
                        child: widget.exercise.mediaType ==
                                    MediaType.video &&
                                !_isStillImageConversion(widget.exercise)
                            ? Stack(
                                fit: StackFit.expand,
                                children: [
                                  if (widget.exercise.absoluteThumbnailPath !=
                                      null)
                                    Image.file(
                                      File(widget
                                          .exercise.absoluteThumbnailPath!),
                                      fit: BoxFit.contain,
                                      width: double.infinity,
                                      errorBuilder:
                                          (_, __, ___) => Container(
                                        color: AppColors.darkSurfaceVariant,
                                      ),
                                    )
                                  else
                                    Container(
                                        color: AppColors.darkSurfaceVariant),
                                  Center(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                            Icons
                                                .play_circle_outline,
                                            size: 48,
                                            color: widget.exercise
                                                        .absoluteThumbnailPath !=
                                                    null
                                                ? Colors.white70
                                                : AppColors.grey500),
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
                                File(widget
                                    .exercise.displayFilePath),
                                fit: BoxFit.contain,
                                width: double.infinity,
                                errorBuilder: (_, __, ___) => const Center(
                                  child: Icon(
                                      Icons.broken_image_outlined,
                                      size: 48,
                                      color: AppColors.grey500),
                                ),
                              ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 4),

                // ── Notes sub-section ──
                _buildSubSection(
                  title: 'Notes',
                  subtitle: widget.exercise.notes?.isNotEmpty == true
                      ? widget.exercise.notes!
                          .substring(
                              0,
                              min(30,
                                  widget.exercise.notes!.length))
                      : 'Add notes...',
                  isOpen: _isNotesOpen,
                  onToggle: () =>
                      setState(() => _isNotesOpen = !_isNotesOpen),
                  child: TextField(
                    controller: _notesController,
                    decoration: const InputDecoration(
                      labelText: 'Notes',
                      hintText:
                          'e.g. Keep back straight, slow on the way down',
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

// ---------------------------------------------------------------------------
// Thick modern slider row — label on left, value on right, slider below
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Compact inline duration slider — appears below the tappable duration label
// ---------------------------------------------------------------------------

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

  /// Snap to nearest 5-second step within [10, 600].
  double _snapToStep(double v) {
    return (v / 5).round().clamp(2, 120) * 5.0;
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
                data: brandedSliderTheme(
                  accent: AppColors.circuit,
                  overlayRadius: 20,
                ),
                child: Slider(
                  value: _value,
                  min: 10,
                  max: 600,
                  divisions: 118, // (600 - 10) / 5
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
                formatDurationStyled(_value.round(),
                    style: DurationFormatStyle.compact),
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: widget.isCustom ? AppColors.circuit : AppColors.textOnDark,
                ),
              ),
            ),
          ],
        ),
        // "Reset to auto" link
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

// ---------------------------------------------------------------------------
// Compact rest bar — thin inline bar replacing full _ExerciseCard for rests
// ---------------------------------------------------------------------------

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
          // Rest icon
          const Padding(
            padding: EdgeInsets.only(left: 8, right: 6),
            child: Icon(
              Icons.self_improvement,
              size: 18,
              color: AppColors.rest,
            ),
          ),

          // "Rest" label
          const Text(
            'Rest',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.rest,
            ),
          ),

          const SizedBox(width: 4),

          // Compact slider
          Expanded(
            child: SliderTheme(
              data: brandedSliderTheme(
                accent: AppColors.rest,
                trackHeight: 4,
                thumbWidth: 6,
                thumbHeight: 18,
                thumbRadius: 3,
                overlayRadius: 14,
                inactiveTrackColor:
                    AppColors.rest.withValues(alpha: 0.2),
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

          // Duration label
          SizedBox(
            width: 42,
            child: Text(
              formatDurationStyled(seconds,
                  style: DurationFormatStyle.compact),
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.rest,
              ),
            ),
          ),

          // Delete button
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

          // Drag handle — far right, matching _ExerciseCard position
          widget.dragHandle,
        ],
      ),
    );
  }
}

// =============================================================================
// Video preview dialog
// =============================================================================

/// Full-screen video player shown when tapping a video exercise.
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
            // Play/pause indicator (shows briefly on tap)
            if (_initialized && !_controller.value.isPlaying)
              const Center(
                child: Icon(Icons.play_arrow, size: 72, color: Colors.white54),
              ),
            // Close button
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

// =============================================================================
// Camera capture sub-screen
// =============================================================================

/// Full-screen camera capture. Returns a single ExerciseCapture on pop,
/// or null if the user cancels.
class _CameraCaptureScreen extends StatefulWidget {
  final Session session;
  final LocalStorageService storage;

  const _CameraCaptureScreen({
    required this.session,
    required this.storage,
  });

  @override
  State<_CameraCaptureScreen> createState() => _CameraCaptureScreenState();
}

class _CameraCaptureScreenState extends State<_CameraCaptureScreen>
    with WidgetsBindingObserver {
  CameraController? _cameraController;
  bool _isCameraInitialized = false;
  bool _isRecording = false;
  bool _wasRecordingOnBackground = false;
  Timer? _recordingTimer;
  double _recordingProgress = 0.0;
  int _recordingSeconds = 0;

  static const _maxRecordingSeconds = 30;
  static const _amberThresholdSeconds = 15;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _recordingTimer?.cancel();
    _cameraController?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      // Cancel any in-progress recording timer and flag that we tore down
      // mid-record so we can notify the user on resume.
      _recordingTimer?.cancel();
      _recordingTimer = null;
      if (_isRecording) {
        _wasRecordingOnBackground = true;
      }
      setState(() {
        _isRecording = false;
        _recordingProgress = 0.0;
        _isCameraInitialized = false;
      });
      _cameraController?.dispose();
      _cameraController = null;
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
      if (_wasRecordingOnBackground && mounted) {
        _wasRecordingOnBackground = false;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Recording interrupted')),
        );
      }
    }
  }

  Future<void> _initCamera() async {
    List<CameraDescription> cameras;
    try {
      cameras = await availableCameras();
    } catch (e) {
      debugPrint('availableCameras failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Camera unavailable — check permissions')),
        );
        Navigator.pop(context);
      }
      return;
    }
    if (cameras.isEmpty) {
      debugPrint('No cameras available');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No camera available on this device')),
        );
        Navigator.pop(context);
      }
      return;
    }

    final camera = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );

    _cameraController = CameraController(
      camera,
      ResolutionPreset.high,
      enableAudio: true,
    );

    try {
      await _cameraController!.initialize();
      if (mounted) setState(() => _isCameraInitialized = true);
    } catch (e) {
      debugPrint('Camera init failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Camera failed: $e')),
        );
        Navigator.pop(context);
      }
    }
  }

  Future<void> _capturePhoto() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) return;
    if (_isRecording) return;

    try {
      final xFile = await _cameraController!.takePicture();

      // Copy camera file to app storage (camera temp files may be cleaned)
      final dir = await getApplicationDocumentsDirectory();
      final rawDir = Directory(p.join(dir.path, 'raw'));
      await rawDir.create(recursive: true);
      final ext = p.extension(xFile.path);
      final destPath = p.join(rawDir.path, '${DateTime.now().millisecondsSinceEpoch}$ext');
      await File(xFile.path).copy(destPath);

      final exercise = ExerciseCapture.create(
        position: widget.session.exercises.length,
        rawFilePath: PathResolver.toRelative(destPath),
        mediaType: MediaType.photo,
        sessionId: widget.session.id,
      );

      await widget.storage.saveExercise(exercise);
      if (mounted) Navigator.pop(context, exercise);
    } catch (e) {
      debugPrint('Photo capture failed: $e');
    }
  }

  Future<void> _startVideoRecording() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) return;
    if (_isRecording) return;

    try {
      await _cameraController!.startVideoRecording();
      setState(() {
        _isRecording = true;
        _recordingSeconds = 0;
        _recordingProgress = 0.0;
      });

      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        _recordingSeconds++;
        setState(() {
          _recordingProgress = _recordingSeconds / _maxRecordingSeconds;
        });
        if (_recordingSeconds >= _maxRecordingSeconds) {
          _stopVideoRecording();
        }
      });
    } catch (e) {
      debugPrint('Video recording start failed: $e');
    }
  }

  Future<void> _stopVideoRecording() async {
    if (_cameraController == null ||
        !_cameraController!.value.isInitialized ||
        !_isRecording) {
      setState(() {
        _isRecording = false;
        _recordingProgress = 0.0;
      });
      return;
    }
    _recordingTimer?.cancel();

    try {
      final xFile = await _cameraController!.stopVideoRecording();

      setState(() {
        _isRecording = false;
        _recordingProgress = 0.0;
        _recordingSeconds = 0;
      });

      // Copy camera file to app storage (camera temp files may be cleaned)
      final dir = await getApplicationDocumentsDirectory();
      final rawDir = Directory(p.join(dir.path, 'raw'));
      await rawDir.create(recursive: true);
      final ext = p.extension(xFile.path);
      final destPath = p.join(rawDir.path, '${DateTime.now().millisecondsSinceEpoch}$ext');
      await File(xFile.path).copy(destPath);

      final exercise = ExerciseCapture.create(
        position: widget.session.exercises.length,
        rawFilePath: PathResolver.toRelative(destPath),
        mediaType: MediaType.video,
        sessionId: widget.session.id,
      );

      await widget.storage.saveExercise(exercise);
      if (mounted) Navigator.pop(context, exercise);
    } catch (e) {
      debugPrint('Video recording stop failed: $e');
      setState(() {
        _isRecording = false;
        _recordingProgress = 0.0;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Recording failed — please try again')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            // Top bar with back button
            Container(
              color: Colors.black,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                  ),
                  const Expanded(
                    child: Text(
                      'Capture Exercise',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(width: 48), // Balance the back button
                ],
              ),
            ),

            // Camera preview
            Expanded(child: _buildCameraPreview()),

            // Capture controls
            Container(
              color: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(width: 80),
                  GestureDetector(
                    onTap: _capturePhoto,
                    onLongPressStart: (_) => _startVideoRecording(),
                    onLongPressEnd: (_) => _stopVideoRecording(),
                    child: _buildCaptureButton(),
                  ),
                  const SizedBox(width: 80),
                ],
              ),
            ),

            // Hint text
            Container(
              color: Colors.black,
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                _isRecording
                    ? 'Release to stop recording'
                    : 'Tap for photo · Hold for video',
                style: const TextStyle(color: Colors.white38, fontSize: 13),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCameraPreview() {
    if (!_isCameraInitialized || _cameraController == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Colors.white38),
            SizedBox(height: 16),
            Text('Starting camera...', style: TextStyle(color: Colors.white38)),
          ],
        ),
      );
    }

    return ClipRect(
      child: OverflowBox(
        alignment: Alignment.center,
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: _cameraController!.value.previewSize?.height ?? 0,
            height: _cameraController!.value.previewSize?.width ?? 0,
            child: CameraPreview(_cameraController!),
          ),
        ),
      ),
    );
  }

  Widget _buildCaptureButton() {
    final ringColor = _recordingSeconds >= _amberThresholdSeconds
        ? Colors.amber
        : Colors.red;

    return SizedBox(
      width: 80,
      height: 80,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (_isRecording)
            SizedBox(
              width: 80,
              height: 80,
              child: CircularProgressIndicator(
                value: _recordingProgress,
                strokeWidth: 4,
                color: ringColor,
                backgroundColor: Colors.white24,
              ),
            ),
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 3),
            ),
          ),
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: _isRecording ? 28 : 60,
            height: _isRecording ? 28 : 60,
            decoration: BoxDecoration(
              color: _isRecording ? Colors.red : Colors.white,
              borderRadius: BorderRadius.circular(_isRecording ? 6 : 30),
            ),
          ),
        ],
      ),
    );
  }
}

