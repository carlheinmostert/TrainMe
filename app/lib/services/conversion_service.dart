import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../models/exercise_capture.dart';
import 'local_storage_service.dart';

/// Background line drawing conversion service.
///
/// Architecture: Layer 2 of the three decoupled async layers.
/// Capture writes a raw file to disk and queues it here. This service
/// processes items sequentially in the background, never blocking the UI.
/// The converted file writes to disk alongside the raw original.
///
/// Listeners (e.g. the session strip UI) are notified via [onConversionUpdate]
/// whenever an exercise's status changes, so thumbnails can crossfade from
/// raw to line-drawing.
///
/// On app restart, call [restoreQueue] to re-queue any captures that were
/// mid-conversion or still pending when the app was killed.
class ConversionService extends ChangeNotifier {
  final LocalStorageService _storage;

  /// The processing queue. Items are processed FIFO.
  final List<ExerciseCapture> _queue = [];

  /// Whether the processor loop is currently running.
  bool _processing = false;

  /// Stream controller for individual conversion updates. Widgets can listen
  /// to this for fine-grained status changes per exercise.
  final _updateController = StreamController<ExerciseCapture>.broadcast();

  /// Fires each time an exercise's conversion status changes.
  Stream<ExerciseCapture> get onConversionUpdate => _updateController.stream;

  ConversionService({required LocalStorageService storage})
      : _storage = storage;

  /// Queue a capture for line drawing conversion.
  ///
  /// Call this immediately after a capture is saved to disk. The method
  /// returns instantly — actual processing happens in the background.
  void queueConversion(ExerciseCapture exercise) {
    _queue.add(exercise);
    _processQueue();
  }

  /// On app restart, reload any unfinished conversions from the database
  /// and re-queue them. Captures that were mid-conversion are reset to
  /// pending (the partial output is discarded).
  Future<void> restoreQueue() async {
    final unconverted = await _storage.getUnconvertedExercises();
    for (final exercise in unconverted) {
      _queue.add(exercise);
    }
    if (_queue.isNotEmpty) {
      _processQueue();
    }
  }

  /// The processing loop. Runs until the queue is drained, then stops.
  /// Re-enters automatically when new items are queued.
  Future<void> _processQueue() async {
    if (_processing) return; // Already running — new items will be picked up.
    _processing = true;

    while (_queue.isNotEmpty) {
      final exercise = _queue.removeAt(0);

      // Mark as converting
      final converting = exercise.copyWith(
        conversionStatus: ConversionStatus.converting,
      );
      await _storage.saveExercise(converting);
      _updateController.add(converting);
      notifyListeners();

      try {
        final convertedPath = await _convert(converting);

        // Mark as done
        final done = converting.copyWith(
          convertedFilePath: convertedPath,
          conversionStatus: ConversionStatus.done,
        );
        await _storage.saveExercise(done);
        _updateController.add(done);
        notifyListeners();
      } catch (e) {
        // Mark as failed — the bio can retry or re-capture
        final failed = converting.copyWith(
          conversionStatus: ConversionStatus.failed,
        );
        await _storage.saveExercise(failed);
        _updateController.add(failed);
        notifyListeners();
        debugPrint('Conversion failed for ${exercise.id}: $e');
      }
    }

    _processing = false;
  }

  /// Convert a single capture. Dispatches to photo or video handler.
  Future<String> _convert(ExerciseCapture exercise) async {
    final dir = await getApplicationDocumentsDirectory();
    final ext = p.extension(exercise.rawFilePath);
    final convertedPath = p.join(
      dir.path,
      'converted',
      '${exercise.id}_line$ext',
    );

    // Ensure output directory exists
    await Directory(p.dirname(convertedPath)).create(recursive: true);

    if (exercise.mediaType == MediaType.photo) {
      await _convertPhoto(exercise.rawFilePath, convertedPath);
    } else {
      await _convertVideo(exercise.rawFilePath, convertedPath);
    }

    return convertedPath;
  }

  /// Convert a single photo to a line drawing.
  Future<void> _convertPhoto(String inputPath, String outputPath) async {
    final inputFile = File(inputPath);
    final bytes = await inputFile.readAsBytes();

    final converted = _convertFrame(bytes);

    final outputFile = File(outputPath);
    await outputFile.writeAsBytes(converted);
  }

  /// Convert a video frame-by-frame to line drawings.
  ///
  /// TODO: Implement real frame extraction via ffmpeg_kit_flutter.
  /// For now, this copies the raw video as a stub so the rest of the
  /// flow works end-to-end.
  Future<void> _convertVideo(String inputPath, String outputPath) async {
    // TODO_OPENCV: Real implementation would:
    // 1. Extract frames using ffmpeg_kit_flutter
    // 2. Convert each frame via _convertFrame()
    // 3. Re-encode frames into a video
    //
    // Stub: copy raw video as "converted" version
    final inputFile = File(inputPath);
    await inputFile.copy(outputPath);
  }

  /// Convert a single image frame to a line drawing.
  ///
  /// TODO_OPENCV: Replace this stub with real opencv_dart integration.
  /// The algorithm (from the validated Python prototype):
  ///   1. Convert to grayscale
  ///   2. Invert the grayscale image
  ///   3. Apply Gaussian blur (kernel_size=31)
  ///   4. Divide grayscale by inverted-blurred (pencil sketch divide)
  ///   5. Apply adaptive threshold (block_size=9)
  ///   6. Adjust contrast (clip below 80 to white)
  ///
  /// For now, returns the input bytes unchanged so the capture-to-display
  /// flow works end-to-end without opencv_dart being wired up.
  Uint8List _convertFrame(Uint8List inputBytes) {
    // TODO_OPENCV: Port line drawing algorithm from line-drawing-convert.skill
    //
    // import 'package:opencv_dart/opencv_dart.dart' as cv;
    //
    // final mat = cv.imdecode(inputBytes, cv.IMREAD_GRAYSCALE);
    // final inverted = cv.bitwise_not(mat);
    // final blurred = cv.gaussianBlur(inverted, (31, 31), 0);
    // final sketch = cv.divide(mat, cv.bitwise_not(blurred), scale: 256.0);
    // final thresh = cv.adaptiveThreshold(
    //   sketch, 255,
    //   cv.ADAPTIVE_THRESH_GAUSSIAN_C,
    //   cv.THRESH_BINARY,
    //   9, 2,
    // );
    // return cv.imencode('.jpg', thresh);
    //
    // For now, pass through unchanged:
    return inputBytes;
  }

  /// Number of items currently waiting in the queue (including any in-progress).
  int get queueLength => _queue.length + (_processing ? 1 : 0);

  /// Whether the service is currently processing conversions.
  bool get isProcessing => _processing;

  @override
  void dispose() {
    _updateController.close();
    super.dispose();
  }
}
