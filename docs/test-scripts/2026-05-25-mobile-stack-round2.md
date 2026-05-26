# Mobile stack round 2 — device QA

Three mobile fixes landing together: always-on-launch My Workouts, unified session-card on My Workouts (swipe-delete + filmstrip), Safe Mode hint overlay toggle promoted out of the easter-egg gate.

PR: `fix(mobile-stack-round2): M12 always-my-workouts-default + M13 unified-session-card + M14 safe-mode-hud-toggle`

## Pre-flight

- App built from this branch (`fix/mobile-stack-round2`) installed on iPhone CHM.
- Signed in. At least one self-recorded workout exists on the My Workouts tab so the card surfaces are testable. If not, capture a quick photo via the My Workouts FAB first.

## Tests

- [ ] **1. Cold launch lands on My Workouts.** Force-quit the app (swipe up from app switcher). Reopen. Home opens with the **My Workouts** segment selected, regardless of which tab you were on previously.

- [ ] **2. Tab selection still works mid-session.** Tap **Clients** in the top segmented control. The Clients list renders. Tap **My Workouts** — the My Workouts list renders again. The selection is sticky during the current session.

- [ ] **3. Re-launch ignores the persisted tab.** With **Clients** selected from test 2, force-quit and reopen. The app lands on **My Workouts** again (the persisted Clients selection is ignored on launch).

- [ ] **4. My Workouts cards show the same filmstrip background as Clients cards.** Open My Workouts. Cards with captured exercises render with a horizontally-tiled B&W filmstrip background (1-4 hero frames depending on session size), a 30% dark veil, and a coral exercise-count glyph at the leading edge. The visual treatment matches the cards on a Client detail page.

- [ ] **5. Swipe-left to delete a My Workouts session works.** Swipe left on any My Workouts card. The row dismisses immediately, and a SnackBar appears at the bottom with "**{title} deleted**" and an **Undo** action. Tap **Undo** — the card returns to the list.

- [ ] **6. Settings → Debug → "Show Safe Mode hint overlay" toggle is visible.** Open **Settings**. Scroll to the bottom. A **Debug** section is visible (between **About** and the build-SHA marker / Powered By footer) containing a single row labelled **Show Safe Mode hint overlay** with a switch. The toggle is reachable without the 7-tap easter egg.

- [ ] **7. Safe Mode hint overlay toggle flips the camera HUD.** With test 6's toggle OFF, enter Camera mode in any session. The viewfinder has NO Safe Mode debug HUD (no GPS / polygon-match readout strip). Return to Settings, flip the toggle ON. Re-enter Camera mode — the HUD now overlays the viewfinder.

## Notes

- M12 fix: removed `_loadScope()` call from `HomeScreen.initState`. Tab selection still persists via `_setScope` for parity, but the persisted value is never read on launch.
- M13 fix: `my_workouts_screen.dart` now uses the canonical `SessionCard` widget (same as `client_sessions_screen.dart`). The legacy `SelfCaptureCard` file remains in the repo but is no longer wired — safe to delete in a follow-up cleanup PR.
- M14 fix: the `SafeModeDebugHudPreference` toggle was already wired in code but lived inside the `if (_diagnosticsVisible)` gate (the 7-tap easter egg). The toggle now lives in a dedicated **Debug** section above the build-SHA marker, always visible.
