import 'dart:io';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import '../models/exercise_capture.dart';
import '../models/session.dart';
import '../services/local_storage_service.dart';
import '../services/upload_service.dart';
import '../widgets/capture_thumbnail.dart';

/// Plan assembly screen — where the bio arranges, annotates, and sends.
///
/// Shows a vertical list of exercise cards that can be reordered via
/// long-press drag. Each card has annotation fields (reps, sets, hold,
/// notes). The "Send" button at the bottom triggers the upload flow.
class PlanEditorScreen extends StatefulWidget {
  final Session session;
  final LocalStorageService storage;

  const PlanEditorScreen({
    super.key,
    required this.session,
    required this.storage,
  });

  @override
  State<PlanEditorScreen> createState() => _PlanEditorScreenState();
}

class _PlanEditorScreenState extends State<PlanEditorScreen> {
  late Session _session;
  late UploadService _uploadService;
  final _clientNameController = TextEditingController();

  bool _isSending = false;
  int? _expandedIndex; // Which card is expanded for editing, if any

  @override
  void initState() {
    super.initState();
    _session = widget.session;
    _uploadService = UploadService(storage: widget.storage);
    _clientNameController.text = _session.clientName;
  }

  @override
  void dispose() {
    _clientNameController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Reorder
  // ---------------------------------------------------------------------------

  /// Handle drag-and-drop reorder of exercise cards.
  void _onReorder(int oldIndex, int newIndex) {
    setState(() {
      if (newIndex > oldIndex) newIndex -= 1;
      final exercises = List<ExerciseCapture>.from(_session.exercises);
      final item = exercises.removeAt(oldIndex);
      exercises.insert(newIndex, item);

      // Update position fields
      for (var i = 0; i < exercises.length; i++) {
        exercises[i] = exercises[i].copyWith(position: i);
      }

      _session = _session.copyWith(exercises: exercises);

      // Collapse any expanded card — positions have changed
      _expandedIndex = null;
    });

    // Persist new order
    _saveExerciseOrder();
  }

  Future<void> _saveExerciseOrder() async {
    for (final ex in _session.exercises) {
      await widget.storage.saveExercise(ex);
    }
  }

  // ---------------------------------------------------------------------------
  // Annotation
  // ---------------------------------------------------------------------------

  /// Update an exercise's metadata (reps, sets, hold, notes).
  void _updateExercise(int index, ExerciseCapture updated) {
    setState(() {
      final exercises = List<ExerciseCapture>.from(_session.exercises);
      exercises[index] = updated;
      _session = _session.copyWith(exercises: exercises);
    });
    widget.storage.saveExercise(updated);
  }

  /// Update the client name.
  void _updateClientName(String name) {
    _session = _session.copyWith(clientName: name);
    widget.storage.saveSession(_session);
  }

  // ---------------------------------------------------------------------------
  // Send flow
  // ---------------------------------------------------------------------------

  /// The Send flow:
  /// 1. Check all conversions are done (or wait for them)
  /// 2. Upload to Supabase
  /// 3. Generate shareable link
  /// 4. Open share sheet
  Future<void> _send() async {
    // Check conversions
    if (!_session.allConversionsComplete) {
      final pending = _session.pendingConversions;
      final proceed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Still converting'),
          content: Text(
            '$pending exercise(s) are still being converted to line drawings. '
            'Wait for them to finish?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Wait & Send'),
            ),
          ],
        ),
      );
      if (proceed != true) return;

      // TODO: Actually wait for conversions to complete before proceeding.
      // For now, send anyway with whatever is ready.
    }

    setState(() => _isSending = true);

    try {
      final url = await _uploadService.uploadPlan(_session);

      setState(() {
        _session = _session.copyWith(
          sentAt: DateTime.now(),
          planUrl: url,
        );
        _isSending = false;
      });

      if (!mounted) return;

      // Show success and offer share sheet
      final shouldShare = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('Plan sent!'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Your plan is ready to share.'),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  url,
                  style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Done'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.pop(context, true),
              icon: const Icon(Icons.share),
              label: const Text('Share via WhatsApp'),
            ),
          ],
        ),
      );

      if (shouldShare == true && mounted) {
        await Share.share(
          '${_session.displayTitle}\n\n'
          '${_session.exercises.length} exercises ready for you:\n'
          '$url',
        );
      }

      // Return to home
      if (mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    } catch (e) {
      setState(() => _isSending = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Send failed: $e'),
            action: SnackBarAction(label: 'Retry', onPressed: _send),
          ),
        );
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Preview
  // ---------------------------------------------------------------------------

  void _previewCapture(ExerciseCapture exercise) {
    showDialog(
      context: context,
      builder: (context) => Dialog.fullscreen(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.file(
              File(exercise.displayFilePath),
              fit: BoxFit.contain,
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

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text(
          'Edit Plan',
          style: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.5),
        ),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0,
      ),
      body: Column(
        children: [
          // Client name field
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: TextField(
              controller: _clientNameController,
              decoration: const InputDecoration(
                labelText: 'Client name',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.person_outline),
              ),
              textCapitalization: TextCapitalization.words,
              onChanged: _updateClientName,
            ),
          ),

          // Exercise card list (reorderable)
          Expanded(
            child: _session.exercises.isEmpty
                ? _buildEmptyState()
                : ReorderableListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
                    itemCount: _session.exercises.length,
                    onReorder: _onReorder,
                    proxyDecorator: (child, index, animation) {
                      return Material(
                        elevation: 4,
                        borderRadius: BorderRadius.circular(12),
                        child: child,
                      );
                    },
                    itemBuilder: (context, index) {
                      final exercise = _session.exercises[index];
                      return _ExerciseCard(
                        key: ValueKey(exercise.id),
                        exercise: exercise,
                        index: index,
                        isExpanded: _expandedIndex == index,
                        onTap: () {
                          setState(() {
                            _expandedIndex =
                                _expandedIndex == index ? null : index;
                          });
                        },
                        onUpdate: (updated) =>
                            _updateExercise(index, updated),
                        onPreview: () => _previewCapture(exercise),
                      );
                    },
                  ),
          ),
        ],
      ),

      // Send button
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            height: 56,
            child: FilledButton.icon(
              onPressed:
                  _isSending || _session.exercises.isEmpty ? null : _send,
              icon: _isSending
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.send),
              label: Text(
                _isSending ? 'Sending...' : 'Send Plan',
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.black87,
                foregroundColor: Colors.white,
                disabledBackgroundColor: Colors.grey.shade300,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.photo_library_outlined, size: 64, color: Colors.black26),
          SizedBox(height: 16),
          Text(
            'No exercises captured yet',
            style: TextStyle(fontSize: 16, color: Colors.black38),
          ),
          SizedBox(height: 4),
          Text(
            'Go back to capture some exercises',
            style: TextStyle(fontSize: 14, color: Colors.black26),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Exercise card — shows thumbnail, metadata, and annotation fields
// ---------------------------------------------------------------------------

class _ExerciseCard extends StatefulWidget {
  final ExerciseCapture exercise;
  final int index;
  final bool isExpanded;
  final VoidCallback onTap;
  final ValueChanged<ExerciseCapture> onUpdate;
  final VoidCallback onPreview;

  const _ExerciseCard({
    super.key,
    required this.exercise,
    required this.index,
    required this.isExpanded,
    required this.onTap,
    required this.onUpdate,
    required this.onPreview,
  });

  @override
  State<_ExerciseCard> createState() => _ExerciseCardState();
}

class _ExerciseCardState extends State<_ExerciseCard> {
  late TextEditingController _repsController;
  late TextEditingController _setsController;
  late TextEditingController _holdController;
  late TextEditingController _notesController;

  @override
  void initState() {
    super.initState();
    _repsController =
        TextEditingController(text: widget.exercise.reps?.toString() ?? '');
    _setsController =
        TextEditingController(text: widget.exercise.sets?.toString() ?? '');
    _holdController = TextEditingController(
        text: widget.exercise.holdSeconds?.toString() ?? '');
    _notesController =
        TextEditingController(text: widget.exercise.notes ?? '');
  }

  @override
  void dispose() {
    _repsController.dispose();
    _setsController.dispose();
    _holdController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  void _save() {
    widget.onUpdate(widget.exercise.copyWith(
      reps: int.tryParse(_repsController.text),
      sets: int.tryParse(_setsController.text),
      holdSeconds: int.tryParse(_holdController.text),
      notes: _notesController.text.isEmpty ? null : _notesController.text,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: Colors.grey.shade50,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Collapsed view: thumbnail + summary
              Row(
                children: [
                  // Thumbnail
                  GestureDetector(
                    onTap: widget.onPreview,
                    child: CaptureThumbnail(
                      exercise: widget.exercise,
                      size: 56,
                    ),
                  ),
                  const SizedBox(width: 12),

                  // Info
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Exercise ${widget.index + 1}',
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _buildSummary(),
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Media type badge
                  Icon(
                    widget.exercise.mediaType == MediaType.photo
                        ? Icons.photo_camera_outlined
                        : Icons.videocam_outlined,
                    size: 20,
                    color: Colors.grey.shade400,
                  ),

                  // Expand indicator
                  Icon(
                    widget.isExpanded
                        ? Icons.expand_less
                        : Icons.expand_more,
                    color: Colors.grey.shade400,
                  ),
                ],
              ),

              // Expanded view: annotation fields
              if (widget.isExpanded) ...[
                const SizedBox(height: 16),
                const Divider(height: 1),
                const SizedBox(height: 16),

                // Reps, Sets, Hold in a row
                Row(
                  children: [
                    Expanded(
                      child: _NumberField(
                        controller: _repsController,
                        label: 'Reps',
                        onChanged: (_) => _save(),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _NumberField(
                        controller: _setsController,
                        label: 'Sets',
                        onChanged: (_) => _save(),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _NumberField(
                        controller: _holdController,
                        label: 'Hold (s)',
                        onChanged: (_) => _save(),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 12),

                // Notes
                TextField(
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
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Build a one-line summary of the exercise metadata.
  String _buildSummary() {
    final parts = <String>[];
    if (widget.exercise.reps != null) {
      parts.add('${widget.exercise.reps} reps');
    }
    if (widget.exercise.sets != null) {
      parts.add('${widget.exercise.sets} sets');
    }
    if (widget.exercise.holdSeconds != null) {
      parts.add('${widget.exercise.holdSeconds}s hold');
    }
    if (widget.exercise.notes != null && widget.exercise.notes!.isNotEmpty) {
      parts.add(widget.exercise.notes!);
    }
    if (parts.isEmpty) {
      return widget.exercise.mediaType == MediaType.photo
          ? 'Photo'
          : 'Video';
    }
    return parts.join(' / ');
  }
}

// ---------------------------------------------------------------------------
// Small number input field
// ---------------------------------------------------------------------------

class _NumberField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final ValueChanged<String>? onChanged;

  const _NumberField({
    required this.controller,
    required this.label,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      keyboardType: TextInputType.number,
      textAlign: TextAlign.center,
      onChanged: onChanged,
    );
  }
}
