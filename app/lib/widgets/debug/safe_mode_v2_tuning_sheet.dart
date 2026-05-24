/// Debug-gated live tuning sheet for the Safe Mode v2 face-match
/// threshold (2026-05-23). Long-press a Safe Mode photo in debug or
/// staging builds to slide this up; drag the slider and the photo
/// re-composites against the new threshold within ~1-2s.
///
/// Production gate: [debugTuningGateActive] returns true only in
/// `kDebugMode` or when `AppConfig.env == 'staging'`. Release/prod
/// builds therefore can neither show the affordance nor reach this
/// code path through any other surface — the long-press wrap in
/// `StudioExerciseCard` + `ExerciseEditorSheet` only attaches a
/// gesture handler when the gate is true.
///
/// Persistence: the "Save as new default" button writes the current
/// slider value to SharedPreferences under
/// [kSafeModeV2ThresholdOverridePrefKey]. Both
/// [ConversionService.reprocessSafeMode] and the capture-time photo
/// Safe Mode pass read this preference; an explicit per-call override
/// still wins. "Reset" clears the key.
///
/// File location convention: anything under `app/lib/widgets/debug/`
/// is debug-only by convention — callers must wrap entry points with
/// `debugTuningGateActive()` so release builds never reach them.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../config.dart';
import '../../models/exercise_capture.dart';
import '../../services/conversion_service.dart';
import '../../theme.dart';

/// True iff this build should expose the tuning sheet. Debug builds
/// always pass; release builds pass only when `--dart-define=ENV=staging`
/// is set (install-sim.sh / install-device.sh's `staging` profile).
///
/// `release` and `prod` builds return false — TestFlight + App Store
/// users never see the long-press affordance.
bool debugTuningGateActive() {
  if (kDebugMode) return true;
  return AppConfig.env == 'staging';
}

/// Slide-up bottom sheet for live solo-face-floor tuning (the
/// post-2026-05-24 semantic; see [kSafeModeV2SoloFloor]). See the
/// file-level dartdoc for the gating + persistence contract.
///
/// The slider drives [ConversionService.reprocessSafeMode] with a
/// 250ms debounce so live drag iterates naturally without queuing
/// dozens of native passes. Each completed reprocess re-keys the
/// preview Image so the on-disk safe variant is read fresh.
Future<void> showSafeModeV2TuningSheet(
  BuildContext context,
  ExerciseCapture exercise,
) async {
  if (!debugTuningGateActive()) return;
  if (exercise.mediaType != MediaType.photo) return;
  HapticFeedback.selectionClick();
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surfaceRaised,
    barrierColor: Colors.black.withValues(alpha: 0.6),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => _SafeModeV2TuningSheet(exercise: exercise),
  );
}

class _SafeModeV2TuningSheet extends StatefulWidget {
  const _SafeModeV2TuningSheet({required this.exercise});

  final ExerciseCapture exercise;

  @override
  State<_SafeModeV2TuningSheet> createState() => _SafeModeV2TuningSheetState();
}

class _SafeModeV2TuningSheetState extends State<_SafeModeV2TuningSheet> {
  double _threshold = kSafeModeV2SoloFloor;
  double? _persistedOverride;
  bool _loadingPrefs = true;
  bool _reprocessing = false;
  int _previewKey = 0;
  bool _flashActive = false;
  Timer? _debounce;
  Timer? _flashTimer;

  @override
  void initState() {
    super.initState();
    _loadPersistedOverride();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _flashTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadPersistedOverride() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getDouble(kSafeModeV2ThresholdOverridePrefKey);
      if (!mounted) return;
      setState(() {
        _persistedOverride = stored;
        _threshold = stored ?? kSafeModeV2SoloFloor;
        _loadingPrefs = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingPrefs = false);
    }
  }

  void _onSliderChanged(double value) {
    setState(() => _threshold = value);
  }

  void _onSliderChangeEnd(double value) {
    _scheduleReprocess(value);
  }

