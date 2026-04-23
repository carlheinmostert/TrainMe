import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;

import '../models/exercise_capture.dart';
import '../models/session.dart';
import '../models/treatment.dart';
import 'local_storage_service.dart';
import 'path_resolver.dart';

/// Wave 4 Phase 1 — unified player prototype.
///
/// An in-process HTTP server (shelf) that binds to `127.0.0.1` on an
/// ephemeral port and serves three kinds of response:
///
/// 1. The static `web-player/` bundle out of the Flutter asset store
///    (index.html, app.js, api.js, styles.css). The bundled copy lives
///    at `app/assets/web-player/` and is registered in pubspec.yaml.
///
/// 2. A shape-identical `get_plan_full` payload at
///    `GET /api/plan/<planId>` built from the local SQLite DB
///    (LocalStorageService). This lets the unmodified web-player
///    bundle render the same plan it would on session.homefit.studio,
///    but sourced from the device — no network needed.
///
/// 3. Local archived media at
///    `GET /local/<exerciseId>/line`     → converted line-drawing file
///    `GET /local/<exerciseId>/archive`  → raw archive (B&W + Original)
///
/// The server is a singleton scoped to a [UnifiedPreviewScreen]: that
/// screen calls [start] in its `initState` and [stop] in `dispose`.
/// Only one WebView consumes it at a time; starting twice returns the
/// already-bound instance.
///
/// Phase 1 is prototype-only. Phase 2 may swap the transport to
/// WKURLSchemeHandler (cuts out the TCP loopback entirely), at which
/// point this class can be deleted; the route logic will have the same
/// shape.
class LocalPlayerServer {
  LocalPlayerServer._();
  static final LocalPlayerServer instance = LocalPlayerServer._();

  HttpServer? _server;
  Session? _boundSession;
  LocalStorageService? _storage;

  /// Port the server is currently bound to. Throws if [start] hasn't
  /// run yet.
  int get port {
    final s = _server;
    if (s == null) {
      throw StateError('LocalPlayerServer.start() not yet called');
    }
    return s.port;
  }

  /// `true` once [start] has returned successfully.
  bool get isRunning => _server != null;

  /// Boot the server. Idempotent while the server is already running
  /// for the given [session]. If called with a different session while
  /// running, stops the existing server and rebinds.
  ///
  /// Returns the origin URL (e.g. `http://127.0.0.1:54321`) the caller
  /// hands to the `WebViewController`.
  Future<Uri> start({
    required Session session,
    required LocalStorageService storage,
  }) async {
    // Re-use if already bound to the same plan.
    if (_server != null && _boundSession?.id == session.id) {
      return _originUri();
    }
    if (_server != null) {
      await stop();
    }
    _boundSession = session;
    _storage = storage;

    final handler = const shelf.Pipeline()
        .addMiddleware(_loggerMiddleware())
        .addMiddleware(_noCacheMiddleware())
        .addHandler(_router);

    // Bind to loopback with an OS-chosen port. shared:true lets us
    // cleanly rebind on hot-restart without TIME_WAIT headaches.
    _server = await shelf_io.serve(
      handler,
      InternetAddress.loopbackIPv4,
      0,
      shared: true,
    );
    return _originUri();
  }

  /// Tear down the server. Safe to call when not running.
  Future<void> stop() async {
    final s = _server;
    _server = null;
    _boundSession = null;
    _storage = null;
    if (s != null) {
      await s.close(force: true);
    }
  }

  Uri _originUri() {
    final s = _server!;
    return Uri(
      scheme: 'http',
      host: s.address.address,
      port: s.port,
    );
  }

