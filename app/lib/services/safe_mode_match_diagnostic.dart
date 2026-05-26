import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Default solo-floor passed to the native diagnostic when the caller
/// doesn't supply one. Kept in sync with `kSafeModeV2SoloFloor` in
/// `conversion_service.dart` — held as a local constant rather than an
/// import to keep this file free of a circular dependency (the
/// conversion service imports US to wire the log-toggle hook).
///
/// If `kSafeModeV2SoloFloor` ever changes in `conversion_service.dart`
/// this default must move in lock-step. The unit test
/// `safe_mode_match_diagnostic_test.dart` asserts the value to catch
/// drift.
const double kSafeModeMatchDiagnosticDefaultThreshold = 0.10;

/// Per-face record returned from a [SafeModeMatchDiagnostic] probe.
///
/// `cosSim` is the MAX cosine similarity this face scored against ALL
/// of the supplied subject embeddings. The hybrid pick-highest rule
/// uses this value (alongside the per-face order) to decide subject
/// vs bystander.
///
/// `normalizedBounds` are Vision bottom-left-origin normalised
/// coordinates (matches the per-face logging in
/// `applySafeModeV2ToPhoto`); `cropPixelRect` is the inflated +
/// top-left-origin rectangle that was handed to MobileFaceNet.
class SafeModeDiagFace {
  const SafeModeDiagFace({
    required this.cosSim,
    required this.normalizedBounds,
    required this.cropPixelRect,
  });

  /// MAX cosSim across every entry in `subjectEmbeddings`. -2.0 if no
  /// references were supplied; -1.0 if the per-face embed itself
  /// failed (rare — see native log for the underlying error).
  final double cosSim;

  /// Vision-output bounds, normalised, bottom-left origin. Useful for
  /// overlay rendering and for confirming Vision saw a face where the
  /// user expected one.
  final Rect normalizedBounds;

  /// Pad-inflated bounds in upright pixel space (top-left origin) that
  /// were used as the MobileFaceNet input crop. Bit-identical to what
  /// `applySafeModeV2ToPhoto` produces for the same `srcPath`.
  final Rect cropPixelRect;
}

/// Result of [SafeModeMatchDiagnostic.run].
///
/// Mirrors the per-face cosSim list + the hybrid pick-highest
/// decision the production matcher would have made on the same
/// inputs. See `safeModeMatchDiagnostic` in `VideoConverterChannel.swift`
/// for the load-bearing parity guarantee.
class SafeModeDiagResult {
  const SafeModeDiagResult({
    required this.faces,
    required this.subjectIndex,
    required this.bestSim,
    required this.branch,
    required this.referenceCount,
  });

  /// One record per Vision-detected face in the probe input.
  final List<SafeModeDiagFace> faces;

  /// Index into [faces] of the face the matcher picked as the subject,
  /// or `null` when the hybrid pick-highest rule landed in no-subject
  /// mode (zero faces, no references, or solo-floor rejection).
  final int? subjectIndex;

  /// Highest cosSim observed across all detected faces. -2.0 when the
  /// face list is empty.
  final double bestSim;

  /// Which decision branch the picker fell into. Stable string values
  /// per `MobileFaceNetEmbedder.PickBranch.rawValue` —
  /// `no-faces` / `no-references` / `solo-floor` / `multi-relative`.
  final String branch;

  /// Number of enrolled embeddings the probe scored against. Useful
  /// for log clarity (e.g. "1 face vs 6 references → cosSim 0.07").
  final int referenceCount;

  /// True when the picker considered the subject identified — i.e.
  /// the production matcher would have kept this face sharp.
  bool get subjectIdentified => subjectIndex != null;
}

