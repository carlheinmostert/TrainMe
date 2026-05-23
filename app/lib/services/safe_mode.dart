/// Safe Mode versioning constants.
///
/// `safe_mode_algorithm_version` on the cloud `exercises` table records
/// which Safe Mode generation produced the safe variant for a given
/// capture. UI and the re-process flow gate on this — captures whose
/// stored version is below the current constant become eligible for
/// re-processing once the bytes are still available (local OR within
/// 90-day raw-archive retention).
///
/// History:
///   * v1 — anchor-box approach (largest-Vision-bbox = subject, paint
///     everyone else). Shipped in PR #389 + the 2026-05-21 completion
///     wave. NEVER published to prod — the failure mode was a
///     bystander whose silhouette overlapped the practitioner's chosen
///     subject getting either painted along with them or completely
///     missed. Carl's QA killed it before TestFlight.
///   * v2 — MobileFaceNet face-recognition (2026-05-23, this design).
///     Per-client biometric embedding derived from the avatar JPG;
///     native pipeline computes cosine similarity per detected face
///     and paints anyone below threshold. Designed in
///     `docs/specs/2026-05-23-safe-mode-face-rec.md`.
///
/// Bump this constant ONLY when the underlying compositing algorithm
/// changes in a way that invalidates the visual output of older
/// captures. The re-process affordance keys on `< kSafeModeAlgorithmVersion`.
const int kSafeModeAlgorithmVersion = 2;
