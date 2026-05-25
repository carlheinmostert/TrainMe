# Test script — Self-trainer intro banner

**PR:** #10 of the self-trainer wave (`feat/self-trainer-migration-banner` → `staging`)
**Spec:** `docs/SELF_TRAINER_WAVE.md` § Migration plan § Communication
**Brief:** `docs/sub-agent-briefs/10-self-trainer-migration-banner.md`

## What this PR ships

1. New widget `app/lib/widgets/self_trainer_intro_banner.dart` — dismissible coral-bordered banner shown above the scope row on Home.
2. New ApiClient helper `isCurrentUserSafeModeGrandfathered()` — reads `practice_members.safe_mode_grandfathered` for the signed-in user (PR #1 schema). Returns false on any error.
3. Banner mounted in `app/lib/screens/home_screen.dart` between the brand lockup (`HomefitLogoLockup`) and the scope row (`HomeScopeSegmented`).
4. SharedPreferences key `self_trainer_intro_dismissed` (bool) — once set true, banner never re-renders on this device.
5. Copy is bracketed `[carl-review:]` — final wording pending Carl's voice pass before merge.

## Test items

Run on staging (`./install-sim.sh staging` or `./install-sim-keep-auth.sh staging`) with the agent QA test account (`qa@homefit.studio`).

- [ ] **a. First cold launch — banner appears.** Fresh install (or first launch after this build lands). Sign in. Land on Home. Banner appears between the brand lockup and the scope row. Headline reads `[carl-review:] My Workouts is live`. Body reads `[carl-review:] Capture yourself, get plans from your practitioner — all in one place.`
- [ ] **b. "Got it" dismisses + persists.** Tap the `[carl-review:] Got it` button. Banner collapses with a 220ms ease-out animation. Force-quit the app, relaunch. Banner does NOT re-appear.
- [ ] **c. × dismisses too.** Reset by running this in the simulator's address bar or via `xcrun simctl spawn <udid> defaults delete studio.homefit.app self_trainer_intro_dismissed` then relaunching. Verify banner reappears. Tap the × icon top-right of the banner. Banner collapses, dismiss flag set. Relaunch → banner stays gone.
- [ ] **d. Grandfathered user sees the extension line.** Sign in as a user whose `practice_members.safe_mode_grandfathered = true` for at least one membership. (Carl: the QA test account is NOT grandfathered by default. Either run `UPDATE practice_members SET safe_mode_grandfathered = true WHERE trainer_id = '<qa-user-id>';` in staging SQL editor, or use a real practitioner account that captured Safe Mode pre-2026-05-25.) Verify the additional line reads `[carl-review:] Safe Mode is now a subscription. Because you've used it, we've extended your access for free — no action needed.`
- [ ] **e. Non-grandfathered user does NOT see the extension line.** Sign in as a user with no grandfather flag (the default for new accounts). Verify only the universal headline + body render — no Safe Mode line.
- [ ] **f. RPC failure is silent.** Disconnect Wi-Fi before signing in. Cold launch + sign in. Banner still renders the universal copy (no grandfathered extension). No SnackBar / error banner from the failed `practice_members` SELECT.

## Pre-merge checks (Mac-side)

- [ ] `dart_analyze` clean on `app/lib/widgets/self_trainer_intro_banner.dart` + `app/lib/screens/home_screen.dart` + `app/lib/services/api_client.dart`.
- [ ] `dart_format` clean on the same files.
- [ ] `flutter build ios --debug --simulator --dart-define=GIT_SHA=<sha>` succeeds.
- [ ] `grep -rn '<<<<<<<\|>>>>>>>' app/lib/ docs/test-scripts/` returns zero matches.
- [ ] **Copy review by Carl** — every `[carl-review:]` bracketed string in `self_trainer_intro_banner.dart` (headline, universal body, grandfathered line, "Got it" label) replaced with final voice.

## Notes

- The banner is mobile-only by design (R-10 N/A) — Home is a Flutter-only surface.
- No push notification, no email — banner is the single channel per Q13.5 (a) of the wave decision log.
- Banner pref key (`self_trainer_intro_dismissed`) has no `v1` suffix — bump to `v2` if the copy materially changes post-launch and we want to re-announce.
