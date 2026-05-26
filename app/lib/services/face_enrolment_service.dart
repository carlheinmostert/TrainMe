import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../config.dart';
import 'api_client.dart';
import 'face_embedding_service.dart';
import 'face_enrolment_camera.dart';
import 'safe_mode.dart' show kSafeModeAlgorithmVersion;
import 'sync_service.dart';

/// Diagnostics gate for face-enrolment debug prints (2026-05-24).
/// Enabled in debug + staging profile so Carl can follow the sweep
/// state machine in Console.app; stays off in prod release.
bool get _kDiagLogs => kDebugMode || AppConfig.env == 'staging';

/// Safe Mode v2 multi-reference face enrolment (2026-05-24, Wave-D).
///
/// State machine controller for the Face-ID-style rotating-head sweep.
/// Owns the camera frame buffer + sweep timing + cancel handling + the
/// native embedding pass + the persist step. UI ([FaceEnrolmentScreen])
/// subscribes to [notifyListeners] for state changes and [errorStream]
/// for inline toast surfacing.
///
/// Lifecycle:
///   1. UI mounts the screen and calls [startSweep] once the camera
///      preview is ready. Service writes its first frame to a temp dir
///      and starts ticking through the yaw + pitch phases.
///   2. Yaw phase (~6s @ 4Hz capture cadence) → pitch phase (~4s) →
///      embedding phase (native MobileFaceNet pass on the captured
///      bundle).
///   3. Native returns 3-8 slots ordered by pose. Service transitions
///      to [FaceEnrolmentState.confirming] with the slot bundle on
///      [pendingSlots].
///   4. UI shows confirm view; on Done it calls [commit] which writes
///      to local SQLite then Supabase, copies the frontal-pick frame
///      into the avatars/ directory + queues the cloud avatar upload,
///      then transitions to [FaceEnrolmentState.done].
///   5. UI listens for [done] and pops back to client detail.
///
/// Hard-fails (per `feedback_no_silent_fallbacks`):
///   - Camera isn't ready when [startSweep] runs → caller surfaces an
///     inline toast and pops back.
///   - Frame capture throws → captures continue; if all yaw frames
///     fail we still attempt embedding with whatever we got. Native
///     handles "not enough valid faces" via [FaceEnrolmentError.notEnoughAngles].
///   - Native call returns [FaceEnrolmentError] → state goes to
///     [FaceEnrolmentState.failed] with the message, UI shows toast,
///     auto-pops after 4 seconds.
///   - Cloud RPC fails → local SQLite write still succeeded (offline-
///     first); user lands back on client detail with the new avatar,
///     and pending_ops will flush the cloud write on next online drain.
///
/// Cancel semantics:
///   - During sweep: stop the periodic capture timer, clean the temp
///     directory, transition to [FaceEnrolmentState.cancelled]. UI pops.
///   - During embedding: the native call cannot be killed mid-flight
///     (MobileFaceNet doesn't support interrupt). We let it complete,
///     throw the result away, and transition to cancelled.
///   - During persisting: same as embedding — we let the local write
///     complete (cheap) and discard. Cloud may still receive the
///     write if it was already in flight; acceptable trade-off.
/// Editor mode resolved once at screen mount from the cached client's
/// `video_consent` flags. Drives which UI branches render and which
/// service paths run during commit.
///
/// Phase 1 (2026-05-25) — Safe Mode v2 enrolment polish.
/// Spec: `docs/specs/2026-05-25-safe-mode-v2-enrolment-polish.md`,
/// section 3 (Consent matrix) + 4f (Consent-aware UI behaviour).
///
/// | face-rec | avatar | mode             |
/// |----------|--------|------------------|
/// | ON       | ON     | [full]           |
/// | ON       | OFF    | [embeddingOnly]  |
/// | OFF      | ON     | [avatarOnly]     |
/// | OFF      | OFF    | [disabled]       |
///
/// Phase 1 wires the enum end-to-end (resolution, screen branching,
/// avatarOnly simple-shot capture path). Phase 2 will add the
/// post-sweep manual selection grid and pose gating that the [full]
/// branch hosts.
enum FaceEnrolmentMode {
  /// Both consents granted. Multi-reference sweep + (Phase 2)
  /// post-sweep manual avatar selection grid. Both artifacts
  /// (embeddings + avatar JPG) persist.
  full,

  /// Face-rec consent ON, avatar consent OFF. Multi-reference sweep
  /// runs; only the embeddings persist. No avatar JPG is written to
  /// the raw-archive bucket and no manual selection grid is shown on
  /// the confirm screen.
  embeddingOnly,

  /// Avatar consent ON, face-rec consent OFF. Simple-mode single-shot
  /// capture — viewfinder + single shutter button, no sweep, no
  /// embedding generation. The captured frame persists as the avatar
  /// JPG only. Resurrects the legacy single-photo avatar flow as a
  /// mode of the multi-reference editor.
  avatarOnly,

  /// Both consents OFF. The editor refuses to open; the entry point
  /// (avatar-tap intercept / "Set face" CTA) shows a SnackBar
  /// directing the practitioner to the consent sheet.
  disabled,
}

/// Resolve the editor mode from a cached client snapshot.
///
/// Pure function so test scaffolding can exercise all four
/// permutations without spinning up the service.
FaceEnrolmentMode resolveFaceEnrolmentMode({
  required bool faceRecognitionAllowed,
  required bool avatarAllowed,
}) {
  if (faceRecognitionAllowed && avatarAllowed) {
    return FaceEnrolmentMode.full;
  }
  if (faceRecognitionAllowed && !avatarAllowed) {
    return FaceEnrolmentMode.embeddingOnly;
  }
  if (!faceRecognitionAllowed && avatarAllowed) {
    return FaceEnrolmentMode.avatarOnly;
  }
  return FaceEnrolmentMode.disabled;
}

// ── Phase 2 — pose bucketing + quality scoring ────────────────────────────
//
// Spec: docs/specs/2026-05-25-safe-mode-v2-enrolment-polish.md sections
// 4b (real-time pose-gated capture) + 4c (per-embedding quality scoring).
// Mockup-approved geometry: docs/design/mockups/safe-mode-v2-enrolment-polish.html
// (6 pose buckets, NOT 8 — per Carl's signoff on open question 1).
//
// All math here is pure + unit-testable. The runtime service plugs the
// helpers into its sweep loop; UI binds to the bucket fill state to drive
// the guidance ring + hint copy.

/// Six discrete pose buckets the practitioner is guided through during
/// the sweep. Carl approved 6 over 8 at mockup signoff — covers the
/// meaningful angles without over-constraining the practitioner.
///
/// Bucket centres (yaw, pitch) in DEGREES — yaw negative = head turned
/// to camera-left (subject's right shoulder), positive = camera-right.
/// Pitch negative = chin down, positive = chin up.
///
/// `front` is the neutral straight-on bucket. The two front-* buckets
/// are 30 degrees off-axis (capturing the asymmetry typical of how
/// people sit naturally without holding a perfect pose). `left` /
/// `right` are full 60-degree profile angles. `slightUp` covers the
/// chin-up angle that catches Vision missing the jaw under typical
/// indoor lighting.
enum PoseBucket {
  front,
  frontLeft,
  frontRight,
  left,
  right,
  slightUp,
}

extension PoseBucketLabel on PoseBucket {
  /// Word-form label rendered in the manual-avatar-selection grid (per
  /// Carl's mockup decision: "front-left" over "front-left, 0 deg pitch"
  /// — the numeric pitch is noisy and not actionable).
  String get label {
    switch (this) {
      case PoseBucket.front:
        return 'front';
      case PoseBucket.frontLeft:
        return 'front-left';
      case PoseBucket.frontRight:
        return 'front-right';
      case PoseBucket.left:
        return 'left';
      case PoseBucket.right:
        return 'right';
      case PoseBucket.slightUp:
        return 'slight-up';
    }
  }

  /// Short uppercase label rendered around the guidance ring (per
  /// mockup: "FRONT", "F-LEFT", "UP" etc.).
  String get ringLabel {
    switch (this) {
      case PoseBucket.front:
        return 'FRONT';
      case PoseBucket.frontLeft:
        return 'F-LEFT';
      case PoseBucket.frontRight:
        return 'F-RIGHT';
      case PoseBucket.left:
        return 'LEFT';
      case PoseBucket.right:
        return 'RIGHT';
      case PoseBucket.slightUp:
        return 'UP';
    }
  }

  /// Bucket centre in degrees (yaw, pitch). Used as both the ideal
  /// target for the practitioner AND the reference point in the
  /// closest-unfilled-bucket hint computation.
  ({double yaw, double pitch}) get centerDeg {
    switch (this) {
      case PoseBucket.front:
        return (yaw: 0.0, pitch: 0.0);
      case PoseBucket.frontLeft:
        return (yaw: -30.0, pitch: 0.0);
      case PoseBucket.frontRight:
        return (yaw: 30.0, pitch: 0.0);
      case PoseBucket.left:
        return (yaw: -60.0, pitch: 0.0);
      case PoseBucket.right:
        return (yaw: 60.0, pitch: 0.0);
      case PoseBucket.slightUp:
        return (yaw: 0.0, pitch: 20.0);
    }
  }
}

/// Manhattan-sum pose distance in degrees. The pose-gating algorithm
/// uses this against a 25-degree threshold (spec section 4b + 6) to
/// decide whether a candidate frame's pose is "meaningfully different"
/// from every existing slot.
///
/// Pure function — no state, no side effects, trivially tested.
double poseDistance(
  ({double yaw, double pitch}) a,
  ({double yaw, double pitch}) b,
) {
  // Wrap-aware delta — AVMetadataFaceObject.yawAngle reports angles in
  // [0, 360) where "straight ahead" is ~0 (or wraps through 359). Naive
  // subtraction makes yaw=359 vs target=0 give delta=359 instead of 1.
  // Fix: take the smaller of |a-b| and (360-|a-b|) per axis. Targets in
  // kPromptSequence may be expressed in [-180, +180] (e.g. -30 for left);
  // wrap-aware math handles either input range correctly.
  double wrappedDelta(double x, double y) {
    final d = (x - y).abs();
    return d > 180.0 ? 360.0 - d : d;
  }
  return wrappedDelta(a.yaw, b.yaw) + wrappedDelta(a.pitch, b.pitch);
}

