import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../config.dart';
import 'api_client.dart';
import 'safe_mode.dart'
    show kSafeModeAlgorithmVersion, kSelfFaceEmbeddingFloats;
import 'sync_service.dart';

/// Diagnostics gate for hydration-path debug prints (2026-05-24).
/// Enabled in debug builds and on staging profile builds so Carl can
/// follow the cold-start hydration sequence in Console.app. Stays OFF
/// in prod release builds to avoid spew.
bool get _kDiagLogs => kDebugMode || AppConfig.env == 'staging';

/// Safe Mode v2 (2026-05-23) — manages the MobileFaceNet biometric
/// embedding for each client.
///
/// The embedding is a 512-D float vector (~2048 bytes) derived
/// ON-DEVICE from the client's avatar JPG via the native iOS
/// `generateFaceEmbedding` platform-channel method. The raw image
/// never leaves the device in a form that can be reverse-engineered
/// into an identifying photo; only the vector ships to Supabase.
///
/// The native pipeline uses this vector at capture time to identify
/// the subject (highest cosine similarity ≥ threshold) vs. bystanders
/// (everyone else) — the same Vision person-segmentation pass paints
/// every non-subject silhouette coral.
///
/// Lifecycle:
///   1. Practitioner toggles "Face recognition for Safe Mode" on for a
///      client (in the consent sheet) OR engages Safe Mode in the
///      camera with a client who lacks an embedding.
///   2. Service checks SQLite for an existing embedding (via the
///      `face_embedding` column added by the schema sibling PR).
///   3. If missing: resolves the avatar JPG (local copy → signed URL
///      download), calls the native `generateFaceEmbedding`, persists
///      via `set_client_face_embedding` RPC, updates state to ready.
///   4. The capture screen reads [stateFor] to gate the capture
///      buttons + show the inline-capture-flow banner when ready,
///      block on loading, surface the error message on failure.
///
/// Hard-fails (per `feedback_no_silent_fallbacks`):
///   - avatar file missing locally AND no avatar_path on the client
///   - native call throws (model load failure, zero faces, multiple
///     ambiguous faces)
///   - persistence RPC fails
///
/// Errors propagate to UI as [EmbeddingState.error] with a
/// practitioner-readable message. No "best-effort" fallback to v1.
class FaceEmbeddingService extends ChangeNotifier {
  FaceEmbeddingService._();

  static final FaceEmbeddingService instance = FaceEmbeddingService._();

  /// Same native channel as the conversion service — the
  /// `generateFaceEmbedding` method lives there (added by the native
  /// sibling PR; until then platform-channel calls return
  /// `MissingPluginException` → caught and surfaced as `error`).
  static const _videoChannel = MethodChannel('com.raidme.video_converter');

  /// Self-trainer wave PR #3 (2026-05-25) — dedicated platform channel
  /// for the self-verification flow. Wraps the same
  /// MobileFaceNetEmbedder singleton used by Safe Mode v2 client
  /// enrolment, but with a simpler image-path → float-list surface (no
  /// hard-fail on multi-face, returns null on no-face instead of
  /// throwing). See `app/ios/Runner/HomefitFaceEmbeddingChannel.swift`.
  static const _selfFaceChannel = MethodChannel(
    'studio.homefit.face_embedding',
  );

  /// Per-client embedding state. UI watches via [stateFor].
  final Map<String, EmbeddingState> _states = <String, EmbeddingState>{};

  /// In-flight generation tasks keyed by clientId so [ensureForClient]
  /// is idempotent under rapid re-entry (e.g. the consent toggle fires
  /// alongside a camera mount that also wants the embedding).
  final Map<String, Future<void>> _inflight = <String, Future<void>>{};

  /// Get the current state for a client. Returns
  /// [EmbeddingState.notNeeded] when the service has not yet been
  /// queried for this client — callers decide whether that means
  /// "block capture and prompt for avatar" or "let it slide" based on
  /// the client's `safeModeFaceRecognitionAllowed` consent.
  EmbeddingState stateFor(String clientId) {
    return _states[clientId] ?? EmbeddingState.notNeeded;
  }

  /// Reset the cached state for a client. Called when the consent
  /// toggle flips OFF (server zeroed the embedding) or when the
  /// practitioner cancels the inline capture flow without setting a
  /// face — the next engagement should re-evaluate, not reuse stale
  /// state.
  void resetFor(String clientId) {
    _states.remove(clientId);
    notifyListeners();
  }

