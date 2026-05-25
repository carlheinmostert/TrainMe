# 2026-05-25 — My Workouts body + FAB + self-capture cards

Self-trainer wave PR #9. Replaces the locked "Coming soon" teaser body of
the My Workouts scope on Home with the real list of self-captures, wires
the New Session FAB to the full capture-entry path, and adds self-capture
cards with tap routing into the Studio.

## Scope

- New body widget at `app/lib/screens/my_workouts_screen.dart`.
- New self-capture card archetype at `app/lib/widgets/self_capture_card.dart`.
- `clients.user_id` surfaced through `list_practice_clients` and
  `get_client_by_id` so the local cache can identify the Self-client.
- SQLite v48 — `cached_clients.user_id TEXT` mirrors the cloud column.
- Updated chrome on My Workouts: "Updated N min ago" hint + sync-failed
  banner extend to this scope (per `docs/SELF_TRAINER_WAVE.md` § Chrome
  on My Workouts).

## Pre-flight

- Build SHA visible in HomeLogo footer matches the PR's head.
- Signed in to a fresh QA account (use `qa@homefit.studio` on staging).
- Home scope picker defaults to "My Workouts" on cold install.

## Items

- [ ] 1. Cold install + no captures: My Workouts shows full-screen "Record
       your first workout" CTA, with the muted "Got a link from your
       practitioner? Tap to claim it." text below. No popups, no chip.
- [ ] 2. Tap New Session FAB without face-recognition consent + with a
       Public-profile selfie set: the inline consent sheet appears (no
       modal popup — slides up from bottom).
- [ ] 3. Tap New Session FAB without a Public-profile selfie set: SnackBar
       prompts "Add a selfie in Settings > Public profile first…". No
       session is minted.
- [ ] 4. Tap New Session FAB after consent has been granted: a fresh
       session is minted locally and the SessionShellScreen opens with
       Camera mode as the default (page 1, not Studio). No "Coming in PR
       #9" toast.
- [ ] 5. After capturing a single exercise and popping back to Home, the
       new session appears at the top of the My Workouts list within ~1s
       (no manual refresh required — the parent re-loads on pop).
- [ ] 6. Self-capture card tap routes to SessionShellScreen in Studio
       mode (page 0). Inbound-card flow is deferred; no inbound rows
       should render in this PR.
- [ ] 7. Self-capture card title reads `{DD Mon YYYY HH:MM}` (e.g. `25
       May 2026 14:32`), subtitle reads `{N} exercises · captured {N}m
       ago`. Glyph shows the first exercise's Hero frame, or the coral
       line-drawing-motif placeholder while conversion is still pending.
- [ ] 8. List is sorted reverse-chronologically. Capture three sessions
       in a row and confirm the newest one shows at the top.
- [ ] 9. Toggle airplane mode on, kill + relaunch the app: the My
       Workouts list still renders the cached sessions (offline-first —
       reads from local SQLite, no spinner-of-doom).
- [ ] 10. "Updated N min ago" hint surfaces above the workouts list when
        a successful sync has happened. Pull-to-refresh on the workouts
        list also re-reads the local cache.
- [ ] 11. Simulate a sync failure (toggle network off during a manual
        refresh): the coral "Couldn't refresh. Tap to retry." banner
        appears above the workouts list (same banner the clients list
        gets — extended in this PR per the design doc).
- [ ] 12. Open Clients scope → confirm the Self-client row does NOT
        appear in the Clients list (cloud-side: yes, it's a clients row;
        UI-side: the Clients list only shows non-self clients).
- [ ] 13. Switch practices via Settings → Account → Practice switcher.
        Confirm the My Workouts list still shows the same sessions (the
        Self-client lives in the user's owner-practice; switching to a
        practice you joined as a practitioner should leave the workouts
        body unchanged, since it's keyed off `clients.user_id` not the
        active practice).

## Out of scope

- Inbound shared plans (`plan_invitations`) — deferred to a follow-up
  wave per `docs/SELF_TRAINER_WAVE.md`. Empty-state surfaces a muted
  "Got a link from your practitioner? Tap to claim it." line without an
  action.
- Safe Mode banner sub-status chip integration with PR #8 — design doc
  is ambiguous on placement; will ship as a follow-up if needed.

## Notes

- Self-client identification is done locally via the new `clients.user_id`
  column surfaced through `list_practice_clients`. No second cloud
  round-trip from the Home screen.
- Session creation is purely local (`LocalStorageService.saveSession`)
  matching the existing `ClientSessionsScreen._startNewSession` pattern.
  No `create_session` RPC exists or is invoked.
