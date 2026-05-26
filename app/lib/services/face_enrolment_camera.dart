import 'dart:async';

import 'package:flutter/services.dart';

/// Dart wrapper around the native `FaceEnrolmentCameraChannel`
/// (`app/ios/Runner/FaceEnrolmentCameraChannel.swift`).
///
/// Owns the lifecycle handshake for the native AVCaptureSession that
/// powers real-time face tracking on the enrolment screen.
///
/// Pose source (Phase 2, 2026-05-26): pose is computed by
/// `VNDetectFaceLandmarksRequest` (revision 3) on the streamed
/// CMSampleBuffer at ~10 Hz. AVCaptureMetadataOutput is retained on
/// the native side only for cheap face-presence + bounding-box update
/// used by `captureFrameAndEmbed`; it no longer emits pose. Pitch is
/// available again (the metadata-output path didn't expose it; Vision
/// does), so the prompt walker can include "lift your chin" prompts.
///
/// Surface:
///   - [poseStream] — broadcast stream of live face pose events at
///     ~10 Hz. Subscribe BEFORE [start]ing; the native EventChannel
///     is one-shot per onListen.
///   - [start] — boot the session for the given direction.
///   - [stop] — tear down.
///   - [captureFrameAndEmbed] — pull the most-recent frame from the
///     native ring buffer, write it as JPG, run MobileFaceNet,
///     return the 2048-byte embedding + frame path.
///
/// Pose units: yaw / pitch / roll are emitted in DEGREES already
/// (Vision returns radians; the native side converts before emitting).
///
/// Pose perspective: the native channel emits yaw + pitch + roll in
/// USER-PERSPECTIVE. Positive yaw = user turned their head to THEIR
/// right; positive pitch = user lifted their chin; positive roll =
/// user tilted toward THEIR right shoulder. This matches the chirality
/// of [kPromptSequence] in `face_enrolment_service.dart`. The native
/// side handles the front-camera mirror inversion before emitting (yaw
/// + roll only — pitch isn't affected by horizontal mirroring) so the
/// Dart side never needs to know which physical camera produced the
/// event.
class FaceEnrolmentCameraChannel {
  static const MethodChannel _methods =
      MethodChannel('homefit/face-enrolment-camera');
  static const EventChannel _poseEvents =
      EventChannel('homefit/face-enrolment-pose-stream');

  FaceEnrolmentCameraChannel._();
  static final FaceEnrolmentCameraChannel instance =
      FaceEnrolmentCameraChannel._();

  Stream<FaceEnrolmentPoseEvent>? _poseStream;

  /// Live pose stream. Lazily binds to the native EventChannel on first
  /// subscribe. Each event represents the LARGEST face detected by the
  /// metadata output (bystander-resilient). No event is emitted on
  /// frames where no face is visible — subscribers should treat a
  /// quiet period as "no face".
  Stream<FaceEnrolmentPoseEvent> get poseStream {
    _poseStream ??= _poseEvents
        .receiveBroadcastStream()
        .map<FaceEnrolmentPoseEvent>(FaceEnrolmentPoseEvent._fromNative);
    return _poseStream!;
  }

  /// Start the native AVCaptureSession on the requested direction.
  /// Returns native session info on success; throws [PlatformException]
  /// on failure (NO_CAMERA / SESSION_SETUP_FAILED). Idempotent if the
  /// requested direction matches the running session.
  Future<Map<String, Object?>> start({required bool useFrontCamera}) async {
    final dynamic raw = await _methods.invokeMethod<Map<dynamic, dynamic>>(
      'start',
      <String, Object?>{
        'position': useFrontCamera ? 'front' : 'back',
      },
    );
    if (raw == null) return const <String, Object?>{};
    return Map<String, Object?>.from(raw as Map);
  }

  /// Stop the native session + clear native ring buffers. Idempotent.
  Future<void> stop() async {
    try {
      await _methods.invokeMethod<Map<dynamic, dynamic>>('stop');
    } on PlatformException {
      // Stop is best-effort — caller is usually disposing.
    }
  }

  /// Pull the most-recent frame from the native ring buffer, write it
  /// as a JPG to [outPath], crop the face out using the latest metadata
  /// bounds, run MobileFaceNet, and return the result.
  ///
  /// Throws [PlatformException] when:
  ///   - NO_FRAME      → session not running / ring empty
  ///   - NO_FACE       → no face detected since the last clear
  ///   - EMBEDDING_FAILED → MobileFaceNet error (see message)
  ///   - WRITE_FAILED  → JPG write to outPath failed
  Future<FaceEnrolmentEmbeddingResult> captureFrameAndEmbed({
    required String outPath,
  }) async {
    final dynamic raw =
        await _methods.invokeMethod<Map<dynamic, dynamic>>(
      'captureFrameAndEmbed',
      <String, Object?>{'outPath': outPath},
    );
    if (raw == null) {
      throw PlatformException(
        code: 'NO_RESPONSE',
        message: 'captureFrameAndEmbed returned null',
      );
    }
    final map = Map<String, Object?>.from(raw as Map);
    final embedding = map['embedding'];
    final Uint8List bytes = embedding is Uint8List
        ? embedding
        : Uint8List.fromList((embedding as List<int>));
    return FaceEnrolmentEmbeddingResult(
      embedding: bytes,
      framePath: map['framePath'] as String? ?? outPath,
      faceBoundsX: (map['faceBoundsX'] as num?)?.toDouble() ?? 0.0,
      faceBoundsY: (map['faceBoundsY'] as num?)?.toDouble() ?? 0.0,
      faceBoundsWidth: (map['faceBoundsWidth'] as num?)?.toDouble() ?? 0.0,
      faceBoundsHeight: (map['faceBoundsHeight'] as num?)?.toDouble() ?? 0.0,
    );
  }
}