/// Pose-gating accept threshold (Manhattan-sum degrees). Below = reject.
/// Tunable during device QA per spec section 10 open question 4.
const double kPoseDistanceThresholdDeg = 25.0;

/// Quality-scoring accept threshold (composite 0-100). Below = reject.
/// Tunable per spec section 10 open question 2.
const double kQualityThreshold = 60.0;

/// Number of pose buckets in the guidance ring. Locked to 6 per Carl's
/// mockup signoff on open question 1.
const int kPoseBucketCount = 6;

/// Ordered sequence of explicit pose prompts.
///
/// Phase 2 (2026-05-26): restored the 6-prompt sweep with a final
/// "lift your chin" prompt that fills the `slightUp` bucket, now that
/// the Vision-on-CMSampleBuffer pose source emits pitch reliably (the
/// prior AVCaptureMetadataOutput source didn't expose pitch, forcing
/// yaw-only buckets). Sequence covers 5 distinct yaw angles + the
/// chin-up angle — strictly more variety than the M37 yaw-only fallback,
/// and aligns with MobileFaceNet's robustness to small pitch changes.
///
/// Order chosen so adjacent prompts require modest head movements
/// (front → right → left → up), keeping the sweep snappy without
/// forcing the practitioner to swing through extremes.
const List<PoseBucket> kPromptSequence = <PoseBucket>[
  PoseBucket.front,        // 1. Look straight ahead
  PoseBucket.frontRight,   // 2. Turn slightly to your right (~+30 deg yaw)
  PoseBucket.right,        // 3. Turn further to your right (~+60 deg yaw)
  PoseBucket.frontLeft,    // 4. Turn slightly to your left (~-30 deg yaw)
  PoseBucket.left,         // 5. Turn further to your left (~-60 deg yaw)
  PoseBucket.slightUp,     // 6. Lift your chin slightly (~+20 deg pitch)
];

/// Per-prompt instruction copy. Indexed by prompt position (0..5).
/// Kept as a static const list rather than localised strings — the
/// Self-trainer + per-client enrolment flow is English-only for MVP.
const List<String> kPromptInstructions = <String>[
  'Look straight ahead',
  'Turn slightly to your right',
  'Turn further to your right',
  'Turn slightly to your left',
  'Turn further to your left',
  'Lift your chin slightly',
];

/// Per-prompt arrow/direction icon hint. UI maps to a Material icon.
/// Values: 'straight', 'right', 'left', 'up', 'down', 'smile'. The
/// screen falls back to `straight` when an unknown value is supplied.
const List<String> kPromptDirections = <String>[
  'straight',
  'right',
  'right',
  'left',
  'left',
  'up',
];

/// Soft-hint copy surfaced after [kStallSoftHintAfter] elapses without
/// a capture on the current prompt. Indexed by prompt position.
const List<String> kPromptStallHints = <String>[
  'Hold steadier — look right at the lens',
  'Turn a little further to the right',
  'Turn further — about half-way to your shoulder',
  'Turn a little further to the left',
  'Turn further — about half-way to your shoulder',
  'Lift your chin a little more — keep eyes on the camera',
];

/// Hard minimum prompts that must be completed for a valid enrolment.
/// Below this we surface a Failed state with Try Again / Close CTAs.
/// 4-of-6 matches the spec ask — better than the prior 3-of-6 since
/// the prompts are explicit + sequential so a 4th miss reflects a
/// real environmental issue.
const int kMinPromptsForValidEnrolment = 4;

/// Soft-hint timer: when a prompt has been active for this long without
/// a successful capture, the UI surfaces a per-prompt stall hint.
const Duration kStallSoftHintAfter = Duration(seconds: 5);

/// Skip-pose timer: when a prompt has been active for this long, the
/// UI surfaces a "Skip this pose" button so the user can move on.
const Duration kStallSkipAfter = Duration(seconds: 15);

/// Pick the closest unfilled bucket to a given current pose. Drives
/// the hint text ("Turn slightly to your right") — implementation is
/// `argmin(poseDistance(current, bucket.center)) for bucket in unfilled`.
///
/// Returns null when every bucket is filled (sweep is complete).
PoseBucket? closestUnfilledBucket(
  ({double yaw, double pitch}) currentDeg,
  Set<PoseBucket> filled,
) {
  PoseBucket? best;
  double bestDist = double.infinity;
  for (final b in PoseBucket.values) {
    if (filled.contains(b)) continue;
    final d = poseDistance(currentDeg, b.centerDeg);
    if (d < bestDist) {
      bestDist = d;
      best = b;
    }
  }
  return best;
}

/// Snap a measured pose to its nearest bucket. Used by the sweep loop
/// to decide which bucket a passing-quality candidate fills.
///
/// Returns null when no bucket is within 35 degrees Manhattan sum
/// (loose guard so we never assign a wildly off-pose frame to a
/// bucket it doesn't really belong to — sweep ignores those frames).
PoseBucket? snapToBucket(({double yaw, double pitch}) poseDeg) {
  PoseBucket? best;
  double bestDist = double.infinity;
  for (final b in PoseBucket.values) {
    final d = poseDistance(poseDeg, b.centerDeg);
    if (d < bestDist) {
      bestDist = d;
      best = b;
    }
  }
  // Loose guard — 35 degrees is generous (kPoseDistanceThresholdDeg + 10).
  if (bestDist > 35.0) return null;
  return best;
}

/// Decide whether a candidate pose is "meaningfully different" from
/// every existing slot pose. Mirrors the spec's pose-gating rule
/// verbatim — accept iff Manhattan distance to ALL existing slots
/// is at or above [kPoseDistanceThresholdDeg].
///
/// Pure function — no state, no side effects. The runtime accept path
/// also requires the candidate pass the quality gate (see
/// [QualityScorer.score]); this only covers the pose half.
bool isPoseGatedAcceptable({
  required ({double yaw, double pitch}) candidateDeg,
  required List<({double yaw, double pitch})> existingDeg,
  double threshold = kPoseDistanceThresholdDeg,
}) {
  if (existingDeg.isEmpty) return true;
  for (final existing in existingDeg) {
    final d = poseDistance(candidateDeg, existing);
    if (d < threshold) return false;
  }
  return true;
}

/// Composite 0-100 quality score per the spec's weighted formula:
///
/// | Metric            | Weight |
/// | ----------------- | ------ |
/// | Vision confidence |   30   |
/// | Sharpness         |   25   |
/// | Lighting          |   20   |
/// | Pose uniqueness   |   15   |
/// | Embedding norm    |   10   |
///
/// All input components are normalised to [0, 1] before weighting.
/// The result is clamped to [0, 100]. Anything below
/// [kQualityThreshold] (default 60) is rejected at the runtime
/// accept site.
///
/// Implemented as a static helper class so the runtime call site +
/// the unit tests share one source of truth.
abstract final class QualityScorer {
  /// Weighted-sum scorer per the spec.
  static double score({
    required double visionConfidence,
    required double sharpness,
    required double lighting,
    required double poseUniqueness,
    required double embeddingNorm,
  }) {
    final vc = visionConfidence.clamp(0.0, 1.0);
    final sh = sharpness.clamp(0.0, 1.0);
    final li = lighting.clamp(0.0, 1.0);
    final pu = poseUniqueness.clamp(0.0, 1.0);
    final normPenalty = (embeddingNorm - 1.0).abs().clamp(0.0, 1.0);
    final normComponent = 1.0 - normPenalty;
    final composite = 30.0 * vc +
        25.0 * sh +
        20.0 * li +
        15.0 * pu +
        10.0 * normComponent;
    return composite.clamp(0.0, 100.0);
  }

  /// Normalised sharpness from the Laplacian variance of a grayscale
  /// face crop. Higher variance = more edge energy = sharper image.
  ///
  /// Baseline: empirically a tack-sharp iPhone selfie crop yields a
  /// variance around 400-1200 in 8-bit grayscale; a defocused crop
  /// drops below 60. We normalise via `clamp(variance / 800, 0, 1)`
  /// so the typical good-shot variance maps to roughly 0.5-1.0.
  ///
  /// Pure: takes a [img.Image] (grayscale or colour — we drop chroma
  /// internally) and returns [0, 1].
  static double sharpnessFromImage(img.Image source) {
    final gray = img.grayscale(source);
    return _normalisedLaplacianVariance(gray);
  }

