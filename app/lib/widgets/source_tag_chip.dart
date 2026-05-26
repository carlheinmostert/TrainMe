import 'package:flutter/material.dart';

import '../models/workout_source_tag.dart';
import '../theme.dart';

/// M29 (2026-05-26) — small inline chip rendered alongside the title of
/// a SessionCard on the My Workouts list. Mirrors the portal's
/// `SourceTagChip` component in `web-portal/src/components/SourceTagChip.tsx`.
///
/// Vocabulary:
///  * [WorkoutSourceTag.self]                  → "SELF" (sage chip)
///  * [WorkoutSourceTag.sharedByPractitioner] → "SHARED BY {email}" if
///    [sharedByEmail] is supplied, otherwise "SHARED" (coral chip)
///
/// Today only the [WorkoutSourceTag.self] branch is reachable. The
/// shared branch is wired so both surfaces light up at the same time
/// when the inbound-shared-plan ingest wave ships.
class SourceTagChip extends StatelessWidget {
  final WorkoutSourceTag tag;
  final String? sharedByEmail;

  const SourceTagChip({
    super.key,
    required this.tag,
    this.sharedByEmail,
  });

  @override
  Widget build(BuildContext context) {
    final isSelf = tag == WorkoutSourceTag.self;
    final label = isSelf
        ? 'SELF'
        : (sharedByEmail != null && sharedByEmail!.isNotEmpty
            ? 'SHARED BY ${sharedByEmail!.toUpperCase()}'
            : 'SHARED');
    // Sage for self (passive, your own library); coral for shared (active
    // inbound from someone else). Matches the portal's colour choice.
    final fg = isSelf ? const Color(0xFF86EFAC) : AppColors.primary;
    final bg = isSelf
        ? const Color(0x2686EFAC) // 15% sage
        : AppColors.primary.withValues(alpha: 0.15);
    final border = isSelf
        ? const Color(0x4D86EFAC) // 30% sage
        : AppColors.primary.withValues(alpha: 0.30);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: border, width: 1),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: 'Inter',
          fontSize: 9,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
          color: fg,
          // Slight drop shadow so the chip stays legible on the
          // filmstrip background even when the cell behind it is the
          // lightest hero. Mirrors the title's shadow grammar.
          shadows: const [
            Shadow(
              color: Color(0x99000000),
              blurRadius: 3,
              offset: Offset(0, 1),
            ),
          ],
        ),
      ),
    );
  }
}
