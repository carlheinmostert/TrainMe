import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:video_thumbnail/video_thumbnail.dart' as vt;
import '../config.dart';
import '../models/exercise_capture.dart';
import 'local_storage_service.dart';
import 'path_resolver.dart';

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

  // ---------------------------------------------------------------------------
  // Singleton — lives for the entire app lifetime. Never disposed.
  // ---------------------------------------------------------------------------

  static ConversionService? _instance;

  /// Access the singleton instance. Must call [initialize] first.
  static ConversionService get instance {
    assert(_instance != null,
        'ConversionService.initialize() must be called before accessing instance');
    return _instance!;
  }

  /// Create and store the singleton. Call once from main().
  static ConversionService initialize(LocalStorageService storage) {
    _instance = ConversionService._(storage: storage);
    return _instance!;
  }

  /// Native iOS platform channel for video conversion.
  /// Uses AVAssetReader/Writer for H.264/265 I/O and Accelerate for
  /// pixel processing -- bypasses OpenCV's codec limitations on iOS.
  static const _videoChannel = MethodChannel('com.raidme.video_converter');

  /// Simple native frame extraction channel (AVAssetImageGenerator).
  static const _thumbChannel = MethodChannel('com.raidme.native_thumb');

  /// The processing queue. Items are processed FIFO.
  final List<ExerciseCapture> _queue = [];

  /// Whether the processor loop is currently running.
  bool _processing = false;

  /// Stream controller for individual conversion updates.
  final _updateController = StreamController<ExerciseCapture>.broadcast();

  /// Fires each time an exercise's conversion status changes.
  Stream<ExerciseCapture> get onConversionUpdate => _updateController.stream;

  ConversionService._({required LocalStorageService storage})
      : _storage = storage {
    // Listen for progress updates from the native video converter.
    _videoChannel.setMethodCallHandler(_handleNativeCallback);
  }

  /// Handle callbacks from the native platform channel (e.g. progress).
  Future<dynamic> _handleNativeCallback(MethodCall call) async {
    if (call.method == 'onProgress') {
      final args = call.arguments as Map?;
      if (args != null) {
        debugPrint(
            'Native video conversion progress: '
            '${args["framesProcessed"]}/${args["totalFrames"]} frames');
      }
    }
  }

  /// Queue a capture for line drawing conversion.
  /// Rest periods are skipped — they have no media to convert.
  void queueConversion(ExerciseCapture exercise) {
    if (exercise.isRest) return;
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
      if (!_updateController.isClosed) {
        _updateController.add(converting);
      }
      notifyListeners();

      try {
        final convertedPath = await _convert(converting);

        // Re-read from the database to pick up intermediate updates
        // (e.g. thumbnailPath set during video thumbnail extraction inside
        // _convert). Without this, the copyWith below would use
        // `converting` which still has thumbnailPath: null, overwriting
        // the thumbnail that was saved to the DB mid-conversion.
        final freshRows = await _storage.db.query(
          'exercises',
          where: 'id = ?',
          whereArgs: [exercise.id],
        );
        final base = freshRows.isNotEmpty
            ? ExerciseCapture.fromMap(freshRows.first)
            : converting;

        var done = base.copyWith(
          convertedFilePath: PathResolver.toRelative(convertedPath),
          conversionStatus: ConversionStatus.done,
        );

        // Replace the raw-video thumbnail with a frame from the CONVERTED
        // line-drawing video so the UI shows the line-art style everywhere.
        if (exercise.mediaType == MediaType.video) {
          try {
            final dir = await getApplicationDocumentsDirectory();
            final thumbPath =
                p.join(dir.path, 'thumbnails', '${exercise.id}_thumb.jpg');
            await _thumbChannel.invokeMethod<String>('extractFrame', {
              'inputPath': PathResolver.resolve(done.convertedFilePath!),
              'outputPath': thumbPath,
              'timeMs': 0,
            });
            done = done.copyWith(thumbnailPath: PathResolver.toRelative(thumbPath));
          } catch (e) {
            debugPrint('Post-conversion thumbnail update failed: $e');
            // Non-fatal — keep the raw thumbnail
          }

          // Probe the raw video duration via AVURLAsset so the "one rep" in
          // the duration estimate reflects the actual clip length instead of
          // the hardcoded AppConfig.secondsPerRep constant. Non-fatal — if the
          // probe fails we leave videoDurationMs null and fall back.
          try {
            final rawPath = PathResolver.resolve(exercise.rawFilePath);
            final ms = await _videoChannel.invokeMethod<int>(
              'getVideoDuration',
              {'inputPath': rawPath},
            );
            if (ms != null && ms > 0) {
              done = done.copyWith(videoDurationMs: ms);
            }
          } catch (e) {
            debugPrint('Video duration probe failed for ${exercise.id}: $e');
            // Non-fatal — leave videoDurationMs unset, estimator falls back
            // to AppConfig.secondsPerRep.
          }
        }

        await _storage.saveExercise(done);
        if (!_updateController.isClosed) {
          _updateController.add(done);
        }
        notifyListeners();

        // Fire-and-forget raw archive — compresses the raw video to a 720p
        // H.264 copy in {Documents}/archive/ so we can re-run better
        // line-drawing filters against the original footage later. A failure
        // here must not disturb the main conversion flow.
        unawaited(_archiveRawVideo(done));
      } catch (e, stack) {
        // Write error to a log file for debugging (readable from simulator filesystem)
        try {
          final logDir = await getApplicationDocumentsDirectory();
          final logFile = File(p.join(logDir.path, 'conversion_error.log'));
          await logFile.writeAsString(
            '${DateTime.now()}\nExercise: ${exercise.id}\n'
            'Raw file: ${exercise.rawFilePath}\n'
            'Error: $e\n\nStack:\n$stack\n\n',
            mode: FileMode.append,
          );
        } catch (_) {}

        // Re-read from the database to preserve thumbnailPath.
        final freshRows = await _storage.db.query(
          'exercises',
          where: 'id = ?',
          whereArgs: [exercise.id],
        );
        final base = freshRows.isNotEmpty
            ? ExerciseCapture.fromMap(freshRows.first)
            : converting;

        final failed = base.copyWith(
          conversionStatus: ConversionStatus.failed,
        );
        await _storage.saveExercise(failed);
        if (!_updateController.isClosed) {
          _updateController.add(failed);
        }
        notifyListeners();
        debugPrint('Conversion failed for ${exercise.id}: $e');
      }
    }

    _processing = false;
  }

  /// Convert a single capture. Dispatches to photo or video handler.
  /// For videos, also extracts a thumbnail from the first frame before
  /// starting the full conversion.
  Future<String> _convert(ExerciseCapture exercise) async {
    final dir = await getApplicationDocumentsDirectory();
    final ext = p.extension(exercise.rawFilePath);
    final convertedDir = p.join(dir.path, 'converted');
    await Directory(convertedDir).create(recursive: true);

    if (exercise.mediaType == MediaType.video) {
      // Extract a thumbnail immediately so the UI has something to show.
      try {
        final thumbPath = await _extractVideoThumbnail(
            exercise.absoluteRawFilePath, exercise.id, dir.path);
        if (thumbPath != null) {
          final withThumb = exercise.copyWith(thumbnailPath: PathResolver.toRelative(thumbPath));
          await _storage.saveExercise(withThumb);
          if (!_updateController.isClosed) {
            _updateController.add(withThumb);
          }
          notifyListeners();
        }
      } catch (e) {
        debugPrint('Thumbnail extraction failed for ${exercise.id}: $e');
        // Non-fatal — the UI will fall back to the placeholder.
      }

      // Try full frame-by-frame video conversion via OpenCV first.
      // On iOS, OpenCV's VideoCapture often can't decode H.264/H.265
      // because the codec backend wasn't compiled in. In that case, fall
      // back to extracting a key frame via video_thumbnail and converting
      // that single frame to a line drawing still image.
      final videoOutputPath = p.join(convertedDir, '${exercise.id}_line$ext');
      try {
        await _convertVideo(exercise.absoluteRawFilePath, videoOutputPath);
        return videoOutputPath;
      } catch (e, stack) {
        debugPrint(
            'Full video conversion failed for ${exercise.id}: $e — '
            'falling back to key-frame extraction');
        try {
          final logDir = await getApplicationDocumentsDirectory();
          final logFile = File(p.join(logDir.path, 'conversion_error.log'));
          await logFile.writeAsString(
            '${DateTime.now()} [_convertVideo failed]\n$e\n$stack\n\n',
            mode: FileMode.append,
          );
        } catch (_) {}
      }

      // Fallback: extract a key frame and convert to a still line drawing.
      final stillOutputPath =
          p.join(convertedDir, '${exercise.id}_line.jpg');
      await _convertVideoViaFrameExtraction(
          exercise.absoluteRawFilePath, stillOutputPath);
      return stillOutputPath;
    } else {
      final convertedPath =
          p.join(convertedDir, '${exercise.id}_line$ext');
      await _convertPhoto(exercise.absoluteRawFilePath, convertedPath);
      return convertedPath;
    }
  }

  /// Extract a video frame and save it as a JPEG thumbnail.
  /// Returns the thumbnail path, or null if extraction fails.
  ///
  /// Tries three approaches in order:
  /// 1. Native iOS platform channel (AVAssetImageGenerator)
  /// 2. OpenCV VideoCapture (works on Android, may fail on iOS)
  /// 3. video_thumbnail package (cross-platform fallback)
  Future<String?> _extractVideoThumbnail(
      String videoPath, String exerciseId, String baseDir) async {
    final thumbDir = Directory(p.join(baseDir, 'thumbnails'));
    await thumbDir.create(recursive: true);
    final thumbPath = p.join(thumbDir.path, '${exerciseId}_thumb.jpg');

    // Attempt 0: Simple native frame extraction (most reliable on iOS).
    try {
      final result = await _thumbChannel.invokeMethod<String>(
        'extractFrame',
        {
          'inputPath': videoPath,
          'outputPath': thumbPath,
          'timeMs': 0,
        },
      );
      if (result != null && await File(thumbPath).exists()) {
        debugPrint('Native thumb channel succeeded: $thumbPath');
        return thumbPath;
      }
    } catch (e) {
      debugPrint('Native thumb channel failed: $e');
      try {
        final logDir = await getApplicationDocumentsDirectory();
        final logFile = File(p.join(logDir.path, 'conversion_error.log'));
        await logFile.writeAsString(
          '${DateTime.now()} [native_thumb extractFrame]\n$e\n\n',
          mode: FileMode.append,
        );
      } catch (_) {}
    }

    // Attempt 1: Full native video converter channel.
    try {
      final result = await _videoChannel.invokeMethod<Map>(
        'extractThumbnail',
        {
          'inputPath': videoPath,
          'outputPath': thumbPath,
          'timeMs': 0,
        },
      );
      if (result != null && result['success'] == true) {
        debugPrint('Native thumbnail extraction succeeded');
        return thumbPath;
      }
    } on PlatformException catch (e) {
      debugPrint('Native thumbnail extraction failed: ${e.message}');
    } on MissingPluginException {
      debugPrint('Video converter channel not registered');
    }

    // Attempt 2: OpenCV VideoCapture (works on Android, may fail on iOS).
    try {
      final cap = cv.VideoCapture.fromFile(videoPath);
      if (cap.isOpened) {
        try {
          final (success, frame) = cap.read();
          if (success && !frame.isEmpty) {
            cv.imwrite(thumbPath, frame,
                params: cv.VecI32.fromList([cv.IMWRITE_JPEG_QUALITY, 85]));
            frame.dispose();
            return thumbPath;
          }
          frame.dispose();
        } finally {
          cap.release();
        }
      } else {
        cap.release();
      }
    } catch (e) {
      debugPrint('OpenCV VideoCapture unavailable: $e');
    }

    // Attempt 3: video_thumbnail package (uses AVAssetImageGenerator on iOS).
    debugPrint('OpenCV VideoCapture failed for thumbnail -- '
        'falling back to video_thumbnail package');
    for (final videoUri in [videoPath, 'file://$videoPath']) {
      try {
        final Uint8List? bytes = await vt.VideoThumbnail.thumbnailData(
          video: videoUri,
          imageFormat: vt.ImageFormat.JPEG,
          maxWidth: 512,
          quality: 85,
        );
        if (bytes != null && bytes.isNotEmpty) {
          await File(thumbPath).writeAsBytes(bytes);
          return thumbPath;
        }
      } catch (e) {
        debugPrint('video_thumbnail thumbnail failed with "$videoUri": $e');
      }
    }
    return null;
  }

  /// Convert a single photo to a line drawing using OpenCV.
  ///
  /// Runs on a background isolate so the 400-800ms OpenCV work on 12MP
  /// photos doesn't block the UI thread. The isolate entry handles the
  /// full imread → process → imwrite cycle with only primitive types
  /// crossing the isolate boundary (opencv_dart Mat handles wrap FFI
  /// pointers that don't survive isolate hops).
  Future<void> _convertPhoto(String inputPath, String outputPath) async {
    await compute<_PhotoConvertArgs, void>(
      _convertPhotoIsolate,
      _PhotoConvertArgs(
        inputPath: inputPath,
        outputPath: outputPath,
        blurKernel: AppConfig.blurKernel,
        thresholdBlock: AppConfig.thresholdBlock,
        contrastLow: AppConfig.contrastLow,
      ),
    );
  }

  /// Convert a video to a line drawing.
  ///
  /// Tries the native iOS platform channel first (AVAssetReader/Writer +
  /// Accelerate). This handles H.264/265 codecs that OpenCV can't decode on
  /// iOS. If the native channel is unavailable (e.g. on Android) or fails,
  /// falls back to OpenCV's VideoCapture/VideoWriter.
  Future<void> _convertVideo(String inputPath, String outputPath) async {
    // --- Attempt 1: Native iOS platform channel ---
    try {
      final result = await _videoChannel.invokeMethod<Map>(
        'convertVideo',
        {
          'inputPath': inputPath,
          'outputPath': outputPath,
          'blurKernel': AppConfig.blurKernel,
          'thresholdBlock': AppConfig.thresholdBlock,
          'contrastLow': AppConfig.contrastLow,
        },
      );
      if (result != null && result['success'] == true) {
        debugPrint(
            'Native video conversion complete: '
            '${result["framesProcessed"]} frames -> $outputPath');
        return;
      }
    } on PlatformException catch (e) {
      debugPrint(
          'Native video conversion failed: ${e.code} - ${e.message} -- '
          'falling back to OpenCV VideoCapture');
    } on MissingPluginException {
      debugPrint(
          'Native video channel not available (not iOS?) -- '
          'falling back to OpenCV VideoCapture');
    }

    // --- Attempt 2: OpenCV VideoCapture/VideoWriter ---
    await _convertVideoViaOpenCV(inputPath, outputPath);
  }

  /// Convert a video frame-by-frame using OpenCV's VideoCapture/VideoWriter.
  ///
  /// Works on platforms where OpenCV has codec support (typically Android).
  /// On iOS, H.264/265 decoding usually fails because the codec backend
  /// wasn't compiled in -- use the native platform channel instead.
  Future<void> _convertVideoViaOpenCV(
      String inputPath, String outputPath) async {
    final cap = cv.VideoCapture.fromFile(inputPath);
    if (!cap.isOpened) {
      debugPrint('VideoCapture failed to open file: $inputPath');
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

  /// Fallback video conversion: extract a key frame from the middle of the
  /// video using the video_thumbnail package (which uses platform-native APIs
  /// like AVAssetImageGenerator on iOS), then convert that single frame to a
  /// line drawing still image.
  ///
  /// This produces a .jpg output instead of a video. The bio gets a clean
  /// line drawing representation of the exercise. Full video-to-video
  /// conversion can be added later when the codec issue is resolved.
  Future<void> _convertVideoViaFrameExtraction(
      String inputPath, String outputPath) async {
    // Extract a frame from roughly the middle of the video.
    // video_thumbnail's timeMs defaults to 0 (first frame); we request the
    // midpoint for a more representative pose.
    //
    // Note: we don't have the duration without a video player, but
    // video_thumbnail with a non-zero timeMs will clamp to the video's
    // actual length, so requesting a large value just gives us the last
    // frame. We'll try 5 seconds in (a reasonable midpoint for exercises
    // capped at 30 seconds).
    final int targetTimeMs = (AppConfig.maxVideoSeconds * 1000) ~/ 2;

    // Try native channel first (most reliable on iOS).
    final tempDir = await getTemporaryDirectory();
    final tempFramePath = p.join(tempDir.path, 'frame_extract_temp.jpg');

    try {
      final result = await _thumbChannel.invokeMethod<String>(
        'extractFrame',
        {
          'inputPath': inputPath,
          'outputPath': tempFramePath,
          'timeMs': targetTimeMs,
        },
      );
      if (result != null && await File(tempFramePath).exists()) {
        // Native extraction succeeded — process with OpenCV below.
      } else {
        throw Exception('Native frame extraction returned null');
      }
    } catch (nativeErr) {
      debugPrint('Native frame extraction failed: $nativeErr');
      try {
        final logDir = await getApplicationDocumentsDirectory();
        final logFile = File(p.join(logDir.path, 'conversion_error.log'));
        await logFile.writeAsString(
          '${DateTime.now()} [native_thumb frame extract]\n$nativeErr\n\n',
          mode: FileMode.append,
        );
      } catch (_) {}

      // Fallback to video_thumbnail package.
      Uint8List? bytes;
      for (final videoUri in [inputPath, 'file://$inputPath']) {
        try {
          bytes = await vt.VideoThumbnail.thumbnailData(
            video: videoUri,
            imageFormat: vt.ImageFormat.JPEG,
            maxWidth: 1920,
            quality: 95,
            timeMs: targetTimeMs,
          );
          if (bytes != null && bytes.isNotEmpty) break;
        } catch (e) {
          debugPrint('video_thumbnail failed with uri "$videoUri": $e');
        }
      }

      if (bytes == null || bytes.isEmpty) {
        throw Exception(
            'All frame extraction methods failed for: $inputPath');
      }

      await File(tempFramePath).writeAsBytes(bytes);
    }

    try {
      // Load and convert via the standard line drawing pipeline.
      final img = cv.imread(tempFramePath, flags: cv.IMREAD_COLOR);
      if (img.isEmpty) {
        throw Exception(
            'OpenCV could not read extracted frame: $tempFramePath');
      }

      try {
        final result = _frameToLineDrawing(img);
        cv.imwrite(outputPath, result,
            params: cv.VecI32.fromList([cv.IMWRITE_JPEG_QUALITY, 95]));
        result.dispose();
      } finally {
        img.dispose();
      }

      debugPrint('Video frame extraction fallback complete: $outputPath');
    } finally {
      // Clean up temp file.
      try {
        await File(tempFramePath).delete();
      } catch (_) {}
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

    // Guard against divide-by-zero on saturated (over-exposed) frames.
    // Gym lighting can produce frames where blur is near 255, making
    // invBlur near 0 — which crashes cv.divide. Clamp to minimum 1 by
    // element-wise max against a ones-filled mat of matching shape.
    final onesMat = cv.Mat.ones(invBlur.rows, invBlur.cols, cv.MatType.CV_8UC1);
    final invBlurSafe = cv.max(invBlur, onesMat);

    // Divide: sketch = gray / (255 - blur) * 256
    final sketch = cv.divide(gray, invBlurSafe, scale: 256.0);

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
    onesMat.dispose();
    invBlurSafe.dispose();
    sketch.dispose();
    blurredGray.dispose();
    adaptive.dispose();
    combined.dispose();
    boosted.dispose();

    return result;
  }

  /// Compress the raw video to a 720p H.264 archive copy and record the
  /// location on the exercise row. Fire-and-forget from [_processQueue] —
  /// any failure is swallowed and logged so it never disturbs the bio's
  /// main flow. No-op for non-video media.
  ///
  /// The raw file in `{Documents}/raw/` is intentionally NOT deleted here —
  /// that's a separate cleanup pass we can add in a follow-up once the
  /// archive pipeline has been exercised in the wild. Safer to over-retain.
  Future<void> _archiveRawVideo(ExerciseCapture done) async {
    // TODO: upload archived raw to private Supabase bucket once auth is in.
    if (done.mediaType != MediaType.video) return;

    try {
      final rawPath = done.absoluteRawFilePath;
      if (rawPath.isEmpty) return;
      if (!await File(rawPath).exists()) {
        debugPrint('Archive skipped — raw file missing for ${done.id}: $rawPath');
        return;
      }

      final docsDir = await getApplicationDocumentsDirectory();
      final archiveDir = p.join(docsDir.path, 'archive');
      await Directory(archiveDir).create(recursive: true);
      final archivePath = p.join(archiveDir, '${done.id}.mp4');

      final result = await _videoChannel.invokeMethod<Map>(
        'compressVideo',
        {
          'inputPath': rawPath,
          'outputPath': archivePath,
        },
      );

      if (result == null || result['success'] != true) {
        debugPrint('Archive compression returned unexpected result for ${done.id}: $result');
        return;
      }

      // TODO: delete the raw file from {Documents}/raw/ once we're confident
      // the archive is sufficient. Leaving the raw in place for now is safer
      // — a failed archive would otherwise lose the only copy of the clip.
      final updated = done.copyWith(
        archiveFilePath: PathResolver.toRelative(archivePath),
        archivedAt: DateTime.now(),
      );
      await _storage.saveExercise(updated);
      if (!_updateController.isClosed) {
        _updateController.add(updated);
      }
      debugPrint(
          'Archived raw video for ${done.id}: $archivePath '
          '(${result["sizeBytes"]} bytes)');
    } catch (e, stack) {
      debugPrint('Raw archive failed for ${done.id}: $e');
      try {
        final logDir = await getApplicationDocumentsDirectory();
        final logFile = File(p.join(logDir.path, 'conversion_error.log'));
        await logFile.writeAsString(
          '${DateTime.now()} [_archiveRawVideo]\n'
          'Exercise: ${done.id}\n'
          'Error: $e\n$stack\n\n',
          mode: FileMode.append,
        );
      } catch (_) {}
    }
  }

  /// Number of items currently waiting in the queue.
  int get queueLength => _queue.length + (_processing ? 1 : 0);

  /// Whether the service is currently processing conversions.
  bool get isProcessing => _processing;

  // Note: dispose() intentionally not overridden. This service is a singleton
  // that lives for the entire app lifetime. Closing the StreamController would
  // cause "Bad state: Cannot add new events after calling close" if a screen
  // that holds a reference triggers disposal.
}

/// Arguments for the photo-convert isolate entry. Must be a const-constructible
/// value type so it survives isolate boundary serialisation cleanly.
class _PhotoConvertArgs {
  final String inputPath;
  final String outputPath;
  final int blurKernel;
  final int thresholdBlock;
  final int contrastLow;

  const _PhotoConvertArgs({
    required this.inputPath,
    required this.outputPath,
    required this.blurKernel,
    required this.thresholdBlock,
    required this.contrastLow,
  });
}

/// Top-level isolate entry for photo line drawing conversion.
///
/// Must be a top-level function (not a closure or method) so `compute()`
/// can invoke it on a background isolate. All OpenCV Mat allocations stay
/// inside this isolate — only file paths cross the boundary.
void _convertPhotoIsolate(_PhotoConvertArgs args) {
  final img = cv.imread(args.inputPath, flags: cv.IMREAD_COLOR);
  if (img.isEmpty) {
    throw Exception('Could not read image: ${args.inputPath}');
  }

  try {
    final result = _frameToLineDrawingSync(
      img,
      blurKernel: args.blurKernel,
      thresholdBlock: args.thresholdBlock,
      contrastLow: args.contrastLow,
    );

    final ext = p.extension(args.outputPath).toLowerCase();
    if (ext == '.jpg' || ext == '.jpeg') {
      cv.imwrite(args.outputPath, result,
          params: cv.VecI32.fromList([cv.IMWRITE_JPEG_QUALITY, 95]));
    } else if (ext == '.png') {
      cv.imwrite(args.outputPath, result,
          params: cv.VecI32.fromList([cv.IMWRITE_PNG_COMPRESSION, 3]));
    } else {
      cv.imwrite(args.outputPath, result);
    }

    result.dispose();
  } finally {
    img.dispose();
  }
}

/// Standalone (top-level) version of the line drawing algorithm for use
/// inside an isolate. Mirrors [ConversionService._frameToLineDrawing] but
/// does not depend on the service instance or AppConfig singletons.
cv.Mat _frameToLineDrawingSync(
  cv.Mat frame, {
  required int blurKernel,
  required int thresholdBlock,
  required int contrastLow,
}) {
  // Step 1: Convert to grayscale
  final gray = cv.cvtColor(frame, cv.COLOR_BGR2GRAY);

  // Step 2: Pencil sketch via divide
  final white = cv.Mat.ones(gray.rows, gray.cols, cv.MatType.CV_8UC1)
      .multiplyU8(255);
  final inv = cv.subtract(white, gray);
  final blur = cv.gaussianBlur(inv, (blurKernel, blurKernel), 0);
  final invBlur = cv.subtract(white, blur);
  // Clamp against divide-by-zero on saturated frames via element-wise max.
  final onesMat = cv.Mat.ones(invBlur.rows, invBlur.cols, cv.MatType.CV_8UC1);
  final invBlurSafe = cv.max(invBlur, onesMat);
  final sketch = cv.divide(gray, invBlurSafe, scale: 256.0);

  // Step 3: Adaptive threshold
  final blurredGray = cv.gaussianBlur(gray, (5, 5), 0);
  final adaptive = cv.adaptiveThreshold(
    blurredGray,
    255,
    cv.ADAPTIVE_THRESH_GAUSSIAN_C,
    cv.THRESH_BINARY,
    thresholdBlock,
    2,
  );

  // Step 4: Combine
  final combined = cv.min(sketch, adaptive);

  // Step 5: Contrast boost
  final scale = 255.0 / (255 - contrastLow).clamp(1, 255);
  final beta = -contrastLow.toDouble() * scale;
  final boosted = combined.convertTo(cv.MatType.CV_8UC1,
      alpha: scale, beta: beta);

  // Step 6: Convert to BGR for output
  final result = cv.cvtColor(boosted, cv.COLOR_GRAY2BGR);

  gray.dispose();
  white.dispose();
  inv.dispose();
  blur.dispose();
  invBlur.dispose();
  onesMat.dispose();
  invBlurSafe.dispose();
  sketch.dispose();
  blurredGray.dispose();
  adaptive.dispose();
  combined.dispose();
  boosted.dispose();

  return result;
}