  /// Ensure an embedding exists for [clientId]. Idempotent —
  /// repeated calls reuse the in-flight Future if one is already
  /// running.
  ///
  /// Flow:
  ///   1. Mark loading.
  ///   2. Resolve the avatar JPG file path (local cache hit, or
  ///      download from the signed URL into a temp file).
  ///   3. Call native `generateFaceEmbedding(srcPath)`.
  ///   4. Persist the returned bytes via
  ///      [ApiClient.setClientFaceEmbedding].
  ///   5. Mark ready.
  ///
  /// Failures hard-fail to [EmbeddingState.error]. The capture screen
  /// surfaces the message verbatim and exposes a Retry CTA.
  Future<void> ensureForClient(String clientId) {
    final existing = _inflight[clientId];
    if (existing != null) return existing;
    final fut = _runEnsure(clientId).whenComplete(() {
      _inflight.remove(clientId);
    });
    _inflight[clientId] = fut;
    return fut;
  }

  Future<void> _runEnsure(String clientId) async {
    _setState(clientId, const EmbeddingState.loading());

    try {
      // Step 1: resolve the avatar JPG to a local path.
      final avatarLocalPath = await _resolveAvatarPath(clientId);
      if (avatarLocalPath == null) {
        _setState(
          clientId,
          const EmbeddingState.error(
            "No avatar set yet — capture a reference photo first.",
          ),
        );
        return;
      }

      // Step 2: invoke the native pipeline.
      final dynamic raw = await _videoChannel
          .invokeMethod<Object?>(
            'generateFaceEmbedding',
            <String, dynamic>{'srcPath': avatarLocalPath},
          )
          .timeout(const Duration(seconds: 15));

      if (raw == null) {
        _setState(
          clientId,
          const EmbeddingState.error(
            "Face recognition couldn't read this avatar — try a clearer photo.",
          ),
        );
        return;
      }

      final Uint8List? bytes = _decodeEmbedding(raw);
      if (bytes == null || bytes.isEmpty) {
        _setState(
          clientId,
          const EmbeddingState.error(
            "Face recognition returned an empty fingerprint — try a clearer photo.",
          ),
        );
        return;
      }

      // Step 3: persist to Supabase.
      final ok = await ApiClient.instance.setClientFaceEmbedding(
        clientId: clientId,
        embedding: bytes,
        modelVersion: kSafeModeAlgorithmVersion,
      );
      if (!ok) {
        _setState(
          clientId,
          const EmbeddingState.error(
            "Couldn't save the face fingerprint — check connection and retry.",
          ),
        );
        return;
      }

      // Persist to local SQLite so cold-start hydration via
      // _refreshCachedClient finds the bytes immediately. Without this,
      // a force-quit between enrolment and the next SyncService._pullClients
      // run would re-show the "Prepare a face fingerprint" CTA on next
      // launch (PR #461 covered the read side only).
      try {
        await SyncService.instance.storage.updateClientFaceEmbedding(
          clientId: clientId,
          embedding: bytes,
          modelVersion: kSafeModeAlgorithmVersion,
        );
        if (_kDiagLogs) {
          debugPrint(
            '[FaceEmbeddingService] local SQLite write succeeded for '
            'client=$clientId, bytes=${bytes.length}',
          );
        }
      } catch (e) {
        // Diagnostics: this catch is normally invisible — the only signal
        // is the next-launch CTA returning. Always log the exception type
        // + message so Console.app shows the real failure.
        debugPrint(
          '[FaceEmbeddingService] local SQLite write FAILED for '
          'client=$clientId, bytes=${bytes.length}, '
          'error=${e.runtimeType}: $e',
        );
      }

      _setState(clientId, EmbeddingState.ready(bytes));
    } on PlatformException catch (e) {
      // Surface native error codes verbatim — they encode the failure
      // reason (model load failure, zero faces, multiple ambiguous
      // faces).
      final msg = e.message?.trim().isNotEmpty == true
          ? e.message!.trim()
          : 'Face recognition failed (${e.code}).';
      _setState(clientId, EmbeddingState.error(msg));
    } on MissingPluginException catch (_) {
      _setState(
        clientId,
        const EmbeddingState.error(
          'Face recognition not available in this build.',
        ),
      );
    } on TimeoutException catch (_) {
      _setState(
        clientId,
        const EmbeddingState.error(
          'Face recognition timed out — try again.',
        ),
      );
    } catch (e) {
      _setState(clientId, EmbeddingState.error('Face recognition failed: $e'));
    }
  }

