import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/exercise_capture.dart';
import '../models/session.dart';
import '../models/treatment.dart';
import 'local_storage_service.dart';
import 'path_resolver.dart';

/// True when an exercise's `convertedFilePath` is a still-image fallback
/// (the converter dropped to a single frame because video conversion
/// failed). Mirrors the studio-screen helper of the same name; copied
/// here to keep the bridge dependency-free.
bool _isStillImageFallback(String? path) {
  if (path == null) return false;
  final lower = path.toLowerCase();
  return lower.endsWith('.jpg') ||
      lower.endsWith('.jpeg') ||
      lower.endsWith('.png');
}

/// Wave 4 Phase 2 — Dart side of the `WKURLSchemeHandler` bridge.
///
/// The Swift handler (`UnifiedPlayerSchemeHandler.swift`) resolves
/// static assets on its own but delegates two dynamic lookups back to
/// Dart over `MethodChannel('com.raidme.unified_preview_scheme')`:
///
/// * `resolvePlanJson({ "planId": String })` → String (JSON payload)
///     Matches the shape of the Phase 1 shelf `/api/plan/<id>` route —
///     a `get_plan_full`-shaped envelope built from local SQLite.
///
/// * `resolveMediaPath({ "exerciseId": String, "kind": "line"|"archive"|"segmented" })`
///     → String (absolute file path on disk)
///     Returns the absolute path the Swift handler should stream.
///     Nullable return (empty string -> nil) signals "no file for this
///     exercise / kind".
///
/// The handler is process-scoped; it binds to a single session at a
/// time (the one currently displayed in `UnifiedPreviewScreen`). Screen
/// init calls [bind]; dispose calls [unbind]. Calling before [bind]
/// returns `FlutterError('NO_SESSION')` so the WebView can fail the
/// request cleanly.
class UnifiedPreviewSchemeBridge {
  UnifiedPreviewSchemeBridge._();
  static final UnifiedPreviewSchemeBridge instance =
      UnifiedPreviewSchemeBridge._();

  static const MethodChannel _channel =
      MethodChannel('com.raidme.unified_preview_scheme');

  Session? _session;
  LocalStorageService? _storage;
  bool _installed = false;

  /// Install the method-call handler. Safe to call repeatedly — only
  /// the first call registers. Call once at app boot, OR lazily the
  /// first time the preview screen mounts.
  void install() {
    if (_installed) return;
    _installed = true;
    _channel.setMethodCallHandler(_onMethodCall);
  }

  /// Bind to the session the preview will render. Swift invokes the
  /// resolver methods against this session until [unbind] is called
  /// (usually from `UnifiedPreviewScreen.dispose`).
  void bind({required Session session, required LocalStorageService storage}) {
    install();
    _session = session;
    _storage = storage;
  }

  void unbind() {
    _session = null;
    _storage = null;
  }

