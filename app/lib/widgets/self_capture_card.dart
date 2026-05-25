import 'package:flutter/material.dart';

import '../models/exercise_capture.dart';
import '../models/session.dart';
import '../services/exercise_hero_resolver.dart';
import '../theme.dart';
import '../utils/hero_crop_alignment.dart';

/// Self-capture card archetype for the My Workouts list (PR #9 of the
/// self-trainer wave). See `docs/SELF_TRAINER_WAVE.md` § Self-capture
/// card design for the spec.
///
/// One row per self-recorded session. Layout:
/// - **Glyph (leading)** — Hero frame from the session's first non-rest
///   exercise via [resolveExerciseHero] with [HeroSurface.filmstrip].
///   While conversion is pending (or there's nothing to render yet), a
///   coral line-drawing motif placeholder takes its place.
/// - **Title** — `session.title` (the existing `{DD Mon YYYY HH:MM}`
///   format minted by `Session.create` callers).
/// - **Subtitle** — `"{N} exercises · captured {relative time ago}"`.
/// - **No chip** — the absence of a source chip differentiates self
///   captures from inbound categorised content (which doesn't ship in
///   this PR; the design doc holds the chip taxonomy for follow-ups).
///
/// Tap routing is owned by the parent screen — this widget just
/// surfaces an [onTap] callback.
class SelfCaptureCard extends StatelessWidget {
  final Session session;
  final VoidCallback onTap;

  const SelfCaptureCard({
    super.key,
    required this.session,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: AppColors.surfaceBase,
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.surfaceBorder, width: 1),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              // Leading glyph — Hero frame from the first non-rest
              // exercise via the canonical resolver, falling back to
              // the line-drawing placeholder when nothing's renderable
              // yet (cold pull before conversion completes, or an
              // empty session). 60×60 mirrors the leading icon
              // footprint on `_ClientCard` so the two surfaces read as
              // the same visual family on the Home spine.
              SizedBox(
                width: 60,
                height: 60,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: _LeadingGlyph(session: session),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _displayTitle(session),
                      style: const TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textOnDark,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _subtitle(session),
                      style: const TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 12,
                        color: AppColors.textSecondaryOnDark,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(
                Icons.chevron_right,
                color: AppColors.grey500,
                size: 22,
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _displayTitle(Session session) {
    final t = session.title;
    if (t != null && t.trim().isNotEmpty) return t.trim();
    return session.displayTitle;
  }

  static String _subtitle(Session session) {
    final renderableCount = session.exercises
        .where((e) => !e.isRest)
        .length;
    final exercisesLabel = renderableCount == 1 ? 'exercise' : 'exercises';
    final age = _relativeAge(session.createdAt);
    return '$renderableCount $exercisesLabel · captured $age';
  }

  static String _relativeAge(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 30) return 'just now';
    if (diff.inMinutes < 1) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    if (diff.inDays < 30) {
      final weeks = (diff.inDays / 7).floor();
      return weeks == 1 ? '1w ago' : '${weeks}w ago';
    }
    final months = (diff.inDays / 30).floor();
    return months == 1 ? '1mo ago' : '${months}mo ago';
  }
}

/// Leading visual for the card. Picks the first non-rest exercise with
/// a renderable Hero frame and routes through the canonical
/// [resolveExerciseHero] (per `feedback_hero_resolver_single_source`).
/// Falls back to a coral line-drawing motif placeholder when nothing's
/// rendererable yet (conversion pending on a brand-new session, or an
/// empty session).
class _LeadingGlyph extends StatelessWidget {
  final Session session;
  const _LeadingGlyph({required this.session});

  @override
  Widget build(BuildContext context) {
    final exercise = _pickHeroSource(session);
    if (exercise == null) {
      return const _LineDrawingPlaceholder();
    }
    final hero = resolveExerciseHero(
      exercise: exercise,
      surface: HeroSurface.filmstrip,
    );
    final file = hero.posterFile;
    if (file == null) {
      return const _LineDrawingPlaceholder();
    }
    final align = heroCropAlignment(exercise);
    Widget image = Image.file(
      file,
      fit: BoxFit.cover,
      alignment: align,
      cacheWidth: 180,
      gaplessPlayback: true,
      errorBuilder: (context, error, stackTrace) =>
          const _LineDrawingPlaceholder(),
    );
    final filter = hero.filter;
    if (filter != null) {
      image = ColorFiltered(colorFilter: filter, child: image);
    }
    return SizedBox.expand(child: image);
  }

  /// Pick the first non-rest exercise whose Hero frame is on disk. The
  /// resolver returns `posterFile == null` when nothing's renderable
  /// (pending / failed conversion). Walking the list lets a partly-
  /// converted session still show a glyph from the second or third
  /// capture once it lands.
  static ExerciseCapture? _pickHeroSource(Session session) {
    for (final e in session.exercises) {
      if (e.isRest) continue;
      final hero = resolveExerciseHero(
        exercise: e,
        surface: HeroSurface.filmstrip,
      );
      if (hero.posterFile != null) return e;
    }
    return null;
  }
}

/// Coral line-drawing motif placeholder. Renders as the leading glyph
/// when no Hero frame is available yet (cold pull pre-conversion, or
/// an empty session). Intentionally simple so it doesn't compete with
/// the real hero once it lands.
class _LineDrawingPlaceholder extends StatelessWidget {
  const _LineDrawingPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
      ),
      alignment: Alignment.center,
      child: const Icon(
        Icons.fitness_center_rounded,
        color: AppColors.primary,
        size: 28,
      ),
    );
  }
}
