import 'package:uuid/uuid.dart';
import '../models/session.dart';
import 'local_storage_service.dart';

/// Handles uploading a completed plan to the cloud and generating a
/// shareable link.
///
/// Architecture: Layer 3 of the three decoupled async layers.
/// Nothing touches the network until the bio taps Send. Only converted
/// (line drawing) files are uploaded — raw footage stays on device.
///
/// STUB: This is a Phase 3 integration point. The current implementation
/// fakes the upload and returns a placeholder URL so the Send flow can
/// be developed end-to-end.
class UploadService {
  final LocalStorageService _storage;

  UploadService({required LocalStorageService storage}) : _storage = storage;

  /// Upload all converted assets for a session, create the plan record
  /// in the backend, and return a shareable URL.
  ///
  /// Precondition: all exercises in the session should have
  /// [ConversionStatus.done]. The caller should check
  /// [Session.allConversionsComplete] before calling this.
  ///
  /// Returns the shareable plan URL (e.g. https://raidme.app/p/{uuid}).
  Future<String> uploadPlan(Session session) async {
    // TODO_SUPABASE: Initialize Supabase client
    // final supabase = Supabase.instance.client;

    // TODO_SUPABASE: Upload each converted file to Supabase Storage
    // final assetUrls = <String, String>{};
    // for (final exercise in session.exercises) {
    //   if (exercise.convertedFilePath == null) continue;
    //   final file = File(exercise.convertedFilePath!);
    //   final storagePath = 'plans/${session.id}/${exercise.id}${p.extension(exercise.convertedFilePath!)}';
    //   await supabase.storage
    //       .from('exercise-assets')
    //       .upload(storagePath, file);
    //   assetUrls[exercise.id] = supabase.storage
    //       .from('exercise-assets')
    //       .getPublicUrl(storagePath);
    // }

    // TODO_SUPABASE: Create plan record in Supabase Postgres
    // await supabase.from('plans').insert({
    //   'id': session.id,
    //   'client_name': session.clientName,
    //   'title': session.displayTitle,
    //   'created_at': session.createdAt.toIso8601String(),
    //   'exercises': session.exercises.map((e) => {
    //     'id': e.id,
    //     'position': e.position,
    //     'media_type': e.mediaType.name,
    //     'asset_url': assetUrls[e.id],
    //     'reps': e.reps,
    //     'sets': e.sets,
    //     'hold_seconds': e.holdSeconds,
    //     'notes': e.notes,
    //   }).toList(),
    // });

    // TODO_SUPABASE: Generate the real shareable URL
    // final planUrl = 'https://raidme.app/p/${session.id}';

    // TODO: At send time, for exercises with includeAudio == false, strip
    // the audio track from the converted video before uploading. This avoids
    // sending ambient gym noise to clients when the trainer hasn't opted in.
    // Use FFmpeg or a native platform channel to remux without audio.

    // STUB: Simulate a short upload delay and return a fake URL.
    await Future.delayed(const Duration(seconds: 1));
    final fakePlanId = const Uuid().v4().substring(0, 8);
    final planUrl = 'https://raidme.app/p/$fakePlanId';

    // Persist the sent state
    final updated = session.copyWith(
      sentAt: DateTime.now(),
      planUrl: planUrl,
    );
    await _storage.saveSession(updated);

    return planUrl;
  }
}
