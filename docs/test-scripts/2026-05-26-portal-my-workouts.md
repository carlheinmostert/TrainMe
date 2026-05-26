# 2026-05-26 — Portal My Workouts entry-point (M29)

PR: `feat(my-workouts): M29 portal entry-point + view-only drill-in + source-tag system`

Branch: `feat/portal-my-workouts` → `staging`.

Adds a view-only mirror of the mobile My Workouts list to `manage.homefit.studio`:

- Dashboard tile in primary position (above Credits, Clients, Classes).
- `/my-workouts` list page filtered to plans where the practitioner is the SUBJECT (`clients.user_id = auth.uid()`).
- `/my-workouts/[id]` read-only drill-in (no edit / publish / share CTAs).
- Source-tag chip system shared between mobile + portal — every row reads "SELF" today; the "SHARED BY ..." branch is wired but not reachable until the inbound-shared-plan ingest wave ships.

## Walk-through

- [ ] 1. Open `manage.homefit.studio/dashboard`. Verify the first tile (top-left of the grid) is labelled "My Workouts" with a dumbbell icon. The tile sits ABOVE Credits, Clients (private), and Classes (group).
- [ ] 2. The My Workouts tile headline reads "N workouts" (or "No workouts yet") and the subtitle reads "Latest Xd ago" (or "Record your first in the iOS app" when empty).
- [ ] 3. Tap the My Workouts tile. Page route is `/my-workouts?practice=...`. Header still shows the practice switcher; back-link reads `← Home`.
- [ ] 4. The list page H1 reads "My Workouts" with a subtitle "N workouts." and a one-line description: "Workouts where you are both the practitioner and the subject. Capture happens in the iOS app — this surface is for review."
- [ ] 5. Each row in the list shows: title, a sage SELF chip directly next to the title, exercise/share/version metadata, and "Published Xd ago" (or "Not published yet").
- [ ] 6. The search input filters in real time. Filter count subtitle updates ("3 of 7 workouts").
- [ ] 7. Tap any row. Route is `/my-workouts/{uuid}?practice=...`. Page renders a single Details card with: Exercises, Version, Shares, Last published, First opened, Subject (if set).
- [ ] 8. The drill-in has NO edit, publish, share, or "open in player" buttons anywhere. Just metadata + back-link.
- [ ] 9. The drill-in title also shows the sage SELF chip next to the H1.
- [ ] 10. Hit a bogus uuid (`/my-workouts/00000000-0000-0000-0000-000000000000`) — Next.js 404 page renders. No leak of "this exists but isn't yours" vs "doesn't exist".
- [ ] 11. iOS app side: open My Workouts. Each session card now has a small sage "SELF" chip above the title (between the leading count glyph and the title). The chip is suppressed on Clients → Client detail session cards.
