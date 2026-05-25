import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../widgets/self_face_consent_sheet.dart';
import 'api_client.dart';
import 'auth_service.dart';

/// Self-trainer wave PR #4 (2026-05-25) — lazy backfill orchestrator.
///
/// On Home's first post-frame after authenticated bootstrap, decide
/// whether to surface the [SelfFaceConsentSheet] for an existing
/// Public-profile-selfie user who hasn't yet opted into
/// self-verification.
///
/// Gating conditions (all must hold to prompt):
///   1. User is authenticated.
///   2. `practitioners.avatar_url IS NOT NULL` — there's a selfie to
///      compute an embedding from.
///   3. `practitioners.face_embedding_consented_at IS NULL` — we haven't
///      already recorded explicit consent for the new self-verification
///      purpose (POPIA Q14.1).
///   4. The "we've already shown the prompt once" SharedPreferences
///      flag is unset for this user. Persist after the first
///      prompt-shown event regardless of Yes/Not now — the user has
///      seen the offer and can opt in any time via Settings.
///
/// Failure modes — every step is best-effort. If anything throws (no
/// network, RPC failure, selfie download fails), we silently no-op:
/// the user can still opt in manually via Settings → Public profile.
class SelfTrainerBootstrap {
  SelfTrainerBootstrap._();

  /// Singleton — keeps the SharedPreferences read/write off the UI
  /// thread between calls and lets the call sites cheaply guard
  /// re-entry while the dialog is open.
  static final SelfTrainerBootstrap instance = SelfTrainerBootstrap._();

  /// `SharedPreferences` key for "we've offered the lazy backfill to
  /// this user". Namespaced under `homefit.` to match
  /// [AuthService._selectedPracticeIdPrefsKey]'s convention. Suffixed
  /// with the user id so different accounts on the same device each
  /// see the prompt once.
  String _prefsKey(String userId) =>
      'homefit.self_trainer.consent_prompted.$userId';

  /// Module-level shared mutex preventing two simultaneous consent-sheet
  /// opens — covers both the lazy-backfill path (this service) and the
  /// FAB "New Self Session" path in `home_screen.dart`. Without sharing
  /// the flag across both call sites, a rapid practice-switch +
  /// FAB-tap could stack two `SelfFaceConsentSheet.show` calls.
  ///
  /// FAB callers MUST check + acquire via [consentPromptInFlight] /
  /// [setConsentPromptInFlight] before opening their own consent sheet.
  /// The SharedPreferences "we've offered this once" flag eventually
  /// persists, but the in-memory mutex prevents the race window.
  static bool _consentPromptInFlight = false;

  /// Read the shared mutex. Returns true iff a consent sheet is
  /// currently open on either the lazy-backfill OR the FAB path.
  static bool get consentPromptInFlight => _consentPromptInFlight;

  /// Acquire / release the shared mutex. Callers MUST release in a
  /// `finally` block.
  static void setConsentPromptInFlight(bool value) {
    _consentPromptInFlight = value;
  }

  /// Call from Home's `initState` post-frame callback. Idempotent and
  /// silent-on-failure.
  Future<void> maybePromptForLazyBackfill(BuildContext context) async {
    if (_consentPromptInFlight) return;
    _consentPromptInFlight = true;
    try {
      final userId = AuthService.instance.currentUserId;
      if (userId == null) return;

      // SharedPreferences gate — has the prompt already been offered?
      final prefs = await SharedPreferences.getInstance();
      final key = _prefsKey(userId);
      if (prefs.getBool(key) == true) return;

      // Cloud gate — does this practitioner have a selfie and no prior
      // consent stamp?
      final profile = await ApiClient.instance.getMyPractitionerProfile();
      if (profile == null) return;
      final avatarUrl = profile.avatarUrl?.trim();
      if (avatarUrl == null || avatarUrl.isEmpty) return;
      if (profile.faceEmbeddingConsentedAt != null) {
        // Already consented (or revoked then re-consented). Mark the
        // prompt flag too so we don't re-evaluate on every launch.
        await prefs.setBool(key, true);
        return;
      }

      // Pull the avatar bytes to a temp file. The native MobileFaceNet
      // pipeline reads files, not URLs.
      final localPath = await _downloadAvatarToTemp(
        avatarUrl: avatarUrl,
        userId: userId,
      );
      if (localPath == null) {
        // Download failed — don't burn the one-shot flag; we'll try
        // again next launch. Network-flaky users shouldn't permanently
        // lose the prompt.
        return;
      }

      if (!context.mounted) return;

      // Mark the prompt-shown flag BEFORE actually showing the sheet
      // so a crash mid-prompt doesn't loop. The user can always opt in
      // later via Settings.
      await prefs.setBool(key, true);

      if (!context.mounted) return;
      // ignore: use_build_context_synchronously
      await SelfFaceConsentSheet.show(context, selfiePath: localPath);
      // We deliberately ignore the outcome — both Yes (registered) and
      // Not now (dismissed) are terminal for the lazy backfill prompt.
      // Yes-failures (no-face / network) keep the sheet open until the
      // user dismisses it themselves, at which point we still treat
      // the prompt as shown.
    } catch (e) {
      // Silent best-effort per the failure-modes contract above.
      debugPrint('SelfTrainerBootstrap.maybePromptForLazyBackfill failed: $e');
    } finally {
      _consentPromptInFlight = false;
    }
  }

  /// Download the practitioner's avatar from [avatarUrl] to a stable
  /// temp file at `{tmp}/self_selfie_{userId}.jpg`. Returns the path or
  /// null on failure.
  ///
  /// Uses [HttpClient] directly rather than the storage-signed-URL
  /// path because the practitioner avatar lives in the PUBLIC `media`
  /// bucket — a plain GET works.
  Future<String?> _downloadAvatarToTemp({
    required String avatarUrl,
    required String userId,
  }) async {
    final client = HttpClient();
    try {
      final uri = Uri.tryParse(avatarUrl);
      if (uri == null) return null;
      final req = await client.getUrl(uri);
      final resp = await req.close();
      if (resp.statusCode != 200) return null;
      final tmpDir = await getTemporaryDirectory();
      final tmpFile = File(p.join(tmpDir.path, 'self_selfie_$userId.jpg'));
      final sink = tmpFile.openWrite();
      await resp.pipe(sink);
      return tmpFile.path;
    } catch (e) {
      debugPrint('SelfTrainerBootstrap._downloadAvatarToTemp failed: $e');
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Diagnostic helper — clear the prompt-shown flag for [userId]. Not
  /// wired to any UI; lives here for debug/QA use.
  @visibleForTesting
  Future<void> resetPromptFlag(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey(userId));
  }
}