  /// Look up the bytes for [clientId] without triggering generation.
  /// Returns the in-memory copy when the state is [EmbeddingState.ready],
  /// null otherwise. Callers needing on-disk persistence read
  /// `clients.face_embedding` via SQLite (added by the schema PR).
  Uint8List? getEmbedding(String clientId) {
    final s = _states[clientId];
    if (s is _ReadyEmbeddingState) return s.bytes;
    return null;
  }

  /// Self-trainer wave PR #3 (2026-05-25) — compute a one-shot
  /// MobileFaceNet embedding for the supplied image (the practitioner's
  /// own self-reference selfie). Returns the 512-d float vector ready
  /// to ship to the `register_self_face` RPC, or `null` when no face
  /// could be detected in the image.
  ///
  /// Unlike [ensureForClient], this method does NOT touch [_states] —
  /// it's a stateless one-shot compute that the Settings → Public
  /// profile flow invokes immediately before calling
  /// [ApiClient.registerSelfFace]. There's no per-client state to
  /// reuse; the practitioner-embedding lives in
  /// `practitioners.face_embedding`, not `clients.face_embedding`.
  ///
  /// Failure mode contract:
  ///   - File missing / decode failure / Vision pipeline failure /
  ///     MobileFaceNet load or inference failure → THROWS the
  ///     [PlatformException] verbatim so the caller can surface the
  ///     native error code (per `feedback_no_silent_fallbacks`).
  ///   - No face detected in the image → returns `null`. This is a
  ///     benign outcome — the UI prompts the user to retake the photo.
  ///
  /// The 15-second timeout matches [ensureForClient]'s — the embed
  /// itself is ~50ms on Neural Engine; the Vision pass + JPEG decode
  /// on a 12 MP HEIC can stretch to a couple of seconds. Anything past
  /// 15s indicates a stuck native call worth surfacing.
  Future<List<double>?> computeForImage(String imagePath) async {
    final dynamic raw = await _selfFaceChannel
        .invokeMethod<Object?>(
          'computeEmbeddingForImage',
          <String, dynamic>{'imagePath': imagePath},
        )
        .timeout(const Duration(seconds: 15));

    // Native returns nil on no-face. The Flutter channel boundary
    // surfaces nil as a Dart null — we treat it as a benign "no face"
    // outcome and return null to the caller, matching the brief's
    // contract ("Returns null on no-face (does not throw)").
    if (raw == null) {
      if (_kDiagLogs) {
        debugPrint(
          '[FaceEmbeddingService] computeForImage: no face in $imagePath',
        );
      }
      return null;
    }

    // The native side encodes the embedding as a `[Float]` which the
    // Flutter codec delivers as a `List<double>` (Float32 widened to
    // Dart's double). Accept the broad `List` shape for forward-compat
    // and coerce element-wise.
    if (raw is List) {
      final out = <double>[];
      for (final v in raw) {
        if (v is double) {
          out.add(v);
        } else if (v is num) {
          out.add(v.toDouble());
        } else {
          // Mixed-shape list — refuse to silently fudge. Surface a
          // diagnostic and treat as a no-face outcome (caller will
          // prompt for a retake; the cause will be in the Console.app
          // log line).
          debugPrint(
            '[FaceEmbeddingService] computeForImage: unexpected element '
            'type ${v.runtimeType} in result list',
          );
          return null;
        }
      }
      // R5-M1 — dimension assertion. MobileFaceNet emits exactly
      // [kSelfFaceEmbeddingFloats] (512) floats. A mismatch indicates
      // either a corrupted native response or an upstream API change
      // we missed; both are "unknown" failures per
      // `feedback_no_silent_fallbacks`, not silent successes. Refuse
      // to return a partial embedding — the caller treats null as
      // "no face / unknown" and prompts a retake.
      if (out.length != kSelfFaceEmbeddingFloats) {
        debugPrint(
          '[FaceEmbeddingService] computeForImage: dim mismatch — '
          'got ${out.length} floats, expected $kSelfFaceEmbeddingFloats '
          '(rejecting result for $imagePath)',
        );
        return null;
      }
      if (_kDiagLogs) {
        debugPrint(
          '[FaceEmbeddingService] computeForImage: '
          'got ${out.length} floats from $imagePath',
        );
      }
      return out;
    }

    // Unrecognised shape. Refuse to silently fudge — return null so
    // the caller treats it as no-face (and the debug log surfaces the
    // real shape).
    debugPrint(
      '[FaceEmbeddingService] computeForImage: unexpected result type '
      '${raw.runtimeType}',
    );
    return null;
  }