  /// Normalised lighting score from contrast + dynamic range in the
  /// face region. Rewards well-lit shots with usable dynamic range
  /// (both shadow and highlight detail). Penalises crushed-black or
  /// blown-white frames typical of bad backlight.
  ///
  /// Formula: 60% contrast (standard deviation / 64) + 40% dynamic
  /// range ((max - min) / 255). Both terms clamped to [0, 1].
  static double lightingFromImage(img.Image source) {
    final gray = img.grayscale(source);
    final width = gray.width;
    final height = gray.height;
    if (width == 0 || height == 0) return 0.0;
    int minLum = 255;
    int maxLum = 0;
    double sum = 0.0;
    double sumSq = 0.0;
    int n = 0;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final px = gray.getPixel(x, y);
        final lum = px.r.toInt();
        if (lum < minLum) minLum = lum;
        if (lum > maxLum) maxLum = lum;
        sum += lum;
        sumSq += lum * lum;
        n++;
      }
    }
    if (n == 0) return 0.0;
    final mean = sum / n;
    final variance = (sumSq / n) - (mean * mean);
    final stdev = variance > 0 ? math.sqrt(variance) : 0.0;
    // Typical well-lit selfie: stdev ~50-70 in 8-bit grayscale.
    final contrastTerm = (stdev / 64.0).clamp(0.0, 1.0);
    final rangeTerm = ((maxLum - minLum) / 255.0).clamp(0.0, 1.0);
    return (0.6 * contrastTerm + 0.4 * rangeTerm).clamp(0.0, 1.0);
  }

  /// Pose-uniqueness score given a candidate pose and the existing
  /// slot poses. 1.0 = maximally far from every existing slot, 0.0 =
  /// effectively identical to one of them. Linear mapping of the
  /// minimum pose-distance over a 60-degree reference span.
  ///
  /// First slot in an empty set always scores 1.0 (no competition).
  static double poseUniquenessScore({
    required ({double yaw, double pitch}) candidateDeg,
    required List<({double yaw, double pitch})> existingDeg,
  }) {
    if (existingDeg.isEmpty) return 1.0;
    double minDist = double.infinity;
    for (final e in existingDeg) {
      final d = poseDistance(candidateDeg, e);
      if (d < minDist) minDist = d;
    }
    // 60 deg = a full pose bucket apart = pose-unique. Below that we
    // scale linearly down to 0 (identical pose).
    return (minDist / 60.0).clamp(0.0, 1.0);
  }

  /// L2 norm of a MobileFaceNet embedding. The model output is
  /// L2-normalised so a healthy embedding's norm should be ~1.0;
  /// deviations indicate a degenerate / saturated forward pass that
  /// produces a less reliable template.
  ///
  /// Embeddings ship as 2048-byte buffers = 512 LE FP32 floats.
  /// Returns the Euclidean norm or `double.nan` on a malformed input.
  static double embeddingL2Norm(Uint8List bytes) {
    if (bytes.length % 4 != 0 || bytes.isEmpty) return double.nan;
    final view = ByteData.sublistView(bytes);
    double sumSq = 0.0;
    for (var i = 0; i < bytes.length; i += 4) {
      final f = view.getFloat32(i, Endian.little);
      sumSq += f * f;
    }
    return math.sqrt(sumSq);
  }

  // ── Private helpers ──────────────────────────────────────────────────────

  static double _normalisedLaplacianVariance(img.Image gray) {
    final width = gray.width;
    final height = gray.height;
    if (width < 3 || height < 3) return 0.0;
    // 3x3 Laplacian kernel:  0 -1  0 / -1  4 -1 /  0 -1  0
    // Compute response and accumulate variance.
    double sum = 0.0;
    double sumSq = 0.0;
    int n = 0;
    for (var y = 1; y < height - 1; y++) {
      for (var x = 1; x < width - 1; x++) {
        final c = gray.getPixel(x, y).r.toInt();
        final t = gray.getPixel(x, y - 1).r.toInt();
        final b = gray.getPixel(x, y + 1).r.toInt();
        final l = gray.getPixel(x - 1, y).r.toInt();
        final r = gray.getPixel(x + 1, y).r.toInt();
        final lap = (4 * c - t - b - l - r).toDouble();
        sum += lap;
        sumSq += lap * lap;
        n++;
      }
    }
    if (n == 0) return 0.0;
    final mean = sum / n;
    final variance = (sumSq / n) - (mean * mean);
    // Empirical normalisation — see docstring for the 800 baseline.
    return (variance / 800.0).clamp(0.0, 1.0);
  }
}

class FaceEnrolmentService extends ChangeNotifier {
  /// [mode] resolves the four-cell consent matrix from spec section 3.
  /// Defaults to [FaceEnrolmentMode.full] for back-compat with Wave-D
  /// callers; the screen passes the resolved mode explicitly going
  /// forward.
  FaceEnrolmentService({this.mode = FaceEnrolmentMode.full});

  /// Resolved at construction by the caller (the enrolment screen)
  /// from the cached client's consent snapshot. Reads as immutable
  /// during the editor's lifecycle — changing consent mid-flow would
  /// invalidate the run and is gated by the entry points.
  final FaceEnrolmentMode mode;

  /// Same native channel as the conversion service. The
  /// `generateFaceEmbeddingsFromFrames` method was added by Wave-BC
  /// (PR #478) and is live on staging.
  @visibleForTesting
  static const MethodChannel videoChannel =
      MethodChannel('com.raidme.video_converter');

  // ── Sweep timing constants ──────────────────────────────────────────────
  //
  // Tuned for a ~10-15s total user-perceived run on real hardware. The
  // 4Hz capture cadence (250ms interval) keeps the frame buffer at ~40
  // captures across the full sweep, which gives the native side enough
  // pose-bucket coverage to pick a 5-8 slot set without choking on
  // the MobileFaceNet pass (~150-300ms per chip on A17).
  //
  // Tunable from device QA — if the practitioner can't keep up with
  // the yaw phase, bump _kYawDuration up and the tick cadence will
  // dilate proportionally.

  /// Yaw phase duration (L → R head rotation).
  static const Duration _kYawDuration = Duration(milliseconds: 6000);

  /// Pitch phase duration (up → down head rotation).
  static const Duration _kPitchDuration = Duration(milliseconds: 4000);

  /// Frame capture interval during the sweep. Lower = more frames =
  /// better pose coverage at the cost of disk + memory.
  static const Duration _kCaptureInterval = Duration(milliseconds: 250);

  /// Target slot count passed to native. Native clamps to [3, 8].
  static const int _kExpectedSlotCount = 6;

  /// Hard minimum slot count to persist. Below this we surface
  /// [FaceEnrolmentError.notEnoughAngles] so the practitioner re-runs
  /// the sweep rather than landing with a useless single-slot enrolment.
  static const int _kHardMinSlotCount = 3;

  /// Number of decorative tick marks on the arc ring. Drives the UI
  /// painter; not load-bearing for the algorithm. 6 ticks = one per
  /// (yaw + pitch) / 6 = ~1.67s.
  static const int kRingTickCount = 6;

  // ── Reactive state ──────────────────────────────────────────────────────

  FaceEnrolmentState _state = FaceEnrolmentState.idle;
  FaceEnrolmentState get state => _state;

  /// 0.0 → 1.0 normalised sweep progress. Drives the arc ring fill.
  /// Reaches 1.0 at the end of the pitch phase.
  double _progress = 0.0;
  double get progress => _progress;

  /// Instruction copy bound to the screen's primary label. Null while
  /// idle / done / cancelled.
  String? _instructionText;
  String? get instructionText => _instructionText;

  /// Captured frame paths during the sweep. Drained when persist
  /// succeeds or on cancel. Public for diagnostics + testing — UI
  /// does not consume this directly.
  final List<String> _capturedFramePaths = <String>[];
  List<String> get capturedFramePaths =>
      List<String>.unmodifiable(_capturedFramePaths);

  /// Picked slots returned from the native embedding pass. Bound to
  /// the confirm view's horizontal thumbnail strip.
  List<FaceEnrolmentSlot>? _pendingSlots;
  List<FaceEnrolmentSlot>? get pendingSlots => _pendingSlots;

  /// Last error if [state] == failed. Null otherwise.
  FaceEnrolmentError? _error;
  FaceEnrolmentError? get error => _error;

  /// Where captured frames live for the current run. Cleaned up on
  /// terminal transitions (done / cancelled / failed).
  Directory? _frameDir;

  /// Periodic timer driving frame capture during the sweep.
  /// M37: legacy timer-driven path; the pose-stream path uses
  /// [_poseSub] instead. Kept so the still-image sweep ([startSweep])
  /// continues to compile for back-compat with any caller that hasn't
  /// migrated yet.
  Timer? _captureTimer;

  /// M37 — live pose subscription powering the prompt walker. Bound
  /// in [startPoseGatedSweep], cancelled on every terminal transition.
  StreamSubscription<FaceEnrolmentPoseEvent>? _poseSub;

  /// M37 — most-recent pose event observed (regardless of accept).
  /// Drives the hint-text "closest unfilled bucket" computation + the
  /// stall flag updates. Updated on every pose stream event.
  // ignore: unused_field
  ({double yaw, double pitch})? _lastObservedPose;

  /// M37 — guard against re-entrant `captureFrameAndEmbed` calls.
  /// Each native call takes ~50-150ms; a second pose event landing
  /// while we're still in flight must not double-fire.
  bool _embedInFlight = false;

  /// M37 — periodic ticker that updates the stall flags every ~500ms
  /// even when no pose events arrive (e.g. user covers the camera).
  /// The pose event itself also calls [_updateStallFlags] but events
  /// can dry up entirely if the face leaves the frame.
  Timer? _stallTimer;


  /// Single broadcast stream for error events. UI subscribes from
  /// `initState` and shows inline coral toasts. Errors also set
  /// [_state] to failed and [_error] for late subscribers.
  final StreamController<FaceEnrolmentError> _errorController =
      StreamController<FaceEnrolmentError>.broadcast();
  Stream<FaceEnrolmentError> get errorStream => _errorController.stream;

  /// Phase 2 — broadcast stream for per-candidate rejections during
  /// the pose-gated sweep. UI subscribes to surface the brief rose
  /// toast at the bottom of the viewfinder (mockup state 2).
  final StreamController<FaceEnrolmentRejection> _rejectionController =
      StreamController<FaceEnrolmentRejection>.broadcast();
  Stream<FaceEnrolmentRejection> get rejectionStream =>
      _rejectionController.stream;

  /// Phase 2 — buckets filled so far in the current sweep. Drives the
  /// guidance ring's lit/dim per-segment state.
  final Set<PoseBucket> _filledBuckets = <PoseBucket>{};
  Set<PoseBucket> get filledBuckets => Set.unmodifiable(_filledBuckets);

  /// Phase 2 — accumulated accepted slots during the pose-gated
  /// sweep. Differs from [_pendingSlots] which is populated only when
  /// the sweep transitions to confirming. The runtime sweep mutates
  /// this; the confirming transition copies it into [_pendingSlots].
  final List<FaceEnrolmentSlot> _accumulatedSlots = <FaceEnrolmentSlot>[];

  /// Phase 2 — last accepted slot's composite quality score. Drives
  /// the "Last slot: NN" badge top-right of the viewfinder. Null
  /// before the first acceptance.
  double? _lastAcceptedScore;
  double? get lastAcceptedScore => _lastAcceptedScore;

  /// Phase 2 — closest unfilled bucket to the most recently observed
  /// pose. Drives the dynamic hint text below the ring. Null when
  /// all buckets are filled or no pose has been observed yet.
  PoseBucket? _currentTargetBucket;
  PoseBucket? get currentTargetBucket => _currentTargetBucket;

  // M30 — _lastProgressAt was the "no progress" timeout anchor for
  // the closest-unfilled-bucket sweep loop. The prompt-driven flow
  // tracks staleness per-prompt via [_currentPromptStartedAt] instead;
  // the field is retired.