  /// Build the full URL to hand the WebView — the bundle's entry point
  /// with `?planId=<id>&src=local`. Path is `/` (the local server
  /// serves index.html at root; the web-player's production routes at
  /// `/p/<id>` go via the Vercel edge middleware, which this embedded
  /// surface deliberately bypasses).
  Uri buildPlayerUrl() {
    final session = _boundSession;
    if (session == null) {
      throw StateError('LocalPlayerServer.start() not yet called');
    }
    return _originUri().replace(
      path: '/',
      queryParameters: {
        'planId': session.id,
        'src': 'local',
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Routing
  // ---------------------------------------------------------------------------

  FutureOr<shelf.Response> _router(shelf.Request req) async {
    final path = req.url.path; // url.path has NO leading slash
    // Root + bundle static files.
    if (path.isEmpty || path == 'index.html') {
      return _serveAsset('assets/web-player/index.html', 'text/html; charset=utf-8');
    }
    if (path == 'app.js') {
      return _serveAsset('assets/web-player/app.js', 'application/javascript; charset=utf-8');
    }
    if (path == 'api.js') {
      return _serveAsset('assets/web-player/api.js', 'application/javascript; charset=utf-8');
    }
    if (path == 'styles.css') {
      return _serveAsset('assets/web-player/styles.css', 'text/css; charset=utf-8');
    }

    // Plan-full JSON.
    final planMatch = RegExp(r'^api/plan/([^/]+)$').firstMatch(path);
    if (planMatch != null) {
      return _servePlanFull(planMatch.group(1)!);
    }

    // Local media.
    final lineMatch =
        RegExp(r'^local/([^/]+)/line$').firstMatch(path);
    if (lineMatch != null) {
      return _serveExerciseMedia(
        exerciseId: lineMatch.group(1)!,
        kind: _MediaKind.line,
        request: req,
      );
    }
    final archiveMatch =
        RegExp(r'^local/([^/]+)/archive$').firstMatch(path);
    if (archiveMatch != null) {
      return _serveExerciseMedia(
        exerciseId: archiveMatch.group(1)!,
        kind: _MediaKind.archive,
        request: req,
      );
    }

    return shelf.Response.notFound('not found: ${req.url}');
  }

  // ---------------------------------------------------------------------------
  // Static asset handler
  // ---------------------------------------------------------------------------

  /// Serve a file from `rootBundle`. UTF-8 decoding for text responses
  /// is done implicitly via the shelf helper because shelf passes the
  /// body through without touching it.
  Future<shelf.Response> _serveAsset(String assetPath, String contentType) async {
    try {
      final byteData = await rootBundle.load(assetPath);
      final bytes = byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      );
      return shelf.Response.ok(
        bytes,
        headers: {
          HttpHeaders.contentTypeHeader: contentType,
          HttpHeaders.contentLengthHeader: bytes.lengthInBytes.toString(),
          // Loosen frame-access policy for the embedded WebView — the
          // bundle only ever loads same-origin resources anyway.
          'cross-origin-resource-policy': 'same-origin',
        },
      );
    } catch (e) {
      return shelf.Response.internalServerError(body: 'asset load failed: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Plan JSON handler — build the `get_plan_full` payload from local SQLite
  // ---------------------------------------------------------------------------

  Future<shelf.Response> _servePlanFull(String planId) async {
    final storage = _storage;
    if (storage == null) {
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': 'server not initialised'}),
        headers: {HttpHeaders.contentTypeHeader: 'application/json'},
      );
    }

    final session = await storage.getSession(planId);
    if (session == null) {
      return shelf.Response.notFound(
        jsonEncode({'error': 'plan not found'}),
        headers: {HttpHeaders.contentTypeHeader: 'application/json'},
      );
    }

    // Resolve consent. Phase 1 falls back to line-drawing-only when we
    // can't determine consent (legacy sessions or the client row isn't
    // in the local cache). This mirrors the server-side `get_plan_full`
    // default.
    final consent = await _resolveConsent(session.clientId);

    final exercisesJson = <Map<String, dynamic>>[];
    for (final e in session.exercises) {
      exercisesJson.add(_exerciseToPayload(e, consent));
    }

    final planJson = <String, dynamic>{
      'id': session.id,
      'client_name': session.clientName,
      'title': session.title,
      'circuit_cycles':
          session.circuitCycles.map((k, v) => MapEntry(k, v)),
      'preferred_rest_interval_seconds': session.preferredRestIntervalSeconds,
      'exercise_count': session.exercises.length,
      'version': session.version,
      'practice_id': session.practiceId,
      'first_opened_at': session.firstOpenedAt?.toIso8601String(),
      'client_id': session.clientId,
      'created_at': session.createdAt.toIso8601String(),
      'sent_at': session.sentAt?.toIso8601String(),
    };

    return shelf.Response.ok(
      jsonEncode({'plan': planJson, 'exercises': exercisesJson}),
      headers: {
        HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
      },
    );
  }

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
    } catch (_) {
      return _ConsentFlags.lineOnly();
    }
  }

  /// Build the exercise payload in the same shape as the server-side
  /// `get_plan_full` (milestone G). Every key the web-player reads is
  /// present; missing ones are explicit `null` so the JS normaliser
  /// doesn't branch on `undefined`.
  Map<String, dynamic> _exerciseToPayload(
    ExerciseCapture e,
    _ConsentFlags consent,
  ) {
    // Local URL shape — handled by the `/local/<exerciseId>/<kind>`
    // handler below. Relative URLs resolve against the WebView origin
    // (http://127.0.0.1:PORT), so keep them leading-slash absolute.
    final lineUrl = e.mediaType == MediaType.video || e.mediaType == MediaType.photo
        ? '/local/${e.id}/line'
        : null;
    final archiveUrl = e.mediaType == MediaType.video && e.archiveFilePath != null
        ? '/local/${e.id}/archive'
        : null;

    return {
      'id': e.id,
      'plan_id': e.sessionId,
      'position': e.position,
      'name': e.name,
      'media_url': lineUrl,
      'thumbnail_url': null, // not served over HTTP in Phase 1
      'media_type': e.mediaType.name,
      'reps': e.reps,
      'sets': e.sets,
      'hold_seconds': e.holdSeconds,
      'notes': e.notes,
      'circuit_id': e.circuitId,
      'include_audio': e.includeAudio,
      'custom_duration_seconds': e.customDurationSeconds,
      'prep_seconds': e.prepSeconds,
      'inter_set_rest_seconds': e.interSetRestSeconds,
      'preferred_treatment': e.preferredTreatment?.wireValue,
      // Three-treatment keys. Same source file covers B&W and Original;
      // the web-player applies grayscale CSS filter to its own side.
      'line_drawing_url': lineUrl,
      'grayscale_url':
          (consent.grayscale && archiveUrl != null) ? archiveUrl : null,
      'original_url':
          (consent.original && archiveUrl != null) ? archiveUrl : null,
    };
  }

  // ---------------------------------------------------------------------------
  // Media streaming — resolves the local archive / converted file and
  // streams it with Range support so iOS AVPlayer can seek.
  // ---------------------------------------------------------------------------

  Future<shelf.Response> _serveExerciseMedia({
    required String exerciseId,
    required _MediaKind kind,
    required shelf.Request request,
  }) async {
    final storage = _storage;
    final session = _boundSession;
    if (storage == null || session == null) {
      return shelf.Response.internalServerError(body: 'server not initialised');
    }

    // Find the matching exercise on the bound session. We don't query
    // the DB again — the session passed to start() already has its
    // exercises hydrated.
    ExerciseCapture? exercise;
    for (final e in session.exercises) {
      if (e.id == exerciseId) {
        exercise = e;
        break;
      }
    }
    if (exercise == null) {
      return shelf.Response.notFound('unknown exercise $exerciseId');
    }

    String? relativePath;
    switch (kind) {
      case _MediaKind.line:
        // Line drawing treatment: use converted file if ready, else the
        // raw capture (photos have no converted path — use raw as-is).
        relativePath = exercise.convertedFilePath ?? exercise.rawFilePath;
        break;
      case _MediaKind.archive:
        relativePath = exercise.archiveFilePath;
        break;
    }
    if (relativePath == null || relativePath.isEmpty) {
      return shelf.Response.notFound(
        'no ${kind.name} file for exercise $exerciseId',
      );
    }

    final absolute = PathResolver.resolve(relativePath);
    final file = File(absolute);
    if (!file.existsSync()) {
      return shelf.Response.notFound('file missing on disk: $absolute');
    }

    return _streamFile(file, request);
  }

  /// Stream a file with HTTP `Range` support so `<video>` elements can
  /// seek. iOS WKWebView on `http://127.0.0.1` issues byte-range GETs
  /// even for short clips; returning 200 with the whole body works but
  /// doubles the memory spike on first paint.
  Future<shelf.Response> _streamFile(File file, shelf.Request req) async {
    final length = await file.length();
    final contentType = _contentTypeFor(file.path);

    final rangeHeader = req.headers[HttpHeaders.rangeHeader];
    if (rangeHeader == null) {
      return shelf.Response.ok(
        file.openRead(),
        headers: {
          HttpHeaders.contentTypeHeader: contentType,
          HttpHeaders.contentLengthHeader: length.toString(),
          HttpHeaders.acceptRangesHeader: 'bytes',
        },
      );
    }

    // Parse `bytes=<start>-<end>`
    final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(rangeHeader);
    if (match == null) {
      return shelf.Response(
        HttpStatus.requestedRangeNotSatisfiable,
        body: 'invalid range',
      );
    }
    final start = int.parse(match.group(1)!);
    final endStr = match.group(2)!;
    final end = endStr.isEmpty ? length - 1 : int.parse(endStr);
    if (start < 0 || end >= length || start > end) {
      return shelf.Response(
        HttpStatus.requestedRangeNotSatisfiable,
        headers: {HttpHeaders.contentRangeHeader: 'bytes */$length'},
      );
    }
    final chunkLength = end - start + 1;
    return shelf.Response(
      HttpStatus.partialContent,
      body: file.openRead(start, end + 1),
      headers: {
        HttpHeaders.contentTypeHeader: contentType,
        HttpHeaders.acceptRangesHeader: 'bytes',
        HttpHeaders.contentLengthHeader: chunkLength.toString(),
        HttpHeaders.contentRangeHeader: 'bytes $start-$end/$length',
      },
    );
  }

  String _contentTypeFor(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.mp4') || lower.endsWith('.m4v')) return 'video/mp4';
    if (lower.endsWith('.mov')) return 'video/quicktime';
    if (lower.endsWith('.webm')) return 'video/webm';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.heic')) return 'image/heic';
    return 'application/octet-stream';
  }

  // ---------------------------------------------------------------------------
  // Middleware
  // ---------------------------------------------------------------------------

  /// Lightweight request logger — only active in debug. Errors bubble
  /// out as 500s so the WebView console surfaces them.
  shelf.Middleware _loggerMiddleware() {
    return (innerHandler) {
      return (request) async {
        try {
          return await innerHandler(request);
        } catch (e, st) {
          // ignore: avoid_print
          print('[LocalPlayerServer] ${request.method} ${request.url} -> $e\n$st');
          return shelf.Response.internalServerError(body: 'server error: $e');
        }
      };
    };
  }

  /// Force `Cache-Control: no-store` so a WebView that retains pages
  /// across screen rebuilds doesn't serve stale plan JSON. Phase 1 is
  /// a prototype — aggressive invalidation is the correct default.
  shelf.Middleware _noCacheMiddleware() {
    return (innerHandler) {
      return (request) async {
        final resp = await innerHandler(request);
        return resp.change(headers: {
          ...resp.headers,
          HttpHeaders.cacheControlHeader: 'no-store, max-age=0',
        });
      };
    };
  }
}

enum _MediaKind { line, archive }

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