  /// Self-trainer wave PR #5 (2026-05-25) — run the on-device
  /// MobileFaceNet pipeline against [mediaPath] (an mp4/mov/m4v video
  /// OR a jpg/jpeg/png/heic photo) and compare against [reference] (the
  /// caller's own face embedding, read from
  /// `practitioners.face_embedding` via [ApiClient.getMySelfFaceEmbedding]).
  ///
  /// Returns a [SelfVerificationOutcome] describing whether the subject
  /// matched and the cosine distance (1.0 - similarity) for diagnostics.
  ///
  /// Failure modes (per `feedback_no_silent_fallbacks` — never silently
  /// fudge into a false-positive verification):
  ///   * `noFace` outcome — the native pipeline detected zero faces in
  ///     any sampled frame. Conversion service treats this as
  ///     `self_verified = false` (conservative).
  ///   * `error` outcome — file missing, decode failure, embedder load
  ///     failure, RPC timeout. The conversion service likewise stamps
  ///     `self_verified = false` so unknown defaults to "not verified".
  ///
  /// The 30-second timeout is sized for a worst-case 3-frame video
  /// sweep on a cold model + cold AVAssetReader; typical run is ~200ms.
  /// Anything over 30s indicates a stuck native call worth surfacing.
  Future<SelfVerificationOutcome> verifyAgainstReference({
    required String mediaPath,
    required List<double> reference,
  }) async {
    try {
      final dynamic raw = await _selfFaceChannel
          .invokeMethod<Object?>(
            'verifyAgainstReference',
            <String, dynamic>{
              'mediaPath': mediaPath,
              'referenceEmbedding': reference,
            },
          )
          .timeout(const Duration(seconds: 30));

      if (raw is! Map) {
        debugPrint(
          '[FaceEmbeddingService] verifyAgainstReference: unexpected '
          'result shape ${raw.runtimeType} for $mediaPath',
        );
        return const SelfVerificationOutcome.error(
          'Unexpected native result shape',
        );
      }
      final map = Map<dynamic, dynamic>.from(raw);
      final noFace = map['noFace'] == true;
      if (noFace) {
        if (_kDiagLogs) {
          debugPrint(
            '[FaceEmbeddingService] verifyAgainstReference: noFace '
            'outcome for $mediaPath',
          );
        }
        return const SelfVerificationOutcome.noFace();
      }
      final matched = map['matched'] == true;
      final distRaw = map['distance'];
      final double? distance = distRaw is num ? distRaw.toDouble() : null;
      if (_kDiagLogs) {
        debugPrint(
          '[FaceEmbeddingService] verifyAgainstReference: '
          'matched=$matched distance=$distance for $mediaPath',
        );
      }
      return SelfVerificationOutcome.checked(
        matched: matched,
        distance: distance,
      );
    } on PlatformException catch (e) {
      final msg = e.message?.trim().isNotEmpty == true
          ? e.message!.trim()
          : 'Self-verification failed (${e.code}).';
      debugPrint(
        '[FaceEmbeddingService] verifyAgainstReference PlatformException: '
        '$msg for $mediaPath',
      );
      return SelfVerificationOutcome.error(msg);
    } on MissingPluginException catch (_) {
      return const SelfVerificationOutcome.error(
        'Self-verification channel not registered',
      );
    } on TimeoutException catch (_) {
      return const SelfVerificationOutcome.error(
        'Self-verification timed out',
      );
    } catch (e) {
      return SelfVerificationOutcome.error('Self-verification failed: $e');
    }
  }

