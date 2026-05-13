import 'package:flutter/material.dart';

import '../theme.dart';

/// Permanent landing surface for the future My Workouts (consumer
/// mode) feature. Renders as the body of [HomeScreen] when the
/// right-hand scope capsule is active. The shape of this screen IS
/// the shape the real My Workouts screen will take: a value-prop
/// header, then a list of workout cards mixing practitioner-sent
/// plans (sage chip) and subscribed/bought classes (coral chip).
///
/// Today the cards are mock examples behind a locked state — that's
/// the advertisement. When My Workouts ships, this widget gets
/// swapped for the real workouts list at the same callsite in
/// [HomeScreen]; the surrounding chrome and scope row don't move.
///
/// Twin of [ClassesComingSoonView] for the right-hand capsule.
class WorkoutsComingSoonView extends StatelessWidget {
  const WorkoutsComingSoonView({super.key});

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
            title: 'Knee rehab — Week 2',
            subtitle: 'from Dr. Sarah · 6 sessions',
            modeLabel: 'From practitioner',
            sage: true,
          ),
          _MockCard(
            title: 'Beginner Mobility',
            subtitle: '4 sessions · joined 2 weeks ago',
            modeLabel: 'Subscribed class',
            sage: false,
          ),
          _MockCard(
            title: 'Morning routine',
            subtitle: 'from Dr. Sarah · 4 sessions',
            modeLabel: 'From practitioner',
            sage: true,
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
            'Your workouts, here.',
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
            'When your practitioner sends a plan or you join a class, '
            'it lands in your pocket. Play offline. No browser.',
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
  final String modeLabel;
  /// When true, the leading glyph + mode pill use the sage rest
  /// palette ("from a practitioner"); when false they use the coral
  /// brand palette ("a class you subscribed/bought").
  final bool sage;

  const _MockCard({
    required this.title,
    required this.subtitle,
    required this.modeLabel,
    required this.sage,
  });

  @override
  Widget build(BuildContext context) {
    // Sage palette mirrors AppColors.rest (#86EFAC) for the
    // practitioner-sent treatment. Coral picks up the brand tint
    // for the subscribed/bought class treatment.
    const sageColor = AppColors.rest;
    final sageTint = sageColor.withValues(alpha: 0.16);
    final glyphBg = sage ? sageTint : AppColors.brandTintBg;
    final glyphFg = sage ? sageColor : AppColors.primary;
    final pillBg = sage ? sageTint : AppColors.brandTintBg;
    final pillFg = sage ? sageColor : AppColors.primary;

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
                color: glyphBg,
                borderRadius: BorderRadius.circular(12),
              ),
              alignment: Alignment.center,
              child: Icon(
                sage
                    ? Icons.spa_outlined
                    : Icons.groups_outlined,
                color: glyphFg,
                size: 26,
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
                      color: pillBg,
                      borderRadius: BorderRadius.circular(100),
                    ),
                    child: Text(
                      modeLabel,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: pillFg,
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
              'Examples only. Real workouts unlock when this ships.',
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
