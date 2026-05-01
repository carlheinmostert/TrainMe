import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../config.dart';
import 'api_client.dart';

/// # loudSwallow — the one sanctioned swallow helper
///
/// Wave 7 (Milestone Q) — see `docs/design-reviews/silent-failures-2026-04-20.md`.
///
/// The problem: `try { ... } catch (e) { debugPrint(e) }` is the root cause
/// of every "oh god why is this silently broken" incident in this codebase.
/// `debugPrint` is stripped from release builds, so those blocks leave
/// literally no trace when they fire against a signed-in practitioner.
///
/// The fix: exactly ONE way to swallow an exception. Every swallow site
/// must route through this helper. The helper:
///
///   1. Always rethrows by default. The caller has to opt IN to swallow
///      via `swallow: true`. This forces each swallow site to be an
///      explicit editorial decision, not a reflex.
///   2. Writes a `warn` / `error` / `fatal` row to the server-side
///      `error_logs` table via the `log_error` RPC. Fire-and-forget —
///      the insert never blocks the caller, and its own failures are
///      swallowed into a local breadcrumb log.
///   3. Appends the same row (as a JSON line) to
///      `{Documents}/diagnostics.log` — a rotating local breadcrumb that
///      survives offline AND release builds. Rotates at 5 MB.
///
/// **Where this helper is allowed:** ONLY at three boundaries per the
/// design review:
///   - `ApiClient` — every RPC call that today has a bare catch.
///   - `UploadService.publish` — the best-effort sub-steps (raw-archive
///     upload, orphan cleanup, plan_issuances audit).
///   - Video platform channel handoffs in `ConversionService`.
///
/// Do NOT sprinkle `loudSwallow` through feature code — swallow is a
/// contract, not a workaround. A new site must be reviewed against the
/// design-review tiering (tier A / B / C). If in doubt: rethrow.
///
/// **Lint rule:** bare empty-body `catch` blocks in `.dart` files are
/// blocked by the pre-commit hook at `.claude/hooks/ban-bare-catch.sh`.
/// Use `loudSwallow` or rethrow.
///
/// ## Example — best-effort raw-archive upload
///
/// ```dart
/// await loudSwallow(
///   () => _api.uploadRawArchive(path: path, file: file),
///   kind: 'raw_archive_upload_failed',
///   source: 'UploadService._uploadRawArchives',
///   severity: 'warn',
///   meta: {'practice_id': practiceId, 'exercise_id': exercise.id},
///   swallow: true,
/// );
/// ```
///
/// ## Example — RPC where the UI has a legitimate empty-list fallback
///
/// ```dart
/// final clients = await loudSwallow<List<PracticeClient>>(
///   () => listPracticeClientsOrThrow(practiceId),
///   kind: 'list_practice_clients_failed',
///   source: 'ApiClient.listPracticeClients',
///   severity: 'warn',
///   swallow: true,
/// );
/// return clients ?? const [];
/// ```
Future<T?> loudSwallow<T>(
  Future<T> Function() body, {
  required String kind,
  required String source,
  String severity = 'warn',
  Map<String, Object?>? meta,
  String? message,
  bool swallow = false,
}) async {
  try {
    return await body();
  } catch (e, st) {
    // Fire-and-forget the server-side log. NEVER await it — the caller
    // must see its result (or rethrow) on the original timeline.
    unawaited(_postErrorLog(
      severity: severity,
      kind: kind,
      source: source,
      message: message ?? e.toString(),
      meta: {
        ...?meta,
        'stack_top': _stackTop(st),
        'error_type': e.runtimeType.toString(),
      },
    ));
    // Always leave a local breadcrumb. Release-build safe (unlike debugPrint).
    unawaited(_appendLocalLog(
      severity: severity,
      kind: kind,
      source: source,
      message: message ?? e.toString(),
      stackTop: _stackTop(st),
      meta: meta,
    ));
    // In debug mode also shout to console so the author sees it during
    // development without having to tail a file.
    if (kDebugMode) {
      // ignore: avoid_print
      debugPrint('[loudSwallow $severity/$kind @ $source] $e');
    }
    if (!swallow) rethrow;
    return null;
  }
}

