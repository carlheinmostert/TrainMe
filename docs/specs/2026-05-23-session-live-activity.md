# 2026-05-23 — Session Live Activity

**Status:** signed off by Carl 2026-05-23. Implementation wave to follow immediately.
**Target branch:** `feat/session-live-activity` → `staging`.
**Mockup:** `docs/design/mockups/2026-05-23-live-activity-states.html` (approved).

## Table of Contents

- [Problem statement](#problem-statement)
- [Design summary](#design-summary)
- [The 12 decisions](#the-12-decisions)
- [Native iOS surface](#native-ios-surface)
- [Dart surface](#dart-surface)
- [Lifecycle](#lifecycle)
- [Content state contract](#content-state-contract)
- [Update cadence](#update-cadence)
- [Cold-start + orphan recovery](#cold-start--orphan-recovery)
- [Privacy posture](#privacy-posture)
- [Carl-side checklist](#carl-side-checklist)
- [Implementation order](#implementation-order)
- [Cut-lines if scope bloats](#cut-lines-if-scope-bloats)
- [Test plan](#test-plan)
- [Out of scope](#out-of-scope)
- [Open risks](#open-risks)

## Problem statement

Practitioners deliberately lock the phone between captures during a session — pocketing it while demoing the next exercise to the client, or putting it down between exercises. Re-entering the capture flow today requires: unlock → app → resume session → swipe to Camera. Four steps from a cold lock.

The goal is to compress that to: unlock → tap Live Activity → Camera. The activity also doubles as a glance-able identity confirmation ("am I capturing the right client?") and Safe Mode state confirmation ("are bystanders being blurred?") — both visible without unlocking.

## Design summary

iOS Live Activity (ActivityKit) pinned for the duration of `SessionShellScreen`. Identity-first lock-screen card (avatar + client name + capture count) with Safe Mode chrome (coral border, glow, banner) when the geofence is active. Dynamic Island compact / minimal / expanded states reuse the same content state. One activity ever per device, identified by session UUID — orphans reconciled on cold-start. iOS-only feature (mobile-only by definition; no R-10 web-player twin).

## The 12 decisions

| # | Decision | Locked value |
|---|---|---|
| Q1 | Underlying behaviour | Deliberate locking → Live Activity is the right mechanism. (Separately: wake-lock during session shell is not part of this PR.) |
| Q2 | Platform mechanism | iOS Live Activity (ActivityKit), not sticky notification or Shortcut |
| Q3 | Lifecycle | Start on `SessionShellScreen` entry; end on shell exit OR publish; persists through background/lock; iOS hard cap 8h foreground / 12h total |
| Q4 | Lock-screen content | Identity-first: avatar + client name + capture count + Safe Mode chrome. (Carl deliberately overrode the conservative "no client identity on lock screen" recommendation — see [Privacy posture](#privacy-posture).) |
| Q5 | Avatar fallback, caching, Safe Mode updates | Initials in coral circle when no avatar; pre-cache avatar PNG to App Group container on shell entry; stream-driven Safe Mode updates with 5s debounce |
| Q6 | Tap target + buttons | Tap body → SessionShellScreen Camera mode always; "Capture next" App Intent button on iOS 17+; iOS deployment target bumped 15 → 16.1 |
| Q7 | Activity identity | One activity ever, keyed to session UUID; reconcile orphans on cold-start; end on shell dispose |
| Q8 | Permission flow | Silent no-op if disabled; one-time coral toast on second shell entry; Settings row shows on/off state with deep-link to iOS Settings |
| Q9 | Dynamic Island layout | Compact: avatar leading + (coral count OR shield-on-Safe-Mode) trailing; Minimal: coral initials chip; Expanded: lock-screen card reused |
| Q10 | Update cadence | Only on capture-completed + Safe-Mode-flip (5s debounced); location authorization bumped `whenInUse` → `always` so shield is truthful while locked |
| Q11 | PR scope | Single PR `feat/session-live-activity` → `staging`; two safety-valve cut-lines defined |
| Q12 | Test plan | 17 numbered items covering happy path + failure modes |

## Native iOS surface

### New Xcode target

`HomefitSessionActivity` — Widget Extension target containing:
- `SessionActivityAttributes.swift` — defines `ActivityAttributes` (immutable: `sessionId`, `practiceId`) and `ContentState` (mutable, see [Content state contract](#content-state-contract))
- `SessionActivityWidget.swift` — `Widget` declaration with `ActivityConfiguration<SessionActivityAttributes>`
- `SessionActivityLockScreenView.swift` — SwiftUI view rendering the lock-screen card layout from the mockup
- `SessionActivityDynamicIslandViews.swift` — compact / minimal / expanded view bodies
- `OpenCameraIntent.swift` — App Intent (iOS 17+) that ferries the session UUID back to the app on button tap

### App Group entitlement

`group.studio.homefit.app` declared on both `Runner` and `HomefitSessionActivity` targets. Used to share:
- Avatar PNG file (`{App Group container}/avatars/{clientId}.png`)
- Any future shared state

Provisioning profile must be re-rolled when adding the App Group capability. Coordinate with Carl before merging.

### Runner-side additions

- `HomefitLaunchChannel.swift` — Flutter platform channel (`studio.homefit.app/launch`) that captures the launch URL / App Intent payload at app start and surfaces it to Dart via `getInitialLaunchContext()` and an `onLaunchContext` stream.
- `AppDelegate.swift` — register the launch channel; in `application(_:open:options:)` and in the App Intent perform handler, capture the session UUID and push it through the channel.
- `Info.plist` — `NSLocationAlwaysAndWhenInUseUsageDescription` string added: *"homefit uses your location to keep Safe Mode active when your phone is locked — so the lock-screen card always shows whether bystanders are being blurred."*

### iOS deployment target

Bump from `15.0` to `16.1` in:
- `app/ios/Podfile`
- `app/ios/Runner.xcodeproj/project.pbxproj` (`IPHONEOS_DEPLOYMENT_TARGET` on all configs)
- `app/ios/Runner/Info.plist` (`MinimumOSVersion` if present)

## Dart surface

### New service

`app/lib/services/live_activity_service.dart` — singleton, wraps the `live_activities` Flutter plugin:

```dart
class LiveActivityService {
  static final instance = LiveActivityService._();
  Future<bool> get isSupported;           // areActivitiesEnabled + iOS 16.1+
  Future<bool> startForSession(Session s, Client c);
  Future<void> updateCaptureCount(int count, String lastName);
  Future<void> updateSafeMode(bool active);
  Future<void> end({Reason reason});      // .shellExit | .publish
  Future<void> reconcileOrphans();        // called on cold-start
}
```

### New widgets / UI

- `app/lib/widgets/live_activity_intro_toast.dart` — one-time coral toast on second session-shell entry. Gated by `SharedPreferences` key `shown_live_activity_intro_v1`.
- `app/lib/screens/settings_screen.dart` — new row "Lock screen access" with on/off state + deep-link button (`url_launcher` to `app-settings:`).

### Wiring points

- `app/lib/screens/session_shell_screen.dart` — `initState` calls `LiveActivityService.instance.startForSession(...)`; `dispose` calls `end(reason: .shellExit)`.
- `app/lib/services/conversion_service.dart` — on capture completion (after the row is inserted), call `updateCaptureCount(...)`.
- `app/lib/services/safe_mode_service.dart` — add a listener that calls `updateSafeMode(...)` with 5s debounce per [Q5](#the-12-decisions).
- `app/lib/services/upload_service.dart` — on successful publish, call `end(reason: .publish)`.
- `app/main.dart` — on app start, before `runApp`, await `LiveActivityService.instance.reconcileOrphans()`.
- `app/lib/auth/auth_gate.dart` — consume the launch context from `HomefitLaunchChannel` and route to `SessionShellScreen(sessionId: ..., initialPage: .camera)` if present. If the session UUID doesn't resolve in local SQLite, land on `ClientListScreen` with a coral toast: *"That session is no longer available."*

## Lifecycle

```
SessionShellScreen.initState
  → LiveActivityService.startForSession(session, client)
    → pre-cache avatar PNG to App Group container
    → Activity.request(attributes, contentState, pushType: .none)

[user backgrounds app / locks phone — activity persists]

capture completed
  → LiveActivityService.updateCaptureCount(n, lastName)

SafeModeService.isActive flips
  → debounce 5s
  → LiveActivityService.updateSafeMode(true/false)

[user taps activity from lock screen]
  → iOS launches/resumes app
  → HomefitLaunchChannel hands session UUID to Dart
  → AuthGate navigates to SessionShellScreen(sessionId, initialPage: .camera)

publish success → LiveActivityService.end(reason: .publish)
OR
SessionShellScreen.dispose → LiveActivityService.end(reason: .shellExit)

[app cold-start, anywhere outside a shell]
  → LiveActivityService.reconcileOrphans()
    → enumerate Activity<SessionActivityAttributes>.activities
    → end every one
```

## Content state contract

**Attributes (immutable, set at `Activity.request` time):**
- `sessionId: UUID`
- `practiceId: UUID`

**Content state (mutable, updated via `Activity.update`):**
- `clientName: String`
- `clientInitials: String` (max 2 chars, derived Dart-side from `client.name`)
- `avatarFilePath: String?` (absolute path inside App Group container; nil → render initials)
- `captureCount: Int`
- `lastCapturedName: String?` (used in expanded Dynamic Island only)
- `safeModeActive: Bool`
- `sessionTitle: String` (auto-format `23 May 2026 14:30`)

## Update cadence

| Trigger | Fires | Notes |
|---|---|---|
| Capture completed | `updateCaptureCount(n, lastName)` | One per capture, ~30s apart in practice |
| Safe Mode flip | `updateSafeMode(bool)` | 5s debounce against GPS polygon-edge flicker |
| Conversion finished | — | No update (count is captures, not conversions) |
| Circuit / title edit | — | No update (rare + invisible on lock screen) |
| Publish | `end(reason: .publish)` | Not an update — ends the activity |
| Time tick | — | Use SwiftUI `Text(.relative)` formatter; self-renders without `update` |

## Cold-start + orphan recovery

**Cold-start tap from lock screen** (app process dead):
1. iOS launches app via `OpenCameraIntent` performHandler (iOS 17+) or `defaultLaunchURL` (iOS 16.1+)
2. `HomefitLaunchChannel` captures the session UUID in `AppDelegate.application(_:didFinishLaunchingWithOptions:)`
3. Flutter boots; `main.dart` calls `LiveActivityService.reconcileOrphans()` **first**
4. `AuthGate` resolves auth; once ready, consumes the launch context
5. If session UUID resolves in local SQLite → push `SessionShellScreen(sessionId, initialPage: .camera)`
6. If not → push `ClientListScreen` with coral toast *"That session is no longer available."*

**Orphan recovery on any cold-start** (with or without launch context):
- Enumerate `Activity<SessionActivityAttributes>.activities`
- End every one. The cold-start + immediate shell-entry path will re-`request` if needed.
- Rationale: there is no in-Dart cache that knows which session was "active" before the kill. Cheaper to end-all than to try to rebind.

**Backgrounding (not killed):** activity persists. Shell stays mounted. `dispose` doesn't fire. Lock-and-return loop works seamlessly.

## Privacy posture

Carl explicitly opted for **client identity on the lock screen** (avatar + name + initials), overriding the conservative recommendation to keep the lock-screen card generic. Rationale: "prove at a glance who you're capturing without unlocking" is the load-bearing value.

Mitigations:
- iOS users with "Show Previews: When Unlocked" set will not see the content until Face ID authenticates. The activity respects that system setting.
- Avatar consent (`clients.video_consent.avatar`) gates avatar rendering. No avatar consent → initials only.
- Safe Mode chrome on the lock screen extends the de-identification visual language to the lock surface.
- No exercise name on the lock-screen card. Last-captured exercise name only surfaces in the Dynamic Island **expanded** view (long-press, only when phone is unlocked + in-hand).

**Location-always authorization** is required for the Safe Mode shield to remain truthful while the phone is locked. Without it, GPS down-throttles in background and the shield goes stale. The `Info.plist` purpose string must justify this to App Store Review.

## Carl-side checklist

Before merging this PR, Carl needs to:

1. Approve the new App Group entitlement in the Apple Developer portal (will trigger a provisioning profile re-roll).
2. Update the App Store Connect privacy form: add `NSLocationAlwaysAndWhenInUseUsageDescription` rationale; toggle "Always" location collection on. (See `docs/app-store-connect-privacy.md`.)
3. Confirm the location-always purpose string copy reads acceptably.
4. Bump TestFlight build number (`bump-version.sh`) — this PR forces a rebuild.
5. Approve the mockup at `docs/design/mockups/2026-05-23-live-activity-states.html` (already done).

## Implementation order

For the implementing sub-agent — do not parallelise these; each depends on the previous landing.

1. **Native plumbing** — add `HomefitSessionActivity` widget extension target; add App Group entitlement to both targets; bump iOS deployment target 15 → 16.1; verify the empty extension compiles and the app installs to a real device with the new entitlement.
2. **Static lock-screen card** — implement `SessionActivityLockScreenView` with hardcoded content; verify it appears on the lock screen when `Activity.request` is called from a test button.
3. **Dart wiring (start/end)** — `LiveActivityService` skeleton; wire `startForSession` / `end` from `SessionShellScreen.initState` / `dispose`; verify activity lifecycle matches shell lifecycle on device.
4. **Avatar pre-cache** — write the avatar PNG to the App Group container on `startForSession`; render in the SwiftUI view from the file path; verify initials fallback when no avatar.
5. **Content updates** — wire `updateCaptureCount` from `ConversionService` and `updateSafeMode` from `SafeModeService` (with 5s debounce); verify lock-screen card updates on device.
6. **Dynamic Island** — implement compact / minimal / expanded views matching the mockup; verify on device with Dynamic Island hardware.
7. **Launch channel + cold-start** — `HomefitLaunchChannel.swift`; `AuthGate` consumption; stale-session fallback toast; verify tap-from-lock-screen → Camera mode on cold-start AND after force-quit.
8. **App Intent button** (cut-line A) — `OpenCameraIntent.swift` registered in widget extension; tap button on iOS 17+ expanded island → opens Camera.
9. **Location-always upgrade** — request `always` authorization the first time `SafeModeService` starts; update `Info.plist`; handle declined case gracefully.
10. **Intro toast + Settings row** — gated by `shown_live_activity_intro_v1` SharedPref; Settings row reads `areActivitiesEnabled` and deep-links to iOS Settings.
11. **Orphan reconciliation** — `reconcileOrphans` called from `main.dart` before `runApp`; verify ghost activity from force-quit clears on next launch.
12. **Test script** — author `docs/test-scripts/2026-05-23-session-live-activity.md` with all 17 items; add to `docs/test-scripts/index.html` at the top of "Test these now".

## Cut-lines if scope bloats

- **Cut A — drop App Intent button.** iOS 17+ tap-body still opens the app. Removes step 8 above + the `OpenCameraIntent.swift` file. Polish, not load-bearing.
- **Cut B — drop Dynamic Island expanded long-press state.** Removes ~30% of SwiftUI layout code. Compact + minimal + lock-screen carry the feature.

Do **not** cut: location-always bump, App Group + avatar pre-cache, cold-start stale-session fallback, capture + Safe Mode update hooks.

## Test plan

Author `docs/test-scripts/2026-05-23-session-live-activity.md` with these 17 numbered items (stable numbering — do not reorder mid-wave):

1. Sign in fresh on a phone with Live Activities never granted → first session-shell entry triggers OS permission, accept → activity appears on lock screen with avatar
2. Same flow but decline location-always prompt → activity still appears; document that Safe Mode shield won't be truthful while locked (known limitation)
3. Existing client with no avatar consent → activity shows initials chip instead of avatar
4. Capture 3 exercises → lock screen counter ticks 1 → 2 → 3 within 2s of each capture
5. Walk into an enforcing premises mid-session → lock-screen card grows coral border + Safe banner; Dynamic Island compact trailing swaps to shield (~5s after geofence enter)
6. Walk out → card goes back to off state (~5s after exit)
7. Background app → lock phone → tap activity → app cold-starts directly to Camera mode of the right session
8. Force-quit app (swipe-up + flick away), then tap activity → app cold-starts to Camera mode (proves orphan-recovery rebind via UUID)
9. Delete the session in the portal while activity is live on phone → tap activity → land on client list with "session no longer available" toast
10. Publish the session from within the shell → activity disappears from lock screen
11. Leave session shell back to client list → activity disappears from lock screen
12. Long-press Dynamic Island → expanded view shows client name + last exercise + Safe banner (if Safe Mode on) + Capture next button
13. Tap "Capture next" button on iOS 17+ expanded island → opens Camera (proves App Intent wiring; iOS 17+ only)
14. Disable Live Activities in iOS Settings → re-enter shell → no activity appears; Settings row in app shows "off"
15. Re-enable in iOS Settings → re-enter shell → activity appears again; Settings row shows "on"
16. Open second session (different client) while a session is already active → first activity ends, second activity replaces it on lock screen (proves one-active-session enforcement)
17. Force-quit during active session, relaunch app and stay on client list → orphan activity gets ended on cold-start (does not linger)

## Out of scope

- **Android.** iOS-only feature; no Android equivalent in this PR.
- **Web player.** R-10 parity does not apply — this is a practitioner-side surface; client web player has nothing analogous.
- **Wake-lock during session shell.** Separate concern, separate small PR if desired. Carl confirmed locking is deliberate; no need to fight auto-lock here.
- **Live Activity-driven capture** (recording from the lock screen). Wildly out of scope.
- **Push-driven activity updates.** All updates are local (Dart → `live_activities` plugin → ActivityKit). No APNs `liveactivity` push tokens.
- **Multi-session lock-screen stacking.** One activity ever, by design.
- **Cross-device sync of activity state** (e.g. Apple Watch glance). Lock screen + Dynamic Island only.

## Open risks

- **Provisioning profile re-roll friction.** First App Group capability addition. May require Carl to re-download a profile and let Xcode re-fetch. If it blocks the implementing agent, the agent should stop and surface the blocker rather than guess.
- **Location-always App Store Review pushback.** Reviewers sometimes question `always` location for non-navigation apps. The purpose-string copy must clearly tie it to a user-visible behaviour (Safe Mode shield truthfulness). If Apple pushes back, the fallback is to keep `whenInUse` and document the shield-staleness as a known limitation (item 2 of the test plan already covers this state).
- **GPS edge flicker.** 5s debounce may need tuning on-device. First implementation may feel either too jumpy or too laggy.
- **Cold-start race.** Launch channel hands UUID to Dart, but Dart needs SQLite + AuthService bootstrapped before navigating. Need an "AuthGate ready" gate before consuming the launch context. Risk: if timing is wrong, user lands on client list and has to tap into the session manually.
- **iOS 16.1 deployment target bump.** Mobile codebase is currently 15.0. Bumping should be safe (iOS 16 adoption ~98% in 2026, zero current TestFlight users on 15) but any third-party plugin that still requires 15 will surface as a Podfile resolution error. Run `pod install` to verify.
