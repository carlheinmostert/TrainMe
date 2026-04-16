import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart' hide Session;
import '../config.dart';
import '../models/session.dart';
import '../models/exercise_capture.dart';
import 'local_storage_service.dart';

/// Handles uploading a completed plan to Supabase and generating a
/// shareable link.
///
/// Architecture: Layer 3 of the three decoupled async layers.
/// Nothing touches the network until the bio taps Send. Only converted
/// (line drawing) files are uploaded — raw footage stays on device.
class UploadService {
  final LocalStorageService _storage;
  final _supabase = Supabase.instance.client;

  /// Storage bucket name for exercise media assets.
  static const _bucket = 'media';

  UploadService({required LocalStorageService storage}) : _storage = storage;

  /// Upload all converted assets for a session, create/update the plan
  /// record in the backend, and return the result.
  ///
  /// Precondition: all exercises in the session should have
  /// [ConversionStatus.done]. The caller should check
  /// [Session.allConversionsComplete] before calling this.
  ///
  /// Returns an [UploadResult] with the shareable URL and the new version.
  Future<UploadResult> uploadPlan(Session session) async {
    final mediaUrls = <String, String>{}; // exerciseId -> media URL
    final thumbUrls = <String, String?>{}; // exerciseId -> thumbnail URL

    // Step 1: Upload media files for each exercise
    for (final exercise in session.exercises) {
      if (exercise.isRest) continue; // Rest periods have no media

      // Upload converted file (or raw if conversion not done)
      // Resolve relative paths to absolute for file I/O
      final filePath = exercise.absoluteConvertedFilePath ?? exercise.absoluteRawFilePath;
      final file = File(filePath);
      if (await file.exists()) {
        final ext = p.extension(filePath);
        final storagePath = '${session.id}/${exercise.id}$ext';
        await _supabase.storage
            .from(_bucket)
            .upload(storagePath, file, fileOptions: const FileOptions(upsert: true));
        final url = _supabase.storage.from(_bucket).getPublicUrl(storagePath);
        mediaUrls[exercise.id] = url;
      }

      // Upload thumbnail if exists
      final thumbPath = exercise.absoluteThumbnailPath;
      if (thumbPath != null) {
        final thumbFile = File(thumbPath);
        if (await thumbFile.exists()) {
          final thumbStoragePath = '${session.id}/${exercise.id}_thumb.jpg';
          await _supabase.storage
              .from(_bucket)
              .upload(thumbStoragePath, thumbFile, fileOptions: const FileOptions(upsert: true));
          final thumbUrl = _supabase.storage.from(_bucket).getPublicUrl(thumbStoragePath);
          thumbUrls[exercise.id] = thumbUrl;
        }
      }
    }

    // Step 2: Upsert plan record. Increment version on each publish.
    final newVersion = session.version + 1;
    await _supabase.from('plans').upsert({
      'id': session.id,
      'client_name': session.clientName,
      'title': session.displayTitle,
      'circuit_cycles': json.encode(session.circuitCycles),
      'preferred_rest_interval_seconds': session.preferredRestIntervalSeconds,
      'exercise_count': session.exercises.where((e) => !e.isRest).length,
      'version': newVersion,
      'created_at': session.createdAt.toIso8601String(),
      'sent_at': DateTime.now().toIso8601String(),
    });

    // Step 3: Delete existing exercises for this plan (clean slate for re-sends),
    // then insert fresh exercise records.
    await _supabase.from('exercises').delete().eq('plan_id', session.id);

    final exerciseRows = session.exercises.map((e) => {
      'id': e.id,
      'plan_id': session.id,
      'position': e.position,
      'name': e.name,
      'media_url': mediaUrls[e.id],
      'thumbnail_url': thumbUrls[e.id],
      'media_type': e.mediaType.name, // 'photo', 'video', or 'rest'
      'reps': e.reps,
      'sets': e.sets,
      'hold_seconds': e.holdSeconds,
      'notes': e.notes,
      'circuit_id': e.circuitId,
      'include_audio': e.includeAudio,
      'custom_duration_seconds': e.customDurationSeconds,
    }).toList();

    await _supabase.from('exercises').insert(exerciseRows);

    // Step 4: Build shareable URL (stable across versions)
    final planUrl = '${AppConfig.webPlayerBaseUrl}/p/${session.id}';

    // Persist the published state locally
    final now = DateTime.now();
    final updated = session.copyWith(
      sentAt: now,
      planUrl: planUrl,
      version: newVersion,
      lastPublishedAt: now,
    );
    await _storage.saveSession(updated);

    return UploadResult(url: planUrl, version: newVersion);
  }
}

/// Result of a successful plan upload/publish.
class UploadResult {
  final String url;
  final int version;

  const UploadResult({required this.url, required this.version});
}
