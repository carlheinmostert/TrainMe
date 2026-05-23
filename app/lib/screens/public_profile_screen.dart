import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../theme.dart';

/// Safe Mode Transparency — Phase A (2026-05-22)
///
/// The "Public profile" Settings sub-screen. Carries the three
/// practitioner-controlled fields the live transparency page surfaces:
/// first name, last name, avatar selfie.
///
/// Selfie capture goes through `image_picker` with `source: camera`
/// and `preferredCameraDevice: front`. After the user picks a photo,
/// the native [PractitionerProfileChannel.verifyFaceInImage] method
/// detects a face — saves are blocked until at least one face is
/// found. (Bystander obscuring is reciprocal to practitioner identity
/// disclosure; an avatar without a face breaks the trust contract.)
///
/// On first successful save the [FirstTimeDisclosureCard] is shown
/// once — gated on whether the `practitioners` row already exists.
class PublicProfileScreen extends StatefulWidget {
  const PublicProfileScreen({super.key});

  static Future<void> push(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const PublicProfileScreen()),
    );
  }

  @override
  State<PublicProfileScreen> createState() => _PublicProfileScreenState();
}

class _PublicProfileScreenState extends State<PublicProfileScreen> {
  static const MethodChannel _faceChannel =
      MethodChannel('studio.homefit.practitioner_profile');

  final TextEditingController _firstCtrl = TextEditingController();
  final TextEditingController _lastCtrl = TextEditingController();
  final ImagePicker _picker = ImagePicker();