/// Wave M41 (2026-05-26) — non-destructive Safe Mode v2 match probe.
///
/// Calls the native `safeModeMatchDiagnostic` method-channel which
/// runs the SAME face-detect + embed + cosSim pipeline as
/// `applySafeModeV2ToPhoto` against [srcPath] and [subjectEmbeddings]
/// but does NOT paint a coral mask, segment, or write any output
/// file. The numbers returned here are bit-for-bit identical to what
/// the production matcher would compute on the same inputs.
///
/// Purpose: lets the Diagnostics screen (and any other future
/// "verify embedding" surface) ask the matcher "what would you do
/// with this photo?" so a self-recognition regression can be triaged
/// WITHOUT having to take a real Safe Mode capture inside a
/// premises polygon.
///
/// Per `feedback_no_silent_fallbacks` failure modes are loud:
///   - missing file / decode failure → [PlatformException].
///   - empty / wrong-byte-length [subjectEmbeddings] → [PlatformException].
///   - Vision face-detect throws → [PlatformException].
/// Faces-but-no-subject is a legitimate outcome and surfaces as a
/// successful [SafeModeDiagResult] with `subjectIndex == null`.
class SafeModeMatchDiagnostic {
  SafeModeMatchDiagnostic._();

  static const MethodChannel _channel =
      MethodChannel('com.raidme.video_converter');

  /// Run the probe. [srcPath] must point to a JPG/HEIC on disk;
  /// [subjectEmbeddings] is the bound client's enrolment slot bundle
  /// (1-8 entries of [kFaceEmbeddingBytes] bytes each); [threshold]
  /// defaults to [kSafeModeV2SoloFloor] (matches the production
  /// solo-floor used by `applySafeModeV2ToPhoto`).
  ///
  /// Throws [PlatformException] on validation / Vision / decode
  /// failure — caller surfaces the message to the diagnostic UI.
  /// Native call is 30s-bounded to mirror the production matcher
  /// timeout.
  static Future<SafeModeDiagResult> run({
    required String srcPath,
    required List<Uint8List> subjectEmbeddings,
    double threshold = kSafeModeMatchDiagnosticDefaultThreshold,
  }) async {
    final raw = await _channel
        .invokeMethod<Map<dynamic, dynamic>>(
          'safeModeMatchDiagnostic',
          <String, dynamic>{
            'srcPath': srcPath,
            'subjectEmbeddings': subjectEmbeddings,
            'threshold': threshold,
          },
        )
        .timeout(const Duration(seconds: 30));
    if (raw == null) {
      throw PlatformException(
        code: 'SAFE_MODE_DIAG_NULL',
        message: 'safeModeMatchDiagnostic returned null',
      );
    }
    return _parseResult(raw);
  }

  @visibleForTesting
  static SafeModeDiagResult parseResultForTesting(
    Map<dynamic, dynamic> raw,
  ) => _parseResult(raw);

  static SafeModeDiagResult _parseResult(Map<dynamic, dynamic> raw) {
    final rawFaces = raw['faces'] as List? ?? const [];
    final faces = <SafeModeDiagFace>[];
    for (final f in rawFaces) {
      if (f is! Map) continue;
      faces.add(SafeModeDiagFace(
        cosSim: (f['cosSim'] as num?)?.toDouble() ?? -2.0,
        normalizedBounds: Rect.fromLTWH(
          (f['boundsX'] as num?)?.toDouble() ?? 0.0,
          (f['boundsY'] as num?)?.toDouble() ?? 0.0,
          (f['boundsWidth'] as num?)?.toDouble() ?? 0.0,
          (f['boundsHeight'] as num?)?.toDouble() ?? 0.0,
        ),
        cropPixelRect: Rect.fromLTWH(
          (f['cropX'] as num?)?.toDouble() ?? 0.0,
          (f['cropY'] as num?)?.toDouble() ?? 0.0,
          (f['cropWidth'] as num?)?.toDouble() ?? 0.0,
          (f['cropHeight'] as num?)?.toDouble() ?? 0.0,
        ),
      ));
    }
    return SafeModeDiagResult(
      faces: faces,
      subjectIndex: raw['subjectIndex'] as int?,
      bestSim: (raw['bestSim'] as num?)?.toDouble() ?? -2.0,
      branch: raw['branch'] as String? ?? 'unknown',
      referenceCount: (raw['referenceCount'] as int?) ?? 0,
    );
  }
}
