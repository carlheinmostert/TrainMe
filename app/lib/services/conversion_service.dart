import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../config.dart';
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

  /// Stream controller for individual conversion updates.
  final _updateController = StreamController<ExerciseCapture>.broadcast();

  /// Fires each time an exercise's conversion status changes.
  Stream<ExerciseCapture> get onConversionUpdate => _updateController.stream;

  ConversionService({required LocalStorageService storage})
      : _storage = storage;

  /// Queue a capture for line drawing conversion.
  void queueConversion(ExerciseCapture exercise) {
    _queue.add(exercise);
    _processQueue();
  }

  /// On app restart, reload any unfinished conversions and re-queue them.
  Future<void> restoreQueue() async {
    final unconverted = await _storage.getUnconvertedExercises();
    for (final exercise in unconverted) {
      _queue.add(exercise);
    }
    if (_queue.isNotEmpty) {
      _processQueue();
    }
  }

  /// The processing loop. Runs until the queue is drained.
  Future<void> _processQueue() async {
    if (_processing) return;
    _processing = true;

    while (_queue.isNotEmpty) {
      final exercise = _queue.removeAt(0);

      final converting = exercise.copyWith(
        conversionStatus: ConversionStatus.converting,
      );
      await _storage.saveExercise(converting);
      _updateController.add(converting);
      notifyListeners();

      try {
        final convertedPath = await _convert(converting);

        final done = converting.copyWith(
          convertedFilePath: convertedPath,
          conversionStatus: ConversionStatus.done,
        );
        await _storage.saveExercise(done);
        _updateController.add(done);
        notifyListeners();
      } catch (e) {
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

    await Directory(p.dirname(convertedPath)).create(recursive: true);

    if (exercise.mediaType == MediaType.photo) {
      await _convertPhoto(exercise.rawFilePath, convertedPath);
    } else {
      await _convertVideo(exercise.rawFilePath, convertedPath);
    }

    return convertedPath;
  }

  /// Convert a single photo to a line drawing using OpenCV.
  Future<void> _convertPhoto(String inputPath, String outputPath) async {
    final img = cv.imread(inputPath, flags: cv.IMREAD_COLOR);
    if (img.isEmpty) {
      throw Exception('Could not read image: $inputPath');
    }

    try {
      final result = _frameToLineDrawing(img);

      final ext = p.extension(outputPath).toLowerCase();
      if (ext == '.jpg' || ext == '.jpeg') {
        cv.imwrite(outputPath, result,
            params: cv.VecI32.fromList([cv.IMWRITE_JPEG_QUALITY, 95]));
      } else if (ext == '.png') {
        cv.imwrite(outputPath, result,
            params: cv.VecI32.fromList([cv.IMWRITE_PNG_COMPRESSION, 3]));
      } else {
        cv.imwrite(outputPath, result);
      }

      result.dispose();
    } finally {
      img.dispose();
    }
  }

  /// Convert a video frame-by-frame to line drawings.
  Future<void> _convertVideo(String inputPath, String outputPath) async {
    final cap = cv.VideoCapture.fromFile(inputPath);
    if (!cap.isOpened) {
      throw Exception('Could not open video: $inputPath');
    }

    try {
      final fps = cap.get(cv.CAP_PROP_FPS);
      final width = cap.get(cv.CAP_PROP_FRAME_WIDTH).toInt();
      final height = cap.get(cv.CAP_PROP_FRAME_HEIGHT).toInt();
      final totalFrames = cap.get(cv.CAP_PROP_FRAME_COUNT).toInt();

      // Choose codec string based on output extension
      final ext = p.extension(outputPath).toLowerCase();
      String codec;
      if (ext == '.mov') {
        codec = 'avc1';
      } else if (ext == '.avi') {
        codec = 'XVID';
      } else {
        codec = 'mp4v';
      }

      final writer = cv.VideoWriter.fromFile(
        outputPath,
        codec,
        fps,
        (width, height),
      );

      if (!writer.isOpened) {
        // Fallback to mp4v
        writer.open(outputPath, 'mp4v', fps, (width, height));
      }

      try {
        var frameCount = 0;
        while (true) {
          final (success, frame) = cap.read();
          if (!success || frame.isEmpty) {
            frame.dispose();
            break;
          }

          final lineFrame = _frameToLineDrawing(frame);
          writer.write(lineFrame);

          lineFrame.dispose();
          frame.dispose();
          frameCount++;

          if (frameCount % 100 == 0) {
            debugPrint('  Video conversion: frame $frameCount/$totalFrames');
          }
        }

        debugPrint('  Video conversion complete: $frameCount frames');
      } finally {
        writer.release();
      }
    } finally {
      cap.release();
    }
  }

  /// Convert a single BGR frame to a line drawing.
  ///
  /// Algorithm (ported from line-drawing-convert.skill):
  ///
  /// 1. Convert to grayscale
  /// 2. Pencil sketch via divide: invert -> blur -> divide original by inverse
  /// 3. Adaptive thresholding for crisp structural lines
  /// 4. Combine: take darkest (most line-like) of both results
  /// 5. Contrast boost: push light grays to white, keep dark lines
  /// 6. Convert back to BGR for output
  cv.Mat _frameToLineDrawing(cv.Mat frame) {
    final blurKernel = AppConfig.blurKernel;
    final thresholdBlock = AppConfig.thresholdBlock;
    final contrastLow = AppConfig.contrastLow;

    // Step 1: Convert to grayscale
    final gray = cv.cvtColor(frame, cv.COLOR_BGR2GRAY);

    // Step 2: Pencil sketch via divide
    // Create a white mat (255) for inversion: inv = 255 - gray
    final white = cv.Mat.ones(gray.rows, gray.cols, cv.MatType.CV_8UC1)
        .multiplyU8(255);
    final inv = cv.subtract(white, gray);

    // Blur the inverted image
    final blur = cv.gaussianBlur(inv, (blurKernel, blurKernel), 0);

    // Divisor: 255 - blur
    final invBlur = cv.subtract(white, blur);

    // Divide: sketch = gray / (255 - blur) * 256
    final sketch = cv.divide(gray, invBlur, scale: 256.0);

    // Step 3: Adaptive threshold for crisp structural lines
    final blurredGray = cv.gaussianBlur(gray, (5, 5), 0);
    final adaptive = cv.adaptiveThreshold(
      blurredGray,
      255,
      cv.ADAPTIVE_THRESH_GAUSSIAN_C,
      cv.THRESH_BINARY,
      thresholdBlock,
      2,
    );

    // Step 4: Combine — take the darkest pixel of both
    final combined = cv.min(sketch, adaptive);

    // Step 5: Contrast boost using convertTo(alpha, beta)
    // Formula: output = clip(input * alpha + beta, 0, 255)
    // We want: output = clip((input - contrastLow) * scale, 0, 255)
    // Which is: alpha = scale, beta = -contrastLow * scale
    final scale = 255.0 / (255 - contrastLow).clamp(1, 255);
    final beta = -contrastLow.toDouble() * scale;
    final boosted = combined.convertTo(cv.MatType.CV_8UC1,
        alpha: scale, beta: beta);

    // Step 6: Convert to BGR for output
    final result = cv.cvtColor(boosted, cv.COLOR_GRAY2BGR);

    // Dispose all intermediate matrices
    gray.dispose();
    white.dispose();
    inv.dispose();
    blur.dispose();
    invBlur.dispose();
    sketch.dispose();
    blurredGray.dispose();
    adaptive.dispose();
    combined.dispose();
    boosted.dispose();

    return result;
  }

  /// Number of items currently waiting in the queue.
  int get queueLength => _queue.length + (_processing ? 1 : 0);

  /// Whether the service is currently processing conversions.
  bool get isProcessing => _processing;

  @override
  void dispose() {
    _updateController.close();
    super.dispose();
  }
}