  PractitionerProfile? _profile;
  String? _localAvatarPath; // newly captured, not yet uploaded
  bool _saving = false;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _firstCtrl.dispose();
    _lastCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final p = await ApiClient.instance.getMyPractitionerProfile();
    if (!mounted) return;
    setState(() {
      _profile = p;
      _firstCtrl.text = p?.firstName ?? '';
      _lastCtrl.text = p?.lastName ?? '';
      _loading = false;
    });
  }

  /// True iff the user has never successfully saved a practitioner row.
  /// Drives the first-time disclosure card.
  bool get _isFirstTimeSave => _profile == null;

  Future<void> _pickSelfie() async {
    try {
      final XFile? picked = await _picker.pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.front,
        imageQuality: 90,
        maxWidth: 1024,
        maxHeight: 1024,
      );
      if (picked == null) return;
      if (!mounted) return;
      setState(() {
        _localAvatarPath = picked.path;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not open the camera. Try again.';
      });
    }
  }

  Future<bool> _verifyFace(String path) async {
    try {
      final dynamic raw = await _faceChannel.invokeMethod(
        'verifyFaceInImage',
        <String, dynamic>{'path': path},
      );
      if (raw is! Map) return false;
      return raw['faceFound'] == true;
    } on PlatformException catch (_) {
      return false;
    }
  }

  Future<void> _save() async {
    if (_saving) return;

    final first = _firstCtrl.text.trim();
    final last = _lastCtrl.text.trim();

    if (first.isEmpty || last.isEmpty) {
      setState(() => _error = 'First and last name are required.');
      return;
    }
    if (first.length > 60 || last.length > 60) {
      setState(() => _error = 'Names must be 60 characters or fewer.');
      return;
    }

    // Avatar required — either an existing one, or a newly captured one.
    final existingAvatar = _profile?.avatarUrl;
    if (_localAvatarPath == null && (existingAvatar == null || existingAvatar.isEmpty)) {
      setState(() => _error = 'A face photo is required.');
      return;
    }

    // If first-time, show the disclosure card and block until accepted.
    if (_isFirstTimeSave) {
      final accepted = await FirstTimeDisclosureCard.show(context);
      if (accepted != true) return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    String avatarUrl = existingAvatar ?? '';
    try {
      // Face-verify + upload only if a fresh selfie was captured.
      if (_localAvatarPath != null) {
        final path = _localAvatarPath!;
        final faceFound = await _verifyFace(path);
        if (!faceFound) {
          if (!mounted) return;
          setState(() {
            _saving = false;
            _error = 'We need a clear photo of your face. Try again.';
          });
          return;
        }
        final userId = AuthService.instance.currentUserId;
        if (userId == null) {
          if (!mounted) return;
          setState(() {
            _saving = false;
            _error = 'You need to be signed in to save.';
          });
          return;
        }
        final uploadedUrl = await ApiClient.instance.uploadAvatar(
          trainerId: userId,
          file: File(path),
        );
        if (uploadedUrl == null) {
          if (!mounted) return;
          setState(() {
            _saving = false;
            _error = 'Avatar upload failed. Check your connection.';
          });
          return;
        }
        avatarUrl = uploadedUrl;
      }

      await ApiClient.instance.setPractitionerProfile(
        firstName: first,
        lastName: last,
        avatarUrl: avatarUrl,
      );
      if (!mounted) return;

      // Refresh the snapshot so the screen reflects the new state and
      // future saves skip the first-time disclosure.
      await _load();
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Public profile saved'),
          duration: Duration(seconds: 2),
        ),
      );
      Navigator.of(context).maybePop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Save failed: ${e.toString()}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surfaceBg,
      appBar: AppBar(
        backgroundColor: AppColors.surfaceBg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          'Public profile',
          style: TextStyle(
            fontFamily: 'Montserrat',
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: AppColors.textOnDark,
          ),
        ),
        iconTheme: const IconThemeData(color: AppColors.textOnDark),
      ),
      body: SafeArea(
        child: _loading
            ? const Center(
                child: CircularProgressIndicator(color: AppColors.primary),
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                children: [
                  _DisclosureBlurb(),
                  const SizedBox(height: 20),
                  Center(
                    child: _AvatarPreview(
                      localPath: _localAvatarPath,
                      remoteUrl: _profile?.avatarUrl,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Center(
                    child: TextButton.icon(
                      onPressed: _saving ? null : _pickSelfie,
                      icon: const Icon(
                        Icons.photo_camera_outlined,
                        color: AppColors.primary,
                        size: 18,
                      ),
                      label: Text(
                        _profile?.avatarUrl != null || _localAvatarPath != null
                            ? 'Update photo'
                            : 'Add face photo',
                        style: const TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: AppColors.primary,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),
                  _FieldLabel(text: 'First name'),
                  const SizedBox(height: 8),
                  _ProfileField(
                    controller: _firstCtrl,
                    hint: 'e.g. Carl',
                    enabled: !_saving,
                    autofillHints: const [AutofillHints.givenName],
                    textCapitalization: TextCapitalization.words,
                  ),
                  const SizedBox(height: 18),
                  _FieldLabel(text: 'Last name'),
                  const SizedBox(height: 8),
                  _ProfileField(
                    controller: _lastCtrl,
                    hint: 'e.g. Mostert',
                    enabled: !_saving,
                    autofillHints: const [AutofillHints.familyName],
                    textCapitalization: TextCapitalization.words,
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(
                        color: AppColors.errorLight,
                        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                        border: Border.all(color: AppColors.error),
                      ),
                      child: Text(
                        _error!,
                        style: const TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 14,
                          color: AppColors.error,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 32),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _saving ? null : _save,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: AppColors.surfaceRaised,
                        disabledForegroundColor: AppColors.textSecondaryOnDark,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                        ),
                      ),
                      child: _saving
                          ? const SizedBox(
                              height: 18,
                              width: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text(
                              'Save',
                              style: TextStyle(
                                fontFamily: 'Inter',
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _DisclosureBlurb extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: AppColors.surfaceBorder),
      ),
      child: const Text(
        'Your name and photo appear publicly on every venue’s live '
        'transparency page when you record in Safe Mode. Bystanders give '
        'up their image (obscured) — you give up your identity (public). '
        'Without this, Safe Mode is disabled.',
        style: TextStyle(
          fontFamily: 'Inter',
          fontSize: 13,
          height: 1.5,
          color: AppColors.textSecondaryOnDark,
        ),
      ),
    );
  }
}

class _AvatarPreview extends StatelessWidget {
  final String? localPath;
  final String? remoteUrl;

  const _AvatarPreview({this.localPath, this.remoteUrl});

  @override
  Widget build(BuildContext context) {
    const size = 120.0;
    Widget child;
    if (localPath != null) {
      child = Image.file(
        File(localPath!),
        width: size,
        height: size,
        fit: BoxFit.cover,
      );
    } else if (remoteUrl != null && remoteUrl!.isNotEmpty) {
      child = Image.network(
        remoteUrl!,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _placeholder(),
      );
    } else {
      child = _placeholder();
    }

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: AppColors.primary, width: 2),
      ),
      child: ClipOval(child: child),
    );
  }

  Widget _placeholder() {
    return Container(
      color: AppColors.surfaceRaised,
      child: const Icon(
        Icons.person,
        size: 56,
        color: AppColors.textSecondaryOnDark,
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  final String text;
  const _FieldLabel({required this.text});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontFamily: 'Inter',
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.5,
        color: AppColors.textSecondaryOnDark,
      ),
    );
  }
}

class _ProfileField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final bool enabled;
  final List<String>? autofillHints;
  final TextCapitalization textCapitalization;

  const _ProfileField({
    required this.controller,
    required this.hint,
    required this.enabled,
    this.autofillHints,
    this.textCapitalization = TextCapitalization.none,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      enabled: enabled,
      autofillHints: autofillHints,
      textCapitalization: textCapitalization,
      maxLength: 60,
      style: const TextStyle(
        fontFamily: 'Inter',
        fontSize: 15,
        color: AppColors.textOnDark,
      ),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(
          fontFamily: 'Inter',
          fontSize: 15,
          color: AppColors.textSecondaryOnDark,
        ),
        filled: true,
        fillColor: AppColors.surfaceRaised,
        counterText: '',
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          borderSide: const BorderSide(color: AppColors.surfaceBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          borderSide: const BorderSide(color: AppColors.surfaceBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          borderSide: const BorderSide(color: AppColors.primary, width: 2),
        ),
      ),
    );
  }
}

/// Full-screen disclosure card shown exactly once — before the first
/// successful save of name + photo. Returns true if accepted, null/false
/// if cancelled.
class FirstTimeDisclosureCard {
  static Future<bool?> show(BuildContext context) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog(
        backgroundColor: AppColors.surfaceBg,
        insetPadding: const EdgeInsets.all(20),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLg),
          side: const BorderSide(color: AppColors.surfaceBorder),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Heads up — this becomes public',
                style: TextStyle(
                  fontFamily: 'Montserrat',
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textOnDark,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Your name and photo will appear publicly on every venue’s '
                'live transparency page when you record there using Safe Mode. '
                'Anyone scanning the venue’s poster can see who you are.',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 15,
                  height: 1.5,
                  color: AppColors.textOnDark,
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'This is the trade: bystanders give up their image (obscured) → '
                'you give up your identity (public).',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 14,
                  height: 1.5,
                  color: AppColors.textSecondaryOnDark,
                ),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(false),
                    child: const Text(
                      'Cancel',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 15,
                        color: AppColors.textSecondaryOnDark,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => Navigator.of(ctx).pop(true),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 22,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                      ),
                    ),
                    child: const Text(
                      'Got it',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