  /// M30 — Current prompt index in [kPromptSequence] (0..5). Drives
  /// which prompt copy + arrow renders + which bucket the tick will
  /// accept. -1 = sweep hasn't started yet (idle); kPromptSequence.length
  /// = all prompts completed.
  int _currentPromptIndex = -1;
  int get currentPromptIndex => _currentPromptIndex;

  /// M30 — When the current prompt became active. Drives the soft-hint
  /// + skip-pose timers. Null while idle / completed.
  DateTime? _currentPromptStartedAt;

  /// M30 — True once [kStallSoftHintAfter] has elapsed on the current
  /// prompt without an accept. UI binds this to render the per-prompt
  /// stall hint copy.
  bool _showStallHint = false;
  bool get showStallHint => _showStallHint;

  /// M30 — True once [kStallSkipAfter] has elapsed on the current
  /// prompt. UI binds this to render the "Skip this pose" button.
  bool _showSkipPrompt = false;
  bool get showSkipPrompt => _showSkipPrompt;

  /// M30 — Number of prompts the practitioner explicitly skipped via
  /// the "Skip this pose" button. Subtracts from the success count
  /// during the finishing check; if fewer than the hard minimum
  /// remain captured, the sweep fails.
  int _skippedPromptCount = 0;
  int get skippedPromptCount => _skippedPromptCount;

  /// Cancellation flag — set by [cancel], read by the sweep + commit
  /// loops to short-circuit cleanly.
  bool _cancelled = false;

  /// Frame producer hook. The screen wires this to its
  /// `_cameraController.takePicture()` flow. We don't own the camera
  /// here — the screen does — because the service shouldn't pin a
  /// camera plugin reference (testing pain + keeps the service free
  /// of UI deps). The hook returns a path to a JPG that the service
  /// then logs in the buffer.
  ///
  /// Set via [setFrameProducer] before [startSweep].
  Future<String?> Function()? _frameProducer;

  /// Bind the frame-producer hook. The screen calls this once after
  /// the camera is initialised, before [startSweep].
  void setFrameProducer(Future<String?> Function() producer) {
    _frameProducer = producer;
  }

  // ── Public API ──────────────────────────────────────────────────────────

  /// Begin the sweep. Transitions idle → sweepingYaw → sweepingPitch
  /// → embedding → confirming. Caller invokes once the camera preview
  /// is up and the screen is ready to render the ring.
  ///
  /// Pre-condition: [setFrameProducer] has been called. If the
  /// producer is null we fail fast with a [FaceEnrolmentError.camera]
  /// since there's no way to recover without the hook wired.
  Future<void> startSweep() async {
    if (_state != FaceEnrolmentState.idle) {
      if (_kDiagLogs) {
        debugPrint(
          '[FaceEnrolment] startSweep ignored — current state=$_state',
        );
      }
      return;
    }
    if (_frameProducer == null) {
      _emitError(const FaceEnrolmentError(
        type: FaceEnrolmentErrorType.camera,
        message: "Camera not ready — try again.",
      ));
      return;
    }
    _cancelled = false;
    _capturedFramePaths.clear();

    // Allocate a per-run temp directory so cancellation can wipe it
    // without disturbing other concurrent flows.
    try {
      final tempDir = await getTemporaryDirectory();
      final runId = DateTime.now().millisecondsSinceEpoch.toString();
      _frameDir = Directory(p.join(tempDir.path, 'face_enrol_$runId'));
      await _frameDir!.create(recursive: true);
    } catch (e) {
      if (_kDiagLogs) {
        debugPrint('[FaceEnrolment] frame dir create failed: $e');
      }
      _emitError(FaceEnrolmentError(
        type: FaceEnrolmentErrorType.io,
        message: "Couldn't prepare capture buffer: $e",
      ));
      return;
    }

    _setState(FaceEnrolmentState.sweepingYaw);
    _instructionText = "Slowly turn your head from left to right";
    notifyListeners();

    await _runPhase(_kYawDuration, baseProgress: 0.0, span: 0.6);
    if (_cancelled) {
      await _teardownFrames();
      _setState(FaceEnrolmentState.cancelled);
      return;
    }

    _setState(FaceEnrolmentState.sweepingPitch);
    _instructionText = "Now look up, then down";
    notifyListeners();

    await _runPhase(_kPitchDuration, baseProgress: 0.6, span: 0.4);
    if (_cancelled) {
      await _teardownFrames();
      _setState(FaceEnrolmentState.cancelled);
      return;
    }

    // Sweep complete — hand off to native for the embedding pass.
    _progress = 1.0;
    _setState(FaceEnrolmentState.embedding);
    _instructionText = "Almost there";
    notifyListeners();

    await _runEmbedding();
  }

