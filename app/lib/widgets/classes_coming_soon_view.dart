import 'package:flutter/material.dart';

import '../theme.dart';

/// Permanent landing surface for the future Classes feature. Renders
/// as the body of [HomeScreen] when the scope segmented control is on
/// Classes. The shape of this screen IS the shape the real Classes
/// screen will take: a value-prop header, then a list of class cards.
/// Today the cards are mock examples behind a locked state — that's
/// the advertisement. When Classes ships, this widget gets swapped for
/// a real `ClassesListScreen` at the same callsite in [HomeScreen];
/// the surrounding chrome and segmented control don't move.
class ClassesComingSoonView extends StatelessWidget {
  const ClassesComingSoonView({super.key});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      physics: const AlwaysScrollableScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          SizedBox(height: 8),
          _Headline(),
          SizedBox(height: 18),
          _MockCard(
            title: 'Glutes & Hamstrings',
            subtitle: '6-week block · 18 sessions',
            mode: 'Subscription',
          ),
          _MockCard(
            title: 'Posture Reset',
            subtitle: '14 sessions',
            mode: 'One-time',
          ),
          _MockCard(
            title: 'Beginner Mobility',
            subtitle: '4 sessions',
            mode: 'Subscription',
          ),
          _Footnote(),
        ],
      ),
    );
  }
}

class _Headline extends StatelessWidget {
  const _Headline();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(4, 4, 4, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'One plan. Many clients.',
            style: TextStyle(
              fontFamily: 'Montserrat',
              fontSize: 22,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.3,
              color: AppColors.textOnDark,
              height: 1.2,
            ),
          ),
          SizedBox(height: 6),
          Text(
            'Build a class once, share it with everyone who buys or '
            'subscribes. Coming after Clients lands.',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: AppColors.textSecondaryOnDark,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}

class _MockCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final String mode;

  const _MockCard({
    required this.title,
    required this.subtitle,
    required this.mode,
  });

  @override
  Widget build(BuildContext context) {
    // Cards are deliberately non-interactive — no InkWell, no chevron.
    // The lock glyph top-right is the only state cue: this is a real
    // class card shape, but you can't open it yet. Opacity held just
    // shy of 60% so the layout still reads as a class library, not as
    // a ghost.
    return Opacity(
      opacity: 0.62,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 5),
        decoration: BoxDecoration(
          color: AppColors.surfaceBase,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.surfaceBorder, width: 1),
        ),
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: AppColors.brandTintBg,
                borderRadius: BorderRadius.circular(12),
              ),
              alignment: Alignment.center,
              child: const Icon(
                Icons.groups_outlined,
                color: AppColors.primary,
                size: 28,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
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
                    subtitle,
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 12,
                      color: AppColors.textSecondaryOnDark,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.brandTintBg,
                      borderRadius: BorderRadius.circular(100),
                    ),
                    child: Text(
                      mode,
                      style: const TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: AppColors.primary,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(
              Icons.lock_outline_rounded,
              size: 20,
              color: AppColors.textSecondaryOnDark,
            ),
          ],
        ),
      ),
    );
  }
}

class _Footnote extends StatelessWidget {
  const _Footnote();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(4, 16, 4, 0),
      child: Row(
        children: [
          Icon(
            Icons.lock_outline_rounded,
            size: 14,
            color: AppColors.textSecondaryOnDark,
          ),
          SizedBox(width: 6),
          Expanded(
            child: Text(
              'Examples only. Real classes unlock when this ships.',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: AppColors.textSecondaryOnDark,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
