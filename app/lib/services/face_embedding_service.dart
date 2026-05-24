import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../config.dart';
import 'api_client.dart';
import 'safe_mode.dart' show kSafeModeAlgorithmVersion;
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

    // Step 1: try the local body-focus avatar PNG that the avatar
    // capture flow writes via client_avatar_capture_screen._useThis().
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