  /// Cold-start rehydration entry point. Callers that already have the
  /// embedding bytes from local SQLite (`cached_clients.face_embedding`)
  /// can prime the in-memory state without re-running the native
  /// generation pipeline.
  ///
  /// No-op if the state is already ready / loading / errored — never
  /// downgrades an in-flight or successful state. Empty byte buffers are
  /// ignored.
  void hydrateFromBytes(String clientId, Uint8List bytes) {
    if (_kDiagLogs) {
      debugPrint(
        '[FaceEmbeddingService] hydrateFromBytes called: '
        'cid=$clientId bytes=${bytes.length}',
      );
    }
    if (bytes.isEmpty) return;
    final existing = _states[clientId];
    if (existing != null &&
        (existing.isReady || existing.isLoading || existing.isError)) {
      if (_kDiagLogs) {
        debugPrint(
          '[FaceEmbeddingService] hydrateFromBytes skipped — already in '
          'state=${existing.runtimeType} for cid=$clientId',
        );
      }
      return;
    }
    _setState(clientId, EmbeddingState.ready(bytes));
    if (_kDiagLogs) {
      debugPrint(
        '[FaceEmbeddingService] hydrateFromBytes promoted state to '
        'ready for cid=$clientId',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  Future<String?> _resolveAvatarPath(String clientId) async {
    final cached =
        await SyncService.instance.storage.getCachedClientById(clientId);
    if (cached == null) return null;
    final avatarPath = cached.avatarPath;
    if (avatarPath == null || avatarPath.isEmpty) return null;

    // Step 1: try the local body-focus avatar PNG written by the
    // multi-reference enrolment flow (FaceEnrolmentService._writeFrontalAvatar).
    // The local file ALWAYS lives at `{docs}/avatars/{clientId}.png`
    // regardless of the cloud-side `avatarPath` shape (which is
    // `{practiceId}/{clientId}/avatar.png` to match the bucket policy).
    // Earlier versions joined docsDir + avatarPath here, which never
    // hit the actual file and always fell through to the cloud
    // signed-URL fallback. Diagnosed 2026-05-23.
    final docsDir = await getApplicationDocumentsDirectory();
    final canonicalLocal = File(
      p.join(docsDir.path, 'avatars', '$clientId.png'),
    );
    if (await canonicalLocal.exists()) {
      return canonicalLocal.path;
    }
    // Defensive: if a future avatar-save path ever writes the cloud-
    // shaped layout under docs/ directly, prefer that file. Cheap to
    // check; not load-bearing.
    final legacyLocal = File(p.join(docsDir.path, avatarPath));
    if (await legacyLocal.exists()) {
      return legacyLocal.path;
    }

    // Step 2: fall back to a signed-URL download. Best-effort — if
    // signing fails we hard-fail the ensure() flow.
    try {
      final signed = await ApiClient.instance.signClientAvatarUrl(
        avatarPath: avatarPath,
      );
      if (signed == null) return null;
      final client = HttpClient();
      try {
        final req = await client.getUrl(Uri.parse(signed));
        final resp = await req.close();
        if (resp.statusCode != 200) return null;
        final tmpDir = await getTemporaryDirectory();
        final tmpFile = File(
          p.join(tmpDir.path, 'face_avatar_$clientId.jpg'),
        );
        final sink = tmpFile.openWrite();
        await resp.pipe(sink);
        return tmpFile.path;
      } finally {
        client.close(force: true);
      }
    } catch (e) {
      debugPrint('FaceEmbeddingService._resolveAvatarPath failed: $e');
      return null;
    }
  }

  /// Native channel returns either raw bytes (Uint8List) or a Map with
  /// an `embedding` key (Uint8List or `List&lt;int&gt;`). Normalise here.
  Uint8List? _decodeEmbedding(Object raw) {
    if (raw is Uint8List) return raw;
    if (raw is List<int>) return Uint8List.fromList(raw);
    if (raw is Map) {
      final dynamic emb = raw['embedding'];
      if (emb is Uint8List) return emb;
      if (emb is List<int>) return Uint8List.fromList(emb);
    }
    return null;
  }

  void _setState(String clientId, EmbeddingState next) {
    _states[clientId] = next;
    notifyListeners();
  }
}

/// State for a single client's biometric embedding lifecycle.
@immutable
abstract class EmbeddingState {
  const EmbeddingState._();

  /// The client has not been queried yet, OR the consent flag is
  /// false and there's nothing to generate. UI decides whether to
  /// trigger [FaceEmbeddingService.ensureForClient] based on consent.
  static const EmbeddingState notNeeded = _NotNeededEmbeddingState();

  /// A generation is in flight. UI disables capture and shows a
  /// "Preparing Safe Mode…" banner with a spinner.
  const factory EmbeddingState.loading() = _LoadingEmbeddingState;

  /// An embedding exists. UI enables capture normally.
  const factory EmbeddingState.ready(Uint8List bytes) =
      _ReadyEmbeddingState;

  /// Generation failed. UI disables capture and shows the message
  /// with a Retry CTA. Hard-fail per `feedback_no_silent_fallbacks` —
  /// the practitioner must take action.
  const factory EmbeddingState.error(String message) =
      _ErrorEmbeddingState;

  /// True iff this state represents a successful, ready-to-use
  /// embedding.
  bool get isReady => this is _ReadyEmbeddingState;

  /// True iff this state represents an in-flight generation.
  bool get isLoading => this is _LoadingEmbeddingState;

  /// True iff this state represents an error.
  bool get isError => this is _ErrorEmbeddingState;

  /// True iff no embedding work has been done yet for this client.
  bool get isNotNeeded => this is _NotNeededEmbeddingState;

  /// Practitioner-readable error message, or null when not in error.
  String? get errorMessage =>
      this is _ErrorEmbeddingState
          ? (this as _ErrorEmbeddingState).message
          : null;
}

class _NotNeededEmbeddingState extends EmbeddingState {
  const _NotNeededEmbeddingState() : super._();
}

class _LoadingEmbeddingState extends EmbeddingState {
  const _LoadingEmbeddingState() : super._();
}

class _ReadyEmbeddingState extends EmbeddingState {
  final Uint8List bytes;
  const _ReadyEmbeddingState(this.bytes) : super._();
}

class _ErrorEmbeddingState extends EmbeddingState {
  final String message;
  const _ErrorEmbeddingState(this.message) : super._();
}

/// Self-trainer wave PR #5 (2026-05-25) — outcome of a
/// capture-time self-verification compare run via
/// [FaceEmbeddingService.verifyAgainstReference].
///
/// Three variants:
///   * `checked`  — the native pipeline produced a result (faces were
///                  detected and the embedding compared). [matched]
///                  reflects whether the cosine similarity met the
///                  threshold; [distance] is the cosine distance
///                  (1 - sim) for diagnostics.
///   * `noFace`   — no face was detected in any sampled frame. Benign
///                  outcome (e.g. gym-equipment photo). The conversion
///                  service stamps `self_verified = false`.
///   * `error`    — file missing / decode failure / embedder load
///                  failure / RPC timeout. The conversion service
///                  likewise stamps `self_verified = false` so unknown
///                  defaults to "not verified". [message] surfaces the
///                  native error code for Console.app log inspection.
@immutable
class SelfVerificationOutcome {
  final bool _checked;
  final bool _matched;
  final double? distance;
  final bool _noFace;
  final String? errorMessage;

  const SelfVerificationOutcome._({
    required bool checked,
    required bool matched,
    required this.distance,
    required bool noFace,
    required this.errorMessage,
  })  : _checked = checked,
        _matched = matched,
        _noFace = noFace;

  const factory SelfVerificationOutcome.checked({
    required bool matched,
    required double? distance,
  }) = _CheckedSelfVerificationOutcome;

  const factory SelfVerificationOutcome.noFace() =
      _NoFaceSelfVerificationOutcome;

  const factory SelfVerificationOutcome.error(String message) =
      _ErrorSelfVerificationOutcome;

  /// True iff the pipeline ran and matched the registered self.
  bool get matched => _checked && _matched;

  /// True iff no face was detected in any sampled frame.
  bool get isNoFace => _noFace;

  /// True iff the pipeline failed (hard error).
  bool get isError => errorMessage != null;

  /// Resolve the tri-state value to stamp on
  /// `exercises.self_verified`. Per the brief: NULL is reserved for
  /// "compare was not attempted" (e.g. no reference embedding). Once
  /// the compare has actually run we stamp true/false explicitly —
  /// `noFace` and `error` both resolve to false (conservative).
  bool get verifiedValue => matched;
}

class _CheckedSelfVerificationOutcome extends SelfVerificationOutcome {
  const _CheckedSelfVerificationOutcome({
    required super.matched,
    required super.distance,
  }) : super._(
          checked: true,
          noFace: false,
          errorMessage: null,
        );
}

class _NoFaceSelfVerificationOutcome extends SelfVerificationOutcome {
  const _NoFaceSelfVerificationOutcome()
      : super._(
          checked: true,
          matched: false,
          distance: null,
          noFace: true,
          errorMessage: null,
        );
}

class _ErrorSelfVerificationOutcome extends SelfVerificationOutcome {
  const _ErrorSelfVerificationOutcome(String message)
      : super._(
          checked: false,
          matched: false,
          distance: null,
          noFace: false,
          errorMessage: message,
        );
}
