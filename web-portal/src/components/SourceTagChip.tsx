import type { WorkoutSourceTag } from '@/lib/supabase/api';

/**
 * M29 (2026-05-26) — small inline chip rendered alongside the title
 * of a row in the My Workouts list / drill-in. Shared vocabulary with
 * the mobile `SessionCard`'s source-tag chip (see
 * `app/lib/widgets/session_card.dart`'s `SourceTagChip`).
 *
 * Today the only value that ever renders is `'self'`. The
 * `'shared_by_practitioner'` branch is wired up but not reachable
 * until the inbound-shared-plan ingest wave ships. Both surfaces light
 * up together at that point — no portal-only or mobile-only chip.
 *
 * Vocabulary:
 *  - `self`                   → "Self" (sage chip)
 *  - `shared_by_practitioner` → "Shared by {email}" if email is known,
 *                               otherwise "Shared" (coral chip)
 *
 * Why a coral tint for shared-by and sage for self: matches the mobile
 * pattern from the My Workouts teaser in
 * `docs/CLIENT_WORKOUTS_AND_CLASSES.md` ("sage chip = practitioner-
 * sent, coral chip = subscribed class") — Carl explicitly described
 * that mix on the locked teaser. We're inverting "practitioner-sent"
 * to coral here because in the My Workouts surface the practitioner
 * is the SUBJECT (sage = passive), and a shared-by-other-practitioner
 * row demands more attention (coral = active inbound). When the inbound
 * branch ships we'll re-validate the colour pairing against Carl's
 * mockups.
 */
export function SourceTagChip({
  sourceTag,
  sharedByEmail,
}: {
  sourceTag: WorkoutSourceTag;
  sharedByEmail?: string | null;
}) {
  if (sourceTag === 'self') {
    return (
      <span
        className="inline-flex items-center rounded-full bg-emerald-500/15 px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wider text-emerald-300 ring-1 ring-inset ring-emerald-500/30"
        title="You are both the practitioner and the subject of this workout"
      >
        Self
      </span>
    );
  }
  // shared_by_practitioner — reserved branch (no real data yet).
  const label = sharedByEmail
    ? `Shared by ${sharedByEmail}`
    : 'Shared';
  return (
    <span
      className="inline-flex items-center rounded-full bg-brand/15 px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wider text-brand ring-1 ring-inset ring-brand/30"
      title={
        sharedByEmail
          ? `Shared with you by ${sharedByEmail}`
          : 'Shared with you by another practitioner'
      }
    >
      {label}
    </span>
  );
}