/// One pose event emitted on [FaceEnrolmentCameraChannel.poseStream].
class FaceEnrolmentPoseEvent {
  /// The ISP-assigned face tracking id. Stable across consecutive
  /// frames for the same physical face — useful for filtering out
  /// flicker but the service doesn't rely on it (the largest-face
  /// pick is already bystander-resilient).
  final int faceID;

  /// Yaw in DEGREES, USER-PERSPECTIVE. Positive = user turned their
  /// head to THEIR right (head rotates around the vertical axis).
  /// Negative = user's left. Null when Vision couldn't compute yaw on
  /// this frame — callers MUST skip the frame rather than default to
  /// zero (per `feedback_no_silent_fallbacks`). The native side
  /// already nil-skips emission when yaw OR pitch came back nil, so
  /// in practice this is non-null whenever an event arrives — the
  /// nullability is retained for defensive decoding.
  final double? yawDeg;

  /// Pitch in DEGREES, USER-PERSPECTIVE. Positive = user lifted their
  /// chin (head tilts back). Negative = user dropped their chin. Null
  /// for the same reason as [yawDeg] — defensive nil-skip rather than
  /// silently default to zero. Pitch was unavailable on the prior
  /// AVCaptureMetadataOutput pose source; the Vision-on-CMSampleBuffer
  /// pipeline emits it. Phase 2 restored "lift your chin" prompts in
  /// [kPromptSequence] now that pitch is reliable.
  final double? pitchDeg;

  /// Roll in DEGREES, USER-PERSPECTIVE. Positive = head tilted toward
  /// the subject's RIGHT shoulder. Null when Vision didn't compute
  /// roll on this frame. The prompt walker does not currently gate on
  /// roll; this field is documented for completeness + diagnostics.
  final double? rollDeg;

  /// Face bounding box in NORMALIZED preview coordinates (top-left
  /// origin, 0..1 across both axes). Use this for the optional
  /// "face is in frame" check; the service primarily acts on yaw.
  final double boundsX;
  final double boundsY;
  final double boundsWidth;
  final double boundsHeight;

  /// Millisecond wall-clock timestamp the event was emitted (Dart
  /// side equivalent of `DateTime.now().millisecondsSinceEpoch`).
  /// Useful for staleness checks if listeners debounce.
  final int timestampMs;

  const FaceEnrolmentPoseEvent({
    required this.faceID,
    required this.yawDeg,
    required this.pitchDeg,
    required this.rollDeg,
    required this.boundsX,
    required this.boundsY,
    required this.boundsWidth,
    required this.boundsHeight,
    required this.timestampMs,
  });

  factory FaceEnrolmentPoseEvent._fromNative(dynamic raw) {
    final m = Map<String, Object?>.from(raw as Map);
    return FaceEnrolmentPoseEvent(
      faceID: (m['faceID'] as num?)?.toInt() ?? -1,
      yawDeg: (m['yawDeg'] as num?)?.toDouble(),
      pitchDeg: (m['pitchDeg'] as num?)?.toDouble(),
      rollDeg: (m['rollDeg'] as num?)?.toDouble(),
      boundsX: (m['boundsX'] as num?)?.toDouble() ?? 0.0,
      boundsY: (m['boundsY'] as num?)?.toDouble() ?? 0.0,
      boundsWidth: (m['boundsWidth'] as num?)?.toDouble() ?? 0.0,
      boundsHeight: (m['boundsHeight'] as num?)?.toDouble() ?? 0.0,
      timestampMs: (m['timestampMs'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Result of a successful [FaceEnrolmentCameraChannel.captureFrameAndEmbed]
/// call. 2048-byte embedding (= 512 LE FP32 floats, per
/// `kFaceEmbeddingBytes`) + the saved JPG path + the bounds used to
/// crop the face. Bounds are passed through so callers can render the
/// captured crop in the post-sweep grid (matches the existing
/// FaceEnrolmentSlot.sourceFramePath contract).
class FaceEnrolmentEmbeddingResult {
  final Uint8List embedding;
  final String framePath;
  final double faceBoundsX;
  final double faceBoundsY;
  final double faceBoundsWidth;
  final double faceBoundsHeight;

  const FaceEnrolmentEmbeddingResult({
    required this.embedding,
    required this.framePath,
    required this.faceBoundsX,
    required this.faceBoundsY,
    required this.faceBoundsWidth,
    required this.faceBoundsHeight,
  });
}