/// Non-async fire-and-forget for sync code paths. Same contract as
/// [loudSwallow] but for `void` work that doesn't need to return a value.
/// Rarely needed — prefer [loudSwallow] wherever possible.
void loudSwallowSync(
  void Function() body, {
  required String kind,
  required String source,
  String severity = 'warn',
  Map<String, Object?>? meta,
  String? message,
  bool swallow = false,
}) {
  try {
    body();
  } catch (e, st) {
    unawaited(_postErrorLog(
      severity: severity,
      kind: kind,
      source: source,
      message: message ?? e.toString(),
      meta: {
        ...?meta,
        'stack_top': _stackTop(st),
        'error_type': e.runtimeType.toString(),
      },
    ));
    unawaited(_appendLocalLog(
      severity: severity,
      kind: kind,
      source: source,
      message: message ?? e.toString(),
      stackTop: _stackTop(st),
      meta: meta,
    ));
    if (kDebugMode) {
      debugPrint('[loudSwallowSync $severity/$kind @ $source] $e');
    }
    if (!swallow) rethrow;
  }
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

/// First few lines of the stack trace. We ship a trimmed prefix (not the
/// full trace) in both the RPC call and the local log so payload sizes
/// stay bounded and the server doesn't accumulate MBs of noise per
/// device. Full traces are easy to recover locally during development.
String _stackTop(StackTrace st) {
  final lines = st.toString().split('\n');
  return lines.take(3).join('\n');
}

/// Post to the `log_error` SECURITY DEFINER RPC (Milestone Q). Fire-and-
/// forget: the caller has already been serviced; a failure here is its
/// own swallow site (one level deep — we don't want an infinite loop of
/// log-of-log calls).
Future<void> _postErrorLog({
  required String severity,
  required String kind,
  required String source,
  String? message,
  Map<String, Object?>? meta,
}) async {
  try {
    // Skip if the auth client isn't initialised yet (cold start before
    // Supabase.initialize, or unit tests). Nothing to log TO.
    final client = ApiClient.instance.raw;
    // No signed-in user → the RPC would fail at auth.uid() check; we
    // still record locally above, so bail early.
    if (client.auth.currentUser == null) return;

    // practice_id is derived lazily to avoid a hard dependency from this
    // helper to AuthService (import cycle risk). Callers may supply
    // `meta['practice_id']` explicitly if they've got it in scope.
    final metaPracticeId = meta?['practice_id'];
    final practiceIdArg = metaPracticeId is String ? metaPracticeId : null;

    await client.rpc(
      'log_error',
      params: <String, dynamic>{
        'p_severity': severity,
        'p_kind': kind,
        'p_source': source,
        'p_message': _truncate(message, 2000),
        'p_meta': meta == null ? null : _safeJson(meta),
        'p_practice_id': practiceIdArg,
        'p_sha': AppConfig.buildSha,
      },
    );
  } catch (e) {
    // We deliberately do NOT recurse into loudSwallow here — that would
    // be a log-of-a-log-of-a-log infinite loop on persistent RPC failure.
    // A local breadcrumb is already being written in parallel.
    if (kDebugMode) {
      debugPrint('loudSwallow: RPC log_error failed: $e');
    }
  }
}

/// Append a single JSON line to `{Documents}/diagnostics.log`. Rotates
/// when the file crosses 5 MB — the previous file moves to
/// `diagnostics.log.1` (overwritten). Two-file rotation is enough for
/// the forensic use case ("what happened in the last hour or two"),
/// without spilling arbitrary disk.
Future<void> _appendLocalLog({
  required String severity,
  required String kind,
  required String source,
  String? message,
  String? stackTop,
  Map<String, Object?>? meta,
}) async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'diagnostics.log');
    final file = File(path);

    // Rotate if the current log is large.
    try {
      if (await file.exists()) {
        final stat = await file.stat();
        if (stat.size > 5 * 1024 * 1024) {
          final backup = File(p.join(dir.path, 'diagnostics.log.1'));
          if (await backup.exists()) {
            await backup.delete();
          }
          await file.rename(backup.path);
        }
      }
    } catch (_) {
      // Rotation is best-effort. A filesystem quirk here shouldn't
      // kill the log write.
    }

    final line = <String, Object?>{
      'ts': DateTime.now().toIso8601String(),
      'severity': severity,
      'kind': kind,
      'source': source,
      'message': _truncate(message, 2000),
      'meta': meta,
      'stack_top': stackTop,
      'sha': AppConfig.buildSha,
    };
    final encoded = '${_safeJsonString(line)}\n';
    await File(path).writeAsString(
      encoded,
      mode: FileMode.append,
      flush: false,
    );
  } catch (_) {
    // Log-of-log is explicitly swallowed. If we can't write to the
    // documents directory the device is in a state where our log won't
    // survive anyway.
  }
}

/// Convert arbitrary Dart values into a JSON-safe shape. Supabase's
/// `rpc(params: ...)` serialiser is strict: Maps / Lists / primitives
/// pass; anything else (Duration, Uri, custom classes) gets stringified
/// defensively so the RPC doesn't throw a codec error on an unrelated
/// value.
Object? _safeJson(Object? value) {
  if (value == null) return null;
  if (value is String || value is num || value is bool) return value;
  if (value is Map) {
    return value.map((k, v) => MapEntry(k.toString(), _safeJson(v)));
  }
  if (value is Iterable) {
    return value.map(_safeJson).toList(growable: false);
  }
  return value.toString();
}

String _safeJsonString(Object? value) {
  try {
    return jsonEncode(_safeJson(value));
  } catch (_) {
    return '{"_encode_error":true}';
  }
}

String? _truncate(String? s, int maxLen) {
  if (s == null) return null;
  if (s.length <= maxLen) return s;
  return s.substring(0, maxLen);
}