  Future<dynamic> _onMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'resolvePlanJson':
        return _resolvePlanJson(call.arguments);
      case 'resolveMediaPath':
        return _resolveMediaPath(call.arguments);
      default:
        throw MissingPluginException('Unknown method: ${call.method}');
    }
  }

  Future<String> _resolvePlanJson(dynamic args) async {
    final session = _session;
    final storage = _storage;
    if (session == null || storage == null) {
      throw PlatformException(code: 'NO_SESSION', message: 'preview not bound');
    }
    final map = args is Map ? Map<String, dynamic>.from(args) : const {};
    final requestedPlanId = map['planId'] as String?;
    if (requestedPlanId != session.id) {
      // The WebView is pinned to the bound session — defensive mismatch
      // guard rather than hitting SQLite for an arbitrary plan.
      throw PlatformException(
        code: 'PLAN_MISMATCH',
        message: 'requested $requestedPlanId, bound ${session.id}',
      );
    }
    final consent = await _resolveConsent(session.clientId);
    final exercisesJson = <Map<String, dynamic>>[];
    for (final e in session.exercises) {
      exercisesJson.add(_exerciseToPayload(e, consent));
    }
    final planJson = <String, dynamic>{
      'id': session.id,
      'client_name': session.clientName,
      'title': session.title,
      'circuit_cycles': session.circuitCycles.map((k, v) => MapEntry(k, v)),
      'preferred_rest_interval_seconds': session.preferredRestIntervalSeconds,
      'exercise_count': session.exercises.length,
      'version': session.version,
      'practice_id': session.practiceId,
      'first_opened_at': session.firstOpenedAt?.toIso8601String(),
      'last_opened_at': session.lastOpenedAt?.toIso8601String(),
      'client_id': session.clientId,
      'created_at': session.createdAt.toIso8601String(),
      'sent_at': session.sentAt?.toIso8601String(),
      'crossfade_lead_ms': session.crossfadeLeadMs,
      'crossfade_fade_ms': session.crossfadeFadeMs,
    };
    return jsonEncode({'plan': planJson, 'exercises': exercisesJson});
  }

  Future<String> _resolveMediaPath(dynamic args) async {
    final session = _session;
    if (session == null) {
      throw PlatformException(code: 'NO_SESSION', message: 'preview not bound');
    }
    final map = args is Map ? Map<String, dynamic>.from(args) : const {};
    final exerciseId = map['exerciseId'] as String?;
    final kind = map['kind'] as String?;
    if (exerciseId == null || exerciseId.isEmpty) {
      throw PlatformException(code: 'BAD_ARGS', message: 'missing exerciseId');
    }
    if (kind != 'line' && kind != 'archive' && kind != 'segmented') {
      throw PlatformException(code: 'BAD_ARGS', message: 'unknown kind $kind');
    }

    ExerciseCapture? exercise;
    for (final e in session.exercises) {
      if (e.id == exerciseId) {
        exercise = e;
        break;
      }
    }
    if (exercise == null) {
      throw PlatformException(
        code: 'NOT_FOUND',
        message: 'unknown exercise $exerciseId',
      );
    }

    String? relative;
    switch (kind) {
      case 'line':
        // Wave 32 fix — if a VIDEO's converted file is a still-image (.jpg)
        // fallback, the WebView's <video> element gets `image/jpeg` and
        // silently fails. Skip the still and fall through to rawFilePath
        // so a real video stream is served for the line treatment.
        if (exercise.mediaType == MediaType.video &&
            _isStillImageFallback(exercise.convertedFilePath)) {
          relative = exercise.rawFilePath;
        } else {
          relative = exercise.convertedFilePath ?? exercise.rawFilePath;
        }
        break;
      case 'archive':
        // Wave 36 — photos have no separate archive pipeline; the raw
        // colour JPG IS the archive surface. Videos still use the 720p
        // H.264 archive.
        if (exercise.mediaType == MediaType.photo) {
          relative = exercise.rawFilePath;
        } else {
          relative = exercise.archiveFilePath;
        }
        break;
      case 'segmented':
        // Wave 36 — same column for video segmented mp4 and photo
        // segmented JPG; consumer derives content-type from extension.
        relative = exercise.segmentedRawFilePath;
        break;
    }
    if (relative == null || relative.isEmpty) {
      dev.log(
        'no $kind file for ${exercise.mediaType.name} exercise $exerciseId '
        '(converted=${exercise.convertedFilePath} raw=${exercise.rawFilePath} '
        'archive=${exercise.archiveFilePath} segmented=${exercise.segmentedRawFilePath})',
        name: 'UnifiedPreviewSchemeBridge',
      );
      throw PlatformException(
        code: 'NOT_FOUND',
        message: 'no $kind file for exercise $exerciseId',
      );
    }
    final resolved = PathResolver.resolve(relative);
    dev.log(
      '$exerciseId/$kind → $resolved',
      name: 'UnifiedPreviewSchemeBridge',
    );
    return resolved;
  }

  // ---------------------------------------------------------------------------
  // Payload builders — shape-identical to the shelf handler so the
  // bundled web-player bundle keeps a single JSON contract across Phase
  // 1 and Phase 2 transports.
  // ---------------------------------------------------------------------------

  Future<_ConsentFlags> _resolveConsent(String? clientId) async {
    final storage = _storage;
    if (clientId == null || storage == null) return _ConsentFlags.lineOnly();
    try {
      final row = await storage.getCachedClientById(clientId);
      if (row == null) return _ConsentFlags.lineOnly();
      return _ConsentFlags(
        line: true,
        grayscale: row.grayscaleAllowed,
        original: row.colourAllowed,
      );
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[UnifiedPreviewSchemeBridge] consent resolve failed: $e\n$st');
      }
      return _ConsentFlags.lineOnly();
    }
  }

  Map<String, dynamic> _exerciseToPayload(
    ExerciseCapture e,
    _ConsentFlags consent,
  ) {
    final lineUrl =
        e.mediaType == MediaType.video || e.mediaType == MediaType.photo
            ? '/local/${e.id}/line'
            : null;
    // For videos the archive is the 720p H.264 file. For photos
    // (Wave 36) it's the raw colour JPG — no separate archive pipeline
    // for photos. The /archive route handler dispatches by mediaType.
    final archiveUrl = e.mediaType == MediaType.video && e.archiveFilePath != null
        ? '/local/${e.id}/archive'
        : (e.mediaType == MediaType.photo &&
                e.rawFilePath.isNotEmpty
            ? '/local/${e.id}/archive'
            : null);
    // Body Focus variant — segmented body-pop file written by the
    // converter. Practitioner is the viewer here, so consent is
    // implicit; gating is strictly file-presence. Wave 36 extends to
    // photos: same column, JPG suffix.
    final segmentedUrl = e.segmentedRawFilePath != null
        ? '/local/${e.id}/segmented'
        : null;

    return {
      'id': e.id,
      'plan_id': e.sessionId,
      'position': e.position,
      'name': e.name,
      'media_url': lineUrl,
      'thumbnail_url': null,
      'media_type': e.mediaType.name,
      'reps': e.reps,
      'sets': e.sets,
      'hold_seconds': e.holdSeconds,
      'notes': e.notes,
      'circuit_id': e.circuitId,
      'include_audio': e.includeAudio,
      'custom_duration_seconds': e.customDurationSeconds,
      'prep_seconds': e.prepSeconds,
      'preferred_treatment': e.preferredTreatment?.wireValue,
      'line_drawing_url': lineUrl,
      'grayscale_url':
          (consent.grayscale && archiveUrl != null) ? archiveUrl : null,
      'original_url':
          (consent.original && archiveUrl != null) ? archiveUrl : null,
      // Practitioner is the viewer — file-presence gating only.
      'grayscale_segmented_url': segmentedUrl,
      'original_segmented_url': segmentedUrl,
    };
  }
}

class _ConsentFlags {
  final bool line;
  final bool grayscale;
  final bool original;

  const _ConsentFlags({
    required this.line,
    required this.grayscale,
    required this.original,
  });

  factory _ConsentFlags.lineOnly() =>
      const _ConsentFlags(line: true, grayscale: false, original: false);
}
