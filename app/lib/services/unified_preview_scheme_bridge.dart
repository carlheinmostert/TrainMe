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
///     A `get_plan_full`-shaped envelope built from local SQLite.
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
      'circuit_names': session.circuitNames.map((k, v) => MapEntry(k, v)),
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
    if (kind != 'line' &&
        kind != 'archive' &&
        kind != 'segmented' &&
        kind != 'hero' &&
        kind != 'hero_color' &&
        kind != 'hero_line') {
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
      case 'hero':
        // The on-device Hero JPG produced by Wave Hero Crop (PR #218).
        // Used as the static <img src> poster for inactive lobby rows
        // post-PR-#255 (which strictly forbids video URLs in <img src>).
        relative = exercise.thumbnailPath;
        break;
      case 'hero_color':
        // Wave Three-Treatment-Thumbs (2026-05-05) — color frame from
        // raw, used by B&W + Original treatments via CSS filter.
        // Convention: same dir as thumbnailPath, `_thumb.jpg` suffix
        // swapped for `_thumb_color.jpg`. Native conversion
        // (conversion_service.dart line 253) writes both lockstep.
        if (exercise.thumbnailPath != null) {
          relative = exercise.thumbnailPath!
              .replaceFirst('_thumb.jpg', '_thumb_color.jpg');
        }
        break;
      case 'hero_line':
        // Wave Three-Treatment-Thumbs — line drawing JPG from the
        // converted line video, used by Line treatment.
        if (exercise.thumbnailPath != null) {
          relative = exercise.thumbnailPath!
              .replaceFirst('_thumb.jpg', '_thumb_line.jpg');
        }
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
  // Payload builders — shape-identical to the server-side `get_plan_full`
  // (milestone G) so the bundled web-player code has a single JSON
  // contract across the live and embedded surfaces.
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

    // Per-set PLAN wave — emit the nested `sets` array shape that the
    // web-player bundle now consumes (matching `get_plan_full`'s
    // server-side response). Each set carries the per-row fields the
    // bundle uses for the PLAN table + rep-stack timing.
    final setsJson = e.sets
        .map((s) => <String, dynamic>{
              'position': s.position,
              'reps': s.reps,
              'hold_seconds': s.holdSeconds,
              'weight_kg': s.weightKg,
              'breather_seconds_after': s.breatherSecondsAfter,
            })
        .toList(growable: false);

    return {
      'id': e.id,
      'plan_id': e.sessionId,
      'position': e.position,
      'name': e.name,
      'media_url': lineUrl,
      // The on-device Hero JPG (Wave Hero Crop, PR #218). Wired post
      // PR #255 — the lobby's <img src> must be a real image URL, never
      // a video URL (iOS WKWebView animates mp4 in <img> and burns HW
      // decoders invisibly). NULL when no thumbnail has been produced
      // yet — the lobby falls back to a skeleton placeholder.
      'thumbnail_url': (e.thumbnailPath != null && e.thumbnailPath!.isNotEmpty)
          ? '/local/${e.id}/hero'
          : null,
      // Wave Three-Treatment-Thumbs (2026-05-05) — line + color
      // variants from native conversion. Bridge route serves them via
      // the homefit-local:// scheme; web player picks based on
      // active treatment. Practitioner-side preview, so file-presence
      // gating only — consent doesn't apply (the file's on-device).
      'thumbnail_url_line':
          (e.thumbnailPath != null && e.thumbnailPath!.isNotEmpty)
              ? '/local/${e.id}/hero_line'
              : null,
      'thumbnail_url_color':
          (e.thumbnailPath != null && e.thumbnailPath!.isNotEmpty)
              ? '/local/${e.id}/hero_color'
              : null,
      'media_type': e.mediaType.name,
      'sets': setsJson,
      'notes': e.notes,
      'circuit_id': e.circuitId,
      'include_audio': e.includeAudio,
      'prep_seconds': e.prepSeconds,
      // Wave 24 — number of reps captured in the source video; the
      // bundle uses this to derive per-rep playback timing.
      'video_reps_per_loop': e.videoRepsPerLoop,
      // Wave 20 / Milestone X — soft-trim window. Both null = no trim,
      // full clip plays. Both set = the bundle clamps `<video>.currentTime`
      // to [start, end] and loops within that window.
      'start_offset_ms': e.startOffsetMs,
      'end_offset_ms': e.endOffsetMs,
      // Wave Hero — practitioner-picked Hero frame offset (ms). Drives
      // the web-player prep-phase overlay + video poster.
      'focus_frame_offset_ms': e.focusFrameOffsetMs,
      // Wave Lobby (PR 1/N) — practitioner-authored 1:1 Hero crop
      // offset, normalized 0.0..1.0 along the source media's free
      // axis. NULL = unset (consumers default to 0.5 / centred). No
      // bundle consumer reads this yet — wired for round-trip parity
      // ahead of the editor + lobby PRs.
      'hero_crop_offset': e.heroCropOffset,
      // Wave 28 — landscape orientation metadata.
      'aspect_ratio': e.aspectRatio,
      'rotation_quarters': e.rotationQuarters,
      // Per-set PLAN rest-fix — round-trip parity with the cloud
      // `get_plan_full` shape. Null for video/photo; positive integer
      // for media_type='rest'. The web-player bundle reads this when
      // deriving rest-card duration; mobile preview hits the same
      // bundle via the local scheme handler so parity is mandatory.
      'rest_seconds': e.restHoldSeconds,
      'preferred_treatment': e.preferredTreatment?.wireValue,
      // Wave 42 — per-exercise body-focus default (PR #146 schema).
      // Mirror the cloud `get_plan_full` shape so the embedded preview
      // matches the live web player. Without this field the web
      // player's `getEffective(exercise, 'bodyFocus')` falls back to
      // `exercise.body_focus !== false`, which evaluates `true` for
      // undefined → body-focus ON. Combined with PR #309's capture
      // default of `preferred_treatment='grayscale'`, every new
      // capture would resolve to `grayscale_segmented_url` (the
      // body-focus-blurred segmented mp4/JPG) — the regression Carl
      // flagged as QA item 8 (embedded Preview heroes blurred).
      'body_focus': e.bodyFocus,
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
