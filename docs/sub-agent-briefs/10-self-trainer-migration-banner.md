# Brief — PR #10: Migration in-app banner + grandfathered user copy

**Target branch:** `feat/self-trainer-migration-banner`
**Target merge:** `staging`
**Depends on:** PR #1 (schema — `safe_mode_grandfathered`)
**Sensitive zone:** copy is Carl-reviewed

## Context

`docs/SELF_TRAINER_WAVE.md` § "Migration plan" § "Communication".

Single in-app banner on first launch post-update. Universal copy + an additional grandfathered-user line.

## Acceptance criteria

1. **Banner widget** — `app/lib/widgets/self_trainer_intro_banner.dart` (new). Dismissible. Renders in Home (above the scope row, below the brand lockup) on cold launch IF `SharedPreferences['self_trainer_intro_dismissed'] != true`. Once dismissed, never re-shows.

2. **Copy template** (refine with Carl on review):
   > **My Workouts is live**
   > Capture yourself, get plans from your practitioner — all in one place.
   > [ Got it ]

   If `practice_members.safe_mode_grandfathered = true` for this user (check via cached membership), append a second line:
   > Safe Mode is now a subscription. Because you've used it, we've extended your access for free — no action needed.

3. **No push notification, no email** — banner is the only channel (per Q13.5 (a)).

4. **Test script** — `docs/test-scripts/2026-05-25-self-trainer-banner.md`. Items: (a) first cold launch post-update: banner appears; (b) tap "Got it": banner dismisses + flag persists; (c) re-launch: banner doesn't re-appear; (d) grandfathered user sees the additional line; (e) non-grandfathered user sees only the universal line.

5. **Copy review** — final copy is **Carl-review-required** before merge.

## Hard rules

- **Repo-relative paths only**.
- **Copy review required.**
- **No mobile deployment.**
- **No emojis.**
- **Branch**: `feat/self-trainer-migration-banner`.
