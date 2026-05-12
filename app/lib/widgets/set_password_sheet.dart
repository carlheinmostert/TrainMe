import 'dart:async';
import 'dart:developer' as dev;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;

import '../services/auth_service.dart';
import '../theme.dart';

/// Bottom sheet with a single password field — the UI for the one-time
/// post-sign-in "Faster sign-in next time — set a password." prompt.
///
/// Uses [AuthService.setPassword], which wraps
/// `supabase.auth.updateUser(UserAttributes(password: ...))`. Requires an
/// active session — callers are expected to launch this only from an
/// authenticated surface (Home).
///
/// Visual spec pulled from `docs/design/project/components.md` (Text Input
/// section) — filled dark base, 1px border, coral focus ring, `radius.md`.
///
/// Returns `true` from [Navigator.pop] on successful save, so the caller
/// can persist the "prompt already handled" flag.
class SetPasswordSheet extends StatefulWidget {
  const SetPasswordSheet({super.key});

  /// Convenience launcher. Shows the sheet and resolves to `true` iff the
  /// password was saved. Safe to call from any [BuildContext] that has a
  /// [Navigator] above it.
  static Future<bool> show(BuildContext context) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true, // respects keyboard inset
      backgroundColor: AppColors.surfaceBase,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const SetPasswordSheet(),
    );
    return saved == true;
  }

  @override
  State<SetPasswordSheet> createState() => _SetPasswordSheetState();
}