  /// Real-time pose-gated sweep (M37, 2026-05-26).
  ///
  /// The Wave-D timer-driven path took a still every ~333ms, shipped
  /// it through the still-image VNDetectFaceLandmarksRequest pipeline,
  /// and accepted/rejected based on the returned yaw + pitch. Console
  /// logs on Carl's iPhone showed VNFaceObservation returned nil
  /// pose for EVERY frame — yaw + pitch never came back — so the
  /// sweep silently rejected everything below the per-prompt
  /// tolerance.
  ///
  /// M37 replaces that with a live pose subscription off
  /// [FaceEnrolmentCameraChannel] which streams `AVMetadataFaceObject`
  /// yaw values (computed by silicon, reliable across off-axis
  /// angles). On each pose event:
  ///
  ///   1. Translate the yaw degrees into our 2D pose tuple
  ///      `(yaw, pitch)` — pitch is forced to 0 because the metadata
  ///      output doesn't expose it. The bucket math still works
  ///      because the yaw-only prompts only depend on yaw.
  ///   2. Resolve the closest-unfilled-bucket hint.
  ///   3. If the pose is within [promptAcceptTolerance] of the
  ///      CURRENT prompt's target bucket AND no embedding is in flight,
  ///      call [FaceEnrolmentCameraChannel.captureFrameAndEmbed] to
  ///      pull the most-recent frame from the native ring buffer and
  ///      run MobileFaceNet on the face crop.
  ///   4. Score the captured embedding via the existing
  ///      [QualityScorer] and accept iff above [kQualityThreshold].
  ///   5. On accept: stamp the slot, fire a haptic, advance to the
  ///      next prompt.
  ///
  /// The sweep ends when every prompt has been completed (or skipped),
  /// OR when [timeout] elapses, OR on practitioner cancel.
  Future<void> startPoseGatedSweep({
    Duration timeout = const Duration(seconds: 180),
  }) async {
    if (_state != FaceEnrolmentState.idle) {
      if (_kDiagLogs) {
        debugPrint(
          '[FaceEnrolment] startPoseGatedSweep ignored — state=$_state',
        );
      }
      return;
    }
    _cancelled = false;
    _capturedFramePaths.clear();
    _filledBuckets.clear();
    _accumulatedSlots.clear();
    _lastAcceptedScore = null;
    _currentTargetBucket = null;
    _skippedPromptCount = 0;
    _showStallHint = false;
    _showSkipPrompt = false;
    _embedInFlight = false;
    _lastObservedPose = null;

    try {
      final tempDir = await getTemporaryDirectory();
      final runId = DateTime.now().millisecondsSinceEpoch.toString();
      _frameDir = Directory(p.join(tempDir.path, 'face_enrol_$runId'));
      await _frameDir!.create(recursive: true);
    } catch (e) {
      _emitError(FaceEnrolmentError(
        type: FaceEnrolmentErrorType.io,
        message: "Couldn't prepare capture buffer: $e",
      ));
      return;
    }

    _setState(FaceEnrolmentState.sweepingYaw);
    _advanceToPrompt(0);
    notifyListeners();

    // Subscribe to the live pose stream. Native session must already
    // be running (the screen calls FaceEnrolmentCameraChannel.start in
    // its initState before pushing this service into sweep).
    _poseSub?.cancel();
    _poseSub = FaceEnrolmentCameraChannel.instance.poseStream.listen(
      _onPoseEvent,
      onError: (Object e, StackTrace st) {
        if (_kDiagLogs) {
          debugPrint('[FaceEnrolment] pose stream error: $e');
        }
      },
    );

    // Periodic stall-flag updater. Pose events also call
    // _updateStallFlags but events can stop arriving entirely if the
    // user covers the camera — the timer makes sure the soft-hint +
    // skip-pose CTA still surface in that case.
    _stallTimer?.cancel();
    _stallTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (_cancelled) return;
      _updateStallFlags();
      notifyListeners();
    });

    // Watchdog: if no prompt has been completed within [timeout], fail
    // with notEnoughAngles. We don't await here — the watchdog runs
    // independently of the pose-event-driven advancement.
    Timer(timeout, () {
      if (_cancelled) return;
      if (_currentPromptIndex >= kPromptSequence.length) return;
      if (_kDiagLogs) {
        debugPrint('[FaceEnrolment] sweep timeout — finishing with what we have');
      }
      unawaited(_finishPoseGatedSweep());
    });
  }

  /// Phase 2 — handle one live pose event. Fast-path: yaw + pitch
  /// distance check against the current prompt's target bucket; only
  /// fire captureFrameAndEmbed when we're within tolerance + idle.
  Future<void> _onPoseEvent(FaceEnrolmentPoseEvent event) async {
    if (_cancelled) return;
    if (_currentPromptIndex < 0 ||
        _currentPromptIndex >= kPromptSequence.length) {
      return;
    }
    final yawDeg = event.yawDeg;
    final pitchDeg = event.pitchDeg;
    if (yawDeg == null || pitchDeg == null) {
      // Vision didn't compute one of the axes this frame — skip rather
      // than default to zero (per `feedback_no_silent_fallbacks`). The
      // next event retries. The native side already nil-skips emission
      // when either yaw or pitch came back nil, so reaching this branch
      // means a defensive miss against malformed payloads.
      if (_kDiagLogs) {
        debugPrint(
          '[FaceEnrolment] pose event with nil axis — yaw=$yawDeg pitch=$pitchDeg (skipping)',
        );
      }
      return;
    }
    final candidatePose = (yaw: yawDeg, pitch: pitchDeg);
    _lastObservedPose = candidatePose;

    final targetBucket = kPromptSequence[_currentPromptIndex];
    final targetCentre = targetBucket.centerDeg;
    final dToTarget = poseDistance(candidatePose, targetCentre);
    const double promptAcceptTolerance = 20.0;

    // Update the stall flags + hint bucket every pose event so the UI
    // reflects how close the user is to the target.
    _updateStallFlags();
    _currentTargetBucket = targetBucket;
    notifyListeners();

    if (dToTarget > promptAcceptTolerance) {
      if (_kDiagLogs) {
        debugPrint(
          '[FaceEnrolment] pose REJECT prompt=$_currentPromptIndex '
          'bucket=$targetBucket '
          'measured_yaw=${yawDeg.toStringAsFixed(1)} '
          'measured_pitch=${pitchDeg.toStringAsFixed(1)} '
          'target_yaw=${targetCentre.yaw.toStringAsFixed(1)} '
          'target_pitch=${targetCentre.pitch.toStringAsFixed(1)} '
          'delta=${dToTarget.toStringAsFixed(1)} tol=${promptAcceptTolerance.toStringAsFixed(1)}',
        );
      }
      return;
    }

    // Within tolerance — try to grab + embed. Guard against re-entrant
    // calls; native captureFrameAndEmbed takes ~50-150ms and a second
    // event firing while we're in flight would double-fire.
    if (_embedInFlight) return;
    _embedInFlight = true;
    try {
      await _captureAndAccept(
        candidatePose: candidatePose,
        targetBucket: targetBucket,
      );
    } finally {
      _embedInFlight = false;
    }
  }

  /// M37 — pull the most-recent frame from the native ring buffer +
  /// score it. On accept: stamp the slot, advance the prompt, fire a
  /// haptic.
  Future<void> _captureAndAccept({
    required ({double yaw, double pitch}) candidatePose,
    required PoseBucket targetBucket,
  }) async {
    final frameDir = _frameDir;
    if (frameDir == null) return;
    final outPath = p.join(
      frameDir.path,
      'f_${DateTime.now().microsecondsSinceEpoch}.jpg',
    );

    FaceEnrolmentEmbeddingResult result;
    try {
      result = await FaceEnrolmentCameraChannel.instance
          .captureFrameAndEmbed(outPath: outPath)
          .timeout(const Duration(seconds: 4));
    } on PlatformException catch (e) {
      // NO_FRAME / NO_FACE are transient — silently skip + try again
      // on the next pose event. EMBEDDING_FAILED is harder; we log it
      // but don't fail the whole sweep on a single bad frame.
      if (_kDiagLogs) {
        debugPrint('[FaceEnrolment] captureFrameAndEmbed failed: ${e.code} ${e.message}');
      }
      return;
    } on TimeoutException catch (_) {
      if (_kDiagLogs) {
        debugPrint('[FaceEnrolment] captureFrameAndEmbed timed out');
      }
      return;
    } catch (e) {
      if (_kDiagLogs) {
        debugPrint('[FaceEnrolment] captureFrameAndEmbed unexpected: $e');
      }
      return;
    }

    _capturedFramePaths.add(result.framePath);

    if (_cancelled) return;
    if (_currentPromptIndex >= kPromptSequence.length) return;
    // Defence: bucket may have advanced while we were awaiting; bail
    // if so to avoid double-stamping.
    if (kPromptSequence[_currentPromptIndex] != targetBucket) return;

    final existingPoses = _accumulatedSlots
        .map((s) => (
              yaw: s.poseYaw ?? 0.0,
              pitch: s.posePitch ?? 0.0,
            ))
        .toList(growable: false);

    // Quality scoring. Decoding the frame is the expensive step
    // (~10-30ms on a downscaled crop); we do it once and reuse.
    final scoreComponents = await _scoreCandidate(
      framePath: result.framePath,
      visionConfidence: 0.95, // Metadata output detected a face — high confidence by definition.
      candidatePose: candidatePose,
      existingPoses: existingPoses,
      embeddingBytes: result.embedding,
    );
    final composite = scoreComponents.composite;

    if (composite < kQualityThreshold) {
      if (_kDiagLogs) {
        debugPrint(
          '[FaceEnrolment] REJECT bucket=$targetBucket '
          'score=${composite.toStringAsFixed(1)} '
          'sh=${scoreComponents.sharpness.toStringAsFixed(2)} '
          'li=${scoreComponents.lighting.toStringAsFixed(2)}',
        );
      }
      // Quality below floor — keep the frame on disk for diagnostics
      // but don't stamp the slot. The next pose event retries.
      return;
    }

    // Accept — stamp the slot for the CURRENT prompt's bucket, mark
    // the bucket filled, advance to the next prompt.
    final slot = FaceEnrolmentSlot(
      slotIndex: _accumulatedSlots.length,
      embedding: result.embedding,
      isFrontalPick: false,
      poseYaw: candidatePose.yaw,
      posePitch: candidatePose.pitch,
      bucket: targetBucket,
      qualityScore: composite,
      sourceFramePath: result.framePath,
    );
    _accumulatedSlots.add(slot);
    _filledBuckets.add(targetBucket);
    _lastAcceptedScore = composite;

    _updateFrontalPick();

    _progress = (_currentPromptIndex + 1) / kPromptSequence.length;

    if (_kDiagLogs) {
      debugPrint(
        '[FaceEnrolment] ACCEPT prompt=$_currentPromptIndex '
        'bucket=$targetBucket score=${composite.toStringAsFixed(1)} '
        'progress=${_accumulatedSlots.length}/${kPromptSequence.length}',
      );
    }

    // M36 — haptic on accept so the user KNOWS to look back at the
    // screen for the next prompt. When turning the head left/right
    // they physically can't see the screen during the move.
    HapticFeedback.mediumImpact();

    final wasLastPrompt = _currentPromptIndex + 1 >= kPromptSequence.length;
    _advanceToPrompt(_currentPromptIndex + 1);
    notifyListeners();

    if (wasLastPrompt) {
      // All prompts done — wrap up immediately rather than waiting on
      // the watchdog or another pose event.
      await _finishPoseGatedSweep();
    }
  }

  /// M30 — Advance to the prompt at [index]. Resets the stall flags
  /// and stamps the prompt-start time so the soft-hint + skip timers
  /// restart cleanly. When [index] equals [kPromptSequence.length] the
  /// sweep loop's while-condition exits and finishing kicks in.
  void _advanceToPrompt(int index) {
    _currentPromptIndex = index;
    _currentPromptStartedAt = DateTime.now();
    _showStallHint = false;
    _showSkipPrompt = false;
    if (index < kPromptSequence.length) {
      _instructionText = kPromptInstructions[index];
      _currentTargetBucket = kPromptSequence[index];
    } else {
      _instructionText = 'All angles captured';
      _currentTargetBucket = null;
    }
    if (_kDiagLogs) {
      debugPrint('[FaceEnrolment] advance → prompt $index '
          '(${index < kPromptSequence.length ? kPromptInstructions[index] : 'done'})');
    }
  }

  /// M30 — Update the per-prompt stall flags ([_showStallHint] +
  /// [_showSkipPrompt]) based on elapsed time on the current prompt.
  /// Pure flag math — does not change [_currentPromptIndex].
  void _updateStallFlags() {
    final startedAt = _currentPromptStartedAt;
    if (startedAt == null) return;
    if (_currentPromptIndex >= kPromptSequence.length) return;
    final elapsed = DateTime.now().difference(startedAt);
    final softHint = elapsed >= kStallSoftHintAfter;
    final skipHint = elapsed >= kStallSkipAfter;
    if (softHint != _showStallHint || skipHint != _showSkipPrompt) {
      _showStallHint = softHint;
      _showSkipPrompt = skipHint;
    }
  }

  /// M30 — Practitioner tapped "Skip this pose". Marks the current
  /// prompt as skipped (tracked separately from completed) and
  /// advances to the next prompt.
  void requestSkipCurrentPrompt() {
    if (_state != FaceEnrolmentState.sweepingYaw &&
        _state != FaceEnrolmentState.sweepingPitch) {
      return;
    }
    if (_currentPromptIndex >= kPromptSequence.length) return;
    _skippedPromptCount++;
    if (_kDiagLogs) {
      debugPrint('[FaceEnrolment] skip prompt $_currentPromptIndex '
          '(${kPromptInstructions[_currentPromptIndex]})');
    }
    _advanceToPrompt(_currentPromptIndex + 1);
    notifyListeners();
  }

  /// M30 — Restart the sweep from a Failed state. Discards accumulated
  /// state cleanly so the run starts fresh. Caller (the screen's Try
  /// Again CTA) MUST be in the failed state — no-op otherwise.
  Future<void> restartFromFailed() async {
    if (_state != FaceEnrolmentState.failed) {
      if (_kDiagLogs) {
        debugPrint('[FaceEnrolment] restartFromFailed ignored — state=$_state');
      }
      return;
    }
    if (_kDiagLogs) {
      debugPrint('[FaceEnrolment] restartFromFailed — clean slate');
    }
    _error = null;
    _cancelled = false;
    _capturedFramePaths.clear();
    _filledBuckets.clear();
    _accumulatedSlots.clear();
    _lastAcceptedScore = null;
    _currentTargetBucket = null;
    _currentPromptIndex = -1;
    _currentPromptStartedAt = null;
    _skippedPromptCount = 0;
    _showStallHint = false;
    _showSkipPrompt = false;
    _instructionText = null;
    _progress = 0.0;
    _embedInFlight = false;
    _lastObservedPose = null;
    await _poseSub?.cancel();
    _poseSub = null;
    _stallTimer?.cancel();
    _stallTimer = null;
    await _teardownFrames();
    _setState(FaceEnrolmentState.idle);
    notifyListeners();
    await startPoseGatedSweep();
  }

  /// Practitioner tap on the legacy "Done" mid-sweep chip — accept
  /// whatever we've got and force-finish the sweep. M30 — replaced by
  /// the explicit "Skip this pose" CTA per prompt
  /// ([requestSkipCurrentPrompt]). Kept as a thin alias that skips the
  /// current prompt so any in-tree callers still compile.
  @Deprecated('Use requestSkipCurrentPrompt — per-prompt skip is the new flow')
  void requestSweepFinish() {
    requestSkipCurrentPrompt();
  }

  // M37 — _runPoseGatedTick (timer-driven still-image path) retired.
  // The live pose stream + on-demand captureFrameAndEmbed in
  // [_onPoseEvent] + [_captureAndAccept] replaces it. Removed entirely
  // rather than left as dead code — the still-image VNDetectFaceLandmarks
  // returned nil pose for every frame on Carl's iPhone and silently
  // rejected the whole sweep, which is exactly what M37 fixes.

  /// Update the [_isFrontalPick] flag across [_accumulatedSlots] so
  /// exactly one slot — the one whose pose is closest to (0, 0) — is
  /// the frontal pick at any time. Called after every accept.
  void _updateFrontalPick() {
    if (_accumulatedSlots.isEmpty) return;
    var bestIdx = 0;
    var bestDist = double.infinity;
    for (var i = 0; i < _accumulatedSlots.length; i++) {
      final s = _accumulatedSlots[i];
      final pose = (yaw: s.poseYaw ?? 0.0, pitch: s.posePitch ?? 0.0);
      final d = poseDistance(pose, const (yaw: 0.0, pitch: 0.0));
      if (d < bestDist) {
        bestDist = d;
        bestIdx = i;
      }
    }
    for (var i = 0; i < _accumulatedSlots.length; i++) {
      final s = _accumulatedSlots[i];
      _accumulatedSlots[i] = s.copyWith(isFrontalPick: i == bestIdx);
    }
  }

  // M30 — _updateHintText (closest-unfilled-bucket flow) retired in
  // favour of [_advanceToPrompt] which owns the instruction copy per
  // prompt. Stall hints surface in the UI via [showStallHint] +
  // [kPromptStallHints].

  /// Wrap-up after the pose-gated sweep ends (all prompts done, all
  /// skipped, timeout, or cancel). Tears down the live pose
  /// subscription + stall timer (M37). Then:
  ///   - If too few slots accepted → surface notEnoughAngles.
  ///   - Else → transition to confirming for the manual-avatar grid
  ///     (full mode) or fall through to commit (embeddingOnly).
  Future<void> _finishPoseGatedSweep() async {
    // Tear down the live subs FIRST so a late pose event can't
    // double-fire a slot acceptance after we've decided to finish.
    await _poseSub?.cancel();
    _poseSub = null;
    _stallTimer?.cancel();
    _stallTimer = null;

    final captured = _accumulatedSlots.length;
    if (captured < kMinPromptsForValidEnrolment) {
      _emitError(FaceEnrolmentError(
        type: FaceEnrolmentErrorType.notEnoughAngles,
        message:
            "Not enough variety captured — try again with better lighting "
            "or more head movement (captured $captured of "
            "$kMinPromptsForValidEnrolment minimum)",
      ));
      return;
    }

    _pendingSlots = List<FaceEnrolmentSlot>.unmodifiable(_accumulatedSlots);
    _setState(FaceEnrolmentState.confirming);
    _instructionText = null;
    notifyListeners();
  }

  // M37 — _radiansToDegreesIfNeeded retired. The pose stream now ships
  // degrees directly off AVCaptureMetadataOutput; the legacy still-image
  // path that depended on the radians→degrees coercion (_runPoseGatedTick)
  // is gone.

  /// Score all five components of a candidate frame and return them
  /// as a single record. Decoding the frame is the expensive step
  /// (~10-30ms); we do it once and reuse for sharpness + lighting.
  Future<_CandidateScoreComponents> _scoreCandidate({
    required String framePath,
    required double visionConfidence,
    required ({double yaw, double pitch}) candidatePose,
    required List<({double yaw, double pitch})> existingPoses,
    required Uint8List embeddingBytes,
  }) async {
    double sharpness = 0.5;
    double lighting = 0.5;
    try {
      final bytes = await File(framePath).readAsBytes();
      // Decode at a downscaled size — full-res face crops are wasteful
      // for variance + min/max scans which are O(width * height).
      final decoded = img.decodeImage(bytes);
      if (decoded != null) {
        final small = decoded.width > 240
            ? img.copyResize(decoded, width: 240)
            : decoded;
        sharpness = QualityScorer.sharpnessFromImage(small);
        lighting = QualityScorer.lightingFromImage(small);
      }
    } catch (e) {
      if (_kDiagLogs) {
        debugPrint('[FaceEnrolment] frame decode for scoring failed: $e');
      }
    }

    final poseUniqueness = QualityScorer.poseUniquenessScore(
      candidateDeg: candidatePose,
      existingDeg: existingPoses,
    );
    final norm = QualityScorer.embeddingL2Norm(embeddingBytes);
    final normSafe = norm.isFinite ? norm : 1.0;
    final normPenalty = (normSafe - 1.0).abs().clamp(0.0, 1.0).toDouble();
    final composite = QualityScorer.score(
      visionConfidence: visionConfidence,
      sharpness: sharpness,
      lighting: lighting,
      poseUniqueness: poseUniqueness,
      embeddingNorm: normSafe,
    );
    return _CandidateScoreComponents(
      visionConfidence: visionConfidence,
      sharpness: sharpness,
      lighting: lighting,
      poseUniqueness: poseUniqueness,
      normPenalty: normPenalty,
      composite: composite,
    );
  }

  /// Cancel the run cleanly. Safe at any state. The service
  /// transitions to [FaceEnrolmentState.cancelled] and the UI pops.
  ///
  /// During [FaceEnrolmentState.embedding] / [FaceEnrolmentState.persisting]
  /// the in-flight native / cloud call is allowed to finish but its
  /// result is discarded.
  ///
  /// M31 — cancel from [FaceEnrolmentState.failed] is now supported so
  /// the Close button on the Failed screen reliably pops the route.
  /// Previously failed was treated as terminal-no-cancel which left
  /// the close button silently no-oping.
  void cancel() {
    if (_state == FaceEnrolmentState.done ||
        _state == FaceEnrolmentState.cancelled) {
      return;
    }
    _cancelled = true;
    _captureTimer?.cancel();
    _captureTimer = null;
    // M37 — tear down the live pose sub + stall timer so a late event
    // can't mutate state after cancel.
    _poseSub?.cancel();
    _poseSub = null;
    _stallTimer?.cancel();
    _stallTimer = null;
    if (_kDiagLogs) {
      debugPrint('[FaceEnrolment] cancel requested at state=$_state');
    }
    // If we were sweeping the loop sees _cancelled on the next tick
    // and transitions. If we were embedding/persisting the in-flight
    // Future drains then checks the flag before setting the success
    // state. Other states (idle / confirming / failed) have no in-
    // flight work — flip immediately so the UI can pop.
    if (_state == FaceEnrolmentState.sweepingYaw ||
        _state == FaceEnrolmentState.sweepingPitch) {
      // Short-circuit immediately — sweep loop will exit on next tick.
    } else if (_state == FaceEnrolmentState.idle ||
        _state == FaceEnrolmentState.confirming ||
        _state == FaceEnrolmentState.failed) {
      // Sync teardown for these — no in-flight work to await.
      unawaited(_teardownFrames());
      _setState(FaceEnrolmentState.cancelled);
    }
  }

  /// Commit the enrolment — write to local + cloud. Caller is the
  /// confirm view's Done button. [clientId] is the parent client.
  ///
  /// Side effects (in order):
  ///   1. Local SQLite write via [LocalStorageService.setCachedClientFaceEmbeddings]
  ///      (mirrored from [SyncService.storage]).
  ///   2. Cloud RPC via [ApiClient.setClientFaceEmbeddings] —
  ///      best-effort. Failure does NOT block the local-side win;
  ///      SyncService picks it up on next pull.
  ///   3. Copy the frontal-pick frame into the persistent avatars/
  ///      directory at `{docs}/avatars/{clientId}.png` (the canonical
  ///      local path FaceEmbeddingService reads from).
  ///   4. Best-effort cloud avatar upload + `set_client_avatar` RPC
  ///      via SyncService.
  ///   5. Prime [FaceEmbeddingService] so the in-memory legacy single-
  ///      embedding state matches the new frontal-pick (back-compat
  ///      with conversion service callsites that still read the
  ///      singular cache during this release cycle).
  Future<void> commit({
    required String clientId,
    int? manuallyChosenAvatarSlotIndex,
  }) async {
    if (_state != FaceEnrolmentState.confirming) {
      if (_kDiagLogs) {
        debugPrint(
          '[FaceEnrolment] commit ignored — state=$_state (expected confirming)',
        );
      }
      return;
    }
    final pendingOriginal = _pendingSlots;
    if (pendingOriginal == null || pendingOriginal.isEmpty) {
      _emitError(const FaceEnrolmentError(
        type: FaceEnrolmentErrorType.notEnoughAngles,
        message: "Couldn't capture enough angles — try again",
      ));
      return;
    }

    // Phase 2 — if the practitioner picked a different cell as the
    // avatar in the manual-selection grid (full mode only), re-stamp
    // the frontal-pick flag onto that slot. embeddingOnly mode never
    // exposes the grid so the override is meaningless there.
    List<FaceEnrolmentSlot> slots = pendingOriginal;
    if (manuallyChosenAvatarSlotIndex != null &&
        mode == FaceEnrolmentMode.full &&
        manuallyChosenAvatarSlotIndex >= 0 &&
        manuallyChosenAvatarSlotIndex < slots.length) {
      slots = List<FaceEnrolmentSlot>.unmodifiable(
        List<FaceEnrolmentSlot>.generate(
          slots.length,
          (i) => slots[i].copyWith(
            isFrontalPick: i == manuallyChosenAvatarSlotIndex,
          ),
        ),
      );
      _pendingSlots = slots;
    }

    _setState(FaceEnrolmentState.persisting);
    _instructionText = "Saving";
    notifyListeners();

    // Step 1: local SQLite write.
    try {
      await SyncService.instance.storage.setCachedClientFaceEmbeddings(
        clientId: clientId,
        slots: slots
            .map((s) => (
                  slotIndex: s.slotIndex,
                  embedding: s.embedding,
                  modelVersion: kSafeModeAlgorithmVersion,
                  isFrontalPick: s.isFrontalPick,
                  poseYaw: s.poseYaw,
                  posePitch: s.posePitch,
                ))
            .toList(growable: false),
      );
      if (_kDiagLogs) {
        debugPrint(
          '[FaceEnrolment] local write succeeded — '
          'client=$clientId slots=${slots.length}',
        );
      }
    } catch (e) {
      if (_kDiagLogs) {
        debugPrint('[FaceEnrolment] local write FAILED: $e');
      }
      _emitError(FaceEnrolmentError(
        type: FaceEnrolmentErrorType.io,
        message: "Couldn't save locally — try again ($e)",
      ));
      return;
    }

    if (_cancelled) {
      await _teardownFrames();
      _setState(FaceEnrolmentState.cancelled);
      return;
    }

    // Step 2: cloud RPC — best-effort, log failure but don't block.
    try {
      final frontalIdx = slots.indexWhere((s) => s.isFrontalPick);
      final safeFrontalIdx = frontalIdx >= 0 ? frontalIdx : 0;
      final ok = await ApiClient.instance.setClientFaceEmbeddings(
        clientId: clientId,
        embeddings:
            slots.map((s) => s.embedding).toList(growable: false),
        modelVersion: kSafeModeAlgorithmVersion,
        frontalPickSlotIndex: safeFrontalIdx,
        posesYaw: slots
            .map((s) => s.poseYaw ?? 0.0)
            .toList(growable: false),
        posesPitch: slots
            .map((s) => s.posePitch ?? 0.0)
            .toList(growable: false),
      );
      if (!ok && _kDiagLogs) {
        debugPrint(
          '[FaceEnrolment] cloud write returned false — sync will retry',
        );
      }
    } catch (e) {
      if (_kDiagLogs) {
        debugPrint('[FaceEnrolment] cloud write threw: $e — local stands');
      }
    }

    // Step 3 + 4: copy frontal-pick frame to avatars/ and best-effort
    // cloud avatar upload. embeddingOnly mode SKIPS this — the client
    // hasn't granted avatar consent, so we must not persist a face
    // photo. (Spec section 3 + acceptance criterion 6.)
    if (mode == FaceEnrolmentMode.embeddingOnly) {
      if (_kDiagLogs) {
        debugPrint('[FaceEnrolment] embeddingOnly — skipping avatar write');
      }
    } else {
      try {
        await _writeFrontalAvatar(clientId: clientId, slots: slots);
      } catch (e) {
        // Avatar write is best-effort — the practitioner will see a
        // missing-avatar slot but enrolment itself succeeded. Log only.
        if (_kDiagLogs) {
          debugPrint('[FaceEnrolment] avatar write failed: $e');
        }
      }
    }

    // Step 5: prime the legacy single-embedding cache so any
    // conversion callsite that still reads
    // FaceEmbeddingService.getEmbedding(clientId) sees the new frontal
    // pick (back-compat during this release cycle).
    try {
      final frontalSlot = slots.firstWhere(
        (s) => s.isFrontalPick,
        orElse: () => slots.first,
      );
      FaceEmbeddingService.instance.hydrateFromBytes(
        clientId,
        frontalSlot.embedding,
      );
    } catch (e) {
      if (_kDiagLogs) {
        debugPrint('[FaceEnrolment] legacy prime failed: $e');
      }
    }

    await _teardownFrames();
    _setState(FaceEnrolmentState.done);
    _instructionText = null;
    notifyListeners();
  }

  // ── Internal phases ─────────────────────────────────────────────────────

  /// Run one sweep phase (yaw or pitch). Drives [_progress] from
  /// `baseProgress` → `baseProgress + span` over `duration`, capturing
  /// a frame every [_kCaptureInterval]. Returns when the phase ends or
  /// [_cancelled] is set.
  Future<void> _runPhase(
    Duration duration, {
    required double baseProgress,
    required double span,
  }) async {
    final endAt = DateTime.now().add(duration);
    // Kick off the periodic capture timer.
    _captureTimer?.cancel();
    _captureTimer = Timer.periodic(_kCaptureInterval, (_) async {
      if (_cancelled) return;
      final producer = _frameProducer;
      if (producer == null) return;
      try {
        final path = await producer();
        if (path == null) return;
        if (_cancelled) {
          // Best-effort cleanup if the user cancelled mid-call.
          try {
            await File(path).delete();
          } catch (_) {}
          return;
        }
        _capturedFramePaths.add(path);
      } catch (e) {
        // Per-frame failures are non-fatal; the next tick retries.
        if (_kDiagLogs) {
          debugPrint('[FaceEnrolment] frame capture skipped: $e');
        }
      }
    });

    // Drive progress via short polls so the UI animates smoothly even
    // if individual captures are slow.
    while (!_cancelled && DateTime.now().isBefore(endAt)) {
      final elapsed = duration - endAt.difference(DateTime.now());
      final ratio = elapsed.inMilliseconds / duration.inMilliseconds;
      _progress = (baseProgress + (ratio.clamp(0.0, 1.0) * span))
          .clamp(0.0, 1.0)
          .toDouble();
      notifyListeners();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    _captureTimer?.cancel();
    _captureTimer = null;
    if (!_cancelled) {
      _progress = (baseProgress + span).clamp(0.0, 1.0).toDouble();
      notifyListeners();
    }
  }

  /// Run the native MobileFaceNet pass on the captured frame buffer.
  /// Transitions to confirming on success or failed on error.
  Future<void> _runEmbedding() async {
    if (_capturedFramePaths.isEmpty) {
      _emitError(const FaceEnrolmentError(
        type: FaceEnrolmentErrorType.notEnoughAngles,
        message: "Couldn't capture enough angles — try again",
      ));
      return;
    }

    try {
      final dynamic resp = await videoChannel
          .invokeMethod<Map<dynamic, dynamic>>(
            'generateFaceEmbeddingsFromFrames',
            <String, dynamic>{
              'framePaths': _capturedFramePaths,
              'expectedSlotCount': _kExpectedSlotCount,
            },
          )
          .timeout(const Duration(seconds: 30));

      if (resp == null) {
        _emitError(const FaceEnrolmentError(
          type: FaceEnrolmentErrorType.embeddingFailed,
          message: "Face recognition returned no result — try again.",
        ));
        return;
      }

      final map = Map<String, dynamic>.from(resp as Map);
      final List<dynamic> embsRaw =
          (map['embeddings'] as List<dynamic>?) ?? const [];
      final List<dynamic> yawsRaw =
          (map['posesYaw'] as List<dynamic>?) ?? const [];
      final List<dynamic> pitchesRaw =
          (map['posesPitch'] as List<dynamic>?) ?? const [];
      final int frontalIndex = (map['frontalPickSlot'] as int?) ?? 0;

      final embeddings = <Uint8List>[];
      for (final raw in embsRaw) {
        if (raw is Uint8List) {
          embeddings.add(raw);
        } else if (raw is List<int>) {
          embeddings.add(Uint8List.fromList(raw));
        }
      }

      if (embeddings.length < _kHardMinSlotCount) {
        _emitError(FaceEnrolmentError(
          type: FaceEnrolmentErrorType.notEnoughAngles,
          message: "Couldn't capture enough angles — try again "
              "(got ${embeddings.length} of $_kHardMinSlotCount min)",
        ));
        return;
      }

      // Cancel between native call and slot assembly — discard.
      if (_cancelled) {
        await _teardownFrames();
        _setState(FaceEnrolmentState.cancelled);
        return;
      }

      final slots = <FaceEnrolmentSlot>[];
      for (var i = 0; i < embeddings.length; i++) {
        final yaw = i < yawsRaw.length
            ? (yawsRaw[i] as num).toDouble()
            : null;
        final pitch = i < pitchesRaw.length
            ? (pitchesRaw[i] as num).toDouble()
            : null;
        slots.add(FaceEnrolmentSlot(
          slotIndex: i,
          embedding: embeddings[i],
          isFrontalPick: i == frontalIndex,
          poseYaw: yaw,
          posePitch: pitch,
          // The frontal-pick frame is whichever sweep frame had the
          // closest-to-zero yaw + pitch. Native side already returned
          // the metadata; we don't try to map back to a specific
          // captured file path here. The avatar copy step in commit()
          // re-derives the closest captured frame to "frontal" by
          // index proximity.
        ));
      }

      _pendingSlots = slots;
      _setState(FaceEnrolmentState.confirming);
      _instructionText = null;
      notifyListeners();
    } on PlatformException catch (e) {
      final code = e.code;
      // Native distinguishes "not enough frames" from generic failure
      // so the UI can show the right copy.
      if (code == 'NOT_ENOUGH_FRAMES') {
        _emitError(FaceEnrolmentError(
          type: FaceEnrolmentErrorType.notEnoughAngles,
          message:
              e.message ?? "Couldn't capture enough angles — try again",
        ));
      } else if (code == 'UNSUPPORTED_OS') {
        _emitError(FaceEnrolmentError(
          type: FaceEnrolmentErrorType.embeddingFailed,
          message:
              e.message ?? "Face recognition needs iOS 15 or newer.",
        ));
      } else {
        _emitError(FaceEnrolmentError(
          type: FaceEnrolmentErrorType.embeddingFailed,
          message: e.message ?? "Face recognition failed ($code).",
        ));
      }
    } on MissingPluginException catch (_) {
      _emitError(const FaceEnrolmentError(
        type: FaceEnrolmentErrorType.embeddingFailed,
        message: "Face recognition not available in this build.",
      ));
    } on TimeoutException catch (_) {
      _emitError(const FaceEnrolmentError(
        type: FaceEnrolmentErrorType.embeddingFailed,
        message: "Face recognition timed out — try again.",
      ));
    } catch (e) {
      _emitError(FaceEnrolmentError(
        type: FaceEnrolmentErrorType.embeddingFailed,
        message: "Face recognition failed: $e",
      ));
    }
  }

  /// Copy the frontal-pick frame into the persistent avatars/
  /// directory and queue the cloud-side avatar upload. The frontal-
  /// pick frame is approximated as the captured frame at the same
  /// list-index as the frontal slot, since native picks slots in
  /// frame-order. Best-effort — failure does not block the enrolment.
  Future<void> _writeFrontalAvatar({
    required String clientId,
    required List<FaceEnrolmentSlot> slots,
  }) async {
    final frontalSlotIdx = slots.indexWhere((s) => s.isFrontalPick);
    if (frontalSlotIdx < 0) return;
    final frontalSlot = slots[frontalSlotIdx];

    // Phase 2 — slots carry the exact source frame path so we can
    // copy the right file (manual avatar override on the grid would
    // be meaningless if we proportionally re-derived). Fall back to
    // the legacy proportional-mapping for Wave-D-era slots that
    // didn't carry the source path.
    String? sourcePath = frontalSlot.sourceFramePath;
    if (sourcePath == null || !File(sourcePath).existsSync()) {
      if (_capturedFramePaths.isEmpty) return;
      final approxCapturedIdx = ((frontalSlotIdx / slots.length) *
              _capturedFramePaths.length)
          .floor()
          .clamp(0, _capturedFramePaths.length - 1);
      sourcePath = _capturedFramePaths[approxCapturedIdx];
    }

    final docsDir = await getApplicationDocumentsDirectory();
    final avatarsDir = Directory(p.join(docsDir.path, 'avatars'));
    if (!avatarsDir.existsSync()) {
      avatarsDir.createSync(recursive: true);
    }
    final localAbs = p.join(avatarsDir.path, '$clientId.png');
    try {
      if (File(localAbs).existsSync()) {
        File(localAbs).deleteSync();
      }
    } catch (_) {}
    await File(sourcePath).copy(localAbs);

    // Queue cloud avatar upload via SyncService — the cloud path
    // encodes the practice scope so RLS approves the bucket write.
    try {
      final cached =
          await SyncService.instance.storage.getCachedClientById(clientId);
      if (cached == null) return;
      final cloudPath =
          '${cached.practiceId}/$clientId/avatar.png';
      try {
        await ApiClient.instance.uploadRawArchive(
          path: cloudPath,
          file: File(localAbs),
          contentType: 'image/png',
        );
      } catch (e) {
        if (_kDiagLogs) {
          debugPrint('[FaceEnrolment] avatar cloud upload failed: $e');
        }
      }
      await SyncService.instance.queueSetAvatar(
        clientId: clientId,
        avatarPath: cloudPath,
      );
    } catch (e) {
      if (_kDiagLogs) {
        debugPrint('[FaceEnrolment] avatar persist queue failed: $e');
      }
    }
  }

  /// Wipe the per-run frame buffer. Called on every terminal
  /// transition (done / cancelled / failed) so we don't leak temp
  /// files. Sync version is best-effort; async deletes await
  /// completion so the dir is gone before the next enrolment.
  Future<void> _teardownFrames() async {
    final dir = _frameDir;
    _frameDir = null;
    _capturedFramePaths.clear();
    if (dir == null) return;
    try {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (e) {
      if (_kDiagLogs) {
        debugPrint('[FaceEnrolment] frame teardown failed: $e');
      }
    }
  }

  // ── State plumbing ──────────────────────────────────────────────────────

  void _setState(FaceEnrolmentState next) {
    if (_state == next) return;
    _state = next;
    if (_kDiagLogs) {
      debugPrint('[FaceEnrolment] state → $next');
    }
    notifyListeners();
  }

  void _emitError(FaceEnrolmentError err) {
    _error = err;
    _state = FaceEnrolmentState.failed;
    _instructionText = null;
    // Capture timer + temp frames go away before the listener fires
    // so the next start (after a Retry) sees a clean slate.
    _captureTimer?.cancel();
    _captureTimer = null;
    // M37 — tear down the live pose sub + stall timer too.
    _poseSub?.cancel();
    _poseSub = null;
    _stallTimer?.cancel();
    _stallTimer = null;
    // Don't await teardown — error UI pops 4s later; if we leak a few
    // frames in the meantime that's acceptable.
    unawaited(_teardownFrames());
    if (_kDiagLogs) {
      debugPrint('[FaceEnrolment] error → ${err.type}: ${err.message}');
    }
    if (!_errorController.isClosed) {
      _errorController.add(err);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _captureTimer?.cancel();
    _poseSub?.cancel();
    _stallTimer?.cancel();
    _errorController.close();
    _rejectionController.close();
    // Don't await — dispose is sync. Best-effort cleanup.
    unawaited(_teardownFrames());
    super.dispose();
  }
}

/// State machine for [FaceEnrolmentService]. UI ([FaceEnrolmentScreen])
/// switches its rendered widget tree on this enum.
enum FaceEnrolmentState {
  /// Service just constructed; camera initialising. UI shows a brief
  /// "Preparing camera" spinner. Auto-trigger [startSweep] once the
  /// camera reports ready.
  idle,

  /// Yaw sweep in progress — instruction "Slowly turn your head from
  /// left to right". Frames captured at ~4Hz.
  sweepingYaw,

  /// Pitch sweep in progress — instruction "Now look up, then down".
  /// Frames captured at ~4Hz.
  sweepingPitch,

  /// Sweep complete; running native MobileFaceNet pass on the
  /// captured buffer. UI shows the ring at 100% + "Almost there"
  /// label.
  embedding,

  /// Native returned a slot bundle; UI shows the confirm view with
  /// the picked thumbnails + Done button.
  confirming,

  /// User tapped Done; local + cloud writes in flight.
  persisting,

  /// Terminal — enrolment succeeded. UI pops back to client detail.
  done,

  /// Terminal — user cancelled. UI pops back without changes.
  cancelled,

  /// Terminal — something went wrong; [FaceEnrolmentService.error]
  /// carries the type + message. UI shows the inline toast for 4s
  /// then pops.
  failed,
}

/// One picked slot from the native enrolment pass. Bound to the
/// confirm view's horizontal thumbnail row.
@immutable
class FaceEnrolmentSlot {
  /// 0-based slot ordinal.
  final int slotIndex;

  /// 2048-byte MobileFaceNet embedding (512 FP32 LE floats).
  final Uint8List embedding;

  /// True for exactly one slot — the most-frontal frame. Used as the
  /// avatar JPG source (or the default-selected cell in the Phase 2
  /// manual-avatar-selection grid).
  final bool isFrontalPick;

  /// Estimated yaw angle (DEGREES) of the picked frame. Phase 2: the
  /// pose-gated sweep stores degrees here directly (not radians) to
  /// match the bucket-centre math in [PoseBucket.centerDeg]. Older
  /// Wave-D native builds returned radians; the Phase 2 sweep
  /// converts at the call site so this field is always degrees going
  /// forward. Nullable for back-compat.
  final double? poseYaw;

  /// Estimated pitch angle (DEGREES). See [poseYaw] for units.
  final double? posePitch;

  /// Bucket this slot was snapped to during the pose-gated sweep.
  /// Phase 2 addition; null for legacy single-pass slots.
  final PoseBucket? bucket;

  /// Composite quality score (0-100) for this slot as accepted by the
  /// sweep loop. Phase 2 addition; null for legacy slots.
  final double? qualityScore;

  /// Local file path to the captured frame this slot came from.
  /// Phase 2 addition — the manual-avatar-selection grid needs to
  /// render the actual face crop per cell, which requires knowing the
  /// source file (the legacy proportional-mapping approximation in
  /// `_resolveCapturedPath` is no longer sufficient when the user can
  /// pick any cell as the avatar). Null for legacy slots.
  final String? sourceFramePath;

  const FaceEnrolmentSlot({
    required this.slotIndex,
    required this.embedding,
    required this.isFrontalPick,
    this.poseYaw,
    this.posePitch,
    this.bucket,
    this.qualityScore,
    this.sourceFramePath,
  });

  FaceEnrolmentSlot copyWith({
    int? slotIndex,
    Uint8List? embedding,
    bool? isFrontalPick,
    double? poseYaw,
    double? posePitch,
    PoseBucket? bucket,
    double? qualityScore,
    String? sourceFramePath,
  }) {
    return FaceEnrolmentSlot(
      slotIndex: slotIndex ?? this.slotIndex,
      embedding: embedding ?? this.embedding,
      isFrontalPick: isFrontalPick ?? this.isFrontalPick,
      poseYaw: poseYaw ?? this.poseYaw,
      posePitch: posePitch ?? this.posePitch,
      bucket: bucket ?? this.bucket,
      qualityScore: qualityScore ?? this.qualityScore,
      sourceFramePath: sourceFramePath ?? this.sourceFramePath,
    );
  }
}

/// Internal record returned by `_scoreCandidate`. Bundles the
/// per-component values + the composite so the diag log can dump
/// all of them on a rejection.
@immutable
class _CandidateScoreComponents {
  final double visionConfidence;
  final double sharpness;
  final double lighting;
  final double poseUniqueness;
  final double normPenalty;
  final double composite;

  const _CandidateScoreComponents({
    required this.visionConfidence,
    required this.sharpness,
    required this.lighting,
    required this.poseUniqueness,
    required this.normPenalty,
    required this.composite,
  });
}

/// Phase 2 rejection event surfaced to the UI as the reject toast.
/// Per Carl's mockup signoff (open question 2), the toast shows the
/// RAW SCORE so practitioners learn what's failing — soft copy like
/// "Move into better light" wins on warmth but loses on calibration.
@immutable
class FaceEnrolmentRejection {
  /// Composite 0-100 score that fell below [kQualityThreshold]. Null
  /// when the rejection was for pose-similarity rather than quality
  /// (the toast then shows a generic "too similar to existing" copy).
  final double? score;

  /// True when the rejection reason was "candidate pose too close to
  /// an already-captured slot". False = quality threshold breach.
  final bool poseDuplicate;

  const FaceEnrolmentRejection({
    this.score,
    this.poseDuplicate = false,
  });
}

/// Error envelope for inline toast surfacing.
@immutable
class FaceEnrolmentError {
  final FaceEnrolmentErrorType type;
  final String message;

  const FaceEnrolmentError({
    required this.type,
    required this.message,
  });
}

/// Discriminates between "user-facing nudge" errors (notEnoughAngles —
/// asks the user to retry) and "infrastructure" errors (camera, io —
/// surfaces a generic apology).
enum FaceEnrolmentErrorType {
  /// Native returned fewer than the hard minimum slots. UI shows the
  /// retry-with-clearer-pose nudge.
  notEnoughAngles,

  /// Native MobileFaceNet pass failed (model load, timeout, platform
  /// exception). UI shows the message + auto-pops.
  embeddingFailed,

  /// Camera plugin failed to initialise OR the screen forgot to wire
  /// the frame producer.
  camera,

  /// SQLite write or temp dir create failed. Rare; surface verbatim
  /// so we can diagnose from Carl's screenshot.
  io,
}
