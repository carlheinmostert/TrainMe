// =============================================================================
// PreviewArtifactPickerSheet — 2026-05-27 (artifact-system follow-up)
// =============================================================================
//
// Single-select artifact picker shown when the practitioner taps PREVIEW
// in the Studio workflow pill. Until now Preview jumped straight to the
// workout-plan card deck — it assumed the only previewable artifact was
// the workout player. A session can now carry multiple artifact kinds
// (workout player + take-home handout, per artifact-system Waves 1-5), so
// Preview first asks WHICH artifact to preview.
//
// Visual: reuses the Publish-gate (`publish_gate_sheet.dart`) row idiom —
// same card / glyph / chip language — so the two sheets read as siblings.
// The difference is selection semantics: the publish gate is MULTI-select
// with a running credit total + CTA; this picker is SINGLE-select and
// fires the chosen preview the moment a selectable row is tapped (no CTA,
// no credit math — previewing is always free + local).
//
// Selectable rows: "Workout player" + "Workout handout" — both always
// previewable from the local session, regardless of publish status, since
// the handout derives from the same session data the player does. Future
// kinds (poster, reel) render as muted "Soon" rows and are NOT tappable.
//
// No modal dialog (R-01 / feedback_no_popups_ever) — this is an inline
// bottom-sheet card, the same pattern the publish gate uses.
// =============================================================================

import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../theme.dart';

/// Which artifact the practitioner picked to preview. Returned by
/// [PreviewArtifactPickerSheet.show] when a selectable row is tapped;
/// null when the sheet is dismissed without a choice.
enum PreviewArtifactChoice {
  /// The swipeable workout-plan card deck (existing UnifiedPreviewScreen).
  workoutPlayer,

  /// The take-home handout page (local-bundled handout.html preview).
  handout,
}

class PreviewArtifactPickerSheet extends StatelessWidget {
  const PreviewArtifactPickerSheet({super.key});

  /// Open the picker as a bottom sheet. Resolves to a
  /// [PreviewArtifactChoice] when the practitioner taps a selectable row,
  /// or null when they back out. Detent matches the publish-gate
  /// convention so the two sheets feel identical; it shrinks naturally
  /// to its content since the row list is short.
  static Future<PreviewArtifactChoice?> show(BuildContext context) {
    return showModalBottomSheet<PreviewArtifactChoice>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surfaceBase,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const PreviewArtifactPickerSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Map registry kinds to a preview choice. Only the two shippable kinds
    // are previewable today; everything else renders as a muted "Soon"
    // launcher that can't be tapped.
    PreviewArtifactChoice? choiceFor(String kind) {
      switch (kind) {
        case ArtifactKind.planUrl:
          return PreviewArtifactChoice.workoutPlayer;
        case ArtifactKind.handout:
          return PreviewArtifactChoice.handout;
        default:
          return null;
      }
    }

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Drag handle — mirrors the publish-gate's own handle.
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: AppColors.surfaceBorder,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const Text(
              'Preview',
              style: TextStyle(
                fontFamily: 'Montserrat',
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: AppColors.textOnDark,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Pick which artifact to preview. Everything here renders '
              'from this session — nothing is published or charged.',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 12.5,
                color: AppColors.textSecondaryOnDark,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 20),

            // Kind rows — same order as the publish gate (handout first,
            // workout player second, then Soon kinds).
            ...ArtifactKindRegistry.all.map((spec) {
              final choice = choiceFor(spec.kind);
              final selectable = spec.shippable && choice != null;
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _PreviewKindRow(
                  spec: spec,
                  selectable: selectable,
                  onTap: selectable
                      ? () => Navigator.of(context).pop(choice)
                      : null,
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}

/// One picker row — visually a sibling of the publish gate's `_KindRow`,
/// trimmed for single-select use (no checkbox glyph, no price label; a
/// trailing chevron signals "tap to open", a "Soon" chip marks the
/// unshippable kinds).
class _PreviewKindRow extends StatelessWidget {
  final ArtifactKindSpec spec;
  final bool selectable;
  final VoidCallback? onTap;

  const _PreviewKindRow({
    required this.spec,
    required this.selectable,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final muted = !selectable;
    final bg = selectable ? AppColors.surfaceBase : AppColors.surfaceBg;
    const border = AppColors.surfaceBorder;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(13),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
          decoration: BoxDecoration(
            color: bg,
            border: Border.all(color: border, width: 1),
            borderRadius: BorderRadius.circular(13),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _PreviewKindGlyph(kind: spec.kind, muted: muted),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Flexible(
                          child: Text(
                            spec.label,
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 14.5,
                              fontWeight: FontWeight.w700,
                              color: muted
                                  ? AppColors.textSecondaryOnDark
                                  : AppColors.textOnDark,
                              letterSpacing: -0.1,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (muted) ...[
                          const SizedBox(width: 8),
                          const _SoonChip(),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      spec.description,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 11.5,
                        color: muted
                            ? AppColors.textSecondaryOnDark
                                .withValues(alpha: 0.6)
                            : AppColors.textSecondaryOnDark,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Trailing affordance: chevron for selectable rows, nothing
              // for Soon rows (the chip already carries the signal).
              if (selectable)
                const Icon(
                  Icons.chevron_right_rounded,
                  size: 22,
                  color: AppColors.textSecondaryOnDark,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Per-kind glyph tile — mirrors the publish gate's `_KindGlyph` so the
/// two sheets share an icon vocabulary.
class _PreviewKindGlyph extends StatelessWidget {
  final String kind;
  final bool muted;

  const _PreviewKindGlyph({required this.kind, required this.muted});

  @override
  Widget build(BuildContext context) {
    IconData icon;
    switch (kind) {
      case ArtifactKind.handout:
        icon = Icons.description_outlined;
        break;
      case ArtifactKind.planUrl:
        icon = Icons.play_arrow_rounded;
        break;
      case ArtifactKind.poster:
        icon = Icons.image_outlined;
        break;
      case ArtifactKind.reel:
        icon = Icons.grid_view_rounded;
        break;
      case ArtifactKind.aiReel:
        icon = Icons.auto_awesome;
        break;
      case ArtifactKind.calendar:
        icon = Icons.event_outlined;
        break;
      default:
        icon = Icons.help_outline;
    }
    final color = muted
        ? AppColors.textSecondaryOnDark.withValues(alpha: 0.55)
        : AppColors.textOnDark;
    return Container(
      width: 28,
      height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Icon(icon, size: 16, color: color),
    );
  }
}

/// "Soon" chip — same idiom as the publish gate's status chip, fixed to
/// the muted unshippable tone.
class _SoonChip extends StatelessWidget {
  const _SoonChip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Text(
        'Soon',
        style: TextStyle(
          fontFamily: 'Montserrat',
          fontWeight: FontWeight.w700,
          fontSize: 9.5,
          color: AppColors.textSecondaryOnDark,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}