class _SetPasswordSheetState extends State<SetPasswordSheet> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();

  bool _obscured = true;
  bool _saving = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    // Auto-focus the field once the sheet is mounted so the keyboard slides
    // up with the sheet.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final password = _controller.text;
    if (password.length < 8) {
      setState(() {
        _errorText = 'Use at least 8 characters.';
      });
      return;
    }

    setState(() {
      _saving = true;
      _errorText = null;
    });

    try {
      await AuthService.instance.setPassword(password);
      if (!mounted) return;
      unawaited(HapticFeedback.mediumImpact());
      Navigator.of(context).pop(true);
    } on AuthException catch (e, st) {
      dev.log(
        'setPassword failed (AuthException): ${e.message}',
        name: 'SetPasswordSheet',
        level: 900, // WARNING
        error: e,
        stackTrace: st,
      );
      if (!mounted) return;
      setState(() {
        _saving = false;
        _errorText = _friendlyError(e.message);
      });
    } catch (e, st) {
      dev.log(
        'setPassword failed (non-AuthException): $e',
        name: 'SetPasswordSheet',
        level: 900, // WARNING
        error: e,
        stackTrace: st,
      );
      if (!mounted) return;
      // Strip the leading "FooException: " prefix so a raw PostgrestException
      // / TimeoutException reads as the underlying server message, not as a
      // stack-trace fragment. Falls back to a generic-but-honest line if the
      // exception has no useful toString().
      final cleanedFirstLine = e is Exception
          ? e
              .toString()
              .split('\n')
              .first
              .replaceFirst(RegExp(r'^[A-Za-z]+Exception:\s*'), '')
          : 'Unexpected error';
      setState(() {
        _saving = false;
        _errorText = _friendlyError(cleanedFirstLine);
      });
    }
  }

  /// Per voice.md: short, what-happened-plus-what-to-do. Supabase's own
  /// strings leak "weak password" in various shapes — normalise the common
  /// ones, then fall through to the actual server message (truncated) so
  /// Carl-on-device can diagnose the masked layer instead of staring at a
  /// useless generic. Loud-swallow pattern, per Carl's preference.
  String _friendlyError(String rawMessage) {
    final msg = rawMessage.toLowerCase();
    if (msg.contains('weak') || msg.contains('short')) {
      return 'Pick a stronger password.';
    }
    if (msg.contains('same') || msg.contains('match')) {
      return "That's already your password.";
    }
    if (msg.contains('reauth')) {
      return 'Sign in again to change your password.';
    }
    if (msg.contains('expired') || msg.contains('session')) {
      return 'Your session expired — sign in again.';
    }
    if (msg.contains('rate') || msg.contains('too many')) {
      return 'Too many attempts — try in a few minutes.';
    }
    if (msg.contains('network') ||
        msg.contains('connection') ||
        msg.contains('timeout')) {
      return 'No connection — check your network.';
    }
    // Fall through: surface the real message so the cause is visible on
    // device. Cap at 120 chars so it fits the error row without wrapping
    // into a wall of text.
    final trimmed = rawMessage.trim();
    if (trimmed.isEmpty) return "Couldn't save password. Try again.";
    final capped =
        trimmed.length > 120 ? '${trimmed.substring(0, 117)}...' : trimmed;
    return 'Server said: $capped';
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return SafeArea(
      top: false,
      child: Padding(
        // Lift the sheet above the keyboard.
        padding: EdgeInsets.only(bottom: bottomInset),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Drag handle affordance (matches AccountSheet style on Home).
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceBorder,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const Text(
                'Set a password',
                style: TextStyle(
                  fontFamily: 'Montserrat',
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                  color: AppColors.textOnDark,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Next time you sign in on this phone or any other, '
                'you can enter your password directly.',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                  height: 1.4,
                  color: AppColors.textSecondaryOnDark,
                ),
              ),
              const SizedBox(height: 20),
              const Padding(
                padding: EdgeInsets.only(left: 4, bottom: 8),
                child: Text(
                  'New password',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                    color: AppColors.textSecondaryOnDark,
                  ),
                ),
              ),
              TextField(
                controller: _controller,
                focusNode: _focus,
                enabled: !_saving,
                obscureText: _obscured,
                textInputAction: TextInputAction.go,
                autocorrect: false,
                enableSuggestions: false,
                autofillHints: const [AutofillHints.newPassword],
                style: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 15,
                  color: AppColors.textOnDark,
                ),
                cursorColor: AppColors.primary,
                onChanged: (_) {
                  if (_errorText != null) {
                    setState(() => _errorText = null);
                  }
                },
                onSubmitted: (_) => _save(),
                decoration: InputDecoration(
                  hintText: 'At least 8 characters',
                  hintStyle: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 15,
                    color: AppColors.textSecondaryOnDark,
                  ),
                  filled: true,
                  fillColor: AppColors.surfaceBg,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                  suffixIcon: IconButton(
                    onPressed: _saving
                        ? null
                        : () => setState(() => _obscured = !_obscured),
                    splashRadius: 20,
                    icon: Icon(
                      _obscured
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                      size: 20,
                      color: AppColors.textSecondaryOnDark,
                    ),
                    tooltip: _obscured ? 'Show password' : 'Hide password',
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                    borderSide:
                        const BorderSide(color: AppColors.surfaceBorder),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                    borderSide: BorderSide(
                      color: _errorText != null
                          ? AppColors.error
                          : AppColors.surfaceBorder,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                    borderSide: BorderSide(
                      color: _errorText != null
                          ? AppColors.error
                          : AppColors.primary,
                      width: 2,
                    ),
                  ),
                ),
              ),
              if (_errorText != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8, left: 4),
                  child: Text(
                    _errorText!,
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 12,
                      color: AppColors.error,
                    ),
                  ),
                ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: _saving
                          ? null
                          : () => Navigator.of(context).pop(false),
                      style: TextButton.styleFrom(
                        foregroundColor: AppColors.textSecondaryOnDark,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius:
                              BorderRadius.circular(AppTheme.radiusMd),
                          side: const BorderSide(
                            color: AppColors.surfaceBorder,
                          ),
                        ),
                      ),
                      child: const Text(
                        'Cancel',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      onPressed: _saving ? null : _save,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius:
                              BorderRadius.circular(AppTheme.radiusMd),
                        ),
                      ),
                      child: _saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor:
                                    AlwaysStoppedAnimation(Colors.white),
                              ),
                            )
                          : const Text(
                              'Save password',
                              style: TextStyle(
                                fontFamily: 'Inter',
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
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
