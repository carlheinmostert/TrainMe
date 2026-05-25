# Brief — PR #9: My Workouts body + FAB wire-up + self-capture cards + tap routing

**Target branch:** `feat/my-workouts-body`
**Target merge:** `staging`
**Depends on:** PR #2 (IA rename), PR #4 (consent flow), PR #5 (verification), PR #6 (publish cost)
**Sensitive zone:** Home rendering pipeline (touches SyncService reads)

## Context

`docs/SELF_TRAINER_WAVE.md` § "Self-capture card design" + § "Capture-entry path from My Workouts" + § "IA changes" § "Chrome on My Workouts".

This PR replaces the locked-teaser body of My Workouts (today: "Coming soon" placeholder cards from `WorkoutsComingSoonView`) with the real list of self-captures + inbound shared plans, wires up the New Session FAB, and implements the tap routing.

## Acceptance criteria

1. **Real body widget** — `app/lib/screens/my_workouts_screen.dart` (new) replaces `app/lib/widgets/workouts_coming_soon_view.dart`'s usage in `app/lib/screens/home_screen.dart`. Reads self-captures (from local SQLite cache populated by SyncService — see #2 below) + inbound plan invitations (TBD — section 1b of `CLIENT_WORKOUTS_AND_CLASSES.md` defers this; for v1, query `plan_invitations` where `accepted_by_user_id = me`).

2. **Cache extension** — `app/lib/services/sync_service.dart` gains a pull branch for the user's self-plans (via a new RPC `list_my_workouts(p_user_id) RETURNS TABLE (...)`). Per `feedback_offline_first_pull_branches`, the pull branch is non-negotiable for any new offline-cached surface. Mirror plans where `client_id = (SELECT id FROM clients WHERE user_id = auth.uid())`.

3. **Self-capture card archetype** — `app/lib/widgets/self_capture_card.dart` (new). Glyph: Hero frame from session (per `app/lib/widgets/exercise_hero_resolver.dart` if it exists, else fallback to first exercise's thumbnail). During conversion-pending: line-drawing motif placeholder. No chip. Title: `{DD Mon YYYY HH:MM}` (from session.title). Subtitle: `"{N} exercises · captured {relative time ago}"`.

4. **Tap routing** — `_onCardTap` in `my_workouts_screen.dart`:
   - If `client_id = self_client_id` → push `SessionShellScreen` in Studio mode (default).
   - Else (inbound from practitioner or subscribed class) → push `PlanPreviewScreen` in playback mode.

5. **New Session FAB** — wired up. On tap: check `face_embedding_consented_at` + self-client exists. If both present: create session (via existing `create_session` RPC, `client_id = self_client_id`), navigate to SessionShellScreen with Camera mode default (per Q6.4). If consent missing: surface the inline consent sheet from PR #4 first.

6. **Empty state** — when zero items: full-screen "Record your first workout" CTA (large) + secondary "Got a link from your practitioner? Tap to claim it." (deferred — for now show as muted text without action).

7. **Sort** — flat reverse-chronological by `captured_at` (or `created_at` for inbound plans).

8. **Chrome extensions** — `home_screen.dart` extends the "Updated N min ago" hint + sync-failed banner conditions to include `_scope == HomeScope.workouts` (today they are Clients-scope-only). Per design doc § "Chrome on My Workouts".

9. **Safe Mode banner sub-status chip** — depends on PR #8 landing first (which adds the chip). If PR #8 is not yet merged, this PR ships without the chip integration; chip lands later.

10. **R-10 parity** — N/A — this is a Home screen, no web equivalent.

11. **Test script** — `docs/test-scripts/2026-05-25-my-workouts-body.md`. Items: (a) cold install + no captures: empty state shows "Record your first workout"; (b) tap FAB without consent: consent sheet appears; (c) tap FAB with consent: session minted, Camera opens; (d) self-capture card tap: opens Studio; (e) inbound card tap: opens Preview; (f) cards sorted reverse-chronologically; (g) offline cache: cards still render without network; (h) sync after capture: new card appears in list within 2s.

## Hard rules

- **Repo-relative paths only**.
- **Sensitive zone — Home rendering + SyncService changes per `feedback_sensitive_code_review_before_merge`.**
- **Offline-first** — list reads from local cache first (per `feedback_offline_first_pull_branches`); background sync refreshes.
- **No direct DB access** — all via `ApiClient` + SyncService cache.
- **R-10 N/A**.
- **No mobile deployment.**
- **No popups ever** (per `feedback_no_popups_ever`) — entity creation flows are inline + default-named, no modals.
- **No emojis.**
- **Branch**: `feat/my-workouts-body`.