  void _scheduleReprocess(double value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      _runReprocess(value);
    });
  }

  Future<void> _runReprocess(double value) async {
    if (_reprocessing) return;
    setState(() => _reprocessing = true);
    final ok = await ConversionService.instance.reprocessSafeMode(
      widget.exercise.id,
      thresholdOverride: value,
    );
    if (!mounted) return;
    setState(() {
      _reprocessing = false;
      if (ok) _previewKey++;
    });
    if (ok) {
      _triggerFlash();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't re-process — try again.")),
      );
    }
  }

  /// 250ms coral border pulse on the preview to give the user a visible
  /// confirmation that the re-composite landed. Without this the slider
  /// can feel inert because the on-disk swap is silent.
  void _triggerFlash() {
    _flashTimer?.cancel();
    setState(() => _flashActive = true);
    _flashTimer = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      setState(() => _flashActive = false);
    });
  }

  Future<void> _saveAsDefault() async {
    HapticFeedback.selectionClick();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(kSafeModeV2ThresholdOverridePrefKey, _threshold);
      if (!mounted) return;
      setState(() => _persistedOverride = _threshold);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Saved default: ${_threshold.toStringAsFixed(3)}',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Couldn't save: $e")),
      );
    }
  }

  Future<void> _resetDefault() async {
    HapticFeedback.selectionClick();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(kSafeModeV2ThresholdOverridePrefKey);
      if (!mounted) return;
      setState(() {
        _persistedOverride = null;
        _threshold = kSafeModeV2SoloFloor;
      });
      _scheduleReprocess(kSafeModeV2SoloFloor);
    } catch (_) {}
  }

  String? _resolvePreviewPath() {
    final safe = widget.exercise.absoluteSafeRawFilePath;
    if (safe != null) return safe;
    return widget.exercise.absoluteRawFilePath;
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final maxHeight = media.size.height * 0.85;
    final previewPath = _resolvePreviewPath();
    // Preview takes ~48% of the sheet so the user's eye lands here, not
    // on the Demo canvas behind the sheet (which shows the line/raw
    // treatment, not the safe variant the slider is editing).
    final previewHeight = maxHeight * 0.48;

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            8,
            16,
            16 + media.viewInsets.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _GrabberHandle(),
              const SizedBox(height: 8),
              const _PreviewLabel(),
              const SizedBox(height: 6),
              SizedBox(
                height: previewHeight,
                child: _PhotoPreview(
                  filePath: previewPath,
                  reprocessing: _reprocessing,
                  refreshKey: _previewKey,
                  flashActive: _flashActive,
                ),
              ),
              const SizedBox(height: 16),
              _ThresholdHeader(
                threshold: _threshold,
                persistedOverride: _persistedOverride,
                loading: _loadingPrefs,
              ),
              const SizedBox(height: 4),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: AppColors.primary,
                  inactiveTrackColor: AppColors.surfaceBorder,
                  thumbColor: AppColors.primary,
                  overlayColor: AppColors.primary.withValues(alpha: 0.2),
                ),
                child: Slider(
                  value: _threshold.clamp(0.0, 0.5),
                  min: 0.0,
                  max: 0.5,
                  onChanged: _loadingPrefs ? null : _onSliderChanged,
                  onChangeEnd: _loadingPrefs ? null : _onSliderChangeEnd,
                ),
              ),
              const SizedBox(height: 4),
              _DefaultsHint(persistedOverride: _persistedOverride),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _SheetButton(
                      label: 'Apply now',
                      filled: true,
                      enabled: !_loadingPrefs && !_reprocessing,
                      onTap: () => _runReprocess(_threshold),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _SheetButton(
                      label: 'Save default',
                      filled: false,
                      enabled: !_loadingPrefs,
                      onTap: _saveAsDefault,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _SheetButton(
                      label: 'Reset',
                      filled: false,
                      enabled: !_loadingPrefs && _persistedOverride != null,
                      onTap: _resetDefault,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              const Text(
                "Debug build only — won't ship to App Store.",
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 11,
                  color: AppColors.textSecondaryOnDark,
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GrabberHandle extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 36,
        height: 4,
        decoration: BoxDecoration(
          color: AppColors.surfaceBorder,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

class _PhotoPreview extends StatelessWidget {
  const _PhotoPreview({
    required this.filePath,
    required this.reprocessing,
    required this.refreshKey,
    required this.flashActive,
  });

  final String? filePath;
  final bool reprocessing;
  final int refreshKey;
  final bool flashActive;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: flashActive
              ? AppColors.primary
              : AppColors.surfaceBorder.withValues(alpha: 0.0),
          width: 2,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.surfaceBase,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (filePath != null)
                Image.file(
                  File(filePath!),
                  // Key combines refreshKey + filePath so a reprocess that
                  // overwrites the same file path still forces a re-read
                  // from disk (otherwise Flutter's ImageCache returns the
                  // pre-reprocess bytes).
                  key: ValueKey('preview-$refreshKey-$filePath'),
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) =>
                      const _PreviewPlaceholder(message: 'Preview unavailable'),
                )
              else
                const _PreviewPlaceholder(message: 'No image to show'),
              if (reprocessing)
                Container(
                  color: Colors.black.withValues(alpha: 0.35),
                  child: const Center(
                    child: SizedBox(
                      width: 36,
                      height: 36,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          AppColors.primary,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PreviewLabel extends StatelessWidget {
  const _PreviewLabel();

  @override
  Widget build(BuildContext context) {
    return const Text(
      'Safe variant — re-composites live as you drag',
      textAlign: TextAlign.center,
      style: TextStyle(
        fontFamily: 'Inter',
        fontSize: 12,
        color: AppColors.textSecondaryOnDark,
        letterSpacing: 0.2,
      ),
    );
  }
}

class _PreviewPlaceholder extends StatelessWidget {
  const _PreviewPlaceholder({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        message,
        style: const TextStyle(
          fontFamily: 'Inter',
          fontSize: 13,
          color: AppColors.textSecondaryOnDark,
        ),
      ),
    );
  }
}

class _ThresholdHeader extends StatelessWidget {
  const _ThresholdHeader({
    required this.threshold,
    required this.persistedOverride,
    required this.loading,
  });

  final double threshold;
  final double? persistedOverride;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const Text(
          'Solo-face floor',
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: AppColors.textOnDark,
          ),
        ),
        Text(
          loading ? '…' : threshold.toStringAsFixed(3),
          style: const TextStyle(
            fontFamily: 'JetBrainsMono',
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: AppColors.primary,
            letterSpacing: 0.3,
          ),
        ),
      ],
    );
  }
}

class _DefaultsHint extends StatelessWidget {
  const _DefaultsHint({required this.persistedOverride});
  final double? persistedOverride;

  @override
  Widget build(BuildContext context) {
    final base =
        'Compile-time default: ${kSafeModeV2SoloFloor.toStringAsFixed(3)}';
    final extra = persistedOverride == null
        ? ''
        : '  ·  saved default: ${persistedOverride!.toStringAsFixed(3)}';
    return Text(
      '$base$extra',
      style: const TextStyle(
        fontFamily: 'Inter',
        fontSize: 11,
        color: AppColors.textSecondaryOnDark,
        letterSpacing: 0.2,
      ),
    );
  }
}

class _SheetButton extends StatelessWidget {
  const _SheetButton({
    required this.label,
    required this.filled,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool filled;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bg = filled ? AppColors.primary : Colors.transparent;
    final fg = filled ? Colors.white : AppColors.primary;
    final border = filled
        ? null
        : Border.all(color: AppColors.primary.withValues(alpha: 0.6));
    return Opacity(
      opacity: enabled ? 1.0 : 0.4,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            height: 40,
            decoration: BoxDecoration(
              color: bg,
              border: border,
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: Text(
              label,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: fg,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
